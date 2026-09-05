#!/usr/bin/env python3
"""Generate a local opt-in XCTest run file, containing no credential values.

First build-for-testing with signing on the disposable Slice 1 simulator.
Then run the emitted xctestrun with test-without-building on that same device.
Use -collect-test-diagnostics never for live UI runs: simulator OS diagnostics
can retain pasted disposable credentials even when XCTest logs do not.
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
    parser.add_argument('--slice2-reasoning', action='store_true')
    parser.add_argument('--slice2-ui', action='store_true')
    parser.add_argument('--development-backend-sha')
    parser.add_argument('--cookie-phase', choices=['login', 'restore', 'logout'])
    args = parser.parse_args()
    if args.cookie_phase and not args.https:
        parser.error('Cookie phases require --https')
    if args.slice2_foundation and (not args.https or args.cookie_phase):
        parser.error('Slice 2 foundation requires --https and no cookie phase')
    if args.slice2_native and (not args.https or args.cookie_phase or args.slice2_foundation):
        parser.error('Slice 2 native requires --https and no other test phase')
    if args.slice2_reasoning and (
        not args.https or args.cookie_phase or args.slice2_foundation or args.slice2_native
    ):
        parser.error('Slice 2 reasoning requires --https and no other test phase')
    if args.slice2_ui and (
        not args.https or args.cookie_phase or args.slice2_foundation or args.slice2_native or args.slice2_reasoning
    ):
        parser.error('Slice 2 UI requires --https and no other test phase')
    development = args.slice2_reasoning or args.slice2_ui
    if development and not args.development_backend_sha:
        parser.error('Development smoke requires --development-backend-sha')
    if args.development_backend_sha and not development:
        parser.error('--development-backend-sha requires --slice2-reasoning or --slice2-ui')
    runtime = RUNTIME
    if development:
        from direct_hermes_development import DEV_RUNTIME, _validate_all

        _validate_all(args.development_backend_sha)
        runtime = DEV_RUNTIME
    else:
        validate()
    output = PRODUCTS / 'SemrehSlice2LiveUI.xctestrun' if args.slice2_ui else OUTPUT
    if PRODUCTS.resolve() != PRODUCTS or output.is_symlink():
        raise RuntimeError('Unexpected XCTest artifact path')
    # Xcode varies the runtime/architecture suffix (e.g. arm64 vs arm64-x86_64).
    # Select the latest build's original plan, never our generated live plan.
    scheme = 'HermesMobileUIVerification' if args.slice2_ui else 'HermesMobile'
    candidates = list(PRODUCTS.glob(f'{scheme}_{scheme}_iphonesimulator*.xctestrun'))
    if not candidates or any(p.is_symlink() or not p.is_file() for p in candidates):
        raise RuntimeError('Missing or unexpected built XCTest run file')
    source = max(candidates, key=lambda p: p.stat().st_mtime_ns)
    plan = plistlib.loads(source.read_bytes())
    targets = [target for config in plan['TestConfigurations']
               for target in config['TestTargets']]
    blueprint = 'HermesMobileUITests' if args.slice2_ui else 'HermesMobileTests'
    if len(targets) != 1 or targets[0].get('BlueprintName') != blueprint:
        raise RuntimeError('Unexpected XCTest target layout')
    target = targets[0]
    target.setdefault('EnvironmentVariables', {}).update({
        'SEMREH_SLICE1_LIVE': '1',
        'SEMREH_SLICE1_CREDENTIALS_FILE': str(runtime / 'credentials.json'),
    })
    if args.https:
        target['EnvironmentVariables']['SEMREH_SLICE1_HTTPS'] = '1'
    method = 'testOptInHostedSlice1AuthGatewayAndDurability'
    if args.slice2_foundation:
        method = 'testOptInHostedSlice2ConversationFoundation'
    if args.slice2_native:
        method = 'testOptInHostedSlice2NativeChatFlow'
    if args.slice2_reasoning:
        environment = target['EnvironmentVariables']
        environment.update({
            'SEMREH_SLICE2_REASONING': '1',
            'SEMREH_SLICE2_DEVELOPMENT_BACKEND_SHA': args.development_backend_sha.lower(),
            'SEMREH_SLICE2_TOOL_CWD': str(runtime / 'tools'),
        })
        method = 'testOptInHostedSlice2NativeReasoning'
    if args.cookie_phase:
        target['EnvironmentVariables']['SEMREH_SLICE1_COOKIE_PHASE'] = args.cookie_phase
        method = 'testOptInHostedCookie' + args.cookie_phase.title() + 'Phase'
        if args.cookie_phase != 'login':
            del target['EnvironmentVariables']['SEMREH_SLICE1_CREDENTIALS_FILE']
    test_class = 'DirectHermesLiveSmokeTests'
    if args.slice2_ui:
        target['EnvironmentVariables']['SEMREH_SLICE2_UI_LIVE'] = '1'
        method = 'testOptInLiveProductionLoginNewChatSend'
        test_class = 'LongChatScrollUITests'
    target['OnlyTestIdentifiers'] = [test_class + '/' + method]
    # Generated build artifact only; no project/scheme or personal configuration changes.
    output.write_bytes(plistlib.dumps(plan))
    print('Built test plan: ' + str(source))
    print(output)


if __name__ == '__main__':
    main()
