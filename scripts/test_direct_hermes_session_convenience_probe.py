#!/usr/bin/env python3
"""Pure contract tests for the bounded session-convenience probe."""

from __future__ import annotations

from contextlib import asynccontextmanager
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import direct_hermes_session_convenience_probe as probe  # noqa: E402
import direct_hermes_reasoning_probe as reasoning  # noqa: E402


def session_payload(archived: bool, *, limit: int = probe.SESSION_LIMIT) -> dict:
    row = {
        "id": "fixture-session-id",
        "profile": probe.PROFILE,
        "is_default_profile": True,
        "archived": archived,
        "pinned": False,
    }
    return {
        "sessions": [row],
        "total": 1,
        "profile_totals": {probe.PROFILE: 1},
        "limit": limit,
        "offset": 0,
        "errors": [],
    }


def count_payload(archived: bool) -> dict:
    payload = session_payload(archived, limit=0)
    payload["sessions"] = []
    return payload


class FakeResponse:
    def __init__(self, payload, status_code=200):
        self.payload = payload
        self.status_code = status_code

    def json(self):
        return self.payload


class FakeClient:
    def __init__(self):
        self.calls = []

    async def get(self, path, *, params):
        self.calls.append((path, dict(params)))
        if path == probe.SEARCH_ROUTE:
            return FakeResponse({
                "results": [{
                    "session_id": "fixture-session-id",
                    "lineage_root": "fixture-session-id",
                    "snippet": f"prefix {probe.SEARCH_MARKER} suffix",
                    "role": "user",
                    "archived": False,
                }]
            })
        archived = params["archived"] == "only"
        if params["limit"] == 0:
            return FakeResponse(count_payload(archived))
        return FakeResponse(session_payload(archived, limit=params["limit"]))


class SessionConvenienceProbeTests(unittest.TestCase):
    def test_session_filters_validate_and_emit_only_schema_counts(self):
        payload = session_payload(False)
        summary = probe._session_summary(payload, archived="exclude", requested_limit=20)
        self.assertEqual(summary["filter_verified"], "exclude")
        self.assertEqual(summary["row_count"], 1)
        self.assertEqual(summary["total"], 1)
        self.assertNotIn("fixture-session-id", repr(summary))
        with self.assertRaisesRegex(AssertionError, "archived=exclude"):
            probe._session_summary(session_payload(True), archived="exclude", requested_limit=20)

    def test_limit_zero_is_a_count_readback_and_not_assumed_empty(self):
        payload = count_payload(False)
        summary = probe._session_summary(payload, archived="exclude", requested_limit=0)
        self.assertEqual(summary["limit"], 0)
        self.assertEqual(summary["total"], 1)

    def test_session_shape_rejects_profile_errors_and_total_mismatch(self):
        cases = [
            {**session_payload(False), "profile_totals": {"other": 1}},
            {**session_payload(False), "errors": [{"profile": "default", "error": "bad"}]},
            {**session_payload(False), "total": 2},
        ]
        for candidate in cases:
            with self.subTest(candidate=candidate):
                with self.assertRaises(AssertionError):
                    probe._session_summary(candidate, archived="exclude", requested_limit=20)

    def test_search_requires_seed_match_and_sanitizes_result_values(self):
        payload = {
            "results": [{
                "session_id": "/Users/maurice/private-id",
                "lineage_root": "private-lineage",
                "snippet": f"{probe.SEARCH_MARKER} only",
                "role": "user",
                "archived": False,
            }]
        }
        summary = probe._search_summary(
            payload, marker=probe.SEARCH_MARKER, requested_limit=20
        )
        self.assertEqual(summary["marker_match_count"], 1)
        self.assertNotIn("private-id", repr(summary))
        with self.assertRaisesRegex(AssertionError, "not found"):
            probe._search_summary(
                {"results": [{**payload["results"][0], "snippet": "unrelated"}]},
                marker=probe.SEARCH_MARKER,
                requested_limit=20,
            )

    def test_exercise_uses_exact_read_only_request_shapes(self):
        client = FakeClient()
        evidence = {}
        import asyncio

        asyncio.run(probe.exercise(client, evidence))
        self.assertEqual(len(client.calls), 7)
        for path, params in client.calls[:6]:
            self.assertEqual(path, probe.SESSION_ROUTE)
            self.assertEqual(set(params), {"profile", "limit", "offset", "archived", "order"})
            self.assertEqual(params["profile"], probe.PROFILE)
            self.assertEqual(params["offset"], 0)
            self.assertIn(params["archived"], probe.ARCHIVED_FILTERS)
        self.assertEqual(client.calls[-1], (
            probe.SEARCH_ROUTE,
            {"q": probe.SEARCH_MARKER, "profile": probe.PROFILE, "limit": probe.SEARCH_LIMIT},
        ))
        self.assertEqual(len(evidence["session_lists"]), 6)

    def test_authenticated_run_is_used_by_exercise(self):
        client = FakeClient()

        @asynccontextmanager
        async def fake_authenticated(*_args, **_kwargs):
            yield client, "ticket-not-retained"

        import asyncio

        evidence = {}
        with mock.patch.object(probe, "authenticated", fake_authenticated):
            asyncio.run(probe._run_authenticated({"username": "fixture", "password": "secret"}, evidence))
        self.assertEqual(len(client.calls), 7)

    def test_output_scope_and_cli_arguments_fail_closed(self):
        parser = probe.build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args([])
        with self.assertRaises(SystemExit):
            parser.parse_args(["--output", "/tmp/evidence.json", "--profile", "default"])
        with tempfile.TemporaryDirectory() as directory:
            outside = Path(directory) / "evidence.json"
            with self.assertRaises(RuntimeError):
                probe._output_path(str(outside))
            with mock.patch.object(reasoning, "EVIDENCE_ROOT", Path(directory)):
                output = Path(directory) / "evidence.json"
                self.assertEqual(probe._output_path(str(output)), output)
                output.write_text("retained", encoding="utf-8")
                with self.assertRaises(RuntimeError):
                    probe._output_path(str(output))
                target = Path(directory) / "target.json"
                target.write_text("target", encoding="utf-8")
                link = Path(directory) / "link.json"
                link.symlink_to(target)
                with self.assertRaises(RuntimeError):
                    probe._output_path(str(link))


if __name__ == "__main__":
    unittest.main()
