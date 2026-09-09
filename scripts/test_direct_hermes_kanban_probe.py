"""Offline guards for the bounded Kanban plugin probe."""

import asyncio
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import direct_hermes_kanban_probe as probe


class KanbanProbeTests(unittest.TestCase):
    def test_preflight_requires_frozen_nondispatch_config_and_source_guards(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            runtime = root / "runtime"
            source = root / "source"
            (runtime / "home").mkdir(parents=True)
            (source / "plugins/kanban/dashboard").mkdir(parents=True)
            (source / "hermes_cli").mkdir()
            config = {
                "kanban": {"dispatch_in_gateway": False, "review_dispatch": False}
            }
            config_path = runtime / "home/config.yaml"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            contracts = "\n".join((
                '@router.get("/boards")', '@router.post("/boards")',
                '@router.post("/tasks")', '@router.patch("/tasks/{task_id}")',
                '@router.post("/tasks/{task_id}/comments")',
                '@router.post("/links")', '@router.websocket("/events")',
            ))
            (source / "plugins/kanban/dashboard/plugin_api.py").write_text(
                contracts, encoding="utf-8"
            )
            (source / "hermes_cli/kanban_db.py").write_text(
                'result.skipped_unassigned.append(row["id"])', encoding="utf-8"
            )
            with patch.object(probe.stock_probe, "RUNTIME", runtime), \
                    patch.object(probe.stock_probe, "SOURCE", source), \
                    patch.object(probe.stock_probe, "validate"), \
                    patch.object(probe, "CONFIG_SHA", probe._config_hash(runtime)):
                probe._preflight()
                config["kanban"]["dispatch_in_gateway"] = True
                config_path.write_text(json.dumps(config), encoding="utf-8")
                with self.assertRaises(RuntimeError):
                    probe._preflight()

    def test_task_must_be_triage_and_unassigned(self):
        task = probe._task({"task": {"id": "t_abc123", "status": "triage", "assignee": None}})
        self.assertEqual(task["id"], "t_abc123")
        for changed in ({"status": "ready", "assignee": None},
                        {"status": "triage", "assignee": "default"}):
            with self.assertRaises(AssertionError):
                probe._task({"task": {"id": "t_abc123", **changed}})

    def test_event_correlation_requires_all_safe_mutation_kinds(self):
        class Socket:
            def __init__(self):
                self.frames = [
                    '{"events":[{"task_id":"foreign","kind":"created"},'
                    '{"task_id":"t_a","kind":"created"},{"task_id":"t_b","kind":"created"},'
                    '{"task_id":"t_a","kind":"edited"},{"task_id":"t_a","kind":"commented"},'
                    '{"task_id":"t_b","kind":"linked"}]}'
                ]
            async def recv(self): return self.frames.pop(0)
        count, kinds = asyncio.run(probe._wait_events(Socket(), {"t_a", "t_b"}))
        self.assertEqual(count, 5)
        self.assertTrue({"created", "edited", "commented", "linked"} <= kinds)


if __name__ == "__main__":
    unittest.main()
