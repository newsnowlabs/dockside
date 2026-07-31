# ADR-0008: SSH per-connection identity — forced-command key binding, not env forwarding

- **Status:** Proposed — research complete, not yet implemented, not yet
  reviewed in conversation beyond this ADR itself.
- **Date:** 2026-07-31
- **Deciders:** Struan Bartlett (pending confirmation)

## Context

`docs/plans/profile-user-env-vars.md` left SSH per-connection identity as an
open question with two candidate options, both unresearched at the time:

- **(i)** Wire identity in via the reverse proxy → wstunnel → dropbear path.
- **(ii)** The user's local SSH config carries an identity value that arrives
  as a session-only env var, via dropbear accepting it.

This ADR researches both against the actual bundled software (not general
SSH/dropbear folklore) and reports what's actually buildable.

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
dropbear.** wstunnel and nginx are relaying opaque encrypted bytes at that
point — they have no cryptographic means to inject a valid SSH protocol
message (like an `env` channel request) into that stream without being a
party to the key exchange, which would mean Dockside implementing its own
SSH-terminating MITM proxy. That is a categorically different, much larger
project than "add a header," not a small extension of option (i).

**Option (i), as literally proposed (identity arriving via the wstunnel/proxy
path into the SSH session itself), is blocked by SSH's own transport
security, not by a missing Dockside feature.** The nginx→wstunnel header
leg works; the wstunnel→dropbear leg cannot carry it into the encrypted
session without patching wstunnel to break its own transparency (real but
substantial upstream/maintenance cost) or building a protocol-aware proxy
(disproportionate).

### Option (ii): does dropbear even accept env vars from the client?

Checked directly against dropbear's actual source
(`github.com/mkj/dropbear`, `src/svr-chansession.c`, `master`, fetched
twice independently for corroboration) rather than relying on general SSH
knowledge. The channel-request dispatcher's full handled set is
`window-change`, `shell`, `pty-req`, `exec`, `subsystem`, `signal` — with an
explicit `/* etc, todo "env", "subsystem" */` comment (stale as far as
`subsystem` goes, but accurate for `env`). **Dropbear has never implemented
server-side handling of the SSH `env` channel request.** A client's
`SendEnv`/`SetEnv` values are sent (per the SSH protocol, as a request with
no reply expected) and silently dropped — dropbear never applies them to the
session. A community PR adding this support
(`mkj/dropbear#205`, "Add support for environment variables") exists and is
described as one of the repo's most-requested open PRs — i.e. still
unmerged. Alpine 3.22 (this image's base — `Dockerfile:15`) packages plain
upstream dropbear **2025.88**, installed via `apk add dropbear` with no
Dockside patches (`Dockerfile:290`), so this applies to the exact binary
Dockside bundles, not a hypothetical older version.

**Option (ii), as literally proposed, is not viable today.** It isn't a
configuration gap on Dockside's side (no `AcceptEnv`-equivalent to enable) —
the server-side feature doesn't exist in the software being run.

### A third mechanism dropbear does support

Dropbear's authorized_keys parsing does support **`command=`** — a per-key
forced command, with the client's originally-requested command (or empty,
for an interactive login) exposed to that forced command via
`$SSH_ORIGINAL_COMMAND` — confirmed against dropbear's man page (Debian/Arch
manpages, consistent across distributions) and consistent with the standard
SSH forced-command pattern used elsewhere (`git-shell`, `scponly`, and
similar restricted-shell-via-`command=` tools). `environment=` is not
supported (consistent with there being no `env`-request handling at all),
but `command=` doesn't need it: a tiny wrapper script, forced per-key, can
set a session env var itself before handing off, with no dependency on any
env-passing SSH feature.

This is directly buildable against the current `AUTHORIZED_KEYS`
construction, which already has per-account structure at the point it's
assembled and only discards it right before writing to disk:

- `Reservation::exec` currently builds `@authorized_keys` via
  `unique map { @{$_->authorized_keys()} : () } @Users` — flattening,
  sorting, and deduplicating every authorized account's keys into one
  bare array (`"--env=AUTHORIZED_KEYS=$keys_json"`), discarding which
  account owns which key.
- `launch.sh::update_ssh_authorized_keys` writes that array's entries
  verbatim, one per line, with no key options.

Both would need to change: `Reservation::exec` to emit `{username, key}`
pairs instead of a flat key array, and `update_ssh_authorized_keys` to write
each line as `command="<wrapper> <token>" <key>` instead of bare `<key>`.

