#!/usr/bin/env python3
"""
Tier 1 unit tests for dockside-network-firewall.py: pure-logic coverage that
needs no root, no iptables/ipset/docker binaries, and no network access.

Covers config loading/validation, iptables-restore text generation, config
diffing, and the ipset refresh/TTL algorithm (with _run()/DNS resolution
mocked out) — see docs/adr/0006-dockside-network-firewall-security-hardening.md
for why the validators and socket auth exist. Tiers 2/3 (real iptables/ipset/
docker, real daemon subprocess, real socket auth) are tracked separately in
docs/plans/follow-on-work.md; they need a privileged/netns environment this
tier deliberately avoids.
"""

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

_MODULE_PATH = Path(__file__).resolve().parent.parent / "dockside-network-firewall.py"
_spec = importlib.util.spec_from_file_location("dockside_network_firewall", _MODULE_PATH)
fw = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = fw
_spec.loader.exec_module(fw)


class ValidatorTests(unittest.TestCase):
    """_val_* functions are the config-injection fix (ADR-0006, finding 1)."""

    def test_identifier_accepts_safe_charset(self):
        fw._val_identifier("ds-prod_01.example:2", "field")  # must not raise

    def test_identifier_rejects_injection_attempt(self):
        with self.assertRaises(ValueError):
            fw._val_identifier("prod; iptables -F", "field")

    def test_identifier_rejects_too_long(self):
        with self.assertRaises(ValueError):
            fw._val_identifier("a" * 65, "field", max_len=64)

    def test_iface_rejects_over_ifnamsiz(self):
        with self.assertRaises(ValueError):
            fw._val_iface("a" * 16, "field")  # IFNAMSIZ-1 == 15

    def test_ip_accepts_valid_ipv4(self):
        fw._val_ip("172.20.0.2", "field")

    def test_ip_rejects_garbage(self):
        with self.assertRaises(ValueError):
            fw._val_ip("172.20.0.2; rm -rf /", "field")

    def test_cidr_accepts_valid(self):
        fw._val_cidr("10.0.0.0/8", "field")

    def test_cidr_rejects_invalid(self):
        with self.assertRaises(ValueError):
            fw._val_cidr("not-a-cidr", "field")

    def test_mac_accepts_valid(self):
        fw._val_mac("02:00:00:00:00:02", "field")

    def test_mac_rejects_invalid(self):
        with self.assertRaises(ValueError):
            fw._val_mac("02:00:00:00:00:zz", "field")

    def test_proto_rejects_unsupported(self):
        with self.assertRaises(ValueError):
            fw._val_proto("sctp", "field")

    def test_port_rejects_out_of_range(self):
        with self.assertRaises(ValueError):
            fw._val_port(70000, "field")

    def test_port_rejects_bool(self):
        # bool is a subclass of int in Python; must not silently pass as a port.
        with self.assertRaises(ValueError):
            fw._val_port(True, "field")

    def test_comment_rejects_newline_injection(self):
        with self.assertRaises(ValueError):
            fw._val_comment("ok\n-F FORWARD", "field")

    def test_comment_rejects_too_long(self):
        with self.assertRaises(ValueError):
            fw._val_comment("a" * 201, "field", max_len=200)

    def test_host_entry_rejects_shell_metacharacters(self):
        with self.assertRaises(ValueError):
            fw._val_host_entry("github.com; touch /tmp/pwned", "field")

    def test_host_entry_accepts_plain_hostname(self):
        fw._val_host_entry("github.com", "field")


