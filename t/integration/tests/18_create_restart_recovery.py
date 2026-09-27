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
  - a graceful restart mid-pull returning promptly: the owning worker's drain abandons the pull,
    naming the reservation in its own log line, and the restarted workers' first pass carries
    the chain to a running container.

Deliberately removes a real Docker image before each of the above (a genuine, low-level
`docker rmi`, not a CLI action - permitted under CLAUDE.md's t/integration hard rules, point 5,
the same allowance create_and_attach_test_network's own direct `docker network` calls already
rely on) to force a real, multi-second pull window every run - without this, a second/subsequent
run would find the image already cached and race an effectively-instant create, making the
restart timing unreliable rather than deterministic.

CreatePullInterruptionTests coverage (same can_restart_services() opt-in: it rewrites the
instance config for its duration, so every Docker call app-server makes goes through a proxy of
the test's own, and restarts docker-event-daemon at teardown so the restored config reaches it
at once):
  - a pull whose connection to Docker is severed mid-stream, and one left silent past the
    transport's inactivity limit, are each unresolved at 'pulling' rather than failed: the
    record keeps its stage and its layers, gains createStatus.unresolved, and the worker that
    recorded it retries ~15s later, carrying the chain through to a running container.
Only app-server's own connection to Docker breaks - Docker, its event stream and every other
connection keep running, which is what app-server observes across a Docker restart. The break
is aimed at one connection by killing the one proxy child carrying it; see
t/integration/lib/docker_socket_proxy.py.

CreateNameCollisionTests coverage (no restart, no special permission needed - the ordinary
create() path's own fail-closed behaviour, docs/adr/0007-create-restart-recovery.md's
"Decision" section, mechanism 3):
  - a fresh create() against a container already holding its exact name fails closed rather
    than adopting it.
  - a reservation named after an unrelated container's hex id prefix creates and adopts only
    its own container, never resolving the name as an id-prefix match against the other.
  - a reservation name that is itself a bare 12- or 64-character hex string is rejected at
    validation, before any container is created - the same short/full ID shape Docker resolves
    a name against ahead of an ID prefix.
