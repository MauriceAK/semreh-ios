#!/usr/bin/env python3
"""Bounded proof of a lost image-stage receipt on a live stock session.

The client deliberately forgets the successful ``image.attach_bytes`` receipt,
closes the socket, obtains a fresh ticket, and resumes the same stored session
within the stock orphan grace window.  It then sends plain text with no stage
or image reference.  Evidence contains only booleans, bounded counts, and the
owned disposable runtime identities; no raw frames, paths, credentials, or
server payloads are retained.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
from pathlib import Path

from websockets.asyncio.client import connect

import direct_hermes_probe as stock_probe
from direct_hermes_attachment_probe import (
    PNG_BYTES,
    PROFILE,
    RPC,
    RPC_TIMEOUT,
    _authenticated,
    _assert_latest_turn,
    _output_path,
    _rest_rows,
    _text,
    _validate_png_bytes,
)
from direct_hermes_capture import write_fixture


ORIGIN = stock_probe.HTTPS_ORIGIN
WS_BASE = ORIGIN.replace("https://", "wss://")


def _contains_key(value: object, key: str) -> bool:
    if isinstance(value, dict):
        return key in value or any(_contains_key(child, key) for child in value.values())
    if isinstance(value, list):
        return any(_contains_key(child, key) for child in value)
    return False


async def _fresh_ticket(client) -> str:
    response = await client.post("/api/auth/ws-ticket")
    if response.status_code != 200:
        raise RuntimeError("fresh WebSocket ticket request failed")
    ticket = response.json().get("ticket")
    if not isinstance(ticket, str) or not ticket:
        raise RuntimeError("fresh WebSocket ticket missing")
    return ticket


async def _close_owned_runtime(client, runtime_id: str | None, evidence: dict) -> None:
    """Close the one runtime created by this probe and record only its status."""
    if not isinstance(runtime_id, str) or not runtime_id:
        return
    try:
        ticket = await _fresh_ticket(client)
        async with connect(
            f"{WS_BASE}/api/ws?ticket={ticket}",
            origin=ORIGIN,
            proxy=None,
        ) as websocket:
            ready = json.loads(await asyncio.wait_for(websocket.recv(), RPC_TIMEOUT))
            if ready.get("params", {}).get("type") != "gateway.ready":
                evidence["cleanup_errors"].append({
                    "operation": "session.close",
                    "type": "gateway_ready_missing",
                })
                return
            rpc = RPC(websocket)
            closed = await rpc.call("session.close", {"session_id": runtime_id})
            if not isinstance(closed, dict) or closed.get("closed") is not True:
                evidence["cleanup_errors"].append({
                    "operation": "session.close",
                    "type": "unconfirmed",
                })
    except Exception:
        evidence["cleanup_errors"].append({
            "operation": "session.close",
            "type": "cleanup_exception",
        })


async def _exercise(credentials: dict, evidence: dict, verify_reset: bool = False) -> dict:
    _validate_png_bytes(PNG_BYTES)
    image_b64 = base64.b64encode(PNG_BYTES).decode("ascii")
    runtime_id: str | None = None
    created_runtime_id: str | None = None
    stored_id: str | None = None
    warmup_marker = "SEMREH_ORPHAN_ATTACHMENT_WARMUP"
    orphan_marker = "SEMREH_ORPHAN_ATTACHMENT_PLAIN_TEXT"
    async with _authenticated(credentials) as (client, first_ticket):
        try:
            async with connect(
                f"{WS_BASE}/api/ws?ticket={first_ticket}",
                origin=ORIGIN,
                proxy=None,
            ) as websocket:
                ready = json.loads(await asyncio.wait_for(websocket.recv(), RPC_TIMEOUT))
                if ready.get("params", {}).get("type") != "gateway.ready":
                    raise RuntimeError("gateway.ready missing")
                rpc = RPC(websocket)
                created = await rpc.call("session.create", {
                    "profile": PROFILE,
                    "cwd": str(stock_probe.RUNTIME / "tools"),
                    "model": "semreh-fixture",
                    "provider": "custom",
                    "close_on_disconnect": False,
                })
                if not isinstance(created, dict):
                    raise RuntimeError("session.create returned no object")
                runtime_id = created.get("session_id")
                created_runtime_id = runtime_id
                stored_id = created.get("stored_session_id")
                if not all(isinstance(value, str) and value for value in (runtime_id, stored_id)):
                    raise RuntimeError("session.create identity missing")

                await rpc.call("prompt.submit", {
                    "session_id": runtime_id,
                    "text": warmup_marker,
                })
                await rpc.wait_terminal(runtime_id)
                await rpc.wait_idle(runtime_id)
                warmup_rows = await _rest_rows(client, stored_id)
                _assert_latest_turn(warmup_rows, warmup_marker, ())
                warmup_durable = any(
                    row.get("role") == "user" and warmup_marker in _text(row)
                    for row in warmup_rows
                )
                if not warmup_durable:
                    raise RuntimeError("warmup user turn was not durable")

                attached = await rpc.call("image.attach_bytes", {
                    "session_id": runtime_id,
                    "content_base64": image_b64,
                    "filename": "orphan-proof.png",
                })
                if not isinstance(attached, dict) or attached.get("attached") is not True:
                    raise RuntimeError("image.attach_bytes did not attach")
                if not isinstance(attached.get("path"), str) or not attached.get("path", "").endswith(".png"):
                    raise RuntimeError("image.attach_bytes omitted its generated path")
                # Deliberately do not retain or send the generated path.  The
                # server has accepted the stage; the simulated client receipt
                # is now lost when this WebSocket is closed.
            fresh_ticket = await _fresh_ticket(client)
            if fresh_ticket == first_ticket:
                raise RuntimeError("fresh ticket was reused")
            async with connect(
                f"{WS_BASE}/api/ws?ticket={fresh_ticket}",
                origin=ORIGIN,
                proxy=None,
            ) as websocket:
                ready = json.loads(await asyncio.wait_for(websocket.recv(), RPC_TIMEOUT))
                if ready.get("params", {}).get("type") != "gateway.ready":
                    raise RuntimeError("fresh gateway.ready missing")
                rpc = RPC(websocket)
                resumed = await rpc.call("session.resume", {
                    "session_id": stored_id,
                    "profile": PROFILE,
                })
                if not isinstance(resumed, dict):
                    raise RuntimeError("session.resume returned no object")
                resumed_runtime_id = resumed.get("session_id")
                if resumed_runtime_id != runtime_id:
                    raise RuntimeError("session.resume did not reuse the live runtime")
                resume_omits_queue = not _contains_key(resumed, "attached_images")
                if not resume_omits_queue:
                    raise RuntimeError("session.resume unexpectedly exposed attachment queue")

                reset_preserved_history = False
                if verify_reset:
                    # Models the explicitly confirmed per-chat action. Only
                    # this probe-created, idle runtime may be closed.
                    await rpc.wait_idle(resumed_runtime_id)
                    before_reset = await _rest_rows(client, stored_id)
                    closed = await rpc.call("session.close", {"session_id": resumed_runtime_id})
                    if not isinstance(closed, dict) or closed.get("closed") is not True:
                        raise RuntimeError("explicit reset close was not confirmed")
                    runtime_id = None
                    reopened = await rpc.call("session.resume", {
                        "session_id": stored_id, "profile": PROFILE,
                    })
                    if not isinstance(reopened, dict):
                        raise RuntimeError("reset resume malformed")
                    new_runtime_id = reopened.get("session_id")
                    if not isinstance(new_runtime_id, str) or not new_runtime_id:
                        raise RuntimeError("reset runtime identity missing")
                    runtime_id = new_runtime_id
                    if runtime_id == resumed_runtime_id:
                        raise RuntimeError("reset unexpectedly reused closed runtime")
                    resumed_runtime_id = runtime_id
                    after_reset = await _rest_rows(client, stored_id)
                    if before_reset != after_reset:
                        raise RuntimeError("runtime reset changed saved history")
                    reset_preserved_history = True

                await rpc.call("prompt.submit", {
                    "session_id": resumed_runtime_id,
                    "text": orphan_marker,
                })
                await rpc.wait_terminal(resumed_runtime_id)
                await rpc.wait_idle(resumed_runtime_id)

                rows = await _rest_rows(client, stored_id)
                matching_users = [
                    row for row in rows
                    if row.get("role") == "user" and orphan_marker in _text(row)
                ]
                if len(matching_users) != 1:
                    raise RuntimeError("plain-text turn was not uniquely durable")
                user_text = _text(matching_users[0])
                image_reference_count = user_text.count("@image:")
                expected_images = 0 if verify_reset else 1
                if image_reference_count != expected_images:
                    raise RuntimeError("unexpected queued-image result after plain-text submit")

                return {
                    "outcome": "passed",
                    "backend_sha": stock_probe.PIN,
                    "warmup_durable": warmup_durable,
                    "fresh_ticket_used": True,
                    "resume_reused_runtime": True,
                    "resume_omits_queue_state": resume_omits_queue,
                    "plain_text_consumed_orphan_image": image_reference_count == 1,
                    "explicit_reset_verified": verify_reset,
                    "reset_preserved_history": reset_preserved_history,
                    "canonical_row_count": len(rows),
                    "canonical_image_reference_count": image_reference_count,
                    "created_runtime_id": created_runtime_id,
                    "resumed_runtime_id": resumed_runtime_id,
                    "stored_session_id": stored_id,
                }
        finally:
            await _close_owned_runtime(client, runtime_id, evidence)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--verify-reset", action="store_true")
    args = parser.parse_args()
    output = _output_path(args.output)
    evidence = {
        "sanitized": True,
        "source_pin": stock_probe.PIN,
        "deployment": "dedicated disposable HTTPS fixture",
        "cleanup_errors": [],
    }
    try:
        stock_probe.validate()
        credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text())
        evidence.update(asyncio.run(_exercise(credentials, evidence, args.verify_reset)))
        if evidence["cleanup_errors"]:
            raise RuntimeError("probe cleanup failed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["outcome"] = "failed"
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        print(json.dumps({
            "outcome": "failed",
            "error_type": type(error).__name__,
            "evidence_written": True,
            "secrets_or_auth_payloads_printed": False,
        }, sort_keys=True))
        raise SystemExit(1) from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(json.dumps({
        "outcome": "passed",
        "source_pin": evidence["source_pin"],
        "evidence_written": True,
        "secrets_or_auth_payloads_printed": False,
    }, sort_keys=True))


if __name__ == "__main__":
    main()
