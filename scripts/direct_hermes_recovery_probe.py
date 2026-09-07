#!/usr/bin/env python3
"""Bounded stock recovery cases for accepted turns and clarify waits.

This probe intentionally exercises only the pinned disposable backend and its
existing deterministic model fixture.  It closes the client WebSocket at two
server-observable boundaries, resumes by durable session identity, and checks
the canonical REST transcript.  Persisted evidence contains booleans/counts
only; prompt text, request IDs, and session IDs remain in memory.
"""

from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
import time

import httpx
from websockets.asyncio.client import connect

import direct_hermes_probe as stock_probe
from direct_hermes_capture import write_fixture
from direct_hermes_identity_probe import _row_text, _rest_rows, authenticated
from direct_hermes_model_fixture import CLARIFY_MARKER
from direct_hermes_reasoning_probe import (
    PROFILE,
    RPC_TIMEOUT,
    Probe,
    _json_frame,
    _output_path,
)


DELAYED_PROMPT = "SEMREH_INTERRUPT_FIXTURE SEMREH_RECOVERY_AFTER_ACCEPT"
DELAYED_ACK = "SEMREH_SLICE1_ACK"
CLARIFY_ACK = "SEMREH_SLICE1_ACK"
PENDING_TIMEOUT = 20.0


async def _new_ticket(client: httpx.AsyncClient) -> str:
    response = await client.post("/api/auth/ws-ticket")
    response.raise_for_status()
    ticket = response.json().get("ticket")
    if not isinstance(ticket, str) or not ticket:
        raise RuntimeError("auth ticket response omitted ticket")
    return ticket


async def _connect(base_ws: str, origin: str, ticket: str):
    ws = await connect(
        f"{base_ws}/api/ws?ticket={ticket}", origin=origin, proxy=None
    )
    ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
    if ready.get("params", {}).get("type") != "gateway.ready":
        await ws.close()
        raise RuntimeError("missing gateway.ready")
    return ws


async def _create_session(probe: Probe, tools_cwd: Path) -> tuple[str, str]:
    created = await probe.rpc("session.create", {
        "profile": PROFILE,
        "cwd": str(tools_cwd),
        "model": "gpt-5",
        "provider": "custom",
        "reasoning_effort": "low",
    })
    runtime = created.get("session_id") if isinstance(created, dict) else None
    stored = created.get("stored_session_id") if isinstance(created, dict) else None
    if not isinstance(runtime, str) or not runtime:
        raise AssertionError("session.create omitted runtime identity")
    if not isinstance(stored, str) or not stored:
        raise AssertionError("session.create omitted durable identity")
    return runtime, stored


async def _canonical_page(
    client: httpx.AsyncClient, stored: str, *, allow_missing: bool = False
) -> tuple[str, list[dict]]:
    response = await client.get(
        f"/api/sessions/{stored}/messages",
        params={
            "profile": PROFILE,
            "include_compacted": "true",
            "order": "oldest",
            "limit": 500,
            "offset": 0,
        },
    )
    if response.status_code == 404 and allow_missing:
        # A just-created draft has no durable transcript resource yet.  The
        # stored ID is the only available canonical anchor until its first
        # accepted turn is written.
        return stored, []
    response.raise_for_status()
    payload = response.json()
    if not isinstance(payload, dict):
        raise AssertionError("canonical REST transcript was not an object")
    canonical = payload.get("session_id")
    if not isinstance(canonical, str) or not canonical:
        raise AssertionError("canonical REST transcript omitted session identity")
    rows = _rest_rows(payload)
    _assert_durable_ids(rows, "canonical transcript")
    return canonical, rows


def _signature(row: dict) -> tuple[object, object, str]:
    return row.get("id"), row.get("role"), _row_text(row)


def _assert_durable_ids(rows: list[dict], label: str) -> None:
    identifiers = [row.get("id") for row in rows]
    if any(
        not isinstance(identifier, (str, int)) or isinstance(identifier, bool)
        for identifier in identifiers
    ):
        raise AssertionError(f"{label} omitted a scalar durable message ID")
    if len(identifiers) != len(set(identifiers)):
        raise AssertionError(f"{label} contained duplicate durable message IDs")


