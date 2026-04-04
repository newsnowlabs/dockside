#!/bin/bash
# Prepare a local (non-container) environment and launch Dockside under s6 supervision.
# Run as root. Suitable for running integration tests locally.
#
# Usage: bash build/development/run-local.sh [extra entrypoint args]
#   e.g. bash build/development/run-local.sh --passwd-stdout

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

# 7. Kill any manually-started dockerd; s6 will manage it via --run-dockerd.
pkill -x dockerd 2>/dev/null || true
sleep 1

# 8. Launch. --run-dockerd skips the docker socket check and container ID detection,
#    and adds dockerd as an s6-supervised service (ulimit failure is now handled gracefully).
#    --ssl-selfsigned generates a local self-signed cert via openssl.
exec /home/dockside/dockside/app/scripts/entrypoint.sh --run-dockerd --ssl-selfsigned "$@"
