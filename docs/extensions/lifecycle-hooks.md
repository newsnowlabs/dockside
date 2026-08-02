# Lifecycle hooks: switching a devtainer's branch or PR

The [`03-git-repo.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/03-git-repo.json) example profile shows Dockside's built-in `gitURLs`/`GIT_URL` clone-on-launch, plus reserved `branch`/`pr` `options` that `launch.sh` special-cases to check out a branch or PR after cloning (see [Launch-time git branch/PR checkout](../setup.md#launch-time-git-branchpr-checkout)). That mechanism is launch-time-only, single-repo, and stops at "the working tree is on the right ref" — it has no idea whether your application needs a rebuild or a service restart to actually run that ref.

This page covers four patterns for making a launched devtainer switch to (and, where relevant, actually *run*) a requested branch or PR, so you can pick the one that fits your application:

| Pattern | Multi-repo? | Rebuild/restart? | Dockside changes needed? |
| - | - | - | - |
| [A. Built-in `gitURLs` checkout](#a-built-in-giturls-checkout) | No | No | None (built in) |
| [B. Entrypoint + static credentials](#b-entrypoint-static-credentials) | Yes | Yes (you write it) | None |
| [C. Entrypoint + Dockside-managed credentials](#c-entrypoint-dockside-managed-credentials) | Yes | Yes (you write it) | None |
| [D. Lifecycle hook](#d-lifecycle-hook) | Yes | Yes (you write it) | New profile field (`hooks`) |

Patterns B–D all rely on the same generic `options` mechanism already described in [setup.md](../setup.md#profiles): a profile can define arbitrary named options (not just the reserved `branch`/`pr`), whose values are injected into the container as `DOCKSIDE_OPTION_<NAME>` environment variables and/or via `{option.<name>}` placeholders. None of this page's patterns need a Dockside-specific "multi-repo" schema — a profile targeting several repos just defines whatever option names make sense for its app (e.g. `frontend_branch`, `api_branch`), and the entrypoint/hook script (which is entirely application-specific) decides what to do with them.

## A. Built-in `gitURLs` checkout

Covered in [setup.md](../setup.md#launch-time-git-branchpr-checkout). Use this when: your devtainer has exactly one repo, cloned via `gitURLs`/`gitURL` at launch, and there's no build step — the working tree being on the right ref *is* "running" it (e.g. an interpreted script, or a repo you only ever browse/edit in the IDE).

It does **not** apply to a profile with no `gitURLs` (or when `gitURL` is left blank at launch) — `launch.sh`'s checkout logic is gated on `GIT_URL` being set for *that* invocation, not on whether a repo happens to already exist at the expected path. A devtainer launched from an image with a repo already baked in (like Dockside's own [self-hosting profiles](#example-dockside-switching-its-own-branch) below) gets no automatic checkout from this path at all — that's what the other three patterns are for.

## B. Entrypoint + static credentials

Your profile's own `command`/`entrypoint` (the container's PID-1 process) does the checkout itself, using a credential your deployment provisions independently of Dockside — typically a read-only deploy key bind-mounted into the container.

This works because two things are both true, regardless of `launch.sh`:

1. **Bind/volume mounts are present from container start.** A `mounts.bind` (or `volume`) entry is part of `docker create`, so a mounted deploy key is already there when your entrypoint's first line runs — no waiting on anything Dockside does later.
2. **`{option.<name>}` placeholders resolve into `command`/`entrypoint` at container-create time.** They become literal argv on the container's `docker create`/`docker run` command line, before `launch.sh` ever runs.

The example [`04-entrypoint-branch-switch.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/04-entrypoint-branch-switch.json) profile demonstrates this end-to-end: it wires `{option.branch}`/`{option.pr}` into its `command`, whose entrypoint script clones (over HTTPS, so the demo runs with no credential at all) and switches ref before starting the long-running process. Read the comments in that profile for how to extend it with a bind-mounted SSH deploy key for a private repo.

