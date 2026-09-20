use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use JSON;
use Test::More;

# 'stopping' is derived for the client from two recorded times and the container's state, and
# is never stored. Every combination of the three inputs is pinned here, and that the derived
# value reaches both client views as a boolean.

sub reservation (%f) {
   return bless {
      id => 'rid', name => 'devt', status => $f{'status'} // 1,
      data   => { ( exists $f{'requested'} ? ( stopRequestedAt => $f{'requested'} ) : () ) },
      docker => { ( exists $f{'started'}   ? ( StartedAt       => $f{'started'} )   : () ) },
   }, 'Reservation';
}

subtest 'stopping only while running, with a stop requested since the last start' => sub {
   ok( reservation( requested => 100.5, started => 100.25 )->is_stopping, 'running, requested after the start: stopping' );
   ok( !reservation( requested => 100.25, started => 100.5 )->is_stopping, 'requested before the start: a later start superseded it' );
   ok( !reservation( requested => 0, started => 100.5 )->is_stopping, 'a request written as 0, one whose Docker call ended without success: not stopping' );
   ok( !reservation( requested => 100.5, started => 100.5 )->is_stopping, 'requested at the same instant as the start: not stopping' );
   ok( !reservation( requested => 100.5, started => 100.25, status => 0 )->is_stopping, 'exited: not stopping, the stop is complete' );
   ok( !reservation( requested => 100.5, started => 100.25, status => -1 )->is_stopping, 'created and never started: not stopping' );
   ok( !reservation( requested => 100.5 )->is_stopping, 'no start on record: not stopping' );
   ok( !reservation( started => 100.25 )->is_stopping, 'no stop requested: not stopping' );
   ok( !reservation()->is_stopping, 'neither recorded: not stopping' );
};

subtest 'the client view carries the flag as a boolean, for developers and viewers alike' => sub {
   my $stopping = reservation( requested => 100.5, started => 100.25 );
   my $idle     = reservation();

   for my $auth ( [ 'developer', { developer => 1 } ], [ 'viewer', {} ] ) {
      my ( $label, $perms ) = @$auth;
      my $view = $stopping->cloneWithConstraints( {}, { auth => $perms } );
      ok( JSON::is_bool( $view->{'stopping'} ) && $view->{'stopping'}, "$label view: stopping is true" );
      ok( !exists $view->{'docker'}{'StartedAt'}, "$label view: the start time itself is not sent" );
      ok( !exists $view->{'data'}{'stopRequestedAt'} && !exists $view->{'data'}{'stopRequestId'}, "$label view: nor the request's own record" );

      $view = $idle->cloneWithConstraints( {}, { auth => $perms } );
      ok( JSON::is_bool( $view->{'stopping'} ) && !$view->{'stopping'}, "$label view: stopping is false" );
   }
};

done_testing;
