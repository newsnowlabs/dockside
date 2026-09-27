use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use Exception;
use File::Temp qw(tempdir);
use JSON qw(encode_json decode_json);
use Time::HiRes ();
use Time::Piece;
use Mojo::IOLoop;
use Mojo::Message::Response;
use Test::More;

# Covers what a create chain does when it cannot establish whether its Docker mutation took
# effect. Exercises real database mutations, real reconciliation and the real ownership lock with
# disposable data; only the Docker transport is ever stubbed, so each test drives the same stage
# code, continuations and persistence a live worker does. The distinction under test throughout is
# between an outcome that is known (advance, or record a definitive failure and expire) and one
# that is not (keep a resumable stage, so a later pass can find out).
my $tmp = tempdir(CLEANUP => 1);
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused' },
};
Util::flog({ file => "$tmp/test.log" });

no warnings 'redefine';
# Container indexes and profile routers take no part in create recovery.
local *Reservation::routers = sub { {} };
local *Reservation::update_container_info = sub {};
# The create body's contents are irrelevant to every outcome here except the two subtests that
# deliberately make compiling it fail, which override this themselves.
local *Reservation::cmdline_json = sub (@) { return { Image => 'img:1' }; };

# The chain's waits are the provider's timer: the ownership inspection's delays within an attempt,
# and the worker's own retry after an unresolved outcome. This one records each timer and fires
# nothing itself. reconcile() below fires the timers due within an attempt, in order, until the
# chain settles, recording their delays in @timerDelays; a retry timer left pending after the
# settlement is what a test reads and fires by hand (fire_retry). So what these tests assert
# about waits is how many, at what delays, and what follows them, never how long they take.
#
# The provider's hold against recycling the worker is recorded the same way: each take, each
# release and each timer armed goes into @events in order, so a test can assert that a chain
# takes one hold, releases it once settled, and arms its retry only after that. A release also
# notes whether 'rid's ownership lock was still held at that moment, which the settlement order
# forbids: the lock is closed before the hold is released.
my @pending;
my @timerDelays;
my @events;
Reservation::provider(
   'timer' => sub ( $delay, $cb ) { push @pending, [ $delay, $cb ]; push @events, 'timer'; return scalar @pending; },
   'hold'  => sub () {
      push @events, 'hold';
      return sub () { push @events, lock_free('rid') ? 'release' : 'release while locked'; };
   },
);
# Retry at once by default, so a test driving consecutive attempts through the sweep is not held
# back by retryAfter; the subtests of the delays themselves restore real ones. The record's wall
# clock is the real one plus whatever fire_retry has advanced it by, so a retry fired by hand
# arrives at the time the worker's would.
local $Reservation::CREATE_UNRESOLVED_RETRY_DELAYS = [ 0, 0 ];
my $clockAdvance = 0;
local *Reservation::_create_now = sub () { return time + $clockAdvance; };

my $OWN_ID = 'c' x 64;

# Every continuation on the chain is called exactly once. A second call is reported by the once
# guard in the log, so the whole file asserts at the end that no chain it drove produced one.
sub second_calls {
   open my $fh, '<', "$tmp/test.log" or return ();
   return grep { /continuation called again; ignored/ } <$fh>;
}

sub write_record ($record) {
   open my $fh, '>', $Data::CONFIG->{reservationsPath} or die $!;
   print $fh encode_json($record), "\n";
   close $fh;
   return;
}

sub read_record {
   open my $fh, '<', $Data::CONFIG->{reservationsPath} or die $!;
   local $/;
   my $text = <$fh>;
   return length($text) ? decode_json($text) : undef;
}

# Writes a reservation stuck at $stage, as a worker that died mid-chain would have left it.
sub seed ( $stage, %extra ) {
   write_record({
      id => 'rid', name => 'devt', version => 2, data => { image => 'img:1' },
      createStatus => { stage => $stage, failed => 0, layers => {} },
      %extra,
   });
   return;
}

# The record as written, for an assertion about the JSON itself rather than the values it decodes to.
sub raw_record {
   open my $fh, '<', $Data::CONFIG->{reservationsPath} or die $!;
   local $/;
   return <$fh> // '';
}

