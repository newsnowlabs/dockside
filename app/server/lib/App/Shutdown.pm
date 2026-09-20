# bin/app-server's graceful-exit gate: the one-way shutting-down latch every admission check
# consults, and the bounded drain that gives this worker's in-flight obligations a chance to
# settle before the process exits. Owned here rather than as a bin/app-server lexical so the
# latch is reachable from any route's own closure without threading a variable through it, and
# so the drain loop itself is exercisable without a reactor.
#
# Deliberately free of any Mojo dependency: everything time-, reactor- and log-shaped is injected
# by configure() below. bin/app-server supplies the production implementations (Mojo::Util's
# steady_time, a reactor tick, Util::flog); a test supplies a synthetic clock and tick and
# collects the log lines. The module knows only that a tick may make progress and that the clock
# advances monotonically.
package App::Shutdown;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw(configure begin_shutdown is_shutting_down admit drain);

# The injected environment, set once by configure() before any worker forks, so every worker
# inherits the same one. Empty until then, which drain() treats as a programming error rather
# than a condition to work around.
my %ENVIRONMENT;

# Set by the first begin_shutdown() call and never cleared: this worker is on its way out, so
# admit() refuses every new obligation from here on and drain() runs exactly once. A refused
# request is answered immediately by its own route; nothing is queued for later.
my $SHUTTING_DOWN = 0;

# Keys: grace (seconds the drain may wait), obligations (a sub returning
# { creates => [ids], hooks => [ids] }), clock (a sub returning monotonic seconds), tick (a sub
# running one round of whatever makes those obligations progress), log (a sub taking one message).
sub configure (%opts) {
   %ENVIRONMENT = %opts;
   return;
}

# One-way latch. True for the caller that actually starts the shutdown, false for every later
# caller, so a repeated shutdown request (a second QUIT re-emits the event that drives this) is a
# no-op rather than a second full grace period stacked on the first.
sub begin_shutdown () {
   return 0 if $SHUTTING_DOWN;
   $SHUTTING_DOWN = 1;
   return 1;
}

sub is_shutting_down () { return $SHUTTING_DOWN; }

# The admission gate for work this worker would otherwise still be carrying when it exits.
# $kind is a short word naming what is being admitted ('create', 'hook'), used in the refusal
# log line; the caller renders its own response.
sub admit ($kind) {
   return 1 unless $SHUTTING_DOWN;
   _log("app-server: refusing $kind: worker $$ is shutting down");
   return 0;
}

# Waits, up to the configured grace period, for the configured obligations to clear, ticking
# between checks. Returns whatever is still outstanding as a { creates => [], hooks => [] }
# hashref - empty lists when everything settled. Only the ids of the two known kinds are ever
# read out of the obligations structure, and only those ids ever reach the log.
sub drain () {
   die "App::Shutdown::drain called before configure\n" unless %ENVIRONMENT;

   my $outstanding = _outstanding();
   unless ( @{ $outstanding->{'creates'} } || @{ $outstanding->{'hooks'} } ) {
      _log("app-server: worker $$ has nothing in flight; exiting");
      return $outstanding;
   }

   my $grace    = $ENVIRONMENT{'grace'};
   my $deadline = $ENVIRONMENT{'clock'}->() + $grace;

   _log( "app-server: worker $$ is shutting down; waiting up to ${grace}s for " .
      _describe($outstanding) . " to settle" );

   while ( ( @{ $outstanding->{'creates'} } || @{ $outstanding->{'hooks'} } )
      && $ENVIRONMENT{'clock'}->() < $deadline )
   {
      $ENVIRONMENT{'tick'}->();
      $outstanding = _outstanding();
   }

   my $remainingCreates = scalar @{ $outstanding->{'creates'} };
   my $remainingHooks   = scalar @{ $outstanding->{'hooks'} };
   if ( $remainingCreates || $remainingHooks ) {
      # A create chain left here is recovered by create()'s own startup sweep/periodic
      # reconciler; hooks have no equivalent beyond hook_is_running's own lazy self-heal on a
      # later read (narrower still for lifecycle:launch/lifecycle:start, which
      # docker-event-daemon's own sweep does re-poll).
      _log( "app-server: worker $$ reached its ${grace}s shutdown grace period with " .
         "$remainingCreates create chain(s) (" . _ids( $outstanding->{'creates'} ) .
         "; recovered by the startup sweep/periodic reconciler) and " .
         "$remainingHooks hook run(s) (" . _ids( $outstanding->{'hooks'} ) .
         "; recovered only lazily, if at all) still in flight" );
   }
   else {
      _log("app-server: worker $$ drained every in-flight create chain and hook run; exiting");
   }

   return $outstanding;
}

# The two known kinds, copied out into a structure of this module's own - whatever else the
# supplied obligations structure carries is never read, never logged and never returned.
sub _outstanding () {
   my $obligations = $ENVIRONMENT{'obligations'}->() // {};
   return {
      'creates' => [ @{ $obligations->{'creates'} // [] } ],
      'hooks'   => [ @{ $obligations->{'hooks'}   // [] } ],
   };
}

sub _describe ($outstanding) {
   return sprintf( '%d create chain(s) (%s) and %d hook run(s) (%s)',
      scalar @{ $outstanding->{'creates'} }, _ids( $outstanding->{'creates'} ),
      scalar @{ $outstanding->{'hooks'} },   _ids( $outstanding->{'hooks'} ) );
}

sub _ids ($ids) { return @$ids ? join( ', ', @$ids ) : 'none'; }

sub _log ($message) {
   my $log = $ENVIRONMENT{'log'} or return;
   $log->($message);
   return;
}

1;
