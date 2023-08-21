package Proxy;

BEGIN {
   eval {
      require nginx;
      nginx->import();
   };
}

use strict;

use Try::Tiny;
use Reservation;
use Util qw(wlog);
use Data qw($CONFIG $HOSTNAME);
use Request;

# Given a domain, extract the unique code identifying the host publicly.
sub domain_to_host {
   my $r = $_[0];

   my $host = $r->header_in("Host");

   wlog("domain_to_host: host=$host");

   # Identify the container to which to proxy.
   # In order to support nested dockside containers,
   # we parse the hostname, splitting on '--'-delimited container names,
   # and splitting the leftmost element again on its first '-'.
   #
   # The required container name will be N from the right, where N
   # is the number of '-'-delimited strings in the X-Nest-Level header.

   # e.g. Example inputs and outputs, for each nest level:
   #
   # www.mydockside.co.uk ->
   # - 0: 'www', '', 'mydockside.co.uk', 0 (as seen by the outermost Dockside container)
   #
   # www-inner.mydockside.co.uk ->
   # - 0: 'inner', 'www', 'mydockside.co.uk', 0 (as seen by the outermost Dockside container)
   # - 1: 'www', '', 'mydockside.co.uk', 1 (as seen by an inner Dockside devtainer)

   # www-my-devtainer--inner.mydockside.co.uk ->
   # - 0: 'inner', 'www-my-devtainer', 'mydockside.co.uk', 0 (as seen by the outermost Dockside container)
   # - 1: 'my-devtainer', 'www', 'mydockside.co.uk', 1 (as seen by an inner Dockside devtainer; will proxy on to 'my-devtainer')

   if( $host =~ /^([^\.]+)\.(.*?)(:\d+)?$/ ) {
      my @elements = reverse split(/--/, $1);
      my $domain = $2;

      # Split again the leftmost element on its first '-'.
      # Add the devtainer name (if found) to @elements.
      # Always add the service name to @elements.
      my ($service, $topHost) = pop(@elements) =~ /^([^-]+)(?:-(.*))?$/;
      push(@elements, $topHost ? $topHost : (), $service);

      my $nestCount = split(/-/, $r->header_in('X-Nest-Level'));

      return undef unless $nestCount < @elements;

      my $element = $elements[$nestCount];
      my $prefix = join('--', reverse @elements[($nestCount+1)..(@elements-1)]);

      wlog("domain_to_host: Host header='$host'; nestCount=$nestCount; container host='$element'; prefix='$prefix'; domain='$domain'");

      return ($element, $prefix, $domain, $nestCount);
   }

   return undef;
}