sub status { return read_record()->{'createStatus'} // {}; }

# Whether $id's ownership lock can be taken right now, and so is held by no chain.
sub lock_free ($id) {
   my $lock = Util::tryLockFile( Reservation::_create_lock_path($id) ) or return 0;
   close $lock;
   return 1;
}

# A complete response, as the transport delivers one: parsed from the wire, so its content
# reports itself finished, which is what the pull stage reads to tell a completed stream from one
# cut off mid-way.
sub responds ( $code, $body = '' ) {
   my $wire = "HTTP/1.1 $code OK\r\nContent-Length: " . length($body) . "\r\n\r\n$body";
   return sub ( $cb, @ ) { $cb->( Mojo::Message::Response->new->parse($wire), undef ); };
}

# A 2xx chunked stream whose connection closed before the terminating chunk: the transport
# delivers it finished and without error, its content unfinished.
sub cut_off () {
   my $wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n{\"status\":\"a\"}\n\r\n";
   return sub ( $cb, @ ) { $cb->( Mojo::Message::Response->new->parse($wire), undef ); };
}

sub fails ($err) {
   return sub ( $cb, @ ) { $cb->( undef, $err ); };
}

# A container list body holding exactly $entry, or nothing.
sub holds ($entry) { return responds( 200, encode_json( defined($entry) ? [$entry] : [] ) ); }
sub owned_by ($id) { return { Id => $OWN_ID, Labels => { 'dev.dockside.reservation.id' => $id } }; }

# A Docker stub answering from a queue of responders per request kind, so a test can say what the
# first lookup returns and what the second one returns. Every request path is recorded, which is
# how "exactly one create was POSTed" and "no lookup was issued at all" are asserted.
sub docker ( $calls, %queues ) {
   return sub ( $socket, $path, $args, $cb ) {
      push @$calls, $path;
      my $kind = $path =~ m{^/containers/json}      ? 'lookup'
               : $path =~ m{^/containers/create}    ? 'create'
               : $path =~ m{/start$}                ? 'start'
               : $path =~ m{^/images/[^/]+/json$}   ? 'image'
               :                                      'other';
      my $queue = $queues{$kind};
      unless ( $queue && @$queue ) {
         push @$calls, "UNEXPECTED:$kind";
         return responds( 500, 'no fixture for this request' )->($cb);
      }
      my $responder = @$queue > 1 ? shift(@$queue) : $queue->[0];
      return $responder->( $cb, $path, $args );
   };
}

# Runs one reconciliation of 'rid' to settlement and reports what the caller was told. A chain
# whose stubbed transport answers at once settles before reconcile_one returns, or as soon as the
# timers it waits on within the attempt have fired; one answered on a later tick settles under
# the loop. Bounded, so a chain that never settles fails an assertion instead of hanging the
# suite. A timer left pending by an earlier attempt belongs to a driver that is gone, and is
# dropped first.
sub reconcile {
   my @settled;
   @pending = ();
   @events  = ();
   my $started = Reservation->reconcile_one( 'rid', sub ( $ok = undef, $err = undef ) {
      push @settled, { 'ok' => $ok, 'err' => $err };
      Mojo::IOLoop->stop;
   } );
   if ($started) {
      while ( !@settled && @pending ) {
         my $timer = shift @pending;
         push @timerDelays, $timer->[0];
         $timer->[1]->();
      }
      run_until_settled( sub { scalar @settled } );
   }
   return { 'started' => $started, 'settled' => \@settled };
}

# Fires the retry timer the last attempt left, as the worker's loop would once its delay had
# passed, advancing the record's clock by that delay first, and returns the delay, or undef
# when none is pending. The retry's own attempt settles before this returns, the stubbed
# transport answering at once.
sub fire_retry {
   return undef unless @pending;
   my $timer = shift @pending;
   $clockAdvance += $timer->[0];
   $timer->[1]->();
   return $timer->[0];
}

# Runs the loop until a settlement stops it, unless $settled already says the chain has settled:
# a stubbed transport that answers at once settles a chain before the call that started it
# returns. Bounded, so a chain that never settles fails an assertion instead of hanging the suite.
sub run_until_settled ($settled) {
   return if $settled->();
   my $timeout = Mojo::IOLoop->timer( 5 => sub { Mojo::IOLoop->stop } );
   Mojo::IOLoop->start;
   Mojo::IOLoop->remove($timeout);
   return;
}

sub unresolved ($err) { return ( ref($err) eq 'Exception' && $err->unresolved ) ? 1 : 0; }
sub reason ($err) { return ref($err) eq 'Exception' ? $err->msg : "$err"; }

# Every path that leaves an outcome unknown must leave the same durable state behind, so this is
# asserted as one thing rather than repeated field by field in each subtest.
sub is_recoverable ( $stage, $label ) {
   my $cs = status();
   is( $cs->{'stage'}, $stage, "$label: stage stays '$stage', so reconciliation still resumes it" );
   ok( !$cs->{'failed'}, "$label: not recorded as failed" );
   ok( !read_record()->{'expiryTime'}, "$label: no expiry, so nothing counts down to deletion" );
   ok( ref( $cs->{'unresolved'} ) eq 'HASH', "$label: records why the outcome is unknown" );
   return $cs->{'unresolved'};
}

subtest 'a create whose response is lost keeps the reservation recoverable' => sub {
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'lookup' => [ holds(undef) ],
      'create' => [ fails('connection reset by peer') ],
   );
   seed('creating');

   my $run = reconcile();
   is( scalar @{ $run->{'settled'} }, 1, 'settles exactly once' );
   ok( unresolved( $run->{'settled'}[0]{'err'} ), 'the caller is told the outcome is unresolved' );
   like( reason( $run->{'settled'}[0]{'err'} ), qr/connection reset/, 'and why' );

   my $diag = is_recoverable( 'creating', 'lost create response' );
   is( $diag->{'attempts'}, 1, 'lost create response: counted as one attempt' );
   ok( $diag->{'retryAfter'}, 'lost create response: names when it is worth asking again' );
};

subtest 'a 409 answered by this reservation own container is adopted, not failed' => sub {
   # The defect this stage exists for: a worker dies with POST /containers/create in flight, the
   # replacement's lookup finds nothing because Docker has not registered the name yet, its own
   # create collides with its predecessor's, and the container that request created then appears.
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'lookup' => [ holds(undef), holds(undef), holds( owned_by('rid') ) ],
      'create' => [ responds( 409, encode_json({ message => 'Conflict. The container name is in use' }) ) ],
      'start'  => [ responds(204) ],
   );
   seed('creating');

   my $run = reconcile();
   is( scalar @{ $run->{'settled'} }, 1, 'settles exactly once' );
   ok( $run->{'settled'}[0]{'ok'}, 'the reservation is reported created, not failed' );
   is( status()->{'stage'}, 'done', 'and reaches done' );
   is( read_record()->{'containerId'}, 'c' x 12, 'adopting the container its own create made' );
   is( scalar( grep { m{^/containers/create} } @calls ), 1, 'exactly one create is POSTed' );
   ok( !read_record()->{'expiryTime'}, 'nothing is expired' );
};

subtest 'a 409 whose name never appears stays unresolved, then succeeds once free' => sub {
   # Docker takes a container's name early in create and releases it again if that create fails,
   # so an empty lookup after a 409 is a transient state. Concluding a permanent collision from it
   # would fail a reservation that is about to be able to create perfectly well.
   my @calls;
   {
      local *Reservation::call_socket_api = docker( \@calls,
         'lookup' => [ holds(undef) ],
         'create' => [ responds( 409, '' ) ],
      );
      seed('creating');
      @timerDelays = ();

      my $run = reconcile();
      ok( unresolved( $run->{'settled'}[0]{'err'} ), 'a rolled-back conflict is unresolved' );
      is_recoverable( 'creating', 'conflict with no owner' );
      is( scalar( grep { m{^/containers/create} } @calls ), 1,
         'conflict with no owner: the inspection only looks, it never re-POSTs' );
      is( scalar( grep { m{^/containers/json} } @calls ), 4,
         'conflict with no owner: one lookup before the create, then the bounded inspection' );
      is_deeply( \@timerDelays, $Reservation::CREATE_CONFLICT_POLL_DELAYS,
         'conflict with no owner: each inspection lookup waits its configured delay' );
   }

   my @retry;
   local *Reservation::call_socket_api = docker( \@retry,
      'lookup' => [ holds(undef) ],
      'create' => [ responds( 201, encode_json({ Id => $OWN_ID }) ) ],
      'start'  => [ responds(204) ],
   );
   my $run = reconcile();
   ok( $run->{'settled'}[0]{'ok'}, 'the next attempt creates the container it could not before' );
   is( status()->{'stage'}, 'done', 'and reaches done' );
   ok( ref( status()->{'unresolved'} ) ne 'HASH', 'clearing the diagnostic it no longer needs' );
};

subtest 'a 409 answered by another reservation container is a definitive failure' => sub {
   for my $case (
      { 'name' => 'another reservation own label', 'entry' => owned_by('other') },
      { 'name' => 'no labels at all',              'entry' => { Id => 'b' x 64 } },
   ) {
      my @calls;
      local *Reservation::call_socket_api = docker( \@calls,
         'lookup' => [ holds(undef), holds( $case->{'entry'} ) ],
         'create' => [ responds( 409, '' ) ],
      );
      seed('creating');

      my $run = reconcile();
      is( unresolved( $run->{'settled'}[0]{'err'} ), 0,
         "$case->{'name'}: a confirmed collision is definitive" );
      like( reason( $run->{'settled'}[0]{'err'} ), qr/does not own/, "$case->{'name'}: and says so" );
      is( status()->{'stage'}, 'failed', "$case->{'name'}: recorded as failed" );
      ok( read_record()->{'expiryTime'}, "$case->{'name'}: and expired" );
   }
};

subtest 'a 409 answered by an unreadable container record stays unresolved' => sub {
   # A record with no usable id is not a container Docker actually reported - it confirms nothing,
   # least of all foreign ownership. Reading its absent label as proof of a collision would fail
   # and expire a reservation on the strength of a record that never established anything.
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'lookup' => [ holds(undef), holds( {} ) ],
      'create' => [ responds( 409, '' ) ],
   );
   seed('creating');

   my $run = reconcile();
   ok( unresolved( $run->{'settled'}[0]{'err'} ), 'an unreadable record is not a confirmed collision' );
   is_recoverable( 'creating', 'unreadable container record' );
};

