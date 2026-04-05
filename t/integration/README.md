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

### Local mode inside an 'inner' Dockside development container
When Dockside is developed using Dockside, this command runs tests inside an 'inner' Dockside development container called `mydockside`:
```bash
# Preferred: authenticate the CLI once, then reuse the stored admin session
dockside login \
  --connect-to 127.0.0.1 \
  --no-verify \
  --nickname local \
  --server https://www-mydockside.local.dockside.dev/

DOCKSIDE_TEST_MODE=local \
DOCKSIDE_TEST_NAME_SUFFIX=auto \ # Use isolated user/role/profile names
DOCKSIDE_TEST_HOST='https://www-mydockside.local.dockside.dev/' \
bash t/integration/run_tests.sh
```

### Local mode Inside Vanilla Cloud Environment (e.g. Claude Code for Web)
```bash
# Assumes Debian, and that dockerd is installed but not running
# - installs needed packages
# - launches Dockside with `--run-dockerd`
# - authenticates the CLI using auto-generated admin credentials
./build/development/run-local.sh

# Now run tests...
DOCKSIDE_TEST_MODE=local \
DOCKSIDE_TEST_NAME_SUFFIX="auto" \
DOCKSIDE_TEST_HOST="https://www.local.dockside.dev/" \
./t/integration/run_tests.sh
```

### Local mode via `docker exec`
Testing from inside the Dockside container itself (e.g. via `docker exec`):
```bash
# Preferred: authenticate the CLI once, then reuse the stored admin session
dockside login \
  --connect-to 127.0.0.1 \
  --no-verify \
  --nickname local \
  --server https://www.local.dockside.dev/

DOCKSIDE_TEST_MODE=local \
DOCKSIDE_TEST_NAME_SUFFIX=auto \ # Use isolated user/role/profile names
DOCKSIDE_TEST_HOST='https://www.local.dockside.dev/' \
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

### Remote mode
Testing from an 'external' machine (e.g. Macbook) against a preexisting Dockside container instance (which may be running locally or remotely):
```bash
# Preferred: authenticate the CLI once, then reuse the stored admin session
dockside login \
   --nickname local \
   --server https://www.local.dockside.dev

