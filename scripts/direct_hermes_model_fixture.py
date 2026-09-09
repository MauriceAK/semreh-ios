#!/usr/bin/env python3
"""Deterministic local OpenAI-compatible provider for real Hermes gateway tests.

Not an external model smoke: no real credentials, no tool calls. Delays let tests
interrupt a genuinely pending provider request. HTTP request bodies are not logged.
"""
import argparse
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import re
import sys
import time
from typing import Optional

REASONING_PROBE = False
GOAL_E2E_PREFIX = 'SEMREH_GOAL_E2E_TWO_TURN_'
GOAL_E2E_STEP_1 = 'SEMREH_GOAL_E2E_STEP_1'
GOAL_E2E_STEP_2 = 'SEMREH_GOAL_E2E_STEP_2'
GOAL_JUDGE_SYSTEM_SHA256 = '61f08b77510ae3492018c03ea51029102d958a27910206c10023b0c058c29d5c'
GOAL_CONTINUATION_PREFIX = '[Continuing toward your standing goal]\nGoal: '
COMPRESSION_BULKY_MARKER_PREFIX = 'SEMREH_COMPRESSION_BULKY_MAIN_'
COMPRESSION_BULKY_MAIN_RE = re.compile(
    rf'^{re.escape(COMPRESSION_BULKY_MARKER_PREFIX)}(\d{{2}})$'
)
COMPRESSION_BULKY_MAIN_BYTES = 4_096
CLARIFY_MARKER = 'SEMREH_BLOCKING_CLARIFY'
CLARIFY_TOOL_CALL_ID = 'call_semreh_clarify'
CLARIFY_ARGUMENTS = {
    'question': 'Choose a bounded fixture answer',
    'choices': ['answer', 'cancel'],
}
CLARIFY_MULTI_SELECT_MARKER = 'SEMREH_BLOCKING_CLARIFY_MULTI_SELECT'
CLARIFY_MULTI_SELECT_TOOL_CALL_ID = 'call_semreh_clarify_multi'
CLARIFY_MULTI_SELECT_ARGUMENTS = {
    'question': 'Choose bounded fixture surfaces',
    'choices': ['iOS', 'TUI', 'desktop'],
    'multi_select': True,
}
CLARIFY_BATCH_MARKER = 'SEMREH_BLOCKING_CLARIFY_BATCH'
CLARIFY_BATCH_TOOL_CALL_ID = 'call_semreh_clarify_batch'
CLARIFY_BATCH_ARGUMENTS = {
    'questions': [
        {
            'id': 'plan',
            'question': 'Choose a bounded plan',
            'choices': ['answer', 'cancel'],
        },
        {
            'id': 'surfaces',
            'question': 'Choose bounded surfaces',
            'choices': ['iOS', 'TUI', 'desktop'],
            'multi_select': True,
        },
    ],
}
CLARIFY_FOLLOWUP_RESPONSES = {
    'SEMREH_SLICE3_CLARIFY_AFTER_SINGLE_ANSWER':
        'SEMREH_SLICE3_CLARIFY_ACK_SINGLE_ANSWER',
    'SEMREH_SLICE3_CLARIFY_AFTER_SINGLE_CANCEL':
        'SEMREH_SLICE3_CLARIFY_ACK_SINGLE_CANCEL',
    'SEMREH_SLICE3_CLARIFY_AFTER_SEMREH_BLOCKING_CLARIFY_BATCH':
        'SEMREH_SLICE3_CLARIFY_ACK_BATCH_CANCEL',
    'SEMREH_SLICE3_CLARIFY_AFTER_SEMREH_BLOCKING_CLARIFY_MULTI_SELECT':
        'SEMREH_SLICE3_CLARIFY_ACK_MULTI_SELECT_CANCEL',
}

