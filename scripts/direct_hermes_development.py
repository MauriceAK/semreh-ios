#!/usr/bin/env python3
"""Guarded launcher for the disposable Slice 2 Hermes development checkout.

This launcher is deliberately separate from direct_hermes_probe.py.  It imports
the baseline probe so baseline validation remains independent, then derives the
new runtime's configuration and test credentials from that validated fixture.
It never touches the personal Hermes checkout, home, credentials, services, or
Tailscale state.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import socket
import stat
import subprocess

import direct_hermes_probe as baseline


DEV_SOURCE = Path('/Users/maurice/workspace/semreh-slice2-backend-dev')
DEV_RUNTIME = Path('/Users/maurice/workspace/semreh-slice2-runtime')
DEV_BRANCH = 'fix/semreh-session-reasoning'
BASE_PIN = baseline.PIN
PORT = baseline.PORT
MODEL_PORT = 18792
MARKER = 'semreh-direct-hermes-slice2-development-v1'
SHA_RE = re.compile(r'^[0-9a-fA-F]{40}$')
RUNTIME_DIRS = ('home', 'tools', 'tmp', 'cache', 'logs')


def _exact(path):
    if not path.is_absolute() or path.is_symlink() or path.resolve(strict=False) != path:
        raise RuntimeError(f'Unexpected or symlinked path: {path}')


def _private_dir(path):
    _exact(path)
    if not path.is_dir() or stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise RuntimeError(f'Private directory check failed: {path}')


def _private_file(path):
    _exact(path)
    if not path.is_file():
        raise RuntimeError(f'Private file check failed: {path}')
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode != 0o600:
        raise RuntimeError(f'Private file permission check failed: {path}')


def _json_file(path):
    _private_file(path)
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        raise RuntimeError(f'Invalid JSON fixture file: {path}') from error


def _git(*args):
    return subprocess.check_output(
        ['git', '-C', str(DEV_SOURCE), *args], text=True, stderr=subprocess.DEVNULL
    ).strip()


def _assert_no_dev_env():
    path = DEV_SOURCE / '.env'
    if path.exists() or path.is_symlink():
        raise RuntimeError('The development checkout must not contain .env')


def _validate_dev_source(backend_sha):
    if not SHA_RE.fullmatch(backend_sha):
        raise RuntimeError('--backend-sha must be exactly 40 hexadecimal characters')
    _exact(DEV_SOURCE)
    if not DEV_SOURCE.is_dir():
        raise RuntimeError('Development checkout is missing')
    try:
        if Path(_git('rev-parse', '--show-toplevel')).resolve() != DEV_SOURCE:
            raise RuntimeError('Development checkout resolved to an unexpected path')
        if _git('branch', '--show-current') != DEV_BRANCH:
            raise RuntimeError('Development checkout is not on the approved branch')
        head = _git('rev-parse', 'HEAD')
        if head.lower() != backend_sha.lower():
            raise RuntimeError('Explicit backend SHA does not match clean development HEAD')
        if subprocess.run(
            ['git', '-C', str(DEV_SOURCE), 'merge-base', '--is-ancestor', BASE_PIN, head],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode != 0:
            raise RuntimeError('Development HEAD is not descended from the pinned baseline')
        if _git('status', '--porcelain=v1', '--untracked-files=all'):
            raise RuntimeError('Development checkout must be clean')
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError('Could not validate the development checkout') from error
    _assert_no_dev_env()


def _validated_baseline_fixture():
    # This call intentionally uses the imported module's untouched constants.
    baseline.validate()
    baseline_config_path = baseline.RUNTIME / 'home' / 'config.yaml'
    baseline_credentials_path = baseline.RUNTIME / 'credentials.json'
    config = _json_file(baseline_config_path)
    credentials = _json_file(baseline_credentials_path)
    if set(credentials) != {'username', 'password'}:
        raise RuntimeError('Approved baseline credentials are not the disposable fixture')
    basic_auth = config.get('dashboard', {}).get('basic_auth', {})
    if basic_auth.get('username') != credentials.get('username'):
        raise RuntimeError('Baseline credential and auth identities do not agree')
    if credentials.get('username') != 'semreh-test' or not isinstance(credentials.get('password'), str):
        raise RuntimeError('Approved baseline credentials are not the disposable fixture')
    return config, credentials


def _expected_config(baseline_config):
    expected = copy.deepcopy(baseline_config)
    terminal = expected.get('terminal')
    if not isinstance(terminal, dict) or not isinstance(terminal.get('cwd'), str):
        raise RuntimeError('Baseline configuration has no terminal cwd')
    terminal['cwd'] = str(DEV_RUNTIME / 'tools')
    return expected


def _marker():
    return {
        'marker': MARKER,
        'devsource': str(DEV_SOURCE),
        'runtime': str(DEV_RUNTIME),
        'base_pin': BASE_PIN,
        'port': PORT,
        'model_port': MODEL_PORT,
    }


def _validate_runtime(baseline_config, baseline_credentials):
    _private_dir(DEV_RUNTIME)
    for name in RUNTIME_DIRS:
        _private_dir(DEV_RUNTIME / name)
    _private_dir(DEV_RUNTIME / 'home' / 'home')
    for name in ('credentials.json', 'marker.json', 'home/config.yaml'):
        _private_file(DEV_RUNTIME / name)
    _exact(DEV_RUNTIME / 'home/state.db')
    if (DEV_RUNTIME / 'home/.env').exists() or (DEV_RUNTIME / 'home/.env').is_symlink():
        raise RuntimeError('Development runtime must use fixture config only, not .env')

    marker = _json_file(DEV_RUNTIME / 'marker.json')
    if marker != _marker():
        raise RuntimeError('Development runtime marker does not match approved paths and pin')
    credentials = _json_file(DEV_RUNTIME / 'credentials.json')
    if credentials != baseline_credentials:
        raise RuntimeError('Development credentials differ from the disposable baseline')
    actual_config = _json_file(DEV_RUNTIME / 'home' / 'config.yaml')
    if actual_config != _expected_config(baseline_config):
        raise RuntimeError('Development configuration differs from baseline beyond terminal.cwd')


def _validate_all(backend_sha):
    baseline_config, baseline_credentials = _validated_baseline_fixture()
    _validate_dev_source(backend_sha)
    _validate_runtime(baseline_config, baseline_credentials)
    print(json.dumps({
        'backend_sha': backend_sha.lower(),
        'base_pin': BASE_PIN,
        'hermes_home': str(DEV_RUNTIME / 'home'),
        'tool_cwd': str(DEV_RUNTIME / 'tools'),
        'port': PORT,
        'model_port': MODEL_PORT,
    }))
    return baseline_config, baseline_credentials


def initialize(backend_sha):
    baseline_config, baseline_credentials = _validated_baseline_fixture()
    _validate_dev_source(backend_sha)
    if DEV_RUNTIME.exists() or DEV_RUNTIME.is_symlink():
        raise RuntimeError('Development runtime already exists; refusing to overwrite it')
    _exact(DEV_RUNTIME.parent)
    DEV_RUNTIME.mkdir(mode=0o700)
    for name in RUNTIME_DIRS:
        (DEV_RUNTIME / name).mkdir(mode=0o700)
    (DEV_RUNTIME / 'home' / 'home').mkdir(mode=0o700)
    baseline.private_json(DEV_RUNTIME / 'credentials.json', baseline_credentials)
    baseline.private_json(DEV_RUNTIME / 'home' / 'config.yaml', _expected_config(baseline_config))
    baseline.private_json(DEV_RUNTIME / 'marker.json', _marker())
    _validate_all(backend_sha)


def _assert_port_free():
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(('127.0.0.1', PORT))
        except OSError as error:
            raise RuntimeError(f'Port {PORT} is already in use; refusing to evict a process') from error


def serve(backend_sha):
    _validate_all(backend_sha)
    _assert_port_free()
    environment = {
        'PATH': str(baseline.PYTHON.parent) + ':/usr/bin:/bin',
        'HERMES_HOME': str(DEV_RUNTIME / 'home'),
        'TMPDIR': str(DEV_RUNTIME / 'tmp'),
        'XDG_CACHE_HOME': str(DEV_RUNTIME / 'cache'),
        'PYTHONPATH': str(DEV_SOURCE),
        'PYTHONUNBUFFERED': '1',
        'PYTHONDONTWRITEBYTECODE': '1',
        'HERMES_SERVE_HEADLESS': '1',
        'HERMES_TUI_TOOLSETS': 'clarify',
    }
    os.chdir(DEV_RUNTIME / 'tools')
    os.execve(str(baseline.PYTHON), [
        str(baseline.PYTHON), '-m', 'hermes_cli.main', 'serve', '--isolated',
        '--host', '127.0.0.1', '--port', str(PORT),
    ], environment)


def _sha_argument(value):
    if not SHA_RE.fullmatch(value):
        raise argparse.ArgumentTypeError('must be exactly 40 hexadecimal characters')
    return value.lower()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('init', 'validate', 'serve'))
    parser.add_argument('--backend-sha', required=True, type=_sha_argument)
    args = parser.parse_args()
    try:
        {'init': initialize, 'validate': _validate_all, 'serve': serve}[args.action](args.backend_sha)
    except RuntimeError as error:
        parser.error(str(error))