def _baseline_anchor_preserved(before: list[dict], after: list[dict]) -> bool:
    if not before:
        return False
    # These probes deliberately keep each session tiny and uncompressed.  A
    # two-row anchor can be preserved while an earlier row is silently
    # replaced, so require the complete pre-turn prefix to remain byte-for-
    # byte equivalent in the canonical REST projection.
    return len(after) >= len(before) and [
        _signature(row) for row in after[:len(before)]
    ] == [_signature(row) for row in before]


def _clarify_tool_row(row: dict) -> bool:
    """Return whether a transcript row is a source-defined clarify artifact."""
    role = row.get("role")
    if role == "tool":
        return row.get("tool_name") == "clarify" and isinstance(
            row.get("tool_call_id"), str
        ) and bool(row.get("tool_call_id"))
    if role != "assistant" or not isinstance(row.get("tool_calls"), list):
        return False
    calls = row["tool_calls"]
    if not calls:
        return False
    names = set()
    for call in calls:
        if not isinstance(call, dict):
            return False
        function = call.get("function")
        name = function.get("name") if isinstance(function, dict) else None
        name = name or call.get("name")
        if not isinstance(name, str):
            return False
        names.add(name)
    return names == {"clarify"}


def _clarify_row_call_ids(row: dict) -> list[str]:
    if row.get("role") == "tool":
        call_id = row.get("tool_call_id")
        return [call_id] if isinstance(call_id, str) and call_id else []
    calls = row.get("tool_calls")
    if not isinstance(calls, list):
        return []
    identifiers = []
    for call in calls:
        call_id = call.get("id") if isinstance(call, dict) else None
        if not isinstance(call_id, str) or not call_id:
            return []
        identifiers.append(call_id)
    return identifiers


def _assert_continuation(
    before_canonical: str,
    before: list[dict],
    after_canonical: str,
    after: list[dict],
    prompt: str,
    assistant_text: str,
    *,
    allow_clarify_tool_rows: bool = False,
) -> dict:
    if not before:
        raise AssertionError("durable baseline must contain the completed warm turn")
    _assert_durable_ids(before, "durable baseline")
    _assert_durable_ids(after, "durable transcript")
    if after_canonical != before_canonical:
        raise AssertionError("canonical session identity changed during recovery")
    anchor_preserved = _baseline_anchor_preserved(before, after)
    if not anchor_preserved:
        raise AssertionError("canonical baseline anchors changed during recovery")
    suffix = after[len(before):]
    matching_users = [
        (index, row) for index, row in enumerate(suffix)
        if row.get("role") == "user" and _row_text(row) == prompt
    ]
    matching_assistants = [
        (index, row) for index, row in enumerate(suffix)
        if row.get("role") == "assistant" and _row_text(row) == assistant_text
    ]
    if len(matching_users) != 1:
        raise AssertionError("recovered prompt was not durable exactly once")
    if len(matching_assistants) != 1:
        raise AssertionError("recovered terminal continuation was not durable exactly once")
    user_index, _ = matching_users[0]
    terminal_index, _ = matching_assistants[0]
    if user_index >= terminal_index:
        raise AssertionError("terminal continuation precedes recovered prompt")
    if user_index != 0 or terminal_index != len(suffix) - 1:
        raise AssertionError("recovered suffix contains rows outside its turn")
    middle = suffix[user_index + 1:terminal_index]
    if allow_clarify_tool_rows:
        if not middle or not all(_clarify_tool_row(row) for row in middle):
            raise AssertionError("clarify suffix contains unverified transcript rows")
        if not any(row.get("role") == "assistant" for row in middle):
            raise AssertionError("clarify suffix omitted its tool-call row")
        if not any(row.get("role") == "tool" for row in middle):
            raise AssertionError("clarify suffix omitted its tool-result row")
        call_ids = [
            call_id for row in middle if row.get("role") == "assistant"
            for call_id in _clarify_row_call_ids(row)
        ]
        result_ids = [
            call_id for row in middle if row.get("role") == "tool"
            for call_id in _clarify_row_call_ids(row)
        ]
        if not call_ids or len(call_ids) != len(set(call_ids)):
            raise AssertionError("clarify tool-call IDs were missing or duplicated")
        if len(result_ids) != len(set(result_ids)) or set(result_ids) != set(call_ids):
            raise AssertionError("clarify tool results did not match their calls")
    elif suffix != [matching_users[0][1], matching_assistants[0][1]]:
        raise AssertionError("recovered turn contains unexpected durable rows")
    return {
        "canonical_identity_unchanged": True,
        "baseline_anchor_preserved": True,
        "before_row_count": len(before),
        "after_row_count": len(after),
        "new_suffix_row_count": len(suffix),
        "unique_user_row": True,
        "unique_terminal_continuation": True,
        "terminal_after_user": True,
        "verified_clarify_tool_rows": bool(allow_clarify_tool_rows),
    }


