#!/usr/bin/env python3
"""Prove default-profile MEMORY adoption using only the owned HTTPS fixture.

Root must first enter the reviewed enabled-config phase and later restore the
disabled baseline. This probe never writes configuration; it mutates one exact
absent MEMORY.md and requires the enabled config bytes stay unchanged.
"""

from __future__ import annotations
import argparse, asyncio, base64, hashlib, json, re, time
from pathlib import Path
from websockets.asyncio.client import connect

from direct_hermes_capture import write_fixture
from direct_hermes_goal_live_probe import _backend_guard
from direct_hermes_identity_probe import authenticated, binding
from direct_hermes_reasoning_probe import Probe, RPC_TIMEOUT, _json_frame, _output_path
import direct_hermes_probe as stock

PROFILE = "default"
MEMORY_ADOPTION_MARKER = "SEMREH_MEMORY_ADOPTION_BENIGN_V1"
MEMORY_ADOPTION_REQUEST = "SEMREH_MEMORY_ADOPTION_REQUEST_V1"
PROMPT = MEMORY_ADOPTION_REQUEST + " Reply with a short acknowledgement. Do not use tools."
EXPECTED_MODEL = {"provider": "custom", "default": "semreh-fixture",
                  "base_url": "http://127.0.0.1:18792/v1"}
EXPECTED_MAIN_TOOLS = ["clarify", "semreh_fixture_approval", "semreh_fixture_secret"]


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _preflight(pid: int, expected_sha: str, diagnostic_log: Path) -> tuple[Path, Path, bytes]:
    stock.validate(allow_memory_adoption=True); _backend_guard(pid)
    stock._validate_runtime_plugins(approval_secret_fixture=True)
    stock._validate_plugin_config(approval_secret_fixture=True)
    stock._validate_runtime_skill(approval_secret_fixture=True)
    if not re.fullmatch(r"[0-9a-f]{64}", expected_sha):
        raise RuntimeError("Expected config SHA must be lowercase SHA-256")
    config_path = stock.RUNTIME / "home/config.yaml"
    config_bytes = config_path.read_bytes()
    if _sha(config_bytes) != expected_sha:
        raise RuntimeError("Disposable config SHA drifted")
    config = json.loads(config_bytes)
    if config.get("model") != EXPECTED_MODEL:
        raise RuntimeError("Main model is not exactly the local fixture")
    if config.get("memory") != {"memory_enabled": True,
                                 "user_profile_enabled": False, "provider": ""}:
        raise RuntimeError("Default memory policy is not the reviewed enabled proof phase")
    memory_path = stock.RUNTIME / "home/memories/MEMORY.md"
    if memory_path.exists() or memory_path.is_symlink():
        raise RuntimeError("Owned default MEMORY.md must be absent before proof")
    if diagnostic_log.is_symlink() or not diagnostic_log.is_file():
        raise RuntimeError("Model diagnostic log must be an existing regular file")
    runtime = stock.RUNTIME.resolve()
    if runtime not in diagnostic_log.resolve().parents:
        raise RuntimeError("Model diagnostic log escaped the owned runtime")
    return config_path, memory_path, config_bytes


def _diagnostic_summary(data: bytes) -> tuple[bool, int]:
    matches = []
    for raw in data.splitlines():
        if not raw.startswith(b"SEMREH_FIXTURE_DIAGNOSTIC "):
            continue
        try:
            item = json.loads(raw.split(b" ", 1)[1])
        except (ValueError, TypeError):
            continue
        if item.get("memory_adoption_request") is True:
            matches.append(item)
    main = [item for item in matches
            if item.get("advertised_tools") == EXPECTED_MAIN_TOOLS]
    auxiliary = [item for item in matches
                 if item.get("advertised_tool_count") == 0
                 and item.get("advertised_tools") == []
                 and item.get("exact_memory_marker_in_system") is False]
    proved = (len(main) == 1 and len(main) + len(auxiliary) == len(matches)
              and main[0].get("advertised_tool_count") == len(EXPECTED_MAIN_TOOLS)
              and main[0].get("exact_memory_marker_in_system") is True
              and main[0].get("fixture_kind") is None)
    return proved, len(auxiliary)


def _diagnostic_proves_adoption(data: bytes) -> bool:
    return _diagnostic_summary(data)[0]


