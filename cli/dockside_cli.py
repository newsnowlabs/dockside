#!/usr/bin/env python3
"""Dockside CLI - manage devtainers from the command line.

Zero external dependencies - requires only Python 3.6+.
"""

import argparse
import copy
import datetime
import getpass
import http.cookiejar
import json
import os
import re
import ssl
import sys
import socket
import shlex
import tempfile
import time
import http.client
import urllib.error
import urllib.parse
import urllib.request

__version__ = '0.2.0'

_HTTP_DEBUG_LEVEL = 0   # set to 1 by --debug-http / _enable_debug_http()

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
        raise ValueError("Dockside config directory override is empty")
    abs_path = os.path.normpath(os.path.abspath(path))
    if '\x00' in abs_path:
        raise ValueError("Dockside config directory override contains null bytes")
    if not os.path.isabs(abs_path):
        raise ValueError("Dockside config directory override is not absolute")
    # normpath removes '..' but be explicit about rejecting them in the raw input
    for part in path.replace('\\', '/').split('/'):
        if part == '..':
            raise ValueError(
                f"Dockside config directory override {path!r} contains path traversal components"
            )
    if os.path.islink(abs_path):
        raise ValueError(f"Dockside config directory override {abs_path!r} is a symlink")
    return abs_path


def _resolve_config_dir():
    raw = os.environ.get('DOCKSIDE_CLI_CONFIG') or os.environ.get('DOCKSIDE_CONFIG_DIR')
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

STATUS_LABELS = {-3: 'removed', -2: 'prelaunch', -1: 'created', 0: 'exited', 1: 'running'}

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


def _save_target_cookie_jar(jar, cookie_file):
    """Persist only target-server cookies, excluding injected ancestor cookies."""
    target_jar = http.cookiejar.MozillaCookieJar()
    for cookie in jar:
        if cookie.has_nonstandard_attr('DocksideAncestor'):
            continue
        target_jar.set_cookie(copy.copy(cookie))
    _save_cookie_jar(target_jar, cookie_file)


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


class _NestLevelHandler(urllib.request.BaseHandler):
    """Inject a precomputed X-Nest-Level header into every outgoing request.

    Used when --connect-to bypasses the nginx proxy chain that would normally
    accumulate this header via 'proxy_set_header X-Nest-Level 1-$http_x_nest_level'.
    """
    def __init__(self, nest_level):
        self._nest_level = nest_level

    def https_request(self, req):
        req.add_unredirected_header('X-Nest-Level', self._nest_level)
        return req

    http_request = https_request


def _compute_nest_level(server_url):
    """Return the X-Nest-Level header value implied by the server URL's nesting depth.

    A dockside URL encodes how many container hops deep this instance is:
      www.domain           -> ''     (outermost, no header needed)
      www-host.domain      -> '1-'   (1 level deep)
      www-a--host.domain   -> '1-1-' (2 levels deep)

    The value mirrors what nginx would have accumulated via
    'proxy_set_header X-Nest-Level 1-$http_x_nest_level' across N proxy hops.
    Only injected when --connect-to is used (direct connection bypassing nginx).
    """
    hostname = urllib.parse.urlparse(server_url).hostname or ''
    first_label = hostname.split('.')[0]        # e.g. 'www-inner--dstest4'
    segments = first_label.split('--')          # split on double-dash separator
    # The first segment is 'service[-topHost]', e.g. 'www-dstest4' or 'www'.
    # (Double-dash separates outer container hops; the service label comes first.)
    m = re.match(r'^(?:.*-(?:wv|mb|webview|minibrowser)-)?[^-]+(-(.+))?$', segments[0])
    has_top_host = bool(m and m.group(2))
    nest_count = (len(segments) - 1) + (1 if has_top_host else 0)
    return '1-' * nest_count


def _enable_debug_http():
    """Enable http.client request/response tracing to stderr.

    Prints raw request/response headers (and more) for every HTTP/HTTPS
    connection — useful for verifying that headers like X-Nest-Level are
    actually being sent.

    NOTE: urllib's AbstractHTTPHandler.do_open() calls h.set_debuglevel()
    on each connection using the handler's own _debuglevel (set at handler
    construction time), which would override any class-level setting.
    _HTTP_DEBUG_LEVEL is therefore used to pass debuglevel=1 to each handler
    when it is constructed in _build_opener() / _build_opener_from_jar().
    """
    global _HTTP_DEBUG_LEVEL
    _HTTP_DEBUG_LEVEL = 1
    import logging
    logging.basicConfig(stream=sys.stderr)
    logging.getLogger('urllib.request').setLevel(logging.DEBUG)


