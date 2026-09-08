#!/usr/bin/env python3
"""Guarded stock profile and cron reads; never creates or runs scheduled work."""
import argparse
import asyncio
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
from urllib.parse import quote

from direct_hermes_capture import write_fixture
from direct_hermes_identity_probe import authenticated
import direct_hermes_probe as stock_probe
from direct_hermes_reasoning_probe import PROFILE, _output_path


def job_summary(job):
    if (not isinstance(job, dict) or not isinstance(job.get("id"), str)
            or not job["id"] or job.get("profile") != PROFILE):
        raise AssertionError("invalid scoped job identity")
    return {"identity_present": True, "profile_matches": True,
            "enabled_is_boolean": isinstance(job.get("enabled"), bool),
            "schedule_is_object": isinstance(job.get("schedule"), dict)}


async def get(client, route, params=None):
    response = await client.get(route, params=params)
    if response.status_code != 200:
        raise RuntimeError("secondary read failed")
    return response.json()


async def exercise(client, evidence):
    active = await get(client, "/api/profiles/active")
    if not isinstance(active, dict) or any(not isinstance(active.get(k), str) or not active[k]
                                           for k in ("active", "current")):
        raise AssertionError("invalid active profile response")
    evidence["active_profile"] = {"fields": ["active", "current"],
                                  "both_names_present": True,
                                  "startup_matches_running": active["active"] == active["current"]}
    jobs = await get(client, "/api/cron/jobs", {"profile": PROFILE})
    if not isinstance(jobs, list):
        raise AssertionError("stock jobs must be bare array")
    evidence["jobs"] = {"row_count": len(jobs), "top_level_type": "array",
                        "rows": [job_summary(job) for job in jobs]}
    targets = await get(client, "/api/cron/delivery-targets")
    if not isinstance(targets, dict) or not isinstance(targets.get("targets"), list):
        raise AssertionError("invalid delivery target envelope")
    if any(not isinstance(row, dict) or not isinstance(row.get("id"), str)
           or not isinstance(row.get("name"), str) for row in targets["targets"]):
        raise AssertionError("invalid delivery target fields")
    evidence["delivery_targets"] = {"row_count": len(targets["targets"]),
                                    "mapped_fields": ["id", "name"], "profile_parameter": False}
    evidence["detail_runs"] = {"verified": False, "reason": "empty_inventory"}
    if jobs:
        job_id = jobs[0]["id"]
        if job_id in (".", "..") or "/" in job_id or "\\" in job_id:
            raise AssertionError("invalid job path segment")
        route = "/api/cron/jobs/" + quote(job_id, safe="")
        detail = await get(client, route, {"profile": PROFILE})
        summary = job_summary(detail)
        if detail["id"] != job_id:
            raise AssertionError("detail identity mismatch")
        runs = await get(client, route + "/runs", {"profile": PROFILE, "limit": 5})
        if (not isinstance(runs, dict) or runs.get("limit") != 5
                or not isinstance(runs.get("runs"), list) or len(runs["runs"]) > 5):
            raise AssertionError("invalid runs envelope")
        for run in runs["runs"]:
            if (not isinstance(run, dict) or run.get("profile") != PROFILE
                    or not isinstance(run.get("id"), str) or not run["id"].startswith("cron_" + job_id + "_")):
                raise AssertionError("run identity mismatch")
        evidence["detail_runs"] = {"verified": True, "detail": summary,
                                   "run_count": len(runs["runs"]), "limit": 5,
                                   "all_run_identities_match": True}


async def _run_authenticated(credentials, evidence):
    async with authenticated(credentials, evidence, base=stock_probe.HTTPS_ORIGIN,
                             origin=stock_probe.HTTPS_ORIGIN) as (client, _ticket):
        await exercise(client, evidence)


def run(output: Path):
    with redirect_stdout(io.StringIO()):
        stock_probe.validate()
    credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text())
    evidence = {"sanitized": True, "source_pin": stock_probe.PIN, "outcome": "failed",
                "profile": PROFILE, "bounded_read_only": True, "cron_mutations": 0,
                "cleanup_errors": []}
    try:
        asyncio.run(_run_authenticated(credentials, evidence))
        if evidence["cleanup_errors"]:
            raise AssertionError("authentication cleanup failed")
        evidence["outcome"] = "passed" if evidence["detail_runs"]["verified"] else "partial"
    except Exception as error:
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError("Secondary probe failed; see sanitized evidence") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Secondary reads {evidence['outcome']}; sanitized evidence: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    run(_output_path(parser.parse_args().output))
