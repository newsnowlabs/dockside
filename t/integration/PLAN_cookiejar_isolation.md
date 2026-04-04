# Cookiejar Isolation — Amended Option 8

## Background

The Dockside integration test harness was overhauled (changes B&C) to use the CLI for all API requests and HTTP service checks. This surfaced two problems:

**Problem A — Admin-vs-user contamination.** After the admin setup phase, admin session cookies persist in the CLI's cookiejar. If those cookies are present when the harness simulates a test user (dev1, dev2, viewer), requests may authenticate as admin, producing false positives in access-control assertions.

**Problem B — Outer/inner cookie propagation (remote mode).** When the test target is an inner Dockside instance (running as a devcontainer inside an outer Dockside), every request must carry:
- an **outer** session cookie to pass through the outer Dockside proxy, AND
- an **inner** session cookie to authenticate to the inner Dockside's own auth layer.

The CLI currently stores cookies per server URL in separate files, so the outer cookie is never automatically included in requests targeted at the inner server. The outer proxy rejects every request with 401.

**Existing partial workaround — shared `cookie_file`.** The CLI already supports sharing a cookie file between server entries:

```json
{
  "servers": [
    {"url": "https://www.local.dockside.dev"},
    {"url": "https://www-ds-ai2.local.dockside.dev", "cookie_file": "local.txt"}
  ]
}
```

This works for interactive CLI use but collapses both sessions into one inseparable file. Cookies differ only by name (e.g. `_dsUID` vs `_ds-ai2-UID`) — not by domain, not by file — making it impossible to include outer cookies without also including admin's inner session cookies. This makes test isolation impossible with the shared-file approach.

---

## Solution: Amended Option 8

Two complementary changes:

1. **Config.json `parent` field** — the inner server entry declares its ancestor; the CLI automatically merges ancestor cookies when building any opener for that server, keeping the cookie files themselves separate.
2. **`--cookie-file <path>` global flag** — the test harness passes a per-client temporary file path as the target server's session store, completely bypassing the host's system cookie store for the target. No DOCKSIDE_CONFIG_DIR override or config cloning is needed.

Together: ancestor (outer) cookies flow in from the system config automatically; the target's (inner) session is isolated to a small temp file per client; admin's stored inner session is never touched.

---

### 1. Config.json: `parent` field

Server entries gain an optional `parent` field (URL or configured nickname):

```json
{
  "servers": [
    {"url": "https://www.local.dockside.dev", "nickname": "outer"},
    {
      "url": "https://www-ds-ai2.local.dockside.dev",
      "nickname": "ai2",
      "parent": "outer"
    }
  ]
}
```

`parent` chains are supported (grand-ancestors, etc.) with cycle detection. This replaces the opaque `cookie_file` sharing — the relationship is now explicit and declarative.

---

### 2. New CLI function: `_merge_ancestor_cookies(jar, cfg, server_entry)`

Follows the `parent` chain recursively and loads each ancestor's cookie file into the given jar **in memory only** — ancestors are never written back to the target's cookie file:

```python
def _merge_ancestor_cookies(jar, cfg, server_entry, _seen=None):
    """Recursively load ancestor cookies into jar (in-memory merge, not saved)."""
    _seen = _seen or {server_entry.get('url', '')}
    parent_ref = (server_entry.get('parent') or '').strip()
    if not parent_ref:
        return
    parent_entry = _find_server(cfg, parent_ref)
    if not parent_entry or parent_entry.get('url', '') in _seen:
        return  # not found or cycle
    _seen.add(parent_entry.get('url', ''))
    parent_file = _cookie_file_for(parent_entry)
    if os.path.isfile(parent_file) and not os.path.islink(parent_file):
        anc_jar = http.cookiejar.MozillaCookieJar(parent_file)
        try:
            anc_jar.load(ignore_discard=True, ignore_expires=True)
            for c in anc_jar:
                jar.set_cookie(c)
        except Exception:
            pass
    _merge_ancestor_cookies(jar, cfg, parent_entry, _seen)
```

---

### 3. New global flag: `--cookie-file <path>`

