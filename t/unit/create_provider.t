use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use Exception;
use File::Temp qw(tempdir);
use JSON qw(encode_json decode_json);
use Mojo::IOLoop;
use Mojo::Message::Response;
use Test::More;

# The create chain takes its timer and its recycling hold from the process that loads
# Reservation, through Reservation::provider. A chain entry with no provider, or one lacking
# either entry, dies before the ownership lock is taken or Docker is contacted; with one
# installed, the ownership inspection's waits are the provider's timer and its budget runs on
# the monotonic clock. The reservation record and the lock are real; only the transport is
# stubbed.
my $tmp = tempdir( CLEANUP => 1 );
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused' },
};
Util::flog( { file => "$tmp/test.log" } );

no warnings 'redefine';
local *Reservation::routers = sub { {} };
local *Reservation::update_container_info = sub { };
local *Reservation::cmdline_json = sub (@) { return { Image => 'img:1' }; };

my $OWN_ID = 'c' x 64;
my $NO_PROVIDER = qr/Reservation::provider.*cannot drive a create chain/;

sub write_record ($record) {
   open my $fh, '>', $Data::CONFIG->{'reservationsPath'} or die $!;
   print $fh encode_json($record), "\n";
   close $fh;
   return;
}

sub read_record {
   open my $fh, '<', $Data::CONFIG->{'reservationsPath'} or die $!;
   local $/;
   my $text = <$fh>;
   return length($text) ? decode_json($text) : undef;
}

sub seed ( $stage, %extra ) {
   write_record( {
      id => 'rid', name => 'devt', version => 2, data => { image => 'img:1' },
      createStatus => { stage => $stage, failed => 0, layers => {} },
      %extra,
   } );
   return;
}

# A reservation with no create yet, as create() expects to find it.
sub fresh {
   write_record( { id => 'rid', name => 'devt', version => 2, data => { image => 'img:1' } } );
   Data::load_fresh('reservations.json');
   return bless { id => 'rid', name => 'devt', version => 2, data => { image => 'img:1' } }, 'Reservation';
}

sub responds ( $code, $body = '' ) {
   return sub ( $cb, @ ) { $cb->( Mojo::Message::Response->new->code($code)->body($body), undef ); };
}

sub holds ($entry) { return responds( 200, encode_json( defined($entry) ? [$entry] : [] ) ); }

# Records every request path; answers a lookup as absent and a create as a conflict, which is
# the shape that enters the ownership inspection. $onLookup runs before each lookup answers.
my @calls;
my @timers;
my @pending;
sub docker ( $onLookup = sub { } ) {
   return sub ( $socket, $path, $args, $cb ) {
      push @calls, $path;
      if ( $path =~ m{^/containers/json} ) {
         $onLookup->();
         return holds(undef)->($cb);
      }
      return responds( 409, '' )->($cb) if $path =~ m{^/containers/create};
      return responds( 500, 'no fixture for this request' )->($cb);
   };
}

# Runs one reconciliation to settlement. The timers the attempt waits on (the inspection's) are
# recorded by the provider above and fired here in order, their delays kept in @timers, until
# the chain settles; the retry timer an unresolved settlement leaves is not fired.
sub reconcile {
   my @settled;
   my $started = Reservation->reconcile_one( 'rid', sub ( $ok = undef, $err = undef ) {
      push @settled, { 'ok' => $ok, 'err' => $err };
      Mojo::IOLoop->stop;
   } );
   while ( $started && !@settled && @pending ) {
      my $timer = shift @pending;
      push @timers, $timer->[0];
      $timer->[1]->();
   }
   return { 'started' => $started, 'settled' => \@settled } if !$started || @settled;

   my $timeout = Mojo::IOLoop->timer( 5 => sub { Mojo::IOLoop->stop } );
   Mojo::IOLoop->start;
   Mojo::IOLoop->remove($timeout);
   return { 'started' => $started, 'settled' => \@settled };
}

sub lock_path { return Reservation::_create_lock_path('rid'); }

sub is_refused_before_anything ( $label ) {
   ok( !-e lock_path(), "$label: the ownership lock was never taken" );
   is( scalar @calls, 0, "$label: no request reached the transport" );
   return;
}

