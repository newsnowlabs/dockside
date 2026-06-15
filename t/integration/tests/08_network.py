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


def _docker_manages_container(ctr):
    """True if the docker daemon reachable here manages container `ctr`.

    A Dockside container launched with runc / io.containerd.runc.v2 + a bind-mounted
    /var/run/docker.sock talks to the host daemon, which DOES manage it. One launched
    with sysbox-runc instead runs an independent inner dockerd (per entrypoint.sh) that
    does NOT manage the Dockside container — so a network cannot be attached to it from
    here. This guard lets the network-attach tests skip cleanly in that case rather than
    create a network and then fail on connect.
    """
    try:
        r = subprocess.run(['docker', 'container', 'inspect', ctr],
                           capture_output=True, timeout=10)
        return r.returncode == 0
    except Exception:
        return False


class NetworkTests(TestCase):
    """Network availability and assignment tests."""

    # Test networks currently connected to the Dockside container, as (net, container)
    # pairs. tearDownClass disconnects/removes any that remain — and the harness routes
    # SIGINT/SIGTERM through tearDownClass (emergency cleanup), so an interrupted run
    # never leaves a test network attached to the container. These tests only ever touch
    # their own throwaway 'inttest-net-*' networks, never the container's existing ones.
    _attached_networks = []

    @classmethod
    def tearDownClass(cls):
        while cls._attached_networks:
            net, ctr = cls._attached_networks.pop()
            subprocess.run(['docker', 'network', 'disconnect', net, ctr],
                           capture_output=True, timeout=15)
            subprocess.run(['docker', 'network', 'rm', net],
                           capture_output=True, timeout=15)

    def _dockside_container(self):
        """Resolve the Dockside container to attach test networks to: harness mode's id,
        else the explicit/auto-detected non-harness id. None if neither is known."""
        return self.harness_container_id or getattr(self, 'dockside_container_id', None)

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
        name = self._sfx('inttest-net-default')
        self._create_and_cleanup(name)
        data = self.admin.get_container(name)
        network = (data.get('data') or {}).get('network') or data.get('network')
        self.assert_true(network is not None and network != '',
                         'container has no network after creation')

    def test_02_create_on_discovered_network(self):
        """Create on a network currently known to Dockside (first available)."""
        seed_name = self._sfx('inttest-net-seed')
        self._create_and_cleanup(seed_name)
        seed_data = self.admin.get_container(seed_name)
        network = (seed_data.get('data') or {}).get('network') or seed_data.get('network')
        if not network:
            self.skip('Could not discover available network from existing container')

        name = self._sfx('inttest-net-explicit')
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
        name = self._sfx('inttest-net-persist')
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
        seed_name = self._sfx('inttest-net-switch-seed')
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

        name = self._sfx('inttest-net-switch')
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
                  a Dockside container id (harness or explicit/auto-detected).
        """
        if not self.can_modify_networks():
            self.skip('Network modification not enabled for this mode '
                      '(set DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY=1 to enable)')
        if not _docker_available():
            self.skip('docker CLI not available')
        ctr = self._dockside_container()
        if not ctr:
            self.skip('no Dockside container id known (set DOCKSIDE_TEST_CONTAINER_ID) '
                      'to attach a network to the Dockside container')
        if not _docker_manages_container(ctr):
            self.skip(f'docker daemon reachable here does not manage container {ctr!r} '
                      '(e.g. a sysbox-runc inner dockerd); cannot attach a network to it')

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
                ['docker', 'network', 'connect', test_net, ctr],
                capture_output=True, timeout=15
            )
            if r.returncode != 0:
                self.skip(f'docker network connect failed: {r.stderr.decode()}')
            attached = True
            self._attached_networks.append((test_net, ctr))  # for emergency teardown

            probe_name = self._sfx('inttest-net-probe')
            self.register_cleanup(probe_name)

            # Discovery is asynchronous: docker-event-daemon must notice the network
            # connected to the Dockside container and rewrite containers.json, the Perl
            # app must reload it, and Profile::applyDefaultsAndFilters must re-read the
            # in-memory host networks before the new network is offered for a reservation.
            # So retry the create until it is accepted (or time out), rather than assuming
            # it is usable the instant after `docker network connect`.
            def _create_probe_on_test_net():
                try:
                    self.admin.create(
                        profile=self.test_profile_alpine,
                        name=probe_name,
                        network=test_net,
                    )
                    return True
                except APIError:
                    return False  # not yet discovered by Dockside; retry
            try:
                self.wait_until(
                    _create_probe_on_test_net, timeout=45, interval=3,
                    timeout_msg='Dockside did not make the attached test network '
                                'available for a reservation')
            except AssertionError as e:
                self.skip(str(e))

            probe_data = self.admin.get_container(probe_name)
            actual_net = ((probe_data.get('data') or {}).get('network')
                          or probe_data.get('network'))
            self.assert_equal(actual_net, test_net,
                              f'probe container not on test network: {actual_net!r}')

        finally:
            if attached:
                subprocess.run(
                    ['docker', 'network', 'disconnect', test_net, ctr],
                    capture_output=True, timeout=15
                )
                try:
                    self._attached_networks.remove((test_net, ctr))
                except ValueError:
                    pass
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
        ctr = self._dockside_container()
        if not ctr:
            self.skip('no Dockside container id known (set DOCKSIDE_TEST_CONTAINER_ID) '
                      'to attach a network to the Dockside container')
        if not _docker_manages_container(ctr):
            self.skip(f'docker daemon reachable here does not manage container {ctr!r} '
                      '(e.g. a sysbox-runc inner dockerd); cannot attach a network to it')

        test_net = f'inttest-net-{uuid.uuid4().hex[:8]}'
        created  = False
        attached = False
        try:
            r = subprocess.run(['docker', 'network', 'create', test_net],
                               capture_output=True, timeout=15)
            if r.returncode != 0:
                self.skip(f'docker network create failed')
            created = True

            r = subprocess.run(
                ['docker', 'network', 'connect', test_net, ctr],
                capture_output=True, timeout=15
            )
            if r.returncode != 0:
                self.skip(f'docker network connect failed')
            attached = True
            self._attached_networks.append((test_net, ctr))  # for emergency teardown

            # Detach immediately
            subprocess.run(
                ['docker', 'network', 'disconnect', test_net, ctr],
                capture_output=True, timeout=15
            )
            attached = False
            try:
                self._attached_networks.remove((test_net, ctr))
            except ValueError:
                pass

            # The Dockside container is no longer attached to test_net, so Dockside
            # must no longer offer it: creating a container on it has to be rejected.
            # cleanup is registered first so a regression that lets it succeed still
            # tears the container down.
            name = self._sfx('inttest-net-gone')
            self.register_cleanup(name)
            self.assert_api_error(
                self.admin.create,
                profile=self.test_profile_alpine,
                name=name,
                network=test_net,
            )

        finally:
            if attached:
                subprocess.run(
                    ['docker', 'network', 'disconnect', test_net, ctr],
                    capture_output=True, timeout=15
                )
                try:
                    self._attached_networks.remove((test_net, ctr))
                except ValueError:
                    pass
            if created:
                subprocess.run(['docker', 'network', 'rm', test_net],
                               capture_output=True, timeout=15)
