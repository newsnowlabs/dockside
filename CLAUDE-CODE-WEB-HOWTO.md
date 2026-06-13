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
- The Docker Hub rate-limit is easily hit. Use `ghcr.io/newsnowlabs/dockside`
  instead of `newsnowlabs/dockside`.

---

## Step 1 — Start the Docker daemon

```bash
dockerd --host unix:///var/run/docker.sock &>/tmp/dockerd.log &
# Wait a few seconds for the socket to appear
sleep 3
docker info   # should succeed
```

---

## Step 2 — Use the GHCR image

Set `DOCKSIDE_IMAGE` so `docker compose` picks up the GHCR image:

```bash
export DOCKSIDE_IMAGE=ghcr.io/newsnowlabs/dockside:latest
```

Or set it inline on every `docker compose` call:

```bash
DOCKSIDE_IMAGE=ghcr.io/newsnowlabs/dockside:latest docker compose up -d
```

---

## Step 3 — Fix the TLS CA trust problem

The `--ssl-builtin` startup mode downloads a pre-built Let's Encrypt wildcard
certificate for `*.local.dockside.dev` from
`https://storage.googleapis.com/dockside/certs/local.dockside.dev/`. Inside the
container this download fails because the container does not trust the Anthropic
egress proxy CA.

**Fix:** mount the host's CA bundle (which already includes the Anthropic CAs)
into the container as a read-only volume. Add this entry to the `volumes:` list
in `docker-compose.yml`:

```yaml
    volumes:
      - ~/.dockside:/data
      - /var/run/docker.sock:/var/run/docker.sock
      - ide:/opt/dockside
      - hostkeys:/opt/dockside/host
      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro   # <-- add this
```

This is the standard Docker pattern for sharing custom CA certificates with
containers without rebuilding the image. With this mount in place, `--ssl-builtin`
works correctly and the certificate is downloaded and installed on startup.

The updated `docker-compose.yml` in this repository already includes this line.

---

## Step 4 — Launch

```bash
mkdir -p ~/.dockside
DOCKSIDE_IMAGE=ghcr.io/newsnowlabs/dockside:latest docker compose up -d

# Read off the auto-generated admin password
docker compose logs 2>&1 | grep 'Sign in'
```

Expected output:
```
dockside  | >>> Sign in with username 'admin' and password '<generated-password>'
```

Navigate to `https://www.local.dockside.dev/` and sign in.

> **Note:** `*.local.dockside.dev` resolves to `127.0.0.1` in public DNS, so
> the URL works without any `/etc/hosts` changes. The certificate is a real
> Let's Encrypt cert, not self-signed.

---

## Known issue — CLI `dockside login` returns 500

Running:

```bash
./cli/dockside login \
  --server https://www.local.dockside.dev/ \
  --nickname local \
  --username admin \
  --no-verify \
  --connect-to 127.0.0.1 \
  --password <password>
```

currently fails with:

```
error: Login failed – connection error: Internal Server Error
```

The nginx error log inside the container shows:

```
call_sv("") failed: "Undefined subroutine &User::AUTOLOAD called."
```

This is a server-side Perl bug unrelated to the execution environment. The TCP
connection and the TLS handshake both succeed; the 500 is returned by the
Dockside Perl application itself when processing the POST body. A direct `curl`
form-POST to the same URL returns a correct 302 redirect with session cookies,
confirming the environment and networking are fine.

---

## Running integration tests

### Always pull before relaunching

`docker compose up -d` reuses the locally cached image even if the remote has
been rebuilt. Always pull explicitly first:

```bash
docker pull ghcr.io/newsnowlabs/dockside:feature
docker compose down && docker compose up -d
```

Forgetting this means tests run against stale server code and features that
were just merged will appear missing.

### Bake the image into docker-compose.yml

Relying on a shell env-var override (`DOCKSIDE_IMAGE=... docker compose up -d`)
is error-prone — the override is easily forgotten. Set the default directly in
`docker-compose.yml`:

```yaml
image: ${DOCKSIDE_IMAGE:-ghcr.io/newsnowlabs/dockside:feature}
```

### Stale dockerd PID after session restart

Each new Claude Code web session gets a fresh container. `dockerd` must be
started manually. If a previous run left `/var/run/docker.pid` behind, a fresh
`dockerd` start fails silently. Fix:

```bash
kill $(cat /var/run/docker.pid) 2>/dev/null
rm -f /var/run/docker.pid
dockerd --host unix:///var/run/docker.sock &>/tmp/dockerd.log &
sleep 3
docker info
```

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

### Use `PYTHONUNBUFFERED=1` — otherwise you see nothing

Python blocks stdout when not connected to a TTY. Without `PYTHONUNBUFFERED=1`
all TAP output (`ok 1`, `not ok 2`, …) queues in-process and only appears at
process exit — or is lost entirely if the process is killed.

Critically, harness setup messages go to stderr (which is always line-buffered)
and _do_ appear in real time. This makes a running test suite look like it is
stuck after "Test environment ready." when it is actually executing tests
normally.

Always set `PYTHONUNBUFFERED=1` as shown above.

### Docker Hub rate limits cause hangs, not fast failures

`docker create` with a Docker Hub image does not fail immediately when rate
limited. Instead it hangs inside the pull phase until a timeout. Use the GCR
mirror to avoid this:

```bash
DOCKSIDE_TEST_IMAGE_REGISTRY=mirror.gcr.io/library
```

When set, the test harness rewrites all profile image names to use this prefix
(e.g. `nginx:latest` → `mirror.gcr.io/library/nginx:latest`). This bypasses
Docker Hub rate limits and makes container creates complete quickly.

Note: this env var is only supported from the `:feature` image at commit
`895ec51` onwards. If `docker create` is still hanging, you are likely running
a stale image — pull again.

### Admin password persists across relaunches (same `~/.dockside`)

The auto-generated admin password is written to `~/.dockside/config/passwd` on
first launch. Subsequent `docker compose down && up` cycles reuse the same
`~/.dockside` mount and the password remains valid. Only delete `~/.dockside`
if you need a full reset (which generates a new password printed in the logs).

---

## Quick-start script

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Start Docker daemon if not running
if ! docker info &>/dev/null 2>&1; then
  dockerd --host unix:///var/run/docker.sock &>/tmp/dockerd.log &
  until docker info &>/dev/null 2>&1; do sleep 1; done
fi

# 2. Create data directory and launch
mkdir -p ~/.dockside
DOCKSIDE_IMAGE=ghcr.io/newsnowlabs/dockside:latest docker compose up -d

# 3. Wait for startup and print credentials
until docker compose logs 2>&1 | grep -q 'Sign in'; do sleep 2; done
docker compose logs 2>&1 | grep 'Sign in'
```
