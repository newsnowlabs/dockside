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
    _DEV2_KEY,
    run_in_devtainer,
)


def _key_id(pubkey_text):
    """Return 'type base64' from a public key line, dropping the comment — ssh-add -L
    may report a different comment than the .pub file, but the key material is stable."""
    parts = pubkey_text.split()
    return ' '.join(parts[:2]) if len(parts) >= 2 else pubkey_text.strip()


class SshOutboundTests(SshTestMixin, TestCase):
    """Outbound SSH via the devtainer's integrated ssh-agent."""

    # Each SSH test module must use a distinct base container name.
    # tearDownClass removes with wait=False, so back-to-back module runs would
    # hit Docker's "name already in use" error if the prior removal was still
    # in flight when the next module's setUpClass called create().
    _BASE_SSH_CONTAINER = 'inttest-outbound-ssh-01'

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
                preferred='ssh',
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

    _AGENT_LIST_SCRIPT = (
        'ssh_add="${DOCKSIDE_TEST_SYSTEM_BIN_DIR:-/opt/dockside/system/latest/bin}/ssh-add"; '
        '[ -x "$ssh_add" ] || ssh_add=ssh-add; '
        'agent_sock=; '
        'for s in /tmp/ssh-*/agent.*; do '
        '  [ -S "$s" ] && SSH_AUTH_SOCK="$s" "$ssh_add" -l >/dev/null 2>&1 && '
        '  { agent_sock="$s"; break; }; '
        'done; '
        'test -n "$agent_sock" || { echo "No ssh-agent socket found in devtainer" >&2; exit 1; }; '
        'SSH_AUTH_SOCK="$agent_sock" "$ssh_add" -L'
    )

    def test_02_all_keypairs_in_agent(self):
        """All of a user's keypairs — not just '*' — are deployed to the agent.

        testdev1 already has the legacy '*' keypair; add a second one, relaunch so
        launch.sh re-deploys the full keypair map, and assert both keys are in the agent.
        """
        if not (os.path.isfile(_DEV1_KEY) and os.path.isfile(_DEV2_KEY)):
            self.skip('testdev keypairs not available')
        self._ensure_ssh_container()

        key1 = _key_id(open(_DEV1_KEY + '.pub', encoding='utf-8').read())
        second_pub = open(_DEV2_KEY + '.pub', encoding='utf-8').read().strip()
        key2 = _key_id(second_pub)
        user = self.test_username_dev1

        self.admin._run(
            'user', 'edit', user,
            '--set', f'ssh.keypairs.inttest2.public={second_pub}',
            '--set', f'ssh.keypairs.inttest2.private=@{_DEV2_KEY}',
        )
        try:
            # Relaunch so the IDE-launch exec re-pushes the full keypair map.
            self.dev1.stop(self.SSH_CONTAINER, wait=True, timeout=60)
            self.dev1.start(self.SSH_CONTAINER, wait=True, timeout=180)

            def _agent_listing_with_both():
                try:
                    r = run_in_devtainer(
                        self.dev1, self.SSH_CONTAINER,
                        ['bash', '-lc', self._AGENT_LIST_SCRIPT],
                        private_key_path=_DEV1_KEY, preferred='ssh',
                        system_bin_dir=self.test_system_bin_dir,
                    )
                except Exception:
                    return None
                return r.stdout if (key1 in r.stdout and key2 in r.stdout) else None

            listing = self.wait_until(
                _agent_listing_with_both, timeout=90, interval=3,
                timeout_msg='ssh-agent did not list both keypairs')
            self.assert_in(key1, listing, "legacy '*' keypair missing from agent")
            self.assert_in(key2, listing, 'second keypair missing from agent')
        finally:
            try:
                self.admin._run('user', 'edit', user, '--unset', 'ssh.keypairs.inttest2')
            except Exception:
                pass
