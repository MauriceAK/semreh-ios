#!/usr/bin/env python3
"""Bounded stock Git READ probe. Integrator review required before live use.

Creates one UUID-named tools repository, commits one tiny baseline locally, then
adds staged and unstaged edits. No remotes or server mutation endpoints. Cleanup
preserves the exact owned repository by moving it to runtime/tmp, never deleting
a tree. This is transport evidence, not native UI or Git-write migration proof.
"""
import argparse
import asyncio
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import uuid

from direct_hermes_capture import write_fixture
from direct_hermes_identity_probe import authenticated
from direct_hermes_reasoning_probe import _output_path
import direct_hermes_probe as stock_probe

BASE = b"baseline\n"
STAGED = BASE + "staged café\n".encode()
WORKTREE = STAGED + "unstaged 雪\n".encode()
FILE = "transport.md"


def fixture_path(name):
    if not re.fullmatch(r"semreh-git-read-[0-9a-f]{32}", name):
        raise AssertionError("invalid fixture name")
    for parent in (stock_probe.RUNTIME, stock_probe.RUNTIME / "tools", stock_probe.RUNTIME / "tmp"):
        if parent.resolve() != parent or parent.is_symlink() or not parent.is_dir():
            raise AssertionError("unsafe fixture parent")
    path = stock_probe.RUNTIME / "tools" / name
    if path.is_symlink() or path.resolve() != path:
        raise AssertionError("unsafe fixture path")
    return path


def identity(path):
    value = path.stat()
    return value.st_dev, value.st_ino


def git(path, *args):
    # Ignore user/system Git configuration and inherited GIT_* routing entirely.
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
           "TMPDIR": str(stock_probe.RUNTIME / "tmp")}
    result = subprocess.run(["/usr/bin/git", "-c", "core.hooksPath=/dev/null",
        "-c", "commit.gpgsign=false", "-c", "user.name=Semreh Fixture",
        "-c", "user.email=fixture@example.invalid", "-C", str(path), *args],
        env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
    if result.returncode:
        raise AssertionError("local fixture Git preparation failed")


def prepare(path):
    if path != fixture_path(path.name) or path.exists():
        raise AssertionError("fixture collision")
    if not 0 < len(WORKTREE) <= 1024:
        raise AssertionError("fixture payload exceeds bound")
    path.mkdir(mode=0o700)
    return identity(path)


def seed(path, owner):
    if path != fixture_path(path.name) or identity(path) != owner:
        raise AssertionError("fixture ownership changed")
    git(path, "init", "--template=", "--initial-branch=semreh-probe")
    (path / FILE).write_bytes(BASE)
    git(path, "add", "--", FILE)
    git(path, "commit", "--quiet", "--message", "Disposable read fixture")
    (path / FILE).write_bytes(STAGED)
    git(path, "add", "--", FILE)
    (path / FILE).write_bytes(WORKTREE)


def preserve_cleanup(path, owner):
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


async def get(client, route, **params):
    response = await client.get(route, params=params)
    if response.status_code != 200:
        raise AssertionError("stock Git read failed")
    return response.json()


async def validate_server(client):
    inventory = await get(client, "/api/profiles")
    rows = inventory.get("profiles", [])
    defaults = [row for row in rows if row.get("name") == "default"]
    if len(defaults) != 1 or defaults[0].get("path") != str(stock_probe.RUNTIME / "home"):
        raise AssertionError("unexpected profile home")
    active = await get(client, "/api/profiles/active")
    if active.get("current") != "default" or active.get("active") != "default":
        raise AssertionError("unexpected running profile")


async def read_repo(client, path, evidence):
    trees = await get(client, "/api/git/worktrees", path=str(path))
    if not any(row.get("path") == str(path) for row in trees.get("worktrees", [])):
        raise AssertionError("worktree root not proven")
    status = await get(client, "/api/git/status", path=str(path))
    rows = status.get("files", []) if isinstance(status, dict) else []
    if status.get("branch") != "semreh-probe" or status.get("changed") != 1 or len(rows) != 1:
        raise AssertionError("stock status shape mismatch")
    if rows[0].get("path") != FILE or rows[0].get("staged") is not True or rows[0].get("unstaged") is not True:
        raise AssertionError("stock status flags mismatch")
    review = await get(client, "/api/git/review/list", path=str(path), scope="uncommitted")
    files = review.get("files", [])
    if len(files) != 1 or files[0].get("path") != FILE or files[0].get("staged") is not True or files[0].get("added") != 2 or files[0].get("removed") != 0:
        raise AssertionError("review inventory mismatch")
    branches = await get(client, "/api/git/branches", path=str(path))
    if not any(row.get("name") == "semreh-probe" and row.get("isRemote") is False for row in branches.get("branches", [])):
        raise AssertionError("stock branches shape mismatch")
    for staged, expected, forbidden in ((True, "+staged café", "+unstaged 雪"), (False, "+unstaged 雪", "+staged café")):
        result = await get(client, "/api/git/review/diff", path=str(path), file=FILE,
                           scope="uncommitted", staged=str(staged).lower())
        diff = result.get("diff")
        if not isinstance(diff, str) or expected not in diff or forbidden in diff or len(diff.encode()) > 4096:
            raise AssertionError("staged/unstaged diff separation failed")
        evidence["staged_diff" if staged else "unstaged_diff"] = {
            "verified": True, "bytes": len(diff.encode()), "sha256": hashlib.sha256(diff.encode()).hexdigest()}
    evidence["stock_read_shapes_verified"] = True


async def exercise(client, evidence, name=None):
    await validate_server(client)
    path = fixture_path(name or "semreh-git-read-" + uuid.uuid4().hex)
    owner = prepare(path)
    evidence.update(fixture_id=path.name, cleanup_preserved=False)
    try:
        seed(path, owner)
        await read_repo(client, path, evidence)
    finally:
        preserve_cleanup(path, owner)
        evidence["cleanup_preserved"] = True


async def authenticated_exercise(credentials, evidence):
    async with authenticated(credentials, evidence, base=stock_probe.HTTPS_ORIGIN,
                             origin=stock_probe.HTTPS_ORIGIN) as (client, _ticket):
        await exercise(client, evidence)


def run(output):
    with redirect_stdout(io.StringIO()):
        stock_probe.validate()
    credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text())
    evidence = {"outcome": "failed", "sanitized": True, "source_pin": stock_probe.PIN,
                "cleanup_errors": [], "server_mutations": 0, "native_ui_verified": False,
                "session_to_root_mapping_verified": False, "git_write_migration_verified": False}
    try:
        asyncio.run(authenticated_exercise(credentials, evidence))
        if evidence["cleanup_errors"]:
            raise AssertionError("authentication cleanup failed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError("Git read probe failed; see sanitized evidence") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Git read probe passed; sanitized evidence: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    run(_output_path(parser.parse_args().output))
