# ADR-0008: Live-reservation router add/remove/replace

- **Status:** Implemented
- **Date:** 2026-08-20
- **Deciders:** Struan Bartlett

## Context

A Profile's `routers` array is embedded wholesale into a Reservation's `profileObject` at launch
(`Reservation::profile()`) and persisted as a frozen-at-launch snapshot — editing the master
Profile afterwards never touches an already-launched reservation's copy. Until now there was no
mutator for that copy's `routers` array at all: the only existing per-router mutation was the auth
*level* on an already-declared router (`meta.access`).

The gap this closes: a devtainer owner (or other permission-holder) has no way to expose a port for
an HTTP/HTTPS/websocket server the profile author never foresaw, or too ephemeral to be worth
coding into the profile — without an admin editing the master profile and relaunching. That should
be possible, subject to a permission the admin controls, the same way other per-container
capabilities in this codebase already are.

## Decision

**Primitives: add, remove, and a same-name replace.** Add and remove are the two real primitives;
replace is a thin, atomic remove+add under one lock, justified only because a bare two-call
remove-then-add would orphan `meta.access[name]` (keyed by router name) for the common
in-place-edit case (bump a port). `replace` needs no permission beyond holding both
`addContainerRouter` and `removeContainerRouter` — it isn't a separate capability.

**Permission model — two axes, not per-router admin flags:**
1. Role-level: two new `@CONTAINER_PERMISSIONS` entries, `addContainerRouter` /
   `removeContainerRouter`, derived/checked exactly like every other container permission.
2. Reservation-level standing: both gated on `can_on($reservation, 'develop')` — true for the
   owner unconditionally, or a named developer who also holds `developContainers` — the same
   two-part shape `viewers`/`developers`/`private`/`access` already use.
3. Profile-level opt-in, **add only**: a new top-level `Profile` boolean, `userRouters`. Off by
   default. `role eq 'admin'` bypasses it by default (only an explicit per-account permission
   denial blocks an admin) — the same admin-bypass shape `has_permission` already has everywhere
   else. Add and remove are not symmetric here: adding introduces surface area the profile author
   never reviewed (a new public prefix, a new private port); removing only touches something
   already reviewed and present. So **remove has no profile-level gate at all** — permission +
   developer standing is the whole story for it.
4. One absolute, non-configurable exception, applying even to admins: a router of type `ide` or
   `ssh` can never be removed through this feature. Both are auto-injected into every profile
   unconditionally; the existing `ssh` profile toggle and `meta.access` are the correct levers for
   that axis already.

**Origin tracking: `type=user`, not a separate property.** A router added through this feature is
stamped `type => 'user'` server-side (overriding anything the caller sends). This is provenance
labelling only — removability does not depend on it; any router (admin-authored or `type=user`) is
removable once permission + developer standing hold. If more self-service flavours are ever
needed, `user:<subtype>` is available without a schema change.

**No per-router "is this one user-removable" flag.** An early draft had one (`userManaged`,
modelled on `hooks[name].manual`, letting an admin opt a *specific* declared router into
removability). Dropped on review: `hooks[].manual` gates a genuine per-item *operational safety*
property (a hook can perform non-idempotent, one-time setup — re-running it is a real,
item-specific risk). Removing a router has no equivalent risk — nothing running is touched, and
it's fully reversible via add/replace — so a `userManaged`-shaped flag would just re-decide the
same trust question `removeContainerRouter` + `can_on(develop)` already answers, not gate a
distinct safety concern. An admin who wants a router unremovable-by-developers already has the
right lever: don't grant the permission, or reconsider who's a named developer.

**`meta.access[name]` must be set explicitly, in the same transaction as the array push.** Two
independent places read a router's access level, and only one defaults a missing entry:
`Reservation::routers()` (live proxy routing) defaults to `'owner'`, but `cloneWithConstraints`
(everything sent to any client) has no fallback and silently drops a router with no `meta.access`
entry from every client payload — live and proxyable, but invisible everywhere. Caught live via
manual DB-surgery testing before the real code path existed; the actual `add_router` sets
`meta.access[name]` as part of the same locked write, not a second step a caller could omit.
`remove_router` deletes the now-orphaned entry; `replace_router` carries it forward when the name
is unchanged and still legal under the router's (possibly narrowed) `auth` list.

