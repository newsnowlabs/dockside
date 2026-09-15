# docker-event-daemon's launch-DAG driver: small, declarative dependency table + one generic
# driver, owned entirely here - not Reservation.pm, which stays limited to pure data operations
# and fork-agnostic building blocks; this module owns "what to dispatch next". Reservation.pm/
# Reservation::Launch.pm's existing pure accessors (ide_command/hook_script/_hook_env/
# ide_command_env) and pure state-recording methods (hook_status_*/store_fields) are called
# directly from here - reused as-is, not reimplemented.
#
# TRANSPORT: every dispatch below is non-blocking (Util::docker_exec), never a fork.
# Non-blocking dispatch avoids races between self-heal and completion callbacks: there is
# only ever one process, so "which of two paths resolves this stage first" is not a question
# that can be asked - the completion callback is the sole, unambiguous resolver. It also
# means self-heal (polling a 'running' stage to check whether its owning process died) is
# *only* ever needed once, at the daemon's own startup, for a stage left 'running' by a
# *previous*, now-dead daemon process - see EventDaemon::LaunchRecovery's own
# restart_recovery_sweep. During normal operation, launch_advance below deliberately does NOT
# poll a 'running' stage at all: it will resolve via its own completion callback, guaranteed,
# unless the daemon itself dies - a case restart_recovery_sweep alone exists to cover. Nothing
# needs to keep re-checking an in-flight launch, because the callback chain drives itself to
# completion on its own.
package EventDaemon::LaunchDispatch;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw(launch_resolve_stage launch_reset_stages launch_in_flight launch_advance
   @LAUNCH_STAGE_NAMES begin_shutdown is_shutting_down in_flight_count drain_complete);

use Try::Tiny;
use JSON;

use Util qw(flog sanitize_sensitive_text docker_exec unique);
use Exception;
use Data qw($CONFIG);
use Reservation::Mutate qw(launch_reset_stages_if_idle);
use User;

my $ROOT_USER    = sub ($reservation) { 'root' };
my $NONROOT_USER = sub ($reservation) { $reservation->unixuser() };

