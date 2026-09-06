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
COMPRESSION_RUNTIME = Path('/Users/maurice/workspace/semreh-slice2-compression-runtime')
IN_PLACE_COMPRESSION_RUNTIME = Path('/Users/maurice/workspace/semreh-slice2-compression-inplace-runtime')
DEV_BRANCH = 'fix/semreh-session-reasoning'
BASE_PIN = baseline.PIN
PORT = baseline.PORT
COMPRESSION_PORT = 18793
MODEL_PORT = 18792
MARKER = 'semreh-direct-hermes-slice2-development-v1'
COMPRESSION_MARKER = 'semreh-direct-hermes-slice2-compression-v1'
COMPRESSION_MODES = ('rotate', 'in-place')
COMPRESSION_AUX_BASE_URL = 'http://127.0.0.1:18792/v1'
COMPRESSION_AUX_API_KEY = 'semreh-compression-fixture-dummy-key'
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


def _runtime_for_mode(compression_mode=None):
    """Return the fixed runtime for ordinary, rotating, or in-place mode.

    ``None`` is the unchanged development fixture. Compression modes are
    deliberately sibling paths so validation cannot fall back across modes.
    """
    if compression_mode is None:
        return DEV_RUNTIME
    if compression_mode == 'rotate':
        return COMPRESSION_RUNTIME
    if compression_mode == 'in-place':
        return IN_PLACE_COMPRESSION_RUNTIME
    raise RuntimeError(f'Unsupported compression mode: {compression_mode}')


def _port_for_mode(compression_mode=None):
    if compression_mode is None:
        return PORT
    if compression_mode in COMPRESSION_MODES:
        return COMPRESSION_PORT
    raise RuntimeError(f'Unsupported compression mode: {compression_mode}')


def _expected_config(baseline_config, *, compression_mode=None):
    expected = copy.deepcopy(baseline_config)
    terminal = expected.get('terminal')
    if not isinstance(terminal, dict) or not isinstance(terminal.get('cwd'), str):
        raise RuntimeError('Baseline configuration has no terminal cwd')
    runtime = _runtime_for_mode(compression_mode)
    terminal['cwd'] = str(runtime / 'tools')
    if compression_mode is not None:
        compression = expected.setdefault('compression', {})
        if not isinstance(compression, dict):
            raise RuntimeError('Baseline compression configuration is not a mapping')
        compression.update({
            'in_place': compression_mode == 'in-place',
            'protect_last_n': 2,
            'min_tail_user_messages': 1,
            'target_ratio': 0.10,
        })
        auxiliary = expected.setdefault('auxiliary', {})
        if not isinstance(auxiliary, dict):
            raise RuntimeError('Baseline auxiliary configuration is not a mapping')
        auxiliary['compression'] = {
            'provider': 'custom',
            'model': 'semreh-fixture',
            'base_url': COMPRESSION_AUX_BASE_URL,
            'api_key': COMPRESSION_AUX_API_KEY,
            'timeout': 120,
            'reasoning_effort': 'none',
            'fallback_chain': [],
        }
        auxiliary['background_review'] = {'enabled': False}
    return expected


def _marker(*, compression_mode=None):
    runtime = _runtime_for_mode(compression_mode)
    marker = COMPRESSION_MARKER if compression_mode is not None else MARKER
    result = {
        'marker': marker,
        'devsource': str(DEV_SOURCE),
        'runtime': str(runtime),
        'base_pin': BASE_PIN,
        'port': _port_for_mode(compression_mode),
        'model_port': MODEL_PORT,
    }
    if compression_mode is not None:
        result['compression_mode'] = compression_mode
    return result


def _validate_runtime(baseline_config, baseline_credentials, *, compression_mode=None):
    runtime = _runtime_for_mode(compression_mode)
    _private_dir(runtime)
    for name in RUNTIME_DIRS:
        _private_dir(runtime / name)
    _private_dir(runtime / 'home' / 'home')
    for name in ('credentials.json', 'marker.json', 'home/config.yaml'):
        _private_file(runtime / name)
    _exact(runtime / 'home/state.db')
    if (runtime / 'home/.env').exists() or (runtime / 'home/.env').is_symlink():
        raise RuntimeError('Development runtime must use fixture config only, not .env')

    marker = _json_file(runtime / 'marker.json')
    if marker != _marker(compression_mode=compression_mode):
        raise RuntimeError('Development runtime marker does not match approved paths, mode and pin')
    credentials = _json_file(runtime / 'credentials.json')
    if credentials != baseline_credentials:
        raise RuntimeError('Development credentials differ from the disposable baseline')
    actual_config = _json_file(runtime / 'home' / 'config.yaml')
    if actual_config != _expected_config(baseline_config, compression_mode=compression_mode):
        raise RuntimeError('Development configuration differs from the approved fixture overlay')


