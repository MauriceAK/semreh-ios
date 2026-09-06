#!/usr/bin/env python3
"""Bounded localhost proof for in-place history and rotating compression lineage."""

from __future__ import annotations

import argparse
import asyncio
from dataclasses import dataclass
import hashlib
import json
import time
from contextlib import asynccontextmanager
import contextlib
import io
from pathlib import Path

import httpx
from websockets.asyncio.client import connect

from direct_hermes_capture import write_fixture
import direct_hermes_probe as stock_probe
from direct_hermes_development import (
    COMPRESSION_MODES,
    COMPRESSION_PORT,
    _runtime_for_mode,
    _validated_baseline_fixture,
    _validate_all,
    _validate_runtime,
)
from direct_hermes_identity_probe import binding
from direct_hermes_model_fixture import (
    COMPRESSION_BULKY_MARKER_PREFIX,
    compression_bulky_assistant,
)
from direct_hermes_reasoning_probe import Probe, _json_frame, _output_path


BASE = f"http://127.0.0.1:{COMPRESSION_PORT}"
WS_BASE = f"ws://127.0.0.1:{COMPRESSION_PORT}"
ORIGIN = BASE
PROFILE = "default"
TURN_COUNT = 12
RPC_TIMEOUT = 35.0
COMPRESSION_TIMEOUT = 150.0


@dataclass(frozen=True)
class CompressionFixture:
    runtime: Path
    backend_sha: str
    stock: bool


STOCK_PIN = stock_probe.PIN


def runtime(mode: str) -> Path:
    if mode not in COMPRESSION_MODES:
        raise RuntimeError("compression mode must be explicit")
    return _runtime_for_mode(mode)


def select_fixture(
    mode: str, *, stock_backend: bool, backend_sha: str | None
) -> CompressionFixture:
    """Resolve the fixed compression sibling and one explicit backend mode."""
    if mode not in COMPRESSION_MODES:
        raise ValueError("compression mode must be explicit")
    if stock_backend:
        if backend_sha is not None:
            raise ValueError("--stock-backend cannot be combined with --backend-sha")
        return CompressionFixture(runtime(mode), STOCK_PIN, True)
    if not backend_sha:
        raise ValueError("--backend-sha is required without --stock-backend")
    return CompressionFixture(runtime(mode), backend_sha.lower(), False)


def validate_fixture(fixture: CompressionFixture, mode: str) -> None:
    """Validate baseline+compression fixtures without exposing credentials."""
    if fixture.runtime != runtime(mode):
        raise RuntimeError("compression fixture runtime does not match requested mode")
    if fixture.stock:
        if fixture.backend_sha != STOCK_PIN:
            raise RuntimeError("stock compression fixture must use the approved stock pin")
        # Baseline validation pins the exact stock source/runtime.  The second
        # validator checks this mode's fixed sibling against that baseline's
        # credentials and overlay, including the marker, paths and port.
        with contextlib.redirect_stdout(io.StringIO()):
            baseline_config, baseline_credentials = _validated_baseline_fixture()
            _validate_runtime(
                baseline_config,
                baseline_credentials,
                compression_mode=mode,
            )
        return
    _validate_all(fixture.backend_sha, compression_mode=mode)


def config_hash(mode: str) -> str:
    path = runtime(mode) / "home" / "config.yaml"
    if path.is_symlink() or path.resolve() != path or not path.is_file():
        raise RuntimeError("unexpected disposable compression config path")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prompt(index: int) -> str:
    return f"{COMPRESSION_BULKY_MARKER_PREFIX}{index:02d}"


def row_text(row: dict) -> str:
    content = row.get("display_content", row.get("content", ""))
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            str(item.get("text", "")) if isinstance(item, dict) else str(item)
            for item in content
        )
    return str(content or "")