sub get_server_port {
   my $r = shift;
   my $protocol = shift;

   # Reload config, containers and reservations as needed.
   Data::load();

   # FIXME:
   # Save looking up reservation if:
   # - Host header doesn't match an expected profile e.g. matches an IP address; or
   # - User agent matches an expected profile e.g. Google/AWS metadata request;
   # - or nestCount means it's not a request directly from a client (but from an outer dockside container).
   # Ideally we should distinguish: request not from a client of this server; request not authorised with the expected header.
   #
   # If there's no X-Forwarded-For header, this container is not receiving a proxied request from another dockside container,
   # but a direct request.
   if(!$r->header_in("X-Forwarded-For")) {
      if($r->header_in('Metadata-Flavor') eq 'Google') {
         return '_UI_';
      }
   }

   # Lookup container
   my ($host, $prefix, $domain, $nestCount) = domain_to_host($r);
   wlog( "get_server_port($protocol): IP=" . $r->remote_addr . "; URI=" . $r->uri . "; Host=" . $r->header_in("Host") . "; XFF=[" . $r->header_in('X-Forwarded-For') . "]; nestCount=$nestCount => host=$host; prefix=$prefix; domain=$domain");

   # We handle the following cases:
   # - it’s a UI request;
   # - reservation not found from the hostname;
   # - reservation found but no container ID (not yet launched);
   # - reservation found, container ID found, but container no longer exists (destroyed);
   # - reservation found, container ID found, but container not running;
   # - reservation found, container ID found, container running, success!

   if( $host eq 'www' && $prefix eq '' ) {
      wlog( "get_server_port($protocol): host='www' and prefix=''; proxying to UI" );
      return '_UI_';
   }

   # Attempt to identify a Reservation via $host
   my $reservation = $host ? Reservation->load( { 'name' => $host } )->[0] : undef;

   # If not, return the non-branded error page code.
   unless( $reservation ) {
      wlog( "get_server_port($protocol): reservation '$host' not found" );
      return 400;
   }

   # We have identified a reservation, so let's identify the router:
   # returns: its URI; and required authorisation level.
   my $props = $reservation->lookup_container_uri($host, $prefix, $domain, $protocol);

   # Identify a user, and its available levels of authorisation.
   my $User = Request->authenticate( { 'cookie' => $r->header_in("Cookie"), 'protocol' => $protocol } );

   # Set debug logging data.
   my $authState = $User->{'_authstate'};
   my $authStateString = join(',', map { "$_=$authState->{$_}" } sort keys %$authState);

   # Choose the authentication failure response string
   # so that NGINX will display a branded error page only to authenticated users.
   my $errorCode = $User->username ? 410 : 400;

   wlog( "get_server_port($protocol): Host=" . $r->header_in("Host") . "; host=$host; prefix=$prefix; domain=$domain => reservation.name=$reservation->{'name'}; containerId=$reservation->{'containerId'}; uri:$props->{'uri'}; auth=$props->{'auth'}; access=$authStateString" );

   unless( $reservation->{'containerId'} ) {
      wlog( "get_server_port($protocol): container not yet launched for reservation $reservation->{'id'}" );
      return $errorCode;
   }

   if( $reservation->{'status'} == -3 ) {
      wlog( "get_server_port($protocol): containerId $reservation->{'containerId'} for reservation $reservation->{'id'} no longer exists" );
      return $errorCode;
   }

   unless( $reservation->{'status'} > 0 ) {
      wlog( "get_server_port($protocol): containerId $reservation->{'containerId'} for reservation $reservation->{'id'} not running" );
      return $errorCode;
   }

   # Prevent proxying loops: although it seems an unlikely edge case that a container will be asked to proxy to itself.
   if($HOSTNAME && $reservation->{'containerId'} eq $HOSTNAME) {
      wlog( "get_server_port($protocol): can't proxy to $reservation->{'containerId'} from host $HOSTNAME");
      return 400;
   }

   # If no container URI can be found, return $errorCode to trigger the error page.
   unless( $props->{'uri'} ) {
      wlog( "get_server_port($protocol): container inaccessible: no shared network with reservation $reservation->{'id'}" );
      return $errorCode;
   }

   # FIXME: Where do we put this code?
   # Can it exist here, or does it need to exist in App.pm?
   #
   # if( ( $reservation->{'meta'}{'authpath'} ne '' ) && ( $r->uri eq $reservation->{'meta'}{'authpath'} ) ) {
   #    my $value = # uniquify concat of existing value $User->authstate('containerCookie') and $reservation->{'meta'}{'secret'}.
   #    $r->status(301);
   #    $r->header_out( 'Set-Cookie',    "$CONFIG->{'containerCookie'}{'name'}=$value; Path=/; Domain=.$CONFIG->{'containerCookie'}{'domain'}; HttpOnly" );
   #    $r->header_out( 'Cache-Control', 'private' );
   #    $r->header_out( 'Location',      '/' );
   #    $r->send_http_header("text/plain");
   #    $r->print("Authenticating\n");
   #    return nginx::OK;
   # }

   # Now check if $User can access services (on any running reservation) with access level $props->{'auth'}
   my $reservationPermissions = $User->reservationPermissions($reservation);
   if( $reservationPermissions->{'auth'}{ $props->{'auth'} } ) {
      return $props->{'uri'};
   }

   return $errorCode;
}

# PUBLIC METHODS
# --------------

# Given a local base port number, convert to a host:port pair for http.
sub http_server_port {
   my $r = shift;

   return get_server_port($r, 'http');
}

# Given a local base port number, convert to a host:port pair for https or the ide
sub https_server_port {
   my $r = shift;

   return get_server_port($r, 'https');
}

# Remove the configured uidCookie(s) from the cookie header.
# We'll use this to set the cookie header on the request proxied to
# the subcontainer.
sub upstream_cookie {
   my $r = shift;

   my $cookie = $r->header_in('Cookie');

   $cookie =~ s/\b\Q$CONFIG->{'uidCookie'}{'name'}\E(?:_http)?=[^ ;]+(;\s*)?//sg;

   return $cookie;
}

1;
