#!/usr/bin/env python3
"""Guarded disposable-Hermes stabilization smoke.

The default action performs only the existing static fixture validation.  The
explicit ``--run`` action makes bounded requests to the owned HTTPS fixture and
its localhost deterministic model.  It never starts or stops either service.
"""

import argparse
import asyncio
import json
from pathlib import Path
import time

import httpx
from websockets.asyncio.client import connect

from direct_hermes_probe import (
    AUXILIARY_FIXTURE_CONFIG,
    HTTPS_ORIGIN,
    RUNTIME,
    _validate_plugin_config,
    _validate_runtime_plugins,
    _validate_runtime_skill,
    validate,
)


PROFILE = "default"
MODEL_ORIGIN = "http://127.0.0.1:18792"
WS_ORIGIN = HTTPS_ORIGIN.replace("https://", "wss://")
EVIDENCE_ROOT = Path("/Users/maurice/workspace/semreh-slice1-evidence")
INITIAL_PROMPT = "SEMREH_STABILIZATION_SMOKE_INITIAL_V1"
INTERRUPT_PROMPT = "SEMREH_INTERRUPT_FIXTURE"
RECOVERY_PROMPT = "SEMREH_STABILIZATION_SMOKE_AFTER_INTERRUPT_V1"
EXPECTED_ACK = "SEMREH_SLICE1_ACK"
RPC_TIMEOUT = 60.0


def guarded_output_path(raw: str) -> Path:
    path = Path(raw)
    if path.is_symlink() or path.parent.resolve() != EVIDENCE_ROOT.resolve():
        raise RuntimeError("Evidence must be a direct, non-symlink child of the fixture evidence root")
    if path.exists():
        raise RuntimeError("Refusing to overwrite stabilization evidence")
    return path


def validate_fixture_policy() -> None:
    """Repeat the safety-critical no-provider/no-tool routing assertions."""
    config_path = RUNTIME / "home/config.yaml"
    if config_path.is_symlink() or config_path.resolve() != config_path:
        raise RuntimeError("Disposable config escaped its owned path")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    if config.get("model") != {
        "provider": "custom",
        "default": "semreh-fixture",
        "base_url": MODEL_ORIGIN + "/v1",
    }:
        raise RuntimeError("Disposable main-model route drifted")
    if config.get("auxiliary") != AUXILIARY_FIXTURE_CONFIG:
        raise RuntimeError("Disposable auxiliary routes drifted")
    if config.get("toolsets") != [] or config.get("platform_toolsets") != {"cli": [], "tui": []}:
        raise RuntimeError("Disposable tool schema policy drifted")
    if config.get("mcp_servers") != {} or config.get("platforms") != {}:
        raise RuntimeError("Disposable external tool/provider policy drifted")
    # The enrolled fixture exposes only clarify plus the repository-owned
    # no-op approval/empty-secret tools.
    _validate_plugin_config(approval_secret_fixture=True)
    _validate_runtime_plugins(approval_secret_fixture=True)
    _validate_runtime_skill(approval_secret_fixture=True)


def assert_canonical_rows(
    payload: object,
    stored_id: str,
    *,
    after_interrupt: bool,
    after_recovery: bool,
) -> int:
    if not isinstance(payload, dict) or payload.get("session_id") != stored_id:
        raise AssertionError("Canonical transcript identity mismatch")
    rows = payload.get("messages")
    if not isinstance(rows, list):
        raise AssertionError("Canonical transcript omitted messages")
    pairs = [(row.get("role"), row.get("content")) for row in rows if isinstance(row, dict)]
    required = [("user", INITIAL_PROMPT), ("assistant", EXPECTED_ACK)]
    if after_interrupt:
        required.append(("user", INTERRUPT_PROMPT))
    if after_recovery:
        required += [("user", RECOVERY_PROMPT), ("assistant", EXPECTED_ACK)]
    cursor = 0
    for expected in required:
        try:
            cursor = pairs.index(expected, cursor) + 1
        except ValueError as error:
            raise AssertionError("Canonical transcript omitted an owned smoke row") from error
    pagination = payload.get("pagination")
    if not isinstance(pagination, dict) or pagination.get("has_more") is True:
        raise AssertionError("Canonical transcript was incomplete")
    expected_user_counts = {
        INITIAL_PROMPT: 1,
        INTERRUPT_PROMPT: 1 if after_interrupt else 0,
        RECOVERY_PROMPT: 1 if after_recovery else 0,
    }
    for prompt, expected_count in expected_user_counts.items():
        if pairs.count(("user", prompt)) != expected_count:
            raise AssertionError("Canonical transcript duplicated or omitted an owned prompt")
    expected_ack_count = 2 if after_recovery else 1
    if pairs.count(("assistant", EXPECTED_ACK)) != expected_ack_count:
        raise AssertionError("Canonical transcript duplicated or omitted a fixture ACK")
    return len(rows)