DOCKSIDE_TEST_NAME_SUFFIX=auto # Use isolated user/role/profile names \
DOCKSIDE_TEST_HOST='https://www.local.dockside.dev/' \
bash t/integration/run_tests.sh
```

#### Outer/inner cookie propagation in Remote Mode

When the test target is an inner Dockside instance (running as a devcontainer
inside an outer Dockside), every request must carry both an outer and an inner
session cookie. The CLI handles this automatically when the server's config
entry declares a `parent`:

```json
{
  "servers": [
    {"url": "https://www.local.dockside.dev", "nickname": "outer"},
    {
      "url": "https://www-inner.local.dockside.dev",
      "nickname": "inner",
      "parent": "outer"
    }
  ]
}
```

Set this up with `dockside login --parent outer` when registering the inner
server.

Once the CLI is authenticated to both the outer and inner Dockside instances
(to the outer, as any user owning or with development access to the inner;
and to the inner, as `admin`), the harness passes `--cookie-auth ancestors-only`
and `--cookie-file <tmpfile>` on future CLI calls made with explicit credentials
for non-admin test users.

`--cookie-auth ancestors-only` prevents the CLI from loading any stored session
cookies for the target inner instance, while still merging ancestor cookies for
the outer instance. As a result, the login POST carries only the ancestor
cookie(s) plus the explicit test-user credentials, and subsequent requests in
that same CLI invocation use the newly established inner session for that test
user rather than the stored inner `admin` session.

`--cookie-file <tmpfile>` provides a dedicated per-client cookie path outside
the system cookie store. In the intended model, this file is where the newly
established inner-session cookie for that explicit test user should be persisted,
so later CLI invocations for the same test client can reuse that inner session
without re-sending the user's credentials, while ancestor cookies for the outer
instance continue to be merged automatically from the system config's `parent`
chain.

In the current implementation, the `ancestors-only` code path already achieves
the security-critical part of this design: it avoids loading the stored inner
`admin` session and ensures the login POST carries only ancestor cookies plus
the explicit test-user credentials. However, the new inner test-user session is
currently retained only for that one CLI process and is not yet persisted to
the temp cookie file for reuse across later subprocess invocations.

(Simplest implementation:
- keep --ancestors-only logic unchanged (for backwards compatibility);
- ensure `--cookie-file <path>` correctly overrides the system path to the target's 
  `cookie_file` for that invocation;
- in the new persistent-login option scenario, ensure that tests provide an empty
  per-test-user-namd temp file for `--cookie-file <path>` for each test user's
  initial login; and thereafter ensure subsequent CLI calls for each test user use
  `--cookie-file <path>` with the path to that test user's file;
- at end of test, clean up all the temp files.)

> N.B. Important: if only `DOCKSIDE_TEST_HOST=...` is set, the runner selects
**remote** mode. To get local-mode TCP routing to `localhost`, set
`DOCKSIDE_TEST_MODE=local` explicitly.
>
> In local and harness modes the canonical request URL remains
`https://$DOCKSIDE_TEST_HOST`, but the TCP leg is routed with `--connect-to`
(`localhost` in local mode, the harness container address in harness mode).
This preserves the public hostname for TLS SNI and Host-header handling while
avoiding dependence on public routing from inside the Dockside container.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `DOCKSIDE_TEST_MODE` | (if `DOCKSIDE_TEST_IMAGE`, then `harness`; else `remote`) | `local`, `remote`, or `harness` |
| `DOCKSIDE_TEST_HOST` | — | Public FQDN or URL, e.g. `www.local.dockside.dev` or `https://www.local.dockside.dev/` |
| `DOCKSIDE_TEST_ADMIN` | — | `username:password` (if unset, uses stored CLI session) |
| `DOCKSIDE_TEST_IMAGE` | — | Docker image for harness mode |
| `DOCKSIDE_TEST_HARNESS_ZONE` | `dockside.test` | DNS zone used by harness mode when launching a fresh Dockside container |
| `DOCKSIDE_TEST_VERIFY_SSL` | `0` | Set `1` to verify SSL certificates |
| `DOCKSIDE_TEST_CONTAINER_ID` | — | Running Dockside container ID (enables docker-exec SSH tests in non-harness modes) |
| `DOCKSIDE_TEST_SSH_SERVER` | `git@github.com` | Outbound SSH server for test 09 B |
| `DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY` | mode default | `1` = allow creating/attaching Docker networks; `0` = disallow |
| `DOCKSIDE_TEST_NAME_SUFFIX` | (none) | Suffix for test resource names; `auto` generates a random 6-char hex string |
| `DOCKSIDE_TEST_SKIP_CLEANUP` | `0` | Usually set via `--skip-cleanup`; preserves created test roles/users/profiles for investigation |

## Runner Flags

| Flag | Effect |
|---|---|
| `--only <prefix>` | Run only test files whose filename starts with the prefix, e.g. `04` |
| `--verbose` | Print every CLI command executed by the harness and extra probe diagnostics for skipped HTTP checks |
| `--debug` | Include verbose mode output plus captured subprocess stdout/stderr |
| `--skip-cleanup` | Preserve the dynamic test environment created by `_EnvManager`; per-test/container teardown still runs |

## Running Subsets

```bash
# Run only access control tests:
bash t/integration/run_tests.sh --only 04

# Run only SSH tests:
bash t/integration/run_tests.sh --only 09

# Run only network tests with explicit network modification allowed:
DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY=1 bash t/integration/run_tests.sh --only 08

# Run a preserved repro with isolated resource names:
DOCKSIDE_TEST_NAME_SUFFIX=auto bash t/integration/run_tests.sh --only 04 --skip-cleanup --verbose
```

