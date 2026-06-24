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

## Known issue — CLI `dockside login` returns 500

Running `./cli/dockside login ...` against `newsnowlabs/dockside:latest` fails
with a server-side Perl error (`Undefined subroutine &User::AUTOLOAD`). Use the
`:latest` image instead, where this is fixed.

---

## Running integration tests

### Run tests from inside the Dockside container

`wstunnel` (required for SSH-based container access) only exists inside the
Dockside container at `/opt/dockside/system/latest/bin`. Run all integration
tests via `docker exec`:

```bash
docker exec -u dockside dockside bash -c "
  cd /home/dockside/dockside
  PYTHONUNBUFFERED=1 \
  DOCKSIDE_TEST_MODE=local \
  DOCKSIDE_TEST_HOST=www.local.dockside.dev \
  DOCKSIDE_TEST_CONTAINER_ACCESS=ssh \
  DOCKSIDE_TEST_IMAGE_REGISTRY=mirror.gcr.io/library \
  PATH=\$PATH:/opt/dockside/system/latest/bin \
  bash t/integration/run_tests.sh
"
```

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

**Option A — Bind-mount the CA bundle via profile `mounts.bind`**

Add a new env var (e.g. `DOCKSIDE_TEST_CA_BUNDLE`) that the test harness uses
to append a bind mount entry to every profile spec before creating it:

```python
if _CA_BUNDLE:
    spec.setdefault('mounts', {}).setdefault('bind', []).append(
        {'src': _CA_BUNDLE, 'dst': '/etc/ssl/certs/ca-certificates.crt', 'options': 'ro'}
    )
```

The bind-mount source is resolved by the Docker daemon against the outer host
(not the Dockside container), and `/etc/ssl/certs/ca-certificates.crt` on the
outer host already includes the Anthropic CAs.

Usage: `DOCKSIDE_TEST_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt`

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

# 4. Wait for startup and print credentials
until docker compose logs 2>&1 | grep -q 'Sign in'; do sleep 2; done
docker compose logs 2>&1 | grep 'Sign in'
```
