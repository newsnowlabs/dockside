# Sub-package providing utility function to Reservation::.
package Reservation::Mutate;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = qw(update load_clean_map record_stop_request release_stop_request resolve_hook_status hook_claim_if_not_running launch_reset_stages_if_idle add_router remove_router replace_router);

use Util qw(flog wlog YYYYMMDDHHMMSS cacheReadWrite cloneHash call_socket_api_sync tryLockFile);
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
         # (A brand-new id has no prior 'name' yet - nothing to remove.)
         delete $by_name->{ $by_id->{$id}{'name'} } if defined $by_id->{$id}{'name'};

         # Copy across all values that are different.
         cloneHash($e, $by_id->{$id});

         # Assign the new object back to the BY_HOST index.
         $by_name->{ $by_id->{$id}{'name'} } = $by_id->{$id};

         return 1;
      }
   );
}

# record_stop_request:
#
# Records $requestedAt, the time a stop request for reservation $id was sent to Docker, and
# $requestId, that request's own id, as data.stopRequestedAt and data.stopRequestId, unless a
# later time is on record. Stop requests for one container may be sent from any worker and their
# records land in any order, so the later time always stands; an equal time, two requests within
# one millisecond, is taken over by the request recording it, the two having no order. Returns
# whether it was recorded.
sub record_stop_request ($id, $requestedAt, $requestId) {
   my $recorded = 0;
   mutate(
      sub ($by_id, $by_name) {
         my $reservation = $by_id->{$id} or return 0;
         my $known = $reservation->{'data'}{'stopRequestedAt'};
         return 0 if defined($known) && $known > $requestedAt;
         $reservation->{'data'}{'stopRequestedAt'} = $requestedAt;
         $reservation->{'data'}{'stopRequestId'}   = $requestId;
         $recorded = 1;
         return 1;
      }
   );
   return $recorded;
}

# release_stop_request:
#
# Writes data.stopRequestedAt as 0 for reservation $id, marking the stop request with id
# $requestId as one whose Docker call ended without success, but only while the record still
# holds that id: a request recorded since is left for its own completion to settle. Returns
# whether it was released.
sub release_stop_request ($id, $requestId) {
   my $released = 0;
   mutate(
      sub ($by_id, $by_name) {
         my $reservation = $by_id->{$id} or return 0;
         my $known = $reservation->{'data'}{'stopRequestId'};
         return 0 unless defined($known) && $known eq $requestId;
         $reservation->{'data'}{'stopRequestedAt'} = 0;
         $released = 1;
         return 1;
      }
   );
   return $released;
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

   # Keep deletion guards through the database write, not just through the callback.
   # Acquisition is non-blocking: a create driver may hold its reservation lock while
   # waiting for this database lock, so waiting here would deadlock.
   my @deletionLocks;

   return mutate(
      sub ($by_id, $by_name) {

         my $Updates = 0;

         keys %$by_id;
         # Loop through reservation db entries
         while( my ( $id, $reservation ) = each %$by_id ) {

            # A reservation whose create chain is still recoverable - a non-terminal stage that
            # has not been recorded as failed - is neither expired nor deleted here. Its container
            # may exist: a create that could not establish its own outcome deliberately keeps this
            # stage so that a later reconciliation pass can find out, and expiring the record
            # would delete the only thing that remembers to ask. This matters most at 'starting',
            # where a containerId is already recorded, so the branch below would otherwise expire
            # the record on the strength of a Docker snapshot that simply has not caught up.
            # Reconciliation is what ends this state: it either completes the chain, or records a
            # definitive failure, after which the ordinary rules below apply.
            my $createStatus = $reservation->{'createStatus'};
            if ( ref($createStatus) eq 'HASH' && !$createStatus->{'failed'}
                 && ( $createStatus->{'stage'} // '' ) =~ /^(?:pulling|creating|starting)$/ ) {
               # An expiry recorded before the record reached this state would otherwise outlive it.
               if ( $reservation->{'expiryTime'} ) {
                  delete $reservation->{'expiryTime'};
                  $Updates++;
               }
               next;
            }

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
               my $lock = tryLockFile("$CONFIG->{'tmpPath'}/r-$id.lock");
               next unless $lock;   # an outstanding create can still update this record
               push @deletionLocks, $lock;
               flog("load_clean_map: deleting reservation $id");
               delete $by_name->{ $by_id->{$id}{'name'} };
               delete $by_id->{$id};
               $Updates++;

               # Retain the inode until app-server's pre-fork orphan cleanup. Another
               # process may already have opened this path before trying its flock;
               # unlinking here would allow it and a later opener to own different inodes.
            }
         }

         # Only rewrite the reservation db if there were actual updates.
         return $Updates;

      }
   );
}