## Test Construction

### Admin Credentials and Session Isolation

The harness creates separate `DocksideClient` instances for each test role
(admin, dev1, dev2, viewer). Each client with explicit credentials gets its own
temporary session cookie file (via `--cookie-file <tmpfile>`) so sessions are
completely isolated — the admin's cookies never contaminate dev1/dev2/viewer
requests and vice versa.

The harness also creates its own test roles, users, and embedded alpine/nginx
profiles at runtime. It does not rely on static `t/integration/config/users.json`
or `roles.json` being installed on the target server, other than an `admin` user,
which must have sufficient permissions create the test users/roles/profiles and
execute the tests.

### `use_cli_admin_creds` flag

`DocksideClient` accepts a `use_cli_admin_creds` parameter that controls how
the admin client authenticates:

- **`use_cli_admin_creds=False`** (default; required for harness mode, optional
  for local/remote): explicit `--username`/`--password` flags are passed to the
  CLI on every call; a per-client temporary cookie file isolates the session.
  `DOCKSIDE_TEST_ADMIN=user:pass` must be set.

- **`use_cli_admin_creds=True`** (remote/local modes only): the CLI's
  pre-existing stored session is used — no credentials are passed. Requires a
  prior `dockside login`. `DOCKSIDE_TEST_ADMIN` must be unset. Cannot be used
  in harness mode.

All test-user clients (dev1, dev2, viewer) always use `use_cli_admin_creds=False`.

## Access Control Model

Dockside's access control uses two distinct concepts:

**Profile `auth` array** — defines the *selectable range* of *access modes* the
owner may choose for each router. This does not set the active *access mode*.

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

The harness drives all API operations via the Dockside CLI
(`dockside --output json ...`) as a subprocess. For HTTP service checks it uses
two paths:
- authenticated checks go through the CLI `check-url` command
- anonymous checks use the in-process `http_check()` helper

This split is deliberate: authenticated checks need the CLI's session and
cross-domain cookie logic, while anonymous checks do not.

### Arguments for using the CLI

**Tests the full user-facing interface.** Dockside ships the CLI as a
first-class product. Every test invocation exercises CLI argument parsing,
output serialisation, error handling, and cookie management alongside the
server API. A broken CLI is a user-facing bug; these tests catch it.

**check-url.** The authenticated probe path uses `check-url`,
which encapsulates non-trivial logic: TCP-override routing (`--connect-to`),
cross-domain cookie injection, and JSON output. This logic cannot be exercised
by direct urllib calls. Using `check-url` in the authenticated tests is the
only way to get integration coverage of it.

**No duplicate authenticated HTTP client code.** Without the CLI the harness
would need its own cookie/session/cross-domain request path mirroring the CLI.
The current approach keeps the complex authenticated path in one place.

**Dogfooding.** The CLI is a tool operators actually use to interact with
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

**check-url/http_check split.** For local and harness modes, authenticated service checks still intentionally
use CLI `check-url` so that the CLI's routing/session code is exercised. The
anonymous path already uses `http_check()`, which keeps unauthenticated probes
simple while avoiding unnecessary cookie/session indirection.

## Debugging Service Checks

When an HTTP access test is skipped with messages like `Could not reach nginx service`,
that means the probe did not get any HTTP response at all; it failed at the
transport layer before a status code could be asserted.

Useful reproductions:

```bash
# Preserve resources and print probe diagnostics
DOCKSIDE_TEST_NAME_SUFFIX=auto \
DOCKSIDE_TEST_MODE=local \
DOCKSIDE_TEST_HOST=www.local.dockside.dev \
bash t/integration/run_tests.sh --only 04 --verbose --skip-cleanup

# Reproduce an authenticated probe via the CLI
dockside check-url https://www-my-container.example.test/ --debug-http
```

`--debug-http` is especially useful when the configured server entry contributes
transport settings such as `connect_to`, `parent`, or `no_verify`.
