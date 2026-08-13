"""
18_create_restart_recovery.py — app-server restart recovery mid-create().

Coverage:
  - restarting app-server (`sudo s6-svc -t`, the exact non-graceful command this repo's
    own restart matrix uses for every service, including app-server - see
    docs/plans/create-restart-recovery-plan.md's own "Confirmed live" finding on what that
    signal actually does to Mojo::Server::Prefork) while a devtainer's create() chain is
    still genuinely in flight (createStatus.stage non-terminal, with real progress recorded
    - not "started a moment ago") does not strand it forever: the startup reconcile sweep
    and per-worker periodic reconciler (Reservation::reconcile_if_claimed) pick it back up
    and it eventually reaches a terminal createStatus.stage ('done'), with the container
    actually running - not just "the process didn't crash".
  - the same under N concurrent in-flight creates at once, exercising the atomic
    per-reservation reconciliation claim (Reservation::Mutate::create_reconcile_claim) under
    real concurrent load - the condition a naive (unlocked) version of this mechanism would
    have raced under, per that doc's own "Revision 2" note.

Requires can_restart_services() == True (DOCKSIDE_TEST_ALLOW_SERVICE_RESTART=1) - skipped
entirely otherwise, mirroring 16_ded_restart_recovery.py's own reasoning exactly (see its
docstring - the same mountIDE:false/sudo/s6 access requirement applies here).

Deliberately removes a real Docker image before each test (a genuine, low-level `docker rmi`,
not a CLI action - permitted under CLAUDE.md's t/integration hard rules, point 5, the same
allowance create_and_attach_test_network's own direct `docker network` calls already rely on)
to force a real, multi-second pull window every run - without this, a second/subsequent run
would find the image already cached and race an effectively-instant create, making the restart
timing unreliable rather than deterministic.

STATUS: not yet run - see the session's own before/after verification notes for how this was
proven to actually catch the regression it targets, ahead of the first real run against a live
instance.
"""

import os
import sys
import json
import subprocess
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError, restart_app_server

# A real, moderately-sized image, deliberately made absent before each test (see
# _ensure_image_absent) - large enough that a genuine pull takes several real seconds, giving
# comfortable margin to observe createStatus.stage=='pulling' with actual layer progress and
# issue the restart while the chain is still genuinely in flight, rather than racing an
# already-cached image's near-instant create. Same image this session's own live verification
# of create-restart-recovery-plan.md's Open Questions #1 already used for the identical
# purpose (confirmed there: a killed pull aborts server-side, so recovery here really does
# have to redo the whole pull, not just resume one already-abandoned mid-stream).
PULL_IMAGE = 'node:22'


def _create_status(container_data):
    return (container_data or {}).get('createStatus') or {}


