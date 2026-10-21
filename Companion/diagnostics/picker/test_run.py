import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import run


class LifecycleTests(unittest.TestCase):
    def run_fixture(self, state="Shutdown", stream_state="Shutdown", test_exit=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            case = run.CASES[1]
            udid = "owned-device"

            def fake_command(args, output, timeout=60):
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text("fixture output")
                if args[:3] == ["xcrun", "simctl", "create"]:
                    output.write_text(udid)
                elif args[:4] == ["xcrun", "simctl", "list", "devices"]:
                    run.save(output, {"devices": {"runtime": [{"udid": udid, "state": state}]}})
                elif args[0] == "xcodebuild":
                    (output.parent / "Tests.xcresult").mkdir()
                    return test_exit
                elif "summary" in args:
                    run.save(output, {"result": "Passed", "passedTests": 1, "failedTests": 0, "skippedTests": 0})
                elif "attachments" in args:
                    attachments = output.parent / "attachments"
                    attachments.mkdir()
                    (attachments / "screen.png").write_bytes(b"\x89PNG\r\n\x1a\nfixture")
                    run.save(attachments / "manifest.json", [{
                        "testIdentifier": "PickerDiagnosticTests/testMinimalFileImporterCancellation()",
                        "attachments": [{"exportedFileName": "screen.png", "suggestedHumanReadableName": "minimal-final.png", "timestamp": 1, "deviceId": udid}],
                    }])
                elif "diagnostics" in args:
                    diagnostics = output.parent / "test-diagnostics"
                    diagnostics.mkdir()
                    (diagnostics / "session.log").write_text("fixture session")
                return 0

            def fake_observe(device, folder, stop, files_id):
                run.save(folder / "files-installed-identity.json", {"present": True})
                run.save(folder / "system-stream-exit.json", {
                    "exit": 0, "observed_at": "fixture", "stopped_by_observer": stream_state is None,
                    "device_state": stream_state,
                })
                (folder / "system-stream.ndjson").write_text('{"eventMessage": "fixture"}\n')

            selection = {"exact_ids_match": True, "actual_device_matches_request": True, "baseline_context_matches": True}
            with patch.object(run, "EVIDENCE", root), patch.dict(os.environ, RUNNER_TEMP=directory), \
                    patch.object(run, "command", side_effect=fake_command) as commands, \
                    patch.object(run, "observe", side_effect=fake_observe), \
                    patch.object(run, "verify_test_tree", return_value=selection), \
                    patch.object(run, "cleanup_device", return_value={"shutdown_confirmed": True, "shutdown_exit": None}):
                verdict = run.run_case(case, "runtime", "phone", root / "control.xcodeproj", "files")
            collection = json.loads((root / case[0] / "post-test-collection.json").read_text())
            return verdict, collection, [call.args[0] for call in commands.call_args_list]

    def test_shutdown_uses_exported_screen_without_post_test_simulator_commands(self):
        verdict, collection, commands = self.run_fixture()
        self.assertTrue(verdict["passed"])
        self.assertTrue(verdict["final_screen_verified"])
        self.assertEqual(collection["status"], "unavailable")
        self.assertIn("Shutdown", collection["reason"])
        self.assertFalse(any("spawn" in args or "screenshot" in args for args in commands))

    def test_booted_collects_retained_logs_and_screen(self):
        verdict, collection, commands = self.run_fixture(state="Booted", stream_state=None)
        self.assertTrue(verdict["passed"])
        self.assertEqual(collection["status"], "attempted")
        self.assertTrue(any("show" in args for args in commands))
        self.assertTrue(any("screenshot" in args for args in commands))

    def test_early_stream_death_remains_incomplete_after_later_shutdown(self):
        verdict, _, _ = self.run_fixture(stream_state="Booted")
        self.assertTrue(verdict["tests_passed"])
        self.assertFalse(verdict["evidence_complete"])
        self.assertFalse(verdict["passed"])

    def test_nonzero_test_exit_remains_failed_with_complete_evidence(self):
        verdict, _, _ = self.run_fixture(test_exit=65)
        self.assertEqual(verdict["test_exit"], 65)
        self.assertTrue(verdict["evidence_complete"])
        self.assertFalse(verdict["tests_passed"])
        self.assertFalse(verdict["passed"])

    def test_observer_keeps_first_stream_exit_state_after_shutdown(self):
        inventories = iter(["Booted", "Shutdown"])
        stop = Mock()
        stop.is_set.return_value = False
        polls = 0

        def wait(_):
            nonlocal polls
            polls += 1
            stop.is_set.return_value = polls == 2

        stop.wait.side_effect = wait

        def subprocess_run(args, **kwargs):
            state = next(inventories) if "devices" in args else "Shutdown"
            return Mock(stdout=json.dumps({"devices": {"runtime": [{"udid": "owned", "state": state}]}}))

        boot = Mock(returncode=0)
        boot.poll.return_value = 0
        stream = Mock(returncode=17)
        stream.poll.return_value = 17
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(run.subprocess, "run", side_effect=subprocess_run), \
                patch.object(run.subprocess, "Popen", side_effect=[boot, stream]), \
                patch.object(run, "command", return_value=1):
            folder = Path(directory)
            run.observe("owned", folder, stop, "files")
            receipt = json.loads((folder / "system-stream-exit.json").read_text())
        self.assertEqual(receipt["device_state"], "Booted")
        self.assertEqual(receipt["exit"], 17)
        self.assertFalse(run.stream_complete(receipt))
        stream.terminate.assert_not_called()

    def test_cleanup_requires_shutdown_readback_and_preserves_raw_exit(self):
        with patch.object(run, "read_device_state", side_effect=["Booted", "Shutdown"]), \
                patch.object(run, "command", return_value=405):
            result = run.cleanup_device("owned", Path("unused"))
        self.assertEqual(result["shutdown_exit"], 405)
        self.assertTrue(result["shutdown_confirmed"])
        with patch.object(run, "read_device_state", return_value="Shutdown"), patch.object(run, "command") as command:
            self.assertTrue(run.cleanup_device("owned", Path("unused"))["shutdown_confirmed"])
            command.assert_not_called()
        with patch.object(run, "read_device_state", side_effect=["Booted", "Booted"]), patch.object(run, "command", return_value=0):
            self.assertFalse(run.cleanup_device("owned", Path("unused"))["shutdown_confirmed"])

    def test_cleanup_waits_for_observed_shutdown(self):
        with patch.object(run, "read_device_state", side_effect=["Shutting Down", "Shutdown"]), \
                patch.object(run.time, "sleep"), patch.object(run, "command") as command:
            self.assertTrue(run.cleanup_device("owned", Path("unused"))["shutdown_confirmed"])
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
