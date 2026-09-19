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
HTTPS_ORIGIN = 'https://semreh-slice1-test.tailda8427.ts.net'
BLOCKING_FIXTURE_PLUGINS = Path(__file__).resolve().parent / 'fixtures'
BLOCKING_FIXTURE_DEPLOYED = RUNTIME / 'home' / 'plugins'
BLOCKING_FIXTURE_SKILL_DEPLOYED = RUNTIME / 'home' / 'skills' / 'semreh-fixture-empty-secret'
BLOCKING_FIXTURE_TOOLSET = 'semreh_blocking_fixture'
BLOCKING_FIXTURE_PLUGIN_ID = 'semreh-blocking-fixture'
BLOCKING_FIXTURE_TOOLS_CONFIG = {'tool_search': {'enabled': 'off'}}
NAMED_FIXTURE_PROFILES = frozenset({'semreh-goal-scope-8f059a8ae784'})
COMPRESSION_FIXTURE_CONFIG = {
    'in_place': False,
    'protect_last_n': 2,
    'min_tail_user_messages': 1,
    'target_ratio': 0.10,
}
AUXILIARY_FIXTURE_CONFIG = {
    'background_review': {'enabled': False},
    'transient_retries': 0,
    'goal_judge': {
        'provider': 'custom',
        'model': 'semreh-fixture',
        'base_url': 'http://127.0.0.1:18792/v1',
        'api_key': 'no-key-required',
        'api_mode': 'chat_completions',
        'timeout': 5,
        'max_tokens': 128,
        'fallback_chain': [],
    },
    'compression': {
        'provider': 'custom',
        'model': 'semreh-fixture',
        'base_url': 'http://127.0.0.1:18792/v1',
        'api_key': 'no-key-required',
        'api_mode': 'chat_completions',
        'timeout': 120,
        'reasoning_effort': 'none',
        'fallback_chain': [],
    },
}
BLOCKING_FIXTURE_SHA256 = {
    'semreh-blocking-fixture/plugin.yaml':
        'd3b40257401e2155498486ed5bc9d947240e30a8ab38d4d1a9e63373c726d2f4',
    'semreh-blocking-fixture/__init__.py':
        '23d1fcec78b7bb1c5fec70bc4a66fe21903b3bd3c52b9798ff9ec5ab8280c31d',
    'semreh-blocking-fixture/skills/empty_secret/SKILL.md':
        'f35fac54ff7e55b9e3843d73999a48010bf961ced9b1bdda6b0075cfa451d770',
}
BLOCKING_FIXTURE_SKILL_SHA256 = 'f35fac54ff7e55b9e3843d73999a48010bf961ced9b1bdda6b0075cfa451d770'


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
        'compression': COMPRESSION_FIXTURE_CONFIG,
        'auxiliary': AUXILIARY_FIXTURE_CONFIG,
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


def _fixture_home(profile=None):
    if profile is None:
        return RUNTIME / 'home'
    if profile not in NAMED_FIXTURE_PROFILES:
        raise RuntimeError('Named fixture profile is not allowlisted')
    home = RUNTIME / 'home' / 'profiles' / profile
    if home.is_symlink() or home.resolve() != home or not home.is_dir():
        raise RuntimeError('Named fixture profile escaped or is unavailable')
    if home.stat().st_mode & 0o077:
        raise RuntimeError('Named fixture profile is accessible to other users')
    return home


def validate(*, allow_memory_adoption=False, profile=None):
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
    hermes_home = _fixture_home(profile)
    config_path = hermes_home / 'config.yaml'
    if (config_path.is_symlink() or config_path.resolve() != config_path
            or not config_path.is_file() or config_path.stat().st_mode & 0o077):
        raise RuntimeError('Unexpected named fixture configuration')
    config = json.loads(config_path.read_text())
    expected = {
        'model': {'provider': 'custom', 'default': 'semreh-fixture', 'base_url': 'http://127.0.0.1:18792/v1'},
        'terminal': {'backend': 'local', 'cwd': str(RUNTIME / 'tools'), 'home_mode': 'profile'},
        'memory': {'memory_enabled': allow_memory_adoption,
                   'user_profile_enabled': False, 'provider': ''},
        'compression': COMPRESSION_FIXTURE_CONFIG,
        'auxiliary': AUXILIARY_FIXTURE_CONFIG,
        'curator': {'enabled': False}, 'mcp_servers': {}, 'platforms': {},
        'kanban': {'dispatch_in_gateway': False, 'review_dispatch': False},
        'security': {'allow_lazy_installs': False}, 'cron': {'allow_agent_scheduling': False},
        'toolsets': [], 'platform_toolsets': {'cli': [], 'tui': []},
    }
    if any(config.get(key) != value for key, value in expected.items()):
        raise RuntimeError('Disposable runtime configuration drifted; refusing launch')
    dashboard = config.get('dashboard', {})
    basic = dashboard.get('basic_auth', {})
    if (dashboard.get('public_url') not in ('http://semreh-slice1.test:18791', HTTPS_ORIGIN)
            or basic.get('username') != 'semreh-test'
            or not basic.get('password_hash', '').startswith('scrypt$')
            or len(basic.get('secret', '')) < 32):
        raise RuntimeError('Disposable authentication configuration drifted')
    if dashboard['public_url'] == HTTPS_ORIGIN:
        endpoint = RUNTIME / 'tailscale-proxy/endpoint.json'
        if endpoint.is_symlink() or endpoint.resolve() != endpoint:
            raise RuntimeError('Unexpected HTTPS endpoint path')
        if json.loads(endpoint.read_text()) != {'origin': HTTPS_ORIGIN, 'upstream': 'http://127.0.0.1:18791'}:
            raise RuntimeError('HTTPS endpoint does not match the enrolled test node')
    print(json.dumps({'source_sha': PIN, 'hermes_home': str(hermes_home),
                      'tool_cwd': str(RUNTIME / 'tools'), 'port': PORT,
                      'os_isolation': False, 'personal_credentials_inherited': False}))


