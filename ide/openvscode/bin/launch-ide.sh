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
export PATH="$IDE_PATH/bin:$PATH:$IDE_PATH/bin"
export GIT_EXEC_PATH="$IDE_PATH/bin"

log "Launching IDE from IIDE_PATH='$IIDE_PATH' using: ./node ./out/server-main.js --host 0.0.0.0 --port 3131 --without-connection-token ..."

cd $IIDE_PATH/openvscode
unset IDE_PATH IDE IIDE_PATH LOG_PATH

log "- environment variables:"
env | sed -r 's/^/    /' >&2

# FIXME: Parametrise /opt/dockside here
mkdir -p $HOME/.openvscode-server/data/Machine && echo '{ "git.path": "/opt/dockside/ide/theia/latest/bin/git", "git.confirmSync": false }' >$HOME/.openvscode-server/data/Machine/settings.json
exec ./node ./out/server-main.js --host 0.0.0.0 --port 3131 --without-connection-token