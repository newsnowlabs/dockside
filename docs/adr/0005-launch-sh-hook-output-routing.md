# ADR-0005: `launch.sh`'s hook/launch-stage output routing — caller-visible by default

- **Status:** Implemented
- **Date:** 2026-08-16
- **Deciders:** Struan Bartlett

## Context

`docker-event-daemon`'s launch DAG (`launch:prep` → `launch:git`/`launch:ide`,
`lifecycle:launch` → `lifecycle:start`) and on-demand hook runs (`dockside hook run`,
`Reservation::run_hook_manual`) both dispatch into `app/scripts/container/launch.sh` via
`docker exec`, and both rely on `Reservation::dispatch_hook_exec`/
`docker-event-daemon::_launch_dispatch_exec` capturing that exec's real stdout/stderr into a
host-side `logPath` file — the same file `load_hook_log`/`dockside get`/the Vue UI's `Show log`
all read back.

`launch.sh` also keeps its own durable, in-container trace: `$LOG`
(`/tmp/dockside/launch-<uid>.log`), everything `log()` narrates, spanning every invocation for
that UID over the container's whole life.

Before this change, `init()` unconditionally redirected the process's real fd 1/2 into `$LOG`
(saving the true originals as fd 3/4), and only two call sites explicitly routed output back
to fd 3/4 to reach the host: `launch_prep`/`launch_git`'s entire invocation (`eval "$@" 1>&3
2>&4`), and `run_hook`'s own `"$SCRIPT" 1>&3 2>&4` around just the invoked hook script. Every
other `log()` call — including `run_hook`'s own pre-flight diagnostics ("script not found or
not executable", "hook already running") — went to fd 2, which by then meant `$LOG` only.

This was found live: a `lifecycle:launch` hook whose script was missing on disk failed with
exit code 1 and a host-side hook log containing **zero bytes** — `run_hook`'s "not found"
`log()` line was real, but it only ever reached `$LOG`, invisible without a `docker exec` into
the devtainer itself. The bug wasn't specific to that one message; it was that host visibility
was an *opt-in allow-list* (`launch_prep`/`launch_git`/the one line in `run_hook`) that had to
be kept in sync, by hand, with every dispatch shape docker-event-daemon's DAG and
`run_hook_manual` could produce — and nothing enforced that sync. Any future pre-flight
failure path, in any entry point, could reproduce the same silent-empty-log bug.

## Guiding principle

Dockside-initiated logs are captured and rendered by Dockside. Custom hooks straddle this
line — they're both Dockside-initiated (Dockside decides when they run and dispatches them)
and non-Dockside-authored (their content is the profile/hook author's own), except in the
narrow case of a custom hook written *for Dockside's own development* (`dockside-self-update.sh`
— see [`docs/extensions/lifecycle-hooks.md`](../extensions/lifecycle-hooks.md)'s "Dockside
switching its own branch" example), where Dockside is both initiator and author at once. Even
so, a custom hook is under its author's control: they can redirect any and all of its output to
a local file if they choose. `/tmp/dockside` isn't guaranteed persistent across container
restarts anyway — it may well be a tmpfs — so only the hook author truly knows where it's best
to write local logs if they want them kept at all. They're equally free to hide secrets from
Dockside's own log capture, the same way.

This is the principle the decision below follows: fd 1/2 default to caller-visible not because
every byte written there is safe to expose, but because deciding that is exactly the kind of
call only the content's own author — Dockside itself for its own narration, a hook author for
theirs — can actually make, and defaulting to `$LOG`-only (private) would have silently made
that call for them instead, in the wrong direction, every time someone forgot to opt a new
entry point in (see Context above).

## Decision

Flip the default: **fd 1/2 are never redirected**. They stay exactly what `docker_exec`
attached for this invocation — the real, caller-visible stream `dispatch_hook_exec`/
`_launch_dispatch_exec` capture for anything non-detached, or simply unread for `launch_ide`'s
`Detach:true` dispatch. `$LOG` becomes the opt-in side instead: `init()` opens one dedicated,
always-open fd 5 onto it, and `log()` writes every line to both fd 2 (the real stream) and fd 5
(`$LOG`) unconditionally.

This removes the allow-list entirely — `launch_prep`/`launch_git`'s blanket `eval "$@" 1>&3
2>&4` and `run_hook`'s targeted `"$SCRIPT" 1>&3 2>&4` are both gone, replaced by plain
dispatch/invocation, since fd 1/2 already carry the right semantics for every entry point
without per-function classification.

**One deliberate exception:** `init()`'s `$DEBUG`-gated environment dump (`busybox env | sed
...`) writes to fd 5 only, never fd 2. Unlike everything else `log()` narrates, this dumps the
*entire* environment verbatim — including secrets Dockside itself injects into every
hook/launch-stage exec (`GH_TOKEN`, `GIT_URL`, any `DOCKSIDE_OPTION_*` a profile author put a
secret in — see `Reservation::_hook_env`). Nothing server-side ever sets `$DEBUG`; it's a
manual flag someone with direct docker/host access sets when hand-running `launch.sh` via
`docker exec` (or the `debug` dispatch verb). Defaulting the dump to caller-visible just
because `DEBUG` is on would leak it to the whole `develop`-permitted set on that devtainer
instead (`can_on($container, 'develop')`, `User.pm`: the owner, any user/role named in
`developers`, and anyone with the broader `developAllContainers` permission) — a different,
usually less-trusted audience than whoever has docker/host access to set `DEBUG` in the first
place.

Custom hook scripts' own raw output follows the guiding principle above directly: `launch.sh`
no longer makes the private-vs-caller-visible call on the author's behalf by defaulting it to
`$LOG`-only. See `docs/extensions/lifecycle-hooks.md`'s "What the hook script can rely on" for
the author-facing statement of this.

## Consequences

- The bug class that motivated this is now structurally prevented, not just patched at the one
  site it was found: any new `log()` call, in any current or future entry point, is
  caller-visible by construction — there is no list to forget to update.
- `$LOG` is no longer a strict superset of what a caller sees. Raw (non-`log()`) command output
  — e.g. a custom hook script's own `npm run build` chatter — reaches the caller-visible stream
  only; it is not automatically duplicated into `$LOG`. Given `$LOG` was never guaranteed
  durable in the first place (`/tmp` may be tmpfs-backed per profile), and the host-side hook
  log already reliably persists exactly that content for the caller, this is judged an
  acceptable trade rather than a regression worth a `tee` (see Alternatives).
- Raw, unlabelled output from any future `launch.sh` code is caller-visible by default. Any
  call site that would print something genuinely sensitive (the `$DEBUG` dump today; anything
  similar added later) must deliberately opt out to fd 5, the same way the `$DEBUG` dump does —
  there is no automatic redaction.
- `launch_nonroot`'s `su`-spawned child (a fresh top-level `launch.sh` invocation) now
  transparently inherits the correct fd 1/2 across the `su`/`env` boundary with no special
  handling, and picks up its own fd 5/`$LOG` handle via its own `init()` call — as a side
  effect, the non-root continuation's own `log()` narration (previously `$LOG`-only, invisible
  to the host under the old scheme) now reaches the host too.

## Alternatives considered

- **Keep `$LOG` as the default, make host-visibility the opt-in** (the first shape proposed
  during this work): `init()` classifies which dispatched function name is "host-observed"
  (`launch_prep`/`launch_git`/`run_hook`) and only those get an `eval ... 1>&3 2>&4`-style
  wrapper; `log()` stays fd-2-only, `$LOG`-bound. Rejected: this is the same allow-list shape
  that caused the original bug, just with one fewer gap closed — a new DAG stage or dispatch
  path added later still has to be remembered and added to the classification list, or its
  `log()` output silently vanishes from the host again.
- **`tee` raw script output to both destinations.** Would make `$LOG` a true superset again.
  Rejected for the added complexity in a POSIX `sh` script with no `PIPESTATUS` (getting the
  invoked script's real exit code back out through a pipeline needs an extra temp-file/fd
  dance), for merging stdout/stderr into one stream before `docker_exec`'s frame-typed demuxer
  ever sees it (losing a distinction it currently preserves), and because the benefit — a
  second, redundant copy of content the host-side hook log already persists — was judged not
  worth either cost.
