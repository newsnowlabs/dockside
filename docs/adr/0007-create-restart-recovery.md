# ADR-0007: `create()` restart recovery and graceful shutdown

- **Status:** Implemented
- **Date:** 2026-08-12
- **Deciders:** Struan Bartlett

## Context

`Reservation::create` is a three-stage chain of continuations (pull the image if it isn't already
present → `POST /containers/create` → `POST /containers/{id}/start`), each stage recorded in
`createStatus.stage` (`pulling` → `creating` → `starting` → `done`, or `failed` at any point).
The stage is written once, synchronously, when a stage begins. While a pull runs the record also
receives a layer-progress snapshot at most once a second, but that exists for the polling client's
display: a snapshot that has stopped changing is not evidence that the driver died, since a
healthy pull can go quiet while it waits on a registry. Nothing in the persisted record says
whether a process is still driving the chain. That fact exists only in whichever process's memory
is actually driving it, and is lost the instant that process exits without writing a terminal
stage. A deliberate restart is closed by mechanism 6 below. What remains is uncontrolled death -
an OOM kill, an uncaught exception in a worker, `s6-svc -t` or `-k` - and, with the driver alive,
a reply lost between Docker and the driver (a socket error or timeout, or `dockerd` restarting
mid-request), after which the driver cannot tell whether its own request took effect.

Two things narrow the gap. A client cannot retry against an existing reservation: every create
request constructs a new reservation with a fresh id and, unless one is given, a fresh name, and a
name still held by another record is refused by the reservation database before any Docker call
is made. `create()`'s own refusal of a set `createStatus` is therefore defence in depth against a
second programmatic call for the same id, not a client-facing idempotency feature. So the gap is
not "duplicate creates are possible" - it's "a stuck reservation never gets un-stuck, and a
container found during recovery can be adopted without any check that it belongs to the
reservation adopting it."

`docker-event-daemon` has an analogous recovery mechanism for its own launch DAG (`hooks.status`,
a restart-recovery sweep, a recurring check for anything still genuinely in flight). That pattern
doesn't port directly to `app-server`, for a reason specific to how the two processes are shaped:

- `docker-event-daemon` is a single, non-forking process - "the process restarted" and "the
  thing driving the DAG restarted" are the same event. A sweep run once at startup, before its
  event loop starts, catches every case there is.
- `app-server` runs under `Mojo::Server::Prefork` - one manager process plus N worker processes,
  forked from the manager after the manager's own one-time startup code has already run. A
  `create()` call's whole chain lives entirely in the memory of the one worker that
  received the original HTTP request. The manager forks a *replacement* worker directly from
  itself when one dies - it does not re-exec the script, so a startup-only sweep never fires
  again for that case. A single worker dying (an uncaught exception, that worker OOM-killed) is,
  from the affected reservation's point of view, indistinguishable from a whole-process restart,
  but a startup-only sweep silently misses it.

Recovering a stuck reservation safely also has to answer a question distinct from "where did the
chain get to": whether a container found under the reservation's name during recovery actually
belongs to it. Whatever is then done with that container - adopting it, or removing it and failing
the reservation - begins with the same identification. Dockside-created containers carry no
identity of their own beyond the name each create call chooses, and Docker enforces name
uniqueness only at the exact-string level - so a recovery that blindly adopts "whatever holds this
name" cannot tell its own abandoned attempt's container apart from an unrelated one that happens
to share the name (a reservation named after an existing, unreserved container, or after a hex
prefix of one, if the lookup used resolves id prefixes the way Docker's single-container endpoint
does). The window in which a driver's death leaves such a container behind is small: `creating`
is written, the create posted, Docker's reply read and the id written within a fraction of a
second, and only uncontrolled death can fall inside it. A lost reply with the driver alive opens
the same question without any death, and is the likelier way to reach it. The same ambiguity, applied to a
chain that's still genuinely running rather than dead, is a second real hazard: every app-server
worker sees the same on-disk non-terminal stage on every reconcile tick, so a periodic
reconciler with no way to tell live from abandoned can just as easily misjudge a live chain and
start a second, concurrent driver for it.

## Glossary

