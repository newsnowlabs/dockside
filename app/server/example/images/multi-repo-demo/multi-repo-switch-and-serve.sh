#!/bin/sh
# Shared switch+(re)start logic for the multi-repo example profiles
# (05-image-embedded-multi-repo-hook.json, 06-image-embedded-multi-repo-entrypoint.json -
# see docs/extensions/lifecycle-hooks.md's "Multi-repo" section). Baked into the demo image
# by this directory's Dockerfile.
#
# Reads its two ref values from DOCKSIDE_OPTION_ALPHA_REF/DOCKSIDE_OPTION_BETA_REF env vars
# only, never from argv - so the exact same script serves both profiles even though "how the
# option values reach PID-1" differs completely between them:
#   - 05 (hook): DOCKSIDE_OPTION_* is already in the hook's docker-exec env by the time it
#     runs - nothing extra needed (Reservation::_hook_env).
#   - 06 (entrypoint): DOCKSIDE_OPTION_* is *also* set directly on `docker create`'s own Env
#     (Reservation::Launch::cmdline_json, seeded from the same Reservation::_option_env_pairs
#     _hook_env uses) - so this script reads it exactly the same way there too. {option.<name>}
#     argv substitution still exists and is still the right tool when a value needs to land
#     directly in a non-shell binary's own argv (see 04-git-clone-entrypoint.json for that
#     case) - it's just not needed here, since this is a shell script reading a variable.
#
# Each toy repo is a full git working tree cloned, at image build time, from a local bare
# "upstream" baked into the same image (see the Dockerfile) - so `git fetch origin` here needs
# no network access and no credential of any kind. A real multi-repo app would fetch from real
# remotes using whichever credential source (static deploy key, or Dockside-managed
# ssh-agent/gh auth - hooks only, never a bare entrypoint, see the doc) fits its deployment;
# that choice is orthogonal to everything below.
#
# Deliberately does NOT use `git switch --track -c "$ref" "origin/$ref"` guarded by `2>/dev/null
# ||` the way 00/01's dockside-self-update.sh and 04's clone-entrypoint script do for PR/branch
# resolution against real GitHub refs - there's no PR concept for these local toy repos, only
# plain branch names ('main', 'feature-x' - see the Dockerfile). A real deployment fetching real
# GitHub-hosted repos would reuse the resolve_tree_branch()/PR-vs-branch parsing shown in those
# other examples; this script's whole point is the per-repo loop and the env-var mechanics
# above, not re-demonstrating ref parsing.

set -e

switch_repo() {
   name="$1"; dir="$2"; ref="$3"
   [ -n "$ref" ] || ref="main"
   echo "[$name] switching to '$ref'"
   git -C "$dir" fetch -q origin "refs/heads/$ref:refs/remotes/origin/$ref"
   git -C "$dir" switch -q "$ref" 2>/dev/null || git -C "$dir" switch -q --track -c "$ref" "origin/$ref"
   git -C "$dir" reset -q --hard "origin/$ref"
}

# Idempotent (re)start: kill whatever this repo's own pidfile last recorded (if still alive),
# then serve the freshly-switched working tree. Safe to call on every invocation, whether this
# is the very first start (06's entrypoint, or 05's lifecycle:launch auto-fire) or a later
# on-demand re-switch (05 only - `dockside hook run <devtainer> lifecycle:launch`; 06 has no
# hooks declared at all, so it can only ever run this once, at container-create time - see the
# profile's own description for why that's the whole point of the comparison).
#
# A real app's "rebuild" step (e.g. 00/01's `npm run build`) would go between switch_repo and
# serve_repo; skipped here since each repo is just a static file - the point of this demo is the
# multi-repo/env-var mechanics, not re-demonstrating a real build step.
serve_repo() {
   name="$1"; dir="$2"; port="$3"
   pidfile="/tmp/dockside-example-$name.pid"
   if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      kill "$(cat "$pidfile")"
      sleep 1   # let the old server release the port before we rebind it
   fi
   ( cd "$dir" && python3 -m http.server "$port" >"/tmp/dockside-example-$name.log" 2>&1 & echo $! >"$pidfile" )
   sleep 1
   echo "[$name] serving $(cat "$dir/served-content.txt") on :$port"
}

switch_repo alpha /home/dockside/alpha "${DOCKSIDE_OPTION_ALPHA_REF:-main}"
switch_repo beta  /home/dockside/beta  "${DOCKSIDE_OPTION_BETA_REF:-main}"

serve_repo alpha /home/dockside/alpha 8081
serve_repo beta  /home/dockside/beta  8082
