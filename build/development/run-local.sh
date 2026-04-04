#!/bin/bash
# Prepare a local (non-container) environment and launch Dockside under s6 supervision.
# Run as root. Suitable for running integration tests locally.
#
# Usage: bash build/development/run-local.sh [--reset] [extra entrypoint args]
#
# Options:
#   --reset   Remove /data/config before starting (forces fresh credential generation).
#             Use this whenever you need a clean config or new admin password.
#
# The admin password is written to /tmp/dockside-passwd on every fresh start.
# Re-read it with: cat /tmp/dockside-passwd

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASSWD_FILE=/tmp/dockside-passwd

# Parse --reset from our own args before forwarding the rest to entrypoint.
EXTRA_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --reset) RESET=1 ;;
    *) EXTRA_ARGS+=("$arg") ;;
  esac
done

# 1. Create dockside user so /home/dockside exists and nginx.conf 'user dockside' resolves.
id dockside &>/dev/null || useradd -r -m -d /home/dockside -s /bin/bash dockside

# 2. Add dockside to docker and bind groups (mirrors Dockerfile's usermod -a -G docker,bind).
#    docker: needed for docker-event-daemon and nginx's Perl module (Docker API calls).
#    bind:   needed for bind9 DNS service (though disabled in local-dev mode).
usermod -aG docker,bind dockside

# 3. Allow dockside to run git in the repo directory (owned by root/another user).
sudo -u dockside git config --global --add safe.directory /home/user/dockside 2>/dev/null || true

# 4. Symlink the repo into the path that entrypoint.sh and the nginx runscript expect by default.
[ -e /home/dockside/dockside ] || ln -s "$REPO_DIR" /home/dockside/dockside

# 5. Create /opt/dockside/host so entrypoint takes the writable branch of the host-key check
#    (avoids exit 1; ide_cmd dropbearkey will fail silently — no set -e in entrypoint).
mkdir -p /opt/dockside/host

# 6. Create /data (entrypoint writes config, certs, db here).
mkdir -p /data

# 7. Optionally reset config (forces fresh credential generation on next start).
[ -n "$RESET" ] && rm -rf /data/config && echo "run-local: /data/config cleared"

# 8. Kill any manually-started dockerd; s6 will manage it via --run-dockerd.
pkill -x dockerd 2>/dev/null || true
sleep 1

# 9. Launch. --run-dockerd skips the docker socket check and container ID detection,
#    and adds dockerd as an s6-supervised service (ulimit failure is now handled gracefully).
#    --ssl-builtin uses the built-in local.dockside.dev cert; the server will expect
#    Host: www.local.dockside.dev (https://www.local.dockside.dev/).
#    --passwd-file captures the admin credentials for use by test scripts.
exec /home/dockside/dockside/app/scripts/entrypoint.sh \
  --run-dockerd \
  --ssl-builtin \
  --passwd-file "$PASSWD_FILE" \
  "${EXTRA_ARGS[@]}"
