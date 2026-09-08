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
import re
from direct_hermes_probe import validate, RUNTIME, PIN

PRODUCTS = Path('/Users/maurice/workspace/semreh-slice1-build/Build/Products')
OUTPUT = PRODUCTS / 'SemrehSlice1Live.xctestrun'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--https', action='store_true')
    parser.add_argument('--slice2-foundation', action='store_true')
    parser.add_argument('--slice2-native', action='store_true')
    parser.add_argument('--slice2-reasoning', action='store_true')
    parser.add_argument('--slice2-ui', action='store_true')
    parser.add_argument('--slice3-clarification', action='store_true')
    parser.add_argument('--slice3-attachment', action='store_true')
    parser.add_argument('--slice3-blocking', action='store_true')
    parser.add_argument('--slice3-file-picker', action='store_true')
    parser.add_argument('--slice3-recovery', action='store_true')
    parser.add_argument('--slice3-completed-away', action='store_true')
    parser.add_argument('--slice3-relaunch', action='store_true')
    parser.add_argument('--slice3-app-kill', action='store_true')
    parser.add_argument('--slice3-gateway-restart', action='store_true')
    parser.add_argument('--slice3-active-socket-loss', action='store_true')
    parser.add_argument('--slice3-pre-ack-loss', action='store_true')
    parser.add_argument('--slice3-uncertainty', action='store_true')
    parser.add_argument('--slice4-session-metadata', action='store_true')
    parser.add_argument('--slice4-branch', action='store_true')
    parser.add_argument('--slice4-branch-ui', action='store_true')
    parser.add_argument('--gateway-restart-nonce')
    parser.add_argument('--tui-created-session-id')
    parser.add_argument('--slice3-relaunch-seed-text')
    parser.add_argument('--development-backend-sha')
    parser.add_argument('--stock-backend', action='store_true')
    parser.add_argument('--cookie-phase', choices=['login', 'restore', 'logout'])
    args = parser.parse_args()
    if args.slice4_branch_ui and (
        not args.slice2_ui or not args.https or not args.stock_backend
        or args.development_backend_sha or args.cookie_phase
        or args.gateway_restart_nonce or args.tui_created_session_id
        or args.slice3_relaunch_seed_text or args.slice4_session_metadata
        or args.slice4_branch or args.slice2_foundation or args.slice2_native
        or args.slice2_reasoning
        or any(value for name, value in vars(args).items() if name.startswith('slice3_'))
    ):
        parser.error('--slice4-branch-ui requires --slice2-ui --https --stock-backend and no other test phase')
    if args.slice4_branch and (
        not args.https or not args.stock_backend or args.development_backend_sha
        or args.cookie_phase or args.gateway_restart_nonce or args.tui_created_session_id
        or args.slice3_relaunch_seed_text or args.slice4_session_metadata
        or any(value for name, value in vars(args).items()
               if name.startswith(('slice2_', 'slice3_')))
    ):
        parser.error('--slice4-branch requires --https --stock-backend and no other test phase')
    if args.slice4_session_metadata and (
        not args.https or not args.stock_backend or args.development_backend_sha
        or args.cookie_phase or args.gateway_restart_nonce or args.tui_created_session_id
        or args.slice3_relaunch_seed_text
        or any(value for name, value in vars(args).items()
               if name.startswith(('slice2_', 'slice3_')))
    ):
        parser.error('--slice4-session-metadata requires --https --stock-backend and no other test phase')
    if args.slice3_pre_ack_loss and (
        not args.https or not args.stock_backend or args.development_backend_sha
        or args.cookie_phase or args.slice2_foundation or args.slice2_native
        or args.slice2_reasoning or args.slice2_ui or args.slice3_clarification
        or args.slice3_attachment or args.slice3_blocking or args.slice3_file_picker
        or args.slice3_recovery or args.slice3_completed_away or args.slice3_relaunch
        or args.slice3_app_kill or args.slice3_gateway_restart or args.slice3_active_socket_loss
        or args.gateway_restart_nonce or args.tui_created_session_id or args.slice3_relaunch_seed_text
    ):
        parser.error('--slice3-pre-ack-loss requires --https --stock-backend and no other test phase')
    if args.slice3_active_socket_loss and (
        not args.https or not args.stock_backend or args.development_backend_sha
        or args.cookie_phase or args.slice2_foundation or args.slice2_native
        or args.slice2_reasoning or args.slice2_ui or args.slice3_clarification
        or args.slice3_attachment or args.slice3_blocking or args.slice3_file_picker
        or args.slice3_recovery or args.slice3_completed_away or args.slice3_relaunch or args.slice3_app_kill
        or args.slice3_gateway_restart or args.gateway_restart_nonce
        or args.tui_created_session_id or args.slice3_relaunch_seed_text
    ):
        parser.error('--slice3-active-socket-loss requires --https --stock-backend and no other test phase')
    uncertainty_other_phase = (
        args.slice2_foundation or args.slice2_native or args.slice2_reasoning
        or args.slice3_clarification or args.slice3_attachment or args.slice3_blocking
        or args.slice3_file_picker or args.slice3_recovery or args.slice3_completed_away
        or args.slice3_relaunch or args.slice3_app_kill or args.slice3_gateway_restart
        or args.slice3_active_socket_loss or args.slice3_pre_ack_loss
        or args.cookie_phase or args.gateway_restart_nonce or args.development_backend_sha
    )
    if args.slice3_uncertainty and (
        uncertainty_other_phase or not args.slice2_ui or not args.https
        or not args.stock_backend or not args.tui_created_session_id
        or not args.slice3_relaunch_seed_text
    ):
        parser.error(
            '--slice3-uncertainty requires --slice2-ui --https --stock-backend '
            '--tui-created-session-id --slice3-relaunch-seed-text and no other test phase'
        )
    if args.slice3_uncertainty and not re.fullmatch(
        r'SEMREH_SLICE3_PRE_ACK_SEED_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}',
        args.slice3_relaunch_seed_text or ''
    ):
        parser.error('--slice3-uncertainty requires a SEMREH_SLICE3_PRE_ACK_SEED_<UUID> marker')
    if args.tui_created_session_id and (
        not args.slice2_ui or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', args.tui_created_session_id)
    ):
        parser.error('--tui-created-session-id requires --slice2-ui and a plain durable session ID')
    if args.slice3_relaunch_seed_text and (
        not (args.slice3_relaunch or args.slice3_app_kill or args.slice3_uncertainty)
        or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}', args.slice3_relaunch_seed_text)
    ):
        parser.error('--slice3-relaunch-seed-text requires --slice3-relaunch, --slice3-app-kill, or --slice3-uncertainty and a bounded synthetic marker')
    if args.gateway_restart_nonce and (
        not args.slice3_gateway_restart
        or not re.fullmatch(r'[A-Za-z0-9_-]{16,128}', args.gateway_restart_nonce)
    ):
        parser.error('--gateway-restart-nonce requires --slice3-gateway-restart and 16-128 safe characters')
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
    if args.slice3_clarification and (
        not args.slice2_ui or not args.https or args.cookie_phase
        or not args.stock_backend or args.development_backend_sha
    ):
        parser.error('--slice3-clarification requires --slice2-ui --https --stock-backend')
    if args.slice3_attachment and (
        not args.slice2_ui or not args.https or args.cookie_phase
        or not args.stock_backend or args.development_backend_sha
    ):
        parser.error('--slice3-attachment requires --slice2-ui --https --stock-backend')
    if args.slice3_blocking and (
        not args.slice2_ui or not args.https or args.cookie_phase
        or not args.stock_backend or args.development_backend_sha
    ):
        parser.error('--slice3-blocking requires --slice2-ui --https --stock-backend')
    if sum(bool(flag) for flag in (
        args.slice3_clarification, args.slice3_attachment, args.slice3_blocking
    )) > 1:
        parser.error('--slice3-clarification, --slice3-attachment, and --slice3-blocking are mutually exclusive')
    if args.slice3_file_picker and (
        not args.slice2_ui or not args.https or args.cookie_phase
        or not args.stock_backend or args.development_backend_sha
        or args.slice2_foundation or args.slice2_native or args.slice2_reasoning
        or args.slice3_clarification or args.slice3_attachment or args.slice3_blocking
        or args.slice3_recovery or args.slice3_completed_away or args.slice3_relaunch
        or args.slice3_gateway_restart or args.tui_created_session_id
    ):
        parser.error('--slice3-file-picker requires --slice2-ui --https --stock-backend and no other test phase')
    if args.slice3_recovery and (
        not args.https or args.cookie_phase or not args.stock_backend
        or args.development_backend_sha or args.slice2_foundation
        or args.slice2_native or args.slice2_reasoning or args.slice2_ui
        or args.slice3_clarification or args.slice3_attachment or args.slice3_blocking
        or args.slice3_file_picker or args.slice3_completed_away or args.slice3_relaunch
        or args.slice3_gateway_restart or args.slice3_app_kill
        or args.tui_created_session_id or args.slice3_relaunch_seed_text
    ):
        parser.error('--slice3-recovery requires --https --stock-backend and no other test phase')
    if args.slice3_completed_away and (
        not args.https or args.cookie_phase or not args.stock_backend
        or args.development_backend_sha or args.slice2_foundation
        or args.slice2_native or args.slice2_reasoning or args.slice2_ui
        or args.slice3_clarification or args.slice3_attachment or args.slice3_blocking
        or args.slice3_file_picker or args.slice3_recovery or args.slice3_relaunch or args.tui_created_session_id
        or args.slice3_gateway_restart or args.gateway_restart_nonce
        or args.slice3_relaunch_seed_text
    ):
        parser.error('--slice3-completed-away requires --https --stock-backend and no other test phase')
    if args.slice3_relaunch and (
        not args.slice2_ui or not args.https or args.cookie_phase
        or not args.stock_backend or args.development_backend_sha
        or args.slice2_foundation or args.slice2_native or args.slice2_reasoning
        or args.slice3_clarification or args.slice3_attachment or args.slice3_blocking
        or args.slice3_recovery or args.slice3_completed_away
        or args.slice3_gateway_restart or args.slice3_app_kill or args.slice3_uncertainty
        or not args.tui_created_session_id
    ):
        parser.error('--slice3-relaunch requires --slice2-ui --https --stock-backend --tui-created-session-id and no other test phase')
    if args.slice3_app_kill and (
        not args.slice2_ui or not args.https or args.cookie_phase
        or not args.stock_backend or args.development_backend_sha
        or args.slice2_foundation or args.slice2_native or args.slice2_reasoning
        or args.slice3_clarification or args.slice3_attachment or args.slice3_blocking
        or args.slice3_file_picker or args.slice3_recovery or args.slice3_completed_away
        or args.slice3_relaunch or args.slice3_gateway_restart or args.slice3_uncertainty
        or not args.tui_created_session_id
    ):
        parser.error('--slice3-app-kill requires --slice2-ui --https --stock-backend --tui-created-session-id and no other test phase')
    if args.slice3_gateway_restart and (
        not args.https or args.cookie_phase or not args.stock_backend
        or args.development_backend_sha or args.slice2_foundation
        or args.slice2_native or args.slice2_reasoning or args.slice2_ui
        or args.slice3_clarification or args.slice3_attachment or args.slice3_blocking
        or args.slice3_file_picker or args.slice3_recovery or args.slice3_completed_away or args.slice3_relaunch or args.slice3_app_kill
        or not args.gateway_restart_nonce
    ):
        parser.error('--slice3-gateway-restart requires --https --stock-backend --gateway-restart-nonce and no other test phase')
    backend_phase = (
        args.slice3_pre_ack_loss or args.slice3_active_socket_loss or args.slice2_reasoning or args.slice2_ui or args.slice3_file_picker or args.slice3_recovery
        or args.slice3_completed_away or args.slice3_relaunch or args.slice3_gateway_restart
        or args.slice3_uncertainty or args.slice4_session_metadata
        or args.slice4_branch or args.slice4_branch_ui
    )
    if args.stock_backend and not backend_phase:
        parser.error('--stock-backend requires --slice2-reasoning, --slice2-ui, --slice3-file-picker, --slice3-completed-away, --slice3-relaunch, --slice3-gateway-restart, or --slice3-uncertainty')
    if backend_phase and args.stock_backend == bool(args.development_backend_sha):
        parser.error('Slice 2 backend phase requires exactly one backend mode')
    development = backend_phase and not args.stock_backend
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
    coordination_path = None
    if args.slice3_gateway_restart:
        runtime_root = runtime
        if runtime_root.is_symlink() or runtime_root.resolve() != runtime_root:
            raise RuntimeError('Unexpected gateway restart runtime path')
        coordination_path = runtime_root / f'slice3-gateway-restart-{args.gateway_restart_nonce}.json'
        if coordination_path.parent.resolve() != runtime_root or coordination_path.is_symlink() or coordination_path.exists():
            raise RuntimeError('Gateway restart coordination path already exists or escaped runtime')
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
            'SEMREH_SLICE2_TOOL_CWD': str(runtime / 'tools'),
        })
        if args.stock_backend:
            environment['SEMREH_SLICE2_STOCK_BACKEND_SHA'] = PIN
        else:
            environment['SEMREH_SLICE2_DEVELOPMENT_BACKEND_SHA'] = args.development_backend_sha.lower()
        method = 'testOptInHostedSlice2NativeReasoning'
    if args.slice3_recovery:
        environment = target['EnvironmentVariables']
        environment.update({
            'SEMREH_SLICE2_STOCK_BACKEND_SHA': PIN,
            'SEMREH_SLICE2_TOOL_CWD': str(runtime / 'tools'),
            'SEMREH_SLICE3_RECOVERY_NATIVE': '1',
        })
        method = 'testOptInHostedSlice3NativeAttachmentRecovery'
    if args.slice3_completed_away:
        environment = target['EnvironmentVariables']
        environment.update({
            'SEMREH_SLICE2_STOCK_BACKEND_SHA': PIN,
            'SEMREH_SLICE2_TOOL_CWD': str(runtime / 'tools'),
            'SEMREH_SLICE3_COMPLETED_AWAY_NATIVE': '1',
        })
        method = 'testOptInHostedSlice3CompletedWhileAway'
    if args.slice3_gateway_restart:
        environment = target['EnvironmentVariables']
        environment.update({
            'SEMREH_SLICE2_STOCK_BACKEND_SHA': PIN,
            'SEMREH_SLICE2_TOOL_CWD': str(runtime / 'tools'),
            'SEMREH_SLICE3_GATEWAY_RESTART_NATIVE': '1',
            'SEMREH_SLICE3_GATEWAY_RESTART_NONCE': args.gateway_restart_nonce,
            'SEMREH_SLICE3_GATEWAY_RESTART_COORDINATION_PATH': str(coordination_path),
        })
        method = 'testOptInHostedSlice3NativeGatewayRestart'
    if args.slice3_active_socket_loss:
        target['EnvironmentVariables'].update({
            'SEMREH_SLICE2_STOCK_BACKEND_SHA': PIN,
            'SEMREH_SLICE2_TOOL_CWD': str(runtime / 'tools'),
            'SEMREH_SLICE3_ACTIVE_SOCKET_LOSS_NATIVE': '1',
        })
        method = 'testOptInHostedSlice3NativeActiveSocketLoss'
    if args.slice3_pre_ack_loss:
        target['EnvironmentVariables'].update({
            'SEMREH_SLICE2_STOCK_BACKEND_SHA': PIN,
            'SEMREH_SLICE2_TOOL_CWD': str(runtime / 'tools'),
            'SEMREH_SLICE3_PRE_ACK_LOSS_NATIVE': '1',
        })
        method = 'testOptInHostedSlice3NativePreACKLoss'
    if args.slice4_session_metadata:
        target['EnvironmentVariables'].update({
            'SEMREH_SLICE2_STOCK_BACKEND_SHA': PIN,
            'SEMREH_SLICE2_TOOL_CWD': str(runtime / 'tools'),
            'SEMREH_SLICE4_SESSION_METADATA_NATIVE': '1',
        })
        method = 'testOptInHostedSlice4SessionMetadataConsumers'
    if args.slice4_branch:
        target['EnvironmentVariables'].update({
            'SEMREH_SLICE2_STOCK_BACKEND_SHA': PIN,
            'SEMREH_SLICE2_TOOL_CWD': str(runtime / 'tools'),
            'SEMREH_SLICE4_BRANCH_NATIVE': '1',
        })
        method = 'testOptInHostedSlice4BranchConsumers'
    if args.cookie_phase:
        target['EnvironmentVariables']['SEMREH_SLICE1_COOKIE_PHASE'] = args.cookie_phase
        method = 'testOptInHostedCookie' + args.cookie_phase.title() + 'Phase'
        if args.cookie_phase != 'login':
            del target['EnvironmentVariables']['SEMREH_SLICE1_CREDENTIALS_FILE']
    test_class = 'DirectHermesLiveSmokeTests'
    if args.slice2_ui:
        environment = target['EnvironmentVariables']
        environment['SEMREH_SLICE2_UI_BACKEND_MODE'] = 'development' if development else 'stock'
        environment['SEMREH_SLICE2_UI_BACKEND_SHA'] = (
            args.development_backend_sha.lower() if development else PIN
        )
        environment['SEMREH_SLICE2_TOOL_CWD'] = str(runtime / 'tools')
        target['EnvironmentVariables']['SEMREH_SLICE2_UI_LIVE'] = '1'
        if args.slice3_clarification:
            target['EnvironmentVariables']['SEMREH_SLICE3_CLARIFICATION_UI'] = '1'
        if args.slice3_attachment:
            target['EnvironmentVariables']['SEMREH_SLICE3_ATTACHMENT_UI'] = '1'
        if args.slice3_blocking:
            target['EnvironmentVariables']['SEMREH_SLICE3_BLOCKING_UI'] = '1'
        if args.slice3_file_picker:
            target['EnvironmentVariables']['SEMREH_SLICE3_FILE_PICKER_UI'] = '1'
        if args.slice3_relaunch:
            target['EnvironmentVariables']['SEMREH_SLICE3_RELAUNCH_UI'] = '1'
        if args.slice3_app_kill:
            target['EnvironmentVariables']['SEMREH_SLICE3_APP_KILL_UI'] = '1'
        if args.slice3_uncertainty:
            target['EnvironmentVariables']['SEMREH_SLICE3_UNCERTAINTY_UI'] = '1'
        if args.slice4_branch_ui:
            target['EnvironmentVariables']['SEMREH_SLICE4_BRANCH_UI'] = '1'
        if args.tui_created_session_id:
            target['EnvironmentVariables']['SEMREH_SLICE2_TUI_CREATED_SESSION_ID'] = args.tui_created_session_id
        if args.slice3_relaunch_seed_text:
            target['EnvironmentVariables']['SEMREH_SLICE3_RELAUNCH_SEED_TEXT'] = args.slice3_relaunch_seed_text
        method = 'testOptInLiveProductionLoginNewChatSend'
        test_class = 'LongChatScrollUITests'
    target['OnlyTestIdentifiers'] = [test_class + '/' + method]
    # Generated build artifact only; no project/scheme or personal configuration changes.
    output.write_bytes(plistlib.dumps(plan))
    print('Built test plan: ' + str(source))
    print(output)


if __name__ == '__main__':
    main()
