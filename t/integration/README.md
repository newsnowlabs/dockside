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
| `06_git_profile.py` | Git URL, branch, PR options (PR test requires `DOCKSIDE_TEST_GITHUB_TOKEN`) |
| `07_ide.py` | IDE creation; viewer/developer IDE access |
| `08_network.py` | Network assignment; harness-only: create/attach/detach networks |
| `09_ssh.py` | Inbound SSH via wstunnel |
| `10_ssh_outbound.py` | Outbound self-SSH via the devtainer's integrated ssh-agent |
| `11_admin_api.py` | Admin CRUD round-trips (role/profile/user/`account`) with persisted-shape assertions, verb enforcement (405), role-record validation |
| `12_rejection.py` | Negative paths: rejected launches and disallowed constrained values (image/runtime/unixuser/network/IDE); absent-resource edit/remove/get; self-protection (own manageUsers / admin role / account) and removal of an in-use role |

## Writing tests — hard rules

These tests are a **black-box client of the product, driven only through the `dockside`
CLI**. Follow these rules so the suite stays consistent and maintainable:

1. **Call the CLI; never import it.** Drive the product via the `DocksideClient` methods in
   `lib/dockside_test.py` (`_run(...)`, `check_url(...)`, `create`/`update`/`start`/`stop`/
   `remove`, …), which shell out to `dockside`. Do **not** `import dockside_cli` or call its
   functions from a test or the harness.
2. **If the CLI can't do it, upgrade the CLI — don't work around it.** When a test needs a
   capability the CLI lacks, add the command/flag to `cli/dockside_cli.py` and call it (e.g.
   the self-service account test uses `dockside account edit`, added for exactly this
   reason). Never hand-roll raw HTTP against the server, and never copy CLI internals
   (openers, nest-level / connect-to handling, …) into a test.
3. **Create fixtures at runtime; never rely on pre-existing state.** All users, roles, and
   profiles are created by the harness/tests via the CLI during setup and removed during
   teardown — there are no static `config/users.json` / `config/roles.json` fixtures.
4. **Browser-only surfaces are out of scope** and are verified manually in the Vue UI — e.g.
   the profile-editor `_json` blob encoding and the SSH key editor. The CLI sends real
   fields (never the `_json` wrapper) by design, so the CLI suite covers the field-level
   contract; the UI encoding is a separate, manual check.
5. **Harness-local low-level helpers are allowed** (e.g. the anonymous `http_check` for
   unauthenticated proxy probes) but live in `lib/dockside_test.py` and must be
   self-contained — they never import the CLI.

After changing **server** code, restart the Dockside services before running the suite (the
running server is not auto-reloaded); after changing **client** code, rebuild the Vue bundle.

## Test Modes

### Inside a Dockside development container (recommended for active development)

The recommended way to develop and test Dockside is to launch a Dockside
development container from an outer Dockside server using the
`01-dockside-own-ide` profile.  The inner container runs its own Dockside
instance, and you test that inner instance from within the container itself.

Because the inner container has `ssh` and `wstunnel` available under
`/opt/dockside/system/latest/bin`, you can exercise the **full routing stack**
(host SSH → wstunnel ProxyCommand → inner Dockside's nginx → devtainer
dropbear) without any special setup:

```bash
# Authenticate the CLI once against the inner Dockside server
dockside login \
  --server https://www-mydev.example.dockside.dev

# Run all tests; remote mode is auto-detected from the stored CLI session.
# DOCKSIDE_TEST_CONTAINER_ACCESS defaults to 'ssh', exercising the full routing
# stack (nginx -> wstunnel -> devtainer dropbear) for the SSH and outbound-SSH
# tests; set it to 'docker' to enter the devtainer directly. ('auto' is rejected.)
bash t/integration/run_tests.sh
```

If you want to pin the access method explicitly:
```bash
# Full routing path (nginx + wstunnel + dropbear) — recommended:
DOCKSIDE_TEST_CONTAINER_ACCESS=ssh bash t/integration/run_tests.sh --only 10

# In-container only (bypasses nginx/wstunnel) — faster for targeted debugging:
DOCKSIDE_TEST_CONTAINER_ACCESS=docker bash t/integration/run_tests.sh --only 10
```