# These two markers are deliberately exact and opt-in.  The approval/secret
# tool schemas are advertised only by the explicit disposable fixture mode;
# ordinary model requests must never manufacture a blocking callback.
APPROVAL_MARKER = 'SEMREH_BLOCKING_APPROVAL'
APPROVAL_TOOL_CALL_ID = 'call_semreh_approval'
APPROVAL_TOOL_NAME = 'semreh_fixture_approval'
APPROVAL_ARGUMENTS = {}
SECRET_MARKER = 'SEMREH_BLOCKING_SECRET'
SECRET_TOOL_CALL_ID = 'call_semreh_secret'
SECRET_TOOL_NAME = 'semreh_fixture_secret'
SECRET_ARGUMENTS = {}
BLOCKING_FOLLOWUP_RESPONSES = {
    'SEMREH_SLICE3_BLOCKING_AFTER_APPROVAL_DENY':
        'SEMREH_SLICE3_BLOCKING_ACK_APPROVAL_DENY',
    'SEMREH_SLICE3_BLOCKING_AFTER_SECRET_CANCEL':
        'SEMREH_SLICE3_BLOCKING_ACK_SECRET_CANCEL',
}

# Keep the marker dispatch explicit so adding a synthetic probe case cannot
# make ordinary prompts accidentally emit a clarify call.
CLARIFY_FIXTURES = {
    CLARIFY_MARKER: (CLARIFY_TOOL_CALL_ID, CLARIFY_ARGUMENTS),
    CLARIFY_MULTI_SELECT_MARKER: (
        CLARIFY_MULTI_SELECT_TOOL_CALL_ID,
        CLARIFY_MULTI_SELECT_ARGUMENTS,
    ),
    CLARIFY_BATCH_MARKER: (CLARIFY_BATCH_TOOL_CALL_ID, CLARIFY_BATCH_ARGUMENTS),
}

BLOCKING_FIXTURES = {
    APPROVAL_MARKER: (APPROVAL_TOOL_CALL_ID, APPROVAL_TOOL_NAME, APPROVAL_ARGUMENTS),
    SECRET_MARKER: (SECRET_TOOL_CALL_ID, SECRET_TOOL_NAME, SECRET_ARGUMENTS),
}
_DIAGNOSTIC_TOOL_NAMES = {
    'clarify', APPROVAL_TOOL_NAME, SECRET_TOOL_NAME,
}


def compression_bulky_assistant(index: int) -> str:
    """Return varied deterministic assistant content of exactly 4096 ASCII bytes."""
    if not isinstance(index, int) or isinstance(index, bool) or not 0 <= index <= 99:
        raise ValueError('bulky assistant index must be an integer from 0 through 99')
    prefix = f'SEMREH_COMPRESSION_BULKY_REPLY_{index:02d}:'
    remaining = COMPRESSION_BULKY_MAIN_BYTES - len(prefix)
    if remaining < 0:
        raise AssertionError('bulky fixture prefix exceeded its byte budget')
    body = ''.join(chr(ord('A') + ((index + offset) % 26)) for offset in range(remaining))
    content = prefix + body
    if len(content) != COMPRESSION_BULKY_MAIN_BYTES:
        raise AssertionError('bulky fixture content did not meet its byte budget')
    return content


def bulky_main_content(marker: str) -> str:
    """Return bulky content for one exact short marker."""
    match = COMPRESSION_BULKY_MAIN_RE.fullmatch(marker)
    if match is None:
        raise ValueError('marker is not an exact bulky-main fixture marker')
    return compression_bulky_assistant(int(match.group(1)))


def clarify_marker_active(body: dict, last_user: object) -> bool:
    """Only expose the clarify call for the exact marker and advertised tool."""
    if not isinstance(last_user, str) or last_user not in CLARIFY_FIXTURES or not isinstance(body.get('tools'), list):
        return False
    # After the gateway answers the call, the tool result is in the next model
    # request.  End the deterministic turn with an ACK instead of reopening the
    # same prompt indefinitely.
    messages = body.get('messages', [])
    latest_user = max(
        (index for index, message in enumerate(messages)
         if isinstance(message, dict) and message.get('role') == 'user'),
        default=-1,
    )
    if any(isinstance(message, dict) and message.get('role') == 'tool'
           for message in messages[latest_user + 1:]):
        return False
    return any(
        isinstance(tool, dict)
        and isinstance(tool.get('function'), dict)
        and tool['function'].get('name') == 'clarify'
        for tool in body['tools']
    )


def clarify_tool_call(body: dict, last_user: object) -> Optional[dict]:
    """Return one deterministic OpenAI tool call for the clarify-only probe."""
    if not clarify_marker_active(body, last_user):
        return None
    call_id, arguments = CLARIFY_FIXTURES[last_user]
    return {
        'id': call_id,
        'type': 'function',
        'function': {
            'name': 'clarify',
            'arguments': json.dumps(arguments, separators=(',', ':')),
        },
    }


