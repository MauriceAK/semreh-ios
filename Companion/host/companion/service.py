from __future__ import annotations

import asyncio
import contextlib
import json
import re
import time
from collections import defaultdict, deque

import aiohttp
from aiohttp import web

from .domain import APIError, MAX_BODY, MAX_RESPONSE, digest, encoded, identifier, operation_id, preferences, text
from .delivery import Proactivity
from .attachments import Attachments, LIMITS, MAX_UPLOAD_BODY, attachment_ids, is_upload, prepare, prompt_with_attachments


class Hub:
    def __init__(self, store):
        self.store = store
        self.subscribers: dict[str, tuple[str, asyncio.Queue]] = {}

    def subscribe(self, key, device):
        if len(self.subscribers) >= 128:
            raise APIError("busy", "Too many connected devices.", 503)
        queue = asyncio.Queue(maxsize=64)
        self.subscribers[key] = device, queue
        return queue

    def unsubscribe(self, key):
        self.subscribers.pop(key, None)

    def revoke(self, device):
        for key, (owner, queue) in list(self.subscribers.items()):
            if owner == device:
                while not queue.empty():
                    queue.get_nowait()
                queue.put_nowait(None)
                del self.subscribers[key]

    async def publish(self, event):
        for key, (device, queue) in list(self.subscribers.items()):
            if not self.store.active(device) or queue.full():
                while not queue.empty():
                    queue.get_nowait()
                queue.put_nowait(None)
                del self.subscribers[key]
            else:
                queue.put_nowait(event)


