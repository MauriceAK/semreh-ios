#!/usr/bin/env python3
"""Pure contract tests for the bounded stock-Hermes compatibility probe."""

import sys
import tempfile
import unittest
import asyncio
import json
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import direct_hermes_stock_compatibility as probe  # noqa: E402


class StockCompatibilityTests(unittest.TestCase):
    def test_reasoning_read_accepts_only_stock_shape(self):
        self.assertEqual(
            probe.classify_reasoning_read({"value": "medium", "display": "show"}),
            {"value": "medium", "display": "show", "contract": "stock-read-v1"},
        )
        rejected = [
            None,
            {"value": "extreme", "display": "show"},
            {"value": "low", "display": "sometimes"},
            {"value": "low", "display": "show", "session_reasoning_contract": 1},
            {"value": "low", "display": "show", "persisted": True},
            {"value": "low", "display": "show", "deferred": False},
        ]
        for value in rejected:
            with self.subTest(value=value), self.assertRaises(AssertionError):
                probe.classify_reasoning_read(value)

    def test_rest_pair_requires_exact_identity_order_content_and_pagination(self):
        payload = {
            "session_id": "stored",
            "messages": [
                {"role": "user", "content": probe.PROMPT},
                {"role": "assistant", "content": "SEMREH_SLICE1_ACK"},
            ],
            "pagination": {"limit": 10, "offset": 0, "has_more": False},
        }
        self.assertEqual(probe.assert_rest_pair(payload, "stored")["row_count"], 2)
        rejected = [
            {**payload, "session_id": "wrong"},
            {**payload, "messages": payload["messages"][:1]},
            {**payload, "messages": list(reversed(payload["messages"]))},
            {**payload, "messages": [{"role": "user", "content": "wrong"}, payload["messages"][1]]},
            {**payload, "messages": [payload["messages"][0], {"role": "assistant", "content": "wrong-ack"}]},
            {key: value for key, value in payload.items() if key != "pagination"},
        ]
        for value in rejected:
            with self.subTest(value=value), self.assertRaises(AssertionError):
                probe.assert_rest_pair(value, "stored")

    def test_output_guard_rejects_outside_symlink_and_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = probe.EVIDENCE_ROOT
            probe.EVIDENCE_ROOT = root
            try:
                good = root / "stock.json"
                self.assertEqual(probe.output_path(good), good)
                good.write_text("existing")
                with self.assertRaises(RuntimeError):
                    probe.output_path(good)
                outside = root.parent / "outside-stock.json"
                with self.assertRaises(RuntimeError):
                    probe.output_path(outside)
                target = root / "target"
                target.write_text("target")
                link = root / "link.json"
                link.symlink_to(target)
                with self.assertRaises(RuntimeError):
                    probe.output_path(link)
            finally:
                probe.EVIDENCE_ROOT = original

    def test_final_phase_cannot_report_success_after_cleanup_error(self):
        self.assertEqual(
            probe.final_phase(turn_succeeded=True, cleanup_errors=[], config_unchanged=True),
            "complete",
        )
        self.assertEqual(
            probe.final_phase(turn_succeeded=True, cleanup_errors=[{"operation": "logout"}], config_unchanged=True),
            "failed",
        )
        self.assertEqual(
            probe.final_phase(turn_succeeded=True, cleanup_errors=[], config_unchanged=False),
            "failed",
        )

    def test_categorical_failure_evidence_avoids_config_sanitization(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "failure.json"
            probe.write_categorical_failure(path, {
                "configured_source_pin": probe.PIN,
                "backend_contract": "configured-only",
                "process_identity": "external listener attestation required",
                "provider": "deterministic localhost fixture; no external provider",
                "cleanup_errors": [{"operation": "config_read", "type": "OSError"}],
                "secret": "must-not-be-written",
            })
            evidence = json.loads(path.read_text())
            self.assertEqual(evidence["phase"], "failed")
            self.assertFalse(evidence["config_unchanged"])
            self.assertNotIn("secret", evidence)

    def test_rpc_buffers_terminal_event_received_before_prompt_ack(self):
        class FakeWS:
            def __init__(self):
                self.frames = [
                    {"jsonrpc": "2.0", "method": "event", "params": {
                        "type": "message.complete", "session_id": "runtime",
                        "payload": {"status": "complete"},
                    }},
                    {"jsonrpc": "2.0", "id": 1, "result": {"accepted": True}},
                ]

            async def send(self, _message):
                return None

            async def recv(self):
                return json.dumps(self.frames.pop(0))

        async def exercise_rpc():
            rpc = probe.RPC(FakeWS())
            self.assertEqual(await rpc.call("prompt.submit", {"session_id": "runtime"}), {"accepted": True})
            await rpc.wait_complete("runtime")

        asyncio.run(exercise_rpc())


if __name__ == "__main__":
    unittest.main()
