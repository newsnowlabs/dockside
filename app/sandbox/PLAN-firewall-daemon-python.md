# Plan: Python firewall daemon replacing dockside-network-firewall.sh

## Overview

Replace `dockside-network-firewall.sh` with a Python 3.6+ daemon that:
- Loads configuration from two admin-editable JSON files
- Manages Docker networks and iptables/ipset rules atomically
- Enforces a FORWARD DROP safety guarantee with no open-firewall window
- Optionally accepts a Unix domain socket for dynamic runtime updates
- Supports zero-disruption restarts (iptables rules are not torn down on SIGTERM)
- Runs as a systemd Type=notify service (identical contract to today)

---

## 1. File layout

```
/usr/local/lib/dockside/
  dockside-network-firewall.py    # replaces .sh; single-file implementation
/etc/dockside/
  network-config.json             # Docker network definitions (admin-editable)
  firewall-config.json            # per-network firewall policies (admin-editable)
```

The two config files together replace the hardcoded `setup()` body in the bash script.
They are separated because bridge-based iptables rules and Docker custom networks are
independent entities: iptables rules for a bridge interface can exist before the
corresponding Docker network is created, and vice versa.

The management socket path is specified via `--socket PATH` or `DOCKSIDE_FIREWALL_SOCKET`
env var. There is no compiled-in default — the socket is disabled unless explicitly
configured. Its path should be chosen to match the launch context:

- **Systemd host service**: `/run/dockside/firewall.sock`
- **Docker Compose**: a path reachable from both the host daemon and any container that
  needs to send commands (e.g. bind-mounted into the Dockside app container)

