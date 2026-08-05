"""
15_entrypoint_signaling.py — Dockside's own signaling for patterns B and C
(docs/extensions/lifecycle-hooks.md)

These patterns hand branch/PR/repo switching entirely to an application's own
entrypoint script — Dockside's only job is to make the right primitive
available at the right time. This module tests exactly those primitives, not
any application-level ref-parsing logic (already covered for the shared
disambiguation logic via pattern A in 06_git_profile.py):

  - Pattern B: `{option.<name>}` resolves into the container's own `command`
    argv at container-create time, verbatim (no shell reinterpretation) - kept
    deliberately fast, no credential-dependent wait.
  - Pattern C: once `/tmp/dockside/.credentials-ready` appears, a live
    ssh-agent socket (discovered the same way an entrypoint following the
    documented pattern would - launch.sh does not pin it to a fixed path)
    genuinely has the launching user's key(s) loaded, and (if a GitHub token
    is configured on the user) `gh` is genuinely authenticated on disk.
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, CapabilityUnavailable
sys.path.insert(0, os.path.dirname(__file__))
from _ssh_test_common import SshTestMixin, _DEV1_KEY, run_in_devtainer

GITHUB_TOKEN = os.environ.get('DOCKSIDE_TEST_GITHUB_TOKEN', '')


# ── Pattern B ────────────────────────────────────────────────────────────────

class OptionArgvResolutionTests(TestCase):
    """{option.<name>} resolves into the container's own command argv, verbatim."""

    def _read_marker(self, name):
        try:
            result = run_in_devtainer(
                self.dev1,
                name,
                ['cat', '/tmp/option-argv-marker'],
                private_key_path=_DEV1_KEY,
                preferred=('docker' if self.test_mode in ('local', 'harness') else 'ssh'),
                system_bin_dir=self.test_system_bin_dir,
                run_as_user='dockside',
            )
        except CapabilityUnavailable as exc:
            self.skip(str(exc))
        return result.stdout if result.returncode == 0 else None

    def _create_and_read(self, name, value):
        self.register_cleanup(name)
        result = self.dev1.create(
            profile=self.test_profile_option_argv,
            name=name,
            options=json.dumps({'value': value}),
        )
        self.assert_true(result is not None)
        self.wait_running(self.dev1, name, timeout=60)

        marker = self.wait_until(
            lambda: self._read_marker(name),
            timeout=20,
            interval=1,
            timeout_msg=f'/tmp/option-argv-marker never appeared for {name!r}',
        )
        return marker

    def test_01_option_value_resolved_into_argv(self):
        name = self._sfx('inttest-argv-plain')
        marker = self._create_and_read(name, 'hello world')
        self.assert_equal(marker, 'hello world')

    def test_02_option_value_with_shell_metacharacters_not_executed(self):
        # Proves Dockside's own argv handling never reinterprets the option value
        # as shell syntax - a platform guarantee, distinct from (and a
        # prerequisite for) the app-level injection-safety already verified by
        # hand for the real example scripts that consume {option.ref} this way.
        name = self._sfx('inttest-argv-inject')
        payload = '; touch /tmp/pwned-argv-test ;'
        marker = self._create_and_read(name, payload)
        self.assert_equal(marker, payload)

        try:
            result = run_in_devtainer(
                self.dev1,
                name,
                ['sh', '-c', 'test -f /tmp/pwned-argv-test && echo YES || echo NO'],
                private_key_path=_DEV1_KEY,
                preferred=('docker' if self.test_mode in ('local', 'harness') else 'ssh'),
                system_bin_dir=self.test_system_bin_dir,
                run_as_user='dockside',
            )
        except CapabilityUnavailable as exc:
            self.skip(str(exc))
        self.assert_equal(result.stdout.strip(), 'NO', 'option value was executed as shell syntax')


# ── Pattern C ────────────────────────────────────────────────────────────────

