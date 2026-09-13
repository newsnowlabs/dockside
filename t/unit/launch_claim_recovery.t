use v5.36;
use FindBin;
use Test::More;

# Evaluate the dispatch wrapper without the daemon's file-scope Docker I/O and event loop.
open my $fh, '<', "$FindBin::Bin/../../app/server/bin/docker-event-daemon" or die $!;
my $source = do { local $/; <$fh> };
my ($wrapper) = $source =~ /(sub _launch_dispatch_hook_stage .*?)\n# Pure, synchronous merge/s;
die 'Cannot locate launch hook wrapper' unless $wrapper;
my $run = eval 'use v5.36; my %launchRecovering; sub flog {} ' . $wrapper . q{
   sub ($reservation, $cb) {
      _launch_dispatch_hook_stage($reservation, 'lifecycle:launch', $cb);
      return { %launchRecovering };
   }
};
die $@ if $@;

{
   package LostClaim;
   sub hook_script { 'true' }
   sub containerId { 'test-container' }
   sub dispatch_hook_exec { $_[4]->(undef) }
}

my $callbacks = 0;
my $recovering = $run->(bless({}, 'LostClaim'), sub { $callbacks++ });
is($callbacks, 0, 'losing a claim yields without a synchronous DAG continuation');
is_deeply($recovering, { 'test-container' => 1 }, 'winner is tracked for tick-driven recovery');
done_testing;