class RPC:
    def __init__(self, websocket):
        self.websocket = websocket
        self.next_id = 1
        self.buffered = []

    async def receive(self, timeout: float = RPC_TIMEOUT) -> dict:
        frame = json.loads(await asyncio.wait_for(self.websocket.recv(), timeout))
        if not isinstance(frame, dict):
            raise RuntimeError("Gateway frame was not an object")
        return frame

    async def call(self, method: str, params: dict, timeout: float = RPC_TIMEOUT):
        request_id = self.next_id
        self.next_id += 1
        await self.websocket.send(json.dumps({
            "jsonrpc": "2.0", "id": request_id, "method": method, "params": params,
        }))
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Gateway RPC deadline exceeded")
            frame = await self.receive(remaining)
            if frame.get("id") == request_id:
                if "error" in frame:
                    raise RuntimeError("Gateway RPC returned an error")
                return frame.get("result")
            self.buffered.append(frame)

    @staticmethod
    def terminal_status(frame: dict, runtime_id: str):
        params = frame.get("params", {})
        if params.get("type") != "message.complete" or params.get("session_id") != runtime_id:
            return None
        return params.get("payload", {}).get("status")

    async def wait_terminal(self, runtime_id: str, expected: str) -> None:
        for index, frame in enumerate(self.buffered):
            status = self.terminal_status(frame, runtime_id)
            if status is not None:
                del self.buffered[index]
                if status != expected:
                    raise AssertionError("Gateway returned an unexpected terminal status")
                return
        deadline = time.monotonic() + RPC_TIMEOUT
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Gateway terminal deadline exceeded")
            frame = await self.receive(remaining)
            status = self.terminal_status(frame, runtime_id)
            if status is None:
                self.buffered.append(frame)
            else:
                if status != expected:
                    raise AssertionError("Gateway returned an unexpected terminal status")
                return


async def wait_idle(rpc: RPC, runtime_id: str) -> int:
    started = time.monotonic()
    polls = 0
    while time.monotonic() - started < 40:
        polls += 1
        result = await rpc.call("session.status", {"session_id": runtime_id})
        if isinstance(result, dict) and "Agent Running: No" in str(result.get("output", "")):
            return polls
        await asyncio.sleep(0.25)
    raise TimeoutError("Owned session did not become idle after interrupt")


def write_evidence(path: Path, evidence: dict) -> None:
    # The schema is deliberately aggregate-only: no IDs, prompts, frames,
    # credentials, URLs, response bodies, or exception strings are accepted.
    allowed = {"checks", "counts", "latencies_ms"}
    if set(evidence) != allowed:
        raise RuntimeError("Unexpected stabilization evidence field")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def valid_model_inventory(data: object) -> bool:
    identities = [
        (item.get("id"), item.get("owned_by"))
        for item in data if isinstance(item, dict)
    ] if isinstance(data, list) else []
    return identities in (
        [("semreh-fixture", "local-test")],
        [("semreh-fixture", "local-test"), ("gpt-5", "local-test")],
    )


def empty_evidence() -> dict:
    return {
        "checks": {
            "source_pin": False, "fixture_policy": True, "model_identity": False,
            "authenticated": False, "ticket_socket_ready": False,
            "initial_durable_ack": False, "interrupt_terminal": False,
            "interrupt_idle": False, "canonical_read_after_interrupt": False,
            "post_interrupt_send": False, "owned_session_closed": False,
        },
        "counts": {"canonical_rows_after_interrupt": 0, "canonical_rows_final": 0, "idle_polls": 0},
        "latencies_ms": {"initial_turn": 0, "interrupt_to_idle": 0, "recovery_turn": 0},
    }


