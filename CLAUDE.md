# Repo Notes

- `./test.sh` runs the full static suite (Perl compile, Vue build, ESLint, StyleLint,
  ShellCheck, JSON/YAML, Python compile) — run it regularly, not just for Perl.
  `./test.sh --only <check>` runs a single check (e.g. `--only perl` while iterating on
  Perl under `app/server/lib` or `app/server/bin`; `--only vue`, `--only eslint`, …).
- When validating Perl server changes on this local Dockside host, restart:
  - `sudo s6-svc -t /etc/service/nginx`
  - `sudo s6-svc -t /etc/service/docker-event-daemon`
- Before running tests that exercise **server** changes, restart the services above —
  the running server is **not** auto-reloaded. Rebuild the Vue bundle
  (`cd app/client && npm run build`) for **client** changes.
- Integration suite invocation (local mode). Authenticate the CLI once first if not
  already done — the hostname depends on your environment:
  - **Personal laptop/server running Dockside:** `www-<name>.local.dockside.dev`
  - **Inner Dockside dev container inside an outer production Dockside:** your inner
    container's public hostname (e.g. `www-<name>.staging.dockside.example.com`)
  ```
  dockside login --connect-to 127.0.0.1 --no-verify --nickname local \
    --server https://www-<name>.<your-domain>/
  ```
  Then run (host is inferred from the stored session; GitHub token needed only for module 06):
  ```
  DOCKSIDE_TEST_MODE=local \
    DOCKSIDE_TEST_GITHUB_TOKEN=$(/opt/dockside/system/latest/bin/gh auth token) \
    bash t/integration/run_tests.sh [--only NN]
  ```
  Run modules individually with `--only NN` for targeted testing.

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

- **Server Perl** loads from the repo (`perl_modules …/app/server/lib`) → just restart the services.
- **`launch.sh` / IDE assets** come from `/opt/dockside` → deploy as `entrypoint.sh` does, e.g.
  `sudo cp app/scripts/container/launch.sh /opt/dockside/bin/launch.sh` (back up first); the
  change then reaches newly-launched devtainers.

With `mountIDE: true` the full suite still runs, but it exercises the **outer** Dockside's
`launch.sh`/IDEs — so repo `launch.sh`/IDE changes aren't reflected there; test those under a
`mountIDE: false` env or by rebuilding the image.

## Writing integration tests (hard rules)

`t/integration` tests drive the product **only through the `dockside` CLI** (run as a
subprocess via `DocksideClient` in `t/integration/lib/dockside_test.py`). See
`t/integration/README.md` for the full guide. The hard rules:

1. **Call the CLI; never import it.** Do not `import dockside_cli` or call its functions
   from a test or the harness — interact via `DocksideClient._run(...)` / `check_url(...)`
   and the `create`/`update`/… wrappers.
2. **Missing capability → upgrade the CLI.** If a test needs something the CLI can't do,
   add the command/flag to `cli/dockside_cli.py` and call it. Never hand-roll raw HTTP
   against the server or copy CLI internals into a test.
3. **No pre-existing fixtures.** All users/roles/profiles are created at runtime by the
   harness/tests via the CLI and cleaned up — never rely on static config files.
4. **Browser-only surfaces are verified manually** (e.g. the Vue profile `_json` blob, the
   SSH editor), not in the CLI-driven suite.
5. The harness may keep self-contained low-level helpers (e.g. the anonymous `http_check`),
   but these belong to the harness and never import the CLI.
