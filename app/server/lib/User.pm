package User;

use strict;

use JSON;
use Try::Tiny;
use URI::Escape;
use Storable;
use Data qw($CONFIG);
use Util qw(flog wlog TO_JSON generate_auth_cookie_values);
use Reservation;

################################################################################
# CURRENT VERSION
# ---------------

sub CURRENT_VERSION {
   return 1;
}

##################
# VERSION UPGRADES
# ----------------

sub versionUpgrade {
   my $self = shift;

   if($self->version == 0) {
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
   'developAllContainers' # Permission to develop all containers irrespective of ownership or named developers
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

sub ConfigurePasswd {
   $USER_PASSWD = $_[0];
}

# Optionally, update the $USERS package global of User object.
# Then update the derived permissions for each User object.
sub ConfigureUsers {
   if($_[0]) {
      $USERS = $_[0];
   }

   foreach my $user (values %$USERS) {
      $user->updateDerivedPermissions();
      $user->updateDerivedResourceConstraints();
   }
}

sub ConfigureRoles {
   $ROLES = $_[0];
}

################################################################################
# CLASS METHODS
#

# To retrieve preloaded User object: User->load($username)
# To merge clone of preloaded User object into existing User object: $User->load($username)

sub load {
   my $self = shift;
   my $username = shift;

   return undef unless $USERS->{$username};

   if(ref($self)) {
      my $user = Storable::dclone($USERS->{$username});

      %$self = %$user;
   }

   return $USERS->{$username};
}

sub viewers {
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

sub new {
   my $class = shift;
   my $data = shift;

   my $self;

   # Decode JSON if needed.
   if(defined($data)) {
      if(!ref($data)) {
         $data = decode_json($data);
      }

      # Require a username
      return undef unless $data->{'username'};

      $self = bless { 
         %$data{ qw(username id name email role secrets) },
         '_permissions' => $data->{'permissions'} // {},
         '_resources' => $data->{'resources'} // {},
      }, ( ref($class) || $class );

      $self->updateDerivedPermissions();
      $self->updateDerivedResourceConstraints();

      # $self->versionUpgrade();

      return $self;
   }

   # Empty User object represents a dummy client.
   return bless {}, ( ref($class) || $class );
}

################################################################################
# AUTHENTICATION
#

# Returns: array of cookies (https, http) suitable for authenticating user.
sub generate_auth_cookies {
   my $self = shift;
   my $host = shift;

   return generate_auth_cookie_values( $CONFIG->{'uidCookie'}{'name'}, $CONFIG->{'uidCookie'}{'salt'}, $host, $self->signable() );
}

################################################################################
# ACCESSORS
# ---------

sub version {
   return $_[0]->{'version'};
}

sub username {
   return $_[0]->{'username'};
}

sub role {
   return $_[0]->{'role'};
}

# This sub must match that of same name in UserTagsInput.vue
sub role_as_meta {
   return $_[0]->role() ? ('role:' . $_[0]->role()) : undef;
}

# FIXME: Rename to derivedPermissions
sub permissions {
   return $_[0]->{'derivedPermissions'};
}

sub derivedResourceConstraints {
   return $_[0]->{'derivedResourceConstraints'};
}

sub signable {
   return { 'name' => $_[0]->username() };
}

sub details {
   my $self = shift;

   return { %$self{'username', 'id', 'name', 'email'} };
}

sub details_full {
   my $self = shift;

   return { %$self{'username', 'id', 'name', 'email', 'secrets'} };
}

sub password {
   my $self = shift;

   return $USER_PASSWD->{$self->username};
}

sub passwordDefined {
   my $self = shift;

   return defined($USER_PASSWD->{$self->username});
}

sub authorized_keys {
   my $self = shift;

   return $self->{'secrets'}{'ssh'}{'authorized_keys'} // [];
}

################################################################################
# MUTATORS
# --------

sub authstate {
   my $self = shift;
   my $auth = shift;

   if(@_ == 0) {
      return $self->{'_authstate'}{$auth};
   }

   if(my $value = shift) {
      $self->{'_authstate'}{$auth} = $value;
   }

   return $self;
}

################################################################################
# CONSTRUCTOR HELPERS
#

sub updateDerivedPermissions {
   my $self = shift;

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
      if($permissions{$permission} eq '0') {
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
sub updateDerivedResourceConstraints {
   my $self = shift;

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
   foreach my $resourceType (qw( profiles runtimes networks auth images )) {

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

sub has_permission {
   my $self = shift;
   my $permission = shift;    # permission name

   return $self->{'derivedPermissions'}{$permission};
}

# Evaluates the User's authorisation to act on a specified container,
# given:
# - the type of action (view, develop or keepPrivate); and
# - the User's specific permissions and their relationship to the specified container
#   i.e. named owner, named developer, or named viewer.
sub can_on {
   my $self = shift;
   my $container  = shift;    # Reservation object
   my $action = shift;    # 'view' | 'develop' | 'keepPrivate'

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

sub can_use_resource {
   my $self = shift;
   my $resourceType = shift;
   my $resource = shift;

   my $resources = $self->derivedResourceConstraints;

   return $resources->{$resourceType} &&
      ($resources->{$resourceType}{$resource} // $resources->{$resourceType}{'*'});
}

####################################################################################################
#
# Query resources accessible to the user
#

sub profiles {
   my $self = shift;

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
sub reservationPermissions {
   my $self = shift;
   my $reservation = shift;

   my $permittedAuth = $self->username ? {
      'owner' => ( $reservation->meta('owner') eq $self->username ) ? 1 : 0,
      'developer' => $self->can_on( $reservation, 'develop' ),
      'viewer' => $self->can_on( $reservation, 'view' ),
      'user' => 1
   } : {};

   $permittedAuth->{'containerCookie'} = (
      $reservation->{'meta'}{'secret'} ne '' &&
      $self->{'_authstate'}{'containerCookie'} =~ /\Q$reservation->{'meta'}{'secret'}\E/
      ) ? 1 : 0;

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
sub createClientReservation {
   my $self = shift;
   my $reservation = shift;

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

sub reservations {
   my $self = shift;
   my $opts = shift;

   # FIXME: if $opts->{'id'}, pass this into Reservation->load for efficiency.
   my $reservations = Reservation->load( {} );

   my $viewable = [];

   foreach my $reservation (@$reservations) {

      # Skip all but the specified reservation, if id provided.
      next if $opts->{'id'} && ($opts->{'id'} ne $reservation->{'id'});

      # Skip all but the specified reservation, if name provided.
      next if $opts->{'name'} && ($opts->{'name'} ne $reservation->{'name'});

      # Skip all reservations without an active container, if required.
      next if $opts->{'status'} eq 'hasRunnableContainer' && $reservation->{'status'} < 0;

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

sub reservation {
   my $self = shift;
   my $opts = (ref($_[0]) eq 'HASH') ? $_[0] : { 'id' => $_[0] }; shift;

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
sub set {
   my $self = shift;
   my $reservation = shift;
   my $property = shift;
   my $value = shift;

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

   if( $property eq 'image') {

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

   if( $property eq 'runtime') {

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

   return 1;
}

# Updates the metadata stored within a Reservation object
# Named in camelCase for consistency with current REST API call.
sub updateContainerReservation {
   my $self = shift;
   my $args = shift;

   my $reservation = $self->reservation( $args->{'id'} );

   unless($reservation) {
      die Exception->new( 'msg' => "Reservation id '$args->{'id'}' not found" );
   }

   my $origReservation = Storable::dclone($reservation);

   # FIXME: We don't want to update data.network, when we change network; or do we?
   # FIXME: Should calling $reservation->data('network', <network>) call update_network?
   foreach my $m (qw(access viewers developers private network description)) {
      # Don't try and update arguments that don't exist or are undefined.
      if(defined($args->{$m})) {
         $self->set($reservation, $m, $args->{$m}) || 
            die Exception->new( 'msg' => "You have no permissions to set '$m' to '$args->{$m}' in this reservation" );
      }
   }

   # If we reach this point, the user was permitted to make the proposed changes,
   # which can now be stored;
   $reservation->store();

   # and then acted upon.
   $reservation->update_network();

   # Only update devtainer authorized_keys if relevant reservation fields change.
   if( $origReservation->meta('developers') ne $reservation->meta('developers') ||
      $origReservation->meta('access')->{'ssh'} ne $reservation->meta('access')->{'ssh'} ) {
      $reservation->exec('update_ssh_authorized_keys');
   }

   # Create a sanitised clone of the reservation object, before returning.
   return $self->createClientReservation($reservation);
}

# Stops, starts or removed a container.
# Named in camelCase for consistency with current REST API call.
sub controlContainer {
   my $self = shift;
   my $cmd = shift;
   my $id = shift;
   my $args = shift;

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
sub createContainerReservation {
   my $self = shift;
   my $args = shift;

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

   foreach my $m (qw(profile image runtime network unixuser access viewers developers private description)) {
      $self->set($reservation, $m, $args->{$m}) || 
         die Exception->new( 'msg' => "You have no permissions to set '$m' to '$args->{$m}' in this reservation" );
   }

   # Test if we can construct the command line; on failure, we'll throw an error.
   $reservation->cmdline();

   # Store, launch, and create a sanitised clone of the reservation object, before returning.
   return $self->createClientReservation( $reservation->store()->launch() );
}

1;
