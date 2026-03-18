"""
04_access_and_http.py — MERGED: access control, HTTP proxy, and router visibility

Tests all observable effects simultaneously as user lists, access modes, and
developers/viewers are modified:
  - Who can list/get the container
  - What routers appear in list/get responses for each user
  - What HTTP status code the proxy returns for each user/mode combination

Uses two containers:
  inttest-ac-01   (alpine) — testdev1 is owner; used for list/get/edit tests
  inttest-nginx-01 (nginx) — admin is owner; used for HTTP proxy tests
"""

import sys
import os
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib'))

from dockside_test import TestCase, APIError

PROFILE_ALPINE = '10-alpine'
PROFILE_NGINX = '30-nginx'
AC_CONTAINER = 'inttest-ac-01'
NGINX_CONTAINER = 'inttest-nginx-01'


class AccessAndHttpTests(TestCase):
    """
    Comprehensive access-control and HTTP-proxy test.

    All test_ methods in this class share state via class variables to avoid
    repeated container setup/teardown. The _ensure_setup classmethod is called
    at the start of each test that needs a running container.
    """

    _ac_created = False
    _nginx_created = False
    _nginx_started = False

    def setUp(self):
        super().setUp()
        self.register_cleanup(AC_CONTAINER)
        self.register_cleanup(NGINX_CONTAINER)

    # ──────────────────────────────────────────────────────────────────────────
    # Section A — Initial visibility (no sharing)
    # ──────────────────────────────────────────────────────────────────────────

    def test_01_create_containers(self):
        """Create both test containers."""
        # testdev1 creates the AC test container
        try:
            self.dev1.create(profile=PROFILE_ALPINE, name=AC_CONTAINER)
        except APIError as e:
            if 'already' in str(e).lower() or 'exists' in str(e).lower():
                pass
            else:
                raise
        # Admin creates the nginx container
        try:
            self.admin.create(profile=PROFILE_NGINX, name=NGINX_CONTAINER)
        except APIError as e:
            if 'already' in str(e).lower() or 'exists' in str(e).lower():
                pass
            else:
                raise

    def test_02_owner_sees_own(self):
        names = self.container_names_in_list(self.dev1)
        self.assert_in(AC_CONTAINER, names, 'Owner (dev1) cannot see their own container')

    def test_03_dev2_cannot_see_unshared(self):
        names = self.container_names_in_list(self.dev2)
        self.assert_not_in(AC_CONTAINER, names, 'dev2 can see unshared container')

    def test_04_admin_sees_all(self):
        names = self.container_names_in_list(self.admin)
        self.assert_in(AC_CONTAINER, names, 'admin cannot see container (missing viewAllContainers?)')
        self.assert_in(NGINX_CONTAINER, names, 'admin cannot see nginx container')

    def test_05_viewer_cannot_see_unshared(self):
        names = self.container_names_in_list(self.viewer)
        self.assert_not_in(AC_CONTAINER, names, 'viewer can see unshared container')

    # ──────────────────────────────────────────────────────────────────────────
    # Section B — Viewer sharing
    # ──────────────────────────────────────────────────────────────────────────

    def test_06_add_viewer_grants_list_visibility(self):
        self.admin.update(AC_CONTAINER, viewers='testviewer')
        names = self.container_names_in_list(self.viewer)
        self.assert_in(AC_CONTAINER, names, 'viewer not visible after being added to viewers list')

    def test_07_viewer_can_get(self):
        # Ensure viewer is set
        self.admin.update(AC_CONTAINER, viewers='testviewer')
        data = self.viewer.get_container(AC_CONTAINER)
        self.assert_true(isinstance(data, dict), 'viewer get_container returned non-dict')

    def test_08_viewers_field_correct(self):
        self.admin.update(AC_CONTAINER, viewers='testviewer')
        data = self.dev1.get_container(AC_CONTAINER)
        viewers = (data.get('meta') or {}).get('viewers') or []
        if isinstance(viewers, str):
            viewers = [v.strip() for v in viewers.split(',') if v.strip()]
        self.assert_in('testviewer', viewers, 'testviewer not in meta.viewers')

    def test_09_viewer_cannot_edit(self):
        self.admin.update(AC_CONTAINER, viewers='testviewer')
        self.assert_api_error(
            self.viewer.update, AC_CONTAINER, description='viewer tried to edit'
        )

    # ──────────────────────────────────────────────────────────────────────────
    # Section C — Developer sharing (testdev2)
    # ──────────────────────────────────────────────────────────────────────────

    def test_10_add_dev2_grants_list_visibility(self):
        self.admin.update(AC_CONTAINER, developers='testdev1,testdev2')
        names = self.container_names_in_list(self.dev2)
        self.assert_in(AC_CONTAINER, names, 'dev2 cannot see container after being added as developer')

    def test_11_dev2_can_edit(self):
        self.admin.update(AC_CONTAINER, developers='testdev1,testdev2')
        self.dev2.update(AC_CONTAINER, description='edited by testdev2')
        data = self.dev1.get_container(AC_CONTAINER)
        desc = (data.get('meta') or {}).get('description') or data.get('description') or ''
        self.assert_equal(desc, 'edited by testdev2', 'description not updated by dev2')

    def test_12_developers_field_correct(self):
        self.admin.update(AC_CONTAINER, developers='testdev1,testdev2')
        data = self.dev1.get_container(AC_CONTAINER)
        devs = (data.get('meta') or {}).get('developers') or []
        if isinstance(devs, str):
            devs = [d.strip() for d in devs.split(',') if d.strip()]
        self.assert_in('testdev2', devs, 'testdev2 not in meta.developers')

    # ──────────────────────────────────────────────────────────────────────────
    # Section D — Router visibility filtering (list/get)
    # ──────────────────────────────────────────────────────────────────────────

    def test_13_developer_mode_viewer_listing_hides_www_router(self):
        """With access=developer (default), viewer should see no routers."""
        # Ensure viewer is added, dev2 removed, access = developer
        self.admin.update(AC_CONTAINER, viewers='testviewer', developers='testdev1')
        # Default access is developer; explicitly set it
        try:
            self.admin.update(AC_CONTAINER, access='{"www":"developer"}')
        except APIError:
            pass  # May not have a www router or access field
        routers = self.get_routers_for(self.viewer, AC_CONTAINER)
        # Viewer should see no routers when all are set to developer mode
        self.assert_true(
            'www' not in routers,
            f'viewer sees www router in developer mode: {routers}'
        )

    def test_14_developer_mode_viewer_get_hides_www_router(self):
        """get_container for viewer should also show no/empty routers when developer mode."""
        self.admin.update(AC_CONTAINER, viewers='testviewer', developers='testdev1')
        try:
            self.admin.update(AC_CONTAINER, access='{"www":"developer"}')
        except APIError:
            pass
        routers = self.get_routers_for(self.viewer, AC_CONTAINER)
        self.assert_true('www' not in routers,
                         f'viewer get shows www router in developer mode: {routers}')

    def test_15_viewer_mode_viewer_listing_shows_www_router(self):
        """With access=viewer, viewer should see www router."""
        self.admin.update(AC_CONTAINER, viewers='testviewer')
        try:
            self.admin.update(AC_CONTAINER, access='{"www":"viewer"}')
        except APIError as e:
            self.skip(f'Cannot set viewer access mode: {e}')
        routers = self.get_routers_for(self.viewer, AC_CONTAINER)
        self.assert_in('www', routers,
                       f'viewer does not see www router in viewer mode; routers={routers}')

    def test_16_viewer_mode_viewer_get_shows_www_router(self):
        """get_container for viewer shows www router in viewer mode."""
        self.admin.update(AC_CONTAINER, viewers='testviewer')
        try:
            self.admin.update(AC_CONTAINER, access='{"www":"viewer"}')
        except APIError as e:
            self.skip(f'Cannot set viewer access mode: {e}')
        routers = self.get_routers_for(self.viewer, AC_CONTAINER)
        self.assert_in('www', routers,
                       f'viewer get does not show www router in viewer mode')

    # ──────────────────────────────────────────────────────────────────────────
    # Section E — HTTP proxy access control (nginx container)
    # ──────────────────────────────────────────────────────────────────────────

    def _ensure_nginx_running(self):
        """Start nginx if not already running; wait for it."""
        try:
            data = self.admin.get_container(NGINX_CONTAINER)
        except APIError:
            self.admin.create(profile=PROFILE_NGINX, name=NGINX_CONTAINER)
            data = self.admin.get_container(NGINX_CONTAINER)
        if data.get('status') != 1:
            self.admin.start(NGINX_CONTAINER, wait=True, timeout=120)
            time.sleep(3)  # Let nginx fully initialise

    def _get_parent_fqdn(self):
        """Get parentFQDN from the nginx container (needed for remote mode)."""
        data = self.admin.get_container(NGINX_CONTAINER)
        return (data.get('data') or {}).get('parentFQDN') or data.get('parentFQDN')

    def _nginx_status(self, client, router='www'):
        """Return HTTP status code for the nginx container's www service."""
        parent_fqdn = None if self.admin._host_header else self._get_parent_fqdn()
        try:
            status, _ = client.check_service(NGINX_CONTAINER, router_prefix=router,
                                              parent_fqdn=parent_fqdn)
        except APIError:
            return None
        return status

    def test_20_start_nginx(self):
        """Start the nginx container and wait for it to be ready."""
        self._ensure_nginx_running()
        data = self.admin.get_container(NGINX_CONTAINER)
        self.assert_equal(data.get('status'), 1, 'nginx not running after start')

    def test_21_default_developer_owner_gets_200(self):
        """Owner gets 200 in developer mode (default)."""
        self._ensure_nginx_running()
        # Reset to developer mode
        try:
            self.admin.update(NGINX_CONTAINER, access='{"www":"developer"}')
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
            self.admin.update(NGINX_CONTAINER, access='{"www":"developer"}')
        except APIError:
            pass
        # Use viewer client with no cookies (simulate unauth by checking a service
        # that requires auth — 400 = not authenticated)
        from dockside_test import DocksideClient
        # We test by hitting service URL with no cookies at all
        parent_fqdn = None if self.admin._host_header else self._get_parent_fqdn()
        if self.admin._host_header:
            parts = self.admin._host_header.split('.', 1)
            suffix = parts[1] if len(parts) > 1 else self.admin._host_header
            service_host = f'www-{NGINX_CONTAINER}.{suffix}'
            import urllib.parse as _up
            parsed = _up.urlparse(self.admin._server)
            port = parsed.port
            connect_url = f'https://localhost:{port}/' if port and port != 443 else 'https://localhost/'
        else:
            connect_url = f'https://www-{NGINX_CONTAINER}{parent_fqdn}/'
            service_host = None

        from dockside_test import http_check
        code, _ = http_check(
            connect_url,
            host_header=service_host,
            cookies=None,
            verify_ssl=self.admin._verify_ssl,
        )
        self.assert_http_status(code, 400, f'unauth got {code} instead of 400 in developer mode')

    def test_23_public_mode_unauth_gets_200(self):
        """Unauthenticated user gets 200 in public mode."""
        self._ensure_nginx_running()
        try:
            self.admin.update(NGINX_CONTAINER, access='{"www":"public"}')
        except APIError as e:
            self.skip(f'Cannot set public mode: {e}')
        parent_fqdn = None if self.admin._host_header else self._get_parent_fqdn()
        if self.admin._host_header:
            parts = self.admin._host_header.split('.', 1)
            suffix = parts[1] if len(parts) > 1 else self.admin._host_header
            service_host = f'www-{NGINX_CONTAINER}.{suffix}'
            import urllib.parse as _up
            parsed = _up.urlparse(self.admin._server)
            port = parsed.port
            connect_url = f'https://localhost:{port}/' if port and port != 443 else 'https://localhost/'
        else:
            connect_url = f'https://www-{NGINX_CONTAINER}{parent_fqdn}/'
            service_host = None
        from dockside_test import http_check
        code, _ = http_check(connect_url, host_header=service_host,
                              verify_ssl=self.admin._verify_ssl)
        self.assert_http_status(code, 200, f'unauth got {code} instead of 200 in public mode')

    def test_24_public_mode_viewer_gets_200(self):
        """Viewer (not in viewers list) gets 200 in public mode."""
        self._ensure_nginx_running()
        self.admin.update(NGINX_CONTAINER, viewers='')
        try:
            self.admin.update(NGINX_CONTAINER, access='{"www":"public"}')
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
            self.admin.update(NGINX_CONTAINER, access='{"www":"user"}')
        except APIError as e:
            self.skip(f'Cannot set user mode: {e}')
        parent_fqdn = None if self.admin._host_header else self._get_parent_fqdn()
        if self.admin._host_header:
            parts = self.admin._host_header.split('.', 1)
            suffix = parts[1] if len(parts) > 1 else self.admin._host_header
            service_host = f'www-{NGINX_CONTAINER}.{suffix}'
            import urllib.parse as _up
            parsed = _up.urlparse(self.admin._server)
            port = parsed.port
            connect_url = f'https://localhost:{port}/' if port and port != 443 else 'https://localhost/'
        else:
            connect_url = f'https://www-{NGINX_CONTAINER}{parent_fqdn}/'
            service_host = None
        from dockside_test import http_check
        code, _ = http_check(connect_url, host_header=service_host,
                              verify_ssl=self.admin._verify_ssl)
        self.assert_http_status(code, 400, f'unauth got {code} in user mode')

    def test_26_user_mode_authenticated_gets_200(self):
        """Authenticated user (testviewer, not in viewers list) gets 200 in user mode."""
        self._ensure_nginx_running()
        self.admin.update(NGINX_CONTAINER, viewers='')
        try:
            self.admin.update(NGINX_CONTAINER, access='{"www":"user"}')
        except APIError as e:
            self.skip(f'Cannot set user mode: {e}')
        code = self._nginx_status(self.viewer)
        if code is None:
            self.skip('Could not reach nginx service')
        self.assert_http_status(code, 200, f'viewer got {code} in user mode')

    def test_27_viewer_mode_named_viewer_gets_200(self):
        """Named viewer gets 200 when access=viewer."""
        self._ensure_nginx_running()
        self.admin.update(NGINX_CONTAINER, viewers='testviewer')
        try:
            self.admin.update(NGINX_CONTAINER, access='{"www":"viewer"}')
        except APIError as e:
            self.skip(f'Cannot set viewer mode: {e}')
        code = self._nginx_status(self.viewer)
        if code is None:
            self.skip('Could not reach nginx service')
        self.assert_http_status(code, 200, f'named viewer got {code} in viewer mode')

    def test_28_viewer_mode_unnamed_dev2_gets_410(self):
        """dev2 (not in developers/viewers) gets 410 in viewer mode."""
        self._ensure_nginx_running()
        self.admin.update(NGINX_CONTAINER, viewers='testviewer', developers='')
        try:
            self.admin.update(NGINX_CONTAINER, access='{"www":"viewer"}')
        except APIError as e:
            self.skip(f'Cannot set viewer mode: {e}')
        code = self._nginx_status(self.dev2)
        if code is None:
            self.skip('Could not reach nginx service')
        self.assert_http_status(code, 410, f'unnamed dev2 got {code} in viewer mode')

    def test_29_developer_mode_named_dev2_gets_200(self):
        """dev2 in developers list gets 200 in developer mode."""
        self._ensure_nginx_running()
        self.admin.update(NGINX_CONTAINER, developers='testdev2')
        try:
            self.admin.update(NGINX_CONTAINER, access='{"www":"developer"}')
        except APIError:
            pass
        code = self._nginx_status(self.dev2)
        if code is None:
            self.skip('Could not reach nginx service')
        self.assert_http_status(code, 200, f'named dev2 got {code} in developer mode')

    def test_30_developer_mode_viewer_gets_410(self):
        """Viewer (even if named in viewers list) gets 410 in developer mode."""
        self._ensure_nginx_running()
        self.admin.update(NGINX_CONTAINER, viewers='testviewer', developers='testdev2')
        try:
            self.admin.update(NGINX_CONTAINER, access='{"www":"developer"}')
        except APIError:
            pass
        code = self._nginx_status(self.viewer)
        if code is None:
            self.skip('Could not reach nginx service')
        self.assert_http_status(code, 410, f'viewer got {code} in developer mode')

    def test_31_router_listing_reflects_access_mode(self):
        """Router visibility in list matches access mode: dev2 sees www in developer mode, viewer doesn't."""
        self._ensure_nginx_running()
        self.admin.update(NGINX_CONTAINER, developers='testdev2', viewers='testviewer')
        try:
            self.admin.update(NGINX_CONTAINER, access='{"www":"developer"}')
        except APIError:
            pass
        dev2_routers = self.get_routers_for(self.dev2, NGINX_CONTAINER)
        viewer_routers = self.get_routers_for(self.viewer, NGINX_CONTAINER)
        self.assert_in('www', dev2_routers,
                       f'dev2 does not see www router in developer mode: {dev2_routers}')
        self.assert_true('www' not in viewer_routers,
                         f'viewer sees www router in developer mode: {viewer_routers}')