class _ConnectToHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS connection that TCP-connects to a forced address while preserving
    the original hostname for TLS SNI (and therefore for the Host header)."""
    _force_host = None   # injected by _ConnectToHandler
    _force_port = None   # injected by _ConnectToHandler (None → use URL port)

    def connect(self):
        port = self._force_port if self._force_port is not None else (self.port or 443)
        self.sock = self._create_connection(
            (self._force_host, port),
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

    def __init__(self, connect_to, context, debuglevel=0):
        super().__init__(context=context, debuglevel=debuglevel)
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


def _build_opener(cookie_file, verify_ssl, host_header=None, connect_to=None, nest_level=None):
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
        urllib.request.HTTPRedirectHandler(),
    ]
    if connect_to:
        handlers.append(_ConnectToHandler(connect_to, ctx, debuglevel=_HTTP_DEBUG_LEVEL))
    else:
        handlers.append(urllib.request.HTTPSHandler(context=ctx, debuglevel=_HTTP_DEBUG_LEVEL))
    if host_header:
        handlers.append(_HostOverrideHandler(host_header))
    if nest_level:
        handlers.append(_NestLevelHandler(nest_level))
    opener = urllib.request.build_opener(*handlers)
    opener._jar = jar
    return opener


def _build_opener_from_jar(jar, verify_ssl, host_header=None, connect_to=None, nest_level=None):
    """Create a urllib opener from a pre-built cookie jar."""
    ctx = ssl.create_default_context()
    if not verify_ssl:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    handlers = [
        urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPRedirectHandler(),
    ]
    if connect_to:
        handlers.append(_ConnectToHandler(connect_to, ctx, debuglevel=_HTTP_DEBUG_LEVEL))
    else:
        handlers.append(urllib.request.HTTPSHandler(context=ctx, debuglevel=_HTTP_DEBUG_LEVEL))
    if host_header:
        handlers.append(_HostOverrideHandler(host_header))
    if nest_level:
        handlers.append(_NestLevelHandler(nest_level))
    opener = urllib.request.build_opener(*handlers)
    opener._jar = jar
    return opener


def _merge_ancestor_cookies(jar, cfg, server_entry, _seen=None, _target_url=None):
    """
    Recursively inject ancestor session cookies into jar, scoped to the target URL.

    Follows the 'parent' chain declared in the server config entry.  Each
    ancestor's session cookies are re-injected into jar with the TARGET
    server's hostname as the cookie domain — NOT the ancestor's own domain.

    This is necessary because urllib's HTTPCookieProcessor only sends a cookie
    when the cookie's domain attribute matches the request URL's hostname.  The
    ancestor's cookies carry the ancestor's hostname as domain (e.g. the outer
    proxy's own URL), which does not match the target server URL.  Re-injecting
    with the target hostname ensures the outer proxy's session cookie IS included
    in every request sent to the inner server, so the outer proxy can read and
    validate it from the incoming Cookie header.

    Ancestors are never written back to the target's cookie file.
    """
    if _target_url is None:
        _target_url = server_entry.get('url', '')
    if _seen is None:
        _seen = {server_entry.get('url', '')}
    parent_ref = (server_entry.get('parent') or '').strip()
    if not parent_ref:
        return
    parent_entry = _find_server(cfg, parent_ref)
    if not parent_entry or parent_entry.get('url', '') in _seen:
        return  # not found or cycle
    _seen.add(parent_entry.get('url', ''))
    parent_file = _cookie_file_for(parent_entry)
    if os.path.isfile(parent_file) and not os.path.islink(parent_file):
        anc_jar = http.cookiejar.MozillaCookieJar(parent_file)
        try:
            anc_jar.load(ignore_discard=True, ignore_expires=True)
            for c in anc_jar:
                # Re-inject with the target server's hostname so the cookie
                # IS sent when urllib makes requests to the target URL.
                _inject_cookie(
                    jar,
                    _target_url,
                    c.name,
                    c.value,
                    nonstandard_attrs={'DocksideAncestor': '1'},
                )
        except Exception:
            pass
    _merge_ancestor_cookies(jar, cfg, parent_entry, _seen, _target_url)


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


def _do_post(opener, url, params, timeout=30, as_json=False):
    """POST url with form-encoded (default) or JSON params → parsed JSON, raising APIError on failure."""
    if as_json:
        payload = json.dumps(params).encode('utf-8')
        content_type = 'application/json'
    else:
        payload = _encode_params(params).encode('utf-8')
        content_type = 'application/x-www-form-urlencoded'
    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            'Accept': 'application/json',
            'Content-Type': content_type,
        },
    )
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


# ── Cookie injection ──────────────────────────────────────────────────────────

def _inject_cookie(jar, server_url, name, value, nonstandard_attrs=None):
    """Inject a named cookie into the jar scoped to the server's hostname."""
    hostname = urllib.parse.urlparse(server_url).hostname or ''
    cookie = http.cookiejar.Cookie(
        version=0, name=name, value=value,
        port=None, port_specified=False,
        domain=hostname, domain_specified=True, domain_initial_dot=False,
        path='/', path_specified=True,
        secure=True, expires=None, discard=True,
        comment=None, comment_url=None, rest=dict(nonstandard_attrs or {}),
    )
    jar.set_cookie(cookie)


# ── Authentication ────────────────────────────────────────────────────────────

def _login_into_opener(opener, server, username, password, extra_cookies=None):
    """POST credentials using an existing opener and return it on success."""
    jar = opener._jar
    if extra_cookies:
        for cname, cval in extra_cookies.items():
            _inject_cookie(jar, server, cname, cval)
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
    if not any(not cookie.has_nonstandard_attr('DocksideAncestor') for cookie in jar):
        raise APIError(
            'Login failed – no session cookie received. '
            'Check credentials and ensure the server URL is correct.'
        )
    return opener


def login(server, username, password, verify_ssl=True,
          extra_cookies=None, cookie_file=None, host_header=None, connect_to=None,
          nest_level=None):
    """
    POST credentials to Dockside, return the authenticated opener.
    extra_cookies: dict of {name: value} injected before the POST.
    Raises APIError on failure.
    """
    if cookie_file is None:
        cookie_file = os.path.join(CONFIG_DIR, 'cookies.txt')
    opener = _build_opener(cookie_file, verify_ssl,
                           host_header=host_header, connect_to=connect_to,
                           nest_level=nest_level)
    return _login_into_opener(opener, server, username, password,
                              extra_cookies=extra_cookies)


def get_authenticated_opener(server, server_entry, username, password,
                              verify_ssl=True, transient=False,
                              extra_cookies=None, host_header=None, connect_to=None,
                              session_cookie_file=None, cookie_auth='all', cfg=None):
    """
    Return an authenticated opener.

    Performs a fresh login when username+password are given and optionally
    persists the session.  Otherwise loads stored cookies for this server.

    session_cookie_file: if set, use this path for the target's session cookies
        instead of the path derived from config.json.  Ancestor cookies are
        still merged from their normal paths in the system config.
    cookie_auth: 'all' (default) — load both target and ancestor cookies;
        'ancestors-only' — skip loading the target's stored session before the
        request/login while still merging ancestors in memory.
    cfg: loaded config dict, used to follow the 'parent' chain.  If None, no
        ancestor cookies are merged.
    """
    connect_to = connect_to or server_entry.get('connect_to')
    cookie_file = session_cookie_file or _cookie_file_for(server_entry)

    # When connecting directly (bypassing the nginx proxy chain), compute the
    # X-Nest-Level value from the server URL so the Perl handler sees the correct
    # nesting depth.  For normal public-URL connections, outer nginx sets this
    # header on each proxy_pass hop and we must not inject it ourselves.
    nest_level = _compute_nest_level(server) if connect_to else None

    if username and password:
        if cookie_auth == 'ancestors-only':
            jar = http.cookiejar.MozillaCookieJar()
            opener = _build_opener_from_jar(jar, verify_ssl, host_header, connect_to,
                                            nest_level=nest_level)
        else:
            opener = _build_opener(cookie_file, verify_ssl,
                                   host_header=host_header, connect_to=connect_to,
                                   nest_level=nest_level)
        if cfg:
            _merge_ancestor_cookies(opener._jar, cfg, server_entry)
        opener = _login_into_opener(opener, server, username, password,
                                    extra_cookies=extra_cookies)
        if not transient:
            _ensure_config_dir()
            _save_target_cookie_jar(opener._jar, cookie_file)
        return opener
    if cookie_auth == 'ancestors-only':
        # Empty in-memory jar for target; ancestor cookies injected first (with
        # the target server's domain) so the outer proxy receives and validates
        # them when requests pass through.
        jar = http.cookiejar.MozillaCookieJar()
        opener = _build_opener_from_jar(jar, verify_ssl, host_header, connect_to,
                                        nest_level=nest_level)
        if cfg:
            _merge_ancestor_cookies(jar, cfg, server_entry)
        return opener
    # Load stored cookies
    if not os.path.isfile(cookie_file):
        ref = server_entry.get('nickname') or server
        die(
            f"Not logged in to {ref!r}. Run 'dockside login' first, "
            "or supply --username / --password (or DOCKSIDE_USER / DOCKSIDE_PASSWORD)."
        )
    opener = _build_opener(cookie_file, verify_ssl,
                           host_header=host_header, connect_to=connect_to,
                           nest_level=nest_level)
    if cfg:
        _merge_ancestor_cookies(opener._jar, cfg, server_entry)
    return opener


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

def _encode_params(p):
    """
    Build a URL query string suitable for the Dockside API.

    Keys may contain dots (dotted-path notation for nested fields).
    Booleans → 0/1; dicts/lists → compact JSON strings; rest → str.
    None values are skipped; empty strings are included as-is (signals
    delete to the server).
    Uses quote() (not quote_plus()) so spaces become %20, not +.
    Perl's uri_unescape() only decodes %XX sequences, not + signs.
    """
    params = {}
    for k, v in p.items():
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
    qs = _encode_params(fields)
    data = _do_get(opener, server.rstrip('/') + '/containers/create?' + qs, timeout=30)
    return data.get('reservation')


def api_update(opener, server, res_id, fields):
    qs = _encode_params(fields)
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


def api_user_list(opener, server, sensitive=False):
    qs = ('?' + _encode_params({'sensitive': 1})) if sensitive else ''
    data = _do_get(opener, server.rstrip('/') + '/users' + qs)
    return data.get('data') or []


def api_user_get(opener, server, username, sensitive=False):
    qs = ('?' + _encode_params({'sensitive': 1})) if sensitive else ''
    url = server.rstrip('/') + '/users/' + urllib.parse.quote(username, safe='') + qs
    data = _do_get(opener, url)
    return data.get('data')


def api_user_create(opener, server, fields):
    data = _do_post(opener, server.rstrip('/') + '/users/create', fields, timeout=30)
    return data.get('data')


def api_user_update(opener, server, username, fields):
    url = server.rstrip('/') + '/users/' + urllib.parse.quote(username, safe='') + '/update'
    data = _do_post(opener, url, fields, timeout=30)
    return data.get('data')


def api_user_remove(opener, server, username):
    url = (server.rstrip('/') + '/users/' + urllib.parse.quote(username, safe='') + '/remove')
    data = _do_get(opener, url, timeout=30)
    return data.get('data')


def api_role_list(opener, server):
    data = _do_get(opener, server.rstrip('/') + '/roles')
    return data.get('data') or []


def api_role_get(opener, server, name):
    url = server.rstrip('/') + '/roles/' + urllib.parse.quote(name, safe='')
    data = _do_get(opener, url)
    return data.get('data')


def api_role_create(opener, server, fields):
    qs = _encode_params(fields)
    data = _do_get(opener, server.rstrip('/') + '/roles/create?' + qs, timeout=30)
    return data.get('data')


def api_role_update(opener, server, name, fields):
    qs = _encode_params(fields)
    url = (server.rstrip('/') + '/roles/' + urllib.parse.quote(name, safe='')
           + '/update?' + qs)
    data = _do_get(opener, url, timeout=30)
    return data.get('data')


def api_role_remove(opener, server, name):
    url = server.rstrip('/') + '/roles/' + urllib.parse.quote(name, safe='') + '/remove'
    data = _do_get(opener, url, timeout=30)
    return data.get('data')


def api_profile_list(opener, server):
    data = _do_get(opener, server.rstrip('/') + '/profiles')
    return data.get('data') or []


def api_profile_get(opener, server, name):
    url = server.rstrip('/') + '/profiles/' + urllib.parse.quote(name, safe='')
    data = _do_get(opener, url)
    return data.get('data')


def api_profile_create(opener, server, fields):
    data = _do_post(opener, server.rstrip('/') + '/profiles/create', fields, timeout=30, as_json=True)
    return data.get('data')


def api_profile_update(opener, server, name, fields):
    url = server.rstrip('/') + '/profiles/' + urllib.parse.quote(name, safe='') + '/update'
    data = _do_post(opener, url, fields, timeout=30, as_json=True)
    return data.get('data')


def api_profile_remove(opener, server, name):
    url = (server.rstrip('/') + '/profiles/' + urllib.parse.quote(name, safe='') + '/remove')
    data = _do_get(opener, url, timeout=30)
    return data.get('data')


def api_profile_rename(opener, server, name, new_name):
    qs = _encode_params({'new_name': new_name})
    url = (server.rstrip('/') + '/profiles/' + urllib.parse.quote(name, safe='')
           + '/rename?' + qs)
    data = _do_get(opener, url, timeout=30)
    return data.get('data')


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
            'gone' → container removed (reservation gone or status -3)
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        containers = fetch_containers(opener, server)
        if target == 'gone':
            c = next((c for c in containers if c.get('id') == res_id), None)
            if c is None:
                # Reservation fully deleted.
                if not quiet:
                    print(file=sys.stderr)
                return True
            if c.get('status', 0) <= -3:
                # Docker container removed; reservation preserved briefly.
                if not quiet:
                    print(file=sys.stderr)
                return True
        else:
            for c in containers:
                if c.get('id') == res_id:
                    status = c.get('status', -99)
                    if target == 1 and status == 1:
                        if not quiet:
                            print(file=sys.stderr)
                        return True
                    if target == 0 and status <= 0:
                        if not quiet:
                            print(file=sys.stderr)
                        return True
                    break
        if not quiet:
            print('.', end='', flush=True, file=sys.stderr)
        time.sleep(interval)
    if not quiet:
        print(file=sys.stderr)
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


def _ssh_alias(container):
    """Return the SSH host alias/FQDN for a container's ssh router."""
    ssh_url = (_router_urls(container) or {}).get('ssh', '')
    if not ssh_url or '@' not in ssh_url:
        return ''
    return ssh_url.rsplit('@', 1)[1]


def _connect_to_websocket_target(connect_to):
    """
    Return a websocket URL for the TCP target implied by --connect-to.

    The logical SSH host remains in --hostHeader=%n (and optionally --tlsSNI %n);
    this helper only decides the raw websocket TCP endpoint.
    """
    if not connect_to:
        return None
    if ':' in connect_to:
        host, _, port_str = connect_to.rpartition(':')
        port = int(port_str)
    else:
        host = connect_to
        port = 443
    if host in ('localhost', '::1'):
        host = '127.0.0.1'
    return f'wss://{host}:{port}' if port != 443 else f'wss://{host}'


def _auth_cookie_header(opener, server):
    """Return the server-generated Cookie header string from /getAuthCookies."""
    data = _do_get(opener, server.rstrip('/') + '/getAuthCookies', timeout=30)
    return data.get('data') or ''


def _merged_ssh_cookie_header(opener, server):
    """
    Return the Cookie header for SSH proxying to `server`.

    /getAuthCookies returns the target server's own auth cookie (plus any
    configured globalCookie), but it does not include ancestor cookies that the
    CLI merged into the opener jar via the configured parent chain. For nested
    Dockside instances we must prepend those ancestor cookies too, so the
    ProxyCommand request traverses the outer proxies with the same effective
    authentication state as normal CLI requests.
    """
    target_cookie_header = _auth_cookie_header(opener, server)

    ancestor_parts = []
    for cookie in getattr(opener, '_jar', ()) or ():
        try:
            if cookie.has_nonstandard_attr('DocksideAncestor'):
                ancestor_parts.append(f'{cookie.name}={cookie.value}')
        except Exception:
            continue

    if ancestor_parts and target_cookie_header:
        return '; '.join(ancestor_parts + [target_cookie_header])
    if ancestor_parts:
        return '; '.join(ancestor_parts)
    return target_cookie_header


def _build_ssh_proxy_command(cookie_header, websocket_url, nest_level=None, tls_sni=None):
    """
    Build a ProxyCommand line suitable for use inside ssh_config.

    `%n` and `%p` are intentionally left for OpenSSH to expand.
    """
    if not cookie_header:
        raise APIError('No auth cookie header returned by /getAuthCookies')
    argv = ['wstunnel', '--hostHeader=%n']
    if nest_level:
        argv.append(f'--customHeaders=X-Nest-Level: {nest_level}')
    argv.append(f'--customHeaders=Cookie: {cookie_header.replace("%", "%%")}')
    argv.extend(['-L', 'stdio:127.0.0.1:%p'])
    if tls_sni:
        argv.extend(['--tlsSNI', tls_sni])
    argv.append(websocket_url)
    return shlex.join(argv)


def _resolve_ssh_proxy_spec(opener, server, container, connect_to=None):
    """Resolve the pieces needed for an SSH ProxyCommand for a container."""
    ssh_alias = _ssh_alias(container)
    if not ssh_alias:
        die(f"Devtainer {container.get('name')!r} does not expose an 'ssh' router")
    server_hostname = urllib.parse.urlparse(server).hostname or ''
    ssh_user = ((container.get('data') or {}).get('unixuser') or '').strip()
    nest_level = _compute_nest_level(server) if connect_to else None
    if connect_to:
        websocket_url = _connect_to_websocket_target(connect_to)
        tls_sni = '%n'
    else:
        websocket_url = f'wss://{server_hostname}'
        tls_sni = None
    cookie_header = _merged_ssh_cookie_header(opener, server)
    proxy_command = _build_ssh_proxy_command(
        cookie_header,
        websocket_url,
        nest_level=nest_level,
        tls_sni=tls_sni,
    )
    return {
        'devtainer': container.get('name', ''),
        'ssh_user': ssh_user,
        'ssh_alias': ssh_alias,
        'ssh_config_host': _ssh_config_host_pattern(ssh_alias),
        'hostname': server_hostname,
        'websocket_url': websocket_url,
        'connect_to': connect_to or '',
        'nest_level': nest_level or '',
        'proxy_command': proxy_command,
    }


def _build_ssh_config_block(spec, identity_file=None, forward_agent=False, alias=None):
    """Render an ssh_config Host block from a resolved ssh proxy spec."""
    ssh_alias = alias or spec.get('ssh_config_host') or spec.get('ssh_alias') or ''
    ssh_hostname = spec.get('hostname') or ''
    proxy_command = spec.get('proxy_command') or ''
    ssh_user = spec.get('ssh_user') or ''
    if not ssh_alias or not ssh_hostname or not proxy_command:
        raise APIError('CLI did not resolve a usable SSH proxy spec')

    lines = [
        f'Host {ssh_alias}',
        f'    ProxyCommand {proxy_command}',
        f'    Hostname {ssh_hostname}',
    ]
    if ssh_user:
        lines.append(f'    User {ssh_user}')
    if identity_file:
        lines.append(f'    IdentityFile {identity_file}')
    if forward_agent:
        lines.append('    ForwardAgent yes')
    return '\n'.join(lines)


def _ssh_config_host_pattern(ssh_alias):
    """Return a reusable per-server ssh_config Host pattern for a resolved alias."""
    if not ssh_alias.startswith('ssh-'):
        return ssh_alias
    return re.sub(r'^ssh-(?:.*?(?=--|\.))', 'ssh-*', ssh_alias, count=1) if re.search(r'--|\.', ssh_alias[4:]) else 'ssh-*'


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
        default=argparse.SUPPRESS,
        help='Dockside server URL or configured nickname  [env: DOCKSIDE_SERVER]',
    )
    p.add_argument(
        '--username', '-u', metavar='USER',
        default=argparse.SUPPRESS,
        help='Username for one-shot auth  [env: DOCKSIDE_USER]',
    )
    p.add_argument(
        '--password', '-p', metavar='PASS',
        default=argparse.SUPPRESS,
        help='Password for one-shot auth  [env: DOCKSIDE_PASSWORD]',
    )
    p.add_argument(
        '--output', '-o',
        choices=['text', 'json', 'yaml'],
        default=argparse.SUPPRESS,
        help='Output format (default: text)',
    )
    p.add_argument(
        '--no-verify', action='store_true', default=argparse.SUPPRESS,
        help='Skip SSL certificate verification (e.g. for self-signed certs)',
    )
    p.add_argument(
        '--host-header', dest='host_header', metavar='HOST',
        default=argparse.SUPPRESS,
        help='Override HTTP Host header sent with every request  [env: DOCKSIDE_HOST_HEADER]',
    )
    p.add_argument(
        '--connect-to', dest='connect_to', metavar='HOST_OR_IP[:PORT]',
        default=argparse.SUPPRESS,
        help='Override TCP connection target (host/IP, optional :port). '
             'The server URL hostname is still used for TLS SNI and the Host header.  '
             '[env: DOCKSIDE_CONNECT_TO]',
    )
    p.add_argument(
        '--cookie-file', dest='session_cookie_file', metavar='PATH',
        default=argparse.SUPPRESS,
        help='Full path to use as the session cookie file for the target server, '
             'overriding the path derived from config.json. Ancestor cookies are '
             'still loaded from their normal paths in the system config. '
             'Useful for isolating sessions in test harnesses without affecting '
             'the system cookie store.',
    )
    p.add_argument(
        '--cookie-auth', dest='cookie_auth', metavar='MODE',
        choices=['all', 'ancestors-only'],
        default=argparse.SUPPRESS,
        help='Cookie loading mode: "all" (default) loads target and ancestor cookies; '
             '"ancestors-only" skips the target\'s stored session and uses only ancestor '
             'cookies merged in-memory (requires --username/--password).',
    )
    p.add_argument(
        '--debug-http', dest='debug_http', action='store_true', default=argparse.SUPPRESS,
        help='Print raw HTTP request/response headers for debugging.',
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


def _add_user_fields(p, create=False):
    """Fields for user create/edit."""
    p.add_argument('--email', metavar='EMAIL', help='Email address')
    p.add_argument('--role', metavar='ROLE', help='Role name (e.g. admin, developer)')
    p.add_argument('--name', metavar='DISPLAY_NAME', help='Display name')
    p.add_argument('--user-password', dest='user_password', metavar='PASS',
                   help="Set the user's login password (stored hashed in passwd file)")
    p.add_argument('--gh-token', dest='gh_token', metavar='TOKEN',
                   help='GitHub Personal Access Token passed as GH_TOKEN to containers')
    p.add_argument('--permissions', metavar='JSON',
                   help="Full permissions object as JSON, "
                        "e.g. '{\"createContainerReservation\":1}'")
    p.add_argument('--resources', metavar='JSON',
                   help="Full resources object as JSON, "
                        "e.g. '{\"profiles\":[\"*\"]}'")
    p.add_argument('--ssh', metavar='JSON',
                   help='Full ssh object as JSON')
    p.add_argument('--set', metavar='KEY=VALUE', action='append',
                   help='Set a nested property via dot-notation key (repeatable), e.g. '
                        "--set resources.profiles='[\"*\"]' or "
                        '--set permissions.createContainerReservation=1 ; '
                        'use --set KEY=@file to read the value from a file '
                        '(.json files are parsed as JSON, others as a string)')
    p.add_argument('--unset', metavar='KEY', action='append',
                   help='Delete a nested property via dot-notation key (repeatable), '
                        'e.g. --unset ssh.xyzzy')
    p.add_argument('--from-json', metavar='FILE|-',
                   help='Read base record from a JSON file (use - for stdin); '
                        'other flags take precedence')


def _add_role_fields(p):
    """Fields for role create/edit."""
    p.add_argument('--permissions', metavar='JSON',
                   help="Full permissions object as JSON, "
                        "e.g. '{\"createContainerReservation\":1}'")
    p.add_argument('--resources', metavar='JSON',
                   help="Full resources object as JSON, "
                        "e.g. '{\"networks\":{\"*\":1}}'")
    p.add_argument('--set', metavar='KEY=VALUE', action='append',
                   help='Set a nested property via dot-notation key (repeatable), e.g. '
                        '--set permissions.createContainerReservation=1 ; '
                        'use --set KEY=@file to read the value from a file '
                        '(.json files are parsed as JSON, others as a string)')
    p.add_argument('--unset', metavar='KEY', action='append',
                   help='Delete a nested property via dot-notation key (repeatable), '
                        'e.g. --unset permissions.createContainerReservation')
    p.add_argument('--from-json', metavar='FILE|-',
                   help='Read base record from a JSON file (use - for stdin); '
                        'other flags take precedence')


def _add_profile_fields(p, create=False):
    """Fields for profile create/edit."""
    p.add_argument('--active', dest='active', action='store_true', default=None,
                   help='Mark profile as active')
    p.add_argument('--no-active', dest='active', action='store_false',
                   help='Mark profile as inactive (draft/disabled)')
    p.add_argument('--set', metavar='KEY=VALUE', action='append',
                   help='Set a nested property via dot-notation (repeatable), e.g. '
                        '--set name="My Profile" or '
                        "--set images='[\"ubuntu:*\"]' ; "
                        'use --set KEY=@file.json to read value from a JSON file')
    p.add_argument('--unset', metavar='KEY', action='append',
                   help='Delete a nested property via dot-notation key (repeatable), '
                        'e.g. --unset security.apparmor')
    p.add_argument('--from-json', metavar='FILE|-',
                   help='Read full profile record from a JSON file (use - for stdin); '
                        'other flags take precedence')


def _collect_profile_fields(args, create=False):
    """Build the fields dict for a profile create/edit API call."""
    fields = {}
    from_json = getattr(args, 'from_json', None)
    if from_json:
        fields = _load_json_input(from_json)

    active = getattr(args, 'active', None)
    if active is not None:
        fields['active'] = active  # Python bool; preserved by JSON body encoding

    fields.update(_parse_set_args(getattr(args, 'set', None) or []))

    unset = getattr(args, 'unset', None) or []
    if unset:
        fields['_unset'] = unset

    return fields


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

    verify = not (getattr(args, 'no_verify', False) or server_entry.get('no_verify', False))
    host_header = (getattr(args, 'host_header', None)
                   or os.environ.get('DOCKSIDE_HOST_HEADER'))
    connect_to = (getattr(args, 'connect_to', None)
                  or os.environ.get('DOCKSIDE_CONNECT_TO'))
    effective_connect_to = connect_to or server_entry.get('connect_to')
    session_cookie_file = getattr(args, 'session_cookie_file', None) or None
    cookie_auth = getattr(args, 'cookie_auth', 'all') or 'all'
    if getattr(args, 'debug_http', False):
        _enable_debug_http()
    # transient: don't persist the session when using one-shot credentials,
    # unless --cookie-file was given (which provides a dedicated scratch space).
    transient = (username is not None
                 and session_cookie_file is None
                 and cookie_auth != 'ancestors-only')
    try:
        opener = get_authenticated_opener(
            server_url, server_entry, username, password,
            verify_ssl=verify,
            transient=transient,
            host_header=host_header,
            connect_to=connect_to,
            session_cookie_file=session_cookie_file,
            cookie_auth=cookie_auth,
            cfg=cfg,
        )
    except APIError as e:
        die(str(e))

    # Effective output format: flag → server config → global config → 'text'
    fmt = (getattr(args, 'output', None)
           or server_entry.get('output')
           or cfg.get('output')
           or 'text')
    args._fmt = fmt
    args._verify_effective = verify
    args._host_header_effective = host_header
    args._connect_to_effective = effective_connect_to

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

    current_entry = _current_server(cfg)
    server = (getattr(args, 'server', None)
              or os.environ.get('DOCKSIDE_SERVER')
              or (current_entry or {}).get('url', '')
              or (cfg.get('servers') or [{}])[0].get('url', '')
              or '')
    if not server:
        server = input('Server URL: ').strip()
    server = _normalise_server_url(server)
    # Re-resolve current_entry in case server was overridden or typed
    if not current_entry or current_entry.get('url') != server:
        current_entry = _find_server(cfg, server)

    # Nickname: from flag, then stored config entry, then prompt
    nickname = (getattr(args, 'nickname', None) or '').strip()
    if not nickname and current_entry:
        nickname = (current_entry.get('nickname') or '').strip()
    if not nickname and sys.stdin.isatty():
        parsed   = urllib.parse.urlparse(server)
        default  = parsed.hostname or server
        prompted = input(f'Server nickname [{default}]: ').strip()
        nickname = prompted or default
    if nickname:
        nickname = nickname.strip()

    display_ref = nickname if nickname else urllib.parse.urlparse(server).hostname or server
    print(f'Logging in to [{display_ref}]')

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

    host_header = (getattr(args, 'host_header', None)
                   or os.environ.get('DOCKSIDE_HOST_HEADER'))
    connect_to = (getattr(args, 'connect_to', None)
                  or os.environ.get('DOCKSIDE_CONNECT_TO')
                  or (current_entry or {}).get('connect_to')
                  or None)
    parent = ((getattr(args, 'parent', None) or '').strip()
              or (current_entry or {}).get('parent')
              or None)
    effective_cookie_file = cookie_file_override
    if effective_cookie_file is None and current_entry:
        effective_cookie_file = current_entry.get('cookie_file')
    provisional_entry = {
        'url': server,
        'nickname': nickname,
        'cookie_file': effective_cookie_file,
        'connect_to': connect_to,
        'parent': parent,
    }
    cookie_file = _cookie_file_for(provisional_entry)
    if getattr(args, 'debug_http', False):
        _enable_debug_http()
    try:
        get_authenticated_opener(
            server,
            provisional_entry,
            username,
            password,
            verify_ssl=not getattr(args, 'no_verify', False),
            transient=False,
            extra_cookies=extra_cookies or None,
            host_header=host_header,
            connect_to=connect_to,
            session_cookie_file=cookie_file,
            cfg=cfg,
        )
    except APIError as e:
        die(str(e))
    no_verify = getattr(args, 'no_verify', False)
    _upsert_server(cfg, server, nickname=nickname or None,
                   cookie_file=cookie_file_override,
                   connect_to=connect_to,
                   parent=parent)
    # Persist --no-verify so future commands for this server skip SSL
    # verification automatically without needing the flag each time.
    entry = _find_server(cfg, server)
    if no_verify:
        entry['no_verify'] = True
    else:
        entry.pop('no_verify', None)
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


def _parse_set_args(set_args):
    """
    Parse --set KEY=VALUE args into a flat dict.

    Keys use dot notation and are passed as-is to the server, which handles
    dotted-path merging in _apply_args_to_record.
    VALUE is JSON-decoded when possible; otherwise treated as a plain string.
    An empty VALUE (--set KEY=) sets the key to an empty string.

    If VALUE starts with '@', the remainder is treated as a file path:
    .json files are parsed as JSON; all other files are read as a string.
    """
    result = {}
    for item in (set_args or []):
        if '=' not in item:
            die(f'--set must be in KEY=VALUE format, got: {item!r}')
        key, _, raw_val = item.partition('=')
        key = key.strip()
        if not key:
            die(f'--set key is empty in: {item!r}')
        if raw_val.startswith('@'):
            path = raw_val[1:]
            try:
                with open(path, 'r') as fh:
                    content = fh.read()
            except OSError as e:
                die(f'--set {key}: cannot read file {path!r}: {e}')
            if path.endswith('.json'):
                try:
                    result[key] = json.loads(content)
                except (json.JSONDecodeError, ValueError) as e:
                    die(f'--set {key}: {path!r} is not valid JSON: {e}')
            else:
                result[key] = content
        elif raw_val == '':
            result[key] = ''
        else:
            try:
                result[key] = json.loads(raw_val)
            except (json.JSONDecodeError, ValueError):
                result[key] = raw_val
    return result


def _collect_user_fields(args, create=False):
    """Build the fields dict for a user create/edit API call."""
    fields = {}
    from_json = getattr(args, 'from_json', None)
    if from_json:
        fields = _load_json_input(from_json)

    def _set(k, attr):
        v = getattr(args, attr, None)
        if v is not None:
            fields[k] = v

    _set('email',    'email')
    _set('role',     'role')
    _set('name',     'name')
    _set('password', 'user_password')
    _set('gh_token', 'gh_token')

    for flag in ('permissions', 'resources', 'ssh'):
        raw = getattr(args, flag, None)
        if raw is not None:
            try:
                fields[flag] = json.loads(raw)
            except (json.JSONDecodeError, ValueError) as e:
                die(f'--{flag} is not valid JSON: {e}')

    fields.update(_parse_set_args(getattr(args, 'set', None) or []))

    unset = getattr(args, 'unset', None) or []
    if unset:
        fields['_unset'] = unset

    if getattr(args, 'sensitive', False):
        fields['sensitive'] = 1

    return fields


def _collect_role_fields(args, create=False):
    """Build the fields dict for a role create/edit API call."""
    fields = {}
    from_json = getattr(args, 'from_json', None)
    if from_json:
        fields = _load_json_input(from_json)

    if create:
        name = getattr(args, 'role_name', None)
        if name:
            fields['name'] = name

    for flag in ('permissions', 'resources'):
        raw = getattr(args, flag, None)
        if raw is not None:
            try:
                fields[flag] = json.loads(raw)
            except (json.JSONDecodeError, ValueError) as e:
                die(f'--{flag} is not valid JSON: {e}')

    fields.update(_parse_set_args(getattr(args, 'set', None) or []))

    unset = getattr(args, 'unset', None) or []
    if unset:
        fields['_unset'] = unset

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


# ── User command implementations ──────────────────────────────────────────────

def cmd_user_list(args):
    opener, server = _client(args)
    try:
        users = api_user_list(opener, server,
                              sensitive=getattr(args, 'sensitive', False))
    except APIError as e:
        die(str(e))
    if args._fmt in ('json', 'yaml'):
        emit(users, args._fmt)
        return
    if not users:
        print('No users found.')
        return
    for u in users:
        uname = u.get('username', '')
        role  = u.get('role', '')
        name  = u.get('name', '') or ''
        email = u.get('email', '') or ''
        print(f'{uname:<20}  role={role:<16}  name={name!r:<24}  email={email}')


def cmd_user_get(args):
    opener, server = _client(args)
    try:
        record = api_user_get(opener, server, args.username,
                              sensitive=getattr(args, 'sensitive', False))
    except APIError as e:
        die(str(e))
    if args._fmt in ('json', 'yaml'):
        emit(record, args._fmt)
    else:
        print(_fmt_detail(record))


def cmd_user_create(args):
    opener, server = _client(args)
    fields = _collect_user_fields(args, create=True)
    fields['username'] = args.username
    try:
        record = api_user_create(opener, server, fields)
    except APIError as e:
        die(str(e))
    uname = (record or {}).get('username') or fields.get('username')
    print(f'User created: {uname!r}', file=sys.stderr)
    if args._fmt in ('json', 'yaml'):
        emit(record, args._fmt)
    else:
        print(_fmt_detail(record))


def cmd_user_edit(args):
    opener, server = _client(args)
    fields = _collect_user_fields(args, create=False)
    if not fields:
        die('Nothing to update – specify at least one flag or --set KEY=VALUE')
    try:
        record = api_user_update(opener, server, args.username, fields)
    except APIError as e:
        die(str(e))
    print(f'User updated: {args.username!r}', file=sys.stderr)
    if args._fmt in ('json', 'yaml'):
        emit(record, args._fmt)
    else:
        print(_fmt_detail(record))


def cmd_user_remove(args):
    opener, server = _client(args)
    if not getattr(args, 'force', False):
        try:
            confirm = input(f'Remove user {args.username!r}? [y/N] ').strip().lower()
        except EOFError:
            confirm = ''
        if confirm not in ('y', 'yes'):
            print('Aborted.')
            return
    try:
        api_user_remove(opener, server, args.username)
    except APIError as e:
        die(str(e))
    if args._fmt in ('json', 'yaml'):
        emit({'ok': True}, args._fmt)
    else:
        print(f'User {args.username!r} removed.')


# ── Role command implementations ──────────────────────────────────────────────

def cmd_role_list(args):
    opener, server = _client(args)
    try:
        roles = api_role_list(opener, server)
    except APIError as e:
        die(str(e))
    if args._fmt in ('json', 'yaml'):
        emit(roles, args._fmt)
        return
    if not roles:
        print('No roles found.')
        return
    for r in roles:
        name  = r.get('name', '')
        perms = ', '.join(
            k for k, v in (r.get('permissions') or {}).items() if v
        ) or '(none)'
        print(f'{name:<20}  permissions: {perms}')


def cmd_role_get(args):
    opener, server = _client(args)
    try:
        record = api_role_get(opener, server, args.role_name)
    except APIError as e:
        die(str(e))
    if args._fmt in ('json', 'yaml'):
        emit(record, args._fmt)
    else:
        print(_fmt_detail(record))


def cmd_role_create(args):
    opener, server = _client(args)
    fields = _collect_role_fields(args, create=True)
    fields['name'] = args.role_name
    try:
        record = api_role_create(opener, server, fields)
    except APIError as e:
        die(str(e))
    print(f'Role created: {args.role_name!r}', file=sys.stderr)
    if args._fmt in ('json', 'yaml'):
        emit(record, args._fmt)
    else:
        print(_fmt_detail(record))


def cmd_role_edit(args):
    opener, server = _client(args)
    fields = _collect_role_fields(args, create=False)
    if not fields:
        die('Nothing to update – specify at least one flag or --set KEY=VALUE')
    try:
        record = api_role_update(opener, server, args.role_name, fields)
    except APIError as e:
        die(str(e))
    print(f'Role updated: {args.role_name!r}', file=sys.stderr)
    if args._fmt in ('json', 'yaml'):
        emit(record, args._fmt)
    else:
        print(_fmt_detail(record))


def cmd_role_remove(args):
    opener, server = _client(args)
    if not getattr(args, 'force', False):
        try:
            confirm = input(f'Remove role {args.role_name!r}? [y/N] ').strip().lower()
        except EOFError:
            confirm = ''
        if confirm not in ('y', 'yes'):
            print('Aborted.')
            return
    try:
        api_role_remove(opener, server, args.role_name)
    except APIError as e:
        die(str(e))
    if args._fmt in ('json', 'yaml'):
        emit({'ok': True}, args._fmt)
    else:
        print(f'Role {args.role_name!r} removed.')


# ── Profile command implementations ───────────────────────────────────────────

def cmd_profile_list(args):
    opener, server = _client(args)
    try:
        profiles = api_profile_list(opener, server)
    except APIError as e:
        die(str(e))
    if args._fmt in ('json', 'yaml'):
        emit(profiles, args._fmt)
        return
    if not profiles:
        print('No profiles found.')
        return
    for pr in profiles:
        pid    = pr.get('id', '')
        name   = pr.get('name', '') or ''
        active = pr.get('active', False)
        print(f'{pid:<30}  active={str(active):<5}  name={name!r}')


def cmd_profile_get(args):
    opener, server = _client(args)
    try:
        record = api_profile_get(opener, server, args.profile_name)
    except APIError as e:
        die(str(e))
    if args._fmt in ('json', 'yaml'):
        emit(record, args._fmt)
    else:
        print(_fmt_detail(record))


def cmd_profile_create(args):
    opener, server = _client(args)
    fields = _collect_profile_fields(args, create=True)
    fields['id'] = args.profile_name
    try:
        record = api_profile_create(opener, server, fields)
    except APIError as e:
        die(str(e))
    pid = (record or {}).get('id') or fields.get('id')
    print(f'Profile created: {pid!r}', file=sys.stderr)
    if args._fmt in ('json', 'yaml'):
        emit(record, args._fmt)
    else:
        print(_fmt_detail(record))


def cmd_profile_edit(args):
    opener, server = _client(args)
    fields = _collect_profile_fields(args, create=False)
    if not fields:
        die('Nothing to update – specify at least one flag, --set KEY=VALUE, or --from-json')
    try:
        record = api_profile_update(opener, server, args.profile_name, fields)
    except APIError as e:
        die(str(e))
    print(f'Profile updated: {args.profile_name!r}', file=sys.stderr)
    if args._fmt in ('json', 'yaml'):
        emit(record, args._fmt)
    else:
        print(_fmt_detail(record))


def cmd_profile_remove(args):
    opener, server = _client(args)
    if not getattr(args, 'force', False):
        try:
            confirm = input(f'Remove profile {args.profile_name!r}? [y/N] ').strip().lower()
        except EOFError:
            confirm = ''
        if confirm not in ('y', 'yes'):
            print('Aborted.')
            return
    try:
        api_profile_remove(opener, server, args.profile_name)
    except APIError as e:
        die(str(e))
    if args._fmt in ('json', 'yaml'):
        emit({'ok': True}, args._fmt)
    else:
        print(f'Profile {args.profile_name!r} removed.')


def cmd_profile_rename(args):
    opener, server = _client(args)
    try:
        result = api_profile_rename(opener, server, args.profile_name, args.new_name)
    except APIError as e:
        die(str(e))
    print(f'Profile {args.profile_name!r} renamed to {args.new_name!r}.')
    if args._fmt in ('json', 'yaml'):
        emit(result, args._fmt)


def cmd_check_url(args):
    """
    Fetch a URL using the current session's cookies and report the HTTP status.

    Session cookies (scoped to the server domain) are injected into the request
    for the target URL regardless of domain — matching the browser behaviour
    when accessing a devtainer sub-domain.  Use --connect-to to route the TCP
    connection to a different address (e.g. localhost:<port> for local/harness
    testing) while keeping the canonical hostname for TLS SNI and the Host header.
    """
    opener, _server = _client(args)
    url     = args.url
    timeout = getattr(args, 'timeout', 30)
    verify  = getattr(args, '_verify_effective', not getattr(args, 'no_verify', False))
    connect_to = getattr(args, '_connect_to_effective', None)
    nest_level = _compute_nest_level(_server) if connect_to else None

    # Build a cross-domain SSL context
    ctx = ssl.create_default_context()
    if not verify:
        ctx.check_hostname = False
        ctx.verify_mode    = ssl.CERT_NONE

    # Re-inject server session cookies into a new jar scoped to the target host
    target_host = urllib.parse.urlparse(url).hostname or ''
    target_jar  = http.cookiejar.CookieJar()
    for c in opener._jar:
        rest = dict(getattr(c, '_rest', {}))
        target_jar.set_cookie(http.cookiejar.Cookie(
            version=c.version, name=c.name, value=c.value,
            port=None, port_specified=False,
            domain=target_host, domain_specified=True, domain_initial_dot=False,
            path='/', path_specified=True,
            secure=False, expires=c.expires, discard=c.discard,
            comment=c.comment, comment_url=c.comment_url, rest=rest,
        ))

    handlers = [urllib.request.HTTPCookieProcessor(target_jar)]
    if getattr(args, 'no_redirect', False):
        class _NoRedir(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **kw):
                return None
            def http_error_301(self, req, fp, code, msg, hdrs):
                raise urllib.error.HTTPError(req.full_url, code, msg, hdrs, fp)
            def http_error_302(self, req, fp, code, msg, hdrs):
                raise urllib.error.HTTPError(req.full_url, code, msg, hdrs, fp)
            def http_error_303(self, req, fp, code, msg, hdrs):
                raise urllib.error.HTTPError(req.full_url, code, msg, hdrs, fp)
        handlers.append(_NoRedir())
    else:
        handlers.append(urllib.request.HTTPRedirectHandler())
    if connect_to:
        handlers.append(_ConnectToHandler(connect_to, ctx, debuglevel=_HTTP_DEBUG_LEVEL))
    else:
        handlers.append(urllib.request.HTTPSHandler(context=ctx, debuglevel=_HTTP_DEBUG_LEVEL))
    host_header = getattr(args, '_host_header_effective', None)
    if host_header:
        handlers.append(_HostOverrideHandler(host_header))
    if nest_level:
        handlers.append(_NestLevelHandler(nest_level))

    check_opener = urllib.request.build_opener(*handlers)
    req = urllib.request.Request(url)
    try:
        with check_opener.open(req, timeout=timeout) as resp:
            status      = resp.status
            body        = resp.read()
            resp_hdrs   = dict(resp.headers)
    except urllib.error.HTTPError as e:
        status    = e.code
        body      = e.read()
        resp_hdrs = dict(e.headers) if e.headers else {}
    except urllib.error.URLError as e:
        if getattr(args, 'debug_http', False):
            print(f'# debug-http: check-url url={url}', file=sys.stderr)
            print(f'# debug-http: connect_to={connect_to or "(direct)"}', file=sys.stderr)
            print(f'# debug-http: target_host={target_host or "(empty)"}', file=sys.stderr)
            print(f'# debug-http: nest_level={nest_level or "(none)"}', file=sys.stderr)
            print(f'# debug-http: urlerror={e!r}', file=sys.stderr)
        die(f'Connection error: {e.reason}')
    except socket.timeout as e:
        if getattr(args, 'debug_http', False):
            print(f'# debug-http: check-url url={url}', file=sys.stderr)
            print(f'# debug-http: connect_to={connect_to or "(direct)"}', file=sys.stderr)
            print(f'# debug-http: target_host={target_host or "(empty)"}', file=sys.stderr)
            print(f'# debug-http: nest_level={nest_level or "(none)"}', file=sys.stderr)
            print(f'# debug-http: timeout={e!r}', file=sys.stderr)
        die(f'Connection error: {e}')

    result = {
        'status':  status,
        'url':     url,
        'body':    body.decode('utf-8', errors='replace'),
        'headers': resp_hdrs,
    }

    if args._fmt in ('json', 'yaml'):
        emit(result, args._fmt)
    else:
        print(f'STATUS {status}')
        for k, v in resp_hdrs.items():
            print(f'{k}: {v}')
        print()
        sys.stdout.write(result['body'])


def cmd_ssh_proxy_command(args):
    """Print a ProxyCommand line for a devtainer's ssh router."""
    opener, server = _client(args)
    try:
        containers = fetch_containers(opener, server)
        container = resolve(containers, args.devtainer)
        result = _resolve_ssh_proxy_spec(
            opener,
            server,
            container,
            connect_to=getattr(args, '_connect_to_effective', None),
        )
    except APIError as e:
        die(str(e))

    if args._fmt in ('json', 'yaml'):
        emit(result, args._fmt)
    else:
        print(result['proxy_command'])


def cmd_ssh_config(args):
    """Print an ssh_config Host block for a devtainer SSH router."""
    opener, server = _client(args)
    try:
        containers = fetch_containers(opener, server)
        container = resolve(containers, args.devtainer)
        result = _resolve_ssh_proxy_spec(
            opener,
            server,
            container,
            connect_to=getattr(args, '_connect_to_effective', None),
        )
        result['ssh_config'] = _build_ssh_config_block(
            result,
            identity_file=getattr(args, 'identity_file', None),
            forward_agent=getattr(args, 'forward_agent', False),
            alias=getattr(args, 'ssh_alias_override', None),
        )
    except APIError as e:
        die(str(e))

    if args._fmt in ('json', 'yaml'):
        emit(result, args._fmt)
    else:
        print(result['ssh_config'])


def cmd_ssh(args):
    """
    SSH convenience wrapper.

    Supported forms:
      dockside ssh DEVTAINER [SSH-ARGS...]
      dockside ssh config DEVTAINER
      dockside ssh proxy-command DEVTAINER
    """
    if args.ssh_target == 'proxy-command':
        if not args.ssh_rest:
            die('ssh proxy-command requires DEVTAINER')
        if len(args.ssh_rest) > 1:
            die('ssh proxy-command accepts exactly one DEVTAINER argument')
        args.devtainer = args.ssh_rest[0]
        return cmd_ssh_proxy_command(args)
    if args.ssh_target == 'config':
        if not args.ssh_rest:
            die('ssh config requires DEVTAINER')
        if len(args.ssh_rest) > 1:
            die('ssh config accepts exactly one DEVTAINER argument')
        args.devtainer = args.ssh_rest[0]
        return cmd_ssh_config(args)

    opener, server = _client(args)
    try:
        containers = fetch_containers(opener, server)
        container = resolve(containers, args.ssh_target)
        spec = _resolve_ssh_proxy_spec(
            opener,
            server,
            container,
            connect_to=getattr(args, '_connect_to_effective', None),
        )
    except APIError as e:
        die(str(e))

    ssh_alias = spec.get('ssh_alias')
    ssh_hostname = spec.get('hostname')
    proxy_command = spec.get('proxy_command')
    ssh_user = spec.get('ssh_user')
    if not ssh_alias or not ssh_hostname or not proxy_command:
        die('CLI did not resolve a usable SSH proxy spec')

    destination = f'{ssh_user}@{ssh_alias}' if ssh_user else ssh_alias
    remote_args = list(getattr(args, 'ssh_rest', None) or [])
    if remote_args and remote_args[0] == '--':
        remote_args = remote_args[1:]
    argv = [
        'ssh',
        '-o', f'ProxyCommand={proxy_command}',
        '-o', f'HostName={ssh_hostname}',
    ]
    if getattr(args, 'identity_file', None):
        argv.extend(['-o', f'IdentityFile={args.identity_file}'])
    if getattr(args, 'forward_agent', False):
        argv.extend(['-o', 'ForwardAgent=yes'])
    argv.extend([destination] + remote_args)
    os.execvp('ssh', argv)


def cmd_whoami(args):
    """Show the authenticated user and their effective (server-merged) permissions."""
    opener, server = _client(args)
    try:
        data = _do_get(opener, server.rstrip('/') + '/me/')
    except APIError as e:
        die(str(e))
    record = data.get('data') or {}

    if args._fmt in ('json', 'yaml'):
        emit(record, args._fmt)
    else:
        print(f"username:  {record.get('username', '')}")
        print(f"id:        {record.get('id', '')}")
        print(f"role:      {record.get('role', '')}")
        perms = (record.get('permissions') or {}).get('actions') or {}
        if perms:
            print('permissions:')
            for k, v in sorted(perms.items()):
                print(f'  {k}: {v}')
        resources = record.get('resources') or {}
        if resources:
            print('resources:')
            for k, v in sorted(resources.items()):
                print(f'  {k}: {json.dumps(v)}')


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
    _add_global_flags(p)

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
    sp.add_argument('--parent', metavar='URL_OR_NICKNAME',
                    help='Declare a parent (outer) Dockside server for this entry. '
                         'When making requests to this server, cookies from the parent\'s '
                         'session file are automatically merged in-memory so that the outer '
                         'proxy is satisfied. Stored in config.json.')
    sp.add_argument('--output', '-o', choices=['text', 'json', 'yaml'], default=None,
                    help='Default output format to store in config for this server')
    sp.add_argument('--no-verify', action='store_true',
                    help='Skip SSL certificate verification')
    sp.add_argument('--host-header', dest='host_header', metavar='HOST',
                    help='Override HTTP Host header sent with every request  '
                         '[env: DOCKSIDE_HOST_HEADER]')
    sp.add_argument('--connect-to', dest='connect_to', metavar='HOST_OR_IP[:PORT]',
                    help='Override TCP connection target while keeping URL hostname for '
                         'TLS SNI and the Host header  [env: DOCKSIDE_CONNECT_TO]')
    sp.add_argument('--debug-http', dest='debug_http', action='store_true',
                    help='Print raw HTTP request/response headers for debugging.')
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

    # ── user ───────────────────────────────────────────────────────────────────
    user_p = sub.add_parser('user', help='Manage Dockside users (requires manageUsers permission)')
    user_sub = user_p.add_subparsers(dest='user_command', metavar='SUBCOMMAND')
    user_sub.required = True

    sp = user_sub.add_parser('list', aliases=['ls'], help='List all users')
    _add_global_flags(sp)
    sp.add_argument('--sensitive', action='store_true',
                    help='Include ssh private keys and gh_token in output')
    sp.set_defaults(func=cmd_user_list)

    sp = user_sub.add_parser('get', help='Show details of a specific user')
    _add_global_flags(sp)
    sp.add_argument('username', metavar='USERNAME')
    sp.add_argument('--sensitive', action='store_true',
                    help='Include ssh private keys and gh_token in output')
    sp.set_defaults(func=cmd_user_get)

    sp = user_sub.add_parser(
        'create',
        help='Create a new user',
        description=(
            'Create a new Dockside user.\n\n'
            'Simple fields may be given as individual flags.  For nested\n'
            'properties use --set KEY=VALUE with dot-notation, e.g.:\n'
            "  --set resources.profiles='[\"*\"]'\n"
            '  --set permissions.createContainerReservation=1\n\n'
            'A complete record may also be supplied via --from-json.'
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    _add_global_flags(sp)
    sp.add_argument('username', metavar='USERNAME', help='New username (must be unique)')
    _add_user_fields(sp, create=True)
    sp.set_defaults(func=cmd_user_create)

    sp = user_sub.add_parser(
        'edit',
        help='Edit an existing user',
        description=(
            'Edit a Dockside user record.\n\n'
            'Simple fields may be given as individual flags.  For nested\n'
            'properties use --set KEY=VALUE with dot-notation.'
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    _add_global_flags(sp)
    sp.add_argument('username', metavar='USERNAME')
    _add_user_fields(sp, create=False)
    sp.add_argument('--sensitive', action='store_true',
                    help='Include ssh private keys and gh_token in output')
    sp.set_defaults(func=cmd_user_edit)

    sp = user_sub.add_parser('remove', aliases=['rm', 'delete'], help='Remove a user')
    _add_global_flags(sp)
    sp.add_argument('username', metavar='USERNAME')
    sp.add_argument('--force', '-f', action='store_true',
                    help='Skip confirmation prompt')
    sp.set_defaults(func=cmd_user_remove)

    # ── role ───────────────────────────────────────────────────────────────────
    role_p = sub.add_parser('role', help='Manage Dockside roles (requires manageUsers permission)')
    role_sub = role_p.add_subparsers(dest='role_command', metavar='SUBCOMMAND')
    role_sub.required = True

    sp = role_sub.add_parser('list', aliases=['ls'], help='List all roles')
    _add_global_flags(sp)
    sp.set_defaults(func=cmd_role_list)

    sp = role_sub.add_parser('get', help='Show details of a specific role')
    _add_global_flags(sp)
    sp.add_argument('role_name', metavar='ROLE')
    sp.set_defaults(func=cmd_role_get)

    sp = role_sub.add_parser(
        'create',
        help='Create a new role',
        description=(
            'Create a new Dockside role.\n\n'
            'Use --set KEY=VALUE for nested properties, e.g.:\n'
            '  --set permissions.createContainerReservation=1\n'
            "  --set resources.networks='{\"*\":1}'"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    _add_global_flags(sp)
    sp.add_argument('role_name', metavar='ROLE', help='Role name')
    _add_role_fields(sp)
    sp.set_defaults(func=cmd_role_create)

    sp = role_sub.add_parser(
        'edit',
        help='Edit an existing role',
        description=(
            'Edit a Dockside role.\n\n'
            'Use --set KEY=VALUE for nested properties.'
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    _add_global_flags(sp)
    sp.add_argument('role_name', metavar='ROLE', help='Role name')
    _add_role_fields(sp)
    sp.set_defaults(func=cmd_role_edit)

    sp = role_sub.add_parser('remove', aliases=['rm', 'delete'], help='Remove a role')
    _add_global_flags(sp)
    sp.add_argument('role_name', metavar='ROLE', help='Role name')
    sp.add_argument('--force', '-f', action='store_true',
                    help='Skip confirmation prompt')
    sp.set_defaults(func=cmd_role_remove)

    # ── profile ────────────────────────────────────────────────────────────────
    profile_p = sub.add_parser(
        'profile',
        help='Manage Dockside profiles (requires manageProfiles permission)',
    )
    profile_sub = profile_p.add_subparsers(dest='profile_command', metavar='SUBCOMMAND')
    profile_sub.required = True

    sp = profile_sub.add_parser('list', aliases=['ls'], help='List all profiles')
    _add_global_flags(sp)
    sp.set_defaults(func=cmd_profile_list)

    sp = profile_sub.add_parser('get', help='Show the full record of a specific profile')
    _add_global_flags(sp)
    sp.add_argument('profile_name', metavar='PROFILE')
    sp.set_defaults(func=cmd_profile_get)

    sp = profile_sub.add_parser(
        'create',
        help='Create a new profile',
        description=(
            'Create a new Dockside profile.\n\n'
            'The PROFILE argument is the unique file-stem ID used in container\n'
            'create operations (e.g. "debian-dev", "01-myteam").\n\n'
            'Supply the full JSON via --from-json, or build the record field-by-\n'
            'field with --set KEY=VALUE (dot-notation).  The JSON "name" display\n'
            'field defaults to the profile ID if not specified.\n\n'
            'New profiles are created inactive (active=false) by default;\n'
            'use --active to enable immediately or edit afterwards.'
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    _add_global_flags(sp)
    sp.add_argument('profile_name', metavar='PROFILE',
                    help='Profile ID (used as the filename stem, e.g. "debian-dev")')
    _add_profile_fields(sp, create=True)
    sp.set_defaults(func=cmd_profile_create)

    sp = profile_sub.add_parser(
        'edit',
        help='Edit an existing profile',
        description=(
            'Edit a Dockside profile.\n\n'
            'Use --from-json to replace the full record, or --set KEY=VALUE\n'
            '(dot-notation) to update individual fields.  Use --active / --no-active\n'
            'to toggle the profile on or off.'
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    _add_global_flags(sp)
    sp.add_argument('profile_name', metavar='PROFILE')
    _add_profile_fields(sp, create=False)
    sp.set_defaults(func=cmd_profile_edit)

    sp = profile_sub.add_parser('remove', aliases=['rm', 'delete'],
                                 help='Remove a profile')
    _add_global_flags(sp)
    sp.add_argument('profile_name', metavar='PROFILE')
    sp.add_argument('--force', '-f', action='store_true',
                    help='Skip confirmation prompt')
    sp.set_defaults(func=cmd_profile_remove)

    sp = profile_sub.add_parser('rename', help='Rename a profile (changes the file-stem ID)')
    _add_global_flags(sp)
    sp.add_argument('profile_name', metavar='PROFILE', help='Current profile ID')
    sp.add_argument('new_name', metavar='NEW_PROFILE', help='New profile ID')
    sp.set_defaults(func=cmd_profile_rename)

    # ── check-url ──────────────────────────────────────────────────────────────
    sp = sub.add_parser(
        'check-url',
        help='Fetch a URL using the current session and report the HTTP status',
        description=(
            'Make an HTTP GET to URL using the current session cookies.\n\n'
            'Cookies are injected for the target domain regardless of the server\n'
            'domain — use this to check devtainer sub-domain URLs from scripts.\n\n'
            'Use --connect-to to route TCP to a local port while keeping the\n'
            'canonical hostname for TLS SNI (local/harness testing).'
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    _add_global_flags(sp)
    sp.add_argument('url', metavar='URL', help='HTTPS URL to fetch')
    sp.add_argument('--no-redirect', dest='no_redirect', action='store_true',
                    help='Do not follow HTTP redirects; return the 3xx status directly')
    sp.add_argument('--timeout', type=int, default=30, metavar='SECS',
                    help='Request timeout in seconds (default: 30)')
    sp.set_defaults(func=cmd_check_url)

    # ── ssh ───────────────────────────────────────────────────────────────────
    sp = sub.add_parser(
        'ssh',
        help='Connect to a devtainer ssh router or print its ProxyCommand',
        description=(
            'SSH helper for devtainer routes.\n\n'
            'All Dockside CLI options must appear before DEVTAINER. Anything after\n'
            'DEVTAINER is passed through to ssh unchanged.\n\n'
            'Direct connect:\n'
            '  dockside ssh DEVTAINER [SSH-ARGS...]\n\n'
            'Config block:\n'
            '  dockside ssh config DEVTAINER\n\n'
            'Low-level proxy command:\n'
            '  dockside ssh proxy-command DEVTAINER'
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    _add_global_flags(sp)
    sp.add_argument('--identity-file', metavar='PATH',
                    help='SSH private key to use for direct ssh or ssh config output')
    sp.add_argument('--forward-agent', action='store_true',
                    help='Enable SSH agent forwarding for direct ssh or ssh config output')
    sp.add_argument('--alias', dest='ssh_alias_override', metavar='HOST_ALIAS',
                    help='Override the Host alias used by ssh config output')
    sp.add_argument(
        'ssh_target',
        metavar='DEVTAINER',
        help='DEVTAINER identifier, or the literal subcommand name "config" or "proxy-command"',
    )
    sp.add_argument(
        'ssh_rest',
        nargs=argparse.REMAINDER,
        metavar='SSH-ARGS',
        help='SSH args for direct connect, or DEVTAINER for proxy-command; all Dockside options must come before DEVTAINER',
    )
    sp.set_defaults(func=cmd_ssh)

    # ── whoami ─────────────────────────────────────────────────────────────────
    sp = sub.add_parser(
        'whoami',
        help='Show the authenticated user and their effective permissions',
        description=(
            'Display the currently authenticated user and their effective\n'
            '(role-merged) permissions and resources as returned by the server.\n\n'
            'Useful for verifying that the stored session is valid and that\n'
            'the user has the required permissions before running tests or scripts.'
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    _add_global_flags(sp)
    sp.set_defaults(func=cmd_whoami)

    return p


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    parser = build_parser()
    args   = parser.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
