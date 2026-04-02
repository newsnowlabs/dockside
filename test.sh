#!/usr/bin/env bash
# test.sh — Dockside automated test suite
#
# Runs static analysis and build checks that require no running container.
# Usage:
#   bash test.sh                  # run all checks
#   bash test.sh --only perl      # run one category
#   bash test.sh --only vue
#   bash test.sh --only eslint
#   bash test.sh --only stylelint
#   bash test.sh --only shellcheck
#   bash test.sh --only perltidy
#   bash test.sh --only json
#
# Exit code: 0 if all selected checks pass, 1 otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ── Colours ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; RESET='\033[0m'; BOLD='\033[1m'
else
  GREEN=''; RED=''; YELLOW=''; RESET=''; BOLD=''
fi

# ── State ────────────────────────────────────────────────────────────────────
declare -A RESULTS=()
ONLY="${2:-}"   # set by --only flag below

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
run_check() {
  local name="$1"; shift
  [[ -n "$ONLY" && "$ONLY" != "$name" ]] && return 0

  echo ""
  echo -e "${BOLD}━━━ $name ━━━${RESET}"
  if "$@"; then
    RESULTS["$name"]="PASS"
    echo -e "${GREEN}✓ $name passed${RESET}"
  else
    RESULTS["$name"]="FAIL"
    echo -e "${RED}✗ $name FAILED${RESET}"
  fi
}

skip_check() {
  local name="$1"; local reason="$2"
  [[ -n "$ONLY" && "$ONLY" != "$name" ]] && return 0
  RESULTS["$name"]="SKIP"
  echo ""
  echo -e "${YELLOW}⚠ $name skipped: $reason${RESET}"
}

