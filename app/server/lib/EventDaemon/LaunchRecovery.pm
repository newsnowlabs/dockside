# Tracks and re-polls a reservation whose launch-DAG stage was left 'running' with no completion
# callback anywhere left to resolve it on its own - either because the docker-event-daemon
# process that owned that callback has died (a restart), or because it lost a claim on
# lifecycle:launch/lifecycle:start to a concurrent on-demand invocation of the same name.
#
# containerId => 1, seeded by restart_recovery_sweep, for a reservation whose launch was still
# genuinely in-flight (a real, live exec, not yet actually finished) at the exact moment this
# daemon process started - never added during ordinary operation otherwise, where every live
# dispatch's own completion callback is the sole, sufficient resolver (see
# EventDaemon::LaunchDispatch's own header comment on why per-tick polling is otherwise
# unnecessary). Not just a theoretical case: restart_recovery_sweep's own hook_is_running
# self-heal check correctly does nothing when a stage's exec really is still running (it must
# not falsely resolve a genuinely live exec) - but the process that owned that exec's completion
# callback is gone, permanently, and no Docker event exists that the daemon treats as "an exec
# finished, go check on it" (docker events' own exec_die carries no reservation/stage context).
# Left unaddressed, such a stage stays 'running' forever even after its real exec genuinely
# completes. check_launch_recovering re-checks every entry here until launch_in_flight() says
# there's nothing left to recover, then drops it - scoped to this one, self-limiting case.
#
# Second, ordinary-operation seeding source: EventDaemon::LaunchDispatch's own
# _launch_dispatch_hook_stage, when its own hook_claim_if_not_running loses the claim on
# lifecycle:launch/lifecycle:start to a concurrent on-demand run_hook_manual invocation of the
# same name (the only two DAG stage names externally reachable that way). The daemon isn't the
# owner of that dispatch's completion in this case, so it can't rely on its own completion
# callback the way every other stage can - the same "who resolves this" gap the restart case
# has, just triggered by losing a race instead of by a process restart. Reusing this mechanism
# rather than inventing a second one: the reconciliation loop's own logic (re-check until
# settled, then drop) is identical either way.
package EventDaemon::LaunchRecovery;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw(mark clear_recovering check_launch_recovering restart_recovery_sweep);

use Try::Tiny;

use Util qw(flog);
use Data;
use Reservation;
use EventDaemon::LaunchDispatch qw(launch_in_flight launch_advance @LAUNCH_STAGE_NAMES);

my %launchRecovering;

# Seeds $containerId for tick-driven recovery - see this module's own header comment for the
# two cases that call this (a lost claim, or restart_recovery_sweep below finding a stage still
# in flight after its own first self-heal pass).
sub mark ($containerId) {
   $launchRecovering{$containerId} = 1;
}

# Clears any stale entry from a previous, unrelated launch cycle for the same container -
# called by EventDaemon::ContainerSync::onContainerStart when a genuine new start event
# supersedes whatever a previous restart's still-unfinished recovery sweep was tracking for this
# containerId. Not clearing this is harmless in outcome (check_launch_recovering's own
# reload-and-check would just find this fresh cycle's own stages and no-op once they resolve)
# but wasteful and confusing to reason about - it would keep re-checking a reservation for an
# entirely unrelated launch cycle until that one, coincidentally, also finished.
sub clear_recovering ($containerId) {
   delete $launchRecovering{$containerId};
}

# Re-checks any reservation still genuinely in-flight after restart_recovery_sweep's own first
# pass, or newly enqueued by a lost lifecycle-hook claim - see this module's own header comment
# for why this, and only this, case needs per-tick polling under the async model. Self-limiting:
# each entry removes itself the moment launch_in_flight() says there's nothing left to recover.
# Called once per eventHandler tick; self-contained, owns its own try/catch.
sub check_launch_recovering {
   return unless %launchRecovering;
   try {
      for my $cid (keys %launchRecovering) {
         Data::load('config.json', 'users.json', 'roles.json', 'reservations.json', 'containers.json');
         my $reservations = Reservation->load({ 'containerId' => $cid });
         if (!@$reservations) {
            delete $launchRecovering{$cid};
            next;
         }

         my $reservation = $reservations->[0];
         try {
            for my $name (@LAUNCH_STAGE_NAMES) {
               my $state = ( $reservation->hook_status($name) // {} )->{'state'} // 'pending';
               $reservation->hook_is_running($name) if $state eq 'running';
            }
            launch_advance($reservation);
         }
         catch {
            flog("EventDaemon::LaunchRecovery::check_launch_recovering: caught exception reconciling reservationId=" . $reservation->id . ": " . (ref($_) ? $_->dbg : $_));
         };

         delete $launchRecovering{$cid} unless launch_in_flight($reservation);
      }
   }
   catch {
      flog("EventDaemon::LaunchRecovery::check_launch_recovering: caught exception: " . (ref($_) ? $_->dbg : $_));
   };
}

# Restart-recovery: a launch stage left 'running' in hooks.status belonged to a dispatch of the
# *previous* docker-event-daemon process - that process is gone, so there is no completion
# callback left anywhere that will ever resolve it on its own (see EventDaemon::LaunchDispatch's
# own header comment for why every *other* case resolves via its own callback, guaranteed, by
# construction). Seeds from every reservation whose DAG isn't fully settled, self-heals any
# 'running' stage via the existing hook_is_running check where its exec has genuinely already
# finished, then runs launch_advance to pick up wherever the DAG can now continue.
#
# Not necessarily settled by this one pass: hook_is_running correctly does nothing when a
# stage's exec is still genuinely running - it must not falsely resolve a live exec - but that
# leaves it exactly as orphaned as before (no callback anywhere will ever notice it finish, so
# restarting the daemon mid-dispatch alone would otherwise leave a stage stuck 'running'
# indefinitely, well after its real exec had actually completed). %launchRecovering (see this
# module's own header comment) is what covers this: seeded here for anything still in-flight
# after this first pass, then check_launch_recovering re-checks it until settled. Called once per
# daemon *process* lifetime by the top-level script, not once per eventHandler restart.
sub restart_recovery_sweep {
   try {
      Data::load('config.json', 'users.json', 'roles.json', 'reservations.json', 'containers.json');
      my $allReservations = Reservation->load();
      my @inFlight = grep { launch_in_flight($_) } @$allReservations;
      flog(sprintf("EventDaemon::LaunchRecovery::restart_recovery_sweep: %d of %d reservation(s) have a launch still in progress...", scalar @inFlight, scalar @$allReservations));
      for my $reservation (@inFlight) {
         try {
            for my $name (@LAUNCH_STAGE_NAMES) {
               my $state = ( $reservation->hook_status($name) // {} )->{'state'} // 'pending';
               $reservation->hook_is_running($name) if $state eq 'running';   # self-heals in place if dead
            }
            launch_advance($reservation);
            mark( $reservation->containerId ) if launch_in_flight($reservation);
         }
         catch {
            flog("EventDaemon::LaunchRecovery::restart_recovery_sweep: caught exception reconciling reservationId=" . $reservation->id . ": " . (ref($_) ? $_->dbg : $_));
         };
      }
      flog(sprintf("EventDaemon::LaunchRecovery::restart_recovery_sweep: %d reservation(s) still in flight after the first pass; on_tick will keep re-checking them", scalar keys %launchRecovering)) if %launchRecovering;
   }
   catch {
      flog("EventDaemon::LaunchRecovery::restart_recovery_sweep: sweep failed (non-fatal): " . (ref($_) ? $_->dbg : $_));
   };
}

1;
