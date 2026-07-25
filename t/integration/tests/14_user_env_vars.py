"""
14_user_env_vars.py — Per-user custom env vars, driven entirely through the CLI.

Covers the new `env` field on the user record: `{ KEY: { value, secret,
targets: { docker, ide, ssh } } }`, self- and admin-editable via the same
`--set env.KEY.*` / `--unset env.KEY` dotted-path mechanism already used for
`ssh.publicKeys.*`/`ssh.keypairs.*`.

  - EnvVarsApiTests: storage/API round-trips, secret masking + restore-on-
    unchanged-POST, validation rejections, self-vs-admin permission
    boundaries. No live container.
  - EnvVarsInjectionTests: launches a real devtainer and verifies each of the
    three injection targets independently — `docker create` (baked into the
    container's own env), `ide` (the IDE server process's own env, reached
    via apply_user_env surviving the launch.sh env -i wipe), and `ssh` (an
    actual SSH session, reached via the .bashrc/.profile rc-file snippet).

Out of scope here (browser-only, verified manually): confirming an env var is
visible inside an actual IDE terminal pane (as opposed to the IDE server
process's own environment, which EnvVarsInjectionTests.test_02 checks via
docker exec/proc) requires driving a live Theia/openvscode terminal in a
browser, which this CLI-only suite does not do (see t/integration/README.md
rule 4). This was instead verified live, out-of-band, against code-server
(the closest openly-installable VS-Code-Server-family distribution) and by
reading the actual shipped Theia terminal-spawning source — see the PR/commit
history for that investigation.
"""

import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import APIError, CapabilityUnavailable, TestCase
from _ssh_test_common import _DEV1_KEY, devtainer_container_id, docker_available, run_in_devtainer


