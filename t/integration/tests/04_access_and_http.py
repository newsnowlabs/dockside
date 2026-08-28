"""
04_access_and_http.py — MERGED: access control, HTTP proxy, and router visibility

Tests all observable effects simultaneously as user lists, access modes, and
developers/viewers are modified:
  - Who can list/get the container
  - What routers appear in list/get responses for each user
  - What HTTP status code the proxy returns for each user/mode combination

Uses three containers:
  inttest-ac-01     (alpine)               — dev1 is owner; used for list/get/edit tests
  inttest-nginx-01  (nginx)                — admin is owner; used for HTTP proxy tests
  inttest-router-01 (alpine, userRouters=1) — dev1 is owner; used for router add/remove/replace
                                              tests (docs/adr/0008-router-mutation.md) - its
                                              own profile/container so AC_CONTAINER's profile
                                              (userRouters unset) stays available for the
                                              negative "profile does not allow this" case
"""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError, verbose_enabled

_BASE_AC_CONTAINER     = 'inttest-ac-01'
_BASE_NGINX_CONTAINER  = 'inttest-nginx-01'
_BASE_ROUTER_CONTAINER = 'inttest-router-01'


class AccessAndHttpTests(TestCase):
    """
    Comprehensive access-control and HTTP-proxy test.

    Both containers persist across all test methods.  setUpClass computes
    suffixed names and creates them; tearDownClass removes them once.
    """

    @classmethod
    def setUpClass(cls):
        cls.AC_CONTAINER     = cls._sfx(_BASE_AC_CONTAINER)
        cls.NGINX_CONTAINER  = cls._sfx(_BASE_NGINX_CONTAINER)
        cls.ROUTER_CONTAINER = cls._sfx(_BASE_ROUTER_CONTAINER)

    @classmethod
    def tearDownClass(cls):
        for name in (cls.AC_CONTAINER, cls.NGINX_CONTAINER, cls.ROUTER_CONTAINER):
            for fn in (
                lambda n=name: cls.admin.stop(n, wait=False),
                lambda n=name: cls.admin.remove(n, wait=False),
            ):
                try:
                    fn()
                except Exception:
                    pass

    # ── URL helpers ───────────────────────────────────────────────────────────

    def _service_url(self, container_name, router_prefix='www'):
        """Build the canonical service URL for a container."""
        return self.admin.service_url(container_name, router_prefix)

    # ──────────────────────────────────────────────────────────────────────────
    # Section A — Initial visibility (no sharing)
    # ──────────────────────────────────────────────────────────────────────────

    def test_01_create_containers(self):
        """Create both test containers."""
        try:
            self.dev1.create(profile=self.test_profile_alpine, name=self.AC_CONTAINER)
        except APIError as e:
            if 'already' in str(e).lower() or 'exists' in str(e).lower():
                pass
            else:
                raise
        try:
            self.admin.create(profile=self.test_profile_nginx, name=self.NGINX_CONTAINER)
        except APIError as e:
            if 'already' in str(e).lower() or 'exists' in str(e).lower():
                pass
            else:
                raise
        try:
            self.dev1.create(profile=self.test_profile_router, name=self.ROUTER_CONTAINER)
        except APIError as e:
            if 'already' in str(e).lower() or 'exists' in str(e).lower():
                pass
            else:
                raise

    def test_02_owner_sees_own(self):
        names = self.container_names_in_list(self.dev1)
        self.assert_in(self.AC_CONTAINER, names, 'Owner (dev1) cannot see their own container')

    def test_03_dev2_cannot_see_unshared(self):
        names = self.container_names_in_list(self.dev2)
        self.assert_not_in(self.AC_CONTAINER, names, 'dev2 can see unshared container')

    def test_04_admin_sees_all(self):
        names = self.container_names_in_list(self.admin)
        self.assert_in(self.AC_CONTAINER, names, 'admin cannot see container (missing viewAllContainers?)')
        self.assert_in(self.NGINX_CONTAINER, names, 'admin cannot see nginx container')

    def test_05_viewer_cannot_see_unshared(self):
        names = self.container_names_in_list(self.viewer)
        self.assert_not_in(self.AC_CONTAINER, names, 'viewer can see unshared container')

    # ──────────────────────────────────────────────────────────────────────────
    # Section B — Viewer sharing
    # ──────────────────────────────────────────────────────────────────────────

    def test_06_add_viewer_grants_list_visibility(self):
        self.admin.update(self.AC_CONTAINER, viewers=self.test_username_viewer)
        names = self.container_names_in_list(self.viewer)
        self.assert_in(self.AC_CONTAINER, names, 'viewer not visible after being added to viewers list')

    def test_07_viewer_can_get(self):
        self.admin.update(self.AC_CONTAINER, viewers=self.test_username_viewer)
        data = self.viewer.get_container(self.AC_CONTAINER)
        self.assert_true(isinstance(data, dict), 'viewer get_container returned non-dict')

    def test_08_viewers_field_correct(self):
        self.admin.update(self.AC_CONTAINER, viewers=self.test_username_viewer)
        data = self.dev1.get_container(self.AC_CONTAINER)
        viewers = (data.get('meta') or {}).get('viewers') or []
        if isinstance(viewers, str):
            viewers = [v.strip() for v in viewers.split(',') if v.strip()]
        self.assert_in(self.test_username_viewer, viewers,
                       f'{self.test_username_viewer!r} not in meta.viewers')

    def test_09_viewer_cannot_edit(self):
        self.admin.update(self.AC_CONTAINER, viewers=self.test_username_viewer)
        self.assert_api_error(
            self.viewer.update, self.AC_CONTAINER, description='viewer tried to edit'
        )

    # ──────────────────────────────────────────────────────────────────────────
    # Section C — Developer sharing (dev2)
    # ──────────────────────────────────────────────────────────────────────────

    def test_10_add_dev2_grants_list_visibility(self):
        self.admin.update(self.AC_CONTAINER,
                          developers=f'{self.test_username_dev1},{self.test_username_dev2}')
        names = self.container_names_in_list(self.dev2)
        self.assert_in(self.AC_CONTAINER, names, 'dev2 cannot see container after being added as developer')

    def test_11_dev2_can_edit(self):
        self.admin.update(self.AC_CONTAINER,
                          developers=f'{self.test_username_dev1},{self.test_username_dev2}')
        self.dev2.update(self.AC_CONTAINER, description='edited by dev2')
        data = self.dev1.get_container(self.AC_CONTAINER)
        desc = (data.get('meta') or {}).get('description') or data.get('description') or ''
        self.assert_equal(desc, 'edited by dev2', 'description not updated by dev2')

    def test_12_developers_field_correct(self):
        self.admin.update(self.AC_CONTAINER,
                          developers=f'{self.test_username_dev1},{self.test_username_dev2}')
        data = self.dev1.get_container(self.AC_CONTAINER)
        devs = (data.get('meta') or {}).get('developers') or []
        if isinstance(devs, str):
            devs = [d.strip() for d in devs.split(',') if d.strip()]
        self.assert_in(self.test_username_dev2, devs,
                       f'{self.test_username_dev2!r} not in meta.developers')

    # ──────────────────────────────────────────────────────────────────────────
    # Section D — Router visibility filtering (list/get)
    # ──────────────────────────────────────────────────────────────────────────

    def test_13_developer_mode_viewer_listing_hides_www_router(self):
        """With access=developer (default), viewer should see no routers."""
        self.admin.update(self.AC_CONTAINER, viewers=self.test_username_viewer,
                          developers=self.test_username_dev1)
        try:
            self.admin.update(self.AC_CONTAINER, access='{"www":"developer"}')
        except APIError:
            pass
        routers = self.get_routers_for(self.viewer, self.AC_CONTAINER)
        self.assert_true(
            'www' not in routers,
            f'viewer sees www router in developer mode: {routers}'
        )

    def test_14_developer_mode_viewer_get_hides_www_router(self):
        """get_container for viewer should also show no/empty routers when developer mode."""
        self.admin.update(self.AC_CONTAINER, viewers=self.test_username_viewer,
                          developers=self.test_username_dev1)
        try:
            self.admin.update(self.AC_CONTAINER, access='{"www":"developer"}')
        except APIError:
            pass
        routers = self.get_routers_for(self.viewer, self.AC_CONTAINER)
        self.assert_true('www' not in routers,
                         f'viewer get shows www router in developer mode: {routers}')

    def test_15_viewer_mode_viewer_listing_shows_www_router(self):
        """With access=viewer, viewer should see www router."""
        self.admin.update(self.AC_CONTAINER, viewers=self.test_username_viewer)
        try:
            self.admin.update(self.AC_CONTAINER, access='{"www":"viewer"}')
        except APIError as e:
            self.skip(f'Cannot set viewer access mode: {e}')
        routers = self.get_routers_for(self.viewer, self.AC_CONTAINER)
        self.assert_in('www', routers,
                       f'viewer does not see www router in viewer mode; routers={routers}')

    def test_16_viewer_mode_viewer_get_shows_www_router(self):
        """get_container for viewer shows www router in viewer mode."""
        self.admin.update(self.AC_CONTAINER, viewers=self.test_username_viewer)
        try:
            self.admin.update(self.AC_CONTAINER, access='{"www":"viewer"}')
        except APIError as e:
            self.skip(f'Cannot set viewer access mode: {e}')
        routers = self.get_routers_for(self.viewer, self.AC_CONTAINER)
        self.assert_in('www', routers,
                       f'viewer get does not show www router in viewer mode')

    # ──────────────────────────────────────────────────────────────────────────
    # Section E — HTTP proxy access control (nginx container)
    # ──────────────────────────────────────────────────────────────────────────

    def _ensure_nginx_running(self):
        """Start nginx if not already running; wait for it."""
        try:
            data = self.admin.get_container(self.NGINX_CONTAINER)
        except APIError:
            self.admin.create(profile=self.test_profile_nginx, name=self.NGINX_CONTAINER)
            data = self.admin.get_container(self.NGINX_CONTAINER)
        if data.get('status') != 1:
            self.admin.start(self.NGINX_CONTAINER, wait=True, timeout=120)
        self.wait_until(
            lambda: self._nginx_status(self.admin) == 200,
            timeout=20,
            interval=1,
            timeout_msg='nginx owner route did not become ready',
        )

    def _nginx_status(self, client, router='www'):
        """Return HTTP status code for the nginx container's www service."""
        service_url = self._service_url(self.NGINX_CONTAINER, router_prefix=router)
        try:
            status, _ = client.check_url(service_url)
        except APIError as e:
            if verbose_enabled():
                user = getattr(client, '_username', None) or 'anonymous'
                print(f'# nginx probe failed for user={user} url={service_url}: {e}',
                      file=sys.stderr)
            return None
        return status

    def _set_nginx_access(self, mode, developers=None, viewers=None):
        """Apply access mode and named principals for nginx router tests."""
        self._ensure_nginx_running()
        if developers is not None:
            self.admin.update(self.NGINX_CONTAINER, developers=developers)
        if viewers is not None:
            self.admin.update(self.NGINX_CONTAINER, viewers=viewers)
        try:
            self.admin.update(self.NGINX_CONTAINER, access=f'{{"www":"{mode}"}}')
        except APIError as e:
            self.skip(f'Cannot set {mode} mode: {e}')

    def _assert_nginx_mode_matrix(self, mode, expected_by_principal):
        """Assert nginx router responses for the standard access matrix."""
        self._set_nginx_access(
            mode,
            developers=self.test_username_dev2,
            viewers=self.test_username_viewer,
        )
        principals = [
            ('owner', self.admin),
            ('named developer', self.dev2),
            ('named viewer', self.viewer),
            ('authenticated user', self.user),
            ('view-all user', self.view_all),
            ('develop-all user', self.develop_all),
            ('anonymous', self.unauth),
        ]
        for label, client in principals:
            code = self._nginx_status(client)
            if code is None:
                self.skip(f'Could not reach nginx service for {label}')
            expected = expected_by_principal[label]
            self.assert_http_status(
                code,
                expected,
                f'{label} got {code} in {mode} mode',
            )

    def test_20_start_nginx(self):
        """Start the nginx container and wait for it to be ready."""
        self._ensure_nginx_running()
        data = self.admin.get_container(self.NGINX_CONTAINER)
        self.assert_equal(data.get('status'), 1, 'nginx not running after start')

    def test_21_developer_mode_access_matrix(self):
        """Developer mode: owner and named developers only."""
        self._assert_nginx_mode_matrix('developer', {
            'owner': 200,
            'named developer': 200,
            'named viewer': 410,
            'authenticated user': 410,
            'view-all user': 410,
            'develop-all user': 200,
            'anonymous': 400,
        })

    def test_22_viewer_mode_access_matrix(self):
        """Viewer mode: owner, named developers, and named viewers only."""
        self._assert_nginx_mode_matrix('viewer', {
            'owner': 200,
            'named developer': 200,
            'named viewer': 200,
            'authenticated user': 410,
            'view-all user': 200,
            'develop-all user': 410,
            'anonymous': 400,
        })

    def test_23_user_mode_access_matrix(self):
        """User mode: any authenticated target user may access; anonymous may not."""
        self._assert_nginx_mode_matrix('user', {
            'owner': 200,
            'named developer': 200,
            'named viewer': 200,
            'authenticated user': 200,
            'view-all user': 200,
            'develop-all user': 200,
            'anonymous': 400,
        })

    def test_24_public_mode_access_matrix(self):
        """Public mode: all authenticated and target-anonymous probes succeed."""
        self._assert_nginx_mode_matrix('public', {
            'owner': 200,
            'named developer': 200,
            'named viewer': 200,
            'authenticated user': 200,
            'view-all user': 200,
            'develop-all user': 200,
            'anonymous': 200,
        })

    def test_31_router_listing_reflects_access_mode(self):
        """Router visibility in list matches access mode: dev2 sees www in developer mode, viewer doesn't."""
        self._ensure_nginx_running()
        self.admin.update(self.NGINX_CONTAINER, developers=self.test_username_dev2,
                          viewers=self.test_username_viewer)
        try:
            self.admin.update(self.NGINX_CONTAINER, access='{"www":"developer"}')
        except APIError:
            pass
        dev2_routers   = self.get_routers_for(self.dev2, self.NGINX_CONTAINER)
        viewer_routers = self.get_routers_for(self.viewer, self.NGINX_CONTAINER)
        self.assert_in('www', dev2_routers,
                       f'dev2 does not see www router in developer mode: {dev2_routers}')
        self.assert_true('www' not in viewer_routers,
                         f'viewer sees www router in developer mode: {viewer_routers}')

    # ──────────────────────────────────────────────────────────────────────────
    # Section F — Router mutation (docs/adr/0008-router-mutation.md)
    #
    # ROUTER_CONTAINER (dev1-owned, inttest-router profile with userRouters=1) exercises the
    # permission + developer-standing + profile-gate matrix for add; AC_CONTAINER (dev1-owned,
    # inttest-alpine profile, userRouters unset) is reused for the negative profile-gate case.
    # NGINX_CONTAINER doubles for a genuine live-reachability check (Section E's server is
    # already running there, so a new router pointed at its own port 80 is provably real - no
    # need to stand up a second server just for this).
    #
    # Not covered here: gatewayMode rejection on add - a host-level, not per-reservation, config
    # the harness has no supported way to toggle per-test; left to manual/unit-level verification
    # rather than forcing a brittle test around it.
    # ──────────────────────────────────────────────────────────────────────────

    def test_40_router_add_rejected_without_permission(self):
        """viewer (no addContainerRouter permission at all) cannot add a router."""
        self.assert_api_error(
            lambda: self.viewer.add_router(self.ROUTER_CONTAINER, prefix='nope', port=9001))

    def test_41_router_add_rejected_without_developer_standing(self):
        """dev2 holds addContainerRouter (shared role with dev1) but isn't owner/developer here."""
        self.assert_api_error(
            lambda: self.dev2.add_router(self.ROUTER_CONTAINER, prefix='nope2', port=9002))

    def test_42_router_add_rejected_when_profile_disallows(self):
        """dev1 (owner, has permission) is still rejected: AC_CONTAINER's profile has no userRouters."""
        self.assert_api_error(
            lambda: self.dev1.add_router(self.AC_CONTAINER, prefix='nope3', port=9003))

    def test_43_router_add_succeeds_for_owner_on_userRouters_profile(self):
        """dev1 (owner) adds a router on the userRouters=1 profile; it's live, type=user."""
        self.dev1.add_router(self.ROUTER_CONTAINER, prefix='extra', port=9101)
        data = self.dev1.get_container(self.ROUTER_CONTAINER)
        routers = (data.get('profileObject') or {}).get('routers') or []
        added = next((r for r in routers if r.get('name') == 'extra'), None)
        self.assert_true(added is not None, f'added router not present: {routers}')
        self.assert_equal(added.get('type'), 'user', "added router's type is not 'user'")
        access = (data.get('meta') or {}).get('access') or {}
        self.assert_equal(access.get('extra'), 'owner',
                          "added router's meta.access was not set to the default for an "
                          "owner-added router ('owner') - without any meta.access entry it "
                          "would be invisible to every client despite being live (see "
                          "docs/adr/0008-router-mutation.md)")

    def test_44_router_add_rejects_duplicate_name(self):
        """Adding a router with a name already in use is a collision, not a silent shadow."""
        # No hyphen in the prefix - this must fail on the name collision specifically, not be
        # a false positive from the separate hyphenated-prefix rejection.
        self.assert_api_error(
            lambda: self.dev1.add_router(self.ROUTER_CONTAINER, prefix='extraagain', port=9102, router_name='extra'))

    def test_45_router_remove_rejected_for_ide_type(self):
        """The auto-injected 'ide' router can never be removed, even by the owner."""
        self.assert_api_error(
            lambda: self.dev1.remove_router(self.ROUTER_CONTAINER, 'ide'))

    def test_46_router_remove_succeeds_for_shared_developer_not_just_creator(self):
        """dev2, once shared as a developer (but not the one who added it), can remove it too."""
        self.dev1.update(self.ROUTER_CONTAINER, developers=self.test_username_dev2)
        # No hyphen in the prefix (only in the router's own name, which is fine) - a hyphenated
        # *prefix* is rejected server-side, since the proxy treats any hyphen in an actual
        # request prefix as a passthrough indicator (see Reservation::normalise_router_def).
        self.dev1.add_router(self.ROUTER_CONTAINER, prefix='sharedtest', port=9103, router_name='shared-test')
        # dev2 did not add 'shared-test' - only shares developer standing on the reservation.
        self.dev2.remove_router(self.ROUTER_CONTAINER, 'shared-test')
        routers = self.get_routers_for(self.dev1, self.ROUTER_CONTAINER)
        self.assert_true('shared-test' not in routers,
                         f"dev2's remove of a router it didn't create had no effect: {routers}")

    def test_47_router_replace_carries_access_forward(self):
        """replace (same name) keeps the existing meta.access value, only the port changes."""
        self.dev1.add_router(self.ROUTER_CONTAINER, prefix='replaceme', port=9104, router_name='replaceme')
        self.dev1.update(self.ROUTER_CONTAINER, access='{"replaceme":"owner"}')
        self.dev1.replace_router(self.ROUTER_CONTAINER, 'replaceme', prefix='replaceme', port=9105)
        data = self.dev1.get_container(self.ROUTER_CONTAINER)
        routers = (data.get('profileObject') or {}).get('routers') or []
        replaced = next((r for r in routers if r.get('name') == 'replaceme'), None)
        self.assert_true(replaced is not None, 'replaced router not present')
        port = ((replaced.get('https') or replaced.get('http') or {}).get('port'))
        self.assert_equal(port, 9105, f'replace did not update the port: {replaced}')
        access = (data.get('meta') or {}).get('access') or {}
        self.assert_equal(access.get('replaceme'), 'owner',
                          "replace did not carry the pre-existing access level ('owner') forward")

    def test_48_router_add_succeeds_for_admin_bypassing_profile_gate(self):
        """admin adds a router even though NGINX_CONTAINER's profile has no userRouters."""
        self._ensure_nginx_running()
        # Points at nginx's own real listening port (80, already proxied by the 'www' router) -
        # so the next test can prove it's genuinely live, not just present in metadata.
        self.admin.add_router(self.NGINX_CONTAINER, prefix='adminadded', port=80)
        routers = self.get_routers_for(self.admin, self.NGINX_CONTAINER)
        self.assert_in('adminadded', routers, f'admin-added router not present: {routers}')

    def test_49_router_added_by_admin_is_live_reachable(self):
        """The router test_48 added works against the real, already-running nginx - no restart."""
        service_url = self._service_url(self.NGINX_CONTAINER, router_prefix='adminadded')
        status, _ = self.admin.check_url(service_url)
        self.assert_http_status(status, 200, f'admin-added router not live-reachable: {status}')

    def test_50_router_default_auth_allows_widening_access_later(self):
        """With no --auth given, the wide default allow-list still permits widening to 'public'."""
        self.dev1.add_router(self.ROUTER_CONTAINER, prefix='widenme', port=9105, router_name='widenme')
        self.dev1.update(self.ROUTER_CONTAINER, access='{"widenme":"public"}')
        data = self.dev1.get_container(self.ROUTER_CONTAINER)
        access = (data.get('meta') or {}).get('access') or {}
        self.assert_equal(access.get('widenme'), 'public',
                          "widening a default-auth router's access to 'public' was rejected")

    def test_51_router_custom_auth_is_honoured_and_enforced(self):
        """--auth narrows what a router's access can ever be set to, not just its starting value.

        Added by dev2, a shared developer but *not* the owner (test_46 shared developer standing
        on ROUTER_CONTAINER) - dev2's own preferred default is 'developer' (see
        User::_defaultRouterAccessLevel), which isn't in this router's caller-narrowed auth list,
        so this genuinely exercises the fallback-to-sole-permitted-level path, not just a
        coincidence of dev1 (the owner) already preferring 'owner'.
        """
        self.dev2.add_router(self.ROUTER_CONTAINER, prefix='locked', port=9106,
                             router_name='locked', auth=['owner'])
        data = self.dev1.get_container(self.ROUTER_CONTAINER)
        routers = (data.get('profileObject') or {}).get('routers') or []
        locked = next((r for r in routers if r.get('name') == 'locked'), None)
        self.assert_true(locked is not None, 'custom-auth router not present')
        self.assert_equal(locked.get('auth'), ['owner'], "custom 'auth' list was not honoured")
        access = (data.get('meta') or {}).get('access') or {}
        self.assert_equal(access.get('locked'), 'owner',
                          "default access level did not fall back to the sole permitted level "
                          "('owner') when dev2's own preferred default ('developer') isn't in "
                          "a caller-narrowed auth list")
        # 'developer' is not in this router's auth list, so widening (or any change) to it must
        # still be rejected even though dev2 (the adder) has developer standing on this reservation.
        self.assert_api_error(
            lambda: self.dev1.update(self.ROUTER_CONTAINER, access='{"locked":"developer"}'))

    def test_52_router_add_default_access_depends_on_adder_identity(self):
        """A developer (not the owner) adding a router defaults to 'developer', not 'owner' -
        the counterpart of test_43 (an owner-added router defaults to 'owner')."""
        self.dev2.add_router(self.ROUTER_CONTAINER, prefix='devadded', port=9107,
                             router_name='devadded')
        data = self.dev1.get_container(self.ROUTER_CONTAINER)
        access = (data.get('meta') or {}).get('access') or {}
        self.assert_equal(access.get('devadded'), 'developer',
                          "a router added by a shared developer (not the owner) did not "
                          "default to 'developer' access")

    def test_53_router_add_explicit_access_overrides_default(self):
        """--access explicitly overrides the owner/developer default, either direction."""
        self.dev1.add_router(self.ROUTER_CONTAINER, prefix='ownerpicksdev', port=9108,
                             router_name='ownerpicksdev', access='developer')
        data = self.dev1.get_container(self.ROUTER_CONTAINER)
        access = (data.get('meta') or {}).get('access') or {}
        self.assert_equal(access.get('ownerpicksdev'), 'developer',
                          "--access did not override the owner's own default ('owner')")

    def test_54_router_add_rejects_access_not_in_auth_list(self):
        """An explicit --access value not permitted by --auth is rejected, not silently coerced."""
        self.assert_api_error(
            lambda: self.dev1.add_router(self.ROUTER_CONTAINER, prefix='badaccess', port=9109,
                                         router_name='badaccess', auth=['owner'], access='developer'))

    def test_55_router_auth_accepts_comma_separated_list(self):
        """--auth accepts a single comma-separated value, equivalent to repeating the flag."""
        self.dev1.add_router(self.ROUTER_CONTAINER, prefix='commaauth', port=9110,
                             router_name='commaauth', auth=['owner,developer'])
        data = self.dev1.get_container(self.ROUTER_CONTAINER)
        routers = (data.get('profileObject') or {}).get('routers') or []
        commaauth = next((r for r in routers if r.get('name') == 'commaauth'), None)
        self.assert_true(commaauth is not None, 'comma-auth router not present')
        self.assert_equal(sorted(commaauth.get('auth') or []), ['developer', 'owner'],
                          "comma-separated --auth value was not parsed into both levels")

    def test_56_router_auth_accepts_repeated_flags(self):
        """--auth also works given as separate repeated flags, not just one comma-separated value
        (test_55's form) - both are supposed to accumulate into the same combined list."""
        self.dev1.add_router(self.ROUTER_CONTAINER, prefix='repeatedauth', port=9111,
                             router_name='repeatedauth', auth=['owner', 'developer'])
        data = self.dev1.get_container(self.ROUTER_CONTAINER)
        routers = (data.get('profileObject') or {}).get('routers') or []
        repeated = next((r for r in routers if r.get('name') == 'repeatedauth'), None)
        self.assert_true(repeated is not None, 'repeated --auth flags router not present')
        self.assert_equal(sorted(repeated.get('auth') or []), ['developer', 'owner'],
                          "repeated --auth flags were not both honoured")

    def test_57_router_replace_auth_narrowing_falls_back_like_add(self):
        """--auth/--access apply to 'replace' too, not just 'add'. Narrowing --auth on replace to
        exclude the carried-forward value rules out carry-forward, falling back to the same
        owner/developer-aware default 'add' would use - not the old value, and not a bare
        'developer'."""
        self.dev1.add_router(self.ROUTER_CONTAINER, prefix='replacenarrow', port=9112,
                             router_name='replacenarrow')
        # dev1 (owner) added it, so it starts at 'owner' (test_43's rule) - confirm that first,
        # since the rest of this test depends on it.
        data = self.dev1.get_container(self.ROUTER_CONTAINER)
        access = (data.get('meta') or {}).get('access') or {}
        self.assert_equal(access.get('replacenarrow'), 'owner', 'unexpected starting access level')
        self.dev1.replace_router(self.ROUTER_CONTAINER, 'replacenarrow', prefix='replacenarrow',
                                 port=9112, auth=['developer', 'public'])
        data = self.dev1.get_container(self.ROUTER_CONTAINER)
        access = (data.get('meta') or {}).get('access') or {}
        self.assert_equal(access.get('replacenarrow'), 'developer',
                          "replace did not fall back to the new auth list's first entry "
                          "('developer') once the carried-forward value ('owner') became illegal")

    def test_58_router_replace_explicit_access_used_when_carry_forward_invalid(self):
        """--access on replace is only consulted once carry-forward is ruled out (the old value
        is no longer legal under the new --auth); it then picks the specific level requested,
        not just the owner/developer default."""
        self.dev1.add_router(self.ROUTER_CONTAINER, prefix='replaceexplicit', port=9113,
                             router_name='replaceexplicit')
        self.dev1.replace_router(self.ROUTER_CONTAINER, 'replaceexplicit', prefix='replaceexplicit',
                                 port=9113, auth=['developer', 'public'], access='public')
        data = self.dev1.get_container(self.ROUTER_CONTAINER)
        access = (data.get('meta') or {}).get('access') or {}
        self.assert_equal(access.get('replaceexplicit'), 'public',
                          "--access on replace was not honoured once carry-forward became invalid")
