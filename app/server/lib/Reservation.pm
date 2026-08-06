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
# all, so cloneHash never touches it.
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
# own in-memory copy, so a later read in the same process sees the value it just committed.
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

# $command is undef for exactly one caller shape: docker-event-daemon's genuine container-start
# dispatch (a live container-start event, or its deferred pendingLaunch retry once the launcher
# is ready) - the only case that represents "this devtainer just started". Every other caller
# (User::updateContainerReservation's 'update_ssh_authorized_keys', and 'restart_ide' if
# re-enabled) always passes an explicit command naming a one-off action on an already-running
# container. This distinction (not "is it 'restart_ide'?") is what gates the startCount
# increment below - see docs/plans/lifecycle-hooks-review-followup.md item E.
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

      # Store before exec so the UI reflects the intended IDE immediately.
      $reservation->data('runningIDE', $reservation->meta('IDE'))->store();

      run_system($CONFIG->{'docker'}{'bin'}, 'exec', '-d', '-u', $reservation->unixuser(), $containerId, @Command);

      return 1;
   }

   # Server-side start count, injected as DOCKSIDE_START_COUNT so launch.sh can tell a
   # genuine first start (fires 'lifecycle:launch') from every later restart (fires
   # 'lifecycle:start' instead - see below). Named for what it actually counts - every
   # container-start event, including the first - not "launch" in the product-vocabulary sense
   # of a one-time devtainer creation (see docs/plans/lifecycle-hooks-review-followup.md item E
   # for the launch-vs-start distinction this whole split is built on). Computed here but only
   # persisted after run_system() below confirms the exec dispatch itself succeeded (it dies on
   # failure) - deliberately not before: incrementing first would burn a count on a dispatch
   # that never reached the container at all, permanently skipping 'lifecycle:launch' on what
   # is still genuinely this devtainer's first real start next time. This does not cover every
   # failure mode (a dispatch that succeeds but dies inside the container before reaching the
   # hook still consumes the count) - closing that gap needs a completion signal from inside
   # the container, which is item D; not a blocker for this.
   my $startCount = defined($command) ? undef : ($reservation->data('startCount') // 0) + 1;

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

   # Two separate env slots, not one: this single exec runs the whole perpetual launch_ide
   # process, which must be able to auto-fire BOTH 'lifecycle:launch' (only on this devtainer's
   # true first start, gated below on DOCKSIDE_START_COUNT) and 'lifecycle:start' (every start,
   # including this one) without a second `docker exec` - see item E. Each name's script is
   # resolved separately since they may differ (or either may be unconfigured).
   my @envHook;
   if( my $script = $reservation->hook_script('lifecycle:launch') ) {
      @envHook = ( "--env=DOCKSIDE_HOOK_SCRIPT=$script" );
   }
   my @envHookStart;
   if( my $script = $reservation->hook_script('lifecycle:start') ) {
      @envHookStart = ( "--env=DOCKSIDE_HOOK_SCRIPT_START=$script" );
   }
   my @envStartCount = defined($startCount) ? ( "--env=DOCKSIDE_START_COUNT=$startCount" ) : ();

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
   # including during any retry window before the exec succeeds.
   $reservation->data('runningIDE', $reservation->meta('IDE'))->store();

   run_system($CONFIG->{'docker'}{'bin'}, 'exec', '-d', '-u', 'root',
      ($reservation->ide_command_env()),
      "--env=OWNER_DETAILS=$user_details",
      "--env=SSH_AGENT_KEYS=" . encode_json( $user->keypairs_all() ),
      @envCommonHook,
      @envHook,
      @envHookStart,
      @envStartCount,
      @envSSH,
      @envDevContainer,
      @envIDE,
      $containerId,
      @Command
   );

   # Persist the increment only now that run_system() has confirmed the exec dispatch itself
   # succeeded (see the comment where $startCount was computed above).
   $reservation->data('startCount', $startCount)->store() if defined $startCount;

   return 1;
}

