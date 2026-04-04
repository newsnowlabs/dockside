# Cookiejar Isolation Problems in CLI-Driven Test Harness

## Context

Changes B&C rewrote the test harness to:
- **B**: Use the CLI's `check-url` subcommand for all HTTP service checks (replacing inline urllib)
- **C**: Use the CLI for dynamic admin setup/teardown (creating test users, roles, profiles)

An unintended consequence is that the CLI's cookiejar, which was designed for interactive single-user CLI sessions, is now shared across distinct authentication contexts within a single test run. Two separate problems arise.

---

## Issue A: Admin cookies contaminating test-user simulation

### Mechanism

When `DOCKSIDE_TEST_ADMIN` is unset (`session_only=True`), the admin client uses the **system** `~/.config/dockside/` config dir without overriding `DOCKSIDE_CONFIG_DIR`. This is intentional — it allows a developer to run `dockside login` once and then drive tests without exposing a password on the command line.

Test users (dev1, dev2, viewer) each get an **isolated temp dir** as `DOCKSIDE_CONFIG_DIR`. Because `--username`/`--password` are passed on every call, `get_authenticated_opener()` calls `login()` fresh each time (`transient=True` → cookies are used for the call but not persisted across calls). In theory, each test-user CLI invocation is therefore stateless and user-specific.

### Why isolation is currently correct but fragile

The isolated-temp-dir approach does correctly separate test users from each other. However:

