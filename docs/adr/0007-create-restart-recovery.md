# ADR-0007: `create()` restart recovery and graceful shutdown

- **Status:** Implemented
- **Date:** 2026-08-12
- **Deciders:** Struan Bartlett

## Context

`Reservation::create` is a four-stage `Mojo::Promise` chain (check image →
pull if missing → `POST /containers/create` → `POST /containers/{id}/start`),
each stage recorded in `createStatus.stage` (`pulling` → `creating` →
`starting` → `done`, or `failed` at any point). Before this change, nothing
resumed that chain if the process driving it died partway through — the
reservation was left with a non-terminal `createStatus.stage` forever, with
no code path that would ever advance or fail it. This was a real,
routinely-triggerable gap, not a hypothetical: `s6-svc -t /etc/service/app-server`
(part of this repo's own restart matrix, run after every shared-lib edit), an
OOM kill, or a bad deploy would all trigger it.

What was already true without any new code, worth noting because it narrows
the actual gap: the idempotency guard checks `$self->{'createStatus'}`,
populated straight from the persisted reservation record on load — not just
an in-process flag. A client retrying `dockside create` against the same
reservation after a crash+restart was already correctly refused a duplicate.
**The actual gap is narrower than "duplicate creates are possible" — it's "a
stuck reservation never gets un-stuck."**

`docker-event-daemon` already has this kind of recovery for its launch DAG
(`hooks.status`, a restart-recovery sweep, `%launchRecovering` + a recurring
check for anything still genuinely in flight). That pattern doesn't port
directly, for a reason specific to how the two processes are shaped:

- `docker-event-daemon` is a single, non-forking process — "the process
  restarted" and "the thing driving the DAG restarted" are the same event. A
  sweep run once at startup, before its event loop starts, catches every
  case there is.
- `app-server` runs under `Mojo::Server::Prefork` — one manager process plus
  N worker processes (default 4), forked from the manager after the
  manager's own one-time startup code (including any startup sweep placed
  there) has already run. A `create()` call's whole promise chain lives
  entirely in the memory of the one worker that received the original HTTP
  request. The manager monitors worker heartbeats and forks a *replacement*
  worker **directly from itself** when one dies — it does not re-exec the
  script, so a startup-only sweep does not fire again for that case. A
  single worker dying (an uncaught exception, that worker OOM-killed) is,
  from the affected reservation's point of view, indistinguishable from a
  whole-process restart — but a startup-only sweep silently misses it.

## Decision

Three mechanisms, addressing two distinct failure granularities plus
prevention:

