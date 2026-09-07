#!/usr/bin/env python3
"""Pure mocked-HTTP contract tests for the native attachment complement."""

import asyncio
from contextlib import asynccontextmanager
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import direct_hermes_native_attachment_check as probe  # noqa: E402


MARKER = "SEMREH_SLICE3_ATTACHMENT_UI_PROMPT_00000000-0000-0000-0000-000000000001"


class FakeResponse:
    def __init__(self, payload, status_code=200):
        self.payload = payload
        self.status_code = status_code

    def json(self):
        return self.payload


class FakeClient:
    def __init__(self, sessions, messages, mismatch=False):
        self.sessions = sessions
        self.messages = messages
        self.calls = []
        self.mismatch = mismatch

    async def get(self, path, params):
        self.calls.append((path, dict(params)))
        if path == "/api/profiles/sessions":
            return FakeResponse({"sessions": self.sessions})
        if path in ("/api/media", "/api/files/read"):
            return FakeResponse({"data_url": "data:image/png;base64,YQ==",
                                 "path": params["path"],
                                 "size": 2 if self.mismatch else 1})
        return FakeResponse(self.messages)


class NativeAttachmentCheckTests(unittest.TestCase):
    def run_check(self, *, sessions=None, messages=None, check_media=False, mismatch=False):
        with tempfile.TemporaryDirectory(prefix="semreh-native-check-") as temporary:
            runtime = Path(temporary)
            (runtime / "credentials.json").write_text(
                json.dumps({"username": "fixture", "password": "not-real"}),
                encoding="utf-8",
            )
            client = FakeClient(
                sessions=[{"id": "stored-session"}] if sessions is None else sessions,
                messages=messages if messages is not None else self.valid_messages(runtime),
                mismatch=mismatch,
            )

            @asynccontextmanager
            async def fake_authenticated(_credentials):
                yield client, "test-ticket"

            with mock.patch.object(probe.stock, "RUNTIME", runtime), \
                    mock.patch.object(probe, "_authenticated", fake_authenticated):
                result = asyncio.run(probe.check(MARKER, check_media))
            created_paths = {path.relative_to(runtime) for path in runtime.iterdir()}
        return result, client, created_paths

    @staticmethod
    def valid_messages(runtime):
        image = runtime / "home" / "images" / "native.png"
        return {
            "session_id": "stored-session",
            "messages": [
                {
                    "id": "user-1",
                    "role": "user",
                    "content": f"{MARKER}\n@image:{image}",
                },
                {
                    "id": "assistant-1",
                    "role": "assistant",
                    "content": "SEMREH_SLICE1_ACK",
                },
            ],
        }

    def test_unique_marker_final_pair_and_ids_pass_without_network_or_writes(self):
        result, client, created_paths = self.run_check()

        self.assertEqual(result["canonical_session_id"], "stored-session")
        self.assertEqual(result["user_row_id"], "user-1")
        self.assertEqual(result["terminal_row_id"], "assistant-1")
        self.assertEqual(result["row_count"], 2)
        self.assertEqual(len(client.calls), 2)
        self.assertEqual(created_paths, {Path("credentials.json")})

    def test_rejects_missing_or_blank_canonical_session_id(self):
        for value in (None, "", "   "):
            with self.subTest(value=value):
                messages = self.valid_messages(Path("/fixture"))
                if value is None:
                    messages.pop("session_id")
                else:
                    messages["session_id"] = value
                with self.assertRaisesRegex(RuntimeError, "Canonical session ID missing"):
                    self.run_check(messages=messages)

    def test_owned_media_reads_match_without_file_writes(self):
        result, client, created_paths = self.run_check(check_media=True)
        self.assertTrue(result["authenticated_managed_file_read"])
        self.assertEqual(result["matching_decoded_bytes"], 1)
        self.assertEqual([call[0] for call in client.calls[-2:]],
                         ["/api/media", "/api/files/read"])
        self.assertEqual(created_paths, {Path("credentials.json")})

    def test_managed_metadata_mismatch_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "metadata mismatch"):
            self.run_check(check_media=True, mismatch=True)

    def test_rejects_malformed_session_list_and_message_rows(self):
        with self.assertRaisesRegex(RuntimeError, "bounded discovery"):
            self.run_check(sessions="not-a-list")

        malformed = self.valid_messages(Path("/fixture"))
        malformed["messages"] = [{"id": "user-1"}, "not-a-row"]
        with self.assertRaisesRegex(RuntimeError, "messages malformed"):
            self.run_check(messages=malformed)

        missing_rows = self.valid_messages(Path("/fixture"))
        missing_rows.pop("messages")
        with self.assertRaisesRegex(RuntimeError, "messages missing"):
            self.run_check(messages=missing_rows)

    def test_rejects_duplicate_marker_wrong_reference_and_nonterminal_ack(self):
        duplicate = self.valid_messages(Path("/fixture"))
        duplicate["messages"].insert(1, copy.deepcopy(duplicate["messages"][0]))
        duplicate["messages"][1]["id"] = "user-2"
        with self.assertRaisesRegex(RuntimeError, "duplicated or not the final turn"):
            self.run_check(messages=duplicate)

        wrong_reference = self.valid_messages(Path("/fixture"))
        wrong_reference["messages"][0]["content"] = f"{MARKER}\n@file:notes.txt"
        with self.assertRaisesRegex(RuntimeError, "owned canonical image"):
            self.run_check(messages=wrong_reference)

        nonterminal = self.valid_messages(Path("/fixture"))
        nonterminal["messages"][-1]["role"] = "user"
        with self.assertRaisesRegex(RuntimeError, "terminal ACK"):
            self.run_check(messages=nonterminal)

    def test_rejects_missing_or_duplicate_durable_row_ids(self):
        missing = self.valid_messages(Path("/fixture"))
        missing["messages"][0].pop("id")
        with self.assertRaisesRegex(RuntimeError, "row identities invalid"):
            self.run_check(messages=missing)

        duplicate = self.valid_messages(Path("/fixture"))
        duplicate["messages"][-1]["id"] = duplicate["messages"][0]["id"]
        with self.assertRaisesRegex(RuntimeError, "row identities invalid"):
            self.run_check(messages=duplicate)


if __name__ == "__main__":
    unittest.main()
