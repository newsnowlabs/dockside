#!/usr/bin/env python3
"""
Dockside Integration Test Runner Entry Point
============================================
Invoked by run_tests.sh. Discovers and runs test modules.

Environment variables (set by run_tests.sh / harness.sh):
  DOCKSIDE_TEST_MODE         local|remote|harness
  DOCKSIDE_TEST_HOST         Public FQDN (e.g. www.local.dockside.dev)
  DOCKSIDE_TEST_SERVER_URL   Full https URL (set by run_tests.sh)
  DOCKSIDE_TEST_HOST_HEADER  Host header override (set for local/harness modes)
  DOCKSIDE_TEST_ADMIN        username:password
  DOCKSIDE_TEST_DEV1         username:password (default: testdev1:testpass123)
  DOCKSIDE_TEST_DEV2         username:password (default: testdev2:testpass123)
  DOCKSIDE_TEST_VIEWER       username:password (default: testviewer:testpass123)
  DOCKSIDE_TEST_VERIFY_SSL   0 or 1 (default: 0)
  DOCKSIDE_TEST_ONLY         prefix filter (e.g. '04')
  DOCKSIDE_TEST_HARNESS_ID   Harness container ID (harness mode)
  DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY  1 or 0 (override default per-mode behaviour)
"""

import importlib.util
import os
import sys

# Allow importing from the repo's cli/ directory (for shared code if needed)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INTEGRATION_DIR = os.path.dirname(SCRIPT_DIR)
REPO_ROOT = os.path.dirname(os.path.dirname(INTEGRATION_DIR))

sys.path.insert(0, SCRIPT_DIR)
sys.path.insert(0, os.path.join(REPO_ROOT, 'cli'))

from dockside_test import TestRunner


def _parse_creds(env_var, default_user, default_pass):
    raw = os.environ.get(env_var, f'{default_user}:{default_pass}')
    if ':' in raw:
        user, _, pwd = raw.partition(':')
        return user.strip(), pwd.strip()
    return raw.strip(), default_pass


def _load_module(path):
    spec = importlib.util.spec_from_file_location(
        os.path.basename(path).replace('.py', ''), path
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    # Resolve CLI path
    cli_path = os.path.join(REPO_ROOT, 'cli', 'dockside')
    if not os.path.isfile(cli_path):
        print(f'ERROR: CLI not found at {cli_path}', file=sys.stderr)
        sys.exit(1)

    server_url = os.environ.get('DOCKSIDE_TEST_SERVER_URL', '')
    host_header = os.environ.get('DOCKSIDE_TEST_HOST_HEADER', '') or None
    test_mode = os.environ.get('DOCKSIDE_TEST_MODE', 'remote')
    verify_ssl = os.environ.get('DOCKSIDE_TEST_VERIFY_SSL', '0') == '1'
    only_prefix = os.environ.get('DOCKSIDE_TEST_ONLY', '').strip()
    harness_id = os.environ.get('DOCKSIDE_TEST_HARNESS_ID', '').strip() or None

    # Network modify override
    env_nm = os.environ.get('DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY', '').strip()
    allow_network_modify = None
    if env_nm == '1':
        allow_network_modify = True
    elif env_nm == '0':
        allow_network_modify = False

    if not server_url:
        print('ERROR: DOCKSIDE_TEST_SERVER_URL not set', file=sys.stderr)
        sys.exit(1)

    admin_creds = _parse_creds('DOCKSIDE_TEST_ADMIN', 'admin', 'changeme')
    dev1_creds = _parse_creds('DOCKSIDE_TEST_DEV1', 'testdev1', 'testpass123')
    dev2_creds = _parse_creds('DOCKSIDE_TEST_DEV2', 'testdev2', 'testpass123')
    viewer_creds = _parse_creds('DOCKSIDE_TEST_VIEWER', 'testviewer', 'testpass123')

    credentials = {
        'admin':  admin_creds,
        'dev1':   dev1_creds,
        'dev2':   dev2_creds,
        'viewer': viewer_creds,
    }

    runner = TestRunner(
        cli_path=cli_path,
        server_url=server_url,
        credentials=credentials,
        host_header=host_header,
        verify_ssl=verify_ssl,
        test_mode=test_mode,
        harness_container_id=harness_id,
        allow_network_modify=allow_network_modify,
    )

    # Discover test modules
    tests_dir = os.path.join(INTEGRATION_DIR, 'tests')
    test_files = sorted(
        f for f in os.listdir(tests_dir)
        if f.endswith('.py') and not f.startswith('_')
        and (not only_prefix or f.startswith(only_prefix))
    )

    total_tests = 0
    print(f'TAP version 13')
    for fname in test_files:
        path = os.path.join(tests_dir, fname)
        try:
            mod = _load_module(path)
        except Exception as e:
            print(f'# ERROR loading {fname}: {e}', file=sys.stderr)
            continue
        runner.run_module(mod)

    ok = runner.print_summary()
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    # When invoked as --cleanup by the bash EXIT/INT trap, do nothing.
    # The TestRunner's own atexit/signal handlers already handle cleanup.
    if '--cleanup' in sys.argv:
        sys.exit(0)
    main()
