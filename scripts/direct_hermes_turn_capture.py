#!/usr/bin/env python3
"""Real pinned Hermes turn/interrupt checks using the deterministic local model."""
import asyncio
import json
from pathlib import Path
import sqlite3
import time

import httpx
from websockets.asyncio.client import connect
from direct_hermes_probe import RUNTIME, PIN, validate
from direct_hermes_capture import sanitize, write_fixture, BASE, HEADERS

OUTPUT = Path(__file__).resolve().parents[1] / 'docs/migration/fixtures/slice1-local-turn.json'


async def main():
    validate()
    credentials = json.loads((RUNTIME / 'credentials.json').read_text())
    evidence = {'configured_source_pin': PIN, 'provider': 'deterministic localhost fixture; NOT external LLM proof', 'frames': []}
    async with httpx.AsyncClient(base_url=BASE, headers=HEADERS, trust_env=False) as client:
        response = await client.post('/auth/password-login', json={'provider': 'basic', **credentials, 'next': ''})
        response.raise_for_status()
        ticket = (await client.post('/api/auth/ws-ticket')).json()['ticket']
        async with connect('ws://127.0.0.1:18791/api/ws?ticket=' + ticket, origin='http://semreh-slice1.test:18791', proxy=None) as ws:
            next_id = 1
            async def receive():
                frame = json.loads(await asyncio.wait_for(ws.recv(), 60))
                evidence['frames'].append(sanitize(frame))
                return frame
            async def rpc(method, params):
                nonlocal next_id
                rid = next_id
                next_id += 1
                request = {'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params}
                evidence['frames'].append({'sent': sanitize(request)})
                await ws.send(json.dumps(request))
                while True:
                    frame = await receive()
                    if frame.get('id') == rid:
                        if 'error' in frame:
                            raise RuntimeError(json.dumps(sanitize(frame['error'])))
                        return frame['result']
            await receive()
            created = await rpc('session.create', {'cwd': str(RUNTIME / 'tools'), 'model': 'semreh-fixture', 'provider': 'custom'})
            sid, stored = created['session_id'], created['stored_session_id']
            await rpc('prompt.submit', {'session_id': sid, 'text': 'SEMREH_SLICE1_PROMPT'})
            while True:
                frame = await receive()
                event = frame.get('params', {})
                if event.get('type') == 'message.complete' and event.get('session_id') == sid:
                    if event.get('payload', {}).get('status') == 'error':
                        raise RuntimeError('Hermes reported terminal error: ' + json.dumps(event['payload']))
                    break
            with sqlite3.connect('file:' + str(RUNTIME / 'home/state.db') + '?mode=ro', uri=True) as db:
                rows = db.execute('SELECT role,content FROM messages WHERE session_id=? ORDER BY id', (stored,)).fetchall()
            evidence['durable_rows'] = rows
            assert sum(role == 'user' for role, _ in rows) == 1
            assert sum(role == 'assistant' for role, _ in rows) == 1
            assert any(role == 'assistant' and 'SEMREH_SLICE1_ACK' in (text or '') for role, text in rows)
            response = await client.get('/api/sessions/' + stored + '/messages', params={'profile': 'default', 'include_compacted': 'true', 'order': 'latest', 'limit': 20, 'offset': 0})
            response.raise_for_status()
            evidence['rest_history'] = sanitize(response.json())
            await rpc('prompt.submit', {'session_id': sid, 'text': 'SEMREH_INTERRUPT_FIXTURE'})
            running = await rpc('session.status', {'session_id': sid})
            assert 'Agent Running: Yes' in running['output']
            interrupt_frame_start = len(evidence['frames'])
            await rpc('session.interrupt', {'session_id': sid})
            deadline = time.monotonic() + 40
            while True:
                status = await rpc('session.status', {'session_id': sid})
                if 'Agent Running: No' in status['output']:
                    evidence['interrupt_server_nonrunning'] = True
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError('Server still running after interrupt')
                await asyncio.sleep(0.25)
            def interrupted_event_seen():
                return any(f.get('params', {}).get('type') == 'message.complete'
                           and f['params'].get('session_id') == sid
                           and f['params'].get('payload', {}).get('status') == 'interrupted'
                           for f in evidence['frames'][interrupt_frame_start:])
            while not interrupted_event_seen():
                await receive()
            evidence['matching_interrupted_terminal_event'] = True
            await rpc('session.close', {'session_id': sid})
        await client.post('/auth/logout')
    write_fixture(OUTPUT, evidence)
    print('Exact durable turn counts, canonical REST and server-confirmed interrupt passed: ' + str(OUTPUT))


if __name__ == '__main__':
    asyncio.run(main())
