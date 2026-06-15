"""
Dockside Integration Test Framework
====================================
Drives the Dockside CLI via subprocess with --output json for reliable parsing.
HTTP service access checks use the CLI's check-url command for all authenticated
requests and urllib directly (with connect_to TCP override) for anonymous requests.

Python 3.6+ required. Zero external dependencies.
"""

import atexit
import http.client
import http.cookiejar
import json
import os
import re
import signal
import ssl
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request


# DOCKSIDE_TEST_DEBUG / DOCKSIDE_TEST_VERBOSE produce secret-bearing diagnostics: full
# CLI argv (including --gh-token and --password), raw request/response bodies, and the
# generated SSH config (which carries the session Cookie in its ProxyCommand). Warn once
# per run so the output is not pasted into shared logs or bug reports. Owner decision:
# warn rather than redact — the exposed secrets are the operator's own (cf. the CLI's
# --debug-http warning).
if (os.environ.get('DOCKSIDE_TEST_DEBUG', '').strip() == '1'
        or os.environ.get('DOCKSIDE_TEST_VERBOSE', '').strip() == '1'):
    print('# WARNING: DOCKSIDE_TEST_DEBUG/VERBOSE output is secret-bearing '
          '(CLI argv incl. tokens/passwords, request/response bodies, session cookies) — '
          'do not paste these logs into bug reports or shared channels.', file=sys.stderr)


# ── Exceptions ─────────────────────────────────────────────────────────────────

class APIError(Exception):
    """Raised when the CLI exits non-zero or returns an error response."""
    pass


class CapabilityUnavailable(APIError):
    """Raised when a host capability a test needs is genuinely unavailable (e.g. the
    docker/ssh/wstunnel binary or a key is missing) — the one case where skipping is
    legitimate. Subclasses APIError so existing `except APIError` handlers still catch
    it, but lets skip sites catch ONLY this and let real API/CLI regressions (plain
    APIError) propagate and fail instead of being downgraded to skips."""
    pass


class SkipTest(Exception):
    """Raised by a test to skip itself gracefully."""
    pass


class _UnavailableClient:
    """
    Placeholder for a client whose credentials are invalid or whose user
    does not exist on the server.  Any attribute access raises SkipTest so
    that tests requiring this role are automatically skipped rather than
    failing with a confusing auth error.
    """
    def __init__(self, role, reason):
        self._skip_msg = f'{role} unavailable: {reason}'

    def __getattr__(self, name):
        # _skip_msg lives in __dict__, so this won't recurse.
        raise SkipTest(self._skip_msg)


# ── TCP connect-to override (mirrors dockside_cli._ConnectToHandler) ──────────

class _ConnectToHTTPSConnection(http.client.HTTPSConnection):
    """HTTPSConnection that dials a forced host/port for the TCP leg while
    keeping the original hostname for TLS SNI."""
    _force_host = None
    _force_port = None

    def connect(self):
        self.sock = self._create_connection(
            (self._force_host or self.host, self._force_port or self.port),
            self.timeout,
            self.source_address,
        )
        if self._tunnel_host:
            self._tunnel()
            server_hostname = self._tunnel_host
        else:
            server_hostname = self.host
        self.sock = self._context.wrap_socket(self.sock, server_hostname=server_hostname)


class _ConnectToHandler(urllib.request.HTTPSHandler):
    """HTTPS handler that TCP-connects to a forced address while preserving
    the original hostname for TLS SNI and the HTTP Host header."""

    def __init__(self, connect_to, context):
        super().__init__(context=context)
        if ':' in connect_to:
            host, _, port = connect_to.rpartition(':')
            self._force_host = host
            self._force_port = int(port)
        else:
            self._force_host = connect_to
            self._force_port = None

    def https_open(self, req):
        force_host = self._force_host
        force_port = self._force_port
        ctx        = self._context

        def conn_factory(host, **kwargs):
            kwargs['context'] = ctx
            conn = _ConnectToHTTPSConnection(host, **kwargs)
            conn._force_host = force_host
            conn._force_port = force_port
            return conn

        return self.do_open(conn_factory, req)


# ── Helpers ────────────────────────────────────────────────────────────────────

def _fields_to_args(fields):
    """Convert a dict of fields to CLI --flag value pairs."""
    flag_names = {
        'gitURL': 'git-url',
    }
    args = []
    for k, v in fields.items():
        args.extend([f'--{flag_names.get(k, k)}', str(v)])
    return args


def verbose_enabled():
    return os.environ.get('DOCKSIDE_TEST_VERBOSE', '').strip() == '1'


