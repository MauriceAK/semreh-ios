#!/usr/bin/env python3
"""Pure bounds and transcript-shape tests for the opt-in long-scroll seed."""

import asyncio
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import unittest


SCRIPT = Path(__file__).resolve().with_name("direct_hermes_longscroll_seed.py")


def load_seed_module():
    spec = importlib.util.spec_from_file_location("direct_hermes_longscroll_seed", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class LongScrollSeedContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.seed = load_seed_module()

    def test_turn_bound_is_70_through_80(self):
        for turns in (70, 72, 80):
            self.assertEqual(self.seed._validate_turn_count(turns), turns)
        for turns in (True, False, 0, 69, 81, "72"):
            with self.assertRaises(ValueError):
                self.seed._validate_turn_count(turns)

    def test_prompts_are_short_unique_and_run_scoped(self):
        nonce = "0123456789abcdef0123456789abcdef"
        prompts = self.seed._build_prompts(nonce, 72)
        self.assertEqual(len(prompts), 72)
        self.assertEqual(prompts[0], f"SEMREH_LONGSCROLL_SEED_{nonce}_TURN_001")
        self.assertEqual(prompts[-1], f"SEMREH_LONGSCROLL_SEED_{nonce}_TURN_072")
        self.assertEqual(len(set(prompts)), len(prompts))
        self.assertTrue(all(len(prompt) <= 80 for prompt in prompts))
        with self.assertRaises(ValueError):
            self.seed._build_prompts("not-a-uuid", 72)

    def test_cli_requires_explicit_seed_opt_in_and_bounded_turns(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as missing_opt_in:
                self.seed._parse_args(["--output", "/tmp/longscroll-fixture.json"])
            self.assertEqual(missing_opt_in.exception.code, 2)

            args = self.seed._parse_args([
                "--output", "/tmp/longscroll-fixture.json", "--seed-longscroll",
            ])
            self.assertEqual(args.turns, self.seed.DEFAULT_TURNS)
            self.assertFalse(args.approval_secret_fixture)
            explicit_fixture = self.seed._parse_args([
                "--output", "/tmp/longscroll-fixture.json", "--seed-longscroll",
                "--approval-secret-fixture",
            ])
            self.assertTrue(explicit_fixture.approval_secret_fixture)

            with self.assertRaises(SystemExit) as below_minimum:
                self.seed._parse_args([
                    "--output", "/tmp/longscroll-fixture.json", "--seed-longscroll", "--turns", "69",
                ])
            self.assertEqual(below_minimum.exception.code, 2)

            with self.assertRaises(SystemExit) as above_maximum:
                self.seed._parse_args([
                    "--output", "/tmp/longscroll-fixture.json", "--seed-longscroll", "--turns", "81",
                ])
            self.assertEqual(above_maximum.exception.code, 2)

    def test_canonical_transcript_requires_exact_rows_and_unique_ids(self):
        prompts = ["SEMREH_LONGSCROLL_SEED_fixture_TURN_001", "SEMREH_LONGSCROLL_SEED_fixture_TURN_002"]
        rows = [
            {"id": "row-1", "role": "user", "content": prompts[0]},
            {"id": "row-2", "role": "assistant", "content": self.seed.ACK},
            {"id": "row-3", "role": "user", "content": prompts[1]},
            {"id": "row-4", "role": "assistant", "content": self.seed.ACK},
        ]
        self.seed._validate_canonical_rows(rows, prompts, "durable-session-1")

        invalid_cases = []
        invalid_cases.append(rows[:-1])
        wrong_role = [dict(row) for row in rows]
        wrong_role[1]["role"] = "tool"
        invalid_cases.append(wrong_role)
        wrong_ack = [dict(row) for row in rows]
        wrong_ack[3]["content"] = "not the fixture acknowledgement"
        invalid_cases.append(wrong_ack)
        duplicate_id = [dict(row) for row in rows]
        duplicate_id[3]["id"] = duplicate_id[2]["id"]
        invalid_cases.append(duplicate_id)
        missing_id = [dict(row) for row in rows]
        missing_id[0].pop("id")
        invalid_cases.append(missing_id)
        wrong_prompt = [dict(row) for row in rows]
        wrong_prompt[2]["content"] = "unexpected user content"
        invalid_cases.append(wrong_prompt)

        for invalid in invalid_cases:
            with self.subTest(rows=invalid):
                with self.assertRaises(ValueError):
                    self.seed._validate_canonical_rows(invalid, prompts, "durable-session-1")

        with self.assertRaises(ValueError):
            self.seed._validate_canonical_rows(rows, prompts, "invalid/session-id")

    def test_canonical_readback_is_bounded_and_pages_oldest_order(self):
        class Response:
            def __init__(self, payload):
                self.payload = payload

            def raise_for_status(self):
                return None

            def json(self):
                return self.payload

        class Client:
            def __init__(self, rows):
                self.rows = rows
                self.calls = []

            async def get(self, path, *, params):
                self.calls.append((path, dict(params)))
                offset = params["offset"]
                limit = params["limit"]
                page = self.rows[offset:offset + limit]
                return Response({
                    "session_id": "durable-session-1",
                    "messages": page,
                    "pagination": {
                        "limit": limit,
                        "offset": offset,
                        "order": params["order"],
                        "returned": len(page),
                    },
                })

        rows = [{"id": f"row-{index}"} for index in range(144)]
        client = Client(rows)
        canonical = asyncio.run(self.seed._canonical_rows(client, "durable-session-1"))
        self.assertEqual(canonical, rows)
        self.assertEqual([call[1]["offset"] for call in client.calls], [0, 100])
        self.assertTrue(all(call[1]["order"] == "oldest" for call in client.calls))
        self.assertTrue(all(call[1]["limit"] == 100 for call in client.calls))

        too_many = Client([{"id": f"row-{index}"} for index in range(161)])
        with self.assertRaises(RuntimeError):
            asyncio.run(self.seed._canonical_rows(too_many, "durable-session-1"))

    def test_approved_target_guard_rejects_a_different_runtime_or_pin(self):
        from unittest.mock import patch

        with patch.object(self.seed.stock_probe, "PIN", "0" * 40):
            with self.assertRaises(RuntimeError):
                self.seed._assert_approved_target()


if __name__ == "__main__":
    unittest.main()