class EnvVarsApiTests(TestCase):
    """Storage/API round-trips for the 'env' field (no live container)."""

    @classmethod
    def setUpClass(cls):
        cls._user          = cls._sfx('inttest-envvars-user')
        cls._user_password = 'inttest-envvars-pass'
        cls.admin._run('user', 'create', cls._user,
                       '--role', cls.test_role_developer,
                       '--user-password', cls._user_password,
                       '--name', 'Env Vars Test User')
        cls._user_client = cls.admin.with_credentials(cls._user, cls._user_password)

    @classmethod
    def tearDownClass(cls):
        try:
            cls.admin._run('user', 'remove', '--force', cls._user)
        except Exception:
            pass

    def test_01_basic_round_trip(self):
        self.admin._run(
            'user', 'edit', self._user,
            '--set', 'env.FOO.value=bar',
            '--set', 'env.FOO.secret=0',
            '--set', 'env.FOO.targets={"docker":true,"ide":true}',
        )
        rec = self.admin._run('user', 'get', self._user, '--sensitive')
        entry = ((rec or {}).get('env') or {}).get('FOO') or {}
        self.assert_equal(entry.get('value'), 'bar', f'env.FOO.value did not round-trip: {entry!r}')
        self.assert_true(not entry.get('secret'), f'env.FOO.secret unexpectedly truthy: {entry!r}')
        targets = entry.get('targets') or {}
        self.assert_true(bool(targets.get('docker')) and bool(targets.get('ide')),
                         f'env.FOO.targets did not round-trip: {targets!r}')
        self.assert_true(not targets.get('ssh'), f'env.FOO.targets.ssh unexpectedly set: {targets!r}')

    def test_02_unset(self):
        self.admin._run('user', 'edit', self._user, '--set', 'env.TOUNSET.value=x')
        rec = self.admin._run('user', 'get', self._user, '--sensitive')
        self.assert_in('TOUNSET', (rec.get('env') or {}), 'env.TOUNSET was not set')
        self.admin._run('user', 'edit', self._user, '--unset', 'env.TOUNSET')
        rec2 = self.admin._run('user', 'get', self._user, '--sensitive')
        self.assert_not_in('TOUNSET', (rec2.get('env') or {}), 'env.TOUNSET survived --unset')

    def test_03_secret_masking(self):
        self.admin._run(
            'user', 'edit', self._user,
            '--set', 'env.SECRETVAR.value=abcdefgh12345678',
            '--set', 'env.SECRETVAR.secret=1',
        )
        rec = self.admin._run('user', 'get', self._user)
        entry = ((rec or {}).get('env') or {}).get('SECRETVAR') or {}
        self.assert_true('*' in (entry.get('value') or ''),
                         f'SECRETVAR value was not masked in non-sensitive response: {entry!r}')
        rec_sensitive = self.admin._run('user', 'get', self._user, '--sensitive')
        entry_sensitive = ((rec_sensitive or {}).get('env') or {}).get('SECRETVAR') or {}
        self.assert_equal(entry_sensitive.get('value'), 'abcdefgh12345678',
                          f'SECRETVAR value was masked even with --sensitive: {entry_sensitive!r}')

    def test_04_secret_restore_on_unchanged_post(self):
        """_restore_redacted_env must not write the masked sentinel to disk."""
        self.admin._run(
            'user', 'edit', self._user,
            '--set', 'env.SECRETVAR2.value=IntTestRoundtrip0000000000000014',
            '--set', 'env.SECRETVAR2.secret=1',
        )
        masked = ((self.admin._run('user', 'get', self._user).get('env') or {}).get('SECRETVAR2') or {}).get('value')
        self.assert_true('*' in (masked or ''), f'SECRETVAR2 not masked: {masked!r}')

        # POST the masked value back — simulates a client round-tripping the record.
        self.admin._run('user', 'edit', self._user, '--set', f'env.SECRETVAR2.value={masked}')

        rec = self.admin._run('user', 'get', self._user, '--sensitive')
        stored = ((rec.get('env') or {}).get('SECRETVAR2') or {}).get('value')
        self.assert_equal(stored, 'IntTestRoundtrip0000000000000014',
                          f'SECRETVAR2 overwritten by masked sentinel: {stored!r}')

    def test_05_non_secret_asterisk_value_not_treated_as_sentinel(self):
        """A non-secret value containing '*' must not be misdetected as a masked sentinel."""
        self.admin._run(
            'user', 'edit', self._user,
            '--set', 'env.PCTVAR.value=50*discount',
            '--set', 'env.PCTVAR.secret=0',
        )
        rec = self.admin._run('user', 'get', self._user, '--sensitive')
        stored = ((rec.get('env') or {}).get('PCTVAR') or {}).get('value')
        self.assert_equal(stored, '50*discount', f'non-secret value mangled: {stored!r}')

    def test_06_reserved_name_rejected(self):
        self.assert_api_error(
            lambda: self.admin._run('user', 'edit', self._user, '--set', 'env.PATH.value=x'))
        self.assert_api_error(
            lambda: self.admin._run('user', 'edit', self._user, '--set', 'env.DOCKSIDE_FOO.value=x'))

    def test_07_malformed_key_rejected(self):
        self.assert_api_error(
            lambda: self.admin._run('user', 'edit', self._user, '--set', 'env.1BAD.value=x'))

    def test_08_value_with_newline_rejected(self):
        self.assert_api_error(
            lambda: self.admin._run('user', 'edit', self._user,
                                    '--set', 'env.BADNL.value=line1\nline2'))

    def test_09_too_many_vars_rejected(self):
        body = {'env': {f'VAR{i}': {'value': str(i), 'secret': False, 'targets': {}}
                        for i in range(51)}}
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as fh:
            json.dump(body, fh)
            path = fh.name
        try:
            self.assert_api_error(
                lambda: self.admin._run('user', 'edit', self._user, '--from-json', path))
        finally:
            os.unlink(path)

    def test_10_self_service_can_set_all_targets(self):
        client = self._user_client
        client._run(
            'account', 'edit',
            '--set', 'env.SELFVAR.value=self-set',
            '--set', 'env.SELFVAR.targets={"docker":true,"ide":true,"ssh":true}',
        )
        rec = client._run('account', 'show')
        targets = ((rec.get('env') or {}).get('SELFVAR') or {}).get('targets') or {}
        self.assert_true(all(targets.get(t) for t in ('docker', 'ide', 'ssh')),
                         f'self-service could not set all three targets: {targets!r}')

    def test_11_self_service_cannot_set_other_users_env(self):
        client = self._user_client
        self.assert_api_error(
            lambda: client._run('user', 'edit', 'admin', '--set', 'env.HACK.value=x'))

    def test_12_debug_reserved(self):
        self.assert_api_error(
            lambda: self.admin._run('user', 'edit', self._user, '--set', 'env.DEBUG.value=1'))

    def test_13_new_secret_value_containing_asterisk_not_deleted(self):
        """A brand-new secret var whose real value contains '*' must not be
        misdetected as an unchanged-masked sentinel and silently dropped."""
        self.admin._run(
            'user', 'edit', self._user,
            '--set', 'env.STARSECRET.value=ab*cdefgh',
            '--set', 'env.STARSECRET.secret=1',
        )
        rec = self.admin._run('user', 'get', self._user, '--sensitive')
        entry = ((rec or {}).get('env') or {}).get('STARSECRET')
        self.assert_true(entry is not None, 'STARSECRET was silently deleted (masked-sentinel misdetection)')
        self.assert_equal(entry.get('value'), 'ab*cdefgh', f'STARSECRET value corrupted: {entry!r}')

    def test_14_secret_value_changed_to_new_asterisk_value_not_reverted(self):
        """Changing an existing secret to a new value that happens to contain
        '*' must persist the new value, not revert to the old one."""
        self.admin._run(
            'user', 'edit', self._user,
            '--set', 'env.STARSECRET2.value=originalvalue123',
            '--set', 'env.STARSECRET2.secret=1',
        )
        self.admin._run('user', 'edit', self._user, '--set', 'env.STARSECRET2.value=new*value456')
        rec = self.admin._run('user', 'get', self._user, '--sensitive')
        stored = ((rec.get('env') or {}).get('STARSECRET2') or {}).get('value')
        self.assert_equal(stored, 'new*value456', f'STARSECRET2 update was reverted to old value: {stored!r}')

    def test_15_secret_toggle_off_with_masked_value_restores_real_value(self):
        """Toggling secret->non-secret while re-posting the untouched masked
        string must restore the real value, not persist the mask itself."""
        self.admin._run(
            'user', 'edit', self._user,
            '--set', 'env.TOGGLEVAR.value=ToggleRealValue0000000000042',
            '--set', 'env.TOGGLEVAR.secret=1',
        )
        masked = ((self.admin._run('user', 'get', self._user).get('env') or {}).get('TOGGLEVAR') or {}).get('value')
        self.assert_true('*' in (masked or ''), f'TOGGLEVAR not masked: {masked!r}')

        self.admin._run(
            'user', 'edit', self._user,
            '--set', f'env.TOGGLEVAR.value={masked}',
            '--set', 'env.TOGGLEVAR.secret=0',
        )
        rec = self.admin._run('user', 'get', self._user, '--sensitive')
        stored = ((rec.get('env') or {}).get('TOGGLEVAR') or {}).get('value')
        self.assert_equal(stored, 'ToggleRealValue0000000000042',
                          f'toggling secret off persisted the mask instead of the real value: {stored!r}')

    def test_16_non_scalar_value_rejected(self):
        body = {'env': {'BADVALUE': {'value': {'nested': 'obj'}, 'secret': False, 'targets': {}}}}
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as fh:
            json.dump(body, fh)
            path = fh.name
        try:
            self.assert_api_error(
                lambda: self.admin._run('user', 'edit', self._user, '--from-json', path))
        finally:
            os.unlink(path)

    def test_17_non_boolean_target_value_rejected(self):
        """A JSON string "false" is Perl-truthy; the server must reject it
        rather than silently treat the target as enabled."""
        self.assert_api_error(
            lambda: self.admin._run(
                'user', 'edit', self._user,
                '--set', 'env.BADTARGET.value=x',
                '--set', 'env.BADTARGET.targets={"docker":"false"}',
            ))

    def test_18_unknown_target_key_rejected(self):
        self.assert_api_error(
            lambda: self.admin._run(
                'user', 'edit', self._user,
                '--set', 'env.BADTARGETKEY.value=x',
                '--set', 'env.BADTARGETKEY.targets={"nope":true}',
            ))

    def test_19_overlong_key_rejected(self):
        long_key = 'A' * 129
        self.assert_api_error(
            lambda: self.admin._run('user', 'edit', self._user, '--set', f'env.{long_key}.value=x'))

    def test_20_overlong_value_rejected(self):
        long_value = 'x' * 4097
        self.assert_api_error(
            lambda: self.admin._run('user', 'edit', self._user, '--set', f'env.OVERLONGVAL.value={long_value}'))

    def test_21_aggregate_ide_ssh_blob_size_rejected(self):
        """Per-var limits (50 vars x 4096 bytes) alone would allow a combined
        ide+ssh blob larger than the aggregate limit enforced for the single
        --env=DOCKSIDE_USER_ENV=<json> argv element built in Reservation::exec."""
        big_value = 'x' * 4000
        env = {f'BIGVAR{i}': {'value': big_value, 'secret': False,
                              'targets': {'ide': True, 'ssh': True}}
               for i in range(20)}
        body = {'env': env}
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as fh:
            json.dump(body, fh)
            path = fh.name
        try:
            self.assert_api_error(
                lambda: self.admin._run('user', 'edit', self._user, '--from-json', path))
        finally:
            os.unlink(path)


