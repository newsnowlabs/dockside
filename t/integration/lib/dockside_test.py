"""
Dockside Integration Test Framework
====================================
Drives the Dockside CLI via subprocess with --output json for reliable parsing.
HTTP service access checks use urllib directly with session cookies from CLI login.

Python 3.6+ required. Zero external dependencies.
"""

import atexit
import http.cookiejar
import json
import os
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


# ── Helpers ────────────────────────────────────────────────────────────────────

def _fields_to_args(fields):
    """Convert a dict of fields to CLI --flag value pairs."""
    args = []
    for k, v in fields.items():
        args.extend([f'--{k}', str(v)])
    return args


def http_check(url, host_header=None, cookies=None, verify_ssl=False, timeout=10):
    """
    HTTP GET to url; return (status_code, body_bytes).
    Does not follow 4xx/5xx redirects (but does follow 3xx).
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

    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPSHandler(context=ctx),
        _NoRedirectHandler(),
    )
    req = urllib.request.Request(url)
    if host_header:
        req.add_unredirected_header('Host', host_header)
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except urllib.error.URLError as e:
        raise APIError(f'HTTP check failed: {e.reason}')


def _inject_simple_cookie(jar, url, name, value):
    """Add a simple name=value cookie to a CookieJar for the given URL."""
    import http.cookiejar as cj
    parsed = urllib.parse.urlparse(url)
    domain = parsed.hostname
    cookie = cj.Cookie(
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

    Calls 'dockside --output json ...' as a subprocess for all API operations.
    Maintains a cookie jar (loaded from the CLI's cookie file) for direct HTTP checks.
    """

    def __init__(self, cli_path, server_url, username, password,
                 host_header=None, verify_ssl=False, config_dir=None):
        self._cli = cli_path
        self._server = server_url
        self._username = username
        self._password = password
        self._host_header = host_header
        self._verify_ssl = verify_ssl
        self._config_dir = config_dir or tempfile.mkdtemp(prefix='dockside-test-')
        self._cookie_jar = None  # loaded lazily after first _run

    def _base_args(self):
        args = [
            '--server', self._server,
            '--output', 'json',
            '--username', self._username,
            '--password', self._password,
        ]
        if not self._verify_ssl:
            args.append('--no-verify')
        if self._host_header:
            args.extend(['--host-header', self._host_header])
        return args

    def _run(self, *cmd_args):
        """Run CLI subcommand; return parsed JSON or raise APIError."""
        # Subcommand must come before global flags so argparse routes to the
        # correct subparser (global flags like --server are only defined there,
        # not on the top-level parser).
        cmd = [self._cli] + list(cmd_args[:1]) + self._base_args() + list(cmd_args[1:])
        env = os.environ.copy()
        env['DOCKSIDE_CONFIG_DIR'] = self._config_dir
        debug = os.environ.get('DOCKSIDE_TEST_DEBUG', '').strip() == '1'
        if debug:
            print(f'# DEBUG cmd: {cmd}', file=sys.stderr)
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

    def _reload_cookie_jar(self):
        """Load/reload the cookie file written by the CLI."""
        cookie_file = os.path.join(self._config_dir, 'cookies.txt')
        if not os.path.isfile(cookie_file):
            return
        jar = http.cookiejar.MozillaCookieJar(cookie_file)
        try:
            jar.load(ignore_discard=True, ignore_expires=True)
        except Exception:
            return
        self._cookie_jar = jar

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
        result = self._run('list')
        return result if isinstance(result, list) else []

    def get_container(self, name):
        return self._run('get', name)

    def create(self, **fields):
        return self._run('create', *_fields_to_args(fields))

    def update(self, name, **fields):
        return self._run('edit', name, *_fields_to_args(fields))

    def start(self, name, wait=True, timeout=120):
        if wait:
            return self._run('start', '--timeout', str(timeout), name)
        return self._run('start', '--no-wait', name)

    def stop(self, name, wait=True, timeout=60):
        if wait:
            return self._run('stop', '--timeout', str(timeout), name)
        return self._run('stop', '--no-wait', name)

    def remove(self, name):
        return self._run('remove', '--force', '--no-wait', name)

    def logs(self, name):
        return self._run('logs', name)

    # ── HTTP service checks ───────────────────────────────────────────────────

    def check_service(self, container_name, router_prefix='www',
                      parent_fqdn=None, timeout=10):
        """
        HTTP GET to the container's router URL using this user's session cookies.
        Returns (status_code, body_bytes).

        URL construction:
          local/harness: https://localhost[:<port>] with Host: <prefix>-<name>.<suffix>
          remote:        https://<prefix>-<name>.<parent_fqdn>
        """
        if self._host_header:
            # local or harness mode: strip first label from host_header to get suffix
            parts = self._host_header.split('.', 1)
            suffix = parts[1] if len(parts) > 1 else self._host_header
            service_host = f'{router_prefix}-{container_name}.{suffix}'
            # Extract port from server URL if present
            parsed = urllib.parse.urlparse(self._server)
            port = parsed.port
            if port and port != 443:
                connect_url = f'https://localhost:{port}/'
            else:
                connect_url = 'https://localhost/'
            return http_check(
                connect_url,
                host_header=service_host,
                cookies=self._cookie_jar,
                verify_ssl=self._verify_ssl,
                timeout=timeout,
            )
        else:
            # remote mode
            if parent_fqdn is None:
                raise APIError('parent_fqdn required in remote mode for check_service')
            service_url = f'https://{router_prefix}-{container_name}{parent_fqdn}/'
            return http_check(
                service_url,
                cookies=self._cookie_jar,
                verify_ssl=self._verify_ssl,
                timeout=timeout,
            )

    def cleanup(self):
        """Remove the temporary config directory."""
        import shutil
        try:
            shutil.rmtree(self._config_dir, ignore_errors=True)
        except Exception:
            pass


