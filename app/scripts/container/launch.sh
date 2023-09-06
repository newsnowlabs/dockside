#!/opt/dockside/theia/bin/sh -x

log() {
   local PID="$$"
   local S=$(printf "%s|%15s|%5d|" "$(date +%Y-%m-%d.%H:%M:%S)" "child-init" "$PID")
   echo "$S$1" >&2
}

which() {
   local cmd="$1"
   for p in $(echo $PATH | tr ':' '\012'); do [ -x "$p/$cmd" ] && echo "$p/$cmd" && break; done
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
   chown $IDE_USER.$IDE_USER $HOME
   [ -d $HOME/.vscode ] && chown $IDE_USER.$IDE_USER $HOME/.vscode
        
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

create_git_repo() {
   [ -n "$GIT_URL" ] || return

   local HOME=$(getent passwd $IDE_USER | cut -d':' -f6)
   cd $HOME

   # GIT_EXEC_PATH="$IDE_PATH/bin"
   # $IDE_PATH/bin/git-clone $GIT_URL && chown -R $IDE_USER.$IDE_USER $(basename $GIT_URL)
   $IDE_PATH/bin/git -c http.sslcainfo=$IDE_PATH/certs/ca-certificates.crt --exec-path=$IDE_PATH/bin clone $GIT_URL
   chown -R $IDE_USER.$IDE_USER $(basename -s .git $GIT_URL)
}

# Expects:
# - IDE_USER
# - IDE_PATH
# 

# 1. (Optionally) Create user (if needed)
# 2. (Optionally) Create .gitconfig file
# 3. Launch IDE watcher, in turn launching and keep running IDE.
launch_ide() {
   [ -n "$IDE_USER" ] || IDE_USER="root"
   
   # Use IDE_PATH if specified and directory exists;
   # otherwise look for the alphanumerically latest subsubdirectory of /opt/dockside/ide
   if [ -n "$IDE_PATH" ] && [ -d "$IDE_PATH" ]; then
     log "Using IDE_PATH '$IDE_PATH'"
   else
     IDE_PATH="$(ls -d /opt/dockside/ide/*/* | tail -n 1)"
     log "Selecting latest IDE_PATH '$IDE_PATH'"
   fi

   # WARNING: DON'T BACKGROUND THESE WHILE LOOPS, OR SYSBOX RUNTIME WILL FAIL TO RUN CORRECTLY.
   if [ $(id -u) -eq 0 ] && [ "$IDE_USER" != "root" ]; then

      echo "IDE_USER=$IDE_USER" >&2
      create_user
      create_git_committer
      create_git_repo

      while true
      do
         # su will retain exported env vars and set new ones.
         # So we use 'env -i' to clear all env vars before setting just the ones needed.
         $IDE_PATH/bin/su $IDE_USER -c "env -i HOME=\"$(getent passwd $IDE_USER | cut -d':' -f6)\" USER=\"$IDE_USER\" IDE_PATH=\"$IDE_PATH\" $IDE_PATH/bin/sh $IDE_PATH/bin/launch-ide.sh"
         sleep 1
      done
   else

      IDE_USER=$(id -u -n)
      echo "IDE_USER=$IDE_USER" >&2

      create_git_committer
      create_git_repo

      # Either:
      # - Current user is root and IDE_USER is root;
      # - Current user is not root and IDE_USER is ignored.
      while true
      do
         IDE_PATH="$IDE_PATH" $IDE_PATH/bin/sh $IDE_PATH/bin/launch-ide.sh
         sleep 1
      done
   fi
}

eval "$@"