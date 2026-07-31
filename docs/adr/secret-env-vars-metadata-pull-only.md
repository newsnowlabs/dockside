# ADR: Secret-flagged env vars are metadata-pull-only, never auto-injected

- **Status:** Accepted — sequenced after `claude/secrets-encryption-users-json-zghgcl`
  and a metadata-server env-fetch endpoint; not yet implemented on this branch.
- **Date:** 2026-07-31 (revised: replaced the source-IP-matching / per-reservation-
  volume transport sketch with a single shared Unix socket and token-based
  reservation lookup, once the volume approach was found impossible — Docker
  cannot attach a new mount to an already-running container, and the Dockside
  server is one long-lived container serving many devtainers created after it)
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

### Transport: a single shared Unix socket, not per-reservation volumes or HTTP(S)

The original sketch for this decision assumed the existing IP-matching
transport (`App::Metadata.pm`, reached over the network, identified by
matching the caller's source IP to a `Reservation`) would simply gain an
authenticated path. Working through the actual mechanics in conversation
surfaced two problems with extending it as-is, and a cleaner replacement:

- **A dedicated Unix socket per reservation, in a per-reservation volume,
  is not achievable.** Docker fixes a container's mounts at `docker create`
  time; there is no way to attach a new volume to an already-running
  container. The Dockside server is a single, long-lived container, started
  once — most devtainers it will ever serve are created *after* that. A
  volume per devtainer would need to be attached to the Dockside server's
  own, already-fixed mount set retroactively, which Docker doesn't support.
- **HTTP(S) over TCP carries real risk from a co-located attacker sharing
  the container's one network namespace**, independent of anything already
  covered by `ssh-session-identity-for-metadata-server.md`'s token. Checked directly: `CAP_NET_RAW` **is** in
  Docker's default capability set, so a root-capable session inside the
  same container can capture same-namespace traffic without needing any
  additional privilege — plain HTTP is fully exposed to this. HTTPS without
  hostname/CA verification (the practical situation for a request that
  can't reasonably present a certificate matching a public hostname)
  protects the payload against *passive* capture but not an *active*
  redirect: NAT/iptables-based interception needs `CAP_NET_ADMIN`, not in
  Docker's default set, but `/etc/hosts` tampering needs no special
  capability at all if the client resolves a hostname rather than
  connecting to a fixed address.

**Decision: the metadata server is reached over a single, fixed Unix
domain socket**, not per-reservation sockets and not TCP. `AF_UNIX`
sockets generate no network traffic at all — nothing for `CAP_NET_RAW`-based
capture to see, and no DNS/hostname resolution step for `/etc/hosts`
tampering to redirect — so this removes the transport-level risk
category outright rather than mitigating it. The socket is mounted into
the Dockside server once, at its own startup (a normal, static volume
declaration, no retroactive mounting needed), and into every devtainer as
each is created (unaffected by the constraint above, since a devtainer's
own mounts are decided fresh at its own creation time — Dockside already
does this for other shared volumes). `nginx`'s native `listen unix:/path;`
support lets the same `App::Metadata::handle` logic serve this listener
alongside its existing TCP one — additive, not a rearchitecture.

**Because one socket now serves every devtainer, the metadata server can no
longer infer which reservation is asking from the connection itself** —
the IP-matching mechanism this ADR originally assumed doesn't carry over
(all requests now arrive from the same socket, not distinguishable
source addresses). `SO_PEERCRED` (the kernel-supplied peer pid/uid/gid on
an `AF_UNIX` connection) was considered as a replacement and rejected for
now: its `pid` field is reported relative to the *receiving* process's own
PID namespace, and the Dockside server runs in its own, separate namespace
from every devtainer (checked: `docker-compose.yml` sets no `pid: host` or
equivalent) — so the pid comes back unresolvable as things stand. Making it
usable would mean granting the Dockside server visibility into the host's
entire process list, a real, additional privilege grant, for a mechanism
that — even then — would only identify *which container*, requiring a
further cross-reference against `dockerd`'s own container/PID accounting to
be useful at all.

**Instead: reservation identity rides in the same token `ssh-session-identity-for-metadata-server.md` already
mints**, which now carries `reservation_id` alongside `account`. The
metadata server treats `reservation_id` as an **untrusted lookup key** —
like a JWT's `kid` header — used only to select which reservation's signing
secret to check the token's HMAC against; the request is trusted only if
that verification succeeds. A forged `reservation_id` buys an attacker
nothing, since they can't produce a valid signature for a key they were
never issued. This requires no new mechanism beyond what `ssh-session-identity-for-metadata-server.md` already
builds — reservation identification and account identification are both
answered by the same verified payload. For `ide`-originated requests (no
SSH/dropbear involved), `Reservation::exec` mints a reservation-scoped-only
token the same way, over the same existing `docker exec` env-injection
mechanism already used for `AUTHORIZED_KEYS`/`SSH_AGENT_KEYS` — no account
field, consistent with `shared-devtainer-env-var-disclosure.md`'s still-open limitation that individual
accounts can't be distinguished inside a shared IDE process.

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
  shared devtainer) is **partially** solved by this decision, and only for
  `ssh`. With `ssh-session-identity-for-metadata-server.md`'s token in place, the metadata server can scope its
  response to the actual connecting account rather than always the
  reservation owner, for SSH-originated requests — real per-account
  isolation, not just per-container. For `ide`-originated requests, it is
  **not** solved: there is still no per-account signal inside a shared IDE
  process (`shared-devtainer-env-var-disclosure.md`'s limitation), so any developer with IDE access to a
  shared devtainer can still pull the owner's secret vars via the same
  reservation-scoped-only token every IDE session gets. Either way, this
  decision removes *passive/ambient* disclosure (nothing appears in `env`,
  terminal history, or a log unless explicitly fetched) and — for `ssh` —
  a real per-account boundary; the residual gap is exactly, and only, the
  `ide` case `shared-devtainer-env-var-disclosure.md` already names as an accepted, disclosed limitation.
- `App::Metadata.pm`'s existing `# FIXME` about hardening beyond
  `Metadata-Flavor` header + no-XFF + source-IP matching is **superseded**
  by this ADR's transport decision, not merely made more urgent: the
  Unix-socket-plus-token design replaces source-IP matching entirely (the
  socket carries no meaningful source address to match in the first place),
  so implementing the new path retires this FIXME rather than needing to
  separately harden the mechanism it was written about.
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
- **A dedicated Unix socket (and volume) per reservation.** The first
  sketch of the socket idea. Rejected as impossible, not just suboptimal:
  Docker cannot attach a new volume to an already-running container, and
  the Dockside server is a single long-lived container whose own mount set
  is fixed at its startup, long before most devtainers it will ever serve
  are created.
- **`SO_PEERCRED` for reservation identification over the shared socket.**
  Considered and rejected for now. Its `pid` field only resolves within the
  receiving process's own PID namespace; the Dockside server currently
  shares none with its devtainers (checked: no `pid: host` in
  `docker-compose.yml`). Enabling it would mean granting the Dockside
  server host-wide process visibility — a real, additional privilege, for a
  mechanism that would still only identify *which container*, not *which
  account*, and would still need a further lookup against `dockerd`'s own
  container/PID records to be useful. The token-based approach (adopted)
  achieves the same result with no new privilege grant, reusing
  infrastructure `ssh-session-identity-for-metadata-server.md` already builds for the account-identification
  problem.
- **Keep source-IP matching, just add an auth header.** Superseded rather
  than extended: once every devtainer reaches the metadata server through
  one shared socket instead of distinguishable network addresses, there is
  no meaningful source address left to match against — the transport
  change and the identification change had to happen together.
- **HTTP(S) over TCP to a fixed or well-known address.** Would have been
  the natural incremental step from the original IP-matching design, and
  was seriously considered. Rejected in favor of the Unix socket once the
  capability analysis above showed plain HTTP is realistically sniffable by
  a co-located attacker under Docker's *default* capabilities (`CAP_NET_RAW`
  is granted by default) and that HTTPS without hostname verification only
  protects against passive capture, not an active redirect via `/etc/hosts`
  tampering (which, unlike NAT-based redirection, needs no elevated
  capability). The Unix socket removes the entire risk category instead of
  mitigating pieces of it.
