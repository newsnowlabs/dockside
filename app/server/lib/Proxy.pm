package Proxy;

BEGIN {
   eval {
      require nginx;
      nginx->import();
   };
}

use v5.36;

use Try::Tiny;
use Reservation;
use Util qw(flog wlog);
use Data qw($CONFIG $HOSTNAME);
use Request;

flog({ 'service' => 'dockside-proxy' });

# Load at module-load time - previously App.pm's own perl_require (loaded first in nginx
# config) guaranteed $CONFIG was populated before Proxy's own perl_set vars ever ran; that
# module_require is gone now that App.pm's own content-handler role has moved to bin/app-server
# (see docs/plans/mojolicious-app-server-split-plan.md's cutover), so Proxy must ensure this
# itself rather than depend on load order elsewhere in the config.
Data::load();

# Where a UI/API request gets proxied to, now that App.pm is no longer perl_require'd (and
# hence no longer runs as nginx's own content handler) - bin/app-server, standalone, on
# loopback. Replaces the old '_UI_' sentinel string (which relied on falling through to
# nginx's own `perl App::handlerHTTP[S];` content-handler directive once no proxy_pass matched
# - that directive is gone from the nginx config too, see the same cutover).
sub ui_uri () {
   return sprintf( 'http://127.0.0.1:%d', $CONFIG->{'appServer'}{'port'} // 8100 );
}

# Given a domain, extract the unique code identifying the host publicly.
sub domain_to_host ($r) {
   my $host = $r->header_in("Host");

   # wlog("domain_to_host: host=$host");

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

      # Split on two and only two dashes; these separate nested Dockside containers
      my @elements = reverse split(/(*nlb:-)--(*nla:-)/, $1);
      my $domain = $2;

      # Retain <service> (e.g. 'ide') or e.g. 8eb55c33-985f-406e-b9e7-a8b0c4962e1e-wv-<service> as $service
      # Add the devtainer name (if found) to @elements.
      # Always add the service name to @elements.
      # See launch-ide.sh THEIA_WEBVIEW_EXTERNAL_ENDPOINT and THEIA_MINI_BROWSER_HOST_PATTERN.
      my ($service, $topHost) = pop(@elements) =~ /^((?:.*-(?:wv|mb|webview|minibrowser)-)?[^-]+)(?:-(.*))?$/;
      push(@elements, $topHost ? $topHost : (), $service);

      my $nestCount = split(/-/, $r->header_in('X-Nest-Level') // '');

      return undef unless $nestCount < @elements;

      my $element = $elements[$nestCount];
      my $prefix = join('--', reverse @elements[($nestCount+1)..(@elements-1)]);

      # wlog("domain_to_host: Host header='$host'; nestCount=$nestCount; container host='$element'; prefix='$prefix'; domain='$domain'");

      return ($element, $prefix, $domain, $nestCount);
   }

   return undef;
}

# Renamed from get_server_port - see the fail-closed get_server_port wrapper below, which is
# the name nginx config actually calls now.
sub _get_server_port ($r, $protocol) {
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
      if(($r->header_in('Metadata-Flavor') // '') eq 'Google') {
         return ui_uri();
      }
   }

   # Lookup container
   my ($host, $prefix, $domain, $nestCount) = domain_to_host($r);
   # wlog( "_get_server_port($protocol): IP=" . $r->remote_addr . "; URI=" . $r->uri . "; Host=" . $r->header_in("Host") . "; XFF=[" . $r->header_in('X-Forwarded-For') . "]; nestCount=$nestCount => host=$host; prefix=$prefix; domain=$domain");

   # We handle the following cases:
   # - it’s a UI request;
   # - reservation not found from the hostname;
   # - reservation found but no container ID (not yet launched);
   # - reservation found, container ID found, but container no longer exists (destroyed);
   # - reservation found, container ID found, but container not running;
   # - reservation found, container ID found, container running, success!

   if( $host eq 'www' && $prefix eq '' ) {
      # wlog( "_get_server_port($protocol): host='www' and prefix=''; proxying to UI" );
      return ui_uri();
   }

   # Attempt to identify a Reservation via $host
   my $reservation = $host ? Reservation->load( { 'name' => $host } )->[0] : undef;

   # If not, return the non-branded error page code.
   unless( $reservation ) {
      wlog( "_get_server_port($protocol): reservation '$host' not found" );
      return 400;
   }

   # We have identified a reservation, so let's identify the router:
   # returns: its URI; and required authorisation level.
   my $props = $reservation->lookup_container_uri($host, $prefix, $domain, $protocol);

   # For the SSH router, route wstunnel v10 upgrade requests (/v1/...) to the v10
   # server port (2223) rather than the v6 server port (2222).
   if ($prefix eq 'ssh' && defined($props->{'uri'}) && $r->uri =~ m{^/v1(?:/|\z)}) {
      my $v10port = $CONFIG->{'ssh'}{'v10port'} // 2223;
      $props->{'uri'} =~ s/:\d+$/:$v10port/;
   }

   # Identify a user, and its available levels of authorisation.
   my $User = Request->authenticate( { 'cookie' => $r->header_in("Cookie"), 'protocol' => $protocol } );

   # Set debug logging data.
   my $authState = $User->{'_authstate'};
   my $authStateString = join(',', map { "$_=$authState->{$_}" } sort keys %$authState);

   # Choose the authentication failure response string
   # so that NGINX will display a branded error page only to authenticated users.
   my $errorCode = $User->username ? 410 : 400;

   wlog( "_get_server_port($protocol): Host=" . ($r->header_in("Host") // '[EMPTY]') . "; host=$host; prefix=$prefix; domain=$domain => reservation.name=$reservation->{'name'}; containerId=$reservation->{'containerId'}; uri:$props->{'uri'}; auth=$props->{'route'}{'auth'}; access=$authStateString" );

   unless( $reservation->{'containerId'} ) {
      wlog( "_get_server_port($protocol): container not yet launched for reservation $reservation->{'id'}" );
      return $errorCode;
   }

   if( $reservation->{'status'} == -3 ) {
      wlog( "_get_server_port($protocol): containerId $reservation->{'containerId'} for reservation $reservation->{'id'} no longer exists" );
      return $errorCode;
   }

   unless( $reservation->{'status'} > 0 ) {
      wlog( "_get_server_port($protocol): containerId $reservation->{'containerId'} for reservation $reservation->{'id'} not running" );
      return $errorCode;
   }

   # Prevent proxying loops: although it seems an unlikely edge case that a container will be asked to proxy to itself.
   if($HOSTNAME && $reservation->{'containerId'} eq $HOSTNAME) {
      wlog( "_get_server_port($protocol): can't proxy to $reservation->{'containerId'} from host $HOSTNAME");
      return 400;
   }

   # If no container URI can be found, return $errorCode to trigger the error page.
   unless( $props->{'uri'} ) {
      wlog( "_get_server_port($protocol): container inaccessible: no shared network with reservation $reservation->{'id'}" );
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

   # Now check if $User can access services (on any running reservation) with access level $props->{'route'}{'auth'}
   my $reservationPermissions = $User->reservationPermissions($reservation);
   if( $reservationPermissions->{'auth'}{ $props->{'route'}{'auth'} } ) {
      return $props->{'uri'};
   }

   return $errorCode;
}

# Fail-closed wrapper around _get_server_port above. Before this split, an uncaught die here
# left $upstream_http/$upstream_https unset, and nginx's own `perl App::handlerHTTP[S];`
# directive (the location's default content handler) served the request instead - never
# actually a *safe* fallback, just an accidental one. That directive is gone now (see the
# cutover), so an uncaught die here would otherwise propagate as nginx's own generic 500 with
# no branded error page and no log context. Catch here instead, log it, and fail closed to the
# same '400' _get_server_port itself already uses for "reservation not found" - nginx's own
# `if ($upstream_http = '400') {...}` block (see the nginx config) already handles that value.
sub get_server_port ($r, $protocol) {
   return try {
      return _get_server_port($r, $protocol);
   }
   catch {
      wlog("get_server_port($protocol): caught exception: " . ( ref($_) ? $_->dbg : $_ ));
      return '400';
   };
}

# PUBLIC METHODS
# --------------

# Given a local base port number, convert to a host:port pair for http.
sub http_server_port ($r) {
   return get_server_port($r, 'http');
}

# Given a local base port number, convert to a host:port pair for https or the ide
sub https_server_port ($r) {
   return get_server_port($r, 'https');
}

# True for exactly the same request shape _get_server_port's own UI checks above route to
# ui_uri() - the metadata gate (no XFF, Metadata-Flavor: Google), or a plain 'www' host with no
# devtainer prefix. Shared here so upstream_cookie and forwarded_host both apply the same
# UI-vs-devtainer distinction as routing itself, rather than each re-deriving it.
sub is_ui_request ($r) {
   if ( !$r->header_in('X-Forwarded-For') && ( $r->header_in('Metadata-Flavor') // '' ) eq 'Google' ) {
      return 1;
   }

   my ($host, $prefix) = domain_to_host($r);
   return ( defined($host) && $host eq 'www' && $prefix eq '' ) ? 1 : 0;
}

# Remove the configured uidCookie(s) from the cookie header - for a devtainer-bound request
# only; a UI/API-bound request (now genuinely proxied to bin/app-server, not handled in-process
# - see is_ui_request's own comment) needs the cookie intact, since bin/app-server's own
# Request->authenticate reads it directly, same as App.pm always did when it ran embedded.
sub upstream_cookie ($r) {
   my $cookie = $r->header_in('Cookie');

   return $cookie if is_ui_request($r);

   $cookie =~ s/\b\Q$CONFIG->{'uidCookie'}{'name'}\E(?:_http)?=[^ ;]+(;\s*)?//sg;

   return $cookie;
}

# Backs the nginx config's own $forwarded_host perl_set var (replacing a plain
# `proxy_set_header X-Forwarded-Host $host;`) - a UI/API request now needs its header to carry
# the port bin/app-server's own Mojolicious stack expects to see reflected back (matching
# $r->header_in('Host') exactly, port included where present), while a devtainer-bound request
# must keep receiving exactly the port-stripped value $host already gives it today (unchanged
# behaviour - devtainer-side code depends on the header never carrying a port). is_ui_request is
# exactly the same test that routes a request to ui_uri() in the first place, so this header only
# ever carries a port precisely when the request is actually going to the app server.
#
# $r->variable('host'), not a $r->hostname method - ngx_http_perl_module's documented $r API
# (header_in/header_out/variable/uri/args/... - see http://nginx.org/en/docs/http/
# ngx_http_perl_module.html) has no 'hostname' method; $r->variable(name) is its own documented
# mechanism for reading any nginx-level variable from Perl, and 'host' is nginx's own core
# variable (the same $host already used elsewhere in this file's nginx config, port-stripped
# per nginx's own docs) - this reads the exact same value.
sub forwarded_host ($r) {
   return is_ui_request($r) ? $r->header_in('Host') : $r->variable('host');
}

1;
