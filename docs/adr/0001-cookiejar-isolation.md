# ADR-0001: Cookiejar isolation for the CLI-driven integration harness

- **Status:** Proposed (draft — part of the `OtdcG` curated merge)
- **Date:** 2026-06-13
- **Deciders:** Struan Bartlett
- **Provenance:** Distilled from the branch's working documents
  `COOKIEJAR_ISOLATION_ANALYSIS.md`, `PLAN_cookiejar_isolation.md`, and `ISSUES.md`,
  which were exploratory artifacts and are **not** carried into `main` (they remain in
  the archived `raw/$FEATURE` history). This ADR is the durable record.

## Context

The integration harness was rewritten to drive the product **only through the
`dockside` CLI** (per the test hard-rules) and to create all users/roles/profiles at
runtime. Because the CLI persists session cookies, two contamination problems surfaced:

- **Issue A — admin-vs-user cookie contamination.** After the admin setup phase, admin
  session cookies persist in the CLI's cookie store. Test-user calls (dev1/dev2/viewer)
  relied on each using a fresh, empty temp location — a fragile assumption: if an admin
  cookie leaked into a test-user request, access-control assertions would pass for the
  wrong reason (false green).
- **Issue B — outer/inner cookie propagation (nested Dockside).** When the target is an
  *inner* Dockside running inside an *outer* one, every request needs **two** cookies:
  the outer session (to pass the outer proxy) and the inner session (to authenticate to
  the inner server). The CLI stores cookies **per server URL**, so a call to the inner
  server loaded only the inner cookie → the outer proxy returned **401**.

Both issues are most acute in local/remote modes; harness mode is lower-risk but not
immune.

## Options considered

| # | Option | Why rejected |
|---|---|---|
| 1 | Full revert to the pre-CLI harness | Loses the dynamic env-management and CLI-as-black-box benefits the rewrite was for. |
| 2 | CLI for setup only; raw `urllib` for the test phase | The outer/inner (Issue B) problem still bites during admin setup. |
| 3 | Fresh temp dir per `_run()` call | Solves Issue A only; provides no outer cookies for Issue B. |
| 4 | Whitelist outer cookies via a CLI `--extra-cookie` | Handles both, but needs CLI work *and* threading outer cookies through the harness. |
| 5 | Blacklist inner cookies via `config.json` | Brittle, discovery-dependent. |
| 6a/6b | Multi-config / per-user contexts inside the CLI | Architecturally cleanest but high cost; benefits all CLI users, not just tests — out of scope here. |
| 7 | Domain-hierarchy cookie inheritance in the CLI | Solves Issue B automatically but over-includes unrelated cookies and doesn't address Issue A. |

## Decision — "Option 8": declarative parent chain + per-client cookie file

Two complementary, generally-useful CLI mechanisms (not test-only scaffolding):

1. **`parent` field in `config.json` server entries.** A server entry may declare an
   outer server (by URL or nickname). The CLI's `_merge_ancestor_cookies()` walks the
   parent chain and loads each ancestor's cookie file into the request opener
   **in-memory only** — ancestors are never written back. This solves Issue B
   declaratively (register an inner server with `--parent <outer>`).

2. **Global `--cookie-file <path>` flag.** The harness passes a per-client temporary
   file as the *target* server's session store, bypassing the host's system cookie
   store for that session while still consulting the system config for the parent
   chain. Each test-user client gets its own file → Issue A cannot occur. `DOCKSIDE_CONFIG_DIR`
   is no longer overridden, so the parent chain remains reachable.

**Implementation markers.** Merged ancestor cookies are tagged with a nonstandard cookie
attribute (`DocksideAncestor`) so they survive cookie-jar serialisation and can be filtered
out at save time: `_save_target_cookie_jar` persists only the target server's *own* cookies.
Ancestor cookies are therefore never cached in the child's session file — they are re-loaded
fresh from the parent's session on every invocation, so the outer session state is always
current.

## Consequences

- **Enables:** per-client session isolation (admin cookies cannot reach test-user
  requests); automatic outer/inner cookie propagation via the declarative `parent`
  chain; both are real operator features, not just test plumbing; isolation is one
  file per client rather than a temp directory tree.
- **Costs:** one-time CLI work (`_merge_ancestor_cookies()`, the two flags); harness
  refactor to per-client temp file; inner-server entries must declare a `parent`
  (operator responsibility: `dockside login --parent <outer>`).
- **Code anchors (current state):** the ancestor re-scoping invariant lives in
  `cli/dockside_cli.py::_merge_ancestor_cookies` (ancestor cookies are re-scoped to the
  *target* hostname so urllib sends them to the inner server); per-client isolation in
  `t/integration/lib/dockside_test.py` (temp `--cookie-file`; `DOCKSIDE_CONFIG_DIR`
  always cleared so the system parent chain is consulted).
