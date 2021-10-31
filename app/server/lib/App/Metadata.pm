package App::Metadata;

use strict;

BEGIN {
   eval {
      require nginx;
      nginx->import();
   };
}

use Try::Tiny;
use JSON;
use Util qw(flog);

sub success {
   my $r = shift;

   $r->status(200);
   $r->header_out( 'Cache-Control', 'no-store' );
   $r->header_out( 'Metadata-Flavor', 'Google' );
   $r->header_out( 'Server', 'Metadata Server for VM' );
   $r->header_out( 'Content-Length', length($_[0]) );
   $r->send_http_header("application/text");
   $r->print($_[0]);
   return nginx::OK;
}

sub failure {
   my $r = shift;
   my $code = shift;

   $r->status($code || 404);
   $r->header_out( 'Cache-Control', 'no-store' );
   $r->header_out( 'Metadata-Flavor', 'Google' );
   $r->header_out( 'X-IP', $r->remote_addr);
   $r->header_out( 'Server', 'Metadata Server for VM' );
   $r->send_http_header("application/text");
   return nginx::OK;
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

sub handle {
   my $r = shift;

   # FIXME: 
   # Although Proxy will have checked, consider double-checking that:
   # - Host header doesn't match an expected profile e.g. matches an IP address; or
   # - User agent matches an expected profile
   # - or to require a custom header e.g. Metadata-Flavor: Google
   #
   # See: https://cloud.google.com/compute/docs/storing-retrieving-metadata

   # e.g.
   # curl -H 'Metadata-Flavor: Google' http://172.17.0.5/computeMetadata/v1/instance/hostname
   # curl -H 'Metadata-Flavor: Google' http://172.17.0.5/computeMetadata/v1/instance/fqdn
   # curl -H 'Metadata-Flavor: Google' http://172.17.0.5/computeMetadata/v1/instance/attributes/startup-script

   if($r->header_in("X-Forwarded-For") || $r->header_in('Metadata-Flavor') ne 'Google' || $r->uri !~ m!^/computeMetadata/v1/(.*)$!) {
      return nginx::DECLINED;
   }

   my $path = $1;

   try {

      my $reservations = Reservation->load( {
         'ip' => $r->remote_addr
      } );

      if(my $reservation = $reservations->[0]) {

         my $response;

         # Return an internal FQDN
         if($path =~ m!(instance|project)/hostname$!) {
            $response = $reservation->name;
         }
         elsif($path =~ m!(instance|project)/fqdn$!) {
            $response = $reservation->data('FQDN');
         }
         elsif($path =~ m!(instance)/attributes/root-password$!) {
            $response = 'z1x2c3v4';
         }
         # Return userdata
         elsif($path =~ m!(instance|project)/attributes/startup-script$!) {
            $response = $reservation->profileObject->{'metadata'}{'attributes'}{'startup-script'};
            $response = ref($response) eq 'ARRAY' ? join('', map { "$_\n" } @$response) : $response;
            $response = $reservation->_placeholders($response);
         }         

         if($response) {
            return success($r, $response);
         }
      }

      # Return an HTTP status that can cause 'curl --retry' to retry.
      return failure($r, 502);
   }
   catch {
      my ($msg, $dbg) = ref($_) ? ($_->msg(), $_->dbg()) : ($_,$_);
      flog("Caught exception: dbg='$dbg'; msg='$msg'");
      failure($r);
   }
}

1;
