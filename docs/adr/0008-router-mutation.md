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

**No per-router "is this one user-removable" flag.** A per-router `userManaged` admin opt-in
(modelled on `hooks[name].manual`, letting an admin opt a *specific* declared router into
removability) is not needed: `hooks[].manual` gates a genuine per-item *operational safety*
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
entry from every client payload — live and proxyable, but invisible everywhere. `add_router`
therefore sets `meta.access[name]` as part of the same locked write, not a second step a caller
could omit.
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
- The Decision above is the server API and CLI; the Vue components (see "UI implementation
  outline") are separate, independently-schedulable work that nothing here depends on.
- Listening-port autodetection and a metadata-server-driven self-service API (letting a process
  inside the devtainer itself request its own routers, e.g. an AI coding agent working in a
  worktree) are both out of scope for this ADR's implemented feature, but not for its design
  remit — see "Future work" below for both, including why autodetection is deferred rather than
  rejected outright. Either, if built, should call these same `add_router`/`remove_router`/
  `replace_router` primitives rather than a separate code path. The self-service path also depends
  on ADR-0009's token mechanism, layered on top of the metadata server's existing IP-based floor.

## Future work

### Listening-port autodetection — deferred, not rejected

An alternative to a human/CLI-driven add: have Dockside's own infrastructure periodically exec
into each container, notice a newly-listening port, and auto-create a router for it (VS
Code-style auto-forwarding). Two independent ambiguities make this harder than it looks:

- **Protocol.** A passive port scan — or even an active one, sending a TLS ClientHello and checking
  for a ServerHello — can at best tell you whether a port is wire-encrypted; it can't tell you it's
  HTTP at all, versus some other TCP protocol (gRPC, a database, a raw socket service). Absent a
  protocol signal, the model has to either surface both an `http<port>-` and `https<port>-` prefix
  for every discovered port, or hold the router back pending explicit confirmation.
- **Which port.** A dev process routinely opens several ports at once (app port, debugger, metrics,
  admin, a bundler's HMR socket) — deciding which one is "the" service worth a public router is a
  second, independent unknown that no amount of better protocol detection resolves.

Both point the same way: an autodetected candidate needs a confirming decision-maker somewhere — a
human, or a process that already knows what it just started — before a router goes live
unattended. That rules out a fully-automatic, infra-side scanning daemon, but not autodetection in
general. IDEs like VS Code/Theia already run comparable port-detection for
their own "forward this port" UX, scoped to the one workspace they're attached to — reusing that
existing signal, rather than building a new Dockside-side scanning daemon, may sidestep the
"which port" ambiguity for free, since the IDE already knows what belongs to its own workspace, and
could plausibly reuse (or feed) whatever confirmation step the self-service API below ends up
needing. This needs its own investigation — in particular, how, if at all, the IDE itself resolves
the protocol question for its own port-forwarding UI — before it can be relied on as a signal; left
as a follow-on to explore, not designed here.

### Self-service router management from inside the devtainer

The motivating use case behind autodetection — letting a developer's AI agent, working in
its own git worktree inside an already-launched devtainer, expose the app server it just started
without a human running a CLI command for every dev-server restart — doesn't need
infrastructure-side detection at all: the agent already knows exactly what it started and on what
protocol. What it lacks is a lightweight way to *authenticate* that request, scoped to
"reconfigure only this one devtainer's own routers," short of provisioning a full outer-Dockside
account with the owner's create/stop/remove privileges (possible today, but onerous to bootstrap
per-devtainer for routine agent use).

The chosen direction reuses the metadata server's existing trust floor rather than inventing a new
one: it already resolves a caller's identity purely from source IP, with the reservation id always
derived server-side from that lookup — a request can never name a target reservation. Router
mutation would be the first *write* gated this way, which is a real step up in consequence: a
stale/reused docker IP landing a write against the wrong, newly-provisioned reservation is a
narrower risk than for the read-only lookups this floor has only ever gated before, but a worse
one. See ADR-0009 for the general per-reservation, named-token mechanism layered on top of the IP
floor to gate that step up.

**The `routers` capability.** Given a token that grants it
(`metadata.tokens.<name>.routers` — see ADR-0009 for the token schema, lifecycle, storage, and
CLI/API this sits inside), its shape is:
```json
"routers": { "auth": ["owner", "developer"], "default": "owner" }
```
`auth` is the router-mutation allow-list ceiling, `default` the initial access level assigned to a
router the token adds — the same two values `User.pm` already resolves for the human CLI/UI path,
just profile-authored instead of session-derived.

**Implementing ADR-0009's owner-permission check for this capability: reuse, not
reimplementation.** The metadata-server handler for a `routers`-capability token doesn't run any
authorization logic of its own. It resolves the reservation's owner account and calls the exact
same `User::addContainerRouter`/`removeContainerRouter`/`replaceContainerRouter` entry points the
CLI/UI path calls, as that owner, passing the token's `auth`/`default` through as `--auth`/
`--access` are passed today. Every check those methods already perform therefore applies
unchanged: `has_permission('addContainerRouter'/'removeContainerRouter')` (now checked against the
owner's account — this is ADR-0009's use-time re-check, not a second, parallel mechanism),
`can_on($reservation, 'develop')` (trivially true for an owner), and `_canAddRoutersToReservation`
(the profile's `userRouters` opt-in, or the owner being an admin). Nothing about
`Mutate.pm`/`normalise_router_def` changes or needs to know a token was involved.

One consequence worth flagging for profile authors, since it falls directly out of this reuse
rather than being a separate rule: declaring a `routers`-capability token is not itself a
substitute for `userRouters`. A profile that declares such a token but leaves `userRouters` false
only works via the token if the owner happens to be an admin (the same bypass the human path
already has); otherwise both need to be set, exactly as they would for the owner to add a router
via the CLI directly.

**Deferred, not designed here:**

- **Prefix/domain/protocol restriction per token.** Not motivated by a collision/squatting risk:
  `Proxy::domain_to_host` resolves *which reservation* a request belongs to from the container
  name embedded in the public hostname before any router-prefix lookup ever runs, and
  `Reservation::lookup_container_uri` only ever consults that one already-identified reservation's
  own router table — two devtainers can never collide at the prefix or domain level, whatever
  values either one picks. Within a single reservation,
  `normalise_router_def`'s existing overlap check already rejects any two routers (self-service or
  admin-authored) claiming the same (protocol, prefix, domain) tuple. So access level (who can
  reach a router once it exists) is the only restriction this feature actually needs; protocol and
  domain need none, for the reasons already given. If a prefix restriction is ever wanted anyway,
  it'd be for a purely organizational reason — an admin wanting a given token's additions confined
  to a predictable namespace (e.g. `dev-*`) rather than an unconstrained one — not a safety
  requirement. Still a single additional profile-level allow-pattern layered into the existing
  `normalise_router_def`/`Mutate.pm` validation if ever built, not a new "router class" concept.

## UI implementation outline

The Vue components described here are separate, independently-schedulable work from the server
API and CLI in Decision above. Scope: router add/remove/replace only — token management's UI is
ADR-0009's concern, since its design is capability-agnostic rather than router-specific.

### Router add/remove/replace

`Container.vue`'s routers table (currently display-only: it renders `profile.routers` and lets an
already-launched reservation's `meta.access[name]` be edited in the form's existing edit mode, but
has no add/remove of its own) gets:

