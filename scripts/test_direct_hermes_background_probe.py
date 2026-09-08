"""Offline safety and correlation tests for the guarded background probe."""

import asyncio
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import AsyncMock, patch

import direct_hermes_background_probe as probe


class BackgroundProbeTests(unittest.TestCase):
    def test_route_guard_requires_exact_hash_local_model_and_disabled_features(self):
        with TemporaryDirectory() as temporary:
            runtime = Path(temporary).resolve()
            (runtime / "home").mkdir()
            path = runtime / "home" / "config.yaml"
            valid = {
                "model": {"provider": "custom", "default": "semreh-fixture",
                          "base_url": "http://127.0.0.1:18792/v1"},
                "auxiliary": {"background_review": {"enabled": False}},
                "memory": {"memory_enabled": False, "user_profile_enabled": False,
                           "provider": ""},
                "tools": {"tool_search": {"enabled": "off"}},
            }
            path.write_text(json.dumps(valid), encoding="utf-8")
            with patch.object(probe, "EXPECTED_CONFIG_SHA256", probe._config_hash(runtime)):
                probe._assert_local_background_routes(runtime)
                for drift in (
                    {**valid, "auxiliary": {"background_review": {"enabled": True}}},
                    {**valid, "providers": {"personal": {"api_key": "secret"}}},
                    {**valid, "model": {**valid["model"],
                                        "base_url": "https://example.test"}},
                    {**valid, "tools": {"tool_search": {"enabled": "on"}}},
                ):
                    path.write_text(json.dumps(drift), encoding="utf-8")
                    with self.assertRaises(RuntimeError):
                        probe._assert_local_background_routes(runtime)

    def test_validation_failure_prevents_credentials_and_network(self):
        with patch.object(probe.stock_probe, "validate", side_effect=RuntimeError("bad fixture")), \
                patch.object(probe.Path, "read_text") as read_text, \
                patch.object(probe, "_exercise", new=AsyncMock()) as exercise:
            with self.assertRaisesRegex(RuntimeError, "bad fixture"):
                asyncio.run(probe._run(Path("/tmp/not-written-background-evidence.json")))
        read_text.assert_not_called()
        exercise.assert_not_awaited()

    def test_completion_requires_parent_task_and_exact_answer(self):
        class Buffered:
            def __init__(self, frames): self.frames = frames
            async def receive(self, _deadline): raise AssertionError("unexpected receive")

        task_ids = {"bg_alpha", "bg_beta"}
        good = [{"params": {"type": "background.complete", "session_id": "runtime-1",
                 "payload": {"task_id": task_id, "text": probe.EXPECTED_ANSWER}}}
                for task_id in task_ids]
        matched = asyncio.run(probe._wait_background_completions(
            Buffered(good), "runtime-1", task_ids, 0
        ))
        self.assertEqual(matched, task_ids)
        bad = json.loads(json.dumps(good))
        bad[0]["params"]["payload"]["text"] = "wrong"
        with self.assertRaises(AssertionError):
            asyncio.run(probe._wait_background_completions(
                Buffered(bad), "runtime-1", task_ids, 0
            ))


if __name__ == "__main__":
    unittest.main()
