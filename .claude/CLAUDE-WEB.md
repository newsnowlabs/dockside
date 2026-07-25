# Running Dockside in Claude Code on the Web

This document records the steps, pitfalls, and fixes discovered when bringing up
Dockside inside a Claude Code remote execution environment (the managed cloud
container Anthropic provisions when you start a session from claude.ai/code or
a GitHub Action).

---

## Environment characteristics

- You get a fresh, ephemeral Linux container with root access.
- Docker Engine (`dockerd`) is installed but **not running** — there is no systemd
  or other init system to start it automatically.
- Outbound HTTPS traffic is intercepted by an Anthropic **transparent TLS
  inspection proxy**. The proxy re-signs every TLS certificate with its own CA.
  Four CA certificates are pre-installed on the host in
  `/usr/local/share/ca-certificates/` and merged into the system bundle
  `/etc/ssl/certs/ca-certificates.crt`:
  - `egress-gateway-ca-production.crt`
  - `egress-gateway-ca-staging.crt`
  - `swp-ca-production.crt`
  - `swp-ca-staging.crt`
- Docker containers created by `dockerd` do **not** inherit the host CA bundle.
  Their base images carry their own `/etc/ssl/certs/ca-certificates.crt`, which
  does not include the Anthropic CAs. Any `curl` or other TLS client inside a
  container that tries to reach the internet will fail with:
  ```
  SSL certificate problem: self-signed certificate in certificate chain
  ```
- The Docker Hub unauthenticated pull rate-limit is easily hit. Use
  `ghcr.io/newsnowlabs/dockside` instead of `newsnowlabs/dockside`.

---

## Step 1 — Start the Docker daemon

```bash
# Kill any stale PID file from a previous session
kill $(cat /var/run/docker.pid 2>/dev/null) 2>/dev/null
rm -f /var/run/docker.pid

dockerd --host unix:///var/run/docker.sock &>/tmp/dockerd.log &
until docker info &>/dev/null 2>&1; do sleep 1; done
```

---

## Step 2 — Patch `docker-compose.yml` locally (do not commit these changes)

> **Important:** The edits below are environment-specific workarounds for the
> Claude Code remote execution environment. They must be applied to your local
> working copy of `docker-compose.yml` **but must never be committed or pushed**,
> as they would break other environments.

### 2a — Use the GHCR image (if requested by the user)

The default image in `docker-compose.yml` is `newsnowlabs/dockside:latest`
(Docker Hub). Switch it to the GHCR image to avoid rate limits, or to use a
specific tag such as `:feature`:

```yaml
    image: ${DOCKSIDE_IMAGE:-ghcr.io/newsnowlabs/dockside:feature}
```

Always `docker pull` the target image before relaunching — `docker compose up -d`
reuses the locally cached layer set and will silently run stale code if you skip
the pull:

```bash
docker pull ghcr.io/newsnowlabs/dockside:latest
```

### 2b — Mount the host CA bundle into the Dockside container

The `--ssl-builtin` startup mode downloads a pre-built Let's Encrypt wildcard
certificate for `*.local.dockside.dev` from Google Cloud Storage. Inside the
container this download fails because the container does not trust the Anthropic
egress proxy CA.

**Fix:** add a read-only bind mount of the host CA bundle to the `volumes:` list:

```yaml
    volumes:
      - ~/.dockside:/data
      - /var/run/docker.sock:/var/run/docker.sock
      - ide:/opt/dockside
      - hostkeys:/opt/dockside/host
      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro   # add this
```

This is the standard Docker pattern for sharing custom CA certificates with a
container without rebuilding its image. With this mount in place `--ssl-builtin`
works correctly and the certificate is downloaded on startup.

---

## Step 3 — Launch

```bash
docker compose up -d

# Read off the auto-generated admin password and save it
docker compose logs 2>&1 | grep 'Sign in' | tee /tmp/dockside-password.txt
```

Expected output:
```
dockside  | >>> Sign in with username 'admin' and password '<generated-password>'
```

Save the password to `/tmp/dockside-password.txt` (or another tmpfile) as shown
above — it is only printed on first launch and is not retrievable from the
`~/.dockside` config files afterwards.

The password persists across `docker compose down && up` cycles as long as
`~/.dockside` is not deleted. If the password is lost, the simplest recovery is:

```bash
rm ~/.dockside/config/passwd
docker compose restart
docker compose logs 2>&1 | grep 'Sign in' | tee /tmp/dockside-password.txt
```

Dockside generates and logs a fresh admin password whenever `passwd` is absent
on startup.

Navigate to `https://www.local.dockside.dev/` and sign in.

> **Note:** `*.local.dockside.dev` resolves to `127.0.0.1` in public DNS, so
> the URL works without any `/etc/hosts` changes. The certificate is a real
> Let's Encrypt cert, not self-signed.

