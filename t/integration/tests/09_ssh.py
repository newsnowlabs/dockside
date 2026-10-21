"""
09_ssh.py — SSH access tests (inbound via wstunnel)

Test A — Inbound SSH via wstunnel ProxyCommand:
  Prerequisites: wstunnel binary in PATH
  Skipped per-test if wstunnel not found.

Test B — wstunnel v10 CLI surfaces (exec-proxy / ssh config):
  Wildcard/per-devtainer `ssh config` generation and the exec-proxy
  path-traversal guard are pure CLI checks (no ssh/wstunnel needed); the
  headers-file permission check reuses a live connection like Test A.

Test C — wstunnel headers file lifetime across login/logout:
  `dockside ssh` and exec-proxy reuse a cached headers file (holding the
  session Cookie) for as long as it exists, so login and logout must remove
  it.  Runs as dev1 in a private CLI config directory, leaving the system
  config's stored sessions untouched.

The committed test-only Ed25519 keypairs are in:
  t/integration/config/ssh/testdev1_ed25519{,.pub}
  t/integration/config/ssh/testdev2_ed25519{,.pub}
"""

import os
import re
import stat
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))
from dockside_test import TestCase, APIError
from _ssh_test_common import (
    SshTestMixin,
    _DEV1_KEY,
    _DEV2_KEY,
    run_host_ssh_via_cli_config,
    ssh_available,
    warn_missing_host_tool,
    wstunnel_available,
)

_WSTUNNEL_HEADERS_DIR = os.path.join(
    os.path.expanduser('~'), '.config', 'dockside', 'wstunnel'
)


