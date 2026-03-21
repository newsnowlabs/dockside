#!/usr/bin/env python3
"""
Dockside network firewall daemon.

Replaces dockside-network-firewall.sh with a Python 3.6+ daemon that:
  - Loads configuration from /etc/dockside/network-config.json and
    /etc/dockside/firewall-config.json
  - Manages Docker networks and iptables/ipset rules atomically via a single
    iptables-restore --noflush call, with no open-firewall window
  - Leaves iptables rules in place on shutdown, enabling zero-disruption
    systemctl restart; use --teardown for explicit cleanup
  - Optionally accepts a Unix domain socket for dynamic runtime updates
    (socket path set via --socket PATH or $DOCKSIDE_FIREWALL_SOCKET)
  - Triggers config reload on SIGUSR1 (maps to ExecReload= in systemd unit)
  - Runs as a systemd Type=notify service

CLI modes:
  --daemon              Full daemon: setup + ipset refresh loop
  --daemon --socket P   Daemon with management socket at path P
  --status --socket P   Query running daemon for status
  --teardown            Remove all Dockside firewall rules and ipsets
  (no flags)            One-shot: apply config and exit
"""

from __future__ import annotations

import json
import logging
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from typing import Dict, List, Optional

# ---------------------------------------------------------------------------
# Environment-driven constants
# ---------------------------------------------------------------------------

# How long (seconds) a resolved IP address may linger in an ipset after it
# is no longer returned by DNS.  The grace period prevents brief DNS flapping
# (common with CDN services returning different IP pools) from immediately
# blocking in-flight connections.
IPSET_STALE_TTL = int(os.environ.get("IPSET_STALE_TTL", "300"))

# How often (seconds) the daemon re-resolves hostname-backed ipsets to catch
# DNS changes.  Should be comfortably below IPSET_STALE_TTL so fresh IPs are
# added well before stale ones expire.
IPSET_REFRESH_INTERVAL = int(os.environ.get("IPSET_REFRESH_INTERVAL", "60"))

# String prefix applied to every iptables chain name and ipset name created
# by this daemon.  Makes Dockside-owned objects instantly identifiable and
# easy to enumerate during teardown.
DOCKSIDE_PREFIX = "DOCKSIDE"


# ---------------------------------------------------------------------------
# Subprocess helper
# ---------------------------------------------------------------------------

def _run(
    args: List[str],
    input: Optional[str] = None,
    allow_fail: bool = False,
) -> subprocess.CompletedProcess:
    """Run an external command, capturing stdout and stderr as strings.

    Args:
        args:       Argv list; first element is the executable name.
        input:      Optional string written to the process's stdin.  Used to
                    feed multi-line rule sets to ``iptables-restore``.
        allow_fail: When True, a non-zero exit code is logged at DEBUG level
                    and the CompletedProcess is returned to the caller rather
                    than raising.  Use this for idempotent operations where
                    failure simply means "nothing to do" (e.g. "ipset already
                    exists", "rule not found", "chain does not exist").

    Returns:
        CompletedProcess with .stdout and .stderr available as strings.

    Raises:
        subprocess.CalledProcessError: if the command exits non-zero and
            ``allow_fail`` is False.
    """
    # Log the command at DEBUG level; append a byte-count note when stdin data
    # is provided so the log line stays readable without dumping the full input.
    logging.debug("+ %s%s", " ".join(str(a) for a in args),
                  f"  [{len(input)} bytes stdin]" if input else "")
    result = subprocess.run(
        args,
        input=input,
        stdout=subprocess.PIPE,   # capture stdout so callers can inspect it
        stderr=subprocess.PIPE,   # capture stderr for error messages
        text=True,                # decode bytes to str; avoids manual .decode()
    )
    if result.returncode != 0:
        if allow_fail:
            # Expected failure: log quietly and return so the caller can
            # decide whether the outcome matters (e.g. check stderr text).
            logging.debug("  exit %d: %s", result.returncode,
                          result.stderr.strip()[:200])
        else:
            logging.error("Command failed: %s", " ".join(str(a) for a in args))
            logging.error("  stderr: %s", result.stderr.strip())
            raise subprocess.CalledProcessError(
                result.returncode, args, result.stdout, result.stderr
            )
    return result


def _systemd_notify(state: str) -> None:
    """Send an sd_notify(3) status string to the systemd supervisor process.

    Common values for *state*:
      ``"READY=1"``           — startup complete; service is ready to accept work.
      ``"RELOADING=1"``       — config reload in progress.
      ``"STATUS=<message>"``  — free-form human-readable status shown by
                                ``systemctl status``.

    Silently ignored when systemd-notify is not installed (e.g. during
    development or inside a container that does not run systemd).
    """
    try:
        # allow_fail=True: a non-zero exit (e.g. daemon was not started by
        # systemd, so there is no notification socket) is not fatal.
        _run(["systemd-notify", state], allow_fail=True)
    except FileNotFoundError:
        # systemd-notify binary absent — not running under systemd; skip.
        pass


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

