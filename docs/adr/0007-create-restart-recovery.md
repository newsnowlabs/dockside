# ADR-0007: `create()` restart recovery and graceful shutdown

- **Status:** Implemented
- **Date:** 2026-08-12
- **Deciders:** Struan Bartlett

## Context

`Reservation::create` is a three-stage `Mojo::Promise` chain (pull the image if it isn't already
present → `POST /containers/create` → `POST /containers/{id}/start`), each stage recorded in
`createStatus.stage` (`pulling` → `creating` → `starting` → `done`, or `failed` at any point).
`createStatus.stage` is written once, synchronously, at the start of a stage, and never touched
again until that stage's own async work resolves - so a reservation five minutes into a
genuinely healthy pull and one whose driving process died four minutes ago are byte-for-byte
identical on disk. Nothing in the persisted record distinguishes "still running" from
"abandoned"; that fact exists only in whichever process's memory is actually driving the chain,
and is lost the instant that process exits without writing a terminal stage. This is a real,
routinely-triggerable gap in this repo's own normal workflow, not a hypothetical:
`s6-svc -t /etc/service/app-server` (part of this repo's own restart matrix, run after every
shared-lib edit), an OOM kill, or a bad deploy all trigger it.

What's already true independent of any of this, worth noting because it narrows the actual gap:
the idempotency guard checks the persisted reservation record, not just an in-process flag, so a
client retrying `dockside create` against the same reservation after a crash+restart is already
correctly refused a duplicate. The gap is narrower than "duplicate creates are possible" - it's
"a stuck reservation never gets un-stuck, and a container found during recovery can be adopted
without any check that it belongs to the reservation adopting it."

`docker-event-daemon` has an analogous recovery mechanism for its own launch DAG (`hooks.status`,
a restart-recovery sweep, a recurring check for anything still genuinely in flight). That pattern
doesn't port directly to `app-server`, for a reason specific to how the two processes are shaped:

- `docker-event-daemon` is a single, non-forking process - "the process restarted" and "the
  thing driving the DAG restarted" are the same event. A sweep run once at startup, before its
  event loop starts, catches every case there is.
- `app-server` runs under `Mojo::Server::Prefork` - one manager process plus N worker processes,
  forked from the manager after the manager's own one-time startup code has already run. A
  `create()` call's whole promise chain lives entirely in the memory of the one worker that
  received the original HTTP request. The manager forks a *replacement* worker directly from
  itself when one dies - it does not re-exec the script, so a startup-only sweep never fires
  again for that case. A single worker dying (an uncaught exception, that worker OOM-killed) is,
  from the affected reservation's point of view, indistinguishable from a whole-process restart,
  but a startup-only sweep silently misses it.

Recovering a stuck reservation safely also has to answer a question distinct from "where did the
chain get to": whether a container found under the reservation's name during recovery actually
belongs to it. Dockside-created containers carry no identity of their own beyond the name each
create call chooses, and Docker enforces name uniqueness only at the exact-string level - so a
recovery that blindly adopts "whatever holds this name" cannot tell its own abandoned attempt's
container apart from an unrelated one that happens to share the name (a reservation named after
an existing, unreserved container, or after a hex prefix of one, if the lookup used resolves id
prefixes the way Docker's single-container endpoint does). The same ambiguity, applied to a
chain that's still genuinely running rather than dead, is a second real hazard: every app-server
worker sees the same on-disk non-terminal stage on every reconcile tick, so a periodic
reconciler with no way to tell live from abandoned can just as easily misjudge a live chain and
start a second, concurrent driver for it.

## Decision

**1. A per-reservation ownership lock, held by whichever process drives a reservation's create
chain, for the chain's whole lifetime.** The lock file is `<tmpPath>/r-<id>.lock` (the
established per-reservation naming under `tmpPath`, alongside the hook logs). `Reservation::create`
takes it (`Util::tryLockFile`, `LOCK_EX | LOCK_NB`) before writing the first
`createStatus.stage`; failure to acquire means a chain for this reservation is already live
somewhere, and `create()` refuses exactly as it already does for a set `createStatus`. The open
handle lives in the chain's closure (`Reservation::_create_track`) and is closed - releasing the
lock - when the chain settles, on success or failure. The kernel gives this property for free: a
`flock` held on an open descriptor is released the instant the holding process dies, for any
reason, with no heartbeat, no staleness threshold, no pid probing.