def _validate_all(backend_sha, *, compression_mode=None):
    baseline_config, baseline_credentials = _validated_baseline_fixture()
    _validate_dev_source(backend_sha)
    _validate_runtime(
        baseline_config,
        baseline_credentials,
        compression_mode=compression_mode,
    )
    runtime = _runtime_for_mode(compression_mode)
    result = {
        'backend_sha': backend_sha.lower(),
        'base_pin': BASE_PIN,
        'hermes_home': str(runtime / 'home'),
        'tool_cwd': str(runtime / 'tools'),
        'port': _port_for_mode(compression_mode),
        'model_port': MODEL_PORT,
    }
    if compression_mode is not None:
        result['compression_mode'] = compression_mode
    print(json.dumps(result))
    return baseline_config, baseline_credentials


def initialize(backend_sha, *, compression_mode=None):
    baseline_config, baseline_credentials = _validated_baseline_fixture()
    _validate_dev_source(backend_sha)
    runtime = _runtime_for_mode(compression_mode)
    if runtime.exists() or runtime.is_symlink():
        raise RuntimeError('Development runtime already exists; refusing to overwrite it')
    _exact(runtime.parent)
    runtime.mkdir(mode=0o700)
    for name in RUNTIME_DIRS:
        (runtime / name).mkdir(mode=0o700)
    (runtime / 'home' / 'home').mkdir(mode=0o700)
    baseline.private_json(runtime / 'credentials.json', baseline_credentials)
    baseline.private_json(
        runtime / 'home' / 'config.yaml',
        _expected_config(baseline_config, compression_mode=compression_mode),
    )
    baseline.private_json(runtime / 'marker.json', _marker(compression_mode=compression_mode))
    _validate_all(backend_sha, compression_mode=compression_mode)


def _assert_port_free(port=PORT):
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(('127.0.0.1', port))
        except OSError as error:
            raise RuntimeError(f'Port {port} is already in use; refusing to evict a process') from error


def serve(backend_sha, *, compression_mode=None):
    _validate_all(backend_sha, compression_mode=compression_mode)
    _assert_port_free(_port_for_mode(compression_mode))
    runtime = _runtime_for_mode(compression_mode)
    port = _port_for_mode(compression_mode)
    environment = {
        'PATH': str(baseline.PYTHON.parent) + ':/usr/bin:/bin',
        'HERMES_HOME': str(runtime / 'home'),
        'TMPDIR': str(runtime / 'tmp'),
        'XDG_CACHE_HOME': str(runtime / 'cache'),
        'PYTHONPATH': str(DEV_SOURCE),
        'PYTHONUNBUFFERED': '1',
        'PYTHONDONTWRITEBYTECODE': '1',
        'HERMES_SERVE_HEADLESS': '1',
        'HERMES_TUI_TOOLSETS': 'clarify',
    }
    os.chdir(runtime / 'tools')
    os.execve(str(baseline.PYTHON), [
        str(baseline.PYTHON), '-m', 'hermes_cli.main', 'serve', '--isolated',
        '--host', '127.0.0.1', '--port', str(port),
    ], environment)


def _sha_argument(value):
    if not SHA_RE.fullmatch(value):
        raise argparse.ArgumentTypeError('must be exactly 40 hexadecimal characters')
    return value.lower()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('init', 'validate', 'serve'))
    parser.add_argument('--backend-sha', required=True, type=_sha_argument)
    parser.add_argument('--compression-mode', choices=COMPRESSION_MODES)
    args = parser.parse_args()
    try:
        {'init': initialize, 'validate': _validate_all, 'serve': serve}[args.action](
            args.backend_sha, compression_mode=args.compression_mode
        )
    except RuntimeError as error:
        parser.error(str(error))