Terms are defined once here and used with exactly this meaning throughout this record. Where a
term names a thing in the code, the code's name follows in brackets. The create chain's own terms
(record, stage, driver, attempt, entry, first create, possible prior create, outcome classes,
evidence) are defined under "Terms" in the state-model section, next to the rules that use them.
Three terms here (admission, issued tail, suspension) name distinctions the drain in mechanism 6
does not make; they are defined so that the whole area shares one vocabulary.

**Processes and framework**

- **app-server.** The Mojolicious HTTP service (`app/server/bin/app-server`) behind nginx. It runs
  under `Mojo::Server::Prefork`: one **manager** process that forks and supervises **workers**;
  each worker runs its own copy of the event loop and serves requests.
- **docker-event-daemon.** The single, non-forking process (`app/server/bin/docker-event-daemon`)
  that consumes Docker's `/events` stream, drives the launch DAG and runs its own event loop.
- **Event loop / reactor.** `Mojo::IOLoop` and the reactor beneath it. Both binaries run one. All
  asynchronous work in this area runs on it: HTTP calls to Docker and timers.
- **Public API (of Mojolicious).** Attributes, events and methods documented in the module's own
  POD. For `Mojo::Server::Prefork` (installed 9.31) that is: events `finish`, `heartbeat`, `reap`,
  `spawn`, `wait`; attributes `accepts`, `cleanup`, `graceful_timeout`, `heartbeat_interval`,
  `heartbeat_timeout`, `pid_file`, `spare`, `workers`; methods `check_pid`, `ensure_pid_file`,
  `healthy`, `run`. Everything else, including any method whose name begins with an underscore
  and any key inside the object hash, is **internal**.
- **Graceful shutdown.** The manager receiving `SIGQUIT`. It sends each worker `SIGQUIT`, which
  makes the worker's loop stop accepting connections and emit its `finish` event; the manager then
  waits up to the **graceful ceiling** for each worker to exit before killing it.
- **Graceful ceiling** (`graceful_timeout`). The one bound the framework provides: the seconds a
  worker may take to exit after being asked to, measured by the manager, after which it is sent
  `SIGKILL`. A single number for the whole process.
- **Immediate stop.** The manager receiving `SIGTERM` or `SIGINT`. Every worker is sent `SIGKILL`
  at once; nothing drains. This is Prefork's documented behaviour.
- **Restart, in production.** The whole container stopping or restarting under `docker compose`
  (an upgrade, a host reboot). `s6-svscan`'s shutdown cascade delivers each service the signal
  its `down-signal` file names: `SIGQUIT` for app-server, so a graceful shutdown; `SIGTERM` for
  the daemon, which it treats as a request to drain and exit. No production procedure runs
  `s6-svc` against a single service.
- **Restart, in development.** `s6-svc -r <service>` after an edit to what that service loads.
  The same `down-signal` files apply, so app-server's is graceful here too.

**Work and its accounting**

- **Drain.** What a worker does between its `finish` event and its exit: it stops admitting new
  work and waits for work it already owes. The **drain predicate** is the condition under which
  it may exit.
- **Admission.** The check that decides whether a request or a timer may start new work. A worker
  that is shutting down refuses admission: the request gets a 503, the timer does nothing.
- **In-flight registry.** A process-local table of work the process still owes. There are three:
  create chains (`%CREATE_IN_FLIGHT`, `Reservation.pm`), hook runs whose outcome write has not
  yet been decided (`%HOOK_DISPATCH_IN_FLIGHT`, `Reservation.pm`; released once the one attempt
  has applied, been fenced or thrown), and the daemon's DAG dispatches
  (`%DISPATCH_IN_FLIGHT`, `EventDaemon/LaunchDispatch.pm`). A fourth, `%ASYNC_UA_IN_FLIGHT` in
  `Util.pm`, only keeps HTTP user agents alive and is diagnostic.
- **Obligation.** An entry in an in-flight registry: something this process must finish, or hand
  over durably, before it may exit.
- **Issued tail.** The part of a create chain after a mutation has been posted to Docker and
  before its result is durably recorded. Distinct from a pull, which may be abandoned at any time
  because it changes nothing a later attempt cannot redo.
- **Durable handover.** Leaving the on-disk record in a state from which any later process can
  resume correctly, so that this process's exit loses nothing. The record is the queue.

**The create chain**

