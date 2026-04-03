#!/usr/bin/env bash
# run_tests.sh — Dockside Integration Test Runner
#
# Usage:
#   bash t/integration/run_tests.sh [--only <prefix>] [--verbose]
#
# Environment variables:
#
#   DOCKSIDE_TEST_MODE    local|remote|harness  (auto-detected if unset)
#
#   DOCKSIDE_TEST_HOST    Public FQDN of the Dockside instance, e.g.:
#                           www.local.dockside.dev
#                           www.myinstance.example.com
#                         Always the www.* form. Protocol assumed https://.
#                         - remote:  requests go directly to https://$DOCKSIDE_TEST_HOST
#                         - local:   requests go to https://$DOCKSIDE_TEST_HOST with
#                                    TCP routed to localhost via --connect-to
#
#   DOCKSIDE_TEST_ADMIN   username:password, e.g. 'admin:MySecret99'
#                         If unset in local/remote mode, the CLI's stored session
#                         is used (run 'dockside login' first).
#
#   DOCKSIDE_TEST_IMAGE   Docker image for harness mode
#   DOCKSIDE_TEST_HARNESS_ZONE  DNS zone for harness container (default: dockside.test)
#   DOCKSIDE_TEST_VERIFY_SSL  0 (default) or 1
#
#   DOCKSIDE_TEST_NAME_SUFFIX  Suffix for test resource names:
#                               (unset)  standard names, e.g. inttest-dev1
#                               auto     generate a random 6-char hex suffix per run
#                               <string> use this exact string as the suffix
#
#   DOCKSIDE_TEST_CONTAINER_ID   Running Dockside container ID (enables docker-exec
#                                SSH tests in non-harness modes)
#   DOCKSIDE_TEST_SSH_SERVER     Outbound SSH target (default: git@github.com)
#                                Testdev1's public key must be pre-authorized there.
#
#   DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY  1 = allow creating/attaching Docker networks
#                                       0 = disallow (even in harness mode)
#                                       (unset = use mode default)
#
# Examples:
#   # Harness mode (CI):
#   DOCKSIDE_TEST_IMAGE=newsnowlabs/dockside:latest bash t/integration/run_tests.sh
#
#   # Harness mode with custom zone:
#   DOCKSIDE_TEST_HARNESS_ZONE=inttest.example.com \
#     DOCKSIDE_TEST_IMAGE=newsnowlabs/dockside:latest bash t/integration/run_tests.sh
#
#   # Remote mode:
#   DOCKSIDE_TEST_HOST=www.local.dockside.dev DOCKSIDE_TEST_ADMIN=admin:pass bash t/integration/run_tests.sh
#
#   # Local mode (inside or alongside the Dockside container):
#   DOCKSIDE_TEST_MODE=local DOCKSIDE_TEST_HOST=www.local.dockside.dev bash t/integration/run_tests.sh
#
#   # Run only a subset:
#   DOCKSIDE_TEST_IMAGE=... bash t/integration/run_tests.sh --only 04
#
#   # Allow network modification in remote/local mode (use with care):
#   DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY=1 DOCKSIDE_TEST_HOST=... bash t/integration/run_tests.sh --only 08

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${INTEGRATION_DIR}/../.." && pwd)"

# Parse flags
ONLY_PREFIX=""
VERBOSE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) ONLY_PREFIX="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

# ── Mode detection ─────────────────────────────────────────────────────────────
if [[ -n "${DOCKSIDE_TEST_MODE:-}" ]]; then
    MODE="${DOCKSIDE_TEST_MODE}"
elif [[ -n "${DOCKSIDE_TEST_IMAGE:-}" ]]; then
    MODE="harness"
elif [[ -n "${DOCKSIDE_TEST_HOST:-}" ]]; then
    MODE="remote"
else
    echo "ERROR: Set DOCKSIDE_TEST_HOST (remote/local) or DOCKSIDE_TEST_IMAGE (harness)" >&2
    echo "       Or set DOCKSIDE_TEST_MODE=local with DOCKSIDE_TEST_HOST" >&2
    exit 1
fi

# ── Harness setup ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "harness" ]]; then
    # shellcheck source=harness.sh
    source "${INTEGRATION_DIR}/harness.sh"
    # harness.sh exports DOCKSIDE_TEST_SERVER_URL, DOCKSIDE_TEST_CONNECT_TO, etc.
fi

# ── Connection parameters by mode ─────────────────────────────────────────────
case "$MODE" in
    remote)
        HOST="${DOCKSIDE_TEST_HOST:?DOCKSIDE_TEST_HOST required for remote mode}"
        export DOCKSIDE_TEST_SERVER_URL="https://${HOST}"
        export DOCKSIDE_TEST_CONNECT_TO=""
        ;;
    local)
        HOST="${DOCKSIDE_TEST_HOST:?DOCKSIDE_TEST_HOST required for local mode}"
        export DOCKSIDE_TEST_SERVER_URL="https://${HOST}"
        export DOCKSIDE_TEST_CONNECT_TO="localhost"
        ;;
    harness)
        # Already set by harness.sh
        ;;
    *)
        echo "ERROR: Unknown mode ${MODE}" >&2
        exit 1
        ;;
esac

export DOCKSIDE_TEST_MODE="${MODE}"
export DOCKSIDE_TEST_ONLY="${ONLY_PREFIX}"
export DOCKSIDE_TEST_HARNESS_ID="${DOCKSIDE_TEST_HARNESS_ID:-}"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    echo "# Running cleanup..." >&2
    python3 "${INTEGRATION_DIR}/lib/run_tests_main.py" --cleanup 2>/dev/null || true
    # harness.sh's own trap handles container teardown
}
trap cleanup EXIT INT TERM

# ── Run tests ─────────────────────────────────────────────────────────────────
echo "# Dockside Integration Tests"
echo "# Mode: ${MODE}"
echo "# Server: ${DOCKSIDE_TEST_SERVER_URL}"
[[ -n "${DOCKSIDE_TEST_CONNECT_TO:-}" ]] && echo "# Connect-to: ${DOCKSIDE_TEST_CONNECT_TO}"
[[ -n "${ONLY_PREFIX}" ]] && echo "# Filter: ${ONLY_PREFIX}"
echo "#"

PYTHONPATH="${INTEGRATION_DIR}/lib:${REPO_ROOT}/cli" \
    python3 "${INTEGRATION_DIR}/lib/run_tests_main.py"
