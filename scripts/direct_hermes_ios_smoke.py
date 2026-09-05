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
SOURCE = PRODUCTS / 'HermesMobile_HermesMobile_iphonesimulator26.5-arm64-x86_64.xctestrun'
OUTPUT = PRODUCTS / 'SemrehSlice1Live.xctestrun'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--https', action='store_true')
    parser.add_argument('--cookie-phase', choices=['login', 'restore', 'logout'])
    args = parser.parse_args()
    if args.cookie_phase and not args.https:
        parser.error('Cookie phases require --https')
    validate()
    if PRODUCTS.resolve() != PRODUCTS or SOURCE.is_symlink() or OUTPUT.is_symlink():
        raise RuntimeError('Unexpected XCTest artifact path')
    plan = plistlib.loads(SOURCE.read_bytes())
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
    if args.cookie_phase:
        target['EnvironmentVariables']['SEMREH_SLICE1_COOKIE_PHASE'] = args.cookie_phase
        method = 'testOptInHostedCookie' + args.cookie_phase.title() + 'Phase'
        if args.cookie_phase != 'login':
            del target['EnvironmentVariables']['SEMREH_SLICE1_CREDENTIALS_FILE']
    target['OnlyTestIdentifiers'] = ['DirectHermesLiveSmokeTests/' + method]
    # Generated build artifact only; no project/scheme or personal configuration changes.
    OUTPUT.write_bytes(plistlib.dumps(plan))
    print(OUTPUT)


if __name__ == '__main__':
    main()
