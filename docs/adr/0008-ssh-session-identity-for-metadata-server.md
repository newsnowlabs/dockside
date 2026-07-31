# ADR-0008: SSH per-connection identity — a minimal, auth-gated dropbear patch

- **Status:** Accepted — not yet implemented. Research has converged on a
  single mechanism (earlier revisions of this ADR kept a no-patch fallback
  "live"; that fallback was subsequently found to be insecure, not merely
  costlier — see below).
- **Date:** 2026-07-31 (revised: dropped the forced-command-wrapper fallback
  after finding it's forgeable by any co-located session; added the `/proc`
  cross-session read risk and required mitigation; added `reservation_id` to
  the minted token to serve ADR-0005's single-shared-socket design)
- **Deciders:** Struan Bartlett

## Context

`docs/plans/profile-user-env-vars.md` left SSH per-connection identity as an
open question with two candidate options, both unresearched at the time:

- **(i)** Wire identity in via the reverse proxy → wstunnel → dropbear path.
- **(ii)** The user's local SSH config carries an identity value that arrives
  as a session-only env var, via dropbear accepting it.

This ADR researches both against the actual bundled software, considers
swapping dropbear for OpenSSH, evaluates patching dropbear directly, and —
in this revision — closes two gaps found only once the mechanism was
scrutinized further in conversation: a forgery hole in the no-patch
fallback this ADR originally kept alongside the patch, and a cross-session
`/proc` read risk affecting wherever the resulting token ends up.

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
`environment=` idea and the forced-command wrapper this ADR originally kept
as a fallback (see "Why the wrapper route is rejected outright" below): it
is entirely server-authored.** The value comes from Dockside's own
`update_ssh_authorized_keys`, never from anything the connecting client
sends — unlike OpenSSH's `SendEnv`/`AcceptEnv` model, there is no
"client proposes a value, server checks an allowlist" trust question to
reason about at all, because the client never proposes anything.

**Apply-point matters: auth-success, not `command=`'s session-channel
dispatch.** `command=`'s logic only fires inside `sessioncommand()`, which
is reached only when a client opens a *session* channel
(`shell`/`exec`/`subsystem`). A client that opens **only** a
port-forwarding channel (`ssh -N -L ...`, tunnel-only, no shell) never
reaches that code path at all — confirmed by reading `svr-chansession.c`'s
channel-request dispatch. The patch must apply the identity value at
**auth-success time** (right after `svr_parse_pubkey_options` succeeds for
that key, independent of which channel types get opened afterwards), not
piggyback on `command=`'s apply-point, so this gap doesn't apply here — a
port-forward-only connection still gets the identity value minted and set
before any channel-type branching, even though (in practice) there's no
shell process in that case to consume it anyway.

**Ongoing cost, stated plainly:** a source patch means Dockside now
builds dropbear from source and carries a diff that needs periodic rebasing
whenever Alpine's dropbear package (and thus the version this patch targets)
moves — a real, ongoing maintenance line-item, not a one-time cost.

### Why the wrapper route is rejected outright, not kept as a fallback

The previous revision of this ADR kept a no-patch fallback: give each key's
authorized_keys line a `command="<wrapper> <token-placeholder>"` binding,
where the wrapper sets a session env var and execs `$SSH_ORIGINAL_COMMAND`.
Scrutinized further, this is not a smaller/costlier version of the same
protection — **it is a complete bypass, trivially available to any
co-located session.**

The wrapper is invoked as `$IDE_USER` — the same shared unix account every
connecting session lands as, whether they authenticated as themselves or
not. It has **no way to distinguish** "I was just invoked by dropbear as
the direct, gated result of a real key authenticating" from "I was manually
re-run by an already-connected user, typing my path and an argument of
their choosing." Both look identical to the script: same user, same binary,
an argv string. A parent-process check doesn't rescue this either — an
attacker's own legitimate, correctly-authenticated shell is *also* a
descendant of dropbear (from their own real connection), so "my parent is
dropbear" is true for a manual re-invocation too. If the wrapper holds, or
can derive, whatever signing capability is needed to produce a valid
credential, then **any connected user can mint a token for any other
identity they can see in `authorized_keys`**, by simply re-running the
wrapper with a different account name as its argument — defeating the
entire point of the mechanism, not weakening it.

The patch route doesn't share this hole, provided (and only provided) one
discipline is followed: the signing secret (`DOCKSIDE_METADATA_HMAC_KEY`,
below) is read once by dropbear from its own **pre-fork** process
environment — inherited from `docker exec`, before any privilege drop to
`$IDE_USER` — used internally to compute the token, and never exported into,
or made readable by, the spawned session. Minting a token this way still
requires the same bar as impersonating anyone in SSH generally: possessing
the private key that authenticates as them, checked by dropbear's own
internal, non-user-invokable code — not a program sitting on disk that
anyone with a shell can run directly.

**The wrapper route is therefore dropped entirely, not kept as a
lower-cost fallback.** There is no viable no-patch alternative that
provides this property; the earlier framing of "one winning option, or two
viable options, even if one is costly" resolves to the former.

### The `/proc` cross-session read risk, and the required mitigation

Once minted, the token has to go *somewhere* the connecting user's own,
later-invoked script can reach it — see "Where the token surfaces," below.
That place is the spawned session's own environment, inherited by
everything it forks. This is exactly the kind of value the rest of this
plan (ADR-0005, ADR-0007) has been concerned about protecting from
*other*, differently-authenticated sessions sharing the same container —
and the same concern applies here: could a different collaborator's SSH
session read this token out of the target session's `/proc/<pid>/environ`?

Researched directly (not assumed) in conversation before this revision:

- Reading `/proc/<pid>/environ` is gated by the kernel's
  `ptrace_may_access()` — same-UID access (which every session here has,
  since all land as `$IDE_USER`) is allowed unconditionally under
  `ptrace_scope=0`, but restricted to actual process ancestry under
  `ptrace_scope=1` (Ubuntu's and many distros' shipped default). This is a
  **host kernel sysctl**, not namespaced per container, and Dockside
  neither sets nor currently checks it — so whether this vector is closed
  depends entirely on the deployment host, which Dockside doesn't control.
- Docker's default capability set (checked: does **not** include
  `CAP_SYS_PTRACE`, and Dockside's `Reservation::Launch::cmdline_security`
  has no `cap-add`/`cap-drop` handling of its own — only a profile's
  `dockerArgs` could add it, and no shipped example profile does) means
  **cross-UID** ptrace access (e.g. a root process reading `$IDE_USER`'s
  environ) is blocked regardless of `ptrace_scope`, and this holds even if
  a connecting user escalates to root *inside* the container via `sudo` —
  the capability **bounding set** is a ceiling fixed at `docker create`
  time that nothing inside the container, including root, can raise.
  This does not, however, help with the **same-UID sibling** case (one
  `$IDE_USER` session reading another's), which is exactly what's at issue
  here, since no capability is needed for that under `ptrace_scope=0`.
- `landrun` (a CLI wrapper around Linux Landlock, `github.com/Zouuup/landrun`)
  closes this regardless of the host's `ptrace_scope`. Landlock's ptrace
  restriction is automatic — not opt-in — for any process inside a Landlock
  domain: *"the tracee must be in a sub-domain of the tracer."* Two
  independently-created, sibling domains (one per SSH session, neither
  nested in the other) satisfy neither direction of that relationship, so
  a landrun-wrapped session cannot read another's `/proc/<pid>/environ`
  regardless of the host's `ptrace_scope` setting — Landlock only adds
  restriction on top of the classic DAC/Yama model, never depends on it.
  This also survives in-session privilege escalation: Landlock restrictions
  are inherited by all descendants and cannot be removed by a later
  `setuid`/`sudo` within the same domain, unlike ordinary DAC permissions.
  Unprivileged by design (no `CAP_SYS_ADMIN` needed), consistent with a
  container that already runs with Docker's default capability set.

**This only works if every connecting session is wrapped, uniformly** — the
guarantee is symmetric: a sandboxed tracer is blocked from reading a
target outside its sub-domain, so *every* session that could plausibly be
an attacker needs to be inside its own independent domain, not just the
one being protected.

## Decision

**Patch dropbear with a single-purpose, server-authored authorized_keys
option (`dockside-identity=`), applied at auth-success time. There is no
recommended no-patch fallback** — see above. As part of the same session
handoff, the patch must exec into a **mandatory, independently-created
Landlock sandbox (`landrun` or equivalent)** before reaching the
connecting user's shell, and must **fail closed** — refuse to hand out the
identity token, or refuse the connection outright — if Landlock support is
unavailable on the host kernel (checked at container/session start, not
silently degraded).

**Prerequisite, shared with the abandoned wrapper design:** `Reservation::exec`
currently discards per-account key ownership before it reaches the
container —

- `Reservation::exec` currently builds `@authorized_keys` via
  `unique map { @{$_->authorized_keys()} : () } @Users` — flattening,
  sorting, and deduplicating every authorized account's keys into one bare
  array (`"--env=AUTHORIZED_KEYS=$keys_json"`).
- `launch.sh::update_ssh_authorized_keys` writes that array's entries
  verbatim, one per line, with no key options.

Both need to change to `{username, key}` pairs, with each authorized_keys
line becoming `dockside-identity="<account>" <key>` — the file carries only
the **account label**, never a secret. Freshness and unforgeability come
from the patch's own minting, not from anything static in the file.

**What the patch mints, and where it comes from:**

- At each devtainer's launch/relaunch, `Reservation::exec` also passes a
  per-reservation signing secret into the container's env — e.g.
  `--env=DOCKSIDE_METADATA_HMAC_KEY=<key>` — alongside the existing
  `AUTHORIZED_KEYS`/`SSH_AGENT_KEYS` env vars. Known only to Dockside's
  server process and this one container; never exposed to any user-facing
  surface. This also passes `--env=DOCKSIDE_RESERVATION_ID=<id>`, or the
  patch is simply told the reservation ID the same way.
- At auth-success, the patched dropbear (still running privileged,
  pre-fork) reads both from its own process environment, generates a fresh
  random nonce (dropbear already has a CSPRNG for its own key-exchange
  operations), and computes a token over
  `reservation_id || account || nonce || expiry`, HMAC'd with the signing
  key — e.g. `DOCKSIDE_SSH_IDENTITY=<reservation_id>.<account>.<nonce>.<expiry>.<hmac>`.
  `reservation_id` is included specifically to serve ADR-0005's
  single-shared-socket metadata transport: since one socket now serves
  every devtainer, the metadata server needs the request itself to say
  which reservation it's for, and this token is what carries that,
  cryptographically bound so it can't be forged independently of the
  matching reservation's own key (see ADR-0005 for the server-side
  verification flow — this ADR mints the token, ADR-0005 defines how it's
  transported and checked).
