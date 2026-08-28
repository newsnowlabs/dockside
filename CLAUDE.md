# Repo Notes

- `./test.sh` runs the full static suite (Perl compile, Vue build, Vue unit tests (Vitest),
  ESLint, StyleLint, ShellCheck, JSON/YAML, Python compile) — run it regularly, not just for Perl.
  `./test.sh --only <check>` runs a single check (e.g. `--only perl` while iterating on
  Perl under `app/server/lib` or `app/server/bin`; `--only vue`, `--only eslint`, …).
- Perl server code runs across **three** independent processes, each loading its own copy of
  `app/server/lib` at startup — a file edit alone changes nothing until the process(es) that
  loaded it are restarted (Perl modules compile once at process start, no hot-reload). Restart
  by what you touched:
  - `app/server/lib/{App,App/Metadata,User,Reservation,Reservation/*,Data,Util,Exception,
    Profile,Containers,Request}.pm`, `app/server/bin/app-server` → **all three, as three
    separate invocations** — `s6-svc` (and `s6-svstat`) take exactly one `servicedir` argument
    each; passing all three paths to a single call silently restarts (or checks) only the
    first and drops the rest with a warning, no error:
    ```
    sudo s6-svc -r /etc/service/nginx
    sudo s6-svc -r /etc/service/docker-event-daemon
    sudo s6-svc -r /etc/service/app-server
    ```
    — these are shared libs `docker-event-daemon` and `app-server` both load directly, and
    `Proxy.pm` (embedded in nginx) also loads `Reservation.pm`/`Data.pm`/`Request.pm`.
    `-r` restarts via whichever signal the service's own `./down-signal` file names, or
    `SIGTERM` if it has none. `app-server` ships a `down-signal` of `QUIT`, so its `-r` is a
    graceful `SIGQUIT` — it's the one process that can have a `create()` chain genuinely in
    flight. `nginx`/`docker-event-daemon` have no `down-signal` file, so their `-r` is a
    plain `SIGTERM`, same as before.
  - `app/server/lib/Proxy.pm`, `app/server/nginx/conf/**` → `sudo s6-svc -r /etc/service/nginx`
    only.
  - `app/server/bin/docker-event-daemon` only → `sudo s6-svc -r /etc/service/docker-event-daemon`
    only.
  - When in doubt, or after any multi-file change, just restart all three — cheap, and the
    single most common self-inflicted "why is my fix not taking effect" bug is one of these
    three processes silently still running the pre-edit code.
- Before running tests that exercise **server** changes, restart the relevant services above —
  the running server is **not** auto-reloaded. Rebuild the Vue bundle
  (`cd app/client && npm run build`) for **client** changes.

## The `dockside` CLI

Needed for two things: running the integration suite, and ad-hoc HTTP checks against a live
instance mid-session (both below). Nothing else in this repo — static checks, restarting
services, editing code — needs a CLI session at all.

### Session setup

**Check for an existing session before assuming there isn't one or that you need
credentials**: run `python3 cli/dockside server list` (or `dockside server list` if it's on
PATH). Recommended usage is for the developer to already be logged in as admin locally and
hand that session to you, so one usually exists — never ask the user for credentials over
chat. If none is found, ask the user whether they'd rather log in themselves (remind them of
the login command below) or have you try it — don't just assume either way.

If asked to try it yourself: the hostname depends on your environment:
- **Personal laptop/server running Dockside:** `www-<name>.local.dockside.dev`
- **Inner Dockside dev container inside an outer production Dockside:** your inner
  container's public hostname (e.g. `www-<name>.dockside-domain.com` — the outer server's
  domain is whatever it actually is, no fixed convention to assume) — derive it rather than
  asking or guessing: `ssl.domains[0]` in `/data/config/config.json` gives the base domain
  (e.g. `<name>.dockside-domain.com`); prepend `www-` to its first label for the actual UI
  hostname (`www-<name>.dockside-domain.com`). Don't trust the container's own "Navigate
  to ..." boot-log line for this — confirmed unreliable: on a real instance it printed a
  `www.<name>...` form (dot, not hyphen) that 400s, while the actual working hostname was
  the hyphenated `www-<name>...` form above.

