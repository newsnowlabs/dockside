# ADR: Per-user devtainer accounts and IDE processes — a long-term alternative to session-scoped identity machinery

- **Status:** Proposed — a considered long-term direction, not a decision to
  build now. Does not block or supersede `secret-env-vars-metadata-pull-only.md`/
  `ssh-session-identity-for-metadata-server.md`, which remain the near-term plan.
- **Date:** 2026-07-31
- **Deciders:** Struan Bartlett (direction proposed; adoption not yet decided)

## Context

`ssh-session-identity-for-metadata-server.md` builds real, if unusual,
machinery — two dropbear patches, a bundled Landlock sandbox with a
fail-closed startup check, an HMAC-based identity token, a live
authenticated query to the outer Dockside server — entirely to simulate
per-identity isolation within one shared Unix account (`$IDE_USER`), which
every collaborator on a shared devtainer lands as regardless of which
Dockside account they authenticated with. All of that complexity exists
because ordinary Unix DAC has nothing to say once two sessions share a UID.

Raised as an alternative worth working through properly: what if
collaborators didn't share a UID at all? Give each one a real, separate
Unix account (and, further, a separate IDE process) inside the shared
devtainer, and the entire category of problem `ssh-session-identity-for-metadata-server.md`
exists to compensate for stops needing compensation — it reverts to
standard, well-understood, already-battle-tested Unix multi-user security.

## What this fixes categorically, not just adequately

This distinction matters: some of what `ssh-session-identity-for-metadata-server.md`
builds is *working around* a structural gap in the single-shared-account
model, not filling an implementation gap within it. No amount of further
refinement to that approach can close those specific gaps, because they
aren't shortfalls in the mechanism — they're consequences of the
architecture the mechanism has to operate inside. Separate accounts close
them because the gap they're built around stops existing:

- **SSH identity** — dropbear already natively supports multiple accounts
  authenticating via their own respective keys; this is ordinary SSH server
  behavior, not something Dockside has to build. `$LOGNAME` inside the
  session already *is* the answer, vouched for by the OS itself via the
  actual account switch — no minted token, no live query, no HMAC needed
  for this purpose at all.
- **`/proc/<pid>/environ` cross-session reads** — now genuinely different
  UIDs. Cross-UID ptrace access requires `CAP_SYS_PTRACE`, confirmed absent
  from Docker's default capability set (`ssh-session-identity-for-metadata-server.md`'s
  research). This is a *structural* guarantee, not a bundled sandbox
  Dockside has to keep working and rebasing.
- **Agent-forwarding socket isolation** — ordinary Unix socket permissions
  correctly separate per-account sockets once accounts genuinely differ.
  The `SO_PEERCRED`-plus-ancestry-walk patch becomes unnecessary.