subtest 'a create Docker refuses outright during recovery stays unresolved until confirmed' => sub {
   # The retry is not the reservation's first attempt: an earlier one, whose outcome this process
   # never learned, may have been issued by a worker that has since died and gone on to create a
   # container regardless. This retry's own refusal - whatever Docker's reason - says nothing
   # about that earlier request, so it must not terminalize the reservation until ownership is
   # actually confirmed, exactly as an unresolved 409 does not.
   for my $code ( 400, 404 ) {
      my @calls;
      local *Reservation::call_socket_api = docker( \@calls,
         'lookup' => [ holds(undef) ],
         'create' => [ responds( $code, encode_json({ message => 'no such image: img:1' }) ) ],
      );
      seed('creating');

      my $run = reconcile();
      ok( unresolved( $run->{'settled'}[0]{'err'} ),
         "HTTP $code: Docker's own refusal is not trusted over an unresolved predecessor" );
      like( reason( $run->{'settled'}[0]{'err'} ), qr/no such image/,
         "HTTP $code: keeping Docker's own reason" );
      is_recoverable( 'creating', "HTTP $code" );
      is( scalar( grep { m{^/containers/create} } @calls ), 1, "HTTP $code: exactly one create is POSTed" );
      is( scalar( grep { m{^/containers/json} } @calls ), 4,
         "HTTP $code: one lookup before the create, then the bounded ownership confirmation" );
   }
};

subtest 'a create Docker refuses outright on the first attempt is a definitive failure' => sub {
   # A fresh, non-recovery create has no predecessor request to account for: this attempt is the
   # only one that could have created anything, so its own refusal is the whole story.
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'create' => [ responds( 400, encode_json({ message => 'no such image: img:1' }) ) ],
   );
   seed('creating');
   my $reservation = Reservation::_reservation_reloaded('rid');

   my @settled;
   $reservation->_create_track(
      sub ($settle) { $reservation->_create_run_from_creating( { Image => 'img:1' }, 0, $settle ) },
      sub ( $ok = undef, $err = undef ) {
         push @settled, { 'ok' => $ok, 'err' => $err };
         Mojo::IOLoop->stop;
      } );
   run_until_settled( sub { scalar @settled } );

   is( scalar @settled, 1, 'settles exactly once' );
   is( unresolved( $settled[0]{'err'} ), 0, 'a first attempt is failed without any ownership check' );
   is( status()->{'stage'}, 'failed', 'recorded as failed' );
   ok( read_record()->{'expiryTime'}, 'and expired' );
   is( scalar( grep { m{^/containers/json} } @calls ), 0, 'no lookup is issued at all' );
};

subtest 'a create Docker refuses outright after a resumed pull is a definitive failure' => sub {
   # A record at 'pulling' has never issued a create: 'creating' is written to disk before any
   # create is posted. So the create that follows a resumed pull is this reservation's first, has
   # no predecessor whose container could be waiting under the name, and Docker's refusal of it
   # is the whole story - the reservation must fail and expire, not sit at 'launching' retrying an
   # invalid configuration for ever.
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'image'  => [ responds( 200, '{}' ) ],
      'create' => [ responds( 400, encode_json({ message => 'invalid configuration' }) ) ],
   );
   seed('pulling');

   my $run = reconcile();
   is( scalar @{ $run->{'settled'} }, 1, 'settles exactly once' );
   is( unresolved( $run->{'settled'}[0]{'err'} ), 0, 'a first attempt is failed without any ownership check' );
   like( reason( $run->{'settled'}[0]{'err'} ), qr/invalid configuration/, "keeping Docker's own reason" );
   is( status()->{'stage'}, 'failed', 'recorded as failed' );
   ok( read_record()->{'expiryTime'}, 'and expired' );
   is( scalar( grep { m{^/containers/create} } @calls ), 1, 'exactly one create is POSTed' );
   is( scalar( grep { m{^/containers/json} } @calls ), 0, 'no lookup is issued at all' );
};

subtest 'a create success carrying no usable id keeps the reservation recoverable' => sub {
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'lookup' => [ holds(undef) ],
      'create' => [ responds( 201, '{not valid json' ) ],
   );
   seed('creating');

   my $run = reconcile();
   ok( unresolved( $run->{'settled'}[0]{'err'} ),
      'Docker accepted the create, so an unreadable body is not proof nothing exists' );
   is_recoverable( 'creating', 'unusable create response' );
   ok( !defined( read_record()->{'containerId'} ), 'unusable create response: no id is invented' );
};

subtest 'a create success carrying a malformed id keeps the reservation recoverable' => sub {
   # The body decodes cleanly this time, unlike the previous case, but 'garbage' is not a shape
   # Docker's own container ids ever take. Trusting it would persist an id nothing can start or
   # look up, and drive the start stage against a container that does not exist under it.
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'lookup' => [ holds(undef) ],
      'create' => [ responds( 201, encode_json({ Id => 'garbage' }) ) ],
   );
   seed('creating');

   my $run = reconcile();
   ok( unresolved( $run->{'settled'}[0]{'err'} ),
      'an id that is not Docker\'s own hex form is not proof nothing exists' );
   is_recoverable( 'creating', 'malformed create response id' );
   ok( !defined( read_record()->{'containerId'} ), 'malformed create response id: no id is invented' );
   is( scalar( grep { m{/start$} } @calls ), 0,
      'malformed create response id: no start is issued against an unusable id' );
};

subtest 'a lookup that establishes nothing never authorizes a create' => sub {
   # The lookup is what decides whether a recovery may POST a create at all. Reading a failed or
   # unreadable lookup as "nothing holds this name" would issue a create against a name that may
   # already hold this reservation's own container.
   for my $case (
      { 'name' => 'the lookup request fails',  'lookup' => fails('connection refused') },
      { 'name' => 'the lookup returns 500',    'lookup' => responds( 500, 'server error' ) },
      { 'name' => 'the list will not decode',  'lookup' => responds( 200, '[not json' ) },
      { 'name' => 'the list is not a list',    'lookup' => responds( 200, '{}' ) },
      { 'name' => 'two containers match',      'lookup' => responds( 200,
           encode_json( [ owned_by('rid'), owned_by('other') ] ) ) },
   ) {
      my @calls;
      local *Reservation::call_socket_api = docker( \@calls, 'lookup' => [ $case->{'lookup'} ] );
      seed('creating');

      my $run = reconcile();
      ok( unresolved( $run->{'settled'}[0]{'err'} ), "$case->{'name'}: unresolved" );
      is( scalar( grep { m{^/containers/create} } @calls ), 0,
         "$case->{'name'}: no create is issued" );
      is( status()->{'stage'}, 'creating', "$case->{'name'}: stays resumable" );
      ok( !read_record()->{'expiryTime'}, "$case->{'name'}: and unexpired" );
   }
};

subtest 'a start whose outcome is unknown is retried, and tolerates an already-running container' => sub {
   my @calls;
   {
      local *Reservation::call_socket_api = docker( \@calls, 'start' => [ fails('socket closed') ] );
      seed( 'starting', containerId => 'c' x 12 );

      my $run = reconcile();
      ok( unresolved( $run->{'settled'}[0]{'err'} ), 'a lost start response is unresolved' );
      is_recoverable( 'starting', 'lost start response' );
      is( scalar( grep { m{^/containers/json} } @calls ), 0,
         'lost start response: a start never enters the create path name inspection' );
   }

   local *Reservation::call_socket_api = docker( \@calls, 'start' => [ responds(304) ] );
   my $run = reconcile();
   ok( $run->{'settled'}[0]{'ok'}, 'the retry finds the container already running and settles' );
   is( status()->{'stage'}, 'done', 'reaching done' );
};

