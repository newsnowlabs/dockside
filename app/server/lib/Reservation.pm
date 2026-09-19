package Reservation;

use v5.36;

use JSON;
use Expect;
use Try::Tiny;
use Tie::File;
use Storable qw(dclone);
use URI::Escape;
use Mojo::IOLoop;
use Mojo::Promise;
use Mojo::Util qw(steady_time);
use Reservation::Mutate qw(update load_clean_map record_hook_history resolve_hook_status hook_claim_if_not_running);
# Not imported: Reservation::Mutate's own add_router/remove_router/replace_router - Reservation.pm
# defines its OWN methods of the same name below (the public API other code calls), which call
# Reservation::Mutate's versions fully-qualified. Importing both under the same bare names into
# this package would collide (whichever `sub` in this file compiles last silently wins), so the
# Mutate-side functions are deliberately left unimported and always called fully-qualified.
use Reservation::Load;
use Reservation::Launch;
use Containers;
use Profile;
use Util qw(flog wlog trim is_true clean_pty run TO_JSON YYYYMMDDHHMMSS cacheReadWrite call_socket_api_sync call_socket_api docker_exec unique run_system get_uri sanitize_sensitive_text format_caught_error tryLockFile);
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
         # Allow any value known_router_auth_levels() recognises (owner/viewer/developer/user/
         # public) - one shared list rather than a second hardcoded copy that could drift from
         # it. 'containerCookie' is deliberately excluded from that list: User::reservationPermissions
         # never grants it and Proxy.pm's own handling of it is commented out, so accepting it
         # here would be silently unusable everywhere else.
         # (unless type eq ide, in which case allow only owner|developer).
         #
         # If no value specified, set to the default ('developers' if none specified in the profile).
         my $access = $value->{$name};
         die Exception->new( 'msg' => "Cannot set auth/access mode for router '$name' to '$access'" )
            unless grep { $_ eq $access } @{ known_router_auth_levels() };

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

      # Docker's single-container endpoints match an exact ID before an exact name, but an exact
      # name before an ID *prefix* - so a container named as a bare 12/64-char hex string can
      # capture containerId-addressed calls meant for another container whose ID happens to
      # equal this name.
      if( $self->{'name'} =~ /^[0-9a-f]{12}$/ || $self->{'name'} =~ /^[0-9a-f]{64}$/ ) {
         die Exception->new( 'msg' => "Failed to create Reservation with invalid name '$self->{'name'}': "
            . "must not be a bare 12- or 64-character hexadecimal string" );
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
# ROUTER MUTATION (add / remove / replace)
#
# docs/adr/0008-router-mutation.md - lets a permission-holding developer add/remove routers on
# a live reservation, subject to a profile-level opt-in for add (Profile->userRouters) and the
# standard addContainerRouter/removeContainerRouter permission + can_on(develop) gate, both
# checked by User.pm before any of the methods below are ever called. Nothing here re-checks
# permissions - these are the mutation primitives only.

# The full vocabulary of router access levels this codebase recognises (User::reservationPermissions'
# own $permittedAuth keys, minus the explicitly-incomplete 'containerCookie' - see that sub's own
# comment). normalise_router_def below validates a router's 'auth' list against this; User.pm's
# addContainerRouter/replaceContainerRouter reuse it (via known_router_auth_levels() below) as the
# default 'auth' list when the caller didn't supply one - deciding *that* default is User.pm's job,
# not this file's or Reservation::Mutate's (see docs/adr/0008-router-mutation.md).
my @KNOWN_ROUTER_AUTH_LEVELS = qw( user developer public viewer owner );

# Returns a fresh copy of the known-levels list above - the same wide allow-list Profile.pm's own
# applyDefaultsAndFilters gives every non-ide/ssh router. Called fully-qualified
# (Reservation::known_router_auth_levels()) from User.pm, which is the only place that decides
# *when* to fall back to it.
sub known_router_auth_levels () {
   return [ @KNOWN_ROUTER_AUTH_LEVELS ];
}

# Validates and normalises a client-submitted router definition (docs/adr/0008-router-mutation.md).
# Deliberately not a Profile method/reuse of Profile::validate_profile_routers - a self-service
# add has a narrower, server-controlled field set ('type' is forced below, never caller-supplied;
# 'auth' is caller-*optional*, defaulting to the wide list rather than being forced) and needs two
# checks the profile loader itself never bothered with:
# reject on any (protocol, prefix, domain) collision against $existingRouters, rather than
# silently shadowing it the way Reservation::routers()'s own last-write-wins lookup table would;
# and reject a hyphenated prefix outright, since lookup_container_uri (this file, the
# `$prefix =~ /-/` branch) unconditionally treats any hyphen in the *actual request* prefix as a
# passthrough indicator and diverts to the '**' router, never consulting the literal prefix table
# at all - a router registered under a hyphenated prefix would be added successfully but could
# never actually be reached by it.
#
# Called only from inside Reservation::Mutate's own locked callback, against the freshly-reread
# on-disk router list - there is no separate, unlocked "fast early error" pre-check in User.pm
# (nothing needs one enough to justify a second call; the lock is cheap and uncontended in the
# common case).
#
# Dies with an Exception (status 400) on any problem. Returns a new, normalised router hashref -
# never mutates $routerDef or $existingRouters.
sub normalise_router_def ($routerDef, $existingRouters) {
   $routerDef = {} unless ref($routerDef) eq 'HASH';
   $existingRouters //= [];

   my $prefixes = $routerDef->{'prefixes'};
   $prefixes = [$prefixes] if defined($prefixes) && !ref($prefixes);
   die Exception->new( 'msg' => "router 'prefixes' must be a non-empty Array of strings", 'status' => 400 )
      unless ref($prefixes) eq 'ARRAY' && @$prefixes;
   for my $prefix (@$prefixes) {
      die Exception->new(
         'msg'    => "router prefix '$prefix' must not contain a hyphen - the proxy treats any " .
                     "hyphenated request prefix as a passthrough indicator, so a router registered " .
                     "under one could never actually be reached by it",
         'status' => 400
      ) if $prefix =~ /-/;
   }

   my $domains = $routerDef->{'domains'};
   $domains = [$domains] if defined($domains) && !ref($domains);
   $domains = ['*'] unless ref($domains) eq 'ARRAY' && @$domains;

   my $name = $routerDef->{'name'} // $prefixes->[0];
   die Exception->new( 'msg' => "router 'name' must be lower case, consist only of letters, digits and hyphens (but not successive hyphens) and begin with a letter", 'status' => 400 )
      unless $name =~ /^[a-z](?:-[a-z0-9]+|[a-z0-9]+)+$/;
   die Exception->new( 'msg' => "a router named '$name' already exists on this reservation", 'status' => 400 )
      if grep { $_->{'name'} eq $name } @$existingRouters;

   my %public;
   for my $publicProtocol (qw( http https )) {
      my $proto = $routerDef->{$publicProtocol};
      next unless $proto;
      die Exception->new( 'msg' => "router '$publicProtocol' must be an Object with 'protocol' and 'port'", 'status' => 400 )
         unless ref($proto) eq 'HASH' && $proto->{'protocol'} && defined($proto->{'port'});
      # 'protocol' ends up as the scheme of the proxy_pass target nginx is handed for every
      # request to this router (Reservation::lookup_container_uri renders it straight into
      # "<protocol>://<ip>:<port>", which Proxy::_get_server_port returns to the nginx config's
      # own `proxy_pass $upstream_https`). nginx honours a proxy target supplied via a variable
      # verbatim, without normalising it, so this must stay restricted to the two schemes nginx
      # can actually proxy to: a value carrying its own host, path or query would otherwise be
      # honoured as one, redirecting this router's traffic anywhere the Dockside container can
      # reach.
      die Exception->new( 'msg' => "router '$publicProtocol.protocol' must be 'http' or 'https'", 'status' => 400 )
         unless $proto->{'protocol'} =~ /^https?$/;
      die Exception->new( 'msg' => "router '$publicProtocol.port' must be an integer between 1 and 65535", 'status' => 400 )
         unless $proto->{'port'} =~ /^\d+$/ && $proto->{'port'} >= 1 && $proto->{'port'} <= 65535;
      $public{$publicProtocol} = { 'protocol' => $proto->{'protocol'}, 'port' => 0 + $proto->{'port'} };
   }
   die Exception->new( 'msg' => "router must declare at least one of 'http'/'https'", 'status' => 400 )
      unless %public;

   # 'auth' is required by this point - User.pm always supplies one (the caller's own --auth, or
   # its own default of every known level via known_router_auth_levels() above if the caller gave
   # none) before ever calling down to add_router/replace_router. This function only validates
   # shape/membership; it makes no decision about what belongs here when nothing was supplied.
   my $auth = $routerDef->{'auth'};
   $auth = [$auth] if defined($auth) && !ref($auth);
   die Exception->new(
      'msg'    => "router 'auth' must be a non-empty Array containing only: " . join(', ', @KNOWN_ROUTER_AUTH_LEVELS),
      'status' => 400
   ) unless ref($auth) eq 'ARRAY' && @$auth && !grep { my $a = $_; !grep { $_ eq $a } @KNOWN_ROUTER_AUTH_LEVELS } @$auth;

   # Collision check: reject if any (publicProtocol, prefix, domain) tuple this router would
   # claim is already claimed by an existing router. '*' on either side is treated as an overlap
   # with anything - conservative (some non-wildcard pairs it flags aren't a *real* nginx-level
   # collision) rather than precise, matching this feature's "reject on any overlap" intent.
   # $existingPrefixes/$existingDomains depend only on $existing, so they're computed once per
   # existing router, not once per (protocol, prefix, domain) combination being tested against it.
   for my $publicProtocol (keys %public) {
      for my $existing (@$existingRouters) {
         my $existingProto = $existing->{$publicProtocol} or next;
         my $existingPrefixes = ($existing->{'prefixes'} && @{$existing->{'prefixes'}}) ? $existing->{'prefixes'} : ['*'];
         my $existingDomains  = ($existing->{'domains'}  && @{$existing->{'domains'}})  ? $existing->{'domains'}  : ['*'];
         for my $prefix (@$prefixes) {
            for my $domain (@$domains) {
               if( (grep { $_ eq $prefix || $_ eq '*' || $prefix eq '*' } @$existingPrefixes) &&
                   (grep { $_ eq $domain || $_ eq '*' || $domain eq '*' } @$existingDomains) ) {
                  die Exception->new(
                     'msg' => "router prefix '$prefix' (domain '$domain', $publicProtocol) already claimed by router '$existing->{'name'}'",
                     'status' => 400
                  );
               }
            }
         }
      }
   }

   return {
      'name'     => $name,
      'type'     => 'user',   # server-assigned, always
      # Whatever User.pm resolved and handed down (caller-narrowed via --auth, or its own
      # wide-by-default known_router_auth_levels() fallback) - the *conservative* part of this
      # feature is the initial meta.access value User.pm also resolves alongside this (see
      # add_router/replace_router below), not the eligible range: an owner/developer must still be
      # able to widen access later via the existing, already permission-gated
      # `dockside edit --access` flow, which checks the requested level against exactly this list
      # (User::set's own 'access' branch).
      'auth'     => $auth,
      'prefixes' => $prefixes,
      'domains'  => $domains,
      %public,
   };
}

# Adds a router to this live reservation. $accessLevel is the initial meta.access value to
# assign - resolved by User.pm (its own owner/developer default, or an explicit caller override),
# never decided here or in Reservation::Mutate: this method and Mutate only validate it's actually
# legal under the router's final (default-wide, or caller-narrowed) auth list, they don't choose
# it. Persists via Reservation::Mutate::add_router (locked, re-validated against the fresh
# on-disk router list - see normalise_router_def's own comment) then updates this process's
# in-memory copy so an immediate createClientReservation() reflects the change without a second
# reload.
sub add_router ($self, $routerDef, $accessLevel) {
   my ($normalised, $resolvedAccessLevel) = Reservation::Mutate::add_router( $self->id(), $routerDef, $accessLevel );
   push( @{ $self->{'profileObject'}{'routers'} }, $normalised );
   $self->{'meta'}{'access'}{ $normalised->{'name'} } = $resolvedAccessLevel;
   $self->{'routersLookup'} = $self->routers();
   return $normalised;
}

# Removes router $name from this live reservation. Dies (via Reservation::Mutate::remove_router)
# if $name doesn't exist or is a hard-blocked ide/ssh router - no other per-router check is left;
# permission/profile-gate checks already happened in User.pm before this is called.
sub remove_router ($self, $name) {
   Reservation::Mutate::remove_router( $self->id(), $name );
   $self->{'profileObject'}{'routers'} = [ grep { $_->{'name'} ne $name } @{ $self->{'profileObject'}{'routers'} } ];
   delete $self->{'meta'}{'access'}{$name};
   $self->{'routersLookup'} = $self->routers();
   return $self;
}

# Atomically replaces router $name with $routerDef (a convenience wrapper - remove+add under one
# lock, carrying meta.access[$name] forward when the name is unchanged). $explicitAccessLevel,
# if defined, is the caller's own explicit request and always wins; otherwise the carried-forward
# value is used when still legal under the router's final auth list, else $defaultAccessLevel
# (User.pm resolves both exactly as add_router's own $accessLevel is resolved). Gated by both
# addContainerRouter and removeContainerRouter in User.pm, same hard ide/ssh block as
# remove_router.
sub replace_router ($self, $name, $routerDef, $explicitAccessLevel, $defaultAccessLevel) {
   # The actually-assigned level is decided inside the lock (explicit, else carried forward from
   # the fresh on-disk meta.access[$name] when the name is unchanged and still legal, else
   # $defaultAccessLevel) - see Reservation::Mutate::replace_router's own comment.
   my ($normalised, $resolvedAccessLevel) = Reservation::Mutate::replace_router( $self->id(), $name, $routerDef, $explicitAccessLevel, $defaultAccessLevel );
   $self->{'profileObject'}{'routers'} = [
      grep { $_->{'name'} ne $name } @{ $self->{'profileObject'}{'routers'} }
   ];
   push( @{ $self->{'profileObject'}{'routers'} }, $normalised );
   delete $self->{'meta'}{'access'}{$name} unless $normalised->{'name'} eq $name;
   $self->{'meta'}{'access'}{ $normalised->{'name'} } = $resolvedAccessLevel;
   $self->{'routersLookup'} = $self->routers();
   return $normalised;
}

################################################################################
# RESERVATION QUERY METHODS
#

# Query 'viewers' or 'developers' $key for presence of username $user
sub meta_has_user ($self, $key, $user) {
   # Empty $user would still match the regex, so check for this case.
   return 0 unless defined($user);

   # An unset list - 'viewers'/'developers' never assigned on this reservation - names nobody,
   # and is matched against as the empty string rather than as undef.
   return ( $self->meta($key) // '' ) =~ /(?:^|,)\Q$user\E(?:,|$)/;
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

# getLogs stays synchronous - a fast local read, never worth an async version. Stop/start/remove
# (see action() below) are the genuinely slow ones; getLogs isn't, so it isn't routed through
# action() at all.
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

   # A reservation whose container does not exist - a create that failed, or one still in
   # flight - has no id to act on, and interpolating it into the paths below would ask Docker
   # about '/containers//stop'. Reported through $cb, the channel every other outcome of this
   # call already uses - as an Exception, the same shape a Docker-side refusal below hands back,
   # so the caller has one kind of thing to render (see the route in bin/app-server).
   unless ( length( $containerId // '' ) ) {
      $cb->( undef, Exception->new(
         'msg'    => "This devtainer has no running container to '$action'",
         'status' => 409,
      ) );
      return;
   }

   # $ok decides, per action, which Docker response codes count as the action having taken
   # effect - not just a 2xx, because Docker signals several already-in-the-desired-state
   # outcomes with a 304 or 404 that are successes for our purpose. $refusal names the codes
   # worth reporting in words rather than as a bare number.
   my ( $method, $path, $ok, $refusal );

   if ( $action eq 'stop' ) {
      my $t = $args->{'t'} // 10;   # Docker CLI's own default stop grace period
      ( $method, $path ) = ( 'POST', "/containers/$containerId/stop?t=$t" );
      # 204 stopped, 304 already stopped, 404 already gone - all mean "not running", the goal.
      $ok = sub ($code) { $code == 204 || $code == 304 || $code == 404 };
   }
   elsif ( $action eq 'start' ) {
      ( $method, $path ) = ( 'POST', "/containers/$containerId/start" );
      # 204 started, 304 already running. A 404 here is a real failure - nothing to start.
      $ok = sub ($code) { $code == 204 || $code == 304 };
   }
   elsif ( $action eq 'remove' ) {
      ( $method, $path ) = ( 'DELETE', "/containers/$containerId?v=true" );
      # 204 removed, 404 already gone (a remove that finds nothing has reached its goal). 409 is
      # Docker refusing to remove a still-running container - the one refusal worth naming.
      $ok      = sub ($code) { $code == 204 || $code == 404 };
      $refusal = { 409 => 'This devtainer is running; stop it before it can be removed' };
   }
   else {
      die Exception->new( 'msg' => "Unknown docker container action '$action'" );
   }

   call_socket_api(
      $CONFIG->{'docker'}{'socket'}, $path, { 'method' => $method },
      sub ( $result, $err ) {
         my $code = $result ? $result->code : undef;
         flog( "Reservation::action: '$action' on '$containerId' "
            . ( $err ? "failed: $err" : 'returned ' . ( $code // '(no result)' ) ) );

         # A transport-level failure ($err set, no HTTP response) is an upstream problem: this
         # server could not reach or drive Docker. dbg carries the raw reason for the log;
         # msg stays client-safe.
         if ( $err ) {
            $cb->( $result, Exception->new(
               'msg'    => "Could not reach Docker to '$action' this devtainer",
               'dbg'    => "Reservation::action: '$action' on '$containerId': $err",
               'status' => 502,
            ) );
            return;
         }

         # A response arrived, but with a code this action does not count as success - a genuine
         # refusal (named, where known) rather than the silent 200 this used to report.
         if ( defined($code) && !$ok->($code) ) {
            $cb->( $result, Exception->new(
               'msg'    => $refusal->{$code} // "Docker refused to '$action' this devtainer (HTTP $code)",
               'status' => $refusal->{$code} ? 409 : 502,
            ) );
            return;
         }

         $cb->( $result, undef );
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
# persisted value to compute (see Reservation::Mutate::update_running_hook for that case,
# e.g. the detached-launch startCount increment it commits under the same lock as its
# ownership check).
sub store_fields ($self, $fields) {
   $self->update( { 'id' => $self->id(), %$fields } );
   return $self;
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
            # Only a JSON Object is a usable devcontainer.json - $cb's caller (User.pm) reads
            # $dc as a hashref unconditionally. A syntactically valid but non-Object body (an
            # Array, string or number) falls through to the next branch exactly like a parse
            # failure, rather than handing the caller something it can't safely dereference.
            if ( ref($decoded) eq 'HASH' ) {
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

# Persists createStatus, then updates the in-memory copy so this same process's own later reads
# (including cloneWithConstraints/sanitise, and hence anything that returns $self to a client
# after this point) see it too. $extra merges in any other top-level fields that need to change
# atomically with it (currently only 'expiryTime', on the failure paths below).
#
# Persisting first, and only then mutating $self, is load-bearing: update() writes $value
# unconditionally from its argument, never from $self's own copy, so a failed write leaves $self
# holding the same createStatus it held before the call. A caller that goes on to record a
# different outcome (e.g. _create_status_enter's own failure path, which reports the entry
# unresolved) reads $self->{'createStatus'} to preserve what that outcome inherits - layers,
# stage, attempts - and must see the last state that actually reached disk, not one this call
# failed to persist. Mutating $self first would let that outcome carry forward a stage nothing
# ever recorded, and a later definitive failure would then persist final diagnostics against it
# while leaving the record parked at that unrecorded, non-terminal stage - one reconciliation
# never revisits, because it isn't 'failed' and isn't the stage anything is actually resuming.
sub _create_status_set ($self, $value, $extra = {}) {
   $self->update( { 'createStatus' => $value, %$extra } );
   $self->{'createStatus'} = $value;
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

# invocationId => 1, from just before dispatch_hook_exec hands its docker_exec call over - or
# from the point a failure before that owes an outcome write instead - until that invocation's
# outcome is durably recorded in *this* process. Same shape and purpose as
# %CREATE_IN_FLIGHT above, for the other non-detached exec connection a restart can sever
# mid-flight. The obligation deliberately outlives the exec's own completion callback: what a
# draining worker must wait for is the outcome reaching disk, not the connection closing, so it
# is released by _hook_settle_outcome only once the write has been applied or fenced, and is
# held across retries for as long as it is neither - see that function's own comment for why an
# unwritten outcome must keep a drain incomplete. Process-local like %CREATE_IN_FLIGHT:
# docker-event-daemon and bin/app-server each see only their own copy despite calling the same
# function defined once here.
my %HOOK_DISPATCH_IN_FLIGHT;

sub hook_dispatch_in_flight_count ($class) { return scalar keys %HOOK_DISPATCH_IN_FLIGHT; }

# A create chain that ends without learning whether its Docker mutation took effect records an
# 'unresolved' diagnostic and keeps its stage, so a later reconciliation pass retries it. These
# bound that retrying.
#
# The cooldown is deliberately its own constant rather than appServer.reconcileIntervalSeconds:
# the reconcile interval sets how often a worker sweeps, while this sets how soon a record that
# has just failed to learn its outcome is worth asking about again. Tying recovery latency to the
# sweep cadence would make a record abandoned by a dying worker wait a full sweep interval before
# anyone retries it, even though its lock is already free.
our $CREATE_UNRESOLVED_RETRY_COOLDOWN_SECONDS = 60;
our $CREATE_UNRESOLVED_WARN_AFTER_ATTEMPTS = 5;

# Docker reserves a container's name early in create and releases it again if that create then
# fails, so a 409 followed by an empty name lookup is a transient state, not a verdict. These
# poll it out: one lookup immediately, then two more, all inside a single overall budget that
# also caps each lookup's own request timeout - a stalled GET must not outlive the budget, since
# the reservation's ownership lock is held for the whole inspection.
our $CREATE_CONFLICT_POLL_DELAYS = [ 0, 0.5, 1.5 ];
our $CREATE_CONFLICT_POLL_BUDGET_SECONDS = 5;

# Path of the per-reservation ownership lock create()/reconcile_one() hold, non-blockingly, for
# a create() chain's whole lifetime - docs/adr/0007-create-restart-recovery.md's "Decision"
# section. Lives under tmpPath, alongside hook logs (the established per-reservation-file
# location) - not persisted content, just a kernel lock target: a wiped or freshly-created file
# is acquired correctly either way, since ownership lives in the flock, not the file's bytes.
sub _create_lock_path ($id) {
   return "$CONFIG->{'tmpPath'}/r-$id.lock";
}

# Forces this worker's own reservation cache to catch up with whatever another process (a
# sibling worker, docker-event-daemon) has written to reservations.json since this worker's own
# copy was last loaded, then returns the current Reservation object for $id, or undef if it no
# longer exists. Uses Data's normal locked read and parsing, but bypasses its timestamp
# cache: two writes can have identical mtimes even with fractional-second stat. A cached
# non-terminal stage must never authorize a new driver after the prior one has settled.
sub _reservation_reloaded ($id) {
   Data::load_fresh('reservations.json');
   return $Reservation::BY_ID->{$id};
}

# Docker's own error text for a response this chain could not use. Every endpoint called here
# reports failure as {"message":"..."}; the fallbacks cover a response that does not.
sub _create_response_error ($result) {
   my $body = eval { $result->body } // '';
   my $message = eval { decode_json($body)->{'message'} };
   return $message if defined($message) && !ref($message) && length($message);
   return $body if length($body);
   my $code = eval { $result->code };
   return defined($code) ? "HTTP $code" : 'no response body';
}

# Classifies one Docker response to a mutation this chain issued, on the axis that decides what
# the reservation does next:
#   success    - it took effect
#   failed     - Docker understood the request and refused it, so nothing took effect
#   conflict   - the name is already taken; by what is a separate question (_create_confirm_ownership)
#   unresolved - it may or may not have taken effect
#
# Anything not positively identified is unresolved, because the two directions are not symmetric:
# treating an unknown outcome as unresolved costs one later lookup, while treating it as failed
# records a definitive failure - and with it an expiry that deletes the reservation - for a
# container that may be running.
#
# $op distinguishes the two mutations, which succeed differently. A create must carry a usable id
# in a JSON body. A start reports success with a bodyless 204, and reports a container some
# earlier or overlapping run already started with 304 - rejecting that would record a failure on a
# container that is healthy and running, and it is reachable whenever this stage is re-entered. A
# 409 is a name collision for create; for start it carries no such meaning, so it is left
# unresolved rather than entering the create path's name adoption.
sub _create_classify ($op, $result, $err) {
   return ( 'unresolved', "$err" ) if defined $err;
   return ( 'unresolved', 'no response and no error' ) unless $result;

   my $code = eval { $result->code };
   return ( 'unresolved', 'response carries no status code' )
      unless defined($code) && !ref($code) && $code =~ /^[1-9][0-9]{2}$/;

   return ( 'success', undef ) if $code >= 200 && $code < 300;
   return ( 'success', undef ) if $op eq 'start' && $code == 304;
   return ( 'conflict', _create_response_error($result) ) if $op eq 'create' && $code == 409;
   return ( 'failed', _create_response_error($result) )
      if $code == 400 || $code == 404 || $code == 422;

   return ( 'unresolved', _create_response_error($result) );
}

# The rejection that keeps a reservation recoverable: _create_track records it without a terminal
# stage or an expiry, so a later reconciliation pass resumes the chain. Every other rejection on
# this chain is a plain string and is treated as definitive.
sub _create_unresolved_error ($msg) {
   return Exception->new( 'unresolved' => 1, 'msg' => $msg );
}

# A promise already rejected with $err, for the paths that fail before there is anything to await.
sub _create_rejected ($err) {
   my $promise = Mojo::Promise->new;
   $promise->reject($err);
   return $promise;
}

# Ground-truth-by-name lookup. Anchored to the exact name via the collection endpoint's own
# filters, not Docker's single-container GET /containers/{name}/json, which also resolves an id
# prefix - a reservation named after a hex prefix of some other container's id would otherwise
# match that container instead (docs/adr/0007-create-restart-recovery.md's "Decision" section).
# The name is escaped because that filter is matched as a regular expression by Docker.
#
# Reports one of three states through $cb, and the distinction between the last two is what stops
# this authorizing a create that should not happen:
#   present - exactly one container holds the name; its record is in 'entry'
#   absent  - a valid, successful list response held no entries, so nothing holds the name
#   unknown - the lookup produced no usable evidence either way
#
# Only a validated successful list response can establish absence. A failed request, a non-200, a
# body that will not decode, a decoded value that is not a list, an entry that is not a container
# record, or more than one match all report 'unknown': acting on any of those as though the name
# were free issues a create against a name that may already hold this reservation's own container.
#
# $timeout, when set, caps the whole request - callers that poll this run under an overall budget
# and must not let a stalled GET outlive it. Reporting every failure through $cb is what keeps the
# enclosing promise settling: an exception raised here escapes into the reactor instead of the
# promise (unlike one raised in a ->then callback), leaving the chain unsettled and its ownership
# lock held for the lifetime of the process.
sub _create_lookup_by_name ($self, $timeout, $cb) {
   my $name = $self->name;

   call_socket_api( $CONFIG->{'docker'}{'socket'},
      '/containers/json?all=1&filters='
         . uri_escape( encode_json( { 'name' => [ '^/' . quotemeta($name) . '$' ] } ) ),
      ( defined($timeout) ? { 'request_timeout' => $timeout } : {} ),
      sub ( $result, $err ) {
         return $cb->( { 'state' => 'unknown', 'reason' => "$err" } ) if defined $err;

         my $code = eval { $result && $result->code };
         unless ( defined($code) && !ref($code) && $code == 200 ) {
            $cb->( { 'state' => 'unknown', 'reason' => $result
               ? 'name lookup returned ' . _create_response_error($result)
               : 'name lookup returned no response' } );
            return;
         }

         my $matches = eval { decode_json( $result->body ) };
         unless ( ref($matches) eq 'ARRAY' ) {
            $cb->( { 'state' => 'unknown', 'reason' => "malformed container list for name '$name': "
               . ( format_caught_error($@) || 'response is not a JSON array' ) } );
            return;
         }

         return $cb->( { 'state' => 'absent' } ) unless @$matches;
         if ( @$matches > 1 ) {
            $cb->( { 'state' => 'unknown',
               'reason' => scalar(@$matches) . " containers report the exact name '$name'" } );
            return;
         }
         unless ( ref( $matches->[0] ) eq 'HASH' ) {
            $cb->( { 'state' => 'unknown',
               'reason' => "container list entry for name '$name' is not a record" } );
            return;
         }
         $cb->( { 'state' => 'present', 'entry' => $matches->[0] } );
      } );
   return;
}

# Decides what a container found holding this reservation's name means for it. Only
# dev.dockside.reservation.id is load-bearing - see cmdline_json's own comment on why the other
# identity labels are cosmetic. Returns:
#   ours      - this reservation's own id label and a usable container id, which is the detail
#   unrelated - a valid record whose ownership label is absent or names another reservation
#   unknown   - the record cannot be read as evidence either way
#
# Docker represents "no labels" as an absent key or a null, both valid records that confirm the
# container is not this reservation's. A record whose shape is wrong instead - a 'Labels' that is
# neither a set nor null, a label value or id that is not a plain string, an id not in Docker's
# own hex form - confirms nothing and is reported unknown: treating unreadable data as proof of
# another owner would record a definitive failure, and with it an expiry, against a container that
# may be this reservation's own.
sub _create_entry_ownership ($self, $entry) {
   return ( 'unknown', 'container list entry is not a record' ) unless ref($entry) eq 'HASH';

   # Checked before ownership, and regardless of which way ownership will go: a record with no
   # usable id is not confirmed evidence of anything, and reading its absent/mismatched label as
   # proof of foreign ownership would record a definitive failure - and an expiry - against a
   # container that may be this reservation's own, on the strength of a malformed entry.
   my $id = $entry->{'Id'};
   return ( 'unknown', 'container list entry has no usable id' )
      unless defined($id) && !ref($id) && $id =~ /^[0-9a-f]{12,64}$/;

   my $labels = $entry->{'Labels'};
   return ( 'unknown', "container's labels are not a set" )
      if defined($labels) && ref($labels) ne 'HASH';

   my $owner = defined($labels) ? $labels->{'dev.dockside.reservation.id'} : undef;
   return ( 'unknown', "container's reservation-id label is not a plain value" ) if ref($owner);
   return ( 'unrelated', 'a container this reservation does not own already holds the name' )
      unless defined($owner) && $owner eq $self->id();

   return ( 'ours', $id );
}

# Establishes what currently holds this reservation's name, reporting the same three ownership
# states as _create_entry_ownership above (a bare 'no container holds the name' outcome is
# reported as 'unknown', not a fourth state - see below). Called wherever a single, one-shot
# lookup would not be trustworthy evidence that nothing needs adopting:
#
# - straight after a 409 from POST /containers/create, where Docker reserves a container's name
#   early and releases it again if that create then fails, so an empty lookup immediately after is
#   a transient state rather than a verdict;
# - before a recovery retry concludes that a definitive-looking rejection (400/404/422) means this
#   reservation owns nothing, or that a create it cannot even attempt (a broken create body) has
#   nothing to adopt.
#
# In every one of these cases, the reservation's own earlier create - issued by a worker that has
# since died - may still be completing at Docker, independently of whatever this process just
# observed: the ownership lock is process state, and the request it no longer bounds is not. This
# polls for the name to resolve, then gives up unresolved rather than concluding anything - nothing
# observed here proves a collision is permanent, or that no container will ever appear, and
# reporting 'unknown' for a call site that treats it as unresolved is what keeps a genuinely
# still-in-flight predecessor's container from being orphaned by an expiry.
#
# The whole inspection is bounded, and each lookup's own request timeout is capped to what remains
# of that budget, because the reservation's ownership lock is held throughout: a stalled GET would
# otherwise hold it, and a draining worker waiting on it, for as long as the socket stayed open.
sub _create_confirm_ownership ($self, $cb) {
   my $deadline = steady_time() + $CREATE_CONFLICT_POLL_BUDGET_SECONDS;
   my @delays = @{$CREATE_CONFLICT_POLL_DELAYS};
   my $reason = 'no container holds the name';
   my ( $poll, $finish );

   # Clearing both closures leaves any timer or lookup callback still outstanding with nothing to
   # call, so the inspection reports its result exactly once and drops its own reference cycle.
   $finish = sub ( $state, $detail ) {
      $poll = $finish = undef;
      $cb->( $state, $detail );
      return;
   };

   $poll = sub {
      return $finish->( 'unknown', "$reason, and no inspection attempts remain" ) unless @delays;

      Mojo::IOLoop->timer( shift(@delays) => sub (@) {
         return unless $finish;
         my $remaining = $deadline - steady_time();
         return $finish->( 'unknown', "$reason within the name-conflict inspection budget" )
            if $remaining <= 0;

         _create_lookup_by_name( $self, $remaining, sub ($lookup) {
            return unless $finish;
            return $finish->( _create_entry_ownership( $self, $lookup->{'entry'} ) )
               if $lookup->{'state'} eq 'present';

            $reason = $lookup->{'state'} eq 'absent'
               ? 'no container holds the name'
               : ( $lookup->{'reason'} // 'the name lookup produced no usable evidence' );
            $poll->() if $poll;
         } );
      } );
      return;
   };

   $poll->();
   return;
}

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
                  #
                  # The write is contained because it is the one recoverable failure in this
                  # loop: losing a progress snapshot costs a client some smoothness, whereas
                  # letting it abort the loop would skip the remainder of this chunk, which is
                  # where Docker reports a mid-stream pull error for this same transfer. A pull
                  # that actually failed would then be reported as having succeeded.
                  my $now = time();
                  if ( $now > $lastPersist ) {
                     $lastPersist = $now;
                     my $persisted = eval { $self->update( { 'createStatus' => $cs } ); 1 };
                     flog( "Reservation::_create_stage_pulling: progress write failed for reservationId="
                         . $self->id() . ": " . format_caught_error($@) ) unless $persisted;
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

# $priorCreatePossible says whether a create request for this reservation may already have been
# issued by some earlier driver whose outcome was never learned. It is true for exactly one entry:
# a record read at stage 'creating' under the ownership lock, since 'creating' is persisted before
# the create is posted and nothing else ever posts one. A fresh create(), and a chain resumed from
# 'pulling', have no such predecessor - a record at 'pulling' has never reached the write that
# precedes a post - so for those this stage's own result is the whole story.
sub _create_stage_creating ($self, $body, $priorCreatePossible = 0) {
   my $socket = $CONFIG->{'docker'}{'socket'};

   my $createContainer = sub {
      return Mojo::Promise->new( sub ($resolve, $reject) {
         call_socket_api( $socket, '/containers/create?name=' . uri_escape( $self->name ), {
            'method' => 'POST',
            'json'   => $body,
         }, sub ($result, $err) {
            my ( $state, $detail ) = _create_classify( 'create', $result, $err );

            if ( $state eq 'failed' ) {
               my $refusal = "create refused for name '" . $self->name . "': $detail";

               # Where a prior create may have been issued, this retry is not the reservation's
               # first attempt: the earlier one, whose outcome this process never learned, may have
               # been issued by a worker that has since died and gone on to create a container
               # regardless - Docker went on processing it, since the ownership lock is process
               # state and the in-flight request is not. This retry's own refusal says nothing
               # about that earlier request, so it is not trusted as a verdict until ownership is
               # confirmed. With no possible predecessor, the refusal is definitive.
               if ($priorCreatePossible) {
                  _create_confirm_ownership( $self, sub ( $owner, $ownerDetail ) {
                     return $resolve->($ownerDetail) if $owner eq 'ours';
                     return $reject->($refusal) if $owner eq 'unrelated';
                     $reject->( _create_unresolved_error( "$refusal, and what holds name '"
                        . $self->name . "' could not be established: $ownerDetail" ) );
                  } );
                  return;
               }
               $reject->($refusal);
               return;
            }
            if ( $state eq 'unresolved' ) {
               $reject->( _create_unresolved_error( "create for name '" . $self->name
                  . "' reported no usable outcome: $detail" ) );
               return;
            }
            if ( $state eq 'conflict' ) {
               # A 409 says the name is taken and nothing more. It does not say by what: this
               # reservation's own earlier create - issued by a worker that has since died,
               # whose request Docker went on processing regardless, since the ownership lock
               # is process state and the in-flight request is not - collides with this one
               # exactly as an unrelated container does. Ownership is established by looking.
               _create_confirm_ownership( $self, sub ( $owner, $ownerDetail ) {
                  return $resolve->($ownerDetail) if $owner eq 'ours';
                  return $reject->( "name '" . $self->name
                     . "' is already in use by a container this reservation does not own" )
                     if $owner eq 'unrelated';
                  $reject->( _create_unresolved_error( "name '" . $self->name
                     . "' is taken but its owner could not be established: $ownerDetail" ) );
               } );
               return;
            }

            # Docker accepted the create, so a response carrying no usable Id leaves the
            # container's existence unknown rather than disproved. Resolving would persist an
            # unusable containerId and drive the start stage against nothing, so this reports an
            # unresolved outcome and lets a later pass find the container by name instead.
            # Decoding must not be allowed to throw, for the same reason as the name lookup - the
            # exception would bypass this promise entirely rather than rejecting it. The id is held
            # to the same hex-id shape _create_entry_ownership requires: a 201 whose body does not
            # actually carry a real Docker id is exactly the case this must not trust.
            my $containerId = eval { decode_json( $result->body )->{'Id'} };
            unless ( defined($containerId) && !ref($containerId) && $containerId =~ /^[0-9a-f]{12,64}$/ ) {
               $reject->( _create_unresolved_error( "create for name '" . $self->name
                  . "' returned no usable id: "
                  . ( format_caught_error($@) || 'no Id in response' ) ) );
               return;
            }
            $resolve->($containerId);
         } );
      } );
   };

   # Where a prior create may have been issued, the name is looked up before creating anything:
   # the container this stage is about to create may already exist, made by the request whose
   # outcome was lost. A container under this reservation's own name is adopted only if it also
   # carries this reservation's own id label, and only a lookup that positively establishes the
   # name is free may fall through to a create - an inconclusive lookup must not authorize one,
   # since it cannot tell "nothing holds this name" apart from "Docker did not answer".
   my $lookupOrCreate = $priorCreatePossible
      ? Mojo::Promise->new( sub ($resolve, $reject) {
           _create_lookup_by_name( $self, undef, sub ($lookup) {
              if ( $lookup->{'state'} eq 'unknown' ) {
                 $reject->( _create_unresolved_error( "cannot establish what holds name '"
                    . $self->name . "': " . $lookup->{'reason'} ) );
                 return;
              }
              unless ( $lookup->{'state'} eq 'present' ) {
                 $createContainer->()->then( $resolve, $reject );
                 return;
              }
              my ( $owner, $detail ) = _create_entry_ownership( $self, $lookup->{'entry'} );
              return $resolve->($detail) if $owner eq 'ours';
              return $reject->( "name '" . $self->name
                 . "' is already in use by a container this reservation does not own" )
                 if $owner eq 'unrelated';
              $reject->( _create_unresolved_error( "container holding name '" . $self->name
                 . "' could not be identified: $detail" ) );
           } );
        } )
      : $createContainer->();

   return $lookupOrCreate->then( sub ($containerId) {
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
      my $persisted = eval {
         $self->containerId($shortId);
         $self->update( { 'containerId' => $shortId } );
         1;
      };
      return 1 if $persisted;

      # The container exists; only the record of its id was lost. Failing definitively here would
      # expire a reservation whose container is running, so this reports an unresolved outcome
      # instead: the stage stays 'creating', and a later pass adopts that container by name.
      die _create_unresolved_error( "created a container for name '" . $self->name
         . "' but could not record its id: " . format_caught_error($@) );
   } );
}

sub _create_stage_starting ($self, $containerId) {
   my $socket = $CONFIG->{'docker'}{'socket'};

   return Mojo::Promise->new( sub ($resolve, $reject) {
      call_socket_api( $socket, "/containers/$containerId/start", { 'method' => 'POST' }, sub ($result, $err) {
         # Docker's own 'already started' 304 counts as success here - see _create_classify,
         # which holds that rule and the rest of this response's reading.
         my ( $state, $detail ) = _create_classify( 'start', $result, $err );
         return $resolve->(1) if $state eq 'success';
         return $reject->( "start refused for container '$containerId': $detail" )
            if $state eq 'failed';

         # The start may well have taken effect. Reporting it unresolved keeps the reservation at
         # 'starting', where a later pass reissues the start - idempotent, by that same 304.
         $reject->( _create_unresolved_error(
            "start of container '$containerId' reported no usable outcome: "
            . ( $detail // 'no detail' ) ) );
      } );
   } );
}

# The three-stage tail shared by create() and reconcile_create() below - each _create_run_from_*
# does its own stage's work then hands off to the next, so create() (which always starts at
# 'pulling') and a reconciliation resuming from any of the three stages both end up running
# exactly the same code for every stage they actually need, never a separate recovery-only copy.
# Records entry to $stage, reporting whether that reached disk. A caller that gets false must not
# go on to issue the stage's Docker call: a mutation made against a transition nothing recorded
# cannot be recovered, because no other process can see that it was ever attempted.
#
# An unresolved diagnostic belongs to one stage's repeated attempts, so re-entering the same stage
# carries it - and that stage's per-layer pull progress - forward, while advancing to a different
# stage or reaching a terminal one drops both. They describe an attempt that has now concluded;
# carrying them into 'done' would report a settled chain as still uncertain.
sub _create_status_enter ($self, $stage) {
   my $cs = ref( $self->{'createStatus'} ) eq 'HASH' ? $self->{'createStatus'} : {};
   my $resumed = ( $cs->{'stage'} // '' ) eq $stage;

   my $persisted = eval {
      $self->_create_status_set( {
         'stage'  => $stage,
         'failed' => 0,
         'layers' => ( $resumed ? $cs->{'layers'} : undef ) // {},
         # Written as a defined false value rather than left out, because a persisted createStatus
         # is merged field by field (Reservation::Mutate::update's cloneHash) and so cannot lose a
         # key by omission: a diagnostic dropped only from the hash written here would survive on
         # disk and describe a stage that has already moved on. Readers test it with ref(), which
         # is what makes the two forms interchangeable. Same reasoning as 'failed' above.
         'unresolved' => ( $resumed && ref( $cs->{'unresolved'} ) eq 'HASH' )
            ? $cs->{'unresolved'} : 0,
      } );
      1;
   };
   return 1 if $persisted;

   flog( "Reservation::_create_status_enter: could not record stage '$stage' for reservationId="
       . $self->id() . ": " . format_caught_error($@) );
   return 0;
}

sub _create_run_from_starting ($self) {
   return _create_rejected( _create_unresolved_error( "could not record the start of reservation '"
      . $self->id() . "'" ) ) unless $self->_create_status_enter('starting');

   return _create_stage_starting( $self, $self->containerId() )->then( sub (@) {
      flog("Reservation::create: reservation '" . $self->id() . "' created and started successfully");
      return 1 if $self->_create_status_enter('done');

      # The container is started; only the record saying so was lost. Left at 'starting', a later
      # pass reissues the start and settles the chain, so this stays recoverable rather than
      # reporting a success no other process can see.
      die _create_unresolved_error( "reservation '" . $self->id()
         . "' started but its completion could not be recorded" );
   } );
}

sub _create_run_from_creating ($self, $body, $priorCreatePossible = 0) {
   return _create_rejected( _create_unresolved_error( "could not record the create stage of "
      . "reservation '" . $self->id() . "'" ) ) unless $self->_create_status_enter('creating');

   return _create_stage_creating( $self, $body, $priorCreatePossible )->then( sub (@) {
      return $self->_create_run_from_starting();
   } );
}

# A chain at 'pulling' has never issued a create - 'creating' is written to disk before any create
# is posted - so the create that follows the pull is always this reservation's first, whether the
# chain is fresh or resumed, and is never told to account for a predecessor.
sub _create_run_from_pulling ($self, $body) {
   return _create_stage_pulling( $self, $self->data('image') )->then( sub (@) {
      return $self->_create_run_from_creating( $body, 0 );
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
      # 'unresolved' is cleared explicitly, for the reason _create_status_enter gives: a
      # definitive failure settles the question an earlier attempt could not, and a persisted
      # createStatus does not lose a key by omission.
      { 'stage' => 'failed', 'failed' => 1, 'error' => $msg, 'layers' => $layers,
        'unresolved' => 0 },
      { 'expiryTime' => YYYYMMDDHHMMSS(time) }
   );
   return $msg;
}

# Records that this attempt ended without establishing whether its Docker mutation took effect -
# the opposite of _create_fail above in the two ways that decide what happens next. The stage is
# left as it is, so reconcile_one still recognises the record as resumable, and no expiryTime is
# set, so load_clean_map does not start a deletion clock against a container that may exist.
#
# 'attempts' and 'since' are persisted rather than counted in memory because consecutive attempts
# are made by different workers, and after a restart by different processes; a count held in any
# one of them would restart at zero exactly when it mattered. 'retryAfter' is what stops a sibling
# worker's sweep retrying the instant this one releases the ownership lock - the lock excludes
# simultaneous drivers, but says nothing about how soon the next may start.
sub _create_unresolved ($self, $err) {
   my $msg = ( ref($err) eq 'Exception' ) ? $err->msg : "$err";
   my $cs = ref( $self->{'createStatus'} ) eq 'HASH' ? $self->{'createStatus'} : {};
   my $previous = ref( $cs->{'unresolved'} ) eq 'HASH' ? $cs->{'unresolved'} : {};
   my $attempts = ( $previous->{'attempts'} // 0 ) + 1;
   my $stage = $cs->{'stage'} // 'unknown';

   flog( "Reservation::_create_unresolved: reservation '" . $self->id()
       . "' outcome unresolved at stage '$stage' after $attempts attempt(s): $msg" );
   wlog( "Reservation: reservation '" . $self->id()
       . "' has not established the outcome of its container create after $attempts attempts: $msg" )
      if $attempts == $CREATE_UNRESOLVED_WARN_AFTER_ATTEMPTS;

   my %status = %$cs;
   delete $status{'error'};
   $status{'failed'} = 0;
   $status{'unresolved'} = {
      'reason'     => $msg,
      'since'      => $previous->{'since'} // YYYYMMDDHHMMSS(time),
      'attempts'   => $attempts,
      'retryAfter' => YYYYMMDDHHMMSS( time + $CREATE_UNRESOLVED_RETRY_COOLDOWN_SECONDS ),
   };
   $self->_create_status_set( \%status );

   return $msg;
}

# Records this attempt's outcome and reports whether the reservation is still recoverable.
# Contained, because it writes to disk: a write that throws here would otherwise escape into the
# reactor, leaving the ownership lock held and the in-flight count never cleared.
#
# An outcome that could not be recorded is reported as unresolved whatever it was. That is not a
# fallback guess - it is the literal state of affairs: the record still says whatever it said
# before, so as far as any other process can tell, this attempt has not concluded.
sub _create_record_outcome ($self, $err) {
   my $unresolved = ( ref($err) eq 'Exception' && $err->unresolved ) ? 1 : 0;
   my $msg = ( ref($err) eq 'Exception' ) ? $err->msg : "$err";

   my $recorded = eval { $unresolved ? $self->_create_unresolved($err) : $self->_create_fail($err); 1 };
   return ( $unresolved, $msg ) if $recorded;

   flog( "Reservation::_create_record_outcome: could not record the outcome of reservation '"
       . $self->id() . "' ($msg): " . format_caught_error($@) );
   return ( 1, $msg );
}

# Registers this reservation in %CREATE_IN_FLIGHT for $promise's own duration (a
# create()/reconcile_create() chain already running), clearing it once settled regardless of
# outcome. $onSettled (default: no one's listening - create()'s own contract has no external
# consumer for its tail) fires after cleanup, with the terminal ($self,undef)/(undef,$exception)
# result - reconcile_create() below is the one real consumer, since unlike create()'s
# fire-fast-then-continue $cb, its own $cb fires exactly once, on settle, with nothing else to
# ack early. $lock (optional: create()/reconcile_create()'s own per-reservation ownership lock
# handle - docs/adr/0007-create-restart-recovery.md's "Decision" section) is held in this
# closure and closed - releasing it - only once the chain settles, so the lock covers this
# chain's entire lifetime regardless of outcome.
sub _create_track ($self, $promise, $onSettled = sub {}, $lock = undef) {
   my $id = $self->id();
   $CREATE_IN_FLIGHT{$id} = 1;

   my $notified = 0;
   my $notify = sub ( $reservation, $err ) {
      return if $notified++;
      delete $CREATE_IN_FLIGHT{$id};
      close($lock) if $lock;
      $lock = undef;

      # The consumer runs here: after this chain's own cleanup, and outside the handler that
      # classifies the chain's outcome. Both placements are load-bearing. A consumer invoked from
      # inside that handler would have its own exception classified as this chain's failure -
      # overwriting an outcome already recorded, and entering the consumer a second time - and one
      # invoked before cleanup could observe an in-flight count and a held lock for a chain that
      # has already settled.
      eval { $onSettled->( $reservation, $err ); 1 }
         or flog( "Reservation::_create_track: settlement consumer failed for reservationId=$id: "
                . format_caught_error($@) );
      return;
   };

   # Two handlers on one ->then, deliberately, rather than ->then->catch: the rejection handler
   # must see only the chain's own failures, not anything the fulfilment handler raises.
   $promise->then(
      sub (@) {
         $notify->( $self, undef );
         return;
      },
      sub ($err) {
         my ( $unresolved, $msg ) = $self->_create_record_outcome($err);
         $notify->( undef,
            Exception->new( 'msg' => $msg, ( $unresolved ? ( 'unresolved' => 1 ) : () ) ) );
         return;
      },
   );

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
# Idempotency guard, in two parts, both required: a non-blocking per-reservation ownership lock
# (tryLockFile - docs/adr/0007-create-restart-recovery.md's "Decision" section), acquired
# before any Docker call begins, refuses a second concurrent create() for the same id outright
# rather than letting two processes or workers both drive a chain for it - immediately
# (LOCK_NB), not by queuing behind whoever holds it, since a second call arriving while a chain
# is genuinely live should be refused, not delayed until that chain happens to finish. Once the
# lock is held, nothing else can be concurrently mutating this id's createStatus, but this
# object's own copy of it can still be stale (loaded before some earlier chain for this id
# completed and released the lock this call just acquired) - so the actual guard is a forced
# reload under the lock, not the in-memory copy; see _reservation_reloaded's own comment.
#
# Composed with Mojo::Promise, not nested callbacks - the one genuinely multi-step async chain
# in this file (image check -> optional pull -> create -> start). This is a deliberate, scoped
# exception to this file otherwise having no Mojolicious-framework dependency at all (no $c, no
# ->render, no routes) - chosen here specifically because this is the one multi-step chain in
# the whole file; the alternative (nested callbacks) would be a four-deep pyramid. It is not
# precedent for giving another method a promise-shaped interface: every other async method here
# presents the plain ($self, ..., $cb) single-callback convention to its callers, whatever it
# uses internally (_hook_settle_outcome drives its retries off a Mojo::IOLoop timer and still
# reports through a single callback).
sub create ($self, $cb) {
   my $id = $self->id();

   my $lock = tryLockFile( _create_lock_path($id) );
   unless ($lock) {
      $cb->( undef, Exception->new( 'msg' => "Reservation '$id' already has a create in progress; refusing a duplicate create" ) );
      return;
   }

   if ( ( _reservation_reloaded($id) // {} )->{'createStatus'} ) {
      close($lock);
      $cb->( undef, Exception->new( 'msg' => "Reservation '$id' already has a createStatus set; refusing a duplicate create" ) );
      return;
   }

   my $body;
   try {
      $body = $self->cmdline_json();
   }
   catch {
      my $msg = $self->_create_fail($_);
      close($lock);
      $cb->( undef, Exception->new( 'msg' => "Failed to compile 'docker create' request body, with error: $msg" ) );
   };
   return unless $body;   # cmdline_json() threw - already reported, and the lock already released, via $cb above

   $self->_create_status_set( { 'stage' => 'pulling', 'failed' => 0, 'layers' => {} } );
   $cb->( $self, undef );

   $self->_create_track( $self->_create_run_from_pulling($body), sub {}, $lock );
   return;
}

# Resumes a create() chain abandoned by the process (or, under Mojo::Server::Prefork, just the
# one worker) that was driving it - reads createStatus.stage to decide where to resume, per
# docs/adr/0007-create-restart-recovery.md's own "Ground truth per stage" table.
# $self must already be a freshly-read, lock-held snapshot - see reconcile_one below, the one
# real caller, for both. Only a record read at 'creating' resumes with a possible prior create
# (the label-checked adoption and ownership confirmation in _create_stage_creating): 'creating' is
# persisted before any create is posted, so that is the one stage at which a predecessor's create
# may exist. A chain resumed from 'pulling' never reached that write, so its create is a first
# attempt and Docker's refusal of it is definitive, exactly as for a fresh create().
#
# 'starting' resumes from the container id already on disk and needs no create body, so it never
# compiles one. That is not an optimisation: cmdline_json() reads the reservation's profile, so an
# unrelated profile or configuration change can make it throw, and compiling it here would let
# that terminate a reservation whose container exists and only needs starting.
#
# $cb fires exactly once, when reconciliation fully settles (success or failure) - unlike
# create()'s own fire-fast-then-continue contract, nothing is waiting synchronously on this
# (it's driven by a timer, not an HTTP request), so there is no early ack to give. $lock is
# reconcile_one's own already-acquired ownership lock handle, threaded through to _create_track
# so it is held for this resumed chain's whole lifetime and released only once it settles -
# every early return in this function must close it first, since _create_track never runs to
# do so on those paths.
sub reconcile_create ($self, $cb, $lock = undef) {
   my $stage = ( $self->{'createStatus'} // {} )->{'stage'} // '';

   if ( $stage eq 'starting' ) {
      $self->_create_track( $self->_create_run_from_starting(), $cb, $lock );
      return;
   }

   unless ( $stage eq 'pulling' || $stage eq 'creating' ) {
      my $msg = "reservation '" . $self->id() . "' has unreconcilable createStatus.stage '$stage'";
      flog("Reservation::reconcile_create: $msg");
      close($lock) if $lock;
      $cb->( undef, Exception->new( 'msg' => $msg ) );
      return;
   }

   my ( $body, $prepError );
   try {
      $body = $self->cmdline_json();
   }
   catch {
      $prepError = $_;
   };

   if ( defined $prepError ) {
      # A reservation at 'creating' may already own a container, and adopting one needs no create
      # body - so ownership is established first, and only a reservation that provably owns
      # nothing is failed for a body that cannot be rebuilt.
      if ( $stage eq 'creating' ) {
         $self->_create_track( _create_adopt_only( $self, $prepError ), $cb, $lock );
         return;
      }
      my $msg = $self->_create_fail($prepError);
      close($lock) if $lock;
      $cb->( undef, Exception->new( 'msg' => $msg ) );
      return;
   }

   $self->_create_track(
      ( $stage eq 'pulling' ? $self->_create_run_from_pulling($body)
                            : $self->_create_run_from_creating( $body, 1 ) ),
      $cb, $lock );
   return;
}

# Resumes a reservation stuck at 'creating' whose create body cannot be rebuilt. Adoption needs no
# body, so a container this reservation already owns still reaches 'starting'. Anything else keeps
# the preparation failure - definitive where a confirmed record establishes that a container this
# reservation does not own already holds the name, unresolved otherwise. A body that cannot be
# compiled says nothing about whether a container was already created, and neither does a single
# absent snapshot: the create that would have made one may have been issued by a worker that has
# since died, whose request Docker went on processing regardless (the ownership lock is process
# state; the in-flight request is not) - so, like the 409 and recovery-retry cases,
# _create_confirm_ownership's bounded poll is what this waits on before concluding either way.
sub _create_adopt_only ($self, $prepError) {
   my $prepMsg = ( ref($prepError) eq 'Exception' ) ? $prepError->msg : "$prepError";
   my $context = "cannot rebuild the create request for reservation '" . $self->id() . "' ($prepMsg)";

   return Mojo::Promise->new( sub ( $resolve, $reject ) {
      _create_confirm_ownership( $self, sub ( $owner, $detail ) {
         return $resolve->($detail) if $owner eq 'ours';
         return $reject->("$context, and it owns no container to adopt") if $owner eq 'unrelated';
         $reject->( _create_unresolved_error(
            "$context, and what holds name '" . $self->name . "' could not be established: $detail" ) );
      } );
   } )->then( sub ($containerId) {
      my $shortId = substr( $containerId, 0, 12 );
      my $persisted = eval {
         $self->containerId($shortId);
         $self->update( { 'containerId' => $shortId } );
         1;
      };
      die _create_unresolved_error( "adopted the container holding name '" . $self->name
         . "' but could not record its id: " . format_caught_error($@) ) unless $persisted;

      return $self->_create_run_from_starting();
   } );
}

# Decides what a non-terminal createStatus.stage for $id actually means, and resumes the chain
# if it was abandoned - the one entry point _reconcile_pass (bin/app-server) uses for every
# candidate it finds.
#
# A non-terminal stage on disk is ambiguous alone - it can't say whether a live process is still
# driving it. The lock resolves that: refused means one is (skip). Acquired means the previous
# holder either finished and released it deliberately (a fresh reload now shows a terminal
# stage, or no reservation at all) or died mid-chain (the kernel freed the lock, but nothing
# wrote a terminal stage, so the reload still shows the same non-terminal stage). Reading the
# stage only after acquiring the lock is what tells these apart - the caller's own candidate
# list is just a snapshot and is never trusted directly for this (see _reservation_reloaded).
#
# Returns 1 if it resumed a chain, 0 if it skipped; says nothing about whether a resumed chain
# later succeeds, which lands in createStatus as always. The lock is held for the resumed
# chain's whole lifetime by reconcile_create/_create_track, released only when it settles.
sub reconcile_one ($class, $id, $cb = sub {}) {
   my $lock = tryLockFile( _create_lock_path($id) );
   unless ($lock) {
      $cb->();
      return 0;
   }

   my $reservation = _reservation_reloaded($id);
   my $createStatus = $reservation ? ( $reservation->{'createStatus'} // {} ) : {};
   my $stage = ref($createStatus) eq 'HASH' ? ( $createStatus->{'stage'} // '' ) : '';
   unless ( $stage =~ /^(?:pulling|creating|starting)$/ ) {
      close($lock);
      $cb->();
      return 0;
   }

   # A reservation whose last attempt could not establish its outcome names the time it is worth
   # asking Docker again. Honouring that here - under the lock, against the freshly reloaded
   # record - is what paces the retries: the lock excludes a second simultaneous driver, but does
   # nothing to stop a sibling worker's sweep picking the record up the instant the previous
   # holder releases it. This is an eligibility time, not a schedule; the next pass to run after
   # it is the one that retries.
   my $unresolved = ref( $createStatus->{'unresolved'} ) eq 'HASH' ? $createStatus->{'unresolved'} : {};
   my $retryAfter = $unresolved->{'retryAfter'};
   if ( defined($retryAfter) && !ref($retryAfter) && YYYYMMDDHHMMSS(time) lt $retryAfter ) {
      close($lock);
      $cb->();
      return 0;
   }

   $reservation->reconcile_create( $cb, $lock );
   return 1;
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

# How long a 'running' hook-status entry may sit with no execId assigned yet before this being
# genuinely still live stops being assumed and self-healing takes over instead - shared, for the
# same reason as $HOOK_HISTORY_MAX above, between this file's own hook_is_running and
# Reservation::Mutate's _hook_entry_liveness (used by hook_claim_if_not_running and
# launch_reset_stages_if_idle), which each independently make this same "is it still genuinely
# running" decision rather than one calling the other (one runs locked, one deliberately
# doesn't - see hook_is_running's own comment). Bounds a different window than
# $CONFIG->{'hooks'}{'defaultTimeoutSeconds'} (a hook's own configured execution time, once
# actually running): this is purely the gap between a claim being persisted and Docker handing
# back an execId for it, normally sub-second, so a generous multiple of ordinary latency is
# already ample - it exists only to eventually self-heal a claim whose owning process died
# outright before ever reaching that point (dispatch_hook_exec's own try/catch around this same
# window already handles every other way it can fail to get there).
our $HOOK_CLAIM_STALE_SECONDS = 60;

# Longest gap between retries of a hook outcome write that will not go through, and the attempt
# at which the retrying starts being reported as a stuck drain rather than a hiccup - see
# _hook_settle_outcome. The ceiling keeps an unwritable disk from being retried in a tight loop
# while still recovering promptly once it can be written to again; the warning threshold sits
# past the immediate retries, so an interrupted lock that succeeds on its second attempt never
# raises one.
our $HOOK_PERSIST_RETRY_CEILING = 30;
our $HOOK_PERSIST_WARN_AFTER_ATTEMPTS = 5;

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
# round-trip in the common case, it was never the thing overlap-safety depends on. Each self-heal
# write below passes $status->{'invocationId'} back to hook_status_completed as the invocation it
# believes it's resolving; if a newer claim has since superseded it, that write is rejected and
# this still reports not-running regardless - the same already-tolerated imprecision as the
# auto-invoke race above, not a new one, and the corrected in-memory entry hook_status_completed
# syncs on rejection is what a subsequent call sees.
sub hook_is_running ($self, $name) {
   my $status = $self->_hook_status_all->{$name};
   return 0 unless $status && ($status->{'state'} // '') eq 'running';

   # Newly-started, before docker_exec()'s own on_created callback has fired yet (see
   # hook_status_started/hook_status_set_running_details below) - the execId doesn't exist yet,
   # so there is nothing to check against Docker. Still counted as running unless it's been that
   # way for longer than $HOOK_CLAIM_STALE_SECONDS - past that, dispatch_hook_exec's own
   # try/catch around this exact window would already have settled anything it could catch, so
   # what's left with no execId this long is a claim whose owning process died outright.
   unless ( defined($status->{'execId'}) ) {
      my $staleBefore = YYYYMMDDHHMMSS( time - $HOOK_CLAIM_STALE_SECONDS );
      return 1 if ( $status->{'startTime'} // '' ) ge $staleBefore;
      $self->hook_status_completed( $name, { 'state' => 'aborted' }, ($status->{'invocationId'} // '') );
      return 0;
   }

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
         }, ($status->{'invocationId'} // '') );
         return 0;
      }
   }

   # No conclusive answer from the daemon - self-heal the record (so a future check, and any
   # status-read caller, sees 'aborted' rather than a misleadingly eternal 'running') and
   # report not-running.
   $self->hook_status_completed($name, { 'state' => 'aborted' }, ($status->{'invocationId'} // ''));
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
# hook_status_set_running_details, called from that callback once it's known. $extraFields
# merges onto the entry as-is - docker-event-daemon's own _launch_dispatch_prep uses this to
# attach 'pendingStartCount', so whichever code eventually resolves this entry to 'done' (the
# live dispatch, or either restart-recovery/on-claim heal path - see
# Reservation::Mutate::_resolve_hook_entry) can commit it, without needing to be that same
# invocation.
sub hook_status_started ($self, $name, $logPath, $extraFields = {}) {
   $self->_hook_status_store_one( $name, {
      'name'      => $name,
      'state'     => 'running',
      'execId'    => undef,
      'logPath'   => $logPath,
      'startTime' => YYYYMMDDHHMMSS(time),
      %$extraFields,
   } );
}

# Persist only this invocation's progress, under the same lock as its ownership check.
# Rejection refreshes the caller's local view and prevents a superseded exec from starting.
sub hook_status_set_running_details ($self, $name, $execId, $expectedInvocationId) {
   return $self->_hook_status_update_running($name, $expectedInvocationId, { 'execId' => $execId });
}

# Detached dispatch has no terminal completion. Confirm its start and any legacy launch
# count increment atomically while it still owns the running slot.
sub hook_status_dispatch_started ($self, $name, $expectedInvocationId, $incrementStartCount = 0) {
   return $self->_hook_status_update_running(
      $name, $expectedInvocationId, { 'dispatchStarted' => 1 }, $incrementStartCount );
}

sub _hook_status_update_running ($self, $name, $expectedInvocationId, $fields, $incrementStartCount = 0) {
   my ( $applied, $entry, $startCount ) = Reservation::Mutate::update_running_hook(
      $self->id(), $name, $expectedInvocationId, $fields, $incrementStartCount );
   ( $self->{'data'}{'hooks'} //= {} )->{'status'}{$name} = $entry;
   $self->{'data'}{'startCount'} = $startCount if defined $startCount;
   flog("Reservation: '$name' dispatch progress rejected for reservationId=" . $self->id()) unless $applied;
   return $applied;
}

# Called once the hook has finished, timed out, or been confirmed aborted, recording the
# outcome on both the master record and the bounded history array. $fields must include
# 'state' explicitly ('done' or 'aborted') - never defaulted, so a caller can never
# accidentally leave a completed entry reading 'running' by omission.
#
# Goes through Reservation::Mutate::resolve_hook_status, not _hook_status_store_one - the merge
# against the entry's prior fields happens fresh under the reservations-db lock, not against
# this process's own possibly-stale in-memory copy, and any 'pendingStartCount' the entry
# carries (see hook_status_started) is committed in that same locked write, not as a second,
# separate one that could land only one side of if a crash landed between them.
#
# $expectedInvocationId, when the caller was resolving a claim it made earlier (see
# hook_claim_if_not_running/hook_status_started), fences this write against a claim it no longer
# owns - see Reservation::Mutate::_resolve_hook_entry. Returns true if the write was applied,
# false if rejected as stale. Either way, $self's own in-memory copy is synced to whatever is now
# genuinely current - on rejection that's the superseding invocation's own entry, not $fields -
# but the history append and the caller's own post-completion continuation (an $on_settled or
# $cb) apply only when the write itself was applied: a rejected write has nothing of this
# invocation's own left to report.
sub hook_status_completed ($self, $name, $fields, $expectedInvocationId = undef) {
   my ( $applied, $entry, $startCount ) = resolve_hook_status( $self->id(), $name, $fields, $expectedInvocationId );
   ( $self->{'data'}{'hooks'} //= {} )->{'status'}{$name} = $entry;
   $self->{'data'}{'startCount'} = $startCount if defined $startCount;

   unless ($applied) {
      flog( "Reservation::hook_status_completed: '$name' resolve rejected for reservationId="
          . $self->id() . " - expected invocationId '" . ( $expectedInvocationId // '(none)' )
          . "', current is '" . ( $entry->{'invocationId'} // '(none)' ) . "'" );
      return 0;
   }

   record_hook_history($self->id(), { %$entry }, $HOOK_HISTORY_MAX);
   return 1;
}

# Delay in seconds before retry number $n of an outcome write. The first two are immediate: the
# failure most likely to be transient is a signal-interrupted lock acquisition, which succeeds as
# soon as it is retried. Past that the wait doubles up to a ceiling, so a disk that stays
# unwritable is retried indefinitely without spinning on it.
sub _hook_persist_retry_delay ($n) {
   return 0 if $n <= 2;
   my $delay = 0.5 * ( 2 ** ( $n - 3 ) );
   return $delay > $HOOK_PERSIST_RETRY_CEILING ? $HOOK_PERSIST_RETRY_CEILING : $delay;
}

# Persists a finished invocation's outcome, and only then releases its %HOOK_DISPATCH_IN_FLIGHT
# obligation and notifies the caller, once. It takes that obligation on itself, so every route
# into this function is counted for as long as it owes a write - including a failure that
# happens before any exec is dispatched. The obligation is what a draining worker waits on, so
# it is held until the outcome is durable rather than dropped when the exec connection closes.
# Two terminal outcomes release it:
#
#   applied - the write landed. Release, then notify exactly once.
#   fenced  - resolve_hook_status rejected the write because a newer invocation owns the entry
#             now, or the reservation is gone. Nothing of this invocation's own is left to
#             persist or report, so release and stay silent - hook_status_completed already
#             specifies that a rejected write suppresses the caller's continuation.
#
# A thrown write is neither. The outcome is still unrecorded, so the obligation stays held and
# the write is retried - same $fields, same $invocationId, never a fresh dispatch - until it
# applies or is fenced. Passing $invocationId is what keeps a retry fenced: a newer invocation
# claiming $name in between makes the retry a rejection rather than an overwrite.
#
# Retrying indefinitely is the point rather than a hazard. A drain must not report success for an
# outcome that was never written, and an entry left 'running' for a later reader to repair is not
# a recorded outcome - it is a repair that has not happened yet, and may never happen if nothing
# reads the entry again. Bounding how long a worker may wait for its obligations is the shutdown
# policy's concern, not this function's; this function's job is to not claim settlement it
# cannot back. A worker that exits first loses the retry with the process, which is the same
# position a process killed outright is already in.
#
# $outcome, when set, is the settlement state to report as-is; undef derives it from the
# persisted entry. A dispatch that never ran reports 'aborted', which _hook_outcome_state would
# otherwise flatten to the less specific 'failed'.
#
# A retry can re-apply a write that already landed, when it was the history append following it
# that threw. _resolve_hook_entry is idempotent for exactly this case, at the cost of at most one
# duplicate history row - preferred over discarding a real outcome.
sub _hook_settle_outcome ($self, $name, $fields, $invocationId, $outcome, $err, $on_settled) {
   # Registered here rather than relied upon from the caller, and idempotent because it is keyed
   # by invocation: a dispatched hook is already counted for the exec it is awaiting, while a
   # failure before dispatch reaches this point with nothing counted at all. Either way the
   # obligation has to exist before the first write is attempted, or a write that throws would
   # schedule its retries against a count that never rose - and a drain reading zero would let
   # the worker exit, discarding the retry and leaving an acknowledged invocation recorded as
   # still running.
   $HOOK_DISPATCH_IN_FLIGHT{$invocationId} = 1;

   my $attempt = 0;
   my $persist;

   $persist = sub {
      $attempt++;
      my ( $applied, $failed );
      my $written = try {
         $applied = $self->hook_status_completed( $name, $fields, $invocationId );
         1;
      }
      catch {
         $failed = $_;
         0;
      };

      unless ($written) {
         my $delay = _hook_persist_retry_delay($attempt);
         flog( "Reservation::_hook_settle_outcome: '$name' could not persist its outcome for reservationId="
             . $self->id() . " (attempt $attempt, retrying in ${delay}s, dispatch still counted in flight): "
             . format_caught_error($failed) );
         # Once, at the point this stops looking like a momentary interruption - the drain this
         # is holding open is otherwise indistinguishable from a hook that is simply slow.
         wlog( "Reservation::_hook_settle_outcome: '$name' outcome still unwritten for reservationId="
             . $self->id() . " after $attempt attempts; this worker cannot finish draining until "
             . "it is written: " . format_caught_error($failed) )
            if $attempt == $HOOK_PERSIST_WARN_AFTER_ATTEMPTS;
         Mojo::IOLoop->timer( $delay => sub (@) { $persist->() } );
         return;
      }

      # Released here, after the durability decision and before the one notification, so an
      # exception thrown by $on_settled itself can neither leak the count nor produce a second
      # notification. $persist is cleared to break its own reference cycle.
      delete $HOOK_DISPATCH_IN_FLIGHT{$invocationId};
      $persist = undef;

      return unless $applied;

      $on_settled->( $outcome // _hook_outcome_state( $self->hook_status($name) ), $err );
      return;
   };

   $persist->();
   return;
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
#      exactly, just without the fork) hooks in here only, and answers its own caller from here
#      alone - anything that fails after this point (prep below, or dispatch itself) is reported
#      only via $on_settled, exactly like a genuine docker_exec dispatch failure already is;
#      run_hook_manual's own such caller discovers it only by polling
#      User::runContainerHookStatus, never via the original request.
#   $on_settled->($outcome, $err) - fires once dispatch has fully finished, or could not even be
#      attempted: $outcome is one of hook_status's own state values ('done'/'failed'/'aborted').
#      A caller that needs to know the final result (docker-event-daemon's launch DAG, to call
#      launch_resolve_stage) hooks in here. A rejected ownership check suppresses this callback.
#
# Deliberately does NOT repeat run_hook_manual's own on-demand-specific validation gates
# (declared? implemented? manual?) - a different caller may have entirely different gating;
# those stay in each caller. $args:
#   user    - exec user (default: $self->unixuser())
#   timeout - seconds; defaults to $CONFIG->{'hooks'}{'defaultTimeoutSeconds'}
sub dispatch_hook_exec ($self, $name, $script, $args, $on_claimed, $on_settled) {
   my $invocationId = sprintf( "%08x", int( rand(0xffffffff) ) );
   my $logPath = "$CONFIG->{'tmpPath'}/r-" . $self->id() . "-hook-$invocationId.log";

   my $claimedEntry = hook_claim_if_not_running( $self->id(), $name, $logPath, $HOOK_HISTORY_MAX, $invocationId );
   unless ($claimedEntry) {
      $on_claimed->(undef);
      return;
   }
   # Sync this process's own in-memory copy - see hook_claim_if_not_running's own comment for
   # why (mutate() only ever wrote a fresh, separately-loaded copy, not $self).
   ( $self->{'data'}{'hooks'} //= {} )->{'status'}{$name} = $claimedEntry;
   $on_claimed->($claimedEntry);

   # A claimed slot with no execId ever assigned: with no exec dispatched, there is nothing
   # left running that could ever settle it on its own, so a failure here must be settled in
   # this same try/catch, the one place that notices it - unlike a failure once docker_exec
   # itself has been called below, which settles inside its own async completion callback.
   my ( @Command, $user, @env, $timeout, $containerId, $log );
   my $prepared = try {
      @Command = $self->ide_command();
      die Exception->new( 'msg' => 'Internal error - no IDE command configured', 'dbg' => 'Reservation::dispatch_hook_exec: ide_command() returned empty' ) unless @Command;
      $Command[-1] = 'run_hook';
      push( @Command, $name, $script );

      my $owner = $self->owner('username');
      $user = User->load($owner);
      die Exception->new( 'msg' => "The owner of this devtainer ('$owner') no longer exists", 'status' => 400 ) unless $user;

      @env = map { my $e = $_; $e =~ s/^--env=//; $e } $self->_hook_env($user);

      $timeout     = $args->{'timeout'} || $CONFIG->{'hooks'}{'defaultTimeoutSeconds'} || 120;
      $containerId = $self->containerId();

      open( $log, '>>', $logPath )
         or die Exception->new( 'dbg' => "Reservation::dispatch_hook_exec: cannot open log '$logPath': $!" );
      $log->autoflush(1);
      1;
   }
   catch {
      # Mirrors the docker_exec-itself-failed branch below exactly (settle 'aborted', notify via
      # $on_settled) - $on_claimed has already fired by this point (same as it does for that
      # branch too), so there is nothing left to retract; the caller already knows to discover
      # the real outcome via polling, same as for any other post-claim failure. Settled through
      # the same helper as that branch, so this path gets the same write-failure handling and a
      # failed write is reported via $on_settled rather than escaping to this function's caller.
      my $dbg = format_caught_error($_);
      flog("Reservation::dispatch_hook_exec: '$name' failed before dispatch could begin: $dbg");
      $self->_hook_settle_outcome( $name, { 'state' => 'aborted' }, $invocationId, 'aborted', $dbg, $on_settled );
      0;
   };
   return unless $prepared;

   flog( "Reservation::dispatch_hook_exec: DISPATCHING (via exec API): " . join( '|', map { sanitize_sensitive_text($_) } @Command ) );

   # Last synchronous step before docker_exec's own async call - see %HOOK_DISPATCH_IN_FLIGHT's
   # own comment for why this placement (and the decrement's) is what makes the count reliable.
   $HOOK_DISPATCH_IN_FLIGHT{$invocationId} = 1;

   docker_exec( $CONFIG->{'docker'}{'socket'}, $containerId, {
      'Cmd' => \@Command, 'User' => $args->{'user'} // $self->unixuser(), 'Env' => \@env,
   }, {
      'inactivity_timeout' => $timeout + 30,
      'request_timeout'    => $timeout,
      'on_created' => sub ($execId) { $self->hook_status_set_running_details( $name, $execId, $invocationId ); },
      'on_output'  => sub ($stream, $bytes) { print $log $bytes; },
   }, sub ( $result, $err ) {
      close($log);

      # Derived before any write is attempted, so a retry inside _hook_settle_outcome replays
      # exactly this result rather than re-deriving it from state that has since moved on.
      my ( $fields, $outcome );
      if ( !$result ) {
         flog("Reservation::dispatch_hook_exec: '$name' failed to dispatch: $err");
         ( $fields, $outcome ) = ( { 'state' => 'aborted' }, 'aborted' );
      }
      else {
         my $rc       = $result->{'exitCode'};
         my $timedOut = $result->{'timedOut'} ? 1 : 0;
         $fields = {
            'state'    => 'done',
            'exitCode' => $rc,
            'timedOut' => $timedOut,
            'busy'     => ( defined($rc) && $rc == 2 && !$timedOut ) ? 1 : 0,
         };
      }

      $self->_hook_settle_outcome( $name, $fields, $invocationId, $outcome, $err, $on_settled );
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
