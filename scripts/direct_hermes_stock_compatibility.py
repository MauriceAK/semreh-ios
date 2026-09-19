#!/usr/bin/env python3
"""Bounded stock-Hermes protocol smoke; never exercises reasoning writes."""

import argparse
import asyncio
import hashlib
import json
import time
from pathlib import Path

import httpx
from websockets.asyncio.client import connect

from direct_hermes_capture import BASE, HEADERS, ORIGIN, WS_BASE, write_fixture
from direct_hermes_probe import PIN, RUNTIME, validate


PROFILE = "default"
PROMPT = "SEMREH_STOCK_COMPATIBILITY_PROMPT"
EXPECTED_ACK = "SEMREH_SLICE1_ACK"
EVIDENCE_ROOT = Path("/Users/maurice/workspace/semreh-slice1-evidence")
ALLOWED_EFFORTS = {"none", "low", "medium", "high"}
RPC_DEADLINE_SECONDS = 60


def config_hash():
    return hashlib.sha256((RUNTIME / "home/config.yaml").read_bytes()).hexdigest()


def output_path(raw):
    path = Path(raw)
    if path.is_symlink() or path.parent.resolve() != EVIDENCE_ROOT.resolve():
        raise RuntimeError("Output must be a direct, non-symlink child of the evidence root")
    if path.exists():
        raise RuntimeError("Refusing to overwrite stock compatibility evidence")
    return path


def classify_reasoning_read(result):
    if not isinstance(result, dict):
        raise AssertionError("config.get reasoning result was not an object")
    value = result.get("value")
    display = result.get("display")
    if value not in ALLOWED_EFFORTS or display not in {"show", "hide"}:
        raise AssertionError("config.get reasoning returned an invalid stock value")
    if "session_reasoning_contract" in result or "persisted" in result or "deferred" in result:
        raise AssertionError("extended reasoning response returned by stock compatibility probe")
    return {"value": value, "display": display, "contract": "stock-read-v1"}


def assert_rest_pair(payload, stored_id):
    if not isinstance(payload, dict) or payload.get("session_id") != stored_id:
        raise AssertionError("REST transcript canonical identity mismatch")
    rows = payload.get("messages")
    if not isinstance(rows, list) or len(rows) != 2:
        raise AssertionError("REST transcript did not contain one durable pair")
    if [row.get("role") for row in rows] != ["user", "assistant"]:
        raise AssertionError("REST transcript roles were not the expected durable pair")
    if rows[0].get("content") != PROMPT:
        raise AssertionError("REST transcript did not preserve the submitted prompt")
    if rows[1].get("content") != EXPECTED_ACK:
        raise AssertionError("REST transcript did not contain the exact fixture ACK")
    pagination = payload.get("pagination")
    if not isinstance(pagination, dict):
        raise AssertionError("REST transcript omitted pagination metadata")
    return {"row_count": 2, "roles": ["user", "assistant"], "pagination_present": True}


class RPC:
    def __init__(self, ws):
        self.ws = ws
        self.next_id = 1
        self.buffered_events = []

    async def receive(self, timeout=RPC_DEADLINE_SECONDS):
        frame = json.loads(await asyncio.wait_for(self.ws.recv(), timeout))
        if not isinstance(frame, dict):
            raise RuntimeError("gateway frame was not an object")
        return frame

    async def call(self, method, params, timeout=RPC_DEADLINE_SECONDS):
        request_id = self.next_id
        self.next_id += 1
        await self.ws.send(json.dumps({
            "jsonrpc": "2.0", "id": request_id, "method": method, "params": params,
        }))
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("stock gateway RPC deadline exceeded")
            frame = await self.receive(min(remaining, RPC_DEADLINE_SECONDS))
            if frame.get("id") == request_id:
                if "error" in frame:
                    raise RuntimeError("stock gateway RPC failed")
                return frame.get("result")
            self.buffered_events.append(frame)

    @staticmethod
    def _is_complete(frame, runtime_id):
        params = frame.get("params", {})
        if params.get("type") != "message.complete" or params.get("session_id") != runtime_id:
            return False
        status = params.get("payload", {}).get("status")
        if status != "complete":
            raise AssertionError("stock turn did not reach a normal terminal")
        return True

    async def wait_complete(self, runtime_id, timeout=RPC_DEADLINE_SECONDS):
        for index, frame in enumerate(self.buffered_events):
            if self._is_complete(frame, runtime_id):
                del self.buffered_events[index]
                return

        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("stock gateway terminal deadline exceeded")
            frame = await self.receive(min(remaining, RPC_DEADLINE_SECONDS))
            if self._is_complete(frame, runtime_id):
                return
            self.buffered_events.append(frame)


def final_phase(*, turn_succeeded, cleanup_errors, config_unchanged):
    return "complete" if turn_succeeded and not cleanup_errors and config_unchanged else "failed"


def write_categorical_failure(path, evidence):
    """Write safe categorical evidence when config cannot be read for sanitizing."""
    if path.is_symlink() or path.exists():
        raise RuntimeError("Refusing to overwrite stock compatibility evidence")
    path.parent.mkdir(parents=True, exist_ok=True)
    safe = {
        "configured_source_pin": evidence.get("configured_source_pin"),
        "backend_contract": evidence.get("backend_contract"),
        "process_identity": evidence.get("process_identity"),
        "provider": evidence.get("provider"),
        "phase": "failed",
        "cleanup_errors": evidence.get("cleanup_errors", []),
        "config_unchanged": False,
    }
    path.write_text(json.dumps(safe, indent=2) + "\n", encoding="utf-8")


