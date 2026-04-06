#!/bin/bash
#
# Prepare a 'vanilla' local (non-container) Debian environment and launch Dockside
# via its standard container entrypoint, under its included s6 supervisor, then
# authenticate the CLI automatically.
#
# - Suitable for running integration tests locally inside a vanilla Debian environment
#   with dockerd installed, such as Claude Code for Web
# - Run as root. 
#
# Usage: bash build/development/run-local.sh [--reset] [extra entrypoint args]
#
# Options:
#   --reset   Remove /data/config and ~/.config/dockside before starting,
#             forcing fresh credential generation and a clean CLI session.
#
# After startup:
#   /tmp/dockside-passwd  — admin credentials (admin:<password>)
#   /tmp/dockside-env     — source this before using ./cli/dockside in other shells

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASSWD_FILE=/tmp/dockside-passwd
ENV_FILE=/tmp/dockside-env

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

# 7. Optionally reset config and CLI session state.
if [ -n "$RESET" ]; then
  rm -rf /data/config ~/.config/dockside
  echo "run-local: /data/config and ~/.config/dockside cleared"
fi

# 8. Ensure www.local.dockside.dev bypasses any HTTP proxy, then write an env file
#    that CLI callers can source to get the same setting.
export no_proxy="${no_proxy:+${no_proxy},}www.local.dockside.dev"
export NO_PROXY="${NO_PROXY:+${NO_PROXY},}www.local.dockside.dev"
printf 'export no_proxy="%s"\nexport NO_PROXY="%s"\n' "$no_proxy" "$NO_PROXY" > "$ENV_FILE"

# 9. Kill any manually-started dockerd; s6 will manage it via --run-dockerd.
pkill -x dockerd 2>/dev/null || true
sleep 1

# 10. Launch entrypoint in the background (it will exec s6-svscan and block indefinitely).
#     --run-dockerd skips docker socket check and container ID detection.
#     --ssl-builtin uses the built-in local.dockside.dev cert (Host: www.local.dockside.dev).
#     --passwd-file captures admin credentials for CLI use.
/home/dockside/dockside/app/scripts/entrypoint.sh \
  --run-dockerd \
  --ssl-builtin \
  --passwd-file "$PASSWD_FILE" \
  "${EXTRA_ARGS[@]}" &
ENTRYPOINT_PID=$!

# 11. Wait for entrypoint to write the passwd file (signals config is ready).
echo "run-local: waiting for server to initialise..."
WAIT=0
until [ -s "$PASSWD_FILE" ] || ! kill -0 "$ENTRYPOINT_PID" 2>/dev/null; do
  sleep 1
  WAIT=$((WAIT + 1))
  [ "$WAIT" -ge 60 ] && echo "run-local: timed out waiting for passwd file" && exit 1
done

# 12. Wait for nginx to accept HTTPS connections.
echo "run-local: waiting for nginx..."
WAIT=0
until curl -sk --connect-timeout 2 https://127.0.0.1/ -o /dev/null 2>/dev/null; do
  sleep 2
  WAIT=$((WAIT + 2))
  [ "$WAIT" -ge 60 ] && echo "run-local: timed out waiting for nginx" && exit 1
done

# 13. Authenticate the CLI.
USERNAME=$(cut -d: -f1 "$PASSWD_FILE")
PASSWORD=$(cut -d: -f2 "$PASSWD_FILE")
"$REPO_DIR/cli/dockside" login \
  --connect-to 127.0.0.1 \
  --no-verify \
  --nickname local \
  --server https://www.local.dockside.dev/ \
  --username "$USERNAME" \
  --password "$PASSWORD"

echo "run-local: ready. To use the CLI in another shell: source $ENV_FILE"

# Keep this process alive so the server isn't orphaned if run in the foreground.
wait "$ENTRYPOINT_PID"
