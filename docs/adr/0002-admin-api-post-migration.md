# ADR-0002: Migrate state-changing API routes from GET to POST

- **Status:** Proposed (draft — part of the `OtdcG` curated merge)
- **Date:** 2026-06-13
- **Deciders:** Struan Bartlett
- **Scope note:** The branch migrated and enforced POST on the **admin/self** mutation
  routes only, *deliberately deferring* the **container** routes (see `4c6b2bb`). This
  merge **completes** that migration — the container routes are brought onto POST in the
  net-new commit **C7**, so that no state-changing route remains reachable via GET.

## Context

Historically, state-changing API operations were reachable over `GET`. Two concrete
problems:

- **GET is the wrong verb for mutations.** GET requests are cacheable, prefetchable, and
  logged (URLs, including their query strings, land in access logs and browser history).
  State changes must not ride a method with those semantics.
- **GET arguments are not JSON-decoded.** The GET argument parser (`split_args`) treats
  values as flat strings, so structured fields (role `permissions`/`resources`, the
  profile `_json` blob) would be corrupted. Mutations need a body that is parsed and
  JSON-decoded consistently.

## Decision

1. **POST for all state-changing routes**, parsed through a single normalization point,
   `App.pm::parse_body_args` → `get_args`, which yields uniformly-decoded Perl
   structures for both `application/json` bodies and form-encoded values (the CLI sends
   structured fields as JSON-stringified form values; the Vue client posts JSON). A
   reserved `_unset` key (array of dotted paths) expresses field deletions.
2. **A single enforcement guard** in `_api_handler` returns **405** for non-POST on the
   mutation routes, rather than per-route ad-hoc checks.
3. **Bodyless POSTs dispatch** (no-arg mutations like `remove`/`start`/`stop`): a POST
   with an empty body previously returned 400; it now falls through to the API handler.
4. **Canonical (sorted) JSON responses** (`->canonical`): Perl hash order is randomized
   per process; without this, every response reorders keys, breaking the admin JSON
   editor and producing noisy diffs in CLI `-o json` output. Sorted order also matches
   the on-disk profile/role writes.

**Roll-out within this merge:** the curated series lands atomically — the server's POST
enforcement (the 405 guard, commit C1) and the POST-only clients (CLI in C2, Vue in C3)
merge together. There is therefore **no "accept both verbs" transition** and no window
where a client is ahead of the server: a GET on an admin/self mutation route is rejected
from the moment the series lands. (A staged rollout that temporarily accepted both verbs
would only be needed if the server and clients shipped in separate releases, which they
do not here.)

**Completion (this merge, C7):** the container routes (`/containers/create`,
`/containers/<id>/{update,start,stop,remove}`) are added to the enforcement guard and
their CLI/Vue callers switched to POST. Container **reads** (`/containers`,
`.../logs`, `/resources`) intentionally remain GET.

## Alternatives considered

- **Keep mutations on GET** — rejected for the two reasons in Context (caching/logging
  semantics; no JSON decoding of structured fields).
- **Per-route method checks** — rejected in favor of one centralized guard (one regex,
  one place to reason about which routes are state-changing).
- **Migrate everything in the branch** — the branch deliberately deferred container
  routes to keep its scope on the admin feature; this ADR records that the migration is
  now finished rather than left half-done.

## Consequences

- All clients must send mutations as POST; the CLI and Vue client do. The redaction/
  restore pattern (`User/Manage.pm`) ensures a sanitized record echoed back over POST
  does not destroy secrets.
- The enforcement guard is the single source of truth for "which routes are
  state-changing"; new mutation routes must be added to it.
- After C7, GET can no longer trigger any state change — the security/caching posture is
  consistent across the whole API.
