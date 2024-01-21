package Reservation;

use strict;

use JSON;
use Expect;
use Try::Tiny;
use Tie::File;
use Storable;
use Reservation::Mutate qw(update load_clean_map);
use Reservation::Load;
use Reservation::Launch;
use Containers;
use Profile;
use Util qw(flog wlog get_config trim is_true clean_pty run run_pty TO_JSON YYYYMMDDHHMMSS cacheReadWrite call_socket_api unique run_system);
use Data qw($CONFIG $HOSTNAME);

################################################################################
# CURRENT VERSION
# ---------------

sub CURRENT_VERSION {
   return 2;
}

##################
# VERSION UPGRADES
# ----------------

sub versionUpgrade {
   my $self = shift;

   if($self->version < 2) {
      my @names = map { $_->{'name'} } @{$self->profileObject->routers};
      my @oldValues = split(/,/, $self->{'meta'}{'access'});

      $self->{'meta'}{'access'} = {};
      for(my $i = 0; $i < @names; $i++) {
         $self->{'meta'}{'access'}{ $names[$i] } = ($oldValues[$i] eq 'globalCookie') ? 'user' : $oldValues[$i];
      }

      $self->{'version'} = 2;
   }
}

################################################################################
# CONFIGURE PACKAGE GLOBALS
# -------------------------
#
# Some of these are written by Reservation::Load.

our $RESERVATIONS;
our $BY_ID;
our $BY_NAME;
our $BY_IP;
our $BY_CONTAINERID;

################################################################################
# SIMPLE ACCESSORS
# ----------------

sub version {
   return $_[0]->{'version'};
}

sub id {
   return $_[0]->{'id'};
}

sub name {
   return $_[0]->{'name'};
}

sub docker {
   return $_[0]->{'docker'};
}

sub containerId {
   my $self = shift;

   if(@_ == 0) {
      return $self->{'containerId'};
   }

   $self->{'containerId'} = $_[0];

   return $self;
}

sub profileObject {
   return $_[0]->{'profileObject'};
}

sub status {
   return $_[0]->{'status'};
}

# With no arguments: return owner data structure.
# With one argument: return value of named property within owner data structure.
sub owner {
   my $self = shift;
   my $prop = shift;

   return $prop ? $self->{'owner'}{$prop} : $self->{'owner'};
}

sub profile {
   my $self = shift;

   if(@_ == 0) {
      return $self->{'profile'};
   }

   my $name = shift;
   unless( $name =~ /^[a-zA-Z0-9][a-zA-Z0-9\-\_]+$/ && Profile->load($name) ) {
      die Exception->new( 'msg' => "Failed to set Reservation profile to unknown or invalid profile '$name'" );
   }

   $self->{'profile'} = $name;

   # Generate profileObject property by instantiating a Profile object using the named profile.
   $self->{'profileObject'} = Profile->load($name);
}

sub data {
   my $self = shift;

   my $key = shift;

   if(@_ == 0) {
      return $self->{'data'}{$key};
   }

   my $value = shift;
   if($key eq 'image') {
      # FIXME:
      # <optional> <domainname> <optional> :<port> '/'
      # 
      if( $value !~ m!^(?:[A-Za-z0-9_\-/\.\:]+(?::[A-Za-z0-9_\-]+)?)?$! ) {
         die Exception->new( 'msg' => "Failed to create Reservation with invalid image '$value'" );
      }
   }
   elsif($key eq 'runtime') {
      if( $value !~ /^([a-zA-Z][a-zA-Z0-9\-]+)?$/ ) {
         die Exception->new( 'msg' => "Failed to create Reservation with invalid runtime '$value'" );
      }
   }
   elsif($key eq 'network') {
      if( $value !~ /^([a-zA-Z][a-zA-Z0-9\-]+)?$/ ) {
         die Exception->new( 'msg' => "Failed to create Reservation with invalid network '$value'" );
      }
   }
   elsif($key eq 'unixuser') {
      if( $value !~ /^([a-zA-Z][a-z0-9\-]+)?$/ ) {
         die Exception->new( 'msg' => "Failed to create Reservation with invalid unixuser '$value'" );
      }
   }

   $self->{'data'}{$key} = $value;

   return $self;
}

