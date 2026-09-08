#!/usr/bin/env python3
"""Bounded stock session-export probe for the disposable fixture.

Session discovery/detail/export are GET-only and do not mutate session/provider
resources.  The shared authentication wrapper still performs its bounded login,
ticket, and logout control requests.
"""

from __future__ import annotations

import argparse
import asyncio
from contextlib import redirect_stdout
import hashlib
import io
import json
import re

from direct_hermes_capture import write_fixture
from direct_hermes_identity_probe import authenticated
from direct_hermes_reasoning_probe import PROFILE, _output_path
import direct_hermes_probe as stock_probe


SEARCH_ROUTE = "/api/sessions/search"
DETAIL_ROUTE = "/api/sessions/{session_id}"
EXPORT_ROUTE = "/api/sessions/{session_id}/export"
SEARCH_MARKER = "SEMREH_SLICE3_APP_RELAUNCH_SEED_AUTH_V1"
MAXIMUM_BYTES = 20 * 1024 * 1024


def _keys(value):
    return sorted(str(key) for key in value) if isinstance(value, dict) else []


def _route_segment(value):
    if not isinstance(value, str) or not value or value in {".", ".."}:
        raise AssertionError("synthetic search result has unsafe session ID")
    if "/" in value or "\\" in value or "?" in value or "#" in value:
        raise AssertionError("synthetic search result has unsafe session ID")
    if re.search(r"[\x00-\x1f\x7f]", value):
        raise AssertionError("synthetic search result has unsafe session ID")
    return value


async def _get_json(client, route, params):
    response = await client.get(route, params=params)
    if response.status_code != 200:
        raise AssertionError("stock read failed")
    return response.json()


async def validate_server(client):
    inventory = await _get_json(client, "/api/profiles", {})
    defaults = [row for row in inventory.get("profiles", [])
                if isinstance(row, dict) and row.get("name") == PROFILE]
    if len(defaults) != 1 or defaults[0].get("path") != str(stock_probe.RUNTIME / "home"):
        raise AssertionError("unexpected profile home")
    active = await _get_json(client, "/api/profiles/active", {})
    if active.get("current") != PROFILE or active.get("active") != PROFILE:
        raise AssertionError("unexpected running profile")


async def _synthetic_session(client):
    payload = await _get_json(client, SEARCH_ROUTE, {
        "q": SEARCH_MARKER, "profile": PROFILE, "limit": 20,
    })
    rows = payload.get("results") if isinstance(payload, dict) else None
    matches = [row for row in rows or [] if isinstance(row, dict)
               and SEARCH_MARKER in (row.get("snippet") or "")]
    if len(matches) != 1 or len(rows) != 1:
        raise AssertionError("bounded search did not identify one synthetic session")
    session_id = _route_segment(matches[0].get("session_id"))
    detail = await _get_json(client, DETAIL_ROUTE.format(session_id=session_id), {
        "profile": PROFILE,
    })
    if detail.get("id") != session_id or detail.get("profile") != PROFILE:
        raise AssertionError("synthetic detail identity/profile mismatch")
    return session_id


async def _bounded_export(client, route, params):
    data = bytearray()
    async with client.stream("GET", route, params=params) as response:
        if response.status_code != 200:
            raise AssertionError("stock export failed")
        async for chunk in response.aiter_bytes():
            if len(data) + len(chunk) > MAXIMUM_BYTES:
                raise AssertionError("stock export exceeded byte bound")
            data.extend(chunk)
    return bytes(data)


def _export_summary(payload, expected_id, byte_count, digest):
    if not isinstance(payload, dict) or payload.get("id") != expected_id:
        raise AssertionError("export identity mismatch")
    messages = payload.get("messages")
    if "profile" in payload and payload["profile"] != PROFILE:
        raise AssertionError("export profile mismatch")
    if not isinstance(messages, list) or not all(isinstance(row, dict) for row in messages):
        raise AssertionError("export messages are not complete object rows")
    row_keys = sorted({str(key) for row in messages for key in row})
    if messages and not all("id" in row and "role" in row for row in messages):
        raise AssertionError("export message row is missing stock identity/role")
    return {
        "top_level_keys": _keys(payload),
        "message_row_keys": row_keys,
        "message_count": len(messages),
        "byte_count": byte_count,
        "sha256": digest,
        "identity_verified": True,
        "profile_verified": PROFILE,
    }


async def exercise(client, evidence):
    await validate_server(client)
    session_id = await _synthetic_session(client)
    route = EXPORT_ROUTE.format(session_id=session_id)
    data = await _bounded_export(client, route, {"profile": PROFILE})
    try:
        payload = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise AssertionError("stock export was not complete JSON") from None
    evidence["request"] = {"method": "GET", "path_template": EXPORT_ROUTE,
                           "params": {"profile": PROFILE}, "maximum_bytes": MAXIMUM_BYTES}
    evidence["response"] = _export_summary(
        payload, session_id, len(data), hashlib.sha256(data).hexdigest()
    )


async def authenticated_exercise(credentials, evidence):
    async with authenticated(credentials, evidence, base=stock_probe.HTTPS_ORIGIN,
                             origin=stock_probe.HTTPS_ORIGIN) as (client, _ticket):
        await exercise(client, evidence)


def run(output):
    with redirect_stdout(io.StringIO()):
        stock_probe.validate()
    credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text())
    evidence = {"outcome": "failed", "sanitized": True, "source_pin": stock_probe.PIN,
                "cleanup_errors": [], "session_provider_mutations": 0, "provider_calls": 0,
                "authentication_control_requests_excluded": True,
                "native_ui_verified": False}
    try:
        asyncio.run(authenticated_exercise(credentials, evidence))
        if evidence["cleanup_errors"]:
            raise AssertionError("authentication cleanup failed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError("Export probe failed; see sanitized evidence") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Export probe passed; sanitized evidence: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    run(_output_path(parser.parse_args().output))
