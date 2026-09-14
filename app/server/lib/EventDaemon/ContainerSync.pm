# Keeps Dockside's container state file (containers.json) in sync with the live Docker engine,
# bridging Docker's runtime state to Dockside's own data layer so the application always has an
# up-to-date view of running containers, and classifies/reacts to Docker events - including
# kicking off the launch:-DAG (see EventDaemon::LaunchDispatch) on a genuine container start.
package EventDaemon::ContainerSync;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw(update onEvent);

use Try::Tiny;
use JSON;
use Time::HiRes qw(time);

use Util qw(flog cacheReadWrite call_socket_api);
use Exception;
use Data qw($CONFIG);
use Reservation;
use Containers;
use EventDaemon::LaunchDispatch qw(launch_reset_stages);
use EventDaemon::LaunchReadiness qw(launch_or_queue_until_launcher_ready clear_pending_launch);
use EventDaemon::LaunchRecovery qw(clear_recovering);

# Pure, synchronous merge (no I/O) of an already-fetched Docker /containers/json response with
# the existing containers.json content. Runs after the (potentially slow - see update's own
# comment) fetch completes, so only this fast, pure step needs to run under cacheReadWrite's
# lock. $newContainersFromAPI is the decoded body of the API response; $oldJSON is
# cacheReadWrite's own existing-file content, read fresh right before this runs.
sub _update_merge ($newContainersFromAPI, $oldJSON) {
   my $oldContainers;
   try {
      $oldContainers = $oldJSON ? decode_json($oldJSON)->{'containers'} : {};
   }
   catch {
      $oldContainers = {};
   };

   my $idePath = $CONFIG->{'ide'}{'path'};
   my $hostDataPath = $CONFIG->{'ssh'}{'path'};

   my $newContainers;
   foreach my $c (@$newContainersFromAPI) {

      my $ID = substr($c->{'Id'}, 0, 12); # Truncate to Docker's standard short ID length.

      # For each mount point of interest, produce ['volume', $name] or ['bind', $source].
      my ($ideVolume) = map { $_->{'Type'} eq 'volume' ? ['volume', $_->{'Name'}] : ['bind', $_->{'Source'}] } grep { $_->{'Destination'} eq $idePath } @{$c->{'Mounts'}};
      my ($hostDataVolume) = map { $_->{'Type'} eq 'volume' ? ['volume', $_->{'Name'}] : ['bind', $_->{'Source'}] } grep { $_->{'Destination'} eq $hostDataPath } @{$c->{'Mounts'}};

      $newContainers->{$ID}{'docker'} = {
         'ID' => $ID, # Short ID (for now)
         'Names' => substr($c->{'Names'}[0], 1), # Skip leading '/'
         'CreatedAt' => $c->{'Created'}, # Unix timestamp
         'Status' => $c->{'Status'}, # String
         'Image' => $c->{'Image'}, # String
         'ImageId' => substr( substr($c->{'ImageID'}, 7), 0, 12), # Strip 'sha256:' prefix (7 chars), then truncate to short ID.
         'Size' => $c->{'SizeRw'},
         'Networks' => join(',', sort keys %{$c->{'NetworkSettings'}{'Networks'}})
      };

      # HashRef keyed on internal port looking up host port.
      # This is only needed when $CONFIG->{'gateway'}{'enabled'} is true (and this is deprecated)
      my $ports = { map { $_->{'PrivatePort'} => $_->{'PublicPort'} } @{$c->{'Ports'}} };

      $newContainers->{$ID}{'inspect'} = {
         'Networks' => $c->{'NetworkSettings'}{'Networks'},
         'Ports' => $ports,
         'ideVolume' => $ideVolume,
         'hostDataVolume' => $hostDataVolume
      };

      # Copy the container Size from the oldContainer record if we haven't requested the Size on this run.
      if( $oldContainers && $oldContainers->{$ID} && $oldContainers->{$ID}{'docker'}{'Size'} ) {
         if( !$newContainers->{$ID}{'docker'}{'Size'} ) {
            $newContainers->{$ID}{'docker'}{'Size'} = $oldContainers->{$ID}{'docker'}{'Size'};
         }
      }

   }

   my $newContainersFile = { 'version' => Containers::CURRENT_VERSION, 'containers' => $newContainers };

   return encode_json($newContainersFile);
}

