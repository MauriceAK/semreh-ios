#!/usr/bin/env python3
"""Guarded stock ``prompt.background`` probe; never external-provider proof."""

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
from direct_hermes_reasoning_probe import (
    PROFILE, RPC_TIMEOUT, Probe, _json_frame, _output_path, _row_text,
)

EXPECTED_CONFIG_SHA256 = "23079a49d48d26f8299fd41760c917914855e9b410de69d2f0dfcf7100ee6358"
MAIN_PROMPT = "SEMREH_BACKGROUND_PARENT_BASELINE"
BACKGROUND_PROMPTS = (
    "SEMREH_BACKGROUND_TASK_ALPHA Reply with the deterministic fixture acknowledgement.",
    "SEMREH_BACKGROUND_TASK_BETA Reply with the deterministic fixture acknowledgement.",
)
EXPECTED_ANSWER = "SEMREH_SLICE1_ACK"
BACKGROUND_TIMEOUT = 40.0


def _assert_local_background_routes(runtime: Path) -> None:
    path = runtime / "home" / "config.yaml"
    if path.is_symlink() or path.resolve() != path or not path.is_file():
        raise RuntimeError("Unexpected disposable config path")
    if _config_hash(runtime) != EXPECTED_CONFIG_SHA256:
        raise RuntimeError("Disposable config hash drifted")
    config = json.loads(path.read_text(encoding="utf-8"))
    if config.get("model") != {
        "provider": "custom", "default": "semreh-fixture",
        "base_url": "http://127.0.0.1:18792/v1",
    }:
        raise RuntimeError("Disposable local model route drifted")
    if config.get("auxiliary") != {"background_review": {"enabled": False}}:
        raise RuntimeError("Disposable auxiliary policy drifted")
    if config.get("memory") != {
        "memory_enabled": False, "user_profile_enabled": False, "provider": "",
    } or config.get("tools") != {"tool_search": {"enabled": "off"}}:
        raise RuntimeError("Disposable memory/tool-search policy drifted")
    if any(config.get(key) for key in ("providers", "custom_providers")):
        raise RuntimeError("Disposable config contains an alternate provider route")
    nested = [candidate for candidate in (runtime / "home").rglob("config.yaml")
              if candidate != path]
    if nested:
        raise RuntimeError("Disposable profile contains an unguarded config override")


async def _wait_background_completions(
    probe: Probe, session_id: str, task_ids: set[str], start: int,
) -> set[str]:
    matched: dict[str, str] = {}
    deadline = time.monotonic() + BACKGROUND_TIMEOUT
    while set(matched) != task_ids:
        for frame in probe.frames[start:]:
            params = frame.get("params") or {}
            payload = params.get("payload") or {}
            task_id = payload.get("task_id")
            if (params.get("type") == "background.complete"
                    and params.get("session_id") == session_id
                    and task_id in task_ids):
                text = payload.get("text")
                if text != EXPECTED_ANSWER:
                    raise AssertionError("deterministic background answer changed or failed")
                prior = matched.setdefault(task_id, text)
                if prior != text:
                    raise AssertionError("background task produced conflicting completions")
        if set(matched) != task_ids:
            await probe.receive(deadline)
    return set(matched)


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
            # Frames are needed transiently for correlation but never persisted.
            probe = Probe(ws, client, {"frames": []})
            try:
                created = await probe.rpc("session.create", {
                    "profile": PROFILE, "cwd": str(stock_probe.RUNTIME / "tools"),
                    "model": "semreh-fixture", "provider": "custom",
                })
                runtime_id, stored_id = binding(created)
                start = len(probe.frames)
                await probe.rpc("prompt.submit", {
                    "session_id": runtime_id, "text": MAIN_PROMPT,
                })
                await probe.wait_terminal(runtime_id, start)
                await probe.wait_idle(runtime_id)
                before = await page(client, stored_id, 100, 0)
                assert_rows(before, [MAIN_PROMPT])
                if _row_text(before[1]) != EXPECTED_ANSWER:
                    raise AssertionError("deterministic main answer changed")

                event_start = len(probe.frames)
                task_ids: set[str] = set()
                for prompt in BACKGROUND_PROMPTS:
                    result = await probe.rpc("prompt.background", {
                        "session_id": runtime_id, "text": prompt,
                    })
                    task_id = result.get("task_id") if isinstance(result, dict) else None
                    if not isinstance(task_id, str) or not task_id.startswith("bg_"):
                        raise AssertionError("prompt.background returned no bounded task identity")
                    if task_id in task_ids:
                        raise AssertionError("prompt.background reused a task identity")
                    task_ids.add(task_id)
                matched = await _wait_background_completions(
                    probe, runtime_id, task_ids, event_start,
                )
                after = await page(client, stored_id, 100, 0)
                if after != before:
                    raise AssertionError("background tasks mutated the parent transcript")
                evidence["assertions"] = {
                    "main_turn_durable": True,
                    "background_ack_count": len(task_ids),
                    "background_completion_count": len(matched),
                    "all_completions_correlated_by_parent_and_task": matched == task_ids,
                    "deterministic_local_answers_exact": True,
                    "canonical_parent_transcript_unchanged": True,
                    "local_model_and_policy_guarded": True,
                    "tools_files_browser_audio_not_exercised": True,
                }
            finally:
                if runtime_id is not None:
                    closed = await probe.rpc("session.close", {"session_id": runtime_id})
                    if closed.get("closed") is not True:
                        raise AssertionError("owned parent runtime close was not confirmed")


async def _run(output: Path) -> None:
    stock_probe.validate()
    _assert_local_background_routes(stock_probe.RUNTIME)
    config_before = _config_hash(stock_probe.RUNTIME)
    credentials = json.loads(
        (stock_probe.RUNTIME / "credentials.json").read_text(encoding="utf-8")
    )
    evidence = {
        "sanitized": True,
        "backend_sha": stock_probe.PIN,
        "deployment": "owned stock HTTPS fixture",
        "provider": "deterministic localhost fixture; NOT external-provider proof",
        "cleanup_errors": [],
    }
    try:
        await _exercise(credentials, evidence)
        config_after = _config_hash(stock_probe.RUNTIME)
        evidence["config_sha256_before"] = config_before
        evidence["config_sha256_after"] = config_after
        if config_after != config_before or config_after != EXPECTED_CONFIG_SHA256:
            raise AssertionError("disposable config changed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["outcome"] = "failed"
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError(
            f"Background probe failed; sanitized evidence retained at {output}"
        ) from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Background assertions passed; sanitized evidence: {output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stock-backend", action="store_true", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    asyncio.run(_run(_output_path(args.output)))


if __name__ == "__main__":
    main()