def http_check(url, connect_to=None, host_header=None, cookies=None,
               verify_ssl=False, timeout=10):
    """
    HTTP GET to url; return (status_code, body_bytes).
    Does not follow redirects (returns 3xx as-is).

    connect_to: 'host[:port]' — override TCP target while keeping URL hostname
                for TLS SNI.  Use for local/harness mode anonymous checks.
    host_header: legacy override (kept for backward compatibility; prefer
                 constructing the canonical URL and using connect_to instead).
    cookies: dict of {name: value} or http.cookiejar.CookieJar instance.
    """
    ctx = ssl.create_default_context()
    if not verify_ssl:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

    jar = http.cookiejar.CookieJar()
    if isinstance(cookies, http.cookiejar.CookieJar):
        for c in cookies:
            jar.set_cookie(c)
    elif isinstance(cookies, dict):
        for name, value in cookies.items():
            _inject_simple_cookie(jar, url, name, value)

    handlers = [
        urllib.request.HTTPCookieProcessor(jar),
        _NoRedirectHandler(),
    ]
    if connect_to:
        handlers.append(_ConnectToHandler(connect_to, ctx))
    else:
        handlers.append(urllib.request.HTTPSHandler(context=ctx))
    if host_header:
        # Legacy: add a Host header override handler
        class _HostOverride(urllib.request.BaseHandler):
            def http_request(self, req):
                req.add_unredirected_header('Host', host_header)
                return req
            https_request = http_request
        handlers.append(_HostOverride())

    opener = urllib.request.build_opener(*handlers)
    req = urllib.request.Request(url)
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except urllib.error.URLError as e:
        target = f'{url} via {connect_to}' if connect_to else url
        raise APIError(f'HTTP check failed for {target}: {e.reason}')


def _inject_simple_cookie(jar, url, name, value):
    """Add a simple name=value cookie to a CookieJar for the given URL."""
    parsed = urllib.parse.urlparse(url)
    domain = parsed.hostname
    cookie = http.cookiejar.Cookie(
        version=0, name=name, value=value,
        port=None, port_specified=False,
        domain=domain, domain_specified=True, domain_initial_dot=False,
        path='/', path_specified=True,
        secure=False, expires=None, discard=True,
        comment=None, comment_url=None, rest={},
    )
    jar.set_cookie(cookie)


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Do not follow redirects — return 3xx as-is."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

    def http_error_301(self, req, fp, code, msg, headers):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)

    def http_error_302(self, req, fp, code, msg, headers):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)

    def http_error_303(self, req, fp, code, msg, headers):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)


# ── DocksideClient ─────────────────────────────────────────────────────────────

# Every DocksideClient that creates a temp cookie file registers itself here, so the
# signal path (TestRunner._emergency_cleanup) can remove ALL of their files — not just
# the runner's fixed set. with_credentials() siblings are held on test classes and are
# absent from the runner's _clients map, but they land here. (Normal exit is covered by
# each client's own atexit registration; this list is for the signal path, where atexit
# does not run.)
_ALL_CLIENTS = []


