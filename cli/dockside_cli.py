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
import time
import urllib.error
import urllib.parse
import urllib.request

__version__ = '0.1.0'

# ── Configuration paths ───────────────────────────────────────────────────────

CONFIG_DIR  = os.environ.get('DOCKSIDE_CONFIG_DIR') or \
              os.path.join(os.path.expanduser('~'), '.config', 'dockside')
CONFIG_FILE = os.path.join(CONFIG_DIR, 'config.json')
COOKIE_FILE = os.path.join(CONFIG_DIR, 'cookies.txt')

# ── Status labels ─────────────────────────────────────────────────────────────

STATUS_LABELS = {-2: 'prelaunch', -1: 'created', 0: 'exited', 1: 'running'}

# ── YAML serialiser (zero external dependencies) ──────────────────────────────

_YAML_BOOL_LITERALS = {'true', 'false', 'yes', 'no', 'on', 'off', 'null', '~'}
_YAML_SPECIAL_FIRST = set('-?:,[]{}#&*!|>\'"@`%')


def _yaml_scalar(s):
    """Return a YAML-safe scalar representation of string s."""
    if not isinstance(s, str):
        s = str(s)
    need_quote = (
        not s
        or s.lower() in _YAML_BOOL_LITERALS
        or s[0] in _YAML_SPECIAL_FIRST
        or s[0].isdigit()                   # could be mis-parsed as number
        or any(c in s for c in ':#\n\r\t')
        or s != s.strip()
    )
    if need_quote:
        # JSON string encoding is always valid in YAML
        return json.dumps(s, ensure_ascii=False)
    return s


def _yaml_node(obj, depth):
    """Recursively emit YAML lines for obj at the given indent depth."""
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
        dp1 = '  ' * (depth + 1)   # padding that sub-nodes will have
        for item in obj:
            if isinstance(item, (dict, list)) and item:
                sub = _yaml_node(item, depth + 1)
                # sub[0] starts with dp1 padding; strip it, then prepend '- '
                # e.g. '  name: foo' → '- name: foo'  (at depth 0)
                first_stripped = sub[0][len(dp1):]
                lines.append(f'{pad}- {first_stripped}')
                # Remaining sub-lines already carry depth+1 indentation.
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
                scalar = _yaml_node(v, depth)[0]
                lines.append(f'{pad}{key}: {scalar}')
        return lines

    return [_yaml_scalar(str(obj))]


def to_yaml(obj):
    """Serialise obj to a YAML string."""
    return '\n'.join(_yaml_node(obj, 0)) + '\n'


# ── Output helpers ────────────────────────────────────────────────────────────

def emit(data, fmt):
    """Print data in the requested format (json/yaml/text handled by caller)."""
    if fmt == 'json':
        print(json.dumps(data, indent=2))
    elif fmt == 'yaml':
        sys.stdout.write(to_yaml(data))
    else:
        # Text format is rendered per-command; this is a fallback.
        print(json.dumps(data, indent=2))


def die(msg, code=1):
    print(f'error: {msg}', file=sys.stderr)
    sys.exit(code)


# ── Config persistence ────────────────────────────────────────────────────────

def load_config():
    """Load ~/.config/dockside/config.json, returning {} on missing/invalid."""
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_config(cfg):
    os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
    with open(CONFIG_FILE, 'w') as f:
        json.dump(cfg, f, indent=2)
    os.chmod(CONFIG_FILE, 0o600)


# ── HTTP client ───────────────────────────────────────────────────────────────

class APIError(Exception):
    def __init__(self, msg, http_status=None):
        super().__init__(msg)
        self.http_status = http_status


def _build_opener(cookie_file, verify_ssl):
    """Create a urllib opener with cookie jar and SSL settings."""
    jar = http.cookiejar.MozillaCookieJar(cookie_file)
    if os.path.exists(cookie_file):
        try:
            jar.load(ignore_discard=True, ignore_expires=True)
        except Exception:
            pass

    ctx = ssl.create_default_context()
    if not verify_ssl:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPSHandler(context=ctx),
        urllib.request.HTTPRedirectHandler(),
    )
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


# ── Authentication ────────────────────────────────────────────────────────────

