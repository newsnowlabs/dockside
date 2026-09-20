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

# Exercise real database mutations and flock with disposable data; no Docker required. Only the
# transport (Util::call_socket_api, as imported into Reservation) is ever stubbed, so each test
# runs the real stage code and the real continuations, each stage sub driven directly with a
# continuation of the test's own.
my $tmp = tempdir(CLEANUP => 1);
my $logPath = "$tmp/test.log";
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused' },
};
Util::flog({ file => $logPath });

sub read_log {
   open my $fh, '<', $logPath or return '';
   local $/;
   return <$fh> // '';
}

sub write_record ($record) {
   open my $fh, '>', $Data::CONFIG->{reservationsPath} or die $!;
   print $fh encode_json($record), "\n";
   close $fh;
}

sub read_record {
   open my $fh, '<', $Data::CONFIG->{reservationsPath} or die $!;
   local $/;
   my $text = <$fh>;
   return length($text) ? decode_json($text) : undef;
}

sub reservation {
   write_record({ id => 'rid', name => 'devt', data => { image => 'img:1' } });
   return bless { id => 'rid', name => 'devt', data => { image => 'img:1' } }, 'Reservation';
}

sub response ($code, $body) {
   return Mojo::Message::Response->new->code($code)->body($body);
}

# Runs $start with a continuation that records every call it receives, as [ 'resolve', $value ]
# or [ 'reject', $err ], then runs the loop until the first, so a stage whose transport answers
# on a later tick still settles here. Bounded, so a stage that never settles - the failure mode
# every test here is about - fails an assertion instead of hanging the suite.
sub settle ($start) {
   my @settled;
   $start->( sub ( $value, $err ) {
      push @settled, defined($err) ? [ 'reject', $err ] : [ 'resolve', $value ];
      Mojo::IOLoop->stop;
   } );
   return \@settled if @settled;
   my $timeout = Mojo::IOLoop->timer( 5 => sub { Mojo::IOLoop->stop } );
   Mojo::IOLoop->start;
   Mojo::IOLoop->remove($timeout);
   return \@settled;
}

# Runs $code with stderr captured, since a continuation's second call is reported there as well
# as in the log. Returns $code's results followed by the captured text.
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

# A stage reports a plain string when it has established that the mutation did not happen, and
# an Exception carrying 'unresolved' when it could not establish that - so a test reading the
# reason has to handle both, and asserting which one it got is the point of several below.
sub reason ($err) {
   return ref($err) eq 'Exception' ? $err->msg : "$err";
}

sub unresolved ($err) {
   return ( ref($err) eq 'Exception' && $err->unresolved ) ? 1 : 0;
}

subtest 'a create response that decodes but carries no usable Id is unresolved, not resolved' => sub {
   for my $body ( '{not valid json', encode_json({}), encode_json({ Id => '' }) ) {
      my @paths;
      no warnings 'redefine';
      local *Reservation::call_socket_api = sub ($socket, $path, $args, $cb) {
         push @paths, $path;
         $cb->( response( 201, $body ), undef );
      };

      my $r = reservation();
      my $settled = settle( sub ($cb) { Reservation::_create_stage_creating( $r, { Image => 'img:1' }, 0, $cb ) } );

      is( scalar @$settled, 1, "settles exactly once for body '$body'" );
      is( $settled->[0][0], 'reject', 'an unusable create response is a rejection' );
      like( reason( $settled->[0][1] ), qr/no usable id/, 'rejection names the real problem' );
      # Docker accepted the create: a body this side could not read is not evidence that no
      # container exists, so this must stay recoverable rather than expiring the reservation.
      ok( unresolved( $settled->[0][1] ), 'and reports the outcome as unresolved' );
      is( scalar @paths, 1, 'nothing is issued after the unusable response' );
      ok( !defined( read_record()->{'containerId'} ), 'no containerId is persisted' );
   }
};

subtest 'a usable create response resolves and persists the short container id' => sub {
   no warnings 'redefine';
   local *Reservation::call_socket_api = sub ($socket, $path, $args, $cb) {
      $cb->( response( 201, encode_json({ Id => 'a' x 64 }) ), undef );
   };

   my $r = reservation();
   my $settled = settle( sub ($cb) { Reservation::_create_stage_creating( $r, { Image => 'img:1' }, 0, $cb ) } );

   is( scalar @$settled, 1, 'settles exactly once' );
   is( $settled->[0][0], 'resolve', 'a usable response resolves' );
   is( read_record()->{'containerId'}, 'a' x 12, 'the 12-char short id is persisted' );
};