sub meta {
   my $self = shift;

   my $key = shift;

   if(@_ == 0) {
      return $self->{'meta'}{$key};
   }

   my $value = shift;
   if( $key eq 'owner' ) {
      if( $value =~ /^[a-z0-9]*$/ ) {
         # FIXME: check that username(s) provided are valid
         $self->{'meta'}{$key} = $value || '';
      }
      else {
         die Exception->new( 'msg' => "Cannot set reservation 'owner' to invalid value '$value'" );
      }
   }
   elsif( $key =~ /^(viewers|developers)$/ ) {

      # $value can be a comma-separated list of items of form either '<username>' or 'role:<role>' or ''
      my @values = split(/,/, $value);

      # Check if all values match the regex
      if( (grep { /^(role:)?[a-z][a-z0-9]+$/ } @values) == @values ) {
         # TODO: check that username(s) and role(s) provided are valid
         $self->{'meta'}{$key} = $value || '';
      }
      else {
         die Exception->new( 'msg' => "Cannot set reservation '$key' to invalid value '$value'" );
      }
   }
   elsif( $key eq 'access' ) {
      foreach my $name (keys %$value) {
         # Allow any value from this list:
         # - owner|viewer|developer|user|public|containerCookie
         # (unless type eq ide, in which case allow only owner|developer).
         #
         # If no value specified, set to the default ('developers' if none specified in the profile).
         my $access = $value->{$name};
         die Exception->new( 'msg' => "Cannot set auth/access mode for router '$name' to '$access'" )
            unless $access =~ /^(?:owner|viewer|developer|user|public|containerCookie)$/;

         die Exception->new( 'msg' => "Cannot set auth/access mode for router '$name' to '$access'" )
            if $name =~ /^(?:ide|ssh)$/ && !($access =~ /^(?:owner|developer)$/);

         $self->{'meta'}{'access'}{$name} = $access;
      }
   }
   elsif( $key eq 'private' ) {
      if( $value =~ /^(1|0)$/ ) {
         $self->{'meta'}{$key} = $value;
      }
      else {
         die Exception->new( 'msg' => "Cannot set reservation privacy to invalid value '$value'" );
      }
   }
   elsif( $key eq 'description' ) {
      $self->{'meta'}{$key} = $value;
   }

   return $self;
}

################################################################################
# VALIDATORS
# ----------

sub validate {
   my $self = shift;

   if($self->{'name'} ne '') {
      # Name must be lower case, consist only of letters, digits and hyphens (but not successive hyphens) and begin with a letter
      unless( $self->{'name'} =~ /^[a-z](?:-[a-z0-9]+|[a-z0-9]+)+$/ ) {
         die Exception->new( 'msg' => "Failed to create Reservation with invalid name '$self->{'name'}'" );
      }
   }
   else {
      # Assign auto-generated name
      $self->{'name'} = sprintf( "%x", int(rand(0xffffffff)) ^ $$ );
   }

   # FIXME: check that data.parentFQDN is valid
   $self->{'data'}{'FQDN'} ||= "$self->{'name'}$self->{'data'}{'parentFQDN'}";

   # Assign default id.
   $self->{'id'} = sprintf( "%x", int(rand(0xffffffffffffffff)) ^ $$ );
}

################################################################################
# CONSTRUCTORS
# ------------

sub new {
   my $class = shift;
   my $data = shift;
   my $validated = shift;

   # Decode JSON if needed.
   if(!ref($data)) {
      $data = decode_json($data);
   }

   # If pre-validated, $data is safe to use;
   # otherwise generate fresh data structure with just the keys we need.
   my $self = $validated ? { %$data, 'validated' => 1 } :
      {
         'version' => CURRENT_VERSION(),
         'id' => $data->{'id'},
         'name' => $data->{'name'}, # Name
         'profile' => "", # Launch profile name
         'profileObject' => $data->{'profileObject'}, # Launch profile data structure (optional)
         'data' => { # Profile-related launch data e.g. network, image, command, user
            'runtime' => "",
            'network' => "",
            'image' => "",
            'unixuser' => "",
            'parentFQDN' => $data->{'data'}{'parentFQDN'} // "",
            'FQDN' => $data->{'data'}{'FQDN'} // ""
         },
         'owner' => $data->{'owner'},
         'meta' => {
            # N.B. The default values are currently needed only when $data->{'id'} eq 'new', for the dummy Reservation object.
            # This could be avoided by breaking out meta validation from validate(), or by passing them in from App when the
            # dummy Reservation object is requested.
            'owner' => $data->{'meta'}->{'owner'} // "",
            'developers' => "",
            'viewers' => "",
            'private' => 0,
            'access' => {},
            'description' => ''
         },
         'containerId' => $data->{'containerId'} // undef,
         'docker' => $data->{'docker'} // {},
         'expiryTime' => $data->{'expiryTime'} // undef,
         'status' => -2,
         'ide' => $CONFIG->{'ide'}
      };

   bless $self, ( ref($class) || $class );

   # If a dummy Reservation object has been requested for sending to the client,
   # return what we have now.
   if( $data->{'id'} eq 'new' ) {
      return $self;
   }

   # Perform validation and setup
   if( $validated ) {

      # If a profileObject property has been provided and it is not a Profile object,
      # that's because it has been loaded from the Reservation db: instantiate it.
      if($self->{'profileObject'}) {
         if(ref($self->{'profileObject'}) ne 'Profile') {
            $self->{'profileObject'} = Profile->new($self->{'profileObject'}, 1);
         }
      }

      # Upgrade object version if needed.
      $self->versionUpgrade();

      # Instantiate routers lookup cache object.
      $self->{'routersLookup'} = $self->routers();
   }
   else {
      $self->validate();
   }

   return $self;
}

