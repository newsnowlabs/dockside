#!/opt/dockside/theia/bin/sh

log() {
   local PID="$$"
   local S=$(printf "%s|%15s|%5d|" "$(date +%Y-%m-%d.%H:%M:%S)" "child-init" "$PID")
   echo "$S$1" >&2
}

which() {
   local cmd="$1"
   for p in $(echo $PATH | tr ':' '\012'); do [ -x "$p/$cmd" ] && echo "$p/$cmd" && break; done
}

fake_home() {
   local FAKEHOME="$1"
    
   mkdir -p "$FAKEHOME" && chown -R $IDE_USER.$IDE_USER "$FAKEHOME"

   export _HOME="$HOME"
   export HOME="$FAKEHOME"
}

set_home() {
   export HOME=$(getent passwd $IDE_USER | cut -d':' -f6)    
}

# Expects:
# - IDE_USER
# 
create_user() {
   # Use single '=' for sh-compatibility

   if ! getent passwd "$IDE_USER" >/dev/null; then
    
      # Use bash if available, as it may be a nicer shell experience than /bin/sh
      if [ -x "/bin/bash" ]; then
         SHL="/bin/bash"
      elif [ -x "/bin/ash" ]; then
         SHL="/bin/ash"
      else
         SHL="/bin/sh"
      fi
        
      # Add the user with this shell
      if [ -x $(which useradd) ] || [ -x $(which adduser) ]; then
         [ -x $(which useradd) ] && useradd -l -U -m $IDE_USER -s $SHL || adduser -D $IDE_USER -s $SHL
      fi
   fi
   
   # Fix homedir ownership, since bind-mounts may have created it wrongly.
   # FIXME: Implement a generalised solution to this, whereby Reservation Profile tmpfs
   # mounts are passed by docker-event-daemon to this script
   local HOME=$(getent passwd $IDE_USER | cut -d':' -f6)
   chown $IDE_USER.$IDE_USER $HOME $HOME/.vscode
        
   # Set up sudo, in case that package is installed
   if ! [ -f /etc/sudoers.d/$IDE_USER ]; then
      mkdir -p /etc/sudoers.d && echo "$IDE_USER ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/$IDE_USER
   fi
   
   # Alternatively, run echo 'root:<passwd>' | chpasswd to change to the root password and allow su to work.
   if [ -n "$ROOT_PASSWORD" ]; then
      echo "root:$ROOT_PASSWORD" | chpasswd
   fi
}

create_git_committer() {
   if [ -n "$GIT_COMMITTER_NAME" ] && [ -n "$GIT_COMMITTER_EMAIL" ]; then
      local HOME=$(getent passwd $IDE_USER | cut -d':' -f6)
      cat >$HOME/.gitconfig <<_EOE_ && chown $IDE_USER.$IDE_USER $HOME/.gitconfig
[user]
name = $GIT_COMMITTER_NAME
email = $GIT_COMMITTER_EMAIL
_EOE_
    fi
}

# DEPRECATED
meta_curl() {
   /opt/dockside/theia/bin/curl -sf --retry 10 --retry-delay 1 -m 10 -H 'Metadata-Flavor: Google' "$@"
}

# DEPRECATED
launch_entrypoint() {
  log "If ENTRYPOINT defined, exec it..."
  if [ -n "$ENTRYPOINT" ]; then
     exec $ENTRYPOINT
  fi
}

# Expects:
# - IDE_USER
# 

# 1. (Optionally) Create user (if needed)
# 2. (Optionally) Create .gitconfig file
# 3. Launch IDE watcher, in turn launching and keep running IDE.
launch_ide() {
   [ -n "$IDE_USER" ] || IDE_USER="root"

   # WARNING: DON'T BACKGROUND THESE WHILE LOOPS, OR SYSBOX RUNTIME WILL FAIL TO RUN CORRECTLY.
   if [ $(id -u) -eq 0 ] && [ "$IDE_USER" != "root" ]; then

      echo "IDE_USER=$IDE_USER" >&2
      create_user
      create_git_committer

      while true
      do
         /opt/dockside/theia/bin/su $IDE_USER -c "env -i HOME=\"$(getent passwd $IDE_USER | cut -d':' -f6)\" USER=\"$IDE_USER\" /opt/dockside/theia/bin/sh $IDE_PATH/bin/launch-ide.sh IDE_PATH=\"$IDE_PATH\""
         sleep 1
      done
   else

      IDE_USER=$(id -u -n)
      echo "IDE_USER=$IDE_USER" >&2

      create_git_committer

      # Either:
      # - Current user is root and IDE_USER is root;
      # - Current user is not root and IDE_USER is ignored.
      while true
      do
         /opt/dockside/theia/bin/sh $IDE_PATH/bin/launch-ide.sh IDE_PATH="$IDE_PATH"
         sleep 1
      done </dev/null &>/dev/null
   fi
}

# DEPRECATED
exec_meta_startup() {
  if [ -z "$METADATA_URI" ]; then
    return
  fi

  # To place this in a noexec filesystem - typically true for /tmp/ - would need special care
  # and treatment (such as parsing the shebang and calling the intepreter directly).
  while true
  do
      # Try re-reading the startup-script.
      log "Retrieving startup-script from metadata server... " >&2
      meta_curl -o $METADATA_SS_FSPATH $METADATA_URI/instance/attributes/startup-script && break

      # In case the startup-script was cached from a previous launch, break anyway.
      if [ -f "$METADATA_SS_FSPATH" ]; then
          log "Retrieved startup-script to '$METADATA_SS_FSPATH', or this file preexisted."
          break
      fi

      # Pause before trying again, indefinitely.
      log "No start-up script retrieved or preexisting, so looping... " >&2
      sleep 1
  done

  log "Execing startup script '$METADATA_SS_FSPATH'... " >&2
  [ -f "$METADATA_SS_FSPATH" ] && chmod 755 $METADATA_SS_FSPATH && exec $METADATA_SS_FSPATH
}

# DEPRECATED
launch() {

  launch_ide
  exec_meta_startup
  launch_entrypoint

  # If no entrypoint, wait for Theia watcher to exit.
  log "No ENTRYPOINT defined, waiting for Theia watcher to exit..."
  wait
}

IDE_PATH=$(realpath $(dirname $0))
eval "$@"

