#!/usr/bin/env python3
"""Bounded stock approval/secret cancellation probe for the opt-in fixture.

The gateway must be launched with ``direct_hermes_probe.py serve
--approval-secret-fixture`` before this probe is run.  This file never starts
or changes the gateway.  It sends only a synthetic approval denial and an
empty secret value; evidence contains booleans/counts and no request payloads,
credentials, cookies, tickets, or secret values.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
from pathlib import Path
import time

import httpx
from websockets.asyncio.client import connect

from direct_hermes_capture import write_fixture
import direct_hermes_probe as stock_probe
from direct_hermes_model_fixture import (
    APPROVAL_MARKER,
    APPROVAL_TOOL_NAME,
    SECRET_MARKER,
    SECRET_TOOL_NAME,
)
from direct_hermes_reasoning_probe import (
    PROFILE,
    RPC_TIMEOUT,
    Probe,
    _json_frame,
    _output_path,
)


EVENT_TIMEOUT = 25.0
TURN_TIMEOUT = 55.0
EMPTY_SECRET_ENV = "SEMREH_FIXTURE_EMPTY_SECRET"
_ALLOWED_TOOL_NAMES = {APPROVAL_TOOL_NAME, SECRET_TOOL_NAME}


def _config_hash(runtime: Path) -> str:
    path = runtime / "home" / "config.yaml"
    if path.is_symlink() or path.resolve() != path or not path.is_file():
        raise RuntimeError("Unexpected disposable config path")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _binding(payload: dict) -> tuple[str, str]:
    runtime = payload.get("session_id")
    stored = payload.get("stored_session_id") or payload.get("session_key")
    if not isinstance(runtime, str) or not runtime:
        raise AssertionError("session.create omitted runtime identity")
    if not isinstance(stored, str) or not stored:
        raise AssertionError("session.create omitted stored identity")
    return runtime, stored


async def _new_ticket(client: httpx.AsyncClient) -> str:
    response = await client.post("/api/auth/ws-ticket")
    response.raise_for_status()
    ticket = response.json().get("ticket")
    if not isinstance(ticket, str) or not ticket:
        raise RuntimeError("auth ticket response omitted ticket")
    return ticket


async def _connect(base_ws: str, origin: str, ticket: str):
    ws = await connect(f"{base_ws}/api/ws?ticket={ticket}", origin=origin, proxy=None)
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
    return _binding(created)


async def _wait_request(probe: Probe, event_type: str, runtime: str,
                        start: int) -> tuple[dict, dict]:
    deadline = time.monotonic() + EVENT_TIMEOUT
    while True:
        for frame in probe.frames[start:]:
            params = frame.get("params") or {}
            if params.get("type") != event_type or params.get("session_id") != runtime:
                continue
            payload = params.get("payload") or {}
            request_id = payload.get("request_id")
            if not isinstance(request_id, str) or not request_id:
                raise AssertionError(f"{event_type} omitted request_id")
            return frame, payload
        await probe.receive(deadline)


async def _wait_terminal(probe: Probe, runtime: str, start: int) -> dict:
    deadline = time.monotonic() + TURN_TIMEOUT
    while True:
        for frame in probe.frames[start:]:
            params = frame.get("params") or {}
            if params.get("type") != "message.complete" or params.get("session_id") != runtime:
                continue
            payload = params.get("payload") or {}
            if payload.get("status") == "error":
                raise AssertionError("synthetic blocking cancellation completed with an error")
            return frame
        await probe.receive(deadline)


def _request_shape(event_type: str, frame: dict, payload: dict, runtime: str) -> dict:
    params = frame.get("params") or {}
    result = {
        "event": params.get("type") == event_type,
        "session_matches": params.get("session_id") == runtime,
        "request_id_present": bool(payload.get("request_id")),
    }
    if event_type == "approval.request":
        choices = payload.get("choices")
        pattern_keys = payload.get("pattern_keys")
        result.update({
            "choices_count": len(choices) if isinstance(choices, list) else 0,
            "choices": list(choices) if isinstance(choices, list) else [],
            "deny_available": isinstance(choices, list) and "deny" in choices,
            "description_present": isinstance(payload.get("description"), str),
            "pattern_keys_count": len(pattern_keys)
            if isinstance(pattern_keys, list) else 0,
            "allow_session": payload.get("allow_session") is True,
            "allow_permanent": payload.get("allow_permanent") is True,
        })
    else:
        result.update({
            "env_var_matches": payload.get("env_var") == EMPTY_SECRET_ENV,
            "prompt_present": isinstance(payload.get("prompt"), str),
        })
    return result


def _event_diagnostics(probe: Probe) -> dict:
    """Return bounded event/tool diagnostics without retaining raw payloads."""
    counts: dict[str, int] = {}
    tool_events: list[dict] = []
    for frame in probe.frames:
        params = frame.get("params") or {}
        event_type = params.get("type")
        if not isinstance(event_type, str):
            continue
        counts[event_type] = counts.get(event_type, 0) + 1
        if event_type not in {"tool.start", "tool.complete", "tool.result"}:
            continue
        payload = params.get("payload") or {}
        name = payload.get("name") or payload.get("tool_name")
        row = {
            "event": event_type,
            "name": name if name in _ALLOWED_TOOL_NAMES else "<unexpected>",
            "allowed_name": name in _ALLOWED_TOOL_NAMES,
        }
        if event_type in {"tool.complete", "tool.result"}:
            result = payload.get("result")
            row["result_present"] = result is not None
            row["result_is_error"] = (
                isinstance(result, dict)
                and ("error" in result or result.get("success") is False)
            )
        tool_events.append(row)
    return {"event_counts": counts, "tool_events": tool_events}


async def _exercise(credentials: dict, evidence: dict, *, runtime: Path,
                    base: str, ws_base: str, origin: str,
                    tools_cwd: Path) -> None:
    async with httpx.AsyncClient(
        base_url=base, trust_env=False, follow_redirects=False
    ) as client:
        evidence["phase"] = "login"
        login = await client.post("/auth/password-login", json={
            "provider": "basic", **credentials, "next": "",
        })
        if login.status_code not in (200, 302, 303):
            raise RuntimeError("fixture login failed")
        active: set[str] = set()
        ws = None
        probe = None
        try:
            evidence["phase"] = "connect"
            ws = await _connect(ws_base, origin, await _new_ticket(client))
            probe = Probe(ws, client, {"frames": []})

            evidence["phase"] = "approval.session.create"
            approval_runtime, approval_stored = await _create_session(probe, tools_cwd)
            active.add(approval_runtime)
            approval_start = len(probe.frames)
            evidence["phase"] = "approval.request"
            await probe.rpc("prompt.submit", {
                "session_id": approval_runtime, "text": APPROVAL_MARKER,
            })
            approval_frame, approval_payload = await _wait_request(
                probe, "approval.request", approval_runtime, approval_start
            )
            if not _request_shape(
                "approval.request", approval_frame, approval_payload, approval_runtime
            )["deny_available"]:
                raise AssertionError("approval request omitted deny choice")
            evidence["phase"] = "approval.pending"
            pending = await probe.rpc("approval.pending", {
                "session_id": approval_runtime,
            })
            approvals = pending.get("approvals") if isinstance(pending, dict) else None
            pending_row = next((item for item in approvals or [] if isinstance(item, dict)
                                and item.get("request_id") == approval_payload.get("request_id")), None)
            if not isinstance(approvals, list) or pending_row is None:
                raise AssertionError("approval.pending did not retain the emitted request")
            evidence["phase"] = "approval.resume"
            resumed = await probe.rpc("session.resume", {
                "session_id": approval_stored,
                "profile": PROFILE,
            })
            resumed_pending = resumed.get("pending_approval") if isinstance(resumed, dict) else None
            if not isinstance(resumed_pending, dict) or (
                resumed_pending.get("request_id") != approval_payload.get("request_id")
            ):
                raise AssertionError("session.resume did not restore the pending approval")
            evidence["phase"] = "approval.respond"
            await probe.rpc("approval.received", {
                "session_id": approval_runtime,
                "request_id": approval_payload["request_id"],
            })
            resolved = await probe.rpc("approval.respond", {
                "session_id": approval_runtime,
                "request_id": approval_payload["request_id"],
                "choice": "deny",
            })
            if not isinstance(resolved, dict) or resolved.get("resolved") != 1:
                raise AssertionError("approval denial did not resolve exactly one request")
            evidence["phase"] = "approval.terminal"
            await _wait_terminal(probe, approval_runtime, approval_start)
            evidence["checks"].append({
                "name": "approval.request -> pending -> deny",
                "result": _request_shape(
                    "approval.request", approval_frame, approval_payload, approval_runtime
                ) | {
                    "pending_match": True,
                    "pending_choices_count": len(pending_row.get("choices", []))
                    if isinstance(pending_row.get("choices"), list) else 0,
                    "resume_pending_match": True,
                    "resume_choices_count": len(resumed_pending.get("choices", []))
                    if isinstance(resumed_pending.get("choices"), list) else 0,
                    "resolved_count": 1,
                    "terminal": True,
                },
            })

            evidence["phase"] = "secret.session.create"
            secret_runtime, _ = await _create_session(probe, tools_cwd)
            active.add(secret_runtime)
            secret_start = len(probe.frames)
            evidence["phase"] = "secret.request"
            await probe.rpc("prompt.submit", {
                "session_id": secret_runtime, "text": SECRET_MARKER,
            })
            secret_frame, secret_payload = await _wait_request(
                probe, "secret.request", secret_runtime, secret_start
            )
            secret_shape = _request_shape(
                "secret.request", secret_frame, secret_payload, secret_runtime
            )
            if not secret_shape["env_var_matches"]:
                raise AssertionError("secret request used an unexpected fixture env name")
            evidence["phase"] = "secret.respond"
            secret_response = await probe.rpc("secret.respond", {
                "session_id": secret_runtime,
                "request_id": secret_payload["request_id"],
                "value": "",
            })
            if not isinstance(secret_response, dict) or secret_response.get("status") != "ok":
                raise AssertionError("empty secret response did not return status=ok")
            evidence["phase"] = "secret.terminal"
            await _wait_terminal(probe, secret_runtime, secret_start)
            evidence["checks"].append({
                "name": "secret.request -> empty cancellation",
                "result": secret_shape | {
                    "empty_value_submitted": True,
                    "response_status_ok": True,
                    "terminal": True,
                },
            })
        finally:
            evidence["last_work_phase"] = evidence.get("phase")
            evidence["phase"] = "cleanup"
            if probe is not None:
                for session_id in list(active):
                    try:
                        closed = await probe.rpc("session.close", {"session_id": session_id})
                        if not isinstance(closed, dict) or closed.get("closed") is not True:
                            raise AssertionError("session cleanup close was not confirmed")
                    except Exception:
                        evidence["cleanup_errors"] += 1
            if ws is not None:
                await ws.close()
            try:
                logout = await client.post("/auth/logout")
                if logout.status_code not in (200, 302, 303):
                    raise AssertionError("logout failed")
                protected = await client.get("/api/sessions", params={"profile": PROFILE})
                if protected.status_code != 401:
                    raise AssertionError("logout left fixture client authenticated")
            except Exception:
                evidence["cleanup_errors"] += 1
            if probe is not None:
                evidence["event_diagnostics"] = _event_diagnostics(probe)


async def run(output: Path) -> None:
    stock_probe.validate()
    runtime = stock_probe.RUNTIME
    credentials = json.loads((runtime / "credentials.json").read_text())
    before = _config_hash(runtime)
    evidence = {
        "sanitized": True,
        "source_pin": stock_probe.PIN,
        "deployment": stock_probe.HTTPS_ORIGIN,
        "fixture_toolset": stock_probe.BLOCKING_FIXTURE_TOOLSET,
        "checks": [],
        "cleanup_errors": 0,
        "not_verified": [
            "sudo callback (intentionally not enabled)",
            "native UI and physical device behavior",
        ],
    }
    try:
        await _exercise(
            credentials, evidence, runtime=runtime,
            base=stock_probe.HTTPS_ORIGIN,
            ws_base=stock_probe.HTTPS_ORIGIN.replace("https://", "wss://"),
            origin=stock_probe.HTTPS_ORIGIN,
            tools_cwd=runtime / "tools",
        )
        evidence["global_config_unchanged"] = _config_hash(runtime) == before
        if not evidence["global_config_unchanged"]:
            raise AssertionError("global fixture configuration changed")
        if evidence["cleanup_errors"]:
            raise AssertionError("fixture cleanup failed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["outcome"] = "failed"
        evidence["error_type"] = type(error).__name__
        evidence["failure_phase"] = evidence.get("last_work_phase") or evidence.get("phase")
        evidence["global_config_unchanged"] = _config_hash(runtime) == before
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError(f"Approval/secret probe failed; evidence: {output}") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Approval/secret cancellation probe passed; evidence: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    asyncio.run(run(_output_path(args.output)))