def _validate_fixture_tree(root: Path, *, label: str) -> None:
    if root.is_symlink() or root.resolve() != root or not root.is_dir():
        raise RuntimeError(f'{label} fixture root is unavailable or escaped')
    expected = {
        'semreh-blocking-fixture',
        'semreh-blocking-fixture/plugin.yaml',
        'semreh-blocking-fixture/__init__.py',
        'semreh-blocking-fixture/skills',
        'semreh-blocking-fixture/skills/empty_secret',
        'semreh-blocking-fixture/skills/empty_secret/SKILL.md',
    }
    actual = {str(path.relative_to(root)) for path in root.rglob('*')}
    if actual != expected:
        raise RuntimeError(f'{label} fixture tree contains unexpected files')
    for path in root.rglob('*'):
        if path.is_symlink() or path.resolve() != path:
            raise RuntimeError(f'{label} fixture tree contains an escaped path')
    for relative, expected_sha in BLOCKING_FIXTURE_SHA256.items():
        path = root / relative
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected_sha:
            raise RuntimeError(f'{label} fixture content digest mismatch')


def _validate_runtime_plugins(*, approval_secret_fixture: bool, hermes_home=None) -> None:
    plugins_root = (hermes_home or RUNTIME / 'home') / 'plugins'
    if not plugins_root.exists():
        if approval_secret_fixture:
            raise RuntimeError('Opt-in blocking fixture is not installed in disposable runtime')
        return
    if approval_secret_fixture:
        _validate_fixture_tree(plugins_root, label='Deployed')
    elif plugins_root.is_symlink() or plugins_root.resolve() != plugins_root:
        raise RuntimeError('Unexpected disposable runtime plugin path')
    elif any(plugins_root.iterdir()):
        raise RuntimeError('Default disposable runtime must not contain plugins')


def _validate_runtime_skill(*, approval_secret_fixture: bool, hermes_home=None) -> None:
    fixture_root = (hermes_home or RUNTIME / 'home') / 'skills' / 'semreh-fixture-empty-secret'
    skills_root = fixture_root.parent
    if not skills_root.exists():
        if approval_secret_fixture:
            raise RuntimeError('Opt-in blocking skill is not installed in disposable runtime')
        return
    if skills_root.is_symlink() or skills_root.resolve() != skills_root or not skills_root.is_dir():
        raise RuntimeError('Unexpected disposable runtime skills path')
    if approval_secret_fixture:
        if fixture_root.is_symlink() or fixture_root.resolve() != fixture_root or not fixture_root.is_dir():
            raise RuntimeError('Opt-in blocking skill is unavailable or escaped')
        actual = {str(path.relative_to(fixture_root)) for path in fixture_root.rglob('*')}
        if actual != {'SKILL.md'}:
            raise RuntimeError('Opt-in blocking skill contains unexpected files')
        skill = fixture_root / 'SKILL.md'
        if (not skill.is_file()
                or hashlib.sha256(skill.read_bytes()).hexdigest() != BLOCKING_FIXTURE_SKILL_SHA256):
            raise RuntimeError('Deployed skill content digest mismatch')
    elif fixture_root.exists():
        raise RuntimeError('Default disposable runtime must not contain blocking fixture skill')


def _validate_plugin_config(*, approval_secret_fixture: bool, hermes_home=None) -> None:
    config_path = (hermes_home or RUNTIME / 'home') / 'config.yaml'
    if config_path.is_symlink() or config_path.resolve() != config_path:
        raise RuntimeError('Unexpected disposable config path')
    config = json.loads(config_path.read_text())
    plugins = config.get('plugins')
    if plugins is None:
        if approval_secret_fixture:
            raise RuntimeError('Opt-in blocking fixture is not enabled in disposable config')
        return
    if not isinstance(plugins, dict):
        raise RuntimeError('Disposable plugin config is not an object')
    enabled = plugins.get('enabled', [])
    if not isinstance(enabled, list):
        raise RuntimeError('Disposable plugin allowlist is not a list')
    if approval_secret_fixture:
        if plugins != {'enabled': [BLOCKING_FIXTURE_PLUGIN_ID]}:
            raise RuntimeError('Disposable config enables an unexpected plugin')
        if config.get('tools') != BLOCKING_FIXTURE_TOOLS_CONFIG:
            raise RuntimeError('Opt-in disposable config must disable tool_search')
    elif enabled:
        raise RuntimeError('Default disposable config must not enable plugins')