> **Pass option values as argv, not interpolated into your script text.** The example passes `{option.branch}`/`{option.pr}` as extra arguments to `sh -c '<script>' sh "{option.branch}" "{option.pr}"` (read inside the script as `$1`/`$2`), rather than substituting them directly into the script string. A user-supplied option value becomes a single literal argv string this way, immune to shell-metacharacter injection — interpolating it straight into the script text would not be.

This is the pattern to reach for when your deployment already has its own way to provision git credentials into a container (a secret dropped by CI/ops tooling, a purpose-built volume, etc.) and you want the simplest possible mechanism with no dependency on Dockside's own timing.

## C. Entrypoint + Dockside-managed credentials

Same idea as pattern B — your entrypoint does the checkout itself — but using the SSH keys/`gh` token Dockside manages *for the devtainer's owner*, rather than a separately-provisioned static credential. The catch: those aren't available yet when the container's PID-1 process starts. `launch.sh` sets them up later, asynchronously, via a `docker exec` from `docker-event-daemon` once the container is already running — so an entrypoint that wants to use them has to wait for a signal.

`launch.sh` provides that signal: once ssh-agent, `known_hosts`, and `gh` auth are all set up for this launch, it touches `/tmp/dockside/.credentials-ready` (this happens before, and independently of, any repository-specific `gitURLs` cloning, so it fires even for profiles with no `gitURLs` at all). It also pins the ssh-agent socket to a fixed path, `/tmp/dockside/agent.sock`, instead of the random one `ssh-agent` would otherwise choose — so once the sentinel appears, any process (including one that started long before `launch.sh` did) can reach it immediately, with no discovery needed. `gh`'s own auth is written to `~/.config/gh/hosts.yml` on disk, so it needs no special handling to be reachable from a different process.

A minimal entrypoint using this pattern:

```sh
#!/bin/sh
set -e

# Wait (bounded) for launch.sh to finish setting up credentials.
i=0
while [ ! -f /tmp/dockside/.credentials-ready ]; do
   i=$((i + 1))
   [ "$i" -lt 60 ] || { echo "timed out waiting for credentials" >&2; exit 1; }
   sleep 1
done

export SSH_AUTH_SOCK=/tmp/dockside/agent.sock
# gh auth (if GH_TOKEN was configured for this user) is already on disk; no
# extra setup needed to use `gh` here.

# ... your own git fetch/switch, build, then finally exec your real process ...
exec /my-app/start.sh
```

Use this pattern when you want branch/PR switching to use the *same* SSH keys/`gh` auth a developer already has configured in Dockside, rather than provisioning a separate credential — at the cost of the container's real startup being delayed until `launch.sh` catches up.

## D. Lifecycle hook

An image-embedded script, declared in the profile, dispatched the same way Dockside dispatches its own internal `launch.sh` functions (`docker exec -u <user> <containerId> /opt/dockside/launch.sh <fn>`) — auto-run once per launch, and re-runnable on demand at any later point without restarting the container, e.g. after a user changes a devtainer's `branch`/`pr` options mid-session.

This is the pattern to reach for when a checkout alone isn't "running" the requested ref — your app needs a rebuild and/or a service restart — or when a single devtainer spans multiple repos that need coordinated handling. It's also the only pattern here that lets a user re-trigger the switch without a full container relaunch.

### Declaring a hook

```json
"hooks": {
   "launch": "/opt/myapp/hooks/on-launch.sh"
}
```

