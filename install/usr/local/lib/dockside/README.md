# dockside-network-firewall.py

Python 3.6+ daemon that manages Docker bridge networks and iptables/ipset
firewall rules for Dockside. Replaces the original `dockside-network-firewall.sh`.

## Overview

The daemon:

- Creates and validates Docker bridge networks described in `network-config.json`
- Builds per-network iptables chains atomically via `iptables-restore --noflush`
  (no open-firewall window during rule updates)
- Manages hostname-backed `ipset` sets, refreshing DNS every 60 s with a
  grace-period eviction mechanism to survive brief DNS flapping
- Optionally exposes a Unix-domain management socket for runtime config updates
- Triggers config reload on `SIGUSR1` (mapped to `ExecReload=` in the systemd unit)
- Runs as a `systemd` `Type=notify` service
- Leaves iptables rules in place on shutdown so containers stay protected during
  a `systemctl restart`; use `--teardown` to remove all Dockside rules explicitly

## Requirements

- Python 3.6+
- `iptables` / `iptables-restore`
- `ipset`
- `docker` CLI (for network creation)
- `systemd-notify` (optional; silently skipped if absent)

## CLI Usage

```
dockside-network-firewall.py [OPTIONS]
```

| Flag | Description |
|---|---|
| `--daemon` | Full daemon: apply config, start management socket, run ipset refresh loop |
| `--teardown` | Remove all Dockside iptables chains and ipsets, then exit |
| `--status` | Query a running daemon via the management socket and print JSON status |
| `--socket PATH` | Unix socket path (also set via `$DOCKSIDE_FIREWALL_SOCKET`) |
| `--network-config PATH` | Path to network config JSON (default: `/etc/dockside/network-config.json`) |
| `--firewall-config PATH` | Path to firewall config JSON (default: `/etc/dockside/firewall-config.json`) |
| `--debug` | Enable debug-level logging |

**One-shot mode** (no flags): apply config once and exit. Backwards-compatible
with the original bash script.

```bash
# One-shot apply
dockside-network-firewall.py

# Daemon with management socket
dockside-network-firewall.py --daemon --socket /run/dockside/firewall.sock

# Query running daemon
dockside-network-firewall.py --status --socket /run/dockside/firewall.sock

# Remove all Dockside rules
dockside-network-firewall.py --teardown
```

### RESET mode

Setting `RESET=1` in the environment causes existing Docker networks to be
removed and recreated on startup. Useful after subnet changes.

```bash
RESET=1 dockside-network-firewall.py --daemon
```

## Configuration Files

### network-config.json

Defines the Docker bridge networks to create.

```json
{
  "networks": [
    {
      "name":         "ds-prod",
      "subnet":       "172.16.0.0/16",
      "dockside_ip":  "172.16.0.2",
      "dockside_mac": "02:00:00:00:00:01"
    }
  ]
}
```

| Field | Required | Description |
|---|---|---|
| `name` | yes | Docker network name; also the Linux bridge name (lower-cased) |
| `subnet` | yes | CIDR subnet, e.g. `"172.16.0.0/16"` |
| `gateway_ip` | no | Docker network gateway IP; defaults to the `.1` host of the subnet |
| `dockside_ip` | no | Source IP of the dockside container on this network (typically `.2`); traffic from this IP bypasses the egress chain |
| `dockside_mac` | no | MAC address of the dockside container's interface; traffic from this MAC bypasses the egress chain |

At least one of `dockside_ip` or `dockside_mac` (or both) should be set for any
managed network; either is sufficient to identify dockside-container traffic.

A network with no `dockside_ip`, `dockside_mac`, egress rules, or NAT rules is
considered **unmanaged** and receives no Dockside firewall chains; its traffic
passes through Docker's default FORWARD rules unchanged.

### firewall-config.json

Defines ipsets and per-network egress/NAT policies.

```json
{
  "ipsets": {
    "my-allowlist": ["api.example.com", "cdn.example.com"]
  },
  "networks": {
    "ds-prod": {
      "egress": [...],
      "nat":    [...]
    }
  }
}
```

#### ipsets

Each entry maps an ipset name to a list of hostnames or literal IP addresses.
The daemon resolves hostnames at startup and re-resolves every
`IPSET_REFRESH_INTERVAL` seconds (default 60 s).

#### egress rules

An ordered list of rules evaluated top-to-bottom. The first matching rule wins.
A terminal `{"action": "drop"}` at the end of the list implements a
default-deny posture.

```json
{ "proto": "tcp",  "ports": [443],   "to": "all" }
{ "proto": "tcp",  "ports": [443],   "to": "cidr",  "cidr":  "10.0.0.0/8" }
{ "proto": "tcp",  "ports": [443],   "to": "ip",    "ip":    "1.2.3.4" }
{ "proto": "tcp",  "ports": [443],   "to": "host",  "host":  "api.example.com" }
{ "proto": "tcp",  "ports": [443],   "to": "ipset", "ipset": "my-allowlist" }
{ "proto": "udp",  "ports": [53],    "to": "all" }
{ "proto": "icmp", "type":  "echo-request" }
{ "action": "drop", "cidr": "192.168.0.0/16" }
{ "action": "drop" }
```

