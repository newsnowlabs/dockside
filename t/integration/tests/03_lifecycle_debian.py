"""
03_lifecycle_debian.py — Lifecycle with debian:latest image
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError

PROFILE_NAME        = '11-debian'
_BASE_CONTAINER     = 'inttest-debian-01'
_BASE_DEV_CONTAINER = 'inttest-debian-dev1'


class LifecycleDebianTests(TestCase):
    """Lifecycle test using Debian image.

    State (the container) persists across all test methods in this class.
    setUpClass computes the suffixed container name; tearDownClass cleans up once.
    Per-test tearDown is NOT used for this container — that was the root cause of
    the docker errors where tearDown removed the container after test_01_create,
    leaving tests 04-06 operating on a reservation with no backing docker container.
    """

    @classmethod
    def setUpClass(cls):
        cls.CONTAINER_NAME = cls._sfx(_BASE_CONTAINER)

    @classmethod
    def tearDownClass(cls):
        for fn in (
            lambda: cls.admin.stop(cls.CONTAINER_NAME, wait=False),
            lambda: cls.admin.remove(cls.CONTAINER_NAME, wait=False),
        ):
            try:
                fn()
            except Exception:
                pass

    def test_01_create(self):
        result = self.admin.create(
            profile=PROFILE_NAME,
            name=self.CONTAINER_NAME,
        )
        self.assert_true(result is not None, 'create returned nothing')

    def test_02_list_contains(self):
        names = self.container_names_in_list(self.admin)
        self.assert_in(self.CONTAINER_NAME, names)

    def test_03_get(self):
        data = self.admin.get_container(self.CONTAINER_NAME)
        self.assert_true(isinstance(data, dict), 'get returned non-dict')

    def test_04_start(self):
        self.admin.start(self.CONTAINER_NAME, wait=True, timeout=180)
        data = self.admin.get_container(self.CONTAINER_NAME)
        self.assert_equal(data.get('status'), 1)

    def test_05_stop(self):
        try:
            self.admin.start(self.CONTAINER_NAME, wait=True, timeout=30)
        except Exception:
            pass
        self.admin.stop(self.CONTAINER_NAME, wait=True, timeout=60)
        data = self.admin.get_container(self.CONTAINER_NAME)
        self.assert_equal(data.get('status'), 0)

    def test_06_remove(self):
        try:
            self.admin.stop(self.CONTAINER_NAME, wait=True, timeout=30)
        except Exception:
            pass
        self.admin.remove(self.CONTAINER_NAME)

        def _removed():
            containers = self.admin.list_containers()
            c = next(
                (
                    item for item in containers
                    if isinstance(item, dict) and item.get('name') == self.CONTAINER_NAME
                ),
                None,
            )
            return c is None or c.get('status', 0) <= -3

        self.wait_until(
            _removed,
            timeout=20,
            interval=1,
            timeout_msg=f'{self.CONTAINER_NAME!r} still present after remove',
        )
        # Container removed by the test itself; tearDownClass will find nothing to clean up.


class LifecycleDebianDev1Tests(TestCase):
    """dev1 creates a debian devtainer."""

    @classmethod
    def setUpClass(cls):
        cls.DEV_CONTAINER = cls._sfx(_BASE_DEV_CONTAINER)

    @classmethod
    def tearDownClass(cls):
        for fn in (
            lambda: cls.admin.stop(cls.DEV_CONTAINER, wait=False),
            lambda: cls.admin.remove(cls.DEV_CONTAINER, wait=False),
        ):
            try:
                fn()
            except Exception:
                pass

    def test_07_dev1_can_create_own(self):
        result = self.dev1.create(
            profile=PROFILE_NAME,
            name=self.DEV_CONTAINER,
        )
        self.assert_true(result is not None)
        names = self.container_names_in_list(self.dev1)
        self.assert_in(self.DEV_CONTAINER, names)
