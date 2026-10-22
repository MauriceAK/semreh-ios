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
    'eventMessage CONTAINS[c] "DOCRemote" OR eventMessage CONTAINS[c] "documentpicker" OR '
    'subsystem CONTAINS[c] "Accessibility" OR process CONTAINS[c] "AXUI" OR '
    'process CONTAINS[c] "accessibility"'
)
HOST_PREDICATE = (
    'subsystem CONTAINS[c] "CoreSimulator" OR process CONTAINS[c] "Simulator" OR '
    'subsystem CONTAINS[c] "Accessibility" OR process CONTAINS[c] "AXUI"'
)
CASES = (
    ("A-real-app", len(json.loads((HERE / "expected-tests.json").read_text())["A-real-app"]), (
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
    if not isinstance(inventory, dict) or not isinstance(inventory.get("devices"), dict):
        raise ValueError("Device inventory must contain a devices dictionary")
    for group in inventory["devices"].values():
        if not isinstance(group, list):
            raise ValueError("Device inventory runtime must contain a list")
        for device in group:
            if not isinstance(device, dict) or not isinstance(device.get("udid"), str) or not isinstance(device.get("state"), str):
                raise ValueError("Device inventory entry requires a UDID and state")
            if device["udid"] == udid:
                return device["state"]
    return "Missing"


def read_device_state(udid, output):
    return device_state(json.loads(required(
        ["xcrun", "simctl", "list", "devices", "--json"], output, timeout=30)), udid)


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


def stamp():
    return {"at": now(), "monotonic": time.monotonic()}


def append_receipt(path, value):
    with path.open("a") as out:
        out.write(json.dumps(value) + "\n")


def stop_process(process):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            process.wait(timeout=2)
            return process.returncode
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            process.poll()
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                process.wait(timeout=2)
                return process.returncode
            time.sleep(0.02)
    raise RuntimeError(f"Owned process group {process.pid} remains after SIGTERM and SIGKILL")


def observe_command(args, output, stop, timeout):
    receipt = {"command": args, "started": stamp()}
    process = None
    try:
        with output.open("wb") as log:
            process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                if stop.is_set() or time.monotonic() >= deadline:
                    receipt["cancelled" if stop.is_set() else "timed_out"] = True
                    break
                try:
                    process.wait(timeout=0.2)
                except subprocess.TimeoutExpired:
                    pass
            receipt["exit"] = process.returncode
    except Exception as error:
        receipt["error"] = repr(error)
    finally:
        if process is not None:
            try:
                receipt["exit"] = stop_process(process)
            except Exception as error:
                receipt["cleanup_error"] = repr(error)
        receipt["finished"] = stamp()
        save(output.with_suffix(output.suffix + ".command.json"), receipt)
    return receipt.get("exit") == 0 and not any(receipt.get(key) for key in ("error", "timed_out", "cancelled", "cleanup_error"))


def observe_streams(udid, folder, stop):
    streams = {
        "host": ["/usr/bin/log", "stream", "--level", "debug", "--style", "ndjson", "--predicate", HOST_PREDICATE],
        "simulator": ["xcrun", "simctl", "spawn", udid, "log", "stream", "--level", "debug", "--style", "ndjson", "--predicate", PREDICATE],
    }
    active = {}
    next_attempt = dict.fromkeys(streams, 0)
    segments = []

    def finish(kind, stopped):
        process, output, errors, receipt = active.pop(kind)
        receipt.update(stopped_by_observer=stopped, exit=process.poll())
        try:
            receipt["exit"] = stop_process(process)
        except Exception as error:
            receipt["cleanup_error"] = repr(error)
        receipt["finished"] = stamp()
        output.close()
        errors.close()
        save(folder / "stream-segments.json", segments)
        next_attempt[kind] = time.monotonic() + 10

    try:
        while not stop.is_set():
            for kind, args in streams.items():
                if kind in active and active[kind][0].poll() is not None:
                    finish(kind, False)
                if kind in active or time.monotonic() < next_attempt[kind] or stop.is_set():
                    continue
                number = sum(item["kind"] == kind for item in segments)
                filename = f"{kind}-stream-{number:03d}.ndjson"
                receipt = {"kind": kind, "udid": udid if kind == "simulator" else None,
                           "command": args, "file": filename, "started": stamp()}
                segments.append(receipt)
                output = (folder / filename).open("wb")
                errors = (folder / (filename + ".stderr")).open("wb")
                try:
                    process = subprocess.Popen(args, stdout=output, stderr=errors, start_new_session=True)
                    receipt["pid"] = process.pid
                    active[kind] = (process, output, errors, receipt)
                except Exception as error:
                    receipt.update(error=repr(error), finished=stamp())
                    output.close()
                    errors.close()
                    next_attempt[kind] = time.monotonic() + 10
                save(folder / "stream-segments.json", segments)
            stop.wait(0.2)
    except Exception as error:
        save(folder / "stream-observer-error.json", {**stamp(), "error": repr(error)})
    finally:
        for kind in list(active):
            finish(kind, active[kind][0].poll() is None)
        save(folder / "stream-observer-stopped.json", stamp())


def observe(udid, folder, stop, files_id):
    streams = threading.Thread(target=observe_streams, args=(udid, folder, stop), daemon=True)
    streams.start()
    previous = None
    installed = False
    sample = 0
    boot_process = None
    boot_log = None
    boot_receipt = None
    try:
        while not stop.is_set():
            state = "Unknown"
            inventory_path = folder / f"devices-sample-{sample:03d}.json"
            if observe_command(["xcrun", "simctl", "list", "devices", "--json"], inventory_path, stop, 30):
                try:
                    state = device_state(json.loads(inventory_path.read_text()), udid)
                except (ValueError, KeyError, TypeError) as error:
                    append_receipt(folder / "observation-errors.jsonl", {**stamp(), "collector": "inventory", "file": inventory_path.name, "error": repr(error)})
            if state != previous:
                append_receipt(folder / "boot-milestones.jsonl", {**stamp(), "udid": udid, "state": state})
                previous = state
            if state == "Booted" and boot_receipt is None and not stop.is_set():
                boot_log = (folder / "bootstatus-observation.txt").open("wb")
                boot_receipt = {"started": stamp(), "policy": "Observation only after Booted; no -b or test launch gate"}
                try:
                    boot_process = subprocess.Popen(["xcrun", "simctl", "bootstatus", udid], stdout=boot_log, stderr=subprocess.STDOUT, start_new_session=True)
                except Exception as error:
                    boot_receipt.update(error=repr(error), finished=stamp())
                save(folder / "bootstatus-observation.json", boot_receipt)
            if boot_process is not None and "finished" not in boot_receipt and boot_process.poll() is not None:
                boot_receipt.update(exit=boot_process.returncode, finished=stamp())
                save(folder / "bootstatus-observation.json", boot_receipt)
            if state == "Booted" and not installed and not stop.is_set():
                apps_path = folder / f"installed-apps-{sample:03d}.plist"
                if observe_command(["xcrun", "simctl", "listapps", udid], apps_path, stop, 15):
                    try:
                        apps = plistlib.loads(apps_path.read_bytes())
                        if not isinstance(apps, dict):
                            raise ValueError("Installed application inventory is not a dictionary")
                        save(folder / "files-installed-identity.json", {**stamp(), "bundle_id": files_id, "present": files_id in apps, "metadata": apps.get(files_id)})
                        installed = files_id in apps
                    except (ValueError, plistlib.InvalidFileException, TypeError) as error:
                        append_receipt(folder / "observation-errors.jsonl", {**stamp(), "collector": "listapps", "file": apps_path.name, "error": repr(error)})
            if sample % 5 == 0:
                for kind, args in (("processes", ["ps", "-axo", "pid,ppid,pcpu,pmem,rss,comm"]),
                                   ("memory", ["vm_stat"]), ("load", ["sysctl", "vm.loadavg"]),
                                   ("simulator-processes", ["xcrun", "simctl", "spawn", udid, "launchctl", "list"])):
                    if stop.is_set():
                        break
                    if kind != "simulator-processes" or state == "Booted":
                        observe_command(args, folder / f"{kind}-{sample:03d}.txt", stop, 10)
            sample += 1
            stop.wait(2)
    except Exception as error:
        save(folder / "observer-error.json", {**stamp(), "error": repr(error)})
    finally:
        stop.set()
        if boot_process is not None:
            try:
                boot_receipt.update(exit=stop_process(boot_process), reaped=stamp())
            except Exception as error:
                boot_receipt["cleanup_error"] = repr(error)
            save(folder / "bootstatus-observation.json", boot_receipt)
        if boot_log is not None:
            boot_log.close()
        streams.join(timeout=10)
        cleanup_failures = []
        for path in folder.glob("*.command.json"):
            receipt = json.loads(path.read_text())
            if receipt.get("cleanup_error"):
                cleanup_failures.append({"receipt": path.name, "error": receipt["cleanup_error"]})
        save(folder / "observer-stopped.json", {**stamp(), "stream_observer_stopped": not streams.is_alive(),
                                              "boot_cleanup_complete": boot_receipt is None or "cleanup_error" not in boot_receipt,
                                              "command_cleanup_complete": not cleanup_failures,
                                              "command_cleanup_failures": cleanup_failures})


def verify_stream_coverage(folder, name, udid):
    selector = next(case[2][-1] for case in CASES if case[0] == name)
    test_id = "/".join(selector.split(":", 1)[1].split("/")[-2:]) + "()"
    manifest = json.loads((folder / "attachments/manifest.json").read_text())
    attachments = [item for test in manifest if test.get("testIdentifier") == test_id
                   for item in test.get("attachments", []) if item.get("deviceId") == udid]
    recordings = [item["timestamp"] for item in attachments if str(item.get("exportedFileName", "")).endswith(".mp4")]
    observations = [item["timestamp"] for item in attachments if isinstance(item.get("timestamp"), (int, float))]
    interval = [min(recordings), max(observations)] if recordings and observations else None
    remote_pids = set()
    for attachment in attachments:
        filename = attachment.get("exportedFileName", "")
        if Path(filename).name != filename or not filename.endswith(".txt"):
            continue
        text = (folder / "attachments" / filename).read_text(errors="replace")
        roots = set(re.findall(r"Application,[^\n]+?pid: (\d+)", text))
        remote_pids.update(set(re.findall(r"<AX element pid: (\d+)", text)) - roots)
    segments_path = folder / "stream-segments.json"
    segments = json.loads(segments_path.read_text()) if segments_path.exists() else []
    summaries = []
    for segment in segments:
        event_count = 0
        first = None
        last = None
        identities = {}
        malformed = 0
        with (folder / segment["file"]).open(errors="replace") as event_log:
            for line in event_log:
                try:
                    event = json.loads(line)
                    timestamp = datetime.fromisoformat(event["timestamp"]).timestamp()
                    message = event["eventMessage"]
                    if not isinstance(message, str):
                        raise ValueError("Non-string event message")
                except (ValueError, KeyError, TypeError):
                    malformed += 1
                    continue
                event_count += 1
                first = timestamp if first is None else min(first, timestamp)
                last = timestamp if last is None else max(last, timestamp)
                image = event.get("processImagePath", event.get("process", ""))
                pid = str(event.get("processID", event.get("processIdentifier", "")))
                target = re.search(r"Files|Documents|DocumentManager|fileprovider", str(image), re.I)
                correlated = [value for value in remote_pids if pid == value or re.search(
                    r"(?:\bpid\s*[:=]?\s*|\bprocessID\s*[:=]\s*|[:<])" + value + r"(?=[\s>\]])", message, re.I)]
                if interval and interval[0] <= timestamp <= interval[1] and (target or correlated) and pid.isdigit():
                    identity = identities.setdefault(pid, {"image": image, "remote_ax_pids": [], "correlations": {}})
                    identity["remote_ax_pids"] = sorted(set(correlated) | set(identity["remote_ax_pids"]))
                    for value in correlated:
                        method = "process_id" if pid == value else "message_pid"
                        identity["correlations"][value] = sorted(set(identity["correlations"].get(value, [])) | {method})
        uninterrupted = bool(interval and segment.get("finished") and not segment.get("error") and not segment.get("cleanup_error")
                             and datetime.fromisoformat(segment["started"]["at"]).timestamp() <= interval[0]
                             and datetime.fromisoformat(segment["finished"]["at"]).timestamp() >= interval[1]
                             and first is not None and first <= interval[0] and last >= interval[1])
        target_covered = bool(identities) and (not remote_pids or any(value["remote_ax_pids"] for value in identities.values()))
        summaries.append({"file": segment["file"], "kind": segment["kind"], "events": event_count, "malformed_lines": malformed,
                          "first_event": first, "last_event": last, "uninterrupted_interval": uninterrupted,
                          "target_identities": identities, "target_covered": target_covered})
    host_covered = any(item["kind"] == "host" and item["uninterrupted_interval"] for item in summaries)
    simulator_covered = any(item["kind"] == "simulator" and item["uninterrupted_interval"] and item["target_covered"] for item in summaries)
    result = {"testIdentifier": test_id, "interval": interval, "interval_source": "recording start through final target attachment",
              "remote_ax_pids": sorted(remote_pids), "segments": summaries, "host_covered": host_covered,
              "simulator_covered": simulator_covered,
              "cleanup_complete": all("cleanup_error" not in segment for segment in segments),
              "complete": host_covered and simulator_covered and all("cleanup_error" not in segment for segment in segments)}
    save(folder / "stream-coverage.json", result)
    return result


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
    unit_prefix_matches = started_ids[:len(expected_units)] == expected_units
    baseline_context_matches = unit_prefix_matches and started_ids == expected and ui_order == expected_ui_order if name.startswith("A-") else True
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
        coverage = verify_stream_coverage(folder, name, udid)
        verdict["stream_coverage_complete"] = coverage["complete"]
        observer_receipt = folder / "observer-stopped.json"
        collectors_stopped = observer_receipt.exists() and all(json.loads(observer_receipt.read_text()).get(key) for key in ("stream_observer_stopped", "boot_cleanup_complete", "command_cleanup_complete"))
        verdict["evidence_complete"] = all((
            state == "Shutdown" or (state == "Booted" and verdict["system_log_exit"] == 0 and verdict["screenshot_exit"] == 0),
            verdict["stream_coverage_complete"],
            collectors_stopped,
            not (folder / "stream-observer-error.json").exists(),
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
