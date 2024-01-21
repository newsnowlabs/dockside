# Profile.pm

# A Profile object, which can be constructed:
#
# 1. By Reservation->new(), when instantiating the encapsulated Profile data structure for a Reservation record
#    loaded from the database;
# 2. By the Data package, which loads the available profiles from the filesystem and stores them in the $PROFILES
#    package global object for later retrieval by Profile->load.

package Profile;

use strict;

use JSON;
use Storable;
use Data qw($CONFIG);
use Util qw(flog TO_JSON);

################################################################################
# CURRENT VERSION
# ---------------

sub CURRENT_VERSION {
   return 3;
}

##################
# VERSION UPGRADES
# ----------------

sub versionUpgrade {
   my $self = shift;

   if($self->version == 0) {
      if(my $routers = delete $self->{'proxy'}) {
         $self->{'routers'} = $routers;
      }
      $self->{'version'}++;
   }

   if($self->version == 1) {
      if(my $unixusers = delete $self->{'users'}) {
         $self->{'unixusers'} = $unixusers;
      }

      if(my $routers = $self->{'routers'}) {
         for(my $i = 0; $i < @$routers; $i++) {
            $routers->[$i]{'name'} //= $routers->[$i]{'prefixes'}[0] // "router-$i";
            if($routers->[$i]{'auth'}) {
               if(ref($routers->[$i]{'auth'}) ne 'ARRAY') {
                  # Set permissible array of auth modes to just the predefined default.
                  $routers->[$i]{'auth'} = ($routers->[$i]{'type'} =~ /^(ide|ssh)$/) ? [ 'owner', 'developer' ] : [ 'user', 'developer', 'public', 'viewer', 'owner' ];
               }
               # else allow current setting.
            }
            else {
               # Define default auth options, if none specified in the profile
               $routers->[$i]{'auth'} = [ 'owner', 'developer' ];
            }
         }
      }

      $self->{'version'}++;
   }

   if($self->version == 2) {
      $self->{'runtimes'} = ['runc'] unless $self->{'runtimes'} && @{$self->{'runtimes'}} > 0;
      $self->{'unixusers'} = ['dockside'] unless $self->{'unixusers'} && @{$self->{'unixusers'}} > 0;

      # If unspecified in profile, set to value of config.json default, or true.
      $self->{'ssh'} //= $CONFIG->{'ssh'}{'default'} // 1;

      $self->{'version'}++;
   }

}

################################################################################
# CONFIGURE PACKAGE GLOBALS
# -------------------------

our $PROFILES;

sub Configure {
   $PROFILES = $_[0];
}

################################################################################
# SIMPLE ACCESSORS
# ----------------

sub errors {
   my $self = shift;

   push( @{ $self->{'errors'} }, [@_] );

   return undef;
}

sub name {
   return $_[0]->{'name'};
}

sub version {
   return $_[0]->{'version'};
}

################################################################################
# CONSTRUCTORS AND CLASS METHODS
# ------------------------------

sub names {
   return keys %$PROFILES;
}

sub load {
   my $class = shift;
   my $profile = shift;

   return $PROFILES->{$profile};
}

sub new {
   my $class = shift;
   my $data  = shift;
   my $validated = shift;

   # Decode JSON if needed.
   if(!ref($data)) {
      $data = decode_json($data);
   }

   my $self = bless { %$data }, ( ref($class) || $class );

   $self->versionUpgrade();

   return $self if $validated;

   $self->validate();

   # Add the IDE router, if none specified
   if( ! grep { $_->{'type'} eq 'ide' } @{$self->{'routers'}} ) {
      push(@{$self->{'routers'}}, {
         "name" => 'ide',
         "type" => 'ide',
         "auth" => ['developer', 'owner'],
         "prefixes" => ["ide"],
         "domains" => ["*"],
         "https" => {
            "protocol" => "http", 
            # FIXME: Change to port => $self->spare_port(), once this can be passed to
            # the container IDE launch script.
            "port" => 3131
         },
      });
   }

   # Add the SSH router, if none specified.
   # N.B. Updating config.json .ssh property WON'T cause this to re-evaluate,
   # not without reloading all profiles.
   if( $self->{'ssh'} && ! grep { $_->{'type'} eq 'ssh' } @{$self->{'routers'}} ) {
      push(@{$self->{'routers'}}, {
         "name" => 'ssh',
         "type" => 'ssh',
         "auth" => ['developer', 'owner'],
         "prefixes" => ["ssh"],
         "domains" => ["*"],
         "https" => {
            "protocol" => "http", 
            "port" => $CONFIG->{'ssh'}{'port'}
         },
      });
   }

   return $self;
}

