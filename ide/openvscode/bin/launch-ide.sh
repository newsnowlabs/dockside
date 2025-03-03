#!/opt/dockside/system/latest/bin/sh -l

# Expects:
# - IDE_PATH
# - LOG_PATH
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
export PATH="$PATH:$IDE_PATH/bin"

log "Launching IDE from IIDE_PATH='$IIDE_PATH' using: ./node ./out/server-main.js --host 0.0.0.0 --port 3131 --without-connection-token ..."

# Create system settings
SETTINGS_DIR="$HOME/.openvscode-server/data/Machine"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
mkdir -p $SETTINGS_DIR
[ -f "$SETTINGS_FILE" ] || echo '{}' >$SETTINGS_FILE
jq --arg binpath "$IDE_PATH/bin" '."git.path"=$binpath+"/git" | ."telemetry.telemetryLevel"="off" | ."terminal.integrated.env.linux".PATH="${env:PATH}:"+$binpath' $SETTINGS_FILE >$SETTINGS_FILE.new && mv $SETTINGS_FILE.new $SETTINGS_FILE

cd $IIDE_PATH/openvscode
unset IDE_PATH IDE IIDE_PATH LOG_PATH

log "- environment variables:"
env | sed -r 's/^/    /' >&2

exec ./node ./out/server-main.js --host 0.0.0.0 --port 3131 --without-connection-token