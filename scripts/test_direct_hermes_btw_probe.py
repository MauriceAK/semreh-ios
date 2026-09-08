"""Offline safety and correlation tests for the guarded BTW probe."""

import asyncio
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import AsyncMock, patch

import direct_hermes_btw_probe as probe


class BtwProbeTests(unittest.TestCase):
    def test_route_guard_requires_local_main_and_no_side_override(self):
        with TemporaryDirectory() as temporary:
            runtime = Path(temporary).resolve()
            (runtime / "home").mkdir()
            path = runtime / "home" / "config.yaml"
            valid = {
                "model": {"provider": "custom", "default": "semreh-fixture",
                          "base_url": "http://127.0.0.1:18792/v1"},
                "auxiliary": {"background_review": {"enabled": False}},
            }
            path.write_text(json.dumps(valid), encoding="utf-8")
            probe._assert_local_btw_routes(runtime)
            for drift in (
                {**valid, "auxiliary": {"side_question": {"provider": "personal"}}},
                {**valid, "providers": {"personal": {"api_key": "secret"}}},
                {**valid, "model": {**valid["model"], "base_url": "https://example.test"}},
            ):
                path.write_text(json.dumps(drift), encoding="utf-8")
                with self.assertRaises(RuntimeError):
                    probe._assert_local_btw_routes(runtime)
            path.write_text(json.dumps(valid), encoding="utf-8")
            nested = runtime / "home" / "profiles" / "default"
            nested.mkdir(parents=True)
            (nested / "config.yaml").write_text("{}", encoding="utf-8")
            with self.assertRaises(RuntimeError):
                probe._assert_local_btw_routes(runtime)

    def test_validation_failure_prevents_credentials_and_network(self):
        with patch.object(probe.stock_probe, "validate", side_effect=RuntimeError("bad fixture")), \
                patch.object(probe.Path, "read_text") as read_text, \
                patch.object(probe, "_exercise", new=AsyncMock()) as exercise:
            with self.assertRaisesRegex(RuntimeError, "bad fixture"):
                asyncio.run(probe._run(Path("/tmp/not-written-btw-evidence.json")))
        read_text.assert_not_called()
        exercise.assert_not_awaited()

    def test_btw_completion_requires_session_task_question_and_exact_answer(self):
        class Buffered:
            def __init__(self, frame): self.frames = [frame]
            async def receive(self, _deadline): raise AssertionError("unexpected receive")
        good = {"params": {"type": "btw.complete", "session_id": "runtime-1",
                "payload": {"task_id": "btw_abc", "question": probe.BTW_QUESTION,
                            "text": probe.EXPECTED_ANSWER}}}
        asyncio.run(probe._wait_btw(Buffered(good), "runtime-1", "btw_abc", 0))
        for key, value in (("question", "wrong"), ("text", "wrong")):
            bad = json.loads(json.dumps(good))
            bad["params"]["payload"][key] = value
            with self.assertRaises(AssertionError):
                asyncio.run(probe._wait_btw(Buffered(bad), "runtime-1", "btw_abc", 0))


if __name__ == "__main__":
    unittest.main()
