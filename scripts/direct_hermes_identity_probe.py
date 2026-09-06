#!/usr/bin/env python3
"""Bounded live identity/paging probe; not compression or literal TUI proof."""

import argparse
import asyncio
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import time
from contextlib import asynccontextmanager

import httpx
from websockets.asyncio.client import connect

from direct_hermes_capture import write_fixture
import direct_hermes_probe as stock_probe
from direct_hermes_reasoning_probe import (
    BASE, WS_BASE, HTTPS_ORIGIN, PROFILE, TOOLS_CWD, RUNTIME as DEV_RUNTIME, PIN,
    RPC_TIMEOUT, Probe, _json_frame, _output_path, _rest_rows, _row_text,
    _validate_all,
)


@dataclass(frozen=True)
class ProbeFixture:
    runtime: Path
    tools_cwd: Path
    base: str
    ws_base: str
    origin: str
    backend_sha: str
    stock: bool


STOCK_RUNTIME = stock_probe.RUNTIME
STOCK_TOOLS_CWD = STOCK_RUNTIME / "tools"
STOCK_BASE = stock_probe.HTTPS_ORIGIN
STOCK_WS_BASE = STOCK_BASE.replace("https://", "wss://")
STOCK_PIN = stock_probe.PIN


def select_fixture(*, stock_backend: bool, backend_sha: str | None) -> ProbeFixture:
    if stock_backend:
        if backend_sha is not None:
            raise ValueError("--stock-backend cannot be combined with --backend-sha")
        return ProbeFixture(
            runtime=STOCK_RUNTIME,
            tools_cwd=STOCK_TOOLS_CWD,
            base=STOCK_BASE,
            ws_base=STOCK_WS_BASE,
            origin=STOCK_BASE,
            backend_sha=STOCK_PIN,
            stock=True,
        )
    if not backend_sha:
        raise ValueError("--backend-sha is required without --stock-backend")
    return ProbeFixture(
        runtime=DEV_RUNTIME,
        tools_cwd=TOOLS_CWD,
        base=BASE,
        ws_base=WS_BASE,
        origin=HTTPS_ORIGIN,
        backend_sha=backend_sha.lower(),
        stock=False,
    )


def _config_hash(runtime: Path) -> str:
    path = runtime / "home" / "config.yaml"
    if path.is_symlink() or path.resolve() != path or not path.is_file():
        raise RuntimeError("Unexpected disposable config path")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def binding(payload, expected=None):
    runtime = payload.get("session_id")
    aliases = [payload.get(key) for key in ("stored_session_id", "session_key", "resumed")
               if payload.get(key) is not None]
    if not isinstance(runtime, str) or not runtime:
        raise AssertionError("missing runtime identity")
    if not aliases or any(not isinstance(value, str) or not value for value in aliases):
        raise AssertionError("missing durable identity")
    if len(set(aliases)) != 1 or (expected is not None and aliases[0] != expected):
        raise AssertionError("durable aliases changed or disagree")
    return runtime, aliases[0]


def assert_rows(rows, prompts):
    if [row.get("role") for row in rows] != [r for _ in prompts for r in ("user", "assistant")]:
        raise AssertionError("durable role sequence differs")
    if [_row_text(row) for row in rows[::2]] != prompts:
        raise AssertionError("durable prompt sequence differs")
    if any(not _row_text(row).strip() for row in rows[1::2]):
        raise AssertionError("empty durable assistant response")


async def page(client, stored, limit, offset):
    response = await client.get(f"/api/sessions/{stored}/messages", params={
        "profile": PROFILE, "include_compacted": "true", "order": "latest",
        "limit": limit, "offset": offset,
    })
    response.raise_for_status()
    payload = response.json()
    if payload.get("session_id") != stored:
        raise AssertionError("REST canonical ID differs for uncompressed session")
    return _rest_rows(payload)


@asynccontextmanager
async def authenticated(credentials, evidence, *, base=BASE, origin=HTTPS_ORIGIN):
    async with httpx.AsyncClient(base_url=base, trust_env=False, follow_redirects=False) as client:
        login = await client.post("/auth/password-login", json={
            "provider": "basic", **credentials, "next": "",
        })
        if login.status_code not in (200, 302, 303):
            raise RuntimeError("fixture login failed")
        response = await client.post("/api/auth/ws-ticket")
        response.raise_for_status()
        ticket = response.json().get("ticket")
        if not isinstance(ticket, str) or not ticket:
            raise RuntimeError("missing fixture ticket")
        try:
            yield client, ticket
        finally:
            try:
                logout = await client.post("/auth/logout")
                if logout.status_code != 302 or logout.headers.get("location") != "/login":
                    raise AssertionError("logout did not return the source-defined login redirect")
                protected = await client.get("/api/sessions", params={"profile": PROFILE})
                if protected.status_code != 401:
                    raise AssertionError("logout left the fixture client authenticated")
            except Exception as error:
                evidence["cleanup_errors"].append({"operation": "logout", "type": type(error).__name__})


