"""Pure guard/contract tests for the read-only export probe."""

import asyncio
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import direct_hermes_export_probe as probe


class Response:
    def __init__(self, body, status=200):
        self.body, self.status_code = body, status
    def json(self):
        return self.body


class Stream(Response):
    async def __aenter__(self):
        return self
    async def __aexit__(self, *_args):
        return None
    async def aiter_bytes(self):
        for chunk in self.body:
            yield chunk


class Client:
    def __init__(self, root, export=None):
        self.root, self.calls = root, []
        self.export = export or json.dumps({"id": "synthetic-id", "messages": [
            {"id": 1, "role": "user", "content": "PRIVATE TRANSCRIPT"}
        ]}).encode()
    async def get(self, route, *, params):
        self.calls.append(("GET", route, dict(params)))
        if route == "/api/profiles":
            return Response({"profiles": [{"name": "default", "path": str(self.root / "home")}]})
        if route == "/api/profiles/active":
            return Response({"current": "default", "active": "default"})
        if route == probe.SEARCH_ROUTE:
            return Response({"results": [{"session_id": "synthetic-id",
                "snippet": probe.SEARCH_MARKER}]})
        if route == "/api/sessions/synthetic-id":
            return Response({"id": "synthetic-id", "profile": "default"})
        raise AssertionError("unexpected GET route")
    def stream(self, method, route, *, params):
        self.calls.append((method, route, dict(params)))
        return Stream([self.export[:7], self.export[7:]])


class ExportProbeTests(unittest.TestCase):
    def test_exact_read_only_routes_shape_and_sanitized_evidence(self):
        root = Path("/fixture/runtime")
        client, evidence = Client(root), {}
        with patch.object(probe.stock_probe, "RUNTIME", root):
            asyncio.run(probe.exercise(client, evidence))
        self.assertEqual(client.calls, [
            ("GET", "/api/profiles", {}),
            ("GET", "/api/profiles/active", {}),
            ("GET", probe.SEARCH_ROUTE, {"q": probe.SEARCH_MARKER, "profile": "default", "limit": 20}),
            ("GET", "/api/sessions/synthetic-id", {"profile": "default"}),
            ("GET", "/api/sessions/synthetic-id/export", {"profile": "default"}),
        ])
        encoded = json.dumps(evidence)
        self.assertNotIn("synthetic-id", encoded)
        self.assertNotIn("PRIVATE TRANSCRIPT", encoded)
        self.assertEqual(evidence["response"]["message_count"], 1)
        self.assertEqual(len(evidence["response"]["sha256"]), 64)

    def test_export_rejects_wrong_identity_rows_and_oversize(self):
        with self.assertRaisesRegex(AssertionError, "identity"):
            probe._export_summary({"id": "wrong", "messages": []}, "expected", 2, "hash")
        with self.assertRaisesRegex(AssertionError, "object rows"):
            probe._export_summary({"id": "expected", "messages": ["bad"]}, "expected", 2, "hash")
        with self.assertRaisesRegex(AssertionError, "profile"):
            probe._export_summary({"id": "expected", "profile": "other", "messages": []},
                                  "expected", 2, "hash")
        self.assertEqual(
            probe._export_summary({"id": "expected", "messages": []}, "expected", 2, "hash")["profile_verified"],
            "default",
        )
        client = Client(Path("/fixture/runtime"), export=b"x" * (probe.MAXIMUM_BYTES + 1))
        with self.assertRaisesRegex(AssertionError, "byte bound"):
            asyncio.run(probe._bounded_export(client, "/api/sessions/id/export", {"profile": "default"}))

    def test_search_session_id_must_be_safe_route_segment(self):
        self.assertEqual(probe._route_segment("20260907_123456_abcd"), "20260907_123456_abcd")
        for value in (None, "", ".", "..", "a/b", "a\\b", "a?profile=other", "a#fragment", "a\nnext"):
            with self.subTest(value=value), self.assertRaisesRegex(AssertionError, "unsafe"):
                probe._route_segment(value)

    def test_server_guard_runs_before_synthetic_lookup(self):
        root = Path("/fixture/runtime")
        client = Client(root)
        with patch.object(probe.stock_probe, "RUNTIME", root):
            client.root = Path("/wrong")
            with self.assertRaisesRegex(AssertionError, "profile home"):
                asyncio.run(probe.exercise(client, {}))
        self.assertEqual(len(client.calls), 1)


if __name__ == "__main__":
    unittest.main()
