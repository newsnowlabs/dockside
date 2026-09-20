# bin/app-server's graceful-exit gate: the one-way shutting-down latch every admission check
# consults, and the drain that gives this worker's in-flight obligations a chance to settle
# before the process exits. Owned here rather than as a bin/app-server lexical so the
# latch is reachable from any route's own closure without threading a variable through it, and
# so the drain loop itself is exercisable without a reactor.
#
# Deliberately free of any Mojo dependency: everything time-, reactor- and log-shaped is injected
# by configure() below. bin/app-server supplies the production implementations (Mojo::Util's
# steady_time, a reactor tick, the loop's accept limit, Util::flog); a test supplies a synthetic
# clock, tick and limit and collects the log lines. The module knows only that a tick may make
# progress, that the clock advances monotonically and that a limit of 0 stops the loop counting
# accepts.
package App::Shutdown;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw(configure begin_shutdown is_shutting_down admit drain graceful_timeout_for hold);

# Seconds by which a drain under a finite ceiling stops short of the ceiling itself. The manager
# kills the worker at the ceiling regardless; stopping this much earlier is what lets the worker
# log what it leaves behind and exit cleanly rather than be killed mid-line. A ceiling of this
# much or less therefore leaves no time to wait at all.
our $MARGIN = 10;

# Seconds between the drain's own progress lines, so a wait long enough to be worth asking about
# is visible in the log while it is happening rather than only once it ends.
our $LOG_INTERVAL = 30;

# The graceful_timeout, in seconds, given to Mojo::Server::Prefork when no ceiling is configured.
# Prefork's ceiling is a number compared against a stamp, so a drain with no configured limit
# still needs one, and this is a backstop rather than a bound the drain plans around: no hook
# run limit or Docker call is expected to approach a day. It is one day rather than something
# larger because Prefork also treats a worker whose heartbeat has gone silent as a graceful
# stop and kills it at this same ceiling, so a worker hung while serving is reaped a day after
# Prefork marks it (about a minute after its heartbeat stops) instead of leaking until the
# container restarts. A drain that does outlast it - a hook whose own run limit exceeds a day -
# is killed at it: 'unlimited' means no configured ceiling, not the absence of one.
our $UNLIMITED_GRACEFUL_TIMEOUT = 86400;

# The injected environment, set once by configure() before any worker forks, so every worker
# inherits the same one. Empty until then, which drain() treats as a programming error rather
# than a condition to work around.
my %ENVIRONMENT;

# Set by the first begin_shutdown() call and never cleared: this worker is on its way out, so
# admit() refuses every new obligation from here on and drain() runs exactly once. A refused
# request is answered immediately by its own route; nothing is queued for later.
my $SHUTTING_DOWN = 0;

# Keys: ceiling (seconds after which the manager kills this worker, or undef for an unlimited
# drain), obligations (a sub returning { creates => [ids], hooks => [ids] }), clock (a sub
# returning monotonic seconds), tick (a sub running one round of whatever makes those obligations
# progress), log (a sub taking one message), accept_limit (a sub returning the loop's accept
# limit when called with no argument and setting it when called with one).
sub configure (%opts) {
   %ENVIRONMENT = %opts;
   return;
}

# Holds against this worker being recycled, and the loop's accept limit as it stood before the
# first of them was taken. Mojo::Server::Prefork replaces a worker once its loop has accepted the
# worker's quota of connections, by having the loop stop gracefully. A hold keeps the loop from
# counting accepts, so the worker cannot be recycled from under whatever holds it.
my $HOLDS = 0;
my $KEPT_LIMIT;

# Takes a hold and returns a sub that releases it. The first hold reads the loop's accept limit,
# keeps it and sets 0, which stops the loop counting accepts; the last release restores what was
# kept, and the count the loop had already begun resumes where it stood, so a worker past its
# quota stops gracefully at its next accept, after the chain. A release sub releases once; a
# later call does nothing.
sub hold () {
   die "App::Shutdown::hold called before configure\n" unless $ENVIRONMENT{'accept_limit'};
   if ( $HOLDS++ == 0 ) {
      $KEPT_LIMIT = $ENVIRONMENT{'accept_limit'}->();
      $ENVIRONMENT{'accept_limit'}->(0);
   }
   my $released = 0;
   return sub () {
      return if $released++;
      $ENVIRONMENT{'accept_limit'}->($KEPT_LIMIT) if --$HOLDS == 0;
      return;
   };
}