subtest 'a start Docker answers with 409 does not enter name-collision handling' => sub {
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls, 'start' => [ responds( 409, 'conflict' ) ] );
   seed( 'starting', containerId => 'c' x 12 );

   my $run = reconcile();
   ok( unresolved( $run->{'settled'}[0]{'err'} ),
      'a 409 has no name-collision meaning for start, so it establishes nothing' );
   is( scalar( grep { m{^/containers/json} } @calls ), 0, 'and no container is looked up by name' );
   is( status()->{'stage'}, 'starting', 'the reservation stays resumable' );
};

subtest 'a start Docker answers with 404 ends recovery definitively' => sub {
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'start' => [ responds( 404, encode_json({ message => 'no such container' }) ) ] );
   seed( 'starting', containerId => 'c' x 12 );

   my $run = reconcile();
   is( unresolved( $run->{'settled'}[0]{'err'} ), 0,
      'a container Docker says does not exist is a confirmed absence, not an unknown' );
   is( status()->{'stage'}, 'failed', 'recorded as failed' );
   ok( read_record()->{'expiryTime'}, 'and expired, so the record is eventually cleaned up' );
};

sub epoch ($stamp) { return Time::Piece->strptime( $stamp, '%Y-%m-%d %H:%M:%S' )->epoch; }

subtest 'the recording worker retries at the configured delays, and the third unresolved outcome is failed and retained' => sub {
   local $Reservation::CREATE_UNRESOLVED_RETRY_DELAYS = [ 15, 45 ];
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'lookup' => [ holds(undef) ],
      'create' => [ fails('connection reset by peer') ],
   );
   seed('creating');

   reconcile();
   my $first = status()->{'unresolved'};
   is( $first->{'attempts'}, 1, 'the first unresolved outcome is attempt one' );
   like( raw_record(), qr/"attempts":1[,}]/, 'persisted as a number, not a string' );
   is( epoch( $first->{'retryAfter'} ) - epoch( $first->{'since'} ), 15, 'and names the first delay as when the next may run' );
   is( scalar @pending, 1, 'the worker holds one retry timer' );
   is( $pending[0][0], 15, 'at the first delay' );
   is_deeply( \@events, [qw(hold release timer)],
      'the hold against recycling is released, after the lock, before the retry is armed' );

   my $issued = scalar @calls;
   fire_retry();
   ok( scalar @calls > $issued, 'the retry issues a Docker request' );
   my $second = status()->{'unresolved'};
   is( $second->{'attempts'}, 2, 'the second unresolved outcome is attempt two, read from disk' );
   is( $second->{'since'}, $first->{'since'}, 'the time it was first unresolved is kept' );
   is( status()->{'stage'}, 'creating', 'the stage is unchanged' );
   is( scalar @pending, 1, 'one retry timer again' );
   is( $pending[0][0], 45, 'at the second delay' );

   fire_retry();
   is( status()->{'stage'}, 'failed', 'the third unresolved outcome is recorded as failed' );
   ok( status()->{'failed'}, 'terminally' );
   ok( !read_record()->{'expiryTime'}, 'with no expiry, so the record stays' );
   like( status()->{'error'}, qr/^after 3 attempts, a container may exist under name 'devt': .*connection reset by peer$/,
      'the reason states the count, what may exist, and the last reason' );
   ok( !ref( status()->{'unresolved'} ), 'the unresolved diagnostic is cleared, the question being settled' );
   is( scalar @pending, 0, 'and no further retry is scheduled' );
   is( scalar( grep { m{^/containers/create} } @calls ), 3, 'three creates were posted in all' );
   ok( status()->{'entered'}{'failed'}, 'the failure is entered like any other' );
};

subtest 'the bound tells the consumer a definitive failure, and states what exists at starting' => sub {
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls, 'start' => [ fails('connection reset by peer') ] );
   seed( 'starting', containerId => 'c' x 12, createStatus => { stage => 'starting', failed => 0, layers => {},
      unresolved => { reason => 'earlier', attempts => 2, since => '2026-01-01 00:00:00', retryAfter => '2026-01-01 00:00:45' } } );

   my $run = reconcile();
   is( $run->{'started'}, 1, 'a sweep past retryAfter runs the attempt' );
   ok( !unresolved( $run->{'settled'}[0]{'err'} ), 'the consumer is told a definitive failure' );
   like( reason( $run->{'settled'}[0]{'err'} ), qr/^after 3 attempts; container cccccccccccc exists and may be running: .*connection reset/,
      'naming the container that exists' );
   is( status()->{'stage'}, 'failed', 'recorded as failed' );
   ok( !read_record()->{'expiryTime'}, 'and retained' );
};

subtest 'the count comes from disk and belongs to one stage' => sub {
   local *Reservation::call_socket_api = docker( [],
      'lookup' => [ holds(undef) ],
      'create' => [ responds( 201, encode_json({ Id => $OWN_ID }) ) ],
      'start'  => [ fails('connection reset by peer') ],
   );
   seed( 'creating', createStatus => { stage => 'creating', failed => 0, layers => {},
      unresolved => { reason => 'earlier', attempts => 2, since => '2026-01-01 00:00:00', retryAfter => '2026-01-01 00:00:45' } } );

   reconcile();
   is( status()->{'stage'}, 'starting', 'the create succeeds and the start is unresolved' );
   is( status()->{'unresolved'}{'attempts'}, 1, 'counted from one at the new stage, not three' );
   isnt( status()->{'unresolved'}{'since'}, '2026-01-01 00:00:00', 'with its own since' );
};

subtest 'a retry finding the record settled by another driver issues nothing' => sub {
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'lookup' => [ holds(undef) ],
      'create' => [ fails('connection reset by peer') ],
   );
   seed('creating');
   reconcile();
   is( scalar @pending, 1, 'a retry is pending' );

   my $record = read_record();
   $record->{'createStatus'} = { stage => 'done', failed => 0, layers => {}, unresolved => 0 };
   write_record($record);
   my $issued = scalar @calls;
   fire_retry();
   is( scalar @calls, $issued, 'the retry, finding a terminal stage under the lock, contacts Docker no further' );
   is( status()->{'stage'}, 'done', 'and leaves the record as it found it' );
};

subtest 'a reservation within its retry cooldown is skipped without contacting Docker' => sub {
   local $Reservation::CREATE_UNRESOLVED_RETRY_DELAYS = [ 600, 600 ];
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'lookup' => [ holds(undef) ],
      'create' => [ fails('connection reset by peer') ],
   );
   seed('creating');

   reconcile();
   my $issued = scalar @calls;

   # The ownership lock is free at this point - it is released when the attempt settles - so the
   # cooldown is the only thing pacing a sibling worker's sweep.
   my $lock = Util::tryLockFile( Reservation::_create_lock_path('rid') );
   ok( $lock, 'the previous attempt released its ownership lock' );
   close $lock;

   my $run = reconcile();
   is( $run->{'started'}, 0, 'the next pass declines to resume it yet' );
   is( scalar @calls, $issued, 'and issues no Docker request at all' );
   is( status()->{'unresolved'}{'attempts'}, 1, 'the skipped pass is not counted as an attempt' );

   ok( Util::tryLockFile( Reservation::_create_lock_path('rid') ),
      'the skipped pass releases the lock it took to check' );
};