**Who decides the initial `meta.access[name]` value, and who decides the `auth` allow-list —
`User.pm`, not `Reservation::Mutate`.** `Reservation::Mutate` has no identity or policy concept at
all; it only mutates on-disk data under a lock. Two inputs this feature needs — the router's
`auth` allow-list, and the initial access level to assign — are therefore always resolved by
`User.pm` before it ever calls down into `Reservation::add_router`/`replace_router`, and passed as
explicit values: `auth` defaults to every known level
(`Reservation::known_router_auth_levels()`) unless the caller narrowed it via `--auth`; the initial
access level defaults to `'owner'` if the caller owns the reservation, else `'developer'` (the
narrowest level that still includes a non-owner caller, who by construction already holds
developer standing) — overridable via an explicit `--access`. `Reservation::Mutate` and
`Reservation::normalise_router_def` only *validate* these two already-resolved values are
mutually consistent (the access level is a member of the auth list); they never choose either one.
This keeps the owner/developer distinction — a caller-identity concern — entirely out of the
data-mutation layer, where nothing else needs to know who's asking.

This is deliberately not applied to `User::set()`'s own pre-existing 'access' branch (the
profile-declared-router launch-time default, "first entry of the router's `auth` list") — at
launch there's only ever one possible actor (the launcher, who instantly becomes the owner), so an
owner/developer-aware rule there would just always resolve to `'owner'`, silently overriding
whatever order a profile author chose by listing `auth` entries in a particular sequence. That
existing convention is left untouched; the actor-aware default is specific to this feature's
self-service add/replace.

**`--auth` also accepts a caller-supplied initial `--access` value, and a comma-separated list.**
The CLI's `--auth` flag can be repeated, given a comma-separated value, or both, rather than
forcing one call per level. A separate `--access` flag lets a caller override the owner/developer
default outright, still validated against the (possibly narrowed) `auth` list. The flag stays
named `--auth`, matching the underlying `auth` field name in the router/profile JSON schema,
rather than a possibly-clearer alternative like `--access-levels` — favouring schema/CLI
consistency over a marginal naming improvement.

**Concurrency: transform under the lock, never blind-overwrite from a stale snapshot.**
`cloneHash` (the merge primitive behind `store_fields`) only merges HASH-vs-HASH pairs — `routers`
is an array, a pure leaf overwrite. Computing a new array in the request process and writing it
back would lose a concurrent second add. Instead, `add_router`/`remove_router`/`replace_router`
each run their whole read-validate-mutate-write cycle inside `Reservation::Mutate`'s own `flock`,
against the freshly-reread on-disk record — the same shape `increment_data_field` already
established for this class of problem. Permission/profile-gate checks happen once in `User.pm`,
before the lock; only the array mutation itself, plus the absolute `ide`/`ssh` block, needs the
lock's protection.

**Validation, including a stricter bar than the profile loader itself uses.** No existing code
rejects a colliding router prefix/domain/protocol within a profile — `Reservation::routers()`'s own
lookup table is a silent last-write-wins hash, tolerable for a trusted admin's static file.
Self-service input gets a real collision check instead of silently shadowing an existing route.

**gatewayMode: reject `add` outright, unconditionally.** gatewayMode publishes Docker ports only at
container-create time, so a new router's port may not be reachable without a full recreate. Rather
than a publish-check-and-warn path, `add` simply fails closed with a clear error when
`$CONFIG->{gatewayMode}` is set — gatewayMode is deprecated and this feature isn't worth extra
complexity there. `remove`/`replace` are unaffected.

## Consequences

- A router add/remove/replace, once persisted, takes effect on the very next proxied request —
  `Proxy.pm` reloads `reservations.json` (mtime-checked) on every request, so none of the three
  services need restarting for this feature specifically (unlike editing a Profile *file*).
- New permissions (`addContainerRouter`, `removeContainerRouter`) need adding to any role that
  should grant them — existing roles get neither by default.
- Existing profiles are unaffected: `userRouters` defaults off, and the removal path has no new
  gate for admin-authored routers at all (permission + developer standing was already the bar for
  every other per-container mutation).
- This ADR covers the server API and CLI only. A Vue UI surface (devtainer edit-state controls,
  admin permission-screen entries) is a separate, independently-schedulable piece of work built
  on the same API — its design is not this ADR's concern, and nothing here depends on it existing.
- Listening-port autodetection (VS Code-style auto-forwarding) is an explicitly out-of-scope future
  extension; if built, it should call these same `add_router`/`remove_router` primitives rather
  than a separate code path.

## Alternatives considered

- **Per-router `userManaged` admin opt-in for removal** — rejected; see Decision above.
- **Warn-and-succeed in gatewayMode** (return success with a "may need a restart" caveat) —
  rejected in favour of a hard, simple rejection, given gatewayMode's deprecated status.
- **Folding add/remove/replace into the existing `/containers/:id/update` endpoint** (as a
  `routers` field, whole-array replace) — rejected: add/remove are two distinct permissions, a
  router definition has enough shape to want its own request body, and a whole-array replace from
  the client reopens exactly the concurrency hazard the locked-transform design avoids.
