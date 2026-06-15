package App;

use v5.36;

BEGIN {
   eval {
      require nginx;
      nginx->import();
   };
}

use JSON;
use URI::Escape;
use Try::Tiny;
use File::Path;
use Digest::SHA qw(sha256_hex);
use Util qw(flog wlog run run_pty sanitize_sensitive_text YYYYMMDDHHMMSS);
use Data qw($CONFIG $VERSION $HOSTINFO $HOSTNAME);
use Containers;
use Profile;
use Reservation;
use Request;
use User;
use App::Metadata;

####################################################################################################
# May be used in future to validate git branch references passed into launching containers.
# RegExp rules based on git-check-ref-format
# my $valid_ref_name = qr%^(?!.*/\.)(?!.*\.\.)(?!/)(?!.*//)(?!.*\@\{)(?!\@$)(?!.*\\)[^\000-\037\177 ~^:?*\[]+/[^\000-\037\177 ~^:?*\[]+(?<!\.lock)(?<!/)(?<!\.)$%;

####################################################################################################

flog({ 'service' => "dockside-app" });
Data::load();

####################################################################################################

sub get_asset ($filename) {
   return '' if !defined($filename) || $filename =~ /\.\./;
   open( my $FH, '<', "$CONFIG->{'assetsPath'}/$filename" ) || return '';
   local $/;
   my $contents = <$FH>;
   close $FH;
   return $contents;
}

sub get_client_asset ($filename) {
   return '' if !defined($filename) || $filename =~ /\.\./;
   open( my $FH, '<', "$CONFIG->{'clientDistPath'}/$filename" ) || return '';
   local $/;
   my $contents = <$FH>;
   close $FH;
   return $contents;
}

# A short, opaque cache-buster for a built client asset: a hash of its mtime+size (a cheap
# stat, no file read). It changes on every rebuild — including dev rebuilds with no git
# commit — so an immutable-cached asset URL is refreshed exactly when the file changes.
# Not the git version: that wouldn't change on a dev rebuild and needlessly reveals the
# commit (the version is already in window.dockside.version for traceability). Falls back
# to 'missing' only if the file is absent (a broken deploy — the asset route 404s too, so
# the value is moot); that just avoids an undef-interpolation warning at page render.
sub _asset_version ($filename) {
   my @st = stat("$CONFIG->{'clientDistPath'}/$filename");
   return @st ? substr( sha256_hex("$st[9]-$st[7]"), 0, 12 ) : 'missing';
}

