"""
09_ssh.py — SSH access tests (inbound via wstunnel)

Test A — Inbound SSH via wstunnel ProxyCommand:
  Prerequisites: wstunnel binary in PATH
  Skipped per-test if wstunnel not found.

The committed test-only Ed25519 keypairs are in:
  t/integration/config/ssh/testdev1_ed25519{,.pub}
  t/integration/config/ssh/testdev2_ed25519{,.pub}
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))
from dockside_test import TestCase, APIError
from _ssh_test_common import (
    SshTestMixin,
    _DEV1_KEY,
    _DEV2_KEY,
    run_host_ssh_via_cli_config,
    ssh_available,
    warn_missing_host_tool,
    wstunnel_available,
)


class SshTests(SshTestMixin, TestCase):
    """Inbound SSH via wstunnel ProxyCommand."""

    # ── Test A: Inbound SSH via wstunnel ──────────────────────────────────────

    def test_01_owner_ssh_via_wstunnel(self):
        """dev1 (owner) can SSH into their devtainer via wstunnel."""
        if not ssh_available():
            warn_missing_host_tool('ssh')
            self.skip('ssh not in PATH')
        if not wstunnel_available():
            warn_missing_host_tool('wstunnel')
            self.skip('wstunnel not in PATH')
        if not os.path.isfile(_DEV1_KEY):
            self.skip(f'testdev1 key not found at {_DEV1_KEY}')

        self._ensure_ssh_container()

        r = run_host_ssh_via_cli_config(
            self.dev1, self.SSH_CONTAINER, _DEV1_KEY, ['echo', 'hello']
        )
        self.assert_equal(r.stdout.strip(), 'hello',
                          f'SSH did not return hello; rc={r.returncode} '
                          f'stderr={r.stderr!r} stdout={r.stdout!r}')

    def test_02_ssh_proxy_denied_to_non_developer(self):
        """dev2 (not in developers) gets 410 from SSH router."""
        self._ensure_ssh_container()
        try:
            self.dev1.update(self.SSH_CONTAINER, developers='')
        except APIError:
            pass
        try:
            self._wait_ssh_route_status(self.dev2, 410, timeout=20)
        except APIError as e:
            self.skip(f'Could not check SSH service: {e}')

    def test_03_add_dev2_and_ssh_connects(self):
        """After adding dev2 as developer, they can SSH in with their key."""
        if not ssh_available():
            warn_missing_host_tool('ssh')
            self.skip('ssh not in PATH')
        if not wstunnel_available():
            warn_missing_host_tool('wstunnel')
            self.skip('wstunnel not in PATH')
        if not os.path.isfile(_DEV2_KEY):
            self.skip(f'testdev2 key not found at {_DEV2_KEY}')

        self._ensure_ssh_container()

        self.dev1.update(self.SSH_CONTAINER, developers=self.test_username_dev2)
        self._wait_ssh_route_accessible(self.dev2, timeout=20)

        r = run_host_ssh_via_cli_config(
            self.dev2, self.SSH_CONTAINER, _DEV2_KEY, ['echo', 'hello']
        )
        self.assert_equal(r.stdout.strip(), 'hello',
                          f'dev2 SSH failed; rc={r.returncode} '
                          f'stderr={r.stderr!r} stdout={r.stdout!r}')

    def test_04_remove_dev2_and_ssh_denied(self):
        """After removing dev2 from developers, SSH proxy returns 410."""
        self._ensure_ssh_container()
        self.dev1.update(self.SSH_CONTAINER, developers=self.test_username_dev2)
        self.dev1.update(self.SSH_CONTAINER, developers='')
        try:
            self._wait_ssh_route_status(self.dev2, 410, timeout=20)
        except APIError as e:
            self.skip(f'Could not check SSH service: {e}')