################################################################################
# CLASS METHODS
# -------------

# Update loaded Reservation objects with details of the containers they relate to,
# and update BY_IP and BY_CONTAINERID indices into the Reservation objects.
#
# This class method expects to be called whenever either the containers cache file,
# or reservations db file, is updated.

sub update_container_info {
   my $class = shift;

   my $containers = Containers->containers;

   $BY_IP = {};
   $BY_CONTAINERID = {};
   foreach my $r (@$RESERVATIONS) {

      # Simple | $map->{'containerId'} | $containers->{$containerId} | $map->{'expiryTime'} | Set 'docker' to:
      # N      | Y                     | Y                           | Y                    | Shouldn't happen: Map should remove expiryTime if $containerId is found
      # N      | Y                     | Y                           | N                    | Container data
      # Y/N    | Y                     | N                           | Y                    | { ID }
      # Y/N    | Y                     | N                           | N                    | Simple=N => Shouldn't happen: Map should add expiryTime if $containerId is not found; Simple=Y => { ID }
      # N      | N                     | Y                           | Y                    | N/A
      # N      | N                     | Y                           | N                    | N/A
      # Y/N    | N                     | N-N/A                       | Y                    | {}
      # Y/N    | N                     | N-N/A                       | N                    | {}

      my $containerId = $r->{'containerId'};
      if( $containerId ) {
         if( $containers->{$containerId} ) {

            $BY_CONTAINERID->{ substr($containerId, 0, 12) } = $r;

            # If the referenced container exists, then set up the data structures for it.
            $r->{'docker'} = $containers->{$containerId}{'docker'};
            $r->{'inspect'} = $containers->{$containerId}{'inspect'};

            if($r->{'docker'}{'Status'} =~ /Created/) {
               $r->{'status'} = -1;
            }
            elsif($r->{'docker'}{'Status'} =~ /Exited/) {
               $r->{'status'} = 0;
            }
            else {
               # Running
               $r->{'status'} = 1;
            }

            foreach my $network (keys %{$r->{'inspect'}{'Networks'}}) {
               my $IP = $r->{'inspect'}{'Networks'}{$network}{'IPAddress'};
               if($IP) {
                  $BY_IP->{$IP} = $r;
               }
            }
         }
         else {
            # We have a containerId but no corresponding container, which implies the container has been destroyed.
            $r->{'status'} = -3;
         }
      }
      # We have no containerId, which implies no container has yet been launched for this reservation.
      else {
         $r->{'status'} = -2;
      }

      $r->load_launch_logs();      
   }

   return $class;
}

sub load {
   my $class = shift;
   my $opts = shift;

   if( exists($opts->{'id'} ) ) {
      if( $BY_ID->{ $opts->{'id'} } ) {
         return [ $BY_ID->{ $opts->{'id'} } ];
      }

      return [];
   }
   elsif( exists($opts->{'name'}) ) {
      if( $BY_NAME->{ $opts->{'name'} } ) {
         return [ $BY_NAME->{ $opts->{'name'} } ];
      }

      return [];
   }
   elsif( exists($opts->{'ip'}) ) {
      if( $BY_IP->{ $opts->{'ip'}} ) {
         return [ $BY_IP->{ $opts->{'ip'}} ];
      }
      return [];
   }
   elsif( exists($opts->{'containerId'}) ) {
      my $containerId = substr($opts->{'containerId'}, 0, 12);

      if( $BY_CONTAINERID->{$containerId} ) {
         return [ $BY_CONTAINERID->{$containerId} ];
      }
      return [];
   }

   return $RESERVATIONS;
}

################################################################################
# OBJECT METHODS
# --------------

