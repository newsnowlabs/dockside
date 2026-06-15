# ADR-0004: SSH ProxyCommand credential exposure — fix with the wstunnel upgrade

- **Status:** Proposed (deferred — out of scope for the `OtdcG` curated merge; to be
  implemented with the wstunnel v10 upgrade)
- **Date:** 2026-06-15
- **Deciders:** Struan Bartlett

## Context

To reach a devtainer's SSH router, the CLI emits an OpenSSH `ProxyCommand` that runs
`wstunnel`. `_build_ssh_proxy_command` (`cli/dockside_cli.py`) bakes the live session
cookie directly into that command string:

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
   secret-free `ProxyCommand dockside ssh proxy-connect <devtainer> --server … %h %p`; the
   re-invoked CLI loads the stored session at connect time, obtains the credential, writes
   the 0600 headers file, runs the tunnel, and cleans up. This addresses dimension 2 (no
   secret in `~/.ssh/config` / printed output / parent argv). Its *non-negotiable*
   justification is **correctness**: a credential baked into a static config (or a static
   headers file) goes stale on session rotation; only a live process can present the current
   one. Its security contribution is **sprawl reduction**, not a new categorical guarantee.

**Deprioritise** server-side SSH-scoped / time-limited / single-use tokens. Once
`--http-headers-file` removes the process-list exposure and the credential lives only in
same-UID 0600 files, a scoped token buys little: a same-UID attacker can read
`~/.config/dockside/` and take the full session anyway, and the cross-UID hole is already
closed. Its only residual value is against network/server-log capture of the upgrade
request — but the session cookie already traverses that path on every normal request, so it
is marginal and not SSH-specific (it is really a question about the cookie session model in
general).

## Consequences

- **At the current tip the leak persists** — `dockside ssh config` / `ssh proxy-command`
  still embed the session cookie, and `wstunnel` still shows it in `ps`. This is a known,
  accepted state for the `OtdcG` merge, tracked for the wstunnel upgrade.
- The end state (re-invocation + `--http-headers-file`) brings the SSH path's credential
  exposure **down to the existing CLI-session baseline** (a same-UID 0600 file), with **no
  server-side auth change**.
- The wstunnel v10 CLI is a clean break (`wstunnel client …` / `wstunnel server …`
  subcommands and renamed flags), so **both** the client proxy-command generation **and**
  the `wstunnel --server` side must migrate together. Backwards-compatibility (mixed
  old/new wstunnel during rollout, and old saved `~/.ssh/config` blocks that reference the
  old syntax) must be designed before landing.
- The re-invoked `dockside` must be resolvable from `ProxyCommand` (on `PATH`, or an
  absolute path / `python3 …/dockside_cli.py`), run fully non-interactively, and fail
  cleanly when the stored session has expired (prompting a re-`login`).

## Surfaces to migrate together (when this lands)

The wstunnel v10 CLI break means client and server must move atomically. These
surfaces all touch the cookie-bearing tunnel and must be updated in lockstep
(enumerated by the release-readiness review):

- `cli/dockside_cli.py` (`_build_ssh_proxy_command`, ~1144-1160) — replace the
  cookie-bearing `wstunnel` argv with a 0600 `--http-headers-file` and the
  secret-free `dockside ssh proxy-connect` re-invocation ProxyCommand.
- `app/client/src/components/SSHInfo.vue` — replace the v6 `wstunnel` download
  links/flags and the inline cookie-bearing config it renders for the user.
- `cli/README.md` — document the new secret-free generated config, the
  credential-refresh behaviour, and the v10 syntax.
- `docs/extensions/ssh.md` — update client install/version guidance and migration
  steps for old saved v6 `~/.ssh/config` blocks.
- `t/integration/tests/_ssh_test_common.py` and the SSH diagnostics — stop
  treating the generated config as cookie-bearing, test 0600 headers-file cleanup,
  and ensure debug output cannot expose the header-file contents.
- The Docker/server-side `wstunnel` invocation and bundled binaries — migrate the
  client and server syntax together.

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