def assert_originals_once_in_order(
    rows: list[dict], prompts: list[str], assistant_texts: list[str]
) -> None:
    if len(prompts) != len(assistant_texts):
        raise AssertionError("expected compression turn pairs disagree")
    expected = [
        pair
        for user, assistant in zip(prompts, assistant_texts, strict=True)
        for pair in (("user", user), ("assistant", assistant))
    ]
    expected_text = {text for _, text in expected}
    observed = [
        (str(row.get("role", "")), row_text(row))
        for row in rows
        if row_text(row) in expected_text
    ]
    if observed != expected:
        raise AssertionError("original durable turns were missing, duplicated, or reordered")


def assert_reduction(result: dict) -> None:
    summary = result.get("summary") if isinstance(result.get("summary"), dict) else {}
    if result.get("status") != "compressed" or summary.get("aborted") is True:
        raise AssertionError("compression did not report a non-aborted commit")
    before_messages = result.get("before_messages")
    after_messages = result.get("after_messages")
    before_tokens = result.get("before_tokens")
    after_tokens = result.get("after_tokens")
    if not all(isinstance(value, int) for value in (
        result.get("removed"), before_messages, after_messages, before_tokens, after_tokens
    )):
        raise AssertionError("compression acknowledgement omitted numeric reduction evidence")
    if result["removed"] <= 0 or after_messages >= before_messages or after_tokens >= before_tokens:
        raise AssertionError("compression was a no-op or did not reduce both rows and tokens")


def reduction_evidence(result: dict) -> dict:
    """Copy only bounded scalar diagnostics; never retain result messages."""
    summary = result.get("summary") if isinstance(result.get("summary"), dict) else {}
    flags = {
        key: summary.get(key) is True
        for key in ("aborted", "refused_would_grow", "fallback_used", "noop")
    }
    if flags["refused_would_grow"]:
        category = "refused_would_grow"
    elif flags["aborted"]:
        category = "aborted"
    elif flags["fallback_used"]:
        category = "fallback_used"
    elif flags["noop"]:
        category = "noop"
    else:
        category = "committed_or_unknown"
    status = result.get("status")
    copied = {"status": status if isinstance(status, str) else None}
    for key in (
        "removed", "before_messages", "after_messages", "before_tokens", "after_tokens"
    ):
        value = result.get(key)
        copied[key] = value if isinstance(value, int) and not isinstance(value, bool) else None
    copied["summary"] = {**flags, "reason_category": category}
    return copied


async def messages(client, requested: str, *, include_compacted: bool, order: str,
                   limit: int, offset: int) -> tuple[str, list[dict], dict]:
    response = await client.get(f"/api/sessions/{requested}/messages", params={
        "profile": PROFILE,
        "include_compacted": "true" if include_compacted else "false",
        "order": order,
        "limit": limit,
        "offset": offset,
    })
    response.raise_for_status()
    payload = response.json()
    rows = payload.get("messages")
    pagination = payload.get("pagination")
    if not isinstance(payload.get("session_id"), str) or not isinstance(rows, list):
        raise RuntimeError("malformed profiled message page")
    if not isinstance(pagination, dict) or (
        pagination.get("limit") != limit
        or pagination.get("offset") != offset
        or pagination.get("order") != order
        or pagination.get("returned") != len(rows)
    ):
        raise AssertionError("message page returned inconsistent pagination metadata")
    return payload["session_id"], rows, pagination


async def reconstructed_latest(client, requested: str, expected_canonical: str,
                               *, include_compacted: bool, total: int,
                               page_size: int = 5) -> list[dict]:
    rebuilt: list[dict] = []
    for offset in range(0, total, page_size):
        canonical, rows, _ = await messages(
            client, requested, include_compacted=include_compacted,
            order="latest", limit=page_size, offset=offset,
        )
        if canonical != expected_canonical:
            raise AssertionError("paged request changed canonical session id")
        rebuilt = rows + rebuilt
    return rebuilt


async def session_detail(client, session_id: str) -> dict:
    response = await client.get(
        f"/api/sessions/{session_id}", params={"profile": PROFILE}
    )
    response.raise_for_status()
    payload = response.json()
    if not isinstance(payload, dict):
        raise RuntimeError("malformed session metadata response")
    return payload