################################################################################
# VALIDATORS
# ----------

sub validate {
   my $self = shift;

   # Parse/validate data keys one by one, recursively decending with each.

   return undef unless $self->{'active'};

   # A list of allowed properties: a trailing '!' indicates the property is mandatory.
   $self->do_validate( '', $self, qw( name! version! description active! mountIDE routers runtimes networks! images! unixusers imagePathsFilter mounts runDockerInit dockerArgs command entrypoint metadata lxcfs ssh security ) );

   return $self;
}

# Validate an Object (not an Array)
# @props is array of expected properties: '!' denotes a mandatory field
sub do_validate {
   my $self  = shift;
   my $type  = shift;
   my $data  = shift;
   my @props = @_;

   my $propsString = join( ', ', @props );

   my $propsRE = join( '|', map { s/[\?\!]//; $_; } @props );

   unless( ref($data) eq 'HASH' || ref($data) eq __PACKAGE__ ) {
      return $self->errors( $type, "'$type' must be an Object with the following properties: $propsString" );
   }

   foreach my $prop ( sort keys %$data ) {

      # Check the proposed 'prop' is allowed.
      unless( $prop =~ /^(?:$propsRE)$/ ) {
         $self->errors( $type, sprintf( 'property "%s" unknown, must be one of: %s', $prop, $propsString ) );
         next;
      }

      my $sub = 'validate_' .

        # Substitute 'profile' for the first element of the $type string.
        # FIXME: If we're keeping this code, let's lose the 'profile' from each sub name.
        join( '_', 'profile', splice( @{ [ split( /\./, $type ) ] }, 1 ) ) . "_$prop";

      # Remove '[0]', '[1]', etc.
      $sub =~ s/\[\d+\]//g;

      # Replace '-' with '_'.
      # OR FIXME: remove all non-perl-sub-name chars from profiles.json property names.
      $sub =~ s/[^a-zA-Z0-9_]+//g;

      # Uncomment to debug:
      # flog("Profile::do_validate: type=$type; prop=$prop; can($sub)?");

      next unless $self->can($sub);

      # Type-property validation
      $self->$sub( "$type.$prop", $data->{$prop} );
   }

   foreach my $prop ( @props ) {
      # Check the proposed 'prop' is allowed.
      if( $prop =~ /\!$/ && !exists($data->{$prop}) ) {
         $self->errors( $type, sprintf( 'property "%s" not found but must be specified', $prop ) );
         next;
      }
   }   
}

sub validate_profile_mounts_tmpfs_dst {
   my $self = shift;
   my $type = shift;
   my $data = shift;

   my $dstRE = '^/';

   $self->errors( $type, "must specify a <dst>" ) unless $data;
   $self->errors( $type, "must specify a <dst> matching /$dstRE/" ) unless $data =~ /$dstRE/;
}

sub validate_profile_mounts_tmpfs {
   my $self = shift;
   my $type = shift;
   my $data = shift;

   # FIXME:
   # Checking that we have an Array,
   # and looping through the Array elements,
   # is standard logic for Arrays in the data model.
   #
   # Should we abstract them back to do_validate?
   #
   # If so, we need to can() and call two subs:
   # - one for each Array element (e.g. ${type}_Instance or $type)
   # - one for the whole Array - that just checks we have the required Array elements - (e.g. $type or $type_Array)

   unless( ref($data) eq 'ARRAY' ) {
      return $self->errors( $type, "must be an Array" );
   }

   for( my $i = 0; $i < @$data; $i++ ) {
      $self->do_validate( "$type\[$i\]", $data->[$i], 
         qw( dst! tmpfs-size tmpfs-mode tmpfs-uid tmpfs-gid tmpfs-noexec tmpfs-nosuid tmpfs-nodev )
      );
   }
}

sub validate_profile_mounts {
   my $self = shift;
   my $type = shift;
   my $data = shift;

   $self->do_validate( $type, $data, qw( tmpfs bind volume ) );
}

sub validate_profile_routers {
   my $self = shift;
   my $type = shift;
   my $data = shift;

   unless( ref($data) eq 'ARRAY' ) {
      return $self->errors( $type, "must be an Array" );
   }

   for( my $i = 0; $i < @$data; $i++ ) {
      $self->do_validate( "$type\[$i\]", $data->[$i], qw( name type auth prefixes! domains! http https ) );

      # Choose a name, if none provided.
      $data->[$i]{'name'} //= $data->[$i]{'prefixes'}[0] // "router-$i";

      # Assign default permitted authorisation modes, if none provided.
      $data->[$i]{'auth'} //= [ 'owner', 'developer' ];
   }
}

sub validate_profile_unixusers {
   my $self = shift;
   my $type = shift;
   my $data = shift;

   unless( ref($data) eq 'ARRAY' && @$data >= 1 ) {
      return $self->errors( $type, "must be an Array with at least one username string" );
   }

   my $userRE = '^[a-z_][a-z0-9_-]*$';

   my $i = 0;
   foreach my $user (@$data) {
      if( ref($user) ) {
         $self->errors( "$type\[$i\]", "must be a string" );
         next;
      }

      $self->errors( "$type\[$i\]", "'$user' must match /$userRE/" ) unless $user =~ /$userRE/;
   }
   continue {
      $i++;
   }
}

sub validate_profile_security {
   my $self = shift;
   my $type = shift;
   my $data = shift;

   $self->do_validate( $type, $data, qw( apparmor seccomp no-new-privileges labels ) );

   if($data->{'labels'}) {
      if( ref($data->{'labels'}) eq 'HASH' ) {
         $self->do_validate( "$type.labels", $data->{'labels'}, qw( user role type level ) );
      }
      elsif( $data->{'labels'} ne 'disable' ) {
         $self->errors( "$type.labels", "must be the string 'disable' or an Object with keys 'user', 'role', 'type', 'level'" );
      }
   }

   if( defined($data->{'no-new-privileges'}) && $data->{'no-new-privileges'} !~ /^[01]$/ ) {
      $self->errors( "$type.no-new-privileges", "must be true or false or '1' or '0', if defined" );
   }
}

################################################################################
# DATA ACCESSORS
# --------------

sub runtimes {
   return $_[0]->{'runtimes'} // [];
}

sub networks {
   return $_[0]->{'networks'} // [];
}

sub images {
   return $_[0]->{'images'} // [];
}

sub unixusers {
   return $_[0]->{'unixusers'} // [];
}

sub routers {
   return $_[0]->{'routers'} // [];
}

sub ssh {
   return $_[0]->{'ssh'};
}

# Test if Profile property $type contains (or encompasses) value $value.
# Returns 0 if not, non-0 if so.

sub has {
   my $self = shift;
   my $type = shift;
   my $value = shift;

   my $array;
   if($type eq 'image') {
      $array = $self->images;

      # If $value does not match at least one Profile image or image pattern, reject it.
      return 0 unless scalar(
         grep { $value =~ /^${_}$/ }
         map {
            my $imageRegex = quotemeta($_);
            $imageRegex =~ s/\\\*/\.\*/g;
            $imageRegex;
         } @$array
      );

      # my $imageConstraints = $self->{'imageConstraints'};
      #
      # # Order user's image resource constraints by specificity
      # # i.e. (number of non-wildcard characters), descending.
      # my @orderedImageConstraints =
      #    sort {
      #       my $A = $a; $A =~ s/\*+//g;
      #       my $B = $b; $B =~ s/\*+//g;
      #       length($B) <=> length($A);
      #    } keys %$imageConstraints;
      #
      # # If $value matches a user's $imageConstraint, allow/deny according to the constraint.
      # foreach my $imageConstraint (@orderedImageConstraints) {
      #    my $imageConstraintRegex = quotemeta($imageConstraint);
      #    $imageConstraintRegex =~ s/(\\\*)+/\.\*/g;
      #    if( $value =~ /^${imageConstraintRegex}$/ ) {
      #
      #       # We matched this constraint; but did it map to true or false?
      #       # If true, we allow the image.
      #       # If false, we don't.
      #       return $imageConstraints->{$imageConstraint};
      #    }
      # }
      # return 0;

      return 1;
   }
   elsif($type eq 'runtime') {
      $array = $self->runtimes;
   }
   elsif($type eq 'network') {
      $array = $self->networks;
   }
   elsif($type eq 'unixuser') {
      $array = $self->unixusers;
   }
   elsif($type eq 'router') {
      $array = [ map { $_->{'type'} } @{$self->routers} ];
   }

   return scalar(grep { $_ eq $value } @$array);
}

sub spare_port {
   my $self = shift;

   my $ports = $self->ports_hash();

   for( my $port = 1024; $port < 32768; $port++ ) {
      return $port unless $ports->{$port};
   }

   return undef;
}

sub ports_hash {
   my %ports;

   # Compile a unique list of private exposed ports for the profile.
   foreach my $router (@{ $_[0]->routers } ) {
      foreach my $protocol (qw( http https )) {
         $ports{ $router->{$protocol}{'port'} }++ if exists $router->{$protocol}{'port'};
      }
   }

   return \%ports;
}

sub ports {
   my $ports = $_[0]->ports_hash();

   return keys %$ports;
}

################################################################################
# DEFAULTS DATA ACCESSORS
# -----------------------

sub default_runtime {
   my $self = shift;

   die "No default runtime available\n" unless @{$self->{'runtimes'}};

   return $self->{'runtimes'}[0];
}

sub default_network {
   my $self = shift;

   die "No default network found\n" unless @{$self->{'networks'}};

   return $self->{'networks'}[0];
}

sub default_unixuser {
   my $self = shift;

   die "No default unixuser found\n" unless
      $self->{'unixusers'} && @{$self->{'unixusers'}};

   return $self->{'unixusers'}[0];
}

sub default_image {
   my $self = shift;

   my @nonWildcardImages = grep { !/\*/ } @{$self->{'images'}};
   return $nonWildcardImages[0] if @nonWildcardImages;

   die "No default image found\n";
}

sub default_command {
   my $self = shift;

   if(ref($self->{'command'}) eq 'ARRAY') {
      return @{$self->{'command'}};
   }

   if($self->{'command'} ne '') {
      return ($self->{'command'});
   }

   return ();
}

sub entrypoint {
   my $self = shift;

   return ref($self->{'entrypoint'}) eq 'ARRAY' ? join(' ', @{$self->{'entrypoint'}}) : $self->{'entrypoint'};
}

sub should_mount_ide {
   my $self = shift;

   return 1 unless exists($self->{'mountIDE'}) && $self->{'mountIDE'} == 0;

   return 0;
}

sub run_docker_init {
   my $self = shift;

   return (exists($self->{'runDockerInit'}) && $self->{'runDockerInit'} == 0) ? 0 : 1;
}

sub has_lxcfs_enabled {
   my $self = shift;

   # Disabled unless lxcfs.mountpoints[] specified in config.json.
   return 0 unless $CONFIG->{'lxcfs'} && ref($CONFIG->{'lxcfs'}{'mountpoints'}) eq 'ARRAY'
      && $CONFIG->{'lxcfs'}{'available'} == 1;

   # If lxcfs.default === true in config.json, disable if profile lxcfs === false
   if( $CONFIG->{'lxcfs'}{'default'} == 1 ) {
      return 0 if exists($self->{'lxcfs'}) && $self->{'lxcfs'} == 0;
   }
   # If lxcfs.default === false in config.json, disable unless profile lxcfs === true
   elsif( $CONFIG->{'lxcfs'}{'default'} == 0 ) {
      return 0 unless exists($self->{'lxcfs'}) && $self->{'lxcfs'} == 1;
   }

   return 1;
}

################################################################################
# CLONE WITH CONSTRAINTS AND SANITISE
# -----------------------------------

# Create and return a sanitised copy of the Profile object.
# Inputs:
# - A Profile object
# - A set of constraints for removing unauthorised resources from the embedded Profile object
# Outputs:
# - A cloned Profile object, with unauthorised resources removed, augmented with 'imageConstraints'.

sub cloneWithConstraints {
   my $self = shift;
   my $constraints = shift;

   my $clone = Storable::dclone($self);

   return $clone->applyConstraints($constraints);
}

sub applyConstraints {
   my $self = shift;
   my $constraints = shift;

   foreach my $resourceType (qw( runtimes networks auth images )) {

      # This constraint is defined in User->updateDerivedResourceConstraints.
      # It is assumed all required constraints will have been generated.
      my $resourceConstraints = $constraints->{$resourceType};

      if($resourceType eq 'auth') {

         my $routers;
         foreach my $router (@{$self->routers}) {
            $router->{'auth'} = [
               grep { $resourceConstraints->{$_} // $resourceConstraints->{'*'} } @{$router->{'auth'}}
            ];
         }
      }
      elsif($resourceType eq 'images') {
         $self->{'imageConstraints'} = $resourceConstraints;
      }
      else {
         $self->{$resourceType} = [
            grep { $resourceConstraints->{$_} // $resourceConstraints->{'*'} } @{$self->{$resourceType}}
         ];
      }
   }

   return $self;
}

sub sanitise {
   my $self = shift;

   foreach my $key (qw( active mounts runDockerInit metadata command entrypoint )) {
      delete $self->{$key};
   }

   return $self;
}

################################################################################
# ERRORS
# -----------------------

sub errorsArray {
   my $self = shift;

   return map { $_ = ($_->[0] ? "in '$_->[0]', " : '') . $_->[1] } @{ $self->{'errors'} };
}

1;
