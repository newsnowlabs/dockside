"""
14_hooks.py — Profile-declared hooks (docs/extensions/lifecycle-hooks.md)

Coverage:
  - a profile's `hooks."lifecycle:launch"` script is auto-invoked once, after
    launch-time git/ssh/gh setup completes, without any explicit CLI call
  - `dockside hook run <devtainer> "lifecycle:launch"` re-invokes it synchronously
    and reports success, but only when the profile lists it in `manualHooks` -
    manual runnability of a lifecycle hook is opt-in, not automatic
  - a failing hook script surfaces as both a `.hook-failed.<name>` sentinel inside
    the devtainer and a non-zero/APIError result from `dockside hook run`
  - a profile with no matching hook configured is rejected cleanly (no docker exec
    attempted), including for a malformed/adversarial hook name
  - a manual invoke racing the automatic one completes cleanly either way
    (success or a clean "busy" report), never hangs or crashes
  - a profile-declared custom hook (any name not in the reserved 'lifecycle:*' set)
    is always manually invocable, needs no `manualHooks` entry, and dispatches
    independently of 'lifecycle:launch' (separate sentinel/lock state)
  - hook-naming edge cases: a bare `"launch"` key (no namespace) is schema-valid
    but inert - nothing auto-invokes it, it's just an ordinary custom hook; a
    reserved-but-unimplemented lifecycle name (`"lifecycle:stop"`) is schema-valid
    and may even be listed in `manualHooks`, but dispatch still rejects running it
    as "not yet implemented" regardless
  - `dockside hook run` requires an explicit hook-name argument (no default)
  - HookWithGitUrlTests: a gitURLs profile whose ref-bearing option is
    deliberately not named 'ref' (so launch.sh's built-in checkout_git_ref()
    no-ops) has its "lifecycle:launch" hook auto-invoked after create_git_repo()'s
    synchronous clone completes, and correctly switches the already-cloned repo to
    a requested branch or PR (docs/extensions/lifecycle-hooks.md pattern D)
"""

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError, CapabilityUnavailable
sys.path.insert(0, os.path.dirname(__file__))
from _ssh_test_common import _DEV1_KEY, run_in_devtainer