**2. A single reconciler, run per worker.** Each `app-server` worker runs a reconcile pass
(`_reconcile_pass`) once when its own event loop starts, and again every
`appServer.reconcileIntervalSeconds`. Both are registered pre-fork, on the shared `Mojo::IOLoop`
singleton, so each forked worker's own copy of the reactor ticks them independently - the
manager itself never runs the reactor past that point, so neither ever fires there. A pass loads
`reservations.json`, and for every reservation with a non-terminal `createStatus.stage` attempts
`Reservation->reconcile_one`, which takes the reservation's lock non-blockingly: refused means a
chain for it is live somewhere, so it's skipped; acquired means the lock was free, for exactly
one of two reasons - the previous holder finished and released it deliberately (a fresh reload
now shows a terminal stage, or the reservation is gone), or it died mid-chain (the kernel freed
the lock, but nothing wrote a terminal stage, so the reload still shows the same non-terminal
stage). Reading the stage only *after* acquiring the lock, from a fresh, direct reload (not the
pass's own candidate snapshot, and not the calling worker's cached copy - see
`Reservation::_reservation_reloaded`), is what tells these two cases apart; the snapshot a pass
iterates from is never trusted to still be current by the time a lock is acquired. That reload
must also bypass `Data::load`'s own timestamp-gated cache (`Data::load_fresh`, not `Data::load`):
two separate writes to `reservations.json` can share an identical modification timestamp even
with the fractional-second `stat` `Data::load` otherwise relies on, so a worker's cached copy of
a since-settled `pulling`/`creating`/`starting` stage can survive an ordinary, cache-respecting
reload and be mistaken for the current state.

This is the only sweep app-server runs: a whole-process restart is just every worker's own first
pass, arbitrated by the same per-reservation locks, with nothing run in the manager beyond the
one-time orphan-lock cleanup below (mechanism 4) - a lock taken before any worker forks would be
inherited by every forked worker and never released while any of them lives. Recovery after a
restart with several abandoned chains is not spread evenly across workers: whichever worker's
own pass reaches a given candidate first claims it, so one worker can end up driving recovery
for all of them if it happens to run first, while its siblings find nothing left. This trades
even load for a simpler mechanism - every chain still reaches a terminal stage on its own
schedule, just not necessarily on a worker chosen for balance.

**3. Dockside-created containers carry identity labels, and a recovery re-entry's adoption
requires the id label.** `Reservation::Launch::cmdline_json` sets:

| Label | Value |
|---|---|
| `dev.dockside.reservation.id` | the reservation id - the ownership check |
| `dev.dockside.owner.username` | the owner's username at create time |
| `dev.dockside.owner.name` | the owner's display name at create time |
| `dev.dockside.profile` | the profile name |

Only the first is load-bearing. The others exist so an operator running `docker inspect` sees a
coherent, self-describing set rather than one opaque key, and so
`docker ps --filter label=dev.dockside.reservation.id` works as a handle. Keys use reverse-DNS
of `dockside.dev`, Docker's own documented namespacing convention.

