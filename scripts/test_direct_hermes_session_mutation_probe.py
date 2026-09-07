"""Pure contract tests for the bounded stock session mutation probe."""

from __future__ import annotations

import sys
import unittest
from contextlib import asynccontextmanager
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import direct_hermes_session_mutation_probe as probe  # noqa: E402


def list_payload(*, target_archived: bool = False, target_pinned: bool = False,
                 target_title: str | None = None, archived: str = "include") -> dict:
    target = {
        "id": "owned-target",
        "profile": probe.PROFILE,
        "is_default_profile": True,
        "title": target_title,
        "archived": target_archived,
        "pinned": target_pinned,
    }
    sibling = {
        "id": "owned-sibling",
        "profile": probe.PROFILE,
        "is_default_profile": True,
        "title": "sibling-title",
        "archived": False,
        "pinned": False,
    }
    rows = [target, sibling]
    if archived == "exclude":
        rows = [row for row in rows if not row["archived"]]
    elif archived == "only":
        rows = [row for row in rows if row["archived"]]
    return {
        "sessions": rows,
        "total": len(rows),
        "profile_totals": {probe.PROFILE: len(rows)},
        "limit": probe.LIST_LIMIT,
        "offset": 0,
        "errors": [],
    }


class SessionMutationProbeTests(unittest.TestCase):
    def test_owned_binding_requires_matching_bounded_durable_aliases(self):
        runtime, stored = probe._owned_binding({
            "session_id": "runtime-1",
            "stored_session_id": "owned-1",
            "session_key": "owned-1",
            "profile": probe.PROFILE,
        })
        self.assertEqual((runtime, stored), ("runtime-1", "owned-1"))
        for candidate in (
            {"session_id": "runtime-1"},
            {"session_id": "runtime-1", "stored_session_id": "owned-1", "session_key": "other"},
            {"session_id": "runtime-1", "stored_session_id": "/private/path"},
            {"session_id": "runtime-1", "stored_session_id": "owned-1", "profile": "other"},
        ):
            with self.subTest(candidate=candidate):
                with self.assertRaises(AssertionError):
                    probe._owned_binding(candidate)

    def test_list_contract_enforces_default_profile_and_archive_filter(self):
        summary = probe._list_summary(
            list_payload(target_archived=False),
            archived="include",
            requested_limit=probe.LIST_LIMIT,
            owned_ids={"owned-target", "owned-sibling"},
        )
        self.assertEqual(summary["owned_rows_present"], 2)
        self.assertEqual(summary["metadata"]["owned-target"]["title"], None)
        self.assertEqual(summary["metadata"]["owned-sibling"]["pinned"], False)
        with self.assertRaisesRegex(AssertionError, "archived=exclude"):
            probe._list_summary(
                list_payload(target_archived=True),
                archived="exclude",
                requested_limit=probe.LIST_LIMIT,
            )
        with self.assertRaisesRegex(AssertionError, "archived=only"):
            probe._list_summary(
                list_payload(target_archived=False),
                archived="only",
                requested_limit=probe.LIST_LIMIT,
            )

    def test_list_contract_rejects_missing_identity_and_profile_errors(self):
        payload = list_payload()
        payload["sessions"][0].pop("id")
        with self.assertRaisesRegex(AssertionError, "durable identity"):
            probe._list_summary(payload, archived="include", requested_limit=probe.LIST_LIMIT)
        payload = list_payload()
        payload["errors"] = [{"profile": probe.PROFILE, "error": "fixture"}]
        with self.assertRaisesRegex(AssertionError, "profile errors"):
            probe._list_summary(payload, archived="include", requested_limit=probe.LIST_LIMIT)

    def test_patch_requires_ok_and_exact_readback(self):
        summary = probe._patch_summary(
            {"ok": True, "title": probe.MUTATION_TITLE},
            {"title": probe.MUTATION_TITLE},
        )
        self.assertEqual(summary["readback_fields"], ["title"])
        for candidate in (
            {},
            {"ok": False, "title": probe.MUTATION_TITLE},
            {"ok": True, "title": "wrong"},
            {"ok": True, "title": None},
        ):
            with self.subTest(candidate=candidate):
                with self.assertRaises(AssertionError):
                    probe._patch_summary(candidate, {"title": probe.MUTATION_TITLE})

    def test_sibling_comparison_rejects_mutation_or_disappearance(self):
        before = probe._list_summary(
            list_payload(), archived="include", requested_limit=probe.LIST_LIMIT
        )["metadata"]
        after = dict(before)
        after["owned-sibling"] = dict(after["owned-sibling"])
        after["owned-sibling"]["pinned"] = True
        with self.assertRaisesRegex(AssertionError, "sibling metadata"):
            probe._assert_sibling_unchanged(before, after, "owned-sibling")
        with self.assertRaisesRegex(AssertionError, "disappeared"):
            probe._assert_sibling_unchanged(before, {}, "owned-sibling")

    def test_cli_accepts_only_output_and_rejects_arbitrary_target_options(self):
        parser = probe.build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args([])
        for option in ("--profile", "--target-session-id", "--delete"):
            with self.subTest(option=option):
                with self.assertRaises(SystemExit):
                    parser.parse_args(["--output", "/tmp/evidence.json", option, "value"])

    def test_mocked_exercise_restores_target_and_preserves_sibling(self):
        class Response:
            status_code = 200

            def __init__(self, payload):
                self.payload = payload

            def json(self):
                return self.payload

        class Client:
            def __init__(self):
                self.rows = {
                    "owned-target": {
                        "id": "owned-target", "profile": probe.PROFILE,
                        "is_default_profile": True, "title": None,
                        "archived": False, "pinned": False,
                    },
                    "owned-sibling": {
                        "id": "owned-sibling", "profile": probe.PROFILE,
                        "is_default_profile": True, "title": "sibling-title",
                        "archived": False, "pinned": False,
                    },
                }
                self.patch_bodies = []

            async def get(self, _path, *, params):
                rows = list(self.rows.values())
                if params["archived"] == "exclude":
                    rows = [row for row in rows if not row["archived"]]
                elif params["archived"] == "only":
                    rows = [row for row in rows if row["archived"]]
                return Response({
                    "sessions": [dict(row) for row in rows],
                    "total": len(rows),
                    "profile_totals": {probe.PROFILE: len(rows)},
                    "limit": params["limit"], "offset": 0, "errors": [],
                })

            async def patch(self, path, *, json):
                self.patch_bodies.append((path, dict(json)))
                row = self.rows["owned-target"]
                if "title" in json and json["title"] is not None:
                    row["title"] = json["title"] or None
                for key in ("archived", "pinned"):
                    if key in json:
                        row[key] = json[key]
                result = {"ok": True, "title": row["title"] or ""}
                for key in ("archived", "pinned"):
                    if key in json:
                        result[key] = row[key]
                return Response(result)

        class WebSocket:
            async def recv(self):
                return '{"params":{"type":"gateway.ready"}}'

            async def close(self):
                return None

        class FakeProbe:
            def __init__(self, *_args):
                self.frames = []

            async def rpc(self, method, _params):
                self.asserted_method = method
                return {"closed": True}

        client = Client()
        websocket = WebSocket()

        @asynccontextmanager
        async def fake_authenticated(*_args, **_kwargs):
            yield client, "fixture-ticket"

        async def fake_connect(*_args, **_kwargs):
            return websocket

        async def fake_create_and_warm(_probe, owned_runtimes):
            if not owned_runtimes:
                owned_runtimes.append("runtime-target")
                return "runtime-target", "owned-target"
            owned_runtimes.append("runtime-sibling")
            return "runtime-sibling", "owned-sibling"

        evidence = {"cleanup_errors": [], "phase": "test"}
        with mock.patch.object(probe, "authenticated", fake_authenticated), \
             mock.patch.object(probe, "connect", fake_connect), \
             mock.patch.object(probe, "_json_frame", return_value={
                 "params": {"type": "gateway.ready"}
             }), \
             mock.patch.object(probe, "Probe", FakeProbe), \
             mock.patch.object(probe, "_create_and_warm", fake_create_and_warm):
            import asyncio
            asyncio.run(probe._exercise({}, evidence))

        self.assertEqual(evidence["mutation_contract"]["sibling_unchanged"], True)
        self.assertFalse(client.rows["owned-target"]["archived"])
        self.assertFalse(client.rows["owned-target"]["pinned"])
        self.assertIsNone(client.rows["owned-target"]["title"])
        self.assertEqual(client.rows["owned-sibling"]["title"], "sibling-title")
        self.assertEqual(evidence["cleanup_errors"], [])
        self.assertGreaterEqual(len(client.patch_bodies), 6)
        titles = [body.get("title") for _path, body in client.patch_bodies]
        self.assertTrue(any(
            isinstance(title, str) and title.startswith(probe.MUTATION_TITLE + "_")
            for title in titles
        ))


if __name__ == "__main__":
    unittest.main()
