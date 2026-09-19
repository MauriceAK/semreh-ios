#!/usr/bin/env python3
"""Bounded stock Kanban plugin probe; never enables or dispatches work."""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import time
import uuid
from pathlib import Path

from websockets.asyncio.client import connect

from direct_hermes_capture import write_fixture
import direct_hermes_probe as stock_probe
from direct_hermes_identity_probe import _config_hash, authenticated
from direct_hermes_reasoning_probe import _json_frame, _output_path

API = "/api/plugins/kanban"
CONFIG_SHA = "23079a49d48d26f8299fd41760c917914855e9b410de69d2f0dfcf7100ee6358"
WS_TIMEOUT = 12.0


def _preflight() -> None:
    stock_probe.validate()
    if _config_hash(stock_probe.RUNTIME) != CONFIG_SHA:
        raise RuntimeError("Disposable config hash drifted")
    config = json.loads((stock_probe.RUNTIME / "home/config.yaml").read_text())
    kanban = config.get("kanban")
    if kanban != {"dispatch_in_gateway": False, "review_dispatch": False}:
        raise RuntimeError("Kanban dispatch policy drifted")
    if kanban.get("default_assignee"):
        raise RuntimeError("Unassigned tasks could be auto-assigned")
    source = stock_probe.SOURCE / "plugins/kanban/dashboard/plugin_api.py"
    db_source = stock_probe.SOURCE / "hermes_cli/kanban_db.py"
    if any(path.is_symlink() or path.resolve() != path or not path.is_file()
           for path in (source, db_source)):
        raise RuntimeError("Pinned Kanban source path invalid")
    api_text, db_text = source.read_text(), db_source.read_text()
    for contract in ('@router.get("/boards")', '@router.post("/boards")',
                     '@router.post("/tasks")', '@router.patch("/tasks/{task_id}")',
                     '@router.post("/tasks/{task_id}/comments")',
                     '@router.post("/links")', '@router.websocket("/events")'):
        if contract not in api_text:
            raise RuntimeError("Pinned Kanban route contract drifted")
    if 'result.skipped_unassigned.append(row["id"])' not in db_text:
        raise RuntimeError("Pinned unassigned dispatch guard drifted")


def _task(payload: object) -> dict:
    task = payload.get("task") if isinstance(payload, dict) else None
    if not isinstance(task, dict) or not re.fullmatch(r"t_[A-Za-z0-9]+", str(task.get("id", ""))):
        raise AssertionError("Kanban task response missing canonical identity")
    if task.get("assignee") not in (None, "") or task.get("status") != "triage":
        raise AssertionError("Probe task was not inert and unassigned")
    return task


async def _wait_events(ws, task_ids: set[str]) -> tuple[int, set[str]]:
    deadline = time.monotonic() + WS_TIMEOUT
    kinds: set[str] = set()
    count = 0
    while not ({"created", "edited", "commented", "linked"} <= kinds):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Bounded Kanban event deadline expired")
        frame = _json_frame(await asyncio.wait_for(ws.recv(), remaining))
        events = frame.get("events") if isinstance(frame, dict) else None
        if not isinstance(events, list):
            raise AssertionError("Kanban event envelope malformed")
        for event in events:
            if not isinstance(event, dict) or event.get("task_id") not in task_ids:
                continue
            kind = event.get("kind")
            if isinstance(kind, str):
                kinds.add(kind)
                count += 1
    return count, kinds