class SshTests(SshTestMixin, TestCase):
    """Inbound SSH via wstunnel ProxyCommand."""

    # ── Test A: Inbound SSH via wstunnel ──────────────────────────────────────

    def test_01_owner_ssh_via_wstunnel(self):
        """dev1 (owner) can SSH into their devtainer via wstunnel."""
        if not ssh_available():
            warn_missing_host_tool('ssh')
            self.skip('ssh not in PATH')
        if not wstunnel_available():
            warn_missing_host_tool('wstunnel')
            self.skip('wstunnel not in PATH')
        if not os.path.isfile(_DEV1_KEY):
            self.skip(f'testdev1 key not found at {_DEV1_KEY}')

        self._ensure_ssh_container()

        r = run_host_ssh_via_cli_config(
            self.dev1, self.SSH_CONTAINER, _DEV1_KEY, ['echo', 'hello']
        )
        self.assert_equal(r.stdout.strip(), 'hello',
                          f'SSH did not return hello; rc={r.returncode} '
                          f'stderr={r.stderr!r} stdout={r.stdout!r}')

    def test_02_ssh_proxy_denied_to_non_developer(self):
        """dev2 (not in developers) gets 410 from SSH router."""
        self._ensure_ssh_container()
        try:
            self.dev1.update(self.SSH_CONTAINER, developers='')
        except APIError:
            pass
        self._wait_ssh_route_status(self.dev2, 410, timeout=20)

    def test_03_add_dev2_and_ssh_connects(self):
        """After adding dev2 as developer, they can SSH in with their key."""
        if not ssh_available():
            warn_missing_host_tool('ssh')
            self.skip('ssh not in PATH')
        if not wstunnel_available():
            warn_missing_host_tool('wstunnel')
            self.skip('wstunnel not in PATH')
        if not os.path.isfile(_DEV2_KEY):
            self.skip(f'testdev2 key not found at {_DEV2_KEY}')

        self._ensure_ssh_container()

        self.dev1.update(self.SSH_CONTAINER, developers=self.test_username_dev2)
        self._wait_ssh_route_accessible(self.dev2, timeout=20)

        r = run_host_ssh_via_cli_config(
            self.dev2, self.SSH_CONTAINER, _DEV2_KEY, ['echo', 'hello']
        )
        self.assert_equal(r.stdout.strip(), 'hello',
                          f'dev2 SSH failed; rc={r.returncode} '
                          f'stderr={r.stderr!r} stdout={r.stdout!r}')

    def test_04_remove_dev2_and_ssh_denied(self):
        """After removing dev2 from developers, SSH proxy returns 410."""
        self._ensure_ssh_container()
        self.dev1.update(self.SSH_CONTAINER, developers=self.test_username_dev2)
        self.dev1.update(self.SSH_CONTAINER, developers='')
        self._wait_ssh_route_status(self.dev2, 410, timeout=20)

    # ── Test B: wstunnel v10 CLI surfaces (exec-proxy / ssh config) ────────────
    #
    # These do not need ssh/wstunnel in PATH: `ssh config` and the exec-proxy
    # path-traversal guard are pure CLI text-generation / early-die checks, not
    # live wstunnel connections.

    def test_05_wildcard_ssh_config_block(self):
        """`dockside ssh config` (no devtainer) emits a wildcard exec-proxy block."""
        config_text = self.dev1.ssh_config()
        self.assert_true(
            re.search(r'^Host ssh-\*\S*$', config_text, re.MULTILINE) is not None,
            f'wildcard config missing a wildcard Host pattern: {config_text!r}'
        )
        # ProxyCommand embeds the resolved CLI path (not necessarily bare
        # 'dockside' — see _dockside_self_path), so match on the command's tail.
        self.assert_true(
            re.search(r'^\s*ProxyCommand .* ssh exec-proxy %n$', config_text, re.MULTILINE) is not None,
            f'wildcard config missing the exec-proxy ProxyCommand: {config_text!r}'
        )

    def test_06_wstunnel_flag_embedded_in_proxy_command(self):
        """--wstunnel PATH is embedded in both wildcard and per-devtainer configs."""
        self._ensure_ssh_container()
        custom_path = '/opt/custom/wstunnel'

        wildcard_text = self.dev1.ssh_config(wstunnel_binary=custom_path)
        self.assert_in(
            f'ssh --wstunnel {custom_path} exec-proxy %n', wildcard_text,
            f'--wstunnel override missing from wildcard config: {wildcard_text!r}'
        )

        per_devtainer_text = self.dev1.ssh_config(self.SSH_CONTAINER, wstunnel_binary=custom_path)
        self.assert_in(
            f'ssh --wstunnel {custom_path} exec-proxy %n', per_devtainer_text,
            f'--wstunnel override missing from per-devtainer config: {per_devtainer_text!r}'
        )

    def test_07_wstunnel_headers_file_permissions(self):
        """The wstunnel v10 headers file this module's connections wrote is 0600."""
        if not ssh_available():
            warn_missing_host_tool('ssh')
            self.skip('ssh not in PATH')
        if not wstunnel_available():
            warn_missing_host_tool('wstunnel')
            self.skip('wstunnel not in PATH')
        if not os.path.isfile(_DEV1_KEY):
            self.skip(f'testdev1 key not found at {_DEV1_KEY}')

        self._ensure_ssh_container()
        # Ensure at least one connection has happened in this run so a headers
        # file is guaranteed to exist (independent of test execution order).
        run_host_ssh_via_cli_config(
            self.dev1, self.SSH_CONTAINER, _DEV1_KEY, ['echo', 'hello']
        )

        self.assert_true(
            os.path.isdir(_WSTUNNEL_HEADERS_DIR),
            f'wstunnel headers directory missing: {_WSTUNNEL_HEADERS_DIR!r}'
        )
        entries = [
            os.path.join(_WSTUNNEL_HEADERS_DIR, name)
            for name in os.listdir(_WSTUNNEL_HEADERS_DIR)
        ]
        files = [p for p in entries if os.path.isfile(p)]
        self.assert_true(bool(files), f'no wstunnel headers files found in {_WSTUNNEL_HEADERS_DIR!r}')
        for path in files:
            mode = stat.S_IMODE(os.stat(path).st_mode)
            self.assert_equal(mode, 0o600,
                               f'wstunnel headers file {path!r} has mode {oct(mode)}, expected 0o600')

    def test_08_exec_proxy_rejects_path_traversal_alias(self):
        """exec-proxy refuses to write a headers file for a key containing '/'."""
        if not wstunnel_available():
            warn_missing_host_tool('wstunnel')
            self.skip('wstunnel not in PATH')

        wildcard_text = self.dev1.ssh_config()
        m = re.search(r'^Host (\S+)$', wildcard_text, re.MULTILINE)
        self.assert_true(bool(m), f'no Host line found in wildcard config: {wildcard_text!r}')
        # fnmatch's '*' matches '/' too, so this still resolves to the configured
        # server — it's the write step, not the server lookup, that must reject it.
        malicious_alias = m.group(1).replace('*', 'x/y', 1)

        try:
            self.dev1.ssh_exec_proxy_text(malicious_alias)
        except APIError as e:
            self.assert_in('path separators', str(e),
                            f'unexpected exec-proxy failure for {malicious_alias!r}: {e}')
        else:
            raise AssertionError(
                f'exec-proxy should have refused headers-file key from {malicious_alias!r}'
            )

    # ── Test C: wstunnel headers file lifetime across login/logout ────────────

    def test_09_login_and_logout_remove_stale_wstunnel_headers(self):
        """login/logout remove a stale headers file; the next connection rewrites it."""
        if not ssh_available():
            warn_missing_host_tool('ssh')
            self.skip('ssh not in PATH')
        if not wstunnel_available():
            warn_missing_host_tool('wstunnel')
            self.skip('wstunnel not in PATH')
        if not os.path.isfile(_DEV1_KEY):
            self.skip(f'testdev1 key not found at {_DEV1_KEY}')
        entry = self.admin.server_entry()
        if entry is None:
            self.skip('server under test is not a configured CLI server')
        if entry.get('parent'):
            self.skip('server under test is reached through a parent chain, '
                      'which an isolated CLI config cannot carry')

        self._ensure_ssh_container()
        iso = self.dev1.with_isolated_config()
        try:
            def login():
                iso.login(connect_to=entry.get('connect_to'),
                          no_verify=bool(entry.get('no_verify')))

            def ssh_hello():
                return run_host_ssh_via_cli_config(
                    iso, self.SSH_CONTAINER, _DEV1_KEY, ['echo', 'hello'])

            login()
            r = ssh_hello()
            self.assert_equal(r.stdout.strip(), 'hello',
                              f'SSH failed; rc={r.returncode} stderr={r.stderr!r}')
            files = iso.wstunnel_headers_files()
            self.assert_true(bool(files), 'connection wrote no wstunnel headers file')

            # Stand in for a session or globalCookie value the server no longer accepts.
            for path in files:
                with open(path) as fh:
                    lines = fh.read().splitlines()
                lines = [re.sub(r'^(Cookie: [^=]+=).*$', r'\1stale-integration-test-value', line)
                         for line in lines]
                with open(path, 'w') as fh:
                    fh.write('\n'.join(lines) + '\n')
            r = ssh_hello()
            self.assert_true(r.returncode != 0,
                             'SSH succeeded with a stale cookie in the headers file, so this '
                             f'test is not exercising the cached file; stdout={r.stdout!r}')

            login()
            self.assert_equal(iso.wstunnel_headers_files(), [],
                              'login left wstunnel headers files in place')
            r = ssh_hello()
            self.assert_equal(r.stdout.strip(), 'hello',
                              f'SSH failed after re-login; rc={r.returncode} stderr={r.stderr!r}')
            self.assert_true(bool(iso.wstunnel_headers_files()),
                             'connection after re-login wrote no wstunnel headers file')

            iso.logout()
            self.assert_equal(iso.wstunnel_headers_files(), [],
                              'logout left wstunnel headers files in place')
        finally:
            iso.cleanup()
