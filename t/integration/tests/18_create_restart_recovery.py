"""
18_create_restart_recovery.py — app-server restart recovery and fresh-create fail-closed
behaviour for create().

CreateRestartRecoveryTests coverage (requires can_restart_services() ==
True / DOCKSIDE_TEST_ALLOW_SERVICE_RESTART=1 - skipped entirely otherwise, mirroring
16_ded_restart_recovery.py's own reasoning exactly - see its docstring, the same
mountIDE:false/sudo/s6 access requirement applies here):
  - restarting app-server (`sudo s6-svc -t`, a genuinely non-graceful signal - standing in for
    a real crash/OOM kill; see docs/adr/0007-create-restart-recovery.md's "Decision" section
    on what that signal actually does to Mojo::Server::Prefork, and on why the documented
    day-to-day `-r` command is deliberately not used here) while a devtainer's create() chain
    is still genuinely in flight (createStatus.stage non-terminal, with real progress recorded
    - not "started a moment ago") does not strand it forever: each worker's own reconcile pass
    (Reservation->reconcile_one, gated by a per-reservation lock rather than a single
    process-wide one - see that ADR's "Decision" section) picks it back up, and it eventually
    reaches a terminal createStatus.stage ('done'), with the container actually running - not
    just "the process didn't crash".
  - the same under N concurrent in-flight creates at once, exercising the per-reservation locks
    under real concurrent load.
  - a graceful restart draining an in-flight create instead of abandoning it to the reconciler.

Deliberately removes a real Docker image before each of the above (a genuine, low-level
`docker rmi`, not a CLI action - permitted under CLAUDE.md's t/integration hard rules, point 5,
the same allowance create_and_attach_test_network's own direct `docker network` calls already
rely on) to force a real, multi-second pull window every run - without this, a second/subsequent
run would find the image already cached and race an effectively-instant create, making the
restart timing unreliable rather than deterministic.

CreateNameCollisionTests coverage (no restart, no special permission needed - the ordinary
create() path's own fail-closed behaviour, docs/adr/0007-create-restart-recovery.md's
"Decision" section, mechanism 3):
  - a fresh create() against a container already holding its exact name fails closed rather
    than adopting it.
  - a reservation named after an unrelated container's hex id prefix creates and adopts only
    its own container, never resolving the name as an id-prefix match against the other.
"""

import os
import sys
import json
import subprocess
import tempfile
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError, restart_app_server, restart_app_server_graceful

# app-server's own log. Read directly (it is world-readable) rather than through the CLI, for
# the one thing the CLI cannot show: whether a graceful restart drained an in-flight create in
# the worker that owned it, or left it to the startup sweep afterwards - both end 'done', so the
# drain's own log line is the only observable difference (see test_03). The same low-level-helper
# allowance (CLAUDE.md t/integration rule 5) that _ensure_image_absent's docker calls rely on.
_APP_SERVER_LOG = '/var/log/dockside/dockside.log'

# A real, moderately-sized image, deliberately made absent before each test (see
# _ensure_image_absent) - large enough that a genuine pull takes several real seconds, giving
# comfortable margin to observe createStatus.stage=='pulling' with actual layer progress and
# issue the restart while the chain is still genuinely in flight, rather than racing an
# already-cached image's near-instant create. A killed pull aborts server-side, so recovery
# here has to redo the whole pull, not resume one already-abandoned mid-stream.
PULL_IMAGE = 'node:22'


def _create_status(container_data):
    return (container_data or {}).get('createStatus') or {}


def _wait_create_settled(test, name, timeout=120):
    """Shared by every TestCase below (both restart-driven and not) - polls until $name's
    createStatus.stage reaches a terminal value. `test` is the calling TestCase instance,
    passed explicitly since this is a plain function, not a method, on none of them."""
    def _check():
        try:
            data = test.admin.get_container(name)
        except APIError:
            return False
        stage = _create_status(data).get('stage')
        return data if stage in ('done', 'failed') else False

    return test.wait_until(
        _check, timeout=timeout, interval=1,
        timeout_msg=f'{name!r} createStatus.stage did not reach a terminal state',
    )


