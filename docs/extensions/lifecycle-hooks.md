# Lifecycle hooks: switching a devtainer's branch or PR

The [`03-git-repo.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/03-git-repo.json) example profile shows Dockside's built-in `gitURLs`/`GIT_URL` clone-on-launch, plus a single reserved `ref` option — holding a branch name, a PR number, or a full GitHub branch/PR URL copied from the browser — that `launch.sh` special-cases to check out after cloning (see [Launch-time git branch/PR checkout](../setup.md#launch-time-git-branchpr-checkout)). That mechanism is launch-time-only, single-repo, and stops at "the working tree is on the right ref" — it has no idea whether your application needs a rebuild or a service restart to actually run that ref.

This page covers four patterns for making a launched devtainer switch to (and, where relevant, actually *run*) a requested branch or PR, so you can pick the one that fits your application:

| Pattern | Multi-repo? | Rebuild/restart? | Dockside changes needed? |
| - | - | - | - |
| [A. Built-in `gitURLs` checkout](#a-built-in-giturls-checkout) | No | No | None (built in) |
| [B. Entrypoint + static credentials](#b-entrypoint-static-credentials) | Yes | Yes (you write it) | None |
| [C. Entrypoint + Dockside-managed credentials](#c-entrypoint-dockside-managed-credentials) | Yes | Yes (you write it) | None |
| [D. Lifecycle hook](#d-lifecycle-hook) | Yes | Yes (you write it) | New profile field (`hooks`) |

Patterns B–D all rely on the same generic `options` mechanism already described in [setup.md](../setup.md#profiles): a profile can define arbitrary named options (not just the reserved `ref`), whose values are injected into the container as `DOCKSIDE_OPTION_<NAME>` environment variables and/or via `{option.<name>}` placeholders. None of this page's patterns need a Dockside-specific "multi-repo" schema — a profile targeting several repos just defines whatever option names make sense for its app (e.g. `frontend_ref`, `api_ref`), and the entrypoint/hook script (which is entirely application-specific) decides what to do with them.

None of B–D need two separate options either: a single `ref`-style option that may hold a branch name, a PR number, or a full GitHub URL is entirely a matter of how your own entrypoint/hook script chooses to interpret its value — Dockside doesn't need to know the difference. The rule used throughout this page's examples, and by `launch.sh` itself for pattern A:

1. `https://github.com/<org>/<repo>/pull/<n>[...]` → PR `<n>` (extracted directly, unambiguous).
2. `https://github.com/<org>/<repo>/tree/<remainder>` or `.../commits/<remainder>` → a branch, resolved by trying progressively shorter prefixes of `<remainder>` against the repo's actual branches (`git ls-remote`) until one matches, starting with the full remainder. This isn't guesswork: git's ref namespace is hierarchical (`feature` and `feature/foo` can never both exist as branches at once), so there's exactly one real branch any given remainder could resolve to, and the search finds it — the only extra cost is a handful of `git ls-remote` round-trips for a branch name/subpath combination with several slashes.
3. Anything else: strip any leading `#` (so `42` and `#42` are equivalent); if what's left is purely numeric, treat it as a PR number; otherwise treat the original value as a branch name.

## A. Built-in `gitURLs` checkout

Covered in [setup.md](../setup.md#launch-time-git-branchpr-checkout). Use this when: your devtainer has exactly one repo, cloned via `gitURLs`/`gitURL` at launch, and there's no build step — the working tree being on the right ref *is* "running" it (e.g. an interpreted script, or a repo you only ever browse/edit in the IDE).

It does **not** apply to a profile with no `gitURLs` (or when `gitURL` is left blank at launch) — `launch.sh`'s checkout logic is gated on `GIT_URL` being set for *that* invocation, not on whether a repo happens to already exist at the expected path. A devtainer launched from an image with a repo already baked in (like Dockside's own [self-hosting profiles](#example-dockside-switching-its-own-branch) below) gets no automatic checkout from this path at all — that's what the other three patterns are for. This is deliberate, not a gap: see the callout in [setup.md](../setup.md#launch-time-git-branchpr-checkout) for why extending `launch.sh` itself to also act on a pre-existing repo isn't a good idea.

## B. Entrypoint + static credentials

Your profile's own `command`/`entrypoint` (the container's PID-1 process) does the checkout itself, using a credential your deployment provisions independently of Dockside — typically a read-only deploy key bind-mounted into the container.

This works because two things are both true, regardless of `launch.sh`:

1. **Bind/volume mounts are present from container start.** A `mounts.bind` (or `volume`) entry is part of `docker create`, so a mounted deploy key is already there when your entrypoint's first line runs — no waiting on anything Dockside does later.
2. **`{option.<name>}` placeholders resolve into `command`/`entrypoint` at container-create time.** They become literal argv on the container's `docker create`/`docker run` command line, before `launch.sh` ever runs.

The example [`04-entrypoint-branch-switch.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/04-entrypoint-branch-switch.json) profile demonstrates this end-to-end: it wires `{option.ref}` into its `command`, whose entrypoint script clones (over HTTPS, so the demo runs with no credential at all), decides whether `ref` is a branch, a PR number, or a full GitHub `tree`/`pull` URL (in which case it's resolved into a branch or PR number first — the same `resolve_tree_branch()` approach `checkout_git_ref()` uses for pattern A), and switches to it before starting the long-running process. Read the comments in that profile for how to extend it with a bind-mounted SSH deploy key for a private repo.

> **Pass option values as argv, not interpolated into your script text.** The example passes `{option.ref}` as an extra argument to `sh -c '<script>' sh "{option.ref}"` (read inside the script as `$1`), rather than substituting it directly into the script string. A user-supplied option value becomes a single literal argv string this way, immune to shell-metacharacter injection — interpolating it straight into the script text would not be.

This is the pattern to reach for when your deployment already has its own way to provision git credentials into a container (a secret dropped by CI/ops tooling, a purpose-built volume, etc.) and you want the simplest possible mechanism with no dependency on Dockside's own timing.

## C. Entrypoint + Dockside-managed credentials

Same idea as pattern B — your entrypoint does the checkout itself — but using the SSH keys/`gh` token Dockside manages *for the devtainer's owner*, rather than a separately-provisioned static credential. The catch: those aren't available yet when the container's PID-1 process starts. `launch.sh` sets them up later, asynchronously, via a `docker exec` from `docker-event-daemon` once the container is already running — so an entrypoint that wants to use them has to wait for a signal.

`launch.sh` provides that signal: once ssh-agent, `known_hosts`, and `gh` auth are all set up for this launch, it touches `/tmp/dockside/.credentials-ready` (this happens before, and independently of, any repository-specific `gitURLs` cloning, so it fires even for profiles with no `gitURLs` at all). `gh`'s own auth is written to `~/.config/gh/hosts.yml` on disk, so it needs no special handling to be reachable from a different process — but the ssh-agent socket is *not* at a fixed path: `ssh-agent` is left to choose its own (`/tmp/ssh-XXXXXXXXXX/agent.<pid>`), the same as plain OpenSSH always does, rather than Dockside pinning it to something predictable. A container restart tears down every process inside it including the agent, so a fixed path would refuse to bind on relaunch — and worse, a well-known, world-writable path is squattable by any other UID in the container ahead of the real agent, which could then harvest the owner's keys via the `ssh-add` that follows. So your entrypoint needs to *discover* the socket, not assume it:

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

# Discover Dockside's own managed ssh-agent: scan its default socket naming
# (/tmp/ssh-*/agent.*) newest-first by mtime, and validate each candidate with `ssh-add -l`
# rather than trusting mtime alone - a dead agent's directory (e.g. left behind by an
# OOM-killed process) can still be the newest by mtime with no live agent behind it. Exit code
# 0 (has keys) or 1 (no keys, but the agent answered) both mean live; anything else (2 = could
# not contact an agent at all) does not. This is the same discovery launch.sh's own run_hook()
# uses for the equivalent problem - see app/scripts/container/launch.sh.
for sock in $(ls -dt /tmp/ssh-*/agent.* 2>/dev/null); do
   SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1
   case $? in
      0|1) export SSH_AUTH_SOCK="$sock"; break ;;
   esac
done
# gh auth (if GH_TOKEN was configured for this user) is already on disk; no
# extra setup needed to use `gh` here.

# ... your own git fetch/switch, build, then finally exec your real process ...
exec /my-app/start.sh
```

Use this pattern when you want branch/PR switching to use the *same* SSH keys/`gh` auth a developer already has configured in Dockside, rather than provisioning a separate credential — at the cost of the container's real startup being delayed until `launch.sh` catches up.

Like pattern B, this handles multiple repos just as easily as one: `.credentials-ready` and the discovered `SSH_AUTH_SOCK` aren't tied to any particular repo, so once they're available your entrypoint is free to fetch/switch as many repos as the devtainer needs, using whatever `DOCKSIDE_OPTION_*` option names your profile defines for each.

> **A second, different agent socket exists too — for a different purpose.** dropbear (Dockside's SSH server) creates its own, separate forwarded-agent socket at `/tmp/dropbear-<hex>/auth-<hex>-<n>` while a developer is connected with agent forwarding (`ssh -A`/`ForwardAgent`) — but it exposes *that developer's own local keys*, not the reservation owner's registered credentials, and only for the lifetime of that one SSH session. That makes it session-transient and identity-inconsistent between runs, so it's the wrong target for the unattended discovery above — but it's a genuinely available option if you specifically want a hook or entrypoint to act with *the connected developer's own* credentials rather than the reservation's, e.g. an interactive debugging session that should never touch the owner's registered keys.

## D. Lifecycle hook

An image-embedded script, declared in the profile, dispatched the same way Dockside dispatches its own internal `launch.sh` functions (`docker exec -u <user> <containerId> /opt/dockside/launch.sh <fn>`) — auto-run at launch time (`lifecycle:launch` only on a devtainer's true first launch, `lifecycle:start` on every launch including that one — see [Running it](#running-it) below for the distinction), and re-runnable on demand at any later point without restarting the container, e.g. after a user changes a devtainer's `ref` option mid-session.

This is the pattern to reach for when a checkout alone isn't "running" the requested ref — your app needs a rebuild and/or a service restart — or when a single devtainer spans multiple repos that need coordinated handling. It's also the only pattern here that lets a user re-trigger the switch without a full container relaunch.

### Declaring a hook

```json
"hooks": {
   "lifecycle:launch": { "script": "/opt/myapp/hooks/on-launch.sh", "manual": true }
}
```

`hooks` is profile-only — it can never be set or overridden by a launch-time request, so the executable that runs is always the one the profile/image author chose (the same trust model as a profile's `command`/`entrypoint`). Only the *arguments* — the values of whatever `options` your profile defines — are user-influenced.

Each entry is an Object: `script` (mandatory) is the absolute in-image path to run; `manual` (optional, meaningful only on a reserved `lifecycle:*` name — see below) opts that hook into on-demand re-invocation via `dockside hook run`, in addition to its automatic invocation.

> **A devtainer's hooks are fixed at creation time, not live-linked to the profile.** The profile is snapshotted into the reservation record when a devtainer is created — a deliberate separation of concerns, since it means editing a profile is always safe and can never affect anything already running. One consequence: adding, removing, or changing a `hooks` entry on a profile has no effect on devtainers created before that edit. Attempting to run a hook name not in *this devtainer's own* snapshot fails with *"No hook '\<name\>' is configured for this devtainer - check the hook name's spelling, or recreate the devtainer if this hook has been added to the profile since it was created"* — naming both possible causes rather than checking the live profile to tell which applies.

Hook names fall into two kinds:

- **Reserved lifecycle names**, namespaced `lifecycle:<event>` — `lifecycle:launch` and `lifecycle:start` (both implemented; see [Running it](#running-it) below), plus `lifecycle:stop`/`lifecycle:rename`/`lifecycle:periodic`, reserved for a broader set of lifecycle trigger points that may be added in future. These are schema-valid today even though only `launch`/`start` do anything yet, so a profile can adopt a name now without the schema needing to change shape later — but don't assume the others fire, or that they'll ever be manually runnable the way `launch`/`start` are (that's a decision for whenever each one is actually implemented).
- **Custom names** — anything else: lowercase, starting with a letter, hyphens allowed but not leading/trailing/doubled (e.g. `update`, `repo-status`, `backup`). A profile can declare any number of these with zero Dockside code changes, for whatever on-demand actions your app needs beyond the reserved lifecycle events.

**A reserved lifecycle name only auto-invokes if it's `lifecycle:launch` or `lifecycle:start`** (the two implemented today) — nothing else in `hooks` is ever auto-fired. **A reserved lifecycle name is only manually runnable (`dockside hook run`) if its own entry sets `"manual": true`** — this is opt-in, not automatic, so declaring `hooks."lifecycle:launch"` with `script` alone gets you auto-invoke but *not* on-demand re-invocation; you need `"manual": true` too (the same is true for `lifecycle:start`). Custom names must never set `manual` at all — since nothing ever auto-fires them, they're always manually runnable by construction (setting `"manual": true` on one is rejected as a likely mistake, not silently ignored).

> **Gotcha**: because custom names are unrestricted, a profile can legally declare a bare `"launch"` key (no `lifecycle:` prefix) — it validates fine, but it is an ordinary *custom* hook, not the reserved lifecycle one. Nothing ever auto-invokes it; it only runs via `dockside hook run <devtainer> launch`. This is an easy mistake when migrating an older profile — double-check you meant `lifecycle:launch`, not `launch`.

### What the hook script can rely on

- Runs as the devtainer's own unix user (not root) — use `sudo` inside the script for anything privileged, the same way you would by hand.
- `DOCKSIDE_OPTION_<NAME>` env vars for every option your profile defines (not just `ref` — define whatever option names your app needs, including per-repo ones for a multi-repo app).
- `GH_TOKEN`, `GIT_URL`/`SSH_KNOWN_HOSTS_DOMAINS` if this profile also uses `gitURLs`.
- `SSH_AUTH_SOCK` already pointed at a live ssh-agent socket — no setup needed, unlike writing your own entrypoint under pattern C: every hook invocation, whether the launch-time/start-time auto-invoke or an on-demand one, is its own independent `docker exec` and so never inherits the socket from `spawn_ssh_agent`'s own process tree — `run_hook()` discovers Dockside's managed agent itself before running your script, the same way for both.
- Exit code `0` for success, non-zero for failure. `launch.sh` records the outcome as `/tmp/dockside/.hook-ready.<name>` or `.hook-failed.<name>` (scoped by hook name, so two different hooks' sentinels never collide), and (on failure) surfaces a warning via the same mechanism used for other launch-time warnings, visible in the devtainer's IDE/SSH terminal on next login.
- Exit code `2` specifically means "a run was already in progress" (see [Concurrency](#concurrency) below) — not a script failure.

### Running it

- **Automatically**, for `lifecycle:launch` and `lifecycle:start` only — no other hook, reserved or custom, is ever auto-invoked. Both run in the same place: after launch-time git/ssh/gh setup for that invocation has completed (i.e. after the same point `.credentials-ready` is touched for pattern C, and — if this profile also uses `gitURLs` — after any requested ref has been checked out into the cloned repo). They differ in *how often*:
  - **`lifecycle:launch` fires once** — only on this devtainer's true first launch, never again on a later restart. This matters because a devtainer's `options` (and so `DOCKSIDE_OPTION_<NAME>`/`{option.*}` values, including `ref`) are frozen at creation time and can never change afterwards — there is nothing new for a hook keyed off them to do on a restart, and re-running unconditionally would force whatever the hook does (a rebuild, a service restart, a slow `git pull`) on every plain restart, whether or not anything changed.
  - **`lifecycle:start` fires every launch, including the first one** — use this for anything that should genuinely happen every time a devtainer (re)starts, e.g. an automatic `git pull --ff-only` on resume, independent of whether `ref` was ever set.
  - If a profile declares both, both run, in that order, on the very first launch; only `lifecycle:start` runs again on every subsequent restart.
- **On demand**, at any later point, for `lifecycle:launch`/`lifecycle:start` (if that entry sets `"manual": true`) or any custom hook: `dockside hook run <devtainer> <hook-name>` dispatches it and waits for the outcome, reporting it the same way regardless of how long the hook actually takes (a `.` prints for each poll while it's still running, so a slow hook — e.g. an `npm run build` — no longer looks like the command has hung):
  ```
  $ dockside hook run my-devtainer lifecycle:launch
  Running hook 'lifecycle:launch' on 'my-devtainer'…
  ..
  Hook 'lifecycle:launch' on 'my-devtainer' succeeded.
  ```
  Exit codes: `0` success, `1` the hook script failed (or aborted before it could report an exit code at all — rare, e.g. the server process itself was killed mid-run), `3` a run was already in progress, `4` the hook timed out. Pass `--timeout SECONDS` to raise the server-side time limit for hooks that take a while — the default is 120s (`hooks.defaultTimeoutSeconds` in `config.json`). `HOOK` is required — there is no default hook name.

### Concurrency

Both invocation paths run the same `launch.sh` function, which self-serializes per hook name via a lock: if a run of that *same* hook is already in progress, a second one doesn't queue or block — it reports "busy" (exit code `2`/`3` depending on which layer you're looking at) and leaves the first run to finish undisturbed. A concurrent invocation of a *different* hook name is unaffected — locks and sentinels are scoped per name, so `lifecycle:launch` and a custom hook on the same devtainer never contend with each other.

### Example: Dockside switching its own branch

Dockside's own self-hosting example profiles (`00-dockside.json`, `01-dockside-own-ide.json`, `91-dockside-sysbox.json`, `92-dockside-runcvm.json`) launch images with the Dockside repo already baked in at `/home/dockside/dockside` — no `gitURLs`, so pattern A doesn't apply, and switching branch means rebuilding the Vue client and restarting Dockside's own services, not just a checkout. They declare `"hooks": {"lifecycle:launch": {"script": ".../dockside-self-update.sh", "manual": true}}` (the `"manual": true` is what makes `dockside hook run` able to re-trigger it later, not just the automatic once-per-launch invocation), wired to [`app/scripts/hooks/dockside-self-update.sh`](https://github.com/newsnowlabs/dockside/blob/main/app/scripts/hooks/dockside-self-update.sh). This is deliberately on `lifecycle:launch`, not `lifecycle:start`: `ref` can never change after the devtainer is created, so checking it out is inherently one-shot, and the no-`ref` fallback below (`git pull --ff-only`) is deliberately opt-in via on-demand `dockside hook run` rather than forced on every plain restart — a profile that genuinely wants an automatic pull on every resume should use `lifecycle:start` for that instead.

```sh
#!/bin/bash
set -euo pipefail

REPO="$HOME/dockside"
cd "$REPO"

REF="${DOCKSIDE_OPTION_REF:-}"

# resolve_tree_branch(): same progressive-shortening resolution as
# checkout_git_ref() in app/scripts/container/launch.sh — elided here, see the
# real script for the full version.

PR="" BRANCH=""
case "$REF" in
  https://github.com/*/pull/*)
    PR=${REF#*/pull/}; PR=${PR%%[/?#]*}
    ;;
  https://github.com/*/tree/*)
    CANDIDATE=${REF#*/tree/}; CANDIDATE=${CANDIDATE%%[?#]*}
    BRANCH=$(resolve_tree_branch "$CANDIDATE") || BRANCH="$CANDIDATE"
    ;;
  https://github.com/*/commits/*)
    CANDIDATE=${REF#*/commits/}; CANDIDATE=${CANDIDATE%%[?#]*}
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
  gh pr checkout --force "$PR" || { git fetch origin "refs/pull/$PR/head" && git checkout FETCH_HEAD; }
elif [ -n "$BRANCH" ]; then
  git fetch origin "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
  git switch "$BRANCH" 2>/dev/null || git switch --track -c "$BRANCH" "origin/$BRANCH"
  git reset --hard "origin/$BRANCH"
else
  git pull --ff-only
fi

cd "$REPO/app/client" && npm install --no-audit --no-fund && npm run build

sudo s6-svc -t /etc/service/nginx
sudo s6-svc -t /etc/service/docker-event-daemon
```

(Elided above: `resolve_tree_branch()`'s body, IDE-bundled `git`/`gh` binary paths, and log lines — see the real script for the full version.) This reuses the exact restart sequence documented for manual use in this repo's own `CLAUDE.md`, and consumes the same single `ref` option as `03-git-repo.json` — via a hook instead of `launch.sh`'s built-in checkout, since a bare checkout alone would leave the previous branch's build still running.

**Why `--force`/`reset --hard` for the branch/PR switch, but plain `git pull --ff-only` for the no-`ref` fallback?** Because this hook only ever *auto*-fires once, on this devtainer's true first start (`lifecycle:launch`, not `lifecycle:start` — see above): switching to a *different* requested ref has no prior local work of the user's own to protect on that ref, so unconditionally converging a pre-existing local branch of that name (e.g. one baked into the image) onto the just-fetched remote tip is safe and intended. Pulling the *current* branch is a different case even here — it's the branch this devtainer has actually been running, which may carry real local commits (from image build time, or from an earlier manual `dockside hook run`) worth protecting, so it stays fail-loud-not-destructive. The same reasoning applies to any hook you wire to `lifecycle:launch` yourself: prefer `reset --hard`/`--force` when switching to a ref this devtainer couldn't have done real work on yet; prefer `--ff-only` for anything that touches a branch it may already have been running — and always `--ff-only` for a hook wired to `lifecycle:start`, since by definition it can run again on a devtainer with genuine history since the last invocation.

## E. Custom (non-lifecycle) hooks: on-demand actions beyond branch switching

Everything above covers `lifecycle:launch` specifically — a reserved name Dockside itself auto-invokes. A profile can also declare any number of **custom hooks**: any name that isn't one of the reserved `lifecycle:*` forms, requiring no Dockside code changes to add and never setting `manual` (they're always on-demand only, and always manually runnable, since nothing else ever triggers them).

A representative use case: a CI job keeping a long-lived preview devtainer in sync with a PR's latest commit, without a full relaunch. This is deliberately *not* the same job as `lifecycle:launch` — it should only ever fast-forward whatever's already checked out (never resolve or switch to a different ref) and then rebuild/restart, so it can't accidentally do what a branch switch does:

```json
"hooks": {
   "lifecycle:launch": { "script": "/opt/myapp/hooks/on-launch.sh", "manual": true },
   "update": { "script": "/opt/myapp/hooks/on-update.sh" }
}
```

```sh
#!/bin/sh
set -e
cd /opt/myapp
git pull --ff-only
npm install --no-audit --no-fund && npm run build
sudo s6-svc -t /etc/service/my-app
```

Triggered the same way as any other on-demand hook — `dockside hook run my-devtainer update` — whether run by a developer or by an external caller such as a CI pipeline. The credential the script uses to authenticate to git is entirely the profile author's choice, same as for any other pattern on this page: reuse the calling user's own git/gh credentials (pattern C's mechanism — this is the default for every hook, custom or lifecycle, with no extra configuration), or bind-mount a separately-provisioned read-only deploy key (pattern B's mechanism) if you'd rather not depend on a specific person's credentials for a routine, automatable action. Dockside's authorization model doesn't need to know which — the `runContainerHooks` permission plus ordinary `develop` access to the devtainer governs who may call `dockside hook run` at all, entirely independent of what credential the hook script itself decides to use.
