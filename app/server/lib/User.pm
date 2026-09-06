package User;

use v5.36;

use JSON;
use Try::Tiny;
use URI::Escape;
use Storable qw(dclone);
use Data qw($CONFIG);
use Util qw(flog wlog TO_JSON generate_auth_cookie_values encrypt_password cacheReadWrite);
use User::Manage qw(
   listUsers getUser getSelf createUser updateUser updateSelf removeUser
   listRoles getRole createRole updateRole removeRole
);
use Profile::Manage qw(
   listProfiles getProfile createProfile updateProfile removeProfile renameProfile
);
use Reservation;

################################################################################
# CURRENT VERSION
# ---------------

sub CURRENT_VERSION () {
   return 2;
}

##################
# VERSION UPGRADES
# ----------------

sub versionUpgrade ($self) {
   if($self->version == 0) {
      $self->{'_resources'}{'IDEs'} //= ['*'];
      $self->{'version'}++;
   }
   if($self->version == 1) {
      # Migrate ssh.authorized_keys (array) → ssh.publicKeys (hash)
      my $old = $self->{'ssh'}{'authorized_keys'};
      if(ref($old) eq 'ARRAY' && @$old) {
         my $i = 1;
         for my $key (@$old) {
            $self->{'ssh'}{'publicKeys'}{"key$i"} = $key;
            $i++;
         }
      }
      delete $self->{'ssh'}{'authorized_keys'};
      $self->{'version'}++;
   }
}

################################################################################
# CONFIGURE PACKAGE GLOBALS
# -------------------------

my @GENERAL_PERMISSIONS = (
   'createContainerReservation', # Permission to launch a container reservation
   'viewAllContainers', # Permission to view all containers (except ones marked private)
   'viewAllPrivateContainers', # Permission to view all containers including private containers
   'developContainers', # Permission to develop containers that one owns or is a named developer on
   'developAllContainers', # Permission to develop all containers irrespective of ownership or named developers
   'manageUsers',    # Permission to create/update/remove/list users and roles
   'manageProfiles'  # Permission to create/update/remove/rename/list profiles
);

my @CONTAINER_PERMISSIONS = (
   'setContainerViewers', # Permission to edit the list of viewers for containers
   'setContainerDevelopers', # Permission to edit the list of developers for containers
   'setContainerPrivacy', # Permission to edit the private flag of containers
   'startContainer', # Permission to start a container
   'stopContainer', # Permission to stop a container
   'removeContainer', # Permission to remove a container
   'getContainerLogs', # Permission to retrieve container logs
   'runContainerHooks', # Permission to run a container's profile-declared lifecycle hook
   'addContainerRouter', # Permission to add a router to a live reservation (profile must also opt in via Profile->userRouters, unless admin)
   'removeContainerRouter' # Permission to remove any router (except ide/ssh) from a live reservation - no profile opt-in needed
);

our $USER_PASSWD;
our $ROLES;
our $USERS;

sub ConfigurePasswd ($passwd) {
   $USER_PASSWD = $passwd;
}

# Optionally, update the $USERS package global of User object.
# Then update the derived permissions for each User object.
sub ConfigureUsers ($users = undef) {
   if($users) {
      $USERS = $users;
   }

   foreach my $user (values %$USERS) {
      $user->updateDerivedPermissions();
      $user->updateDerivedResourceConstraints();
   }
}

sub ConfigureRoles ($roles) {
   $ROLES = $roles;
}

################################################################################
# CLASS METHODS
#

# To retrieve preloaded User object: User->load($username)
# To merge clone of preloaded User object into existing User object: $User->load($username)

sub load ($self, $username) {
   return undef unless $USERS->{$username};

   if(ref($self)) {
      my $user = dclone($USERS->{$username});

      %$self = %$user;
   }

   return $USERS->{$username};
}

