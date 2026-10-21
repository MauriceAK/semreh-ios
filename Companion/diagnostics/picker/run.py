#!/usr/bin/env python3

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import threading
import time
from datetime import datetime, timezone


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
EVIDENCE = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "PickerDiagnosticEvidence"
RUNTIME_VERSION = "26.4.1"
RUNTIME_BUILD = "23E254a"
DEVICE_NAME = "iPhone 17 Pro"
PREDICATE = (
    'process CONTAINS[c] "Files" OR process CONTAINS[c] "Document" OR '
    'process CONTAINS[c] "fileprovider" OR process == "runningboardd" OR '
    'process == "launchd" OR process == "SpringBoard" OR '
    'subsystem CONTAINS[c] "DocumentManager" OR subsystem CONTAINS[c] "FileProvider" OR '
    'subsystem CONTAINS[c] "RunningBoard" OR subsystem CONTAINS[c] "FrontBoard" OR '
    'eventMessage CONTAINS[c] "DOCRemote" OR eventMessage CONTAINS[c] "documentpicker"'
)
CASES = (
    ("A-real-app", 115, (
        "-only-testing:HermesCompanionTests",
        "-skip-testing:HermesCompanionTests/AppleVoiceEngineTests",
        "-only-testing:HermesCompanionUITests/ChatPolishUITests/testAccessibilityLongDraftAndAttachmentStayInsideKeyboardViewport",
        "-only-testing:HermesCompanionUITests/ChatPolishUITests/testApprovalWithKeyboard",
        "-only-testing:HermesCompanionUITests/ChatPolishUITests/testComposerGeometryAndPickerCancellation",
    )),
    ("B-minimal-file-importer", 1, (
        "-only-testing:PickerControlUITests/PickerDiagnosticTests/testMinimalFileImporterCancellation",
    )),
    ("C-built-in-files", 1, (
        "-only-testing:PickerControlUITests/PickerDiagnosticTests/testBuiltInFilesBrowseAndSearch",
    )),
)


def now():
    return datetime.now(timezone.utc).isoformat()


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def command(args, output, timeout=60):
    output.parent.mkdir(parents=True, exist_ok=True)
    receipt = {"command": [str(arg) for arg in args], "started": now()}
    with output.open("wb") as log:
        process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            receipt["exit"] = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            receipt.update(exit=124, timed_out=True)
    receipt["finished"] = now()
    save(output.with_suffix(output.suffix + ".command.json"), receipt)
    return receipt["exit"]


def required(args, output, timeout=60):
    result = command(args, output, timeout)
    if result:
        raise RuntimeError(f"Command exited {result}: {args}; see {output}")
    return output.read_text()


def device_state(inventory, udid):
    return next((device["state"] for group in inventory["devices"].values()
                 for device in group if device["udid"] == udid), "Missing")


def read_device_state(udid, output):
    return device_state(json.loads(required(
        ["xcrun", "simctl", "list", "devices", "--json"], output, timeout=30)), udid)


def stream_complete(receipt):
    return bool(receipt.get("stopped_by_observer") or
                receipt.get("device_state") in ("Shutdown", "Shutting Down", "ShuttingDown"))


def verify_screenshot(folder, name, udid):
    manifest = json.loads((folder / "attachments/manifest.json").read_text())
    selector = CASES[0][2][-1] if name.startswith("A-") else next(case[2][0] for case in CASES if case[0] == name)
    test_id = "/".join(selector.split(":", 1)[1].split("/")[-2:]) + "()"
    candidates = []
    for test in manifest:
        if test.get("testIdentifier") != test_id:
            continue
        for attachment in test.get("attachments", []):
            filename = attachment.get("exportedFileName", "")
            path = folder / "attachments" / filename
            if (Path(filename).name == filename and path.suffix.lower() == ".png"
                    and attachment.get("deviceId") == udid
                    and attachment.get("suggestedHumanReadableName")
                    and isinstance(attachment.get("timestamp"), (int, float))
                    and path.is_file()):
                with path.open("rb") as source:
                    if source.read(8) == b"\x89PNG\r\n\x1a\n":
                        candidates.append(attachment)
    selected = max(candidates, key=lambda attachment: attachment["timestamp"], default=None)
    save(folder / "final-screen-attachment.json", {"testIdentifier": test_id, "attachment": selected})
    return selected is not None


