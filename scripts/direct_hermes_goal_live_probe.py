#!/usr/bin/env python3
"""Reproduce stock /goal profile scope on the existing owned gateway only."""

from __future__ import annotations
import argparse, asyncio, hashlib, json, re, sqlite3, subprocess, uuid
from pathlib import Path
import yaml
from websockets.asyncio.client import connect
from direct_hermes_capture import write_fixture
import direct_hermes_probe as stock
from direct_hermes_identity_probe import _config_hash, authenticated, binding
from direct_hermes_reasoning_probe import RPC_TIMEOUT, Probe, _json_frame, _output_path

# Current contained fixture includes the explicitly local-only goal judge. The
# original scope-reproduction receipt records its earlier configuration hash.
CONFIG_SHA = "d0a13a4e266aaa416e3b025e5fa6029377a1c964f0275712710eb1ab7afba9a8"
OWNED_HOME = (stock.RUNTIME / "home/home").resolve()
PROFILES_ROOT = (stock.RUNTIME / "home/profiles").resolve()
WRAPPERS_ROOT = (OWNED_HOME / ".local/bin").resolve()


def _backend_guard(pid: int) -> None:
    if pid <= 1:
        raise RuntimeError("Expected backend PID is invalid")
    command = subprocess.run(["ps", "eww", "-p", str(pid), "-o", "command="],
        check=True, capture_output=True, text=True, timeout=5).stdout
    if str(stock.PYTHON) not in command or "hermes_cli.main serve" not in command:
        raise RuntimeError("PID is not the owned stock serve process")
    env = dict(re.findall(r"(?:^|\s)([A-Z][A-Z0-9_]*)=([^\s]*)", command))
    if env.get("HOME") != str(OWNED_HOME) or env.get("HERMES_HOME") != str(stock.RUNTIME / "home"):
        raise RuntimeError("Owned serve HOME/HERMES_HOME precondition failed")
    listener = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid),
        "-iTCP:18791", "-sTCP:LISTEN", "-t"], check=True,
        capture_output=True, text=True, timeout=5).stdout.split()
    if listener != [str(pid)]:
        raise RuntimeError("PID is not sole owned listener on 18791")
    cwd = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
        check=True, capture_output=True, text=True, timeout=5).stdout.splitlines()
    if "n" + str((stock.RUNTIME / "tools").resolve()) not in cwd:
        raise RuntimeError("Owned serve cwd drifted")


def _tree_digest(root: Path) -> tuple[int, str]:
    if root.is_symlink() or not root.is_dir() or stock.RUNTIME.resolve() not in root.resolve().parents:
        raise RuntimeError("Owned skill tree invalid")
    digest = hashlib.sha256(); count = 0
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or (not path.is_file() and not path.is_dir()):
            raise RuntimeError("Owned skill tree contains unsupported entries")
        if path.is_file():
            rel = path.relative_to(root).as_posix().encode()
            digest.update(len(rel).to_bytes(4, "big") + rel + hashlib.sha256(path.read_bytes()).digest())
            count += 1
    return count, digest.hexdigest()


def _preflight(pid: int) -> tuple[int, str]:
    stock.validate(); _backend_guard(pid)
    stock._validate_runtime_plugins(approval_secret_fixture=True)
    stock._validate_plugin_config(approval_secret_fixture=True)
    stock._validate_runtime_skill(approval_secret_fixture=True)
    if _config_hash(stock.RUNTIME) != CONFIG_SHA:
        raise RuntimeError("Disposable config drifted")
    cfg = json.loads((stock.RUNTIME / "home/config.yaml").read_text())
    if cfg.get("quick_commands") not in (None, {}) or cfg.get("tools") != {"tool_search": {"enabled": "off"}}:
        raise RuntimeError("Command/tool policy drifted")
    if cfg.get("memory") != {"memory_enabled": False, "user_profile_enabled": False, "provider": ""}:
        raise RuntimeError("Memory policy drifted")
    if sorted(p.name for p in (stock.RUNTIME / "home/plugins").iterdir()) != [stock.BLOCKING_FIXTURE_PLUGIN_ID]:
        raise RuntimeError("Plugin allowlist drifted")
    clone_sensitive = (
        stock.RUNTIME / "home/.env",
        stock.RUNTIME / "home/SOUL.md",
        stock.RUNTIME / "home/memories/MEMORY.md",
        stock.RUNTIME / "home/memories/USER.md",
    )
    if any(path.is_symlink() for path in clone_sensitive):
        raise RuntimeError("Profile clone source contains a symlinked identity file")
    if ((stock.RUNTIME / "home/.env").exists()
            or (stock.RUNTIME / "home/memories/MEMORY.md").exists()
            or (stock.RUNTIME / "home/memories/USER.md").exists()):
        raise RuntimeError("Profile clone source contains credential or memory state")
    if any(stock.RUNTIME.resolve() not in p.parents for p in (OWNED_HOME, PROFILES_ROOT, WRAPPERS_ROOT)):
        raise RuntimeError("Owned profile roots escaped runtime")
    return _tree_digest(stock.RUNTIME / "home/skills")


