#!/usr/bin/env python3
"""Bounded edit/regenerate/delete probe for the owned stock Hermes fixture.

Only fresh sessions created by this invocation are addressed. The probe never
accepts session, profile, origin, model, provider, or cwd overrides and never
retries an ambiguous destructive request. Evidence contains counts, booleans,
field names, error codes, and transcript hashes—not message or event content.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
from pathlib import Path
from typing import Any

from websockets.asyncio.client import connect

import direct_hermes_probe as stock_probe
from direct_hermes_branch_probe import _canonical_rows
from direct_hermes_capture import write_fixture
from direct_hermes_identity_probe import authenticated
from direct_hermes_reasoning_probe import PROFILE, Probe, RPC_TIMEOUT, _json_frame, _output_path
from direct_hermes_session_mutation_probe import _owned_binding


MESSAGES_ROUTE = "/api/sessions/{session_id}/messages"
DETAIL_ROUTE = "/api/sessions/{session_id}"
MESSAGE_LIMIT = 100
TARGET_TURNS = ("SEMREH_S4_DESTRUCTIVE_TARGET_A", "SEMREH_S4_DESTRUCTIVE_TARGET_B")
SIBLING_TURNS = ("SEMREH_S4_DESTRUCTIVE_SIBLING_A",)
EDIT_TEXT = "SEMREH_S4_DESTRUCTIVE_TARGET_B_EDITED"
EMPTY_PREFIX_TEXT = "SEMREH_S4_DESTRUCTIVE_EMPTY_PREFIX_REPLACEMENT"
MISSING_ROW_ID = 9_223_372_036_854_775_807


def _digest(rows: list[tuple[str, str]]) -> dict[str, Any]:
    encoded = json.dumps(rows, ensure_ascii=False, separators=(",", ":"))
    return {
        "row_count": len(rows),
        "user_count": sum(role == "user" for role, _ in rows),
        "role_sequence": [role for role, _ in rows],
        "content_sha256": hashlib.sha256(encoded.encode()).hexdigest(),
    }


def _history(payload: Any, expected_id: str) -> tuple[list[tuple[str, str]], list[int]]:
    if not isinstance(payload, dict) or payload.get("session_id") != expected_id:
        raise AssertionError("messages resolver returned an unexpected durable identity")
    raw = payload.get("messages")
    rows = _canonical_rows(raw)
    user_row_ids: list[int] = []
    for row in raw if isinstance(raw, list) else []:
        if not isinstance(row, dict) or row.get("role") != "user":
            continue
        row_id = row.get("id")
        if not isinstance(row_id, int) or isinstance(row_id, bool) or row_id <= 0:
            raise AssertionError("canonical user row omitted a positive durable row id")
        user_row_ids.append(row_id)
    if len(user_row_ids) != sum(role == "user" for role, _ in rows):
        raise AssertionError("visible user rows and durable row ids disagreed")
    return rows, user_row_ids


def _error_code(frame: Any, expected: int) -> int:
    error = frame.get("error") if isinstance(frame, dict) else None
    code = error.get("code") if isinstance(error, dict) else None
    if code != expected:
        raise AssertionError(f"RPC refusal did not return expected code {expected}")
    return code


def _delete_ack(payload: Any, expected_id: str) -> None:
    if not isinstance(payload, dict) or payload != {"deleted": expected_id}:
        raise AssertionError("session.delete did not acknowledge the exact owned stored ID")


async def _messages(client, stored_id: str) -> tuple[list[tuple[str, str]], list[int]]:
    response = await client.get(
        MESSAGES_ROUTE.format(session_id=stored_id),
        params={"profile": PROFILE, "include_compacted": "true", "order": "oldest",
                "limit": MESSAGE_LIMIT, "offset": 0},
    )
    if response.status_code != 200:
        raise RuntimeError("authoritative messages read failed")
    return _history(response.json(), stored_id)


async def _submit(
    probe: Probe, runtime: str, text: str, *, require_streaming: bool = False, **extra: Any
) -> None:
    start = len(probe.frames)
    accepted = await probe.rpc("prompt.submit", {"session_id": runtime, "text": text, **extra})
    allowed = ("streaming",) if require_streaming else ("streaming", "queued")
    if not isinstance(accepted, dict) or accepted.get("status") not in allowed:
        raise AssertionError("owned deterministic prompt was not accepted")
    await probe.wait_terminal(runtime, start)
    await probe.wait_idle(runtime)


async def _create(probe: Probe, owned: dict[str, str], turns: tuple[str, ...]) -> tuple[str, str]:
    created = await probe.rpc("session.create", {
        "profile": PROFILE,
        "cwd": str(stock_probe.RUNTIME / "tools"),
        "model": "semreh-fixture",
        "provider": "custom",
        "reasoning_effort": "low",
    })
    runtime, stored = _owned_binding(created)
    if runtime in owned or stored in owned.values():
        raise AssertionError("fresh session reused an owned identity")
    owned[runtime] = stored  # register before the first turn for bounded cleanup
    for text in turns:
        await _submit(probe, runtime, text)
    return runtime, stored


async def _exercise(credentials: dict[str, Any], evidence: dict[str, Any]) -> None:
    base = stock_probe.HTTPS_ORIGIN
    owned: dict[str, str] = {}
    closed: set[str] = set()
    async with authenticated(credentials, evidence, base=base, origin=base) as (client, ticket):
        ws = None
        probe: Probe | None = None
        try:
            evidence["phase"] = "connect owned HTTPS fixture"
            ws = await connect(
                f"{base.replace('https://', 'wss://')}/api/ws?ticket={ticket}",
                origin=base, proxy=None,
            )
            ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("stock gateway did not become ready")
            probe = Probe(ws, client, {"frames": []})

            evidence["phase"] = "create two fresh deterministic sessions"
            target_runtime, target_stored = await _create(probe, owned, TARGET_TURNS)
            sibling_runtime, sibling_stored = await _create(probe, owned, SIBLING_TURNS)
            before, row_ids = await _messages(client, target_stored)
            sibling_before, sibling_row_ids = await _messages(client, sibling_stored)
            if [text for role, text in before if role == "user"] != list(TARGET_TURNS):
                raise AssertionError("target warmup history did not match owned turns")
            if len(before) != 4 or [role for role, _ in before] != [
                "user", "assistant", "user", "assistant"
            ]:
                raise AssertionError("target warmup was not exactly two complete turns")
            if [text for role, text in sibling_before if role == "user"] != list(SIBLING_TURNS):
                raise AssertionError("sibling warmup history did not match owned turns")

            evidence["phase"] = "edit second durable user row"
            edit_params = {
                "truncate_before_row_id": row_ids[1],
                "confirm_truncate": True,
            }
            await _submit(
                probe, target_runtime, EDIT_TEXT, require_streaming=True, **edit_params
            )
            edited, edited_row_ids = await _messages(client, target_stored)
            if [text for role, text in edited if role == "user"] != [TARGET_TURNS[0], EDIT_TEXT]:
                raise AssertionError("durable row edit did not replace the selected user turn")
            if len(edited) != 4 or [role for role, _ in edited] != [
                "user", "assistant", "user", "assistant"
            ] or edited[:2] != before[:2]:
                raise AssertionError("durable row edit changed the preserved first turn")
            if await _messages(client, sibling_stored) != (sibling_before, sibling_row_ids):
                raise AssertionError("durable row edit changed the sibling")

            evidence["phase"] = "regenerate from edited durable user row"
            regenerate_params = {
                "truncate_before_row_id": edited_row_ids[1],
                "confirm_truncate": True,
            }
            await _submit(
                probe, target_runtime, EDIT_TEXT, require_streaming=True,
                **regenerate_params,
            )
            regenerated, regenerated_row_ids = await _messages(client, target_stored)
            if [text for role, text in regenerated if role == "user"] != [
                TARGET_TURNS[0], EDIT_TEXT
            ]:
                raise AssertionError("durable row regeneration changed the selected user text")
            if len(regenerated) != 4 or [role for role, _ in regenerated] != [
                "user", "assistant", "user", "assistant"
            ] or regenerated[:2] != before[:2]:
                raise AssertionError("durable row regeneration changed the preserved first turn")
            if await _messages(client, sibling_stored) != (sibling_before, sibling_row_ids):
                raise AssertionError("durable row regeneration changed the sibling")

            evidence["phase"] = "reject nonexistent durable row"
            edited_digest = _digest(edited)
            regenerated_digest = _digest(regenerated)
            refused = await probe.expect_error("prompt.submit", {
                "session_id": target_runtime,
                "text": "SEMREH_S4_DESTRUCTIVE_MUST_NOT_WRITE",
                "truncate_before_row_id": MISSING_ROW_ID,
                "confirm_truncate": True,
            })
            missing_code = _error_code(refused, 4018)
            after_missing, _ = await _messages(client, target_stored)
            if _digest(after_missing) != regenerated_digest:
                raise AssertionError("nonexistent row refusal changed target history")

            evidence["phase"] = "confirm truncation that empties the prior prefix"
            empty_prefix_params = {
                "truncate_before_row_id": regenerated_row_ids[0],
                "confirm_truncate": True,
                "confirm_empty_truncate": True,
            }
            await _submit(
                probe, target_runtime, EMPTY_PREFIX_TEXT, require_streaming=True,
                **empty_prefix_params,
            )
            empty_prefix_rows, _ = await _messages(client, target_stored)
            if empty_prefix_rows[0:1] != [("user", EMPTY_PREFIX_TEXT)] or len(
                empty_prefix_rows
            ) != 2 or [role for role, _ in empty_prefix_rows] != ["user", "assistant"]:
                raise AssertionError("confirmed empty-prefix truncation did not leave one full turn")
            empty_prefix_digest = _digest(empty_prefix_rows)
            if await _messages(client, sibling_stored) != (sibling_before, sibling_row_ids):
                raise AssertionError("empty-prefix truncation changed the sibling")

            evidence["phase"] = "refuse attached stored-ID delete"
            refused_delete = await probe.expect_error("session.delete", {
                "session_id": target_stored, "profile": PROFILE,
            })
            active_delete_code = _error_code(refused_delete, 4023)
            if _digest((await _messages(client, target_stored))[0]) != empty_prefix_digest:
                raise AssertionError("active-session delete refusal changed target history")
            if (await _messages(client, sibling_stored))[0] != sibling_before:
                raise AssertionError("active-session delete refusal changed the sibling")

            evidence["phase"] = "close target then delete exact owned stored ID"
            close_ack = await probe.rpc("session.close", {"session_id": target_runtime})
            if not isinstance(close_ack, dict) or close_ack.get("closed") is not True:
                raise AssertionError("owned target runtime close was not confirmed")
            closed.add(target_runtime)
            deleted = await probe.rpc("session.delete", {
                "session_id": target_stored, "profile": PROFILE,
            })
            _delete_ack(deleted, target_stored)

            detail = await client.get(
                DETAIL_ROUTE.format(session_id=target_stored), params={"profile": PROFILE}
            )
            if detail.status_code != 404:
                raise AssertionError("deleted target remained addressable")
            sibling_after, _ = await _messages(client, sibling_stored)
            if sibling_after != sibling_before:
                raise AssertionError("target deletion changed the owned sibling")

            evidence["contract"] = {
                "owned_sessions_created": 2,
                "origin_is_owned_https": base == stock_probe.HTTPS_ORIGIN,
                "profile_is_default": PROFILE == "default",
                "edit_request_fields": sorted(edit_params),
                "regenerate_request_fields": sorted(regenerate_params),
                "empty_prefix_request_fields": sorted(empty_prefix_params),
                "edit_before": _digest(before),
                "edit_after": edited_digest,
                "regenerate_after": regenerated_digest,
                "empty_prefix_after": empty_prefix_digest,
                "nonexistent_row_error_code": missing_code,
                "nonexistent_row_history_unchanged": True,
                "active_delete_error_code": active_delete_code,
                "active_delete_preserved_target": True,
                "delete_ack_exact_owned_id": True,
                "deleted_target_absent": True,
                "sibling_unchanged": True,
                "sibling": _digest(sibling_after),
                "destructive_requests_retried": False,
            }
        finally:
            if ws is not None:
                for runtime in owned:
                    if runtime in closed:
                        continue
                    try:
                        if probe is None:
                            raise RuntimeError("gateway probe was not initialized")
                        result = await probe.rpc("session.close", {"session_id": runtime})
                        if not isinstance(result, dict) or result.get("closed") is not True:
                            raise AssertionError("session.close not confirmed")
                        closed.add(runtime)
                    except Exception as error:
                        evidence["cleanup_errors"].append({
                            "operation": "close_owned_runtime", "type": type(error).__name__
                        })
                await ws.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    return parser


def run(output: Path) -> None:
    stock_probe.validate()
    credentials = json.loads(
        (stock_probe.RUNTIME / "credentials.json").read_text(encoding="utf-8")
    )
    evidence: dict[str, Any] = {
        "sanitized": True, "outcome": "failed", "source_pin": stock_probe.PIN,
        "deployment": stock_probe.HTTPS_ORIGIN, "profile": PROFILE,
        "phase": "startup", "cleanup_errors": [],
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
        raise RuntimeError(f"Destructive probe failed; evidence: {output}") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Destructive assertions passed; sanitized evidence: {output}")


if __name__ == "__main__":
    args = build_parser().parse_args()
    run(_output_path(args.output))
