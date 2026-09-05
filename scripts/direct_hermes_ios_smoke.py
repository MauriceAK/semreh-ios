#!/usr/bin/env python3
"""Generate a local opt-in XCTest run file, containing no credential values.

First build-for-testing with signing on the disposable Slice 1 simulator.
Then run the emitted xctestrun with test-without-building on that same device.
Use --https for the enrolled test route. Cookie phases must be run separately
in distinct hosted app processes; no production auth UI cutover is implied.
"""
from pathlib import Path
import argparse
import plistlib
from direct_hermes_probe import validate, RUNTIME

PRODUCTS = Path('/Users/maurice/workspace/semreh-slice1-build/Build/Products')
OUTPUT = PRODUCTS / 'SemrehSlice1Live.xctestrun'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--https', action='store_true')
    parser.add_argument('--slice2-foundation', action='store_true')
    parser.add_argument('--slice2-native', action='store_true')
    parser.add_argument('--cookie-phase', choices=['login', 'restore', 'logout'])
    args = parser.parse_args()
    if args.cookie_phase and not args.https:
        parser.error('Cookie phases require --https')
    if args.slice2_foundation and (not args.https or args.cookie_phase):
        parser.error('Slice 2 foundation requires --https and no cookie phase')
    if args.slice2_native and (not args.https or args.cookie_phase or args.slice2_foundation):
        parser.error('Slice 2 native requires --https and no other test phase')
    validate()
    if PRODUCTS.resolve() != PRODUCTS or OUTPUT.is_symlink():
        raise RuntimeError('Unexpected XCTest artifact path')
    # Xcode varies the runtime/architecture suffix (e.g. arm64 vs arm64-x86_64).
    # Select the latest build's original plan, never our generated live plan.
    candidates = list(PRODUCTS.glob('HermesMobile_HermesMobile_iphonesimulator*.xctestrun'))
    if not candidates or any(p.is_symlink() or not p.is_file() for p in candidates):
        raise RuntimeError('Missing or unexpected built XCTest run file')
    source = max(candidates, key=lambda p: p.stat().st_mtime_ns)
    plan = plistlib.loads(source.read_bytes())
    targets = [target for config in plan['TestConfigurations']
               for target in config['TestTargets']]
    if len(targets) != 1 or targets[0].get('BlueprintName') != 'HermesMobileTests':
        raise RuntimeError('Unexpected XCTest target layout')
    target = targets[0]
    target.setdefault('EnvironmentVariables', {}).update({
        'SEMREH_SLICE1_LIVE': '1',
        'SEMREH_SLICE1_CREDENTIALS_FILE': str(RUNTIME / 'credentials.json'),
    })
    if args.https:
        target['EnvironmentVariables']['SEMREH_SLICE1_HTTPS'] = '1'
    method = 'testOptInHostedSlice1AuthGatewayAndDurability'
    if args.slice2_foundation:
        method = 'testOptInHostedSlice2ConversationFoundation'
    if args.slice2_native:
        method = 'testOptInHostedSlice2NativeChatFlow'
    if args.cookie_phase:
        target['EnvironmentVariables']['SEMREH_SLICE1_COOKIE_PHASE'] = args.cookie_phase
        method = 'testOptInHostedCookie' + args.cookie_phase.title() + 'Phase'
        if args.cookie_phase != 'login':
            del target['EnvironmentVariables']['SEMREH_SLICE1_CREDENTIALS_FILE']
    target['OnlyTestIdentifiers'] = ['DirectHermesLiveSmokeTests/' + method]
    # Generated build artifact only; no project/scheme or personal configuration changes.
    OUTPUT.write_bytes(plistlib.dumps(plan))
    print('Built test plan: ' + str(source))
    print(OUTPUT)


if __name__ == '__main__':
    main()
