use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use Exception;
use File::Temp qw(tempdir);
use JSON qw(encode_json decode_json);
use Mojo::Message::Response;
use Test::More;

# Reservation::action turns stop/start/remove into one Docker Engine API request each. Only the
# transport is stubbed, to capture the request it is asked to make, to report a connection when
# the test says one was made, and to answer it. The reservation record is real, so what a stop
# writes before answering is read back from disk.
my $tmp = tempdir( CLEANUP => 1 );
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused' },
};
Util::flog( { file => "$tmp/test.log" } );

my $CID = 'c' x 12;

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

# Runs $code with stderr captured, since wlog writes warnings there, to keep them out of the TAP
# stream and to assert on them. Returns $code's results followed by the captured text.
sub captured ($code) {
   open( my $saved, '>&', \*STDERR ) or die "stderr: $!";
   open( STDERR, '>', "$tmp/stderr" ) or die "stderr: $!";
   my @out = eval { $code->() };
   my $failed = $@;
   open( STDERR, '>&', $saved ) or die "stderr: $!";
   die $failed if $failed;
   open my $fh, '<', "$tmp/stderr" or die $!;
   local $/;
   my $warnings = <$fh> // '';
   return ( @out, $warnings );
}

# Completions held back by 'defer' (below), as subs the test calls in the order it chooses.
my @DEFERRED;

# Runs one action against a stubbed Docker and returns the request made, the sequence of
# events, the reservation and the warning lines written meanwhile: 'sent' when the transport
# reports the request written (unless 'sent' is 0), then 'completed' with the code or the
# transport error, with each answer the caller received in between as ['answered', $result,
# $err]. With 'defer', the completion is pushed to @DEFERRED instead of running at once. The
# record is seeded afresh, with 'data' if given, unless 'keep' says to leave the file as it is.
sub act ( $action, $args = {}, %opt ) { return captured( sub { _act( $action, $args, %opt ) } ) }