async def _exercise(credentials: dict, evidence: dict, *, allow_owned_mutations: bool) -> None:
    async with authenticated(credentials, evidence, base=stock_probe.HTTPS_ORIGIN,
                             origin=stock_probe.HTTPS_ORIGIN) as (client, ticket):
        availability = await client.get(f"{API}/boards")
        if availability.status_code == 404:
            evidence["plugin_available"] = False
            evidence["mutations_performed"] = False
            return
        availability.raise_for_status()
        payload = availability.json()
        if not isinstance(payload, dict) or not isinstance(payload.get("boards"), list):
            raise AssertionError("Kanban availability response malformed")
        evidence["plugin_available"] = True
        if not allow_owned_mutations:
            evidence["mutations_performed"] = False
            evidence["mutation_probe_requires_separate_approval"] = True
            return

        suffix = uuid.uuid4().hex[:12]
        slug = f"semreh-probe-{suffix}"
        title_a = f"SEMREH_KANBAN_INERT_A_{suffix}"
        title_b = f"SEMREH_KANBAN_INERT_B_{suffix}"
        created_board = False
        try:
            response = await client.post(f"{API}/boards", json={
                "slug": slug, "name": f"Semreh Probe {suffix}", "switch": False,
            })
            response.raise_for_status()
            board = response.json().get("board")
            if not isinstance(board, dict) or board.get("slug") != slug:
                raise AssertionError("Kanban board identity mismatch")
            created_board = True

            ws_url = (stock_probe.HTTPS_ORIGIN.replace("https://", "wss://")
                      + f"{API}/events?ticket={ticket}&board={slug}&since=0")
            async with connect(ws_url, origin=stock_probe.HTTPS_ORIGIN, proxy=None) as ws:
                tasks = []
                for title in (title_a, title_b):
                    response = await client.post(f"{API}/tasks", params={"board": slug},
                                                 json={"title": title, "triage": True})
                    response.raise_for_status()
                    tasks.append(_task(response.json()))
                ids = {str(task["id"]) for task in tasks}
                if len(ids) != 2:
                    raise AssertionError("Kanban task identities collided")
                first, second = tasks
                response = await client.patch(f"{API}/tasks/{first['id']}",
                    params={"board": slug}, json={"body": "Synthetic inert probe body"})
                response.raise_for_status()
                _task(response.json())
                response = await client.post(f"{API}/tasks/{first['id']}/comments",
                    params={"board": slug}, json={"author": "semreh-probe",
                                                  "body": "Synthetic inert probe comment"})
                response.raise_for_status()
                response = await client.post(f"{API}/links", params={"board": slug},
                    json={"parent_id": first["id"], "child_id": second["id"]})
                response.raise_for_status()
                event_count, event_kinds = await _wait_events(ws, ids)

                for task in tasks:
                    detail = await client.get(f"{API}/tasks/{task['id']}",
                                              params={"board": slug})
                    detail.raise_for_status()
                    current = _task(detail.json())
                    if current["title"] not in (title_a, title_b):
                        raise AssertionError("Kanban canonical title changed")
                first_detail = (await client.get(f"{API}/tasks/{first['id']}",
                                                 params={"board": slug})).json()
                if (first_detail.get("task") or {}).get("body") != "Synthetic inert probe body":
                    raise AssertionError("Kanban edited body readback missing")
                if len(first_detail.get("comments", [])) != 1:
                    raise AssertionError("Kanban comment readback missing")
                second_detail = (await client.get(f"{API}/tasks/{second['id']}",
                                                  params={"board": slug})).json()
                first_links = first_detail.get("links")
                second_links = second_detail.get("links")
                if (not isinstance(first_links, dict)
                        or first_links.get("children") != [second["id"]]
                        or not isinstance(second_links, dict)
                        or second_links.get("parents") != [first["id"]]):
                    raise AssertionError("Kanban dependency readback missing")
                evidence["assertions"] = {
                    "owned_board_created": True, "inert_unassigned_task_count": 2,
                    "edit_comment_dependency_readback": True,
                    "authenticated_ws_event_count": event_count,
                    "required_ws_event_kinds_seen": sorted(event_kinds & {"created", "edited", "commented", "linked"}),
                    "dispatch_reassign_specify_decompose_not_called": True,
                }
        finally:
            if created_board:
                deleted = await client.delete(f"{API}/boards/{slug}", params={"delete": "true"})
                if deleted.status_code != 200:
                    evidence["cleanup_errors"].append({"operation": "owned_board_delete", "type": "HTTPStatusError"})
                    raise AssertionError("Exact owned board cleanup was not confirmed")


async def _run(output: Path, *, allow_owned_mutations: bool = False) -> None:
    _preflight()
    before = _config_hash(stock_probe.RUNTIME)
    credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text())
    evidence = {"sanitized": True, "backend_sha": stock_probe.PIN,
                "deployment": "owned stock HTTPS fixture", "cleanup_errors": []}
    try:
        await _exercise(credentials, evidence, allow_owned_mutations=allow_owned_mutations)
        if evidence["cleanup_errors"]:
            raise AssertionError("Kanban probe cleanup did not complete cleanly")
        after = _config_hash(stock_probe.RUNTIME)
        evidence["config_sha256_unchanged"] = before == after == CONFIG_SHA
        if not evidence["config_sha256_unchanged"]:
            raise AssertionError("Disposable config changed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["outcome"] = "failed"
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence); output.chmod(0o600)
        raise RuntimeError(f"Kanban probe failed; sanitized evidence retained at {output}") from None
    write_fixture(output, evidence); output.chmod(0o600)
    print(f"Kanban assertions passed; sanitized evidence: {output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stock-backend", action="store_true", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--allow-owned-mutations", action="store_true")
    args = parser.parse_args()
    asyncio.run(_run(
        _output_path(args.output), allow_owned_mutations=args.allow_owned_mutations,
    ))


if __name__ == "__main__":
    main()
