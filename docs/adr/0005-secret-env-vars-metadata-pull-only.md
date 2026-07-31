# ADR-0005: Secret-flagged env vars are metadata-pull-only, never auto-injected

- **Status:** Accepted — sequenced after `claude/secrets-encryption-users-json-zghgcl`
  and a metadata-server env-fetch endpoint; not yet implemented on this branch.
- **Date:** 2026-07-31
- **Deciders:** Struan Bartlett

## Context

`claude/user-env-vars-6cs63v` added per-user custom env vars (`User.pm`'s `env`
field: `{ KEY: { value, secret, targets: { docker, ide, ssh } } }`), with three
delivery mechanisms Dockside performs automatically on the user's behalf:

- **`docker`** — baked into `docker create` via `Reservation::Launch::cmdline_user_env`.
- **`ide`** — bundled into the `DOCKSIDE_USER_ENV` blob on the `docker exec` that
  launches the IDE (`Reservation::exec`), written to a file by `launch.sh`'s
  `populate_user_env`, and exported into the IDE process's environment by
  `apply_user_env` (surviving the `env -i` allowlist wipe).
- **`ssh`** — the same blob's `ssh` half, written to a file and sourced via a
  marker-guarded `.bashrc`/`.profile` snippet (`install_user_env_notice`) so it
  reaches SSH login shells.

