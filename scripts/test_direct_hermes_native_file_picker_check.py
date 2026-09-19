#!/usr/bin/env python3
"""Pure mocked-HTTP tests for the opt-in Files-picker canonical check."""

import asyncio
import base64
from contextlib import asynccontextmanager
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


TEXT_MARKER = "SEMREH_SLICE3_FILE_PICKER_TEXT_00000000-0000-0000-0000-000000000001"
PDF_MARKER = "SEMREH_SLICE3_FILE_PICKER_PDF_00000000-0000-0000-0000-000000000002"
TEXT_BYTES = probe.FILE_PICKER_TEXT_BYTES
PNG_BYTES = b"synthetic-pdf-page"


class FakeResponse:
    def __init__(self, payload, status_code=200):
        self.payload = payload
        self.status_code = status_code

    def json(self):
        return self.payload


class FakeClient:
    def __init__(self, messages, *, text_bytes=TEXT_BYTES, text_path=None, media_path=None):
        self.messages = messages if isinstance(messages, list) else [messages]
        self.text_bytes = text_bytes
        self.text_path = text_path
        self.media_path = media_path
        self.calls = []
        self.message_index = 0

    async def get(self, path, params):
        self.calls.append((path, dict(params)))
        if path == "/api/profiles/sessions":
            return FakeResponse({"sessions": [{"id": "stored-session"}]})
        if path.endswith("/messages"):
            payload = self.messages[min(self.message_index, len(self.messages) - 1)]
            self.message_index += 1
            return FakeResponse(payload)
        if path == "/api/files/read":
            content = base64.b64encode(self.text_bytes).decode("ascii")
            return FakeResponse({
                "name": "semreh-picker.txt",
                "path": self.text_path or params["path"],
                "size": len(self.text_bytes),
                "mime_type": "text/plain",
                "data_url": f"data:text/plain;base64,{content}",
            })
        if path == "/api/media":
            content = base64.b64encode(PNG_BYTES).decode("ascii")
            return FakeResponse({"data_url": f"data:image/png;base64,{content}"})
        raise AssertionError(f"unexpected route {path}")


class NativeFilePickerCheckTests(unittest.TestCase):
    def run_check(self, messages=None, **client_kwargs):
        with tempfile.TemporaryDirectory(prefix="semreh-file-picker-check-") as temporary:
            runtime = Path(temporary)
            (runtime / "credentials.json").write_text(
                json.dumps({"username": "fixture", "password": "not-real"}),
                encoding="utf-8",
            )
            payload = messages if messages is not None else self.valid_messages(runtime)
            client = FakeClient(payload, **client_kwargs)

            @asynccontextmanager
            async def fake_authenticated(_credentials):
                yield client, "test-ticket"

            with mock.patch.object(probe.stock, "RUNTIME", runtime), \
                    mock.patch.object(probe, "_authenticated", fake_authenticated):
                result = asyncio.run(probe.check_file_picker(TEXT_MARKER, PDF_MARKER))
        return result, client

    @staticmethod
    def valid_messages(runtime):
        text_path = runtime / "home" / "attachments" / "semreh-picker.txt"
        image_path = runtime / "home" / "images" / "pdf_p1_20260907_1.png"
        return {
            "session_id": "stored-session",
            "messages": [
                {"id": 1, "role": "user", "content": "warm-up"},
                {"id": 2, "role": "assistant", "content": "SEMREH_SLICE1_ACK"},
                {"id": 3, "role": "user", "content": f"{TEXT_MARKER}\n@file:{text_path}"},
                {"id": 4, "role": "assistant", "content": "SEMREH_SLICE1_ACK"},
                {"id": 5, "role": "user", "content": f"{PDF_MARKER}\n@image:{image_path}"},
                {"id": 6, "role": "assistant", "content": "SEMREH_SLICE1_ACK"},
            ],
        }

    def test_file_picker_turns_share_one_session_and_read_owned_bytes(self):
        result, client = self.run_check()

        self.assertEqual(result["canonical_session_id"], "stored-session")
        self.assertEqual(result["text_user_row_id"], 3)
        self.assertEqual(result["pdf_user_row_id"], 5)
        self.assertEqual(result["row_count"], 6)
        self.assertTrue(result["text_contents_exact"])
        self.assertTrue(result["pdf_one_page_image"])
        self.assertEqual(result["text_bytes"], len(TEXT_BYTES))
        self.assertEqual(result["pdf_image_bytes"], len(PNG_BYTES))
        self.assertEqual(
            [call[0] for call in client.calls],
            ["/api/profiles/sessions", "/api/sessions/stored-session/messages",
             "/api/files/read", "/api/media"],
        )

    def test_rejects_markers_split_across_canonical_sessions(self):
        first = self.valid_messages(Path("/fixture"))
        first["messages"] = first["messages"][:4]
        second = self.valid_messages(Path("/fixture"))
        second["messages"] = [second["messages"][0], second["messages"][1],
                               second["messages"][4], second["messages"][5]]
        with self.assertRaisesRegex(RuntimeError, "markers must each occur exactly once"):
            self.run_check(messages=[first, second])

    def test_rejects_wrong_order_or_intervening_rows(self):
        wrong_order = self.valid_messages(Path("/fixture"))
        wrong_order["messages"][2], wrong_order["messages"][4] = (
            wrong_order["messages"][4], wrong_order["messages"][2]
        )
        with self.assertRaisesRegex(RuntimeError, "wrong order"):
            self.run_check(messages=wrong_order)

        extra = self.valid_messages(Path("/fixture"))
        extra["messages"].insert(4, {"id": 99, "role": "tool", "content": "unexpected"})
        with self.assertRaisesRegex(RuntimeError, "exactly one terminal ACK"):
            self.run_check(messages=extra)

    def test_rejects_duplicate_ids_or_changed_text_bytes(self):
        duplicate = self.valid_messages(Path("/fixture"))
        duplicate["messages"][5]["id"] = duplicate["messages"][4]["id"]
        with self.assertRaisesRegex(RuntimeError, "row identities invalid"):
            self.run_check(messages=duplicate)

        with self.assertRaisesRegex(RuntimeError, "text file contents changed"):
            self.run_check(text_bytes=b"wrong fixture contents")

    def test_rejects_reference_outside_owned_home(self):
        messages = self.valid_messages(Path("/fixture"))
        messages["messages"][2]["content"] = f"{TEXT_MARKER}\n@file:/tmp/semreh-picker.txt"
        with self.assertRaisesRegex(RuntimeError, "escaped owned home"):
            self.run_check(messages=messages)


if __name__ == "__main__":
    unittest.main()
