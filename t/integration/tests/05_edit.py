"""
05_edit.py — Edit metadata; verify persistence
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError

_BASE_CONTAINER = 'inttest-edit-01'


class EditTests(TestCase):
    """Edit container metadata and verify changes persist.

    Each test creates the container fresh in setUp (idempotent) so tests are
    independent of each other.
    """

    def setUp(self):
        super().setUp()
        self.CONTAINER_NAME = self._sfx(_BASE_CONTAINER)
        self.register_cleanup(self.CONTAINER_NAME)
        try:
            self.admin.create(profile=self.test_profile_alpine, name=self.CONTAINER_NAME)
        except APIError as e:
            if 'already' not in str(e).lower() and 'exists' not in str(e).lower():
                raise

    def _get_meta(self, key):
        data = self.admin.get_container(self.CONTAINER_NAME)
        return (data.get('meta') or {}).get(key) or data.get(key)

    def test_01_edit_description(self):
        self.admin.update(self.CONTAINER_NAME, description='test description value')
        desc = self._get_meta('description')
        self.assert_equal(desc, 'test description value')

    def test_02_edit_viewers(self):
        self.admin.update(self.CONTAINER_NAME, viewers=self.test_username_viewer)
        viewers = self._get_meta('viewers')
        if isinstance(viewers, str):
            viewers = [v.strip() for v in viewers.split(',') if v.strip()]
        self.assert_in(self.test_username_viewer, viewers or [])

    def test_03_edit_developers(self):
        self.admin.update(self.CONTAINER_NAME, developers=self.test_username_dev1)
        devs = self._get_meta('developers')
        if isinstance(devs, str):
            devs = [d.strip() for d in devs.split(',') if d.strip()]
        self.assert_in(self.test_username_dev1, devs or [])

    def test_04_edit_combined(self):
        self.admin.update(self.CONTAINER_NAME,
                          description='combined edit',
                          viewers=self.test_username_viewer,
                          developers=self.test_username_dev1)
        data = self.admin.get_container(self.CONTAINER_NAME)
        meta = data.get('meta') or {}
        desc = meta.get('description') or data.get('description')
        self.assert_equal(desc, 'combined edit')

    def test_05_viewer_cannot_edit(self):
        self.admin.update(self.CONTAINER_NAME, viewers=self.test_username_viewer)
        self.assert_api_error(
            self.viewer.update, self.CONTAINER_NAME, description='viewer edit attempt'
        )

    def test_06_non_owner_developer_can_edit_allowed_fields(self):
        """After dev1 is added as developer, they can update description and viewers."""
        self.admin.update(self.CONTAINER_NAME, developers=self.test_username_dev1)
        self.dev1.update(self.CONTAINER_NAME, description='edited by dev1')
        data = self.admin.get_container(self.CONTAINER_NAME)
        meta = data.get('meta') or {}
        desc = meta.get('description') or data.get('description')
        self.assert_equal(desc, 'edited by dev1')

    def test_07_dev2_cannot_edit_when_not_developer(self):
        """dev2 not in developers list cannot edit."""
        self.admin.update(self.CONTAINER_NAME, developers=self.test_username_dev1)
        self.assert_api_error(
            self.dev2.update, self.CONTAINER_NAME, description='dev2 edit attempt'
        )
