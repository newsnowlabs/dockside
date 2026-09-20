use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use Exception;
use File::Temp qw(tempdir);
use Mojo::Message::Response;
use Test::More;

# Reservation::action turns stop/start/remove into one Docker Engine API request each. Only the
# transport is stubbed, to capture the request it is asked to make and to answer it.
my $tmp = tempdir( CLEANUP => 1 );
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused' },
};
Util::flog( { file => "$tmp/test.log" } );

my $CID = 'c' x 12;

# Runs one action against a stubbed Docker that answers $opt{'code'}, and returns the request
# made and what the caller was told.
sub act ( $action, $args = {}, %opt ) {
   my $r = bless { id => 'rid', name => 'devt', containerId => $CID }, 'Reservation';
   my ( $request, @answered );

   no warnings qw(redefine once);
   local *Reservation::call_socket_api = sub ( $socket, $path, $opts, $cb ) {
      $request = { 'path' => $path, 'method' => $opts->{'method'} };
      $cb->( Mojo::Message::Response->new->code( $opt{'code'} // 204 ), undef );
   };

   $r->action( $action, $args, sub (@a) { push @answered, [@a] } );
   return ( $request, \@answered );
}

subtest 'a stop with no timeout of its own sends none' => sub {
   my ( $request, $answered ) = act('stop');
   is( $request->{'method'}, 'POST', 'as a POST' );
   is( $request->{'path'}, "/containers/$CID/stop", 'with no query, so Docker applies the container own stop timeout' );
   is( scalar @$answered, 1, 'the caller is answered once' );
   ok( !defined $answered->[0][1], 'with success' );
};

subtest 'a stop given a timeout sends it' => sub {
   my ( $request ) = act( 'stop', { 't' => 5 } );
   is( $request->{'path'}, "/containers/$CID/stop?t=5", 'as the t query Docker reads' );
};

subtest 'start and remove address their own endpoints' => sub {
   my ( $start ) = act('start');
   is( $start->{'method'}, 'POST', 'start is a POST' );
   is( $start->{'path'}, "/containers/$CID/start", 'to the start endpoint' );

   my ( $remove ) = act('remove');
   is( $remove->{'method'}, 'DELETE', 'remove is a DELETE' );
   is( $remove->{'path'}, "/containers/$CID?v=true", 'of the container and its anonymous volumes' );
};

done_testing;