# Updates the dockerLaunchLogs property of the Reservation,
# to container the tail of the launch log file written by Reservation::launch.
#
sub load_launch_logs {
   my $self = shift;

   my $id = $self->id();

   # LAST N LINES WITH Tie::File
   my @lines;
   tie @lines, 'Tie::File', "$CONFIG->{'tmpPath'}/r-$id.log"
   || do {
      flog("Cannot open reservation log file '$id': $!");
      return [];
   };

   my $TerminationRE = qr/^=== EXIT CODE \d+ ===$/;

   my $data = [];
   for( my $i = (@lines) - 10; $i < (@lines); $i++ ) {
      push(@$data, $lines[$i]) if $i >= 0 && $lines[$i] !~ /$TerminationRE/;
   }
   untie @lines;

   $self->{'dockerLaunchLogs'} = $data;

   return $data;
}

# Gets the container logs for the Reservation:
# Inputs:
# - stdout => { 'clean_pty' => [0|1] }
# - stderr => { 'clean_pty' => [0|1] }
#
# Returns:
# - array of (undef, <stdout>, <stderr>)
#
sub load_container_logs {
   my $self = shift;
   my $opts = shift;

   my $containerId = $self->containerId();

   my $path = sprintf("/containers/%s/logs?stderr=%s&stdout=%s",
      $containerId,
      $opts->{'stderr'} ? 'true' : 'false',
      $opts->{'stdout'} ? 'true' : 'false'
   );

   my $result = call_socket_api(
      $CONFIG->{'docker'}{'socket'},
      $path
   );

   unless($result) {
      die Exception->new( 'dbg' => "Unable to execute Docker API call: $path #1", 'msg' => "Unable to retrieve container logs" );
   }

   unless($result->is_success) {
      die Exception->new( 'dbg' => "Unable to execute Docker API call '$path', error: " . trim($result->body), 'msg' => "Unable to retrieve container logs" );
   }

   my @stream = (undef, 'stdout', 'stderr');
   my $body = $result->body;
   my @output;
   while ($body) {
      # Extract the header bytes, and remove them from $body:
      # - see https://docs.docker.com/engine/api/v1.41/#operation/ContainerLogs
      #   and https://docs.docker.com/engine/api/v1.41/#operation/ContainerAttach
      my $header = substr($body, 0, 8, '');
      my ($stream_type, $length) = unpack("CxxxN", $header);
      my $text = substr($body, 0, $length, '');

      # Optionally, clean PTY escape sequences from the logs.
      $output[ $opts->{'merge'} ? 1 : $stream_type ] .= $opts->{ $stream[$stream_type] }{'clean_pty'} ? clean_pty($text) : $text;
   }

   return \@output;
}

################################################################################
# CLONE WITH CONSTRAINTS AND SANITISE
# -----------------------------------

# Create and return a sanitised copy of the Reservation object and its embedded Profile object,
# augmented with a user's reservation permissions.
# (known as a clientReservation).
# Inputs:
# - A set of constraints for removing unauthorised resources from the embedded Profile object
# - A mode - 'developer' or 'viewer' - that dictates a list of allowed properties, according to
#   the user's relationship with the reservation.
# Returns:
# - A clientReservation data structure

sub cloneWithConstraints {
   my $self = shift;
   my $constraints = shift;
   my $reservationPermissions = shift;

   # Clone reservation object and embedded profile object
   my $clone = Storable::dclone($self);

   if($clone->profileObject) {
      $clone->profileObject->applyConstraints($constraints);

      # FIXME: Optionally, move next block to Profile, by passing in $reservationPermissions
      #        and $clone->meta.
      #
      # Remove routers that are not accessible to the User:
      $clone->{'profileObject'}{'routers'} = [
         # Skip router if current auth level isn't permitted by the constraints:
         grep {
            $reservationPermissions->{'auth'}{ $clone->meta('access')->{ $_->{'name'} } }
         } @{$clone->profileObject->routers}
      ];
   }

   if($reservationPermissions->{'auth'}{'developer'}) {
      # Developer reservation constraints
      $clone->sanitise(
         {
            'docker' => [ qw( ID Size CreatedAt Status Image ImageId Networks ) ],
            'meta' => [ qw( owner developers viewers private access description ) ],
            'profileObject' => [ qw(name routers networks runtimes) ],
            'data' => [ qw( FQDN parentFQDN image runtime unixuser ) ],
            'dockerLaunchLogs' => 1
         },
         [ qw(id name owner profile status containerId) ]
      );
   }
   else {
      # Viewer reservation constraints
      $clone->sanitise(
         {
            'docker' => [ qw( ID Size CreatedAt Status ) ],
            'meta' => [ qw( owner access viewers ) ],
            'profileObject' => [ qw( name routers ) ]
         },
         [ qw( id name owner profile status containerId ) ]
      );
   }

   # Potentially, augment this with new 'permissions' on the reservation that tells the UI whether each (piece of):
   # container data can be displayed, edited and controls operated.
   $clone->{'permissions'} = $reservationPermissions;

   return $clone;
}