subtest 'a container created but not recorded is recovered, not failed' => sub {
   # The write of the new container's id is the one place a storage failure can lose a container
   # entirely: Docker has made it, and only the record saying so failed.
   my @calls;
   my $realUpdate = \&Reservation::update;
   local *Reservation::update = sub ( $self, $fields, @rest ) {
      die Exception->new( 'dbg' => 'fixture write failure' ) if exists $fields->{'containerId'};
      return $realUpdate->( $self, $fields, @rest );
   };
   local *Reservation::call_socket_api = docker( \@calls,
      'lookup' => [ holds(undef) ],
      'create' => [ responds( 201, encode_json({ Id => $OWN_ID }) ) ],
   );
   seed('creating');

   my $run = reconcile();
   ok( unresolved( $run->{'settled'}[0]{'err'} ),
      'a create that succeeded but could not be recorded is unresolved, not failed' );
   like( reason( $run->{'settled'}[0]{'err'} ), qr/could not record its id/, 'and says so' );
   is_recoverable( 'creating', 'unrecorded container id' );
   is( scalar( grep { m{/start$} } @calls ), 0,
      'unrecorded container id: no start is issued against a transition nothing recorded' );
};

subtest 'a write failure recording done does not overwrite what was actually persisted' => sub {
   # Docker has already started the container - only the write recording that this reservation
   # reached 'done' fails. The unresolved outcome recorded next must describe the stage still on
   # disk ('starting'), not the stage this attempt only tried and failed to reach: a record left
   # at 'done' with an unresolved diagnostic is not a stage anything ever resumes.
   my @calls;
   my $realUpdate = \&Reservation::update;
   local *Reservation::update = sub ( $self, $fields, @rest ) {
      die Exception->new( 'dbg' => 'fixture write failure' )
         if ref( $fields->{'createStatus'} ) eq 'HASH'
         && ( $fields->{'createStatus'}{'stage'} // '' ) eq 'done';
      return $realUpdate->( $self, $fields, @rest );
   };
   local *Reservation::call_socket_api = docker( \@calls, 'start' => [ responds(204) ] );
   seed( 'starting', containerId => 'c' x 12 );

   my $run = reconcile();
   ok( unresolved( $run->{'settled'}[0]{'err'} ), 'the caller is told completion could not be recorded' );
   is( status()->{'stage'}, 'starting', 'the record still shows the last stage that actually reached disk' );
   ok( ref( status()->{'unresolved'} ) eq 'HASH', 'and records why' );
   ok( !read_record()->{'expiryTime'}, 'so nothing counts down to deletion' );
};

subtest 'a settlement consumer that throws cannot rewrite the outcome or run twice' => sub {
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'lookup' => [ holds(undef) ],
      'create' => [ responds( 201, encode_json({ Id => $OWN_ID }) ) ],
      'start'  => [ responds(204) ],
   );
   seed('creating');

   my $entered = 0;
   my $reservation = Reservation::_reservation_reloaded('rid');
   @events = ();
   $reservation->_create_track(
      sub ($settle) { $reservation->_create_run_from_creating( { Image => 'img:1' }, 1, $settle ) },
      sub (@) {
         $entered++;
         Mojo::IOLoop->stop;
         die "fixture consumer failure\n";
      } );
   run_until_settled( sub { $entered } );

   is( $entered, 1, 'the consumer is entered exactly once' );
   is( status()->{'stage'}, 'done', 'and its own exception does not turn a success into a failure' );
   ok( !read_record()->{'expiryTime'}, 'nor expire a reservation whose container is running' );
   is( Reservation->create_in_flight_count(), 0, 'the chain is still released from the in-flight set' );
   is_deeply( \@events, [qw(hold release)], 'and its hold against recycling is released' );
};

subtest 'a resumed chain does not need a create body it cannot use' => sub {
   # cmdline_json reads the reservation's profile, so an unrelated profile change can make it
   # throw. That must not terminate a reservation whose container already exists.
   local *Reservation::cmdline_json = sub (@) { die Exception->new( 'msg' => 'profile is unusable' ); };

   my @calls;
   {
      local *Reservation::call_socket_api = docker( \@calls, 'start' => [ responds(204) ] );
      seed( 'starting', containerId => 'c' x 12 );

      my $run = reconcile();
      ok( $run->{'settled'}[0]{'ok'}, 'a reservation at starting is started without compiling one' );
      is( status()->{'stage'}, 'done', 'and reaches done' );
   }

   my @adopt;
   local *Reservation::call_socket_api = docker( \@adopt,
      'lookup' => [ holds( owned_by('rid') ) ],
      'start'  => [ responds(204) ],
   );
   seed('creating');

   my $run = reconcile();
   ok( $run->{'settled'}[0]{'ok'},
      'a reservation at creating adopts the container it already owns, which needs no body' );
   is( read_record()->{'containerId'}, 'c' x 12, 'recording the adopted id' );
   is( scalar( grep { m{^/containers/create} } @adopt ), 0, 'without attempting a create' );
};

subtest 'a reservation with no container to adopt and a broken body stays unresolved until confirmed' => sub {
   # A body that cannot be compiled says nothing about whether a container was already created,
   # and neither does a single absent snapshot: the create that would have made one may have been
   # issued by a worker that has since died, whose request Docker went on processing regardless.
   local *Reservation::cmdline_json = sub (@) { die Exception->new( 'msg' => 'profile is unusable' ); };

   my @calls;
   local *Reservation::call_socket_api = docker( \@calls, 'lookup' => [ holds(undef) ] );
   seed('creating');

   my $run = reconcile();
   ok( unresolved( $run->{'settled'}[0]{'err'} ),
      'an absent snapshot does not rule out a predecessor still completing' );
   like( reason( $run->{'settled'}[0]{'err'} ), qr/profile is unusable/, 'reporting the real reason' );
   is_recoverable( 'creating', 'broken body, nothing found yet' );
   is( scalar( grep { m{^/containers/create} } @calls ), 0, 'no create is attempted' );
   is( scalar( grep { m{^/containers/json} } @calls ), 3, 'the bounded ownership confirmation runs' );
};

subtest 'a reservation confirmed to own no container is failed when its body cannot be built' => sub {
   local *Reservation::cmdline_json = sub (@) { die Exception->new( 'msg' => 'profile is unusable' ); };

   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'lookup' => [ holds(undef), holds( owned_by('other') ) ] );
   seed('creating');

   my $run = reconcile();
   is( unresolved( $run->{'settled'}[0]{'err'} ), 0,
      'a confirmed foreign container settles the question definitively' );
   like( reason( $run->{'settled'}[0]{'err'} ), qr/owns no container/, 'reporting the real reason' );
   is( status()->{'stage'}, 'failed', 'recorded as failed' );
   ok( read_record()->{'expiryTime'}, 'and expired' );
};

subtest 'a fresh create whose outcome is lost is accounted for by the next attempt' => sub {
   # The handover between the two kinds of create attempt. A fresh create() records 'creating'
   # before posting, so when its post's outcome is lost the record left behind is exactly the one
   # a later pass reads as "a prior create may have been issued": that pass looks the name up
   # first and adopts the container the lost request made, rather than posting a second create.
   my @calls;
   my $reservation;
   {
      local *Reservation::call_socket_api = docker( \@calls,
         'image'  => [ responds( 200, '{}' ) ],
         'create' => [ fails('connection reset by peer') ],
      );
      write_record({ id => 'rid', name => 'devt', version => 2, data => { image => 'img:1' } });
      $reservation = Reservation::_reservation_reloaded('rid');

      my @acked;
      $reservation->create( sub ( $ok = undef, $err = undef ) { push @acked, { 'ok' => $ok, 'err' => $err }; } );
      is( scalar @acked, 1, 'create() acknowledges once, immediately' );
      ok( $acked[0]{'ok'}, 'and successfully' );

      my $timeout = Mojo::IOLoop->timer( 5 => sub { Mojo::IOLoop->stop } );
      Mojo::IOLoop->recurring( 0.05 => sub { Mojo::IOLoop->stop unless Reservation->create_in_flight_count() } );
      Mojo::IOLoop->start;
      Mojo::IOLoop->remove($timeout);

      is( Reservation->create_in_flight_count(), 0, 'the fresh chain settles' );
      is_recoverable( 'creating', 'fresh create with a lost outcome' );
      is( scalar( grep { m{^/containers/json} } @calls ), 0, 'a first create looks nothing up beforehand' );
   }

   my @next;
   local *Reservation::call_socket_api = docker( \@next,
      'lookup' => [ holds( owned_by('rid') ) ],
      'start'  => [ responds(204) ],
   );
   my $run = reconcile();
   ok( $run->{'settled'}[0]{'ok'}, 'the next pass adopts the container the lost request made' );
   is( status()->{'stage'}, 'done', 'and reaches done' );
   is( scalar( grep { m{^/containers/create} } @next ), 0, 'without posting a second create' );
};

