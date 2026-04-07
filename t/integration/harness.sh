#!/usr/bin/env bash
# harness.sh — Launch a fresh Dockside container for integration testing.
# Sourced by run_tests.sh when DOCKSIDE_TEST_MODE=harness.
#
# Environment inputs:
#   DOCKSIDE_TEST_IMAGE       (required) Docker image to launch
#   DOCKSIDE_TEST_HARNESS_ZONE  DNS zone / ssl-zone for the harness container
#                               (default: dockside.test)
#   DOCKSIDE_TEST_HARNESS_ISOLATED_CLI_CONFIG
#                               1/unset = create a temporary CLI config dir,
#                               add a temporary harness server entry, and use
#                               the CLI's stored transport settings
#                               0 = keep legacy direct --connect-to transport
#
# Sets and exports:
#   DOCKSIDE_TEST_SERVER_URL   https://www.<HARNESS_ZONE>
#   DOCKSIDE_TEST_CONNECT_TO   localhost:<port>
#   DOCKSIDE_TEST_ADMIN        admin:<password>
#   DOCKSIDE_TEST_MODE         harness
#   DOCKSIDE_TEST_HARNESS_ID   <container id>
#   DOCKSIDE_CLI_CONFIG        <temp dir> (default isolated mode only)
#   DOCKSIDE_TEST_USE_SERVER_TRANSPORT
#                              1 when CLI server config should supply transport
#
# Registers a cleanup trap to stop/remove the container on exit.

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${INTEGRATION_DIR}/../.." && pwd)"

harness_cleanup() {
    if [[ "${DOCKSIDE_TEST_SKIP_CLEANUP:-${SKIP_CLEANUP:-0}}" == "1" ]]; then
        echo "# Skipping harness teardown (--skip-cleanup)" >&2
        return
    fi
    if [[ -n "${DOCKSIDE_TEST_TEMP_CLI_CONFIG:-}" ]]; then
        echo "# Removing harness CLI config ${DOCKSIDE_TEST_TEMP_CLI_CONFIG}..." >&2
        rm -rf "${DOCKSIDE_TEST_TEMP_CLI_CONFIG}" 2>/dev/null || true
    fi
    if [[ -n "${DOCKSIDE_TEST_HARNESS_ID:-}" ]]; then
        echo "# Stopping harness container ${DOCKSIDE_TEST_HARNESS_ID}..." >&2
        docker stop "${DOCKSIDE_TEST_HARNESS_ID}" 2>/dev/null || true
        docker rm   "${DOCKSIDE_TEST_HARNESS_ID}" 2>/dev/null || true
    fi
}
trap harness_cleanup EXIT INT TERM

IMAGE="${DOCKSIDE_TEST_IMAGE:?DOCKSIDE_TEST_IMAGE must be set for harness mode}"
HARNESS_ZONE="${DOCKSIDE_TEST_HARNESS_ZONE:-dockside.test}"

echo "# Pulling ${IMAGE}..." >&2
docker pull "${IMAGE}" >&2

echo "# Starting Dockside harness container (ssl-zone: ${HARNESS_ZONE})..." >&2
HARNESS_ID=$(docker run --detach \
    --publish 0:443 \
    --volume /var/run/docker.sock:/var/run/docker.sock \
    "${IMAGE}" \
    --ssl-selfsigned --ssl-zone "${HARNESS_ZONE}" --passwd-stdout 2>/dev/null)

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

# Wait for HTTPS to be ready using the canonical hostname via --resolve
echo "# Waiting for HTTPS readiness..." >&2
deadline=$((SECONDS + 60))
while [[ $SECONDS -lt $deadline ]]; do
    if curl --silent --insecure --max-time 3 \
            --resolve "www.${HARNESS_ZONE}:${HOST_PORT}:127.0.0.1" \
            "https://www.${HARNESS_ZONE}/" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

export DOCKSIDE_TEST_SERVER_URL="https://www.${HARNESS_ZONE}"
export DOCKSIDE_TEST_CONNECT_TO="localhost:${HOST_PORT}"
export DOCKSIDE_TEST_ADMIN="admin:${ADMIN_PASSWORD}"
export DOCKSIDE_TEST_MODE="harness"

HARNESS_ISOLATED_CLI_CONFIG="${DOCKSIDE_TEST_HARNESS_ISOLATED_CLI_CONFIG:-1}"
if [[ "${HARNESS_ISOLATED_CLI_CONFIG}" != "0" ]]; then
    HARNESS_CLI_CONFIG="$(mktemp -d /tmp/dockside-harness-cli.XXXXXX)"
    export DOCKSIDE_TEST_TEMP_CLI_CONFIG="${HARNESS_CLI_CONFIG}"
    export DOCKSIDE_CLI_CONFIG="${HARNESS_CLI_CONFIG}"
    export DOCKSIDE_TEST_USE_SERVER_TRANSPORT="1"
    HARNESS_SERVER_NICKNAME="harness-$(python3 - <<'PY'
import random
print('%06x' % random.randrange(0x1000000))
PY
)"
    echo "# Creating isolated harness CLI config at ${HARNESS_CLI_CONFIG}" >&2
    "${REPO_ROOT}/cli/dockside" login \
        --server "${DOCKSIDE_TEST_SERVER_URL}" \
        --nickname "${HARNESS_SERVER_NICKNAME}" \
        --connect-to "${DOCKSIDE_TEST_CONNECT_TO}" \
        --no-verify \
        --username admin \
        --password "${ADMIN_PASSWORD}" >/dev/null
    echo "# Harness ready: ${DOCKSIDE_TEST_SERVER_URL} (connect-to: ${DOCKSIDE_TEST_CONNECT_TO}, cli-config: ${HARNESS_CLI_CONFIG}, server: ${HARNESS_SERVER_NICKNAME})" >&2
else
    unset DOCKSIDE_CLI_CONFIG || true
    unset DOCKSIDE_TEST_TEMP_CLI_CONFIG || true
    export DOCKSIDE_TEST_USE_SERVER_TRANSPORT="0"
    echo "# Harness ready: ${DOCKSIDE_TEST_SERVER_URL} (connect-to: ${DOCKSIDE_TEST_CONNECT_TO}, legacy direct transport)" >&2
fi