def cleanup_device(udid, folder):
    state = read_device_state(udid, folder / "devices-before-shutdown.json")
    receipt = {"initial_state": state, "shutdown_exit": None}
    if state == "Booted":
        receipt["shutdown_exit"] = command(["xcrun", "simctl", "shutdown", udid], folder / "shutdown.txt")
        state = read_device_state(udid, folder / "devices-after-shutdown.json")
    deadline = time.monotonic() + 60
    sample = 0
    while state in ("Shutting Down", "ShuttingDown") and time.monotonic() < deadline:
        time.sleep(2)
        state = read_device_state(udid, folder / f"devices-shutdown-poll-{sample}.json")
        sample += 1
    receipt.update(final_state=state, shutdown_confirmed=state == "Shutdown")
    return receipt


def observe(udid, folder, stop, files_id):
    previous = None
    boot_process = None
    boot_log = None
    boot_finished = False
    stream_process = None
    stream_log = None
    stream_exit = None
    installed = False
    sample = 0
    try:
        while not stop.is_set():
            inventory = subprocess.run(
                ["xcrun", "simctl", "list", "devices", "--json"],
                capture_output=True, text=True, timeout=30, check=True,
            )
            state = device_state(json.loads(inventory.stdout), udid)
            if state != previous:
                with (folder / "boot-milestones.jsonl").open("a") as out:
                    out.write(json.dumps({"at": now(), "udid": udid, "state": state}) + "\n")
                previous = state
            if state == "Booted" and boot_process is None:
                boot_log = (folder / "bootstatus-observation.txt").open("wb")
                boot_process = subprocess.Popen(["xcrun", "simctl", "bootstatus", udid], stdout=boot_log, stderr=subprocess.STDOUT)
                save(folder / "bootstatus-start.json", {"at": now(), "policy": "Observation only, after Booted; no -b and no launch gate"})
                stream_log = (folder / "system-stream.ndjson").open("wb")
                stream_args = ["xcrun", "simctl", "spawn", udid, "log", "stream", "--level", "debug", "--style", "ndjson", "--predicate", PREDICATE]
                stream_process = subprocess.Popen(stream_args, stdout=stream_log, stderr=subprocess.STDOUT)
                save(folder / "system-stream-start.json", {"at": now(), "command": stream_args})
            if stream_process is not None and stream_exit is None and stream_process.poll() is not None:
                stream_exit = {"observed_at": now(), "exit": stream_process.returncode,
                               "stopped_by_observer": False, "device_state": state}
                save(folder / "system-stream-exit.json", stream_exit)
            if boot_process is not None and not boot_finished and boot_process.poll() is not None:
                save(folder / "bootstatus-exit.json", {"observed_at": now(), "exit": boot_process.returncode, "poll_target_seconds": 2, "note": "Observed completion; inventory and resource sampling can delay this timestamp."})
                boot_finished = True
            if state == "Booted" and not installed:
                apps_path = folder / "installed-apps.plist"
                if command(["xcrun", "simctl", "listapps", udid], apps_path, timeout=15) == 0:
                    required(["plutil", "-convert", "json", "-o", str(folder / "installed-apps.json"), str(apps_path)], folder / "convert-app-inventory.txt", timeout=15)
                    apps = json.loads((folder / "installed-apps.json").read_text())
                    save(folder / "files-installed-identity.json", {"at": now(), "bundle_id": files_id, "present": files_id in apps, "metadata": apps.get(files_id)})
                    installed = True
            if sample % 5 == 0 and not stop.is_set():
                with (folder / "resources.txt").open("ab") as out:
                    out.write(("\n" + now() + "\n").encode())
                    for args in (["ps", "-axo", "pid,ppid,pcpu,pmem,rss,comm"], ["vm_stat"], ["sysctl", "vm.loadavg"]):
                        subprocess.run(args, stdout=out, stderr=subprocess.STDOUT, timeout=10)
                if state == "Booted" and not stop.is_set():
                    with (folder / "simulator-processes.txt").open("ab") as out:
                        out.write(("\n" + now() + "\n").encode())
                        subprocess.run(["xcrun", "simctl", "spawn", udid, "launchctl", "list"], stdout=out, stderr=subprocess.STDOUT, timeout=10)
            sample += 1
            stop.wait(2)
    except Exception as error:
        save(folder / "observer-error.json", {"at": now(), "error": str(error)})
    finally:
        if boot_process is not None:
            if boot_process.poll() is None:
                boot_process.terminate()
            try:
                boot_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                boot_process.kill()
                boot_process.wait()
            if not boot_finished:
                save(folder / "bootstatus-exit.json", {"observed_at": now(), "exit": boot_process.returncode, "ended_with_observer": True})
            boot_log.close()
        if stream_process is not None:
            stopped_by_observer = stream_process.poll() is None
            if stream_exit is None:
                stream_exit = {"observed_at": now(), "exit": stream_process.returncode,
                               "stopped_by_observer": stopped_by_observer}
                if not stopped_by_observer:
                    try:
                        stream_exit["device_state"] = read_device_state(udid, folder / "devices-at-stream-exit.json")
                    except Exception as error:
                        stream_exit["state_error"] = str(error)
            if stopped_by_observer:
                stream_process.terminate()
            try:
                stream_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                stream_process.kill()
                stream_process.wait()
            stream_exit.update(exit=stream_process.returncode, reaped_at=now())
            save(folder / "system-stream-exit.json", stream_exit)
            stream_log.close()