class EgressRule:
    """One rule in a network's outbound (egress) traffic policy.

    Each instance is parsed directly from a JSON object inside the
    ``"egress"`` array of a firewall-config network entry.  The rule is later
    translated into one or more iptables match/target lines by
    ``IptablesManager._egress_to_iptables()``.
    """

    def __init__(self, d: dict):
        # Optional transport-protocol filter.  None means match any protocol.
        self.proto     = d.get("proto")               # "tcp"|"udp"|"icmp"|None

        # Destination port numbers to match.  Empty list means all ports.
        self.ports     = d.get("ports", [])            # list[int]

        # Selector type for the traffic destination:
        #   "all"   — match any destination address
        #   "cidr"  — match a specific subnet (see self.cidr)
        #   "ip"    — match a single IP address (see self.ip)
        #   "ipset" — match against a named ipset (see self.ipset)
        #   "host"  — resolve a hostname at runtime and match its IPs (see self.host)
        self.to        = d.get("to", "all")            # "all"|"cidr"|"ip"|"ipset"|"host"

        # CIDR string used when to=="cidr" (e.g. "10.0.0.0/8").
        self.cidr      = d.get("cidr")

        # Single IPv4 address string used when to=="ip".
        self.ip        = d.get("ip")

        # Name of a pre-defined ipset (from the "ipsets" config section)
        # used when to=="ipset".
        self.ipset     = d.get("ipset")

        # Hostname resolved to one or more IPs at rule-apply time when
        # to=="host".
        self.host      = d.get("host")

        # ICMP message type; only relevant when proto=="icmp".
        # Defaults to "echo-request" (i.e. allow outbound ping).
        self.icmp_type = d.get("type", "echo-request")

        # What to do when traffic matches this rule:
        #   "allow" — emit an iptables RETURN rule (traffic is accepted by
        #             Docker's existing FORWARD ACCEPT rule higher in the chain).
        #   "drop"  — emit REJECT (for TCP: tcp-reset) + DROP rules to
        #             actively refuse the traffic and notify the sender.
        self.action    = d.get("action", "allow")      # "allow"|"drop"

    def __repr__(self) -> str:
        if self.action == "drop":
            return f"EgressRule(drop, cidr={self.cidr!r})"
        return f"EgressRule({self.proto}, ports={self.ports}, to={self.to!r})"


class NatRule:
    """One DNAT (Destination NAT) rule in a network's nat config.

    Each instance is parsed from an object in the ``"nat"`` array of a
    firewall-config network entry and is translated into an iptables
    PREROUTING DNAT rule by ``IptablesManager._build_restore_input()``.

    A DNAT rule intercepts packets arriving on the network whose destination
    port matches ``match_dport`` and rewrites the destination address/port to
    redirect them to a different host and/or port inside the network.
    """

    def __init__(self, d: dict):
        # Transport protocol for the DNAT match; defaults to "tcp".
        self.proto       = d.get("proto", "tcp")

        # Destination port number to intercept (the "external" port seen by
        # the original sender).
        self.match_dport = d.get("match_dport")   # int: port to intercept

        # Optional hostname resolved at apply-time to supply the DNAT target
        # IP.  Mutually exclusive with to_ip.
        self.to_host     = d.get("to_host")        # hostname, resolved at apply-time

        # Optional literal IP address used as the DNAT target.  Used when a
        # fixed IP is preferred over a hostname lookup.
        self.to_ip       = d.get("to_ip")          # IP directly (alternative to to_host)

        # Target port number to rewrite the destination port to.
        self.to_port     = d.get("to_port")        # int: redirect target port


class NetworkSpec:
    """Describes one Docker network and the firewall policy attached to it.

    Populated from a combination of network-config.json (basic topology) and
    firewall-config.json (egress/NAT rules).  Used throughout the code as the
    single source of truth for a network's configuration.
    """

    def __init__(self, d: dict):
        # Docker network name (also used to derive the Linux bridge interface
        # name via the ``dev`` property and iptables chain names via
        # ``chain_prefix``).
        self.name        = d["name"]

        # CIDR subnet for the network (e.g. "172.20.0.0/16").
        self.subnet      = d["subnet"]

        # Optional explicit gateway IP.  When absent, derived automatically
        # from the subnet by ``_subnet_to_gateway()`` (first host, i.e. x.x.x.1).
        self.gateway_ip  = d.get("gateway_ip")

        # Optional MAC address of the gateway interface.  When provided,
        # iptables rules allow traffic from this MAC address unconditionally,
        # ensuring gateway-initiated packets are never blocked.
        self.gateway_mac = d.get("gateway_mac")

        # Outbound traffic rules appended by Config.from_dicts() after parsing
        # the firewall-config "egress" array for this network.
        self.egress_rules: List[EgressRule] = []

        # DNAT rules appended by Config.from_dicts() after parsing the
        # firewall-config "nat" array for this network.
        self.nat_rules:   List[NatRule]    = []

    @property
    def dev(self) -> str:
        """Linux bridge interface name for this network.

        Docker names the kernel bridge interface after the network name,
        lower-cased (e.g. network "MyNet" → bridge "mynet").  iptables rules
        match on this name via ``-i <dev>`` (inbound) and ``-o <dev>``
        (outbound).
        """
        return self.name.lower()

    @property
    def chain_prefix(self) -> str:
        """Base name for the iptables chains belonging to this network.

        The ingress chain will be ``<prefix>-ING`` and the egress chain
        ``<prefix>-OUT``.  Using DOCKSIDE_PREFIX ensures all Dockside-owned
        chains are identifiable by name and can be enumerated for teardown.
        """
        return f"{DOCKSIDE_PREFIX}-{self.name.upper()}"

    @property
    def managed(self) -> bool:
        """True if this network needs DOCKSIDE-DISPATCH entries and firewall chains.

        An "unmanaged" network (no gateway configured, no egress or NAT rules)
        does not require custom firewall chains; its traffic flows through
        Docker's default FORWARD rules unchanged.  Only managed networks get
        entries in the DOCKSIDE-DISPATCH jump chain.
        """
        return bool(
            self.gateway_ip or self.gateway_mac
            or self.egress_rules or self.nat_rules
        )

    def __repr__(self) -> str:
        return f"NetworkSpec({self.name!r}, subnet={self.subnet!r})"