class HooksTests(TestCase):
    """Test the profile-declared hook mechanism: auto-invoke, manual re-invoke
    (gated by `manualHooks`), failure surfacing, and custom-hook independence."""

    def _inspect(self, name, hook_name='lifecycle:launch', log_path='/tmp/hook-runs.log'):
        # Sentinel filenames are scoped by hook name (see launch.sh's run_hook()) -
        # the raw name is embedded directly, safe because reserved 'lifecycle:*'
        # names and custom slugs can never collide (colons are forbidden in a
        # custom name's syntax).
        script = (
            f'printf "hook_ready=%s\\n" "$(test -f /tmp/dockside/.hook-ready.{hook_name} && echo 1 || echo 0)"; '
            f'printf "hook_failed=%s\\n" "$(test -f /tmp/dockside/.hook-failed.{hook_name} && echo 1 || echo 0)"; '
            f'printf "log=%s\\n" "$(cat {log_path} 2>/dev/null | tr \'\\n\' \'|\')"'
        )
        try:
            result = run_in_devtainer(
                self.dev1,
                name,
                ['sh', '-c', script],
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

    def _wait_hook_settled(self, name, hook_name='lifecycle:launch', log_path='/tmp/hook-runs.log', timeout=60):
        """Wait until the given hook has finished (ready or failed) for this
        devtainer, and return the final inspected state."""
        state = {}

        def _check():
            nonlocal state
            state = self._inspect(name, hook_name=hook_name, log_path=log_path)
            return state if (state.get('hook_ready') == '1' or state.get('hook_failed') == '1') else False

        return self.wait_until(
            _check, timeout=timeout, interval=1,
            timeout_msg=f'hook {hook_name!r} for {name!r} did not settle (.hook-ready/.hook-failed never appeared)',
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
        # would itself fail the test (no try/except — success is required). This
        # profile lists 'lifecycle:launch' in manualHooks, so it's allowed. The
        # literal colon in the hook name also doubles as this suite's proof that
        # it survives CLI -> HTTP -> server unmangled (percent-encoded as %3A by
        # the CLI's _encode_params, decoded via App.pm's split_args/uri_unescape) -
        # if it didn't round-trip correctly, the server would see a different
        # string and reject with "No hook ... configured" instead of succeeding.
        self.dev1.hook_run(name, 'lifecycle:launch')

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

        self.assert_api_error(lambda: self.dev1.hook_run(name, 'lifecycle:launch'))

    def test_04_no_hook_configured(self):
        name = self._sfx('inttest-hook-none')
        self.register_cleanup(name)
        result = self.dev1.create(profile=self.test_profile_alpine, name=name)
        self.assert_true(result is not None)
        self.wait_running(self.dev1, name, timeout=60)

        self.assert_api_error(lambda: self.dev1.hook_run(name, 'lifecycle:launch'))

    def test_05_concurrent_invoke_does_not_hang(self):
        name = self._sfx('inttest-hook-race')
        self._create_hook_container(name, marker='race')
        # Race a manual invoke against the auto-invoke triggered by launch itself.
        # Whichever wins, this must complete cleanly - success, or a clean "busy"/
        # failure APIError - rather than hang or raise anything unexpected. Timing
        # is inherently non-deterministic here, so this only asserts "did not hang
        # or crash", not a specific outcome.
        try:
            self.dev1.hook_run(name, 'lifecycle:launch', timeout=30)
        except APIError:
            pass

    def test_06_custom_hook_independent_of_launch(self):
        # test_profile_hook (this class's shared fixture) also declares a second,
        # custom-named hook, 'update', purely to exercise the generalized
        # custom-hook path: no manualHooks entry needed (custom names are always
        # manually invocable), independent sentinel/lock state from
        # 'lifecycle:launch', and no auto-invoke of its own.
        name = self._sfx('inttest-hook-custom')
        self._create_hook_container(name, marker='auto1')

        # 'lifecycle:launch' auto-invokes at launch; 'update' does not - assert its
        # sentinel is entirely absent before we ever call it.
        pre_state = self._inspect(name, hook_name='update', log_path='/tmp/update-hook-runs.log')
        self.assert_equal(pre_state.get('hook_ready'), '0', f'update hook should not auto-invoke; state={pre_state!r}')
        self.assert_equal(pre_state.get('hook_failed'), '0')

        # Manually invoke the custom hook; no APIError expected even though this
        # profile's manualHooks only lists 'lifecycle:launch' - custom names never
        # need to be listed there.
        self.dev1.hook_run(name, 'update')

        update_state = self._inspect(name, hook_name='update', log_path='/tmp/update-hook-runs.log')
        self.assert_equal(update_state.get('hook_ready'), '1', f'expected update hook to succeed; state={update_state!r}')
        self.assert_in('ran:update:0', self._log_lines(update_state))

        # 'lifecycle:launch's own sentinel/log is untouched by the 'update' call -
        # proves independent lock/sentinel scoping by name.
        launch_state = self._inspect(name)
        self.assert_equal(launch_state.get('hook_ready'), '1')
        self.assert_in('ran:auto1:0', self._log_lines(launch_state))
        self.assert_not_in('ran:auto1:1', self._log_lines(launch_state))

    def test_07_bare_launch_key_is_inert_but_manually_runnable(self):
        # test_profile_hook_edge_case declares plain "launch" (no 'lifecycle:'
        # namespace) as an ordinary custom hook - schema-valid (any slug is), but
        # nothing ever auto-invokes it (only 'lifecycle:launch' does). Since
        # custom hooks are always manually invocable, it's still reachable via its
        # bare name with no manualHooks entry.
        name = self._sfx('inttest-hook-edge-bare')
        self.register_cleanup(name)
        result = self.dev1.create(profile=self.test_profile_hook_edge_case, name=name)
        self.assert_true(result is not None)
        self.wait_running(self.dev1, name, timeout=90)

        # Give the (fast, no-op) real 'lifecycle:launch' auto-invoke path a moment
        # to have run (this profile doesn't declare it, so nothing should appear),
        # then confirm the bare "launch" custom hook never fired on its own.
        pre = run_in_devtainer(
            self.dev1, name, ['sh', '-c', 'cat /tmp/bare-launch-hook-runs.log 2>/dev/null'],
            private_key_path=_DEV1_KEY,
            preferred=('docker' if self.test_mode in ('local', 'harness') else 'ssh'),
            system_bin_dir=self.test_system_bin_dir, run_as_user='dockside',
        )
        self.assert_equal(pre.stdout.strip(), '', 'bare "launch" custom hook must never auto-invoke')

        # Manual invoke by its bare custom name succeeds with no APIError.
        self.dev1.hook_run(name, 'launch')

        post = run_in_devtainer(
            self.dev1, name, ['sh', '-c', 'cat /tmp/bare-launch-hook-runs.log 2>/dev/null'],
            private_key_path=_DEV1_KEY,
            preferred=('docker' if self.test_mode in ('local', 'harness') else 'ssh'),
            system_bin_dir=self.test_system_bin_dir, run_as_user='dockside',
        )
        self.assert_equal(post.stdout.strip(), 'ran')

    def test_08_manual_invoke_requires_manualHooks_opt_in(self):
        # test_profile_hook_edge_case also declares "lifecycle:launch" itself, but
        # deliberately does NOT list it in manualHooks. Auto-invoke doesn't consult
        # manualHooks at all, so it fires fine at launch; manual re-invoke is
        # rejected, proving manual runnability of a lifecycle hook is opt-in, not
        # automatic - the core behavior this design change exists for.
        name = self._sfx('inttest-hook-edge-noopt')
        self.register_cleanup(name)
        result = self.dev1.create(profile=self.test_profile_hook_edge_case, name=name)
        self.assert_true(result is not None)
        self.wait_running(self.dev1, name, timeout=90)

        state = self._wait_hook_settled(name, hook_name='lifecycle:launch', log_path='/tmp/edge-launch-hook-runs.log')
        self.assert_equal(state.get('hook_ready'), '1', f'expected auto-invoke to succeed; state={state!r}')

        self.assert_api_error(lambda: self.dev1.hook_run(name, 'lifecycle:launch'))

    def test_09_reserved_unimplemented_rejected_even_if_in_manualHooks(self):
        # test_profile_hook_edge_case declares "lifecycle:stop" and lists it in
        # manualHooks - schema-valid, forward-compatible - but run_hook_sync still
        # rejects running it as "not yet implemented", proving that gate is
        # checked independently of, and before, the manualHooks gate.
        name = self._sfx('inttest-hook-edge-reserved')
        self.register_cleanup(name)
        result = self.dev1.create(profile=self.test_profile_hook_edge_case, name=name)
        self.assert_true(result is not None)
        self.wait_running(self.dev1, name, timeout=90)

        self.assert_api_error(lambda: self.dev1.hook_run(name, 'lifecycle:stop'))

    def test_10_cli_requires_hook_name_argument(self):
        # Omitting the HOOK positional is an argparse-level usage error - the CLI
        # never even attempts an HTTP round-trip. Any devtainer name works here,
        # real or not, since argument parsing happens before any API call.
        self.assert_api_error(lambda: self.dev1._run_mutating('hook', 'run', 'nonexistent-devtainer'))

    def test_11_adversarial_malformed_hook_name_rejected_cleanly(self):
        # The CLI does no client-side slug validation of the hook name - it
        # forwards whatever string it's given straight to the server, so calling
        # it via the normal CLI path here is equivalent to bypassing any CLI-side
        # safety net. A name containing '/', '..' or shell metacharacters must be
        # rejected as "no such hook configured" (it can never match a declared
        # key), never attempted as an exec.
        name = self._sfx('inttest-hook-adversarial')
        self._create_hook_container(name, marker='auto1')
        for malformed in ('../../etc/passwd', '/etc/passwd', '; rm -rf /tmp', 'lifecycle:launch; id'):
            self.assert_api_error(lambda m=malformed: self.dev1.hook_run(name, m))


class HookNamingValidationTests(TestCase):
    """Profile-level validation of hook names and `manualHooks`, independent of
    ever launching a devtainer - these are schema checks on `profile create`."""

    def _create_ad_hoc_profile(self, spec):
        name = self._sfx('inttest-hook-validation')
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump(spec, f)
            tmp_path = f.name
        try:
            self.admin._run_mutating('profile', 'create', name, '--from-json', tmp_path)
        finally:
            os.unlink(tmp_path)
        return name

    def _remove_profile(self, name):
        try:
            self.admin._run_mutating('profile', 'remove', '--force', name)
        except APIError:
            pass

    def _minimal_hook_spec(self, hooks, manual_hooks=None):
        spec = {
            "version": 4,
            "name": "Integration Test - Hook Validation (ad hoc)",
            "active": True,
            "routers": [
                {
                    "name": "www", "prefixes": ["www"], "domains": ["*"],
                    "https": {"protocol": "http", "port": 8080},
                    "auth": ["developer", "owner"],
                }
            ],
            "networks": ["*"],
            "images": ["alpine:latest"],
            "unixusers": ["dockside"],
            "hooks": hooks,
            "mounts": {"tmpfs": [], "bind": [], "volume": []},
            "command": ["/bin/sh", "-c", "sleep infinity"],
        }
        if manual_hooks is not None:
            spec['manualHooks'] = manual_hooks
        return spec

    def test_01_custom_hook_name_slug_rules(self):
        # Dashes accepted; leading/trailing/doubled dash, uppercase, and a
        # leading digit are all rejected.
        name = self._create_ad_hoc_profile(self._minimal_hook_spec({"repo-status": "/opt/x.sh"}))
        self._remove_profile(name)

        for bad in ('-leading', 'trailing-', 'double--dash', 'Uppercase', '1leading-digit'):
            self.assert_api_error(lambda b=bad: self._create_ad_hoc_profile(self._minimal_hook_spec({b: "/opt/x.sh"})))

    def test_02_unknown_colon_prefixed_name_rejected(self):
        self.assert_api_error(
            lambda: self._create_ad_hoc_profile(self._minimal_hook_spec({"foo:bar": "/opt/x.sh"}))
        )

    def test_03_manualHooks_rejects_custom_name(self):
        # A custom name is always manually invocable already - listing one in
        # manualHooks is meaningless and should be rejected as a likely mistake,
        # not silently ignored.
        self.assert_api_error(lambda: self._create_ad_hoc_profile(
            self._minimal_hook_spec({"repo-status": "/opt/x.sh"}, manual_hooks=["repo-status"])
        ))

    def test_04_manualHooks_rejects_undeclared_name(self):
        # Referential integrity: a manualHooks entry must correspond to a
        # declared hooks key.
        self.assert_api_error(lambda: self._create_ad_hoc_profile(
            self._minimal_hook_spec({"lifecycle:launch": "/opt/x.sh"}, manual_hooks=["lifecycle:stop"])
        ))

    def test_05_manualHooks_accepts_declared_lifecycle_name(self):
        name = self._create_ad_hoc_profile(self._minimal_hook_spec(
            {"lifecycle:launch": "/opt/x.sh"}, manual_hooks=["lifecycle:launch"]
        ))
        self._remove_profile(name)


GIT_URL = 'https://github.com/newsnowlabs/dockside.git'
EXPLICIT_BRANCH = 'gh-pages'
EXPLICIT_PR = '40'  # closed PR, same one used by 06_git_profile.py

_GIT_HOOK_INSPECT_SCRIPT = (
    'printf "hook_ready=%s\\n" "$(test -f /tmp/dockside/.hook-ready.lifecycle:launch && echo 1 || echo 0)"; '
    'printf "hook_failed=%s\\n" "$(test -f /tmp/dockside/.hook-failed.lifecycle:launch && echo 1 || echo 0)"; '
    'printf "result=%s\\n" "$(cat /tmp/hook-git-result 2>/dev/null)"'
)


class HookWithGitUrlTests(TestCase):
    """A gitURLs profile whose ref-bearing option is deliberately not named 'ref',
    so launch.sh's built-in checkout_git_ref() reads an empty DOCKSIDE_OPTION_REF
    and no-ops, leaving the switch to a hook instead - run against the repo
    create_git_repo() already cloned synchronously, in-line, before run_hook is
    ever invoked. No race between the clone and the hook's auto-invoke, by
    construction (see docs/extensions/lifecycle-hooks.md pattern D).

    Tests hook-specific mechanics only (auto-invoke firing after a real clone,
    env var delivery, .hook-ready reporting) - not the shared ref-disambiguation
    logic, already matrix-tested via pattern A in 06_git_profile.py.
    """

    def _inspect(self, name):
        try:
            result = run_in_devtainer(
                self.dev1,
                name,
                ['sh', '-c', _GIT_HOOK_INSPECT_SCRIPT],
                private_key_path=_DEV1_KEY,
                preferred=('docker' if self.test_mode in ('local', 'harness') else 'ssh'),
                system_bin_dir=self.test_system_bin_dir,
                run_as_user='dockside',
            )
        except CapabilityUnavailable as exc:
            self.skip(str(exc))
        if result.returncode != 0:
            return {}
        out = {}
        for line in result.stdout.splitlines():
            if '=' in line:
                key, value = line.split('=', 1)
                out[key.strip()] = value.strip()
        return out

    def _wait_settled(self, name, timeout=90):
        state = {}

        def _check():
            nonlocal state
            state = self._inspect(name)
            return state if (state.get('hook_ready') == '1' or state.get('hook_failed') == '1') else False

        return self.wait_until(
            _check, timeout=timeout, interval=1,
            timeout_msg=f'hook for {name!r} did not settle (.hook-ready/.hook-failed never appeared)',
        )

    def _create(self, name, test_ref):
        self.register_cleanup(name)
        result = self.dev1.create(
            profile=self.test_profile_hook_git,
            name=name,
            gitURL=GIT_URL,
            options=json.dumps({'test_ref': test_ref}),
        )
        self.assert_true(result is not None)
        self.wait_running(self.dev1, name, timeout=120)

    def test_01_hook_switches_branch_after_clone(self):
        name = self._sfx('inttest-hookgit-branch')
        self._create(name, EXPLICIT_BRANCH)
        state = self._wait_settled(name)
        self.assert_equal(state.get('hook_ready'), '1', f'expected hook to succeed; state={state!r}')
        self.assert_equal(state.get('result'), f'switched:{EXPLICIT_BRANCH}')

    def test_02_hook_switches_pr_after_clone(self):
        name = self._sfx('inttest-hookgit-pr')
        self._create(name, EXPLICIT_PR)
        state = self._wait_settled(name)
        self.assert_equal(state.get('hook_ready'), '1', f'expected hook to succeed; state={state!r}')
        # A PR checkout always lands in detached HEAD - `git rev-parse
        # --abbrev-ref HEAD` reports the literal string "HEAD" in that state,
        # not a branch name (verified by hand against the real repo).
        self.assert_equal(state.get('result'), 'switched:HEAD')
