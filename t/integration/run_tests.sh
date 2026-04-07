#!/usr/bin/env bash
# run_tests.sh — Dockside Integration Test Runner
#
# Usage:
#   bash t/integration/run_tests.sh [--only <prefix>] [--verbose] [--debug]
#
# Environment variables:
#
#   DOCKSIDE_TEST_MODE    local|remote|harness  (auto-detected if unset)
#
#   DOCKSIDE_TEST_HOST    Public FQDN (or URL) of the Dockside instance, e.g.:
#                           www.local.dockside.dev
#                           https://www.myinstance.example.com/
#                         If unset outside harness mode, the runner tries the
#                         CLI's currently selected server URL.
#                         Any https:// prefix and trailing slash are stripped.
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
#                               (unset)  defaults to auto
#                               auto     generate a random 6-char hex suffix per run
#                               <string> use this exact string as the suffix
#
#   DOCKSIDE_TEST_REUSE_USER_SESSIONS  1 = after each test user's first successful
#                                      authenticated CLI call, reuse that user's
#                                      per-client temp cookie file on later CLI
#                                      invocations and retry only read-only
#                                      commands with credentials if the reused
#                                      session fails
#                                      0/unset = pass explicit credentials on every
#                                      CLI call for test users
#
#   DOCKSIDE_TEST_CLEANUP_REUSED       1/unset = also remove reused test roles/
#                                      users/profiles for this suffix at end of run
#                                      0 = remove only resources created by
#                                      the current run
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
#   # Fixed-suffix rerun that also cleans reused test resources:
#   DOCKSIDE_TEST_NAME_SUFFIX=xyz DOCKSIDE_TEST_CLEANUP_REUSED=1 \
#     bash t/integration/run_tests.sh --only 09
#
#   # Allow network modification in remote/local mode (use with care):
#   DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY=1 DOCKSIDE_TEST_HOST=... bash t/integration/run_tests.sh --only 08

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${INTEGRATION_DIR}/../.." && pwd)"

# ── Default environment ───────────────────────────────────────────────────────
: "${DOCKSIDE_TEST_NAME_SUFFIX:=auto}"
: "${DOCKSIDE_TEST_CLEANUP_REUSED:=1}"
export DOCKSIDE_TEST_NAME_SUFFIX
export DOCKSIDE_TEST_CLEANUP_REUSED

# ── Infer host from current CLI server, when possible ────────────────────────
if [[ -z "${DOCKSIDE_TEST_HOST:-}" && -z "${DOCKSIDE_TEST_IMAGE:-}" ]]; then
    DOCKSIDE_TEST_HOST="$(
        python3 - <<'PY'
import json
import os

cfg_path = os.path.expanduser('~/.config/dockside/config.json')
try:
    with open(cfg_path, encoding='utf-8') as fh:
        cfg = json.load(fh)
except Exception:
    print('')
    raise SystemExit(0)

ref = cfg.get('current')
servers = cfg.get('servers') or []
entry = None
if ref:
    for item in servers:
        if item.get('nickname') == ref or item.get('url') == ref:
            entry = item
            break
if entry is None and servers:
    entry = servers[0]

print((entry or {}).get('url', ''))
PY
    )"
    if [[ -n "${DOCKSIDE_TEST_HOST}" ]]; then
        echo "# DOCKSIDE_TEST_HOST not set; using current CLI server: ${DOCKSIDE_TEST_HOST}" >&2
        export DOCKSIDE_TEST_HOST
    fi
fi

# Parse flags
ONLY_PREFIX=""
VERBOSE=0
DEBUG=0
SKIP_CLEANUP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) ONLY_PREFIX="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        --debug) DEBUG=1; shift ;;
        --skip-cleanup) SKIP_CLEANUP=1; shift ;;
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
    echo "       Or select a current CLI server with 'dockside login' / 'dockside server use'" >&2
    echo "       Or set DOCKSIDE_TEST_MODE=local with DOCKSIDE_TEST_HOST" >&2
    exit 1
fi

# ── Harness setup ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "harness" ]]; then
    # shellcheck source=harness.sh
    source "${INTEGRATION_DIR}/harness.sh"
    # harness.sh exports DOCKSIDE_TEST_SERVER_URL, DOCKSIDE_TEST_CONNECT_TO, etc.
fi

# ── Normalise DOCKSIDE_TEST_HOST (strip https:// prefix and trailing slash) ────
if [[ -n "${DOCKSIDE_TEST_HOST:-}" ]]; then
    DOCKSIDE_TEST_HOST="${DOCKSIDE_TEST_HOST#https://}"
    DOCKSIDE_TEST_HOST="${DOCKSIDE_TEST_HOST#http://}"
    DOCKSIDE_TEST_HOST="${DOCKSIDE_TEST_HOST%/}"
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
[[ "$VERBOSE"      == "1" ]] && export DOCKSIDE_TEST_VERBOSE=1
[[ "$DEBUG"        == "1" ]] && export DOCKSIDE_TEST_DEBUG=1
[[ "$SKIP_CLEANUP" == "1" ]] && export DOCKSIDE_TEST_SKIP_CLEANUP=1

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    if [[ "${DOCKSIDE_TEST_SKIP_CLEANUP:-0}" != "1" ]]; then
        echo "# Running cleanup..." >&2
        python3 "${INTEGRATION_DIR}/lib/run_tests_main.py" --cleanup 2>/dev/null || true
    fi
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