def login(server, username, password, verify_ssl=True):
    """
    POST credentials to Dockside, return (opener, jar).
    Raises APIError on failure.
    """
    cookie_file = COOKIE_FILE
    opener = _build_opener(cookie_file, verify_ssl)

    url = server.rstrip('/') + '/'
    payload = urllib.parse.urlencode(
        {'username': username, 'password': password}
    ).encode()
    req = urllib.request.Request(url, data=payload, method='POST')
    try:
        with opener.open(req, timeout=15) as resp:
            # After successful login, Dockside redirects back; we're authenticated.
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


def get_authenticated_opener(server, username, password, verify_ssl=True, transient=False):
    """
    Return an authenticated opener.

    If username+password are supplied, perform a fresh login and optionally
    persist the session.  Otherwise load the stored cookie file.
    """
    if username and password:
        opener = login(server, username, password, verify_ssl=verify_ssl)
        if not transient:
            os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
            opener._jar.save(COOKIE_FILE, ignore_discard=True, ignore_expires=True)
            os.chmod(COOKIE_FILE, 0o600)
        return opener

    # Use stored cookies
    if not os.path.exists(COOKIE_FILE):
        die(
            "Not logged in. Run 'dockside login' first, "
            "or supply --username / --password (or DOCKSIDE_USER / DOCKSIDE_PASSWORD)."
        )
    return _build_opener(COOKIE_FILE, verify_ssl)


# ── Container resolution ──────────────────────────────────────────────────────

def fetch_containers(opener, server):
    """Fetch the full container list from the API."""
    data = _do_get(opener, server.rstrip('/') + '/containers')
    return data.get('data') or []


def resolve(containers, identifier):
    """
    Resolve a devtainer by name, reservation ID, or Docker container ID prefix.
    Returns the matching container dict, or exits with an error.
    """
    # Exact name match
    for c in containers:
        if c.get('name') == identifier:
            return c
    # Exact reservation ID
    for c in containers:
        if c.get('id') == identifier:
            return c
    # Docker container ID prefix (or full)
    matches = [
        c for c in containers
        if (c.get('containerId') or '').startswith(identifier)
    ]
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
    return urllib.parse.urlencode(params)


def api_create(opener, server, fields):
    """Create a new devtainer reservation."""
    qs = _encode_params(**fields)
    url = server.rstrip('/') + '/containers/create?' + qs
    data = _do_get(opener, url, timeout=30)
    return data.get('reservation')


def api_update(opener, server, res_id, fields):
    """Update an existing devtainer reservation."""
    qs = _encode_params(**fields)
    url = (server.rstrip('/') +
           f'/containers/{urllib.parse.quote(res_id)}/update?' + qs)
    data = _do_get(opener, url, timeout=30)
    return data.get('reservation')


def api_control(opener, server, res_id, cmd):
    """Send start/stop/remove to a devtainer. Returns updated container list."""
    url = (server.rstrip('/') +
           f'/containers/{urllib.parse.quote(res_id)}/{urllib.parse.quote(cmd)}')
    data = _do_get(opener, url, timeout=30)
    return data.get('data') or []


def api_logs(opener, server, res_id):
    """Retrieve container logs as plain text."""
    url = (
        server.rstrip('/') +
        f'/containers/{urllib.parse.quote(res_id)}/logs'
        '?stdout=true&stderr=true&format=text&clean_pty=true&merge=true'
    )
    return _do_get_text(opener, url, timeout=60)


# ── Wait for state ────────────────────────────────────────────────────────────

def wait_for(opener, server, res_id, target, timeout=120, interval=2, quiet=False):
    """
    Poll until the container reaches `target`.

    target: 1  → running
            0  → exited/stopped (status <= 0)
            'gone' → no longer in the container list
    """
    deadline = time.monotonic() + timeout
    dots = 0
    while time.monotonic() < deadline:
        containers = fetch_containers(opener, server)
        if target == 'gone':
            if not any(c.get('id') == res_id for c in containers):
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
            dots += 1
        time.sleep(interval)
    if not quiet and dots:
        print()
    return False


# ── Text rendering ────────────────────────────────────────────────────────────

def _status_str(status):
    return STATUS_LABELS.get(status, str(status))


