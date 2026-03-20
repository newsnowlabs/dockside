# Plan: Python firewall daemon replacing dockside-network-firewall.sh

## Overview

Replace `dockside-network-firewall.sh` with a Python 3.6+ daemon that:
- Loads configuration from two admin-editable JSON files
- Manages Docker networks and iptables/ipset rules atomically
- Enforces a FORWARD DROP safety guarantee with no open-firewall window
- Optionally accepts a Unix domain socket for dynamic runtime updates
- Runs as a systemd Type=notify service (identical contract to today)

---

## 1. File layout

```
/usr/local/lib/dockside/
  dockside-network-firewall.py    # replaces .sh; single-file implementation
/etc/dockside/
  network-config.json             # Docker network definitions (admin-editable)
  firewall-config.json            # per-network firewall policies (admin-editable)
/run/dockside/
  firewall.sock                   # management socket (optional; disabled if path empty)
```

The two config files together replace the hardcoded `setup()` body in the bash script.
If `firewall.sock` is disabled (path set to `""` in config or flag), the daemon runs
purely from files — identical operational model to today.

---

## 2. Config file schemas

### `/etc/dockside/network-config.json`

```json
{
  "networks": [
    {
      "name": "ds-prod",
      "subnet": "172.16.0.0/16",
      "gateway_ip": "172.16.0.2",
      "gateway_mac": "02:00:00:00:00:01"
    },
    {
      "name": "dockside",
      "subnet": "172.15.0.0/16"
    }
  ]
}
```

Fields:
- `name` — Docker network name; also seeds the iptables chain name (`DOCKSIDE-{NAME}-ING` etc.)
- `subnet` — CIDR; gateway defaults to `.1` if `gateway_ip` omitted
- `gateway_ip` — optional; used for ING exclusion rule and OUT exclusion rule
- `gateway_mac` — optional; used for ING/OUT exclusion rules (same as today)

### `/etc/dockside/firewall-config.json`

```json
{
  "ipsets": {
    "claude-allowlist": [
      "api.anthropic.com",
      "statsig.anthropic.com",
      "registry.npmjs.org",
      "github.com"
    ]
  },
  "networks": {
    "ds-prod": {
      "egress": [
        { "proto": "udp", "ports": [53],        "to": "all" },
        { "proto": "tcp", "ports": [53, 80, 443], "to": "all" },
        { "proto": "tcp", "ports": [25],          "to": "all" },
        { "proto": "tcp", "ports": [3306],        "to": "cidr", "cidr": "192.168.0.0/16" },
        { "proto": "icmp", "type": "echo-request" },
        { "action": "drop" }
      ]
    },
    "ds-claude": {
      "egress": [
        { "proto": "udp", "ports": [53],   "to": "all" },
        { "proto": "tcp", "ports": [53],   "to": "all" },
        { "proto": "tcp", "ports": [443],  "to": "ipset", "ipset": "claude-allowlist" },
        { "proto": "tcp", "ports": [22],   "to": "ipset", "ipset": "claude-allowlist" },
        { "proto": "icmp", "type": "echo-request" },
        { "action": "drop" }
      ]
    }
  }
}
```

