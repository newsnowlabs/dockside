"""
Shared helpers for SSH integration tests.
"""

import os
import shlex
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


def requested_container_access_method(default='auto'):
    value = os.environ.get('DOCKSIDE_TEST_CONTAINER_ACCESS', default).strip().lower()
    return value if value in ('auto', 'docker', 'ssh') else default


def devtainer_container_id(client, devtainer_name):
    if not docker_available():
        return None
    try:
        data = client.get_container(devtainer_name)
    except Exception:
        return None
    return (data.get('data') or {}).get('id') or data.get('containerId')


def write_ssh_config(tmpdir, host_pattern, proxy_command, hostname, identity_file, ssh_user=None):
    """Write a temporary SSH config file and return its path."""
    config_path = os.path.join(tmpdir, 'ssh_config')
    with open(config_path, 'w') as fh:
        fh.write(f'Host {host_pattern}\n')
        fh.write(f'    ProxyCommand {proxy_command}\n')
        fh.write(f'    Hostname {hostname}\n')
        if ssh_user:
            fh.write(f'    User {ssh_user}\n')
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


def write_cli_ssh_config(tmpdir, config_text):
    """Write CLI-generated ssh_config text plus strict test-only options."""
    config_path = os.path.join(tmpdir, 'ssh_config')
    with open(config_path, 'w', encoding='utf-8') as fh:
        fh.write(config_text.rstrip())
        fh.write('\n')
        fh.write('    IdentitiesOnly yes\n')
        fh.write('    PreferredAuthentications publickey\n')
        fh.write('    PasswordAuthentication no\n')
        fh.write('    KbdInteractiveAuthentication no\n')
        fh.write('    BatchMode yes\n')
        fh.write('    StrictHostKeyChecking no\n')
        fh.write('    UserKnownHostsFile /dev/null\n')
        fh.write('    LogLevel ERROR\n')
    os.chmod(config_path, 0o600)
    return config_path


def run_host_ssh_via_cli_config(client, devtainer, private_key_path, remote_argv):
    """
    Use the CLI's `ssh config` output plus strict test-only options to run ssh.

    Returns subprocess.CompletedProcess.
    """
    spec = client.ssh_proxy_spec(devtainer)
    ssh_alias = spec.get('ssh_alias')
    if not ssh_alias:
        raise APIError('CLI did not return a usable SSH alias')
    with ssh_tempdir() as tmpdir:
        identity_file = prepare_identity_file(tmpdir, private_key_path)
        config_text = client.ssh_config(
            devtainer,
            identity_file=identity_file,
            alias=ssh_alias,
        )
        config_path = write_cli_ssh_config(tmpdir, config_text)
        # Join with proper shell quoting so the remote shell sees each argument
        # as a distinct word.  Without this, bare semicolons in a bash -lc script
        # are interpreted by the remote /bin/sh before bash ever sees them.
        remote_cmd = ' '.join(shlex.quote(a) for a in list(remote_argv))
        argv = ['ssh', '-F', config_path, ssh_alias, remote_cmd]
        debug_ssh_command(argv, config_path)
        return subprocess.run(
            argv,
            capture_output=True, text=True, timeout=30
        )


def run_in_devtainer(client, devtainer, remote_argv, private_key_path=None,
                     preferred='auto', system_bin_dir=None, run_as_user=None):
    """
    Run a command inside a devtainer using docker exec or host-side SSH.

    preferred: auto|docker|ssh
    Returns subprocess.CompletedProcess.
    Raises APIError if no usable access method is available.
    """
    access = requested_container_access_method(preferred)
    devtainer_id = devtainer_container_id(client, devtainer)
    docker_possible = bool(devtainer_id)
    ssh_possible = (
        ssh_available()
        and wstunnel_available()
        and private_key_path
        and os.path.isfile(private_key_path)
    )

    if access == 'auto':
        access = 'docker' if docker_possible else 'ssh'

    actual_backend = None

    argv = list(remote_argv)
    docker_argv = ['docker', 'exec']
    if run_as_user:
        docker_argv.extend(['-u', run_as_user])
    if system_bin_dir:
        docker_argv.extend(['-e', 'DOCKSIDE_TEST_SYSTEM_BIN_DIR=%s' % system_bin_dir])
        argv = ['env', 'DOCKSIDE_TEST_SYSTEM_BIN_DIR=%s' % system_bin_dir] + argv
    docker_argv.extend([devtainer_id] + argv)

    if debug_enabled():
        print(
            '# DEBUG run_in_devtainer devtainer=%s preferred=%s chosen=%s '
            'docker_possible=%s ssh_possible=%s' % (
                devtainer,
                preferred,
                access,
                int(docker_possible),
                int(ssh_possible),
            ),
            file=sys.stderr,
        )

    def _debug_result(result, backend):
        if not debug_enabled():
            return
        print(
            f'# DEBUG run_in_devtainer result backend={backend} '
            f'rc={result.returncode} '
            f'stdout={result.stdout!r} '
            f'stderr={result.stderr!r}',
            file=sys.stderr,
        )

    if access == 'docker' and docker_possible:
        actual_backend = 'docker'
        if debug_enabled():
            print(f'# DEBUG run_in_devtainer backend={actual_backend} devtainer={devtainer}',
                  file=sys.stderr)
        r = subprocess.run(docker_argv, capture_output=True, text=True, timeout=30)
        _debug_result(r, actual_backend)
        return r
    if access == 'ssh' and ssh_possible:
        actual_backend = 'ssh'
        if debug_enabled():
            print(f'# DEBUG run_in_devtainer backend={actual_backend} devtainer={devtainer}',
                  file=sys.stderr)
        r = run_host_ssh_via_cli_config(client, devtainer, private_key_path, argv)
        _debug_result(r, actual_backend)
        return r
    if access == 'docker' and ssh_possible:
        actual_backend = 'ssh'
        if debug_enabled():
            print(f'# DEBUG run_in_devtainer fallback backend={actual_backend} devtainer={devtainer}',
                  file=sys.stderr)
        r = run_host_ssh_via_cli_config(client, devtainer, private_key_path, argv)
        _debug_result(r, actual_backend)
        return r
    if access == 'ssh' and docker_possible:
        actual_backend = 'docker'
        if debug_enabled():
            print(f'# DEBUG run_in_devtainer fallback backend={actual_backend} devtainer={devtainer}',
                  file=sys.stderr)
        r = subprocess.run(docker_argv, capture_output=True, text=True, timeout=30)
        _debug_result(r, actual_backend)
        return r

    if access == 'ssh':
        if not ssh_available():
            warn_missing_host_tool('ssh')
        if not wstunnel_available():
            warn_missing_host_tool('wstunnel')
        raise APIError('Requested SSH container access is unavailable')
    if access == 'docker':
        raise APIError('Requested docker-exec container access is unavailable')
    raise APIError('No usable container access method available')


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
        base = getattr(cls, '_BASE_SSH_CONTAINER', _BASE_SSH_CONTAINER)
        cls.SSH_CONTAINER = cls._sfx(base)
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

    def _ssh_route_status(self, client):
        """Return the SSH router status code, or None if not yet reachable."""
        try:
            ssh_url = self.dev1.service_url(self.SSH_CONTAINER, router_prefix='ssh')
            code, _ = client.check_url(ssh_url)
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
