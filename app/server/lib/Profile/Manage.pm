# Sub-package providing profile management (CRUD + rename) to User::.
package Profile::Manage;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw(
   listProfiles getProfile createProfile updateProfile removeProfile renameProfile
);

use JSON;
use Storable qw(dclone);
use Data qw(invalidate_profile_cache);
use Profile;
use Util qw(flog cacheReadWrite);
use Exception;

my $CONFIG_PATH  = '/data/config';
my $PROFILES_DIR = "$CONFIG_PATH/profiles";

# Profile names that collide with route action words.
my %RESERVED_NAMES = map { $_ => 1 } qw(create update remove rename);

################################################################################
# PRIVATE HELPERS

sub _profile_file ($name) {
   return "$PROFILES_DIR/$name.json";
}

sub _validate_profile_name ($name) {
   die Exception->new( 'msg' => "Invalid profile name: use only letters, digits, dots, hyphens, underscores; must start with a letter or digit" )
      unless defined $name && $name =~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
   die Exception->new( 'msg' => "Profile name '$name' is reserved" )
      if $RESERVED_NAMES{$name};
}

# Read and parse a profile file directly from disk (bypasses the $PROFILES
# in-memory cache, so inactive profiles are visible too).
sub _read_raw ($name) {
   my $file = _profile_file($name);
   die Exception->new( 'msg' => "Profile '$name' not found" )
      unless -f $file;
   my $text = cacheReadWrite($file);
   my $data = Data::parse_json($text);
   $data->{'id'} = $name;
   return $data;
}

