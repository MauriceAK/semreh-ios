#!/usr/bin/env python3
"""Fail-closed Semreh Simulator smoothness evidence exporter (stdlib only).

Input is a JSON manifest with `runs`, one object per scenario/variant/repetition.
Each run names an xcresult, app_binary, callback_report (the opt-in UI test
attachment), events (its JSON attachment), native-timestamp video, motion_csv,
and memory_csv. A pre-build source stamp, app/xctestrun hashes, and hashes of
annotated evidence bind each run. XCTest and RSS use raw Mach seconds;
video PTS stays in its own domain. Motion CSV:
video_pts_seconds,phase,row_id,row_y_points (five or more native-timestamp
observations of one identifiable row per measured phase). Memory CSV:
clock_domain,mach_absolute_seconds,rss_bytes,pid (one app PID). frame-review.json must name a
reviewer, the video hash, every reviewed native frame, and zero blank frames.
Run `self-test` for synthetic INPUT ONLY parser checks, or `analyze MANIFEST`.

Record video separately with `xcrun simctl io UDID recordVideo --codec=h264 FILE`
and retain the original file. Inspect frames at original PTS, annotate actual
row coordinates, and identify the sampled app PID. No ffmpeg fps filter is used.
The exporter cannot infer presented FPS, GPU work or app-attributed stalls from
CADisplayLink callbacks or Simulator video. Attach supported Instruments evidence
separately; absent proof leaves those fields UNVERIFIED.
"""
from __future__ import annotations
import argparse
import csv
import ctypes
import hashlib
import json
import math
import plistlib
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

CLOCK_DOMAIN = "mach_absolute_seconds"
VIDEO_CLOCK_DOMAIN = "native_video_pts_seconds"


class MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def raw_mach_seconds() -> float:
    if sys.platform != "darwin":
        raise EvidenceError("raw Mach clock requires Darwin")
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    lib.mach_absolute_time.restype = ctypes.c_uint64
    lib.mach_timebase_info.argtypes = [ctypes.POINTER(MachTimebase)]
    scale = MachTimebase()
    if lib.mach_timebase_info(ctypes.byref(scale)) != 0 or scale.denom == 0:
        raise EvidenceError("Mach timebase unavailable")
    return lib.mach_absolute_time() * scale.numer / scale.denom / 1e9


SCENARIOS = {"four_tall_motion", "four_tall_full_inline", "four_tall_eager_arrow_motion", "four_tall_eager_arrow_motion_only", "rich30_stream", "rich30_open_back", "rich30_switch", "rich30_paging"}
VARIANTS = {"baseline", "candidate"}
COMMON_FLAGS = ["--chat-windowed-eager", "--chat-windowed-rows=60"]
VARIANT_FLAGS = {"baseline": COMMON_FLAGS, "candidate": COMMON_FLAGS + ["--chat-rich-native-code-text"]}
FIXTURE_FLAGS = {"four_tall_motion": "--chat-performance-four-tall-lab",
                 "four_tall_full_inline": "--chat-performance-four-tall-lab",
                 "four_tall_eager_arrow_motion": "--chat-performance-four-tall-lab",
                 "four_tall_eager_arrow_motion_only": "--chat-performance-four-tall-lab",
                 "rich30_stream": "--chat-performance-rich30-lab",
                 "rich30_open_back": "--chat-performance-rich30-back-lab",
                 "rich30_switch": "--chat-performance-rich-switch-lab",
                 "rich30_paging": "--chat-performance-rich30-lab"}
SELECTORS = {
    ("four_tall_motion", "baseline"): "testOptInSmoothnessFourTallMotionBaseline",
    ("four_tall_motion", "candidate"): "testOptInSmoothnessFourTallMotionCandidate",
    ("four_tall_full_inline", "baseline"): "testOptInSmoothnessFourTallFullInlineBaseline",
    ("four_tall_full_inline", "candidate"): "testOptInSmoothnessFourTallFullInlineCandidate",
    ("four_tall_eager_arrow_motion", "baseline"): "testOptInSmoothnessFourTallEagerArrowBaseline",
    ("four_tall_eager_arrow_motion", "candidate"): "testOptInSmoothnessFourTallEagerArrowCandidate",
    ("four_tall_eager_arrow_motion_only", "baseline"): "testOptInSmoothnessFourTallEagerArrowMotionOnlyBaseline",
    ("four_tall_eager_arrow_motion_only", "candidate"): "testOptInSmoothnessFourTallEagerArrowMotionOnlyCandidate",
    ("rich30_stream", "baseline"): "testOptInSmoothnessRich30StreamBaseline",
    ("rich30_stream", "candidate"): "testOptInSmoothnessRich30StreamCandidate",
    ("rich30_open_back", "baseline"): "testOptInSmoothnessRich30OpenBackBaseline",
    ("rich30_open_back", "candidate"): "testOptInSmoothnessRich30OpenBackCandidate",
    ("rich30_switch", "baseline"): "testOptInSmoothnessRichSwitchBaseline",
    ("rich30_switch", "candidate"): "testOptInSmoothnessRichSwitchCandidate",
    ("rich30_paging", "baseline"): "testOptInSmoothnessRich30CoveragePagingBaseline",
    ("rich30_paging", "candidate"): "testOptInSmoothnessRich30CoveragePaging",
}
REQUIRED_CALLBACK_PHASES = {
    "four_tall_motion": ("scroll", "arrow"),
    "four_tall_full_inline": ("scroll", "arrow"),
    "four_tall_eager_arrow_motion": ("scroll", "arrow"),
    "four_tall_eager_arrow_motion_only": ("scroll", "arrow"),
    "rich30_stream": ("scroll", "arrow", "streamFollow", "streamParked"),
    "rich30_open_back": ("entry", "back", "streamFollow"),
    "rich30_switch": ("switchChat",),
    # The DEBUG page button changes ChatTranscriptView's private window. Its
    # parent has no trustworthy viewport-completion callback in this lane.
    "rich30_paging": ("arrow",),
}
MOTION_PHASES = {
    "four_tall_motion": ("scroll", "arrow"),
    "four_tall_full_inline": ("scroll", "arrow"),
    "four_tall_eager_arrow_motion": ("scroll", "arrow"),
    "four_tall_eager_arrow_motion_only": ("scroll", "arrow"),
    "rich30_stream": ("scroll", "arrow"),
    "rich30_paging": ("paging", "arrow"),
}
SIMULATOR = "21251C87-66C9-4F3B-AF32-F9FBE40A76FF"
DERIVED_DATA = "/tmp/semreh-arrow-smooth-dd"


class EvidenceError(ValueError):
    pass


