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
use Util qw(flog cacheReadWrite apply_args_to_record lockFile);
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

# Acquire the single advisory lock guarding all profile structural mutations
# (create/update/rename/remove).  Profiles are one-file-per-profile, so a per-file
# cacheReadWrite lock cannot serialise create's existence check or a rename across
# two files; this coarse lock makes each whole check-then-act atomic against the
# others.  Held via a lexical at each call site, so it releases when that lexical
# leaves scope (normal return or exception).  Profile mutations are rare,
# admin-only operations, so the serialisation cost is negligible.  The ".lock"
# name never matches the profiles/*.json glob, so it is invisible to listing.
sub _mutation_lock () {
   return lockFile("$PROFILES_DIR/.lock");
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

   my $lock = _mutation_lock();   # serialise the whole check-then-act below

   _validate_profile_name($name);

   die Exception->new( 'msg' => "Profile '$name' already exists" )
      if -f _profile_file($name);

   # When the admin UI posts the whole profile body as a JSON blob under '_json',
   # that blob is the authoritative record (full replace).  Otherwise start from
   # minimal defaults and overlay the supplied args (--from-json sends real fields;
   # --set / --active overlay only a few).  parse_body_args may have already decoded
   # '_json' to a hashref (form-encoded path) or left it a string (JSON body).
   my $record;
   if ( defined $args->{'_json'} ) {
      $record = ref $args->{'_json'} eq 'HASH'
         ? $args->{'_json'}
         : eval { Data::parse_json( $args->{'_json'} ) };
      die Exception->new( 'msg' => "Invalid profile data: '_json' must be a JSON object" )
         unless ref $record eq 'HASH';
      $record->{'version'} //= Profile::CURRENT_VERSION();
   }
   else {
      $record = {
         'version'  => Profile::CURRENT_VERSION(),
         'active'   => JSON::false,
         'images'   => [],
         'networks' => [],
      };
   }

   # 'id' is the filename key and '_json' the encoding vehicle; neither is stored
   # in the record body.  (The UI's _json round-trips an injected 'id'.)
   apply_args_to_record( $record, $args, qw(id _json) );
   delete $record->{'id'};

   # Default the display name to the profile id when not supplied.
   $record->{'name'} //= $name;

   # Coerce 'active' to a JSON boolean so it round-trips correctly through
   # JSON serialisation regardless of how the caller encoded it.
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

# Update an existing profile.  When the admin UI posts the whole body under
# '_json', that decoded blob fully replaces the record (so field deletions take
# effect) and remaining args overlay it.  Otherwise the existing on-disk record
# is the base and supplied args overlay it (--set / --active change only those
# fields; --from-json sends real fields).
# The update runs inside a cacheReadWrite lock so that no concurrent write can
# interleave between the read and the write.
sub updateProfile ($self, $name, $args) {
   die Exception->new( 'msg' => "You need the 'manageProfiles' permission" )
      unless $self->has_permission('manageProfiles');

   my $lock = _mutation_lock();   # serialise against concurrent rename/remove of $name

   die Exception->new( 'msg' => "Profile '$name' not found" )
      unless -f _profile_file($name);

   my $record;
   cacheReadWrite( _profile_file($name), sub ($oldData) {
      # '_json' (the admin UI's full-body blob) replaces the on-disk record so
      # field deletions take effect; otherwise the on-disk record is the base.
      # parse_body_args may deliver '_json' pre-decoded (hashref) or as a string.
      if ( defined $args->{'_json'} ) {
         $record = ref $args->{'_json'} eq 'HASH'
            ? $args->{'_json'}
            : eval { Data::parse_json( $args->{'_json'} ) };
         die Exception->new( 'msg' => "Invalid profile data: '_json' must be a JSON object" )
            unless ref $record eq 'HASH';
         $record->{'version'} //= Profile::CURRENT_VERSION();
      }
      else {
         $record = Data::parse_json($oldData);
      }

      # 'id' is the filename key and '_json' the encoding vehicle; neither is
      # stored in the record body.
      apply_args_to_record( $record, $args, qw(id _json) );
      delete $record->{'id'};

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

   my $lock = _mutation_lock();   # serialise the not-found check + unlink

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

   my $lock = _mutation_lock();   # serialise both existence checks + the rename

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
