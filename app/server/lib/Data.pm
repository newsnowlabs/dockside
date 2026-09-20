package Data;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw($CONFIG $HOSTNAME $INNER_DOCKERD $VERSION $HOSTINFO invalidate_profile_cache valid_ide_name
   $CONFIG_PATH $USERS_FILE $ROLES_FILE $PASSWD_FILE $PROFILES_DIR);

use B;
use JSON;
use Time::HiRes qw(stat time gettimeofday);
use Try::Tiny;
use Util qw(flog wlog cacheReadWrite get_config call_socket_json_api);

# Single source of truth for all persistent config storage paths.
# Exported so that User::Manage and Profile::Manage can reference these
# constants directly rather than each independently hard-coding '/data/config'.
# Any future relocation of the config root requires only a change here.
our $CONFIG_PATH  = '/data/config';
our $USERS_FILE   = "$CONFIG_PATH/users.json";
our $ROLES_FILE   = "$CONFIG_PATH/roles.json";
our $PASSWD_FILE  = "$CONFIG_PATH/passwd";
our $PROFILES_DIR = "$CONFIG_PATH/profiles";

# Load in the container ID of this Dockside container and the inner-dockerd flag.
# See entrypoint.sh for details. Read from app-server's own service data dir, not nginx's -
# ctr-id/inner-dockerd are identical copies in every service's data dir (entrypoint.sh writes
# them per-service), but 'version' is only ever computed and written by app-server/run, the
# process that actually renders it into the UI.
our $HOSTNAME = get_config('/etc/service/app-server/data/ctr-id');
our $INNER_DOCKERD = get_config('/etc/service/app-server/data/inner-dockerd');
our $VERSION = get_config('/etc/service/app-server/data/version');
our $HOSTINFO = { 'docker' => undef, 'IDEs' => undef }; # Host info cache: populated later

# Core config files: a failure to parse one is a critical error, not something to run past on
# stale/undef data (see load()'s own parse-failure handling). Profiles are deliberately not
# here - a single unparseable profile is skipped individually (Data.pm's profiles loader), never
# a whole-server failure.
my %CORE_FILE = map { $_ => 1 } qw( config.json users.json roles.json reservations.json containers.json );

# Set true by app-server / docker-event-daemon around their own startup load: a core-file parse
# failure then exits the process (bypassing any surrounding catch) so s6 restarts it. Left false
# for reload-time loads and for nginx-embedded Proxy, where the failure is instead re-thrown and
# caught by the request/event handler already around it - failing that one request/event closed
# rather than taking the process, or an nginx worker, down.
our $CORE_PARSE_FAILURE_FATAL = 0;

sub parse_json ($json) {
   local $_ = $json;

   # Remove lines beginning //
   s!^\s*//.*$!!gm;

   # Remove //.... from ends of lines, but only if '"' not used in the comment
   s!//[^"]*$!!gm;

   return from_json( $_, { 'relaxed' => 1 } );
}

# One message to both loggers for a config value this server cannot use: wlog reaches stderr - a
# supervised service's own log stream, and nginx's error log for the embedded proxy - while flog
# files it in the service log alongside the load lines it belongs with.
sub _config_warn ($message) {
   my $msg = "Data::load: config.json: $message";
   flog($msg);
   wlog($msg);
   return;
}

# True only of a JSON number that is a finite whole number of at least 1. The decoded scalar's
# own flags are what tells a JSON number apart from a JSON string of digits - from_json leaves a
# number with numeric flags and no string flag of its own - and the two are kept distinct
# deliberately by _validate_shutdown_grace_seconds below: the only string that key takes is
# 'unlimited', so a quoted "300" is a mistake to tell the operator about rather than silently
# accept. The number's own decimal form then has to be plain digits: an exponent that overflows
# decodes to infinity, which is numerically whole and positive and would otherwise pass, and a
# magnitude beyond what prints as digits is no ceiling anyone means. A JSON boolean decodes to
# an object and a number the decoder keeps as a string (one too large for a native integer) to
# a string, so both fall to the two tests before this one.
sub _is_json_positive_integer ($value) {
   return 0 if !defined($value) || ref($value);

   my $flags = B::svref_2object( \$value )->FLAGS;
   return 0 unless ( $flags & ( B::SVp_IOK | B::SVp_NOK ) ) && !( $flags & B::SVp_POK );

   return "$value" =~ /\A[1-9][0-9]*\z/ ? 1 : 0;
}

