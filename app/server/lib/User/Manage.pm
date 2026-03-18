# Sub-package providing user and role management (CRUD) to User::.
package User::Manage;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw(
   listUsers getUser createUser updateUser removeUser
   listRoles getRole createRole updateRole removeRole
);

use JSON;
use Data;
use Util qw(encrypt_password cacheReadWrite);
use Exception;

my $CONFIG_PATH = '/data/config';

################################################################################
# PRIVATE HELPERS

# Parse raw passwd file text into a hash of username => encrypted_password.
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

# Attempt JSON decode of a value; fall back to the raw string.
sub _decode_value ($val) {
   return $val unless defined $val && length $val;
   my $decoded = eval { decode_json($val) };
   return $@ ? $val : $decoded;
}

# Apply flat args (possibly dotted-path keys, possibly JSON-encoded values) into
# a record hashref in place. Shallower keys are applied first so deeper paths can
# override them. Keys listed in @skip are ignored.
sub _apply_args_to_record ($record, $args, @skip) {
   my %skip = map { $_ => 1 } @skip;

   for my $key ( sort { scalar( split /\./, $a ) <=> scalar( split /\./, $b ) } keys %$args ) {
      next if $skip{$key};
      next unless defined $args->{$key};

      my $val   = _decode_value( $args->{$key} );
      my @parts = split( /\./, $key );
      my $ref   = $record;
      for my $part ( @parts[ 0 .. $#parts - 1 ] ) {
         $ref->{$part} //= {};
         $ref = $ref->{$part};
      }
      $ref->{ $parts[-1] } = $val;
   }
}

# Convert a loaded User object back to its canonical users.json record form.
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

# Sanitise a user record for API output: strip sensitive fields unless requested.
sub _sanitise_user_record ($record, $sensitive = 0) {
   my $out = {%$record};
   unless ($sensitive) {
      delete $out->{'gh_token'};
      if ( ref $out->{'ssh'} eq 'HASH' && ref $out->{'ssh'}{'keypairs'} eq 'HASH' ) {
         $out->{'ssh'}             = { %{ $out->{'ssh'} } };
         $out->{'ssh'}{'keypairs'} = { %{ $out->{'ssh'}{'keypairs'} } };
         for my $kp_name ( keys %{ $out->{'ssh'}{'keypairs'} } ) {
            my $kp = $out->{'ssh'}{'keypairs'}{$kp_name};
            if ( ref $kp eq 'HASH' ) {
               $out->{'ssh'}{'keypairs'}{$kp_name} = {%$kp};
               delete $out->{'ssh'}{'keypairs'}{$kp_name}{'private'};
            }
         }
      }
   }
   return $out;
}

################################################################################
# USER CRUD

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

sub createUser ($self, $args) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');

   my $username = $args->{'username'}
      or die Exception->new( 'msg' => "username is required" );
   die Exception->new( 'msg' => "Invalid username: use only letters, digits, hyphens, underscores" )
      unless $username =~ /^[A-Za-z0-9_-]+$/;
   die Exception->new( 'msg' => "User '$username' already exists" )
      if $User::USERS->{$username};

   my $new_user;
   cacheReadWrite( "$CONFIG_PATH/users.json", sub ($oldData) {
      my $users = length( $oldData // '' ) ? Data::parse_json($oldData) : {};

      die Exception->new( 'msg' => "User '$username' already exists" )
         if $users->{$username};

      # Auto-assign id if not provided or non-numeric.
      my $id = $args->{'id'};
      unless ( defined $id && $id =~ /^\d+$/ ) {
         my $max_id = 0;
         for my $u ( values %$users ) {
            $max_id = $u->{'id'} if ( $u->{'id'} // 0 ) > $max_id;
         }
         $id = $max_id + 1;
      }

      $new_user = {
         'id'          => $id + 0,
         'email'       => '',
         'name'        => '',
         'role'        => 'user',
         'permissions' => {},
         'resources'   => {},
         'version'     => User::CURRENT_VERSION(),
      };

      _apply_args_to_record( $new_user, $args, qw(username password sensitive id) );

      $users->{$username} = $new_user;
      return JSON->new->utf8->pretty->canonical->encode($users);
   } );

   my @reload = ('users.json');
   if ( defined $args->{'password'} && length $args->{'password'} ) {
      cacheReadWrite( "$CONFIG_PATH/passwd", sub ($oldData) {
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
   cacheReadWrite( "$CONFIG_PATH/users.json", sub ($oldData) {
      my $users = length( $oldData // '' ) ? Data::parse_json($oldData) : {};
      $record = $users->{$username}
         or die Exception->new( 'msg' => "User '$username' not found in users.json" );

      _apply_args_to_record( $record, $args, qw(username password sensitive) );

      $users->{$username} = $record;
      return JSON->new->utf8->pretty->canonical->encode($users);
   } );

   my @reload = ('users.json');
   if ( defined $args->{'password'} && length $args->{'password'} ) {
      cacheReadWrite( "$CONFIG_PATH/passwd", sub ($oldData) {
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

sub removeUser ($self, $username, $args = {}) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "User '$username' not found" )
      unless $User::USERS->{$username};
   die Exception->new( 'msg' => "Cannot remove your own account" )
      if $self->username eq $username;

   cacheReadWrite( "$CONFIG_PATH/users.json", sub ($oldData) {
      my $users = length( $oldData // '' ) ? Data::parse_json($oldData) : {};
      exists $users->{$username}
         or die Exception->new( 'msg' => "User '$username' not found in users.json" );
      delete $users->{$username};
      return JSON->new->utf8->pretty->canonical->encode($users);
   } );

   my $passwd_changed = 0;
   cacheReadWrite( "$CONFIG_PATH/passwd", sub ($oldData) {
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
   die Exception->new( 'msg' => "Role '$name' already exists" )
      if $User::ROLES->{$name};

   my $new_role;
   cacheReadWrite( "$CONFIG_PATH/roles.json", sub ($oldData) {
      my $roles = length( $oldData // '' ) ? Data::parse_json($oldData) : {};

      die Exception->new( 'msg' => "Role '$name' already exists" )
         if $roles->{$name};

      $new_role = { 'permissions' => {}, 'resources' => {} };
      _apply_args_to_record( $new_role, $args, qw(name) );

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
   cacheReadWrite( "$CONFIG_PATH/roles.json", sub ($oldData) {
      my $roles = length( $oldData // '' ) ? Data::parse_json($oldData) : {};
      $record = $roles->{$name}
         or die Exception->new( 'msg' => "Role '$name' not found in roles.json" );

      _apply_args_to_record( $record, $args, qw(name) );

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

   my @users_with_role = grep { ( $User::USERS->{$_}{'role'} // '' ) eq $name } keys %$User::USERS;
   die Exception->new(
      'msg' => "Cannot remove role '$name': still assigned to: " . join( ', ', sort @users_with_role ) )
      if @users_with_role;

   cacheReadWrite( "$CONFIG_PATH/roles.json", sub ($oldData) {
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