With one driver per reservation guaranteed by the lock, `_create_stage_creating` treats a fresh
(non-recovery) create's `409` from `POST /containers/create` as a genuine collision with a
container this reservation does not own: the chain fails with a user-facing reason ("name ... is
already in use by a container this reservation does not own") and no adoption occurs, with no
pre-create lookup at all - Docker's own uniqueness check is the check. A *recovery* re-entry
(resuming a chain some other process left mid-flight) looks up its own name first, because
that's the one case where a container already existing under the name is the expected outcome of
its own earlier, abandoned attempt: the lookup is
`GET /containers/json?all=1&filters={"name":["^/<name>$"]}` (anchored to the exact name, not
Docker's single-container `GET /containers/{name}/json`, which also resolves an id prefix - a
reservation named after a hex prefix of some other container's id would otherwise match that
container instead). A match is adopted only if its `dev.dockside.reservation.id` label equals
this reservation's id; any other or missing label fails the chain closed exactly like the
fresh-create case, without ever attempting a create call that would only `409` anyway.

**4. Lock-file hygiene.** `Reservation::Mutate::load_clean_map` takes the reservation lock
non-blockingly before deleting an expired record, and holds it through the database write.
It skips a record while a create driver owns the lock: that driver can still write to the
record. The cleaner retains the lock file even after deletion, because another process may
already have opened it before attempting its flock. Unlinking would allow two processes to
lock different inodes under the same path. A one-time pass in the manager, before any worker
forks (`_cleanup_orphaned_reservation_locks`), removes files with no matching reservation.

**5. `starting` accepts `304`.** A repeat start on an already-running container - the case a
resumed chain hits whenever recovery re-enters at `starting` - returns Docker's own idempotent
response for a container that's already running; `_create_stage_starting` accepts `204` or
`304`, matching `Reservation::action`'s own convention for the same case.

**6. Graceful exit handler** (prevention, not cure - closes the gap the other mechanisms only
clean up after). Given how routinely `app-server` gets restarted *on purpose* in this repo's
normal workflow, refusing new creates and giving existing ones a bounded chance to finish
reduces how often 1/2 even need to fire, for the one failure mode entirely under this codebase's
own control.

Verified against the actual installed `Mojo::Server::Prefork`/`Mojo::IOLoop` source, not
documentation guesswork: a **non-graceful** shutdown (`SIGTERM`/`SIGINT` to the manager) kills
every worker with `SIGKILL` immediately - no grace period at all. Only a **graceful** shutdown
(`SIGQUIT` to the manager) sends each worker `SIGQUIT` and waits up to `graceful_timeout`
(default 120s) before forcing. But switching to a graceful signal alone isn't sufficient:
`Mojo::IOLoop`'s own `stop_gracefully` waits only for accepted *server-side connections* to
close, and `create()`'s own handler returns its HTTP response immediately (by design - the
fast-ack-then-poll UX its own header comment describes), so the connection that carried the
original `POST /containers/create` closes almost instantly and Mojo considers the worker done
**while the detached promise chain is still actively running** on that worker's event loop.
Mojo's graceful shutdown has no visibility into work that outlives the request that started it.

The handler tracks in-flight `create()` chains (`Reservation->create_in_flight_count`) and, on
the worker's `finish` event, waits up to `appServer.shutdownGracePeriod` (default 90s) for that
count to reach zero before letting the worker actually stop; the `/containers/create` route
itself checks a `$shuttingDown` flag at its own top and returns a clean `503` rather than
starting a chain about to be abandoned. `shutdownGracePeriod` is deliberately coordinated
against `Mojo::Server::Prefork`'s own `graceful_timeout` - raised from its 120s default to 150s
in `bin/app-server`'s own construction - so the exit handler's bounded wait never races the
manager's hard force-kill ceiling (60s of headroom).

This only prevents the *deliberate-restart* case. A real crash, an OOM kill, `-k`, or
`graceful_timeout` itself expiring all bypass it entirely by construction (nothing catches
`SIGKILL`) - mechanisms 1/2 remain the only backstop for those.

**Operational follow-on**: `app-server` ships its own `down-signal` file (content `QUIT`), read
by both a manual `s6-svc -r` and `s6-svscan`'s own whole-container-shutdown cascade
(`docker stop`, a host reboot) - the latter bypasses a manual `s6-svc` invocation entirely, so it
needed its own, separately-verified mechanism to reach the same graceful path. `nginx`/
`docker-event-daemon` carry no `down-signal` file, so both still restart via a plain `SIGTERM`.
`CLAUDE.md`'s restart matrix and every script that restarts services
(`dockside-self-update.sh`) use `s6-svc -r` uniformly across all three for this reason - the one
flag whose signal `down-signal` actually governs, unlike `-t`/`-q`, which are hard-coded to their
one named signal regardless of any per-service file.

### Known and unknown outcomes

A create chain issues mutations it may not learn the result of. The ownership lock is this
process's state and dies with it; a request already accepted by Docker is not this process's state
and may be carried out regardless. So the exit of the process that issued a request is not
evidence that the request had no effect, and every outcome falls on two axes, not one:

| Outcome | Meaning | Recorded as | Reconciled again? |
|---|---|---|---|
| Success | The mutation took effect | the stage advances, ultimately `done` | no |
| Resolved failure | Docker refused the request, so nothing took effect | `stage: failed`, `failed: 1`, an `expiryTime` | no |
| Unresolved | It may or may not have taken effect | the stage is kept, `failed: 0`, a `createStatus.unresolved` diagnostic, **no** `expiryTime` | yes |

**Anything not positively identified is unresolved.** The two directions are not symmetric:
treating an unknown outcome as unresolved costs one later lookup, while treating it as a failure
records an expiry that deletes the reservation - and with it the only record of a container that
may be running. Concretely, unresolved covers a lost or timed-out response, a `2xx` whose body
cannot be read (Docker accepted the mutation; only the id was lost), a `5xx`, any status not
listed below, a name lookup that establishes nothing, and a Docker call that succeeded whose
result could not be written to disk.

