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

# Names that cannot be used for a user or role because they collide with the
# REST route action words: a user named 'create' would be shadowed by the static
# /users/create route (and 'new' is the client's create-form route token).  Same
# set Profile::Manage reserves and the Vue client mirrors, kept identical across
# all three collections for consistency.
my %RESERVED_NAMES = map { $_ => 1 } qw(new create update remove rename);

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
# $orig_privates — name→scalar map of private key strings taken BEFORE
#                  apply_args_to_record.  A shallow hashref copy is NOT safe
#                  because apply_args_to_record mutates nested hashrefs in-place,
#                  aliasing through the copy and destroying the originals.
sub _restore_redacted_ssh ($record, $orig_privates) {
   my $kps = ( ( $record->{'ssh'} // {} )->{'keypairs'} // {} );
   for my $kp_name ( keys %$kps ) {
      my $kp = $kps->{$kp_name};
      next unless ref $kp eq 'HASH' && ( $kp->{'private'} // '' ) eq '<redacted>';
      if ( exists $orig_privates->{$kp_name} ) {
         $kp->{'private'} = $orig_privates->{$kp_name};
      } else {
         delete $kp->{'private'};
      }
   }
}

# Restore a gh_token that was masked for API output.
#
# _sanitise_user_record replaces gh_token with a first-4/last-4 masked form.
# If that masked value is POSTed back unchanged, writing it would destroy the
# real token.  Any value containing '*' is treated as a masked sentinel and
# replaced with the original (or deleted if none existed).
sub _restore_redacted_gh_token ($record, $orig_token) {
   if ( ( $record->{'gh_token'} // '' ) =~ /\*/ ) {
      defined($orig_token)
         ? ( $record->{'gh_token'} = $orig_token )
         : delete $record->{'gh_token'};
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

# Reject creating a user or role whose identifier is still referenced by an existing
# reservation: re-using a deleted identifier's name would silently grant the new
# identity that reservation's stale owner/viewers/developers access (privilege confusion
# on identifier reuse). The reservation-store scan and metadata knowledge live in
# Reservation::referencing_reservations; here we apply only the create-time reject
# policy. The converse invariant + locking (B1.5b) is a larger follow-on.
sub _reject_if_referenced_by_reservation ($identifier, $kind) {
   require Reservation;
   my @refs = Reservation->referencing_reservations( $identifier, $kind );
   return unless @refs;
   my $detail = join( ', ',
      map { ( $_->{'name'} // $_->{'id'} // '?' ) . ' (' . join( '/', @{ $_->{'fields'} } ) . ')' } @refs );
   die Exception->new(
      'status' => 409,
      'msg'    => "Cannot create $kind '$identifier': it is still referenced by "
                . "reservation(s) $detail — remove or reassign those references first "
                . "to avoid granting stale access.",
   );
}

sub createUser ($self, $args) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');

   my $username = $args->{'username'}
      or die Exception->new( 'msg' => "username is required" );
   die Exception->new( 'msg' => "Invalid username: use only letters, digits, hyphens, underscores" )
      unless $username =~ /^[A-Za-z0-9_-]+$/;
   # Reserve the route action words and 'new' (see %RESERVED_NAMES): such a name
   # would collide with a static /users/... route and be unreachable via the API.
   die Exception->new( 'msg' => "Username '$username' is reserved" )
      if $RESERVED_NAMES{$username};
   # Fast pre-check against the in-memory cache; the definitive check inside
   # cacheReadWrite holds the file lock and therefore eliminates the TOCTOU race.
   die Exception->new( 'msg' => "User '$username' already exists" )
      if $User::USERS->{$username};

   # Reject an explicitly-assigned role that does not exist: otherwise the user is
   # stored pointing at a non-existent role and silently resolves to no role-derived
   # permissions. (An omitted role falls back to the built-in default, so only validate
   # when one is supplied.)
   die Exception->new( 'msg' => "Role '$args->{'role'}' does not exist" )
      if defined $args->{'role'} && length $args->{'role'}
         && !$User::ROLES->{ $args->{'role'} };

   # Reject a username still referenced by a reservation's owner/viewers/developers:
   # re-using a deleted user's name would silently inherit those stale grants.
   _reject_if_referenced_by_reservation($username, 'user');

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
      # Reject non-object permissions/resources before they reach disk (see
      # _validate_record_objects); users get the same guard roles do.
      _validate_record_objects($new_user);

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

   # Reject reassigning the user to a role that does not exist (see createUser); only
   # validated when 'role' is part of this edit.
   die Exception->new( 'msg' => "Role '$args->{'role'}' does not exist" )
      if defined $args->{'role'} && length $args->{'role'}
         && !$User::ROLES->{ $args->{'role'} };

   my $record;
   cacheReadWrite( $USERS_FILE, sub ($oldData) {
      my $users = length( $oldData // '' ) ? Data::parse_json($oldData) : {};
      $record = $users->{$username}
         or die Exception->new( 'msg' => "User '$username' not found in users.json" );

      # Snapshot scalar values BEFORE apply_args_to_record.  A shallow hashref
      # copy aliases through to nested structures that apply_args_to_record
      # mutates in-place — snapshot scalars instead to avoid aliasing.
      my $kps = ( $record->{'ssh'} // {} )->{'keypairs'} // {};
      my $orig_privates = { map  { $_ => $kps->{$_}{'private'} }
                            grep { ref $kps->{$_} eq 'HASH' && exists $kps->{$_}{'private'} }
                            keys %$kps };
      my $orig_gh_token = $record->{'gh_token'};
      apply_args_to_record( $record, $args, qw(username password sensitive) );
      _restore_redacted_ssh( $record, $orig_privates );
      _restore_redacted_gh_token( $record, $orig_gh_token );
      # Reject non-object permissions/resources before they reach disk (see
      # _validate_record_objects); users get the same guard roles do.
      _validate_record_objects($record);

      # Prevent admin lock-out via self-demotion: a caller (who necessarily holds
      # manageUsers to reach here) must not strip their OWN manageUsers capability,
      # whether by changing role or via a permissions override/_unset.  Removal of
      # the last admin by deletion is already blocked by removeUser's self-deletion
      # guard, and since the caller is always an admin, self-demotion is the only
      # remaining path to zero admins.  Evaluate effective permissions on the
      # post-edit record (role-inherited or explicit '1' both count); dying here
      # aborts the cacheReadWrite write, so nothing is persisted.
      if ( $self->username eq $username ) {
         my $updated = User->new( { %$record, 'username' => $username } );
         die Exception->new(
            'msg'    => "You cannot remove your own 'manageUsers' permission; "
                      . "ask another administrator to make this change",
            'status' => 403,
         ) unless $updated && $updated->has_permission('manageUsers');
      }

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

   # Field deletions (_unset) are honoured too, but only for whitelisted personal
   # fields, so a self-service caller cannot delete protected fields (role,
   # permissions, id, ...) by listing them for removal.
   if ( ref $args->{'_unset'} eq 'ARRAY' ) {
      my @unset = grep { $allowed{ (split /\./, $_)[0] } } @{ $args->{'_unset'} };
      $safe_args->{'_unset'} = \@unset if @unset;
   }

   my $record;
   cacheReadWrite( $USERS_FILE, sub ($oldData) {
      my $users = length( $oldData // '' ) ? Data::parse_json($oldData) : {};
      $record = $users->{$username}
         or die Exception->new( 'msg' => "User '$username' not found in users.json" );

      my $kps = ( $record->{'ssh'} // {} )->{'keypairs'} // {};
      my $orig_privates = { map  { $_ => $kps->{$_}{'private'} }
                            grep { ref $kps->{$_} eq 'HASH' && exists $kps->{$_}{'private'} }
                            keys %$kps };
      my $orig_gh_token = $record->{'gh_token'};
      apply_args_to_record( $record, $safe_args );
      _restore_redacted_ssh( $record, $orig_privates );
      _restore_redacted_gh_token( $record, $orig_gh_token );

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
   # access and could leave no admin behind to recover.  403 (Forbidden), matching
   # the manageUsers self-demotion guards — the caller is authenticated, the action
   # is simply not allowed; without an explicit status it would default to 401 and
   # mislead clients into treating it as an expired session.
   die Exception->new( 'status' => 403, 'msg' => "Cannot remove your own account" )
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

# Validate a user or role record before persisting.  'permissions' and
# 'resources', when present, must be JSON objects (hashrefs).  A non-hash value —
# e.g. a JSON string that slipped through an un-decoded transport, or a malformed
# client payload — would be written to disk and then crash permission resolution
# on the next config reload: for roles updateDerivedPermissions does
# %{ $role->{permissions} }, and for users permission lookups dereference
# $user->record->{permissions}{$action}.  Either way it persistently breaks
# permission resolution, so reject it before it reaches disk.
sub _validate_record_objects ($record) {
   for my $field (qw(permissions resources)) {
      next unless exists $record->{$field};
      die Exception->new( 'msg' => "Field '$field' must be a JSON object" )
         unless ref $record->{$field} eq 'HASH';
   }
}

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
   # Reserve the route action words and 'new' (see %RESERVED_NAMES) — same reason
   # as users.
   die Exception->new( 'msg' => "Role name '$name' is reserved" )
      if $RESERVED_NAMES{$name};
   die Exception->new( 'msg' => "Role '$name' already exists" )
      if $User::ROLES->{$name};

   # Reject a role name still referenced by a reservation (as 'role:<name>'): re-using
   # a deleted role's name would silently inherit those stale grants.
   _reject_if_referenced_by_reservation($name, 'role');

   my $new_role;
   cacheReadWrite( $ROLES_FILE, sub ($oldData) {
      my $roles = length( $oldData // '' ) ? Data::parse_json($oldData) : {};

      die Exception->new( 'msg' => "Role '$name' already exists" )
         if $roles->{$name};

      $new_role = { 'permissions' => {}, 'resources' => {} };
      apply_args_to_record( $new_role, $args, qw(name) );
      _validate_record_objects($new_role);

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
      _validate_record_objects($record);

      # Prevent admin lock-out via self-demotion of one's OWN role (parallel to the
      # updateUser guard): a caller necessarily holds manageUsers to reach here, and
      # only editing their OWN role can drop their effective manageUsers to zero
      # (editing any other role leaves the caller's own role — and thus their
      # capability — untouched).  Evaluate the post-edit effective permission with the
      # REAL resolution machinery rather than re-implementing it: temporarily install
      # the new role record into the in-memory roles cache and construct a User from
      # the caller's own stored user record, so updateDerivedPermissions resolves
      # manageUsers against the NEW role (the $User::ROLES cache is otherwise stale
      # until Data::load runs after this write).  Dying here aborts the cacheReadWrite
      # write, so nothing is persisted.
      #
      # Skipped when:
      #  - the caller's role isn't the one being edited (no self-demotion possible);
      #  - the caller's role is literally 'admin' (updateDerivedPermissions grants all
      #    permissions to the 'admin' role-name regardless of its permissions hash, so
      #    a role edit can never strip it — checking would falsely reject);
      #  - the caller already holds a user-level manageUsers override of '1' (that
      #    override wins over the role, so they keep the capability regardless).
      if ( ( $self->{'role'} // '' ) eq $name
        && ( $self->{'role'} // '' ) ne 'admin'
        && ( ( $self->{'_permissions'} // {} )->{'manageUsers'} // '' ) ne '1' )
      {
         my $actor_record = _user_to_record( $User::USERS->{ $self->username } );
         local $User::ROLES->{$name} = $record;
         my $reresolved = User->new($actor_record);
         die Exception->new(
            'msg'    => "You cannot remove the 'manageUsers' permission from your "
                      . "own role; ask another administrator.",
            'status' => 403,
         ) unless $reresolved && $reresolved->has_permission('manageUsers');
      }

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
