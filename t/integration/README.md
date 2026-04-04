# Dockside Integration Tests

End-to-end integration tests that exercise the live Dockside API, CLI, and
proxy layer. Tests are written in Python 3.6+ with zero external dependencies
and produce TAP-compatible output.

## What is covered

| Test file | What it tests |
|---|---|
| `01_auth.py` | Authentication, permission checks, viewer cannot create |
| `02_lifecycle_alpine.py` | Create / start / stop / remove (alpine image) |
| `03_lifecycle_debian.py` | Create / start / stop / remove (debian image) |
| `04_access_and_http.py` | Access control: visibility, router filtering, HTTP proxy responses |
| `05_edit.py` | Edit metadata fields; viewer/non-developer cannot edit |
| `06_git_profile.py` | Git URL, branch, PR options |
| `07_ide.py` | IDE creation; viewer/developer IDE access |
| `08_network.py` | Network assignment; harness-only: create/attach/detach networks |
| `09_ssh.py` | Inbound SSH via wstunnel; outbound SSH via integrated ssh-agent |

## Test Modes

### Remote mode
Testing against an existing Dockside instance from an external machine:
```bash
DOCKSIDE_TEST_HOST=www.local.dockside.dev \
DOCKSIDE_TEST_ADMIN=admin:MySecret99 \
bash t/integration/run_tests.sh
```

### Local mode
Testing from inside the Dockside container itself (e.g. via `docker exec`):
```bash
DOCKSIDE_TEST_MODE=local \
DOCKSIDE_TEST_HOST=www.local.dockside.dev \
DOCKSIDE_TEST_ADMIN=admin:MySecret99 \
bash t/integration/run_tests.sh
```

### Harness mode (CI)
Launches a fresh Dockside container, runs all tests, then removes the container:
```bash
DOCKSIDE_TEST_IMAGE=newsnowlabs/dockside:latest \
bash t/integration/run_tests.sh
```

### Via test.sh
```bash
DOCKSIDE_TEST_IMAGE=newsnowlabs/dockside:latest \
bash test.sh --only integration
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `DOCKSIDE_TEST_MODE` | auto-detected | `local`, `remote`, or `harness` |
| `DOCKSIDE_TEST_HOST` | — | Public FQDN, e.g. `www.local.dockside.dev` |
| `DOCKSIDE_TEST_ADMIN` | — | `username:password` (if unset, uses stored CLI session) |
| `DOCKSIDE_TEST_IMAGE` | — | Docker image for harness mode |
| `DOCKSIDE_TEST_VERIFY_SSL` | `0` | Set `1` to verify SSL certificates |
| `DOCKSIDE_TEST_CONTAINER_ID` | — | Running Dockside container ID (enables docker-exec SSH tests in non-harness modes) |
| `DOCKSIDE_TEST_SSH_SERVER` | `git@github.com` | Outbound SSH server for test 09 B |
| `DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY` | mode default | `1` = allow creating/attaching Docker networks; `0` = disallow |
| `DOCKSIDE_TEST_NAME_SUFFIX` | (none) | Suffix for test resource names; `auto` generates a random 6-char hex string |

## Running Subsets

```bash
# Run only access control tests:
DOCKSIDE_TEST_IMAGE=... bash t/integration/run_tests.sh --only 04

# Run only SSH tests:
DOCKSIDE_TEST_IMAGE=... bash t/integration/run_tests.sh --only 09

# Run only network tests with explicit network modification allowed:
DOCKSIDE_TEST_IMAGE=... DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY=1 bash t/integration/run_tests.sh --only 08
```

## Admin Credentials and Session Isolation

The harness creates separate `DocksideClient` instances for each test role
(admin, dev1, dev2, viewer). Each client with explicit credentials gets its own
temporary session cookie file (via `--cookie-file <tmpfile>`) so sessions are
completely isolated — the admin's cookies never contaminate dev1/dev2/viewer
requests and vice versa.

### `use_cli_admin_creds` flag

`DocksideClient` accepts a `use_cli_admin_creds` parameter that controls how
the admin client authenticates:

- **`use_cli_admin_creds=True`** (required for harness mode, optional for
  local/remote): explicit `--username`/`--password` flags are passed to the CLI
  on every call; a per-client temporary cookie file isolates the session.
  `DOCKSIDE_TEST_ADMIN=user:pass` must be set.

- **`use_cli_admin_creds=False`** (interactive dev use only): no credentials
  are passed; the CLI reads its stored session from a prior `dockside login`.
  `DOCKSIDE_TEST_ADMIN` must be unset. Cannot be used in harness mode.

All test-user clients (dev1, dev2, viewer) always use `use_cli_admin_creds=True`.

### Outer/inner cookie propagation (remote mode)

When the test target is an inner Dockside instance (running as a devcontainer
inside an outer Dockside), every request must carry both an outer and an inner
session cookie. The CLI handles this automatically when the server's config
entry declares a `parent`:

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

Set this up with `dockside login --parent outer` when registering the inner
server. With `--cookie-file <tmpfile>`, the target's session is isolated to the
temp file while ancestor (outer) cookies are still loaded from the system config's
parent chain automatically.

## For AI Developers (Claude, etc.)

When working inside a Dockside devtainer:

- **Inside a devtainer** (profiles 00/01/91/92): the outer Dockside server is
  accessible via its public FQDN. Use **remote mode**:
  ```bash
  DOCKSIDE_TEST_HOST="${DOCKSIDE_HOST:-www.local.dockside.dev}" \
  DOCKSIDE_TEST_ADMIN=admin:pass \
  bash t/integration/run_tests.sh
  ```

- **Inside the Dockside container itself** (via `docker exec`): use **local mode**.

- **In CI / fully isolated**: use **harness mode** with `DOCKSIDE_TEST_IMAGE`.

Note: in harness and local modes the tests connect to `https://localhost` and
inject the correct `Host` header via the `--host-header` CLI flag.