sub sanitise {
   my $self = shift;

   # Start with HASH of properties
   my $properties = shift;

   my $array = shift;
   
   # Augment with additional properties
   foreach my $property (@$array) {
      $properties->{$property} = 1;
   }

   foreach my $key (keys %$self) {
      if(ref($properties->{$key}) eq 'HASH') {
         sanitise($self->{$key}, $properties->{$key});
      }
      if(ref($properties->{$key}) eq 'ARRAY') {
         sanitise($self->{$key}, {}, $properties->{$key});
      }
      elsif(!$properties->{$key}) {
         delete $self->{$key};
      }
   }

   return $self;
}

################################################################################
# MAPFILE ENTRY GENERATION
#

sub mapfile_routers {
   my $self = shift;

   # <http|https>/<prefixes>/<domains>=<http|https>:<port>
   # e.g. https/*/*=http:8080

   my $proxies = $self->profileObject->routers;

   my $routers;

   # Public Protocols/Prefixes/Domains => Private protocol and port
   # <http,https>/<prefix1,prefix2,prefix3,...>/<domain1,domain2,domain3,...>=<http|https>:<port>:<auth>
   # e.g. https/*/*=http:8080:public

   # Derive a minimal LHS that represents permutations of request that all map to the RHS, for each given router.
   # We do not attempt to merge separate routers.
   my $auth = $self->meta('access');

   for(my $i=0; $i < @$proxies; $i++) {
      my $router = $proxies->[$i];
      my $routerName = $router->{'name'};

      my %destinations;
      foreach my $publicProtocol ('http', 'https') {
         
         if( exists($router->{$publicProtocol}) && $router->{$publicProtocol}{'protocol'} && $router->{$publicProtocol}{'port'} ) {
            $destinations{ sprintf("%s:%d:%s",
                              $router->{$publicProtocol}{'protocol'},
                              $router->{$publicProtocol}{'port'}, 
                              $auth->{$routerName} || 'owner',
                           ) }{$publicProtocol} = 1;
         }
      }

      while( my ($destination, $publicProtocols) = each %destinations) {
         my $key = sprintf("%s/%s/%s",
            join(',', sort keys %$publicProtocols),
            $router->{'prefixes'} ? join(',', @{$router->{'prefixes'}}) : '*',
            $router->{'domains'} ? join(',', @{$router->{'domains'}}) : '*',
         );

         $routers->{$key} = $destination;
      }
   }

   return $routers;
}

# This method generates a data structure consumed by lookup_container_uri() below.
sub routers {
   my $self = shift;

   my $routers = $self->mapfile_routers;

   my $lookup;

   while( my($key, $val) = each %$routers ) {
      my($publicProtocols, $prefixes, $domains) = split(m!/!, $key);
      my $privateProtocolPortAuth = [split(/:/, $val)];

      # Split the prefixes on ',' with a workaround for split() not returning a single empty string,
      # when splitting on an empty string.
      my @prefixes = split(/,/, $prefixes, -1);
      @prefixes = ('') unless @prefixes;

      # Split the domains on ',' with a workaround for split() not returning a single empty string,
      # when splitting on an empty string.
      my @domains = split(/,/, $domains, -1);
      @domains = ('*') unless @domains;

      foreach my $publicProtocol (split(/,/, $publicProtocols)) {
         foreach my $prefix (@prefixes) {
            foreach my $domain (@domains) {
               $lookup->{$publicProtocol}{$prefix}{$domain} = $privateProtocolPortAuth;
            }
         }
      }
   }

   return $lookup;
}