class ConfigParsingTests(unittest.TestCase):
    """Config.from_dicts(): network/egress/nat parsing and cross-referencing."""

    def test_minimal_config_parses(self):
        net = {"networks": [{"name": "dockside", "subnet": "172.30.0.0/24"}]}
        fw_data = {"networks": {"dockside": {"egress": [
            {"proto": "tcp", "ports": [443], "to": "all"},
            {"action": "drop"},
        ]}}}
        cfg = fw.Config.from_dicts(net, fw_data)
        self.assertEqual(cfg.network_names(), {"dockside"})
        spec = cfg.networks[0]
        self.assertEqual(len(spec.egress_rules), 2)
        self.assertTrue(spec.managed)  # has egress rules -> managed

    def test_network_with_no_rules_and_no_dockside_ip_mac_is_unmanaged(self):
        net = {"networks": [{"name": "plain", "subnet": "172.30.2.0/24"}]}
        cfg = fw.Config.from_dicts(net, {})
        self.assertFalse(cfg.networks[0].managed)

    def test_dockside_mac_alone_makes_network_managed(self):
        net = {"networks": [{
            "name": "ai-dev-sandbox", "subnet": "172.31.1.0/24",
            "dockside_mac": "02:00:00:00:00:02",
        }]}
        cfg = fw.Config.from_dicts(net, {})
        self.assertTrue(cfg.networks[0].managed)

    def test_firewall_config_referencing_unknown_network_raises(self):
        net = {"networks": [{"name": "dockside", "subnet": "172.30.0.0/24"}]}
        fw_data = {"networks": {"ds-typo": {"egress": []}}}
        with self.assertRaises(ValueError):
            fw.Config.from_dicts(net, fw_data)

    def test_ipset_referenced_names_tracks_egress_ipset_rules(self):
        net = {"networks": [{"name": "n", "subnet": "172.30.3.0/24"}]}
        fw_data = {
            "ipsets": {"allow": ["github.com"]},
            "networks": {"n": {"egress": [
                {"proto": "tcp", "ports": [443], "to": "ipset", "ipset": "allow"},
            ]}},
        }
        cfg = fw.Config.from_dicts(net, fw_data)
        self.assertEqual(cfg.ipset_referenced_names(), {"allow"})

    def test_ipset_entry_with_injection_attempt_raises(self):
        net = {"networks": [{"name": "n", "subnet": "172.30.4.0/24"}]}
        fw_data = {"ipsets": {"allow": ["github.com; rm -rf /"]}, "networks": {}}
        with self.assertRaises(ValueError):
            fw.Config.from_dicts(net, fw_data)

    def test_nat_rule_parses(self):
        net = {"networks": [{"name": "ds-clone", "subnet": "172.30.5.0/24"}]}
        fw_data = {"networks": {"ds-clone": {"nat": [
            {"proto": "tcp", "match_dport": 13306, "to_host": "db.internal", "to_port": 3306},
        ]}}}
        cfg = fw.Config.from_dicts(net, fw_data)
        nat = cfg.networks[0].nat_rules[0]
        self.assertEqual(nat.to_host, "db.internal")
        self.assertEqual(nat.to_port, 3306)

    def test_round_trip_to_net_data_and_to_fw_data(self):
        net = {"networks": [{
            "name": "ds-prod", "subnet": "172.20.3.0/24",
            "dockside_ip": "172.20.3.2", "dockside_mac": "02:00:00:00:00:02",
        }]}
        fw_data = {"networks": {"ds-prod": {"egress": [
            {"proto": "tcp", "ports": [443], "to": "all"},
        ]}}}
        cfg = fw.Config.from_dicts(net, fw_data)
        self.assertEqual(cfg.to_net_data(), net)
        self.assertEqual(cfg.to_fw_data(), {"networks": fw_data["networks"]})


class DiffConfigsTests(unittest.TestCase):
    """_diff_configs(): pure set-difference driving the cleanup phase."""

    def _cfg(self, net_names, ipset_names=()):
        net = {"networks": [{"name": n, "subnet": "172.30.0.0/24"} for n in net_names]}
        fw_data = {"ipsets": {i: ["github.com"] for i in ipset_names}}
        return fw.Config.from_dicts(net, fw_data)

    def test_no_previous_config_yields_no_removals(self):
        removed_nets, removed_ipsets = fw._diff_configs(None, self._cfg(["a"]))
        self.assertEqual(removed_nets, set())
        self.assertEqual(removed_ipsets, set())

    def test_removed_network_and_ipset_detected(self):
        old = self._cfg(["a", "b"], ["allow"])
        new = self._cfg(["a"], [])
        removed_nets, removed_ipsets = fw._diff_configs(old, new)
        self.assertEqual(removed_nets, {"b"})
        self.assertEqual(removed_ipsets, {"allow"})

    def test_unchanged_config_yields_no_removals(self):
        old = self._cfg(["a"], ["allow"])
        new = self._cfg(["a"], ["allow"])
        removed_nets, removed_ipsets = fw._diff_configs(old, new)
        self.assertEqual(removed_nets, set())
        self.assertEqual(removed_ipsets, set())


