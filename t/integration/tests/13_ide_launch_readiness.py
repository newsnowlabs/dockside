"""
13_ide_launch_readiness.py — IDE launch deferral for mountIDE:false devtainers.

Contract under test: for a profile with mountIDE:false, the docker-event-daemon
must defer the IDE exec (`docker exec ... /opt/dockside/launch.sh launch_ide`)
until the launcher path exists inside the container AND was written during the
current container run — a leftover launch.sh symlink from a previous run on the
same (persisted) container filesystem must not trigger a premature IDE launch.

No real Dockside image is needed: the daemon keys purely off the profile's
mountIDE:false and the launcher path from config (ide.command[0], i.e.
/opt/dockside/launch.sh). The fixture profile uses a stock alpine image whose
command emulates the Dockside-image entrypoint contract:

  1. print "ENTRYPOINT_START <epoch>" to stdout,
  2. sleep _REPOPULATE_SECS (simulating the rsync repopulation of the volume),
  3. write a stub /opt/dockside/bin/launch.sh, then symlink
     /opt/dockside/launch.sh -> bin/launch.sh (the readiness signal, last),
  4. print "REPOPULATED <epoch>", then sleep forever.

The stub launcher, when exec'd by the daemon, writes "IDE_LAUNCHED <epoch>" to
/proc/1/fd/1 (the container's main stdout), so every assertion here can be made
through `dockside logs` alone — fully CLI-driven, no docker exec, works in any
test mode.

Scenarios:
  - test_01 (fresh launch): launcher is absent at start; the daemon must wait
    for it and exec only after the entrypoint installs it.
  - test_02 (restart — the regression): after stop/start the PREVIOUS run's
    launch.sh is already present while the entrypoint is still sleeping.
    Without the mtime staleness check the daemon execs the stale launcher
    within ~1-2s of start (its readiness poll is 1s); with it, the exec must
    land only after the entrypoint refreshes the launcher ~_REPOPULATE_SECS
    later. The ~10s margin makes the assertion robust to whole-second
    timestamp granularity.
"""

import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))
from dockside_test import TestCase, APIError

# Must comfortably exceed the daemon's 1s readiness-poll interval (so a
# premature exec is unambiguous) and stay well inside its 60s launch window.
_REPOPULATE_SECS = 10

# NOTE: reservation command strings pass through the server's placeholder
# substitution, so this script must not contain any '{...}' sequences
# (shell "${VAR}" forms included). $(...) is safe: the single-quoted printf
# format below keeps it literal in the stub until the stub itself runs — but
# '%s' inside that printf FORMAT would be eaten as a conversion spec, hence
# the '%%s' escape for the stub's own date call.
_FIXTURE_SCRIPT = (
    'echo "ENTRYPOINT_START $(date +%s)"; '
    f'sleep {_REPOPULATE_SECS}; '
    'mkdir -p /opt/dockside/bin; '
    "printf '#!/bin/sh\\necho \"IDE_LAUNCHED $(date +%%s)\" > /proc/1/fd/1\\n' "
    '> /opt/dockside/bin/launch.sh; '
    'chmod 755 /opt/dockside/bin/launch.sh; '
    'ln -sf bin/launch.sh /opt/dockside/launch.sh; '
    'echo "REPOPULATED $(date +%s)"; '
    'exec sleep infinity'
)


def _prefix_image(image):
    """Mirror the harness's registry prefixing for unqualified image names."""
    registry = os.environ.get('DOCKSIDE_TEST_IMAGE_REGISTRY', '').strip().rstrip('/')
    if not registry:
        return image
    if '/' in image:
        first = image.split('/')[0]
        if '.' in first or ':' in first:
            return image
    return f'{registry}/{image}'


# unixusers is ["root"] because the daemon's IDE exec runs
# `docker exec -u <unixuser>` and root is the only user guaranteed to exist in
# a stock alpine image.
_IDE_LAUNCH_PROFILE = {
    "version": 2,
    "name": "Integration Test - IDE launch readiness",
    "active": True,
    "routers": [
        {
            "name": "www",
            "prefixes": ["www"],
            "domains": ["*"],
            "https": {"protocol": "http", "port": 8080},
            "auth": ["developer", "owner", "viewer", "user", "containerCookie", "public"],
        }
    ],
    "networks": ["*"],
    "images": [_prefix_image("alpine:latest")],
    "unixusers": ["root"],
    "mountIDE": False,
    "command": ["/bin/sh", "-c", _FIXTURE_SCRIPT],
}


def _marker_epochs(logs_text, marker):
    """Return all integer epochs logged for a marker, oldest first."""
    return [int(m) for m in re.findall(rf'^{marker} (\d+)\s*$', logs_text, re.MULTILINE)]


