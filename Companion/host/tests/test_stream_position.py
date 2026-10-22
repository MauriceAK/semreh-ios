import asyncio
import copy
import unittest

from companion.gateway import Gateway, Live, PublicTurn
from companion.domain import APIError


class SnapshotStreamPositionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.gateway = Gateway('http://127.0.0.1', 'unused', 'test-profile', 'unused')
        self.gateway.generation = 'fixture-generation'
        self.gateway.epoch = 'fixture-upstream-epoch'
        self.live = Live(stored='fixture-session', runtime='fixture-runtime',
                         generation=self.gateway.generation, state='working',
                         segment='segment-A', turn=PublicTurn(set()))
        self.gateway.live[self.live.stored] = self.live
        self.captured = asyncio.Event()
        self.release = asyncio.Event()
        self.history_calls = 0
        self.events = []
        self.sequence = 0
        self.inflight = {}
        self.canonical_rows = []
        self.metadata = {}
        self.turn_started_at = None

        async def attach(stored):
            self.assertEqual(stored, self.live.stored)
            return self.live

        async def rpc(method, params):
            self.assertEqual(method, 'session.activate')
            return {'session_id': self.live.runtime, 'running': True, 'turn_started_at': self.turn_started_at,
                    'inflight': {'assistant': self.live.turn.current_text if self.live.turn else 'Current answer', **self.inflight}}

        async def history(stored, **kwargs):
            self.history_calls += 1
            if self.history_calls == 1:
                self.captured.set()
                await self.release.wait()
            if projection := kwargs.get('projection'):
                projection.history_ids = {row['id'] for row in self.canonical_rows}
                projection.history_metadata = copy.deepcopy(self.metadata)
            return {'messages': copy.deepcopy(self.canonical_rows), 'before': None, 'has_more': False}

        async def controls(stored):
            return {'model': 'fixture-model'}

        async def publish(event):
            self.events.append(copy.deepcopy(event))

        self.gateway.attach = attach
        self.gateway.rpc = rpc
        self.gateway.history = history
        self.gateway.controls = controls
        self.gateway.publish = publish

    async def event(self, kind, payload):
        self.sequence += 1
        await self.gateway._apply_event({'connection_generation': self.gateway.generation,
                                        'session_id': self.live.runtime, 'seq': self.sequence,
                                        'type': kind, 'payload': payload})

    def replay(self, snapshot):
        rows = {row['id']: row['text'] for row in snapshot['page']['messages']}
        cut = snapshot.get('stream_position')
        for event in self.events:
            position = event.get('stream_position')
            if cut and position and position['epoch'] == cut['epoch'] and position['sequence'] <= cut['sequence']:
                continue
            if event['type'] == 'delta':
                delta = event['payload']
                rows[delta['id']] = delta['text'] if delta['replace'] else rows.get(delta['id'], '') + delta['text']
        return rows

    async def test_snapshot_splits_pending_batch_and_replays_only_its_suffix(self):
        await self.event('message.delta', {'text': 'A'})
        pending = asyncio.create_task(self.gateway.snapshot(self.live.stored))
        await self.captured.wait()
        await self.event('message.delta', {'text': 'B'})
        await self.gateway.flush_deltas(self.live.stored)
        self.release.set()
        snapshot = await pending
        self.assertEqual(self.replay(snapshot)['segment-A'], 'AB')
        self.assertEqual(self.live.turn.current_text, 'AB')
        self.assertEqual(self.history_calls, 1)
        self.assertEqual([event['payload']['text'] for event in self.events], ['A', 'B'])
        self.assertLess(self.events[0]['stream_position']['sequence'], snapshot['stream_position']['sequence'])
        self.assertGreater(self.events[1]['stream_position']['sequence'], snapshot['stream_position']['sequence'])

    async def test_interim_during_history_does_not_mix_sealed_and_active_segments(self):
        await self.event('message.delta', {'text': 'Public interim.'})
        pending = asyncio.create_task(self.gateway.snapshot(self.live.stored))
        await self.captured.wait()
        await self.event('message.interim', {'text': 'Public interim.', 'already_streamed': True})
        self.release.set()
        snapshot = await pending
        self.assertEqual([row['text'] for row in snapshot['page']['messages']], ['Public interim.'])
        self.assertEqual(snapshot['page']['messages'][0]['id'], 'segment-A')
        socket_snapshot = next(event for event in self.events if event['type'] == 'snapshot')
        self.assertEqual(socket_snapshot['stream_position'], socket_snapshot['payload']['stream_position'])
        self.assertGreater(snapshot['stream_position']['sequence'], socket_snapshot['stream_position']['sequence'])
        self.assertEqual(self.history_calls, 3)

    async def test_every_snapshot_has_a_new_cut_even_without_another_delta(self):
        self.release.set()
        first = await self.gateway.snapshot(self.live.stored)
        second = await self.gateway.snapshot(self.live.stored)
        self.assertEqual(first['stream_position']['epoch'], second['stream_position']['epoch'])
        self.assertGreater(second['stream_position']['sequence'], first['stream_position']['sequence'])
        self.assertGreater(first['stream_position']['sequence'], 0)

    async def test_session_counter_survives_live_replacement_and_upstream_reconnect(self):
        self.release.set()
        first = await self.gateway.snapshot(self.live.stored)
        self.gateway.generation = 'replacement-upstream-connection'
        self.gateway.epoch = 'replacement-upstream-replay'
        self.gateway.live.pop(self.live.stored)
        self.live = Live(stored='fixture-session', runtime='replacement-runtime', generation=self.gateway.generation,
                         state='working', turn=PublicTurn(set()))
        self.gateway.live[self.live.stored] = self.live
        second = await self.gateway.snapshot(self.live.stored)
        self.assertEqual(first['stream_position']['epoch'], second['stream_position']['epoch'])
        self.assertGreater(second['stream_position']['sequence'], first['stream_position']['sequence'])
        replacement = Gateway('http://127.0.0.1', 'unused', 'test-profile', 'unused')
        self.assertNotEqual(replacement.stream_epoch, self.gateway.stream_epoch)

    async def test_snapshot_keeps_captured_requests_state_and_old_segment(self):
        self.live.requests = [{'id': 'question-1', 'method': 'clarify', 'params': {'question': 'Choose'}}]
        self.live.state = 'waiting'
        original_rpc = self.gateway.rpc

        async def rpc(method, params):
            result = await original_rpc(method, params)
            result['open_requests'] = copy.deepcopy(self.live.requests)
            return result

        self.gateway.rpc = rpc
        pending = asyncio.create_task(self.gateway.snapshot(self.live.stored))
        await self.captured.wait()
        await self.event('request.cancel', {'id': 'question-1'})
        self.live.state = 'working'
        self.release.set()
        snapshot = await pending
        self.assertEqual(snapshot['state'], 'waiting')
        self.assertEqual([request['id'] for request in snapshot['requests']], ['question-1'])
        self.assertEqual(self.live.requests, [])
        self.assertGreater(self.events[-1]['stream_position']['sequence'], snapshot['stream_position']['sequence'])

    async def test_reconnect_during_history_cannot_retag_a_captured_request(self):
        self.gateway.ready.set()
        self.live.requests = [{'id': 'old-request', 'method': 'clarify', 'params': {'question': 'Choose'}}]
        original_rpc = self.gateway.rpc

        async def rpc(method, params):
            result = await original_rpc(method, params)
            result['open_requests'] = copy.deepcopy(self.live.requests)
            return result

        self.gateway.rpc = rpc
        pending = asyncio.create_task(self.gateway.snapshot(self.live.stored))
        await self.captured.wait()
        self.live.requests = []
        self.live.state = 'offline'
        self.gateway.generation = 'new-upstream-generation'
        self.release.set()
        with self.assertRaises(APIError) as failure:
            await pending
        self.assertEqual(failure.exception.status, 503)
        self.assertEqual(self.live.requests, [])
        self.assertEqual(self.live.state, 'offline')
        self.assertEqual(self.history_calls, 1)

    async def test_disconnect_during_history_rejects_a_captured_waiting_state(self):
        self.gateway.ready.set()
        self.live.requests = [{'id': 'old-request', 'method': 'clarify', 'params': {'question': 'Choose'}}]
        original_rpc = self.gateway.rpc

        async def rpc(method, params):
            result = await original_rpc(method, params)
            result['open_requests'] = copy.deepcopy(self.live.requests)
            return result

        self.gateway.rpc = rpc
        pending = asyncio.create_task(self.gateway.snapshot(self.live.stored))
        await self.captured.wait()
        self.gateway.ready.clear()
        self.live.requests = []
        self.live.state = 'offline'
        self.release.set()
        with self.assertRaises(APIError) as failure:
            await pending
        self.assertEqual(failure.exception.status, 503)
        self.assertEqual(self.live.state, 'offline')
        self.assertEqual(self.history_calls, 1)

    async def test_reconnect_during_activation_does_not_apply_the_old_response(self):
        self.gateway.ready.set()
        original_rpc = self.gateway.rpc

        async def rpc(method, params):
            result = await original_rpc(method, params)
            result['open_requests'] = [{'id': 'old-request', 'method': 'clarify', 'params': {'question': 'Choose'}}]
            self.captured.set()
            await self.release.wait()
            return result

        self.gateway.rpc = rpc
        pending = asyncio.create_task(self.gateway.snapshot(self.live.stored))
        await self.captured.wait()
        self.gateway.generation = 'new-upstream-generation'
        self.live.state = 'offline'
        self.release.set()
        with self.assertRaises(APIError) as failure:
            await pending
        self.assertEqual(failure.exception.status, 503)
        self.assertEqual(self.live.requests, [])
        self.assertEqual(self.live.state, 'offline')
        self.assertEqual(self.live.generation, 'fixture-generation')
        self.assertEqual(self.history_calls, 0)

    def test_request_projection_keeps_its_captured_generation(self):
        self.live.requests = [
            {'id': 'approval', 'method': 'approval', 'params': {}},
            {'id': 'clarify', 'method': 'clarify', 'params': {'question': 'Choose'}},
            {'id': 'host', 'method': 'unsupported', 'params': {}}]
        self.gateway.generation = 'new-upstream-generation'
        projected = self.gateway.requests(self.live)
        self.assertEqual({request['generation'] for request in projected}, {'fixture-generation'})
        self.assertEqual({request['id'] for request in projected}, {'approval', 'clarify', 'host'})

    async def test_concurrent_snapshots_keep_independent_cuts_and_correction_order(self):
        await self.event('message.delta', {'text': 'BeforeAfter'})
        self.inflight = {'corrections': ['Use another file'], 'correction_offsets': [6]}
        first_task = asyncio.create_task(self.gateway.snapshot(self.live.stored))
        await self.captured.wait()
        await self.event('message.delta', {'text': '! '})
        second = await self.gateway.snapshot(self.live.stored)
        self.release.set()
        first = await first_task
        self.assertEqual([row['text'] for row in first['page']['messages']], ['Before', 'Use another file', 'After'])
        self.assertEqual([row['text'] for row in second['page']['messages']], ['Before', 'Use another file', 'After! '])
        self.assertGreater(second['stream_position']['sequence'], first['stream_position']['sequence'])
        self.assertEqual(self.live.turn.current_text, 'BeforeAfter! ')
        self.assertEqual(self.live.turn.correction_after_counts, {0: 0})

    async def test_completion_during_history_retries_without_duplicate_provisional_final(self):
        await self.event('message.delta', {'text': 'The answer.'})
        pending = asyncio.create_task(self.gateway.snapshot(self.live.stored))
        await self.captured.wait()
        self.canonical_rows = [{'id': 'canonical-final', 'role': 'assistant', 'text': 'The answer.', 'provisional': False}]
        await self.event('message.complete', {'text': 'The answer.', 'status': 'complete',
                                             'persisted_turn': {'row_ids': ['canonical-final'], 'final_assistant_row_id': 'canonical-final'}})
        self.release.set()
        snapshot = await pending
        self.assertEqual(snapshot['page']['messages'], self.canonical_rows)
        self.assertEqual(self.history_calls, 3)
        completion = next(event for event in self.events if event['type'] == 'snapshot')
        self.assertGreater(snapshot['stream_position']['sequence'], completion['stream_position']['sequence'])

    async def test_repeated_structural_changes_stop_after_three_attempts(self):
        async def history(stored, **kwargs):
            self.history_calls += 1
            self.live.projection_revision += 1
            return {'messages': [], 'before': None, 'has_more': False}

        self.gateway.history = history
        with self.assertRaisesRegex(Exception, 'Hermes changed this conversation'):
            await self.gateway.snapshot(self.live.stored)
        self.assertEqual(self.history_calls, 3)

    async def test_canonical_final_ahead_of_complete_event_never_returns_duplicate(self):
        await self.event('message.delta', {'text': 'The answer.'})
        pending = asyncio.create_task(self.gateway.snapshot(self.live.stored))
        await self.captured.wait()
        self.canonical_rows = [{'id': 'canonical-final', 'role': 'assistant', 'text': 'The answer.', 'provisional': False}]
        self.release.set()
        with self.assertRaisesRegex(Exception, 'Hermes is finishing this reply'):
            await pending
        self.assertEqual(self.history_calls, 3)
        self.assertFalse(any(event['type'] == 'snapshot' for event in self.events))
        await self.event('message.complete', {'text': 'The answer.', 'status': 'complete',
                                             'persisted_turn': {'row_ids': ['canonical-final'], 'final_assistant_row_id': 'canonical-final'}})
        final = next(event for event in self.events if event['type'] == 'snapshot')
        self.assertEqual(final['payload']['page']['messages'], self.canonical_rows)

    async def test_cold_resume_keeps_old_history_and_catches_timestamped_ahead_final(self):
        self.release.set()
        self.live.turn = None
        self.turn_started_at = 10
        self.canonical_rows = [
            {'id': 'old-user', 'role': 'user', 'text': 'Previous ask', 'provisional': False},
            {'id': 'old-answer', 'role': 'assistant', 'text': 'Previous answer', 'provisional': False}]
        self.metadata = {'old-user': {'timestamp': 1}, 'old-answer': {'timestamp': 2}}
        first = await self.gateway.snapshot(self.live.stored)
        self.assertEqual([row['text'] for row in first['page']['messages']], ['Previous ask', 'Previous answer', 'Current answer'])
        self.canonical_rows.append({'id': 'new-final', 'role': 'assistant', 'text': 'Current answer', 'provisional': False})
        self.metadata['new-final'] = {'timestamp': 11}
        with self.assertRaisesRegex(Exception, 'Hermes is finishing this reply'):
            await self.gateway.snapshot(self.live.stored)

    async def test_completed_turn_stays_completed_until_new_inflight_turn_exists(self):
        self.release.set()
        self.live.turn.completed = True
        self.live.turn.started_at = 10
        self.live.turn.final_row_id = 'canonical-final'
        self.live.turn.persisted_ids = {'canonical-final'}
        self.canonical_rows = [{'id': 'canonical-final', 'role': 'assistant', 'text': 'The answer.', 'provisional': False}]
        self.metadata = {'canonical-final': {'timestamp': 11}}

        async def rpc(method, params):
            return {'session_id': self.live.runtime, 'running': True, 'turn_started_at': 10}

        self.gateway.rpc = rpc
        snapshot = await self.gateway.snapshot(self.live.stored)
        self.assertEqual(snapshot['page']['messages'], self.canonical_rows)
        self.assertTrue(self.live.turn.completed)
        self.assertEqual(self.history_calls, 1)


if __name__ == '__main__':
    unittest.main()
