#!/usr/bin/env python3
"""False-positive guards for the bounded compression probe."""

import asyncio
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import direct_hermes_compression_probe as probe  # noqa: E402


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def raise_for_status(self):
        return None

    def json(self):
        return self.payload


class PagingClient:
    def __init__(self, rows, canonical="tip"):
        self.rows = rows
        self.canonical = canonical

    async def get(self, _path, params):
        if params["order"] == "oldest":
            rows = self.rows[params["offset"]:params["offset"] + params["limit"]]
        else:
            end = max(0, len(self.rows) - params["offset"])
            rows = self.rows[max(0, end - params["limit"]):end]
        return FakeResponse({
            "session_id": self.canonical,
            "messages": rows,
            "pagination": {
                "limit": params["limit"],
                "offset": params["offset"],
                "order": params["order"],
                "returned": len(rows),
            },
        })


class CompressionProbeTests(unittest.TestCase):
    def test_prompts_are_short_unique_fixture_markers(self):
        first = probe.prompt(0)
        self.assertEqual(first, probe.prompt(0))
        self.assertNotEqual(first, probe.prompt(1))
        self.assertEqual(first, "SEMREH_COMPRESSION_BULKY_MAIN_00")
        self.assertLess(len(first.encode("ascii")), 64)
        assistants = [probe.compression_bulky_assistant(index) for index in range(2)]
        self.assertEqual(len(assistants[0].encode("ascii")), 4_096)
        self.assertNotEqual(assistants[0], assistants[1])

    def test_reduction_evidence_excludes_messages_and_free_text(self):
        result = {
            "status": "aborted", "removed": 0,
            "before_messages": 24, "after_messages": 24,
            "before_tokens": 12000, "after_tokens": 12000,
            "messages": [{"content": "must not persist"}],
            "summary": {
                "aborted": True,
                "note": "external provider detail must not persist",
            },
        }
        copied = probe.reduction_evidence(result)
        self.assertNotIn("messages", copied)
        self.assertNotIn("note", copied["summary"])
        self.assertEqual(copied["summary"]["reason_category"], "aborted")

    def test_reduction_rejects_noop_aborted_and_token_growth(self):
        good = {"status": "compressed", "summary": {"aborted": False}, "removed": 4,
                "before_messages": 24, "after_messages": 8,
                "before_tokens": 12000, "after_tokens": 2000}
        probe.assert_reduction(good)
        cases = [
            {**good, "removed": 0},
            {**good, "status": "aborted"},
            {**good, "summary": {"aborted": True}},
            {**good, "after_messages": 24},
            {**good, "after_tokens": 12000},
        ]
        for candidate in cases:
            with self.subTest(candidate=candidate):
                with self.assertRaises(AssertionError):
                    probe.assert_reduction(candidate)

    def test_originals_reject_duplicate_missing_and_wrong_order(self):
        prompts = ["p1", "p2"]
        assistants = ["a1", "a2"]
        rows = [
            {"role": "user", "content": "p1"},
            {"role": "assistant", "content": "a1"},
            {"role": "system", "content": "extra summary projection"},
            {"role": "user", "content": "p2"},
            {"role": "assistant", "content": "a2"},
        ]
        probe.assert_originals_once_in_order(rows, prompts, assistants)
        for candidate in (rows + [rows[-1]], rows[:-1], [rows[3], *rows[:3], rows[4]]):
            with self.subTest(candidate=candidate):
                with self.assertRaises(AssertionError):
                    probe.assert_originals_once_in_order(candidate, prompts, assistants)

    def test_latest_pages_reconstruct_oldest_order(self):
        rows = [{"role": "user", "content": str(index)} for index in range(13)]
        rebuilt = asyncio.run(probe.reconstructed_latest(
            PagingClient(rows), "ancestor", "tip",
            include_compacted=True, total=len(rows), page_size=5,
        ))
        self.assertEqual(rebuilt, rows)

    def test_latest_pages_reject_wrong_canonical_tip(self):
        with self.assertRaisesRegex(AssertionError, "canonical"):
            asyncio.run(probe.reconstructed_latest(
                PagingClient([], canonical="wrong"), "ancestor", "tip",
                include_compacted=True, total=1,
            ))

    def test_rotation_metadata_requires_exact_parent_and_closed_reason(self):
        parent = {"id": "parent", "ended_at": 1.0, "end_reason": "compression"}
        child = {"id": "child", "parent_session_id": "parent"}
        probe.assert_rotation_metadata(parent, child, "parent", "child")
        cases = [
            ({**parent, "id": "other"}, child),
            (parent, {**child, "parent_session_id": "other"}),
            ({**parent, "end_reason": "closed"}, child),
            ({**parent, "ended_at": None}, child),
        ]
        for candidate_parent, candidate_child in cases:
            with self.subTest(parent=candidate_parent, child=candidate_child):
                with self.assertRaises(AssertionError):
                    probe.assert_rotation_metadata(
                        candidate_parent, candidate_child, "parent", "child"
                    )

    def test_runtime_mode_is_explicit(self):
        with self.assertRaises(RuntimeError):
            probe.runtime("ordinary")

    def test_current_stock_config_requires_exact_local_rotation_route(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw).resolve()
            (root / "home").mkdir()
            config = {"compression": dict(probe.CURRENT_COMPRESSION),
                      "model": {"provider": "custom", "default": "semreh-fixture",
                                "base_url": "http://127.0.0.1:18792/v1"},
                      "auxiliary": {"transient_retries": 0,
                                    "compression": dict(probe.CURRENT_COMPRESSION_AUX)}}
            path = root / "home/config.yaml"; path.write_text(json.dumps(config))
            sha = hashlib.sha256(path.read_bytes()).hexdigest()
            with (patch.object(probe.stock_probe, "RUNTIME", root),
                  patch.object(probe.stock_probe, "validate"),
                  patch.object(probe.stock_probe, "_validate_runtime_plugins"),
                  patch.object(probe.stock_probe, "_validate_plugin_config"),
                  patch.object(probe.stock_probe, "_validate_runtime_skill"),
                  patch.object(probe, "_backend_guard")):
                probe.validate_current_stock(123, sha)
                config["auxiliary"]["compression"]["base_url"] = "https://example.invalid/v1"
                path.write_text(json.dumps(config))
                bad_sha = hashlib.sha256(path.read_bytes()).hexdigest()
                with self.assertRaises(RuntimeError):
                    probe.validate_current_stock(123, bad_sha)

    def test_current_stock_mode_requires_rotate_pid_and_sha(self):
        with self.assertRaises(ValueError):
            asyncio.run(probe.run("in-place", Path("unused"), current_stock_https=True,
                                  expected_backend_pid=1, expected_config_sha="0" * 64))


if __name__ == "__main__":
    unittest.main()
