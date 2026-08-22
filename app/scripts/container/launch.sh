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
   # fd 2 is always whatever this invocation's real stderr is - the docker-exec stream a
   # caller (docker-event-daemon, or a synchronous `dockside hook run`) is capturing, or
   # simply discarded for a Detach:true dispatch (launch_ide) with nobody reading it. fd 5
   # is the dedicated, always-open handle onto this devtainer's own $LOG (see init()'s own
   # comment) - so every log() line reaches both the caller-visible stream and the
   # in-container trace, with no per-entry-point plumbing needed on either side.
   echo "$S$1" >&2
   echo "$S$1" >&5
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
   [ -x "$(which dropbear)" ] && [ -x "$(which dropbearkey)" ] && [ -x "$(which wstunnel-v6 2>/dev/null)" ] || return

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

   log "(2/2) Launching wstunnel v6 on port 2222"
   wstunnel-v6 --server ws://0.0.0.0:2222 --restrictTo=127.0.0.1:$DROPBEAR_PORT >$LOG_PATH/wstunnel-v6.log 2>&1 &

   if [ -x "$(which wstunnel 2>/dev/null)" ]; then
      log "(3/3) Launching wstunnel v10 on port 2223"
      wstunnel server ws://0.0.0.0:2223 --restrict-to=127.0.0.1:$DROPBEAR_PORT --log-lvl=info >$LOG_PATH/wstunnel.log 2>&1 &
   fi
}

# Returns 0 if a fresh clone just succeeded, 1 if the clone failed, 2 if the repo
# already existed (a restart) and the clone was skipped. The caller uses this to
# decide whether to run checkout_git_ref at all: DOCKSIDE_OPTION_REF is fixed at
# reservation-creation time and can never change, so that checkout should only
# ever run once, right after a genuine fresh clone - re-running it on every
# restart has nothing new to do, and would fail loudly (by design, to protect
# local work) on every single restart from then on if local history has since
# diverged from origin, not just once.
create_git_repo() {
   [ -n "$GIT_URL" ] || return 0

   local CLONE_DIR
   CLONE_DIR=$(basename "${GIT_URL%.git}")
   if [ -d "$HOME/$CLONE_DIR/.git" ]; then
      log "Repo '$HOME/$CLONE_DIR' already exists; skipping clone (already set up by an earlier launch)"
      return 2
   fi

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

   log "Authenticating to Github with token '${TOKEN:0:16}' ..."
   # Run in a subshell so `unset` (needed to stop `gh` warning that GH_TOKEN itself
   # is what's authenticating, instead of storing credentials) only strips GH_TOKEN
   # from this subshell's own copy of the environment, not from run_prep_nonroot's
   # own shell that calls this function - defensive scoping for whatever else might
   # run later in that shell, even though nothing currently does (the lifecycle
   # hooks that used to run in this same shell/subshell are now their own
   # independent execs, each with GH_TOKEN freshly injected via _hook_env).
   ( unset GH_TOKEN; $IDE_PATH/bin/gh auth login --with-token < <(echo "$TOKEN") ) || log "WARN: gh auth login failed"
}

