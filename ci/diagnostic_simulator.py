#!/usr/bin/env python3
"""Own one hosted-only diagnostic Simulator after the scored full suite fails."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


def require(condition):
    if not condition:
        raise ValueError("diagnostic Simulator ownership guard failed")


def hosted():
    require(os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted")
    require(re.fullmatch(r"[0-9]+", os.environ.get("GITHUB_RUN_ID", ""))
            and re.fullmatch(r"[0-9]+", os.environ.get("GITHUB_RUN_ATTEMPT", "")))


def sdk(*arguments, timeout=30):
    result = subprocess.run(["xcrun", "simctl", *arguments], capture_output=True,
                            text=True, timeout=timeout)
    require(result.returncode == 0)
    return result.stdout.strip()


def devices():
    data = json.loads(sdk("list", "devices", "--json"))
    return {item["udid"]: (runtime, item)
            for runtime, group in data["devices"].items() for item in group}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("create", "cleanup"))
    parser.add_argument("--source")
    parser.add_argument("--ownership", required=True, type=Path)
    args = parser.parse_args()
    try:
        hosted()
        path = args.ownership.absolute()
        require(path.is_relative_to(Path.cwd()) and ".." not in path.parts
                and path.name == "ownership.json"
                and not any(p.is_symlink() for p in (path, *path.parents)))
        if args.operation == "create":
            require(re.fullmatch(r"[A-Fa-f0-9-]{36}", args.source or "") and not path.exists())
            require(shutil.disk_usage(Path.cwd()).free > 3 * 1024**3)
            before = devices()
            require(args.source in before)
            runtime, source = before[args.source]
            device_type = source.get("deviceTypeIdentifier", "")
            require(source.get("isAvailable") is True
                    and re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+", runtime)
                    and re.fullmatch(r"com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-[A-Za-z0-9-]+", device_type))
            path.parent.mkdir(parents=True, exist_ok=False)
            label = "Semreh Mounted Diagnostics " + os.environ["GITHUB_RUN_ID"]
            identifier = sdk("create", label, device_type, runtime)
            require(re.fullmatch(r"[A-Fa-f0-9-]{36}", identifier) and identifier not in before)
            owner = {"schemaVersion": 1, "id": identifier, "name": label,
                     "runtime": runtime, "deviceType": device_type,
                     "source": args.source, "run": os.environ["GITHUB_RUN_ID"],
                     "attempt": os.environ["GITHUB_RUN_ATTEMPT"], "createdAt": time.time()}
            with path.open("x") as stream:
                json.dump(owner, stream, indent=2)
            # Publish ownership before boot, so a failed boot is still cleaned up.
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write("id=" + identifier + "\n")
            sdk("boot", identifier)
            sdk("bootstatus", identifier, "-b", timeout=120)
            actual_runtime, actual = devices()[identifier]
            require(actual_runtime == runtime and actual["name"] == label
                    and actual.get("deviceTypeIdentifier") == device_type and actual["state"] == "Booted")
            print(json.dumps({"created": True, "id": identifier, "separateFromScoredSimulator": True}))
        else:
            require(path.is_file() and path.stat().st_size < 4096)
            owner = json.loads(path.read_text())
            require(owner.get("schemaVersion") == 1 and owner.get("run") == os.environ["GITHUB_RUN_ID"]
                    and owner.get("attempt") == os.environ["GITHUB_RUN_ATTEMPT"]
                    and re.fullmatch(r"[A-Fa-f0-9-]{36}", owner.get("id", ""))
                    and owner["id"] != owner.get("source")
                    and owner.get("name") == "Semreh Mounted Diagnostics " + owner["run"])
            existing = devices().get(owner["id"])
            if existing is not None:
                runtime, device = existing
                require(runtime == owner["runtime"] and device["name"] == owner["name"]
                        and device.get("deviceTypeIdentifier") == owner["deviceType"])
                if device["state"] != "Shutdown":
                    sdk("shutdown", owner["id"])
                sdk("delete", owner["id"])
                require(owner["id"] not in devices())
            print(json.dumps({"cleanedUp": True, "alreadyAbsent": existing is None}))
    except (OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"operation": args.operation, "completed": False,
                          "errorType": type(error).__name__}))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
