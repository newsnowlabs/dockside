# Sub-package providing utility function to Reservation::.
package Reservation::Mutate;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw(update load_clean_map record_hook_history increment_data_field hook_claim_if_not_running);

use Util qw(flog wlog YYYYMMDDHHMMSS cacheReadWrite cloneHash call_socket_api);
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
sub mutate ($mutateFn = undef) {
   return cacheReadWrite(
      $CONFIG->{'reservationsPath'}, 
      $mutateFn ? (
         sub ($oldData, $mutateFn) {

            my $by_id = {};
            my $by_name = {};
            foreach my $l ( split( /(?:\r?\n)+/, $oldData ) ) {
               my $e = decode_json($l);
               $by_name->{ $e->{'name'} } = $e;
               $by_id->{ $e->{'id'} }     = $e;
            }

            if( $mutateFn && $mutateFn->($by_id, $by_name) ) {
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
sub update ($self, $e) {
   return mutate(
      sub ($by_id, $by_name) {

         my $id = $self->id;

         # Don't allow storage of a reservation db entry, with a host name already in use
         # by another reservation db entry.
         if(
               defined($e->{'name'}) && 
               defined($by_name->{$e->{'name'}}) &&
               $by_name->{$e->{'name'}}{'id'} ne $id
            ) {
               die Exception->new( 'dbg' => "Cannot save/update reservation id $id with hostname '$e->{'name'}', because this hostname it is already in use by reservation id $by_name->{$e->{'name'}}{'id'}", 'msg' => "Error updating reservation: hostname '$e->{'name'}' already in use" );
         }

         # Assign empty hash, if needed.
         $by_id->{$id} //= {};

         # Remove BY_HOST index entry for old 'name' key on this id, in case 'name' key value has changed.
         delete $by_name->{ $by_id->{$id}{'name'} };

         # Copy across all values that are different.
         cloneHash($e, $by_id->{$id});

         # Assign the new object back to the BY_HOST index.
         $by_name->{ $by_id->{$id}{'name'} } = $by_id->{$id};

         return 1;
      }
   );
}

# load_clean_map:
#
# Takes as input, a full complement of container IDs for active (running or stopped) containers.
# Loops through the reservation db contents, deleting any entries that do not tally with active containers.
sub load_clean_map ($class, @containerIds) {

   my %containerIds;

   # Create a unique list from map containerIds
   @containerIds{@containerIds} = (1) x (@containerIds);

   my $now = YYYYMMDDHHMMSS(time);
   my $expireTime = YYYYMMDDHHMMSS(time - 30);

   return mutate(
      sub ($by_id, $by_name) {

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

# record_hook_history:
#
# Atomically append $entry to reservation $id's data.hooks.history array, evicting oldest-first
# down to at most $cap rows once appending would exceed it - but only rows in a terminal state
# ($_->{'exitCode'} defined), never a still-running one (item B's storage-model rule: an
# unrelated, more-frequent *other* hook name's invocations must never push a genuinely
# still-running row out from under it, so the array can transiently exceed $cap while enough
# invocations are genuinely in flight at once - expected, not a bug).
#
# Deliberately its own atomic mutator, bypassing Reservation::store()'s usual whole-record
# update() - update()'s cloneHash-based merge (Util.pm) recurses safely into nested *hashes*
# (data.hooks.status, keyed by hook name, merges key-by-key across concurrent forked children
# updating different names, each blind to the other's simultaneous write), but an *array*
# value is only ever compared by reference and replaced wholesale - two concurrent appends
# via that path would race, and the loser's row would simply be lost. This function instead
# re-reads the reservation fresh under mutate()'s own exclusive lock, appends, evicts, and
# writes back - safe under genuine concurrency, unlike a read-append-store() round trip
# through a possibly-stale in-memory copy of the whole array.
sub record_hook_history ($id, $entry, $cap) {
   return mutate(
      sub ($by_id, $by_name) {
         my $reservation = $by_id->{$id} or return 0;
         my $data = $reservation->{'data'} //= {};
         my $hooks = $data->{'hooks'} //= {};
         my $history = $hooks->{'history'} //= [];

         push(@$history, $entry);

         while( @$history > $cap ) {
            my $evictIndex;
            for my $i ( 0 .. $#$history ) {
               if( defined $history->[$i]{'exitCode'} ) {
                  $evictIndex = $i;
                  last;
               }
            }
            last unless defined $evictIndex;
            splice(@$history, $evictIndex, 1);
         }

         return 1;
      }
   );
}

# increment_data_field:
#
# Atomically increments $reservation.data.$key by 1 and returns the new value. Same rationale
# and pattern as record_hook_history just above (its own comment explains the general
# principle in full) - the read and the write both happen inside mutate()'s own exclusive lock,
# against a freshly re-read reservation, never against this process's own in-memory copy.
#
# Deliberately not just "narrow the eventual store() payload down to {data => {$key => N}}":
# narrowing what gets *sent* (see Reservation::store_fields) only protects fields a writer
# isn't trying to change, by leaving them absent from its payload entirely - it does nothing
# for a field the writer *is* trying to change, whose new value is computed by reading the
# field's own prior value first (an increment, unlike an authoritative "set to X"). Two
# increments computed from the same stale read would still silently lose one, no matter how
# narrowly the write is scoped - only recomputing from a fresh value, under the same lock as
# the write, closes that. (Today's calling code only ever attempts one increment per launch
# cycle, per stage's own idempotency guard, so this isn't defending against a currently-known
# concurrent second incrementer - it's closing the same class of gap record_hook_history
# already closes for the history array, on the same principle, so a future caller doesn't
# reopen it.)
sub increment_data_field ($id, $key) {
   my $newValue;
   mutate(
      sub ($by_id, $by_name) {
         my $reservation = $by_id->{$id} or return 0;
         my $data = $reservation->{'data'} //= {};
         $newValue = ( $data->{$key} // 0 ) + 1;
         $data->{$key} = $newValue;
         return 1;
      }
   );
   return $newValue;
}

# Atomically checks-and-claims hook/stage $name for reservation $id: if it is not genuinely
# running, marks it running (with $logPath) and returns true (the caller should proceed to
# dispatch); if it genuinely is, returns false (the caller should report busy / skip) - all
# inside one mutate() call, so two concurrent callers (different nginx workers dispatching
# run_hook_sync, or an nginx worker racing docker-event-daemon's own launch-DAG auto-dispatch
# of lifecycle:launch/lifecycle:start) can never both see "not running" and both proceed, the
# way Reservation::hook_is_running + hook_status_started could when called as two separate,
# unlocked steps (found live: 2 of 4 genuinely concurrent `dockside hook run` calls against the
# same devtainer both actually executed the hook script, confirmed against the container's own
# execution log, not just against the API's response).
#
# Deliberately not built on top of hook_is_running/hook_status_started - those remain as they
# are (a fast, unlocked, best-effort pre-check and a plain recording write respectively), still
# used on their own by callers that only ever have a single writer for the name in question
# (docker-event-daemon's own restart-recovery/on_tick self-heal, and the read-only hook_status()
# endpoint) and don't need this. This is for the two call sites where a second, concurrent
# writer for the *same* name is genuinely possible: Reservation::run_hook_sync (multiple nginx
# workers) and docker-event-daemon's own auto-dispatch of lifecycle:launch/lifecycle:start (the
# only two DAG stage names externally reachable via run_hook_sync too, when a profile's hooks
# entry sets "manual": true on them).
#
# Mirrors hook_is_running's own liveness/self-heal reasoning (same two signals, same order,
# same fallback to 'aborted' if neither is conclusive) - just performed inside the lock, on raw
# hash data, so the "is it stale" decision and the claim are one atomic step instead of two.
# The execId liveness probe is a real HTTP round-trip to dockerd, so this does hold the
# reservations-db file lock for its duration - only on the self-heal path (an existing 'running'
# entry with an unresolved liveness question), never on the common "nothing recorded yet" path,
# which returns after a single hash lookup.
#
# A self-heal here (finding a stale entry and resolving it 'done'/'failed'/'aborted' before
# claiming the slot fresh) also needs a history-array append, exactly like hook_is_running's own
# self-heal does via hook_status_completed - done as a separate, sequential record_hook_history
# call *after* this mutate() returns (nesting a second mutate() call inside this one's own
# closure would try to flock() the same file twice from this process and deadlock - mutate()'s
# lock is not reentrant).
#
# Returns the claimed entry (a hashref) if this call won and should proceed to dispatch, or
# undef if another invocation already owns $name. mutate() only ever operates on a fresh,
# separately-loaded copy of the reservation, never the caller's own in-memory object (see
# Reservation::Mutate::update's own comment) - a winning caller MUST sync this returned entry
# onto its own in-memory Reservation, exactly mirroring _hook_status_store_one's existing
# discipline, or its own subsequent hook_status_set_running_details call would merge pid/execId
# onto stale (pre-claim) in-memory state instead of this fresh entry.
sub hook_claim_if_not_running ($id, $name, $logPath, $cap) {
   my $claimedEntry;
   my $healedEntry;

   mutate(
      sub ($by_id, $by_name) {
         my $reservation = $by_id->{$id} or return 0;
         my $status = ( $reservation->{'data'}{'hooks'} //= {} )->{'status'} //= {};
         my $existing = $status->{$name};

         if ( $existing && ( $existing->{'state'} // '' ) eq 'running' ) {
            if ( !defined( $existing->{'pid'} ) && !defined( $existing->{'execId'} ) ) {
               return 0;   # newly-started elsewhere, neither signal exists yet - genuinely busy
            }
            if ( defined( $existing->{'pid'} ) && kill( 0, $existing->{'pid'} ) ) {
               return 0;   # genuinely still running
            }
            if ( defined( $existing->{'execId'} ) ) {
               my $res = call_socket_api( $CONFIG->{'docker'}{'socket'}, "/exec/$existing->{'execId'}/json", {} );
               if ( $res && $res->is_success ) {
                  my $info = decode_json( $res->body );
                  return 0 if $info->{'Running'};   # genuinely still running

                  if ( defined $info->{'ExitCode'} ) {
                     $healedEntry = { %$existing,
                        'state'    => $info->{'ExitCode'} == 0 ? 'done' : 'failed',
                        'exitCode' => $info->{'ExitCode'},
                     };
                  }
               }
            }
            $healedEntry //= { %$existing, 'state' => 'aborted' };
            $status->{$name} = $healedEntry;
            # Falls through to claim the now-free slot below.
         }

         $status->{$name} = $claimedEntry = {
            'name'      => $name,
            'state'     => 'running',
            'pid'       => undef,
            'execId'    => undef,
            'logPath'   => $logPath,
            'startTime' => YYYYMMDDHHMMSS(time),
         };
         return 1;
      }
   );

   record_hook_history( $id, { %$healedEntry }, $cap ) if $healedEntry;
   return $claimedEntry;
}

1;