class IptablesRuleGenTests(unittest.TestCase):
    """Pure iptables-restore text builders — no subprocess, no kernel calls."""

    def test_egress_allow_all_ports(self):
        rule = fw.EgressRule({"proto": "tcp", "ports": [80, 443], "to": "all"})
        lines = fw.IptablesManager._egress_to_iptables("DOCKSIDE-N-OUT", rule)
        self.assertEqual(len(lines), 1)
        self.assertIn("-A DOCKSIDE-N-OUT -p tcp ", lines[0])
        self.assertIn("--dports 80,443", lines[0])
        self.assertIn("-j RETURN", lines[0])
        self.assertNotIn("-d ", lines[0])  # "all" -> no destination filter

    def test_egress_allow_cidr(self):
        rule = fw.EgressRule({"proto": "tcp", "ports": [3306], "to": "cidr", "cidr": "192.168.0.0/16"})
        lines = fw.IptablesManager._egress_to_iptables("DOCKSIDE-N-OUT", rule)
        self.assertIn("-d 192.168.0.0/16 ", lines[0])

    def test_egress_allow_ipset(self):
        rule = fw.EgressRule({"proto": "tcp", "ports": [443], "to": "ipset", "ipset": "allow"})
        lines = fw.IptablesManager._egress_to_iptables("DOCKSIDE-N-OUT", rule)
        self.assertIn("-m set --match-set allow dst", lines[0])

    def test_egress_allow_icmp(self):
        rule = fw.EgressRule({"proto": "icmp"})
        lines = fw.IptablesManager._egress_to_iptables("DOCKSIDE-N-OUT", rule)
        self.assertIn("--icmp-type echo-request", lines[0])

    def test_egress_drop_emits_reject_then_drop(self):
        rule = fw.EgressRule({"action": "drop"})
        lines = fw.IptablesManager._egress_to_iptables("DOCKSIDE-N-OUT", rule)
        self.assertEqual(len(lines), 2)
        self.assertIn("-j REJECT --reject-with tcp-reset", lines[0])
        self.assertIn("-p tcp -m conntrack --ctstate NEW", lines[0])
        self.assertIn("-j DROP", lines[1])
        self.assertNotIn("-p tcp", lines[1])  # second line covers non-TCP too

    def test_egress_drop_with_cidr_scopes_both_lines(self):
        rule = fw.EgressRule({"action": "drop", "cidr": "10.0.0.0/8"})
        lines = fw.IptablesManager._egress_to_iptables("DOCKSIDE-N-OUT", rule)
        self.assertIn("-d 10.0.0.0/8 ", lines[0])
        self.assertIn("-d 10.0.0.0/8 ", lines[1])

    def test_egress_comment_quotes_are_neutralised(self):
        # Comment text reaches iptables-restore inside a double-quoted string;
        # an embedded double quote must not be able to break out of it.
        rule = fw.EgressRule({"proto": "tcp", "ports": [80], "to": "all",
                               "comment": 'test "quote" here'})
        lines = fw.IptablesManager._egress_to_iptables("DOCKSIDE-N-OUT", rule)
        self.assertIn("--comment \"test 'quote' here\"", lines[0])

    def test_egress_host_rule_skipped_on_unresolvable_host(self):
        rule = fw.EgressRule({"proto": "tcp", "ports": [443], "to": "host", "host": "nonexistent.invalid"})
        with mock.patch.object(fw, "_resolve_hostname", return_value=None):
            lines = fw.IptablesManager._egress_to_iptables("DOCKSIDE-N-OUT", rule)
        self.assertEqual(lines, [])

    def test_dispatch_out_match_no_exemption_when_unset(self):
        spec = fw.NetworkSpec({"name": "n", "subnet": "172.30.0.0/24"})
        match = fw.IptablesManager._dispatch_out_match(spec)
        self.assertEqual(match, "-i n ! -o n")

    def test_dispatch_out_match_mac_only(self):
        spec = fw.NetworkSpec({"name": "n", "subnet": "172.30.0.0/24",
                                "dockside_mac": "02:00:00:00:00:02"})
        match = fw.IptablesManager._dispatch_out_match(spec)
        self.assertIn("-m mac ! --mac-source 02:00:00:00:00:02", match)
        self.assertNotIn("-s ", match)

    def test_dispatch_out_match_mac_and_ip(self):
        spec = fw.NetworkSpec({"name": "n", "subnet": "172.30.0.0/24",
                                "dockside_ip": "172.30.0.2",
                                "dockside_mac": "02:00:00:00:00:02"})
        match = fw.IptablesManager._dispatch_out_match(spec)
        self.assertIn("-m mac ! --mac-source 02:00:00:00:00:02", match)
        self.assertIn("! -s 172.30.0.2", match)

    def test_build_restore_input_declares_and_flushes_dispatch_and_per_network_chains(self):
        net = {"networks": [{"name": "dockside", "subnet": "172.30.0.0/24"}]}
        fw_data = {"networks": {"dockside": {"egress": [
            {"proto": "tcp", "ports": [443], "to": "all"},
        ]}}}
        cfg = fw.Config.from_dicts(net, fw_data)
        managed = [s for s in cfg.networks if s.managed]
        lines = fw.IptablesManager._build_restore_input(managed, [])
        text = "\n".join(lines)
        self.assertEqual(lines[0], "*filter")
        self.assertIn(":DOCKSIDE-DISPATCH - [0:0]", lines)
        self.assertIn(":DOCKSIDE-DOCKSIDE-ING - [0:0]", lines)
        self.assertIn(":DOCKSIDE-DOCKSIDE-OUT - [0:0]", lines)
        self.assertIn("-F DOCKSIDE-DISPATCH", lines)
        self.assertIn("COMMIT", lines)
        self.assertNotIn("*nat", text)  # no NAT rules configured -> no nat table block

    def test_build_restore_input_emits_nat_table_only_when_nat_rules_present(self):
        net = {"networks": [{"name": "ds-clone", "subnet": "172.30.6.0/24"}]}
        fw_data = {"networks": {"ds-clone": {"nat": [
            {"proto": "tcp", "match_dport": 13306, "to_ip": "192.0.2.10", "to_port": 3306},
        ]}}}
        cfg = fw.Config.from_dicts(net, fw_data)
        managed = [s for s in cfg.networks if s.managed]
        nat_specs = [s for s in managed if s.nat_rules]
        lines = fw.IptablesManager._build_restore_input(managed, nat_specs)
        self.assertIn("*nat", lines)
        self.assertTrue(any("DNAT --to-destination 192.0.2.10:3306" in l for l in lines))


