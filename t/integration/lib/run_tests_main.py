#!/usr/bin/env python3
"""
Dockside Integration Test Runner Entry Point
============================================
Invoked by run_tests.sh. Discovers and runs test modules.

Environment variables (set by run_tests.sh / harness.sh):
  DOCKSIDE_TEST_MODE         local|remote|harness
  DOCKSIDE_TEST_SERVER_URL   Full https URL (canonical, set by run_tests.sh)
  DOCKSIDE_TEST_ONLY         prefix filter (e.g. '04')
  DOCKSIDE_TEST_HARNESS_ID   Harness container ID (harness mode)
  DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY  1 or 0 (override default per-mode behaviour)
  DOCKSIDE_TEST_NAME_SUFFIX  Suffix for test resource names:
                               (unset)  same as 'auto'
                               auto     generate a fresh random 6-char hex suffix
                               <string> use this exact string as the suffix
                               (empty)  rejected — an empty suffix would let test
                                        names collide with un-suffixed real resources
  DOCKSIDE_TEST_CLEANUP_REUSED  1 or 0 (default: 0). When 1, pre-existing roles/users/
                               profiles that a run reuses are also REMOVED at the end —
                               only safe on an instance you own; off by default so the
                               harness never deletes resources it did not create.
"""

import importlib.util
import json
import os
import random
import signal
import socket
import subprocess
import sys

SCRIPT_DIR      = os.path.dirname(os.path.abspath(__file__))
INTEGRATION_DIR = os.path.dirname(SCRIPT_DIR)
REPO_ROOT       = os.path.dirname(os.path.dirname(INTEGRATION_DIR))
_SSH_DIR        = os.path.join(INTEGRATION_DIR, 'config', 'ssh')

sys.path.insert(0, SCRIPT_DIR)
sys.path.insert(0, os.path.join(REPO_ROOT, 'cli'))

from dockside_test import (
    DocksideClient, TestRunner, APIError,
    docker_available, docker_manages_container, resolve_allow_network_modify,
    create_and_attach_test_network,
)


# ── Image registry prefix ──────────────────────────────────────────────────────
# Set DOCKSIDE_TEST_IMAGE_REGISTRY to redirect bare Docker Hub image pulls to a
# mirror, e.g. DOCKSIDE_TEST_IMAGE_REGISTRY=mirror.gcr.io/library
# Images that already contain an explicit registry host (first path component
# contains '.' or ':') are left unchanged.

_IMAGE_REGISTRY = os.environ.get('DOCKSIDE_TEST_IMAGE_REGISTRY', '').rstrip('/')


def _prefix_image(image):
    if not _IMAGE_REGISTRY:
        return image
    if '/' in image:
        first = image.split('/')[0]
        if '.' in first or ':' in first:
            return image  # explicit registry host (e.g. 127.0.0.1:19999/... or gcr.io/...)
    return f'{_IMAGE_REGISTRY}/{image}'


# ── CA bundle bind-mount ────────────────────────────────────────────────────────
# Devtainers launched by Dockside do not inherit the host's CA bundle. Set
# DOCKSIDE_TEST_CA_BUNDLE to a host path (e.g. /etc/ssl/certs/ca-certificates.crt)
# to bind-mount it read-only into every test profile at the same path, so
# devtainer package managers (apk/apt) and HTTPS git clones trust it. Useful
# behind a TLS-inspecting proxy whose CA is trusted on the host but not baked
# into devtainer base images.

_CA_BUNDLE = os.environ.get('DOCKSIDE_TEST_CA_BUNDLE', '')


def _with_ca_bundle_mount(spec):
    if not _CA_BUNDLE:
        return spec
    spec = dict(spec)
    mounts = dict(spec.get('mounts') or {})
    mounts['bind'] = list(mounts.get('bind') or []) + [
        {'src': _CA_BUNDLE, 'dst': '/etc/ssl/certs/ca-certificates.crt', 'readonly': True}
    ]
    spec['mounts'] = mounts
    return spec


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
    "images": [_prefix_image("alpine:latest")],
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

