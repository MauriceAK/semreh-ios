import asyncio
import json
import tempfile
import time
import unittest
from pathlib import Path

import httpx
import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from companion.delivery import APNs, Proactivity
from companion.store import Store


class APNsMockTests(unittest.IsolatedAsyncioTestCase):
    async def test_apns_mock_uses_signed_http2_request_and_generic_alert(self):
        with tempfile.TemporaryDirectory() as directory:
            key = ec.generate_private_key(ec.SECP256R1())
            path = Path(directory) / "key.p8"
            path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            provider = APNs(str(path), "KEY123", "TEAM123", "test.companion")
            await provider.client.aclose()
            observed = []
            def mock(request):
                observed.append(request)
                return httpx.Response(200)
            provider.client = httpx.AsyncClient(http2=True, transport=httpx.MockTransport(mock))
            result = await provider.send({"environment": "sandbox", "push_token": "a" * 64}, {"id": "update-one", "session_id": "canonical-session", "summary": "Private transcript must not be in notification"})
            self.assertEqual(result, "sent")
            request = observed[0]
            self.assertEqual(request.url.host, "api.sandbox.push.apple.com")
            self.assertEqual(request.headers["apns-topic"], "test.companion")
            self.assertEqual(request.headers["apns-collapse-id"], "update-one")
            claims = jwt.decode(request.headers["authorization"].split(" ")[1], key.public_key(), algorithms=["ES256"])
            self.assertEqual(claims["iss"], "TEAM123")
            payload = json.loads(request.content)
            self.assertEqual(payload["update_id"], "update-one")
            self.assertEqual(payload["session_id"], "canonical-session")
            self.assertNotIn("Private transcript", request.content.decode())
            await provider.close()

    async def test_durable_outbox_defers_quiet_hours_retries_and_deduplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "store.db")
            store = Store(path, "fixture-profile")
            pair = store.pair(store.invite(), "Phone")
            store.register_push(pair["device_id"], "a" * 64, "sandbox")
            store.set_preferences(pair["device_id"], {"notifications_enabled": True, "quiet_start": 0, "quiet_end": 60, "time_zone": "UTC"})
            update = store.add_update("result-run", {"kind": "result", "title": "Done", "summary": "Controlled"}, {"session_id": "canonical-session"}, now=0)
            class MockPush:
                def __init__(self):
                    self.calls = []
                async def send(self, device, event):
                    self.calls.append(event["id"])
                    if len(self.calls) == 1:
                        raise httpx.ReadTimeout("Controlled lost APNs response")
                    return "sent"
            push = MockPush()
            async def publish(event):
                pass
            service = Proactivity(None, store, publish, push)
            await service.deliver_once(now=30)
            self.assertEqual(push.calls, [])
            await service.deliver_once(now=3601)
            self.assertEqual(push.calls, [update["id"]])
            store.close()
            store = Store(path, "fixture-profile")
            service = Proactivity(None, store, publish, push)
            await service.deliver_once(now=3602)
            self.assertEqual(len(push.calls), 1)
            await service.deliver_once(now=3607)
            self.assertEqual(push.calls, [update["id"], update["id"]])
            await service.deliver_once(now=9999)
            self.assertEqual(len(push.calls), 2)
            self.assertEqual(store.deliveries(9999), [])
            store.close()

    async def test_stale_request_push_is_suppressed(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(str(Path(directory) / "state.db"), "fixture-profile")
            pair = store.pair(store.invite(), "Phone")
            store.register_push(pair["device_id"], "b" * 64, "sandbox")
            store.add_update("request-old", {"kind": "needs_you", "title": "Approve", "summary": "Controlled", "session_id": "session"}, {"session_id": "session", "request_id": "old", "generation": "old-generation"}, now=0)
            class MockGateway:
                async def snapshot(self, session):
                    return {"requests": [{"id": "new", "generation": "new-generation"}]}
            class MockPush:
                async def send(self, device, event):
                    raise AssertionError("Stale request must not reach APNs")
            async def publish(event):
                pass
            service = Proactivity(MockGateway(), store, publish, MockPush())
            await service.deliver_once(now=10)
            self.assertEqual(store.deliveries(10), [])
            store.close()

    async def test_unexpected_background_failure_is_visible_in_host_health(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(str(Path(directory) / "state.db"), "fixture-profile")
            class InvalidUpstream:
                async def rest(self, *args, **kwargs):
                    return [None]
            async def publish(event):
                pass
            service = Proactivity(InvalidUpstream(), store, publish)
            await service.start()
            for _ in range(20):
                if service.problem:
                    break
                await asyncio.sleep(0.01)
            self.assertIn("worker stopped", service.problem)
            await service.close()
            store.close()