An unresolved reservation keeps a non-terminal stage, so `reconcile_one` still resumes it, and
carries `attempts`, `since` and `retryAfter` in its diagnostic. `retryAfter` paces the retries:
the lock excludes a second simultaneous driver but says nothing about how soon the next may
start, so without it a sibling worker's sweep would retry the instant the previous holder
released the lock. Such a record is never expired or deleted by `load_clean_map`, including at
`starting`, where a container id is already recorded and a Docker snapshot that has not caught up
would otherwise start a deletion clock against a live container. Reconciliation is what ends the
state - by completing the chain, or by recording a definitive failure, after which the ordinary
cleanup rules apply.

### Ground truth per stage

Each non-terminal stage has a real Docker-side signal to reconcile against - no stage needs an
ongoing "is this still happening" poll the way a live hook `execId` does. The `creating` row
differs between a fresh create and a recovery re-entry, per mechanism 3 above.

| `createStatus.stage` freshly read while holding the reservation lock | Reconciliation check | Safe action |
|---|---|---|
| `pulling` | `GET /images/{image}/json` | Present → proceed to `creating` as a first create (next row). Absent → re-`POST /images/create` (killing the client mid-pull aborts it server-side too - Docker does not keep pulling after the initiating connection drops - so no "pull already in progress" check is ever needed). A pull that fails created nothing, so its failure is definitive. A record at `pulling` has never issued a create, because `creating` is persisted before any create is posted, so the create that follows a resumed pull has no predecessor to account for |
| `creating` (first create: reached from `create()` or from `pulling`, fresh or resumed) | `POST /containers/create`, with `409` confirmed by the lookup below | `2xx` with a usable id → proceed to `starting`. `400`/`404`/`422` → `failed`, user-facing reason: no earlier create can exist, so this refusal is the whole story. `409` → confirm ownership, never infer it |
| `creating` (read at `creating` under the lock: a prior create may have been issued) | `GET /containers/json?all=1&filters={"name":["^/<name>$"]}` | Present, with a usable id, **and** `Labels."dev.dockside.reservation.id"` equals this reservation's id → proceed to `starting` with its id. A record with a usable id and any other or no matching label → `failed`, user-facing conflict reason. A record with no usable id confirms nothing, so it is treated the same as an unreadable lookup, below. Absent → run the create call, whose own `400`/`404`/`422`/`409` is confirmed the same way as the two rows below, not inferred from this one lookup - the predecessor's own request, issued by a worker now dead, may still be completing regardless of what this retry is told. Only a validated `200` list establishes absence: a failed, unreadable, non-list or multiply-matching lookup, or a record whose shape cannot be read, is unresolved and must not authorize a create |
| `creating` with a possible prior create, `400`/`404`/`422` from its own create call, or a body that could not be compiled to attempt one | the same name lookup, polled on a bounded budget | Owned by this reservation → adopt its id and proceed to `starting`. A record with a usable id owned by anything else → `failed`. Nothing holding the name after the poll budget, or a record with no usable id → unresolved: this retry's own outcome is not evidence about a predecessor's still-completing request |
| `creating`, `409` from the create call | the same name lookup, polled on a bounded budget | Owned by this reservation → adopt its id and proceed to `starting`. A record with a usable id owned by anything else → `failed`. Nothing holding the name, or a record with no usable id → unresolved: Docker takes a name early in create and releases it if that create fails, so an empty lookup here is a transient state and not a verdict |
| `starting` | none needed | `POST /containers/{id}/start`; `204` or `304` both proceed to `done` (`304` is Docker's already-running answer, which re-entry depends on). `404` → `failed`, the container is confirmed gone. A `409` carries no name-collision meaning here and never enters the create path's adoption |

Resuming `starting` needs only the container id already on disk, so it never compiles a create
body. That is not an optimisation: `cmdline_json()` reads the reservation's profile, and
compiling one here would let an unrelated profile change terminate a reservation whose container
exists and only needs starting. A `creating` re-entry whose body cannot be compiled likewise
establishes ownership first, since adopting a container needs no body either.

## Lock-file lifecycle and constraints

- **No persistence requirement.** Lock state is kernel state on the descriptor, not file
  content. After any restart no process holds a lock, so a surviving file is acquired by the
  first attempt and a wiped file is recreated by it; both give the correct answer. `tmpPath` is
  therefore fine whether or not it is a tmpfs.
- **Never unlink a lock file during online record deletion.** Even an unlocked file can
  already be open in a worker waiting to attempt its flock. Retain it until the manager's
  pre-fork startup cleanup, which removes `r-<id>.lock` files with no matching reservation.
  Before deleting an expired record, acquire its reservation lock non-blockingly and retain
  it through the database write. Never wait for it while holding the database lock: a create
  driver can hold the reservation lock while waiting for the database lock.
- **No `fork` without `exec` while holding a lock.** An inherited descriptor keeps the lock alive
  for the child's lifetime after the parent dies. Perl's default `$^F` marks descriptors above 2
  close-on-exec, so `system`-style children do not inherit it; a bare `fork` in a worker would.
  Nothing on the create path forks; this is the invariant that keeps it so.
- **A chain that hangs while its worker lives holds the lock indefinitely.** The same exposure
  exists in any in-process in-flight table, including a single-driver daemon's. In practice it is
  bounded by `Mojo::UserAgent`'s inactivity timeout on each Docker call (the chain passes none
  explicitly, so Mojo's 40s default applies): a stalled call errors, the chain settles as
  `failed`, and the lock is released with it.

## Consequences

- A `create()` chain survives every restart shape this codebase actually exercises: a
  whole-process restart, a single worker dying under its siblings, and a deliberate,
  in-repo-normal restart - proven by `t/integration/tests/18_create_restart_recovery.py`, which
  kills `app-server` mid-pull (single and four-concurrent) via a genuinely non-graceful
  `s6-svc -t` and confirms every reservation still reaches `done`. That test deliberately keeps
  `-t`, not the documented `-r`, specifically because its job is proving recovery from a
  non-graceful kill standing in for a real crash/OOM - `-r` is graceful for `app-server`, so only
  `-t` still exercises that worst case.
- Reconciliation is invisible to a polling client by design: a stuck `createStatus.stage` starts
  moving again (or flips to `failed` with a real reason) the same way it would have if the
  original worker had simply lived - no new `createStatus` shape.
- Retry is unbounded on the periodic reconciler's own interval, by deliberate choice - a
  reservation that can't reconcile is symptomatic of something wrong with Docker itself (which
  would be blocking everything else too), not something to silently paper over as `failed` after
  some arbitrary number of attempts.