# The env vars any hook invocation (the launch-time auto-invoke, dispatched in-process by
# launch.sh itself, or a later `docker exec ... launch.sh run_hook` built here) needs
# regardless of which specific hook is running: the same GIT_URL/SSH_KNOWN_HOSTS_DOMAINS,
# DOCKSIDE_OPTION_* and GH_TOKEN env this reservation's IDE launch already gets - shared here
# to avoid duplicating/drifting that logic between exec() and run_hook_sync(). Deliberately
# does NOT resolve a hook script path itself (unlike an earlier version of this function) -
# exec() may need up to two script paths at once ('lifecycle:launch' and 'lifecycle:start',
# see above) and run_hook_sync passes its one script path directly as a launch.sh CLI
# argument instead (see below), so each caller resolves whichever script(s) it needs itself.
#
# Returns `docker` CLI flag strings ("--env=KEY=VALUE"), not plain "KEY=VALUE" - matching
# exec()'s own @envHook/@envIDE/etc. below, since exec() still shells out to the `docker` CLI
# directly (run_system(...'exec','-d',...,@envCommonHook,...)). run_hook_sync (see item B)
# dispatches via the Docker Engine API's exec/create instead, whose `Env` field wants plain
# "KEY=VALUE" strings - a real bug, caught by the integration suite, not by this session's own
# manual testing (which never actually inspected DOCKSIDE_OPTION_* forwarding specifically):
# passing "--env=KEY=VALUE" straight into that JSON field doesn't error, it just silently
# creates a nonsense env var literally named "--env" whose value is "KEY=VALUE" - so
# DOCKSIDE_OPTION_* (and GIT_URL/GH_TOKEN) never reached the hook process at all. Fixed at
# run_hook_sync's own call site (strips the prefix there) rather than changing this function's
# output format, since exec() still needs the CLI-flag form.
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
# Safe to update via the ordinary store() below despite concurrent forked children invoking
# *different* names on the same reservation: Util::cloneHash (which store()'s update() uses)
# recurses into nested hashes key-by-key, so two such writes merge additively rather than one
# clobbering the other - the extra 'hooks' nesting level is just as safe, since cloneHash
# recurses through it the same way.
#
# hooks.history is a bounded, oldest-first array of past invocations across all names.
# Deliberately NOT maintained via store() - cloneHash only recurses into hashes; an array
# value is compared by reference and replaced wholesale, so two concurrent appends via that
# path would race and the loser's row would simply be lost. record_hook_history()
# (Reservation::Mutate) instead re-reads the reservation fresh under its own atomic mutate()
# lock, appends, evicts, and writes back - safe under genuine concurrency.

my $HOOK_HISTORY_MAX = 100;

# Internal helpers isolating hooks.status's read/write boilerplate - every accessor below
# reads the whole per-name status hash, mutates one entry, and writes the whole 'hooks' data
# key back (history lives alongside it, untouched by these two).
sub _hook_status_all ($self) {
   return ($self->data('hooks') // {})->{'status'} // {};
}

sub _hook_status_store ($self, $all) {
   my $hooks = $self->data('hooks') // {};
   $hooks->{'status'} = $all;
   $self->data('hooks', $hooks)->store();
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
         return 1 if decode_json($res->body)->{'Running'};
      }
   }

   # Neither signal confirms liveness - self-heal the record (so a future check, and any
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
   my $all = $self->_hook_status_all;
   $all->{$name} = {
      'name'      => $name,
      'state'     => 'running',
      'pid'       => undef,
      'execId'    => undef,
      'logPath'   => $logPath,
      'startTime' => YYYYMMDDHHMMSS(time),
   };
   $self->_hook_status_store($all);
}

# Called by the forked child once it knows both its own pid ($$) and the exec id
# (docker_exec's on_created callback) - see hook_status_started above for why these can't be
# known any earlier.
sub hook_status_set_running_details ($self, $name, $pid, $execId) {
   my $all = $self->_hook_status_all;
   return unless $all->{$name};
   $all->{$name}{'pid'} = $pid;
   $all->{$name}{'execId'} = $execId;
   $self->_hook_status_store($all);
}