Added to `_add_global_flags()` (so available on every authenticated subcommand: list, get, create, check-url, whoami, etc.):

```python
p.add_argument(
    '--cookie-file', dest='session_cookie_file', metavar='PATH',
    help='Full path to use as the session cookie file for the target server, '
         'overriding the path derived from config.json. Ancestor cookies are '
         'still loaded from their normal paths. Useful for isolating sessions '
         'in test harnesses without affecting the system cookie store.'
)
```

**Behaviour when `--cookie-file <path>` is set:**
- The target server's cookies are read from and written to `<path>` instead of the path that `_cookie_file_for(server_entry)` would derive from config.json.
- When combined with `--username`/`--password`: fresh login; session cookie saved to `<path>` (not transient, because we have an explicit scratch space).
- Ancestor cookies are still loaded from the system config's `COOKIES_DIR` by `_merge_ancestor_cookies()`.
- The host's stored session for the target server is never read or modified.

**Companion flag `--cookie-auth ancestors-only`** (stateless variant, added alongside `--cookie-file`):
- No target session file is loaded at all (equivalent to `--cookie-file /dev/null` but without a path).
- Ancestor cookies are loaded normally.
- Requires `--username`/`--password`; resulting session is in-memory only (transient, never saved).
- Useful for interactive debugging or truly per-invocation stateless calls.

---

### 4. Changes to `get_authenticated_opener()` and `_client()`

**`_client()`** — extract `session_cookie_file` and `cookie_auth` from `args` and pass to `get_authenticated_opener`:

```python
session_cookie_file = getattr(args, 'session_cookie_file', None)
cookie_auth = getattr(args, 'cookie_auth', 'all')
opener = get_authenticated_opener(
    server_url, server_entry, username, password,
    verify_ssl=verify,
    transient=(username is not None and session_cookie_file is None
               and cookie_auth != 'ancestors-only'),
    session_cookie_file=session_cookie_file,
    cookie_auth=cookie_auth,
    cfg=cfg,
    ...
)
```

**`get_authenticated_opener()`** — new parameters `session_cookie_file`, `cookie_auth`, `cfg`:

```python
def get_authenticated_opener(server, server_entry, username, password,
                              verify_ssl=True, transient=False,
                              extra_cookies=None, host_header=None, connect_to=None,
                              session_cookie_file=None, cookie_auth='all', cfg=None):
    if cookie_auth == 'ancestors-only':
        # Empty in-memory jar for target; ancestor cookies only
        jar = http.cookiejar.MozillaCookieJar()
        opener = _build_opener_from_jar(jar, verify_ssl, host_header, connect_to)
        _merge_ancestor_cookies(jar, cfg or {}, server_entry)
        if username and password:
            _login_into_opener(server, username, password, opener)  # transient
        return opener

    cookie_file = session_cookie_file or _cookie_file_for(server_entry)
    connect_to = connect_to or server_entry.get('connect_to')

    if username and password:
        opener = login(server, username, password, verify_ssl=verify_ssl,
                       extra_cookies=extra_cookies, cookie_file=cookie_file,
                       host_header=host_header, connect_to=connect_to)
        if not transient:
            _ensure_config_dir()
            _save_cookie_jar(opener._jar, cookie_file)  # save before merging ancestors
        _merge_ancestor_cookies(opener._jar, cfg or {}, server_entry)
        return opener

    # No credentials — load stored cookies
    if not os.path.isfile(cookie_file):
        ref = server_entry.get('nickname') or server
        die(f"Not logged in to {ref!r}. Run 'dockside login' first, ...")
    opener = _build_opener(cookie_file, verify_ssl, host_header=host_header,
                           connect_to=connect_to)
    _merge_ancestor_cookies(opener._jar, cfg or {}, server_entry)
    return opener
```

The `_build_opener_from_jar(jar, ...)` helper is a small variant of `_build_opener` that accepts a pre-constructed `CookieJar` instead of a file path (or `_build_opener` can be adapted to accept either).

The `cfg` object must be passed from `_client()` since `CONFIG_DIR` and `load_config()` are module-level — no change to how config is loaded, just pass the already-loaded dict through.

