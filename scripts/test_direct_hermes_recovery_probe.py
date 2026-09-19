#!/usr/bin/env python3
"""Pure evidence-contract tests for the bounded recovery probe."""

from __future__ import annotations

import unittest

from direct_hermes_recovery_probe import _assert_continuation


PROMPT = "SEMREH_RECOVERY_PROMPT"
ACK = "SEMREH_RECOVERY_ACK"
CANONICAL = "stored-session"


def row(identifier, role, content, **extra):
    return {"id": identifier, "role": role, "content": content, **extra}


class RecoveryEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.before = [
            row(1, "user", "SEMREH_RECOVERY_WARMUP"),
            row(2, "assistant", ACK),
        ]
        self.after = self.before + [
            row(3, "user", PROMPT),
            row(4, "assistant", ACK),
        ]

    def assert_rejected(self, rows, *, before=None, after_canonical=CANONICAL):
        with self.assertRaises(AssertionError):
            _assert_continuation(
                CANONICAL,
                self.before if before is None else before,
                after_canonical,
                rows,
                PROMPT,
                ACK,
            )

    def test_accepts_new_suffix_after_stable_nonempty_baseline(self):
        evidence = _assert_continuation(
            CANONICAL, self.before, CANONICAL, self.after, PROMPT, ACK
        )
        self.assertEqual(evidence["new_suffix_row_count"], 2)
        self.assertTrue(evidence["terminal_after_user"])

    def test_rejects_missing_user(self):
        self.assert_rejected(self.before + [row(4, "assistant", ACK)])

    def test_rejects_duplicate_user(self):
        self.assert_rejected(
            self.before + [row(3, "user", PROMPT), row(4, "user", PROMPT), row(5, "assistant", ACK)]
        )

    def test_rejects_reversed_user_and_terminal(self):
        self.assert_rejected(
            self.before + [row(3, "assistant", ACK), row(4, "user", PROMPT)]
        )

    def test_rejects_altered_baseline(self):
        altered = [row(1, "user", "changed"), *self.before[1:]]
        self.assert_rejected(altered + self.after[len(self.before):], before=self.before)

    def test_rejects_empty_baseline(self):
        self.assert_rejected(self.after, before=[])

    def test_rejects_changed_canonical_identity(self):
        self.assert_rejected(self.after, after_canonical="different-session")

    def test_rejects_missing_durable_message_id(self):
        rows = [dict(item) for item in self.after]
        rows[-1].pop("id")
        self.assert_rejected(rows)

    def test_rejects_duplicate_durable_message_id(self):
        rows = [dict(item) for item in self.after]
        rows[-1]["id"] = rows[-2]["id"]
        self.assert_rejected(rows)

    def test_clarify_accepts_only_verified_tool_rows_between_user_and_ack(self):
        rows = self.before + [
            row(3, "user", PROMPT),
            row(
                4,
                "assistant",
                "",
                tool_calls=[{"id": "call-1", "function": {"name": "clarify"}}],
            ),
            row(5, "tool", "cancelled", tool_name="clarify", tool_call_id="call-1"),
            row(6, "assistant", ACK),
        ]
        evidence = _assert_continuation(
            CANONICAL,
            self.before,
            CANONICAL,
            rows,
            PROMPT,
            ACK,
            allow_clarify_tool_rows=True,
        )
        self.assertTrue(evidence["verified_clarify_tool_rows"])

    def test_clarify_rejects_unverified_middle_row(self):
        rows = self.before + [
            row(3, "user", PROMPT),
            row(4, "assistant", "intermediate commentary"),
            row(5, "assistant", ACK),
        ]
        with self.assertRaises(AssertionError):
            _assert_continuation(
                CANONICAL,
                self.before,
                CANONICAL,
                rows,
                PROMPT,
                ACK,
                allow_clarify_tool_rows=True,
            )

    def test_clarify_rejects_unpaired_tool_result(self):
        rows = self.before + [
            row(3, "user", PROMPT),
            row(
                4,
                "assistant",
                "",
                tool_calls=[{"id": "call-1", "function": {"name": "clarify"}}],
            ),
            row(5, "tool", "cancelled", tool_name="clarify", tool_call_id="call-other"),
            row(6, "assistant", ACK),
        ]
        with self.assertRaises(AssertionError):
            _assert_continuation(
                CANONICAL,
                self.before,
                CANONICAL,
                rows,
                PROMPT,
                ACK,
                allow_clarify_tool_rows=True,
            )


if __name__ == "__main__":
    unittest.main()
