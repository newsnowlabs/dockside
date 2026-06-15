#!/opt/dockside/system/latest/bin/sh

# Purpose:
# - Called by docker-event-daemon, via `docker exec`, to launch needed portable binary components
#   e.g. useradd, git, ssh-agent, chosen IDE, in the development container context.
#
# Input environment:
# - IDE_PATH: (awaiting rename)
#    - references a path to system binaries
#     /opt/dockside/system/current, /opt/dockside/system/latest or /opt/dockside/system/<version>
#   - resolves any symlink to an actual directory, so that symlink updates on upgrades remain safe;
#   - fallback: look for a suitable subdir of /opt/dockside/system
# - IDE_USER:
#   - the user account with which to launch non-root-capable components e.g. git, ssh-agent, the IDE
# - PATH:
#   - the PATH environment variables, normally determined by docker per the container's image

DOCKSIDE_ROOT="/opt/dockside"

log() {
   local PID="$$"
   local S=$(printf "%s|%15s|%5d|" "$(date +%Y-%m-%d.%H:%M:%S)" "launch" "$PID")
   echo "$S$1" >&2
}

# Use the IDE-bundled git binary. Its CA cert store (http.sslcainfo) and exec-path
# are baked into that binary's own wrapper script (created in the Dockerfile next to
# the gh wrapper), so they no longer need to be passed on every call here.
git() {
   $IDE_PATH/bin/git "$@"
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
for a in id chown chmod date find grep head mkdir mv readlink sed sort tail tr xargs
do
  eval "$a() { busybox $a \"\$@\"; }"
done

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
   for p in $(busybox cat /proc/mounts | busybox grep "^tmpfs ${HOME}[/ ]" | busybox awk '{print $2}')
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

   if [ -z "$GIT_COMMITTER_NAME" ] && [ -z "$GIT_COMMITTER_EMAIL" ]; then
      GIT_COMMITTER_NAME=$(echo "$OWNER_DETAILS" | jq -re '.name')
      GIT_COMMITTER_EMAIL=$(echo "$OWNER_DETAILS" | jq -re '.email')
   fi

   if [ -n "$GIT_COMMITTER_NAME" ] && [ -n "$GIT_COMMITTER_EMAIL" ]; then
      log "Updating ~/.gitconfig with user.name = $GIT_COMMITTER_NAME"
      $IDE_PATH/bin/git config -f $HOME/.gitconfig --replace-all user.name "$GIT_COMMITTER_NAME"
      log "Updating ~/.gitconfig with user.email = $GIT_COMMITTER_EMAIL"
      $IDE_PATH/bin/git config -f $HOME/.gitconfig --replace-all user.email "$GIT_COMMITTER_EMAIL"
      busybox chown $IDE_USER:$IDE_USER $HOME/.gitconfig
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
   dropbear -RE -p 127.0.0.1:$DROPBEAR_PORT -r $HOSTDATA_PATH/ed25519_host_key >$LOG_PATH/dropbear.log 2>&1

   log "(2/2) Launching wstunnel on port 2222"
   wstunnel --server ws://0.0.0.0:2222 --restrictTo=127.0.0.1:$DROPBEAR_PORT >$LOG_PATH/wstunnel.log 2>&1 &
}

create_git_repo() {
   [ -n "$GIT_URL" ] || return 0

   log "- Running: git clone $GIT_URL"
   # Detect clone failure explicitly: without this the function returned the
   # status of the trailing gitconfig block, so a failed clone went unnoticed and
   # the caller went on to touch .git-repo-ready over an absent repository.
   if ! GIT_SSH_COMMAND="$IDE_PATH/bin/ssh -o StrictHostKeyChecking=accept-new" git clone "$GIT_URL"; then
      log "ERROR: git clone '$GIT_URL' failed"
      return 1
   fi

   # If $GIT_URL is an https:// URI, then store sslcainfo in .gitconfig
   if echo "$GIT_URL" | grep -qE '^https?://'; then
      log "Updating ~/.gitconfig with http.sslcainfo=$IDE_PATH/certs/ca-certificates.crt"
      git config -f "$HOME/.gitconfig" --add http.sslcainfo "$IDE_PATH/certs/ca-certificates.crt"
   fi
   return 0
}

