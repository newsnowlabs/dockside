use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use Exception;
use File::Temp qw(tempdir);
use JSON qw(encode_json decode_json);
use Mojo::IOLoop;
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

sub entry { return read_record()->{'data'}{'hooks'}{'status'}{'myhook'} }

# Runs the event loop until $cond holds or $limit seconds pass. Retries of a failed outcome write
# are scheduled on the loop, so nothing past the first attempt is observable without this.
sub pump_until ( $cond, $limit = 5 ) {
   return if $cond->();
   my $deadline = Mojo::IOLoop->timer( $limit => sub { Mojo::IOLoop->stop } );
   my $poll = Mojo::IOLoop->recurring( 0.005 => sub { Mojo::IOLoop->stop if $cond->() } );
   Mojo::IOLoop->start;
   Mojo::IOLoop->remove($_) for $deadline, $poll;
   return;
}

# Runs one full dispatch with the stubs installed for as long as $opt{'body'} needs them - which
# outlives dispatch_hook_exec itself, since a retried write happens on a later loop tick.
#
# %opt: 'result'/'err' are what the exec transport reports; 'failing' is a scalar ref the test
# raises and lowers to make outcome writes throw; 'write_failures' fails that many leading writes
# and then stops; 'fence' makes every write report itself rejected; 'on_settled' replaces the
# recording callback; 'body' receives the recorded state while the stubs are still live.
sub dispatch (%opt) {
   open my $fh, '>', $Data::CONFIG->{reservationsPath} or die $!;
   print $fh encode_json({ id => 'rid', name => 'devt', data => {} }), "\n";
   close $fh;

   my $r = bless { id => 'rid', name => 'devt', containerId => 'cid' }, 'Reservation';
   my $state = { 'settled' => [], 'claimed' => [], 'writes' => [], 'dispatches' => 0 };
   my $countdown = $opt{'write_failures'} // 0;
   my $failing = $opt{'failing'};

   no warnings qw(redefine once);
   local *Reservation::ide_command = sub { return ( '/opt/dockside/bin/launch.sh', 'placeholder' ) };
   local *Reservation::owner       = sub { return 'someone' };
   local *Reservation::unixuser    = sub { return 'devuser' };
   local *Reservation::_hook_env   = sub { return () };
   local *User::load               = sub { return bless {}, 'User' };

   local *Reservation::docker_exec = sub ( $socket, $containerId, $args, $opts, $cb ) {
      $state->{'dispatches'}++;
      $cb->( $opt{'result'}, $opt{'err'} );
   };

   # Records what the obligation looked like at the moment each write was attempted - the whole
   # point of the ordering under test.
   local *Reservation::hook_status_completed = sub ( $self, @args ) {
      push @{ $state->{'writes'} },
         { 'in_flight' => Reservation->hook_dispatch_in_flight_count(), 'fields' => $args[1] };
      my $shouldFail = $failing ? $$failing : ( $countdown-- > 0 );
      die Exception->new( 'dbg' => 'fixture write failure' ) if $shouldFail;
      return 0 if $opt{'fence'};
      return $REAL_COMPLETED->( $self, @args );
   };

   eval {
      $r->dispatch_hook_exec( 'myhook', '/hook.sh', {},
         sub (@a) { push @{ $state->{'claimed'} }, [@a] },
         $opt{'on_settled'} // sub (@a) { push @{ $state->{'settled'} }, [@a] } );
      1;
   } or $state->{'error'} = $@;

   $state->{'in_flight_after_dispatch'} = Reservation->hook_dispatch_in_flight_count();
   $opt{'body'}->($state) if $opt{'body'};
   return $state;
}

subtest 'the obligation is still held while the outcome is being written' => sub {
   my $run = dispatch( 'result' => { 'execId' => 'e', 'exitCode' => 0, 'timedOut' => 0 } );

   is( scalar @{ $run->{'writes'} }, 1, 'the outcome is written once' );
   is( $run->{'writes'}[0]{'in_flight'}, 1,
      'the dispatch is still counted in flight at the moment its outcome is written' );
   is( $run->{'in_flight_after_dispatch'}, 0, 'and released once that write has landed' );
   is( scalar @{ $run->{'settled'} }, 1, 'the caller is notified exactly once' );
   is( $run->{'settled'}[0][0], 'done', 'the notified outcome is the resolved state' );
   is( entry()->{'state'}, 'done', 'the outcome is persisted' );
   is( entry()->{'exitCode'}, 0, 'with its exit code' );
};

subtest 'an outcome that will not write keeps the dispatch counted in flight' => sub {
   my $failing = 1;
   dispatch(
      'result'  => { 'execId' => 'e', 'exitCode' => 0, 'timedOut' => 0 },
      'failing' => \$failing,
      'body'    => sub ($run) {
         is( $run->{'in_flight_after_dispatch'}, 1,
            'the obligation survives a write that threw' );

         # Long enough for several scheduled retries, all of which fail.
         pump_until( sub { scalar @{ $run->{'writes'} } >= 4 }, 3 );

         cmp_ok( scalar @{ $run->{'writes'} }, '>=', 4, 'the write keeps being retried' );
         is( $run->{'dispatches'}, 1, 'the hook itself is never run again' );
         is( Reservation->hook_dispatch_in_flight_count(), 1,
            'a drain evaluating this count cannot conclude the hook has settled' );
         is( scalar @{ $run->{'settled'} }, 0,
            'and the caller is not told of a settlement that has not happened' );
         is( entry()->{'state'}, 'running', 'nothing terminal is recorded' );

         # The failure clears; the very next retry must settle it and let the drain finish.
         $failing = 0;
         pump_until( sub { Reservation->hook_dispatch_in_flight_count() == 0 }, 3 );

         is( Reservation->hook_dispatch_in_flight_count(), 0,
            'the obligation is released once the outcome is finally written' );
         is( scalar @{ $run->{'settled'} }, 1, 'the caller is notified exactly once, on settlement' );
         is( $run->{'settled'}[0][0], 'done', 'with the real outcome' );
         is( $run->{'dispatches'}, 1, 'still without ever rerunning the hook' );
         is( entry()->{'state'}, 'done', 'and the outcome reaches disk' );
      },
   );
};

subtest 'a retried write replays the original result rather than re-deriving one' => sub {
   dispatch(
      'result'         => { 'execId' => 'e', 'exitCode' => 3, 'timedOut' => 0 },
      'write_failures' => 1,
      'body'           => sub ($run) {
         pump_until( sub { Reservation->hook_dispatch_in_flight_count() == 0 }, 3 );

         is( scalar @{ $run->{'writes'} }, 2, 'the write is retried after it threw' );
         is( $run->{'writes'}[1]{'fields'}{'exitCode'}, 3, 'the retry replays the original result' );
         is( $run->{'writes'}[0]{'in_flight'}, 1, 'held for the first attempt' );
         is( $run->{'writes'}[1]{'in_flight'}, 1, 'still held for the retry' );
         is( scalar @{ $run->{'settled'} }, 1, 'the caller is notified exactly once' );
         is( entry()->{'exitCode'}, 3, 'with the original exit code persisted' );
      },
   );
};

subtest 'a write fenced by a newer invocation is released silently, not retried' => sub {
   my $run = dispatch(
      'result' => { 'execId' => 'e', 'exitCode' => 0, 'timedOut' => 0 },
      'fence'  => 1,
   );

   is( scalar @{ $run->{'writes'} }, 1, 'a rejected write is not a failed write, so it is not retried' );
   is( scalar @{ $run->{'settled'} }, 0,
      'a superseded invocation reports nothing, as hook_status_completed already specifies' );
   is( $run->{'in_flight_after_dispatch'}, 0,
      'the obligation is released - there is no outcome of this invocation left to record' );
};

subtest 'a dispatch that never ran reports aborted, not the less specific failed' => sub {
   my $run = dispatch( 'result' => undef, 'err' => 'container is gone' );

   is( scalar @{ $run->{'settled'} }, 1, 'the caller is notified exactly once' );
   is( $run->{'settled'}[0][0], 'aborted', 'the reported outcome stays aborted' );
   like( $run->{'settled'}[0][1], qr/container is gone/, 'the dispatch error is passed through' );
   is( entry()->{'state'}, 'aborted', 'and is what gets persisted' );
   is( $run->{'in_flight_after_dispatch'}, 0, 'the obligation is released' );
};

subtest 'a completion consumer that throws is not invoked a second time' => sub {
   my $calls = 0;
   my $run = dispatch(
      'result'     => { 'execId' => 'e', 'exitCode' => 0, 'timedOut' => 0 },
      'on_settled' => sub (@) { $calls++; die "consumer failure\n" },
   );

   is( $calls, 1, 'the consumer is called exactly once, never re-entered by error handling' );
   is( $run->{'in_flight_after_dispatch'}, 0,
      'the obligation was already released before the consumer ran, so its exception cannot leak it' );
   is( entry()->{'state'}, 'done', 'the outcome remains persisted' );
   like( $run->{'error'}, qr/consumer failure/, 'the consumer exception belongs to the caller' );
};

subtest 'retry delays start immediate and then back off to a ceiling' => sub {
   is( Reservation::_hook_persist_retry_delay(1), 0, 'the first retry is immediate' );
   is( Reservation::_hook_persist_retry_delay(2), 0, 'so is the second' );
   cmp_ok( Reservation::_hook_persist_retry_delay(3), '>', 0, 'later retries wait' );
   cmp_ok( Reservation::_hook_persist_retry_delay(4), '>',
           Reservation::_hook_persist_retry_delay(3), 'and the wait grows' );
   is( Reservation::_hook_persist_retry_delay(99), $Reservation::HOOK_PERSIST_RETRY_CEILING,
      'without growing without bound' );
};

done_testing;
