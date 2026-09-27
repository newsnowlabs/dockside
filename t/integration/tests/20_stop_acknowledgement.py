"""
20_stop_acknowledgement.py — a stop is acknowledged as soon as Docker has it, and the
reservation reports 'stopping' until the container is observed stopped
"""

import sys
import os
import time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase

_BASE_CONTAINER = 'inttest-stopack-01'

# The profile's --stop-timeout, which its SIGTERM-ignoring command makes Docker wait out in full.
_STOP_TIMEOUT = 20


class StopAcknowledgementTests(TestCase):
    """Drives one devtainer whose stop takes its full 20 s stop timeout. State persists across
    the methods in this class; tearDownClass cleans up once."""

    @classmethod
    def setUpClass(cls):
        cls.CONTAINER_NAME = cls._sfx(_BASE_CONTAINER)

    @classmethod
    def tearDownClass(cls):
        for fn in (
            lambda: cls.admin.stop(cls.CONTAINER_NAME, wait=True, timeout=60),
            lambda: cls.admin.remove(cls.CONTAINER_NAME, wait=False),
        ):
            try:
                fn()
            except Exception:
                pass

    def _stopped(self):
        data = self.admin.get_container(self.CONTAINER_NAME)
        status = data.get('status') if isinstance(data, dict) else None
        return status is not None and status <= 0

    def test_01_create(self):
        self.create_and_wait(self.admin, self.test_profile_stop_timeout, self.CONTAINER_NAME)
        data = self.admin.get_container(self.CONTAINER_NAME)
        self.assert_equal(data.get('stopping'), False, 'a freshly started devtainer is not stopping')

    def test_02_stop_is_acknowledged_before_the_container_exits(self):
        requested = time.monotonic()
        self.admin.stop(self.CONTAINER_NAME, wait=False)
        acknowledged_after = time.monotonic() - requested
        self.assert_true(
            acknowledged_after < _STOP_TIMEOUT / 2,
            f'stop returned after {acknowledged_after:.1f}s, so it waited for the container rather than for Docker to take the request',
        )

        data = self.admin.get_container(self.CONTAINER_NAME)
        self.assert_equal(data.get('status'), 1, 'the container is still running right after the acknowledgement')
        self.assert_equal(data.get('stopping'), True, 'and the reservation reports it stopping')

        self.wait_until(self._stopped, timeout=_STOP_TIMEOUT * 3, timeout_msg='container did not stop')
        stopped_after = time.monotonic() - requested
        self.assert_true(
            stopped_after >= _STOP_TIMEOUT * 0.5,
            f'container stopped after {stopped_after:.1f}s, before its {_STOP_TIMEOUT}s stop timeout could have elapsed',
        )
        data = self.admin.get_container(self.CONTAINER_NAME)
        self.assert_equal(data.get('stopping'), False, 'once stopped, the reservation no longer reports it stopping')

    def test_03_a_later_start_clears_the_indicator(self):
        self.admin.start(self.CONTAINER_NAME, wait=True, timeout=120)
        self.wait_running(self.admin, self.CONTAINER_NAME)
        # The daemon records the new start time from the start event; the stop request on
        # record is older than it, so the flag reads false without anything clearing it.
        self.wait_until(
            lambda: self.admin.get_container(self.CONTAINER_NAME).get('stopping') is False,
            timeout=20, timeout_msg='reservation still reports stopping after a restart',
        )