def assert_rotation_metadata(parent: dict, child_row: dict, ancestor: str, child: str) -> None:
    if parent.get("id", parent.get("session_id")) != ancestor:
        raise AssertionError("rotation metadata omitted parent or child")
    if child_row.get("id", child_row.get("session_id")) != child:
        raise AssertionError("rotation metadata omitted parent or child")
    if child_row.get("parent_session_id") != ancestor:
        raise AssertionError("rotated child does not point to compression parent")
    if parent.get("end_reason") != "compression" or parent.get("ended_at") is None:
        raise AssertionError("compression parent was not durably closed for compression")


@asynccontextmanager
async def authenticated(credentials: dict, evidence: dict):
    async with httpx.AsyncClient(base_url=BASE, trust_env=False, follow_redirects=False) as client:
        login = await client.post("/auth/password-login", json={
            "provider": "basic", **credentials, "next": "",
        })
        if login.status_code not in (200, 302, 303):
            raise RuntimeError("fixture login failed")
        try:
            ticket_response = await client.post("/api/auth/ws-ticket")
            ticket_response.raise_for_status()
            ticket = ticket_response.json().get("ticket")
            if not isinstance(ticket, str) or not ticket:
                raise RuntimeError("fixture ticket missing")
            yield client, ticket
        finally:
            try:
                logout = await client.post("/auth/logout")
                if logout.status_code != 302 or logout.headers.get("location") != "/login":
                    raise AssertionError("logout contract changed")
                protected = await client.get("/api/sessions", params={"profile": PROFILE})
                if protected.status_code != 401:
                    raise AssertionError("logout left fixture authenticated")
            except Exception as error:
                evidence["cleanup_errors"].append({"operation": "logout", "type": type(error).__name__})


async def normal_turn(probe: Probe, runtime_id: str, text: str) -> None:
    start = len(probe.frames)
    await probe.rpc("prompt.submit", {"session_id": runtime_id, "text": text})
    terminal = await probe.wait_terminal(runtime_id, start)
    payload = (terminal.get("params") or {}).get("payload") or {}
    if payload.get("status") != "complete":
        raise AssertionError("fixture turn did not complete normally")
    await probe.wait_idle(runtime_id)


