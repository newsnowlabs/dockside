# Sub-package providing utility function to Reservation::.
package Reservation::Mutate;

use strict;

use Exporter qw(import);
our @EXPORT_OK = qw(update load_clean_map);

use Util qw(flog wlog YYYYMMDDHHMMSS cacheReadWrite cloneHash);
use Exception;
use Data qw($CONFIG);
use JSON;

# mutate:
#
# Reloads, and optionally updates, the reservation db atomically:
# - If called without arguments, simply reloads the reservation db.
# - If called with an $update subref, after reloading the reservation db, the update sub will be called
#   (with the internal map data structure as argument) to update the internal reservation db data structure(s).
#   - If the update sub returns true, the reservation db will be truncated and rewritten before the file is closed and exclusive lock released, and we return true.
#   - If the update sub returns false, the reservation db will not be rewritten, and we return 0.
# - On any error, return undef.
#
# In both cases, an exclusive lock is taken to ensure the reservation db is not in process of being written by another process,
# while it is read or re-written here.
#
# TODO:
# - Cache the last modified time on $HID_PATH. If it hasn't changed, then don't bother reparsing the file unless $update is provided.
sub mutate {
   my $mutateFn = shift;

   return cacheReadWrite(
      $CONFIG->{'reservationsPath'}, 
      $mutateFn ? (
         sub {
            my $oldData = shift;
            my $mutateFn = shift;

            my $by_id = {};
            my $by_name = {};
            foreach my $l ( split( /(?:\r?\n)+/, $oldData ) ) {
               my $e = decode_json($l);
               $by_name->{ $e->{'name'} } = $e;
               $by_id->{ $e->{'id'} }     = $e;
            }

            if( $mutateFn && &$mutateFn($by_id, $by_name) ) {
               return join('', map { JSON::XS->new->utf8->convert_blessed->encode($_) . "\n"; } values %$by_id);
            }
            else {
               return $oldData;
            }
         }, $mutateFn
      ) : ()
   );
}

# PUBLIC METHODS
# --------------

# update:
#
# Atomically update the reservation database for $self:
# $e provides a hashref of properties to update.
sub update {
   my $self = shift;
   my $e = shift;

   return mutate(
      sub {
         my $by_id = shift;
         my $by_name = shift;

         my $id = $self->id;

         # Don't allow storage of a reservation reservation db entry, with a host name already in use
         # by another reservation reservation db entry.
         if(
               defined($e->{'name'}) && 
               defined($by_name->{$e->{'name'}}) &&
               $by_name->{$e->{'name'}}{'id'} ne $id
            ) {
               die Exception->new( 'dbg' => "Cannot save/update reservation id $id with hostname '$e->{'name'}', because this hostname it is already in use by reservation id $by_name->{$e->{'name'}}{'id'}", 'msg' => "Error updating reservation: hostname '$e->{'name'}' already in use" );
         }

         # Remove BY_HOST index entry for old 'name' key on this id, in case 'name' key value has changed.
         # delete $by_name->{ $by_id->{$id}{'name'} };

         # Copy across all values that are different.
         cloneHash($e, $by_id->{$id});

         # Assign the new object back to the BY_HOST index.
         $by_name->{ $e->{'name'} } = $by_id->{$id};

         return 1;
      }
   );
}

# load_clean_map:
#
# Takes as input, a full complement of container IDs for active (running or stopped) containers.
# Loops through the reservation db contents, deleting any entries that do not tally with active containers.
sub load_clean_map {
   my $self = shift;
   my @containerIds = @_;

   my %containerIds;

   # Create a unique list from map containerIds
   @containerIds{@containerIds} = (1) x (@containerIds);

   my $now = YYYYMMDDHHMMSS(time);
   my $expireTime = YYYYMMDDHHMMSS(time - 30);

   return mutate(
      sub {
         my $by_id = shift;
         my $by_name = shift;

         my $Updates = 0;

         keys %$by_id;
         # Loop through reservation db entries
         while( my ( $id, $reservation ) = each %$by_id ) {

            # If the reservation already has a containerId:
            if( my $containerId = $reservation->{'containerId'} ) {

               # flog("load_clean_map: resId=$id; containerId=$containerId");

               # If its containerId is found (in the provided list), delete expiryTime - which must have been previously added in error.
               if( $containerIds{$containerId} ) {
                  if( $reservation->{'expiryTime'} ) {
                     delete $reservation->{'expiryTime'};
                     $Updates++;
                  }
                  next;
               }

               # Otherwise, if containerId has not been found (in the provided list), and has no expiryTime yet:
               # - add expiryTime.
               if( !$reservation->{'expiryTime'} ) {
                  $reservation->{'expiryTime'} = $now;
                  $Updates++;
                  next;
               }
            }

            # For container reservations, and failed launch reservations:
            # - If expiryTime exists and is old enough, delete the reservation db entry.
            if( $reservation->{'expiryTime'} && $reservation->{'expiryTime'} lt $expireTime ) {
               flog("load_clean_map: deleting reservation $id");
               delete $by_name->{ $by_id->{$id}{'name'} };
               delete $by_id->{$id};
               $Updates++;
            }
         }

         # Only rewrite the reservation db if there were actual updates.
         return $Updates;
         
      }
   );
}

1;
