package App;

use strict;

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
use Util qw(flog wlog run run_pty);
use Data qw($CONFIG $VERSION);
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

sub get_asset {
   my $filename = shift;

   return undef if /\.\./;
   open( my $FH, '<', "$CONFIG->{'assetsPath'}/$filename" ) || return undef;

   local $/;
   my $contents = <$FH>;
   close $FH;
   return $contents;
}

sub get_client_asset {
   my $filename = shift;

   return undef if /\.\./;
   open( my $FH, '<', "$CONFIG->{'clientDistPath'}/$filename" ) || return undef;

   local $/;
   my $contents = <$FH>;
   close $FH;
   return $contents;
}

sub get_header {
   my $title = shift;

   return get_asset('header.html') . 
      "   <title>" . ($title // 'Dockside - A dev and staging environment in one - From NewsNow Labs') . "</title>\n" .
      get_asset('gtm.html');
}

####################################################################################################

sub log_status {
   my $sub = shift;
   my $json = shift;

   flog("$sub: " . $json->{'msg'});

   return $json;
}

####################################################################################################
#
# Router logic: the main application entry point.
#

sub split_args {
   my $queryString = shift;

   # Split querystring-style arguments, and unescape them
   my %hash = map { uri_unescape($_) } split( /[=&]/, $queryString );

   # Map once more to eliminate any hash key mapping to undef
   return { map { $_ // '' } %hash };
}

sub json {
   my $r = shift;
   my $code = shift;
   my $data = shift;

   $r->status($code);
   $r->header_out( 'Cache-Control', 'no-store' );
   $r->send_http_header("application/json");

   $r->print( JSON::XS->new->utf8->convert_blessed->encode( $data ) );

   return nginx::OK;
}

sub redirect {
   my $r = shift;
   my $code = shift;
   my $location = shift;
   my $headers = shift;

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

sub html {
   my $r = shift;
   my $code = shift;
   my $data = shift;

   $r->status($code);
   $r->header_out( 'Cache-Control', 'no-store' );
   $r->send_http_header("text/html");

   $r->print( $data );

   return nginx::OK;
}

sub text {
   my $r = shift;
   my $code = shift;
   my $data = shift;

   $r->status($code);
   $r->header_out( 'Cache-Control', 'no-store' );
   $r->send_http_header("text/plain");

   $r->print( $data );

   return nginx::OK;
}

sub send_branded_page {
   my $r = shift; # nginx request object
   my $code = shift;
   my $class = shift;
   my $html = shift;

   $r->status($code);
   $r->send_http_header("text/html");
   $r->print( get_header() );
   $r->print( "<style>\n" . get_asset('signin.css') . "\n</style>\n" );
   $r->print("</head><body>\n");
   $r->print('<link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/css/bootstrap.min.css" integrity="sha384-BVYiiSIFeK1dGmJRAkycuHAHRg32OmUcww7on3RYdg4Va+PmSTsz/K68vbdEjh4u" crossorigin="anonymous">');
   $r->print('<div class="container"><div class="branded ' . $class . '"><div class="dockside"></div>' . $html . "</div></div>\n</body></html>\n");
   return nginx::OK;
}

sub send_login_page {
   my $r = shift; # nginx request object

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

sub handle_login_form {
   my $r = shift; # nginx request object
   my $parentFQDN = shift; # copy of $parentFQDN

   # Extract credentials from body.
   # Unescape keys and values, for consistency and simplicity.
   my %credentials = map { uri_unescape($_) } split(/[&=]/, $r->request_body);

   try {

      if( my $User = Request->authenticate_by_credentials( $credentials{'username'}, $credentials{'password'} ) ) {
         my @cookies = $User->generate_auth_cookies($parentFQDN);

         # On successful login, redirect with 302 to current URI
         redirect($r, 302, $r->uri, [
            map { ['Set-Cookie', $_] } @cookies
         ]);
         return 1;
      }
      else {
         flog("auth_cookie: credentials not valid");
         return 0;
      }
   }
   catch {
      flog("auth_cookie: caught exception: '$_'");
      return 0;
   }

   # Fallthrough: try return code will be returned here.
}

sub _handler {
   my $r = shift; # nginx request object
   my $protocol = shift; # protocol = 'http' | 'https'

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
      if( $r->has_request_body(
            sub {
               return handle_login_form($_[0], $parentFQDN) || send_login_page($r);
            }
         )) {
         return nginx::OK;
      }

      return nginx::HTTP_BAD_REQUEST;
   }

   # User is signed in.
   flog("App: route=$route; User=" . $User->username);

   if( $route eq '/' || $route =~ m!^/container/! ) {
      ###############################
      # Display main page HTML
      #
      $r->send_http_header("text/html");
      $r->print( get_header() );
      $r->print( "<style>\n" . get_client_asset('main.css') . "\n</style>\n" );

      # Output permissions for signed-in user
      try {

         $r->print(
            sprintf( "<script>window.dockside = %s\n</script>",
                     JSON::XS->new->utf8->convert_blessed->encode(
                        {
                           # FIXME: set 'user' => $User, after simply either (a) changing User object definition to make 'permissions' the derivedPermissions; or (b) the Vue app to check user.derivedPermissions.
                           'user'    => {
                              'username' => $User->username,
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
      $r->print( "<script>\n" . get_client_asset('main.js') . "</script>\n" );
      $r->print("</body></html>\n");

      return nginx::OK;
   }

   ###############################
   # AJAX SERVICES
   #

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
      my ($msg, $dbg, $time) = ref($_) eq 'Exception' ? ($_->msg(), $_->dbg(), $_->time()) : ($_, $_, time);

      flog("Reporting exception at '$time': msg='$msg'; dbg='$dbg'; content type='$type'");

      if($type eq 'text') {
         return text($r, 401, "$msg at $time");
      }
      else {
         return json($r, 401, { 'status' => '401', 'msg' => "$msg at $time", 'time' => $time });
      }
   };

   return nginx::OK;
}

sub handler {
   my $r = shift;
   my $protocol = shift;

   flog({ 'service' => 'dockside-handler' });

   my $R = try {
      Data::load();
      return _handler($r, $protocol);
   }
   catch {
      my ($msg, $dbg) = ref($_) ? ($_->msg(), $_->dbg()) : ($_,$_);

      wlog( "Caught exception: dbg='$dbg'; msg='$msg'");
      flog("Caught exception: dbg='$dbg'; msg='$msg'");
      return html($r, 503, "<html><body><h1>Dockside</h1><p>Caught exception: $msg</p></body></html>");
   };

   return $R;
}

sub handlerHTTP {
   my $r = shift; # nginx request object

   return handler($r, 'http');
}

sub handlerHTTPS {
   my $r = shift; # nginx request object

   return handler($r, 'https');
}

1;