def blocking_tool_call(body: dict, last_user: object) -> Optional[dict]:
    """Return one exact synthetic approval/secret tool call when advertised."""
    if not isinstance(last_user, str) or last_user not in BLOCKING_FIXTURES:
        return None
    tools = body.get('tools')
    if not isinstance(tools, list):
        return None
    latest_user = max(
        (index for index, message in enumerate(body.get('messages', []))
         if isinstance(message, dict) and message.get('role') == 'user'),
        default=-1,
    )
    if any(isinstance(message, dict) and message.get('role') == 'tool'
           for message in body.get('messages', [])[latest_user + 1:]):
        return None
    call_id, name, arguments = BLOCKING_FIXTURES[last_user]
    if not any(
        isinstance(tool, dict)
        and isinstance(tool.get('function'), dict)
        and tool['function'].get('name') == name
        for tool in tools
    ):
        return None
    return {
        'id': call_id,
        'type': 'function',
        'function': {
            'name': name,
            'arguments': json.dumps(arguments, separators=(',', ':')),
        },
    }


def _contains_marker(value: object, marker: str) -> bool:
    if isinstance(value, str):
        return marker in value
    if isinstance(value, list):
        return any(_contains_marker(item, marker) for item in value)
    if isinstance(value, dict):
        return any(_contains_marker(item, marker) for item in value.values())
    return False


def safe_request_diagnostics(body: dict, last_user: object,
                             selected_tool_call: Optional[dict]) -> dict:
    """Return bounded provider diagnostics without retaining prompt content."""
    advertised = []
    tools = body.get('tools')
    if isinstance(tools, list):
        for tool in tools:
            function = tool.get('function') if isinstance(tool, dict) else None
            name = function.get('name') if isinstance(function, dict) else None
            advertised.append(name if name in _DIAGNOSTIC_TOOL_NAMES else '<unexpected>')
    selected_name = None
    if isinstance(selected_tool_call, dict):
        function = selected_tool_call.get('function') or {}
        raw_name = function.get('name') if isinstance(function, dict) else None
        selected_name = raw_name if raw_name in _DIAGNOSTIC_TOOL_NAMES else '<unexpected>'
    return {
        'last_user_type': type(last_user).__name__,
        'exact_approval_marker': last_user == APPROVAL_MARKER,
        'exact_secret_marker': last_user == SECRET_MARKER,
        'contains_approval_marker': _contains_marker(last_user, APPROVAL_MARKER),
        'contains_secret_marker': _contains_marker(last_user, SECRET_MARKER),
        'advertised_tool_count': len(advertised),
        'advertised_tools': advertised,
        'selected_tool_call': selected_tool_call is not None,
        'selected_tool_name': selected_name,
        'fixture_kind': goal_e2e_kind(body, last_user),
    }


def goal_e2e_kind(body: dict, last_user: object) -> Optional[str]:
    if not isinstance(last_user, str) or GOAL_E2E_PREFIX not in last_user:
        return None
    messages = body.get('messages')
    system = next((message.get('content') for message in (messages or [])
                   if isinstance(message, dict) and message.get('role') == 'system'), None)
    if (isinstance(system, str)
            and hashlib.sha256(system.encode()).hexdigest() == GOAL_JUDGE_SYSTEM_SHA256):
        # The second judge prompt contains both prior step strings. Priority is
        # therefore deliberately newest-step-first.
        if GOAL_E2E_STEP_2 in last_user:
            return 'goal_judge_2'
        if GOAL_E2E_STEP_1 in last_user:
            return 'goal_judge_1'
        return None
    if body.get('stream') is True:
        if last_user.startswith(GOAL_CONTINUATION_PREFIX):
            return 'goal_main_2'
        if last_user.startswith(GOAL_E2E_PREFIX):
            return 'goal_main_1'
    return None


