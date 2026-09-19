#!/usr/bin/env python3
"""Create one disposable durable seed for the opt-in app relaunch gate.

This is a JSON-RPC-created stock session, not a TUI or app-launch claim.  The
session remains durable after this helper closes its owned runtime so the UI
test can reopen it through the normal production deep link.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import re
from pathlib import Path

from websockets.asyncio.client import connect

import direct_hermes_probe as stock_probe
from direct_hermes_capture import write_fixture
from direct_hermes_identity_probe import authenticated, _rest_rows, _row_text
from direct_hermes_reasoning_probe import (
    EVIDENCE_ROOT, PROFILE, Probe, RPC_TIMEOUT, _json_frame, _output_path,
)


SEED_PREFIX = "SEMREH_SLICE3_APP_RELAUNCH_SEED_"
ACK = "SEMREH_SLICE1_ACK"
SAFE_TEXT = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\Z")
STORED_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
RELAUNCH_PROMPT = re.compile(r"SEMREH_SLICE3_RELAUNCH_[A-Fa-f0-9-]{36}\Z")
APP_KILL_PROMPT = re.compile(
    r"SEMREH_INTERRUPT_FIXTURE SEMREH_SLICE3_APP_KILL_[A-Fa-f0-9-]{36}\Z"
)


def _validate_seed_text(raw: str) -> str:
    if not SAFE_TEXT.fullmatch(raw):
        raise ValueError("seed text must be a bounded synthetic marker")
    return raw


def _canonical_digest(rows: list[dict]) -> str:
    encoded = json.dumps(rows, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(encoded).hexdigest()


def _load_seed_evidence(path: Path) -> dict:
    if (
        not path.is_absolute()
        or path.is_symlink()
        or path.resolve() != path
        or path.parent.resolve() != EVIDENCE_ROOT.resolve()
        or not path.is_file()
    ):
        raise RuntimeError("seed evidence must be an ordinary retained file")
    try:
        evidence = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RuntimeError("seed evidence is not valid JSON") from error
    if (
        not isinstance(evidence, dict)
        or evidence.get("sanitized") is not True
        or evidence.get("outcome") != "passed"
        or evidence.get("source_pin") != stock_probe.PIN
        or evidence.get("seed_source") != "JSON-RPC session.create + prompt.submit"
        or evidence.get("canonical_baseline_rows") != 2
        or evidence.get("canonical_baseline_exact") is not True
        or not isinstance(evidence.get("baseline_rows_sha256"), str)
        or not SAFE_TEXT.fullmatch(str(evidence.get("seed_text", "")))
    ):
        raise RuntimeError("seed evidence does not describe the approved JSON-RPC baseline")
    return evidence


async def _seed(credentials: dict, seed_text: str, evidence: dict) -> tuple[str, str]:
    base = stock_probe.HTTPS_ORIGIN
    ws_base = base.replace("https://", "wss://")
    runtime_path = stock_probe.RUNTIME / "tools"
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
                "cwd": str(runtime_path),
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

            start = len(probe.frames)
            accepted = await probe.rpc("prompt.submit", {
                "session_id": owned_runtime,
                "text": seed_text,
            })
            if not isinstance(accepted, dict) or accepted.get("status") not in ("streaming", "queued"):
                raise RuntimeError("stock seed prompt was not accepted")
            await probe.wait_terminal(owned_runtime, start)
            await probe.wait_idle(owned_runtime)

            response = await client.get(
                f"/api/sessions/{stored_id}/messages",
                params={
                    "profile": PROFILE,
                    "include_compacted": "true",
                    "order": "oldest",
                    "limit": 20,
                    "offset": 0,
                },
            )
            response.raise_for_status()
            payload = response.json()
            if payload.get("session_id") != stored_id:
                raise RuntimeError("seed canonical REST response did not match its durable session")
            rows = _rest_rows(payload)
            if len(rows) != 2 or [row.get("role") for row in rows] != ["user", "assistant"]:
                raise RuntimeError("stock seed did not create exactly one user/assistant pair")
            if _row_text(rows[0]) != seed_text or _row_text(rows[1]) != ACK:
                raise RuntimeError("stock seed canonical transcript did not match the fixture contract")
            evidence.update({
                "seed_source": "JSON-RPC session.create + prompt.submit",
                "canonical_baseline_rows": 2,
                "canonical_baseline_exact": True,
                "baseline_rows_sha256": _canonical_digest(rows),
                "seed_acknowledgement_count": 1,
            })
            return stored_id, seed_text
        finally:
            if probe is not None and owned_runtime is not None:
                try:
                    closed = await probe.rpc("session.close", {"session_id": owned_runtime})
                    if not isinstance(closed, dict) or closed.get("closed") is not True:
                        evidence.setdefault("cleanup_errors", []).append("session.close not confirmed")
                except Exception as error:  # cleanup is reported without leaking wire data
                    evidence.setdefault("cleanup_errors", []).append(type(error).__name__)
            if ws is not None:
                await ws.close()


async def _verify(credentials: dict, stored_id: str, seed_evidence: dict, evidence: dict,
                  expected_app_kill: bool = False) -> None:
    base = stock_probe.HTTPS_ORIGIN
    expected_seed = seed_evidence["seed_text"]
    async with authenticated(credentials, evidence, base=base, origin=base) as (client, _ticket):
        response = await client.get(
            f"/api/sessions/{stored_id}/messages",
            params={
                "profile": PROFILE,
                "include_compacted": "true",
                "order": "oldest",
                "limit": 20,
                "offset": 0,
            },
        )
        response.raise_for_status()
        payload = response.json()
        if payload.get("session_id") != stored_id:
            raise RuntimeError("canonical REST response did not match the requested durable session")
        rows = _rest_rows(payload)
        if len(rows) != 4 or [row.get("role") for row in rows] != ["user", "assistant", "user", "assistant"]:
            raise RuntimeError("relaunch canonical transcript did not contain exactly two user/assistant pairs")
        baseline_match = _canonical_digest(rows[:2]) == seed_evidence["baseline_rows_sha256"]
        if not baseline_match or _row_text(rows[0]) != expected_seed or _row_text(rows[1]) != ACK:
            raise RuntimeError("relaunch canonical transcript changed its seeded prefix")
        follow_up = _row_text(rows[2])
        prompt_pattern = APP_KILL_PROMPT if expected_app_kill else RELAUNCH_PROMPT
        if not prompt_pattern.fullmatch(follow_up) or _row_text(rows[3]) != ACK:
            raise RuntimeError("relaunch canonical follow-up was not one exact fixture turn")
        evidence.update({
            "verification_source": "authenticated canonical REST messages",
            "stored_session_id_shape_valid": True,
            "canonical_session_id_match": True,
            "canonical_row_count": len(rows),
            "baseline_prefix_hash_match": True,
            "exact_user_assistant_pairs": 2,
            "follow_up_prompt_shape_valid": True,
            "follow_up_ack_exact": True,
            "no_extra_prompt": True,
        })


async def _run(output: Path, seed_text: str | None, verify_session_id: str | None,
               seed_evidence_path: Path | None, verify_app_kill: bool = False) -> None:
    stock_probe.validate()
    credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text(encoding="utf-8"))
    evidence = {
        "sanitized": True,
        "outcome": "failed",
        "source_pin": stock_probe.PIN,
        "deployment": stock_probe.HTTPS_ORIGIN,
        "cleanup_errors": [],
        "seed_text": seed_text,
        "not_verified": ["XCUIApplication termination/relaunch", "canonical post-relaunch send"],
    }
    try:
        if verify_session_id is not None:
            seed_evidence = _load_seed_evidence(seed_evidence_path)  # type: ignore[arg-type]
            await _verify(credentials, verify_session_id, seed_evidence, evidence, verify_app_kill)
            stored_id = verify_session_id
            marker = seed_evidence["seed_text"]
            evidence["not_verified"] = ["XCUIApplication termination/relaunch process-death attribution"]
        else:
            stored_id, marker = await _seed(credentials, seed_text, evidence)  # type: ignore[arg-type]
        evidence["seed_text"] = marker
        if evidence["cleanup_errors"]:
            raise RuntimeError("owned seed runtime cleanup was not confirmed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError(f"Relaunch seed failed; sanitized evidence retained at {output}") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    # The ID is needed to construct the production deep link. It is a
    # disposable session identifier, not authentication material or a raw RPC.
    print(json.dumps({
        "outcome": "passed",
        "seed_source": evidence.get("seed_source", evidence.get("verification_source")),
        "stored_session_id": stored_id,
        "seed_text": marker,
        "evidence": str(output),
    }, sort_keys=True))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--seed-text", default=SEED_PREFIX + "FIXTURE")
    parser.add_argument("--verify-session-id")
    parser.add_argument("--seed-evidence")
    parser.add_argument("--verify-app-kill", action="store_true")
    args = parser.parse_args()
    try:
        if args.verify_session_id:
            if not STORED_ID.fullmatch(args.verify_session_id):
                raise ValueError("verify session ID is not a bounded durable identifier")
            if not args.seed_evidence:
                raise ValueError("--verify-session-id requires --seed-evidence")
            if args.seed_text != SEED_PREFIX + "FIXTURE":
                raise ValueError("--verify-session-id cannot be combined with --seed-text")
            seed_text = None
            seed_evidence = Path(args.seed_evidence)
        else:
            if args.seed_evidence or args.verify_app_kill:
                raise ValueError("--seed-evidence and --verify-app-kill require --verify-session-id")
            seed_text = _validate_seed_text(args.seed_text)
            seed_evidence = None
        output = _output_path(args.output)
        asyncio.run(_run(output, seed_text, args.verify_session_id, seed_evidence, args.verify_app_kill))
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