- **Chain.** The pull → create → start sequence that makes a reservation's container.
- **Ownership lock.** The per-reservation `flock` (`<tmpPath>/r-<id>.lock`) that guarantees one
  driver at a time. Kernel state: released the instant the holding process dies.
- **Reconciler.** The per-worker sweep (`_reconcile_pass` in `bin/app-server`, running
  `Reservation->reconcile_one`) that resumes abandoned chains every
  `appServer.reconcileIntervalSeconds` and once at worker start.
- **Adoption.** A resumed attempt taking over a container that an earlier attempt created, allowed
  only on exact name plus this reservation's id label plus a usable id.
- **Unresolved.** An attempt that ended without learning whether its mutation took effect. The
  record keeps its stage, gains a `createStatus.unresolved` diagnostic (`attempts`, `since`,
  `retryAfter`, `reason`), and is never expired. The next attempt after `retryAfter` finds out:
  the recording worker's own, at `$CREATE_UNRESOLVED_RETRY_DELAYS`, or a sweep's. The outcome
  after the last delay is the bound, recorded as `failed` with no expiry.
- **Suspension.** A chain ended deliberately at a boundary where nothing has been posted, because
  the worker is shutting down. Not a failure; the next attempt resumes.

**Hooks**

- **Hook run / invocation.** One execution of a profile hook inside a devtainer via Docker's exec
  API, identified by an `invocationId`. Dispatched by the daemon (launch DAG stages) or by
  app-server (manual runs).
- **Claim.** The `hooks.status` entry that marks an invocation as running. A claim with no
  `execId` older than `$HOOK_CLAIM_STALE_SECONDS` is self-healed by the next reader, which is what
  makes a hook run survive the death of its dispatching process.
- **Outcome write.** Persisting the invocation's final state and its history row, in one locked
  write, attempted once. An obligation is held while the attempt is being decided and released
  whatever its result: **applied** means it was written; **fenced** means a newer invocation
  superseded it and the write was correctly skipped; **threw** means nothing reached disk, the
  entry stays `running` with its `execId`, and the next reader of that entry (the status read a
  poller repeats, the daemon's recovery sweep, or the next claim of the name) settles it from
  Docker's exec inspection, or records `aborted` where Docker no longer has the exec.

**Robustness**

- **Crash safety.** The property that a process may die at any instruction without loss beyond
  what a later process can recover from the durable record. Crash safety is the primary
  guarantee; the drain is an optimisation of the deliberate-restart case (P1).
- **Graceful failure.** A launch that ends in a user-visible `failed` state with a reason, leaving
  the user to inspect and relaunch. It is the alternative to automatic recovery, not a lesser
  outcome.

## Principles

**P1. Crash safety first; drain second.** The system must be correct if any process is killed at
any moment. Given that, the drain exists only so that a routine, deliberate restart usually costs
the user nothing. A drain that is occasionally cut short is acceptable, because what it cuts
short is recovered by the same machinery that handles a crash.

**P2. Mojolicious is used through its public API only.** Admissibility test for any code that
touches the framework's process management: it may set documented attributes, subscribe to
documented events and call documented methods. It may not override a method whose name begins
with an underscore, read or write keys of the server object, or depend on the order of operations
inside a framework method. A small subclass that meets this test is acceptable; one that does not
is not, however useful the behaviour it buys. Where the public API cannot express a wanted
behaviour, the behaviour is redesigned or dropped, not the rule.

**P3. Every edge case gets an explicit outcome decision.** Automatic recovery is chosen only where
its cost in code and in operator confusion is justified by how often the case occurs and how bad
the alternative is for the user. "Fail with a clear reason and let the user relaunch" is a valid
outcome.

**P4. Model before code; tests from the model.** A change to this area produces a short model
(states, evidence, invariants, transitions) before implementation, and its tests are derived from
the model's transition rows. The state-model section below is the model for the create chain and
the template for the rest.

**P5. The record is the queue.** Anything a process must not lose is written to disk before the
process depends on it. Process memory holds nothing that a later process needs.

**P6. Reservation.pm is domain logic and owns no framework dependency.** Asynchronous primitives
it needs, a timer and the recycling hold, are provided to it by the process that loads it
(`Reservation::provider`); its monotonic clock is Perl's own. The create chain is a chain of
continuations, each called exactly once (I7), and the module names the framework nowhere.

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
clean up after). A deliberate restart is the one stop entirely under this codebase's own
control. In production it is the container stopping or restarting under `docker compose`,
reaching `app-server` through `s6-svscan`'s shutdown cascade; in development it is a per-service
`s6-svc -r` after a shared-lib edit. Refusing new creates and letting existing ones finish
means 1/2 are needed only for a death nobody chose.

