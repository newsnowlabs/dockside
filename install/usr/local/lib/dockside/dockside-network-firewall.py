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

import ipaddress
import json
import logging
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import tempfile
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
# Config value validators
# ---------------------------------------------------------------------------
# All validators raise ValueError with a descriptive message on bad input so
# that Config.from_dicts() / Config.from_files() aborts before any kernel
# mutation is attempted.  They are intentionally strict: allow-list rather
# than deny-list.

_IDENTIFIER_RE = re.compile(r'^[A-Za-z0-9_.:-]+$')
_MAC_RE         = re.compile(r'^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$')
_VALID_PROTOS   = frozenset({"tcp", "udp", "icmp"})
_VALID_ACTIONS  = frozenset({"allow", "drop"})
_VALID_TO       = frozenset({"all", "cidr", "ip", "ipset", "host"})


def _val_identifier(value: str, field: str, max_len: int = 64) -> None:
    """Validate a name used as an iptables chain/network/ipset identifier.

    Accepts only ``[A-Za-z0-9_.:-]`` so that the value is safe to interpolate
    directly into iptables-restore text without risk of injecting rule tokens.
    """
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field}: expected non-empty string, got {value!r}")
    if len(value) > max_len:
        raise ValueError(f"{field}: identifier too long ({len(value)} > {max_len})")
    if not _IDENTIFIER_RE.match(value):
        raise ValueError(
            f"{field}: {value!r} contains characters outside [A-Za-z0-9_.:-]"
        )


def _val_iface(value: str, field: str) -> None:
    """Validate a Linux network interface name (IFNAMSIZ-1 = 15 chars max)."""
    _val_identifier(value, field, max_len=15)


def _val_ip(value: str, field: str) -> None:
    """Validate an IPv4 address string using the stdlib ipaddress module."""
    try:
        ipaddress.IPv4Address(value)
    except ValueError:
        raise ValueError(f"{field}: {value!r} is not a valid IPv4 address")


def _val_cidr(value: str, field: str) -> None:
    """Validate an IPv4 CIDR string (host bits need not be zero)."""
    try:
        ipaddress.IPv4Network(value, strict=False)
    except ValueError:
        raise ValueError(f"{field}: {value!r} is not a valid IPv4 CIDR")


def _val_mac(value: str, field: str) -> None:
    """Validate a colon-separated MAC address (e.g. ``aa:bb:cc:dd:ee:ff``)."""
    if not isinstance(value, str) or not _MAC_RE.match(value):
        raise ValueError(f"{field}: {value!r} is not a valid MAC address")


def _val_proto(value: str, field: str) -> None:
    """Validate a transport-layer protocol name."""
    if value not in _VALID_PROTOS:
        raise ValueError(
            f"{field}: {value!r} is not a supported protocol; "
            f"must be one of {sorted(_VALID_PROTOS)}"
        )


def _val_port(value, field: str) -> None:
    """Validate a TCP/UDP port number (1–65535)."""
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"{field}: port must be an integer, got {value!r}")
    if not 1 <= value <= 65535:
        raise ValueError(f"{field}: port {value} is out of range 1–65535")


def _val_comment(value: str, field: str, max_len: int = 200) -> None:
    """Validate a free-text comment: no control characters, bounded length.

    iptables comments are embedded in rule text; newlines and other control
    characters could corrupt the iptables-restore input stream.
    """
    if not isinstance(value, str):
        raise ValueError(f"{field}: expected string, got {type(value).__name__!r}")
    if len(value) > max_len:
        raise ValueError(f"{field}: comment too long ({len(value)} > {max_len})")
    for ch in value:
        if ord(ch) < 0x20 or ord(ch) == 0x7F:
            raise ValueError(
                f"{field}: comment contains control character "
                f"U+{ord(ch):04X} — not permitted"
            )


def _val_icmp_type(value: str, field: str) -> None:
    """Validate an ICMP type string (name or decimal number, no control chars)."""
    _val_comment(value, field, max_len=40)


