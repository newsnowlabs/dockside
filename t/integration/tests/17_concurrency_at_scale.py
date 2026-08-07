"""
17_concurrency_at_scale.py — devtainer launch/restart at realistic concurrency.

Coverage:
  - N devtainers created concurrently (not the 2-3 overlapping launches
    exercised live during original development - see docs/plans/lifecycle-
    hooks-review-followup.md's Concern #7 / the ded-async-rewrite branch's own
    task #16 tracking pointer) all reach running state, with no cross-talk
    between concurrent launch-dispatch DAGs (one container's own name/profile
    never bleeding into another's).
  - the same N devtainers, stopped and started concurrently across multiple
    rounds, correctly increment data.startCount per container each round (see
    16_ded_restart_recovery.py for the DAG-recovery angle on restarts;
    this module is about concurrency/scale, not fault injection).

Does not require can_restart_services() or can_modify_networks() - this only
drives ordinary create/stop/start through the CLI at higher concurrency than
the rest of the suite, so it runs under the default profile.

Uses concurrent.futures.ThreadPoolExecutor to fire real concurrent CLI
subprocess calls - each thread blocks on its own `subprocess.run`, which
releases the GIL for the duration, so this achieves genuine OS-level
concurrency the same way the manual thrash-testing session's backgrounded
shell `&`/`wait` did. First use of real concurrency in this harness (stdlib
only - no new dependency).

DRAFT - not yet run against a live instance. N=8 is a starting point, sized
for a shared CI host's likely headroom, not a specific measured budget -
verify/adjust the first time this actually runs.
"""

import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError

N = 8


class ConcurrencyAtScaleTests(TestCase):

    def _concurrent(self, fn, items):
        """Run fn(item) for every item in items, truly concurrently. Returns
        {item: exception_or_None} - None means fn(item) succeeded."""
        results = {}
        with ThreadPoolExecutor(max_workers=len(items)) as pool:
            futures = {pool.submit(fn, item): item for item in items}
            for future in as_completed(futures):
                item = futures[future]
                try:
                    future.result()
                    results[item] = None
                except Exception as e:
                    results[item] = e
        return results

    def test_01_concurrent_launch_storm(self):
        names = [self._sfx(f'inttest-scale-{i}') for i in range(N)]
        for name in names:
            self.register_cleanup(name)

        results = self._concurrent(
            lambda n: self.admin.create(profile=self.test_profile_alpine, name=n),
            names,
        )
        failures = {n: e for n, e in results.items() if e is not None}
        self.assert_true(not failures, f'{len(failures)}/{N} concurrent creates failed: {failures}')

        for name in names:
            self.wait_running(self.admin, name, timeout=60)

        # No cross-talk between concurrent launch DAGs: each container's own
        # identity must be exactly its own, not another's.
        for name in names:
            data = self.admin.get_container(name)
            self.assert_equal(data.get('name'), name)
            self.assert_equal(data.get('profile'), self.test_profile_alpine)

    def test_02_concurrent_restart_storm_multi_round(self):
        names = [self._sfx(f'inttest-scale-restart-{i}') for i in range(N)]

        def _start_count(name):
            data = self.admin.get_container(name)
            return (data.get('data') or {}).get('startCount')

        for name in names:
            self.register_cleanup(name)
            self.admin.create(profile=self.test_profile_alpine, name=name)
            self.wait_running(self.admin, name, timeout=60)

        counts_before = {name: (_start_count(name) or 0) for name in names}

        for round_num in range(1, 4):
            stop_results = self._concurrent(
                lambda n: self.admin.stop(n, wait=True, timeout=60), names)
            stop_failures = {n: e for n, e in stop_results.items() if e is not None}
            self.assert_true(not stop_failures, f'round {round_num}: stop failures: {stop_failures}')

            start_results = self._concurrent(
                lambda n: self.admin.start(n, wait=True, timeout=90), names)
            start_failures = {n: e for n, e in start_results.items() if e is not None}
            self.assert_true(not start_failures, f'round {round_num}: start failures: {start_failures}')

            for name in names:
                self.wait_running(self.admin, name, timeout=60)

        for name in names:
            after = _start_count(name) or 0
            self.assert_true(
                after > counts_before[name],
                f'{name!r}: startCount did not advance across 3 restart rounds '
                f'(before={counts_before[name]!r}, after={after!r})',
            )