# Updates the container state by retrieving the current container list from the Docker API
# (non-blocking) and merging it with the existing container data. $opts->{'updateSizes'} (only
# when $CONFIG->{'docker'}{'sizes'} also allows it) adds Docker's own size=true, which computes
# every container's RW-layer diff size - genuinely slow, not just theoretically: measured at
# ~30x the no-sizes call's own latency against a real daemon with a modest container count, and
# size=true's cost scales with fleet size/filesystem activity, not something a better query
# fixes. This is exactly why this call is non-blocking at all: the point isn't to make size=true
# itself faster (it can't be - that cost is Docker's own, not this call's), it's that the
# daemon's own reactor - servicing /events and every in-flight launch dispatch - stays
# responsive for that whole duration instead of stalling on it.
#
# The fetch happens *before* cacheReadWrite is ever called, deliberately - nothing about
# fetching depends on containers.json's own content, so there's no correctness reason to hold
# its lock for the fetch's duration. cacheReadWrite itself needs no changes: only the fast,
# pure merge (_update_merge, called from here) ever runs under its lock, exactly its existing
# synchronous contract, same as its other callers throughout the codebase (Profile/User/Role
# management).
sub update ($opts, $cb) {
   # $CONFIG->{'docker'}{'sizes'} can disable size tracking entirely, not just defer it.
   my $path = '/containers/json?all=true' . (($CONFIG->{'docker'}{'sizes'} && $opts->{'updateSizes'}) ? '&size=true' : '');

   flog("EventDaemon::ContainerSync::update: requesting container list" . ($opts->{'updateSizes'} ? ' with sizes' : ' without sizes'));

   call_socket_api( $CONFIG->{'docker'}{'socket'}, $path, {}, sub ($result, $err) {
      try {
         unless ($result) {
            die Exception->new( 'dbg' => "Unable to execute Docker API call: $path #1", 'msg' => "Unable to retrieve container list: $err" );
         }
         unless ($result->is_success) {
            die Exception->new( 'msg' => sprintf("Unable to obtain container list via $path (response code %d, error '%s')", $result->code, $result->message) );
         }

         my $newContainersFromAPI = decode_json($result->body);

         # cacheReadWrite reads containers.json's own current content fresh, right here, right
         # before the merge - a genuine improvement over the old shape, not just incidental: the
         # Size-preservation read below is now as recent as possible, rather than read once
         # before a (possibly slow) fetch that has already happened by this point regardless.
         my $containersJSON = cacheReadWrite(
            $CONFIG->{'containersPath'},
            sub ($oldJSON) { _update_merge($newContainersFromAPI, $oldJSON) },
         );

         my $containersFile = decode_json($containersJSON);
         my $containers = $containersFile->{'containers'};

         # Assign ExpiryTimes to Reservations missing containers, and clean up old Reservations.
         Reservation->load_clean_map(keys %$containers);
      }
      catch {
         flog("EventDaemon::ContainerSync::update: caught exception: " . (ref($_) ? $_->dbg : $_));
      };
      $cb->() if $cb;
   } );
}

