"""Pure contract tests for the guarded full-session branch probe."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import direct_hermes_branch_probe as probe  # noqa: E402


def rows(*pairs: tuple[str, str]) -> list[dict[str, str]]:
    return [{"role": role, "content": content} for role, content in pairs]


class BranchProbeTests(unittest.TestCase):
    def test_full_copy_requires_complete_parent_and_preserves_exact_content(self):
        parent = probe._canonical_rows(rows(
            ("user", probe.PARENT_MARKERS[0]),
            ("assistant", "ACK A"),
            ("user", probe.PARENT_MARKERS[1]),
            ("assistant", "ACK B"),
        ))
        probe.assert_full_copy(parent, list(parent), list(parent))
        with self.assertRaisesRegex(AssertionError, "complete parent"):
            probe.assert_full_copy(parent, parent[:-1], parent)
        changed = list(parent)
        changed[-1] = ("assistant", "different")
        with self.assertRaisesRegex(AssertionError, "complete parent"):
            probe.assert_full_copy(parent, changed, parent)

    def test_full_copy_rejects_parent_mutation_and_wrong_turn_order(self):
        parent = probe._canonical_rows(rows(
            ("user", probe.PARENT_MARKERS[0]),
            ("assistant", "ACK A"),
            ("user", probe.PARENT_MARKERS[1]),
            ("assistant", "ACK B"),
        ))
        with self.assertRaisesRegex(AssertionError, "parent transcript"):
            probe.assert_full_copy(parent, parent, parent[:-1])
        wrong = [("assistant", "ACK A"), ("user", probe.PARENT_MARKERS[0]),
                 ("user", probe.PARENT_MARKERS[1]), ("assistant", "ACK B")]
        with self.assertRaisesRegex(AssertionError, "user/assistant order"):
            probe.assert_full_copy(wrong, wrong, wrong)

    def test_branch_result_requires_parent_and_distinct_runtime_durable_identity(self):
        child = {
            "session_id": "child-runtime",
            "stored_session_id": "child-stored",
            "session_key": "child-stored",
            "parent": "parent-stored",
            "message_count": 4,
            "info": {"profile": probe.PROFILE},
        }
        self.assertEqual(
            probe.assert_branch_result(child, parent_runtime="parent-runtime", parent_stored="parent-stored", expected_message_count=4),
            ("child-runtime", "child-stored"),
        )
        for candidate in (
            {**child, "parent": "other"},
            {**child, "session_id": "parent-runtime"},
            {**child, "stored_session_id": "other", "session_key": "child-stored"},
            {**child, "message_count": 0},
            {**child, "info": {"profile": "other"}},
        ):
            with self.subTest(candidate=candidate):
                with self.assertRaises(AssertionError):
                    probe.assert_branch_result(candidate, parent_runtime="parent-runtime", parent_stored="parent-stored", expected_message_count=4)

    def test_detail_requires_profile_and_parent_when_child(self):
        payload = {"id": "child-stored", "profile": probe.PROFILE, "parent_session_id": "parent-stored"}
        probe._assert_detail(payload, "child-stored", profile=probe.PROFILE, parent="parent-stored")
        for candidate in (
            {**payload, "profile": "other"},
            {**payload, "parent_session_id": "other"},
            {**payload, "id": "other"},
        ):
            with self.subTest(candidate=candidate):
                with self.assertRaises(AssertionError):
                    probe._assert_detail(candidate, "child-stored", profile=probe.PROFILE, parent="parent-stored")

    def test_child_can_append_one_turn_without_mutating_parent(self):
        parent = [("user", probe.PARENT_MARKERS[0]), ("assistant", "ACK A"),
                  ("user", probe.PARENT_MARKERS[1]), ("assistant", "ACK B")]
        child = parent + [("user", "SEMREH_S4_BRANCH_CHILD_V1"), ("assistant", "ACK C")]
        probe.assert_child_extension(parent, child, "SEMREH_S4_BRANCH_CHILD_V1")
        with self.assertRaisesRegex(AssertionError, "copied parent prefix"):
            probe.assert_child_extension(parent, child[1:], "SEMREH_S4_BRANCH_CHILD_V1")

    def test_parser_requires_stock_backend_and_output(self):
        parser = probe.build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args(["--output", "/tmp/evidence.json"])
        args = parser.parse_args(["--stock-backend", "--output", "/tmp/evidence.json"])
        self.assertTrue(args.stock_backend)
        with self.assertRaises(SystemExit):
            parser.parse_args(["--backend-sha", "abc", "--output", "/tmp/evidence.json"])


if __name__ == "__main__":
    unittest.main()
