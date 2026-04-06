"""
06_git_profile.py — Git URL, branch, and PR options

Current coverage:
  - launch accepts a gitURL for the example 03-git-repo profile
  - launch accepts branch / PR profile options
  - launch accepts alternate allowed images for the profile
  - gitURL is stored in the resulting reservation data

This does not yet verify the contents of the launched devtainer, only that the
launch-time API and profile wiring accept and persist these fields.

Possible future extension:
  - in local / harness mode, inspect the running devtainer with docker exec and
    assert the expected repository and checkout state
  - in remote mode, do the same over SSH when the 09_ssh.py prerequisites are
    available
  - verify:
      * default-branch checkout
      * explicit branch checkout
      * explicit PR checkout
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError

PROFILE_NAME = '03-git-repo'
GIT_URL = 'https://github.com/newsnowlabs/dockside.git'


class GitProfileTests(TestCase):
    """Test creating devtainers with git URL, branch, and PR options."""

    def test_01_create_with_git_url(self):
        name = self._sfx('inttest-git-01')
        self.register_cleanup(name)
        result = self.admin.create(
            profile=PROFILE_NAME,
            name=name,
            gitURL=GIT_URL,
        )
        self.assert_true(result is not None)
        data = self.admin.get_container(name)
        git_url = ((data.get('data') or {}).get('gitURL')
                   or data.get('gitURL')
                   or (data.get('meta') or {}).get('gitURL'))
        self.assert_true(git_url is not None, 'gitURL not stored in container data')

    def test_02_create_with_branch_option(self):
        name = self._sfx('inttest-git-branch')
        self.register_cleanup(name)
        import json
        result = self.admin.create(
            profile=PROFILE_NAME,
            name=name,
            gitURL=GIT_URL,
            options=json.dumps({'branch': 'main'}),
        )
        self.assert_true(result is not None)

    def test_03_create_with_pr_option(self):
        name = self._sfx('inttest-git-pr')
        self.register_cleanup(name)
        import json
        result = self.admin.create(
            profile=PROFILE_NAME,
            name=name,
            gitURL=GIT_URL,
            options=json.dumps({'pr': '1'}),
        )
        self.assert_true(result is not None)

    def test_04_create_debian_with_git_url(self):
        name = self._sfx('inttest-git-debian')
        self.register_cleanup(name)
        result = self.admin.create(
            profile=PROFILE_NAME,
            name=name,
            gitURL=GIT_URL,
            image='debian:latest',
        )
        self.assert_true(result is not None)

    def test_05_create_ubuntu_with_git_url(self):
        name = self._sfx('inttest-git-ubuntu')
        self.register_cleanup(name)
        result = self.admin.create(
            profile=PROFILE_NAME,
            name=name,
            gitURL=GIT_URL,
            image='ubuntu:latest',
        )
        self.assert_true(result is not None)
