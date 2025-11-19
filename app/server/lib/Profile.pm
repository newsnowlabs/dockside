# Profile.pm

# A Profile object, which can be constructed:
#
# 1. By Reservation->new(), when instantiating the encapsulated Profile data structure for a Reservation record
#    loaded from the database;
# 2. By the Data package, which loads the available profiles from the filesystem and stores them in the $PROFILES
#    package global object for later retrieval by Profile->load.

package Profile;

use v5.36;

use JSON;
use Storable qw(dclone);
use Data qw($CONFIG);
use Util qw(flog TO_JSON);

################################################################################
# CURRENT VERSION
# ---------------

sub CURRENT_VERSION () {
   return 4;
}

##################
# VERSION UPGRADES
# ----------------

sub versionUpgrade ($self) {
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
      $self->{'runtimes'} = ['runc'] unless defined($self->{'runtimes'}) && (ref($self->{'runtimes'}) eq 'ARRAY') && @{$self->{'runtimes'}} > 0;
      $self->{'unixusers'} = ['dockside'] unless defined($self->{'unixusers'}) && (ref($self->{'unixusers'}) eq 'ARRAY') && @{$self->{'unixusers'}} > 0;

      # If unspecified in profile, set to value of config.json default, or true.
      $self->{'ssh'} //= $CONFIG->{'ssh'}{'default'} // 1;

      $self->{'version'}++;
   }

   if($self->version == 3) {
      $self->{'IDEs'} = $CONFIG->{'ide'}{'IDEs'} unless defined($self->{'IDEs'});
      $self->{'entrypoint'} = [ $self->{'entrypoint'} ] if $self->{'entrypoint'} && !ref($self->{'entrypoint'});

      $self->{'version'}++;
   }
}

sub applyDefaults ($self) {
   if(my $routers = $self->{'routers'}) {
      for(my $i = 0; $i < @$routers; $i++) {
         $routers->[$i]{'name'} //= $routers->[$i]{'prefixes'}[0] // "router-$i";

         # Define default auth options, if none specified in the profile
         $routers->[$i]{'auth'} //= [ 'owner', 'developer' ];

         # Default type
         $routers->[$i]{'type'} //= '';
      }
   }
}

################################################################################
# CONFIGURE PACKAGE GLOBALS
# -------------------------

our $PROFILES;

sub Configure ($profiles) {
   $PROFILES = $profiles;
}

################################################################################
# SIMPLE ACCESSORS
# ----------------

sub errors ($self, @error) {
   push( @{ $self->{'errors'} }, [@error] );

   return undef;
}

sub name ($self) {
   return $self->{'name'};
}

sub version ($self) {
   return $self->{'version'};
}

################################################################################
# CONSTRUCTORS AND CLASS METHODS
# ------------------------------

sub names ($class) {
   return keys %$PROFILES;
}

sub load ($class, $profile) {
   return $PROFILES->{$profile};
}

