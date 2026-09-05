#!/usr/bin/env python3
"""Scan only disposable Slice 1 artifacts; report paths, never matching secrets.

This detects known test secrets and obvious bearer formats. It is not a proof
that arbitrary opaque secrets cannot occur. Runtime credentials/config/database
are intentionally private operational state, not shareable verification artifacts.
"""
import json
from pathlib import Path
import re
from direct_hermes_probe import RUNTIME, validate

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = Path('/Users/maurice/workspace/semreh-slice1-evidence')


def main():
    validate()
    credentials = json.loads((RUNTIME / 'credentials.json').read_text())
    config = json.loads((RUNTIME / 'home/config.yaml').read_text())
    known = [credentials['password'], config['dashboard']['basic_auth']['secret'],
             config['dashboard']['basic_auth']['password_hash']]
    patterns = [re.compile(rb'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
                re.compile(rb'[?&]ticket=[A-Za-z0-9_-]{20,}')]
    files = list((ROOT / 'docs/migration').rglob('*'))
    files += list((RUNTIME / 'home/logs').rglob('*'))
    files += list((RUNTIME / 'logs').rglob('*'))
    files += list(EVIDENCE.rglob('*'))
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
                       if path.name == 'StandardOutputAndStandardError.txt']
    print(json.dumps({'files_scanned': checked, 'flagged_paths': failures,
                      'exported_console_logs': console_scanned,
                      'scope': 'known test secrets and obvious bearer formats; not arbitrary opaque secrets'}))
    if failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