gh_authenticate() {
   if [ -f "$HOME/.config/gh/hosts.yml" ]; then
      log "Authenticated to Github already; skipping setup"
   fi

   if [ -z "$GH_TOKEN" ]; then
      log "Github authentication skipped, as no GH_TOKEN for this user"
      return
   fi

   # Avoid this issue:
   # The value of the GH_TOKEN environment variable is being used for authentication.
   # To have GitHub CLI store credentials instead, first clear the value from the environment.
   local TOKEN="$GH_TOKEN"
   unset GH_TOKEN

   log "Authenticating to Github with token '${TOKEN:0:16}' ..."
   $IDE_PATH/bin/gh auth login --with-token < <(echo "$TOKEN") || log "WARN: gh auth login failed"
}

# Returns 0 if there was nothing to do or the requested branch/PR was checked out;
# non-zero if a requested checkout failed (so the caller can abort and signal it).
checkout_git_branch_or_pr() {
   local BRANCH="${DOCKSIDE_OPTION_BRANCH:-}"
   local PR="${DOCKSIDE_OPTION_PR:-}"

   [ -n "$BRANCH" ] || [ -n "$PR" ] || return 0

   # Only act on the repo that was just cloned via GIT_URL.
   # For pre-populated images (no GIT_URL), branch/PR checkout is the
   # responsibility of the profile command, which can use {option.branch}
   # and {option.pr} placeholders or read the DOCKSIDE_OPTION_* env vars.
   [ -n "$GIT_URL" ] || return 0

   local CLONE_DIR
   CLONE_DIR=$(basename "${GIT_URL%.git}")
   local REPO="$HOME/$CLONE_DIR"

   [ -d "$REPO/.git" ] || return 0

   if [ -n "$PR" ]; then
      log "Checking out PR $PR in $REPO"
      if (cd "$REPO" && $IDE_PATH/bin/gh pr checkout "$PR"); then
         log "Checked out PR $PR via gh in $REPO"
         return 0
      fi
      log "gh pr checkout '$PR' failed, trying git fetch fallback"
      if (cd "$REPO" && git fetch origin "refs/pull/$PR/head" && git checkout FETCH_HEAD); then
         log "Checked out PR $PR via git fetch in $REPO"
         return 0
      fi
      log "WARN: PR $PR checkout failed in $REPO"
      return 1
   fi

   # Branch: fetch the named branch explicitly, then switch to it. Grouped with `if`
   # so precedence is unambiguous and — crucially — a branch that does not exist on
   # origin is a hard failure (the fetch fails) rather than `git checkout -b` silently
   # creating an empty local branch from the current HEAD.
   log "Checking out branch $BRANCH in $REPO"
   if (
      cd "$REPO" &&
      git fetch origin "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" &&
      { git switch "$BRANCH" 2>/dev/null || git switch --track -c "$BRANCH" "origin/$BRANCH"; }
   ); then
      log "Checked out branch $BRANCH in $REPO"
      return 0
   fi
   log "WARN: branch '$BRANCH' checkout failed in '$REPO' (does it exist on origin?)"
   return 1
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

populate_known_hosts() {

   if [ -f "$HOME/.ssh/known_hosts" ]; then
      log "Leaving existing ~/.ssh/known_hosts"
      return
   fi

   if [ -n "$SSH_KNOWN_HOSTS_DOMAINS" ]; then
      # Replace any ',' with spaces
      SSH_KNOWN_HOSTS_DOMAINS=$(echo $SSH_KNOWN_HOSTS_DOMAINS | tr ',' ' ')
      log "Known-hosts domains specifically requested: '$SSH_KNOWN_HOSTS_DOMAINS'"
   fi

   # Scan home folder for preexisting GIT repos and extract list of remote urls
   log "Scanning for known-hosts domains from preexisting git repos: ..."
   local SSH_KNOWN_HOSTS_REPO_DOMAINS=$(
      find $HOME -type d -name .git -exec echo "{}/config" \; | \
         xargs -I '{}' grep url '{}' | \
         sed -r 's|\s*url\s*=\s*||; /^[^@]+@/!d; s|^[^@]+@([^:/]+).*$|\1|' | \
         sort -u
   )
   log "Scan for known-hosts domains found: '$SSH_KNOWN_HOSTS_REPO_DOMAINS'"

   local SSH_KNOWN_HOSTS_DOMAINS_ALL=$(
      echo $SSH_KNOWN_HOSTS_REPO_DOMAINS $SSH_KNOWN_HOSTS_DOMAINS | \
      tr ' ' '\012' | \
      sort -u
   )

   if [ -n "$SSH_KNOWN_HOSTS_DOMAINS_ALL" ]; then
      log "- Running: IDE_PATH/bin/ssh-keyscan $SSH_KNOWN_HOSTS_DOMAINS_ALL >>$HOME/.ssh/known_hosts"
      $IDE_PATH/bin/ssh-keyscan $SSH_KNOWN_HOSTS_DOMAINS_ALL >>$HOME/.ssh/known_hosts
   fi

}

populate_ssh_agent_keys() {
   # SSH_AGENT_KEYS is a JSON object mapping keypair name -> { public, private }.
   # Add every keypair's private key to the ssh-agent, each via a transient key file
   # that is removed immediately after ssh-add (keys live only in the agent, not on disk).
   local names
   names=$(echo "$SSH_AGENT_KEYS" | jq -r 'if type == "object" then keys[] else empty end' 2>/dev/null)

   if [ -z "$names" ]; then
      log "SSH_AGENT_KEYS has no keypairs; not adding any keys to the ssh-agent"
      return
   fi

   mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

   # Defence-in-depth secret cleanup: each keypair is written to a transient
   # dockside.XXXXXX file (and .pub) only long enough to ssh-add it, then removed
   # in-loop below. A termination signal arriving inside that window would otherwise
   # strand private-key material on disk, so sweep every transient file (all share the
   # dockside. prefix) on the common signals and then exit. The trap is cleared once
   # the keys are loaded so it does not alter the later IDE-supervision phase.
   trap 'rm -f "$HOME"/.ssh/dockside.* 2>/dev/null; exit 1' INT TERM HUP

   # Iterate via read (never unquoted) since a keypair name may be '*'. Feed the
   # loop with process substitution rather than a pipe so it runs in THIS shell and
   # the add_failures counter survives the loop (a piped 'while' runs in a subshell,
   # discarding any variable it sets).
   local name KEY_PRIVATE KEY_PUBLIC KEY_PATH
   local add_failures=0
   while IFS= read -r name; do
      [ -n "$name" ] || continue

      KEY_PRIVATE=$(echo "$SSH_AGENT_KEYS" | jq -r --arg n "$name" '.[$n].private // empty')
      KEY_PUBLIC=$(echo "$SSH_AGENT_KEYS" | jq -r --arg n "$name" '.[$n].public // empty')

      if [ -z "$KEY_PRIVATE" ] || [ -z "$KEY_PUBLIC" ]; then
         log "Keypair '$name' has no public/private material; skipping"
         continue
      fi

      # Log the public key only (it identifies the keypair); never log private
      # material, not even a prefix — the launch log is not a secret store.
      log "SSH_AGENT_KEYS[$name](PUBLIC)=$KEY_PUBLIC"

      KEY_PATH=$(busybox mktemp "$HOME/.ssh/dockside.XXXXXX")
      echo "$KEY_PRIVATE" > "$KEY_PATH"
      echo "$KEY_PUBLIC" > "$KEY_PATH.pub"
      chmod 400 "$KEY_PATH" "$KEY_PATH.pub"

      log "Adding keypair '$name' to ssh-agent ..."
      # Capture ssh-add's own status: without the 'if' the iteration's exit status
      # would be the trailing rm, masking an ssh-add failure — and the final
      # 'ssh-add -L' below succeeds whenever ANY key is loaded, so one failed key
      # would otherwise go completely unnoticed.
      if ! "$IDE_PATH/bin/ssh-add" "$KEY_PATH"; then
         log "ERROR: ssh-add failed for keypair '$name'"
         add_failures=$((add_failures + 1))
      fi

      rm -f "$KEY_PATH" "$KEY_PATH.pub"
   done < <(echo "$names")

   # Final sweep catches any transient file stranded by a non-signal failure inside
   # the loop (where the per-iteration rm above would not have run), then disarm.
   rm -f "$HOME"/.ssh/dockside.* 2>/dev/null
   trap - INT TERM HUP

   "$IDE_PATH/bin/ssh-add" -L

   if [ "$add_failures" -gt 0 ]; then
      log "ERROR: $add_failures ssh-agent keypair(s) failed to load"
      return 1
   fi
   return 0
}

find_files_of_type() {
   find $HOME/* -type d -name "node_modules" -prune -o -type f "$@" -print -quit | grep -q .
}

find_files_having() {
   local grep="$1"

   find "$HOME" -type d -name "node_modules" -o -name ".*" -prune -o -type f -exec head -n 1 {} \; 2>/dev/null | $IDE_PATH/bin/busybox grep -qE '^#!.*('$grep')'
}

# Populate ~/.vscode/extensions.json:
# - Only alter an existing file when extensions are explicit providedly or auto-detect is explicitly requested.
# - Always autodetect when no existing file found.
# Inputs:
# - DEVCONTAINER_VSCODE_EXTENSIONS: JSON e.g. { "extensions": [ "ms-python.python", "ms-toolsai.jupyter" ] }
# - DEVCONTAINER_VSCODE_UNWANTED_EXTENSIONS: JSON (same object)
# - DEVCONTAINER_VSCODE_EXTENSIONS_AUTODETECT: 0 (false) or 1 (true)
populate_vscode_extensions() {
   local DIR="$HOME/.vscode"
   local FILE="$DIR/extensions.json"
   local NEW_FILE=0

   log "Creating $DIR ..."
   mkdir -p "$DIR"

   log "Checking for $FILE ..."

   if [ -f $FILE ]; then
      log "Prexisting '$FILE' found."
   else
      log "Prexisting '$FILE' not found, creating new."
      cat <<'_EOE_' >$FILE
{
   // See https://go.microsoft.com/fwlink/?LinkId=827846 to learn about workspace recommendations.
   // Extension identifier format: ${publisher}.${name}. Example: vscode.csharp
   // List of extensions which should be recommended for users of this workspace.
   "recommendations": [],
   // List of extensions that should not be recommended for users of this workspace.
   "unwantedRecommendations": []
}
_EOE_
      NEW_FILE=1
   fi

   local EXT_SET=0
   if [ -n "$DEVCONTAINER_VSCODE_EXTENSIONS" ] && [ "$DEVCONTAINER_VSCODE_EXTENSIONS" != "null" ]; then
      EXT_SET=1
   fi

   local UNWANTED_SET=0
   if [ -n "$DEVCONTAINER_VSCODE_UNWANTED_EXTENSIONS" ] && [ "$DEVCONTAINER_VSCODE_UNWANTED_EXTENSIONS" != "null" ]; then
      UNWANTED_SET=1
   fi

   local AUTODETECT_ENABLED=0
   if [ "$NEW_FILE" -eq 1 ]; then
      if [ "${DEVCONTAINER_VSCODE_EXTENSIONS_AUTODETECT:-}" != "0" ]; then
         AUTODETECT_ENABLED=1
      fi
   else
      if [ "${DEVCONTAINER_VSCODE_EXTENSIONS_AUTODETECT:-}" = "1" ]; then
         AUTODETECT_ENABLED=1
      fi
   fi

   local SHOULD_MODIFY=0
   if [ "$NEW_FILE" -eq 1 ] || [ "$EXT_SET" -eq 1 ] || [ "$UNWANTED_SET" -eq 1 ] || [ "$AUTODETECT_ENABLED" -eq 1 ]; then
      SHOULD_MODIFY=1
   fi

   if [ "$SHOULD_MODIFY" -ne 1 ]; then
      log "Leaving '$FILE' unchanged."
      return
   fi

   local WORKFILE
   WORKFILE=$(mktemp)
   if ! grep -v '//.*$' "$FILE" >"$WORKFILE"; then
      : >"$WORKFILE"
   fi

   if [ ! -s "$WORKFILE" ]; then
      echo '{"recommendations":[],"unwantedRecommendations":[]}' >"$WORKFILE"
   fi

   local UPDATED=0

   if [ "$EXT_SET" -eq 1 ]; then
      log "Adding recommended extensions from DEVCONTAINER_VSCODE_EXTENSIONS"
      local USER_RECS
      USER_RECS=$(echo "$DEVCONTAINER_VSCODE_EXTENSIONS" | jq -ce '.extensions // []') || USER_RECS='[]'
      if jq --argjson user_recs "$USER_RECS" '.recommendations = ((.recommendations // []) + $user_recs | unique)' "$WORKFILE" >"$WORKFILE.new"; then
         mv "$WORKFILE.new" "$WORKFILE"
         UPDATED=1
      fi
   fi

   if [ "$UNWANTED_SET" -eq 1 ]; then
      log "Adding unwanted extensions from DEVCONTAINER_VSCODE_UNWANTED_EXTENSIONS"
      local USER_UNWANTED
      USER_UNWANTED=$(echo "$DEVCONTAINER_VSCODE_UNWANTED_EXTENSIONS" | jq -ce '.extensions // []') || USER_UNWANTED='[]'
      if jq --argjson user_unwanted "$USER_UNWANTED" '.unwantedRecommendations = ((.unwantedRecommendations // []) + $user_unwanted | unique)' "$WORKFILE" >"$WORKFILE.new"; then
         mv "$WORKFILE.new" "$WORKFILE"
         UPDATED=1
      fi
   fi

   if [ "$AUTODETECT_ENABLED" -eq 1 ]; then
      log "Auto-detecting extensions for '$FILE' ..."
   else
      log "Skipping auto-detection of extensions, since DEVCONTAINER_VSCODE_EXTENSIONS_AUTODETECT='$DEVCONTAINER_VSCODE_EXTENSIONS_AUTODETECT'"
   fi

   local EXTS=""
   if [ "$AUTODETECT_ENABLED" -eq 1 ]; then
      find_files_of_type -name '*.sh' || find_files_having 'bash|sh' && EXTS="$EXTS vscode.shellscript"
      find_files_of_type -name '*.pl' -o -name '*.pm' || find_files_having 'perl' && EXTS="$EXTS vscode.perl"
      find_files_of_type -name '*.py' || find_files_having 'python' && EXTS="$EXTS vscode.python"
      find_files_of_type -name '*.css' && EXTS="$EXTS vscode.css"
      find_files_of_type -name '*.js' && EXTS="$EXTS vscode.javascript"
      find_files_of_type -name '*.json' && EXTS="$EXTS vscode.json"
      find_files_of_type -name '*.htm*' && EXTS="$EXTS vscode.html"
      find_files_of_type -name '*.json' && EXTS="$EXTS vscode.json"
      find_files_of_type -name '*.md'  && EXTS="$EXTS vscode.markdown"
      find_files_of_type -regex '.*\.ya*ml' && EXTS="$EXTS vscode.yaml"
      find_files_of_type -name 'Dockerfile' && EXTS="$EXTS vscode.docker"
      find_files_of_type -name '*.rb'  && EXTS="$EXTS vscode.ruby"
      find_files_of_type -name '*.java'  && EXTS="$EXTS vscode.java"
      find_files_of_type -name '*.php*'  && EXTS="$EXTS vscode.php"
      find_files_of_type -name '*.ts'  && EXTS="$EXTS vscode.typescript"
      find_files_of_type -name '*.go'  && EXTS="$EXTS vscode.go"
   fi

   if [ "$AUTODETECT_ENABLED" -eq 1 ] && [ -n "$EXTS" ]; then
      log "Populating $FILE with (in JSON): $EXTS"
      if jq --argjson new_items "$(echo "$EXTS" | jq -R 'split(" ") | map(select(. != ""))')" '.recommendations = ((.recommendations // []) + $new_items | unique)' "$WORKFILE" >"$WORKFILE.new"; then
         mv "$WORKFILE.new" "$WORKFILE"
         UPDATED=1
      fi
   fi

   if [ "$UPDATED" -eq 1 ]; then
      mv "$WORKFILE" "$FILE"
   else
      rm -f "$WORKFILE"
   fi
}

populate_vscode_settings() {
   local DIR="$HOME/.vscode"
   local FILE="$DIR/settings.json"

   log "Creating $DIR ..."
   mkdir -p "$DIR"

   log "Checking for settings.json file '$FILE' ..."
   if [ -f $FILE ]; then
      log "Found prexisting file '$FILE'."
   else
      log "Creating empty file '$FILE'."
      echo '{}' >$FILE
   fi

   local EXCLUDES='**/.vscode **/.vscode-server **/.openvscode-server **/.theia **/.cache **/.ssh **/.git'
   if [ -n "$EXCLUDES" ]; then
      log "Populating '$FILE' with 'files.exclude' exclusions (in JSON): $EXCLUDES"

      jq --argjson new_items "$(echo "$EXCLUDES" | jq -R 'split(" ") | map({(.): true}) | add')"    '."files.exclude" |= . + $new_items' "$FILE" >$FILE.new && mv $FILE.new $FILE
   fi
}

launch_nonroot() {
   log "Continuing launch as non-root user '$IDE_USER' ..."

   local HOME=$(getent passwd $IDE_USER | cut -d':' -f6)
   cd $HOME

   # Exported env vars made available to run_nonroot:
   export DEVCONTAINER_VSCODE

   # Without -l, su passes all inherited/exported env vars to the child process unchanged,
   # so only PATH and HOME need to be stated here as they require new values for $IDE_USER.
   $IDE_PATH/bin/su $IDE_USER -c "env PATH=\"$_PATH\" HOME=\"$HOME\" $DOCKSIDE_ROOT/launch.sh run_nonroot"
}

launch_theia() {
   # Resolve IIDE_PATH:
   # - use IDE if provided and exists; else
   # - use the 'current' or 'latest' symlink (if they resolve to a directory), in that order; else
   # - try and find a suitable subdir
   if [ -n "$IDE" ] && [ -d "$DOCKSIDE_ROOT/ide/$IDE" ]; then
      IIDE_PATH="$DOCKSIDE_ROOT/ide/$IDE"
   elif [ -d "$DOCKSIDE_ROOT/ide/theia/current" ]; then
      IIDE_PATH="$DOCKSIDE_ROOT/ide/theia/current"
   elif [ -d "$DOCKSIDE_ROOT/ide/theia/latest" ]; then
      IIDE_PATH="$DOCKSIDE_ROOT/ide/theia/latest"
   else
      # Fallback: look for the alphanumerically-latest subdirectory of /opt/dockside/ide/theia
      # N.B. Assumes `find`, `sort` and `head` in the PATH
      IIDE_PATH="$(find $DOCKSIDE_ROOT/ide/theia/  -mindepth 1 -maxdepth 1 -type d | sort -r | head -1)"
   fi

   # Remove dependency on symlink going forwards
   IIDE_PATH="$(readlink -f "$IIDE_PATH")"

   # WARNING: DON'T BACKGROUND THESE WHILE LOOPS, OR SYSBOX RUNTIME WILL FAIL TO RUN CORRECTLY.
   while true
   do

      log "Launching and supervising the Theia IDE at $IDE_PATH"

      if [ $(id -u) -eq 0 ] && [ "$IDE_USER" != "root" ]; then
         # Without -l, su passes all inherited/exported env vars through; env -i clears them
         # so only the vars the IDE launcher needs are explicitly stated.
         $IDE_PATH/bin/su $IDE_USER -c "env -i PATH=\"$_PATH\" HOME=\"$(getent passwd $IDE_USER | cut -d':' -f6)\" USER=\"$IDE_USER\" IDE_PATH=\"$IDE_PATH\" IDE=\"$IDE\" IIDE_PATH=\"$IIDE_PATH\" LOG_PATH=\"$LOG_PATH\" $IDE_PATH/bin/sh $IIDE_PATH/bin/launch-ide.sh"
      else
         env -i PATH="$_PATH" HOME="$HOME" USER="$USER" IDE_PATH="$IDE_PATH" IDE="$IDE" IIDE_PATH="$IIDE_PATH" LOG_PATH="$LOG_PATH" SSH_AUTH_SOCK="$SSH_AUTH_SOCK" $IDE_PATH/bin/sh $IIDE_PATH/bin/launch-ide.sh
      fi

      sleep 1
   done   
}

launch_openvscode() {
   # Resolve IIDE_PATH:
   # - use IDE if provided and exists; else
   # - use the 'current' or 'latest' symlink if they resolve to a directory), in that order; else
   # - try and find a suitable subdir.
   if [ -n "$IDE" ] && [ -d "$DOCKSIDE_ROOT/ide/$IDE" ]; then
      IIDE_PATH="$DOCKSIDE_ROOT/ide/$IDE"
   elif [ -d "$DOCKSIDE_ROOT/ide/openvscode/current" ]; then
      IIDE_PATH="$DOCKSIDE_ROOT/ide/openvscode/current"
   elif [ -d "$DOCKSIDE_ROOT/ide/openvscode/latest" ]; then
      IIDE_PATH="$DOCKSIDE_ROOT/ide/openvscode/latest"
   else
      # Fallback: look for the alphanumerically-latest subdirectory of /opt/dockside/ide/openvscode
      # N.B. Assumes `find`, `sort` and `head` in the PATH
      IIDE_PATH="$(find $DOCKSIDE_ROOT/ide/openvscode/  -mindepth 1 -maxdepth 1 -type d | sort -r | head -1)"
   fi

   # Remove dependency on symlink going forwards
   IIDE_PATH="$(readlink -f "$IIDE_PATH")"

   # WARNING: DON'T BACKGROUND THESE WHILE LOOPS, OR SYSBOX RUNTIME WILL FAIL TO RUN CORRECTLY.
   while true
   do

      log "Launching and supervising the openvscode IDE at $IIDE_PATH"

      if [ $(id -u) -eq 0 ] && [ "$IDE_USER" != "root" ]; then
         # Without -l, su passes all inherited/exported env vars through; env -i clears them
         # so only the vars the IDE launcher needs are explicitly stated.
         $IDE_PATH/bin/su $IDE_USER -c "env -i PATH=\"$_PATH\" HOME=\"$(getent passwd $IDE_USER | cut -d':' -f6)\" USER=\"$IDE_USER\" IDE_PATH=\"$IDE_PATH\" IDE=\"$IDE\" IIDE_PATH=\"$IIDE_PATH\" LOG_PATH=\"$LOG_PATH\" $IDE_PATH/bin/sh $IIDE_PATH/bin/launch-ide.sh"
      else
         env -i PATH="$_PATH" HOME="$HOME" USER="$USER" IDE_PATH="$IDE_PATH" IDE="$IDE" IIDE_PATH="$IIDE_PATH" LOG_PATH="$LOG_PATH" SSH_AUTH_SOCK="$SSH_AUTH_SOCK" $IDE_PATH/bin/sh $IIDE_PATH/bin/launch-ide.sh
      fi

      sleep 1
   done
}

# Record a launch-time warning for the user: log it AND append to the per-launch
# status file under $LOG_PATH, which the user's interactive shells print on login
# (see install_launch_status_notice), so launch problems surface in the
# Theia/openvscode/SSH terminal rather than only in the launch log.
dockside_user_warning() {
   log "WARNING: $*"
   echo "DOCKSIDE WARNING: $*" >> "$LOG_PATH/launch-status.txt" 2>/dev/null || true
}

# Idempotently add a snippet to the user's shell rc files that prints any launch
# warnings. Covers bash (~/.bashrc) and POSIX/ash/dash login shells (~/.profile),
# guarded by a marker so relaunches do not duplicate it. run_nonroot runs as
# $IDE_USER (invoked via su), so the rc files are created/owned by the user.
install_launch_status_notice() {
   local marker='# dockside-launch-status'
   local line="[ -f \"$LOG_PATH/launch-status.txt\" ] && cat \"$LOG_PATH/launch-status.txt\""
   local rc
   # Shell coverage: ~/.bashrc for interactive bash (Theia/openvscode terminals);
   # ~/.profile for login sh/dash/ash (and bash login when there is no ~/.bash_profile).
   # Only touch rc files that already exist — don't create dotfiles the image/user did
   # not set up (a lone created ~/.bashrc may not even be sourced), and don't grep a file
   # that isn't there. The snippet is POSIX, so it is safe in any of these shells.
   for rc in "$HOME/.bashrc" "$HOME/.profile"; do
      [ -f "$rc" ] || continue
      grep -qF "$marker" "$rc" 2>/dev/null && continue
      printf '\n%s\n%s\n' "$marker" "$line" >> "$rc" 2>/dev/null || true
   done
}

run_nonroot() {
   log "User account launch started ..."
   # Surface launch-time warnings to the user's interactive shells: clear any stale
   # warnings from a previous launch, then ensure the rc snippet is installed.
   rm -f "$LOG_PATH/launch-status.txt" 2>/dev/null
   install_launch_status_notice
   spawn_ssh_agent
   # A failed key load is non-fatal (the IDE still launches), but no longer silent:
   # populate_ssh_agent_keys logs + returns non-zero, and we surface it to the user.
   if ! populate_ssh_agent_keys; then
      dockside_user_warning "One or more SSH keys could not be loaded into the ssh-agent (see $LOG)."
   fi
   populate_known_hosts
   (
      log "Repo setup subproc started ..."
      # A failed clone is a hard error: there is no repository to set up, so abort
      # before any sentinel is written (checkout_git_branch_or_pr would otherwise
      # return 0 on the absent repo and let .git-repo-ready be touched anyway).
      if ! create_git_repo; then
         dockside_user_warning "Git clone of '$GIT_URL' failed; the repository was not set up (see $LOG)."
         touch "$LOG_PATH/.git-repo-failed"
         exit 1
      fi
      gh_authenticate
      # A requested branch/PR checkout failure is a hard error: abort the rest of repo
      # setup, log it, and write .git-repo-failed instead of the success sentinel so a
      # consumer can detect it immediately rather than waiting for a timeout.
      #
      # On success (or when no branch/PR was requested), write .git-repo-ready. With a
      # hard clone failure now handled above, this signals that a GIT_URL clone
      # succeeded and any requested branch/PR was checked out; it does NOT wait for the
      # later VS Code population, and Dockside does not guarantee an otherwise error-free
      # working tree, so .git-repo-ready is gated on a non-empty GIT_URL and its sole
      # consumer (t/integration/tests/06_git_profile.py) still verifies the repo state.
      if checkout_git_branch_or_pr; then
         [ -n "$GIT_URL" ] && touch "$LOG_PATH/.git-repo-ready"
      else
         dockside_user_warning "Checkout of the requested branch/PR failed; the repository may be on the wrong ref (see $LOG)."
         touch "$LOG_PATH/.git-repo-failed"
         exit 1
      fi
      populate_vscode_extensions;
      populate_vscode_settings
      log "Repo setup subproc finished";
   ) &
   restart_ide
   log "User account launch finished."
}

restart_ide() {
   # TODO: Kill existing IDE...

   # Match IDE strings of form openvscode/<version> or <theia>/<version>
   # where <version> is a specific version string or the string 'latest'
   case "$IDE" in
      openvscode/*)
         launch_openvscode
         ;;
      theia/*)
         launch_theia
         ;;
      *)
         launch_theia
         ;;
   esac
}

launch_ide() {
   log "Launch started ..."
   create_user
   create_git_config
   update_ssh_authorized_keys
   launch_sshd
   launch_nonroot
   log "Launch finished."
}

init() {
   # Use IDE_PATH, if provided and it exists; if not, use the 'current' or 'latest' symlink
   # Resolve IDE_PATH:
   # - use IDE_PATH if provided and exists; else
   # - use the 'current' or 'latest' symlink (if they resolve to a directory), in that order; else
   # - try and find a suitable subdir.
   if [ -z "$IDE_PATH" ] || [ -d "$IDE_PATH" ]; then
      if [ -d "$DOCKSIDE_ROOT/system/current" ]; then
        IDE_PATH="$DOCKSIDE_ROOT/system/current"
      elif [ -d "$DOCKSIDE_ROOT/system/latest" ]; then
        IDE_PATH="$DOCKSIDE_ROOT/system/latest"
      else
         # Fallback: look for the alphanumerically-latest subdirectory of /opt/dockside/system
         # N.B. Assumes `find`, `sort` and `head` in the original non-Dockside PATH
         IDE_PATH="$(find $DOCKSIDE_ROOT/system/ -mindepth 1 -maxdepth 1 -type d | sort -r | head -1)"
      fi
   fi

   # Save PATH
   export _PATH="$PATH"
   PATH="$IDE_PATH/bin:$_PATH"

   # Remove dependency on symlink going forwards and reset PATH
   IDE_PATH="$(readlink -f "$IDE_PATH")"
   PATH="$IDE_PATH/bin:$_PATH"

   # Set default IDE_USER
   [ -n "$IDE_USER" ] || IDE_USER="root"

   LOG_PATH=/tmp/dockside
   LOG=$LOG_PATH/launch-$(id -u).log

   [ -d $LOG_PATH ] || busybox mkdir -p $LOG_PATH && busybox chmod a+rwx,+t $LOG_PATH 2>/dev/null
   [ -d $LOG ] || busybox touch $LOG && busybox chmod 644 $LOG

   exec 1>>$LOG
   exec 2>>$LOG

   log "Executing '$*' with:"
   log "- PATH=$PATH"
   log "- IDE_USER=$IDE_USER"
   log "- IDE_PATH=$IDE_PATH"
   if [ -n "$DEBUG" ]; then
      log "- Environment:"
      busybox env | busybox sed 's/^/=> /'}
   fi
}

[ "$1" = "nop" ] && shift || init "$@"
eval "$@"