class Config:
    """Merged runtime configuration: network topology + firewall policy.

    Combines data from the two config files into a ready-to-use object.
    ``networks`` is the authoritative list of NetworkSpec objects (each with
    their egress/NAT rules already attached) and ``ipsets`` is the mapping of
    ipset name → list of hostnames/IPs to populate it with.
    """

    def __init__(self, networks: List[NetworkSpec], ipsets: Dict[str, List[str]]):
        # Ordered list of all configured networks.
        self.networks = networks

        # Mapping of ipset name → list of hostnames/CIDR strings.
        # Populated by IpsetManager at apply time.
        self.ipsets   = ipsets

    @classmethod
    def from_files(cls, network_path: str, firewall_path: str) -> "Config":
        """Load and merge config from the two JSON files on disk.

        Args:
            network_path:  Path to network-config.json (network topology).
            firewall_path: Path to firewall-config.json (egress/NAT/ipset rules).

        Returns:
            A fully populated Config instance.

        Raises:
            OSError:       if either file cannot be opened.
            json.JSONDecodeError: if either file contains invalid JSON.
            ValueError:    if firewall-config references an unknown network.
        """
        with open(network_path) as f:
            net_data = json.load(f)
        with open(firewall_path) as f:
            fw_data = json.load(f)
        return cls.from_dicts(net_data, fw_data)

    @classmethod
    def from_dicts(cls, net_data: dict, fw_data: dict) -> "Config":
        """Build a Config from already-parsed JSON dictionaries.

        First pass: build a NetworkSpec for every entry in the network-config
        "networks" array, keyed by name.

        Second pass: walk the firewall-config "networks" map; for each network
        name append its EgressRules and NatRules onto the matching NetworkSpec.
        If a firewall-config entry names a network that was not present in the
        network-config, raise immediately — a silent mismatch would lead to
        rules never being installed.

        Args:
            net_data: Parsed network-config.json (top-level dict).
            fw_data:  Parsed firewall-config.json (top-level dict).

        Returns:
            A fully populated Config instance.

        Raises:
            ValueError: if firewall-config references a network name not found
                in net_data.
        """
        # First pass: create a NetworkSpec for every declared network.
        specs: Dict[str, NetworkSpec] = {}
        for nd in net_data.get("networks", []):
            spec = NetworkSpec(nd)
            specs[spec.name] = spec

        # Collect ipset definitions (name → list of hosts/CIDRs).
        ipsets = fw_data.get("ipsets", {})

        # Second pass: attach egress and NAT rules from firewall-config to the
        # matching NetworkSpec objects.
        for net_name, fw in fw_data.get("networks", {}).items():
            if net_name not in specs:
                # Guard: a typo in firewall-config would silently produce no
                # rules for the intended network; raise early instead.
                raise ValueError(
                    f"firewall-config references unknown network {net_name!r}"
                )
            spec = specs[net_name]
            for r in fw.get("egress", []):
                spec.egress_rules.append(EgressRule(r))
            for r in fw.get("nat", []):
                spec.nat_rules.append(NatRule(r))

        return cls(list(specs.values()), ipsets)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _subnet_to_gateway(subnet: str) -> str:
    """Derive the conventional gateway IP (host .1) from a CIDR subnet string.

    Example: ``"172.16.0.0/16"`` → ``"172.16.0.1"``

    Used when a NetworkSpec does not supply an explicit ``gateway_ip``.  The
    convention of placing the gateway at the first host address (.1) matches
    Docker's own default bridge gateway assignment.
    """
    # Strip the prefix length (everything after "/") to get the bare base IP.
    base  = subnet.split("/")[0]
    # Replace the last octet with "1" to get the .1 host address.
    parts = base.split(".")
    parts[-1] = "1"
    return ".".join(parts)


def _resolve_hostname(hostname: str) -> Optional[str]:
    """Resolve a hostname to its first IPv4 address, or None on failure.

    Uses ``socket.AF_INET`` to restrict results to IPv4, avoiding IPv6
    addresses that iptables (non-ip6tables) cannot match.

    Args:
        hostname: DNS name or dotted-decimal IP string.

    Returns:
        The first IPv4 address string, or None if resolution fails.
    """
    try:
        # getaddrinfo returns a list of 5-tuples; element [4] is the address
        # tuple, and [4][0] is the IP string for AF_INET results.
        infos = socket.getaddrinfo(hostname, None, socket.AF_INET)
        return infos[0][4][0] if infos else None
    except socket.gaierror as exc:
        logging.warning("DNS resolution failed for %s: %s", hostname, exc)
        return None


