use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Util;
use Exception;
use File::Temp qw(tempdir);
use Mojo::IOLoop;
use Mojo::UserAgent;
use Test::More;

# Drives the real Util::call_socket_api with failures injected *beneath* it, in Mojo::UserAgent.
# Stubbing call_socket_api itself - what the other unit tests do, rightly, to exercise their own
# callers - cannot cover this function's own setup and teardown paths, which are where a caller's
# in-flight obligation is leaked or double-released.
my $tmp = tempdir(CLEANUP => 1);
my $logPath = "$tmp/test.log";
Util::flog({ file => $logPath });

sub read_log {
   open my $fh, '<', $logPath or die $!;
   local $/;
   return <$fh> // '';
}

subtest 'an unsupported method settles through the callback rather than dying' => sub {
   my @settled;
   my $returned = eval {
      Util::call_socket_api( 'unused', '/containers/x', { 'method' => 'PUT' },
         sub (@a) { push @settled, [@a] } );
      1;
   };

   ok( $returned, 'the caller does not have to catch an exception to learn of this' );
   is( scalar @settled, 1, 'the callback fires exactly once' );
   ok( !defined( $settled[0][0] ), 'with no result' );
   like( $settled[0][1], qr/unsupported method 'PUT'/, 'naming the method it refused' );
   is( Util::async_ua_in_flight_count(), 0, 'nothing is left registered' );
};

subtest 'a request that cannot be built settles once and registers no user agent' => sub {
   my @settled;
   no warnings 'redefine';
   local *Mojo::UserAgent::build_tx = sub { die "fixture build failure\n" };

   my $returned = eval {
      Util::call_socket_api( 'unused', '/containers/x', {}, sub (@a) { push @settled, [@a] } );
      1;
   };

   ok( $returned, 'a build failure is not an exception to the caller' );
   is( scalar @settled, 1, 'the callback fires exactly once' );
   like( $settled[0][1], qr/failed to build request/, 'the failure says what stage it was at' );
   like( $settled[0][1], qr/fixture build failure/, 'and includes what actually went wrong' );
   is( Util::async_ua_in_flight_count(), 0, 'no user agent is registered for a request never built' );
};

subtest 'a request that cannot be started settles once and leaks no user agent' => sub {
   my @settled;
   no warnings 'redefine';
   local *Mojo::UserAgent::start = sub { die Exception->new( 'dbg' => 'fixture start failure' ) };

   my $returned = eval {
      Util::call_socket_api( 'unused', '/containers/x', {}, sub (@a) { push @settled, [@a] } );
      1;
   };

   ok( $returned, 'a start failure is not an exception to the caller' );
   is( scalar @settled, 1, 'the callback fires exactly once' );
   like( $settled[0][1], qr/failed to start request/, 'the failure says what stage it was at' );
   like( $settled[0][1], qr/fixture start failure/, 'and includes what actually went wrong' );
   is( Util::async_ua_in_flight_count(), 0,
      'the user agent registered before the start attempt is dropped again' );
};

subtest 'an exception from the caller own callback is not reported as a transport failure' => sub {
   my $calls = 0;
   no warnings 'redefine';
   # A start that delivers its failure straight to the completion callback, synchronously - the
   # one case where a throw escaping start() belongs to the caller rather than to the transport.
   local *Mojo::UserAgent::start = sub ( $ua, $tx, $cb ) {
      $cb->( $ua, $tx );
      return $tx;
   };

   my $error;
   eval {
      Util::call_socket_api( 'unused', '/containers/x', {},
         sub (@) { $calls++; die "consumer failure\n" } );
      1;
   } or $error = $@;

   is( $calls, 1, 'the callback is entered exactly once' );
   like( $error, qr/consumer failure/,
      'the caller own exception reaches the caller, not a rewritten start-failure message' );
   is( Util::async_ua_in_flight_count(), 0, 'and the user agent is still not leaked' );
};

subtest 'a streamed-response consumer that throws cannot escape into the reactor' => sub {
   my @settled;
   my $reads = 0;
   no warnings 'redefine';
   # Deliberately never completes, so the read event can be driven against a request that is
   # still open. That leaves this one request's user agent registered for the rest of the file,
   # which is why the cleanup assertions below are relative to their own starting point.
   local *Mojo::UserAgent::start = sub ( $ua, $tx, $cb ) { return $tx };

   my $tx = Util::call_socket_api( 'unused', '/images/create', {
      'method'  => 'POST',
      'on_read' => sub (@) { $reads++; die "fixture consumer failure\n" },
   }, sub (@a) { push @settled, [@a] } );

   ok( $tx, 'the transaction is returned for a caller holding a stream' );

   # Exactly what the reactor does when response bytes arrive, against the real subscription
   # call_socket_api installed.
   my $survived = eval { $tx->res->content->emit( read => 'some bytes' ); 1 };

   ok( $survived, 'the read event completes despite the consumer throwing' );
   is( $reads, 1, 'the consumer was genuinely invoked' );
   like( read_log(), qr/on_read consumer failed for \/images\/create/,
      'the consumer failure is reported where it can be diagnosed' );
   is( scalar @settled, 0, 'a consumer failure is not itself a settlement' );
};

subtest 'a genuine transport failure settles once and cleans up after itself' => sub {
   my @settled;
   my $before = Util::async_ua_in_flight_count();
   Util::call_socket_api( "$tmp/definitely-not-a-socket", '/containers/json', {},
      sub (@a) { push @settled, [@a]; Mojo::IOLoop->stop } );

   is( Util::async_ua_in_flight_count(), $before + 1,
      'the user agent is held for the duration of the request' );

   my $timeout = Mojo::IOLoop->timer( 5 => sub { Mojo::IOLoop->stop } );
   Mojo::IOLoop->start;
   Mojo::IOLoop->remove($timeout);

   is( scalar @settled, 1, 'the callback fires exactly once' );
   ok( !defined( $settled[0][0] ), 'an unreachable socket has no usable result' );
   ok( defined( $settled[0][1] ), 'and is reported as an error' );
   is( Util::async_ua_in_flight_count(), $before,
      'the user agent is released once the request settles' );
};

done_testing;