def _val_host_entry(value: str, field: str) -> None:
    """Validate one entry in an ipset host list: IP, CIDR, or hostname.

    Hostnames are not resolved here; we only check for control characters and
    an identifier-safe character set to prevent injection into ipset commands.
    """
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field}: expected non-empty string, got {value!r}")
    for ch in value:
        if ord(ch) < 0x20 or ord(ch) == 0x7F:
            raise ValueError(
                f"{field}: entry {value!r} contains control character U+{ord(ch):04X}"
            )
    # Reject characters that could be interpreted as shell metacharacters or
    # iptables option delimiters when used in ipset add/test commands.
    if re.search(r'[\s\'"\\;|&<>]', value):
        raise ValueError(
            f"{field}: entry {value!r} contains a disallowed character"
        )


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

        # Optional human-readable description of the rule; transferred verbatim
        # to iptables via ``-m comment --comment "..."`` so it appears in
        # ``iptables -L`` output alongside the rule.
        self.comment   = d.get("comment")              # str|None

        # ── Validate all fields before any rule generation can use them ──────
        if self.action not in _VALID_ACTIONS:
            raise ValueError(
                f"egress rule: action {self.action!r} is not valid; "
                f"must be one of {sorted(_VALID_ACTIONS)}"
            )
        if self.to not in _VALID_TO:
            raise ValueError(
                f"egress rule: to {self.to!r} is not valid; "
                f"must be one of {sorted(_VALID_TO)}"
            )
        if self.proto is not None:
            _val_proto(self.proto, "egress rule: proto")
        for p in self.ports:
            _val_port(p, "egress rule: ports entry")
        if self.cidr is not None:
            _val_cidr(self.cidr, "egress rule: cidr")
        if self.ip is not None:
            _val_ip(self.ip, "egress rule: ip")
        if self.ipset is not None:
            _val_identifier(self.ipset, "egress rule: ipset")
        if self.comment is not None:
            _val_comment(self.comment, "egress rule: comment")
        if self.proto == "icmp":
            _val_icmp_type(self.icmp_type, "egress rule: type")

    def to_dict(self) -> dict:
        """Serialise back to the JSON dict form used in firewall-config.json.

        Only non-default, non-None fields are emitted so the round-trip output
        stays as compact as the original input.  The ``action`` key is omitted
        when it is ``"allow"`` (the default); it is always emitted for
        ``"drop"`` rules.  The ``"type"`` key (ICMP type) is only emitted when
        ``proto`` is ``"icmp"``.
        """
        d: dict = {}
        if self.action != "allow":
            d["action"] = self.action
        if self.proto:
            d["proto"] = self.proto
        if self.ports:
            d["ports"] = self.ports
        d["to"] = self.to
        if self.cidr:
            d["cidr"] = self.cidr
        if self.ip:
            d["ip"] = self.ip
        if self.ipset:
            d["ipset"] = self.ipset
        if self.host:
            d["host"] = self.host
        if self.proto == "icmp":
            d["type"] = self.icmp_type
        if self.comment:
            d["comment"] = self.comment
        return d

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

        # ── Validate all fields ───────────────────────────────────────────────
        _val_proto(self.proto, "nat rule: proto")
        if self.match_dport is not None:
            _val_port(self.match_dport, "nat rule: match_dport")
        if self.to_ip is not None:
            _val_ip(self.to_ip, "nat rule: to_ip")
        if self.to_port is not None:
            _val_port(self.to_port, "nat rule: to_port")

    def to_dict(self) -> dict:
        """Serialise back to the JSON dict form used in firewall-config.json."""
        d: dict = {"proto": self.proto}
        if self.match_dport is not None:
            d["match_dport"] = self.match_dport
        if self.to_host:
            d["to_host"] = self.to_host
        if self.to_ip:
            d["to_ip"] = self.to_ip
        if self.to_port is not None:
            d["to_port"] = self.to_port
        return d


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

        # Optional explicit gateway IP for Docker network creation.  When absent,
        # derived automatically from the subnet by ``_subnet_to_gateway()``
        # (first host, i.e. x.x.x.1).  Not used for iptables rule matching;
        # see ``dockside_ip`` for that purpose.
        self.gateway_ip  = d.get("gateway_ip")

        # Optional source IP of the dockside container on this network (typically
        # the x.x.x.2 host).  When provided, DOCKSIDE-DISPATCH rules use ``-s``
        # to identify traffic originating from the dockside container and exempt
        # it from the per-network OUT chain / allow it through the ING chain.
        self.dockside_ip  = d.get("dockside_ip")

        # Optional MAC address of the dockside container's interface on this
        # network.  When provided, DOCKSIDE-DISPATCH rules use ``--mac-source``
        # to identify dockside-container traffic.  Either ``dockside_ip``,
        # ``dockside_mac``, or both may be set; at least one is needed for the
        # network to be "managed" (unless egress/NAT rules are present).
        self.dockside_mac = d.get("dockside_mac")

        # ── Validate topology fields ──────────────────────────────────────────
        # Network name is used as part of iptables chain names and the Docker
        # bridge device name; it must be safe for both contexts.
        _val_identifier(self.name, "network: name")
        _val_cidr(self.subnet, "network: subnet")
        if self.gateway_ip is not None:
            _val_ip(self.gateway_ip, "network: gateway_ip")
        if self.dockside_ip is not None:
            _val_ip(self.dockside_ip, "network: dockside_ip")
        if self.dockside_mac is not None:
            _val_mac(self.dockside_mac, "network: dockside_mac")

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

        An "unmanaged" network (no dockside container IP/MAC configured, no
        egress or NAT rules) does not require custom firewall chains; its
        traffic flows through Docker's default FORWARD rules unchanged.  Only
        managed networks get entries in the DOCKSIDE-DISPATCH jump chain.
        """
        return bool(
            self.dockside_ip or self.dockside_mac
            or self.egress_rules or self.nat_rules
        )

    def to_net_dict(self) -> dict:
        """Serialise the network topology fields to a network-config.json entry.

        Returns a dict suitable for inclusion in the ``"networks"`` array of
        network-config.json.  Optional fields (``gateway_ip``, ``dockside_ip``,
        ``dockside_mac``) are omitted when not set so the output stays compact.
        """
        d: dict = {"name": self.name, "subnet": self.subnet}
        if self.gateway_ip:
            d["gateway_ip"] = self.gateway_ip
        if self.dockside_ip:
            d["dockside_ip"] = self.dockside_ip
        if self.dockside_mac:
            d["dockside_mac"] = self.dockside_mac
        return d

    def to_fw_dict(self) -> Optional[dict]:
        """Serialise the firewall rules to a firewall-config.json network entry.

        Returns a dict with ``"egress"`` and/or ``"nat"`` keys, or ``None``
        when the network has no firewall rules (so it can be omitted from the
        ``"networks"`` map in firewall-config.json rather than emitting an
        empty object).
        """
        if not self.egress_rules and not self.nat_rules:
            return None
        d: dict = {}
        if self.egress_rules:
            d["egress"] = [r.to_dict() for r in self.egress_rules]
        if self.nat_rules:
            d["nat"] = [r.to_dict() for r in self.nat_rules]
        return d

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

        # Collect ipset definitions (name → list of hosts/CIDRs) and validate.
        ipsets = fw_data.get("ipsets", {})
        for set_name, entries in ipsets.items():
            _val_identifier(set_name, "ipset name")
            if not isinstance(entries, list):
                raise ValueError(
                    f"ipset {set_name!r}: expected a list of host entries, "
                    f"got {type(entries).__name__!r}"
                )
            for entry in entries:
                _val_host_entry(entry, f"ipset {set_name!r}: entry")

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

    def network_names(self) -> set:
        """Return the set of network names in this config."""
        return {s.name for s in self.networks}

    def ipset_referenced_names(self) -> set:
        """Return the set of ipset names referenced by any egress rule.

        Used by the cleanup phase to determine which ipsets are still "live"
        (referenced by at least one iptables rule in the current config) and
        must not be destroyed even if they were removed from ``self.ipsets``.
        """
        names: set = set()
        for spec in self.networks:
            for rule in spec.egress_rules:
                if rule.to == "ipset" and rule.ipset:
                    names.add(rule.ipset)
        return names

    def to_net_data(self) -> dict:
        """Reconstruct the network-config.json top-level dict from this Config."""
        return {"networks": [s.to_net_dict() for s in self.networks]}

    def to_fw_data(self) -> dict:
        """Reconstruct the firewall-config.json top-level dict from this Config.

        ``"ipsets"`` is only emitted when there are ipsets defined (avoids an
        empty ``"ipsets": {}`` key in the output file).  Networks with no
        firewall rules are omitted from ``"networks"`` (same as the source
        files typically do).
        """
        fw_nets: dict = {}
        for s in self.networks:
            fw = s.to_fw_dict()
            if fw is not None:
                fw_nets[s.name] = fw
        result: dict = {}
        if self.ipsets:
            result["ipsets"] = dict(self.ipsets)
        result["networks"] = fw_nets
        return result


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
# Config-diff helpers
# ---------------------------------------------------------------------------

def _diff_configs(
    old: Optional["Config"],
    new: "Config",
) -> tuple:
    """Compute what was removed between two Config objects.

    Returns a 2-tuple ``(removed_nets, removed_ipsets)`` where each element
    is a ``set`` of name strings that are present in *old* but absent in *new*.
    When *old* is ``None`` (first apply; no previous state) both sets are empty.

    Pure Python — no kernel calls, no side effects.
    """
    if old is None:
        return set(), set()
    removed_nets   = old.network_names()   - new.network_names()
    removed_ipsets = set(old.ipsets.keys()) - set(new.ipsets.keys())
    return removed_nets, removed_ipsets


def _network_has_containers(name: str) -> bool:
    """Return True if a Docker network currently has containers connected.

    Parses the JSON output of ``docker network inspect <name>``.  The
    ``Containers`` key in the top-level object is a dict whose keys are
    container IDs; an empty dict means no containers are attached.

    On any parse failure (invalid JSON, unexpected structure) the function
    returns ``True`` — the conservative choice — to prevent a buggy inspect
    output from causing unintended chain deletion.

    Args:
        name: Docker network name.

    Returns:
        True if the network has connected containers (or if the check fails
        conservatively), False if the network has no containers or does not
        exist.
    """
    r = _run(["docker", "network", "inspect", name], allow_fail=True)
    if r.returncode != 0:
        # Network does not exist in Docker; nothing to protect.
        return False
    try:
        data = json.loads(r.stdout)
        if not data:
            return False
        containers = data[0].get("Containers", {})
        return bool(containers)
    except (ValueError, IndexError, KeyError, TypeError):
        logging.warning(
            "Could not parse docker network inspect output for %s; "
            "assuming containers present — deferring chain cleanup", name
        )
        return True


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
        r = _run([
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
        ], allow_fail=True)
        if r.returncode != 0:
            # Docker socket may be unavailable (e.g. macOS bind-mount omitted).
            # iptables rules are still applied and reference the bridge name; they
            # will take effect automatically once the network is created externally.
            # There is no security risk: a container cannot join a non-existent
            # network, so the absence of the network implies no containers to protect.
            logging.warning(
                "Could not create Docker network %s — Docker socket unavailable "
                "or creation failed; iptables rules will be applied regardless "
                "and will take effect if the network is created later",
                name,
            )


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

    def deregister(self, name: str) -> None:
        """Remove an ipset from the refresh registry without touching the kernel.

        After this call the refresh loop will no longer re-resolve or update
        the named ipset.  Callers should follow up with ``destroy_by_names``
        to remove the kernel ipset objects as well.
        """
        self._sets.pop(name, None)

    def registered_names(self) -> set:
        """Return the set of ipset names currently registered for periodic refresh."""
        return set(self._sets.keys())


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

    def ensure_forward_policy(self, forward_policy: str) -> bool:
        """Manage the FORWARD chain default policy.

        When ``forward_policy`` is ``'drop'`` (the default), the FORWARD chain
        policy is set to DROP.  If the current policy is already DROP (the
        normal Linux case — Docker sets this before the daemon starts) the call
        is a no-op.  When the current policy is ACCEPT and we are about to
        change it to DROP (the macOS Docker Desktop case, where Docker leaves
        FORWARD as ACCEPT), this method returns True to signal that the caller
        should subsequently insert the ESTABLISHED,RELATED conntrack workaround
        in DOCKER-USER; without that rule, ongoing ``docker exec`` sessions
        would be interrupted by the policy change.

        When ``forward_policy`` is ``'allow-accept'``, an existing ACCEPT
        policy is left unchanged and the method returns False.  The policy is
        never actively set to ACCEPT by this method.

        Args:
            forward_policy: ``'drop'`` or ``'allow-accept'``.

        Returns:
            True if the policy was changed from ACCEPT to DROP (macOS case),
            meaning ``ensure_conntrack_accept`` should be called after
            ``ensure_dispatch_chain``; False otherwise.
        """
        r = _run(["iptables", "-S", "FORWARD"], allow_fail=True)
        currently_accept = (
            r.returncode == 0 and "-P FORWARD ACCEPT" in r.stdout
        )

        if not currently_accept:
            logging.debug("FORWARD policy already DROP; nothing to change")
            return False

        if forward_policy == "allow-accept":
            logging.info(
                "FORWARD policy is ACCEPT and --forward-policy=allow-accept; "
                "leaving unchanged"
            )
            return False

        # Changing ACCEPT → DROP: this is the macOS Docker Desktop case.
        # Log clearly so operators understand why the extra rule is added.
        logging.info(
            "FORWARD policy is ACCEPT — setting to DROP "
            "(macOS Docker Desktop detected); "
            "will insert ESTABLISHED,RELATED workaround in DOCKER-USER"
        )
        _run(["iptables", "-P", "FORWARD", "DROP"])
        logging.debug("FORWARD policy set to DROP")
        return True

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

    def ensure_conntrack_accept(self) -> None:
        """Insert an ESTABLISHED,RELATED ACCEPT rule at the top of DOCKER-USER.

        This is the macOS Docker Desktop workaround applied when the FORWARD
        policy is changed from ACCEPT to DROP.  On macOS, ``docker exec``
        traffic traverses FORWARD and uses connection-tracking states that
        would otherwise be silently discarded by the DROP policy before
        Docker's own FORWARD ESTABLISHED,RELATED rule can accept them.

        The rule is inserted at position 1 of DOCKER-USER, i.e. before the
        ``-j DOCKSIDE-DISPATCH`` jump that ``ensure_dispatch_chain`` added.
        This guarantees that established/related traffic is accepted
        immediately without traversing any of Dockside's dispatch or
        per-network chains.

        The ``-C`` (check) probe makes the insertion idempotent: if the rule
        is already present (e.g. from a previous daemon run) it is not
        duplicated.
        """
        r = _run(
            [
                "iptables", "-C", "DOCKER-USER",
                "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED",
                "-j", "ACCEPT",
            ],
            allow_fail=True,
        )
        if r.returncode == 0:
            logging.debug(
                "DOCKER-USER ESTABLISHED,RELATED rule already present; skipping"
            )
            return
        logging.info(
            "Inserting ESTABLISHED,RELATED ACCEPT at top of DOCKER-USER "
            "(macOS Docker Desktop workaround)"
        )
        _run([
            "iptables", "-I", "DOCKER-USER", "1",
            "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED",
            "-j", "ACCEPT",
        ])

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
        #   The dockside container's own MAC/IP are already excluded by _dispatch_out_match,
        #   so its traffic never reaches the per-network OUT chains; no separate exemption
        #   rules are needed.
        for spec in managed:
            dev = spec.dev
            p   = spec.chain_prefix
            # ING: intra-network traffic — both ingress and egress interface are the same bridge.
            lines.append(
                f"-A DOCKSIDE-DISPATCH -i {dev} -o {dev}"
                f" -m comment --comment \"ingress to devcontainers from dockside container\""
                f" -j {p}-ING"
            )
            # OUT: egress traffic — enters the bridge, exits a different interface.
            #   Dockside's own MAC/IP are excluded by _dispatch_out_match, so its traffic
            #   falls through to the terminal RETURN below without touching the OUT chain.
            out_match = IptablesManager._dispatch_out_match(spec)
            lines.append(
                f"-A DOCKSIDE-DISPATCH {out_match}"
                f" -m comment --comment \"egress from devcontainers\""
                f" -j {p}-OUT"
            )

        # 3b. Terminal RETURN: any packet not matched above (non-managed bridge, or
        #   the dockside container's own traffic excluded by _dispatch_out_match) is
        #   returned to DOCKER-USER, which then returns to FORWARD.
        lines.append(
            "-A DOCKSIDE-DISPATCH"
            " -m comment --comment \"pass-through\""
            " -j RETURN"
        )

        # 4. Per-network ING chains — control NEW intra-network connections.
        #   Purpose: prevent containers from initiating connections to each other
        #   unless the packet originates from the gateway (which is trusted).
        #   ESTABLISHED/RELATED packets are not matched here (no ctstate filter
        #   on the DROP); they are allowed by Docker's FORWARD ACCEPT rule.
        for spec in managed:
            p  = spec.chain_prefix
            gm = spec.dockside_mac
            gi = spec.dockside_ip
            if gm:
                lines.append(
                    f"-A {p}-ING -m mac --mac-source {gm} -p tcp"
                    f" -m conntrack --ctstate NEW"
                    f" -m comment --comment \"Allow ingress from dockside container\""
                    f" -j RETURN"
                )
            if gi:
                lines.append(
                    f"-A {p}-ING -s {gi} -p tcp"
                    f" -m conntrack --ctstate NEW"
                    f" -m comment --comment \"Allow ingress from dockside container\""
                    f" -j RETURN"
                )
            lines.append(
                f"-A {p}-ING -m conntrack --ctstate NEW"
                f" -m comment --comment \"Drop all other ingress to devcontainers\""
                f" -j DROP"
            )

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
          - are *not* from the dockside container (excluded so dockside-container
            traffic hits the dockside exemption rules in step 3b instead)

        Excluding dockside-container traffic from the OUT chain is important: the
        dockside container is a trusted host whose egress should not be subject
        to container egress policy.

        Returns a string of iptables match options (no ``-j`` target) ready to
        be embedded in a ``-A DOCKSIDE-DISPATCH … -j <PREFIX>-OUT`` rule.
        """
        dev   = spec.dev
        gm    = spec.dockside_mac
        gi    = spec.dockside_ip
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
        # into the OUT chain (no dockside exemption needed).
        return " ".join(parts)

    @staticmethod
    def _egress_to_iptables(chain: str, rule: EgressRule) -> List[str]:
        """Translate one EgressRule into zero or more iptables-restore rule lines.

        Drop rules:
          A drop rule emits two lines:
            1. REJECT with ``tcp-reset`` for TCP NEW connections (gives the
               sender an immediate RST so it does not hang waiting for a timeout).
            2. A plain DROP for non-TCP NEW connections only.
          Both rules restrict to NEW connections so that ESTABLISHED/RELATED
          packets for already-permitted flows (e.g. a DNAT-redirected port that
          was allowed by an earlier rule) are not disrupted — they fall through
          the OUT chain and are accepted by Docker's FORWARD ESTABLISHED rule.

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
        # Optional iptables comment fragment, inserted before every -j target.
        cmt = (
            f" -m comment --comment \"{rule.comment.replace(chr(34), chr(39))}\""
            if rule.comment else ""
        )

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
                f"{cmt} -j REJECT --reject-with tcp-reset"
            )
            # Non-TCP: plain DROP for NEW connections only.
            # Restricting to NEW means ESTABLISHED/RELATED packets for already-allowed
            # flows (e.g. a DNAT-redirected MySQL connection) are not disrupted — they
            # fall through the OUT chain and are accepted by Docker's FORWARD ESTABLISHED
            # rule.  This applies to both targeted (dst set) and terminal (dst empty) drops.
            lines.append(f"{prefix} {dst}-m conntrack --ctstate NEW{cmt} -j DROP")
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
                f" -m conntrack --ctstate NEW{cmt} -j RETURN"
            )
        elif rule.proto in ("tcp", "udp") and rule.ports:
            # Use the ``multiport`` extension to match a comma-separated list of
            # destination port numbers in a single rule (more efficient than one
            # rule per port).
            ports_str = ",".join(str(p) for p in rule.ports)
            lines.append(
                f"{prefix} -p {rule.proto} {dst}"
                f"-m multiport --dports {ports_str}"
                f" -m conntrack --ctstate NEW{cmt} -j RETURN"
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

        # Step 1: remove all Dockside-inserted rules from DOCKER-USER.
        _run(
            ["iptables", "-D", "DOCKER-USER", "-j", "DOCKSIDE-DISPATCH"],
            allow_fail=True,
        )
        # Remove the macOS ESTABLISHED,RELATED workaround rule if present.
        _run(
            [
                "iptables", "-D", "DOCKER-USER",
                "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED",
                "-j", "ACCEPT",
            ],
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

    def remove_network_chains(self, spec: NetworkSpec) -> None:
        """Flush and delete all iptables chains belonging to a removed network.

        **Must be called after** ``apply_config()`` has rebuilt
        ``DOCKSIDE-DISPATCH`` without this network's jump entries.  By the
        time this method runs the chains are already unreachable; this is
        purely a kernel-object cleanup step.

        Deletion order in the nat table:
          1. Remove the ``PREROUTING → <PREFIX>-NAT`` jump rule first.
             iptables refuses to delete a chain that is still a jump target.
          2. Flush the NAT chain.
          3. Delete the NAT chain.

        All steps use ``allow_fail=True`` so that absent chains (e.g. when
        the network had no NAT rules and the NAT chain was never created) are
        silently skipped.
        """
        p = spec.chain_prefix
        # Filter table: flush then delete ingress and egress chains.
        for chain in (f"{p}-ING", f"{p}-OUT"):
            _run(["iptables", "-F", chain], allow_fail=True)
            _run(["iptables", "-X", chain], allow_fail=True)
        # Nat table: remove the PREROUTING jump before flushing/deleting the
        # chain (iptables rejects deleting a chain still referenced by a rule).
        nat_chain = f"{p}-NAT"
        _run(
            ["iptables", "-t", "nat", "-D", "PREROUTING", "-j", nat_chain],
            allow_fail=True,
        )
        _run(["iptables", "-t", "nat", "-F", nat_chain], allow_fail=True)
        _run(["iptables", "-t", "nat", "-X", nat_chain], allow_fail=True)
        logging.info("Removed iptables chains for network %s", spec.name)

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

    Authorization:
      Peer credentials are read via ``SO_PEERCRED`` for every connection.
      Mutating actions (those that alter iptables/ipset state or persisted
      config) require the connecting process to run as root (UID 0).
      Read-only actions (``status``, ``refresh``) are permitted for any
      process in the socket's group.  All requests are logged with their peer
      PID/UID/GID for audit purposes.
    """

    # Actions that alter iptables/ipset kernel state or the persisted config
    # files; these require the connecting peer to be root (UID 0).
    _MUTATING_ACTIONS = frozenset({
        "reload", "apply", "set-network", "remove-network",
        "set-ipset", "remove-ipset", "reconcile",
    })

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

        Peer credentials are read via ``SO_PEERCRED`` before the request is
        dispatched.  Mutating actions require the peer to be root (UID 0).
        All requests are logged with peer PID/UID/GID for audit purposes.

        The ``finally`` block ensures the connection is always closed, even on
        unexpected exceptions, so file descriptors are not leaked.
        """
        try:
            # ── Read peer credentials (Linux SO_PEERCRED) ─────────────────────
            # struct ucred { pid_t pid; uid_t uid; gid_t gid; } — all 32-bit.
            try:
                raw = conn.getsockopt(
                    socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("iII")
                )
                peer_pid, peer_uid, peer_gid = struct.unpack("iII", raw)
            except OSError:
                # SO_PEERCRED unavailable (non-Linux or unusual socket type).
                # Treat as unknown peer; will be blocked for mutating actions.
                peer_pid = peer_uid = peer_gid = -1

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
                req    = json.loads(buf.decode())
                action = req.get("action", "")

                # ── Audit log ─────────────────────────────────────────────────
                logging.info(
                    "mgmt-socket: pid=%s uid=%s gid=%s action=%r",
                    peer_pid, peer_uid, peer_gid, action,
                )

                # ── Authorization ─────────────────────────────────────────────
                # Mutating actions may only be invoked by root (UID 0).
                # Read-only actions (status, refresh) are open to any peer
                # that can connect (already constrained by socket 0o660 perms).
                if action in self._MUTATING_ACTIONS and peer_uid != 0:
                    resp = {
                        "status": "error",
                        "message": (
                            f"permission denied: action {action!r} requires "
                            f"root (uid 0); peer uid={peer_uid}"
                        ),
                    }
                else:
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
        forward_policy: str = "drop",
    ):
        # Paths to the two JSON config files; reloaded on SIGUSR1 or "reload" action.
        self._net_path      = network_config_path
        self._fw_path       = firewall_config_path
        # Optional path for the management Unix socket; None = no socket.
        self._sock_path     = socket_path
        # FORWARD chain policy: 'drop' or 'allow-accept'.
        self._forward_policy = forward_policy
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
          3. FORWARD default policy (see ensure_forward_policy).
          4. DOCKSIDE-DISPATCH chain and DOCKER-USER jump.
          4a. macOS conntrack workaround (only when FORWARD was changed from
              ACCEPT to DROP — see ensure_conntrack_accept).
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
        changed_to_drop = self._ipt_mgr.ensure_forward_policy(self._forward_policy)
        self._ipt_mgr.ensure_dispatch_chain()
        if changed_to_drop:
            # FORWARD was ACCEPT and we just set it to DROP (macOS Docker Desktop).
            # Insert the conntrack workaround AFTER ensure_dispatch_chain so that
            # the ESTABLISHED,RELATED rule sits at position 1 of DOCKER-USER,
            # ahead of the -j DOCKSIDE-DISPATCH jump inserted by ensure_dispatch_chain.
            self._ipt_mgr.ensure_conntrack_accept()
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

    def _cleanup_phase(
        self,
        old_config: Optional[Config],
        new_config: Config,
    ) -> None:
        """Phase 2 of two-phase apply: remove kernel objects dropped from config.

        Must be called **after** ``apply_config()`` has atomically rebuilt
        ``DOCKSIDE-DISPATCH`` for *new_config* (so removed networks' chains are
        already unreachable before they are deleted).

        Container safety
        ----------------
        Before deleting a removed network's chains, ``_network_has_containers``
        is called.  If the network still has running containers the chain
        deletion is deferred and a warning is logged.  The firewall policy is
        already correct — ``DOCKSIDE-DISPATCH`` no longer dispatches to those
        chains — so deferring the cleanup is safe.  The orphaned chains will be
        removed on the next reload/apply/remove-network once the containers
        have gone.

        Ipset safety
        ------------
        An ipset is only destroyed when it is safe to do so:
          - Not still defined in *new_config*.
          - Not referenced by any egress rule in *new_config*.
          - Not referenced by any deferred network's egress rules (i.e. a
            network whose chains were kept because containers are connected).

        Caller must hold ``self._lock``.
        """
        if old_config is None:
            return

        removed_nets, removed_ipsets = _diff_configs(old_config, new_config)
        if not removed_nets and not removed_ipsets:
            return

        # Build a name→spec map from old_config for removed networks.
        old_specs = {s.name: s for s in old_config.networks}

        # --- Network chain cleanup ---
        kept_nets: set = set()   # networks whose cleanup was deferred
        for net_name in removed_nets:
            spec = old_specs[net_name]
            if _network_has_containers(net_name):
                logging.warning(
                    "Network %s still has active containers; "
                    "deferring chain cleanup until containers disconnect",
                    net_name,
                )
                kept_nets.add(net_name)
            else:
                self._ipt_mgr.remove_network_chains(spec)

        # --- Ipset cleanup ---
        # An ipset must NOT be destroyed when it is:
        #   (a) still defined in new_config.ipsets, OR
        #   (b) referenced by a remaining network's egress rules, OR
        #   (c) referenced by a deferred network's egress rules
        #       (its chains are still in the kernel; destruction would leave
        #        iptables rules pointing at a non-existent ipset).
        new_ipset_defs = set(new_config.ipsets.keys())
        new_ipset_refs = new_config.ipset_referenced_names()

        kept_refs: set = set()
        for net_name in kept_nets:
            for rule in old_specs[net_name].egress_rules:
                if rule.to == "ipset" and rule.ipset:
                    kept_refs.add(rule.ipset)

        safe_to_destroy = removed_ipsets - new_ipset_defs - new_ipset_refs - kept_refs
        for ipset_name in safe_to_destroy:
            self._ipset_mgr.deregister(ipset_name)
            self._ipset_mgr.destroy_by_names([ipset_name])
            logging.info("Destroyed removed ipset %s", ipset_name)

        deferred_ipsets = removed_ipsets - safe_to_destroy
        if deferred_ipsets:
            logging.info(
                "Ipset cleanup deferred (still referenced or containers active): %s",
                ", ".join(sorted(deferred_ipsets)),
            )

    def _two_phase_apply(
        self,
        new_config: Config,
        old_config: Optional[Config],
    ) -> None:
        """Apply *new_config* in two ordered phases.

        **Phase 1 — addition/update (atomic):**
          - Ensure Docker networks exist (``ensure_networks``).
          - Ensure ipsets are created and populated (``ensure_ipset``).
          - Atomically rebuild all Dockside iptables chains via a single
            ``iptables-restore --noflush`` call (``apply_config``).

        **Phase 2 — cleanup (diff-driven):**
          - Compute what was removed: ``old_config − new_config``.
          - Flush and delete orphaned chains for removed networks (deferred
            when containers are still connected).
          - Deregister and destroy removed ipsets (deferred when still
            referenced by active chains or the new config).

        **Ordering invariant (safety-critical):** ``apply_config()`` MUST
        complete before ``_cleanup_phase()`` deletes anything.  After
        ``apply_config()``, ``DOCKSIDE-DISPATCH`` no longer references removed
        networks (so their chains are safe to delete) and no active iptables
        rules reference removed ipsets (so they are safe to destroy).

        Caller must hold ``self._lock``.
        """
        # Phase 1: ensure everything required by new_config exists.
        self._docker_mgr.ensure_networks(new_config.networks)
        for name, hostnames in new_config.ipsets.items():
            self._ipset_mgr.ensure_ipset(name, hostnames)
        self._ipset_mgr.refresh_all()
        self._ipt_mgr.apply_config(new_config)   # atomic iptables-restore

        # Phase 2: clean up objects removed from old_config.
        self._cleanup_phase(old_config, new_config)

        # Update in-memory config last, after both phases succeed.
        self._config = new_config

    def _save_config(self, config: Config) -> None:
        """Atomically write *config* back to both on-disk JSON config files.

        Each file is written to a temporary sibling (same directory = same
        filesystem) and then renamed into place via ``os.replace()``, which
        maps to ``rename(2)`` on Linux — an atomic operation that ensures
        readers always see either the old or the new file, never a partial
        write.

        Caller must hold ``self._lock`` to prevent two concurrent socket
        actions from racing on the disk write.

        Raises:
            OSError / IOError: if the temp file cannot be written or renamed.
        """
        for path, data in (
            (self._net_path, config.to_net_data()),
            (self._fw_path,  config.to_fw_data()),
        ):
            dir_path = os.path.dirname(os.path.abspath(path))
            fd, tmp_path = tempfile.mkstemp(
                dir=dir_path, prefix=".tmp-firewall-", suffix=".json"
            )
            try:
                with os.fdopen(fd, "w") as f:
                    json.dump(data, f, indent=2)
                    f.write("\n")
                os.replace(tmp_path, path)   # atomic rename(2)
            except Exception:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
                raise
        logging.debug(
            "Config saved atomically: %s and %s", self._net_path, self._fw_path
        )

    def _reconcile(self) -> dict:
        """Compare in-memory config against host state; remove orphaned objects.

        Performs three checks, all under ``_lock``:

        1. **Orphaned iptables chains**: enumerates all ``DOCKSIDE-*`` chains
           in the kernel via ``_list_dockside_chains``; flushes and deletes any
           whose name prefix is not expected from ``self._config``.

        2. **Orphaned ipsets**: destroys any ipsets registered in
           ``IpsetManager._sets`` that are no longer defined in
           ``self._config.ipsets``.

        3. **Docker network orphans**: lists Docker networks and reports (but
           never deletes) any whose names look Dockside-owned but are absent
           from ``self._config``.  Docker network deletion requires stopping
           all connected containers first, which is the operator's
           responsibility.

        Returns a dict suitable for returning directly as a socket response.
        """
        with self._lock:
            cfg = self._config
            if cfg is None:
                return {"status": "error", "message": "daemon not yet initialized"}

            removed_chains:      List[str] = []
            removed_ipsets_list: List[str] = []
            docker_orphans:      List[str] = []

            # 1. Orphaned iptables chains.
            expected_prefixes: set = set()
            for s in cfg.networks:
                if s.managed:
                    expected_prefixes.add(s.chain_prefix)
            # DOCKSIDE-DISPATCH chain begins with DOCKSIDE_PREFIX.
            expected_prefixes.add(DOCKSIDE_PREFIX)

            for table in ("filter", "nat"):
                flags = ["-t", table] if table != "filter" else []
                for chain in self._ipt_mgr._list_dockside_chains(table):
                    if not any(chain.startswith(p) for p in expected_prefixes):
                        _run(["iptables"] + flags + ["-F", chain], allow_fail=True)
                        _run(["iptables"] + flags + ["-X", chain], allow_fail=True)
                        removed_chains.append(chain)
                        logging.info(
                            "Reconcile: removed orphaned chain %s (%s table)",
                            chain, table,
                        )

            # 2. Orphaned ipsets: registered in IpsetManager but absent from config.
            config_ipset_names = set(cfg.ipsets.keys())
            for name in list(self._ipset_mgr.registered_names() - config_ipset_names):
                self._ipset_mgr.deregister(name)
                self._ipset_mgr.destroy_by_names([name])
                removed_ipsets_list.append(name)
                logging.info("Reconcile: destroyed orphaned ipset %s", name)

            # 3. Docker network orphans (informational only; never deleted).
            r = _run(
                ["docker", "network", "ls", "--format", "{{.Name}}"],
                allow_fail=True,
            )
            if r.returncode == 0:
                config_nets = cfg.network_names()
                for net_name in r.stdout.split():
                    if net_name not in config_nets and net_name.lower().startswith("ds-"):
                        docker_orphans.append(net_name)
                if docker_orphans:
                    logging.warning(
                        "Reconcile: Docker networks not in config "
                        "(not removed — operator action required): %s",
                        ", ".join(docker_orphans),
                    )

        return {
            "status":         "ok",
            "removed_chains": removed_chains,
            "removed_ipsets": removed_ipsets_list,
            "docker_orphans": docker_orphans,
        }

    def _reload(self) -> None:
        """Load config from disk and atomically apply it while holding _lock.

        Uses ``_two_phase_apply`` so that networks and ipsets removed from the
        config files since the last reload are cleaned up from the kernel.
        On any error the existing config remains active (the atomic
        ``iptables-restore --noflush`` in Phase 1 ensures no partial state).
        """
        try:
            new_config = Config.from_files(self._net_path, self._fw_path)
            with self._lock:
                self._two_phase_apply(new_config, self._config)
            logging.info("Config reload complete")
        except Exception:
            logging.exception("Config reload failed")

    def _handle_request(self, req: dict) -> dict:
        """Dispatch a management socket request to the appropriate handler.

        Supported actions:
          ``reload``          — reload config from disk (same as SIGUSR1);
                                cleans up objects removed since last apply.
          ``apply``           — apply an inline config supplied in the request
                                body (``network_config`` + ``firewall_config``
                                keys); saves to disk; cleans up removed objects.
          ``refresh``         — re-resolve all ipsets immediately without
                                reloading the rest of the config.
          ``status``          — return current daemon state (networks + IPs).
          ``set-network``     — upsert one network (topology + firewall rules);
                                saves to disk.
          ``remove-network``  — remove one network from config; saves to disk.
          ``set-ipset``       — upsert one ipset definition; saves to disk.
          ``remove-ipset``    — remove one ipset; saves to disk.
          ``reconcile``       — compare in-memory config against host state and
                                clean up orphaned iptables chains and ipsets.

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
                # Apply an inline config; two-phase apply cleans up removals.
                net_data = req.get("network_config", {})
                fw_data  = req.get("firewall_config", {})
                new_cfg  = Config.from_dicts(net_data, fw_data)
                with self._lock:
                    self._two_phase_apply(new_cfg, self._config)
                    self._save_config(new_cfg)
                return {"status": "ok"}

            elif action == "refresh":
                # Re-resolve ipsets immediately; does not reload other config.
                with self._lock:
                    self._ipset_mgr.refresh_all()
                return {"status": "ok"}

            elif action == "status":
                return self._get_status()

            elif action == "set-network":
                return self._handle_set_network(req)

            elif action == "remove-network":
                return self._handle_remove_network(req)

            elif action == "set-ipset":
                return self._handle_set_ipset(req)

            elif action == "remove-ipset":
                return self._handle_remove_ipset(req)

            elif action == "reconcile":
                return self._reconcile()

            else:
                return {"status": "error", "message": f"unknown action: {action!r}"}
        except Exception as exc:
            return {"status": "error", "message": str(exc)}

    def _handle_set_network(self, req: dict) -> dict:
        """Upsert one network entry (topology + optional firewall rules).

        Request keys:
          ``name``     (str, required)  — network name.
          ``network``  (dict, optional) — topology fields to set or update:
                                          ``subnet``, ``gateway_ip``,
                                          ``dockside_ip``, ``dockside_mac``.
                                          Missing fields preserve existing values.
          ``firewall`` (dict, optional) — firewall rules for this network:
                                          ``egress`` list, ``nat`` list.
                                          Omitting this key removes any
                                          existing rules for the network.

        A subnet change on an existing network is rejected because it requires
        Docker network recreation (which disconnects containers).  The operator
        should update the file and use ``reload`` with ``RESET=1`` instead.
        """
        name = req.get("name")
        if not name:
            return {"status": "error", "message": "missing 'name'"}
        net_obj = req.get("network") or {}
        fw_obj  = req.get("firewall")   # None means "no rules"

        with self._lock:
            old_cfg = self._config or Config([], {})

            # Build the new raw network-spec dict by merging provided fields
            # onto the existing NetworkSpec (if any) so callers can do partial
            # updates (e.g. change dockside_ip without re-specifying subnet).
            existing_spec: dict = {}
            for s in old_cfg.networks:
                if s.name == name:
                    existing_spec = s.to_net_dict()
                    break

            # Reject subnet changes on existing networks.
            if (
                existing_spec
                and net_obj.get("subnet")
                and existing_spec.get("subnet") != net_obj["subnet"]
            ):
                return {
                    "status": "error",
                    "message": (
                        f"subnet change for existing network {name!r} is not "
                        "supported via set-network (would disconnect containers);"
                        " update network-config.json and reload with RESET=1"
                    ),
                }

            # Overlay provided fields onto existing values.
            new_net_spec: dict = dict(existing_spec)
            new_net_spec["name"] = name
            for key in ("subnet", "gateway_ip", "dockside_ip", "dockside_mac"):
                val = net_obj.get(key)
                if val is not None:
                    new_net_spec[key] = val

            if "subnet" not in new_net_spec:
                return {
                    "status": "error",
                    "message": f"'subnet' is required for new network {name!r}",
                }

            # Build the updated network list (replace existing or append).
            new_net_specs = []
            replaced = False
            for s in old_cfg.networks:
                if s.name == name:
                    new_net_specs.append(new_net_spec)
                    replaced = True
                else:
                    new_net_specs.append(s.to_net_dict())
            if not replaced:
                new_net_specs.append(new_net_spec)

            # Build the updated firewall networks map.
            new_fw_nets: dict = {}
            for s in old_cfg.networks:
                if s.name == name:
                    continue    # will be replaced below
                fw = s.to_fw_dict()
                if fw is not None:
                    new_fw_nets[s.name] = fw
            if fw_obj:
                new_fw_nets[name] = fw_obj

            net_data = {"networks": new_net_specs}
            fw_data  = {"ipsets": dict(old_cfg.ipsets), "networks": new_fw_nets}
            new_cfg  = Config.from_dicts(net_data, fw_data)
            self._two_phase_apply(new_cfg, old_cfg)
            self._save_config(new_cfg)

        return {"status": "ok", "networks": [s.name for s in new_cfg.networks]}

    def _handle_remove_network(self, req: dict) -> dict:
        """Remove one network from config and apply cleanup.

        Request keys:
          ``name`` (str, required) — network name to remove.

        Container safety is handled by ``_cleanup_phase``: if the network
        still has containers connected, the iptables chain deletion is deferred
        and a warning is logged.  The firewall is immediately correct (the
        network is removed from ``DOCKSIDE-DISPATCH`` by the Phase 1
        ``iptables-restore`` call) regardless of deferral.
        """
        name = req.get("name")
        if not name:
            return {"status": "error", "message": "missing 'name'"}

        with self._lock:
            old_cfg = self._config
            if old_cfg is None:
                return {"status": "error", "message": "daemon not yet initialized"}
            if name not in old_cfg.network_names():
                return {
                    "status": "error",
                    "message": f"network {name!r} not in config",
                }

            # Build new config with this network removed.
            new_net_specs = [
                s.to_net_dict() for s in old_cfg.networks if s.name != name
            ]
            new_fw_nets: dict = {}
            for s in old_cfg.networks:
                if s.name == name:
                    continue
                fw = s.to_fw_dict()
                if fw is not None:
                    new_fw_nets[s.name] = fw

            net_data = {"networks": new_net_specs}
            fw_data  = {"ipsets": dict(old_cfg.ipsets), "networks": new_fw_nets}
            new_cfg  = Config.from_dicts(net_data, fw_data)
            self._two_phase_apply(new_cfg, old_cfg)
            self._save_config(new_cfg)

        return {"status": "ok"}

    def _handle_set_ipset(self, req: dict) -> dict:
        """Upsert one ipset definition.

        Request keys:
          ``name``      (str, required)  — ipset name.
          ``hostnames`` (list, required) — list of hostnames/IPs to populate
                                           the ipset with.
        """
        ipset_name = req.get("name")
        hostnames  = req.get("hostnames", [])
        if not ipset_name:
            return {"status": "error", "message": "missing 'name'"}
        if not isinstance(hostnames, list):
            return {"status": "error", "message": "'hostnames' must be a list"}

        with self._lock:
            old_cfg = self._config or Config([], {})
            new_ipsets = dict(old_cfg.ipsets)
            new_ipsets[ipset_name] = hostnames
            net_data = old_cfg.to_net_data()
            fw_data  = old_cfg.to_fw_data()
            fw_data["ipsets"] = new_ipsets
            new_cfg  = Config.from_dicts(net_data, fw_data)
            self._two_phase_apply(new_cfg, old_cfg)
            self._save_config(new_cfg)

        return {"status": "ok"}

    def _handle_remove_ipset(self, req: dict) -> dict:
        """Remove one ipset definition and destroy its kernel objects.

        Request keys:
          ``name`` (str, required) — ipset name to remove.

        Pre-flight guard: the request is rejected if any remaining network's
        egress rules still reference this ipset by name.  Removing a
        referenced ipset would leave dangling ``-m set --match-set`` rules
        in the kernel that silently fail to match.  The operator must first
        update or remove the referencing network's firewall rules.
        """
        ipset_name = req.get("name")
        if not ipset_name:
            return {"status": "error", "message": "missing 'name'"}

        with self._lock:
            old_cfg = self._config
            if old_cfg is None:
                return {"status": "error", "message": "daemon not yet initialized"}
            if ipset_name not in old_cfg.ipsets:
                return {
                    "status": "error",
                    "message": f"ipset {ipset_name!r} not in config",
                }
            # Guard: refuse removal if still referenced by egress rules.
            referencing = [
                s.name for s in old_cfg.networks
                if any(r.ipset == ipset_name for r in s.egress_rules)
            ]
            if referencing:
                return {
                    "status": "error",
                    "message": (
                        f"ipset {ipset_name!r} is still referenced by: "
                        + ", ".join(referencing)
                        + "; remove or update those network rules first"
                    ),
                }

            new_ipsets = {k: v for k, v in old_cfg.ipsets.items() if k != ipset_name}
            net_data = old_cfg.to_net_data()
            fw_data  = old_cfg.to_fw_data()
            fw_data["ipsets"] = new_ipsets
            new_cfg  = Config.from_dicts(net_data, fw_data)
            self._two_phase_apply(new_cfg, old_cfg)
            self._save_config(new_cfg)

        return {"status": "ok"}

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
    ap.add_argument(
        "--forward-policy",
        choices=["drop", "allow-accept"],
        default="drop",
        dest="forward_policy",
        help=(
            "FORWARD chain policy. "
            "'drop' (default): set FORWARD to DROP, inserting an "
            "ESTABLISHED,RELATED workaround in DOCKER-USER when the policy "
            "was previously ACCEPT (macOS Docker Desktop). "
            "'allow-accept': leave an existing ACCEPT policy unchanged "
            "(FAOD: never actively sets the policy to ACCEPT)."
        ),
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
        forward_policy=args.forward_policy,
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