Verified against the actual installed `Mojo::Server::Prefork`/`Mojo::IOLoop` source, not
documentation guesswork: a **non-graceful** shutdown (`SIGTERM`/`SIGINT` to the manager) kills
every worker with `SIGKILL` immediately - no grace period at all. Only a **graceful** shutdown
(`SIGQUIT` to the manager) sends each worker `SIGQUIT` and waits up to `graceful_timeout`
(default 120s) before forcing. But switching to a graceful signal alone isn't sufficient:
`Mojo::IOLoop`'s own `stop_gracefully` waits only for accepted *server-side connections* to
close, and `create()`'s own handler returns its HTTP response immediately (by design - the
fast-ack-then-poll UX its own header comment describes), so the connection that carried the
original `POST /containers/create` closes almost instantly and Mojo considers the worker done
**while the detached chain is still actively running** on that worker's event loop.
Mojo's graceful shutdown has no visibility into work that outlives the request that started it.

`App::Shutdown` tracks the worker's in-flight `create()` chains and hook runs
(`Reservation->create_in_flight_ids`, `->hook_dispatch_in_flight_ids`) and, on the worker's
`finish` event, drains: it waits for them to settle before letting the worker actually stop,
with no configured ceiling by default, or up to `appServer.shutdownGraceSeconds` less a fixed
margin when a finite ceiling is configured, logging what it is still waiting for every 30 s; the
`/containers/create` route itself asks `App::Shutdown` for admission at its own top and returns
a clean `503` rather than starting a chain about to be abandoned. The same value is passed to
`Mojo::Server::Prefork`'s own `graceful_timeout`, computed once before the workers fork, so the
worker's wait and the manager's force-kill ceiling cannot disagree. With no configured ceiling
that timeout is a one-day backstop, kept that small because Prefork kills a worker whose
heartbeat has gone silent at the same ceiling, so a worker hung while serving is reaped rather
than leaked; a drain that outlasts a day is killed at it. What bounds a drain in practice is
each hook run's own limit, each Docker call's inactivity timeout, and the container's stop
grace.

This only prevents the *deliberate-restart* case. A real crash, an OOM kill, `-k`, or
`graceful_timeout` itself expiring all bypass it entirely by construction (nothing catches
`SIGKILL`) - mechanisms 1/2 remain the only backstop for those.

**Operational follow-on**: `app-server` ships its own `down-signal` file (content `QUIT`). It is
read by `s6-svscan`'s whole-container shutdown cascade, which is the production path
(`docker compose stop`/`restart`, a host reboot), and by a manual `s6-svc -r`, which is the
development path (`CLAUDE.md`'s restart matrix, and the self-hosting hook
`dockside-self-update.sh`). Both therefore reach the same graceful shutdown. `nginx`/
`docker-event-daemon` carry no `down-signal` file, so both restart via a plain `SIGTERM`. The
development path must use `-r`, the one flag whose signal `down-signal` governs; `-t`/`-q` are
hard-coded to their one named signal regardless of any per-service file.

### The create chain as a state model

The mechanisms above are what make recovery possible. This section is the rule book they operate
under: for every state a reservation can be found in, what evidence the process that finds it may
trust, and what it must do with each thing that evidence can say. A change to the create chain is
judged against it, and the chain's test coverage is complete when every transition row below is
exercised.

#### Terms

- **Record.** A reservation's entry in `reservations.json`. Its `createStatus.stage` is the
  reservation's **stage**; `createStatus.failed`, `createStatus.unresolved`, `containerId` and
  `expiryTime` are the other fields the model reads. `createStatus.entered`, stage name to the
  fractional epoch of the stage's first entry, is written by the stage write and read by the
  client and by an operator; the model never reads it, since liveness is decided by the
  ownership lock, not by elapsed time.