# Apply flat args (possibly dotted-path keys, possibly JSON-encoded values)
# into a record hashref in place.  Shallower keys are applied first so deeper
# paths can override them.  Keys in @skip are ignored.
sub _apply_args_to_record ($record, $args, @skip) {
   my %skip = map { $_ => 1 } @skip;

   for my $key ( sort { scalar( split /\./, $a ) <=> scalar( split /\./, $b ) } keys %$args ) {
      next if $skip{$key};
      next if $key eq '_unset';
      next unless defined $args->{$key};

      my $val = do {
         my $v = $args->{$key};
         if ( defined $v && length $v ) {
            my $d = eval { decode_json($v) };
            $@ ? $v : $d;
         }
         else { $v }
      };

      my @parts = split( /\./, $key );
      my $ref   = $record;
      for my $part ( @parts[ 0 .. $#parts - 1 ] ) {
         $ref->{$part} //= {};
         $ref = $ref->{$part};
      }
      $ref->{ $parts[-1] } = $val;
   }

   # _unset: JSON array of dotted-path keys to delete from the record
   if ( defined $args->{'_unset'} ) {
      my $keys = eval { decode_json( $args->{'_unset'} ) } // [];
      for my $key (@$keys) {
         my @parts = split( /\./, $key );
         my $ref   = $record;
         for my $part ( @parts[ 0 .. $#parts - 1 ] ) {
            last unless ref $ref eq 'HASH' && exists $ref->{$part};
            $ref = $ref->{$part};
         }
         delete $ref->{ $parts[-1] } if ref $ref eq 'HASH';
      }
   }
}

# Validate a profile record by instantiating a temporary Profile object and
# running the structural validator.  Dies with a descriptive error if the
# profile is active and fails validation.
sub _validate_record ($record) {
   my $temp = bless dclone($record), 'Profile';
   $temp->versionUpgrade();

   my $result = $temp->validate();

   # validate() returns: undef  = inactive (skip validation, no errors)
   #                     1      = active and valid
   #                     0      = active and invalid (errors populated)
   if ( defined $result && $result == 0 ) {
      die Exception->new(
         'msg' => "Profile validation failed: " . join( "; ", $temp->errorsArray )
      );
   }
}

################################################################################
# PROFILE CRUD

sub listProfiles ($self, $args = {}) {
   die Exception->new( 'msg' => "You need the 'manageProfiles' permission" )
      unless $self->has_permission('manageProfiles');

   my @profiles;
   for my $file ( sort glob("$PROFILES_DIR/*.json") ) {
      my ($name) = $file =~ m{([^/]+)\.json$};
      next unless defined $name;

      my $data = eval {
         my $text = cacheReadWrite($file);
         my $d = Data::parse_json($text);
         $d->{'id'} = $name;
         $d;
      };
      if ($@) {
         flog("Profile::Manage::listProfiles: error reading '$file': $@");
         next;
      }
      push @profiles, $data;
   }

   return \@profiles;
}

sub getProfile ($self, $name, $args = {}) {
   die Exception->new( 'msg' => "You need the 'manageProfiles' permission" )
      unless $self->has_permission('manageProfiles');

   return _read_raw($name);
}

sub createProfile ($self, $name, $args) {
   die Exception->new( 'msg' => "You need the 'manageProfiles' permission" )
      unless $self->has_permission('manageProfiles');

   _validate_profile_name($name);

   die Exception->new( 'msg' => "Profile '$name' already exists" )
      if -f _profile_file($name);

   # Build the base record.
   my $record;
   if ( defined $args->{'_json'} && length $args->{'_json'} ) {
      $record = Data::parse_json( $args->{'_json'} );
   }
   else {
      $record = {
         'name'    => $name,
         'version' => Profile::CURRENT_VERSION(),
         'active'  => JSON::false,
         'images'  => [],
         'networks' => [],
      };
   }

   _apply_args_to_record( $record, $args, qw(id _json) );

   # Default the JSON 'name' display field to the profile id if not provided.
   $record->{'name'} //= $name;

   # Coerce 'active' to a proper JSON boolean (validator requires boolean type).
   if ( exists $record->{'active'} ) {
      $record->{'active'} = $record->{'active'} ? JSON::true : JSON::false;
   }

   _validate_record($record);

   cacheReadWrite( _profile_file($name), sub ($old) {
      return JSON->new->utf8->pretty->canonical->encode($record);
   });

   invalidate_profile_cache();
   Data::load('profiles/*.json');

   return { 'id' => $name, %$record };
}

sub updateProfile ($self, $name, $args) {
   die Exception->new( 'msg' => "You need the 'manageProfiles' permission" )
      unless $self->has_permission('manageProfiles');

   die Exception->new( 'msg' => "Profile '$name' not found" )
      unless -f _profile_file($name);

   my $record;
   cacheReadWrite( _profile_file($name), sub ($oldData) {
      my $base = Data::parse_json($oldData);

      if ( defined $args->{'_json'} && length $args->{'_json'} ) {
         # Full replacement from supplied JSON, then apply any extra args.
         $record = Data::parse_json( $args->{'_json'} );
      }
      else {
         $record = $base;
      }

      _apply_args_to_record( $record, $args, qw(id _json) );

      # Coerce 'active' to a proper JSON boolean (validator requires boolean type).
      if ( exists $record->{'active'} ) {
         $record->{'active'} = $record->{'active'} ? JSON::true : JSON::false;
      }

      _validate_record($record);

      return JSON->new->utf8->pretty->canonical->encode($record);
   });

   invalidate_profile_cache();
   Data::load('profiles/*.json');

   return { 'id' => $name, %$record };
}

sub removeProfile ($self, $name, $args = {}) {
   die Exception->new( 'msg' => "You need the 'manageProfiles' permission" )
      unless $self->has_permission('manageProfiles');

   die Exception->new( 'msg' => "Profile '$name' not found" )
      unless -f _profile_file($name);

   unlink( _profile_file($name) )
      or die Exception->new( 'msg' => "Failed to remove profile '$name': $!" );

   invalidate_profile_cache();
   Data::load('profiles/*.json');

   return { 'id' => $name };
}

sub renameProfile ($self, $name, $new_name, $args = {}) {
   die Exception->new( 'msg' => "You need the 'manageProfiles' permission" )
      unless $self->has_permission('manageProfiles');

   die Exception->new( 'msg' => "Profile '$name' not found" )
      unless -f _profile_file($name);

   _validate_profile_name($new_name);

   die Exception->new( 'msg' => "Profile '$new_name' already exists" )
      if -f _profile_file($new_name);

   rename( _profile_file($name), _profile_file($new_name) )
      or die Exception->new( 'msg' => "Failed to rename profile '$name' to '$new_name': $!" );

   invalidate_profile_cache();
   Data::load('profiles/*.json');

   return { 'id' => $new_name, 'old_id' => $name };
}

1;
