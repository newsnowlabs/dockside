use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use User;
use Exception;
use Util qw(format_caught_error);
use File::Temp qw(tempdir);
use JSON qw(encode_json decode_json);
use Mojo::IOLoop;
use Test::More;

# A finished invocation's %HOOK_DISPATCH_IN_FLIGHT obligation is what a draining worker waits on,
# so these tests care about exactly when it is released relative to the outcome write being
# decided. Only the exec transport and the environment lookups around it are stubbed; the claim,
# the settlement helper, the fencing and the database writes are all real.
my $tmp = tempdir(CLEANUP => 1);
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused' }, hooks => { defaultTimeoutSeconds => 5 },
};
Util::flog({ file => "$tmp/test.log" });

my $REAL_COMPLETED = \&Reservation::hook_status_completed;

# Minimal stand-in for the exec-inspection response hook_is_running reads, which needs only these
# two accessors.
{
   package ExecInspect;
   use v5.36;
   sub new ($class, %fields) { return bless { %fields }, $class }
   sub is_success ($self) { return $self->{'is_success'} }
   sub body ($self) { return $self->{'body'} }
}

sub read_record {
   open my $fh, '<', $Data::CONFIG->{reservationsPath} or die $!;
   local $/;
   my $text = <$fh>;
   return length($text) ? decode_json($text) : undef;
}

sub entry { return read_record()->{'data'}{'hooks'}{'status'}{'myhook'} }

# The on-disk record as a fresh Reservation, for a read path (hook_is_running) that must see the
# entry as it stands rather than a caller's in-memory copy of it.
sub reloaded { return bless { %{ read_record() } }, 'Reservation' }

# Runs the event loop until $cond holds or $limit seconds pass. Used to give any work a settle
# path might have scheduled on the loop a chance to run before asserting that none was.
sub pump_until ( $cond, $limit = 5 ) {
   return if $cond->();
   my $deadline = Mojo::IOLoop->timer( $limit => sub { Mojo::IOLoop->stop } );
   my $poll = Mojo::IOLoop->recurring( 0.005 => sub { Mojo::IOLoop->stop if $cond->() } );
   Mojo::IOLoop->start;
   Mojo::IOLoop->remove($_) for $deadline, $poll;
   return;
}

sub log_text {
   open my $fh, '<', "$tmp/test.log" or die $!;
   local $/;
   return scalar <$fh>;
}