def discover_files(runtime):
    runtime_root = Path(runtime["bundlePath"]) / "Contents/Resources/RuntimeRoot"
    candidates = []
    for info in (runtime_root / "Applications").glob("*.app/Info.plist"):
        metadata = plistlib.loads(info.read_bytes())
        if metadata.get("CFBundleDisplayName") == "Files" or metadata.get("CFBundleName") == "Files" or info.parent.name == "MobileDocuments.app":
            candidates.append({"path": str(info), "bundle_id": metadata["CFBundleIdentifier"], "name": metadata.get("CFBundleName"), "display_name": metadata.get("CFBundleDisplayName")})
    save(EVIDENCE / "files-runtime-candidates.json", candidates)
    if len(candidates) != 1:
        raise RuntimeError(f"Expected one observed Files app in the selected runtime, found {len(candidates)}")
    return candidates[0]["bundle_id"]


def hash_sources():
    paths = list((ROOT / "Companion/ios").rglob("*")) + list(HERE.rglob("*"))
    save(EVIDENCE / "source-sha256.json", {
        str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(paths) if path.is_file() and "__pycache__" not in path.parts
    })
    save(EVIDENCE / "production-source-sha256.json", {
        str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted((ROOT / "Companion/ios").rglob("*")) if path.is_file()
    })


def verify_test_tree(folder, name, udid):
    tree = json.loads((folder / "test-tree.json").read_text())
    expected = json.loads((HERE / "expected-tests.json").read_text())[name]
    observed = []

    def visit(node):
        if node.get("nodeType") == "Test Case":
            observed.append("/".join(node["nodeIdentifierURL"].split("/")[-3:]))
        for child in node.get("children", []):
            visit(child)

    for node in tree["testNodes"]:
        visit(node)
    devices = tree.get("devices", [])
    device_matches = bool(devices) and all(device.get("deviceId") == udid and device.get("osVersion") == RUNTIME_VERSION and device.get("osBuildNumber") == RUNTIME_BUILD for device in devices)
    log = (folder / "xcodebuild.log").read_text(errors="replace")
    starts = re.findall(r"Test Case '-\[([^ ]+) ([^\]]+)\]' started", log)
    ui_order = [method for class_name, method in starts if class_name.endswith("ChatPolishUITests")]
    expected_ui_order = [selector.rsplit("/", 1)[-1] for selector in CASES[0][2] if "/ChatPolishUITests/" in selector]
    started_ids = [class_name.replace(".", "/") + "/" + method for class_name, method in starts]
    expected_units = [test for test in expected if test.startswith("HermesCompanionTests/")]
    unit_prefix_matches = len(starts) == 115 and sorted(started_ids[:112]) == sorted(expected_units)
    baseline_context_matches = unit_prefix_matches and ui_order == expected_ui_order if name.startswith("A-") else True
    receipt = {"expected": expected, "observed": observed, "exact_ids_match": sorted(observed) == sorted(expected), "actual_devices": devices, "actual_device_matches_request": device_matches, "observed_start_order": started_ids, "observed_ui_start_order": ui_order, "expected_historical_ui_order": expected_ui_order if name.startswith("A-") else [], "historical_ui_order_matches": ui_order == expected_ui_order if name.startswith("A-") else None, "baseline_context_matches": baseline_context_matches}
    save(folder / "selection-readback.json", receipt)
    return receipt