"""

import gzip
import os
import sys
import json
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

_LIB_DIR = os.path.join(os.path.dirname(__file__), '..', 'lib')
sys.path.insert(0, _LIB_DIR)

from dockside_test import (
    TestCase, APIError, restart_app_server, restart_app_server_graceful, restart_docker_event_daemon,
)

# app-server's own log. Read directly (it is world-readable) rather than through the CLI, for
# what the CLI cannot show: which worker did what to a chain across a restart - the owning
# worker's drain naming the reservation it abandons mid-pull (see test_03), or the recording
# worker's retry line - where the record alone ends 'done' either way. The same low-level-helper
# allowance (CLAUDE.md t/integration rule 5) that _ensure_image_absent's docker calls rely on.
_APP_SERVER_LOG = '/var/log/dockside/dockside.log'

# A real, moderately-sized image, deliberately made absent before each test (see
# _ensure_image_absent) - large enough that a genuine pull takes several real seconds, giving
# comfortable margin to observe createStatus.stage=='pulling' with actual layer progress and
# issue the restart while the chain is still genuinely in flight, rather than racing an
# already-cached image's near-instant create. A killed pull aborts server-side, so recovery
# here has to redo the whole pull, not resume one already-abandoned mid-stream.
PULL_IMAGE = 'node:22'

# The instance's own config, and the proxy CreatePullInterruptionTests points its `docker.socket`
# at for the duration of a test. app-server re-reads the config on every authenticated request
# and docker-event-daemon on its next container event, so redirecting Docker calls needs no
# service restart - the create request that follows the rewrite is already served through the
# proxy.
_DOCKSIDE_CONFIG = '/data/config/config.json'
_DEFAULT_DOCKER_SOCKET = '/var/run/docker.sock'
_DOCKER_SOCKET_PROXY = os.path.join(_LIB_DIR, 'docker_socket_proxy.py')


def _create_status(container_data):
    return (container_data or {}).get('createStatus') or {}


def _pid_alive(pid):
    """True while `pid` is a running or stopped process. A process that has exited is neither,
    whether reaped yet or not: a zombie is the reaper's business, not a process still holding a
    connection."""
    try:
        with open(f'/proc/{pid}/stat', encoding='utf-8') as fh:
            stat = fh.read()
    except OSError:
        return False
    # The state field follows the parenthesised command name, which may itself hold spaces.
    return stat.rpartition(')')[2].split()[0] != 'Z'


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


class _PullChainTests(TestCase):
    """Fixtures shared by the two classes below, each of which drives a create() through a real,
    multi-second image pull: the throwaway profile permitting PULL_IMAGE, the removal of that
    image, the wait for a pull with genuine progress behind it, the reader for app-server's own
    log, and the rewrite of the instance config a case makes to run the instance under a setting
    of its own for its duration.

    Holds no test_ methods, so the runner's class discovery - every TestCase subclass in the
    module - finds nothing to run here."""

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

    # ── Instance config rewriting, for a case that runs the instance under a setting of its own ──

    def _load_config(self):
        """Return the instance config as (raw bytes, parsed dict), or skip when this run cannot
        rewrite and restore it byte-for-byte."""
        if not os.access(_DOCKSIDE_CONFIG, os.W_OK):
            self.skip(
                f'{_DOCKSIDE_CONFIG} is not writable by this user, so the instance cannot be '
                'run under a setting of the test\'s own'
            )
        try:
            with open(_DOCKSIDE_CONFIG, 'rb') as fh:
                raw = fh.read()
            return raw, json.loads(raw.decode('utf-8'))
        except (OSError, UnicodeDecodeError, ValueError) as e:
            self.skip(f'{_DOCKSIDE_CONFIG} is not plain readable JSON ({e}), so it cannot be '
                      'rewritten and restored safely')

    def _write_config(self, raw):
        """Replace the config by writing a sibling temp file and renaming it over the original,
        preserving its mode. The rename is what makes the swap atomic for a concurrent reader:
        app-server re-reads this file on every authenticated request, so a reader either gets the
        whole old config or the whole new one, never a half-written one. The rename gives the
        file this user's own group, which no reader of it depends on - a torn read on a live
        instance costs more than the group does."""
        mode = os.stat(_DOCKSIDE_CONFIG).st_mode & 0o777
        fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(_DOCKSIDE_CONFIG),
                                        prefix='.config.json.')
        try:
            with os.fdopen(fd, 'wb') as fh:
                fh.write(raw)
            os.chmod(tmp_path, mode)
            os.replace(tmp_path, _DOCKSIDE_CONFIG)
        except BaseException:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

    def _log_contains_since(self, offset, needle, timeout=120):
        """Poll app-server's log, from byte `offset`, for `needle`. A line this is asked for can
        trail the event that provoked it by however long the pull takes to finish - so this polls
        rather than reading once.

        Rotation-aware: logrotate can rotate this file mid-test (size-triggered, checked every
        60s; the file is renamed, compressed to `.1.gz` and recreated empty), which leaves
        `offset` pointing past the end of the new, smaller file, and the needle in one of two
        places: after `offset` in the rotated predecessor, when it was written before the
        rotation, or anywhere in the new file, when after. When the file is now smaller than
        `offset`, both are read: the predecessor (`.1`, or `.1.gz` once compressed) from `offset`,
        and the new file whole. Reading the new file from the start is safe because every needle
        passed here names this test's own reservation id, which no earlier line can carry: the
        drain line naming the chain it abandons, or the retry line naming the reservation. A
        match therefore cannot be some unrelated earlier line before the offset."""
        def _read_from(path, start):
            opener = gzip.open if path.endswith('.gz') else open
            with opener(path, 'rb') as fh:
                fh.seek(start)
                return fh.read().decode('utf-8', errors='replace')

        def _check():
            try:
                size = os.path.getsize(_APP_SERVER_LOG)
            except OSError:
                return False
            if size >= offset:
                try:
                    return needle in _read_from(_APP_SERVER_LOG, offset)
                except OSError:
                    return False
            for rotated in (_APP_SERVER_LOG + '.1', _APP_SERVER_LOG + '.1.gz'):
                try:
                    if needle in _read_from(rotated, offset):
                        return True
                except OSError:
                    continue
            try:
                return needle in _read_from(_APP_SERVER_LOG, 0)
            except OSError:
                return False

        try:
            return self.wait_until(_check, timeout=timeout, interval=1, timeout_msg='not found')
        except AssertionError:
            return False


class CreateRestartRecoveryTests(_PullChainTests):
    """app-server restart while a create() is still mid-flight must not strand the
    reservation - the restarted workers' first pass must pick it back up to a terminal
    createStatus.stage.

    The cases run the instance under a sweep interval far longer than their own timeouts,
    written into the config for their duration: app-server reads appServer.reconcileIntervalSeconds
    at startup, and every case restarts it, so the restarted workers run their first pass at once
    and their next only after that interval. A chain that reaches done within a case's timeout
    therefore did so through the first pass, which is what the cases are about. Teardown restores
    the config and restarts app-server once more, so the restored value is the one running."""

    _SWEEP_INTERVAL_SECONDS = 600

    def setUp(self):
        super().setUp()
        if not self.can_restart_services():
            self.skip(
                'service restart not enabled for this run (set '
                'DOCKSIDE_TEST_ALLOW_SERVICE_RESTART=1 in a mountIDE:false '
                'environment with sudo/s6 access to restart app-server - see '
                "CLAUDE.md's testing-capability matrix)"
            )
        self._config_bytes, config = self._load_config()
        config.setdefault('appServer', {})['reconcileIntervalSeconds'] = self._SWEEP_INTERVAL_SECONDS
        self._write_config(json.dumps(config, indent=2).encode('utf-8'))
        self._config_rewritten = True
        self._profile = self._create_pull_profile()

    def tearDown(self):
        """Every step runs even if an earlier one raises, and any failure is surfaced. The
        devtainers go first, through app-server as it runs; the config is restored next, and
        app-server restarted so the restored interval is the one running."""
        failures = []
        for step in (super().tearDown, self._remove_test_profile, self._restore_config,
                     self._restart_app_server_on_restored_config):
            try:
                step()
            except Exception as e:
                failures.append(f'{step.__name__}: {e!r}')
        if failures:
            raise AssertionError('teardown step(s) failed: ' + '; '.join(failures))

    def _remove_test_profile(self):
        if getattr(self, '_profile', None):
            self._remove_profile(self._profile)

    def _restore_config(self):
        if getattr(self, '_config_rewritten', False):
            self._write_config(self._config_bytes)
            self._config_rewritten = False

    def _restart_app_server_on_restored_config(self):
        """Only once the config was read for rewriting: a setUp that skipped before that left
        app-server running the operator's own interval throughout. Nothing of this case is in
        flight by now, so the documented graceful restart returns as soon as the workers exit.
        The helper returns when s6 reports the new manager, which is before its workers listen,
        so this also waits until a request is answered again: the next case's setUp is the
        next request, and a gateway error there would be this teardown's doing."""
        if not hasattr(self, '_config_bytes'):
            return
        restart_app_server_graceful()

        def _serving():
            try:
                self.admin.list_containers()
            except APIError:
                return False
            return True

        self.wait_until(_serving, timeout=30, interval=0.5,
                        timeout_msg='app-server did not answer a request within 30s of its restart')

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

    # The bound on a graceful restart made mid-pull. A worker with nothing posted to Docker
    # exits as soon as its drain has named the chain it abandons, so the restart takes the few
    # seconds the manager and s6 need; the pull it abandons runs for far longer than this.
    _GRACEFUL_RESTART_BOUND_SECONDS = 20

    def test_03_graceful_restart_abandons_pull_to_next_pass(self):
        """A graceful restart (`s6-svc -r` -> SIGQUIT, app-server's own down-signal) while a
        create() is mid-pull returns within a bound far shorter than the pull: the owning
        worker's drain waits only for a create or start already posted to Docker and for hook
        runs, names the chain it abandons at pulling in its own log line, and exits - ADR-0007
        mechanism 6. The restarted workers' first pass then resumes the record at pulling and
        carries it to done and running. The log line is what proves the abandonment happened in
        the owning worker; the bound is what proves the drain did not wait the pull out."""
        self._ensure_image_absent()
        name = self._sfx('inttest-createrestart-graceful')
        self.register_cleanup(name)
        self.admin.create(profile=self._profile, name=name, no_wait=True)

        data = self._wait_pulling_with_progress(name)
        reservation_id = data['id']

        try:
            offset = os.path.getsize(_APP_SERVER_LOG)
        except OSError:
            offset = 0

        # SIGQUIT while the pull is genuinely in flight. This blocks until the manager exits,
        # which it only does once its workers have drained - so on return the drain has happened.
        started = time.monotonic()
        restart_app_server_graceful()
        elapsed = time.monotonic() - started

        self.assert_true(
            elapsed < self._GRACEFUL_RESTART_BOUND_SECONDS,
            f'graceful restart mid-pull took {elapsed:.1f}s, over the '
            f'{self._GRACEFUL_RESTART_BOUND_SECONDS}s bound: the drain waited for the pull',
        )
        needle = f'at an unissued stage ({reservation_id})'
        self.assert_true(
            self._log_contains_since(offset, needle),
            f'the owning worker did not name the chain it abandoned: no {needle!r} after the '
            f'restart',
        )

        data = _wait_create_settled(self, name)
        _assert_recovered(self, name, data)


