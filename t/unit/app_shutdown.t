use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Util qw(flog);
use File::Temp qw(tempdir);
use App::Shutdown;
use Test::More;

# App::Shutdown's latch is module-level and one-way, and its drain runs against whatever
# configure() last installed, so this file is order-dependent in two ways. The unconfigured case
# comes first, because nothing can un-configure the module afterwards; everything the latch
# affects comes last, because nothing can clear it.

my $tmp = tempdir(CLEANUP => 1);
flog({ file => "$tmp/log" });

# Test-owned drain environment: a clock that only the injected tick advances, an obligations
# structure the tick mutates, a collector each subtest resets before it starts, and an accept
# limit the hold reads and sets.
my $now = 0;
my %obligations;
my @logged;
my $ticks = 0;
my $limit = 10000;

sub install_environment (%overrides) {
   $now    = 0;
   $ticks  = 0;
   @logged = ();
   $limit  = 10000;
   App::Shutdown::configure(
      # A ceiling of 20 with App::Shutdown's own 10s margin leaves a 10s wait, which is what the
      # subtests below that do not override it count ticks against.
      'ceiling'      => 20,
      'obligations'  => sub () { return \%obligations; },
      'clock'        => sub () { return $now; },
      'log'          => sub ($message) { push @logged, $message; },
      'accept_limit' => sub (@set) { $limit = $set[0] if @set; return $limit; },

      # One second per tick, settling one obligation - creates first, then hooks - which is the
      # only thing that ever makes the drain's predicate progress here.
      'tick' => sub () {
         $ticks++;
         $now += 1;
         shift @{ $obligations{'creates'} } or shift @{ $obligations{'hooks'} };
         return;
      },
      %overrides,
   );
   return;
}

subtest 'drain and hold before configure name configure in their own failure' => sub {
   my $died = !eval { App::Shutdown::drain(); 1 };
   ok($died, 'drain refuses to run against an unconfigured module');
   like($@, qr/configure/, 'the message names configure, so the caller knows what is missing');

   $died = !eval { App::Shutdown::hold(); 1 };
   ok($died, 'hold refuses to run against an unconfigured module');
   like($@, qr/configure/, 'and its message names configure too');
};

subtest 'drain with nothing in flight returns immediately' => sub {
   %obligations = ( 'creates' => [], 'hooks' => [] );
   install_environment();

   my $remaining = App::Shutdown::drain();

   is($ticks, 0, 'no tick is run when there is nothing to wait for');
   is_deeply($remaining, { 'creates' => [], 'hooks' => [] }, 'the remainder is empty');
   is(scalar @logged, 1, 'exactly one line is logged');
   like($logged[0], qr/nothing in flight; exiting/, 'and it reports an immediate exit');
};

subtest 'drain returns as soon as the obligations clear' => sub {
   %obligations = ( 'creates' => [ 'r-two', 'r-one' ], 'hooks' => ['h-one'] );
   install_environment();

   my $remaining = App::Shutdown::drain();

   is($ticks, 3, 'one tick per obligation, and none after the last one settled');
   is_deeply($remaining, { 'creates' => [], 'hooks' => [] }, 'nothing is left outstanding');
   is(scalar @logged, 2, 'a start line and a finish line');
   like($logged[0], qr/waiting up to 10s for 2 create chain\(s\) \(r-two, r-one\)/,
      'the start line counts the creates and names them');
   like($logged[0], qr/1 hook run\(s\) \(h-one\)/, 'and counts the hooks and names them');
   like($logged[1], qr/drained every in-flight create chain and hook run after 3s; exiting/,
      'the finish line reports a complete drain and how long it took');
};