---

### 5. Test harness changes

#### `use_cli_admin_creds` and its relationship to test modes

`DocksideClient` has two operating modes for admin, controlled by the `use_cli_admin_creds` flag (renamed from `session_only`). This flag does **not** apply to test-user clients (dev1, dev2, viewer), which always use explicit credentials:

**`use_cli_admin_creds=False`** — developer convenience mode for **local** and **remote** modes only:
- Admin has already run `dockside login` interactively before the test run.
- No `--username`/`--password` are passed to the CLI; `DOCKSIDE_CONFIG_DIR` is not overridden.
- The CLI reads `~/.config/dockside/config.json` and its stored admin session cookie.
- `DOCKSIDE_TEST_ADMIN` env var is unset; `run_tests_main.py` detects this and sets `admin_creds = (None, None)`.
- **Harness mode cannot use this** — it runs unattended in a container with no prior `dockside login`.
- After Option 8: **unchanged**. Since the system config is already used, any `parent` entry already declared there means ancestor cookies are merged automatically.

**`use_cli_admin_creds=True`** — explicit-credentials mode, **required** for harness mode, **optional** for local/remote:
- `DOCKSIDE_TEST_ADMIN=user:pass` is set; credentials are passed via `--username`/`--password` on every CLI call.
- Currently: creates a temp dir; sets `DOCKSIDE_CONFIG_DIR` to it. The temp dir is empty — no `parent` chain, no ancestor cookies (Problem B is structurally impossible to solve in this model).
- After Option 8: **no `DOCKSIDE_CONFIG_DIR` override**. A per-client **temp file** is created and passed as `--cookie-file <path>` on every call. The CLI uses the system config (`~/.config/dockside/`) for the `parent` chain, while the target's session is isolated to the temp file.

All test-user clients (dev1, dev2, viewer) always use `use_cli_admin_creds=True` (they always have explicit credentials). This flag is a concept that only ever applies to the admin client.

#### Sequence of events in the test run

1. **`_env_manager.setup()`** uses `admin_client` to create test roles, user accounts (dev1, dev2, viewer), and profiles via `user create`, `role create`, etc. Admin authenticates to the target with its own credentials (or stored session if `session_only=True`); its session is isolated in admin's own temp file. This step does **not** involve dev1/dev2/viewer clients at all.

2. **`_setup_clients()`** creates separate `DocksideClient` instances for dev1, dev2, viewer. Each gets its own temp file (`tempfile.mkstemp()`). `_base_args()` appends `--cookie-file <tempfile>` on every call. `DOCKSIDE_CONFIG_DIR` is not set.

3. **`_validate_client()`** calls `list_containers()` on each test-user client — the first time each test user authenticates: fresh login with `--username`/`--password`, session saved to the client's temp file. In remote/inner mode, ancestor cookies from the system config's `parent` chain are automatically merged.

4. **Subsequent test calls** for dev1/dev2/viewer load the saved session from their respective temp files — no re-login. Each client's temp file is isolated from admin's and from each other.

5. **Cleanup**: `DocksideClient.cleanup()` deletes `_session_cookie_file`. No temp directories.

#### Changes to `DocksideClient`

- Replace `_config_dir = tempfile.mkdtemp(...)` with `_session_cookie_file = tempfile.mkstemp(suffix='.txt', prefix='dockside-sess-')[1]` (for `session_only=False`).
- `_base_args()`: append `--cookie-file <_session_cookie_file>` when set.
- `_run()`: remove `env['DOCKSIDE_CONFIG_DIR'] = self._config_dir`; always `env.pop('DOCKSIDE_CONFIG_DIR', None)`.
- `_reload_cookie_jar()`: currently a bug — looks for `cookies.txt` in `_config_dir` but the CLI writes to `_config_dir/cookies/<slug>.txt`. With the new approach, reload from `_session_cookie_file` directly.
- `cleanup()`: delete `_session_cookie_file` instead of `_config_dir`.

---

### 6. Behaviour by mode

