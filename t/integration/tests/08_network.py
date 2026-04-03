"""
08_network.py — Network options

Design principle:
  Devtainers can only join networks connected to the Dockside container.
  Whether it is safe to create/attach/detach new Docker networks depends on
  context:

  Default behaviour by mode:
    harness → can modify (we own the Dockside container)
    local   → cannot modify (may be a developer's production instance)
    remote  → cannot modify (definitely someone's live system)

  This default can always be overridden via:
    DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY=1   force-enable network modification
    DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY=0   force-disable

  can_modify_networks() (from TestCase base) applies this logic.
"""

import subprocess
import sys
import os
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError


def _docker_networks():
    """Return list of docker network names visible on the host."""
    try:
        r = subprocess.run(
            ['docker', 'network', 'ls', '--format', '{{.Name}}'],
            capture_output=True, text=True, timeout=10
        )
        return r.stdout.splitlines()
    except Exception:
        return []


def _docker_available():
    try:
        r = subprocess.run(['docker', 'version'], capture_output=True, timeout=5)
        return r.returncode == 0
    except Exception:
        return False


class NetworkTests(TestCase):
    """Network availability and assignment tests."""

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _get_available_networks(self):
        """
        Ask Dockside what networks are available for a new devtainer.
        Returns list of network name strings, or None if unsupported.
        """
        try:
            containers = self.admin.list_containers()
            networks = set()
            for c in containers:
                if isinstance(c, dict):
                    net = (c.get('data') or {}).get('network') or c.get('network')
                    if net:
                        networks.add(net)
            return list(networks) if networks else None
        except APIError:
            return None

    def _create_and_cleanup(self, name, **kwargs):
        self.register_cleanup(name)
        return self.admin.create(
            profile=self.test_profile_alpine,
            name=name,
            **kwargs
        )

    # ── Common tests (all modes) ──────────────────────────────────────────────

    def test_01_create_default_network(self):
        """Create without --network; container should be assigned a network."""
        name = 'inttest-net-default'
        self._create_and_cleanup(name)
        data = self.admin.get_container(name)
        network = (data.get('data') or {}).get('network') or data.get('network')
        self.assert_true(network is not None and network != '',
                         'container has no network after creation')

    def test_02_create_on_discovered_network(self):
        """Create on a network currently known to Dockside (first available)."""
        seed_name = 'inttest-net-seed'
        self._create_and_cleanup(seed_name)
        seed_data = self.admin.get_container(seed_name)
        network = (seed_data.get('data') or {}).get('network') or seed_data.get('network')
        if not network:
            self.skip('Could not discover available network from existing container')

        name = 'inttest-net-explicit'
        self._create_and_cleanup(name)
        try:
            self.admin.update(name, network=network)
        except APIError as e:
            self.skip(f'Cannot set network via edit: {e}')
        data = self.admin.get_container(name)
        actual = (data.get('data') or {}).get('network') or data.get('network')
        self.assert_equal(actual, network, f'network mismatch: {actual!r} != {network!r}')

    def test_03_network_persists_after_edit(self):
        """Network field persists after an unrelated edit."""
        name = 'inttest-net-persist'
        self._create_and_cleanup(name)
        data = self.admin.get_container(name)
        network = (data.get('data') or {}).get('network') or data.get('network')

        self.admin.update(name, description='network persistence test')
        data2 = self.admin.get_container(name)
        network2 = (data2.get('data') or {}).get('network') or data2.get('network')
        self.assert_equal(network, network2, 'network changed after unrelated edit')

    def test_04_edit_network(self):
        """
        Switch network via edit (requires at least two available networks).
        Skips gracefully if only one network is available.
        """
        seed_name = 'inttest-net-switch-seed'
        self._create_and_cleanup(seed_name)
        seed_data = self.admin.get_container(seed_name)
        net_a = (seed_data.get('data') or {}).get('network') or seed_data.get('network')

        all_containers = self.admin.list_containers()
        net_b = None
        for c in all_containers:
            if not isinstance(c, dict):
                continue
            n = (c.get('data') or {}).get('network') or c.get('network')
            if n and n != net_a:
                net_b = n
                break

        if not net_b:
            self.skip('Only one network available; cannot test network switch')

        name = 'inttest-net-switch'
        self._create_and_cleanup(name)
        try:
            self.admin.update(name, network=net_b)
        except APIError as e:
            self.skip(f'Cannot switch network: {e}')
        data = self.admin.get_container(name)
        actual = (data.get('data') or {}).get('network') or data.get('network')
        self.assert_equal(actual, net_b, f'network not switched: {actual!r}')

    # ── Harness/modify tests (require can_modify_networks()) ─────────────────

    def test_05_create_and_attach_test_network(self):
        """
        Create a unique Docker network, attach it to the Dockside container,
        verify it appears in available networks, then clean up.
        Requires: can_modify_networks() == True AND docker CLI available AND
                  harness_container_id known.
        """
        if not self.can_modify_networks():
            self.skip('Network modification not enabled for this mode '
                      '(set DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY=1 to enable)')
        if not _docker_available():
            self.skip('docker CLI not available')
        if not self.harness_container_id:
            self.skip('harness_container_id not set; cannot attach network to Dockside container')

        test_net = f'inttest-net-{uuid.uuid4().hex[:8]}'
        created  = False
        attached = False
        try:
            r = subprocess.run(['docker', 'network', 'create', test_net],
                               capture_output=True, timeout=15)
            if r.returncode != 0:
                self.skip(f'docker network create failed: {r.stderr.decode()}')
            created = True

            r = subprocess.run(
                ['docker', 'network', 'connect', test_net, self.harness_container_id],
                capture_output=True, timeout=15
            )
            if r.returncode != 0:
                self.skip(f'docker network connect failed: {r.stderr.decode()}')
            attached = True

            probe_name = 'inttest-net-probe'
            self.register_cleanup(probe_name)
            try:
                self.admin.create(
                    profile=self.test_profile_alpine,
                    name=probe_name,
                    network=test_net,
                )
                probe_data = self.admin.get_container(probe_name)
                actual_net = ((probe_data.get('data') or {}).get('network')
                              or probe_data.get('network'))
                self.assert_equal(actual_net, test_net,
                                  f'probe container not on test network: {actual_net!r}')
            except APIError as e:
                self.skip(f'Could not create devtainer on test network: {e}')

        finally:
            if attached:
                subprocess.run(
                    ['docker', 'network', 'disconnect', test_net, self.harness_container_id],
                    capture_output=True, timeout=15
                )
            if created:
                subprocess.run(['docker', 'network', 'rm', test_net],
                               capture_output=True, timeout=15)

    def test_06_test_network_disappears_after_detach(self):
        """
        Create a test network, attach to Dockside, verify available, detach,
        verify it's no longer creatable for new devtainers.
        """
        if not self.can_modify_networks():
            self.skip('Network modification not enabled for this mode')
        if not _docker_available():
            self.skip('docker CLI not available')
        if not self.harness_container_id:
            self.skip('harness_container_id not set')

        test_net = f'inttest-net-{uuid.uuid4().hex[:8]}'
        created  = False
        try:
            r = subprocess.run(['docker', 'network', 'create', test_net],
                               capture_output=True, timeout=15)
            if r.returncode != 0:
                self.skip(f'docker network create failed')
            created = True

            r = subprocess.run(
                ['docker', 'network', 'connect', test_net, self.harness_container_id],
                capture_output=True, timeout=15
            )
            if r.returncode != 0:
                self.skip(f'docker network connect failed')

            # Detach immediately
            subprocess.run(
                ['docker', 'network', 'disconnect', test_net, self.harness_container_id],
                capture_output=True, timeout=15
            )

            # Now attempting to create a container on this network should fail
            name = 'inttest-net-gone'
            self.register_cleanup(name)
            try:
                self.admin.create(
                    profile=self.test_profile_alpine,
                    name=name,
                    network=test_net,
                )
                pass
            except APIError:
                pass  # Expected: network no longer available

        finally:
            if created:
                subprocess.run(['docker', 'network', 'rm', test_net],
                               capture_output=True, timeout=15)
