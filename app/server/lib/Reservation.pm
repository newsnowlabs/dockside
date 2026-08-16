package Reservation;

use v5.36;

use JSON;
use Expect;
use Try::Tiny;
use Tie::File;
use Storable qw(dclone);
use URI::Escape;
use Mojo::Promise;
use Reservation::Mutate qw(update load_clean_map record_hook_history increment_data_field hook_claim_if_not_running);
use Reservation::Load;
use Reservation::Launch;
use Containers;
use Profile;
use Util qw(flog wlog trim is_true clean_pty run TO_JSON YYYYMMDDHHMMSS cacheReadWrite call_socket_api_sync call_socket_api docker_exec unique run_system get_uri sanitize_sensitive_text);
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
   # return what we have now. $data->{'id'} is absent (undef) for a genuinely
   # new reservation being created, not just for the 'new' dummy-object request.
   if( ($data->{'id'} // '') eq 'new' ) {
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
      # createStatus is a structured {stage, failed, layers} hash written by create -
      # shape-tolerant here because a reservation created before this branch's own launch()
      # (deleted) may still have the old plain truthy/falsy exit-code value on disk. A bare
      # truthy-hashref check would be wrong for the new shape: {} is truthy in Perl regardless
      # of whether 'failed' is set, so create's very first (in-flight, not-yet-failed)
      # write would otherwise show -4 immediately.
      else {
         my $cs = $r->{'createStatus'};
         my $failed = ref($cs) eq 'HASH' ? $cs->{'failed'} : $cs;
         $r->{'status'} = $failed ? -4 : -2;
      }
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

# Tails a hook invocation's outer log file (dispatch_hook_exec's own on_output callback,
# below, writes the hook's stdout+stderr frames here as they arrive) for a status/log read
# endpoint to serve - see User::runContainerHookStatus and bin/app-server's GET
# /containers/<id>/hook/status route. Last $maxLines lines via Tie::File, read fresh from
# disk on every call, no in-process caching - cheap for "poll a status field, fetch the
# tail" use. No synthetic termination line to strip: docker_exec()'s on_output
# callback writes only the hook's own raw stdout/stderr bytes.
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

   my $result = call_socket_api_sync(
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
            'data' => [ qw( FQDN parentFQDN image runtime network unixuser gitURL runningIDE options startCount hooks ) ]
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

# The one survivor of the old action()/action_async() split that stays synchronous - a fast
# local read, never worth an async version. Stop/start/remove (see action() below) are the
# genuinely slow ones; getLogs isn't, so it isn't routed through action() at all.
sub getLogs ($self, $args = {}) {
   return $self->load_container_logs({
      'stdout' => is_true($args->{'stdout'}) ? { 'clean_pty' => is_true($args->{'clean_pty'}) } : undef,
      'stderr' => is_true($args->{'stderr'}) ? { 'clean_pty' => is_true($args->{'clean_pty'}) } : undef,
      'merge' => is_true($args->{'merge'})
   });
}

# stop/start/remove via the Docker Engine API directly (call_socket_api), no docker CLI
# subprocess, no fork at all. Idempotent at Docker's own level for all three (repeat calls return
# 304/304/404 respectively) - no guard needed, unlike create above. getLogs (above) is the one
# container command that stays synchronous, never routed through here.
sub action ($self, $action, $args, $cb) {
   my $containerId = $self->containerId();
   my ( $method, $path );

   if ( $action eq 'stop' ) {
      my $t = $args->{'t'} // 10;   # Docker CLI's own default stop grace period
      ( $method, $path ) = ( 'POST', "/containers/$containerId/stop?t=$t" );
   }
   elsif ( $action eq 'start' ) {
      ( $method, $path ) = ( 'POST', "/containers/$containerId/start" );
   }
   elsif ( $action eq 'remove' ) {
      ( $method, $path ) = ( 'DELETE', "/containers/$containerId?v=true" );
   }
   else {
      die Exception->new( 'msg' => "Unknown docker container action '$action'" );
   }

   call_socket_api(
      $CONFIG->{'docker'}{'socket'}, $path, { 'method' => $method },
      sub ( $result, $err ) {
         flog( "Reservation::action: '$action' on '$containerId' "
            . ( $err ? "failed: $err" : 'returned ' . ( $result ? $result->code : '(no result)' ) ) );
         $cb->( $result, $err );
      }
   );
   return;
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
# writer whose own dispatch took several seconds before finally writing (a slow docker_exec
# call, say): its own in-memory snapshot of every unrelated field is exactly that many seconds
# stale by the time it stores.
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

# Fetches the devcontainer.json for this reservation's gitURL, if it points at a GitHub repo:
# tries 'main' first, only falling back to 'master' if 'main' fails or returns unparseable
# JSON - built on get_uri so User::createContainerReservation's own async chain never
# blocks the reactor while GitHub responds. Expressed as a recursive callback chain (there's
# no early 'return' across an async boundary). $cb fires exactly once, with the decoded
# devcontainer.json hashref, or undef if there is none (no gitURL, non-GitHub URL, or neither
# branch has one).
sub getGitDevContainer ($self, $cb) {
   my $uri = $self->data('gitURL');
   flog("getGitDevContainer: uri=" . ($uri // ''));

   return $cb->(undef) unless $uri;

   unless ( $uri =~ m!^(?:https://github.com/|git\@github\.com:)(.*)\.git$! ) {
      return $cb->(undef);
   }
   my $path = $1;

   my $tryBranch;
   $tryBranch = sub (@branches) {
      unless (@branches) {
         $cb->(undef);
         return;
      }
      my ( $branch, @rest ) = @branches;
      my $devcontainerUri = "https://raw.githubusercontent.com/$path/refs/heads/$branch/.devcontainer/devcontainer.json";

      get_uri( $devcontainerUri, sub ($result) {
         flog( "getGitDevContainer: uri=$devcontainerUri; result=" . ( $result // '(none)' )
            . "; is_success=" . ( ( $result && $result->is_success ) ? 1 : 0 ) );

         if ( $result && $result->is_success ) {
            my $body = $result->body;
            $body =~ s!//.*$!!gm;
            my $decoded = eval { decode_json($body) };
            if ($decoded) {
               $cb->($decoded);
               return;
            }
         }
         $tryBranch->(@rest);
      } );
   };
   $tryBranch->( qw( main master ) );

   return;
}

# Updates createStatus both in-memory (so this same process's own later reads - including
# cloneWithConstraints/sanitise, and hence anything that returns $self to a client after this
# point - see it immediately) and on disk (so a later poller reading a *fresh* Reservation->load()
# sees it too) - the same "set in-memory, then persist" shape containerId's own accessor +
# update() call already uses. $extra merges in any other top-level fields that need to change
# atomically with it (currently only 'expiryTime', on the failure paths below).
sub _create_status_set ($self, $value, $extra = {}) {
   $self->{'createStatus'} = $value;
   $self->update( { 'createStatus' => $value, %$extra } );
   return $self;
}

# reservation id => 1, while create()/reconcile_create()'s own promise chain is actively
# running in *this* process - queried by bin/app-server's periodic reconciler (skip a
# reservation this worker already owns, without even attempting a claim) and its exit handler
# (wait for these to drain before letting the worker actually exit). See
# docs/adr/0007-create-restart-recovery.md. Lives here, not as a bin/app-server-side hash as
# that decision's first draft called for - Reservation.pm is the only code that actually
# observes a chain's start/settle moments; a bin/app-server-side hash would need a second
# callback threaded all the way through User::createContainerReservation's own unrelated
# signature just to signal in/out, for no benefit over owning it where the lifecycle already
# lives. create_in_flight/create_in_flight_count below are its only public surface.
my %CREATE_IN_FLIGHT;

sub create_in_flight ($class, $id) { return exists $CREATE_IN_FLIGHT{$id}; }
sub create_in_flight_count ($class) { return scalar keys %CREATE_IN_FLIGHT; }

# Ground-truth stage builders, shared by create() (always starts at 'pulling') and
# reconcile_create() (resumes at whatever stage createStatus was stuck at) - see
# docs/adr/0007-create-restart-recovery.md's own "Ground truth per stage" table for the
# reasoning behind each one. Each returns a Mojo::Promise and is unconditionally safe to
# (re)enter - there is no "first time" vs "recovery" branch inside any of them, so there is
# exactly one code path per stage, not two.

sub _create_stage_pulling ($self, $image) {
   my $socket = $CONFIG->{'docker'}{'socket'};

   return Mojo::Promise->new( sub ($resolve, $reject) {
      call_socket_api( $socket, '/images/' . uri_escape($image) . '/json', {}, sub ($result, $err) {
         return $reject->($err) if $err;
         $resolve->( $result && $result->code == 200 );
      } );
   } )->then( sub ($present) {
      return 1 if $present;

      my ( $repo, $tag ) = $image =~ m{^(.+):([^/:]+)$} ? ( $1, $2 ) : ( $image, 'latest' );
      my $lastPersist = 0;

      return Mojo::Promise->new( sub ($resolve, $reject) {
         my $buf = '';
         my $failed;
         call_socket_api( $socket, '/images/create?fromImage=' . uri_escape($repo) . '&tag=' . uri_escape($tag), {
            'method'  => 'POST',
            'on_read' => sub ($bytes) {
               $buf .= $bytes;
               while ( ( my $nl = index( $buf, "\n" ) ) >= 0 ) {
                  my $line = substr( $buf, 0, $nl );
                  $buf = substr( $buf, $nl + 1 );
                  next unless length($line);
                  my $event = eval { decode_json($line) };
                  next unless $event;
                  # Two distinct error shapes share this same stream: a per-layer failure
                  # mid-pull uses 'error'/'errorDetail'
                  # (Docker's documented pull-progress event shape); a pull that fails outright
                  # before any layer progress starts (e.g. 404 'manifest unknown' for a bad tag)
                  # delivers a single line shaped {"message":...} instead - Docker's generic
                  # top-level API error shape, just delivered over this same on_read stream
                  # rather than as a distinctly-shaped non-200 body (the completion callback
                  # below never sees it separately: by the time it runs, this loop has already
                  # consumed the line, including its trailing newline, out of $buf).
                  if ( my $errMsg = $event->{'error'} // $event->{'message'} ) {
                     $failed = $errMsg;
                  }
                  next unless $event->{'id'};

                  my $cs = $self->{'createStatus'};
                  $cs->{'layers'}{ $event->{'id'} } = {
                     'status'  => $event->{'status'},
                     'current' => $event->{'progressDetail'}{'current'},
                     'total'   => $event->{'progressDetail'}{'total'},
                  };
                  $self->{'createStatus'} = $cs;

                  # Debounce the disk write - hundreds of progress events can arrive over a
                  # large pull. At most once/second is a reasonable default, not a
                  # precisely-tuned one - revisit if a real client ends up wanting smoother
                  # progress than that; the in-memory copy above is always current regardless.
                  my $now = time();
                  if ( $now > $lastPersist ) {
                     $lastPersist = $now;
                     $self->update( { 'createStatus' => $cs } );
                  }
               }
            },
         }, sub ($result, $err) {
            if ( $err || !$result || !$result->is_success ) {
               # A pull can fail two different ways: a clean top-level HTTP error before any
               # streaming starts (e.g. 404 'manifest unknown' for a bad tag - a single
               # {"message":...} JSON object body, no trailing newline for the while loop above
               # to have consumed it, so it's still sitting unparsed in $buf), or an error
               # embedded mid-stream after a 200 already started (a bad layer partway through an
               # otherwise-real pull - $failed, above). $result->body is *always* empty here
               # regardless of which - on_read replaces Mojo's own default body-accumulation
               # (see call_socket_api's own comment) - so $buf/$failed are the only place
               # the actual error text survives. An unknown-tag pull returns 404 with exactly
               # this un-newline-terminated {"message":...} shape - without this fallback it
               # would silently report an empty error string instead.
               my $bodyErr = length($buf) ? ( eval { decode_json($buf)->{'message'} } // $buf ) : undef;
               $reject->( $err // $failed // $bodyErr // ( $result ? 'HTTP ' . $result->code : 'no response' ) );
               return;
            }
            if ($failed) {
               $reject->($failed);
               return;
            }
            $resolve->(1);
         } );
      } );
   } );
}

sub _create_stage_creating ($self, $body) {
   my $socket = $CONFIG->{'docker'}{'socket'};

   # Ground-truth check, unconditional (not just for reconciliation) - does a container with
   # this reservation's own name already exist? Makes this stage safely re-enterable by
   # construction: a blind retry here would 409 on the name collision (create-restart-
   # recovery-plan.md's own "Ground truth per stage" table) - checking first costs one extra
   # GET on the ordinary, non-recovery path too, where it will (almost) always come back
   # absent, but that's a cheap, uniform cost for not needing a second, recovery-only code
   # path here at all.
   return Mojo::Promise->new( sub ($resolve, $reject) {
      call_socket_api( $socket, '/containers/' . uri_escape( $self->name ) . '/json', {}, sub ($result, $err) {
         return $reject->($err) if $err;
         $resolve->( $result && $result->code == 200 ? decode_json( $result->body )->{'Id'} : undef );
      } );
   } )->then( sub ($existingId) {
      return $existingId if $existingId;

      return Mojo::Promise->new( sub ($resolve, $reject) {
         call_socket_api( $socket, '/containers/create?name=' . uri_escape( $self->name ), {
            'method' => 'POST',
            'json'   => $body,
         }, sub ($result, $err) {
            if ( $err || !$result || !$result->is_success ) {
               $reject->( $err // ( $result ? $result->body : 'no response' ) );
               return;
            }
            $resolve->( decode_json( $result->body )->{'Id'} );
         } );
      } );
   } )->then( sub ($containerId) {
      # Store the 12-char short id, matching Reservation::containerId's own established
      # convention - docker-event-daemon's containers.json keys are the same 12-char short id
      # (_update_merge: 'substr($c->{'Id'}, 0, 12)'), and both $BY_CONTAINERID (this file's own
      # update_container_info) and load_clean_map match against those keys directly. The
      # Create API's response 'Id' (and the ground-truth GET above) is the full 64-char id -
      # storing it untruncated would silently never match either lookup: update_container_info
      # would leave this reservation's status stuck at -3 ('destroyed') forever,
      # onContainerStart would log "we don't manage" this containerId and never fire the
      # launch DAG, and load_clean_map would conclude the container is gone and delete the
      # reservation entirely after 30s - all while the container itself is alive and running.
      my $shortId = substr( $containerId, 0, 12 );
      $self->containerId($shortId);
      $self->update( { 'containerId' => $shortId } );
   } );
}

sub _create_stage_starting ($self, $containerId) {
   my $socket = $CONFIG->{'docker'}{'socket'};

   return Mojo::Promise->new( sub ($resolve, $reject) {
      call_socket_api( $socket, "/containers/$containerId/start", { 'method' => 'POST' }, sub ($result, $err) {
         if ( $err || !$result || !$result->is_success ) {
            $reject->( $err // ( $result ? $result->body : 'no response' ) );
            return;
         }
         $resolve->(1);
      } );
   } );
}

# The three-stage tail shared by create() and reconcile_create() below - each _create_run_from_*
# does its own stage's work then hands off to the next, so create() (which always starts at
# 'pulling') and a reconciliation resuming from any of the three stages both end up running
# exactly the same code for every stage they actually need, never a separate recovery-only copy.
sub _create_run_from_starting ($self) {
   $self->_create_status_set( { 'stage' => 'starting', 'failed' => 0, 'layers' => {} } );
   return _create_stage_starting( $self, $self->containerId() )->then( sub (@) {
      flog("Reservation::create: reservation '" . $self->id() . "' created and started successfully");
      $self->_create_status_set( { 'stage' => 'done', 'failed' => 0, 'layers' => {} } );
   } );
}

sub _create_run_from_creating ($self, $body) {
   $self->_create_status_set( { 'stage' => 'creating', 'failed' => 0, 'layers' => {} } );
   return _create_stage_creating( $self, $body )->then( sub (@) {
      return $self->_create_run_from_starting();
   } );
}

sub _create_run_from_pulling ($self, $body) {
   return _create_stage_pulling( $self, $self->data('image') )->then( sub (@) {
      return $self->_create_run_from_creating($body);
   } );
}

# Shared failure handling for create()/reconcile_create() - flogs, then records createStatus
# 'failed' with a real error message, preserving whatever per-layer pull progress had already
# been recorded rather than replacing the whole createStatus hash wholesale (lets the client
# show where the pull actually died instead of the per-layer detail vanishing the instant
# 'stage' flips to 'failed' - a failure before any layer progress exists, e.g. cmdline_json()
# throwing, simply has no layers to preserve, {} either way). Returns the extracted message,
# for a caller that also needs it for its own $cb.
sub _create_fail ($self, $err) {
   my $msg = ( ref($err) eq 'Exception' ) ? $err->msg : "$err";
   flog("Reservation::create: reservation '" . $self->id() . "' failed: $msg");
   my $layers = ( ref($self->{'createStatus'}) eq 'HASH' ? $self->{'createStatus'}{'layers'} : undef ) // {};
   $self->_create_status_set(
      { 'stage' => 'failed', 'failed' => 1, 'error' => $msg, 'layers' => $layers },
      { 'expiryTime' => YYYYMMDDHHMMSS(time) }
   );
   return $msg;
}

# Registers this reservation in %CREATE_IN_FLIGHT for $promise's own duration (a
# create()/reconcile_create() chain already running), clearing it once settled regardless of
# outcome. $onSettled (default: no one's listening - create()'s own contract has no external
# consumer for its tail) fires after cleanup, with the terminal ($self,undef)/(undef,$exception)
# result - reconcile_create() below is the one real consumer, since unlike create()'s
# fire-fast-then-continue $cb, its own $cb fires exactly once, on settle, with nothing else to
# ack early.
sub _create_track ($self, $promise, $onSettled = sub {}) {
   my $id = $self->id();
   $CREATE_IN_FLIGHT{$id} = 1;

   $promise->then( sub (@) {
      $onSettled->( $self, undef );
   } )->catch( sub ($err) {
      my $msg = $self->_create_fail($err);
      $onSettled->( undef, Exception->new( 'msg' => $msg ) );
   } )->finally( sub (@) {
      delete $CREATE_IN_FLIGHT{$id};
   } );

   return;
}

# Creates and starts this reservation's container - no fork, no PTY, no docker CLI subprocess:
# builds the Docker Create API body from cmdline_json() (Reservation/Launch.pm), pulls the
# image first if it isn't already present (with real per-layer progress, not a PTY log-tail),
# then POST /containers/create and POST /containers/{id}/start, all via call_socket_api.
# docker-event-daemon's own onContainerStart (/events-driven, unconditional on who issued the
# docker start) fires the launch DAG exactly as it does today - no signal to DED needed at all.
#
# $cb fires exactly once, synchronously, right after the idempotency guard below is written -
# not once the container is actually created/started. The rest of this sub's own work (image
# check/pull, create, start) continues independently afterwards, on this same process's event
# loop, visible only via polling createStatus (see status()'s own comment on its shape) - this
# preserves a fast-ack-then-poll client UX, which only holds if the initial API call keeps
# returning quickly rather than waiting for the whole chain. If the process (or, under
# Mojo::Server::Prefork, just the one worker) driving that background chain dies before it
# reaches a terminal stage, nothing above this sub notices on its own - see reconcile_create()
# below and docs/adr/0007-create-restart-recovery.md for what does.
#
# Idempotency guard: writes an initial createStatus synchronously, before any Docker call
# begins, then checks-then-sets with no yield point in between - race-free because a single
# Mojolicious worker processes one request at a time.
#
# Composed with Mojo::Promise, not nested callbacks - the one genuinely multi-step async chain
# in this file (image check -> optional pull -> create -> start). This is a deliberate, scoped
# exception to this file otherwise having no Mojolicious-framework dependency at all (no $c, no
# ->render, no routes) - chosen here specifically because this is the one multi-step chain in
# the whole file; the alternative (nested callbacks) would be a four-deep pyramid. Not precedent
# for reaching for Mojo::Promise/Mojo::IOLoop elsewhere in this file - every other _async sub
# here stays on the plain ($self, ..., $cb) single-callback convention.
sub create ($self, $cb) {
   my $id = $self->id();

   if ( $self->{'createStatus'} ) {
      $cb->( undef, Exception->new( 'msg' => "Reservation '$id' already has a createStatus set; refusing a duplicate create" ) );
      return;
   }

   my $body;
   try {
      $body = $self->cmdline_json();
   }
   catch {
      my $msg = $self->_create_fail($_);
      $cb->( undef, Exception->new( 'msg' => "Failed to compile 'docker create' request body, with error: $msg" ) );
   };
   return unless $body;   # cmdline_json() threw - already reported via $cb above

   $self->_create_status_set( { 'stage' => 'pulling', 'failed' => 0, 'layers' => {} } );
   $cb->( $self, undef );

   $self->_create_track( $self->_create_run_from_pulling($body) );
   return;
}

# Resumes a create() chain interrupted by the process (or, under Mojo::Server::Prefork, just
# the one worker) that was driving it dying mid-flight - reads createStatus.stage to decide
# where to resume, per docs/adr/0007-create-restart-recovery.md's own "Ground truth per
# stage" table. No claim/locking of its own - callers (bin/app-server's startup sweep and
# periodic reconciler) are responsible for ensuring only one caller ever reconciles a given
# reservation at a time; the periodic reconciler does this via a single process-wide sweep
# lock (not a per-reservation claim - see that doc's own "Revision 3" for why a per-reservation
# claim, tried first, was more machinery than the actual concern needed).
#
# $cb fires exactly once, when reconciliation fully settles (success or failure) - unlike
# create()'s own fire-fast-then-continue contract, nothing is waiting synchronously on this
# (it's driven by a sweep/timer, not an HTTP request), so there is no early ack to give.
sub reconcile_create ($self, $cb) {
   my $stage = ( $self->{'createStatus'} // {} )->{'stage'} // '';

   my $body;
   try {
      $body = $self->cmdline_json();
   }
   catch {
      my $msg = $self->_create_fail($_);
      $cb->( undef, Exception->new( 'msg' => $msg ) );
   };
   return unless $body;

   my $chain =
        $stage eq 'pulling'  ? $self->_create_run_from_pulling($body)
      : $stage eq 'creating' ? $self->_create_run_from_creating($body)
      : $stage eq 'starting' ? $self->_create_run_from_starting()
      : undef;

   unless ($chain) {
      my $msg = "reservation '" . $self->id() . "' has unreconcilable createStatus.stage '$stage'";
      flog("Reservation::reconcile_create: $msg");
      $cb->( undef, Exception->new( 'msg' => $msg ) );
      return;
   }

   $self->_create_track( $chain, $cb );
   return;
}

# $command is undef for exactly one caller shape: docker-event-daemon's genuine container-start
# dispatch (a live container-start event, or its deferred pendingLaunch retry once the launcher
# is ready) - the only case that represents "this devtainer just started". Every other caller
# (User::updateContainerReservation's 'update_ssh_authorized_keys', and 'restart_ide' if
# re-enabled) always passes an explicit command naming a one-off action on an already-running
# container. This distinction (not "is it 'restart_ide'?") is what gates the startCount
# increment below.
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
      # store_fields' own comment - since this reservation's own launch may concurrently be
      # writing other, unrelated fields.
      $reservation->data('runningIDE', $reservation->meta('IDE'));
      $reservation->store_fields( { 'data' => { 'runningIDE' => $reservation->data('runningIDE') } } );

      run_system($CONFIG->{'docker'}{'bin'}, 'exec', '-d', '-u', $reservation->unixuser(), $containerId, @Command);

      return 1;
   }

   # Server-side start count, injected as DOCKSIDE_START_COUNT so launch.sh can tell a
   # genuine first start (fires 'lifecycle:launch') from every later restart (fires
   # 'lifecycle:start' instead - see below). Named for what it actually counts - every
   # container-start event, including the first - not "launch" in the product-vocabulary sense
   # of a one-time devtainer creation. Computed here but only persisted after run_system()
   # below confirms the exec dispatch itself succeeded (it dies on failure) - deliberately
   # not before: incrementing first would burn a count on a dispatch
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
   # including during any retry window before the exec succeeds. Narrow store - see
   # store_fields' own comment.
   $reservation->data('runningIDE', $reservation->meta('IDE'));
   $reservation->store_fields( { 'data' => { 'runningIDE' => $reservation->data('runningIDE') } } );

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
# to avoid duplicating/drifting that logic between exec() and dispatch_hook_exec().
# Deliberately does NOT resolve a hook script path itself - exec() may need up to two script
# paths at once ('lifecycle:launch' and 'lifecycle:start', see above) and
# dispatch_hook_exec passes its one script path directly as a launch.sh CLI argument
# instead (see below), so each caller resolves whichever script(s) it needs itself.
#
# Returns `docker` CLI flag strings ("--env=KEY=VALUE"), not plain "KEY=VALUE" - matching
# exec()'s own @envHook/@envIDE/etc. below, since exec() still shells out to the `docker` CLI
# directly (run_system(...'exec','-d',...,@envCommonHook,...)). dispatch_hook_exec
# dispatches via the Docker Engine API's exec/create instead, whose `Env` field wants plain
# "KEY=VALUE" strings, not "--env=KEY=VALUE" - passing the CLI-flag form straight into that
# JSON field doesn't error, it just silently creates a nonsense env var literally named
# "--env" whose value is "KEY=VALUE", so DOCKSIDE_OPTION_* (and GIT_URL/GH_TOKEN) never reach
# the hook process at all. Fixed at dispatch_hook_exec's own call site (strips the
# prefix there) rather than changing this function's output format, since exec() still needs
# the CLI-flag form.
# Plain "KEY=VALUE" strings for every DOCKSIDE_OPTION_<NAME> this reservation's profile
# options resolve to - the one place that mapping is computed, so every consumer (currently
# _hook_env's docker-exec env below, and Reservation::Launch::cmdline_json's docker-create Env)
# reads the same values off the same $self->data('options') and can never drift apart on what a
# devtainer's options actually are. Safe to expose at container-create time as well as via
# docker exec: these are profile-author-declared option *values* (already visible in
# {option.<name>}-substituted argv via `docker inspect`, and already handed to every hook
# invocation), not a credential - unlike GIT_URL/GH_TOKEN below, deliberately left docker-exec-
# only (see docs/extensions/lifecycle-hooks.md's credential-source section for why: a live
# secret sitting in every process's environment from container boot is a materially different
# exposure than one only reaching a hook that explicitly asked for it).
sub _option_env_pairs ($self) {
   return map {
      'DOCKSIDE_OPTION_' . uc($_) . '=' . ($self->data('options') // {})->{$_}
   } keys %{ $self->data('options') // {} };
}

sub _hook_env ($self, $user) {
   my @envGit;
   if( $self->gitURL() ) {
      # SCP-style URLs may use any username (see the gitURL validation regex in
      # Reservation::data), not just literally 'git@' - match that here too, else
      # $git_domain is left undef for e.g. 'deploy@host:path'.
      my ($git_domain) = $self->gitURL() =~ m!^(?:https://|[a-zA-Z][\w-]*@)([^:/]+)!;
      @envGit = (
         "--env=GIT_URL=" . $self->gitURL(),
         "--env=SSH_KNOWN_HOSTS_DOMAINS=$git_domain"
      );
   }

   my @envOptions = map { "--env=$_" } $self->_option_env_pairs();

   my @envGhToken;
   if( my $token = $user->gh_token() ) {
      @envGhToken = ( "--env=GH_TOKEN=$token" );
   }

   return (@envGit, @envOptions, @envGhToken);
}

# --- Hook status/history storage ---
#
# data('hooks') = { status => {...}, history => [...] } - two structures nested under one
# top-level data key, deliberately different shapes for different jobs:
#
# hooks.status is the master record, a hash keyed by hook name - one entry per name, holding
# its current/last invocation's state. This is what a pre-exec "is this already running?"
# check (hook_is_running) and a "what happened last time?" query (hook_status) both read.
# Concurrent dispatches of *different* names on the same reservation must never clobber each
# other's entries - see Reservation::store_fields' own comment for exactly what
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

# Package (not lexical) so docker-event-daemon's own _launch_dispatch_hook_stage - which needs
# the identical cap for its own hook_claim_if_not_running call, dispatching the same two
# externally-reachable stage names (lifecycle:launch/lifecycle:start) - can reference it as
# $Reservation::HOOK_HISTORY_MAX without a second, independently-drifting constant.
our $HOOK_HISTORY_MAX = 100;

# Internal helpers isolating hooks.status's read/write boilerplate.
sub _hook_status_all ($self) {
   return ($self->data('hooks') // {})->{'status'} // {};
}

# Persists exactly one name's entry - never the whole status hash (see the block comment
# above for why that distinction matters) - while keeping this process's own in-memory copy
# consistent too, so a later read in the same process (e.g. hook_status_set_running_details
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

   # Newly-started, before docker_exec()'s own on_created callback has fired yet
   # (see hook_status_started/hook_status_set_running_details below) - the execId doesn't
   # exist yet, so there is nothing to check; it is, definitionally, still running.
   return 1 unless defined($status->{'execId'});

   # Stale-running detection, mirroring run_hook()'s own kill -0 reclaim for its in-container
   # lock: an app-server/docker-event-daemon process that died before this dispatch's own
   # completion callback ever ran (OOM, crash, restart) would otherwise wedge this name as
   # "running" forever. The exec API's own Running state is the only signal available - nothing
   # forks for this any more, so there is no local pid to check first.
   my $res = call_socket_api_sync($CONFIG->{'docker'}{'socket'}, "/exec/$status->{'execId'}/json", {});
   if( $res && $res->is_success ) {
      my $info = decode_json($res->body);
      return 1 if $info->{'Running'};

      # Not running, and we have a real answer from the daemon about how it ended - use it,
      # rather than defaulting to 'aborted' below regardless of what actually happened.
      if( defined $info->{'ExitCode'} ) {
         $self->hook_status_completed( $name, {
            'state'    => $info->{'ExitCode'} == 0 ? 'done' : 'failed',
            'exitCode' => $info->{'ExitCode'},
         } );
         return 0;
      }
   }

   # No conclusive answer from the daemon - self-heal the record (so a future check, and any
   # status-read caller, sees 'aborted' rather than a misleadingly eternal 'running') and
   # report not-running.
   $self->hook_status_completed($name, { 'state' => 'aborted' });
   return 0;
}

# Returns $name's master-record entry (undef if it has never been invoked on this
# reservation), for a status/log read endpoint to serve. Normalizes the numeric-ish fields
# (exitCode/timedOut/busy) back to real numbers before returning.
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
   for my $f (qw(exitCode timedOut busy)) {
      $clean->{$f} = 0 + $clean->{$f} if defined $clean->{$f};
   }
   return $clean;
}

# Called synchronously before dispatch begins (docker-event-daemon's own launch:-DAG stages
# only - dispatch_hook_exec's own claim/dispatch, below, uses hook_claim_if_not_running
# instead), to record that $name has started, so a poller sees 'running' immediately rather
# than a gap where the record doesn't exist yet. execId is deliberately undef at this point -
# it only exists once docker_exec's own on_created callback fires - see
# hook_status_set_running_details, called from that callback once it's known.
sub hook_status_started ($self, $name, $logPath) {
   $self->_hook_status_store_one( $name, {
      'name'      => $name,
      'state'     => 'running',
      'execId'    => undef,
      'logPath'   => $logPath,
      'startTime' => YYYYMMDDHHMMSS(time),
   } );
}

# Called from docker_exec's own on_created callback once the exec id is known - see
# hook_status_started above for why it can't be known any earlier.
sub hook_status_set_running_details ($self, $name, $execId) {
   my $existing = $self->_hook_status_all->{$name} or return;
   $self->_hook_status_store_one( $name, { %$existing, 'execId' => $execId } );
}

# Called once the hook has finished, timed out, or been confirmed aborted, recording the
# outcome on both the master record and the bounded history array. $fields must include
# 'state' explicitly ('done' or 'aborted') - never defaulted, so a caller can never
# accidentally leave a completed entry reading 'running' by omission.
sub hook_status_completed ($self, $name, $fields) {
   my $entry = { %{ $self->_hook_status_all->{$name} // { 'name' => $name } }, %$fields };
   $self->_hook_status_store_one( $name, $entry );

   record_hook_history($self->id(), { %$entry }, $HOOK_HISTORY_MAX);
}

# The one canonical async hook-dispatch core - claims, dispatches via the exec API, and
# records the outcome start to finish (hook_claim_if_not_running -> hook_status_set_running_
# details -> hook_status_completed). Both remaining dispatch paths - this on-demand entry
# point's own run_hook_manual below, and docker-event-daemon's launch DAG (via
# _launch_dispatch_hook_stage, which just wraps this) - go through it, so there is exactly one
# place that knows how to dispatch a hook and record its outcome.
#
# Two callbacks, not one, because callers need to act at two different points:
#   $on_claimed->($claimedEntry_or_undef) - fires synchronously, before any Docker I/O, once the
#      atomic claim (hook_claim_if_not_running) resolves. undef means another invocation already
#      owns $name (busy) - the caller must not treat this as an error, and dispatch stops here.
#      A caller that needs to return "started"/"busy" immediately without waiting for the hook to
#      actually finish (run_hook_manual - matching the fork model's own fire-and-forget shape
#      exactly, just without the fork) hooks in here only.
#   $on_settled->($outcome, $err) - fires once dispatch has fully finished: $outcome is one of
#      hook_status's own state values ('done'/'failed'/'aborted') once the exec resolves, or
#      $err is set (and $outcome undef) if dispatch couldn't even be attempted. A caller that
#      needs to know the final result (docker-event-daemon's launch DAG, to call
#      launch_resolve_stage) hooks in here.
#
# Deliberately does NOT repeat run_hook_manual's own on-demand-specific validation gates
# (declared? implemented? manual?) - a different caller may have entirely different gating;
# those stay in each caller. $args:
#   user    - exec user (default: $self->unixuser())
#   timeout - seconds; defaults to $CONFIG->{'hooks'}{'defaultTimeoutSeconds'}
sub dispatch_hook_exec ($self, $name, $script, $args, $on_claimed, $on_settled) {
   my $invocationId = sprintf( "%08x", int( rand(0xffffffff) ) );
   my $logPath = "$CONFIG->{'tmpPath'}/r-" . $self->id() . "-hook-$invocationId.log";

   my $claimedEntry = hook_claim_if_not_running( $self->id(), $name, $logPath, $HOOK_HISTORY_MAX );
   unless ($claimedEntry) {
      $on_claimed->(undef);
      return;
   }
   # Sync this process's own in-memory copy - see hook_claim_if_not_running's own comment for
   # why (mutate() only ever wrote a fresh, separately-loaded copy, not $self).
   ( $self->{'data'}{'hooks'} //= {} )->{'status'}{$name} = $claimedEntry;
   $on_claimed->($claimedEntry);

   my @Command = $self->ide_command();
   die Exception->new( 'msg' => 'Internal error - no IDE command configured', 'dbg' => 'Reservation::dispatch_hook_exec: ide_command() returned empty' ) unless @Command;
   $Command[-1] = 'run_hook';
   push( @Command, $name, $script );

   my $owner = $self->owner('username');
   my $user  = User->load($owner);
   die Exception->new( 'msg' => "The owner of this devtainer ('$owner') no longer exists", 'status' => 400 ) unless $user;

   my @env = map { my $e = $_; $e =~ s/^--env=//; $e } $self->_hook_env($user);

   my $timeout     = $args->{'timeout'} || $CONFIG->{'hooks'}{'defaultTimeoutSeconds'} || 120;
   my $containerId = $self->containerId();

   flog( "Reservation::dispatch_hook_exec: DISPATCHING (via exec API): " . join( '|', map { sanitize_sensitive_text($_) } @Command ) );

   open( my $log, '>>', $logPath )
      or die Exception->new( 'dbg' => "Reservation::dispatch_hook_exec: cannot open log '$logPath': $!" );
   $log->autoflush(1);

   docker_exec( $CONFIG->{'docker'}{'socket'}, $containerId, {
      'Cmd' => \@Command, 'User' => $args->{'user'} // $self->unixuser(), 'Env' => \@env,
   }, {
      'inactivity_timeout' => $timeout + 30,
      'request_timeout'    => $timeout,
      'on_created' => sub ($execId) { $self->hook_status_set_running_details( $name, $execId ); },
      'on_output'  => sub ($stream, $bytes) { print $log $bytes; },
   }, sub ( $result, $err ) {
      try {
         close($log);

         if ( !$result ) {
            flog("Reservation::dispatch_hook_exec: '$name' failed to dispatch: $err");
            $self->hook_status_completed( $name, { 'state' => 'aborted' } );
            $on_settled->( 'aborted', $err );
            return;
         }

         my $rc       = $result->{'exitCode'};
         my $timedOut = $result->{'timedOut'} ? 1 : 0;
         my $busy     = ( defined($rc) && $rc == 2 && !$timedOut ) ? 1 : 0;

         $self->hook_status_completed( $name, {
            'state'    => 'done',
            'exitCode' => $rc,
            'timedOut' => $timedOut,
            'busy'     => $busy,
         } );
         $on_settled->( _hook_outcome_state( $self->hook_status($name) ), undef );
      }
      catch {
         flog("Reservation::dispatch_hook_exec: caught exception resolving '$name': " . ( ref($_) ? $_->dbg : $_ ));
         $on_settled->( undef, $_ );
      };
   } );
}

# Maps a raw hook_status() record to done/failed/timedOut - the same vocabulary
# docker-event-daemon's own launch_resolve_stage expects (was
# _launch_state_from_hook_status, docker-event-daemon-local; now shared since
# dispatch_hook_exec's $on_settled needs the identical mapping for its own
# generic 'done'/'failed'/'aborted' outcome, not just the DAG's use of it).
sub _hook_outcome_state ($status) {
   return 'failed'   unless $status;
   return 'failed'   if $status->{'state'} eq 'aborted';
   return 'timedOut' if $status->{'timedOut'};
   return ( $status->{'exitCode'} // 1 ) == 0 ? 'done' : 'failed';
}

# The on-demand entry point for running a hook now (User::runContainerHook, ultimately
# `dockside hook run`): validates the request, then dispatches via dispatch_hook_exec.
# $cb fires immediately once the claim resolves - not once the hook itself finishes; the
# actual dispatch continues in the background, pollable via hook_status/
# User::runContainerHookStatus.
sub run_hook_manual ($self, $args, $cb) {
   my $name = $args->{'name'};
   die Exception->new( 'msg' => "'name' is required", 'status' => 400 ) unless length( $name // '' );

   # $self->profileObject is this reservation's own profile snapshot from creation time, not a
   # live read of the profile as it exists now - so if $script is empty, the message below
   # names both possible causes (a typo, or the hook was added to the profile after this
   # devtainer was created) without being able to tell which actually applies.
   my $script = $self->hook_script($name);
   die Exception->new(
      'msg' => "No hook '$name' is configured for this devtainer - check the hook name's " .
               "spelling, or recreate the devtainer if this hook has been added to the " .
               "profile since it was created",
      'status' => 400
   ) unless length($script);

   if ( $name =~ /^lifecycle:/ ) {
      die Exception->new( 'msg' => "'$name' is reserved for a future release, not runnable yet", 'status' => 400 )
         unless $name eq 'lifecycle:launch' || $name eq 'lifecycle:start';

      die Exception->new( 'msg' => "'$name' is not configured as manually invocable for this profile (see its 'hooks' entry's 'manual' field)", 'status' => 400 )
         unless $self->profileObject->hooks->{$name}{'manual'};
   }

   my $timeout = $args->{'timeout'} || $CONFIG->{'hooks'}{'defaultTimeoutSeconds'} || 120;
   die Exception->new( 'msg' => "'timeout' must be a positive integer number of seconds", 'status' => 400 )
      unless $timeout =~ /^[1-9][0-9]*$/;

   $self->dispatch_hook_exec(
      $name, $script, { 'timeout' => $timeout },
      sub ($claimedEntry) {
         return $cb->( { 'busy' => 1 }, undef ) unless $claimedEntry;
         return $cb->( { 'started' => 1, 'name' => $name }, undef );
      },
      sub ( $outcome, $err ) {
         # Nothing further to do here - dispatch_hook_exec has already persisted the
         # outcome via hook_status_completed; a client discovers it by polling
         # User::runContainerHookStatus (the GET /containers/:id/hook/status route), a plain
         # synchronous read.
      }
   );
}

1;
