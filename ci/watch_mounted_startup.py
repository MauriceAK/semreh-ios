#!/usr/bin/env python3
"""Capped private samples of one exact Simulator test host during startup.

Diagnostic only: preserves test logic and exit code; sampling can perturb timing.
Run alongside xcodebuild and stop it when xcodebuild finishes. Raw stacks stay
worker-local; uploaded receipts contain only counts and predefined frame labels.
"""
import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import shlex
import stat
import subprocess
import time
import uuid

MARKER = Path("Library/Caches/semreh-mounted-startup.json")
BUNDLE_ID = "com.maurice.semreh"
MAX_SAMPLES = 1
MAX_PHASES = 32
TRIGGER_SECONDS = 0.5
MAX_MARKER_AGE_SECONDS = 30.0
MAX_MARKER_UPTIME_SECONDS = 10 * 365 * 24 * 60 * 60
MAX_CAPTURE_BYTES = 8 * 1024 * 1024
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


def bounded_private_text(path):
    """Read only a bounded regular private file; never follow a replaced symlink."""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode) or not 0 <= metadata.st_size <= MAX_CAPTURE_BYTES:
                return None
            raw = stream.read(MAX_CAPTURE_BYTES + 1)
            return raw.decode(errors="replace") if len(raw) <= MAX_CAPTURE_BYTES else None
    except OSError:
        return None


def sample_status_categories(raw):
    """Literal categories only: never export sampler messages, symbols or paths."""
    lower = raw.lower()
    categories = []
    for needles, category in (
            (("operation not permitted", "permission denied", "requires root"), "permission-denied"),
            (("task_for_pid", "unable to get task", "failed to get task"), "task-port-unavailable"),
            (("no such process", "process not found", "does not exist"), "process-unavailable"),
            (("sampling process",), "sampling-started"),
            (("analyzing sample", "analysis of sampling"), "analysis-started"),
            (("sample analysis of process", "sample saved", "written to"), "sample-output-reported"),
            (("usage: sample",), "usage-error")):
        if any(needle in lower for needle in needles):
            categories.append(category)
    return categories or (["unclassified-output"] if raw.strip() else ["empty-output"])


def host_uptime_seconds():
    # Match ProcessInfo.systemUptime explicitly. Python monotonic is used only
    # for command duration, never assumed to be the marker's clock domain.
    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    library.mach_absolute_time.restype = ctypes.c_uint64
    timebase = Timebase()
    if library.mach_timebase_info(ctypes.byref(timebase)) != 0 or not timebase.denom:
        raise ValueError("host-uptime-unavailable")
    return library.mach_absolute_time() * timebase.numer / timebase.denom / 1_000_000_000


def capture_sample(pid, private_output, index, timeout):
    """One sampler invocation. Raw stack/stdout/stderr stay in the private directory."""
    output = private_output / f"sample-{index:02d}.private.txt"
    stdout = private_output / f"sample-{index:02d}.stdout.private.txt"
    stderr = private_output / f"sample-{index:02d}.stderr.private.txt"
    record = {}
    started = time.monotonic()
    record["captureLaunchMonotonicSeconds"] = started
    record["captureLaunchUptimeSeconds"] = host_uptime_seconds()
    with stdout.open("xb") as out, stderr.open("xb") as err:
        os.chmod(stdout, 0o600)
        os.chmod(stderr, 0o600)
        try:
            result = subprocess.run(["/usr/bin/sample", str(pid), "2", "10", "-file", str(output)],
                                    stdout=out, stderr=err, timeout=timeout)
            record["exitCode"] = result.returncode
        except subprocess.TimeoutExpired:
            record["sampleTimedOut"] = True
        except OSError:
            record["sampleLaunchFailed"] = True
    record["captureReturnMonotonicSeconds"] = time.monotonic()
    record["captureReturnUptimeSeconds"] = host_uptime_seconds()
    record["durationSeconds"] = record["captureReturnMonotonicSeconds"] - started
    if output.is_file() and not output.is_symlink():
        os.chmod(output, 0o600)
    record["bytes"] = output.stat().st_size if output.is_file() else 0
    raw = bounded_private_text(output)
    if raw:
        record["safeCallGraph"] = safe_call_graph(raw)
    else:
        record["unavailableReason"] = "raw-sample-missing-empty-or-exceeds-8MiB"
    for name, path in (("stdout", stdout), ("stderr", stderr)):
        record[name + "Bytes"] = path.stat().st_size
        raw = bounded_private_text(path)
        record[name + "Status"] = sample_status_categories(raw) if raw is not None else ["output-unreadable-or-exceeds-8MiB"]
    return record


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
    if not path.is_absolute() or not path.is_dir() or path.is_symlink() or path.resolve() != path:
        return None
    device = Path.home() / "Library/Developer/CoreSimulator/Devices" / simulator
    try:
        relative = path.relative_to(device)
    except ValueError:
        return None
    expected = ("data", "Containers", "Data" if kind == "data" else "Bundle", "Application")
    if (relative.parts[:4] != expected or len(relative.parts) != (5 if kind == "data" else 6)
            or not exact_uuid(relative.parts[4])
            or (kind != "data" and relative.parts[5] != "HermesMobile.app")):
        return None
    return path