- **Service layer** (`container.js`), same `FORM_POST`/body-string shape `putContainer` already
  uses: `addRouter(id, routerDef, access)`, `removeRouter(id, name)`,
  `replaceRouter(id, name, routerDef, access)` — POSTing to `router/add`/`remove`/`replace`, with
  `routerDef` JSON-stringified into the body's `router` field (`_decode_router_arg` requires a
  JSON string, not nested form fields).
- **A `RouterForm.vue` modal**, `mode: 'add' | 'edit'`, pre-filled from the existing router when
  editing: name (optional — falls back to the first prefix, same as `normalise_router_def`
  itself), prefixes, domains (advanced/collapsed, default `*`), an HTTP block and an HTTPS block
  (each a checkbox revealing private-protocol/private-port fields when ticked — at least one
  required, mirroring `normalise_router_def`'s own check), `auth` checkboxes over the five known
  levels, and an initial-access `<select>` filtered to whichever `auth` boxes are checked (reusing
  the filter the existing access-level `<select>` already does for admin-authored routers).
  Submit errors (collision, bad prefix, gatewayMode rejection) are 400s shown inline in the modal,
  not `alert()`'d — they're validation feedback a user acts on, not a fatal failure.
- **Table integration**, each control gated on the permission flags the server already computes
  and exposes (`container.permissions.actions.addContainerRouter`/`removeContainerRouter` — the
  profile-level `userRouters` opt-in is already folded into that flag via
  `_canAddRoutersToReservation`, so the client makes no separate policy decision): a per-row
  "Remove" button, hidden client-side for `type === 'ide' | 'ssh'` as a courtesy (the server
  enforces this absolutely regardless) and confirmed via a `ConfirmModal` instance keyed per
  router name — the same component the existing container-remove control uses; a per-row "Edit"
  button (needs both permissions, since replace does) opening `RouterForm` pre-filled, submitting
  via `replaceRouter`; an "Add router" button below the table opening `RouterForm` empty,
  submitting via `addRouter`.
- **Response handling**: `router/add`/`remove`/`replace` return `{ status, reservation }`, a
  single reservation, the same shape `POST /containers/create` returns — so the response handler
  must dispatch the existing single-reservation upsert action (`addContainer`), not
  `setContainers` (which expects the full containers array, as `start`/`stop`/`remove` return).
  Using the wrong one would silently stop the row from refreshing.

## Alternatives considered

- **Per-router `userManaged` admin opt-in for removal** — rejected; see Decision above.
- **Warn-and-succeed in gatewayMode** (return success with a "may need a restart" caveat) —
  rejected in favour of a hard, simple rejection, given gatewayMode's deprecated status.
- **Folding add/remove/replace into the existing `/containers/:id/update` endpoint** (as a
  `routers` field, whole-array replace) — rejected: add/remove are two distinct permissions, a
  router definition has enough shape to want its own request body, and a whole-array replace from
  the client reopens exactly the concurrency hazard the locked-transform design avoids.