| Mode | Admin `use_cli_admin_creds` | Outer/inner? | Admin client | Test-user client (dev1/dev2/viewer) | Result |
|------|----------------------------|-------------|--------------|--------------------------------------|--------|
| **Harness** | `True` (required; explicit creds always set) | No outer proxy | `--cookie-file <admin-tempfile>` + creds; system config used | `--cookie-file <user-tempfile>` + creds; system config used | Correct: each client isolated; no outer cookies needed |
| **Local** | `False` (pre-authenticated) or `True` | No outer proxy | `False`: system stored session, no flags; `True`: `--cookie-file <tempfile>` + creds | `--cookie-file <user-tempfile>` + creds | Correct in both admin variants; no outer cookies needed |
| **Remote, target = outer** | `False` or `True` | No inner | Same as local | `--cookie-file <user-tempfile>` + creds | Correct: single server, no parent chain |
| **Remote, target = inner** | `False` or `True` | Outer proxy required | `False`: system config has `parent` declared → outer cookies merged automatically; `True`: same (system config used via temp-file path) | `--cookie-file <user-tempfile>` + creds; outer cookies merged from `parent` chain in system config | Correct: outer proxy satisfied; inner authenticates as test user |

Key: `use_cli_admin_creds=False` is only usable for admin in local/remote modes where the developer has pre-authenticated. Harness mode always uses `use_cli_admin_creds=True`. Test-user clients always use `use_cli_admin_creds=True`.

---

### 7. Implementation steps and critical files

#### Step 0 — Commit the plan (do first)
Copy this plan file to `t/integration/PLAN_cookiejar_isolation.md`, commit on branch `claude/update-integration-tests-cli-OtdcG`, and push. This preserves the design in the branch so the implementation has a stable reference even if it gets stuck.

#### Step 1 — CLI changes (`cli/dockside_cli.py`)
- Add `_merge_ancestor_cookies(jar, cfg, server_entry, _seen=None)`.
- Add `_build_opener_from_jar(jar, verify_ssl, host_header, connect_to)` (variant of `_build_opener` accepting a pre-built jar).
- Add `--cookie-file PATH` (dest `session_cookie_file`) and `--cookie-auth {all,ancestors-only}` to `_add_global_flags()`.
- Update `get_authenticated_opener()` with `session_cookie_file`, `cookie_auth`, `cfg` params; call `_merge_ancestor_cookies()` before returning.
- Update `_client()` to extract the new args, compute `transient` correctly, and pass `cfg` through.
- Add `--parent` flag to `login` subcommand (so operators can declare the parent relationship when registering a server).

#### Step 2 — Harness changes (`t/integration/lib/dockside_test.py`)
- Rename `session_only` parameter/attribute to `use_cli_admin_creds` throughout. Rationale: the new name describes the observable behaviour — whether the admin client should pass explicit `--username`/`--password` flags to the CLI — rather than the indirect mechanism. `use_cli_admin_creds=False` means admin has pre-authenticated via `dockside login` (interactive dev use); `use_cli_admin_creds=True` means the harness supplies credentials on every call (harness mode and explicit-creds dev mode). Update all callers in `run_tests_main.py` and any other files that construct `DocksideClient` with this flag.
- Replace `_config_dir = tempfile.mkdtemp(...)` with `_session_cookie_file = tempfile.mkstemp(...)[1]` for `use_cli_admin_creds=True` clients.
- `_base_args()`: append `--cookie-file <_session_cookie_file>` when set.
- `_run()`: always `env.pop('DOCKSIDE_CONFIG_DIR', None)`; remove `env['DOCKSIDE_CONFIG_DIR'] = ...` line.
- `_reload_cookie_jar()`: read from `_session_cookie_file` instead of `_config_dir/cookies.txt`.
- `cleanup()`: remove `_session_cookie_file` instead of `_config_dir`.

#### Step 3 — Runner changes (`t/integration/lib/run_tests_main.py`)
- No temp-dir creation for test-user clients; no `DOCKSIDE_CONFIG_DIR` env var handling.

