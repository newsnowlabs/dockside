"""
16_ded_restart_recovery.py — docker-event-daemon restart recovery mid-launch-DAG.

Coverage:
  - restarting docker-event-daemon while a devtainer's launch DAG (launch:prep ->
    launch:git/launch:ide/lifecycle:*) is still in flight does not strand it: the
    startup "Restart-recovery" sweep + %launchRecovering/on_tick reconciliation
    (docker-event-daemon's own header comment calls this "found live, not
    assumed" during original development) picks it back up and every stage
    eventually reaches a terminal state - not just "the process didn't crash".
  - the same, under N concurrent in-flight launches at once - the single-
    container case isolates the mechanism; this exercises it under the
    condition it was actually found under (concurrent load).
  - docker-event-daemon itself survives the restart cleanly (comes back up
    with a new pid, not a crash-loop).

Requires can_restart_services() == True (DOCKSIDE_TEST_ALLOW_SERVICE_RESTART=1)
- skipped entirely otherwise, since restarting a real host service needs
sudo/s6 access most test environments deliberately don't have (see
resolve_allow_service_restart's own comment in dockside_test.py). This means
these tests are opt-in, not part of a default `bash t/integration/run_tests.sh`
run - see this repo's CLAUDE.md "Runtime environment & testing capability"
section for which launch profile gives that access (mountIDE:false).

STATUS: written and reviewed (including in the ded-async-rewrite-quality-audit.md
pass), Python syntax-checked, but **not yet executed against a live instance** -
this repo's automated tooling has no `dockside login` session available to run
it. Written against the CLI/harness shapes exercised live during the
ded-async-rewrite branch's own manual thrash-testing session (same scenario,
same result, ad hoc); intended to lock that result in as a repeatable
regression check, not to re-derive it. Run this once, by hand, in a
mountIDE:false environment (`DOCKSIDE_TEST_MODE=local
DOCKSIDE_TEST_ALLOW_SERVICE_RESTART=1 bash t/integration/run_tests.sh --only 16`)
before relying on it as actual regression coverage, and drop this notice once it
has been.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError, restart_docker_event_daemon

N = 5  # kept modest for a CI-style run; the manual thrash session used 8-10


def _hook_stage_state(container_data, stage):
    hooks = ((container_data or {}).get('data') or {}).get('hooks') or {}
    status = hooks.get('status') or {}
    return (status.get(stage) or {}).get('state')


class DedRestartRecoveryTests(TestCase):
    """docker-event-daemon restart while launches are still mid-DAG must not
    strand them - the Restart-recovery sweep + %launchRecovering/on_tick must
    pick every in-flight reservation back up to a terminal DAG state."""

    def setUp(self):
        super().setUp()
        if not self.can_restart_services():
            self.skip(
                'service restart not enabled for this run (set '
                'DOCKSIDE_TEST_ALLOW_SERVICE_RESTART=1 in a mountIDE:false '
                'environment with sudo/s6 access to restart docker-event-daemon '
                '- see CLAUDE.md\'s testing-capability matrix)'
            )

    def _wait_stage_reached(self, name, stage, states, timeout=20):
        """Poll until data.hooks.status[stage].state is one of `states`."""
        def _check():
            try:
                data = self.admin.get_container(name)
            except APIError:
                return False
            state = _hook_stage_state(data, stage)
            return state if state in states else False

        return self.wait_until(
            _check, timeout=timeout, interval=0.5,
            timeout_msg=f'{name!r} stage {stage!r} did not reach one of {states!r}',
        )

    def _wait_dag_settled(self, name, timeout=60):
        """Poll until the container is running and launch:ide - the last stage
        dispatched, and (per docker-event-daemon's own launch_in_flight()
        comment) deliberately perpetual/never-'done' since it's the long-running
        IDE supervisor - has at least been dispatched ('running' or 'done')."""
        def _check():
            try:
                data = self.admin.get_container(name)
            except APIError:
                return False
            if data.get('status') != 1:
                return False
            state = _hook_stage_state(data, 'launch:ide')
            return data if state in ('done', 'running') else False

        return self.wait_until(
            _check, timeout=timeout, interval=1,
            timeout_msg=f'{name!r} launch DAG did not settle',
        )

    def test_01_single_container_restart_mid_dag(self):
        """Isolates the mechanism: one launch, interrupted deterministically -
        polled until launch:prep is actually dispatched, not a guessed sleep."""
        name = self._sfx('inttest-dedrestart-solo')
        self.register_cleanup(name)
        self.admin.create(profile=self.test_profile_alpine, name=name, no_wait=True)

        self._wait_stage_reached(name, 'launch:prep', ('running', 'done'), timeout=20)

        restart_docker_event_daemon()

        data = self._wait_dag_settled(name, timeout=60)
        self.assert_equal(data.get('status'), 1)
        prep_state = _hook_stage_state(data, 'launch:prep')
        self.assert_equal(prep_state, 'done', f'launch:prep never settled; full data={data!r}')

    def test_02_concurrent_launches_restart_mid_dag(self):
        """The condition this was actually found under during original
        development: several launches in flight at once, not just one."""
        names = [self._sfx(f'inttest-dedrestart-{i}') for i in range(N)]
        for name in names:
            self.register_cleanup(name)
            self.admin.create(profile=self.test_profile_alpine, name=name, no_wait=True)

        # Wait for at least one to be genuinely mid-dispatch before restarting -
        # "at least one", not "this specific one", since N concurrent dispatches
        # don't settle in lockstep.
        def _any_dispatched():
            for name in names:
                try:
                    data = self.admin.get_container(name)
                except APIError:
                    continue
                if _hook_stage_state(data, 'launch:prep') in ('running', 'done'):
                    return True
            return False

        self.wait_until(
            _any_dispatched, timeout=20, interval=0.5,
            timeout_msg='no launch reached launch:prep dispatch before timeout',
        )

        restart_docker_event_daemon()

        for name in names:
            data = self._wait_dag_settled(name, timeout=60)
            self.assert_equal(data.get('status'), 1, f'{name!r} did not end up running')
            self.assert_equal(_hook_stage_state(data, 'launch:prep'), 'done', f'{name!r}: {data!r}')
