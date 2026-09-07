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
            "--stock-backend requires --slice2-reasoning, --slice2-ui, --slice3-file-picker, --slice3-completed-away, --slice3-relaunch, or --slice3-gateway-restart",
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
            "--slice3-relaunch-seed-text requires --slice3-relaunch or --slice3-app-kill and a bounded synthetic marker",
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