- **Driver.** The process, or `Mojo::Server::Prefork` worker, currently running a reservation's
  create chain. There is at most one at a time, guaranteed by the ownership lock (mechanism 1).
- **Attempt.** One run of the chain by one driver, from acquiring the lock to releasing it. A
  fresh `create()` is an attempt; each resumption by `reconcile_one` is another.
- **Entry.** The state a driver finds the record in when its attempt begins. There are four:
  **fresh** (no `createStatus`), and resumed at **`pulling`**, **`creating`** or **`starting`**.
- **First create.** A create request issued by an attempt that knows no earlier create can have
  been issued for this reservation. A fresh entry's create is a first create, and so is the create
  that follows a pull resumed from `pulling`.
- **Possible prior create.** The condition of an attempt entered at `creating`: some earlier
  attempt may have posted a create whose outcome was never recorded, and Docker may have carried
  it out regardless of that attempt's death. The ownership lock is this process's state and dies
  with it; a request already accepted by Docker is not this process's state and may be carried out
  regardless. So the exit of the process that issued a request is not evidence that the request
  had no effect.
- **Outcome classes.** Every request ends in exactly one of: **success** (the mutation took
  effect), **definitive failure** (Docker refused it, so nothing took effect), or **unresolved**
  (whether it took effect cannot be established).

  | Outcome | Recorded as | Reconciled again? |
  |---|---|---|
  | Success | the stage advances, ultimately `done` | no |
  | Definitive failure | `stage: failed`, `failed: 1`, `error`, an `expiryTime` | no |
  | Unresolved | the stage is kept, `failed: 0`, a `createStatus.unresolved` diagnostic (`reason`, `attempts`, `since`, `retryAfter`), **no** `expiryTime` | yes |

  **Anything not positively identified is unresolved.** The two directions are not symmetric:
  treating an unknown outcome as unresolved costs one later lookup, while treating it as a failure
  records an expiry that deletes the reservation, and with it the only record of a container that
  may be running.
- **Mutation.** A request that can change Docker's state: an image pull, a container create, a
  container start. A name lookup is not a mutation.
- **Evidence.** A fact a driver may act on. The next section lists which facts qualify.

#### What a driver may trust

A driver acts only on the following. Anything else is not evidence, whatever it appears to say.

1. **The stage read from a fresh reload of the record while holding the ownership lock.** Not the
   reconciler's candidate snapshot, and not the driver's own in-memory copy from before the lock
   was taken (mechanism 2).
2. **A validated `200` list response to the exact-name lookup** `GET /containers/json?all=1` with
   the filter `{"name":["^/<name>$"]}`, the name regex-escaped. It establishes **present** (one
   entry) or **absent** (no entries). A failed request, any other status, a body that will not
   decode, a decoded value that is not a list, or more than one entry establishes nothing.
3. **A present entry's ownership**, read as: a usable id (a plain string of 12 to 64 lowercase hex
   digits) and a `Labels` set that is absent, null, or a hash whose
   `dev.dockside.reservation.id` is a plain string. With those shapes, the entry is **ours** if the
   label equals this reservation's id, **unrelated** otherwise, including when no label is present.
   An entry of any other shape establishes nothing.
4. **Docker's status code to the driver's own request**, classified per operation by the table
   under "Classification".
5. **The result of the driver's own write to the record.** A write that throws has not happened.
   The in-memory copy is updated only after the write returns, so a failed write leaves memory
   agreeing with disk.

Explicitly not evidence: the exit or death of any process; the ownership lock being free; the text
of a `409` body; a name match without the id label; a lookup that is anything but a validated
`200` list; a stage the driver tried and failed to write.

#### Invariants

- **I1. The stage is written before its mutation is posted.** `creating` reaches disk before a
  create is posted, `starting` before a start. A driver whose stage write fails posts nothing and
  ends the attempt unresolved. Consequently a record at `pulling` has never had a create posted
  for it, and a record at `starting` always carries a `containerId`. The stage write also
  records the stage's first-entry time in `createStatus.entered`; a re-entry keeps the time
  already there.
- **I2. One live driver per reservation.** The lock is taken before the first write of an attempt
  and released only after every callback that could write for that attempt has settled.
- **I3. Adoption needs the exact name, this reservation's id label and a usable id.** Never any
  one of those alone.