### Local mode inside an 'inner' Dockside development container
When the inner Dockside instance is being tested from within itself (i.e. the
test runner and the Dockside server are the same container), use local mode so
the CLI routes to `localhost` rather than via the public hostname:
```bash
# Preferred: authenticate the CLI once, then reuse the stored admin session
dockside login \
  --connect-to 127.0.0.1 \
  --no-verify \
  --nickname local \
  --server https://www-mydockside.local.dockside.dev/

DOCKSIDE_TEST_MODE=local \
DOCKSIDE_TEST_HOST='https://www-mydockside.local.dockside.dev/' \
bash t/integration/run_tests.sh
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
bash t/integration/run_tests.sh
```

### Harness mode (CI)
Launches a fresh Dockside container, runs all tests, then removes the container.
By default the harness also creates an isolated temporary CLI config directory,
logs in there, and drives the harness target through the CLI's stored server
entry rather than by forcing `--connect-to` on every CLI call:
```bash
DOCKSIDE_TEST_IMAGE=newsnowlabs/dockside:latest \
bash t/integration/run_tests.sh
```

Set `DOCKSIDE_TEST_HARNESS_ISOLATED_CLI_CONFIG=0` to fall back to the legacy
direct `--connect-to` harness transport.

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
and to the inner, as `admin`), the harness passes `--cookie-file <tmpfile>` on
future CLI calls made with explicit credentials for non-admin test users.

`--cookie-file <tmpfile>` provides a dedicated per-client cookie path outside
the system cookie store. For test-user clients, the harness creates an
initially-empty per-user temp file, continues to pass explicit credentials on
every CLI invocation, and cleans the file up at test end. Ancestor cookies for
the outer instance continue to be merged automatically from the system config's
`parent` chain, so the login POST to an inner instance still carries the outer
session cookie(s) needed by the proxy.

An optional mode (`DOCKSIDE_TEST_REUSE_USER_SESSIONS=1`) reuses each
test user's temp cookie file on later CLI subprocesses after an initial
credentialed call has seeded it, while retrying only read-only commands with
explicit credentials if the reused session fails.

When rerunning with a fixed suffix, the harness by default
(`DOCKSIDE_TEST_CLEANUP_REUSED=0`) removes only the resources the current run
created and **preserves** any pre-existing roles, users, and profiles it merely
reused — so a run can never delete resources it did not create. Set
`DOCKSIDE_TEST_CLEANUP_REUSED=1` (only on an instance you own) to also remove the
reused (pre-existing) resources for that suffix at the end of the run.

