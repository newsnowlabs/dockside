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
- Integration suite invocation (local mode, SSH container access, real GitHub token):
  ```
  DOCKSIDE_TEST_MODE=local DOCKSIDE_TEST_HOST=www-<name>.local.dockside.dev \
    DOCKSIDE_TEST_CONTAINER_ACCESS=ssh \
    DOCKSIDE_TEST_GITHUB_TOKEN=$(/opt/dockside/system/latest/bin/gh auth token) \
    bash t/integration/run_tests.sh [--only NN]
  ```
  The full suite can be flaky under load (resource contention); run modules individually
  with `--only NN` for reliable results.

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