def expected_flags(scenario: str, variant: str) -> list[str]:
    if scenario in ("four_tall_eager_arrow_motion", "four_tall_eager_arrow_motion_only"):
        # Native code and full-inline source stay ON in both variants.
        # Motion is the sole A/B difference; legacy candidate keeps its meaning.
        flags = COMMON_FLAGS + ["--chat-rich-native-code-text", "--chat-full-inline-code"]
        return flags + (["--chat-eager-arrow-motion"] if variant == "candidate" else [])
    flags = list(VARIANT_FLAGS[variant])
    if scenario != "four_tall_motion":
        flags.append("--chat-full-inline-code")
    if scenario == "rich30_stream":
        flags.append("--chat-performance-stream-rich-code")
    if scenario == "rich30_paging":
        flags.append("--chat-performance-rich30-paging-spread")
    return flags


def observation_scope(scenario: str) -> dict:
    if scenario == "four_tall_eager_arrow_motion_only":
        return {"observation_scope": "motion_only",
                "selection_correctness": "UNVERIFIED_SEPARATE_BLOCKER",
                "aggregate_callback_scope": "launch_and_motion_observation"}
    if scenario == "four_tall_eager_arrow_motion":
        return {"observation_scope": "motion_and_selection",
                "selection_correctness": "REQUIRES_COMBINED_TEST_PASS",
                "aggregate_callback_scope": "includes_selection_do_not_score_as_motion"}
    return {"observation_scope": "existing_scenario_contract"}


def validate_observation_events(scenario: str, names: dict) -> None:
    if scenario not in ("four_tall_eager_arrow_motion", "four_tall_eager_arrow_motion_only"):
        return
    motion_end = names.get("motion_scored_interval_end")
    readable = names.get("arrow_tail_readable")
    if motion_end is None or readable is None or motion_end <= readable:
        raise EvidenceError("missing motion observation boundary after readable settlement")
    if scenario == "four_tall_eager_arrow_motion_only":
        if any(name.startswith("selection_") for name in names):
            raise EvidenceError("motion-only capture contains selection work")
    else:
        begin = names.get("selection_correctness_begin")
        complete = names.get("selection_correctness_complete")
        if begin is None or complete is None or not motion_end < begin < complete:
            raise EvidenceError("combined capture lacks a completed separate selection gate")


def required_path(value: str) -> Path:
    path = Path(value)
    if not path.is_file() or path.stat().st_size == 0:
        raise EvidenceError(f"missing/empty evidence: {path}")
    return path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_identity() -> dict:
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    diff = subprocess.check_output(["git", "diff", "--binary", "HEAD"], text=False)
    untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"]).split(b"\0")
    hashes = {path.decode(): sha256(Path(path.decode())) for path in untracked if path and Path(path.decode()).is_file()}
    return {"git_head": head, "git_diff_sha256": hashlib.sha256(diff).hexdigest(),
            "untracked_file_sha256": hashes}


def validate_build_stamp(stamp: Path, xctestrun: Path, binary: Path) -> dict:
    recorded = json.loads(required_path(str(stamp)).read_text())
    if recorded != source_identity():
        raise EvidenceError("source changed since pre-build source stamp")
    if min(binary.stat().st_mtime_ns, xctestrun.stat().st_mtime_ns) <= stamp.stat().st_mtime_ns:
        raise EvidenceError("binary or xctestrun predates the source stamp")
    return recorded


def check_disk(path: Path) -> None:
    if shutil.disk_usage(path).free < 3 * 1024 ** 3:
        raise EvidenceError("below 3 GiB free disk floor; capture not started")


def verify_xctestrun_app(xctestrun: Path, app_binary: Path) -> None:
    with xctestrun.open("rb") as stream:
        plan = plistlib.load(stream)
    app_paths = []
    def walk(value):
        if isinstance(value, dict):
            if isinstance(value.get("UITargetAppPath"), str):
                app_paths.append(value["UITargetAppPath"])
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    walk(plan)
    if not app_paths:
        raise EvidenceError("xctestrun lacks UITargetAppPath; cannot bind build identity")
    for raw in app_paths:
        resolved = raw.replace("__TESTROOT__", str(xctestrun.parent))
        candidate = Path(resolved) / app_binary.name
        if candidate.resolve() == app_binary.resolve():
            return
    raise EvidenceError("xctestrun UI target app does not match stamped app binary")


def parse_report(path: Path) -> dict:
    blocks: dict[str, dict] = {}
    phase = "aggregate"
    for line in path.read_text().splitlines():
        if line.startswith("phase="):
            phase = line.split()[0].split("=", 1)[1]
        if "=" not in line:
            continue
        for token in line.split():
            if "=" in token:
                key, value = token.split("=", 1)
                blocks.setdefault(phase, {})[key] = value
    if "CADisplayLink main-run-loop callback timing only" not in path.read_text():
        raise EvidenceError("callback report has wrong measurement provenance")
    if blocks.get("aggregate", {}).get("fps") != "not_measured":
        raise EvidenceError("callback report mislabels FPS")
    if blocks.get("aggregate", {}).get("clock_domain") != CLOCK_DOMAIN:
        raise EvidenceError("callback report clock domain mismatch")
    return blocks


def numeric(value: str, name: str) -> float:
    try:
        number = float(value)
    except (ValueError, TypeError):
        raise EvidenceError(f"{name} is absent or nonnumeric: {value}") from None
    if not math.isfinite(number):
        raise EvidenceError(f"{name} is not finite")
    return number


def parse_gap_bound(value: str, name: str) -> float:
    if value.startswith("<"):
        return numeric(value[1:], name)  # conservative upper bound, ms
    raise EvidenceError(f"{name} is absent or overflow-binned: {value}")


