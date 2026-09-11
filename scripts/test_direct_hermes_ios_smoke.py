#!/usr/bin/env python3
"""Pure CLI rejection checks for hosted smoke backend-mode guards."""

import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
import importlib.util
import plistlib
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parent / "direct_hermes_ios_smoke.py"
SEED_SCRIPT = Path(__file__).resolve().parent / "direct_hermes_relaunch_seed.py"


def load_smoke_module():
    spec = importlib.util.spec_from_file_location("direct_hermes_ios_smoke", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def load_seed_module():
    spec = importlib.util.spec_from_file_location("direct_hermes_relaunch_seed", SEED_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class IOSSmokeGuardTests(unittest.TestCase):
    def test_polish_ui_phases_require_exactly_one_standalone_stock_phase(self):
        message = 'polish UI phase requires exactly one fixed polish selector and the stock HTTPS UI phase'
        for arguments in (
            ['--polish-restore-ui'],
            ['--https', '--stock-backend', '--slice2-ui', '--polish-restore-ui', '--polish-thinking-ui'],
            ['--https', '--stock-backend', '--slice2-ui', '--polish-send-jump-ui', '--interim-heading-ui'],
        ):
            with self.subTest(arguments=arguments):
                self.assertRejected(arguments, message)

    def test_polish_ui_phases_export_exact_targets_and_environment_guards(self):
        cases = (
            ('--polish-restore-ui', 'SEMREH_POLISH_RESTORE_UI',
             'LongChatScrollUITests/testOptInProductionColdRestoreNeverShowsBlankAndReopensKnownChat'),
            ('--polish-thinking-ui', 'SEMREH_POLISH_THINKING_UI',
             'DirectSkillUITests/testOptInProductionThinkingPlacementSurvivesStopResendAndReopen'),
            ('--polish-send-jump-ui', 'SEMREH_POLISH_SEND_JUMP_UI',
             'LongChatScrollUITests/testOptInProductionSendKeepsNewPromptAndStreamingResponseVisible'),
        )
        for flag, environment_key, selector in cases:
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as temporary:
                smoke = load_smoke_module()
                products = Path(temporary).resolve()
                source = products / 'HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun'
                source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                    'TestTargets': [{'BlueprintName': 'HermesMobileUITests'}],
                }]}))
                with patch.object(smoke, 'PRODUCTS', products), \
                        patch.object(smoke, 'RUNTIME', products / 'runtime'), \
                        patch.object(smoke, 'validate') as validate, \
                        patch.object(sys, 'argv', [str(SCRIPT), '--https', '--stock-backend',
                                                   '--slice2-ui', flag]):
                    with redirect_stdout(StringIO()): smoke.main()
                validate.assert_called_once_with()
                target = plistlib.loads(
                    (products / 'SemrehSlice2LiveUI.xctestrun').read_bytes()
                )['TestConfigurations'][0]['TestTargets'][0]
                self.assertEqual(target['OnlyTestIdentifiers'], [selector])
                self.assertEqual(target['EnvironmentVariables'][environment_key], '1')
                self.assertEqual(target['EnvironmentVariables']['SEMREH_SLICE2_UI_BACKEND_MODE'], 'stock')

    def test_a2_profile_ui_rejects_missing_or_unowned_fixture_data(self):
        message = ('--a2-profile-ui requires the stock HTTPS UI phase plus bounded '
                   'non-default profile and sentinel values')
        self.assertRejected(['--a2-profile-ui'], message)

        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary).resolve()
            with patch.object(smoke, 'RUNTIME', runtime), \
                    patch.object(sys, 'argv', [str(SCRIPT), '--https', '--stock-backend',
                                               '--slice2-ui', '--a2-profile-ui',
                                               '--a2-profile-name', 'missing-profile',
                                               '--a2-selected-sentinel', 'owned row',
                                               '--a2-default-sentinel', 'default row']):
                with self.assertRaisesRegex(SystemExit, '2'):
                    smoke.main()

    def test_a2_profile_ui_exports_exact_owned_profile_target(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            products = root / 'products'
            products.mkdir()
            source = products / 'HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileUITests'}],
            }]}))
            runtime = root / 'runtime'
            (runtime / 'home' / 'profiles' / 'owned-profile').mkdir(parents=True)
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'RUNTIME', runtime), \
                    patch.object(smoke, 'validate') as validate, \
                    patch.object(sys, 'argv', [str(SCRIPT), '--https', '--stock-backend',
                                               '--slice2-ui', '--a2-profile-ui',
                                               '--a2-profile-name', 'owned-profile',
                                               '--a2-selected-sentinel', 'owned row',
                                               '--a2-default-sentinel', 'default row']):
                with redirect_stdout(StringIO()):
                    smoke.main()

            validate.assert_called_once_with()
            target = plistlib.loads(
                (products / 'SemrehSlice2LiveUI.xctestrun').read_bytes()
            )['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'LongChatScrollUITests/'
                'testOptInProductionNonDefaultProfileOwnsFirstControlAndSessionsSidebarLoad',
            ])
            environment = target['EnvironmentVariables']
            self.assertEqual(environment['SEMREH_A2_PROFILE_NAME'], 'owned-profile')
            self.assertEqual(environment['SEMREH_A2_SELECTED_SENTINEL'], 'owned row')
            self.assertEqual(environment['SEMREH_A2_DEFAULT_SENTINEL'], 'default row')

    def test_interim_heading_ui_requires_standalone_stock_ui_https(self):
        message = '--interim-heading-ui requires --slice2-ui --https --stock-backend and no other test phase'
        for arguments in (
            ['--interim-heading-ui'],
            ['--slice2-ui', '--interim-heading-ui'],
            ['--https', '--slice2-ui', '--interim-heading-ui'],
            ['--https', '--stock-backend', '--interim-heading-ui'],
            ['--https', '--stock-backend', '--slice2-ui', '--interim-heading-ui',
             '--slice4-skill-ui'],
        ):
            with self.subTest(arguments=arguments):
                self.assertRejected(arguments, message)

    def test_interim_heading_ui_exports_exact_target_with_stabilization_guard(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary).resolve()
            source = products / 'HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileUITests'}],
            }]}))
            output = products / 'SemrehSlice2LiveUI.xctestrun'
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'RUNTIME', products / 'runtime'), \
                    patch.object(smoke, 'validate') as validate, \
                    patch.object(sys, 'argv', [str(SCRIPT), '--https', '--stock-backend',
                                               '--slice2-ui', '--interim-heading-ui']):
                with redirect_stdout(StringIO()): smoke.main()
            validate.assert_called_once_with()
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'DirectSkillUITests/'
                'testOptInProductionInterimHeadingSurvivesFinalAndCanonicalReopen',
            ])
            environment = target['EnvironmentVariables']
            self.assertEqual(environment['SEMREH_STABILIZATION_UI'], '1')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_MODE'], 'stock')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_SHA'], smoke.PIN)
            self.assertEqual(environment['SEMREH_SLICE1_HTTPS'], '1')
            self.assertNotIn('SEMREH_SLICE4_SKILL_UI', environment)

    def test_stabilization_ui_requires_standalone_stock_ui_https(self):
        message = '--stabilization-ui requires --slice2-ui --https --stock-backend and no other test phase'
        for arguments in (
            ['--stabilization-ui'],
            ['--slice2-ui', '--stabilization-ui'],
            ['--https', '--slice2-ui', '--stabilization-ui'],
            ['--https', '--stock-backend', '--stabilization-ui'],
            ['--https', '--stock-backend', '--slice2-ui', '--stabilization-ui', '--slice4-skill-ui'],
        ):
            with self.subTest(arguments=arguments):
                self.assertRejected(arguments, message)

    def test_stabilization_ui_exports_exact_stop_resend_target(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary).resolve()
            source = products / 'HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileUITests'}],
            }]}))
            output = products / 'SemrehSlice2LiveUI.xctestrun'
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'RUNTIME', products / 'runtime'), \
                    patch.object(smoke, 'validate') as validate, \
                    patch.object(sys, 'argv', [str(SCRIPT), '--https', '--stock-backend',
                                               '--slice2-ui', '--stabilization-ui']):
                with redirect_stdout(StringIO()): smoke.main()
            validate.assert_called_once_with()
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'DirectSkillUITests/testOptInProductionStopThenResend',
            ])
            environment = target['EnvironmentVariables']
            self.assertEqual(environment['SEMREH_STABILIZATION_UI'], '1')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_MODE'], 'stock')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_SHA'], smoke.PIN)
            self.assertEqual(environment['SEMREH_SLICE1_HTTPS'], '1')
            self.assertNotIn('SEMREH_SLICE4_SKILL_UI', environment)

    def test_personal_bootstrap_ui_requires_standalone_stock_ui_https(self):
        message = '--personal-bootstrap-ui requires --slice2-ui --https --stock-backend and no other test phase'
        for arguments in (
            ['--personal-bootstrap-ui'],
            ['--slice2-ui', '--personal-bootstrap-ui'],
            ['--https', '--slice2-ui', '--personal-bootstrap-ui'],
            ['--https', '--stock-backend', '--personal-bootstrap-ui'],
            ['--https', '--stock-backend', '--slice2-ui', '--personal-bootstrap-ui', '--slice4-btw-ui'],
        ):
            with self.subTest(arguments=arguments):
                self.assertRejected(arguments, message)

    def test_personal_bootstrap_ui_exports_exact_bootstrap_only_target(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary).resolve()
            source = products / 'HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileUITests'}],
            }]}))
            output = products / 'SemrehSlice2LiveUI.xctestrun'
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'RUNTIME', products / 'runtime'), \
                    patch.object(smoke, 'validate') as validate, \
                    patch.object(sys, 'argv', [str(SCRIPT), '--https', '--stock-backend',
                                               '--slice2-ui', '--personal-bootstrap-ui']):
                with redirect_stdout(StringIO()): smoke.main()
            validate.assert_called_once_with()
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'DirectSkillUITests/testOptInPersonalPilotBootstrapOnly',
            ])
            environment = target['EnvironmentVariables']
            self.assertEqual(environment['SEMREH_PERSONAL_BOOTSTRAP_UI'], '1')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_MODE'], 'stock')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_SHA'], smoke.PIN)
            self.assertEqual(environment['SEMREH_SLICE1_HTTPS'], '1')
            self.assertNotIn('SEMREH_SLICE4_SKILL_UI', environment)

    def test_slice4_skill_ui_requires_standalone_stock_ui_https(self):
        message = '--slice4-skill-ui requires --slice2-ui --https --stock-backend and no other test phase'
        for arguments in (
            ['--slice4-skill-ui'],
            ['--slice2-ui', '--slice4-skill-ui'],
            ['--https', '--slice2-ui', '--slice4-skill-ui'],
            ['--https', '--stock-backend', '--slice4-skill-ui'],
            ['--https', '--stock-backend', '--slice2-ui', '--slice4-skill-ui', '--slice4-background-ui'],
        ):
            with self.subTest(arguments=arguments):
                self.assertRejected(arguments, message)

    def test_slice4_skill_ui_exports_exact_production_ui_target(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary).resolve()
            source = products / 'HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileUITests'}],
            }]}))
            output = products / 'SemrehSlice2LiveUI.xctestrun'
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'RUNTIME', products / 'runtime'), \
                    patch.object(smoke, 'validate') as validate, \
                    patch.object(sys, 'argv', [str(SCRIPT), '--https', '--stock-backend',
                                               '--slice2-ui', '--slice4-skill-ui']):
                with redirect_stdout(StringIO()): smoke.main()
            validate.assert_called_once_with()
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'DirectSkillUITests/testOptInProductionLoginNewChatSkillListAndShortcutDetail',
            ])
            environment = target['EnvironmentVariables']
            self.assertEqual(environment['SEMREH_SLICE4_SKILL_UI'], '1')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_MODE'], 'stock')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_SHA'], smoke.PIN)
            self.assertEqual(environment['SEMREH_SLICE1_HTTPS'], '1')
            self.assertNotIn('SEMREH_SLICE4_GOAL_UI', environment)

    def test_slice4_goal_ui_requires_standalone_stock_ui_https(self):
        message = '--slice4-goal-ui requires --slice2-ui --https --stock-backend and no other test phase'
        for arguments in (
            ['--slice4-goal-ui'],
            ['--slice2-ui', '--slice4-goal-ui'],
            ['--https', '--slice2-ui', '--slice4-goal-ui'],
            ['--https', '--stock-backend', '--slice4-goal-ui'],
            ['--https', '--stock-backend', '--slice2-ui', '--slice4-goal-ui', '--slice4-background-ui'],
            ['--https', '--stock-backend', '--slice2-ui', '--slice4-goal-ui', '--slice3-attachment'],
        ):
            with self.subTest(arguments=arguments):
                self.assertRejected(arguments, message)

    def test_slice4_goal_ui_exports_exact_production_ui_target(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary).resolve()
            source = products / 'HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileUITests'}],
            }]}))
            output = products / 'SemrehSlice2LiveUI.xctestrun'
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'RUNTIME', products / 'runtime'), \
                    patch.object(smoke, 'validate') as validate, \
                    patch.object(sys, 'argv', [
                        str(SCRIPT), '--https', '--stock-backend', '--slice2-ui', '--slice4-goal-ui'
                    ]):
                with redirect_stdout(StringIO()):
                    smoke.main()
            validate.assert_called_once_with()
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'DirectGoalUITests/testOptInProductionLoginNewChatGoalStatus',
            ])
            environment = target['EnvironmentVariables']
            self.assertEqual(environment['SEMREH_SLICE4_GOAL_UI'], '1')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_MODE'], 'stock')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_SHA'], smoke.PIN)
            self.assertEqual(environment['SEMREH_SLICE1_HTTPS'], '1')
            self.assertNotIn('SEMREH_SLICE4_BACKGROUND_UI', environment)

    def test_slice4_background_ui_requires_standalone_stock_ui_https(self):
        message = '--slice4-background-ui requires --slice2-ui --https --stock-backend and no other test phase'
        for arguments in (
            ['--slice4-background-ui'],
            ['--slice2-ui', '--slice4-background-ui'],
            ['--https', '--slice2-ui', '--slice4-background-ui'],
            ['--https', '--stock-backend', '--slice4-background-ui'],
            ['--https', '--stock-backend', '--slice2-ui', '--slice4-background-ui', '--slice4-branch-ui'],
            ['--https', '--stock-backend', '--slice2-ui', '--slice4-background-ui', '--slice3-attachment'],
        ):
            with self.subTest(arguments=arguments):
                self.assertRejected(arguments, message)

    def test_slice4_background_ui_exports_exact_production_ui_target(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary).resolve()
            source = products / 'HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileUITests'}],
            }]}))
            output = products / 'SemrehSlice2LiveUI.xctestrun'
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'RUNTIME', products / 'runtime'), \
                    patch.object(smoke, 'validate') as validate, \
                    patch.object(sys, 'argv', [
                        str(SCRIPT), '--https', '--stock-backend', '--slice2-ui', '--slice4-background-ui'
                    ]):
                with redirect_stdout(StringIO()):
                    smoke.main()
            validate.assert_called_once_with()
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'LongChatScrollUITests/testOptInLiveProductionLoginNewChatSend',
            ])
            environment = target['EnvironmentVariables']
            self.assertEqual(environment['SEMREH_SLICE4_BACKGROUND_UI'], '1')
            self.assertNotIn('SEMREH_SLICE4_BTW_UI', environment)

    def test_slice4_btw_ui_requires_standalone_stock_ui_https(self):
        message = '--slice4-btw-ui requires --slice2-ui --https --stock-backend and no other test phase'
        for arguments in (
            ['--slice4-btw-ui'],
            ['--slice2-ui', '--slice4-btw-ui'],
            ['--https', '--slice2-ui', '--slice4-btw-ui'],
            ['--https', '--stock-backend', '--slice4-btw-ui'],
            ['--https', '--stock-backend', '--slice2-ui', '--slice4-btw-ui', '--slice4-branch-ui'],
            ['--https', '--stock-backend', '--slice2-ui', '--slice4-btw-ui', '--slice3-attachment'],
            ['--https', '--stock-backend', '--slice2-ui', '--slice4-btw-ui', '--cookie-phase', 'login'],
            ['--https', '--stock-backend', '--slice2-ui', '--slice4-btw-ui', '--tui-created-session-id', 'seed'],
        ):
            with self.subTest(arguments=arguments):
                self.assertRejected(arguments, message)

    def test_slice4_btw_ui_exports_exact_production_ui_target(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary).resolve()
            source = products / 'HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileUITests'}],
            }]}))
            output = products / 'SemrehSlice2LiveUI.xctestrun'
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'RUNTIME', products / 'runtime'), \
                    patch.object(smoke, 'validate') as validate, \
                    patch.object(sys, 'argv', [
                        str(SCRIPT), '--https', '--stock-backend', '--slice2-ui', '--slice4-btw-ui'
                    ]):
                with redirect_stdout(StringIO()):
                    smoke.main()
            validate.assert_called_once_with()
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'LongChatScrollUITests/testOptInLiveProductionLoginNewChatSend',
            ])
            environment = target['EnvironmentVariables']
            self.assertEqual(environment['SEMREH_SLICE4_BTW_UI'], '1')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_MODE'], 'stock')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_SHA'], smoke.PIN)
            self.assertEqual(environment['SEMREH_SLICE1_HTTPS'], '1')

    def test_git_ui_requires_valid_id_and_standalone_stock_https_ui(self):
        base = ['--https', '--stock-backend', '--slice2-ui', '--slice4-git-ui-session-id']
        for arguments in (
            ['--slice4-git-ui-session-id', 'owned-session'],
            ['--https', '--slice2-ui', '--slice4-git-ui-session-id', 'owned-session'],
            base + [''], base + ['../unsafe'], base + ['a' * 129],
            base + ['owned-session', '--slice4-branch-ui'],
            base + ['owned-session', '--slice3-attachment'],
        ):
            with self.subTest(arguments=arguments):
                self.assertRejected(arguments, '--slice4-git-ui-session-id requires')

    def test_git_ui_exports_exact_owned_session_and_production_target(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary).resolve()
            source = products / 'HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileUITests'}],
            }]}))
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'RUNTIME', products / 'runtime'), \
                    patch.object(smoke, 'validate'), \
                    patch.object(sys, 'argv', [str(SCRIPT), '--https', '--stock-backend',
                        '--slice2-ui', '--slice4-git-ui-session-id', 'owned-session']):
                with redirect_stdout(StringIO()):
                    smoke.main()
            target = plistlib.loads((products / 'SemrehSlice2LiveUI.xctestrun').read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'LongChatScrollUITests/testOptInLiveProductionLoginNewChatSend'])
            self.assertEqual(target['EnvironmentVariables']['SEMREH_SLICE4_GIT_UI_SESSION_ID'], 'owned-session')
            self.assertEqual(target['EnvironmentVariables']['SEMREH_SLICE2_UI_BACKEND_MODE'], 'stock')

    def test_slice4_branch_ui_requires_standalone_stock_ui_https(self):
        message = '--slice4-branch-ui requires --slice2-ui --https --stock-backend and no other test phase'
        for arguments in (
            ['--slice4-branch-ui'],
            ['--slice2-ui', '--slice4-branch-ui'],
            ['--https', '--slice2-ui', '--slice4-branch-ui'],
            ['--https', '--stock-backend', '--slice4-branch-ui'],
            ['--https', '--stock-backend', '--slice2-ui', '--slice4-branch-ui', '--slice4-branch'],
            ['--https', '--stock-backend', '--slice2-ui', '--slice4-branch-ui', '--slice3-attachment'],
            ['--https', '--stock-backend', '--slice2-ui', '--slice4-branch-ui', '--cookie-phase', 'login'],
        ):
            with self.subTest(arguments=arguments):
                self.assertRejected(arguments, message)

    def test_slice4_branch_ui_exports_exact_production_ui_target(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary).resolve()
            source = products / 'HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileUITests'}],
            }]}))
            output = products / 'SemrehSlice2LiveUI.xctestrun'
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'RUNTIME', products / 'runtime'), \
                    patch.object(smoke, 'validate') as validate, \
                    patch.object(sys, 'argv', [
                        str(SCRIPT), '--https', '--stock-backend', '--slice2-ui', '--slice4-branch-ui'
                    ]):
                with redirect_stdout(StringIO()):
                    smoke.main()
            validate.assert_called_once_with()
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'LongChatScrollUITests/testOptInLiveProductionLoginNewChatSend',
            ])
            environment = target['EnvironmentVariables']
            self.assertEqual(environment['SEMREH_SLICE4_BRANCH_UI'], '1')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_MODE'], 'stock')
            self.assertEqual(environment['SEMREH_SLICE2_UI_BACKEND_SHA'], smoke.PIN)
            self.assertEqual(environment['SEMREH_SLICE1_HTTPS'], '1')

    def test_slice4_branch_requires_standalone_stock_https(self):
        message = '--slice4-branch requires --https --stock-backend and no other test phase'
        self.assertRejected(['--slice4-branch'], message)
        self.assertRejected(['--https', '--slice4-branch'], message)
        self.assertRejected([
            '--https', '--stock-backend', '--slice4-branch', '--slice4-session-metadata'
        ], message)
        for other in ('--slice2-ui', '--slice3-recovery', '--slice3-active-socket-loss',
                      '--slice3-pre-ack-loss', '--slice3-gateway-restart'):
            with self.subTest(other=other):
                self.assertRejected(
                    ['--https', '--stock-backend', '--slice4-branch', other], message
                )

    def test_slice4_branch_exports_exact_native_target(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary).resolve()
            source = products / 'HermesMobile_HermesMobile_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileTests'}],
            }]}))
            output = products / 'SemrehSlice1Live.xctestrun'
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'OUTPUT', output), \
                    patch.object(smoke, 'validate') as validate, \
                    patch.object(sys, 'argv', [
                        str(SCRIPT), '--https', '--stock-backend', '--slice4-branch'
                    ]):
                with redirect_stdout(StringIO()):
                    smoke.main()
            validate.assert_called_once_with()
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'DirectHermesLiveSmokeTests/testOptInHostedSlice4BranchConsumers',
            ])
            environment = target['EnvironmentVariables']
            self.assertEqual(environment['SEMREH_SLICE4_BRANCH_NATIVE'], '1')
            self.assertEqual(environment['SEMREH_SLICE2_STOCK_BACKEND_SHA'], smoke.PIN)
            self.assertEqual(environment['SEMREH_SLICE2_TOOL_CWD'], str(smoke.RUNTIME / 'tools'))
            self.assertEqual(environment['SEMREH_SLICE1_HTTPS'], '1')

    def test_session_metadata_requires_standalone_stock_https(self):
        base = ['--slice4-session-metadata', '--https', '--stock-backend']
        for arguments in (
            ['--slice4-session-metadata'],
            ['--slice4-session-metadata', '--https'],
            ['--slice4-session-metadata', '--stock-backend'],
            *[base + [flag] for flag in (
                '--slice2-ui', '--slice2-native', '--slice2-foundation',
                '--slice2-reasoning', '--slice3-attachment', '--slice3-clarification',
                '--slice3-blocking', '--slice3-file-picker', '--slice3-recovery',
                '--slice3-completed-away', '--slice3-relaunch', '--slice3-gateway-restart',
                '--slice3-app-kill', '--slice3-active-socket-loss',
                '--slice3-pre-ack-loss', '--slice3-uncertainty',
            )],
            base + ['--cookie-phase', 'login'],
            base + ['--development-backend-sha', 'a' * 40],
            base + ['--tui-created-session-id', 'seed'],
            base + ['--gateway-restart-nonce', 'A' * 16],
            base + ['--slice3-relaunch-seed-text', 'seed'],
        ):
            with self.subTest(arguments=arguments):
                self.assertRejected(arguments, '--slice4-session-metadata requires')

    def test_session_metadata_exports_exact_native_target(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary).resolve()
            source = products / 'HermesMobile_HermesMobile_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileTests'}],
            }]}))
            output = products / 'SemrehSlice1Live.xctestrun'
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'OUTPUT', output), \
                    patch.object(smoke, 'validate') as validate, \
                    patch.object(sys, 'argv', [str(SCRIPT), '--https', '--stock-backend', '--slice4-session-metadata']):
                with redirect_stdout(StringIO()):
                    smoke.main()
            validate.assert_called_once_with()
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'DirectHermesLiveSmokeTests/testOptInHostedSlice4SessionMetadataConsumers',
            ])
            environment = target['EnvironmentVariables']
            self.assertEqual(environment['SEMREH_SLICE4_SESSION_METADATA_NATIVE'], '1')
            self.assertEqual(environment['SEMREH_SLICE2_STOCK_BACKEND_SHA'], smoke.PIN)
            self.assertEqual(environment['SEMREH_SLICE2_TOOL_CWD'], str(smoke.RUNTIME / 'tools'))
            self.assertEqual(environment['SEMREH_SLICE1_HTTPS'], '1')

    def test_pre_ack_loss_is_stock_https_and_standalone(self):
        base = ['--slice3-pre-ack-loss', '--https', '--stock-backend']
        for arguments in (
            ['--slice3-pre-ack-loss'],
            ['--slice3-pre-ack-loss', '--https'],
            ['--slice3-pre-ack-loss', '--stock-backend'],
            *[base + [flag] for flag in (
                '--slice2-ui', '--slice2-native', '--slice2-foundation',
                '--slice2-reasoning', '--slice3-attachment', '--slice3-clarification',
                '--slice3-blocking', '--slice3-file-picker', '--slice3-recovery',
                '--slice3-completed-away', '--slice3-relaunch', '--slice3-gateway-restart',
                '--slice3-app-kill', '--slice3-active-socket-loss',
            )],
            base + ['--cookie-phase', 'login'],
            base + ['--tui-created-session-id', 'seed'],
            base + ['--development-backend-sha', 'a' * 40],
            base + ['--gateway-restart-nonce', 'A' * 16],
            base + ['--slice3-relaunch-seed-text', 'seed'],
        ):
            with self.subTest(arguments=arguments):
                self.assertRejected(arguments, '--slice3-pre-ack-loss requires')

    def test_pre_ack_loss_exports_exact_native_target(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary).resolve()
            source = products / 'HermesMobile_HermesMobile_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileTests'}],
            }]}))
            output = products / 'SemrehSlice1Live.xctestrun'
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'OUTPUT', output), \
                    patch.object(smoke, 'validate') as validate, \
                    patch.object(sys, 'argv', [str(SCRIPT), '--https', '--stock-backend', '--slice3-pre-ack-loss']):
                with redirect_stdout(StringIO()):
                    smoke.main()
            validate.assert_called_once_with()
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'DirectHermesLiveSmokeTests/testOptInHostedSlice3NativePreACKLoss',
            ])
            environment = target['EnvironmentVariables']
            self.assertEqual(environment['SEMREH_SLICE3_PRE_ACK_LOSS_NATIVE'], '1')
            self.assertNotIn('SEMREH_SLICE3_ACTIVE_SOCKET_LOSS_NATIVE', environment)
            self.assertEqual(environment['SEMREH_SLICE2_STOCK_BACKEND_SHA'], smoke.PIN)
            self.assertEqual(environment['SEMREH_SLICE2_TOOL_CWD'], str(smoke.RUNTIME / 'tools'))
            self.assertEqual(environment['SEMREH_SLICE1_HTTPS'], '1')

    def test_active_socket_loss_is_stock_https_and_standalone(self):
        base = ['--slice3-active-socket-loss', '--https', '--stock-backend']
        for arguments in (
            ['--slice3-active-socket-loss'],
            ['--slice3-active-socket-loss', '--https'],
            ['--slice3-active-socket-loss', '--stock-backend'],
            *[base + [flag] for flag in (
                '--slice2-ui', '--slice2-native', '--slice2-foundation',
                '--slice2-reasoning', '--slice3-attachment', '--slice3-clarification',
                '--slice3-blocking', '--slice3-file-picker', '--slice3-recovery',
                '--slice3-completed-away', '--slice3-relaunch', '--slice3-gateway-restart',
            )],
            base + ['--cookie-phase', 'login'],
            base + ['--tui-created-session-id', 'seed'],
            base + ['--development-backend-sha', 'a' * 40],
            base + ['--gateway-restart-nonce', 'A' * 16],
        ):
            with self.subTest(arguments=arguments):
                self.assertRejected(arguments, '--slice3-active-socket-loss requires')

    def test_active_socket_loss_exports_exact_native_target(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary).resolve()
            source = products / 'HermesMobile_HermesMobile_iphonesimulator.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{
                'TestTargets': [{'BlueprintName': 'HermesMobileTests'}],
            }]}))
            output = products / 'SemrehSlice1Live.xctestrun'
            with patch.object(smoke, 'PRODUCTS', products), \
                    patch.object(smoke, 'OUTPUT', output), \
                    patch.object(smoke, 'validate') as validate, \
                    patch.object(sys, 'argv', [str(SCRIPT), '--https', '--stock-backend', '--slice3-active-socket-loss']):
                with redirect_stdout(StringIO()):
                    smoke.main()
            validate.assert_called_once_with()
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], [
                'DirectHermesLiveSmokeTests/testOptInHostedSlice3NativeActiveSocketLoss',
            ])
            environment = target['EnvironmentVariables']
            self.assertEqual(environment['SEMREH_SLICE3_ACTIVE_SOCKET_LOSS_NATIVE'], '1')
            self.assertEqual(environment['SEMREH_SLICE2_STOCK_BACKEND_SHA'], smoke.PIN)
            self.assertEqual(environment['SEMREH_SLICE2_TOOL_CWD'], str(smoke.RUNTIME / 'tools'))
            self.assertEqual(environment['SEMREH_SLICE1_HTTPS'], '1')

    def test_relaunch_seed_accepts_only_bounded_synthetic_marker(self):
        seed = load_seed_module()
        self.assertEqual(
            seed._validate_seed_text("SEMREH_SLICE3_APP_RELAUNCH_SEED_TEST"),
            "SEMREH_SLICE3_APP_RELAUNCH_SEED_TEST",
        )
        for invalid in ("", "seed with spaces", "seed/with/path", "x" * 129):
            with self.assertRaises(ValueError):
                seed._validate_seed_text(invalid)
        self.assertTrue(seed.RELAUNCH_PROMPT.fullmatch("SEMREH_SLICE3_RELAUNCH_01234567-89ab-cdef-0123-456789abcdef"))
        self.assertFalse(seed.RELAUNCH_PROMPT.fullmatch("SEMREH_SLICE3_RELAUNCH_extra"))
        self.assertTrue(seed.APP_KILL_PROMPT.fullmatch(
            "SEMREH_INTERRUPT_FIXTURE SEMREH_SLICE3_APP_KILL_01234567-89ab-cdef-0123-456789abcdef"
        ))
        self.assertFalse(seed.APP_KILL_PROMPT.fullmatch("SEMREH_SLICE3_APP_KILL_extra"))

    def assertRejected(self, arguments, message):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn(message, result.stderr)

    def test_stock_requires_backend_phase(self):
        self.assertRejected(
            ["--stock-backend"],
            "--stock-backend requires --slice2-reasoning, --slice2-ui, --slice3-file-picker, --slice3-completed-away, --slice3-relaunch, --slice3-gateway-restart, or --slice3-uncertainty",
        )

    def test_reasoning_requires_exactly_one_backend_mode(self):
        self.assertRejected(
            ["--https", "--slice2-reasoning"],
            "Slice 2 backend phase requires exactly one backend mode",
        )
        self.assertRejected(
            [
                "--https", "--slice2-reasoning", "--stock-backend",
                "--development-backend-sha", "not-a-real-sha",
            ],
            "Slice 2 backend phase requires exactly one backend mode",
        )

    def test_ui_requires_exactly_one_backend_mode(self):
        self.assertRejected(
            ["--https", "--slice2-ui"],
            "Slice 2 backend phase requires exactly one backend mode",
        )
        self.assertRejected(
            [
                "--https", "--slice2-ui", "--stock-backend",
                "--development-backend-sha", "not-a-real-sha",
            ],
            "Slice 2 backend phase requires exactly one backend mode",
        )

    def test_slice3_clarification_requires_stock_https_ui(self):
        message = "--slice3-clarification requires --slice2-ui --https --stock-backend"
        self.assertRejected(["--slice3-clarification"], message)
        self.assertRejected(["--https", "--slice3-clarification", "--stock-backend"], message)
        self.assertRejected(["--https", "--slice2-ui", "--slice3-clarification"], message)
        self.assertRejected(
            ["--slice2-ui", "--stock-backend", "--slice3-clarification"],
            "Slice 2 UI requires --https and no other test phase",
        )
        self.assertRejected(
            [
                "--https", "--slice2-ui", "--slice3-clarification",
                "--development-backend-sha", "8c50f84522a755d40346e73701a6847fbdde20ec",
            ],
            message,
        )

    def test_slice3_attachment_requires_stock_https_ui(self):
        message = "--slice3-attachment requires --slice2-ui --https --stock-backend"
        self.assertRejected(["--slice3-attachment"], message)
        self.assertRejected(["--https", "--slice3-attachment", "--stock-backend"], message)
        self.assertRejected(["--https", "--slice2-ui", "--slice3-attachment"], message)
        self.assertRejected(
            ["--slice2-ui", "--stock-backend", "--slice3-attachment"],
            "Slice 2 UI requires --https and no other test phase",
        )
        self.assertRejected(
            [
                "--https", "--slice2-ui", "--slice3-attachment",
                "--development-backend-sha", "8c50f84522a755d40346e73701a6847fbdde20ec",
            ],
            message,
        )

    def test_slice3_blocking_requires_stock_https_ui(self):
        message = "--slice3-blocking requires --slice2-ui --https --stock-backend"
        self.assertRejected(["--slice3-blocking"], message)
        self.assertRejected(["--https", "--slice3-blocking", "--stock-backend"], message)
        self.assertRejected(["--https", "--slice2-ui", "--slice3-blocking"], message)
        self.assertRejected(
            ["--slice2-ui", "--stock-backend", "--slice3-blocking"],
            "Slice 2 UI requires --https and no other test phase",
        )
        self.assertRejected(
            [
                "--https", "--slice2-ui", "--slice3-blocking",
                "--development-backend-sha", "8c50f84522a755d40346e73701a6847fbdde20ec",
            ],
            message,
        )
        for other in ("--slice3-clarification", "--slice3-attachment"):
            self.assertRejected(
                ["--https", "--slice2-ui", "--stock-backend", "--slice3-blocking", other],
                "--slice3-clarification, --slice3-attachment, and --slice3-blocking are mutually exclusive",
            )

    def test_slice3_file_picker_requires_stock_https_ui_and_is_standalone(self):
        message = "--slice3-file-picker requires --slice2-ui --https --stock-backend and no other test phase"
        self.assertRejected(["--slice3-file-picker"], message)
        self.assertRejected(["--https", "--slice3-file-picker", "--stock-backend"], message)
        self.assertRejected(["--https", "--slice2-ui", "--slice3-file-picker"], message)
        self.assertRejected(
            [
                "--https", "--slice2-ui", "--stock-backend", "--slice3-file-picker",
                "--slice3-attachment",
            ],
            message,
        )

    def test_stock_ui_generation_exports_file_picker_selector(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{
                    "TestTargets": [{"BlueprintName": "HermesMobileUITests"}],
                }],
            }))
            runtime = Path(temporary) / "stock-runtime"
            with patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "RUNTIME", runtime), \
                    patch.object(smoke, "validate") as validate, \
                    patch.object(smoke, "PIN", "29112bef099274229cadff79cdff7bf7b99c4b77"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice2-ui", "--stock-backend",
                        "--slice3-file-picker",
                    ]):
                output = StringIO()
                with redirect_stdout(output):
                    smoke.main()

            validate.assert_called_once_with()
            plan = plistlib.loads((products / "SemrehSlice2LiveUI.xctestrun").read_bytes())
            target = plan["TestConfigurations"][0]["TestTargets"][0]
            environment = target["EnvironmentVariables"]
            self.assertEqual(environment["SEMREH_SLICE3_FILE_PICKER_UI"], "1")
            self.assertEqual(
                target["OnlyTestIdentifiers"],
                ["LongChatScrollUITests/testOptInLiveProductionLoginNewChatSend"],
            )
            self.assertNotIn("SEMREH_SLICE3_ATTACHMENT_UI", environment)
            self.assertNotIn("SEMREH_SLICE3_BLOCKING_UI", environment)
            self.assertNotIn("password", output.getvalue().lower())

    def test_slice3_recovery_requires_stock_https_and_is_standalone(self):
        message = "--slice3-recovery requires --https --stock-backend and no other test phase"
        self.assertRejected(["--slice3-recovery"], message)
        self.assertRejected(["--https", "--slice3-recovery"], message)
        self.assertRejected(["--https", "--slice3-recovery", "--stock-backend", "--slice2-native"], message)
        self.assertRejected(
            ["--https", "--slice2-ui", "--slice3-recovery", "--stock-backend", "--slice3-blocking"],
            message,
        )
        self.assertRejected(
            ["--https", "--slice3-recovery", "--stock-backend", "--development-backend-sha", "abc"],
            message,
        )

    def test_slice3_completed_away_requires_stock_https_and_is_standalone(self):
        message = "--slice3-completed-away requires --https --stock-backend and no other test phase"
        self.assertRejected(["--slice3-completed-away"], message)
        self.assertRejected(["--https", "--slice3-completed-away"], message)
        self.assertRejected(
            ["--https", "--slice3-completed-away", "--stock-backend", "--slice2-ui"],
            message,
        )
        self.assertRejected(
            ["--https", "--slice3-completed-away", "--stock-backend", "--slice3-recovery"],
            "--slice3-recovery requires --https --stock-backend and no other test phase",
        )
        self.assertRejected(
            [
                "--https", "--slice3-completed-away",
                "--development-backend-sha", "8c50f84522a755d40346e73701a6847fbdde20ec",
            ],
            "--slice3-completed-away requires --https --stock-backend and no other test phase",
        )

    def test_slice3_gateway_restart_requires_stock_https_nonce_and_is_standalone(self):
        message = "--slice3-gateway-restart requires --https --stock-backend --gateway-restart-nonce and no other test phase"
        self.assertRejected(["--slice3-gateway-restart"], message)
        self.assertRejected(["--https", "--slice3-gateway-restart", "--stock-backend"], message)
        self.assertRejected(
            ["--https", "--slice3-gateway-restart", "--stock-backend", "--gateway-restart-nonce", "short"],
            "--gateway-restart-nonce requires --slice3-gateway-restart and 16-128 safe characters",
        )
        self.assertRejected(
            [
                "--https", "--slice3-gateway-restart", "--stock-backend",
                "--gateway-restart-nonce", "ABCDEFGHIJKLMNOP",
                "--slice3-completed-away",
            ],
            "--slice3-completed-away requires --https --stock-backend and no other test phase",
        )

    def test_slice3_relaunch_requires_seeded_stock_ui_and_is_standalone(self):
        message = "--slice3-relaunch requires --slice2-ui --https --stock-backend --tui-created-session-id and no other test phase"
        self.assertRejected(["--slice3-relaunch"], message)
        self.assertRejected(
            ["--https", "--slice2-ui", "--stock-backend", "--slice3-relaunch"],
            message,
        )
        self.assertRejected(
            [
                "--https", "--slice2-ui", "--stock-backend", "--slice3-relaunch",
                "--tui-created-session-id", "seed-id", "--slice3-blocking",
            ],
            message,
        )
        self.assertRejected(
            [
                "--https", "--slice2-ui", "--slice3-relaunch",
                "--tui-created-session-id", "seed-id",
            ],
            message,
        )
        self.assertRejected(
            [
                "--https", "--slice2-ui", "--stock-backend", "--slice3-relaunch",
                "--tui-created-session-id", "seed-id", "--slice3-relaunch-seed-text", "bad marker",
            ],
            "--slice3-relaunch-seed-text requires --slice3-relaunch, --slice3-app-kill, or --slice3-uncertainty and a bounded synthetic marker",
        )

    def test_slice3_uncertainty_requires_exact_seeded_stock_ui_and_is_standalone(self):
        message = "--slice3-uncertainty requires --slice2-ui --https --stock-backend --tui-created-session-id --slice3-relaunch-seed-text and no other test phase"
        self.assertRejected(["--slice3-uncertainty"], message)
        self.assertRejected(
            ["--https", "--slice2-ui", "--stock-backend", "--slice3-uncertainty"],
            message,
        )
        self.assertRejected(
            [
                "--https", "--slice2-ui", "--stock-backend", "--slice3-uncertainty",
                "--tui-created-session-id", "seed-id",
            ],
            message,
        )
        self.assertRejected(
            [
                "--https", "--slice2-ui", "--stock-backend", "--slice3-uncertainty",
                "--tui-created-session-id", "seed-id",
                "--slice3-relaunch-seed-text", "SEMREH_SLICE3_PRE_ACK_SEED_bad",
            ],
            "--slice3-uncertainty requires a SEMREH_SLICE3_PRE_ACK_SEED_<UUID> marker",
        )
        valid = "SEMREH_SLICE3_PRE_ACK_SEED_01234567-89ab-cdef-0123-456789abcdef"
        base = [
            "--https", "--slice2-ui", "--stock-backend", "--slice3-uncertainty",
            "--tui-created-session-id", "seed-id", "--slice3-relaunch-seed-text", valid,
        ]
        for conflicting_phase in (
            "--slice2-foundation", "--slice2-native", "--slice2-reasoning",
            "--slice3-clarification", "--slice3-attachment", "--slice3-blocking",
            "--slice3-file-picker", "--slice3-recovery", "--slice3-completed-away",
            "--slice3-relaunch", "--slice3-app-kill", "--slice3-gateway-restart",
        ):
            with self.subTest(conflicting_phase=conflicting_phase):
                self.assertRejected(base + [conflicting_phase], message)
        self.assertRejected(base + ["--cookie-phase", "login"], message)
        self.assertRejected(base + ["--development-backend-sha", "a" * 40], message)
        self.assertRejected(base + ["--gateway-restart-nonce", "A" * 16], message)
        self.assertRejected(
            base + ["--slice3-pre-ack-loss"],
            "--slice3-pre-ack-loss requires",
        )
        self.assertRejected(
            base + ["--slice3-active-socket-loss"],
            "--slice3-active-socket-loss requires",
        )

    def test_stock_ui_generation_exports_prompt_uncertainty_opt_in(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{
                    "TestTargets": [{"BlueprintName": "HermesMobileUITests"}],
                }],
            }))
            runtime = Path(temporary) / "stock-runtime"
            seed = "SEMREH_SLICE3_PRE_ACK_SEED_01234567-89ab-cdef-0123-456789abcdef"
            with patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "RUNTIME", runtime), \
                    patch.object(smoke, "validate") as validate, \
                    patch.object(smoke, "PIN", "29112bef099274229cadff79cdff7bf7b99c4b77"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice2-ui", "--stock-backend",
                        "--slice3-uncertainty", "--tui-created-session-id", "seed-id",
                        "--slice3-relaunch-seed-text", seed,
                    ]):
                with redirect_stdout(StringIO()):
                    smoke.main()

            validate.assert_called_once_with()
            plan = plistlib.loads((products / "SemrehSlice2LiveUI.xctestrun").read_bytes())
            target = plan["TestConfigurations"][0]["TestTargets"][0]
            environment = target["EnvironmentVariables"]
            self.assertEqual(environment["SEMREH_SLICE3_UNCERTAINTY_UI"], "1")
            self.assertEqual(environment["SEMREH_SLICE2_TUI_CREATED_SESSION_ID"], "seed-id")
            self.assertEqual(environment["SEMREH_SLICE3_RELAUNCH_SEED_TEXT"], seed)
            self.assertNotIn("SEMREH_SLICE3_RELAUNCH_UI", environment)
            self.assertNotIn("SEMREH_SLICE3_APP_KILL_UI", environment)
            self.assertEqual(
                target["OnlyTestIdentifiers"],
                ["LongChatScrollUITests/testOptInLiveProductionLoginNewChatSend"],
            )

    def test_slice3_app_kill_requires_seeded_stock_ui_and_is_standalone(self):
        message = "--slice3-app-kill requires --slice2-ui --https --stock-backend --tui-created-session-id and no other test phase"
        self.assertRejected(["--slice3-app-kill"], message)
        self.assertRejected(
            ["--https", "--slice2-ui", "--stock-backend", "--slice3-app-kill"],
            message,
        )
        self.assertRejected(
            [
                "--https", "--slice2-ui", "--stock-backend", "--slice3-app-kill",
                "--tui-created-session-id", "seed-id", "--slice3-relaunch",
            ],
            "--slice3-relaunch requires",
        )

    def test_stock_ui_generation_exports_isolated_slice3_app_kill_opt_in(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{"TestTargets": [{"BlueprintName": "HermesMobileUITests"}]}],
            }))
            runtime = Path(temporary) / "stock-runtime"
            with patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "RUNTIME", runtime), \
                    patch.object(smoke, "validate"), \
                    patch.object(smoke, "PIN", "29112bef099274229cadff79cdff7bf7b99c4b77"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice2-ui", "--stock-backend",
                        "--slice3-app-kill", "--tui-created-session-id", "seed-id",
                        "--slice3-relaunch-seed-text", "SEMREH_SLICE3_APP_RELAUNCH_SEED_TEST",
                    ]):
                with redirect_stdout(StringIO()):
                    smoke.main()

            plan = plistlib.loads((products / "SemrehSlice2LiveUI.xctestrun").read_bytes())
            target = plan["TestConfigurations"][0]["TestTargets"][0]
            environment = target["EnvironmentVariables"]
            self.assertEqual(environment["SEMREH_SLICE3_APP_KILL_UI"], "1")
            self.assertNotIn("SEMREH_SLICE3_RELAUNCH_UI", environment)
            self.assertEqual(environment["SEMREH_SLICE2_TUI_CREATED_SESSION_ID"], "seed-id")
            self.assertEqual(environment["SEMREH_SLICE3_RELAUNCH_SEED_TEXT"], "SEMREH_SLICE3_APP_RELAUNCH_SEED_TEST")
            self.assertEqual(target["OnlyTestIdentifiers"], [
                "LongChatScrollUITests/testOptInLiveProductionLoginNewChatSend",
            ])
    def test_stock_native_recovery_generation_exports_exact_target_and_guards(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobile_HermesMobile_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{
                    "TestTargets": [{"BlueprintName": "HermesMobileTests"}],
                }],
            }))
            runtime = Path(temporary) / "stock-runtime"
            credentials = runtime / "credentials.json"
            tool_cwd = runtime / "tools"
            with patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "OUTPUT", products / "SemrehSlice1Live.xctestrun"), \
                    patch.object(smoke, "RUNTIME", runtime), \
                    patch.object(smoke, "validate") as validate, \
                    patch.object(smoke, "PIN", "29112bef099274229cadff79cdff7bf7b99c4b77"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice3-recovery", "--stock-backend",
                    ]):
                output = StringIO()
                with redirect_stdout(output):
                    smoke.main()

            validate.assert_called_once_with()
            plan = plistlib.loads((products / "SemrehSlice1Live.xctestrun").read_bytes())
            target = plan["TestConfigurations"][0]["TestTargets"][0]
            environment = target["EnvironmentVariables"]
            self.assertEqual(environment["SEMREH_SLICE1_CREDENTIALS_FILE"], str(credentials))
            self.assertEqual(environment["SEMREH_SLICE2_STOCK_BACKEND_SHA"], "29112bef099274229cadff79cdff7bf7b99c4b77")
            self.assertEqual(environment["SEMREH_SLICE2_TOOL_CWD"], str(tool_cwd))
            self.assertEqual(environment["SEMREH_SLICE3_RECOVERY_NATIVE"], "1")
            self.assertEqual(environment["SEMREH_SLICE1_HTTPS"], "1")
            self.assertEqual(
                target["OnlyTestIdentifiers"],
                ["DirectHermesLiveSmokeTests/testOptInHostedSlice3NativeAttachmentRecovery"],
            )
            self.assertNotIn("SEMREH_SLICE3_COMPLETED_AWAY_NATIVE", environment)
            self.assertNotIn("SEMREH_SLICE3_RELAUNCH_UI", environment)
            self.assertNotIn("password", output.getvalue().lower())

    def test_stock_ui_generation_exports_slice3_relaunch_seeded_session(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{
                    "TestTargets": [{"BlueprintName": "HermesMobileUITests"}],
                }],
            }))
            runtime = Path(temporary) / "stock-runtime"
            credentials = runtime / "credentials.json"
            with patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "RUNTIME", runtime), \
                    patch.object(smoke, "validate") as validate, \
                    patch.object(smoke, "PIN", "29112bef099274229cadff79cdff7bf7b99c4b77"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice2-ui", "--stock-backend",
                        "--slice3-relaunch", "--tui-created-session-id", "seed-id",
                    ]):
                output = StringIO()
                with redirect_stdout(output):
                    smoke.main()

            validate.assert_called_once_with()
            plan = plistlib.loads((products / "SemrehSlice2LiveUI.xctestrun").read_bytes())
            target = plan["TestConfigurations"][0]["TestTargets"][0]
            environment = target["EnvironmentVariables"]
            self.assertEqual(environment["SEMREH_SLICE1_CREDENTIALS_FILE"], str(credentials))
            self.assertEqual(environment["SEMREH_SLICE3_RELAUNCH_UI"], "1")
            self.assertEqual(environment["SEMREH_SLICE2_TUI_CREATED_SESSION_ID"], "seed-id")
            self.assertNotIn("SEMREH_SLICE3_RELAUNCH_SEED_TEXT", environment)
            self.assertEqual(
                target["OnlyTestIdentifiers"],
                ["LongChatScrollUITests/testOptInLiveProductionLoginNewChatSend"],
            )
            self.assertNotIn("password", output.getvalue().lower())

    def test_stock_ui_generation_exports_explicit_relaunch_seed_marker(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{
                    "TestTargets": [{"BlueprintName": "HermesMobileUITests"}],
                }],
            }))
            runtime = Path(temporary) / "stock-runtime"
            with patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "RUNTIME", runtime), \
                    patch.object(smoke, "validate"), \
                    patch.object(smoke, "PIN", "29112bef099274229cadff79cdff7bf7b99c4b77"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice2-ui", "--stock-backend",
                        "--slice3-relaunch", "--tui-created-session-id", "seed-id",
                        "--slice3-relaunch-seed-text", "SEMREH_SLICE3_APP_RELAUNCH_SEED_TEST",
                    ]):
                with redirect_stdout(StringIO()):
                    smoke.main()

            plan = plistlib.loads((products / "SemrehSlice2LiveUI.xctestrun").read_bytes())
            environment = plan["TestConfigurations"][0]["TestTargets"][0]["EnvironmentVariables"]
            self.assertEqual(
                environment["SEMREH_SLICE3_RELAUNCH_SEED_TEXT"],
                "SEMREH_SLICE3_APP_RELAUNCH_SEED_TEST",
            )

    def test_stock_native_completed_away_generation_exports_exact_target_and_guards(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobile_HermesMobile_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{
                    "TestTargets": [{"BlueprintName": "HermesMobileTests"}],
                }],
            }))
            runtime = Path(temporary) / "stock-runtime"
            credentials = runtime / "credentials.json"
            tool_cwd = runtime / "tools"
            with patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "OUTPUT", products / "SemrehSlice1Live.xctestrun"), \
                    patch.object(smoke, "RUNTIME", runtime), \
                    patch.object(smoke, "validate") as validate, \
                    patch.object(smoke, "PIN", "29112bef099274229cadff79cdff7bf7b99c4b77"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice3-completed-away", "--stock-backend",
                    ]):
                output = StringIO()
                with redirect_stdout(output):
                    smoke.main()

            validate.assert_called_once_with()
            plan = plistlib.loads((products / "SemrehSlice1Live.xctestrun").read_bytes())
            target = plan["TestConfigurations"][0]["TestTargets"][0]
            environment = target["EnvironmentVariables"]
            self.assertEqual(environment["SEMREH_SLICE1_CREDENTIALS_FILE"], str(credentials))
            self.assertEqual(environment["SEMREH_SLICE2_STOCK_BACKEND_SHA"], "29112bef099274229cadff79cdff7bf7b99c4b77")
            self.assertEqual(environment["SEMREH_SLICE2_TOOL_CWD"], str(tool_cwd))
            self.assertEqual(environment["SEMREH_SLICE3_COMPLETED_AWAY_NATIVE"], "1")
            self.assertEqual(environment["SEMREH_SLICE1_HTTPS"], "1")
            self.assertEqual(
                target["OnlyTestIdentifiers"],
                ["DirectHermesLiveSmokeTests/testOptInHostedSlice3CompletedWhileAway"],
            )
            self.assertNotIn("password", output.getvalue().lower())

    def test_stock_native_gateway_restart_generation_exports_coordination_contract(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobile_HermesMobile_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{
                    "TestTargets": [{"BlueprintName": "HermesMobileTests"}],
                }],
            }))
            runtime = (Path(temporary) / "stock-runtime").resolve()
            runtime.mkdir()
            nonce = "ABCDEFGHIJKLMNOP"
            with patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "OUTPUT", products / "SemrehSlice1Live.xctestrun"), \
                    patch.object(smoke, "RUNTIME", runtime), \
                    patch.object(smoke, "validate"), \
                    patch.object(smoke, "PIN", "29112bef099274229cadff79cdff7bf7b99c4b77"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice3-gateway-restart", "--stock-backend",
                        "--gateway-restart-nonce", nonce,
                    ]):
                with redirect_stdout(StringIO()):
                    smoke.main()

            plan = plistlib.loads((products / "SemrehSlice1Live.xctestrun").read_bytes())
            target = plan["TestConfigurations"][0]["TestTargets"][0]
            environment = target["EnvironmentVariables"]
            self.assertEqual(environment["SEMREH_SLICE3_GATEWAY_RESTART_NATIVE"], "1")
            self.assertEqual(environment["SEMREH_SLICE3_GATEWAY_RESTART_NONCE"], nonce)
            self.assertEqual(
                environment["SEMREH_SLICE3_GATEWAY_RESTART_COORDINATION_PATH"],
                str(runtime / f"slice3-gateway-restart-{nonce}.json"),
            )
            self.assertEqual(
                target["OnlyTestIdentifiers"],
                ["DirectHermesLiveSmokeTests/testOptInHostedSlice3NativeGatewayRestart"],
            )
            self.assertFalse((runtime / f"slice3-gateway-restart-{nonce}.json").exists())

    def test_stock_native_gateway_restart_rejects_preexisting_coordination_marker(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobile_HermesMobile_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{
                    "TestTargets": [{"BlueprintName": "HermesMobileTests"}],
                }],
            }))
            runtime = (Path(temporary) / "stock-runtime").resolve()
            runtime.mkdir()
            marker = runtime / "slice3-gateway-restart-ABCDEFGHIJKLMNOP.json"
            marker.write_text("occupied")
            with patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "OUTPUT", products / "SemrehSlice1Live.xctestrun"), \
                    patch.object(smoke, "RUNTIME", runtime), \
                    patch.object(smoke, "validate"), \
                    patch.object(smoke, "PIN", "29112bef099274229cadff79cdff7bf7b99c4b77"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice3-gateway-restart", "--stock-backend",
                        "--gateway-restart-nonce", "ABCDEFGHIJKLMNOP",
                    ]):
                with self.assertRaisesRegex(RuntimeError, "already exists"):
                    smoke.main()

    def test_stock_ui_generation_exports_exact_mode_and_paths(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{
                    "TestTargets": [{"BlueprintName": "HermesMobileUITests"}],
                }],
            }))
            runtime = Path(temporary) / "stock-runtime"
            credentials = runtime / "credentials.json"
            tool_cwd = runtime / "tools"
            with patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "RUNTIME", runtime), \
                    patch.object(smoke, "validate") as validate, \
                    patch.object(smoke, "PIN", "29112bef099274229cadff79cdff7bf7b99c4b77"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice2-ui", "--stock-backend",
                    ]):
                output = StringIO()
                with redirect_stdout(output):
                    smoke.main()

            validate.assert_called_once_with()
            plan = plistlib.loads((products / "SemrehSlice2LiveUI.xctestrun").read_bytes())
            environment = plan["TestConfigurations"][0]["TestTargets"][0]["EnvironmentVariables"]
            self.assertEqual(environment["SEMREH_SLICE2_UI_BACKEND_MODE"], "stock")
            self.assertEqual(
                environment["SEMREH_SLICE2_UI_BACKEND_SHA"],
                "29112bef099274229cadff79cdff7bf7b99c4b77",
            )
            self.assertEqual(environment["SEMREH_SLICE1_CREDENTIALS_FILE"], str(credentials))
            self.assertEqual(environment["SEMREH_SLICE2_TOOL_CWD"], str(tool_cwd))
            self.assertEqual(
                plan["TestConfigurations"][0]["TestTargets"][0]["OnlyTestIdentifiers"],
                ["LongChatScrollUITests/testOptInLiveProductionLoginNewChatSend"],
            )
            self.assertNotIn("SEMREH_SLICE3_CLARIFICATION_UI", environment)
            self.assertNotIn("SEMREH_SLICE3_BLOCKING_UI", environment)
            self.assertNotIn("SEMREH_SLICE3_COMPLETED_AWAY_NATIVE", environment)
            self.assertNotIn("password", output.getvalue().lower())

    def test_stock_ui_generation_exports_slice3_clarification_opt_in(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{
                    "TestTargets": [{"BlueprintName": "HermesMobileUITests"}],
                }],
            }))
            runtime = Path(temporary) / "stock-runtime"
            with patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "RUNTIME", runtime), \
                    patch.object(smoke, "validate") as validate, \
                    patch.object(smoke, "PIN", "29112bef099274229cadff79cdff7bf7b99c4b77"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice2-ui", "--stock-backend",
                        "--slice3-clarification",
                    ]):
                with redirect_stdout(StringIO()):
                    smoke.main()

            validate.assert_called_once_with()
            plan = plistlib.loads((products / "SemrehSlice2LiveUI.xctestrun").read_bytes())
            environment = plan["TestConfigurations"][0]["TestTargets"][0]["EnvironmentVariables"]
            self.assertEqual(environment["SEMREH_SLICE3_CLARIFICATION_UI"], "1")

    def test_stock_ui_generation_exports_slice3_attachment_opt_in(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{
                    "TestTargets": [{"BlueprintName": "HermesMobileUITests"}],
                }],
            }))
            runtime = Path(temporary) / "stock-runtime"
            with patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "RUNTIME", runtime), \
                    patch.object(smoke, "validate") as validate, \
                    patch.object(smoke, "PIN", "29112bef099274229cadff79cdff7bf7b99c4b77"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice2-ui", "--stock-backend",
                        "--slice3-attachment",
                    ]):
                with redirect_stdout(StringIO()):
                    smoke.main()

            validate.assert_called_once_with()
            plan = plistlib.loads((products / "SemrehSlice2LiveUI.xctestrun").read_bytes())
            environment = plan["TestConfigurations"][0]["TestTargets"][0]["EnvironmentVariables"]
            self.assertEqual(environment["SEMREH_SLICE3_ATTACHMENT_UI"], "1")

    def test_stock_ui_generation_exports_slice3_blocking_opt_in(self):
        smoke = load_smoke_module()
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{
                    "TestTargets": [{"BlueprintName": "HermesMobileUITests"}],
                }],
            }))
            runtime = Path(temporary) / "stock-runtime"
            with patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "RUNTIME", runtime), \
                    patch.object(smoke, "validate") as validate, \
                    patch.object(smoke, "PIN", "29112bef099274229cadff79cdff7bf7b99c4b77"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice2-ui", "--stock-backend",
                        "--slice3-blocking",
                    ]):
                with redirect_stdout(StringIO()):
                    smoke.main()

            validate.assert_called_once_with()
            plan = plistlib.loads((products / "SemrehSlice2LiveUI.xctestrun").read_bytes())
            target = plan["TestConfigurations"][0]["TestTargets"][0]
            environment = target["EnvironmentVariables"]
            self.assertEqual(environment["SEMREH_SLICE3_BLOCKING_UI"], "1")
            self.assertEqual(
                target["OnlyTestIdentifiers"],
                ["LongChatScrollUITests/testOptInLiveProductionLoginNewChatSend"],
            )

    def test_development_ui_generation_validates_exact_backend_and_paths(self):
        smoke = load_smoke_module()
        development_sha = "8c50f84522a755d40346e73701a6847fbdde20ec"
        with tempfile.TemporaryDirectory() as temporary:
            products = (Path(temporary) / "products").resolve()
            products.mkdir()
            source = products / "HermesMobileUIVerification_HermesMobileUIVerification_iphonesimulator.xctestrun"
            source.write_bytes(plistlib.dumps({
                "TestConfigurations": [{
                    "TestTargets": [{"BlueprintName": "HermesMobileUITests"}],
                }],
            }))
            runtime = Path(temporary) / "development-runtime"
            credentials = runtime / "credentials.json"
            tool_cwd = runtime / "tools"
            validator = Mock()
            development_module = SimpleNamespace(
                DEV_RUNTIME=runtime,
                _validate_all=validator,
            )
            with patch.dict(sys.modules, {"direct_hermes_development": development_module}), \
                    patch.object(smoke, "PRODUCTS", products), \
                    patch.object(smoke, "RUNTIME", Path(temporary) / "stock-runtime"), \
                    patch.object(sys, "argv", [
                        str(SCRIPT), "--https", "--slice2-ui",
                        "--development-backend-sha", development_sha,
                    ]):
                output = StringIO()
                with redirect_stdout(output):
                    smoke.main()

            validator.assert_called_once_with(development_sha)
            plan = plistlib.loads((products / "SemrehSlice2LiveUI.xctestrun").read_bytes())
            environment = plan["TestConfigurations"][0]["TestTargets"][0]["EnvironmentVariables"]
            self.assertEqual(environment["SEMREH_SLICE2_UI_BACKEND_MODE"], "development")
            self.assertEqual(environment["SEMREH_SLICE2_UI_BACKEND_SHA"], development_sha)
            self.assertEqual(environment["SEMREH_SLICE1_CREDENTIALS_FILE"], str(credentials))
            self.assertEqual(environment["SEMREH_SLICE2_TOOL_CWD"], str(tool_cwd))
            self.assertNotIn("password", output.getvalue().lower())

    def test_development_sha_cannot_select_an_unrelated_phase(self):
        self.assertRejected(
            ["--development-backend-sha", "not-a-real-sha"],
            "--development-backend-sha requires --slice2-reasoning or --slice2-ui",
        )


if __name__ == "__main__":
    unittest.main()
