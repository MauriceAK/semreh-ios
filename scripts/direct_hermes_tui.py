#!/usr/bin/env python3
"""Launch the built Slice 2 TUI against only the disposable dev checkout.

This is a verification launcher, not a package manager or a general Hermes
launcher.  It validates the approved backend checkout and runtime, requires an
already-built TUI bundle at the expected path, then replaces itself with Node
using a deliberately small environment.  The TUI consequently spawns its
gateway from the same disposable source/runtime and cannot inherit a personal
Hermes home, proxy, gateway URL, or credentials.

The process must be run from a real terminal because the TUI intentionally
exits when stdin is not a TTY.  ``--resume-stored-id`` accepts only a durable
session identifier written by the disposable gateway; it is never interpreted
as a path, URL, or shell fragment.
"""

import argparse
import contextlib
import io
import os
from pathlib import Path
import re
import stat

import direct_hermes_development as development


NODE = Path('/opt/homebrew/bin/node')
BUNDLE = development.DEV_SOURCE / 'ui-tui' / 'dist' / 'entry.js'
ACTIVE_SESSION_FILE = development.DEV_RUNTIME / 'home' / 'tui-active-session.json'
SESSION_ID_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$')


def _exact(path: Path) -> None:
    if not path.is_absolute() or path.is_symlink() or path.resolve(strict=False) != path:
        raise RuntimeError(f'Unexpected or symlinked path: {path}')


def _regular_file(path: Path, *, executable: bool = False) -> None:
    _exact(path)
    if not path.is_file():
        raise RuntimeError(f'Expected regular file is missing: {path}')
    if executable and not os.access(path, os.X_OK):
        raise RuntimeError(f'Expected executable is not executable: {path}')


def _homebrew_node() -> None:
    # Homebrew intentionally exposes node through /opt/homebrew/bin/node as a
    # symlink.  Permit only that fixed link and keep its target inside the
    # Homebrew Node Cellar; callers cannot choose a different interpreter.
    if NODE != Path('/opt/homebrew/bin/node') or not NODE.is_symlink():
        raise RuntimeError(f'Expected Homebrew Node symlink is missing: {NODE}')
    try:
        target = NODE.resolve(strict=True)
    except OSError as error:
        raise RuntimeError(f'Could not resolve Homebrew Node: {NODE}') from error
    cellar = Path('/opt/homebrew/Cellar/node')
    if target != cellar and cellar not in target.parents:
        raise RuntimeError(f'Homebrew Node resolved outside the approved Cellar: {target}')
    if not target.is_file() or not os.access(target, os.X_OK):
        raise RuntimeError(f'Approved Homebrew Node target is not executable: {target}')


def _private_existing_file(path: Path) -> None:
    _exact(path)
    if not path.exists():
        return
    if not path.is_file() or stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise RuntimeError(f'Active-session file must be a private regular file: {path}')


def _resume_id(value: str) -> str:
    value = value.strip()
    if not SESSION_ID_RE.fullmatch(value):
        raise argparse.ArgumentTypeError(
            'must be a durable session id (ASCII letters, digits, ., _, -; 1-128 chars)'
        )
    return value


def _validate_bundle_and_runtime() -> None:
    # The development validator checks the source SHA, branch, clean tree,
    # fixture credentials/config, and every disposable runtime path.  Keep its
    # informational JSON off the terminal: the next process owns the TTY.
    _regular_file(BUNDLE)
    if BUNDLE.stat().st_size <= 0:
        raise RuntimeError(f'TUI bundle is empty: {BUNDLE}')
    _homebrew_node()
    _private_existing_file(ACTIVE_SESSION_FILE)


def _environment(resume_stored_id: str | None) -> dict[str, str]:
    runtime = development.DEV_RUNTIME
    hermes_home = runtime / 'home'
    # The fixture provisions a separate nested HOME specifically so ordinary
    # ``~`` lookups cannot accidentally treat HERMES_HOME itself as a user's
    # home directory.  Keep Hermes state rooted at the profile home while all
    # generic XDG/user-file lookups stay in the disposable nested directory.
    home = hermes_home / 'home'
    tools = runtime / 'tools'
    source = development.DEV_SOURCE

    # Start from no inherited environment.  In particular, do not preserve
    # HERMES_HOME, HOME, proxy, NODE_OPTIONS, HERMES_TUI_GATEWAY_URL, or
    # HERMES_TUI_SIDECAR_URL from the invoking shell.
    environment = {
        'PATH': f'{development.baseline.PYTHON.parent}:/opt/homebrew/bin:/usr/bin:/bin',
        'HOME': str(home),
        'HERMES_HOME': str(hermes_home),
        'TMPDIR': str(runtime / 'tmp'),
        'XDG_CACHE_HOME': str(runtime / 'cache'),
        'XDG_CONFIG_HOME': str(home),
        'XDG_DATA_HOME': str(home),
        'XDG_STATE_HOME': str(home),
        'HERMES_PYTHON': str(development.baseline.PYTHON),
        'HERMES_PYTHON_SRC_ROOT': str(source),
        'HERMES_CWD': str(tools),
        'PYTHONPATH': str(source),
        'PYTHONUNBUFFERED': '1',
        'PYTHONDONTWRITEBYTECODE': '1',
        'HERMES_TUI_TOOLSETS': 'clarify',
        'HERMES_TUI_ACTIVE_SESSION_FILE': str(ACTIVE_SESSION_FILE),
        'NODE_ENV': 'production',
        'TERM': 'xterm-256color',
        'COLORTERM': 'truecolor',
        'LANG': 'C.UTF-8',
        'LC_ALL': 'C.UTF-8',
    }
    if resume_stored_id is not None:
        environment['HERMES_TUI_RESUME'] = resume_stored_id
    return environment


def launch(backend_sha: str, resume_stored_id: str | None) -> None:
    # Validate before any child process is created.  The helper also validates
    # the independent baseline fixture used to derive the dev runtime.
    with contextlib.redirect_stdout(io.StringIO()):
        development._validate_all(backend_sha)
    _validate_bundle_and_runtime()

    os.chdir(development.DEV_RUNTIME / 'tools')
    os.execve(
        str(NODE),
        [str(NODE), '--max-old-space-size=8192', '--expose-gc', str(BUNDLE)],
        _environment(resume_stored_id),
    )


def _sha_argument(value: str) -> str:
    if not development.SHA_RE.fullmatch(value):
        raise argparse.ArgumentTypeError('must be exactly 40 hexadecimal characters')
    return value.lower()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend-sha', required=True, type=_sha_argument)
    parser.add_argument(
        '--resume-stored-id',
        type=_resume_id,
        help='resume one validated durable session id from the disposable runtime',
    )
    args = parser.parse_args()
    try:
        launch(args.backend_sha, args.resume_stored_id)
    except RuntimeError as error:
        parser.error(str(error))
