# ADR: SSH ProxyCommand credential exposure — fix with the wstunnel upgrade

- **Status:** Implemented — landed with the wstunnel v6→v10 upgrade
  (`devel-20260628-wstunnel-upgrade`)
- **Date:** 2026-06-15
- **Deciders:** Struan Bartlett

## Context

To reach a devtainer's SSH router, the CLI emits an OpenSSH `ProxyCommand` that runs
`wstunnel`. `_build_ssh_proxy_command` (`cli/dockside_cli.py`, since renamed to
`cli/dockside`) bakes the live session cookie directly into that command string:

```
wstunnel --hostHeader=%n --customHeaders='Cookie: <SESSION>' -L stdio:127.0.0.1:%p wss://…
```

That string then escapes through four sinks:

- **printed** by `dockside ssh proxy-command` (terminal scrollback, shell history);
- **persisted** by `dockside ssh config` into the user's `~/.ssh/config` (cleartext, on disk);
- the **parent `ssh` process argv** (`ssh -o ProxyCommand=…`, via `cmd_ssh`);
- the **`wstunnel` child's argv** — `ps` / `/proc/<pid>/cmdline`.

This is not just a test-harness artifact: any user who runs `dockside ssh config` or
`dockside ssh` exposes their session cookie this way.

There are **two independent exposure dimensions**, and they need different fixes:

1. **In-flight / process list.** Without `hidepid`, `/proc/<pid>/cmdline` is world-readable,
   so **another user on the host** can scrape the cookie from `ps`. This is the only
   *cross-UID* exposure.
2. **At-rest / persisted / printed.** The cookie in `~/.ssh/config`, in printed output /
   shell history, and in the parent `ssh` argv. These are same-UID surfaces, but ones that
   users and tools treat as **non-secret** — committed to dotfile repos, synced across
   machines, pasted into issues/chat, captured in CI logs — so the credential is prone to
   *escaping the same-UID/single-machine boundary*.

The credential itself is a full, reusable, long-lived session cookie. The user's stored CLI
session already lives at `~/.config/dockside/` (0600), so any *same-UID* attacker already
has the full session regardless of SSH — which bounds what credential-scoping can buy.

