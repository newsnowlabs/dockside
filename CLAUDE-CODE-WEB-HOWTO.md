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
