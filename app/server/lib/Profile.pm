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
use Data qw($CONFIG $HOSTNAME $HOSTINFO);
use Util qw(flog TO_JSON);

################################################################################
# CURRENT VERSION
# ---------------

sub CURRENT_VERSION {
   return 4;
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
      $self->{'version'}++;
   }

   if($self->version == 2) {
      $self->{'version'}++;
   }

   if($self->version == 3) {
      $self->{'entrypoint'} = [ $self->{'entrypoint'} ] if $self->{'entrypoint'} && !ref($self->{'entrypoint'});
      $self->{'version'}++;
   }
}

sub applyDefaultsAndFilters {
   my $self = shift;

   my $applyFilters = sub {
      my $type = shift;
      my $items = shift;

      my %matched;
      foreach my $item (@$items) {
         next unless $self->has($type, $item);
         $matched{$item}++;
      }

      return [sort { $a cmp $b } keys %matched];
   };

   # Routers
   if(my $routers = $self->{'routers'}) {
      for(my $i = 0; $i < @$routers; $i++) {
         $routers->[$i]{'name'} //= $routers->[$i]{'prefixes'}[0] // "router-$i";

         # Define default auth options, if none specified in the profile, to
         # permissible array of auth modes, according to router type.
         $routers->[$i]{'auth'} //= ($routers->[$i]{'type'} =~ /^(ide|ssh)$/) ?
            [ 'owner', 'developer' ] : [ 'user', 'developer', 'public', 'viewer', 'owner' ];
      }
   }

   # Network
   my @hostNetworks = sort { $a cmp $b } grep { $_ ne 'dockside' } keys %{Containers->containers->{$HOSTNAME}{'inspect'}{'Networks'}};
   $self->{'networks'} = ["*"] unless defined($self->{'networks'});
   $self->{'networks'} = $applyFilters->('network', \@hostNetworks);
   flog("Profile::applyDefaultsAndFilters: networks=" . join(',', @{$self->{'networks'}}));

   # IDE
   $self->{'IDEs'} = ["*"] unless defined($self->{'IDEs'});
   $self->{'IDEs'} = $applyFilters->('IDE', $HOSTINFO->{'IDEs'});

   # Runtimes
   $self->{'runtimes'} = ["*"] unless defined($self->{'runtimes'});
   $self->{'runtimes'} = $applyFilters->('runtime', [keys %{$HOSTINFO->{'docker'}{'Runtimes'}}]);

   # unixusers
   $self->{'unixusers'} = ['dockside'] unless defined($self->{'unixusers'});

   # SSH
   # If unspecified in profile, set to value of config.json default, or true.
   $self->{'ssh'} //= $CONFIG->{'ssh'}{'default'} // 1;
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

   # Return early if already validated.
   if( $validated ) {
      return $self;
   }

   # Return early if not valid.
   # An 'errors' property will have been added to $self.
   if( !$self->validate ) {
      return $self;
   }

   # Apply defaults only after validation, as this process assumes a valid data structure.
   # TODO: Are any defaults or filters needed even for validated records?
   # TODO: Should defaults and filters be separated?
   $self->applyDefaultsAndFilters();

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
   $self->do_validate(
      '',
      Storable::dclone($self),
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

   return $self->{'errors'} ? 0 : 1;
}

sub _parse_props {
   my $propcodes = shift;

   my $propsLookup;

   foreach my $propNcode ( @$propcodes ) {
      # Split propNcode into name and code strings
      my ($prop, $codestring) = $propNcode =~ /^([^=]+)(?:=(.*))?$/;
      my %codesLookup;

      # Split code string into an array of 1-char strings
      my @codes = split( //, $codestring );

      # Covert the code array into a hash lookup
      @codesLookup{@codes} = (1) x scalar(@codes);

      $propsLookup->{$prop} = \%codesLookup;
   }

   return $propsLookup;
}

# Validate an Object (not an Array)
# @props is array of expected properties: '!' denotes a mandatory field
sub do_validate {
   my $self  = shift;
   my $type  = shift;
   my $data  = shift;
   my @propcodes = @_;

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

sub validate_profile_IDEs {
   my $self = shift;
   my $type = shift;
   my $data = shift;

   unless( ref($data) eq 'ARRAY' ) {
      return $self->errors( $type, "must be an Array" );
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

   unless( ref($data) eq 'ARRAY' ) {
      return $self->errors( $type, "must be an Array" );
   }

   for( my $i = 0; $i < @$data; $i++ ) {
      $self->do_validate( "$type\[$i\]", $data->[$i], 
         qw( dst=s! tmpfs-size=s tmpfs-mode=s tmpfs-uid=s tmpfs-gid=s tmpfs-noexec=b tmpfs-nosuid=b tmpfs-nodev=b )
      );
   }
}

sub validate_profile_mounts_bind {
   my $self = shift;
   my $type = shift;
   my $data = shift;

   unless( ref($data) eq 'ARRAY' ) {
      return $self->errors( $type, "must be an Array" );
   }

   for( my $i = 0; $i < @$data; $i++ ) {
      $self->do_validate( "$type\[$i\]", $data->[$i], 
         qw( dst=s! src=s! readonly=b )
      );
   }
}

sub validate_profile_mounts_volume {
   my $self = shift;
   my $type = shift;
   my $data = shift;

   unless( ref($data) eq 'ARRAY' ) {
      return $self->errors( $type, "must be an Array" );
   }

   for( my $i = 0; $i < @$data; $i++ ) {
      $self->do_validate( "$type\[$i\]", $data->[$i], 
         qw( dst=s! src=s readonly=b )
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
      $self->do_validate( "$type\[$i\]", $data->[$i], qw( name=s type=s auth=@ prefixes=@! domains=@! http=% https=% ) );
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

sub gitURLs {
   return $_[0]->{'gitURLs'} // [];
}

sub IDEs {
   return $_[0]->{'IDEs'} // [];
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
   }
   elsif($type eq 'gitURL') {
      $array = $self->gitURLs;
   
      # Optional prop: allowed to be '' only if no profile value(s)
      if( @$array == 0 && $value eq '' ) {
         return 1;
      }
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

   # Props allowing wildcard matching
   if($type =~ /^(image|gitURL|runtime|network|IDE)$/) {
      if( @$array == 0 || $value eq '' ) {
         return 0;
      }

      # If $value does not match at least one Profile element pattern, reject it.
      return 0 unless scalar(
         grep { $value =~ /^${_}$/ }
         map {
            my $regex = quotemeta($_);
            $regex =~ s/\\\*/\.\*/g;
            $regex;
         } @$array
      );

      return 1;
   }

   # Properties allowing only exact matching
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

sub default_gitURL {
   my $self = shift;

   my @nonWildcardGitURLs = grep { !/\*/ } @{$self->{'GitURLs'}};
   return $nonWildcardGitURLs[0] if @nonWildcardGitURLs;

   # Default gitURL is '' if none is specified
   return '';
}

sub default_IDE {
   my $self = shift;

   return $self->{'IDEs'}[0] if @{$self->{'IDEs'}};

   # Default IDE is '' if none is specified
   return '';
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