---

## Step 3b — Refresh the IDE-bundled CA store (fixes git-wrapper HTTPS failures)

Step 2b fixes TLS trust for the Dockside container's own system trust store (used by
`--ssl-builtin`'s Let's Encrypt download), but Dockside's bundled `git`/`gh` wrappers
(see `Dockerfile`) don't consult that store — they hardcode a separate, image-baked
CA bundle at `$IDE_PATH/certs/ca-certificates.crt`
(`/opt/dockside/system/latest/certs/ca-certificates.crt`), copied in from the Alpine
build stage. That file lives on the `ide` named volume, which Dockside shares
read/write into every devtainer it launches, so fixing it here also fixes HTTPS
`git clone` inside devtainers (e.g. `06_git_profile.py` in the integration suite).

Once the container is up, overwrite it with the same host bundle used in Step 2b:

```bash
docker exec dockside cp /etc/ssl/certs/ca-certificates.crt \
  /opt/dockside/system/latest/certs/ca-certificates.crt
```

This is safe even though the source (Debian, from the Claude Code host) and the
original destination content (Alpine-sourced) come from different distros: both are
plain concatenated PEM certificate blocks — a generic, distro-independent format —
and the bundled `git`/`gh` binaries carry their own musl/OpenSSL runtime (via
BundELF's `patchelf` bundling), so they never depended on the host distro's trust
store to begin with. Only this single flat file matters — the wrappers reference it
directly and never consult the per-cert hash-symlink directory that also happens to
live alongside it in `certs/`.

---

## Step 4 — Installing local code changes into the running container

Nothing about the container is auto-reloaded from your git checkout. Every edit
made in this working directory — Perl, CLI, Vue, `launch.sh`/IDE assets — has to
be explicitly installed into the running `dockside` container before it takes
effect, using `docker cp` (there's no bind mount of the repo by default). This
section covers the workflow, plus two ways to make the launch.sh/IDE-asset case
survive a container restart, and an alternative that avoids `docker cp` entirely
for the Perl/CLI/test case.

### Perl server and CLI changes

Copy the changed files into the container's copy of the repo checkout at
`/home/dockside/dockside`, then restart the affected services (per the repo-root
`CLAUDE.md`, the running server does **not** pick up file changes automatically):

```bash
docker cp app/server/lib/User/Manage.pm dockside:/home/dockside/dockside/app/server/lib/User/Manage.pm
docker exec dockside sudo s6-svc -t /etc/service/nginx
docker exec dockside sudo s6-svc -t /etc/service/docker-event-daemon
```

`cli/dockside` is a standalone script run from the host (or wherever the
integration suite invokes it from) — copy it the same way if you're testing it
inside the container, or just run your host checkout's copy directly.

### Vue client changes

Rebuild, then copy the whole `dist/` output over the container's copy:

```bash
(cd app/client && npm run build)
docker cp app/client/dist/. dockside:/home/dockside/dockside/app/client/dist/
```

No service restart needed — nginx serves the static files directly.

### `launch.sh` / IDE asset changes — the volume-vs-`.img` gotcha

`launch.sh` and the IDE bundles are **not** read from the git checkout at
runtime; they're read from `/opt/dockside`, which `entrypoint.sh` populates
from `/opt/dockside.img` (the image-baked copy) at container start. This means:

- `docker cp app/scripts/container/launch.sh dockside:/opt/dockside/bin/launch.sh`
  takes effect immediately (`docker-event-daemon` execs it fresh on every
  `docker exec ... launch.sh`), **but is silently wiped on the next container
  restart** — `entrypoint.sh` unconditionally overwrites `/opt/dockside/bin/`
  from `/opt/dockside.img/bin/` every time it runs, with no check for
  newer/local content. This is a real trap: a `dockerd` crash-and-recover, or
  any `docker restart dockside`, quietly reverts your patch back to the image
  version with no error.
- **Better: patch `.img`, not the volume.** Copy into
  `/opt/dockside.img/bin/launch.sh` instead. `entrypoint.sh`'s `bin/` copy step
  runs `cp -a "${OPT_PATH}.img/bin/." "$OPT_PATH/bin/"` on every start, so your
  change now propagates to the volume automatically on every restart instead
  of being destroyed by it. Verified live: after `docker cp` to `.img/bin/`
  followed by `docker restart dockside`, both `/opt/dockside/bin/launch.sh` and
  `/opt/dockside.img/bin/launch.sh` reflected the patch.
  ```bash
  docker cp app/scripts/container/launch.sh dockside:/opt/dockside.img/bin/launch.sh
  docker restart dockside
  ```
- **IDE/system version directories behave differently from `bin/`.** Files
  under `/opt/dockside.img/ide/<name>/<version>/` and
  `/opt/dockside.img/system/<version>/` (e.g. `openvscode/bin/launch-ide.sh`)
  are only copied to the volume **if the destination version directory doesn't
  already exist** — `entrypoint.sh` treats them as "install once, then leave
  running devtainers alone." A patch to an existing version directory made
  directly at the volume path (`/opt/dockside/ide/...`) is **not** clobbered by
  a restart (unlike `bin/`), but a patch made only under `.img/ide/...` will
  **not** propagate to an already-populated volume either — you'd need to patch
  both, or remove the volume's copy of that version dir first. In practice,
  for an existing installed IDE version, patch the volume path directly; the
  `.img` copy only matters for versions not yet installed on the volume.
- **`.img` itself is part of the container's writable layer, not a docker
  volume** (confirmed via `mount | grep dockside` inside the container — only
  `/opt/dockside` and `/opt/dockside/host` show up as real mounts). So `.img`
  edits survive container **restarts** but are lost on container **removal or
  recreation** (`docker compose down` + `up`, or `docker rm`) — re-apply after
  recreating the container, same as any other manual in-container patch.

### Alternative: bind-mount the repo instead of `docker cp`

For the Perl/CLI/test-code case (not `launch.sh`/IDE assets — those live under
`/opt/dockside`, a separate subsystem, and aren't helped by this), you can skip
`docker cp` entirely by bind-mounting your working directory over the
container's checkout in `docker-compose.yml`:

```yaml
services:
  dockside:
    volumes:
      - .:/home/dockside/dockside:ro
```

This is feasible despite a possible UID mismatch between your host user and the
container's `dockside` user (uid 1001): Dockside's Perl/FastCGI app and CLI only
need *read* access to the checkout (all mutable state lives in the separate
`~/.dockside:/data`-backed volume), and a git checkout is normally
world-readable/world-traversable, which is sufficient for another UID to read
regardless of ownership. Verify with `find . -not -perm -o=r` /
`find . -type d -not -perm -o=x` before relying on it if your checkout has
unusual permissions. Edits on the host then appear inside the container
immediately with no `docker cp` step — only a service restart (Perl) or
`npm run build` (Vue) is still needed. Add this **as a local-only
`docker-compose.yml` change**, same as the `:feature` image switch and CA-mount
patch below — never commit it (see Step 2).

---

## Known issue — CLI `dockside login` returns 500

Running `./cli/dockside login ...` against `newsnowlabs/dockside:latest` fails
with a server-side Perl error (`Undefined subroutine &User::AUTOLOAD`). Use the
`:latest` image instead, where this is fixed.

---

## Running integration tests

### Run tests from inside the Dockside container

`wstunnel` (required for SSH-based container access) only exists inside the
Dockside container at `/opt/dockside/system/latest/bin`. The recommended way is
to authenticate the CLI first and then run via `docker exec`:

```bash
# Authenticate the CLI (one-time; persists in ~/.dockside/... inside the container)
docker exec -u dockside dockside bash -c "
  cd /home/dockside/dockside
  ./cli/dockside login \
    --connect-to 127.0.0.1 \
    --no-verify \
    --nickname local \
    --server https://www.local.dockside.dev/ \
    --username admin \
    --password \"\$(cat /tmp/dockside-password.txt | grep -o \"'[^']*'\" | tr -d \"'\")\"
"

# Run all tests
docker exec -u dockside dockside bash -c "
  cd /home/dockside/dockside
  PYTHONUNBUFFERED=1 \
  DOCKSIDE_TEST_MODE=local \
  DOCKSIDE_TEST_HOST=www.local.dockside.dev \
  DOCKSIDE_TEST_CONTAINER_ACCESS=ssh \
  DOCKSIDE_TEST_IMAGE_REGISTRY=mirror.gcr.io/library \
  DOCKSIDE_TEST_NETWORK=bridge \
  PATH=\$PATH:/opt/dockside/system/latest/bin \
  bash t/integration/run_tests.sh
"
```

`DOCKSIDE_TEST_NETWORK=bridge` is explicit here rather than relying on the
harness's own single-network auto-detection (it only needs one network attached
to the `dockside` container to disambiguate, which is all `network_mode: "bridge"`
gives it here) — spelling it out keeps this invocation reproducible regardless of
what the harness's default behaviour does in a given version, and matches the
literal Docker network name `network_mode: "bridge"` attaches to (Docker's
built-in default bridge network, always named `bridge`).

### `PYTHONUNBUFFERED=1` is required for live output

Python blocks stdout when not connected to a TTY. Without `PYTHONUNBUFFERED=1`
all TAP lines queue in-process and appear only at exit — or are lost if the
process is killed. Harness setup messages go to stderr (always line-buffered)
and do appear in real time, making a running suite look stuck after
"Test environment ready." when it is actually executing. Always set
`PYTHONUNBUFFERED=1`.

### Docker Hub rate limits cause hangs, not fast failures

`docker create` with an unmirrored Docker Hub image does not fail immediately
when rate limited — it hangs inside the pull phase until a timeout. Set:

```bash
DOCKSIDE_TEST_IMAGE_REGISTRY=mirror.gcr.io/library
```

The harness rewrites all profile image names to use this prefix (e.g.
`nginx:latest` → `mirror.gcr.io/library/nginx:latest`), bypassing Docker Hub.

### CA certificates are not inherited by launched devtainers

The Dockside container itself can be given the host CA bundle (see Step 2b
above), but devtainers that Dockside launches are separate containers and do not
inherit that mount. This causes two classes of test failure in the Claude Code
environment:

- **Git HTTPS clone failures** — `git clone https://github.com/...` inside a
  devtainer fails with an SSL certificate error because the devtainer's image CA
  bundle does not include the Anthropic proxy CA.
- **`apk`/`apt` failures** — Alpine and Debian containers that install packages
  on startup (`apk update && apk add ...`) hit the same SSL error, so the
  entrypoint fails before the container is usable.

Three approaches to fix this:

**Option A — Bind-mount the CA bundle via profile `mounts.bind` (implemented)**

`DOCKSIDE_TEST_CA_BUNDLE` exists in the integration-test harness
(`t/integration/lib/run_tests_main.py`, `_with_ca_bundle_mount`): when set, it
bind-mounts the given host CA bundle read-only into every test profile at
`/etc/ssl/certs/ca-certificates.crt`, so devtainer `apk`/`apt` package installs
and generic HTTPS traffic trust it:

```python
mounts['bind'] = list(mounts.get('bind') or []) + [
    {'src': _CA_BUNDLE, 'dst': '/etc/ssl/certs/ca-certificates.crt', 'readonly': True}
]
```

The bind-mount source is resolved by the Docker daemon against the outer host
(not the Dockside container), and `/etc/ssl/certs/ca-certificates.crt` on the
outer host already includes the Anthropic CAs.

Usage: `DOCKSIDE_TEST_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt`

**Gap: this does not fix the git-clone failure class above.** `06_git_profile.py`'s
HTTPS clones go through Dockside's bundled `git` wrapper, which hardcodes
`-c http.sslcainfo=<IDE_PATH>/certs/ca-certificates.crt` — a separate, image-baked
file in the shared IDE volume, unrelated to the system trust store this env var
patches. **Fixed by replacing that file's contents — see Step 3b above.**

**Option B — `dockerArgs` in the profile**

Equivalent to A, using the raw docker args field instead of the structured
mounts field:

```python
spec.setdefault('dockerArgs', []).append(
    f'--volume={_CA_BUNDLE}:/etc/ssl/certs/ca-certificates.crt:ro'
)
```

**Option C — Dockside server-side global mount**

If Dockside's server configuration supports a global `dockerArgs` or `mounts`
field applied to all containers, the CA bundle mount could be placed there
rather than in each test profile. This would fix the issue without any harness
changes and would also benefit non-test containers launched interactively.

---

## Quick-start script

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Kill stale dockerd PID and restart
kill $(cat /var/run/docker.pid 2>/dev/null) 2>/dev/null || true
rm -f /var/run/docker.pid
dockerd --host unix:///var/run/docker.sock &>/tmp/dockerd.log &
until docker info &>/dev/null 2>&1; do sleep 1; done

# 2. Patch docker-compose.yml locally (do not commit)
DOCKSIDE_IMAGE='ghcr.io/newsnowlabs/dockside:latest'
#    - set GHCR image
sed -i "s|image: \${DOCKSIDE_IMAGE:-newsnowlabs/dockside:latest}|image: \${DOCKSIDE_IMAGE:-$DOCKSIDE_IMAGE}|" docker-compose.yml
#    - mount host CA bundle
sed -i '/hostkeys:\/opt\/dockside\/host/a\      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro' docker-compose.yml

# 3. Pull the target image explicitly, then launch
docker pull "$DOCKSIDE_IMAGE"
mkdir -p ~/.dockside
docker compose up -d

# 4. Refresh the IDE-bundled git/gh CA store (see Step 3b)
docker exec dockside cp /etc/ssl/certs/ca-certificates.crt \
  /opt/dockside/system/latest/certs/ca-certificates.crt

# 5. Wait for startup and print credentials
until docker compose logs 2>&1 | grep -q 'Sign in'; do sleep 2; done
docker compose logs 2>&1 | grep 'Sign in'
```
