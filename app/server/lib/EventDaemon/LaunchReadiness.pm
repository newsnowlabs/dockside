# docker-event-daemon's pre-dispatch readiness gate: mountIDE:false Dockside devtainers
# populate their own /opt/dockside volume during entrypoint startup. Defer IDE launch until the
# configured launcher path exists instead of retrying docker exec failures. Distinct from
# EventDaemon::LaunchRecovery's own polling - this is "waiting for a file to appear before a
# first dispatch", not "recovering a claim nobody's completion callback will ever settle".
package EventDaemon::LaunchReadiness;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw(launch_or_queue_until_launcher_ready clear_pending_launch check_pending_launches);

use Try::Tiny;
use Time::HiRes qw(time);

use Util qw(flog docker_container_path_exists);
use Data qw($CONFIG);
use Reservation;
use EventDaemon::LaunchDispatch qw(launch_advance);

my $LAUNCH_READY_MAX_WAIT = 60; # seconds
my $LAUNCH_READY_INTERVAL = 1;  # seconds between Docker API readiness checks

my %pendingLaunch;  # containerId => { deadline => epoch, nextTime => epoch, launcher => path, reservationId => id }

sub launcher_wait_path ($reservation) {
   return undef if $reservation->profileObject->should_mount_ide;

   return $reservation->ide_command_launcher();
}

# Returns true if the launcher exists inside the container AND its mtime is >= $since
# (meaning it was written during the current container run, not left over from a previous one).
# $since is undef when no staleness check is needed (e.g. first-ever launch with no prior volume).
sub launcher_path_exists ($reservation, $launcher, $since = undef) {
   my ($exists, $mtime) = docker_container_path_exists(
      $CONFIG->{'docker'}{'socket'},
      $reservation->containerId,
      $launcher
   );
   return 0 unless $exists;
   # $mtime is whole seconds (Docker's stat has no sub-second precision by the time it's
   # parsed); $since may carry a Time::HiRes fractional part, so floor it before comparing
   # or a launcher written in the same second as $since is wrongly seen as predating it.
   return 0 if defined($since) && defined($mtime) && $mtime < int($since);
   return 1;
}

sub queue_pending_launch ($reservation, $context, $launcher, $since) {
   my $containerId = $reservation->containerId;

   # The container is running but the IDE is not yet launched. Until it is,
   # route UI IDE links according to the requested IDE, not any previous value. Narrow store -
   # see Reservation::store_fields' own comment - since this reservation may concurrently be
   # written by other, unrelated fields.
   $reservation->data('runningIDE', $reservation->meta('IDE'));
   $reservation->store_fields( { 'data' => { 'runningIDE' => $reservation->data('runningIDE') } } );

   $pendingLaunch{$containerId} = {
      deadline      => time() + $LAUNCH_READY_MAX_WAIT,
      nextTime      => time() + $LAUNCH_READY_INTERVAL,
      launcher      => $launcher,
      reservationId => $reservation->id,
      startTime     => $since,
   };

   flog("$context: delaying IDE launch for reservationId=" . $reservation->id . " with containerId=$containerId: launcher '$launcher' is not present yet (or predates container start)");
}

sub launch_or_queue_until_launcher_ready ($reservation, $context, $since) {
   my $launcher = launcher_wait_path($reservation);

   if(defined($launcher) && $launcher ne '' && !launcher_path_exists($reservation, $launcher, $since)) {
      queue_pending_launch($reservation, $context, $launcher, $since);
      return undef;
   }

   # Kicks off the whole launch:prep -> {launch:git, launch:ide, lifecycle:*} DAG - fire-and-
   # forget in the sense that dispatch is non-blocking, but self-propagating: each stage's own
   # dispatch closure calls launch_advance again once it resolves, so a single call here drives
   # the whole DAG to completion without anything needing to poll it - see
   # EventDaemon::LaunchDispatch::launch_advance's own comment. A truthy return here only means
   # the DAG was successfully kicked off, not that it's finished; real progress is recorded
   # asynchronously in data('hooks') as each stage resolves.
   launch_advance($reservation);
   return 1;
}

# Clears any stale entry from a previous start of the same container - called by
# EventDaemon::ContainerSync::onContainerStart when a genuine new start event supersedes
# whatever a previous wait was tracking for this containerId.
sub clear_pending_launch ($containerId) {
   delete $pendingLaunch{$containerId};
}

# Starts any pending IDE launches whose launcher path has appeared - called once per
# eventHandler tick. Self-contained: owns its own try/catch, so a caller need not wrap it.
sub check_pending_launches {
   return unless %pendingLaunch;
   try {
      for my $cid (keys %pendingLaunch) {
         my $entry = $pendingLaunch{$cid};
         next if time() < $entry->{'nextTime'};

         if (time() >= $entry->{'deadline'}) {
            flog("EventDaemon::LaunchReadiness::check_pending_launches: giving up on pending IDE launch for reservationId=" . $entry->{'reservationId'} . " with containerId=$cid after ${LAUNCH_READY_MAX_WAIT}s waiting for launcher '" . $entry->{'launcher'} . "'");
            delete $pendingLaunch{$cid};
            next;
         }

         flog("EventDaemon::LaunchReadiness::check_pending_launches: checking pending IDE launch for reservationId=" . $entry->{'reservationId'} . " with containerId=$cid");

         Data::load('config.json', 'users.json', 'roles.json', 'reservations.json', 'containers.json');

         my $reservations = Reservation->load({ 'containerId' => $cid });
         if (!@$reservations) {
            flog("EventDaemon::LaunchReadiness::check_pending_launches: containerId=$cid no longer managed; cancelling pending IDE launch");
            delete $pendingLaunch{$cid};
            next;
         }

         my $reservation = $reservations->[0];
         my $launcher = launcher_wait_path($reservation) // $entry->{'launcher'};

         if(defined($launcher) && $launcher ne '' && !launcher_path_exists($reservation, $launcher, $entry->{'startTime'})) {
            flog("EventDaemon::LaunchReadiness::check_pending_launches: launcher '$launcher' still not present (or predates container start) for reservationId=" . $reservation->id . " with containerId=$cid");
            $entry->{'launcher'} = $launcher;
            $entry->{'nextTime'} = time() + $LAUNCH_READY_INTERVAL;
            next;
         }

         try {
            # See launch_or_queue_until_launcher_ready's own comment - dispatch is
            # non-blocking and self-propagating, so "dispatched" below means the DAG was
            # kicked off, not that launch:prep itself has actually finished yet.
            launch_advance($reservation);
            flog("EventDaemon::LaunchReadiness::check_pending_launches: pending IDE launch dispatched for reservationId=" . $reservation->id . " with containerId=$cid");
            delete $pendingLaunch{$cid};
         }
         catch {
            my $dbg = ref($_) ? $_->dbg() : $_;
            flog("EventDaemon::LaunchReadiness::check_pending_launches: pending IDE launch failed after launcher became ready for reservationId=" . $reservation->id . " with containerId=$cid; cancelling pending launch: $dbg");
            delete $pendingLaunch{$cid};
         };
      }
   }
   catch {
      flog("EventDaemon::LaunchReadiness::check_pending_launches: caught exception: " . (ref($_) ? $_->dbg : $_));
   };
}

1;