async def _warm_session(probe: Probe, runtime: str, prompt: str) -> None:
    start = len(probe.frames)
    submitted = await probe.rpc("prompt.submit", {
        "session_id": runtime,
        "text": prompt,
    })
    if not isinstance(submitted, dict) or submitted.get("status") != "streaming":
        raise AssertionError("warm prompt was not explicitly accepted")
    terminal = await probe.wait_terminal(runtime, start)
    _require_complete(terminal)
    await probe.wait_idle(runtime)


async def _prepare_baseline(
    client: httpx.AsyncClient,
    probe: Probe,
    runtime: str,
    stored: str,
    warm_prompt: str,
    warm_ack: str,
) -> tuple[str, list[dict]]:
    fresh_canonical, fresh_rows = await _canonical_page(
        client, stored, allow_missing=True
    )
    if fresh_canonical != stored or fresh_rows:
        raise AssertionError("new recovery session was not an empty fresh baseline")
    await _warm_session(probe, runtime, warm_prompt)
    baseline_canonical, baseline_rows = await _canonical_page(client, stored)
    if baseline_canonical != stored or not baseline_rows:
        raise AssertionError("completed warm turn did not produce a canonical baseline")
    if sum(
        row.get("role") == "assistant" and _row_text(row) == warm_ack
        for row in baseline_rows
    ) != 1:
        raise AssertionError("warm baseline did not contain exactly one fixture ACK")
    return baseline_canonical, baseline_rows


async def _wait_clarify(
    probe: Probe, runtime: str, start: int
) -> tuple[dict, dict]:
    for frame in probe.frames[start:]:
        params = frame.get("params") or {}
        if params.get("type") == "clarify.request" and params.get("session_id") == runtime:
            payload = params.get("payload") or {}
            request_id = payload.get("request_id")
            if not isinstance(request_id, str) or not request_id:
                raise AssertionError("clarify.request omitted request_id")
            return frame, payload
    deadline = time.monotonic() + PENDING_TIMEOUT
    while True:
        frame = await probe.receive(deadline)
        params = frame.get("params") or {}
        if params.get("type") == "clarify.request" and params.get("session_id") == runtime:
            payload = params.get("payload") or {}
            request_id = payload.get("request_id")
            if not isinstance(request_id, str) or not request_id:
                raise AssertionError("clarify.request omitted request_id")
            return frame, payload


def _require_complete(frame: dict) -> None:
    payload = (frame.get("params") or {}).get("payload") or {}
    if payload.get("status") != "complete":
        raise AssertionError("recovered turn did not reach a normal terminal")


