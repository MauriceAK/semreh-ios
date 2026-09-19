#!/usr/bin/env python3
"""Bounded stock Git mutation probe for one fresh disposable local repository.

Integrator review is required before live use. The probe has no remote, commit,
discard, clean, worktree-remove, or arbitrary-tool operation. A successful run
retains its owned repository/session for the integrator's bounded UI check;
failure cleanup moves only that repository under the disposable runtime's tmp.
"""

from __future__ import annotations

import argparse
import asyncio
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import re
import subprocess
import uuid

from websockets.asyncio.client import connect

import direct_hermes_probe as stock_probe
from direct_hermes_capture import write_fixture
from direct_hermes_git_read_probe import get, git, identity, validate_server
from direct_hermes_identity_probe import authenticated
from direct_hermes_reasoning_probe import PROFILE, Probe, RPC_TIMEOUT, _json_frame, _output_path
from direct_hermes_session_mutation_probe import _owned_binding


FILE = "owned.txt"
BASE = b"synthetic baseline\n"
MODIFIED = b"synthetic baseline\nowned change\n"
INITIAL_BRANCH = "semreh-probe"
OTHER_BRANCH = "semreh-probe-alt"
UI_SEED = "SEMREH_SLICE4_GIT_UI_SEED"


def fixture_path(name: str) -> Path:
    if not re.fullmatch(r"semreh-git-mutation-[0-9a-f]{32}", name):
        raise AssertionError("invalid fixture name")
    for parent in (stock_probe.RUNTIME, stock_probe.RUNTIME / "tools", stock_probe.RUNTIME / "tmp"):
        if parent.resolve() != parent or parent.is_symlink() or not parent.is_dir():
            raise AssertionError("unsafe fixture parent")
    path = stock_probe.RUNTIME / "tools" / name
    if path.is_symlink() or path.resolve() != path:
        raise AssertionError("unsafe fixture path")
    return path


def prepare(path: Path) -> tuple[int, int]:
    if path != fixture_path(path.name) or path.exists():
        raise AssertionError("fixture collision")
    if not 0 < len(MODIFIED) <= 1024:
        raise AssertionError("fixture payload exceeds bound")
    path.mkdir(mode=0o700)
    return identity(path)


def seed(path: Path, owner: tuple[int, int]) -> None:
    if path != fixture_path(path.name) or identity(path) != owner:
        raise AssertionError("fixture ownership changed")
    git(path, "init", "--template=", "--initial-branch=" + INITIAL_BRANCH)
    (path / FILE).write_bytes(BASE)
    git(path, "add", "--", FILE)
    git(path, "commit", "--quiet", "--message", "Disposable mutation fixture")
    git(path, "branch", OTHER_BRANCH)
    (path / FILE).write_bytes(MODIFIED)


def preserve_cleanup(path: Path, owner: tuple[int, int]) -> None:
    if path != fixture_path(path.name) or identity(path) != owner:
        raise AssertionError("cleanup ownership mismatch")
    if any(entry.is_symlink() for entry in path.rglob("*")):
        raise AssertionError("cleanup refused symlink artifact")
    destination = stock_probe.RUNTIME / "tmp" / (path.name + "-retired")
    if destination.exists() or destination.is_symlink():
        raise AssertionError("cleanup destination collision")
    path.rename(destination)
    if path.exists() or identity(destination) != owner:
        raise AssertionError("cleanup move not confirmed")


async def post(client, route: str, body: dict) -> dict:
    response = await client.post(route, json=body)
    if response.status_code != 200:
        raise AssertionError("stock Git mutation failed")
    payload = response.json()
    if not isinstance(payload, dict):
        raise AssertionError("stock Git mutation response was not an object")
    return payload


def assert_status(payload: dict, *, branch: str, staged: int, unstaged: int) -> None:
    if not isinstance(payload, dict) or payload.get("branch") != branch:
        raise AssertionError("stock Git status branch mismatch")
    if payload.get("staged") != staged or payload.get("unstaged") != unstaged:
        raise AssertionError("stock Git index/worktree counts mismatch")
    changed = staged or unstaged
    if payload.get("changed") != int(bool(changed)):
        raise AssertionError("stock Git changed count mismatch")
    rows = payload.get("files")
    if changed:
        if not isinstance(rows, list) or len(rows) != 1 or rows[0].get("path") != FILE:
            raise AssertionError("stock Git status escaped the explicit owned file")
    elif rows != []:
        raise AssertionError("clean stock Git status returned changed files")


