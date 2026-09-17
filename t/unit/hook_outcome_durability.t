use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use Exception;
use File::Temp qw(tempdir);
use JSON qw(encode_json decode_json);
use Test::More;

# A finished invocation's %HOOK_DISPATCH_IN_FLIGHT obligation is what a draining worker waits on,
# so these tests care about exactly when it is released relative to the outcome reaching disk.
# Only the exec transport and the environment lookups around it are stubbed; the claim, the
# settlement helper, the fencing and the database writes are all real.
my $tmp = tempdir(CLEANUP => 1);
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused' }, hooks => { defaultTimeoutSeconds => 5 },
};
Util::flog({ file => "$tmp/test.log" });

my $REAL_COMPLETED = \&Reservation::hook_status_completed;

sub read_record {
   open my $fh, '<', $Data::CONFIG->{reservationsPath} or die $!;
   local $/;
   my $text = <$fh>;
   return length($text) ? decode_json($text) : undef;
}

# Runs one full dispatch. %opt: 'result'/'err' are what the exec transport reports; 'write_failures'
# makes that many leading outcome writes throw; 'fence' makes every write report itself rejected;
# 'on_settled' replaces the recording callback.
sub dispatch (%opt) {
   open my $fh, '>', $Data::CONFIG->{reservationsPath} or die $!;
   print $fh encode_json({ id => 'rid', name => 'devt', data => {} }), "\n";
   close $fh;

   my $r = bless { id => 'rid', name => 'devt', containerId => 'cid' }, 'Reservation';
   my ( @settled, @claimed, @writes );
   my $dispatches = 0;
   my $failures = $opt{'write_failures'} // 0;

   no warnings qw(redefine once);
   local *Reservation::ide_command = sub { return ( '/opt/dockside/bin/launch.sh', 'placeholder' ) };
   local *Reservation::owner       = sub { return 'someone' };
   local *Reservation::unixuser    = sub { return 'devuser' };
   local *Reservation::_hook_env   = sub { return () };
   local *User::load               = sub { return bless {}, 'User' };

   local *Reservation::docker_exec = sub ( $socket, $containerId, $args, $opts, $cb ) {
      $dispatches++;
      $cb->( $opt{'result'}, $opt{'err'} );
   };

   # Records what the obligation looked like at the moment each write was attempted - the whole
   # point of the ordering under test.
   local *Reservation::hook_status_completed = sub ( $self, @args ) {
      push @writes, { 'in_flight' => Reservation->hook_dispatch_in_flight_count(), 'fields' => $args[1] };
      die Exception->new( 'dbg' => 'fixture write failure' ) if $failures-- > 0;
      return 0 if $opt{'fence'};
      return $REAL_COMPLETED->( $self, @args );
   };

   my $error;
   eval {
      $r->dispatch_hook_exec( 'myhook', '/hook.sh', {},
         sub (@a) { push @claimed, [@a] },
         $opt{'on_settled'} // sub (@a) { push @settled, [@a] } );
      1;
   } or $error = $@;

   return {
      'settled'         => \@settled,
      'claimed'         => \@claimed,
      'writes'          => \@writes,
      'dispatches'      => $dispatches,
      'error'           => $error,
      'in_flight_after' => Reservation->hook_dispatch_in_flight_count(),
      'entry'           => read_record()->{'data'}{'hooks'}{'status'}{'myhook'},
   };
}

subtest 'the obligation is still held while the outcome is being written' => sub {
   my $run = dispatch( 'result' => { 'execId' => 'e', 'exitCode' => 0, 'timedOut' => 0 } );

   is( scalar @{ $run->{'writes'} }, 1, 'the outcome is written once' );
   is( $run->{'writes'}[0]{'in_flight'}, 1,
      'the dispatch is still counted in flight at the moment its outcome is written' );
   is( $run->{'in_flight_after'}, 0, 'and released once that write has landed' );
   is( scalar @{ $run->{'settled'} }, 1, 'the caller is notified exactly once' );
   is( $run->{'settled'}[0][0], 'done', 'the notified outcome is the resolved state' );
   is( $run->{'entry'}{'state'}, 'done', 'the outcome is persisted' );
   is( $run->{'entry'}{'exitCode'}, 0, 'with its exit code' );
};

subtest 'a failed outcome write is retried with the same result and no redispatch' => sub {
   my $run = dispatch(
      'result' => { 'execId' => 'e', 'exitCode' => 3, 'timedOut' => 0 },
      'write_failures' => 1,
   );

   is( $run->{'dispatches'}, 1, 'the hook itself is never run again' );
   is( scalar @{ $run->{'writes'} }, 2, 'the write is retried after it threw' );
   is( $run->{'writes'}[1]{'fields'}{'exitCode'}, 3,
      'the retry replays the original result rather than re-deriving one' );
   is( $run->{'writes'}[0]{'in_flight'}, 1, 'held for the first attempt' );
   is( $run->{'writes'}[1]{'in_flight'}, 1, 'still held for the retry' );
   is( $run->{'in_flight_after'}, 0, 'released once the retry lands' );
   is( scalar @{ $run->{'settled'} }, 1, 'the caller is still notified exactly once' );
   is( $run->{'entry'}{'state'}, 'done', 'the outcome reaches disk via the retry' );
   is( $run->{'entry'}{'exitCode'}, 3, 'with the original exit code' );
};

subtest 'an unwritable outcome still releases the obligation, so a drain cannot hang' => sub {
   my $attempts = Reservation::_HOOK_PERSIST_ATTEMPTS();
   my $run = dispatch(
      'result' => { 'execId' => 'e', 'exitCode' => 0, 'timedOut' => 0 },
      'write_failures' => $attempts + 5,
   );

   is( $run->{'dispatches'}, 1, 'the hook is never run again' );
   is( scalar @{ $run->{'writes'} }, $attempts, 'the write is attempted a bounded number of times' );
   is( $run->{'in_flight_after'}, 0,
      'the obligation is released even though the outcome could not be recorded' );
   is( scalar @{ $run->{'settled'} }, 1, 'the caller is notified exactly once' );
   ok( !defined( $run->{'settled'}[0][0] ), 'with no outcome to report' );
   ok( defined( $run->{'settled'}[0][1] ), 'and the write failure as the error' );
   is( $run->{'entry'}{'state'}, 'running',
      'the entry is left for the documented self-heal to resolve from its exec' );
   ok( !defined( $run->{'error'} ), 'the write failure never escapes to the dispatch caller' );
};

subtest 'a write fenced by a newer invocation is released silently, not retried' => sub {
   my $run = dispatch(
      'result' => { 'execId' => 'e', 'exitCode' => 0, 'timedOut' => 0 },
      'fence'  => 1,
   );

   is( scalar @{ $run->{'writes'} }, 1, 'a rejected write is not a failed write, so it is not retried' );
   is( scalar @{ $run->{'settled'} }, 0,
      'a superseded invocation reports nothing, as hook_status_completed already specifies' );
   is( $run->{'in_flight_after'}, 0, 'the obligation is still released' );
};

subtest 'a dispatch that never ran reports aborted, not the less specific failed' => sub {
   my $run = dispatch( 'result' => undef, 'err' => 'container is gone' );

   is( scalar @{ $run->{'settled'} }, 1, 'the caller is notified exactly once' );
   is( $run->{'settled'}[0][0], 'aborted', 'the reported outcome stays aborted' );
   like( $run->{'settled'}[0][1], qr/container is gone/, 'the dispatch error is passed through' );
   is( $run->{'entry'}{'state'}, 'aborted', 'and is what gets persisted' );
   is( $run->{'in_flight_after'}, 0, 'the obligation is released' );
};

subtest 'a completion consumer that throws is not invoked a second time' => sub {
   my $calls = 0;
   my $run = dispatch(
      'result'     => { 'execId' => 'e', 'exitCode' => 0, 'timedOut' => 0 },
      'on_settled' => sub (@) { $calls++; die "consumer failure\n" },
   );

   is( $calls, 1, 'the consumer is called exactly once, never re-entered by error handling' );
   is( $run->{'in_flight_after'}, 0,
      'the obligation was already released before the consumer ran, so its exception cannot leak it' );
   is( $run->{'entry'}{'state'}, 'done', 'the outcome remains persisted' );
   like( $run->{'error'}, qr/consumer failure/, 'the consumer exception belongs to the caller' );
};

done_testing;