subtest 'a server error answering a create or start with a possible predecessor is unresolved' => sub {
   # A 5xx says Docker failed somewhere, not where: the mutation may have been committed before
   # whatever failed. With a prior create possibly outstanding, or a container that certainly
   # exists, nothing here justifies a definitive failure.
   {
      my @calls;
      local *Reservation::call_socket_api = docker( \@calls,
         'lookup' => [ holds(undef) ],
         'create' => [ responds( 500, encode_json({ message => 'internal error' }) ) ],
      );
      seed('creating');
      my $run = reconcile();
      ok( unresolved( $run->{'settled'}[0]{'err'} ), 'create 500: unresolved' );
      is_recoverable( 'creating', 'create 500' );
      is( scalar( grep { m{^/containers/create} } @calls ), 1, 'create 500: exactly one create is POSTed' );
   }
   {
      my @calls;
      local *Reservation::call_socket_api = docker( \@calls, 'start' => [ responds( 500, 'internal error' ) ] );
      seed( 'starting', containerId => 'c' x 12 );
      my $run = reconcile();
      ok( unresolved( $run->{'settled'}[0]{'err'} ), 'start 500: unresolved' );
      is_recoverable( 'starting', 'start 500' );
      is( scalar( grep { m{^/containers/json} } @calls ), 0, 'start 500: no name inspection' );
   }
};

