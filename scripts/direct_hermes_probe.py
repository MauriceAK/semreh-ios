#!/usr/bin/env python3
"""Guarded local Slice 1 backend. Never uses the installed personal Hermes CLI.

This is configuration separation, not a filesystem sandbox. Generated secrets and
state stay outside the repository. Only the foreground process is owned here;
never use `hermes serve --stop`, which scans unrelated Hermes processes.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys

SOURCE = Path('/Users/maurice/workspace/semreh-slice1-backend-source')
RUNTIME = Path('/Users/maurice/workspace/semreh-slice1-runtime')
PYTHON = Path('/Users/maurice/workspace/semreh-slice1-venv/bin/python')
PIN = '29112bef099274229cadff79cdff7bf7b99c4b77'
PORT = 18791
MARKER = 'semreh-direct-hermes-slice1-disposable-v1'


def checked_paths():
    for path in (SOURCE, RUNTIME):
        if path.is_symlink() or path.resolve() != path:
            raise RuntimeError(f'Unexpected/symlinked test path: {path}')
    if subprocess.check_output(['git', '-C', str(SOURCE), 'rev-parse', 'HEAD'], text=True).strip() != PIN:
        raise RuntimeError('Wrong Hermes pin')
    if subprocess.check_output(['git', '-C', str(SOURCE), 'status', '--porcelain'], text=True).strip():
        raise RuntimeError('Hermes source must be clean')


def private_json(path, data):
    # New files only: never overwrite an existing credential/configuration.
    with path.open('x', encoding='utf-8') as stream:
        os.chmod(path, 0o600)
        json.dump(data, stream, indent=2)
        stream.write('\n')


def initialize():
    checked_paths()
    if RUNTIME.exists():
        raise RuntimeError('Runtime already exists; inspect it rather than overwriting')
    password = secrets.token_urlsafe(24)
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1, dklen=32)
    encoded = 'scrypt$16384$8$1$' + base64.b64encode(salt).decode() + '$' + base64.b64encode(digest).decode()
    RUNTIME.mkdir(mode=0o700)
    for name in ('home', 'tools', 'tmp', 'cache', 'logs'):
        (RUNTIME / name).mkdir(mode=0o700)
    (RUNTIME / 'home' / 'home').mkdir(mode=0o700)
    private_json(RUNTIME / 'credentials.json', {'username': 'semreh-test', 'password': password})
    config = {
        'model': {'provider': 'custom', 'default': 'semreh-fixture', 'base_url': 'http://127.0.0.1:18792/v1'},
        'toolsets': [], 'platform_toolsets': {'cli': [], 'tui': []},
        'terminal': {'backend': 'local', 'cwd': str(RUNTIME / 'tools'), 'home_mode': 'profile'},
        'memory': {'memory_enabled': False, 'user_profile_enabled': False, 'provider': ''},
        'auxiliary': {'background_review': {'enabled': False}},
        'curator': {'enabled': False},
        'mcp_servers': {},
        'platforms': {},
        'kanban': {'dispatch_in_gateway': False, 'review_dispatch': False},
        'security': {'allow_lazy_installs': False},
        'cron': {'allow_agent_scheduling': False},
        'dashboard': {'public_url': 'http://semreh-slice1.test:18791', 'basic_auth': {
            'username': 'semreh-test', 'password_hash': encoded, 'secret': secrets.token_urlsafe(48)
        }},
    }
    private_json(RUNTIME / 'home' / 'config.yaml', config)  # JSON is valid YAML.
    private_json(RUNTIME / 'marker.json', {'marker': MARKER, 'source': str(SOURCE), 'port': PORT})
    print('Created disposable runtime; credentials are private and were not printed.')


def validate():
    checked_paths()
    for name in ('marker.json', 'credentials.json', 'home/config.yaml'):
        path = RUNTIME / name
        if path.is_symlink() or path.resolve() != path or not path.is_file():
            raise RuntimeError('Unexpected private runtime file')
        if path.stat().st_mode & 0o077:
            raise RuntimeError('Private runtime file is accessible to other users')
    marker = json.loads((RUNTIME / 'marker.json').read_text())
    if marker != {'marker': MARKER, 'source': str(SOURCE), 'port': PORT}:
        raise RuntimeError('Invalid runtime marker')
    for name in ('home', 'home/home', 'tools', 'tmp', 'cache', 'logs'):
        path = RUNTIME / name
        if path.is_symlink() or path.resolve() != path:
            raise RuntimeError('Runtime child escaped its expected path')
    config = json.loads((RUNTIME / 'home' / 'config.yaml').read_text())
    expected = {
        'model': {'provider': 'custom', 'default': 'semreh-fixture', 'base_url': 'http://127.0.0.1:18792/v1'},
        'terminal': {'backend': 'local', 'cwd': str(RUNTIME / 'tools'), 'home_mode': 'profile'},
        'memory': {'memory_enabled': False, 'user_profile_enabled': False, 'provider': ''},
        'auxiliary': {'background_review': {'enabled': False}},
        'curator': {'enabled': False}, 'mcp_servers': {}, 'platforms': {},
        'kanban': {'dispatch_in_gateway': False, 'review_dispatch': False},
        'security': {'allow_lazy_installs': False}, 'cron': {'allow_agent_scheduling': False},
        'toolsets': [], 'platform_toolsets': {'cli': [], 'tui': []},
    }
    if any(config.get(key) != value for key, value in expected.items()):
        raise RuntimeError('Disposable runtime configuration drifted; refusing launch')
    dashboard = config.get('dashboard', {})
    basic = dashboard.get('basic_auth', {})
    if (dashboard.get('public_url') != 'http://semreh-slice1.test:18791'
            or basic.get('username') != 'semreh-test'
            or not basic.get('password_hash', '').startswith('scrypt$')
            or len(basic.get('secret', '')) < 32):
        raise RuntimeError('Disposable authentication configuration drifted')
    print(json.dumps({'source_sha': PIN, 'hermes_home': str(RUNTIME / 'home'),
                      'tool_cwd': str(RUNTIME / 'tools'), 'port': PORT,
                      'os_isolation': False, 'personal_credentials_inherited': False}))


def serve():
    validate()
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', PORT))  # Fail on conflict; never evict a listener.
    # Deliberate allowlist: no inherited provider credentials, Desktop marker,
    # profile selection, SSH agent, or shell initialization environment.
    environment = {
        'PATH': str(PYTHON.parent) + ':/usr/bin:/bin',
        'HERMES_HOME': str(RUNTIME / 'home'),
        'TMPDIR': str(RUNTIME / 'tmp'),
        'XDG_CACHE_HOME': str(RUNTIME / 'cache'),
        'PYTHONPATH': str(SOURCE), 'PYTHONUNBUFFERED': '1',
        'PYTHONDONTWRITEBYTECODE': '1',
        'HERMES_SERVE_HEADLESS': '1',
        # Explicit valid toolset avoids the gateway's empty-list fallback to
        # platform defaults. Clarification has no terminal/file execution.
        'HERMES_TUI_TOOLSETS': 'clarify',
    }
    os.chdir(RUNTIME / 'tools')
    # Use the complete first-party serve startup: it bridges terminal settings
    # and discovers the basic-auth plugin before start_server. Explicit custom
    # HERMES_HOME roots profile lookup here; --isolated prevents server rerouting.
    os.execve(str(PYTHON), [str(PYTHON), '-m', 'hermes_cli.main',
        'serve', '--isolated', '--host', '127.0.0.1', '--port', str(PORT)], environment)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['init', 'validate', 'serve'])
    args = parser.parse_args()
    {'init': initialize, 'validate': validate, 'serve': serve}[args.action]()