subtest 'a transport that completes a stage twice leaves one settlement and a logged second call' => sub {
   no warnings 'redefine';
   local *Reservation::call_socket_api = sub ($socket, $path, $args, $cb) {
      $cb->( response( 201, encode_json({ Id => 'd' x 64 }) ), undef ) for 1 .. 2;
   };

   my $r = reservation();
   my ( $settled, $warnings ) = captured( sub {
      settle( sub ($cb) { Reservation::_create_stage_creating( $r, { Image => 'img:1' }, 0, $cb ) } );
   } );

   is( scalar @$settled, 1, 'the stage settles exactly once' );
   is( $settled->[0][0], 'resolve', 'with the first completion' );
   is( read_record()->{'containerId'}, 'd' x 12, 'and one recorded outcome' );
   like( read_log(), qr/_create_stage_creating for reservation 'rid': continuation called again; ignored/,
      'the second completion is logged as a bug, naming the stage' );
   like( $warnings, qr/continuation called again; ignored/, 'on stderr too' );
};

subtest 'a recovery name lookup that will not decode is rejected, not left unsettled' => sub {
   my @paths;
   no warnings 'redefine';
   local *Reservation::call_socket_api = sub ($socket, $path, $args, $cb) {
      push @paths, $path;
      $cb->( response( 200, '[not valid json' ), undef );
   };

   my $r = reservation();
   my $settled = settle( sub ($cb) { Reservation::_create_stage_creating( $r, { Image => 'img:1' }, 1, $cb ) } );

   is( scalar @$settled, 1, 'settles exactly once' );
   is( $settled->[0][0], 'reject', 'an undecodable lookup is a rejection' );
   like( reason( $settled->[0][1] ), qr/malformed container list/, 'rejection names the real problem' );
   ok( unresolved( $settled->[0][1] ), 'an unreadable lookup establishes nothing, so it is unresolved' );
   is( scalar @paths, 1, 'no create is issued when ownership of the name is unknown' );
};

subtest 'recovery adopts only on this reservation own label and a usable id' => sub {
   # A valid record that names another owner - or no owner - is evidence of a genuine collision,
   # so it fails definitively. A record this side cannot read is evidence of nothing, so it stays
   # unresolved: expiring a reservation on the strength of unreadable data would delete a record
   # whose container may be its own.
   my @cases = (
      {
         name       => 'an entry shaped unlike a container list entry',
         entry      => 'not-a-hash',
         pattern    => qr/is not a record/,
         unresolved => 1,
      },
      {
         name       => 'labels belonging to another reservation',
         entry      => { Id => 'b' x 64, Labels => { 'dev.dockside.reservation.id' => 'other' } },
         pattern    => qr/does not own/,
         unresolved => 0,
      },
      {
         name       => 'no labels at all',
         entry      => { Id => 'b' x 64 },
         pattern    => qr/does not own/,
         unresolved => 0,
      },
      {
         name       => 'a Labels field that is not a hash',
         entry      => { Id => 'b' x 64, Labels => 'broken' },
         pattern    => qr/labels are not a set/,
         unresolved => 1,
      },
      {
         name       => 'this reservation label but no id',
         entry      => { Labels => { 'dev.dockside.reservation.id' => 'rid' } },
         pattern    => qr/no usable id/,
         unresolved => 1,
      },
   );

   for my $case (@cases) {
      my @paths;
      no warnings 'redefine';
      local *Reservation::call_socket_api = sub ($socket, $path, $args, $cb) {
         push @paths, $path;
         $cb->( response( 200, encode_json( [ $case->{'entry'} ] ) ), undef );
      };

      my $r = reservation();
      my $settled = settle( sub ($cb) { Reservation::_create_stage_creating( $r, { Image => 'img:1' }, 1, $cb ) } );

      is( scalar @$settled, 1, "settles exactly once: $case->{'name'}" );
      is( $settled->[0][0], 'reject', "does not adopt: $case->{'name'}" );
      like( reason( $settled->[0][1] ), $case->{'pattern'}, "rejection is specific: $case->{'name'}" );
      is( unresolved( $settled->[0][1] ), $case->{'unresolved'},
         "classified on the evidence available: $case->{'name'}" );
      is( scalar @paths, 1, "no create is attempted against a taken name: $case->{'name'}" );
   }
};