sub new ($class, $data, $validated = 0) {
   # Decode JSON if needed.
   if(!ref($data)) {
      $data = decode_json($data);
   }

   my $self = bless { %$data }, ( ref($class) || $class );

   $self->versionUpgrade();
   $self->applyDefaults();

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

sub validate ($self) {
   # Parse/validate data keys one by one, recursively decending with each.

   return undef unless $self->{'active'};

   # A list of allowed properties: a trailing '!' indicates the property is mandatory.
   $self->do_validate(
      '',
      dclone($self),
      qw(
         name=s!
         version=s!
         description=s
         active=b!
         mountIDE=b
         routers=@
         runtimes=@
         networks=@!
         images=@!
         unixusers=@
         imagePathsFilter=@
         mounts=%
         runDockerInit=b
         dockerArgs=@
         command=@
         entrypoint=@
         metadata
         lxcfs=b
         ssh=b
         security=%
         gitURLs=@
         IDEs=@
      )
   );

   return $self;
}

sub _parse_props ($propcodes) {
   my $propsLookup;

   foreach my $propNcode ( @$propcodes ) {
      # Split propNcode into name and code strings
      my ($prop, $codestring) = $propNcode =~ /^([^=]+)(?:=(.*))?$/;
      my %codesLookup;

      # Split code string into an array of 1-char strings
      my @codes = split( //, $codestring // '' );

      # Covert the code array into a hash lookup
      @codesLookup{@codes} = (1) x scalar(@codes);

      $propsLookup->{$prop} = \%codesLookup;
   }

   return $propsLookup;
}

# Validate an Object (not an Array)
# @props is array of expected properties: '!' denotes a mandatory field
sub do_validate ($self, $type, $data, @propcodes) {
   my $props = _parse_props(\@propcodes);
   my @propList = sort { lc($a) cmp lc($b) } keys %$props;
   my $propsString = join( ', ', @propList );
   my $propsRE = join( '|', @propList );

   # This sub only validates Objects, so check passed data is a hash or blessed hash of this package.
   unless( ref($data) eq 'HASH' || ref($data) eq __PACKAGE__ ) {
      return $self->errors( $type, "'$type' must be a JSON Object with the following properties: $propsString" );
   }

   # Check each mandatory 'prop' has been specified.
   foreach my $prop ( @propList ) {
      if( $props->{$prop}->{'!'} && !exists($data->{$prop}) ) {
         $self->errors( $type, sprintf( 'mandatory property "%s" not found', $prop ) );
         next;
      }
   }

   # Check each prop in supplied data
   foreach my $prop ( sort { $a cmp $b } keys %$data ) {

      # Skip the 'errors' pseudo-property
      next if $prop eq 'errors';

      # Check the proposed 'prop' is allowed.
      unless( $prop =~ /^(?:$propsRE)$/ ) {
         $self->errors( $type, sprintf( 'property "%s" unknown, must be one of: %s', $prop, $propsString ) );
         next;
      }

      if( $props->{$prop}->{'@'} && ref($data->{$prop}) ne 'ARRAY' ) {
         $self->errors( $type, sprintf( 'property "%s" must be JSON type Array', $prop ) );
         next;
      }

      if( $props->{$prop}->{'%'} && ref($data->{$prop}) ne 'HASH' ) {
         $self->errors( $type, sprintf( 'property "%s" must be JSON type Object', $prop ) );
         next;
      }

      if( $props->{$prop}->{'b'} && $data->{$prop} != 0 && $data->{$prop} != 1 ) {
         $self->errors( $type, sprintf( 'property "%s" must be JSON type Boolean, not %s', $prop, $data->{$prop} ) );
         next;
      }

      if( $props->{$prop}->{'s'} && ref($data->{$prop}) ) {
         $self->errors( $type, sprintf( 'property "%s" must be JSON type String', $prop ) );
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

}

sub validate_profile_IDEs ($self, $type, $data) {
   unless( ref($data) eq 'ARRAY' ) {
      return $self->errors( $type, "must be an Array" );
   }
}

sub validate_profile_mounts_tmpfs_dst ($self, $type, $data) {
   my $dstRE = '^/';

   $self->errors( $type, "must specify a <dst>" ) unless $data;
   $self->errors( $type, "must specify a <dst> matching /$dstRE/" ) unless $data =~ /$dstRE/;
}

sub validate_profile_mounts_tmpfs ($self, $type, $data) {
   unless( ref($data) eq 'ARRAY' ) {
      return $self->errors( $type, "must be an Array" );
   }

   for( my $i = 0; $i < @$data; $i++ ) {
      $self->do_validate( "$type\[$i\]", $data->[$i], 
         qw( dst=s! tmpfs-size=s tmpfs-mode=s tmpfs-uid=s tmpfs-gid=s tmpfs-noexec=b tmpfs-nosuid=b tmpfs-nodev=b )
      );
   }
}

sub validate_profile_mounts_bind ($self, $type, $data) {
   unless( ref($data) eq 'ARRAY' ) {
      return $self->errors( $type, "must be an Array" );
   }

   for( my $i = 0; $i < @$data; $i++ ) {
      $self->do_validate( "$type\[$i\]", $data->[$i], 
         qw( dst=s! src=s! readonly=b )
      );
   }
}

sub validate_profile_mounts_volume ($self, $type, $data) {
   unless( ref($data) eq 'ARRAY' ) {
      return $self->errors( $type, "must be an Array" );
   }

   for( my $i = 0; $i < @$data; $i++ ) {
      $self->do_validate( "$type\[$i\]", $data->[$i], 
         qw( dst=s! src=s readonly=b )
      );
   }
}

sub validate_profile_mounts ($self, $type, $data) {
   $self->do_validate( $type, $data, qw( tmpfs bind volume ) );
}

sub validate_profile_routers ($self, $type, $data) {
   unless( ref($data) eq 'ARRAY' ) {
      return $self->errors( $type, "must be an Array" );
   }

   for( my $i = 0; $i < @$data; $i++ ) {
      $self->do_validate( "$type\[$i\]", $data->[$i], qw( name=s type=s auth=@ prefixes=@! domains=@! http=% https=% ) );
   }
}

sub validate_profile_unixusers ($self, $type, $data) {
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

sub validate_profile_security ($self, $type, $data) {
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

sub runtimes ($self) {
   return $self->{'runtimes'} // [];
}

sub networks ($self) {
   return $self->{'networks'} // [];
}

sub images ($self) {
   return $self->{'images'} // [];
}

sub gitURLs ($self) {
   return $self->{'gitURLs'} // [];
}

sub IDEs ($self) {
   return $self->{'IDEs'} // [];
}

sub unixusers ($self) {
   return $self->{'unixusers'} // [];
}

sub routers ($self) {
   return $self->{'routers'} // [];
}

sub ssh ($self) {
   return $self->{'ssh'};
}

# Test if Profile property $type contains (or encompasses) value $value.
# Returns 0 if not, non-0 if so.

sub has ($self, $type, $value = '') {
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
   elsif($type eq 'gitURL') {

      $array = $self->gitURLs;

      if( @$array == 0 ) {
         return 1 if $value eq '';
         return 0;
      }

      return 0 if $value eq '';

      # If $value does not match at least one Profile gitURL or gitURL pattern, reject it.
      return 0 unless scalar(
         grep { $value =~ /^${_}$/ }
         map {
            my $gitURLRegex = quotemeta($_);
            $gitURLRegex =~ s/\\\*/\.\*/g;
            $gitURLRegex;
         } @$array
      );

      return 1;
   }
   elsif($type eq 'runtime') {
      $array = $self->runtimes;
   }
   elsif($type eq 'network') {
      $array = $self->networks;
   }
   elsif($type eq 'IDE') {
      $array = $self->IDEs;
   }
   elsif($type eq 'unixuser') {
      $array = $self->unixusers;
   }
   elsif($type eq 'router') {
      $array = [ map { $_->{'type'} } @{$self->routers} ];
   }

   return scalar(grep { $_ eq $value } @$array);
}

sub spare_port ($self) {
   my $ports = $self->ports_hash();

   for( my $port = 1024; $port < 32768; $port++ ) {
      return $port unless $ports->{$port};
   }

   return undef;
}

sub ports_hash ($self) {
   my %ports;

   # Compile a unique list of private exposed ports for the profile.
   foreach my $router (@{ $self->routers } ) {
      foreach my $protocol (qw( http https )) {
         $ports{ $router->{$protocol}{'port'} }++ if exists $router->{$protocol}{'port'};
      }
   }

   return \%ports;
}

sub ports ($self) {
   my $ports = $self->ports_hash();

   return keys %$ports;
}

################################################################################
# DEFAULTS DATA ACCESSORS
# -----------------------

sub default_runtime ($self) {
   die "No default runtime available\n" unless @{$self->{'runtimes'}};

   return $self->{'runtimes'}[0];
}

sub default_network ($self) {
   die "No default network found\n" unless @{$self->{'networks'}};

   return $self->{'networks'}[0];
}

sub default_unixuser ($self) {
   die "No default unixuser found\n" unless
      $self->{'unixusers'} && @{$self->{'unixusers'}};

   return $self->{'unixusers'}[0];
}

sub default_image ($self) {
   my @nonWildcardImages = grep { !/\*/ } @{$self->{'images'}};
   return $nonWildcardImages[0] if @nonWildcardImages;

   die "No default image found\n";
}

sub default_gitURL ($self) {
   my @nonWildcardGitURLs = grep { !/\*/ } @{$self->{'GitURLs'}};
   return $nonWildcardGitURLs[0] if @nonWildcardGitURLs;

   # Default gitURL is '' if none is specified
   return '';
}

sub default_IDE ($self) {
   return $self->{'IDEs'}[0] if @{$self->{'IDEs'}};

   # Default IDE is '' if none is specified
   return '';
}

sub default_command ($self) {
   if(ref($self->{'command'}) eq 'ARRAY') {
      return @{$self->{'command'}};
   }

   if($self->{'command'} ne '') {
      return ($self->{'command'});
   }

   return ();
}

sub entrypoint ($self) {
   return ref($self->{'entrypoint'}) eq 'ARRAY' ? join(' ', @{$self->{'entrypoint'}}) : $self->{'entrypoint'};
}

sub should_mount_ide ($self) {
   return 1 unless exists($self->{'mountIDE'}) && $self->{'mountIDE'} == 0;

   return 0;
}

sub run_docker_init ($self) {
   return (exists($self->{'runDockerInit'}) && $self->{'runDockerInit'} == 0) ? 0 : 1;
}

sub has_lxcfs_enabled ($self) {
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

sub cloneWithConstraints ($self, $constraints) {
   my $clone = dclone($self);

   return $clone->applyConstraints($constraints);
}

sub applyConstraints ($self, $constraints) {
   foreach my $resourceType (qw( runtimes networks auth images IDEs )) {

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

sub sanitise ($self) {
   foreach my $key (qw( active mounts runDockerInit metadata command entrypoint )) {
      delete $self->{$key};
   }

   return $self;
}

################################################################################
# ERRORS
# -----------------------

sub errorsArray ($self) {
   return map { $_ = ($_->[0] ? "in '$_->[0]', " : '') . $_->[1] } @{ $self->{'errors'} };
}

1;