# Called when a container start event is received. Updates container state, reloads all
# data files (config, users, reservations, containers), then launches the IDE process
# inside the container if it belongs to a Dockside-managed reservation. Non-blocking throughout
# (update) - returns immediately, continuing via callback once the container-state update
# settles; onEvent (its only caller) never used this function's own return value, so nothing
# needed adjusting there.
sub _onContainerStart ($id, $eventCount) {

   # Record the time the start event was received, before the slower update()/Data::load()
   # work below; used to detect stale launcher symlinks left over in the IDE volume from a
   # previous container run. Capturing this later would let a launcher written by a fast
   # entrypoint (before that work completes) look older than it really is.
   my $T1 = time();

   # This container's details might not yet have been loaded. Do this now.
   flog("EventDaemon::ContainerSync::onContainerStart #$eventCount: Updating docker containers without sizes before reloading reservations");
   update( {}, sub {
      # Reload config, reservations and containers, to access Reservation->load and %CONFIG.
      # Reload users and roles too, in case we can update owner's name and email [at later date].
      Data::load('config.json', 'users.json', 'roles.json', 'reservations.json', 'containers.json');

      my $reservations = Reservation->load({ 'containerId' => $id });
      if(!@$reservations) {
         flog("EventDaemon::ContainerSync::onContainerStart #$eventCount: we don't manage containerId=$id");
         return;
      }

      my $reservation = $reservations->[0]; # Safe: filtered by containerId, so at most one match.
      my $reservationId = $reservation->id;
      my $containerId = $reservation->containerId;

      flog("EventDaemon::ContainerSync::onContainerStart #$eventCount: we manage reservationId=$reservationId with containerId=$containerId");

      # Clear any stale pending launch entry from a previous start of the same container.
      clear_pending_launch($containerId);

      # Also clear any stale launch-recovery entry - a genuine new start event supersedes
      # whatever a previous daemon restart's still-unfinished recovery sweep was tracking for
      # this containerId. See EventDaemon::LaunchRecovery::clear_recovering's own comment.
      clear_recovering($containerId);

      # Reset the launch:-DAG stage statuses for a fresh cycle - without this, this restart's
      # launch_advance call below (via launch_or_queue_until_launcher_ready) would see
      # launch:prep's still-persisted 'done' status from the *original* launch and skip the
      # whole cascade (including lifecycle:start, which must fire on every restart - see
      # EventDaemon::LaunchDispatch::launch_reset_stages' own comment). Exactly once here, not
      # inside EventDaemon::LaunchReadiness::check_pending_launches - those retries are for this
      # *same* start event, and must keep seeing what this reset already put in place.
      launch_reset_stages($reservation);

      try {
         launch_or_queue_until_launcher_ready($reservation, "onContainerStart #$eventCount", $T1);
      }
      catch {
         my ($msg, $dbg) = ref($_) ? ($_->msg(), $_->dbg()) : ($_,$_);
         flog("EventDaemon::ContainerSync::onContainerStart #$eventCount: failed to launch IDE for reservationId=$reservationId with containerId=$containerId: dbg='$dbg'; msg='$msg'");
      };
   } );
}

# Classifies a raw Docker event and dispatches to the appropriate handler.
# Returns 1 if the event is relevant (accumulated into $relevantEvents to trigger a fast
# container-state refresh), or 0 if it is not of interest and can be ignored.
sub onEvent ($event, $eventCount) {

   my $id = $event->{'Actor'}{'ID'};
   my $type = $event->{'Type'};
   my $action = $event->{'Action'};

   flog(
      sprintf("EventDaemon::ContainerSync::onEvent #$eventCount: received event: Type=%s, Action=%s, Actor=%s",
         $type, $action, $id
      )
   );

   if( $type eq 'network' && $action =~ /^(connect|disconnect)$/ ) {
      return 1; # Network topology changed; container port/network data may be stale.
   }

   if( $type eq 'container' && $action =~ /^(stop|create|destroy)$/ ) {
      # Pending-launch tracking is keyed by the 12-char Reservation->containerId; Docker
      # container events carry the full-length Actor ID, so normalise before the lookup or the
      # cancellation misses and the daemon keeps waiting on a stopped container.
      my $cid = substr($id // '', 0, 12);
      if ($action =~ /^(stop|destroy)$/ && clear_pending_launch($cid)) {
         flog("EventDaemon::ContainerSync::onEvent #$eventCount: cancelled pending IDE launch for $action containerId=$cid");
      }
      return 1; # Container lifecycle change; state refresh needed.
   }

   if( $type eq 'container' && $action =~ /^(start)$/ ) {
      _onContainerStart($id, $eventCount);
      return 1;
   }

   return 0; # Unrecognised event type/action; no update needed.
}

1;