async def _resume_after_disconnect(
    client: httpx.AsyncClient,
    probe: Probe,
    ws,
    stored: str,
    previous_runtime: str,
    base_ws: str,
    origin: str,
    active: set[str],
) -> tuple[Probe, object, tuple[str, int]]:
    await ws.close()
    fresh_ticket = await _new_ticket(client)
    fresh_ws = await _connect(base_ws, origin, fresh_ticket)
    resumed_start = len(probe.frames)
    fresh_probe = Probe(fresh_ws, client, probe.evidence)
    try:
        resumed = await fresh_probe.rpc("session.resume", {
            "session_id": stored,
            "profile": PROFILE,
        })
    except Exception:
        try:
            await fresh_ws.close()
        except Exception:
            pass
        raise
    runtime = resumed.get("session_id") if isinstance(resumed, dict) else None
    if not isinstance(runtime, str) or not runtime:
        await fresh_ws.close()
        raise AssertionError("session.resume omitted runtime identity")
    active.discard(previous_runtime)
    active.add(runtime)
    return fresh_probe, fresh_ws, (runtime, resumed_start)


async def _exercise(
    credentials: dict,
    evidence: dict,
    *,
    runtime: Path,
    base: str,
    base_ws: str,
    origin: str,
) -> None:
    tools_cwd = runtime / "tools"
    evidence["phase"] = "authenticating"
    async with authenticated(credentials, evidence, base=base, origin=origin) as (client, ticket):
        evidence["phase"] = "connected"
        ws = await _connect(base_ws, origin, ticket)
        probe = Probe(ws, client, {"frames": []})
        active: set[str] = set()
        try:
            # Case 1: prompt.submit has been accepted and the provider is
            # demonstrably running, then the client socket disappears.
            evidence["phase"] = "creating accepted-turn session"
            runtime_a, stored_a = await _create_session(probe, tools_cwd)
            active.add(runtime_a)
            before_canonical, before_rows = await _prepare_baseline(
                client,
                probe,
                runtime_a,
                stored_a,
                "SEMREH_RECOVERY_WARMUP_ACCEPT",
                DELAYED_ACK,
            )
            evidence["phase"] = "accepted-turn warm baseline complete"
            submitted = await probe.rpc("prompt.submit", {
                "session_id": runtime_a,
                "text": DELAYED_PROMPT,
            })
            if not isinstance(submitted, dict) or submitted.get("status") != "streaming":
                raise AssertionError("delayed prompt was not explicitly accepted")
            await probe.wait_running(runtime_a)
            evidence["phase"] = "accepted turn running before disconnect"
            probe, ws, resumed_info = await _resume_after_disconnect(
                client, probe, ws, stored_a, runtime_a, base_ws, origin, active
            )
            runtime_a, resume_start = resumed_info
            terminal_a = await probe.wait_terminal(runtime_a, resume_start)
            _require_complete(terminal_a)
            await probe.wait_idle(runtime_a)
            evidence["phase"] = "accepted turn resumed and idle"
            after_canonical, after_rows = await _canonical_page(client, stored_a)
            delayed_check = _assert_continuation(
                before_canonical,
                before_rows,
                after_canonical,
                after_rows,
                DELAYED_PROMPT,
                DELAYED_ACK,
            )
            delayed_check.update({
                "socket_closed_after_explicit_acceptance": True,
                "resume_returned_same_durable_session": True,
                "terminal_status_complete": True,
            })
            evidence["checks"].append({
                "name": "accepted delayed turn reconnect",
                "result": delayed_check,
            })

            # Case 2: a clarify tool is waiting, then the client disconnects;
            # resume must expose the same pending request before cancellation.
            evidence["phase"] = "creating clarify session"
            runtime_b, stored_b = await _create_session(probe, tools_cwd)
            active.add(runtime_b)
            before_canonical, before_rows = await _prepare_baseline(
                client,
                probe,
                runtime_b,
                stored_b,
                "SEMREH_RECOVERY_WARMUP_CLARIFY",
                CLARIFY_ACK,
            )
            evidence["phase"] = "clarify warm baseline complete"
            start_b = len(probe.frames)
            submitted = await probe.rpc("prompt.submit", {
                "session_id": runtime_b,
                "text": CLARIFY_MARKER,
            })
            if not isinstance(submitted, dict) or submitted.get("status") != "streaming":
                raise AssertionError("clarify prompt was not accepted")
            _, pending_payload = await _wait_clarify(probe, runtime_b, start_b)
            evidence["phase"] = "clarify request pending before disconnect"
            request_id = pending_payload["request_id"]
            probe, ws, resumed_info = await _resume_after_disconnect(
                client, probe, ws, stored_b, runtime_b, base_ws, origin, active
            )
            runtime_b, _ = resumed_info
            resumed_pending = await probe.rpc("session.resume", {
                "session_id": stored_b,
                "profile": PROFILE,
            })
            pending = resumed_pending.get("pending_clarify") or {}
            if pending.get("request_id") != request_id:
                raise AssertionError("clarify request did not survive socket reconnect")
            evidence["phase"] = "clarify request restored after disconnect"
            response_start = len(probe.frames)
            response = await probe.rpc("clarify.respond", {
                "session_id": runtime_b,
                "request_id": request_id,
                "answer": "",
            })
            if not isinstance(response, dict) or response.get("status") != "ok":
                raise AssertionError("empty clarify cancellation was not accepted")
            terminal_b = await probe.wait_terminal(runtime_b, response_start)
            _require_complete(terminal_b)
            await probe.wait_idle(runtime_b)
            evidence["phase"] = "clarify cancellation resumed and idle"
            no_pending = await probe.rpc("session.resume", {
                "session_id": stored_b,
                "profile": PROFILE,
            })
            if no_pending.get("pending_clarify"):
                raise AssertionError("clarify cancellation left a pending request")
            post_runtime = no_pending.get("session_id")
            if isinstance(post_runtime, str) and post_runtime and post_runtime != runtime_b:
                active.discard(runtime_b)
                active.add(post_runtime)
                runtime_b = post_runtime
            after_canonical, after_rows = await _canonical_page(client, stored_b)
            clarify_check = _assert_continuation(
                before_canonical,
                before_rows,
                after_canonical,
                after_rows,
                CLARIFY_MARKER,
                CLARIFY_ACK,
                allow_clarify_tool_rows=True,
            )
            clarify_check.update({
                "socket_closed_during_clarify_wait": True,
                "pending_request_restored": True,
                "empty_cancel_terminal_complete": True,
                "pending_cleared_after_cancel": True,
            })
            evidence["checks"].append({
                "name": "clarify wait reconnect and cancel",
                "result": clarify_check,
            })
            evidence["phase"] = "both recovery cases checked"
        finally:
            for runtime_id in sorted(active):
                try:
                    closed = await probe.rpc("session.close", {"session_id": runtime_id})
                    if not isinstance(closed, dict) or closed.get("closed") is not True:
                        raise AssertionError("session cleanup close was not confirmed")
                except Exception as error:
                    evidence.setdefault("cleanup_errors", []).append({
                        "operation": "session.close",
                        "type": type(error).__name__,
                    })
            await ws.close()


async def run(output: Path) -> None:
    stock_probe.validate()
    runtime = stock_probe.RUNTIME
    credentials = json.loads((runtime / "credentials.json").read_text())
    evidence = {
        "sanitized": True,
        "source_pin": stock_probe.PIN,
        "deployment": stock_probe.HTTPS_ORIGIN,
        "checks": [],
        "cleanup_errors": [],
        "not_verified": [
            "socket loss before definitive prompt.submit acceptance",
            "socket loss between provider completion and message.complete",
            "app suspension/termination recovery",
            "backend restart recovery",
        ],
    }
    try:
        await _exercise(
            credentials,
            evidence,
            runtime=runtime,
            base=stock_probe.HTTPS_ORIGIN,
            base_ws=stock_probe.HTTPS_ORIGIN.replace("https://", "wss://"),
            origin=stock_probe.HTTPS_ORIGIN,
        )
        if evidence["cleanup_errors"]:
            raise AssertionError("recovery probe cleanup failed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["outcome"] = "failed"
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError(f"Recovery probe failed; evidence: {output}") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Recovery probe passed; evidence: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    asyncio.run(run(_output_path(args.output)))