def response_text(body: dict, last_user: object) -> str:
    """Select the fixture response while keeping non-bulky behavior unchanged."""
    goal_kind = goal_e2e_kind(body, last_user)
    if goal_kind == 'goal_judge_2':
        return '{"verdict":"done","reason":"fixture goal complete"}'
    if goal_kind == 'goal_judge_1':
        return '{"verdict":"continue","reason":"fixture step one complete"}'
    if goal_kind == 'goal_main_2':
        return GOAL_E2E_STEP_2
    if goal_kind == 'goal_main_1':
        return GOAL_E2E_STEP_1
    if body.get('stream') is True and isinstance(last_user, str):
        if COMPRESSION_BULKY_MAIN_RE.fullmatch(last_user):
            return bulky_main_content(last_user)

    text = 'SEMREH_SLICE1_ACK'
    if isinstance(last_user, str):
        text = {**CLARIFY_FOLLOWUP_RESPONSES, **BLOCKING_FOLLOWUP_RESPONSES}.get(
            last_user, text
        )
        messages = body.get('messages', [])
        latest_user = max(
            (index for index, message in enumerate(messages)
             if isinstance(message, dict) and message.get('role') == 'user'),
            default=-1,
        )
        if any(isinstance(message, dict) and message.get('role') == 'tool'
               for message in messages[latest_user + 1:]):
            text = {
                APPROVAL_MARKER: 'SEMREH_SLICE3_BLOCKING_ACK_APPROVAL_DENY',
                SECRET_MARKER: 'SEMREH_SLICE3_BLOCKING_ACK_SECRET_CANCEL',
            }.get(last_user, text)
    if REASONING_PROBE and 'SEMREH_REASONING_PROBE' in str(last_user):
        reasoning = body.get('reasoning') or {}
        effort = body.get('reasoning_effort') or reasoning.get('effort')
        if reasoning.get('enabled') is False:
            effort = 'none'
        text = 'SEMREH_REASONING_EFFORT:' + str(effort or 'missing')
    return text


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path != '/v1/models':
            self.send_error(404)
            return
        models = ['semreh-fixture', 'gpt-5'] if REASONING_PROBE else ['semreh-fixture']
        self.reply({'object': 'list', 'data': [
            {'id': model, 'object': 'model', 'owned_by': 'local-test'} for model in models
        ]})

    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != '/v1/chat/completions':
            self.send_error(404)
            return
        length = int(self.headers.get('Content-Length', '0'))
        if length > 2_000_000:
            self.send_error(413)
            return
        body = json.loads(self.rfile.read(length))
        messages = body.get('messages', [])
        last_user = next((m.get('content', '') for m in reversed(messages) if m.get('role') == 'user'), '')
        if 'SEMREH_INTERRUPT_FIXTURE' in str(last_user):
            time.sleep(15)
        # Bulky compression corpus replies are deliberately stream-only and
        # exact-marker-only. Auxiliary non-streaming summaries containing these
        # markers continue to receive the ordinary deterministic ACK.
        text = response_text(body, last_user)
        tool_call = clarify_tool_call(body, last_user)
        if tool_call is None:
            tool_call = blocking_tool_call(body, last_user)
        print(
            'SEMREH_FIXTURE_DIAGNOSTIC ' + json.dumps(
                safe_request_diagnostics(body, last_user, tool_call),
                separators=(',', ':'),
            ),
            file=sys.stderr,
            flush=True,
        )
        base = {'id': 'chatcmpl-semreh-fixture', 'created': int(time.time()), 'model': 'semreh-fixture'}
        try:
            if body.get('stream'):
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                if tool_call is not None:
                    chunks = [
                        ({'role': 'assistant', 'content': ''}, None),
                        ({'tool_calls': [{'index': 0, **tool_call}]}, None),
                        ({}, 'tool_calls'),
                    ]
                else:
                    chunks = [({'role': 'assistant', 'content': text}, None), ({}, 'stop')]
                for delta, reason in chunks:
                    chunk = {**base, 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': delta, 'finish_reason': reason}]}
                    self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
                    self.wfile.flush()
                self.wfile.write(b'data: [DONE]\n\n')
            else:
                message = {'role': 'assistant', 'content': ''}
                finish_reason = 'stop'
                if tool_call is not None:
                    message['tool_calls'] = [tool_call]
                    finish_reason = 'tool_calls'
                else:
                    message['content'] = text
                self.reply({**base, 'object': 'chat.completion', 'choices': [{'index': 0, 'message': message, 'finish_reason': finish_reason}], 'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}})
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when the client interrupts a pending fixture turn.


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reasoning-probe', action='store_true')
    REASONING_PROBE = parser.parse_args().reasoning_probe
    print('Deterministic model fixture listening on 127.0.0.1:18792', flush=True)
    ThreadingHTTPServer(('127.0.0.1', 18792), Handler).serve_forever()