class DocksideClient:
    """
    Per-user Dockside client.

    Calls 'dockside --output json ...' as a subprocess for all API operations,
    including HTTP service checks via the 'check-url' subcommand.

    Parameters
    ----------
    use_cli_admin_creds : bool
        If True (interactive dev use), the CLI's pre-existing stored session is
        used — no --username/--password are passed and DOCKSIDE_CONFIG_DIR is not
        overridden.  Requires a prior 'dockside login'.  Cannot be used in harness
        mode (no prior login available).

        If False (default), --username/--password are passed to the CLI on every
        call and a per-client temporary cookie file is used (via --cookie-file) to
        keep sessions isolated.  The system config (~/.config/dockside/) is still
        consulted for the parent chain so ancestor cookies are merged automatically.
        Required for harness mode; used for all test-user clients (dev1/dev2/viewer).
    """

    def __init__(self, cli_path, server_url, username=None, password=None,
                 connect_to=None, verify_ssl=False,
                 use_cli_admin_creds=False, reuse_explicit_session=False,
                 use_server_transport=False):
        self._cli = cli_path
        self._server = server_url
        self._username = username
        self._password = password
        self._connect_to = connect_to
        self._verify_ssl = verify_ssl
        self._use_cli_admin_creds = use_cli_admin_creds
        self._use_server_transport = use_server_transport
        self._reuse_explicit_session = (
            reuse_explicit_session and not use_cli_admin_creds
        )
        self._persisted_session_ready = False
        if not use_cli_admin_creds:
            # Create a per-client temp file for the target session only.
            # Ancestor cookies still come from the system config's parent chain.
            base_tag = username if username else 'anon'
            user_tag = re.sub(r'[^A-Za-z0-9_.-]+', '-', base_tag).strip('-') or 'user'
            # Securely create a unique per-client cookie file (mkstemp; mode 0600)
            # rather than a predictable shared path, so concurrent harness runs do
            # not collide on it and a pre-existing symlink cannot redirect the write.
            fd, path = tempfile.mkstemp(prefix=f'dockside-sess-{user_tag}-', suffix='.txt')
            os.close(fd)
            self._session_cookie_file = path
            # The cookie file holds a live session and 0600 perms, so make sure it
            # is removed at process exit even if nothing calls cleanup() explicitly.
            # cleanup() is idempotent; the signal path additionally invokes it via
            # TestRunner._emergency_cleanup, because atexit handlers do not run once
            # a caught signal is re-raised to the default handler.
            atexit.register(self.cleanup)
            # Also record it for the signal path (see _ALL_CLIENTS above), which atexit
            # cannot cover and which the runner's fixed _clients map misses for siblings.
            _ALL_CLIENTS.append(self)
        else:
            self._session_cookie_file = None  # use system config stored session
        self._cookie_jar = None  # loaded lazily after first _run

    def with_credentials(self, username, password):
        """Return a sibling client for a different user, sharing this client's
        connection settings (server, transport, TLS) but with its own credentials
        and isolated session cookie file.

        Mutation tests that create a dedicated throwaway user use this to act AS that
        user (e.g. /me/update self-edit) instead of borrowing a shared fixture client.
        """
        return DocksideClient(
            cli_path=self._cli,
            server_url=self._server,
            username=username,
            password=password,
            connect_to=self._connect_to,
            verify_ssl=self._verify_ssl,
            use_cli_admin_creds=False,
            reuse_explicit_session=self._reuse_explicit_session,
            use_server_transport=self._use_server_transport,
        )

    def _should_send_credentials(self, force_credentials=False):
        if self._use_cli_admin_creds:
            return False
        if not self._username or not self._password:
            return False
        if force_credentials:
            return True
        if not self._reuse_explicit_session:
            return True
        return not self._persisted_session_ready

    def _base_args(self, force_credentials=False):
        args = [
            '--server', self._server,
            '--output', 'json',
        ]
        if not self._use_cli_admin_creds:
            if self._should_send_credentials(force_credentials=force_credentials):
                args.extend(['--username', self._username,
                             '--password', self._password])
            args.extend(['--cookie-file', self._session_cookie_file])
        if not self._verify_ssl:
            args.append('--no-verify')
        if self._connect_to and not self._use_server_transport:
            args.extend(['--connect-to', self._connect_to])
        return args

    def _run_once(self, *cmd_args, force_credentials=False):
        """Run CLI subcommand; return parsed JSON or raise APIError."""
        # Shared auth/transport flags are placed before the command so commands
        # like `ssh` can safely treat everything after their target as passthrough
        # argv for downstream tools such as OpenSSH.
        cmd = [self._cli] + self._base_args(force_credentials=force_credentials) + list(cmd_args)
        env = os.environ.copy()
        # Always use the system config so the parent chain is available for
        # ancestor cookie merging.  Session isolation is achieved via --cookie-file.
        env.pop('DOCKSIDE_CONFIG_DIR', None)
        verbose = os.environ.get('DOCKSIDE_TEST_VERBOSE', '').strip() == '1'
        debug   = os.environ.get('DOCKSIDE_TEST_DEBUG',   '').strip() == '1'
        if verbose or debug:
            # Secret-bearing: cmd may include --gh-token / --password (see the
            # module-level DEBUG/VERBOSE warning).
            print(f'# CMD: {" ".join(cmd)}', file=sys.stderr)
        result = subprocess.run(cmd, capture_output=True, text=True, env=env)
        if debug:
            print(f'# DEBUG rc={result.returncode} stdout={result.stdout!r} stderr={result.stderr!r}',
                  file=sys.stderr)
        if result.returncode != 0:
            msg = result.stderr.strip() or result.stdout.strip()
            raise APIError(msg or f'CLI exited {result.returncode}')
        # Reload cookie jar after each authenticated request
        self._reload_cookie_jar()
        if result.stdout.strip():
            try:
                return json.loads(result.stdout)
            except json.JSONDecodeError as e:
                raise APIError(f'JSON parse error ({e}): stdout={result.stdout!r}')
        return None

    def _run_readonly(self, *cmd_args):
        try:
            return self._run_once(*cmd_args)
        except APIError as e:
            if not self._reuse_explicit_session or self._should_send_credentials():
                raise
            verbose = os.environ.get('DOCKSIDE_TEST_VERBOSE', '').strip() == '1'
            debug   = os.environ.get('DOCKSIDE_TEST_DEBUG',   '').strip() == '1'
            if verbose or debug:
                print('# Read-only command failed with reused session; retrying with explicit credentials',
                      file=sys.stderr)
            self._persisted_session_ready = False
            return self._run_once(*cmd_args, force_credentials=True)

    def _run_mutating(self, *cmd_args):
        """Run a mutating CLI command exactly once.

        Mutating commands must never be automatically retried by the harness,
        because a server-side partial success would leave state uncertain.
        """
        return self._run_once(*cmd_args)

    def _run(self, *cmd_args):
        """Backward-compatible internal entrypoint for read-only commands."""
        return self._run_readonly(*cmd_args)

    def _run_text(self, *cmd_args):
        """Run a read-only CLI command that returns plain text output."""
        cmd = [self._cli, '--server', self._server, '--output', 'text']
        if not self._use_cli_admin_creds:
            if self._should_send_credentials():
                cmd.extend(['--username', self._username,
                            '--password', self._password])
            cmd.extend(['--cookie-file', self._session_cookie_file])
        if not self._verify_ssl:
            cmd.append('--no-verify')
        if self._connect_to and not self._use_server_transport:
            cmd.extend(['--connect-to', self._connect_to])
        cmd.extend(list(cmd_args))
        env = os.environ.copy()
        env.pop('DOCKSIDE_CONFIG_DIR', None)
        verbose = os.environ.get('DOCKSIDE_TEST_VERBOSE', '').strip() == '1'
        debug   = os.environ.get('DOCKSIDE_TEST_DEBUG',   '').strip() == '1'
        if verbose or debug:
            # Secret-bearing: cmd may include --gh-token / --password (see the
            # module-level DEBUG/VERBOSE warning).
            print(f'# CMD: {" ".join(cmd)}', file=sys.stderr)
        result = subprocess.run(cmd, capture_output=True, text=True, env=env)
        if debug:
            print(f'# DEBUG rc={result.returncode} stdout={result.stdout!r} stderr={result.stderr!r}',
                  file=sys.stderr)
        if result.returncode != 0:
            msg = result.stderr.strip() or result.stdout.strip()
            raise APIError(msg or f'CLI exited {result.returncode}')
        self._reload_cookie_jar()
        return result.stdout

    def _reload_cookie_jar(self):
        """Load/reload the session cookie file written by the CLI."""
        if self._session_cookie_file is None:
            self._cookie_jar = None
            self._persisted_session_ready = False
            return
        if not os.path.isfile(self._session_cookie_file):
            self._cookie_jar = None
            self._persisted_session_ready = False
            return
        jar = http.cookiejar.MozillaCookieJar(self._session_cookie_file)
        try:
            jar.load(ignore_discard=True, ignore_expires=True)
        except Exception:
            self._cookie_jar = None
            self._persisted_session_ready = False
            return
        self._cookie_jar = jar
        self._persisted_session_ready = any(True for _ in jar)

    def get_auth_cookie_header(self):
        """
        Return the cookie header string from /getAuthCookies for this client.

        This mirrors the UI SSH flow, so ancestor cookies and any configured
        global cookie are handled by the server-side helper rather than being
        reconstructed from the local cookie jar.
        """
        url = self._server.rstrip('/') + '/getAuthCookies'
        result = self._run_readonly('check-url', '--no-redirect', '--timeout', '30', url)
        if result is None:
            return None
        body = result.get('body', '')
        if not isinstance(body, str) or not body:
            return None
        try:
            payload = json.loads(body)
        except Exception:
            return None
        return payload.get('data')

    # ── API methods ───────────────────────────────────────────────────────────

    def list_containers(self):
        result = self._run_readonly('list')
        if not isinstance(result, list):
            raise APIError(f'list returned unexpected type {type(result).__name__!r}: {result!r}')
        return result

    def get_container(self, name):
        return self._run_readonly('get', name)

    def create(self, no_wait=False, **fields):
        # no_wait maps to the CLI's --no-wait switch (a store_true flag, so it is
        # not a value-bearing field and cannot go through _fields_to_args).  With
        # --no-wait the CLI returns the reservation record immediately and exits 0
        # even if the launch later fails; without it, a launch failure (status -4)
        # makes the CLI exit non-zero, which the harness surfaces as APIError.
        args = list(_fields_to_args(fields))
        if no_wait:
            args.append('--no-wait')
        return self._run_mutating('create', *args)

    def update(self, name, **fields):
        return self._run_mutating('edit', name, *_fields_to_args(fields))

    def start(self, name, wait=True, timeout=120):
        if wait:
            return self._run_mutating('start', '--timeout', str(timeout), name)
        return self._run_mutating('start', '--no-wait', name)

    def stop(self, name, wait=True, timeout=60):
        if wait:
            return self._run_mutating('stop', '--timeout', str(timeout), name)
        return self._run_mutating('stop', '--no-wait', name)

    def remove(self, name, wait=False, timeout=60):
        if wait:
            return self._run_mutating('remove', '--force', '--timeout', str(timeout), name)
        return self._run_mutating('remove', '--force', '--no-wait', name)

    def logs(self, name):
        return self._run_readonly('logs', name)

    # ── HTTP service checks ───────────────────────────────────────────────────

    def check_url(self, url, timeout=30):
        """
        Fetch url using the CLI check-url command with this user's session cookies.

        Session cookies are attached only for targets inside the deployment's domain
        tree over HTTPS (the server host or a subdomain sharing its parent domain —
        where devtainer router hostnames live); off-domain or HTTP targets get none
        unless --allow-cross-domain-cookies is passed. The domain check is a
        label-count heuristic, NOT public-suffix-aware (a server at dockside.co.uk
        would accept evil.co.uk), so it is not a security boundary on such domains.
        Redirects are not followed.
        Returns (status_code, body_bytes).
        """
        result = self._run_readonly('check-url', '--no-redirect', '--timeout', str(timeout), url)
        if result is None:
            raise APIError('check-url returned no output')
        status   = result.get('status')
        body_str = result.get('body', '')
        body     = body_str.encode('utf-8') if isinstance(body_str, str) else (body_str or b'')
        return status, body

    def ssh_proxy_spec(self, name):
        """Return the CLI-resolved SSH proxy spec for a devtainer."""
        result = self._run_readonly('ssh', 'proxy-command', name)
        if not isinstance(result, dict):
            raise APIError('ssh proxy-command returned no structured output')
        return result

    def ssh_config(self, name, identity_file=None, alias=None, forward_agent=False):
        """Return CLI-generated ssh_config text for a devtainer."""
        args = ['ssh']
        if identity_file:
            args.extend(['--identity-file', identity_file])
        if forward_agent:
            args.append('--forward-agent')
        if alias:
            args.extend(['--alias', alias])
        args.append('config')
        args.append(name)
        return self._run_text(*args)

    def service_url(self, container_name, router_prefix='www'):
        """
        Return the canonical service URL for a container router.

        Requires a client that has full access to the container (owner, admin,
        or named developer) — the server only returns parentFQDN to entitled
        clients.  Use this to obtain the URL first, then call check_url() with
        a different (possibly restricted) client to verify access control.
        """
        data        = self.get_container(container_name)
        parent_fqdn = (data.get('data') or {}).get('parentFQDN') or data.get('parentFQDN')
        if not parent_fqdn:
            raise APIError(
                f'parentFQDN not available for {container_name!r} '
                f'— use an entitled client (owner/admin/developer) to call service_url()'
            )
        return f'https://{router_prefix}-{container_name}{parent_fqdn}/'

    def check_service(self, container_name, router_prefix='www', timeout=30):
        """
        HTTP GET to the container's router URL using this user's session cookies.
        Returns (status_code, body_bytes).

        The calling client must have full container access so that service_url()
        can resolve parentFQDN.  To test a restricted client (viewer, removed
        developer), obtain the URL via an entitled client's service_url() first,
        then call check_url() directly.
        """
        url = self.service_url(container_name, router_prefix)
        return self.check_url(url, timeout=timeout)

    def cleanup(self):
        """Remove the temporary session cookie file."""
        if self._session_cookie_file:
            try:
                os.unlink(self._session_cookie_file)
            except OSError:
                pass
        self._cookie_jar = None
        self._persisted_session_ready = False


