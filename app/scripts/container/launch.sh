#!/opt/dockside/theia/bin/sh

log() {
   local PID="$$"
   local S=$(printf "%s|%15s|%5d|" "$(date +%Y-%m-%d.%H:%M:%S)" "launch" "$PID")
   echo "$S$1" >&2
}

which() {
   local cmd="$1"
   for p in $(echo $PATH | tr ':' '\012'); do [ -x "$p/$cmd" ] && echo "$p/$cmd" && return 0; done
   return 1
}

debug() {
   DEBUG=1
   set -x
}

# Create busybox shortcut for certain commands
for a in id chown chmod; do eval "$a() { busybox $a \"\$@\"; }"; done

# Assumes getent can be found in PATH
create_user() {

   # Only proceed if we are root, and the desired IDE_USER is NOT root
   [ $(id -u) -eq 0 ] && [ "$IDE_USER" != "root" ] || return

   log "Checking for user account: $IDE_USER"

   # Use single '=' for sh-compatibility

   if ! getent passwd "$IDE_USER" >/dev/null; then
      log "Creating user account: $IDE_USER"
    
      # Use bash if available, as it may be a nicer shell experience than /bin/sh
      local SHL
      if [ -x "/bin/bash" ]; then
         SHL="/bin/bash"
      elif [ -x "/bin/ash" ]; then
         SHL="/bin/ash"
      else
         SHL="/bin/sh"
      fi

      log "Detected shell: $SHL"
        
      # Add the user with this shell, using an available command from the image
      if [ -x "$(which useradd)" ]; then
         log "Running: useradd -l -U -m $IDE_USER -s $SHL"
         useradd -l -U -m $IDE_USER -s $SHL
      elif [ -x "$(which adduser)" ]; then
         log "Running: adduser -D $IDE_USER -s $SHL"
         adduser -D $IDE_USER -s $SHL
      else
         log "Running: busybox adduser -D $IDE_USER -s $SHL"
         busybox adduser -D $IDE_USER -s $SHL
      fi
   else
      log "Found existing user account: $IDE_USER"
   fi
   
   # Fix homedir ownership, since bind-mounts may have created it wrongly.
   local HOME=$(getent passwd $IDE_USER | cut -d':' -f6)

   log "Restoring correct ownership for HOME: $HOME"
   busybox chown $IDE_USER:$IDE_USER $HOME
   
   # A generalised solution to docker issue, whereby tmpfs mountpoint ownership and mode
   # is incorrectly set following container stop/start: find tmpfs inside $HOME and
   # fixup ownership and permissions.
   for p in $(busybox cat /proc/mounts | busybox grep "^tmpfs $HOME[/ ]" | busybox awk '{print $2}')
   do
      if [ -d "$p" ]; then
         log "Restoring correct ownership and permissions for tmpfs: $p"
         busybox chown $IDE_USER:$IDE_USER $p
         busybox chmod u=rwx,g=rx,o=rx,+t $p
      fi
   done

   # Set up sudo, in case that package is installed
   if ! [ -f /etc/sudoers.d/$IDE_USER ]; then
      log "Setting up $IDE_USER for sudo (requires sudo package)"
      busybox mkdir -p /etc/sudoers.d && echo "$IDE_USER ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/$IDE_USER
   fi
   
   # Alternatively, run echo 'root:<passwd>' | chpasswd to change to the root password and allow su to work.
   if [ -n "$ROOT_PASSWORD" ]; then
      log "Setting root password"
      echo "root:$ROOT_PASSWORD" | busybox chpasswd
   fi
}

update_ssh_authorized_keys() {
   local KEYS=$(echo "$AUTHORIZED_KEYS" | jq -re '.[]?')
   local HOME=$(getent passwd $IDE_USER | cut -d':' -f6)
   log "Creating $HOME/.ssh/authorized_keys for $IDE_USER"

   # Set up .ssh folder, if it doesn't exist
   busybox mkdir -p $HOME/.ssh

   # Set up authorized_keys, whether or not it exists
   echo "$KEYS" >$HOME/.ssh/authorized_keys

   log "Resetting ownership and permissions for $HOME/.ssh and $HOME/.ssh/authorized_keys"
   busybox chown $IDE_USER:$IDE_USER $HOME/.ssh $HOME/.ssh/authorized_keys
   busybox chmod u=rwX,g=rX,o=rX $HOME/.ssh
   busybox chmod 600 $HOME/.ssh/authorized_keys
}

