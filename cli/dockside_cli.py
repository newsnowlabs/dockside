#!/usr/bin/env python3
"""Dockside CLI - manage devtainers from the command line.

Zero external dependencies - requires only Python 3.6+.
"""

import argparse
import datetime
import getpass
import http.cookiejar
import json
import os
import re
import ssl
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

__version__ = '0.2.0'

# ── Config directory validation ───────────────────────────────────────────────

def _validate_config_dir(path):
    """
    Validate and return the absolute config directory path.

    Raises ValueError for:
    - empty or non-absolute paths
    - paths containing null bytes or traversal components
    - paths that resolve to a symlink
    """
    if not path:
        raise ValueError("DOCKSIDE_CONFIG_DIR is empty")
    abs_path = os.path.normpath(os.path.abspath(path))
    if '\x00' in abs_path:
        raise ValueError("DOCKSIDE_CONFIG_DIR contains null bytes")
    if not os.path.isabs(abs_path):
        raise ValueError("DOCKSIDE_CONFIG_DIR is not absolute")
    # normpath removes '..' but be explicit about rejecting them in the raw input
    for part in path.replace('\\', '/').split('/'):
        if part == '..':
            raise ValueError(
                f"DOCKSIDE_CONFIG_DIR {path!r} contains path traversal components"
            )
    if os.path.islink(abs_path):
        raise ValueError(f"DOCKSIDE_CONFIG_DIR {abs_path!r} is a symlink")
    return abs_path


def _resolve_config_dir():
    raw = os.environ.get('DOCKSIDE_CONFIG_DIR')
    if raw:
        try:
            return _validate_config_dir(raw)
        except ValueError as e:
            print(f'error: {e}', file=sys.stderr)
            sys.exit(1)
    return os.path.join(os.path.expanduser('~'), '.config', 'dockside')


CONFIG_DIR   = _resolve_config_dir()
CONFIG_FILE  = os.path.join(CONFIG_DIR, 'config.json')
COOKIES_DIR  = os.path.join(CONFIG_DIR, 'cookies')

# ── Status labels ─────────────────────────────────────────────────────────────

STATUS_LABELS = {-2: 'prelaunch', -1: 'created', 0: 'exited', 1: 'running'}

# ── YAML serialiser (zero external dependencies) ──────────────────────────────

_YAML_BOOL_LITERALS = {'true', 'false', 'yes', 'no', 'on', 'off', 'null', '~'}
_YAML_SPECIAL_FIRST = set('-?:,[]{}#&*!|>\'"@`%')


def _yaml_scalar(s):
    if not isinstance(s, str):
        s = str(s)
    need_quote = (
        not s
        or s.lower() in _YAML_BOOL_LITERALS
        or s[0] in _YAML_SPECIAL_FIRST
        or s[0].isdigit()
        or any(c in s for c in ':#\n\r\t')
        or s != s.strip()
    )
    return json.dumps(s, ensure_ascii=False) if need_quote else s


def _yaml_node(obj, depth):
    pad = '  ' * depth
    if obj is None:
        return ['null']
    if isinstance(obj, bool):
        return ['true' if obj else 'false']
    if isinstance(obj, (int, float)):
        return [repr(obj)]
    if isinstance(obj, str):
        return [_yaml_scalar(obj)]
    if isinstance(obj, list):
        if not obj:
            return ['[]']
        lines = []
        dp1 = '  ' * (depth + 1)
        for item in obj:
            if isinstance(item, (dict, list)) and item:
                sub = _yaml_node(item, depth + 1)
                lines.append(f'{pad}- {sub[0][len(dp1):]}')
                lines.extend(sub[1:])
            else:
                lines.append(f'{pad}- {_yaml_node(item, depth)[0]}')
        return lines
    if isinstance(obj, dict):
        if not obj:
            return ['{}']
        lines = []
        for k, v in obj.items():
            key = _yaml_scalar(str(k))
            if isinstance(v, (dict, list)) and v:
                lines.append(f'{pad}{key}:')
                lines.extend(_yaml_node(v, depth + 1))
            else:
                lines.append(f'{pad}{key}: {_yaml_node(v, depth)[0]}')
        return lines
    return [_yaml_scalar(str(obj))]


def to_yaml(obj):
    return '\n'.join(_yaml_node(obj, 0)) + '\n'


# ── Output helpers ────────────────────────────────────────────────────────────

def emit(data, fmt):
    if fmt == 'json':
        print(json.dumps(data, indent=2))
    elif fmt == 'yaml':
        sys.stdout.write(to_yaml(data))
    else:
        print(json.dumps(data, indent=2))


def die(msg, code=1):
    print(f'error: {msg}', file=sys.stderr)
    sys.exit(code)


# ── Safe file I/O ─────────────────────────────────────────────────────────────

def _ensure_config_dir():
    """Create CONFIG_DIR and COOKIES_DIR safely; refuse to proceed if either is a symlink."""
    if os.path.islink(CONFIG_DIR):
        die(f"Config directory {CONFIG_DIR!r} is a symlink – refusing to use it")
    os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
    if os.path.islink(COOKIES_DIR):
        die(f"Cookies directory {COOKIES_DIR!r} is a symlink – refusing to use it")
    os.makedirs(COOKIES_DIR, mode=0o700, exist_ok=True)


