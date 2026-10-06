#!/usr/bin/env python3
"""Export bounded, strictly filtered mounted-readiness metadata for CI diagnosis.

These private exports are excluded from the new safe artifact. The existing
failure-result artifact is unchanged. No raw strings, identifiers, images,
errors or attachment paths are copied into this uploaded JSON.
"""
import argparse
from itertools import islice
import json
import math
from pathlib import Path
import subprocess

CASES = (
    "testMountedSteerAcceptanceClearsUnchangedDraft",
    "testMountedSteerBackReopenRetiresOldCompletionOwnership",
    "testMountedSteerClearAndRetypeRetainsDraft",
    "testMountedSteerDelayedResponsesRetainInterveningEdit",
    "testMountedSteerRejectionAndTransportFailureRetainDraft",
)
PHASES = {"mounted composer", "startup: composer mounted", "startup: initial prompt running",
          "startup: initial draft cleared", "keyboard Send enabled"}
STATES = {"disconnected", "connecting", "ready", "stopped"}
METHODS = ("session.resume", "session.info", "prompt.submit", "session.steer",
           "session.status", "session.usage", "approval.pending")


def number(value):
    return value if (type(value) in (int, float) and abs(value) < 1e12
                     and math.isfinite(value)) else None


def boolean(value):
    return value if type(value) is bool else None


def fields(raw, keys, convert):
    return {key: convert(raw.get(key)) for key in keys} if isinstance(raw, dict) else {}


def label(value, allowed):
    return value if isinstance(value, str) and value in allowed else "unknown"


def state(value):
    if not isinstance(value, dict):
        return {}
    return {"uptime": number(value.get("uptime")),
            "runtimeState": label(value.get("runtimeState"), STATES),
            "starting": boolean(value.get("starting")), "activeRun": boolean(value.get("activeRun"))}


def filtered(raw):
    if not isinstance(raw, dict) or raw.get("schemaVersion") != 3:
        return None
    result = fields(raw, ("readinessWaitStartedAtUptime", "readinessElapsedSeconds", "stateCapturedAtUptime",
                          "transportSampledAtUptime", "transportSnapshotLagSeconds", "editorCount",
                          "applicationState", "sceneActivationState", "unlistedMethodCount"), number)
    result.update(fields(raw, ("routePresented", "windowIsKey", "windowIsHidden", "steerResponsePending"), boolean))
    phase = raw.get("phase")
    result["phase"] = label(phase, PHASES)
    result["model"] = fields(raw.get("model"), ("isStartingChat", "hasActiveRun", "hasSendError",
        "isEstablishingConnection", "hasPromptDeliveryUncertainty", "hasConfirmedAcceptance"), boolean)
    runtime = raw.get("runtime")
    if isinstance(runtime, dict):
        result["runtime"] = {"state": label(runtime.get("state"), STATES),
                             "connectionGeneration": number(runtime.get("connectionGeneration"))}
    connection = raw.get("mockConnectionProgress")
    result["mockConnectionProgress"] = fields(connection, ("enteredAtUptime", "returnedAtUptime",
        "identifierReadCount", "firstIdentifierReadAtUptime", "lastIdentifierReadAtUptime"), number)
    result["mockConnectionProgress"].update(fields(connection, ("isConnected",), boolean))
    result["rpcMethodCounts"] = fields(raw.get("rpcMethodCounts"), METHODS, number)
    progress = raw.get("readinessProgress")
    if isinstance(progress, dict):
        result["readinessProgress"] = fields(progress, ("pollCount", "maximumPollGapSeconds"), number)
        result["readinessProgress"].update(fields(progress, ("markerBeginWritten", "markerEndWritten"), boolean))
        result["readinessProgress"]["finalPollState"] = state(progress.get("finalPollState"))
        transitions = progress.get("runtimeTransitions")
        result["readinessProgress"]["runtimeTransitions"] = [state(item) for item in transitions[:16]] if isinstance(transitions, list) else []
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    destination = args.output / "safe/readiness.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        parser.error("refusing to overwrite a readiness receipt")
    report = {"schemaVersion": 1, "knownCaseCount": len(CASES), "diagnostics": [], "exportFailures": 0}
    if args.result.is_dir():
        (args.output / "private").mkdir(mode=0o700, exist_ok=True)
        for index, case in enumerate(CASES):
            private = args.output / "private" / f"readiness-{index + 1:02d}"
            try:
                # --only-failures omits keepAlways attachments in a child
                # activity whose assertion occurs later. Select the exact case.
                command = ["xcrun", "xcresulttool", "export", "attachments", "--path", str(args.result),
                           "--output-path", str(private), "--test-id", f"ChatTranscriptViewRestoreTests/{case}()"]
                exported = subprocess.run(command, stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL, timeout=30)
                if exported.returncode:
                    report["exportFailures"] += 1
                    continue
                for path in islice(private.iterdir(), 32):
                    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536 or path.name == "manifest.json":
                        continue
                    try:
                        receipt = filtered(json.loads(path.read_text()))
                    except (OSError, ValueError, UnicodeError, TypeError, RecursionError):
                        continue
                    if receipt is not None:
                        report["diagnostics"].append({"test": case, "receipt": receipt})
                        break
            except (OSError, subprocess.TimeoutExpired):
                report["exportFailures"] += 1
    else:
        report["unavailableReason"] = "result-bundle-not-present"
    destination.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")


if __name__ == "__main__":
    main()