# Called by the forked child once the hook has finished, timed out, or been confirmed aborted,
# recording the outcome on both the master record and the bounded history array. $fields must
# include 'state' explicitly ('done' or 'aborted') - never defaulted, so a caller can never
# accidentally leave a completed entry reading 'running' by omission.
sub hook_status_completed ($self, $name, $fields) {
   my $all = $self->_hook_status_all;
   my $entry = { %{ $all->{$name} // { 'name' => $name } }, %$fields };
   $all->{$name} = $entry;
   $self->_hook_status_store($all);

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

   my @Command = $self->ide_command();
   die Exception->new( 'msg' => 'Internal error - no IDE command configured', 'dbg' => 'Reservation::run_hook_sync: ide_command() returned empty' ) unless @Command;
   $Command[-1] = 'run_hook';
   push( @Command, $name );
   # launch.sh's run_hook() takes the script path as an explicit argument (see item E) rather
   # than reading a fixed env var, so every on-demand invocation passes it here directly.
   push( @Command, $script );

   my $owner = $self->owner('username');
   my $user = User->load($owner);
   die Exception->new( 'msg' => "The owner of this devtainer ('$owner') no longer exists", 'status' => 400 ) unless $user;

   # _hook_env returns `docker` CLI flag strings ("--env=KEY=VALUE" - see its own comment) for
   # exec()'s sake; docker_exec() below dispatches via the Docker Engine API instead, whose
   # `Env` field wants plain "KEY=VALUE" strings - strip the CLI-flag prefix here, at this
   # call site only, rather than changing _hook_env's own output format.
   my @env = map { my $e = $_; $e =~ s/^--env=//; $e } $self->_hook_env($user);

   my $timeout = $args->{'timeout'} || $CONFIG->{'hooks'}{'defaultTimeoutSeconds'} || 120;
   die Exception->new( 'msg' => "'timeout' must be a positive integer number of seconds", 'status' => 400 )
      unless $timeout =~ /^[1-9][0-9]*$/;

   my $containerId = $self->containerId();

   # Cheap, local, no docker round-trip - see hook_is_running's own comment for exactly what
   # this does and doesn't guarantee (it is not the thing overlap-safety depends on).
   if( $self->hook_is_running($name) ) {
      return { 'busy' => 1 };
   }

   my $invocationId = sprintf( "%08x", int(rand(0xffffffff)) ^ $$ );
   my $logPath = "$CONFIG->{'tmpPath'}/r-" . $self->id() . "-hook-$invocationId.log";
   $self->hook_status_started($name, $logPath);

   flog( "Reservation::run_hook_sync: DISPATCHING (async, via exec API): " . join( '|', map { sanitize_sensitive_text($_) } @Command ) );

   # Fork - exactly Reservation::launch's existing pattern (see item B: "the pattern already
   # exists in this codebase") - parent returns immediately, freeing the caller; the forked
   # child does the actual dispatch-and-wait via docker_exec() directly, no CLI involved.
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
   try {
      open( my $log, '>>', $logPath )
         or die Exception->new( 'dbg' => "Reservation::run_hook_sync child: cannot open log '$logPath': $!" );
      $log->autoflush(1);

      my $result = docker_exec( $CONFIG->{'docker'}{'socket'}, $containerId, {
         'Cmd'  => \@Command,
         'User' => $self->unixuser(),
         'Env'  => \@env,
      }, {
         # A generous margin over $timeout, not $timeout itself - request_timeout below is
         # what actually enforces the hook's own configured budget; this only guards against
         # a truly stalled connection outliving that.
         'inactivity_timeout' => $timeout + 30,
         'request_timeout'    => $timeout,
         # Fires before docker_exec's own (blocking) start-and-stream call, so the exec id
         # reaches the status record as early as possible - see hook_status_started's comment
         # for why this can't be known any earlier than this, from the child, using its own
         # real pid ($$, not the parent's - the parent never learns the child's pid until
         # fork() returns, well before the exec is even created).
         'on_created' => sub ($execId) { $self->hook_status_set_running_details($name, $$, $execId); },
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
      flog("Reservation::run_hook_sync child: caught exception dispatching '$name': $dbg");
      $self->hook_status_completed( $name, { 'state' => 'aborted' } );
   };

   exit(0);
}

1;