def _fmt_table(containers):
    """Render containers as a text table."""
    if not containers:
        return '(no devtainers)'

    headers = ['NAME', 'STATUS', 'PROFILE', 'OWNER', 'URL']
    rows = []
    for c in containers:
        meta   = c.get('meta') or {}
        data   = c.get('data') or {}
        owner  = meta.get('owner') or (c.get('owner') or {}).get('username', '')
        rows.append([
            c.get('name', ''),
            _status_str(c.get('status')),
            c.get('profile', ''),
            owner,
            data.get('FQDN', ''),
        ])

    widths = [max(len(h), max((len(r[i]) for r in rows), default=0))
              for i, h in enumerate(headers)]

    def fmt_row(row):
        return '  '.join(cell.ljust(widths[i]) for i, cell in enumerate(row))

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

    access_str = json.dumps(meta.get('access') or {}, separators=(', ', ': '))

    lines = [
        ('Name',          c.get('name', '')),
        ('Status',        _status_str(c.get('status'))),
        ('Reservation',   c.get('id', '')),
        ('Container ID',  c.get('containerId') or docker.get('ID', '')),
        ('Profile',       c.get('profile', '')),
        ('Image',         data.get('image', '')),
        ('Runtime',       data.get('runtime', '')),
        ('Network',       data.get('network', '')),
        ('IDE',           meta.get('IDE', '')),
        ('URL',           data.get('FQDN', '')),
        ('Git URL',       data.get('gitURL', '')),
        ('Unix user',     data.get('unixuser', '')),
        ('Description',   meta.get('description', '')),
        ('Owner',         meta.get('owner') or owner.get('username', '')),
        ('Developers',    meta.get('developers', '')),
        ('Viewers',       meta.get('viewers', '')),
        ('Private',       'yes' if meta.get('private') else 'no'),
        ('Access',        access_str),
        ('Docker status', docker.get('Status', '')),
        ('Created',       created),
    ]

    label_width = max(len(l) for l, _ in lines)
    return '\n'.join(
        f'{label.ljust(label_width)}  {value}'
        for label, value in lines
        if value
    )


# ── Shared argument helpers ───────────────────────────────────────────────────