async def _exercise(client, ticket: str, diagnostic_log: Path, evidence: dict) -> None:
    profile = await client.get("/api/profiles")
    profile.raise_for_status()
    rows = profile.json().get("profiles") or []
    matches = [row for row in rows if row.get("name") == PROFILE]
    expected_home = str(stock.RUNTIME / "home")
    if len(matches) != 1 or matches[0].get("path") != expected_home:
        raise RuntimeError("Default profile home changed")
    active = await client.get("/api/profiles/active"); active.raise_for_status()
    if active.json().get("current") != PROFILE or active.json().get("active") != PROFILE:
        raise RuntimeError("Gateway profile is not exactly default")

    marker_bytes = (MEMORY_ADOPTION_MARKER + "\n").encode()
    memory_path = stock.RUNTIME / "home/memories/MEMORY.md"
    response = await client.post("/api/files/upload-stream",
        data={"path": str(memory_path), "overwrite": "false"},
        files={"file": ("MEMORY.md", marker_bytes, "text/markdown")})
    if response.status_code != 200 or response.json().get("ok") is not True \
            or response.json().get("path") != str(memory_path):
        raise RuntimeError("Owned MEMORY upload was not confirmed")
    read = await client.get("/api/files/read", params={"path": str(memory_path)})
    read.raise_for_status()
    payload = read.json(); data_url = payload.get("data_url")
    try:
        encoded = data_url.split(",", 1)[1] if isinstance(data_url, str) \
            and data_url.startswith("data:text/markdown;base64,") else None
        returned_bytes = base64.b64decode(encoded, validate=True) if encoded else None
    except (ValueError, TypeError):
        returned_bytes = None
    if (payload.get("path") != str(memory_path) or payload.get("size") != len(marker_bytes)
            or returned_bytes != marker_bytes):
        raise RuntimeError("Owned MEMORY readback identity changed")

    offset = diagnostic_log.stat().st_size
    runtime_id = None
    ws_base = stock.HTTPS_ORIGIN.replace("https://", "wss://")
    async with connect(f"{ws_base}/api/ws?ticket={ticket}", origin=stock.HTTPS_ORIGIN,
                       proxy=None) as ws:
        ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
        if ready.get("params", {}).get("type") != "gateway.ready":
            raise RuntimeError("gateway.ready missing")
        probe = Probe(ws, client, {"frames": []})
        created = await probe.rpc("session.create", {"profile": PROFILE,
            "cwd": str(stock.RUNTIME / "tools"), "model": "semreh-fixture", "provider": "custom"})
        runtime_id, _ = binding(created)
        try:
            accepted = await probe.rpc("prompt.submit", {"session_id": runtime_id, "text": PROMPT})
            if accepted.get("status") != "streaming":
                raise RuntimeError("Prompt was not accepted")
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                frame = await probe.receive(deadline)
                params = frame.get("params") or {}
                if params.get("type") == "message.complete" and params.get("session_id") == runtime_id:
                    break
            else:
                raise TimeoutError("Fresh MEMORY-adoption turn did not complete")
        finally:
            if runtime_id:
                closed = await probe.rpc("session.close", {"session_id": runtime_id})
                if closed.get("closed") is not True:
                    raise RuntimeError("Owned session close was not confirmed")
    proved, auxiliary_count = _diagnostic_summary(diagnostic_log.read_bytes()[offset:])
    if not proved:
        raise AssertionError("Model fixture did not prove exactly one MEMORY marker")
    evidence["assertions"] = {"default_profile": True, "managed_memory_readback": True,
        "fresh_session": True, "local_model_only": True,
        "exact_memory_marker_in_system": True,
        "auxiliary_request_count": auxiliary_count}


async def _run(output: Path, pid: int, expected_sha: str, diagnostic_log: Path) -> None:
    config_path, memory_path, original_config = _preflight(pid, expected_sha, diagnostic_log)
    evidence = {"sanitized": True, "backend_sha": stock.PIN, "cleanup_errors": []}
    credentials = json.loads((stock.RUNTIME / "credentials.json").read_text())
    attempted_memory = False
    try:
        async with authenticated(credentials, evidence, base=stock.HTTPS_ORIGIN,
                                 origin=stock.HTTPS_ORIGIN) as (client, ticket):
            try:
                attempted_memory = True
                await _exercise(client, ticket, diagnostic_log, evidence)
            finally:
                if memory_path.exists() and memory_path.read_bytes() == (MEMORY_ADOPTION_MARKER + "\n").encode():
                    deleted = await client.request("DELETE", "/api/files", json={
                        "path": str(memory_path), "recursive": False})
                    if deleted.status_code != 200 or deleted.json().get("ok") is not True:
                        evidence["cleanup_errors"].append("owned memory delete not confirmed")
        if memory_path.exists() or config_path.read_bytes() != original_config:
            evidence["cleanup_errors"].append("memory remained or enabled proof config drifted")
        if evidence["cleanup_errors"]:
            raise AssertionError("Cleanup integrity failed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["outcome"] = "failed"; evidence["error_type"] = type(error).__name__
        evidence["memory_write_attempted"] = attempted_memory
        write_fixture(output, evidence); output.chmod(0o600); raise
    write_fixture(output, evidence); output.chmod(0o600)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stock-backend", action="store_true", required=True)
    parser.add_argument("--expected-backend-pid", type=int, required=True)
    parser.add_argument("--expected-config-sha", required=True)
    parser.add_argument("--model-diagnostic-log", type=Path, required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    asyncio.run(_run(_output_path(args.output), args.expected_backend_pid,
                     args.expected_config_sha, args.model_diagnostic_log))


if __name__ == "__main__": main()