- **The signing key itself is never exported into the child session** —
  only the derived token is, after the privilege drop and the mandatory
  `landrun` exec.

**Where the token surfaces:** as an environment variable in the connecting
user's login shell (and everything that shell subsequently forks) — there
is no other place a user's own, later-invoked script could reach it from,
since responsibility for actually querying the metadata server is
deliberately left to the user (ADR-0005). This is precisely why the
Landlock requirement above is not optional: the token's confidentiality
*from other sessions in the same shared container* rests entirely on that
sandboxing, not on the delivery mechanism itself. Disabling core dumps for
these sessions (`ulimit -c 0`) is a cheap, complementary step — an
environment variable lives in process memory, and a core dump would
otherwise write it to disk incidentally, defeating "never written to disk"
without any config-writing tool being involved.

## Consequences

- `Reservation::exec` / `update_ssh_authorized_keys` restructuring (shape
  of the JSON blob, per-line option emission instead of bare keys) —
  scoped, not large.
- Building dropbear from source instead of `apk add`-ing it (mechanically
  compatible with the existing build stage — `make`/`gcc`/`g++` already
  present) and carrying/periodically rebasing the patch against Alpine's
  dropbear version as it moves — a real, ongoing maintenance line-item.
- A new bundled dependency: `landrun` (or equivalent Landlock wrapper),
  added to the image's binary set alongside dropbear, `wstunnel`, etc. — a
  small Go binary, consistent in kind with what's already bundled via
  `BUNDELF`.
