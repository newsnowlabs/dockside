use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Util qw(flog);
use File::Temp qw(tempdir);
use EventDaemon::LaunchDispatch;
use Test::More;

# begin_shutdown() is deliberately one-way (see its own comment - this process is exiting, not
# pausing), so this file tests both sides of it in one place, in the only order that makes
# sense: everything that must still work *before* shutdown, then the shutdown itself, then
# everything that must be refused *after* it. Order matters here in a way it doesn't in most
# test files.

my $tmp = tempdir(CLEANUP => 1);
flog({ file => "$tmp/log" });

{
   package TouchReservation;
   # No methods beyond what each subtest below stubs in - if launch_maybe_dispatch's own
   # shutdown gate ever stopped being the very first thing it checks, a test here would fail
   # loudly (either the call count would be wrong, or a missing-method exception would fire),
   # not silently.
}

subtest 'launch_maybe_dispatch reaches the reservation normally before shutdown' => sub {
   my $calls = 0;
   no warnings qw(redefine once);
   local *TouchReservation::hook_status = sub { $calls++; return { state => 'running' }; };
   ok(!EventDaemon::LaunchDispatch::is_shutting_down(), 'not shutting down yet');
   EventDaemon::LaunchDispatch::launch_maybe_dispatch( bless( {}, 'TouchReservation' ), 'launch:prep' );
   is($calls, 1, 'the reservation was consulted normally before any shutdown was requested');
};

subtest 'launch_maybe_dispatch refuses all new dispatch once shutdown has begun' => sub {
   my $calls = 0;
   no warnings qw(redefine once);
   local *TouchReservation::hook_status = sub { $calls++; return { state => 'running' }; };

   EventDaemon::LaunchDispatch::begin_shutdown();
   ok(EventDaemon::LaunchDispatch::is_shutting_down(), 'flag set');

   EventDaemon::LaunchDispatch::launch_maybe_dispatch( bless( {}, 'TouchReservation' ), 'launch:prep' );
   is($calls, 0, 'the reservation was never even consulted once shutdown had begun');

   # Confirmed against a second, different stage too - the gate is unconditional, not
   # per-stage, so this isn't redundant with the case above: a gate accidentally wired to only
   # one stage's own applicability check would pass the test above and fail this one.
   local *TouchReservation::profileObject = sub { die "should never be reached\n"; };
   EventDaemon::LaunchDispatch::launch_maybe_dispatch( bless( {}, 'TouchReservation' ), 'launch:git' );
   is($calls, 0, 'a second, dependency-bearing stage is refused identically (hook_status still never called)');
};

done_testing;