def callback_metrics(block: dict) -> dict:
    count = int(block.get("callbacks", 0))
    gaps = int(block.get("callback_gaps", 0))
    if count < 2 or gaps < 1:
        raise EvidenceError("zero/one-callback phase is UNMEASURED")
    duration = numeric(block.get("measured_callback_gap_coverage_seconds"), "coverage")
    if duration <= 0:
        raise EvidenceError("empty callback coverage")
    target_min = numeric(block.get("observed_target_interval_min_ms"), "target min")
    target_max = numeric(block.get("observed_target_interval_max_ms"), "target max")
    if target_min <= 0 or target_max < target_min:
        raise EvidenceError("invalid observed refresh target")
    missed = int(block.get("estimated_missed_target_intervals", -1))
    if missed < 0:
        raise EvidenceError("missing missed-interval count")
    result = {
        "callback_count": count,
        "gap_count": gaps,
        "gap_coverage_seconds": duration,
        "effective_callback_hz_proxy": gaps / duration,
        "observed_target_interval_min_ms": target_min,
        "observed_target_interval_max_ms": target_max,
        "p50_gap_ms_upper": parse_gap_bound(block.get("p50_callback_gap_ms_upper_bin", ""), "p50"),
        "p95_gap_ms_upper": parse_gap_bound(block.get("p95_callback_gap_ms_upper_bin", ""), "p95"),
        "p99_gap_ms_upper": parse_gap_bound(block.get("p99_callback_gap_ms_upper_bin", ""), "p99"),
        "max_gap_ms": numeric(block.get("maximum_callback_gap_ms"), "max gap"),
        "missed_target_interval_ratio_estimate": missed / (gaps + missed),
        "gaps_over_50_ms": int(block.get("callback_gaps_over_50_ms", -1)),
        "gaps_over_100_ms": int(block.get("callback_gaps_over_100_ms", -1)),
    }
    if min(result["gaps_over_50_ms"], result["gaps_over_100_ms"]) < 0:
        raise EvidenceError("missing long-gap counts")
    # At adaptive 60/120 Hz, a single target is misleading; use the fastest
    # observed target for the conservative provisional gate.
    target = target_min
    result["provisional_callback_gate"] = (
        result["p95_gap_ms_upper"] <= 1.5 * target
        and result["p99_gap_ms_upper"] <= 2 * target
        and result["missed_target_interval_ratio_estimate"] <= .01
        and result["gaps_over_100_ms"] == 0
    )
    return result


def read_csv(path: Path, columns: tuple[str, str]) -> list[tuple[float, float]]:
    with path.open(newline="") as stream:
        reader = csv.DictReader(stream)
        if not set(columns).issubset(reader.fieldnames or []):
            raise EvidenceError(f"{path} must contain {columns}")
        rows = [(numeric(row[columns[0]], columns[0]), numeric(row[columns[1]], columns[1]))
                for row in reader]
    if len(rows) < 2 or any(b[0] <= a[0] for a, b in zip(rows, rows[1:])):
        raise EvidenceError(f"{path} requires >=2 strictly increasing timestamps")
    return rows


def read_memory(path: Path, expected_pid: int) -> list[tuple[float, float]]:
    with path.open(newline="") as stream:
        reader = csv.DictReader(stream)
        if not {"clock_domain", "mach_absolute_seconds", "rss_bytes", "pid"}.issubset(reader.fieldnames or []):
            raise EvidenceError("memory CSV needs raw Mach timestamp, clock domain, RSS and app PID")
        rows = []
        for row in reader:
            if row["clock_domain"] != CLOCK_DOMAIN:
                raise EvidenceError("memory clock domain differs from XCTest events")
            if int(row["pid"]) != expected_pid:
                raise EvidenceError("memory segment merges different app processes")
            rows.append((numeric(row["mach_absolute_seconds"], "memory time"),
                         numeric(row["rss_bytes"], "RSS")))
    if len(rows) < 2 or any(b[0] <= a[0] for a, b in zip(rows, rows[1:])):
        raise EvidenceError("memory segment has insufficient ordered samples")
    return rows


def validate_clock_correlation(event_doc: dict, capture: dict, expected_pid: int) -> list[float]:
    events = event_doc.get("events", [])
    if event_doc.get("clock_domain") != CLOCK_DOMAIN or any(
        event.get("clock_domain") != CLOCK_DOMAIN for event in events
    ):
        raise EvidenceError("XCTest event clock origin differs from RSS clock")
    if capture.get("clock_domain") != CLOCK_DOMAIN or capture.get("memory_sampler", {}).get("pid") != expected_pid:
        raise EvidenceError("capture clock domain or app PID does not match RSS segment")
    return [numeric(event.get("mach_absolute_seconds"), "event time") for event in events]


def motion_rows(path: Path) -> dict[str, tuple[str, list[tuple[float, float]]]]:
    with path.open(newline="") as stream:
        reader = csv.DictReader(stream)
        if not {"video_pts_seconds", "phase", "row_id", "row_y_points"}.issubset(reader.fieldnames or []):
            raise EvidenceError("motion CSV requires video_pts_seconds,phase,row_id,row_y_points")
        records = [(row["phase"].strip(), row["row_id"].strip(),
                    numeric(row["video_pts_seconds"], "video PTS"),
                    numeric(row["row_y_points"], "row y")) for row in reader]
    grouped = {}
    for phase, row_id, pts, y in records:
        if not phase or not row_id:
            raise EvidenceError("motion phase and row ID cannot be empty")
        grouped.setdefault(phase, []).append((row_id, pts, y))
    result = {}
    for phase, entries in grouped.items():
        if len(entries) < 5 or any(entry[0] != entries[0][0] for entry in entries):
            raise EvidenceError(f"motion phase {phase} needs at least five observations of one named row")
        rows = [(pts, y) for _, pts, y in entries]
        if any(b[0] <= a[0] for a, b in zip(rows, rows[1:])):
            raise EvidenceError(f"motion phase {phase} timestamps must increase")
        if rows[-1][0] - rows[0][0] < .2 or len({round(y, 1) for _, y in rows}) < 3:
            raise EvidenceError(f"motion phase {phase} lacks sustained observed displacement")
        if any(b[0] - a[0] > .2 for a, b in zip(rows, rows[1:])):
            raise EvidenceError(f"motion phase {phase} annotations are too sparse")
        result[phase] = (entries[0][0], rows)
    return result


def video_pts(path: Path) -> list[float]:
    command = ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
               "frame=best_effort_timestamp_time", "-of", "json", str(path)]
    raw = subprocess.check_output(command, text=True)
    frames = json.loads(raw).get("frames", [])
    pts = [numeric(frame.get("best_effort_timestamp_time"), "video PTS") for frame in frames]
    if len(pts) < 2 or any(b <= a for a, b in zip(pts, pts[1:])):
        raise EvidenceError("video lacks increasing native timestamps")
    return pts


def reviewed_video(path: Path, video: Path, frame_count: int) -> dict:
    review = json.loads(required_path(str(path)).read_text())
    if (review.get("video_sha256") != sha256(video)
            or review.get("reviewed_native_frames") != frame_count
            or review.get("blank_frames") != 0
            or not review.get("reviewer")):
        raise EvidenceError("full native-frame blank review missing, stale, or found blanks")
    return {"reviewed_native_frames": frame_count, "blank_frames": 0,
            "reviewer": review["reviewer"]}