- Recovery is decided by one atomic, kernel-arbitrated question per reservation, with no
  heuristics and no cross-worker state. `create_in_flight`/`create_in_flight_count`
  (`Reservation.pm`) exist only for the graceful drain's own counter, since
  `Reservation.pm` is the only code that observes a chain's start/settle moments.
- A name collision on a first create is a user-visible `failed`. Operators can identify and
  filter Dockside-managed containers by label (`docker ps --filter label=dev.dockside.reservation.id`).
- `create()`'s own body is a set of unconditionally re-enterable `_create_stage_*` functions
  chained by stage-specific `_create_run_from_*` glue - `create()` always starts at
  `_create_run_from_pulling`; `reconcile_one`/`reconcile_create` start wherever
  `createStatus.stage` says. The one flag that changes behaviour, `$priorCreatePossible`, is true
  only for a record read at `creating` under the lock, and only affects that stage (mechanism 3's
  lookup, and ownership confirmation before a refusal is trusted); a chain resumed from `pulling`
  runs the same code as a fresh one, since no create can have been posted for it. This is the
  only way to avoid a second, parallel copy of the pull/create/start logic existing solely for
  recovery.

## Rollout and unlabelled containers

A container created before identity labels existed has no reservation identity label. If its
journal is left at `creating`, recovery will refuse to adopt it and record `failed`, even if it
was in fact created by that reservation. There is no name-only compatibility fallback. Existing
terminal reservations are not re-adopted, and recovery at `starting` continues using the already
persisted container ID.

If an unlabelled container is stranded at `creating`, an operator must inspect the reservation,
logs and container to establish its provenance; the matching name alone is insufficient.
Preserve any required data, then remove the failed reservation through the normal
administrative flow and rename or remove the conflicting container as appropriate before
submitting a new create. The new container receives the identity label. Do not clear the failed
stage to force retries or backfill ownership from a name match; if provenance is uncertain, leave
the existing container untouched and use a different name for the new reservation.

## Required regression coverage

`t/integration/tests/18_create_restart_recovery.py` covers, or must cover, the following (using
controlled scheduling or barriers for the races rather than depending on pull duration):

