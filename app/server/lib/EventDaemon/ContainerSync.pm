# Keeps Dockside's container state file (containers.json) in sync with the live Docker engine,
# bridging Docker's runtime state to Dockside's own data layer so the application always has an
# up-to-date view of running containers, and classifies/reacts to Docker events - including
# kicking off the launch:-DAG (see EventDaemon::LaunchDispatch) on a genuine container start.
package EventDaemon::ContainerSync;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw(update onEvent record_all_started_at);

use Try::Tiny;
use JSON;
use Time::HiRes qw(time);
use Mojo::Date;

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

      # StartedAt is known only from inspecting the container (record_started_at below), never
      # from the list, so the old record's value is carried the way Size is above.
      if( $oldContainers && $oldContainers->{$ID} && defined $oldContainers->{$ID}{'docker'}{'StartedAt'} ) {
         $newContainers->{$ID}{'docker'}{'StartedAt'} = $oldContainers->{$ID}{'docker'}{'StartedAt'};
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

# Docker's inspect reports State.StartedAt as an RFC 3339 UTC string with nanoseconds, and Go's
# zero time, 0001-01-01T00:00:00Z, for a container that has never started. Mojo::Date keeps the
# fraction but reads that zero time's year as 2001, so it is excluded by its text. Returns a
# fractional epoch, or undef for the zero time or a string that does not parse.
sub _started_at_epoch ($startedAt) {
   return undef unless defined($startedAt) && $startedAt !~ /^0001-01-01T/;
   return Mojo::Date->new($startedAt)->epoch;
}

# Records $epoch as docker.StartedAt on containers.json's entry for $id, under the file's lock,
# or with $epoch undef removes the value. Inspections of one container land in whatever order
# Docker answers them, so a value is only ever replaced by a later one. An entry the list fetch
# has not yet written is left alone: the container's next start event inspects again. Returns
# whether anything was written.
sub _write_started_at ($id, $epoch) {
   my $shortId = substr($id, 0, 12);
   my $written = 0;
   cacheReadWrite( $CONFIG->{'containersPath'}, sub ($oldJSON) {
      my $file  = decode_json($oldJSON);
      my $entry = $file->{'containers'}{$shortId} or return $oldJSON;
      my $known = $entry->{'docker'}{'StartedAt'};
      if ( defined $epoch ) {
         return $oldJSON if defined($known) && $known >= $epoch;
         $entry->{'docker'}{'StartedAt'} = $epoch;
      }
      else {
         return $oldJSON unless defined $known;
         delete $entry->{'docker'}{'StartedAt'};
      }
      $written = 1;
      return encode_json($file);
   } );
   return $written;
}

# Removes a container's recorded start time. Called when the container has started again and
# the new time is not yet known, so that the list refresh carries no previous start forward and
# an inspection that fails leaves the container with no value, which readers treat as not
# stopping, rather than a stale one that a stop request could remain newer than for as long as
# the container runs.
sub _clear_started_at ($id) {
   try { _write_started_at( $id, undef ) }
   catch { flog("EventDaemon::ContainerSync::_clear_started_at: containerId=" . substr($id, 0, 12) . ": " . (ref($_) ? $_->dbg : $_)) };
   return;
}

# Fetches a container's last start time from Docker and records it (_write_started_at), after
# removing the value on record (_clear_started_at). The value is what Reservation's client view
# compares a stop request's time against, so the stopping indicator settles when the container
# is next started. Non-blocking; $cb, if given, is called once with no arguments when the record
# has been made or abandoned.
sub record_started_at ($id, $cb = undef) {
   my $shortId = substr($id, 0, 12);
   _clear_started_at($shortId);
   call_socket_api( $CONFIG->{'docker'}{'socket'}, "/containers/$shortId/json", {}, sub ($result, $err) {
      try {
         die "unable to inspect: " . ($err // 'no result') unless $result;
         die sprintf("inspect answered %d", $result->code) unless $result->is_success;
         my $epoch = _started_at_epoch( decode_json($result->body)->{'State'}{'StartedAt'} );
         die "inspect reports no start time" unless defined $epoch;
         my $written = _write_started_at($shortId, $epoch);
         flog("EventDaemon::ContainerSync::record_started_at: containerId=$shortId StartedAt=$epoch "
            . ($written ? 'recorded' : 'not recorded: no newer than the value on record, or no entry yet'));
      }
      catch {
         flog("EventDaemon::ContainerSync::record_started_at: containerId=$shortId: " . (ref($_) ? $_->dbg : $_));
      };
      $cb->() if $cb;
   } );
   return;
}

# Records the start time of every container in containers.json, so a container started while no
# daemon was observing events carries its real start rather than none or a stale one. Every
# container, not only those whose status phrase reads "Up": Reservation::update_container_info
# treats every status but Created and Exited as running, and a container that has never started
# reports the zero time, which is recorded as nothing. Once per process, after the first list
# fetch. $cb is called once, with no arguments, when every inspection has settled; with no
# containers that is before this returns.
sub record_all_started_at ($cb) {
   my $containers = try { decode_json( cacheReadWrite( $CONFIG->{'containersPath'} ) )->{'containers'} } catch { {} };
   my @ids = sort keys %$containers;

   flog("EventDaemon::ContainerSync::record_all_started_at: " . scalar(@ids) . " container(s)");
   my $pending = scalar(@ids) or do { $cb->(); return; };
   record_started_at( $_, sub { $cb->() unless --$pending } ) for @ids;
   return;
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
   # The container has a new start time, not yet known: the value on record is removed before
   # the list refresh below, which would otherwise carry it forward, and the container is
   # inspected after it, once its entry is certain to exist. Whether or not this daemon manages
   # the container, and independent of the launch below, so it is not waited for.
   _clear_started_at($id);

   update( {}, sub {
      record_started_at($id);

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