def exact_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value.lower()
    except (ValueError, AttributeError):
        return False


def marker(path):
    try:
        # Atomic writer replacement cannot pair one marker's bytes with another
        # marker's timestamp: read and fstat the same non-symlink descriptor.
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= 1024:
                return None
            raw = stream.read(1025)
            after = os.fstat(stream.fileno())
            if (len(raw) != before.st_size or before.st_size != after.st_size
                    or before.st_mtime_ns != after.st_mtime_ns):
                return None
        value = json.loads(raw)
        if (set(value) != {"schemaVersion", "phase", "token", "active", "pid", "uptime"}
                or value["schemaVersion"] != 1 or value["phase"] != "initial-prompt-running"
                or not isinstance(value["active"], bool)
                or not isinstance(value["pid"], int) or isinstance(value["pid"], bool)
                or not 0 < value["pid"] <= 2_147_483_647
                or not isinstance(value["token"], str)
                or not exact_uuid(value["token"])
                or not isinstance(value["uptime"], (int, float))
                or isinstance(value["uptime"], bool)
                or not 0 <= value["uptime"] <= MAX_MARKER_UPTIME_SECONDS
                or not math.isfinite(value["uptime"])):
            return None
        value["_mtime_ns"] = before.st_mtime_ns
        return value
    except (OSError, ValueError, TypeError):
        return None


def marker_age(value, now_ns=None):
    """Both timestamps use this host's filesystem/wall clock, not app uptime."""
    age = ((time.time_ns() if now_ns is None else now_ns) - value["_mtime_ns"]) / 1_000_000_000
    if not math.isfinite(age):
        return None, "nonfinite-file-age"
    if age < 0:
        return None, "future-file-time"
    if age > MAX_MARKER_AGE_SECONDS:
        return None, "implausible-file-age"
    return age, None


def observe_phase(receipt, phases, value, age, age_guard, now, watch_started):
    """Capped safe ledger; private dictionary keys never enter the receipt."""
    if not value:
        return None
    key = (value["pid"], value["token"])
    existing = phases.get(key)
    if not value["active"]:
        if existing and not existing["record"]["endMarkerObserved"]:
            record = existing["record"]
            record["endMarkerObserved"] = True
            record["endMarkerUptime"] = value["uptime"]
            record["endObservedElapsedSeconds"] = now - watch_started
            record["maximumWatcherGapSeconds"] = max(
                record["maximumWatcherGapSeconds"], now - existing["last_seen"])
            existing["last_seen"] = now
        return None
    if existing is None:
        if len(phases) >= MAX_PHASES:
            receipt["phaseLedgerTruncated"] = True
            return None
        record = {"index": len(phases) + 1, "markerUptime": value["uptime"],
                  "firstObservedElapsedSeconds": now - watch_started,
                  "firstObservedFileAgeSeconds": age, "observationCount": 0,
                  "maximumWatcherGapSeconds": 0.0, "endMarkerObserved": False,
                  "ageGuard": None}
        existing = {"record": record, "last_seen": now}
        phases[key] = existing
        receipt["phases"].append(record)
        receipt["markersSeen"] += 1
    record = existing["record"]
    record["observationCount"] += 1
    record["maximumWatcherGapSeconds"] = max(record["maximumWatcherGapSeconds"], now - existing["last_seen"])
    record["lastObservedElapsedSeconds"] = now - watch_started
    record["lastObservedFileAgeSeconds"] = age
    if age_guard and record["ageGuard"] != age_guard:
        receipt["guardFailures"] += 1
    record["ageGuard"] = age_guard
    existing["last_seen"] = now
    return record


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



