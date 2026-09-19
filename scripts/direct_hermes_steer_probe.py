#!/usr/bin/env python3
"""Bounded live ``session.steer`` probe for the disposable Slice 2 backend.

This proves the pinned gateway's real queued-steer path: a warmed agent accepts
steering while a deterministic provider request is delayed, the original turn
still completes normally, and a leftover steer is delivered as exactly one
follow-up turn.  The local fixture has no tool-producing route, so this does
not prove in-place tool-result consumption.  The backend's accepted steer
boolean is intentionally reported as wire status ``queued``; this probe does
not claim the unused native ``SteerOutcome.accepted`` enum case.
"""

from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path

from websockets.asyncio.client import connect

from direct_hermes_capture import write_fixture
import direct_hermes_probe as stock_probe
from direct_hermes_identity_probe import (
    STOCK_PIN,
    ProbeFixture,
    _config_hash,
    assert_rows,
    authenticated,
    binding,
    page,
    select_fixture,
)
from direct_hermes_reasoning_probe import (
    PROFILE,
    RPC_TIMEOUT,
    Probe,
    _validate_all,
    _json_frame,
    _row_text,
    _output_path,
)


WARMUP_PROMPT = "SEMREH_STEER_WARMUP"
ORIGINAL_PROMPT = "SEMREH_INTERRUPT_FIXTURE SEMREH_STEER_ORIGINAL"
STEER_PROMPT = "SEMREH_STEER_QUEUED"


def _assert_durable_rows(
    rows: list[dict], expected_users: list[str], *, require_steer: bool = False
) -> None:
    """Use the shared row contract; require the steer only on the final read."""
    assert_rows(rows, expected_users)
    if require_steer and [_row_text(row) for row in rows[::2]].count(STEER_PROMPT) != 1:
        raise AssertionError("steer correction was not durable exactly once")


async def _wait_normal_terminal(probe: Probe, session_id: str, start: int) -> int:
    """Wait for one complete event and return that event's next frame cursor."""
    frame = await probe.wait_terminal(session_id, start)
    payload = (frame.get("params") or {}).get("payload") or {}
    if payload.get("status") != "complete":
        raise AssertionError("steer fixture turn did not complete normally")
    for index in range(start, len(probe.frames)):
        if probe.frames[index] is frame:
            return index + 1
    raise AssertionError("terminal frame was not retained in the probe buffer")


async def _close_owned(
    probe: Probe | None, owned_runtime_ids: set[str], cleanup_errors: list[dict[str, str]]
) -> None:
    """Close only probe-created runtimes while the owning WebSocket is open."""
    if probe is None:
        return
    for owned_id in sorted(owned_runtime_ids):
        try:
            closed = await probe.rpc("session.close", {"session_id": owned_id})
            if closed.get("closed") is not True:
                raise AssertionError("owned runtime close was not confirmed")
        except Exception as error:
            cleanup_errors.append(
                {"operation": "session.close", "type": type(error).__name__}
            )


