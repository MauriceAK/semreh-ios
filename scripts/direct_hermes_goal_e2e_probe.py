#!/usr/bin/env python3
"""Bounded two-turn /goal proof against the owned deterministic gateway."""

from __future__ import annotations
import argparse, asyncio, hashlib, json, re, time, uuid
from pathlib import Path
from websockets.asyncio.client import connect

from direct_hermes_capture import write_fixture
import direct_hermes_probe as stock
from direct_hermes_goal_live_probe import _backend_guard, _matches, _meta
from direct_hermes_identity_probe import authenticated, binding
from direct_hermes_reasoning_probe import Probe, RPC_TIMEOUT, _json_frame, _output_path

PROFILE = "default"
GOAL_PREFIX = "SEMREH_GOAL_E2E_TWO_TURN_"
STEP_1 = "SEMREH_GOAL_E2E_STEP_1"
STEP_2 = "SEMREH_GOAL_E2E_STEP_2"
EXPECTED_JUDGE = {
    "provider": "custom", "model": "semreh-fixture",
    "base_url": "http://127.0.0.1:18792/v1", "api_key": "no-key-required",
    "api_mode": "chat_completions", "timeout": 5, "max_tokens": 128,
    "fallback_chain": [],
}


def _config_preflight(pid: int, expected_sha: str) -> None:
    stock.validate(); _backend_guard(pid)
    stock._validate_runtime_plugins(approval_secret_fixture=True)
    stock._validate_plugin_config(approval_secret_fixture=True)
    stock._validate_runtime_skill(approval_secret_fixture=True)
    path = stock.RUNTIME / "home/config.yaml"
    if not re.fullmatch(r"[0-9a-f]{64}", expected_sha):
        raise RuntimeError("Expected config SHA must be lowercase SHA-256")
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected_sha:
        raise RuntimeError("Disposable config SHA drifted")
    config = json.loads(path.read_text())
    auxiliary = config.get("auxiliary")
    if not isinstance(auxiliary, dict) or auxiliary.get("transient_retries") != 0:
        raise RuntimeError("Auxiliary retry policy is not bounded to zero")
    if auxiliary.get("goal_judge") != EXPECTED_JUDGE:
        raise RuntimeError("Goal judge is not exactly pinned to the local fixture")
    if config.get("model") != {"provider": "custom", "default": "semreh-fixture",
                                "base_url": "http://127.0.0.1:18792/v1"}:
        raise RuntimeError("Main model is not exactly pinned to the local fixture")


def _config_sha() -> str:
    return hashlib.sha256((stock.RUNTIME / "home/config.yaml").read_bytes()).hexdigest()


def _rows(payload: dict) -> list[tuple[str, str]]:
    messages = payload.get("messages")
    if not isinstance(messages, list):
        raise RuntimeError("Canonical transcript has no messages")
    return [(str(row.get("role")), str(row.get("content") or row.get("display_content") or ""))
            for row in messages if isinstance(row, dict)]


def _completion_count(frames: list[dict], runtime_id: str) -> int:
    return sum(1 for frame in frames
               if (frame.get("params") or {}).get("type") == "message.complete"
               and (frame.get("params") or {}).get("session_id") == runtime_id)


async def _messages(client, stored_id: str) -> list[tuple[str, str]]:
    response = await client.get(f"/api/sessions/{stored_id}/messages", params={
        "profile": PROFILE, "include_compacted": "true", "order": "oldest",
        "limit": 20, "offset": 0})
    response.raise_for_status()
    return _rows(response.json())