# ── TestCase base class ────────────────────────────────────────────────────────

class TestCase:
    """
    Base class for integration test cases.

    Subclass and implement test_* methods.
    Access clients via self.admin, self.dev1, self.dev2, self.viewer,
    self.user, self.view_all, self.develop_all, self.unauth.
    """

    # Injected by TestRunner before test execution
    admin = None
    dev1 = None
    dev2 = None
    viewer = None
    user = None
    view_all = None
    develop_all = None
    unauth = None

    # Test mode / env injected by TestRunner
    test_mode = 'remote'       # 'local', 'remote', 'harness'
    harness_container_id = None
    allow_network_modify = None  # None = use mode default; True/False = explicit override

    # Dynamic test resource names (injected by TestRunner; may include suffix)
    test_username_dev1    = 'inttest-dev1'
    test_username_dev2    = 'inttest-dev2'
    test_username_viewer  = 'inttest-viewer'
    test_username_user    = 'inttest-user'
    test_username_view_all = 'inttest-viewall'
    test_username_develop_all = 'inttest-developall'
    test_role_developer   = 'inttest-developer'
    test_role_viewer      = 'inttest-viewer-role'
    test_role_user        = 'inttest-user-role'
    test_role_view_all    = 'inttest-viewall-role'
    test_role_develop_all = 'inttest-developall-role'
    test_profile_alpine     = 'inttest-alpine'
    test_profile_nginx      = 'inttest-nginx'
    test_profile_bad_image  = 'inttest-bad-image'
    test_image_alpine       = 'alpine:latest'
    test_image_nginx        = 'nginx:latest'
    test_image_debian       = 'debian:latest'
    test_image_ubuntu       = 'ubuntu:latest'
    test_password_dev     = 'inttest-testpass'
    test_system_bin_dir   = '/opt/dockside/system/latest/bin'

    # Suffix for all test resource names (injected by TestRunner)
    _name_suffix = ''
    _test_method_name = ''

    @classmethod
    def _sfx(cls, name):
        """Return name with the run-specific suffix appended, if any."""
        s = getattr(cls, '_name_suffix', '') or ''
        return f'{name}-{s}' if s else name

    def setUp(self):
        self._cleanup_names = []

    def tearDown(self):
        if os.environ.get('DOCKSIDE_TEST_SKIP_CONTAINER_CLEANUP') == '1':
            return
        for name in self._cleanup_names:
            try:
                self.admin.stop(name, wait=False)
            except Exception:
                pass
            try:
                self.admin.remove(name, wait=False)
            except Exception:
                pass

    def register_cleanup(self, name):
        self._cleanup_names.append(name)

    def can_modify_networks(self):
        """
        Whether this test run may create/attach/detach Docker networks.

        Defaults:
          harness → True  (we own the Dockside container)
          local   → False (may be the developer's own instance)
          remote  → False (definitely someone's production instance)

        Always overridable via DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY=1/0
        or the allow_network_modify class attribute set by the runner.
        """
        env_val = os.environ.get('DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY', '').strip()
        if env_val == '1':
            return True
        if env_val == '0':
            return False
        if self.allow_network_modify is not None:
            return self.allow_network_modify
        return self.test_mode == 'harness'

    # ── Assertions ────────────────────────────────────────────────────────────

    def assert_true(self, expr, msg='assertion failed'):
        if not expr:
            raise AssertionError(msg)

    def assert_equal(self, a, b, msg=None):
        if a != b:
            raise AssertionError(msg or f'{a!r} != {b!r}')

    def assert_in(self, item, container, msg=None):
        if item not in container:
            raise AssertionError(msg or f'{item!r} not in {container!r}')

    def assert_not_in(self, item, container, msg=None):
        if item in container:
            raise AssertionError(msg or f'{item!r} unexpectedly in {container!r}')

    def assert_http_status(self, actual, expected, msg=None):
        if actual != expected:
            raise AssertionError(
                msg or f'HTTP status {actual} != {expected}'
            )

    def assert_api_error(self, fn, *args, **kwargs):
        """Assert that fn(*args, **kwargs) raises APIError."""
        try:
            fn(*args, **kwargs)
        except APIError:
            return
        raise AssertionError('Expected APIError but none was raised')

    def assert_container_field(self, container_data, path, expected):
        """
        Assert a nested field in container data.
        path: dot-separated string, e.g. 'meta.viewers'
        """
        parts = path.split('.')
        val = container_data
        for p in parts:
            if isinstance(val, dict):
                val = val.get(p)
            else:
                val = None
                break
        if val != expected:
            raise AssertionError(
                f'Container field {path!r}: {val!r} != {expected!r}'
            )

    def skip(self, reason):
        raise SkipTest(reason)

    def wait_until(self, predicate, timeout=20, interval=1, timeout_msg='condition not met'):
        """Poll predicate() until it returns a truthy value or timeout expires."""
        deadline = time.time() + timeout
        last_value = None
        while time.time() < deadline:
            last_value = predicate()
            if last_value:
                return last_value
            time.sleep(interval)
        raise AssertionError(f'{timeout_msg} within {timeout}s (last={last_value!r})')

    def create_and_wait(self, client, profile, name, timeout=20, **kwargs):
        """Create a container and assert it reaches running state (status == 1).

        Fails immediately with a clear message if the container reaches
        status -4 (launch-failed), and times out with a useful message
        if it never starts.  Passes **kwargs through to client.create()
        for extra fields such as ide=.
        """
        result = client.create(profile=profile, name=name, **kwargs)
        self.assert_true(result is not None, 'create returned nothing')
        created_name = result.get('name') if isinstance(result, dict) else None
        self.assert_equal(created_name, name, f'expected container name {name!r}')

        # dockside create --wait (the default) already blocks until running or
        # fast-fails on status -4, so one poll is usually enough.
        deadline = time.time() + timeout
        last_data = None
        while time.time() < deadline:
            try:
                last_data = client.get_container(name)
            except APIError:
                last_data = None
            status = last_data.get('status') if isinstance(last_data, dict) else None
            if status == 1:
                return result
            if status == -4:
                create_status = last_data.get('createStatus')
                raise AssertionError(
                    f'Container {name!r} launch failed (createStatus={create_status!r})'
                )
            time.sleep(1)

        status = last_data.get('status') if isinstance(last_data, dict) else None
        raise AssertionError(
            f'Container {name!r} did not reach running state within {timeout}s '
            f'(status={status!r})'
        )

    def wait_running(self, client, name, timeout=120):
        """Poll until container status == 1 or timeout."""
        def _running():
            try:
                data = client.get_container(name)
            except APIError:
                return False
            return (data.get('status') if isinstance(data, dict) else None) == 1

        self.wait_until(
            _running,
            timeout=timeout,
            interval=1,
            timeout_msg=f'Container {name!r} did not reach running state',
        )

    def container_names_in_list(self, client):
        """Return set of container names visible to client."""
        items = client.list_containers()
        return {item.get('name') for item in items if isinstance(item, dict)}

    def get_routers_for(self, client, container_name):
        """Return router keys visible to client for a container, or empty set."""
        try:
            data = client.get_container(container_name)
        except APIError:
            return set()
        routers = (data.get('profileObject') or {}).get('routers') or {}
        if isinstance(routers, dict):
            return set(routers.keys())
        if isinstance(routers, list):
            return {
                item.get('name')
                for item in routers
                if isinstance(item, dict) and item.get('name')
            }
        return set()