- **Filesystem-persisted secrets** — the one gap `ssh-session-identity-for-metadata-server.md`
  explicitly could not close (its own Consequences: "ordinary DAC file
  permissions offer no protection at all when every collaborator is the
  same UID"). A `0600` file under a real per-account `$HOME` is correctly
  protected by DAC that was structurally powerless before. No version of
  the token/Landlock approach, however refined, closes this — it isn't
  about SSH.
- **The IDE-sharing problem** (`shared-devtainer-env-var-disclosure.md`'s
  entire subject) — closeable too, but only with the second half of this
  model: separate IDE *processes*, not just separate accounts. See below.

## Two separable levels of adoption

Worth treating as genuinely distinct, not an all-or-nothing choice:

1. **Separate accounts, one shared IDE process still.** Closes everything
   SSH-related above, and the filesystem-secrets gap, without touching IDE
   launching, proxying, or per-user resource allocation at all.
   Meaningfully smaller than full multi-IDE, and a serious, self-contained
   option on its own.
2. **Separate accounts *and* separate IDE processes.** Additionally closes
   `shared-devtainer-env-var-disclosure.md`'s IDE-sharing gap, at real
   added cost (below). A single IDE server process is fundamentally
   single-user in its process model — it can't cleanly serve multiple
   distinct accounts with proper per-account isolation the way a
   multi-user SSH daemon can — so this level, not level 1, is what's
   actually required if closing the IDE gap specifically is the goal.

## What actually needs building

Checked against the current code, not assumed:

- **User provisioning becomes dynamic, not one-shot.** `create_user()`
  (`launch.sh:80`) today provisions exactly one account, guarded by "does
  `$IDE_USER` already exist" — a natural extension point, not a redesign,
  but a developer added *after* launch needs an account created into an
  already-running container. That means extending whatever already re-runs
  on relaunch/`restart_ide` cycles (the same point `update_ssh_authorized_keys`
  already re-runs at) to diff and create newly-added accounts, or a
  dedicated incremental "add-account" `docker exec` command.
- **UID stability across relaunches**, easy to get wrong silently: if a
  devtainer is recreated later and accounts get assigned UIDs in whatever
  order collaborators happen to reconnect, files on any persistent volume
  from before the relaunch end up owned by the wrong newly-assigned UID.
  UID-per-(reservation, account) needs to be deterministic — derived or
  recorded — not incrementally assigned as people happen to connect.
- **Per-user IDE instances (level 2 only) touch several subsystems.**
  Both `ide/openvscode/bin/launch-ide.sh` and
  `ide/theia/latest/bin/launch-ide.sh` hardcode `--port 3131` — confirmed
  by reading them — so `launch_theia`/`launch_openvscode` need a port
  argument instead. `Proxy.pm::get_server_port` already resolves the
  authenticated `$User` for every request (confirmed earlier in this
  project's research), so routing to the right per-user port is a natural
  extension of existing logic, not new machinery — but
  `docker-event-daemon`'s `restart_ide`-style dispatch needs to know
  *which* user's IDE it's restarting, not just "the" IDE, and the Vue
  client's current single IDE-status tile per reservation needs to become
  per-user (or lazy-launch-and-show-on-demand).
- **Resource overhead, quantified rather than assumed manageable.** A
  single Theia or openvscode-server instance easily runs 200–500MB+ RAM at
  idle before counting per-user language-server/extension-host children,
  which also multiply per instance. Three or four collaborators each with
  their own IDE is a plausible 1–2GB+ of pure redundancy on top of
  whatever the workload itself needs. Likely manageable for devtainers
  shared with a handful of people, as proposed — but profile memory
  limits would need to account for it explicitly, not assume it away.
- **Shared workspace relocation is close to required, not optional**, if
  genuine collaboration on the same code is the point: a repo nested under
  one user's `$HOME` isn't reachable by others without loosening that
  specific home directory (awkward — home dirs are conventionally `700`)
  or duplicating the checkout per account (defeats the purpose).
  Relocating to a neutral, group-owned path (e.g. `/dockside/workspace`,
  as sketched) is the right call. Two classic multi-user-shared-directory
  details worth being explicit about, since both bite silently if skipped:
  the directory needs the **setgid bit** (`chmod g+s`) so files
  collaborators create default to the shared group rather than each
  user's own primary group; and each session's **umask** needs to be
  group-write-permissive (`002`, not the usual `022`) or collaborators
  will constantly hit permission-denied editing files someone else most
  recently saved.
- **Role-based sharing (`meta('developers')`'s `role:<name>` tokens) is
  incompatible with this model as-is, and should be dropped.** Checked
  directly (`Reservation.pm:1094-1106`): `@usersHavingDeveloperRoles` is
  computed by checking `User->viewers` against `role:<name>` tokens in a
  reservation's `developers` field, meaning the authorized set for a
  reservation can grow or shrink purely from *someone else's role
  assignment changing elsewhere in the system* — with no edit to the
  reservation itself. That's fundamentally at odds with "provision N
  accounts up front" without also building a mechanism to react to
  role-membership drift, which is real, additional scope this ADR doesn't
  attempt to justify. Explicit, named developer sharing (a bounded, small,
  explicitly-managed list) is the right fit for per-account provisioning;
  role-based dynamic sharing is not, and should be removed if this model
  is adopted.

## A residual trade-off worth naming, not infrastructure

If a shared devtainer was ever valued for genuine live pair-programming —
multiple people in the *same* IDE window, seeing each other's cursors and
terminal output in real time — level 2 (separate IDE processes) loses
that. Each person gets their own, fully isolated editor now looking at
shared files on disk, not a shared live session. Worth confirming this
trade-off is acceptable before treating separate IDE processes as a
strict improvement over the status quo.

## What reopens if this is adopted

`secret-env-vars-metadata-pull-only.md`'s pull-only model for secret env
vars was a deliberate response to the single-shared-account architecture —
auto-injecting a secret was rejected specifically because any account with
access to a shared devtainer could read what was auto-injected for any
other. With real per-account isolation, that risk is gone: `launch.sh` (or
a per-account launch step) could safely auto-populate *that specific
account's* secrets into files or environment only they can read, reopening
auto-push as a safe option again — the capability
`secret-env-vars-metadata-pull-only.md` closed off could be reconsidered,
not just the delivery mechanism simplified.

## Decision

**Not adopted now. Recorded as the long-term direction Dockside's shared-
devtainer model should move toward, evaluated independently of, and
without blocking, `secret-env-vars-metadata-pull-only.md`/
`ssh-session-identity-for-metadata-server.md`.** Those ADRs describe a
smaller, more contained, already-substantially-designed piece of work,
concentrated mostly in one component (dropbear plus a metadata socket),
that delivers real value — correctly-scoped SSH secret delivery — sooner
than a cross-cutting provisioning/IDE-launching/proxying/UI project would.
This ADR is architecturally cleaner and closes strictly more (nothing in
it works around a gap the token/Landlock approach can structurally never
close), but it is a genuinely larger project, with real resource cost at
level 2 and a real UX trade-off if live shared editing is valued.

## Consequences

- If adopted later, `ssh-session-identity-for-metadata-server.md`'s two
  dropbear patches and Landlock wrapping become *removable*
  simplifications once real per-account identity exists — not wasted
  effort building them first. `secret-env-vars-metadata-pull-only.md`'s
  metadata-server socket and token concept would also get simpler (OS-
  verified account identity replaces a minted token) without needing to
  be re-invented from scratch.
- Level 1 (accounts only) is available as an intermediate step: closes the
  SSH-identity and filesystem-secrets problems without taking on the
  IDE-launching/proxying/resource cost of level 2, and could be adopted
  independently, ahead of a decision on level 2.
- Explicit developer sharing survives; role-based dynamic sharing does
  not, without additional scope this ADR doesn't cover (a mechanism to
  provision/deprovision accounts as role membership drifts independently
  of any edit to the reservation).
- Requires new engineering across `launch.sh` (dynamic provisioning, UID
  stability, workspace relocation/setgid/umask), `Reservation.pm`/
  `Reservation/Launch.pm` (dropping role-based developer resolution),
  `ide/*/bin/launch-ide.sh` and `Proxy.pm` (level 2 only: per-user ports
  and routing), `docker-event-daemon` (level 2 only: per-user IDE
  lifecycle), and the Vue client (level 2 only: per-user IDE status) —
  spread across substantially more of the codebase than
  `ssh-session-identity-for-metadata-server.md`'s dropbear-and-socket-
  concentrated scope.

## Alternatives considered

- **The session-scoped token/Landlock machinery already designed
  (`secret-env-vars-metadata-pull-only.md`/`ssh-session-identity-for-metadata-server.md`).**
  Smaller, more contained, already substantially designed, delivers value
  sooner — but structurally cannot close the filesystem-secrets or
  IDE-sharing gaps regardless of further refinement. Not rejected — this
  ADR's Decision explicitly keeps it as the near-term plan; recorded here
  as the comparison point this whole document evaluates against.
- **Level 2 without level 1** (shared accounts, separate IDE processes
  somehow scoped per connection) — not coherent: a single Unix account has
  no way to correctly attribute a specific IDE process, terminal, or file
  to one of several people sharing it, which is the same structural gap
  `ssh-session-identity-for-metadata-server.md` exists to work around in
  the first place. Separate IDE processes only make sense on top of
  separate accounts, not instead of them.
