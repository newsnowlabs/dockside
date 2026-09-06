# ADR-0009: Metadata-server tokens

- **Status:** Proposed
- **Date:** 2026-08-25
- **Deciders:** Struan Bartlett

## Context

Dockside's metadata server already resolves a caller's identity purely from its own source IP —
no other credential involved. That floor is adequate for read-only, server-authored responses: a
stale or reused IP landing a *read* against the wrong, newly-provisioned reservation is a
low-consequence mistake.

Using that same floor to gate a *write* instead — ADR-0008's self-service router management is
the motivating case, letting a process inside a devtainer (typically an AI coding agent working
in its own worktree) reconfigure that devtainer's own routers without a human running the CLI for
every dev-server restart — changes the calculus: a stale/reused IP landing a *write* against the
wrong reservation is a worse mistake than the equivalent read, and IP alone stops being
sufficient on its own. This ADR designs the general credential layer for that step-up — a
per-reservation, named, revocable token — so any metadata-server-mediated write can reuse it
rather than each inventing its own scheme. Nothing here touches or depends on anything else the
metadata server does; the only fact this design relies on is the one stated above (it can resolve
a caller's reservation from source IP alone).

## Decision

**Token-first, capability-second schema.** Declared per-profile, by name, under the profile's
existing `metadata` key — a natural per-profile namespace for anything the metadata server hands
out or gates. Nested under a generic `tokens` map, with each name holding one or more capability
grants beneath it, rather than a capability holding a list of tokens:
```json
"metadata": {
  "tokens": {
    "agent-dev": {
      "routers": { "auth": ["owner", "developer"], "default": "owner" }
    },
    "ci": {
      "routers": { "auth": ["developer"], "default": "developer" }
    }
  }
}
```
`routers` here is the capability ADR-0008 defines — see there for exactly what its `auth`/
`default` fields mean and how they're consumed. What matters at this layer: any other capability
(e.g. a `hooks` grant) slots in beside `routers` under the same named token,
without a schema migration or a second token namespace. Two independently-scoped names are two
independently-rotatable credentials — rotating `ci` because it leaked never touches `agent-dev`,
and a compromised `ci` token can't reach anything `agent-dev` couldn't already, since grants are
evaluated per name, not merged across the map.

- One token is generated per declared name, at launch — not one per access level/capability-range.
  Naming avoids having to enumerate every point in a combinatorial option space, and lets two
  grantees with identical scope hold independently rotatable/revocable credentials, which a fixed
  one-token-per-level scheme can't offer, since it has exactly one credential per level.
- Required by default; a profile (or a site-wide default, for small/trusted single-operator
  deployments) may opt out of the *token* requirement specifically — the underlying IP-based
  reservation lookup this sits on top of is never optional; it's the existing, unconditional floor.
- Never injected into the devtainer's own environment at launch — surfaced only via explicit
  CLI/UI reveal, once, at generation/rotation time (see Surfacing below). This is the point of
  naming tokens per intended grantee rather than minting one ambient container-wide credential: a
  developer decides, per agent session, which token (if any) to hand out, and can revoke one
  agent's access by rotating just its token.
- Stored as `sha256_hex(token)` in the reservation record, in the clear — safe because the hash is
  one-way and the token itself is a high-entropy random value, not because the record is otherwise
  protected. Deliberately *not* coupled to any reversible encrypt/decrypt-at-rest storage: that
  kind of machinery is for secrets like `gh_token`/SSH private keys, which must be recovered in
  plaintext to actually be used — a bearer token being compared, not decrypted, never needs it. If
  re-displayable (rather than reveal-once/rotate-to-replace) tokens are ever wanted, swapping the
  hash for reversible encryption is a drop-in storage-layer change should Dockside grow that
  facility generically, not a redesign of anything here.

**Capability exercise never exceeds the owner's current permission.** A token's declared
capability is a delegation of power the reservation's owner already holds, not an independent
grant. So whenever the metadata server actually exercises a capability on a token's behalf (e.g.
adding a router), it re-checks that the owner's account currently holds whatever role permission
that capability's own direct-mutation path requires (for `routers`: `addContainerRouter`/
`removeContainerRouter`) — the same check `User.pm` already runs for a logged-in caller, just run
against the owner's account instead, since a token-authenticated request has no logged-in caller
to check. This matters because ADR-0008's role permission binds even the owner: an owner without
`addContainerRouter` cannot add a router directly, and a token must not become a way around that
by substituting the profile author's decision to declare the token for the admin's own,
independent per-account permission decision. The check runs at the moment of use, not once at
reveal/rotate time — permission is re-verified on every metadata-server-authenticated write,
exactly as the direct path re-checks it on every call rather than caching it at login, so
revoking a role permission takes effect on every outstanding token immediately, with nothing to
separately track or rotate. Bound to the owner specifically, not whoever revealed or rotated the
token — simplest, and consistent with this mechanism's existing owner-centric defaults; a
developer's own role permission is irrelevant to whether a token *works*, only to whether they
were entitled to hand it out in the first place. `token/list`/`token/rotate` themselves stay
gated on `can_on(develop)` alone (see API routes below): revealing or rotating a token whose
capability the owner can't currently exercise is harmless — it simply won't work when used.

