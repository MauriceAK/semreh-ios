#!/usr/bin/env python3
"""Real HTTPS per-session reasoning contract probe for the disposable backend.

The provider is the repository's deterministic localhost model fixture.  This
is protocol/persistence evidence, not an external-provider or model-quality
claim.  Authentication material, cookies, tickets, and config secrets never
enter the evidence object or process output.
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

from direct_hermes_capture import sanitize, write_fixture
from direct_hermes_development import _validate_all, DEV_RUNTIME as RUNTIME
from direct_hermes_probe import HTTPS_ORIGIN, PIN


EVIDENCE_ROOT = Path("/Users/maurice/workspace/semreh-slice1-evidence")
BASE = HTTPS_ORIGIN
WS_BASE = HTTPS_ORIGIN.replace("https://", "wss://")
PROFILE = "default"
TOOLS_CWD = RUNTIME / "tools"
RPC_TIMEOUT = 35.0
TURN_TIMEOUT = 55.0
STATUS_POLL = 0.25


def _output_path(raw: str | None) -> Path:
    if not raw:
        raise RuntimeError("--output is required")
    path = Path(raw)
    if not path.is_absolute() or path.is_symlink():
        raise RuntimeError("--output must be an absolute non-symlink path")
    if path.parent.resolve() != EVIDENCE_ROOT.resolve():
        raise RuntimeError(f"--output must be directly under {EVIDENCE_ROOT}")
    if path.exists():
        raise RuntimeError(f"Refusing to overwrite existing evidence: {path}")
    return path


def _config_hash() -> str:
    path = RUNTIME / "home" / "config.yaml"
    if path.is_symlink() or path.resolve() != path or not path.is_file():
        raise RuntimeError("Unexpected disposable config path")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _json_frame(raw) -> dict:
    try:
        value = json.loads(raw)
    except (TypeError, ValueError) as exc:
        raise RuntimeError("WebSocket returned non-JSON data") from exc
    if not isinstance(value, dict):
        raise RuntimeError("WebSocket returned a non-object frame")
    return value


class Probe:
    def __init__(self, ws, client: httpx.AsyncClient, evidence: dict):
        self.ws = ws
        self.client = client
        self.evidence = evidence
        self.frames = evidence["frames"]
        self.next_id = 1

    async def receive(self, deadline: float) -> dict:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("bounded WebSocket receive deadline expired")
        frame = _json_frame(await asyncio.wait_for(self.ws.recv(), remaining))
        self.frames.append(sanitize(frame))
        return frame

    async def rpc(self, method: str, params: dict, *, timeout: float = RPC_TIMEOUT):
        request_id = self.next_id
        self.next_id += 1
        await self.ws.send(
            json.dumps(
                {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
            )
        )
        deadline = time.monotonic() + timeout
        while True:
            frame = await self.receive(deadline)
            if frame.get("id") != request_id:
                continue
            if "error" in frame:
                raise RuntimeError(
                    f"{method} failed: {json.dumps(sanitize(frame['error']), sort_keys=True)}"
                )
            return frame.get("result")

    async def expect_error(self, method: str, params: dict) -> dict:
        request_id = self.next_id
        self.next_id += 1
        await self.ws.send(
            json.dumps(
                {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
            )
        )
        deadline = time.monotonic() + RPC_TIMEOUT
        while True:
            frame = await self.receive(deadline)
            if frame.get("id") != request_id:
                continue
            if "error" not in frame:
                raise AssertionError(f"{method} unexpectedly succeeded")
            return frame

    async def wait_terminal(self, session_id: str, start: int) -> dict:
        deadline = time.monotonic() + TURN_TIMEOUT
        while True:
            for frame in self.frames[start:]:
                params = frame.get("params") or {}
                if (
                    params.get("type") == "message.complete"
                    and params.get("session_id") == session_id
                ):
                    payload = params.get("payload") or {}
                    if payload.get("status") == "error":
                        raise RuntimeError("deterministic reasoning turn returned an error")
                    return frame
            await self.receive(deadline)

    async def wait_running(self, session_id: str) -> dict:
        deadline = time.monotonic() + 10.0
        while True:
            status = await self.rpc("session.status", {"session_id": session_id})
            if "Agent Running: Yes" in str(status.get("output", "")):
                return status
            if time.monotonic() >= deadline:
                raise AssertionError("delayed fixture turn never became server-running")
            await asyncio.sleep(STATUS_POLL)

    async def wait_idle(self, session_id: str) -> dict:
        deadline = time.monotonic() + TURN_TIMEOUT
        while True:
            status = await self.rpc("session.status", {"session_id": session_id})
            if "Agent Running: No" in str(status.get("output", "")):
                return status
            if time.monotonic() >= deadline:
                raise AssertionError("server remained running past bounded turn deadline")
            await asyncio.sleep(STATUS_POLL)

    async def rest_messages(self, stored_id: str) -> dict:
        response = await self.client.get(
            f"/api/sessions/{stored_id}/messages",
            params={
                "profile": PROFILE,
                "include_compacted": "true",
                "order": "oldest",
                "limit": 100,
                "offset": 0,
            },
        )
        response.raise_for_status()
        payload = response.json()
        if not isinstance(payload, dict):
            raise RuntimeError("profiled REST messages response was not an object")
        return payload


def _rest_rows(payload: dict) -> list[dict]:
    rows = payload.get("messages")
    if rows is None:
        rows = payload.get("data")
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise RuntimeError("profiled REST messages response had no message rows")
    return rows


def _row_text(row: dict) -> str:
    value = row.get("content")
    if isinstance(value, list):
        return " ".join(str(part.get("text", "")) for part in value if isinstance(part, dict))
    return str(value or row.get("display_content") or "")


def _assert_turn_rows(payload: dict, expected_user: list[str], expected_efforts: list[str]) -> None:
    rows = _rest_rows(payload)
    expected_roles = [role for _ in expected_user for role in ("user", "assistant")]
    if [str(row.get("role")) for row in rows] != expected_roles:
        raise AssertionError("durable REST rows did not preserve exact user/assistant order")
    for index, (prompt, effort) in enumerate(zip(expected_user, expected_efforts)):
        user_row, assistant_row = rows[index * 2 : index * 2 + 2]
        if _row_text(user_row) != prompt:
            raise AssertionError("durable REST user prompt order/content changed")
        expected = f"SEMREH_REASONING_EFFORT:{effort}"
        if expected not in _row_text(assistant_row):
            raise AssertionError(f"durable assistant row did not contain {expected}")


def _load_resume_evidence(raw: str, backend_sha: str) -> dict:
    path = Path(raw)
    if not path.is_absolute() or path.is_symlink():
        raise RuntimeError("--resume-from must be an absolute non-symlink path")
    if path.parent.resolve() != EVIDENCE_ROOT.resolve():
        raise RuntimeError(f"--resume-from must be directly under {EVIDENCE_ROOT}")
    if not path.is_file() or path.resolve() != path:
        raise RuntimeError("--resume-from must be an ordinary evidence file")
    try:
        evidence = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RuntimeError("--resume-from is not valid JSON evidence") from error
    if not isinstance(evidence, dict) or evidence.get("sanitized") is not True:
        raise RuntimeError("--resume-from must be marked sanitized")
    if evidence.get("outcome") != "passed":
        raise RuntimeError("--resume-from must have a passed outcome")
    if str(evidence.get("backend_sha") or "").lower() != backend_sha.lower():
        raise RuntimeError("--resume-from backend SHA does not match --backend-sha")
    sessions = evidence.get("sessions")
    if not isinstance(sessions, dict):
        raise RuntimeError("--resume-from has no session evidence")
    for key in ("first_stored_id", "sibling_stored_id"):
        if not isinstance(sessions.get(key), str) or not sessions[key].strip():
            raise RuntimeError(f"--resume-from has no {key}")
    return evidence


def _assert_reasoning_readback(readback: dict, effort: str) -> None:
    if readback.get("value") != effort or readback.get("session_reasoning_contract") != 1:
        raise AssertionError(
            f"config.get did not report {effort} with session reasoning contract 1"
        )


async def _exercise_restart_phase(probe: Probe, evidence: dict, prior: dict) -> None:
    prior_first = [
        "SEMREH_REASONING_PROBE warmup-low",
        "SEMREH_INTERRUPT_FIXTURE SEMREH_REASONING_PROBE delayed-low",
        "SEMREH_REASONING_PROBE subsequent-high",
        "SEMREH_REASONING_PROBE cold-resume-high",
    ]
    prior_first_efforts = ["low", "low", "high", "high"]
    prior_sibling = ["SEMREH_REASONING_PROBE warmup-medium"]
    first_stored = prior["sessions"]["first_stored_id"]
    sibling_stored = prior["sessions"]["sibling_stored_id"]

    evidence["phase"] = "restart resume first session"
    first_resume = await probe.rpc(
        "session.resume", {"session_id": first_stored, "profile": PROFILE}
    )
    first_runtime = first_resume["session_id"]
    evidence["sessions"] = {
        "prior_first_stored_id": first_stored,
        "prior_sibling_stored_id": sibling_stored,
        "resumed_runtime_ids": [],
    }
    evidence["sessions"]["resumed_runtime_ids"].append(first_runtime)
    _assert_turn_rows(await probe.rest_messages(first_stored), prior_first, prior_first_efforts)
    _assert_reasoning_readback(
        await probe.rpc(
            "config.get", {"key": "reasoning", "session_id": first_runtime, "profile": PROFILE}
        ),
        "high",
    )
    restart_first = "SEMREH_REASONING_PROBE restart-high"
    start = len(probe.frames)
    await probe.rpc("prompt.submit", {"session_id": first_runtime, "text": restart_first})
    await probe.wait_terminal(first_runtime, start)
    await probe.wait_idle(first_runtime)
    _assert_turn_rows(
        await probe.rest_messages(first_stored),
        prior_first + [restart_first],
        prior_first_efforts + ["high"],
    )

    evidence["phase"] = "restart resume sibling"
    sibling_resume = await probe.rpc(
        "session.resume", {"session_id": sibling_stored, "profile": PROFILE}
    )
    sibling_runtime = sibling_resume["session_id"]
    evidence["sessions"]["resumed_runtime_ids"].append(sibling_runtime)
    _assert_turn_rows(await probe.rest_messages(sibling_stored), prior_sibling, ["medium"])
    _assert_reasoning_readback(
        await probe.rpc(
            "config.get",
            {"key": "reasoning", "session_id": sibling_runtime, "profile": PROFILE},
        ),
        "medium",
    )
    restart_sibling = "SEMREH_REASONING_PROBE restart-sibling-medium"
    start = len(probe.frames)
    await probe.rpc(
        "prompt.submit", {"session_id": sibling_runtime, "text": restart_sibling}
    )
    await probe.wait_terminal(sibling_runtime, start)
    await probe.wait_idle(sibling_runtime)
    _assert_turn_rows(
        await probe.rest_messages(sibling_stored),
        prior_sibling + [restart_sibling],
        ["medium", "medium"],
    )

    # Both runtime IDs were created by this restart phase.  The durable rows
    # remain in state.db; close only these live handles, never delete history.
    await probe.rpc("session.close", {"session_id": first_runtime})
    await probe.rpc("session.close", {"session_id": sibling_runtime})
    evidence["assertions"] = {
        "prior_four_pairs_retained": True,
        "restart_first_request_used_high": True,
        "restart_sibling_request_used_medium": True,
        "restart_config_get_contract": 1,
        "runtime_ids_closed_without_row_deletion": True,
    }


async def _run(output: Path, backend_sha: str, resume_from: str | None = None) -> None:
    _validate_all(backend_sha)
    prior = _load_resume_evidence(resume_from, backend_sha) if resume_from else None
    credentials = json.loads((RUNTIME / "credentials.json").read_text(encoding="utf-8"))
    config_before = _config_hash()
    evidence = {
        "configured_source_pin": PIN,
        "backend_sha": backend_sha.lower(),
        "deployment": HTTPS_ORIGIN,
        "provider": "deterministic localhost fixture; NOT external-provider proof",
        "profile": PROFILE,
        "sanitized": True,
        "frames": [],
    }
    try:
        await _exercise(credentials, config_before, evidence, prior=prior)
        evidence["config_sha256_before"] = config_before
        evidence["config_sha256_after"] = _config_hash()
        if evidence["config_sha256_before"] != evidence["config_sha256_after"]:
            raise AssertionError("global config changed after reasoning probe")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["outcome"] = "failed"
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError(f"Probe failed; sanitized evidence retained at {output}") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Reasoning contract assertions passed; sanitized evidence: {output}")


async def _exercise(
    credentials: dict, config_before: str, evidence: dict, *, prior: dict | None = None
) -> None:
    evidence["phase"] = "authentication"
    async with httpx.AsyncClient(base_url=BASE, trust_env=False, follow_redirects=False) as client:
        login = await client.post(
            "/auth/password-login",
            json={"provider": "basic", **credentials, "next": ""},
        )
        if login.status_code not in (200, 302, 303):
            raise RuntimeError(f"disposable HTTPS login failed with {login.status_code}")
        ticket_response = await client.post("/api/auth/ws-ticket")
        ticket_response.raise_for_status()
        ticket = ticket_response.json().get("ticket")
        if not isinstance(ticket, str) or not ticket:
            raise RuntimeError("disposable HTTPS server returned no WebSocket ticket")

        async with connect(
            f"{WS_BASE}/api/ws?ticket={ticket}",
            origin=HTTPS_ORIGIN,
            proxy=None,
        ) as ws:
            ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
            evidence["frames"].append(sanitize(ready))
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("expected gateway.ready from disposable HTTPS backend")
            probe = Probe(ws, client, evidence)

            if prior is not None:
                await _exercise_restart_phase(probe, evidence, prior)
                await client.post("/auth/logout")
                return

            evidence["phase"] = "create and warmup"
            first = await probe.rpc(
                "session.create",
                {
                    "profile": PROFILE,
                    "cwd": str(TOOLS_CWD),
                    "model": "gpt-5",
                    "provider": "custom",
                    "reasoning_effort": "low",
                },
            )
            sibling = await probe.rpc(
                "session.create",
                {
                    "profile": PROFILE,
                    "cwd": str(TOOLS_CWD),
                    "model": "gpt-5",
                    "provider": "custom",
                    "reasoning_effort": "medium",
                },
            )
            first_runtime = first["session_id"]
            sibling_runtime = sibling["session_id"]
            first_stored = first["stored_session_id"]
            sibling_stored = sibling["stored_session_id"]
            created_runtime_ids = {first_runtime, sibling_runtime}
            evidence["sessions"] = {
                "first_stored_id": first_stored,
                "sibling_stored_id": sibling_stored,
                "created_runtime_ids": sorted(created_runtime_ids),
            }

            # Warm both sessions so the real provider request proves the initial
            # per-session choices before the busy-turn change.
            warm_first = "SEMREH_REASONING_PROBE warmup-low"
            start = len(probe.frames)
            await probe.rpc("prompt.submit", {"session_id": first_runtime, "text": warm_first})
            await probe.wait_terminal(first_runtime, start)
            await probe.wait_idle(first_runtime)
            warm_sibling = "SEMREH_REASONING_PROBE warmup-medium"
            start = len(probe.frames)
            await probe.rpc("prompt.submit", {"session_id": sibling_runtime, "text": warm_sibling})
            await probe.wait_terminal(sibling_runtime, start)
            await probe.wait_idle(sibling_runtime)
            _assert_turn_rows(
                await probe.rest_messages(first_stored), [warm_first], ["low"]
            )
            _assert_turn_rows(
                await probe.rest_messages(sibling_stored), [warm_sibling], ["medium"]
            )

            delayed = "SEMREH_INTERRUPT_FIXTURE SEMREH_REASONING_PROBE delayed-low"
            evidence["phase"] = "busy next-turn selection"
            start = len(probe.frames)
            await probe.rpc("prompt.submit", {"session_id": first_runtime, "text": delayed})
            await probe.wait_running(first_runtime)
            selected = await probe.rpc(
                "config.set",
                {
                    "key": "reasoning",
                    "value": "high",
                    "scope": "session",
                    "session_id": first_runtime,
                    "profile": PROFILE,
                },
            )
            if selected.get("scope") != "session" or not selected.get("deferred"):
                raise AssertionError("busy reasoning selection was not deferred to this session")
            if selected.get("persisted") is not True:
                raise AssertionError("busy reasoning selection was not durably acknowledged")
            selected_readback = await probe.rpc(
                "config.get",
                {"key": "reasoning", "session_id": first_runtime, "profile": PROFILE},
            )
            if selected_readback.get("value") != "high" or selected_readback.get("session_reasoning_contract") != 1:
                raise AssertionError("config.get did not report the pending high session choice")
            sibling_readback = await probe.rpc(
                "config.get",
                {"key": "reasoning", "session_id": sibling_runtime, "profile": PROFILE},
            )
            if sibling_readback.get("value") != "medium":
                raise AssertionError("sibling session reasoning changed during targeted update")
            await probe.wait_terminal(first_runtime, start)
            await probe.wait_idle(first_runtime)
            delayed_rows = await probe.rest_messages(first_stored)
            _assert_turn_rows(
                delayed_rows, [warm_first, delayed], ["low", "low"]
            )

            next_high = "SEMREH_REASONING_PROBE subsequent-high"
            evidence["phase"] = "next turn"
            start = len(probe.frames)
            await probe.rpc("prompt.submit", {"session_id": first_runtime, "text": next_high})
            await probe.wait_terminal(first_runtime, start)
            await probe.wait_idle(first_runtime)
            _assert_turn_rows(
                await probe.rest_messages(first_stored),
                [warm_first, delayed, next_high],
                ["low", "low", "high"],
            )

            # Explicitly targeted requests fail closed; none may become a
            # profile-default write.
            evidence["phase"] = "scope rejection"
            for params in (
                {"key": "reasoning", "value": "high", "scope": "session", "profile": PROFILE},
                {
                    "key": "reasoning",
                    "value": "high",
                    "scope": "session",
                    "session_id": "stale-generated-runtime-id",
                    "profile": PROFILE,
                },
                {
                    "key": "reasoning",
                    "value": "high",
                    "session_id": "stale-generated-runtime-id",
                    "profile": PROFILE,
                },
                {
                    "key": "reasoning",
                    "value": "high",
                    "scope": "session",
                    "session_id": first_runtime,
                    "profile": "wrong-generated-profile",
                },
            ):
                await probe.expect_error("config.set", params)

            if _config_hash() != config_before:
                raise AssertionError("session-scoped reasoning changed global config.yaml")

            await probe.rpc("session.close", {"session_id": first_runtime})
            await probe.rpc("session.close", {"session_id": sibling_runtime})

            resumed = await probe.rpc(
                "session.resume",
                {"session_id": first_stored, "profile": PROFILE},
            )
            resumed_runtime = resumed["session_id"]
            evidence["phase"] = "cold resume"
            evidence["sessions"]["resumed_runtime_id"] = resumed_runtime
            resumed_prompt = "SEMREH_REASONING_PROBE cold-resume-high"
            start = len(probe.frames)
            await probe.rpc(
                "prompt.submit", {"session_id": resumed_runtime, "text": resumed_prompt}
            )
            await probe.wait_terminal(resumed_runtime, start)
            await probe.wait_idle(resumed_runtime)
            _assert_turn_rows(
                await probe.rest_messages(first_stored),
                [warm_first, delayed, next_high, resumed_prompt],
                ["low", "low", "high", "high"],
            )
            await probe.rpc("session.close", {"session_id": resumed_runtime})
            evidence["assertions"] = {
                "busy_deferred_and_persisted": True,
                "inflight_turn_used_old_effort": True,
                "next_turn_used_new_effort": True,
                "sibling_unchanged": True,
                "global_config_sha256_unchanged": True,
                "stale_missing_wrong_profile_rejected": True,
                "cold_resume_restored_high": True,
                "durable_turn_order_verified_via_profiled_rest": True,
            }

        await client.post("/auth/logout")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend-sha", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--resume-from")
    args = parser.parse_args()
    output = _output_path(args.output)
    asyncio.run(_run(output, args.backend_sha, args.resume_from))


if __name__ == "__main__":
    main()