# ── TestCase base class ────────────────────────────────────────────────────────

class TestCase:
    """
    Base class for integration test cases.

    Subclass and implement test_* methods.
    Access clients via self.admin, self.dev1, self.dev2, self.viewer, self.unauth.
    """

    # Injected by TestRunner before test execution
    admin = None
    dev1 = None
    dev2 = None
    viewer = None
    unauth = None

    # Test mode / env injected by TestRunner
    test_mode = 'remote'       # 'local', 'remote', 'harness'
    harness_container_id = None
    allow_network_modify = None  # None = use mode default; True/False = explicit override

    def setUp(self):
        self._cleanup_names = []

    def tearDown(self):
        for name in self._cleanup_names:
            try:
                self.admin.stop(name, wait=False)
            except Exception:
                pass
            try:
                self.admin.remove(name)
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

    def wait_running(self, client, name, timeout=120):
        """Poll until container status == 1 or timeout."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                data = client.get_container(name)
                status = data.get('status') if isinstance(data, dict) else None
                if status == 1:
                    return
            except APIError:
                pass
            time.sleep(3)
        raise AssertionError(f'Container {name!r} did not reach running state within {timeout}s')

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
        return set(routers.keys())


# ── TestRunner ─────────────────────────────────────────────────────────────────

class TestRunner:
    """
    Discovers and runs TestCase subclasses, emitting TAP-compatible output.
    """

    def __init__(self, cli_path, server_url, credentials, host_header=None,
                 verify_ssl=False, test_mode='remote', harness_container_id=None,
                 allow_network_modify=None):
        self._cli_path = cli_path
        self._server_url = server_url
        self._credentials = credentials  # dict: role -> (username, password)
        self._host_header = host_header
        self._verify_ssl = verify_ssl
        self._test_mode = test_mode
        self._harness_container_id = harness_container_id
        self._allow_network_modify = allow_network_modify
        self._clients = {}
        self._active_cases = []
        self._total = 0
        self._passed = 0
        self._failed = 0
        self._skipped = 0
        self._setup_clients()
        self._register_cleanup()

    def _make_client(self, username, password):
        if username is None:
            return None
        return DocksideClient(
            cli_path=self._cli_path,
            server_url=self._server_url,
            username=username,
            password=password,
            host_header=self._host_header,
            verify_ssl=self._verify_ssl,
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
        self._clients = {
            'admin':  self._make_client(*creds['admin']),
            'dev1':   self._validate_client(self._make_client(*creds['dev1']), 'dev1'),
            'dev2':   self._validate_client(self._make_client(*creds['dev2']), 'dev2'),
            'viewer': self._validate_client(self._make_client(*creds['viewer']), 'viewer'),
            'unauth': None,
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

    def _inject_clients(self, case):
        case.admin = self._clients['admin']
        case.dev1 = self._clients['dev1']
        case.dev2 = self._clients['dev2']
        case.viewer = self._clients['viewer']
        case.unauth = self._clients['unauth']
        case.test_mode = self._test_mode
        case.harness_container_id = self._harness_container_id
        case.allow_network_modify = self._allow_network_modify

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

    def print_summary(self):
        print(f'# Tests: {self._total}, Passed: {self._passed}, '
              f'Failed: {self._failed}, Skipped: {self._skipped}')
        return self._failed == 0