async def authenticated_exercise(credentials: dict, evidence: dict) -> None:
    base = stock_probe.HTTPS_ORIGIN
    async with authenticated(credentials, evidence, base=base, origin=base) as (client, ticket):
        ws = None
        runtime: str | None = None
        path: Path | None = None
        owner: tuple[int, int] | None = None
        retained = False
        try:
            ws = await connect(
                f"{base.replace('https://', 'wss://')}/api/ws?ticket={ticket}",
                origin=base, proxy=None,
            )
            ready = _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT))
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("stock gateway did not become ready")
            probe = Probe(ws, client, {"frames": []})
            await validate_server(client)
            path = fixture_path("semreh-git-mutation-" + uuid.uuid4().hex)
            owner = prepare(path)
            evidence["cleanup_preserved"] = False
            try:
                seed(path, owner)
                created = await probe.rpc("session.create", {
                    "profile": PROFILE, "cwd": str(path), "model": "semreh-fixture",
                    "provider": "custom", "reasoning_effort": "low",
                })
                candidate = created.get("session_id") if isinstance(created, dict) else None
                if isinstance(candidate, str) and candidate:
                    runtime = candidate  # close a known created runtime even if binding validation fails
                runtime, _stored = _owned_binding(created)
                evidence["session_bound_to_owned_repo"] = True
                start = len(probe.frames)
                accepted = await probe.rpc("prompt.submit", {
                    "session_id": runtime, "text": UI_SEED,
                })
                if not isinstance(accepted, dict) or accepted.get("status") not in (
                    "streaming", "queued"
                ):
                    raise AssertionError("owned UI seed prompt was not accepted")
                await probe.wait_terminal(runtime, start)
                await probe.wait_idle(runtime)
                # Exercise the REST contract without creating another repo.
                await _exercise_prepared(client, path, owner, evidence)
                evidence["owned_repo_path"] = str(path)
                evidence["owned_stored_session_id"] = _stored
                evidence["ui_seed_marker"] = UI_SEED
                evidence["retained_for_ui"] = True
                retained = True
            except Exception:
                preserve_cleanup(path, owner)
                evidence["cleanup_preserved"] = True
                raise
        finally:
            if ws is not None and runtime is not None and not retained:
                try:
                    closed = await probe.rpc("session.close", {"session_id": runtime})
                    if not isinstance(closed, dict) or closed.get("closed") is not True:
                        raise AssertionError("owned session close was not confirmed")
                except Exception as error:
                    evidence["cleanup_errors"].append({
                        "operation": "close_owned_runtime", "type": type(error).__name__
                    })
            if ws is not None:
                await ws.close()


async def _exercise_prepared(client, path: Path, owner: tuple[int, int], evidence: dict) -> None:
    """Run the REST sequence against an already prepared, identity-pinned repo."""
    # Reuse the public exercise implementation without its allocation/cleanup.
    initial = await get(client, "/api/git/status", path=str(path))
    assert_status(initial, branch=INITIAL_BRANCH, staged=0, unstaged=1)
    body = {"path": str(path), "file": FILE}
    if await post(client, "/api/git/review/stage", body) != {"ok": True}:
        raise AssertionError("explicit-file stage acknowledgement mismatch")
    assert_status(await get(client, "/api/git/status", path=str(path)),
                  branch=INITIAL_BRANCH, staged=1, unstaged=0)
    if await post(client, "/api/git/review/unstage", body) != {"ok": True}:
        raise AssertionError("explicit-file unstage acknowledgement mismatch")
    assert_status(await get(client, "/api/git/status", path=str(path)),
                  branch=INITIAL_BRANCH, staged=0, unstaged=1)
    if identity(path) != owner:
        raise AssertionError("fixture ownership changed before clean switch")
    (path / FILE).write_bytes(BASE)
    assert_status(await get(client, "/api/git/status", path=str(path)),
                  branch=INITIAL_BRANCH, staged=0, unstaged=0)
    if await post(client, "/api/git/branch/switch", {
        "path": str(path), "branch": OTHER_BRANCH
    }) != {"branch": OTHER_BRANCH}:
        raise AssertionError("clean branch switch acknowledgement mismatch")
    assert_status(await get(client, "/api/git/status", path=str(path)),
                  branch=OTHER_BRANCH, staged=0, unstaged=0)
    if identity(path) != owner:
        raise AssertionError("fixture ownership changed before UI handoff")
    (path / FILE).write_bytes(MODIFIED)
    assert_status(await get(client, "/api/git/status", path=str(path)),
                  branch=OTHER_BRANCH, staged=0, unstaged=1)
    evidence["contract"] = {
        "fresh_owned_repo": True, "explicit_file_stage": True,
        "explicit_file_unstage": True, "clean_branch_switch": True,
        "index_worktree_readback": True, "remote_operations": 0,
        "discard_or_clean_operations": 0, "server_commit_operations": 0,
        "ui_handoff_has_one_modified_file": True,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    return parser


def run(output: Path) -> None:
    with redirect_stdout(io.StringIO()):
        stock_probe.validate()
    credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text())
    evidence = {
        "outcome": "failed", "sanitized": True, "source_pin": stock_probe.PIN,
        "cleanup_errors": [], "native_ui_verified": False,
    }
    try:
        asyncio.run(authenticated_exercise(credentials, evidence))
        if evidence["cleanup_errors"]:
            raise AssertionError("owned session cleanup failed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError("Git mutation probe failed; see sanitized evidence") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Git mutation probe passed; sanitized evidence: {output}")


if __name__ == "__main__":
    args = build_parser().parse_args()
    run(_output_path(args.output))