Admin credentials, if you don't already have them: recover from this container's own
first-boot log rather than guessing or asking over chat (username is always `admin`) —
only present if the password hasn't been rotated since first boot; if this comes back
empty, fall back to asking the user.
```
export DOCKSIDE_PASSWORD=$(docker logs "$(hostname)" 2>&1 | grep -oP "password '\K[^']*")
```
```
dockside login --connect-to 127.0.0.1 --no-verify --nickname local \
  --server https://www-<name>.<your-domain>/ --username admin
```
(`--password` is read from `$DOCKSIDE_PASSWORD` automatically, keeping the secret out of
the process list, unlike passing `--password` directly.)

### Ad-hoc HTTP checks

Use `dockside check-url <URL>` (or `python3 cli/dockside check-url <URL>`), not a handcrafted
`curl` — it reuses the CLI's own already-working session/TLS/connection setup. Confirmed this
session: a raw `curl` against the public hostname hung, while `check-url` against the
identical URL worked immediately.

### Integration suite invocation (local mode)

Once you have a session, run (host is inferred from the stored session; GitHub token needed
only for module 06; `PYTHONUNBUFFERED=1` matters — without it, Python block-buffers stdout
when it isn't a TTY, so TAP output queues up invisibly until exit instead of streaming live,
and a running suite can look hung after "Test environment ready." when it's actually working):
```
PYTHONUNBUFFERED=1 \
  DOCKSIDE_TEST_MODE=local \
  DOCKSIDE_TEST_GITHUB_TOKEN=$(/opt/dockside/system/latest/bin/gh auth token) \
  bash t/integration/run_tests.sh [--only NN]
```
Run modules individually with `--only NN` for targeted testing.

## Commit authorship

Every commit's **Author** must be the real human contributor — never
`Claude <noreply@anthropic.com>`. Credit Claude via a `Co-Authored-By:` trailer instead. Fix an
unpushed bad-author commit with `git commit --amend --author=...`; never rewrite one that's
already shared without explicit sign-off.

## Commit messages

Keep commit messages that land on `main` focused on the current change's *why* — not the
branch's own process history. Drop provenance/lineage narrative that becomes stale or
unreachable once the source branch is deleted, e.g. "Originally authored on `<branch>` (commit
`<hash>`)" or "Rebased directly onto main, reconciling with...". A `Raw-History:` trailer (see
below) is for genuine squash-rewrites, where it points at the one place the discarded pre-squash
history survives; a straight rebase/reword that keeps each commit's own message and hash needs
no such trailer, since nothing is being discarded.

## Checking whether a branch already landed

