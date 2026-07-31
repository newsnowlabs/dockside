# ADR-0008: SSH per-connection identity — a minimal dropbear patch, with a no-patch fallback

- **Status:** Proposed — research complete, not yet implemented, not yet
  reviewed in conversation beyond this ADR itself.
- **Date:** 2026-07-31 (revised same day: added OpenSSH-swap and
  patch-dropbear-directly research)
- **Deciders:** Struan Bartlett (pending confirmation)

## Context

`docs/plans/profile-user-env-vars.md` left SSH per-connection identity as an
open question with two candidate options, both unresearched at the time:

- **(i)** Wire identity in via the reverse proxy → wstunnel → dropbear path.
- **(ii)** The user's local SSH config carries an identity value that arrives
  as a session-only env var, via dropbear accepting it.

This ADR researches both against the actual bundled software, then goes
further: whether swapping dropbear for OpenSSH would remove the limitation,
and whether patching dropbear directly is a realistic option — not general
SSH/dropbear folklore in either case.

### What identity signal already exists, and where it stops

`Proxy.pm::get_server_port` resolves a real, authenticated `$User` (via
`Request->authenticate` against the session cookie) for every router-proxied
connection, including the `ssh` router — confirmed by reading the code. Per
ADR-0004, SSH access to devtainers is architecturally always
wstunnel-mediated, so this holds for every SSH session. The nginx config
(`app/server/nginx/conf/sites-available/default`) already has a working
precedent for turning a Perl-computed value into a header on the proxied
request: `perl_set $upstream_cookie Proxy::upstream_cookie;` paired with
`proxy_set_header Cookie $upstream_cookie;`. So getting identity as far as
the HTTP **upgrade request** that nginx proxies to the container's
`wstunnel server` process is straightforward — that part of option (i) is
real and uses existing machinery.

**Where it stops:** `wstunnel server` (`launch.sh`'s `launch_sshd`, running
*inside* the devtainer) is a transport-layer relay — `--restrict-to
127.0.0.1:$DROPBEAR_PORT` forwards raw bytes to a fixed TCP target once the
WebSocket upgrade completes. Nothing in wstunnel's documented feature set
(checked: `-H`/`--http-headers` for the *client* side sending headers,
`--restrict-to` for the fixed forward target; no `cmd://` scheme or
header-to-target-passthrough found) exposes the upgrade request's headers to
whatever it forwards to. And even if it did, there's a harder wall behind
it: **everything past the initial SSH banner exchange is encrypted using
keys negotiated directly between the connecting `ssh`/`dbclient` and
whichever SSH server terminates it.** wstunnel and nginx are relaying opaque
encrypted bytes at that point — they have no cryptographic means to inject a
valid SSH protocol message (like an `env` channel request) into that stream
without being a party to the key exchange, which would mean Dockside
implementing its own SSH-terminating MITM proxy.

**This is not dropbear-specific.** It's a property of the SSH protocol
itself, so it holds identically for OpenSSH's `sshd` — swapping the
in-container SSH server (considered below) would not unlock option (i). The
nginx→wstunnel header leg works; the wstunnel→dropbear (or wstunnel→sshd)
leg cannot carry it into the encrypted session without patching wstunnel to
break its own transparency (real but substantial upstream/maintenance cost)
or building a protocol-aware proxy (disproportionate). **Option (i) is
dropped from further consideration** — not costly, actually blocked.

### Option (ii), against dropbear: not viable as shipped