async def _exercise(credentials: dict, evidence: dict, fixture: ProbeFixture) -> None:
    evidence["phase"] = "authentication"
    evidence.setdefault("cleanup_errors", [])

    async with authenticated(
        credentials, evidence, base=fixture.base, origin=fixture.origin
    ) as (client, ticket):
        async with connect(
            f"{fixture.ws_base}/api/ws?ticket={ticket}",
            origin=fixture.origin,
            proxy=None,
        ) as ws:
            ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("expected gateway.ready from disposable backend")

            # Keep frames available for bounded terminal matching, but never
            # persist them: some gateway methods can carry system prompts.
            probe = Probe(ws, client, {"frames": []})
            owned_runtime_ids: set[str] = set()
            try:
                evidence["phase"] = "create and warmup"
                created = await probe.rpc(
                    "session.create",
                    {
                        "profile": PROFILE,
                        "cwd": str(fixture.tools_cwd),
                        "model": "gpt-5",
                        "provider": "custom",
                    },
                )
                runtime_id, stored_id = binding(created)
                owned_runtime_ids.add(runtime_id)
                evidence["sessions"] = {
                    "stored_id": stored_id,
                    "created_runtime_id": runtime_id,
                }

                warm_start = len(probe.frames)
                await probe.rpc(
                    "prompt.submit", {"session_id": runtime_id, "text": WARMUP_PROMPT}
                )
                await _wait_normal_terminal(probe, runtime_id, warm_start)
                await probe.wait_idle(runtime_id)
                warm_rows = await page(client, stored_id, 100, 0)
                _assert_durable_rows(warm_rows, [WARMUP_PROMPT])

                evidence["phase"] = "delayed original plus queued steer"
                original_start = len(probe.frames)
                await probe.rpc(
                    "prompt.submit", {"session_id": runtime_id, "text": ORIGINAL_PROMPT}
                )
                await probe.wait_running(runtime_id)

                steer_result = await probe.rpc(
                    "session.steer",
                    {"session_id": runtime_id, "profile": PROFILE, "text": STEER_PROMPT},
                )
                if steer_result.get("status") != "queued":
                    raise AssertionError(
                        "pinned session.steer acceptance must be reported as queued"
                    )
                if steer_result.get("text") != STEER_PROMPT:
                    raise AssertionError("session.steer acknowledgement changed its text")

                # The steer must not interrupt the delayed original. The first
                # complete event is the original turn; the second is the
                # leftover-steer follow-up requeued by the gateway finalizer.
                next_start = await _wait_normal_terminal(
                    probe, runtime_id, original_start
                )
                await _wait_normal_terminal(probe, runtime_id, next_start)
                await probe.wait_idle(runtime_id)
                rows = await page(client, stored_id, 100, 0)
                _assert_durable_rows(
                    rows,
                    [WARMUP_PROMPT, ORIGINAL_PROMPT, STEER_PROMPT],
                    require_steer=True,
                )

                evidence["assertions"] = {
                    "warmed_agent_before_steer": True,
                    "session_steer_wire_status_queued": True,
                    "original_turn_completed_normally": True,
                    "leftover_steer_followup_completed_normally": True,
                    "durable_user_assistant_order_exact": True,
                    "steer_correction_durable_once": True,
                    "accepted_enum_wire_status_not_claimed": True,
                    "in_place_tool_result_consumption_not_claimed": True,
                }
            finally:
                # The gateway close RPC must run before this WebSocket context
                # exits; durable rows remain after the runtime is closed.
                await _close_owned(probe, owned_runtime_ids, evidence["cleanup_errors"])

    if evidence["cleanup_errors"]:
        raise AssertionError("probe cleanup did not fully close its owned runtime")


def _persist_failure(output: Path, evidence: dict) -> None:
    # WebSocket frames are intentionally kept only in memory for matching.
    evidence.pop("frames", None)
    write_fixture(output, evidence)
    output.chmod(0o600)


async def _run(output: Path, backend_sha: str | None = None, *, stock_backend: bool = False) -> None:
    fixture = select_fixture(stock_backend=stock_backend, backend_sha=backend_sha)
    if fixture.stock:
        stock_probe.validate()
    else:
        _validate_all(fixture.backend_sha)
    credentials = json.loads((fixture.runtime / "credentials.json").read_text(encoding="utf-8"))
    config_before = _config_hash(fixture.runtime)
    evidence = {
        "configured_source_pin": STOCK_PIN,
        "backend_sha": fixture.backend_sha,
        "deployment": fixture.origin,
        "provider": "deterministic localhost fixture; NOT external-provider proof",
        "profile": PROFILE,
        "sanitized": True,
        "frames": [],
        "not_verified": [
            "SteerOutcome.accepted wire status (pinned backend maps acceptance to queued)",
            "in-place tool-result steer consumption (fixture has no tool-producing route)",
            "literal TUI/Desktop UI use",
        ],
    }
    try:
        await _exercise(credentials, evidence, fixture)
        config_after = _config_hash(fixture.runtime)
        evidence["config_sha256_before"] = config_before
        evidence["config_sha256_after"] = config_after
        if config_before != config_after:
            raise AssertionError("global fixture config changed during steer probe")
        evidence["global_config_unchanged"] = True
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["outcome"] = "failed"
        evidence["error_type"] = type(error).__name__
        try:
            evidence["config_sha256_before"] = config_before
            evidence["config_sha256_after"] = _config_hash(fixture.runtime)
            evidence["global_config_unchanged"] = (
                evidence["config_sha256_before"] == evidence["config_sha256_after"]
            )
        except Exception:
            pass
        _persist_failure(output, evidence)
        raise RuntimeError(f"Steer probe failed; sanitized evidence retained at {output}") from None

    _persist_failure(output, evidence)
    print(f"Queued steer assertions passed; sanitized evidence: {output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    backend = parser.add_mutually_exclusive_group(required=True)
    backend.add_argument("--backend-sha")
    backend.add_argument("--stock-backend", action="store_true")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    asyncio.run(_run(_output_path(args.output), args.backend_sha, stock_backend=args.stock_backend))


if __name__ == "__main__":
    main()
