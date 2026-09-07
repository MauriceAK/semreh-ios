#!/usr/bin/env python3
"""Guarded full-session ``session.branch`` probe for the disposable stock gateway.

This is a protocol/persistence check, not a UI or compression claim.  It creates
one fresh default-profile session, writes two deterministic turns, branches the
complete history (deliberately omitting ``count``), and verifies the child through
the authoritative messages resolver.  Only the two runtimes created by this
probe are closed.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
from pathlib import Path
from typing import Any

import httpx

import direct_hermes_probe as stock_probe
from direct_hermes_capture import write_fixture
from direct_hermes_identity_probe import authenticated, binding
from direct_hermes_reasoning_probe import (
    PROFILE,
    Probe,
    RPC_TIMEOUT,
    _json_frame,
    _output_path,
    _row_text,
)
from websockets.asyncio.client import connect


BRANCH_METHOD = "session.branch"
MESSAGES_ROUTE = "/api/sessions/{session_id}/messages"
DETAIL_ROUTE = "/api/sessions/{session_id}"
MESSAGE_LIMIT = 100
PARENT_MARKERS = ("SEMREH_S4_BRANCH_PARENT_V1_A", "SEMREH_S4_BRANCH_PARENT_V1_B")


def _canonical_rows(rows: Any) -> list[tuple[str, str]]:
    """Return only visible role/content pairs; never persist the source rows."""
    if not isinstance(rows, list):
        raise AssertionError("messages response did not contain a list")
    result: list[tuple[str, str]] = []
    for row in rows:
        if not isinstance(row, dict):
            raise AssertionError("messages response contained a non-object row")
        role = row.get("role")
        if role not in ("user", "assistant"):
            continue
        text = _row_text(row)
        if not text.strip():
            raise AssertionError("visible message row was empty")
        result.append((role, text))
    return result


def _summary(rows: list[tuple[str, str]]) -> dict[str, Any]:
    encoded = json.dumps(rows, ensure_ascii=False, separators=(",", ":"))
    return {
        "row_count": len(rows),
        "pair_count": sum(role == "user" for role, _ in rows),
        "role_sequence": [role for role, _ in rows],
        "content_sha256": hashlib.sha256(encoded.encode("utf-8")).hexdigest(),
    }


def assert_full_copy(
    parent_before: list[tuple[str, str]],
    child: list[tuple[str, str]],
    parent_after: list[tuple[str, str]],
) -> None:
    if not parent_before or len(parent_before) % 2:
        raise AssertionError("parent transcript was not a non-empty full-turn sequence")
    if [role for role, _ in parent_before] != [r for _ in range(len(parent_before) // 2) for r in ("user", "assistant")]:
        raise AssertionError("parent transcript did not preserve user/assistant order")
    if child != parent_before:
        raise AssertionError("branch child did not copy the complete parent transcript")
    if parent_after != parent_before:
        raise AssertionError("branch changed the parent transcript")
    users = [text for role, text in parent_before if role == "user"]
    if users != list(PARENT_MARKERS):
        raise AssertionError("parent transcript markers did not match the owned fixture turns")


def assert_branch_result(
    result: Any,
    *,
    parent_runtime: str,
    parent_stored: str,
    expected_message_count: int,
    profile: str = PROFILE,
) -> tuple[str, str]:
    if not isinstance(result, dict):
        raise AssertionError("session.branch returned no object")
    child_runtime, child_stored = binding(result)
    if child_runtime == parent_runtime or child_stored == parent_stored:
        raise AssertionError("session.branch reused the parent identity")
    if result.get("parent") != parent_stored:
        raise AssertionError("session.branch parent did not identify the owned durable parent")
    if result.get("message_count") != expected_message_count:
        raise AssertionError("session.branch reported an incomplete copied message count")
    info = result.get("info")
    if isinstance(info, dict) and info.get("profile") not in (None, profile):
        raise AssertionError("session.branch response escaped the requested profile")
    return child_runtime, child_stored


def assert_child_extension(
    parent_rows: list[tuple[str, str]], child_rows: list[tuple[str, str]], marker: str
) -> None:
    if child_rows[: len(parent_rows)] != parent_rows:
        raise AssertionError("child turn did not preserve the copied parent prefix")
    suffix = child_rows[len(parent_rows) :]
    if len(suffix) != 2 or suffix[0] != ("user", marker) or suffix[1][0] != "assistant":
        raise AssertionError("child turn did not append one owned user/assistant pair")


def _assert_detail(payload: Any, expected_id: str, *, profile: str, parent: str | None = None) -> None:
    if not isinstance(payload, dict):
        raise AssertionError("session detail was not an object")
    returned_id = payload.get("id", payload.get("session_id"))
    if returned_id != expected_id:
        raise AssertionError("session detail resolved an unexpected durable identity")
    if payload.get("profile") != profile:
        raise AssertionError("session detail escaped the requested profile")
    if parent is not None and payload.get("parent_session_id") != parent:
        raise AssertionError("session detail did not preserve the branch parent")


async def _messages(client: httpx.AsyncClient, stored_id: str) -> list[tuple[str, str]]:
    response = await client.get(
        MESSAGES_ROUTE.format(session_id=stored_id),
        params={
            "profile": PROFILE,
            "include_compacted": "true",
            "order": "oldest",
            "limit": MESSAGE_LIMIT,
            "offset": 0,
        },
    )
    if response.status_code != 200:
        raise RuntimeError("authoritative messages read failed")
    payload = response.json()
    if payload.get("session_id") != stored_id:
        raise AssertionError("messages resolver returned an unexpected canonical ID")
    return _canonical_rows(payload.get("messages"))


async def _detail(client: httpx.AsyncClient, stored_id: str) -> dict[str, Any]:
    response = await client.get(
        DETAIL_ROUTE.format(session_id=stored_id), params={"profile": PROFILE}
    )
    if response.status_code != 200:
        raise RuntimeError("authoritative session detail read failed")
    payload = response.json()
    if not isinstance(payload, dict):
        raise RuntimeError("session detail response was not an object")
    return payload


async def _exercise(credentials: dict[str, Any], evidence: dict[str, Any]) -> None:
    base = stock_probe.HTTPS_ORIGIN
    ws_base = base.replace("https://", "wss://")
    owned_runtimes: set[str] = set()
    branch_dispatched = False
    branch_ack_received = False
    async with authenticated(credentials, evidence, base=base, origin=base) as (client, ticket):
        ws = None
        probe: Probe | None = None
        try:
            ws = await connect(f"{ws_base}/api/ws?ticket={ticket}", origin=base, proxy=None)
            ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("stock gateway did not become ready")
            probe = Probe(ws, client, {"frames": []})

            evidence["phase"] = "create and warm owned parent"
            created = await probe.rpc("session.create", {
                "profile": PROFILE,
                "cwd": str(stock_probe.RUNTIME / "tools"),
                "model": "semreh-fixture",
                "provider": "custom",
                "reasoning_effort": "low",
            })
            parent_runtime, parent_stored = binding(created)
            owned_runtimes.add(parent_runtime)
            prompts: list[str] = []
            for marker in PARENT_MARKERS:
                start = len(probe.frames)
                accepted = await probe.rpc("prompt.submit", {
                    "session_id": parent_runtime,
                    "text": marker,
                })
                if not isinstance(accepted, dict) or accepted.get("status") not in ("streaming", "queued"):
                    raise AssertionError("owned branch warmup prompt was not accepted")
                await probe.wait_terminal(parent_runtime, start)
                await probe.wait_idle(parent_runtime)
                prompts.append(marker)

            parent_before = await _messages(client, parent_stored)
            if [text for role, text in parent_before if role == "user"] != prompts:
                raise AssertionError("parent messages did not contain the owned fixture turns")
            evidence["parent_before"] = _summary(parent_before)

            evidence["phase"] = "full-session branch without count"
            branch_params = {"session_id": parent_runtime}
            branch_dispatched = True
            evidence["branch_dispatched"] = True
            try:
                branched = await probe.rpc(BRANCH_METHOD, branch_params)
                branch_ack_received = True
                evidence["branch_ack_received"] = True
            except Exception:
                evidence["branch_ack_received"] = False
                evidence["unknown_child_cleanup_required"] = True
                raise
            # Register the returned runtime before validating the rest of the
            # response. A malformed ACK must not leak a known child runtime.
            if (isinstance(branched, dict)
                    and isinstance(branched.get("session_id"), str)
                    and branched["session_id"].strip()):
                owned_runtimes.add(branched["session_id"])
            else:
                evidence["unknown_child_cleanup_required"] = True
            child_runtime, child_stored = assert_branch_result(
                branched,
                parent_runtime=parent_runtime,
                parent_stored=parent_stored,
                expected_message_count=len(parent_before),
            )
            owned_runtimes.add(child_runtime)
            evidence["branch_request"] = {
                "method": BRANCH_METHOD,
                "fields": sorted(branch_params),
                "count_omitted": "count" not in branch_params,
            }

            evidence["phase"] = "verify child profile parent and canonical content"
            child_detail = await _detail(client, child_stored)
            _assert_detail(child_detail, child_stored, profile=PROFILE, parent=parent_stored)
            parent_detail = await _detail(client, parent_stored)
            _assert_detail(parent_detail, parent_stored, profile=PROFILE)
            child_rows = await _messages(client, child_stored)
            assert_full_copy(parent_before, child_rows, await _messages(client, parent_stored))
            evidence["phase"] = "verify child independent turn and parent unchanged"
            child_marker = "SEMREH_S4_BRANCH_CHILD_V1"
            child_start = len(probe.frames)
            accepted = await probe.rpc("prompt.submit", {
                "session_id": child_runtime,
                "text": child_marker,
            })
            if not isinstance(accepted, dict) or accepted.get("status") not in ("streaming", "queued"):
                raise AssertionError("owned child prompt was not accepted")
            await probe.wait_terminal(child_runtime, child_start)
            await probe.wait_idle(child_runtime)
            child_after = await _messages(client, child_stored)
            assert_child_extension(parent_before, child_after, child_marker)
            parent_after = await _messages(client, parent_stored)
            if parent_after != parent_before:
                raise AssertionError("child turn changed the parent transcript")
            evidence["child"] = {
                "runtime_created": child_runtime != parent_runtime,
                "stored_id_distinct": child_stored != parent_stored,
                "profile_verified": child_detail.get("profile") == PROFILE,
                "parent_verified": child_detail.get("parent_session_id") == parent_stored,
                "content_verified": child_rows == parent_before,
                "messages": _summary(child_rows),
                "independent_turn_verified": True,
                "after_turn_messages": _summary(child_after),
            }
            evidence["parent_after"] = _summary(parent_after)
            evidence["checks"] = [
                "full session.branch request omitted count",
                "child profile matched default",
                "child parent_session_id matched parent durable ID",
                "child content matched complete parent content",
                "parent content remained unchanged",
            ]
        finally:
            if branch_dispatched and not branch_ack_received:
                evidence["unknown_child_cleanup_required"] = True
            if probe is not None:
                for runtime_id in sorted(owned_runtimes):
                    try:
                        closed = await probe.rpc("session.close", {"session_id": runtime_id})
                        if not isinstance(closed, dict) or closed.get("closed") is not True:
                            evidence["cleanup_errors"].append("owned session.close not confirmed")
                    except Exception as error:
                        evidence["cleanup_errors"].append(
                            {"operation": "session.close", "type": type(error).__name__}
                        )
            if ws is not None:
                await ws.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stock-backend", action="store_true", required=True)
    parser.add_argument("--output", required=True)
    return parser


def run(output: Path, *, stock_backend: bool = False) -> None:
    if not stock_backend:
        raise RuntimeError("This bounded branch probe only permits the pinned stock backend")
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
        "not_verified": ["compression", "latest-descendant resolution", "UI/device behavior"],
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
        raise RuntimeError(f"Branch probe failed; evidence: {output}") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Branch assertions passed; sanitized evidence: {output}")


if __name__ == "__main__":
    args = build_parser().parse_args()
    run(_output_path(args.output), stock_backend=args.stock_backend)
