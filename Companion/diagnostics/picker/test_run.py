import json
import os
from pathlib import Path
import tempfile
import plistlib
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
import unittest
from unittest.mock import Mock, patch

import run


class LifecycleTests(unittest.TestCase):
    def run_fixture(self, state="Shutdown", stream_state="Shutdown", test_exit=0, command_cleanup=True):
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
                run.save(folder / "observer-stopped.json", {"stream_observer_stopped": True, "boot_cleanup_complete": True, "command_cleanup_complete": command_cleanup})

            selection = {"exact_ids_match": True, "actual_device_matches_request": True, "baseline_context_matches": True}
            with patch.object(run, "EVIDENCE", root), patch.dict(os.environ, RUNNER_TEMP=directory), \
                    patch.object(run, "command", side_effect=fake_command) as commands, \
                    patch.object(run, "observe", side_effect=fake_observe), \
                    patch.object(run, "verify_test_tree", return_value=selection), \
                    patch.object(run, "verify_stream_coverage", return_value={"complete": stream_state != "Booted"}), \
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

    def test_unreaped_sampler_keeps_otherwise_complete_case_incomplete(self):
        verdict, _, _ = self.run_fixture(command_cleanup=False)
        self.assertTrue(verdict["tests_passed"])
        self.assertTrue(verdict["stream_coverage_complete"])
        self.assertFalse(verdict["evidence_complete"])
        self.assertFalse(verdict["passed"])

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



class FastStop:
    def __init__(self):
        self.event = threading.Event()
        self.samples = 0

    def is_set(self):
        return self.event.is_set()

    def set(self):
        self.event.set()

    def wait(self, delay):
        if delay == 2:
            self.samples += 1
            if self.samples == 6:
                self.set()
        return self.event.wait(0.002)