def _assert_recovered(test, name, data):
    stage = _create_status(data).get('stage')
    test.assert_equal(stage, 'done', f'{name!r} createStatus never reached done: {data.get("createStatus")!r}')
    test.assert_equal(data.get('status'), 1, f'{name!r} did not end up running: {data!r}')


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
        if hasattr(self, '_profile'):
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

    def test_01_single_create_restart_mid_pull(self):
        """Isolates the mechanism: one create, interrupted deterministically mid-pull -
        polled until real layer progress is observed, not a guessed sleep."""
        self._ensure_image_absent()
        name = self._sfx('inttest-createrestart-solo')
        self.register_cleanup(name)
        self.admin.create(profile=self._profile, name=name, no_wait=True)

        self._wait_pulling_with_progress(name)

        restart_app_server()

        data = _wait_create_settled(self, name)
        _assert_recovered(self, name, data)

    def test_02_concurrent_creates_restart_mid_flight(self):
        """The condition the atomic reconciliation claim actually exists for: several
        creates in flight at once, so the periodic reconciler's own independent-per-worker
        firing has more than one stuck reservation to race over, not just one with nothing
        to contend for."""
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
            data = _wait_create_settled(self, name)
            _assert_recovered(self, name, data)

    def _log_contains_since(self, offset, needle, timeout=120):
        """Poll app-server's log, from byte `offset`, for `needle`. The drain line is written as
        the worker exits, which under a graceful shutdown trails the restart by however long the
        pull takes to finish - so this polls rather than reading once.

        Rotation-aware: logrotate can rotate this file mid-test (size-triggered, ~every 60s), which
        would leave `offset` pointing past the end of the new, smaller file. When the file is now
        smaller than `offset`, read it whole from the start instead - safe here because the needle
        (the graceful drain line) is written by nothing else in this module (test_01/02 use a
        non-graceful `-t` that never drains), so a match cannot be some earlier line before the
        offset."""
        def _check():
            try:
                size = os.path.getsize(_APP_SERVER_LOG)
                with open(_APP_SERVER_LOG, 'r', errors='replace') as fh:
                    fh.seek(0 if size < offset else offset)
                    return needle in fh.read()
            except OSError:
                return False

        try:
            return self.wait_until(_check, timeout=timeout, interval=1, timeout_msg='not found')
        except AssertionError:
            return False

    def test_03_graceful_restart_drains_in_flight_create(self):
        """A graceful restart (`s6-svc -r` -> SIGQUIT, app-server's own down-signal) mid-pull must
        DRAIN the in-flight create() in the worker that owns it - ADR-0007 mechanism 3 - not
        abandon it for the startup sweep to recover afterwards. Both paths leave the reservation
        'done', so the drain is asserted via the exit handler's own log line, the only observable
        difference, alongside the terminal state. This is the path restart_app_server's `-t`
        deliberately does not exercise, and which shipped inert until it was fixed."""
        self._ensure_image_absent()
        name = self._sfx('inttest-createrestart-graceful')
        self.register_cleanup(name)
        self.admin.create(profile=self._profile, name=name, no_wait=True)

        self._wait_pulling_with_progress(name)

        try:
            offset = os.path.getsize(_APP_SERVER_LOG)
        except OSError:
            offset = 0

        # SIGQUIT while the pull is genuinely in flight. This blocks until the manager exits,
        # which it only does once its workers have drained - so on return the drain has happened.
        restart_app_server_graceful()

        self.assert_true(
            self._log_contains_since(offset, 'drained every in-flight create chain'),
            "graceful restart did not drain the in-flight create(): no 'drained every in-flight "
            "create chain' line after the restart - mechanism 3 inert, or the drain hit its grace "
            "period",
        )

        data = _wait_create_settled(self, name)
        _assert_recovered(self, name, data)