# The graceful_timeout to give Mojo::Server::Prefork for a worker draining under $ceiling. Both
# come from the one configured value, so the bound the manager enforces and the bound the worker
# drains against can never disagree.
sub graceful_timeout_for ($ceiling) {
   return defined($ceiling) ? $ceiling : $UNLIMITED_GRACEFUL_TIMEOUT;
}

# One-way latch. True for the caller that actually starts the shutdown, false for every later
# caller, so a repeated shutdown request (a second QUIT re-emits the event that drives this) is a
# no-op rather than a second full drain stacked on the first.
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

# Waits for the configured obligations to clear - without limit under an undefined ceiling,
# otherwise up to the ceiling less $MARGIN - ticking between checks and reporting progress every
# $LOG_INTERVAL. Returns whatever is still outstanding as a { creates => [], hooks => [] }
# hashref - empty lists when everything settled. Only the ids of the two known kinds are ever
# read out of the obligations structure, and only those ids ever reach the log.
sub drain () {
   die "App::Shutdown::drain called before configure\n" unless %ENVIRONMENT;

   my $outstanding = _outstanding();
   unless ( @{ $outstanding->{'creates'} } || @{ $outstanding->{'hooks'} } ) {
      _log("app-server: worker $$ has nothing in flight; exiting");
      return $outstanding;
   }

   my $ceiling = $ENVIRONMENT{'ceiling'};
   my $start   = $ENVIRONMENT{'clock'}->();
   my $budget  = defined($ceiling) ? ( $ceiling > $MARGIN ? $ceiling - $MARGIN : 0 ) : undef;
   my $deadline = defined($budget) ? $start + $budget : undef;
   my $nextLog  = $start + $LOG_INTERVAL;

   _log( "app-server: worker $$ is shutting down; " .
      ( defined($budget) ? "waiting up to ${budget}s" : 'waiting without limit' ) . ' for ' .
      _describe($outstanding) . ' to settle' );

   while ( ( @{ $outstanding->{'creates'} } || @{ $outstanding->{'hooks'} } )
      && ( !defined($deadline) || $ENVIRONMENT{'clock'}->() < $deadline ) )
   {
      $ENVIRONMENT{'tick'}->();
      $outstanding = _outstanding();

      # Only while something remains: a tick that settles the last obligation as it crosses the
      # interval has nothing left to report waiting for, and the finish line below follows at once.
      if ( ( @{ $outstanding->{'creates'} } || @{ $outstanding->{'hooks'} } )
         && $ENVIRONMENT{'clock'}->() >= $nextLog )
      {
         _log( sprintf( 'app-server: worker %d draining for %ds; still waiting for %s',
            $$, $ENVIRONMENT{'clock'}->() - $start, _describe($outstanding) ) );

         # Advanced past the clock rather than by one interval, so a single tick that blocked for
         # several intervals reports the wait once, at its true length, not once per interval it
         # spanned.
         $nextLog += $LOG_INTERVAL while $nextLog <= $ENVIRONMENT{'clock'}->();
      }
   }

   # Whole seconds: the injected clock is monotonic but not necessarily integral, and these lines
   # report how long the wait took, not a measurement anything computes from.
   my $elapsed          = int( $ENVIRONMENT{'clock'}->() - $start );
   my $remainingCreates = scalar @{ $outstanding->{'creates'} };
   my $remainingHooks   = scalar @{ $outstanding->{'hooks'} };
   if ( $remainingCreates || $remainingHooks ) {
      # A create chain left here is recovered by create()'s own startup sweep/periodic
      # reconciler; hooks have no equivalent beyond hook_is_running's own lazy self-heal on a
      # later read (narrower still for lifecycle:launch/lifecycle:start, which
      # docker-event-daemon's own sweep does re-poll).
      _log( "app-server: worker $$ reached its shutdown ceiling after ${elapsed}s with " .
         "$remainingCreates create chain(s) (" . _ids( $outstanding->{'creates'} ) .
         "; recovered by the startup sweep/periodic reconciler) and " .
         "$remainingHooks hook run(s) (" . _ids( $outstanding->{'hooks'} ) .
         "; recovered only lazily, if at all) still in flight" );
   }
   else {
      _log( "app-server: worker $$ drained every in-flight create chain and hook run " .
         "after ${elapsed}s; exiting" );
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
