package User;

use v5.36;

use JSON;
use Try::Tiny;
use URI::Escape;
use Storable qw(dclone);
use Data qw($CONFIG);
use Util qw(flog wlog TO_JSON generate_auth_cookie_values encrypt_password);
use Reservation;

################################################################################
# CURRENT VERSION
# ---------------

sub CURRENT_VERSION () {
   return 1;
}

##################
# VERSION UPGRADES
# ----------------

sub versionUpgrade ($self) {
   if($self->version == 0) {
      $self->{'_resources'}{'IDEs'} //= ['*'];
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
   'manageUsers' # Permission to create/update/remove/list users and roles
);

my @CONTAINER_PERMISSIONS = (
   'setContainerViewers', # Permission to edit the list of viewers for containers
   'setContainerDevelopers', # Permission to edit the list of developers for containers
   'setContainerPrivacy', # Permission to edit the private flag of containers
   'startContainer', # Permission to start a container
   'stopContainer', # Permission to stop a container
   'removeContainer', # Permission to remove a container
   'getContainerLogs' # Permission to retrieve container logs
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
   return $self->{'ssh'}{'authorized_keys'} // [];
}

sub keypairs ($self, $prefix) {
   return $self->{'ssh'}{'keypairs'}{$prefix};
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
      if( $self->{'role'} eq 'admin' || $permissions{$permission} eq '1') {
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
      $self->can_use_resource('profiles', $_) ?
         ($_ => Profile->load($_)->cloneWithConstraints($self->derivedResourceConstraints)->sanitise) :
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

      # If container is not yet created, then update launch logs.
      if($reservation->{'status'} == -2) {
         $reservation->load_launch_logs();
      }

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

      # Permitted, if no change in value is requested, or empty value requested when non-empty value already set.
      if( $reservation->meta('IDE') eq $value || ($reservation->meta('IDE') ne '' && ($value eq '')) ) {
         return 1;
      }

      if( $value eq '' ) {
         # Select default for this profile (and, where required, user).
         $value = $profileObject->default_IDE;
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

      # Decode JSON string if needed.
      my $decoded;
      if( ref($value) eq 'HASH' ) {
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

   # Update metadata fields if they are defined in the arguments
   foreach my $m (qw( access viewers developers private network description IDE )) {
      if(defined($args->{$m})) {
         $self->set($reservation, $m, $args->{$m}) || 
            die Exception->new( 'msg' => "You have no permissions to set '$m' to '$args->{$m}' in this reservation" );
      }
   }

   # Store the changes if all updates are successful
   $reservation->store();

   # Apply any network changes
   $reservation->update_network();

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

# Stops, starts or removed a container.
# Named in camelCase for consistency with current REST API call.
sub controlContainer ($self, $cmd, $id, $args = {}) {
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

   # Execute the requested command.
   return $container->action($cmd, $args);
}

# Creates a Reservation object, stores it, and attempts to launch a container for that Reservation.
# Named in camelCase for consistency with current REST API call.
sub createContainerReservation ($self, $args) {
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

   # Test if we can construct the command line; on failure, we'll throw an error.
   $reservation->cmdline();

   my $dc = $reservation->getGitDevContainer();
   if($dc) {

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

   # Store, launch, and create a sanitised clone of the reservation object, before returning.
   return $self->createClientReservation( $reservation->store()->launch() );
}

################################################################################
# USER AND ROLE MANAGEMENT
# ------------------------

my $CONFIG_PATH = '/data/config';

# Read a JSON config file (stripping // comments) and return parsed data.
sub _read_config_file ($filename) {
   my $path = "$CONFIG_PATH/$filename";
   open( my $FH, '<', $path ) or die Exception->new( 'msg' => "Cannot read $path: $!" );
   local $/;
   my $raw = <$FH>;
   close $FH;
   return Data::parse_json($raw);
}

# Atomically write a data structure to a JSON config file.
sub _write_config_file ($filename, $data) {
   my $path = "$CONFIG_PATH/$filename";
   my $tmp  = "$path.tmp.$$";
   my $json = JSON->new->utf8->pretty->canonical->encode($data);
   open( my $FH, '>', $tmp ) or die Exception->new( 'msg' => "Cannot write $tmp: $!" );
   print $FH $json;
   close $FH;
   rename( $tmp, $path ) or die Exception->new( 'msg' => "Cannot rename $tmp to $path: $!" );
}

# Read the passwd file as a hash of username => encrypted_password.
sub _read_passwd_file () {
   my $path = "$CONFIG_PATH/passwd";
   return {} unless -r $path;
   open( my $FH, '<', $path ) or die Exception->new( 'msg' => "Cannot read $path: $!" );
   my %passwd;
   while ( my $line = <$FH> ) {
      chomp $line;
      $line =~ s/^\s*|\s*$//g;
      next if $line =~ /^(#.*)?$/;
      my ( $user, $hash ) = split( /:/, $line, 2 );
      $passwd{$user} = $hash if defined $user && defined $hash;
   }
   close $FH;
   return \%passwd;
}

# Atomically write a passwd hash back to the passwd file.
sub _write_passwd_file ($passwd) {
   my $path = "$CONFIG_PATH/passwd";
   my $tmp  = "$path.tmp.$$";
   open( my $FH, '>', $tmp ) or die Exception->new( 'msg' => "Cannot write $tmp: $!" );
   for my $user ( sort keys %$passwd ) {
      print $FH "$user:$passwd->{$user}\n";
   }
   close $FH;
   rename( $tmp, $path ) or die Exception->new( 'msg' => "Cannot rename $tmp to $path: $!" );
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
         $out->{'ssh'}         = { %{ $out->{'ssh'} } };
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

#
# User CRUD
#

sub listUsers ($self, $args = {}) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');

   my $sensitive = $args->{'sensitive'} ? 1 : 0;
   return [ map { _sanitise_user_record( _user_to_record( $USERS->{$_} ), $sensitive ) }
            sort keys %$USERS ];
}

sub getUser ($self, $username, $args = {}) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "User '$username' not found" )
      unless $USERS->{$username};

   my $sensitive = $args->{'sensitive'} ? 1 : 0;
   return _sanitise_user_record( _user_to_record( $USERS->{$username} ), $sensitive );
}

sub createUser ($self, $args) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');

   my $username = $args->{'username'}
      or die Exception->new( 'msg' => "username is required" );
   die Exception->new( 'msg' => "Invalid username: use only letters, digits, hyphens, underscores" )
      unless $username =~ /^[A-Za-z0-9_-]+$/;
   die Exception->new( 'msg' => "User '$username' already exists" )
      if $USERS->{$username};

   my $users = _read_config_file('users.json');

   # Auto-assign id if not provided or non-numeric.
   my $id = $args->{'id'};
   unless ( defined $id && $id =~ /^\d+$/ ) {
      my $max_id = 0;
      for my $u ( values %$users ) {
         $max_id = $u->{'id'} if ( $u->{'id'} // 0 ) > $max_id;
      }
      $id = $max_id + 1;
   }

   my $new_user = {
      'id'          => $id + 0,
      'email'       => '',
      'name'        => '',
      'role'        => 'user',
      'permissions' => {},
      'resources'   => {},
      'version'     => CURRENT_VERSION(),
   };

   _apply_args_to_record( $new_user, $args, qw(username password sensitive id) );

   $users->{$username} = $new_user;
   _write_config_file( 'users.json', $users );

   if ( defined $args->{'password'} && length $args->{'password'} ) {
      my $passwd = _read_passwd_file();
      $passwd->{$username} = encrypt_password( $args->{'password'} );
      _write_passwd_file($passwd);
      Data::load('passwd');
   }

   Data::load('users.json');

   return _sanitise_user_record( { %$new_user, 'username' => $username },
      $args->{'sensitive'} ? 1 : 0 );
}

sub updateUser ($self, $username, $args) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "User '$username' not found" )
      unless $USERS->{$username};

   my $users  = _read_config_file('users.json');
   my $record = $users->{$username}
      or die Exception->new( 'msg' => "User '$username' not found in users.json" );

   _apply_args_to_record( $record, $args, qw(username password sensitive) );

   $users->{$username} = $record;
   _write_config_file( 'users.json', $users );

   if ( defined $args->{'password'} && length $args->{'password'} ) {
      my $passwd = _read_passwd_file();
      $passwd->{$username} = encrypt_password( $args->{'password'} );
      _write_passwd_file($passwd);
      Data::load('passwd');
   }

   Data::load('users.json');

   return _sanitise_user_record( { %$record, 'username' => $username },
      $args->{'sensitive'} ? 1 : 0 );
}

sub removeUser ($self, $username, $args = {}) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "User '$username' not found" )
      unless $USERS->{$username};
   die Exception->new( 'msg' => "Cannot remove your own account" )
      if $self->username eq $username;

   my $users = _read_config_file('users.json');
   exists $users->{$username}
      or die Exception->new( 'msg' => "User '$username' not found in users.json" );

   delete $users->{$username};
   _write_config_file( 'users.json', $users );

   my $passwd = _read_passwd_file();
   if ( exists $passwd->{$username} ) {
      delete $passwd->{$username};
      _write_passwd_file($passwd);
      Data::load('passwd');
   }

   Data::load('users.json');

   return { 'username' => $username };
}

#
# Role CRUD
#

sub listRoles ($self) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');

   return [ map { { 'name' => $_, %{ $ROLES->{$_} } } } sort keys %$ROLES ];
}

