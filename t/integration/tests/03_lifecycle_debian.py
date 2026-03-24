"""
03_lifecycle_debian.py — Lifecycle with debian:latest image
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError

PROFILE_NAME = '11-debian'
CONTAINER_NAME = 'inttest-debian-01'


class LifecycleDebianTests(TestCase):
    """Lifecycle test using Debian image."""

    def setUp(self):
        super().setUp()
        self.register_cleanup(CONTAINER_NAME)

    def test_01_create(self):
        result = self.admin.create(
            profile=PROFILE_NAME,
            name=CONTAINER_NAME,
        )
        self.assert_true(result is not None, 'create returned nothing')

    def test_02_list_contains(self):
        names = self.container_names_in_list(self.admin)
        self.assert_in(CONTAINER_NAME, names)

    def test_03_get(self):
        data = self.admin.get_container(CONTAINER_NAME)
        self.assert_true(isinstance(data, dict), 'get returned non-dict')

    def test_04_start(self):
        self.admin.start(CONTAINER_NAME, wait=True, timeout=180)
        data = self.admin.get_container(CONTAINER_NAME)
        self.assert_equal(data.get('status'), 1)

    def test_05_stop(self):
        try:
            self.admin.start(CONTAINER_NAME, wait=True, timeout=30)
        except Exception:
            pass
        self.admin.stop(CONTAINER_NAME, wait=True, timeout=60)
        data = self.admin.get_container(CONTAINER_NAME)
        self.assert_equal(data.get('status'), 0)

    def test_06_remove(self):
        try:
            self.admin.stop(CONTAINER_NAME, wait=True, timeout=30)
        except Exception:
            pass
        self.admin.remove(CONTAINER_NAME)
        names = self.container_names_in_list(self.admin)
        self.assert_not_in(CONTAINER_NAME, names)
        self._cleanup_names.clear()


class LifecycleDebianDev1Tests(TestCase):
    """dev1 creates a debian devtainer."""

    DEV_CONTAINER = 'inttest-debian-dev1'

    def setUp(self):
        super().setUp()
        self.register_cleanup(self.DEV_CONTAINER)

    def test_07_dev1_can_create_own(self):
        result = self.dev1.create(
            profile=PROFILE_NAME,
            name=self.DEV_CONTAINER,
        )
        self.assert_true(result is not None)
        names = self.container_names_in_list(self.dev1)
        self.assert_in(self.DEV_CONTAINER, names)