sub get_header ($title = undef) {
   return get_asset('header.html') . 
      "   <title>" . ($title // 'Dockside - A dev and staging environment in one - From NewsNow Labs') . "</title>\n" .
      get_asset('gtm.html');
}

####################################################################################################

sub log_status ($sub, $json) {
   flog("$sub: " . $json->{'msg'});

   return $json;
}

####################################################################################################
#
# Router logic: the main application entry point.
#

sub split_args ($queryString) {
   # Split querystring-style arguments, and unescape them
   my %hash = map { uri_unescape($_) } split( /[=&]/, $queryString );

   # Map once more to eliminate any hash key mapping to undef
   return { map { $_ // '' } %hash };
}

# Parse a POST request body into a normalised hashref whose values are always
# decoded Perl structures (numbers, booleans, hashrefs, arrayrefs) — never raw
# JSON strings.  This single normalisation point means apply_args_to_record()
# in Util.pm never needs to distinguish between content types.
#
# Two content-type paths:
#   application/json  — decode the whole body as a JSON object directly.
#                       A non-empty body that fails to decode to a JSON object
#                       is rejected with HTTP 400 (see below), not coerced to {};
#                       an empty body is handled by the form path as an
#                       intentionally-empty argument set.
#   form-encoded      — split key=value pairs, URL-unescape each token, then
#                       JSON-decode each individual value so the result matches
#                       the shape of the JSON path.  This preserves CLI support:
#                       the CLI sends form-encoded bodies whose values are
#                       JSON-stringified (e.g. permissions='{"actions":{...}}').
#                       Plain string values that are not valid JSON are kept as-is.
#
# Edge case: a key without a value in form-encoded input (e.g. "key1&key2=v")
# produces a hash entry with an undef value.  apply_args_to_record() skips
# undef-valued keys, so this is handled safely downstream.
#
# Special key '_unset': must be a JSON array of dotted-path keys to delete from
# the record.  If decoding fails or yields a non-array, it defaults to [].
sub parse_body_args ($r) {
   my $body = $r->request_body // '';
   my $ct   = $r->header_in('Content-Type') // '';

   if ( $ct =~ m{application/json}i && length $body ) {
      my $decoded = eval { JSON::XS->new->utf8->decode($body) };
      # A declared JSON body that does not decode to an object is a malformed
      # request, not an empty one: reject it with 400 rather than silently
      # coercing to {} (which would let a mutation appear to succeed as a no-op).
      # An empty body never reaches here (guarded by `length $body` above) and so
      # still parses as an intentionally-empty argument set via the form path.
      die Exception->new(
         'msg'    => 'Request body is not a valid JSON object',
         'dbg'    => 'parse_body_args: application/json body failed to decode to a HASH'
                     . ( $@ ? ": $@" : '' ),
         'status' => 400,
      ) unless ref($decoded) eq 'HASH';
      return $decoded;
   }

   # Form-encoded fallback: split on '=' and '&', then for each token translate
   # '+' to space before percent-decoding (application/x-www-form-urlencoded
   # encodes a space as '+' and a literal '+' as %2B, so '+'->space must happen
   # before uri_unescape turns %2B back into '+'), and finally JSON-decode each
   # value so the result has the same shape as the JSON path.  The first-party
   # CLI percent-encodes spaces, but other form clients rely on '+'.
   my %flat = map { ( my $t = $_ ) =~ tr/+/ /; uri_unescape($t) } split( /[=&]/, $body );
   my %decoded;
   for my $key ( keys %flat ) {
      my $v = $flat{$key};
      if ( $key eq '_unset' ) {
         # _unset must be a JSON array of dotted-path keys; treat decode failure
         # or a non-array result as an empty list so callers see a safe value.
         my $list = eval { decode_json($v) };
         $decoded{$key} = ( ref $list eq 'ARRAY' ) ? $list : [];
      }
      elsif ( defined $v && length $v ) {
         # Attempt JSON decode; fall back to plain string if $v is not valid JSON.
         # This covers both simple scalars ("alice") and structured values
         # ('{"actions":{"manageUsers":true}}') sent by the CLI.
         my $d = eval { decode_json($v) };
         $decoded{$key} = $@ ? $v : $d;
      }
      else {
         # Empty or undef value: pass through as-is.
         $decoded{$key} = $v;
      }
   }
   return \%decoded;
}

# Return a merged args hashref for the request.
# For POST requests the body is parsed (via parse_body_args) and merged with
# any query-string args; query-string values take precedence on collision so
# that routing parameters cannot be silently overridden by a crafted body.
# For non-POST requests only the query-string is used.
sub get_args ($r, $querystring) {
   if ( $r->request_method eq 'POST' ) {
      my $body_args = parse_body_args($r);
      my $qs_args   = split_args($querystring);
      return { %$body_args, %$qs_args };   # query-string wins on collision
   }
   return split_args($querystring);
}

sub json ($r, $code, $data) {
   $r->status($code);
   $r->header_out( 'Cache-Control', 'no-store' );
   $r->send_http_header("application/json");

   # canonical: sort object keys so every API response has a deterministic key
   # order (Perl hash order is otherwise randomised per process). This gives
   # clients — the admin JSON editor and the CLI — stable, diff-friendly output.
   $r->print( JSON::XS->new->utf8->convert_blessed->canonical->encode( $data ) );

   return nginx::OK;
}

sub redirect ($r, $code, $location, $headers = []) {
   $r->status($code);
   $r->header_out( 'Cache-Control', 'no-store' );
   $r->header_out( 'Location',      $location );

   foreach my $h (@$headers) {
      $r->header_out(@$h);
   }

   $r->send_http_header("text/plain");
   $r->print("Redirecting to $location ...\n");

   return nginx::OK;
}

sub html ($r, $code, $data) {
   $r->status($code);
   $r->header_out( 'Cache-Control', 'no-store' );
   $r->send_http_header("text/html");

   $r->print( $data );

   return nginx::OK;
}

sub text ($r, $code, $data) {
   $r->status($code);
   $r->header_out( 'Cache-Control', 'no-store' );
   $r->send_http_header("text/plain");

   $r->print( $data );

   return nginx::OK;
}

sub send_branded_page ($r, $code, $class, $html) { # nginx request object
   $r->status($code);
   $r->send_http_header("text/html");
   $r->print( get_header() );
   $r->print( "<style>\n" . get_asset('signin.css') . "\n</style>\n" );
   $r->print("</head><body>\n");
   $r->print('<link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/css/bootstrap.min.css" integrity="sha384-BVYiiSIFeK1dGmJRAkycuHAHRg32OmUcww7on3RYdg4Va+PmSTsz/K68vbdEjh4u" crossorigin="anonymous">');
   $r->print('<div class="container"><div class="branded ' . $class . '"><div class="dockside"></div>' . $html . "</div></div>\n</body></html>\n");
   return nginx::OK;
}

sub send_login_page ($r) { # nginx request object
   return send_branded_page($r, 200, 'signin', <<'_EOE_'
   <form method="POST" accept-charset="UTF-8">
      <label for="inputUser" class="sr-only">Username</label>
      <input name="username" type="username" id="inputUser" class="form-control" placeholder="Username" autocomplete="username" required autofocus>
      <label for="inputPassword" class="sr-only">Password</label>
      <input name="password" type="password" id="inputPassword" class="form-control" placeholder="Password" autocomplete="current-password" required>
      <input class="btn btn-lg btn-primary btn-block" type="submit" value="Sign in">
   </form>
_EOE_
   );
}

sub handle_login_form ($r, $parentFQDN) { # nginx request object # copy of $parentFQDN
   # Extract credentials from body.
   # Unescape keys and values, for consistency and simplicity.
   my %credentials = map { uri_unescape($_) } split(/[&=]/, $r->request_body);

   try {

      my $User = Request->authenticate_by_credentials( $credentials{'username'}, $credentials{'password'} );

      if( ref($User) ) {
         my @cookies = $User->generate_auth_cookies($parentFQDN);

         # On successful login, redirect with 302 to current URI
         redirect($r, 302, $r->uri, [
            map { ['Set-Cookie', $_] } @cookies
         ]);
         return 1;
      }
      elsif( $User eq 'INVALID' ) {
         flog("auth_cookie: credentials not valid for user '$credentials{'username'}'");
         return 0;
      }
      elsif( $User eq 'NOTFOUND' ) {
         flog("auth_cookie: user '$credentials{'username'}' not found in users.json: check file for errors");
         return 0;
      }
      else {
         flog("auth_cookie: unknown error authenticating: check users.json for errors");
         return 0;
      }
   }
   catch {
      flog("auth_cookie: caught exception: '$_'");
      return 0;
   }

   # Fallthrough: try return code will be returned here.
}

# ---------------------------------------------------------------------------
# Named body-handler callbacks for has_request_body().
#
# nginx's XS binding for has_request_body() stores the callback's raw code
# pointer (CV*) without calling SvREFCNT_inc.  When the callback is an
# anonymous sub, its refcount drops to zero as soon as _handler() returns
# nginx::OK, freeing the CV.  When nginx's event loop later invokes the
# callback (after the request body has been read asynchronously), it holds a
# dangling pointer → call_sv("") failed → HTTP 500.
#
# Named subs are always anchored in the package symbol table, so their CV is
# never freed regardless of whether nginx increments the refcount.
# ---------------------------------------------------------------------------

sub _login_body_handler ($r) {
   my $parentFQDN = $r->header_in('Host'); $parentFQDN =~ s!^[^\-\.]+!!;
   $parentFQDN = '-' . $parentFQDN unless $parentFQDN =~ /^\./;
   handle_login_form($r, $parentFQDN) || send_login_page($r);
   # Return OK regardless of handle_login_form's result: the body handler must let
   # nginx flush the buffered 302 redirect. Propagating its truthy success value (1)
   # would suppress the flush and the client would see RemoteDisconnected.
   return nginx::OK;
}

sub _api_body_handler ($r) {
   my $parentFQDN = $r->header_in('Host'); $parentFQDN =~ s!^[^\-\.]+!!;
   $parentFQDN = '-' . $parentFQDN unless $parentFQDN =~ /^\./;
   my $User = Request->authenticate( { 'cookie' => $r->header_in("Cookie"), 'protocol' => 'https' } );
   return _api_handler($r, $User, $r->args, $parentFQDN);
}

sub _handler ($r, $protocol) { # nginx request object; protocol = 'http' | 'https'
   # Create temporary path needed for cache and log files.
   if( ! -d $CONFIG->{'tmpPath'} ) {
      mkpath( [ $CONFIG->{'tmpPath'} ], 0, 0755 );
   }

   # Ignore HEAD requests.
   return nginx::OK if $r->header_only;

   # Check for, and handle, metadata requests.
   if( App::Metadata::handle($r) == nginx::OK ) {
      return nginx::OK;
   }

   # Reject all requests for the UI, unless protocol is HTTPS.
   return nginx::HTTP_BAD_REQUEST unless $protocol eq 'https';

   my $route = $r->uri;
   my $querystring = $r->args;

   # Generate the 'parent fully qualified domain name', i.e.
   # a hostname from which child container hostnames can be generated,
   # (and from which a cookie domain can ultimately be derived)
   # by stripping off leading characters up to the first '-' or '.'
   #
   # Host header may be of the form:
   # - www.mydockside.co.uk -> .mydockside.co.uk
   # - www-mydevtainer.mydockside.co.uk -> --mydevtainer.mydockside.co.uk
   # - www-mydevtainer--mydocksidedevtainer.mydockside.co.uk -> --mydevtainer--mydocksidedevtainer.mydockside.co.uk
   #
   # When Dockside is accessed on a non-standard port, the Host header may also have :<port> suffixed.

   my $parentFQDN = $r->header_in('Host'); $parentFQDN =~ s!^[^\-\.]+!!;
   $parentFQDN = '-' . $parentFQDN unless $parentFQDN =~ /^\./;

   # Determine level of authorisation of requestor.
   my $User = Request->authenticate( { 'cookie' => $r->header_in("Cookie"), 'protocol' => $protocol } );

   # If globalCookie authentication is enabled, prevent access unless the global cookie is set.
   if( $User->authstate('globalCookieRequired') && !$User->authstate('globalCookie') ) {
      $r->status(401);
      $r->header_out( 'Cache-Control', 'no-store' );
      $r->send_http_header("text/plain");
      $r->print("Not found!\n");
      return nginx::OK;
   }

   # Serve /docs/ statically.
   if( $route =~ m!^/docs(?:/|$)! ) {
      return nginx::DECLINED;
   }

   # Serve /favicon.ico etc.
   if( $route =~ m!^/(favicon\.ico|apple-touch-icon\.png)$! ) {
      my $file = $&;
      $r->status(200);
      $r->send_http_header("image/icon");
      $r->sendfile("$CONFIG->{'assetsPath'}/ico/$file");
      return nginx::OK;
   }

   if( $route =~ m!^/ico/[a-z0-9\-_]+\.png$! ) {
      my $file = $&;
      $r->status(200);
      $r->send_http_header("image/png");
      $r->sendfile("$CONFIG->{'assetsPath'}/$file");
      return nginx::OK;
   }

   if( $route =~ m!^/ico/[a-z0-9\-_]+\.svg$! ) {
      my $file = $&;
      $r->status(200);
      $r->send_http_header("image/svg+xml");
      $r->sendfile("$CONFIG->{'assetsPath'}/$file");
      return nginx::OK;
   }

   # If no auth cookie exists, cookie cannot be validated, or user is not still valid, then show sign-in screen.
   unless( $User->username ) {

      # GET request? Then send login page.
      if( $r->request_method ne "POST") {
         
         # If / or /container/, serve login page.
         # Otherwise redirect to / to serve login page.
         unless( $route eq '/' || $route =~ m!^/container/! ) {
            return redirect($r, 302, '/');
         }

         return send_login_page($r);
      }

      # POST request? Then handle login form, and on failure send login page again.
      if( $r->has_request_body(\&_login_body_handler) ) {
         return nginx::OK;
      }

      return nginx::HTTP_BAD_REQUEST;
   }

   # User is signed in.
   # Enable for verbose request logging:
   # flog("App: route=$route; User=" . $User->username);

   # Serve the Vue client bundle (main.js, main.css) as separate, cacheable assets rather
   # than inlining them into every page. Placed below the auth gate so they are served to
   # authenticated users only. nginx gzips the responses on the fly (application/javascript
   # and text/css are in gzip_types); the ?v= cache-buster on the references below changes
   # whenever the file changes, so a long immutable max-age is safe. ($route is the path
   # only — $r->uri — so the ?v= query does not affect this match, and the regex pins the
   # exact filenames, so there is no path traversal.)
   if( $route =~ m!^/assets/main\.(js|css)$! ) {
      my $ext = $1;
      my %content_type = ( 'js' => 'application/javascript', 'css' => 'text/css' );
      $r->status(200);
      $r->header_out('Cache-Control', 'public, max-age=31536000, immutable');
      $r->send_http_header( $content_type{$ext} );
      $r->sendfile("$CONFIG->{'clientDistPath'}/main.$ext");
      return nginx::OK;
   }

   if( $route eq '/' || $route =~ m!^/(container|admin|account)(/|$)! ) {
      ###############################
      # Display main page HTML
      #
      $r->send_http_header("text/html");
      $r->print( get_header() );
      # main.css served as a separate cacheable, gzip-compressible asset (see the
      # /assets/main.(js|css) route above), not inlined. Render-blocking in <head> like the
      # inline <style> it replaces, so styles still apply before first paint.
      my $css_v = _asset_version('main.css');
      $r->print( qq{<link rel="stylesheet" href="/assets/main.css?v=$css_v">\n} );

      # Output permissions for signed-in user
      try {

         $r->print(
            sprintf( "<script>window.dockside = %s\n</script>",
                     JSON::XS->new->utf8->convert_blessed->encode(
                        {
                           # FIXME: set 'user' => $User, after simply either (a) changing User object definition to make 'permissions' the derivedPermissions; or (b) the Vue app to check user.derivedPermissions.
                           'user'    => {
                              %{ $User->details() }, # username, name, email, id
                              'role' => $User->role, # User's role
                              'role_as_meta' => $User->role_as_meta, # User's role in metadata format
                              'permissions' => { 'actions' => $User->permissions() } # User's permissions
                           },
                           'profiles' => $User->profiles(),
                           'containers' => $User->reservations({'client' => 1}),
                           'viewers' => User->viewers(),
                           'dummyReservation' => $User->createClientReservation(),
                           'host' => $parentFQDN,
                           'version' => $VERSION // 'v-unknown'
                        }
                     )
            )
         );
      }
      catch {
         # FIXME: The caught exception can itself be an exception: find a way to rethrow it, preserving the msg/dbg history for debug purposes.
         die Exception->new( 'msg' => 'Failed to initialise client-side data structures', 'dbg' => "Caught exception: $_" );
      };

      $r->print('</head>');
      $r->print( '<body data-spy="scroll" data-target=".sidebar">' . "\n" );
      $r->print( "<div id='app'><router-view></router-view></div>\n" );
      # main.js served as a separate cacheable, gzip-compressible asset (see the
      # /assets/main.(js|css) route above) instead of inlining ~3.8 MiB into every page.
      my $js_v = _asset_version('main.js');
      $r->print( qq{<script src="/assets/main.js?v=$js_v"></script>\n} );
      $r->print("</body></html>\n");

      return nginx::OK;
   }

   ###############################
   # AJAX SERVICES
   #

   if ( $r->request_method eq 'POST' ) {
      if ( $r->has_request_body(\&_api_body_handler) ) {
         return nginx::OK;
      }
      # A bodyless POST (e.g. a no-arg mutation like remove/start/stop) still needs
      # dispatching — there is simply nothing to read first.
      return _api_handler( $r, $User, $querystring, $parentFQDN );
   }

   return _api_handler( $r, $User, $querystring, $parentFQDN );
}

# ---------------------------------------------------------------------------
# _api_handler — dispatches all authenticated API requests.
# Called directly for GET; called from within a has_request_body() callback
# for POST (at which point $r->request_body is populated and get_args() works).
# ---------------------------------------------------------------------------
sub _api_handler ($r, $User, $querystring, $parentFQDN) {
   my $route = $r->uri;
   my $type = 'json';
   try {

      #############################################
      # Create a Reservation and launch a container
      #
      if( $route =~ m!^/containers/create/?$! ) {
         my $args = split_args($querystring); # Split querystring-style arguments

         # Use the current host's parentFQDN string to generate the child
         # container's hostname, if none has been provided.
         $args->{'parentFQDN'} ||= $parentFQDN;

         my $reservation = $User->createContainerReservation( $args );
         return json($r, $reservation ? 200 : 401, { 'status' => $reservation ? '200' : '401', 'reservation' => $reservation });
      }

      ##########################
      # Update i.e. save an edit
      #
      if( $route =~ m!^/containers/([^\/]+)/update/?$! ) {
         my $id = $1;
         my $args = split_args($querystring); # Split querystring-style arguments
         $args->{'id'} = $id if $id;

         my $reservation = $User->updateContainerReservation($args);
         return json($r, $reservation ? 200 : 401, { 'status' => $reservation ? '200' : '401', 'reservation' => $reservation });
      }

      ###################
      # Start/Stop/Remove
      #
      if( $route =~ m!^/containers/([^\/]+)/(stop|start|remove)/?$! ) {
         my $id = $1;
         my $cmd = $2;

         # Currently we ignore the return value. This is not ideal, but:
         # (a) it is not strictly necessary, the current state of the container will be updated in the Vue app
         #     and the success/failure of their request to change container state will ultimately be apparent.
         # (b) some commands like 'docker start' can also return success, but then the container can fail
         #     to start anyway.
         # (c) until there is better support in the Vue app to display errors, there is no point in returning;

         $User->controlContainer($cmd, $id);

         return json($r, 200, { 'status' => '200', 'data' => $User->reservations({'client' => 1}) });
      }

      ######################################
      # Load Reservations and container data
      #
      if( $route =~ m!^/containers/([^\/]+)/logs/?$! ) {
         my $id = $1;
         my $args = split_args($querystring); # Split querystring-style arguments

         if($args->{'format'} eq 'text') {
            $type = 'text';
         }

         my $logs = $User->controlContainer('getLogs', $id, $args);

         return ($args->{'format'} eq 'text') ? text($r, 200, join('', @$logs)) : json($r, 200, { 'status' => '200', 'data' => $logs });
      }

      ######################################
      # Load Reservations and container data
      #
      if( $route =~ m!^/containers/?$! ) {

         my $containers = $User->reservations({'client' => 1});
         return json($r, 200, { 'status' => '200', 'data' => $containers });
      }

      ######################################
      # Host resources — runtimes, networks, IDEs, auth modes
      # Used by the admin UI to populate resource suggestion lists.
      #

      if( $route =~ m!^/resources/?$! ) {
         die Exception->new( 'msg' => "You need the 'manageUsers' or 'manageProfiles' permission" )
            unless $User->has_permission('manageUsers') || $User->has_permission('manageProfiles');
         my @networks = sort { $a cmp $b } keys %{ (Containers->containers // {})->{$HOSTNAME // ''}{'inspect'}{'Networks'} // {} };
         my @runtimes = sort { $a cmp $b } keys %{ ($HOSTINFO->{'docker'} // {})->{'Runtimes'} // {} };
         my @IDEs     = @{ $HOSTINFO->{'IDEs'} // [] };
         return json($r, 200, {
            'status' => '200',
            'data'   => {
               'runtimes'  => \@runtimes,
               'networks'  => \@networks,
               'IDEs'      => \@IDEs,
               'authModes' => ['user', 'developer', 'public', 'viewer', 'owner'],
            }
         });
      }

      ######################################
      # State-changing admin/self endpoints must use POST.  Mutations must not be
      # reachable via GET: GET has cacheable/prefetchable/logged side effects, and
      # the GET arg parser (split_args) does not JSON-decode values, so structured
      # fields would be corrupted.  Container routes are intentionally NOT enforced
      # here (their GET→POST migration is staged separately).
      #
      if ( $route =~ m!^/(?:me/update|users/create|users/[^/]+/(?:update|remove)|roles/create|roles/[^/]+/(?:update|remove)|profiles/create|profiles/[^/]+/(?:update|remove|rename))/?$!
           && $r->request_method ne 'POST' ) {
         return json($r, 405, { 'status' => '405', 'msg' => 'Method Not Allowed: use POST' });
      }

      ######################################
      # Account (self-service) — any authenticated user
      #

      if( $route =~ m!^/me/?$! ) {
         my $record = $User->getSelf();
         return json($r, 200, { 'status' => '200', 'data' => $record });
      }

      if( $route =~ m!^/me/update/?$! ) {
         my $args = get_args($r, $querystring);
         my $record = $User->updateSelf($args);
         return json($r, 200, { 'status' => '200', 'data' => $record });
      }

      if( $route =~ m!^/me/profiles/?$! ) {
         return json($r, 200, { 'status' => '200', 'data' => $User->profiles() });
      }

      ######################################
      # User management
      #

      if( $route =~ m!^/users/?$! ) {
         my $args = split_args($querystring);
         return json($r, 200, { 'status' => '200', 'data' => $User->listUsers($args) });
      }

      if( $route =~ m!^/users/create/?$! ) {
         my $args = get_args($r, $querystring);
         my $record = $User->createUser($args);
         return json($r, 200, { 'status' => '200', 'data' => $record });
      }

      if( $route =~ m!^/users/([^/]+)/?$! && $r->request_method eq 'GET' ) {
         my $username = $1;
         my $args = split_args($querystring);
         my $record = $User->getUser($username, $args);
         return json($r, 200, { 'status' => '200', 'data' => $record });
      }

      if( $route =~ m!^/users/([^/]+)/update/?$! ) {
         my $username = $1;
         my $args = get_args($r, $querystring);
         my $record = $User->updateUser($username, $args);
         return json($r, 200, { 'status' => '200', 'data' => $record });
      }

      if( $route =~ m!^/users/([^/]+)/remove/?$! ) {
         my $username = $1;
         my $args = split_args($querystring);
         my $result = $User->removeUser($username, $args);
         return json($r, 200, { 'status' => '200', 'data' => $result });
      }

      ######################################
      # Role management
      #

      if( $route =~ m!^/roles/?$! ) {
         return json($r, 200, { 'status' => '200', 'data' => $User->listRoles() });
      }

      if( $route =~ m!^/roles/create/?$! ) {
         my $args = get_args($r, $querystring);
         my $name = $args->{'name'}
            or die Exception->new( 'msg' => "name is required" );
         my $record = $User->createRole($name, $args);
         return json($r, 200, { 'status' => '200', 'data' => $record });
      }

      if( $route =~ m!^/roles/([^/]+)/?$! && $r->request_method eq 'GET' ) {
         my $name = $1;
         my $record = $User->getRole($name);
         return json($r, 200, { 'status' => '200', 'data' => $record });
      }

      if( $route =~ m!^/roles/([^/]+)/update/?$! ) {
         my $name = $1;
         my $args = get_args($r, $querystring);
         my $record = $User->updateRole($name, $args);
         return json($r, 200, { 'status' => '200', 'data' => $record });
      }

      if( $route =~ m!^/roles/([^/]+)/remove/?$! ) {
         my $name = $1;
         my $result = $User->removeRole($name);
         return json($r, 200, { 'status' => '200', 'data' => $result });
      }

      ######################################
      # Profile management
      #

      if( $route =~ m!^/profiles/?$! ) {
         my $args = split_args($querystring);
         return json($r, 200, { 'status' => '200', 'data' => $User->listProfiles($args) });
      }

      if( $route =~ m!^/profiles/create/?$! ) {
         my $args = get_args($r, $querystring);
         my $id = $args->{'id'}
            or die Exception->new( 'msg' => "id is required" );
         my $record = $User->createProfile($id, $args);
         return json($r, 200, { 'status' => '200', 'data' => $record });
      }

      if( $route =~ m!^/profiles/([^/]+)/?$! && $r->request_method eq 'GET' ) {
         my $name = $1;
         my $args = split_args($querystring);
         return json($r, 200, { 'status' => '200', 'data' => $User->getProfile($name, $args) });
      }

      if( $route =~ m!^/profiles/([^/]+)/update/?$! ) {
         my $name = $1;
         my $args = get_args($r, $querystring);
         my $record = $User->updateProfile($name, $args);
         return json($r, 200, { 'status' => '200', 'data' => $record });
      }

      if( $route =~ m!^/profiles/([^/]+)/remove/?$! ) {
         my $name = $1;
         my $result = $User->removeProfile($name);
         return json($r, 200, { 'status' => '200', 'data' => $result });
      }

      if( $route =~ m!^/profiles/([^/]+)/rename/?$! ) {
         my $name = $1;
         my $args = get_args($r, $querystring);
         my $new_name = $args->{'new_name'}
            or die Exception->new( 'msg' => "new_name is required" );
         my $result = $User->renameProfile($name, $new_name, $args);
         return json($r, 200, { 'status' => '200', 'data' => $result });
      }

      ######################################
      # Load Reservations and container data
      #
      if( $route =~ m!^/getAuthCookies/?$! ) {

         my @cookies = $User->generate_auth_cookies($parentFQDN);
         my ($cookie) = map { s/;.*$//; $_ } grep { /Secure;$/ } @cookies;

         # Append on the globalCookie (if configured in config.json)
         if( $CONFIG->{'globalCookie'} && $CONFIG->{'globalCookie'}{'name'} && $CONFIG->{'globalCookie'}{'secret'} ) {
            $cookie .= sprintf("; %s=%s",
               $CONFIG->{'globalCookie'}{'name'},
               uri_escape($CONFIG->{'globalCookie'}{'secret'})
            );
         }

         return json($r, 200, { 'status' => '200', 'data' => $cookie });
      }

      # Default: redirect to /
      return redirect($r, 302, '/');
   }
   catch {
      my ($msg, $dbg, $time, $status);
      if( ref($_) eq 'Exception' ) {
         ($msg, $dbg, $time, $status) = ($_->msg(), $_->dbg(), $_->time(), $_->status());
      }
      else {
         ($msg, $dbg, $time) = ($_, $_, time);
      }

      # Most API errors carry no specific status and default to 401, preserving
      # existing behaviour; an Exception may set its own (e.g. 400 for a malformed
      # body, 403 for a forbidden self-edit).
      $status //= 401;

      # Sanitize regardless of source: an Exception's own msg/dbg can embed secrets
      # (env payloads, private keys, gh_token) from interpolated input or command
      # text, and both are surfaced -- $msg to the client, $dbg to the log.
      ($msg, $dbg) = map { sanitize_sensitive_text($_) } ($msg, $dbg);

      my $Time = YYYYMMDDHHMMSS($time);

      flog("Reporting exception at '$Time': msg='$msg'; dbg='$dbg'; status='$status'; content type='$type'");

      if($type eq 'text') {
         return text($r, $status, "$msg (at $Time)");
      }
      else {
         return json($r, $status, { 'status' => "$status", 'msg' => "$msg (at $Time)", 'time' => $time });
      }
   };

   return nginx::OK;
}

sub handler ($r, $protocol) {
   flog({ 'service' => 'dockside-handler' });

   my $R = try {
      Data::load();
      return _handler($r, $protocol);
   }
   catch {
      my ($msg, $dbg);
      if( ref($_) ) {
         ($msg, $dbg) = ($_->msg(), $_->dbg());
      }
      else {
         ($msg, $dbg) = ($_, $_);
      }
      # Sanitize regardless of source (see _handler's catch); $msg reaches the client.
      ($msg, $dbg) = map { sanitize_sensitive_text($_) } ($msg, $dbg);

      wlog( "Caught exception: dbg='$dbg'; msg='$msg'");
      flog("Caught exception: dbg='$dbg'; msg='$msg'");
      return html($r, 503, "<html><body><h1>Dockside</h1><p>Caught exception: $msg</p></body></html>");
   };

   return $R;
}

sub handlerHTTP ($r) { # nginx request object
   return handler($r, 'http');
}

sub handlerHTTPS ($r) { # nginx request object
   return handler($r, 'https');
}

1;