async def exercise(path):
    validate()
    evidence = {
        "configured_source_pin": PIN,
        "backend_contract": "stock-29112-read-and-turn-only-configured-pin",
        "process_identity": "external listener attestation required",
        "reasoning_write_exercised": False,
        "provider": "deterministic localhost fixture; no external provider",
        "phase": "config",
        "checks": [],
        "cleanup_errors": [],
        "captured_at_unix": int(time.time()),
    }
    try:
        before = config_hash()
        credentials = json.loads((RUNTIME / "credentials.json").read_text())
        config = json.loads((RUNTIME / "home/config.yaml").read_text())
    except Exception as error:
        evidence["cleanup_errors"].append({"operation": "config_read", "type": type(error).__name__})
        write_categorical_failure(path, evidence)
        raise
    if config.get("dashboard", {}).get("public_url") != ORIGIN:
        raise RuntimeError("Probe mode does not match the validated stock fixture")

    succeeded = False
    owned_runtime = None
    client = httpx.AsyncClient(base_url=BASE, headers=HEADERS, trust_env=False, follow_redirects=False)
    try:
        login = await client.post("/auth/password-login", json={"provider": "basic", **credentials, "next": ""})
        if login.status_code not in (200, 302, 303):
            raise RuntimeError("stock fixture login failed")
        ticket_response = await client.post("/api/auth/ws-ticket")
        ticket_response.raise_for_status()
        ticket = ticket_response.json().get("ticket")
        if not isinstance(ticket, str) or not ticket:
            raise RuntimeError("stock fixture ticket missing")
        evidence["phase"] = "gateway smoke"
        async with connect(WS_BASE + "/api/ws?ticket=" + ticket, origin=ORIGIN, proxy=None) as ws:
            rpc = RPC(ws)
            ready = await rpc.receive()
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("stock gateway.ready missing")
            created = await rpc.call("session.create", {
                "profile": PROFILE, "cwd": str(RUNTIME / "tools"),
                "model": "semreh-fixture", "provider": "custom",
            })
            owned_runtime = created.get("session_id") if isinstance(created, dict) else None
            stored_id = created.get("stored_session_id") if isinstance(created, dict) else None
            if not all(isinstance(value, str) and value for value in (owned_runtime, stored_id)):
                raise AssertionError("stock session.create omitted runtime or durable identity")
            try:
                reasoning = await rpc.call("config.get", {
                    "key": "reasoning", "session_id": owned_runtime, "profile": PROFILE,
                })
                evidence["reasoning_read"] = classify_reasoning_read(reasoning)
                await rpc.call("prompt.submit", {"session_id": owned_runtime, "text": PROMPT})
                await rpc.wait_complete(owned_runtime)
                status = await rpc.call("session.status", {"session_id": owned_runtime})
                if not isinstance(status, dict) or "Agent Running: No" not in str(status.get("output", "")):
                    raise AssertionError("stock runtime was not idle after terminal event")
                transcript = await client.get(f"/api/sessions/{stored_id}/messages", params={
                    "profile": PROFILE, "include_compacted": "true", "order": "latest",
                    "limit": 10, "offset": 0,
                })
                transcript.raise_for_status()
                evidence["durable_transcript"] = assert_rest_pair(transcript.json(), stored_id)
                evidence["checks"] = [
                    "gateway ready and stock session identities",
                    "stock reasoning read response",
                    "normal deterministic turn terminal and idle",
                    "canonical REST durable pair and pagination",
                ]
            finally:
                evidence["phase"] = "cleanup"
                try:
                    closed = await rpc.call("session.close", {"session_id": owned_runtime})
                    if not isinstance(closed, dict) or closed.get("closed") is not True:
                        raise AssertionError("owned stock runtime did not close")
                    owned_runtime = None
                except Exception as error:
                    evidence["cleanup_errors"].append({
                        "operation": "session.close", "type": type(error).__name__,
                    })
        evidence["phase"] = "logout"
        succeeded = not evidence["cleanup_errors"]
    finally:
        # The socket normally owns runtime cleanup. Record only categorical local
        # cleanup failures; never persist server frames or exception strings.
        if owned_runtime is not None:
            evidence["cleanup_errors"].append({"operation": "session.close", "type": "socket_scope_exited"})
        try:
            logout = await client.post("/auth/logout")
            if logout.status_code not in (200, 302, 303):
                raise AssertionError("unexpected logout status")
        except Exception as error:
            evidence["cleanup_errors"].append({"operation": "logout", "type": type(error).__name__})
        await client.aclose()
        try:
            after = config_hash()
            evidence["config_unchanged"] = before == after
        except Exception as error:
            evidence["config_unchanged"] = False
            evidence["cleanup_errors"].append({"operation": "config_read_after", "type": type(error).__name__})
        evidence["phase"] = final_phase(
            turn_succeeded=succeeded,
            cleanup_errors=evidence["cleanup_errors"],
            config_unchanged=evidence.get("config_unchanged", False),
        )
        try:
            write_fixture(path, evidence)
        except Exception:
            if not path.exists():
                write_categorical_failure(path, evidence)
            else:
                raise
    if not evidence["config_unchanged"]:
        raise AssertionError("stock compatibility probe changed fixture configuration")
    if evidence["cleanup_errors"]:
        raise AssertionError("stock compatibility cleanup failed")
    print("Stock pin/read/turn/REST compatibility passed; sanitized evidence: " + str(path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend-sha", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    if args.backend_sha.lower() != PIN:
        parser.error("--backend-sha must be the exact approved stock Hermes pin")
    asyncio.run(exercise(output_path(args.output)))


if __name__ == "__main__":
    main()