async def exercise(
    credentials,
    evidence,
    *,
    base=BASE,
    ws_base=WS_BASE,
    origin=HTTPS_ORIGIN,
    tools_cwd=TOOLS_CWD,
):
    async with authenticated(credentials, evidence, base=base, origin=origin) as (client, ticket):
        async with connect(f"{ws_base}/api/ws?ticket={ticket}", origin=origin, proxy=None) as ws:
            ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("missing gateway.ready")
            # Keep sanitized frames in memory for terminal matching, but omit them
            # from persisted evidence: session.info can contain full system prompts.
            probe = Probe(ws, client, {"frames": []})
            owned = set()
            prompts = []
            try:
                evidence["phase"] = "fresh unpersisted create and attach"
                created = await probe.rpc("session.create", {
                    "profile": PROFILE, "cwd": str(tools_cwd), "model": "gpt-5",
                    "provider": "custom", "reasoning_effort": "low",
                })
                runtime, stored = binding(created)
                owned.add(runtime)
                evidence["stored_id"] = stored
                absent = await client.get(f"/api/sessions/{stored}/messages", params={
                    "profile": PROFILE, "include_compacted": "true", "order": "latest",
                    "limit": 3, "offset": 0,
                })
                if absent.status_code != 404:
                    raise AssertionError("fresh draft already has a durable transcript resource")
                attached = await probe.rpc("session.resume", {"session_id": stored, "profile": PROFILE})
                attached_runtime, _ = binding(attached, stored)
                if attached_runtime != runtime or attached.get("message_count") != 0:
                    raise AssertionError("unpersisted live attachment was not reused empty")
                evidence["checks"].append("fresh unpersisted attachment reused")

                async def turn(label):
                    evidence["phase"] = label
                    prompt = f"SEMREH_IDENTITY_PROBE {label}"
                    start = len(probe.frames)
                    await probe.rpc("prompt.submit", {"session_id": runtime, "text": prompt})
                    await probe.wait_terminal(runtime, start)
                    await probe.wait_idle(runtime)
                    prompts.append(prompt)
                    rows = await page(client, stored, 100, 0)
                    assert_rows(rows, prompts)
                    evidence["checks"].append(label)

                await turn("fresh first send")
                attached = await probe.rpc("session.resume", {"session_id": stored, "profile": PROFILE})
                if binding(attached, stored)[0] != runtime:
                    raise AssertionError("persisted live attachment was not reused")
                await turn("live resume send")

                for mode, flags in (("cold", {}), ("deferred", {"defer_history": True}),
                                    ("lazy", {"lazy": True})):
                    previous_runtime = runtime
                    closed = await probe.rpc("session.close", {"session_id": runtime})
                    if closed.get("closed") is not True:
                        raise AssertionError("owned runtime close was not confirmed")
                    owned.remove(runtime)
                    evidence["phase"] = f"{mode} resume"
                    started = time.monotonic()
                    resumed = await probe.rpc("session.resume", {
                        "session_id": stored, "profile": PROFILE, **flags,
                    })
                    runtime, _ = binding(resumed, stored)
                    owned.add(runtime)
                    if runtime == previous_runtime:
                        raise AssertionError("closed runtime was reused instead of cold resume")
                    evidence["resume_seconds"][mode] = round(time.monotonic() - started, 4)
                    if mode == "deferred" and (resumed.get("messages") != [] or resumed.get("hydrating") is not True):
                        raise AssertionError("deferred cold response did not declare hydration")
                    if mode == "lazy" and resumed.get("info", {}).get("lazy") is not True:
                        raise AssertionError("lazy watch response did not declare lazy state")
                    # Successful next turn proves deferred hydration / lazy upgrade
                    # is usable; session.history alone can read DB before hydration.
                    await turn(f"{mode} resume send")

                evidence["phase"] = "latest chronological page reconstruction"
                all_rows = await page(client, stored, 100, 0)
                reconstructed = []
                for offset in range(0, len(all_rows), 3):
                    rows = await page(client, stored, 3, offset)
                    reconstructed = rows + reconstructed
                if reconstructed != all_rows:
                    raise AssertionError("latest pages did not prepend into exact canonical history")
                assert_rows(reconstructed, prompts)
                evidence["checks"].append("latest pages reconstruct exact chronological rows")
                evidence["durable_pairs"] = len(prompts)
            finally:
                for runtime_id in owned:
                    try:
                        closed = await probe.rpc("session.close", {"session_id": runtime_id})
                        if closed.get("closed") is not True:
                            raise AssertionError("cleanup close not confirmed")
                    except Exception as error:
                        evidence["cleanup_errors"].append({"operation": "session.close", "type": type(error).__name__})


async def run(output, backend_sha=None, *, stock_backend=False):
    fixture = select_fixture(stock_backend=stock_backend, backend_sha=backend_sha)
    if fixture.stock:
        stock_probe.validate()
    else:
        _validate_all(fixture.backend_sha)
    credentials = json.loads((fixture.runtime / "credentials.json").read_text())
    before = _config_hash(fixture.runtime)
    evidence = {"sanitized": True, "base_pin": STOCK_PIN, "backend_sha": fixture.backend_sha,
                "deployment": fixture.origin, "checks": [], "resume_seconds": {}, "cleanup_errors": [],
                "not_verified": ["compression lineage", "literal TUI/Desktop UI", "physical device"]}
    try:
        await exercise(
            credentials,
            evidence,
            base=fixture.base,
            ws_base=fixture.ws_base,
            origin=fixture.origin,
            tools_cwd=fixture.tools_cwd,
        )
        if evidence["cleanup_errors"]:
            raise AssertionError("fixture cleanup failed")
        if _config_hash(fixture.runtime) != before:
            raise AssertionError("global fixture configuration changed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["outcome"] = "failed"
        evidence["error_type"] = type(error).__name__
        evidence["global_config_unchanged"] = _config_hash(fixture.runtime) == before
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError(f"Identity probe failed; evidence: {output}") from None
    evidence["global_config_unchanged"] = _config_hash(fixture.runtime) == before
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Identity probe passed; evidence: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    backend = parser.add_mutually_exclusive_group(required=True)
    backend.add_argument("--backend-sha")
    backend.add_argument("--stock-backend", action="store_true")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    asyncio.run(run(_output_path(args.output), args.backend_sha, stock_backend=args.stock_backend))