class CreatePullInterruptionTests(_PullChainTests):
    """A pull whose connection to Docker breaks is unresolved at 'pulling', not failed: the
    reservation keeps its stage and its layers, gains a createStatus.unresolved record, and the
    worker that recorded it retries ~15s later - the retried pull completes (Docker keeps the
    layers already pulled) and the chain goes on to a running container.

    The break is aimed at exactly one of app-server's connections by killing the single
    docker_socket_proxy child carrying it, so Docker itself, the daemon's event stream and every
    other connection keep running - what app-server observes across a Docker restart. Only the
    `docker.socket` path in the instance config changes, for the duration of a test: app-server
    re-reads the config on every authenticated request, so the create request itself is served
    through the proxy. docker-event-daemon reads the config at startup and on each container
    start event, so it follows the test's devtainer starting onto the proxy and, once the config
    is restored, would keep the proxy's path for its periodic container sync until the next
    start anywhere; teardown restarts it so the restored path takes effect at once, before the
    proxy stops.

    The proxy's own contract is checked at both ends, with the instance config untouched by a
    failure of either: before the config is redirected, a `docker version` through its socket
    must succeed and its control file must name the child that carried the request; at teardown
    it must exit 0 on SIGTERM, leaving neither its socket nor a live child behind. A harness
    fault thus fails as itself, not as a create that never reached Docker."""

    def setUp(self):
        super().setUp()
        if not self.can_restart_services():
            self.skip(
                'service restart not enabled for this run (set '
                'DOCKSIDE_TEST_ALLOW_SERVICE_RESTART=1 - these cases rewrite the instance\'s own '
                'config to route every Docker call app-server makes through a test proxy for '
                'their duration, and restart docker-event-daemon at teardown)'
            )
        self._config_bytes, config = self._load_config()
        self._profile = self._create_pull_profile()

        self._tmpdir = tempfile.mkdtemp(prefix='dsproxy-')
        self._control_path = os.path.join(self._tmpdir, 'requests.log')
        # A Unix socket path is limited to ~107 bytes, so the socket sits directly in a
        # short-prefixed temp dir rather than a nested one.
        self._listen_path = os.path.join(self._tmpdir, 'docker.sock')
        target_path = (config.get('docker') or {}).get('socket') or _DEFAULT_DOCKER_SOCKET
        # Its own session, so the proxy and every connection child it forks share one process
        # group that _stop_proxy can finish off as a unit should the proxy's own stop not.
        self._proxy = subprocess.Popen(
            [sys.executable, _DOCKER_SOCKET_PROXY, self._listen_path, target_path,
             self._control_path],
            start_new_session=True,
        )
        self.wait_until(
            lambda: os.path.exists(self._listen_path), timeout=10, interval=0.2,
            timeout_msg=f'the docker socket proxy did not start listening on '
                        f'{self._listen_path!r}',
        )
        self._check_proxy_forwards()

        config.setdefault('docker', {})['socket'] = self._listen_path
        self._write_config(json.dumps(config, indent=2).encode('utf-8'))
        # True while the instance config names the proxy's socket: the proxy must outlive that.
        self._redirected = True
        # True once it ever has: the daemon may have followed it there.
        self._config_rewritten = True

    def tearDown(self):
        """Unwinds in the one order that never leaves a live consumer pointing at a socket that
        has gone: the config goes back first; docker-event-daemon is restarted, since it reads
        the config at startup and otherwise only on a container start event, and its periodic
        container sync would keep the proxy's path until one; then the devtainers are removed;
        and the proxy stops only after that. Every step runs even if an earlier one raises, and
        any failure is surfaced rather than swallowed. The one exception is deliberate: while the
        config still names the proxy's socket, because restoring it failed, the proxy is left
        running and its directory in place, and that is reported, since a config pointing at a
        socket that has gone would break every Docker call the instance makes from then on."""
        failures = []
        for step in (self._restore_config, self._restart_daemon, self._remove_test_profile,
                     super().tearDown, self._stop_proxy, self._remove_tmpdir):
            try:
                step()
            except Exception as e:
                failures.append(f'{step.__name__}: {e!r}')
        if failures:
            raise AssertionError('teardown step(s) failed: ' + '; '.join(failures))

    # ── Instance config redirection ───────────────────────────────────────────

    def _restore_config(self):
        if getattr(self, '_redirected', False):
            self._write_config(self._config_bytes)
            self._redirected = False

    def _restart_daemon(self):
        # Only once the config has been redirected: a setUp that skipped or failed before the
        # rewrite left the daemon on the real socket throughout.
        if getattr(self, '_config_rewritten', False):
            restart_docker_event_daemon()

    def _remove_test_profile(self):
        if getattr(self, '_profile', None):
            self._remove_profile(self._profile)

    def _stop_proxy(self):
        """Stop the proxy and assert it stopped as its contract says: on SIGTERM it unlinks its
        listening socket, kills and reaps every connection child, and exits 0. The process group
        is killed outright afterwards whatever happened, so a proxy that broke that contract still
        leaves nothing forwarding. By this point the config is restored and the devtainers are
        removed, so any connection still open through the proxy belongs to nothing this test
        needs - and a consumer whose stream ends this way reconnects on the restored socket
        path. While the config still names the proxy's socket, the proxy is left running."""
        proxy = getattr(self, '_proxy', None)
        if proxy is None:
            return
        if getattr(self, '_redirected', False):
            raise AssertionError(
                f'the docker socket proxy is left running on {self._listen_path!r}: the instance '
                f'config still points at it'
            )
        proxy.terminate()
        try:
            returncode = proxy.wait(timeout=10)
            self.wait_until(
                lambda: not [pid for pid in self._recorded_pids() if _pid_alive(pid)],
                timeout=5, interval=0.2,
                timeout_msg='the proxy exited leaving a connection child of its own alive',
            )
        finally:
            # start_new_session made the proxy its own group leader, so its pid is the group id.
            try:
                os.killpg(proxy.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        self.assert_equal(returncode, 0, f'the proxy exited {returncode} on SIGTERM, not 0')
        self.assert_true(
            not os.path.exists(self._listen_path),
            f'the proxy exited leaving its listening socket {self._listen_path!r} behind',
        )

    def _remove_tmpdir(self):
        if getattr(self, '_tmpdir', None) and not getattr(self, '_redirected', False):
            shutil.rmtree(self._tmpdir, ignore_errors=True)

    # ── The proxy's contract ──────────────────────────────────────────────────

    def _check_proxy_forwards(self):
        """A `docker version` through the proxy's socket must answer, and the control file must
        name the child that carried it. This runs before the instance config is redirected, so
        a proxy that cannot forward fails with the instance untouched. The CLI sends its ping
        and its version request down one connection, and a child records the first request
        line it carries, so the line recorded is whichever of the two the CLI sent first."""
        result = subprocess.run(
            ['docker', '-H', f'unix://{self._listen_path}', 'version',
             '--format', '{{.Server.Version}}'],
            capture_output=True, text=True, timeout=30,
        )
        self.assert_equal(
            result.returncode, 0,
            f'`docker version` through the proxy socket failed ({result.returncode}): '
            f'{result.stderr.strip()!r}',
        )
        self.assert_true(
            result.stdout.strip(),
            '`docker version` through the proxy socket reported no server version',
        )
        self.assert_true(
            any(request_line.startswith(('HEAD ', 'GET '))
                for _pid, request_line in self._recorded_requests()),
            f'the proxy forwarded `docker version` but recorded no child carrying it: '
            f'{self._recorded_requests()!r}',
        )

    def _recorded_requests(self):
        """Every `(pid, request line)` the proxy's children have recorded, in order."""
        try:
            with open(self._control_path, encoding='utf-8') as fh:
                recorded = fh.read().splitlines()
        except OSError:
            return []
        requests = []
        for line in recorded:
            pid, _, request_line = line.partition(' ')
            if pid.isdigit():
                requests.append((int(pid), request_line))
        return requests

    def _recorded_pids(self):
        return [pid for pid, _request_line in self._recorded_requests()]

    # ── The interrupted-pull flow both cases share ────────────────────────────

    def _wait_pull_connection(self, timeout=20):
        """Return the pid of the proxy child carrying the image pull. Each Docker request
        app-server makes is its own connection, hence its own child, so the pull is identified
        by the one request line a child recorded before forwarding anything."""
        def _check():
            for pid, request_line in self._recorded_requests():
                if request_line.startswith('POST /images/create'):
                    return pid
            return False

        return self.wait_until(
            _check, timeout=timeout, interval=0.3,
            timeout_msg='no proxy connection carrying the image pull was recorded',
        )

    def _observe_interrupted_pull(self, name, break_child, unresolved_timeout,
                                  release_child=None):
        """Create $name, break its pull the way `break_child(pid)` does, and assert the whole
        outcome: unresolved at 'pulling' with one attempt recorded, a retry scheduled in
        app-server's log, and a settled, running devtainer afterwards. `release_child`, when
        given, runs once the unresolved record has been observed (or the wait for it has given
        up), so a child left stopped by `break_child` is always let go.

        Returns the createStatus.unresolved record, for a caller with something further to
        assert about its reason."""
        self._ensure_image_absent()
        self.register_cleanup(name)
        self.admin.create(profile=self._profile, name=name, no_wait=True)
        self._wait_pulling_with_progress(name)

        pid = self._wait_pull_connection()
        try:
            offset = os.path.getsize(_APP_SERVER_LOG)
        except OSError:
            offset = 0

        def _unresolved_at_pulling():
            try:
                data = self.admin.get_container(name)
            except APIError:
                return False
            cs = _create_status(data)
            unresolved = cs.get('unresolved')
            if cs.get('stage') != 'pulling' or not isinstance(unresolved, dict):
                return False
            return data if unresolved.get('attempts') == 1 else False

        try:
            break_child(pid)
        except ProcessLookupError:
            raise AssertionError(
                f'the connection carrying {name!r}\'s pull (proxy child {pid}) had already '
                f'closed, so the pull was never interrupted'
            )
        try:
            data = self.wait_until(
                _unresolved_at_pulling, timeout=unresolved_timeout, interval=1,
                timeout_msg=f'{name!r} was never recorded unresolved at stage pulling with one '
                            f'attempt after its Docker connection broke',
            )
        finally:
            if release_child is not None:
                release_child(pid)

        unresolved = _create_status(data).get('unresolved')
        reason = unresolved.get('reason')
        print(f'# {name}: unresolved at pulling - reason={reason!r} '
              f'since={unresolved.get("since")!r} retryAfter={unresolved.get("retryAfter")!r}')
        self.assert_true(
            isinstance(reason, str) and reason.strip(),
            f'{name!r} is unresolved but records no reason: {unresolved!r}',
        )

        reservation_id = data.get('id')
        self.assert_true(
            self._log_contains_since(offset, f"reservation '{reservation_id}' retries in 15s"),
            f'{name!r} (reservation {reservation_id!r}) was recorded unresolved, but the worker '
            f'that recorded it logged no retry - the record is unresolved with nothing coming '
            f'back to it',
        )

        # The pull is redone from the start against a fresh connection, on top of whatever
        # Docker already has, so the whole chain gets a generous ceiling here.
        final = _wait_create_settled(self, name, timeout=240)
        _assert_recovered(self, name, final)

        # Observed, not asserted: how much of the interrupted pull the retry inherited is
        # Docker's business, not this behaviour's contract.
        layers = _create_status(final).get('layers') or {}
        cached = sum(1 for layer in layers.values()
                     if (layer or {}).get('status') == 'Already exists')
        print(f'# {name}: {len(layers)} layers after the retried pull - {cached} "Already exists", '
              f'{len(layers) - cached} other')

        return unresolved

    def test_01_pull_cut_off_by_connection_loss(self):
        """A pull whose connection to Docker is severed mid-stream is unresolved at 'pulling'
        and retried by the worker that recorded it, reaching a running container - a broken
        connection to a Docker that is still there is not a pull that failed."""
        self._observe_interrupted_pull(
            self._sfx('inttest-pullbreak-reset'),
            lambda pid: os.kill(pid, signal.SIGKILL),
            unresolved_timeout=30,
        )

    def test_02_pull_stalled_past_inactivity_limit(self):
        """A pull that simply goes silent - its connection still open, no bytes moving either
        way - is unresolved at 'pulling' once the transport's 40s inactivity limit expires, and
        retried exactly as a severed one is: a stall is a connection app-server has not been told
        is broken, not a pull that failed."""
        def _release(pid):
            # A stopped child is resumed before it is killed, so no child is ever left in
            # SIGSTOP holding a connection to Docker open.
            for sig in (signal.SIGCONT, signal.SIGKILL):
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    return

        unresolved = self._observe_interrupted_pull(
            self._sfx('inttest-pullbreak-stall'),
            lambda pid: os.kill(pid, signal.SIGSTOP),
            unresolved_timeout=90,
            release_child=_release,
        )

        self.assert_in(
            'inactivity', (unresolved.get('reason') or '').lower(),
            f'a silent pull was unresolved, but not for inactivity: {unresolved!r}',
        )


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

    def test_03_bare_hex_name_rejected_at_validation(self):
        """A reservation name that is itself a bare 12- or 64-character hex string is rejected
        by Reservation::validate before create() ever runs - that shape is exactly what Docker
        would resolve as a container's own short or full ID, ahead of an ID prefix, so a
        container actually given such a name could capture another container's containerId-
        addressed calls. Unlike test_01/test_02, no other container is involved: the name alone
        is the defect, so this needs no low-level docker fabrication or cleanup."""
        # uuid4().hex is already lowercase hex; forcing the first character to 'a' guarantees
        # the base name grammar's own "begin with a letter" rule is satisfied too, so the
        # rejection below is attributable to the hex-length check, not the pre-existing grammar
        # check (which fails names starting 0-9 for an unrelated reason).
        name_12 = 'a' + uuid.uuid4().hex[:11]
        name_64 = 'a' + uuid.uuid4().hex + uuid.uuid4().hex[:31]

        for name in (name_12, name_64):
            try:
                self.admin.create(profile=self.test_profile_alpine, name=name)
            except APIError as e:
                self.assert_in(
                    'must not be a bare 12- or 64-character hexadecimal string', str(e),
                    f'{name!r} was rejected, but not for being a bare hex string: {e!r}',
                )
            else:
                raise AssertionError(f'create with bare hex name {name!r} was accepted, not rejected')

            self.assert_api_error(lambda n=name: self.admin.get_container(n))
