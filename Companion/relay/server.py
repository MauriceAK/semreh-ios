from __future__ import annotations

import argparse
import asyncio
import contextlib
import hmac
import json
import os
import re
import uuid
from pathlib import Path

import aiohttp
from aiohttp import web

MAX_FRAME = 8 * 1024 * 1024
MAX_REQUEST = 256 * 1024
MAX_RESPONSE = 4 * 1024 * 1024
MAX_UPLOAD = 7 * 1024 * 1024
UPLOAD_ROUTE = re.compile(r"/v1/sessions/[A-Za-z0-9_.:-]+/attachments")
ROUTE = re.compile(r"/v1/(host|pair|sessions(?:/[A-Za-z0-9_.:-]+/(?:snapshot|history|controls|commands|attachments(?:/[a-f0-9-]{36})?))?|jobs(?:/[A-Za-z0-9_.:-]+)?|updates(?:/[A-Za-z0-9-]+)?|preferences|device|events)")


class Connection:
    def __init__(self, ws):
        self.ws = ws
        self.pending = {}
        self.streams = {}
        self.queue = asyncio.Queue(maxsize=128)
        self.queued_bytes = 0
        self.uploads = 0

    async def send(self, payload):
        raw = await asyncio.to_thread(json.dumps, payload, ensure_ascii=False, separators=(",", ":")) if payload.get("method") == "POST" and UPLOAD_ROUTE.fullmatch(payload.get("path", "")) else json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        size = len(raw.encode())
        if size > MAX_FRAME or self.queued_bytes + size > MAX_FRAME * 2:
            raise web.HTTPServiceUnavailable(text="Host tunnel is busy")
        try:
            self.queue.put_nowait((raw, size))
            self.queued_bytes += size
        except asyncio.QueueFull:
            raise web.HTTPServiceUnavailable(text="Host tunnel is busy") from None

    async def writer(self):
        while True:
            raw, size = await self.queue.get()
            self.queued_bytes -= size
            await asyncio.wait_for(self.ws.send_str(raw), 15)

    async def call(self, payload):
        if len(self.pending) >= 64:
            raise web.HTTPServiceUnavailable(text="Host has too many pending requests")
        key = str(uuid.uuid4())
        future = asyncio.get_running_loop().create_future()
        self.pending[key] = future
        try:
            await self.send({**payload, "id": key})
            return await asyncio.wait_for(future, 45)
        except (TimeoutError, ConnectionError):
            return {"status": 503, "body": {"error": {"code": "host_unavailable", "message": "Host connection ended. Check the operation status before trying a new action."}}}
        finally:
            self.pending.pop(key, None)


