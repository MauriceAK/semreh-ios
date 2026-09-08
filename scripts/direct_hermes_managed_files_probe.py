#!/usr/bin/env python3
"""One disposable managed-file roundtrip; never memory/provider adoption evidence.

Run only after integrator approval. Writes one unique <=1 KiB Markdown file in
the pinned fixture tools directory, then deletes only that verified owned file.
Atomic upload is not exclusive creation/CAS: stock checks overwrite before rename.
"""
import argparse
import asyncio
import base64
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import re
import uuid

from direct_hermes_capture import write_fixture
from direct_hermes_identity_probe import authenticated
from direct_hermes_reasoning_probe import _output_path
import direct_hermes_probe as stock_probe

CONTENT = "Disposable transport verification.\nUTF-8: café 雪\r\nFinal line.\n".encode()


def guarded_target(name):
    if not re.fullmatch(r"semreh-managed-probe-[0-9a-f]{32}\.md", name):
        raise AssertionError("invalid disposable name")
    root = stock_probe.RUNTIME / "tools"
    target = root / name
    if root.resolve() != root or not root.is_dir() or target.is_symlink():
        raise AssertionError("unsafe disposable root or target")
    if target.resolve() != target or not 0 < len(CONTENT) <= 1024:
        raise AssertionError("unsafe disposable target or payload")
    return target


async def get(client, route, **params):
    response = await client.get(route, params=params)
    if response.status_code != 200:
        raise AssertionError("managed probe read failed")
    return response.json()


def check_listing(payload, root):
    if not isinstance(payload, dict) or payload.get("path") != str(root):
        raise AssertionError("managed listing scope mismatch")
    # Unrestricted authenticated policy is accepted, but this probe still pins
    # every path locally. A different locked root is never bypassed via /api/fs.
    if payload.get("root") not in (None, str(root)) or payload.get("locked_root") != payload.get("root"):
        raise AssertionError("unexpected managed policy root")
    rows = payload.get("entries")
    if not isinstance(rows, list):
        raise AssertionError("invalid managed listing")
    return rows


async def exercise(client, evidence, name=None):
    target = guarded_target(name or f"semreh-managed-probe-{uuid.uuid4().hex}.md")
    profiles = await get(client, "/api/profiles")
    defaults = [row for row in profiles.get("profiles", []) if row.get("name") == "default"]
    if len(defaults) != 1 or defaults[0].get("path") != str(stock_probe.RUNTIME / "home"):
        raise AssertionError("unexpected profile home")
    active = await get(client, "/api/profiles/active")
    if active.get("current") != "default" or active.get("active") != "default":
        raise AssertionError("unexpected running profile")
    rows = check_listing(await get(client, "/api/files", path=str(target.parent)), target.parent)
    if target.exists() or any(row.get("name") == target.name or row.get("path") == str(target) for row in rows):
        raise AssertionError("disposable name collision")
    attempted = False
    owned_identity = None
    evidence.update(cleanup_verified=False, uncertain_leftover=False)
    try:
        guarded_target(target.name)
        if target.exists():
            raise AssertionError("late disposable collision")
        attempted = True
        response = await client.post("/api/files/upload-stream",
            data={"path": str(target), "overwrite": "false"},
            files={"file": (target.name, CONTENT, "text/markdown")})
        if response.status_code != 200:
            raise AssertionError("managed upload failed")
        receipt = response.json()
        if receipt.get("ok") is not True or receipt.get("path") != str(target):
            raise AssertionError("managed upload receipt mismatch")
        guarded_target(target.name)
        if not target.is_file() or target.stat().st_size != len(CONTENT) or target.read_bytes() != CONTENT:
            raise AssertionError("confirmed upload local identity mismatch")
        owned_identity = (target.stat().st_dev, target.stat().st_ino)
        read = await get(client, "/api/files/read", path=str(target))
        expected_url = "data:text/markdown;base64," + base64.b64encode(CONTENT).decode()
        if read.get("path") != str(target) or read.get("name") != target.name or read.get("size") != len(CONTENT) or read.get("data_url") != expected_url:
            raise AssertionError("managed readback mismatch")
        rows = check_listing(await get(client, "/api/files", path=str(target.parent)), target.parent)
        matches = [row for row in rows if row.get("path") == str(target) and row.get("name") == target.name and row.get("is_directory") is False]
        if len(matches) != 1:
            raise AssertionError("uploaded file not uniquely listed")
        evidence.update(roundtrip_verified=True, listing_verified=True,
            byte_count=len(CONTENT), sha256=hashlib.sha256(CONTENT).hexdigest())
    finally:
        if owned_identity is not None and target.exists():
            guarded_target(target.name)
            if not target.is_file() or (target.stat().st_dev, target.stat().st_ino) != owned_identity or target.stat().st_size != len(CONTENT) or target.read_bytes() != CONTENT:
                raise AssertionError("cleanup refused: owned file changed")
            response = await client.request("DELETE", "/api/files", json={"path": str(target), "recursive": False})
            if response.status_code != 200 or response.json().get("ok") is not True or target.exists():
                raise AssertionError("managed cleanup failed")
        evidence["cleanup_verified"] = not target.exists() and not target.is_symlink()
        evidence["uncertain_leftover"] = attempted and owned_identity is None and not evidence["cleanup_verified"]


async def authenticated_exercise(credentials, evidence):
    async with authenticated(credentials, evidence, base=stock_probe.HTTPS_ORIGIN,
                             origin=stock_probe.HTTPS_ORIGIN) as (client, _ticket):
        await exercise(client, evidence)


def run(output):
    with redirect_stdout(io.StringIO()):
        stock_probe.validate()
    credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text())
    evidence = {"sanitized": True, "outcome": "failed", "source_pin": stock_probe.PIN,
                "cleanup_errors": [], "memory_editor_verified": False,
                "provider_adoption_verified": False, "native_ui_verified": False}
    try:
        asyncio.run(authenticated_exercise(credentials, evidence))
        if evidence["cleanup_errors"]:
            raise AssertionError("authentication cleanup failed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError("Managed-file probe failed; see sanitized evidence") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Managed-file probe passed; sanitized evidence: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    run(_output_path(parser.parse_args().output))