# ── TestRunner ─────────────────────────────────────────────────────────────────

class TestRunner:
    """
    Discovers and runs TestCase subclasses, emitting TAP-compatible output.
    """

    def __init__(self, cli_path, server_url, credentials, connect_to=None,
                 verify_ssl=False, test_mode='remote', harness_container_id=None,
                 allow_network_modify=None, name_attrs=None,
                 reuse_user_sessions=False, use_server_transport=False,
                 dockside_container_id=None):
        self._cli_path = cli_path
        self._server_url = server_url
        self._credentials = credentials  # dict: role -> (username, password) or (None, None)
        self._connect_to = connect_to
        self._verify_ssl = verify_ssl
        self._test_mode = test_mode
        self._harness_container_id = harness_container_id
        # Dockside container id for network-attach tests; harness mode uses
        # harness_container_id, non-harness modes use this (explicit or auto-detected).
        self._dockside_container_id = dockside_container_id
        self._allow_network_modify = allow_network_modify
        self._name_attrs = name_attrs or {}
        self._reuse_user_sessions = reuse_user_sessions
        self._use_server_transport = use_server_transport
        self._clients = {}
        self._active_cases = []
        self._active_class_teardowns = []
        self._total = 0
        self._passed = 0
        self._failed = 0
        self._skipped = 0
        # Optional callback invoked on SIGINT/SIGTERM (where main()'s finally is
        # skipped) to tear down dynamic fixtures; set by the runner's owner.
        self._on_emergency = None
        # Test-user clients that failed to authenticate during setup. Every test user
        # is harness-created, so an auth failure is a real defect, not a reason to
        # quietly skip coverage: the runner's owner fails the suite when this is
        # non-empty (see run_tests_main).
        self.auth_failures = []
        self._setup_clients()
        self._register_cleanup()

    def _make_client(self, username, password, use_cli_admin_creds=False):
        return DocksideClient(
            cli_path=self._cli_path,
            server_url=self._server_url,
            username=username,
            password=password,
            connect_to=self._connect_to,
            verify_ssl=self._verify_ssl,
            use_cli_admin_creds=use_cli_admin_creds,
            reuse_explicit_session=self._reuse_user_sessions,
            use_server_transport=self._use_server_transport,
        )

    def _validate_client(self, client, role):
        """Return client if auth succeeds, _UnavailableClient otherwise.

        Records the failure so the suite fails overall: every test user is created by
        the harness with a known password, so an auth failure means the environment is
        broken. Tests needing this role still skip individually (informative), but
        run_tests_main turns a non-empty auth_failures into a non-zero exit so the
        regression cannot hide as reduced coverage.
        """
        try:
            client.list_containers()
            return client
        except APIError as e:
            print(f'# WARNING: {role} credentials failed ({e}); '
                  f'tests requiring {role} will be skipped and the suite will fail',
                  file=sys.stderr)
            self.auth_failures.append((role, str(e)))
            return _UnavailableClient(role, str(e))

    def _setup_clients(self):
        creds = self._credentials
        admin_creds = creds['admin']
        # Admin: use_cli_admin_creds=True when no explicit credentials are provided,
        # meaning the developer has pre-authenticated via 'dockside login'.
        # use_cli_admin_creds=False when explicit credentials are supplied (harness mode).
        use_cli_admin_creds = (admin_creds[0] is None)
        self._clients = {
            'admin':  self._make_client(*admin_creds, use_cli_admin_creds=use_cli_admin_creds),
            # Test-user clients always supply explicit credentials (use_cli_admin_creds=False).
            'dev1':   self._validate_client(self._make_client(*creds['dev1'], use_cli_admin_creds=False), 'dev1'),
            'dev2':   self._validate_client(self._make_client(*creds['dev2'], use_cli_admin_creds=False), 'dev2'),
            'viewer': self._validate_client(self._make_client(*creds['viewer'], use_cli_admin_creds=False), 'viewer'),
            'user':   self._validate_client(self._make_client(*creds['user'], use_cli_admin_creds=False), 'user'),
            'view_all': self._validate_client(self._make_client(*creds['view_all'], use_cli_admin_creds=False), 'view_all'),
            'develop_all': self._validate_client(self._make_client(*creds['develop_all'], use_cli_admin_creds=False), 'develop_all'),
            'unauth': self._make_client(None, None, use_cli_admin_creds=False),
        }

    def _register_cleanup(self):
        def _cleanup(signum, _frame):
            self._emergency_cleanup()
            # main()'s finally (which removes the dynamic users/roles/profiles) is
            # skipped once we re-raise the signal below, so run the registered
            # environment cleanup here too; otherwise an interrupted run leaks them.
            if self._on_emergency:
                try:
                    self._on_emergency()
                except Exception:
                    pass
            # Restore default handler and re-raise so the process actually exits
            signal.signal(signum, signal.SIG_DFL)
            os.kill(os.getpid(), signum)
        signal.signal(signal.SIGINT, _cleanup)
        signal.signal(signal.SIGTERM, _cleanup)
        # SIGHUP too, so a dropped terminal also tears down client temp files (and
        # fixtures); otherwise SIGHUP would fall through to run_tests_main's earlier
        # handler, which cleans fixtures but not the per-client cookie files.
        signal.signal(signal.SIGHUP, _cleanup)
        atexit.register(self._emergency_cleanup)

    def _emergency_cleanup(self):
        for case in self._active_cases:
            try:
                case.tearDown()
            except Exception:
                pass
        for cls in list(self._active_class_teardowns):
            if hasattr(cls, 'tearDownClass'):
                try:
                    cls.tearDownClass()
                except Exception:
                    pass
        self._active_class_teardowns.clear()
        # Remove every client's credential-bearing temp cookie file. atexit does not
        # run on the signal path (we re-raise to SIG_DFL), so do it here; iterate the
        # module-level registry rather than self._clients so with_credentials() siblings
        # are covered too. cleanup() is idempotent, so the normal-exit atexit pass is harmless.
        for client in list(_ALL_CLIENTS):
            try:
                client.cleanup()
            except Exception:
                pass

    def _inject_clients(self, case):
        case.admin = self._clients['admin']
        case.dev1 = self._clients['dev1']
        case.dev2 = self._clients['dev2']
        case.viewer = self._clients['viewer']
        case.user = self._clients['user']
        case.view_all = self._clients['view_all']
        case.develop_all = self._clients['develop_all']
        case.unauth = self._clients['unauth']
        case.test_mode = self._test_mode
        case.harness_container_id = self._harness_container_id
        case.dockside_container_id = self._dockside_container_id
        case.allow_network_modify = self._allow_network_modify
        for attr, value in self._name_attrs.items():
            setattr(case, attr, value)

    def run_module(self, module):
        """Discover and run all TestCase subclasses in module."""
        import inspect
        classes = [
            obj for name, obj in inspect.getmembers(module, inspect.isclass)
            if issubclass(obj, TestCase) and obj is not TestCase
        ]
        classes.sort(key=lambda c: c.__name__)
        for cls in classes:
            self._run_class(cls)

    def _run_class(self, cls):
        methods = sorted(
            name for name in dir(cls)
            if name.startswith('test_') and callable(getattr(cls, name))
        )

        # Inject clients and name attrs as class attributes so
        # setUpClass/tearDownClass can use them
        cls.admin   = self._clients['admin']
        cls.dev1    = self._clients['dev1']
        cls.dev2    = self._clients['dev2']
        cls.viewer  = self._clients['viewer']
        cls.user    = self._clients['user']
        cls.view_all = self._clients['view_all']
        cls.develop_all = self._clients['develop_all']
        cls.unauth  = self._clients['unauth']
        cls.test_mode            = self._test_mode
        cls.harness_container_id = self._harness_container_id
        cls.dockside_container_id = self._dockside_container_id
        cls.allow_network_modify = self._allow_network_modify
        for attr, value in self._name_attrs.items():
            setattr(cls, attr, value)

        # Class-level setup
        if hasattr(cls, 'setUpClass') and callable(getattr(cls, 'setUpClass')):
            try:
                cls.setUpClass()
            except Exception as e:
                for method_name in methods:
                    self._total += 1
                    self._failed += 1
                    label = f'{cls.__name__}.{method_name}'
                    print(f'not ok {self._total} - {label}')
                    print(f'  # setUpClass failed: {e}')
                return

        # Track this class for emergency teardown if it has tearDownClass
        has_class_teardown = hasattr(cls, 'tearDownClass') and callable(getattr(cls, 'tearDownClass'))
        if has_class_teardown:
            self._active_class_teardowns.append(cls)

        for method_name in methods:
            self._total += 1
            case = cls()
            case._test_method_name = method_name
            self._inject_clients(case)
            self._active_cases.append(case)
            label = f'{cls.__name__}.{method_name}'
            t0 = time.monotonic()
            try:
                case.setUp()
                getattr(case, method_name)()
                case.tearDown()
                elapsed = time.monotonic() - t0
                self._passed += 1
                print(f'ok {self._total} - {label} # {elapsed:.3f}s')
            except SkipTest as e:
                elapsed = time.monotonic() - t0
                case.tearDown()
                self._skipped += 1
                print(f'ok {self._total} - {label} # SKIP {e} ({elapsed:.3f}s)')
            except (AssertionError, APIError) as e:
                elapsed = time.monotonic() - t0
                try:
                    case.tearDown()
                except Exception:
                    pass
                self._failed += 1
                print(f'not ok {self._total} - {label} # {elapsed:.3f}s')
                print(f'  # {e}')
            except Exception as e:
                elapsed = time.monotonic() - t0
                try:
                    case.tearDown()
                except Exception:
                    pass
                self._failed += 1
                print(f'not ok {self._total} - {label} # {elapsed:.3f}s')
                print(f'  # Unexpected error: {e}')
                for line in traceback.format_exc().splitlines():
                    print(f'  # {line}')
            finally:
                self._active_cases.remove(case)

        # Class-level teardown
        if has_class_teardown:
            try:
                cls.tearDownClass()
            except Exception:
                pass
            self._active_class_teardowns.remove(cls)

    def print_summary(self):
        print(f'# Tests: {self._total}, Passed: {self._passed}, '
              f'Failed: {self._failed}, Skipped: {self._skipped}')
        return self._failed == 0