- **I4. An outcome exists only once it is on disk.** If the write recording an outcome fails, the
  attempt reports unresolved whatever the outcome was, because the record still says what it said
  before the attempt.
- **I5. At most one create is posted per attempt.** The `409` and refusal paths inspect; they never
  post again. A second create for the same reservation can only come from a later attempt, which
  looks the name up first.
- **I6. A resumable record is never expired by cleanup.** A record whose stage is `pulling`,
  `creating` or `starting` with `failed` false is left alone by `load_clean_map`, whether or not it
  carries a `containerId` and whether or not that container is in the Docker snapshot. This
  matters most at `starting`, where a container id is already recorded and a Docker snapshot that
  has not caught up would otherwise start a deletion clock against a live container.
- **I7. Every continuation on the chain is called exactly once.** A second call is a logged bug
  and is ignored, so one attempt records one outcome; an outcome that is not recorded is not an
  outcome.
- **I8. The consumer of an attempt is notified once, after cleanup, outside the classifier.** A
  consumer that throws cannot change the recorded outcome or be entered twice.
- **I9. An unresolved diagnostic belongs to one stage.** Re-entering the same stage carries it
  forward; advancing to another stage, or reaching a terminal one, clears it.

#### States

| Stage on disk | What may exist in Docker | What the next attempt may assume |
|---|---|---|
| none | nothing of this reservation's | It is the first attempt. |
| `pulling` | image partly or fully pulled | No container; no create has been posted (I1). The pull is idempotent. |
| `creating`, no `containerId` | a container under this name with this reservation's label, if a prior create was carried out | A prior create is possible. Ownership must be established before any refusal is trusted. |
| `creating`, with `containerId` | that container | The id was recorded but `starting` was not. The preflight lookup finds and re-adopts it. |
| `starting` | the container, started or not | The container exists unless Docker says `404`. A start is idempotent (`304`). |
| `done` | the container, started | Terminal. |
| `failed` | nothing of this reservation's; after the retry bound, whatever the last unresolved attempt left, which the `error` states | Terminal. With an `expiryTime`, cleanup deletes the record; the bounded failure carries none, and the record stays until removed. |

#### Classification

Per request, from the driver's own response. `$err` is a transport-level failure (timeout, reset,
closed socket).