The `ingress` key is omitted here: absent means "use default ingress policy" which is
gateway-only (replicate today's `$chn-ING` logic). Explicit `"ingress": "open"` or
`"ingress": "drop-all"` are supported future values.

NAT/DNAT rules (today's `reroute_mysql`) use a separate `nat` key per network:
```json
"nat": [
  { "proto": "tcp", "dport": 13306, "redirect_ip": "192.0.2.10", "redirect_port": 3306 }
]
```

---

## 3. iptables chain structure

```
FORWARD
  └─> DOCKER-USER                (Docker's persistent jump — untouched)
        ├─> DOCKSIDE-DISPATCH    (Dockside adds once at startup, never removes during refresh)
        │     ├─ -i ds-prod -o ds-prod  -j DOCKSIDE-ds-prod-ING
        │     ├─ -i ds-prod ! -o ds-prod [mac/ip filter] -j DOCKSIDE-ds-prod-OUT
        │     ├─ ... other managed networks ...
        │     │
        │     │  ── safety net: catch anything from a Dockside bridge not dispatched above ──
        │     ├─ -i ds-prod  -j DROP
        │     ├─ -o ds-prod  -j DROP
        │     ├─ ... one pair per managed network ...
        │     │
        │     └─ RETURN          (non-Dockside traffic falls through to Docker's rules)
        │
        └─> RETURN               (Docker appends this; Docker's FORWARD rules follow)

DOCKSIDE-ds-prod-ING:
  -m mac --mac-source GW_MAC -p tcp -m conntrack --ctstate NEW -j RETURN
  -s GW_IP               -p tcp -m conntrack --ctstate NEW -j RETURN
  -m conntrack --ctstate NEW -j DROP

DOCKSIDE-ds-prod-OUT:
  ... RETURN rules per egress policy ...
  terminal DROP

DOCKSIDE-ds-prod-NAT  (nat table PREROUTING):
  ... DNAT rules ...
```

The key structural change from the bash script is:
- `DOCKER-USER` is **never flushed** — only one jump (`→ DOCKSIDE-DISPATCH`) is managed
- `DOCKSIDE-DISPATCH` and all `DOCKSIDE-*` chains are replaced atomically via
  `iptables-restore --noflush`

---

## 4. FORWARD chain safety

Two independent layers:

**Layer 1 — enforce FORWARD DROP policy at startup:**
```python
subprocess.run(["iptables", "-P", "FORWARD", "DROP"], check=True)
```
Modern Docker already sets this, but we enforce it explicitly. This ensures any
traffic not explicitly accepted by Docker's or Dockside's rules is dropped by default.

**Layer 2 — safety-net DROPs inside DOCKSIDE-DISPATCH:**
After all per-network dispatch jumps, DOCKSIDE-DISPATCH always contains:
```
-A DOCKSIDE-DISPATCH -i <dev> -j DROP   # for each Dockside bridge
-A DOCKSIDE-DISPATCH -o <dev> -j DROP
```
These are part of the atomically-applied ruleset, so they are present from the moment
`iptables-restore` returns. There is no instant where a Dockside bridge interface is
reachable without a DROP catching it.

This eliminates the open-firewall window that exists in the bash script (which does
`iptables -F DOCKER-USER` then rebuilds rules one network at a time).

---

## 5. Atomic apply strategy

All iptables state is rebuilt in memory and applied in one `iptables-restore --noflush`
call. The generator produces:

```
*filter
:DOCKSIDE-DISPATCH - [0:0]
:DOCKSIDE-ds-prod-ING - [0:0]
:DOCKSIDE-ds-prod-OUT - [0:0]
... (all Dockside chains declared) ...

-F DOCKSIDE-DISPATCH
-F DOCKSIDE-ds-prod-ING
-F DOCKSIDE-ds-prod-OUT
... (flush each Dockside chain) ...

-A DOCKSIDE-DISPATCH ...dispatch rules...
-A DOCKSIDE-DISPATCH -i ds-prod -j DROP   ← safety net
-A DOCKSIDE-DISPATCH -o ds-prod -j DROP

-A DOCKSIDE-ds-prod-ING ...
-A DOCKSIDE-ds-prod-OUT ...
COMMIT

*nat
:DOCKSIDE-ds-prod-NAT - [0:0]
-F DOCKSIDE-ds-prod-NAT
... DNAT rules ...
COMMIT
```

`iptables-restore --noflush` flushes and rebuilds only the listed chains. DOCKER-USER
and Docker's own chains are untouched. The operation is atomic from the kernel's
perspective (processed as a single transaction).

---

## 6. Python module structure (single file)

```
class Config:
    # Loads, validates, and merges network-config.json + firewall-config.json
    # Properties: .networks (list[NetworkSpec]), .ipsets (dict[str, list[str]])
    @classmethod
    def from_files(cls, network_path, firewall_path) -> "Config"
    @classmethod
    def from_dict(cls, d) -> "Config"   # for socket-pushed config

class NetworkSpec:
    # name, dev, chain_prefix, subnet, gateway_ip, gateway_mac,
    # ingress_policy, egress_rules, nat_rules

class DockerNetworkManager:
    def ensure_networks(self, networks: list[NetworkSpec], reset=False)
    def delete_network(self, name: str)

class IpsetManager:
    # Maintains: setname -> list[hostname], setname -> set[ip] (last-known)
    # Stale-TTL: keep old IPs for IPSET_STALE_TTL seconds after DNS stops returning them
    def ensure_ipset(self, name: str, hostnames: list[str])
    def refresh_all(self)           # re-resolve DNS; swap entries; honour stale-TTL
    def destroy_all_dockside(self)  # cleanup on shutdown

class IptablesManager:
    def ensure_forward_drop(self)
    def ensure_dispatch_chain(self)           # idempotent: create DOCKSIDE-DISPATCH + DOCKER-USER jump
    def apply_config(self, config: Config)    # builds restore input, calls iptables-restore
    def teardown(self)                        # remove DOCKER-USER jump, flush+delete all DOCKSIDE-* chains

class ManagementSocket:
    # Unix domain socket server; each connection handled in a new thread
    # Disabled if socket_path is empty/None
    def start(self, socket_path: str, handler_fn)
    def stop(self)

class FirewallDaemon:
    # Orchestrates all of the above
    def run(self)           # startup sequence + event loop
    def _refresh_loop(self) # background thread
    def _handle_request(self, request: dict) -> dict  # socket handler
```

---

## 7. Socket protocol

Socket: `/run/dockside/firewall.sock` (configurable; disabled if path is empty).

Connection model: one JSON object per connection (request/response, then close).
The JSON object is a newline-terminated UTF-8 string, max 1 MiB.

### Requests

| action | payload | description |
|--------|---------|-------------|
| `"reload"` | — | Re-read config files from disk, re-apply atomically |
| `"apply"` | `"config": {...}` | Push a complete config dict, apply atomically |
| `"refresh"` | — | Trigger immediate ipset DNS refresh |
| `"status"` | — | Return current state summary |

### Responses

```json
{ "status": "ok" }
{ "status": "ok", "networks": ["ds-prod", "ds-claude"], "ipsets": {"claude-allowlist": ["1.2.3.4"]} }
{ "status": "error", "message": "validation failed: unknown network ds-foo" }
```

### Concurrency

A single `threading.Lock` serialises all iptables/ipset mutations. Socket handler
threads and the background refresh thread both acquire this lock. This prevents
interleaved iptables operations without requiring a serialising event loop.

---

## 8. Startup sequence

```
1.  Parse CLI args (--daemon | --refresh | --status | default one-shot)
2.  Load Config from /etc/dockside/{network,firewall}-config.json
3.  iptables -P FORWARD DROP                   (enforce; warn if Docker hasn't done it)
4.  DockerNetworkManager.ensure_networks()     (create missing; rm+recreate if RESET=1)
5.  IptablesManager.ensure_dispatch_chain()    (idempotent: create DOCKSIDE-DISPATCH,
                                                add DOCKER-USER jump if absent)
6.  IpsetManager.ensure_ipset() for each set   (create ipsets; no DNS yet)
7.  IpsetManager.refresh_all()                 (initial DNS population)
8.  IptablesManager.apply_config(config)       (full iptables-restore --noflush)
9.  ManagementSocket.start() if enabled
10. systemd-notify --ready                     (ExecStartPost docker compose unblocks)
11. Start background refresh thread
12. Block on management socket accept loop (or signal for daemon mode)
```

---

## 9. Background refresh loop

```python
def _refresh_loop(self):
    while not self._stop.wait(timeout=self.interval):
        try:
            with self._lock:
                self.ipset_mgr.refresh_all()
        except Exception:
            logging.exception("ipset refresh failed")
```

- Interval: `IPSET_REFRESH_INTERVAL` env var (default 60 s), same as today
- `_stop` is a `threading.Event`; set in shutdown handler so the thread exits cleanly
- Config-file mtime is also checked here; if changed, re-read and re-apply atomically

---

## 10. Shutdown / cleanup (SIGTERM)

```
1. Set _stop event → background thread exits on next wakeup
2. ManagementSocket.stop() → stop accepting new connections
3. IptablesManager.teardown():
     a. Remove DOCKSIDE-DISPATCH jump from DOCKER-USER
     b. iptables-restore --noflush an empty ruleset flushing all DOCKSIDE-* chains
     c. Delete all DOCKSIDE-* chains (iptables -X)
     d. Flush/delete DOCKSIDE-*-NAT chains in nat table
4. IpsetManager.destroy_all_dockside()
```

Docker network interfaces (br-*) are not removed on shutdown — Docker manages those.

---

## 11. CLI interface (unchanged contract with systemd)

```
dockside-network-firewall.py --daemon    # full daemon (start → ready → refresh loop)
dockside-network-firewall.py --refresh   # one-shot ipset refresh + config file reload
dockside-network-firewall.py --status    # query socket, print JSON status
dockside-network-firewall.py             # one-shot setup (no daemon, no socket)
```

`ExecStart`, `ExecStartPost`, `ExecStop`, and `ExecReload` in `dockside.service` remain
unchanged except for the interpreter path.

`ExecReload` will be updated to send `SIGUSR1` instead of spawning `--refresh` as a
separate process; the daemon handles SIGUSR1 by queuing a config-reload + ipset-refresh
inside its main loop.

---

## 12. Dependency summary

| Need | Solution |
|------|---------|
| JSON config parsing | `json` stdlib |
| DNS resolution | `socket.getaddrinfo()` stdlib |
| Unix socket server | `socket` + `threading` stdlib |
| iptables operations | subprocess `iptables-restore`, `iptables -N/-D/-X` |
| ipset operations | subprocess `ipset` |
| Docker network creation | subprocess `docker network` |
| systemd readiness | subprocess `systemd-notify --ready` or `sd_notify` via ctypes |
| inotify (optional) | `inotify_simple` PyPI pkg; fall back to mtime polling if absent |

No third-party packages are strictly required. The daemon runs on Python 3.6+ with
only stdlib, matching the stated constraint.

---

## 13. Migration from bash

1. Write `network-config.json` and `firewall-config.json` matching today's `setup()` body
2. Replace `ExecStart=` in `dockside.service` with `python3 .../dockside-network-firewall.py --daemon`
3. Run `systemctl daemon-reload && systemctl restart dockside`
4. Verify with `dockside-network-firewall.py --status` and `iptables -L DOCKSIDE-DISPATCH`
5. Once stable, remove the bash script

A helper mode `dockside-network-firewall.py --dump-config` (future) can introspect live
iptables state and emit equivalent JSON config files for review.

---

## Open questions / decisions needed

1. **Two files vs one**: The plan uses two files (network + firewall). Alternatively,
   one combined `dockside-config.json` with a `networks` key and a `firewall` key.
   Two files allow the network layer to be managed separately from policy.

2. **Socket disabled by default**: Should the socket be opt-in (disabled unless
   `DOCKSIDE_SOCKET` env var or `--socket` flag) or opt-out? Opt-in is safer for
   deployments that don't need dynamic config.

3. **Config file watching**: Poll mtime at each refresh interval (simplest, no deps)
   vs inotify (instant response, one optional dep). Plan assumes polling as default.

4. **NAT table handling**: The plan generates `iptables-restore` input for the nat
   table too, applying it atomically alongside filter. This differs from the bash script
   which manages NAT with individual `iptables` calls. Confirm this is acceptable.
