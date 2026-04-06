#!/usr/bin/env python3
"""
Dockside Integration Test Runner Entry Point
============================================
Invoked by run_tests.sh. Discovers and runs test modules.

Environment variables (set by run_tests.sh / harness.sh):
  DOCKSIDE_TEST_MODE         local|remote|harness
  DOCKSIDE_TEST_SERVER_URL   Full https URL (canonical, set by run_tests.sh)
  DOCKSIDE_TEST_CONNECT_TO   TCP override: 'host[:port]' (set for local/harness)
  DOCKSIDE_TEST_ADMIN        username:password  (if unset, uses stored CLI session)
  DOCKSIDE_TEST_VERIFY_SSL   0 or 1 (default: 0)
  DOCKSIDE_TEST_ONLY         prefix filter (e.g. '04')
  DOCKSIDE_TEST_HARNESS_ID   Harness container ID (harness mode)
  DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY  1 or 0 (override default per-mode behaviour)
  DOCKSIDE_TEST_NAME_SUFFIX  Suffix for test resource names:
                               (unset)  no suffix — use standard names
                               auto     generate a fresh random 6-char hex suffix
                               <string> use this exact string as the suffix
"""

import importlib.util
import json
import os
import random
import sys

SCRIPT_DIR      = os.path.dirname(os.path.abspath(__file__))
INTEGRATION_DIR = os.path.dirname(SCRIPT_DIR)
REPO_ROOT       = os.path.dirname(os.path.dirname(INTEGRATION_DIR))
_SSH_DIR        = os.path.join(INTEGRATION_DIR, 'config', 'ssh')

sys.path.insert(0, SCRIPT_DIR)
sys.path.insert(0, os.path.join(REPO_ROOT, 'cli'))

from dockside_test import DocksideClient, TestRunner, APIError


# ── Profile templates (embedded; independent of any server's bundled profiles) ─

_ALPINE_PROFILE = {
    "version": 2,
    "name": "Integration Test - Alpine",
    "active": True,
    "routers": [
        {
            "name": "www",
            "prefixes": ["www"],
            "domains": ["*"],
            "https": {"protocol": "http", "port": 8080},
            "auth": ["developer", "owner", "viewer", "user", "containerCookie", "public"],
        }
    ],
    "networks": ["*"],
    "images": ["alpine:latest"],
    "unixusers": ["dockside"],
    "mounts": {
        "tmpfs": [{"dst": "/home/{ideUser}/.ssh", "tmpfs-size": "1M"}],
        "bind": [],
        "volume": [],
    },
    "lxcfs": True,
    "dockerArgs": ["--memory=2G", "--pids-limit=4000"],
    "command": [
        "/bin/sh", "-c",
        "[ -x \"$(which sudo)\" ] || (apk update && apk add sudo curl libgcc libstdc++ bash;); sleep infinity",
    ],
}

_NGINX_PROFILE = {
    "version": 2,
    "name": "Integration Test - NGINX",
    "active": True,
    "routers": [
        {
            "name": "www",
            "prefixes": ["www"],
            "domains": ["*"],
            "https": {"protocol": "http", "port": 80},
            "auth": ["developer", "owner", "viewer", "user", "containerCookie", "public"],
        }
    ],
    "networks": ["*"],
    "images": ["nginx:latest"],
    "unixusers": ["dockside"],
    "mounts": {
        "tmpfs": [{"dst": "/home/{ideUser}/.ssh", "tmpfs-size": "1M"}],
    },
    "security": {"apparmor": "unconfined"},
    "entrypoint": ["/bin/bash"],
    "command": [
        "-c",
        "[ -x \"$(which sudo)\" ] || (apt update && apt -y install sudo);"
        " chmod -R dockside /usr/share/nginx/html;"
        " exec /docker-entrypoint.sh nginx -g 'daemon off;'",
    ],
    "dockerArgs": ["--memory=1G", "--pids-limit=4000", "--cpus=1"],
}


# ── Developer role spec ────────────────────────────────────────────────────────

_DEVELOPER_ROLE_PERMISSIONS = {
    'createContainerReservation': 1,
    'startContainer':             1,
    'stopContainer':              1,
    'removeContainer':            1,
    'developContainers':          1,
    'setContainerViewers':        1,
    'setContainerDevelopers':     1,
    'getContainerLogs':           1,
    'viewAllContainers':          0,
}

_VIEW_ALL_ROLE_PERMISSIONS = {
    'viewAllContainers':          1,
}