#### Step 4 — Update `t/integration/README.md`
- Reflect the `use_cli_admin_creds` rename and the `--cookie-file` / `parent` mechanism.
- Add an appendix section: **"Why the test harness uses the CLI"** — adapt the Supplement section from this plan, covering the rationale (full product surface testing, `check-url` coverage, no duplicate HTTP client code) and the tradeoffs (subprocess overhead, failure ambiguity), and noting that for local and harness modes the CLI dependency could be made optional in a future update by falling back to the harness's own `http_check()`.

#### Step 5 — Smoke test
Run the harness against a local Dockside instance to confirm auth works for all client roles.

**Not needed** (compared to earlier Option 8 drafts): no config.json cloning, no cookie file copying, no `DOCKSIDE_TEST_OUTER_URL` harness logic — the system config's `parent` chain handles outer/inner automatically.

---

## Supplement: Is using the CLI in the test harness desirable?

The question is whether the test harness should call the CLI as a subprocess (current approach after B&C) rather than making direct authenticated HTTP requests as it did before.

### Arguments for using the CLI

**Tests the full user-facing interface.** Dockside ships the CLI as a first-class product. Every test invocation exercises CLI argument parsing, output serialisation, error handling, and cookie management alongside the server API. A broken CLI is a user-facing bug; these tests will catch it.

**`check-url` specifically.** The `check-url` CLI command encapsulates non-trivial logic: TCP-override routing (`--connect-to`), cross-domain cookie injection, and JSON output. This logic cannot be tested by direct urllib calls. Using `check-url` in harness tests is the only way to get integration coverage of it.

**No duplicate HTTP client code.** Before B&C the harness had its own `_ConnectToHTTPSConnection`, `_ConnectToHandler`, and cookie-injection logic that mirrored the CLI. Using the CLI collapses this into a single implementation.

**Dogfooding.** The CLI is the tool operators actually use to interact with Dockside. Running tests via the CLI validates the experience operators will have, not just an internal API surface.

### Arguments against (downsides)

**Test failure ambiguity.** When a test fails it is not immediately clear whether the server API is wrong or the CLI is wrong. A CLI argument-parsing bug could cause all tests to fail even when the server is healthy. This conflation makes CI less precise as a signal of server correctness.

**Subprocess overhead.** Each API call spawns a Python subprocess, which is meaningfully slower than an in-process HTTP call. For large test suites this accumulates.

**Cookie management complexity.** The entire issue being analysed here — ancestor cookies, `parent` chains, `--cookie-file` overrides — exists precisely because the harness delegates session management to the CLI. A direct HTTP harness would manage cookies entirely in-process with no such complexity.

**Complexity asymmetry across modes.** Local mode and harness mode involve only a single Dockside instance. The outer/inner cookie complexity is entirely a remote-mode concern. In the simpler modes the CLI adds subprocess overhead and cookie-management machinery (however lightweight) that has no additional test value over a direct urllib call.

### Business / test-effectiveness verdict

The downside of test failure ambiguity is real but manageable: the CLI captures stderr from every invocation and exposes it in test output, so CLI bugs present as distinctive, diagnosable error messages rather than silent misassertions. The cookie management complexity is a one-time implementation cost that, via Option 8, also directly improves the CLI for interactive users (the `parent` field and `--cookie-file` are genuinely useful features, not test scaffolding).

The core case for the CLI-based harness is that Dockside is not only a server product — the CLI is part of what is shipped and supported. Integration tests that exercise the CLI alongside the server validate the product as a whole, not just its internal API. This is worth the additional complexity, provided the complexity is properly encapsulated (as Option 8 does).

The one area where the verdict is less clear is HTTP service checks (`check-url`) for local/harness modes, where the outer/inner scenario never arises. Here the CLI approach adds no cookie-specific value, only subprocess overhead and CLI-correctness coverage. This is still positive (testing `check-url` itself), but operators who find the overhead problematic could use `http_check()` (already present in `dockside_test.py`) for the simpler modes and `check-url` only for remote mode. For now, keeping a single code path (always use `check-url`) is the right default; micro-optimisation can come later if test suite speed becomes a concern.