class IpsetRefreshTests(unittest.TestCase):
    """IpsetManager._refresh_one(): the seen-set/stale-TTL eviction algorithm,
    with _run() and DNS resolution mocked — no real ipset binary involved."""

    def _fake_run(self, calls):
        def run(args, input=None, allow_fail=False):
            calls.append(args)
            result = mock.Mock()
            if args[:2] == ["ipset", "list"]:
                result.returncode = 0
                result.stdout = "Members:\n" + "\n".join(self._live_ips)
            elif args[:2] == ["ipset", "test"]:
                ip = args[3]
                result.returncode = 0 if ip in self._seen_ips else 1
            else:
                result.returncode = 0
                result.stdout = ""
            return result
        return run

    def test_new_ip_is_added_to_live_and_seen_sets(self):
        self._live_ips = []
        self._seen_ips = set()
        mgr = fw.IpsetManager()
        mgr._sets["allow"] = ["github.com"]
        calls = []
        with mock.patch.object(fw, "_run", self._fake_run(calls)), \
             mock.patch.object(fw, "_resolve_hostname_all", return_value=["1.2.3.4"]):
            mgr._refresh_one("allow")
        add_calls = [c for c in calls if c[:2] == ["ipset", "add"] and c[2] == "-exist" and c[3] == "allow"]
        self.assertTrue(any("1.2.3.4" in c for c in add_calls))

    def test_ip_absent_from_dns_but_still_within_ttl_is_kept(self):
        self._live_ips = ["9.9.9.9"]
        self._seen_ips = {"9.9.9.9"}  # still within its seen-set TTL window
        mgr = fw.IpsetManager()
        mgr._sets["allow"] = ["github.com"]
        calls = []
        with mock.patch.object(fw, "_run", self._fake_run(calls)), \
             mock.patch.object(fw, "_resolve_hostname_all", return_value=["1.2.3.4"]):
            mgr._refresh_one("allow")
        del_calls = [c for c in calls if c[:2] == ["ipset", "del"] and c[2] == "allow"]
        self.assertEqual(del_calls, [])  # not evicted yet

    def test_ip_expired_from_seen_set_is_evicted_from_live_set(self):
        self._live_ips = ["9.9.9.9"]
        self._seen_ips = set()  # seen-set entry has expired (TTL elapsed)
        mgr = fw.IpsetManager()
        mgr._sets["allow"] = ["github.com"]
        calls = []
        with mock.patch.object(fw, "_run", self._fake_run(calls)), \
             mock.patch.object(fw, "_resolve_hostname_all", return_value=["1.2.3.4"]):
            mgr._refresh_one("allow")
        del_calls = [c for c in calls if c[:2] == ["ipset", "del"] and c[2] == "allow"]
        self.assertTrue(any("9.9.9.9" in c for c in del_calls))

    def test_total_dns_failure_leaves_live_set_untouched(self):
        self._live_ips = ["9.9.9.9"]
        self._seen_ips = set()
        mgr = fw.IpsetManager()
        mgr._sets["allow"] = ["github.com"]
        calls = []
        with mock.patch.object(fw, "_run", self._fake_run(calls)), \
             mock.patch.object(fw, "_resolve_hostname_all", return_value=[]):
            mgr._refresh_one("allow")
        # No add/del calls at all: safety guard bails out before touching the kernel.
        mutating = [c for c in calls if c[:2] in (["ipset", "add"], ["ipset", "del"])]
        self.assertEqual(mutating, [])


if __name__ == "__main__":
    unittest.main()