# Given a URL path remainder after "/tree/" or "/commits/" of a GitHub URL (which may
# contain slashes, since GitHub branch names can too), find the longest prefix that is
# an actual branch on $1 (a local repo path)'s 'origin', by trying progressively
# shorter prefixes of $2 - the common case (no subpath in the URL) matches immediately
# on the first, full-remainder try. Echoes the resolved branch name and returns 0 on a
# match; returns 1 (no output) if nothing matched, in which case the caller falls back
# to treating the whole remainder as the branch name - the subsequent git fetch then
# fails loudly if that's genuinely wrong, same as an invalid bare branch name today. (A
# ls-remote failure for network/auth reasons rather than "no such branch" also falls
# through to that same fetch-fails-loudly path, just one step later.)
#
# This longest-prefix-first search is not just a heuristic: git's own ref namespace is
# hierarchical, so "feature" and "feature/foo" can never both exist as branches at once
# (creating one when the other exists is a git error) - there is exactly one real branch
# any given remainder could resolve to, and trying the fullest candidate first finds it
# without ever needing to backtrack past a false shorter match.
resolve_tree_branch() {
   local REPO="$1"
   local CANDIDATE="$2"
   while [ -n "$CANDIDATE" ]; do
      if git -C "$REPO" ls-remote --exit-code origin "refs/heads/$CANDIDATE" >/dev/null 2>&1; then
         echo "$CANDIDATE"
         return 0
      fi
      case "$CANDIDATE" in
         */*) CANDIDATE="${CANDIDATE%/*}" ;;
         *) return 1 ;;
      esac
   done
   return 1
}

# Returns 0 if there was nothing to do or the requested ref was checked out;
# non-zero if a requested checkout failed (so the caller can abort and signal it).
checkout_git_ref() {
   local REF="${DOCKSIDE_OPTION_REF:-}"

   # Legacy back-compat: no real profile declares the old separate 'branch'/'pr' options any
   # more (this branch's own example profiles are all migrated to the unified 'ref'), but
   # retaining this is cheap. PR takes precedence over BRANCH if somehow both are set, matching
   # the original pre-'ref' checkout_git_branch_or_pr()'s own precedence. Fed into the same
   # $REF disambiguation below exactly as if it had been typed directly into 'ref' - always
   # correct for a PR number (never ambiguous with a branch name), and for the overwhelming
   # majority of branch names; a purely-numeric legacy BRANCH value is the one case this
   # heuristic would (mis)treat as a PR number, unlike the old dedicated-field behaviour, which
   # never drew that distinction - accepted given no real profile still uses these fields.
   [ -n "$REF" ] || REF="${DOCKSIDE_OPTION_PR:-${DOCKSIDE_OPTION_BRANCH:-}}"

   [ -n "$REF" ] || return 0

   # Only act on the repo that was just cloned via GIT_URL.
   # For pre-populated images (no GIT_URL), ref checkout is the
   # responsibility of the profile command, which can use {option.ref}
   # placeholders or read the DOCKSIDE_OPTION_REF env var directly.
   #
   # Deliberately not extended to also act on a pre-existing repo when GIT_URL is
   # unset: a repo an application's own entrypoint is already using (or about to
   # use) could be mid-switch from underneath it if this ran too, leaving the
   # working tree in an indeterminate state. Use one of the entrypoint/hook
   # patterns in docs/extensions/lifecycle-hooks.md instead, where the
   # application itself is in control of when the switch happens.
   [ -n "$GIT_URL" ] || return 0

   local CLONE_DIR
   CLONE_DIR=$(basename "${GIT_URL%.git}")
   local REPO="$HOME/$CLONE_DIR"

   [ -d "$REPO/.git" ] || return 0

   # A single 'ref' option covers several forms: a bare branch name; a bare PR number
   # (optionally '#'-prefixed, e.g. "42" or "#42"); or a full GitHub URL copied from the
   # browser - https://github.com/<org>/<repo>/pull/<n> (unambiguous: the PR number is
   # extracted directly) or https://github.com/<org>/<repo>/tree/<branch> (potentially
   # ambiguous if <branch> contains a slash, resolved via resolve_tree_branch() above by
   # checking progressively shorter prefixes against the actual repo). Anchored to
   # 'https://github.com/' so a literal branch name that happens to contain '/pull/' or
   # '/tree/' as a substring isn't misread as a URL.
   local PR="" BRANCH=""
   case "$REF" in
      https://github.com/*/pull/*)
         PR=${REF#*/pull/}
         PR=${PR%%[/?#]*}
         ;;
      https://github.com/*/tree/*)
         local CANDIDATE=${REF#*/tree/}
         CANDIDATE=${CANDIDATE%%[?#]*}
         BRANCH=$(resolve_tree_branch "$REPO" "$CANDIDATE") || BRANCH="$CANDIDATE"
         ;;
      https://github.com/*/commits/*)
         local CANDIDATE=${REF#*/commits/}
         CANDIDATE=${CANDIDATE%%[?#]*}
         BRANCH=$(resolve_tree_branch "$REPO" "$CANDIDATE") || BRANCH="$CANDIDATE"
         ;;
      *)
         local NUM="${REF#'#'}"
         case "$NUM" in
            ''|*[!0-9]*) BRANCH="$REF" ;;
            *)           PR="$NUM" ;;
         esac
         ;;
   esac

   if [ -n "$PR" ]; then
      log "Checking out PR $PR in $REPO"
      # --force: this function only ever runs once, on this devtainer's genuine first start
      # (see the DOCKSIDE_START_COUNT gate at its call site) - there is no prior local work of
      # the user's own to protect, so unconditionally resetting a pre-existing local branch of
      # this name (e.g. baked into the image) to the PR's current state, same reasoning as
      # 'git reset --hard' below for the branch path, is safe and intended. `gh`'s own docs
      # describe --force as doing exactly this.
      if (cd "$REPO" && $IDE_PATH/bin/gh pr checkout --force "$PR"); then
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
      { git switch "$BRANCH" 2>/dev/null || git switch --track -c "$BRANCH" "origin/$BRANCH"; } &&
      # A pre-existing local branch of this name (e.g. baked into the image, or left
      # over from an earlier launch) is not touched by 'switch' above - only the
      # just-fetched origin/$BRANCH ref advances. This function only ever runs once, on this
      # devtainer's genuine first start (see the DOCKSIDE_START_COUNT gate at its call site),
      # so there is no prior local work of the user's own to lose - a fresh devtainer's only
      # "local state" is whatever the image shipped with, not real work worth protecting.
      # Reset hard rather than fast-forward-only, so a pre-existing local branch of this name
      # converges unconditionally on the just-fetched origin/$BRANCH tip even if it had
      # diverged from origin (not merely fallen behind it, which --ff-only alone would still
      # have failed loudly on rather than converging) - a freshly-tracked branch is already at
      # this commit, so this is a no-op there.
      git reset --hard "origin/$BRANCH"
   ); then
      log "Checked out branch $BRANCH in $REPO"
      return 0
   fi
   log "WARN: branch '$BRANCH' checkout failed in '$REPO' (does it exist on origin?)"
   return 1
}

# Run a hook named $1, using the executable at path $2 - either the reserved lifecycle
# names 'lifecycle:launch'/'lifecycle:start' or a profile-declared custom name (an
# in-image, profile-author-trusted executable; $2 is resolved server-side per name - see
# Reservation::hook_script/_hook_env). Every invocation - auto-fired or on demand - reaches
# this the same way: its own independent `docker exec ... launch.sh run_hook <name> <script>`,
# script path passed as a plain argument (see Reservation::dispatch_hook_exec). Auto-fire
# is DED dispatching this exec itself, after launch:git (the git/ssh/gh setup phase) succeeds
# or has nothing to do - 'lifecycle:launch' only when this devtainer's DOCKSIDE_START_COUNT is
# 1, 'lifecycle:start' every launch including that one (see docker-event-daemon's own "Launch
# dispatch orchestration" section for the full dispatch DAG). This is not a special case of
# this function at all: on-demand invocation (Reservation::run_hook_manual) reaches it
# through the identical path, which is exactly what keeps a hook's own status record
# consistent regardless of how it was fired - there's only ever one recorder. Every invocation
# calls this same function, so it self-serializes per name via an mkdir-based lock: a
# concurrent second invocation of the *same* name does not block or double-run, it just reports
# "busy" (exit 2) and leaves the first run to finish undisturbed - a concurrent invocation of a
# *different* name is unaffected, since the lock and sentinels are scoped by name. Names are
# embedded raw in filenames (no sanitization needed): only '/' and NUL are unsafe in a Linux
# filename, and reserved lifecycle names' literal ':' can never collide with a custom name,
# whose slug syntax forbids colons entirely (see Profile.pm).
#
# Returns 0 on success (or when no hook is configured for this profile), 1 if the
# hook script itself failed, 2 if a run was already in progress.
run_hook() {
   local NAME="$1"
   local SCRIPT="$2"
   [ -n "$SCRIPT" ] || { log "run_hook: no hook configured"; return 0; }

   # Every invocation of this function - on demand (Reservation::run_hook_manual) or
   # auto-fired by DED (see this function's own header comment) - is its own independent
   # `docker exec`, never sharing spawn_ssh_agent's process tree, so SSH_AUTH_SOCK is never
   # inherited either way: discover Dockside's own managed agent instead (see
   # find_ssh_auth_sock below). ssh_auth_sock_is_live still short-circuits this to a no-op
   # on the rare chance SSH_AUTH_SOCK already arrived live some other way, but neither path
   # can rely on that.
   if ! ssh_auth_sock_is_live "$SSH_AUTH_SOCK"; then
      SSH_AUTH_SOCK=$(find_ssh_auth_sock) && export SSH_AUTH_SOCK
   fi

   if [ ! -x "$SCRIPT" ]; then
      log "run_hook: ERROR: '$SCRIPT' not found or not executable"
      dockside_user_warning "Hook '$NAME' is not configured correctly ('$SCRIPT' not found or not executable); see $LOG."
      rm -f "$LOG_PATH/.hook-ready.$NAME"
      touch "$LOG_PATH/.hook-failed.$NAME"
      return 1
   fi

   local LOCK="$LOG_PATH/.hook.lock.d.$NAME"
   if ! mkdir "$LOCK" 2>/dev/null; then
      local OLD_PID
      OLD_PID=$(cat "$LOCK/pid" 2>/dev/null)
      if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
         log "run_hook: '$NAME' already running (pid $OLD_PID); refusing concurrent run"
         return 2
      fi
      log "run_hook: found stale lock for '$NAME' (pid $OLD_PID not running); reclaiming"
      rm -rf "$LOCK"
      mkdir "$LOCK" 2>/dev/null || { log "run_hook: ERROR: could not acquire lock for '$NAME'"; return 2; }
   fi
   # $$ is unreliable here: this shell keeps $$ pinned to the top-level process's
   # PID even inside a `( … ) &` subshell, so it doesn't identify whichever process
   # is actually running this hook. Read /proc/self/stat via the `read` builtin
   # instead (no fork happens - unlike any external command, which would just
   # report its own unrelated PID) to reliably capture the real PID of the calling
   # process, whether that's a top-level invocation or a subshell.
   local REAL_PID
   read -r REAL_PID _ < /proc/self/stat
   echo "$REAL_PID" > "$LOCK/pid"
   rm -f "$LOG_PATH/.hook-ready.$NAME" "$LOG_PATH/.hook-failed.$NAME"

   log "run_hook: running '$NAME' ($SCRIPT) ..."
   # The hook script's own stdout/stderr need no explicit routing any more: fd 1/2 already
   # ARE the real caller-visible stream (see init()'s own comment), so a synchronous caller
   # (Reservation::run_hook_manual) or DED's dispatch_hook_exec sees it directly, and log()
   # calls made by this function itself now reach that same stream too (not just $LOG) - so
   # a pre-flight failure below (script missing, hook already running) is visible to whoever
   # dispatched this invocation, not just discoverable via $LOG inside the container.
   if "$SCRIPT"; then
      log "run_hook: '$NAME' ($SCRIPT) succeeded"
      touch "$LOG_PATH/.hook-ready.$NAME"
      rm -rf "$LOCK"
      return 0
   else
      local rc=$?
      log "run_hook: '$NAME' ($SCRIPT) failed with exit code $rc"
      dockside_user_warning "Hook '$NAME' failed (exit $rc); see $LOG."
      touch "$LOG_PATH/.hook-failed.$NAME"
      rm -rf "$LOCK"
      return 1
   fi
}

spawn_ssh_agent() {
   log "Checking for ssh-agent ..."
   if [ -x $(which ssh-agent) ] && ! pgrep ssh-agent >/dev/null; then
      log "Found ssh-agent binary but no running agent, so launching it ..."

      # Let ssh-agent choose its own socket path (no -a) - a container restart tears
      # down every process inside it, ssh-agent included, so pgrep above correctly
      # finds nothing and a fresh agent with a fresh socket spawns every time; there
      # is no "later independent invocation" that needs to guess this one's path in
      # advance. A separate `docker exec ... launch.sh run_hook` (run_hook_manual) is
      # exactly such an independent invocation, but it discovers the socket instead
      # of relying on a fixed path - see find_ssh_auth_sock() below - which also
      # avoids the security hazard a well-known, world-writable path had: any other
      # UID in the container could squat it before this agent started and harvest
      # keys via the ssh-add that follows.
      eval $($(which ssh-agent))
      export SSH_AUTH_SOCK

      log "Launched ssh-agent binary with SSH_AUTH_SOCK='$SSH_AUTH_SOCK'"
   fi
}

# Returns 0 if $1 (an SSH_AUTH_SOCK candidate path) has a live, responding ssh-agent behind it,
# checked via `ssh-add -l`'s exit code rather than the socket merely existing: 0 means it has
# keys, 1 means no keys but the agent answered (a real, live state - populate_ssh_agent_keys
# may legitimately have found no keypairs for this user), anything else (2 = could not contact
# an agent at all, e.g. a dead socket left behind by an OOM-killed process; 127 if ssh-add
# itself is missing) means not live.
ssh_auth_sock_is_live() {
   local SSH_ADD_BIN
   SSH_ADD_BIN=$(which ssh-add) || return 1
   SSH_AUTH_SOCK="$1" "$SSH_ADD_BIN" -l >/dev/null 2>&1
   case $? in
      0|1) return 0 ;;
      *)   return 1 ;;
   esac
}

# Discover a live ssh-agent socket for the current unix user, for a caller that did not itself
# spawn the agent and so has no SSH_AUTH_SOCK inherited from that process tree - every
# `docker exec ... launch.sh run_hook` invocation (see run_hook below), on demand or
# auto-fired by DED alike, since each is its own independent exec, never sharing
# spawn_ssh_agent's process tree. Also used directly by launch_git/launch_ide, for the same
# reason - neither shares launch:prep's process tree either, despite launch:prep being where
# spawn_ssh_agent actually runs.
# Scans Dockside's own managed agent's default socket naming (/tmp/ssh-*/agent.* - OpenSSH's
# own convention) newest-first by mtime, validating each candidate's liveness rather than
# trusting mtime alone. Deliberately does not scan /tmp/dropbear-*/auth-* - dropbear's own,
# separate forwarded-agent sockets, which expose whichever developer happens to be
# interactively connected right now's own local keys, not this reservation's own registered
# credentials - the wrong target for this automated, unattended case. An inner tmpfs /tmp is
# harmless here: it just means no stale sockets from a previous container run to sift through.
# Echoes the first responding socket path and returns 0; echoes nothing and returns 1 if none
# responds (e.g. no agent has ever run for this user, or none of its sockets are still live).
find_ssh_auth_sock() {
   local SOCK
   for SOCK in $(ls -dt /tmp/ssh-*/agent.* 2>/dev/null); do
      if ssh_auth_sock_is_live "$SOCK"; then
         echo "$SOCK"
         return 0
      fi
   done
   return 1
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

# Drops from root to $IDE_USER and continues launch by running $1 (default: run_prep_nonroot)
# there, via the same top-level dispatch mechanism ("launch.sh <function>") every entry point
# uses - so the su'd child gets exactly the same init() setup (LOG_PATH, PATH, its own fd 5/
# $LOG handle) a freshly-dispatched exec would, and its own log() output reaches the same
# caller-visible stream (fd 1/2, inherited straight through su/env) as the parent's, with no
# extra plumbing needed. Generalized from a single hardcoded target: what used to be
# one function, run_nonroot, was split into launch_prep's own non-root tail plus the separate
# launch_git entry point - both need this same su-transition machinery, only launch_prep's
# since launch_git is dispatched directly as the non-root user by DED, needing no su at all
# (only steps that genuinely need root - create_user, launch_sshd's dropbear - run as root at
# all; everything else drops to the non-root user as soon as it can).
launch_nonroot() {
   local FUNCTION="${1:-run_prep_nonroot}"
   log "Continuing launch as non-root user '$IDE_USER' (running '$FUNCTION') ..."

   local HOME=$(getent passwd $IDE_USER | cut -d':' -f6)
   cd $HOME

   # Exported env vars made available to the non-root function:
   export DEVCONTAINER_VSCODE

   # Without -l, su passes all inherited/exported env vars to the child process unchanged,
   # so only PATH and HOME need to be stated here as they require new values for $IDE_USER.
   $IDE_PATH/bin/su $IDE_USER -c "env PATH=\"$_PATH\" HOME=\"$HOME\" $DOCKSIDE_ROOT/bin/launch.sh $FUNCTION"
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
# guarded by a marker so relaunches do not duplicate it. run_prep_nonroot runs as
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

# The non-root tail of exec #1 (launch:prep) - ssh-agent/credentials only. Reached via
# launch_prep -> launch_nonroot's su-transition, never dispatched directly. Git repo setup and
# the lifecycle hooks that used to run inline here (in a backgrounded subshell, concurrent with
# the IDE loop below) are now launch_git and their own separately-dispatched execs
# respectively. This function no longer starts the IDE at all: that's launch:ide, dispatched
# independently by DED the moment launch:prep (this whole chain) succeeds, not sequenced behind
# git/hooks - preserving exactly the concurrency the old backgrounded-subshell-plus-inline-
# restart_ide shape gave for free.
run_prep_nonroot() {
   log "User account prep started ..."
   # Surface launch-time warnings to the user's interactive shells: clear any stale
   # warnings from a previous launch, then ensure the rc snippet is installed. Also clear
   # .credentials-ready from a previous launch here, for the same reason: /tmp survives a
   # stop/start, so a stale ready sentinel from a prior successful launch would otherwise
   # still read as "ready" the instant this launch starts - before this launch's own setup
   # has run again - masking a genuine failure on this restart.
   rm -f "$LOG_PATH/launch-status.txt" "$LOG_PATH/.credentials-ready" 2>/dev/null
   install_launch_status_notice
   spawn_ssh_agent
   # A failed key load is non-fatal (the IDE still launches), but no longer silent:
   # populate_ssh_agent_keys logs + returns non-zero, and we surface it to the user.
   if ! populate_ssh_agent_keys; then
      dockside_user_warning "One or more SSH keys could not be loaded into the ssh-agent (see $LOG)."
   fi
   populate_known_hosts
   # Authenticate gh, and signal that credentials (ssh-agent + known_hosts + gh) are
   # ready, unconditionally and before any git-repo-specific work — so this signal is
   # available regardless of whether this profile even has a GIT_URL, and is not skipped
   # when a later, independently-dispatched git clone happens to fail. This is what lets an
   # application's own entrypoint (started long before this script runs) poll for
   # "$LOG_PATH/.credentials-ready" and then use the same ssh-agent/gh auth Dockside set up
   # here, without needing to wait for or depend on git-repo setup at all.
   gh_authenticate
   touch "$LOG_PATH/.credentials-ready"
   log "User account prep finished."
}

# Exec #2 (item F's launch:git) - the optional git repo setup only, no hook invocation inside
# it at all (unlike the old run_nonroot, which fired both lifecycle hooks inline, in the same
# backgrounded subshell, right after this same git logic). Dispatched directly as the non-root
# unix user by DED (no su-transition needed, unlike launch_prep - see the root-vs-non-root
# guardrail in item F), only when the profile declares gitURLs at all. On success (or having
# nothing to do), DED dispatches lifecycle:launch/lifecycle:start as their own separate execs,
# via the ordinary run_hook entry point every on-demand invocation already uses - see item F's
# "Couplings to resolve first" for why (real per-hook status, one recorder instead of two kept
# in sync by hand).
launch_git() {
   log "Git repo setup started ..."
   # Docker's exec API 'User' field sets the euid/env correctly (proven already by every
   # on-demand hook dispatched this same way - see run_hook above) but not necessarily the
   # initial cwd the way `su -c` (used by launch_nonroot) does - be explicit rather than
   # assume, since create_git_repo's `git clone` (no explicit destination dir) depends on it.
   cd "$HOME" || { log "launch_git: ERROR: cannot cd to HOME='$HOME'"; exit 1; }

   # This exec never shares launch:prep's process tree, so SSH_AUTH_SOCK is never inherited
   # from spawn_ssh_agent there - discover Dockside's own managed agent instead, exactly as
   # run_hook does (see its own comment and find_ssh_auth_sock's header comment). Needed for
   # any SSH-based GIT_URL clone/checkout below.
   if ! ssh_auth_sock_is_live "$SSH_AUTH_SOCK"; then
      SSH_AUTH_SOCK=$(find_ssh_auth_sock) && export SSH_AUTH_SOCK
   fi

   # Clear stale sentinels from a previous launch - see run_prep_nonroot's own comment for why
   # this matters even though /tmp usually survives a stop/start.
   rm -f "$LOG_PATH/.git-repo-ready" "$LOG_PATH/.git-repo-failed" 2>/dev/null

   create_git_repo
   case $? in
      0|2)
         # Either a fresh clone just succeeded, or the repo already existed (a restart -
         # the clone was skipped) - either way, a usable repo now exists at $REPO. Whether
         # to run checkout_git_ref is decided independently of *which* of these two
         # happened, purely by DOCKSIDE_START_COUNT below: "did launch.sh's own clone just
         # run" is not the same question as "is this this devtainer's genuine first start" -
         # a profile could conceivably ship a repo already cloned/baked into the image, in
         # which case create_git_repo would report "already existed" (2) even on a true
         # first start, and a requested ref must still be honoured then. DOCKSIDE_OPTION_REF
         # is frozen at reservation-creation time and can never change, so there is no
         # legitimate reason to run checkout_git_ref on any later start regardless.
         if [ "$DOCKSIDE_START_COUNT" = "1" ]; then
            # A requested ref checkout failure is a hard error: abort the rest of repo
            # setup, log it, and write .git-repo-failed instead of the success sentinel so a
            # consumer can detect it immediately rather than waiting for a timeout.
            #
            # On success (or when no ref was requested), write .git-repo-ready. With a
            # hard clone failure now handled above, this signals that a GIT_URL clone
            # succeeded and any requested ref was checked out; it does NOT wait for the
            # later VS Code population, and Dockside does not guarantee an otherwise error-free
            # working tree, so .git-repo-ready is gated on a non-empty GIT_URL and its sole
            # consumer (t/integration/tests/06_git_profile.py) still verifies the repo state.
            if checkout_git_ref; then
               [ -n "$GIT_URL" ] && touch "$LOG_PATH/.git-repo-ready"
            else
               dockside_user_warning "Checkout of the requested ref failed; the repository may be on the wrong ref (see $LOG)."
               touch "$LOG_PATH/.git-repo-failed"
               exit 1
            fi
         else
            [ -n "$GIT_URL" ] && touch "$LOG_PATH/.git-repo-ready"
         fi
         ;;
      *)
         # A failed clone is a hard error: there is no repository to set up, so
         # abort before any sentinel is written (checkout_git_ref would otherwise
         # return 0 on the absent repo and let .git-repo-ready be touched anyway).
         dockside_user_warning "Git clone of '$GIT_URL' failed; the repository was not set up (see $LOG)."
         touch "$LOG_PATH/.git-repo-failed"
         exit 1
         ;;
   esac

   populate_vscode_extensions
   populate_vscode_settings
   log "Git repo setup finished."
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

# Exec #3 (item F's launch:ide) - IDE supervision only, perpetual. Dispatched independently by
# DED the moment launch:prep succeeds - not waiting on launch:git or either hook exec - which
# is what preserves the old backgrounded-subshell design's "IDE comes up while cloning
# continues" concurrency. Dispatched directly as the non-root unix user, with Detach:true (a
# hard requirement, not a convenience - see item F's Enabler section: a non-detached dispatch
# of a perpetual process would hold DED's connection open for the container's whole life).
# launch_theia/launch_openvscode already handle both "already non-root" and "still root, needs
# su" cases internally (see their own `id -u` check) - dispatching this non-root directly, as
# DED now does, simply takes their already-existing non-root branch, one layer of su removed
# from what launch_ide used to need when it ran as root.
launch_ide() {
   log "IDE launch started ..."
   cd "$HOME" || { log "launch_ide: ERROR: cannot cd to HOME='$HOME'"; exit 1; }

   # This exec never shares launch:prep's process tree, so SSH_AUTH_SOCK is never inherited
   # from spawn_ssh_agent there - discover Dockside's own managed agent instead, exactly as
   # run_hook/launch_git do. Needed before restart_ide: launch_theia/launch_openvscode's own
   # already-non-root branch explicitly passes SSH_AUTH_SOCK into the IDE launcher's env.
   if ! ssh_auth_sock_is_live "$SSH_AUTH_SOCK"; then
      SSH_AUTH_SOCK=$(find_ssh_auth_sock) && export SSH_AUTH_SOCK
   fi

   restart_ide
   log "IDE launch finished."
}

# Exec #1 (launch:prep) - core setup, nothing hook- or git-related: create_user, ssh authorized
# keys, sshd, then drops to $IDE_USER for ssh-agent/credentials via launch_nonroot's default
# target, run_prep_nonroot. Dispatched as root (the one stage that is - create_user and
# launch_sshd's dropbear genuinely need it; everything else drops to the non-root user as soon
# as it can). Deliberately does not add new fatal-on-failure checks beyond what each of these
# steps already had (e.g.
# populate_ssh_agent_keys inside run_prep_nonroot stays a non-fatal warning, exactly as
# before) - hardening individual steps' failure semantics is a separate, later decision, not
# part of this restructure; DED observes whatever real exit code this function naturally
# produces today, which is a strict improvement over no observability at all regardless.
launch_prep() {
   log "Prep launch started ..."
   create_user
   create_git_config
   update_ssh_authorized_keys
   launch_sshd
   launch_nonroot run_prep_nonroot
   log "Prep launch finished."
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

   # Dedicated, always-open fd for this devtainer's own $LOG - see log()'s own comment for
   # why this, and not redirecting fd 1/2, is the mechanism: fd 1/2 are deliberately left
   # exactly as docker_exec attached them for this invocation (whatever a caller is - or
   # isn't, for a Detach:true dispatch like launch_ide - reading), so raw (non-log()) output
   # from any command runs straight through to that caller by default, for every entry point
   # alike, with no per-function classification to keep in sync as new hook stages/dispatch
   # shapes are added elsewhere (docker-event-daemon's launch DAG, profile-declared hooks).
   # $LOG is the opt-in side instead: log()'s own lines reach it via fd 5 unconditionally;
   # a command whose own raw output is worth keeping in-container too (rare - most of what's
   # worth keeping is already narrated via log()) can redirect to it explicitly with `>&5`.
   exec 5>>$LOG

   log "Executing '$*' with:"
   log "- PATH=$PATH"
   log "- IDE_USER=$IDE_USER"
   log "- IDE_PATH=$IDE_PATH"
   if [ -n "$DEBUG" ]; then
      log "- Environment:"
      # Deliberately $LOG-only (fd 5), never the caller-visible stream: this dumps the
      # entire environment verbatim, which includes real secrets Dockside itself injects
      # into every hook/launch-stage exec (e.g. GH_TOKEN - see Reservation::_hook_env) -
      # not something to default to caller-visible just because DEBUG is on.
      busybox env | busybox sed 's/^/=> /' >&5
   fi
}

[ "$1" = "nop" ] && shift || init "$@"

# No per-function dispatch distinction needed: fd 1/2 already ARE whatever this invocation's
# real caller-visible stream is (see init()'s and log()'s own comments), for every entry
# point alike - docker-event-daemon's _launch_dispatch_exec/dispatch_hook_exec capture it
# host-side for anything non-detached, and it's simply unread for launch_ide's Detach:true
# dispatch.
eval "$@"