| Field | Values | Description |
|---|---|---|
| `proto` | `"tcp"`, `"udp"`, `"icmp"` | Transport protocol |
| `ports` | `[int, …]` | Destination port list (TCP/UDP only) |
| `to` | `"all"`, `"cidr"`, `"ip"`, `"host"`, `"ipset"` | Destination selector |
| `cidr` | CIDR string | Used when `to == "cidr"` |
| `ip` | IP string | Used when `to == "ip"` |
| `host` | hostname | Resolved at apply-time; use `"ipset"` for frequently-changing addresses |
| `ipset` | ipset name | Must appear in the top-level `"ipsets"` map |
| `type` | ICMP type name | Used when `proto == "icmp"` (default `"echo-request"`) |
| `action` | `"allow"` (default), `"drop"` | `"drop"` emits REJECT+DROP; `"allow"` emits RETURN |

Drop rules without a destination match (`{"action": "drop"}`) are terminal and
only match **new** connections so already-established flows are not disrupted.
Drop rules with a destination (e.g. `{"action": "drop", "cidr": "..."}`) match
all connection states, immediately tearing down existing flows to that target.

#### nat rules (DNAT)

Intercepts packets entering the bridge on `match_dport` and rewrites the
destination to `to_ip`/`to_host`:`to_port`.

```json
{
  "proto":       "tcp",
  "match_dport": 3306,
  "to_host":     "db.internal",
  "to_port":     13306
}
```

| Field | Description |
|---|---|
| `proto` | Transport protocol (default `"tcp"`) |
| `match_dport` | Destination port to intercept |
| `to_host` | Hostname resolved at apply-time to supply the DNAT target IP |
| `to_ip` | Literal target IP (alternative to `to_host`) |
| `to_port` | Target port number |

## Systemd Integration

The daemon is shipped as a `Type=notify` systemd service:

```ini
[Service]
Type=notify
ExecStart=/usr/local/lib/dockside/dockside-network-firewall.py --daemon
ExecReload=/bin/kill -USR1 $MAINPID
```

`systemctl reload dockside` sends `SIGUSR1` to the daemon, which triggers a
config reload from disk in a background thread without interrupting the
running firewall.

## Management Socket

When started with `--daemon --socket PATH`, the daemon listens on a
`AF_UNIX SOCK_STREAM` socket (mode `0660`). The protocol is
**newline-terminated JSON**:

```
Request:  {"action": "<action>", ...}\n
Response: {"status": "ok"|"error", ...}\n
```

### Actions

#### `status` — query daemon state

```json
// Request
{"action": "status"}

// Response (daemon ready)
{
  "status":   "ok",
  "ready":    true,
  "networks": ["ds-priv", "ds-clone", "ds-prod"],
  "ipsets": {
    "my-allowlist": ["1.2.3.4", "5.6.7.8"]
  }
}

// Response (before first apply completes)
{"status": "ok", "ready": false}
```

#### `reload` — reload config from disk

```json
// Request
{"action": "reload"}

// Response (synchronous — arrives after rules are applied)
{"status": "ok"}
```

Equivalent to `SIGUSR1` but synchronous: the response is not sent until the
reload is complete. Re-reads both config files from their configured paths,
updates Docker networks and ipsets, and atomically re-applies all iptables
rules.

#### `apply` — apply an inline config without touching files

```json
// Request
{
  "action": "apply",
  "network_config": {
    "networks": [
      {"name": "ds-prod", "subnet": "172.16.0.0/16", "dockside_ip": "172.16.0.2"}
    ]
  },
  "firewall_config": {
    "ipsets": {},
    "networks": {
      "ds-prod": {
        "egress": [
          {"proto": "tcp", "ports": [443], "to": "all"},
          {"action": "drop"}
        ]
      }
    }
  }
}

// Response
{"status": "ok"}
```

