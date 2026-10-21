import asyncio
import base64
import json
import tempfile
import time
import unittest
import uuid
from pathlib import Path

from aiohttp import ClientSession, WSMsgType, web
from aiohttp.test_utils import TestServer

from companion.domain import APIError, silent_result
from companion.gateway import Gateway
from companion.service import Service, app_for
from companion.store import Store
from companion.tunnel import Tunnel
from relay.server import Relay, app_for as relay_app
from upstream_fixture import HermesFixture


class HostContractTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.upstream = HermesFixture()
        self.upstream_server = TestServer(self.upstream.app)
        await self.upstream_server.start_server()
        self.store = Store(str(Path(self.temp.name) / "companion.db"), self.upstream.profile)
        self.gateway = Gateway(str(self.upstream_server.make_url("")), self.upstream.admin_token, self.upstream.profile, self.store.cursor_key)
        self.service = Service(self.gateway, self.store, poll_interval=3600)
        self.server = TestServer(app_for(self.service))
        await self.server.start_server()
        await asyncio.wait_for(self.gateway.ready.wait(), 3)
        self.client = ClientSession()
        self.pair = await self.request("POST", "/v1/pair", {"code": self.store.invite(), "device_name": "Fixture phone"}, authenticated=False)
        self.headers = {"Authorization": "Bearer " + self.pair["token"]}
        self.relay_server = None

    async def asyncTearDown(self):
        await self.client.close()
        await self.server.close()
        if self.relay_server:
            await self.relay_server.close()
        for ws in list(self.upstream.ws):
            await ws.close()
        await asyncio.gather(*self.upstream.background, return_exceptions=True)
        await self.upstream_server.close()
        self.temp.cleanup()

    async def request(self, method, path, body=None, authenticated=True, status=200, base=None):
        url = str(self.server.make_url(path)) if base is None else base + path
        async with self.client.request(method, url, json=body, headers=getattr(self, "headers", {}) if authenticated else {}) as response:
            data = await response.json()
            self.assertEqual(response.status, status, data)
            self.assertNotIn(self.upstream.admin_token, json.dumps(data))
            return data

    async def test_pair_revoke_closes_stream_and_denies_reads(self):
        await self.request("GET", "/v1/host", authenticated=False, status=401)
        ws = await self.client.ws_connect(self.server.make_url("/v1/events"), headers=self.headers)
        self.assertEqual((await ws.receive_json())["type"], "connection")
        await self.request("DELETE", "/v1/device")
        self.assertIn((await ws.receive(timeout=2)).type, {WSMsgType.CLOSE, WSMsgType.CLOSED})
        await self.request("GET", "/v1/sessions", status=401)
        await ws.close()

    async def test_long_history_cursor_stays_stable_when_rows_append(self):
        first = await self.request("GET", "/v1/sessions/long-session/history")
        self.assertEqual((len(first["messages"]), first["messages"][0]["id"], first["messages"][-1]["id"]), (120, "9881", "10000"))
        self.upstream.histories["long-session"].extend({"id": i, "role": "assistant", "content": "Concurrent append"} for i in range(10001, 10004))
        second = await self.request("GET", "/v1/sessions/long-session/history?before=" + first["before"])
        self.assertEqual([r["id"] for r in second["messages"]], [str(i) for i in range(9761, 9881)])
        await self.request("GET", "/v1/sessions/long-session/history?before=bad", status=400)

    async def test_send_stream_persist_and_uuid_replay(self):
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        ws = await self.client.ws_connect(self.server.make_url("/v1/events"), headers=self.headers)
        await ws.receive_json()
        command = {"operation_id": str(uuid.uuid4()), "kind": "send", "text": "Controlled prompt"}
        receipt = await self.request("POST", "/v1/sessions/long-session/commands", command)
        self.assertEqual(receipt["status"], "accepted")
        deltas, persisted = [], False
        for _ in range(12):
            event = await ws.receive_json(timeout=3)
            if event["type"] == "delta":
                deltas.append(event["payload"]["text"])
            if event["type"] == "snapshot" and event["payload"]["page"]["messages"][-1]["text"] == "Controlled answer":
                persisted = True
                break
        self.assertEqual("".join(deltas), "Controlled answer")
        self.assertTrue(persisted)
        self.assertEqual(await self.request("POST", "/v1/sessions/long-session/commands", command), receipt)
        self.assertEqual(self.upstream.submissions, 1)
        await self.request("POST", "/v1/sessions/long-session/commands", {**command, "text": "Different"}, status=409)
        await ws.close()

    async def test_lost_ack_is_uncertain_and_never_retried(self):
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        command = {"operation_id": str(uuid.uuid4()), "kind": "send", "text": "DROP_ACK"}
        receipt = await self.request("POST", "/v1/sessions/long-session/commands", command, status=409)
        self.assertEqual(receipt["status"], "uncertain")
        await asyncio.wait_for(self.gateway.ready.wait(), 4)
        duplicate = await self.request("POST", "/v1/sessions/long-session/commands", command, status=409)
        self.assertEqual(duplicate, receipt)
        self.assertEqual(self.upstream.submissions, 1)

    async def next_event(self, ws, kind):
        for _ in range(12):
            try:
                event = await ws.receive_json(timeout=3)
            except TimeoutError:
                self.fail("Timed out waiting for event: " + kind)
            if event["type"] == kind:
                return event
        self.fail("Expected event: " + kind)

    async def test_settled_session_info_publishes_idle_after_completion_while_running(self):
        answer = "Canonical completed answer"
        self.upstream.inflight = {"assistant": answer, "streaming": True}
        initial = await self.request("GET", "/v1/sessions/long-session/snapshot")
        self.assertEqual(initial["state"], "working")
        ws = await self.client.ws_connect(self.server.make_url("/v1/events"), headers=self.headers)
        self.addAsyncCleanup(ws.close)
        await ws.receive_json()
        self.upstream.histories["long-session"].append({"id": 10001, "role": "assistant", "content": answer})
        await self.upstream.event("message.complete", {"text": answer, "status": "complete", "persisted_turn": {"final_assistant_row_id": 10001}})
        completion = (await self.next_event(ws, "snapshot"))["payload"]
        self.assertEqual(completion["state"], "working")
        self.assertTrue(any(row["id"] == "10001" and row["text"] == answer and not row["provisional"] for row in completion["page"]["messages"]))
        self.upstream.inflight = None
        await self.upstream.event("session.info", {"running": False})
        settled = await self.next_event(ws, "connection")
        self.assertEqual(settled["session_id"], "long-session")
        self.assertEqual(settled["payload"]["state"], "idle")
        await ws.close()

    async def test_session_info_publishes_current_turn_and_request_state(self):
        for expected in ["working", "waiting"]:
            with self.subTest(state=expected):
                self.upstream.inflight = None
                self.upstream.requests = []
                await self.request("GET", "/v1/sessions/long-session/snapshot")
                ws = await self.client.ws_connect(self.server.make_url("/v1/events"), headers=self.headers)
                self.addAsyncCleanup(ws.close)
                await ws.receive_json()
                self.upstream.inflight = {"assistant": "A newer turn", "streaming": True}
                if expected == "waiting":
                    self.upstream.requests = [{"id": "approval-new-turn", "method": "approval", "params": {"command": "Controlled approval"}}]
                await self.upstream.event("session.info", {"running": False})
                current = await self.next_event(ws, "connection")
                self.assertEqual(current["session_id"], "long-session")
                self.assertEqual(current["payload"]["state"], expected)
                await ws.close()

    async def test_settled_session_info_reaches_subscriber_after_another_snapshot_read(self):
        self.upstream.inflight = {"assistant": "Completed answer", "streaming": True}
        initial = await self.request("GET", "/v1/sessions/long-session/snapshot")
        self.assertEqual(initial["state"], "working")
        ws = await self.client.ws_connect(self.server.make_url("/v1/events"), headers=self.headers)
        self.addAsyncCleanup(ws.close)
        await ws.receive_json()
        self.upstream.inflight = None
        other_reader = await self.request("GET", "/v1/sessions/long-session/snapshot")
        self.assertEqual(other_reader["state"], "idle")
        await self.upstream.event("session.info", {"running": False})
        settled = await self.next_event(ws, "connection")
        self.assertEqual(settled["session_id"], "long-session")
        self.assertEqual(settled["payload"]["state"], "idle")
        await ws.close()

    async def test_unchanged_session_info_refreshes_controls_and_current_state(self):
        self.upstream.inflight = {"assistant": "Still working", "streaming": True}
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        ws = await self.client.ws_connect(self.server.make_url("/v1/events"), headers=self.headers)
        self.addAsyncCleanup(ws.close)
        await ws.receive_json()
        await self.upstream.event("session.info", {"running": True})
        controls = await ws.receive_json(timeout=3)
        self.assertEqual(controls["type"], "controls")
        current = await ws.receive_json(timeout=3)
        self.assertEqual(current["type"], "connection")
        self.assertEqual(current["session_id"], "long-session")
        self.assertEqual(current["payload"]["state"], "working")
        await ws.close()

    async def test_controls_read_back_and_require_model_confirmation(self):
        self.upstream.lazy_model_options = True
        controls = await self.request("GET", "/v1/sessions/long-session/controls")
        self.assertEqual(controls["reasoning_levels"], ["none", "low", "medium", "high"])
        self.assertNotIn("shell", [r["name"] for r in controls["commands"]])
        command = {"operation_id": str(uuid.uuid4()), "kind": "model", "value": "expensive-model", "provider": "fixture-provider"}
        first = await self.request("POST", "/v1/sessions/long-session/commands", command)
        self.assertEqual(first["status"], "rejected")
        self.assertEqual(first["confirmation"]["value"], "expensive-model")
        self.assertEqual(self.upstream.models["long-session"], "small-model")
        await self.request("POST", "/v1/sessions/long-session/commands", {**command, "operation_id": str(uuid.uuid4()), "confirmed": True})
        await self.request("POST", "/v1/sessions/long-session/commands", {"operation_id": str(uuid.uuid4()), "kind": "reasoning", "value": "low"})
        controls = await self.request("GET", "/v1/sessions/long-session/controls")
        self.assertEqual((controls["model"], controls["reasoning"]), ("expensive-model", "low"))

    async def test_approval_refresh_rejects_cancellation_and_stale_generation(self):
        self.upstream.requests = [{"id": "srq-controlled", "method": "approval", "params": {"request_id": "queue-id", "command": "controlled", "description": "Controlled approval", "choices": ["once", "deny"]}}]
        snapshot = await self.request("GET", "/v1/sessions/long-session/snapshot")
        card = snapshot["requests"][0]
        command = {"operation_id": str(uuid.uuid4()), "kind": "answer", "request_id": card["id"], "generation": card["generation"], "answer": "once"}
        self.upstream.requests = []
        rejected = await self.request("POST", "/v1/sessions/long-session/commands", command, status=409)
        self.assertEqual(rejected["error"]["code"], "stale_request")
        self.assertEqual(self.upstream.answers, 0)
        await self.request("POST", "/v1/sessions/long-session/commands", {**command, "operation_id": str(uuid.uuid4()), "generation": "old"}, status=409)

    async def test_profiles_and_arbitrary_commands_cannot_escape(self):
        await self.request("GET", "/v1/host?profile=default", status=400)
        await self.request("POST", "/v1/sessions/long-session/commands", {"operation_id": str(uuid.uuid4()), "kind": "send", "text": "/shell print secrets"}, status=400)
        self.assertEqual(self.upstream.submissions, 0)
        await self.request("POST", "/v1/rpc", {"operation_id": str(uuid.uuid4()), "method": "shell.exec"}, status=404)

    async def test_relay_routes_only_paired_device_to_its_host(self):
        secret = "relay-host-secret-at-least-32-characters"
        relay = Relay({"host-one-123": secret, "host-two-456": "second-host-secret-at-least-32-characters"})
        self.relay_server = TestServer(relay_app(relay))
        await self.relay_server.start_server()
        relay_url = str(self.relay_server.make_url("")).replace("http:", "ws:").rstrip("/")
        tunnel = Tunnel(self.service, relay_url, "host-one-123", secret)
        self.service.relay = tunnel
        await tunnel.start()
        for _ in range(50):
            if "host-one-123" in relay.connections:
                break
            await asyncio.sleep(0.01)
        base = str(self.relay_server.make_url("/h/host-one-123")).rstrip("/")
        await self.request("GET", "/v1/host", authenticated=False, status=401, base=base)
        host = await self.request("GET", "/v1/host", base=base)
        self.assertEqual(host["profile"], "fixture-profile")
        connection = relay.connections["host-one-123"]
        connection.pending.update({f"occupied-{index}": asyncio.get_running_loop().create_future() for index in range(64)})
        for _ in range(140):
            async with self.client.get(base + "/v1/events", headers=self.headers) as response:
                await response.read()
                self.assertEqual(response.status, 503)
        self.assertEqual(len(connection.streams), 0)
        connection.pending.clear()
        other = str(self.relay_server.make_url("/h/host-two-456")).rstrip("/")
        await self.request("GET", "/v1/host", base=other, status=503)
        ws = await self.client.ws_connect(base + "/v1/events", headers=self.headers)
        self.assertEqual((await ws.receive_json(timeout=3))["type"], "connection")
        await self.request("DELETE", "/v1/device", base=base)
        self.assertIn((await ws.receive(timeout=3)).type, {WSMsgType.CLOSE, WSMsgType.CLOSED})
        await ws.close()

    async def test_jobs_are_official_and_duplicate_results_are_suppressed(self):
        job = await self.request("POST", "/v1/jobs", {"operation_id": str(uuid.uuid4()), "session_id": "long-session", "name": "Watch fixture", "instruction": "Report changed value", "schedule": "every 1h", "notify": "changes"})
        self.assertEqual(job["session_id"], "long-session")
        for index, body in enumerate(["A changed value", "A changed value", "[SILENT] No change", "A second change"]):
            run = f"cron_{job['id']}_{index}"
            self.upstream.histories[run] = [{"id": index + 20000, "role": "assistant", "content": body}]
            self.upstream.runs[job["id"]].append({"id": run, "source": "cron", "started_at": time.time(), "ended_at": time.time(), "is_active": False})
            await self.service.proactive.poll_once()
        updates = await self.request("GET", "/v1/updates")
        self.assertEqual(len(updates["updates"]), 2)
        detail = await self.request("GET", "/v1/updates/" + updates["updates"][0]["id"])
        self.assertEqual(detail["text"], "A second change")
        self.assertTrue(detail["result_session_id"].startswith("cron_"))
        paused = await self.request("PATCH", "/v1/jobs/" + job["id"], {"operation_id": str(uuid.uuid4()), "enabled": False})
        self.assertFalse(paused["enabled"])
        self.assertFalse(self.upstream.jobs[job["id"]]["enabled"])
        self.assertEqual(len(self.upstream.histories["long-session"]), 10000)

    async def test_hermes_silence_variants(self):
        for value in ["[SILENT]", "NO_REPLY", "no reply", "Nothing changed.\nNO_REPLY", "[SILENT] Nothing changed"]:
            self.assertTrue(silent_result(value), value)
        for value in ["The report quotes NO_REPLY inside a sentence.", ""]:
            self.assertFalse(silent_result(value), value)

    async def test_chat_only_grant_cannot_change_controls_through_slash(self):
        restricted = self.store.pair(self.store.invite(scopes={"read", "chat"}), "Limited phone")
        self.headers = {"Authorization": "Bearer " + restricted["token"]}
        await self.request("POST", "/v1/sessions/long-session/commands", {"operation_id": str(uuid.uuid4()), "kind": "send", "text": "/reasoning high"}, status=403)
        self.assertFalse(any(method == "config.set" for method, _ in self.upstream.calls))

    async def test_revoke_while_attach_waits_prevents_late_submit(self):
        self.upstream.block_method = "session.resume"
        submit = asyncio.create_task(self.request("POST", "/v1/sessions/long-session/commands", {"operation_id": str(uuid.uuid4()), "kind": "send", "text": "Must not submit"}, status=401))
        await asyncio.wait_for(self.upstream.blocked.wait(), 2)
        revoke = asyncio.create_task(self.request("DELETE", "/v1/device"))
        for _ in range(50):
            if not self.store.active(self.pair["device_id"]):
                break
            await asyncio.sleep(0.01)
        self.upstream.release.set()
        await asyncio.gather(submit, revoke)
        self.assertEqual(self.upstream.submissions, 0)

    async def test_generation_change_during_approval_refresh_prevents_answer(self):
        self.upstream.requests = [{"id": "srq-controlled", "method": "approval", "params": {"request_id": "queue-id", "choices": ["once", "deny"]}}]
        snapshot = await self.request("GET", "/v1/sessions/long-session/snapshot")
        self.upstream.block_method = "session.activate"
        card = snapshot["requests"][0]
        answer = asyncio.create_task(self.request("POST", "/v1/sessions/long-session/commands", {"operation_id": str(uuid.uuid4()), "kind": "answer", "request_id": card["id"], "generation": card["generation"], "answer": "once"}, status=409))
        await asyncio.wait_for(self.upstream.blocked.wait(), 2)
        self.gateway.generation = "controlled-new-connection-generation"
        self.upstream.release.set()
        result = await answer
        self.assertEqual(result["error"]["code"], "stale_request")
        self.assertEqual(self.upstream.answers, 0)

    async def test_snapshot_reserves_inflight_slot_without_losing_history(self):
        self.upstream.inflight = {"assistant": "Partial live answer", "streaming": True}
        snapshot = await self.request("GET", "/v1/sessions/long-session/snapshot")
        self.assertEqual(len(snapshot["page"]["messages"]), 120)
        self.assertTrue(snapshot["page"]["messages"][-1]["provisional"])
        older = await self.request("GET", "/v1/sessions/long-session/history?before=" + snapshot["page"]["before"])
        self.assertEqual(older["messages"][-1]["id"], "9881")

    async def test_created_sessions_keep_live_cache_bounded(self):
        for _ in range(140):
            await self.request("POST", "/v1/sessions", {"operation_id": str(uuid.uuid4())})
        self.assertLessEqual(len(self.gateway.live), 128)
        self.assertEqual(len(self.upstream.histories), 141)

    async def test_stream_burst_coalesces_without_dropping_or_closing(self):
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        ws = await self.client.ws_connect(self.server.make_url("/v1/events"), headers=self.headers)
        await ws.receive_json()
        await self.request("POST", "/v1/sessions/long-session/commands", {"operation_id": str(uuid.uuid4()), "kind": "send", "text": "STREAM_BURST"})
        text_parts, snapshots = [], []
        for _ in range(20):
            event = await ws.receive_json(timeout=3)
            if event["type"] == "delta":
                text_parts.append(event["payload"]["text"])
            if event["type"] == "snapshot":
                snapshots.append(event["payload"])
                break
        self.assertEqual("".join(text_parts), "word " * 500)
        self.assertLess(len(text_parts), 20)
        self.assertEqual(snapshots[-1]["page"]["messages"][-1]["text"], "word " * 500)
        self.assertFalse(ws.closed)
        await ws.close()

    async def test_completion_update_reads_its_canonical_row_after_later_turns(self):
        await self.request("POST", "/v1/sessions/long-session/commands", {"operation_id": str(uuid.uuid4()), "kind": "send", "text": "First prompt"})
        updates = []
        for _ in range(100):
            updates = (await self.request("GET", "/v1/updates"))["updates"]
            if updates:
                break
            await asyncio.sleep(0.01)
        self.assertTrue(updates)
        self.upstream.histories["long-session"].append({"id": 10003, "role": "assistant", "content": "A later unrelated answer"})
        detail = await self.request("GET", "/v1/updates/" + updates[0]["id"])
        self.assertEqual(detail["text"], "Controlled answer")

    async def test_script_result_uses_validated_official_path_and_rejects_ledger_preview(self):
        job = "script-job"
        run = "cron_output:script-job:2026-10-19_10-00-00"
        ledger = "cron_output:script-job:exec:0"
        self.upstream.runs[job] = [{"id": run, "source": "cron_output"}, {"id": ledger, "source": "cron_output", "preview": "A short noncanonical preview"}]
        content = "The complete controlled script output"
        self.upstream.outputs["/controlled/profile/cron/output/script-job/2026-10-19_10-00-00.md"] = "data:text/markdown;base64," + base64.b64encode(content.encode()).decode()
        result, session = await self.service.proactive.result_text({"job_id": job, "run_id": run})
        self.assertEqual((result, session), (content, None))
        with self.assertRaises(APIError) as raised:
            await self.service.proactive.result_text({"job_id": job, "run_id": ledger})
        self.assertEqual(raised.exception.code, "result_unavailable")

    async def test_result_readiness_does_not_hide_other_completed_jobs(self):
        for job in ["not-ready", "ready"]:
            self.upstream.jobs[job] = {"id": job, "name": job, "prompt": "Controlled", "enabled": True}
            run = "cron_" + job + "_1"
            self.upstream.runs[job] = [{"id": run, "source": "cron", "started_at": time.time(), "ended_at": time.time()}]
            self.upstream.histories[run] = [] if job == "not-ready" else [{"id": 20001, "role": "assistant", "content": "Ready result"}]
        await self.service.proactive.poll_once()
        updates = (await self.request("GET", "/v1/updates"))["updates"]
        self.assertEqual([row["title"] for row in updates], ["ready"])
        self.assertFalse(self.store.observed("not-ready", "cron_not-ready_1"))

    async def test_routine_update_keeps_original_row_after_later_turns_and_restart(self):
        job, run = "stable-result", "cron_stable-result_1"
        self.upstream.jobs[job] = {"id": job, "name": "Routine", "enabled": True}
        self.upstream.runs[job] = [{"id": run, "source": "cron", "started_at": time.time(), "ended_at": time.time()}]
        self.upstream.histories[run] = [{"id": 30001, "role": "assistant", "content": "Original routine outcome"}]
        await self.service.proactive.poll_once()
        update = (await self.request("GET", "/v1/updates"))["updates"][0]
        self.upstream.histories[run].extend({"id": i, "role": "assistant", "content": "Later unrelated answer"} for i in range(30002, 30243))
        previous = self.store
        self.store = Store(str(Path(self.temp.name) / "companion.db"), self.upstream.profile)
        self.service.store = self.service.proactive.store = self.store
        previous.close()
        detail = await self.request("GET", "/v1/updates/" + update["id"])
        self.assertEqual(detail["text"], "Original routine outcome")
        self.assertEqual(detail["result_session_id"], run)
        self.upstream.histories[run].pop(0)
        missing = await self.request("GET", "/v1/updates/" + update["id"], status=404)
        self.assertEqual(missing["error"]["code"], "result_unavailable")

    async def test_legacy_routine_update_without_row_identity_does_not_guess(self):
        job, run = "legacy-result", "cron_legacy-result_1"
        self.upstream.runs[job] = [{"id": run, "source": "cron", "ended_at": time.time()}]
        self.upstream.histories[run] = [{"id": 30002, "role": "assistant", "content": "Unrelated later answer"}]
        update = self.store.add_update("legacy-result", {"kind": "result", "title": "Routine", "summary": "Original routine outcome"}, {"job_id": job, "run_id": run})
        response = await self.request("GET", "/v1/updates/" + update["id"], status=404)
        self.assertEqual(response["error"]["code"], "result_unavailable")

    async def test_revoke_during_request_refresh_prevents_push_dispatch(self):
        entered, release = asyncio.Event(), asyncio.Event()
        sent = []
        class Push:
            async def send(self, device, update):
                sent.append(update["id"])
                return "sent"
            async def close(self):
                pass
        async def snapshot(session):
            entered.set()
            await release.wait()
            return {"requests": [{"id": "request", "generation": "generation"}]}
        self.service.proactive.apns = Push()
        self.gateway.snapshot = snapshot
        await self.request("PATCH", "/v1/device", {"push_token": "a" * 64, "environment": "sandbox"})
        update = self.store.add_update("revoke-request", {"kind": "needs_you", "title": "Approve", "summary": "", "session_id": "long-session"}, {"session_id": "long-session", "request_id": "request", "generation": "generation"}, now=10)
        delivery = asyncio.create_task(self.service.proactive.deliver_once(now=11))
        try:
            await asyncio.wait_for(entered.wait(), 1)
            await self.request("DELETE", "/v1/device")
        finally:
            release.set()
            await delivery
        self.assertEqual(sent, [])
        self.assertEqual(self.store.db.execute("SELECT state FROM outbox WHERE update_id=?", (update["id"],)).fetchone()[0], "revoked")

    async def test_push_response_after_revocation_keeps_terminal_outbox_state(self):
        entered, release = asyncio.Event(), asyncio.Event()
        sent = []
        class Push:
            async def send(self, device, update):
                sent.append(update["id"])
                entered.set()
                await release.wait()
                return "sent"
            async def close(self):
                pass
        self.service.proactive.apns = Push()
        await self.request("PATCH", "/v1/device", {"push_token": "a" * 64, "environment": "sandbox"})
        update = self.store.add_update("already-dispatched", {"kind": "result", "title": "Done", "summary": ""}, {"session_id": "long-session", "row_id": "10000"}, now=10)
        delivery = asyncio.create_task(self.service.proactive.deliver_once(now=11))
        try:
            await asyncio.wait_for(entered.wait(), 1)
            await self.request("DELETE", "/v1/device")
        finally:
            release.set()
            await delivery
        self.assertEqual(sent, [update["id"]])
        self.assertEqual(self.store.db.execute("SELECT state FROM outbox WHERE update_id=?", (update["id"],)).fetchone()[0], "revoked")
        await self.service.proactive.deliver_once(now=100)
        self.assertEqual(sent, [update["id"]])