async def _exercise(credentials: dict, evidence: dict) -> None:
    marker = GOAL_PREFIX + uuid.uuid4().hex[:12]
    runtime_id = None; goal_dispatch_attempted = False
    async with authenticated(credentials, evidence, base=stock.HTTPS_ORIGIN,
                             origin=stock.HTTPS_ORIGIN) as (client, ticket):
        active_response = await client.get("/api/profiles/active")
        active_response.raise_for_status()
        active = active_response.json()
        if not isinstance(active, dict) or active.get("active") != PROFILE or active.get("current") != PROFILE:
            raise RuntimeError("Gateway active/current profile is not default")
        ws_base = stock.HTTPS_ORIGIN.replace("https://", "wss://")
        async with connect(f"{ws_base}/api/ws?ticket={ticket}", origin=stock.HTTPS_ORIGIN,
                           proxy=None) as ws:
            ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("gateway.ready missing")
            probe = Probe(ws, client, {"frames": []})
            created = await probe.rpc("session.create", {"profile": PROFILE,
                "cwd": str(stock.RUNTIME / "tools"), "model": "semreh-fixture",
                "provider": "custom"})
            runtime_id, stored_id = binding(created); key = "goal:" + stored_id
            try:
                goal_dispatch_attempted = True
                kickoff = await probe.rpc("command.dispatch", {
                    "session_id": runtime_id, "name": "goal", "arg": marker})
                if (kickoff.get("type") != "send" or kickoff.get("message") != marker
                        or not _matches(_meta(stock.RUNTIME / "home/state.db", key), marker, "active")):
                    raise AssertionError("Goal kickoff receipt/state changed")
                accepted = await probe.rpc("prompt.submit", {
                    "session_id": runtime_id, "text": kickoff["message"]})
                if not isinstance(accepted, dict) or accepted.get("status") != "streaming":
                    raise AssertionError("Goal kickoff was not accepted as streaming")
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    state = _meta(stock.RUNTIME / "home/state.db", key)
                    complete_count = _completion_count(probe.frames, runtime_id)
                    if _matches(state, marker, "done") and complete_count >= 2:
                        break
                    try:
                        await probe.receive(min(deadline, time.monotonic() + 0.5))
                    except TimeoutError:
                        pass
                else:
                    raise TimeoutError("Two-turn goal did not finish within bounded deadline")
                raw_state = json.loads(_meta(stock.RUNTIME / "home/state.db", key) or "{}")
                if raw_state.get("turns_used") != 2 or raw_state.get("status") != "done":
                    raise AssertionError("Goal did not finish in exactly two judged turns")
                rows = await _messages(client, stored_id)
                if ([role for role, _ in rows] != ["user", "assistant", "user", "assistant"]
                        or rows[0][1] != marker or STEP_1 not in rows[1][1]
                        or marker not in rows[2][1] or not rows[2][1].startswith("[Continuing toward your standing goal]")
                        or STEP_2 not in rows[3][1]):
                    raise AssertionError("Canonical two-turn goal transcript changed")
                await asyncio.sleep(0.5)
                if len(await _messages(client, stored_id)) != 4:
                    raise AssertionError("Unexpected third goal turn was scheduled")
                evidence["assertions"] = {"default_profile": True, "one_prompt_submit": True,
                    "two_main_turns": True, "two_judged_turns_inferred_from_state": True, "goal_done": True,
                    "no_third_turn": True, "canonical_four_rows": True,
                    "local_judge_route_pinned": True}
            finally:
                try:
                    owned_goal = _meta(stock.RUNTIME / "home/state.db", key)
                    if goal_dispatch_attempted and any(
                            _matches(owned_goal, marker, status)
                            for status in ("active", "paused", "done")):
                        cleared = await probe.rpc("command.dispatch", {
                            "session_id": runtime_id, "name": "goal", "arg": "clear"})
                        if (cleared.get("type") != "exec"
                                or not _matches(_meta(stock.RUNTIME / "home/state.db", key), marker, "cleared")):
                            raise AssertionError("Owned goal clear not confirmed")
                finally:
                    if runtime_id:
                        closed = await probe.rpc("session.close", {"session_id": runtime_id})
                        if closed.get("closed") is not True:
                            raise AssertionError("Owned runtime close not confirmed")


async def _run(output: Path, pid: int, config_sha: str) -> None:
    _config_preflight(pid, config_sha)
    credentials = json.loads((stock.RUNTIME / "credentials.json").read_text())
    evidence = {"sanitized": True, "backend_sha": stock.PIN, "cleanup_errors": []}
    try:
        await _exercise(credentials, evidence)
        evidence["config_unchanged_after_cleanup"] = _config_sha() == config_sha
        if evidence["cleanup_errors"] or not evidence["config_unchanged_after_cleanup"]:
            raise AssertionError("Authenticated cleanup/config integrity check failed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["config_unchanged_after_cleanup"] = _config_sha() == config_sha
        evidence["outcome"] = "failed"; evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence); output.chmod(0o600); raise
    write_fixture(output, evidence); output.chmod(0o600)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stock-backend", action="store_true", required=True)
    parser.add_argument("--expected-backend-pid", type=int, required=True)
    parser.add_argument("--expected-config-sha", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    asyncio.run(_run(_output_path(args.output), args.expected_backend_pid, args.expected_config_sha))


if __name__ == "__main__": main()
