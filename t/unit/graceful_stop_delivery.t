use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Test2::IPC;
use Test::More;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use IO::Socket::UNIX;
use Mojo::IOLoop;
use POSIX ();
use Time::HiRes ();
use Util;
use App::Shutdown;

# The shapes app_shutdown.t cannot pin without a reactor: SIGQUIT delivered while one of the
# worker's own callbacks is executing, under the handler Mojo::Server::Prefork installs in each
# worker, a Perl signal handler that stops the loop gracefully. Perl runs the handler between
# two operations of that callback, so the finish event arrives inside it, and the drain must
# begin once the callback has completed, never above it. One case per callback the worker's
# code hands the loop: a timer's, entered through Util::loop_timer as a create chain's retry is;
# a streamed read, the request-sent check and the completion of Util::call_socket_api, as a
# hook's output, an action's early answer and every Docker reply are; and the completion of
# Util::get_uri, as a devcontainer.json fetch is. Each runs under the installed Mojo::IOLoop
# with the wiring bin/app-server makes, so a change in how the loop or Perl delivers the signal
# fails here rather than in a restart.
#
# The shutdown latch is set once per process, so each case runs in a child forked for it, which
# begins with the latch unset and its own copy of the loop, as a Prefork worker does; Test2::IPC
# carries the child's assertions to this process's plan.
my $tmp = tempdir( CLEANUP => 1 );

# A server in a process of its own, as Docker is, on a Unix socket path or a TCP port, that
# answers one complete request a moment later, framed as 'framing' says. 'chunked' sends the
# body as one chunk with the terminating chunk in the same write, as Docker's pull stream
# ends, so the reply completes the call in the event that reads the body; 'until_close' sends
# no length and closes the connection a moment later still, as Docker's raw exec output stream
# ends, so the completion is an event of its own; a body length otherwise. A server in this
# process's own loop would not do: the graceful stop under test stops that loop accepting, so a
# request the signal overtook would never be answered. Returns the port for a TCP server.
my @servers;
sub server ( %opts ) {
   my $listener = $opts{'path'}
      ? IO::Socket::UNIX->new( 'Type' => SOCK_STREAM(), 'Local' => $opts{'path'}, 'Listen' => 1 )
      : IO::Socket::INET->new( 'LocalAddr' => '127.0.0.1', 'LocalPort' => 0, 'Proto' => 'tcp', 'Listen' => 1 );
   die "listen: $!" unless $listener;
   my $framing = $opts{'framing'} // 'length';
   my $reply
      = $framing eq 'until_close' ? "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\n\r\nhello"
      : $framing eq 'chunked'     ? "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
      :                             "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
   my $pid = fork() // die "fork: $!";
   if ( $pid == 0 ) {
      my $client = $listener->accept() or POSIX::_exit(1);
      my $request = '';
      while ( $request !~ /\r\n\r\n/ ) {
         my $read = sysread( $client, my $bytes, 65536 );
         last unless $read;
         $request .= $bytes;
      }
      Time::HiRes::sleep(0.05);
      syswrite( $client, $reply );
      Time::HiRes::sleep(0.05) if $framing eq 'until_close';
      close($client);
      POSIX::_exit(0);
   }
   push @servers, $pid;
   my $port = $opts{'path'} ? undef : $listener->sockport();
   close($listener);
   return $port;
}

# The wiring bin/app-server makes, and the obligations the case declares: creates carries the
# issued tail the interrupted callback's consumer clears, abandoned a chain the drain names and
# never waits for.
my @order;
my @logged;
my %obligations;
sub arm (%declared) {
   @order       = ();
   @logged      = ();
   %obligations = ( 'creates' => [], 'hooks' => [], 'abandoned' => [], %declared );
   App::Shutdown::configure(
      # Finite, so a drain begun above a paused callback fails the case after its budget rather
      # than hanging it: it would wait for the obligation the paused callback holds.
      'ceiling'      => 15,
      'obligations'  => sub () { return \%obligations; },
      'clock'        => sub () { return Time::HiRes::time(); },
      'tick'         => sub () { Mojo::IOLoop->singleton->reactor->one_tick; return; },
      'log'          => sub ($message) { push @logged, $message; },
      'accept_limit' => sub (@set) { return 0; },
   );
   Util::step_wrapper( \&App::Shutdown::busy_while );
   Mojo::IOLoop->singleton->on( finish => sub (@) {
      push @order, 'finish';
      App::Shutdown::on_finish( sub () { push @order, 'drain'; App::Shutdown::drain(); } );
   } );
   $SIG{QUIT} = sub { Mojo::IOLoop->singleton->stop_gracefully };
   return;
}

# Sends the signal from inside the executing callback: the handler runs between two of the
# operations that follow.
sub interrupt ($label) {
   push @order, "$label begins";
   kill QUIT => $$;
   my $ops = 0;
   $ops++ for 1 .. 10;
   return;
}