The bundled `wstunnel` is **6.0**, where headers can be passed **only** via `-H /
--customHeaders` on the command line (no env var, no file, no stdin). So with this binary
the cookie *must* appear in wstunnel's argv. Upstream `wstunnel` (erebe/wstunnel) is now
**v10.5.5** and adds `--http-headers-file` ("Send custom headers in the upgrade request
reading them from a file … file is read every time"), which lets the cookie be passed via a
0600 file instead of argv. A wstunnel upgrade is on Dockside's roadmap independently.

## Decision

**Do not fix SSH credential exposure in the `OtdcG` branch.** The clean fix is coupled to
the wstunnel upgrade and to backwards-compatibility work, and the branch is already large.
When the wstunnel upgrade is done, fix it with **two pieces**:

1. **`--http-headers-file` (requires wstunnel v10).** The proxy writes the cookie to a 0600
   temp file and passes `--http-headers-file`, so it never enters wstunnel's argv. This is
   the **one categorical security win**: it closes the cross-UID process-list exposure
   (dimension 1). A 0600 temp file is the same exposure class as the existing
   `~/.config/dockside/` session — no worse.
2. **`dockside`-CLI-as-`ProxyCommand` re-invocation.** `dockside ssh config` emits a
   secret-free `ProxyCommand dockside ssh exec-proxy %n` (shipped as `exec-proxy`, not the
   `proxy-connect` name originally sketched here — same mechanism, different name); the
   re-invoked CLI resolves the owning server from the SSH alias (`%n`), loads the stored
   session, obtains the credential, and writes the 0600 headers file. This addresses
   dimension 2 (no secret in `~/.ssh/config` / printed output / parent argv). Its
   *non-negotiable* justification is **correctness**: a credential baked into a static
   config (or a static headers file) goes stale on session rotation; only a live process can
   present the current one. Its security contribution is **sprawl reduction**, not a new
   categorical guarantee.

   Implementation detail that deviates from the original sketch above: the headers file is
   **persistent and reused**, keyed by server hostname (or by SSH alias when `connect_to` is
   in play), not a one-shot per-connection temp file that gets cleaned up afterwards.
   `exec-proxy` skips the `/getAuthCookies` round-trip entirely when a valid file already
   exists on disk, re-fetching only when it's absent. This trades a small window of
   potential staleness (the file isn't proactively invalidated on session rotation; a stale
   cookie simply fails at connect time and requires a fresh `dockside login`) for avoiding
   an HTTP round-trip on every SSH connection.

**Deprioritise** server-side SSH-scoped / time-limited / single-use tokens. Once
`--http-headers-file` removes the process-list exposure and the credential lives only in
same-UID 0600 files, a scoped token buys little: a same-UID attacker can read
`~/.config/dockside/` and take the full session anyway, and the cross-UID hole is already
closed. Its only residual value is against network/server-log capture of the upgrade
request — but the session cookie already traverses that path on every normal request, so it
is marginal and not SSH-specific (it is really a question about the cookie session model in
general).

## Consequences

- **The leak is fixed for the current (`exec-proxy` / `ssh config`) path.** Neither the
  session cookie nor any other secret appears in `~/.ssh/config`, printed output, the
  parent `ssh` process argv, or the `wstunnel` child's argv/`/proc/<pid>/cmdline`. The
  credential lives only in a same-UID 0600 headers file under
  `~/.config/dockside/wstunnel/`, matching the existing CLI-session baseline (dimension 1
  and 2 both addressed).
- **The deprecated "Legacy" path is an intentional, residual exception.** `SSHInfo.vue`
  still offers a v6, cookie-in-`ProxyCommand` tab for users with old saved
  `~/.ssh/config` blocks; that path still exhibits the original exposure by design, not
  oversight, and is expected to be dropped once the dual-version rollout window closes.
- The end state (re-invocation + `--http-headers-file`) brings the SSH path's credential
  exposure **down to the existing CLI-session baseline** (a same-UID 0600 file), with **no
  server-side auth change**.
- The wstunnel v10 CLI is a clean break (`wstunnel client …` / `wstunnel server …`
  subcommands and renamed flags), so **both** the client proxy-command generation **and**
  the `wstunnel --server` side migrated together, landing as a genuine dual-version rollout:
  the image ships both binaries (`wstunnel` = v10, `wstunnel-v6` = legacy) and the server
  runs both listeners (2223 and 2222) side by side, so old saved `~/.ssh/config` blocks
  referencing the v6 inline-cookie syntax keep working during the transition.
- The re-invoked `dockside` must be resolvable from `ProxyCommand` (on `PATH`, or an
  absolute path), run fully non-interactively, and fail cleanly when the stored session has
  expired (prompting a re-`login`). Confirmed in the shipped implementation.
- **Test coverage landed with this fix:** the existing SSH integration tests
  (`t/integration/tests/09_ssh.py`) already exercise `exec-proxy` end-to-end incidentally,
  since `dockside ssh config` now always emits the `exec-proxy` `ProxyCommand`. Explicit
  tests were added for the wildcard (no-devtainer) `ssh config` block, the `--wstunnel`
  binary-path override, the headers file's 0600 permissions, and the path-traversal guard
  (`_write_wstunnel_headers_file` rejecting a key containing `/`).
- **Deliberately deferred as follow-up work, not silent gaps:** a dedicated test for
  nested/multi-server alias resolution (the bug fixed by `1753e7c`, requiring a
  devtainer-inside-a-devtainer fixture) and an explicit regression test pinning the
  deprecated legacy v6 path to the v6 server.

## Surfaces migrated (landed)

The wstunnel v10 CLI break meant client and server had to move atomically. These
surfaces all touched the cookie-bearing tunnel and were updated in lockstep
(originally enumerated by the release-readiness review):

- `cli/dockside` (renamed from `dockside_cli.py`; `_build_ssh_proxy_command`,
  `_check_wstunnel_binary`, `_write_wstunnel_headers_file`, `_build_wstunnel_client_argv`,
  `cmd_ssh_exec_proxy`) — replaced the cookie-bearing `wstunnel` argv with a 0600
  `--http-headers-file` and the secret-free `dockside ssh exec-proxy` re-invocation
  ProxyCommand.
- `app/client/src/components/SSHInfo.vue` — reworked into three tabs (wstunnel v10+,
  Dockside CLI, and a deprecated Legacy v6 tab), replacing the single v6 inline-cookie
  flow.
- `cli/README.md` — documents the new secret-free generated config, the
  credential-refresh/reuse behaviour, `ssh exec-proxy`, `ssh config`'s wildcard form, and
  the `--wstunnel` binary override.
- `docs/extensions/ssh.md` — updated client install/version guidance and the migration
  note for old saved v6 `~/.ssh/config` blocks.
- `t/integration/tests/_ssh_test_common.py` / `09_ssh.py` — the existing tests already
  exercise `exec-proxy` and the 0600 headers file end-to-end (since `ssh config` now
  always emits the `exec-proxy` ProxyCommand); added explicit tests for the wildcard
  `ssh config` block, `--wstunnel`, the 0600 permission, and the path-traversal guard.
  Nested/multi-server alias resolution and an explicit legacy-v6 regression test remain
  open follow-up items (see Consequences).
- The Docker/server-side `wstunnel` invocation and bundled binaries — the image now
  ships both `wstunnel` (v10, primary) and `wstunnel-v6` (legacy), with the nginx SSH
  router dispatching by URI prefix to the matching server process.

## Alternatives considered

- **Re-invocation alone, against today's wstunnel (no upgrade).** Removes the secret from
  `~/.ssh/config` and printed output immediately and fixes staleness, but leaves the
  process-list (cross-UID) exposure untouched (the cookie is still in wstunnel's argv).
  Viable only as an interim if the persisted-config emission is judged urgent; rejected for
  now because it double-handles the proxy-command generation (reworked again at upgrade).
- **Server-side scoped / time-limited / single-use token.** Real protection against
  process-list / network / replay capture, but low marginal value once `--http-headers-file`
  closes the process-list hole (see Decision). Single-use additionally needs shared
  server-side issued/consumed state — a `flock`-serialised file in Dockside's
  `cacheReadWrite` idiom, with expiry sweeping — disproportionate for the residual it
  covers. Deferred as optional, broader CLI-session hardening.
- **In-process tunnel in the CLI (no wstunnel child).** Keeps the cookie in memory, but the
  client must speak wstunnel's server-side upgrade protocol (path prefix, target encoding),
  making it tightly coupled and version-fragile unless we own both ends. Rejected.