**Surfacing tokens: reveal-once, not re-showable.** Because only `sha256_hex(token)` is ever
persisted, the plaintext exists nowhere, at any time, after the moment it's minted — there is no
server-side "show me that token again" to build a `show` command against, only a mint event whose
response happens to include the value. That collapses the surface to three operations instead of
the four a "show" verb would suggest:

- **Mint**, implicit, not a separate call: every declared name gets a freshly-generated token at
  launch, and each one's plaintext rides once in that launch response, alongside everything else
  `POST /containers/create` already returns.
- **Rotate**, the only way to get a value back after the initial reveal is missed, a new grantee
  needs onboarding, or a token is suspected compromised: generate a new random value, overwrite
  the stored hash, and return the new plaintext once. This is a hard cutover, not an additional
  live credential — anything already holding the old value stops working the instant rotate
  completes, and needs the new value handed to it before its next call.
- **List**, read-only and secret-free: declared names plus their profile-authored capability
  grants, so a caller can see what exists (and reason about what's been handed out) without
  minting anything just to check.

**API routes** — a sub-resource of `/containers/:id`, its own top-level noun rather than nested
under any one capability it might grant (`/containers/:id/router/token/...` would misname the
relationship: a token is a named grant that currently happens to include a `routers` capability,
not a router sub-concept — the whole reason the schema above is token-first, not
capability-first). Gated on `_require_login` + `can_on(develop)`, deliberately no narrower:
revealing or rotating a token is harmless independent of whether its capability can currently be
exercised, since that's enforced separately, at use time, against the owner's account (see
"Capability exercise never exceeds the owner's current permission" above) — not against whoever
happens to be revealing or rotating it:

- `POST /containers/:id/token/rotate` (body: `name`) → `{ status, name, token, reservation }`.
  `token` is the one and only place the new plaintext appears in this response; it is never
  written to disk or logged.
- `GET /containers/:id/token/list` → `{ status, tokens: { <name>: { <capability>: {...}, ... } } }`
  — no secret material, safe to call as often as needed (e.g. to populate a UI panel on load).

No standalone "show"/"reveal" route: the one other place plaintext appears is the existing
`POST /containers/create` response, extended with a sibling `tokens` field alongside the existing
`reservation` — `{ status, reservation, tokens: { <name>: <plaintext>, ... } }` for every name the
launched profile declares. `tokens` is deliberately not nested inside `reservation`: that object's
shape must stay identical to whatever the regular polling refresh (`updateContainers`/
`setContainers`) sends for this reservation ever after, which can only ever carry the hash, since
that's all that persists server-side. `rotate`'s response follows the same rule at smaller scale
(`token` alongside `reservation`, one name at a time).

**CLI** (`cli/dockside`) — `token`, its own top-level noun, for the same reason the API routes sit
beside any one capability's routes rather than under them — thin wrappers over the two routes
above, nothing else:

- `dockside token list <reservation>` → table of name / capability grants from `token/list`.
- `dockside token rotate <reservation> <name>` → calls `rotate`, prints the new plaintext once
  with an explicit "this invalidates the previous value immediately" warning, and does nothing
  else silently reversible.
- No `dockside token show`: a freshly-launched reservation's tokens appear in `create`'s own
  output; `rotate` is the only "get me a value" verb for any later point.

**Considered and rejected:**

- **Request-then-confirm instead of a direct token-gated write** (a request lands as a pending
  item a human approves via UI/CLI, rather than taking effect immediately once token-authenticated
  — ADR-0008's router-add is the concrete example). Rejected: this
  reintroduces a human into every call, which already happens today at zero engineering cost — the
  requesting process can simply emit the CLI command for a human to review and run. The only thing
  a token-gated direct write buys over that status quo is removing the human from the per-call
  loop, which a confirm-first step would undo while adding real new machinery (pending-request
  storage, a UI list, expiry).

## Consequences

- Any future metadata-server-mediated write can reuse this token layer by defining its own
  capability object nested under a token name, rather than inventing a separate auth scheme —
  this ADR is the general mechanism, not tied to any one capability.
- ADR-0008 defines the `routers` capability — see there for its concrete shape (`auth`/`default`),
  how it's consumed by `Mutate.pm`/`normalise_router_def`, and for capability-specific deferred
  items (e.g. prefix/domain restriction) that belong to that capability, not to this general
  mechanism.

## UI implementation outline

The Vue components described here are separate, independently-schedulable work. Generic, like the
rest of this ADR, not router-specific — see ADR-0008 for the router-specific UI (the routers
table, add/remove/replace controls), which is separate work from this one.

- **Store**: a new state slice, `tokens: {}` (reservation id → `{ [name]: plaintext }`), a plain
  in-memory Vuex field like the rest of the store's state (no persistence plugin exists here
  beyond one hand-picked `localStorage` field elsewhere, so nothing needs guarding against by
  default) — mutation `setTokens(state, { id, tokens })` merges rather than replaces
  (`Vue.set(state.tokens, id, { ...(state.tokens[id]||{}), ...tokens })`), so a single-name
  `rotate` doesn't drop other names already held for the same reservation; action `addTokens`, a
  thin wrapper, matching the existing `addContainer` mutation/action pairing style already used
  elsewhere in this store for a single-reservation upsert.
- **Populated, never auto-displayed**, at the two response handlers that ever see plaintext: the
  existing container-create response handler dispatches `addTokens` with `data.tokens` (the
  sibling field on the `create` response — see API routes above) alongside whatever it already
  dispatches for the reservation itself, with no modal opened; the token-rotate handler dispatches
  `addTokens` with `{ [name]: data.token }` after calling `rotateToken`, with no modal opened
  either time: a value minted at launch stays available for whenever a developer actually opens
  the tokens panel, rather than being lost the moment that first response is handled off-screen.
- **`Tokens.vue`**, opened manually only (a "Manage tokens" button, gated on developer standing and
  the reservation being live — tokens don't exist pre-launch): reads `$store.state.tokens[id]`
  merged with the always-fetchable `getTokens` (`token/list` — names plus capability grants, no
  secret material, so safe to call on every open). Per declared name: plaintext present in the
  store → show it with a Copy button (the same `code-block` + Copy pattern `SSHInfo.vue` already
  uses for its own one-time connection details); absent (this tab was reloaded since the last
  mint/rotate, or never held it) → "not available in this session — rotate to get a new value,"
  not a blank or an error, since there is genuinely nothing left to fetch. A per-name "Rotate"
  button calls `rotateToken` and re-renders from the store.
- **Lifetime**: kept for the browser tab's session (survives navigating away from and back to the
  container view; cleared only by a page reload, ordinary Vuex-state lifetime) — deliberately not
  cleared the first time the modal displays it. The one-time boundary that actually matters is
  server-side (`mint`/`rotate` hands the value out once); how many times the same browser tab
  redisplays something already sitting in its own memory doesn't reopen that boundary, the same
  way `SSHInfo.vue`'s own cookie panel is already freely re-viewable without weakening anything.
- **Service functions** (`container.js`): `getTokens(id)` (GET `token/list`), `rotateToken(id,
  name)` (POST `token/rotate`).

### Naming

Tokens are not tied to any one capability (a named token can grant more than `routers` without a
schema change — see Decision above), so nothing about their surface should read as though they
were, at any layer:

| Layer            | Name                                                    |
|------------------|----------------------------------------------------------|
| Profile schema   | `metadata.tokens.<name>.<capability>` (`routers` is the capability ADR-0008 defines; nested under `metadata` only because that's the existing profile extension point, not descriptive of what the token is) |
| API routes       | `/containers/:id/token/list`, `/containers/:id/token/rotate` |
| CLI              | `dockside token list`, `dockside token rotate`          |
| Store            | state `tokens`, mutation `setTokens`, action `addTokens`|
| Component        | `Tokens.vue`                                            |
| Service functions| `getTokens(id)`, `rotateToken(id, name)`                |

`accessTokens` was considered and dropped — the router-mutation feature that motivated this design
already uses "access" for a different thing (`meta.access[name]`, a router's access *level*), and
pairing that with an `accessTokens` store field in the same vocabulary invites exactly the
confusion being designed away. `serviceTokens`/`serviceAccountTokens` (a GCP service-account
analogy) was also considered and dropped — it overclaims: these tokens aren't a new
identity/principal, they gate a write on top of an identity (the reservation) that's still
resolved the same way it always was, by IP.
