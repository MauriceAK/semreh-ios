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
