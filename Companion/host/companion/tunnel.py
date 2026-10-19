from __future__ import annotations

import asyncio
import contextlib
import json
from urllib.parse import urlsplit

import aiohttp

from .domain import APIError, MAX_RESPONSE, encoded
from .attachments import MAX_TUNNEL_FRAME, is_upload


class Tunnel:
    def __init__(self, service, url: str, host_id: str, token: str):
        parsed = urlsplit(url)
        if parsed.scheme != "wss" and not (parsed.scheme == "ws" and parsed.hostname in {"127.0.0.1", "localhost", "::1"}):
            raise ValueError("Remote relay tunnels require wss")
        if parsed.query or parsed.fragment or parsed.username or len(token) < 32:
            raise ValueError("Invalid relay configuration")
        self.service, self.url, self.token = service, url.rstrip("/") + "/tunnel/" + host_id, token
        self.task = None
        self.streams = {}
        self.requests = set()
        self.connected = False
        self.uploads = 0

    async def start(self):
        self.task = asyncio.create_task(self.run())

    async def close(self):
        if self.task:
            self.task.cancel()
            await asyncio.gather(self.task, return_exceptions=True)
        await asyncio.gather(*self.requests, return_exceptions=True)

    async def send(self, ws, payload):
        raw = await asyncio.to_thread(encoded, payload)
        if len(raw.encode()) > MAX_TUNNEL_FRAME:
            raise APIError("payload_too_large", "This result exceeds the tunnel frame size.", 413)
        await asyncio.wait_for(ws.send_str(raw), 10)

    async def run(self):
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=50)) as http:
            while True:
                try:
                    async with http.ws_connect(self.url, headers={"Authorization": "Bearer " + self.token}, heartbeat=20, max_msg_size=MAX_TUNNEL_FRAME) as ws:
                        self.connected = True
                        async for frame in ws:
                            if frame.type != aiohttp.WSMsgType.TEXT:
                                continue
                            data = await asyncio.to_thread(json.loads, frame.data) if len(frame.data) > 256 * 1024 else json.loads(frame.data)
                            if not isinstance(data, dict):
                                await ws.close(code=1008)
                                break
                            if data.get("type") == "unsubscribe":
                                task = self.streams.pop(data.get("stream_id"), None)
                                if task:
                                    task.cancel()
                                continue
                            if len(self.requests) >= 32:
                                await self.send(ws, {"type": "response", "id": data.get("id"), "status": 503, "body": {"error": {"code": "busy", "message": "Host is busy."}}})
                                continue
                            task = asyncio.create_task(self.handle(ws, data))
                            self.requests.add(task)
                            task.add_done_callback(self.requests.discard)
                except (aiohttp.ClientError, ConnectionError, TimeoutError, ValueError):
                    pass
                finally:
                    self.connected = False
                    for task in self.streams.values():
                        task.cancel()
                    await asyncio.gather(*self.streams.values(), return_exceptions=True)
                    self.streams.clear()
                await asyncio.sleep(2)

    async def handle(self, ws, data):
        upload = is_upload(data.get("method"), data.get("path", ""))
        reserved = False
        try:
            if upload:
                self.service.auth(data.get("authorization", ""), "chat")
                if self.uploads >= 2:
                    raise APIError("busy", "Two attachments are already uploading. Try again shortly.", 503)
                self.uploads += 1
                reserved = True
            if data.get("type") == "authorize_upload":
                self.service.auth(data.get("authorization", ""), "chat")
                result, status = {}, 200
            elif data.get("type") == "subscribe":
                device = self.service.auth(data.get("authorization", ""))
                stream = data["stream_id"]
                if stream in self.streams:
                    raise APIError("stream_exists", "This event stream already exists.", 409)
                queue = self.service.hub.subscribe("relay:" + stream, device["id"])
                self.streams[stream] = asyncio.create_task(self.events(ws, stream, device["id"], queue))
                result, status = {}, 200
            elif data.get("type") == "request":
                result, status = await self.service.dispatch(data["method"], data["path"], data.get("body", {}), data.get("authorization", ""), data.get("query", {}))
            else:
                raise APIError("invalid_tunnel", "Unsupported tunnel message.")
            if len((await asyncio.to_thread(encoded, result)).encode()) > MAX_RESPONSE - 1024:
                raise APIError("payload_too_large", "This result exceeds the safe response size.", 413)
        except APIError as error:
            result, status = {"error": {"code": error.code, "message": error.message}}, error.status
        except (aiohttp.ClientError, ConnectionError, TimeoutError):
            result, status = {"error": {"code": "offline", "message": "Hermes is reconnecting."}}, 503
        except Exception:
            result, status = {"error": {"code": "internal_error", "message": "Companion could not complete this request."}}, 500
        finally:
            if reserved:
                self.uploads -= 1
        with contextlib.suppress(aiohttp.ClientError, ConnectionError, TimeoutError):
            await self.send(ws, {"type": "response", "id": data.get("id"), "status": status, "body": result})

    async def events(self, ws, stream, device, queue):
        try:
            await self.send(ws, {"type": "event", "id": stream, "event": {"type": "connection", "payload": {"state": "connected" if self.service.gateway.connected else "offline"}}})
            while True:
                event = await queue.get()
                if event is None or not self.service.store.active(device):
                    await self.send(ws, {"type": "stream_closed", "id": stream})
                    return
                await self.send(ws, {"type": "event", "id": stream, "event": event})
        finally:
            self.service.hub.unsubscribe("relay:" + stream)
