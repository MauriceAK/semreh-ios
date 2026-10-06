#!/usr/bin/env python3
"""Capped private samples of one exact Simulator test host during startup.

Diagnostic only: never changes the test process, predicate, deadline or exit code.
Run alongside xcodebuild and stop it when xcodebuild finishes. Raw stacks stay
worker-local; uploaded receipts contain only counts and predefined frame labels.
"""
import argparse
import ctypes
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import time

MARKER = Path("Library/Caches/semreh-mounted-startup.json")
BUNDLE_ID = "com.maurice.semreh"
MAX_SAMPLES = 4
TRIGGER_SECONDS = 2.0
running = True


def frame_labels(frame):
    """Never return symbols, addresses, paths or other text from the raw sample."""
    lower = frame.lower()
    symbol = lower.split("(in ", 1)[0]
    module = "unknown"
    for needle, label in (("(in hermesmobile", "app"), ("(in attributegraph)", "attributegraph"),
                          ("(in swiftui", "swiftui"), ("(in uikit", "uikit"),
                          ("(in libswift_concurrency", "swift-concurrency"),
                          ("(in libdispatch", "dispatch"), ("(in corefoundation", "corefoundation"),
                          ("(in xctest", "xctest")):
        if needle in lower:
            module = label
            break
    operation = "unknown"
    if module == "app":
        for type_token, methods, label in (
                ("musecomposerentrylayout", ("sizethatfits", "placesubviews"), "composer-layout"),
                ("composertextview", ("sizethatfits", "contentheight", "reportheight"), "composer-sizing"),
                ("composertextview", ("syncfocus", "synchronizeexternaltext"), "composer-focus-or-document"),
                ("pastingtextview", ("layoutsubviews",), "composer-focus-or-document"),
                ("chatnativetranscript", ("preferredlayoutattributesfitting", "didfit", "settlelayout"), "transcript-fit"),
                ("chatview.", ("senddraftmessage",), "send-entry"),
                ("chatviewmodel", ("senddirectmessage", "ensuredirectconversation"), "send-model"),
                ("hermesserverruntime", ("startconnection", "connect"), "runtime-connect"),
                ("gatewayconversationcontroller", ("ensurebinding", "resume", "applyresume"), "conversation-bind")):
            if type_token in symbol and any(method in symbol for method in methods):
                return module, label
    for needles, label in (
            (("mach_msg",), "message-wait"), (("semaphore_wait",), "semaphore-wait"),
            (("__psynch_mutexwait", "__ulock_wait"), "lock-wait"),
            (("cfRunLoopRun".lower(), "cfRunLoopServiceMachPort".lower()), "run-loop"),
            (("swift_task_switch", "swift_task_run", "swift_job_run"), "swift-task-execution"),
            (("ag::graph::updatestack::update", "ag::graph::update_attribute"), "attribute-update"),
            (("becomefirstresponder", "resignfirstresponder", "keyboard", "textinput", "textview"), "text-input"),
            (("sizethatfits", "layoutsubviews", "layoutifneeded", "sizein", "layout"), "layout"),
            (("updateviewgraph", "render", "viewbody", "bodyaccessor"), "view-update"),
            (("xctwaiter", "fulfillment", "waitforexpectations"), "test-wait")):
        if any(needle in symbol for needle in needles):
            operation = label
            break
    return module, operation


def safe_call_graph(raw):
    """Keep capped call-tree topology/counts, with literal labels only."""
    threads = []
    current = None
    in_graph = False
    for line in raw.splitlines():
        if line == "Call graph:":
            in_graph = True
            continue
        if not in_graph:
            continue
        if line.startswith("Total number in stack") or line.startswith("Sort by top of stack"):
            break
        clean = line.lstrip(" +!:|")
        header = re.match(r"^(\d+) Thread_\d+", clean)
        if header:
            if len(threads) >= 8:
                current = None
                continue
            current = {"index": len(threads) + 1, "mainThread": "com.apple.main-thread" in line,
                       "rootSamples": int(header[1]), "frames": [], "framesTruncated": False}
            threads.append(current)
            continue
        frame = re.match(r"^(\d+) (.+)$", clean)
        if current is not None and frame:
            if len(current["frames"]) >= 256:
                current["framesTruncated"] = True
                continue
            module, operation = frame_labels(frame[2])
            current["frames"].append({"depth": min(512, len(line) - len(clean)),
                                      "samples": int(frame[1]), "module": module, "operation": operation})
    return {"mainThreadIdentified": any(t["mainThread"] for t in threads), "threads": threads,
            "limits": "Capped call-tree frame counts are diagnostic weights, not compositor FPS or CPU percentages"}


def stop(_signum, _frame):
    global running
    running = False


def container(simulator, kind):
    try:
        result = subprocess.run(
            ["xcrun", "simctl", "get_app_container", simulator, BUNDLE_ID, kind],
            capture_output=True, text=True, timeout=3)
    except subprocess.TimeoutExpired:
        return None
    if result.returncode:
        return None
    path = Path(result.stdout.strip())
    if not path.is_absolute() or not path.is_dir():
        return None
    return path.resolve()


def marker(path):
    try:
        if path.is_symlink() or path.stat().st_size > 1024:
            return None
        value = json.loads(path.read_text())
        if (set(value) != {"schemaVersion", "phase", "token", "active", "pid", "uptime"}
                or value["schemaVersion"] != 1 or value["phase"] != "initial-prompt-running"
                or not isinstance(value["active"], bool)
                or not isinstance(value["pid"], int) or isinstance(value["pid"], bool) or value["pid"] <= 0
                or not isinstance(value["token"], str)
                or not re.fullmatch(r"[A-Fa-f0-9-]{36}", value["token"])
                or not isinstance(value["uptime"], (int, float))
                or isinstance(value["uptime"], bool) or not math.isfinite(value["uptime"])):
            return None
        return value
    except (OSError, ValueError, TypeError):
        return None