sub viewers ($class = undef) {
   return [ map { { 'name' => $USERS->{$_}{'name'} // $_, 'username' => $_, 'role' => $USERS->{$_}{'role'} } } sort keys %$USERS ];
}

################################################################################
# CONSTRUCTORS
#

# Generate a new User object, either:
# - with data from users.json, for populating the $USERS in-memory user database;
# - with no data, representing a client connection, subject to authentication.
#
# N.B. We NO LONGER check that the user has a password defined in the passwd file,
# to allow for API to return list of users to an admin, including those without passwords.

sub new ($class, $data = undef) {
   my $self;

   # Decode JSON if needed.
   if(defined($data)) {
      if(!ref($data)) {
         $data = decode_json($data);
      }

      # Require a username
      return undef unless $data->{'username'};

      $self = bless {
         %$data{ qw(username id name email role ssh version gh_token) },
         '_permissions' => $data->{'permissions'} // {},
         '_resources' => $data->{'resources'} // {},
      }, ( ref($class) || $class );

      $self->versionUpgrade();
      $self->updateDerivedPermissions();
      $self->updateDerivedResourceConstraints();

      return $self;
   }

   # Empty User object represents a dummy client.
   return bless {}, ( ref($class) || $class );
}

################################################################################
# AUTHENTICATION
#

# Returns: array of cookies (https, http) suitable for authenticating user.
sub generate_auth_cookies ($self, $host) {
   return generate_auth_cookie_values( $CONFIG->{'uidCookie'}{'name'}, $CONFIG->{'uidCookie'}{'salt'}, $host, $self->signable() );
}

################################################################################
# ACCESSORS
# ---------

sub version ($self) {
   return $self->{'version'} // 0;
}

sub username ($self) {
   return $self->{'username'};
}

sub role ($self) {
   return $self->{'role'};
}

# This sub must match that of same name in UserTagsInput.vue
sub role_as_meta ($self) {
   return $self->role() ? ('role:' . $self->role()) : undef;
}

# FIXME: Rename to derivedPermissions
sub permissions ($self) {
   return $self->{'derivedPermissions'};
}

sub derivedResourceConstraints ($self) {
   return $self->{'derivedResourceConstraints'};
}

sub signable ($self) {
   return { 'name' => $self->username() };
}

sub details ($self) {
   return { %$self{'username', 'id', 'name', 'email'} };
}

sub details_full ($self) {
   return { %$self{'username', 'id', 'name', 'email', 'ssh'} };
}

sub password ($self) {
   return $USER_PASSWD->{$self->username};
}

sub passwordDefined ($self) {
   return defined($USER_PASSWD->{$self->username});
}

sub authorized_keys ($self) {
   my $pk = $self->{'ssh'}{'publicKeys'} // {};
   return [ values %$pk ];
}

sub keypairs ($self, $prefix) {
   return $self->{'ssh'}{'keypairs'}{$prefix};
}

# All of the user's SSH keypairs as a { name => { public, private } } map.
# Deployed in full to the devtainer's ssh-agent (see Reservation::exec).
sub keypairs_all ($self) {
   return $self->{'ssh'}{'keypairs'} // {};
}

sub gh_token ($self) {
   return $self->{'gh_token'} // '';
}

################################################################################
# MUTATORS
# --------

sub authstate ($self, $auth, @rest) {
   if(!@rest) {
      return $self->{'_authstate'}{$auth};
   }

   if(my $value = $rest[0]) {
      $self->{'_authstate'}{$auth} = $value;
   }

   return $self;
}

################################################################################
# CONSTRUCTOR HELPERS
#

sub updateDerivedPermissions ($self) {
   my $user = $self->username;

   # Assume a null role, if no role specified.
   # return {} unless $USERS->{$user};

   # Combine role permissions and user permissions
   my %permissions;

   # If role specified, and it's a recognised role:
   if( my $role = $ROLES->{ $self->{'role'} } ) {

      # And if a permissions property exists for that specified role:
      if( $role->{'permissions'} ) {
         # Start with the role's permissions
         %permissions = %{ $role->{'permissions'} };
      }
   }

   # If a permissions property exists for the user:
   if( $self->{'_permissions'} ) {
      # Merge in the user's permissions
      %permissions = ( %permissions, %{ $self->{'_permissions'} } );
   }

   # Now evaluate a truth value for all permissions, against the merged permissions and the user's role.
   foreach my $permission (@GENERAL_PERMISSIONS, @CONTAINER_PERMISSIONS) {

      # If explicitly set to 0 or false, permission is denied.
      if(defined($permissions{$permission}) && $permissions{$permission} eq '0') {
         $permissions{$permission} = 0;
         next;
      }

      # Failing that, if explicitly set to 1, or the role is 'admin', permission is granted.
      if( $self->{'role'} eq 'admin' || (defined($permissions{$permission}) && $permissions{$permission} eq '1')) {
         $permissions{$permission} = 1;
         next;
      }

      # Failing that, permission is denied.
      $permissions{$permission} = 0;
   }

   # Update the merged 'permissions' property, merged into user's permissions.
   $self->{'derivedPermissions'} = \%permissions;
}

# Start with copy of the user's role's resources
# Loop through user's resource types
# For each resource type:
# if ARRAY, loop through allow any additional resources
# if HASH, loop through keys denying/allowing resources
#
# Output:
# - a hash for each constraint, where the truth value for a key indicates whether the named resource is allowed/denied,
#   and in absence of a key the truth value for '*' indicates whether the resource is allowed/denied.
#
# - the special key '//' (not yet implemented) represents a regex which, if the named resources matches, indicates
#   whether the named resource is allowed/denied.
#
sub updateDerivedResourceConstraints ($self) {
   my @constraintLists;

   if( my $role = $ROLES->{ $self->{'role'} } ) {

      # And if a permissions property exists for that specified role:
      if( $role->{'resources'} ) {
         # Start with the role's resources
         push( @constraintLists, $role->{'resources'} );
      }
   }

   # Finish with user's resources
   if( $self->{'_resources'} ) {
      push( @constraintLists, $self->{'_resources'} );
   }

   my $resourceConstraints = {};
   foreach my $resourceType (qw( profiles runtimes networks auth images IDEs )) {

      # Disallow all resources by default
      $resourceConstraints->{$resourceType} = { '*' => 0 };

      # First process the role resources (if available), then the user's resources.
      foreach my $constraintList (@constraintLists) {
         my $constraints = $constraintList->{$resourceType};

         if( ref($constraints) eq 'ARRAY' ) {
            my %r;
            @r{@$constraints} = (1) x (@$constraints);
            $resourceConstraints->{$resourceType} = { %{$resourceConstraints->{$resourceType}}, %r };
         }
         elsif( ref($constraints) eq 'HASH' ) {
            $resourceConstraints->{$resourceType} = {
               %{$resourceConstraints->{$resourceType}},
               ( map { $_ => ($constraints->{$_} eq '1') ? 1 : 0 } keys %$constraints )
            };
         }
      }
   }

   # Update the merged 'permissions' property, merged into user's permissions.
   $self->{'derivedResourceConstraints'} = $resourceConstraints;
}

####################################################################################################
#
# Permissions logic
#

sub has_permission ($self, $permission) {    # permission name
   return $self->{'derivedPermissions'}{$permission};
}

# Evaluates the User's authorisation to act on a specified container,
# given:
# - the type of action (view, develop or keepPrivate); and
# - the User's specific permissions and their relationship to the specified container
#   i.e. named owner, named developer, or named viewer.
sub can_on ($self, $container, $action) {    # Reservation object; 'view' | 'develop' | 'keepPrivate'
   my $username = $self->username();
   my $role = $self->role_as_meta;

   # Users named as a container's owner, developer or viewer can view the container.
   if( $action eq 'view' ) {

      # Anyone with viewAllContainers capability can view all containers, except private ones
      return 1 if $self->has_permission( 'viewAllContainers' ) && ( $container->meta('private') ne '1' );

      # Anyone with viewAllPrivateContainers capability can also view all containers
      return 1 if $self->has_permission( 'viewAllPrivateContainers' );

      return (
         $container->meta('owner') eq $username ||
         $container->meta_has_user('viewers', $username) ||
         $container->meta_has_user('viewers', $role) ||
         $container->meta_has_user('developers', $username) ||
         $container->meta_has_user('developers', $role)
      ) ? 1 : 0;
   }

   # Users named as a container's owner or developer can develop the container.
   if( $action eq 'develop' ) {
      return 1 if $container->meta('owner') eq $username;
      return 0 unless $self->has_permission( 'developContainers' );
      return 1 if $self->has_permission( 'developAllContainers' );    # FIXME This is implementing a 3-way switch with two booleans (always-on, depends-on-container, always-off)
      return (
         $container->meta_has_user('developers', $username) ||
         $container->meta_has_user('developers', $role)
      ) ? 1 : 0;
   }

   # Only the User named as the container's owner can keep the container private.
   if( $action eq 'keepPrivate' ) {
      return ( $container->meta('owner') eq $username ) ? 1 : 0;
   }

   return 0;
}

sub can_use_resource ($self, $resourceType, $resource) {
   my $resources = $self->derivedResourceConstraints;

   return $resources->{$resourceType} &&
      ($resources->{$resourceType}{$resource} // $resources->{$resourceType}{'*'});
}

####################################################################################################
#
# Query resources accessible to the user
#

sub profiles ($self) {
   my %userProfiles = map {
      my $p = Profile->load($_);
      ($self->can_use_resource('profiles', $_) && $p->{'active'}) ?
         ($_ => $p->cloneWithConstraints($self->derivedResourceConstraints)->sanitise) :
         ()
   } (Profile->names);

   return \%userProfiles;
}

# Returns data structure indicating user's relationship to a reservation:
# - auth: authorisation modes the user satisfies on the reservation
# - actions: actions the user is permitted to perform on the reservation/container
sub reservationPermissions ($self, $reservation) {
   my $permittedAuth = $self->username ? {
      'owner' => ( $reservation->meta('owner') eq $self->username ) ? 1 : 0,
      'developer' => $self->can_on( $reservation, 'develop' ),
      'viewer' => $self->can_on( $reservation, 'view' ),
      'user' => 1
   } : {};

   # containerCookie functionality incomplete:
   #
   # $permittedAuth->{'containerCookie'} = (
   #    $reservation->{'meta'}{'secret'} ne '' &&
   #    $self->{'_authstate'}{'containerCookie'} =~ /\Q$reservation->{'meta'}{'secret'}\E/
   #    ) ? 1 : 0;

   # public
   $permittedAuth->{'public'} = 1;

   my $permittedActions;
   foreach my $permission (@CONTAINER_PERMISSIONS) {
      $permittedActions->{$permission} = ($permittedAuth->{'developer'} && $self->has_permission($permission)) ? 1 : 0;
   }

   # addContainerRouter needs one more gate the generic loop above can't express: the profile
   # itself must opt in via userRouters (docs/adr/0008-router-mutation.md) - unless this user is
   # admin, who bypasses the profile-level gate by default (only an explicit per-account denial
   # of addContainerRouter, already reflected in has_permission above, blocks an admin). Give this
   # one permission its own line rather than special-casing it inside the loop above, so every
   # other @CONTAINER_PERMISSIONS entry keeps the plain, generic check. removeContainerRouter
   # needs no equivalent - it has no profile-level component, so the generic loop already
   # produced the right answer for it.
   if( $permittedActions->{'addContainerRouter'} ) {
      $permittedActions->{'addContainerRouter'} = $self->_canAddRoutersToReservation($reservation);
   }

   return { 'auth' => $permittedAuth, 'actions' => $permittedActions };
}

# Created a 'ClientReservation' data structure for a reservation.
# This data structure is a sanitised Reservation object,
# augmented with data indicating the user's relationship to the reservation,
# and with properties, that the user does not need to see, removed.
sub createClientReservation ($self, $reservation = undef) {
   # Create a dummy reservation, for the client UI.
   $reservation //= Reservation->new( {
      'id' => 'new',
      'owner' => $self->details(),
      'meta' => {
         'owner' => $self->username()
      },
   } );

   return $reservation->cloneWithConstraints(
      $self->derivedResourceConstraints, 
      $self->reservationPermissions($reservation)
   );
}

# Query Reservation objects viewable by the user.
#
# Inputs (hashref):
# - id: <reservation id> - <optional>
# - name: <reservation name> - <optional>
# - status: 'hasRunnableContainer' - <optional>
# - external: create a sanitised clone of the reservation objects (and referenced Profile objects),
#             suitable for sending to the user, with unneeded properties deleted

sub reservations ($self, $opts = {}) {
   # FIXME: if $opts->{'id'}, pass this into Reservation->load for efficiency.
   my $reservations = Reservation->load( {} );

   my $viewable = [];

   foreach my $reservation (@$reservations) {

      # Skip all but the specified reservation, if id provided.
      next if $opts->{'id'} && ($opts->{'id'} ne $reservation->{'id'});

      # Skip all but the specified reservation, if name provided.
      next if $opts->{'name'} && ($opts->{'name'} ne $reservation->{'name'});

      # Skip all reservations without an active container, if required.
      next if $opts->{'status'} && $opts->{'status'} eq 'hasRunnableContainer' && $reservation->{'status'} < 0;

      # Skip containers the user isn't allowed to view.
      next unless $self->can_on( $reservation, 'view' );

      # If the data will be used externally (i.e. sent to the client),
      # make a copy, sanitise to remove unneeded data and annotate it with permissions data.
      # WARNING: Be careful to avoid storing the sanitised copy back into the reservations database!
      push(@$viewable, $opts->{'client'} ? $self->createClientReservation($reservation) : $reservation);
   }

   my $username = $self->username;
   my $role = $self->role_as_meta();
   
   # Sort reservations by:
   # - those one owns, first
   # - those one is a named developer on, second;
   # - those one is a named viewer on, third;
   # - by status, descending;
   # - alphabetically.
   @$viewable = sort {
      ( ($b->meta('owner') eq $username) <=> ($a->meta('owner') eq $username) )
      ||
      ( ($b->meta_has_user('developers', $username) || $b->meta_has_user('developers', $role)) <=> ($a->meta_has_user('developers', $username) || $a->meta_has_user('developers', $role)) )
      ||
      ( ($b->meta_has_user('viewers', $username) || $b->meta_has_user('viewers', $role)) <=> ($a->meta_has_user('viewers', $username) || $a->meta_has_user('viewers', $role)) )
      ||
      ( $b->status() <=> $a->status() )
      ||
      ( $a->name() cmp $b->name() );
   } @$viewable;

   return $viewable;
}

sub reservation ($self, $arg = undef) {
   my $opts = (ref($arg) eq 'HASH') ? $arg : { 'id' => $arg };

   my $reservations = $self->reservations( $opts );

   # This also verifies the user has view access to this container.
   if( !scalar(@$reservations) ) {
      die Exception->new( 'msg' => "Container not found" );
   }
   elsif( scalar(@$reservations) > 1 ) {
      die Exception->new( 'msg' => "Multiple reservations found", 'dbg' => $reservations );
   }

   return $reservations->[0];
}

####################################################################################################
#
# Update resources accessible to the user
#

# Private method.
# Returns truthy if user is authorised to set $property to $value
# Returns falsey if not.
sub set ($self, $reservation, $property, $value = '') {
   # Signature defaults fire based on arg count, not definedness - createContainerReservation/
   # updateContainerReservation always pass 4 args, even when the caller's $args->{$m} is
   # absent, so the '' default above never fires here. Normalise undef to '' explicitly so
   # every eq/ne branch below sees '' for "no value supplied".
   $value //= '';

   if( $property eq 'profile') {

      # Not permitted
      return 0 unless
         $value &&
         # The createContainerReservation permission doesn't need to be checked:
         # the profile can only be set on launch, and it has already been checked in createContainerReservation.
         $self->can_use_resource('profiles', $value);

      return $reservation->profile($value);
   }

   my $profileObject = $reservation->profileObject->cloneWithConstraints($self->derivedResourceConstraints);

   if( $property eq 'gitURL') {

      if( $value eq '' ) {

         # If no gitURLs in this profile, treat as optional
         if( scalar(@{$profileObject->gitURLs}) == 0 ) {
            return 1;
         }

         # Otherwise, select the default for this profile (and, where required, user).
         $value = $profileObject->default_gitURL;
      }

      # Not permitted
      return 0 unless
         # The createContainerReservation permission doesn't need to be checked:
         # the gitURL can only be set on launch, and the permission has already been
         # checked in createContainerReservation.
         defined($value) && # Check we were able to identify a default $value (if needed)
         $profileObject->has('gitURL', $value); # The requested gitURL is in the profile list

      return $reservation->data('gitURL', $value);
   }

   elsif( $property eq 'image') {

      if( $value eq '' ) {
         # Select default for this profile (and, where required, user).
         $value = $profileObject->default_image;
      }

      # Not permitted
      return 0 unless
         # The createContainerReservation permission doesn't need to be checked:
         # the image can only be set on launch, and the permission has already been
         # checked in createContainerReservation.
         defined($value) && # Check we were able to identify a default $value (if needed)
         $profileObject->has('image', $value); # The requested image is in the profile list

      return $reservation->data('image', $value);
   }

   elsif( $property eq 'runtime') {

      if( $value eq '' ) {
         # Select default for this profile (and, where required, user).
         $value = $profileObject->default_runtime;
      }

      # Not permitted
      return 0 unless
         # The createContainerReservation permission doesn't need to be checked:
         # the runtime can only be set on launch, and the permission has already been
         # checked in createContainerReservation.
         defined($value) && # Check we were able to identify a default $value (if needed)
         $profileObject->has('runtime', $value); # The requested runtime is in the profile list

      return $reservation->data('runtime', $value);
   }

   elsif( $property eq 'network') {

      # Permitted, if no change is requested.
      # FIXME: If a data.network change is successful, but the call to dockerd to change the network is unsuccessful,
      # the data.network property could become out of sync with the docker.Networks property.
      # Perhaps we should be comparing the requested network with docker.Networks instead?
      if( $value eq '' ) {
         # Select default for this profile (and, where required, user).
         ($value) = $profileObject->default_network;
      }

      # Not permitted
      return 0 unless
         defined($value) && # Check we were able to identify a default $value (if needed)
         $self->can_on( $reservation, 'develop' ) && # We can develop on the given container; network might be changed after launch.
         $profileObject->has( 'network', $value ); # The requested network is in the profile list

      return $reservation->data('network', $value);
   }

   elsif( $property eq 'unixuser') {

      if( $value eq '' ) {
         # Select default for this profile (and, where required, user).
         $value = $profileObject->default_unixuser;
      }

      # Not permitted
      return 0 unless
         # The createContainerReservation permission doesn't need to be checked:
         # the unixuser can only be set on launch, and the permission has already been
         # checked in createContainerReservation.
         defined($value) && # Check we were able to identify a default $value (if needed)
         $profileObject->has( 'unixuser', $value); # The requested unixuser is in the profile list

      return $reservation->data('unixuser', $value);
   }

   elsif( $property eq 'IDE') {

      my $current = $reservation->meta('IDE') // '';

      # Permitted, if no change in value is requested, or empty value requested
      # when non-empty value already set. Gated on $current ne '': a fresh
      # reservation (current '') must always fall through to default resolution
      # below, never short-circuit here just because both sides are blank.
      if( $current ne '' && ($current eq $value || $value eq '') ) {
         return 1;
      }

      if( $value eq '' ) {
         # Select default for this profile (and, where required, user).
         $value = $profileObject->default_IDE;

         # Permitted (IDE left unresolved), if the profile has no IDE choices to
         # offer at all - matches pre-existing behaviour for profiles whose IDEs
         # list resolves empty (no host IDE installed, no 'none' declared).
         return 1 if $value eq '';
      }

      # Not permitted
      return 0 unless
         # The createContainerReservation permission doesn't need to be checked:
         # the image can only be set on launch, and the permission has already been
         # checked in createContainerReservation.
         defined($value) && # Check we were able to identify a default $value (if needed)
         $profileObject->has('IDE', $value) && # The requested gitURL is in the profile list
         $self->can_on( $reservation, 'develop' ); # We can develop on the given container; IDE might be changed after launch.

      return $reservation->meta('IDE', $value);
   }

   elsif( $property eq 'description') {

      # Not permitted
      return 0 unless
         $self->can_on( $reservation, 'develop' );

      return $reservation->meta('description', $value);
   }

   elsif( $property eq 'private') {

      $value = $value ? 1 : 0;

      # Permitted, if no change is requested.
      if( $reservation->meta('private') == $value ) {
         return 1;
      }

      # Not permitted
      return 0 unless
         $self->has_permission( 'setContainerPrivacy' ) &&
         $self->can_on( $reservation, 'keepPrivate' );

      return $reservation->meta('private', $value);
   }

   elsif( $property eq 'access') {
      # $value is JSON object consisting of <name>: <value> pairs,
      # where <name> is a router name and <value> is an allowed serviceAccessLevel.
      # If no object is provided, default serviceAccessLevels will be used for the profile and user.
      # If object is provided, but some router <names> are missing or some <values> are empty, do not change serviceAccessLevels will be used for the profile and user.

      # If $value provided, assume it is JSON and decode.
      if( $value ne '' ) {
         try {
            $value = decode_json($value);
         }
         catch {
            return 0;
         };
      }

      # $value ne '' above leaves $value as '' (not decoded) whenever no access was
      # requested - previously that meant $value stayed undef, and Perl reads undef->{$name}
      # below as an empty map without complaint; now that the top-of-sub $value //= '' means
      # a real, defined '' reaches here instead, the same read would die ("Can't use string
      # as a HASH ref") under strict refs. Normalise explicitly rather than depending on
      # that undef-specific leniency.
      $value = {} unless ref($value) eq 'HASH';

      my $oldAccess = $reservation->meta('access');
      my $newAccess = {};

      # Check every router in the profile.
      # Only consider updating access level where requested, or where no existing value is set (the launch case).
      # Where requested, only require permission to update access level if the requested value is different.
      # Where not requested, if no existing value is set (the launch case) look for a permitted default.
      foreach my $router (@{$profileObject->routers}) {
         my $name = $router->{'name'};

         # If the user has requested an access mode be assigned for this router,
         # and it is different to the one which is currently set,
         # do not permit unless the user is allowed to use that access mode
         # and the profile supports it.
         if( $value->{$name} && ($value->{$name} ne $oldAccess->{$name}) ) {
            return 0 unless
               # User and profile allow the requested auth type
               grep { $_ eq $value->{$name} } @{$router->{'auth'}};

            $newAccess->{$name} = $value->{$name};
         }

         # FIXME: If we decide to restrict the client's access to routers that they are not permitted to access,
         # then we'll need to break this elsif out into a separate foreach that loops through $reservation->profileObject->routers instead.
         #
         # If the user has not requested an access mode for this router and no access mode has yet
         # been assigned, then look for an acceptable default, and do not proceed if no good default can be found.
         elsif(!$oldAccess->{$name}) {
            # If no access mode has been applied yet for a router, select the first appropriate.
            my ($defaultAuth) = @{$router->{'auth'}};

            # Not permitted: if no acceptable access mode can be found.
            return 0 unless $defaultAuth;

            $newAccess->{$name} = $defaultAuth;
         }
      }

      # Permitted, if no access settings would actually be changed.
      return 1 unless keys %$newAccess;

      # Not permitted
      return 0 unless
         $self->can_on( $reservation, 'develop' );

      return $reservation->meta('access', $newAccess);
   }

   elsif( $property eq 'viewers' ) {

      # Permitted, if no change is requested.
      return 1 unless $reservation->meta($property) ne $value;

      # Not permitted
      return 0 unless
         $self->has_permission( 'setContainerViewers' ) &&
         $self->can_on( $reservation, 'develop' );

      return $reservation->meta($property, $value);
   }

   elsif( $property eq 'developers' ) {

      # Permitted, if no change is requested.
      return 1 unless $reservation->meta($property) ne $value;

      # Not permitted
      return 0 unless
         $self->has_permission( 'setContainerDevelopers' ) &&
         $self->can_on( $reservation, 'develop' );

      return $reservation->meta($property, $value);
   }

   elsif( $property eq 'options' ) {
      my $profileOptions = $profileObject->options;

      # No options defined in this profile: ignore any submitted value.
      return 1 unless @$profileOptions;

      # Decode JSON string if needed. An undef or empty value means no options
      # were supplied; treat as empty hash so defaults are filled in below.
      my $decoded;
      if( !defined($value) || $value eq '' ) {
         $decoded = {};
      }
      elsif( ref($value) eq 'HASH' ) {
         $decoded = $value;
      }
      else {
         try {
            $decoded = decode_json($value);
         }
         catch {
            return 0;
         };
      }

      return 0 unless ref($decoded) eq 'HASH';

      # Build lookup of allowed option names.
      my %allowed = map { $_->{'name'} => $_ } @$profileOptions;

      # Reject any option keys not defined in the profile.
      for my $key ( keys %$decoded ) {
         return 0 unless exists $allowed{$key};

         # For select-type options, reject values not in the allowed list.
         my $opt = $allowed{$key};
         if( ($opt->{'type'} // 'text') eq 'select' ) {
            return 0 unless grep { $_ eq $decoded->{$key} } @{$opt->{'values'} // []};
         }
      }

      # Fill in defaults for any options not supplied by the user.
      for my $opt ( @$profileOptions ) {
         $decoded->{ $opt->{'name'} } //= $opt->{'default'} // '';
      }

      return $reservation->data('options', $decoded);
   }

   return 1;
}

# Updates the metadata stored within a Reservation object
# Named in camelCase for consistency with current REST API call.
sub updateContainerReservation ($self, $args) {
   # Retrieve the reservation object using the provided reservation ID
   my $reservation = $self->reservation( $args->{'id'} );

   # Throw an exception if the reservation is not found
   unless($reservation) {
      die Exception->new( 'msg' => "Reservation id '$args->{'id'}' not found" );
   }

   # Create a deep clone of the original reservation for comparison
   my $origReservation = dclone($reservation);

   # Update metadata fields if they are defined in the arguments. Tracks which ones were
   # actually touched (split by whether each lives under meta vs data - see set()'s own
   # per-property branches) so the eventual store only sends what this request actually
   # changed, not this process's entire in-memory copy of every meta/data field - see
   # Reservation::store_fields' own comment for why a blind full store() risks clobbering a
   # fresher value some concurrent writer (another admin's own edit, or this same devtainer's
   # own docker-event-daemon launch dispatch if it's still mid-launch) already persisted.
   my %touchedMeta;
   my %touchedData;
   foreach my $m (qw( access viewers developers private network description IDE )) {
      if(defined($args->{$m})) {
         $self->set($reservation, $m, $args->{$m}) ||
            die Exception->new( 'msg' => "You have no permissions to set '$m' to '$args->{$m}' in this reservation" );
         if( $m eq 'network' ) { $touchedData{$m} = $reservation->data($m); }
         else { $touchedMeta{$m} = $reservation->meta($m); }
      }
   }

   # Store the changes if all updates are successful
   # (if container is not running runningIDE should mirror requested IDE immediately)
   if(!$reservation->is_running) {
      $reservation->data('runningIDE', $reservation->meta('IDE'));
      $touchedData{'runningIDE'} = $reservation->data('runningIDE');
   }

   $reservation->store_fields( {
      ( %touchedMeta ? ( 'meta' => \%touchedMeta ) : () ),
      ( %touchedData ? ( 'data' => \%touchedData ) : () ),
   } );

   # Only reconcile Docker network attachment when the requested network changed.
   if( ($origReservation->data('network') // '') ne ($reservation->data('network') // '') ) {
      $reservation->update_network();
   }

   # Only if the reservation is running
   if($reservation->is_running) {
      
      # Check if the IDE has changed
      if ($origReservation->meta('IDE') ne $reservation->meta('IDE')) {
         # Execute a command to update the running IDE
         # (Enable once the restart_ide logic is resilient)
         #
         # $reservation->exec('restart_ide');
      }

      # Update SSH authorized keys if there are changes in developers or access fields
      if( $origReservation->meta('developers') ne $reservation->meta('developers') ||
         $origReservation->meta('access')->{'ssh'} ne $reservation->meta('access')->{'ssh'} ) {
         $reservation->exec('update_ssh_authorized_keys');
      }
   }

   # Return a sanitized clone of the reservation object for client-side use
   return $self->createClientReservation($reservation);
}

# Decodes an $args->{'router'} value into a plain hashref, mirroring set()'s own 'access'/'options'
# branches above - the request body is form-urlencoded like every other API call in this file
# (App::split_args), so a structured field like a router definition arrives as one JSON-encoded
# string value, not as nested form fields. Dies with a 400 Exception on malformed JSON, same
# status normalise_router_def itself uses for every other input problem.
sub _decode_router_arg ($value) {
   die Exception->new( 'msg' => "'router' is required", 'status' => 400 )
      unless defined($value) && $value ne '';
   my $decoded;
   try {
      $decoded = decode_json($value);
   }
   catch {
      die Exception->new( 'msg' => "'router' must be valid JSON", 'status' => 400 );
   };
   die Exception->new( 'msg' => "'router' must be a JSON Object", 'status' => 400 )
      unless ref($decoded) eq 'HASH';
   # 'type' is the one field a client has no legitimate reason to send - always server-assigned by
   # Reservation::normalise_router_def, which builds its return value as a fresh whitelist of
   # known fields rather than merging $decoded in, so a stray 'type' here is discarded downstream
   # regardless. 'auth', unlike 'type', *is* legitimately caller-suppliable (a narrowed allow-list
   # via --auth) - see addContainerRouter/replaceContainerRouter below, which fill in the wide
   # default themselves when it's absent, rather than leaving that decision to
   # Reservation::normalise_router_def (docs/adr/0008-router-mutation.md).
   return $decoded;
}

# Shared by reservationPermissions (deriving the client-visible actions.addContainerRouter flag)
# and addContainerRouter/replaceContainerRouter (enforcing the same rule) - docs/adr/0008-router-mutation.md's
# profile-level opt-in for *adding* a router, bypassed by default for role='admin'. Factored into
# one place so the two can never drift apart - the enforcement and the "can I?" signal shown to
# any client (CLI or a future UI) must always agree.
sub _canAddRoutersToReservation ($self, $reservation) {
   return (
      $self->role eq 'admin' || ( $reservation->profileObject && $reservation->profileObject->userRouters )
   ) ? 1 : 0;
}

# The initial meta.access value a self-service add/replace gets when the caller didn't request an
# explicit one via --access: 'owner' if this user owns $reservation, else 'developer' - the
# narrowest access level that still includes the caller. Anyone reaching this code who isn't the
# owner already passed can_on(develop), i.e. is a named developer, so 'developer' is the correct
# non-owner preference, not a further-narrowed "just me" level (no such level exists in this
# codebase's vocabulary - see Reservation's @KNOWN_ROUTER_AUTH_LEVELS). Falls back to the first
# entry of $auth (the router's own final, default-wide or caller-narrowed, auth list) if the
# preferred level isn't actually a member of it - e.g. a developer adding a router with
# --auth owner can't have 'developer' as its default, so this falls back to 'owner' instead.
#
# This is deliberately a different mechanism from User::set()'s own 'access' branch (the
# profile-declared-router launch-time default, "first entry of the router's auth list") - that
# one is unavoidably actor-agnostic (only the owner exists at launch time; there's nothing to be
# actor-aware about), so retrofitting this rule there would just always resolve to 'owner',
# silently overriding whatever order a profile author chose. Self-service add/replace has no such
# prior convention to preserve, so it's free to use the more precise rule.
#
# Reservation::Mutate makes no such actor-aware (or any other) decision itself - it only checks
# that whatever value is resolved here is actually legal under $auth; this is the one place that
# fallback is decided. See docs/adr/0008-router-mutation.md.
sub _defaultRouterAccessLevel ($self, $reservation, $auth) {
   my $preferred = ( $reservation->meta('owner') eq $self->username ) ? 'owner' : 'developer';
   return ( grep { $_ eq $preferred } @$auth ) ? $preferred : $auth->[0];
}

# Adds a router to a live reservation (docs/adr/0008-router-mutation.md). Gated on
# addContainerRouter + can_on(develop) (the same two-part shape as every other developer-level
# container mutation above - see the 'access'/'private' branches of set()) and, unless this user
# is admin, the profile's own userRouters opt-in - the one profile-level gate that survived
# review. Shape and collision validation, and the actual persistence, live in
# Reservation::normalise_router_def and Reservation::add_router - this method's job is the
# permission/profile-gate decision, resolving the two inputs neither of those layers is allowed
# to guess at itself (the router's allowed 'auth' list, and the initial access level to assign),
# and marshalling the request.
sub addContainerRouter ($self, $args) {
   my $reservation = $self->reservation( $args->{'id'} );
   unless($reservation) {
      die Exception->new( 'msg' => "Reservation id '$args->{'id'}' not found" );
   }

   unless( $self->has_permission('addContainerRouter') && $self->can_on( $reservation, 'develop' ) ) {
      die Exception->new( 'msg' => "You need the 'addContainerRouter' permission to add a router to this devtainer" );
   }
   unless( $self->_canAddRoutersToReservation($reservation) ) {
      die Exception->new( 'msg' => "This devtainer's profile does not allow adding routers" );
   }

   my $routerDef = _decode_router_arg( $args->{'router'} );
   $routerDef->{'auth'} //= Reservation::known_router_auth_levels();
   my $accessLevel = $args->{'access'} // $self->_defaultRouterAccessLevel($reservation, $routerDef->{'auth'});

   $reservation->add_router( $routerDef, $accessLevel );

   return $self->createClientReservation($reservation);
}

# Removes router $args->{'name'} from a live reservation. Gated on removeContainerRouter +
# can_on(develop) only - no profile-level opt-in; removal is uniform across admin-authored and
# type=user routers alike. The one remaining per-router exception (type ide/ssh, non-bypassable
# even for admin) is enforced inside Reservation::remove_router itself, not here.
sub removeContainerRouter ($self, $args) {
   my $reservation = $self->reservation( $args->{'id'} );
   unless($reservation) {
      die Exception->new( 'msg' => "Reservation id '$args->{'id'}' not found" );
   }

   unless( $self->has_permission('removeContainerRouter') && $self->can_on( $reservation, 'develop' ) ) {
      die Exception->new( 'msg' => "You need the 'removeContainerRouter' permission to remove a router from this devtainer" );
   }

   $reservation->remove_router( $args->{'name'} );

   return $self->createClientReservation($reservation);
}

# Atomically replaces router $args->{'name'} with $args->{'router'} (a convenience wrapper -
# same-name remove+add under one lock, carrying meta.access forward). Needs both permissions -
# the add half and the remove half are each exactly as gated as their standalone counterparts
# above, so replace needs no permission or profile-gate of its own beyond the union of the two.
sub replaceContainerRouter ($self, $args) {
   my $reservation = $self->reservation( $args->{'id'} );
   unless($reservation) {
      die Exception->new( 'msg' => "Reservation id '$args->{'id'}' not found" );
   }

   unless(
      $self->has_permission('addContainerRouter') && $self->has_permission('removeContainerRouter') &&
      $self->can_on( $reservation, 'develop' )
   ) {
      die Exception->new( 'msg' => "You need both the 'addContainerRouter' and 'removeContainerRouter' permissions to replace a router on this devtainer" );
   }
   unless( $self->_canAddRoutersToReservation($reservation) ) {
      die Exception->new( 'msg' => "This devtainer's profile does not allow adding (and so replacing) routers" );
   }

   my $routerDef = _decode_router_arg( $args->{'router'} );
   $routerDef->{'auth'} //= Reservation::known_router_auth_levels();
   my $accessLevel = $args->{'access'} // $self->_defaultRouterAccessLevel($reservation, $routerDef->{'auth'});

   $reservation->replace_router( $args->{'name'}, $routerDef, $accessLevel );

   return $self->createClientReservation($reservation);
}

# Stops, starts or removed a container.
# Named in camelCase for consistency with current REST API call.
sub controlContainer ($self, $cmd, $id, $args = {}, $cb = undef) {
   if( $id !~ m!^([0-9a-f]+)$! || $cmd !~ m!^(stop|start|remove|getLogs)$! ) {
      die Exception->new( 'msg' => "command '$cmd' with invalid argument '$id' failed" );
   }

   my $permission = $cmd eq 'getLogs' ? 'getContainerLogs' : "${cmd}Container";
   if( !$self->has_permission($permission) ) {
      die Exception->new( 'msg' => "You need the '$permission' permission to execute command '$cmd' on this devtainer" );
   }

   my $container = $self->reservation($id);

   if( !$self->can_on( $container, 'develop' )) {
      die Exception->new( 'msg' => "You need the 'develop' permission to execute '$cmd' on this devtainer" );
   }

   # Execute the requested command. Narrow store - see Reservation::store_fields' own comment -
   # since this container's own launch DAG (docker-event-daemon) may concurrently be writing
   # other, unrelated fields once 'start' actually takes effect.
   if($cmd eq 'start' && !$container->is_running) {
      $container->data('runningIDE', $container->meta('IDE'));
      $container->store_fields( { 'data' => { 'runningIDE' => $container->data('runningIDE') } } );
   }

   # $cb present (bin/app-server's native stop/start/remove routes) => async, via
   # action, no fork, no docker CLI subprocess. $cb absent => the getLogs route, the
   # one caller that stays on the synchronous getLogs() path deliberately - see getLogs()'s
   # own comment for why.
   return $container->action($cmd, $args, $cb) if $cb;
   return $container->getLogs($args);
}

# Runs a container's profile-declared hook (named by $args->{'name'}) on demand (e.g. a user has
# changed the 'branch'/'pr' options and wants their devtainer to switch now, without a full
# relaunch). Named/shaped like controlContainer above. $args is forwarded opaquely to
# run_hook_manual, which requires and validates 'name' itself - nothing here needs to know
# its shape.
#
# $cb is required: bin/app-server's native hook route is this method's only caller now - the
# old synchronous (forking) fallback, and the App.pm route that was its only caller, are both
# gone (audited first - no other caller existed).
sub runContainerHook ($self, $id, $args, $cb) {
   if( $id !~ m!^([0-9a-f]+)$! ) {
      die Exception->new( 'msg' => "hook run with invalid argument '$id' failed" );
   }

   if( !$self->has_permission('runContainerHooks') ) {
      die Exception->new( 'msg' => "You need the 'runContainerHooks' permission to run a devtainer's hook" );
   }

   my $container = $self->reservation($id);

   if( !$self->can_on( $container, 'develop' )) {
      die Exception->new( 'msg' => "You need the 'develop' permission to run a hook on this devtainer" );
   }

   return $container->run_hook_manual($args, $cb);
}

# Reads a container's hook invocation status/log (named by $args->{'name'}), for a client to
# poll now that runContainerHook above dispatches non-blockingly and returns almost
# immediately. Same permission model as runContainerHook - reading a hook's own status/log
# needs the same permissions as running it in the first place, not a separate lesser one.
# Returns { status, output }:
# status is hook_status($name)'s master-record entry (undef if $name has never been invoked
# on this devtainer), output is load_hook_log($name)'s tailed log lines ([] if there is
# nothing to show yet, for either reason).
sub runContainerHookStatus ($self, $id, $args = {}) {
   if( $id !~ m!^([0-9a-f]+)$! ) {
      die Exception->new( 'msg' => "hook status read with invalid argument '$id' failed" );
   }

   if( !$self->has_permission('runContainerHooks') ) {
      die Exception->new( 'msg' => "You need the 'runContainerHooks' permission to read a devtainer's hook status" );
   }

   my $container = $self->reservation($id);

   if( !$self->can_on( $container, 'develop' )) {
      die Exception->new( 'msg' => "You need the 'develop' permission to read a hook's status on this devtainer" );
   }

   my $name = $args->{'name'};
   die Exception->new( 'msg' => "'name' is required", 'status' => 400 ) unless length($name // '');

   return {
      'status' => $container->hook_status($name),
      'output' => $container->load_hook_log($name),
   };
}

# Creates a Reservation object, stores it, and attempts to launch a container for that Reservation.
# Named in camelCase for consistency with current REST API call.
#
# $cb is required: bin/app-server's native create route is this method's only caller now -
# async throughout (getGitDevContainer, then store(), then create - no fork, no
# blocking GitHub fetch, no docker CLI subprocess). The old synchronous fallback, and the
# App.pm route that was its only caller, are both gone (audited first - no other caller
# existed).
sub createContainerReservation ($self, $args, $cb) {
   # Launch new container.
   if( !$self->has_permission( 'createContainerReservation' ) ) {
      die Exception->new( 'msg' => "You need the 'createContainerReservation' permission to launch a devtainer" );
   }

   flog("User::createContainerReservation: calling Reservation->new");

   my $reservation = Reservation->new( {
         'name' => $args->{'name'},
         'data' => { # Profile-related launch data e.g. network, image, command, user
            'parentFQDN' => $args->{'parentFQDN'},
            'FQDN' => $args->{'FQDN'}
         },
         'owner' => $self->details(),
         'meta' => {
            'owner' => $self->username()
         },
      }
   );

   foreach my $m (qw( profile image runtime network unixuser access viewers developers private description gitURL IDE options )) {
      $self->set($reservation, $m, $args->{$m}) ||
         die Exception->new( 'msg' => "You have no permissions to set '$m' to '$args->{$m}' in this reservation" );
   }

   $reservation->data('runningIDE', $reservation->meta('IDE'));

   # Test if we can construct the command line; on failure, we'll throw an error.
   $reservation->cmdline();

   $reservation->getGitDevContainer( sub ($dc) {
      if ($dc) {
         if($dc->{'image'}) {
            $reservation->data('image', $dc->{'image'});

            if(!$dc->{'overrideCommand'}) {
               $reservation->data('entrypoint', '/bin/sh');
               $reservation->data('command', ['-c', "while sleep 1000; do :; done"]);
            }
         }

         $dc->{'remoteUser'} && $reservation->data('unixuser', $dc->{'remoteUser'});
         $dc->{'postCreateCommand'} && $reservation->data('postCreateCommand', $dc->{'postCreateCommand'});
         $dc->{'customizations'}{'vscode'} && $reservation->data('vscode', $dc->{'customizations'}{'vscode'});
      }

      # Store, then create/launch asynchronously, then hand $cb a sanitised clone of the
      # reservation object. A full (not narrowed) store() is correct here specifically: this
      # reservation id has never been persisted before this call, so no other process can
      # possibly be concurrently writing to it - none of Reservation::store_fields' concerns (a
      # stale in-memory copy of some unrelated field clobbering a fresher one) apply to a
      # record's very first write. Wrapped in try/catch because this whole callback runs outside
      # the caller's own try/catch frame (it fires later, off the event loop, once the GitHub
      # fetch above resolves) - an uncaught die here would be an uncaught exception inside a Mojo
      # completion callback, not something bin/app-server's own surrounding try/catch could ever
      # see (see docker_exec's own comment on this same hazard, Util.pm).
      try {
         $reservation->store()->create( sub ($createdReservation, $err) {
            return $cb->( undef, $err ) if $err;
            return $cb->( $self->createClientReservation($createdReservation), undef );
         } );
      }
      catch {
         $cb->( undef, $_ );
      };
   } );
   return;
}

1;