def verify_xcresult(path: Path, selector: str) -> dict:
    raw = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "tests",
                                   "--path", str(path)], text=True)
    tree = json.loads(raw)
    matches = []
    def walk(value):
        if isinstance(value, dict):
            name = value.get("name", "")
            identifier = value.get("nodeIdentifier", "")
            exact = name in (selector, selector + "()") or bool(re.search(
                r"(?:^|[/.])" + re.escape(selector) + r"(?:\(\))?$", identifier))
            if value.get("nodeType") in ("Test Case", "Test Case Run") and exact:
                matches.append(value)
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    walk(tree)
    if not matches or not all(node.get("result") == "Passed" for node in matches):
        raise EvidenceError(f"selector {selector} did not execute and pass in {path}")
    return {"selector": selector, "matching_nodes": len(matches), "result": "Passed"}


def owned_app_pids() -> set[int]:
    processes = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    return {int(line.strip().split(None, 1)[0]) for line in processes.splitlines()
            if f"/Devices/{SIMULATOR}/" in line and "/HermesMobile.app/HermesMobile" in line}


def sample_owned_simulator_memory(output: Path, done: threading.Event, state: dict,
                                  excluded_pids: set[int]) -> None:
    """Sample one newly launched app PID, never joining separate processes."""
    pid = None
    rows = []
    while not done.is_set():
        try:
            matches = owned_app_pids() - excluded_pids
        except (subprocess.CalledProcessError, ValueError):
            matches = set()
        if pid is None and len(matches) == 1:
            pid = next(iter(matches))
            state["pid"] = pid
        elif pid is not None and any(candidate != pid for candidate in matches):
            state["relaunch_detected"] = True
        if pid is not None and pid in matches:
            try:
                rss_kb = int(subprocess.check_output(["ps", "-p", str(pid), "-o", "rss="],
                                                     text=True).strip())
                rows.append((CLOCK_DOMAIN, raw_mach_seconds(), rss_kb * 1024, pid))
            except (subprocess.CalledProcessError, ValueError):
                state["process_exited"] = True
        elif pid is not None:
            state["process_exited"] = True
        done.wait(.25)
    if len(rows) >= 2:
        with output.open("w", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(("clock_domain", "mach_absolute_seconds", "rss_bytes", "pid"))
            writer.writerows(rows)
        state["samples"] = len(rows)


def analyze_run(run: dict, source: dict) -> dict:
    scenario, variant = run["scenario"], run["variant"]
    if scenario not in SCENARIOS or variant not in VARIANTS:
        raise EvidenceError("unknown scenario or variant")
    if run.get("flags") != expected_flags(scenario, variant):
        raise EvidenceError("variant flags differ from frozen A/B contract")
    if run.get("fixture") != scenario:
        raise EvidenceError("fixture identity mismatch")
    if run.get("fixture_flag") != FIXTURE_FLAGS[scenario]:
        raise EvidenceError("fixture launch provenance mismatch")
    for field in ("callback_report", "events", "motion_csv", "memory_csv",
                  "video", "frame_review", "capture_metadata"):
        if sha256(required_path(run[field])) != run.get("artifact_sha256", {}).get(field):
            raise EvidenceError(f"{field} changed since evidence manifest")
    binary = required_path(run["app_binary"])
    if sha256(binary) != source["app_sha256"]:
        raise EvidenceError("stale/different app binary")
    xctestrun = required_path(run["xctestrun"])
    if sha256(xctestrun) != source["xctestrun_sha256"]:
        raise EvidenceError("mixed xctestrun identity")
    verify_xctestrun_app(xctestrun, binary)
    validate_build_stamp(Path(run["source_stamp"]), xctestrun, binary)
    xcresult = Path(run["xcresult"])
    if not xcresult.is_dir():
        raise EvidenceError("missing xcresult")
    tests = verify_xcresult(xcresult, SELECTORS[(scenario, variant)])
    blocks = parse_report(required_path(run["callback_report"]))
    if int(blocks.get("aggregate", {}).get("phases_open_at_stop", -1)) != 0:
        raise EvidenceError("one or more phases were force-closed when sampling stopped")
    metrics = callback_metrics(blocks["aggregate"])
    if scenario == "four_tall_eager_arrow_motion":
        metrics["provisional_callback_gate"] = None
        metrics["gate_exclusion"] = "aggregate includes selection correctness; use scroll/arrow phases"
    required_phases = {}
    for phase in REQUIRED_CALLBACK_PHASES[scenario]:
        block = blocks.get(phase, {})
        if int(block.get("phase_events", 0)) < 1 or block.get("phase_callback_timing_coverage") != "observed":
            raise EvidenceError(f"active-motion phase {phase} missing or has no callback-gap coverage")
        if (int(block.get("interaction_events_without_callback", -1)) != 0
                or int(block.get("interaction_timed_events", -1)) != int(block["phase_events"])):
            raise EvidenceError(f"phase {phase} has unclosed or callback-free events")
        phase_metrics = callback_metrics(block)
        duration_ms = numeric(block.get("interaction_duration_total_ms"), "phase duration")
        observed_ms = phase_metrics["gap_coverage_seconds"] * 1000
        if duration_ms <= 0 or observed_ms > duration_ms + 2:
            raise EvidenceError(f"invalid full interval accounting for phase {phase}")
        phase_metrics["total_interaction_duration_ms"] = duration_ms
        phase_metrics["unobserved_interval_ms"] = max(0, duration_ms - observed_ms)
        phase_metrics["callback_gap_coverage_fraction"] = observed_ms / duration_ms
        if phase_metrics["callback_gap_coverage_fraction"] < .5:
            raise EvidenceError(f"phase {phase} has insufficient interval coverage")
        required_phases[phase] = phase_metrics
    event_doc = json.loads(required_path(run["events"]).read_text())
    if event_doc.get("scenario") != scenario:
        raise EvidenceError("event scenario mismatch")
    events = event_doc.get("events", [])
    capture = json.loads(required_path(run["capture_metadata"]).read_text())
    times = validate_clock_correlation(event_doc, capture, int(run["memory_pid"]))
    if len(times) < 4 or any(b <= a for a, b in zip(times, times[1:])):
        raise EvidenceError("missing/nonmonotonic phase events")
    names = {e["event"]: e["mach_absolute_seconds"] for e in events}
    validate_observation_events(scenario, names)
    if capture.get("video_clock_domain") != VIDEO_CLOCK_DOMAIN:
        raise EvidenceError("capture PID or clock domain does not match run")
    start_bound = numeric(capture.get("video_start_request_mach_seconds"), "video start host bound")
    stop_bound = numeric(capture.get("video_stop_observed_mach_seconds"), "video stop host bound")
    if not start_bound < stop_bound or capture.get("video_pts_mapping") != "unmapped; start/stop host bounds do not establish per-frame correspondence":
        raise EvidenceError("video/host clock mapping or bounds missing")
    if times[0] < start_bound or times[-1] > stop_bound:
        raise EvidenceError("XCTest event clock origin falls outside capture host bounds")
    if "process_launch_request" not in names:
        raise EvidenceError("launch/preparation not counted")
    video = required_path(run["video"])
    pts = video_pts(video)
    blank_review = reviewed_video(Path(run["frame_review"]), video, len(pts))
    motions = motion_rows(required_path(run["motion_csv"])) if scenario in MOTION_PHASES else {}
    motion_summary = {}
    for phase in MOTION_PHASES.get(scenario, ()):
        if phase not in motions:
            raise EvidenceError(f"missing actual row displacement for {phase}")
        row_id, rows = motions[phase]
        if rows[0][0] < pts[0] or rows[-1][0] > pts[-1]:
            raise EvidenceError("motion annotation falls outside native video PTS")
        displacement = max(y for _, y in rows) - min(y for _, y in rows)
        if displacement <= 1:
            raise EvidenceError(f"no actual row displacement documented for {phase}")
        motion_summary[phase] = {"row_id": row_id, "displacement_points": displacement,
                                 "pts_first": rows[0][0], "pts_last": rows[-1][0]}
    memory = read_memory(required_path(run["memory_csv"]), int(run["memory_pid"]))
    if memory[0][0] < start_bound or memory[-1][0] > stop_bound:
        raise EvidenceError("RSS clock origin falls outside capture host bounds")
    rss = [v for _, v in memory]
    if min(rss) <= 0:
        raise EvidenceError("invalid process memory sample")
    result = {
        "scenario": scenario, "variant": variant, "repetition": run["repetition"],
        **observation_scope(scenario),
        "selector": tests, "callbacks": metrics,
        "callback_phases": required_phases,
        "paging_callback_phase": "UNVERIFIED_VIEWPORT_COMPLETION" if scenario == "rich30_paging" else "NOT_APPLICABLE",
        "input_provenance": "XCTest synthesized action, not physical touch",
        "phase_provenance": {"entry": "UIKit appearance lifecycle", "back": "shared Back to list lifecycle",
                             "scroll": "native scroll interaction and deceleration",
                             "arrow": "explicit request through tail settlement or cancellation",
                             "paging": "DEBUG window fixture lacks a trustworthy viewport-completion phase in this lane; XCTest AX page transition is separate",
                             "streamFollow": "automatic follow during active turn",
                             "streamParked": "active turn while reader is away from tail",
                             "switchChat": "selection to UIKit appearance lifecycle"},
        "event_times": names, "event_clock_domain": CLOCK_DOMAIN,
        "video": {"path": str(video), "sha256": sha256(video), "clock_domain": VIDEO_CLOCK_DOMAIN,
                  "host_capture_bounds_mach_seconds": [start_bound, stop_bound],
                  "host_to_pts_mapping": "UNVERIFIED", "native_pts_first": pts[0],
                  "native_pts_last": pts[-1], "native_frame_count": len(pts),
                  "annotated_motion_phases": motion_summary,
                  "native_capture_gap_p95_ms": sorted((b - a) * 1000 for a, b in zip(pts, pts[1:]))[
                      math.ceil(.95 * (len(pts) - 1)) - 1],
                  "blank_review": blank_review,
                  "presented_fps": "UNVERIFIED"},
        "memory": {"peak_rss_bytes": max(rss), "last_observed_rss_bytes": rss[-1],
                   "first_rss_bytes": rss[0], "growth_bytes": rss[-1] - rss[0],
                   "pid": int(run["memory_pid"]), "clock_domain": CLOCK_DOMAIN},
        "main_thread_stall_ms": "UNVERIFIED",
        "first_presented_readable_frame_ms": "UNVERIFIED",
        "physical_tap_to_ack_ms": "UNVERIFIED",
        "acceptance": "UNVERIFIED_PRESENTED_FRAMES_AND_MAIN_THREAD_ATTRIBUTION",
    }
    if scenario in ("four_tall_motion", "four_tall_full_inline", "four_tall_eager_arrow_motion", "four_tall_eager_arrow_motion_only"):
        result["xctest_arrow_request_to_ax_readable_ms"] = (names["arrow_tail_readable"] - names["arrow_tap_request"]) * 1000
        result["xctest_cold_launch_request_to_ax_readable_ms"] = (names["first_readable_tail"] - names["process_launch_request"]) * 1000
    if scenario == "rich30_stream":
        result["xctest_cold_launch_request_to_ax_readable_ms"] = (names["first_readable_tail"] - names["process_launch_request"]) * 1000
    if scenario == "rich30_open_back":
        result["cycles"] = [{"open_action_to_ax_transcript_ms": (names[f"open_{n}_transcript_readable"] - names[f"open_{n}_tap_request"]) * 1000,
                             "back_action_to_ax_list_ms": (names[f"back_{n}_list_readable"] - names[f"back_{n}_tap_request"]) * 1000}
                            for n in range(1, 7)]
        cycle_memory = []
        for n in range(1, 7):
            target = names[f"back_{n}_list_readable"]
            nearest = min(memory, key=lambda sample: abs(sample[0] - target))
            if abs(nearest[0] - target) > 1:
                raise EvidenceError(f"memory sample missing near back cycle {n}")
            cycle_memory.append(int(nearest[1]))
        result["memory"]["after_back_cycle_rss_bytes"] = cycle_memory
        result["memory"]["first_to_last_cycle_growth_bytes"] = cycle_memory[-1] - cycle_memory[0]
    if scenario == "rich30_switch":
        result["warm_switch_observations"] = len([event for event in events if event["event"].startswith("chat_")])
    if scenario == "rich30_paging":
        if "rich_groups_covered_30" not in names:
            raise EvidenceError("all 30 rich groups were not observed in mounted UI")
        result["paging_action_to_readable_ms"] = [
            (names[f"page_{n}_readable"] - names[f"page_{n}_request"]) * 1000 for n in range(1, 4)]
    return result


def analyze(manifest: Path) -> dict:
    doc = json.loads(required_path(str(manifest)).read_text())
    source = doc["source"]
    if {key: source[key] for key in source_identity()} != source_identity():
        raise EvidenceError("stale source identity; rebuild/rebase evidence manifest")
    runs = doc.get("runs", [])
    keys = [(r["scenario"], r["variant"], r["repetition"]) for r in runs]
    expected = {(s, v, n) for s, v in SELECTORS for n in (1, 2, 3)}
    if set(keys) != expected or len(keys) != len(expected):
        raise EvidenceError("missing, duplicate, or unexpected scenario/variant/repetition")
    results = [analyze_run(run, source) for run in runs]
    return {"schema": "semreh_smoothness_metrics_v1", "source": source,
            "runs": results, "overall_acceptance": "UNVERIFIED",
            "reason": "Callback timing and native-timestamp motion video do not prove presented FPS or app-attributed main-thread stalls."}


def record(xctestrun: Path, app_binary: Path, source_stamp: Path, output: Path,
           scenario: str, variant: str, repetition: int) -> None:
    """Capture one serial signed Simulator test, retaining failed attempts."""
    if (scenario, variant) not in SELECTORS or repetition not in (1, 2, 3):
        raise EvidenceError("unknown selector or repetition")
    required_path(str(xctestrun))
    required_path(str(app_binary))
    validate_build_stamp(source_stamp, xctestrun, app_binary)
    verify_xctestrun_app(xctestrun, app_binary)
    check_disk(output.parent)
    output.mkdir(parents=True, exist_ok=False)
    selector = SELECTORS[(scenario, variant)]
    video = output / "original-timestamps.mp4"
    result = output / "test.xcresult"
    recorder_log = output / "recorder.log"
    test_log = output / "xcodebuild.log"
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
               "-destination", f"platform=iOS Simulator,id={SIMULATOR}",
               "-derivedDataPath", DERIVED_DATA, "-resultBundlePath", str(result),
               "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
               f"-only-testing:HermesMobileUITests/LongChatScrollUITests/{selector}"]
    capture = {"scenario": scenario, "variant": variant, "repetition": repetition,
               **observation_scope(scenario),
               "capture_metadata": str(output / "capture.json"),
               "selector": selector, "simulator": SIMULATOR, "derived_data": DERIVED_DATA,
               "app_binary": str(app_binary), "app_sha256": sha256(app_binary),
               "xctestrun": str(xctestrun), "xctestrun_sha256": sha256(xctestrun),
               "source_stamp": str(source_stamp),
               "flags": expected_flags(scenario, variant), "fixture_flag": FIXTURE_FLAGS[scenario],
               "clock_domain": CLOCK_DOMAIN, "video_clock_domain": VIDEO_CLOCK_DOMAIN,
               "xcodebuild_command": command,
               "video": str(video), "xcresult": str(result), "source": source_identity()}
    (output / "capture.json").write_text(json.dumps(capture, indent=2))
    capture["video_start_request_mach_seconds"] = raw_mach_seconds()
    with recorder_log.open("wb") as recorder_stream:
        recorder = subprocess.Popen(["xcrun", "simctl", "io", SIMULATOR, "recordVideo",
                                     "--codec=h264", str(video)], stdout=recorder_stream,
                                    stderr=subprocess.STDOUT)
        try:
            time.sleep(2)
            if recorder.poll() is not None:
                raise EvidenceError("Simulator recorder exited before test; see recorder.log")
            memory_done = threading.Event()
            memory_state: dict = {}
            baseline_pids = owned_app_pids()
            memory_thread = threading.Thread(target=sample_owned_simulator_memory,
                                             args=(output / "memory.csv", memory_done,
                                                   memory_state, baseline_pids),
                                             daemon=True)
            memory_thread.start()
            with test_log.open("wb") as test_stream:
                try:
                    completed = subprocess.run(command, stdout=test_stream, stderr=subprocess.STDOUT,
                                               check=False)
                finally:
                    memory_done.set()
                    memory_thread.join(timeout=5)
            capture["xcodebuild_exit_code"] = completed.returncode
            capture["memory_sampler"] = memory_state
        finally:
            if recorder.poll() is None:
                recorder.send_signal(2)
            try:
                capture["recorder_exit_code"] = recorder.wait(timeout=20)
            except subprocess.TimeoutExpired:
                capture["recorder_exit_code"] = "TIMEOUT"
                recorder.terminate()
                try:
                    recorder.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    capture["recorder_exit_code"] = "TIMEOUT_STILL_RUNNING"
            (output / "capture.json").write_text(json.dumps(capture, indent=2))
    capture["video_stop_observed_mach_seconds"] = raw_mach_seconds()
    capture["video_pts_mapping"] = "unmapped; start/stop host bounds do not establish per-frame correspondence"
    (output / "capture.json").write_text(json.dumps(capture, indent=2))
    if capture.get("xcodebuild_exit_code") != 0 or capture["recorder_exit_code"] not in (0, 130, -2):
        raise EvidenceError("test or recorder failed; raw evidence retained")
    if not capture.get("memory_sampler", {}).get("pid"):
        raise EvidenceError("no uniquely identified app PID; raw evidence retained")
    if capture["memory_sampler"].get("relaunch_detected"):
        raise EvidenceError("app relaunched during one memory segment; raw evidence retained")
    required_path(str(video))
    required_path(str(output / "memory.csv"))
    verify_xcresult(result, selector)
    attachments = output / "attachments"
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                    "--output-path", str(attachments)], check=True)
    reports, event_files = [], []
    for candidate in attachments.rglob("*"):
        if not candidate.is_file() or candidate.stat().st_size > 5_000_000:
            continue
        body = candidate.read_text(errors="ignore")
        if "measurement=CADisplayLink main-run-loop callback timing only" in body:
            reports.append(str(candidate))
        try:
            event_doc = json.loads(body)
            if event_doc.get("scenario") == scenario and isinstance(event_doc.get("events"), list):
                event_files.append(str(candidate))
        except (ValueError, AttributeError):
            pass
    if len(reports) != 1 or len(event_files) != 1:
        raise EvidenceError("expected one callback report and one event JSON attachment; raw capture retained")
    capture["callback_report"] = reports[0]
    capture["events"] = event_files[0]
    capture["motion_csv"] = str(output / "motion.csv")
    (output / "motion.csv").write_text("video_pts_seconds,phase,row_id,row_y_points\n")
    capture["memory_csv"] = str(output / "memory.csv")
    capture["memory_pid"] = capture["memory_sampler"]["pid"]
    capture["frame_review"] = str(output / "frame-review.json")
    (output / "frame-review.json").write_text(json.dumps({
        "video_sha256": sha256(video), "reviewed_native_frames": 0,
        "blank_frames": None, "reviewer": ""}, indent=2))
    capture["status"] = "complete"
    (output / "capture.json").write_text(json.dumps(capture, indent=2))
    print(json.dumps(capture, indent=2))