_DEVELOP_ALL_ROLE_PERMISSIONS = {
    **_DEVELOPER_ROLE_PERMISSIONS,
    'developAllContainers':       1,
}

# Required admin permissions for running the test suite
_REQUIRED_ADMIN_PERMISSIONS = [
    'createContainerReservation',
    'startContainer',
    'stopContainer',
    'removeContainer',
    'developContainers',
    'setContainerViewers',
    'setContainerDevelopers',
    'getContainerLogs',
    'viewAllContainers',
    'manageUsers',
    'manageProfiles',
]
_REQUIRED_ADMIN_RESOURCES = ['auth', 'profiles', 'networks', 'runtimes', 'IDEs', 'images']


# ── Helpers ────────────────────────────────────────────────────────────────────

def _parse_creds(env_var, default_user, default_pass):
    raw = os.environ.get(env_var, f'{default_user}:{default_pass}')
    if ':' in raw:
        user, _, pwd = raw.partition(':')
        return user.strip(), pwd.strip()
    return raw.strip(), default_pass


def _load_module(path):
    spec = importlib.util.spec_from_file_location(
        os.path.basename(path).replace('.py', ''), path
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _read_file(path):
    with open(path) as fh:
        return fh.read().strip()


def _resolve_suffix():
    """
    Resolve the test resource name suffix from DOCKSIDE_TEST_NAME_SUFFIX:
      unset  → '' (no suffix)
      'auto' → random 6-char hex string, printed to stderr
      other  → that string verbatim
    """
    raw = os.environ.get('DOCKSIDE_TEST_NAME_SUFFIX', '').strip()
    if not raw:
        return ''
    if raw == 'auto':
        suffix = '%06x' % random.randrange(0x1000000)
        print(f'# DOCKSIDE_TEST_NAME_SUFFIX=auto → suffix: {suffix}', file=sys.stderr)
        return suffix
    return raw


def _suffixed(base, suffix):
    return f'{base}-{suffix}' if suffix else base


# ── Admin pre-flight check ─────────────────────────────────────────────────────

def _check_admin_permissions(admin_client, server_url):
    """
    Run 'dockside whoami' and verify admin has all permissions required to run
    the test suite.  Aborts with a diagnostic if anything is missing.
    """
    try:
        record = admin_client._run('whoami')
    except APIError as e:
        print(f'ERROR: Could not verify admin permissions (dockside whoami failed): {e}',
              file=sys.stderr)
        sys.exit(1)

    if record is None:
        print('ERROR: dockside whoami returned no data', file=sys.stderr)
        sys.exit(1)

    perms     = (record.get('permissions') or {}).get('actions') or {}
    resources = record.get('resources') or {}

    missing_perms = [p for p in _REQUIRED_ADMIN_PERMISSIONS if not perms.get(p)]
    missing_res   = [r for r in _REQUIRED_ADMIN_RESOURCES
                     if not (resources.get(r) and ('*' in resources[r] or resources[r]))]

    if not missing_perms and not missing_res:
        uname = record.get('username', '?')
        role  = record.get('role', '?')
        print(f'# Admin permissions OK (user: {uname}, role: {role})', file=sys.stderr)
        return

    print('ERROR: Admin user is missing required permissions or resources.', file=sys.stderr)
    print(f'  Full record: {json.dumps(record, indent=2)}', file=sys.stderr)
    if missing_perms:
        print(f'  Missing permissions: {missing_perms}', file=sys.stderr)
        for p in missing_perms:
            print(f'    Fix: dockside user edit {record.get("username","admin")}'
                  f' --set permissions.actions.{p}=1 --server {server_url}',
                  file=sys.stderr)
    if missing_res:
        print(f'  Missing resources: {missing_res}', file=sys.stderr)
        for r in missing_res:
            print(f'    Fix: dockside user edit {record.get("username","admin")}'
                  f' --set resources.{r}=[\"*\"] --server {server_url}',
                  file=sys.stderr)
    sys.exit(1)


# ── Dynamic environment setup / teardown ──────────────────────────────────────

class _EnvManager:
    """Creates and tracks test roles, users, and profiles; cleans up on request."""

    def __init__(self, admin_client, suffix, server_url, cleanup_reused=False):
        self._admin    = admin_client
        self._suffix   = suffix
        self._server   = server_url
        self._cleanup_reused = cleanup_reused
        self._created_roles    = []
        self._created_users    = []
        self._created_profiles = []

        # Resolved names (set in setup())
        self.role_developer  = None
        self.role_viewer     = None
        self.user_dev1       = None
        self.user_dev2       = None
        self.user_viewer     = None
        self.profile_alpine  = None
        self.profile_nginx   = None
        self.password_dev    = 'inttest-testpass'

    # ── helpers ───────────────────────────────────────────────────────────────

    def _get_role(self, name):
        try:
            return self._admin._run('role', 'get', name)
        except APIError:
            return None

    def _get_user(self, name):
        try:
            return self._admin._run('user', 'get', name)
        except APIError:
            return None

    def _get_profile(self, name):
        try:
            return self._admin._run('profile', 'get', name)
        except APIError:
            return None

    def _track_reused(self, bucket, name):
        if self._cleanup_reused and name not in bucket:
            bucket.append(name)

    def _perms_match(self, record, expected_perms):
        """Check that a role's permissions dict matches the expected spec."""
        actual = (record.get('permissions') or {})
        # record may have 'permissions' as a flat dict (role JSON) or nested
        if isinstance(actual, dict) and 'actions' in actual:
            actual = actual['actions']
        for k, v in expected_perms.items():
            # Server may return numeric values as strings ('1'/'0'); compare as int.
            try:
                if int(actual.get(k, -1)) != int(v):
                    return False
            except (TypeError, ValueError):
                if actual.get(k) != v:
                    return False
        return True

    # ── role management ───────────────────────────────────────────────────────

    def _ensure_role(self, base_name, perms_spec):
        """Ensure a test role exists with the given permissions spec."""
        name = _suffixed(base_name, self._suffix)
        existing = self._get_role(name)
        if existing is not None:
            if self._perms_match(existing, perms_spec):
                self._track_reused(self._created_roles, name)
                print(f'# Role {name!r}: reusing existing (permissions match)', file=sys.stderr)
                return name
            else:
                print(f'ERROR: Role {name!r} exists but permissions do not match spec.',
                      file=sys.stderr)
                print(f'  Got:      {existing.get("permissions")}', file=sys.stderr)
                print(f'  Expected: {perms_spec}', file=sys.stderr)
                print(f'  To fix:   dockside role remove {name} --force --server {self._server}',
                      file=sys.stderr)
                sys.exit(1)

        # Create the role
        set_args = []
        for k, v in perms_spec.items():
            set_args.extend(['--set', f'permissions.{k}={v}'])
        self._admin._run('role', 'create', name, *set_args)
        self._created_roles.append(name)
        print(f'# Role {name!r}: created', file=sys.stderr)
        return name

    # ── user management ───────────────────────────────────────────────────────

    def _ensure_user(self, base_name, role_name, resources, ssh_pubkey=None,
                     ssh_keypair_name=None, ssh_privkey_path=None, ssh_pubkey_value=None):
        name     = _suffixed(base_name, self._suffix)
        existing = self._get_user(name)

        def _ssh_set_args():
            args = []
            if ssh_pubkey:
                public_key_name = (
                    'integration-key-pub'
                    if ssh_keypair_name == '*'
                    else (ssh_keypair_name or 'integration-key') + '-pub'
                )
                args.extend(['--set', f'ssh.publicKeys.{public_key_name}={ssh_pubkey}'])
            if ssh_keypair_name and ssh_privkey_path and ssh_pubkey_value:
                args.extend([
                    '--set', f'ssh.keypairs.{ssh_keypair_name}.public={ssh_pubkey_value}',
                    '--set', f'ssh.keypairs.{ssh_keypair_name}.private=@{ssh_privkey_path}',
                ])
            return args

        if existing is not None:
            # Check role matches; be lenient about resources (just require presence)
            existing_role = existing.get('role', '')
            if existing_role == role_name:
                # Always (re-)set the password so that a user created without one
                # (e.g. by a previous buggy run) gets a usable passwd entry.
                self._admin._run(
                    'user', 'edit', name, '--user-password', self.password_dev,
                    *_ssh_set_args()
                )
                self._track_reused(self._created_users, name)
                print(f'# User {name!r}: reusing existing (role matches)', file=sys.stderr)
                return name
            else:
                print(f'ERROR: User {name!r} exists with role {existing_role!r},'
                      f' expected {role_name!r}.', file=sys.stderr)
                print(f'  To fix:   dockside user remove {name} --force'
                      f' --server {self._server}', file=sys.stderr)
                sys.exit(1)

        # Build create args
        create_args = [
            '--role',          role_name,
            '--user-password', self.password_dev,
        ]
        for res_key, res_val in resources.items():
            create_args.extend(['--set', f'resources.{res_key}={json.dumps(res_val)}'])
        create_args.extend(_ssh_set_args())

        self._admin._run('user', 'create', name, *create_args)
        self._created_users.append(name)
        print(f'# User {name!r}: created', file=sys.stderr)
        return name

    # ── profile management ────────────────────────────────────────────────────

    def _ensure_profile(self, base_name, profile_spec):
        name     = _suffixed(base_name, self._suffix)
        existing = self._get_profile(name)
        if existing is not None:
            self._track_reused(self._created_profiles, name)
            print(f'# Profile {name!r}: reusing existing', file=sys.stderr)
            return name

        # Write spec to a temp file and create
        import tempfile as _tmp
        spec_copy = dict(profile_spec)
        # Update display name to include the actual profile ID
        spec_copy['name'] = spec_copy.get('name', base_name) + (f' [{self._suffix}]' if self._suffix else '')
        with _tmp.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump(spec_copy, f)
            tmp_path = f.name
        try:
            self._admin._run('profile', 'create', name, '--from-json', tmp_path)
        finally:
            os.unlink(tmp_path)
        self._created_profiles.append(name)
        print(f'# Profile {name!r}: created', file=sys.stderr)
        return name

    # ── public interface ──────────────────────────────────────────────────────

    def setup(self):
        """Create all test roles, users, and profiles (or reuse existing)."""
        print('# Setting up test environment...', file=sys.stderr)

        _dev_resources = {
            'profiles': ['*'],
            'networks': ['*'],
            'runtimes': ['runc'],
            'IDEs':     ['*'],
            'images':   ['*'],
            'auth':     ['*'],
        }
        _viewer_resources = {
            'profiles': [],
            'networks': [],
            'runtimes': [],
            'IDEs':     [],
            'images':   [],
            'auth':     [],
        }

        # Roles
        self.role_developer = self._ensure_role('inttest-developer', _DEVELOPER_ROLE_PERMISSIONS)
        self.role_viewer    = self._ensure_role('inttest-viewer-role', {})
        self.role_user      = self._ensure_role('inttest-user-role', {})
        self.role_view_all  = self._ensure_role('inttest-viewall-role', _VIEW_ALL_ROLE_PERMISSIONS)
        self.role_develop_all = self._ensure_role('inttest-developall-role', _DEVELOP_ALL_ROLE_PERMISSIONS)

        # SSH key info
        dev1_pub_path  = os.path.join(_SSH_DIR, 'testdev1_ed25519.pub')
        dev1_priv_path = os.path.join(_SSH_DIR, 'testdev1_ed25519')
        dev2_pub_path  = os.path.join(_SSH_DIR, 'testdev2_ed25519.pub')
        dev2_priv_path = os.path.join(_SSH_DIR, 'testdev2_ed25519')

        dev1_pubkey = _read_file(dev1_pub_path) if os.path.isfile(dev1_pub_path) else None
        dev2_pubkey = _read_file(dev2_pub_path) if os.path.isfile(dev2_pub_path) else None

        # Users
        self.user_dev1 = self._ensure_user(
            'inttest-dev1', self.role_developer, _dev_resources,
            ssh_pubkey=dev1_pubkey,
            ssh_keypair_name='*',
            ssh_privkey_path=dev1_priv_path,
            ssh_pubkey_value=dev1_pubkey,
        )
        self.user_dev2 = self._ensure_user(
            'inttest-dev2', self.role_developer, _dev_resources,
            ssh_pubkey=dev2_pubkey,
            ssh_keypair_name='*',
            ssh_privkey_path=dev2_priv_path,
            ssh_pubkey_value=dev2_pubkey,
        )
        self.user_viewer = self._ensure_user(
            'inttest-viewer', self.role_viewer, _viewer_resources,
        )
        self.user_user = self._ensure_user(
            'inttest-user', self.role_user, _viewer_resources,
        )
        self.user_view_all = self._ensure_user(
            'inttest-viewall', self.role_view_all, _viewer_resources,
        )
        self.user_develop_all = self._ensure_user(
            'inttest-developall', self.role_develop_all, _viewer_resources,
        )

        # Profiles
        self.profile_alpine = self._ensure_profile('inttest-alpine', _ALPINE_PROFILE)
        self.profile_nginx  = self._ensure_profile('inttest-nginx',  _NGINX_PROFILE)

        print('# Test environment ready.', file=sys.stderr)

    def cleanup(self):
        """Remove only resources created by this run (not pre-existing ones)."""
        if not (self._created_users or self._created_roles or self._created_profiles):
            return
        print('# Cleaning up test environment...', file=sys.stderr)
        # Remove in reverse-dependency order: users → roles → profiles
        for name in self._created_users:
            try:
                self._admin._run('user', 'remove', '--force', name)
                print(f'# Removed user {name!r}', file=sys.stderr)
            except APIError as e:
                print(f'# Warning: could not remove user {name!r}: {e}', file=sys.stderr)
        for name in self._created_roles:
            try:
                self._admin._run('role', 'remove', '--force', name)
                print(f'# Removed role {name!r}', file=sys.stderr)
            except APIError as e:
                print(f'# Warning: could not remove role {name!r}: {e}', file=sys.stderr)
        for name in self._created_profiles:
            try:
                self._admin._run('profile', 'remove', '--force', name)
                print(f'# Removed profile {name!r}', file=sys.stderr)
            except APIError as e:
                print(f'# Warning: could not remove profile {name!r}: {e}', file=sys.stderr)


# ── Entry point ────────────────────────────────────────────────────────────────

# Module-level reference so the bash EXIT trap's --cleanup invocation can call it
_env_manager = None


def main():
    global _env_manager

    # Resolve CLI path
    cli_path = os.path.join(REPO_ROOT, 'cli', 'dockside')
    if not os.path.isfile(cli_path):
        print(f'ERROR: CLI not found at {cli_path}', file=sys.stderr)
        sys.exit(1)

    server_url   = os.environ.get('DOCKSIDE_TEST_SERVER_URL', '')
    connect_to   = os.environ.get('DOCKSIDE_TEST_CONNECT_TO', '').strip() or None
    test_mode    = os.environ.get('DOCKSIDE_TEST_MODE', 'remote')
    verify_ssl   = os.environ.get('DOCKSIDE_TEST_VERIFY_SSL', '0') == '1'
    only_prefix  = os.environ.get('DOCKSIDE_TEST_ONLY', '').strip()
    harness_id   = os.environ.get('DOCKSIDE_TEST_HARNESS_ID', '').strip() or None
    skip_cleanup = os.environ.get('DOCKSIDE_TEST_SKIP_CLEANUP', '0') == '1'
    reuse_user_sessions = os.environ.get('DOCKSIDE_TEST_REUSE_USER_SESSIONS', '0') == '1'
    cleanup_reused = os.environ.get('DOCKSIDE_TEST_CLEANUP_REUSED', '0') == '1'

    # Network modify override
    env_nm = os.environ.get('DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY', '').strip()
    allow_network_modify = None
    if env_nm == '1':
        allow_network_modify = True
    elif env_nm == '0':
        allow_network_modify = False

    if not server_url:
        print('ERROR: DOCKSIDE_TEST_SERVER_URL not set', file=sys.stderr)
        sys.exit(1)

    # ── Admin credentials / session ───────────────────────────────────────────
    admin_env = os.environ.get('DOCKSIDE_TEST_ADMIN', '').strip()
    if admin_env:
        admin_user, _, admin_pass = admin_env.partition(':')
        admin_creds = (admin_user.strip(), admin_pass.strip())
    else:
        # No explicit credentials — use the stored CLI session
        print('# DOCKSIDE_TEST_ADMIN not set; using stored CLI session for admin',
              file=sys.stderr)
        admin_creds = (None, None)  # session_only mode

    # Build admin client (used for pre-flight + env setup).
    # use_cli_admin_creds=True when no explicit credentials are provided,
    # meaning the developer has pre-authenticated via 'dockside login'.
    # use_cli_admin_creds=False (default) when explicit credentials are supplied
    # (harness mode and explicit-creds dev use).
    admin_client = DocksideClient(
        cli_path=cli_path,
        server_url=server_url,
        username=admin_creds[0],
        password=admin_creds[1],
        connect_to=connect_to,
        verify_ssl=verify_ssl,
        use_cli_admin_creds=(admin_creds[0] is None),
    )

    # Pre-flight: verify admin has required permissions (via dockside whoami)
    _check_admin_permissions(admin_client, server_url)

    # ── Name suffix ───────────────────────────────────────────────────────────
    suffix = _resolve_suffix()
    if suffix:
        print(f'# Test resource suffix: {suffix!r}', file=sys.stderr)
    else:
        print('# Test resource suffix: (none)', file=sys.stderr)

    # ── Dynamic environment setup ─────────────────────────────────────────────
    if cleanup_reused:
        print('# Reused test resources will be cleaned up at end of run', file=sys.stderr)
    _env_manager = _EnvManager(
        admin_client,
        suffix,
        server_url,
        cleanup_reused=cleanup_reused,
    )
    ok = False
    try:
        _env_manager.setup()

        # Resolved names
        test_username_dev1   = _env_manager.user_dev1
        test_username_dev2   = _env_manager.user_dev2
        test_username_viewer = _env_manager.user_viewer
        test_username_user    = _env_manager.user_user
        test_username_view_all = _env_manager.user_view_all
        test_username_develop_all = _env_manager.user_develop_all
        test_role_developer  = _env_manager.role_developer
        test_role_viewer     = _env_manager.role_viewer
        test_role_user       = _env_manager.role_user
        test_role_view_all   = _env_manager.role_view_all
        test_role_develop_all = _env_manager.role_develop_all
        test_profile_alpine  = _env_manager.profile_alpine
        test_profile_nginx   = _env_manager.profile_nginx
        test_password_dev    = _env_manager.password_dev
        test_system_bin_dir  = os.environ.get(
            'DOCKSIDE_TEST_SYSTEM_BIN_DIR',
            '/opt/dockside/system/latest/bin',
        )

        name_attrs = {
            'test_username_dev1':   test_username_dev1,
            'test_username_dev2':   test_username_dev2,
            'test_username_viewer': test_username_viewer,
            'test_username_user':   test_username_user,
            'test_username_view_all': test_username_view_all,
            'test_username_develop_all': test_username_develop_all,
            'test_role_developer':  test_role_developer,
            'test_role_viewer':     test_role_viewer,
            'test_role_user':       test_role_user,
            'test_role_view_all':   test_role_view_all,
            'test_role_develop_all': test_role_develop_all,
            'test_profile_alpine':  test_profile_alpine,
            'test_profile_nginx':   test_profile_nginx,
            'test_password_dev':    test_password_dev,
            'test_system_bin_dir':  test_system_bin_dir,
            '_name_suffix':         suffix,
        }

        # ── Credentials for dev/viewer test users ─────────────────────────────
        credentials = {
            'admin':  admin_creds,
            'dev1':   (test_username_dev1,   test_password_dev),
            'dev2':   (test_username_dev2,   test_password_dev),
            'viewer': (test_username_viewer, test_password_dev),
            'user':   (test_username_user, test_password_dev),
            'view_all': (test_username_view_all, test_password_dev),
            'develop_all': (test_username_develop_all, test_password_dev),
        }

        runner = TestRunner(
            cli_path=cli_path,
            server_url=server_url,
            credentials=credentials,
            connect_to=connect_to,
            verify_ssl=verify_ssl,
            test_mode=test_mode,
            harness_container_id=harness_id,
            allow_network_modify=allow_network_modify,
            name_attrs=name_attrs,
            reuse_user_sessions=reuse_user_sessions,
        )

        # ── Discover and run test modules ─────────────────────────────────────
        tests_dir  = os.path.join(INTEGRATION_DIR, 'tests')
        test_files = sorted(
            f for f in os.listdir(tests_dir)
            if f.endswith('.py') and not f.startswith('_')
            and (not only_prefix or f.startswith(only_prefix))
        )

        print('TAP version 13')
        for fname in test_files:
            path = os.path.join(tests_dir, fname)
            try:
                mod = _load_module(path)
            except Exception as e:
                print(f'# ERROR loading {fname}: {e}', file=sys.stderr)
                continue
            runner.run_module(mod)

        ok = runner.print_summary()
    finally:
        if skip_cleanup:
            print('# Skipping environment cleanup (--skip-cleanup)', file=sys.stderr)
        else:
            _env_manager.cleanup()

    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    # When invoked as --cleanup by the bash EXIT/INT trap, run env cleanup only.
    if '--cleanup' in sys.argv:
        if _env_manager is not None and os.environ.get('DOCKSIDE_TEST_SKIP_CLEANUP', '0') != '1':
            _env_manager.cleanup()
        sys.exit(0)
    main()