MACHO_MAGIC = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def file_sha(path):
    if path.is_symlink() or path.resolve() != path or not path.is_file():
        raise ValueError("identity-file-unavailable")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bounded_plist(path):
    if path.is_symlink() or path.resolve() != path:
        raise ValueError("identity-plist-unavailable")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or not 0 < metadata.st_size <= 1024 * 1024:
            raise ValueError("identity-plist-unavailable")
        raw = stream.read(1024 * 1024 + 1)
        if len(raw) != metadata.st_size:
            raise ValueError("identity-plist-changed")
    value = plistlib.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("identity-plist-not-dictionary")
    return value


def implementation_hashes(bundle):
    if bundle.is_symlink() or bundle.resolve() != bundle or not bundle.is_dir():
        raise ValueError("identity-bundle-unavailable")
    result = {}
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink():
            raise ValueError("identity-bundle-symlink")
        if path.is_file():
            with path.open("rb") as stream:
                is_macho = stream.read(4) in MACHO_MAGIC
            if is_macho:
                result[str(path.relative_to(bundle))] = file_sha(path)
    if "HermesMobile" not in result:
        raise ValueError("identity-executable-missing")
    return result


def signing_status(path):
    # Contributor CI intentionally disables bundle signing. Record that honestly;
    # identical implementation hashes remain mandatory for every sample.
    result = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)],
                            capture_output=True, text=True, timeout=8)
    if result.returncode == 0:
        return "verified"
    lower = result.stderr.lower()
    return "unsigned" if "not signed" in lower else "unverified"


def diagnostic_owner(path, simulator):
    path = path.absolute()
    if (not path.is_relative_to(Path.cwd()) or path.is_symlink() or path.resolve() != path
            or not path.is_file() or path.stat().st_size > 4096):
        raise ValueError("owned-diagnostic-receipt-unavailable")
    owner = json.loads(path.read_text())
    if (os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or owner.get("schemaVersion") != 1 or owner.get("id") != simulator
            or owner.get("source") == simulator
            or owner.get("run") != os.environ.get("GITHUB_RUN_ID")
            or owner.get("attempt") != os.environ.get("GITHUB_RUN_ATTEMPT")
            or owner.get("name") != "Semreh Mounted Diagnostics " + owner.get("run", "")):
        raise ValueError("owned-diagnostic-receipt-mismatch")
    return file_sha(path)


def built_identity(app, scheme):
    app = app.absolute()
    if (scheme != "HermesMobile" or not app.is_relative_to(Path.cwd())
            or app.parts[-4:] != ("Build", "Products", "Debug-iphonesimulator", "HermesMobile.app")):
        raise ValueError("built-host-scheme-mismatch")
    info = bounded_plist(app / "Info.plist")
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != "HermesMobile":
        raise ValueError("built-host-info-mismatch")
    return {"implementation": implementation_hashes(app), "infoSHA256": file_sha(app / "Info.plist"),
            "executableSigningStatus": signing_status(app / "HermesMobile"),
            "bundleSigningStatus": signing_status(app)}