sub lookup_container_uri {
   my $self = shift;
   my $host = shift;
   my $actualPrefix = shift;
   my $actualDomain = shift;
   my $protocol = shift;

   my $prefix = $actualPrefix;
   my $domain = $actualDomain;

   wlog( "lookup_container_uri: id=$self->{'id'}; host=$host; actualPrefix=$actualPrefix; actualDomain=$actualDomain; protocol=$protocol" );

   if( !$self->{'routersLookup'}{$protocol} ) {
      wlog( "lookup_container_uri: reservation $self->{'id'} found, and is authorised, but no $protocol routes found" );
      return undef;
   }

   # Match the Theia webview or minibrowser prefixes, e.g. ada64f8c-e28a-467e-8005-684da9eeaa90-wv-ide, and map to the 'ide' prefix.
   # The actual domain prefixes in use by Theia are configured in launch-ide.sh (currently 'wv' and 'mb').
   # We retain support for legacy prefixes 'webview' and 'minibrowser' for a limited period, for backwards compatibility.
   if( $host ne '' && $prefix =~ /^.*-(wv|mb|webview|minibrowser)-ide$/ ) {
      wlog( "lookup_container_uri: reservation $self->{'id'} found, and is authorised, mapping prefix '$prefix' => 'ide'" );
      $prefix = 'ide';
   }

   # FIXME: Move $prefix =~ /-/ to Proxy::domain_to_host,
   # and pass through a number of remaining host prefixes, that can be used
   # to indicate the request is a passthrough request here.
   if( $host ne '' && $prefix =~ /-/ ) {
      if( !$self->{'routersLookup'}{$protocol}{'**'} ) {
         wlog( "lookup_container_uri: reservation $self->{'id'} found, and is authorised, but no $protocol passthru route found for the passthrough wildcard prefix '**'" );
         return undef;
      }

      wlog( "lookup_container_uri: reservation $self->{'id'} found, and is authorised, and $protocol route found for the passthru wildcard prefix '**'");
      $prefix = '**';
   }

   elsif( !$self->{'routersLookup'}{$protocol}{$prefix} ) {
      wlog( "lookup_container_uri: reservation $self->{'id'} found, and is authorised, but no $protocol route found for prefix '$prefix'" );

      if( !$self->{'routersLookup'}{$protocol}{'*'} ) {
         wlog( "lookup_container_uri: reservation $self->{'id'} found, and is authorised, but no $protocol route found for the wildcard prefix '*'" );
         return undef;
      }

      wlog( "lookup_container_uri: reservation $self->{'id'} found, and is authorised, and $protocol route found for the wildcard prefix '*'");
      # Use the available wildcard prefix '*'.
      $prefix = '*';
   }

   if( !$self->{'routersLookup'}{$protocol}{$prefix}{$domain} ) {
      wlog( "lookup_container_uri: reservation $self->{'id'} found, and is authorised, and $protocol route for prefix '$prefix' found, but no route found for domain '$domain'" );

      if( !$self->{'routersLookup'}{$protocol}{$prefix}{'*'} ) {
         wlog( "lookup_container_uri: reservation $self->{'id'} found, and is authorised, and $protocol route for prefix '$prefix' found, but no route found for the wildcard domain '*'" );
         return undef;
      }

      wlog( "lookup_container_uri: reservation $self->{'id'} found, and is authorised, and $protocol route for prefix '$prefix' found, and route found for the wildcard domain '*'" );
      # Use the available wildcard domain '*'.
      $domain = '*';
   }

   my $exposedPort = $self->{'routersLookup'}{$protocol}{$prefix}{$domain}[1];

   my $uri;
   if($CONFIG->{'gateway'}{'enabled'} && $CONFIG->{'gateway'}{'IP'}) {
      $uri = sprintf("%s://%s:%d",
         $self->{'routersLookup'}{$protocol}{$prefix}{$domain}[0],
         $CONFIG->{'gatewayIP'},
         $self->{'inspect'}{'Ports'}{$exposedPort}
      );
   }
   else {
      my $hostNetworks;
      if(!$INNER_DOCKERD) {
         # Attempt to directly address container via an IP on a network we share with the container.
         $hostNetworks = Containers->containers->{$HOSTNAME}{'inspect'}{'Networks'};
      }
      # else {
         # When addressing a devtainer running on an inner dockerd instance, we assume all of its networks are accessible from the Dockside container.
      # }
      
      # Loop through the addressed container's networks.
      foreach my $network (sort { $a cmp $b } keys %{ $self->{'inspect'}{'Networks'}}) {

         # Skip if we don't share $network with the addressed container;
         # but, if we didn't identify any host/hostNetworks, we'll use the first.
         next if $hostNetworks && !$hostNetworks->{$network};

         # We found a $network we share; use this IP.
         $uri = sprintf("%s://%s:%d",
            $self->{'routersLookup'}{$protocol}{$prefix}{$domain}[0],
            $self->{'inspect'}{'Networks'}{$network}{'IPAddress'},
            $exposedPort
         );

         last;
      }
   }

   my $auth = $self->{'routersLookup'}{$protocol}{$prefix}{$domain}[2];

   wlog("container_uri: host='$host'; actualPrefix='$actualPrefix'; assumedPrefix='$prefix'; actualDomain='$actualDomain'; assumedDomain='$domain'; auth=$auth; uri=" .
      ($uri // 'NO-URI-FOUND')
   );

   return { 'uri' => $uri, 'auth' => $auth };
}

################################################################################
# RESERVATION QUERY METHODS
#

# Query 'viewers' or 'developers' $key for presence of username $user
sub meta_has_user {
   my $self = shift;
   my $key = shift;
   my $user = shift;

   # Empty $user would still match the regex, so check for this case.
   return 0 unless defined($user);

   return $self->meta($key) =~ /(?:^|,)\Q$user\E(?:,|$)/;
}

################################################################################
# RESERVATION CONTROL METHODS
#

sub action {
   my $self = shift;
   my $action = shift;
   my $args = shift;

   my $command;
   if($action eq 'start') {
      $command = 'start';
   }
   elsif($action eq 'stop') {
      $command = 'stop';
   }
   elsif($action eq 'remove') {
      $command = 'rm';
   }
   elsif($action eq 'getLogs') {
      return $self->load_container_logs({
         'stdout' => is_true($args->{'stdout'}) ? { 'clean_pty' => is_true($args->{'clean_pty'}) } : undef,
         'stderr' => is_true($args->{'stderr'}) ? { 'clean_pty' => is_true($args->{'clean_pty'}) } : undef,
         'merge' => is_true($args->{'merge'})
      });
   }
   else {
      die Exception->new( 'msg' => "Unknown docker container action '$action'" );
   }

   my $containerId = $self->containerId();
   return run("$CONFIG->{'docker'}{'bin'} $command $containerId");
}

sub update_network {
   my $self = shift;
   
   my $network = $self->data('network');
   my $containerId = $self->{'containerId'};

   flog("update_network: $network");

   # Disconnect all existing networks, except requested one.
   foreach my $oldNetwork (keys %{$self->{'inspect'}{'Networks'}}) {
      next if $network eq $oldNetwork;
      run("$CONFIG->{'docker'}{'bin'} network disconnect $oldNetwork $containerId");
   }

   # Connect requested network, if not existing
   if(!$self->{'inspect'}{'Networks'}{$network}) {
      run("$CONFIG->{'docker'}{'bin'} network connect $network $containerId");
   }
}

sub store {
   my $self = shift;
   
   $self->update( {
      'id' => $self->id(),
      'name' => $self->name(),
      'profile' => $self->profile(),
      'owner' => $self->owner(),
      'meta' => $self->{'meta'},
      'profileObject' => $self->profileObject(),
      'data' => $self->{'data'},
      'version' => $self->{'version'},
      $self->{'ide'} ? ('ide' => $self->{'ide'}) : ()
   } );

   return $self;
}

sub launch {
   my $self = shift;

   my @cmdline = 
   try {
      return ($self->cmdline());
   }
   catch {
      my $msg = (ref($_) eq 'Exception') ? $_->msg : $_;
      flog("Reservation::launch: Reservation->cmdline() threw error: $_");
      $self->update( {
         'expiryTime' => YYYYMMDDHHMMSS(time)
      } );
      die Exception->new( 'msg' => "Failed to compile 'docker run' command line, with error: $msg", 'dbg' => "Reservation::launch: Reservation->cmdline() threw error: $msg" );
   };

   my $id = $self->id();

   my @cmd;
   push(@cmd,
      $CONFIG->{'docker'}{'bin'},
      'create',
      '--cidfile', "$CONFIG->{'tmpPath'}/r-$id.cid",
      '--label', "owner.username=" . $self->owner('username'),
      '--label', "owner.name=" . $self->owner('name'),

      # TODO: Configure Profiles to support launch user.
      # '--user=root',

      @cmdline
   );

   my $cmd = join(' ', @cmd);
   $cmd =~ s!\s+! !g;

   flog("Reservation::launch: FORKING TO RUN: $cmd");

   # FIXME: Debug this code by uncommenting this line
   # return { 'status' => undef, 'msg' => 'failed to launch container', 'cmd' => $cmd, 'dbg' => "XYZZY" };

   flog("Reservation::launch: launching container with reservation id " . $self->id());

   my $pid;
   if( $pid = fork ) {

      # --------------
      # PARENT PROCESS
      # --------------

      # Reap our child process eventually
      $SIG{'CHLD'} = sub {
         waitpid $pid, 0; $SIG{'CHLD'} = 'DEFAULT';
      };

      return $self;
   }

   # -------------
   # CHILD PROCESS
   # -------------

   try {

      flog("Reservation::launch: RUNNING: $cmd");

      # Set PATH required for 'docker run' to launch external credential helpers, like gcloud.
      local $ENV{'PATH'} = $CONFIG->{'docker'}{'PATH'};
      local $ENV{'HOME'} = $CONFIG->{'docker'}{'HOME'} // '/home/newsnow';

      # Enable this to simulate slow launches.
      # sleep(30);

      # Launch 'docker run' command in a subprocess with pty piped to specified file.
      my $exitCode = run_pty( \@cmd, "$CONFIG->{'tmpPath'}/r-$id.log" );

      # 'docker run' has completed, so, log containerId (if launch successful) and exitCode.

      my $o = get_config("$CONFIG->{'tmpPath'}/r-$id.cid");
      flog("Reservation::launch: containerId='$o'; exitCode=$exitCode");

      if( $o !~ /^([0-9a-f]{12})[0-9a-f]{52}$/i ) {
         flog("Reservation::launch: 'docker run' failed to output container id");
         die Exception->new( 'msg' => 'docker run failed to output container id' );
      }

      # Set containerId in $self
      $self->containerId($1);

      # Update containerId property in reservation db for $self
      $self->update( {
         'containerId' => $self->containerId()
      } );
      
      flog("Reservation::launch: updated reservation db successfully");

      # Now the reservation db has been updated with the containerId,
      # docker-event-daemon will be able to identify the container, when launched, as its responsibility.
      #
      # So, start the container.
      $self->action('start');
      flog("Reservation::launch: started container");

      exit(0);
   }
   catch {
      my $msg = (ref($_) eq 'Exception') ? $_->msg : $_;
      flog("Reservation::launch: caught exception in 'docker run': '$msg'");
      $self->update( {
         'expiryTime' => YYYYMMDDHHMMSS(time)
      } );
      exit(0);
   };
}

sub exec {
   my $reservation = shift;
   my $command = shift;

   my $reservationId = $reservation->id();
   my $containerId = $reservation->containerId();

   my @Command = $reservation->ide_command();
   if(!@Command) {
      flog("exec: not launching IDE for reservationId=$reservationId, containerId=$containerId: no command");
      return undef;
   }

   if($command) {
      # Replace final element of command array (the default command) with new command.
      $Command[-1] = $command;
   }

   my $owner = $reservation->owner('username');
   my $user = User->load($owner);
   my $user_details = encode_json($user->details_full);

   my @envSSH;
   if( $reservation->profileObject->ssh ) {

      my @developersMeta = split(',', $reservation->meta('developers'));
      my @developers = grep { !/^role:/ } @developersMeta;
      my %developerRoles = map { s/^role://; ($_ => 1); } grep { /^role:/ } @developersMeta;

      flog("exec: developers=[" . join(',', @developers) . "]");
      flog("exec: developerRoles=[" . join(',', keys %developerRoles) . "]");

      my @usersHavingDeveloperRoles = map { $developerRoles{$_->{'role'}} ? $_->{'username'} : () } @{User->viewers};
      flog("exec: usersHavingDeveloperRoles=[" . join(',', @usersHavingDeveloperRoles) . "]");

      # Include SSH keys for named developers, and users with named roles
      # only if the access level for the 'ssh' service is 'developer'
      my @usernames = unique ($reservation->owner('username'), 
         $reservation->meta('access')->{'ssh'} eq 'developer' ? (@developers, @usersHavingDeveloperRoles) : ()
      );

      flog("exec: usernames=[" . join(',', @usernames) . "]");

      my @Users = map { User->load($_) } @usernames;
      flog("exec: " . join(',', @Users));

      my @authorized_keys = sort { $a cmp $b } unique map { $_ ? @{$_->authorized_keys()} : () } @Users;
      flog("exec: " . join(',', @authorized_keys));

      my $keys_json = encode_json(\@authorized_keys);

      @envSSH = (
         "--env=AUTHORIZED_KEYS=$keys_json",
         "--env=HOSTDATA_PATH=$CONFIG->{'ssh'}{'path'}",
         "--env=SSHD_ENABLE=1"
      );

      flog("exec: launching IDE for reservationId=$reservationId, containerId=$containerId, with command '" .
         join(' ', @Command) . "' for owner '$owner', developers '" .
         join(',', @usernames) . "', owner details '$user_details', keys '$keys_json'"
      );
   }
   else {   
      flog("exec: launching IDE for reservationId=$reservationId, containerId=$containerId, with command '" .
         join(' ', @Command) . "' for owner '$owner'"
      );
   }

   # TODO: Configure Profiles to support launching IDE as non-root user
   flog("exec: launching IDE for reservationId=$reservationId, containerId=$containerId, with command: " .
      join(' ', @Command)
   );
   run_system($CONFIG->{'docker'}{'bin'}, 'exec', '-d', '-u', 'root',
      ($reservation->ide_command_env()),
      "--env=OWNER_DETAILS=$user_details",
      @envSSH,
      $containerId,
      @Command
   );

   return 1;
}

1;
