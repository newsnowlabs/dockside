# ADR-0005: dockside-network-firewall daemon design

- **Status:** Implemented — landing with the `devel-sandbox` merge
- **Date:** 2026-07-09
- **Deciders:** Struan Bartlett
- **Provenance:** Distilled from the branch's original design document
  (`PLAN-firewall-daemon-python.md`, March 2026) and the shipped code. Some details
  changed between plan and implementation (e.g. `gateway_ip`/`gateway_mac` were renamed
  to `dockside_ip`/`dockside_mac`, and runtime add/remove of individual networks/ipsets
  was added after the plan was written); this ADR reflects what shipped, not the
  original draft.

## Context

Dockside previously relied on a bash script (`dockside-network-firewall.sh`) to build
per-network iptables/ipset rules for devtainer workspaces. It rebuilt rules by flushing
and repopulating `DOCKER-USER` in place — a window during which forwarded traffic had no
Dockside-managed policy applied, and a crash mid-rebuild could leave the firewall
partially applied. The replacement daemon
(`app/sandbox/dockside-network-firewall.py`) needed the same operational contract
(systemd `Type=notify` service, config-file driven) with none of the failure windows.

## Decisions

1. **`DOCKSIDE-DISPATCH` indirection chain, added once, never flushed.** Dockside owns
   exactly one jump rule in `DOCKER-USER` (`-j DOCKSIDE-DISPATCH`), installed once at
   startup and never removed during normal operation. Every subsequent rule rebuild only
   touches Dockside-owned chains beneath that jump — `DOCKER-USER` itself, and Docker's
   own chains, are never touched again. Reconfiguration is isolated from Docker's own
   chain management.

2. **Atomic rebuild via a single `iptables-restore --noflush` call.** Rather than
   incrementally adding/removing individual rules with `iptables -A`/`-D` (the bash
   script's approach), the daemon regenerates the full ruleset for all Dockside-owned
   chains as text and applies it in one `iptables-restore --noflush` call — only the
   chains explicitly listed are flushed and rebuilt, Docker's own chains are untouched.
   This eliminates the open-firewall window the bash script had between flushing and
   repopulating rules: the ruleset transitions from old to new in one step.

3. **Two-layer FORWARD-chain safety net.** Both an explicit `FORWARD DROP` policy
   enforcement at startup, and a terminal `DROP` for any Dockside-bridge traffic not
   explicitly dispatched above, are enforced on every apply. Even if Docker's default
   policy were ever different than expected, or a rule-generation bug left a gap,
   unmatched traffic on a Dockside-managed bridge still fails closed.

4. **`SIGTERM` leaves iptables/ipset state in place; teardown is a separate, explicit
   operator action.** A daemon restart (`systemctl restart`) doesn't tear down and
   rebuild the firewall from empty — the kernel's ruleset persists independently of
   whether the daemon is running, and the next startup's atomic apply (decision 2)
   rebuilds over whatever's already there with no gap. Full removal (`--teardown`) is a
   distinct, deliberate mode — not something a routine restart or crash can trigger by
   accident.

5. **Two-phase apply for runtime reconfiguration.** The management socket's
   `set-network`/`remove-network`/`set-ipset`/`remove-ipset`/`reconcile` actions can
   change the running config without a restart. Phase 1 atomically rebuilds everything
   the *new* config needs (decision 2); only once that's committed does Phase 2 compute
   what was removed and clean up orphaned chains/ipsets — deferring cleanup of a removed
   network's chains if containers are still attached to it, so a config change alone
   never drops a live connection.

6. **File-based config with an optional runtime socket, not socket-only.** Two JSON
   files (`network-config.json`, `firewall-config.json`) fully describe the daemon's
   config and are the only inputs it needs to function — an admin can edit them and
   restart, identical in operational model to the original bash script. The Unix-domain
   management socket is strictly additive: it lets the same config be queried/mutated at
   runtime without a restart, and is disabled entirely unless a socket path is
   explicitly configured.

7. **No third-party dependencies.** Python 3.6+ stdlib only (`subprocess`, `socket`,
   `threading`, `json`, `ipaddress`) — the daemon shells out to
   `iptables-restore`/`ipset`/`docker` rather than linking a netlink/iptables library.
   This keeps the footprint minimal for a host-level daemon that has to run reliably as
   root, with no Python environment/dependency install step of its own.

8. **Alpine, not Debian, as the image's base.** Measured directly rather than assumed:
   an Alpine build with `python3`/`iptables`/`ip6tables`/`ipset`/`util-linux`/`docker-cli`
   came to ~90MB; the equivalent Debian build came to ~384MB, because Debian's `docker.io`
   package bundles the full Docker Engine (`dockerd`+`containerd`+`runc`, ~254MB) when this
   container only ever talks to the host's mounted `docker.sock` as a client. Alpine's
   `docker-cli` package is correctly scoped to just the client, with no extra apt-repo
   setup needed (Debian's CLI-only `docker-ce-cli` package requires adding Docker's
   upstream repo, as the main image already does). All required tool versions were
   verified equal or newer on Alpine (e.g. `nsenter` from genuine `util-linux`, not a
   busybox stand-in).

9. **`dockside_ip`/`dockside_mac` (ING exemption) and `dockside_egress`
   (OUT-chain exemption) are separate, independently-set fields, not one
   combined toggle.** The original implementation keyed both effects off the
   presence of `dockside_ip`/`dockside_mac`: setting either one both (a)
   whitelisted that MAC/IP to open new intra-network connections in the ING
   chain (needed for the reverse proxy) and (b) unconditionally excluded that
   traffic from the network's OUT chain, so devtainer egress rules could never
   apply to the dockside container's own traffic. These are different
   concerns — (a) is "who may initiate connections on this bridge," (b) is
   "does egress policy apply to this identity" — and conflating them made it
   impossible to express "let dockside reverse-proxy here, but also police its
   own egress" without a code change. `dockside_egress` (`"exempt"` default,
   or `"policed"`) now controls (b) independently; `dockside_ip`/`dockside_mac`
   control only (a). `"exempt"` is a deliberate placeholder, not a
   settled design: every shipped example leaves it at the default because
   nobody has yet inventoried what the dockside container's own egress on a
   managed network actually needs (DNS, ACME, etc.) — `"policed"` is only
   safe to switch to once that inventory exists and rules cover it. There was
   no backwards-compatibility constraint on this change (only two production
   installations exist, both operator-controlled), so the split was made
   directly rather than staged behind a compatibility shim.

## Consequences

Every rule rebuild is all-or-nothing at the kernel level — there is no partial-apply
state to reason about. The full pre-landing development history (including the original
plan document this ADR distills) is preserved at `raw/devel-sandbox`; chain-by-chain
detail lives in the code's own docstrings, not duplicated here.
