#!/usr/bin/env python3
"""Capture sanitized auth/WS fixtures from the exact disposable local backend."""
import asyncio
import json
from pathlib import Path
import time

import httpx
from websockets.asyncio.client import connect
from websockets.exceptions import InvalidStatus

from direct_hermes_probe import RUNTIME, PIN, validate

OUTPUT = Path(__file__).resolve().parents[1] / 'docs/migration/fixtures/slice1-local-auth.json'
BASE = 'http://127.0.0.1:18791'
HEADERS = {'Host': 'semreh-slice1.test:18791'}
SENSITIVE = {'password', 'password_hash', 'secret', 'ticket', 'access_token', 'refresh_token', 'token',
             'authorization', 'api_key', 'cookie', 'set-cookie', 'client_secret', 'system_prompt'}


def sanitize(value):
    if isinstance(value, dict):
        return {k: '<redacted>' if k.lower() in SENSITIVE else sanitize(v) for k, v in value.items()}
    if isinstance(value, list):
        return [sanitize(v) for v in value]
    if isinstance(value, str):
        return value.replace('/Users/maurice', '<test-account>')
    return value


def write_fixture(path, evidence):
    if path.is_symlink() or path.parent.resolve() != path.parent:
        raise RuntimeError('Fixture path must not be a symlink')
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(sanitize(evidence), indent=2) + '\n'
    credentials = json.loads((RUNTIME / 'credentials.json').read_text())
    config = json.loads((RUNTIME / 'home/config.yaml').read_text())
    for secret in (credentials['password'], config['dashboard']['basic_auth']['secret'],
                   config['dashboard']['basic_auth']['password_hash']):
        if secret in text:
            raise RuntimeError('Secret found in fixture; refusing to write')
    path.write_text(text)


async def main():
    validate()
    credentials = json.loads((RUNTIME / 'credentials.json').read_text())
    results = {'configured_source_pin': PIN, 'deployment': 'loopback HTTP with explicit public Host; NOT real HTTPS/proxy gate',
               'captured_at_unix': int(time.time()), 'http': [], 'websocket': []}
    async with httpx.AsyncClient(base_url=BASE, headers=HEADERS, trust_env=False, follow_redirects=False) as client:
        async def request(method, path, body=None):
            response = await client.request(method, path, json=body)
            try:
                data = response.json()
            except ValueError:
                data = {'non_json_body': True}
            # Retain names and attributes, never cookie values.
            cookie_attributes = []
            for cookie in response.headers.get_list('set-cookie'):
                first, *attrs = cookie.split(';')
                cookie_attributes.append({'name': first.split('=', 1)[0], 'attributes': [a.strip() for a in attrs]})
            results['http'].append({'method': method, 'path': path, 'request': sanitize(body),
                                    'status': response.status_code, 'body': sanitize(data),
                                    'set_cookie_attributes': cookie_attributes})
            return response, data
        status, _ = await request('GET', '/api/status')
        assert status.status_code == 200
        providers, data = await request('GET', '/api/auth/providers')
        assert providers.status_code == 200 and data['providers'][0]['supports_password']
        unauth, _ = await request('GET', '/api/sessions')
        assert unauth.status_code == 401
        invalid, _ = await request('POST', '/auth/password-login', {
            'provider': 'basic', 'username': credentials['username'], 'password': 'deliberately-invalid', 'next': ''})
        assert invalid.status_code == 401
        assert not list(client.cookies.jar), 'Invalid credentials created cookies'
        login, _ = await request('POST', '/auth/password-login', {'provider': 'basic', **credentials, 'next': ''})
        assert login.status_code in (200, 302, 303), f'Unexpected login status {login.status_code}'
        protected, _ = await request('GET', '/api/sessions')
        assert protected.status_code == 200
        ticket_response, ticket_data = await request('POST', '/api/auth/ws-ticket')
        assert ticket_response.status_code == 200
        ticket = ticket_data['ticket']
        ws_url = 'ws://127.0.0.1:18791/api/ws?ticket=' + ticket
        async with connect(ws_url, origin='http://semreh-slice1.test:18791', proxy=None) as ws:
            ready = json.loads(await asyncio.wait_for(ws.recv(), 30))
            results['websocket'].append(sanitize(ready))
            assert ready.get('method') == 'event' and ready.get('params', {}).get('type') == 'gateway.ready', 'Expected gateway.ready event'
            await ws.send(json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'gateway.ping', 'params': {}}))
            while True:
                message = json.loads(await asyncio.wait_for(ws.recv(), 30))
                results['websocket'].append(sanitize(message))
                if message.get('id') == 1:
                    assert 'result' in message
                    break
        try:
            async with connect(ws_url, origin='http://semreh-slice1.test:18791', proxy=None):
                raise AssertionError('Reused ticket accepted')
        except InvalidStatus as exc:
            assert exc.response.status_code == 403, 'Unexpected ticket-reuse rejection status'
            results['reused_ticket_rejected_http_status'] = exc.response.status_code
        fresh, fresh_data = await request('POST', '/api/auth/ws-ticket')
        assert fresh.status_code == 200 and fresh_data['ticket'] != ticket
        async with connect('ws://127.0.0.1:18791/api/ws?ticket=' + fresh_data['ticket'],
                           origin='http://semreh-slice1.test:18791', proxy=None) as ws:
            fresh_ready = json.loads(await asyncio.wait_for(ws.recv(), 30))
            assert fresh_ready.get('params', {}).get('type') == 'gateway.ready'
            results['fresh_ticket_reconnect_ready'] = True
        logout, _ = await request('POST', '/auth/logout')
        assert logout.status_code in (200, 302, 303)
        after, _ = await request('GET', '/api/sessions')
        assert after.status_code == 401
    write_fixture(OUTPUT, results)
    print('Local auth/ready/ping/ticket/logout assertions passed; sanitized fixture: ' + str(OUTPUT))


if __name__ == '__main__':
    asyncio.run(main())
