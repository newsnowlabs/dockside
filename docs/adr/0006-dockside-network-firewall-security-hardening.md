# ADR-0006: dockside-network-firewall security hardening

- **Status:** Implemented
- **Date:** 2026-07-09
- **Deciders:** Struan Bartlett
- **Provenance:** Distilled from a security review conducted during development
  (`security-review-dockside-network-firewall.md`, March 2026); disposition updated to
  reflect fixes landed since, including one (finding 3) added as part of this landing.

## Context

Before landing, the daemon was audited for malicious logic, unsafe root behaviors, and
implementation defects — appropriate scrutiny for a daemon that runs as root and mutates
iptables/ipset state based on config it reads and, optionally, commands received over a
Unix socket. The review found no malicious behavior, but flagged three concrete risks.

## Findings and disposition

1. **Config values interpolated into `iptables-restore` text without validation (High) —
   Fixed.** Network/chain/ipset names, interfaces, IPs, CIDRs, MACs, protocols, ports,
   ICMP types, and comments were passed into `iptables-restore`'s text format without
   validation. Fix: allow-list validator functions (`_val_identifier`, `_val_iface`,
   `_val_ip`, `_val_cidr`, `_val_mac`, `_val_proto`, `_val_port`, `_val_comment`,
   `_val_icmp_type`, `_val_host_entry`) reject malformed or adversarial values at
   config-parse time, before any kernel mutation is attempted.

2. **Management socket had no peer authentication for mutating actions (Medium/High) —
   Fixed.** Any process able to connect to the socket could issue mutating commands
   (`apply`, `set-network`, `remove-network`, `set-ipset`, `remove-ipset`, `reconcile`),
   with filesystem permissions (`0660`) as the only access control. Fix: `SO_PEERCRED` is
   read on every connection; mutating actions require the peer to be root (UID 0).
   Read-only actions (`status`, `refresh`) remain open to any process in the socket's
   group. Every request is logged with the peer's PID/UID/GID for audit purposes.

3. **Unbounded per-connection thread spawning on the management socket (Medium) —
   Fixed.** `_accept_loop` spawned a new thread per accepted connection with no upper
   bound; a local client able to reach the socket could exhaust threads/resources by
   opening many connections. Fix: a bounded semaphore caps concurrent connection
   handlers — a connection that can't acquire a slot is closed immediately rather than
   spawning a thread — and a per-connection socket timeout bounds how long a slow or
   idle client can hold a slot. Deliberately not a full worker-pool/backpressure protocol
   (the review's original suggestion): given the socket's actual threat model (`0660`
   permissions, root-gated mutations, a host you control), the simpler bound is
   proportionate to the risk.

## Consequences

All three findings are closed as of this landing. If the socket's threat model changes
(e.g. exposed beyond a single trusted host), revisit finding 3's mitigation — the current
bound is sized for a single-host, group-restricted deployment, not an adversarial
multi-tenant one.