def run_case(case, runtime_id, device_type, control_project, files_id):
    name, expected_count, selectors = case
    folder = EVIDENCE / name
    folder.mkdir()
    udid = required(["xcrun", "simctl", "create", f"PickerDiagnostic-{name}", device_type, runtime_id], folder / "created-device.txt").strip()
    save(folder / "case.json", {"case": name, "requested_udid": udid, "runtime": runtime_id, "created": now(), "expected_tests": expected_count, "selectors": selectors, "boot_policy": "xcodebuild automatic boot; fresh device, no Files prewarm"})
    required(["xcrun", "simctl", "list", "devices", "--json"], folder / "devices-before.json")
    project = ROOT / "Companion/ios/HermesCompanion.xcodeproj" if name.startswith("A-") else control_project
    scheme = "HermesCompanion" if name.startswith("A-") else "PickerControl"
    derived = Path(os.environ["RUNNER_TEMP"]) / f"PickerDerived-{name}"
    result_bundle = folder / "Tests.xcresult"
    args = ["xcodebuild", "test", "-project", str(project), "-scheme", scheme, "-configuration", "Debug",
            "-destination", f"platform=iOS Simulator,id={udid}", "-derivedDataPath", str(derived),
            "-resultBundlePath", str(result_bundle), "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            "-testLanguage", "en", "-testRegion", "US", *selectors, "DEVELOPMENT_TEAM=", "CODE_SIGN_IDENTITY=-"]
    stop = threading.Event()
    observer = threading.Thread(target=observe, args=(udid, folder, stop, files_id), daemon=True)
    observer.start()
    verdict = {"case": name, "requested_udid": udid, "expected_tests": expected_count, "passed": False, "tests_passed": False}
    try:
        verdict["test_exit"] = command(args, folder / "xcodebuild.log", timeout=900)
        stop.set()
        observer.join(timeout=90)
        verdict["observer_stopped"] = not observer.is_alive()
        state = read_device_state(udid, folder / "devices-after.json")
        verdict["post_test_device_state"] = state
        verdict["system_log_exit"] = None
        verdict["screenshot_exit"] = None
        if state == "Booted":
            verdict["system_log_exit"] = command(["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "20m", "--style", "ndjson", "--info", "--debug", "--predicate", PREDICATE], folder / "system-log.ndjson", timeout=120)
            verdict["screenshot_exit"] = command(["xcrun", "simctl", "io", udid, "screenshot", str(folder / "post-test-screen.png")], folder / "screenshot-command.txt")
        save(folder / "post-test-collection.json", {
            "at": now(), "device_state": state,
            "status": "attempted" if state == "Booted" else "unavailable",
            "reason": None if state == "Booted" else f"Device is {state}; no reboot for collection",
            "system_log_exit": verdict["system_log_exit"], "screenshot_exit": verdict["screenshot_exit"],
        })
        products = derived / "Build/Products"
        save(folder / "built-product-sha256.json", {
            str(path.relative_to(products)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in products.rglob("*") if path.is_file() and (os.access(path, os.X_OK) or path.suffix == ".xctestrun")
        })
        if result_bundle.exists():
            summary_exit = command(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result_bundle)], folder / "test-summary.json")
            verdict["test_tree_exit"] = command(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result_bundle)], folder / "test-tree.json")
            verdict["attachments_exit"] = command(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result_bundle), "--output-path", str(folder / "attachments")], folder / "export-attachments.txt", timeout=120)
            verdict["diagnostics_exit"] = command(["xcrun", "xcresulttool", "export", "diagnostics", "--path", str(result_bundle), "--output-path", str(folder / "test-diagnostics")], folder / "export-diagnostics.txt", timeout=120)
            if verdict["attachments_exit"] == 0:
                verdict["final_screen_verified"] = verify_screenshot(folder, name, udid)
            if verdict["test_tree_exit"] == 0:
                selection = verify_test_tree(folder, name, udid)
                verdict["selection_verified"] = selection["exact_ids_match"] and selection["actual_device_matches_request"]
                verdict["baseline_context_matches"] = selection["baseline_context_matches"]
            if summary_exit == 0:
                summary = json.loads((folder / "test-summary.json").read_text())
                verdict["summary"] = summary
                verdict["tests_passed"] = verdict["test_exit"] == 0 and summary.get("result") == "Passed" and summary.get("passedTests") == expected_count and summary.get("failedTests") == 0 and summary.get("skippedTests") == 0
        identity_path = folder / "files-installed-identity.json"
        verdict["files_identity_confirmed"] = identity_path.exists() and json.loads(identity_path.read_text())["present"]
        stream_exit = folder / "system-stream-exit.json"
        stream_valid = stream_exit.exists() and stream_complete(json.loads(stream_exit.read_text())) and (folder / "system-stream.ndjson").stat().st_size > 0
        verdict["evidence_complete"] = all((
            state == "Shutdown" or (state == "Booted" and verdict["system_log_exit"] == 0 and verdict["screenshot_exit"] == 0),
            stream_valid,
            verdict["observer_stopped"],
            verdict["files_identity_confirmed"],
            not (folder / "observer-error.json").exists(),
            verdict.get("selection_verified", False),
            verdict.get("baseline_context_matches", False),
            verdict.get("attachments_exit") == 0,
            verdict.get("diagnostics_exit") == 0,
            verdict.get("final_screen_verified", False),
            any(path.is_file() and path.stat().st_size for path in (folder / "test-diagnostics").rglob("*")),
        ))
        verdict["passed"] = verdict["tests_passed"] and verdict["evidence_complete"]
    except Exception as error:
        verdict.update(passed=False, error=str(error))
    finally:
        stop.set()
        observer.join(timeout=90)
        try:
            verdict.update(cleanup_device(udid, folder))
        except Exception as error:
            verdict.update(shutdown_confirmed=False, cleanup_error=str(error))
        verdict["passed"] = verdict["passed"] and verdict.get("shutdown_confirmed", False)
        save(folder / "verdict.json", verdict)
    return verdict


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise RuntimeError("This collects system evidence only on disposable GitHub-hosted runners.")
    if os.environ.get("GITHUB_REPOSITORY") != "MauriceAK/semreh-ios" or os.environ.get("GITHUB_REF") != "refs/heads/companion/picker-diagnostics-20261021":
        raise RuntimeError("Unexpected repository or branch.")
    EVIDENCE.mkdir(exist_ok=False)
    save(EVIDENCE / "runner.json", {key: os.environ.get(key) for key in ("GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "RUNNER_OS", "RUNNER_ARCH", "ImageOS", "ImageVersion", "DEVELOPER_DIR")})
    revision = required(["git", "rev-parse", "HEAD"], EVIDENCE / "revision.txt").strip()
    if revision != os.environ["GITHUB_SHA"]:
        raise RuntimeError("Checkout does not match workflow revision.")
    required(["git", "status", "--porcelain"], EVIDENCE / "git-status.txt")
    version = required(["xcodebuild", "-version"], EVIDENCE / "xcode-version.txt")
    if version.splitlines() != ["Xcode 26.6", "Build version 17F113"]:
        raise RuntimeError("This comparison requires the observed Xcode 26.6 build 17F113.")
    required(["sw_vers"], EVIDENCE / "macos-version.txt")
    runtimes = json.loads(required(["xcrun", "simctl", "list", "runtimes", "--json"], EVIDENCE / "runtimes.json"))["runtimes"]
    matches = [runtime for runtime in runtimes if runtime.get("version") == RUNTIME_VERSION and runtime.get("buildversion") == RUNTIME_BUILD and runtime.get("isAvailable")]
    if len(matches) != 1:
        raise RuntimeError("Required iOS 26.4.1 build 23E254a is unavailable; no substitution.")
    runtime = matches[0]
    device_types = json.loads(required(["xcrun", "simctl", "list", "devicetypes", "--json"], EVIDENCE / "device-types.json"))["devicetypes"]
    phones = [device for device in device_types if device["name"] == DEVICE_NAME]
    if len(phones) != 1:
        raise RuntimeError("Required iPhone 17 Pro device type is unavailable.")
    files_id = discover_files(runtime)
    manifest = json.loads((ROOT / "Companion/SOURCE.json").read_text())
    mismatches = []
    for entry in manifest["files"]:
        relative = Path(entry["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError("Invalid production manifest path.")
        if hashlib.sha256((ROOT / "Companion" / relative).read_bytes()).hexdigest() != entry["sha256"]:
            mismatches.append(str(relative))
    save(EVIDENCE / "production-manifest-check.json", {"source_revision": manifest["source_revision"], "checked": len(manifest["files"]), "mismatches": mismatches})
    if mismatches:
        raise RuntimeError("Production source differs from its existing delivery manifest.")
    hash_sources()
    control = Path(os.environ["RUNNER_TEMP"]) / "PickerControlSource"
    shutil.copytree(HERE, control)
    (control / "PickerControlUITests/FilesIdentity.swift").write_text("enum FilesIdentity { static let bundleIdentifier = " + json.dumps(files_id) + " }\n")
    save(EVIDENCE / "generated-files-identity.json", {"bundle_id": files_id, "swift_source": (control / "PickerControlUITests/FilesIdentity.swift").read_text()})
    results = []
    for case in CASES:
        try:
            results.append(run_case(case, runtime["identifier"], phones[0]["identifier"], control / "PickerControl.xcodeproj", files_id))
        except Exception as error:
            results.append({"case": case[0], "passed": False, "setup_error": str(error)})
        save(EVIDENCE / "comparison.json", results)
        if results[-1].get("observer_stopped") is False:
            break
    return 0 if len(results) == 3 and all(result["passed"] for result in results) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        EVIDENCE.mkdir(parents=True, exist_ok=True)
        save(EVIDENCE / "fatal.json", {"at": now(), "error": str(error)})
        raise
