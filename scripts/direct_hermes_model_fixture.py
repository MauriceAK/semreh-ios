#!/usr/bin/env python3
"""Deterministic local OpenAI-compatible provider for real Hermes gateway tests.

Not an external model smoke: no real credentials, no tool calls. Delays let tests
interrupt a genuinely pending provider request. HTTP request bodies are not logged.
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time

REASONING_PROBE = False


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
        text = 'SEMREH_SLICE1_ACK'
        if REASONING_PROBE and 'SEMREH_REASONING_PROBE' in str(last_user):
            # Echo only the synthetic request's effort, not prompts or headers.
            # gpt-5 is a protocol fixture name here; no OpenAI service is called.
            reasoning = body.get('reasoning') or {}
            effort = body.get('reasoning_effort') or reasoning.get('effort')
            if reasoning.get('enabled') is False:
                effort = 'none'
            text = 'SEMREH_REASONING_EFFORT:' + str(effort or 'missing')
        base = {'id': 'chatcmpl-semreh-fixture', 'created': int(time.time()), 'model': 'semreh-fixture'}
        try:
            if body.get('stream'):
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                for delta, reason in [({'role': 'assistant', 'content': text}, None), ({}, 'stop')]:
                    chunk = {**base, 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': delta, 'finish_reason': reason}]}
                    self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
                    self.wfile.flush()
                self.wfile.write(b'data: [DONE]\n\n')
            else:
                self.reply({**base, 'object': 'chat.completion', 'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': text}, 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}})
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when the client interrupts a pending fixture turn.


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reasoning-probe', action='store_true')
    REASONING_PROBE = parser.parse_args().reasoning_probe
    print('Deterministic model fixture listening on 127.0.0.1:18792', flush=True)
    ThreadingHTTPServer(('127.0.0.1', 18792), Handler).serve_forever()
