package Reservation;

use v5.36;

use JSON;
use Expect;
use Try::Tiny;
use Tie::File;
use Storable qw(dclone);
use Reservation::Mutate qw(update load_clean_map record_hook_history increment_data_field);
use Reservation::Load;
use Reservation::Launch;
use Containers;
use Profile;
use Util qw(flog wlog get_config trim is_true clean_pty run run_pty TO_JSON YYYYMMDDHHMMSS cacheReadWrite call_socket_api docker_exec unique run_system get_uri sanitize_sensitive_text);
use Data qw($CONFIG $HOSTNAME $INNER_DOCKERD valid_ide_name);

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

sub version ($self) {
   return $self->{'version'};
}

sub id ($self) {
   return $self->{'id'};
}

sub name ($self) {
   return $self->{'name'};
}

sub docker ($self) {
   return $self->{'docker'};
}

sub containerId ($self, @value) {
   return $self->{'containerId'} unless @value;

   $self->{'containerId'} = $value[0];

   return $self;
}

sub profileObject ($self) {
   return $self->{'profileObject'};
}

# Returns:
# -1: Created (but not yet ever Started or Exited)
#  0: Exited (i.e. stopped)
#  1: Started (i.e. running)
sub status ($self) {
   return $self->{'status'};
}

sub is_running ($self) {
   return $self->status == 1;
}

# With no arguments: return owner data structure.
# With one argument: return value of named property within owner data structure.
sub owner ($self, $prop = undef) {
   return $prop ? $self->{'owner'}{$prop} : $self->{'owner'};
}

sub profile ($self, @args) {
   return $self->{'profile'} unless @args;

   my $name = $args[0];
   unless( $name =~ /^[a-zA-Z0-9][a-zA-Z0-9\-\_]+$/ && Profile->load($name) ) {
      die Exception->new( 'msg' => "Failed to set Reservation profile to unknown or invalid profile '$name'" );
   }

   $self->{'profile'} = $name;

   # Generate profileObject property by instantiating a Profile object using the named profile.
   $self->{'profileObject'} = Profile->load($name);
}

sub data ($self, $key, @rest) {
   return $self->{'data'}{$key} unless @rest;

   my $value = $rest[0];
   if($key eq 'image') {
      # FIXME:
      # <optional> <domainname> <optional> :<port> '/'
      # 
      if( $value !~ m!^(?:[A-Za-z0-9_\-/\.\:]+(?::[A-Za-z0-9_\-]+)?)?$! ) {
         die Exception->new( 'msg' => "Failed to create Reservation with invalid image '$value'" );
      }
   }
   elsif($key eq 'runtime') {
      # Allow runtimes of form: runc, sysbox-runc, and io.containerd.runc.v2
      if( $value !~ /^([a-zA-Z][a-zA-Z0-9\-]*(?:\.[a-zA-Z0-9\-]+)*)?$/ ) {
         die Exception->new( 'msg' => "Failed to create Reservation with invalid runtime '$value'" );
      }
   }
   elsif($key eq 'network') {
      if( $value !~ /^([a-zA-Z][a-zA-Z0-9\-\_\.]+)?$/ ) {
         die Exception->new( 'msg' => "Failed to create Reservation with invalid network '$value'" );
      }
   }
   elsif($key eq 'unixuser') {
      if( $value !~ /^([a-zA-Z][a-z0-9\-]+)?$/ ) {
         die Exception->new( 'msg' => "Failed to create Reservation with invalid unixuser '$value'" );
      }
   }
   elsif($key eq 'gitURL') {
      unless(
         $value eq '' ||
         $value =~ qr!^https://
                     (?:
                        [a-zA-Z0-9]
                        (?:[a-zA-Z0-9-]*[a-zA-Z0-9])?
                     \.)+          # Subdomains
                     [a-zA-Z]{2,}  # Top-level domain
                     /
                     .+            # Non-empty path
                     (?:\.git)?$!x ||
         $value =~ qr!^[a-zA-Z][\w-]*@ # Username
                     (?:
                        [a-zA-Z0-9]
                        (?:[a-zA-Z0-9-]*[a-zA-Z0-9])?
                     \.)+          # Subdomains
                     [a-zA-Z]{2,}  # Top-level domain
                     :
                     .+            # Non-empty path
                     (?:\.git)?$!x
         ) {
         die Exception->new( 'msg' => "Failed to create Reservation with invalid gitURL '$value'" );
      }
   }

   $self->{'data'}{$key} = $value;

   return $self;
}

