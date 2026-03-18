"""
02_lifecycle_alpine.py — Full devtainer lifecycle with alpine:latest
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError

PROFILE_NAME = '10-alpine'
CONTAINER_NAME = 'inttest-alpine-01'


class LifecycleAlpineTests(TestCase):
    """Full lifecycle test: create → list → get → start → stop → remove.

    State (the container) persists across all test methods in this class.
    setUp does not register per-test cleanup; tearDownClass handles cleanup once.
    """

    @classmethod
    def tearDownClass(cls):
        for fn in (
            lambda: cls.admin.stop(CONTAINER_NAME, wait=False),
            lambda: cls.admin.remove(CONTAINER_NAME, wait=False),
        ):
            try:
                fn()
            except Exception:
                pass

    def test_01_create(self):
        result = self.admin.create(
            profile=PROFILE_NAME,
            name=CONTAINER_NAME,
        )
        self.assert_true(result is not None, 'create returned nothing')
        # result may be the container data dict or contain it
        name = result.get('name') if isinstance(result, dict) else None
        self.assert_true(
            name == CONTAINER_NAME or result is not None,
            f'expected container name {CONTAINER_NAME!r}'
        )

    def test_02_list_contains(self):
        names = self.container_names_in_list(self.admin)
        self.assert_in(CONTAINER_NAME, names, f'{CONTAINER_NAME!r} not in list')

    def test_03_get(self):
        data = self.admin.get_container(CONTAINER_NAME)
        self.assert_true(isinstance(data, dict), 'get returned non-dict')
        self.assert_true('name' in data or 'id' in data, 'get result missing name/id')

    def test_04_start(self):
        # Container was created running (status=1); stop first to exercise the start path.
        try:
            self.admin.stop(CONTAINER_NAME, wait=True, timeout=30)
        except Exception:
            pass
        self.admin.start(CONTAINER_NAME, wait=True, timeout=120)
        data = self.admin.get_container(CONTAINER_NAME)
        status = data.get('status') if isinstance(data, dict) else None
        self.assert_equal(status, 1, f'expected status 1, got {status!r}')

    def test_05_stop(self):
        # Ensure started first (idempotent if already running)
        try:
            self.admin.start(CONTAINER_NAME, wait=True, timeout=30)
        except Exception:
            pass
        self.admin.stop(CONTAINER_NAME, wait=True, timeout=60)
        data = self.admin.get_container(CONTAINER_NAME)
        status = data.get('status') if isinstance(data, dict) else None
        self.assert_equal(status, 0, f'expected status 0, got {status!r}')

    def test_06_remove(self):
        try:
            self.admin.stop(CONTAINER_NAME, wait=True, timeout=30)
        except Exception:
            pass
        self.admin.remove(CONTAINER_NAME)
        # Reservations linger in the list for ~30s after removal while dockside
        # finalises async docker rm.  Accept success if the entry is either:
        #   (a) absent from the list, or
        #   (b) present but in "container-removed" state: status <= -2 and no containerId
        containers = self.admin.list_containers()
        c = next((item for item in containers
                  if isinstance(item, dict) and item.get('name') == CONTAINER_NAME), None)
        if c is not None:
            status = c.get('status', 0)
            container_id = c.get('containerId')
            self.assert_true(
                status <= -2 and not container_id,
                f'{CONTAINER_NAME!r} still in list after remove '
                f'(status={status!r}, containerId={container_id!r})',
            )


class LifecycleAlpineDev1Tests(TestCase):
    """testdev1 can create and manage their own container."""

    DEV_CONTAINER = 'inttest-alpine-dev1'

    def setUp(self):
        super().setUp()
        self.register_cleanup(self.DEV_CONTAINER)

    def test_07_dev1_can_create_own(self):
        result = self.dev1.create(
            profile=PROFILE_NAME,
            name=self.DEV_CONTAINER,
        )
        self.assert_true(result is not None, 'dev1 create returned nothing')
        names = self.container_names_in_list(self.dev1)
        self.assert_in(self.DEV_CONTAINER, names)