All three mechanisms apply uniformly regardless of the `secret` flag — a
`secret=true` var is masked in API *output* only; internally it is delivered
exactly like a non-secret one. A PR review against this branch (Codex,
newsnowlabs/dockside#45) found and this branch fixed several concrete
consequences of that: `apply_user_env` exporting secret values into a process
whose launch script then dumped the full environment to a log file
(`f6ae71a`, `b89a3bf`), `echo`'s shell-dependent backslash interpretation
risking value corruption on the way into a file (`25403da`), and validation
gaps letting malformed values reach those delivery paths. Fixing each
mechanism's leak surface individually is the reactive posture; this ADR is
about not needing to keep doing that.

Structurally, "auto-inject a secret value into files/process-env inside a
container" carries an irreducible category of risk that "store it, encrypted,
and hand it to a script that asks for it" does not: the latter never writes
the value anywhere Dockside doesn't fully control the lifetime of, and every
future leak vector this review might have missed (a new IDE version's log
dump, a new debug flag, a backup job that snapshots `$HOME`) simply cannot
expose a value that was never placed on the container's filesystem or in a
process environment table Dockside doesn't own.

Dockside already has the mechanism for pull-based delivery:
`App::Metadata.pm`, routed to by `Proxy.pm::get_server_port` for requests with
no `X-Forwarded-For` and a `Metadata-Flavor: Google` header, authenticated by
matching the caller's source IP to a live `Reservation`. It currently serves
`hostname`/`fqdn`/a profile-defined `startup-script` attribute — no secrets.
`claude/secrets-encryption-users-json-zghgcl` is separately adding
application-level encryption at rest for `users.json`, which this decision
depends on: there is little point moving secret vars to a pull-only model if
they're still sitting in `users.json` plaintext at the other end.

## Decision

**A `secret=true` env var is never delivered by Dockside into `docker`,
`ide`, or `ssh`.** It is stored (encrypted, once the encryption-at-rest
branch lands) and retrievable only by an authenticated request to the
metadata server. Responsibility for getting the value from the metadata
server into a running shell or process — writing a login-shell snippet, an
IDE task, whatever — belongs to the user or admin who set the variable, not
to Dockside.

Concretely, once the encryption-at-rest and metadata-server work land:

- `User.pm::env_vars_for_target` excludes `secret=true` entries, so
  `cmdline_user_env` and `Reservation::exec`'s `DOCKSIDE_USER_ENV` builder
  never see them regardless of `targets`.
- `User::Manage::_validate_env_vars` rejects `secret=true` combined with
  `targets.docker=true` outright — this combination is not merely
  discouraged, it is **structurally impossible** under a pull model (a
  process cannot fetch its own initial environment from an HTTP endpoint
  before it exists to make the request). Whether `ide`/`ssh` targets are
  similarly rejected on a secret var (rather than silently accepted but
  inert) is an implementation decision for whoever picks this up — reject is
  preferred, so the API/UI never lets a user configure a target that can
  never fire.
- `App::Metadata.pm` gains an authenticated path returning the requesting
  reservation's owner's env vars (secret and non-secret both — the pull
  interface should be uniform, even though non-secret vars are *also*
  auto-pushed; a script fetching "my vars" shouldn't need to know which ones
  Dockside already delivered another way).
- `EnvVarsEditor.vue` disables the docker/ide/ssh checkboxes when `secret` is
  checked and explains the metadata-server retrieval path in their place.

**Non-secret vars keep the existing push mechanisms as built and hardened by
this branch.** This is not a wasted-work concern: unmarked-secret values
(feature flags, non-sensitive config) are very likely the majority real-world
case, and the push path is now the well-tested one.

## Consequences

- The `docker`/`ide`/`ssh` delivery code built and hardened on this branch is
  **not discarded** — it becomes the non-secret-only path, which is most of
  its exercised surface today anyway (the existing integration tests in
  `t/integration/tests/14_user_env_vars.py` don't specifically exercise
  secret values *through* docker/ide/ssh delivery; they test masking/storage
  behavior separately).
- The "docker inspect can see anything baked into `docker create`" warning
  already added to `EnvVarsEditor.vue` becomes moot for secrets specifically,
  since secrets can no longer target `docker` at all — it remains relevant
  for non-secret docker-target vars, which are unaffected by this ADR.
- The multi-user-sharing question (who else can retrieve a secret from a
  shared devtainer) is **not** solved by this decision. The metadata server
  authenticates by reservation IP, a per-*container* grain, not per-account —
  any developer with legitimate SSH/IDE access to a shared devtainer can pull
  the owner's secret vars from the metadata endpoint exactly as they could
  read an auto-populated file today. This decision removes *passive/ambient*
  disclosure (nothing appears in `env`, terminal history, or a log unless
  explicitly fetched) and opens the door to an audit trail (log each metadata
  fetch) and a future per-connection identity layer (see
  `docs/plans/profile-user-env-vars.md`), but does not by itself restrict
  *who* can obtain the value within a shared devtainer's authorized set.
- `App::Metadata.pm`'s existing `# FIXME` about hardening beyond
  `Metadata-Flavor` header + no-XFF + source-IP matching becomes materially
  more important once the endpoint serves actual secrets rather than a
  hostname — this should be addressed as part of implementing the new path,
  not deferred again.
- Test coverage needs reworking: `EnvVarsInjectionTests` in
  `t/integration/tests/14_user_env_vars.py` should gain a case asserting a
  `secret=true` var is *never* observable via `docker exec`/IDE-process-env/
  SSH-session-env regardless of its `targets`, plus new coverage once the
  metadata endpoint exists.

## Alternatives considered

- **Keep auto-injecting secrets everywhere, rely on hardening.** What this
  branch did before this ADR. Rejected as the long-term posture — it's an
  open-ended commitment to finding and fixing every future leak vector
  individually (log dumps, debug flags, backup jobs, the next IDE version),
  rather than removing the category of risk once.
- **tmpfs-back the container-side delivery files instead.** Real mitigation
  (see `docs/plans/profile-user-env-vars.md` for the precedent — `~/.ssh` is
  already tmpfs-mounted in shipped example profiles for the same reason) but
  it's opt-in per profile today, and forcing it universally means either
  hardcoding an unconditional tmpfs mount regardless of profile config or
  requiring profiles to declare one — a real behavioral change to force on
  every profile, and it still leaves the value sitting in a process
  environment / file for the container's lifetime, just not persisted across
  restarts. Doesn't eliminate the leak surface the way pull-based delivery
  does; potentially still worth doing for non-secret files as hygiene, but
  it's not a substitute for this decision.
- **Encrypt in transit but keep pushing.** Doesn't address the actual risk,
  which is values sitting in a container's writable filesystem or process
  table at rest, not values in flight to get there.
