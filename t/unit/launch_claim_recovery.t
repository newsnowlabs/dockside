use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Util qw(flog);
use File::Temp qw(tempdir);
use EventDaemon::LaunchDispatch;
use EventDaemon::LaunchRecovery;
use Test::More;

my $tmp = tempdir(CLEANUP => 1);
flog({ file => "$tmp/log" });

{
   package LostClaim;
   sub hook_script { 'true' }
   sub containerId { 'test-container' }
   sub dispatch_hook_exec { $_[4]->(undef) }   # simulates a lost claim: on_claimed(undef)
}

subtest 'losing a claim registers for recovery without a synchronous continuation' => sub {
   my @marked;
   no warnings 'redefine';
   local *EventDaemon::LaunchRecovery::mark = sub { push @marked, $_[0]; };

   my $callbacks = 0;
   EventDaemon::LaunchDispatch::_launch_dispatch_hook_stage(
      bless({}, 'LostClaim'), 'lifecycle:launch', sub { $callbacks++ });
   is($callbacks, 0, 'losing a claim yields without a synchronous DAG continuation');
   is_deeply(\@marked, ['test-container'], 'winner is tracked for tick-driven recovery');
};

subtest 'the real recovery tick finds and drops an unmanaged lost claim' => sub {
   # Unmocked EventDaemon::LaunchRecovery::mark/check_launch_recovering - only the reservation
   # lookup they drive is stubbed, so this exercises the real tracking hash and tick logic
   # rather than just confirming mark() was reached (which would still pass even if mark()
   # became a no-op).
   my $loads = 0;
   no warnings 'redefine';
   local *Reservation::load = sub { $loads++; return []; };   # nothing is ever managed
   local *Data::load = sub { };

   my $callbacks = 0;
   EventDaemon::LaunchDispatch::_launch_dispatch_hook_stage(
      bless({}, 'LostClaim'), 'lifecycle:launch', sub { $callbacks++ });
   is($callbacks, 0, 'losing a claim yields without a synchronous DAG continuation');

   EventDaemon::LaunchRecovery::check_launch_recovering();
   is($loads, 1, 'the real recovery tick looks the lost claim up exactly once');

   EventDaemon::LaunchRecovery::check_launch_recovering();
   is($loads, 1, 'an unmanaged reservation is dropped after its first tick, not re-checked');
};

done_testing;
