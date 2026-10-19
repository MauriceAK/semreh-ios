import asyncio
import base64
import json
import time
import unittest
import uuid

from aiohttp.test_utils import TestServer

from companion.attachments import MAX_FILE_BYTES, MAX_TEXT_BYTES
from companion.tunnel import Tunnel
from companion.store import Store
from relay.server import Relay, app_for as relay_app
import test_service


class AttachmentContractTests(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = test_service.HostContractTests.asyncSetUp
    asyncTearDown = test_service.HostContractTests.asyncTearDown
    request = test_service.HostContractTests.request

    def payload(self, data=b"Private controlled text", name="notes.txt", media="text/plain"):
        return {"operation_id": str(uuid.uuid4()), "name": name, "media_type": media,
                "content_base64": base64.b64encode(data).decode()}

    async def upload(self, payload=None, session="long-session", **kwargs):
        return await self.request("POST", f"/v1/sessions/{session}/attachments", payload or self.payload(), **kwargs)

    async def send(self, ids, value="", session="long-session", **kwargs):
        body = {"operation_id": str(uuid.uuid4()), "kind": "send", "text": value, "attachment_ids": ids}
        return await self.request("POST", f"/v1/sessions/{session}/commands", body, **kwargs)

    async def relay(self):
        secret = "attachment-fixture-relay-secret-32-characters"
        relay = Relay({"attachment-host": secret})
        self.relay_server = TestServer(relay_app(relay))
        await self.relay_server.start_server()
        tunnel = Tunnel(self.service, str(self.relay_server.make_url("")).replace("http:", "ws:").rstrip("/"), "attachment-host", secret)
        self.service.relay = tunnel
        await tunnel.start()
        for _ in range(100):
            if "attachment-host" in relay.connections:
                return str(self.relay_server.make_url("/h/attachment-host")).rstrip("/")
            await asyncio.sleep(0.01)
        self.fail("Relay tunnel did not connect")

    async def test_file_only_send_uses_exact_ref_and_projects_canonical_row(self):
        item = await self.upload()
        self.assertEqual(set(item), {"id", "name", "media_type", "byte_count", "status"})
        self.assertEqual(item["status"], "ready")
        self.assertEqual(self.upstream.submissions, 0)
        receipt = await self.send([item["id"]])
        self.assertEqual(receipt["status"], "accepted")
        prompt = next(params["text"] for method, params in self.upstream.calls if method == "prompt.submit")
        self.assertEqual(prompt, next(iter(self.upstream.files)))
        self.assertTrue(next(params["queued"] for method, params in self.upstream.calls if method == "prompt.submit"))
        self.assertFalse(any(method.startswith("image.") for method, _ in self.upstream.calls))
        page = await self.request("GET", "/v1/sessions/long-session/history")
        row = next(row for row in page["messages"] if row["id"] == receipt["user_row_id"])
        self.assertEqual(row["text"], "")
        self.assertEqual(row["attachments"], [item])
        again = await self.send([item["id"]], status=409)
        self.assertEqual(again["error"]["code"], "attachment_unavailable")
        self.assertEqual(self.upstream.submissions, 1)

    async def test_upload_and_send_replay_cannot_duplicate_or_change_content(self):
        body = self.payload()
        item = await self.upload(body)
        self.assertEqual(await self.upload(body), item)
        await self.upload({**body, "content_base64": base64.b64encode(b"changed").decode()}, status=409)
        self.assertEqual(len(self.upstream.files), 1)
        command = {"operation_id": str(uuid.uuid4()), "kind": "send", "text": "Read this", "attachment_ids": [item["id"]]}
        receipt = await self.request("POST", "/v1/sessions/long-session/commands", command)
        self.assertEqual(await self.request("POST", "/v1/sessions/long-session/commands", command), receipt)
        self.assertEqual(self.upstream.submissions, 1)

    async def test_tickets_cannot_cross_device_or_conversation(self):
        item = await self.upload()
        session = await self.request("POST", "/v1/sessions", {"operation_id": str(uuid.uuid4())})
        wrong = await self.send([item["id"]], session=session["id"], status=404)
        self.assertEqual(wrong["error"]["code"], "attachment_not_found")
        other = self.store.pair(self.store.invite(), "Another device")
        self.headers = {"Authorization": "Bearer " + other["token"]}
        await self.send([item["id"]], status=404)
        await self.request("DELETE", "/v1/sessions/long-session/attachments/" + item["id"], {"operation_id": str(uuid.uuid4())}, status=404)
        self.assertEqual(self.upstream.submissions, 0)

    async def test_expiry_removal_and_duplicate_ids_fail_before_submit(self):
        item = await self.upload()
        await self.send([item["id"], item["id"]], status=400)
        with self.store.db:
            self.store.db.execute("UPDATE attachments SET expires=? WHERE id=?", (time.time() - 1, item["id"]))
        expired = await self.send([item["id"]], status=410)
        self.assertEqual(expired["error"]["code"], "attachment_expired")
        item = await self.upload()
        path = "/v1/sessions/long-session/attachments/" + item["id"]
        body = {"operation_id": str(uuid.uuid4())}
        self.assertEqual(await self.request("DELETE", path, body), {"removed": True})
        self.assertEqual(await self.request("DELETE", path, body), {"removed": True})
        await self.send([item["id"]], status=409)
        self.assertEqual(self.upstream.submissions, 0)

    async def test_slash_and_other_commands_cannot_consume_attachments(self):
        item = await self.upload()
        for value in ("/model", "  /status", "/shell"):
            result = await self.send([item["id"]], value, status=400)
            self.assertEqual(result["error"]["code"], "invalid_attachment")
        await self.request("POST", "/v1/sessions/long-session/commands", {"operation_id": str(uuid.uuid4()), "kind": "interrupt", "attachment_ids": [item["id"]]}, status=400)
        await self.send([item["id"]], "Normal message")
        self.assertEqual(self.upstream.submissions, 1)

    async def test_invalid_media_bytes_base64_name_and_limits_never_reach_gateway(self):
        invalid = [self.payload(b"text", "notes.zip", "application/zip"), self.payload(b"text", "photo.jpg", "image/jpeg"),
                   self.payload(b"text", "image.png", "image/png"), self.payload(b"text", "file.pdf", "application/pdf"),
                   self.payload(b"\xff\x00", "data.txt"), self.payload(b"", "empty.txt"),
                   {**self.payload(), "content_base64": "not!base64"}]
        invalid += [self.payload(name=name) for name in ("../notes.txt", "a\\b.txt", "@file:notes.txt", "notes\n.txt", "`name`.txt")]
        invalid.append(self.payload(name="名" * 100 + ".txt"))
        for body in invalid:
            with self.subTest(name=body["name"]):
                await self.upload(body, status=400)
        await self.upload(self.payload(b"a" * (MAX_TEXT_BYTES + 1)), status=413)
        await self.upload(self.payload(b"%PDF-" + b"a" * MAX_FILE_BYTES, "file.pdf", "application/pdf"), status=413)
        self.assertEqual(self.upstream.files, {})

    async def test_read_only_and_revoked_grants_cannot_upload_or_send(self):
        item = await self.upload()
        read_only = self.store.pair(self.store.invite(scopes={"read"}), "Read-only phone")
        self.headers = {"Authorization": "Bearer " + read_only["token"]}
        await self.upload(status=403)
        await self.send([item["id"]], status=403)
        self.headers = {"Authorization": "Bearer " + self.pair["token"]}
        await self.request("DELETE", "/v1/device")
        await self.upload(status=401)
        await self.send([item["id"]], status=401)
        self.assertEqual(len(self.upstream.files), 1)
        self.assertEqual(self.upstream.submissions, 0)

    async def test_revocation_while_waiting_for_gateway_prevents_upload(self):
        self.gateway.ready.clear()
        body = self.payload()
        upload = asyncio.create_task(self.upload(body, status=401))
        for _ in range(100):
            if self.store.db.execute("SELECT 1 FROM attachments").fetchone():
                break
            await asyncio.sleep(0.01)
        self.store.revoke(self.pair["device_id"])
        self.gateway.ready.set()
        await upload
        self.assertEqual(self.upstream.files, {})

    async def test_unknown_upload_and_send_outcomes_are_never_replayed(self):
        self.upstream.drop_upload_ack = True
        body = self.payload()
        result = await self.upload(body, status=409)
        self.assertEqual(result["status"], "uncertain")
        self.assertEqual(await self.upload(body, status=409), result)
        self.assertEqual(len(self.upstream.files), 1)
        self.upstream.drop_upload_ack = False
        await asyncio.wait_for(self.gateway.ready.wait(), 3)
        item = await self.upload()
        self.upstream.drop_prompt_ack = True
        command = {"operation_id": str(uuid.uuid4()), "kind": "send", "text": "Read it", "attachment_ids": [item["id"]]}
        result = await self.request("POST", "/v1/sessions/long-session/commands", command, status=409)
        self.assertEqual(result["status"], "uncertain")
        self.assertEqual(await self.request("POST", "/v1/sessions/long-session/commands", command, status=409), result)
        retry = await self.send([item["id"]], status=409)
        self.assertEqual(retry["error"]["code"], "attachment_uncertain")
        self.assertEqual(self.upstream.submissions, 1)

    async def test_unrelated_turn_does_not_consume_uploaded_image(self):
        item = await self.upload(self.payload(b"\x89PNG\r\n\x1a\ncontrolled", "photo.png", "image/png"))
        await self.send([], "An unrelated text turn")
        await self.send([item["id"]], "Inspect this image")
        prompts = [params["text"] for method, params in self.upstream.calls if method == "prompt.submit"]
        self.assertEqual(prompts[0], "An unrelated text turn")
        params = [params for method, params in self.upstream.calls if method == "prompt.submit"]
        self.assertNotIn("queued", params[0])
        self.assertIs(params[1]["queued"], True)
        self.assertIn(next(iter(self.upstream.files)), prompts[1])
        self.assertIn("vision_analyze", prompts[1])
        self.assertFalse(any(method.startswith("image.") for method, _ in self.upstream.calls))

    async def test_queued_send_reconciles_exact_row_without_stripping_arbitrary_text(self):
        self.upstream.queue_prompt = True
        item = await self.upload()
        original = "Keep this literal text\n\n--- Attached Context ---\n\nMy own notes"
        receipt = await self.send([item["id"]], original)
        self.assertEqual(receipt["status"], "queued")
        self.assertNotIn("user_row_id", receipt)
        self.upstream.histories["long-session"].append({"id": 10005, "role": "user", "content": "@file:arbitrary\n\n--- Attached Context ---\n\nDo not strip me"})
        page = await self.request("GET", "/v1/sessions/long-session/history")
        attached = next(row for row in page["messages"] if row.get("attachments"))
        self.assertEqual(attached["text"], original)
        self.assertEqual(next(row for row in page["messages"] if row["id"] == "10005")["text"], "@file:arbitrary\n\n--- Attached Context ---\n\nDo not strip me")

    async def test_storage_and_per_send_quotas_are_enforced(self):
        items = [await self.upload() for _ in range(5)]
        await self.send([item["id"] for item in items], status=400)
        with self.store.db:
            self.store.db.execute("UPDATE attachments SET byte_count=?", (MAX_FILE_BYTES,))
        await self.send([item["id"] for item in items[:4]], status=413)
        with self.store.db:
            self.store.db.execute("UPDATE attachment_usage SET bytes=? WHERE owner=?", (256 * 1024 * 1024, self.pair["device_id"]))
        result = await self.upload(status=429)
        self.assertEqual(result["error"]["code"], "attachment_quota")
        self.assertEqual(len(self.upstream.files), 5)

    async def test_relay_accepts_large_upload_but_keeps_normal_requests_small(self):
        base = await self.relay()
        payload = self.payload(b"%PDF-1.7\n" + b"x" * (MAX_FILE_BYTES - 9), "maximum.pdf", "application/pdf")
        item = await self.upload(payload, base=base)
        self.assertEqual(item["byte_count"], MAX_FILE_BYTES)
        host = await self.request("GET", "/v1/host", base=base)
        self.assertEqual(host["capabilities"]["attachment_limits"]["max_text_bytes"], MAX_TEXT_BYTES)
        await self.request("POST", "/v1/sessions/long-session/commands", {"operation_id": str(uuid.uuid4()), "kind": "send", "text": "x" * (256 * 1024)}, status=413, base=base)
        await self.request("POST", "/v1/sessions/long-session/commands", {"operation_id": str(uuid.uuid4()), "kind": "send", "text": "x" * (256 * 1024)}, status=413)
        await self.request("DELETE", "/v1/sessions/long-session/attachments/" + item["id"], {"operation_id": str(uuid.uuid4())}, base=base)
        self.assertEqual(len(self.upstream.files), 1)

    async def test_large_canonical_history_reduces_upstream_page_without_missing_rows(self):
        self.upstream.histories["long-session"] = [{"id": index, "role": "user", "content": "x" * MAX_TEXT_BYTES} for index in range(1, 151)]
        seen, cursor = [], None
        while True:
            page = await self.request("GET", "/v1/sessions/long-session/history" + ("?before=" + cursor if cursor else ""))
            self.assertLessEqual(len(json.dumps(page).encode()), 4 * 1024 * 1024)
            seen.extend(row["id"] for row in page["messages"])
            cursor = page["before"]
            if cursor is None:
                break
        self.assertEqual(len(seen), 150)
        self.assertEqual(set(seen), {str(index) for index in range(1, 151)})

    async def test_two_simultaneous_sends_cannot_reuse_one_attachment(self):
        item = await self.upload()
        async def attempt():
            async with self.client.post(self.server.make_url("/v1/sessions/long-session/commands"), headers=self.headers,
                                        json={"operation_id": str(uuid.uuid4()), "kind": "send", "text": "Only once", "attachment_ids": [item["id"]]}) as response:
                return response.status, await response.json()
        results = await asyncio.gather(attempt(), attempt())
        self.assertEqual(sorted(status for status, _ in results), [200, 409])
        self.assertEqual(self.upstream.submissions, 1)

    async def test_revocation_before_attachment_submit_is_rechecked(self):
        item = await self.upload()
        self.gateway.ready.clear()
        sending = asyncio.create_task(self.send([item["id"]], "Read this", status=401))
        for _ in range(100):
            if self.store.db.execute("SELECT state FROM attachments WHERE id=?", (item["id"],)).fetchone()[0] == "sending":
                break
            await asyncio.sleep(0.01)
        self.store.revoke(self.pair["device_id"])
        self.gateway.ready.set()
        await sending
        self.assertEqual(self.upstream.submissions, 0)

    async def test_ready_ticket_and_canonical_projection_survive_store_restart(self):
        item = await self.upload()
        path = str(self.store.db.execute("PRAGMA database_list").fetchone()[2])
        self.store.close()
        self.store = Store(path, self.upstream.profile)
        self.service.store = self.service.proactive.store = self.service.hub.store = self.service.attachments.store = self.store
        receipt = await self.send([item["id"]], "Persist this attachment")
        self.store.close()
        self.store = Store(path, self.upstream.profile)
        self.service.store = self.service.proactive.store = self.service.hub.store = self.service.attachments.store = self.store
        page = await self.request("GET", "/v1/sessions/long-session/history")
        row = next(row for row in page["messages"] if row["id"] == receipt["user_row_id"])
        self.assertEqual(row["text"], "Persist this attachment")
        self.assertEqual(row["attachments"], [item])

    async def test_first_attachment_persists_empty_official_draft_before_upload(self):
        self.upstream.lazy_created_sessions = True
        session = await self.request("POST", "/v1/sessions", {"operation_id": str(uuid.uuid4()), "title": "Keep this draft"})
        sid = session["id"]
        self.assertIn(sid, self.upstream.unpersisted)
        current_title = self.gateway.live[sid].title
        body = self.payload()
        item = await self.upload(body, session=sid)
        self.assertEqual(await self.upload(body, session=sid), item)
        self.assertNotIn(sid, self.upstream.unpersisted)
        titles = [params for method, params in self.upstream.calls if method == "session.title"]
        self.assertEqual([params["title"] for params in titles], [current_title])
        self.assertEqual(self.upstream.histories[sid], [])
        self.gateway.live.pop(sid)
        receipt = await self.send([item["id"]], "Resume this draft", session=sid)
        self.assertEqual(receipt["status"], "accepted")
        page = await self.request("GET", f"/v1/sessions/{sid}/history")
        self.assertEqual(page["messages"][0]["attachments"], [item])
        await self.upload()
        self.assertEqual(len([1 for method, _ in self.upstream.calls if method == "session.title"]), 1)

    async def test_revocation_during_empty_draft_persistence_prevents_file_upload(self):
        self.upstream.lazy_created_sessions = True
        session = await self.request("POST", "/v1/sessions", {"operation_id": str(uuid.uuid4())})
        self.upstream.block_method = "session.title"
        task = asyncio.create_task(self.upload(session=session["id"], status=401))
        await asyncio.wait_for(self.upstream.blocked.wait(), 2)
        self.store.revoke(self.pair["device_id"])
        self.upstream.release.set()
        await task
        self.assertEqual(self.upstream.files, {})
        self.assertEqual(self.upstream.submissions, 0)

    async def test_chunked_upload_budget_and_busy_uploads_fail_without_gateway_work(self):
        async def oversized():
            for _ in range(8):
                yield b"x" * (1024 * 1024)
        async with self.client.post(self.server.make_url("/v1/sessions/long-session/attachments"), headers=self.headers,
                                    data=oversized()) as response:
            self.assertEqual(response.status, 413)
        self.service.upload_ingress = 2
        await self.upload(status=503)
        self.service.upload_ingress = 0
        self.assertEqual(self.upstream.files, {})

    async def test_stop_remains_available_while_upload_waits_for_gateway_ack(self):
        entered, release = asyncio.Event(), asyncio.Event()
        upload_method = self.gateway.upload_attachment
        async def held(stored, prepared, authorize):
            entered.set()
            await release.wait()
            return await upload_method(stored, prepared, authorize)
        self.gateway.upload_attachment = held
        upload = asyncio.create_task(self.upload())
        stop = None
        try:
            await asyncio.wait_for(entered.wait(), 2)
            stop = asyncio.create_task(self.request("POST", "/v1/sessions/long-session/commands", {"operation_id": str(uuid.uuid4()), "kind": "interrupt"}))
            await asyncio.wait_for(asyncio.shield(stop), 1)
            self.assertTrue(any(method == "session.interrupt" for method, _ in self.upstream.calls))
            self.assertFalse(upload.done())
        finally:
            release.set()
            await upload
            if stop:
                await stop

    async def test_invalid_relay_uploads_do_not_reserve_slots_or_wait_for_bodies(self):
        base = await self.relay()
        release = asyncio.Event()
        async def stalled():
            yield b'{"content_base64":"'
            await release.wait()
        async def invalid():
            async with self.client.post(base + "/v1/sessions/long-session/attachments", headers={"Authorization": "Bearer invalid"}, data=stalled()) as response:
                return response.status
        blocked = [asyncio.create_task(invalid()) for _ in range(2)]
        try:
            results = await asyncio.wait_for(asyncio.gather(*blocked), 2)
            self.assertEqual(results, [401, 401])
            await self.upload(base=base)
            read_only = self.store.pair(self.store.invite(scopes={"read"}), "Read-only relay phone")
            async with self.client.post(base + "/v1/sessions/long-session/attachments", headers={"Authorization": "Bearer " + read_only["token"]}, data=stalled()) as response:
                self.assertEqual(response.status, 403)
        finally:
            release.set()
            await asyncio.gather(*blocked, return_exceptions=True)
        self.assertEqual(len(self.upstream.files), 1)

    async def test_queued_row_replacement_and_attachment_merge_keep_projection(self):
        self.upstream.queue_prompt = True
        first, second = await self.upload(), await self.upload()
        await self.send([first["id"]], "First queued message")
        await self.send([second["id"]], "Second queued message")
        page = await self.request("GET", "/v1/sessions/long-session/history")
        self.assertEqual(len([row for row in page["messages"] if row.get("attachments")]), 2)
        prompts = [params["text"] for method, params in self.upstream.calls if method == "prompt.submit"]
        self.upstream.histories["long-session"] = [{"id": 20001, "role": "user", "content": "\n\n".join(prompts) + "\n\n--- Attached Context ---\n\nExpanded payload"}]
        page = await self.request("GET", "/v1/sessions/long-session/history")
        self.assertEqual(page["messages"][0]["text"], "First queued message\n\nSecond queued message")
        self.assertEqual(page["messages"][0]["attachments"], [first, second])
        self.assertEqual(page["messages"][0]["id"], "20001")
        self.upstream.histories["long-session"][0]["content"] = prompts[0] + "\n\nOutside-client message\n\n--- Attached Context ---\n\nLiteral user text must stay"
        page = await self.request("GET", "/v1/sessions/long-session/history")
        self.assertEqual(page["messages"][0]["text"], "First queued message\n\nOutside-client message\n\n--- Attached Context ---\n\nLiteral user text must stay")

    async def test_unicode_history_uses_bounded_utf8_through_relay_and_events(self):
        base = await self.relay()
        page = {"messages": [{"id": "unicode", "role": "user", "text": "😀" * 900000, "provisional": False}], "before": None, "has_more": False}
        async def history(*args):
            return page
        self.gateway.history = history
        async with self.client.get(base + "/v1/sessions/long-session/history", headers=self.headers) as response:
            raw = await response.read()
            self.assertEqual(response.status, 200)
            self.assertLess(len(raw), 4 * 1024 * 1024)
            self.assertEqual(json.loads(raw), page)
        ws = await self.client.ws_connect(base + "/v1/events", headers=self.headers, max_msg_size=4 * 1024 * 1024)
        await ws.receive_json(timeout=3)
        await self.service.hub.publish({"type": "snapshot", "session_id": "long-session", "payload": {"page": page}})
        event = await ws.receive_json(timeout=5)
        self.assertEqual(event["payload"]["page"], page)
        await self.request("GET", "/v1/host", base=base)
        await ws.close()

    async def test_own_plain_queued_messages_merge_cleanly_without_losing_literal_markers(self):
        self.upstream.queue_prompt = True
        item = await self.upload()
        await self.send([], "Plain before")
        await self.send([item["id"]], "Read the file")
        literal = "Plain after\n\n--- Attached Context ---\n\nThis was typed by the user"
        await self.send([], literal)
        prompts = [params["text"] for method, params in self.upstream.calls if method == "prompt.submit"]
        merged = "\n\n".join(prompts) + "\n\n--- Attached Context ---\n\nExpanded context\n\nPlain before"
        self.upstream.histories["long-session"] = [{"id": 20010, "role": "user", "content": merged}]
        page = await self.request("GET", "/v1/sessions/long-session/history")
        row = page["messages"][0]
        self.assertEqual(row["text"], "Plain before\n\nRead the file\n\n" + literal)
        self.assertEqual(row["attachments"], [item])
        self.upstream.histories["long-session"][0]["id"] = 20011
        page = await self.request("GET", "/v1/sessions/long-session/history")
        self.assertEqual(page["messages"][0]["text"], row["text"])
        self.assertEqual(page["messages"][0]["attachments"], [item])
