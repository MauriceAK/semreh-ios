"""Pure tests for the deterministic model fixture response contract."""

from __future__ import annotations

import unittest
import json

import direct_hermes_model_fixture as fixture


class ModelFixtureTests(unittest.TestCase):
    def test_multimodal_user_content_does_not_emit_clarification(self) -> None:
        body = {'tools': [{'type': 'function', 'function': {'name': 'clarify'}}]}
        self.assertIsNone(fixture.clarify_tool_call(body, [{'type': 'text', 'text': 'ordinary'}]))

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

    def test_exact_multi_select_marker_emits_advertised_shape_only(self) -> None:
        body = {
            'tools': [{'type': 'function', 'function': {'name': 'clarify'}}],
        }
        call = fixture.clarify_tool_call(body, fixture.CLARIFY_MULTI_SELECT_MARKER)
        self.assertEqual(call['id'], fixture.CLARIFY_MULTI_SELECT_TOOL_CALL_ID)
        self.assertEqual(call['function']['name'], 'clarify')
        self.assertEqual(
            call['function']['arguments'],
            '{"question":"Choose bounded fixture surfaces",'
            '"choices":["iOS","TUI","desktop"],"multi_select":true}',
        )
        self.assertIsNone(fixture.clarify_tool_call(
            body, 'prefix ' + fixture.CLARIFY_MULTI_SELECT_MARKER
        ))
        self.assertIsNone(fixture.clarify_tool_call(
            {'tools': [{'type': 'function', 'function': {'name': 'other'}}]},
            fixture.CLARIFY_MULTI_SELECT_MARKER,
        ))

    def test_exact_batch_marker_emits_questions_and_suppresses_after_tool_result(self) -> None:
        body = {
            'tools': [{'type': 'function', 'function': {'name': 'clarify'}}],
        }
        call = fixture.clarify_tool_call(body, fixture.CLARIFY_BATCH_MARKER)
        self.assertEqual(call['id'], fixture.CLARIFY_BATCH_TOOL_CALL_ID)
        self.assertEqual(
            call['function']['arguments'],
            '{"questions":[{"id":"plan","question":"Choose a bounded plan",'
            '"choices":["answer","cancel"]},{"id":"surfaces",'
            '"question":"Choose bounded surfaces",'
            '"choices":["iOS","TUI","desktop"],"multi_select":true}]}',
        )
        self.assertIsNone(fixture.clarify_tool_call(
            body,
            fixture.CLARIFY_BATCH_MARKER + ' suffix',
        ))
        self.assertIsNone(fixture.clarify_tool_call({
            **body,
            'messages': [
                {'role': 'user', 'content': fixture.CLARIFY_BATCH_MARKER},
                {'role': 'tool', 'content': '{"answers": {}}'},
            ],
        }, fixture.CLARIFY_BATCH_MARKER))

    def test_exact_blocking_markers_emit_only_advertised_fixture_tools(self) -> None:
        body = {
            'tools': [
                {'type': 'function', 'function': {'name': fixture.APPROVAL_TOOL_NAME}},
                {'type': 'function', 'function': {'name': fixture.SECRET_TOOL_NAME}},
            ],
        }
        approval = fixture.blocking_tool_call(body, fixture.APPROVAL_MARKER)
        self.assertEqual(approval['id'], fixture.APPROVAL_TOOL_CALL_ID)
        self.assertEqual(approval['function']['name'], fixture.APPROVAL_TOOL_NAME)
        self.assertEqual(
            approval['function']['arguments'],
            '{}',
        )
        secret = fixture.blocking_tool_call(body, fixture.SECRET_MARKER)
        self.assertEqual(secret['id'], fixture.SECRET_TOOL_CALL_ID)
        self.assertEqual(secret['function']['name'], fixture.SECRET_TOOL_NAME)
        self.assertEqual(secret['function']['arguments'], '{}')
        self.assertIsNone(fixture.blocking_tool_call(
            body, 'prefix ' + fixture.APPROVAL_MARKER
        ))
        self.assertIsNone(fixture.blocking_tool_call(
            {'tools': [{'type': 'function', 'function': {'name': 'other'}}]},
            fixture.SECRET_MARKER,
        ))
        self.assertIsNone(fixture.blocking_tool_call({**body, 'messages': [
            {'role': 'user', 'content': fixture.APPROVAL_MARKER},
            {'role': 'tool', 'content': 'denied'},
        ]}, fixture.APPROVAL_MARKER))

    def test_blocking_followups_are_exact_and_ordinary_text_is_unchanged(self) -> None:
        self.assertEqual(
            fixture.response_text(
                {'stream': False}, 'SEMREH_SLICE3_BLOCKING_AFTER_APPROVAL_DENY'
            ),
            'SEMREH_SLICE3_BLOCKING_ACK_APPROVAL_DENY',
        )
        self.assertEqual(
            fixture.response_text(
                {'stream': False}, 'SEMREH_SLICE3_BLOCKING_AFTER_SECRET_CANCEL'
            ),
            'SEMREH_SLICE3_BLOCKING_ACK_SECRET_CANCEL',
        )
        self.assertEqual(
            fixture.response_text(
                {'stream': False},
                'prefix SEMREH_SLICE3_BLOCKING_AFTER_SECRET_CANCEL',
            ),
            'SEMREH_SLICE1_ACK',
        )

    def test_provider_diagnostics_redact_unknown_tools_and_prompt_content(self) -> None:
        diagnostics = fixture.safe_request_diagnostics({
            'tools': [
                {'type': 'function', 'function': {'name': fixture.APPROVAL_TOOL_NAME}},
                {'type': 'function', 'function': {'name': 'private_tool'}},
            ],
        }, fixture.APPROVAL_MARKER, {
            'function': {'name': fixture.APPROVAL_TOOL_NAME},
        })
        self.assertTrue(diagnostics['exact_approval_marker'])
        self.assertTrue(diagnostics['contains_approval_marker'])
        self.assertEqual(diagnostics['advertised_tools'], [
            fixture.APPROVAL_TOOL_NAME, '<unexpected>'
        ])
        self.assertTrue(diagnostics['selected_tool_call'])
        self.assertEqual(diagnostics['selected_tool_name'], fixture.APPROVAL_TOOL_NAME)
        self.assertNotIn(fixture.APPROVAL_MARKER, json.dumps(diagnostics))

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

    def test_exact_clarification_followups_have_unique_acknowledgements(self) -> None:
        expected = {
            "SEMREH_SLICE3_CLARIFY_AFTER_SINGLE_ANSWER":
                "SEMREH_SLICE3_CLARIFY_ACK_SINGLE_ANSWER",
            "SEMREH_SLICE3_CLARIFY_AFTER_SINGLE_CANCEL":
                "SEMREH_SLICE3_CLARIFY_ACK_SINGLE_CANCEL",
            "SEMREH_SLICE3_CLARIFY_AFTER_SEMREH_BLOCKING_CLARIFY_BATCH":
                "SEMREH_SLICE3_CLARIFY_ACK_BATCH_CANCEL",
            "SEMREH_SLICE3_CLARIFY_AFTER_SEMREH_BLOCKING_CLARIFY_MULTI_SELECT":
                "SEMREH_SLICE3_CLARIFY_ACK_MULTI_SELECT_CANCEL",
        }
        for marker, acknowledgement in expected.items():
            self.assertEqual(fixture.response_text({"stream": False}, marker), acknowledgement)
        self.assertEqual(
            fixture.response_text({"stream": False}, "prefix SEMREH_SLICE3_CLARIFY_AFTER_SINGLE_ANSWER"),
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