class Service:
    def __init__(self, gateway, store, name="My Hermes", apns=None, scheduler=None, poll_interval=10):
        self.gateway, self.store, self.name = gateway, store, name
        self.hub = Hub(store)
        self.proactive = Proactivity(gateway, store, self.hub.publish, apns, poll_interval)
        self.scheduler = scheduler
        self.relay = None
        gateway.publish = self.hub.publish
        gateway.on_update = self.proactive.add_update
        self.pair_attempts = deque(maxlen=200)
        self.dispatch_locks = defaultdict(asyncio.Lock)
        self.attachments = Attachments(store)
        self.upload_slots = 0
        self.upload_ingress = 0
        gateway.project_message = self.attachments.project

    async def start(self, app=None):
        await self.gateway.start()
        await self.proactive.start()
        if self.scheduler:
            await self.scheduler.start()
        if self.relay:
            await self.relay.start()

    async def close(self, app=None):
        if self.relay:
            await self.relay.close()
        if self.scheduler:
            await self.scheduler.close()
        await self.proactive.close()
        await self.gateway.close()
        self.store.close()

    def auth(self, authorization, scope="read"):
        if not isinstance(authorization, str) or not authorization.startswith("Bearer ") or len(authorization) > 200:
            raise APIError("unauthorized", "Pair this device to continue.", 401)
        return self.store.authenticate(authorization[7:], scope)

    async def dispatch(self, method, path, body, authorization, query=None):
        query = query or {}
        if not isinstance(body, dict) or "profile" in body or "profile" in query:
            raise APIError("invalid_input", "The connected profile cannot be changed by a phone request.")
        upload = is_upload(method, path)
        serialized = await asyncio.to_thread(encoded, body) if upload else encoded(body)
        if len(serialized.encode()) > (MAX_UPLOAD_BODY if upload else MAX_BODY):
            raise APIError("payload_too_large", "This request is too large.", 413)
        if method == "POST" and path == "/v1/pair":
            now = time.monotonic()
            while self.pair_attempts and self.pair_attempts[0] < now - 60:
                self.pair_attempts.popleft()
            if len(self.pair_attempts) >= 30:
                raise APIError("rate_limited", "Too many pairing attempts. Try again in a minute.", 429)
            self.pair_attempts.append(now)
            code = text(body.get("code"), "pairing code", 100)
            name = text(body.get("device_name"), "device name", 100)
            result = self.store.pair(code, name)
            return {"version": 1, **result, "host": {"name": self.name, "profile": self.store.profile}}, 200
        device = self.auth(authorization)
        if method == "GET":
            return await self.read(path, query, device), 200
        if path == "/v1/device":
            if method == "DELETE":
                self.store.revoke(device["id"])
                self.hub.revoke(device["id"])
                async with self.dispatch_locks[device["id"]]:
                    pass
                return {"revoked": True}, 200
            if method == "PATCH":
                token = text(body.get("push_token"), "push token", 256)
                if not re.fullmatch(r"[0-9a-fA-F]{64,256}", token) or body.get("environment") not in {"sandbox", "production"}:
                    raise APIError("invalid_push", "Invalid Apple notification registration.")
                self.store.register_push(device["id"], token, body["environment"])
                return {"registered": True}, 200
        if path == "/v1/preferences" and method == "PUT":
            prefs = preferences(body)
            self.store.set_preferences(device["id"], prefs)
            return prefs, 200
        original_body = body
        attachment_ids(body)
        if body.get("kind") == "send" and isinstance(body.get("text"), str) and body["text"].startswith("/"):
            name, _, arg = body["text"][1:].partition(" ")
            body = {**body, "kind": "slash", "name": name, "arg": arg}
        scope = "jobs" if path.startswith("/v1/jobs") else "controls" if body.get("kind") in {"model", "reasoning", "slash"} else "chat"
        self.auth(authorization, scope)
        operation = operation_id(body.get("operation_id"))
        body = {**body, "operation_id": operation}
        signature = await asyncio.to_thread(lambda: digest(encoded({"method": method, "path": path, "body": original_body}))) if upload else digest(encoded({"method": method, "path": path, "body": original_body}))
        prior = self.store.begin(device["id"], operation, signature)
        if prior:
            return prior
        def authorize():
            self.auth(authorization, scope)
        try:
            interrupt = method == "POST" and re.fullmatch(r"/v1/sessions/[A-Za-z0-9_.:-]+/commands", path) and body.get("kind") == "interrupt"
            async with contextlib.nullcontext() if interrupt else self.dispatch_locks[device["id"]]:
                authorize()
                result = await self.mutate(method, path, body, authorize, device["id"])
            status = 200
        except APIError as error:
            result, status = {"error": {"code": error.code, "message": error.message}}, error.status
        except (ConnectionError, TimeoutError, aiohttp.ClientError):
            result, status = {"operation_id": operation, "status": "uncertain", "message": "The connection ended before Hermes confirmed this action. Review the conversation before trying a new action."}, 409
        self.store.finish(device["id"], operation, result, status)
        return result, status

    async def read(self, path, query, device):
        if path == "/v1/host":
            return {"version": 1, "name": self.name, "profile": self.store.profile, "connected": self.gateway.connected, "capabilities": {"chat": True, "controls": True, "proactivity": True, "attachments": True, "attachment_limits": LIMITS, "notifications": self.proactive.apns is not None, "relay": self.relay is not None, "scheduler": self.scheduler.status if self.scheduler else "external"}, "notice": self.proactive.problem}
        if path == "/v1/sessions":
            return await self.gateway.sessions()
        match = re.fullmatch(r"/v1/sessions/([A-Za-z0-9_.:-]+)/(?P<action>snapshot|history|controls)", path)
        if match:
            stored = identifier(match.group(1))
            action = match.group("action")
            if action == "history":
                return await self.gateway.history(stored, query.get("before"))
            if action == "snapshot":
                return await self.gateway.snapshot(stored)
            return await self.gateway.controls(stored, refresh=True)
        if path == "/v1/jobs":
            return await self.proactive.jobs()
        if path == "/v1/updates":
            return {"updates": self.store.updates()}
        match = re.fullmatch(r"/v1/updates/([A-Za-z0-9-]+)", path)
        if match:
            return await self.proactive.detail(identifier(match.group(1)))
        if path == "/v1/preferences":
            return self.store.get_preferences(device["id"])
        raise APIError("not_found", "Unknown Companion route.", 404)

    async def mutate(self, method, path, body, authorize, device):
        if method == "POST" and path == "/v1/sessions":
            title = text(body["title"], "conversation title", 200) if "title" in body else None
            return await self.gateway.create(title, authorize)
        match = re.fullmatch(r"/v1/sessions/([A-Za-z0-9_.:-]+)/commands", path)
        if match and method == "POST":
            stored = identifier(match.group(1))
            ids = attachment_ids(body)
            if not ids:
                tracked = body.get("kind") == "send" and self.attachments.track_plain(device, stored, body["operation_id"], text(body.get("text"), "message", 200000))
                try:
                    result = await self.gateway.command(stored, body, authorize)
                except APIError:
                    if tracked:
                        self.attachments.finish_plain(device, body["operation_id"], {"status": "rejected"})
                    raise
                except (ConnectionError, TimeoutError, aiohttp.ClientError):
                    if tracked:
                        self.attachments.finish_plain(device, body["operation_id"], {"status": "uncertain"})
                    raise
                if tracked:
                    self.attachments.finish_plain(device, body["operation_id"], result)
                return result
            tickets = self.attachments.resolve(device, stored, ids)
            value = text(body.get("text", ""), "message", 200000, empty=True)
            submitted = prompt_with_attachments(value, tickets)
            if len(submitted) > 200000:
                raise APIError("invalid_input", "Shorten this message to leave room for its attachment references.")
            self.attachments.claim(device, stored, body["operation_id"], value, submitted, tickets)
            try:
                result = await self.gateway.command(stored, {**body, "text": submitted}, authorize, queue_attachments=True)
            except APIError:
                self.attachments.sent(device, body["operation_id"], "rejected")
                raise
            except (ConnectionError, TimeoutError, aiohttp.ClientError):
                self.attachments.sent(device, body["operation_id"], "uncertain")
                raise
            state = "queued" if result.get("status") == "queued" else "consumed" if result.get("status") in {"accepted", "steered", "redirected"} else "rejected" if result.get("status") == "rejected" else "uncertain"
            self.attachments.sent(device, body["operation_id"], state, result.get("user_row_id"))
            return result
        match = re.fullmatch(r"/v1/sessions/([A-Za-z0-9_.:-]+)/attachments(?:/([a-f0-9-]{36}))?", path)
        if match:
            stored, key = identifier(match.group(1)), match.group(2)
            if method == "DELETE" and key:
                return self.attachments.remove(device, stored, key)
            if method == "POST" and not key:
                if self.upload_slots >= 2:
                    raise APIError("busy", "Two attachments are already uploading. Try again shortly.", 503)
                self.upload_slots += 1
                prepared = None
                try:
                    prepared = await asyncio.to_thread(prepare, body)
                    authorize()
                    self.attachments.reserve(device, stored, prepared)
                    result = await self.gateway.upload_attachment(stored, prepared, authorize)
                    authorize()
                    return self.attachments.uploaded(prepared, result)
                except APIError as error:
                    if prepared:
                        self.attachments.upload_failed(prepared, error.code in {"upstream_contract", "unauthorized"})
                    if error.code == "upstream_contract":
                        raise ConnectionError("Hermes may have staged a file without confirming its reference") from None
                    raise
                except (ConnectionError, TimeoutError, aiohttp.ClientError):
                    if prepared:
                        self.attachments.upload_failed(prepared, True)
                    raise
                finally:
                    self.upload_slots -= 1
        if method == "POST" and path == "/v1/jobs":
            return await self.proactive.create(body, authorize)
        match = re.fullmatch(r"/v1/jobs/([A-Za-z0-9_.:-]+)", path)
        if match:
            if method == "PATCH":
                return await self.proactive.change(identifier(match.group(1)), body.get("enabled"), authorize)
            if method == "DELETE":
                return await self.proactive.remove(identifier(match.group(1)), authorize)
        raise APIError("not_found", "Unknown Companion route.", 404)

    async def http(self, request):
        upload_reserved = False
        try:
            if request.path == "/v1/events" and request.method == "GET":
                return await self.stream(request)
            if request.query.get("token"):
                raise APIError("invalid_authorization", "Use the Authorization header, not a URL token.")
            upload = is_upload(request.method, request.path)
            limit = MAX_UPLOAD_BODY if upload else MAX_BODY
            if request.content_length is not None and request.content_length > limit:
                raise APIError("payload_too_large", "This request is too large.", 413)
            if upload:
                self.auth(request.headers.get("Authorization", ""), "chat")
                if self.upload_ingress >= 2:
                    raise APIError("busy", "Two attachments are already uploading. Try again shortly.", 503)
                self.upload_ingress += 1
                upload_reserved = True
            raw = bytearray()
            try:
                async with asyncio.timeout(30):
                    async for chunk in request.content.iter_chunked(65536):
                        raw.extend(chunk)
                        if len(raw) > limit:
                            raise APIError("payload_too_large", "This request is too large.", 413)
            except TimeoutError:
                raise APIError("request_timeout", "Uploading took too long. Check your connection and try again.", 408) from None
            body = await asyncio.to_thread(json.loads, raw) if raw and upload else json.loads(raw) if raw else {}
            result, status = await self.dispatch(request.method, request.path, body, request.headers.get("Authorization", ""), dict(request.query))
            raw = await asyncio.to_thread(encoded, result)
            if len(raw.encode()) > MAX_RESPONSE:
                raise APIError("payload_too_large", "This result exceeds the safe response size.", 413)
            return web.Response(text=raw, content_type="application/json", status=status, headers={"Cache-Control": "no-store"})
        except APIError as error:
            return web.json_response({"error": {"code": error.code, "message": error.message}}, status=error.status)
        except (json.JSONDecodeError, UnicodeError):
            return web.json_response({"error": {"code": "invalid_json", "message": "Send a JSON object."}}, status=400)
        except (aiohttp.ClientError, ConnectionError, TimeoutError):
            return web.json_response({"error": {"code": "offline", "message": "Hermes is unavailable. Reconnecting."}}, status=503)
        except Exception:
            return web.json_response({"error": {"code": "internal_error", "message": "Companion could not complete this request."}}, status=500)
        finally:
            if upload_reserved:
                self.upload_ingress -= 1

    async def stream(self, request):
        if request.query:
            raise APIError("invalid_query", "Event streams do not accept URL credentials.")
        device = self.auth(request.headers.get("Authorization", ""))
        key = "http:" + str(id(request))
        queue = self.hub.subscribe(key, device["id"])
        ws = web.WebSocketResponse(heartbeat=20, max_msg_size=4096)
        try:
            await ws.prepare(request)
            await ws.send_json({"type": "connection", "payload": {"state": "connected" if self.gateway.connected else "offline"}})
            async def drain():
                while True:
                    event = await queue.get()
                    if event is None or not self.store.active(device["id"]):
                        await ws.close(code=1008, message=b"Reconnect and synchronize")
                        return
                    await asyncio.wait_for(ws.send_str(await asyncio.to_thread(encoded, event)), 10)
            task = asyncio.create_task(drain())
            try:
                async for frame in ws:
                    if frame.type == aiohttp.WSMsgType.TEXT:
                        await ws.close(code=1008, message=b"Receive-only stream")
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
        finally:
            self.hub.unsubscribe(key)
        return ws


def app_for(service: Service, lifecycle=True):
    app = web.Application(client_max_size=MAX_UPLOAD_BODY)
    app.router.add_route("*", "/{path:.*}", service.http)
    if lifecycle:
        app.on_startup.append(service.start)
        app.on_cleanup.append(service.close)
    return app