create_git_config() {
   local HOME=$(getent passwd $IDE_USER | cut -d':' -f6)

   if [ -f "$HOME/.gitconfig" ]; then
      log "Leaving be existing ~/.gitconfig"
      return
   fi

   if [ -z "$GIT_COMMITTER_NAME" ] && [ -z "$GIT_COMMITTER_EMAIL" ]; then
      GIT_COMMITTER_NAME=$(echo "$OWNER_DETAILS" | jq -re '.name')
      GIT_COMMITTER_EMAIL=$(echo "$OWNER_DETAILS" | jq -re '.email')
   fi

   if [ -n "$GIT_COMMITTER_NAME" ] && [ -n "$GIT_COMMITTER_EMAIL" ]; then
      log "Creating ~/.gitconfig for $IDE_USER"
      busybox cat >$HOME/.gitconfig <<_EOE_ && busybox chown $IDE_USER:$IDE_USER $HOME/.gitconfig
[user]
name = $GIT_COMMITTER_NAME
email = $GIT_COMMITTER_EMAIL
_EOE_
    fi
}

launch_sshd() {
   [ -x "$(which dropbear)" ] && [ -x "$(which dropbearkey)" ] && [ -x "$(which wstunnel)" ] || return

   log "- SSHD_ENABLE='$SSHD_ENABLE'"
   log "- HOSTDATA_PATH='$HOSTDATA_PATH'"

   [ -n "$HOSTDATA_PATH" ] || return
   [ "$SSHD_ENABLE" = "1" ] || return

   log "Launching sshd services ..."
   [ $(id -u) -eq 0 ] && DROPBEAR_PORT=22 || DROPBEAR_PORT=2022
   [ -d "$HOSTDATA_PATH" ] || mkdir -p $HOSTDATA_PATH

   [ -f "$HOSTDATA_PATH/ed25519_host_key" ] || dropbearkey -t ed25519 -f $HOSTDATA_PATH/ed25519_host_key

   log "(1/2) Launching dropbear on port $DROPBEAR_PORT with host keys from $HOSTDATA_PATH"
   dropbear -RE -p 127.0.0.1:$DROPBEAR_PORT -r $HOSTDATA_PATH/ed25519_host_key >/tmp/dockside/dropbear.log 2>&1

   log "(2/2) Launching wstunnel on port 2222"
   wstunnel --server ws://0.0.0.0:2222 --restrictTo=127.0.0.1:$DROPBEAR_PORT >/tmp/dockside/wstunnel.log 2>&1 &
}

create_git_repo() {
   [ -n "$GIT_URL" ] || return

   log "Creating git repo for '$GIT_URL' ..."
   log "GIT_KEYS=$GIT_KEYS"

   local KEY_PATH="$HOME/.ssh/key"

   [ -f "$KEY_PATH" ] || echo "$GIT_KEYS" | jq -re '.private' >$KEY_PATH
   [ -f "$KEY_PATH.pub" ] || echo "$GIT_KEYS" | jq -re '.public' >$KEY_PATH.pub

   chmod 400 $KEY_PATH $KEY_PATH.pub

   $IDE_PATH/bin/ssh-add "$KEY_PATH"
   $IDE_PATH/bin/ssh-add -L
   
   log "- Running: IDE_PATH/bin/ssh-keyscan github.com >$HOME/.ssh/known_hosts"
   $IDE_PATH/bin/ssh-keyscan github.com >$HOME/.ssh/known_hosts
   
   # GIT_SSH_COMMAND="$IDE_PATH/bin/ssh -i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
   # $IDE_PATH/bin/git -c http.sslcainfo=$IDE_PATH/certs/ca-certificates.crt --exec-path=$IDE_PATH/bin clone $GIT_URL

   log "- Running: $IDE_PATH/bin/git -c http.sslcainfo=$IDE_PATH/certs/ca-certificates.crt --exec-path=$IDE_PATH/bin clone $GIT_URL"
   GIT_SSH_COMMAND="$IDE_PATH/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" $IDE_PATH/bin/git -c http.sslcainfo=$IDE_PATH/certs/ca-certificates.crt --exec-path=$IDE_PATH/bin clone $GIT_URL
}

