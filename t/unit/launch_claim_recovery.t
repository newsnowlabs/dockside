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

my @marked;
no warnings 'redefine';
local *EventDaemon::LaunchRecovery::mark = sub { push @marked, $_[0]; };

my $callbacks = 0;
EventDaemon::LaunchDispatch::_launch_dispatch_hook_stage(
   bless({}, 'LostClaim'), 'lifecycle:launch', sub { $callbacks++ });
is($callbacks, 0, 'losing a claim yields without a synchronous DAG continuation');
is_deeply(\@marked, ['test-container'], 'winner is tracked for tick-driven recovery');
done_testing;
