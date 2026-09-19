#!/usr/bin/env python3
"""Offline tests for the opt-in stabilization smoke helper."""

import asyncio
import json
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import semreh_stabilization_smoke as smoke  # noqa: E402


class StabilizationSmokeTests(unittest.TestCase):
    def test_output_must_be_fresh_direct_evidence_child(self):
        with tempfile.TemporaryDirectory() as directory:
            old_root = smoke.EVIDENCE_ROOT
            smoke.EVIDENCE_ROOT = Path(directory)
            try:
                good = smoke.EVIDENCE_ROOT / "fresh.json"
                self.assertEqual(smoke.guarded_output_path(str(good)), good)
                good.write_text("existing", encoding="utf-8")
                with self.assertRaises(RuntimeError):
                    smoke.guarded_output_path(str(good))
                with self.assertRaises(RuntimeError):
                    smoke.guarded_output_path(str(smoke.EVIDENCE_ROOT / "nested" / "new.json"))
            finally:
                smoke.EVIDENCE_ROOT = old_root

    def test_canonical_rows_require_owned_sequence_and_complete_page(self):
        payload = {
            "session_id": "stored",
            "messages": [
                {"role": "user", "content": smoke.INITIAL_PROMPT},
                {"role": "assistant", "content": smoke.EXPECTED_ACK},
                {"role": "user", "content": smoke.INTERRUPT_PROMPT},
                {"role": "user", "content": smoke.RECOVERY_PROMPT},
                {"role": "assistant", "content": smoke.EXPECTED_ACK},
            ],
            "pagination": {"has_more": False},
        }
        initial = {**payload, "messages": payload["messages"][:2]}
        self.assertEqual(smoke.assert_canonical_rows(
            initial, "stored", after_interrupt=False, after_recovery=False,
        ), 2)
        self.assertEqual(smoke.assert_canonical_rows(
            payload, "stored", after_interrupt=True, after_recovery=True,
        ), 5)
        with self.assertRaises(AssertionError):
            smoke.assert_canonical_rows(
                {**payload, "session_id": "other"}, "stored",
                after_interrupt=True, after_recovery=True,
            )
        with self.assertRaises(AssertionError):
            smoke.assert_canonical_rows(
                {**payload, "pagination": {"has_more": True}}, "stored",
                after_interrupt=True, after_recovery=True,
            )
        duplicate = {**payload, "messages": [payload["messages"][0], *payload["messages"]]}
        with self.assertRaises(AssertionError):
            smoke.assert_canonical_rows(
                duplicate, "stored", after_interrupt=True, after_recovery=True,
            )

    def test_model_inventory_accepts_only_documented_owned_fixture_modes(self):
        base = [{"id": "semreh-fixture", "owned_by": "local-test"}]
        self.assertTrue(smoke.valid_model_inventory(base))
        self.assertTrue(smoke.valid_model_inventory(
            [*base, {"id": "gpt-5", "owned_by": "local-test"}],
        ))
        self.assertFalse(smoke.valid_model_inventory(
            [*base, {"id": "gpt-5", "owned_by": "other"}],
        ))
        self.assertFalse(smoke.valid_model_inventory(
            [*base, {"id": "unexpected", "owned_by": "local-test"}],
        ))

    def test_rpc_buffers_terminal_before_ack_and_matches_status(self):
        class FakeWebSocket:
            def __init__(self):
                self.frames = [
                    {"method": "event", "params": {"type": "message.complete", "session_id": "runtime", "payload": {"status": "complete"}}},
                    {"id": 1, "result": {"accepted": True}},
                ]

            async def send(self, _value):
                return None

            async def recv(self):
                return json.dumps(self.frames.pop(0))

        async def exercise():
            rpc = smoke.RPC(FakeWebSocket())
            self.assertEqual(await rpc.call("prompt.submit", {}), {"accepted": True})
            await rpc.wait_terminal("runtime", "complete")

        asyncio.run(exercise())

    def test_evidence_writer_rejects_nonaggregate_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            evidence = {"checks": {"ok": True}, "counts": {"rows": 2}, "latencies_ms": {"turn": 1}}
            smoke.write_evidence(path, evidence)
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), evidence)
            with self.assertRaises(RuntimeError):
                smoke.write_evidence(Path(directory) / "bad.json", {**evidence, "frames": []})

    def test_run_writes_aggregate_state_when_exercise_fails(self):
        async def failing_exercise(evidence):
            evidence["checks"]["fixture_policy"] = True
            raise RuntimeError("not persisted")

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "failed.json"
            original = smoke._exercise_smoke
            smoke._exercise_smoke = failing_exercise
            try:
                with self.assertRaises(RuntimeError):
                    asyncio.run(smoke.run_smoke(path))
            finally:
                smoke._exercise_smoke = original
            saved = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(set(saved), {"checks", "counts", "latencies_ms"})
            self.assertNotIn("error", saved)


if __name__ == "__main__":
    unittest.main()
