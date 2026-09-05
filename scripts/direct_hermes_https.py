#!/usr/bin/env python3
"""Run the test-only tsnet HTTPS proxy without personal Tailscale credentials.

Build tools/directhermesproxy first. First run prints a browser enrollment link;
the human must approve this separate node. No personal Tailscale CLI is invoked.
"""
import os
from pathlib import Path
from direct_hermes_probe import RUNTIME, validate

BINARY = Path('/Users/maurice/workspace/semreh-slice1-tools/bin/direct-hermes-https')

if __name__ == '__main__':
    validate()
    if not BINARY.is_file() or BINARY.is_symlink():
        raise RuntimeError('Build the dedicated HTTPS test binary first')
    os.umask(0o077)
    os.chdir(RUNTIME)
    os.execve(str(BINARY), [str(BINARY)], {
        'PATH': '/usr/bin:/bin',
        'TMPDIR': str(RUNTIME / 'tmp'),
        'TS_NO_LOGS_NO_SUPPORT': 'true',
    })
