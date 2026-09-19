#!/usr/bin/env python3
"""Guarded stock ``prompt.btw`` probe against the disposable localhost model."""

from __future__ import annotations

import argparse
import asyncio
import json
import time
from pathlib import Path

from websockets.asyncio.client import connect

from direct_hermes_capture import write_fixture
import direct_hermes_probe as stock_probe
from direct_hermes_identity_probe import _config_hash, assert_rows, authenticated, binding, page
from direct_hermes_reasoning_probe import PROFILE, RPC_TIMEOUT, Probe, _json_frame, _output_path

MAIN_PROMPT = "SEMREH_BTW_CONTEXT"
BTW_QUESTION = "What was the fixture context marker?"
EXPECTED_ANSWER = "SEMREH_SLICE1_ACK"


def _assert_local_btw_routes(runtime: Path) -> None:
    """Fail closed unless main, fork, and one-shot fallback all stay localhost."""
    path = runtime / "home" / "config.yaml"
    if path.is_symlink() or path.resolve() != path or not path.is_file():
        raise RuntimeError("Unexpected disposable config path")
    config = json.loads(path.read_text(encoding="utf-8"))
    if config.get("model") != {
        "provider": "custom", "default": "semreh-fixture",
        "base_url": "http://127.0.0.1:18792/v1",
    }:
        raise RuntimeError("Disposable main model route drifted")
    # side_question.py inherits the live parent's runtime when this task entry
    # is absent; its fork failure fallback receives that same main_runtime.
    auxiliary = config.get("auxiliary")
    if auxiliary != {"background_review": {"enabled": False}}:
        raise RuntimeError("Disposable auxiliary routing drifted")
    if any(config.get(key) for key in ("providers", "custom_providers")):
        raise RuntimeError("Disposable config contains an alternate provider route")
    nested_configs = [candidate for candidate in (runtime / "home").rglob("config.yaml")
                      if candidate != path]
    if nested_configs:
        raise RuntimeError("Disposable profile contains an unguarded config override")


async def _wait_btw(probe: Probe, session_id: str, task_id: str, start: int) -> dict:
    deadline = time.monotonic() + 30.0
    while True:
        for frame in probe.frames[start:]:
            params = frame.get("params") or {}
            payload = params.get("payload") or {}
            if (params.get("type") == "btw.complete"
                    and params.get("session_id") == session_id
                    and payload.get("task_id") == task_id):
                if payload.get("question") != BTW_QUESTION:
                    raise AssertionError("correlated BTW question changed")
                if payload.get("text") != EXPECTED_ANSWER:
                    raise AssertionError("deterministic BTW answer changed or failed")
                return frame
        await probe.receive(deadline)


async def _exercise(credentials: dict, evidence: dict) -> None:
    runtime_id = None
    async with authenticated(credentials, evidence, base=stock_probe.HTTPS_ORIGIN,
                             origin=stock_probe.HTTPS_ORIGIN) as (client, ticket):
        ws_base = stock_probe.HTTPS_ORIGIN.replace("https://", "wss://")
        async with connect(f"{ws_base}/api/ws?ticket={ticket}",
                           origin=stock_probe.HTTPS_ORIGIN, proxy=None) as ws:
            ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("expected gateway.ready")
            probe = Probe(ws, client, {"frames": []})
            try:
                created = await probe.rpc("session.create", {
                    "profile": PROFILE, "cwd": str(stock_probe.RUNTIME / "tools"),
                    "model": "semreh-fixture", "provider": "custom",
                })
                runtime_id, stored_id = binding(created)
                start = len(probe.frames)
                await probe.rpc("prompt.submit", {"session_id": runtime_id, "text": MAIN_PROMPT})
                await probe.wait_terminal(runtime_id, start)
                await probe.wait_idle(runtime_id)
                before = await page(client, stored_id, 100, 0)
                assert_rows(before, [MAIN_PROMPT])

                btw_start = len(probe.frames)
                result = await probe.rpc("prompt.btw", {
                    "session_id": runtime_id, "text": BTW_QUESTION,
                })
                task_id = result.get("task_id") if isinstance(result, dict) else None
                if not isinstance(task_id, str) or not task_id.startswith("btw_"):
                    raise AssertionError("prompt.btw did not return a bounded task identity")
                await _wait_btw(probe, runtime_id, task_id, btw_start)
                after = await page(client, stored_id, 100, 0)
                if after != before:
                    raise AssertionError("prompt.btw mutated the canonical transcript")
                evidence["assertions"] = {
                    "main_turn_durable": True,
                    "btw_ack_correlated_by_session_and_task": True,
                    "deterministic_local_answer_exact": True,
                    "canonical_transcript_unchanged": True,
                    "main_fork_and_fallback_routes_guarded_local": True,
                    "tools_or_personal_provider_not_claimed": True,
                }
            finally:
                if runtime_id is not None:
                    closed = await probe.rpc("session.close", {"session_id": runtime_id})
                    if closed.get("closed") is not True:
                        raise AssertionError("owned runtime close was not confirmed")


async def _run(output: Path) -> None:
    stock_probe.validate()
    _assert_local_btw_routes(stock_probe.RUNTIME)
    config_before = _config_hash(stock_probe.RUNTIME)
    credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text(encoding="utf-8"))
    evidence = {
        "sanitized": True, "backend_sha": stock_probe.PIN,
        "deployment": stock_probe.HTTPS_ORIGIN,
        "provider": "deterministic localhost fixture; NOT external-provider proof",
    }
    try:
        await _exercise(credentials, evidence)
        config_after = _config_hash(stock_probe.RUNTIME)
        evidence["config_sha256_before"] = config_before
        evidence["config_sha256_after"] = config_after
        if config_after != config_before:
            raise AssertionError("disposable config changed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["outcome"] = "failed"
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError(f"BTW probe failed; sanitized evidence retained at {output}") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"BTW assertions passed; sanitized evidence: {output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stock-backend", action="store_true", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    asyncio.run(_run(_output_path(args.output)))


if __name__ == "__main__":
    main()