def serve(*, with_pdf_renderer=False, approval_secret_fixture=False, profile=None):
    validate(profile=profile)
    hermes_home = _fixture_home(profile)
    _validate_plugin_config(approval_secret_fixture=approval_secret_fixture,
                            hermes_home=hermes_home)
    _validate_runtime_skill(approval_secret_fixture=approval_secret_fixture,
                            hermes_home=hermes_home)
    with socket.socket() as probe:
        # Match the HTTP server's reuse behavior so a just-stopped test server's
        # TIME_WAIT sockets do not prevent restart. A live listener still fails.
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(('127.0.0.1', PORT))  # Fail on conflict; never evict a listener.
    # Deliberate allowlist: no inherited provider credentials, Desktop marker,
    # profile selection, SSH agent, or shell initialization environment.
    environment = {
        'PATH': str(PYTHON.parent) + ':/usr/bin:/bin',
        'HOME': str(RUNTIME / 'home' / 'home'),
        'HERMES_HOME': str(hermes_home),
        'TMPDIR': str(RUNTIME / 'tmp'),
        'XDG_CACHE_HOME': str(RUNTIME / 'cache'),
        'PYTHONPATH': str(SOURCE), 'PYTHONUNBUFFERED': '1',
        'PYTHONDONTWRITEBYTECODE': '1',
        'HERMES_SERVE_HEADLESS': '1',
        # Explicit valid toolset avoids the gateway's empty-list fallback to
        # platform defaults. Clarification has no terminal/file execution.
        'HERMES_TUI_TOOLSETS': 'clarify',
    }
    if approval_secret_fixture:
        _validate_fixture_tree(BLOCKING_FIXTURE_PLUGINS, label='Repository')
    _validate_runtime_plugins(approval_secret_fixture=approval_secret_fixture,
                              hermes_home=hermes_home)
    if approval_secret_fixture:
        # The fixture is installed under this disposable profile only; stock
        # bundled plugins (including dashboard auth) remain visible.
        environment['HERMES_TUI_TOOLSETS'] = ','.join(
            ('clarify', BLOCKING_FIXTURE_TOOLSET)
        )
    if with_pdf_renderer:
        # Explicitly approved test dependency, not the whole Homebrew PATH.
        # Keep the default fixture launcher unchanged when PDF tests are off.
        renderer_bin = Path('/opt/homebrew/opt/poppler/bin')
        if not (renderer_bin / 'pdftoppm').is_file() or not os.access(renderer_bin / 'pdftoppm', os.X_OK):
            raise RuntimeError('Approved PDF renderer is unavailable')
        environment['PATH'] += ':' + str(renderer_bin)
    os.chdir(RUNTIME / 'tools')
    # Use the complete first-party serve startup: it bridges terminal settings
    # and discovers the basic-auth plugin before start_server. Explicit custom
    # HERMES_HOME roots profile lookup here; --isolated prevents server rerouting.
    argv = [str(PYTHON), '-m', 'hermes_cli.main']
    if profile is not None:
        # Belt-and-suspenders with HERMES_HOME: the pinned stock parser resolves
        # this against the custom root, then strips -p before normal argparse.
        argv.extend(['-p', profile])
    argv.extend(['serve', '--isolated', '--host', '127.0.0.1', '--port', str(PORT)])
    os.execve(str(PYTHON), argv, environment)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['init', 'validate', 'serve'])
    parser.add_argument('--with-pdf-renderer', action='store_true',
                        help='Expose the approved Poppler renderer to this disposable gateway only')
    parser.add_argument('--approval-secret-fixture', action='store_true',
                        help='Explicitly enable the repository-owned no-op approval/empty-secret fixture')
    parser.add_argument('--profile', choices=sorted(NAMED_FIXTURE_PROFILES),
                        help='Opt in to the allowlisted owned nondefault fixture profile')
    args = parser.parse_args()
    if args.profile and args.action == 'init':
        parser.error('--profile is only valid with validate or serve')
    if (args.with_pdf_renderer or args.approval_secret_fixture) and args.action != 'serve':
        parser.error('fixture serve flags are only valid with serve')
    if args.action == 'serve':
        serve(with_pdf_renderer=args.with_pdf_renderer,
              approval_secret_fixture=args.approval_secret_fixture,
              profile=args.profile)
    else:
        if args.action == 'validate':
            validate(profile=args.profile)
        else:
            initialize()