# Settles appServer.shutdownGraceSeconds in place on a freshly loaded config.json's appServer
# section. The string 'unlimited' and a positive integer number of seconds stand as given;
# every other shape, and the key's absence, leave it 'unlimited', with one warning for anything
# actually written in the file. A value this server cannot use is never a reason to fail the
# load: the rest of the config is serviceable, and the fallback is the safest of the two shapes -
# it waits for in-flight work rather than cutting it short.
sub _validate_shutdown_grace_seconds ($appServer) {
   if ( exists $appServer->{'shutdownGracePeriod'} ) {
      _config_warn( 'appServer.shutdownGracePeriod is not a key this server reads; a draining ' .
         "worker's ceiling comes from appServer.shutdownGraceSeconds" );
      delete $appServer->{'shutdownGracePeriod'};
   }

   unless ( exists $appServer->{'shutdownGraceSeconds'} ) {
      $appServer->{'shutdownGraceSeconds'} = 'unlimited';
      return;
   }

   my $value = $appServer->{'shutdownGraceSeconds'};

   # The numeric test must come before any string comparison against $value: comparing a number
   # as a string caches its string form in the scalar, which is the very flag the numeric test
   # reads to tell 300 from "300".
   return if _is_json_positive_integer($value);
   return if defined($value) && !ref($value) && $value eq 'unlimited';

   my $shown =
        ref($value)      ? 'the ' . ref($value) . ' value it holds'
      : !defined($value) ? 'its null value'
      :                    "the value '$value'";
   _config_warn( "appServer.shutdownGraceSeconds: ignoring $shown; it takes the string " .
      "'unlimited' or a positive integer number of seconds, and drains unlimited until it holds " .
      'one of those' );
   $appServer->{'shutdownGraceSeconds'} = 'unlimited';
   return;
}

sub valid_ide_name ($ide) {
   # 'none' is a pseudo-IDE meaning "no IDE" (SSH-only) - see Profile::applyDefaultsAndFilters.
   return defined($ide) && ( $ide eq 'none' || $ide =~ m!\A[^./\0][^/\0]*/[^./\0][^/\0]*\z! );
}

####################################################################################################

our $CONFIG;