Checked directly against dropbear's actual source
(`github.com/mkj/dropbear`, `src/svr-chansession.c`, `master`, fetched
twice independently for corroboration). The channel-request dispatcher's
full handled set is `window-change`, `shell`, `pty-req`, `exec`,
`subsystem`, `signal` — with an explicit `/* etc, todo "env", "subsystem"
*/` comment (stale for `subsystem`, accurate for `env`). **Dropbear has
never implemented server-side handling of the SSH `env` channel request.**
A client's `SendEnv`/`SetEnv` values are sent and silently dropped. A
community PR adding this (`mkj/dropbear#205`, "Add support for environment
variables") exists, described as one of the repo's most-requested open PRs
— still unmerged as of this research. Alpine 3.22 (this image's base —
`Dockerfile:15`) packages plain upstream dropbear **2025.88**, installed via
`apk add dropbear` (`Dockerfile:290`), so this applies to the exact binary
Dockside currently bundles.

### Would swapping to OpenSSH avoid this?

Checked rather than assumed, since it's a fair question: OpenSSH's `sshd`
genuinely has server-side capabilities dropbear lacks —
`AcceptEnv`/`SendEnv` (the `env`-request handling dropbear never
implemented) **and** authorized_keys' `environment="KEY=VALUE"` option
(admin-controlled, no client cooperation needed — gated by
`PermitUserEnvironment`, off by default upstream for the same reason
arbitrary-env-injection is a known footgun, but fully controllable in
Dockside's own `sshd_config` since Dockside owns the container image).
**If Dockside ran OpenSSH's `sshd` instead of dropbear, option (ii) would
be straightforwardly buildable, and better than that: `environment=`
sets the value directly without needing a forced-command wrapper at all.**

That capability gap is real, but the cost of getting it is disproportionate
to what's needed:

- `openssh-client-default` is already installed (`Dockerfile:290`) — but
  that's the **client** tools (`ssh`, `ssh-add`, `ssh-agent`,
  `ssh-keyscan`, used for outbound git/SSH), not `sshd`, the server. The
  server binary and its runtime dependencies (`libcrypto`/`libssl`, `zlib`,
  optionally PAM) are not currently part of the image at all — this would
  be a genuinely new dependency, not a config flip.
- Dropbear's small size and minimal dependency footprint is very likely why
  it was chosen for a per-devtainer, frequently-launched, container-bundled
  SSH daemon in the first place (this is dropbear's whole design purpose,
  versus OpenSSH's broader feature surface and heavier runtime). Replacing
  it changes image size, startup cost, and operational surface (host keys,
  privilege separation, `sshd_config`, moduli, PAM stack decisions) for
  every devtainer going forward, to solve a problem that — as the next
  section shows — has a much smaller fix available.
- The existing SSH integration tests (`t/integration/tests/09_ssh.py`,
  `10_ssh_outbound.py`) and `docs/adr/0004` are all written against
  dropbear + wstunnel's current behavior; a server swap is a surface far
  wider than this ADR's actual problem.

**Rejected as disproportionate — the capability gap is real, but a full SSH
daemon swap to reach one authorized_keys parsing feature is a much bigger
lever than the problem needs.** Recorded here so it isn't silently assumed
impossible; it's a live option if a *different* future reason to prefer
OpenSSH ever comes up.

### Patching dropbear directly

First, a correction to the premise this research started from: **Dockside's
Dockerfile does not currently patch dropbear.** `Dockerfile:290` installs it
via plain `apk add dropbear` (Alpine's prebuilt binary package); the only
thing done to it afterwards is `patchelf`-based binary relocation via the
existing `BUNDELF_BINARIES` bundling step (`Dockerfile:295`), which rewrites
the binary's RPATH/interpreter so it's portable into `/opt/dockside` — a
portability rewrite, not a behavioral patch. There is no vendored dropbear
source, no `.patch`/`.diff` file, and no `dropbear`-named file anywhere else
in the repo (checked). What *is* true, and useful: this BUNDELF step is
already Dockside's established pattern for taking a binary and preparing it
for this exact bundling/relocation model, and the build stage that installs
dropbear already has `make gcc g++` installed (`Dockerfile:290`) — the exact
toolchain needed to build dropbear from source instead of `apk add`ing it,
with no new build dependencies. Building from a released source tarball
needs only `./configure && make` (no `autoconf`/`autoheader`, which are only
needed if `configure.ac` itself is edited — an unpatched-`configure.ac`,
add-new-C-code patch doesn't need them) plus `zlib`, already present.

**What a minimal patch would actually add.** Checked dropbear's
authorized_keys option parser directly
(`src/svr-authpubkeyoptions.c`, `svr_parse_pubkey_options()`). The full set
of options it recognizes today: `no-port-forwarding`,
`no-agent-forwarding`, `no-X11-forwarding`, `no-pty`, `restrict`,
`command=`, `permitopen=`, `permitlisten=`, `no-touch-required`,
`verify-required`. `command=`'s handling is the exact pattern needed: the
parser reads a quoted value into a buffer and stores it
(`pubkey_options->forced_command = m_malloc(...); memcpy(...)`) on the
per-key options struct, which persists through to session start. A new
option — e.g. a Dockside-specific `dockside-identity="<token>"`, not
upstream's generic `environment=` — would follow the identical pattern:
recognize the prefix, copy the quoted value onto a new struct field, apply
it (a single `setenv()`) when that key's session starts. This is materially
**smaller and more surgical** than `mkj/dropbear#205`'s general
SendEnv/AcceptEnv feature (~68 lines across 4 files, and the maintainer
pushed back on it in review — `"plain unsigned doesn't match existing code
style"`, `"Don't write tricky code"` re: bitshift use, `"This pointer
arithmetic looks too risky"`, and an open question about whether its
`putenv` usage leaks memory). A `command=`-shaped, single-fixed-purpose
option sidesteps all of that: no client-supplied arbitrary variable names,
no arbitrary count of variables, no `putenv`/buffer-reuse pattern to get
subtly wrong — it is one more `if (option matches "dockside-identity=")`
branch parsing exactly the way `command=` already does, immediately next to
it in the same file.

**This also has a real capability advantage over both the OpenSSH
`environment=` idea and this ADR's own forced-command-wrapper fallback
(below): it is entirely server-authored.** The value comes from Dockside's
own `update_ssh_authorized_keys`, never from anything the connecting client
sends — unlike OpenSSH's `SendEnv`/`AcceptEnv` model, there is no
"client proposes a value, server checks an allowlist" trust question to
reason about at all, because the client never proposes anything.

**A real gap versus the forced-command-wrapper fallback, checked directly:**
`command=`'s logic (and so this ADR's wrapper mechanism, and — if it hooked
into the same code path — a naively-implemented `dockside-identity=`) only
fires inside `sessioncommand()`, which is reached only when a client opens a
*session* channel (`shell`/`exec`/`subsystem`). A client that opens **only**
a port-forwarding channel (`ssh -N -L ...`, tunnel-only, no shell) never
reaches that code path at all — confirmed by reading `svr-chansession.c`'s
channel-request dispatch. A patch that applies the identity value at
**auth-success time** (right after `svr_parse_pubkey_options` succeeds for
that key, independent of which channel types get opened afterwards) does
not share this gap; a patch that piggybacks on the existing `command=`
apply-point does. This is a real design choice within "patch dropbear," not
just a patch-vs-no-patch question — worth being deliberate about which
apply-point the patch uses. In practice this gap may not matter (a
tunnel-only connection runs no shell process that could consume an identity
env var anyway), but it's a materially different guarantee and should be a
conscious choice, not an accident of which function was easiest to hook.

**Ongoing cost, stated plainly:** a source patch means Dockside now
builds dropbear from source and carries a diff that needs periodic rebasing
whenever Alpine's dropbear package (and thus the version this patch targets)
moves — a real, ongoing maintenance line-item, not a one-time cost. This is
the "even if one is costly" case the research was asked to consider.

## Decision

**Prefer a minimal dropbear source patch adding a single-purpose,
server-authored authorized_keys option (e.g. `dockside-identity=`), applied
at auth-success time rather than piggybacked on `command=`'s session-channel
apply-point. Keep the forced-command-wrapper mechanism (no patch required)
as a documented fallback if carrying a source patch is judged not worth the
ongoing maintenance cost.** Both require the same `AUTHORIZED_KEYS`
restructuring in `Reservation::exec`/`update_ssh_authorized_keys` described
below; they differ only in what dropbear does with the per-key value once
it's there. Proposed for confirmation, not yet a settled decision — this
ADR intentionally keeps both live rather than collapsing to one, per the
"one winning option, or two viable options" brief this research was
commissioned under.

**Both routes need the same prerequisite change**, since `Reservation::exec`
currently discards per-account key ownership before it reaches the
container:

- `Reservation::exec` currently builds `@authorized_keys` via
  `unique map { @{$_->authorized_keys()} : () } @Users` — flattening,
  sorting, and deduplicating every authorized account's keys into one bare
  array (`"--env=AUTHORIZED_KEYS=$keys_json"`), discarding which account
  owns which key.
- `launch.sh::update_ssh_authorized_keys` writes that array's entries
  verbatim, one per line, with no key options.

Both need to change to `{username, key}` pairs and per-line options instead
of a flat key list — this part of the work is identical regardless of which
route below is chosen.

- **Patch route:** each line becomes
  `dockside-identity="<token>" <key>`, applied by the patched dropbear
  directly — no wrapper script needed.
- **No-patch fallback route:** each line becomes
  `command="<wrapper> <token>" <key>`; a small wrapper (shipped in the
  image) sets the session env var and execs `$SSH_ORIGINAL_COMMAND` (or an
  interactive shell if empty) — inherits the port-forward-only gap noted
  above.

**Critical requirement, independent of which route is chosen:** the value
delivered must be an **unforgeable, session-scoped bearer credential, not a
plaintext identity claim.** A bare env var is not tamper-evident — any
process running inside that session (the connecting user's own later
commands, or, in a shared devtainer, anything a co-located collaborator's
process can reach) can trivially `export` a different value into its own
children. If either route just sets `DOCKSIDE_SSH_IDENTITY=<plaintext
username>`, anything in that session can impersonate any other authorized
account when querying the metadata server — worse than not having this
mechanism at all. `launch.sh`/`update_ssh_authorized_keys` (or
`Reservation::exec`, wherever the token is minted) must instead generate an
unguessable, server-verifiable token bound to (reservation, account, ideally
a short expiry), and the metadata server (ADR-0005) must validate that token
against its own record of what it minted, never merely trust whatever value
arrives in the env var. This requirement is unchanged by, and more
important than, the patch-vs-no-patch choice above.

## Consequences

- Either route requires the same `Reservation::exec` /
  `update_ssh_authorized_keys` restructuring (shape of the JSON blob, and
  per-line option emission instead of bare keys) — scoped, not large, but
  not nothing, and shared regardless of which route is chosen.
- **Patch route** additionally requires: building dropbear from source
  instead of `apk add`ing it (mechanically compatible with the existing
  build stage — `make`/`gcc`/`g++` already present, no `autoconf` needed for
  a `configure.ac`-untouched patch), carrying and periodically rebasing the
  patch against Alpine's dropbear version as it moves, and choosing the
  auth-success apply-point deliberately (not defaulting to `command=`'s
  session-channel-only apply-point) if the port-forward-only gap matters.
- **No-patch fallback route** additionally requires: the wrapper script
  itself (shipped in the image, no source patch), and accepting the
  port-forward-only gap as a known, probably-inconsequential limitation
  (confirmed via source: `sessioncommand()`/`command=` logic never runs for
  a connection that opens no session channel).
- **Known limitation, either route:** if two different accounts have
  uploaded the literal same public key (unusual, not prevented today), only
  one line's binding can apply to that key — whichever authorized_keys line
  is matched first. Pre-existing identity-hygiene edge case, not introduced
  by this mechanism.
- This closes the transport gap for `ssh` only, either route. It does
  nothing for `ide` (ADR-0007's shared-single-process limitation stands).
- Once built, this is the missing second factor referenced in ADR-0005's
  Consequences: the metadata server can validate the session token and
  scope its response to the actual connecting account rather than always
  the reservation owner, for the `ssh` path specifically.
- Sequenced after ADR-0005's metadata-server endpoint exists (nothing to
  validate the token against otherwise) and is independent of ADR-0006/0007.

## Alternatives considered (superseded or rejected by research)

- **(i) Reverse-proxy → wstunnel → dropbear (or wstunnel → sshd) plumbing.**
  The nginx-to-wstunnel leg is real (reuses the existing
  `perl_set`/`proxy_set_header` `Cookie`-forwarding pattern); the
  wstunnel-to-server leg is blocked by (a) wstunnel's actual feature set (no
  header-to-target passthrough) and (b) SSH's own transport encryption,
  which makes injecting a protocol message into an already-negotiated
  session from outside the SSH stack infeasible without a full MITM SSH
  proxy — confirmed to hold identically for OpenSSH, not a dropbear
  limitation. Rejected — not costly, actually blocked.
- **(ii) Client-side `SetEnv`/`SendEnv` against dropbear as-is.** Rejected
  outright: dropbear (2025.88, unpatched, as bundled) has never implemented
  the SSH `env` channel request server-side. Nothing to configure — the
  feature doesn't exist in the running software. Revisit only if
  `mkj/dropbear#205` merges upstream and Dockside's Alpine base picks up a
  release containing it.
- **Swap dropbear for OpenSSH's `sshd`.** Would genuinely unlock
  `AcceptEnv`/`SendEnv` and authorized_keys `environment=` — a real
  capability dropbear structurally lacks. Rejected as disproportionate: a
  new server binary and dependency chain (`sshd` isn't currently bundled at
  all, only OpenSSH's client tools are), likely chosen against originally
  for size/footprint reasons that still apply, and a much bigger lever than
  the one authorized_keys parsing feature this problem actually needs.
  Recorded as a live option if a different, independent reason to prefer
  OpenSSH ever arises.
- **General `environment=` support in dropbear (mirroring OpenSSH's
  semantics) instead of a narrow, single-purpose option.** Rejected in
  favor of the narrower `dockside-identity=`-style design: general
  client-influenced-name env support reopens the exact trust questions
  OpenSSH itself gates behind `PermitUserEnvironment` (off by default
  upstream for good reason), for no benefit here — Dockside only ever needs
  to deliver one, server-authored value.