sub getRole ($self, $name) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "Role '$name' not found" )
      unless $ROLES->{$name};

   return { 'name' => $name, %{ $ROLES->{$name} } };
}

sub createRole ($self, $name, $args) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "Invalid role name: use only letters, digits, hyphens, underscores" )
      unless $name =~ /^[A-Za-z0-9_-]+$/;
   die Exception->new( 'msg' => "Role '$name' already exists" )
      if $ROLES->{$name};

   my $roles    = _read_config_file('roles.json');
   my $new_role = { 'permissions' => {}, 'resources' => {} };

   _apply_args_to_record( $new_role, $args, qw(name) );

   $roles->{$name} = $new_role;
   _write_config_file( 'roles.json', $roles );
   Data::load('roles.json');
   Data::load('users.json');

   return { 'name' => $name, %$new_role };
}

sub updateRole ($self, $name, $args) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "Role '$name' not found" )
      unless $ROLES->{$name};

   my $roles  = _read_config_file('roles.json');
   my $record = $roles->{$name}
      or die Exception->new( 'msg' => "Role '$name' not found in roles.json" );

   _apply_args_to_record( $record, $args, qw(name) );

   $roles->{$name} = $record;
   _write_config_file( 'roles.json', $roles );
   Data::load('roles.json');
   Data::load('users.json');

   return { 'name' => $name, %$record };
}

sub removeRole ($self, $name) {
   die Exception->new( 'msg' => "You need the 'manageUsers' permission" )
      unless $self->has_permission('manageUsers');
   die Exception->new( 'msg' => "Role '$name' not found" )
      unless $ROLES->{$name};

   my @users_with_role = grep { ( $USERS->{$_}{'role'} // '' ) eq $name } keys %$USERS;
   die Exception->new(
      'msg' => "Cannot remove role '$name': still assigned to: " . join( ', ', sort @users_with_role ) )
      if @users_with_role;

   my $roles = _read_config_file('roles.json');
   exists $roles->{$name}
      or die Exception->new( 'msg' => "Role '$name' not found in roles.json" );

   delete $roles->{$name};
   _write_config_file( 'roles.json', $roles );
   Data::load('roles.json');
   Data::load('users.json');

   return { 'name' => $name };
}

1;