- A new fail-closed startup check: attempt a trivial Landlock ruleset at
  container/session setup; if it errors (host kernel predates 5.13, or has
  Landlock disabled), refuse to mint/deliver the identity token rather than
  silently degrading to an unprotected one.
- **Known limitation:** if two different accounts have uploaded the literal
  same public key (unusual, not prevented today), only one line's binding
  can apply to that key — whichever authorized_keys line is matched first.
  Pre-existing identity-hygiene edge case, not introduced by this
  mechanism.
- This closes the transport gap for `ssh` only. It does nothing for `ide`
  (ADR-0007's shared-single-process limitation stands — there is no
  per-connection concept inside a running Theia/openvscode process for
  this, or any, mechanism to attach to).
- Once built, this is the missing factor referenced in ADR-0005's
  Consequences — covering **both** halves of what a single shared metadata
  socket needs to know: which reservation is asking (`reservation_id`) and
  which account within it (`account`), from one verified token.
- Sequenced after ADR-0005's metadata-server endpoint exists (nothing to
  validate the token against otherwise) and is independent of ADR-0006/0007.
- Landlock's ptrace-domain protection is specific to `/proc`-based reads.
  It does not touch the separate, still-open risk that a tool the user
  runs persists the *fetched* secret (not this identity token, but
  whatever the metadata server later returns) to a file under the shared
  `$HOME` — see ADR-0007, which this generalizes: ordinary DAC file
  permissions offer no protection at all when every collaborator is the
  same UID, and no amount of transport or `/proc` hardening changes that.

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
- **The forced-command wrapper, as a no-patch fallback.** Kept in the
  previous revision of this ADR as a lower-cost alternative; rejected
  outright once examined for exactly the threat model this mechanism
  exists to address. See "Why the wrapper route is rejected outright,"
  above — it's forgeable by any co-located session, not merely weaker or
  more limited than the patch route.
