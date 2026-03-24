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
            return f"EgressRule(drop, to={self.to!r}, cidr={self.cidr!r})"
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
    """Creates and validates Docker bridge networks described by NetworkSpec objects.

    Responsible only for the Docker layer (``docker network create``).
    iptables/ipset management is handled separately by IptablesManager and
    IpsetManager so that Docker network lifecycle is decoupled from firewall
    rule lifecycle.
    """

    def ensure_networks(
        self, networks: List[NetworkSpec], reset: bool = False
    ) -> None:
        """Ensure every described network exists in Docker, creating it if needed.

        Args:
            networks: List of NetworkSpec objects to create/validate.
            reset:    When True, delete any existing network before recreating
                      it.  Used to force a clean state (e.g. after a subnet
                      change).  Controlled by the RESET=1 environment variable
                      in one-shot mode.
        """
        for spec in networks:
            self._ensure_one(spec, reset)

    def _ensure_one(self, spec: NetworkSpec, reset: bool) -> None:
        """Ensure one Docker network exists, optionally resetting it first.

        Uses ``docker network inspect`` (allow_fail=True) to probe existence
        without raising on a missing network.  If the network exists and
        reset=True, it is removed first so the subsequent create starts clean.
        If it exists and reset=False, the method returns immediately (idempotent).

        The bridge interface name is pinned to ``spec.dev`` (lower-cased network
        name) via the ``com.docker.network.bridge.name`` option so that iptables
        rules that match on ``-i``/``-o <dev>`` are stable across daemon restarts.
        """
        name    = spec.name
        subnet  = spec.subnet
        # Fall back to deriving a .1 gateway if not explicitly configured.
        gateway = spec.gateway_ip or _subnet_to_gateway(subnet)

        # Probe for an existing Docker network; returncode 0 = present.
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
            # Pin the Linux bridge interface name so iptables -i/-o rules are
            # stable; without this Docker auto-generates an unpredictable name.
            "--opt=com.docker.network.bridge.name=" + spec.dev,
            # Allow containers on the same bridge to communicate directly.
            "--opt=com.docker.network.bridge.enable_icc=true",
            # Enable outbound MASQUERADE (SNAT) so containers can reach the internet.
            "--opt=com.docker.network.bridge.enable_ip_masquerade=true",
            "--opt=com.docker.network.driver.mtu=1500",
            # Bind published container ports on all host interfaces by default.
            "--opt=com.docker.network.bridge.host_binding_ipv4=0.0.0.0",
            name,
        ])


# ---------------------------------------------------------------------------
# IpsetManager
# ---------------------------------------------------------------------------

