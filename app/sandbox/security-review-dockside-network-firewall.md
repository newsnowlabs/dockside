# Security review: `dockside-network-firewall.py`

Date: 2026-03-25

## Scope

Reviewed `install/usr/local/lib/dockside/dockside-network-firewall.py` for malicious logic, unsafe root behaviors, and implementation defects that could compromise host integrity.

## Executive summary

- **No intentionally malicious behavior was found** (no covert exfiltration, persistence dropper logic, or obfuscated payload execution patterns).
- The script shows generally careful command execution hygiene by using argument vectors (not shell command strings).
- **However, there are meaningful security risks** in a root daemon context:
  1. **Untrusted config values are interpolated into `iptables-restore` text without strict validation/sanitization**.
  2. **The management socket allows privileged mutation operations with only filesystem permissions as access control** (no peer credential validation / policy layer).
  3. **Socket request handling can be used for low-effort local DoS** via unlimited per-connection handler threads.

## Findings

### 1) `iptables-restore` text is built from unvalidated config values (High)

The daemon builds full `iptables-restore` lines by string interpolation from config-derived values like network names, interface names, MAC/IP selectors, ipset names, comments, and NAT fields. If an attacker can influence configuration or management-socket inputs, malformed or adversarial tokens may break ruleset application or inject unintended rule fragments into restore input.

Why this matters as root:
- The process executes `iptables-restore` as root.
- A malformed/hostile value can cause partial policy failure or unexpected allow/deny behavior.
- Because chains/rules are assembled as free-form strings, validation should be explicit and strict.

Recommended hardening:
- Enforce strict allowlists for identifiers:
  - network/chain/ipset names: `^[A-Za-z0-9_.:-]+$` and length bounds.
  - interface names: Linux iface-safe charset + length.
  - comments: strip or reject control characters including `\n` and `\r`.
- Validate IP/CIDR/MAC/protocol/port fields with `ipaddress` and exact schema checks before rule generation.
- Reject configs that fail validation before any kernel mutation.

### 2) Management socket is privilege-sensitive but lacks peer identity checks (Medium/High, depending on deployment)

The management socket exposes mutating actions (`apply`, `set-network`, `set-ipset`, `remove-*`, `reconcile`) that directly alter iptables/ipset and persisted config. Access control relies on socket path permissions (`0660`) only.

Risk model:
- Any local user/process in the socket’s group can request root-level firewall changes.
- There is no `SO_PEERCRED` verification, allowlist of UIDs/GIDs, or command authorization policy.

Recommended hardening:
- Verify peer credentials (`SO_PEERCRED`) and require root (or specific UID/GID allowlist) for mutating actions.
- Optionally split actions into read-only vs mutating sockets.
- Add audit logging of peer UID/GID/PID and action.

### 3) Unbounded per-connection thread spawning in management socket (Medium)

Each accepted socket connection spawns a new daemon thread immediately. A local client can create many connections and trigger thread/resource exhaustion, reducing daemon responsiveness.

Recommended hardening:
- Use bounded worker pool or semaphore limit.
- Enforce request timeouts and connection quotas.
- Return backpressure errors when capacity is reached.

## Positive safety observations

- External commands are executed via `subprocess.run(args=...)` without shell invocation, reducing classic shell injection exposure.
- Teardown/apply logic is structured and idempotent in many areas.
- There are explicit comments and conservative behavior in some failure cases (e.g., not emptying ipsets on DNS failure).

## Overall risk posture

- **Not malicious**, but **requires hardening** for robust secure operation as a root firewall daemon.
- Priority remediation should focus on:
  1. strict schema + lexical validation of all rule/config inputs,
  2. authenticated/authorized management-socket access for mutating operations,
  3. connection/thread resource limits.
