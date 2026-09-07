"""Pure tests for the deterministic model fixture response contract."""

from __future__ import annotations

import unittest

import direct_hermes_model_fixture as fixture


class ModelFixtureTests(unittest.TestCase):
    def test_exact_clarify_marker_emits_call_only_when_tool_is_advertised(self) -> None:
        body = {
            'stream': True,
            'tools': [{'type': 'function', 'function': {'name': 'clarify'}}],
        }
        call = fixture.clarify_tool_call(body, fixture.CLARIFY_MARKER)
        self.assertEqual(call['function']['name'], 'clarify')
        self.assertEqual(
            call['function']['arguments'],
            '{"question":"Choose a bounded fixture answer","choices":["answer","cancel"]}',
        )
        self.assertIsNone(fixture.clarify_tool_call(body, 'prefix ' + fixture.CLARIFY_MARKER))
        self.assertIsNone(fixture.clarify_tool_call({'stream': True}, fixture.CLARIFY_MARKER))
        self.assertIsNone(fixture.clarify_tool_call({
            **body,
            'messages': [{'role': 'tool', 'content': 'answer'}],
        }, fixture.CLARIFY_MARKER))
        self.assertIsNotNone(fixture.clarify_tool_call({
            **body,
            'messages': [
                {'role': 'user', 'content': fixture.CLARIFY_MARKER},
                {'role': 'tool', 'content': 'old answer'},
                {'role': 'user', 'content': fixture.CLARIFY_MARKER},
            ],
        }, fixture.CLARIFY_MARKER))

    def test_streaming_exact_bulky_marker_is_varied_and_exactly_4096_bytes(self) -> None:
        first = fixture.response_text(
            {"stream": True}, "SEMREH_COMPRESSION_BULKY_MAIN_00"
        )
        second = fixture.response_text(
            {"stream": True}, "SEMREH_COMPRESSION_BULKY_MAIN_01"
        )
        self.assertEqual(len(first.encode("utf-8")), 4096)
        self.assertEqual(len(second.encode("utf-8")), 4096)
        self.assertNotEqual(first, second)
        self.assertEqual(
            fixture.compression_bulky_assistant(0), first
        )

    def test_nonstreaming_exact_marker_keeps_ack(self) -> None:
        self.assertEqual(
            fixture.response_text(
                {"stream": False}, "SEMREH_COMPRESSION_BULKY_MAIN_00"
            ),
            "SEMREH_SLICE1_ACK",
        )

    def test_streaming_marker_substring_keeps_ack(self) -> None:
        self.assertEqual(
            fixture.response_text(
                {"stream": True},
                "summary mentions SEMREH_COMPRESSION_BULKY_MAIN_00 here",
            ),
            "SEMREH_SLICE1_ACK",
        )

    def test_ordinary_prompt_keeps_ack(self) -> None:
        self.assertEqual(
            fixture.response_text({"stream": True}, "SEMREH_SLICE1_TEST"),
            "SEMREH_SLICE1_ACK",
        )

    def test_reasoning_response_is_unchanged(self) -> None:
        old = fixture.REASONING_PROBE
        fixture.REASONING_PROBE = True
        try:
            self.assertEqual(
                fixture.response_text(
                    {"stream": False, "reasoning": {"effort": "medium"}},
                    "SEMREH_REASONING_PROBE ordinary",
                ),
                "SEMREH_REASONING_EFFORT:medium",
            )
        finally:
            fixture.REASONING_PROBE = old


if __name__ == "__main__":
    unittest.main()
