#!/usr/bin/env python3
"""One guarded future cron fixture; pause/resume only, never trigger execution."""
import argparse
import asyncio
from contextlib import redirect_stdout
from datetime import datetime, timezone
import io
import json
from pathlib import Path
from urllib.parse import quote
import uuid

from direct_hermes_capture import write_fixture
from direct_hermes_identity_probe import authenticated, _config_hash
import direct_hermes_probe as stock_probe
from direct_hermes_reasoning_probe import PROFILE, _output_path

ROUTE = "/api/cron/jobs"
SCHEDULE = "2099-01-01T00:00:00+00:00"


def owned(job, marker):
    if (not isinstance(job, dict) or job.get("name") != marker or job.get("prompt") != marker
            or job.get("profile") != PROFILE or not isinstance(job.get("id"), str)
            or not job["id"] or job["id"] in (".", "..") or any(c in job["id"] for c in "/\\")):
        raise AssertionError("fixture ownership not proven")
    return job["id"]


def future_schedule(job):
    schedule = job.get("schedule")
    if not isinstance(schedule, dict) or schedule.get("kind") != "once":
        raise AssertionError("fixture must remain one-shot")
    when = datetime.fromisoformat(schedule.get("run_at", ""))
    if when.tzinfo is None or when.astimezone(timezone.utc) != datetime.fromisoformat(SCHEDULE):
        raise AssertionError("fixture schedule changed")


async def read(client, route=ROUTE):
    response = await client.get(route, params={"profile": PROFILE})
    if response.status_code != 200:
        raise RuntimeError("fixture read failed")
    return response.json()


async def exercise(client, evidence):
    response = await client.get("/api/profiles")
    if response.status_code != 200:
        raise RuntimeError("profile scope verification failed")
    payload = response.json()
    rows = payload.get("profiles") if isinstance(payload, dict) else None
    matches = [row for row in rows if isinstance(row, dict) and row.get("name") == PROFILE] if isinstance(rows, list) else []
    expected_home = stock_probe.RUNTIME / "home"
    if (len(matches) != 1 or matches[0].get("path") != str(expected_home)
            or expected_home.is_symlink() or expected_home.resolve() != expected_home):
        raise AssertionError("endpoint profile is not the dedicated fixture home")
    evidence["endpoint_profile_root_verified"] = True
    if await read(client) != []:
        raise AssertionError("cron inventory must initially be empty")
    marker = "SEMREH_CRON_PROBE_" + uuid.uuid4().hex
    job_id = None
    try:
        evidence["phase"] = "create"
        evidence["create_attempts"] = 1
        try:
            response = await client.post(ROUTE, params={"profile": PROFILE}, json={
                "name": marker, "prompt": marker, "schedule": SCHEDULE,
                "deliver": "local", "skills": [], "model": "semreh-fixture", "provider": "custom",
            })
            if response.status_code != 200:
                raise RuntimeError("create acknowledgement failed")
            job_id = owned(response.json(), marker)
        except Exception:
            # Creation may persist before registration/transport failure. Never
            # resend; resolve only this invocation's exact synthetic identity.
            rows = await read(client)
            if not isinstance(rows, list):
                raise AssertionError("invalid inventory during create recovery")
            matches = [row for row in rows if isinstance(row, dict) and row.get("name") == marker]
            if len(matches) != 1:
                raise AssertionError("ambiguous create could not identify one owned job")
            job_id = owned(matches[0], marker)
            evidence["create_ack_recovered_by_unique_lookup"] = True
        route = ROUTE + "/" + quote(job_id, safe="")
        initial = await read(client, route)
        if owned(initial, marker) != job_id:
            raise AssertionError("created detail identity mismatch")
        future_schedule(initial)
        if initial.get("enabled") is not True or initial.get("state") != "scheduled":
            raise AssertionError("created fixture is not scheduled as expected")
        for action, enabled, state in (("pause", False, "paused"), ("resume", True, "scheduled")):
            evidence["phase"] = action
            response = await client.post(route + "/" + action, params={"profile": PROFILE})
            if response.status_code != 200:
                raise RuntimeError("cron mutation failed")
            receipt = response.json()
            if owned(receipt, marker) != job_id or receipt.get("enabled") is not enabled or receipt.get("state") != state:
                raise AssertionError("mutation receipt mismatch")
            future_schedule(receipt)
            fresh = await read(client, route)
            if owned(fresh, marker) != job_id or fresh.get("enabled") is not enabled or fresh.get("state") != state:
                raise AssertionError("mutation readback mismatch")
            future_schedule(fresh)
            if enabled:
                next_run = datetime.fromisoformat(fresh.get("next_run_at", ""))
                if next_run.tzinfo is None or next_run.astimezone(timezone.utc) != datetime.fromisoformat(SCHEDULE):
                    raise AssertionError("resumed fixture is not scheduled for exact future instant")
            evidence[action] = {"receipt_verified": True, "readback_verified": True,
                                "enabled": enabled, "state": state}
    except Exception as error:
        evidence["operation_error_type"] = type(error).__name__
        raise
    finally:
        if job_id is not None:
            route = ROUTE + "/" + quote(job_id, safe="")
            try:
                if owned(await read(client, route), marker) != job_id:
                    raise AssertionError("cleanup target changed")
                response = await client.delete(route, params={"profile": PROFILE})
                if response.status_code != 200 or response.json().get("ok") is not True:
                    raise AssertionError("cleanup delete unconfirmed")
                if await read(client) != []:
                    raise AssertionError("empty inventory was not restored")
                evidence["restored_empty_inventory"] = True
            except Exception as error:
                evidence["cleanup_errors"].append({"operation": "owned_job_delete", "type": type(error).__name__})
                raise RuntimeError("owned fixture cleanup failed") from None


async def _authenticated_run(credentials, evidence):
    async with authenticated(credentials, evidence, base=stock_probe.HTTPS_ORIGIN,
                             origin=stock_probe.HTTPS_ORIGIN) as (client, _ticket):
        await exercise(client, evidence)


def run(output: Path):
    with redirect_stdout(io.StringIO()):
        stock_probe.validate()
    before = _config_hash(stock_probe.RUNTIME)
    credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text())
    evidence = {"sanitized": True, "outcome": "failed", "source_pin": stock_probe.PIN,
                "profile": PROFILE, "future_fixture_year": 2099, "trigger_requests": 0,
                "cleanup_errors": [], "restored_empty_inventory": False}
    try:
        asyncio.run(_authenticated_run(credentials, evidence))
        if evidence["cleanup_errors"] or not evidence["restored_empty_inventory"]:
            raise AssertionError("cleanup incomplete")
        if _config_hash(stock_probe.RUNTIME) != before:
            raise AssertionError("configuration changed")
        evidence["configuration_unchanged"] = True
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError("Cron fixture probe failed; inspect sanitized evidence") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Cron mutation probe passed; sanitized evidence: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    run(_output_path(parser.parse_args().output))