class SshAgentCredentialsReadyTests(SshTestMixin, TestCase):
    """Once .credentials-ready appears, a live ssh-agent socket genuinely has the
    launching user's key loaded - using dev1, who already has a full SSH keypair
    fixture (see run_tests_main.py's _ensure_user call for user_dev1). launch.sh
    lets ssh-agent choose its own socket path rather than pinning it (see
    docs/plans/lifecycle-hooks-review-followup.md item A), so this discovers it
    the same way launch.sh's own run_hook()/find_ssh_auth_sock() and
    10_ssh_outbound.py's _AGENT_LIST_SCRIPT do: scan /tmp/ssh-*/agent.*, validate
    with `ssh-add -l` (exit 0 or 1 both mean a live agent - 1 just means no keys
    loaded, still a real answer; only something else, e.g. 2, means dead/unreachable)."""

    _BASE_SSH_CONTAINER = 'inttest-cred-ssh-01'

    _CHECK_SCRIPT = (
        'printf "credentials_ready=%s\\n" '
        '"$(test -f /tmp/dockside/.credentials-ready && echo 1 || echo 0)"; '
        'ssh_add_bin="${DOCKSIDE_TEST_SYSTEM_BIN_DIR:-/opt/dockside/system/latest/bin}/ssh-add"; '
        '[ -x "$ssh_add_bin" ] || ssh_add_bin=ssh-add; '
        'agent_sock=; '
        'for s in /tmp/ssh-*/agent.*; do '
        '  [ -S "$s" ] || continue; '
        '  SSH_AUTH_SOCK="$s" "$ssh_add_bin" -l >/dev/null 2>&1; '
        '  case $? in 0|1) agent_sock="$s"; break ;; esac; '
        'done; '
        'echo AGENTKEYS_BEGIN; '
        '[ -n "$agent_sock" ] && SSH_AUTH_SOCK="$agent_sock" "$ssh_add_bin" -L 2>&1; '
        'echo AGENTKEYS_END'
    )

    def _key_id(self, pubkey_text):
        parts = pubkey_text.split()
        return ' '.join(parts[:2]) if len(parts) >= 2 else pubkey_text.strip()

    def _check(self):
        try:
            result = run_in_devtainer(
                self.dev1,
                self.SSH_CONTAINER,
                ['sh', '-c', self._CHECK_SCRIPT],
                private_key_path=_DEV1_KEY,
                preferred=('docker' if self.test_mode in ('local', 'harness') else 'ssh'),
                system_bin_dir=self.test_system_bin_dir,
            )
        except CapabilityUnavailable as exc:
            self.skip(str(exc))
        if result.returncode != 0:
            return None
        out = {}
        agent_lines = []
        in_agent = False
        for line in result.stdout.splitlines():
            if line == 'AGENTKEYS_BEGIN':
                in_agent = True
                continue
            if line == 'AGENTKEYS_END':
                in_agent = False
                continue
            if in_agent:
                agent_lines.append(line)
            elif '=' in line:
                key, value = line.split('=', 1)
                out[key.strip()] = value.strip()
        out['agent_keys'] = '\n'.join(agent_lines)
        return out

    def test_01_credentials_ready_and_agent_key_loaded(self):
        self._ensure_ssh_container()

        state = {}

        def _poll():
            nonlocal state
            state = self._check() or {}
            return state if state.get('credentials_ready') == '1' else False

        # wait_until raises on timeout, so a return here always means the
        # predicate was truthy (state['credentials_ready'] == '1').
        self.wait_until(
            _poll,
            timeout=90,
            interval=1,
            timeout_msg='.credentials-ready never appeared',
        )
        self.assert_equal(state.get('credentials_ready'), '1')

        expected_pubkey = open(_DEV1_KEY + '.pub', 'r', encoding='utf-8').read().strip()
        self.assert_in(
            self._key_id(expected_pubkey),
            state.get('agent_keys', ''),
            f'dev1 key not found in ssh-agent listing: {state.get("agent_keys")!r}',
        )


class GhAuthCredentialsReadyTests(TestCase):
    """Once .credentials-ready appears, gh is genuinely authenticated on disk -
    requires a real GitHub token persisted on a user record (the mechanism
    Reservation.pm's _hook_env()/exec() read via $user->gh_token(), distinct from
    a launch-time options.gh_token trick), so uses a dedicated throwaway user
    rather than mutating a shared fixture user."""

    _BASE_USER = 'inttest-cred-gh'
    _BASE_CONTAINER = 'inttest-cred-gh-01'
    _PASSWORD = 'inttest-cred-gh-pass'

    @classmethod
    def setUpClass(cls):
        if not GITHUB_TOKEN:
            return
        cls._user = cls._sfx(cls._BASE_USER)
        # Register the same key run_in_devtainer's SSH backend (used in 'remote'
        # test mode) authenticates with as _DEV1_KEY, so it is actually present in
        # this throwaway user's own container's authorized_keys - without this,
        # the 'docker' backend (local/harness) works fine, but 'ssh' mode would
        # fail authentication rather than cleanly skip.
        dev1_pubkey = open(_DEV1_KEY + '.pub', 'r', encoding='utf-8').read().strip()
        cls.admin._run(
            'user', 'create', cls._user,
            '--role', cls.test_role_developer,
            '--user-password', cls._PASSWORD,
            '--gh-token', GITHUB_TOKEN,
            '--resources', (
                '{"profiles":["*"],"networks":["*"],"runtimes":["runc"],'
                '"IDEs":["*"],"images":["*"],"auth":["*"]}'
            ),
            '--set', f'ssh.publicKeys.integration-key-pub={dev1_pubkey}',
        )
        cls._client = cls.admin.with_credentials(cls._user, cls._PASSWORD)

    @classmethod
    def tearDownClass(cls):
        if not GITHUB_TOKEN:
            return
        try:
            cls.admin._run('user', 'remove', '--force', cls._user)
        except Exception:
            pass

    def test_01_gh_auth_configured_after_credentials_ready(self):
        if not GITHUB_TOKEN:
            self.skip('DOCKSIDE_TEST_GITHUB_TOKEN not set')

        name = self._sfx(self._BASE_CONTAINER)
        self.register_cleanup(name)
        result = self._client.create(profile=self.test_profile_alpine, name=name)
        self.assert_true(result is not None)
        self.wait_running(self._client, name, timeout=60)

        script = (
            'printf "credentials_ready=%s\\n" '
            '"$(test -f /tmp/dockside/.credentials-ready && echo 1 || echo 0)"; '
            'printf "gh_hosts=%s\\n" '
            '"$(test -f ~/.config/gh/hosts.yml && echo 1 || echo 0)"'
        )

        def _check():
            try:
                result = run_in_devtainer(
                    self._client,
                    name,
                    ['sh', '-c', script],
                    private_key_path=_DEV1_KEY,
                    preferred=('docker' if self.test_mode in ('local', 'harness') else 'ssh'),
                    system_bin_dir=self.test_system_bin_dir,
                    run_as_user='dockside',
                )
            except CapabilityUnavailable as exc:
                self.skip(str(exc))
            if result.returncode != 0:
                return False
            out = {}
            for line in result.stdout.splitlines():
                if '=' in line:
                    key, value = line.split('=', 1)
                    out[key.strip()] = value.strip()
            return out if out.get('credentials_ready') == '1' else False

        state = self.wait_until(
            _check, timeout=90, interval=1,
            timeout_msg='.credentials-ready never appeared',
        )
        self.assert_equal(
            state.get('gh_hosts'), '1',
            'gh was not authenticated (~/.config/gh/hosts.yml missing) once credentials-ready appeared',
        )