async def exercise(mode: str, credentials: dict, evidence: dict) -> None:
    tool_cwd = runtime(mode) / "tools"
    async with authenticated(credentials, evidence) as (client, ticket):
        async with connect(f"{WS_BASE}/api/ws?ticket={ticket}", origin=ORIGIN, proxy=None) as ws:
            ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("missing gateway.ready")
            probe = Probe(ws, client, {"frames": []})
            owned: set[str] = set()
            try:
                evidence["phase"] = "fresh owned session create"
                created = await probe.rpc("session.create", {
                    "profile": PROFILE, "cwd": str(tool_cwd),
                    "model": "semreh-fixture", "provider": "custom",
                })
                runtime_id, ancestor = binding(created)
                owned.add(runtime_id)
                evidence["ancestor_id"] = ancestor
                evidence["initial_runtime_id"] = runtime_id
                prompts = [prompt(index) for index in range(TURN_COUNT)]
                assistant_texts = [
                    compression_bulky_assistant(index) for index in range(TURN_COUNT)
                ]
                for index, text in enumerate(prompts):
                    evidence["phase"] = f"seed turn {index + 1} of {TURN_COUNT}"
                    await normal_turn(probe, runtime_id, text)

                evidence["phase"] = "pre-compression durable readback"
                canonical, originals, _ = await messages(
                    client, ancestor, include_compacted=False,
                    order="oldest", limit=100, offset=0,
                )
                if canonical != ancestor:
                    raise AssertionError("fresh session canonicalized before compression")
                assert_originals_once_in_order(originals, prompts, assistant_texts)

                evidence["phase"] = "actual session.compress"
                result = await probe.rpc(
                    "session.compress", {"session_id": runtime_id}, timeout=COMPRESSION_TIMEOUT
                )
                evidence["reduction"] = reduction_evidence(result)
                assert_reduction(result)
                tip = (result.get("info") or {}).get("stored_session_id")
                if not isinstance(tip, str) or not tip:
                    raise AssertionError("compression response omitted durable tip identity")
                evidence["tip_id"] = tip

                evidence["phase"] = "post-compression active readback"
                active_canonical, active_after, _ = await messages(
                    client, ancestor, include_compacted=False,
                    order="oldest", limit=100, offset=0,
                )
                if len(active_after) >= len(originals):
                    raise AssertionError("active REST history did not reduce after compression")

                if mode == "in-place":
                    if tip != ancestor:
                        raise AssertionError("in-place compression rotated durable identity")
                    evidence["phase"] = "in-place compacted chronological paging"
                    canonical, display, pagination = await messages(
                        client, ancestor, include_compacted=True,
                        order="oldest", limit=100, offset=0,
                    )
                    if canonical != ancestor:
                        raise AssertionError("in-place history changed canonical identity")
                    if active_canonical != ancestor:
                        raise AssertionError("in-place active history changed canonical identity")
                    assert_originals_once_in_order(display, prompts, assistant_texts)
                    if not any(bool(row.get("compacted")) for row in display):
                        raise AssertionError("include_compacted exposed no archived row")
                    rebuilt = await reconstructed_latest(
                        client, ancestor, ancestor, include_compacted=True, total=len(display)
                    )
                    if rebuilt != display:
                        raise AssertionError("latest compacted pages did not reconstruct oldest display set")
                    evidence["checks"] = [
                        "actual non-aborted row/token reduction",
                        "in-place original history ordered exactly once",
                        "compacted latest pages reconstruct oldest display set",
                    ]
                else:
                    if not isinstance(tip, str) or not tip or tip == ancestor:
                        raise AssertionError("rotating compression did not produce a distinct durable tip")
                    if active_canonical != tip:
                        raise AssertionError("rotated active history did not canonicalize to the tip")
                    evidence["phase"] = "rotation parent-child metadata"
                    assert_rotation_metadata(
                        await session_detail(client, ancestor),
                        await session_detail(client, tip),
                        ancestor,
                        tip,
                    )
                    evidence["phase"] = "ancestor and child canonical paging"
                    ancestor_canonical, child_before, _ = await messages(
                        client, ancestor, include_compacted=True,
                        order="oldest", limit=100, offset=0,
                    )
                    child_canonical, direct_child, _ = await messages(
                        client, tip, include_compacted=True,
                        order="oldest", limit=100, offset=0,
                    )
                    if ancestor_canonical != tip or child_canonical != tip or child_before != direct_child:
                        raise AssertionError("ancestor and child did not resolve to identical canonical tip pages")
                    if len(child_before) >= len(originals):
                        raise AssertionError("rotated child unexpectedly reproduced full parent history")

                    evidence["phase"] = "cold resume ancestor for continuation"
                    pre_resume_runtime = runtime_id
                    closed = await probe.rpc("session.close", {"session_id": runtime_id})
                    if closed.get("closed") is not True:
                        raise AssertionError("pre-continuation runtime close failed")
                    owned.remove(runtime_id)
                    resumed = await probe.rpc("session.resume", {
                        "session_id": ancestor, "profile": PROFILE,
                    })
                    runtime_id, resumed_tip = binding(resumed, tip)
                    if runtime_id == pre_resume_runtime:
                        raise AssertionError("closed runtime was reused for ancestor continuation")
                    owned.add(runtime_id)
                    evidence["continuation_runtime_id"] = runtime_id
                    continuation = "SEMREH_COMPRESSION_ROTATED_CONTINUATION"
                    evidence["phase"] = "rotated continuation turn"
                    await normal_turn(probe, runtime_id, continuation)
                    pre_cold_runtime = runtime_id
                    closed = await probe.rpc("session.close", {"session_id": runtime_id})
                    if closed.get("closed") is not True:
                        raise AssertionError("continuation runtime close failed")
                    owned.remove(runtime_id)
                    evidence["phase"] = "second cold resume and child paging"
                    cold = await probe.rpc("session.resume", {
                        "session_id": ancestor, "profile": PROFILE,
                    })
                    runtime_id, cold_tip = binding(cold, tip)
                    if runtime_id == pre_cold_runtime or runtime_id == pre_resume_runtime:
                        raise AssertionError("second cold resume reused a closed runtime")
                    owned.add(runtime_id)
                    evidence["cold_runtime_id"] = runtime_id
                    canonical, child_after, _ = await messages(
                        client, ancestor, include_compacted=True,
                        order="oldest", limit=100, offset=0,
                    )
                    expected_suffix = [
                        ("user", continuation),
                        ("assistant", "SEMREH_SLICE1_ACK"),
                    ]
                    actual_suffix = [
                        (str(row.get("role", "")), row_text(row))
                        for row in child_after[-2:]
                    ]
                    if (
                        canonical != tip
                        or len(child_after) != len(child_before) + 2
                        or actual_suffix != expected_suffix
                        or sum(row_text(row) == continuation for row in child_after) != 1
                    ):
                        raise AssertionError("ancestor continuation did not survive exactly once on cold tip")
                    rebuilt = await reconstructed_latest(
                        client, ancestor, tip, include_compacted=True, total=len(child_after)
                    )
                    if rebuilt != child_after:
                        raise AssertionError("rotated child latest pages did not reconstruct its oldest set")
                    evidence["checks"] = [
                        "actual non-aborted row/token reduction",
                        "exact parent-child compression metadata",
                        "ancestor canonicalizes to child-only tip pages",
                        "ancestor continuation survives cold reload exactly once",
                    ]
                    evidence["parent_history_reconstruction_claimed"] = False
                evidence["before_messages"] = result["before_messages"]
                evidence["after_messages"] = result["after_messages"]
                evidence["before_tokens"] = result["before_tokens"]
                evidence["after_tokens"] = result["after_tokens"]
            finally:
                evidence["cleanup_phase"] = "close owned runtimes"
                for runtime_id in list(owned):
                    try:
                        closed = await probe.rpc("session.close", {"session_id": runtime_id})
                        if closed.get("closed") is not True:
                            raise AssertionError("close not confirmed")
                    except Exception as error:
                        evidence["cleanup_errors"].append({"operation": "session.close", "type": type(error).__name__})