`hooks` is profile-only — it can never be set or overridden by a launch-time request, so the executable that runs is always the one the profile/image author chose (the same trust model as a profile's `command`/`entrypoint`). Only the *arguments* — the values of whatever `options` your profile defines — are user-influenced. Currently only one key, `launch`, is recognised; other names are reserved for a broader set of lifecycle trigger points (start/stop/rename/periodic) that may be added in future — don't assume they fire yet.

### What the hook script can rely on

- Runs as the devtainer's own unix user (not root) — use `sudo` inside the script for anything privileged, the same way you would by hand.
- `DOCKSIDE_OPTION_<NAME>` env vars for every option your profile defines (not just `branch`/`pr` — define whatever option names your app needs, including per-repo ones for a multi-repo app).
- `GH_TOKEN`, `GIT_URL`/`SSH_KNOWN_HOSTS_DOMAINS` if this profile also uses `gitURLs`.
- `SSH_AUTH_SOCK` already pointed at the (pinned) ssh-agent socket — no setup needed, unlike writing your own entrypoint under pattern C.
- Exit code `0` for success, non-zero for failure. `launch.sh` records the outcome as `/tmp/dockside/.hook-ready` or `.hook-failed`, and (on failure) surfaces a warning via the same mechanism used for other launch-time warnings, visible in the devtainer's IDE/SSH terminal on next login.
- Exit code `2` specifically means "a run was already in progress" (see [Concurrency](#concurrency) below) — not a script failure.

### Running it

- **Automatically**, once per launch: `launch.sh` runs it itself, after launch-time git/ssh/gh setup for that invocation has completed (i.e. after the same point `.credentials-ready` is touched for pattern C, and — if this profile also uses `gitURLs` — after any requested branch/PR has been checked out into the cloned repo).
- **On demand**, at any later point: `dockside hook run <devtainer>` runs it synchronously and reports the outcome:
  ```
  $ dockside hook run my-devtainer
  Running hook on 'my-devtainer'…
  Hook on 'my-devtainer' succeeded.
  ```
  Exit codes: `0` success, `1` the hook script failed, `3` a run was already in progress, `4` the hook timed out. Pass `--timeout SECONDS` to raise the server-side time limit for hooks that take a while (e.g. an `npm run build`) — the default is 120s (`hooks.defaultTimeoutSeconds` in `config.json`).

### Concurrency

Both invocation paths run the same `launch.sh` function, which self-serializes via a lock: if a run is already in progress, a second one doesn't queue or block — it reports "busy" (exit code `2`/`3` depending on which layer you're looking at) and leaves the first run to finish undisturbed.

### Example: Dockside switching its own branch

Dockside's own self-hosting example profiles (`00-dockside.json`, `01-dockside-own-ide.json`, `91-dockside-sysbox.json`, `92-dockside-runcvm.json`) launch images with the Dockside repo already baked in at `/home/dockside/dockside` — no `gitURLs`, so pattern A doesn't apply, and switching branch means rebuilding the Vue client and restarting Dockside's own services, not just a checkout. They're wired to [`app/scripts/hooks/dockside-self-update.sh`](https://github.com/newsnowlabs/dockside/blob/main/app/scripts/hooks/dockside-self-update.sh):

```sh
#!/bin/bash
set -euo pipefail

REPO="$HOME/dockside"
cd "$REPO"

BRANCH="${DOCKSIDE_OPTION_BRANCH:-}"
PR="${DOCKSIDE_OPTION_PR:-}"

if [ -n "$PR" ]; then
  gh pr checkout "$PR" || { git fetch origin "refs/pull/$PR/head" && git checkout FETCH_HEAD; }
elif [ -n "$BRANCH" ]; then
  git fetch origin "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
  git switch "$BRANCH" 2>/dev/null || git switch --track -c "$BRANCH" "origin/$BRANCH"
else
  git pull --ff-only
fi

cd "$REPO/app/client" && npm install --no-audit --no-fund && npm run build

sudo s6-svc -t /etc/service/nginx
sudo s6-svc -t /etc/service/docker-event-daemon
```

(Elided above: IDE-bundled `git`/`gh` binary paths and log lines — see the real script for the full version.) This reuses the exact restart sequence documented for manual use in this repo's own `CLAUDE.md`, and consumes the same `branch`/`pr` option names as `03-git-repo.json` — just via a hook instead of `launch.sh`'s built-in checkout, since a bare checkout alone would leave the previous branch's build still running.