class EnvVarsInjectionTests(TestCase):
    """Live-container verification of the three injection targets."""

    @classmethod
    def setUpClass(cls):
        cls._user          = cls._sfx('inttest-envvars-inject-user')
        cls._user_password = 'inttest-envvars-inject-pass'
        cls.CONTAINER       = cls._sfx('inttest-envvars-01')

        pubkey = None
        if os.path.isfile(_DEV1_KEY + '.pub'):
            pubkey = open(_DEV1_KEY + '.pub', encoding='utf-8').read().strip()

        create_args = [
            'user', 'create', cls._user,
            '--role', cls.test_role_developer,
            '--user-password', cls._user_password,
            '--name', 'Env Vars Injection Test User',
            '--resources', json.dumps({
                'profiles': ['*'], 'networks': ['*'], 'runtimes': ['runc'],
                'IDEs': ['*'], 'images': ['*'], 'auth': ['*'],
            }),
        ]
        if pubkey:
            create_args.extend(['--set', f'ssh.publicKeys.inttestkey={pubkey}'])
            create_args.extend(['--set', f'ssh.keypairs.inttestkey.public={pubkey}'])
            create_args.extend(['--set', f'ssh.keypairs.inttestkey.private=@{_DEV1_KEY}'])
        cls.admin._run(*create_args)

        cls._user_client = cls.admin.with_credentials(cls._user, cls._user_password)

        # Set env vars BEFORE launch: the 'docker' target is baked into
        # `docker create` and is fixed at container-creation time.
        cls._user_client._run(
            'account', 'edit',
            '--set', 'env.DOCKER_VAR.value=docker-val',
            '--set', 'env.DOCKER_VAR.targets={"docker":true}',
            '--set', 'env.IDE_VAR.value=ide-val',
            '--set', 'env.IDE_VAR.targets={"ide":true}',
            '--set', 'env.SSH_VAR.value=ssh-val',
            '--set', 'env.SSH_VAR.targets={"ssh":true}',
            '--set', 'env.ALL_VAR.value=all-val',
            '--set', 'env.ALL_VAR.targets={"docker":true,"ide":true,"ssh":true}',
        )

        cls._user_client.create(profile=cls.test_profile_alpine, name=cls.CONTAINER)
        cls._user_client.start(cls.CONTAINER, wait=True, timeout=120)

    @classmethod
    def tearDownClass(cls):
        for fn in (
            lambda: cls._user_client.stop(cls.CONTAINER, wait=False),
            lambda: cls._user_client.remove(cls.CONTAINER, wait=False),
            lambda: cls.admin._run('user', 'remove', '--force', cls._user),
        ):
            try:
                fn()
            except Exception:
                pass

    def _env_lines(self, argv, **kwargs):
        result = run_in_devtainer(self._user_client, self.CONTAINER, argv, **kwargs)
        self.assert_true(result.returncode == 0,
                         f'command failed rc={result.returncode} stdout={result.stdout!r} '
                         f'stderr={result.stderr!r}')
        return result.stdout

    def _docker_exec_root(self, argv):
        """Run argv via `docker exec -u root` directly, unconditionally.

        Unlike run_in_devtainer(preferred='docker'), this ignores
        DOCKSIDE_TEST_CONTAINER_ACCESS: reading another user's (or root's own)
        /proc/<pid>/environ requires root, which an SSH session — landing as
        the devtainer's regular unixuser — cannot provide even when a private
        key is available. These checks are docker-exec-only by nature, not a
        preference the operator's access-method override should be able to
        redirect to SSH.
        """
        if not docker_available():
            raise CapabilityUnavailable('docker exec verification requires docker, which is unavailable')
        container_id = devtainer_container_id(self._user_client, self.CONTAINER)
        if not container_id:
            raise APIError(f'could not resolve docker container id for {self.CONTAINER!r}')
        result = subprocess.run(['docker', 'exec', '-u', 'root', container_id] + argv,
                                capture_output=True, text=True, timeout=30)
        self.assert_true(result.returncode == 0,
                         f'command failed rc={result.returncode} stdout={result.stdout!r} '
                         f'stderr={result.stderr!r}')
        return result.stdout

    def test_01_docker_target_visible_in_container_env(self):
        """A 'docker'-target var is baked into the container's own PID 1 env."""
        try:
            out = self._docker_exec_root(['sh', '-c', "tr '\\0' '\\n' < /proc/1/environ"])
        except CapabilityUnavailable as exc:
            self.skip(str(exc))
        self.assert_in('DOCKER_VAR=docker-val', out.splitlines(),
                       f'docker-target var not in /proc/1/environ: {out!r}')
        self.assert_in('ALL_VAR=all-val', out.splitlines(),
                       f'all-target var not in /proc/1/environ: {out!r}')
        # Target isolation: a var that does NOT target 'docker' must not leak
        # into the container's baseline env.
        self.assert_true('IDE_VAR=ide-val' not in out.splitlines(),
                         f'ide-only var unexpectedly baked into docker create env: {out!r}')
        self.assert_true('SSH_VAR=ssh-val' not in out.splitlines(),
                         f'ssh-only var unexpectedly baked into docker create env: {out!r}')

    def test_02_ide_target_visible_to_container_processes(self):
        """An 'ide'-target var reaches the IDE server process's own environment.

        Reads launch-ide.sh's own environment dump (both the Theia and
        openvscode variants log "- environment variables:" followed by a
        4-space-indented `env | sort` right before exec-ing the actual IDE
        server binary) rather than reading /proc/<pid>/environ directly:
        ptrace-reading another process's /proc/<pid>/environ needs
        CAP_SYS_PTRACE, which is unavailable in some restricted/nested Docker
        setups even for root — the log file needs only an ordinary root file
        read, and is IDE-variant-agnostic. Absence of the ssh-only marker is a
        valid negative check here because no SSH session exists yet at this
        point in the test (see test_03 for a more precisely scoped isolation
        check on the SSH side).
        """
        script = (
            "for f in /tmp/dockside/theia.log /tmp/dockside/openvscode.log; do "
            "[ -f \"$f\" ] && sed -n '/- environment variables:/,$p' \"$f\"; "
            "done; true"
        )
        try:
            out = self._docker_exec_root(['sh', '-c', script])
        except CapabilityUnavailable as exc:
            self.skip(str(exc))
        lines = [line.strip() for line in out.splitlines()]
        self.assert_in('IDE_VAR=ide-val', lines,
                       f'ide-target var not found in the IDE launch environment dump: {out!r}')
        self.assert_in('ALL_VAR=all-val', lines,
                       f'all-target var not found in the IDE launch environment dump: {out!r}')
        self.assert_true('SSH_VAR=ssh-val' not in lines,
                         f'ssh-only var unexpectedly visible in the IDE launch environment dump: {out!r}')

    def test_03_ssh_target_visible_in_ssh_session_env(self):
        """An 'ssh'-target var reaches a real SSH session via the rc-file snippet."""
        try:
            out = self._env_lines(
                ['sh', '-lc', 'env'],
                private_key_path=_DEV1_KEY,
                preferred='ssh',
                system_bin_dir=self.test_system_bin_dir,
            )
        except CapabilityUnavailable as exc:
            self.skip(str(exc))
        lines = out.splitlines()
        self.assert_in('SSH_VAR=ssh-val', lines, f'ssh-target var not in SSH session env: {out!r}')
        self.assert_in('ALL_VAR=all-val', lines, f'all-target var not in SSH session env: {out!r}')
        self.assert_true('IDE_VAR=ide-val' not in lines,
                         f'ide-only var unexpectedly visible in SSH session env: {out!r}')