sub run_loop () {
   # The loop stops on the graceful stop, there being no connection to wait for; this bounds a
   # loop that never receives one.
   Mojo::IOLoop->timer( 10 => sub { push @order, 'timed out'; Mojo::IOLoop->stop; } );
   Mojo::IOLoop->start;
   for my $pid ( splice @servers ) {
      kill 'TERM' => $pid;
      waitpid( $pid, 0 );
   }
   return;
}

sub in_child ( $name, $case ) {
   my $pid = fork() // die "fork: $!";
   if ( $pid == 0 ) {
      subtest $name => $case;
      exit 0;
   }
   waitpid( $pid, 0 );
   is( $? >> 8, 0, "$name: the child exited normally" );
   return;
}

in_child 'a timer callback' => sub {
   arm( 'creates' => ['r-tail'] );
   Util::loop_timer( 0.05, sub () {
      interrupt('callback');
      @{ $obligations{'creates'} } = ();
      push @order, 'callback ends';
   } );
   run_loop();

   is_deeply( \@order, [ 'callback begins', 'finish', 'callback ends', 'drain' ],
      'the finish event arrives inside the callback and the drain follows the callback' );
   ok( App::Shutdown::is_shutting_down(), 'the shutdown began' );
   is( scalar @logged, 1, 'the drain logged one line' );
   like( $logged[0], qr/nothing in flight; exiting/, 'and found the obligation the callback cleared before the drain began' );
};

in_child 'a streamed read of a response read until the connection closes' => sub {
   arm( 'hooks' => ['h-run'] );
   server( 'path' => "$tmp/close.sock", 'framing' => 'until_close' );
   Util::call_socket_api( "$tmp/close.sock", '/exec/x/start', {
      'method'  => 'POST',
      'on_read' => sub ($bytes) { interrupt('read'); push @order, 'read ends'; },
   }, sub (@) { @{ $obligations{'hooks'} } = (); push @order, 'settled'; } );
   run_loop();

   is_deeply( \@order, [ 'read begins', 'finish', 'read ends', 'drain', 'settled' ],
      'the finish event arrives inside the read; the drain follows the read and reaches the completion, on the close' );
   like( $logged[-1], qr/drained every .* after 0s; exiting/, 'the drain waited for the hook run and found it settled' );
};

in_child 'a streamed read of a chunk that ends the response' => sub {
   arm();
   server( 'path' => "$tmp/chunked.sock", 'framing' => 'chunked' );
   Util::call_socket_api( "$tmp/chunked.sock", '/images/create', {
      'method'  => 'POST',
      'on_read' => sub ($bytes) { interrupt('read'); push @order, 'read ends'; },
   }, sub (@) { push @order, 'settled'; } );
   run_loop();

   is_deeply( \@order, [ 'read begins', 'finish', 'read ends', 'drain', 'settled' ],
      'the finish event arrives inside the read; the drain follows the read, and the completion, in the same event, follows the drain' );
   like( $logged[-1], qr/nothing in flight; exiting/, 'so a drain begun there can wait for nothing that completion settles' );
};

in_child 'the request-sent check' => sub {
   arm( 'creates' => ['r-tail'] );
   server( 'path' => "$tmp/sent.sock" );
   Util::call_socket_api( "$tmp/sent.sock", '/containers/x/stop', {
      'method'          => 'POST',
      'on_request_sent' => sub () { interrupt('sent'); push @order, 'sent ends'; },
   }, sub (@) { @{ $obligations{'creates'} } = (); push @order, 'settled'; } );
   run_loop();

   is_deeply( \@order, [ 'sent begins', 'finish', 'sent ends', 'drain', 'settled' ],
      'the finish event arrives inside the check; the drain follows it and reaches the completion' ) or diag explain \@order;
   like( $logged[-1], qr/drained every .* after 0s; exiting/, 'the drain waited for the tail and found it settled' );
};

in_child 'the completion of a Docker call' => sub {
   arm( 'creates' => ['r-tail'] );
   server( 'path' => "$tmp/reply.sock" );
   Util::call_socket_api( "$tmp/reply.sock", '/containers/x/start', { 'method' => 'POST' }, sub (@) {
      interrupt('settled');
      @{ $obligations{'creates'} } = ();
      push @order, 'settled ends';
   } );
   run_loop();

   is_deeply( \@order, [ 'settled begins', 'finish', 'settled ends', 'drain' ],
      'the finish event arrives inside the completion and the drain follows it' );
   like( $logged[0], qr/nothing in flight; exiting/, 'and found the tail the completion cleared before the drain began' );
};

in_child 'the completion of a fetch' => sub {
   arm( 'creates' => ['r-tail'] );
   my $port = server();
   Util::get_uri( "http://127.0.0.1:$port/devcontainer.json", sub (@) {
      interrupt('fetched');
      @{ $obligations{'creates'} } = ();
      push @order, 'fetched ends';
   } );
   run_loop();

   is_deeply( \@order, [ 'fetched begins', 'finish', 'fetched ends', 'drain' ],
      'the finish event arrives inside the fetch completion and the drain follows it' );
   like( $logged[0], qr/nothing in flight; exiting/, 'and found the tail the completion cleared before the drain began' );
};

done_testing;
