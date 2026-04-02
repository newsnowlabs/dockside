#!/usr/bin/env bash
# harness.sh — Launch a fresh Dockside container for integration testing.
# Sourced by run_tests.sh when DOCKSIDE_TEST_MODE=harness.
#
# Sets and exports:
#   DOCKSIDE_TEST_HOST         www.localhost
#   DOCKSIDE_TEST_SERVER_URL   https://www.localhost:<port>
#   DOCKSIDE_TEST_CONNECT_TO   localhost:<port>
#   DOCKSIDE_TEST_ADMIN        admin:<password>
#   DOCKSIDE_TEST_MODE         harness
#   DOCKSIDE_TEST_HARNESS_ID   <container id>
#
# Registers a cleanup trap to stop/remove the container on exit.

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

harness_cleanup() {
    if [[ -n "${DOCKSIDE_TEST_HARNESS_ID:-}" ]]; then
        echo "# Stopping harness container ${DOCKSIDE_TEST_HARNESS_ID}..." >&2
        docker stop "${DOCKSIDE_TEST_HARNESS_ID}" 2>/dev/null || true
        docker rm   "${DOCKSIDE_TEST_HARNESS_ID}" 2>/dev/null || true
    fi
}
trap harness_cleanup EXIT INT TERM

IMAGE="${DOCKSIDE_TEST_IMAGE:?DOCKSIDE_TEST_IMAGE must be set for harness mode}"

echo "# Pulling ${IMAGE}..." >&2
docker pull "${IMAGE}" >&2

echo "# Starting Dockside harness container..." >&2
HARNESS_ID=$(docker run --detach \
    --publish 0:443 \
    --volume "${INTEGRATION_DIR}/config/users.json:/data/config/users.json:ro" \
    --volume "${INTEGRATION_DIR}/config/roles.json:/data/config/roles.json:ro" \
    --volume /var/run/docker.sock:/var/run/docker.sock \
    "${IMAGE}" \
    --ssl-selfsigned --ssl-zone localhost --passwd-stdout 2>/dev/null)

export DOCKSIDE_TEST_HARNESS_ID="${HARNESS_ID}"
echo "# Harness container: ${HARNESS_ID}" >&2

# Wait for admin password in logs
echo "# Waiting for admin password..." >&2
ADMIN_PASSWORD=""
deadline=$((SECONDS + 60))
while [[ $SECONDS -lt $deadline ]]; do
    line=$(docker logs "${HARNESS_ID}" 2>&1 | grep -m1 '^admin:' || true)
    if [[ -n "$line" ]]; then
        ADMIN_PASSWORD="${line#admin:}"
        break
    fi
    sleep 1
done

if [[ -z "$ADMIN_PASSWORD" ]]; then
    echo "ERROR: Timed out waiting for admin password from harness container" >&2
    exit 1
fi

# Get published port
HOST_PORT=$(docker port "${HARNESS_ID}" 443/tcp | cut -d: -f2)
if [[ -z "$HOST_PORT" ]]; then
    echo "ERROR: Could not determine host port for harness container" >&2
    exit 1
fi
echo "# Harness port: ${HOST_PORT}" >&2

# Wait for HTTPS to be ready
echo "# Waiting for HTTPS readiness..." >&2
deadline=$((SECONDS + 60))
while [[ $SECONDS -lt $deadline ]]; do
    if curl --silent --insecure --max-time 3 \
            --connect-to "www.localhost:${HOST_PORT}:localhost:${HOST_PORT}" \
            "https://www.localhost:${HOST_PORT}/" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# Set passwords for test users
echo "# Setting test user passwords..." >&2
docker exec "${HARNESS_ID}" bash -c '
    APP=/home/dockside/dockside/app/server
    HASH=$(perl -I "$APP/lib" -MUtil -e "print Util::encrypt_password(\"testpass123\")" 2>/dev/null)
    if [[ -z "$HASH" ]]; then
        # Fallback: try dockside password command
        echo "testpass123" | dockside password testdev1 2>/dev/null || true
        echo "testpass123" | dockside password testdev2 2>/dev/null || true
        echo "testpass123" | dockside password testviewer 2>/dev/null || true
    else
        printf "testdev1:%s\ntestdev2:%s\ntestviewer:%s\n" \
            "$HASH" "$HASH" "$HASH" >> /data/config/passwd
    fi
' 2>/dev/null || true

export DOCKSIDE_TEST_HOST="www.localhost"
export DOCKSIDE_TEST_SERVER_URL="https://www.localhost:${HOST_PORT}"
export DOCKSIDE_TEST_CONNECT_TO="localhost:${HOST_PORT}"
export DOCKSIDE_TEST_ADMIN="admin:${ADMIN_PASSWORD}"
export DOCKSIDE_TEST_MODE="harness"

echo "# Harness ready: ${DOCKSIDE_TEST_SERVER_URL} (connect-to: ${DOCKSIDE_TEST_CONNECT_TO})" >&2
