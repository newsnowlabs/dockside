"""
06_git_profile.py — Git URL, branch, and PR options
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError

GIT_URL = 'https://github.com/newsnowlabs/dockside.git'


class GitProfileTests(TestCase):
    """Test creating devtainers with git URL, branch, and PR options."""

    def setUp(self):
        super().setUp()

    def test_01_create_with_git_url(self):
        name = 'inttest-git-01'
        self.register_cleanup(name)
        result = self.admin.create(
            profile='Git Repo (Branch/PR)',
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
        name = 'inttest-git-branch'
        self.register_cleanup(name)
        import json
        result = self.admin.create(
            profile='Git Repo (Branch/PR)',
            name=name,
            gitURL=GIT_URL,
            options=json.dumps({'branch': 'main'}),
        )
        self.assert_true(result is not None)

    def test_03_create_with_pr_option(self):
        name = 'inttest-git-pr'
        self.register_cleanup(name)
        import json
        result = self.admin.create(
            profile='Git Repo (Branch/PR)',
            name=name,
            gitURL=GIT_URL,
            options=json.dumps({'pr': '1'}),
        )
        self.assert_true(result is not None)

    def test_04_create_debian_with_git_url(self):
        name = 'inttest-git-debian'
        self.register_cleanup(name)
        result = self.admin.create(
            profile='Git Repo (Branch/PR)',
            name=name,
            gitURL=GIT_URL,
            image='debian:latest',
        )
        self.assert_true(result is not None)

    def test_05_create_ubuntu_with_git_url(self):
        name = 'inttest-git-ubuntu'
        self.register_cleanup(name)
        result = self.admin.create(
            profile='Git Repo (Branch/PR)',
            name=name,
            gitURL=GIT_URL,
            image='ubuntu:latest',
        )
        self.assert_true(result is not None)