Before concluding a **multi-commit** branch is unmerged, check for the `Raw-History:` trailer
convention — a squashed/rewritten landing on `main` won't show up via a plain `git diff` or
`git merge-base --is-ancestor` check (it's a deliberate history rewrite, not a rebase). See
`docs/developing/curated-merge-process.md` (detection snippet + the full curated-landing
process) and `docs/plans/branches.md` (current branch inventory).

## Runtime environment & testing capability (check at the start of each session)

What you can test depends on **how this container was launched** — specifically whether its
launch profile sets **`mountIDE: false`**. That property — *not* the profile name (names like
`01-dockside-own-ide` / `00-dockside` are just current examples and may change) — decides
whether `/opt/dockside` is our **own writable** volume or the **outer** Dockside's
**read-only** IDE volume. Detect it at runtime the way `entrypoint.sh` does (check the
**mount flag**, not user `-w` — the dir is root-owned, so writes need `sudo`):

```
grep ' /opt/dockside ' /proc/mounts    # rw = our own volume (mountIDE:false); ro = outer IDE volume
ls -d /opt/dockside.img 2>/dev/null    # present => image-based Dockside container
sudo s6-svstat /etc/service/nginx       # is an inner Dockside server running here?
```

| Launch context | `/opt/dockside` | Deploy `launch.sh`/IDE? | Testing capability |
|---|---|---|---|
| **`mountIDE: false`** + own Dockside (e.g. `01-dockside-own-ide`) | own **rw** volume; `.img` present | **yes**, via `sudo` (like `entrypoint.sh`); propagates to launched devtainers | **full e2e**, including our repo's `launch.sh`/IDE changes |
| `mountIDE: true` + inner Dockside (e.g. `00-dockside`, `03-git-repo`) | outer Dockside's IDE volume, **read-only** | no | full suite runs and **server** changes are testable (Perl loads from the repo), but the `launch.sh`/IDEs exercised are the **outer** Dockside's, not our repo's |
| no inner Dockside (e.g. host, plain container) | outer IDE (ro) or none | no | static (`./test.sh`) + unit only; integration tests must target a separate/remote instance |

**Why `mountIDE: false` is special:** `/opt/dockside` is then this container's own writable
anonymous volume, which Dockside re-mounts at `/opt/dockside` inside every devtainer it
launches. So you can update `/opt/dockside` directly — exactly as a fresh image build +
`entrypoint.sh` + launch would — and test server, `launch.sh`, and IDE changes end-to-end
without rebuilding an image:

- **Server Perl** loads from the repo (`perl_modules …/app/server/lib`) → restart whichever of
  the three services actually loaded what you changed (see the restart matrix above).
- **`launch.sh` / IDE assets** come from `/opt/dockside` → deploy as `entrypoint.sh` does, e.g.
  `sudo cp app/scripts/container/launch.sh /opt/dockside/bin/launch.sh` (back up first); the
  change then reaches newly-launched devtainers.

With `mountIDE: true` the full suite still runs, but it exercises the **outer** Dockside's
`launch.sh`/IDEs — so repo `launch.sh`/IDE changes aren't reflected there; test those under a
`mountIDE: false` env or by rebuilding the image.

**Browser-driven testing (Playwright MCP)**: only present if this container was built from the
`development` Docker stage (`newsnowlabs/dockside:development`), not the plain production
image — it bakes in a Playwright MCP server + headless Chromium for driving the Vue UI directly,
wired via `/etc/claude-code/managed-mcp.json`. Check rather than assume either way:
```
ls /etc/claude-code/managed-mcp.json 2>/dev/null   # present => development image, Playwright MCP configured
```
Confirmed absent in this session's own container — but that's not conclusive either way in
general: this particular container was launched long enough ago to predate `:development`'s
existence, so its absence here reflects the container's age, not its launch profile.

## Writing integration tests (hard rules)

`t/integration` tests drive the product **only through the `dockside` CLI** (run as a
subprocess via `DocksideClient` in `t/integration/lib/dockside_test.py`). See
`t/integration/README.md` for the full guide. The hard rules:

1. **Call the CLI; never import it.** Do not `import dockside` or call its functions
   from a test or the harness — interact via `DocksideClient._run(...)` / `check_url(...)`
   and the `create`/`update`/… wrappers.
2. **Missing capability → upgrade the CLI.** If a test needs something the CLI can't do,
   add the command/flag to `cli/dockside` and call it. Never hand-roll raw HTTP
   against the server or copy CLI internals into a test.
3. **No pre-existing fixtures.** All users/roles/profiles are created at runtime by the
   harness/tests via the CLI and cleaned up — never rely on static config files.
4. **Browser-only surfaces are verified manually** (e.g. the Vue profile `_json` blob, the
   SSH editor), not in the CLI-driven suite.
5. The harness may keep self-contained low-level helpers (e.g. the anonymous `http_check`),
   but these belong to the harness and never import the CLI.
