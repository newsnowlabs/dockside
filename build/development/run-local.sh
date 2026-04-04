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

# 2. Symlink the repo into the path that entrypoint.sh and the nginx runscript expect by default.
[ -e /home/dockside/dockside ] || ln -s "$REPO_DIR" /home/dockside/dockside

# 3. Create /opt/dockside/host so entrypoint takes the writable branch of the host-key check
#    (avoids exit 1; ide_cmd dropbearkey will fail silently — no set -e in entrypoint).
mkdir -p /opt/dockside/host

# 4. Create /data (entrypoint writes config, certs, db here).
mkdir -p /data

# 5. Kill any manually-started dockerd so s6 (via --run-dockerd) can own the socket.
pkill -x dockerd 2>/dev/null || true
sleep 1

# 6. Launch. --run-dockerd skips the docker socket check and container ID detection.
#    --ssl-selfsigned generates a local self-signed cert via openssl.
exec /home/dockside/dockside/app/scripts/entrypoint.sh --run-dockerd --ssl-selfsigned "$@"
