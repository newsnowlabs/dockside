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


# ── Exceptions ─────────────────────────────────────────────────────────────────

class APIError(Exception):
    """Raised when the CLI exits non-zero or returns an error response."""
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
    args = []
    for k, v in fields.items():
        args.extend([f'--{k}', str(v)])
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
                 use_cli_admin_creds=False, reuse_explicit_session=False):
        self._cli = cli_path
        self._server = server_url
        self._username = username
        self._password = password
        self._connect_to = connect_to
        self._verify_ssl = verify_ssl
        self._use_cli_admin_creds = use_cli_admin_creds
        self._reuse_explicit_session = (
            reuse_explicit_session and not use_cli_admin_creds
        )
        self._persisted_session_ready = False
        if not use_cli_admin_creds:
            # Create a per-client temp file for the target session only.
            # Ancestor cookies still come from the system config's parent chain.
            user_tag = re.sub(r'[^A-Za-z0-9_.-]+', '-', username or 'user').strip('-') or 'user'
            path = os.path.join(tempfile.gettempdir(), f'dockside-sess-{user_tag}.txt')
            with open(path, 'w', encoding='utf-8'):
                pass
            self._session_cookie_file = path
        else:
            self._session_cookie_file = None  # use system config stored session
        self._cookie_jar = None  # loaded lazily after first _run

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
        if self._connect_to:
            args.extend(['--connect-to', self._connect_to])
        return args

    def _run_once(self, *cmd_args, force_credentials=False):
        """Run CLI subcommand; return parsed JSON or raise APIError."""
        # All subcommand tokens must come before global flags so that nested
        # sub-subcommand parsers (e.g. 'role create', 'user create') see their
        # subcommand word before any --server / --output / ... flags.
        # Global flags are appended at the end; argparse accepts them anywhere.
        cmd = [self._cli] + list(cmd_args) + self._base_args(force_credentials=force_credentials)
        env = os.environ.copy()
        # Always use the system config so the parent chain is available for
        # ancestor cookie merging.  Session isolation is achieved via --cookie-file.
        env.pop('DOCKSIDE_CONFIG_DIR', None)
        verbose = os.environ.get('DOCKSIDE_TEST_VERBOSE', '').strip() == '1'
        debug   = os.environ.get('DOCKSIDE_TEST_DEBUG',   '').strip() == '1'
        if verbose or debug:
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

    def get_uid_cookie(self):
        """
        Return (cookie_name, cookie_value) for the session UID cookie,
        or None if not found.
        Used by SSH tests to build the wstunnel ProxyCommand.
        """
        if self._cookie_jar is None:
            self._reload_cookie_jar()
        if self._cookie_jar is None:
            return None
        for cookie in self._cookie_jar:
            # Dockside's UID cookie names start with _ds
            if cookie.name.startswith('_ds'):
                return cookie.name, cookie.value
        return None

    # ── API methods ───────────────────────────────────────────────────────────

    def list_containers(self):
        result = self._run_readonly('list')
        return result if isinstance(result, list) else []

    def get_container(self, name):
        return self._run_readonly('get', name)

    def create(self, **fields):
        return self._run_mutating('create', *_fields_to_args(fields))

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
        Cookies are injected for the target domain regardless of the server domain.
        Returns (status_code, body_bytes).
        """
        result = self._run_readonly('check-url', '--no-redirect', '--timeout', str(timeout), url)
        if result is None:
            raise APIError('check-url returned no output')
        status   = result.get('status')
        body_str = result.get('body', '')
        body     = body_str.encode('utf-8') if isinstance(body_str, str) else (body_str or b'')
        return status, body

    def check_service(self, container_name, router_prefix='www',
                      parent_fqdn=None, timeout=30):
        """
        HTTP GET to the container's router URL using this user's session cookies.
        Returns (status_code, body_bytes).

        URL construction:
          local/harness: derives domain suffix from server URL hostname
                         e.g. server https://www.dockside.test → suffix dockside.test
                         → service URL https://www-<name>.dockside.test/
          remote:        https://<prefix>-<name><parent_fqdn>/
                         parent_fqdn must be supplied (e.g. '.myinstance.example.com')
        """
        if self._connect_to:
            # local or harness mode: derive suffix from canonical server hostname
            parsed   = urllib.parse.urlparse(self._server)
            hostname = parsed.hostname or ''
            parts    = hostname.split('.', 1)
            suffix   = parts[1] if len(parts) > 1 else hostname
            url = f'https://{router_prefix}-{container_name}.{suffix}/'
        else:
            # remote mode
            if parent_fqdn is None:
                raise APIError('parent_fqdn required in remote mode for check_service')
            url = f'https://{router_prefix}-{container_name}{parent_fqdn}/'
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
    test_profile_alpine   = 'inttest-alpine'
    test_profile_nginx    = 'inttest-nginx'
    test_password_dev     = 'inttest-testpass'

    # Suffix for all test resource names (injected by TestRunner)
    _name_suffix = ''

    @classmethod
    def _sfx(cls, name):
        """Return name with the run-specific suffix appended, if any."""
        s = getattr(cls, '_name_suffix', '') or ''
        return f'{name}-{s}' if s else name

    def setUp(self):
        self._cleanup_names = []

    def tearDown(self):
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
                 reuse_user_sessions=False):
        self._cli_path = cli_path
        self._server_url = server_url
        self._credentials = credentials  # dict: role -> (username, password) or (None, None)
        self._connect_to = connect_to
        self._verify_ssl = verify_ssl
        self._test_mode = test_mode
        self._harness_container_id = harness_container_id
        self._allow_network_modify = allow_network_modify
        self._name_attrs = name_attrs or {}
        self._reuse_user_sessions = reuse_user_sessions
        self._clients = {}
        self._active_cases = []
        self._active_class_teardowns = []
        self._total = 0
        self._passed = 0
        self._failed = 0
        self._skipped = 0
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
        )

    def _validate_client(self, client, role):
        """Return client if auth succeeds, _UnavailableClient otherwise."""
        try:
            client.list_containers()
            return client
        except APIError as e:
            print(f'# WARNING: {role} credentials failed ({e}); '
                  f'tests requiring {role} will be skipped', file=sys.stderr)
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
            # Restore default handler and re-raise so the process actually exits
            signal.signal(signum, signal.SIG_DFL)
            os.kill(os.getpid(), signum)
        signal.signal(signal.SIGINT, _cleanup)
        signal.signal(signal.SIGTERM, _cleanup)
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
            self._inject_clients(case)
            self._active_cases.append(case)
            label = f'{cls.__name__}.{method_name}'
            try:
                case.setUp()
                getattr(case, method_name)()
                case.tearDown()
                self._passed += 1
                print(f'ok {self._total} - {label}')
            except SkipTest as e:
                case.tearDown()
                self._skipped += 1
                print(f'ok {self._total} - {label} # SKIP {e}')
            except (AssertionError, APIError) as e:
                try:
                    case.tearDown()
                except Exception:
                    pass
                self._failed += 1
                print(f'not ok {self._total} - {label}')
                print(f'  # {e}')
            except Exception as e:
                try:
                    case.tearDown()
                except Exception:
                    pass
                self._failed += 1
                print(f'not ok {self._total} - {label}')
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
