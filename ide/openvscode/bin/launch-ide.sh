#!/opt/dockside/system/latest/bin/sh -l

# Expects:
# - IIDE_PATH: path to IDE folder e.g. /opt/dockside/ide/openvscode/latest/
# - IDE_PATH:  path to system folder e.g. /opt/dockside/system/latest
# - LOG_PATH:  path to log folder
# 

log() {
  local PID="$$"
  local S=$(printf "%s|%15s|%5d|" "$(date +%Y-%m-%d.%H:%M:%S)" "openvscode" "$PID")
  echo "$S$1" >&2
}

LOG=$LOG_PATH/openvscode.log

log "Switching logging to '$LOG' ..."
touch $LOG && chmod 666 $LOG

exec 1>>$LOG
exec 2>>$LOG

log "Evaling arguments $@ ..."
eval "$@"

# Set needed environment variables
export PATH="$PATH:$IDE_PATH/bin:$IIDE_PATH/openvscode/bin/remote-cli"
export GIT_EXEC_PATH="$IDE_PATH/bin"
export GIT_EDITOR="$IIDE_PATH/openvscode/bin/remote-cli/openvscode-server --wait --reuse-window"
export EDITOR="$GIT_EDITOR"

log "Launching IDE with IIDE_PATH='$IIDE_PATH' and IDE_PATH='$IDE_PATH' using: ./node ./out/server-main.js --host 0.0.0.0 --port 3131 --without-connection-token ..."

# Create system settings
SETTINGS_DIR="$HOME/.openvscode-server/data/Machine"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
mkdir -p $SETTINGS_DIR
[ -f "$SETTINGS_FILE" ] || echo '{}' >$SETTINGS_FILE
jq --arg binpath "$IDE_PATH/bin" \
  -f /dev/stdin \
  "$SETTINGS_FILE" >"$SETTINGS_FILE.new" <<'EOF' && mv "$SETTINGS_FILE.new" "$SETTINGS_FILE"
# set git binary path
."git.path"=$binpath+"/git"
# disable telemetry
| ."telemetry.telemetryLevel"="off"
# extend terminal PATH with bin dir
| ."terminal.integrated.env.linux".PATH="${env:PATH}:"+$binpath
# disable AI/Copilot features, while GitHub.copilot-chat VSIX is unavailable on OpenVSX
| ."chat.disableAIFeatures"=true
EOF

cd $IIDE_PATH/openvscode
unset IDE_PATH IDE IIDE_PATH LOG_PATH

log "- environment variables:"
env | sort | sed -r 's/^/    /' >&2

exec ./node ./out/server-main.js --host 0.0.0.0 --port 3131 --without-connection-token --telemetry-level off