The suffix itself must be non-empty: `DOCKSIDE_TEST_NAME_SUFFIX` defaults to
`auto` (a random hex string) when unset, and an explicitly-empty value is
rejected, because bare un-suffixed names could collide with — and then mutate or
delete — real resources on a shared instance.

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
| `DOCKSIDE_TEST_HOST` | current CLI server URL | Public FQDN or URL, e.g. `www.local.dockside.dev` or `https://www.local.dockside.dev/`; if unset outside harness mode, the runner uses the CLI's currently selected server |
| `DOCKSIDE_TEST_ADMIN` | — | `username:password` (if unset, uses stored CLI session) |
| `DOCKSIDE_TEST_IMAGE` | — | Docker image for harness mode |
| `DOCKSIDE_TEST_HARNESS_ZONE` | `dockside.test` | DNS zone used by harness mode when launching a fresh Dockside container |
| `DOCKSIDE_TEST_HARNESS_ISOLATED_CLI_CONFIG` | `1` | In harness mode, create a temporary `DOCKSIDE_CLI_CONFIG` and temporary server entry so the CLI's stored transport settings drive test traffic; set `0` for legacy direct `--connect-to` transport |
| `DOCKSIDE_TEST_VERIFY_SSL` | `0` | Set `1` to verify SSL certificates |
| `DOCKSIDE_TEST_CONTAINER_ID` | auto in `local`/`harness` | The Dockside container's id or name, used by the network-attach tests (08 `test_05`/`test_06`) to `docker network connect` a throwaway network to it. In `local`/`harness` mode it is auto-detected (from `/etc/service/nginx/data/ctr-id`, else the hostname, which equals the container name in a Dockside-launched container); set it explicitly for an "alongside" run or to override. Only used when network modification is enabled, and only when the reachable docker daemon manages that container (not under a sysbox-runc inner daemon) |
| `DOCKSIDE_TEST_CONTAINER_ACCESS` | `ssh` | Access method for tests that inspect a devtainer: `ssh` (default, via wstunnel) or `docker` (docker exec). `auto` is rejected — choose explicitly. |
| `DOCKSIDE_TEST_IMAGE_REGISTRY` | — | Registry mirror prefix for bare Docker Hub image names (e.g. `mirror.gcr.io/library`). Images with an explicit registry host are unaffected. Useful on hosts with Docker Hub pull-rate limits. |
| `DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY` | mode default | `1` = allow creating/attaching Docker networks; `0` = disallow |
| `DOCKSIDE_TEST_NAME_SUFFIX` | `auto` | Suffix for test resource names; `auto` generates a random 6-char hex string. An explicitly-empty value is rejected |
| `DOCKSIDE_TEST_CLEANUP_REUSED` | `0` | When `1`, also remove reused (pre-existing) test roles/users/profiles for the active suffix, not just resources created by the current run — only safe on an instance you own |
| `DOCKSIDE_TEST_VERBOSE` | `0` | Set `1` to print each CLI invocation. **Secret-bearing** — the argv includes `--gh-token`/`--password`; do not share the output |
| `DOCKSIDE_TEST_DEBUG` | `0` | Set `1` for full diagnostics (CLI argv, raw request/response bodies, generated SSH config). **Secret-bearing** — includes tokens, passwords and session cookies; do not paste into bug reports or shared logs |
| `DOCKSIDE_TEST_SKIP_CLEANUP` | `0` | Usually set via `--skip-cleanup`; preserves created test roles/users/profiles for investigation |
| `DOCKSIDE_TEST_GITHUB_TOKEN` | — | GitHub personal access token; enables `06_git_profile.py` test_03 (PR checkout via `gh pr checkout`); test is skipped if unset |

If `DOCKSIDE_TEST_HOST` is unset outside harness mode, the runner reads the
current CLI config (`DOCKSIDE_CLI_CONFIG`, `DOCKSIDE_CONFIG_DIR`, or
`~/.config/dockside`) and uses the currently selected server URL. The harness
still verifies the effective admin identity and permissions via `dockside
whoami` before creating any test resources.

## Output buffering

