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
# structure the tick mutates, and a collector each subtest resets before it starts.
my $now = 0;
my %obligations;
my @logged;
my $ticks = 0;

sub install_environment (%overrides) {
   $now    = 0;
   $ticks  = 0;
   @logged = ();
   App::Shutdown::configure(
      'grace'       => 10,
      'obligations' => sub () { return \%obligations; },
      'clock'       => sub () { return $now; },
      'log'         => sub ($message) { push @logged, $message; },

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

subtest 'drain before configure names configure in its own failure' => sub {
   my $died = !eval { App::Shutdown::drain(); 1 };
   ok($died, 'drain refuses to run against an unconfigured module');
   like($@, qr/configure/, 'the message names configure, so the caller knows what is missing');
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
   like($logged[1], qr/drained every in-flight create chain and hook run; exiting/,
      'the finish line reports a complete drain');
};

subtest 'drain gives up once the clock passes the grace deadline' => sub {
   %obligations = ( 'creates' => ['r-stuck'], 'hooks' => [ 'h-stuck', 'h-also-stuck' ] );
   install_environment(
      # A tick that advances the clock without ever settling anything, so only the deadline can
      # end the wait.
      'tick' => sub () { $ticks++; $now += 1; return; },
   );

   my $remaining = App::Shutdown::drain();

   is($ticks, 10, 'the wait runs for the full grace period and no longer');
   is_deeply($remaining, { 'creates' => ['r-stuck'], 'hooks' => [ 'h-stuck', 'h-also-stuck' ] },
      'everything still in flight is handed back to the caller');
   like($logged[-1], qr/reached its 10s shutdown grace period with 1 create chain\(s\) \(r-stuck;/,
      'the final line counts and names the creates left behind');
   like($logged[-1], qr/2 hook run\(s\) \(h-stuck, h-also-stuck;/,
      'and counts and names the hook runs left behind');
};

subtest 'only ids are ever read out of the obligations structure' => sub {
   %obligations = ( 'creates' => ['r-one'], 'hooks' => [], 'secret' => 'DECOY' );
   install_environment();

   my $remaining = App::Shutdown::drain();

   is_deeply($remaining, { 'creates' => [], 'hooks' => [] },
      'the remainder carries the two known kinds and nothing else');
   unlike($_, qr/DECOY/, 'no log line carries anything beyond the ids') for @logged;
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
