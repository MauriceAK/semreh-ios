#!/usr/bin/env python3
"""Stdlib unittest contract tests for the bounded identity/paging probe."""

import asyncio
from pathlib import Path
import sys
from types import SimpleNamespace
import tempfile
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
    def test_run_validates_selected_backend_before_credentials_or_network(self):
        async def no_exercise(*_args, **_kwargs):
            return None

        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary)
            (runtime / "credentials.json").write_text("{}", encoding="utf-8")
            for stock, backend_sha in ((True, probe.STOCK_PIN), (False, "dev-sha")):
                fixture = SimpleNamespace(
                    runtime=runtime,
                    stock=stock,
                    backend_sha=backend_sha,
                    base="https://fixture.test",
                    ws_base="wss://fixture.test",
                    origin="https://fixture.test",
                    tools_cwd=runtime / "tools",
                )
                with self.subTest(stock=stock), \
                        mock.patch.object(probe, "select_fixture", return_value=fixture), \
                        mock.patch.object(probe.stock_probe, "validate") as stock_validate, \
                        mock.patch.object(probe, "_validate_all") as development_validate, \
                        mock.patch.object(probe, "_config_hash", return_value="same"), \
                        mock.patch.object(probe, "exercise", new=no_exercise), \
                        mock.patch.object(probe, "write_fixture"), \
                        mock.patch.object(probe.Path, "chmod"):
                    asyncio.run(probe.run(runtime / "evidence.json", backend_sha, stock_backend=stock))
                if stock:
                    stock_validate.assert_called_once_with()
                    development_validate.assert_not_called()
                else:
                    stock_validate.assert_not_called()
                    development_validate.assert_called_once_with(backend_sha)

    def test_run_validation_failure_prevents_credential_read_and_exercise(self):
        fixture = SimpleNamespace(
            runtime=Path("/private/nonexistent/identity-fixture"),
            stock=True,
            backend_sha=probe.STOCK_PIN,
            base="https://fixture.test",
            ws_base="wss://fixture.test",
            origin="https://fixture.test",
            tools_cwd=Path("/private/nonexistent/tools"),
        )
        async def should_not_exercise(*_args, **_kwargs):
            self.fail("exercise must not run after fixture validation fails")

        with mock.patch.object(probe, "select_fixture", return_value=fixture), \
                mock.patch.object(probe.stock_probe, "validate", side_effect=RuntimeError("invalid fixture")), \
                mock.patch.object(probe.Path, "read_text") as read_text, \
                mock.patch.object(probe, "exercise", new=should_not_exercise):
            with self.assertRaisesRegex(RuntimeError, "invalid fixture"):
                asyncio.run(probe.run(Path("/private/nonexistent/evidence.json"), stock_backend=True))
        read_text.assert_not_called()

    def test_stock_fixture_is_explicit_and_uses_baseline_tuple(self):
        fixture = probe.select_fixture(stock_backend=True, backend_sha=None)
        self.assertTrue(fixture.stock)
        self.assertEqual(fixture.backend_sha, probe.STOCK_PIN)
        self.assertEqual(fixture.runtime, probe.STOCK_RUNTIME)
        self.assertEqual(fixture.tools_cwd, probe.STOCK_TOOLS_CWD)
        self.assertEqual(fixture.base, probe.STOCK_BASE)
        self.assertEqual(fixture.ws_base, probe.STOCK_WS_BASE)
        with self.assertRaisesRegex(ValueError, "cannot be combined"):
            probe.select_fixture(stock_backend=True, backend_sha=probe.STOCK_PIN)

    def test_development_fixture_still_requires_backend_sha(self):
        fixture = probe.select_fixture(stock_backend=False, backend_sha="ABCDEF")
        self.assertFalse(fixture.stock)
        self.assertEqual(fixture.backend_sha, "abcdef")
        self.assertEqual(fixture.runtime, probe.DEV_RUNTIME)
        with self.assertRaisesRegex(ValueError, "required"):
            probe.select_fixture(stock_backend=False, backend_sha=None)

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