**1. Startup sweep** (whole-process restart — directly analogous to
`docker-event-daemon`'s own). Runs once, in the manager, before any worker
forks: finds every reservation whose `createStatus.stage` is non-terminal and
reconciles each one against real Docker state (see the table below).
Non-fatal on failure, logged, matching `docker-event-daemon`'s own sweep
convention.

**2. Per-worker periodic reconciler** (a single worker dying while its
siblings and the manager stay up — no `docker-event-daemon` equivalent,
since it's single-process). Each worker independently registers a
`Mojo::IOLoop->recurring` timer (`appServer.reconcileIntervalSeconds`,
default 300s — frequent enough that a stuck reservation doesn't sit broken
long, infrequent enough to read as a self-heal net rather than a poll loop)
that re-runs the same sweep.

Registering this per-worker surfaced a real race before it shipped: with
`appServer.workers` workers, the *same* stuck reservation is visible to all
of them on every tick — this codebase had already hit and fixed exactly this
class of bug once before, for hook dispatch (`hook_claim_if_not_running`,
after a reproduced instance of two concurrent callers both actually
executing the same hook). An unlocked periodic reconciler here would be the
same bug again: worst case, two workers both see a reservation's container
absent at the `creating` stage and both `POST /containers/create` — Docker's
own name uniqueness means only one wins, but the loser needs to treat its own
`409` as "someone else just won" rather than a hard failure.

Fixed with a single process-wide `flock(LOCK_EX | LOCK_NB)` guarding the
*entire* sweep call, not a per-reservation claim. A first-drafted version
used a per-reservation atomic claim (mirroring `hook_claim_if_not_running`'s
shape exactly — a `mutate()`-locked check-and-set with its own staleness
timestamp). It worked, but it was solving a finer-grained problem than the
one that actually existed: nothing about this feature's real usage pattern
(occasional, small numbers of stuck reservations after a restart) needed
different stuck reservations to reconcile in parallel across workers. The
single lock converts the periodic case into "the startup sweep's own
function, just triggered by whichever worker's timer gets there first" —
less code, and an OS-level `flock` gets crash-safety for free (released the
instant the holding process's file descriptor closes, for *any* reason)
where the per-reservation claim needed manually-maintained staleness logic
to get the same property.

**3. Graceful exit handler** (prevention, not cure — closes the gap the
other two only clean up after). Given how routinely `app-server` gets
restarted *on purpose* in this repo's normal workflow, refusing new creates
and giving existing ones a bounded chance to finish reduces how often 1/2
even need to fire, for the one failure mode entirely under this codebase's
own control.

Verified against the actual installed `Mojo::Server::Prefork`/`Mojo::IOLoop`
source, not documentation guesswork: a **non-graceful** shutdown (`SIGTERM`/
`SIGINT` to the manager) kills every worker with `SIGKILL` immediately — no
grace period at all. Only a **graceful** shutdown (`SIGQUIT` to the manager)
sends each worker `SIGQUIT` and waits up to `graceful_timeout` (default
120s) before forcing. But switching to a graceful signal alone isn't
sufficient: `Mojo::IOLoop`'s own `stop_gracefully` waits only for accepted
*server-side connections* to close, and `create()`'s own handler returns its
HTTP response immediately (by design — the fast-ack-then-poll UX its own
header comment describes), so the connection that carried the original
`POST /containers/create` closes almost instantly and Mojo considers the
worker done **while the detached promise chain is still actively running**
on that worker's event loop. Mojo's graceful shutdown has no visibility into
work that outlives the request that started it.

The handler tracks in-flight `create()` chains (`Reservation->create_in_flight_count`)
and, on the worker's `finish` event, waits up to `appServer.shutdownGracePeriod`
(default 90s) for that count to reach zero before letting the worker actually
stop; the `/containers/create` route itself checks a `$shuttingDown` flag at
its own top and returns a clean `503` rather than starting a chain about to
be abandoned. `shutdownGracePeriod` is deliberately coordinated against
`Mojo::Server::Prefork`'s own `graceful_timeout` — raised from its 120s
default to 150s in `bin/app-server`'s own construction — so the exit
handler's bounded wait never races the manager's hard force-kill ceiling (60s
of headroom).

This only prevents the *deliberate-restart* case. A real crash, an OOM kill,
`-k`, or `graceful_timeout` itself expiring all bypass it entirely by
construction (nothing catches `SIGKILL`) — mechanisms 1/2 remain the only
backstop for those.

**Operational follow-on**: `app-server` ships its own `down-signal` file
(content `QUIT`), read by both a manual `s6-svc -r` and `s6-svscan`'s own
whole-container-shutdown cascade (`docker stop`, a host reboot) — the latter
bypasses a manual `s6-svc` invocation entirely, so it needed its own,
separately-verified mechanism to reach the same graceful path. `nginx`/
`docker-event-daemon` carry no `down-signal` file, so both still restart via
a plain `SIGTERM`, unchanged. `CLAUDE.md`'s restart matrix and every script
that restarts services (`dockside-self-update.sh`) use `s6-svc -r`
uniformly across all three for this reason — the one flag whose signal
`down-signal` actually governs, unlike `-t`/`-q`, which are hard-coded to
their one named signal regardless of any per-service file.

### Ground truth per stage

Each non-terminal stage has a real Docker-side signal to reconcile against —
no stage needs an ongoing "is this still happening" poll the way a live hook
`execId` does; every reconciliation below is a single synchronous check
followed by a one-shot action:

| `createStatus.stage` found | Reconciliation check | Safe action |
|---|---|---|
| `pulling` | `GET /images/{image}/json` | Present → proceed to `creating`. Absent → unconditionally re-`POST /images/create` (verified live: killing the client mid-pull genuinely aborts it server-side too — Docker does not keep pulling after the initiating connection drops — so no "pull already in progress" check is ever needed) |
| `creating` | `GET /containers/{name}/json` (the reservation's own container name) | Present → read its id, proceed to `starting` without re-creating (a blind retry here would `409` on the name collision — the one stage where "just retry" is actively wrong). Absent → re-run the create call |
| `starting` | none needed | Unconditionally re-`POST /containers/{id}/start` — already idempotent (a repeat start on an already-running container returns `304`, verified live) |

## Consequences

- A `create()` chain now survives every restart shape this codebase
  actually exercises: a whole-process restart (sweep), a single worker dying
  under its siblings (periodic reconciler), and a deliberate, in-repo-normal
  restart (graceful exit handler) — proven by
  `t/integration/tests/18_create_restart_recovery.py`, which kills
  `app-server` mid-pull (single and four-concurrent) via a genuinely
  non-graceful `s6-svc -t` and confirms every reservation still reaches
  `done`. That test deliberately keeps `-t`, not the now-documented `-r`,
  specifically because its job is proving recovery from a non-graceful kill
  standing in for a real crash/OOM — `-r` is graceful for `app-server` now,
  so only `-t` still exercises that worst case.
- Reconciliation is invisible to a polling client by design: a stuck
  `createStatus.stage` starts moving again (or flips to `failed` with a real
  reason) the same way it would have if the original worker had simply
  lived — no new `createStatus` shape.
- Retry is unbounded on the periodic reconciler's own interval, by
  deliberate choice — a reservation that can't reconcile is symptomatic of
  something wrong with Docker itself (which would be blocking everything
  else too), not something to silently paper over as `failed` after some
  arbitrary number of attempts.
- `%inFlight`-style bookkeeping (`Reservation->create_in_flight`/
  `create_in_flight_count`) lives in `Reservation.pm`, not as a
  `bin/app-server`-side lexical as originally sketched: `Reservation.pm` is
  the only code that actually observes a chain's start/settle moments, and a
  daemon-side hash would have needed a second callback threaded through
  `User::createContainerReservation`'s own unrelated signature purely to
  signal in/out, for no benefit over owning it where the lifecycle already
  lives.
- `create()`'s own body is a set of unconditionally re-enterable
  `_create_stage_*` functions (including the `creating` stage's
  ground-truth-by-name check, which now runs on *every* create, not only a
  recovery path) chained by stage-specific `_create_run_from_*` glue —
  `create()` always starts at `_create_run_from_pulling`,
  `reconcile_create()` starts wherever `createStatus.stage` says. This was
  the only way to avoid a second, parallel copy of the pull/create/start
  logic existing solely for recovery.

## Alternatives considered

- **Port `docker-event-daemon`'s startup-sweep-only pattern as-is.**
  Rejected: covers only the whole-process-restart granularity; a
  single-worker death under `Mojo::Server::Prefork` is a distinct, real
  failure shape with no equivalent in a single-process daemon, and would go
  silently unrecovered.
- **Per-reservation atomic claim for the periodic reconciler** (mirroring
  `hook_claim_if_not_running` exactly). Worked, but solved a finer-grained
  problem than the real usage pattern needed — see Decision above. Replaced
  by the single process-wide lock.
- **Skip the graceful exit handler; rely on the sweep/reconciler alone.**
  Rejected: given how routinely this repo's own workflow restarts
  `app-server` on purpose, that would leave the common case paying the full
  cost (however many minutes until the periodic reconciler's next tick,
  every time) of a failure mode that's otherwise entirely avoidable.
- **Leave `app-server`'s restart on `-t`/`-q` (fixed-signal) rather than
  introducing `down-signal` + `-r`.** Rejected once the graceful exit
  handler existed to have a purpose: `-t` sends `SIGTERM` unconditionally,
  which is the *worst* case for an in-flight chain (immediate `SIGKILL`,
  zero grace) — exactly what the graceful handler exists to avoid on a
  routine, deliberate restart.