class IpsetManager:
    """Creates, populates and periodically refreshes kernel ipsets.

    Each managed ipset stores the current IPv4 addresses for a set of
    hostnames.  A companion "seen-set" (``<name>--seen``) tracks which IPs
    have been returned by DNS recently; an IP is only evicted from the live
    set once it has been absent from DNS long enough for its seen-set TTL to
    expire.  This grace period prevents brief DNS flapping from causing
    unnecessary packet drops.

    Design summary:
        live set  (<name>)        — no per-entry timeout; holds IPs actively in use.
        seen-set  (<name>--seen)  — per-entry timeout = IPSET_STALE_TTL seconds;
                                    acts as a sliding window of "recently seen" IPs.
    """

    def __init__(self):
        # Registry mapping each ipset name to its list of source hostnames.
        # Populated by ensure_ipset(); used by refresh_all() to re-resolve.
        self._sets: Dict[str, List[str]] = {}

    def ensure_ipset(self, name: str, hostnames: List[str]) -> None:
        """Register a named ipset, create it in the kernel (if absent), and populate it.

        Creates two kernel ipsets:
          - ``name``        (hash:ip, no timeout) — the live set used by iptables rules.
          - ``name--seen``  (hash:ip, with IPSET_STALE_TTL) — the staleness tracker.

        ``-exist`` prevents an error if the set already exists (idempotent).
        An initial ``_refresh_one`` call resolves hostnames and loads the live set.

        Args:
            name:      ipset name as used in iptables ``-m set --match-set`` rules.
            hostnames: list of DNS hostnames (and/or literal IPs) whose resolved
                       IPv4 addresses should populate this set.
        """
        self._sets[name] = hostnames
        # Create the live set; -exist means "silently skip if already present".
        _run(["ipset", "create", name, "hash:ip", "-exist"])
        seen = name + "--seen"
        # Create the seen-set with per-entry TTL so entries auto-expire if not
        # refreshed within IPSET_STALE_TTL seconds.
        _run(["ipset", "create", seen, "hash:ip",
              "timeout", str(IPSET_STALE_TTL), "-exist"])
        self._refresh_one(name)

    def refresh_all(self) -> None:
        """Re-resolve and refresh every registered ipset.

        Called periodically by the daemon's refresh loop.  Failures for
        individual ipsets are logged but do not abort the loop (the live set
        is left unchanged so existing connections are not disrupted).
        """
        # Iterate over a snapshot of keys so that concurrent modifications
        # (unlikely but possible via socket reloads) do not raise RuntimeError.
        for name in list(self._sets):
            try:
                self._refresh_one(name)
            except Exception:
                logging.exception("Failed to refresh ipset %s", name)

    def _refresh_one(self, name: str) -> None:
        """Re-resolve hostnames for one ipset and synchronise the kernel set.

        Algorithm (the "seen-set" pattern):
          1. Resolve all hostnames to a set of new IPs (new_ips).
          2. Safety check: if resolution yields nothing, leave the live set
             unchanged to avoid emptying it due to a transient DNS outage.
          3. For each newly resolved IP:
               a. Add it to the live set (idempotent; -exist skips duplicates).
               b. Delete + re-add it to the seen-set to reset its TTL clock.
                  (A plain ``ipset add … timeout`` does NOT extend an existing
                  entry's TTL — only delete-then-add achieves that.)
          4. For each IP currently in the live set but absent from new_ips:
               check the seen-set; if the IP has also expired from the seen-set
               (i.e. it has been absent from DNS for longer than IPSET_STALE_TTL)
               remove it from the live set.  This is the grace-period mechanism.
        """
        hostnames = self._sets.get(name, [])
        seen      = name + "--seen"

        # Resolve all hostnames into a single set of current IPs.
        new_ips: set = set()
        for host in hostnames:
            ips = _resolve_hostname_all(host)
            if ips:
                new_ips.update(ips)
            else:
                logging.warning("Could not resolve %s for ipset %s", host, name)

        # Safety guard: if every hostname failed to resolve, keep the live set
        # as-is rather than emptying it (would block all traffic using this set).
        if not new_ips:
            logging.error(
                "No IPs resolved for ipset %s — leaving live set unchanged", name
            )
            return

        # Snapshot the IPs currently in the kernel live set before making changes.
        live_ips = self._get_ipset_ips(name)

        # Add new IPs; refresh seen-set timeout (delete+add to reset TTL counter).
        for ip in new_ips:
            # Idempotent add to the live set; won't fail if already present.
            _run(["ipset", "add", "-exist", name, ip], allow_fail=True)
            # Delete first — necessary to reset an existing entry's TTL in the
            # seen-set (ipset does not allow in-place timeout extension).
            _run(["ipset", "del", seen, ip], allow_fail=True)
            _run(["ipset", "add", seen, ip,
                  "timeout", str(IPSET_STALE_TTL)], allow_fail=True)

        # Remove IPs that are stale: absent from new resolution AND expired from seen-set.
        for ip in live_ips - new_ips:
            # ``ipset test`` exits 0 if the entry exists, non-zero if absent/expired.
            r = _run(["ipset", "test", seen, ip], allow_fail=True)
            if r.returncode != 0:
                # IP has not appeared in DNS for at least IPSET_STALE_TTL seconds.
                logging.info("Removing stale IP %s from ipset %s", ip, name)
                _run(["ipset", "del", name, ip], allow_fail=True)

        logging.debug("ipset %s refreshed: %d active IPs", name, len(new_ips))

    def _get_ipset_ips(self, name: str) -> set:
        """Return the set of IP addresses currently stored in a kernel ipset.

        Parses the text output of ``ipset list <name>``.  The output format is:
          ``Members:``   (header line)
          ``1.2.3.4``    (plain entry, no timeout)
          ``1.2.3.4 timeout 120 ...``  (entry with remaining TTL)
        Only the first token of each member line is taken as the IP address.
        Returns an empty set if the ipset does not exist or listing fails.
        """
        r = _run(["ipset", "list", name], allow_fail=True)
        if r.returncode != 0:
            return set()
        ips: set = set()
        in_members = False
        for line in r.stdout.splitlines():
            stripped = line.strip()
            if stripped == "Members:":
                # All subsequent non-empty lines until end-of-output are member entries.
                in_members = True
                continue
            if in_members and stripped:
                # Line may be "1.2.3.4" or "1.2.3.4 timeout 120 ..."
                ips.add(stripped.split()[0])
        return ips

    def destroy_by_names(self, names: List[str]) -> None:
        """Destroy named ipsets and their ``--seen`` / ``--tmp`` companion sets.

        Used during teardown.  Destroys all three variants of each ipset name
        with ``allow_fail=True`` so that absent sets are silently skipped.
        The ``--tmp`` suffix was used by an earlier swap-based refresh
        implementation; it is cleaned up here for compatibility.
        """
        for name in names:
            for suffix in ("--tmp", "--seen", ""):
                _run(["ipset", "destroy", name + suffix], allow_fail=True)


# ---------------------------------------------------------------------------
# IptablesManager
# ---------------------------------------------------------------------------

