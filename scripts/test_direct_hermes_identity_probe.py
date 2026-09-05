#!/usr/bin/env python3
"""Stdlib unittest contract tests for the bounded identity/paging probe."""

import asyncio
import sys
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import direct_hermes_identity_probe as probe  # noqa: E402


class FakeResponse:
    def __init__(self, payload=None, *, status_code=200, headers=None):
        self._payload = payload
        self.status_code = status_code
        self.headers = headers or {}

    def json(self):
        return self._payload

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"unexpected fake HTTP {self.status_code}")


class PagingClient:
    """Fake REST client whose latest pages are chronological within each page."""

    def __init__(self, rows, session_id="stored"):
        self.rows = rows
        self.session_id = session_id
        self.calls = []

    async def get(self, path, params):
        self.calls.append((path, dict(params)))
        limit = params["limit"]
        offset = params["offset"]
        end = max(len(self.rows) - offset, 0)
        start = max(end - limit, 0)
        return FakeResponse({"session_id": self.session_id, "messages": self.rows[start:end]})


class AuthClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False

    async def post(self, path, **kwargs):
        self.calls.append(("POST", path, kwargs))
        return self.responses.pop(0)

    async def get(self, path, **kwargs):
        self.calls.append(("GET", path, kwargs))
        return self.responses.pop(0)


class IdentityProbeTests(unittest.TestCase):
    def test_binding_requires_one_consistent_durable_alias(self):
        payload = {
            "session_id": "runtime-1",
            "stored_session_id": "stored-1",
            "session_key": "stored-1",
        }
        self.assertEqual(probe.binding(payload), ("runtime-1", "stored-1"))
        self.assertEqual(probe.binding(payload, "stored-1"), ("runtime-1", "stored-1"))
        for alias in ("stored_session_id", "session_key", "resumed"):
            with self.subTest(alias=alias):
                self.assertEqual(
                    probe.binding({"session_id": "runtime-1", alias: "stored-1"}),
                    ("runtime-1", "stored-1"),
                )

        invalid = [
            {"stored_session_id": "stored-1"},
            {"session_id": "runtime-1"},
            {"session_id": "runtime-1", "stored_session_id": "stored-1", "session_key": "stored-2"},
            {"session_id": "runtime-1", "stored_session_id": ""},
            {"session_id": "runtime-1", "stored_session_id": "stored-1"},
        ]
        for candidate in invalid:
            with self.subTest(candidate=candidate):
                with self.assertRaises(AssertionError):
                    probe.binding(candidate, "stored-expected")

        with self.assertRaises(AssertionError):
            probe.binding({**payload, "resumed": "stored-2"})

    def test_assert_rows_requires_exact_alternating_roles_and_content(self):
        prompts = ["prompt one", "prompt two"]
        rows = [
            {"role": "user", "content": "prompt one"},
            {"role": "assistant", "content": [{"text": "reply one"}]},
            {"role": "user", "content": "prompt two"},
            {"role": "assistant", "content": "reply two"},
        ]
        probe.assert_rows(rows, prompts)

        cases = [
            rows[:2] + [{"role": "assistant", "content": "wrong role"}, rows[3]],
            [*rows[:2], {"role": "user", "content": "wrong prompt"}, rows[3]],
            [*rows[:3], {"role": "assistant", "content": "  "}],
            [*rows, {"role": "user", "content": "unexpected extra"}],
        ]
        for candidate in cases:
            with self.subTest(candidate=candidate):
                with self.assertRaises(AssertionError):
                    probe.assert_rows(candidate, prompts)

    def test_latest_pages_are_chronological_and_offsets_run_backward(self):
        rows = [
            {"role": "user", "content": "p1"},
            {"role": "assistant", "content": "a1"},
            {"role": "user", "content": "p2"},
            {"role": "assistant", "content": "a2"},
            {"role": "user", "content": "p3"},
            {"role": "assistant", "content": "a3"},
        ]
        client = PagingClient(rows)

        async def check():
            latest = await probe.page(client, "stored", 100, 0)
            reconstructed = []
            for offset in range(0, len(latest), 3):
                page = await probe.page(client, "stored", 3, offset)
                reconstructed = page + reconstructed
            return latest, reconstructed

        latest, reconstructed = asyncio.run(check())
        self.assertEqual(reconstructed, latest)
        self.assertEqual([call[1]["offset"] for call in client.calls], [0, 0, 3])
        for _path, params in client.calls:
            self.assertEqual(params["order"], "latest")
            self.assertEqual(params["include_compacted"], "true")
            self.assertEqual(params["profile"], probe.PROFILE)

    def test_page_rejects_a_changed_canonical_id(self):
        client = PagingClient([], session_id="different")
        with self.assertRaisesRegex(AssertionError, "canonical ID"):
            asyncio.run(probe.page(client, "stored", 3, 0))

    def test_authenticated_logout_and_protected_check_succeed(self):
        client = AuthClient([
            FakeResponse({"ok": True}),
            FakeResponse({"ticket": "ticket-value"}),
            FakeResponse({}, status_code=302, headers={"location": "/login"}),
            FakeResponse({}, status_code=401),
        ])
        evidence = {"cleanup_errors": []}

        async def check():
            with mock.patch.object(probe.httpx, "AsyncClient", return_value=client):
                async with probe.authenticated({"username": "fixture", "password": "not-real"}, evidence) as (_, ticket):
                    self.assertEqual(ticket, "ticket-value")

        asyncio.run(check())
        self.assertEqual(evidence["cleanup_errors"], [])
        self.assertEqual([call[1] for call in client.calls], [
            "/auth/password-login", "/api/auth/ws-ticket", "/auth/logout", "/api/sessions",
        ])

    def test_authenticated_records_cleanup_failure_for_bad_logout(self):
        client = AuthClient([
            FakeResponse({"ok": True}),
            FakeResponse({"ticket": "ticket-value"}),
            FakeResponse({}, status_code=200),
        ])
        evidence = {"cleanup_errors": []}

        async def check():
            with mock.patch.object(probe.httpx, "AsyncClient", return_value=client):
                async with probe.authenticated({"username": "fixture", "password": "not-real"}, evidence):
                    pass

        asyncio.run(check())
        self.assertEqual(len(evidence["cleanup_errors"]), 1)
        self.assertEqual(evidence["cleanup_errors"][0]["operation"], "logout")
        self.assertEqual([call[1] for call in client.calls], [
            "/auth/password-login", "/api/auth/ws-ticket", "/auth/logout",
        ])


if __name__ == "__main__":
    unittest.main()
