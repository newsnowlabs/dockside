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

subtest 'a transport that completes a request twice settles the caller once and logs the second' => sub {
   my @settled;
   no warnings 'redefine';
   local *Mojo::UserAgent::start = sub ( $ua, $tx, $cb ) {
      $cb->( $ua, $tx );
      $cb->( $ua, $tx );
      return $tx;
   };

   # The second completion is reported on stderr as well as in the log; captured so it stays
   # out of the TAP stream.
   open( my $saved, '>&', \*STDERR ) or die "stderr: $!";
   open( STDERR, '>', "$tmp/stderr" ) or die "stderr: $!";
   Util::call_socket_api( 'unused', '/containers/x', {}, sub (@a) { push @settled, [@a] } );
   open( STDERR, '>&', $saved ) or die "stderr: $!";
   open( my $fh, '<', "$tmp/stderr" ) or die $!;
   my $stderr = do { local $/; <$fh> // '' };

   is( scalar @settled, 1, 'the callback fires exactly once' );
   ok( defined( $settled[0][0] ), 'with the one completion result' );
   like( read_log(), qr/call_socket_api: settlement for \/containers\/x: continuation called again; ignored/,
      'the second completion is reported as a bug in the transport, naming the request' );
   like( $stderr, qr/settlement for \/containers\/x: continuation called again/, 'on stderr too' );
   is( Util::async_ua_in_flight_count(), 0, 'and the user agent is released' );
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

subtest 'a stream whose consumer failed is reported as a failure, not a success' => sub {
   my @settled;
   my $completed;
   no warnings 'redefine';
   # A transfer that ends with an ordinary HTTP success after its consumer has already thrown.
   # The consumer never saw the rest of that chunk, so the response cannot be handed over as a
   # usable result - anything the caller derives from the stream is incomplete.
   local *Mojo::UserAgent::start = sub ( $ua, $tx, $cb ) {
      $tx->res->content->emit( read => 'some bytes' );
      $completed = sub { $cb->( $ua, $tx ) };
      return $tx;
   };

   my $tx = Util::call_socket_api( 'unused', '/images/create', {
      'method'  => 'POST',
      'on_read' => sub (@) { die "fixture consumer failure\n" },
   }, sub (@a) { push @settled, [@a] } );

   is( scalar @settled, 0, 'nothing settles while the transfer is still running' );
   $completed->();

   is( scalar @settled, 1, 'the callback fires exactly once' );
   ok( !defined( $settled[0][0] ), 'no response is handed over for a stream that was not fully read' );
   like( $settled[0][1], qr/streamed-response consumer failed/, 'the failure says what went wrong' );
   like( $settled[0][1], qr/fixture consumer failure/, 'and carries the consumer error itself' );
};

subtest 'a user agent that cannot be constructed settles once' => sub {
   my @settled;
   no warnings 'redefine';
   local *Mojo::UserAgent::new = sub { die "fixture user agent failure\n" };

   my $returned = eval {
      Util::call_socket_api( 'unused', '/containers/x', {}, sub (@a) { push @settled, [@a] } );
      1;
   };

   ok( $returned, 'a construction failure is not an exception to the caller' );
   is( scalar @settled, 1,
      'the callback still fires exactly once, so a registered obligation is not stranded' );
   like( $settled[0][1], qr/failed to create user agent/, 'the failure says what stage it was at' );
   like( $settled[0][1], qr/fixture user agent failure/, 'and includes what actually went wrong' );
};

# A real local socket server for the two handoff tests below. It reads whatever arrives and,
# once it holds a complete request, answers on a later tick, so the consumer's turn and the
# reply's are distinct. $received is the request as the server read it.
my $received;
sub socket_server ( $path, $onComplete = undef ) {
   $received = '';
   return Mojo::IOLoop->server( path => $path, sub ( $loop, $stream, $id ) {
      $stream->on( read => sub ( $s, $bytes ) {
         $received .= $bytes;
         return unless $received =~ /\r\n\r\n\z/ && !$s->{'answered'}++;
         return $onComplete->() if $onComplete;
         Mojo::IOLoop->timer( 0.05 => sub {
            $s->write( "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n" => sub ($s) { $s->close_gracefully } );
         } );
      } );
   } );
}

sub run_loop ($server) {
   my $timeout = Mojo::IOLoop->timer( 5 => sub { Mojo::IOLoop->stop } );
   Mojo::IOLoop->start;
   Mojo::IOLoop->remove($_) for $timeout, $server;
   return;
}

subtest 'on_request_sent fires once, with no arguments, before the reply completes the call' => sub {
   my $server = socket_server("$tmp/server.sock");
   my @events;
   Util::call_socket_api( "$tmp/server.sock", '/containers/x/stop', {
      'method'          => 'POST',
      'on_request_sent' => sub (@a) { push @events, [ 'sent', @a ]; },
   }, sub (@a) { push @events, [ 'settled', @a ]; Mojo::IOLoop->stop } );
   run_loop($server);

   is_deeply( [ map { $_->[0] } @events ], [ 'sent', 'settled' ], 'the consumer is called exactly once, before the completion callback' );
   is( scalar @{ $events[0] }, 1, 'with no arguments' );
   is( $events[-1][1] && $events[-1][1]->code, 204, 'and the call completes with the server reply' );
   like( $received, qr{\APOST /containers/x/stop HTTP/1\.1\r\n.*\r\n\r\n\z}s, 'which answered the complete request' );
};

subtest 'the request has been handed off when on_request_sent fires: the server gets all of it even if the client then goes away' => sub {
   # What the consumer may rely on: the kernel holds the whole request for the server. The
   # consumer closes the client's connection the instant it is called, at once and without
   # waiting for anything still queued (Mojo::IOLoop::Stream's close, not the loop's remove,
   # which lets queued data drain first), as a worker exiting then would, and the server must
   # still read the complete request. The loop runs until the server has, or the timeout gives
   # up on it.
   my $server = socket_server( "$tmp/server.sock", sub { Mojo::IOLoop->stop } );
   my @events;
   my $tx;
   $tx = Util::call_socket_api( "$tmp/server.sock", '/containers/x/stop', {
      'method'          => 'POST',
      'on_request_sent' => sub { push @events, ['sent']; Mojo::IOLoop->stream( $tx->connection )->close },
   }, sub (@a) { push @events, [ 'settled', @a ] } );
   run_loop($server);

   is_deeply( [ map { $_->[0] } @events ], [ 'sent', 'settled' ], 'the consumer fired, then the call settled' );
   ok( defined( $events[-1][2] ), 'as a transport failure, the connection having been closed' );
   like( $received, qr{\APOST /containers/x/stop HTTP/1\.1\r\n.*\r\n\r\n\z}s, 'and the server read the complete request regardless' );
};

subtest 'an on_request_sent consumer that throws does not prevent settlement' => sub {
   my $server = socket_server("$tmp/server.sock");
   my @settled;
   my $calls = 0;
   Util::call_socket_api( "$tmp/server.sock", '/containers/x/stop', {
      'method'          => 'POST',
      'on_request_sent' => sub { $calls++; die "fixture consumer failure\n" },
   }, sub (@a) { push @settled, [@a]; Mojo::IOLoop->stop } );
   run_loop($server);

   is( $calls, 1, 'the consumer was called' );
   is( scalar @settled, 1, 'and the callback still fires exactly once' );
   is( $settled[0][0] && $settled[0][0]->code, 204, 'with the server reply' );
   like( read_log(), qr/on_request_sent consumer failed for \/containers\/x\/stop/,
      'and the failure is reported where it can be diagnosed' );
};

subtest 'a genuine transport failure settles once and cleans up after itself' => sub {
   my @settled;
   my $sent = 0;
   my $before = Util::async_ua_in_flight_count();
   Util::call_socket_api( "$tmp/definitely-not-a-socket", '/containers/json',
      { 'on_request_sent' => sub { $sent++ } },
      sub (@a) { push @settled, [@a]; Mojo::IOLoop->stop } );

   is( Util::async_ua_in_flight_count(), $before + 1,
      'the user agent is held for the duration of the request' );

   my $timeout = Mojo::IOLoop->timer( 5 => sub { Mojo::IOLoop->stop } );
   Mojo::IOLoop->start;
   Mojo::IOLoop->remove($timeout);

   is( scalar @settled, 1, 'the callback fires exactly once' );
   ok( !defined( $settled[0][0] ), 'an unreachable socket has no usable result' );
   ok( defined( $settled[0][1] ), 'and is reported as an error' );
   is( $sent, 0, 'on_request_sent never fires for a request that never reached a socket' );
   is( Util::async_ua_in_flight_count(), $before,
      'the user agent is released once the request settles' );
};

done_testing;