def _resolve_hostname_all(hostname: str) -> List[str]:
    """Resolve a hostname to all its IPv4 addresses, deduplicated.

    CDN services and load-balanced hostnames may return many A records.
    This function collects all of them while preserving order and removing
    duplicates, so every IP can be added to an ipset.

    Uses ``socket.AF_INET`` to restrict results to IPv4.

    Args:
        hostname: DNS name or dotted-decimal IP string.

    Returns:
        Deduplicated list of IPv4 address strings in resolution order.
        Empty list if resolution fails.
    """
    try:
        infos = socket.getaddrinfo(hostname, None, socket.AF_INET)
        # Use a set for O(1) duplicate detection while ips[] preserves order.
        seen: set = set()
        ips: List[str] = []
        for info in infos:
            ip = info[4][0]   # AF_INET address tuple → IP string
            if ip not in seen:
                seen.add(ip)
                ips.append(ip)
        return ips
    except socket.gaierror as exc:
        logging.warning("DNS resolution failed for %s: %s", hostname, exc)
        return []


# ---------------------------------------------------------------------------
# DockerNetworkManager
# ---------------------------------------------------------------------------

class DockerNetworkManager:

    def ensure_networks(
        self, networks: List[NetworkSpec], reset: bool = False
    ) -> None:
        for spec in networks:
            self._ensure_one(spec, reset)

    def _ensure_one(self, spec: NetworkSpec, reset: bool) -> None:
        name    = spec.name
        subnet  = spec.subnet
        gateway = spec.gateway_ip or _subnet_to_gateway(subnet)

        r      = _run(["docker", "network", "inspect", name], allow_fail=True)
        exists = r.returncode == 0

        if exists:
            if reset:
                logging.info("Removing network %s (RESET=1)", name)
                _run(["docker", "network", "rm", name])
            else:
                logging.debug("Docker network %s already exists", name)
                return

        logging.info("Creating Docker network %s (%s, gw %s)", name, subnet, gateway)
        _run([
            "docker", "network", "create",
            f"--subnet={subnet}",
            f"--gateway={gateway}",
            "--opt=com.docker.network.bridge.name=" + spec.dev,
            "--opt=com.docker.network.bridge.enable_icc=true",
            "--opt=com.docker.network.bridge.enable_ip_masquerade=true",
            "--opt=com.docker.network.driver.mtu=1500",
            "--opt=com.docker.network.bridge.host_binding_ipv4=0.0.0.0",
            name,
        ])


# ---------------------------------------------------------------------------
# IpsetManager
# ---------------------------------------------------------------------------

class IpsetManager:

    def __init__(self):
        # name → list of hostnames
        self._sets: Dict[str, List[str]] = {}

    def ensure_ipset(self, name: str, hostnames: List[str]) -> None:
        """Register and initially populate an ipset."""
        self._sets[name] = hostnames
        _run(["ipset", "create", name, "hash:ip", "-exist"])
        seen = name + "--seen"
        _run(["ipset", "create", seen, "hash:ip",
              "timeout", str(IPSET_STALE_TTL), "-exist"])
        self._refresh_one(name)

    def refresh_all(self) -> None:
        for name in list(self._sets):
            try:
                self._refresh_one(name)
            except Exception:
                logging.exception("Failed to refresh ipset %s", name)

    def _refresh_one(self, name: str) -> None:
        hostnames = self._sets.get(name, [])
        seen      = name + "--seen"

        new_ips: set = set()
        for host in hostnames:
            ips = _resolve_hostname_all(host)
            if ips:
                new_ips.update(ips)
            else:
                logging.warning("Could not resolve %s for ipset %s", host, name)

        if not new_ips:
            logging.error(
                "No IPs resolved for ipset %s — leaving live set unchanged", name
            )
            return

        live_ips = self._get_ipset_ips(name)

        # Add new IPs; refresh seen-set timeout (delete+add to reset TTL counter)
        for ip in new_ips:
            _run(["ipset", "add", "-exist", name, ip], allow_fail=True)
            _run(["ipset", "del", seen, ip], allow_fail=True)
            _run(["ipset", "add", seen, ip,
                  "timeout", str(IPSET_STALE_TTL)], allow_fail=True)

        # Remove IPs that are stale: absent from new resolution AND expired from seen-set
        for ip in live_ips - new_ips:
            r = _run(["ipset", "test", seen, ip], allow_fail=True)
            if r.returncode != 0:
                logging.info("Removing stale IP %s from ipset %s", ip, name)
                _run(["ipset", "del", name, ip], allow_fail=True)

        logging.debug("ipset %s refreshed: %d active IPs", name, len(new_ips))

    def _get_ipset_ips(self, name: str) -> set:
        r = _run(["ipset", "list", name], allow_fail=True)
        if r.returncode != 0:
            return set()
        ips: set = set()
        in_members = False
        for line in r.stdout.splitlines():
            stripped = line.strip()
            if stripped == "Members:":
                in_members = True
                continue
            if in_members and stripped:
                # Line may be "1.2.3.4" or "1.2.3.4 timeout 120 ..."
                ips.add(stripped.split()[0])
        return ips

    def destroy_by_names(self, names: List[str]) -> None:
        """Destroy named ipsets and their --seen/--tmp companions."""
        for name in names:
            for suffix in ("--tmp", "--seen", ""):
                _run(["ipset", "destroy", name + suffix], allow_fail=True)