# Runs one full dispatch with the stubs installed for as long as $opt{'body'} needs them, so a
# body can keep observing the settle path - and drive further reads through it - while they hold.
#
# %opt: 'result'/'err' are what the exec transport reports, and a 'result' carrying an execId also
# reports that execId through docker_exec's own on_created callback, as the real transport does;
# 'failing' is a scalar ref the test raises and lowers to make outcome writes throw; 'fence' makes
# every write report itself rejected; 'prep_fails' fails the invocation before any exec is
# dispatched; 'on_settled' replaces the recording callback; 'body' receives the recorded state
# while the stubs are still live.
sub dispatch (%opt) {
   open my $fh, '>', $Data::CONFIG->{reservationsPath} or die $!;
   print $fh encode_json({ id => 'fab1e', name => 'devt', data => {} }), "\n";
   close $fh;

   my $r = bless { id => 'fab1e', name => 'devt', containerId => 'cid' }, 'Reservation';
   my $state = { 'settled' => [], 'claimed' => [], 'writes' => [], 'dispatches' => 0 };
   my $failing = $opt{'failing'};

   no warnings qw(redefine once);
   # An empty ide_command is what dispatch_hook_exec's own preparation step rejects, so this
   # fails before any exec is dispatched while still leaving a claim that owes an outcome.
   local *Reservation::ide_command = $opt{'prep_fails'}
      ? sub { return () }
      : sub { return ( '/opt/dockside/bin/launch.sh', 'placeholder' ) };
   local *Reservation::owner       = sub { return 'someone' };
   local *Reservation::unixuser    = sub { return 'devuser' };
   local *Reservation::_hook_env   = sub { return () };
   local *User::load               = sub { return bless {}, 'User' };

   local *Reservation::docker_exec = sub ( $socket, $containerId, $args, $opts, $cb ) {
      $state->{'dispatches'}++;
      my $execId = ( $opt{'result'} // {} )->{'execId'};
      $opts->{'on_created'}->($execId) if defined $execId;
      $cb->( $opt{'result'}, $opt{'err'} );
   };

   # Records what the obligation looked like at the moment each write was attempted - the whole
   # point of the ordering under test.
   local *Reservation::hook_status_completed = sub ( $self, @args ) {
      push @{ $state->{'writes'} },
         { 'in_flight' => Reservation->hook_dispatch_in_flight_count(), 'fields' => $args[1] };
      die Exception->new( 'dbg' => 'fixture write failure' ) if $failing && $$failing;
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

subtest 'an outcome write that throws releases the obligation and leaves the entry running' => sub {
   my $failing = 1;
   my ( $writes_after_pump, $in_flight_after_pump );

   my $run = dispatch(
      'result'  => { 'execId' => 'e', 'exitCode' => 0, 'timedOut' => 0 },
      'failing' => \$failing,
      'body'    => sub ($state) {
         # Nothing should be scheduled on the loop by a write that threw; running it for a
         # moment with the fixture still installed is what makes a second attempt observable
         # if one were.
         pump_until( sub { scalar @{ $state->{'writes'} } > 1 }, 0.5 );
         $writes_after_pump    = scalar @{ $state->{'writes'} };
         $in_flight_after_pump = Reservation->hook_dispatch_in_flight_count();
      },
   );

   is( $run->{'in_flight_after_dispatch'}, 0,
      'the obligation is released even though the outcome never reached disk' );
   is( $in_flight_after_pump, 0, 'and stays released, so a drain can complete' );
   is( $writes_after_pump, 1, 'exactly one write is attempted, with no second scheduled' );
   is( $run->{'dispatches'}, 1, 'the hook itself is run once' );
   is( scalar @{ $run->{'settled'} }, 1, 'the caller is notified exactly once' );
   is( $run->{'settled'}[0][0], undef, 'with no settlement state, since none was recorded' );
   like( format_caught_error( $run->{'settled'}[0][1] ), qr/fixture write failure/,
      'and the error that stopped the write' );
   is( entry()->{'state'}, 'running', 'the entry is left running for a later reader to settle' );
   is( entry()->{'execId'}, 'e', 'with the execId that reader needs to ask Docker about' );

   # Matched against the settle path's own lines rather than the whole log, so an identifier that
   # also appears in a dispatch line (the hook's log path carries the invocation id) cannot stand
   # in for the one line this is about.
   my $invocationId = $run->{'claimed'}[0][0]{'invocationId'};
   my @logged = grep { /_hook_settle_outcome/ } split( /\n/, log_text() );
   is( scalar @logged, 1, 'the unwritten outcome is reported once in the service log' );
   like( $logged[0] // '', qr/reservationId=fab1e/, 'against its reservation' );
   like( $logged[0] // '', qr/'myhook'/,          'naming the hook' );
   like( $logged[0] // '', qr/\Q$invocationId\E/, 'and the invocation whose outcome is unrecorded' );
};

subtest 'the next reader settles an unwritten outcome from Docker' => sub {
   # Each case needs its own dispatch: the read under test resolves the entry, so a second read
   # would have nothing left running to settle.
   my $settle_from = sub ($response) {
      my $failing = 1;
      my $observed = {};
      dispatch(
         'result'  => { 'execId' => 'e', 'exitCode' => 0, 'timedOut' => 0 },
         'failing' => \$failing,
         'body'    => sub ($state) {
            $observed->{'before'} = entry();

            # The write fixture is what the self-heal write goes through too, so it has to be
            # lowered for that write to apply.
            $failing = 0;

            no warnings qw(redefine once);
            local *Reservation::call_socket_api_sync = sub (@) { return $response };
            $observed->{'running'} = reloaded()->hook_is_running('myhook');
            $observed->{'after'}   = entry();
         },
      );
      return $observed;
   };

   my $done = $settle_from->( ExecInspect->new(
      'is_success' => 1, 'body' => '{"Running":false,"ExitCode":0}' ) );
   is( $done->{'before'}{'state'}, 'running', 'the unwritten outcome is still running on disk' );
   is( $done->{'running'}, 0, 'Docker reports the exec finished, so the hook is not running' );
   is( $done->{'after'}{'state'}, 'done', 'and the outcome Docker reports is what gets recorded' );
   is( $done->{'after'}{'exitCode'}, 0, 'with its exit code' );

   my $gone = $settle_from->( ExecInspect->new( 'is_success' => 0, 'body' => '' ) );
   is( $gone->{'running'}, 0, 'an exec Docker cannot account for is not running either' );
   is( $gone->{'after'}{'state'}, 'aborted', 'and is recorded as aborted rather than left running' );
};

subtest 'the status read a poller repeats is such a reader' => sub {
   # `dockside hook run` learns an outcome only through User::runContainerHookStatus, so that
   # read has to be the one that settles an unwritten outcome; the permission checks around it
   # are stubbed to pass and the reservation it loads is the record as it stands on disk.
   my $failing = 1;
   my @polls;
   dispatch(
      'result'  => { 'execId' => 'e', 'exitCode' => 3, 'timedOut' => 0 },
      'failing' => \$failing,
      'body'    => sub ($state) {
         $failing = 0;

         no warnings qw(redefine once);
         local *User::has_permission = sub (@) { return 1 };
         local *User::can_on         = sub (@) { return 1 };
         local *User::reservation    = sub ( $self, $id ) { return reloaded() };
         local *Reservation::load_hook_log = sub (@) { return [] };

         my $inspections = 0;
         local *Reservation::call_socket_api_sync = sub (@) {
            $inspections++;
            return ExecInspect->new( 'is_success' => 1, 'body' => '{"Running":false,"ExitCode":3}' );
         };

         my $user = bless {}, 'User';
         push @polls, $user->runContainerHookStatus( 'fab1e', { 'name' => 'myhook' } ) for 1 .. 2;
         push @polls, $inspections;
      },
   );

   is( $polls[0]{'status'}{'state'}, 'failed', 'the first poll after the unwritten outcome reports the exec\'s result' );
   is( $polls[0]{'status'}{'exitCode'}, 3, 'with the exit code Docker holds' );
   is( $polls[1]{'status'}{'state'}, 'failed', 'a later poll reads the settled entry' );
   is( $polls[2], 1, 'and asks Docker only while the entry still reads running' );
   is( entry()->{'state'}, 'failed', 'the settlement is on disk' );
};

subtest 'a failure before dispatch still owes and applies its outcome write' => sub {
   my $run = dispatch( 'prep_fails' => 1 );

   is( $run->{'dispatches'}, 0, 'no exec was ever dispatched' );
   is( scalar @{ $run->{'claimed'} }, 1, 'but the invocation was claimed and acknowledged' );
   is( scalar @{ $run->{'writes'} }, 1, 'its outcome is written once' );
   is( $run->{'writes'}[0]{'in_flight'}, 1,
      'counted in flight for that write, even though nothing registered it before this point' );
   is( $run->{'in_flight_after_dispatch'}, 0, 'and released once the write lands' );
   is( entry()->{'state'}, 'aborted', 'the claim is resolved rather than left running' );
   is( scalar @{ $run->{'settled'} }, 1, 'the caller is notified exactly once' );
   is( $run->{'settled'}[0][0], 'aborted', 'with the outcome that was recorded' );
};

subtest 'a write fenced by a newer invocation is released silently' => sub {
   my $run = dispatch(
      'result' => { 'execId' => 'e', 'exitCode' => 0, 'timedOut' => 0 },
      'fence'  => 1,
   );

   is( scalar @{ $run->{'writes'} }, 1, 'a rejected write is attempted exactly once' );
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

done_testing;
