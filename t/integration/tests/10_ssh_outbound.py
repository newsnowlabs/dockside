"""
10_ssh_outbound.py — Outbound SSH via the devtainer's integrated ssh-agent.

This test verifies that the devtainer's integrated ssh-agent can authenticate
an outbound SSH connection by SSHing from the devtainer to its own local SSH
server on 127.0.0.1. The matching public key is already provisioned into the
owner user's authorized_keys inside the devtainer, so no external SSH service
is required.

Execution path is mode-dependent:
  - local / harness: use docker exec for direct in-container verification
  - remote: use dockside ssh, because host Docker access to the devtainer is
    not available from the external machine

Both paths perform the same substantive check:
  1. find SSH_AUTH_SOCK inside the devtainer
  2. use that agent to SSH to dockside@127.0.0.1
  3. expect the local SSH server in the same devtainer to accept the key
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))
from dockside_test import TestCase
from _ssh_test_common import (
    SshTestMixin,
    _DEV1_KEY,
    docker_available,
    run_host_ssh_via_cli_config,
    ssh_available,
    warn_missing_host_tool,
    wstunnel_available,
)


class SshOutboundTests(SshTestMixin, TestCase):
    """Outbound SSH via the devtainer's integrated ssh-agent."""

    _SELF_SSH_SCRIPT = (
        "ps auxw | egrep '(ssh|drop)' || true; "
        'agent_sock=$(ls /tmp/ssh-*/agent.* 2>/dev/null | head -1); '
        'test -n "$agent_sock" || { echo "No ssh-agent socket found in devtainer" >&2; exit 1; }; '
        'ssh_bin="${DOCKSIDE_TEST_SYSTEM_BIN_DIR:-/opt/dockside/system/latest/bin}/ssh"; '
        'ssh_add_bin="${DOCKSIDE_TEST_SYSTEM_BIN_DIR:-/opt/dockside/system/latest/bin}/ssh-add"; '
        '[ -x "$ssh_bin" ] || ssh_bin=ssh; '
        '[ -x "$ssh_add_bin" ] || ssh_add_bin=ssh-add; '
        'SSH_AUTH_SOCK="$agent_sock" "$ssh_add_bin" -L || true; '
        'cat ~dockside/.ssh/authorized_keys || true; '
        'SSH_AUTH_SOCK="$agent_sock" '
        '"$ssh_bin" -T '
        '-o StrictHostKeyChecking=no '
        '-o UserKnownHostsFile=/dev/null '
        '-o BatchMode=yes '
        'dockside@127.0.0.1 echo hello'
    )

    def _run_self_ssh_via_docker(self, devtainer_id):
        return subprocess.run(
            ['docker', 'exec', '-e', f'DOCKSIDE_TEST_SYSTEM_BIN_DIR={self.test_system_bin_dir}',
             devtainer_id, 'bash', '-lc', self._SELF_SSH_SCRIPT],
            capture_output=True, text=True, timeout=30
        )

    def _run_self_ssh_via_dockside_ssh(self):
        if not ssh_available():
            warn_missing_host_tool('ssh')
            self.skip('ssh not in PATH')
        if not wstunnel_available():
            warn_missing_host_tool('wstunnel')
            self.skip('wstunnel not in PATH')
        if not os.path.isfile(_DEV1_KEY):
            self.skip(f'testdev1 key not found at {_DEV1_KEY}')
        return run_host_ssh_via_cli_config(
            self.dev1, self.SSH_CONTAINER, _DEV1_KEY, ['bash', '-lc', self._SELF_SSH_SCRIPT]
        )

    def test_01_outgoing_ssh_via_integrated_agent(self):
        """Use the devtainer's integrated ssh-agent to SSH to 127.0.0.1."""
        self._ensure_ssh_container()

        expected_pubkey = open(_DEV1_KEY + '.pub', 'r', encoding='utf-8').read().strip()

        if self.test_mode in ('local', 'harness'):
            if not docker_available():
                self.skip('docker CLI not available')
            data = self.dev1.get_container(self.SSH_CONTAINER)
            devtainer_id = (data.get('data') or {}).get('id') or data.get('containerId')
            if not devtainer_id:
                self.skip('Could not determine devtainer container ID')
            result = self._run_self_ssh_via_docker(devtainer_id)
        else:
            result = self._run_self_ssh_via_dockside_ssh()

        self.assert_in(
            expected_pubkey, result.stdout,
            f'Integrated ssh-agent did not report the expected key; '
            f'stdout={result.stdout!r} stderr={result.stderr!r}'
        )
        self.assert_true(
            result.returncode == 0 and result.stdout.strip().endswith('hello'),
            f'Outgoing self-SSH failed; rc={result.returncode} '
            f'stdout={result.stdout!r} stderr={result.stderr!r}'
        )
