"""
12_rejection.py — The server rejects invalid / unavailable resources and unsafe ops.

Negative-path coverage complementing the positive suites: each test asserts the server
REFUSES an invalid request rather than silently accepting it. Driven through the
`dockside` CLI like the rest of the suite.

  Group A — invalid entity references: launch from a non-existent profile; create/edit
            a user with a non-existent role; edit or remove a non-existent
            user / role / profile.
  Group B — profile-constrained value mismatches: create with an image / runtime /
            unixuser / network / IDE that the chosen profile does not permit.
  Group C — self-protection guards: an admin cannot strip its own manageUsers permission
            (lock-out, the C1-#6 guard) or delete its own account. These act on a
            dedicated throwaway admin-capable user via DocksideClient.with_credentials(),
            never the real admin, so a regression harms only the throwaway.
  Group D — role integrity guards: removeRole refuses a role still assigned to a user
            (no dangling refs); updateRole refuses removing manageUsers from the caller's
            OWN admin-granting role (lock-out via a custom, non-'admin' role + its user).
  Group E — reads of non-existent entities: getUser / getRole / getProfile must 404 on a
            name no fixture creates, rather than returning an empty or fabricated record.

If the server does NOT reject one of these, the corresponding test fails — surfacing a
server-side validation gap rather than letting it pass silently.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase

# A name no fixture ever creates: used wherever a test needs a reference the server must
# treat as non-existent.
_ABSENT = 'inttest-absent-zzzqp'


class RejectionTests(TestCase):
    """Server rejects references to resources that don't exist or aren't permitted."""

    @classmethod
    def setUpClass(cls):
        # A throwaway developer user for the "edit to a non-existent role" test, so we
        # never mutate a shared fixture user.
        cls._user = cls._sfx('inttest-rej-user')
        cls.admin._run('user', 'create', cls._user,
                       '--role', cls.test_role_developer,
                       '--user-password', 'inttest-rej-pass')
        # A throwaway admin-capable user (manageUsers via an explicit override) that acts
        # on ITSELF in the Group C self-guard tests, so a regression in those guards harms
        # only this user — never the real admin.
        cls._admin_user = cls._sfx('inttest-rej-admin')
        cls.admin._run('user', 'create', cls._admin_user,
                       '--role', cls.test_role_developer,
                       '--user-password', 'inttest-rej-pass',
                       '--set', 'permissions.manageUsers=1')
        cls._admin_client = cls.admin.with_credentials(cls._admin_user, 'inttest-rej-pass')

        # Fixtures for test_18 (updateRole self-lock-out): a CUSTOM admin-capable role
        # (deliberately NOT named 'admin', so the server's 'admin' role-NAME short-circuit
        # does not apply) and a user holding it. The user acts on its OWN admin-granting
        # role via cls._adminrole_client, so a regression in that guard harms only this
        # throwaway role/user — never the real admin or the built-in 'admin' role.
        cls._admin_role = cls._sfx('inttest-rej-adminrole')
        cls.admin._run('role', 'create', cls._admin_role,
                       '--set', 'permissions.manageUsers=1')
        cls._adminrole_user = cls._sfx('inttest-rej-adminrole-user')
        cls.admin._run('user', 'create', cls._adminrole_user,
                       '--role', cls._admin_role,
                       '--user-password', 'inttest-rej-pass')
        cls._adminrole_client = cls.admin.with_credentials(cls._adminrole_user,
                                                           'inttest-rej-pass')

    @classmethod
    def tearDownClass(cls):
        # Remove users before the role they reference: the server refuses to delete a role
        # still assigned to a user (see test_17), so the role removal would otherwise fail.
        for name in (cls._user, cls._admin_user, cls._adminrole_user):
            try:
                cls.admin._run('user', 'remove', '--force', name)
            except Exception:
                pass
        try:
            cls.admin._run('role', 'remove', '--force', cls._admin_role)
        except Exception:
            pass

    # ── Group A: invalid entity references ──────────────────────────────────────

    def test_01_launch_nonexistent_profile(self):
        name = self._sfx('inttest-rej-noprofile')
        self.register_cleanup(name)
        self.assert_api_error(
            lambda: self.admin.create(profile=_ABSENT, name=name, no_wait=True))

    def test_02_user_create_nonexistent_role(self):
        name = self._sfx('inttest-rej-newuser')
        try:
            self.assert_api_error(
                lambda: self.admin._run('user', 'create', name,
                                        '--role', _ABSENT,
                                        '--user-password', 'inttest-rej-pass'))
        finally:
            try:
                self.admin._run('user', 'remove', '--force', name)
            except Exception:
                pass

    def test_03_user_edit_nonexistent_role(self):
        self.assert_api_error(
            lambda: self.admin._run('user', 'edit', self._user, '--role', _ABSENT))

    def test_04_edit_absent_user(self):
        self.assert_api_error(
            lambda: self.admin._run('user', 'edit', _ABSENT, '--email', 'x@example.invalid'))

    def test_05_edit_absent_role(self):
        self.assert_api_error(
            lambda: self.admin._run('role', 'edit', _ABSENT, '--set', 'permissions.manageUsers=1'))

    def test_06_edit_absent_profile(self):
        self.assert_api_error(
            lambda: self.admin._run('profile', 'edit', _ABSENT, '--set', 'description=x'))

    def test_07_remove_absent_user(self):
        self.assert_api_error(
            lambda: self.admin._run('user', 'remove', '--force', _ABSENT))

    def test_08_remove_absent_role(self):
        self.assert_api_error(
            lambda: self.admin._run('role', 'remove', '--force', _ABSENT))

    def test_09_remove_absent_profile(self):
        self.assert_api_error(
            lambda: self.admin._run('profile', 'remove', '--force', _ABSENT))

    # ── Group B: profile-constrained value mismatches ───────────────────────────
    # test_profile_alpine permits only image alpine:latest and unixuser 'dockside'; a
    # value outside the profile's allow-list (or an unavailable network) must be refused.

    def _assert_create_rejected(self, base, **bad):
        name = self._sfx(base)
        self.register_cleanup(name)  # safety net if the server wrongly accepts it
        self.assert_api_error(
            lambda: self.admin.create(profile=self.test_profile_alpine,
                                      name=name, no_wait=True, **bad))

    def test_10_create_disallowed_image(self):
        self._assert_create_rejected('inttest-rej-image', image=self.test_image_nginx)

    def test_11_create_disallowed_runtime(self):
        self._assert_create_rejected('inttest-rej-runtime', runtime='inttest-bogus-runtime')

    def test_12_create_disallowed_unixuser(self):
        self._assert_create_rejected('inttest-rej-unixuser', unixuser='inttest-bogus-user')

    def test_13_create_unavailable_network(self):
        self._assert_create_rejected('inttest-rej-network', network=_ABSENT)

    def test_14_create_disallowed_ide(self):
        self._assert_create_rejected('inttest-rej-ide', ide='inttest/bogus-ide')

    # ── Group C: self-protection guards (act on a throwaway admin-capable user) ──

    def test_15_admin_cannot_remove_own_manageusers(self):
        """C1-#6 lock-out guard: an admin must not strip its own manageUsers permission."""
        self.assert_api_error(
            lambda: self._admin_client._run('user', 'edit', self._admin_user,
                                            '--set', 'permissions.manageUsers=0'))

    def test_16_admin_cannot_delete_own_account(self):
        """removeUser self-deletion guard: an admin must not delete its own account."""
        self.assert_api_error(
            lambda: self._admin_client._run('user', 'remove', '--force', self._admin_user))

    # ── Group D: role integrity guards ──────────────────────────────────────────
    # The 'admin' built-in role is intentionally NOT exercised by test_18: the server
    # short-circuits on the role NAME 'admin', so stripping its permissions does not
    # demote an admin-role user. That short-circuit is a non-rejection behavior and does
    # not fit this rejection suite's assert_api_error style, so it is left uncovered here.

    def test_17_remove_role_in_use(self):
        """removeRole must refuse a role still assigned to a user (no dangling refs)."""
        role = self._sfx('inttest-rej-inuserole')
        user = self._sfx('inttest-rej-inuser')
        created_role = False
        created_user = False
        try:
            self.admin._run('role', 'create', role, '--set', 'permissions.manageUsers=0')
            created_role = True
            self.admin._run('user', 'create', user,
                            '--role', role,
                            '--user-password', 'inttest-rej-pass')
            created_user = True
            self.assert_api_error(
                lambda: self.admin._run('role', 'remove', '--force', role))
        finally:
            # Remove the user first so the role is no longer in use, then the role —
            # so a server gap (wrongly accepting the in-use removal) never leaks fixtures.
            if created_user:
                try:
                    self.admin._run('user', 'remove', '--force', user)
                except Exception:
                    pass
            if created_role:
                try:
                    self.admin._run('role', 'remove', '--force', role)
                except Exception:
                    pass

    def test_18_admin_cannot_strip_own_admin_role(self):
        """updateRole self-lock-out: an admin must not remove manageUsers from its OWN
        admin-granting (custom) role. Exercises a guard added concurrently in the server,
        so assert only that the request is rejected — not an exact message/status."""
        self.assert_api_error(
            lambda: self._adminrole_client._run('role', 'edit', self._admin_role,
                                                '--set', 'permissions.manageUsers=0'))

    # ── Group E: reads of non-existent entities ─────────────────────────────────
    # getUser / getRole / getProfile must 404 on a name no fixture creates, rather than
    # returning an empty or fabricated record.

    def test_19_get_absent_user(self):
        self.assert_api_error(
            lambda: self.admin._run('user', 'get', _ABSENT))

    def test_20_get_absent_role(self):
        self.assert_api_error(
            lambda: self.admin._run('role', 'get', _ABSENT))

    def test_21_get_absent_profile(self):
        self.assert_api_error(
            lambda: self.admin._run('profile', 'get', _ABSENT))
