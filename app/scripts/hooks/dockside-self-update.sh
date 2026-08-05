#!/bin/bash

# Profile-declared 'lifecycle:launch' hook for Dockside's own self-hosting example profiles
# (00-dockside.json, 01-dockside-own-ide.json, 91-dockside-sysbox.json,
# 92-dockside-runcvm.json). See docs/extensions/lifecycle-hooks.md.
#
# Invoked by launch.sh's run_hook() (see app/scripts/container/launch.sh), as the
# devtainer's own 'dockside' user, once launch-time git/ssh/gh setup has completed. Auto-fires
# only once, on this devtainer's genuine first start (wired to 'lifecycle:launch', not
# 'lifecycle:start' - see docs/plans/lifecycle-hooks-review-followup.md item E), and is
# separately re-invokable any time later via `dockside hook run` (this profile's hooks entry
# for it sets "manual": true). Consumes the same single 'ref' option as the 03-git-repo.json
# example profile, but - because this repo is baked into the image rather than cloned via
# gitURLs - via a hook instead of launch.sh's built-in GIT_URL-gated checkout, since switching
# Dockside's own branch also requires rebuilding the client and restarting Dockside's own
# services, not just a checkout.

set -euo pipefail

REPO="$HOME/dockside"
cd "$REPO"

REF="${DOCKSIDE_OPTION_REF:-}"

# Use the IDE-bundled git/gh binaries (consistent CA store / exec-path), falling
# back to whatever's on PATH if IDE_PATH isn't set for some reason.
GIT_BIN="${IDE_PATH:-/opt/dockside/system/latest}/bin/git"
[ -x "$GIT_BIN" ] || GIT_BIN=git
GH_BIN="${IDE_PATH:-/opt/dockside/system/latest}/bin/gh"
[ -x "$GH_BIN" ] || GH_BIN=gh

# See resolve_tree_branch() in app/scripts/container/launch.sh for the full
# rationale (identical logic, bash variant, using $GIT_BIN and the repo this
# script has already cd'd into rather than taking a repo path argument).
resolve_tree_branch() {
  local CANDIDATE="$1"
  while [ -n "$CANDIDATE" ]; do
    if "$GIT_BIN" ls-remote --exit-code origin "refs/heads/$CANDIDATE" >/dev/null 2>&1; then
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

# A single 'ref' option covers several forms: a bare branch name; a bare PR number
# (optionally '#'-prefixed); or a full GitHub URL copied from the browser - see
# checkout_git_ref() in app/scripts/container/launch.sh, which uses the same logic.
PR="" BRANCH=""
case "$REF" in
  https://github.com/*/pull/*)
    PR=${REF#*/pull/}
    PR=${PR%%[/?#]*}
    ;;
  https://github.com/*/tree/*)
    CANDIDATE=${REF#*/tree/}
    CANDIDATE=${CANDIDATE%%[?#]*}
    BRANCH=$(resolve_tree_branch "$CANDIDATE") || BRANCH="$CANDIDATE"
    ;;
  https://github.com/*/commits/*)
    CANDIDATE=${REF#*/commits/}
    CANDIDATE=${CANDIDATE%%[?#]*}
    BRANCH=$(resolve_tree_branch "$CANDIDATE") || BRANCH="$CANDIDATE"
    ;;
  *)
    NUM="${REF#'#'}"
    case "$NUM" in
      ''|*[!0-9]*) BRANCH="$REF" ;;
      *)           PR="$NUM" ;;
    esac
    ;;
esac

if [ -n "$PR" ]; then
  echo "dockside-self-update: checking out PR $PR"
  # --force: this hook only ever auto-fires once, on this devtainer's genuine first start (see
  # the file header) - there is no prior local work of the user's own to protect, so
  # unconditionally resetting a pre-existing local branch of this name (e.g. baked into the
  # image) to the PR's current state is safe and intended, same reasoning as the branch path
  # below.
  "$GH_BIN" pr checkout --force "$PR" \
    || { "$GIT_BIN" fetch origin "refs/pull/$PR/head" && "$GIT_BIN" checkout FETCH_HEAD; }
elif [ -n "$BRANCH" ]; then
  echo "dockside-self-update: checking out branch $BRANCH"
  "$GIT_BIN" fetch origin "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
  "$GIT_BIN" switch "$BRANCH" 2>/dev/null || "$GIT_BIN" switch --track -c "$BRANCH" "origin/$BRANCH"
  # Reset hard rather than fast-forward-only: this hook only ever auto-fires once, on this
  # devtainer's genuine first start (see the file header), so there is no prior local work of
  # the user's own to lose - unlike the no-ref 'git pull --ff-only' case below, which pulls
  # whatever branch is already checked out and so could have real local commits worth
  # protecting. A pre-existing local branch of this name (e.g. baked into the image) converges
  # unconditionally on the just-fetched origin/$BRANCH tip even if it had diverged from origin;
  # a freshly-tracked branch is already at this commit, so this is a no-op there.
  "$GIT_BIN" reset --hard "origin/$BRANCH"
else
  echo "dockside-self-update: no ref requested, pulling current branch"
  "$GIT_BIN" pull --ff-only
fi

echo "dockside-self-update: rebuilding client ..."
cd "$REPO/app/client"
npm install --no-audit --no-fund
npm run build

echo "dockside-self-update: restarting services ..."
sudo s6-svc -t /etc/service/nginx
sudo s6-svc -t /etc/service/docker-event-daemon

echo "dockside-self-update: done"
