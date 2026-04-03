# Sub-package providing user and role management (CRUD) to User::.
# Storage paths are imported from Data.pm ($USERS_FILE, $ROLES_FILE, $PASSWD_FILE)
# so Data.pm is the single source of truth for all config file locations.
package User::Manage;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw(
   listUsers getUser getSelf createUser updateUser updateSelf removeUser
   listRoles getRole createRole updateRole removeRole
);

use JSON;
use Data qw($USERS_FILE $ROLES_FILE $PASSWD_FILE);
use Util qw(encrypt_password cacheReadWrite apply_args_to_record);
use Exception;

################################################################################
# PRIVATE HELPERS

# Parse the raw text content of the passwd file (colon-separated username:hash
# lines, with blank lines and #-comments ignored) into a plain hash of
# username => encrypted_password.  Returns an empty hash for empty/undef input.
sub _parse_passwd_text ($text) {
   my %passwd;
   for my $line ( split( /\n/, $text // '' ) ) {
      $line =~ s/^\s*|\s*$//g;
      next if $line =~ /^(#.*)?$/;
      my ( $user, $hash ) = split( /:/, $line, 2 );
      $passwd{$user} = $hash if defined $user && defined $hash;
   }
   return %passwd;
}


# Convert a loaded User object (a blessed hashref with derived/computed fields)
# back to the flat record shape stored in users.json.  The _permissions and
# _resources private fields hold overrides only (not role-inherited values);
# the caller receives them under the public 'permissions' / 'resources' keys.
sub _user_to_record ($user) {
   return {
      'username'    => $user->username,
      'id'          => $user->{'id'},
      'email'       => $user->{'email'},
      'name'        => $user->{'name'},
      'role'        => $user->{'role'},
      'version'     => $user->{'version'},
      'permissions' => $user->{'_permissions'} // {},
      'resources'   => $user->{'_resources'}   // {},
      'ssh'         => $user->{'ssh'},
      'gh_token'    => $user->{'gh_token'},
   };
}

# Restore SSH keypair private keys that were redacted for API output.
#
# _sanitise_user_record replaces each private key with the literal sentinel
# '<redacted>' before sending it to the client.  When the client POSTs the
# record back the sentinel arrives unchanged; if we wrote it to disk, the real
# private key would be destroyed.  This sub replaces '<redacted>' with the
# original key material (or deletes the private field if none was stored).
#
# $orig_keypairs — shallow copy of record->ssh->keypairs taken BEFORE
#                  apply_args_to_record, so the live record can be mutated
#                  in place without losing the originals.
sub _restore_redacted_ssh ($record, $orig_keypairs) {
   my $kps = ( ( $record->{'ssh'} // {} )->{'keypairs'} // {} );
   for my $kp_name ( keys %$kps ) {
      my $kp = $kps->{$kp_name};
      next unless ref $kp eq 'HASH' && ( $kp->{'private'} // '' ) eq '<redacted>';
      if ( exists $orig_keypairs->{$kp_name} && exists $orig_keypairs->{$kp_name}{'private'} ) {
         $kp->{'private'} = $orig_keypairs->{$kp_name}{'private'};
      } else {
         delete $kp->{'private'};
      }
   }
}

# Sanitise a user record for API output.
# When $sensitive is false (default), two classes of data are redacted:
#   gh_token   — masked to first-4/last-4 visible characters to confirm
#                it is set without exposing the token value.
#   ssh.keypairs.*.private — replaced with the sentinel '<redacted>' so the
#                client knows a key exists, and _restore_redacted_ssh can
#                recover it if the same record is POSTed back unchanged.
# When $sensitive is true (e.g. for internal reloads), the record is returned
# as a shallow copy with no masking.
# Always returns a new hashref; the original $record is not modified.
sub _sanitise_user_record ($record, $sensitive = 0) {
   my $out = {%$record};
   unless ($sensitive) {
      if ( exists $out->{'gh_token'} && defined $out->{'gh_token'} ) {
         my $t = $out->{'gh_token'};
         $out->{'gh_token'} = length($t) > 8
            ? substr( $t, 0, 4 ) . ( '*' x ( length($t) - 8 ) ) . substr( $t, -4 )
            : '*' x length($t);
      }
      if ( ref $out->{'ssh'} eq 'HASH' && ref $out->{'ssh'}{'keypairs'} eq 'HASH' ) {
         $out->{'ssh'}             = { %{ $out->{'ssh'} } };
         $out->{'ssh'}{'keypairs'} = { %{ $out->{'ssh'}{'keypairs'} } };
         for my $kp_name ( keys %{ $out->{'ssh'}{'keypairs'} } ) {
            my $kp = $out->{'ssh'}{'keypairs'}{$kp_name};
            if ( ref $kp eq 'HASH' && exists $kp->{'private'} ) {
               $out->{'ssh'}{'keypairs'}{$kp_name} = {%$kp};
               $out->{'ssh'}{'keypairs'}{$kp_name}{'private'} = '<redacted>';
            }
         }
      }
   }
   return $out;
}

################################################################################
# USER CRUD
# All mutating subs follow the same pattern:
#   1. Permission and pre-condition checks (die on failure).
#   2. cacheReadWrite — exclusive-lock, read, modify, write the JSON file.
#   3. Optionally cacheReadWrite the passwd file for password changes.
#   4. Data::load to reload the in-memory $User::USERS / $User::ROLES caches.
#   5. Return a sanitised record.

sub listUsers ($self, $args = {}) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');

   my $sensitive = $args->{'sensitive'} ? 1 : 0;
   return [ map { _sanitise_user_record( _user_to_record( $User::USERS->{$_} ), $sensitive ) }
            sort keys %$User::USERS ];
}

sub getUser ($self, $username, $args = {}) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "User '$username' not found" )
      unless $User::USERS->{$username};

   my $sensitive = $args->{'sensitive'} ? 1 : 0;
   return _sanitise_user_record( _user_to_record( $User::USERS->{$username} ), $sensitive );
}

# Self-service read: any authenticated user may read their own record.
# Returns the bootstrap-equivalent format used for window.dockside.user:
# derived (role-inherited + user-override) permissions.actions, role_as_meta,
# and masked sensitive fields.  No manageUsers permission is required.
sub getSelf ($self, $args = {}) {
   my $username = $self->username;
   die Exception->new( 'msg' => "Not authenticated" ) unless $username;
   my $user = $User::USERS->{$username};
   die Exception->new( 'msg' => "User '$username' not found" ) unless $user;

   my $record = _sanitise_user_record( _user_to_record( $user ) );
   $record->{'role_as_meta'} = $user->role_as_meta;
   $record->{'permissions'}  = { 'actions' => $user->permissions() };
   return $record;
}

sub createUser ($self, $args) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');

   my $username = $args->{'username'}
      or die Exception->new( 'msg' => "username is required" );
   die Exception->new( 'msg' => "Invalid username: use only letters, digits, hyphens, underscores" )
      unless $username =~ /^[A-Za-z0-9_-]+$/;
   # 'new' is reserved because it is used as a route token (GET /users/new);
   # without this check a user named 'new' would be unreachable via the API.
   die Exception->new( 'msg' => "Username '$username' is reserved" )
      if $username eq 'new';
   # Fast pre-check against the in-memory cache; the definitive check inside
   # cacheReadWrite holds the file lock and therefore eliminates the TOCTOU race.
   die Exception->new( 'msg' => "User '$username' already exists" )
      if $User::USERS->{$username};

   my $new_user;
   cacheReadWrite( $USERS_FILE, sub ($oldData) {
      my $users = length( $oldData // '' ) ? Data::parse_json($oldData) : {};

      # Definitive duplicate check under the exclusive file lock.
      die Exception->new( 'msg' => "User '$username' already exists" )
         if $users->{$username};

      # Auto-assign a numeric id if not provided or non-numeric: scan existing
      # users for the highest id and increment.  Numeric ids are used to map
      # Dockside users to POSIX UIDs inside containers.
      my $id = $args->{'id'};
      unless ( defined $id && $id =~ /^\d+$/ ) {
         my $max_id = 0;
         for my $u ( values %$users ) {
            $max_id = $u->{'id'} if ( $u->{'id'} // 0 ) > $max_id;
         }
         $id = $max_id + 1;
      }

      $new_user = {
         'id'          => $id + 0,    # +0 coerces to numeric for JSON encoding
         'email'       => '',
         'name'        => '',
         'role'        => 'user',
         'permissions' => {},
         'resources'   => {},
         'version'     => User::CURRENT_VERSION(),
      };

      # Overlay caller-supplied args onto defaults.  'username' is stored as the
      # hash key, not in the record body; 'password' is written to the separate
      # passwd file; 'sensitive' and 'id' are control params, not record fields.
      apply_args_to_record( $new_user, $args, qw(username password sensitive id) );

      $users->{$username} = $new_user;
      return JSON->new->utf8->pretty->canonical->encode($users);
   } );

   # Reload users.json; if a password was also written, reload passwd first so
   # auth is consistent with the new user record.
   my @reload = ('users.json');
   if ( defined $args->{'password'} && length $args->{'password'} ) {
      cacheReadWrite( $PASSWD_FILE, sub ($oldData) {
         my %passwd = _parse_passwd_text($oldData);
         $passwd{$username} = encrypt_password( $args->{'password'} );
         return join( '', map { "$_:$passwd{$_}\n" } sort keys %passwd );
      } );
      unshift @reload, 'passwd';
   }
   Data::load(@reload);

   return _sanitise_user_record( { %$new_user, 'username' => $username },
      $args->{'sensitive'} ? 1 : 0 );
}

sub updateUser ($self, $username, $args) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "User '$username' not found" )
      unless $User::USERS->{$username};

   my $record;
   cacheReadWrite( $USERS_FILE, sub ($oldData) {
      my $users = length( $oldData // '' ) ? Data::parse_json($oldData) : {};
      $record = $users->{$username}
         or die Exception->new( 'msg' => "User '$username' not found in users.json" );

      # Snapshot keypairs BEFORE apply_args_to_record so _restore_redacted_ssh
      # can recover original private key material from the pre-update record.
      my $orig_kps = { %{ ( $record->{'ssh'} // {} )->{'keypairs'} // {} } };
      apply_args_to_record( $record, $args, qw(username password sensitive) );
      _restore_redacted_ssh( $record, $orig_kps );

      $users->{$username} = $record;
      return JSON->new->utf8->pretty->canonical->encode($users);
   } );

   my @reload = ('users.json');
   if ( defined $args->{'password'} && length $args->{'password'} ) {
      cacheReadWrite( $PASSWD_FILE, sub ($oldData) {
         my %passwd = _parse_passwd_text($oldData);
         $passwd{$username} = encrypt_password( $args->{'password'} );
         return join( '', map { "$_:$passwd{$_}\n" } sort keys %passwd );
      } );
      unshift @reload, 'passwd';
   }
   Data::load(@reload);

   return _sanitise_user_record( { %$record, 'username' => $username },
      $args->{'sensitive'} ? 1 : 0 );
}

# Self-service update: any authenticated user may update their own name, email,
# gh_token, and ssh fields.  All other fields in $args are silently discarded,
# preventing privilege escalation (no manageUsers permission required).
sub updateSelf ($self, $args) {
   my $username = $self->username;
   die Exception->new( 'msg' => "Not authenticated" ) unless $username;
   die Exception->new( 'msg' => "User '$username' not found" )
      unless $User::USERS->{$username};

   # Build a whitelist-filtered copy of $args containing only the personal fields
   # a user is allowed to self-edit.  Flat keys (e.g. 'name') are included
   # directly; dotted-path keys are included if their top-level segment is in the
   # whitelist (e.g. 'ssh.keypairs.mykey' is allowed because 'ssh' is allowed).
   my %allowed = map { $_ => 1 } qw(name email gh_token ssh);
   my $safe_args = { map { $_ => $args->{$_} } grep { $allowed{$_} } keys %$args };

   # Also allow dotted-path variants such as ssh.publicKeys, ssh.keypairs.*
   for my $key ( keys %$args ) {
      my ($top) = split /\./, $key;
      $safe_args->{$key} = $args->{$key} if $allowed{$top};
   }

   my $record;
   cacheReadWrite( $USERS_FILE, sub ($oldData) {
      my $users = length( $oldData // '' ) ? Data::parse_json($oldData) : {};
      $record = $users->{$username}
         or die Exception->new( 'msg' => "User '$username' not found in users.json" );

      my $orig_kps = { %{ ( $record->{'ssh'} // {} )->{'keypairs'} // {} } };
      apply_args_to_record( $record, $safe_args );
      _restore_redacted_ssh( $record, $orig_kps );

      $users->{$username} = $record;
      return JSON->new->utf8->pretty->canonical->encode($users);
   } );

   Data::load('users.json');

   return _sanitise_user_record( { %$record, 'username' => $username } );
}

sub removeUser ($self, $username, $args = {}) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "User '$username' not found" )
      unless $User::USERS->{$username};
   # Prevent self-deletion: an admin who deletes their own account would lose
   # access and could leave no admin behind to recover.
   die Exception->new( 'msg' => "Cannot remove your own account" )
      if $self->username eq $username;

   cacheReadWrite( $USERS_FILE, sub ($oldData) {
      my $users = length( $oldData // '' ) ? Data::parse_json($oldData) : {};
      exists $users->{$username}
         or die Exception->new( 'msg' => "User '$username' not found in users.json" );
      delete $users->{$username};
      return JSON->new->utf8->pretty->canonical->encode($users);
   } );

   # Remove the password entry if one exists.  We always attempt the passwd
   # update but only reload it if it actually changed, to avoid an unnecessary
   # Data::load of a file we didn't modify.
   my $passwd_changed = 0;
   cacheReadWrite( $PASSWD_FILE, sub ($oldData) {
      my %passwd = _parse_passwd_text($oldData);
      return $oldData unless exists $passwd{$username};
      delete $passwd{$username};
      $passwd_changed = 1;
      return join( '', map { "$_:$passwd{$_}\n" } sort keys %passwd );
   } );
   Data::load( $passwd_changed ? ( 'passwd', 'users.json' ) : 'users.json' );

   return { 'username' => $username };
}

################################################################################
# ROLE CRUD
# Roles define the default permissions and resources for all users assigned to
# them.  After any role mutation, both roles.json AND users.json are reloaded
# because user permission resolution depends on the current role definitions.

sub listRoles ($self) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');

   return [ map { { 'name' => $_, %{ $User::ROLES->{$_} } } } sort keys %$User::ROLES ];
}

sub getRole ($self, $name) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "Role '$name' not found" )
      unless $User::ROLES->{$name};

   return { 'name' => $name, %{ $User::ROLES->{$name} } };
}

sub createRole ($self, $name, $args) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "Invalid role name: use only letters, digits, hyphens, underscores" )
      unless $name =~ /^[A-Za-z0-9_-]+$/;
   # 'new' is reserved as a route token (GET /roles/new) — same reason as users.
   die Exception->new( 'msg' => "Role name '$name' is reserved" )
      if $name eq 'new';
   die Exception->new( 'msg' => "Role '$name' already exists" )
      if $User::ROLES->{$name};

   my $new_role;
   cacheReadWrite( $ROLES_FILE, sub ($oldData) {
      my $roles = length( $oldData // '' ) ? Data::parse_json($oldData) : {};

      die Exception->new( 'msg' => "Role '$name' already exists" )
         if $roles->{$name};

      $new_role = { 'permissions' => {}, 'resources' => {} };
      apply_args_to_record( $new_role, $args, qw(name) );

      $roles->{$name} = $new_role;
      return JSON->new->utf8->pretty->canonical->encode($roles);
   } );
   Data::load( 'roles.json', 'users.json' );

   return { 'name' => $name, %$new_role };
}

sub updateRole ($self, $name, $args) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "Role '$name' not found" )
      unless $User::ROLES->{$name};

   my $record;
   cacheReadWrite( $ROLES_FILE, sub ($oldData) {
      my $roles = length( $oldData // '' ) ? Data::parse_json($oldData) : {};
      $record = $roles->{$name}
         or die Exception->new( 'msg' => "Role '$name' not found in roles.json" );

      apply_args_to_record( $record, $args, qw(name) );

      $roles->{$name} = $record;
      return JSON->new->utf8->pretty->canonical->encode($roles);
   } );
   Data::load( 'roles.json', 'users.json' );

   return { 'name' => $name, %$record };
}

sub removeRole ($self, $name) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "Role '$name' not found" )
      unless $User::ROLES->{$name};

   # Refuse deletion if any user is currently assigned this role; deleting it
   # would leave those users with a dangling role reference and undefined permissions.
   my @users_with_role = grep { ( $User::USERS->{$_}{'role'} // '' ) eq $name } keys %$User::USERS;
   die Exception->new(
      'msg' => "Cannot remove role '$name': still assigned to: " . join( ', ', sort @users_with_role ) )
      if @users_with_role;

   cacheReadWrite( $ROLES_FILE, sub ($oldData) {
      my $roles = length( $oldData // '' ) ? Data::parse_json($oldData) : {};
      exists $roles->{$name}
         or die Exception->new( 'msg' => "Role '$name' not found in roles.json" );
      delete $roles->{$name};
      return JSON->new->utf8->pretty->canonical->encode($roles);
   } );
   Data::load( 'roles.json', 'users.json' );

   return { 'name' => $name };
}

1;
