"""
11_admin_api.py — Admin API CRUD round-trips, driven entirely through the CLI.

The rest of the suite exercises the admin endpoints only as un-asserted _EnvManager
setup scaffolding.  This module asserts the persisted shape end-to-end via the
`dockside` CLI, covering the merge-gate fixes:

  - role create --permissions <json> persists permissions as a structured object,
    not a string.                                                       [test_01]
  - profile create --from-json persists the full body.                  [test_02]
  - user ssh.publicKeys round-trips.                                     [test_03]
  - account edit (/me/update) honours its self-edit whitelist: a user can change
    their own display name but cannot escalate their role.              [test_04]
  - state-changing endpoints reject GET with 405.                       [test_05]
  - non-object role permissions are rejected, not persisted.            [test_06]
  - SSH keypair private key is not overwritten when '<redacted>' is
    POSTed back (shallow-copy snapshot bug).                            [test_07]
  - gh_token is not overwritten when a masked value is POSTed back
    (missing restore-on-write).                                         [test_08]

Out of scope here (browser-only contracts, verified manually): the server's _json
profile-blob decode (the CLI sends real fields by design and never the _json
wrapper) and the Vue SSH editor.
"""

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase

# active:false → the server skips schema validation, so the body round-trips
# regardless of router/image specifics, keeping the test focused on persistence.
_PROFILE_BODY = {
    'description': 'created by 11_admin_api',
    'active':      False,
    'images':      ['debian:*'],
    'networks':    [],
    'runtimes':    [],
}


