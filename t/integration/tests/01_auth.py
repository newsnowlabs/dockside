"""
01_auth.py — Authentication and permission checks
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError

PROFILE_NAME = '10-alpine'


class AuthTests(TestCase):
    """Authentication and basic permission checks."""

    def test_01_admin_can_list(self):
        result = self.admin.list_containers()
        self.assert_true(isinstance(result, list), 'admin list should return a list')

    def test_02_dev1_can_list(self):
        result = self.dev1.list_containers()
        self.assert_true(isinstance(result, list), 'dev1 list should return a list')

    def test_03_dev2_can_list(self):
        result = self.dev2.list_containers()
        self.assert_true(isinstance(result, list), 'dev2 list should return a list')

    def test_04_viewer_can_list(self):
        result = self.viewer.list_containers()
        self.assert_true(isinstance(result, list), 'viewer list should return a list')

    def test_05_unauthenticated_list_fails(self):
        # unauth client is None — simulate by using wrong credentials
        # Create a temporary client with bad credentials
        from dockside_test import DocksideClient
        import os
        bad = DocksideClient(
            cli_path=self.admin._cli,
            server_url=self.admin._server,
            username='nobody',
            password='wrongpass',
            connect_to=self.admin._connect_to,
            verify_ssl=self.admin._verify_ssl,
        )
        self.assert_api_error(bad.list_containers)
        bad.cleanup()

    def test_06_unauthenticated_create_fails(self):
        from dockside_test import DocksideClient
        bad = DocksideClient(
            cli_path=self.admin._cli,
            server_url=self.admin._server,
            username='nobody',
            password='wrongpass',
            connect_to=self.admin._connect_to,
            verify_ssl=self.admin._verify_ssl,
        )
        self.assert_api_error(
            bad.create, profile=PROFILE_NAME, name='inttest-noauth-create'
        )
        bad.cleanup()

    def test_07_viewer_cannot_create(self):
        # testviewer has no createContainerReservation permission
        self.assert_api_error(
            self.viewer.create,
            profile=PROFILE_NAME,
            name='inttest-viewer-create-fail',
        )
