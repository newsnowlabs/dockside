# Sub-package providing profile management (CRUD + rename) to User::.
# Each profile is stored as a separate JSON file under $PROFILES_DIR (imported
# from Data.pm), rather than in a single aggregate file like users/roles.
# $Profile::PROFILES holds an in-memory cache of active, valid profiles only;
# this module always reads from disk so that inactive and error-state profiles
# are visible to admin CRUD operations.
package Profile::Manage;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw(
   listProfiles getProfile createProfile updateProfile removeProfile renameProfile
);

use JSON;
use Storable qw(dclone);
use Data qw(invalidate_profile_cache $PROFILES_DIR);
use Profile;
use Util qw(flog cacheReadWrite apply_args_to_record);
use Exception;

# Profile names that collide with route action words.  A profile named 'update'
# would make GET /profiles/update ambiguous (detail view vs action endpoint).
my %RESERVED_NAMES = map { $_ => 1 } qw(new create update remove rename);

################################################################################
# PRIVATE HELPERS

# Returns the filesystem path for a profile by name.
sub _profile_file ($name) {
   return "$PROFILES_DIR/$name.json";
}

# Validate a proposed profile name.  Dies with a user-visible message if:
#   - $name is undef, empty, or contains disallowed characters
#   - $name collides with a route action word (see %RESERVED_NAMES)
sub _validate_profile_name ($name) {
   die Exception->new( 'msg' => "Invalid profile name: use only letters, digits, dots, hyphens, underscores; must start with a letter or digit" )
      unless defined $name && $name =~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
   die Exception->new( 'msg' => "Profile name '$name' is reserved" )
      if $RESERVED_NAMES{$name};
}

# Read and parse a profile's JSON file directly from disk, bypassing the
# $Profile::PROFILES in-memory cache.  This makes inactive profiles (active:false)
# and error-state profiles visible to admin operations, whereas the cache only
# holds profiles that are active and passed validation at load time.
# Injects 'id' (the filename stem) into the returned hashref.
# Dies with a user-visible message if the file does not exist.
sub _read_raw ($name) {
   my $file = _profile_file($name);
   die Exception->new( 'msg' => "Profile '$name' not found" )
      unless -f $file;
   my $text = cacheReadWrite($file);
   my $data = Data::parse_json($text);
   $data->{'id'} = $name;
   return $data;
}

# Validate a proposed profile record against the Profile schema.
# Uses a deep-cloned, temporarily blessed copy so the live record is not
# modified.  versionUpgrade() migrates older schema versions in-place on the
# clone before validation.
#
# validate() semantics:
#   undef  — profile is inactive (active:false); validation is skipped.
#   1      — profile is active and structurally valid.
#   0      — profile is active and invalid; errorsArray() contains details.
#
# Only the '0' case (active + invalid) causes a die; inactive profiles are
# always accepted so they can be saved and fixed later.
sub _validate_record ($record) {
   my $temp = bless dclone($record), 'Profile';
   $temp->versionUpgrade();

   my $result = $temp->validate();

   if ( defined $result && $result == 0 ) {
      die Exception->new(
         'msg' => "Profile validation failed: " . join( "; ", $temp->errorsArray )
      );
   }
}

################################################################################
# PROFILE CRUD

# List all profiles by reading every *.json file in $PROFILES_DIR directly.
# Files that fail to parse are logged and skipped rather than causing the whole
# list to fail — an admin needs to be able to see and fix broken profiles.
# Returns an arrayref sorted by filename (alphabetically by profile id).
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

# Create a new profile.  Two creation paths are supported:
#   _json present — the full profile body is supplied as a JSON string (used by
#                   the admin UI which posts the whole profile as a single blob).
#   _json absent  — a minimal skeleton is constructed and extra $args fields
#                   (if any) are overlaid via apply_args_to_record.
#
# In both cases, 'id' (the filename stem) and '_json' (the encoding vehicle)
# are excluded from apply_args_to_record to prevent them being written into
# the record body.
#
# 'active' is explicitly coerced to a JSON boolean after all field writes
# because incoming values can be Perl strings ('1'/'0') from form-encoded
# bodies, and the Profile validator requires a boolean type.
#
# invalidate_profile_cache() + Data::load ensure the runtime cache reflects the
# new profile immediately without waiting for the next scheduled reload.
sub createProfile ($self, $name, $args) {
   die Exception->new( 'msg' => "You need the 'manageProfiles' permission" )
      unless $self->has_permission('manageProfiles');

   _validate_profile_name($name);

   die Exception->new( 'msg' => "Profile '$name' already exists" )
      if -f _profile_file($name);

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

   # Overlay any additional scalar args onto the record.  'id' is the filename
   # key (not stored in the body) and '_json' is already decoded above; both
   # are excluded.
   apply_args_to_record( $record, $args, qw(id _json) );

   # Default the display name to the profile id when not supplied.
   $record->{'name'} //= $name;

   # Coerce 'active' to a proper JSON boolean (the Profile validator requires
   # this type; form-encoded input arrives as string '1' or '0').
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

# Update an existing profile.  Two update modes:
#   _json present — the full new body is decoded from _json (full replacement),
#                   then any additional scalar args are overlaid.
#   _json absent  — the existing on-disk body is used as the base and only the
#                   explicitly provided $args fields are updated (partial update).
# The update runs inside a cacheReadWrite lock so that no concurrent write can
# interleave between the read and the write.
sub updateProfile ($self, $name, $args) {
   die Exception->new( 'msg' => "You need the 'manageProfiles' permission" )
      unless $self->has_permission('manageProfiles');

   die Exception->new( 'msg' => "Profile '$name' not found" )
      unless -f _profile_file($name);

   my $record;
   cacheReadWrite( _profile_file($name), sub ($oldData) {
      my $base = Data::parse_json($oldData);

      if ( defined $args->{'_json'} && length $args->{'_json'} ) {
         # Full replacement: decode _json as the new body.
         $record = Data::parse_json( $args->{'_json'} );
      }
      else {
         # Partial update: start from the existing on-disk record.
         $record = $base;
      }

      apply_args_to_record( $record, $args, qw(id _json) );

      # Coerce 'active' to a JSON boolean (see createProfile for rationale).
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

# Delete the profile's JSON file from disk.  No cascade check is performed:
# containers that were launched with this profile retain their existing state;
# only new launches are affected (the profile will no longer be available).
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

# Rename a profile by renaming its JSON file on disk.  The rename is atomic at
# the filesystem level (POSIX rename(2)).  The profile body is not modified;
# only the filename (and therefore the profile id) changes.
# Returns the new id so the caller can update any in-memory references.
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
