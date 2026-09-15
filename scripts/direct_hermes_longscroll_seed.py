#!/usr/bin/env python3
"""Create a bounded disposable stock transcript for long-scroll UI checks.

This is an explicit fixture-only JSON-RPC seed. It does not change backend
configuration, app source, or UI acceptance thresholds.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import re
import uuid
from pathlib import Path

from websockets.asyncio.client import connect

import direct_hermes_probe as stock_probe
from direct_hermes_capture import write_fixture
from direct_hermes_identity_probe import authenticated, _rest_rows, _row_text
from direct_hermes_reasoning_probe import (
    PROFILE,
    Probe,
    RPC_TIMEOUT,
    _json_frame,
    _output_path,
)


EXPECTED_RUNTIME = Path("/Users/maurice/workspace/semreh-slice1-runtime")
EXPECTED_SOURCE_PIN = "29112bef099274229cadff79cdff7bf7b99c4b77"
EXPECTED_ORIGIN = "https://semreh-slice1-test.tailda8427.ts.net"
ACK = "SEMREH_SLICE1_ACK"
MIN_TURNS = 70
MAX_TURNS = 80
DEFAULT_TURNS = 72
PAGE_LIMIT = 100
MAX_TRANSCRIPT_ROWS = MAX_TURNS * 2
STORED_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
SAFE_MARKER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\Z")
RUN_NONCE = re.compile(r"[0-9a-f]{32}\Z")


def _validate_turn_count(turns: int) -> int:
    if isinstance(turns, bool) or not isinstance(turns, int):
        raise ValueError("turn count must be an integer")
    if not MIN_TURNS <= turns <= MAX_TURNS:
        raise ValueError(f"turn count must be between {MIN_TURNS} and {MAX_TURNS}")
    return turns


def _parse_turn_count(raw: str) -> int:
    try:
        turns = int(raw)
    except ValueError as error:
        raise argparse.ArgumentTypeError("turn count must be an integer") from error
    try:
        return _validate_turn_count(turns)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


def _build_prompts(run_nonce: str, turns: int) -> list[str]:
    _validate_turn_count(turns)
    if not RUN_NONCE.fullmatch(run_nonce):
        raise ValueError("run nonce must be a lowercase UUID hex value")
    prefix = f"SEMREH_LONGSCROLL_SEED_{run_nonce}"
    prompts = [f"{prefix}_TURN_{index:03d}" for index in range(1, turns + 1)]
    if (
        len(set(prompts)) != turns
        or any(not SAFE_MARKER.fullmatch(prompt) or len(prompt) > 80 for prompt in prompts)
    ):
        raise ValueError("generated prompts did not match the bounded synthetic marker contract")
    return prompts


def _assert_approved_target() -> None:
    if (
        stock_probe.RUNTIME != EXPECTED_RUNTIME
        or stock_probe.PIN != EXPECTED_SOURCE_PIN
        or stock_probe.HTTPS_ORIGIN != EXPECTED_ORIGIN
    ):
        raise RuntimeError("long-scroll seed is restricted to the approved stock fixture target")


def _stock_config_hash() -> str:
    path = EXPECTED_RUNTIME / "home" / "config.yaml"
    if path.is_symlink() or path.resolve() != path or not path.is_file():
        raise RuntimeError("Unexpected approved stock config path")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _canonical_digest(rows: list[dict]) -> str:
    encoded = json.dumps(rows, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(encoded).hexdigest()


def _row_identity(row: dict) -> str | None:
    value = row.get("id")
    if isinstance(value, str) and value.strip():
        return "s:" + value
    if isinstance(value, int) and not isinstance(value, bool):
        return "n:" + str(value)
    return None


def _validate_canonical_rows(rows: list[dict], prompts: list[str], stored_id: str) -> None:
    if not STORED_ID.fullmatch(stored_id):
        raise ValueError("canonical transcript durable identity is not bounded")
    if len(rows) != len(prompts) * 2:
        raise ValueError("canonical transcript row count did not match the submitted turns")
    expected_roles = [role for _ in prompts for role in ("user", "assistant")]
    if [row.get("role") for row in rows] != expected_roles:
        raise ValueError("canonical transcript roles were not exact user/assistant pairs")
    identities = [_row_identity(row) for row in rows]
    if any(identity is None for identity in identities) or len(set(identities)) != len(rows):
        raise ValueError("canonical transcript omitted or duplicated row identities")
    for index, prompt in enumerate(prompts):
        if _row_text(rows[index * 2]) != prompt or _row_text(rows[index * 2 + 1]) != ACK:
            raise ValueError("canonical transcript did not match the exact synthetic prompt/ACK series")


async def _canonical_rows(client, stored_id: str) -> list[dict]:
    rows: list[dict] = []
    for offset in range(0, MAX_TRANSCRIPT_ROWS + 1, PAGE_LIMIT):
        response = await client.get(
            f"/api/sessions/{stored_id}/messages",
            params={
                "profile": PROFILE,
                "include_compacted": "true",
                "order": "oldest",
                "limit": PAGE_LIMIT,
                "offset": offset,
            },
        )
        response.raise_for_status()
        payload = response.json()
        if not isinstance(payload, dict) or payload.get("session_id") != stored_id:
            raise RuntimeError("canonical REST page did not match the requested durable session")
        page = _rest_rows(payload)
        if len(page) > PAGE_LIMIT:
            raise RuntimeError("canonical REST page exceeded its requested bound")
        pagination = payload.get("pagination")
        if pagination is not None and (
            not isinstance(pagination, dict)
            or pagination.get("limit") != PAGE_LIMIT
            or pagination.get("offset") != offset
            or pagination.get("order") != "oldest"
            or pagination.get("returned") != len(page)
        ):
            raise RuntimeError("canonical REST pagination metadata did not match the bounded request")
        rows.extend(page)
        if len(rows) > MAX_TRANSCRIPT_ROWS:
            raise RuntimeError("canonical transcript exceeded the 160-row fixture bound")
        if len(page) < PAGE_LIMIT:
            return rows
    raise RuntimeError("canonical transcript exceeded the bounded readback page count")


async def _seed(credentials: dict, turns: int, evidence: dict) -> tuple[str, str]:
    base = EXPECTED_ORIGIN
    ws_base = base.replace("https://", "wss://")
    tools_cwd = EXPECTED_RUNTIME / "tools"
    run_nonce = uuid.uuid4().hex
    prompts = _build_prompts(run_nonce, turns)
    prefix = f"SEMREH_LONGSCROLL_SEED_{run_nonce}"
    owned_runtime: str | None = None
    probe: Probe | None = None
    ws = None

    async with authenticated(credentials, evidence, base=base, origin=base) as (client, ticket):
        try:
            ws = await connect(f"{ws_base}/api/ws?ticket={ticket}", origin=base, proxy=None)
            ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("stock gateway did not become ready")
            probe = Probe(ws, client, {"frames": []})
            created = await probe.rpc("session.create", {
                "profile": PROFILE,
                "cwd": str(tools_cwd),
                "model": "semreh-fixture",
                "provider": "custom",
                "reasoning_effort": "low",
            })
            if not isinstance(created, dict):
                raise RuntimeError("stock session.create returned no object")
            owned_runtime = created.get("session_id")
            stored_id = created.get("stored_session_id")
            if not isinstance(owned_runtime, str) or not owned_runtime:
                raise RuntimeError("stock session.create omitted runtime identity")
            if not isinstance(stored_id, str) or not STORED_ID.fullmatch(stored_id):
                raise RuntimeError("stock session.create omitted a bounded durable identity")

            for prompt in prompts:
                start = len(probe.frames)
                accepted = await probe.rpc("prompt.submit", {
                    "session_id": owned_runtime,
                    "text": prompt,
                })
                if not isinstance(accepted, dict) or accepted.get("status") not in ("streaming", "queued"):
                    raise RuntimeError("stock long-scroll prompt was not accepted")
                await probe.wait_terminal(owned_runtime, start)
                await probe.wait_idle(owned_runtime)

            rows = await _canonical_rows(client, stored_id)
            _validate_canonical_rows(rows, prompts, stored_id)
            evidence.update({
                "seed_source": "JSON-RPC session.create + prompt.submit",
                "canonical_readback": "authenticated oldest-order REST messages",
                "turn_count": turns,
                "canonical_row_count": len(rows),
                "canonical_pairs_exact": True,
                "canonical_row_ids_unique": True,
                "canonical_rows_sha256": _canonical_digest(rows),
                "run_marker_prefix": prefix,
            })
            return stored_id, prefix
        finally:
            if probe is not None and owned_runtime is not None:
                try:
                    closed = await probe.rpc("session.close", {"session_id": owned_runtime})
                    if not isinstance(closed, dict) or closed.get("closed") is not True:
                        evidence.setdefault("cleanup_errors", []).append("session.close not confirmed")
                except Exception as error:  # report cleanup without retaining raw wire data
                    evidence.setdefault("cleanup_errors", []).append(type(error).__name__)
            if ws is not None:
                await ws.close()


async def _run(output: Path, turns: int, approval_secret_fixture: bool = False) -> None:
    _assert_approved_target()
    stock_probe.validate()
    # Reuse only the already approved, digest-pinned blocking fixture when
    # explicitly selected. This validates existing files; it installs nothing.
    stock_probe._validate_plugin_config(approval_secret_fixture=approval_secret_fixture)
    stock_probe._validate_runtime_plugins(approval_secret_fixture=approval_secret_fixture)
    stock_probe._validate_runtime_skill(approval_secret_fixture=approval_secret_fixture)
    config_hash_before = _stock_config_hash()
    credentials = json.loads((EXPECTED_RUNTIME / "credentials.json").read_text(encoding="utf-8"))
    evidence = {
        "sanitized": True,
        "outcome": "failed",
        "source_pin": EXPECTED_SOURCE_PIN,
        "deployment": EXPECTED_ORIGIN,
        "profile": PROFILE,
        "turn_count": turns,
        "maximum_turn_count": MAX_TURNS,
        "maximum_transcript_rows": MAX_TRANSCRIPT_ROWS,
        "approved_blocking_fixture": approval_secret_fixture,
        "config_sha256_before": config_hash_before,
        "cleanup_errors": [],
    }
    try:
        stored_id, marker_prefix = await _seed(credentials, turns, evidence)
        config_hash_after = _stock_config_hash()
        evidence["config_sha256_after"] = config_hash_after
        evidence["configuration_unchanged"] = config_hash_after == config_hash_before
        if config_hash_after != config_hash_before:
            raise RuntimeError("fixture configuration changed during the long-scroll seed")
        if evidence["cleanup_errors"]:
            raise RuntimeError("owned long-scroll runtime cleanup was not confirmed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError(f"Long-scroll seed failed; sanitized evidence retained at {output}") from None

    write_fixture(output, evidence)
    output.chmod(0o600)
    print(json.dumps({
        "outcome": "passed",
        "seed_source": evidence["seed_source"],
        "stored_session_id": stored_id,
        "turn_count": turns,
        "canonical_row_count": evidence["canonical_row_count"],
        "run_marker_prefix": marker_prefix,
        "evidence": str(output),
    }, sort_keys=True))


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--seed-longscroll", action="store_true")
    parser.add_argument("--approval-secret-fixture", action="store_true")
    parser.add_argument("--turns", type=_parse_turn_count, default=DEFAULT_TURNS)
    args = parser.parse_args(argv)
    if not args.seed_longscroll:
        parser.error("fixture creation requires explicit --seed-longscroll opt-in")
    return args


def main(argv: list[str] | None = None) -> None:
    args = _parse_args(argv)
    output = _output_path(args.output)
    asyncio.run(_run(output, args.turns, args.approval_secret_fixture))


if __name__ == "__main__":
    main()
