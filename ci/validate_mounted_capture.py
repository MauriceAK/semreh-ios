#!/usr/bin/env python3
"""One hosted-CI sampler capability check on a fresh, explicitly supplied Simulator.

Run after the authoritative suite, on a separate disposable diagnostic device.
This is not an acceptance test. It mounts the existing server-free Debug lab;
the lab may write synthetic app state, which the owned uninstall removes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import time

from watch_mounted_startup import (BUNDLE_ID, bounded_private_text, capture_sample,
                                   process_birth, process_path, sample_status_categories)


class PreflightUnavailable(Exception):
    pass


def is_simulator_bundle(bundle, simulator):
    """Bind the resolved installation to this exact default CoreSimulator device."""
    devices = (Path.home() / "Library/Developer/CoreSimulator/Devices").resolve()
    root = devices / simulator / "data/Containers/Bundle/Application"
    try:
        relative = bundle.resolve().relative_to(root)
    except ValueError:
        return False
    return (len(relative.parts) == 2 and relative.parts[1] == "HermesMobile.app"
            and re.fullmatch(r"[A-Fa-f0-9-]{36}", relative.parts[0]) is not None)


def executable_hashes(bundle):
    result = {}
    for name in ("HermesMobile", "HermesMobile.debug.dylib"):
        path = bundle / name
        if name == "HermesMobile" and not path.is_file():
            raise ValueError("missing-executable")
        if path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            result[name] = digest.hexdigest()
    return result


def valid_bundle(bundle):
    path = bundle / "Info.plist"
    if not path.is_file() or path.stat().st_size > 1024 * 1024:
        return False
    with path.open("rb") as stream:
        info = plistlib.load(stream)
    return (info.get("CFBundleIdentifier") == BUNDLE_ID
            and info.get("CFBundleExecutable") == "HermesMobile"
            and "iPhoneSimulator" in info.get("CFBundleSupportedPlatforms", []))


def process_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def run_private(stage, command, private, receipt, timeout=15):
    """Bounded control command; only static stage/status metadata is public."""
    stdout, stderr = (private / f"{stage}.{kind}.private.txt" for kind in ("stdout", "stderr"))
    record = {"stage": stage}
    started = time.monotonic()
    with stdout.open("xb") as out, stderr.open("xb") as err:
        os.chmod(stdout, 0o600)
        os.chmod(stderr, 0o600)
        try:
            result = subprocess.run(command, stdout=out, stderr=err, timeout=timeout)
            record["exitCode"] = result.returncode
        except subprocess.TimeoutExpired:
            # subprocess.run kills and reaps this exact child before raising.
            record["timedOut"] = True
        except OSError:
            record["launchFailed"] = True
    record["durationSeconds"] = time.monotonic() - started
    output = bounded_private_text(stdout)
    error = bounded_private_text(stderr)
    record["stdoutBytes"] = stdout.stat().st_size
    record["stderrBytes"] = stderr.stat().st_size
    record["stderrStatus"] = sample_status_categories(error) if error is not None else ["output-unreadable-or-exceeds-8MiB"]
    receipt["steps"].append(record)
    return record.get("exitCode") == 0, output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Fa-f0-9-]{36}", args.simulator):
        parser.error("expected exact Simulator UDID")
    output = args.output.resolve()
    cwd = Path.cwd().resolve()
    if output == cwd or not output.is_relative_to(cwd):
        parser.error("output must be a fresh child of the working directory")
    output.mkdir(parents=True, exist_ok=False)
    private, safe = output / "private", output / "safe"
    private.mkdir(mode=0o700)
    safe.mkdir()
    receipt = {"schemaVersion": 1, "simulator": args.simulator,
               "diagnosticOnly": True, "captureSucceeded": False,
               "cleanupSucceeded": True, "steps": [], "installedByPreflight": False,
               "sampleDurationSeconds": 1, "sampleIntervalMilliseconds": 10,
               "sampleTimeoutSeconds": 30, "maximumSamples": 1}
    app = args.app.resolve()
    installed = None
    source_hashes = None
    install_attempted = launch_attempted = False
    pid = birth = None
    executable = None

    def control(stage, *arguments, timeout=15):
        return run_private(stage, ["xcrun", "simctl", *arguments], private, receipt, timeout)

    def app_inventory(stage):
        ok, raw = control(stage, "listapps", args.simulator)
        if not ok or raw is None:
            return None
        try:
            return json.loads(raw)
        except ValueError:
            # simctl versions may emit an OpenStep property list instead of JSON.
            ok, converted = run_private(stage + "-json", ["/usr/bin/plutil", "-convert", "json", "-o", "-",
                str(private / f"{stage}.stdout.private.txt")], private, receipt)
            return json.loads(converted) if ok and converted else None

    def installed_matches():
        return (installed is not None and is_simulator_bundle(installed, args.simulator)
                and valid_bundle(installed)
                and executable_hashes(installed) == source_hashes)

    def owned_process():
        return (pid is not None and birth is not None and process_path(pid) == executable
                and process_birth(pid) == birth)

    try:
        if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
            receipt["unavailableReason"] = "requires-github-hosted-ci"
            return 0
        if app.name != "HermesMobile.app" or app.parent.name != "Debug-iphonesimulator" or not valid_bundle(app):
            receipt["unavailableReason"] = "invalid-debug-simulator-bundle"
            return 0
        source_hashes = executable_hashes(app)
        receipt["inputExecutableSHA256"] = source_hashes
        ok, raw = control("devices", "list", "devices", "available", "--json")
        devices = json.loads(raw).get("devices", {}) if ok and raw else {}
        exact = [device for runtime, group in devices.items() if "iOS" in runtime
                 for device in group if device.get("udid") == args.simulator]
        if len(exact) != 1 or exact[0].get("state") != "Booted" or not exact[0].get("isAvailable"):
            receipt["unavailableReason"] = "exact-available-booted-ios-device-required"
            return 0
        apps = app_inventory("installed-apps")
        if not isinstance(apps, dict) or BUNDLE_ID in apps:
            receipt["unavailableReason"] = "existing-app-or-unproven-absence"
            return 0
        receipt["initialAppAbsenceVerified"] = True
        install_attempted = True
        receipt["cleanupSucceeded"] = False
        ok, _ = control("install", "install", args.simulator, str(app), timeout=30)
        # Even a timed-out install may have installed the app; bind it before cleanup.
        found, raw = control("installed-container", "get_app_container", args.simulator, BUNDLE_ID, "app")
        if found and raw:
            candidate = Path(raw.strip())
            if candidate.is_absolute() and candidate.is_dir():
                if not is_simulator_bundle(candidate, args.simulator):
                    receipt["unavailableReason"] = "installed-container-outside-selected-simulator"
                    raise PreflightUnavailable
                installed = candidate.resolve()
        if not installed_matches():
            receipt["unavailableReason"] = "installed-bundle-not-bound"
            raise PreflightUnavailable
        receipt["installedByPreflight"] = True
        receipt["installedExecutableSHA256"] = executable_hashes(installed)
        executable = (installed / "HermesMobile").resolve()
        if not ok:
            receipt["unavailableReason"] = "install-command-failed"
            raise PreflightUnavailable
        launch_attempted = True
        launch_wall_ns = time.time_ns()
        ok, raw = control("launch", "launch", args.simulator, BUNDLE_ID, "--chat-performance-lab", timeout=30)
        match = re.fullmatch(re.escape(BUNDLE_ID) + r": ([1-9][0-9]{0,9})\s*", raw.strip()) if ok and raw else None
        if not match or int(match[1]) > 2_147_483_647:
            receipt["unavailableReason"] = "launch-pid-unavailable"
            raise PreflightUnavailable
        pid = int(match[1])
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            candidate_birth = process_birth(pid)
            if (process_path(pid) == executable and candidate_birth is not None
                    and launch_wall_ns <= candidate_birth <= time.time_ns()):
                birth = candidate_birth
                break
            time.sleep(0.05)
        if not owned_process():
            receipt["unavailableReason"] = "launched-process-not-bound"
            raise PreflightUnavailable
        receipt["ownedExecutableVerified"] = True
        receipt["processBirthVerified"] = True
        ok, raw = run_private("launch-arguments", ["/bin/ps", "-ww", "-p", str(pid), "-o", "command="], private, receipt)
        receipt["labArgumentVerified"] = bool(ok and raw and "--chat-performance-lab" in raw.split())
        if not receipt["labArgumentVerified"] or not owned_process():
            receipt["unavailableReason"] = "lab-argument-or-process-revalidation-failed"
            raise PreflightUnavailable
        receipt["sample"] = capture_sample(pid, private, 1, timeout=30)
        sample = receipt["sample"]
        receipt["sameOwnedProcessAfterSample"] = owned_process()
        graph = sample.get("safeCallGraph", {})
        receipt["captureSucceeded"] = bool(sample.get("exitCode") == 0 and not sample.get("sampleTimedOut")
            and receipt["sameOwnedProcessAfterSample"]
            and graph.get("mainThreadIdentified") and any(t.get("frames") for t in graph.get("threads", [])))
    except PreflightUnavailable:
        pass
    except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException) as error:
        receipt["diagnosticErrorType"] = type(error).__name__
    finally:
        if install_attempted:
            try:
                may_uninstall = installed_matches()
                if launch_attempted:
                    if pid is not None and not process_exists(pid):
                        receipt["ownedProcessAlreadyExited"] = True
                    elif owned_process():
                        os.kill(pid, signal.SIGTERM)
                        deadline = time.monotonic() + 10
                        while process_exists(pid) and time.monotonic() < deadline:
                            time.sleep(0.05)
                        may_uninstall = may_uninstall and not process_exists(pid)
                        receipt["ownedProcessTerminated"] = not process_exists(pid)
                    else:
                        may_uninstall = False
                        receipt["cleanupBlockedReason"] = "launched-process-ownership-unproven"
                if may_uninstall:
                    ok, raw = control("cleanup-container", "get_app_container", args.simulator, BUNDLE_ID, "app")
                    if ok and raw and Path(raw.strip()).resolve() == installed and installed_matches():
                        removed, _ = control("uninstall", "uninstall", args.simulator, BUNDLE_ID, timeout=30)
                        apps = app_inventory("cleanup-apps")
                        receipt["cleanupSucceeded"] = bool(removed and isinstance(apps, dict) and BUNDLE_ID not in apps)
                if not receipt["cleanupSucceeded"]:
                    receipt.setdefault("cleanupBlockedReason", "owned-install-removal-not-verified")
            except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException) as error:
                receipt["cleanupErrorType"] = type(error).__name__
        (safe / "validation.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return 0 if receipt["cleanupSucceeded"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