# Supports individual files or all files in a given directory (in which case the 'process' sub can expect an array of data)
my $CONFIG_FILES;
$CONFIG_FILES = {
   'users.json' => {
      # Read under cacheReadWrite's shared lock, the same lock User/Manage.pm's writes take
      # exclusively - so a read never observes a half-written file, matching reservations.json
      # and containers.json below.
      'load' => \&cacheReadWrite,
      'process' => sub ($c) {
         my $USERS;
         foreach my $username ( keys %$c ) {
            $c->{$username}{'username'} = $username;
            my $User = User->new( $c->{$username} );
            if($User) {
               $USERS->{$username} = $User;
            }
         }

         # Set up convenience shortcut
         User::ConfigureUsers($USERS);
      },
      'parse' => \&parse_json
   },
   'roles.json' => {
      # Shared-locked read, same as users.json above.
      'load' => \&cacheReadWrite,
      'process' => sub ($ROLES) {
         if($ROLES) {
            # Set up convenience shortcut
            User::ConfigureRoles($ROLES);
            User::ConfigureUsers();
         }
      },
      'parse' => \&parse_json
   },
   'config.json' => {
      'process' => sub ($c) {
         # Set up convenience shortcut
         $CONFIG = $c;

         # Assign defaults
         $CONFIG->{'docker'}{'socket'} //= '/var/run/docker.sock';
         $CONFIG->{'docker'}{'sizes'} //= 0;

         $CONFIG->{'ide'}{'path'} //= '/opt/dockside';
         $CONFIG->{'ide'}{'subPath'} //= 'ide';
         $CONFIG->{'ide'}{'fullPath'} //= "$CONFIG->{'ide'}{'path'}/$CONFIG->{'ide'}{'subPath'}";
         $CONFIG->{'ide'}{'default'} //= 1;

         $CONFIG->{'ssh'}{'path'} //= "$CONFIG->{'ide'}{'path'}/host";
         $CONFIG->{'ssh'}{'port'} //= 2222;    # in-container wstunnel v6 listen port
         $CONFIG->{'ssh'}{'v10port'} //= 2223; # in-container wstunnel v10 listen port
         $CONFIG->{'ssh'}{'default'} //= 1;

         # Standalone async UI app-server - loopback-only, nginx proxy_passes to it;
         # 0 = unlimited, parity with nginx's own client_max_body_size 0.
         $CONFIG->{'appServer'}{'port'} //= 8100;
         $CONFIG->{'appServer'}{'workers'} //= 4;
         $CONFIG->{'appServer'}{'maxRequestSize'} //= 0;
         # create's own restart-recovery/graceful-exit design - see
         # docs/adr/0007-create-restart-recovery.md. reconcileIntervalSeconds is the per-worker
         # periodic reconciler's own recheck cadence: every worker's tick runs the same candidate
         # sweep, and each candidate is claimed with its own non-blocking lock
         # (Reservation::reconcile_one), so whichever worker reaches a reservation first
         # reconciles it and the others skip it.
         $CONFIG->{'appServer'}{'reconcileIntervalSeconds'} //= 300;

         # shutdownGraceSeconds is the ceiling a shutting-down worker's drain waits under, and
         # the one bin/app-server also hands Mojo::Server::Prefork as its graceful_timeout. It is
         # validated rather than defaulted with //=, because it takes two shapes and a
         # mistyped one silently bounds a drain that operators expect to be unlimited.
         _validate_shutdown_grace_seconds( $CONFIG->{'appServer'} );

         # A hook run's server-side time limit in seconds when the caller sets none. The only
         # default for it: every dispatch path reads this key and none carries a fallback of
         # its own. The container's stop grace (docker-compose.yml's stop_grace_period, or
         # docker run's --stop-timeout) must exceed it - see docs/upgrading.md.
         $CONFIG->{'hooks'}{'defaultTimeoutSeconds'} //= 300;

         # How long a hook-invocation log file (tmpPath/r-<id>-hook-<invocationId>.log) is kept
         # before logrotate-daemon's age-based sweep deletes it - see
         # app/scripts/runscripts/logrotate/data/logrotate-daemon. Independent of
         # HOOK_HISTORY_MAX (Reservation.pm), which only bounds the JSON history *record*, not
         # the log file an evicted record pointed at.
         $CONFIG->{'hooks'}{'logRetentionDays'} //= 30;
      },
      'parse' => \&parse_json
   },
   'passwd' => {
      'process' => sub ($c) {
         # Set up convenience shortcut
         User::ConfigurePasswd($c);
      },
      'parse' => sub ($raw) {
         return {
            map {
               s/^\s*|\s*$//;    # Trim whitespace
               ( split( ':', $_ ) )    # return <username> => <encrypted password>
              }
              grep {
               $_ !~ '^(:?#.*)?$'                  # Trim empty lines and comments
              } split( "\n", $raw )
         };
      }
   },
   'profiles/*.json' => {
      'process' => sub ($c) {
         my %PROFILES;
         my %PROFILE_ERRORS;
         foreach my $profile ( keys %$c ) {
            my $P = Profile->new( $c->{$profile} );

            if($P) {
               if($P->{'errors'}) {
                  flog( sprintf("Error(s) found in profile '%s': %s", $profile, join("; ", $P->errorsArray)) );
               }
               else {
                  $PROFILES{$profile} = $P;
               }
            }
         }

         # Set up convenience shortcut
         Profile::Configure(\%PROFILES);
      },
      'parse' => \&parse_json
   },
   'reservations.json' => {
      'path' => sub () { return $CONFIG->{'reservationsPath'}; },
      'load' => \&cacheReadWrite,
      'parse' => \&Reservation::Load::load,
      'process' => sub ($data) {
         Reservation->update_container_info();
      }
   },
   'containers.json' => {
      'path' => sub () { return $CONFIG->{'containersPath'}; },
      'load' => \&cacheReadWrite,
      'parse' => sub ($json_text) { return decode_json($json_text); },
      'process' => sub ($data) {
         # Capture network list for the Dockside container before updating $CONTAINERS,
         # so we can detect changes and invalidate the profile cache if needed.
         my $oldNetworks = join(',', sort keys %{ (Containers->containers // {})->{$HOSTNAME // ''}{'inspect'}{'Networks'} // {} });

         Containers::Configure($data);

         # If the Dockside container's network list changed, force profiles to reload on
         # the next request. Profiles compute their available-networks list at load time
         # from $CONTAINERS; without this invalidation they would serve stale (or empty)
         # network lists after containers.json is first written or after a network
         # connect/disconnect event.
         my $newNetworks = join(',', sort keys %{ (Containers->containers // {})->{$HOSTNAME // ''}{'inspect'}{'Networks'} // {} });
         if ($oldNetworks ne $newNetworks) {
            flog("Data::load: containers.json: Dockside container network list changed ('$oldNetworks' -> '$newNetworks'); invalidating profile cache");
            invalidate_profile_cache();
         }

         Reservation->update_container_info();
      }
   },
   'hostInfo' => {
      'const' => sub {
         return if $HOSTINFO && $HOSTINFO->{'docker'} && $HOSTINFO->{'IDEs'};

         # Populate docker host info, comprising Runtimes and DefaultRuntimes etc
         $HOSTINFO->{'docker'} = call_socket_json_api($CONFIG->{'docker'}{'socket'}, '/info');

         # Available IDEs on the host system
         if( -d "$CONFIG->{'ide'}{'fullPath'}" ) {
            my $globPath = "$CONFIG->{'ide'}{'fullPath'}/*/*";
            my $ideRoot = $CONFIG->{'ide'}{'fullPath'};
            # Strip off all but final <ideType>/<version>, and only surface
            # entries that are safe to feed back into $DOCKSIDE_ROOT/ide/$IDE.
            my @hostIDEs = map {
               my ($ide) = $_ =~ m!\A\Q$ideRoot\E/([^/\0]+/[^/\0]+)\z!;
               defined($ide) && -d $_ && valid_ide_name($ide) ? $ide : ();
            } <"$globPath">;
            $HOSTINFO->{'IDEs'} = \@hostIDEs;
         }
      }
   }
};

# Loops through all CONFIG_FILES, or all given config files (or config paths);
# constructs a list of config files within config paths, as required;
# but eliminate unreadable config files.
#
# Where a config file is found to have been modified,
# load the file (using custom 'load' function or generic 'get_config' function),
# parse the contents (using custom 'parse' function),
# and finally process the contents (using the custom 'process' function).

sub load (@configFiles) { # Optional: list of config files to check for changes and load.

   if(!@configFiles) {
      # Ensure we load config.json first; other modules might depend upon it.
      @configFiles = ('config.json', grep { $_ ne 'config.json' } sort keys %$CONFIG_FILES);
   }

   # FIXME: Throttle checking config files to 1/5s
   foreach my $p ( @configFiles ) {

      if( !$CONFIG_FILES->{$p} ) {
         flog( "Data::load: error parsing '$p': no such config file defined" );
         next;
      }

      if( $CONFIG_FILES->{$p}{'const'} ) {
         # Constant value - just call the sub and store the result
         $CONFIG->{$p} = &{ $CONFIG_FILES->{$p}{'const'} }();
         next;
      }

      my $isGlob = ($p =~ m!\*!);

      # Prepare a list of files to hopefully read in
      my $path = $CONFIG_FILES->{$p}{'path'} ? $CONFIG_FILES->{$p}{'path'}->() : "$CONFIG_PATH/$p";

      my @candidateFiles;
      if ( $isGlob ) {
         @candidateFiles = <"$path">;
      } else {
         push @candidateFiles, $path;
      }

      # Check all files are readable 
      my @files;
      foreach my $candidateFile (@candidateFiles) {
         if ( -r $candidateFile ) {
            push @files, $candidateFile;
         } else {
            flog( "Data::load: error parsing '$candidateFile': file can't be read" );
         }
      }

      # Work out the most recent last-modified time for all files in the current list
      my $lastModified = 0;
      foreach my $file (@files) {
         # This is Time::HiRes::stat (this file's own top-of-file import), not CORE::stat -
         # $lm carries a fractional-second mtime, and the comparison below relies on that
         # sub-second precision to tell apart two writes to the same file within one wall-clock
         # second (a real occurrence under concurrent reservation/container churn). Removing
         # 'stat' from that import - e.g. while tidying an apparently-unused-looking name -
         # would silently widen every caller's staleness window back out to a full second.
         my $lm = (stat($file))[9];
         $lastModified = $lm if $lm > $lastModified;
      }

      # Skip further processing if files haven't been modified since the last time we processed them
      $CONFIG_FILES->{$p}{'lastModified'} //= 0;
      next if $lastModified == $CONFIG_FILES->{$p}{'lastModified'};

      flog( "Data::load: $p, previously modified at $CONFIG_FILES->{$p}{'lastModified'}, now modified at $lastModified");

      # Get data from files.  For a glob, default to an empty hashref so that
      # removing the last matching file reloads as an empty set (the 'process'
      # callback clears its registry) rather than leaving $data undef, which the
      # callbacks (e.g. `keys %$c`) would die on.
      my $data = $isGlob ? {} : undef;
      my $single_key;
      my $file_count = @files;
      try {
         foreach my $file (@files) {
            my ($filename) = $file =~ m!([^/\.]+)(?:\.[^\./]+)?$!;

            try {
               flog( "Data::load: loading '$file'");
               $data->{$filename} = 
                  $CONFIG_FILES->{$p}{'parse'}->(
                     ($CONFIG_FILES->{$p}{'load'} || \&get_config)->($file)
                  );
               $single_key = $filename if !$isGlob && $file_count == 1;
            }
            catch {
               chomp;
               my $err = $_;

               if ( $CORE_FILE{$p} ) {
                  # Log loudly - to flog and, unconditionally, to STDERR so it reaches the
                  # container's log stream (`docker logs`) whatever the state of the log file -
                  # then either exit for s6 to restart (at startup, $CORE_PARSE_FAILURE_FATAL) or
                  # re-throw. The re-throw aborts this file's update below, so its lastModified and
                  # last-good data are left untouched (the outer handler swallows it) and the next
                  # load retries, rather than running 'process' on a partial/undef parse.
                  my $emsg = "Data::load: ERROR: cannot parse core config file '$file': $err";
                  flog($emsg);
                  print STDERR "[dockside] $emsg\n";
                  if ( $CORE_PARSE_FAILURE_FATAL ) {
                     flog("Data::load: ERROR: exiting so s6 restarts this service");
                     print STDERR "[dockside] Data::load: ERROR: exiting so s6 restarts this service\n";
                     exit(1);
                  }
                  die $err;
               }

               flog("Data::load: error parsing '$file': '$err'");
            };
         }

         if (!$isGlob) {
            if ($file_count == 1 && $data && defined $single_key && exists $data->{$single_key}) {
               $data = $data->{$single_key};
            } else {
               $data = undef;
            }
         }

         # As we're inside an eval, if parsing fails an exception will be thrown and we won't update the lastModified time.
         $CONFIG_FILES->{$p}{'lastModified'} = $lastModified;

         # Run post-parse compilation step (when required).
         if( $CONFIG_FILES->{$p}{'process'} ) {
            $CONFIG_FILES->{$p}{'process'}->($data);
         }

         return 1;
      }
      catch {
         chomp;
         flog("Data::load: error parsing '$p': '$_'");
      };
   }
}

# Reload without trusting modification timestamps. Ownership checks need this even
# with fractional-second stat: separate writes can still have identical timestamps.
sub load_fresh (@configFiles) {
   for my $p ( @configFiles ? @configFiles : keys %$CONFIG_FILES ) {
      $CONFIG_FILES->{$p}{'lastModified'} = -1 if $CONFIG_FILES->{$p};
   }
   load(@configFiles);
}

# Force the profile glob to reload on the next Data::load call.
# Needed after profile file deletion or rename, where the mtime of the remaining
# files does not change and the cache would otherwise not detect the update.
# A -1 sentinel is used rather than delete: when the last profile is removed the
# glob is empty and Data::load computes a max-mtime of 0, which would equal a
# deleted/defaulted-0 stored value and skip the reload, leaving stale profiles.
sub invalidate_profile_cache () {
   $CONFIG_FILES->{'profiles/*.json'}{'lastModified'} = -1;
}

1;