spawn_ssh_agent() {
   log "Checking for ssh-agent ..."
   if [ -x $(which ssh-agent) ] && ! pgrep ssh-agent >/dev/null; then
      log "Found ssh-agent binary but no running agent, so launching it ..."
      
      eval $($(which ssh-agent))
      export SSH_AUTH_SOCK

      log "Launched ssh-agent binary with SSH_AUTH_SOCK='$SSH_AUTH_SOCK'"
   fi
}

launch_nonroot() {
   log "Launching subprocess for non-root user '$IDE_USER' ..."

   local HOME=$(getent passwd $IDE_USER | cut -d':' -f6)
   cd $HOME

   $IDE_PATH/bin/su $IDE_USER -c "env PATH=\"$_PATH\" HOME=\"$HOME\" /opt/dockside/launch.sh run_nonroot"
}

launch_theia() {
   # WARNING: DON'T BACKGROUND THESE WHILE LOOPS, OR SYSBOX RUNTIME WILL FAIL TO RUN CORRECTLY.
   while true
   do

      log "Launching and supervising the Theia IDE at $IDE_PATH"

      if [ $(id -u) -eq 0 ] && [ "$IDE_USER" != "root" ]; then
         # su will retain exported env vars and set new ones.
         # So we use 'env -i' to clear all env vars before setting just the ones needed.
         $IDE_PATH/bin/su $IDE_USER -c "env -i PATH=\"$_PATH\" HOME=\"$(getent passwd $IDE_USER | cut -d':' -f6)\" USER=\"$IDE_USER\" IDE_PATH=\"$IDE_PATH\" $IDE_PATH/bin/sh $IDE_PATH/bin/launch-ide.sh"
      else
         env -i PATH="$_PATH" IDE_PATH="$IDE_PATH" SSH_AUTH_SOCK="$SSH_AUTH_SOCK" $IDE_PATH/bin/sh $IDE_PATH/bin/launch-ide.sh
      fi

      sleep 1
   done   
}

run_nonroot() {
   spawn_ssh_agent
   create_git_repo
   launch_theia
}

launch_ide() {
   create_user
   create_git_config
   update_ssh_authorized_keys
   launch_sshd
   launch_nonroot
}

init() {
   # Use IDE_PATH if specified and directory exists; otherwise look for the
   # alphanumerically latest subsubdirectory of /opt/dockside/ide.
   #
   # N.B. Assume we can find ls and tail in the PATH
   if [ -z "$IDE_PATH" ] || ! [ -d "$IDE_PATH" ]; then
      IDE_PATH="$(ls -d /opt/dockside/ide/*/* | tail -n 1)"
   fi

   [ -n "$IDE_USER" ] || IDE_USER="root"

   export _PATH="$PATH"
   PATH="$IDE_PATH/bin:$PATH"

   LOG_PATH=/tmp/dockside
   LOG=$LOG_PATH/launch-$(id -u).log

   [ -d $LOG_PATH ] || busybox mkdir -p $LOG_PATH && busybox chmod a+rwx,+t $LOG_PATH
   [ -d $LOG ] || busybox touch $LOG && busybox chmod 644 $LOG

   exec 1>>$LOG
   exec 2>>$LOG

   if [ -z "$DEBUG" ]; then
      log "Executing '$@' with IDE_USER=$IDE_USER, IDE_PATH=$IDE_PATH:"
   else
      log "Executing '$@' with IDE_USER=$IDE_USER, IDE_PATH=$IDE_PATH and environment:"
      busybox env | busybox sed 's/^/=> /'}
   fi
}

init "$@"
eval "$@"