def actual_host_identity(pid, bundle, data, expected, watch_started_ns):
    birth = process_birth(pid)
    executable = process_path(pid)
    if (birth is None or birth < watch_started_ns or executable != bundle / "HermesMobile"):
        raise ValueError("owned-process-birth-or-executable-mismatch")
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "args="],
                            capture_output=True, text=True, timeout=3)
    arguments = shlex.split(result.stdout.strip()) if result.returncode == 0 else []
    if not arguments or arguments[0] != str(executable) or arguments.count("--semreh-unit-test-host") != 1:
        raise ValueError("owned-unit-host-arguments-mismatch")
    metadata = bounded_plist(data / ".com.apple.mobile_container_manager.metadata.plist")
    if metadata.get("MCMMetadataIdentifier") != BUNDLE_ID:
        raise ValueError("owned-data-container-mismatch")
    if (implementation_hashes(bundle) != expected["implementation"]
            or file_sha(bundle / "Info.plist") != expected["infoSHA256"]):
        raise ValueError("installed-built-implementation-mismatch")
    executable_signing = signing_status(executable)
    bundle_signing = signing_status(bundle)
    if (expected["executableSigningStatus"] == "verified" and executable_signing != "verified"
            or expected["bundleSigningStatus"] == "verified" and bundle_signing != "verified"):
        raise ValueError("installed-signature-weakened")
    if process_birth(pid) != birth or process_path(pid) != executable:
        raise ValueError("owned-process-changed-during-verification")
    return {"birthNanoseconds": birth, "argvSHA256": hashlib.sha256(
                json.dumps(arguments, separators=(",", ":")).encode()).hexdigest(),
            "executableSHA256": expected["implementation"]["HermesMobile"],
            "installedExecutableSigningStatus": executable_signing,
            "installedBundleSigningStatus": bundle_signing}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--observe-only", action="store_true", help="Record marker observations without invoking sample")
    parser.add_argument("--built-app", type=Path)
    parser.add_argument("--scheme")
    parser.add_argument("--ownership", type=Path)
    parser.add_argument("--max-samples", type=int, default=MAX_SAMPLES)
    parser.add_argument("--sample-timeout", type=int, default=10)
    args = parser.parse_args()
    if not exact_uuid(args.simulator):
        parser.error("expected exact Simulator UDID")
    if not 1 <= args.max_samples <= MAX_SAMPLES:
        parser.error("max-samples must be exactly 1")
    if not 5 <= args.sample_timeout <= 10:
        parser.error("sample-timeout must be between 5 and 10 seconds")
    if not args.observe_only and not (args.built_app and args.scheme and args.ownership):
        parser.error("sampling requires built app, scheme and separate owned diagnostic Simulator receipt")
    args.output.mkdir(parents=True, exist_ok=False)
    private_output = args.output / "private"
    safe_output = args.output / "safe"
    private_output.mkdir(mode=0o700)
    safe_output.mkdir()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    watch_started_ns = time.time_ns()
    receipt = {"schemaVersion": 4, "simulator": args.simulator, "observeOnly": args.observe_only,
               "triggerMarkerFileAgeSeconds": TRIGGER_SECONDS,
               "maximumMarkerFileAgeSeconds": MAX_MARKER_AGE_SECONDS,
               "maximumSamples": 0 if args.observe_only else args.max_samples, "sampleDurationSeconds": 2,
               "sampleTimeoutSeconds": args.sample_timeout,
               "sampleIntervalMilliseconds": 10, "samples": [], "guardFailures": 0,
               "markersSeen": 0, "containersResolved": False,
               "maximumPhases": MAX_PHASES, "phases": [], "phaseLedgerTruncated": False,
               "observationLimits": "Watcher gaps include identity checks and sampling; phase ledger continues after cap. Launch/return bound the sampling command, not each stack timestamp.",
               "perturbedDiagnosticOnly": not args.observe_only, "acceptanceResult": False,
               "markerCaptureClockDomain": "host mach_absolute_time seconds / ProcessInfo.systemUptime"}
    data = bundle = None
    expected = None
    baseline_key = None
    sampled = set()
    phases = {}
    sampling_disabled = args.observe_only
    watch_started = time.monotonic()
    deadline = watch_started + 3600
    try:
        if not args.observe_only:
            receipt["ownedDiagnosticReceiptSHA256"] = diagnostic_owner(args.ownership, args.simulator)
            expected = built_identity(args.built_app, args.scheme)
            receipt["builtIdentity"] = {"scheme": args.scheme,
                "executableSHA256": expected["implementation"]["HermesMobile"],
                "implementationMapSHA256": hashlib.sha256(json.dumps(expected["implementation"], sort_keys=True).encode()).hexdigest(),
                "executableSigningStatus": expected["executableSigningStatus"],
                "bundleSigningStatus": expected["bundleSigningStatus"]}
        while running and time.monotonic() < deadline:
            if data is None or bundle is None:
                data = container(args.simulator, "data")
                bundle = container(args.simulator, "app")
                if data is None or bundle is None:
                    time.sleep(0.5)
                    continue
                receipt["containersResolved"] = True
                baseline = marker(data / MARKER)
                baseline_key = ((baseline["pid"], baseline["token"]) if baseline
                    and baseline["_mtime_ns"] < watch_started_ns else None)
            current = marker(data / MARKER)
            age, age_guard = marker_age(current) if current else (None, None)
            phase = observe_phase(receipt, phases, current, age, age_guard, time.monotonic(), watch_started)
            key = (current["pid"], current["token"]) if current and current["active"] else None
            if (not sampling_disabled and phase and key not in sampled and len(receipt["samples"]) < args.max_samples
                    and age is not None and age >= TRIGGER_SECONDS):
                # Only a new marker from the actual focused XCTest host on the
                # separately owned diagnostic device can authorize a sample.
                if key == baseline_key or current["_mtime_ns"] < watch_started_ns:
                    continue
                verification_started = time.monotonic()
                try:
                    before_identity = actual_host_identity(current["pid"], bundle, data, expected, watch_started_ns)
                    if current["_mtime_ns"] < before_identity["birthNanoseconds"]:
                        raise ValueError("marker-predates-owned-process")
                except (OSError, ValueError, subprocess.TimeoutExpired):
                    receipt["guardFailures"] += 1
                    sampled.add(key)
                    continue
                latest = marker(data / MARKER)
                latest_age, latest_guard = marker_age(latest) if latest else (None, None)
                if (not latest or not latest["active"] or (latest["pid"], latest["token"]) != key
                        or latest["_mtime_ns"] != current["_mtime_ns"]):
                    continue
                if latest_guard or latest_age < TRIGGER_SECONDS:
                    receipt["guardFailures"] += 1
                    sampled.add(key)
                    continue
                sampled.add(key)
                index = len(receipt["samples"]) + 1
                phase["sampleIndex"] = index
                record = {"index": index, "phaseIndex": phase["index"], "pid": current["pid"],
                          "markerUptimeAtObservation": current["uptime"],
                          "markerFileAgeSecondsAtTrigger": latest_age,
                          "observedElapsedSecondsAtTrigger": time.monotonic() - watch_started - phase["firstObservedElapsedSeconds"],
                          "identityVerificationSecondsBeforeCapture": time.monotonic() - verification_started,
                          "processBirthNanoseconds": before_identity["birthNanoseconds"],
                          "argvSHA256": before_identity["argvSHA256"],
                          "ownedExecutableVerified": True, "processBirthRevalidated": True,
                          "installedBuiltImplementationVerified": True,
                          "unitHostFlagVerified": True, "signingStatus": {key: value for key, value in before_identity.items() if key.endswith("SigningStatus")},
                          "samePhaseActiveAtSampleStart": True}
                record.update(capture_sample(current["pid"], private_output, index, timeout=args.sample_timeout))
                try:
                    after_identity = actual_host_identity(current["pid"], bundle, data, expected, watch_started_ns)
                    record["sameIdentityVerifiedAfterSample"] = (
                        after_identity == before_identity
                        and diagnostic_owner(args.ownership, args.simulator) == receipt["ownedDiagnosticReceiptSHA256"]
                        and built_identity(args.built_app, args.scheme) == expected
                        and container(args.simulator, "data") == data
                        and container(args.simulator, "app") == bundle)
                except (OSError, ValueError, subprocess.TimeoutExpired):
                    record["sameIdentityVerifiedAfterSample"] = False
                if not record["sameIdentityVerifiedAfterSample"]:
                    record.pop("safeCallGraph", None)
                    record["unavailableReason"] = "post-sample-identity-unproven"
                if record.get("sampleTimedOut"):
                    sampling_disabled = True
                    receipt["samplingDisabledReason"] = "first-sample-timeout"
                ended = marker(data / MARKER)
                ended_age, ended_guard = marker_age(ended) if ended else (None, None)
                observe_phase(receipt, phases, ended, ended_age, ended_guard, time.monotonic(), watch_started)
                record["samePhaseStillActiveAtSampleEnd"] = bool(
                    ended and ended["active"] and (ended["pid"], ended["token"]) == key)
                receipt["samples"].append(record)
            time.sleep(0.05)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        # Diagnostics cannot convert a failing test into a pass or a pass into
        # a failure; keep only the exception type, without tool output/paths.
        receipt["watcherErrorType"] = type(error).__name__
    finally:
        for sample in receipt["samples"]:
            phase_record = receipt["phases"][sample["phaseIndex"] - 1]
            end_uptime = phase_record.get("endMarkerUptime")
            sample["markerCaptureBoundingIntersectionSeconds"] = (
                max(0.0, min(sample["captureReturnUptimeSeconds"], end_uptime)
                    - max(sample["captureLaunchUptimeSeconds"], phase_record["markerUptime"]))
                if end_uptime is not None else None)
            sample["markerEndObserved"] = end_uptime is not None
        if not receipt["containersResolved"]:
            receipt["unavailableReason"] = "owned-app-containers-not-resolved"
        elif not receipt["markersSeen"]:
            receipt["unavailableReason"] = "no-active-startup-marker-observed"
        elif not receipt["samples"] and not args.observe_only:
            receipt["unavailableReason"] = "no-owned-active-phase-reached-trigger"
        receipt["stopped"] = True
        (safe_output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