The request must contain the **complete** `network_config` and
`firewall_config` structures — this is a full replacement, not a merge.
See [Partial Config Updates](#partial-config-updates) below.

#### `refresh` — re-resolve ipsets immediately

```json
// Request
{"action": "refresh"}

// Response
{"status": "ok"}
```

Re-resolves all hostname-backed ipsets immediately without reloading the rest
of the config. The periodic refresh loop runs the same operation
automatically every `IPSET_REFRESH_INTERVAL` seconds.

#### Error response (any action)

```json
{"status": "error", "message": "firewall-config references unknown network 'typo'"}
```

### Shell examples

```bash
SOCK=/run/dockside/firewall.sock

# Status
echo '{"action":"status"}' | socat - UNIX-CONNECT:$SOCK | python3 -m json.tool

# Reload from disk
echo '{"action":"reload"}' | socat - UNIX-CONNECT:$SOCK

# Force ipset DNS refresh
echo '{"action":"refresh"}' | socat - UNIX-CONNECT:$SOCK
```

Or use the built-in `--status` flag:

```bash
dockside-network-firewall.py --status --socket /run/dockside/firewall.sock
```

## Partial Config Updates

The `apply` action requires the **full** `network_config` and `firewall_config`
objects — it replaces the entire running configuration in one atomic operation.
There is no built-in action for adding, updating or removing a single network,
ipset, or firewall section.

To make a targeted change at runtime, the recommended pattern is:

1. Read the current config from disk (or snapshot `self._config` via `status`
   for the network list)
2. Merge your modification into the in-memory copy
3. Send the complete merged config via `apply`
4. Write the updated config back to disk so `reload`/restart picks it up

```python
import json, socket

def socket_call(sock_path, req):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.sendall((json.dumps(req) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf)

SOCK = "/run/dockside/firewall.sock"

# Load current config from disk
with open("/etc/dockside/network-config.json") as f:
    net_cfg = json.load(f)
with open("/etc/dockside/firewall-config.json") as f:
    fw_cfg = json.load(f)

# Add a new network
net_cfg["networks"].append({
    "name": "ds-newnet", "subnet": "172.20.0.0/16", "dockside_ip": "172.20.0.2"
})
fw_cfg["networks"]["ds-newnet"] = {
    "egress": [
        {"proto": "tcp", "ports": [443], "to": "all"},
        {"action": "drop"}
    ]
}

# Apply and persist
socket_call(SOCK, {"action": "apply", "network_config": net_cfg, "firewall_config": fw_cfg})
with open("/etc/dockside/network-config.json", "w") as f:
    json.dump(net_cfg, f, indent=2)
with open("/etc/dockside/firewall-config.json", "w") as f:
    json.dump(fw_cfg, f, indent=2)
```

**Note on removal**: the `apply` action never removes Docker networks (the
daemon only creates them, never deletes them). Orphaned iptables chains for
removed networks are unreachable after the next apply but are not explicitly
deleted; run `--teardown` followed by a fresh apply for a fully clean state.

## Ipset Refresh Mechanism

Each ipset uses a dual-set "seen-set" pattern to handle DNS flapping:

- **live set** (`<name>`) — no per-entry timeout; used in iptables `--match-set` rules
- **seen-set** (`<name>--seen`) — per-entry TTL of `IPSET_STALE_TTL` seconds (default 300 s)

On each refresh cycle:

1. Resolve all hostnames to their current IPs
2. Add new IPs to both the live set and the seen-set (resetting the TTL)
3. For IPs in the live set but absent from the current DNS result: check the
   seen-set. If the entry has also expired from the seen-set (absent from DNS
   for `> IPSET_STALE_TTL` seconds), remove it from the live set

This means a CDN IP that temporarily disappears from DNS will remain in the
live set for up to 5 minutes, preventing in-flight connections from being dropped.

If **all** hostnames for an ipset fail to resolve, the live set is left
unchanged (failsafe: do not block traffic by emptying the set on a transient
DNS outage).

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `IPSET_STALE_TTL` | `300` | Seconds before a DNS-absent IP is removed from its ipset |
| `IPSET_REFRESH_INTERVAL` | `60` | Seconds between automatic ipset DNS refresh cycles |
| `DOCKSIDE_FIREWALL_SOCKET` | *(unset)* | Default socket path (overridden by `--socket`) |
| `RESET` | `0` | Set to `1` to destroy and recreate Docker networks on startup |

## Iptables Rule Architecture

```
FORWARD (policy DROP)
  └─ DOCKER-USER
       └─ DOCKSIDE-DISPATCH          ← jump inserted at position 1
            ├─ DOCKSIDE-<NET>-ING    ← intra-network (container-to-container) policy
            └─ DOCKSIDE-<NET>-OUT    ← container egress policy

nat PREROUTING
  └─ DOCKSIDE-<NET>-NAT              ← per-network DNAT rules
```

All filter chains are rebuilt atomically via a single `iptables-restore --noflush`
call, which flushes and repopulates only Dockside-owned chains while preserving
Docker's chains (`DOCKER`, `DOCKER-USER`, `DOCKER-ISOLATION-*`, etc.).

## Teardown

```bash
dockside-network-firewall.py --teardown
```

Removes:
- The `DOCKER-USER → DOCKSIDE-DISPATCH` jump rule
- All `DOCKSIDE-*` chains in the filter and nat tables
- All `DOCKSIDE`-prefixed ipsets

Docker networks are **not** removed by teardown; remove them manually with
`docker network rm` if needed.