| Operation | Response | Class |
|---|---|---|
| any | `$err` set, or no response | unresolved |
| any | status code missing or malformed | unresolved |
| create | `2xx` with a usable id in the JSON body | success |
| create | `2xx` without a usable id | unresolved: Docker accepted it; only the id was lost |
| create | `409` | conflict: inspect ownership, never infer it |
| create | `400`, `404`, `422` | definitive failure of **this** request |
| start | `2xx` or `304` | success; no body needed (`304` is Docker's already-running answer, which re-entry depends on) |
| start | `404` | definitive failure: the container is confirmed gone |
| start | `409` | unresolved; it carries no name-collision meaning and never enters adoption |
| any | `5xx` or any status not listed | unresolved |
| image check | `200` | present; `$err` or no response → unresolved at `pulling`; any other status → the pull decides |
| pull | non-2xx response, or an error event in a 2xx stream | definitive failure of the pull, Docker having reported it: a pull creates no container. Killing the client mid-pull aborts it server-side too, so no "pull already in progress" check is needed |
| pull | `$err` or no response (reset, refused, silent past the inactivity limit), or a 2xx stream that ended before its terminating chunk (closed mid-stream; the transport reports a close as an error only while no status line has arrived, so the response's content completion is the evidence) | unresolved at `pulling`. For a pull there is no mutation whose effect is in doubt: "unresolved" means worth retrying, the pull being idempotent and Docker keeping completed layers |

A definitive failure of *this* request becomes a definitive failure of the *reservation* only when
no prior create is possible. With a possible prior create, it is followed by ownership
confirmation, because it says nothing about the earlier request.

#### Ownership confirmation

Used after a `409`, after a refusal with a possible prior create, and when a record at `creating`
cannot compile a create body. It polls the exact-name lookup on a bounded budget
(`$CREATE_CONFLICT_POLL_DELAYS`, `$CREATE_CONFLICT_POLL_BUDGET_SECONDS`), capping each request's
timeout to what remains of the budget because the ownership lock is held throughout. The poll
exists for a predecessor's request still completing inside `dockerd` when the lookup runs; at the
reconciler's cadence that request has long settled before any resumed attempt looks, so the poll
is bounded insurance for an overlap the schedule makes near-impossible, not a routine path. It
reports:

| Poll result | Report |
|---|---|
| present, ours | adopt that id and proceed to `starting` |
| present, unrelated | definitive failure: confirmed foreign ownership |
| present, shape not readable | unresolved |
| absent on every poll | unresolved: Docker takes a name early in create and releases it if that create fails, so absence within the budget is transient, not a verdict |
| lookup established nothing | unresolved |

#### Transitions

Each row is one cell of entry × request × response, with the durable result of the attempt.
"Unresolved" always means: stage kept, `failed` 0, `unresolved` diagnostic written with
`attempts`, `since` and `retryAfter`, no `expiryTime`, lock released, consumer told unresolved.
"Failed" always means: `stage: failed`, `failed: 1`, `error`, lock released, consumer told a
definitive failure, and `expiryTime` except at the retry bound, whose failure carries none (the
"Any entry: recording and pacing" table below, and the States table's `failed` row).

**Fresh entry, and resumed `pulling`**

| Request | Response | Result |
|---|---|---|
| image check | any status but `200` | the pull is posted, and its own outcome decides; the status itself is not a verdict on the reservation |
| pull | Docker-reported failure (a non-2xx response, or an error event in the stream) | failed |
| image check / pull | no response | unresolved at `pulling`, the layer snapshot kept; the next attempt is a `pulling` entry |
| pull | a 2xx stream that ended before its terminating chunk | unresolved at `pulling`, exactly as no response |
| image check | `200`, or pull completes | write `creating`; if the write fails, unresolved with the record left at `pulling` and no create posted |
| first create | success | write `containerId`, then `starting` |
| first create | `400`/`404`/`422` | failed, no lookup at all: no earlier create can exist, so this refusal is the whole story |
| first create | `409` | ownership confirmation |
| first create | `$err`, `5xx`, unusable body | unresolved at `creating`; the next attempt is a `creating` entry and looks the name up first |

**Resumed `creating` (a prior create is possible)**

| Request | Response | Result |
|---|---|---|
| body compile | throws | ownership confirmation without a body: ours → adopt; unrelated → failed; otherwise unresolved. Adopting a container needs no body, and a body that cannot be compiled says nothing about whether a container was already created |
| preflight lookup | present, ours | adopt; write `containerId`; proceed to `starting`; no create posted |
| preflight lookup | present, unrelated | failed; no create posted |
| preflight lookup | present, unreadable | unresolved; no create posted |
| preflight lookup | established nothing | unresolved; no create posted |
| preflight lookup | absent | post the create |
| create | success | write `containerId`, then `starting` |
| create | success, `containerId` write fails | unresolved at `creating`, no `containerId`, no start posted |
| create | success, `starting` write fails | unresolved at `creating` with `containerId` recorded, no start posted |
| create | `$err` or `5xx` | unresolved |
| create | `2xx`, no usable id | unresolved; no id invented; no start |
| create | `400`/`404`/`422` | ownership confirmation: ours → adopt; unrelated → failed; otherwise unresolved. This retry's own outcome is not evidence about a predecessor's still-completing request |
| create | `409`, then ours appears | adopt; proceed |
| create | `409`, unrelated | failed |
| create | `409`, unreadable entry | unresolved |
| create | `409`, absent throughout the budget | unresolved; a later attempt creates once the name is free |

**Resumed `starting`**

| Request | Response | Result |
|---|---|---|
| (no body compile) | body would throw | irrelevant: never compiled. `cmdline_json()` reads the reservation's profile, and compiling it here would let an unrelated profile change terminate a reservation whose container exists and only needs starting |
| start | `204` or `304` | write `done` |
| start | success, `done` write fails | unresolved at `starting` |
| start | `404` | failed |
| start | `409` | unresolved; no lookup |
| start | `$err` or `5xx` | unresolved |

**Any entry: recording and pacing**

| Event | Result |
|---|---|
| the write recording an unresolved or failed outcome fails | consumer told unresolved; record unchanged; lock and in-flight entry released |
| consecutive unresolved attempts at one stage | `attempts` increments and `since` is kept; the recording worker schedules its own retry through the injected timer, at `$CREATE_UNRESOLVED_RETRY_DELAYS` (about 15 s after the first unresolved outcome, about 45 s after the second), `retryAfter` naming the same time; each retry is an ordinary `reconcile_one` under the lock with `retryAfter` honoured, and a sibling's sweep is the backstop. The third consecutive unresolved outcome is recorded as `stage: failed`, `failed: 1`, the last reason as `error` stating what may exist (a container under the name at `creating`, the recorded container at `starting`), **no** `expiryTime`, so the record stays until removed. A process dying mid-attempt records nothing and counts nothing; an outcome write that fails schedules no retry |
| a reconcile pass arrives before `retryAfter` | skipped under the lock, no Docker request, not counted. `retryAfter` paces the retries: the lock excludes a second simultaneous driver but says nothing about how soon the next may start |
| a later attempt advances the stage | the diagnostic is cleared; the entry map is kept |
| the consumer throws | entered once; outcome unchanged; in-flight entry released |
| cleanup runs against a resumable record | record retained, no expiry (I6) |
| any continuation on the chain | called exactly once; a second call is logged and ignored (I7) |

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
  explicitly, so Mojo's 40s default applies): a stalled call errors, the attempt settles with
  the outcome its classification gives, and the lock is released with it; the retry bound
  keeps a call that stalls every time from being retried for ever.

## Consequences

- A `create()` chain survives every restart shape this codebase actually exercises: a
  whole-process restart, a single worker dying under its siblings, and a deliberate restart in
  either lifecycle - proven by `t/integration/tests/18_create_restart_recovery.py`, which
  kills `app-server` mid-pull (single and four-concurrent) via a genuinely non-graceful
  `s6-svc -t` and confirms every reservation still reaches `done`. That test deliberately keeps
  `-t`, not the documented `-r`, specifically because its job is proving recovery from a
  non-graceful kill standing in for a real crash/OOM - `-r` is graceful for `app-server`, so only
  `-t` still exercises that worst case.
- Reconciliation is invisible to a polling client by design: a stuck `createStatus.stage` starts
  moving again (or flips to `failed` with a real reason) the same way it would have if the
  original worker had simply lived - no new `createStatus` shape.
- Retry is bounded, and prompt: the worker that records an unresolved outcome retries it itself,
  about 15 s later and then about 45 s later, with every worker's periodic sweep as the backstop
  for a worker that exits first; the third consecutive unresolved outcome at a stage is recorded
  `failed` with the last reason and no expiry. Two retries cover a transient that straddles the
  first; a reservation still unresolved after three is symptomatic of Docker itself, and the
  user sees the reason, and whether a container may exist under the name, rather than
  "launching" for ever. The record stays for inspection until the user removes it.
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
- **Fail a record stuck at `creating` and remove any container it left, telling the user to
  create afresh.** Needs the same exact-name lookup and label check as adoption to find the
  container, then adds a delete (a mutation with its own unresolved outcome) and a failed record,
  where adoption adds only the start the chain owed anyway. Not removing the container instead
  would leave it holding the name, so the user's fresh create under that name would be refused as
  foreign. Adoption is the smaller and non-destructive of the two, and the unresolved outcome
  class already gives the persistent case its graceful ending.
- **Tolerate a second driver, and add only the label check and `304` acceptance.** Fixes the
  adoption defect and a spurious `failed` on an already-running container, but leaves every long
  pull under multiple workers a candidate for a duplicate pull and a duplicate driver.
- **Skip the graceful exit handler; rely on the lock/reconciler alone.** Every compose stop or
  restart in production, and every per-service restart in development, would then pay the full
  cost (however many minutes until the periodic reconciler's next tick, every time) of a failure
  mode that's otherwise entirely avoidable.
- **Leave `app-server`'s restart on `-t`/`-q` (fixed-signal) rather than introducing
  `down-signal` + `-r`.** `-t` sends `SIGTERM` unconditionally, the worst case for an in-flight
  chain (immediate `SIGKILL`, zero grace) - exactly what the graceful handler exists to avoid on
  a deliberate development restart, and would leave that path behind the production one, which
  the cascade already makes graceful.
