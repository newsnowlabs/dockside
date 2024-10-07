package Request;

use strict;

use JSON;
use Try::Tiny;
use URI::Escape;
use Data qw($CONFIG);
use Util qw(flog wlog TO_JSON encrypt_password validate_auth_cookie);
use User;

# Inputs:
# - $username
# - $password
#
# Returns:
# - a User object, if $username matches a users.json record and $password can be validated; OR
# - 'NOTFOUND'; OR
# - 'INVALID'

sub authenticate_by_credentials {
   my $class = shift; # User class
   my $username = shift;
   my $password = shift;

   my $user = User->new();
   
   # Check that $user is also named in the users.json file
   unless($user->load($username)) {
      return 'NOTFOUND';
   }

   my $passwordEntry = $user->password();

   # Extract salt and encryptedPasswd from password file.
   my ( $salt, $encryptedPasswd ) = $passwordEntry =~ /^(\$(?:1|2a|5|6)\$[^\$]+\$)(.*)$/s;

   # Check that $password is correct for $user in the password file.
   unless( $salt && $encryptedPasswd && encrypt_password( $password, $salt ) eq $passwordEntry ) {
      return 'INVALID';
   }

   return $user;
}

# Inputs:
# - Request cookie header
#
# Returns:
# - a User object containing authentication state, if authentication cookie(s) can be validated

sub authenticate {
   my $class = shift; # User class
   my $options = shift; # cookie: <value>; protocol: <http|https>

   my $cookie = $options->{'cookie'};

   my $user = User->new();

   # We represent authentication states that are independent of Reservation objects in the User object:
   # - public, globalCookie, and globalCookieRequired
   $user->authstate('public', 1);

   # Check if containerCookie is configured.
   if( $CONFIG->{'containerCookie'}{'name'} ) {

      # If so, extract the cookie value.
      my ($containerCookie) = $cookie =~ /\Q$CONFIG->{'containerCookie'}{'name'}\E=([^;]+)/;
      $user->authstate('containerCookie', uri_unescape($containerCookie));
   }
   else {
      wlog( "auth: containerCookie name not configured" );
   }

   # Check if globalCookie is configured.
   if( $CONFIG->{'globalCookie'} && $CONFIG->{'globalCookie'}{'name'} && $CONFIG->{'globalCookie'}{'secret'} ) {

      wlog( "auth: globalCookie name and secret configured" );

      # If it's configured, then a correct globalCookie value is required for user authentication to proceed.
      $user->authstate('globalCookieRequired', 1);

      # If correct globalCookie value is not found, then skip all subsequent authentication checks.
      if( $cookie !~ /\Q$CONFIG->{'globalCookie'}{'name'}\E=\Q$CONFIG->{'globalCookie'}{'secret'}\E/ ) {
         wlog( "auth: globalCookie cookie secret not found" );
         # Skip further processing; no access modes will be enabled (except public), if the globalCookie is configured and not present.
         return $user;
      }

      wlog( "auth: globalCookie cookie secret found" );
      $user->authstate('globalCookie', 1);
   }

   # Augment $user with authenticated user data, if:
   # - http(s) uid cookie exists
   # - cookie can be validated
   # - user exists
   if( my $uid = validate_auth_cookie( $options, $CONFIG->{'uidCookie'}{'name'}, $CONFIG->{'uidCookie'}{'salt'} ) ) {
      # Check that $user is named in users.json file (if it's not loaded, it's not named).
      # N.B. We NO LONGER check that the user has a password defined in the passwd file,
      # for consistency with normal expectations (of e.g. a unix user account).
      unless($user->load($uid->{'name'})) {
         wlog( "auth: user '$uid->{'name'}' not found in users.json file" );
      }
   }
   else {
      wlog( "auth: signature missing or invalid in uid cookie '$CONFIG->{'uidCookie'}{'name'}" . 
      (($options->{'protocol'} eq 'https') ? '' : "_http") .
      "'"
      );
   }

   return $user;
}

1;
