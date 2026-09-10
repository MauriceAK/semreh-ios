#!/usr/bin/env python3
"""Seed one titled durable session for the owned A2 profile-order UI gate."""

from __future__ import annotations

import argparse
import asyncio
from contextlib import redirect_stdout
import io
import json
import re

from websockets.asyncio.client import connect

import direct_hermes_probe as stock_probe
from direct_hermes_identity_probe import authenticated
from direct_hermes_reasoning_probe import Probe, RPC_TIMEOUT, _json_frame


NAMED = "semreh-goal-scope-8f059a8ae784"
TITLES = {
    "default": "SEMREH_A2_DEFAULT_V1",
    NAMED: "SEMREH_A2_SELECTED_V1",
}
PROMPT = "SEMREH_A2_PROFILE_ORDER_WARMUP_V1"
ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")


def _binding(created):
    if not isinstance(created, dict):
        raise RuntimeError("session.create returned no object")
    runtime = created.get("session_id")
    stored = created.get("stored_session_id") or created.get("session_key")
    if not isinstance(runtime, str) or not runtime:
        raise RuntimeError("session.create omitted runtime identity")
    if not isinstance(stored, str) or not ID.fullmatch(stored):
        raise RuntimeError("session.create omitted bounded durable identity")
    return runtime, stored


def _matching_row(payload, *, profile, stored, title):
    rows = payload.get("sessions") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        raise RuntimeError("profile session list returned no rows")
    matches = [row for row in rows if isinstance(row, dict)
               and (row.get("id") or row.get("session_id")) == stored]
    if len(matches) != 1:
        raise RuntimeError("seed session did not appear exactly once")
    row = matches[0]
    if row.get("profile") != profile or row.get("title") != title:
        raise RuntimeError("seed profile/title readback differed")
    return {"stored_id": stored, "profile": profile, "title": title}


def _validate_fixture(profile):
    selected = None if profile == "default" else profile
    with redirect_stdout(io.StringIO()):
        stock_probe.validate(profile=selected)
    home = stock_probe._fixture_home(selected)
    stock_probe._validate_plugin_config(
        approval_secret_fixture=True, hermes_home=home)
    stock_probe._validate_runtime_skill(
        approval_secret_fixture=True, hermes_home=home)
    stock_probe._validate_runtime_plugins(
        approval_secret_fixture=True, hermes_home=home)


async def seed(profile):
    title = TITLES[profile]
    _validate_fixture(profile)
    credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text())
    evidence = {"cleanup_errors": []}
    base = stock_probe.HTTPS_ORIGIN
    ws_base = base.replace("https://", "wss://")
    runtime = None
    async with authenticated(credentials, evidence, base=base, origin=base) as (client, ticket):
        async with connect(f"{ws_base}/api/ws?ticket={ticket}", origin=base, proxy=None) as ws:
            ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("gateway did not become ready")
            probe = Probe(ws, client, {"frames": []})
            try:
                active = await client.get("/api/profiles/active")
                active.raise_for_status()
                identity = active.json()
                if not isinstance(identity, dict) or identity.get("current") != profile:
                    raise RuntimeError("running server is not the requested profile")
                runtime, stored = _binding(await probe.rpc("session.create", {
                    "profile": profile,
                    "cwd": str(stock_probe.RUNTIME / "tools"),
                    "model": "semreh-fixture",
                    "provider": "custom",
                    "reasoning_effort": "low",
                }))
                start = len(probe.frames)
                accepted = await probe.rpc("prompt.submit", {
                    "session_id": runtime, "text": PROMPT})
                if not isinstance(accepted, dict) or accepted.get("status") not in (
                        "streaming", "queued"):
                    raise RuntimeError("seed prompt was not accepted")
                await probe.wait_terminal(runtime, start)
                await probe.wait_idle(runtime)
                patched = await client.patch(f"/api/sessions/{stored}", json={
                    "profile": profile, "title": title})
                if patched.status_code != 200 or patched.json().get("title") != title:
                    raise RuntimeError("session title update was not acknowledged")
                listed = await client.get("/api/profiles/sessions", params={
                    "profile": profile, "archived": "include", "order": "recent",
                    "limit": 500, "offset": 0})
                listed.raise_for_status()
                return _matching_row(listed.json(), profile=profile,
                                     stored=stored, title=title)
            finally:
                if runtime is not None:
                    try:
                        await probe.rpc("session.close", {"session_id": runtime})
                    except Exception:
                        pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, choices=sorted(TITLES))
    args = parser.parse_args()
    print(json.dumps(asyncio.run(seed(args.profile)), sort_keys=True))
