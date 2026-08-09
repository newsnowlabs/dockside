package App::Metadata;

use v5.36;

use Try::Tiny;
use JSON;
use Util qw(flog);

# $c-native (Mojolicious::Controller) - this module is unpublished/alpha (never
# documented, never officially shipped, not used by any production Dockside
# deployment - see docs/plans/mojolicious-app-server-split-plan.md), so unlike
# every other App.pm surface ported this session, there's no external contract
# obliging a verbatim-behind-the-adapter port here. Registered directly as its
# own native route (bin/app-server) rather than reused through
# App::NginxAdapter - the smallest available slice of "stop routing responses
# through the adapter", not a pattern for the routes still doing that.

sub success ($c, $body = '') {
   $c->res->headers->header( 'Cache-Control',   'no-store' );
   $c->res->headers->header( 'Metadata-Flavor', 'Google' );
   $c->res->headers->header( 'Server',          'Metadata Server for VM' );
   $c->res->headers->content_type('application/text');
   $c->res->body($body);
   return $c->rendered(200);
}

sub failure ($c, $code = 404) {
   $c->res->headers->header( 'Cache-Control',   'no-store' );
   $c->res->headers->header( 'Metadata-Flavor', 'Google' );
   $c->res->headers->header( 'X-IP',            _remote_addr($c) );
   $c->res->headers->header( 'Server',          'Metadata Server for VM' );
   $c->res->headers->content_type('application/text');
   return $c->rendered( $code || 404 );
}

# EC2:
# /latest/user-data
# /latest/meta-data/local-ipv4
# /latest/meta-data/instance-id
# /latest/meta-data/ami-id
# /latest/meta-data/public-keys/0/openssh-key

# Google Compute Cloud:
# /computeMetadata/v1/instance/attributes/startup-script
# /computeMetadata/v1/project/attributes/startup-script
# /computeMetadata/v1/project/attributes/ssh-keys
# /computeMetadata/v1/instance/image
# /computeMetadata/v1/instance/hostname
# /computeMetadata/v1/instance/id
# /computeMetadata/v1/instance/network-interfaces/0/ip

# nginx appends its own hop (proxy_add_x_forwarded_for) on its way to app-server;
# strip exactly that one back off to recover what the client itself sent - same
# logic as App::NginxAdapter::header_in's X-Forwarded-For case, kept as an
# independent local copy since this module deliberately no longer goes through
# the adapter at all.
sub _forwarded_for ($c) {
   my $xff = $c->req->headers->header('X-Forwarded-For');
   return undef unless defined $xff && length $xff;
   my @hops = split( /\s*,\s*/, $xff );
   pop @hops;
   my $rest = join( ', ', @hops );
   return length($rest) ? $rest : undef;
}

# nginx sets X-Real-IP to $remote_addr on its own hop (sites-available/default) -
# the true client address; $c->tx->remote_address alone would be nginx's own
# loopback address once proxied.
sub _remote_addr ($c) {
   return $c->req->headers->header('X-Real-IP') // $c->tx->remote_address;
}

sub handle ($c) {
   # FIXME:
   # Consider additionally requiring:
   # - Host header doesn't match an expected profile e.g. matches an IP address; or
   # - User agent matches an expected profile
   #
   # See: https://cloud.google.com/compute/docs/storing-retrieving-metadata

   # e.g.
   # curl -H 'Metadata-Flavor: Google' http://172.17.0.5/computeMetadata/v1/instance/hostname
   # curl -H 'Metadata-Flavor: Google' http://172.17.0.5/computeMetadata/v1/instance/fqdn
   # curl -H 'Metadata-Flavor: Google' http://172.17.0.5/computeMetadata/v1/instance/attributes/startup-script

   # Route registration (bin/app-server) already guarantees the /computeMetadata/v1/
   # prefix; what's left to check here is the client-signature part Mojolicious
   # routing itself can't express - genuine devtainer-originated (no forwarded-for
   # hop beyond nginx's own) and carrying the real metadata-client header.
   if ( _forwarded_for($c) || ( $c->req->headers->header('Metadata-Flavor') // '' ) ne 'Google' ) {
      return failure( $c, 404 );
   }

   my $path = $c->req->url->path->to_string;
   $path =~ s!^/computeMetadata/v1/!!;

   try {
      my $reservations = Reservation->load( {
         'ip' => _remote_addr($c)
      } );

      if ( my $reservation = $reservations->[0] ) {

         my $response;

         # Return an internal FQDN
         if ( $path =~ m!(instance|project)/hostname$! ) {
            $response = $reservation->name;
         }
         elsif ( $path =~ m!(instance|project)/fqdn$! ) {
            $response = $reservation->data('FQDN');
         }
         elsif ( $path =~ m!(instance)/attributes/root-password$! ) {
            $response = 'z1x2c3v4';
         }
         # Return userdata
         elsif ( $path =~ m!(instance|project)/attributes/startup-script$! ) {
            $response = $reservation->profileObject->{'metadata'}{'attributes'}{'startup-script'};
            $response = ref($response) eq 'ARRAY' ? join( '', map { "$_\n" } @$response ) : $response;
            $response = $reservation->_placeholders($response);
         }

         if ($response) {
            return success( $c, $response );
         }
      }

      # Return an HTTP status that can cause 'curl --retry' to retry.
      return failure( $c, 502 );
   }
   catch {
      my ( $msg, $dbg ) = ref($_) ? ( $_->msg(), $_->dbg() ) : ( $_, $_ );
      flog("Caught exception: dbg='$dbg'; msg='$msg'");
      return failure($c);
   };
}

1;
