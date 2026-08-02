"""
14_hooks.py — Profile-declared lifecycle hooks (docs/extensions/lifecycle-hooks.md)

Coverage:
  - a profile's `hooks.launch` script is auto-invoked once, after launch-time
    git/ssh/gh setup completes, without any explicit CLI call
  - `dockside hook run` re-invokes it synchronously and reports success
  - a failing hook script surfaces as both a `.hook-failed` sentinel inside the
    devtainer and a non-zero/APIError result from `dockside hook run`
  - a profile with no `hooks.launch` configured is rejected cleanly (no docker
    exec attempted)
  - a manual invoke racing the automatic one completes cleanly either way
    (success or a clean "busy" report), never hangs or crashes
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError, CapabilityUnavailable
sys.path.insert(0, os.path.dirname(__file__))
from _ssh_test_common import _DEV1_KEY, run_in_devtainer

_INSPECT_SCRIPT = (
    'printf "hook_ready=%s\\n" "$(test -f /tmp/dockside/.hook-ready && echo 1 || echo 0)"; '
    'printf "hook_failed=%s\\n" "$(test -f /tmp/dockside/.hook-failed && echo 1 || echo 0)"; '
    'printf "log=%s\\n" "$(cat /tmp/hook-runs.log 2>/dev/null | tr \'\\n\' \'|\')"'
)


class HooksTests(TestCase):
    """Test the profile-declared 'launch' hook mechanism."""

    def _inspect(self, name):
        try:
            result = run_in_devtainer(
                self.dev1,
                name,
                ['sh', '-c', _INSPECT_SCRIPT],
                private_key_path=_DEV1_KEY,
                preferred=('docker' if self.test_mode in ('local', 'harness') else 'ssh'),
                system_bin_dir=self.test_system_bin_dir,
                run_as_user='dockside',
            )
        except CapabilityUnavailable as exc:
            # A genuine capability gap (docker/ssh/key unavailable) is a legitimate
            # skip; any other failure while inspecting an already-running container
            # should propagate and fail rather than being silently skipped.
            self.skip(str(exc))
        if result.returncode != 0:
            return {}
        out = {}
        for line in result.stdout.splitlines():
            if '=' in line:
                key, value = line.split('=', 1)
                out[key.strip()] = value.strip()
        return out

    def _log_lines(self, state):
        return [line for line in state.get('log', '').split('|') if line]

    def _wait_hook_settled(self, name, timeout=60):
        """Wait until the auto-invoked hook has finished (ready or failed), and
        return the final inspected state."""
        state = {}

        def _check():
            nonlocal state
            state = self._inspect(name)
            return state if (state.get('hook_ready') == '1' or state.get('hook_failed') == '1') else False

        return self.wait_until(
            _check, timeout=timeout, interval=1,
            timeout_msg=f'hook for {name!r} did not settle (.hook-ready/.hook-failed never appeared)',
        )

    def _create_hook_container(self, name, **options):
        self.register_cleanup(name)
        result = self.dev1.create(
            profile=self.test_profile_hook,
            name=name,
            options=json.dumps(options),
        )
        self.assert_true(result is not None)
        self.wait_running(self.dev1, name, timeout=90)

    def test_01_auto_invoke_on_launch(self):
        name = self._sfx('inttest-hook-auto')
        self._create_hook_container(name, marker='auto1')
        state = self._wait_hook_settled(name)
        self.assert_equal(state.get('hook_ready'), '1', f'expected hook to succeed; state={state!r}')
        self.assert_equal(state.get('hook_failed'), '0')
        self.assert_in('ran:auto1:0', self._log_lines(state))

    def test_02_manual_reinvoke_via_cli(self):
        name = self._sfx('inttest-hook-manual')
        self._create_hook_container(name, marker='auto1')
        self._wait_hook_settled(name)

        # Re-invoke synchronously via the CLI; a non-zero/APIError result here
        # would itself fail the test (no try/except — success is required).
        self.dev1.hook_run(name)

        state = self._inspect(name)
        self.assert_equal(state.get('hook_ready'), '1')
        lines = self._log_lines(state)
        self.assert_in('ran:auto1:0', lines, f'missing auto-invoke run; log={lines!r}')
        self.assert_in('ran:auto1:1', lines, f'missing manual re-invoke run; log={lines!r}')

    def test_03_hook_failure_surfaces(self):
        name = self._sfx('inttest-hook-fail')
        self._create_hook_container(name, marker='failtest', fail='1')
        # Wait for the auto-invoked run to settle before driving a second, manual
        # invocation - otherwise a manual call could race the auto-invoke and see
        # "busy" (exit 3) instead of the failure (exit 1) this test means to check.
        state = self._wait_hook_settled(name)
        self.assert_equal(state.get('hook_failed'), '1', f'expected hook to fail; state={state!r}')
        self.assert_equal(state.get('hook_ready'), '0')

        self.assert_api_error(lambda: self.dev1.hook_run(name))

    def test_04_no_hook_configured(self):
        name = self._sfx('inttest-hook-none')
        self.register_cleanup(name)
        result = self.dev1.create(profile=self.test_profile_alpine, name=name)
        self.assert_true(result is not None)
        self.wait_running(self.dev1, name, timeout=60)

        self.assert_api_error(lambda: self.dev1.hook_run(name))

    def test_05_concurrent_invoke_does_not_hang(self):
        name = self._sfx('inttest-hook-race')
        self._create_hook_container(name, marker='race')
        # Race a manual invoke against the auto-invoke triggered by launch itself.
        # Whichever wins, this must complete cleanly - success, or a clean "busy"/
        # failure APIError - rather than hang or raise anything unexpected. Timing
        # is inherently non-deterministic here, so this only asserts "did not hang
        # or crash", not a specific outcome.
        try:
            self.dev1.hook_run(name, timeout=30)
        except APIError:
            pass
