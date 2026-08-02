#!/bin/bash

# Profile-declared 'launch' hook for Dockside's own self-hosting example profiles
# (00-dockside.json, 01-dockside-own-ide.json, 91-dockside-sysbox.json,
# 92-dockside-runcvm.json). See docs/extensions/lifecycle-hooks.md.
#
# Invoked by launch.sh's run_hook() (see app/scripts/container/launch.sh), as the
# devtainer's own 'dockside' user, once launch-time git/ssh/gh setup has completed
# (and again, any time later, via `dockside hook run`). Consumes the same 'branch'
# and 'pr' options as the 03-git-repo.json example profile, but - because this repo
# is baked into the image rather than cloned via gitURLs - via a hook instead of
# launch.sh's built-in GIT_URL-gated checkout, since switching Dockside's own branch
# also requires rebuilding the client and restarting Dockside's own services, not
# just a checkout.

set -euo pipefail

REPO="$HOME/dockside"
cd "$REPO"

BRANCH="${DOCKSIDE_OPTION_BRANCH:-}"
PR="${DOCKSIDE_OPTION_PR:-}"

# Use the IDE-bundled git/gh binaries (consistent CA store / exec-path), falling
# back to whatever's on PATH if IDE_PATH isn't set for some reason.
GIT_BIN="${IDE_PATH:-/opt/dockside/system/latest}/bin/git"
[ -x "$GIT_BIN" ] || GIT_BIN=git
GH_BIN="${IDE_PATH:-/opt/dockside/system/latest}/bin/gh"
[ -x "$GH_BIN" ] || GH_BIN=gh

if [ -n "$PR" ]; then
  echo "dockside-self-update: checking out PR $PR"
  "$GH_BIN" pr checkout "$PR" \
    || { "$GIT_BIN" fetch origin "refs/pull/$PR/head" && "$GIT_BIN" checkout FETCH_HEAD; }
elif [ -n "$BRANCH" ]; then
  echo "dockside-self-update: checking out branch $BRANCH"
  "$GIT_BIN" fetch origin "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
  "$GIT_BIN" switch "$BRANCH" 2>/dev/null || "$GIT_BIN" switch --track -c "$BRANCH" "origin/$BRANCH"
else
  echo "dockside-self-update: no branch/pr requested, pulling current branch"
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