- A whole-process restart and a single worker dying under its siblings both recover a
  reservation stuck at any of the three stages, without duplicating a pull, create, or start.
- With multiple workers, a sibling reconciler skips a reservation whose live create chain holds
  the lock, issuing no duplicate pull, create or start. Killing the owner releases ownership and
  allows a subsequent pass to recover it.
- Pause a reconciler after its candidate snapshot, let the owner persist `done` and release the
  lock, then resume the reconciler. It must re-read and skip, issue no Docker mutation, and leave
  `done` and `expiryTime` unchanged. Also cover a missing reservation and a refreshed
  non-terminal stage with a newly persisted container ID.
- Recovery at `creating` adopts a container with the matching reservation ID label, persists its
  ID and completes without another create POST. Missing or mismatched labels fail closed without
  storing the unrelated container's ID or starting it, including the unlabelled-container rollout
  case. An absent container permits create, but a subsequent `409` fails without adoption.
- A fresh create against an independently-created container of the same name fails closed
  without adopting or starting it. A reservation named after an unrelated container's hex ID
  prefix must likewise never adopt or start that container; a successful create must use its own
  returned ID. Assert the identity label on newly created containers.
- Recovery at `starting` against an already-running container accepts Docker `304`, reaches
  `done`, and does not set `expiryTime`. Retain coverage for `204` success and genuine start
  failures.

## Follow-on work

- **Coalesce `createStatus` progress writes.** Each Docker pull progress event currently persists
  via a blocking, exclusively locked read-modify-write of `reservations.json` on the worker's
  event loop, so a pull's write rate is the registry's event rate, and N concurrent pulls in one
  process are N interleaved writers. Persisting at most one progress update per chain per few
  hundred milliseconds (with stage transitions always written immediately) would cut that
  amplification for every pull, adopted or not. This changes persistence behaviour rather than
  recovery, so it's out of scope here.

## Alternatives considered

- **Port `docker-event-daemon`'s startup-sweep-only pattern as-is.** Covers only the
  whole-process-restart granularity; a single-worker death under `Mojo::Server::Prefork` is a
  distinct failure shape with no equivalent in a single-process daemon, and would go silently
  unrecovered.
- **A single process-wide lock, held only while dispatching a reconcile pass.** Protects a
  sweep's own dispatch against a concurrent sweep, but the chain a dispatch kicks off keeps
  running long after the lock is released, so it never answers whether that chain is still
  alive - and it never covers the original `create()` path at all, so an ordinary `create()`
  call can still be double-driven by a reconciler that has no way to know it's live.
- **A record-based per-reservation claim with a staleness timestamp** (mirroring
  `hook_claim_if_not_running`). Needs a hand-chosen threshold and a per-chain heartbeat write to
  approximate what a kernel-level `flock` gives exactly, and write-amplifies
  `reservations.json` under concurrent pulls.
- **Owner pid in the record, checked with `kill 0`.** Vulnerable to pid reuse across the
  manager's replacement-worker forks, and blind to a chain that died while its worker lived.
- **Move the create chain into `docker-event-daemon`, as further stages of its launch DAG.**
  Gives one driver by construction and unifies lifecycle ownership in one process, but at
  structural cost: head-of-line blocking of Docker events, hooks and creates behind any stall in
  a single reactor (the daemon already has synchronous spots on its hook path); a hard scaling
  ceiling on concurrent creates; authorisation frozen at request time in one process and acted
  on later in another, with `reservations.json` becoming a command queue; a new client-visible
  "requested" stage; and create availability coupled to daemon liveness with no signal to the
  user.
- **Tolerate a second driver, and add only the label check and `304` acceptance.** Fixes the
  adoption defect and a spurious `failed` on an already-running container, but leaves every long
  pull under multiple workers a candidate for a duplicate pull and a duplicate driver.
- **Skip the graceful exit handler; rely on the lock/reconciler alone.** Given how routinely this
  repo's own workflow restarts `app-server` on purpose, that would leave the common case paying
  the full cost (however many minutes until the periodic reconciler's next tick, every time) of a
  failure mode that's otherwise entirely avoidable.
- **Leave `app-server`'s restart on `-t`/`-q` (fixed-signal) rather than introducing
  `down-signal` + `-r`.** `-t` sends `SIGTERM` unconditionally, the worst case for an in-flight
  chain (immediate `SIGKILL`, zero grace) - exactly what the graceful handler exists to avoid on
  a routine, deliberate restart.