def process_path(pid):
    buffer = ctypes.create_string_buffer(4096)
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    libc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libc.proc_pidpath.restype = ctypes.c_int
    if libc.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        return None
    return Path(os.fsdecode(buffer.value)).resolve()


def process_birth(pid):
    # Public Darwin proc_bsdinfo layout (sys/proc_info.h), PROC_PIDTBSDINFO=3.
    class BSDInfo(ctypes.Structure):
        _fields_ = [("flagsAndIDs", ctypes.c_uint32 * 12),
                    ("command", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
                    ("filesAndGroups", ctypes.c_uint32 * 6),
                    ("startSeconds", ctypes.c_uint64), ("startMicroseconds", ctypes.c_uint64)]
    info = BSDInfo()
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    libc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                 ctypes.c_void_p, ctypes.c_int]
    libc.proc_pidinfo.restype = ctypes.c_int
    size = ctypes.sizeof(info)
    if libc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) != size or info.flagsAndIDs[3] != pid:
        return None
    return info.startSeconds * 1_000_000_000 + info.startMicroseconds * 1000


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Fa-f0-9-]{36}", args.simulator):
        parser.error("expected exact Simulator UDID")
    args.output.mkdir(parents=True, exist_ok=False)
    private_output = args.output / "private"
    safe_output = args.output / "safe"
    private_output.mkdir(mode=0o700)
    safe_output.mkdir()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    receipt = {"schemaVersion": 1, "simulator": args.simulator,
               "triggerSecondsAfterFirstObservation": TRIGGER_SECONDS,
               "maximumSamples": MAX_SAMPLES, "sampleDurationSeconds": 1,
               "sampleIntervalMilliseconds": 10, "samples": [], "guardFailures": 0,
               "markersSeen": 0, "containersResolved": False}
    data = bundle = None
    observed = None
    observed_at = 0.0
    observed_birth = None
    sampled = set()
    seen = set()
    deadline = time.monotonic() + 3600
    try:
        while running and time.monotonic() < deadline and len(receipt["samples"]) < MAX_SAMPLES:
            if data is None or bundle is None:
                data = container(args.simulator, "data")
                bundle = container(args.simulator, "app")
                if data is None or bundle is None:
                    time.sleep(0.5)
                    continue
                receipt["containersResolved"] = True
            current = marker(data / MARKER)
            key = (current["pid"], current["token"]) if current and current["active"] else None
            if key != observed:
                observed, observed_at = key, time.monotonic()
                observed_birth = process_birth(current["pid"]) if key else None
            if key and key not in seen:
                seen.add(key)
                receipt["markersSeen"] += 1
            if key and key not in sampled and time.monotonic() - observed_at >= TRIGGER_SECONDS:
                # Both containers come from the same UDID as xcodebuild. Require
                # the actual PID executable to match that exact bundle leaf.
                if (process_path(current["pid"]) != (bundle / "HermesMobile").resolve()
                        or observed_birth is None or process_birth(current["pid"]) != observed_birth
                        or (data / MARKER).stat().st_mtime_ns < observed_birth):
                    receipt["guardFailures"] += 1
                    sampled.add(key)
                    continue
                latest = marker(data / MARKER)
                if not latest or not latest["active"] or (latest["pid"], latest["token"]) != key:
                    continue
                sampled.add(key)
                index = len(receipt["samples"]) + 1
                output = private_output / f"sample-{index:02d}.private.txt"
                record = {"index": index, "pid": current["pid"],
                          "markerUptimeAtObservation": current["uptime"],
                          "observedElapsedSecondsAtTrigger": time.monotonic() - observed_at,
                          "ownedExecutableVerified": True, "processBirthRevalidated": True,
                          "samePhaseActiveAtSampleStart": True}
                started = time.monotonic()
                try:
                    result = subprocess.run(["/usr/bin/sample", str(current["pid"]), "1", "10",
                                             "-file", str(output)], capture_output=True, timeout=10)
                    record["exitCode"] = result.returncode
                except subprocess.TimeoutExpired:
                    record["sampleTimedOut"] = True
                ended = marker(data / MARKER)
                record["durationSeconds"] = time.monotonic() - started
                record["samePhaseStillActiveAtSampleEnd"] = bool(
                    ended and ended["active"] and (ended["pid"], ended["token"]) == key)
                record["bytes"] = output.stat().st_size if output.is_file() else 0
                if 0 < record["bytes"] <= 8 * 1024 * 1024:
                    record["safeCallGraph"] = safe_call_graph(output.read_text(errors="replace"))
                else:
                    record["unavailableReason"] = "raw-sample-missing-or-exceeds-8MiB"
                receipt["samples"].append(record)
            time.sleep(0.05)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        # Diagnostics cannot convert a failing test into a pass or a pass into
        # a failure; keep only the exception type, without tool output/paths.
        receipt["watcherErrorType"] = type(error).__name__
    finally:
        if not receipt["containersResolved"]:
            receipt["unavailableReason"] = "owned-app-containers-not-resolved"
        elif not receipt["markersSeen"]:
            receipt["unavailableReason"] = "no-active-startup-marker-observed"
        elif not receipt["samples"]:
            receipt["unavailableReason"] = "no-owned-active-phase-reached-trigger"
        receipt["stopped"] = True
        (safe_output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