sub _act ( $action, $args, %opt ) {
   write_record( { id => 'rid', name => 'devt', data => $opt{'data'} // {} } ) unless $opt{'keep'};
   my $r = bless { id => 'rid', name => 'devt', containerId => $CID, data => {} }, 'Reservation';
   my ( $request, @events );

   no warnings qw(redefine once);
   local *Reservation::call_socket_api = sub ( $socket, $path, $opts, $cb ) {
      $request = { 'path' => $path, 'method' => $opts->{'method'} };
      if ( $opts->{'on_request_sent'} && ( $opt{'sent'} // 1 ) ) {
         push @events, ['sent'];
         $opts->{'on_request_sent'}->();
      }
      my $complete = $opt{'err'}
         ? sub { push @events, [ 'completed', $opt{'err'} ]; $cb->( undef, $opt{'err'} ) }
         : sub { push @events, [ 'completed', $opt{'code'} // 204 ]; $cb->( Mojo::Message::Response->new->code( $opt{'code'} // 204 ), undef ) };
      return push @DEFERRED, $complete if $opt{'defer'};
      $complete->();
   };

   $r->action( $action, $args, sub (@a) { push @events, [ 'answered', @a ] } );
   return ( $request, \@events, $r );
}

sub answers ($events) { return [ grep { $_->[0] eq 'answered' } @$events ] }
sub sequence ($events) { return [ map { $_->[0] } @$events ] }

subtest 'a stop with no timeout of its own sends none' => sub {
   my ( $request, $events ) = act('stop');
   is( $request->{'method'}, 'POST', 'as a POST' );
   is( $request->{'path'}, "/containers/$CID/stop", 'with no query, so Docker applies the container own stop timeout' );
   is( scalar @{ answers($events) }, 1, 'the caller is answered once' );
   ok( !defined answers($events)->[0][2], 'with success' );
};

subtest 'a stop given a timeout sends it' => sub {
   my ( $request ) = act( 'stop', { 't' => 5 } );
   is( $request->{'path'}, "/containers/$CID/stop?t=5", 'as the t query Docker reads' );
};

subtest 'start and remove address their own endpoints and answer at completion' => sub {
   my ( $start, $startEvents ) = act('start');
   is( $start->{'method'}, 'POST', 'start is a POST' );
   is( $start->{'path'}, "/containers/$CID/start", 'to the start endpoint' );
   is_deeply( sequence($startEvents), [ 'completed', 'answered' ], 'answered once Docker has' );

   my ( $remove, $removeEvents ) = act('remove');
   is( $remove->{'method'}, 'DELETE', 'remove is a DELETE' );
   is( $remove->{'path'}, "/containers/$CID?v=true", 'of the container and its anonymous volumes' );
   is_deeply( sequence($removeEvents), [ 'completed', 'answered' ], 'answered once Docker has' );
   ok( !exists read_record()->{'data'}{'stopRequestedAt'}, 'neither records a stop request' );
};

subtest 'a remove of a failed launch with no container records an expiry without asking Docker' => sub {
   write_record( { id => 'rid', name => 'devt', data => {}, createStatus => { stage => 'failed', failed => 1, error => 'no such image' } } );
   my $r = bless { id => 'rid', name => 'devt', data => {}, createStatus => { stage => 'failed', failed => 1 } }, 'Reservation';
   my @events;
   no warnings qw(redefine once);
   local *Reservation::call_socket_api = sub (@) { push @events, ['requested']; };

   $r->action( 'remove', {}, sub (@a) { push @events, [ 'answered', @a ] } );
   is_deeply( sequence( \@events ), ['answered'], 'answered with no Docker request' );
   ok( !defined $events[0][2], 'as a success' );
   like( read_record()->{'expiryTime'} // '', qr/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/,
      'the record now carries an expiry, so cleanup deletes it' );
   is( read_record()->{'createStatus'}{'stage'}, 'failed', 'and keeps its terminal status' );

   for my $case ( [ 'stop', { stage => 'failed', failed => 1 } ], [ 'remove', { stage => 'creating', failed => 0 } ] ) {
      my ( $action, $createStatus ) = @$case;
      write_record( { id => 'rid', name => 'devt', data => {}, createStatus => $createStatus } );
      my $r = bless { id => 'rid', name => 'devt', data => {}, createStatus => $createStatus }, 'Reservation';
      @events = ();
      $r->action( $action, {}, sub (@a) { push @events, [ 'answered', @a ] } );
      is_deeply( sequence( \@events ), ['answered'], "a '$action' of a record at '$createStatus->{'stage'}' with no container is answered without a request" );
      is( $events[0][2]->status, 409, 'with a refusal' );
      ok( !read_record()->{'expiryTime'}, 'and records no expiry' );
   }
};

subtest 'a stop is answered once its request has been sent, before Docker completes it' => sub {
   my $before = Time::HiRes::time();
   my ( undef, $events, $r ) = act('stop');
   is_deeply( sequence($events), [ 'sent', 'answered', 'completed' ], 'the answer follows the request being sent and precedes the completion' );
   is( scalar @{ answers($events) }, 1, 'and is the only answer' );
   ok( !defined answers($events)->[0][2], 'reporting success' );

   my $requestedAt = read_record()->{'data'}{'stopRequestedAt'};
   ok( defined($requestedAt) && $requestedAt >= int( $before * 1000 ) / 1000 && $requestedAt <= Time::HiRes::time(),
      'stopRequestedAt is on disk, as the time of the request' );
   like( "$requestedAt", qr/^\d+(\.\d{1,3})?$/, 'to the millisecond' );
   ok( $r->data('stopRequestedAt') == $requestedAt, 'and on the object the answer is rendered from, equal to the value read back' );
};

subtest 'a stop request is recorded only if no later one is on record' => sub {
   my ( undef, $events, $r ) = act( 'stop', {}, 'data' => { 'stopRequestedAt' => 4102444800 } );
   is( read_record()->{'data'}{'stopRequestedAt'}, 4102444800, 'the later request time on disk stands' );
   ok( !defined $r->data('stopRequestedAt'), 'and the object is left without one' );
   is( scalar @{ answers($events) }, 1, 'while the stop is still answered' );
};

# Two stops of one container in flight together, the first sent at $first and the second at
# $second on a clock the test controls, both then failing in the order the first was sent. What
# is asserted is that the record settles to the second request's outcome.
sub two_stops_failing_in_order ( $first, $second ) {
   no warnings qw(redefine once);
   my $now = $first;
   local *Time::HiRes::time = sub { $now };
   my ( undef, undef, $rA ) = act( 'stop', {}, 'defer' => 1, 'code' => 500 );
   $now = $second;
   my ( undef, undef, $rB ) = act( 'stop', {}, 'defer' => 1, 'code' => 500, 'keep' => 1 );
   my $record = read_record()->{'data'};
   is( $record->{'stopRequestedAt'}, $second, 'both requests are sent; the second is on record' );
   is( $record->{'stopRequestId'}, $rB->data('stopRequestId'), 'under its own id' );
   ok( length( $rB->data('stopRequestId') // '' ) && ( $rA->data('stopRequestId') // '' ) ne $rB->data('stopRequestId'), 'which differs from the first request\'s' );

   captured( sub { $DEFERRED[0]->() } );
   is( read_record()->{'data'}{'stopRequestedAt'}, $second, 'the first request failing late leaves the second on record' );
   ok( $rA->data('stopRequestedAt') != 0, 'and does not zero its own object either' );

   captured( sub { $DEFERRED[1]->() } );
   is( read_record()->{'data'}{'stopRequestedAt'}, 0, 'the second request failing releases it' );
   is( $rB->data('stopRequestedAt'), 0, 'on its object too' );
   @DEFERRED = ();
   return;
}

subtest 'a late failed completion of an earlier stop does not release a later one' => sub {
   two_stops_failing_in_order( 1700000000.000, 1700000000.001 );
};

subtest 'two stops within one millisecond settle to the one recorded last' => sub {
   two_stops_failing_in_order( 1700000000.000, 1700000000.000 );
};

subtest 'a completion that is not a success after the answer is logged and releases the request, not answered again' => sub {
   my ( undef, $events, $r, $warnings ) = act( 'stop', {}, 'code' => 500 );
   is_deeply( sequence($events), [ 'sent', 'answered', 'completed' ], 'one answer, once sent' );
   like( $warnings, qr/acknowledged 'stop' on '$CID' returned 500/, 'the completion is logged at warning level' );
   is( read_record()->{'data'}{'stopRequestedAt'}, 0, 'and the request time is written as 0, so the reservation no longer reads as stopping' );
   is( $r->data('stopRequestedAt'), 0, 'on the object too' );

   ( undef, $events, $r, $warnings ) = act( 'stop', {}, 'err' => 'connection reset' );
   is( scalar @{ answers($events) }, 1, 'a transport failure after the answer is not answered either' );
   like( $warnings, qr/acknowledged 'stop' on '$CID' failed: connection reset/, 'and is logged at warning level' );
   is( read_record()->{'data'}{'stopRequestedAt'}, 0, 'and releases the request the same way, its outcome being unknown' );

   ( undef, undef, $r, $warnings ) = act('stop');
   is( $warnings, '', 'a completion that succeeds warns about nothing' );
   ok( $r->data('stopRequestedAt') > 0, 'and leaves the request time as recorded' );
};

subtest 'a stop whose request is never sent is answered with the transport failure and records nothing' => sub {
   my ( undef, $events ) = act( 'stop', {}, 'sent' => 0, 'err' => 'connection refused' );
   is_deeply( sequence($events), [ 'completed', 'answered' ], 'answered at completion' );
   my $err = answers($events)->[0][2];
   is( ref($err), 'Exception', 'with an Exception' );
   is( $err->status, 502, 'as an upstream failure' );
   ok( !exists read_record()->{'data'}{'stopRequestedAt'}, 'and no stop request is recorded' );
};

subtest 'a stop request that cannot be recorded is still answered' => sub {
   no warnings qw(redefine once);
   local *Reservation::record_stop_request = sub { die Exception->new( 'dbg' => 'fixture write failure' ) };
   my ( undef, $events, $r, $warnings ) = act('stop');
   is_deeply( sequence($events), [ 'sent', 'answered', 'completed' ], 'answered once sent regardless' );
   ok( !defined $r->data('stopRequestedAt'), 'and the object carries no request time disk does not' );
   ok( !defined answers($events)->[0][2], 'with success, since the stop is under way' );
   like( $warnings, qr/could not record stopRequestedAt.*fixture write failure/, 'and the lost record is logged at warning level' );
};

done_testing;