sub meta ($self, $key, @rest) {
   if(!@rest) {
      return $self->{'meta'}{$key};
   }

   my $value = $rest[0];
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

      # $value can be a comma-separated list of items of form either
      # '<username>' or 'role:<role>' or ''. Accept the same character set
      # supported by user/role creation: letters, digits, hyphens, underscores.
      my @values = split(/,/, $value);

      # Check if all values match the regex
      if( (grep { /^(?:role:)?[A-Za-z0-9_-]+$/ } @values) == @values ) {
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
   elsif($key eq 'IDE') {
      # IDE names mirror Data.pm discovery: <ideType>/<version>, with path
      # components restricted enough to prevent traversal/hidden components.
      if( !valid_ide_name($value) ) {
         die Exception->new( 'msg' => "Failed to create Reservation with invalid IDE '$value'" );
      }

      $self->{'meta'}{$key} = $value;
   }

   return $self;
}

################################################################################
# VALIDATORS
# ----------

sub validate ($self) {
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
   {
      no warnings 'portable';
      $self->{'id'} = sprintf( "%x", int(rand(0xffffffffffffffff)) ^ $$ );
   }
}

################################################################################
# CONSTRUCTORS
# ------------

sub new ($class, $data, $validated = 0) {
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
            'FQDN' => $data->{'data'}{'FQDN'} // "",
            'gitURL' => ""
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

sub update_container_info ($class) {
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
      # We have no containerId: either launch is in-flight (-2) or docker create failed (-4).
      else {
         $r->{'status'} = ($r->{'createStatus'} ? -4 : -2);
      }

      $r->load_launch_logs();      
   }

   return $class;
}

sub load ($class, $opts = undef) {
   return $RESERVATIONS unless $opts;

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
sub load_launch_logs ($self) {
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

# Tails a hook invocation's outer log file (run_hook_sync's forked child, below, writes the
# hook's stdout+stderr frames here as they arrive - see item B,
# docs/plans/lifecycle-hooks-review-followup.md) for a status/log read endpoint to serve -
# see User::runContainerHookStatus and App.pm's GET /containers/<id>/hook/status route. Mirrors
# load_launch_logs() above (last $maxLines lines via Tie::File, read fresh from disk on every
# call, no in-process caching) - cheap for "poll a status field, fetch the tail" use, exactly
# like load_launch_logs already is for r-<id>.log. Unlike load_launch_logs, there is no
# synthetic '=== EXIT CODE ===' termination line to strip: docker_exec()'s on_output callback
# writes only the hook's own raw stdout/stderr bytes.
#
# Returns [] (never undef) if $name has never been invoked (no status record yet, so no
# logPath to read) or its log file cannot be opened (e.g. already cleaned up - see item I, not
# yet built) - a caller can treat "no status" and "no log lines" as the same "nothing to show
# yet" case without special-casing either.
sub load_hook_log ($self, $name, $maxLines = 200) {
   my $status = $self->hook_status($name) or return [];
   my $logPath = $status->{'logPath'} or return [];

   my @lines;
   tie @lines, 'Tie::File', $logPath
   || do {
      flog("Cannot open hook log file '$logPath' for reservation " . $self->id() . ": $!");
      return [];
   };

   my $data = [];
   for( my $i = (@lines) - $maxLines; $i < (@lines); $i++ ) {
      push(@$data, $lines[$i]) if $i >= 0;
   }
   untie @lines;

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
sub load_container_logs ($self, $opts) {
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

sub cloneWithConstraints ($self, $constraints, $reservationPermissions) {
   # Clone reservation object and embedded profile object
   my $clone = dclone($self);

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
            'meta' => [ qw( owner developers viewers private access description IDE ) ],
            'profileObject' => [ qw( name routers networks runtimes IDEs options ) ],
            'data' => [ qw( FQDN parentFQDN image runtime network unixuser gitURL runningIDE options ) ],
            'dockerLaunchLogs' => 1
         },
         [ qw(id name owner profile status containerId createStatus) ]
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

sub sanitise ($self, $properties, $array = []) {
   # Start with HASH of properties
   $properties //= {};
   $array //= [];
   
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
# ROUTER LOOKUP TABLE GENERATION
#
# Builds the per-(protocol,prefix,domain) lookup table consumed by lookup_container_uri()
# below.

sub routers ($self) {
   my $proxies = $self->profileObject->routers;
   my $auth    = $self->meta('access');

   my $lookup = {};

   foreach my $router (@$proxies) {
      my $routerName = $router->{'name'};

      foreach my $publicProtocol (qw( http https )) {
         my $proto = $router->{$publicProtocol} or next;
         next unless $proto->{'protocol'} && $proto->{'port'};

         my $prefixes = $router->{'prefixes'} && @{$router->{'prefixes'}} ? $router->{'prefixes'} : ['*'];
         my $domains  = $router->{'domains'}  && @{$router->{'domains'}}  ? $router->{'domains'}  : ['*'];

         my $route = {
            'private' => {
               'protocol' => $proto->{'protocol'},
               'port'     => $proto->{'port'},
            },
            'auth' => $auth->{$routerName} || 'owner',
         };

         foreach my $prefix (@$prefixes) {
            foreach my $domain (@$domains) {
               $lookup->{$publicProtocol}{$prefix}{$domain} = $route;
            }
         }
      }
   }

   return $lookup;
}

sub lookup_container_uri ($self, $host, $actualPrefix, $actualDomain, $protocol) {
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

   my $route       = $self->{'routersLookup'}{$protocol}{$prefix}{$domain};
   my $exposedPort = $route->{'private'}{'port'};

   my $uri;
   if($CONFIG->{'gateway'}{'enabled'} && $CONFIG->{'gateway'}{'IP'}) {
      $uri = sprintf("%s://%s:%d",
         $route->{'private'}{'protocol'},
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

      # Sort the container's networks by descending order of GwPriority (and, if needed, its name)
      # where the network is in one that's common to both devtainer and the Dockside host container.
      my $Networks = $self->{'inspect'}{'Networks'};
      my @candidateNetworks =
         sort { $Networks->{$b}{'GwPriority'} <=> $Networks->{$a}{'GwPriority'} || $a cmp $b }
         grep { !$hostNetworks || $hostNetworks->{$_} }
         keys %$Networks;

      if(@candidateNetworks) {
         # We found a $network we share; use the IP of the container from the network
         # with the highest gateway priority.
         $uri = sprintf("%s://%s:%d",
            $route->{'private'}{'protocol'},
            $self->{'inspect'}{'Networks'}{ $candidateNetworks[0] }{'IPAddress'},
            $exposedPort
         );
      }
   }

   wlog("container_uri: host='$host'; actualPrefix='$actualPrefix'; assumedPrefix='$prefix'; actualDomain='$actualDomain'; assumedDomain='$domain'; auth=$route->{'auth'}; uri=" .
      ($uri // 'NO-URI-FOUND')
   );

   return { 'uri' => $uri, 'route' => $route };
}

################################################################################
# RESERVATION QUERY METHODS
#

# Query 'viewers' or 'developers' $key for presence of username $user
sub meta_has_user ($self, $key, $user) {
   # Empty $user would still match the regex, so check for this case.
   return 0 unless defined($user);

   return $self->meta($key) =~ /(?:^|,)\Q$user\E(?:,|$)/;
}

# Return the reservations whose owner/viewers/developers reference $identifier, as a
# list of { id, name, fields => [...] } hashes. Lets a caller stop a user or role being
# (re)created with a name still referenced by a reservation — which would otherwise
# silently inherit that reservation's stale grant (privilege confusion on identifier
# reuse), since reservation metadata stores these as plain unvalidated strings that
# authorization later compares directly against the caller's username/role.
# Scans the FULL store via load({}) (deliberately unfiltered — not User::reservations,
# which filters by a caller's visibility). $kind is 'user' (match the owner, and a bare
# username in viewers/developers) or 'role' (match 'role:<name>' in viewers/developers;
# roles are never owners). 'fields' lists EVERY field a reservation references the
# identifier through (a user can be owner AND viewer AND developer), so the caller
# can report them all rather than just the first.
sub referencing_reservations ($class, $identifier, $kind) {
   my $token = ($kind eq 'role') ? "role:$identifier" : $identifier;
   my @refs;
   for my $r ( @{ $class->load( {} ) } ) {
      my @fields;
      push @fields, 'owner'
         if $kind eq 'user' && ( $r->meta('owner') // '' ) eq $identifier;
      push @fields, 'viewers'    if $r->meta_has_user( 'viewers',    $token );
      push @fields, 'developers' if $r->meta_has_user( 'developers', $token );
      push @refs, { 'id' => $r->{'id'}, 'name' => $r->{'name'}, 'fields' => \@fields }
         if @fields;
   }
   return @refs;
}

################################################################################
# RESERVATION CONTROL METHODS
#

sub action ($self, $action, $args = {}) {
   my @command;
   if($action eq 'start') {
      @command = ('start');
   }
   elsif($action eq 'stop') {
      @command = ('stop');
   }
   elsif($action eq 'remove') {
      @command = ('rm', '--volumes');
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
   return run_system($CONFIG->{'docker'}{'bin'}, @command, $containerId);
}

sub update_network ($self) {
   my $network = $self->data('network');
   my $containerId = $self->{'containerId'};
   my $attached = $self->{'inspect'}{'Networks'} // {};

   flog(sprintf(
      "update_network: reservationId=%s containerId=%s desired=%s attached=[%s]",
      $self->id() // '',
      $containerId // '',
      defined($network) ? $network : '<undef>',
      join(', ', sort keys %$attached),
   ));

   # If the container is already attached only to the requested network,
   # there is nothing to do.
   if( $network && $attached->{$network} && scalar(keys %$attached) == 1 ) {
      flog("update_network: no-op; already attached only to desired network '$network'");
      return;
   }

   # Disconnect all existing networks, except requested one.
   foreach my $oldNetwork (keys %$attached) {
      next if ($network // '') eq ($oldNetwork // '');
      flog("update_network: disconnecting network '$oldNetwork' from container '$containerId'");
      run_system($CONFIG->{'docker'}{'bin'}, 'network', 'disconnect', $oldNetwork, $containerId);
   }

   # Connect requested network, if not existing
   if($network && !$attached->{$network}) {
      flog("update_network: connecting network '$network' to container '$containerId'");
      run_system($CONFIG->{'docker'}{'bin'}, 'network', 'connect', $network, $containerId);
   }
}

sub store ($self) {
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

# store_fields:
#
# Like store() above, but persists only the specific fields given, instead of this process's
# entire in-memory record. $fields is a hashref shaped exactly like update()'s own $e (e.g.
# { data => { runningIDE => 'openvscode/latest' } }, or { meta => { access => {...} } }, or
# both) - never the whole 'data'/'meta' hash unless every key in it is genuinely being
# authoritatively set right now.
#
# Why this matters, not just "is tidier": store()'s whole-record write only merges safely
# nested-hash-by-nested-hash where BOTH the incoming payload and the fresh on-disk record are
# hashes at every level down to the changed key (see Util::cloneHash's own comment) - a scalar
# leaf, or a hash present in one but not the other, is blindly overwritten with whatever this
# process happens to be carrying, however old. store()'s $e always includes this process's
# *entire* in-memory 'data'/'meta' - so any field this process loaded a while ago and never
# refreshed, but is NOT trying to change right now, still rides along and can clobber a fresher
# value some *other* concurrent writer already persisted. That's not a rare edge case for a
# forked child that did several seconds of blocking work before finally writing: its own
# snapshot of every unrelated field is exactly that many seconds stale by the time it stores.
# store_fields avoids this at the source - a key genuinely absent from $fields is never sent at
# all, so cloneHash never touches it (see "hooks.status is the master record" above for the
# same principle already relied on for concurrent different-hook-name writes; this generalizes
# it to any field, not just that one).
#
# Only safe for "authoritative overwrite" values - ones that don't need reading their own prior
# persisted value to compute (see Reservation::Mutate::increment_data_field for that case,
# e.g. startCount).
sub store_fields ($self, $fields) {
   $self->update( { 'id' => $self->id(), %$fields } );
   return $self;
}

# Atomically increments data.startCount and returns the new value - see
# Reservation::Mutate::increment_data_field's own comment for why this needs a genuine
# read-under-lock, not just a narrowly-scoped store_fields call. Also updates this process's
# own in-memory copy, so a later read in the same process (e.g. this same forked child
# re-checking its own reservation) sees the value it just committed.
sub increment_start_count ($self) {
   my $newValue = increment_data_field( $self->id(), 'startCount' );
   $self->{'data'}{'startCount'} = $newValue;
   return $newValue;
}

sub getGitDevContainer ($self) {
   my $uri = $self->data('gitURL');
   flog("getGitDevContainer: uri=$uri");

   return undef unless $uri;

   if( $uri =~ m!^(?:https://github.com/|git\@github\.com:)(.*)\.git$! ) {
      my $path = $1;

      foreach my $branch (qw( main master )) {
         # git@github.com:dwavesystems/ocean-devcontainer.git =>
         # https://github.com/dwavesystems/ocean-devcontainer.git =>
         # https://raw.githubusercontent.com/dwavesystems/ocean-devcontainer/refs/heads/main/.devcontainer/devcontainer.json
         my $devcontainerUri = "https://raw.githubusercontent.com/$path/refs/heads/$branch/.devcontainer/devcontainer.json";

         my $result = get_uri($devcontainerUri);
         flog("getGitDevContainer: uri=$devcontainerUri; result=$result; is_success=" . ($result && $result->is_success) . "; body='" . ($result ? $result->body : 'N/A') . "'");

         if( $result && $result->is_success ) {
            # Strip comments
            my $body = $result->body;
            $body =~ s!//.*$!!gm;
            return eval { return decode_json($body); };
         }
      }
   }

   return undef;
}

sub launch ($self) {
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

   my $exitCode;
   try {

      flog("Reservation::launch: RUNNING: $cmd");

      # Set PATH required for 'docker create' to launch external credential helpers, like gcloud.
      local $ENV{'PATH'} = $CONFIG->{'docker'}{'PATH'};
      local $ENV{'HOME'} = $CONFIG->{'docker'}{'HOME'} // '/home/dockside';

      # Enable this to simulate slow launches.
      # sleep(30);

      # Launch 'docker create' command in a subprocess with pty piped to specified file.
      $exitCode = run_pty( \@cmd, "$CONFIG->{'tmpPath'}/r-$id.log" );

      my $o = get_config("$CONFIG->{'tmpPath'}/r-$id.cid");
      flog("Reservation::launch: containerId='$o'; exitCode=$exitCode");

      if( $exitCode != 0 ) {
         flog("Reservation::launch: 'docker create' failed with exit code $exitCode");
         die Exception->new( 'msg' => "docker create failed with exit code $exitCode" );
      }

      if( $o !~ /^([0-9a-f]{12})[0-9a-f]{52}$/i ) {
         flog("Reservation::launch: 'docker create' failed to output container id");
         die Exception->new( 'msg' => 'docker create failed to output container id' );
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
      flog("Reservation::launch: caught exception in 'docker create': '$msg'");
      # Any exception reaching here means the create FAILED, so createStatus must
      # be non-zero — status() maps a non-zero createStatus to -4 (failed) but a
      # zero to -2 (launch in flight).  'docker create' can exit 0 yet still fail
      # afterwards (e.g. no/garbled container id parsed from the output, which dies
      # above with $exitCode still 0); use || not // so that post-command failure
      # records 1 rather than the misleading success value 0.
      $self->update( {
         'createStatus' => ($exitCode || 1),
         'expiryTime'   => YYYYMMDDHHMMSS(time)
      } );
      exit(0);
   };
}

# Runs a one-off action against an already-running container's perpetual launch_ide process,
# by re-invoking it with $command replacing its default final argument (see @Command below) -
# every current/prospective caller (User::updateContainerReservation's
# 'update_ssh_authorized_keys', and 'restart_ide' if re-enabled) always passes an explicit
# command naming that action. $command is never undef in practice any more: this function used
# to double as docker-event-daemon's genuine container-start dispatch too (the undef-$command
# case), which is now handled entirely by launch_maybe_dispatch/%LAUNCH_STAGES instead (see item
# F, "Dispatch orchestration") - that path never calls exec() at all.
sub exec ($reservation, $command = undef) {
   my $reservationId = $reservation->id();
   my $containerId = $reservation->containerId();

   # Existing logic for other commands
   my @Command = $reservation->ide_command();
   if(!@Command) {
      flog("exec: unable to run command for reservationId=$reservationId, containerId=$containerId: no command");
      return undef;
   }

   if($command) {
      # Replace final element of command array (the default command) with new command.
      $Command[-1] = $command;
   }

   if (defined $command && $command eq 'restart_ide') {
      # Logic to update the running IDE
      # This could involve stopping the current IDE process and starting the new one

      flog("exec: restarting IDE for reservationId=$reservationId, containerId=$containerId");

      # Store before exec so the UI reflects the intended IDE immediately. Narrow store - see
      # store_fields' own comment - since this reservation's launch DAG (if this devtainer's
      # own is still in progress) may concurrently be writing other, unrelated fields.
      $reservation->data('runningIDE', $reservation->meta('IDE'));
      $reservation->store_fields( { 'data' => { 'runningIDE' => $reservation->data('runningIDE') } } );

      run_system($CONFIG->{'docker'}{'bin'}, 'exec', '-d', '-u', $reservation->unixuser(), $containerId, @Command);

      return 1;
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

      flog(sanitize_sensitive_text("exec: launching IDE for reservationId=$reservationId, containerId=$containerId, with command '" .
         join(' ', @Command) . "' for owner '$owner', developers '" .
         join(',', @usernames) . "', owner details '$user_details', keys '$keys_json'"
      ));
   }
   else {   
      flog("exec: launching IDE for reservationId=$reservationId, containerId=$containerId, with command '" .
         join(' ', @Command) . "' for owner '$owner'"
      );
   }

   my @envCommonHook = $reservation->_hook_env($user);

   my @envIDE = (
      "--env=IDE=" . $reservation->meta('IDE')
   );

   my @envDevContainer;
   @envDevContainer = (
      "--env=DEVCONTAINER_VSCODE_EXTENSIONS=" . encode_json( $reservation->data('vscode') )
   );

   # TODO: Configure Profiles to support launching IDE as non-root user
   flog("exec: launching IDE for reservationId=$reservationId, containerId=$containerId, with command: " .
      join(' ', @Command)
   );

   # Store before exec so the UI reflects the intended IDE immediately,
   # including during any retry window before the exec succeeds. Narrow store - see
   # store_fields' own comment.
   $reservation->data('runningIDE', $reservation->meta('IDE'));
   $reservation->store_fields( { 'data' => { 'runningIDE' => $reservation->data('runningIDE') } } );

   run_system($CONFIG->{'docker'}{'bin'}, 'exec', '-d', '-u', 'root',
      ($reservation->ide_command_env()),
      "--env=OWNER_DETAILS=$user_details",
      "--env=SSH_AGENT_KEYS=" . encode_json( $user->keypairs_all() ),
      @envCommonHook,
      @envSSH,
      @envDevContainer,
      @envIDE,
      $containerId,
      @Command
   );

   return 1;
}

# The baseline env vars every launch.sh invocation on this reservation needs, regardless of
# which specific action is running inside the container: the same GIT_URL/SSH_KNOWN_HOSTS_DOMAINS,
# DOCKSIDE_OPTION_* and GH_TOKEN env this reservation's IDE launch already gets. Shared by all
# three current callers - exec() (a one-off action against an already-running launch_ide
# process, e.g. 'update_ssh_authorized_keys'), dispatch_hook_exec() (a real hook run), and
# _launch_dispatch_exec() (a %LAUNCH_STAGES stage) - to avoid duplicating/drifting that logic
# between them. Does not resolve any hook/stage script path itself; each caller that needs one
# resolves it separately, since which script(s) (if any) are relevant differs per caller.
#
# Returns `docker` CLI flag strings ("--env=KEY=VALUE"), not plain "KEY=VALUE" - matching
# exec()'s own @envSSH/@envIDE/etc. below, since exec() still shells out to the `docker` CLI
# directly (run_system(...'exec','-d',...,@envCommonHook,...)). dispatch_hook_exec/
# _launch_dispatch_exec (see item B/F) dispatch via the Docker Engine API's exec/create
# instead, whose `Env` field wants plain "KEY=VALUE" strings - a real bug, caught by the
# integration suite, not by this session's own manual testing (which never actually inspected
# DOCKSIDE_OPTION_* forwarding specifically): passing "--env=KEY=VALUE" straight into that JSON
# field doesn't error, it just silently creates a nonsense env var literally named "--env" whose
# value is "KEY=VALUE" - so DOCKSIDE_OPTION_* (and GIT_URL/GH_TOKEN) never reached the hook
# process at all. Fixed at each Engine-API caller's own call site (strips the prefix there)
# rather than changing this function's output format, since exec() still needs the CLI-flag form.
sub _hook_env ($self, $user) {
   my @envGit;
   if( $self->gitURL() ) {
      my ($git_domain) = $self->gitURL() =~ m!^(?:https://|git@)([^:/]+)!;
      @envGit = (
         "--env=GIT_URL=" . $self->gitURL(),
         "--env=SSH_KNOWN_HOSTS_DOMAINS=$git_domain"
      );
   }

   my @envOptions = map {
      "--env=DOCKSIDE_OPTION_" . uc($_) . "=" . ($self->data('options') // {})->{$_}
   } keys %{ $self->data('options') // {} };

   my @envGhToken;
   if( my $token = $user->gh_token() ) {
      @envGhToken = ( "--env=GH_TOKEN=$token" );
   }

   return (@envGit, @envOptions, @envGhToken);
}

# --- Hook status/history storage ---
#
# data('hooks') = { status => {...}, history => [...] } - two structures nested under one
# top-level data key, deliberately different shapes for different jobs (see
# docs/plans/lifecycle-hooks-review-followup.md item B):
#
# hooks.status is the master record, a hash keyed by hook name - one entry per name, holding
# its current/last invocation's state. This is what a pre-exec "is this already running?"
# check (hook_is_running) and a "what happened last time?" query (hook_status) both read.
# Concurrent forked children invoking *different* names on the same reservation must never
# clobber each other's entries - see Reservation::store_fields' own comment for exactly what
# that requires (not just "it's a nested hash", which alone isn't sufficient - a writer whose
# own in-memory copy carries a *stale* copy of a name it isn't even trying to change can still
# clobber it via an ordinary whole-record store()). _hook_status_store_one below is what
# actually makes this safe: it persists only the one name being written, via store_fields, so a
# name genuinely absent from a writer's own payload is never touched on disk, no matter how
# stale that writer's own snapshot of it is.
#
# hooks.history is a bounded, oldest-first array of past invocations across all names.
# Deliberately NOT maintained via store()/store_fields at all - cloneHash only recurses into
# hashes; an array value is compared by reference and replaced wholesale, so two concurrent
# appends via that path would race and the loser's row would simply be lost. record_hook_history()
# (Reservation::Mutate) instead re-reads the reservation fresh under its own atomic mutate()
# lock, appends, evicts, and writes back - safe under genuine concurrency.

my $HOOK_HISTORY_MAX = 100;

# Internal helpers isolating hooks.status's read/write boilerplate.
sub _hook_status_all ($self) {
   return ($self->data('hooks') // {})->{'status'} // {};
}

# Persists exactly one name's entry - never the whole status hash (see the block comment
# above for why that distinction matters) - while keeping this process's own in-memory copy
# consistent too, so a later call in the *same* process (e.g. hook_status_set_running_details
# reading back what hook_status_started just wrote a moment earlier) still sees it; only the
# disk write is narrowed, not this process's own view of its own writes.
sub _hook_status_store_one ($self, $name, $entry) {
   my $status = ( $self->{'data'}{'hooks'} //= {} )->{'status'} //= {};
   $status->{$name} = $entry;
   $self->store_fields( { 'data' => { 'hooks' => { 'status' => { $name => $entry } } } } );
}

# Returns true if $name's last-known invocation is still running, per the master record. A
# cheap, purely *optimizing* pre-exec check (see item B) - it has no visibility into an
# auto-invoked lifecycle:launch/lifecycle:start run (those never touch this record at all - see
# item B's auto-invoke exception), so a false "not running" is possible and expected in that
# specific race. The in-container mkdir lock (run_hook() in launch.sh) remains the actual
# safety net regardless, exactly as it already is today - this only ever saves a wasted
# round-trip in the common case, it was never the thing overlap-safety depends on.
sub hook_is_running ($self, $name) {
   my $status = $self->_hook_status_all->{$name};
   return 0 unless $status && ($status->{'state'} // '') eq 'running';

   # Newly-started, before the forked child has reached docker_exec()'s on_created callback
   # yet (see hook_status_started/hook_status_set_running_details below) - neither liveness
   # signal exists yet, so there is nothing to check; it is, definitionally, still running.
   return 1 unless defined($status->{'pid'}) || defined($status->{'execId'});

   # Stale-running detection, mirroring run_hook()'s own kill -0 reclaim for its in-container
   # lock: a forked child that died without writing back (an nginx worker recycled from under
   # it, OOM, etc.) would otherwise wedge this name as "running" forever. Two signals, cheapest
   # first: the fork's own pid (same PID namespace as this process - a reused-pid false
   # positive is the same accepted limitation run_hook()'s own check already has), then, if
   # that's inconclusive, the exec API's own Running state.
   if( defined $status->{'pid'} ) {
      return 1 if kill(0, $status->{'pid'});
   }
   if( defined $status->{'execId'} ) {
      my $res = call_socket_api($CONFIG->{'docker'}{'socket'}, "/exec/$status->{'execId'}/json", {});
      if( $res && $res->is_success ) {
         my $info = decode_json($res->body);
         return 1 if $info->{'Running'};

         # Not running, and we have a real answer from the daemon about how it ended - use it.
         # This is what makes restart-recovery (item F, "Dispatch orchestration: the code
         # model") able to distinguish real success from real failure rather than defaulting
         # every stuck-'running' record to 'aborted' regardless of what actually happened; it
         # also quietly improves the pre-existing on-demand-hook case the same way, for free.
         if( defined $info->{'ExitCode'} ) {
            $self->hook_status_completed( $name, {
               'state'    => $info->{'ExitCode'} == 0 ? 'done' : 'failed',
               'exitCode' => $info->{'ExitCode'},
            } );
            return 0;
         }
      }
   }

   # Neither signal gave a conclusive answer - self-heal the record (so a future check, and any
   # status-read caller, sees 'aborted' rather than a misleadingly eternal 'running') and
   # report not-running.
   $self->hook_status_completed($name, { 'state' => 'aborted' });
   return 0;
}

# Returns $name's master-record entry (undef if it has never been invoked on this
# reservation), for a status/log read endpoint to serve. Normalizes the numeric-ish fields
# (exitCode/timedOut/busy/pid) back to real numbers before returning.
#
# The root cause this works around is fixed now (Util::cloneHash no longer stringifies
# every value it copies as a side effect of comparing it via `ne` - see cloneHash's own
# comment for the full story), so a freshly-written record no longer needs this. This stays
# as a safety net for records already persisted to disk as JSON-quoted strings from before
# that fix - decode_json on an on-disk `"busy":"0"` (a genuine JSON string in the file itself
# now, not just a Perl-internal flag) always re-decodes as a Perl string, permanently, until
# that exact field is next written - which normalizing here, rather than depending on every
# such record eventually being rewritten, makes moot. Cheap, and harmless once every record
# has been rewritten at least once post-fix, so left in rather than removed.
sub hook_status ($self, $name) {
   my $status = $self->_hook_status_all->{$name};
   return undef unless $status;

   my $clean = { %$status };
   for my $f (qw(exitCode timedOut busy pid)) {
      $clean->{$f} = 0 + $clean->{$f} if defined $clean->{$f};
   }
   return $clean;
}

# Called by the forking parent, before forking (see run_hook_sync below), to record that $name
# has started - so both the parent and (via fork()'s copy-on-write memory) the child already
# see 'running' in their own in-memory copy from the moment the child exists, and so a poller
# sees 'running' immediately rather than a gap where the record doesn't exist yet. pid/execId
# are deliberately not known yet at this point (the child's own pid only exists once fork()
# returns, the exec id only once docker_exec's on_created fires) - see
# hook_status_set_running_details, called by the child once both are known.
sub hook_status_started ($self, $name, $logPath) {
   $self->_hook_status_store_one( $name, {
      'name'      => $name,
      'state'     => 'running',
      'pid'       => undef,
      'execId'    => undef,
      'logPath'   => $logPath,
      'startTime' => YYYYMMDDHHMMSS(time),
   } );
}

# Called by the forked child once it knows both its own pid ($$) and the exec id
# (docker_exec's on_created callback) - see hook_status_started above for why these can't be
# known any earlier.
sub hook_status_set_running_details ($self, $name, $pid, $execId) {
   my $existing = $self->_hook_status_all->{$name} or return;
   $self->_hook_status_store_one( $name, { %$existing, 'pid' => $pid, 'execId' => $execId } );
}

# Called by the forked child once the hook has finished, timed out, or been confirmed aborted,
# recording the outcome on both the master record and the bounded history array. $fields must
# include 'state' explicitly ('done' or 'aborted') - never defaulted, so a caller can never
# accidentally leave a completed entry reading 'running' by omission.
sub hook_status_completed ($self, $name, $fields) {
   my $entry = { %{ $self->_hook_status_all->{$name} // { 'name' => $name } }, %$fields };
   $self->_hook_status_store_one( $name, $entry );

   record_hook_history($self->id(), { %$entry }, $HOOK_HISTORY_MAX);
}

# Dispatch a named hook (a reserved 'lifecycle:*' name or a profile-declared custom name)
# inside the reservation's container, via the exec API directly (decided - see item B) rather
# than forking the `docker` CLI. Non-blocking: forks and returns almost immediately, freeing
# the caller (App::handlerHTTPS's nginx worker - see item B's "fork is mandatory" note) well
# before the hook itself finishes; the forked child does the actual waiting and records the
# outcome via hook_status_completed() above, for a status/log read endpoint (see
# User::runContainerHookStatus, App.pm's GET /containers/<id>/hook/status route, and the
# `dockside hook run` CLI command, which will poll it - see item B's task list) to serve.
#
# $args->{'name'} is required (no default - every caller must say which hook). Three gates,
# checked in order, exactly as before this item B rework: (1) is it declared in this profile's
# `hooks` at all; (2) if it's a 'lifecycle:*' name, is that lifecycle event actually
# implemented yet (today: 'lifecycle:launch' and 'lifecycle:start' - the rest are schema-valid,
# reserved for docs/roadmap.md's future stop/rename/periodic, but not runnable); (3) still only
# for a 'lifecycle:*' name, does its own `hooks` entry set `manual` true (custom names skip (2)
# and (3) entirely - they never auto-fire, so declaring one always makes it manually
# invocable).
#
# Returns { busy => 1 } immediately, no docker exec attempted at all, if hook_is_running()'s
# cheap pre-check already shows $name running (still just an optimization, not the safety net -
# see hook_is_running's own comment); otherwise { started => 1, name => $name } once
# dispatched. Dies with a 400 Exception before attempting anything if any of the gates above
# fail.
sub run_hook_sync ($self, $args = {}) {
   my $name = $args->{'name'};
   die Exception->new( 'msg' => "'name' is required", 'status' => 400 ) unless length($name // '');

   # $self->profileObject is this reservation's own profile snapshot from creation time, not a
   # live lookup - so this check can only ever say whether $name is configured for *this
   # devtainer*, not whether it exists in the profile's current config (which may have changed
   # since, in either direction). The message below names both possible causes without a live
   # profile comparison to pick between them (out of scope - see
   # docs/plans/lifecycle-hooks-review-followup.md item C): a genuinely wrong name, or a hook
   # added to the profile after this devtainer was created (recreating it is the fix only for
   # the latter).
   my $script = $self->hook_script($name);
   die Exception->new(
      'msg' => "No hook '$name' is configured for this devtainer - check the hook name's " .
               "spelling, or recreate the devtainer if this hook has been added to the " .
               "profile since it was created",
      'status' => 400
   ) unless length($script);

   if( $name =~ /^lifecycle:/ ) {
      die Exception->new( 'msg' => "'$name' is reserved for a future release, not runnable yet", 'status' => 400 )
         unless $name eq 'lifecycle:launch' || $name eq 'lifecycle:start';

      die Exception->new( 'msg' => "'$name' is not configured as manually invocable for this profile (see its 'hooks' entry's 'manual' field)", 'status' => 400 )
         unless $self->profileObject->hooks->{$name}{'manual'};
   }

   my $timeout = $args->{'timeout'} || $CONFIG->{'hooks'}{'defaultTimeoutSeconds'} || 120;
   die Exception->new( 'msg' => "'timeout' must be a positive integer number of seconds", 'status' => 400 )
      unless $timeout =~ /^[1-9][0-9]*$/;

   # Cheap, local, no docker round-trip - see hook_is_running's own comment for exactly what
   # this does and doesn't guarantee (it is not the thing overlap-safety depends on). Checked
   # here too, not just inside dispatch_hook_exec below, so a busy reply returns before ever
   # forking - no point paying for a fork just to immediately discover there's nothing to do.
   if( $self->hook_is_running($name) ) {
      return { 'busy' => 1 };
   }

   # Fork - exactly Reservation::launch's existing pattern (see item B: "the pattern already
   # exists in this codebase") - parent returns immediately, freeing the caller (the API
   # server has no event loop of its own and must free the nginx worker - see item B's "fork
   # is mandatory" note); the forked child does the actual dispatch-and-wait via
   # dispatch_hook_exec() below, blocking freely since it has nothing else to do concurrently.
   local $SIG{'CHLD'} = 'DEFAULT';
   my $pid;
   if( $pid = fork ) {
      # PARENT
      $SIG{'CHLD'} = sub { waitpid $pid, 0; $SIG{'CHLD'} = 'DEFAULT'; };
      return { 'started' => 1, 'name' => $name };
   }

   # -------------
   # CHILD PROCESS
   # -------------
   $self->dispatch_hook_exec( $name, $script, { 'timeout' => $timeout, 'pid' => $$ } );
   exit(0);
}

# Shared core: dispatch a named hook/stage via the exec API and record its outcome start to
# finish (hook_status_started -> hook_status_set_running_details -> hook_status_completed).
# Used by run_hook_sync above (wrapped in fork(), see its own comment for why) and, once DED's
# side of item F is built, by its own launch-dispatch driver directly - see
# docs/plans/lifecycle-hooks-review-followup.md item F's "Dispatch orchestration: the code
# model". Blocking - callers on a genuine event loop (DED) cannot call this as-is without
# stalling it; see that same section's note on why this remains open.
#
# Deliberately does NOT repeat run_hook_sync's on-demand-specific validation gates (declared?
# implemented? manual?) or its busy pre-check (already done by the caller, before forking, in
# run_hook_sync's case - DED's own %LAUNCH_STAGES 'applicable' predicates are the equivalent
# gating for auto-dispatch, a genuinely different rule set, so there's nothing generic to
# share there). $args:
#   user    - exec user (default: $self->unixuser() - the on-demand-hook default; DED's
#             'launch:prep' stage is the one caller that needs to override this to 'root')
#   pid     - recorded via hook_status_set_running_details alongside the exec id; run_hook_sync
#             passes its own forked child's real $$, DED's caller omits it (stays undef, since
#             DED never forks - hook_is_running's liveness check already falls through to the
#             execId-only path gracefully in that case, see its own comment)
#   timeout - seconds; defaults to $CONFIG->{'hooks'}{'defaultTimeoutSeconds'}
sub dispatch_hook_exec ($self, $name, $script, $args = {}) {
   my @Command = $self->ide_command();
   die Exception->new( 'msg' => 'Internal error - no IDE command configured', 'dbg' => 'Reservation::dispatch_hook_exec: ide_command() returned empty' ) unless @Command;
   $Command[-1] = 'run_hook';
   # launch.sh's run_hook() takes the script path as an explicit argument (see item E) rather
   # than reading a fixed env var, so every invocation - on-demand or auto - passes it here.
   push( @Command, $name, $script );

   my $owner = $self->owner('username');
   my $user = User->load($owner);
   die Exception->new( 'msg' => "The owner of this devtainer ('$owner') no longer exists", 'status' => 400 ) unless $user;

   # _hook_env returns `docker` CLI flag strings ("--env=KEY=VALUE" - see its own comment) for
   # exec()'s sake; docker_exec() below dispatches via the Docker Engine API instead, whose
   # `Env` field wants plain "KEY=VALUE" strings - strip the CLI-flag prefix here, at this
   # call site only, rather than changing _hook_env's own output format.
   my @env = map { my $e = $_; $e =~ s/^--env=//; $e } $self->_hook_env($user);

   my $timeout = $args->{'timeout'} || $CONFIG->{'hooks'}{'defaultTimeoutSeconds'} || 120;
   my $containerId = $self->containerId();

   my $invocationId = sprintf( "%08x", int(rand(0xffffffff)) ^ $$ );
   my $logPath = "$CONFIG->{'tmpPath'}/r-" . $self->id() . "-hook-$invocationId.log";
   $self->hook_status_started($name, $logPath);

   flog( "Reservation::dispatch_hook_exec: DISPATCHING (via exec API): " . join( '|', map { sanitize_sensitive_text($_) } @Command ) );

   try {
      open( my $log, '>>', $logPath )
         or die Exception->new( 'dbg' => "Reservation::dispatch_hook_exec: cannot open log '$logPath': $!" );
      $log->autoflush(1);

      my $result = docker_exec( $CONFIG->{'docker'}{'socket'}, $containerId, {
         'Cmd'  => \@Command,
         'User' => $args->{'user'} // $self->unixuser(),
         'Env'  => \@env,
      }, {
         # A generous margin over $timeout, not $timeout itself - request_timeout below is
         # what actually enforces the hook's own configured budget; this only guards against
         # a truly stalled connection outliving that.
         'inactivity_timeout' => $timeout + 30,
         'request_timeout'    => $timeout,
         # Fires before docker_exec's own (blocking) start-and-stream call, so the exec id
         # reaches the status record as early as possible - see hook_status_started's comment
         # for why this can't be known any earlier than this.
         'on_created' => sub ($execId) { $self->hook_status_set_running_details($name, $args->{'pid'}, $execId); },
         'on_output'  => sub ($stream, $bytes) { print $log $bytes; },
      } );

      close($log);

      my $rc = $result->{'exitCode'};
      my $timedOut = $result->{'timedOut'} ? 1 : 0;
      # run_hook's own mkdir-lock returns exit code 2 when a run is already in progress -
      # the same signal the old timeout-CLI-wrapped implementation checked for, now read
      # from docker_exec's real ExitCode instead of a host-side process's $?. Note: a
      # request_timeout is purely client-side abandonment (see docker_exec's own comment) -
      # the in-container mkdir lock remains what actually prevents a subsequent overlapping
      # run; a timed-out hook may still be finishing in the background, discoverable later
      # via the .hook-ready/.hook-failed sentinels launch.sh's run_hook writes.
      my $busy = ( defined($rc) && $rc == 2 && !$timedOut ) ? 1 : 0;

      $self->hook_status_completed( $name, {
         'state'    => 'done',
         'exitCode' => $rc,
         'timedOut' => $timedOut,
         'busy'     => $busy,
      } );
   }
   catch {
      my $dbg = ref($_) ? $_->dbg() : "$_";
      flog("Reservation::dispatch_hook_exec: caught exception dispatching '$name': $dbg");
      $self->hook_status_completed( $name, { 'state' => 'aborted' } );
   };

   return { 'started' => 1, 'name' => $name };
}

# --- Launch dispatch orchestration (item F) ---
#
# Small, declarative dependency table + one generic recursive driver, rather than hand-rolled
# if/else at each transition point or a hand-maintained forward "stage -> next stages" hash -
# see docs/plans/lifecycle-hooks-review-followup.md item F's "Dispatch orchestration: the code
# model" for the full reasoning. Each stage declares its own dependencies; the reverse edges
# (who depends on me) are derived once, at load time, below.
#
# Storage is data('hooks') itself, via the reserved 'launch:*' sub-namespace (launch:prep/
# launch:git/launch:ide - not lifecycle:launch/lifecycle:start, which use their own real hook
# name via dispatch_hook_exec() above, since they're genuinely hooks, just DED-auto-invoked
# ones) - see item F coupling 4. Profile::validate_profile_hooks rejects any profile trying to
# declare a 'launch:*' name itself.
#
# TRANSPORT: each stage's dispatch is its own fork, but every fork is a direct child of
# docker-event-daemon itself - never of another stage's own forked process. A stage's forked
# child does its one (blocking) dispatch, records the outcome, and exits; it never dispatches
# anything else. Cascading through the DAG (deciding what's newly eligible once a dependency
# clears) is docker-event-daemon's own job, done by calling launch_advance below - not something
# a completing stage triggers itself. An earlier version had each stage's own resolution fork
# its dependents directly, which needed a fresh fork at every DAG edge (four nested generations
# deep for a full first launch) purely to keep one stage's caller from blocking on that stage's
# whole downstream chain before returning - real, found by direct testing, but a symptom of
# forking at the wrong granularity, not something that concurrency requirement actually forced.
# Restructured so only docker-event-daemon itself ever forks, and only once per stage
# dispatched, keeping the process tree flat regardless of how deep the DAG's dependency chains
# get. Still a stopgap, not the intended end state: forking (here, and in run_hook_sync, which
# uses the same pattern) is the pragmatic choice available today, not something required in
# principle - a genuinely async, IO::Async-integrated dispatch (kick off the exec with
# non-blocking I/O, register a completion callback) would satisfy "don't block the caller" with
# no fork anywhere, and is the real goal; see docs/plans/lifecycle-hooks-review-followup.md item
# F for the full reasoning.

my $ROOT_USER    = sub ($self) { 'root' };
my $NONROOT_USER = sub ($self) { $self->unixuser() };

# Two genuinely different dispatch shapes, not one forced-uniform 'command' field: launch:prep/
# launch:git/launch:ide are bare launch.sh entry-point functions (no hook name/script - see
# _launch_dispatch_exec below), while lifecycle:launch/lifecycle:start are real hooks, reusing
# dispatch_hook_exec() above exactly as an on-demand invocation would. Each stage's 'dispatch'
# closure calls whichever is actually right for it.
my %LAUNCH_STAGES = (
   'launch:prep' => {
      depends_on => [],
      dispatch   => sub ($self) { $self->_launch_dispatch_prep() },
   },
   'launch:git' => {
      depends_on => ['launch:prep'],
      applicable => sub ($self) { !!@{ $self->profileObject->gitURLs // [] } },
      dispatch   => sub ($self) {
         $self->_launch_dispatch_exec( 'launch:git', 'launch_git', $NONROOT_USER->($self), {
            'extra_env' => [
               "DOCKSIDE_START_COUNT=" . ( $self->data('startCount') // 0 ),
               "DEVCONTAINER_VSCODE_EXTENSIONS=" . encode_json( $self->data('vscode') ),
            ],
         } );
      },
   },
   'launch:ide' => {
      depends_on => ['launch:prep'],
      dispatch   => sub ($self) {
         $self->_launch_dispatch_exec( 'launch:ide', 'launch_ide', $NONROOT_USER->($self), {
            'detach'    => 1,
            'extra_env' => [ "IDE=" . $self->meta('IDE') ],
         } );
      },
   },
   'lifecycle:launch' => {
      depends_on => ['launch:git'],
      applicable => sub ($self) {
         !!( $self->profileObject->hooks->{'lifecycle:launch'} && $self->data('startCount') == 1 )
      },
      dispatch   => sub ($self) { $self->_launch_dispatch_hook_stage('lifecycle:launch') },
   },
   'lifecycle:start' => {
      depends_on => ['lifecycle:launch'],
      applicable => sub ($self) { !!$self->profileObject->hooks->{'lifecycle:start'} },
      dispatch   => sub ($self) { $self->_launch_dispatch_hook_stage('lifecycle:start') },
   },
);

my %LAUNCH_DEPENDENTS_OF;
for my $stageName ( keys %LAUNCH_STAGES ) {
   push @{ $LAUNCH_DEPENDENTS_OF{$_} //= [] }, $stageName for @{ $LAUNCH_STAGES{$stageName}{'depends_on'} };
}

# Records a stage's real outcome, from wherever that outcome was discovered (live dispatch
# completion, or launch_advance's own self-heal poll - this driver doesn't care which; see the
# transport note on launch_maybe_dispatch below). $state is 'done'/'failed'/'timedOut'/'skipped'.
#
# Deliberately does NOT cascade to dependents itself - that used to happen here (each forked
# stage calling this on its own completion, which could then fork its *own* dependents in
# turn), but that made every DAG edge a new fork generation: a full first launch (gitURLs +
# both lifecycle hooks) forks four levels deep (prep -> git -> lifecycle:launch ->
# lifecycle:start), each a child of the *previous* stage's own forked process, not of
# docker-event-daemon itself. That's needlessly fragile (found while trying to make a scratch
# test harness reliably observe it - waitpid can only reap direct children, not grandchildren
# several levels deep, and neither can DED's own SIGCHLD handling) for no real benefit: nothing
# about the concurrency this design exists to preserve (launch:ide not waiting on git+hooks)
# requires forking at every edge, only at the one genuine fork point (launch:prep's two
# independent dependents). Cascading is now launch_advance's job instead - see its own comment.
sub launch_resolve_stage ($self, $stage, $state) {
   $self->hook_status_completed( $stage, { 'state' => $state } );
}

sub _launch_deps_cleared ($self, $stage) {
   for my $dep ( @{ $LAUNCH_STAGES{$stage}{'depends_on'} } ) {
      my $status = $self->hook_status($dep);
      return 0 unless $status && $status->{'state'} =~ /^(?:done|skipped)$/;
   }
   return 1;
}

# Dispatches $stage if applicable, or resolves it 'skipped' (a synchronous, non-forking
# resolution - e.g. launch:git skipped for a no-gitURLs profile). Called only from
# launch_advance's own scan below, never from another stage's own dispatch - see
# launch_resolve_stage's comment for why cascading was moved out of the dispatch path itself.
#
# TRANSPORT NOTE: forking here (rather than genuinely async, IO::Async-integrated dispatch) is
# the pragmatic choice available today, matching run_hook_sync's existing pattern - a deliberate
# stopgap, not the intended end state. The eventual goal is docker-event-daemon as a single
# process with no forking at all; if this dispatch model runs into further complications, that's
# the signal to stop patching it and build the async version instead of adding more scaffolding
# here. See docs/plans/lifecycle-hooks-review-followup.md item F for the full reasoning.
sub launch_maybe_dispatch ($self, $stage) {
   # Idempotency guard: launch_advance's own scan is the only caller, running serially in
   # docker-event-daemon's single process - so this is no longer defending against genuinely
   # concurrent callers (there aren't any), just against being asked to dispatch $stage a second
   # time this cycle when it already has a status record (in any state) that isn't 'pending' -
   # see launch_reset_stages below for what 'pending' means and why it's excluded here. Kept as
   # a guard regardless (rather than trusting callers never to double-ask): a stage's own forked
   # child writes its 'running' status asynchronously, after fork() has already returned to this
   # process, so two launch_advance passes close enough together could otherwise both decide to
   # dispatch before the first fork's write has landed.
   my $status = $self->hook_status($stage);
   return if $status && ( $status->{'state'} // '' ) ne 'pending';

   my $spec = $LAUNCH_STAGES{$stage};
   if ( $spec->{'applicable'} && !$spec->{'applicable'}->($self) ) {
      $self->launch_resolve_stage( $stage, 'skipped' );
      # 'skipped' => 1 (not just a truthy return) is load-bearing: launch_advance's own loop
      # re-scans for further progress only when told a stage settled *synchronously*, within
      # this same call - a skip does (hook_status is already terminal by the time this
      # returns); a real dispatch below does not (its status is still 'pending' from this
      # process's point of view until the forked child gets around to writing it, which could
      # be anywhere from microseconds to milliseconds away). Conflating the two here (originally
      # just returning launch_resolve_stage's own value, truthy either way) made launch_advance
      # treat a just-forked stage as "worth re-checking immediately", which finds it still
      # 'pending' and dispatches it *again* - a real double-dispatch bug, found by the test
      # suite actually forking real children and observing duplicate dispatch-log entries, not
      # assumed.
      return { 'skipped' => 1, 'name' => $stage };
   }

   local $SIG{'CHLD'} = 'DEFAULT';
   my $pid;
   if ( $pid = fork ) {
      # PARENT (docker-event-daemon itself) - free to return immediately either way.
      $SIG{'CHLD'} = sub { waitpid $pid, 0; $SIG{'CHLD'} = 'DEFAULT'; };
      return { 'started' => 1, 'name' => $stage };
   }

   # CHILD - does the one (blocking) dispatch, records its own outcome via $spec->{'dispatch'}
   # (which ends in a launch_resolve_stage call), and exits. Never dispatches anything else -
   # cascading to dependents is deliberately left for docker-event-daemon's own next
   # launch_advance pass to notice, not done here.
   #
   # exit(0) MUST run no matter what $spec->{'dispatch'} does, including throwing - this is a
   # forked copy of docker-event-daemon's *entire* process, mid-call-stack, several levels
   # under an on_tick handler that's deliberately wrapped in try/catch (so one bad tick can't
   # crash the daemon). An uncaught exception here, without the eval below, would propagate
   # straight up through this fork's own copy of that same try/catch, which "handles" it by
   # logging and moving on - except "moving on", in this process, means falling back into
   # docker-event-daemon's own on_tick closure and its enclosing $loop->run(), i.e. resuming the
   # entire event loop as a second, permanent, rogue copy of the whole daemon - competing for
   # the same Docker events, double-dispatching everything indefinitely. Found exactly this way,
   # live: an orphaned docker-event-daemon process, PPID pointing at the legitimate one, with its
   # own independent event counter and its own "docker events" subprocess, causing duplicate
   # launch:ide dispatches and a skipped lifecycle:launch in the integration suite - not a
   # theoretical concern.
   #
   # Re-fetch fresh before dispatching, discarding whatever $self this fork inherited from its
   # caller - it was already however old that caller's own load was, and it's about to be used
   # to build this dispatch's actual exec env (SSH keys, developers, IDE choice, options - see
   # _launch_dispatch_prep/_launch_dispatch_exec's own env-building) and applicable() gating, not
   # just to decide whether to fork at all. Falls back to the inherited $self if the reservation
   # has disappeared since (e.g. removed mid-flight) rather than dispatching against nothing.
   Data::load( 'config.json', 'users.json', 'roles.json', 'reservations.json', 'containers.json' );
   if ( my $fresh = Reservation->load( { 'id' => $self->id() } )->[0] ) {
      $self = $fresh;
   }

   eval { $spec->{'dispatch'}->($self); };
   if ($@) {
      flog( "Reservation::launch_maybe_dispatch: CHILD for '$stage' died (exiting regardless): " . ( ref($@) ? $@->dbg : $@ ) );
   }
   exit(0);
}

# Dispatches $name (lifecycle:launch/lifecycle:start) via dispatch_hook_exec() - the exact same
# mechanism an on-demand invocation uses - then translates its outcome into a
# launch_resolve_stage() call (recording it; see that function's own comment for why it no
# longer cascades from here). Deliberately NOT done by making dispatch_hook_exec itself resolve
# the DAG stage: it's shared with run_hook_sync's genuinely on-demand invocations (including
# manual re-invocation of these same two names), which must never affect DAG state - a user
# manually re-running 'lifecycle:launch' later shouldn't touch launch_advance's view of this
# launch cycle at all. So dispatch_hook_exec keeps writing its usual rich on-demand-shaped
# record (state/exitCode/timedOut/busy) unchanged for every caller, on-demand or DAG-driven
# alike - only this wrapper, called exclusively from the DAG's own dispatch closures,
# additionally re-reads that same record afterward and derives the DAG's simpler
# done/failed/timedOut signal from it. Relies on dispatch_hook_exec being blocking/synchronous
# (see launch_maybe_dispatch's transport note) - becomes a completion callback instead if that
# ever changes.
# Maps a raw hook_status() record to the DAG's simpler done/failed/timedOut/skipped vocabulary
# (see launch_resolve_stage) - shared by _launch_dispatch_hook_stage and launch_advance below,
# both of which need to translate a settled hookStatus entry into a state to record.
sub _launch_state_from_hook_status ($status) {
   return 'failed'   unless $status;
   return 'failed'   if $status->{'state'} eq 'aborted';
   return 'timedOut' if $status->{'timedOut'};
   return ( $status->{'exitCode'} // 1 ) == 0 ? 'done' : 'failed';
}

sub _launch_dispatch_hook_stage ($self, $name) {
   # 'pid' => $$ - see _launch_dispatch_exec's own comment on why this matters (same mechanism,
   # same fix); run_hook_sync's on-demand path already gets this right (passes its own $$ too -
   # see below), this auto-invoke path just hadn't been given the same treatment.
   $self->dispatch_hook_exec( $name, $self->hook_script($name), { 'user' => $NONROOT_USER->($self), 'pid' => $$ } );
   $self->launch_resolve_stage( $name, _launch_state_from_hook_status( $self->hook_status($name) ) );
}

my @LAUNCH_STAGE_NAMES = keys %LAUNCH_STAGES;

# Marks every launch:-DAG stage 'pending' - not yet touched in the new launch cycle about to
# begin. Called exactly once per genuine container 'start' Docker event (docker-event-daemon's
# onContainerStart, before its first launch_maybe_dispatch('launch:prep') call for that event -
# never from the pendingLaunch retry-loop's own repeated calls for the *same* event, which must
# keep seeing whatever this reset already put in place), so that launch_maybe_dispatch's
# idempotency guard sees a fresh cycle rather than the previous one's already-resolved status.
#
# Why overwrite to a 'pending' marker rather than delete the old entries outright: the merge
# every write here goes through (Util::cloneHash, via Reservation::Mutate::update) can only add
# or overwrite a key that's present in the update, never remove one that isn't - see the
# "hooks.status is the master record" comment above. A key simply absent from this reset's
# update would leave the stale on-disk entry untouched, defeating the point. Overwriting with
# an explicit, distinctly-named state both sides (this function and launch_maybe_dispatch's
# guard) agree on achieves the same effect within that constraint.
#
# Sends only the 5 launch:-stage names, via store_fields - never the whole hooks.status hash
# (which may also hold entries for on-demand/custom hook names this function has no business
# touching, and which - if read into this process's own in-memory copy any time earlier - could
# be stale relative to a concurrent on-demand invocation's own more recent write, clobbering it
# on write-back exactly the way store_fields' own comment describes).
sub launch_reset_stages ($self) {
   my $entries = { map { $_ => { 'name' => $_, 'state' => 'pending' } } @LAUNCH_STAGE_NAMES };
   my $status = ( $self->{'data'}{'hooks'} //= {} )->{'status'} //= {};
   %$status = ( %$status, %$entries );
   $self->store_fields( { 'data' => { 'hooks' => { 'status' => $entries } } } );
}

# True if this reservation's launch DAG still has work left for launch_advance to do -
# docker-event-daemon uses this to decide whether to keep polling a reservation on its own
# periodic tick, or stop (see launch_advance's own comment on the %launchInFlight tracking set).
#
# launch:ide is deliberately excluded from this check once it's reached 'running': unlike every
# other stage, it never resolves in the happy path (it's the perpetual IDE process, not a script
# that exits) and has no dependents, so treating its ongoing 'running' state as "still needs
# attention" would mean every healthy devtainer stays in the tracking set, polled, forever. That
# would effectively reintroduce continuous IDE health polling via docker-event-daemon - which
# the design deliberately does NOT take on as a priority (see item F's "IDE health-poll
# deprioritization" note; a future in-container supervisor is the intended owner of that, for
# all three of dropbear/wstunnel/the IDE, not docker-event-daemon polling just the one it can
# reach). This only skips *further* checks - launch_advance's own scan still dispatches and
# observes launch:ide exactly once, like any other stage, on the pass where it first becomes
# eligible.
sub launch_in_flight ($self) {
   for my $name (@LAUNCH_STAGE_NAMES) {
      next if $name eq 'launch:ide';
      my $state = ( $self->hook_status($name) // {} )->{'state'} // 'pending';
      return 1 if $state eq 'pending' || $state eq 'running';
   }
   return 0;
}

# Advances this reservation's launch DAG by one scan: dispatches whatever's newly eligible
# ('pending' with its dependencies cleared - see _launch_deps_cleared), and self-heals whatever
# is stuck 'running' with a dead process behind it (hook_is_running's own poll-and-reconcile,
# unchanged - see its comment). This is the single mechanism for both jobs launch_resolve_stage
# and launch_reconcile_stuck_stages used to split between them: ordinary cascade-forward
# progress and restart-recovery are now just this same scan, called from a different place (see
# docker-event-daemon's own %launchInFlight tracking and its DED-startup seeding, which covers
# what a one-time reconcile-at-startup sweep used to be responsible for alone) - a stage left
# stuck 'running' by a docker-event-daemon restart (its live completion callback permanently
# lost - no reconnect/replay is possible for an exec's stream) is caught by the very same
# 'running' branch below as any other in-flight reservation's next ordinary tick would use.
#
# Loops internally until a full pass makes no further progress (bounded by the DAG's size - at
# most a handful of passes, ever): a stage resolving 'skipped' happens synchronously, with no
# fork, so its own dependents can become eligible within this same call rather than waiting for
# docker-event-daemon's next tick - only a genuine (forked) dispatch actually has to wait for a
# later call to notice it settled.
sub launch_advance ($self) {
   # Tracks names already given to launch_maybe_dispatch *within this one call*, regardless of
   # what the status file says - necessary in addition to launch_maybe_dispatch's own
   # status-based guard, not instead of it. A just-forked stage's status is still 'pending' from
   # this process's point of view (its child hasn't had a chance to write 'running' yet - that
   # can only happen after this call returns and the caller reaps it), so a *different* stage's
   # synchronous skip re-triggering the while loop below would otherwise walk straight past the
   # status guard and dispatch the same just-forked stage a second time, in the same call -
   # found by the test suite actually forking real children and observing a duplicate dispatch,
   # not assumed.
   my %dispatchedThisCall;
   my $progressed = 1;
   while ($progressed) {
      $progressed = 0;
      for my $name (@LAUNCH_STAGE_NAMES) {
         next if $dispatchedThisCall{$name};

         my $before = $self->hook_status($name);
         my $state = ( $before // {} )->{'state'} // 'pending';

         if ( $state eq 'running' ) {
            $self->hook_is_running($name);   # self-heals in place (via hook_status_completed) if dead
            my $after = $self->hook_status($name);
            $progressed = 1 if ( ( $after // {} )->{'state'} // '' ) ne $state;
            next;
         }

         next unless $state eq 'pending' && $self->_launch_deps_cleared($name);
         my $result = $self->launch_maybe_dispatch($name);
         $dispatchedThisCall{$name} = 1;
         # Only a synchronous 'skipped' resolution (see launch_maybe_dispatch's own comment on
         # why this distinction matters) means there might be more to do within this same call -
         # a real (forked) dispatch leaves $name still 'pending' from this process's point of
         # view until its child gets around to writing 'running', so re-scanning immediately
         # would just re-dispatch it - %dispatchedThisCall is what actually prevents that; this
         # flag is only about whether it's worth looping again at all.
         $progressed = 1 if $result && $result->{'skipped'};
      }
   }
}

# Dispatches a bare launch.sh entry-point function (launch:prep/launch:git/launch:ide - no hook
# name/script involved, unlike dispatch_hook_exec above, which lifecycle:launch/lifecycle:start
# use instead, via _launch_dispatch_hook_stage) and records its outcome the same way. Base env
# is _hook_env() (GIT_URL/SSH_KNOWN_HOSTS_DOMAINS/DOCKSIDE_OPTION_*/GH_TOKEN) plus
# ide_command_env() (the reservation's own IDE-record env, e.g. per-IDE-type vars - included
# for all three of these stages, matching how the single combined exec() this replaces always
# included it) - both were already part of every launch before item F, for every stage that
# came from it. $opts:
#   detach     => 1          required for launch:ide specifically, see item F's Enabler
#      section - dispatches via docker_exec's Detach:true and returns immediately: only
#      hook_status_started/hook_status_set_running_details ever get called for it in the
#      normal case, never hook_status_completed (see item F coupling 4's launch:ide lifecycle
#      note - it stays 'running' indefinitely, either overwritten by the next restart's fresh
#      dispatch or lazily self-healed by hook_is_running's own dead-detection).
#   extra_env  => [...]      "KEY=VALUE" strings specific to this stage, on top of the base
#      env above - see each stage's own dispatch closure in %LAUNCH_STAGES for what it needs
#      and why (this mirrors exec()'s old single-dispatch env-building, now split per stage).
#   on_success => sub ($self) { ... }   optional, called (only on real success - a real,
#      confirmed exit code of 0) after the exec completes but before launch_resolve_stage -
#      launch:prep's own dispatch (_launch_dispatch_prep below) uses this to persist
#      DOCKSIDE_START_COUNT only once dispatch is confirmed to have actually succeeded,
#      mirroring exec()'s original "don't burn a count on a failed dispatch" reasoning.
sub _launch_dispatch_exec ($self, $stage, $function, $user, $opts = {}) {
   my @Command = $self->ide_command();
   die Exception->new( 'msg' => 'Internal error - no IDE command configured', 'dbg' => 'Reservation::_launch_dispatch_exec: ide_command() returned empty' ) unless @Command;
   $Command[-1] = $function;

   my $owner = $self->owner('username');
   my $userObj = User->load($owner);
   die Exception->new( 'msg' => "The owner of this devtainer ('$owner') no longer exists", 'status' => 400 ) unless $userObj;

   my @env = (
      ( map { my $e = $_; $e =~ s/^--env=//; $e } $self->_hook_env($userObj) ),
      ( map { my $e = $_; $e =~ s/^--env=//; $e } $self->ide_command_env() ),
      @{ $opts->{'extra_env'} // [] },
   );

   # Distinct from a user-declared hook's own --timeout - see item F's own open question on
   # whether this deserves a separate config knob; reusing the same default for now.
   my $timeout = $CONFIG->{'hooks'}{'defaultTimeoutSeconds'} || 120;
   my $containerId = $self->containerId();

   # No logPath - launch:prep/launch:git still log in-container to $LOG as today; echoing that
   # out to a standard outer location (per the "Concretized and decided" section) needs the
   # on_output wiring below, not a status-record field. launch:ide never had one to begin with
   # (see coupling 4).
   $self->hook_status_started($stage, undef);

   flog( "Reservation::_launch_dispatch_exec: DISPATCHING '$stage' (via exec API): " . join( '|', map { sanitize_sensitive_text($_) } @Command ) );

   # This process's own pid ($$) - not undef - is what makes hook_is_running's cheap kill(0,
   # $pid) liveness check meaningful for this stage (see hook_status_set_running_details' own
   # comment). Passing undef here (as this used to) disables that check entirely for
   # launch:prep/launch:git/launch:ide - hook_is_running then falls through to the Docker API's
   # own /exec/.../json on every single self-heal poll while 'running', which can (and, found
   # live, reliably does) independently conclude "done" via the real exec's ExitCode *before*
   # this actual process - the one still running $opts->{'on_success'} below - gets there
   # itself. That race silently skips on_success entirely: docker-event-daemon's own self-heal
   # marks the stage 'done' correctly, but never runs the side effect only this process knows
   # about (launch:prep's own startCount increment) - found exactly this way, live: lifecycle:launch
   # never firing because its own applicable() gate read startCount before this process's
   # on_success had a chance to persist it, even though the increment demonstrably completed
   # (and, moments too late, correctly) shortly after. With a real pid, kill(0,$pid) keeps
   # reporting "still running" for as long as *this process* hasn't finished its own complete
   # work - including on_success - which is exactly the property needed here.
   if ( $opts->{'detach'} ) {
      docker_exec( $CONFIG->{'docker'}{'socket'}, $containerId, {
         'Cmd' => \@Command, 'User' => $user, 'Env' => \@env,
      }, {
         'Detach'     => 1,
         'on_created' => sub ($execId) { $self->hook_status_set_running_details($stage, $$, $execId); },
      } );
      $opts->{'on_success'}->($self) if $opts->{'on_success'};
      return { 'started' => 1, 'name' => $stage };
   }

   try {
      my $result = docker_exec( $CONFIG->{'docker'}{'socket'}, $containerId, {
         'Cmd' => \@Command, 'User' => $user, 'Env' => \@env,
      }, {
         'inactivity_timeout' => $timeout + 30,
         'request_timeout'    => $timeout,
         'on_created'         => sub ($execId) { $self->hook_status_set_running_details($stage, $$, $execId); },
         # TODO (item F "Concretized and decided"): echo frames to a standard outer log
         # location here, mirroring dispatch_hook_exec's on_output - not wired up yet.
      } );

      my $rc = $result->{'exitCode'};
      my $timedOut = $result->{'timedOut'} ? 1 : 0;
      my $success = !$timedOut && defined($rc) && $rc == 0;
      $opts->{'on_success'}->($self) if $success && $opts->{'on_success'};
      $self->launch_resolve_stage( $stage, $timedOut ? 'timedOut' : ( $success ? 'done' : 'failed' ) );
   }
   catch {
      my $dbg = ref($_) ? $_->dbg() : "$_";
      flog("Reservation::_launch_dispatch_exec: caught exception dispatching '$stage': $dbg");
      $self->launch_resolve_stage( $stage, 'failed' );
   };

   return { 'started' => 1, 'name' => $stage };
}

# launch:prep's own dispatch - not just a plain _launch_dispatch_exec call, because this stage
# carries two things specific to it alone, both preserved from exec() (the single-dispatch
# function this whole item F split replaces):
#
# 1. SSH-related env (AUTHORIZED_KEYS/HOSTDATA_PATH/SSHD_ENABLE, only when this profile has ssh
#    enabled at all - needed by update_ssh_authorized_keys/launch_sshd inside launch_prep
#    itself) plus OWNER_DETAILS/SSH_AGENT_KEYS (needed by populate_ssh_agent_keys inside
#    run_prep_nonroot, launch_prep's own non-root tail).
# 2. DOCKSIDE_START_COUNT's compute-before/persist-after-confirmed-success dance - see
#    exec()'s own original comment, preserved verbatim in spirit: computed before dispatch (so
#    a prospective value exists to reason about), but only ever persisted once _launch_dispatch_exec
#    confirms real success via its on_success callback - never on a failed or merely-attempted
#    dispatch, which would otherwise burn a count without launch:prep (and everything gated on
#    it) having actually run. This is exactly the moment data('startCount') becomes the value
#    launch:git's own dispatch (see %LAUNCH_STAGES) and the lifecycle:launch/lifecycle:start
#    'applicable' predicates read afterward - by the time either dispatches, launch:prep has
#    already succeeded, so the count is already final.
sub _launch_dispatch_prep ($self) {
   my $owner = $self->owner('username');
   my $userObj = User->load($owner);
   die Exception->new( 'msg' => "The owner of this devtainer ('$owner') no longer exists", 'status' => 400 ) unless $userObj;

   my @env;
   if ( $self->profileObject->ssh ) {
      my @developersMeta = split( ',', $self->meta('developers') );
      my @developers = grep { !/^role:/ } @developersMeta;
      my %developerRoles = map { s/^role://; ( $_ => 1 ); } grep { /^role:/ } @developersMeta;
      my @usersHavingDeveloperRoles = map { $developerRoles{ $_->{'role'} } ? $_->{'username'} : () } @{ User->viewers };
      my @usernames = unique(
         $self->owner('username'),
         $self->meta('access')->{'ssh'} eq 'developer' ? ( @developers, @usersHavingDeveloperRoles ) : ()
      );
      my @Users = map { User->load($_) } @usernames;
      my @authorized_keys = sort { $a cmp $b } unique map { $_ ? @{ $_->authorized_keys() } : () } @Users;
      push @env,
         "AUTHORIZED_KEYS=" . encode_json( \@authorized_keys ),
         "HOSTDATA_PATH=$CONFIG->{'ssh'}{'path'}",
         "SSHD_ENABLE=1";
   }
   push @env,
      "OWNER_DETAILS=" . encode_json( $userObj->details_full ),
      "SSH_AGENT_KEYS=" . encode_json( $userObj->keypairs_all() );

   # Store before dispatch so the UI reflects the intended IDE immediately, including during
   # any retry window before the dispatch succeeds - matches exec()'s original placement.
   # Narrow store - see store_fields' own comment.
   $self->data( 'runningIDE', $self->meta('IDE') );
   $self->store_fields( { 'data' => { 'runningIDE' => $self->data('runningIDE') } } );

   # This is a *prospective* value, purely informational for the container (DOCKSIDE_START_COUNT
   # below) - launch:prep dispatches at most once per cycle (the same idempotency guard every
   # launch:-stage gets), so nothing else can be concurrently incrementing this reservation's
   # startCount right now, and this read/computation is expected to agree with the atomic
   # increment on_success performs below. It is NOT the persisted source of truth
   # lifecycle:launch's own applicable() gate reads - see increment_start_count's own comment for
   # why that needs a genuine read-under-lock, not a value computed here and stored later.
   my $startCount = ( $self->data('startCount') // 0 ) + 1;

   return $self->_launch_dispatch_exec( 'launch:prep', 'launch_prep', $ROOT_USER->($self), {
      'extra_env'  => [ @env, "DOCKSIDE_START_COUNT=$startCount" ],
      'on_success' => sub ($self) { $self->increment_start_count(); },
   } );
}

1;