def manifest_from_captures(directory: Path) -> dict:
    all_captures = [json.loads(path.read_text()) for path in directory.rglob("capture.json")]
    captures = [capture for capture in all_captures if capture.get("status") == "complete"]
    if not captures:
        raise EvidenceError("no completed capture.json files")
    source = {**captures[0]["source"], "app_sha256": captures[0]["app_sha256"],
              "xctestrun_sha256": captures[0]["xctestrun_sha256"]}
    runs = []
    for capture in captures:
        if (capture["source"] != captures[0]["source"]
                or capture["app_sha256"] != source["app_sha256"]
                or capture["xctestrun_sha256"] != source["xctestrun_sha256"]):
            raise EvidenceError("captures have mixed source or build identity")
        runs.append({key: capture[key] for key in
                     ("scenario", "variant", "repetition", "app_binary", "xctestrun", "source_stamp",
                      "xcresult", "video", "callback_report", "events", "motion_csv", "memory_csv",
                     "memory_pid", "frame_review", "fixture_flag")})
        runs[-1]["capture_metadata"] = capture["capture_metadata"]
        runs[-1]["fixture"] = capture["scenario"]
        runs[-1]["flags"] = capture["flags"]
        runs[-1]["artifact_sha256"] = {
            field: sha256(required_path(capture[field])) for field in
            ("callback_report", "events", "motion_csv", "memory_csv", "video", "frame_review", "capture_metadata")
        }
    return {"source": source, "failed_attempts_retained": len(all_captures) - len(captures),
            "runs": sorted(runs, key=lambda r: (r["scenario"], r["variant"], r["repetition"]))}