class ObserverTests(unittest.TestCase):
    def test_inventory_listapps_and_resource_faults_do_not_end_live_streams(self):
        stop = FastStop()
        processes = {}
        commands = []
        inventories = iter([None, {"devices": []}, "Booted", None, "Booted", "Booted"])
        installed_attempts = 0
        live_during_timeout = []

        class Process:
            def __init__(self, args, **kwargs):
                self.pid = 10000 + len(processes)
                self.returncode = 0 if "bootstatus" in args else None
                self.args = args
                processes[self.pid] = self

            def poll(self):
                return self.returncode

            def wait(self, timeout=None):
                if self.returncode is None:
                    raise subprocess.TimeoutExpired(self.args, timeout)
                return self.returncode

        def killpg(pid, sig):
            if processes[pid].returncode is not None:
                raise ProcessLookupError(pid)
            if sig:
                processes[pid].returncode = -sig

        def command(args, output, stop, timeout):
            nonlocal installed_attempts
            commands.append(args)
            if "devices" in args:
                value = next(inventories)
                if value is None:
                    time.sleep(0.01)
                    live_during_timeout.append([process.args for process in processes.values() if process.poll() is None])
                    run.save(output.with_suffix(".command.json"), {"timed_out": True})
                    return False
                run.save(output, {"devices": {"runtime": [{"udid": "owned", "state": value}]}} if isinstance(value, str) else value)
            elif "listapps" in args:
                installed_attempts += 1
                if installed_attempts == 1:
                    run.save(output.with_suffix(".command.json"), {"exit": 7})
                    return False
                elif installed_attempts == 2:
                    output.write_text("malformed plist")
                else:
                    output.write_bytes(plistlib.dumps({"files": {"CFBundleIdentifier": "files"}}))
            elif args[0] == "ps":
                run.save(output.with_suffix(".command.json"), {"timed_out": True})
                return False
            else:
                output.write_text("fixture")
            return True

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(run.subprocess, "Popen", side_effect=Process), \
                patch.object(run.os, "killpg", side_effect=killpg), \
                patch.object(run, "observe_command", side_effect=command):
            folder = Path(directory)
            run.observe("owned", folder, stop, "files")
            segments = json.loads((folder / "stream-segments.json").read_text())
            errors = [json.loads(line) for line in (folder / "observation-errors.jsonl").read_text().splitlines()]
            self.assertFalse((folder / "observer-error.json").exists())
            self.assertTrue(json.loads((folder / "files-installed-identity.json").read_text())["present"])
            self.assertEqual({error["collector"] for error in errors}, {"inventory", "listapps"})
            self.assertEqual({segment["kind"] for segment in segments}, {"host", "simulator"})
            self.assertTrue(all(segment["stopped_by_observer"] for segment in segments))
            self.assertTrue(json.loads((folder / "observer-stopped.json").read_text())["stream_observer_stopped"])
            self.assertIn("Unknown", (folder / "boot-milestones.jsonl").read_text())
        self.assertEqual(installed_attempts, 3)
        self.assertEqual(len(live_during_timeout), 2)
        self.assertTrue(all(any("spawn" in args for args in values) for values in live_during_timeout))
        self.assertTrue(all(process.poll() is not None for process in processes.values()))
        self.assertGreaterEqual(sum(args == ["vm_stat"] for args in commands), 2)
        self.assertTrue(any("launchctl" in args for args in commands))

    def test_hung_command_timeout_and_stop_reap_owned_process(self):
        for should_stop in (False, True):
            with self.subTest(stop=should_stop), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                stop = threading.Event()
                timer = threading.Timer(0.1, stop.set) if should_stop else None
                if timer:
                    timer.start()
                try:
                    result = run.observe_command([sys.executable, "-c", "import time; time.sleep(30)"], folder / "hang.txt", stop, 5 if should_stop else 0.1)
                finally:
                    if timer:
                        timer.join()
                receipt = json.loads((folder / "hang.txt.command.json").read_text())
                self.assertFalse(result)
                self.assertTrue(receipt["cancelled" if should_stop else "timed_out"])
                self.assertLess(receipt["exit"], 0)
                self.assertNotIn("cleanup_error", receipt)
                self.assertLess(receipt["finished"]["monotonic"] - receipt["started"]["monotonic"], 3)

    def test_exited_leader_does_not_leave_a_sleeping_descendant(self):
        with tempfile.TemporaryDirectory() as directory:
            ready = Path(directory) / "child.pid"
            child = "import os,signal,time; from pathlib import Path; signal.signal(signal.SIGTERM, signal.SIG_IGN); Path(" + repr(str(ready)) + ").write_text(str(os.getpid())); time.sleep(30)"
            leader = subprocess.Popen([sys.executable, "-c", "import subprocess,sys; subprocess.Popen([sys.executable, '-c', " + repr(child) + "])"] , start_new_session=True)
            try:
                self.assertEqual(leader.wait(timeout=3), 0)
                deadline = time.monotonic() + 3
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(ready.exists())
                child_pid = int(ready.read_text())
                os.kill(child_pid, 0)
                self.assertEqual(run.stop_process(leader), 0)
                with self.assertRaises(ProcessLookupError):
                    os.killpg(leader.pid, 0)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
            finally:
                try:
                    os.killpg(leader.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                leader.wait(timeout=3)

    def test_sampler_cleanup_error_is_aggregated_by_real_observer(self):
        stop = threading.Event()

        def command(args, output, stop, timeout):
            run.save(output.with_suffix(output.suffix + ".command.json"), {"cleanup_error": "owned group survived"})
            stop.set()
            return False

        with tempfile.TemporaryDirectory() as directory, patch.object(run, "observe_command", side_effect=command), \
                patch.object(run, "observe_streams", side_effect=lambda udid, folder, stop: stop.wait(3)):
            folder = Path(directory)
            run.observe("owned", folder, stop, "files")
            receipt = json.loads((folder / "observer-stopped.json").read_text())
        self.assertFalse(receipt["command_cleanup_complete"])
        self.assertEqual(len(receipt["command_cleanup_failures"]), 1)
        self.assertIn("owned group survived", receipt["command_cleanup_failures"][0]["error"])

    def test_nonzero_command_and_process_start_error_are_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            stop = threading.Event()
            self.assertFalse(run.observe_command([sys.executable, "-c", "raise SystemExit(9)"], folder / "exit.txt", stop, 2))
            self.assertEqual(json.loads((folder / "exit.txt.command.json").read_text())["exit"], 9)
            with patch.object(run.subprocess, "Popen", side_effect=OSError("fixture spawn failure")):
                self.assertFalse(run.observe_command(["fixture"], folder / "spawn.txt", stop, 2))
            self.assertIn("fixture spawn failure", json.loads((folder / "spawn.txt.command.json").read_text())["error"])

    def test_stream_setup_failure_is_retained_when_later_setup_succeeds(self):
        stop = threading.Event()
        clock = [0]
        processes = {}
        host_attempts = [0]

        def wait(_):
            clock[0] += 10
            if clock[0] == 30:
                stop.set()

        def popen(args, **kwargs):
            if args[0] == "/usr/bin/log":
                host_attempts[0] += 1
                if host_attempts[0] == 1:
                    raise OSError("fixture collector startup")
            process = Mock(pid=100 + len(processes), returncode=None)
            process.poll.side_effect = lambda: process.returncode
            process.wait.side_effect = lambda timeout=None: process.returncode
            processes[process.pid] = process
            return process

        def killpg(pid, sig):
            if processes[pid].returncode is not None:
                raise ProcessLookupError(pid)
            if sig:
                processes[pid].returncode = -sig

        with tempfile.TemporaryDirectory() as directory, patch.object(stop, "wait", side_effect=wait), \
                patch.object(run.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(run.subprocess, "Popen", side_effect=popen), patch.object(run.os, "killpg", side_effect=killpg):
            folder = Path(directory)
            run.observe_streams("owned", folder, stop)
            segments = json.loads((folder / "stream-segments.json").read_text())
        self.assertEqual(host_attempts[0], 2)
        self.assertEqual(len(segments), 3)
        self.assertIn("fixture collector startup", segments[0]["error"])
        self.assertEqual(segments[0]["finished"]["monotonic"], 0)
        self.assertEqual(segments[2]["started"]["monotonic"], 10)
        self.assertTrue(all(process.poll() is not None for process in processes.values()))

    def test_stream_natural_exit_is_preserved_and_does_not_stop_other_stream(self):
        stop = FastStop()
        processes = {}
        ticks = 0

        def wait(_):
            nonlocal ticks
            ticks += 1
            if ticks == 3:
                stop.set()
        stop.wait = wait

        def popen(args, **kwargs):
            process = Mock(pid=100 + len(processes), returncode=17 if "spawn" in args else None)
            process.poll.side_effect = lambda: process.returncode
            process.wait.side_effect = lambda timeout=None: process.returncode
            processes[process.pid] = process
            return process

        def killpg(pid, sig):
            if processes[pid].returncode is not None:
                raise ProcessLookupError(pid)
            if sig:
                processes[pid].returncode = -sig

        with tempfile.TemporaryDirectory() as directory, patch.object(run.subprocess, "Popen", side_effect=popen), patch.object(run.os, "killpg", side_effect=killpg):
            folder = Path(directory)
            run.observe_streams("owned", folder, stop)
            segments = json.loads((folder / "stream-segments.json").read_text())
        self.assertEqual(len(segments), 2)
        simulator = next(item for item in segments if item["kind"] == "simulator")
        host = next(item for item in segments if item["kind"] == "host")
        self.assertEqual(simulator["exit"], 17)
        self.assertFalse(simulator["stopped_by_observer"])
        self.assertTrue(host["stopped_by_observer"])


class PrefixTests(unittest.TestCase):
    def test_current_prefix_requires_exact_frozen_start_order(self):
        expected = json.loads((run.HERE / "expected-tests.json").read_text())["A-real-app"]
        self.assertEqual(run.CASES[0][1], len(expected))
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            run.save(folder / "test-tree.json", {"testNodes": [{"nodeType": "Test Case", "nodeIdentifierURL": "test://fixture/" + value} for value in expected],
                                               "devices": [{"deviceId": "owned", "osVersion": run.RUNTIME_VERSION, "osBuildNumber": run.RUNTIME_BUILD}]})
            for swapped in (False, True):
                order = list(expected)
                if swapped:
                    order[0], order[1] = order[1], order[0]
                (folder / "xcodebuild.log").write_text("\n".join("Test Case '-[" + value.rsplit("/", 1)[0].replace("/", ".") + " " + value.rsplit("/", 1)[1] + "]' started." for value in order))
                receipt = run.verify_test_tree(folder, "A-real-app", "owned")
                self.assertTrue(receipt["exact_ids_match"])
                self.assertEqual(receipt["baseline_context_matches"], not swapped)


class CoverageTests(unittest.TestCase):
    def fixture(self, folder, image="/System/DocumentManager", remote_pid="700", gap=False, events=True):
        def iso(seconds):
            return datetime.fromtimestamp(seconds, timezone.utc).isoformat()
        (folder / "attachments").mkdir()
        (folder / "attachments/ax.txt").write_text("Application, pid: 500\nOther <AX element pid: 700>")
        run.save(folder / "attachments/manifest.json", [{"testIdentifier": "PickerDiagnosticTests/testMinimalFileImporterCancellation()", "attachments": [
            {"exportedFileName": "recording.mp4", "timestamp": 100.0, "deviceId": "owned"},
            {"exportedFileName": "ax.txt", "timestamp": 110.0, "deviceId": "owned"},
        ]}])
        segments = []
        for kind in ("host", "simulator"):
            filename = kind + ".ndjson"
            segments.append({"kind": kind, "file": filename, "started": {"at": iso(99)}, "finished": {"at": iso(109 if gap else 111)}})
            lines = [{"timestamp": iso(t), "eventMessage": "fixture", "processID": remote_pid, "processImagePath": image} for t in (99, 105, 111)] if events else []
            (folder / filename).write_text("\n".join(json.dumps(value) for value in lines))
        run.save(folder / "stream-segments.json", segments)

    def test_interval_and_remote_identity_are_required(self):
        for options, complete in (({}, True), ({"gap": True}, False), ({"events": False}, False),
                                  ({"image": "/System/unrelated", "remote_pid": "999"}, False),
                                  ({"remote_pid": "999"}, False)):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                self.fixture(folder, **options)
                result = run.verify_stream_coverage(folder, "B-minimal-file-importer", "owned")
                self.assertEqual(result["complete"], complete)
                self.assertEqual(result["remote_ax_pids"], ["700"])

    def test_missing_recording_and_malformed_events_stay_incomplete(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            self.fixture(folder)
            (folder / "simulator.ndjson").write_text("not json\n{}\n[]\n")
            result = run.verify_stream_coverage(folder, "B-minimal-file-importer", "owned")
            self.assertFalse(result["complete"])
            self.assertEqual(result["segments"][1]["malformed_lines"], 3)
            run.save(folder / "attachments/manifest.json", [])
            self.assertFalse(run.verify_stream_coverage(folder, "B-minimal-file-importer", "owned")["complete"])

    def test_shutdown_after_stream_gap_cannot_make_coverage_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            self.fixture(folder, gap=True)
            segments = json.loads((folder / "stream-segments.json").read_text())
            for segment in segments:
                segment.update(stopped_by_observer=True, device_state="Shutdown")
            run.save(folder / "stream-segments.json", segments)
            self.assertFalse(run.verify_stream_coverage(folder, "B-minimal-file-importer", "owned")["complete"])


if __name__ == "__main__":
    unittest.main()