subtest 'recovery adopts a container carrying this reservation own label' => sub {
   my @paths;
   no warnings 'redefine';
   local *Reservation::call_socket_api = sub ($socket, $path, $args, $cb) {
      push @paths, $path;
      $cb->( response( 200, encode_json(
         [ { Id => 'c' x 64, Labels => { 'dev.dockside.reservation.id' => 'rid' } } ] ) ), undef );
   };

   my $r = reservation();
   my $settled = settle( sub ($cb) { Reservation::_create_stage_creating( $r, { Image => 'img:1' }, 1, $cb ) } );

   is( scalar @$settled, 1, 'settles exactly once' );
   is( $settled->[0][0], 'resolve', 'the reservation own container is adopted' );
   is( scalar @paths, 1, 'adoption issues no create' );
   is( read_record()->{'containerId'}, 'c' x 12, 'the adopted short id is persisted' );
};

subtest 'the start stage settles once, accepting an already-started container' => sub {
   for my $case ( { code => 204, outcome => 'resolve' }, { code => 304, outcome => 'resolve' },
                  { code => 404, outcome => 'reject' } ) {
      no warnings 'redefine';
      local *Reservation::call_socket_api = sub ($socket, $path, $args, $cb) {
         $cb->( response( $case->{'code'}, 'no such container' ), undef );
      };

      my $r = reservation();
      my $settled = settle( sub ($cb) { Reservation::_create_stage_starting( $r, 'c' x 12, $cb ) } );

      is( scalar @$settled, 1, "settles exactly once for HTTP $case->{'code'}" );
      is( $settled->[0][0], $case->{'outcome'}, "HTTP $case->{'code'} is a $case->{'outcome'}" );
   }
};

subtest 'a failed progress write cannot hide a pull error later in the same chunk' => sub {
   my @paths;
   no warnings 'redefine';
   # Docker reports per-layer progress and a mid-stream failure for the same pull in one chunk.
   # The progress line is what triggers the debounced write; the error line after it is the one
   # that decides the pull's outcome, so the write failing must not stop it being read.
   local *Reservation::update = sub (@) { die Exception->new( 'dbg' => 'fixture progress write failure' ) };
   local *Reservation::call_socket_api = sub ($socket, $path, $args, $cb) {
      push @paths, $path;
      return $cb->( response( 404, '' ), undef ) if $path =~ m{/json$};   # image not present yet
      $args->{'on_read'}->(
           encode_json({ id => 'layer1', status => 'Downloading',
                         progressDetail => { current => 1, total => 2 } } ) . "\n"
         . encode_json({ error => 'manifest unknown' }) . "\n" );
      $cb->( response( 200, '' ), undef );
   };

   my $r = reservation();
   my $settled = settle( sub ($cb) { Reservation::_create_stage_pulling( $r, 'img:1', $cb ) } );

   is( scalar @$settled, 1, 'settles exactly once' );
   is( $settled->[0][0], 'reject', 'a pull Docker reported as failed is not a success' );
   like( $settled->[0][1], qr/manifest unknown/,
      'and it fails with the error Docker reported, not the progress write failure' );
};

subtest 'a transport failure at any stage is a single clean rejection' => sub {
   for my $stage ( 'pulling', 'creating', 'starting' ) {
      no warnings 'redefine';
      local *Reservation::call_socket_api = sub ($socket, $path, $args, $cb) {
         $cb->( undef, 'connection refused' );
      };

      my $r = reservation();
      my $start = $stage eq 'pulling'  ? sub ($cb) { Reservation::_create_stage_pulling( $r, 'img:1', $cb ) }
                : $stage eq 'creating' ? sub ($cb) { Reservation::_create_stage_creating( $r, { Image => 'img:1' }, 0, $cb ) }
                :                        sub ($cb) { Reservation::_create_stage_starting( $r, 'c' x 12, $cb ) };
      my $settled = settle($start);

      is( scalar @$settled, 1, "$stage settles exactly once on a transport failure" );
      is( $settled->[0][0], 'reject', "$stage rejects rather than hanging" );
      like( reason( $settled->[0][1] ), qr/connection refused/, "$stage reports the transport error" );
      # A pull that never completed created nothing, so it is a definitive failure. A create or
      # start whose transport died may well have been carried out by Docker regardless.
      is( unresolved( $settled->[0][1] ), ( $stage eq 'pulling' ? 0 : 1 ),
         "$stage classifies the transport failure by whether it could have mutated anything" );
   }
};

done_testing;