async def run(
    mode: str,
    output: Path,
    backend_sha: str | None = None,
    *,
    stock_backend: bool = False,
) -> None:
    fixture = select_fixture(
        mode,
        stock_backend=stock_backend,
        backend_sha=backend_sha,
    )
    validate_fixture(fixture, mode)
    credentials = json.loads((fixture.runtime / "credentials.json").read_text(encoding="utf-8"))
    before = config_hash(mode)
    evidence = {
        "sanitized": True, "backend_sha": fixture.backend_sha, "compression_mode": mode,
        "stock_backend": fixture.stock,
        "deployment": BASE, "provider": "deterministic localhost fixture",
        "cleanup_errors": [], "checks": [],
        "fallback_note": "empty auxiliary chain retains the guarded localhost main-model safety fallback",
    }
    try:
        await exercise(mode, credentials, evidence)
        if evidence["cleanup_errors"]:
            raise AssertionError("fixture cleanup failed")
        if config_hash(mode) != before:
            raise AssertionError("compression fixture config changed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["outcome"] = "failed"
        evidence["error_type"] = type(error).__name__
        if isinstance(error, AssertionError):
            # Probe assertions are fixed local strings. Never persist provider,
            # HTTP, RPC, or other external exception text.
            evidence["assertion_detail"] = str(error)
        evidence["global_config_unchanged"] = config_hash(mode) == before
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError(f"Compression probe failed; evidence: {output}") from None
    evidence["global_config_unchanged"] = True
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Compression probe passed; evidence: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True, choices=COMPRESSION_MODES)
    backend = parser.add_mutually_exclusive_group(required=True)
    backend.add_argument("--backend-sha")
    backend.add_argument("--stock-backend", action="store_true")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    asyncio.run(
        run(
            args.mode,
            _output_path(args.output),
            args.backend_sha,
            stock_backend=args.stock_backend,
        )
    )