# ---------------------------------------------------------------------------
# IptablesManager
# ---------------------------------------------------------------------------

class IptablesManager:

    def ensure_forward_drop(self) -> None:
        _run(["iptables", "-P", "FORWARD", "DROP"])
        logging.debug("FORWARD policy set to DROP")

    def ensure_dispatch_chain(self) -> None:
        """Create DOCKSIDE-DISPATCH and ensure DOCKER-USER jumps to it."""
        _run(["iptables", "-N", "DOCKSIDE-DISPATCH"], allow_fail=True)
        r = _run(
            ["iptables", "-C", "DOCKER-USER", "-j", "DOCKSIDE-DISPATCH"],
            allow_fail=True,
        )
        if r.returncode != 0:
            logging.info("Adding DOCKER-USER → DOCKSIDE-DISPATCH jump")
            _run(["iptables", "-I", "DOCKER-USER", "1", "-j", "DOCKSIDE-DISPATCH"])

    def apply_config(self, config: Config) -> None:
        """Atomically apply all filter + nat rules via iptables-restore --noflush."""
        managed   = [s for s in config.networks if s.managed]
        nat_specs = [s for s in managed if s.nat_rules]

        restore_text = "\n".join(self._build_restore_input(managed, nat_specs)) + "\n"

        logging.debug("iptables-restore input:\n%s", restore_text)
        _run(["iptables-restore", "--noflush"], input=restore_text)

        # PREROUTING → per-network NAT chain jumps are managed outside iptables-restore
        # because we must not flush PREROUTING (it contains Docker's own NAT rules).
        for spec in nat_specs:
            self._ensure_nat_prerouting_jump(f"{spec.chain_prefix}-NAT")

        logging.info(
            "iptables config applied: %d managed networks, %d with NAT",
            len(managed), len(nat_specs),
        )

    @staticmethod
    def _build_restore_input(
        managed: List[NetworkSpec],
        nat_specs: List[NetworkSpec],
    ) -> List[str]:
        lines: List[str] = []

        # ── filter table ──────────────────────────────────────────────────────
        lines.append("*filter")

        # 1. Declare all Dockside filter chains (create if absent)
        lines.append(":DOCKSIDE-DISPATCH - [0:0]")
        for spec in managed:
            p = spec.chain_prefix
            lines.append(f":{p}-ING - [0:0]")
            lines.append(f":{p}-OUT - [0:0]")

        # 2. Flush all Dockside filter chains
        lines.append("-F DOCKSIDE-DISPATCH")
        for spec in managed:
            p = spec.chain_prefix
            lines.append(f"-F {p}-ING")
            lines.append(f"-F {p}-OUT")

        # 3a. DOCKSIDE-DISPATCH: per-network dispatch jumps
        for spec in managed:
            dev = spec.dev
            p   = spec.chain_prefix
            # ING: intra-network traffic (same bridge in and out)
            lines.append(f"-A DOCKSIDE-DISPATCH -i {dev} -o {dev} -j {p}-ING")
            # OUT: egress from containers, gateway traffic excluded
            out_match = IptablesManager._dispatch_out_match(spec)
            lines.append(f"-A DOCKSIDE-DISPATCH {out_match} -j {p}-OUT")

        # 3b. Gateway exemptions: let the gateway's own new egress pass the safety-net
        for spec in managed:
            dev = spec.dev
            if spec.gateway_mac:
                lines.append(
                    f"-A DOCKSIDE-DISPATCH -i {dev}"
                    f" -m mac --mac-source {spec.gateway_mac} -j RETURN"
                )
            if spec.gateway_ip:
                lines.append(
                    f"-A DOCKSIDE-DISPATCH -i {dev} -s {spec.gateway_ip} -j RETURN"
                )

        # 3c. Safety-net: drop new connections from managed bridges that weren't
        #     dispatched (e.g. left-over bridge after network removed from config).
        #     Only NEW connections; ESTABLISHED/RELATED fall through to Docker's
        #     own FORWARD-chain ACCEPT rule.
        for spec in managed:
            dev = spec.dev
            lines.append(
                f"-A DOCKSIDE-DISPATCH -i {dev} -m conntrack --ctstate NEW -j DROP"
            )

        # 3d. RETURN: let non-Dockside traffic reach Docker's own FORWARD rules
        lines.append("-A DOCKSIDE-DISPATCH -j RETURN")

        # 4. Per-network ING chains (control intra-network NEW connections)
        for spec in managed:
            p  = spec.chain_prefix
            gm = spec.gateway_mac
            gi = spec.gateway_ip
            if gm:
                lines.append(
                    f"-A {p}-ING -m mac --mac-source {gm} -p tcp"
                    f" -m conntrack --ctstate NEW -j RETURN"
                )
            if gi:
                lines.append(
                    f"-A {p}-ING -s {gi} -p tcp"
                    f" -m conntrack --ctstate NEW -j RETURN"
                )
            lines.append(f"-A {p}-ING -m conntrack --ctstate NEW -j DROP")

        # 5. Per-network OUT chains (egress policy)
        for spec in managed:
            p = spec.chain_prefix
            for rule in spec.egress_rules:
                lines.extend(IptablesManager._egress_to_iptables(p, rule))

        lines.append("COMMIT")

        # ── nat table ─────────────────────────────────────────────────────────
        if nat_specs:
            lines.append("*nat")

            for spec in nat_specs:
                p = spec.chain_prefix
                lines.append(f":{p}-NAT - [0:0]")

            for spec in nat_specs:
                p   = spec.chain_prefix
                dev = spec.dev
                lines.append(f"-F {p}-NAT")
                for nat in spec.nat_rules:
                    to_ip = (
                        _resolve_hostname(nat.to_host) if nat.to_host else nat.to_ip
                    )
                    if not to_ip:
                        logging.warning(
                            "NAT rule for %s: could not resolve %r — skipped",
                            spec.name, nat.to_host,
                        )
                        continue
                    lines.append(
                        f"-A {p}-NAT -i {dev} -p {nat.proto}"
                        f" --dport {nat.match_dport}"
                        f" -j DNAT --to-destination {to_ip}:{nat.to_port}"
                    )

            lines.append("COMMIT")

        return lines

    @staticmethod
    def _dispatch_out_match(spec: NetworkSpec) -> str:
        """Build the OUT dispatch match fragment (without -j target)."""
        dev   = spec.dev
        gm    = spec.gateway_mac
        gi    = spec.gateway_ip
        parts = [f"-i {dev}", f"! -o {dev}"]
        if gm and gi:
            parts += [f"-m mac ! --mac-source {gm}", f"! -s {gi}"]
        elif gm:
            parts.append(f"-m mac ! --mac-source {gm}")
        elif gi:
            parts.append(f"! -s {gi}")
        # If neither is set: all outbound traffic from the bridge is dispatched
        return " ".join(parts)

    @staticmethod
    def _egress_to_iptables(chain: str, rule: EgressRule) -> List[str]:
        """Translate one EgressRule to iptables-restore rule lines."""
        lines:  List[str] = []
        prefix  = f"-A {chain}"

        if rule.action == "drop":
            dst = f"-d {rule.cidr} " if rule.cidr else ""
            # TCP: send RST so the sender knows the connection was refused
            lines.append(
                f"{prefix} {dst}-p tcp -m conntrack --ctstate NEW"
                f" -j REJECT --reject-with tcp-reset"
            )
            # Other protocols: DROP.  Targeted drops catch all states (matches bash);
            # terminal drops (no cidr) only drop NEW so established flows keep working.
            if rule.cidr:
                lines.append(f"{prefix} -d {rule.cidr} -j DROP")
            else:
                lines.append(f"{prefix} -m conntrack --ctstate NEW -j DROP")
            return lines

        # Build destination selector
        if rule.to == "cidr" and rule.cidr:
            dst = f"-d {rule.cidr} "
        elif rule.to == "ip" and rule.ip:
            dst = f"-d {rule.ip} "
        elif rule.to == "host" and rule.host:
            ip  = _resolve_hostname(rule.host)
            if not ip:
                logging.warning(
                    "Egress rule: could not resolve host %r — rule skipped", rule.host
                )
                return []
            dst = f"-d {ip} "
        elif rule.to == "ipset" and rule.ipset:
            dst = f"-m set --match-set {rule.ipset} dst "
        else:
            dst = ""  # to=all: no destination filter

        if rule.proto == "icmp":
            lines.append(
                f"{prefix} -p icmp --icmp-type {rule.icmp_type}"
                f" -m conntrack --ctstate NEW -j RETURN"
            )
        elif rule.proto in ("tcp", "udp") and rule.ports:
            ports_str = ",".join(str(p) for p in rule.ports)
            lines.append(
                f"{prefix} -p {rule.proto} {dst}"
                f"-m multiport --dports {ports_str}"
                f" -m conntrack --ctstate NEW -j RETURN"
            )
        else:
            logging.warning(
                "Unrecognised egress rule proto=%r to=%r — skipped",
                rule.proto, rule.to,
            )

        return lines

    @staticmethod
    def _ensure_nat_prerouting_jump(chain_name: str) -> None:
        r = _run(
            ["iptables", "-t", "nat", "-C", "PREROUTING", "-j", chain_name],
            allow_fail=True,
        )
        if r.returncode != 0:
            logging.info("Adding PREROUTING → %s jump", chain_name)
            _run(["iptables", "-t", "nat", "-A", "PREROUTING", "-j", chain_name])

    def teardown(self) -> None:
        """Remove all Dockside iptables state."""
        logging.info("Starting iptables teardown")

        # Remove DOCKER-USER → DOCKSIDE-DISPATCH
        _run(
            ["iptables", "-D", "DOCKER-USER", "-j", "DOCKSIDE-DISPATCH"],
            allow_fail=True,
        )

        # Remove any PREROUTING → DOCKSIDE-*-NAT jumps
        r = _run(
            ["iptables", "-t", "nat", "-S", "PREROUTING"], allow_fail=True
        )
        if r.returncode == 0:
            for line in r.stdout.splitlines():
                if "-j DOCKSIDE-" in line:
                    del_args = line.replace("-A PREROUTING", "", 1).split()
                    _run(
                        ["iptables", "-t", "nat", "-D", "PREROUTING"] + del_args,
                        allow_fail=True,
                    )

        # Flush + delete all DOCKSIDE-* chains in filter table
        for chain in self._list_dockside_chains("filter"):
            _run(["iptables", "-F", chain], allow_fail=True)
            _run(["iptables", "-X", chain], allow_fail=True)

        # Flush + delete all DOCKSIDE-* chains in nat table
        for chain in self._list_dockside_chains("nat"):
            _run(["iptables", "-t", "nat", "-F", chain], allow_fail=True)
            _run(["iptables", "-t", "nat", "-X", chain], allow_fail=True)

        logging.info("iptables teardown complete")

    @staticmethod
    def _list_dockside_chains(table: str) -> List[str]:
        flags = ["-t", table] if table != "filter" else []
        r = _run(["iptables"] + flags + ["-S"], allow_fail=True)
        if r.returncode != 0:
            return []
        chains = []
        for line in r.stdout.splitlines():
            if line.startswith("-N DOCKSIDE-"):
                chains.append(line.split()[1])
        return chains