# _append_hook_history:
#
# Records $entry, a hooks.status entry that has just been made terminal, in $data's
# hooks.history array. Called only from inside a mutate() closure, on the locked, freshly re-read
# $data whose status entry the caller has just resolved, so the row and the terminal entry are
# one write: a crash or a write failure leaves either both or neither, never a resolved entry
# with no row for it or a row for an entry still reading 'running'. Nothing outside a mutate()
# closure appends to this array - Reservation::store()'s cloneHash-based merge (Util.pm)
# compares an array by reference and replaces it wholesale, so two writers appending through
# it would race and the loser's row would be lost.
#
# The array holds one row per invocation. A row already present for $entry's invocationId is
# replaced where it stands rather than joined by a second: two writers can resolve the same
# invocation - a reader that settled it from Docker, and the live completion arriving a moment
# later - and the row ends up carrying whichever wrote last, which is also what the status entry
# carries. A row with no invocationId is only ever appended.
#
# Evicts oldest-first down to at most $cap rows once appending would exceed it - but never a
# row still recording a running invocation (item B's storage-model rule: an unrelated,
# more-frequent *other* hook name's invocations must never push a genuinely still-running row
# out from under it, so the array can transiently exceed $cap while enough invocations are
# genuinely in flight at once - expected, not a bug).
#
# Eligibility is decided on 'state', which is what that rule is actually about, and not on
# whether a row carries an exitCode: a row can be perfectly terminal and still have none, and
# several routinely do - 'skipped' (every inapplicable launch:-DAG stage, recorded on every
# container start), 'aborted' (a dispatch that never produced an exit code at all) and
# 'timedOut'. Making those ineligible would leave the array unable to shrink whenever they
# outnumber the rows that do carry an exitCode, which for an ordinary launch cycle they always
# do, and $cap would then bound nothing.
sub _append_hook_history ($data, $entry, $cap) {
   my $history = ( $data->{'hooks'} //= {} )->{'history'} //= [];

   my $invocationId = $entry->{'invocationId'};
   if ( defined($invocationId) && length($invocationId) ) {
      for my $i ( 0 .. $#$history ) {
         next unless ( $history->[$i]{'invocationId'} // '' ) eq $invocationId;
         $history->[$i] = $entry;
         return;
      }
   }

   push(@$history, $entry);

   while( @$history > $cap ) {
      my $evictIndex;
      for my $i ( 0 .. $#$history ) {
         if( ( $history->[$i]{'state'} // '' ) ne 'running' ) {
            $evictIndex = $i;
            last;
         }
      }
      last unless defined $evictIndex;
      splice(@$history, $evictIndex, 1);
   }

   return;
}

################################################################################
# ROUTER MUTATION (add / remove / replace)
#
# docs/adr/0008-router-mutation.md - these run the whole read-validate-mutate-write cycle inside
# mutate()'s own flock, against the freshly-reread on-disk record, not whatever the caller's
# in-memory Reservation object last saw - closing the same class of lost-update race
# store_fields()'s own comment warns about for a blind whole-array overwrite (cloneHash only
# merges HASH-vs-HASH pairs; 'routers' is an array, a pure leaf-overwrite). Called only via
# Reservation.pm's own add_router/remove_router/replace_router methods (never directly), which
# also keep this process's in-memory copy in sync afterward - see those methods' own comments.
# Permission/profile-gate checks happen in User.pm before any of these are ever called; nothing
# here re-checks them - only the array mutation itself, plus the one hard, non-bypassable
# ide/ssh removal block, needs the lock's protection. This module also makes no *access-level
# policy* decision of its own: add_router/replace_router take the initial meta.access value as an
# already-resolved $accessLevel argument (User.pm decides what that should be - its own
# owner/developer default, or an explicit caller override) and only check it's legal under the
# router's final auth list - see _check_router_access_level below.

# Confirms $accessLevel is actually legal under $auth (the router's final, default-wide or
# caller-narrowed, auth list) and dies with a clear Exception if not. This module makes no policy
# decision about *what* the level should be - that's resolved entirely by User.pm (its own
# owner/developer default, or an explicit caller override - docs/adr/0008-router-mutation.md) and
# handed down as $accessLevel already-chosen; this is a pure data-integrity check, the same kind
# add_router/replace_router already do for shape/collision problems.
sub _check_router_access_level ($accessLevel, $auth) {
   die Exception->new(
      'msg'    => "access level '$accessLevel' is not among this router's allowed access levels: " . join(', ', @$auth),
      'status' => 400
   ) unless grep { $_ eq $accessLevel } @$auth;
}

# Adds a router to reservation $id. Validates/normalises $routerDef via
# Reservation::normalise_router_def against the fresh on-disk router list (dies with an Exception
# on any collision or shape problem), then sets meta.access[name] to $accessLevel - already
# resolved by User.pm, only checked here for legality against the router's final auth list (see
# _check_router_access_level above) - in the same transaction. That's needed regardless of who
# resolves the value: without it, cloneWithConstraints (Reservation.pm's own client-sanitising
# clone) silently drops the new router from every client payload, since (unlike the live-routing
# default in Reservation::routers()) it has no fallback for a missing meta.access entry. Rejects
# outright in gatewayMode (deprecated, not worth this feature's complexity budget there) before
# ever taking the lock, since that's a static, non-racy config fact. Returns
# ($normalised, $accessLevel) - Reservation.pm's own add_router needs both to keep its in-memory
# copy in sync (the second is just $accessLevel echoed back, kept for shape-parity with
# replace_router below, whose second return value can genuinely differ from what was passed in).
sub add_router ($id, $routerDef, $accessLevel) {
   die Exception->new(
      'msg'    => "adding a router is not supported while this Dockside instance runs in gatewayMode",
      'status' => 400
   ) if $CONFIG->{'gatewayMode'};

   my $normalised;
   mutate(
      sub ($by_id, $by_name) {
         my $reservation = $by_id->{$id}
            or die Exception->new( 'msg' => "Reservation '$id' not found", 'status' => 400 );
         my $routers = $reservation->{'profileObject'}{'routers'} //= [];
         $normalised = Reservation::normalise_router_def( $routerDef, $routers );
         _check_router_access_level( $accessLevel, $normalised->{'auth'} );
         push( @$routers, $normalised );
         $reservation->{'meta'}{'access'}{ $normalised->{'name'} } = $accessLevel;
         return 1;
      }
   );
   return ( $normalised, $accessLevel );
}

# Removes router $name from reservation $id. Dies if $name doesn't exist, or is type ide/ssh -
# the one hard, non-bypassable rule left; every other router (admin-authored or type=user alike)
# is removable once User.pm's own permission + can_on(develop) gate passed.
# Also deletes the now-orphaned meta.access[$name] entry, so a later router reusing this name
# starts from add_router's own fresh default rather than inheriting stale access.
sub remove_router ($id, $name) {
   mutate(
      sub ($by_id, $by_name) {
         my $reservation = $by_id->{$id}
            or die Exception->new( 'msg' => "Reservation '$id' not found", 'status' => 400 );
         my $routers = $reservation->{'profileObject'}{'routers'} // [];
         my ($target) = grep { $_->{'name'} eq $name } @$routers;
         die Exception->new( 'msg' => "router '$name' not found", 'status' => 400 ) unless $target;
         die Exception->new(
            'msg'    => "router '$name' has type '" . ( $target->{'type'} // '' ) . "' and can never be removed",
            'status' => 400
         ) if ( $target->{'type'} // '' ) =~ /^(?:ide|ssh)$/;

         $reservation->{'profileObject'}{'routers'} = [ grep { $_->{'name'} ne $name } @$routers ];
         delete $reservation->{'meta'}{'access'}{$name};
         return 1;
      }
   );
   return 1;
}

# Atomically replaces router $name with $routerDef - same-name remove+add under one lock, so a
# rename-in-place never has a window where the router is simply gone. The resulting
# meta.access[$name] is resolved in this order: $explicitAccessLevel, if defined, always wins
# (the caller asked for it by name, so it's checked for legality and used, full stop - it must
# never be silently overridden by the router's own pre-existing access level); otherwise the old
# meta.access[$name] is carried forward, but only when $routerDef's (possibly caller-supplied)
# name is unchanged *and* that carried value is still legal under the new (possibly
# caller-narrowed) auth list - e.g. replacing a 'public' router with one whose auth has been
# narrowed to ['owner'] must not silently keep 'public' just because the name matched; otherwise
# $defaultAccessLevel is used. Both $explicitAccessLevel and $defaultAccessLevel are resolved by
# User.pm exactly as add_router's own $accessLevel is (owner/developer default, or the caller's
# explicit override) - this function only picks between them and the carried value, it decides
# none of the three itself. Returns ($normalised, $accessLevel) - the caller (Reservation.pm's
# own replace_router) needs both to keep its in-memory copy in sync. Same hard ide/ssh block as
# remove_router; collision-checked against the router list with the old entry already excluded,
# so replacing a router with an unchanged definition of the same name never spuriously collides
# with itself.
sub replace_router ($id, $name, $routerDef, $explicitAccessLevel, $defaultAccessLevel) {
   my ( $normalised, $resolvedAccessLevel );
   mutate(
      sub ($by_id, $by_name) {
         my $reservation = $by_id->{$id}
            or die Exception->new( 'msg' => "Reservation '$id' not found", 'status' => 400 );
         my $routers = $reservation->{'profileObject'}{'routers'} // [];
         my ($target) = grep { $_->{'name'} eq $name } @$routers;
         die Exception->new( 'msg' => "router '$name' not found", 'status' => 400 ) unless $target;
         die Exception->new(
            'msg'    => "router '$name' has type '" . ( $target->{'type'} // '' ) . "' and can never be removed/replaced",
            'status' => 400
         ) if ( $target->{'type'} // '' ) =~ /^(?:ide|ssh)$/;

         my @remaining = grep { $_->{'name'} ne $name } @$routers;
         $normalised = Reservation::normalise_router_def( $routerDef, \@remaining );
         push( @remaining, $normalised );
         $reservation->{'profileObject'}{'routers'} = \@remaining;

         my $carried = $reservation->{'meta'}{'access'}{$name};
         $resolvedAccessLevel =
              defined($explicitAccessLevel) ? $explicitAccessLevel
            : ( $normalised->{'name'} eq $name && defined($carried) &&
                grep { $_ eq $carried } @{ $normalised->{'auth'} } ) ? $carried
            : $defaultAccessLevel;
         _check_router_access_level( $resolvedAccessLevel, $normalised->{'auth'} );
         delete $reservation->{'meta'}{'access'}{$name} unless $normalised->{'name'} eq $name;
         $reservation->{'meta'}{'access'}{ $normalised->{'name'} } = $resolvedAccessLevel;

         return 1;
      }
   );
   return ( $normalised, $resolvedAccessLevel );
}

# Shared by hook_claim_if_not_running and launch_reset_stages_if_idle below - both need the
# identical "is this status entry genuinely still running" decision, now performed inside
# mutate()'s lock rather than hook_is_running's unlocked, single-process form. Mirrors
# hook_is_running's own liveness/self-heal reasoning exactly (execId is the only signal, same
# fallback to 'aborted' if it's inconclusive). The execId probe is a real HTTP round-trip to
# dockerd, so a caller with an existing 'running' entry does hold the reservations-db file lock
# for its duration - only on that path, never on the common "nothing recorded" path, which this
# returns from after a single hash lookup.
#
# Returns ($isLive, $healedFields): $isLive true means genuinely still running - the caller must
# not touch this slot. $healedFields is the ('state', and 'exitCode' where known) fields
# describing how a stale $existing actually ended, for the caller to apply via
# _resolve_hook_entry below and _append_hook_history; undef if $existing was already terminal,
# absent, or genuinely live (nothing to heal either way). Deliberately not a full merged entry -
# only _resolve_hook_entry ever combines these fields with $existing, so there is exactly one
# place that does, and it's the one place that also knows about a pending startCount commit.
sub _hook_entry_liveness ($existing) {
   return ( 0, undef ) unless $existing && ( $existing->{'state'} // '' ) eq 'running';

   if ( !defined( $existing->{'execId'} ) ) {
      # Normally live: newly-started elsewhere, the execId signal doesn't exist yet. Stale only
      # past $Reservation::HOOK_CLAIM_STALE_SECONDS with still no execId at all - the one gap
      # Reservation::dispatch_hook_exec's own try/catch around this exact window cannot close
      # (its owning process dying outright, not an exception it could catch and settle itself) -
      # see that package variable's own comment for why this lives there, not here.
      my $staleBefore = YYYYMMDDHHMMSS( time - $Reservation::HOOK_CLAIM_STALE_SECONDS );
      return ( 1, undef ) if ( $existing->{'startTime'} // '' ) ge $staleBefore;
      return ( 0, { 'state' => 'aborted' } );
   }

   my $res = call_socket_api_sync( $CONFIG->{'docker'}{'socket'}, "/exec/$existing->{'execId'}/json", {} );
   if ( $res && $res->is_success ) {
      my $info = decode_json( $res->body );
      return ( 1, undef ) if $info->{'Running'};   # genuinely still running

      if ( defined $info->{'ExitCode'} ) {
         return ( 0, {
            'state'    => $info->{'ExitCode'} == 0 ? 'done' : 'failed',
            'exitCode' => $info->{'ExitCode'},
         } );
      }
   }
   return ( 0, { 'state' => 'aborted' } );   # signal not conclusive - self-heal
}

# The one place a hooks.status.$name entry is ever transitioned into a terminal state
# ('done'/'failed'/'timedOut'/'aborted'/'skipped') - called from inside each of this module's
# own mutate() closures (never on its own, since it needs the lock already held), by
# resolve_hook_status below, hook_claim_if_not_running, and launch_reset_stages_if_idle. $data
# is the reservation's own already-locked 'data' hashref; $fields (must include 'state') is
# merged onto whatever's currently persisted for $name, exactly as
# Reservation::hook_status_completed's own merge used to do - the only difference is this reads
# $existing fresh from $data rather than from a caller's possibly-stale in-memory copy, the same
# correctness reasoning _append_hook_history already relies on for the same class of risk.
#
# If $existing carries 'pendingStartCount' (set by docker-event-daemon's own
# _launch_dispatch_prep at dispatch time - see its comment) and $fields resolves the entry to
# 'done', data.startCount is raised to at least that value in this same write - never
# incremented again from whatever it currently holds, because the dispatched container was
# already told this exact value via DOCKSIDE_START_COUNT before this exec ever ran, and nothing
# that happens afterward can make a different number correct. This makes the commit idempotent:
# applying it twice (e.g. a future caller resolving the same already-resolved entry again) can
# only ever raise data.startCount to the same value, never bump it twice. 'pendingStartCount' is
# never itself persisted onward - it is a one-shot instruction consumed here, not part of the
# entry's own terminal vocabulary.
#
# A supplied token must match the persisted entry, including when that entry has no token.
# An empty string identifies an observed legacy entry with no token; undef is reserved for
# same-lock healers and synchronous DAG decisions. A pending stage has
# no invocation and cannot accept a completion carrying a token. Returns ($applied, $entry).
sub _resolve_hook_entry ($data, $name, $fields, $expectedInvocationId = undef) {
   my $status = ( $data->{'hooks'} //= {} )->{'status'} //= {};
   my $existing = $status->{$name} // { 'name' => $name };

   if ( defined($expectedInvocationId)
        && ( ( $existing->{'invocationId'} // '' ) ne $expectedInvocationId
             || ($expectedInvocationId eq '' && ($existing->{'state'} // '') ne 'running') ) ) {
      return ( 0, $existing );
   }

   my $resolved = { %$existing, %$fields };
   my $pendingStartCount = delete $resolved->{'pendingStartCount'};
   if ( defined($pendingStartCount) && ($fields->{'state'} // '') eq 'done' &&
        ( $data->{'startCount'} // 0 ) < $pendingStartCount ) {
      $data->{'startCount'} = $pendingStartCount;
   }

   return ( 1, $status->{$name} = $resolved );
}

# Reservation::hook_status_completed's own locked mutator - see _resolve_hook_entry above for
# what "resolve" means here, including the pending startCount commit and $expectedInvocationId
# fencing. An applied resolution also records its history row (capped at $cap rows, see
# _append_hook_history) in this same write. Returns ($applied, $entry, $startCount): $applied
# is false when the write was rejected as stale, in which case $entry is whatever is genuinely
# current, not this call's own $fields; $entry is for the caller to sync onto its own in-memory
# copy; $startCount (the record's current value once this call returns, whether or not it just
# changed) for the caller to sync onto its own in-memory copy too.
sub resolve_hook_status ($id, $name, $fields, $cap, $expectedInvocationId = undef) {
   my ( $applied, $resolved, $startCount );
   mutate(
      sub ($by_id, $by_name) {
         my $reservation = $by_id->{$id} or return 0;
         my $data = $reservation->{'data'} //= {};
         ( $applied, $resolved ) = _resolve_hook_entry( $data, $name, $fields, $expectedInvocationId );
         _append_hook_history( $data, { %$resolved }, $cap ) if $applied;
         $startCount = $data->{'startCount'};
         return 1;
      }
   );
   return ( $applied, $resolved, $startCount );
}

# Writes dispatch progress only while the caller owns a running invocation. Exec creation
# and detached-start confirmation use the same locked identity check. A detached launch may
# commit one start-count increment with its first confirmation. Returns current state even
# on rejection so the caller can synchronize its in-memory view.
sub update_running_hook ($id, $name, $expectedInvocationId, $fields, $incrementStartCount = 0) {
   my ( $applied, $entry, $startCount ) = ( 0, undef, undef );
   mutate(
      sub ($by_id, $by_name) {
         my $reservation = $by_id->{$id} or return 0;
         my $data = $reservation->{'data'} //= {};
         $entry = $data->{'hooks'}{'status'}{$name};
         $startCount = $data->{'startCount'};
         return 0 unless $entry && ($entry->{'state'} // '') eq 'running'
            && defined($expectedInvocationId)
            && ($entry->{'invocationId'} // '') eq $expectedInvocationId;
         if ( $incrementStartCount && !$entry->{'dispatchStarted'} ) {
            $startCount = $data->{'startCount'} = ($startCount // 0) + 1;
         }
         $entry = $data->{'hooks'}{'status'}{$name} = { %$entry, %$fields };
         $applied = 1;
         return 1;
      }
   );
   return ( $applied, $entry, $startCount );
}

# Atomically checks-and-claims hook/stage $name for reservation $id: if it is not genuinely
# running, marks it running (with $logPath) and returns true (the caller should proceed to
# dispatch); if it genuinely is, returns false (the caller should report busy / skip) - all
# inside one mutate() call, so two concurrent callers (different app-server workers
# dispatching run_hook_manual, or an app-server worker racing docker-event-daemon's own
# launch-DAG auto-dispatch of lifecycle:launch/lifecycle:start) can never both see "not
# running" and both proceed, the way Reservation::hook_is_running + hook_status_started could
# when called as two separate, unlocked steps: a real, reproducible race, not just a
# theoretical one - 2 of 4 genuinely concurrent `dockside hook run` calls against the same
# devtainer both actually executed the hook script under that unlocked design, confirmed
# against the container's own execution log, not just the API's response.
#
# Deliberately not built on top of hook_is_running/hook_status_started - those remain as they
# are (a fast, unlocked, best-effort pre-check and a plain recording write respectively), still
# used on their own by callers that only ever have a single writer for the name in question
# (docker-event-daemon's own restart-recovery/on_tick self-heal, and the read-only hook_status()
# endpoint) and don't need this. This is for the two call sites where a second, concurrent
# writer for the *same* name is genuinely possible: Reservation::run_hook_manual (multiple
# app-server workers) and docker-event-daemon's own auto-dispatch of lifecycle:launch/
# lifecycle:start (the only two DAG stage names externally reachable via run_hook_manual
# too, when a profile's hooks entry sets "manual": true on them).
#
# A self-heal here (finding a stale entry and resolving it 'done'/'failed'/'aborted' before
# claiming the slot fresh) records the healed entry's history row inside this same mutate()
# closure, exactly as hook_is_running's own self-heal does through hook_status_completed, so
# the heal and the claim that follows it are one write.
#
# Returns the claimed entry (a hashref) if this call won and should proceed to dispatch, or
# undef if another invocation already owns $name. mutate() only ever operates on a fresh,
# separately-loaded copy of the reservation, never the caller's own in-memory object (see
# Reservation::Mutate::update's own comment) - a winning caller MUST sync this returned entry
# onto its own in-memory Reservation, exactly mirroring _hook_status_store_one's existing
# discipline, or its own subsequent hook_status_set_running_details call would merge execId
# onto stale (pre-claim) in-memory state instead of this fresh entry.
#
# $invocationId is stamped onto the claimed entry as-is, uninterpreted here - it is the token
# the caller must present back to _resolve_hook_entry (via resolve_hook_status/
# hook_status_completed) to resolve this exact claim later, so a completion belonging to a since-
# superseded claim of the same $name is rejected rather than overwriting the winner. The heal
# call below needs no token of its own - it reads $status->{$name} fresh, under this same lock,
# so it can never be stale by construction.
sub hook_claim_if_not_running ($id, $name, $logPath, $cap, $invocationId) {
   my $claimedEntry;

   mutate(
      sub ($by_id, $by_name) {
         my $reservation = $by_id->{$id} or return 0;
         my $data = $reservation->{'data'} //= {};
         my $status = ( $data->{'hooks'} //= {} )->{'status'} //= {};

         my ( $isLive, $healedFields ) = _hook_entry_liveness( $status->{$name} );
         return 0 if $isLive;
         if ( $healedFields ) {
            ( undef, my $healedEntry ) = _resolve_hook_entry( $data, $name, $healedFields );
            _append_hook_history( $data, { %$healedEntry }, $cap );
            # Falls through to claim the now-free slot below.
         }

         $status->{$name} = $claimedEntry = {
            'name'         => $name,
            'state'        => 'running',
            'execId'       => undef,
            'logPath'      => $logPath,
            'startTime'    => YYYYMMDDHHMMSS(time),
            'invocationId' => $invocationId,
         };
         return 1;
      }
   );

   return $claimedEntry;
}

# Atomically resets every name in @$stageNames to 'pending' for a fresh launch cycle - except
# any name that's genuinely still running right now (same live-check as
# hook_claim_if_not_running), which is left untouched rather than blindly overwritten.
#
# docker-event-daemon's own launch_reset_stages used to send all 5 DAG stage names
# unconditionally, every container-start event including ordinary restarts. Fine for
# launch:prep/launch:git/launch:ide (docker-event-daemon-exclusive - nothing else ever writes
# them), but lifecycle:launch/lifecycle:start are also reachable via a concurrent on-demand
# run_hook_manual invocation (same two names hook_claim_if_not_running exists for) - genuinely
# possible for a manually-triggered lifecycle:start to be mid-flight in one process at the
# exact moment another restart's reset fires in docker-event-daemon. Blindly overwriting that
# entry's 'running' state to 'pending' wouldn't cause a second dispatch (nothing reads this
# reset as a signal to dispatch anything already-applicable-false or already-dispatched-
# elsewhere), but would corrupt the status record's own accuracy for the duration - checked the
# same way for all 5 names here rather than special-casing which two actually need it.
#
# Returns ($written, $startCount). The caller must sync both onto its in-memory Reservation:
# healing a previous prep can advance the count used by the next launch's dispatch.
sub launch_reset_stages_if_idle ($id, $stageNames, $cap) {
   my $written = {};
   my $startCount;

   mutate(
      sub ($by_id, $by_name) {
         my $reservation = $by_id->{$id} or return 0;
         my $data = $reservation->{'data'} //= {};
         my $status = ( $data->{'hooks'} //= {} )->{'status'} //= {};

         for my $name (@$stageNames) {
            my ( $isLive, $healedFields ) = _hook_entry_liveness( $status->{$name} );
            next if $isLive;   # leave it running, untouched - not ours to reset

            # A stale entry resolved here still commits its own pending startCount (see
            # _resolve_hook_entry) even though $status->{$name} is about to be overwritten below
            # for the fresh cycle - the history row this produces is the only lasting record of
            # that invocation's own outcome, but the startCount side effect isn't allowed to
            # depend on anything ever reading it back from history.
            if ( $healedFields ) {
               ( undef, my $healedEntry ) = _resolve_hook_entry( $data, $name, $healedFields );
               _append_hook_history( $data, { %$healedEntry }, $cap );
            }
            $status->{$name} = $written->{$name} = { 'name' => $name, 'state' => 'pending' };
         }
         $startCount = $data->{'startCount'};
         return 1;
      }
   );

   return ( $written, $startCount );
}

1;
