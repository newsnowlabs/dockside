use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use User;
use Reservation;
use Exception;
use File::Temp qw(tempdir);
use Test::More;

# User::createContainerReservation registers the request in %CREATE_REQUEST_IN_FLIGHT before
# the devcontainer.json fetch and releases it at the entry of the callback the fetch resumes,
# so a draining worker waits for a request whose fetch is outstanding and finds nothing to wait
# for once the chain has been handed the reservation. Everything the method does around the
# fetch is stubbed to the answer it needs: only the registration is under test, driven through
# the real method with a fetch that completes when the test says.
my $tmp = tempdir( CLEANUP => 1 );
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused' }, ide => 'ide',
};
Util::flog( { file => "$tmp/test.log" } );

no warnings qw(redefine once);
local *User::has_permission = sub (@) { return 1; };
local *User::details        = sub (@) { return { 'username' => 'u' }; };
local *User::username       = sub (@) { return 'u'; };
local *User::set = sub ( $self, $reservation, $property, $value = '' ) {
   return 0 if $property eq 'private' && ( $value // '' ) eq 'refused';
   $reservation->{'data'}{'gitURL'} = $value if $property eq 'gitURL';
   return 1;
};
local *User::createClientReservation = sub ( $self, $reservation = undef ) { return $reservation; };
local *Reservation::cmdline_json     = sub (@) { return '{}'; };
local *Reservation::store            = sub ($self) { return $self; };

my @fetches;
my @created;
local *Reservation::get_uri = sub ( $uri, $cb ) { push @fetches, $cb; return; };
local *Reservation::create  = sub ( $self, $cb ) { push @created, $self->id(); $cb->( $self, undef ); return; };

my $user = bless {}, 'User';

sub registered () { return [ User->create_request_in_flight_ids() ]; }

subtest 'a request whose fetch is outstanding is registered until the fetch resumes it' => sub {
   @fetches = @created = ();
   my @answered;
   $user->createContainerReservation( { 'name' => 'devtainer', 'gitURL' => 'https://github.com/o/r.git' },
      sub ( $reservation, $err ) { push @answered, [ $reservation, $err ]; } );

   is( scalar @fetches, 1, 'the fetch is outstanding' );
   is( scalar @{ registered() }, 1, 'and the request is registered' );
   my $id = registered()->[0];
   is_deeply( \@created, [], 'no chain has begun' );

   $fetches[0]->(undef);
   is( scalar @fetches, 2, 'the first branch failing, the fetch of the second is outstanding' );
   is_deeply( registered(), [$id], 'and the request stays registered' );

   $fetches[1]->(undef);
   is_deeply( registered(), [], 'the request is released once the fetch has resumed it' );
   is_deeply( \@created, [$id], 'and the chain has begun' );
   is( scalar @answered, 1, 'the caller is answered' );
   is( $answered[0][0] && $answered[0][0]->id(), $id, 'with the reservation' );
};

subtest 'a request with nothing to fetch is registered and released within the call' => sub {
   @fetches = @created = ();
   $user->createContainerReservation( { 'name' => 'devtainer' }, sub (@) { } );

   is( scalar @fetches, 0, 'nothing is fetched' );
   is_deeply( registered(), [], 'nothing stays registered' );
   is( scalar @created, 1, 'and the chain has begun' );
};

subtest 'a request refused before the fetch registers nothing' => sub {
   @fetches = @created = ();
   my $refused = eval { $user->createContainerReservation( { 'name' => 'devtainer', 'private' => 'refused' }, sub (@) { } ); 1 } ? 0 : 1;

   ok( $refused, 'the refusal reaches the caller' );
   is_deeply( registered(), [], 'and nothing is registered' );
   is( scalar @fetches, 0, 'nothing was fetched' );
};

# get_uri settles a fetch that cannot be built or started at once, with no result, from inside
# the call; the two cases below hand the method that shape.
subtest 'a request whose first fetch settles at once with no result is resumed without a devcontainer and released' => sub {
   @fetches = @created = ();
   my $starts = 0;
   local *Reservation::get_uri = sub ( $uri, $cb ) { $starts++; $cb->(undef); return; };
   my @answered;
   $user->createContainerReservation( { 'name' => 'devtainer', 'gitURL' => 'https://github.com/o/r.git' },
      sub ( $reservation, $err ) { push @answered, [ $reservation, $err ]; } );

   is( $starts, 2, 'each branch is tried' );
   is_deeply( registered(), [], 'nothing stays registered' );
   is( scalar @created, 1, 'the chain begins, with no devcontainer to apply' );
   is( scalar @answered, 1, 'and the caller is answered' );
   ok( !$answered[0][1], 'with the reservation, not a failure' );
};

subtest 'a request whose fallback fetch settles at once with no result, after the first resolved, is resumed and released' => sub {
   @fetches = @created = ();
   local *Reservation::get_uri = sub ( $uri, $cb ) {
      return $cb->(undef) if $uri =~ m{/master/};
      push @fetches, $cb;
      return;
   };
   my @answered;
   $user->createContainerReservation( { 'name' => 'devtainer', 'gitURL' => 'https://github.com/o/r.git' },
      sub ( $reservation, $err ) { push @answered, [ $reservation, $err ]; } );
   is( scalar @{ registered() }, 1, 'the request is registered while the first fetch is outstanding' );

   $fetches[0]->(undef);

   is_deeply( registered(), [], 'the fallback settling at once, nothing stays registered' );
   is( scalar @created, 1, 'and the chain begins' );
   is( scalar @answered, 1, 'and the caller is answered' );
};

subtest 'a request whose resumption throws is released and the caller answered with the failure' => sub {
   @fetches = @created = ();
   local *Reservation::store = sub ($self) { die Exception->new( 'msg' => 'fixture store failure' ); };
   my @answered;
   $user->createContainerReservation( { 'name' => 'devtainer', 'gitURL' => 'https://github.com/o/r.git' },
      sub ( $reservation, $err ) { push @answered, [ $reservation, $err ]; } );
   is( scalar @{ registered() }, 1, 'the request is registered while the fetch is outstanding' );

   $fetches[0]->( Mojo::Message::Response->new->code(200)->body('{"image":"img:1"}') );

   is_deeply( registered(), [], 'the request is released' );
   is( scalar @answered, 1, 'the caller is answered' );
   ok( $answered[0][1], 'with the failure' );
   is_deeply( \@created, [], 'and no chain began' );
};

done_testing;
