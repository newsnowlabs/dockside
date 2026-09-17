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
# runs the real stage code and the real promise chain.
my $tmp = tempdir(CLEANUP => 1);
my $logPath = "$tmp/test.log";
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused' },
};
Util::flog({ file => $logPath });

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

# Runs the loop until $promise settles, recording every settlement it makes. Bounded, so a stage
# that never settles - the failure mode every test here is about - fails an assertion instead of
# hanging the suite.
sub settle ($promise) {
   my @settled;
   $promise->then( sub (@r) { push @settled, [ 'resolve', @r ] },
                   sub (@r) { push @settled, [ 'reject',  @r ] } )
           ->finally( sub (@) { Mojo::IOLoop->stop } );
   my $timeout = Mojo::IOLoop->timer( 5 => sub { Mojo::IOLoop->stop } );
   Mojo::IOLoop->start;
   Mojo::IOLoop->remove($timeout);
   return \@settled;
}

subtest 'a create response that decodes but carries no usable Id is rejected, not resolved' => sub {
   for my $body ( '{not valid json', encode_json({}), encode_json({ Id => '' }) ) {
      my @paths;
      no warnings 'redefine';
      local *Reservation::call_socket_api = sub ($socket, $path, $args, $cb) {
         push @paths, $path;
         $cb->( response( 201, $body ), undef );
      };

      my $r = reservation();
      my $settled = settle( Reservation::_create_stage_creating( $r, { Image => 'img:1' } ) );

      is( scalar @$settled, 1, "settles exactly once for body '$body'" );
      is( $settled->[0][0], 'reject', 'an unusable create response is a rejection' );
      like( $settled->[0][1], qr/malformed create response/, 'rejection names the real problem' );
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
   my $settled = settle( Reservation::_create_stage_creating( $r, { Image => 'img:1' } ) );

   is( scalar @$settled, 1, 'settles exactly once' );
   is( $settled->[0][0], 'resolve', 'a usable response resolves' );
   is( read_record()->{'containerId'}, 'a' x 12, 'the 12-char short id is persisted' );
};

subtest 'a recovery name lookup that will not decode is rejected, not left unsettled' => sub {
   my @paths;
   no warnings 'redefine';
   local *Reservation::call_socket_api = sub ($socket, $path, $args, $cb) {
      push @paths, $path;
      $cb->( response( 200, '[not valid json' ), undef );
   };

   my $r = reservation();
   my $settled = settle( Reservation::_create_stage_creating( $r, { Image => 'img:1' }, 1 ) );

   is( scalar @$settled, 1, 'settles exactly once' );
   is( $settled->[0][0], 'reject', 'an undecodable lookup is a rejection' );
   like( $settled->[0][1], qr/malformed container list/, 'rejection names the real problem' );
   is( scalar @paths, 1, 'no create is issued when ownership of the name is unknown' );
};

subtest 'recovery adoption requires both this reservation label and a usable id' => sub {
   my @cases = (
      {
         name    => 'an entry shaped unlike a container list entry',
         entry   => 'not-a-hash',
         pattern => qr/does not own/,
      },
      {
         name    => 'labels belonging to another reservation',
         entry   => { Id => 'b' x 64, Labels => { 'dev.dockside.reservation.id' => 'other' } },
         pattern => qr/does not own/,
      },
      {
         name    => 'no labels at all',
         entry   => { Id => 'b' x 64 },
         pattern => qr/does not own/,
      },
      {
         name    => 'a Labels field that is not a hash',
         entry   => { Id => 'b' x 64, Labels => 'broken' },
         pattern => qr/does not own/,
      },
      {
         name    => 'this reservation label but no id',
         entry   => { Labels => { 'dev.dockside.reservation.id' => 'rid' } },
         pattern => qr/carries this reservation's own label but no id/,
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
      my $settled = settle( Reservation::_create_stage_creating( $r, { Image => 'img:1' }, 1 ) );

      is( scalar @$settled, 1, "settles exactly once: $case->{'name'}" );
      is( $settled->[0][0], 'reject', "fails closed: $case->{'name'}" );
      like( $settled->[0][1], $case->{'pattern'}, "rejection is specific: $case->{'name'}" );
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
   my $settled = settle( Reservation::_create_stage_creating( $r, { Image => 'img:1' }, 1 ) );

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
      my $settled = settle( Reservation::_create_stage_starting( $r, 'c' x 12 ) );

      is( scalar @$settled, 1, "settles exactly once for HTTP $case->{'code'}" );
      is( $settled->[0][0], $case->{'outcome'}, "HTTP $case->{'code'} is a $case->{'outcome'}" );
   }
};

subtest 'a transport failure at any stage is a single clean rejection' => sub {
   for my $stage ( 'pulling', 'creating', 'starting' ) {
      no warnings 'redefine';
      local *Reservation::call_socket_api = sub ($socket, $path, $args, $cb) {
         $cb->( undef, 'connection refused' );
      };

      my $r = reservation();
      my $promise = $stage eq 'pulling'  ? Reservation::_create_stage_pulling( $r, 'img:1' )
                  : $stage eq 'creating' ? Reservation::_create_stage_creating( $r, { Image => 'img:1' } )
                  :                        Reservation::_create_stage_starting( $r, 'c' x 12 );
      my $settled = settle($promise);

      is( scalar @$settled, 1, "$stage settles exactly once on a transport failure" );
      is( $settled->[0][0], 'reject', "$stage rejects rather than hanging" );
      like( $settled->[0][1], qr/connection refused/, "$stage reports the transport error" );
   }
};

done_testing;
