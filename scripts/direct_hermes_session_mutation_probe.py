#!/usr/bin/env python3
"""Bounded stock session metadata mutation probe.

The probe creates two fresh disposable sessions, warms each with one ordinary
fixture turn, and exercises the official profile-scoped PATCH contract against
one of them.  It never accepts a caller-supplied session ID and never deletes a
database row.  Evidence is limited to request shapes, booleans, and counts.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import uuid
from pathlib import Path
from typing import Any

from websockets.asyncio.client import connect

import direct_hermes_probe as stock_probe
from direct_hermes_capture import write_fixture
from direct_hermes_identity_probe import authenticated
from direct_hermes_reasoning_probe import (
    PROFILE,
    Probe,
    RPC_TIMEOUT,
    _json_frame,
    _output_path,
)


PATCH_ROUTE = "/api/sessions/{session_id}"
LIST_ROUTE = "/api/profiles/sessions"
LIST_LIMIT = 500
SEED_TEXT = "SEMREH_S4_SESSION_MUTATION_WARMUP_V1"
MUTATION_TITLE = "SEMREH_S4_SESSION_MUTATION_TITLE_V1"
STORED_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _row_id(row: dict[str, Any]) -> str | None:
    aliases = [row.get(key) for key in ("id", "session_id") if row.get(key) is not None]
    if aliases and (any(not isinstance(value, str) or not value for value in aliases)
                    or len(set(aliases)) != 1):
        raise AssertionError("session row durable identity aliases disagree")
    return aliases[0] if aliases else None


def _row_metadata(row: dict[str, Any], expected_id: str) -> dict[str, Any]:
    if not isinstance(row, dict) or _row_id(row) != expected_id:
        raise AssertionError("session row did not identify the owned durable session")
    if row.get("profile") != PROFILE or row.get("is_default_profile") is not True:
        raise AssertionError("session row escaped the requested default profile")
    if not isinstance(row.get("archived"), bool) or not isinstance(row.get("pinned"), bool):
        raise AssertionError("session row metadata flags are not booleans")
    title = row.get("title")
    if title is not None and not isinstance(title, str):
        raise AssertionError("session row title is not text or null")
    return {
        "title": title,
        "archived": row["archived"],
        "pinned": row["pinned"],
        "profile": row["profile"],
    }


def _list_summary(
    payload: Any,
    *,
    archived: str,
    requested_limit: int,
    owned_ids: set[str] | None = None,
) -> dict[str, Any]:
    """Validate and summarize the official profile session-list envelope."""
    if not isinstance(payload, dict):
        raise AssertionError("session list response is not an object")
    required = {"sessions", "total", "profile_totals", "limit", "offset", "errors"}
    if not required <= set(payload):
        raise AssertionError("session list envelope is missing stock fields")
    rows = payload["sessions"]
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise AssertionError("session list rows are not objects")
    if not _is_int(payload["total"]) or payload["total"] < 0:
        raise AssertionError("session list total is not a non-negative integer")
    totals = payload["profile_totals"]
    if totals != {PROFILE: payload["total"]}:
        raise AssertionError("session list is not default-profile scoped")
    if payload["limit"] != requested_limit or payload["offset"] != 0:
        raise AssertionError("session list pagination readback differs from request")
    if payload["errors"] != []:
        raise AssertionError("session list reported profile errors")
    row_keys: set[str] = set()
    metadata: dict[str, dict[str, Any]] = {}
    for row in rows:
        row_keys.update(str(key) for key in row)
        identifier = _row_id(row)
        if identifier is None:
            raise AssertionError("session list row omitted durable identity")
        if identifier in metadata:
            raise AssertionError("session list returned a duplicate durable identity")
        metadata[identifier] = _row_metadata(row, identifier)
        if archived == "exclude" and row["archived"]:
            raise AssertionError("archived=exclude returned an archived session")
        if archived == "only" and not row["archived"]:
            raise AssertionError("archived=only returned an unarchived session")
    if len(rows) > requested_limit and any(
        not bool(row.get("pinned")) for row in rows[requested_limit:]
    ):
        raise AssertionError("session list exceeded its limit with a non-pinned row")
    owned_present = set() if owned_ids is None else set(metadata) & owned_ids
    return {
        "top_level_keys": sorted(str(key) for key in payload),
        "row_keys": sorted(row_keys),
        "row_count": len(rows),
        "total": payload["total"],
        "profile_totals_keys": sorted(str(key) for key in totals),
        "errors_count": 0,
        "filter_verified": archived,
        "owned_rows_present": len(owned_present),
        "metadata": metadata,
    }


def _patch_summary(payload: Any, expected: dict[str, Any]) -> dict[str, Any]:
    """Require the PATCH acknowledgement to contain the requested readback."""
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        raise AssertionError("session PATCH did not return ok=true")
    for key, value in expected.items():
        if payload.get(key) != value:
            raise AssertionError(f"session PATCH did not read back {key}")
    return {
        "top_level_keys": sorted(str(key) for key in payload),
        "ok": True,
        "readback_fields": sorted(expected),
    }


def _assert_sibling_unchanged(
    before: dict[str, Any], after: dict[str, Any], sibling_id: str
) -> None:
    if sibling_id not in before or sibling_id not in after:
        raise AssertionError("owned sibling disappeared from session list")
    if before[sibling_id] != after[sibling_id]:
        raise AssertionError("targeted PATCH changed the owned sibling metadata")


def _same_metadata(left: dict[str, Any], right: dict[str, Any]) -> bool:
    # The stock list projection may represent a cleared title as either null or
    # an empty string, while PATCH uses empty string as the clear operation.
    return (
        (left.get("title") or None) == (right.get("title") or None)
        and left.get("archived") == right.get("archived")
        and left.get("pinned") == right.get("pinned")
        and left.get("profile") == right.get("profile")
    )


def _owned_binding(created: Any) -> tuple[str, str]:
    if not isinstance(created, dict):
        raise AssertionError("session.create returned no object")
    runtime = created.get("session_id")
    aliases = [
        created.get(key)
        for key in ("stored_session_id", "session_key", "resumed")
        if created.get(key) is not None
    ]
    if not isinstance(runtime, str) or not runtime:
        raise AssertionError("session.create omitted runtime identity")
    if not aliases or any(not isinstance(value, str) or not value for value in aliases):
        raise AssertionError("session.create omitted durable identity")
    if len(set(aliases)) != 1 or not STORED_ID.fullmatch(aliases[0]):
        raise AssertionError("session.create durable aliases disagreed")
    if created.get("profile") is not None and created.get("profile") != PROFILE:
        raise AssertionError("session.create escaped the default profile")
    return runtime, aliases[0]


async def _list(client, *, archived: str) -> tuple[dict[str, Any], dict[str, Any]]:
    params = {
        "profile": PROFILE,
        "limit": LIST_LIMIT,
        "offset": 0,
        "archived": archived,
        "order": "recent",
    }
    response = await client.get(LIST_ROUTE, params=params)
    if response.status_code != 200:
        raise RuntimeError("profile session list request failed")
    payload = response.json()
    return payload, {"method": "GET", "path": LIST_ROUTE, "params": params}


async def _patch(client, stored_id: str, body: dict[str, Any]) -> tuple[Any, dict[str, Any]]:
    response = await client.patch(
        PATCH_ROUTE.format(session_id=stored_id),
        json={**body, "profile": PROFILE},
    )
    if response.status_code != 200:
        raise RuntimeError("session metadata PATCH request failed")
    return response.json(), {
        "method": "PATCH",
        "path": PATCH_ROUTE,
        "profile_scoped": True,
        "body_fields": sorted(body),
    }


async def _create_and_warm(probe: Probe, owned_runtimes: list[str]) -> tuple[str, str]:
    created = await probe.rpc("session.create", {
        "profile": PROFILE,
        "cwd": str(stock_probe.RUNTIME / "tools"),
        "model": "semreh-fixture",
        "provider": "custom",
        "reasoning_effort": "low",
    })
    runtime, stored = _owned_binding(created)
    # Register immediately after create so a failed warmup still gets closed.
    owned_runtimes.append(runtime)
    start = len(probe.frames)
    accepted = await probe.rpc("prompt.submit", {"session_id": runtime, "text": SEED_TEXT})
    if not isinstance(accepted, dict) or accepted.get("status") not in ("streaming", "queued"):
        raise AssertionError("owned warmup prompt was not accepted")
    await probe.wait_terminal(runtime, start)
    await probe.wait_idle(runtime)
    return runtime, stored


async def _restore_metadata(
    client,
    target_id: str,
    target_before: dict[str, Any],
    sibling_id: str,
    sibling_before: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    response_payload, request = await _patch(client, target_id, {
        "title": target_before["title"] or "",
        "pinned": target_before["pinned"],
        "archived": target_before["archived"],
    })
    _patch_summary(response_payload, {
        "pinned": target_before["pinned"],
        "archived": target_before["archived"],
    })
    final_payload, final_request = await _list(client, archived="include")
    final = _list_summary(final_payload, archived="include",
                          requested_limit=LIST_LIMIT,
                          owned_ids={target_id, sibling_id})
    if target_id not in final["metadata"] or not _same_metadata(
        final["metadata"][target_id], target_before
    ):
        raise AssertionError("final PATCH did not restore initial target metadata")
    _assert_sibling_unchanged({sibling_id: sibling_before}, final["metadata"], sibling_id)
    return {"method": "PATCH", "path": PATCH_ROUTE, "profile_scoped": True,
            "body_fields": ["archived", "pinned", "title"]}, final_request


async def _exercise(credentials: dict[str, Any], evidence: dict[str, Any]) -> None:
    base = stock_probe.HTTPS_ORIGIN
    ws_base = base.replace("https://", "wss://")
    runtimes: list[str] = []
    target_id: str | None = None
    target_before: dict[str, Any] | None = None
    sibling_id: str | None = None
    sibling_before: dict[str, Any] | None = None
    baseline_proven = False
    restoration_done = False
    async with authenticated(credentials, evidence, base=base, origin=base) as (client, ticket):
        ws = None
        probe: Probe | None = None
        try:
            evidence["phase"] = "gateway ready and two owned sessions"
            ws = await connect(f"{ws_base}/api/ws?ticket={ticket}", origin=base, proxy=None)
            ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("stock gateway did not become ready")
            probe = Probe(ws, client, {"frames": []})
            target_runtime, target_id = await _create_and_warm(probe, runtimes)
            sibling_runtime, sibling_id = await _create_and_warm(probe, runtimes)
            owned_ids = {target_id, sibling_id}
            if target_id == sibling_id:
                raise AssertionError("two owned sessions reused one durable identity")

            evidence["phase"] = "initial profile list"
            initial_payload, initial_request = await _list(client, archived="include")
            initial = _list_summary(initial_payload, archived="include", requested_limit=LIST_LIMIT,
                                    owned_ids=owned_ids)
            if initial["owned_rows_present"] != 2:
                raise AssertionError("initial list did not contain both owned sessions")
            target_before = initial["metadata"][target_id]
            sibling_before = initial["metadata"][sibling_id]
            if target_before["profile"] != PROFILE or sibling_before["profile"] != PROFILE:
                raise AssertionError("owned sessions did not retain default profile ownership")
            baseline_proven = True

            checks: list[dict[str, Any]] = []
            mutation_title = (
                f"{MUTATION_TITLE}_{uuid.uuid4().hex[:16]}"
            )
            mutation_steps = [
                ({"title": mutation_title}, {"title": mutation_title}),
                ({"pinned": True}, {"pinned": True}),
                ({"archived": True}, {"archived": True}),
                ({"archived": False}, {"archived": False}),
            ]
            for body, expected in mutation_steps:
                evidence["phase"] = f"PATCH {','.join(sorted(body))}"
                response_payload, request = await _patch(client, target_id, body)
                patch = _patch_summary(response_payload, expected)
                listed_payload, list_request = await _list(client, archived="include")
                listed = _list_summary(listed_payload, archived="include",
                                       requested_limit=LIST_LIMIT, owned_ids=owned_ids)
                _assert_sibling_unchanged(
                    initial["metadata"] if not checks else listed_before,
                    listed["metadata"], sibling_id,
                )
                if listed["metadata"][target_id][next(iter(expected))] != next(iter(expected.values())):
                    raise AssertionError("profile list did not read back PATCH metadata")
                checks.append({"request": request, "response": patch,
                               "readback": list_request})
                listed_before = listed["metadata"]

            evidence["phase"] = "positive archived-only and exclusion filters"
            archived_payload, archived_request = await _list(client, archived="only")
            archived_summary = _list_summary(archived_payload, archived="only",
                                             requested_limit=LIST_LIMIT, owned_ids=owned_ids)
            if target_id in archived_summary["metadata"]:
                raise AssertionError("restored target remained in archived=only")
            # Re-archive solely for the positive archived-only contract.
            response_payload, request = await _patch(client, target_id, {"archived": True})
            _patch_summary(response_payload, {"archived": True})
            only_payload, only_request = await _list(client, archived="only")
            only_summary = _list_summary(only_payload, archived="only",
                                         requested_limit=LIST_LIMIT, owned_ids=owned_ids)
            if only_summary["owned_rows_present"] < 1 or only_summary["total"] < 1:
                raise AssertionError("archived-only list did not provide a positive count")
            exclude_payload, exclude_request = await _list(client, archived="exclude")
            exclude_summary = _list_summary(exclude_payload, archived="exclude",
                                            requested_limit=LIST_LIMIT, owned_ids=owned_ids)
            if target_id in exclude_summary["metadata"]:
                raise AssertionError("archived target remained in archived=exclude")

            evidence["phase"] = "restore initial metadata"
            restore_request, final_request = await _restore_metadata(
                client, target_id, target_before, sibling_id, sibling_before
            )
            restoration_done = True
            evidence["mutation_contract"] = {
                "request": {"method": "PATCH", "path": PATCH_ROUTE,
                            "profile_field": True},
                "body_fields_verified": ["title", "pinned", "archived", "profile"],
                "readback_fields_verified": ["ok", "title", "pinned", "archived"],
                "owned_sessions_created": 2,
                "default_profile_verified": True,
                "origin_verified": base == stock_probe.HTTPS_ORIGIN,
                "sibling_unchanged": True,
                "archived_only_positive_total": only_summary["total"],
                "archived_only_owned_rows": only_summary["owned_rows_present"],
                "archived_exclude_omits_target": True,
                "steps_verified": len(checks) + 1,
                "mutation_steps": checks,
                "request_shapes": [initial_request, archived_request, only_request,
                                    exclude_request, restore_request, final_request],
            }
        finally:
            if baseline_proven and not restoration_done and probe is not None:
                try:
                    await _restore_metadata(
                        client, target_id, target_before, sibling_id, sibling_before
                    )  # type: ignore[arg-type]
                    restoration_done = True
                except Exception as error:
                    evidence["cleanup_errors"].append(
                        {"operation": "restore_session_metadata", "type": type(error).__name__}
                    )
            if ws is not None:
                for runtime in runtimes:
                    try:
                        if probe is None:
                            raise RuntimeError("gateway probe was not initialized")
                        closed = await probe.rpc(
                            "session.close", {"session_id": runtime}
                        )
                        if not isinstance(closed, dict) or closed.get("closed") is not True:
                            evidence["cleanup_errors"].append("session.close not confirmed")
                    except Exception as error:
                        evidence["cleanup_errors"].append(type(error).__name__)
                await ws.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    return parser


def run(output: Path) -> None:
    stock_probe.validate()
    credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text(encoding="utf-8"))
    evidence: dict[str, Any] = {
        "sanitized": True,
        "outcome": "failed",
        "source_pin": stock_probe.PIN,
        "deployment": stock_probe.HTTPS_ORIGIN,
        "profile": PROFILE,
        "phase": "startup",
        "cleanup_errors": [],
    }
    try:
        asyncio.run(_exercise(credentials, evidence))
        if evidence["cleanup_errors"]:
            raise AssertionError("owned runtime cleanup was not confirmed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError(f"Session mutation probe failed; evidence: {output}") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Session mutation assertions passed; sanitized evidence: {output}")


if __name__ == "__main__":
    args = build_parser().parse_args()
    run(_output_path(args.output))