class Relay:
    def __init__(self, hosts: dict[str, str]):
        if not hosts or any(not re.fullmatch(r"[A-Za-z0-9_-]{8,80}", key) or not isinstance(token, str) or len(token) < 32 for key, token in hosts.items()):
            raise ValueError("Configure host IDs and independent random host credentials")
        self.hosts, self.connections = hosts, {}
        self.uploads = 0

    async def tunnel(self, request):
        host_id = request.match_info["host"]
        token = request.headers.get("Authorization", "").removeprefix("Bearer ")
        expected = self.hosts.get(host_id)
        if not expected or not hmac.compare_digest(expected, token) or not request.headers.get("Authorization", "").startswith("Bearer "):
            raise web.HTTPUnauthorized()
        if request.query:
            raise web.HTTPBadRequest()
        if host_id in self.connections:
            raise web.HTTPConflict(text="Host tunnel already connected")
        ws = web.WebSocketResponse(heartbeat=20, max_msg_size=MAX_FRAME)
        await ws.prepare(request)
        connection = Connection(ws)
        self.connections[host_id] = connection
        writer = asyncio.create_task(connection.writer())
        try:
            async for frame in ws:
                if frame.type != aiohttp.WSMsgType.TEXT:
                    continue
                try:
                    data = await asyncio.to_thread(json.loads, frame.data) if len(frame.data) > MAX_REQUEST else json.loads(frame.data)
                    key = data.get("id")
                    if data.get("type") in {"response", "subscribed"}:
                        future = connection.pending.get(key)
                        if future and not future.done():
                            future.set_result(data)
                    elif data.get("type") == "event":
                        queue = connection.streams.get(key)
                        if queue is not None:
                            if queue.full():
                                while not queue.empty():
                                    queue.get_nowait()
                                queue.put_nowait(None)
                            else:
                                queue.put_nowait(data.get("event"))
                    elif data.get("type") == "stream_closed":
                        queue = connection.streams.get(key)
                        if queue is not None:
                            while not queue.empty():
                                queue.get_nowait()
                            queue.put_nowait(None)
                except (ValueError, TypeError):
                    await ws.close(code=1008)
                    break
        finally:
            if self.connections.get(host_id) is connection:
                self.connections.pop(host_id, None)
            writer.cancel()
            await asyncio.gather(writer, return_exceptions=True)
            for future in connection.pending.values():
                if not future.done():
                    future.set_exception(ConnectionError("Host disconnected"))
            for queue in connection.streams.values():
                while not queue.empty():
                    queue.get_nowait()
                queue.put_nowait(None)
        return ws

    async def phone(self, request):
        path = "/v1/" + request.match_info["path"]
        if not ROUTE.fullmatch(path) or request.method not in {"GET", "POST", "PATCH", "PUT", "DELETE"}:
            raise web.HTTPNotFound()
        if "token" in request.query or "profile" in request.query:
            raise web.HTTPBadRequest()
        connection = self.connections.get(request.match_info["host"])
        if connection is None:
            return web.json_response({"error": {"code": "host_offline", "message": "Your Hermes host is offline."}}, status=503)
        authorization = request.headers.get("Authorization", "")
        if len(authorization) > 200:
            raise web.HTTPBadRequest()
        if path == "/v1/events" and request.method == "GET":
            if request.query:
                raise web.HTTPBadRequest()
            return await self.events(request, connection, authorization)
        upload = request.method == "POST" and UPLOAD_ROUTE.fullmatch(path) is not None
        limit = MAX_UPLOAD if upload else MAX_REQUEST
        if request.content_length is not None and request.content_length > limit:
            return web.json_response({"error": {"code": "payload_too_large", "message": "This request is too large."}}, status=413)
        if upload:
            if not authorization.startswith("Bearer "):
                return web.json_response({"error": {"code": "unauthorized", "message": "Pair this device to continue."}}, status=401)
            checked = await connection.call({"type": "authorize_upload", "authorization": authorization})
            if checked.get("status") != 200:
                return web.json_response(checked.get("body", {}), status=checked.get("status", 503))
            if connection.uploads >= 2 or self.uploads >= 16:
                return web.json_response({"error": {"code": "busy", "message": "Attachments are already uploading. Try again shortly."}}, status=503)
            connection.uploads += 1
            self.uploads += 1
        try:
            raw = bytearray()
            try:
                async with asyncio.timeout(30):
                    async for chunk in request.content.iter_chunked(65536):
                        raw.extend(chunk)
                        if len(raw) > limit:
                            return web.json_response({"error": {"code": "payload_too_large", "message": "This request is too large."}}, status=413)
            except TimeoutError:
                return web.json_response({"error": {"code": "request_timeout", "message": "Uploading took too long. Check your connection and try again."}}, status=408)
            try:
                body = await asyncio.to_thread(json.loads, raw) if raw and upload else json.loads(raw) if raw else {}
            except (ValueError, UnicodeError):
                raise web.HTTPBadRequest() from None
            response = await connection.call({"type": "request", "method": request.method, "path": path, "query": dict(request.query), "authorization": authorization, "body": body})
        finally:
            if upload:
                connection.uploads -= 1
                self.uploads -= 1
        status = response.get("status", 502)
        if type(status) is not int or not 100 <= status <= 599:
            status = 502
        raw = await asyncio.to_thread(json.dumps, response.get("body", {}), ensure_ascii=False, separators=(",", ":"))
        if len(raw.encode()) > MAX_RESPONSE:
            return web.json_response({"error": {"code": "payload_too_large", "message": "This result exceeds the safe response size."}}, status=413)
        return web.Response(text=raw, content_type="application/json", status=status, headers={"Cache-Control": "no-store"})

    async def events(self, request, connection, authorization):
        if len(connection.streams) >= 128:
            raise web.HTTPServiceUnavailable()
        stream_id = str(uuid.uuid4())
        queue = asyncio.Queue(maxsize=64)
        connection.streams[stream_id] = queue
        writer = None
        try:
            response = await connection.call({"type": "subscribe", "stream_id": stream_id, "authorization": authorization})
            if response.get("status") != 200:
                return web.json_response(response.get("body", {}), status=response.get("status", 503))
            ws = web.WebSocketResponse(heartbeat=20, max_msg_size=4096)
            await ws.prepare(request)
            async def drain():
                while True:
                    event = await queue.get()
                    if event is None:
                        await ws.close(code=1008, message=b"Reconnect and synchronize")
                        return
                    raw = await asyncio.to_thread(json.dumps, event, ensure_ascii=False, separators=(",", ":"))
                    if len(raw.encode()) > MAX_RESPONSE:
                        await ws.close(code=1009, message=b"Resynchronize")
                        return
                    await asyncio.wait_for(ws.send_str(raw), 10)
            writer = asyncio.create_task(drain())
            async for frame in ws:
                if frame.type == aiohttp.WSMsgType.TEXT:
                    await ws.close(code=1008)
            return ws
        finally:
            if writer:
                writer.cancel()
                await asyncio.gather(writer, return_exceptions=True)
            connection.streams.pop(stream_id, None)
            with contextlib.suppress(web.HTTPException):
                await connection.send({"type": "unsubscribe", "stream_id": stream_id})


def app_for(relay: Relay):
    app = web.Application(client_max_size=MAX_UPLOAD)
    app.router.add_get("/tunnel/{host}", relay.tunnel)
    app.router.add_route("*", "/h/{host}/v1/{path:.*}", relay.phone)
    return app


def main():
    parser = argparse.ArgumentParser(description="Companion outbound relay. Use a TLS reverse proxy for public deployment.")
    parser.add_argument("--credentials", help="0600 JSON file mapping host ID to random host secret; otherwise COMPANION_RELAY_HOSTS environment JSON")
    parser.add_argument("--credentials-env", default="COMPANION_RELAY_HOSTS", help="Environment variable with host credential JSON")
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", default=19221, type=int)
    args = parser.parse_args()
    if args.credentials:
        credentials = Path(args.credentials)
        if credentials.stat().st_mode & 0o077:
            parser.error("Credential file must be readable only by its owner")
        hosts = json.loads(credentials.read_text())
    else:
        hosts = json.loads(os.environ[args.credentials_env])
    relay = Relay(hosts)
    web.run_app(app_for(relay), host=args.bind, port=args.port, access_log=None, print=None)


if __name__ == "__main__":
    main()
