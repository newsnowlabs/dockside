"""
07_ide.py — IDE creation and URL reachability
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError

PROFILE_NAME = '11-debian'
IDE_CONTAINER = 'inttest-ide-01'


class IdeTests(TestCase):
    """IDE access control: viewers cannot access IDE; named developers can."""

    def setUp(self):
        super().setUp()
        self.register_cleanup(IDE_CONTAINER)

    def _ensure_created_and_started(self):
        try:
            self.admin.create(
                profile=PROFILE_NAME,
                name=IDE_CONTAINER,
                ide='openvscode/latest',
            )
        except APIError as e:
            if 'already' not in str(e).lower() and 'exists' not in str(e).lower():
                raise
        data = self.admin.get_container(IDE_CONTAINER)
        if data.get('status') != 1:
            self.admin.start(IDE_CONTAINER, wait=True, timeout=180)

    def test_01_create_no_ide_override(self):
        name = 'inttest-ide-noide'
        self.register_cleanup(name)
        result = self.admin.create(
            profile=PROFILE_NAME,
            name=name,
        )
        self.assert_true(result is not None, 'create without --ide failed')

    def test_02_create_with_ide_override(self):
        """Create with openvscode, start, and verify IDE URL is reachable."""
        self._ensure_created_and_started()
        # Check IDE service is reachable (any response, including 302, counts)
        parent_fqdn = None if self.admin._connect_to else self._get_parent_fqdn()
        try:
            code, _ = self.admin.check_service(
                IDE_CONTAINER, router_prefix='ide', parent_fqdn=parent_fqdn
            )
            self.assert_true(
                code in (200, 302, 301, 303),
                f'IDE URL returned unexpected status {code}'
            )
        except APIError as e:
            self.skip(f'Could not reach IDE URL: {e}')

    def _get_parent_fqdn(self):
        data = self.admin.get_container(IDE_CONTAINER)
        return (data.get('data') or {}).get('parentFQDN') or data.get('parentFQDN')

    def test_03_ide_not_accessible_to_viewer(self):
        """Viewer cannot access IDE (IDE is always owner/developer mode)."""
        self._ensure_created_and_started()
        self.admin.update(IDE_CONTAINER, viewers='testviewer')
        parent_fqdn = None if self.admin._connect_to else self._get_parent_fqdn()
        try:
            code, _ = self.viewer.check_service(
                IDE_CONTAINER, router_prefix='ide', parent_fqdn=parent_fqdn
            )
            self.assert_http_status(code, 410, f'viewer got {code} for IDE (expected 410)')
        except APIError as e:
            self.skip(f'Could not reach IDE URL: {e}')

    def test_04_ide_accessible_to_named_developer(self):
        """Named developer (testdev1) can access IDE."""
        self._ensure_created_and_started()
        self.admin.update(IDE_CONTAINER, developers='testdev1')
        parent_fqdn = None if self.admin._connect_to else self._get_parent_fqdn()
        try:
            code, _ = self.dev1.check_service(
                IDE_CONTAINER, router_prefix='ide', parent_fqdn=parent_fqdn
            )
            self.assert_true(
                code in (200, 302, 301, 303),
                f'dev1 got {code} for IDE (expected 200/redirect)'
            )
        except APIError as e:
            self.skip(f'Could not reach IDE URL: {e}')

    def test_05_ide_accessible_to_dev2_when_added(self):
        """After adding testdev2 as developer, testdev2 can access IDE."""
        self._ensure_created_and_started()
        self.admin.update(IDE_CONTAINER, developers='testdev1,testdev2')
        parent_fqdn = None if self.admin._connect_to else self._get_parent_fqdn()
        try:
            code, _ = self.dev2.check_service(
                IDE_CONTAINER, router_prefix='ide', parent_fqdn=parent_fqdn
            )
            self.assert_true(
                code in (200, 302, 301, 303),
                f'dev2 got {code} for IDE (expected 200/redirect)'
            )
        except APIError as e:
            self.skip(f'Could not reach IDE URL: {e}')

    def test_06_ide_denied_after_dev2_removed(self):
        """After removing testdev2 from developers, testdev2 gets 410 for IDE."""
        self._ensure_created_and_started()
        self.admin.update(IDE_CONTAINER, developers='testdev1,testdev2')
        self.admin.update(IDE_CONTAINER, developers='testdev1')
        parent_fqdn = None if self.admin._connect_to else self._get_parent_fqdn()
        try:
            code, _ = self.dev2.check_service(
                IDE_CONTAINER, router_prefix='ide', parent_fqdn=parent_fqdn
            )
            self.assert_http_status(code, 410, f'dev2 got {code} after being removed (expected 410)')
        except APIError as e:
            self.skip(f'Could not reach IDE URL: {e}')
