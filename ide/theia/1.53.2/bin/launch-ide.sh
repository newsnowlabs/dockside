#!/opt/dockside/theia/bin/sh -l

# Expects:
# - IDE_PATH
# 

log() {
  local PID="$$"
  local S=$(printf "%s|%15s|%5d|" "$(date +%Y-%m-%d.%H:%M:%S)" "theia" "$PID")
  echo "$S$1" >&2
}

which() {
  local cmd="$1"
  for p in $(echo $PATH | tr ':' '\012'); do [ -x "$p/$cmd" ] && echo "$p/$cmd" && break; done
}

LOG=/tmp/dockside/theia.log

log "Creating logfile '$LOG' ..."
touch $LOG && chmod 666 $LOG

exec 1>>$LOG
exec 2>>$LOG

log "Evaling arguments $@ ..."
eval "$@"

log "Launching IDE from IDE_PATH='$IDE_PATH' ..."

log "Backing up and overriding PATH=$PATH ..."
export _PATH="$PATH"
export PATH="$IDE_PATH/bin:$PATH"

# Run ssh-agent if available, but not already running.
log "Checking for ssh-agent ..."
if [ -x $(which ssh-agent) ] && ! pgrep ssh-agent >/dev/null; then
   log "Found ssh-agent binary but no running agent, so launching it ..."
   eval $($(which ssh-agent))
fi

# See https://github.com/eclipse-theia/theia/blob/master/CHANGELOG.md under v0.13.0
# 
# Webview origin pattern can be configured with THEIA_WEBVIEW_EXTERNAL_ENDPOINT env variable.
# The default value is {{uuid}}.webview.{{hostname}}.
# Here {{uuid}} and {{hostname}} are placeholders which get replaced at runtime with proper webview uuid and hostname correspondingly.
#
# To switch to un-secure mode as before configure THEIA_WEBVIEW_EXTERNAL_ENDPOINT with {{hostname}} as a value.
# You can also drop {{uuid}}. prefix, in this case, webviews still will be able to access each other but not the main window.
#export THEIA_WEBVIEW_EXTERNAL_ENDPOINT='{{uuid}}-webview-{{hostname}}'
#export THEIA_MINI_BROWSER_HOST_PATTERN='{{uuid}}-minibrowser-{{hostname}}'
export THEIA_WEBVIEW_EXTERNAL_ENDPOINT='{{uuid}}-wv-{{hostname}}'
export THEIA_MINI_BROWSER_HOST_PATTERN='{{uuid}}-mb-{{hostname}}'
export SHELL="$IDE_PATH/bin/dummysh"

THEIA_PATH=$IDE_PATH
log "Launching IDE using: $THEIA_PATH/bin/node $THEIA_PATH/theia/src-gen/backend/main.js $HOME --hostname 0.0.0.0 --port 3131 ..."

unset IDE_PATH
cd $THEIA_PATH/theia || exit 1

log "Listing launch environment variables ..."
env | sed -r 's/^/    /' >&2

exec $THEIA_PATH/bin/node $THEIA_PATH/theia/src-gen/backend/main.js $HOME --hostname 0.0.0.0 --port 3131 --plugins=local-dir:$HOME/theia-plugins
