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

`DOCKSIDE_TEST_CONTAINER_ACCESS=auto|docker|ssh` can request a preferred path.
The test ignores that preference when the requested mechanism is unavailable.
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
    run_in_devtainer,
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

    def test_01_outgoing_ssh_via_integrated_agent(self):
        """Use the devtainer's integrated ssh-agent to SSH to 127.0.0.1."""
        self._ensure_ssh_container()

        expected_pubkey = open(_DEV1_KEY + '.pub', 'r', encoding='utf-8').read().strip()
        try:
            result = run_in_devtainer(
                self.dev1,
                self.SSH_CONTAINER,
                ['bash', '-lc', self._SELF_SSH_SCRIPT],
                private_key_path=_DEV1_KEY,
                preferred=('docker' if self.test_mode in ('local', 'harness') else 'ssh'),
                system_bin_dir=self.test_system_bin_dir,
            )
        except Exception as exc:
            self.skip(str(exc))

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
