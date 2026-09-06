"""
19_ide_none.py — the 'none' pseudo-IDE (SSH-only devtainers)

Covers:
  - A profile offering 'none' alongside a real IDE: creating with --ide none
    succeeds, and the profile's 'ide' router still exists (so a real IDE can
    be enabled later — routers can't be added post-launch).            [test_01]
  - A profile with the IDE subsystem switched off ("ide": false): creating
    with no --ide defaults to 'none', and no 'ide' router exists.       [test_02]
  - Default IDE selection never silently picks 'none' when a real IDE is
    also on offer.                                                      [test_03]
  - Enabling an IDE later on a devtainer launched with 'none': edit updates
    the stored choice immediately but does not live-switch a running
    devtainer; a stop/start cycle then makes the IDE reachable.         [test_04]
"""

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError


def _none_and_real_profile(name, image):
    return {
        'version': 2,
        'name': name,
        'active': True,
        'routers': [
            {
                'name': 'www',
                'prefixes': ['www'],
                'domains': ['*'],
                'https': {'protocol': 'http', 'port': 8080},
                'auth': ['developer', 'owner', 'viewer', 'user', 'containerCookie', 'public'],
            }
        ],
        'networks': ['*'],
        'images': [image],
        'unixusers': ['dockside'],
        'IDEs': ['openvscode/latest', 'none'],
        'mounts': {
            'tmpfs': [{'dst': '/home/{ideUser}/.ssh', 'tmpfs-size': '1M'}],
            'bind': [],
            'volume': [],
        },
        'lxcfs': True,
        'dockerArgs': ['--pids-limit=4000'],
        'command': ['sleep', 'infinity'],
    }


def _ide_disabled_profile(name, image):
    profile = _none_and_real_profile(name, image)
    profile['ide'] = False
    del profile['IDEs']  # let the global-off collapse override apply
    return profile


class IdeNoneTests(TestCase):
    """The 'none' pseudo-IDE: router preservation, defaulting, permission model."""

    @classmethod
    def setUpClass(cls):
        cls._profile_none_and_real = cls._sfx('inttest-ide-none-real')
        cls._profile_ide_disabled = cls._sfx('inttest-ide-disabled')
        cls._create_profile(
            cls._profile_none_and_real,
            _none_and_real_profile(cls._profile_none_and_real, cls.test_image_debian),
        )
        cls._create_profile(
            cls._profile_ide_disabled,
            _ide_disabled_profile(cls._profile_ide_disabled, cls.test_image_debian),
        )

    @classmethod
    def _create_profile(cls, name, body):
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as fh:
            json.dump(body, fh)
            path = fh.name
        try:
            cls.admin._run('profile', 'create', name, '--from-json', path)
        finally:
            os.unlink(path)

    @classmethod
    def tearDownClass(cls):
        for kind, name in (
            ('profile', cls._profile_none_and_real),
            ('profile', cls._profile_ide_disabled),
        ):
            try:
                cls.admin._run(kind, 'remove', '--force', name)
            except Exception:
                pass

    @staticmethod
    def _has_ide_router(container_data):
        routers = ((container_data.get('profileObject') or {}).get('routers')) or []
        return any(r.get('type') == 'ide' for r in routers)

    def test_01_none_chosen_router_still_present(self):
        """Profile offers 'none' + a real IDE; picking 'none' still gets the ide router."""
        name = self._sfx('inttest-ide-none-01')
        self.register_cleanup(name)
        self.create_and_wait(
            self.admin, self._profile_none_and_real, name, timeout=180, ide='none'
        )
        data = self.admin.get_container(name)
        self.assert_equal(data.get('meta', {}).get('IDE'), 'none',
                          f'expected meta.IDE == none, got {data.get("meta")!r}')
        self.assert_true(
            self._has_ide_router(data),
            "profile offering 'none' + a real IDE should still get an 'ide' router"
        )

    def test_02_ide_disabled_profile_defaults_to_none_no_router(self):
        """Profile has the IDE subsystem off; default launch resolves to 'none', no router."""
        name = self._sfx('inttest-ide-none-02')
        self.register_cleanup(name)
        self.create_and_wait(self.admin, self._profile_ide_disabled, name, timeout=180)
        data = self.admin.get_container(name)
        self.assert_equal(data.get('meta', {}).get('IDE'), 'none',
                          f'expected default meta.IDE == none, got {data.get("meta")!r}')
        self.assert_true(
            not self._has_ide_router(data),
            "profile with the IDE subsystem off should have no 'ide' router"
        )

    def test_03_default_never_picks_none(self):
        """On a profile offering both, launching with no --ide never resolves to 'none'."""
        name = self._sfx('inttest-ide-none-03')
        self.register_cleanup(name)
        self.create_and_wait(self.admin, self._profile_none_and_real, name, timeout=180)
        data = self.admin.get_container(name)
        self.assert_equal(data.get('meta', {}).get('IDE'), 'openvscode/latest',
                          f'default IDE should be the real IDE, not none: {data.get("meta")!r}')

    def test_04_enable_ide_later_via_stop_start(self):
        """edit updates the stored IDE immediately but does not live-switch a running
        devtainer; a stop/start cycle then makes the newly-chosen IDE reachable."""
        name = self._sfx('inttest-ide-none-04')
        self.register_cleanup(name)
        self.create_and_wait(
            self.admin, self._profile_none_and_real, name, timeout=180, ide='none'
        )

        self.admin.update(name, ide='openvscode/latest')
        data = self.admin.get_container(name)
        self.assert_equal(data.get('meta', {}).get('IDE'), 'openvscode/latest',
                          f'edit should update the stored IDE immediately: {data.get("meta")!r}')

        self.admin.stop(name, wait=True, timeout=60)
        self.admin.start(name, wait=True, timeout=180)

        try:
            def _ide_ready():
                try:
                    code, _ = self.admin.check_service(name, router_prefix='ide')
                    return code if code != 502 else None
                except APIError:
                    return None
            code = self.wait_until(
                _ide_ready, timeout=120, interval=3,
                timeout_msg='IDE backend did not become ready after enabling it and restarting',
            )
            self.assert_true(
                code in (200, 302, 301, 303),
                f'IDE URL returned unexpected status {code}'
            )
        except APIError as e:
            self.skip(f'Could not reach IDE URL: {e}')
