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
use Data qw($CONFIG);
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
   my $data = shift;

   $r->status(200);
   $r->header_out( 'Cache-Control', 'no-store' );
   $r->send_http_header("application/json");

   $r->print( JSON::XS->new->utf8->convert_blessed->encode( $data ) );

   return nginx::OK;
}

sub text {
   my $r = shift;
   my $data = shift;

   $r->status(200);
   $r->header_out( 'Cache-Control', 'no-store' );
   $r->send_http_header("text/plain");

   $r->print( $data );

   return nginx::OK;
}

sub send_login_page {
   my $r = shift; # nginx request object

   $r->send_http_header("text/html");
   $r->print( get_asset('header.html') );
   $r->print( "<style>\n" . get_asset('signin.css') . "\n</style>\n" );
   $r->print("</head><body>\n");
   $r->print( get_asset('signin.html') );
   $r->print("</body></html>\n");
   return nginx::OK;
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
         $r->status(302);
         $r->header_out( 'Cache-Control', 'no-store' );
         $r->header_out( 'Location',      '/' );

         foreach my $cookie (@cookies) {
            $r->header_out( 'Set-Cookie', $cookie );
         }

         $r->send_http_header("text/plain");
         $r->print("Authenticating...\n");
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
   # and on which cookies can be assigned,
   # by stripping off leading characters up to the first '-' or '.'
   my $parentFQDN = $r->header_in('Host'); $parentFQDN =~ s!^[^\-\.]+!!;

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

   if( $route =~ m!^/ico/.*?\.svg$! ) {
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
      $r->print( get_asset('header.html') );
      $r->print( "<style>\n" . get_client_asset('main.css') . "\n</style>\n" );

      # Output permissions for signed-in user
      try {

         $r->print(
            sprintf( "<script>window.dockside = %s\n</script>",
                     JSON::XS->new->utf8->convert_blessed->encode(
                        {
                           # FIXME: set 'user' => $User, after simply either (a) changing User object definition to make 'permissions' the derivedPermissions; or (b) the Vue app to check user.derivedPermissions.
                           'user'    => { 'username' => $User->username, 'permissions' => { 'actions' => $User->permissions() } },
                           'profiles' => $User->profiles(),
                           'containers' => $User->reservations({'client' => 1}),
                           'viewers' => User->viewers(),
                           'dummyReservation' => $User->createClientReservation(),
                           'host' => $parentFQDN
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
      if( $route =~ m!^/createContainerReservation/(.*)$! ) {
         my $args = split_args($1); # Split querystring-style arguments

         # Use the current host's parentFQDN string to generate the child
         # container's hostname, if none has been provided.
         $args->{'parentFQDN'} ||= $parentFQDN;

         my $reservation = $User->createContainerReservation( $args );
         return json($r, { 'status' => $reservation ? '200' : '401', 'reservation' => $reservation });
      }

      ##########################
      # Update i.e. save an edit
      #
      if( $route =~ m!^/updateContainerReservation/(.*)$! ) {
         my $args = split_args($1); # Split querystring-style arguments

         my $reservation = $User->updateContainerReservation($args);
         return json($r, { 'status' => $reservation ? '200' : '401', 'reservation' => $reservation });
      }

      ###################
      # Start/Stop/Remove
      #
      if( $route =~ m!^/(stopContainer|startContainer|removeContainer)/(.*)$! ) {

         # Currently we ignore the return value. This is not ideal, but:
         # (a) until there is better support in the Vue app to display errors, there is no point in returning;
         # (b) it is not strictly necessary, the current state of the container will be updated in the Vue app
         #     and the success/failure of their request to change container state will ultimately be apparent.
         #     N.B. Some commands like 'docker start' can also return success, but then the container can fail
         #     to start anyway.

         $User->controlContainer($1, $2);

         return json($r, { 'status' => '200', 'data' => $User->reservations({'client' => 1}) });
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

         my $logs = $User->controlContainer('getContainerLogs', $id, $args);

         return ($args->{'format'} eq 'text') ? text($r, join('', @$logs)) : json($r, { 'status' => '200', 'data' => $logs });
      }

      ######################################
      # Load Reservations and container data
      #
      if( $route =~ m!^/containers/?$! ) {

         my $containers = $User->reservations({'client' => 1});
         return json($r, { 'status' => '200', 'data' => $containers });
      }

   }
   catch {
      my ($msg, $dbg) = ref($_) ? ($_->msg(), $_->dbg()) : ($_,$_);
      
      flog("Reporting exception: dbg='$dbg'; msg='$msg'; content type='$type'");

      if($type eq 'text') {
         text($r, "Error: $msg");
      }
      else {
         json($r, { 'status' => '401', 'msg' => $msg });
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

      $r->status(503);
      $r->print("<html><body><h1>Dockside</h1><p>Caught exception: $msg</p></body></html>");
      wlog( "Caught exception: dbg='$dbg'; msg='$msg'");
      flog("Caught exception: dbg='$dbg'; msg='$msg'");
      return nginx::OK;
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