def _safe_write(path, content_str, mode=0o600):
    """
    Atomically write content_str to path.
    Raises ValueError if path exists as a symlink.
    Uses a temp file + os.replace() for atomicity.
    """
    abs_path = os.path.abspath(path)
    if os.path.islink(abs_path):
        raise ValueError(f"Refusing to write to symlink: {abs_path!r}")
    dir_path = os.path.dirname(abs_path)
    os.makedirs(dir_path, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dir_path, prefix='.dockside-tmp-')
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(content_str)
        os.replace(tmp, abs_path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _safe_write_json(path, data, mode=0o600):
    _safe_write(path, json.dumps(data, indent=2) + '\n', mode)


def _save_cookie_jar(jar, cookie_file):
    """Save cookie jar atomically; refuse to write to a symlink."""
    abs_cf = os.path.abspath(cookie_file)
    if os.path.islink(abs_cf):
        die(f"Cookie file {abs_cf!r} is a symlink – refusing to write")
    dir_path = os.path.dirname(abs_cf)
    os.makedirs(dir_path, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dir_path, prefix='.dockside-cookies-tmp-')
    os.close(fd)
    os.chmod(tmp, 0o600)
    orig = jar.filename
    jar.filename = tmp
    try:
        jar.save(ignore_discard=True, ignore_expires=True)
        os.replace(tmp, abs_cf)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    finally:
        jar.filename = orig


# ── Config – multi-server ─────────────────────────────────────────────────────

def _safe_nick(s):
    """Return a filesystem-safe slug from an arbitrary string (max 64 chars)."""
    slug = re.sub(r'[^a-zA-Z0-9_-]', '-', s)[:64].strip('-')
    return slug or 'server'


def _validate_cookie_filename(name):
    """
    Validate and normalise a user-supplied cookie filename.

    Accepts a bare name (e.g. 'prod') or a name with .txt suffix.
    Rejects anything with path separators, null bytes, '..' components,
    or names that are longer than 128 characters before adding .txt.
    Returns the normalised '<name>.txt' string.
    """
    if not name:
        raise ValueError("Cookie filename must not be empty")
    if '\x00' in name:
        raise ValueError("Cookie filename must not contain null bytes")
    # Strip a single trailing '.txt' so we can normalise uniformly
    base = name[:-4] if name.lower().endswith('.txt') else name
    if not base:
        raise ValueError("Cookie filename must not be empty")
    if len(base) > 128:
        raise ValueError("Cookie filename is too long (max 128 characters before .txt)")
    # Reject any path traversal or directory components
    if os.sep in base or (os.altsep and os.altsep in base) or '/' in base or '\\' in base:
        raise ValueError("Cookie filename must not contain path separators")
    if base == '..' or base.startswith('../') or base.startswith('..\\'):
        raise ValueError("Cookie filename must not contain path traversal")
    # Only allow safe characters (letters, digits, hyphens, underscores, dots)
    if not re.match(r'^[a-zA-Z0-9._-]+$', base):
        raise ValueError("Cookie filename may only contain letters, digits, hyphens, underscores, and dots")
    return base + '.txt'


def _cookie_file_for(server_entry):
    """Derive the cookie file path for a server entry."""
    # Honour an explicit override stored in the server config entry
    override = (server_entry.get('cookie_file') or '').strip()
    if override:
        try:
            filename = _validate_cookie_filename(override)
        except ValueError:
            filename = None
        if filename:
            return os.path.join(COOKIES_DIR, filename)
    # Fall back to deriving a slug from nickname or URL netloc
    nick = (server_entry.get('nickname') or '').strip()
    if nick:
        slug = _safe_nick(nick)
    else:
        parsed = urllib.parse.urlparse(server_entry.get('url', ''))
        slug = _safe_nick(parsed.netloc or 'server')
    return os.path.join(COOKIES_DIR, f'{slug}.txt')


def _migrate_old_config(cfg):
    """Migrate single-server config format to multi-server format in place."""
    if 'server' in cfg and 'servers' not in cfg:
        old_url = cfg.pop('server', None)
        if old_url:
            entry = {'url': old_url}
            cfg['servers'] = [entry]
            cfg['current'] = old_url
    return cfg


def load_config():
    """Load config.json, migrating old single-server format if needed."""
    try:
        with open(CONFIG_FILE, encoding='utf-8') as f:
            cfg = json.load(f)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError:
        return {}
    return _migrate_old_config(cfg)


def save_config(cfg):
    _ensure_config_dir()
    _safe_write_json(CONFIG_FILE, cfg, mode=0o600)


def _find_server(cfg, ref):
    """Find a server entry by URL (exact) or nickname (case-insensitive)."""
    servers = cfg.get('servers') or []
    for s in servers:
        if s.get('url') == ref:
            return s
    ref_lower = ref.lower()
    for s in servers:
        if (s.get('nickname') or '').lower() == ref_lower:
            return s
    return None


def _current_server(cfg):
    """Return the current server entry, or None."""
    ref = cfg.get('current')
    return _find_server(cfg, ref) if ref else None


def _upsert_server(cfg, url, nickname=None, **extra):
    """Add or update a server entry in cfg['servers']."""
    servers = cfg.setdefault('servers', [])
    for s in servers:
        if s.get('url') == url:
            if nickname is not None:
                s['nickname'] = nickname
            s.update({k: v for k, v in extra.items() if v is not None})
            return
    entry = {'url': url}
    if nickname:
        entry['nickname'] = nickname
    entry.update({k: v for k, v in extra.items() if v is not None})
    servers.append(entry)


# ── HTTP client ───────────────────────────────────────────────────────────────

class APIError(Exception):
    def __init__(self, msg, http_status=None):
        super().__init__(msg)
        self.http_status = http_status


class _HostOverrideHandler(urllib.request.BaseHandler):
    """Inject a fixed Host header into every outgoing request (for localhost testing)."""
    def __init__(self, host):
        self._host = host

    def https_request(self, req):
        req.add_unredirected_header('Host', self._host)
        return req

    http_request = https_request


def _build_opener(cookie_file, verify_ssl, host_header=None):
    """Create a urllib opener with cookie jar and SSL settings."""
    jar = http.cookiejar.MozillaCookieJar(cookie_file)
    # Only load cookies from a real file (not a symlink)
    if os.path.isfile(cookie_file) and not os.path.islink(cookie_file):
        try:
            jar.load(ignore_discard=True, ignore_expires=True)
        except Exception:
            pass
    ctx = ssl.create_default_context()
    if not verify_ssl:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    handlers = [
        urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPSHandler(context=ctx),
        urllib.request.HTTPRedirectHandler(),
    ]
    if host_header:
        handlers.append(_HostOverrideHandler(host_header))
    opener = urllib.request.build_opener(*handlers)
    opener._jar = jar
    return opener


def _do_get(opener, url, timeout=30):
    """GET url → parsed JSON, raising APIError on failure."""
    req = urllib.request.Request(url, headers={'Accept': 'application/json'})
    try:
        with opener.open(req, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            data = json.loads(body)
            raise APIError(data.get('msg') or str(e), e.code)
        except (json.JSONDecodeError, ValueError):
            raise APIError(f'HTTP {e.code}: {e.reason}', e.code)
    except urllib.error.URLError as e:
        raise APIError(f'Connection error: {e.reason}')
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        raise APIError('Server returned non-JSON response')
    if str(data.get('status', '200')) not in ('200', '201'):
        raise APIError(data.get('msg') or 'Unknown API error', data.get('status'))
    return data


def _do_get_text(opener, url, timeout=60):
    """GET url → raw text string, raising APIError on failure."""
    req = urllib.request.Request(url)
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.read().decode('utf-8', errors='replace')
    except urllib.error.HTTPError as e:
        raise APIError(f'HTTP {e.code}: {e.reason}', e.code)
    except urllib.error.URLError as e:
        raise APIError(f'Connection error: {e.reason}')


# ── Cookie injection ──────────────────────────────────────────────────────────

def _inject_cookie(jar, server_url, name, value):
    """Inject a named cookie into the jar scoped to the server's hostname."""
    hostname = urllib.parse.urlparse(server_url).hostname or ''
    cookie = http.cookiejar.Cookie(
        version=0, name=name, value=value,
        port=None, port_specified=False,
        domain=hostname, domain_specified=True, domain_initial_dot=False,
        path='/', path_specified=True,
        secure=True, expires=None, discard=True,
        comment=None, comment_url=None, rest={},
    )
    jar.set_cookie(cookie)


# ── Authentication ────────────────────────────────────────────────────────────

def login(server, username, password, verify_ssl=True,
          extra_cookies=None, cookie_file=None, host_header=None):
    """
    POST credentials to Dockside, return the authenticated opener.
    extra_cookies: dict of {name: value} injected before the POST.
    Raises APIError on failure.
    """
    if cookie_file is None:
        cookie_file = os.path.join(CONFIG_DIR, 'cookies.txt')
    opener = _build_opener(cookie_file, verify_ssl, host_header=host_header)
    if extra_cookies:
        for cname, cval in extra_cookies.items():
            _inject_cookie(opener._jar, server, cname, cval)
    url = server.rstrip('/') + '/'
    payload = urllib.parse.urlencode(
        {'username': username, 'password': password}
    ).encode()
    req = urllib.request.Request(url, data=payload, method='POST')
    try:
        with opener.open(req, timeout=15):
            pass
    except urllib.error.URLError as e:
        raise APIError(f'Login failed – connection error: {e.reason}')
    jar = opener._jar
    if not list(jar):
        raise APIError(
            'Login failed – no session cookie received. '
            'Check credentials and ensure the server URL is correct.'
        )
    return opener


def get_authenticated_opener(server, server_entry, username, password,
                              verify_ssl=True, transient=False,
                              extra_cookies=None, host_header=None):
    """
    Return an authenticated opener.

    Performs a fresh login when username+password are given and optionally
    persists the session.  Otherwise loads stored cookies for this server.
    """
    cookie_file = _cookie_file_for(server_entry)
    if username and password:
        opener = login(server, username, password, verify_ssl=verify_ssl,
                       extra_cookies=extra_cookies, cookie_file=cookie_file,
                       host_header=host_header)
        if not transient:
            _ensure_config_dir()
            _save_cookie_jar(opener._jar, cookie_file)
        return opener
    # Load stored cookies
    if not os.path.isfile(cookie_file):
        ref = server_entry.get('nickname') or server
        die(
            f"Not logged in to {ref!r}. Run 'dockside login' first, "
            "or supply --username / --password (or DOCKSIDE_USER / DOCKSIDE_PASSWORD)."
        )
    return _build_opener(cookie_file, verify_ssl, host_header=host_header)


# ── Container resolution ──────────────────────────────────────────────────────

def fetch_containers(opener, server):
    data = _do_get(opener, server.rstrip('/') + '/containers')
    return data.get('data') or []


def resolve(containers, identifier):
    """
    Find a container by name, reservation ID, or Docker container ID prefix.
    Exits with an error if no unique match is found.
    """
    for c in containers:
        if c.get('name') == identifier:
            return c
    for c in containers:
        if c.get('id') == identifier:
            return c
    matches = [c for c in containers
               if (c.get('containerId') or '').startswith(identifier)]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        names = ', '.join(m.get('name') or m.get('id') for m in matches)
        die(f'Ambiguous container ID prefix {identifier!r} – matches: {names}')
    die(f'Devtainer not found: {identifier!r}')


# ── API calls ─────────────────────────────────────────────────────────────────

def _encode_params(**kwargs):
    """
    Build a URL query string suitable for the Dockside API.

    Booleans → 0/1; dicts/lists → compact JSON strings; rest → str.
    Uses quote() (not quote_plus()) so spaces become %20, not +.
    Perl's uri_unescape() only decodes %XX sequences, not + signs.
    """
    params = {}
    for k, v in kwargs.items():
        if v is None:
            continue
        if isinstance(v, bool):
            params[k] = '1' if v else '0'
        elif isinstance(v, (dict, list)):
            params[k] = json.dumps(v, separators=(',', ':'))
        else:
            params[k] = str(v)
    return urllib.parse.urlencode(params, quote_via=urllib.parse.quote)


def api_create(opener, server, fields):
    qs = _encode_params(**fields)
    data = _do_get(opener, server.rstrip('/') + '/containers/create?' + qs, timeout=30)
    return data.get('reservation')


def api_update(opener, server, res_id, fields):
    qs = _encode_params(**fields)
    url = (server.rstrip('/') +
           f'/containers/{urllib.parse.quote(res_id)}/update?' + qs)
    data = _do_get(opener, url, timeout=30)
    return data.get('reservation')


def api_control(opener, server, res_id, cmd):
    """Send start/stop/remove to a devtainer. Returns the updated container list."""
    url = (server.rstrip('/') +
           f'/containers/{urllib.parse.quote(res_id)}/{urllib.parse.quote(cmd)}')
    data = _do_get(opener, url, timeout=30)
    return data.get('data') or []


def api_logs(opener, server, res_id):
    url = (server.rstrip('/') +
           f'/containers/{urllib.parse.quote(res_id)}/logs'
           '?stdout=true&stderr=true&format=text&clean_pty=true&merge=true')
    return _do_get_text(opener, url, timeout=60)


# ── Wait for state ────────────────────────────────────────────────────────────

def wait_for(opener, server, res_id, target, timeout=120, interval=2, quiet=False):
    """
    Poll until the container reaches `target`.

    target: 1      → running
            0      → exited/stopped (status <= 0)
            'gone' → container removed (reservation gone or status -2 + no containerId)
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        containers = fetch_containers(opener, server)
        if target == 'gone':
            c = next((c for c in containers if c.get('id') == res_id), None)
            if c is None:
                # Reservation fully deleted.
                if not quiet:
                    print()
                return True
            if c.get('status', 0) <= -2 and not c.get('containerId'):
                # Docker container removed; reservation preserved in prelaunch state.
                if not quiet:
                    print()
                return True
        else:
            for c in containers:
                if c.get('id') == res_id:
                    status = c.get('status', -99)
                    if target == 1 and status == 1:
                        if not quiet:
                            print()
                        return True
                    if target == 0 and status <= 0:
                        if not quiet:
                            print()
                        return True
                    break
        if not quiet:
            print('.', end='', flush=True)
        time.sleep(interval)
    if not quiet:
        print()
    return False


# ── Log sanitisation ──────────────────────────────────────────────────────────

# ANSI CSI sequences: ESC [ <params> <final-byte>
_RE_CSI  = re.compile(r'\x1b\[[0-9;:<=>?]*[@-~]')
# OSC sequences: ESC ] ... (terminated by BEL or ESC \)
_RE_OSC  = re.compile(r'\x1b\][^\x1b\x07]*(?:\x07|\x1b\\)')
# Two-character ESC sequences (other than CSI/OSC/DCS/PM/APC/SOS)
_RE_ESC  = re.compile(r'\x1b[^[\]PX^_]')
# Dangerous control characters (keep \t=0x09, \n=0x0a, \r=0x0d)
_RE_CTRL = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1a\x1c-\x1f\x7f]')


def sanitize_terminal(text):
    """
    Strip ANSI escape sequences and dangerous terminal control characters.

    Preserves printable text, tab, newline, and carriage return.
    Protects against terminal injection from untrusted log content.
    """
    text = _RE_CSI.sub('', text)
    text = _RE_OSC.sub('', text)
    text = _RE_ESC.sub('', text)
    text = _RE_CTRL.sub('', text)
    return text


# ── Router URL construction ───────────────────────────────────────────────────

def _make_router_url(router, container_name, parent_fqdn, data):
    """
    Construct the access URL / connection string for a single router.

    Uses the same pattern as the web frontend's makeUri():
        {prefix}-{container_name}{parent_fqdn}
    where parent_fqdn starts with '.' (e.g. '.dockside.example.com').
    """
    prefixes = router.get('prefixes') or []
    prefix   = prefixes[0] if prefixes else 'www'
    fqdn     = f'{prefix}-{container_name}{parent_fqdn}'
    rtype    = router.get('type', '')

    if rtype == 'ssh':
        unixuser = data.get('unixuser', '')
        return f'ssh {unixuser}@{fqdn}' if unixuser else f'ssh @{fqdn}'

    # router.https is an object (truthy) when HTTPS is configured
    protocol = 'https' if router.get('https') else 'http'

    if rtype == 'ide':
        running_ide = data.get('runningIDE', '')
        home_dir    = data.get('homeDir') or f'/home/{data.get("unixuser", "")}'
        path = (f'/?folder={home_dir}'
                if running_ide.startswith('openvscode')
                else f'/#{home_dir}')
        return f'{protocol}://{fqdn}{path}'

    return f'{protocol}://{fqdn}/'


def _router_urls(container):
    """
    Return a dict of {router_name: url_string} for all non-passthru routers
    defined in the container's profileObject.
    """
    profile_obj = container.get('profileObject') or {}
    routers     = profile_obj.get('routers') or []
    name        = container.get('name', '')
    data        = container.get('data') or {}
    parent_fqdn = data.get('parentFQDN', '')
    result = {}
    for router in routers:
        rname = router.get('name', '')
        if rname and router.get('type') != 'passthru':
            result[rname] = _make_router_url(router, name, parent_fqdn, data)
    return result


# ── Text rendering ────────────────────────────────────────────────────────────

def _status_str(status):
    return STATUS_LABELS.get(status, str(status))


def _fmt_table(containers, show_urls=False):
    """Render containers as a fixed-width text table."""
    if not containers:
        return '(no devtainers)'

    # Collect the superset of router names across all containers (order-stable)
    router_names = []
    if show_urls:
        seen = set()
        for c in containers:
            for rn in _router_urls(c):
                if rn not in seen:
                    router_names.append(rn)
                    seen.add(rn)

    headers = ['NAME', 'STATUS', 'PROFILE', 'OWNER']
    if show_urls:
        headers += [rn.upper() for rn in router_names]
    else:
        headers.append('URL')

    rows = []
    for c in containers:
        meta  = c.get('meta') or {}
        data  = c.get('data') or {}
        owner = meta.get('owner') or (c.get('owner') or {}).get('username', '')
        row   = [
            c.get('name', ''),
            _status_str(c.get('status')),
            c.get('profile', ''),
            owner,
        ]
        if show_urls:
            urls = _router_urls(c)
            row += [urls.get(rn, '') for rn in router_names]
        else:
            row.append(data.get('FQDN', ''))
        rows.append(row)

    widths = [
        max(len(h), max((len(r[i]) for r in rows), default=0))
        for i, h in enumerate(headers)
    ]

    def fmt_row(r):
        return '  '.join(cell.ljust(widths[i]) for i, cell in enumerate(r))

    sep = '  '.join('-' * w for w in widths)
    return '\n'.join([fmt_row(headers), sep] + [fmt_row(r) for r in rows])


def _fmt_detail(c):
    """Render a single container as a key-value block."""
    meta   = c.get('meta') or {}
    data   = c.get('data') or {}
    docker = c.get('docker') or {}
    owner  = c.get('owner') or {}

    created = ''
    if docker.get('CreatedAt'):
        try:
            created = datetime.datetime.fromtimestamp(
                docker['CreatedAt'], tz=datetime.timezone.utc
            ).strftime('%Y-%m-%d %H:%M:%S UTC')
        except Exception:
            created = str(docker['CreatedAt'])

    access_str  = json.dumps(meta.get('access') or {}, separators=(', ', ': '))
    options     = data.get('options') or {}
    options_str = json.dumps(options, separators=(', ', ': ')) if options else ''

    lines = [
        ('Name',          c.get('name', '')),
        ('Status',        _status_str(c.get('status'))),
        ('Reservation',   c.get('id', '')),
        ('Container ID',  c.get('containerId') or docker.get('ID', '')),
        ('Profile',       c.get('profile', '')),
        ('Image',         data.get('image', '')),
        ('Runtime',       data.get('runtime', '')),
        ('Network',       data.get('network', '')),
        ('Unix user',     data.get('unixuser', '')),
        ('IDE',           meta.get('IDE', '')),
        ('Git URL',       data.get('gitURL', '')),
        ('Description',   meta.get('description', '')),
        ('Owner',         meta.get('owner') or owner.get('username', '')),
        ('Developers',    meta.get('developers', '')),
        ('Viewers',       meta.get('viewers', '')),
        ('Private',       'yes' if meta.get('private') else 'no'),
        ('Access',        access_str),
        ('Options',       options_str),
        ('Docker status', docker.get('Status', '')),
        ('Created',       created),
    ]

    # Append a labelled URL line for each non-passthru router
    for rname, url in _router_urls(c).items():
        lines.append((f'URL ({rname})', url))

    label_width = max(len(lbl) for lbl, _ in lines)
    return '\n'.join(
        f'{lbl.ljust(label_width)}  {val}'
        for lbl, val in lines
        if val
    )


# ── Argument helpers ──────────────────────────────────────────────────────────

def _add_global_flags(p):
    """Add auth / output flags shared by every authenticated subcommand."""
    p.add_argument(
        '--server', '-s', metavar='URL_OR_NICKNAME',
        help='Dockside server URL or configured nickname  [env: DOCKSIDE_SERVER]',
    )
    p.add_argument(
        '--username', '-u', metavar='USER',
        help='Username for one-shot auth  [env: DOCKSIDE_USER]',
    )
    p.add_argument(
        '--password', '-p', metavar='PASS',
        help='Password for one-shot auth  [env: DOCKSIDE_PASSWORD]',
    )
    p.add_argument(
        '--output', '-o',
        choices=['text', 'json', 'yaml'],
        default=None,
        help='Output format (default: text)',
    )
    p.add_argument(
        '--no-verify', action='store_true',
        help='Skip SSL certificate verification (e.g. for self-signed certs)',
    )
    p.add_argument(
        '--host-header', dest='host_header', metavar='HOST',
        help='Override HTTP Host header sent with every request  [env: DOCKSIDE_HOST_HEADER]',
    )


def _add_wait_flags(p, verb='operation to complete'):
    p.add_argument(
        '--no-wait', action='store_true',
        help=f'Return immediately without waiting for {verb}',
    )
    p.add_argument(
        '--timeout', type=int, default=120, metavar='SECS',
        help='Maximum seconds to wait (default: 120)',
    )


def _add_create_fields(p):
    """Fields available when creating a devtainer."""
    p.add_argument('--name', '-n', metavar='NAME',
                   help='Devtainer name (lowercase letters, digits, hyphens)')
    p.add_argument('--profile', metavar='PROFILE',
                   help='Launch profile name (required unless --from-json)')
    p.add_argument('--image', metavar='IMAGE',
                   help='Docker image (e.g. ubuntu:22.04)')
    p.add_argument('--runtime', metavar='RUNTIME',
                   help='Docker runtime (e.g. runc, sysbox-runc)')
    p.add_argument('--unixuser', metavar='USER',
                   help='Unix user inside the container')
    p.add_argument('--git-url', dest='git_url', metavar='URL',
                   help='Git repository URL to clone on launch')
    p.add_argument('--options', metavar='JSON',
                   help="Profile-specific options as a JSON object, "
                        "e.g. '{\"key\":\"val\"}'")
    p.add_argument('--from-json', metavar='FILE|-',
                   help='Read all creation parameters from a JSON file '
                        '(use - for stdin); command-line flags take precedence')
    _add_shared_fields(p)


def _add_shared_fields(p):
    """Fields available when creating or editing a devtainer."""
    p.add_argument('--network', metavar='NETWORK',
                   help='Docker network name')
    p.add_argument('--ide', metavar='IDE',
                   help='IDE to use (e.g. theia/latest, openvscode/latest)')
    p.add_argument('--description', metavar='TEXT',
                   help='Short description of the devtainer')
    p.add_argument('--viewers', metavar='LIST',
                   help='Comma-separated viewer usernames / role:NAME entries')
    p.add_argument('--developers', metavar='LIST',
                   help='Comma-separated developer usernames / role:NAME entries')
    p.set_defaults(private=None)
    p.add_argument('--private', dest='private', action='store_true',
                   help='Mark devtainer as private (hidden from other admins)')
    p.add_argument('--no-private', dest='private', action='store_false',
                   help='Mark devtainer as not private')
    p.add_argument('--access', metavar='JSON',
                   help="Per-router access control as a JSON object, "
                        "e.g. '{\"ssh\":\"developer\",\"www\":\"public\"}'")


# ── Client factory ────────────────────────────────────────────────────────────

def _normalise_server_url(url):
    """Ensure a server URL uses https:// and has no trailing slash."""
    if url.startswith('http://'):
        print('Warning: upgrading server URL from http:// to https://', file=sys.stderr)
        url = 'https://' + url[7:]
    elif not url.startswith('https://'):
        url = 'https://' + url
    return url.rstrip('/')


def _client(args):
    """
    Resolve the server and return (opener, server_url).

    Server resolution order: --server flag → DOCKSIDE_SERVER env → config current.
    The server arg may be a URL or a configured nickname.
    """
    cfg = load_config()

    server_ref = (
        getattr(args, 'server', None)
        or os.environ.get('DOCKSIDE_SERVER')
    )

    if server_ref:
        server_entry = _find_server(cfg, server_ref)
        if server_entry:
            server_url = server_entry['url']
        else:
            # Treat it as a bare URL
            server_url   = server_ref
            server_entry = {'url': server_url}
    else:
        server_entry = _current_server(cfg)
        if not server_entry:
            die(
                "No server configured. Run 'dockside login', "
                "set DOCKSIDE_SERVER, or use --server."
            )
        server_url = server_entry['url']

    server_url          = _normalise_server_url(server_url)
    server_entry['url'] = server_url

    username = getattr(args, 'username', None) or os.environ.get('DOCKSIDE_USER')
    password = getattr(args, 'password', None) or os.environ.get('DOCKSIDE_PASSWORD')
    if password and not username:
        die('--password requires --username (or DOCKSIDE_USER)')

    verify = not getattr(args, 'no_verify', False)
    host_header = (getattr(args, 'host_header', None)
                   or os.environ.get('DOCKSIDE_HOST_HEADER'))
    try:
        opener = get_authenticated_opener(
            server_url, server_entry, username, password,
            verify_ssl=verify,
            transient=(username is not None),
            host_header=host_header,
        )
    except APIError as e:
        die(str(e))

    # Effective output format: flag → server config → global config → 'text'
    fmt = (getattr(args, 'output', None)
           or server_entry.get('output')
           or cfg.get('output')
           or 'text')
    args._fmt = fmt

    return opener, server_url


# ── Command implementations ───────────────────────────────────────────────────

def _parse_extra_cookies(cookie_args):
    """Parse a list of 'NAME=VALUE' strings into a dict."""
    result = {}
    for item in (cookie_args or []):
        if '=' not in item:
            die(f"--cookie must be in NAME=VALUE format, got: {item!r}")
        name, _, value = item.partition('=')
        name = name.strip()
        if not name:
            die(f"--cookie name is empty in: {item!r}")
        result[name] = value
    return result


def cmd_login(args):
    cfg = load_config()

    server = (getattr(args, 'server', None)
              or os.environ.get('DOCKSIDE_SERVER')
              or (cfg.get('servers') or [{}])[0].get('url', '')
              or '')
    if not server:
        server = input('Server URL: ').strip()
    server = _normalise_server_url(server)

    # Nickname: from flag, or prompt interactively
    nickname = getattr(args, 'nickname', None) or ''
    if not nickname and sys.stdin.isatty():
        parsed   = urllib.parse.urlparse(server)
        default  = parsed.hostname or server
        prompted = input(f'Server nickname [{default}]: ').strip()
        nickname = prompted or default
    if nickname:
        nickname = nickname.strip()

    username = (getattr(args, 'username', None)
                or os.environ.get('DOCKSIDE_USER')
                or '')
    if not username:
        username = input('Username: ').strip()

    password = (getattr(args, 'password', None)
                or os.environ.get('DOCKSIDE_PASSWORD')
                or '')
    if not password:
        password = getpass.getpass('Password: ')

    extra_cookies = _parse_extra_cookies(getattr(args, 'cookie', None) or [])

    # Validate --cookie-file override (if supplied)
    cookie_file_override = (getattr(args, 'cookie_file', None) or '').strip() or None
    if cookie_file_override:
        try:
            cookie_file_override = _validate_cookie_filename(cookie_file_override)
        except ValueError as e:
            die(f'Invalid --cookie-file: {e}')

    # Determine the cookie file path using a provisional entry (nickname/override may be set)
    provisional_entry = {'url': server, 'nickname': nickname,
                         'cookie_file': cookie_file_override}
    cookie_file = _cookie_file_for(provisional_entry)

    host_header = (getattr(args, 'host_header', None)
                   or os.environ.get('DOCKSIDE_HOST_HEADER'))
    try:
        opener = login(server, username, password,
                       verify_ssl=not getattr(args, 'no_verify', False),
                       extra_cookies=extra_cookies or None,
                       cookie_file=cookie_file,
                       host_header=host_header)
    except APIError as e:
        die(str(e))

    _ensure_config_dir()
    _save_cookie_jar(opener._jar, cookie_file)

    _upsert_server(cfg, server, nickname=nickname or None,
                   cookie_file=cookie_file_override)
    cfg['current'] = nickname if nickname else server
    out_fmt = getattr(args, 'output', None)
    if out_fmt:
        cfg['output'] = out_fmt
    save_config(cfg)

    display = f'{nickname!r} ({server})' if nickname else server
    print(f'Logged in to {display} as {username}')
    print(f'Session saved to {cookie_file}')


def cmd_logout(args):
    cfg  = load_config()
    ref  = getattr(args, 'server', None) or cfg.get('current') or ''

    if getattr(args, 'all', False):
        # Remove everything
        removed = []
        for path in (CONFIG_FILE,):
            if os.path.exists(path) and not os.path.islink(path):
                os.remove(path)
                removed.append(path)
        for s in cfg.get('servers', []):
            cf = _cookie_file_for(s)
            if os.path.exists(cf) and not os.path.islink(cf):
                os.remove(cf)
                removed.append(cf)
        print('Logged out of all servers.')
        if removed:
            print('Removed:', ', '.join(removed))
        return

    server_entry = _find_server(cfg, ref) if ref else _current_server(cfg)
    if not server_entry:
        print('No active server session to clear.')
        return

    cookie_file = _cookie_file_for(server_entry)
    nick        = server_entry.get('nickname') or server_entry.get('url', '')
    removed     = []
    if os.path.isfile(cookie_file) and not os.path.islink(cookie_file):
        os.remove(cookie_file)
        removed.append(cookie_file)
    print(f'Logged out of {nick!r}.')
    if removed:
        print('Removed:', ', '.join(removed))


def cmd_server_list(args):
    cfg     = load_config()
    servers = cfg.get('servers') or []
    current = cfg.get('current', '')

    if not servers:
        print('No servers configured. Run: dockside login --server URL')
        return

    fmt = getattr(args, 'output', None) or cfg.get('output') or 'text'
    if fmt in ('json', 'yaml'):
        emit(servers, fmt)
        return

    headers = ['NICKNAME', 'URL', 'CURRENT']
    rows = []
    for s in servers:
        nick = s.get('nickname', '')
        url  = s.get('url', '')
        is_current = (current == url or (nick and current == nick))
        rows.append([nick, url, '✓' if is_current else ''])

    widths = [
        max(len(h), max((len(r[i]) for r in rows), default=0))
        for i, h in enumerate(headers)
    ]
    def fmt_row(r):
        return '  '.join(cell.ljust(widths[i]) for i, cell in enumerate(r))
    sep = '  '.join('-' * w for w in widths)
    print('\n'.join([fmt_row(headers), sep] + [fmt_row(r) for r in rows]))


def cmd_server_use(args):
    cfg = load_config()
    ref = args.server_name
    entry = _find_server(cfg, ref)
    if not entry:
        die(f'Server not found: {ref!r}. '
            f'Run "dockside server list" to see configured servers.')
    # Set current to nickname if one exists, otherwise URL
    cfg['current'] = entry.get('nickname') or entry['url']
    save_config(cfg)
    display = (f'{entry["nickname"]!r} ({entry["url"]})'
               if entry.get('nickname') else entry['url'])
    print(f'Now using {display}')


def cmd_list(args):
    opener, server = _client(args)
    try:
        containers = fetch_containers(opener, server)
    except APIError as e:
        die(str(e))

    show_urls = getattr(args, 'urls', False)

    if args._fmt in ('json', 'yaml'):
        emit(containers, args._fmt)
    else:
        print(_fmt_table(containers, show_urls=show_urls))


def cmd_get(args):
    opener, server = _client(args)
    try:
        containers = fetch_containers(opener, server)
        c = resolve(containers, args.devtainer)
    except APIError as e:
        die(str(e))

    if args._fmt in ('json', 'yaml'):
        emit(c, args._fmt)
    else:
        print(_fmt_detail(c))


def _load_json_input(from_json):
    """Load a JSON dict from a file path or '-' for stdin."""
    src = None
    try:
        if from_json == '-':
            src = sys.stdin
        else:
            src = open(from_json, encoding='utf-8')
        return json.load(src)
    except json.JSONDecodeError as e:
        die(f'Invalid JSON input: {e}')
    except OSError as e:
        die(f'Cannot read {from_json}: {e}')
    finally:
        if src and from_json != '-':
            src.close()


def _overlay_fields(args, fields, create):
    """Overwrite fields dict with any explicitly-supplied CLI flags."""
    def _set(key, val):
        if val is not None:
            fields[key] = val

    if create:
        _set('name',     getattr(args, 'name', None))
        _set('profile',  getattr(args, 'profile', None))
        _set('image',    getattr(args, 'image', None))
        _set('runtime',  getattr(args, 'runtime', None))
        _set('unixuser', getattr(args, 'unixuser', None))
        _set('gitURL',   getattr(args, 'git_url', None))
        raw_opts = getattr(args, 'options', None)
        if raw_opts:
            try:
                fields['options'] = json.loads(raw_opts)
            except json.JSONDecodeError as e:
                die(f'--options is not valid JSON: {e}')

    _set('network',     getattr(args, 'network', None))
    _set('IDE',         getattr(args, 'ide', None))
    _set('description', getattr(args, 'description', None))
    _set('viewers',     getattr(args, 'viewers', None))
    _set('developers',  getattr(args, 'developers', None))

    private = getattr(args, 'private', None)
    if private is not None:
        fields['private'] = private

    raw_access = getattr(args, 'access', None)
    if raw_access:
        try:
            fields['access'] = json.loads(raw_access)
        except json.JSONDecodeError as e:
            die(f'--access is not valid JSON: {e}')


def _collect_create_fields(args):
    fields = {}
    from_json = getattr(args, 'from_json', None)
    if from_json:
        fields = _load_json_input(from_json)
    _overlay_fields(args, fields, create=True)
    return fields


def _collect_edit_fields(args):
    fields = {}
    from_json = getattr(args, 'from_json', None)
    if from_json:
        fields = _load_json_input(from_json)
    _overlay_fields(args, fields, create=False)
    return fields


def cmd_create(args):
    opener, server = _client(args)
    fields = _collect_create_fields(args)

    if not fields.get('profile'):
        die("--profile is required (or supply 'profile' in --from-json input)")

    try:
        reservation = api_create(opener, server, fields)
    except APIError as e:
        die(str(e))

    if not reservation:
        die('Container creation failed: server returned no reservation')

    res_id = reservation.get('id')
    name   = reservation.get('name', res_id)
    print(f"Devtainer created: {name!r}  (reservation: {res_id})", file=sys.stderr)

    if not args.no_wait:
        print('Waiting for container to start', end='', file=sys.stderr, flush=True)
        ok = wait_for(opener, server, res_id, target=1, timeout=args.timeout)
        if ok:
            try:
                for c in fetch_containers(opener, server):
                    if c.get('id') == res_id:
                        reservation = c
                        break
            except APIError:
                pass
        else:
            print(
                f'Warning: timed out after {args.timeout}s waiting for '
                f'{name!r} to start. It may still be launching.',
                file=sys.stderr,
            )

    if args._fmt in ('json', 'yaml'):
        emit(reservation, args._fmt)
    else:
        print(_fmt_detail(reservation))


def cmd_start(args):
    opener, server = _client(args)
    try:
        containers = fetch_containers(opener, server)
        c = resolve(containers, args.devtainer)
    except APIError as e:
        die(str(e))

    res_id = c['id']
    name   = c.get('name', res_id)
    print(f'Starting {name!r}…', file=sys.stderr)
    try:
        api_control(opener, server, res_id, 'start')
    except APIError as e:
        die(str(e))

    if not args.no_wait:
        print('Waiting for container to become running', end='', file=sys.stderr, flush=True)
        ok = wait_for(opener, server, res_id, target=1, timeout=args.timeout)
        if ok:
            print(f'{name!r} is running.', file=sys.stderr)
        else:
            print(f'Warning: timed out after {args.timeout}s. '
                  f'{name!r} may still be starting.', file=sys.stderr)
    else:
        print(f'Start command sent for {name!r}.', file=sys.stderr)


def cmd_stop(args):
    opener, server = _client(args)
    try:
        containers = fetch_containers(opener, server)
        c = resolve(containers, args.devtainer)
    except APIError as e:
        die(str(e))

    res_id = c['id']
    name   = c.get('name', res_id)
    print(f'Stopping {name!r}…', file=sys.stderr)
    try:
        api_control(opener, server, res_id, 'stop')
    except APIError as e:
        die(str(e))

    if not args.no_wait:
        print('Waiting for container to stop', end='', file=sys.stderr, flush=True)
        ok = wait_for(opener, server, res_id, target=0, timeout=args.timeout)
        if ok:
            print(f'{name!r} stopped.', file=sys.stderr)
        else:
            print(f'Warning: timed out after {args.timeout}s. '
                  f'{name!r} may still be stopping.', file=sys.stderr)
    else:
        print(f'Stop command sent for {name!r}.', file=sys.stderr)


def cmd_edit(args):
    opener, server = _client(args)
    try:
        containers = fetch_containers(opener, server)
        c = resolve(containers, args.devtainer)
    except APIError as e:
        die(str(e))

    res_id = c['id']
    name   = c.get('name', res_id)
    fields = _collect_edit_fields(args)

    if not fields:
        die('Nothing to update – specify at least one field to change '
            '(e.g. --description, --developers, --ide, …)')

    try:
        reservation = api_update(opener, server, res_id, fields)
    except APIError as e:
        die(str(e))

    print(f'Updated {name!r}.', file=sys.stderr)
    if args._fmt in ('json', 'yaml'):
        emit(reservation, args._fmt)
    else:
        print(_fmt_detail(reservation))


def cmd_remove(args):
    opener, server = _client(args)
    try:
        containers = fetch_containers(opener, server)
        c = resolve(containers, args.devtainer)
    except APIError as e:
        die(str(e))

    res_id = c['id']
    name   = c.get('name', res_id)

    if not args.force:
        try:
            answer = input(f"Remove devtainer {name!r}? [y/N] ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            print('\nAborted.', file=sys.stderr)
            sys.exit(0)
        if answer not in ('y', 'yes'):
            print('Aborted.', file=sys.stderr)
            return

    print(f'Removing {name!r}…', file=sys.stderr)
    try:
        api_control(opener, server, res_id, 'remove')
    except APIError as e:
        die(str(e))

    if not args.no_wait:
        print('Waiting for container to be removed', end='', file=sys.stderr, flush=True)
        ok = wait_for(opener, server, res_id, target='gone', timeout=args.timeout)
        if ok:
            print(f'{name!r} removed.', file=sys.stderr)
        else:
            print(f'Warning: timed out after {args.timeout}s confirming '
                  f'removal of {name!r}.', file=sys.stderr)
    else:
        print(f'Remove command sent for {name!r}.', file=sys.stderr)


def cmd_logs(args):
    opener, server = _client(args)
    try:
        containers = fetch_containers(opener, server)
        c = resolve(containers, args.devtainer)
    except APIError as e:
        die(str(e))

    try:
        logs = api_logs(opener, server, c['id'])
    except APIError as e:
        die(str(e))

    if not getattr(args, 'raw', False):
        logs = sanitize_terminal(logs)

    sys.stdout.write(logs)


# ── Argument parser ───────────────────────────────────────────────────────────

EPILOG = """\
Addressing devtainers:
  DEVTAINER may be the container name, reservation ID, or Docker container ID
  (or an unambiguous prefix of the latter two).

Authentication:
  Run 'dockside login' once to store credentials for interactive use.
  For CI/scripted use, supply credentials via flags or environment variables
  on each invocation – no prior 'login' is needed:

    DOCKSIDE_SERVER=https://my.dockside.io \\
    DOCKSIDE_USER=ci DOCKSIDE_PASSWORD=secret \\
    dockside create --profile myprofile --name pr-123 --image ubuntu:22.04

Output formats:
  -o text  (default)  Human-readable tables / key-value blocks
  -o json             Pretty-printed JSON (machine-readable)
  -o yaml             YAML (machine-readable)

Examples:
  dockside login --server https://my.dockside.io --nickname prod
  dockside server list
  dockside server use prod
  dockside list
  dockside list --urls
  dockside list -o json | jq '.[].name'
  dockside get my-devtainer
  dockside create --profile default --name my-devtainer --image ubuntu:22.04 \\
      --git-url https://github.com/org/repo --developers alice,role:backend
  dockside start my-devtainer
  dockside stop  my-devtainer
  dockside edit  my-devtainer --description 'PR #42' --viewers bob
  dockside remove my-devtainer --force
  dockside logs  my-devtainer
  dockside logs  my-devtainer --raw
"""


def build_parser():
    p = argparse.ArgumentParser(
        prog='dockside',
        description='Dockside CLI – manage devtainers from the command line.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=EPILOG,
    )
    p.add_argument('--version', action='version', version=f'%(prog)s {__version__}')

    sub = p.add_subparsers(dest='command', metavar='COMMAND')
    sub.required = True

    # ── login ──────────────────────────────────────────────────────────────────
    sp = sub.add_parser(
        'login',
        help='Authenticate to a Dockside server and save the session',
        description=(
            'Authenticate to a Dockside server and persist the session cookie.\n\n'
            'Multiple servers can be configured by running login more than once.\n'
            'Use --nickname to give the server a memorable alias.'
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sp.add_argument('--server', '-s', metavar='URL',
                    help='Dockside server URL  [env: DOCKSIDE_SERVER]')
    sp.add_argument('--nickname', '-n', metavar='NAME',
                    help='Short alias for this server (e.g. prod, staging)')
    sp.add_argument('--username', '-u', metavar='USER',
                    help='Username  [env: DOCKSIDE_USER]')
    sp.add_argument('--password', '-p', metavar='PASS',
                    help='Password  [env: DOCKSIDE_PASSWORD]')
    sp.add_argument('--cookie', metavar='NAME=VALUE', action='append',
                    help='Inject an extra cookie (repeatable). '
                         'Required by some Dockside servers that use a global cookie '
                         '(e.g. --cookie globalCookie=secret).')
    sp.add_argument('--cookie-file', metavar='NAME',
                    help='Override the cookie filename (e.g. prod or prod.txt). '
                         'Stored in config.json so subsequent commands reuse the same file. '
                         'Useful when an inner Dockside server must share cookies with an '
                         'outer server (specify the outer server\'s cookie filename here).')
    sp.add_argument('--output', '-o', choices=['text', 'json', 'yaml'], default=None,
                    help='Default output format to store in config for this server')
    sp.add_argument('--no-verify', action='store_true',
                    help='Skip SSL certificate verification')
    sp.set_defaults(func=cmd_login)

    # ── logout ─────────────────────────────────────────────────────────────────
    sp = sub.add_parser('logout',
                        help='Clear saved session for the current (or specified) server')
    sp.add_argument('--server', '-s', metavar='URL_OR_NICKNAME',
                    help='Server to log out of (default: current server)')
    sp.add_argument('--all', action='store_true',
                    help='Log out of all configured servers and remove config')
    sp.set_defaults(func=cmd_logout)

    # ── server ─────────────────────────────────────────────────────────────────
    server_p = sub.add_parser('server', help='Manage configured Dockside servers')
    server_sub = server_p.add_subparsers(dest='server_command', metavar='SUBCOMMAND')
    server_sub.required = True

    sp = server_sub.add_parser('list', aliases=['ls'],
                                help='List configured servers')
    sp.add_argument('--output', '-o', choices=['text', 'json', 'yaml'], default=None)
    sp.set_defaults(func=cmd_server_list)

    sp = server_sub.add_parser('use',
                                help='Set the current default server')
    sp.add_argument('server_name', metavar='URL_OR_NICKNAME',
                    help='Server URL or nickname to make current')
    sp.set_defaults(func=cmd_server_use)

    # ── list ───────────────────────────────────────────────────────────────────
    sp = sub.add_parser('list', aliases=['ls'],
                         help='List all accessible devtainers')
    _add_global_flags(sp)
    sp.add_argument('--urls', action='store_true',
                    help='Add a URL column for each router type (ide, www, ssh, …)')
    sp.set_defaults(func=cmd_list)

    # ── get ────────────────────────────────────────────────────────────────────
    sp = sub.add_parser('get', help='Show details of a specific devtainer')
    _add_global_flags(sp)
    sp.add_argument('devtainer', metavar='DEVTAINER',
                    help='Name, reservation ID, or container ID')
    sp.set_defaults(func=cmd_get)

    # ── create ─────────────────────────────────────────────────────────────────
    sp = sub.add_parser(
        'create',
        help='Create (and launch) a new devtainer',
        description=(
            'Create a new devtainer reservation and launch its container.\n\n'
            'Parameters may be supplied as individual flags, as a JSON file '
            '(--from-json), or both (flags override JSON values).'
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    _add_global_flags(sp)
    _add_create_fields(sp)
    _add_wait_flags(sp, 'the container to start')
    sp.set_defaults(func=cmd_create)

    # ── start ──────────────────────────────────────────────────────────────────
    sp = sub.add_parser('start', help='Start a stopped devtainer')
    _add_global_flags(sp)
    sp.add_argument('devtainer', metavar='DEVTAINER')
    _add_wait_flags(sp, 'the container to become running')
    sp.set_defaults(func=cmd_start)

    # ── stop ───────────────────────────────────────────────────────────────────
    sp = sub.add_parser('stop', help='Stop a running devtainer')
    _add_global_flags(sp)
    sp.add_argument('devtainer', metavar='DEVTAINER')
    _add_wait_flags(sp, 'the container to stop')
    sp.set_defaults(func=cmd_stop)

    # ── edit ───────────────────────────────────────────────────────────────────
    sp = sub.add_parser(
        'edit',
        help="Edit a devtainer's metadata",
        description=(
            'Editable fields: --network, --ide, --description, '
            '--viewers, --developers, --private/--no-private, --access.\n\n'
            'Fields fixed at creation time (name, profile, image, runtime, '
            'unixuser, git-url) cannot be changed after launch.'
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    _add_global_flags(sp)
    sp.add_argument('devtainer', metavar='DEVTAINER')
    _add_shared_fields(sp)
    sp.add_argument('--from-json', metavar='FILE|-',
                    help='Read update parameters from a JSON file (use - for stdin)')
    sp.set_defaults(func=cmd_edit)

    # ── remove ─────────────────────────────────────────────────────────────────
    sp = sub.add_parser('remove', aliases=['rm', 'delete'],
                         help='Remove a devtainer')
    _add_global_flags(sp)
    sp.add_argument('devtainer', metavar='DEVTAINER')
    sp.add_argument('--force', '-f', action='store_true',
                    help='Skip confirmation prompt')
    _add_wait_flags(sp, 'the container to be removed')
    sp.set_defaults(func=cmd_remove)

    # ── logs ───────────────────────────────────────────────────────────────────
    sp = sub.add_parser('logs', help='Retrieve the logs of a devtainer')
    _add_global_flags(sp)
    sp.add_argument('devtainer', metavar='DEVTAINER')
    sp.add_argument('--raw', action='store_true',
                    help='Output logs without stripping ANSI escape sequences '
                         'and control characters (use only in trusted contexts)')
    sp.set_defaults(func=cmd_logs)

    return p


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    parser = build_parser()
    args   = parser.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