def _meta(db_path: Path, key: str) -> str | None:
    if not db_path.exists(): return None
    if db_path.is_symlink() or db_path.resolve() != db_path or stock.RUNTIME.resolve() not in db_path.parents:
        raise RuntimeError("Read-only DB escaped owned runtime")
    with sqlite3.connect(f"file:{db_path.as_posix()}?mode=ro", uri=True) as db:
        row = db.execute("SELECT value FROM state_meta WHERE key = ?", (key,)).fetchone()
    return str(row[0]) if row else None


def _matches(raw: str | None, marker: str, status: str) -> bool:
    try: value = json.loads(raw or "")
    except (TypeError, ValueError): return False
    return value.get("goal") == marker and value.get("status") == status


def _migrated_clone_matches(source_path: Path, clone_path: Path) -> bool:
    source = yaml.safe_load(source_path.read_text()) or {}
    clone = yaml.safe_load(clone_path.read_text()) or {}
    if (not isinstance(source, dict) or not isinstance(clone, dict)
            or "agent" in source or "_config_version" in source
            or clone.get("agent") != {} or clone.get("_config_version") != 39):
        return False
    clone = dict(clone)
    del clone["agent"]
    del clone["_config_version"]
    return clone == source


async def _exercise(credentials: dict, evidence: dict, source_skills: tuple[int, str]) -> None:
    suffix = uuid.uuid4().hex[:12]
    profile, marker = "semreh-goal-scope-" + suffix, "SEMREH_OWNED_GOAL_SCOPE_" + suffix
    profile_path, wrapper_path = PROFILES_ROOT / profile, WRAPPERS_ROOT / profile
    if (profile_path.exists() or profile_path.is_symlink()
            or wrapper_path.exists() or wrapper_path.is_symlink()):
        raise RuntimeError("Profile identity not fresh")
    runtime_id = None; goal_confirmed = False
    evidence["retained_owned_profile_path"] = str(profile_path)
    evidence["retained_owned_wrapper_path"] = str(wrapper_path)
    evidence["stage"] = "authenticate"
    async with authenticated(credentials, evidence, base=stock.HTTPS_ORIGIN,
                             origin=stock.HTTPS_ORIGIN) as (client, ticket):
        evidence["stage"] = "profile_create"
        created_profile = await client.post("/api/profiles", json={
            "name": profile, "clone_from": "default", "clone_all": False,
            "no_skills": False, "description": "Owned inert scope probe",
            "mcp_servers": [], "keep_skills": [], "hub_skills": []})
        created_profile.raise_for_status()
        if created_profile.json().get("path") != str(profile_path) or not profile_path.is_dir():
            raise AssertionError("Profile path mismatch")
        if not wrapper_path.is_file() or wrapper_path.is_symlink():
            raise AssertionError("Owned wrapper missing or unsafe")
        evidence["stage"] = "profile_validate"
        if not _migrated_clone_matches(stock.RUNTIME / "home/config.yaml", profile_path / "config.yaml"):
            raise AssertionError("Cloned config semantic migration differs")
        profile_env = profile_path / ".env"
        if (not profile_env.is_file() or profile_env.is_symlink()
                or any(line.strip() and not line.lstrip().startswith("#")
                       for line in profile_env.read_text().splitlines())):
            raise AssertionError("Selected profile environment is not inert")
        if _tree_digest(profile_path / "skills") != source_skills:
            raise AssertionError("Cloned owned skill tree differs")
        evidence["cloned_skill_file_count"] = source_skills[0]
        evidence["stage"] = "gateway_connect"
        ws_base = stock.HTTPS_ORIGIN.replace("https://", "wss://")
        async with connect(f"{ws_base}/api/ws?ticket={ticket}", origin=stock.HTTPS_ORIGIN, proxy=None) as ws:
            if _json_frame(await asyncio.wait_for(ws.recv(), RPC_TIMEOUT)).get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("gateway.ready missing")
            rpc = Probe(ws, client, {"frames": []})
            evidence["stage"] = "session_create"
            created = await rpc.rpc("session.create", {"profile": profile,
                "cwd": str(stock.RUNTIME / "tools"), "model": "semreh-fixture", "provider": "custom"})
            runtime_id, session_key = binding(created); key = "goal:" + session_key
            try:
                evidence["stage"] = "goal_set"
                result = await rpc.rpc("command.dispatch", {"session_id": runtime_id, "name": "goal", "arg": marker})
                if result.get("type") != "send" or result.get("message") != marker:
                    raise AssertionError("Goal set receipt changed")
                goal_confirmed = True
                default_db, selected_db = stock.RUNTIME / "home/state.db", profile_path / "state.db"
                if not _matches(_meta(default_db, key), marker, "active") or _meta(selected_db, key) is not None:
                    raise AssertionError("Default-vs-selected scope defect not reproduced")
                status = await rpc.rpc("command.dispatch", {
                    "session_id": runtime_id, "name": "goal", "arg": "status",
                })
                if (status.get("type") != "exec" or marker not in str(status.get("output", ""))
                        or "active" not in str(status.get("output", "")).lower()):
                    raise AssertionError("Goal status receipt changed")
                paused = await rpc.rpc("command.dispatch", {"session_id": runtime_id, "name": "goal", "arg": "pause"})
                if paused.get("type") != "exec" or not _matches(_meta(default_db, key), marker, "paused"):
                    raise AssertionError("Goal pause readback changed")
                evidence["assertions"] = {"no_prompt_submit": True, "set_send_not_forwarded": True,
                    "status_exec_canonical_goal": True, "pause_exec": True,
                    "goal_landed_default_db": True,
                    "goal_absent_selected_db": True, "owned_profile_retained": True}
                evidence["stage"] = "cleanup"
            finally:
                try:
                    if goal_confirmed:
                        cleared = await rpc.rpc("command.dispatch", {"session_id": runtime_id, "name": "goal", "arg": "clear"})
                        if (cleared.get("type") != "exec"
                                or not _matches(_meta(stock.RUNTIME / "home/state.db", key), marker, "cleared")
                                or _meta(profile_path / "state.db", key) is not None):
                            raise AssertionError("Owned goal clear not confirmed")
                finally:
                    if runtime_id:
                        closed = await rpc.rpc("session.close", {"session_id": runtime_id})
                        if closed.get("closed") is not True:
                            raise AssertionError("Owned runtime close not confirmed")


async def _run(output: Path, pid: int) -> None:
    skills = _preflight(pid)
    credentials = json.loads((stock.RUNTIME / "credentials.json").read_text())
    evidence = {"sanitized": True, "backend_sha": stock.PIN,
                "deployment": "existing owned HTTPS gateway", "cleanup_errors": []}
    try:
        await _exercise(credentials, evidence, skills)
        if evidence["cleanup_errors"] or _config_hash(stock.RUNTIME) != CONFIG_SHA:
            raise AssertionError("Cleanup/config check failed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["outcome"] = "failed"; evidence["error_type"] = type(error).__name__
        evidence["failed_stage"] = evidence.get("stage", "preflight")
        evidence["config_unchanged_on_failure"] = _config_hash(stock.RUNTIME) == CONFIG_SHA
        write_fixture(output, evidence); output.chmod(0o600)
        raise RuntimeError(f"Goal probe failed; sanitized evidence retained at {output}") from None
    write_fixture(output, evidence); output.chmod(0o600)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stock-backend", action="store_true", required=True)
    parser.add_argument("--expected-backend-pid", type=int, required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args(); asyncio.run(_run(_output_path(args.output), args.expected_backend_pid))
if __name__ == "__main__": main()
