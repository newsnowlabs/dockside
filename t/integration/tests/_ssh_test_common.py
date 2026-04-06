"""
Shared helpers for SSH integration tests.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager

from dockside_test import APIError

_INTEGRATION_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
_SSH_DIR = os.path.join(_INTEGRATION_DIR, 'config', 'ssh')
_DEV1_KEY = os.path.join(_SSH_DIR, 'testdev1_ed25519')
_DEV2_KEY = os.path.join(_SSH_DIR, 'testdev2_ed25519')

_BASE_SSH_CONTAINER = 'inttest-ssh-01'


def wstunnel_available():
    return shutil.which('wstunnel') is not None


def ssh_available():
    return shutil.which('ssh') is not None


def warn_missing_host_tool(tool_name):
    print(f'# WARNING: {tool_name} not found in PATH; SSH integration test will be skipped',
          file=sys.stderr)


def docker_available():
    try:
        result = subprocess.run(['docker', 'version'], capture_output=True, timeout=5)
        return result.returncode == 0
    except Exception:
        return False


def write_ssh_config(tmpdir, host_pattern, proxy_command, hostname, identity_file):
    """Write a temporary SSH config file and return its path."""
    config_path = os.path.join(tmpdir, 'ssh_config')
    with open(config_path, 'w') as fh:
        fh.write(f'Host {host_pattern}\n')
        fh.write(f'    ProxyCommand {proxy_command}\n')
        fh.write(f'    Hostname {hostname}\n')
        fh.write(f'    IdentityFile {identity_file}\n')
        fh.write('    IdentitiesOnly yes\n')
        fh.write('    PreferredAuthentications publickey\n')
        fh.write('    PasswordAuthentication no\n')
        fh.write('    KbdInteractiveAuthentication no\n')
        fh.write('    BatchMode yes\n')
        fh.write('    ForwardAgent yes\n')
        fh.write('    StrictHostKeyChecking no\n')
        fh.write('    UserKnownHostsFile /dev/null\n')
        fh.write('    LogLevel ERROR\n')
    os.chmod(config_path, 0o600)
    return config_path


def prepare_identity_file(tmpdir, source_path):
    """Copy a private key into tmpdir with restrictive permissions for ssh."""
    dest_path = os.path.join(tmpdir, os.path.basename(source_path))
    shutil.copyfile(source_path, dest_path)
    os.chmod(dest_path, 0o600)
    return dest_path


def debug_enabled():
    return os.environ.get('DOCKSIDE_TEST_DEBUG', '').strip() == '1'


def preserve_temp_enabled():
    return (
        debug_enabled() or
        os.environ.get('DOCKSIDE_TEST_SKIP_CLEANUP', '').strip() == '1'
    )


@contextmanager
def ssh_tempdir():
    """
    Yield a temp directory for generated SSH config.

    Preserve it when debugging or when the integration run is using
    --skip-cleanup, so the user can inspect the generated ssh_config.
    """
    if preserve_temp_enabled():
        tmpdir = tempfile.mkdtemp(prefix='dockside-ssh-')
        print(f'# DEBUG preserving ssh tempdir: {tmpdir}', file=sys.stderr)
        try:
            yield tmpdir
        finally:
            pass
        return

    with tempfile.TemporaryDirectory(prefix='dockside-ssh-') as tmpdir:
        yield tmpdir


def debug_ssh_command(argv, config_path):
    if not debug_enabled():
        return
    print(f'# DEBUG ssh-cmd: {" ".join(argv)}', file=sys.stderr)
    try:
        with open(config_path, 'r', encoding='utf-8') as fh:
            config_text = fh.read().rstrip()
    except OSError as exc:
        print(f'# DEBUG ssh-config read failed: {exc}', file=sys.stderr)
        return
    print('# DEBUG ssh-config begin', file=sys.stderr)
    for line in config_text.splitlines():
        print(f'# DEBUG {line}', file=sys.stderr)
    print('# DEBUG ssh-config end', file=sys.stderr)


class SshTestMixin:
    """Common container and routing helpers for SSH tests."""

    @classmethod
    def setUpClass(cls):
        cls.SSH_CONTAINER = cls._sfx(_BASE_SSH_CONTAINER)
        cls._setup_ssh_container()

    @classmethod
    def tearDownClass(cls):
        for fn in (
            lambda: cls.dev1.stop(cls.SSH_CONTAINER, wait=False),
            lambda: cls.dev1.remove(cls.SSH_CONTAINER, wait=False),
        ):
            try:
                fn()
            except Exception:
                pass

    @classmethod
    def _setup_ssh_container(cls):
        """Create and start the shared SSH test container (dev1 is owner)."""
        try:
            data = cls.dev1.get_container(cls.SSH_CONTAINER)
        except APIError:
            cls.dev1.create(
                profile=cls.test_profile_alpine,
                name=cls.SSH_CONTAINER,
            )
            data = cls.dev1.get_container(cls.SSH_CONTAINER)
        if data.get('status') != 1:
            cls.dev1.start(cls.SSH_CONTAINER, wait=True, timeout=120)
        deadline = time.time() + 20
        while time.time() < deadline:
            data = cls.dev1.get_container(cls.SSH_CONTAINER)
            if data.get('status') == 1:
                return
            time.sleep(1)
        raise AssertionError(f'SSH test container {cls.SSH_CONTAINER!r} did not reach running state')

    def _ensure_ssh_container(self):
        """Assert the shared SSH test container is still present and running."""
        data = self.dev1.get_container(self.SSH_CONTAINER)
        self.assert_true(bool(data), f'SSH test container {self.SSH_CONTAINER!r} missing')
        if data.get('status') != 1:
            raise AssertionError(f'SSH test container {self.SSH_CONTAINER!r} is not running')

    def _get_parent_fqdn(self):
        data = self.dev1.get_container(self.SSH_CONTAINER)
        return (data.get('data') or {}).get('parentFQDN') or data.get('parentFQDN')

    def _ssh_route_status(self, client):
        """Return the SSH router status code, or None if not yet reachable."""
        parent_fqdn = None if client._connect_to else self._get_parent_fqdn()
        try:
            code, _ = client.check_service(
                self.SSH_CONTAINER, router_prefix='ssh', parent_fqdn=parent_fqdn
            )
        except APIError:
            return None
        return code

    def _wait_ssh_route_status(self, client, expected_code, timeout=20):
        """Poll the SSH router until it returns expected_code."""
        self.wait_until(
            lambda: self._ssh_route_status(client) == expected_code,
            timeout=timeout,
            interval=1,
            timeout_msg=f'SSH route did not return {expected_code}',
        )

    def _wait_ssh_route_accessible(self, client, timeout=20):
        """Poll until the SSH router stops returning the denied code."""
        self.wait_until(
            lambda: (lambda code: code is not None and code != 410)(self._ssh_route_status(client)),
            timeout=timeout,
            interval=1,
            timeout_msg='SSH route did not become accessible',
        )
