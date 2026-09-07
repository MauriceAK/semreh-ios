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


def load_smoke_module():
    spec = importlib.util.spec_from_file_location("direct_hermes_ios_smoke", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class IOSSmokeGuardTests(unittest.TestCase):
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
            "--stock-backend requires --slice2-reasoning, --slice2-ui, or --slice3-completed-away",
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
            message,
        )

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
            self.assertNotIn("password", output.getvalue().lower())

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