# Two genuinely different dispatch shapes, not one forced-uniform shape: launch:prep/launch:git/
# launch:ide are bare launch.sh entry-point functions (no hook name/script involved - see
# _launch_dispatch_exec below), while lifecycle:launch/lifecycle:start are real, profile-
# declared hooks, dispatched via _launch_dispatch_hook_stage's own thin wrapper around
# Reservation::dispatch_hook_exec - see its own comment.
my %LAUNCH_STAGES = (
   'launch:prep' => {
      depends_on => [],
      dispatch   => \&_launch_dispatch_prep,
   },
   'launch:git' => {
      depends_on => ['launch:prep'],
      applicable => sub ($reservation) { !!@{ $reservation->profileObject->gitURLs // [] } },
      dispatch   => sub ($reservation, $cb) {
         _launch_dispatch_exec( $reservation, 'launch:git', 'launch_git', $NONROOT_USER->($reservation), {
            'extra_env' => [
               "DOCKSIDE_START_COUNT=" . ( $reservation->data('startCount') // 0 ),
               "DEVCONTAINER_VSCODE_EXTENSIONS=" . encode_json( $reservation->data('vscode') ),
            ],
         }, $cb );
      },
   },
   'launch:ide' => {
      depends_on => ['launch:prep'],
      dispatch   => sub ($reservation, $cb) {
         # A profile whose devtainer runs an older, pre-split launch.sh (Profile::
         # ide_launch_version - only possible at all when mountIDE:false, since a mounted IDE is
         # always the outer's own, in-sync copy) has no separate launch_prep/launch_git to have
         # run - launch:prep/launch:git were skipped outright for it (see launch_reset_stages),
         # never dispatched. Its single launch_ide already does all three stages' own work, so
         # it takes over here instead of the split interface's slimmed-down, nonroot-only call.
         ( $reservation->profileObject->ide_launch_version == 0 )
            ? _launch_dispatch_legacy_ide( $reservation, $cb )
            : _launch_dispatch_exec( $reservation, 'launch:ide', 'launch_ide', $NONROOT_USER->($reservation), {
                 'detach'    => 1,
                 'extra_env' => [ "IDE=" . $reservation->meta('IDE') ],
              }, $cb );
      },
   },
   'lifecycle:launch' => {
      depends_on => ['launch:git'],
      applicable => sub ($reservation) {
         !!( $reservation->profileObject->hooks->{'lifecycle:launch'} && ( $reservation->data('startCount') // 0 ) == 1 )
      },
      dispatch   => sub ($reservation, $cb) { _launch_dispatch_hook_stage( $reservation, 'lifecycle:launch', $cb ) },
   },
   'lifecycle:start' => {
      depends_on => ['lifecycle:launch'],
      applicable => sub ($reservation) { !!$reservation->profileObject->hooks->{'lifecycle:start'} },
      dispatch   => sub ($reservation, $cb) { _launch_dispatch_hook_stage( $reservation, 'lifecycle:start', $cb ) },
   },
);

our @LAUNCH_STAGE_NAMES = keys %LAUNCH_STAGES;

# Set by the daemon's shutdown signal handler to stop the DAG driver from starting any *new*
# dispatch - see launch_maybe_dispatch's own gate below. Never cleared. A refused stage just
# stays 'pending', picked up fresh by the next process's own restart_recovery_sweep.
my $SHUTTING_DOWN = 0;

sub begin_shutdown () { $SHUTTING_DOWN = 1; }
sub is_shutting_down () { return $SHUTTING_DOWN; }

# Every non-detached dispatch still awaiting its own docker_exec completion callback, keyed by
# invocationId - detached dispatch (launch:ide) never participates, since it holds no long-lived
# connection worth waiting for. Increment is the last synchronous step before docker_exec is
# called; decrement is the first statement of its completion callback, outside that callback's
# own try/catch, so every exit path decrements exactly once.
my %DISPATCH_IN_FLIGHT;

sub in_flight_count () { return scalar keys %DISPATCH_IN_FLIGHT; }

# True once nothing this process needs to preserve is still in flight - the one condition that
# gates the daemon's own process exit (see docker-event-daemon's outer while(1) loop). Confirmed
# against Mojo::IOLoop's own POD that stop() itself never severs a connection - only the process
# exiting does - so this is the one real gate, not every caller of stop.
sub drain_complete () { return !in_flight_count() && !Reservation->hook_dispatch_in_flight_count(); }

sub launch_resolve_stage ($reservation, $stage, $state, $expectedInvocationId = undef) {
   return $reservation->hook_status_completed( $stage, { 'state' => $state }, $expectedInvocationId );
}

sub _launch_deps_cleared ($reservation, $stage) {
   for my $dep ( @{ $LAUNCH_STAGES{$stage}{'depends_on'} } ) {
      my $status = $reservation->hook_status($dep);
      return 0 unless $status && $status->{'state'} =~ /^(?:done|skipped)$/;
   }
   return 1;
}

# Marks every launch:-DAG stage 'pending' for a fresh launch cycle - except any name that's
# genuinely still running right now, left untouched (see
# Reservation::Mutate::launch_reset_stages_if_idle's own comment for why: lifecycle:launch/
# lifecycle:start are also reachable via a concurrent on-demand run_hook_manual invocation, unlike
# the other three DAG stages, which are docker-event-daemon-exclusive). Called exactly once per
# genuine container 'start' Docker event (EventDaemon::ContainerSync::onContainerStart, before
# its first launch_advance call for that event) - never from the pending-launch retry loop
# (EventDaemon::LaunchReadiness::check_pending_launches), which is for waiting out the *same*
# start event and must keep seeing whatever this reset already put in place. Touches only the 5
# launch:-stage names - never the whole hooks.status hash, which may also hold entries for
# on-demand/custom hook names this has no business touching.
#
# Also updates $reservation's own in-memory hooks.status directly for whichever names were
# actually reset, mirroring Reservation::_hook_status_store_one's own discipline (see its
# comment) - mutate() only ever writes a *fresh*, separately-loaded copy (see
# Reservation::Mutate::update: it mutates $by_id->{$id}, never $self), so without this,
# launch_advance's own very next call - using this same $reservation object - would still see
# every stage's *previous* launch cycle's resolved state and dispatch nothing at all. Found
# exactly this way, live: a restart's onContainerStart correctly reached this function, but the
# whole DAG then silently never dispatched anything, because _launch_deps_cleared/
# launch_maybe_dispatch's own 'pending' checks were reading stale, pre-reset state. A name left
# running (not reset) is correctly excluded from this sync too - its true current state is
# whatever the concurrent invocation that owns it last wrote, not something this process knows.
sub launch_reset_stages ($reservation) {
   my ( $written, $startCount ) = launch_reset_stages_if_idle(
      $reservation->id(), \@LAUNCH_STAGE_NAMES, $Reservation::HOOK_HISTORY_MAX );
   my $status = ( $reservation->{'data'}{'hooks'} //= {} )->{'status'} //= {};
   %$status = ( %$status, %$written );
   $reservation->{'data'}{'startCount'} = $startCount if defined $startCount;

   # A launch-version-0 profile's own launch.sh (Profile::ide_launch_version) predates the
   # launch:prep/launch:git split - it has no launch_prep/launch_git functions for those stages
   # to exec, only the single, older launch_ide that does all three stages' own work itself (see
   # launch:ide's dispatch above). Resolving both 'skipped' immediately, rather than leaving them
   # 'pending' to dispatch and fail against a function that doesn't exist, is what lets
   # _launch_deps_cleared('launch:ide') pass on launch_advance's very first pass.
   if ( $reservation->profileObject->ide_launch_version == 0 ) {
      launch_resolve_stage( $reservation, $_, 'skipped' ) for ( 'launch:prep', 'launch:git' );
   }
}

# True if this reservation's launch DAG still has work left. launch:ide is deliberately excluded
# once dispatched: unlike every other stage it never resolves in the happy path (it's the
# perpetual IDE process, not a script that exits) and has no dependents, so treating its ongoing
# 'running' state as "still needs attention" would mean every healthy devtainer stays flagged
# forever. Used only by EventDaemon::LaunchRecovery's restart_recovery_sweep/
# check_launch_recovering to decide which reservations need reconciling.
sub launch_in_flight ($reservation) {
   for my $name (@LAUNCH_STAGE_NAMES) {
      next if $name eq 'launch:ide';
      my $state = ( $reservation->hook_status($name) // {} )->{'state'} // 'pending';
      return 1 if $state eq 'pending' || $state eq 'running';
   }
   return 0;
}

# Advances this reservation's launch DAG by one scan: dispatches whatever's newly eligible
# ('pending' with its dependencies cleared - see _launch_deps_cleared). Deliberately does NOT
# poll anything 'running' - see this module's own header comment for why that's only ever
# needed once, at startup, not here. Each dispatch attempt is individually wrapped: a synchronous
# failure building one stage's request (an exception before any I/O even begins) must not stop
# the rest of this scan, and - since launch_advance is reached from asynchronous completion
# callbacks as often as from a synchronous caller - cannot rely on an outer try/catch existing
# at all.
sub launch_advance ($reservation) {
   for my $name (@LAUNCH_STAGE_NAMES) {
      my $status = $reservation->hook_status($name);
      my $state = ( $status // {} )->{'state'} // 'pending';

      next unless $state eq 'pending' && _launch_deps_cleared($reservation, $name);

      try {
         launch_maybe_dispatch($reservation, $name);
      }
      catch {
         flog("EventDaemon::LaunchDispatch::launch_advance: caught exception dispatching '$name' for reservationId=" . $reservation->id . ": " . (ref($_) ? $_->dbg : $_));
         launch_resolve_stage($reservation, $name, 'failed');
      };
   }
}

# Dispatches $stage if applicable, or resolves it 'skipped' (synchronous). Idempotency guard:
# with no forking, hook_status_started (called synchronously, before any async I/O begins, by
# _launch_dispatch_exec/_launch_dispatch_hook_stage below) is what makes a stage's 'running'
# status visible to *this same process* immediately - there is no IPC gap for a second,
# re-entrant launch_advance call (from this stage's own completion callback, or a differently-
# triggered call) to race against. This is a direct, structural consequence of there being
# only one process, not a guard bolted on afterward.
sub launch_maybe_dispatch ($reservation, $stage) {
   # Refuse all new dispatch once shutdown has begun, including the synchronous 'skipped' path
   # just below - not I/O-bound, but still new work this process shouldn't start.
   return if is_shutting_down();

   my $status = $reservation->hook_status($stage);
   return if $status && ( $status->{'state'} // '' ) ne 'pending';

   my $spec = $LAUNCH_STAGES{$stage};
   if ( $spec->{'applicable'} && !$spec->{'applicable'}->($reservation) ) {
      launch_resolve_stage( $reservation, $stage, 'skipped' );
      launch_advance($reservation);   # synchronous resolution - re-scan now for newly-eligible dependents
      return;
   }

   $spec->{'dispatch'}->( $reservation, sub { launch_advance($reservation); } );
}

# Dispatches a bare launch.sh entry-point function (launch:prep/launch:git/launch:ide - no hook
# name/script involved, unlike _launch_dispatch_hook_stage) via docker_exec, and records
# its outcome. Base env is _hook_env() (GIT_URL/SSH_KNOWN_HOSTS_DOMAINS/DOCKSIDE_OPTION_*/
# GH_TOKEN) plus ide_command_env() (the reservation's own IDE-record env) - both were already
# part of every launch before this split, for every stage that came from it. $opts:
#   detach     => 1        required for launch:ide specifically - dispatches via Detach:true and
#      returns immediately: only hook_status_started/hook_status_set_running_details ever get
#      called for it in the normal case, never launch_resolve_stage - it stays 'running'
#      indefinitely, either overwritten by the next restart's fresh dispatch or lazily
#      self-healed by the restart-recovery sweep.
#   extra_env  => [...]    "KEY=VALUE" strings specific to this stage, on top of the base env.
#   pending_fields => {...}   merged onto the entry hook_status_started records for this
#      dispatch - see _launch_dispatch_prep's own comment on 'pendingStartCount', its one
#      current use. Only meaningful for the non-Detach path: a field here is committed once
#      this entry resolves to 'done' (see Reservation::Mutate::_resolve_hook_entry), which
#      Detach's own entry never does in the normal case (see 'detach' above) - a Detach
#      caller uses increment_start_count below instead.
#   increment_start_count => 1   commit one start-count increment when a detached dispatch
#      confirms its start, under the same lock that verifies invocation ownership.
#   $cb->()    advances the DAG after this invocation resolves or confirms detached start.
#      A rejected ownership check suppresses the continuation.
sub _launch_dispatch_exec ($reservation, $stage, $function, $user, $opts, $cb) {
   my @Command = $reservation->ide_command();
   die Exception->new( 'msg' => 'Internal error - no IDE command configured', 'dbg' => 'EventDaemon::LaunchDispatch::_launch_dispatch_exec: ide_command() returned empty' ) unless @Command;
   $Command[-1] = $function;

   my $owner = $reservation->owner('username');
   my $userObj = User->load($owner);
   die Exception->new( 'msg' => "The owner of this devtainer ('$owner') no longer exists", 'status' => 400 ) unless $userObj;

   my @env = (
      ( map { my $e = $_; $e =~ s/^--env=//; $e } $reservation->_hook_env($userObj) ),
      ( map { my $e = $_; $e =~ s/^--env=//; $e } $reservation->ide_command_env() ),
      @{ $opts->{'extra_env'} // [] },
   );

   my $timeout = $CONFIG->{'hooks'}{'defaultTimeoutSeconds'} || 120;
   my $containerId = $reservation->containerId();

   # Each dispatch carries one token through exec creation and outcome resolution. Detached
   # dispatch presents it when confirming start, including any legacy start-count increment.
   my $invocationId = sprintf( "%08x", int( rand(0xffffffff) ) );

   # logPath: same convention as Reservation::dispatch_hook_exec (a host-side file under
   # tmpPath, named by reservation id + a random invocation id), so this stage's own output
   # becomes readable via the exact same load_hook_log($stage)/hook/status route that manually-
   # run hooks already use - no separate read path needed. Detach (launch:ide) is the one
   # exception: it's a perpetual, fire-and-forget process (see this sub's own header comment),
   # so there is no bounded "this invocation's output" to capture - undef here, as before.
   my ($log, $logPath);
   unless ( $opts->{'detach'} ) {
      $logPath = "$CONFIG->{'tmpPath'}/r-" . $reservation->id() . "-hook-$invocationId.log";
      open( $log, '>>', $logPath )
         or die Exception->new( 'dbg' => "EventDaemon::LaunchDispatch::_launch_dispatch_exec: cannot open log '$logPath': $!" );
      $log->autoflush(1);
   }

   # Synchronous, before any async I/O begins - see launch_maybe_dispatch's own comment on why
   # that alone is what makes a re-entrant launch_advance call safe.
   $reservation->hook_status_started($stage, $logPath,
      { %{ $opts->{'pending_fields'} // {} }, 'invocationId' => $invocationId });

   flog( "EventDaemon::LaunchDispatch::_launch_dispatch_exec: DISPATCHING '$stage' (via exec API): " . join( '|', map { sanitize_sensitive_text($_) } @Command ) );

   # Last synchronous step before docker_exec's own async call - see %DISPATCH_IN_FLIGHT's own
   # comment for why this placement (and the decrement's) is what makes the count reliable.
   $DISPATCH_IN_FLIGHT{$invocationId} = 1 unless $opts->{'detach'};

   docker_exec( $CONFIG->{'docker'}{'socket'}, $containerId, {
      'Cmd' => \@Command, 'User' => $user, 'Env' => \@env,
   }, {
      ( $opts->{'detach'}
         ? ( 'Detach' => 1 )
         : ( 'inactivity_timeout' => $timeout + 30, 'request_timeout' => $timeout ) ),
      'on_created' => sub ($execId) { $reservation->hook_status_set_running_details($stage, $execId, $invocationId); },
      ( $log ? ( 'on_output' => sub ($stream, $bytes) { print $log $bytes; } ) : () ),
   }, sub ($result, $err) {
      # Unconditional and first, outside the try/catch below - every exit path must decrement
      # exactly once, or the count could wedge shutdown forever with no timeout backstop.
      delete $DISPATCH_IN_FLIGHT{$invocationId} unless $opts->{'detach'};
      try {
         close($log) if $log;

         if ( !$result ) {
            flog("EventDaemon::LaunchDispatch::_launch_dispatch_exec: '$stage' failed to dispatch: $err");
            if ( launch_resolve_stage( $reservation, $stage, 'failed', $invocationId ) ) {
               $cb->();
            }
            return;
         }

         if ( $opts->{'detach'} ) {
            return unless $reservation->hook_status_dispatch_started(
               $stage, $invocationId, $opts->{'increment_start_count'} // 0 );
            $cb->();
            return;
         }

         my $rc = $result->{'exitCode'};
         my $timedOut = $result->{'timedOut'} ? 1 : 0;
         my $success = !$timedOut && defined($rc) && $rc == 0;

         # A 'pendingStartCount' passed via pending_fields, if any, is committed inside this
         # call - see Reservation::Mutate::_resolve_hook_entry. Detached dispatch instead
         # commits its increment when hook_status_dispatch_started confirms ownership.
         if ( launch_resolve_stage( $reservation, $stage,
               $timedOut ? 'timedOut' : ( $success ? 'done' : 'failed' ), $invocationId ) ) {
            $cb->();
         }
      }
      catch {
         flog("EventDaemon::LaunchDispatch::_launch_dispatch_exec: caught exception resolving '$stage': " . (ref($_) ? $_->dbg : $_));
         $cb->();
      };
   } );
}

# SSH-related env (only when this profile has ssh enabled at all) plus OWNER_DETAILS/
# SSH_AGENT_KEYS - shared by launch:prep and, for a launch-version-0 profile (Profile::
# ide_launch_version), the single combined legacy dispatch below: both ultimately feed the same
# root-privileged launch.sh setup (create_user/launch_sshd), just via a different entry-point
# function on the container side.
sub _launch_prep_env ($reservation, $userObj) {
   my @env;
   if ( $reservation->profileObject->ssh ) {
      my @developersMeta = split( ',', $reservation->meta('developers') );
      my @developers = grep { !/^role:/ } @developersMeta;
      my %developerRoles = map { s/^role://; ( $_ => 1 ); } grep { /^role:/ } @developersMeta;
      my @usersHavingDeveloperRoles = map { $developerRoles{ $_->{'role'} } ? $_->{'username'} : () } @{ User->viewers };
      my @usernames = unique(
         $reservation->owner('username'),
         $reservation->meta('access')->{'ssh'} eq 'developer' ? ( @developers, @usersHavingDeveloperRoles ) : ()
      );
      my @Users = map { User->load($_) } @usernames;
      my @authorized_keys = sort { $a cmp $b } unique map { $_ ? @{ $_->authorized_keys() } : () } @Users;
      push @env,
         "AUTHORIZED_KEYS=" . encode_json( \@authorized_keys ),
         "HOSTDATA_PATH=$CONFIG->{'ssh'}{'path'}",
         "SSHD_ENABLE=1";
   }
   push @env,
      "OWNER_DETAILS=" . encode_json( $userObj->details_full ),
      "SSH_AGENT_KEYS=" . encode_json( $userObj->keypairs_all() );

   return @env;
}

# launch:prep's own dispatch - not just a plain _launch_dispatch_exec call, because this stage
# carries two things specific to it alone: (1) _launch_prep_env's own SSH/owner env; (2)
# DOCKSIDE_START_COUNT's compute-before/persist-after-confirmed-success dance - computed here as
# a *prospective* value (purely informational for the container), attached to the dispatched
# entry as 'pendingStartCount' via pending_fields, and only ever committed to data.startCount
# once this entry actually resolves 'done' (see Reservation::Mutate::_resolve_hook_entry) -
# never on a failed or merely-attempted dispatch, which would otherwise burn a count on a
# launch that never actually happened, and never lost if something other than this dispatch's
# own continuation is what ends up resolving the entry (a restart-recovery/on-claim/reset-cycle
# heal finding it already finished, rather than this process's own docker_exec callback firing).
# This is exactly the moment data('startCount') becomes the value launch:git's own dispatch and
# the lifecycle:launch/lifecycle:start 'applicable' predicates read afterward - by the time
# either dispatches, launch:prep has already succeeded, so the count is already final.
sub _launch_dispatch_prep ($reservation, $cb) {
   my $owner = $reservation->owner('username');
   my $userObj = User->load($owner);
   die Exception->new( 'msg' => "The owner of this devtainer ('$owner') no longer exists", 'status' => 400 ) unless $userObj;

   my @env = _launch_prep_env( $reservation, $userObj );

   # Store before dispatch so the UI reflects the intended IDE immediately, including during
   # any retry window before the dispatch succeeds. Narrow store - see store_fields' own comment.
   $reservation->data( 'runningIDE', $reservation->meta('IDE') );
   $reservation->store_fields( { 'data' => { 'runningIDE' => $reservation->data('runningIDE') } } );

   # A *prospective* value, purely informational for the container - launch:prep dispatches at
   # most once per cycle (the same idempotency guard every launch:-stage gets), so nothing else
   # can be concurrently incrementing this reservation's startCount right now. Not the persisted
   # source of truth lifecycle:launch's own applicable() gate reads - see
   # Reservation::Mutate::update_running_hook's own comment for why that needs a genuine
   # read-under-lock, not a value computed here and stored later.
   my $startCount = ( $reservation->data('startCount') // 0 ) + 1;

   return _launch_dispatch_exec( $reservation, 'launch:prep', 'launch_prep', $ROOT_USER->($reservation), {
      'extra_env'      => [ @env, "DOCKSIDE_START_COUNT=$startCount" ],
      'pending_fields' => { 'pendingStartCount' => $startCount },
   }, $cb );
}

# launch:ide's dispatch for a launch-version-0 profile (Profile::ide_launch_version): a devtainer
# whose own launch.sh - never the outer's own, since this can only happen when mountIDE:false -
# has no launch:prep/launch:git/launch:ide split. Its single launch_ide entry point does all
# three stages' own work itself (create_user/launch_sshd, then git clone/checkout, then the
# actual IDE process), so this combines launch:prep's and launch:git's own env into the one
# call; both stages resolve 'skipped' without ever dispatching (see launch_reset_stages).
# Dispatched as root: this container's launch_ide starts with create_user itself, which needs
# root exactly as launch:prep does, unlike a slimmed-down launch_ide that only needs the
# nonroot user launch:prep already created.
#
# The count increment commits once dispatch starts (not once launch has finished) -
# see _launch_dispatch_exec's own comment on why Detach never resolves via a real exit code.
# There is no separate bounded stage to observe real completion on, since this container's own
# launch_ide covers everything in one perpetual call.
sub _launch_dispatch_legacy_ide ($reservation, $cb) {
   my $owner = $reservation->owner('username');
   my $userObj = User->load($owner);
   die Exception->new( 'msg' => "The owner of this devtainer ('$owner') no longer exists", 'status' => 400 ) unless $userObj;

   my @env = _launch_prep_env( $reservation, $userObj );
   my $startCount = ( $reservation->data('startCount') // 0 ) + 1;

   $reservation->data( 'runningIDE', $reservation->meta('IDE') );
   $reservation->store_fields( { 'data' => { 'runningIDE' => $reservation->data('runningIDE') } } );

   return _launch_dispatch_exec( $reservation, 'launch:ide', 'launch_ide', $ROOT_USER->($reservation), {
      'detach'     => 1,
      'extra_env'  => [
         @env,
         "DOCKSIDE_START_COUNT=$startCount",
         "DEVCONTAINER_VSCODE_EXTENSIONS=" . encode_json( $reservation->data('vscode') ),
         "IDE=" . $reservation->meta('IDE'),
      ],
      'increment_start_count' => 1,
   }, $cb );
}

# Dispatches $name (lifecycle:launch/lifecycle:start) - a thin wrapper around
# Reservation::dispatch_hook_exec (the one canonical async hook-dispatch core - see its
# own comment) that supplies this DAG stage's two callback points: on-claim-lost, defer to
# EventDaemon::LaunchRecovery (see its own comment) rather than resolving a stage that isn't
# ours; on-settled, translate the outcome into a launch_resolve_stage() call - deliberately not
# folded into hook_status_completed itself, since that's shared with genuinely on-demand
# invocations (including manual re-runs of these same two names via `dockside hook run`),
# which must never affect DAG state.
sub _launch_dispatch_hook_stage ($reservation, $name, $cb) {
   my $script = $reservation->hook_script($name);
   my $invocationId;

   $reservation->dispatch_hook_exec(
      $name, $script, {},
      sub ($claimedEntry) {
         if ($claimedEntry) {
            # dispatch_hook_exec's own claim - the invocationId this stage's own resolve, below,
            # must still hold when it settles.
            $invocationId = $claimedEntry->{'invocationId'};
            return;
         }
         flog( "EventDaemon::LaunchDispatch::_launch_dispatch_hook_stage: '$name' already claimed by a "
             . "concurrent on-demand invocation - deferring to EventDaemon::LaunchRecovery" );
         # Not exported/imported here deliberately - see this module's own header comment on
         # the asymmetric dependency between this module and EventDaemon::LaunchRecovery, which
         # itself needs launch_in_flight/launch_advance from here. EventDaemon::LaunchRecovery
         # is guaranteed loaded by the time this runs: the daemon script `use`s it at startup,
         # long before any dispatch happens.
         EventDaemon::LaunchRecovery::mark( $reservation->containerId );
         # The winner owns completion. The recovery tick reloads its status before advancing
         # dependents; calling $cb here would recurse against this object's pending entry.
      },
      sub ( $outcome, $err ) {
         # A second, independently-necessary fence on the same invocation:
         # dispatch_hook_exec's own resolve (recording the generic 'done'/'aborted' outcome this
         # $outcome is derived from) already fenced on this same invocationId and can itself have
         # been rejected; this call re-maps that outcome into the DAG's own 'done'/'failed'/
         # 'timedOut' vocabulary and must not apply that mapping - or drive $cb's re-scan - for a
         # claim this invocation no longer holds either.
         if ( launch_resolve_stage( $reservation, $name, $outcome // 'failed', $invocationId ) ) {
            $cb->();
         }
      }
   );
}

1;
