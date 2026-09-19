"""Offline safety-guard tests for the bounded destructive stock probe."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import direct_hermes_destructive_probe as probe  # noqa: E402


class DestructiveProbeGuardTests(unittest.TestCase):
    def test_cli_accepts_only_output_and_no_target_or_fixture_overrides(self):
        parser = probe.build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args([])
        for option in (
            "--session-id", "--target-session-id", "--profile", "--origin",
            "--model", "--provider", "--cwd", "--delete",
        ):
            with self.subTest(option=option), self.assertRaises(SystemExit):
                parser.parse_args(["--output", "/tmp/evidence.json", option, "unsafe"])

    def test_history_requires_exact_identity_and_positive_integer_user_row_ids(self):
        payload = {
            "session_id": "owned",
            "messages": [
                {"role": "user", "content": "a", "id": 11},
                {"role": "assistant", "content": "b", "id": 12},
            ],
        }
        rows, row_ids = probe._history(payload, "owned")
        self.assertEqual(rows, [("user", "a"), ("assistant", "b")])
        self.assertEqual(row_ids, [11])
        bad_payloads = [
            {**payload, "session_id": "other"},
            {**payload, "messages": [{"role": "user", "content": "a"}]},
            {**payload, "messages": [{"role": "user", "content": "a", "id": True}]},
            {**payload, "messages": [{"role": "user", "content": "a", "id": -1}]},
        ]
        for candidate in bad_payloads:
            with self.subTest(candidate=candidate), self.assertRaises(AssertionError):
                probe._history(candidate, "owned")

    def test_error_guards_require_exact_stock_codes(self):
        self.assertEqual(probe._error_code({"error": {"code": 4018}}, 4018), 4018)
        self.assertEqual(probe._error_code({"error": {"code": 4023}}, 4023), 4023)
        for frame in ({}, {"result": {}}, {"error": {}}, {"error": {"code": 4007}}):
            with self.subTest(frame=frame), self.assertRaises(AssertionError):
                probe._error_code(frame, 4023)

    def test_delete_ack_requires_only_the_exact_owned_stored_id(self):
        probe._delete_ack({"deleted": "owned-target"}, "owned-target")
        for payload in (
            {}, {"deleted": True}, {"deleted": "owned-sibling"},
            {"deleted": "owned-target", "extra": True},
        ):
            with self.subTest(payload=payload), self.assertRaises(AssertionError):
                probe._delete_ack(payload, "owned-target")

    def test_digest_contains_no_raw_content(self):
        summary = probe._digest([("user", "private marker"), ("assistant", "reply")])
        self.assertEqual(set(summary), {"row_count", "user_count", "role_sequence", "content_sha256"})
        self.assertNotIn("private marker", json_text := str(summary))
        self.assertNotIn("reply", json_text)

    def test_destructive_constants_are_nonempty_and_missing_row_is_bounded_integer(self):
        self.assertEqual(len(probe.TARGET_TURNS), 2)
        self.assertEqual(len(probe.SIBLING_TURNS), 1)
        self.assertIs(type(probe.MISSING_ROW_ID), int)
        self.assertGreater(probe.MISSING_ROW_ID, 0)


class DestructiveSubmitGuardTests(unittest.IsolatedAsyncioTestCase):
    async def test_destructive_submit_requires_streaming_not_queued(self):
        class FakeProbe:
            frames = []

            def __init__(self, status):
                self.status = status

            async def rpc(self, method, params):
                self.request = (method, params)
                return {"status": self.status}

            async def wait_terminal(self, *_args):
                raise AssertionError("queued destructive request must fail before waiting")

            async def wait_idle(self, *_args):
                raise AssertionError("queued destructive request must fail before waiting")

        with self.assertRaises(AssertionError):
            await probe._submit(
                FakeProbe("queued"), "owned-runtime", "replacement",
                require_streaming=True, truncate_before_row_id=12,
                confirm_truncate=True,
            )


if __name__ == "__main__":
    unittest.main()