class CreateRestartRecoveryTests(TestCase):
    """app-server restart while a create() is still mid-flight must not strand the
    reservation - the startup sweep / periodic reconciler must pick it back up to a
    terminal createStatus.stage."""

    def setUp(self):
        super().setUp()
        if not self.can_restart_services():
            self.skip(
                'service restart not enabled for this run (set '
                'DOCKSIDE_TEST_ALLOW_SERVICE_RESTART=1 in a mountIDE:false '
                'environment with sudo/s6 access to restart app-server - see '
                "CLAUDE.md's testing-capability matrix)"
            )
        self._profile = self._create_pull_profile()

    def tearDown(self):
        self._remove_profile(self._profile)
        super().tearDown()

    # The shared fixture profiles' own images lists are all narrow (e.g. the alpine
    # fixture's own images: ['alpine:latest']) - none permit PULL_IMAGE, so a throwaway
    # profile of our own is needed, same pattern 14_hooks.py's
    # HookNamingValidationTests._create_ad_hoc_profile already establishes, shaped like
    # run_tests_main.py's own _DEBIAN_PROFILE (PULL_IMAGE is Debian-based).
    def _create_pull_profile(self):
        name = self._sfx('inttest-createrestart-profile')
        spec = {
            "version": 2,
            "name": "Integration Test - Create Restart Recovery",
            "active": True,
            "routers": [{
                "name": "www", "prefixes": ["www"], "domains": ["*"],
                "https": {"protocol": "http", "port": 8080},
                "auth": ["developer", "owner", "viewer", "user", "containerCookie", "public"],
            }],
            "networks": ["*"],
            "images": [PULL_IMAGE],
            "unixusers": ["dockside"],
            "mounts": {"tmpfs": [{"dst": "/home/{ideUser}/.ssh", "tmpfs-size": "1M"}], "bind": [], "volume": []},
            "lxcfs": True,
            "dockerArgs": ["--pids-limit=4000"],
            "command": ["sleep", "infinity"],
        }
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

    def _ensure_image_absent(self):
        subprocess.run(['docker', 'rmi', '-f', PULL_IMAGE], capture_output=True, text=True, timeout=30)

    def _wait_pulling_with_progress(self, name, timeout=20):
        """Poll until createStatus.stage=='pulling' *and* real per-layer progress has been
        recorded - not just the very first instant after create() returns, which would race
        the restart against a chain that hasn't actually done anything Docker-side yet."""
        def _check():
            try:
                data = self.admin.get_container(name)
            except APIError:
                return False
            cs = _create_status(data)
            return data if cs.get('stage') == 'pulling' and cs.get('layers') else False

        return self.wait_until(
            _check, timeout=timeout, interval=0.3,
            timeout_msg=f'{name!r} createStatus never reached pulling with real progress',
        )

    def _wait_create_settled(self, name, timeout=120):
        def _check():
            try:
                data = self.admin.get_container(name)
            except APIError:
                return False
            stage = _create_status(data).get('stage')
            return data if stage in ('done', 'failed') else False

        return self.wait_until(
            _check, timeout=timeout, interval=1,
            timeout_msg=f'{name!r} createStatus.stage did not reach a terminal state',
        )

    def _assert_recovered(self, name, data):
        stage = _create_status(data).get('stage')
        self.assert_equal(stage, 'done', f'{name!r} createStatus never reached done: {data.get("createStatus")!r}')
        self.assert_equal(data.get('status'), 1, f'{name!r} did not end up running: {data!r}')

    def test_01_single_create_restart_mid_pull(self):
        """Isolates the mechanism: one create, interrupted deterministically mid-pull -
        polled until real layer progress is observed, not a guessed sleep."""
        self._ensure_image_absent()
        name = self._sfx('inttest-createrestart-solo')
        self.register_cleanup(name)
        self.admin.create(profile=self._profile, name=name, no_wait=True)

        self._wait_pulling_with_progress(name)

        restart_app_server()

        data = self._wait_create_settled(name)
        self._assert_recovered(name, data)

    def test_02_concurrent_creates_restart_mid_flight(self):
        """The condition the atomic reconciliation claim actually exists for: several
        creates in flight at once, so the periodic reconciler's own independent-per-worker
        firing (confirmed live - see create-restart-recovery-plan.md's Open Questions #4)
        has more than one stuck reservation to race over, not just one with nothing to
        contend for."""
        self._ensure_image_absent()
        n = 4
        names = [self._sfx(f'inttest-createrestart-{i}') for i in range(n)]
        for name in names:
            self.register_cleanup(name)
            self.admin.create(profile=self._profile, name=name, no_wait=True)

        # Wait for at least one to be genuinely mid-pull before restarting - "at least
        # one", not "every one", since N concurrent creates don't progress in lockstep.
        def _any_pulling():
            for name in names:
                try:
                    data = self.admin.get_container(name)
                except APIError:
                    continue
                cs = _create_status(data)
                if cs.get('stage') == 'pulling' and cs.get('layers'):
                    return True
            return False

        self.wait_until(
            _any_pulling, timeout=20, interval=0.3,
            timeout_msg='no create reached pulling with real progress before timeout',
        )

        restart_app_server()

        for name in names:
            data = self._wait_create_settled(name)
            self._assert_recovered(name, data)