subtest 'with no provider installed, a chain entry dies before the lock is taken or Docker is contacted' => sub {
   local *Reservation::call_socket_api = docker();
   ok( !defined( Reservation::provider() ), 'nothing is installed to begin with' );

   seed('creating');
   @calls = ();
   my $died = !eval { Reservation->reconcile_one('rid'); 1 };
   ok( $died, 'reconcile_one dies' );
   like( $@, $NO_PROVIDER, 'naming the provider and what it is for' );
   like( $@, qr/no asynchronous provider installed/, 'and that none is installed' );
   is_refused_before_anything('reconcile_one');

   my $r = fresh();
   @calls = ();
   my @answered;
   $died = !eval { $r->create( sub (@a) { push @answered, [@a] } ); 1 };
   ok( $died, 'create dies' );
   like( $@, $NO_PROVIDER, 'with the same message' );
   is( scalar @answered, 0, 'create: the caller is not answered, since nothing was started' );
   is_refused_before_anything('create');
   ok( !read_record()->{'createStatus'}, 'create: no stage was written' );
};

subtest 'a provider lacking either entry is refused the same way, naming the entry' => sub {
   local *Reservation::call_socket_api = docker();

   Reservation::provider( 'timer' => sub (@) { } );
   seed('creating');
   @calls = ();
   my $died = !eval { Reservation->reconcile_one('rid'); 1 };
   ok( $died, 'a timer-only provider does not admit a chain' );
   like( $@, $NO_PROVIDER, 'the message names the provider' );
   like( $@, qr/lacks 'hold'/, 'and the missing entry' );
   is_refused_before_anything('timer only');

   Reservation::provider( 'hold' => sub () { return sub { } } );
   @calls = ();
   $died = !eval { Reservation->reconcile_one('rid'); 1 };
   ok( $died, 'a hold-only provider does not admit a chain either' );
   like( $@, qr/lacks 'timer'/, 'naming that entry' );
   is_refused_before_anything('hold only');
};

# A timer that records what it is asked for and fires at once, and a hold nothing in this stage
# takes.
sub install_provider {
   @timers = ();
   @pending = ();
   Reservation::provider(
      'timer' => sub ( $delay, $cb ) { push @pending, [ $delay, $cb ]; return scalar @pending; },
      'hold'  => sub () { return sub { }; },
   );
   return;
}

subtest 'the ownership inspection waits on the provider timer at the configured delays and reports once' => sub {
   install_provider();
   local *Reservation::call_socket_api = docker();
   seed('creating');
   @calls = ();

   my $run = reconcile();
   is( $run->{'started'}, 1, 'the chain is admitted' );
   is( scalar @{ $run->{'settled'} }, 1, 'and reports through its continuation exactly once' );
   ok( ref( $run->{'settled'}[0]{'err'} ) eq 'Exception' && $run->{'settled'}[0]{'err'}->unresolved,
      'a conflict whose name never resolves is unresolved' );
   is( scalar( grep { m{^/containers/json} } @calls ), 4, 'one preflight lookup, then the inspection three' );
   is_deeply( \@timers, $Reservation::CREATE_CONFLICT_POLL_DELAYS, 'each inspection lookup at its configured delay' );
   ok( -e lock_path(), 'the lock file exists, the chain having taken it' );
   my $lock = Util::tryLockFile( lock_path() );
   ok( $lock, 'and it is free again once the chain has settled' );
   close $lock;
};

subtest 'the inspection budget is measured on the monotonic clock, not waited out' => sub {
   install_provider();
   my $now = 1000;
   local *Reservation::_create_clock = sub () { return $now; };
   # Every lookup costs twice the budget of clock, so the inspection runs out after its first.
   local *Reservation::call_socket_api = docker( sub { $now += 2 * $Reservation::CREATE_CONFLICT_POLL_BUDGET_SECONDS } );
   seed('creating');
   @calls = ();

   my $run = reconcile();
   is( scalar @{ $run->{'settled'} }, 1, 'reports once' );
   my $err = $run->{'settled'}[0]{'err'};
   ok( ref($err) eq 'Exception' && $err->unresolved, 'as unresolved' );
   like( $err->msg, qr/inspection budget/, 'because the budget was exhausted' );
   is( scalar( grep { m{^/containers/json} } @calls ), 2,
      'one preflight lookup and one inspection lookup, the second wait finding no budget left' );
   is( scalar @timers, 2, 'the timer was asked for two waits' );
   is_deeply( \@timers, [ @{$Reservation::CREATE_CONFLICT_POLL_DELAYS}[ 0, 1 ] ], 'at the first two configured delays' );
};

done_testing;
