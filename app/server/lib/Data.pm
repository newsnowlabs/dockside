package Data;

use strict;

use Exporter qw(import);
our @EXPORT_OK = qw($CONFIG $HOSTNAME $INNER_DOCKERD $VERSION);

use JSON;
use Time::HiRes qw(stat time gettimeofday);
use Try::Tiny;
use Util qw(flog cacheReadWrite get_config);

my $CONFIG_PATH = '/data/config';

# Load in the container ID of this Dockside container and the inner-dockerd flag.
# See entrypoint.sh for details
our $HOSTNAME = get_config('/etc/service/nginx/data/ctr-id');
our $INNER_DOCKERD = get_config('/etc/service/nginx/data/inner-dockerd');
our $VERSION = get_config('/etc/service/nginx/data/version');

sub parse_json {
   local $_ = shift;

   # Remove lines beginning //
   s!^\s*//.*$!!gm;

   # Remove //.... from ends of lines, but only if '"' not used in the comment
   s!//[^"]*$!!gm;

   return from_json( $_, { 'relaxed' => 1 } );
}

####################################################################################################

our $CONFIG;

# Supports individual files or all files in a given directory (in which case the 'process' sub can expect an array of data)
my $CONFIG_FILES = {
   'users.json' => {
      'process' => sub {
         my $c = shift;

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
      'process' => sub {
         my $ROLES = shift;

         if($ROLES) {
            # Set up convenience shortcut
            User::ConfigureRoles($ROLES);
            User::ConfigureUsers();
         }
      },
      'parse' => \&parse_json
   },
   'config.json' => {
      'process' => sub {
         my $c = shift;

         # Set up convenience shortcut
         $CONFIG = $c;

         # Assign defaults
         $CONFIG->{'docker'}{'socket'} //= '/var/run/docker.sock';
         $CONFIG->{'docker'}{'sizes'} //= 0;
         $CONFIG->{'ide'}{'path'} //= '/opt/dockside';
         $CONFIG->{'ssh'}{'path'} //= "$CONFIG->{'ide'}{'path'}/host";
      },
      'parse' => \&parse_json
   },
   'passwd' => {
      'process' => sub {
         my $c = shift;

         # Set up convenience shortcut
         User::ConfigurePasswd($c);
      },
      'parse' => sub {
         return {
            map {
               s/^\s*|\s*$//;    # Trim whitespace
               ( split( ':', $_ ) )    # return <username> => <encrypted password>
              }
              grep {
               $_ !~ '^(:?#.*)?$'                  # Trim empty lines and comments
              } split( "\n", $_[0] )
         };
      }
   },
   'profiles/*.json' => {
      'process' => sub {
         my $c = shift;

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
      'path' => sub { return $CONFIG->{'reservationsPath'}; },
      'load' => \&cacheReadWrite,
      'parse' => \&Reservation::Load::load,
      'process' => sub {
         Reservation->update_container_info();
      }
   },
   'containers.json' => {
      'path' => sub { return $CONFIG->{'containersPath'}; },
      'load' => \&cacheReadWrite,
      'parse' => sub { return decode_json($_[0]); },
      'process' => sub {
         Containers::Configure($_[0]);
         Reservation->update_container_info();
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

sub load {
   my @configFiles = @_; # Optional: list of config files to check for changes and load.

   if(!@configFiles) {
      # Ensure we load config.json first; other modules might depend upon it.
      @configFiles = ('config.json', grep { $_ ne 'config.json' } sort keys %$CONFIG_FILES);
   }

   # FIXME: Throttle checking config files to 1/5s
   foreach my $p ( @configFiles ) {

      my $isGlob = ($p =~ m!\*!);

      # Prepare a list of files to hopefully read in
      my $path = $CONFIG_FILES->{$p}{'path'} ? &{ $CONFIG_FILES->{$p}{'path'} } : "$CONFIG_PATH/$p";

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
            flog( "get_updated_config: error parsing '$candidateFile': file can't be read" );
         }
      }

      # Work out the most recent last-modified time for all files in the current list
      my $lastModified;
      foreach my $file (@files) {
         my $lm = (stat($file))[9];
         $lastModified = $lm if $lm > $lastModified;
      }

      # Skip further processing if files haven't been modified since the last time we processed them
      next if $lastModified == $CONFIG_FILES->{$p}{'lastModified'};

      flog( "get_updated_config: $p, previously modified at " . ($CONFIG_FILES->{$p}{'lastModified'} // 0) . ", now modified at $lastModified");

      # Get data from files
      my $data;
      try {
         foreach my $file (@files) {
            my ($filename) = $file =~ m!([^/\.]+)(?:\.[^\./]+)?$!;

            try {
               flog( "get_updated_config: loading '$file'");
               $data->{$filename} = 
                  &{ $CONFIG_FILES->{$p}{'parse'} }( 
                     &{ $CONFIG_FILES->{$p}{'load'} || \&get_config }($file)
                  );
            }
            catch {
               chomp;
               flog("get_updated_config: error parsing '$file': '$_'");
            };
         }

         $data = ($isGlob ? $data : (scalar(@files) == 1 ? $data->{[keys %$data]->[0]} : undef));

         # As we're inside an eval, if parsing fails an exception will be thrown and we won't update the lastModified time.
         $CONFIG_FILES->{$p}{'lastModified'} = $lastModified;

         # Run post-parse compilation step (when required).
         if( $CONFIG_FILES->{$p}{'process'} ) {
            &{ $CONFIG_FILES->{$p}{'process'} }( $data );
         }

         return 1;
      }
      catch {
         chomp;
         flog("get_updated_config: error parsing '$p': '$_'");
      };
   }
}

1;