subtest 'drain gives up once the clock passes the ceiling, less the margin' => sub {
   %obligations = ( 'creates' => ['r-stuck'], 'hooks' => [ 'h-stuck', 'h-also-stuck' ] );
   install_environment(
      # A tick that advances the clock without ever settling anything, so only the deadline can
      # end the wait.
      'tick' => sub () { $ticks++; $now += 1; return; },
   );

   my $remaining = App::Shutdown::drain();

   is($ticks, 10, 'the wait runs for the ceiling less the margin and no longer');
   is_deeply($remaining, { 'creates' => ['r-stuck'], 'hooks' => [ 'h-stuck', 'h-also-stuck' ] },
      'everything still in flight is handed back to the caller');
   like($logged[-1], qr/reached its shutdown ceiling after 10s with 1 create chain\(s\) \(r-stuck;/,
      'the final line counts and names the creates left behind');
   like($logged[-1], qr/2 hook run\(s\) \(h-stuck, h-also-stuck;/,
      'and counts and names the hook runs left behind');
};

subtest 'a finite ceiling stops the drain a margin short of the ceiling itself' => sub {
   %obligations = ( 'creates' => ['r-stuck'], 'hooks' => ['h-stuck'] );
   install_environment(
      'ceiling' => 100,
      'tick'    => sub () { $ticks++; $now += 1; return; },
   );

   my $remaining = App::Shutdown::drain();

   is($now, 100 - $App::Shutdown::MARGIN, 'the wait ends at the ceiling less the margin');
   is($ticks, 90, 'and having ticked once per second up to that point');
   is_deeply($remaining, { 'creates' => ['r-stuck'], 'hooks' => ['h-stuck'] },
      'what never settled is handed back');
   like($logged[0], qr/waiting up to 90s for /, 'the start line quotes the wait, not the ceiling');
   like($logged[-1], qr/reached its shutdown ceiling after 90s with 1 create chain\(s\) \(r-stuck;/,
      'the ceiling line names the create left behind');
   like($logged[-1], qr/1 hook run\(s\) \(h-stuck;/, 'and the hook run left behind');
};

subtest 'a ceiling no larger than the margin leaves no time to wait at all' => sub {
   for my $ceiling ( $App::Shutdown::MARGIN, 5 ) {
      %obligations = ( 'creates' => ['r-stuck'], 'hooks' => [] );
      install_environment(
         'ceiling' => $ceiling,
         'tick'    => sub () { $ticks++; $now += 1; return; },
      );

      my $remaining = App::Shutdown::drain();

      is($ticks, 0, "a ceiling of $ceiling runs no tick");
      is_deeply($remaining, { 'creates' => ['r-stuck'], 'hooks' => [] },
         "a ceiling of $ceiling hands everything back");
      like($logged[0], qr/waiting up to 0s for /, "a ceiling of $ceiling announces no wait");
      like($logged[-1], qr/reached its shutdown ceiling after 0s with 1 create chain\(s\) \(r-stuck;/,
         "a ceiling of $ceiling reports the create left behind straight away");
   }
};

subtest 'an unlimited ceiling waits for as long as the obligations take' => sub {
   %obligations = ( 'creates' => ['r-slow'], 'hooks' => [] );
   install_environment(
      'ceiling' => undef,

      # Settles only after a wait far longer than any finite ceiling this file uses, so a drain
      # that quietly kept a bound of its own would end early and fail here.
      'tick' => sub () {
         $ticks++;
         $now += 1;
         @{ $obligations{'creates'} } = () if $ticks >= 500;
         return;
      },
   );

   my $remaining = App::Shutdown::drain();

   is($ticks, 500, 'the drain ticks on well past 100s of clock');
   is_deeply($remaining, { 'creates' => [], 'hooks' => [] }, 'and returns with nothing left');
   like($logged[0], qr/waiting without limit for 1 create chain\(s\) \(r-slow\)/,
      'the start line says the wait is unbounded and names what it waits for');
   like($logged[-1], qr/drained every in-flight create chain and hook run after 500s; exiting/,
      'the finish line reports the full wait');
};

subtest 'a long drain reports its progress on the log interval' => sub {
   %obligations = ( 'creates' => ['r-stuck'], 'hooks' => [ 'h-stuck', 'h-also-stuck' ] );
   install_environment(
      'ceiling' => 100,
      'tick'    => sub () { $ticks++; $now += 1; return; },
   );

   App::Shutdown::drain();

   my @progress = grep { /draining for/ } @logged;
   is(scalar @progress, 3, 'a 90s wait reports progress three times on a 30s interval');
   like($progress[$_ - 1], qr/\Aapp-server: worker $$ draining for @{[ $_ * $App::Shutdown::LOG_INTERVAL ]}s; /,
      "progress line $_ lands on the interval") for 1 .. 3;
   like($progress[0], qr/still waiting for 1 create chain\(s\) \(r-stuck\) and 2 hook run\(s\) \(h-stuck, h-also-stuck\)/,
      'each progress line carries the counts and ids by kind');
};

subtest 'a drain that settles as it crosses the interval reports no further wait' => sub {
   %obligations = ( 'creates' => [], 'hooks' => ['h-last'] );
   install_environment(
      'ceiling' => 100,
      # Settles the one obligation on the tick that lands the clock exactly on the interval.
      'tick'    => sub () {
         $ticks++;
         $now += 1;
         @{ $obligations{'hooks'} } = () if $now == $App::Shutdown::LOG_INTERVAL;
         return;
      },
   );

   App::Shutdown::drain();

   is(scalar( grep { /draining for/ } @logged ), 0,
      'nothing is reported as still waited for once nothing is');
   like($logged[-1], qr/drained every in-flight create chain and hook run after 30s; exiting/,
      'the finish line follows the settling tick directly');
};

subtest 'the graceful timeout given to the manager follows the ceiling' => sub {
   is(App::Shutdown::graceful_timeout_for(undef), $App::Shutdown::UNLIMITED_GRACEFUL_TIMEOUT,
      'no configured ceiling is expressed as the one-day backstop');
   is(App::Shutdown::graceful_timeout_for(300), 300,
      'a finite ceiling is handed to the manager unchanged');
};

subtest 'only ids are ever read out of the obligations structure' => sub {
   %obligations = ( 'creates' => ['r-one'], 'hooks' => [], 'secret' => 'DECOY' );
   install_environment();

   my $remaining = App::Shutdown::drain();

   is_deeply($remaining, { 'creates' => [], 'hooks' => [] },
      'the remainder carries the two known kinds and nothing else');
   unlike($_, qr/DECOY/, 'no log line carries anything beyond the ids') for @logged;

   # A drain long enough to report progress and then hit its ceiling renders the obligations
   # structure on every one of those lines, so it is checked separately from the short run above.
   %obligations = ( 'creates' => ['r-one'], 'hooks' => [], 'secret' => 'DECOY' );
   install_environment(
      'ceiling' => 100,
      'tick'    => sub () { $ticks++; $now += 1; return; },
   );

   App::Shutdown::drain();

   ok(scalar( grep { /draining for/ } @logged ), 'the long drain did report progress');
   unlike($_, qr/DECOY/, 'no line of a long drain carries anything beyond the ids') for @logged;
};

subtest 'the first hold stops the accept count and the last release restores it' => sub {
   install_environment();

   my $first = App::Shutdown::hold();
   is($limit, 0, 'the first hold reads the limit and sets 0');
   my $second = App::Shutdown::hold();
   is($limit, 0, 'a second hold changes nothing');
   $first->();
   is($limit, 0, 'the first release changes nothing while a hold remains');
   $second->();
   is($limit, 10000, 'the last release restores the limit that was read');
};

subtest 'a release sub releases once' => sub {
   install_environment();

   my $first  = App::Shutdown::hold();
   my $second = App::Shutdown::hold();
   $first->();
   $first->();
   is($limit, 0, 'a second call of one release sub does not release the other hold');
   $second->();
   is($limit, 10000, 'the other hold release restores the limit');
};

subtest 'holds and releases interleaved settle to the limit read' => sub {
   install_environment();

   my $a = App::Shutdown::hold();
   my $b = App::Shutdown::hold();
   $a->();
   my $c = App::Shutdown::hold();
   $b->();
   is($limit, 0, 'one hold outstanding keeps the count stopped');
   $c->();
   is($limit, 10000, 'none outstanding restores the limit read by the first');

   $limit = 5000;
   my $d = App::Shutdown::hold();
   is($limit, 0, 'a hold taken after a full release stops the count again');
   $d->();
   is($limit, 5000, 'and its release restores the limit as it then stood');

   $limit = 0;
   my $e = App::Shutdown::hold();
   $e->();
   is($limit, 0, 'a limit of 0, the count already stopped, is kept and restored as 0');
};

subtest 'admit accepts every kind while the worker is still serving' => sub {
   @logged = ();
   ok(!App::Shutdown::is_shutting_down(), 'the worker is not shutting down yet');
   ok(App::Shutdown::admit('create'),    'a create is admitted');
   ok(App::Shutdown::admit('hook'),      'a hook run is admitted');
   ok(App::Shutdown::admit('reconcile'), 'a reconcile pass is admitted');
   is(scalar @logged, 0, 'an admitted request logs nothing');
};

subtest 'the shutdown latch is one-way' => sub {
   ok(App::Shutdown::begin_shutdown(), 'the first caller starts the shutdown');
   ok(App::Shutdown::is_shutting_down(), 'the latch is set');
   ok(!App::Shutdown::begin_shutdown(), 'a repeated shutdown request is turned away');
   ok(App::Shutdown::is_shutting_down(), 'and leaves the latch set');
};

subtest 'admit refuses every kind once the shutdown has begun' => sub {
   @logged = ();

   ok(!App::Shutdown::admit('create'), 'a create is refused');
   is(scalar @logged, 1, 'exactly one line is logged for it');
   like($logged[0], qr/refusing create: worker $$ is shutting down/, 'naming the kind refused');

   ok(!App::Shutdown::admit('hook'), 'a hook run is refused');
   is(scalar @logged, 2, 'exactly one further line is logged for it');
   like($logged[1], qr/refusing hook: worker $$ is shutting down/, 'naming that kind too');

   # The gate is unconditional on the kind: a kind this test has never named before is refused
   # identically, so a gate accidentally wired to a list of known kinds would fail here.
   ok(!App::Shutdown::admit('reconcile'), 'a reconcile pass is refused');
   is(scalar @logged, 3, 'and logged once, like the others');
   like($logged[2], qr/refusing reconcile: worker $$ is shutting down/, 'naming that kind too');
};

done_testing;