def battery(xctestrun: Path, app_binary: Path, source_stamp: Path, directory: Path) -> None:
    validate_build_stamp(source_stamp, xctestrun, app_binary)
    directory.mkdir(parents=True, exist_ok=True)
    for scenario, variant in sorted(SELECTORS):
        for repetition in (1, 2, 3):
            stem = f"{scenario}-{variant}-{repetition}"
            completed = [path for path in directory.glob(stem + "*")
                         if (path / "capture.json").is_file()
                         and json.loads((path / "capture.json").read_text()).get("status") == "complete"]
            if len(completed) > 1:
                raise EvidenceError(f"multiple completed captures for {stem}")
            if completed:
                capture = json.loads((completed[0] / "capture.json").read_text())
                if (capture["source"] != source_identity()
                        or capture["app_sha256"] != sha256(required_path(str(app_binary)))
                        or capture["xctestrun_sha256"] != sha256(xctestrun)):
                    raise EvidenceError(f"stale completed capture for {stem}; use a fresh output directory")
                continue
            attempt = 1
            output = directory / stem
            while output.exists():
                attempt += 1
                output = directory / f"{stem}-attempt{attempt}"
            record(xctestrun, app_binary, source_stamp, output, scenario, variant, repetition)


def self_test() -> None:
    from tempfile import TemporaryDirectory
    from unittest import mock
    ui_source = Path("HermesMobileUITests/LongChatScrollUITests.swift").read_text()
    for selector in SELECTORS.values():
        assert len(re.findall(r"\bfunc\s+" + re.escape(selector) + r"\s*\(", ui_source)) == 1
    assert VARIANT_FLAGS["candidate"] == VARIANT_FLAGS["baseline"] + ["--chat-rich-native-code-text"]
    assert expected_flags("four_tall_eager_arrow_motion", "candidate") == expected_flags(
        "four_tall_eager_arrow_motion", "baseline") + ["--chat-eager-arrow-motion"]
    assert SCENARIOS == set(FIXTURE_FLAGS) == set(REQUIRED_CALLBACK_PHASES)
    assert set(SELECTORS) == {(scenario, variant) for scenario in SCENARIOS for variant in VARIANTS}
    for variant in VARIANTS:
        combined = expected_flags("four_tall_eager_arrow_motion", variant)
        motion_only = expected_flags("four_tall_eager_arrow_motion_only", variant)
        assert motion_only == combined
        assert "--chat-rich-native-code-text" in motion_only and "--chat-full-inline-code" in motion_only
        args = argument_parser().parse_args([
            "record", "fixture.xctestrun", "app", "stamp.json", "output",
            "four_tall_eager_arrow_motion_only", variant, "1"])
        assert args.scenario == "four_tall_eager_arrow_motion_only" and args.variant == variant
        assert SELECTORS[(args.scenario, args.variant)] != SELECTORS[("four_tall_eager_arrow_motion", variant)]
    assert observation_scope("four_tall_eager_arrow_motion_only")["selection_correctness"] == "UNVERIFIED_SEPARATE_BLOCKER"
    assert observation_scope("four_tall_eager_arrow_motion")["aggregate_callback_scope"] == "includes_selection_do_not_score_as_motion"
    motion_events = {"arrow_tail_readable": 1, "motion_scored_interval_end": 2}
    combined_events = {**motion_events, "selection_correctness_begin": 3,
                       "selection_correctness_complete": 4}
    validate_observation_events("four_tall_eager_arrow_motion_only", motion_events)
    validate_observation_events("four_tall_eager_arrow_motion", combined_events)
    for scenario, events in (("four_tall_eager_arrow_motion_only", combined_events),
                             ("four_tall_eager_arrow_motion", motion_events),
                             ("four_tall_eager_arrow_motion_only", {})):
        try:
            validate_observation_events(scenario, events)
        except EvidenceError:
            pass
        else:
            raise AssertionError("missing or mixed observation boundaries must fail")
    with TemporaryDirectory() as directory:
        path = Path(directory) / "synthetic_input_only.txt"
        path.write_text("\n".join([
            "measurement=CADisplayLink main-run-loop callback timing only", "fps=not_measured", "clock_domain=mach_absolute_seconds",
            "callbacks=4", "callback_gaps=3", "measured_callback_gap_coverage_seconds=0.050",
            "observed_target_interval_min_ms=16.667", "observed_target_interval_max_ms=16.667",
            "estimated_missed_target_intervals=0", "p50_callback_gap_ms_upper_bin=<17",
            "p95_callback_gap_ms_upper_bin=<17", "p99_callback_gap_ms_upper_bin=<17",
            "maximum_callback_gap_ms=16.67", "callback_gaps_over_50_ms=0", "callback_gaps_over_100_ms=0"
        ]))
        metrics = callback_metrics(parse_report(path)["aggregate"])
        assert metrics["callback_count"] == 4 and metrics["provisional_callback_gate"]
        path.write_text(path.read_text().replace("p95_callback_gap_ms_upper_bin=<17",
                                                "p95_callback_gap_ms_upper_bin=<51"))
        assert not callback_metrics(parse_report(path)["aggregate"])["provisional_callback_gate"]
        path.write_text(path.read_text().replace("p95_callback_gap_ms_upper_bin=<51",
                                                "p95_callback_gap_ms_upper_bin=500+"))
        try:
            callback_metrics(parse_report(path)["aggregate"])
        except EvidenceError:
            pass
        else:
            raise AssertionError("overflow-binned percentile cannot pass")
        path.write_text(path.read_text().replace("p95_callback_gap_ms_upper_bin=500+",
                                                "p95_callback_gap_ms_upper_bin=<17"))
        path.write_text(path.read_text().replace("callbacks=4", "callbacks=0"))
        try:
            callback_metrics(parse_report(path)["aggregate"])
        except EvidenceError:
            pass
        else:
            raise AssertionError("zero callbacks must fail closed")
        motion = Path(directory) / "motion.csv"
        motion.write_text("video_pts_seconds,phase,row_id,row_y_points\n0,scroll,row,0\n.25,scroll,row,10\n")
        try:
            motion_rows(motion)
        except EvidenceError:
            pass
        else:
            raise AssertionError("two sparse motion points must fail")
        motion.write_text("video_pts_seconds,phase,row_id,row_y_points\n" +
                          "\n".join(f"{i * .05},scroll,row,{i * 5}" for i in range(5)))
        assert motion_rows(motion)["scroll"][0] == "row"
        memory = Path(directory) / "memory.csv"
        memory.write_text("clock_domain,mach_absolute_seconds,rss_bytes,pid\nmach_absolute_seconds,1,100,1\nmach_absolute_seconds,2,110,2\n")
        try:
            read_memory(memory, 1)
        except EvidenceError:
            pass
        else:
            raise AssertionError("mixed process memory must fail")
        memory.write_text("clock_domain,mach_absolute_seconds,rss_bytes,pid\nprocess_monotonic_seconds,1,100,1\nprocess_monotonic_seconds,2,110,1\n")
        try:
            read_memory(memory, 1)
        except EvidenceError:
            pass
        else:
            raise AssertionError("different clock origin must fail")
        valid_events = {"clock_domain": CLOCK_DOMAIN, "events": [
            {"clock_domain": CLOCK_DOMAIN, "mach_absolute_seconds": 1.0}]}
        valid_capture = {"clock_domain": CLOCK_DOMAIN, "memory_sampler": {"pid": 1}}
        assert validate_clock_correlation(valid_events, valid_capture, 1) == [1.0]
        for bad_events, bad_capture, pid in (
            ({**valid_events, "clock_domain": "process_monotonic_seconds"}, valid_capture, 1),
            ({**valid_events, "events": [{"clock_domain": "process_monotonic_seconds",
                                          "mach_absolute_seconds": 1.0}]}, valid_capture, 1),
            (valid_events, {**valid_capture, "clock_domain": "process_monotonic_seconds"}, 1),
            (valid_events, valid_capture, 2),
        ):
            try:
                validate_clock_correlation(bad_events, bad_capture, pid)
            except EvidenceError:
                pass
            else:
                raise AssertionError("mixed event origin, clock domain, or process must fail")
        selector = "testOptInSmoothnessRichSwitchCandidate"
        wrong = {"nodeType": "Test Case", "name": selector + "Suffix", "result": "Passed"}
        with mock.patch.object(subprocess, "check_output", return_value=json.dumps(wrong)):
            try:
                verify_xcresult(Path(directory), selector)
            except EvidenceError:
                pass
            else:
                raise AssertionError("substring selector match must fail")
        exact = {"nodeType": "Test Case", "name": selector + "()", "result": "Passed"}
        with mock.patch.object(subprocess, "check_output", return_value=json.dumps(exact)):
            assert verify_xcresult(Path(directory), selector)["result"] == "Passed"
        # A failed historical combined capture cannot become a motion-only pass.
        combined_selector = SELECTORS[("four_tall_eager_arrow_motion", "candidate")]
        motion_selector = SELECTORS[("four_tall_eager_arrow_motion_only", "candidate")]
        for name, result in ((combined_selector, "Failed"), (combined_selector, "Passed"),
                             (motion_selector, "Failed"), (motion_selector, "Skipped")):
            node = {"nodeType": "Test Case", "name": name + "()", "result": result}
            with mock.patch.object(subprocess, "check_output", return_value=json.dumps(node)):
                try:
                    verify_xcresult(Path(directory), motion_selector)
                except EvidenceError:
                    pass
                else:
                    raise AssertionError("combined, failed, or skipped capture must not pass motion-only selector")
        node = {"nodeType": "Test Case", "name": motion_selector + "()", "result": "Passed"}
        with mock.patch.object(subprocess, "check_output", return_value=json.dumps(node)):
            assert verify_xcresult(Path(directory), motion_selector)["result"] == "Passed"
    print("PASS synthetic INPUT ONLY callback, motion, PID, exact-selector, CLI, fixture flags, and observation-scope checks")


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("self-test", "source", "selectors"):
        commands.add_parser(command)
    for command, field in (("analyze", "manifest"), ("stamp", "app_binary"),
                           ("manifest", "directory"), ("frames", "video")):
        commands.add_parser(command).add_argument(field, type=Path)
    for command in ("record", "battery"):
        sub = commands.add_parser(command)
        for field in ("xctestrun", "app_binary", "source_stamp", "output"):
            sub.add_argument(field, type=Path)
        if command == "record":
            sub.add_argument("scenario", choices=sorted(SCENARIOS))
            sub.add_argument("variant", choices=sorted(VARIANTS))
            sub.add_argument("repetition", type=int, choices=(1, 2, 3))
    return parser