class IptablesManager:
    """Manages all Dockside iptables filter and nat rules.

    Rule architecture:
      FORWARD (policy DROP)
        └─ DOCKER-USER   (Docker's hook chain, evaluated before Docker's rules)
             └─ DOCKSIDE-DISPATCH  (jump target for each managed network)
                  ├─ <PREFIX>-ING  (intra-network ingress policy per network)
                  └─ <PREFIX>-OUT  (container egress policy per network)

    nat PREROUTING
      └─ <PREFIX>-NAT   (per-network DNAT rules; one chain per network with NAT)

    All Dockside filter chains are rebuilt atomically via a single
    ``iptables-restore --noflush`` call.  ``--noflush`` preserves Docker's
    own chains (DOCKER, DOCKER-USER, etc.) while completely replacing Dockside
    chains, so there is no window where the firewall is open.
    """

    def ensure_forward_drop(self) -> None:
        """Set the FORWARD chain default policy to DROP.

        Docker starts with FORWARD=ACCEPT; setting it to DROP ensures that
        any packet not explicitly permitted by a FORWARD rule (or by
        DOCKSIDE-DISPATCH via DOCKER-USER) is silently discarded.  This is
        the foundation of the deny-by-default posture.
        """
        _run(["iptables", "-P", "FORWARD", "DROP"])
        logging.debug("FORWARD policy set to DROP")

    def ensure_dispatch_chain(self) -> None:
        """Create DOCKSIDE-DISPATCH and ensure DOCKER-USER jumps to it.

        ``-N`` creates the chain; ``allow_fail=True`` ignores the error when
        it already exists (iptables exits non-zero with "Chain already exists").

        ``-C`` (check) probes whether the jump rule is already in DOCKER-USER
        without modifying anything.  Only when the check fails (rule absent)
        is ``-I … 1`` used to insert the jump at position 1 (top of the chain),
        so Dockside's rules run before any other DOCKER-USER rules.
        """
        # Create the chain; allow_fail handles "already exists" gracefully.
        _run(["iptables", "-N", "DOCKSIDE-DISPATCH"], allow_fail=True)
        # Check whether the jump rule already exists.
        r = _run(
            ["iptables", "-C", "DOCKER-USER", "-j", "DOCKSIDE-DISPATCH"],
            allow_fail=True,
        )
        if r.returncode != 0:
            # Rule is absent; insert it at the top of DOCKER-USER.
            logging.info("Adding DOCKER-USER → DOCKSIDE-DISPATCH jump")
            _run(["iptables", "-I", "DOCKER-USER", "1", "-j", "DOCKSIDE-DISPATCH"])

    def apply_config(self, config: Config) -> None:
        """Atomically apply all filter + nat rules via iptables-restore --noflush.

        Steps:
          1. Build the full iptables-restore input (filter + nat tables) as a
             single string via ``_build_restore_input``.
          2. Feed it to ``iptables-restore --noflush`` in one system call.
             ``--noflush`` preserves all chains not mentioned in the input
             (i.e. Docker's own chains) while atomically replacing Dockside
             chains.  This eliminates the open-firewall window that would occur
             if rules were applied incrementally.
          3. Add PREROUTING→NAT-chain jump rules separately for each network
             that has NAT rules (cannot be done via iptables-restore without
             flushing Docker's own PREROUTING entries).
        """
        # Only managed networks (those with gateway/rules configured) need chains.
        managed   = [s for s in config.networks if s.managed]
        nat_specs = [s for s in managed if s.nat_rules]

        restore_text = "\n".join(self._build_restore_input(managed, nat_specs)) + "\n"

        logging.debug("iptables-restore input:\n%s", restore_text)
        # Single atomic call: all Dockside chains are replaced with no gap.
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
        """Generate the full iptables-restore text for all Dockside chains.

        The output is structured as one or two iptables-restore "table blocks":
          ``*filter … COMMIT``  — always present.
          ``*nat … COMMIT``     — only when at least one network has NAT rules.

        Within each block the structure is: chain declarations, then flushes,
        then append rules.  This order is required by iptables-restore.

        Chain declaration syntax (e.g. ``:DOCKSIDE-DISPATCH - [0:0]``):
          Tells iptables-restore to create the chain if it does not already
          exist, and to zero its packet/byte counters.  The ``-`` is the
          chain's default policy (``-`` means "no policy", i.e. user-defined
          chain that falls through to the caller when all rules are exhausted).

        Flush (``-F CHAIN``):
          Removes all existing rules from the chain before new ones are added.
          Combined with ``iptables-restore --noflush`` this achieves an atomic
          replace of Dockside-owned chains without touching Docker's chains.

        Args:
            managed:   NetworkSpec objects that require firewall chains.
            nat_specs: Subset of managed that have at least one NAT rule.

        Returns:
            List of iptables-restore lines (one rule/directive per element).
        """
        lines: List[str] = []

        # ── filter table ──────────────────────────────────────────────────────
        lines.append("*filter")

        # 1. Declare all Dockside filter chains (creates them if absent; zeros counters).
        lines.append(":DOCKSIDE-DISPATCH - [0:0]")
        for spec in managed:
            p = spec.chain_prefix
            lines.append(f":{p}-ING - [0:0]")   # intra-network ingress chain
            lines.append(f":{p}-OUT - [0:0]")   # container egress chain

        # 2. Flush all Dockside filter chains so we start with a clean slate.
        lines.append("-F DOCKSIDE-DISPATCH")
        for spec in managed:
            p = spec.chain_prefix
            lines.append(f"-F {p}-ING")
            lines.append(f"-F {p}-OUT")

        # 3a. DOCKSIDE-DISPATCH: per-network dispatch jumps.
        #   Packets are classified into two categories:
        #     ING: same bridge on both -i and -o (container-to-container, intra-network).
        #     OUT: enters the bridge (-i) but exits a different interface (egress to host/internet).
        for spec in managed:
            dev = spec.dev
            p   = spec.chain_prefix
            # ING: intra-network traffic — both ingress and egress interface are the same bridge.
            lines.append(f"-A DOCKSIDE-DISPATCH -i {dev} -o {dev} -j {p}-ING")
            # OUT: egress traffic — enters the bridge, exits a different interface.
            #   Gateway traffic is excluded by _dispatch_out_match so it bypasses
            #   the per-network OUT chain and reaches the gateway exemptions below.
            out_match = IptablesManager._dispatch_out_match(spec)
            lines.append(f"-A DOCKSIDE-DISPATCH {out_match} -j {p}-OUT")

        # 3b. Gateway exemptions: allow the network gateway's own new outbound
        #   connections to pass without going through the OUT chain.  Matches by
        #   MAC address (more specific) or by source IP; both may be present.
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

        # 3c. Terminal RETURN: any packet not matched above (non-Dockside bridge)
        #   is returned to DOCKER-USER, which then returns to FORWARD.
        lines.append("-A DOCKSIDE-DISPATCH -j RETURN")

        # 4. Per-network ING chains — control NEW intra-network connections.
        #   Purpose: prevent containers from initiating connections to each other
        #   unless the packet originates from the gateway (which is trusted).
        #   ESTABLISHED/RELATED packets are not matched here (no ctstate filter
        #   on the DROP); they are allowed by Docker's FORWARD ACCEPT rule.
        for spec in managed:
            p  = spec.chain_prefix
            gm = spec.gateway_mac
            gi = spec.gateway_ip
            if gm:
                # Allow TCP NEW connections whose source MAC is the gateway MAC.
                lines.append(
                    f"-A {p}-ING -m mac --mac-source {gm} -p tcp"
                    f" -m conntrack --ctstate NEW -j RETURN"
                )
            if gi:
                # Allow TCP NEW connections whose source IP is the gateway IP.
                lines.append(
                    f"-A {p}-ING -s {gi} -p tcp"
                    f" -m conntrack --ctstate NEW -j RETURN"
                )
            # Drop all other new intra-network connections (lateral movement).
            lines.append(f"-A {p}-ING -m conntrack --ctstate NEW -j DROP")

        # 5. Per-network OUT chains — container egress policy.
        #   Each EgressRule is translated to zero or more iptables RETURN or
        #   REJECT/DROP lines by _egress_to_iptables().
        for spec in managed:
            p = spec.chain_prefix
            for rule in spec.egress_rules:
                lines.extend(IptablesManager._egress_to_iptables(f"{p}-OUT", rule))

        lines.append("COMMIT")

        # ── nat table ─────────────────────────────────────────────────────────
        # Only emitted when at least one managed network has NAT rules, to avoid
        # touching the nat table unnecessarily.
        if nat_specs:
            lines.append("*nat")

            # Declare each per-network NAT chain.
            for spec in nat_specs:
                p = spec.chain_prefix
                lines.append(f":{p}-NAT - [0:0]")

            for spec in nat_specs:
                p   = spec.chain_prefix
                dev = spec.dev
                # Flush the chain before repopulating (idempotent rebuild).
                lines.append(f"-F {p}-NAT")
                for nat in spec.nat_rules:
                    # Resolve the DNAT target IP from hostname or use literal IP.
                    to_ip = (
                        _resolve_hostname(nat.to_host) if nat.to_host else nat.to_ip
                    )
                    if not to_ip:
                        # Skip rules whose hostname can't be resolved; log and
                        # continue so other NAT rules in the same network still apply.
                        logging.warning(
                            "NAT rule for %s: could not resolve %r — skipped",
                            spec.name, nat.to_host,
                        )
                        continue
                    # DNAT: rewrite destination IP:port on packets entering the bridge
                    # whose destination port matches match_dport.
                    lines.append(
                        f"-A {p}-NAT -i {dev} -p {nat.proto}"
                        f" --dport {nat.match_dport}"
                        f" -j DNAT --to-destination {to_ip}:{nat.to_port}"
                    )

            lines.append("COMMIT")

        return lines

    @staticmethod
    def _dispatch_out_match(spec: NetworkSpec) -> str:
        """Build the iptables match fragment for the OUT dispatch rule.

        The fragment matches packets that:
          - enter the network's bridge interface (``-i <dev>``)
          - exit a *different* interface (``! -o <dev>`` — i.e. not looping back)
          - are *not* from the gateway (excluded so gateway traffic hits the
            gateway exemption rules in step 3b instead)

        Excluding gateway traffic from the OUT chain is important: the gateway
        is a trusted host whose egress should not be subject to container egress
        policy.

        Returns a string of iptables match options (no ``-j`` target) ready to
        be embedded in a ``-A DOCKSIDE-DISPATCH … -j <PREFIX>-OUT`` rule.
        """
        dev   = spec.dev
        gm    = spec.gateway_mac
        gi    = spec.gateway_ip
        # Start with the mandatory match: enters the bridge, exits elsewhere.
        parts = [f"-i {dev}", f"! -o {dev}"]
        if gm and gi:
            # Exclude by both MAC and IP when both are known (most specific).
            parts += [f"-m mac ! --mac-source {gm}", f"! -s {gi}"]
        elif gm:
            # Only MAC is known; exclude by MAC alone.
            parts.append(f"-m mac ! --mac-source {gm}")
        elif gi:
            # Only IP is known; exclude by source IP alone.
            parts.append(f"! -s {gi}")
        # If neither is set: all outbound traffic from the bridge is dispatched
        # into the OUT chain (no gateway exemption needed).
        return " ".join(parts)

    @staticmethod
    def _egress_to_iptables(chain: str, rule: EgressRule) -> List[str]:
        """Translate one EgressRule into zero or more iptables-restore rule lines.

        Drop rules:
          A drop rule emits two lines:
            1. REJECT with ``tcp-reset`` for TCP NEW connections (gives the
               sender an immediate RST so it does not hang waiting for a timeout).
            2. A plain DROP for all other traffic:
               - When ``cidr`` is set (targeted drop): matches *all* ctstates,
                 so even ESTABLISHED flows to that CIDR are killed.
               - When ``cidr`` is absent (terminal drop): matches only NEW so
                 that already-established connections elsewhere keep working.

        Allow rules:
          An allow rule emits a single RETURN line for NEW connections only.
          ESTABLISHED/RELATED packets for allowed flows are already accepted by
          Docker's FORWARD ACCEPT rule before they even reach DOCKSIDE-DISPATCH,
          so no ESTABLISHED match is needed here.

          Destination is selected by ``rule.to``:
            ``all``   → no ``-d`` filter (match any destination).
            ``cidr``  → ``-d <cidr>``.
            ``ip``    → ``-d <ip>``.
            ``host``  → resolve hostname to first IPv4; skip rule on failure.
            ``ipset`` → ``-m set --match-set <name> dst``.

        Args:
            chain: iptables chain name to append rules to (e.g. "DOCKSIDE-MYNET-OUT").
            rule:  EgressRule instance parsed from firewall-config.

        Returns:
            List of ``-A <chain> …`` rule lines for iptables-restore.
            Empty list if the rule is skipped (unresolvable host or unknown proto).
        """
        lines:  List[str] = []
        prefix  = f"-A {chain}"

        if rule.action == "drop":
            # Build destination filter using the same selectors as allow rules.
            if rule.cidr:
                dst = f"-d {rule.cidr} "
            elif rule.to == "ip" and rule.ip:
                dst = f"-d {rule.ip} "
            elif rule.to == "host" and rule.host:
                ip  = _resolve_hostname(rule.host)
                if not ip:
                    logging.warning(
                        "Egress drop rule: could not resolve host %r — rule skipped",
                        rule.host,
                    )
                    return []
                dst = f"-d {ip} "
            elif rule.to == "ipset" and rule.ipset:
                dst = f"-m set --match-set {rule.ipset} dst "
            else:
                dst = ""
            # TCP: RST response gives the client immediate feedback instead of
            # leaving it in SYN_SENT waiting for a timeout.
            lines.append(
                f"{prefix} {dst}-p tcp -m conntrack --ctstate NEW"
                f" -j REJECT --reject-with tcp-reset"
            )
            # Non-TCP: plain DROP.
            # Targeted drops (destination filter present) catch all ctstates so
            # existing flows to that destination are torn down immediately.
            # Terminal drops (no destination) restrict to NEW only to avoid
            # disrupting already-established flows to destinations not otherwise permitted.
            if dst:
                lines.append(f"{prefix} {dst}-j DROP")
            else:
                lines.append(f"{prefix} -m conntrack --ctstate NEW -j DROP")
            return lines

        # ── Allow rule: build destination selector ────────────────────────────
        if rule.to == "cidr" and rule.cidr:
            dst = f"-d {rule.cidr} "
        elif rule.to == "ip" and rule.ip:
            dst = f"-d {rule.ip} "
        elif rule.to == "host" and rule.host:
            # Resolve at apply-time; for frequently-changing addresses use "ipset".
            ip  = _resolve_hostname(rule.host)
            if not ip:
                logging.warning(
                    "Egress rule: could not resolve host %r — rule skipped", rule.host
                )
                return []
            dst = f"-d {ip} "
        elif rule.to == "ipset" and rule.ipset:
            # Match against a kernel ipset populated and refreshed by IpsetManager.
            dst = f"-m set --match-set {rule.ipset} dst "
        else:
            dst = ""  # to=all: no destination filter; matches any remote IP

        # ── Allow rule: build protocol + port match + RETURN target ───────────
        if rule.proto == "icmp":
            # ICMP does not use ports; match by ICMP type (e.g. echo-request).
            lines.append(
                f"{prefix} -p icmp --icmp-type {rule.icmp_type}"
                f" -m conntrack --ctstate NEW -j RETURN"
            )
        elif rule.proto in ("tcp", "udp") and rule.ports:
            # Use the ``multiport`` extension to match a comma-separated list of
            # destination port numbers in a single rule (more efficient than one
            # rule per port).
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
        """Add a PREROUTING → <chain_name> jump in the nat table if absent.

        Uses ``-C`` (check) to probe without modifying, then ``-A`` (append)
        only when the jump is missing.  This is done outside iptables-restore
        because including PREROUTING in a restore block would require flushing
        it, which would destroy Docker's own PREROUTING MASQUERADE rules.

        Args:
            chain_name: NAT chain name, e.g. ``"DOCKSIDE-MYNET-NAT"``.
        """
        r = _run(
            ["iptables", "-t", "nat", "-C", "PREROUTING", "-j", chain_name],
            allow_fail=True,
        )
        if r.returncode != 0:
            # Jump absent; append it so PREROUTING evaluates this NAT chain.
            logging.info("Adding PREROUTING → %s jump", chain_name)
            _run(["iptables", "-t", "nat", "-A", "PREROUTING", "-j", chain_name])

    def teardown(self) -> None:
        """Remove all Dockside iptables state.

        Teardown order:
          1. Remove the DOCKER-USER → DOCKSIDE-DISPATCH jump rule so Dockside
             is immediately bypassed for new connections.
          2. Remove any PREROUTING → DOCKSIDE-*-NAT jump rules.  These are
             found by parsing ``iptables -t nat -S PREROUTING`` output and
             cannot be flushed via ``iptables-restore`` without destroying
             Docker's own PREROUTING rules.
          3. Flush then delete all DOCKSIDE-* user chains in the filter table.
          4. Flush then delete all DOCKSIDE-* user chains in the nat table.

        All individual steps use ``allow_fail=True`` so that a partially-torn-
        down state (e.g. some chains already absent) does not abort the process.
        """
        logging.info("Starting iptables teardown")

        # Step 1: remove the hook into DOCKER-USER so Dockside is bypassed.
        _run(
            ["iptables", "-D", "DOCKER-USER", "-j", "DOCKSIDE-DISPATCH"],
            allow_fail=True,
        )

        # Step 2: remove PREROUTING → DOCKSIDE-*-NAT jump rules.
        # ``-S PREROUTING`` lists rules in save format, e.g.:
        #   -A PREROUTING -j DOCKSIDE-MYNET-NAT
        # Strip "-A PREROUTING" to get the remaining arguments, then use ``-D``
        # with those same arguments to delete the rule.
        r = _run(
            ["iptables", "-t", "nat", "-S", "PREROUTING"], allow_fail=True
        )
        if r.returncode == 0:
            for line in r.stdout.splitlines():
                if "-j DOCKSIDE-" in line:
                    # Convert "-A PREROUTING <opts>" → ["<opts>"…] for -D.
                    del_args = line.replace("-A PREROUTING", "", 1).split()
                    _run(
                        ["iptables", "-t", "nat", "-D", "PREROUTING"] + del_args,
                        allow_fail=True,
                    )

        # Step 3: flush then delete all DOCKSIDE-* chains in the filter table.
        # Flush (-F) must come before delete (-X) because iptables refuses to
        # delete a non-empty chain.
        for chain in self._list_dockside_chains("filter"):
            _run(["iptables", "-F", chain], allow_fail=True)
            _run(["iptables", "-X", chain], allow_fail=True)

        # Step 4: flush then delete all DOCKSIDE-* chains in the nat table.
        for chain in self._list_dockside_chains("nat"):
            _run(["iptables", "-t", "nat", "-F", chain], allow_fail=True)
            _run(["iptables", "-t", "nat", "-X", chain], allow_fail=True)

        logging.info("iptables teardown complete")

    @staticmethod
    def _list_dockside_chains(table: str) -> List[str]:
        """Return names of all DOCKSIDE-* user chains in the given iptables table.

        Uses ``iptables [-t <table>] -S`` which prints all rules and chain
        declarations in save format.  Chain declaration lines look like:
          ``-N DOCKSIDE-MYNET-OUT``
        Only ``-N`` (new-chain) lines are considered; rule lines (``-A``, ``-P``)
        are ignored.  The second token of each ``-N`` line is the chain name.

        Args:
            table: iptables table name, e.g. ``"filter"`` or ``"nat"``.
                   For ``"filter"`` no ``-t`` flag is passed (default table).

        Returns:
            List of Dockside chain names found in the table.
        """
        # Omit -t flag for the filter table (it is the default).
        flags = ["-t", table] if table != "filter" else []
        r = _run(["iptables"] + flags + ["-S"], allow_fail=True)
        if r.returncode != 0:
            return []
        chains = []
        for line in r.stdout.splitlines():
            # -N lines declare user-defined chains; only pick Dockside-owned ones.
            if line.startswith("-N DOCKSIDE-"):
                chains.append(line.split()[1])
        return chains