def _add_global_flags(p):
    """Add flags shared by every authenticated subcommand."""
    p.add_argument(
        '--server', '-s', metavar='URL',
        help='Dockside server URL  [env: DOCKSIDE_SERVER]',
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


def _add_wait_flags(p, verb='operation to complete'):
    p.add_argument(
        '--no-wait', action='store_true',
        help=f"Return immediately without waiting for {verb}",
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
                   help="Profile-specific options as a JSON object, e.g. '{\"key\":\"val\"}'")
    p.add_argument('--from-json', metavar='FILE|-',
                   help='Read all creation parameters from a JSON file (use - for stdin); '
                        'command-line flags take precedence')
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
    # --private / --no-private without clobbering the default=None sentinel
    p.set_defaults(private=None)
    p.add_argument('--private', dest='private', action='store_true',
                   help='Mark devtainer as private (hidden from other admins)')
    p.add_argument('--no-private', dest='private', action='store_false',
                   help='Mark devtainer as not private')
    p.add_argument('--access', metavar='JSON',
                   help="Per-router access control as a JSON object, "
                        "e.g. '{\"ssh\":\"developer\",\"www\":\"public\"}'")


# ── Client factory used by every command ─────────────────────────────────────

def _client(args):
    """
    Resolve the server URL and return (opener, server).
    Handles env-var → stored-config → flag precedence.
    """
    cfg = load_config()
    server = (
        getattr(args, 'server', None)
        or os.environ.get('DOCKSIDE_SERVER')
        or cfg.get('server')
    )
    if not server:
        die(
            "No server configured.  Run 'dockside login', "
            "set DOCKSIDE_SERVER, or use --server."
        )

    # Normalise: ensure HTTPS (Dockside rejects plain HTTP)
    if server.startswith('http://'):
        print(
            f'Warning: upgrading server URL from http:// to https://',
            file=sys.stderr,
        )
        server = 'https://' + server[7:]
    elif not server.startswith('https://'):
        server = 'https://' + server

    username = getattr(args, 'username', None) or os.environ.get('DOCKSIDE_USER')
    password = getattr(args, 'password', None) or os.environ.get('DOCKSIDE_PASSWORD')

    if password and not username:
        die('--password requires --username (or DOCKSIDE_USER)')

    verify = not getattr(args, 'no_verify', False)

    try:
        opener = get_authenticated_opener(
            server, username, password,
            verify_ssl=verify,
            transient=(username is not None),
        )
    except APIError as e:
        die(str(e))

    # Effective output format: flag > config default > 'text'
    fmt = getattr(args, 'output', None) or cfg.get('output') or 'text'
    args._fmt = fmt

    return opener, server


# ── Command implementations ───────────────────────────────────────────────────

def cmd_login(args):
    cfg = load_config()
    server = args.server or os.environ.get('DOCKSIDE_SERVER') or cfg.get('server')
    if not server:
        server = input('Server URL: ').strip()

    # Normalise URL
    if not server.startswith('http'):
        server = 'https://' + server
    if server.startswith('http://'):
        server = 'https://' + server[7:]
    server = server.rstrip('/')

    username = args.username or os.environ.get('DOCKSIDE_USER')
    if not username:
        username = input('Username: ').strip()

    password = args.password or os.environ.get('DOCKSIDE_PASSWORD')
    if not password:
        password = getpass.getpass('Password: ')

    try:
        opener = login(server, username, password, verify_ssl=not args.no_verify)
    except APIError as e:
        die(str(e))

    os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
    opener._jar.save(COOKIE_FILE, ignore_discard=True, ignore_expires=True)
    os.chmod(COOKIE_FILE, 0o600)

    cfg['server'] = server
    if args.output:
        cfg['output'] = args.output
    save_config(cfg)

    print(f'Logged in to {server} as {username}')
    print(f'Session saved to {COOKIE_FILE}')


def cmd_logout(_args):
    removed = []
    for path in (COOKIE_FILE, CONFIG_FILE):
        if os.path.exists(path):
            os.remove(path)
            removed.append(path)
    if removed:
        print('Logged out.  Removed:', ', '.join(removed))
    else:
        print('No saved session to clear.')


def cmd_list(args):
    opener, server = _client(args)
    try:
        containers = fetch_containers(opener, server)
    except APIError as e:
        die(str(e))

    if args._fmt in ('json', 'yaml'):
        emit(containers, args._fmt)
    else:
        print(_fmt_table(containers))


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


def _collect_create_fields(args):
    """Build the fields dict for a create call from parsed args."""
    fields = {}

    # Load from JSON file/stdin first, then let CLI flags override
    from_json = getattr(args, 'from_json', None)
    if from_json:
        src = sys.stdin if from_json == '-' else None
        try:
            if src is None:
                src = open(from_json)
            fields = json.load(src)
        except json.JSONDecodeError as e:
            die(f'Invalid JSON input: {e}')
        except OSError as e:
            die(f'Cannot read {from_json}: {e}')
        finally:
            if from_json != '-' and src:
                src.close()

    _overlay_fields(args, fields, create=True)
    return fields


def _collect_edit_fields(args):
    """Build the fields dict for an update call from parsed args."""
    fields = {}

    from_json = getattr(args, 'from_json', None)
    if from_json:
        src = sys.stdin if from_json == '-' else None
        try:
            if src is None:
                src = open(from_json)
            fields = json.load(src)
        except json.JSONDecodeError as e:
            die(f'Invalid JSON input: {e}')
        except OSError as e:
            die(f'Cannot read {from_json}: {e}')
        finally:
            if from_json != '-' and src:
                src.close()

    _overlay_fields(args, fields, create=False)
    return fields


def _overlay_fields(args, fields, create):
    """Overwrite fields with any explicitly-supplied CLI flags."""

    def _set(key, val):
        if val is not None:
            fields[key] = val

    if create:
        _set('name',      getattr(args, 'name', None))
        _set('profile',   getattr(args, 'profile', None))
        _set('image',     getattr(args, 'image', None))
        _set('runtime',   getattr(args, 'runtime', None))
        _set('unixuser',  getattr(args, 'unixuser', None))
        _set('gitURL',    getattr(args, 'git_url', None))

        raw_opts = getattr(args, 'options', None)
        if raw_opts:
            try:
                fields['options'] = json.loads(raw_opts)
            except json.JSONDecodeError as e:
                die(f'--options is not valid JSON: {e}')

    _set('network',      getattr(args, 'network', None))
    _set('IDE',          getattr(args, 'ide', None))
    _set('description',  getattr(args, 'description', None))
    _set('viewers',      getattr(args, 'viewers', None))
    _set('developers',   getattr(args, 'developers', None))

    private = getattr(args, 'private', None)
    if private is not None:
        fields['private'] = private

    raw_access = getattr(args, 'access', None)
    if raw_access:
        try:
            fields['access'] = json.loads(raw_access)
        except json.JSONDecodeError as e:
            die(f'--access is not valid JSON: {e}')


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
        ok = wait_for(opener, server, res_id, target=1,
                      timeout=args.timeout, quiet=False)
        if ok:
            # Refresh to get final state
            try:
                containers = fetch_containers(opener, server)
                for c in containers:
                    if c.get('id') == res_id:
                        reservation = c
                        break
            except APIError:
                pass
        else:
            print(
                f'Warning: timed out after {args.timeout}s waiting for '
                f'{name!r} to start.  It may still be launching.',
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
        ok = wait_for(opener, server, res_id, target=1,
                      timeout=args.timeout)
        if ok:
            print(f'{name!r} is running.', file=sys.stderr)
        else:
            print(
                f'Warning: timed out after {args.timeout}s.  '
                f'{name!r} may still be starting.',
                file=sys.stderr,
            )
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
        ok = wait_for(opener, server, res_id, target=0,
                      timeout=args.timeout)
        if ok:
            print(f'{name!r} stopped.', file=sys.stderr)
        else:
            print(
                f'Warning: timed out after {args.timeout}s.  '
                f'{name!r} may still be stopping.',
                file=sys.stderr,
            )
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
        die(
            'Nothing to update – specify at least one field to change '
            '(e.g. --description, --developers, --ide, …)'
        )

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
        ok = wait_for(opener, server, res_id, target='gone',
                      timeout=args.timeout)
        if ok:
            print(f'{name!r} removed.', file=sys.stderr)
        else:
            print(
                f'Warning: timed out after {args.timeout}s confirming removal of {name!r}.',
                file=sys.stderr,
            )
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
  dockside login --server https://my.dockside.io
  dockside list
  dockside list -o json | jq '.[].name'
  dockside get my-devtainer
  dockside create --profile default --name my-devtainer --image ubuntu:22.04 \\
      --git-url https://github.com/org/repo --developers alice,role:backend
  dockside start my-devtainer
  dockside stop  my-devtainer
  dockside edit  my-devtainer --description 'PR #42' --viewers bob
  dockside remove my-devtainer --force
  dockside logs  my-devtainer
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
        description='Authenticate to a Dockside server and persist the session cookie.',
    )
    sp.add_argument('--server', '-s', metavar='URL',
                    help='Dockside server URL  [env: DOCKSIDE_SERVER]')
    sp.add_argument('--username', '-u', metavar='USER',
                    help='Username  [env: DOCKSIDE_USER]')
    sp.add_argument('--password', '-p', metavar='PASS',
                    help='Password  [env: DOCKSIDE_PASSWORD]')
    sp.add_argument('--output', '-o', choices=['text', 'json', 'yaml'], default=None,
                    help='Default output format to store in config')
    sp.add_argument('--no-verify', action='store_true',
                    help='Skip SSL certificate verification')
    sp.set_defaults(func=cmd_login)

    # ── logout ─────────────────────────────────────────────────────────────────
    sp = sub.add_parser('logout', help='Clear saved session and config')
    sp.set_defaults(func=cmd_logout)

    # ── list ───────────────────────────────────────────────────────────────────
    sp = sub.add_parser(
        'list', aliases=['ls'],
        help='List all accessible devtainers',
    )
    _add_global_flags(sp)
    sp.set_defaults(func=cmd_list)

    # ── get ────────────────────────────────────────────────────────────────────
    sp = sub.add_parser(
        'get',
        help='Show details of a specific devtainer',
    )
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
        help='Edit a devtainer\'s metadata',
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
    sp = sub.add_parser(
        'remove', aliases=['rm', 'delete'],
        help='Remove a devtainer',
    )
    _add_global_flags(sp)
    sp.add_argument('devtainer', metavar='DEVTAINER')
    sp.add_argument('--force', '-f', action='store_true',
                    help='Skip confirmation prompt')
    _add_wait_flags(sp, 'the container to be removed')
    sp.set_defaults(func=cmd_remove)

    # ── logs ───────────────────────────────────────────────────────────────────
    sp = sub.add_parser(
        'logs',
        help='Stream the logs of a devtainer',
    )
    _add_global_flags(sp)
    sp.add_argument('devtainer', metavar='DEVTAINER')
    sp.set_defaults(func=cmd_logs)

    return p


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    parser = build_parser()
    args   = parser.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