subtest 'a stage entry that cannot be recorded issues no mutation' => sub {
   # 'creating' and 'starting' are written before their mutation is posted, and that write is what
   # lets any later pass account for the mutation. A post made after a failed write would be one no
   # record anywhere admits was attempted.
   my $realUpdate = \&Reservation::update;
   {
      local *Reservation::update = sub ( $self, $fields, @rest ) {
         die Exception->new( 'dbg' => 'fixture write failure' )
            if ref( $fields->{'createStatus'} ) eq 'HASH'
            && ( $fields->{'createStatus'}{'stage'} // '' ) eq 'creating';
         return $realUpdate->( $self, $fields, @rest );
      };
      my @calls;
      local *Reservation::call_socket_api = docker( \@calls, 'image' => [ responds( 200, '{}' ) ] );
      seed('pulling');
      my $run = reconcile();
      ok( unresolved( $run->{'settled'}[0]{'err'} ), 'creating unrecorded: reported unresolved' );
      is( status()->{'stage'}, 'pulling', 'creating unrecorded: the record shows the last stage that reached disk' );
      ok( !read_record()->{'expiryTime'}, 'creating unrecorded: nothing is expired' );
      is( scalar( grep { m{^/containers/create} } @calls ), 0, 'creating unrecorded: no create is posted' );
      ok( Util::tryLockFile( Reservation::_create_lock_path('rid') ), 'creating unrecorded: the lock is released' );
   }
   {
      local *Reservation::update = sub ( $self, $fields, @rest ) {
         die Exception->new( 'dbg' => 'fixture write failure' )
            if ref( $fields->{'createStatus'} ) eq 'HASH'
            && ( $fields->{'createStatus'}{'stage'} // '' ) eq 'starting';
         return $realUpdate->( $self, $fields, @rest );
      };
      my @calls;
      local *Reservation::call_socket_api = docker( \@calls,
         'lookup' => [ holds(undef) ],
         'create' => [ responds( 201, encode_json({ Id => $OWN_ID }) ) ],
      );
      seed('creating');
      my $run = reconcile();
      ok( unresolved( $run->{'settled'}[0]{'err'} ), 'starting unrecorded: reported unresolved' );
      is( status()->{'stage'}, 'creating', 'starting unrecorded: the record shows the last stage that reached disk' );
      is( read_record()->{'containerId'}, 'c' x 12, 'starting unrecorded: but the container id it did record' );
      is( scalar( grep { m{/start$} } @calls ), 0, 'starting unrecorded: no start is posted' );
   }
};

subtest 'an outcome that cannot be recorded is reported unresolved, whatever it was' => sub {
   # If the write recording an outcome fails, the record still says what it said before the
   # attempt: as far as any other process can tell, the attempt has not concluded. That is what
   # the consumer is told, and the cleanup still happens, so the next pass simply tries again.
   my $realUpdate = \&Reservation::update;
   local *Reservation::update = sub ( $self, $fields, @rest ) {
      die Exception->new( 'dbg' => 'fixture write failure' )
         if ref( $fields->{'createStatus'} ) eq 'HASH'
         && ( ref( $fields->{'createStatus'}{'unresolved'} ) eq 'HASH'
              || ( $fields->{'createStatus'}{'stage'} // '' ) eq 'failed' );
      return $realUpdate->( $self, $fields, @rest );
   };
   for my $case (
      { 'name' => 'an unresolved outcome', 'create' => fails('connection reset by peer') },
      { 'name' => 'a definitive failure',  'create' => responds( 400, encode_json({ message => 'bad request' }) ) },
   ) {
      my @calls;
      local *Reservation::call_socket_api = docker( \@calls, 'create' => [ $case->{'create'} ] );
      seed('creating');
      my $reservation = Reservation::_reservation_reloaded('rid');
      my @settled;
      @pending = ();
      @events  = ();
      $reservation->_create_track(
         sub ($settle) { $reservation->_create_run_from_creating( { Image => 'img:1' }, 0, $settle ) },
         sub ( $ok = undef, $err = undef ) { push @settled, { 'ok' => $ok, 'err' => $err }; Mojo::IOLoop->stop; } );
      run_until_settled( sub { scalar @settled } );

      is( scalar @settled, 1, "$case->{'name'} unrecorded: settles exactly once" );
      ok( unresolved( $settled[0]{'err'} ), "$case->{'name'} unrecorded: reported unresolved" );
      is( status()->{'stage'}, 'creating', "$case->{'name'} unrecorded: the record is unchanged" );
      ok( !status()->{'failed'} && !read_record()->{'expiryTime'},
         "$case->{'name'} unrecorded: neither failed nor expired" );
      is( Reservation->create_in_flight_count(), 0, "$case->{'name'} unrecorded: the chain is released" );
      is( scalar @pending, 0, "$case->{'name'} unrecorded: no retry is scheduled, the count having not advanced" );
      is_deeply( \@events, [qw(hold release)], "$case->{'name'} unrecorded: the hold against recycling is released" );
   }
};

subtest 'a chain holds this worker against recycling from tracking until it settles, whatever the outcome' => sub {
   for my $case (
      { 'name' => 'done', 'stage' => 'starting', 'start' => responds(204), 'events' => [qw(hold release)] },
      { 'name' => 'a definitive failure', 'stage' => 'starting', 'start' => responds(404), 'events' => [qw(hold release)] },
      { 'name' => 'an unresolved outcome', 'stage' => 'starting', 'start' => fails('connection reset by peer'),
        'events' => [qw(hold release timer)] },
   ) {
      local *Reservation::call_socket_api = docker( [], 'start' => [ $case->{'start'} ] );
      seed( $case->{'stage'}, containerId => 'c' x 12 );
      my $run = reconcile();
      is( scalar @{ $run->{'settled'} }, 1, "$case->{'name'}: settles" );
      is_deeply( \@events, $case->{'events'}, "$case->{'name'}: one hold, released after the lock" );
   }

   # Two chains live at once in one worker are two holds, each released as its own chain settles.
   @events = ();
   my @settle;
   for my $id ( 'rid', 'rid2' ) {
      my $reservation = bless { 'id' => $id }, 'Reservation';
      $reservation->_create_track( sub ($settle) { push @settle, $settle; } );
   }
   is_deeply( \@events, [qw(hold hold)], 'two live chains have taken two holds' );
   is( Reservation->create_in_flight_count(), 2, 'and are both in flight' );
   $settle[0]->( 1, undef );
   is_deeply( \@events, [qw(hold hold release)], 'the first to settle releases one' );
   $settle[1]->( 1, undef );
   is_deeply( \@events, [qw(hold hold release release)], 'the second releases the other' );
   is( Reservation->create_in_flight_count(), 0, 'neither is in flight' );

   # A chain refused before it is tracked takes nothing: the lock held by another driver, or a
   # duplicate create for a reservation whose createStatus is already set.
   local *Reservation::call_socket_api = docker( [] );
   seed('creating');
   @events = ();
   my $lock = Util::tryLockFile( Reservation::_create_lock_path('rid') );
   my @refused;
   Reservation::_reservation_reloaded('rid')->create( sub ( $ok = undef, $err = undef ) { push @refused, $err; } );
   like( reason( $refused[0] ), qr/already has a create in progress/, 'a create finding the lock held is refused' );
   is( Reservation->reconcile_one('rid'), 0, 'as is a reconciliation' );
   close $lock;
   Reservation::_reservation_reloaded('rid')->create( sub ( $ok = undef, $err = undef ) { push @refused, $err; } );
   like( reason( $refused[1] ), qr/already has a createStatus set/, 'and a duplicate create' );
   is_deeply( \@events, [], 'none of which took a hold' );
};

subtest 'a preflight lookup finding another owner is a definitive failure without a create' => sub {
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls, 'lookup' => [ holds( owned_by('other') ) ] );
   seed('creating');
   my $run = reconcile();
   is( unresolved( $run->{'settled'}[0]{'err'} ), 0, 'a confirmed foreign owner is definitive' );
   is( status()->{'stage'}, 'failed', 'recorded as failed' );
   ok( read_record()->{'expiryTime'}, 'and expired' );
   is( scalar( grep { m{^/containers/create} } @calls ), 0, 'no create is posted against a taken name' );
};

subtest 'each ownership-confirmation lookup is capped to what remains of the inspection budget' => sub {
   # The ownership lock is held for the whole inspection, so a lookup that stalls must be cut off
   # by the budget rather than by the transport's own default. That is enforced by handing each
   # request a timeout no larger than the budget left when it is issued.
   local $Reservation::CREATE_CONFLICT_POLL_BUDGET_SECONDS = 2;
   my @timeouts;
   local *Reservation::call_socket_api = sub ( $socket, $path, $args, $cb ) {
      push @timeouts, $args->{'request_timeout'} if $path =~ m{^/containers/json};
      return $path =~ m{^/containers/create} ? responds( 409, '' )->($cb) : holds(undef)->($cb);
   };
   seed('creating');
   @timerDelays = ();
   reconcile();
   is( scalar @timeouts, 4, 'one preflight lookup, then the bounded inspection issues its three' );
   is_deeply( \@timerDelays, $Reservation::CREATE_CONFLICT_POLL_DELAYS, 'each at its configured delay' );
   ok( !defined( $timeouts[0] ), 'the preflight lookup runs under no inspection budget' );
   ok( ( grep { defined($_) && $_ > 0 && $_ <= 2 } @timeouts[ 1 .. 3 ] ) == 3,
      'every inspection lookup carries a positive timeout within the budget' );
};

subtest 'a chain records when each stage was first entered' => sub {
   local *Reservation::call_socket_api = docker( [],
      'image'  => [ responds( 200, '{}' ) ],
      'create' => [ responds( 201, encode_json({ Id => $OWN_ID }) ) ],
      'start'  => [ responds(204) ],
   );
   write_record({ id => 'rid', name => 'devt', version => 2, data => { image => 'img:1' } });
   my $before = Time::HiRes::time();
   Reservation::_reservation_reloaded('rid')->create( sub (@) { } );
   run_until_settled( sub { !Reservation->create_in_flight_count() } );
   my $after = Time::HiRes::time();

   is( status()->{'stage'}, 'done', 'the fresh chain reaches done' );
   my $entered = status()->{'entered'};
   is_deeply( [ sort keys %{ $entered // {} } ], [qw(creating done pulling starting)],
      'every stage the chain passed through has an entry' );
   my @times = @{$entered}{qw(pulling creating starting done)};
   ok( ( grep { /^\d+\.\d+$/ } @times ) == 4, 'each is a fractional epoch' )
      or diag( join( ' ', @times ) );
   ok( $times[0] >= $before && $times[-1] <= $after, 'within the time the chain ran' );
   ok( ( grep { $times[$_] <= $times[ $_ + 1 ] } 0 .. 2 ) == 3, 'in stage order' );
};

subtest 'a stage re-entered by a later attempt keeps its first-entry time' => sub {
   my $original = { pulling => 1000.25, creating => 1012.5 };
   seed( 'creating', createStatus => { stage => 'creating', failed => 0, layers => {}, entered => {%$original} } );

   {
      local *Reservation::call_socket_api = docker( [],
         'lookup' => [ holds(undef) ],
         'create' => [ fails('connection reset by peer') ],
      );
      reconcile();
      is_recoverable( 'creating', 'unresolved re-entry' );
      is_deeply( status()->{'entered'}, $original, 'an unresolved attempt at the same stage adds nothing' );
   }

   local *Reservation::call_socket_api = docker( [],
      'lookup' => [ holds(undef) ],
      'create' => [ responds( 201, encode_json({ Id => $OWN_ID }) ) ],
      'start'  => [ responds(204) ],
   );
   reconcile();
   is( status()->{'stage'}, 'done', 'the next attempt completes the chain' );
   ok( !ref( status()->{'unresolved'} ), 'and the advance clears the unresolved diagnostic' );
   my $entered = status()->{'entered'};
   is( $entered->{$_}, $original->{$_}, "$_ keeps the time it was first entered" ) for qw(pulling creating);
   ok( $entered->{'starting'} > $original->{'creating'} && $entered->{'done'} >= $entered->{'starting'},
      'the stages it advanced through are entered after it, in order' );
};

subtest 'a failed record carries the time it failed' => sub {
   seed( 'pulling', createStatus => { stage => 'pulling', failed => 0, layers => {}, entered => { pulling => 1000.25 } } );
   local *Reservation::call_socket_api = docker( [],
      'image' => [ responds( 404, '' ) ],
      'other' => [ responds( 404, '{"message":"manifest unknown"}' ) ],
   );
   my $run = reconcile();
   ok( !unresolved( $run->{'settled'}[0]{'err'} ), 'a pull Docker refuses is a definitive failure' );
   is( status()->{'stage'}, 'failed', 'recorded as failed' );
   is( status()->{'entered'}{'pulling'}, 1000.25, 'the pull entry is kept' );
   like( status()->{'entered'}{'failed'} // '', qr/^\d+\.\d+$/, 'and the failure is entered at a fractional epoch' );
};

# A pull responder: feeds each of @events to the stage's stream reader as one line, then completes
# with $completion (a responder).
sub streams ( $completion, @events ) {
   return sub ( $cb, $path, $args ) {
      $args->{'on_read'}->( encode_json($_) . "\n" ) for @events;
      return $completion->($cb);
   };
}

subtest 'a pull cut off at the socket is unresolved at pulling, and the next attempt completes it' => sub {
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'image'  => [ responds( 404, '' ), responds( 200, '{}' ) ],
      'other'  => [ streams( fails('Premature connection close'),
                       { id => 'layer1', status => 'Pull complete' },
                       { id => 'layer2', status => 'Downloading', progressDetail => { current => 1, total => 4 } } ) ],
      'create' => [ responds( 201, encode_json({ Id => $OWN_ID }) ) ],
      'start'  => [ responds(204) ],
   );
   seed('pulling');

   my $run = reconcile();
   ok( unresolved( $run->{'settled'}[0]{'err'} ), 'the consumer is told the outcome is unresolved' );
   like( reason( $run->{'settled'}[0]{'err'} ), qr/pull of 'img:1' ended without a response: Premature connection close/,
      'naming the pull and the transport error' );
   my $diag = is_recoverable( 'pulling', 'pull cut off' );
   is( $diag->{'attempts'}, 1, 'pull cut off: counted as one attempt' );
   is_deeply( [ sort keys %{ status()->{'layers'} } ], [qw(layer1 layer2)], 'pull cut off: the layer snapshot is kept' );
   is( scalar @pending, 1, 'pull cut off: the worker holds a retry' );

   $run = reconcile();
   ok( $run->{'settled'}[0]{'ok'}, 'the next attempt completes the chain' );
   is( status()->{'stage'}, 'done', 'reaching done' );
   is( scalar( grep { m{^/images/create} } @calls ), 1, 'the pull was issued once, the image being present on the retry' );
   ok( !ref( status()->{'unresolved'} ), 'and the diagnostic is cleared' );
};

subtest 'a pull whose stream ends before its terminating chunk is unresolved, not complete' => sub {
   # The connection closed mid-stream after the status line arrived: the transport reports no
   # error and the response is a 200, so the stream's own completion is the evidence.
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'image'  => [ responds( 404, '' ), responds( 200, '{}' ) ],
      'other'  => [ streams( cut_off(), { id => 'layer1', status => 'Downloading', progressDetail => { current => 1, total => 4 } } ) ],
      'create' => [ responds( 201, encode_json({ Id => $OWN_ID }) ) ],
      'start'  => [ responds(204) ],
   );
   seed('pulling');

   my $run = reconcile();
   ok( unresolved( $run->{'settled'}[0]{'err'} ), 'unresolved' );
   like( reason( $run->{'settled'}[0]{'err'} ), qr/pull of 'img:1' ended before its stream completed/, 'naming the cut-off stream' );
   is_recoverable( 'pulling', 'stream cut off' );
   is( scalar( grep { m{^/containers/create} } @calls ), 0, 'stream cut off: no create is posted for an image that may be absent' );

   $run = reconcile();
   ok( $run->{'settled'}[0]{'ok'}, 'the next attempt completes the chain' );
   is( status()->{'stage'}, 'done', 'reaching done' );
};

subtest 'a pull cut off three times is failed with that reason' => sub {
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'image' => [ responds( 404, '' ) ],
      'other' => [ streams( fails('Premature connection close') ) ],
   );
   seed('pulling');

   reconcile() for 1 .. 2;
   is( status()->{'unresolved'}{'attempts'}, 2, 'two attempts recorded' );
   is( status()->{'stage'}, 'pulling', 'still at pulling' );
   my $run = reconcile();
   ok( !unresolved( $run->{'settled'}[0]{'err'} ), 'the third is a definitive failure' );
   is( status()->{'stage'}, 'failed', 'recorded as failed' );
   like( status()->{'error'}, qr/^after 3 attempts: pull of 'img:1' ended without a response: Premature connection close$/,
      'with the count and the reason, and nothing that may exist, no create having been posted' );
   ok( !read_record()->{'expiryTime'}, 'and retained' );
   is( scalar( grep { m{^/images/create} } @calls ), 3, 'three pulls were issued' );
};

subtest 'an image check with no response is unresolved; one with any other status hands over to the pull' => sub {
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls, 'image' => [ fails('connection refused') ] );
   seed('pulling');
   my $run = reconcile();
   ok( unresolved( $run->{'settled'}[0]{'err'} ), 'no response to the image check is unresolved' );
   like( reason( $run->{'settled'}[0]{'err'} ), qr/image check for 'img:1' ended without a response: connection refused/, 'and says so' );
   is_recoverable( 'pulling', 'image check cut off' );
   is( scalar( grep { m{^/images/create} } @calls ), 0, 'no pull was issued' );

   @calls = ();
   local *Reservation::call_socket_api = docker( \@calls,
      'image'  => [ responds( 500, '' ) ],
      'other'  => [ streams( responds( 200, '' ) ) ],
      'create' => [ responds( 201, encode_json({ Id => $OWN_ID }) ) ],
      'start'  => [ responds(204) ],
   );
   seed('pulling');
   $run = reconcile();
   ok( $run->{'settled'}[0]{'ok'}, 'a 500 to the image check is followed by the pull, which decides' );
   is( scalar( grep { m{^/images/create} } @calls ), 1, 'one pull was issued' );
   is( status()->{'stage'}, 'done', 'and the chain completes' );
};

subtest 'a pull Docker reports as failed is definitive, whatever became of the connection' => sub {
   for my $case (
      { 'name' => 'an error event in the stream', 'pull' => streams( responds( 200, '' ), { error => 'bad layer' } ), 'reason' => qr/^bad layer$/ },
      { 'name' => 'an error event, then the connection lost', 'pull' => streams( fails('Premature connection close'), { error => 'bad layer' } ), 'reason' => qr/^bad layer$/ },
      # A refusal's body arrives through the stream reader, unterminated, as the transport delivers it.
      { 'name' => 'a refusal before the stream', 'reason' => qr/^manifest unknown$/,
        'pull' => sub ( $cb, $path, $args ) { $args->{'on_read'}->('{"message":"manifest unknown"}'); return responds( 404, '' )->($cb); } },
   ) {
      local *Reservation::call_socket_api = docker( [], 'image' => [ responds( 404, '' ) ], 'other' => [ $case->{'pull'} ] );
      seed('pulling');
      my $run = reconcile();
      ok( !unresolved( $run->{'settled'}[0]{'err'} ), "$case->{'name'}: a definitive failure" );
      is( status()->{'stage'}, 'failed', "$case->{'name'}: recorded as failed" );
      like( status()->{'error'}, $case->{'reason'}, "$case->{'name'}: with Docker's own reason" );
      ok( read_record()->{'expiryTime'}, "$case->{'name'}: with an expiry, nothing having been created" );
   }
};

my @secondCalls = second_calls();
is( scalar @secondCalls, 0, 'no continuation on any chain was called twice' )
   or diag( join( '', @secondCalls ) );

done_testing;