# ---------------------------------------------------------------------------
# ManagementSocket
# ---------------------------------------------------------------------------

class ManagementSocket:
    """Unix-domain socket server for runtime daemon management.

    Listens on an AF_UNIX SOCK_STREAM socket.  Each client connection sends a
    single newline-terminated JSON object (the request) and receives a single
    newline-terminated JSON object (the response).

    Protocol:
      Request:  ``{"action": "<action>", …}\\n``
      Response: ``{"status": "ok"|"error", …}\\n``

    The server runs its accept loop in a daemon thread; each accepted
    connection is handled in its own short-lived daemon thread.  All
    connections share the caller-supplied ``handler`` callable, which must be
    thread-safe (FirewallDaemon uses ``self._lock`` for this purpose).
    """

    def __init__(self):
        # The listening server socket; None until start() is called.
        self._server: Optional[socket.socket] = None
        # Set by stop() to signal the accept loop to exit.
        self._stop    = threading.Event()
        # Callable invoked with the parsed request dict; returns response dict.
        self._handler = None

    def start(self, path: str, handler) -> None:
        """Create the socket file, start listening, and launch the accept thread.

        If a socket file already exists at ``path`` it is removed first; a
        stale socket from a previous run would otherwise prevent ``bind()``.

        Permissions are set to 0o660 (owner + group read/write, no world
        access) so that only processes in the same group (e.g. the dockside
        service group) can connect.

        Args:
            path:    Filesystem path for the Unix-domain socket.
            handler: Callable(req: dict) → dict; must be thread-safe.
        """
        # Remove stale socket file from a previous run so bind() can succeed.
        if os.path.exists(path):
            os.unlink(path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
        try:
            # 0o660: owner+group can connect; world cannot.
            os.chmod(path, 0o660)
        except OSError:
            pass
        # Backlog of 5: at most 5 connections may queue while the accept loop
        # is busy; additional connections will be refused by the kernel.
        srv.listen(5)
        self._server  = srv
        self._handler = handler
        t = threading.Thread(
            target=self._accept_loop, daemon=True, name="mgmt-socket"
        )
        t.start()
        logging.info("Management socket listening at %s", path)

    def stop(self) -> None:
        """Signal the accept loop to exit and close the server socket.

        Closing the socket causes the blocking ``accept()`` in the accept loop
        to raise ``OSError``, which the loop catches as its exit condition.
        """
        self._stop.set()
        if self._server:
            try:
                self._server.close()
            except Exception:
                pass

    def _accept_loop(self) -> None:
        """Accept connections in a loop, spawning a handler thread per connection.

        Exits when the stop event is set or when the server socket is closed
        (``accept()`` raises ``OSError``).  Each connection is handled in its
        own daemon thread so a slow client does not block others.
        """
        while not self._stop.is_set():
            try:
                conn, _ = self._server.accept()
            except OSError:
                # Server socket closed by stop() or an unrecoverable error.
                break
            threading.Thread(
                target=self._handle_conn, args=(conn,), daemon=True
            ).start()

    def _handle_conn(self, conn: socket.socket) -> None:
        """Read one newline-terminated JSON request, dispatch it, send JSON response.

        Reads in 4 KiB chunks until a newline is found (end of request) or a
        1 MiB hard limit is reached (runaway client guard).  On any exception
        during dispatch or serialisation, an error JSON is sent back to the
        client before the connection is closed.

        The ``finally`` block ensures the connection is always closed, even on
        unexpected exceptions, so file descriptors are not leaked.
        """
        try:
            buf = b""
            # Accumulate bytes until we see a newline (end of request) or the
            # buffer exceeds 1 MiB (protection against a client that sends
            # data without ever sending a newline).
            while b"\n" not in buf and len(buf) < 1024 * 1024:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
            if buf.strip():
                req  = json.loads(buf.decode())
                resp = self._handler(req)
                # Newline-terminate the response so the client can detect
                # the end of the message without relying on connection close.
                conn.sendall((json.dumps(resp) + "\n").encode())
        except Exception as exc:
            # Best-effort error reply; ignore send failure (client may have gone).
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
    """Top-level daemon that wires DockerNetworkManager, IpsetManager and
    IptablesManager together, handles signals, and runs the ipset refresh loop.

    Thread model:
      Main thread      — blocks on ``_stop.wait()`` after startup; handles signals.
      ipset-refresh    — daemon thread; re-resolves all ipsets every
                         IPSET_REFRESH_INTERVAL seconds.
      mgmt-socket      — daemon thread (if ``socket_path`` provided); accepts
                         management connections.
      config-reload    — short-lived daemon thread spawned on SIGUSR1.
      per-connection   — short-lived daemon threads spawned by ManagementSocket.

    Thread safety:
      ``_lock`` serialises all operations that mutate kernel state (ipset
      membership, iptables rules).  Signal handlers must return quickly, so
      SIGUSR1 off-loads the reload work to a daemon thread.

    Lifecycle:
      1. ``run()`` registers signal handlers, applies config, starts socket and
         refresh thread, notifies systemd READY=1, then blocks until signalled.
      2. On SIGTERM/SIGINT, ``_stop`` is set; ``run()`` unblocks and exits.
         iptables rules are deliberately left in place so containers remain
         protected during a ``systemctl restart``.  Use ``--teardown`` to
         remove them explicitly.
    """

    def __init__(
        self,
        network_config_path: str,
        firewall_config_path: str,
        socket_path: Optional[str] = None,
    ):
        # Paths to the two JSON config files; reloaded on SIGUSR1 or "reload" action.
        self._net_path  = network_config_path
        self._fw_path   = firewall_config_path
        # Optional path for the management Unix socket; None = no socket.
        self._sock_path = socket_path
        # Mutex protecting all kernel-state mutations from concurrent threads.
        self._lock      = threading.Lock()
        # Set by signal handlers to stop the main thread and clean up.
        self._stop      = threading.Event()
        # Currently active Config; None until first _apply_full() succeeds.
        self._config: Optional[Config] = None

        self._docker_mgr = DockerNetworkManager()
        self._ipset_mgr  = IpsetManager()
        self._ipt_mgr    = IptablesManager()
        self._socket     = ManagementSocket()

    def run(self) -> None:
        """Start the daemon: apply config, start threads, block until stopped.

        Startup sequence:
          1. Install signal handlers for SIGTERM, SIGINT (graceful shutdown)
             and SIGUSR1 (config reload — maps to ``ExecReload=`` in the
             systemd unit).
          2. Load config from disk and call _apply_full to set up Docker
             networks, ipsets, and iptables rules.
          3. Start the management socket (if configured).
          4. Notify systemd ``READY=1`` (service is live).
          5. Start the ipset-refresh background thread.
          6. Block the main thread on ``_stop.wait()`` — exits when a shutdown
             signal is received.
          7. Stop the management socket and log exit.
        """
        signal.signal(signal.SIGTERM, self._on_shutdown)
        signal.signal(signal.SIGINT,  self._on_shutdown)
        # SIGUSR1 triggers config reload; systemd sends this on ``systemctl reload``.
        signal.signal(signal.SIGUSR1, self._on_sigusr1)

        self._config = Config.from_files(self._net_path, self._fw_path)
        self._apply_full(
            self._config, reset=(os.environ.get("RESET", "0") == "1")
        )

        if self._sock_path:
            self._socket.start(self._sock_path, self._handle_request)

        # Notify systemd that startup is complete and the daemon is ready to
        # accept work.  Ignored if not running under systemd.
        _systemd_notify("READY=1")
        logging.info("Daemon ready. ipset refresh every %ds.", IPSET_REFRESH_INTERVAL)

        refresh_t = threading.Thread(
            target=self._refresh_loop, daemon=True, name="ipset-refresh"
        )
        refresh_t.start()

        # Block the main thread until a shutdown signal sets ``_stop``.
        self._stop.wait()

        if self._sock_path:
            self._socket.stop()

        # iptables rules are intentionally preserved on shutdown so containers
        # remain protected while a new daemon instance starts (zero-gap restart).
        logging.info(
            "Daemon stopped. iptables rules left in place "
            "(use --teardown for explicit cleanup)."
        )

    def _apply_full(self, config: Config, reset: bool = False) -> None:
        """Perform a full one-shot configuration apply.

        Applies all subsystems in dependency order:
          1. Kernel inotify limits (carried over from the original bash script;
             needed for file-watch-heavy workloads running inside containers).
          2. Docker networks — must exist before iptables rules reference their
             bridge interface names.
          3. FORWARD default policy set to DROP.
          4. DOCKSIDE-DISPATCH chain and DOCKER-USER jump.
          5. ipsets — must exist before iptables rules reference them by name.
          6. iptables filter + nat rules.

        Args:
            config: Config to apply.
            reset:  Passed through to DockerNetworkManager.ensure_networks();
                    when True, existing Docker networks are destroyed and
                    recreated.
        """
        # System tuning carried over from the original bash script.
        _run(
            [
                "sysctl",
                "fs.inotify.max_user_watches=524288",
                "fs.inotify.max_user_instances=8192",
            ],
            allow_fail=True,  # Not fatal if sysctl fails (e.g. insufficient privilege).
        )
        self._docker_mgr.ensure_networks(config.networks, reset=reset)
        self._ipt_mgr.ensure_forward_drop()
        self._ipt_mgr.ensure_dispatch_chain()
        for name, hostnames in config.ipsets.items():
            self._ipset_mgr.ensure_ipset(name, hostnames)
        self._ipt_mgr.apply_config(config)

    def _refresh_loop(self) -> None:
        """Periodically re-resolve all hostname-backed ipsets.

        Uses ``_stop.wait(timeout=…)`` as an interruptible sleep: it returns
        False after the timeout (time to refresh) or True early if the stop
        event is set (daemon is shutting down, exit the loop immediately).
        The ``with self._lock`` ensures the refresh does not race with a
        concurrent config reload triggered by SIGUSR1 or a socket "reload"
        action.
        """
        while not self._stop.wait(timeout=IPSET_REFRESH_INTERVAL):
            try:
                with self._lock:
                    self._ipset_mgr.refresh_all()
            except Exception:
                logging.exception("ipset refresh error")

    def _on_shutdown(self, signum, frame) -> None:
        """SIGTERM / SIGINT handler: set the stop event to unblock run()."""
        logging.info("Signal %d received — shutting down", signum)
        self._stop.set()

    def _on_sigusr1(self, signum, frame) -> None:
        """SIGUSR1 handler: trigger a config reload in a background thread.

        Signal handlers must return quickly (they run on the main thread and
        can interrupt any other operation), so the actual reload work is
        delegated to a short-lived daemon thread.
        """
        logging.info("SIGUSR1 received — reloading config")
        threading.Thread(
            target=self._reload, daemon=True, name="config-reload"
        ).start()

    def _reload(self) -> None:
        """Load config from disk and atomically apply it while holding _lock.

        Acquires ``_lock`` for the apply phase so the refresh loop cannot
        concurrently modify ipset state.  On any error the existing config
        remains active (partial failure does not corrupt state because
        IptablesManager.apply_config uses atomic iptables-restore).
        """
        try:
            new_config = Config.from_files(self._net_path, self._fw_path)
            with self._lock:
                self._docker_mgr.ensure_networks(new_config.networks)
                for name, hostnames in new_config.ipsets.items():
                    self._ipset_mgr.ensure_ipset(name, hostnames)
                # Refresh immediately after updating ipset membership so rules
                # that reference newly-added ipsets are populated before use.
                self._ipset_mgr.refresh_all()
                self._ipt_mgr.apply_config(new_config)
                self._config = new_config
            logging.info("Config reload complete")
        except Exception:
            logging.exception("Config reload failed")

    def _handle_request(self, req: dict) -> dict:
        """Dispatch a management socket request to the appropriate handler.

        Supported actions:
          ``reload``  — reload config from disk (same as SIGUSR1).
          ``apply``   — apply an inline config supplied in the request body;
                        the request must contain ``network_config`` and
                        ``firewall_config`` dict keys matching the JSON file
                        structure.
          ``refresh`` — re-resolve all ipsets immediately without reloading
                        the rest of the config.
          ``status``  — return current daemon state (networks and live ipset IPs).

        All mutating actions are serialised by ``_lock``.  Any exception is
        caught and returned as ``{"status": "error", "message": "…"}``.

        Args:
            req: Parsed request dict from the management socket.

        Returns:
            Response dict to be serialised and sent back to the client.
        """
        action = req.get("action", "")
        try:
            if action == "reload":
                # Reload config from disk; same effect as SIGUSR1.
                self._reload()
                return {"status": "ok"}
            elif action == "apply":
                # Apply an inline config provided in the request body.
                # Useful for programmatic config updates without touching files.
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
                # Re-resolve ipsets immediately; does not reload other config.
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
        """Return a status dict describing the current daemon state.

        Includes the list of configured network names and a snapshot of the
        live IP addresses currently in each ipset.  IPs are sorted for
        deterministic output (useful when diffing successive status calls).

        Returns:
            ``{"status": "ok", "ready": True, "networks": […], "ipsets": {…}}``
            or ``{"status": "ok", "ready": False}`` before first apply.
        """
        cfg = self._config
        if not cfg:
            # Daemon started but _apply_full has not completed yet.
            return {"status": "ok", "ready": False}
        return {
            "status":   "ok",
            "ready":    True,
            "networks": [s.name for s in cfg.networks],
            "ipsets":   {
                # Snapshot live kernel ipset membership (not the hostname list).
                name: sorted(self._ipset_mgr._get_ipset_ips(name))
                for name in cfg.ipsets
            },
        }


# ---------------------------------------------------------------------------
# Socket client helper (for --status)
# ---------------------------------------------------------------------------

def _socket_query(sock_path: str, req: dict) -> dict:
    """Send a JSON request to a running daemon's management socket and return the response.

    Connects to the AF_UNIX socket at ``sock_path``, sends the request as a
    newline-terminated JSON line, and reads back a newline-terminated JSON
    response.  The ``finally`` block guarantees the socket is closed even if
    an exception is raised during send or receive.

    Args:
        sock_path: Path to the daemon's Unix-domain socket.
        req:       Request dict (e.g. ``{"action": "status"}``).

    Returns:
        Parsed response dict from the daemon.

    Raises:
        ConnectionRefusedError: if no daemon is listening at ``sock_path``.
        json.JSONDecodeError:   if the response is malformed.
    """
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    try:
        # Newline-terminate the request so the daemon's _handle_conn exits
        # its accumulation loop.
        s.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        # Read until newline (end of response) or connection closed.
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
    """Parse CLI arguments and dispatch to the appropriate operating mode.

    Operating modes (mutually exclusive; evaluated in order):

    1. ``--status``    Connect to a running daemon via the management socket
                       and print its status as formatted JSON, then exit.
                       Requires ``--socket`` (or ``$DOCKSIDE_FIREWALL_SOCKET``).

    2. ``--teardown``  Remove all Dockside iptables chains and ipsets, then exit.
                       Attempts to load config files to discover ipset names; on
                       failure (config missing/invalid) ipsets are not cleaned up
                       but iptables teardown still proceeds.

    3. ``--daemon``    Full daemon mode: apply config, start management socket
                       and ipset-refresh thread, block until signalled.

    4. (no flags)      One-shot mode: apply config once and exit.  Backwards-
                       compatible with the original bash script invocation.
                       The management socket is not started in this mode.

    The RESET=1 environment variable causes Docker networks to be removed and
    recreated on startup (useful after subnet changes).
    """
    import argparse

    # Pull the "CLI modes:" section from the module docstring as epilog text.
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
        # Allow the socket path to be set via environment variable so the
        # systemd unit does not need to hard-code it.
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
        # Query the running daemon and pretty-print its JSON status response.
        resp = _socket_query(args.socket, {"action": "status"})
        print(json.dumps(resp, indent=2))
        return

    if args.teardown:
        # Try to read config to learn ipset names so they can be destroyed.
        # Tolerate config load failures: if config files are gone, ipset
        # cleanup is skipped but iptables teardown still proceeds.
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
        # Only pass the socket path in daemon mode; one-shot mode has no socket.
        socket_path=args.socket if args.daemon else None,
    )

    if args.daemon:
        # Full daemon: runs until signalled.
        daemon.run()
    else:
        # One-shot: apply config and exit (backwards-compatible with bash one-shot mode).
        # No management socket, no refresh loop.
        config = Config.from_files(args.network_config, args.firewall_config)
        daemon._apply_full(config, reset=(os.environ.get("RESET", "0") == "1"))


if __name__ == "__main__":
    main()