1. **`session_only=True` admin uses system state** — the system config dir is a shared, mutable resource. Any prior non-test CLI operations on the same machine (e.g., the developer's own `dockside login` to the test server as a non-admin user) leave cookies in the system dir that the admin client will silently inherit. If those cookies happen to belong to a different user identity, admin API calls run as the wrong user.

2. **`session_only=False` admin (explicit credentials) gets a persistent temp dir** — admin's temp dir accumulates cookies across the test run and is reused for every admin API call including `check-url`. After the setup phase, this dir contains admin session cookies for the target server. The `check-url` code (`cmd_check_url`) copies **all** cookies from `opener._jar` and re-scopes them to the target hostname. There is no filtering by user identity.

3. **`transient=True` does not clear the stale cookie load** — `get_authenticated_opener` calls `login()` which calls `_build_opener(cookie_file, …)`. `_build_opener` **first loads the existing cookie file**, then the login POST adds the new session cookie. Both old and new cookies end up in the jar. Since each test-user call uses a fresh temp dir (initially empty), stale cookies are not present in practice — but this depends entirely on the temp dir always starting empty, which is a fragile assumption.

4. **`_reload_cookie_jar()` reads the wrong path** — it reads `<config_dir>/cookies.txt` but the CLI writes to `<config_dir>/cookies/<server-slug>.txt`. This means `get_uid_cookie()` (used by SSH tests to extract session cookies) always returns `None`. (Minor independent bug; doesn't affect the isolation problem but is worth noting.)

### Scope

Both local mode and remote mode are affected. In harness mode, `DOCKSIDE_TEST_ADMIN` is always set (extracted from container logs), so admin is always `session_only=False` with an isolated temp dir; the risk is lower but not zero.

---

## Issue B: Outer/inner Dockside cookie propagation (remote mode only)

### Architecture

In remote mode, a developer may be running Dockside (outer) at `*.local.dockside.dev` with a devcontainer that itself runs Dockside (inner) at `*-ds-ai1.local.dockside.dev`. To test the inner Dockside:

- The outer Dockside acts as a reverse proxy to the inner
- Every request to `*.local.dockside.dev` (including to `*-ds-ai1.local.dockside.dev`) must carry the **outer session cookie** (`_dsUID`) to pass through the outer proxy
- Requests to the inner Dockside's own API must also carry the **inner session cookie** (e.g., `_ds-ai1-UID`) for the inner Dockside's authentication layer
- A browser handles this naturally: both cookies have domain `.local.dockside.dev`, so the browser sends both to any `*.local.dockside.dev` URL

### How the CLI falls short

The CLI stores cookies **per server URL**, not per domain:
- Outer: `~/.config/dockside/cookies/www.local.dockside.dev.txt` → `_dsUID=outer_admin_session`
- Inner: `~/.config/dockside/cookies/www-ds-ai1.local.dockside.dev.txt` → `_ds-ai1-UID=inner_admin_session`

When the test is run with `--server https://www-ds-ai1.local.dockside.dev`:
- `_client()` resolves the inner server and loads only `www-ds-ai1.local.dockside.dev.txt`
- The opener contains ONLY the inner session cookie
- The login/API request goes to `https://www-ds-ai1.local.dockside.dev/…`, hitting the outer proxy first
- The outer proxy sees no outer session cookie → **401**

This means CLI-based API calls to an inner Dockside instance simply do not work in the current design. The outer cookies are needed even for the initial admin login to the inner Dockside.

### Interaction with test-user simulation

After a successful admin setup on the inner Dockside (however achieved), test user requests also need outer cookies to pass through the outer proxy. Even if we isolate admin vs test-user cookies correctly, each test-user `check-url` call still needs to carry outer cookies alongside the test-user's own inner session cookie. These are cookies from two different identity contexts and two different server entries.

---

## Options

### Option 1: Full revert of B&C

Undo all of B&C. Return to:
- Pre-seeded `users.json`/`roles.json` via volume mounts; `docker exec` for password hashing
- Inline urllib in test code for HTTP checks (with `_ConnectToHTTPSConnection` etc.)

The cookiejar problem disappears because the CLI is not used for test requests. Dynamic env management is lost.

**Trade-offs:** Clean and simple. No false positives. But loses all the dynamic env management and CLI-testing benefits from B&C. Test users/roles/profiles go back to being statically configured; multi-instance or suffixed runs become impossible.

---

### Option 2: Revert CLI for test phase; keep CLI for setup/cleanup only

CLI is used only during the admin initialisation phase (creating users, roles, profiles) and the cleanup phase. All test-phase API calls (list, get, create containers, etc.) and all HTTP service checks go through a direct HTTP client that the test harness owns.

The test harness keeps its own authenticated `urllib` opener per user, seeded via a direct login POST, and uses `_ConnectToHTTPSConnection`/`_ConnectToHandler` (already present in `dockside_test.py`) for the TCP override. `http_check` is used for unauthenticated checks; a new `authenticated_check` function handles per-user cookie-bearing requests.

**Trade-offs:** Clean separation of concerns. Admin cookies are never in the same code path as test-user simulation. But the test harness still carries its own HTTP client implementation (more maintenance surface). The outer/inner issue in admin setup remains latent but doesn't affect test-user simulation.

---

### Option 3: Keep CLI for all; use a fresh temp dir per `_run()` call (no persistent cookiejar)

Instead of one temp dir per `DocksideClient`, create (and destroy) a new empty temp dir **for each `_run()` call**. Because test users always pass `--username`/`--password`, each call does a fresh login from an empty state. The opener used by that CLI invocation contains only the freshly minted session cookie for the given user; there are no stale cookies to contaminate the request.

This works because `transient=True` (set by `_client()` when username is provided) means the cookie is used for the current invocation only — so there's no need to persist across calls anyway.

**Trade-offs:** Solves the admin-vs-user contamination risk completely (no shared state between calls). Slightly higher overhead (one `mkdtemp()`+`rmtree()` per call), but negligible in practice. Does **not** solve the outer/inner issue (no outer cookies are available). `get_uid_cookie()` for SSH tests would need a different approach (e.g., parse the session cookie from the CLI's JSON response, not from the cookie file). Conceptually cleaner than current per-client dirs; slightly simpler to reason about.

---

### Option 4: Keep CLI for all; disable cookiejar except whitelisted outer-instance cookies

Keep the current per-client isolated-temp-dir approach. Add a mechanism so that when making requests for test-user contexts, only a specified whitelist of "passthrough" cookies (i.e., the outer Dockside session cookie for the current test user) are included alongside the user's own session cookie.

Concretely:
- After each test user's first login, extract the outer session cookie name+value from the server's `Set-Cookie` response (the outer Dockside would set its own cookie during the inner Dockside login flow)
- Store these extracted outer cookies explicitly
- Add `--extra-cookie NAME=VALUE` to the CLI's `check-url` and API commands
- Pass the outer cookies via `--extra-cookie` for every test-user CLI call

This is precise: only the specifically named outer cookies are shared; admin's inner-instance session cookie is never passed.

**Trade-offs:** Directly solves both issues. Requires knowing which cookie names are "outer" (but these are determined during login, not hardcoded). Adds complexity to test harness (must thread outer cookies through to every call). Requires augmenting the CLI with `--extra-cookie`. Does not handle the case where admin has MORE cookies that must not leak (all non-whitelisted cookies are excluded by construction).

---

### Option 5: Keep CLI for all; suppress admin inner-instance cookies via blacklist from `config.json`

Read the target Dockside instance's `config.json` (or a well-known API endpoint) to discover the cookie name(s) it uses. Before each test-user CLI call, filter the cookiejar to exclude those specific names (i.e., blacklist the inner instance's own session cookies from admin's jar). Outer cookies (which have different names) pass through.

**Trade-offs:** Automated discovery of cookie names avoids hardcoding. But requires access to the target server's config at test startup; config.json schema is internal and could change; it only works for the inner instance's cookies and may miss edge cases (e.g., the inner instance uses multiple cookie names). More brittle and fragile than options 3/4.

---

### Option 6a: Augment CLI with `--extra-config` / multiple config dirs per user (CLI-level multi-identity)

Extend `DOCKSIDE_CONFIG_DIR` semantics to support **multiple** config directories in a path-like manner. When building the opener, the CLI loads cookies from **all** config dirs for the relevant server, merging them. The test harness can then point the inner Dockside's client at `<inner-tempdir>:<outer-tempdir>` so that outer cookies are automatically included.

This is the most general solution: it mirrors how a browser loads all matching-domain cookies from a single jar regardless of which site set them.

**Trade-offs:** Cleanest architecture long-term; CLI gains a useful capability (multi-identity, outer/inner support) that is broadly useful beyond tests. High implementation cost: requires CLI changes, merging logic, and test harness changes. Adds conceptual complexity for CLI users. The test harness needs to know which dirs to combine (must discover the outer server identity).

---

### Option 6b: Augment CLI with per-user named cookie contexts (`--user-context`)

Add a `--user-context <name>` flag (or `DOCKSIDE_USER_CONTEXT`) to the CLI. Cookie files are named `<server-slug>-<context>.txt` instead of `<server-slug>.txt`. The test harness calls the CLI with `--user-context admin` for admin calls and `--user-context dev1` for dev1 calls, all within the same `DOCKSIDE_CONFIG_DIR` (the system dir). Different contexts are perfectly isolated by construction; no temp dirs needed.

For the outer/inner issue, a `--with-context <name>` flag could merge cookies from a second context (e.g., `--user-context dev1 --with-context outer-dev1`).

**Trade-offs:** Elegant and broadly useful; CLI gains first-class multi-user identity support. High implementation cost. Does not help operators who currently manage a single shared `~/.config/dockside/` for multiple servers.

---

### Option 7: Domain-hierarchy cookie inheritance in the CLI

Extend `_build_opener` / `_client()` to behave more like a browser: when building the opener for a target server, also load cookies from any configured server whose URL is a parent or sibling domain of the target. This would automatically include outer cookies when making requests to inner-Dockside URLs.

Optionally expose this via an `outer_server` field in each server entry in `config.json`: `{"url": "https://www-ds-ai1.local.dockside.dev", "outer_server": "https://www.local.dockside.dev"}`.

**Trade-offs:** Mirrors browser behaviour exactly; no test-harness changes needed for the outer/inner case. Risk of inadvertently including cookies from unrelated servers that happen to share a TLD. The `outer_server` field variant is safer. Still does not address admin-vs-user contamination (which needs cookiejar isolation, not inheritance).

---

## Summary Table

| Option | Description | Cleanliness | Ease of impl. | Reliability | Outer/inner effectiveness | Admin-vs-user effectiveness | Safety (no false positives) | Operator ease |
|--------|-------------|-------------|---------------|-------------|--------------------------|-----------------------------|-----------------------------|---------------|
| 1 | Full revert B&C | ★★★★★ | ★★★★★ | ★★★★★ | n/a | n/a | ★★★★★ | ★★★★★ (but loses features) |
| 2 | CLI for setup only; urllib for test phase | ★★★★☆ | ★★★☆☆ | ★★★★★ | ★★★☆☆ | ★★★★★ | ★★★★★ | ★★★★☆ |
| 3 | Fresh empty temp dir per `_run()` call | ★★★☆☆ | ★★★★☆ | ★★★★☆ | ★★☆☆☆ | ★★★★★ | ★★★★★ | ★★★★★ |
| 4 | Whitelist outer cookies via `--extra-cookie` | ★★★☆☆ | ★★★☆☆ | ★★★★☆ | ★★★★☆ | ★★★★★ | ★★★★☆ | ★★★☆☆ |
| 5 | Blacklist inner cookies via `config.json` | ★★☆☆☆ | ★★☆☆☆ | ★★☆☆☆ | ★★★☆☆ | ★★★☆☆ | ★★★☆☆ | ★★☆☆☆ |
| 6a | Multiple config dirs merged by CLI | ★★★★★ | ★★☆☆☆ | ★★★★☆ | ★★★★★ | ★★★★★ | ★★★★★ | ★★★★☆ |
| 6b | Per-user cookie contexts in CLI (`--user-context`) | ★★★★★ | ★★☆☆☆ | ★★★★★ | ★★★★☆ | ★★★★★ | ★★★★★ | ★★★★★ |
| 7 | Domain-hierarchy cookie inheritance in CLI | ★★★★☆ | ★★★☆☆ | ★★★☆☆ | ★★★★★ | ★★☆☆☆ | ★★★☆☆ | ★★★★★ |

### Key ratings notes

- **Option 1** is the safest revert but discards the work of B&C (dynamic env management, CLI-based service checks).
- **Option 2** preserves dynamic env management while keeping test simulation clean; the outer/inner issue in admin setup is unresolved (a future problem, not immediately blocking).
- **Option 3** is the minimal-change fix for admin-vs-user contamination with no CLI modifications needed; outer/inner remains unresolved.
- **Option 4** handles both problems but requires CLI augmentation (`--extra-cookie`) and non-trivial test harness changes to thread outer cookies through.
- **Options 6a/6b** are the architecturally cleanest solutions and would benefit all CLI users, but require the most implementation effort.
- **Option 7** solves outer/inner automatically but does not address admin-vs-user contamination and has broader security implications.

### Recommended combined approach

For a near-term fix (low implementation cost):
- **Option 3** (per-call temp dirs) solves admin-vs-user contamination with minimal changes
- Accept that outer/inner in remote mode is unsupported until a CLI-level fix is designed separately

For a longer-term clean design:
- **Option 6b** (per-user cookie contexts) or **Option 6a** (multiple config dirs) solves both problems cleanly and also adds genuinely useful CLI capability