**PTY/port-forwarding compatibility, checked:** `command=` only overrides
what runs on the `shell`/`exec` channel dispatch; it does not itself disable
port forwarding or PTY allocation (those are gated by the separate
`no-port-forwarding`/`no-pty` restrictions, not implied by `command=`), so
existing tunneling/interactive-terminal use over SSH is unaffected as long
as neither of those is added.

## Decision

**Recommend the forced-command key-binding mechanism, not either of the
originally-proposed options — proposed for confirmation, not yet a settled
decision.**

Concretely: give each authorized account's key(s) a `command=` binding to a
small wrapper (shipped in the image, invoked by dropbear per-connection)
that sets a session-scoped identity value and then execs
`$SSH_ORIGINAL_COMMAND` (or an interactive shell if empty) — preserving
normal SSH behavior for the connecting user while stamping identity into
that one session before their shell starts.

**Critical requirement, independent of which mechanism was chosen:** the
value the wrapper sets must be an **unforgeable, session-scoped bearer
credential, not a plaintext identity claim.** A bare env var is not
tamper-evident — any process running inside that session (the connecting
user's own later commands, or, in a devtainer with `no-secret`-flagged
sharing, anything a co-located collaborator's process can reach) can
trivially `export` a different value into its own children. If the wrapper
just sets `DOCKSIDE_SSH_IDENTITY=<plaintext-username>`, anything in that
session can impersonate any other authorized account when querying the
metadata server, which is worse than not having this mechanism at all. The
wrapper must instead mint (or the wrapper's caller — e.g. `launch.sh` at
`update_ssh_authorized_keys` time — must pre-mint) an unguessable,
server-verifiable token bound to (reservation, account, and ideally a
short expiry), and the metadata server (ADR-0005) must validate that token
against its own record of what it minted, not merely trust whatever value
arrives in the env var. This requirement, not the transport mechanism, is
the load-bearing part of closing the sharing gap described in ADR-0005's
Consequences.

## Consequences

- No wstunnel changes, no proxy/nginx plumbing changes, no dropbear
  patching — the mechanism uses dropbear's existing, documented,
  currently-shipped feature set.
- `Reservation::exec`'s `AUTHORIZED_KEYS` construction and
  `launch.sh::update_ssh_authorized_keys` both need real changes (shape of
  the JSON blob, and the line-writing logic) — scoped, not large, but not
  nothing.
- **Known limitation, not a blocker:** if two different accounts have
  uploaded the literal same public key (unusual, but not prevented today),
  only one `command=` binding can apply to that key — whichever
  authorized_keys line dropbear matches first. This is a pre-existing
  identity-hygiene edge case (two accounts sharing one key already blurs
  who's who), not introduced by this mechanism.
- This closes the transport gap for `ssh` only. It does nothing for `ide`
  (ADR-0007's shared-single-process limitation stands — there is no
  per-connection concept inside a running Theia/openvscode process for this
  mechanism, or any mechanism, to attach to).
- Once built, this is the missing second factor referenced in ADR-0005's
  Consequences: the metadata server can validate the session token and
  scope its response to the actual connecting account rather than always
  the reservation owner, for the `ssh` path specifically.
- Sequenced after ADR-0005's metadata-server endpoint exists (nothing to
  validate the token against otherwise) and is independent of ADR-0006/0007.

## Alternatives considered (superseded by research)

- **(i) Reverse-proxy → wstunnel → dropbear plumbing.** The
  nginx-to-wstunnel leg is real and reuses an existing pattern
  (`perl_set`/`proxy_set_header`, as used for `Cookie` forwarding today);
  the wstunnel-to-dropbear leg is blocked by (a) wstunnel's actual feature
  set (no header-to-target passthrough) and (b) SSH's own transport
  encryption, which makes injecting a protocol message into an
  already-negotiated session from outside the SSH stack infeasible without
  a full MITM SSH proxy. Rejected as disproportionate — the "cost" here
  isn't implementation effort so much as it requires either forking a
  third-party dependency or building an entirely different class of
  component (an SSH-aware proxy) than Dockside has today.
- **(ii) Client-side `SetEnv`/`SendEnv`.** Rejected outright, not merely
  deprioritized: dropbear (the exact version this image bundles, 2025.88 via
  Alpine 3.22, unpatched) has never implemented the SSH `env` channel
  request server-side. There is nothing to configure or work around — the
  server-side feature does not exist in the running software. Revisit only
  if `mkj/dropbear#205` merges upstream and Dockside's Alpine base picks up
  a dropbear release containing it — worth a periodic check, not a plan to
  build against today.