# ── 1. Perl syntax / compile check ──────────────────────────────────────────
check_perl() {
  # Ensure CPAN dependencies are available (installed as Debian packages in the container)
  local missing_debs=()
  for pkg in \
              libtry-tiny-perl liburi-perl libterm-readkey-perl libjson-xs-perl libexpect-perl \
              libcrypt-rijndael-perl libmojolicious-perl \
              libyaml-libyaml-perl \
              libio-async-perl \
              ; do
    if ! dpkg -s "$pkg" &>/dev/null; then
      missing_debs+=("$pkg")
    fi
  done
  if [[ ${#missing_debs[@]} -gt 0 ]]; then
    echo "  Installing missing Perl CPAN packages via apt: ${missing_debs[*]}"
    apt-get install -y -q "${missing_debs[@]}" 2>&1 | tail -5
  fi

  local failed=0

  local modules=(
    app/server/lib/App.pm
    app/server/lib/App/Metadata.pm
    app/server/lib/Containers.pm
    app/server/lib/Data.pm
    app/server/lib/Exception.pm
    app/server/lib/Profile.pm
    app/server/lib/Proxy.pm
    app/server/lib/Request.pm
    app/server/lib/Reservation.pm
    app/server/lib/Reservation/Launch.pm
    app/server/lib/Reservation/Load.pm
    app/server/lib/Reservation/Mutate.pm
    app/server/lib/User.pm
    app/server/lib/User/Manage.pm
    app/server/lib/Util.pm
  )

  # Note: upgrade and password-wrapper are bash scripts, also excluded.
  local scripts=(
    app/server/bin/docker-event-daemon
    app/server/bin/mkpasswd
    app/server/bin/password
    app/server/bin/json-to-yaml
  )

  for f in "${modules[@]}" "${scripts[@]}"; do
    if [[ ! -f "$f" ]]; then
      echo "  MISSING: $f"
      failed=1
      continue
    fi
    if ! perl -c -I app/server/lib -I t/stubs "$f" 2>/dev/null; then
      echo "  FAILED:  $f"
      perl -c -I app/server/lib -I t/stubs "$f" 2>&1 || true
      failed=1
    else
      echo "  OK:      $f"
    fi
  done

  return $failed
}

# ── 2. Vue / JS production build ────────────────────────────────────────────
check_vue() {
  if ! command -v npm &>/dev/null; then
    echo "npm not found — skipping Vue build"
    return 1
  fi

  (
    cd app/client

    # Only run npm install if node_modules is missing or package-lock.json changed
    if [[ ! -d node_modules ]]; then
      echo "  Running npm install..."
      npm install --prefer-offline 2>&1
    else
      echo "  node_modules present, skipping npm install"
    fi

    echo "  Running npm run build..."
    npm run build 2>&1
  )
}

# ── 3. ESLint ────────────────────────────────────────────────────────────────
check_eslint() {
  if ! command -v npm &>/dev/null; then
    echo "npm not found — cannot run ESLint"
    return 1
  fi
  if [[ ! -d app/client/node_modules ]]; then
    echo "node_modules not installed — run the 'vue' check first"
    return 1
  fi
  (
    cd app/client
    echo "  Running ESLint on src/..."
    npx --no-install eslint src/ --ext .js,.vue 2>&1
  )
}

# ── 4. StyleLint ─────────────────────────────────────────────────────────────
check_stylelint() {
  if ! command -v npm &>/dev/null; then
    echo "npm not found — cannot run StyleLint"
    return 1
  fi
  if [[ ! -d app/client/node_modules ]]; then
    echo "node_modules not installed — run the 'vue' check first"
    return 1
  fi
  (
    cd app/client
    echo "  Running StyleLint on src/..."
    npx --no-install stylelint "src/**/*.{vue,scss,css}" 2>&1
  )
}

# ── 5. ShellCheck ─────────────────────────────────────────────────────────────
check_shellcheck() {
  if ! command -v shellcheck &>/dev/null; then
    echo "shellcheck not found (install with: apt-get install -y shellcheck)"
    return 1
  fi

  # Note: json-to-yaml is a Perl one-liner with no shebang, so excluded from shellcheck.
  local scripts=(
    test.sh
    app/scripts/entrypoint.sh
    app/scripts/runscripts/nginx/run
    app/scripts/runscripts/dockerd/run
    app/scripts/runscripts/docker-event-daemon/run
    app/scripts/runscripts/bind/run
    app/scripts/runscripts/dehydrated/run
    app/scripts/runscripts/logrotate/run
    app/server/bin/upgrade
    app/server/bin/password-wrapper
    app/scripts/container/launch.sh
    t/integration/run_tests.sh
    t/integration/harness.sh
  )

  local failed=0
  for f in "${scripts[@]}"; do
    if [[ ! -f "$f" ]]; then
      echo "  MISSING: $f"
      failed=1
      continue
    fi
    if shellcheck --severity=error "$f" 2>&1; then
      echo "  OK:      $f"
    else
      echo "  FAILED:  $f"
      failed=1
    fi
  done
  return $failed
}

# ── 6. perltidy formatting check ─────────────────────────────────────────────
check_perltidy() {
  if ! command -v perltidy &>/dev/null; then
    echo "perltidy not found"
    return 1
  fi

  local profile="build/development/perltidyrc"
  if [[ ! -f "$profile" ]]; then
    echo "perltidy profile not found at $profile"
    return 1
  fi

  local failed=0
  local tmpfile
  tmpfile="$(mktemp)"

  # Avoid process substitution: /dev/fd may not exist in all container environments
  local pm_list
  pm_list="$(mktemp)"
  find app/server/lib -name '*.pm' | sort > "$pm_list"

  while IFS= read -r f; do
    perltidy --profile="$profile" -st "$f" > "$tmpfile" 2>&1
    if ! diff -q "$f" "$tmpfile" &>/dev/null; then
      echo "  FORMAT DIFF: $f"
      diff "$f" "$tmpfile" || true
      failed=1
    else
      echo "  OK:          $f"
    fi
  done < "$pm_list"

  rm -f "$tmpfile" "$pm_list"
  return $failed
}

# ── 7. JSON / YAML validation ─────────────────────────────────────────────────
check_json() {
  local failed=0

  local json_files=(
    app/client/package.json
    app/client/jsconfig.json
    t/integration/config/users.json
    t/integration/config/roles.json
  )

  for f in "${json_files[@]}"; do
    if [[ ! -f "$f" ]]; then
      echo "  MISSING: $f"
      failed=1
      continue
    fi
    if python3 -m json.tool "$f" > /dev/null 2>&1; then
      echo "  OK (JSON): $f"
    else
      echo "  INVALID:   $f"
      python3 -m json.tool "$f" 2>&1 || true
      failed=1
    fi
  done

  # YAML
  if python3 -c "import yaml" 2>/dev/null; then
    for f in mkdocs.yml; do
      if [[ ! -f "$f" ]]; then continue; fi
      if python3 -c "import yaml, sys; yaml.safe_load(open('$f'))" 2>&1; then
        echo "  OK (YAML): $f"
      else
        echo "  INVALID:   $f"
        failed=1
      fi
    done
  else
    echo "  (python3-yaml not available, skipping YAML validation)"
  fi

  return $failed
}

# ── 8. Python syntax check ───────────────────────────────────────────────────
check_python() {
  local failed=0
  local py_files=()

  # Gather all Python files under t/integration/ and cli/
  while IFS= read -r -d '' f; do
    py_files+=("$f")
  done < <(find t/integration cli -name '*.py' -print0 2>/dev/null | sort -z)

  if [[ ${#py_files[@]} -eq 0 ]]; then
    echo "  (no Python files found)"
    return 0
  fi

  for f in "${py_files[@]}"; do
    if python3 -m py_compile "$f" 2>&1; then
      echo "  OK:     $f"
    else
      echo "  FAILED: $f"
      failed=1
    fi
  done
  return $failed
}

check_integration() {
  if [[ -z "${DOCKSIDE_TEST_HOST:-}" && -z "${DOCKSIDE_TEST_IMAGE:-}" && \
        "${DOCKSIDE_TEST_MODE:-}" != 'local' ]]; then
    echo "  SKIP: Set DOCKSIDE_TEST_HOST or DOCKSIDE_TEST_IMAGE to run integration tests."
    echo "  See t/integration/README.md for full usage."
    return 1
  fi
  bash "$REPO_ROOT/t/integration/run_tests.sh"
}

# ── Run checks ───────────────────────────────────────────────────────────────
echo -e "${BOLD}Dockside test suite${RESET}"
echo "Repo: $REPO_ROOT"

run_check "perl"       check_perl
run_check "vue"        check_vue
run_check "eslint"     check_eslint
run_check "stylelint"  check_stylelint
run_check "shellcheck" check_shellcheck
run_check "json"       check_json
run_check "python"     check_python
# perltidy is available via --only perltidy but excluded from the default run:
# the codebase pre-dates perltidy enforcement and has many pre-existing diffs.
[[ -n "$ONLY" ]] && run_check "perltidy" check_perltidy
# Integration tests require a running Dockside instance; opt-in only:
[[ -n "$ONLY" ]] && run_check "integration" check_integration

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ Summary ━━━${RESET}"

overall=0
for name in perl vue eslint stylelint shellcheck json perltidy; do
  result="${RESULTS[$name]:-SKIP}"
  case "$result" in
    PASS) echo -e "  ${GREEN}✓ PASS${RESET}  $name" ;;
    FAIL) echo -e "  ${RED}✗ FAIL${RESET}  $name"; overall=1 ;;
    SKIP) echo -e "  ${YELLOW}⚠ SKIP${RESET}  $name" ;;
  esac
done

echo ""
if [[ $overall -eq 0 ]]; then
  echo -e "${GREEN}All checks passed.${RESET}"
else
  echo -e "${RED}One or more checks FAILED.${RESET}"
fi

exit $overall
