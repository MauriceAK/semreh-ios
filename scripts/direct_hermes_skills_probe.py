#!/usr/bin/env python3
"""Read only stock skills inventory and one SKILL.md in the guarded fixture.

No skill mutation or execution occurs. Evidence includes only contract checks,
counts and known schema fields; skill names, content and paths stay in memory.
"""

from __future__ import annotations

import argparse
import asyncio
from contextlib import redirect_stdout
import io
import json
from pathlib import Path

from direct_hermes_capture import write_fixture
from direct_hermes_identity_probe import authenticated
import direct_hermes_probe as stock_probe
from direct_hermes_reasoning_probe import PROFILE, _output_path

LIST_ROUTE = "/api/skills"
CONTENT_ROUTE = "/api/skills/content"
KNOWN_LIST_FIELDS = {"name", "category", "description", "enabled", "usage", "provenance"}


def list_summary(payload) -> dict:
    if not isinstance(payload, list):
        raise AssertionError("stock skills response must be a bare array")
    known_fields = set()
    enabled_count = 0
    for row in payload:
        if not isinstance(row, dict):
            raise AssertionError("skill row must be an object")
        if not isinstance(row.get("name"), str) or not row["name"].strip():
            raise AssertionError("skill row must contain a name")
        if not isinstance(row.get("enabled"), bool):
            raise AssertionError("stock enabled flag must be boolean")
        for field in ("category", "description"):
            if row.get(field) is not None and not isinstance(row[field], str):
                raise AssertionError("skill descriptive field has invalid type")
        known_fields.update(KNOWN_LIST_FIELDS.intersection(row))
        enabled_count += int(row["enabled"])
    return {
        "top_level_type": "array", "row_count": len(payload),
        "known_row_fields": sorted(known_fields), "enabled_count": enabled_count,
        "disabled_count": len(payload) - enabled_count,
    }


def content_summary(payload, requested_name: str) -> dict:
    if not isinstance(payload, dict):
        raise AssertionError("stock skill content response must be an object")
    if payload.get("name") != requested_name:
        raise AssertionError("skill content identity differs from requested skill")
    if not isinstance(payload.get("content"), str) or not isinstance(payload.get("path"), str):
        raise AssertionError("stock content and path fields must be text")
    return {
        "known_fields": ["content", "name", "path"],
        "requested_name_matches": True, "content_is_text": True,
        "content_nonempty": bool(payload["content"]), "path_is_text": True,
    }


async def exercise(client, evidence: dict) -> None:
    response = await client.get(LIST_ROUTE, params={"profile": PROFILE})
    if response.status_code != 200:
        raise RuntimeError("skills list request failed")
    rows = response.json()
    evidence["list"] = {
        "method": "GET", "path": LIST_ROUTE, "profile": PROFILE,
        "response_status": 200, "response": list_summary(rows),
    }
    evidence["content"] = {"verified": False, "reason": "empty_inventory"}
    if not rows:
        return
    name = rows[0]["name"]
    response = await client.get(CONTENT_ROUTE, params={"profile": PROFILE, "name": name})
    evidence["content"] = {
        "method": "GET", "path": CONTENT_ROUTE, "profile": PROFILE,
        "query_fields": ["name", "profile"], "response_status": response.status_code,
        "verified": False,
    }
    if response.status_code == 404:
        evidence["content"]["reason"] = "listed_skill_unavailable"
        return
    if response.status_code != 200:
        raise RuntimeError("skill content request failed")
    evidence["content"]["response"] = content_summary(response.json(), name)
    evidence["content"]["verified"] = True


async def _run_authenticated(credentials: dict, evidence: dict) -> None:
    async with authenticated(credentials, evidence, base=stock_probe.HTTPS_ORIGIN,
                             origin=stock_probe.HTTPS_ORIGIN) as (client, _ticket):
        await exercise(client, evidence)


def run(output: Path) -> None:
    # Reuse the exact pin/clean-tree/config/path guards without printing host paths.
    with redirect_stdout(io.StringIO()):
        stock_probe.validate()
    credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text())
    evidence = {
        "sanitized": True, "outcome": "failed", "source_pin": stock_probe.PIN,
        "deployment": stock_probe.HTTPS_ORIGIN, "profile": PROFILE,
        "bounded_read_only": True, "skill_mutations": 0, "cleanup_errors": [],
    }
    try:
        asyncio.run(_run_authenticated(credentials, evidence))
        if evidence["cleanup_errors"]:
            raise AssertionError("fixture authentication cleanup failed")
        evidence["outcome"] = "passed" if evidence["content"]["verified"] else "partial"
    except Exception as error:
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError("Skills probe failed; see sanitized evidence") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Skills probe {evidence['outcome']}; sanitized evidence: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    run(_output_path(parser.parse_args().output))
