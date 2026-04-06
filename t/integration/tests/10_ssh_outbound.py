"""
10_ssh_outbound.py — Outbound SSH via the devtainer's integrated ssh-agent.

Prerequisites:
  - docker CLI in PATH
  - harness_container_id known or DOCKSIDE_TEST_CONTAINER_ID set
  - DOCKSIDE_TEST_SSH_SERVER set (default: git@github.com)
  - testdev1 public key pre-authorised at that server

The committed test-only Ed25519 keypair is in:
  t/integration/config/ssh/testdev1_ed25519{,.pub}
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))
from dockside_test import TestCase
from _ssh_test_common import SshTestMixin, docker_available


class SshOutboundTests(SshTestMixin, TestCase):
    """Outbound SSH via the devtainer's integrated ssh-agent."""

    def test_01_outgoing_ssh_via_integrated_agent(self):
        """Use the devtainer's integrated ssh-agent to SSH outward."""
        if not docker_available():
            self.skip('docker CLI not available')

        container_id = (
            self.harness_container_id
            or os.environ.get('DOCKSIDE_TEST_CONTAINER_ID', '').strip()
        )
        if not container_id:
            self.skip('No Dockside container ID available (set DOCKSIDE_TEST_CONTAINER_ID)')

        ssh_server = os.environ.get('DOCKSIDE_TEST_SSH_SERVER', 'git@github.com').strip()

        self._ensure_ssh_container()

        data = self.dev1.get_container(self.SSH_CONTAINER)
        devtainer_id = (data.get('data') or {}).get('id') or data.get('containerId')
        if not devtainer_id:
            self.skip('Could not determine devtainer container ID')

        result = subprocess.run(
            ['docker', 'exec', devtainer_id, 'bash', '-c',
             'ls /tmp/ssh-*/agent.* 2>/dev/null | head -1'],
            capture_output=True, text=True, timeout=10
        )
        agent_sock = result.stdout.strip()
        if not agent_sock:
            self.skip('No ssh-agent socket found in devtainer (IDE not started?)')

        result = subprocess.run(
            ['docker', 'exec', '-e', f'SSH_AUTH_SOCK={agent_sock}',
             devtainer_id, 'ssh', '-T', '-o', 'StrictHostKeyChecking=no',
             ssh_server],
            capture_output=True, text=True, timeout=30
        )
        output = (result.stdout + result.stderr).lower()
        if 'github.com' in ssh_server:
            self.assert_true(
                'successfully authenticated' in output,
                f'Expected "successfully authenticated" in output; got: {output[:200]!r}'
            )
        else:
            self.assert_true(
                result.returncode == 0 or 'authenticated' in output or 'welcome' in output,
                f'Outgoing SSH failed; rc={result.returncode} output={output[:200]!r}'
            )
