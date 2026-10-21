import asyncio
import copy
import json
import unittest

import test_service


class TranscriptProjectionTests(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = test_service.HostContractTests.asyncSetUp
    asyncTearDown = test_service.HostContractTests.asyncTearDown
    request = test_service.HostContractTests.request

    async def history(self, cursor=None):
        path = "/v1/sessions/long-session/history"
        return await self.request("GET", path + ("?before=" + cursor if cursor else ""))

    async def test_only_public_content_reaches_chat_without_rewriting_literal_text(self):
        literal = 'Explain <untrusted_tool_result>{"count": 2}</untrusted_tool_result>\n\n```json\n{"ok": true}\n```'
        answer = '- **Viewer:** `http://127.0.0.1:8766/`\n\nLiteral <think>XML</think> and {"ok": true}.'
        self.upstream.histories["long-session"] = [
            {"id": 1, "role": "system", "content": "Hidden instruction"},
            {"id": 2, "role": "user", "content": literal},
            {"id": 3, "role": "assistant", "content": None, "tool_calls": [{"id": "call-1"}]},
            {"id": 4, "role": "tool", "content": '<untrusted_tool_result>{"private": "tool payload"}</untrusted_tool_result>'},
            {"id": 5, "role": "user", "content": "Synthetic continuation", "display_kind": "auto_continue"},
            {"id": 6, "role": "assistant", "content": "Hidden scaffolding", "display_kind": "hidden"},
            {"id": 7, "role": "assistant", "content": [{"type": "thinking", "text": "Private thought"}, {"type": "tool_result", "text": "Nested tool"}]},
            {"id": 8, "role": "assistant", "content": [{"type": "reasoning", "text": "Private chain"}, {"type": "text", "text": answer}], "reasoning_content": "Private reasoning field"},
            {"id": 9, "role": "user", "content": "Old compaction wrapper", "display_content": "Recovered ask"},
            {"id": 10, "role": "assistant", "content": "Original private wrapper", "display_content": "**Recovered reply**"},
            {"id": 11, "role": "assistant", "content": "Must not recover explicitly empty display", "display_content": ""},
            {"id": 12, "role": "user", "content": "Actually change the file", "display_kind": "steer"},
            {"id": 13, "role": "assistant", "content": "Checking the file.", "tool_calls": [{"id": "call-2"}]},
            {"id": 14, "role": "assistant", "content": None, "codex_reasoning_items": [{"text": "Private sidecar"}]},
            {"id": 15, "role": "assistant", "content": {"type": "reasoning", "text": "Never stringify payloads"}},
        ]
        original = copy.deepcopy(self.upstream.histories["long-session"])
        page = await self.history()
        self.assertEqual([(r["id"], r["role"], r["text"]) for r in page["messages"]], [
            ("2", "user", literal), ("8", "assistant", answer), ("9", "user", "Recovered ask"),
            ("10", "assistant", "**Recovered reply**"), ("12", "user", "Actually change the file"),
            ("13", "assistant", "Checking the file.")])
        self.assertFalse(page["has_more"])
        self.assertEqual(self.upstream.histories["long-session"], original)

    async def test_official_display_commentary_survives_history_projection(self):
        self.upstream.histories["long-session"] = [
            {"id": 1, "role": "user", "content": "Check the file"},
            {"id": 2, "role": "assistant", "content": "The file is ready.",
             "display_commentary": ["Okay, I’m looking into that.", "I found the relevant section."],
             "display_reasoning": "Private reasoning", "codex_message_items": [{"text": "Raw provider data"}]},
            {"id": 3, "role": "assistant", "content": None, "display_commentary": ["One more public update."]},
        ]
        page = await self.history()
        self.assertEqual([row["text"] for row in page["messages"]], [
            "Check the file", "Okay, I’m looking into that.", "I found the relevant section.",
            "The file is ready.", "One more public update."])
        self.assertEqual(len({row["id"] for row in page["messages"]}), 5)
        self.assertNotIn("Private reasoning", json.dumps(page))
        self.assertNotIn("Raw provider data", json.dumps(page))

    async def test_nonstreamed_official_interim_is_visible_before_history_catches_up(self):
        self.upstream.histories["long-session"] = [{"id": 1, "role": "user", "content": "Check the file"}]
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        ws = await self.client.ws_connect(self.server.make_url("/v1/events"), headers=self.headers)
        await ws.receive_json()
        await self.upstream.event("message.start")
        await self.upstream.event("message.interim", {"text": "Okay, I’m looking into that.", "already_streamed": False})
        observed = []
        for _ in range(8):
            event = await ws.receive_json(timeout=3)
            if event["type"] == "delta":
                observed.append(event["payload"]["text"])
            if event["type"] == "snapshot":
                observed.extend(row["text"] for row in event["payload"]["page"]["messages"] if row["role"] == "assistant")
                break
        await ws.close()
        self.assertIn("Okay, I’m looking into that.", observed)

    async def test_commentary_pagination_keeps_all_parts_and_canonical_cursor(self):
        commentary = [f"Public progress {i}" for i in range(250)]
        self.upstream.histories["long-session"] = [
            {"id": 1, "role": "user", "content": "Begin"},
            {"id": 2, "role": "assistant", "content": "Final", "display_commentary": commentary},
            {"id": 3, "role": "assistant", "content": "Hidden", "display_kind": "hidden", "display_commentary": ["Do not expose"]}]
        pages, cursor = [], None
        for _ in range(4):
            page = await self.history(cursor)
            self.assertLessEqual(len(page["messages"]), 120)
            pages = page["messages"] + pages
            cursor = page["before"]
            if not cursor:
                break
        self.assertIsNone(cursor)
        self.assertEqual([row["text"] for row in pages], ["Begin", *commentary, "Final"])
        self.assertEqual(len({row["id"] for row in pages}), 252)

    async def test_streamed_and_nonstreamed_interims_survive_snapshots_without_cumulative_duplicates(self):
        self.upstream.histories["long-session"] = [
            {"id": 1, "role": "assistant", "content": "Checking now."},
            {"id": 2, "role": "user", "content": "Check again"}]
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        ws = await self.client.ws_connect(self.server.make_url("/v1/events"), headers=self.headers)
        self.addAsyncCleanup(ws.close)
        await ws.receive_json()
        self.upstream.inflight = {"assistant": "", "streaming": True}
        await self.upstream.event("message.start")
        await self.upstream.event("message.delta", {"text": "Checking now."})
        self.upstream.inflight["assistant"] = "Checking now."
        await self.upstream.event("message.interim", {"text": "Checking now.", "already_streamed": True})
        async def next_snapshot():
            for _ in range(12):
                event = await ws.receive_json(timeout=3)
                if event["type"] == "snapshot":
                    return event["payload"]["page"]["messages"]
            self.fail("Missing public snapshot")
        rows = await next_snapshot()
        self.assertEqual([r["text"] for r in rows], ["Checking now.", "Check again", "Checking now."])
        await self.upstream.event("message.interim", {"text": "One more detail.", "already_streamed": False})
        rows = await next_snapshot()
        self.assertEqual([r["text"] for r in rows], ["Checking now.", "Check again", "Checking now.", "One more detail."])
        await self.upstream.event("message.delta", {"text": "Final answer."})
        self.upstream.inflight["assistant"] = "Checking now.Final answer."
        await self.upstream.event("message.interim", {"text": "Final answer.", "already_streamed": True})
        rows = await next_snapshot()
        self.assertEqual([r["text"] for r in rows], ["Checking now.", "Check again", "Checking now.", "One more detail.", "Final answer."])
        self.upstream.histories["long-session"] += [{"id": 3, "role": "assistant", "content": "Done.", "display_commentary": ["Checking now.", "One more detail.", "Final answer."], "reasoning_content": "Private"}]
        self.upstream.inflight = None
        await self.upstream.event("message.complete", {"text": "Done.", "status": "complete", "persisted_turn": {"row_ids": [2, 3], "final_assistant_row_id": 3}})
        rows = await next_snapshot()
        self.assertEqual([r["text"] for r in rows], ["Checking now.", "Check again", "Checking now.", "One more detail.", "Final answer.", "Done."])
        self.assertTrue(all(not row["provisional"] for row in rows))
        self.assertEqual((await self.history())["messages"], rows)

    async def test_receipt_identity_is_projected_without_matching_repeated_text(self):
        import uuid
        self.upstream.histories["long-session"] = [{"id": 1, "role": "user", "content": "Same prompt"}]
        operation = str(uuid.uuid4())
        receipt = await self.request("POST", "/v1/sessions/long-session/commands", {"operation_id": operation, "kind": "send", "text": "Same prompt"})
        page = await self.history()
        submitted = next(row for row in page["messages"] if row["id"] == receipt["user_row_id"])
        self.assertEqual(submitted["operation_id"], operation)
        self.assertNotIn("operation_id", page["messages"][0])

    async def test_interim_follows_new_canonical_user_and_keeps_identical_final(self):
        self.upstream.histories["long-session"] = [{"id": 1, "role": "assistant", "content": "Previous answer"}]
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        ws = await self.client.ws_connect(self.server.make_url("/v1/events"), headers=self.headers)
        self.addAsyncCleanup(ws.close)
        await ws.receive_json()
        self.upstream.histories["long-session"].append({"id": 2, "role": "user", "content": "Check"})
        self.upstream.inflight = {"assistant": "", "streaming": True}
        await self.upstream.event("message.start")
        await self.upstream.event("message.interim", {"text": "Okay.", "already_streamed": False})
        async def next_snapshot():
            for _ in range(12):
                event = await ws.receive_json(timeout=3)
                if event["type"] == "snapshot":
                    return event["payload"]["page"]["messages"]
            self.fail("Missing public snapshot")
        self.assertEqual([row["text"] for row in await next_snapshot()], ["Previous answer", "Check", "Okay."])
        self.upstream.histories["long-session"].append({"id": 3, "role": "assistant", "content": "Okay."})
        self.upstream.inflight = None
        await self.upstream.event("message.complete", {"text": "Okay.", "status": "complete", "persisted_turn": {"row_ids": [2, 3], "final_assistant_row_id": 3}})
        self.assertEqual([row["text"] for row in await next_snapshot()], ["Previous answer", "Check", "Okay.", "Okay."])

    async def test_reconnect_replays_missing_public_interim_before_advancing_sequence(self):
        self.upstream.histories["long-session"] = [{"id": 1, "role": "user", "content": "Check"}]
        self.upstream.inflight = {"assistant": "", "streaming": True}
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        await self.upstream.event("message.start")
        for _ in range(100):
            if self.gateway.live["long-session"].seq == self.upstream.seq:
                break
            await asyncio.sleep(0.01)
        first_seq = self.upstream.seq
        missing = [
            {"type": "message.interim", "session_id": "runtime-long", "seq": first_seq + 1,
             "payload": {"text": "Public progress while disconnected.", "already_streamed": False}},
            {"type": "reasoning.delta", "session_id": "runtime-long", "seq": first_seq + 2,
             "payload": {"text": "Private reasoning while disconnected"}},
        ]
        original_rpc = self.upstream.rpc
        async def replay_rpc(method, params, ws):
            if method == "session.events.since":
                return {"events": missing, "latest_seq": first_seq + 2, "truncated": False, "epoch": self.upstream.epoch, "open_requests": []}
            return await original_rpc(method, params, ws)
        self.upstream.rpc = replay_rpc
        self.upstream.seq = first_seq + 2
        generation = self.gateway.generation
        for upstream_ws in list(self.upstream.ws):
            await upstream_ws.close()
        for _ in range(100):
            if self.gateway.generation != generation and self.gateway.connected and self.gateway.live["long-session"].seq == first_seq + 2:
                break
            await asyncio.sleep(0.02)
        rows = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]["messages"]
        self.assertEqual([row["text"] for row in rows], ["Check", "Public progress while disconnected."])
        self.assertNotIn("Private reasoning", json.dumps(rows))

    async def test_completed_commentary_and_older_pages_have_canonical_multiplicity(self):
        from companion.gateway import PublicTurn
        self.upstream.histories["long-session"] = [{"id": 1, "role": "user", "content": "Begin"}]
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        parts = [f"Progress {index // 2}" for index in range(70)]
        self.upstream.histories["long-session"].append({"id": 2, "role": "assistant", "content": "Final", "display_commentary": parts})
        live = self.gateway.live["long-session"]
        live.turn = PublicTurn({"1"}, persisted_ids={"1", "2"}, final_row_id="2", completed=True)
        for index, part in enumerate(parts):
            live.turn.seal(f"live-{index}", part)
        page = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]
        rows = page["messages"]
        while page["before"]:
            page = await self.history(page["before"])
            rows = page["messages"] + rows
        self.assertEqual([row["text"] for row in rows], ["Begin", *parts, "Final"])
        self.assertEqual(len({row["id"] for row in rows}), 72)
        self.assertFalse(any(row["provisional"] for row in rows))

    async def test_cold_attach_sealed_segment_does_not_duplicate_on_reconnect(self):
        self.upstream.histories["long-session"] = [{"id": 1, "role": "user", "content": "Begin"}]
        self.upstream.inflight = {"assistant": "Existing streamed segment", "streaming": True}
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        await self.upstream.event("message.interim", {"text": "Existing streamed segment", "already_streamed": True})
        for _ in range(100):
            if self.gateway.live["long-session"].turn.interims:
                break
            await asyncio.sleep(0.01)
        before = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]["messages"]
        generation = self.gateway.generation
        for upstream_ws in list(self.upstream.ws):
            await upstream_ws.close()
        for _ in range(100):
            if self.gateway.generation != generation and self.gateway.connected:
                break
            await asyncio.sleep(0.02)
        after = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]["messages"]
        self.assertEqual([row["text"] for row in before], ["Begin", "Existing streamed segment"])
        self.assertEqual(after, before)
        await self.upstream.event("message.delta", {"text": "New final suffix"})
        for _ in range(100):
            if self.gateway.live["long-session"].turn.current_text == "New final suffix":
                break
            await asyncio.sleep(0.01)
        rows = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]["messages"]
        self.assertEqual([row["text"] for row in rows], ["Begin", "Existing streamed segment", "New final suffix"])

    async def test_previous_completion_does_not_repeat_old_text_in_new_turn_snapshot(self):
        from companion.gateway import PublicTurn
        self.upstream.histories["long-session"] = [{"id": 1, "role": "user", "content": "First"}]
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        live = self.gateway.live["long-session"]
        live.turn = PublicTurn({"1"}, current_text="Old final", streamed_count=9)
        self.upstream.histories["long-session"] += [
            {"id": 2, "role": "assistant", "content": "Old final"}, {"id": 3, "role": "user", "content": "Next"}]
        self.upstream.inflight = {"assistant": "New answer", "streaming": True, "started_at": 2}
        await self.upstream.event("message.complete", {"text": "Old final", "status": "complete", "persisted_turn": {"row_ids": [1, 2], "final_assistant_row_id": 2}})
        for _ in range(100):
            if live.turn.awaiting_start:
                break
            await asyncio.sleep(0.01)
        rows = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]["messages"]
        self.assertEqual([row["text"] for row in rows], ["First", "Old final", "Next", "New answer"])
        await self.upstream.event("message.start")
        await self.upstream.event("message.delta", {"text": "New "})
        await self.upstream.event("message.delta", {"text": "answer continues"})
        for _ in range(100):
            if live.turn.current_text == "New answer continues":
                break
            await asyncio.sleep(0.01)
        rows = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]["messages"]
        self.assertEqual([row["text"] for row in rows], ["First", "Old final", "Next", "New answer continues"])

    async def test_official_inflight_corrections_keep_their_stream_offsets(self):
        self.upstream.histories["long-session"] = [{"id": 1, "role": "user", "content": "Begin"}]
        self.upstream.inflight = {"assistant": "BeforeAfter", "streaming": True, "started_at": 10,
                                  "corrections": ["Use the other file", "Use the other file"], "correction_offsets": [6, 6]}
        page = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]
        self.assertEqual([row["text"] for row in page["messages"]], ["Begin", "Before", "Use the other file", "Use the other file", "After"])
        self.assertEqual([row["role"] for row in page["messages"]], ["user", "assistant", "user", "user", "assistant"])
        self.assertEqual(len({row["id"] for row in page["messages"]}), 5)

    async def test_correction_stays_inside_streamed_segment_after_interim_seals(self):
        self.upstream.histories["long-session"] = [{"id": 1, "role": "user", "content": "Begin"}]
        self.upstream.inflight = {"assistant": "BeforeAfter", "streaming": True,
                                  "corrections": ["Change direction"], "correction_offsets": [6]}
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        live = self.gateway.live["long-session"]
        await self.gateway._apply_event({"type": "message.interim", "session_id": live.runtime,
            "connection_generation": self.gateway.generation, "payload": {"text": "BeforeAfter", "already_streamed": True}})
        page = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]
        self.assertEqual([row["text"] for row in page["messages"]], ["Begin", "Before", "Change direction", "After"])

    async def test_later_correction_follows_already_visible_nonstreamed_commentary(self):
        self.upstream.histories["long-session"] = [{"id": 1, "role": "user", "content": "Begin"}]
        self.upstream.inflight = {"assistant": "", "streaming": True}
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        live = self.gateway.live["long-session"]
        await self.gateway._apply_event({"type": "message.interim", "session_id": live.runtime,
            "connection_generation": self.gateway.generation,
            "payload": {"text": "Public update before correction", "already_streamed": False}})
        self.upstream.inflight.update(corrections=["Change direction"], correction_offsets=[0])
        page = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]
        self.assertEqual([row["text"] for row in page["messages"]], ["Begin", "Public update before correction", "Change direction"])

    async def test_all_three_segment_width_combinations_preserve_observed_order(self):
        from itertools import product
        from companion.gateway import PublicTurn
        for streamed in product((False, True), repeat=3):
            with self.subTest(streamed=streamed):
                turn = PublicTurn(set())
                for index, is_streamed in enumerate(streamed):
                    value = f"Public {index}"
                    if is_streamed:
                        turn.streamed_count += len(value)
                    turn.seal(f"segment-{index}", value)
                turn.project_corrections(turn.interims, "", "active", [], [], {})
                rows = turn.project_corrections(turn.interims, "", "active", ["Correction"], [turn.streamed_count], {})
                self.assertEqual([row["text"] for row in rows], ["Public 0", "Public 1", "Public 2", "Correction"])

    async def test_correction_order_uses_observed_timeline_at_shared_stream_boundaries(self):
        for first_streamed in (False, True):
            for second_streamed in (False, True):
                with self.subTest(first=first_streamed, second=second_streamed):
                    self.gateway.live.pop("long-session", None)
                    self.upstream.histories["long-session"] = [{"id": 1, "role": "user", "content": "Begin"}]
                    self.upstream.inflight = {"assistant": "", "streaming": True}
                    await self.request("GET", "/v1/sessions/long-session/snapshot")
                    live = self.gateway.live["long-session"]
                    async def emit(kind, payload):
                        await self.gateway._apply_event({"type": kind, "session_id": live.runtime,
                            "connection_generation": self.gateway.generation, "payload": payload})
                    async def interim(value, streamed):
                        if streamed:
                            self.upstream.inflight["assistant"] += value
                            await emit("message.delta", {"text": value})
                        await emit("message.interim", {"text": value, "already_streamed": streamed})
                    async def texts():
                        page = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]
                        self.assertEqual(len({row["id"] for row in page["messages"]}), len(page["messages"]))
                        return [row["text"] for row in page["messages"]]
                    await interim("Repeated public update", first_streamed)
                    await interim("Repeated public update", second_streamed)
                    self.assertEqual(await texts(), ["Begin", "Repeated public update", "Repeated public update"])
                    boundary = len(self.upstream.inflight["assistant"])
                    self.upstream.inflight.update(corrections=["Same direction"], correction_offsets=[boundary])
                    expected = ["Begin", "Repeated public update", "Repeated public update", "Same direction"]
                    self.assertEqual(await texts(), expected)
                    await interim("Later public update", False)
                    expected += ["Later public update"]
                    self.assertEqual(await texts(), expected)
                    self.upstream.inflight.update(corrections=["Same direction", "Same direction"], correction_offsets=[boundary, boundary])
                    expected += ["Same direction"]
                    self.assertEqual(await texts(), expected)
                    await interim("Final streamed update", True)
                    self.assertEqual(await texts(), expected + ["Final streamed update"])

    async def test_persisted_current_turn_corrections_replace_public_projection_once(self):
        original_rpc = self.upstream.rpc
        async def timed_rpc(method, params, ws):
            result = await original_rpc(method, params, ws)
            if method in {"session.activate", "session.resume"}:
                result["turn_started_at"] = 10
            return result
        self.upstream.rpc = timed_rpc
        for coalesced in (False, True):
            self.gateway.live.pop("long-session", None)
            self.upstream.histories["long-session"] = [
                {"id": 1, "role": "user", "content": "Prior", "timestamp": 1},
                {"id": 2, "role": "assistant", "content": "Before", "timestamp": 2},
                {"id": 3, "role": "user", "content": "Change", "display_kind": "steer", "timestamp": 3},
                {"id": 4, "role": "assistant", "content": "Old final", "timestamp": 4},
                {"id": 5, "role": "user", "content": "Begin", "timestamp": 10},
                {"id": 6, "role": "assistant", "content": "Before", "timestamp": 11},
                {"id": 7, "role": "user", "content": "Change\nChange" if coalesced else "Change", "display_kind": "steer", "timestamp": 12},
            ]
            corrections = ["Change", "Change"] if coalesced else ["Change"]
            self.upstream.inflight = {"user": "Begin", "assistant": "BeforeAfter", "streaming": True,
                                      "corrections": corrections, "correction_offsets": [6] * len(corrections)}
            page = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]
            self.assertEqual([row["text"] for row in page["messages"]],
                ["Prior", "Before", "Change", "Old final", "Begin", "Before", "Change\nChange" if coalesced else "Change", "After"])
            self.assertEqual([row["id"] for row in page["messages"][:7]], [str(i) for i in range(1, 8)])

    async def test_replay_crosses_turns_without_duplicating_live_prefix_or_losing_suffix(self):
        self.upstream.histories["long-session"] = [{"id": 1, "role": "user", "content": "First"}]
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        events = [
            ("message.start", {}),
            ("message.delta", {"text": "Looking"}),
            ("message.interim", {"text": "Looking", "already_streamed": True}),
            ("message.complete", {"text": "Old final", "status": "complete", "persisted_turn": {"row_ids": [1, 2], "final_assistant_row_id": 2}}),
            ("message.start", {}),
            ("message.delta", {"text": "Looking"}),
            ("message.interim", {"text": "Looking", "already_streamed": True}),
            ("message.delta", {"text": "Final suffix"}),
        ]
        frames = [{"type": kind, "session_id": "runtime-long", "payload": payload, "seq": index + 1} for index, (kind, payload) in enumerate(events)]
        self.upstream.histories["long-session"] += [
            {"id": 2, "role": "assistant", "content": "Old final", "display_commentary": ["Looking"]},
            {"id": 3, "role": "user", "content": "Second"}]
        self.upstream.inflight = {"assistant": "LookingFinal suffix", "streaming": True, "started_at": 2}
        original_rpc = self.upstream.rpc
        async def replay_rpc(method, params, ws):
            if method == "session.events.since":
                return {"events": frames, "latest_seq": len(frames), "truncated": False, "epoch": self.upstream.epoch, "open_requests": []}
            return await original_rpc(method, params, ws)
        self.upstream.rpc = replay_rpc
        self.upstream.seq = len(frames)
        generation = self.gateway.generation
        for upstream_ws in list(self.upstream.ws):
            await upstream_ws.close()
        for _ in range(100):
            if self.gateway.generation != generation and self.gateway.connected and self.gateway.live["long-session"].seq == len(frames):
                break
            await asyncio.sleep(0.02)
        rows = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]["messages"]
        self.assertEqual([row["text"] for row in rows], ["First", "Looking", "Old final", "Second", "Looking", "Final suffix"])
        await self.upstream.event("message.delta", {"text": " continues"})
        for _ in range(100):
            if self.gateway.live["long-session"].turn.current_text == "Final suffix continues":
                break
            await asyncio.sleep(0.01)
        rows = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]["messages"]
        self.assertEqual([row["text"] for row in rows], ["First", "Looking", "Old final", "Second", "Looking", "Final suffix continues"])

    async def test_hidden_only_pages_preserve_canonical_progress_and_concurrent_append(self):
        rows = [{"id": n, "role": "assistant", "content": f"Visible {n}"} for n in range(1, 131)]
        rows += [{"id": n, "role": "tool", "content": "Hidden result"} for n in range(131, 491)]
        rows += [{"id": n, "role": "assistant", "content": f"Visible {n}"} for n in range(491, 511)]
        self.upstream.histories["long-session"] = rows
        first = await self.history()
        self.assertEqual([r["id"] for r in first["messages"]], [str(n) for n in [*range(31, 131), *range(491, 511)]])
        self.assertTrue(first["has_more"])
        self.upstream.histories["long-session"] += [{"id": 511, "role": "tool", "content": "New tool"}, {"id": 512, "role": "assistant", "content": "New answer"}]
        second = await self.history(first["before"])
        self.assertEqual([r["id"] for r in second["messages"]], [str(n) for n in range(1, 31)])
        self.assertFalse(second["has_more"])

    async def test_hidden_only_tail_has_bounded_progress_cursor(self):
        self.upstream.histories["long-session"] = [{"id": 1, "role": "assistant", "content": "Earlier actual answer"}]
        self.upstream.histories["long-session"] += [{"id": n, "role": "tool", "content": "Tool"} for n in range(2, 6002)]
        first = await self.history()
        self.assertEqual(first["messages"], [])
        self.assertTrue(first["has_more"])
        self.assertIsNotNone(first["before"])
        reads = [call for call in self.upstream.calls if call[0].endswith("/messages")]
        self.assertLessEqual(len(reads), 32)
        second = await self.history(first["before"])
        self.assertEqual([(r["id"], r["text"]) for r in second["messages"]], [("1", "Earlier actual answer")])
        self.assertFalse(second["has_more"])

    async def test_reasoning_is_not_streamed_and_final_is_identical_after_reconnect(self):
        self.upstream.histories["long-session"] = [{"id": 1, "role": "user", "content": "Give **answer**"}]
        await self.request("GET", "/v1/sessions/long-session/snapshot")
        ws = await self.client.ws_connect(self.server.make_url("/v1/events"), headers=self.headers)
        await ws.receive_json()
        await self.upstream.event("message.start")
        await self.upstream.event("reasoning.delta", {"text": "Private scratchpad"})
        await self.upstream.event("thinking.delta", {"text": "Private thinking"})
        await self.upstream.event("reasoning.available", {"text": "Private block"})
        await self.upstream.event("tool.complete", {"name": "read_file", "result": "Private tool"})
        answer = "**Actual answer**\n\n```json\n{\"ready\": true}\n```"
        for part in [answer[:12], answer[12:]]:
            await self.upstream.event("message.delta", {"text": part})
        chunks = []
        for _ in range(8):
            event = await ws.receive_json(timeout=3)
            self.assertNotEqual(event["type"], "snapshot")
            if event["type"] == "delta":
                chunks.append(event["payload"]["text"])
                if "".join(chunks) == answer:
                    break
        self.assertEqual("".join(chunks), answer)
        self.upstream.histories["long-session"] += [{"id": 2, "role": "tool", "content": "Private tool"}, {"id": 3, "role": "assistant", "content": answer, "reasoning_content": "Private scratchpad"}]
        await self.upstream.event("message.complete", {"text": answer, "status": "complete", "persisted_turn": {"final_assistant_row_id": 3}})
        final = None
        for _ in range(12):
            event = await ws.receive_json(timeout=3)
            if event["type"] == "delta":
                chunks.append(event["payload"]["text"])
            if event["type"] == "snapshot":
                final = event["payload"]["page"]["messages"]
                break
        self.assertEqual("".join(chunks), answer)
        self.assertEqual([(r["id"], r["text"]) for r in final], [("1", "Give **answer**"), ("3", answer)])
        generation = self.gateway.generation
        for upstream_ws in list(self.upstream.ws):
            await upstream_ws.close()
        for _ in range(100):
            if self.gateway.generation != generation and self.gateway.connected:
                break
            await asyncio.sleep(0.02)
        self.assertNotEqual(self.gateway.generation, generation)
        self.assertTrue(self.gateway.connected)
        replay = await self.request("GET", "/v1/sessions/long-session/snapshot")
        self.assertEqual(replay["page"]["messages"], final)
        await ws.close()

    async def test_inflight_slot_keeps_canonical_cursor_across_tool_gaps(self):
        self.upstream.histories["long-session"] = [row for n in range(1, 126) for row in [
            {"id": n * 2 - 1, "role": "assistant", "content": f"Answer {n}"},
            {"id": n * 2, "role": "tool", "content": "Tool result"}]]
        self.upstream.inflight = {"assistant": "Partial **answer**", "reasoning": "Private", "streaming": True}
        page = (await self.request("GET", "/v1/sessions/long-session/snapshot"))["page"]
        self.assertEqual(len(page["messages"]), 120)
        self.assertTrue(page["messages"][-1]["provisional"])
        self.assertEqual(page["messages"][0]["id"], "13")
        older = await self.history(page["before"])
        self.assertEqual([r["id"] for r in older["messages"]], ["1", "3", "5", "7", "9", "11"])
        self.assertFalse(older["has_more"])

    async def test_response_size_limit_preserves_visible_rows_across_hidden_gaps(self):
        large = "😀" * 140000
        self.upstream.histories["long-session"] = [row for n in range(1, 12) for row in [
            {"id": n * 2 - 1, "role": "assistant", "content": large},
            {"id": n * 2, "role": "tool", "content": "Tool result"}]]
        seen, cursor = [], None
        for _ in range(12):
            page = await self.history(cursor)
            self.assertLess(len(json.dumps(page, ensure_ascii=False).encode()), 4 * 1024 * 1024)
            seen = [row["id"] for row in page["messages"]] + seen
            cursor = page["before"]
            if cursor is None:
                break
        self.assertIsNone(cursor)
        self.assertEqual(seen, [str(n) for n in range(1, 22, 2)])
