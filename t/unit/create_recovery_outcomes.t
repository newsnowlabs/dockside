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

# Covers what a create chain does when it cannot establish whether its Docker mutation took
# effect. Exercises real database mutations, real reconciliation and the real ownership lock with
# disposable data; only the Docker transport is ever stubbed, so each test drives the same stage
# code, promise chain and persistence a live worker does. The distinction under test throughout is
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

# What these tests assert about the conflict inspection is how many lookups it makes and what it
# concludes from them, not how long it waits in between.
local $Reservation::CREATE_CONFLICT_POLL_DELAYS = [ 0, 0, 0 ];
# Retry immediately by default, so a test driving consecutive attempts does not wait out a real
# cooldown; the subtest that tests the cooldown itself restores a real one.
local $Reservation::CREATE_UNRESOLVED_RETRY_COOLDOWN_SECONDS = 0;

my $OWN_ID = 'c' x 64;

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

sub status { return read_record()->{'createStatus'} // {}; }

sub responds ( $code, $body = '' ) {
   return sub ( $cb, @ ) { $cb->( Mojo::Message::Response->new->code($code)->body($body), undef ); };
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

# Runs one reconciliation of 'rid' to settlement and reports what the caller was told. Bounded, so
# a chain that never settles fails an assertion instead of hanging the suite.
sub reconcile {
   my @settled;
   my $started = Reservation->reconcile_one( 'rid', sub ( $ok = undef, $err = undef ) {
      push @settled, { 'ok' => $ok, 'err' => $err };
      Mojo::IOLoop->stop;
   } );
   return { 'started' => $started, 'settled' => \@settled } unless $started;

   my $timeout = Mojo::IOLoop->timer( 5 => sub { Mojo::IOLoop->stop } );
   Mojo::IOLoop->start;
   Mojo::IOLoop->remove($timeout);
   return { 'started' => $started, 'settled' => \@settled };
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

      my $run = reconcile();
      ok( unresolved( $run->{'settled'}[0]{'err'} ), 'a rolled-back conflict is unresolved' );
      is_recoverable( 'creating', 'conflict with no owner' );
      is( scalar( grep { m{^/containers/create} } @calls ), 1,
         'conflict with no owner: the inspection only looks, it never re-POSTs' );
      is( scalar( grep { m{^/containers/json} } @calls ), 4,
         'conflict with no owner: one lookup before the create, then the bounded inspection' );
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
      $reservation->_create_run_from_creating( { Image => 'img:1' }, 0 ),
      sub ( $ok = undef, $err = undef ) {
         push @settled, { 'ok' => $ok, 'err' => $err };
         Mojo::IOLoop->stop;
      } );
   my $timeout = Mojo::IOLoop->timer( 5 => sub { Mojo::IOLoop->stop } );
   Mojo::IOLoop->start;
   Mojo::IOLoop->remove($timeout);

   is( scalar @settled, 1, 'settles exactly once' );
   is( unresolved( $settled[0]{'err'} ), 0, 'a first attempt is failed without any ownership check' );
   is( status()->{'stage'}, 'failed', 'recorded as failed' );
   ok( read_record()->{'expiryTime'}, 'and expired' );
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

subtest 'consecutive unresolved attempts accumulate across reloads' => sub {
   my @calls;
   local *Reservation::call_socket_api = docker( \@calls,
      'lookup' => [ holds(undef) ],
      'create' => [ fails('connection reset by peer') ],
   );
   seed('creating');

   reconcile();
   my $first = status()->{'unresolved'};
   reconcile();
   my $second = status()->{'unresolved'};
   reconcile();
   my $third = status()->{'unresolved'};

   is( $third->{'attempts'}, 3, 'the attempt count survives each attempt reloading the record' );
   is( $third->{'since'}, $first->{'since'}, 'and the time it was first unresolved is kept' );
   isnt( $second->{'retryAfter'}, undef, 'each attempt names when the next may run' );
   is( status()->{'stage'}, 'creating', 'the stage is unchanged throughout' );
};

subtest 'a reservation within its retry cooldown is skipped without contacting Docker' => sub {
   local $Reservation::CREATE_UNRESOLVED_RETRY_COOLDOWN_SECONDS = 600;
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
   $reservation->_create_track(
      $reservation->_create_run_from_creating( { Image => 'img:1' }, 1 ),
      sub (@) {
         $entered++;
         Mojo::IOLoop->stop;
         die "fixture consumer failure\n";
      } );

   my $timeout = Mojo::IOLoop->timer( 5 => sub { Mojo::IOLoop->stop } );
   Mojo::IOLoop->start;
   Mojo::IOLoop->remove($timeout);

   is( $entered, 1, 'the consumer is entered exactly once' );
   is( status()->{'stage'}, 'done', 'and its own exception does not turn a success into a failure' );
   ok( !read_record()->{'expiryTime'}, 'nor expire a reservation whose container is running' );
   is( Reservation->create_in_flight_count(), 0, 'the chain is still released from the in-flight set' );
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

done_testing;
