"""
04_access_and_http.py — MERGED: access control, HTTP proxy, and router visibility

Tests all observable effects simultaneously as user lists, access modes, and
developers/viewers are modified:
  - Who can list/get the container
  - What routers appear in list/get responses for each user
  - What HTTP status code the proxy returns for each user/mode combination

Uses two containers:
  inttest-ac-01    (alpine) — dev1 is owner; used for list/get/edit tests
  inttest-nginx-01 (nginx)  — admin is owner; used for HTTP proxy tests
"""

import sys
import os
import time
import urllib.parse

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError, http_check, verbose_enabled

_BASE_AC_CONTAINER    = 'inttest-ac-01'
_BASE_NGINX_CONTAINER = 'inttest-nginx-01'


class AccessAndHttpTests(TestCase):
    """
    Comprehensive access-control and HTTP-proxy test.

    Both containers persist across all test methods.  setUpClass computes
    suffixed names and creates them; tearDownClass removes them once.
    """

    @classmethod
    def setUpClass(cls):
        cls.AC_CONTAINER    = cls._sfx(_BASE_AC_CONTAINER)
        cls.NGINX_CONTAINER = cls._sfx(_BASE_NGINX_CONTAINER)

    @classmethod
    def tearDownClass(cls):
        for name in (cls.AC_CONTAINER, cls.NGINX_CONTAINER):
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
        """
        Build the canonical service URL for a container.
        local/harness: https://<prefix>-<name>.<domain-suffix>/
        remote:        requires parentFQDN from container data
        """
        if self.admin._connect_to:
            hostname = urllib.parse.urlparse(self.admin._server).hostname or ''
            parts    = hostname.split('.', 1)
            suffix   = parts[1] if len(parts) > 1 else hostname
            return f'https://{router_prefix}-{container_name}.{suffix}/'
        else:
            data        = self.admin.get_container(container_name)
            parent_fqdn = (data.get('data') or {}).get('parentFQDN') or data.get('parentFQDN') or ''
            return f'https://{router_prefix}-{container_name}{parent_fqdn}/'

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
            time.sleep(3)  # Let nginx fully initialise

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

    def _nginx_anon_status(self, router='www'):
        """
        Return HTTP status for the nginx service as an unauthenticated visitor
        (no session cookies at all).
        """
        service_url = self._service_url(self.NGINX_CONTAINER, router_prefix=router)
        try:
            code, _ = http_check(
                service_url,
                connect_to=self.admin._connect_to,
                cookies=None,
                verify_ssl=self.admin._verify_ssl,
            )
            return code
        except APIError as e:
            if verbose_enabled():
                connect_to = self.admin._connect_to or '(direct)'
                print(f'# anonymous nginx probe failed for url={service_url} '
                      f'connect_to={connect_to}: {e}', file=sys.stderr)
            return None

    def test_20_start_nginx(self):
        """Start the nginx container and wait for it to be ready."""
        self._ensure_nginx_running()
        data = self.admin.get_container(self.NGINX_CONTAINER)
        self.assert_equal(data.get('status'), 1, 'nginx not running after start')

    def test_21_default_developer_owner_gets_200(self):
        """Owner gets 200 in developer mode (default)."""
        self._ensure_nginx_running()
        try:
            self.admin.update(self.NGINX_CONTAINER, access='{"www":"developer"}')
        except APIError:
            pass
        code = self._nginx_status(self.admin)
        if code is None:
            self.skip('Could not reach nginx service')
        self.assert_http_status(code, 200, f'owner got {code} in developer mode')

    def test_22_default_developer_unauth_gets_400(self):
        """Unauthenticated user gets 400 in developer mode."""
        self._ensure_nginx_running()
        try:
            self.admin.update(self.NGINX_CONTAINER, access='{"www":"developer"}')
        except APIError:
            pass
        code = self._nginx_anon_status()
        if code is None:
            self.skip('Could not reach nginx service anonymously')
        self.assert_http_status(code, 400, f'unauth got {code} instead of 400 in developer mode')

    def test_23_public_mode_unauth_gets_200(self):
        """Unauthenticated user gets 200 in public mode."""
        self._ensure_nginx_running()
        try:
            self.admin.update(self.NGINX_CONTAINER, access='{"www":"public"}')
        except APIError as e:
            self.skip(f'Cannot set public mode: {e}')
        code = self._nginx_anon_status()
        if code is None:
            self.skip('Could not reach nginx service anonymously')
        self.assert_http_status(code, 200, f'unauth got {code} instead of 200 in public mode')

    def test_24_public_mode_viewer_gets_200(self):
        """Viewer (not in viewers list) gets 200 in public mode."""
        self._ensure_nginx_running()
        self.admin.update(self.NGINX_CONTAINER, viewers='')
        try:
            self.admin.update(self.NGINX_CONTAINER, access='{"www":"public"}')
        except APIError as e:
            self.skip(f'Cannot set public mode: {e}')
        code = self._nginx_status(self.viewer)
        if code is None:
            self.skip('Could not reach nginx service')
        self.assert_http_status(code, 200, f'viewer got {code} in public mode')

    def test_25_user_mode_unauth_gets_400(self):
        """Unauthenticated user gets 400 in user mode."""
        self._ensure_nginx_running()
        try:
            self.admin.update(self.NGINX_CONTAINER, access='{"www":"user"}')
        except APIError as e:
            self.skip(f'Cannot set user mode: {e}')
        code = self._nginx_anon_status()
        if code is None:
            self.skip('Could not reach nginx service anonymously')
        self.assert_http_status(code, 400, f'unauth got {code} in user mode')

    def test_26_user_mode_authenticated_gets_200(self):
        """Authenticated user (viewer, not in viewers list) gets 200 in user mode."""
        self._ensure_nginx_running()
        self.admin.update(self.NGINX_CONTAINER, viewers='')
        try:
            self.admin.update(self.NGINX_CONTAINER, access='{"www":"user"}')
        except APIError as e:
            self.skip(f'Cannot set user mode: {e}')
        code = self._nginx_status(self.viewer)
        if code is None:
            self.skip('Could not reach nginx service')
        self.assert_http_status(code, 200, f'viewer got {code} in user mode')

    def test_27_viewer_mode_named_viewer_gets_200(self):
        """Named viewer gets 200 when access=viewer."""
        self._ensure_nginx_running()
        self.admin.update(self.NGINX_CONTAINER, viewers=self.test_username_viewer)
        try:
            self.admin.update(self.NGINX_CONTAINER, access='{"www":"viewer"}')
        except APIError as e:
            self.skip(f'Cannot set viewer mode: {e}')
        code = self._nginx_status(self.viewer)
        if code is None:
            self.skip('Could not reach nginx service')
        self.assert_http_status(code, 200, f'named viewer got {code} in viewer mode')

    def test_28_viewer_mode_unnamed_dev2_gets_410(self):
        """dev2 (not in developers/viewers) gets 410 in viewer mode."""
        self._ensure_nginx_running()
        self.admin.update(self.NGINX_CONTAINER, viewers=self.test_username_viewer, developers='')
        try:
            self.admin.update(self.NGINX_CONTAINER, access='{"www":"viewer"}')
        except APIError as e:
            self.skip(f'Cannot set viewer mode: {e}')
        code = self._nginx_status(self.dev2)
        if code is None:
            self.skip('Could not reach nginx service')
        self.assert_http_status(code, 410, f'unnamed dev2 got {code} in viewer mode')

    def test_29_developer_mode_named_dev2_gets_200(self):
        """dev2 in developers list gets 200 in developer mode."""
        self._ensure_nginx_running()
        self.admin.update(self.NGINX_CONTAINER, developers=self.test_username_dev2)
        try:
            self.admin.update(self.NGINX_CONTAINER, access='{"www":"developer"}')
        except APIError:
            pass
        code = self._nginx_status(self.dev2)
        if code is None:
            self.skip('Could not reach nginx service')
        self.assert_http_status(code, 200, f'named dev2 got {code} in developer mode')

    def test_30_developer_mode_viewer_gets_410(self):
        """Viewer (even if named in viewers list) gets 410 in developer mode."""
        self._ensure_nginx_running()
        self.admin.update(self.NGINX_CONTAINER, viewers=self.test_username_viewer,
                          developers=self.test_username_dev2)
        try:
            self.admin.update(self.NGINX_CONTAINER, access='{"www":"developer"}')
        except APIError:
            pass
        code = self._nginx_status(self.viewer)
        if code is None:
            self.skip('Could not reach nginx service')
        self.assert_http_status(code, 410, f'viewer got {code} in developer mode')

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