class CreateNameCollisionTests(TestCase):
    """A fresh create() must never adopt a container it didn't create itself - docs/adr/
    0007-create-restart-recovery.md's "Decision" section, mechanism 3. Unlike
    CreateRestartRecoveryTests above, these exercise only the ordinary (non-recovery) create
    path: no restart, no special permission, no slow-pull profile - the shared alpine fixture
    is enough."""

    def _low_level_create(self, name=None):
        """Creates a container directly via `docker create` - not through the CLI/API - the
        one way to get a container Dockside had no part in creating, standing in for "an
        unrelated container" in each test below; there's no CLI command that could produce
        one, since Dockside's own create always tracks what it makes. This suite already
        reaches past the CLI the same way for networks and images
        (create_and_attach_test_network, _ensure_image_absent), but always for scaffolding
        around a container, never the container itself - this is the first place one is
        fabricated directly, extending that same allowance to a new resource type.

        Always given an identifiable name (`name`, or a random inttest-container-<hex> one),
        matching create_and_attach_test_network's own inttest-net-<hex> convention, rather than
        Docker's own random generator - the point being that a container this test's cleanup
        misses (its process killed before `finally` runs, a leak nothing here currently sweeps
        for automatically) is still recognisable as test debris rather than a real container.

        Returns the container's full 64-char id, as `docker create` itself prints to stdout."""
        container_name = name or f'inttest-container-{uuid.uuid4().hex[:8]}'
        args = ['docker', 'create', '--name', container_name, self.test_image_alpine, 'sleep', 'infinity']
        result = subprocess.run(args, capture_output=True, text=True, timeout=30, check=True)
        return result.stdout.strip()

    def _docker_inspect(self, container_id, go_format):
        result = subprocess.run(
            ['docker', 'inspect', container_id, '--format', go_format],
            capture_output=True, text=True, timeout=30, check=True,
        )
        return result.stdout.strip()

    def test_01_fresh_create_fails_closed_against_same_name_container(self):
        """A container already holding a fresh reservation's exact name is never adopted -
        the ordinary create path's own 409 handling fails the chain closed instead of looking
        the container up and adopting it, the way only a recovery re-entry is allowed to."""
        name = self._sfx('inttest-namecollision-exact')
        other_id = self._low_level_create(name=name)
        try:
            self.admin.create(profile=self.test_profile_alpine, name=name, no_wait=True)
            data = _wait_create_settled(self, name)

            self.assert_equal(
                _create_status(data).get('stage'), 'failed',
                f'{name!r} createStatus did not fail closed against a pre-existing container: '
                f'{data.get("createStatus")!r}',
            )
            self.assert_in(
                'already in use by a container this reservation does not own',
                _create_status(data).get('error') or '',
            )

            self.assert_equal(
                self._docker_inspect(name, '{{.State.Running}}'), 'false',
                f'pre-existing container {name!r} was started by the failed create',
            )
            labels = json.loads(self._docker_inspect(name, '{{json .Config.Labels}}') or 'null') or {}
            self.assert_not_in(
                'dev.dockside.reservation.id', labels,
                f'pre-existing container {name!r} was unexpectedly labelled by the failed create: {labels!r}',
            )
        finally:
            subprocess.run(['docker', 'rm', '-f', name], capture_output=True, text=True, timeout=30)
            try:
                self.admin.remove(name, wait=False)
            except APIError:
                pass

    def test_02_hex_prefix_name_never_resolves_by_id(self):
        """A reservation named after another container's hex id prefix must create and adopt
        only its own container, never resolve the name against the other by id-prefix match -
        the behaviour Docker's single-container GET endpoint has and the anchored
        collection-filter lookup this design uses instead does not share."""
        # Reservation names must start with a letter (Reservation::validate's own naming
        # regex); a docker id is random hex, so a leading digit is retried rather than trusted
        # on the first attempt - roughly 3 in 8 attempts already start with a-f.
        other_id = None
        for _ in range(20):
            candidate = self._low_level_create()
            if candidate[0] in 'abcdef':
                other_id = candidate
                break
            subprocess.run(['docker', 'rm', '-f', candidate], capture_output=True, text=True, timeout=30)
        if other_id is None:
            raise AssertionError('could not obtain a docker container id starting with a letter after 20 attempts')

        name = self._sfx(other_id[:12])
        self.register_cleanup(name)
        try:
            self.admin.create(profile=self.test_profile_alpine, name=name, no_wait=True)
            data = _wait_create_settled(self, name)
            _assert_recovered(self, name, data)

            own_id = data.get('containerId')
            self.assert_true(
                own_id and own_id != other_id[:len(own_id)],
                f'{name!r} adopted the unrelated container {other_id!r} instead of creating its own '
                f'(own containerId: {own_id!r})',
            )

            labels = json.loads(self._docker_inspect(own_id, '{{json .Config.Labels}}') or 'null') or {}
            self.assert_equal(
                labels.get('dev.dockside.reservation.id'), data.get('id'),
                f'{name!r}\'s own container is missing or has the wrong reservation id label: {labels!r}',
            )

            self.assert_equal(
                self._docker_inspect(other_id, '{{.State.Running}}'), 'false',
                f'unrelated container {other_id!r} was started by an unrelated create',
            )
        finally:
            subprocess.run(['docker', 'rm', '-f', other_id], capture_output=True, text=True, timeout=30)
