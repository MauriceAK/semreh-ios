#!/usr/bin/env python3
"""Launch a built TUI against one of the two approved disposable fixtures.

This is a verification launcher, not a package manager or a general Hermes
launcher.  It validates the selected approved backend checkout and runtime,
requires an already-built TUI bundle at the corresponding fixed path, then
replaces itself with Node using a deliberately small environment.  The TUI
consequently spawns its gateway from the same disposable source/runtime and
cannot inherit a personal Hermes home, proxy, gateway URL, or credentials.

Development mode takes ``--backend-sha`` and validates the exact clean
development checkout.  Stock mode takes ``--stock-backend`` and validates the
independent pinned baseline source/runtime; it never accepts a caller-selected
source, runtime, or SHA.

The process must be run from a real terminal because the TUI intentionally
exits when stdin is not a TTY.  ``--resume-stored-id`` accepts only a durable
session identifier written by the disposable gateway; it is never interpreted
as a path, URL, or shell fragment.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import os
from pathlib import Path
import re
import stat
from dataclasses import dataclass

import direct_hermes_development as development


NODE = Path('/opt/homebrew/bin/node')
DEV_BUNDLE = development.DEV_SOURCE / 'ui-tui' / 'dist' / 'entry.js'
STOCK_BUNDLE = development.baseline.SOURCE / 'ui-tui' / 'dist' / 'entry.js'
DEV_ACTIVE_SESSION_FILE = development.DEV_RUNTIME / 'home' / 'tui-active-session.json'
STOCK_ACTIVE_SESSION_FILE = development.baseline.RUNTIME / 'home' / 'tui-active-session.json'
SESSION_ID_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$')


@dataclass(frozen=True)
class _LaunchTarget:
    """All paths and the source pin for one fixed launcher mode."""

    stock: bool
    backend_sha: str
    source: Path
    runtime: Path
    bundle: Path
    active_session_file: Path


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


def _target(backend_sha: str | None, *, stock_backend: bool) -> _LaunchTarget:
    """Resolve exactly one fixed source/runtime pair; never mix their modes."""
    if stock_backend:
        if backend_sha is not None:
            raise RuntimeError('--stock-backend cannot be combined with --backend-sha')
        return _LaunchTarget(
            stock=True,
            backend_sha=development.baseline.PIN,
            source=development.baseline.SOURCE,
            runtime=development.baseline.RUNTIME,
            bundle=STOCK_BUNDLE,
            active_session_file=STOCK_ACTIVE_SESSION_FILE,
        )
    if backend_sha is None:
        raise RuntimeError('Development mode requires --backend-sha')
    if not development.SHA_RE.fullmatch(backend_sha):
        raise RuntimeError('--backend-sha must be exactly 40 hexadecimal characters')
    return _LaunchTarget(
        stock=False,
        backend_sha=backend_sha.lower(),
        source=development.DEV_SOURCE,
        runtime=development.DEV_RUNTIME,
        bundle=DEV_BUNDLE,
        active_session_file=DEV_ACTIVE_SESSION_FILE,
    )


def _validate_target(target: _LaunchTarget) -> None:
    # Both validators print informational JSON.  Keep that off the terminal:
    # the next process owns the TTY.  Stock mode must use baseline validation;
    # development mode additionally checks its exact SHA/branch/clean tree.
    with contextlib.redirect_stdout(io.StringIO()):
        if target.stock:
            development.baseline.validate()
        else:
            development._validate_all(target.backend_sha)


def _validate_bundle_and_runtime(target: _LaunchTarget) -> None:
    _regular_file(target.bundle)
    if target.bundle.stat().st_size <= 0:
        raise RuntimeError(f'TUI bundle is empty: {target.bundle}')
    _homebrew_node()
    _private_existing_file(target.active_session_file)


def _environment_for_target(
    target: _LaunchTarget, resume_stored_id: str | None
) -> dict[str, str]:
    runtime = target.runtime
    hermes_home = runtime / 'home'
    # The fixture provisions a separate nested HOME specifically so ordinary
    # ``~`` lookups cannot accidentally treat HERMES_HOME itself as a user's
    # home directory.  Keep Hermes state rooted at the profile home while all
    # generic XDG/user-file lookups stay in the disposable nested directory.
    # Both modes explicitly pin HOME here. Stock wrappers may consult
    # Path.home(), so leaving it absent would permit a personal-home fallback.
    home = hermes_home / 'home'
    tools = runtime / 'tools'

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
        'HERMES_PYTHON_SRC_ROOT': str(target.source),
        'HERMES_CWD': str(tools),
        'PYTHONPATH': str(target.source),
        'PYTHONUNBUFFERED': '1',
        'PYTHONDONTWRITEBYTECODE': '1',
        'HERMES_TUI_TOOLSETS': 'clarify',
        'HERMES_TUI_ACTIVE_SESSION_FILE': str(target.active_session_file),
        'NODE_ENV': 'production',
        'TERM': 'xterm-256color',
        'COLORTERM': 'truecolor',
        'LANG': 'C.UTF-8',
        'LC_ALL': 'C.UTF-8',
    }
    if resume_stored_id is not None:
        environment['HERMES_TUI_RESUME'] = resume_stored_id
    return environment


def launch(
    backend_sha: str | None,
    resume_stored_id: str | None,
    *,
    stock_backend: bool = False,
) -> None:
    target = _target(backend_sha, stock_backend=stock_backend)
    _validate_target(target)
    _validate_bundle_and_runtime(target)

    os.chdir(target.runtime / 'tools')
    os.execve(
        str(NODE),
        [str(NODE), '--max-old-space-size=8192', '--expose-gc', str(target.bundle)],
        _environment_for_target(target, resume_stored_id),
    )


def _sha_argument(value: str) -> str:
    if not development.SHA_RE.fullmatch(value):
        raise argparse.ArgumentTypeError('must be exactly 40 hexadecimal characters')
    return value.lower()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--backend-sha', type=_sha_argument)
    modes.add_argument(
        '--stock-backend',
        action='store_true',
        help='use the exact approved stock source/runtime and baseline pin',
    )
    parser.add_argument(
        '--resume-stored-id',
        type=_resume_id,
        help='resume one validated durable session id from the disposable runtime',
    )
    args = parser.parse_args()
    try:
        launch(args.backend_sha, args.resume_stored_id, stock_backend=args.stock_backend)
    except RuntimeError as error:
        parser.error(str(error))