async def _exercise_smoke(evidence: dict) -> None:
    validate()
    validate_fixture_policy()
    runtime_id = None
    credentials = json.loads((RUNTIME / "credentials.json").read_text(encoding="utf-8"))
    config = json.loads((RUNTIME / "home/config.yaml").read_text(encoding="utf-8"))
    evidence["checks"]["source_pin"] = True
    if config.get("dashboard", {}).get("public_url") != HTTPS_ORIGIN:
        raise RuntimeError("Disposable fixture is not enrolled for its owned HTTPS route")

    async with httpx.AsyncClient(trust_env=False, follow_redirects=False, timeout=15) as model_client:
        models = await model_client.get(MODEL_ORIGIN + "/v1/models")
        models.raise_for_status()
        data = models.json().get("data")
        if not valid_model_inventory(data):
            raise RuntimeError("Deterministic model identity mismatch")
        evidence["checks"]["model_identity"] = True

    client = httpx.AsyncClient(base_url=HTTPS_ORIGIN, trust_env=False, follow_redirects=False, timeout=30)
    try:
        login = await client.post("/auth/password-login", json={"provider": "basic", **credentials, "next": ""})
        if login.status_code not in (200, 302, 303):
            raise RuntimeError("Disposable fixture login failed")
        evidence["checks"]["authenticated"] = True
        ticket_response = await client.post("/api/auth/ws-ticket")
        ticket_response.raise_for_status()
        ticket = ticket_response.json().get("ticket")
        if not isinstance(ticket, str) or not ticket:
            raise RuntimeError("Disposable fixture ticket missing")

        async with connect(WS_ORIGIN + "/api/ws?ticket=" + ticket, origin=HTTPS_ORIGIN, proxy=None) as websocket:
            rpc = RPC(websocket)
            ready = await rpc.receive(30)
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("Disposable gateway did not become ready")
            evidence["checks"]["ticket_socket_ready"] = True
            created = await rpc.call("session.create", {
                "profile": PROFILE, "cwd": str(RUNTIME / "tools"),
                "model": "semreh-fixture", "provider": "custom",
            })
            if not isinstance(created, dict):
                raise RuntimeError("Owned session creation returned an invalid response")
            runtime_id = created.get("session_id")
            stored_id = created.get("stored_session_id")
            if not all(isinstance(value, str) and value for value in (runtime_id, stored_id)):
                raise RuntimeError("Owned session creation omitted exact identities")
            try:
                started = time.monotonic()
                await rpc.call("prompt.submit", {"session_id": runtime_id, "text": INITIAL_PROMPT})
                await rpc.wait_terminal(runtime_id, "complete")
                evidence["latencies_ms"]["initial_turn"] = round((time.monotonic() - started) * 1000)

                transcript = await client.get(f"/api/sessions/{stored_id}/messages", params={
                    "profile": PROFILE, "include_compacted": "true", "order": "oldest",
                    "limit": 50, "offset": 0,
                })
                transcript.raise_for_status()
                assert_canonical_rows(
                    transcript.json(), stored_id,
                    after_interrupt=False, after_recovery=False,
                )
                evidence["checks"]["initial_durable_ack"] = True

                await rpc.call("prompt.submit", {"session_id": runtime_id, "text": INTERRUPT_PROMPT})
                running = await rpc.call("session.status", {"session_id": runtime_id})
                if not isinstance(running, dict) or "Agent Running: Yes" not in str(running.get("output", "")):
                    raise AssertionError("Delayed fixture was not running before interrupt")
                started = time.monotonic()
                await rpc.call("session.interrupt", {"session_id": runtime_id})
                evidence["counts"]["idle_polls"] = await wait_idle(rpc, runtime_id)
                evidence["latencies_ms"]["interrupt_to_idle"] = round((time.monotonic() - started) * 1000)
                evidence["checks"]["interrupt_idle"] = True
                await rpc.wait_terminal(runtime_id, "interrupted")
                evidence["checks"]["interrupt_terminal"] = True

                transcript = await client.get(f"/api/sessions/{stored_id}/messages", params={
                    "profile": PROFILE, "include_compacted": "true", "order": "oldest",
                    "limit": 50, "offset": 0,
                })
                transcript.raise_for_status()
                evidence["counts"]["canonical_rows_after_interrupt"] = assert_canonical_rows(
                    transcript.json(), stored_id,
                    after_interrupt=True, after_recovery=False,
                )
                evidence["checks"]["canonical_read_after_interrupt"] = True

                started = time.monotonic()
                await rpc.call("prompt.submit", {"session_id": runtime_id, "text": RECOVERY_PROMPT})
                await rpc.wait_terminal(runtime_id, "complete")
                evidence["latencies_ms"]["recovery_turn"] = round((time.monotonic() - started) * 1000)
                transcript = await client.get(f"/api/sessions/{stored_id}/messages", params={
                    "profile": PROFILE, "include_compacted": "true", "order": "oldest",
                    "limit": 50, "offset": 0,
                })
                transcript.raise_for_status()
                evidence["counts"]["canonical_rows_final"] = assert_canonical_rows(
                    transcript.json(), stored_id,
                    after_interrupt=True, after_recovery=True,
                )
                evidence["checks"]["post_interrupt_send"] = True
            finally:
                if runtime_id is not None:
                    closed = await rpc.call("session.close", {"session_id": runtime_id})
                    if not isinstance(closed, dict) or closed.get("closed") is not True:
                        raise AssertionError("Owned runtime did not close")
                    evidence["checks"]["owned_session_closed"] = True
                    runtime_id = None
    finally:
        try:
            await client.post("/auth/logout")
        finally:
            await client.aclose()

    if not all(evidence["checks"].values()):
        raise AssertionError("Stabilization smoke did not complete every guarded check")


async def run_smoke(path: Path) -> None:
    evidence = empty_evidence()
    try:
        await _exercise_smoke(evidence)
    finally:
        write_evidence(path, evidence)
    print("Disposable stabilization smoke passed; aggregate evidence: " + str(path))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Run the explicit owned live smoke")
    parser.add_argument("--output", help="Fresh direct child of the disposable evidence directory")
    args = parser.parse_args()
    if not args.run:
        if args.output is not None:
            parser.error("--output is only valid with --run")
        validate()
        validate_fixture_policy()
        print(json.dumps({"validated": True, "source_pin_matches": True, "live_requests_sent": False}))
        return
    if args.output is None:
        parser.error("--run requires --output")
    asyncio.run(run_smoke(guarded_output_path(args.output)))


if __name__ == "__main__":
    main()