class AdminApiTests(TestCase):
    """Admin CRUD round-trips, asserting the persisted shape (CLI-driven)."""

    @classmethod
    def setUpClass(cls):
        cls._role     = cls._sfx('inttest-permrole')
        cls._prof     = cls._sfx('inttest-tmpprofile')
        cls._role_bad = cls._sfx('inttest-badrole')
        # Mutation tests use a dedicated throwaway user, never the shared dev1/dev2
        # fixtures: mutating a shared user leaks state into other modules and into
        # fixed-suffix reruns. This user is created here and removed in tearDownClass,
        # so the tests need no per-test restore.
        cls._user          = cls._sfx('inttest-adminapi-user')
        cls._user_password = 'inttest-adminapi-pass'
        cls.admin._run('user', 'create', cls._user,
                       '--role', cls.test_role_developer,
                       '--user-password', cls._user_password,
                       '--name', 'Admin API Test User')
        # A client authenticated AS the dedicated user, for the /me/update self-edit test.
        cls._user_client = cls.admin.with_credentials(cls._user, cls._user_password)

    @classmethod
    def tearDownClass(cls):
        for kind, name in (('role', cls._role), ('role', cls._role_bad),
                           ('profile', cls._prof), ('user', cls._user)):
            try:
                cls.admin._run(kind, 'remove', '--force', name)
            except Exception:
                pass

    # ── role permissions round-trip ────────────────────────────────────────────

    def test_01_role_permissions_round_trip(self):
        self.admin._run(
            'role', 'create', self._role,
            '--permissions', '{"actions":{"manageUsers":true,"manageProfiles":false}}',
        )
        rec = self.admin._run('role', 'get', self._role)
        self.assert_true(isinstance(rec, dict), 'role get did not return an object')
        perms = rec.get('permissions')
        self.assert_true(isinstance(perms, dict),
                         f'permissions persisted as non-object: {perms!r}')
        actions = perms.get('actions', perms)
        self.assert_true(isinstance(actions, dict) and bool(actions.get('manageUsers')),
                         f'manageUsers not persisted truthy: {perms!r}')

    # ── profile body round-trip via --from-json ─────────────────────────────────

    def test_02_profile_body_round_trip(self):
        body = dict(_PROFILE_BODY, name=self._prof)
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as fh:
            json.dump(body, fh)
            path = fh.name
        try:
            self.admin._run('profile', 'create', self._prof, '--from-json', path)
        finally:
            os.unlink(path)
        rec = self.admin._run('profile', 'get', self._prof)
        self.assert_true(isinstance(rec, dict), 'profile get did not return an object')
        # Assert the whole submitted body round-trips, not just images: a partial check
        # would pass even if create silently dropped most of the body.
        self.assert_in('debian:*', rec.get('images') or [],
                       f'profile body (images) not persisted: {rec!r}')
        self.assert_equal(rec.get('description'), _PROFILE_BODY['description'],
                          f'profile body (description) not persisted: {rec!r}')
        self.assert_true(not rec.get('active'),
                         f'profile body (active=false) not persisted: {rec.get("active")!r}')
        self.assert_equal(rec.get('networks') or [], [],
                          f'profile body (networks) not persisted: {rec!r}')
        self.assert_equal(rec.get('runtimes') or [], [],
                          f'profile body (runtimes) not persisted: {rec!r}')

    # ── user ssh.publicKeys round-trip ──────────────────────────────────────────

    def test_03_user_ssh_publickeys_round_trip(self):
        user = self._user
        key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY11111111111111111111 inttest@dev1'
        self.admin._run('user', 'edit', user, '--set', f'ssh.publicKeys.inttestkey={key}')
        rec = self.admin._run('user', 'get', user, '--sensitive')
        pubkeys = ((rec or {}).get('ssh') or {}).get('publicKeys') or {}
        self.assert_true(any(v == key for v in pubkeys.values()),
                         f'ssh.publicKeys did not round-trip: {pubkeys!r}')

    # ── /me/update self-edit whitelist (via `account edit`) ─────────────────────

    def test_04_account_edit_whitelist(self):
        # Act as the dedicated user (not shared dev1): this mutates the caller's own
        # record, and the user is discarded in tearDownClass.
        client = self._user_client
        before = client._run('whoami')
        self.assert_true(isinstance(before, dict), 'whoami did not return an object')
        orig_role = before.get('role')
        # Change own display name AND attempt to escalate role in the same call.
        client._run('account', 'edit', '--name', 'Int Test Name', '--set', 'role=admin')
        after = client._run('whoami')
        self.assert_equal(after.get('name'), 'Int Test Name',
                          'display name not updated via account edit')
        self.assert_equal(after.get('role'), orig_role,
                          'role was changed via /me/update — self-edit whitelist bypass!')

    # ── verb enforcement: mutations reject GET with 405 ─────────────────────────

    def test_05_get_on_mutation_is_405(self):
        base = self.admin._server.rstrip('/')
        # Non-destructive targets (missing name / nonexistent user): the only
        # pre/post-fix difference is the status — a 4xx app error before, 405 after.
        status, _ = self.admin.check_url(base + '/roles/create')
        self.assert_http_status(status, 405,
                                f'GET /roles/create returned {status}, expected 405')
        status2, _ = self.admin.check_url(base + '/users/inttest-verbcheck-absent/remove')
        self.assert_http_status(status2, 405,
                                f'GET /users/<x>/remove returned {status2}, expected 405')

    # ── SSH keypair private key round-trip ──────────────────────────────────────

    def test_07_ssh_keypair_private_roundtrip(self):
        """_restore_redacted_ssh must not write the '<redacted>' sentinel to disk."""
        user = self._user
        kp   = 'inttest-privkey'
        real_private = 'INTTEST_FAKE_PRIVATE_KEY_ROUNDTRIP_07'
        real_public  = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY33333 inttest@roundtrip'

        # Store a keypair with a known private key value.
        self.admin._run('user', 'edit', user,
                        '--set', f'ssh.keypairs.{kp}.private={real_private}',
                        '--set', f'ssh.keypairs.{kp}.public={real_public}')

        # Simulate the Vue round-trip: POST back '<redacted>' as the private key.
        self.admin._run('user', 'edit', user,
                        '--set', f'ssh.keypairs.{kp}.private=<redacted>',
                        '--set', f'ssh.keypairs.{kp}.public={real_public}')

        rec = self.admin._run('user', 'get', user, '--sensitive')
        stored_kps  = ((rec or {}).get('ssh') or {}).get('keypairs') or {}
        stored_priv = (stored_kps.get(kp) or {}).get('private')
        self.assert_equal(stored_priv, real_private,
                          f'private key overwritten by <redacted> sentinel: {stored_priv!r}')

    # ── gh_token round-trip ──────────────────────────────────────────────────────

    def test_08_gh_token_roundtrip(self):
        """_restore_redacted_gh_token must not write a masked gh_token to disk."""
        user  = self._user
        token = 'ghp_IntTestRoundtrip0000000000000008'

        # Set a known gh_token.
        self.admin._run('user', 'edit', user, '--gh-token', token)

        # GET without --sensitive: the response carries the masked form.
        rec    = self.admin._run('user', 'get', user)
        masked = (rec or {}).get('gh_token') or ''
        self.assert_true('*' in masked,
                         f'gh_token was not masked in non-sensitive response: {masked!r}')

        # POST the masked value back — simulates a client round-tripping the record.
        self.admin._run('user', 'edit', user, '--gh-token', masked)

        # The original token must survive.
        rec2   = self.admin._run('user', 'get', user, '--sensitive')
        stored = (rec2 or {}).get('gh_token') or ''
        self.assert_equal(stored, token,
                          f'gh_token overwritten by masked value: {stored!r}')

    # ── role record validation: non-object permissions rejected ─────────────────

    def test_06_role_non_object_permissions_rejected(self):
        # The CLI JSON-decodes --permissions client-side, so a quoted JSON string is a
        # valid-JSON *string* value — which the server must reject (a non-hash
        # permissions value crashes updateDerivedPermissions on the next reload).
        self.assert_api_error(
            lambda: self.admin._run('role', 'create', self._role_bad,
                                    '--permissions', '"not-an-object"'))
