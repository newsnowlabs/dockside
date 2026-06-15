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

`DOCKSIDE_TEST_CONTAINER_ACCESS` selects the path explicitly: `ssh` (default) or
`docker`. `auto` is rejected by the runner, and an unavailable requested mechanism
raises rather than silently falling back.
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))
from dockside_test import CapabilityUnavailable, TestCase
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
        # Diagnostic only — confirm ssh-agent and dropbear are running. Use pgrep (match
        # by process name), NOT `ps | grep`: a ps/grep pipeline echoes this script's own
        # command line — which contains the ===AGENTKEYS=== markers below — into stdout,
        # producing spurious marker matches. pgrep -l prints just PID + name.
        'pgrep -l ssh || true; pgrep -l drop || true; '
        'agent_sock=$(ls /tmp/ssh-*/agent.* 2>/dev/null | head -1); '
        'test -n "$agent_sock" || { echo "No ssh-agent socket found in devtainer" >&2; exit 1; }; '
        'ssh_bin="${DOCKSIDE_TEST_SYSTEM_BIN_DIR:-/opt/dockside/system/latest/bin}/ssh"; '
        'ssh_add_bin="${DOCKSIDE_TEST_SYSTEM_BIN_DIR:-/opt/dockside/system/latest/bin}/ssh-add"; '
        '[ -x "$ssh_bin" ] || ssh_bin=ssh; '
        '[ -x "$ssh_add_bin" ] || ssh_add_bin=ssh-add; '
        # Fence the agent listing so the test can assert the key came from the agent
        # (ssh-add -L) and not from the authorized_keys dump that follows.
        'echo ===AGENTKEYS_BEGIN===; '
        'SSH_AUTH_SOCK="$agent_sock" "$ssh_add_bin" -L || true; '
        'echo ===AGENTKEYS_END===; '
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
        except CapabilityUnavailable as exc:
            # CapabilityUnavailable = the container-access mechanism is genuinely
            # unavailable (no ssh/wstunnel/docker, or no key) — a real skip. A plain
            # APIError (e.g. a proxy-spec/config regression) or any other exception is
            # a real failure once the container is up, and now propagates.
            self.skip(str(exc))

        # Assert the key was listed by the AGENT, not merely present in
        # authorized_keys: extract only the fenced ssh-add -L section and match on the
        # key id (type+base64), since the agent may report a different comment.
        # Take the LAST marker pair, as a safeguard against any stray earlier output (the
        # diagnostic above is pgrep-based precisely so it does not echo these markers).
        agent_section = ''
        if '===AGENTKEYS_BEGIN===' in result.stdout and '===AGENTKEYS_END===' in result.stdout:
            agent_section = (result.stdout.rsplit('===AGENTKEYS_BEGIN===', 1)[-1]
                                          .split('===AGENTKEYS_END===', 1)[0])
        self.assert_in(
            _key_id(expected_pubkey), agent_section,
            f'Integrated ssh-agent (ssh-add -L) did not list the expected key; '
            f'agent_section={agent_section!r} stdout={result.stdout!r} stderr={result.stderr!r}'
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

        dev1 already has the legacy '*' keypair; transiently add a second one,
        relaunch so launch.sh re-deploys the full keypair map, and assert both keys
        are in the agent.

        dev1 may be an ADOPTED pre-existing fixture that setup must never mutate, so
        the edit here is treated as save-and-restore of dev1's EXACT prior state: we
        proceed only when the throwaway 'inttest2' keypair is absent (skipping rather
        than overwriting should a real one exist) and unset it again in the finally,
        returning dev1 to that verified-absent state. (A dedicated throwaway user is
        the alternative, but it would have to clone dev1's whole fixture — role,
        per-user resources, public keys — and launch its own container.)
        """
        if not (os.path.isfile(_DEV1_KEY) and os.path.isfile(_DEV2_KEY)):
            self.skip('testdev keypairs not available')
        self._ensure_ssh_container()

        key1 = _key_id(open(_DEV1_KEY + '.pub', encoding='utf-8').read())
        second_pub = open(_DEV2_KEY + '.pub', encoding='utf-8').read().strip()
        key2 = _key_id(second_pub)
        user = self.test_username_dev1

        # Never clobber data on a possibly-adopted dev1: only add inttest2 if absent.
        prior = self.admin._run('user', 'get', user)
        prior_keypairs = ((prior.get('ssh') or {}).get('keypairs')) or {}
        if 'inttest2' in prior_keypairs:
            self.skip("dev1 already has an 'inttest2' keypair; "
                      "refusing to overwrite an adopted fixture")

        # Mutate INSIDE the try so the finally always attempts the restore — even if the
        # edit's client call raises after the change already applied server-side. Mark the
        # attempt before issuing it, for the same reason.
        attempted_set = False
        restore_error = None
        try:
            attempted_set = True
            self.admin._run(
                'user', 'edit', user,
                '--set', f'ssh.keypairs.inttest2.public={second_pub}',
                '--set', f'ssh.keypairs.inttest2.private=@{_DEV2_KEY}',
            )
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
            # Restore dev1 to its verified prior state (inttest2 absent). A failure here
            # would leave an adopted fixture mutated, so record it and fail below — but
            # do not raise in the finally, which would mask a failure from the body.
            if attempted_set:
                try:
                    self.admin._run('user', 'edit', user, '--unset', 'ssh.keypairs.inttest2')
                except Exception as exc:
                    restore_error = exc
                    print(f'# ERROR: failed to restore dev1 (remove inttest2 keypair): {exc}',
                          file=sys.stderr)
        self.assert_true(
            restore_error is None,
            f'failed to restore dev1 after test; inttest2 keypair may persist: {restore_error}')