# Debian counterpart to _ALPINE_PROFILE, used by the lifecycle (03) and IDE (07)
# modules.  Those modules previously hard-coded the server's bundled '11-debian'
# profile, which violates the suite's no-pre-existing-fixtures rule and breaks on
# any server that does not ship that exact profile.  An apt-based image is needed
# (rather than reusing the alpine fixture) because 07 launches an IDE, whose
# bootstrap assumes a Debian/Ubuntu userland.
_DEBIAN_PROFILE = {
    "version": 2,
    "name": "Integration Test - Debian",
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
    "images": [_prefix_image("debian:latest")],
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
        "[ -x \"$(which sudo)\" ] || (apt update && apt -y install sudo curl); sleep infinity",
    ],
}

_GIT_PROFILE = {
    "version": 4,
    "name": "Integration Test - Git Repo",
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
    "images": [_prefix_image("ubuntu:latest"), _prefix_image("debian:latest"), _prefix_image("alpine:latest")],
    "gitURLs": ["*"],
    "unixusers": ["dockside"],
    "options": [
        {
            "name": "branch",
            "label": "Branch",
            "type": "text",
            "default": "",
            "placeholder": "e.g. main, feature/my-feature (leave blank for default)",
        },
        {
            "name": "pr",
            "label": "Pull Request #",
            "type": "text",
            "default": "",
            "placeholder": "e.g. 42 (overrides branch if set)",
        },
        {
            "name": "gh_token",
            "label": "GitHub Token",
            "type": "text",
            "default": "",
            "placeholder": "GitHub personal access token for gh pr checkout",
        },
    ],
    "mounts": {
        "tmpfs": [{"dst": "/home/{ideUser}/.ssh", "tmpfs-size": "1M"}],
        "bind": [],
        "volume": [],
    },
    "lxcfs": True,
    "dockerArgs": ["--memory=1G", "--pids-limit=4000", "--env=GH_TOKEN={option.gh_token}"],
    "command": [
        "/bin/sh", "-c",
        "[ -x \"$(which sudo)\" ] || (apt update && apt -y install sudo); sleep infinity",
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
    "images": [_prefix_image("nginx:latest")],
    "unixusers": ["dockside"],
    "mounts": {
        "tmpfs": [{"dst": "/home/{ideUser}/.ssh", "tmpfs-size": "1M"}],
    },
    "security": {"apparmor": "unconfined"},
    "entrypoint": ["/bin/bash"],
    "command": [
        "-c",
        "[ -x \"$(which sudo)\" ] || (apt update && apt -y install sudo);"
        " chown -R dockside /usr/share/nginx/html;"
        " exec /docker-entrypoint.sh nginx -g 'daemon off;'",
    ],
    "dockerArgs": ["--memory=1G", "--pids-limit=4000", "--cpus=1"],
}

# 127.0.0.1:19999 is chosen because no registry will be listening there;
# docker create fails immediately with connection-refused, giving a fast,
# reliable, rate-limit-free launch failure for testing status -4.
_BAD_IMAGE_PROFILE = {
    "version": 2,
    "name": "Integration Test - Bad Image (launch failure)",
    "active": True,
    "routers": [],
    "networks": ["*"],
    "images": ["127.0.0.1:19999/dockside-test-nonexistent:latest"],
    "unixusers": ["dockside"],
    "mounts": {"tmpfs": [], "bind": [], "volume": []},
    "command": ["/bin/sh", "-c", "sleep infinity"],
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
      unset  → random 6-char hex string (same as 'auto')
      'auto' → random 6-char hex string, printed to stderr
      other  → that string verbatim
    """
    raw = os.environ.get('DOCKSIDE_TEST_NAME_SUFFIX', 'auto').strip()
    if raw == 'auto':
        suffix = '%06x' % random.randrange(0x1000000)
        print(f'# DOCKSIDE_TEST_NAME_SUFFIX=auto → suffix: {suffix}', file=sys.stderr)
        return suffix
    if not raw:
        # An empty suffix produces bare names (inttest-dev1, inttest-alpine, ...) that
        # can collide with un-suffixed real resources; combined with reuse + cleanup
        # that risks mutating and deleting them. Refuse rather than silently allow it.
        print('# ERROR: DOCKSIDE_TEST_NAME_SUFFIX is empty. Use "auto" (default) or a '
              'non-empty string; an empty suffix is not permitted.', file=sys.stderr)
        sys.exit(1)
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
        self.profile_alpine     = None
        self.profile_debian     = None
        self.profile_nginx      = None
        self.profile_git        = None
        self.profile_bad_image  = None
        self.password_dev    = 'inttest-testpass'

        # Resolved by select_network() before setup() builds any profile.
        self.selected_network = None
        self._created_network = None  # (name, container_id) if we created+attached it

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

    def _ensure_user(self, base_name, role_name, resources, display_name=None,
                     email=None, ssh_pubkey=None, ssh_keypair_name=None,
                     ssh_privkey_path=None, ssh_pubkey_value=None):
        name     = _suffixed(base_name, self._suffix)
        existing = self._get_user(name)

        def _user_set_args():
            args = []
            if display_name is not None:
                args.extend(['--name', display_name])
            if email is not None:
                args.extend(['--email', email])
            return args

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
            # Reuse an existing user only by adoption — never mutate a user we did not
            # create this run. A pre-existing account that merely shares this suffixed
            # name could be a real user (or a half-created leftover from a buggy run);
            # (re-)setting its password/name/email/ssh would clobber it. So adopt the
            # record as-is and rely on it already matching the fixture. If a divergent
            # leftover (e.g. created without a usable password) breaks dependent tests,
            # the operator removes it and re-runs — surfaced loudly, not silently
            # overwritten. (Role is still checked; a mismatch is a hard error below.)
            existing_role = existing.get('role', '')
            if existing_role == role_name:
                self._track_reused(self._created_users, name)
                print(f'# User {name!r}: reusing existing as-is (role matches; not mutated)',
                      file=sys.stderr)
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
        create_args.extend(_user_set_args())
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
        spec_copy = _with_ca_bundle_mount(profile_spec)
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

    # ── network selection ─────────────────────────────────────────────────────

    def _container_networks(self, ctr):
        """Return the set of Docker network names `ctr` is currently attached to,
        or None if that can't be determined (docker unreachable, ctr unknown, etc.)."""
        r = subprocess.run(['docker', 'inspect', ctr], capture_output=True, timeout=10)
        if r.returncode != 0:
            return None
        try:
            data = json.loads(r.stdout)
            return set(data[0]['NetworkSettings']['Networks'].keys())
        except (ValueError, KeyError, IndexError, TypeError):
            return None

    def _network_attached(self, ctr, network_name):
        """True if `network_name` is one of `ctr`'s current Docker network attachments."""
        networks = self._container_networks(ctr)
        return networks is not None and network_name in networks

    def select_network(self, test_mode, allow_network_modify, dockside_container_id):
        """Choose which Docker network test devtainers use, deterministically.

        Every default test profile used to declare ``"networks": ["*"]``, which
        Profile::applyDefaultsAndFilters resolves to an alphabetical sort of
        whatever networks the Dockside-under-test happens to be attached to.  On
        a real instance with more than one attached network (e.g. one firewall-
        managed, one not), that made a test run's actual network non-deterministic
        and dependent on incidental network naming rather than anything the suite
        declares — the same "correct by assumption" problem the no-pre-existing-
        fixtures rule exists to avoid for users/roles/profiles.  This picks one
        network explicitly instead, in priority order:

          1. DOCKSIDE_TEST_NETWORK env var — used verbatim.  Verified against the
             Dockside-under-test's actual attachments when docker access and a
             container id are both available; trusted as-is otherwise (e.g. true
             remote mode with no local docker access to check with).
          2. If docker access and a container id are available and the
             Dockside-under-test is currently attached to exactly one network,
             use it automatically. There is nothing to disambiguate — a set of
             one is deterministic regardless of what it happens to be named —
             so this needs no modify permission and is not the "correct by
             assumption" problem this method exists to remove (e.g. a fresh
             single-network deployment such as the root docker-compose.yml's
             network_mode: "bridge").
          3. Auto-create-and-attach a dedicated ``inttest-net-*`` network, when
             network modification is enabled (resolve_allow_network_modify()) and
             the preconditions 08_network.py's own network-attach tests already
             require all hold (docker reachable, a container id known, that
             daemon manages it). Only reached when step 2 found 2+ candidate
             networks (genuine ambiguity) or none at all.
          4. Fail fast.  This deliberately does NOT fall back to whatever ["*"]
             would have resolved to — that silent, environment-dependent choice
             is exactly what this method exists to remove.

        Exits the process on failure (this runs during setup, not as a test).
        """
        explicit = os.environ.get('DOCKSIDE_TEST_NETWORK', '').strip()
        if explicit:
            if docker_available() and dockside_container_id:
                if not self._network_attached(dockside_container_id, explicit):
                    print(
                        f'ERROR: DOCKSIDE_TEST_NETWORK={explicit!r} is not attached to '
                        f'Dockside container {dockside_container_id!r}.', file=sys.stderr)
                    print('  Attach it first, e.g.:', file=sys.stderr)
                    print(f'    docker network connect {explicit} {dockside_container_id}',
                          file=sys.stderr)
                    sys.exit(1)
            self.selected_network = explicit
            print(f'# Test devtainer network: {explicit!r} (explicit, DOCKSIDE_TEST_NETWORK)',
                  file=sys.stderr)
            return

        if docker_available() and dockside_container_id:
            networks = self._container_networks(dockside_container_id)
            if networks is not None and len(networks) == 1:
                net = next(iter(networks))
                self.selected_network = net
                print(f'# Test devtainer network: {net!r} (only network attached to the '
                      f'Dockside-under-test; unambiguous, no selection needed)',
                      file=sys.stderr)
                return

        can_modify = resolve_allow_network_modify(test_mode, allow_network_modify)
        if (can_modify and docker_available() and dockside_container_id
                and docker_manages_container(dockside_container_id)):
            probe_profile = self._ensure_profile('inttest-netprobe', _ALPINE_PROFILE)
            probe_name = _suffixed('inttest-netprobe-check', self._suffix)
            try:
                net = create_and_attach_test_network(
                    self._admin, dockside_container_id, probe_profile, probe_name)
            except (RuntimeError, AssertionError) as e:
                print(f'ERROR: could not create/attach a test network: {e}', file=sys.stderr)
                sys.exit(1)
            # The probe reservation itself is removed later, in cleanup() — it was
            # just created with no_wait=True (create_and_attach_test_network's own
            # discovery-retry loop calls create() that way), so removing it here
            # immediately would race its own launch and can silently fail, leaving
            # it attached and blocking the network's removal at the end of the run.
            # By cleanup() time (after the whole suite has run) it is long since
            # settled, so a normal blocking remove(wait=True) there is reliable.
            self.selected_network = net
            self._created_network = (net, dockside_container_id, probe_name)
            print(f'# Test devtainer network: {net!r} (auto-created and attached)',
                  file=sys.stderr)
            return

        networks = (self._container_networks(dockside_container_id)
                    if docker_available() and dockside_container_id else None)
        if networks:
            print(f'ERROR: {len(networks)} candidate networks are attached to the '
                  f'Dockside-under-test ({", ".join(sorted(networks))}) — ambiguous, '
                  f'refusing to guess.', file=sys.stderr)
        else:
            print('ERROR: no test devtainer network selected, and none can be created.',
                  file=sys.stderr)
        print('  Set DOCKSIDE_TEST_NETWORK=<name> to use a specific network already', file=sys.stderr)
        print('  connected to the Dockside-under-test, or set', file=sys.stderr)
        print('  DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY=1 (and DOCKSIDE_TEST_CONTAINER_ID if not',
              file=sys.stderr)
        print('  auto-detectable) to let the harness create and attach one.', file=sys.stderr)
        sys.exit(1)

    # ── public interface ──────────────────────────────────────────────────────

    def setup(self):
        """Create all test roles, users, and profiles (or reuse existing)."""
        print('# Setting up test environment...', file=sys.stderr)
        assert self.selected_network, 'select_network() must be called before setup()'

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
            display_name='Integration Test Dev 1',
            email='inttest-dev1@dockside-integration-test.invalid',
            ssh_pubkey=dev1_pubkey,
            ssh_keypair_name='*',
            ssh_privkey_path=dev1_priv_path,
            ssh_pubkey_value=dev1_pubkey,
        )
        self.user_dev2 = self._ensure_user(
            'inttest-dev2', self.role_developer, _dev_resources,
            display_name='Integration Test Dev 2',
            email='inttest-dev2@dockside-integration-test.invalid',
            ssh_pubkey=dev2_pubkey,
            ssh_keypair_name='*',
            ssh_privkey_path=dev2_priv_path,
            ssh_pubkey_value=dev2_pubkey,
        )
        self.user_viewer = self._ensure_user(
            'inttest-viewer', self.role_viewer, _viewer_resources,
            display_name='Integration Test Viewer',
            email='inttest-viewer@dockside-integration-test.invalid',
        )
        self.user_user = self._ensure_user(
            'inttest-user', self.role_user, _viewer_resources,
            display_name='Integration Test User',
            email='inttest-user@dockside-integration-test.invalid',
        )
        self.user_view_all = self._ensure_user(
            'inttest-viewall', self.role_view_all, _viewer_resources,
            display_name='Integration Test View-All',
            email='inttest-viewall@dockside-integration-test.invalid',
        )
        self.user_develop_all = self._ensure_user(
            'inttest-developall', self.role_develop_all, _viewer_resources,
            display_name='Integration Test Develop-All',
            email='inttest-developall@dockside-integration-test.invalid',
        )

        # Profiles keep the "*" wildcard (any attached host network validates), so a
        # profile reused from a previous run is never pinned to a network that may
        # since have been torn down. The network select_network() chose for *this*
        # run is instead applied at create() time by default (see TestRunner's
        # default_network / DocksideClient.create()), which is also what keeps every
        # devtainer's default network deterministic without touching the profile.
        self.profile_alpine     = self._ensure_profile('inttest-alpine',     _ALPINE_PROFILE)
        self.profile_debian     = self._ensure_profile('inttest-debian',     _DEBIAN_PROFILE)
        self.profile_nginx      = self._ensure_profile('inttest-nginx',      _NGINX_PROFILE)
        self.profile_git        = self._ensure_profile('inttest-git',        _GIT_PROFILE)
        self.profile_bad_image  = self._ensure_profile('inttest-bad-image',  _BAD_IMAGE_PROFILE)

        print('# Test environment ready.', file=sys.stderr)

    def cleanup(self):
        """Remove only resources created by this run (not pre-existing ones).

        Best-effort: a failure on one resource is logged and the rest are still
        attempted. Returns the number of resources that could NOT be removed so
        the caller can surface a distinct status — a green test run that
        nevertheless leaks fixtures is neither a clean pass nor a test failure.
        """
        if not (self._created_users or self._created_roles or self._created_profiles
                or self._created_network):
            return 0
        failures = 0
        print('# Cleaning up test environment...', file=sys.stderr)
        # Remove in reverse-dependency order: users → roles → profiles → network
        for name in self._created_users:
            try:
                self._admin._run('user', 'remove', '--force', name)
                print(f'# Removed user {name!r}', file=sys.stderr)
            except APIError as e:
                failures += 1
                print(f'# Warning: could not remove user {name!r}: {e}', file=sys.stderr)
        for name in self._created_roles:
            try:
                self._admin._run('role', 'remove', '--force', name)
                print(f'# Removed role {name!r}', file=sys.stderr)
            except APIError as e:
                failures += 1
                print(f'# Warning: could not remove role {name!r}: {e}', file=sys.stderr)
        for name in self._created_profiles:
            try:
                self._admin._run('profile', 'remove', '--force', name)
                print(f'# Removed profile {name!r}', file=sys.stderr)
            except APIError as e:
                failures += 1
                print(f'# Warning: could not remove profile {name!r}: {e}', file=sys.stderr)
        if self._created_network:
            net, ctr, probe_name = self._created_network
            try:
                # remove() alone does not stop a running container (matches
                # TestCase.tearDown's own stop-then-remove pattern for test devtainers).
                self._admin.stop(probe_name, wait=True)
                self._admin.remove(probe_name, wait=True)
                print(f'# Removed probe reservation {probe_name!r}', file=sys.stderr)
            except APIError as e:
                failures += 1
                print(f'# Warning: could not remove probe reservation {probe_name!r}: {e}',
                      file=sys.stderr)
            r1 = subprocess.run(['docker', 'network', 'disconnect', net, ctr],
                                capture_output=True, timeout=15)
            r2 = subprocess.run(['docker', 'network', 'rm', net],
                                capture_output=True, timeout=15)
            if r1.returncode == 0 and r2.returncode == 0:
                print(f'# Removed test network {net!r}', file=sys.stderr)
            else:
                failures += 1
                print(f'# Warning: could not fully remove test network {net!r}', file=sys.stderr)
            self._created_network = None
        return failures


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
    test_mode    = os.environ.get('DOCKSIDE_TEST_MODE', 'remote')
    only_prefix  = os.environ.get('DOCKSIDE_TEST_ONLY', '').strip()
    harness_id   = os.environ.get('DOCKSIDE_TEST_HARNESS_ID', '').strip() or None
    skip_cleanup = os.environ.get('DOCKSIDE_TEST_SKIP_CLEANUP', '0') == '1'
    reuse_user_sessions = os.environ.get('DOCKSIDE_TEST_REUSE_USER_SESSIONS', '0') == '1'
    cleanup_reused = os.environ.get('DOCKSIDE_TEST_CLEANUP_REUSED', '0') == '1'

    # Dockside container id for the network-attach tests (08 test_05/06), which
    # `docker network connect` a throwaway network to it. Explicit env wins; otherwise,
    # in local/harness mode we are normally running inside the Dockside container under
    # test, so auto-detect: entrypoint.sh records the raw id at
    # /etc/service/nginx/data/ctr-id, and in a Dockside-launched container the hostname
    # equals the container name (also a valid `docker` reference). Not auto-detected in
    # remote mode (this process is not in the server's container). Network modification
    # itself remains gated behind can_modify_networks() (DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY).
    dockside_container_id = os.environ.get('DOCKSIDE_TEST_CONTAINER_ID', '').strip() or None
    if not dockside_container_id and test_mode in ('local', 'harness'):
        try:
            with open('/etc/service/nginx/data/ctr-id', encoding='utf-8') as _f:
                dockside_container_id = _f.read().strip() or None
        except OSError:
            dockside_container_id = None
        if not dockside_container_id:
            dockside_container_id = socket.gethostname() or None

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

    # Admin always uses the stored CLI session established by 'dockside login'.
    admin_creds = (None, None)
    admin_client = DocksideClient(
        cli_path=cli_path,
        server_url=server_url,
        use_cli_admin_creds=True,
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

    # TestRunner installs its own SIGINT/SIGTERM handlers, but only after setup()
    # below. Until then a SIGTERM/SIGHUP during fixture creation would default-
    # terminate the process and skip the finally: cleanup, leaking the users/roles/
    # profiles created so far. (SIGINT already raises KeyboardInterrupt and reaches
    # the finally.) Install an early handler over the env-manager's whole lifetime
    # that runs the same idempotent cleanup, then restores the default disposition
    # and re-raises so the process still exits with normal signal semantics.
    if not skip_cleanup:
        def _early_emergency_cleanup(signum, _frame):
            try:
                _env_manager.cleanup()
            finally:
                signal.signal(signum, signal.SIG_DFL)
                os.kill(os.getpid(), signum)
        for _sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(_sig, _early_emergency_cleanup)

    ok = False
    cleanup_failed = 0
    try:
        # harness_id wins when set, matching TestCase._dockside_container()'s existing
        # precedent (08_network.py): harness.sh runs on the *host* and launches a fresh
        # container via `docker run`, so in harness mode dockside_container_id's own
        # auto-detect (this process's own ctr-id/hostname) resolves to the driver host's
        # identity, not the harness container's — using it directly would attach the
        # auto-created test network to the wrong container, or fail outright.
        _env_manager.select_network(test_mode, allow_network_modify,
                                     harness_id or dockside_container_id)
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
        test_profile_alpine     = _env_manager.profile_alpine
        test_profile_debian     = _env_manager.profile_debian
        test_profile_nginx      = _env_manager.profile_nginx
        test_profile_git        = _env_manager.profile_git
        test_profile_bad_image  = _env_manager.profile_bad_image
        test_image_alpine       = _prefix_image('alpine:latest')
        test_image_nginx        = _prefix_image('nginx:latest')
        test_image_debian       = _prefix_image('debian:latest')
        test_image_ubuntu       = _prefix_image('ubuntu:latest')
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
            'test_profile_alpine':     test_profile_alpine,
            'test_profile_debian':     test_profile_debian,
            'test_profile_nginx':      test_profile_nginx,
            'test_profile_git':        test_profile_git,
            'test_profile_bad_image':  test_profile_bad_image,
            'test_image_alpine':       test_image_alpine,
            'test_image_nginx':        test_image_nginx,
            'test_image_debian':       test_image_debian,
            'test_image_ubuntu':       test_image_ubuntu,
            'test_password_dev':       test_password_dev,
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
            test_mode=test_mode,
            harness_container_id=harness_id,
            dockside_container_id=dockside_container_id,
            allow_network_modify=allow_network_modify,
            name_attrs=name_attrs,
            reuse_user_sessions=reuse_user_sessions,
            default_network=_env_manager.selected_network,
        )
        # On SIGINT/SIGTERM the runner re-raises the signal, skipping the finally
        # below, so give it the env cleanup to still remove dynamic fixtures
        # (honouring --skip-cleanup).
        runner._on_emergency = None if skip_cleanup else _env_manager.cleanup

        # ── Discover and run test modules ─────────────────────────────────────
        tests_dir  = os.path.join(INTEGRATION_DIR, 'tests')
        test_files = sorted(
            f for f in os.listdir(tests_dir)
            if f.endswith('.py') and not f.startswith('_')
            and (not only_prefix or f.startswith(only_prefix))
        )

        print('TAP version 13')
        # A harness-created test user that cannot authenticate is a broken environment,
        # not a reason to silently skip its tests: surface each as a failing TAP line and
        # force a non-zero exit below.
        for role, reason in getattr(runner, 'auth_failures', []):
            print(f'not ok - auth {role}: {reason}')
        load_failures = 0
        for fname in test_files:
            path = os.path.join(tests_dir, fname)
            try:
                mod = _load_module(path)
            except Exception as e:
                # A module that fails to import is a suite failure, not a silent
                # skip: record it and force a non-zero exit so a broken or missing
                # module cannot produce a green run. Other modules still run.
                load_failures += 1
                print(f'# ERROR loading {fname}: {e}', file=sys.stderr)
                print(f'not ok - load {fname}: {e}')
                continue
            runner.run_module(mod)

        ok = (runner.print_summary()
              and load_failures == 0
              and not getattr(runner, 'auth_failures', []))
    finally:
        if skip_cleanup:
            print('# Skipping environment cleanup (--skip-cleanup)', file=sys.stderr)
        else:
            cleanup_failed = _env_manager.cleanup()

    # Exit codes: 1 = a test/load/auth failure (dominates); 2 = tests passed but
    # one or more test resources could not be removed (leaked fixtures — distinct
    # so CI can tell a leak apart from a real failure); 0 = clean pass.
    if not ok:
        sys.exit(1)
    if cleanup_failed:
        print(f'# WARNING: {cleanup_failed} test resource(s) could not be removed; '
              'environment may need manual cleanup', file=sys.stderr)
        sys.exit(2)
    sys.exit(0)


if __name__ == '__main__':
    # When invoked as --cleanup by the bash EXIT/INT trap, run env cleanup only.
    if '--cleanup' in sys.argv:
        if _env_manager is not None and os.environ.get('DOCKSIDE_TEST_SKIP_CLEANUP', '0') != '1':
            _env_manager.cleanup()
        sys.exit(0)
    main()
