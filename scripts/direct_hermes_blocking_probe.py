#!/usr/bin/env python3
"""Bounded real clarify-request answer/cancel/reconnect probe.

The probe uses only the pinned disposable backend and the clarify-only local
model fixture.  It deliberately does not enable terminal, sudo, secret, or
provider tools.  Evidence contains prompt shapes and boolean outcomes only;
request/session identifiers are never persisted.
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
    CLARIFY_BATCH_MARKER,
    CLARIFY_MARKER,
    CLARIFY_MULTI_SELECT_MARKER,
)
from direct_hermes_reasoning_probe import (
    PROFILE,
    RPC_TIMEOUT,
    Probe,
    _json_frame,
    _output_path,
)


TURN_TIMEOUT = 55.0
PENDING_TIMEOUT = 20.0


def _config_hash(runtime: Path) -> str:
    path = runtime / "home" / "config.yaml"
    if path.is_symlink() or path.resolve() != path or not path.is_file():
        raise RuntimeError("Unexpected disposable config path")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _clarify_timeout(runtime: Path) -> int:
    config = json.loads((runtime / "home" / "config.yaml").read_text())
    clarify = config.get("clarify") or {}
    agent = config.get("agent") or {}
    raw = clarify.get("timeout", agent.get("clarify_timeout", 3600))
    try:
        return int(raw)
    except (TypeError, ValueError):
        return 3600


def _binding(payload: dict) -> tuple[str, str]:
    runtime = payload.get("session_id")
    durable = payload.get("stored_session_id") or payload.get("session_key")
    if not isinstance(runtime, str) or not runtime:
        raise AssertionError("session.create omitted runtime session identity")
    if not isinstance(durable, str) or not durable:
        raise AssertionError("session.create omitted durable session identity")
    return runtime, durable


def _request_summary(frame: dict, session_id: str) -> dict:
    params = frame.get("params") or {}
    payload = params.get("payload") or {}
    request_id = payload.get("request_id")
    safe_payload = {
        key: payload[key]
        for key in ("question", "choices", "multi_select")
        if key in payload
    }
    questions = payload.get("questions")
    if isinstance(questions, list):
        safe_payload["questions"] = [
            {
                key: question[key]
                for key in ("qid", "question", "choices", "multi_select")
                if key in question
            }
            for question in questions
            if isinstance(question, dict)
        ]
    return {
        "event": params.get("type"),
        "session_matches": params.get("session_id") == session_id,
        "request_id_present": isinstance(request_id, str) and bool(request_id),
        "request_id_length": len(request_id) if isinstance(request_id, str) else 0,
        "question_present": isinstance(payload.get("question"), str),
        "choices_count": len(payload.get("choices"))
        if isinstance(payload.get("choices"), list) else None,
        # The marker's question is synthetic. Persist only DTO fields needed
        # for client rendering; request_id is intentionally excluded.
        "safe_payload": safe_payload,
    }


async def _wait_event(probe: Probe, event_type: str, session_id: str,
                      start: int,
                      timeout: float = PENDING_TIMEOUT) -> tuple[dict, dict]:
    for frame in probe.frames[start:]:
        params = frame.get("params") or {}
        if params.get("type") == event_type and params.get("session_id") == session_id:
            payload = params.get("payload") or {}
            request_id = payload.get("request_id")
            if not isinstance(request_id, str) or not request_id:
                raise AssertionError(f"{event_type} omitted request_id")
            return frame, payload
    deadline = time.monotonic() + timeout
    while True:
        frame = await probe.receive(deadline)
        params = frame.get("params") or {}
        if params.get("type") == event_type and params.get("session_id") == session_id:
            payload = params.get("payload") or {}
            request_id = payload.get("request_id")
            if not isinstance(request_id, str) or not request_id:
                raise AssertionError(f"{event_type} omitted request_id")
            return frame, payload


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


async def _start_clarify(
    probe: Probe, runtime: str, marker: str = CLARIFY_MARKER
) -> tuple[dict, dict]:
    start = len(probe.frames)
    await probe.rpc("prompt.submit", {"session_id": runtime, "text": marker})
    return await _wait_event(probe, "clarify.request", runtime, start)


def _pending_resume(resumed: dict, request_id: str) -> bool:
    pending = resumed.get("pending_clarify") or {}
    return pending.get("request_id") == request_id


async def _expect_expired(probe: Probe, params: dict) -> dict:
    result = await probe.rpc("clarify.respond", params)
    if not isinstance(result, dict) or result.get("status") != "expired":
        raise AssertionError("wrong clarify request did not return status=expired")
    return result


async def _complete_clarify(probe: Probe, runtime: str, request_id: str,
                            answer: str) -> dict:
    start = len(probe.frames)
    await probe.rpc("clarify.respond", {
        "session_id": runtime,
        "request_id": request_id,
        "answer": answer,
    })
    return await probe.wait_terminal(runtime, start)


def _terminal_ack(frame: dict) -> str:
    payload = (frame.get("params") or {}).get("payload") or {}
    if payload.get("status") == "error":
        raise AssertionError("clarify completion returned an error")
    text = payload.get("text")
    if not isinstance(text, str) or "SEMREH_SLICE1_ACK" not in text:
        raise AssertionError("clarify completion omitted the deterministic ACK")
    return text


async def _exercise(credentials: dict, evidence: dict, *, runtime: Path,
                    base: str, ws_base: str, origin: str, tools_cwd: Path,
                    run_expiry: bool) -> None:
    async with httpx.AsyncClient(
        base_url=base, trust_env=False, follow_redirects=False
    ) as client:
        login = await client.post("/auth/password-login", json={
            "provider": "basic", **credentials, "next": "",
        })
        if login.status_code not in (200, 302, 303):
            raise RuntimeError("fixture login failed")
        active = set()
        ws = None
        probe = None
        try:
            ticket = await _new_ticket(client)
            ws = await _connect(ws_base, origin, ticket)
            probe = Probe(ws, client, {"frames": []})

            # Answer path plus wrong request/session probes. Stock clarify
            # response methods tolerate stale IDs as {status: expired}; verify
            # the original request remains pending after each stale response.
            runtime_a, stored_a = await _create_session(probe, tools_cwd)
            active.add(runtime_a)
            frame_a, payload_a = await _start_clarify(probe, runtime_a)
            rid_a = payload_a["request_id"]
            evidence["checks"].append({
                "name": "clarify.request answer shape",
                "result": _request_summary(frame_a, runtime_a),
            })
            await _expect_expired(probe, {
                "session_id": runtime_a,
                "request_id": "semreh-wrong-request",
                "answer": "answer",
            })
            if not _pending_resume(await probe.rpc("session.resume", {
                "session_id": stored_a, "profile": PROFILE,
            }), rid_a):
                raise AssertionError("wrong request cleared the pending clarify")
            await _expect_expired(probe, {
                "session_id": "semreh-wrong-session",
                "request_id": "semreh-wrong-request",
                "answer": "answer",
            })
            if not _pending_resume(await probe.rpc("session.resume", {
                "session_id": stored_a, "profile": PROFILE,
            }), rid_a):
                raise AssertionError("wrong session/request cleared pending clarify")
            await _complete_clarify(probe, runtime_a, rid_a, "answer")
            evidence["checks"].append({"name": "answer", "result": True})

            # Exercise the advertised single-question multi-select DTO.  The
            # fixture marker is exact-only; completion keeps this request from
            # remaining in the disposable runtime's pending registry.
            runtime_multi, stored_multi = await _create_session(probe, tools_cwd)
            active.add(runtime_multi)
            frame_multi, payload_multi = await _start_clarify(
                probe, runtime_multi, CLARIFY_MULTI_SELECT_MARKER
            )
            multi_shape = _request_summary(frame_multi, runtime_multi)
            multi_payload = multi_shape["safe_payload"]
            if multi_payload.get("multi_select") is not True:
                raise AssertionError("multi-select clarify request lost its flag")
            if multi_shape.get("choices_count") != 3:
                raise AssertionError("multi-select clarify choices were not preserved")
            _terminal_ack(await _complete_clarify(
                probe, runtime_multi, payload_multi["request_id"], ""
            ))
            resumed_multi = await probe.rpc("session.resume", {
                "session_id": stored_multi, "profile": PROFILE,
            })
            if resumed_multi.get("pending_clarify"):
                raise AssertionError("multi-select cancellation left a pending request")
            evidence["checks"].append({
                "name": "multi-select shape, empty cancellation, terminal ACK and no pending request",
                "result": multi_shape,
            })

            # Verify the batch shape before exercising the app's minimal
            # supported action: cancelling the entire request with an empty
            # answer and no question_id.
            runtime_batch, stored_batch = await _create_session(probe, tools_cwd)
            active.add(runtime_batch)
            frame_batch, payload_batch = await _start_clarify(
                probe, runtime_batch, CLARIFY_BATCH_MARKER
            )
            batch_shape = _request_summary(frame_batch, runtime_batch)
            batch_questions = batch_shape["safe_payload"].get("questions")
            if (
                not isinstance(batch_questions, list)
                or [item.get("qid") for item in batch_questions] != ["q0", "q1"]
                or batch_questions[1].get("multi_select") is not True
            ):
                raise AssertionError("batch clarify questions were not preserved")
            _terminal_ack(await _complete_clarify(
                probe, runtime_batch, payload_batch["request_id"], ""
            ))
            resumed_batch = await probe.rpc("session.resume", {
                "session_id": stored_batch, "profile": PROFILE,
            })
            if resumed_batch.get("pending_clarify"):
                raise AssertionError("batch cancellation left a pending request")
            evidence["checks"].append({
                "name": "batch shape, empty cancellation, terminal ACK and no pending request",
                "result": batch_shape,
            })

            # Empty answer is the explicit cancellation contract.
            runtime_b, stored_b = await _create_session(probe, tools_cwd)
            active.add(runtime_b)
            frame_b, payload_b = await _start_clarify(probe, runtime_b)
            terminal_b = await _complete_clarify(
                probe, runtime_b, payload_b["request_id"], ""
            )
            _terminal_ack(terminal_b)
            resumed_b = await probe.rpc("session.resume", {
                "session_id": stored_b, "profile": PROFILE,
            })
            pending_after_cancel = resumed_b.get("pending_clarify") or {}
            if pending_after_cancel:
                raise AssertionError("empty clarify answer left a pending request")
            evidence["checks"].append({
                "name": "empty answer cancel",
                "result": {
                    **_request_summary(frame_b, runtime_b),
                    "terminal_ack": True,
                    "pending_after_resume": False,
                },
            })

            # Keep one request pending while the first ticket/websocket closes;
            # session.resume must return the same pending request before the
            # answer is accepted on the fresh authenticated connection.
            runtime_c, stored_c = await _create_session(probe, tools_cwd)
            active.add(runtime_c)
            frame_c, payload_c = await _start_clarify(probe, runtime_c)
            rid_c = payload_c["request_id"]
            await ws.close()
            ws = None

            fresh_ticket = await _new_ticket(client)
            ws = await _connect(ws_base, origin, fresh_ticket)
            probe = Probe(ws, client, {"frames": []})
            resumed = await probe.rpc("session.resume", {
                "session_id": stored_c,
                "profile": PROFILE,
            })
            resumed_runtime, _ = _binding(resumed)
            if resumed_runtime != runtime_c:
                active.discard(runtime_c)
                active.add(resumed_runtime)
                runtime_c = resumed_runtime
            pending = resumed.get("pending_clarify") or {}
            same_pending = pending.get("request_id") == rid_c
            evidence["checks"].append({
                "name": "reconnect pending clarify",
                "result": {
                    "request_id_restored": same_pending,
                    "question_present": isinstance(pending.get("question"), str),
                    "event_shape": _request_summary(frame_c, runtime_c),
                },
            })
            if not same_pending:
                raise AssertionError("session.resume did not restore pending clarify")
            await _expect_expired(probe, {
                "session_id": "semreh-wrong-session",
                "request_id": "semreh-wrong-request",
                "answer": "answer",
            })
            if not _pending_resume(await probe.rpc("session.resume", {
                "session_id": stored_c, "profile": PROFILE,
            }), rid_c):
                raise AssertionError("wrong reconnect response cleared pending clarify")
            await _complete_clarify(probe, runtime_c, rid_c, "answer")
            evidence["checks"].append({"name": "reconnect answer", "result": True})

            # The pinned stock _respond implementation indexes the global
            # pending registry by request_id and does not compare its stored
            # owner to params.session_id for clarify/sudo/secret.  Exercise
            # that exact-target case on a disposable prompt and report the
            # result explicitly; no backend patch or workaround is applied.
            runtime_d, stored_d = await _create_session(probe, tools_cwd)
            active.add(runtime_d)
            frame_d, payload_d = await _start_clarify(probe, runtime_d)
            rid_d = payload_d["request_id"]
            completion_start = len(probe.frames)
            cross_session = await probe.rpc("clarify.respond", {
                "session_id": "semreh-wrong-session",
                "request_id": rid_d,
                "answer": "answer",
            })
            accepted = isinstance(cross_session, dict) and cross_session.get("status") == "ok"
            evidence.setdefault("findings", []).append({
                "name": "clarify response owner binding",
                "result": "backend accepted wrong session" if accepted else "backend rejected wrong session",
                "severity": "backend_limitation" if accepted else "none",
                "app_guard_required": accepted,
            })
            if accepted:
                await probe.wait_terminal(runtime_d, completion_start)
            else:
                await _complete_clarify(probe, runtime_d, rid_d, "answer")

            # A late duplicate is allowed to receive the stock expired result,
            # but must not create a second completion or reopen the prompt.
            late = await probe.rpc("clarify.respond", {
                "session_id": runtime_c,
                "request_id": rid_c,
                "answer": "answer",
            })
            evidence["checks"].append({
                "name": "duplicate response is terminal",
                "result": {"status": late.get("status") if isinstance(late, dict) else None},
            })

            # The disposable runtime deliberately retains its 3600-second
            # default.  Do not mutate config or sleep for an hour in this probe.
            timeout = _clarify_timeout(runtime)
            evidence["expiry"] = {
                "configured_timeout_seconds": timeout,
                "status": "not_run" if not run_expiry else "unsupported_without_short_timeout",
                "reason": "probe never mutates runtime config; use a disposable short-timeout fixture",
            }
        finally:
            if probe is not None:
                for runtime_id in list(active):
                    try:
                        closed = await probe.rpc("session.close", {"session_id": runtime_id})
                        if not isinstance(closed, dict) or closed.get("closed") is not True:
                            raise AssertionError("session cleanup close was not confirmed")
                    except Exception as error:
                        evidence.setdefault("cleanup_errors", []).append({
                            "operation": "session.close",
                            "type": type(error).__name__,
                        })
            if ws is not None:
                await ws.close()
            try:
                logout = await client.post("/auth/logout")
                if logout.status_code not in (200, 302, 303):
                    raise AssertionError("logout failed")
                protected = await client.get("/api/sessions", params={"profile": PROFILE})
                if protected.status_code != 401:
                    raise AssertionError("logout left fixture client authenticated")
            except Exception as error:
                evidence.setdefault("cleanup_errors", []).append({
                    "operation": "logout",
                    "type": type(error).__name__,
                })


async def run(output: Path, *, run_expiry: bool = False) -> None:
    stock_probe.validate()
    runtime = stock_probe.RUNTIME
    credentials = json.loads((runtime / "credentials.json").read_text())
    before = _config_hash(runtime)
    evidence = {
        "sanitized": True,
        "source_pin": stock_probe.PIN,
        "deployment": stock_probe.HTTPS_ORIGIN,
        "checks": [],
        "cleanup_errors": [],
        "not_verified": [
            "approval request lifecycle (clarify-only toolset)",
            "sudo/secret lifecycle (not enabled)",
            "expiry live event (default timeout is not bounded)",
            "literal TUI/Desktop UI and physical device",
        ],
    }
    try:
        await _exercise(
            credentials,
            evidence,
            runtime=runtime,
            base=stock_probe.HTTPS_ORIGIN,
            ws_base=stock_probe.HTTPS_ORIGIN.replace("https://", "wss://"),
            origin=stock_probe.HTTPS_ORIGIN,
            tools_cwd=runtime / "tools",
            run_expiry=run_expiry,
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
        evidence["global_config_unchanged"] = _config_hash(runtime) == before
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError(f"Blocking probe failed; evidence: {output}") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Blocking clarify probe passed; evidence: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--run-expiry",
        action="store_true",
        help="Record that expiry is intentionally unrun; never changes config or waits unboundedly",
    )
    args = parser.parse_args()
    asyncio.run(run(_output_path(args.output), run_expiry=args.run_expiry))