class IdeLaunchReadinessTests(TestCase):
    """mountIDE:false IDE-launch deferral and stale-launcher detection."""

    @classmethod
    def setUpClass(cls):
        cls.PROFILE = cls._sfx('inttest-idelaunch')
        cls.CONTAINER = cls._sfx('inttest-idelaunch-01')
        cls._profile_created = False

        try:
            cls.admin._run('profile', 'get', cls.PROFILE)
        except APIError:
            with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
                json.dump(_IDE_LAUNCH_PROFILE, f)
                tmp_path = f.name
            try:
                cls.admin._run('profile', 'create', cls.PROFILE, '--from-json', tmp_path)
            finally:
                os.unlink(tmp_path)
            cls._profile_created = True

    @classmethod
    def tearDownClass(cls):
        for fn in (
            lambda: cls.admin.stop(cls.CONTAINER, wait=False),
            lambda: cls.admin.remove(cls.CONTAINER, wait=False),
        ):
            try:
                fn()
            except Exception:
                pass
        if cls._profile_created:
            # The devtainer may still be counted against the profile while its
            # (wait=False) removal completes; retry briefly rather than leaking
            # the fixture profile.
            import time as _time
            deadline = _time.time() + 30
            while True:
                try:
                    cls.admin._run('profile', 'remove', cls.PROFILE, '--force')
                    break
                except Exception as exc:
                    if _time.time() >= deadline:
                        print(f'# WARNING: failed to remove profile {cls.PROFILE!r}: {exc}',
                              file=sys.stderr)
                        break
                    _time.sleep(2)

    # ── helpers ────────────────────────────────────────────────────────────────

    def _logs(self):
        return self.admin._run_text('logs', self.CONTAINER)

    def _wait_markers(self, marker, count, timeout, context):
        """Poll logs until `marker` has appeared `count` times; return epochs."""
        return self.wait_until(
            lambda: (lambda e: e if len(e) >= count else None)(
                _marker_epochs(self._logs(), marker)),
            timeout=timeout,
            interval=1,
            timeout_msg=f'{context}: {marker} #{count} not seen in logs',
        )

    def _ensure_container_running(self):
        try:
            data = self.admin.get_container(self.CONTAINER)
        except APIError:
            self.admin.create(profile=self.PROFILE, name=self.CONTAINER)
            data = self.admin.get_container(self.CONTAINER)
        if data.get('status') != 1:
            self.admin.start(self.CONTAINER, wait=True, timeout=120)
        self.wait_until(
            lambda: self.admin.get_container(self.CONTAINER).get('status') == 1,
            timeout=60,
            timeout_msg=f'{self.CONTAINER!r} did not reach running state',
        )

    # ── Scenario A: fresh launch ───────────────────────────────────────────────

    def test_01_fresh_launch_defers_until_launcher_ready(self):
        """On first launch the IDE exec waits for the launcher to be installed."""
        self._ensure_container_running()

        repopulated = self._wait_markers(
            'REPOPULATED', 1, _REPOPULATE_SECS + 30, 'fresh launch')
        launched = self._wait_markers(
            'IDE_LAUNCHED', 1, 30, 'fresh launch')

        self.assert_true(
            launched[0] >= repopulated[0],
            f'IDE launcher exec\'d at {launched[0]}, before the entrypoint '
            f'finished installing it at {repopulated[0]}'
        )

    # ── Scenario B: restart with leftover launcher (the regression) ───────────

    def test_02_restart_ignores_stale_launcher(self):
        """After stop/start, the previous run's launch.sh must not trigger a
        premature IDE exec while the entrypoint is still repopulating."""
        self._ensure_container_running()
        # Ensure run 1's markers are complete before restarting, so run 2's
        # markers are unambiguously the second occurrences.
        self._wait_markers('REPOPULATED', 1, _REPOPULATE_SECS + 30, 'pre-restart')
        self._wait_markers('IDE_LAUNCHED', 1, 30, 'pre-restart')

        self.admin.stop(self.CONTAINER, wait=True, timeout=60)
        self.admin.start(self.CONTAINER, wait=True, timeout=120)

        starts = self._wait_markers(
            'ENTRYPOINT_START', 2, 60, 'restart')
        repopulated = self._wait_markers(
            'REPOPULATED', 2, _REPOPULATE_SECS + 60, 'restart')
        launched = self._wait_markers(
            'IDE_LAUNCHED', 2, 30, 'restart')

        # The stale launch.sh from run 1 existed for the whole of run 2's
        # repopulation window; a premature exec would land within ~1-2s of
        # ENTRYPOINT_START, ~_REPOPULATE_SECS before REPOPULATED.
        self.assert_true(
            launched[1] >= repopulated[1],
            f'stale launcher exec\'d at {launched[1]}, before run 2 '
            f'reinstalled it at {repopulated[1]} '
            f'(run 2 started at {starts[1]}) — mtime staleness check failed'
        )
        self.assert_true(
            launched[1] >= starts[1] + _REPOPULATE_SECS - 1,
            f'IDE exec at {launched[1]} landed only '
            f'{launched[1] - starts[1]}s after run 2 start; expected >= '
            f'{_REPOPULATE_SECS - 1}s (entrypoint repopulation delay)'
        )
