"""
02_lifecycle_alpine.py — Full devtainer lifecycle with alpine:latest
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError

_BASE_CONTAINER     = 'inttest-alpine-01'
_BASE_DEV_CONTAINER = 'inttest-alpine-dev1'


class LifecycleAlpineTests(TestCase):
    """Full lifecycle test: create → list → get → start → stop → remove.

    State (the container) persists across all test methods in this class.
    setUpClass computes the suffixed container name; tearDownClass cleans up once.
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
        self.create_and_wait(self.admin, self.test_profile_alpine, self.CONTAINER_NAME)

    def test_02_list_contains(self):
        names = self.container_names_in_list(self.admin)
        self.assert_in(self.CONTAINER_NAME, names, f'{self.CONTAINER_NAME!r} not in list')

    def test_03_get(self):
        data = self.admin.get_container(self.CONTAINER_NAME)
        self.assert_true(isinstance(data, dict), 'get returned non-dict')
        self.assert_true('name' in data or 'id' in data, 'get result missing name/id')

    def test_04_start(self):
        # Container was created running (status=1); stop first to exercise the start path.
        try:
            self.admin.stop(self.CONTAINER_NAME, wait=True, timeout=30)
        except Exception:
            pass
        self.admin.start(self.CONTAINER_NAME, wait=True, timeout=120)
        data = self.admin.get_container(self.CONTAINER_NAME)
        status = data.get('status') if isinstance(data, dict) else None
        self.assert_equal(status, 1, f'expected status 1, got {status!r}')

    def test_05_stop(self):
        # Ensure started first (idempotent if already running)
        try:
            self.admin.start(self.CONTAINER_NAME, wait=True, timeout=30)
        except Exception:
            pass
        self.admin.stop(self.CONTAINER_NAME, wait=True, timeout=60)
        data = self.admin.get_container(self.CONTAINER_NAME)
        status = data.get('status') if isinstance(data, dict) else None
        self.assert_equal(status, 0, f'expected status 0, got {status!r}')

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


class LifecycleAlpineDev1Tests(TestCase):
    """testdev1 can create and manage their own container."""

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
        self.create_and_wait(self.dev1, self.test_profile_alpine, self.DEV_CONTAINER)


class CreateFailureTests(TestCase):
    """Container whose image does not exist reaches status -4 (launch-failed).

    Uses a profile pointing at a localhost registry that is guaranteed not to
    be running, so docker create fails immediately without any network round-trip
    to Docker Hub.

    test_08 asserts the server-side transition to -4 (createStatus recorded);
    test_09 asserts the CLI's user-facing contract that a *waited* create exits
    non-zero on that failure rather than silently reporting success.
    """

    @classmethod
    def setUpClass(cls):
        cls.CONTAINER_NAME = cls._sfx('inttest-create-fail-01')

    @classmethod
    def tearDownClass(cls):
        try:
            cls.admin.remove(cls.CONTAINER_NAME, wait=False)
        except Exception:
            pass

    def test_08_bad_image_reaches_launch_failed(self):
        # Create with --no-wait so the reservation record is returned (and the CLI
        # exits 0) regardless of the expected launch failure; this isolates the
        # server-side -4 transition under test from the CLI's exit-code contract,
        # which test_09 covers.
        result = self.admin.create(
            profile=self.test_profile_bad_image,
            name=self.CONTAINER_NAME,
            no_wait=True,
        )
        self.assert_true(result is not None, 'create returned nothing')
        created_name = result.get('name') if isinstance(result, dict) else None
        self.assert_equal(created_name, self.CONTAINER_NAME,
                          f'expected container name {self.CONTAINER_NAME!r}')

        def _launch_failed():
            try:
                data = self.admin.get_container(self.CONTAINER_NAME)
            except APIError:
                return None
            return data if (data.get('status') if isinstance(data, dict) else None) == -4 else None

        data = self.wait_until(
            _launch_failed,
            timeout=30,
            interval=1,
            timeout_msg=f'{self.CONTAINER_NAME!r} did not reach launch-failed state (-4)',
        )
        create_status = data.get('createStatus') if isinstance(data, dict) else None
        self.assert_true(
            create_status,
            f'createStatus not set on launch failure (got {create_status!r})',
        )

    def test_09_waited_create_exits_nonzero_on_launch_failure(self):
        # A waited create (the default) must exit non-zero when the launch fails
        # (-4), so scripts and automation do not mistake a failed launch for
        # success; the harness surfaces that non-zero exit as APIError.
        name = self._sfx('inttest-create-fail-wait-09')
        self.register_cleanup(name)
        self.assert_api_error(
            lambda: self.admin.create(profile=self.test_profile_bad_image, name=name))