If no socket path is given, the daemon runs purely from files with no dynamic config
interface — identical operational model to today's bash script.

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
        { "proto": "udp", "ports": [53],          "to": "all" },
        { "proto": "tcp", "ports": [53, 80, 443], "to": "all" },
        { "proto": "tcp", "ports": [25],          "to": "all" },
        { "proto": "tcp", "ports": [3306],        "to": "cidr", "cidr": "192.168.0.0/16" },
        { "proto": "icmp", "type": "echo-request" },
        { "action": "drop" }
      ]
    },
    "ds-claude": {
      "egress": [
        { "proto": "udp", "ports": [53],  "to": "all" },
        { "proto": "tcp", "ports": [53],  "to": "all" },
        { "proto": "tcp", "ports": [443], "to": "ipset", "ipset": "claude-allowlist" },
        { "proto": "tcp", "ports": [22],  "to": "ipset", "ipset": "claude-allowlist" },
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

NAT/DNAT rules use a `nat` key per network. The primary use-case is sandboxed
development: redirect outgoing connections from containers — e.g. MySQL calls to a
production hostname — to a safely sandboxed clone, without modifying application code:

```json
"ds-clone": {
  "nat": [
    { "proto": "tcp", "dport": 13306, "redirect_ip": "192.0.2.10", "redirect_port": 3306 }
  ],
  "egress": [ ... ]
}
```

---

## 3. iptables chain structure

```
FORWARD
  └─> DOCKER-USER                (Docker's persistent jump — untouched by Dockside)
        ├─> DOCKSIDE-DISPATCH    (added once at startup; never removed during refresh)
        │     ├─ -i ds-prod -o ds-prod  -j DOCKSIDE-ds-prod-ING
        │     ├─ -i ds-prod ! -o ds-prod [mac/ip filter] -j DOCKSIDE-ds-prod-OUT
        │     ├─ ... other managed networks ...
        │     │
        │     │  ── safety net: drop anything from a Dockside bridge not dispatched above ──
        │     ├─ -i ds-prod  -j DROP
        │     ├─ -o ds-prod  -j DROP
        │     ├─ ... one pair per managed network ...
        │     │
        │     └─ RETURN          (non-Dockside traffic falls through to Docker's rules)
        │
        └─> RETURN               (Docker appends this; Docker's FORWARD rules follow)

DOCKSIDE-ds-prod-ING:
  -m mac --mac-source GW_MAC -p tcp -m conntrack --ctstate NEW -j RETURN
  -s GW_IP                   -p tcp -m conntrack --ctstate NEW -j RETURN
  -m conntrack --ctstate NEW -j DROP

DOCKSIDE-ds-prod-OUT:
  ... RETURN rules per egress policy ...
  terminal DROP/REJECT

DOCKSIDE-ds-prod-NAT  (nat table PREROUTING):
  ... DNAT rules ...
```

The key structural change from the bash script:
- `DOCKER-USER` is **never flushed** — Dockside manages exactly one rule there
  (`-j DOCKSIDE-DISPATCH`), added once at startup
- `DOCKSIDE-DISPATCH` and all `DOCKSIDE-*` chains are replaced atomically via a single
  `iptables-restore --noflush` call

---

## 4. FORWARD chain safety

Two independent layers, both enforced at every apply:

**Layer 1 — enforce FORWARD DROP policy at startup:**
```python
subprocess.run(["iptables", "-P", "FORWARD", "DROP"], check=True)
```
Modern Docker already sets this, but we enforce it explicitly. Any packet not matched
by Docker's or Dockside's rules is dropped at the policy level.

**Layer 2 — safety-net DROPs inside DOCKSIDE-DISPATCH:**
After all per-network dispatch jumps, DOCKSIDE-DISPATCH always ends with:
```
-A DOCKSIDE-DISPATCH -i <dev> -j DROP   # for each Dockside bridge
-A DOCKSIDE-DISPATCH -o <dev> -j DROP
```
These are part of the atomically-applied ruleset. There is no instant where a Dockside
bridge interface is reachable without a DROP catching packets that slip past the
per-network chains.

This eliminates the open-firewall window present in the bash script, which does
`iptables -F DOCKER-USER` (line 378) then rebuilds rules one network at a time.

---

## 5. Atomic apply strategy

All iptables state is rebuilt in memory and applied in one `iptables-restore --noflush`
call — both filter and nat tables together. The generator produces:

```
*filter
:DOCKSIDE-DISPATCH - [0:0]
:DOCKSIDE-ds-prod-ING - [0:0]
:DOCKSIDE-ds-prod-OUT - [0:0]
... (all Dockside filter chains declared) ...

-F DOCKSIDE-DISPATCH
-F DOCKSIDE-ds-prod-ING
-F DOCKSIDE-ds-prod-OUT
...

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

`iptables-restore --noflush` flushes and rebuilds only the listed chains atomically.
`DOCKER-USER` and all Docker-owned chains are untouched.

---

## 6. Python module structure (single file)

```
class Config:
    # Loads and validates network-config.json + firewall-config.json
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

class IpsetManager:
    # Maintains: setname -> list[hostname], setname -> set[ip] (last-known)
    # Stale-TTL: keep old IPs for IPSET_STALE_TTL seconds after DNS stops returning them
    def ensure_ipset(self, name: str, hostnames: list[str])
    def refresh_all(self)              # re-resolve DNS; swap entries; honour stale-TTL
    def destroy_all_dockside(self)     # explicit teardown only

class IptablesManager:
    def ensure_forward_drop(self)
    def ensure_dispatch_chain(self)    # idempotent: create DOCKSIDE-DISPATCH,
                                       # add DOCKER-USER jump if absent
    def apply_config(self, config)     # build full restore input, apply atomically
    def teardown(self)                 # explicit teardown: rm jump, flush+delete chains

class ManagementSocket:
    # Unix domain socket server; each connection handled in a new thread
    # Disabled if socket_path is None/empty
    def start(self, socket_path: str, handler_fn)
    def stop(self)

class FirewallDaemon:
    def run(self)                      # startup sequence + event loop
    def _refresh_loop(self)            # background thread
    def _handle_request(self, req: dict) -> dict   # socket handler
```

---

## 7. Socket protocol

Connection model: one JSON object per connection (request then response, then close).
Each object is a newline-terminated UTF-8 string, max 1 MiB.

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
threads and the background refresh thread both acquire this lock.

---

## 8. Startup sequence

```
1.  Parse CLI args (--daemon | --teardown | --status | default one-shot)
2.  Load Config from /etc/dockside/{network,firewall}-config.json
3.  iptables -P FORWARD DROP                   (enforce; warn if already set)
4.  DockerNetworkManager.ensure_networks()     (create missing; rm+recreate if RESET=1)
5.  IptablesManager.ensure_dispatch_chain()    (idempotent: create DOCKSIDE-DISPATCH,
                                                add DOCKER-USER jump if absent)
6.  IpsetManager.ensure_ipset() for each set   (create sets; ipset create --exist)
7.  IpsetManager.refresh_all()                 (initial DNS population)
8.  IptablesManager.apply_config(config)       (full iptables-restore --noflush)
9.  ManagementSocket.start() if socket path given
10. systemd-notify --ready                     (ExecStartPost docker compose unblocks)
11. Start background refresh thread
12. Block on management socket accept loop (or sleep loop for daemon mode without socket)
```

At step 5 and 8, the daemon applies atomically over whatever iptables state already
exists — whether freshly booted or inherited from a previous daemon instance. No
teardown is needed before re-applying.

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

- Interval: `IPSET_REFRESH_INTERVAL` env var (default 60 s)
- `_stop` is a `threading.Event`; set in shutdown handler for clean exit
- No config-file watching: file-based config changes take effect on the next daemon
  restart or via a `reload` request on the management socket

---

## 10. Shutdown model (SIGTERM)

On SIGTERM, the daemon **leaves all iptables and ipset state in place**:

```
1. Set _stop event → background thread exits on next wakeup
2. ManagementSocket.stop() → close listening socket, drain in-flight requests
3. Exit (rules remain active in the kernel)
```

This makes `systemctl restart dockside` zero-disruption: the next startup (step 8
above) atomically updates chains over the inherited state without any dark period.

Firewall rules established by Dockside continue to protect traffic even while no
daemon is running — the kernel holds the ruleset independently.

### Explicit teardown

A separate `--teardown` mode performs full cleanup for when Dockside networking is
being permanently removed:

```
1. Remove DOCKSIDE-DISPATCH jump from DOCKER-USER
2. Flush all DOCKSIDE-* filter chains
3. Delete all DOCKSIDE-* filter chains
4. Flush/delete DOCKSIDE-*-NAT nat chains
5. IpsetManager.destroy_all_dockside()
```

`ExecStop=` in the service unit does **not** call `--teardown` by default; it only
stops docker compose. Teardown is an operator action, not a routine stop.

---

## 11. CLI interface

```
dockside-network-firewall.py --daemon              # full daemon (start → ready → refresh loop)
dockside-network-firewall.py --daemon --socket PATH  # daemon with management socket
dockside-network-firewall.py --status [--socket PATH]  # query socket, print JSON status
dockside-network-firewall.py --teardown            # explicit full cleanup
dockside-network-firewall.py                       # one-shot setup (no daemon, no socket)
```

`ExecStart` in `dockside.service` changes to:
```
ExecStart=/usr/local/lib/dockside/dockside-network-firewall.py --daemon
```
(add `--socket /run/dockside/firewall.sock` when socket support is wanted)

`ExecReload` sends `SIGUSR1` to the daemon process (triggering a config reload + ipset
refresh from within the daemon) rather than spawning a child process:
```
ExecReload=/bin/kill -USR1 $MAINPID
```

`ExecStop` remains `docker compose ... down`; no `--teardown` is called on routine stop.

---

## 12. Dependency summary

| Need | Solution |
|------|---------|
| JSON config parsing | `json` stdlib |
| DNS resolution | `socket.getaddrinfo()` stdlib |
| Unix socket server | `socket` + `threading` stdlib |
| iptables operations | subprocess: `iptables-restore`, `iptables -N/-D/-X/-P` |
| ipset operations | subprocess: `ipset` |
| Docker network creation | subprocess: `docker network` |
| systemd readiness | subprocess: `systemd-notify --ready` |

No third-party packages required. Python 3.6+ stdlib only.

---

## 13. Migration from bash

1. Write `network-config.json` and `firewall-config.json` matching today's `setup()` body
2. Update `ExecStart=` in `dockside.service`; update `ExecReload=` to use `kill -USR1`
3. `systemctl daemon-reload && systemctl restart dockside`
4. Verify: `dockside-network-firewall.py --status` and `iptables -nL DOCKSIDE-DISPATCH`
5. Once stable, remove `dockside-network-firewall.sh`