# ---------------------------------------------------------------------------
# ManagementSocket
# ---------------------------------------------------------------------------

class ManagementSocket:

    def __init__(self):
        self._server: Optional[socket.socket] = None
        self._stop    = threading.Event()
        self._handler = None

    def start(self, path: str, handler) -> None:
        if os.path.exists(path):
            os.unlink(path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
        try:
            os.chmod(path, 0o660)
        except OSError:
            pass
        srv.listen(5)
        self._server  = srv
        self._handler = handler
        t = threading.Thread(
            target=self._accept_loop, daemon=True, name="mgmt-socket"
        )
        t.start()
        logging.info("Management socket listening at %s", path)

    def stop(self) -> None:
        self._stop.set()
        if self._server:
            try:
                self._server.close()
            except Exception:
                pass

    def _accept_loop(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self._server.accept()
            except OSError:
                break
            threading.Thread(
                target=self._handle_conn, args=(conn,), daemon=True
            ).start()

    def _handle_conn(self, conn: socket.socket) -> None:
        try:
            buf = b""
            while b"\n" not in buf and len(buf) < 1024 * 1024:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
            if buf.strip():
                req  = json.loads(buf.decode())
                resp = self._handler(req)
                conn.sendall((json.dumps(resp) + "\n").encode())
        except Exception as exc:
            try:
                conn.sendall(
                    (json.dumps({"status": "error", "message": str(exc)}) + "\n")
                    .encode()
                )
            except Exception:
                pass
        finally:
            conn.close()


# ---------------------------------------------------------------------------
# FirewallDaemon
# ---------------------------------------------------------------------------

class FirewallDaemon:

    def __init__(
        self,
        network_config_path: str,
        firewall_config_path: str,
        socket_path: Optional[str] = None,
    ):
        self._net_path  = network_config_path
        self._fw_path   = firewall_config_path
        self._sock_path = socket_path
        self._lock      = threading.Lock()
        self._stop      = threading.Event()
        self._config: Optional[Config] = None

        self._docker_mgr = DockerNetworkManager()
        self._ipset_mgr  = IpsetManager()
        self._ipt_mgr    = IptablesManager()
        self._socket     = ManagementSocket()

    def run(self) -> None:
        signal.signal(signal.SIGTERM, self._on_shutdown)
        signal.signal(signal.SIGINT,  self._on_shutdown)
        signal.signal(signal.SIGUSR1, self._on_sigusr1)

        self._config = Config.from_files(self._net_path, self._fw_path)
        self._apply_full(
            self._config, reset=(os.environ.get("RESET", "0") == "1")
        )

        if self._sock_path:
            self._socket.start(self._sock_path, self._handle_request)

        _systemd_notify("READY=1")
        logging.info("Daemon ready. ipset refresh every %ds.", IPSET_REFRESH_INTERVAL)

        refresh_t = threading.Thread(
            target=self._refresh_loop, daemon=True, name="ipset-refresh"
        )
        refresh_t.start()

        self._stop.wait()

        if self._sock_path:
            self._socket.stop()

        logging.info(
            "Daemon stopped. iptables rules left in place "
            "(use --teardown for explicit cleanup)."
        )

    def _apply_full(self, config: Config, reset: bool = False) -> None:
        # System tuning carried over from the original bash script
        _run(
            [
                "sysctl",
                "fs.inotify.max_user_watches=524288",
                "fs.inotify.max_user_instances=8192",
            ],
            allow_fail=True,
        )
        self._docker_mgr.ensure_networks(config.networks, reset=reset)
        self._ipt_mgr.ensure_forward_drop()
        self._ipt_mgr.ensure_dispatch_chain()
        for name, hostnames in config.ipsets.items():
            self._ipset_mgr.ensure_ipset(name, hostnames)
        self._ipt_mgr.apply_config(config)

    def _refresh_loop(self) -> None:
        while not self._stop.wait(timeout=IPSET_REFRESH_INTERVAL):
            try:
                with self._lock:
                    self._ipset_mgr.refresh_all()
            except Exception:
                logging.exception("ipset refresh error")

    def _on_shutdown(self, signum, frame) -> None:
        logging.info("Signal %d received — shutting down", signum)
        self._stop.set()

    def _on_sigusr1(self, signum, frame) -> None:
        logging.info("SIGUSR1 received — reloading config")
        threading.Thread(
            target=self._reload, daemon=True, name="config-reload"
        ).start()

    def _reload(self) -> None:
        try:
            new_config = Config.from_files(self._net_path, self._fw_path)
            with self._lock:
                self._docker_mgr.ensure_networks(new_config.networks)
                for name, hostnames in new_config.ipsets.items():
                    self._ipset_mgr.ensure_ipset(name, hostnames)
                self._ipset_mgr.refresh_all()
                self._ipt_mgr.apply_config(new_config)
                self._config = new_config
            logging.info("Config reload complete")
        except Exception:
            logging.exception("Config reload failed")

    def _handle_request(self, req: dict) -> dict:
        action = req.get("action", "")
        try:
            if action == "reload":
                self._reload()
                return {"status": "ok"}
            elif action == "apply":
                net_data = req.get("network_config", {})
                fw_data  = req.get("firewall_config", {})
                new_cfg  = Config.from_dicts(net_data, fw_data)
                with self._lock:
                    self._docker_mgr.ensure_networks(new_cfg.networks)
                    for name, hostnames in new_cfg.ipsets.items():
                        self._ipset_mgr.ensure_ipset(name, hostnames)
                    self._ipt_mgr.apply_config(new_cfg)
                    self._config = new_cfg
                return {"status": "ok"}
            elif action == "refresh":
                with self._lock:
                    self._ipset_mgr.refresh_all()
                return {"status": "ok"}
            elif action == "status":
                return self._get_status()
            else:
                return {"status": "error", "message": f"unknown action: {action!r}"}
        except Exception as exc:
            return {"status": "error", "message": str(exc)}

    def _get_status(self) -> dict:
        cfg = self._config
        if not cfg:
            return {"status": "ok", "ready": False}
        return {
            "status":   "ok",
            "ready":    True,
            "networks": [s.name for s in cfg.networks],
            "ipsets":   {
                name: sorted(self._ipset_mgr._get_ipset_ips(name))
                for name in cfg.ipsets
            },
        }


# ---------------------------------------------------------------------------
# Socket client helper (for --status)
# ---------------------------------------------------------------------------

def _socket_query(sock_path: str, req: dict) -> dict:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    try:
        s.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        return json.loads(buf.decode())
    finally:
        s.close()


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(
        description="Dockside network firewall daemon",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("\nCLI")[1] if "\nCLI" in __doc__ else "",
    )
    ap.add_argument(
        "--daemon", action="store_true",
        help="Run in daemon mode (setup + periodic ipset refresh loop)",
    )
    ap.add_argument(
        "--teardown", action="store_true",
        help="Remove all Dockside firewall rules and ipsets, then exit",
    )
    ap.add_argument(
        "--status", action="store_true",
        help="Query running daemon status via management socket, then exit",
    )
    ap.add_argument(
        "--socket", metavar="PATH",
        default=os.environ.get("DOCKSIDE_FIREWALL_SOCKET"),
        help="Unix socket path (default: $DOCKSIDE_FIREWALL_SOCKET)",
    )
    ap.add_argument(
        "--network-config", metavar="PATH",
        default="/etc/dockside/network-config.json",
    )
    ap.add_argument(
        "--firewall-config", metavar="PATH",
        default="/etc/dockside/firewall-config.json",
    )
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
        stream=sys.stderr,
    )

    if args.status:
        if not args.socket:
            logging.error("--socket PATH is required for --status")
            sys.exit(1)
        resp = _socket_query(args.socket, {"action": "status"})
        print(json.dumps(resp, indent=2))
        return

    if args.teardown:
        ipset_names: List[str] = []
        try:
            cfg = Config.from_files(args.network_config, args.firewall_config)
            ipset_names = list(cfg.ipsets.keys())
        except Exception as exc:
            logging.warning(
                "Could not load config during teardown (%s); "
                "ipsets will not be cleaned up", exc,
            )
        IptablesManager().teardown()
        IpsetManager().destroy_by_names(ipset_names)
        logging.info("Teardown complete")
        return

    daemon = FirewallDaemon(
        network_config_path=args.network_config,
        firewall_config_path=args.firewall_config,
        socket_path=args.socket if args.daemon else None,
    )

    if args.daemon:
        daemon.run()
    else:
        # One-shot: apply config and exit (backwards-compatible with bash one-shot mode)
        config = Config.from_files(args.network_config, args.firewall_config)
        daemon._apply_full(config, reset=(os.environ.get("RESET", "0") == "1"))


if __name__ == "__main__":
    main()