def main(argv: list[str] | None = None) -> None:
    args = argument_parser().parse_args(argv)
    if args.command == "self-test":
        self_test()
    elif args.command == "analyze":
        print(json.dumps(analyze(args.manifest), indent=2, sort_keys=True))
    elif args.command == "source":
        print(json.dumps(source_identity(), indent=2))
    elif args.command == "selectors":
        print(json.dumps([{"scenario": scenario, "variant": variant, "selector": selector,
                           "fixture_flag": FIXTURE_FLAGS[scenario],
                           "flags": expected_flags(scenario, variant), **observation_scope(scenario)}
                          for (scenario, variant), selector in sorted(SELECTORS.items())], indent=2))
    elif args.command == "stamp":
        app = required_path(str(args.app_binary))
        print(json.dumps({**source_identity(), "app_sha256": sha256(app)}, indent=2))
    elif args.command == "record":
        record(args.xctestrun, args.app_binary, args.source_stamp, args.output,
               args.scenario, args.variant, args.repetition)
    elif args.command == "manifest":
        print(json.dumps(manifest_from_captures(args.directory), indent=2))
    elif args.command == "battery":
        battery(args.xctestrun, args.app_binary, args.source_stamp, args.output)
    elif args.command == "frames":
        print("video_pts_seconds,phase,row_id,row_y_points")
        for pts in video_pts(required_path(str(args.video))):
            print(f"{pts:.6f},,,")


if __name__ == "__main__":
    try:
        main()
    except (EvidenceError, KeyError, subprocess.CalledProcessError, OSError) as error:
        print(f"EVIDENCE INCOMPLETE: {error}", file=sys.stderr)
        sys.exit(2)
