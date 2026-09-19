#!/usr/bin/env python3
"""Scan only disposable Slice 1 artifacts; report paths, never matching secrets.

This detects known test secrets and obvious bearer formats. It is not a proof
that arbitrary opaque secrets cannot occur. Runtime credentials/config/database
are intentionally private operational state, not shareable verification artifacts.
"""
import argparse
import json
from pathlib import Path
import re
from direct_hermes_probe import RUNTIME, validate

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = Path('/Users/maurice/workspace/semreh-slice1-evidence')


def selected_evidence_paths(values):
    """Validate explicit targets before any scan; never resolve through links."""
    selected = []
    for value in values:
        path = Path(value)
        if not path.is_absolute() or '..' in path.parts or path == EVIDENCE:
            raise ValueError('evidence targets must be exact absolute descendants of EVIDENCE')
        if not path.is_relative_to(EVIDENCE):
            raise ValueError('evidence target escapes EVIDENCE')
        if any(part.is_symlink() for part in (path, *path.parents)):
            raise ValueError('evidence target or ancestor is a symlink')
        if not path.exists() or not (path.is_file() or path.is_dir()):
            raise ValueError('evidence target must be an existing file or directory')
        if path not in selected:
            selected.append(path)
    return selected


def artifact_files(runtimes, selected):
    # These mandatory scopes are included even in targeted-evidence mode.
    files = list((ROOT / 'docs/migration').rglob('*'))
    for runtime in runtimes:
        files += list((runtime / 'home/logs').rglob('*'))
        files += list((runtime / 'logs').rglob('*'))
    if selected:
        for path in selected:
            files.append(path)
            if path.is_dir():
                files += list(path.rglob('*'))
    else:
        files += list(EVIDENCE.rglob('*'))
    return list(dict.fromkeys(files))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--development-backend-sha')
    parser.add_argument('--compression-mode', action='append', choices=('in-place', 'rotate'), default=[])
    parser.add_argument('--evidence-path', action='append', default=[],
                        help='Audit only this absolute evidence descendant (repeatable); docs/runtime logs always scanned')
    args = parser.parse_args()
    try:
        selected = selected_evidence_paths(args.evidence_path)
    except ValueError as exc:
        parser.error(str(exc))
    if args.compression_mode and not args.development_backend_sha:
        parser.error('--compression-mode requires --development-backend-sha')
    validate()
    runtimes = [RUNTIME]
    if args.development_backend_sha:
        from direct_hermes_development import _validate_all, DEV_RUNTIME
        _validate_all(args.development_backend_sha)
        runtimes.append(DEV_RUNTIME)
        from direct_hermes_development import _runtime_for_mode
        for mode in args.compression_mode:
            _validate_all(args.development_backend_sha, compression_mode=mode)
            runtimes.append(_runtime_for_mode(mode))
    credentials = json.loads((RUNTIME / 'credentials.json').read_text())
    config = json.loads((RUNTIME / 'home/config.yaml').read_text())
    known = [credentials['password'], config['dashboard']['basic_auth']['secret'],
             config['dashboard']['basic_auth']['password_hash']]
    patterns = [re.compile(rb'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
                re.compile(rb'[?&]ticket=[A-Za-z0-9_-]{20,}')]
    files = artifact_files(runtimes, selected)
    checked, failures = 0, []
    for path in files:
        if path.is_symlink():
            failures.append(str(path))
            continue
        if not path.is_file():
            continue
        data = path.read_bytes()
        checked += 1
        if any(value.encode() in data for value in known) or any(p.search(data) for p in patterns):
            failures.append(str(path))
    # XCTest console output must first be exported using xcresulttool export
    # diagnostics; get log --type console is unavailable for these test bundles.
    console_scanned = [str(path.relative_to(EVIDENCE)) for path in files
                       if path.name == 'StandardOutputAndStandardError.txt' and path.is_relative_to(EVIDENCE)]
    print(json.dumps({'files_scanned': checked, 'flagged_paths': failures,
                      'audit_mode': 'targeted-evidence' if selected else 'full-evidence',
                      'selected_evidence_paths': [str(path) for path in selected],
                      'mandatory_scopes': ['docs/migration', 'validated runtime home/logs and logs'],
                      'exclusions': ['runtime credentials/config/database are private operational state',
                                     'unselected evidence is not scanned in targeted-evidence mode',
                                     'container bytes do not establish coverage of unexported/compressed contents'],
                      'exported_console_logs': console_scanned,
                      'scope': 'known test secrets and obvious bearer formats; not arbitrary opaque secrets'}))
    if failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
