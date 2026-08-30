# Switching a devtainer's branch or PR

The [`03-git-repo.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/03-git-repo.json) example profile shows Dockside's built-in `gitURLs`/`GIT_URL` clone-on-launch, plus a single reserved `ref` option — holding a branch name, a PR number, or a full GitHub branch/PR URL copied from the browser — that `launch.sh` special-cases to check out after cloning (see [Launch-time git branch/PR checkout](../setup.md#launch-time-git-branchpr-checkout)). That mechanism is launch-time-only, single-repo, and stops at "the working tree is on the right ref" — it has no idea whether your application needs a rebuild or a service restart to actually run that ref.

Everything else on this page is really three **independent** choices, not a menu of mutually-exclusive "patterns" — pick one value from each, and hooks (the third choice) compose freely with either value of the other two:

1. **[Where your repo(s) come from](#1-where-your-repos-come-from)** — Dockside's built-in `gitURLs` checkout, a repo already baked into the image, or your own entrypoint cloning one at container-create time.
2. **[Where your git credential comes from](#2-where-your-git-credential-comes-from)** — a statically/externally-provisioned one (e.g. a bind-mounted deploy key), or the SSH keys/`gh` token Dockside manages for the devtainer's owner.
3. **[What performs the switch](#3-what-performs-the-switch)** — your profile's own `command`/entrypoint (PID-1), or a declared `hooks` script.

Not every combination of these three is a good idea — see [Combinations that don't work](#combinations-that-dont-work) once you've read what each choice actually does.

All of this relies on the same generic `options` mechanism already described in [setup.md](../setup.md#profiles): a profile can define arbitrary named options (not just the reserved `ref`), whose values become available to whatever performs the switch. A profile targeting several repos just defines whatever option names make sense for its app (e.g. `frontend_ref`, `api_ref`) — see [Multi-repo](#multi-repo) below; Dockside doesn't need a repo-count-aware schema for this at all.

None of this needs two separate options either: a single `ref`-style option that may hold a branch name, a PR number, or a full GitHub URL is entirely a matter of how your own script chooses to interpret its value — Dockside doesn't need to know the difference. The rule used throughout this page's examples, and by `launch.sh` itself for the built-in checkout:

1. `https://github.com/<org>/<repo>/pull/<n>[...]` → PR `<n>` (extracted directly, unambiguous).
2. `https://github.com/<org>/<repo>/tree/<remainder>` or `.../commits/<remainder>` → a branch, resolved by trying progressively shorter prefixes of `<remainder>` against the repo's actual branches (`git ls-remote`) until one matches, starting with the full remainder. This isn't guesswork: git's ref namespace is hierarchical (`feature` and `feature/foo` can never both exist as branches at once), so there's exactly one real branch any given remainder could resolve to, and the search finds it — the only extra cost is a handful of `git ls-remote` round-trips for a branch name/subpath combination with several slashes.
3. Anything else: strip any leading `#` (so `42` and `#42` are equivalent); if what's left is purely numeric, treat it as a PR number; otherwise treat the original value as a branch name.

## 1. Where your repo(s) come from

**Built-in `gitURLs` checkout.** Covered in [setup.md](../setup.md#launch-time-git-branchpr-checkout). Use this when: your devtainer has exactly one repo, cloned via `gitURLs`/`gitURL` at launch, and there's no build step — the working tree being on the right ref *is* "running" it (e.g. an interpreted script, or a repo you only ever browse/edit in the IDE). It does **not** apply to a profile with no `gitURLs` (or when `gitURL` is left blank at launch) — `launch.sh`'s checkout logic is gated on `GIT_URL` being set for *that* invocation, not on whether a repo happens to already exist at the expected path. This mechanism is also structurally single-repo (one `gitURL`, one reserved `ref` option) — the other two choices below aren't.

**Already baked into the image.** Your image already has the repo(s) checked out at build time (a real deployment's own multi-repo application image is the common case this covers — see [Multi-repo](#multi-repo)). There's no clone to do at container start, only a `git fetch`/`switch` against an existing working tree. [`00-dockside.json`/`01-dockside-own-ide.json`](#example-dockside-switching-its-own-branch) are the canonical single-repo example of this.

**Cloned at container start by your own entrypoint.** A generic image with no repo baked in, whose own `command`/entrypoint clones one itself, the first time the container runs. [`04-git-clone-entrypoint.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/04-git-clone-entrypoint.json) demonstrates this end-to-end: `{option.ref}` is wired into its `command`, whose entrypoint script clones (over HTTPS, so the demo runs with no credential at all), decides whether `ref` is a branch, a PR number, or a full GitHub `tree`/`pull` URL, and switches to it before starting the long-running process. This works because two things are both true, regardless of `launch.sh`:

1. **Bind/volume mounts are present from container start.** A `mounts.bind` (or `volume`) entry is part of `docker create`, so a mounted deploy key is already there when your entrypoint's first line runs — no waiting on anything Dockside does later.
2. **`{option.<name>}` placeholders resolve into `command`/`entrypoint` at container-create time.** They become literal argv on the container's `docker create`/`docker run` command line, before `launch.sh` ever runs.

> **Pass option values as argv, not interpolated into your script text.** `04`'s example passes `{option.ref}` as an extra argument to `sh -c '<script>' sh "{option.ref}"` (read inside the script as `$1`), rather than substituting it directly into the script string. A user-supplied option value becomes a single literal argv string this way, immune to shell-metacharacter injection — interpolating it straight into the script text would not be. `{option.<name>}` argv substitution stays the right tool for a value that needs to land directly in a non-shell binary's own argv (a CLI flag, say); it just isn't your *only* option for reaching a shell entrypoint any more — see the next section.

## 2. Where your git credential comes from

**Statically/externally-provisioned.** Your deployment has its own way to get a credential into the container independently of Dockside — typically a read-only deploy key bind-mounted in (`mounts.bind`), but equally a secret baked into the image, or dropped in by CI/ops tooling. Present from container start, so a `command`/entrypoint can use it immediately with no waiting. `04`'s comments show how to wire this in for a private repo.

**Dockside-managed.** The SSH keys/`gh` token Dockside manages *for the devtainer's owner*, rather than a separately-provisioned static credential. `launch.sh` sets these up asynchronously, via a `docker exec` from `docker-event-daemon` once the container is already running — independent of whatever the profile's own `command`/entrypoint is doing (see [Combinations that don't work](#combinations-that-dont-work) for why that independence is a hazard, not a convenience, for an entrypoint). Once ssh-agent, `known_hosts`, and `gh` auth are all set up for this launch, `launch.sh` touches `/tmp/dockside/.credentials-ready` (this happens before, and independently of, any repository-specific `gitURLs` cloning, so it fires even for profiles with no `gitURLs` at all).

- **From a hook, this is transparent — nothing to write.** Every hook invocation, whether the launch-time/start-time auto-invoke or an on-demand one, gets `SSH_AUTH_SOCK` already pointed at a live ssh-agent socket and `gh`'s own auth already on disk (`~/.config/gh/hosts.yml`) — `run_hook()` discovers Dockside's managed agent itself before running your script. See [What the hook script can rely on](#what-the-hook-script-can-rely-on) below.
- **From an entrypoint, it's neither transparent nor recommended** — see the next section.

> **A second, different agent socket exists too — for a different purpose.** dropbear (Dockside's SSH server) creates its own, separate forwarded-agent socket at `/tmp/dropbear-<hex>/auth-<hex>-<n>` while a developer is connected with agent forwarding (`ssh -A`/`ForwardAgent`) — but it exposes *that developer's own local keys*, not the reservation owner's registered credentials, and only for the lifetime of that one SSH session. That's the wrong target for anything unattended, but it's a genuinely available option if you specifically want a hook to act with *the connected developer's own* credentials rather than the reservation's.

## Combinations that don't work

**Entrypoint + Dockside-managed credentials: technically possible, don't do it.** In principle a bare entrypoint could poll for `/tmp/dockside/.credentials-ready` and then discover the ssh-agent socket itself (it's not at a fixed path — `ssh-agent` picks its own, `/tmp/ssh-XXXXXXXXXX/agent.<pid>` — and a well-known fixed path would be squattable by another UID in the container anyway):

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
# OOM-killed process) can still be the newest by mtime with no live agent behind it.
for sock in $(ls -dt /tmp/ssh-*/agent.* 2>/dev/null); do
   SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1
   case $? in
      0|1) export SSH_AUTH_SOCK="$sock"; break ;;
   esac
done

# ... your own git fetch/switch, build, then finally exec your real process ...
exec /my-app/start.sh
```

Don't ship this. The real problem isn't the polling code above (that part works) — it's that **there is no ordering guarantee between your entrypoint and `docker-event-daemon`'s dispatch of the credential-setup DAG at all.** Both start the moment Docker reports the container `running`; nothing serializes them unless you build that synchronization yourself, and the snippet above is exactly that hand-rolled synchronization, duplicating logic a hook gets for free. Use a hook instead if you want this credential source — it composes cleanly (see [What the hook script can rely on](#what-the-hook-script-can-rely-on)), with no polling code of your own to get wrong.

**Entrypoint doing git work + a hook that also touches the same repo: same race, general form.** This isn't specific to credentials — it's the same "no ordering guarantee" problem applied to anything else your entrypoint does that a `lifecycle:launch`/`lifecycle:start` hook on the same profile *also* touches (an entrypoint cloning a repo while a hook independently fetches/switches it, say). Both run concurrently by default; two independently-scheduled processes mutating the same working tree with no lock between them is a recipe for corruption or non-deterministic outcomes, not a convenient division of labour. Pick **one** mechanism (entrypoint *or* hook) per repo, per profile — the example profiles on this page each use exactly one, deliberately, for this reason.

## 3. What performs the switch

**Your profile's own `command`/`entrypoint`** (the container's PID-1 process) does the checkout itself. Runs exactly once, at container-create time; the only way to re-switch is to recreate the devtainer (a profile's `options` are frozen at creation and can never change afterwards). Needs no Dockside feature beyond `options`/`{option.*}` — see [`04-git-clone-entrypoint.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/04-git-clone-entrypoint.json) and [`06-image-embedded-multi-repo-entrypoint.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/06-image-embedded-multi-repo-entrypoint.json).

**A declared `hooks` script**, dispatched the same way Dockside dispatches its own internal `launch.sh` functions (`docker exec -u <user> <containerId> /opt/dockside/launch.sh <fn>`) — auto-run at launch time (`lifecycle:launch` only on a devtainer's true first launch, `lifecycle:start` on every launch including that one — see [Running it](#running-it) below), and re-runnable on demand at any later point without restarting the container, e.g. after a user changes a devtainer's `ref` option... except a devtainer's options can't actually change after creation either, so in practice this means re-running the *same* switch (useful for a no-`ref` "pull latest" fallback, or to retry a build), or a *different* custom hook entirely (see [Custom hooks](#custom-non-lifecycle-hooks-on-demand-actions-beyond-branch-switching)).

This is the pattern to reach for when a checkout alone isn't "running" the requested ref (your app needs a rebuild and/or a service restart), when you want Dockside-managed credentials (see above), or when a single devtainer spans multiple repos that need coordinated handling and independent on-demand re-triggering.

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

- **Reserved lifecycle names**, namespaced `lifecycle:<event>` — `lifecycle:launch` and `lifecycle:start` (both implemented and in real use today — see [Running it](#running-it) below), plus `lifecycle:stop`/`lifecycle:rename`/`lifecycle:periodic`, reserved for a broader set of lifecycle trigger points that may be added in future. These are schema-valid today even though only `launch`/`start` do anything yet, so a profile can adopt a name now without the schema needing to change shape later — but don't assume the others fire, or that they'll ever be manually runnable the way `launch`/`start` are.
- **Custom names** — anything else: lowercase, starting with a letter, hyphens allowed but not leading/trailing/doubled (e.g. `update`, `repo-status`, `backup`). A profile can declare any number of these with zero Dockside code changes, for whatever on-demand actions your app needs beyond the reserved lifecycle events.

**A reserved lifecycle name only auto-invokes if it's `lifecycle:launch` or `lifecycle:start`** (the two implemented today) — nothing else in `hooks` is ever auto-fired. **A reserved lifecycle name is only manually runnable (`dockside hook run`) if its own entry sets `"manual": true`** — this is opt-in, not automatic, so declaring `hooks."lifecycle:launch"` with `script` alone gets you auto-invoke but *not* on-demand re-invocation; you need `"manual": true` too (the same is true for `lifecycle:start`). Custom names must never set `manual` at all — since nothing ever auto-fires them, they're always manually runnable by construction (setting `"manual": true` on one is rejected as a likely mistake, not silently ignored).

> **Gotcha**: because custom names are unrestricted, a profile can legally declare a bare `"launch"` key (no `lifecycle:` prefix) — it validates fine, but it is an ordinary *custom* hook, not the reserved lifecycle one. Nothing ever auto-invokes it; it only runs via `dockside hook run <devtainer> launch`. This is an easy mistake when migrating an older profile — double-check you meant `lifecycle:launch`, not `launch`.

### What the hook script can rely on

- Runs as the devtainer's own unix user (not root) — use `sudo` inside the script for anything privileged, the same way you would by hand.
- `DOCKSIDE_OPTION_<NAME>` env vars for every option your profile defines (not just `ref` — define whatever option names your app needs, including per-repo ones for a multi-repo app). Same convention a `command`/entrypoint's own PID-1 process now gets too (see [Multi-repo](#multi-repo) below) — this used to be a hook-only convenience; it no longer is.
- `GH_TOKEN`, `GIT_URL`/`SSH_KNOWN_HOSTS_DOMAINS` if this profile also uses `gitURLs`.
- `SSH_AUTH_SOCK` already pointed at a live ssh-agent socket — no setup needed, unlike hand-rolling this in an entrypoint (see [Combinations that don't work](#combinations-that-dont-work)): every hook invocation is its own independent `docker exec` and so never inherits the socket from `spawn_ssh_agent`'s own process tree — `run_hook()` discovers Dockside's managed agent itself before running your script, the same way for both the automatic and on-demand paths.
- Exit code `0` for success, non-zero for failure. `launch.sh` records the outcome as `/tmp/dockside/.hook-ready.<name>` or `.hook-failed.<name>` (scoped by hook name, so two different hooks' sentinels never collide), and (on failure) surfaces a warning via the same mechanism used for other launch-time warnings, visible in the devtainer's IDE/SSH terminal on next login.
- Exit code `2` specifically means "a run was already in progress" (see [Concurrency](#concurrency) below) — not a script failure.
- Your script's own stdout/stderr become this reservation's hook log — visible to anyone with developer-level access to this devtainer: its owner, anyone it's been shared with as a developer, and any Dockside admin permitted to develop other users' devtainers. So while an automatic `lifecycle:launch` run is triggered by Dockside itself on the devtainer's first launch, its log is later readable by that same developer-access group, the same as for a `dockside hook run` someone triggers directly (`dockside get`'s "Launch hooks" line/`Show log`/CLI equivalent for the automatic case; the live output printed while the command waits for `hook run`). This is the *only* copy Dockside keeps: if your hook's output should also be written to the devtainer's own filesystem, or kept out of Dockside's capture entirely (e.g. because it would otherwise print something sensitive to a shared-but-not-fully-trusted developer), that's currently your hook's own responsibility — redirect it yourself.

### Running it

- **Automatically**, for `lifecycle:launch` and `lifecycle:start` only — no other hook, reserved or custom, is ever auto-invoked. Both run in the same place: after launch-time git/ssh/gh setup for that invocation has completed (i.e. after `.credentials-ready` is touched, and — if this profile also uses `gitURLs` — after any requested ref has been checked out into the cloned repo). They differ in *how often*:
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

## Multi-repo

Nothing above is repo-count-aware, so a multi-repo app just defines one option pair per repo (`alpha_ref`/`beta_ref`, or whatever names fit) and loops over them in whichever script performs the switch. [`05-image-embedded-multi-repo-hook.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/05-image-embedded-multi-repo-hook.json) and [`06-image-embedded-multi-repo-entrypoint.json`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/config/profiles/06-image-embedded-multi-repo-entrypoint.json) are the same two toy repos (baked into a shared demo image — see `app/server/example/images/multi-repo-demo/`), switched by the *identical* script — [`multi-repo-switch-and-serve.sh`](https://github.com/newsnowlabs/dockside/blob/main/app/server/example/images/multi-repo-demo/multi-repo-switch-and-serve.sh) — via a hook in one profile and directly from `command` in the other, so the two profiles' diff is exactly the "what performs the switch" choice and nothing else.

That the two profiles can share one script at all relies on a mechanical detail worth calling out: **`DOCKSIDE_OPTION_<NAME>` env vars now reach a `command`/entrypoint's PID-1 process too, not just a hook's `docker exec` environment.** Previously this wasn't true — an entrypoint had no way to read an option's value except via `{option.<name>}` argv substitution (see `04`'s `$1`-based approach above), because `docker create`'s own `Env` never included them. Both now come from the same place (`Reservation::_option_env_pairs`), so a shell entrypoint can read `$DOCKSIDE_OPTION_ALPHA_REF` exactly the way a hook script always could. `{option.<name>}` argv substitution hasn't gone away — it's still the right (and only) way to feed a value directly into a non-shell binary's own argv (a CLI flag it expects, say) — it's just no longer the *only* way to reach a shell entrypoint's variables.

Multi-repo doesn't change any of the guidance above: each repo still gets exactly one mechanism switching it (entrypoint *or* hook — see [Combinations that don't work](#combinations-that-dont-work)), and the credential-source choice is made once per script, not per repo, unless your app genuinely needs different credentials for different repos.

## Example: Dockside switching its own branch

Dockside's own self-hosting example profiles (`00-dockside.json`, `01-dockside-own-ide.json`, `91-dockside-sysbox.json`, `92-dockside-runcvm.json`) launch images with the Dockside repo already baked in at `/home/dockside/dockside` — no `gitURLs`, so the built-in checkout doesn't apply, and switching branch means rebuilding the Vue client and restarting Dockside's own services, not just a checkout. This is the canonical single-repo "image-embedded, hook-driven" example (repo choice 1 + switch choice 3 from the top of this page): they declare `"hooks": {"lifecycle:launch": {"script": ".../dockside-self-update.sh", "manual": true}}` (the `"manual": true` is what makes `dockside hook run` able to re-trigger it later, not just the automatic once-per-launch invocation), wired to [`app/scripts/hooks/dockside-self-update.sh`](https://github.com/newsnowlabs/dockside/blob/main/app/scripts/hooks/dockside-self-update.sh). This is deliberately on `lifecycle:launch`, not `lifecycle:start`: `ref` can never change after the devtainer is created, so checking it out is inherently one-shot, and the no-`ref` fallback below (`git pull --ff-only`) is deliberately opt-in via on-demand `dockside hook run` rather than forced on every plain restart — a profile that genuinely wants an automatic pull on every resume should use `lifecycle:start` for that instead.

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

sudo s6-svc -r /etc/service/nginx
sudo s6-svc -r /etc/service/docker-event-daemon
sudo s6-svc -r /etc/service/app-server
```

(Elided above: `resolve_tree_branch()`'s body, IDE-bundled `git`/`gh` binary paths, and log lines — see the real script for the full version.) This reuses the restart sequence documented for manual use in this repo's own `CLAUDE.md` (all three services that load `app/server/lib`, since a repo update can change server Perl as well as the client build — **and note each of those three `s6-svc` calls needs its own invocation**: `s6-svc`/`s6-svstat` accept exactly one `servicedir` argument each, and silently restart/check only the first if given several on one command line; app-server's own `down-signal` file makes its `-r` deliver `SIGQUIT` for a graceful drain, unlike the other two — see CLAUDE.md's own restart matrix for why), and consumes the same single `ref` option as `03-git-repo.json` — via a hook instead of `launch.sh`'s built-in checkout, since a bare checkout alone would leave the previous branch's build still running.

**Why `--force`/`reset --hard` for the branch/PR switch, but plain `git pull --ff-only` for the no-`ref` fallback?** Because this hook only ever *auto*-fires once, on this devtainer's true first start (`lifecycle:launch`, not `lifecycle:start` — see above): switching to a *different* requested ref has no prior local work of the user's own to protect on that ref, so unconditionally converging a pre-existing local branch of that name (e.g. one baked into the image) onto the just-fetched remote tip is safe and intended. Pulling the *current* branch is a different case even here — it's the branch this devtainer has actually been running, which may carry real local commits (from image build time, or from an earlier manual `dockside hook run`) worth protecting, so it stays fail-loud-not-destructive. The same reasoning applies to any hook you wire to `lifecycle:launch` yourself: prefer `reset --hard`/`--force` when switching to a ref this devtainer couldn't have done real work on yet; prefer `--ff-only` for anything that touches a branch it may already have been running — and always `--ff-only` for a hook wired to `lifecycle:start`, since by definition it can run again on a devtainer with genuine history since the last invocation.

## Custom (non-lifecycle) hooks: on-demand actions beyond branch switching

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

Triggered the same way as any other on-demand hook — `dockside hook run my-devtainer update` — whether run by a developer or by an external caller such as a CI pipeline. The credential the script uses to authenticate to git is entirely the profile author's choice, same as for any other hook on this page: reuse the calling user's own git/gh credentials (this is the default for every hook, custom or lifecycle, with no extra configuration), or bind-mount a separately-provisioned read-only deploy key if you'd rather not depend on a specific person's credentials for a routine, automatable action. Dockside's authorization model doesn't need to know which — the `runContainerHooks` permission plus ordinary `develop` access to the devtainer governs who may call `dockside hook run` at all, entirely independent of what credential the hook script itself decides to use.
