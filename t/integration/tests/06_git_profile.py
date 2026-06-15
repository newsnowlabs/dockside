"""
06_git_profile.py — Git URL, branch, and PR options

Coverage:
  - launch accepts a gitURL for the example 03-git-repo profile
  - launch accepts branch / PR profile options
  - launch accepts alternate allowed images for the profile
  - launch writes the owner's git name/email into ~/.gitconfig
  - launch clones the requested repo into the unix user's home directory
  - explicit branch / PR launch options affect the resulting checkout state
"""

import sys
import os
import json
import subprocess
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError, CapabilityUnavailable
sys.path.insert(0, os.path.dirname(__file__))
from _ssh_test_common import _DEV1_KEY, run_in_devtainer

GIT_URL = 'https://github.com/newsnowlabs/dockside.git'
GH_REPO = 'newsnowlabs/dockside'  # owner/repo for `gh -R` PR queries
EXPLICIT_BRANCH = 'gh-pages'
EXPLICIT_PR = '40'  # closed PR from claude/login-use-current-server-pzpOa → main
GITHUB_TOKEN = os.environ.get('DOCKSIDE_TEST_GITHUB_TOKEN', '')
REPO_DIR = '/home/dockside/dockside'
HOME_DIR = '/home/dockside'


class GitProfileTests(TestCase):
    """Test creating devtainers with git URL, branch, and PR options."""

    _INSPECT_SCRIPT = (
        'home="' + HOME_DIR + '"; repo="' + REPO_DIR + '"; '
        'git_bin="${DOCKSIDE_TEST_SYSTEM_BIN_DIR:-/opt/dockside/system/latest/bin}/git"; '
        '[ -x "$git_bin" ] || git_bin=git; '
        'printf "git_ready=%s\\n" "$(test -f /tmp/dockside/.git-repo-ready && echo 1 || echo 0)"; '
        'printf "git_failed=%s\\n" "$(test -f /tmp/dockside/.git-repo-failed && echo 1 || echo 0)"; '
        'printf "gitconfig_name=%s\\n" "$("$git_bin" config -f "$home/.gitconfig" --get user.name 2>/dev/null || true)"; '
        'printf "gitconfig_email=%s\\n" "$("$git_bin" config -f "$home/.gitconfig" --get user.email 2>/dev/null || true)"; '
        'printf "repo_exists=%s\\n" "$(test -d "$repo/.git" && echo 1 || echo 0)"; '
        'printf "origin_url=%s\\n" "$("$git_bin" -C "$repo" remote get-url origin 2>/dev/null || true)"; '
        'printf "branch=%s\\n" "$("$git_bin" -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"; '
        'printf "head_ref=%s\\n" "$(cat "$repo/.git/HEAD" 2>/dev/null || true)"'
    )

    def _debug(self, msg):
        if os.environ.get('DOCKSIDE_TEST_DEBUG', '').strip() == '1':
            print(f'# DEBUG [06_git_profile] {msg}', file=sys.stderr)

    def _create_git_container(self, name, **fields):
        self._debug(f'create start name={name} fields={fields!r}')
        self.register_cleanup(name)
        result = self.dev1.create(
            profile=self.test_profile_git,
            name=name,
            gitURL=GIT_URL,
            **fields,
        )
        self.assert_true(result is not None)
        self.wait_running(self.dev1, name, timeout=120)
        self._debug(f'create running name={name}')
        data = self.dev1.get_container(name)
        git_url = ((data.get('data') or {}).get('gitURL')
                   or data.get('gitURL')
                   or (data.get('meta') or {}).get('gitURL'))
        self.assert_true(git_url is not None, 'gitURL not stored in container data')
        return data

    def _inspect_git_state(self, name):
        self._debug(f'inspect start name={name}')
        try:
            result = run_in_devtainer(
                self.dev1,
                name,
                ['bash', '-lc', self._INSPECT_SCRIPT],
                private_key_path=_DEV1_KEY,
                preferred=('docker' if self.test_mode in ('local', 'harness') else 'ssh'),
                system_bin_dir=self.test_system_bin_dir,
                run_as_user='dockside',
            )
        except CapabilityUnavailable as exc:
            # CapabilityUnavailable = the container-access mechanism is genuinely
            # unavailable (docker/ssh/wstunnel or key missing) — a legitimate skip. A
            # plain APIError (e.g. a container-id or proxy/config regression), a
            # TimeoutExpired, or any other error while inspecting an already-running
            # container now propagates and fails rather than being skipped.
            self.skip(str(exc))
        self._debug(
            f'inspect done name={name} rc={result.returncode} '
            f'stdout_len={len(result.stdout)} stderr_len={len(result.stderr)}'
        )
        if result.returncode != 0:
            self._debug(f'inspect non-zero rc={result.returncode}; retrying')
            return {}
        out = {}
        for line in result.stdout.splitlines():
            if '=' in line:
                key, value = line.split('=', 1)
                out[key.strip()] = value.strip()
        self._debug(
            'inspect state name=%s gitconfig_name=%r gitconfig_email=%r '
            'repo_exists=%r origin_url=%r branch=%r head_ref=%r' % (
                name,
                out.get('gitconfig_name'),
                out.get('gitconfig_email'),
                out.get('repo_exists'),
                out.get('origin_url'),
                out.get('branch'),
                out.get('head_ref'),
            )
        )
        return out

    def _wait_git_state(self, name, predicate, timeout_msg, timeout=30):
        self._debug(f'wait state start name={name} timeout={timeout}')

        def _check():
            state = self._inspect_git_state(name)
            # launch.sh writes .git-repo-failed when a requested branch/PR checkout
            # fails; fail fast on it instead of waiting out the timeout.
            if state.get('git_failed') == '1':
                raise AssertionError(
                    f'repo setup reported failure (.git-repo-failed) for {name!r}; '
                    f'state={state!r}')
            return state if predicate(state) else False

        return self.wait_until(
            _check,
            timeout=timeout,
            interval=1,
            timeout_msg=timeout_msg,
        )

    def _verify_pr_head(self, name):
        """Return (head_sha, pr_head_oid) from inside the devtainer.

        head_sha is the checked-out HEAD commit; pr_head_oid is the requested PR's head
        commit read via gh (against GH_REPO, independent of local branch state). When
        they match, the devtainer genuinely checked out that PR rather than just some
        non-main ref. Both reads run gh/git *inside the devtainer* on purpose: the PR
        checkout itself relies on gh working there, so a gh that cannot read the PR head
        is a real failure (handled by the caller), not a reason to skip.
        """
        script = (
            'repo="' + REPO_DIR + '"; '
            'git_bin="${DOCKSIDE_TEST_SYSTEM_BIN_DIR:-/opt/dockside/system/latest/bin}/git"; '
            '[ -x "$git_bin" ] || git_bin=git; '
            'gh_bin="${DOCKSIDE_TEST_SYSTEM_BIN_DIR:-/opt/dockside/system/latest/bin}/gh"; '
            '[ -x "$gh_bin" ] || gh_bin=gh; '
            'printf "head_sha=%s\\n" "$("$git_bin" -C "$repo" rev-parse HEAD 2>/dev/null || true)"; '
            'printf "pr_head_oid=%s\\n" "$(GH_PAGER=cat "$gh_bin" -R ' + GH_REPO
            + ' pr view ' + EXPLICIT_PR + ' --json headRefOid -q .headRefOid 2>/dev/null || true)"'
        )
        try:
            result = run_in_devtainer(
                self.dev1, name, ['bash', '-lc', script],
                private_key_path=_DEV1_KEY,
                preferred=('docker' if self.test_mode in ('local', 'harness') else 'ssh'),
                system_bin_dir=self.test_system_bin_dir,
                run_as_user='dockside',
            )
        except (APIError, subprocess.TimeoutExpired) as exc:
            raise AssertionError(
                f'could not exec gh/git inside the devtainer to verify the PR head: {exc}'
            )
        out = {}
        for line in result.stdout.splitlines():
            if '=' in line:
                key, value = line.split('=', 1)
                out[key.strip()] = value.strip()
        self._debug(f'pr head check name={name} {out!r}')
        return out.get('head_sha', ''), out.get('pr_head_oid', '')

    def _assert_gitconfig(self, state):
        self.assert_equal(state.get('gitconfig_name'), 'Integration Test Dev 1')
        self.assert_equal(state.get('gitconfig_email'), 'inttest-dev1@dockside-integration-test.invalid')

    def _normalize_git_url(self, url):
        return (url or '').rstrip('/')

    def test_01_create_with_git_url(self):
        name = self._sfx('inttest-git-01')
        self._create_git_container(name)
        state = self._wait_git_state(
            name,
            lambda s: (s.get('git_ready') == '1'
                       and s.get('repo_exists') == '1'
                       and bool(s.get('gitconfig_name'))
                       and bool(s.get('origin_url'))
                       and s.get('branch') not in ('', 'HEAD')),
            'git repo and .gitconfig did not appear',
        )
        self._assert_gitconfig(state)
        self.assert_equal(
            self._normalize_git_url(state.get('origin_url')),
            self._normalize_git_url(GIT_URL),
        )
        self.assert_equal(state.get('branch'), 'main')

    def test_02_create_with_branch_option(self):
        name = self._sfx('inttest-git-branch')
        self._create_git_container(
            name,
            options=json.dumps({'branch': EXPLICIT_BRANCH}),
        )
        state = self._wait_git_state(
            name,
            lambda s: s.get('git_ready') == '1' and s.get('branch') == EXPLICIT_BRANCH,
            f'branch {EXPLICIT_BRANCH!r} checkout did not complete',
            timeout=60,
        )
        self._assert_gitconfig(state)
        self.assert_equal(
            self._normalize_git_url(state.get('origin_url')),
            self._normalize_git_url(GIT_URL),
        )

    def test_03_create_with_pr_option(self):
        if not GITHUB_TOKEN:
            self.skip('DOCKSIDE_TEST_GITHUB_TOKEN not set')
        name = self._sfx('inttest-git-pr')
        self._create_git_container(
            name,
            options=json.dumps({'pr': EXPLICIT_PR, 'gh_token': GITHUB_TOKEN}),
        )
        state = self._wait_git_state(
            name,
            lambda s: (s.get('git_ready') == '1'
                       and s.get('repo_exists') == '1'
                       and s.get('head_ref') not in ('', 'ref: refs/heads/main')),
            'PR checkout did not move HEAD away from the default branch ref',
            timeout=60,
        )
        self._assert_gitconfig(state)
        self.assert_equal(
            self._normalize_git_url(state.get('origin_url')),
            self._normalize_git_url(GIT_URL),
        )
        # The "HEAD moved off main" wait above is necessary but weak — any branch or
        # commit would satisfy it. Confirm via gh that HEAD is actually PR EXPLICIT_PR's
        # head commit, so a checkout of the wrong PR/branch is caught.
        head_sha, pr_head_oid = self._verify_pr_head(name)
        # An empty pr_head_oid means gh could not read the PR head inside the
        # devtainer — but the PR checkout itself relies on gh working there, so this
        # is a failure (gh broken/unauthenticated), not a reason to skip and leave
        # the weak "HEAD moved off main" check as the only coverage.
        self.assert_true(
            pr_head_oid,
            f'gh could not read PR {EXPLICIT_PR} head oid inside the devtainer — the '
            f'PR cannot have been checked out (gh unavailable/unauthenticated there)',
        )
        self.assert_true(
            head_sha and head_sha == pr_head_oid,
            f'devtainer HEAD {head_sha!r} is not PR {EXPLICIT_PR} head {pr_head_oid!r}',
        )

    def test_04_create_debian_with_git_url(self):
        name = self._sfx('inttest-git-debian')
        self.register_cleanup(name)
        result = self.dev1.create(
            profile=self.test_profile_git,
            name=name,
            gitURL=GIT_URL,
            image=self.test_image_debian,
        )
        self.assert_true(result is not None)

    def test_05_create_ubuntu_with_git_url(self):
        name = self._sfx('inttest-git-ubuntu')
        self.register_cleanup(name)
        result = self.dev1.create(
            profile=self.test_profile_git,
            name=name,
            gitURL=GIT_URL,
            image=self.test_image_ubuntu,
        )
        self.assert_true(result is not None)
