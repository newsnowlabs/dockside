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
#   DOCKSIDE_TEST_HARNESS_ISOLATED_CLI_CONFIG
#                         1/unset = in harness mode, create a temporary CLI config
#                         directory and temporary server entry so the CLI's own
#                         stored transport settings drive test traffic
#                         0 = use legacy direct --connect-to transport in harness mode
#   DOCKSIDE_TEST_VERIFY_SSL  0 (default) or 1
#
#   DOCKSIDE_TEST_NAME_SUFFIX  Suffix for test resource names:
#                               (unset)  defaults to auto
#                               auto     generate a random 6-char hex suffix per run
#                               <string> use this exact string as the suffix
#                               (empty)  rejected — an empty suffix would let test names
#                                        collide with un-suffixed real resources
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
#   DOCKSIDE_TEST_CLEANUP_REUSED       0/unset = remove only resources created by the
#                                      current run (default; never deletes pre-existing
#                                      resources the run merely reused)
#                                      1 = ALSO remove reused test roles/users/profiles
#                                      for this suffix at end of run — only safe on an
#                                      instance you own
#
#   DOCKSIDE_TEST_CONTAINER_ID   Dockside container id/name for the network-attach tests
#                                (08 test_05/06). Auto-detected in local/harness mode
#                                (/etc/service/nginx/data/ctr-id, else hostname); set
#                                explicitly for an "alongside" run or to override
#
#   DOCKSIDE_TEST_IMAGE_REGISTRY  Docker image registry mirror to use instead of
#                                 Docker Hub for bare image names (e.g. alpine:latest).
#                                 Images with an explicit registry host are unaffected.
#                                 Example: mirror.gcr.io/library
#                                 Useful on hosts with Docker Hub pull-rate limits.
#
#   DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY  1 = allow creating/attaching Docker networks
#                                       0 = disallow (even in harness mode)
#                                       (unset = use mode default)
#   DOCKSIDE_TEST_CONTAINER_ACCESS  docker|ssh (default: ssh)
#                                  Method for tests that inspect a devtainer
#                                  internally.  'ssh' (default) uses wstunnel and
#                                  exercises the real access path; wstunnel must be
#                                  in PATH or the runner aborts early.  'docker'
#                                  uses docker exec — bypasses the SSH path, useful
#                                  on hosts without wstunnel but not recommended
#                                  for CI.  'auto' is no longer accepted.
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
# Reject an explicitly-empty suffix (set but blank): an empty suffix yields bare
# resource names that can collide with un-suffixed real resources. Default to auto
# only when the variable is genuinely unset.
if [ -n "${DOCKSIDE_TEST_NAME_SUFFIX+set}" ] && [ -z "${DOCKSIDE_TEST_NAME_SUFFIX}" ]; then
   echo "ERROR: DOCKSIDE_TEST_NAME_SUFFIX is set but empty; use 'auto' or a non-empty string." >&2
   exit 1
fi
: "${DOCKSIDE_TEST_NAME_SUFFIX:=auto}"
# Default OFF: a run never deletes pre-existing resources it merely reused. Set to 1
# only on an instance you own to also clean reused fixtures (see header).
: "${DOCKSIDE_TEST_CLEANUP_REUSED:=0}"
export DOCKSIDE_TEST_NAME_SUFFIX
export DOCKSIDE_TEST_CLEANUP_REUSED

# ── Infer host from current CLI server, when possible ────────────────────────
if [[ -z "${DOCKSIDE_TEST_HOST:-}" && -z "${DOCKSIDE_TEST_IMAGE:-}" ]]; then
    DOCKSIDE_TEST_HOST="$(
        python3 - <<'PY'
import json
import os

cfg_root = (
    os.environ.get('DOCKSIDE_CLI_CONFIG')
    or os.environ.get('DOCKSIDE_CONFIG_DIR')
    or os.path.join(os.path.expanduser('~'), '.config', 'dockside')
)
cfg_path = os.path.join(cfg_root, 'config.json')
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
SKIP_CONTAINER_CLEANUP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) ONLY_PREFIX="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        --debug) DEBUG=1; shift ;;
        --skip-cleanup) SKIP_CLEANUP=1; shift ;;
        --skip-container-cleanup) SKIP_CONTAINER_CLEANUP=1; shift ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

[[ "$SKIP_CLEANUP" == "1" ]] && export DOCKSIDE_TEST_SKIP_CLEANUP=1
[[ "$SKIP_CONTAINER_CLEANUP" == "1" ]] && export DOCKSIDE_TEST_SKIP_CONTAINER_CLEANUP=1

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

# ── Container access method ───────────────────────────────────────────────────
: "${DOCKSIDE_TEST_CONTAINER_ACCESS:=ssh}"
export DOCKSIDE_TEST_CONTAINER_ACCESS
if [[ "${DOCKSIDE_TEST_CONTAINER_ACCESS}" == "auto" ]]; then
    echo "ERROR: DOCKSIDE_TEST_CONTAINER_ACCESS=auto is no longer supported." >&2
    echo "       Use 'ssh' (default) or 'docker'." >&2
    exit 1
fi
if [[ "${DOCKSIDE_TEST_CONTAINER_ACCESS}" != "docker" ]]; then
    if ! command -v wstunnel >/dev/null 2>&1; then
        echo "ERROR: wstunnel not found in PATH." >&2
        echo "       SSH-based devtainer access requires wstunnel." >&2
        echo "       Install wstunnel, or set DOCKSIDE_TEST_CONTAINER_ACCESS=docker to use" >&2
        echo "       docker exec instead (bypasses the SSH path; not recommended for CI)." >&2
        exit 1
    fi
fi

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    local exit_code=$?  # capture before any cleanup commands can reset it
    # This trap replaces the EXIT/INT/TERM trap that harness.sh (sourced in harness
    # mode) registered for its own teardown, so invoke that teardown here — otherwise
    # the harness container and temp CLI config are never cleaned up.
    if declare -F harness_cleanup >/dev/null 2>&1; then
        harness_cleanup
    fi
    exit "$exit_code"
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
    python3 -u "${INTEGRATION_DIR}/lib/run_tests_main.py"