## Access Control Model

Dockside's access control uses two distinct concepts:

**Profile `auth` array** — defines the *selectable range* of access modes the
owner may choose for each router. This does not set the active mode.

**`meta.access.{routerName}`** — the *active* access mode for a given router
on a live devtainer. Changed via the Edit UI or CLI `--access` flag.

### Access levels

| Mode | Who can access the service |
|---|---|
| `public` | Everyone (unauthenticated + all users) |
| `user` | Any authenticated user |
| `viewer` | Owner + named developers + named viewers |
| `developer` | Owner + named developers only |
| `owner` | Owner only |

### Viewer vs Developer

**Viewers** (listed in `meta.viewers`):
- Can view/list the devtainer
- Can access services set to `viewer`, `user`, or `public` mode
- **Cannot** access the IDE or SSH router (always `owner`/`developer` only)
- **Cannot** edit any container properties

**Developers** (listed in `meta.developers`, plus the owner):
- Can view/list the devtainer
- Can access the IDE and SSH router
- Can edit: description, viewers, developers, IDE, access mode, network

**Admin users** (role `admin`, with `viewAllContainers` permission):
- Can see all containers regardless of sharing

### Router filtering

`GET /containers` (list) and `GET /containers/{id}` (get) filter each
container's `profileObject.routers` to only those the requesting user can
access at the current `meta.access` setting. A viewer will see zero routers
for a container whose services are all set to `developer` mode.

### IDE and SSH routers

Always restricted to `owner` or `developer`; the profile `auth` array for
these routers should not include `viewer`, `user`, or `public`.

## SSH Tests

Tests `09_ssh.py` use committed test-only Ed25519 keypairs:
- `t/integration/config/ssh/testdev1_ed25519` + `.pub`
- `t/integration/config/ssh/testdev2_ed25519` + `.pub`

These are safe to commit — they are purpose-generated, non-production keys
used only against ephemeral test instances. They are embedded in `users.json`
so Dockside automatically populates `~/.ssh/authorized_keys` inside devtainers.

**Test A (inbound via wstunnel):** requires `wstunnel` in `PATH`. Skipped otherwise.
The ProxyCommand format mirrors what `SSHInfo.vue` generates in the UI.

**Test B (outbound via ssh-agent):** requires `docker` CLI and a known
container ID. Set `DOCKSIDE_TEST_SSH_SERVER=git@github.com` (or another server
where the testdev1 public key is pre-authorized).

## Network Tests

`08_network.py` has two tiers:

**Common tests (all modes):** use only networks already connected to the
Dockside container. No new networks are created or modified.

**Harness-only tests (or `DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY=1`):** create a
unique Docker network, attach it to the Dockside container, verify it appears
in available networks, then clean up. Safe to run against any Dockside
instance you control — never deletes or modifies pre-existing networks.

---

## Appendix: Why the test harness uses the CLI

The harness drives all API operations and HTTP service checks via the Dockside
CLI (`dockside --output json ...`) as a subprocess rather than making direct
HTTP requests. This is a deliberate design choice.

### Arguments for using the CLI

**Tests the full user-facing interface.** Dockside ships the CLI as a
first-class product. Every test invocation exercises CLI argument parsing,
output serialisation, error handling, and cookie management alongside the
server API. A broken CLI is a user-facing bug; these tests catch it.

**`check-url` specifically.** The `check-url` CLI command encapsulates
non-trivial logic: TCP-override routing (`--connect-to`), cross-domain cookie
injection, and JSON output. This logic cannot be exercised by direct urllib
calls. Using `check-url` in harness tests is the only way to get integration
coverage of it.

**No duplicate HTTP client code.** Without the CLI the harness would need its
own `_ConnectToHTTPSConnection`, `_ConnectToHandler`, and cookie-injection
logic mirroring the CLI. The CLI-based approach collapses this into a single
implementation.

**Dogfooding.** The CLI is the tool operators actually use to interact with
Dockside. Running tests via the CLI validates the experience operators will
have, not just an internal API surface.

### Tradeoffs

**Test failure ambiguity.** When a test fails it is not immediately clear
whether the server API or the CLI is at fault. CLI bugs present as distinctive
error messages in captured stderr, which makes them diagnosable, but they can
cause many tests to fail at once even when the server is healthy.

**Subprocess overhead.** Each API call spawns a Python subprocess. For large
test suites this adds up compared to in-process HTTP calls.

**Cookie management complexity.** The session-isolation machinery (`--cookie-file`,
`parent` chain, `use_cli_admin_creds`) exists because the harness delegates
session management to the CLI. A direct HTTP harness would manage cookies
entirely in-process with no such complexity.

### Future option

For local and harness modes (single Dockside instance, no outer/inner proxy),
the CLI dependency for service checks could be made optional: `check_service()`
could fall back to the harness's own `http_check()` function which already
supports `connect_to` TCP overrides. This would reduce subprocess overhead
without losing `check-url` coverage in remote/inner mode where it matters most.
This optimisation is deferred; a single code path (always use `check-url`) is
the right default for now.