`run_tests.sh` invokes Python with `-u` (unbuffered) so TAP output lines reach
the terminal or log file immediately. If you invoke `run_tests_main.py` directly,
pass `-u` or set `PYTHONUNBUFFERED=1` to avoid lines being held in an 8 KB
block buffer until it fills or the process exits.

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
bash t/integration/run_tests.sh --only 04 --skip-cleanup --verbose
```

## Test Construction

### Test Imperatives

- Each test must be deterministic and independent of execution order.
- A test must either keep a container alive for the whole class or create a fresh per-test container; do not mix those models accidentally.
- Successive test methods must not remove a container and then recreate a container with the same name in the next method. Asynchronous `stop --no-wait` / `remove --no-wait` cleanup can race with the next method's `setUp()`.
- If per-method cleanup removes containers, use a distinct container name per test method.
- If a class intentionally shares a container across methods, keep creation and cleanup at class scope (`setUpClass` / `tearDownClass`) and make the stateful progression explicit in the test docstring.
- Tests must not rely on pre-existing roles, users, profiles, or container state outside the harness-managed dynamic environment.
- Mutating commands should be issued once; any wait for resulting state must be done by polling read-only APIs rather than by replaying the mutation.
- After changing state that is reflected through cached container metadata, tests should allow for bounded convergence by polling rather than assuming immediate readback. This applies in particular to:
  - removed containers, where Dockside may keep the reservation record briefly before removing it
  - Docker state that Dockside learns via `docker-event-daemon` from dockerd events, so an API read may lag briefly behind a completed Docker operation.

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

## Git Profile Tests

`06_git_profile.py` tests the git-repo launch feature: cloning a repo, checking
out a branch, and checking out a PR via `gh pr checkout`.

The PR test (`test_03`) requires a GitHub personal access token so that `gh` can
authenticate inside the devtainer:

```bash
DOCKSIDE_TEST_GITHUB_TOKEN=<token> \
DOCKSIDE_TEST_CONTAINER_ACCESS=docker \
bash t/integration/run_tests.sh --only 06
```

If `DOCKSIDE_TEST_GITHUB_TOKEN` is not set the PR test is **skipped** (not
failed). The remaining tests (default-branch clone, explicit branch, alternate
images) run without any token.

If you already have a token stored via `gh auth login` on the host, you may
populate the variable automatically — but only if you are comfortable with the
token being passed into ephemeral test containers as a `GH_TOKEN` environment
variable (visible via `docker inspect` and container logs):

```bash
DOCKSIDE_TEST_GITHUB_TOKEN=$(/opt/dockside/system/latest/bin/gh auth token 2>/dev/null) \
DOCKSIDE_TEST_CONTAINER_ACCESS=docker \
bash t/integration/run_tests.sh --only 06
```

## SSH Tests

Tests `09_ssh.py` and `10_ssh_outbound.py` use committed test-only Ed25519 keypairs:
- `t/integration/config/ssh/testdev1_ed25519` + `.pub`
- `t/integration/config/ssh/testdev2_ed25519` + `.pub`

These are safe to commit — they are purpose-generated, non-production keys
used only against ephemeral test instances. The harness writes the public keys
into the test users' `ssh.publicKeys.*` entries and the private keypair into
`ssh.keypairs.*`, so Dockside both populates `~/.ssh/authorized_keys` and loads
the matching private key into the devtainer's integrated `ssh-agent`.

**`09_ssh.py` (inbound via wstunnel):**
- requires `wstunnel` in `PATH`
- uses host-side `ssh` plus the CLI-resolved ProxyCommand / SSH config details
- skipped if `wstunnel` is unavailable

**`10_ssh_outbound.py` (outbound via integrated ssh-agent):**

`DOCKSIDE_TEST_CONTAINER_ACCESS=docker|ssh` selects how the test enters the
devtainer (default `ssh`; `auto` is rejected — choose explicitly).  The two
values cover different depths of the routing stack:

| Value | How the test enters the devtainer | What routing is exercised |
|---|---|---|
| `docker` | `docker exec` directly into the container | In-container only (dropbear, ssh-agent, authorized_keys); nginx and wstunnel are **not** exercised |
| `ssh` | Host-side `ssh` via a wstunnel ProxyCommand built from `dockside ssh config` | Full stack: nginx routing → wstunnel → devtainer dropbear |

`ssh` (the default) is preferred — it tests the complete user-facing SSH path.
When running from a Dockside development container, both `ssh` and `wstunnel` are
available under `/opt/dockside/system/latest/bin`, so the full-stack path works
out of the box.

Both paths run the same in-devtainer check once inside:
- confirm `ssh-agent` is running and has the expected key loaded
- confirm `~dockside/.ssh/authorized_keys` contains the matching public key
- SSH from the devtainer to `dockside@127.0.0.1` and expect `hello`

Requirements:
- `docker` path: host `docker` CLI accessible; devtainer's OpenSSH client
  under `DOCKSIDE_TEST_SYSTEM_BIN_DIR` (default: `/opt/dockside/system/latest/bin`)
- `ssh` path: `wstunnel` and `ssh` in `PATH` (both present in Dockside
  development containers)

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
