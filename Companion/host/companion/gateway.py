from __future__ import annotations

import asyncio
import base64
import contextlib
import hashlib
import hmac
import json
import time
import uuid
from dataclasses import dataclass, field
from urllib.parse import quote, urlsplit

import aiohttp

from .domain import APIError, MAX_RESPONSE, PAGE_SIZE, SAFE_SLASH, encoded, identifier, message, text, utc


class UpstreamError(APIError):
    def __init__(self, code=None):
        super().__init__("hermes_rejected", "Hermes rejected this operation. Refresh the session and check its configuration.", 502)
        self.upstream_code = code


@dataclass
class Live:
    stored: str
    runtime: str
    title: str = "New conversation"
    info: dict = field(default_factory=dict)
    state: str = "idle"
    requests: list = field(default_factory=list)
    generation: str = ""
    seq: int = 0
    segment: str = field(default_factory=lambda: str(uuid.uuid4()))
    controls: dict | None = None
    controls_at: float = 0
    pending_model: str | None = None
    pending_provider: str | None = None
    status_text: str = ""


@dataclass
class StreamBatch:
    segment: str
    parts: list[str] = field(default_factory=list)
    characters: int = 0


class Gateway:
    def __init__(self, url: str, token: str, profile: str, cursor_key: str):
        parsed = urlsplit(url)
        if parsed.scheme not in {"http", "https"} or parsed.hostname not in {"localhost", "127.0.0.1", "::1"} or parsed.query or parsed.fragment or parsed.username:
            raise ValueError("The official Hermes gateway must be a loopback HTTP(S) URL")
        self.url, self.token, self.profile = url.rstrip("/"), token, profile
        self.cursor_key = cursor_key.encode()
        self.http: aiohttp.ClientSession | None = None
        self.ws = None
        self.pending: dict[str, asyncio.Future] = {}
        self.ready = asyncio.Event()
        self.hello = asyncio.Event()
        self.epoch = ""
        self.generation = ""
        self.live: dict[str, Live] = {}
        self.session_lock = asyncio.Lock()
        self.events = asyncio.Queue(maxsize=1024)
        self.deltas: dict[str, StreamBatch] = {}
        self.tasks = []
        self.closing = False
        self.publish = self._ignore
        self.on_update = self._ignore
        self.project_message = lambda session, row: row

    async def _ignore(self, *args):
        pass

    @property
    def connected(self):
        return self.ready.is_set()

    async def start(self):
        self.http = aiohttp.ClientSession(headers={"Authorization": "Bearer " + self.token}, timeout=aiohttp.ClientTimeout(total=35))
        self.tasks = [asyncio.create_task(self._connections()), asyncio.create_task(self._events()), asyncio.create_task(self._stream_updates())]

    async def close(self):
        self.closing = True
        for task in self.tasks:
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)
        if self.http:
            await self.http.close()

    async def _connections(self):
        delay = 0.25
        while not self.closing:
            reader = None
            try:
                previous_epoch = self.epoch
                self.hello.clear()
                self.generation = str(uuid.uuid4())
                async with self.http.ws_connect(self.url + "/api/ws", params={"token": self.token}, heartbeat=20, max_msg_size=MAX_RESPONSE) as ws:
                    self.ws = ws
                    reader = asyncio.create_task(self._reader(ws))
                    await asyncio.wait_for(self.hello.wait(), 15)
                    if self.epoch != previous_epoch:
                        for live in self.live.values():
                            live.seq = 0
                    await self.rpc("client.capabilities", {"server_requests": True}, negotiate=True)
                    self.ready.set()
                    delay = 0.25
                    await self.publish({"type": "connection", "payload": {"state": "connected"}})
                    for stored in list(self.live):
                        with contextlib.suppress(APIError, TimeoutError):
                            live = await self.attach(stored, force=True)
                            replay = await self.rpc("session.events.since", {"session_id": live.runtime, "last_seen": live.seq})
                            live.seq = replay.get("latest_seq", 0)
                            await self.emit_snapshot(stored)
                    await reader
            except asyncio.CancelledError:
                raise
            except (aiohttp.ClientError, APIError, TimeoutError, OSError, ValueError):
                pass
            finally:
                self.ready.clear()
                self.deltas.clear()
                self.ws = None
                if reader:
                    reader.cancel()
                    await asyncio.gather(reader, return_exceptions=True)
                for future in self.pending.values():
                    if not future.done():
                        future.set_exception(ConnectionError("Hermes connection closed"))
                self.pending.clear()
                for live in self.live.values():
                    live.requests = []
                    live.state = "offline"
                await self.publish({"type": "connection", "payload": {"state": "offline", "message": "Reconnecting to Hermes."}})
            await asyncio.sleep(delay)
            delay = min(delay * 2, 15)

    async def _reader(self, ws):
        async for frame in ws:
            if frame.type != aiohttp.WSMsgType.TEXT:
                if frame.type in {aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR}:
                    break
                continue
            data = json.loads(frame.data)
            if "id" in data and "method" not in data:
                future = self.pending.get(str(data["id"]))
                if future and not future.done():
                    if "error" in data:
                        future.set_exception(UpstreamError(data["error"].get("code")))
                    else:
                        future.set_result(data.get("result", {}))
                continue
            if data.get("method") == "event":
                event = data.get("params", {})
                if event.get("type") == "gateway.ready":
                    self.epoch = event.get("payload", {}).get("replay_epoch", "")
                    self.hello.set()
                else:
                    try:
                        self.events.put_nowait({**event, "connection_generation": self.generation})
                    except asyncio.QueueFull:
                        await ws.close(code=1013, message=b"Resynchronize")
                        break
            elif "id" in data and "method" in data:
                try:
                    self.events.put_nowait({"type": "server.request", "session_id": data.get("params", {}).get("session_id"), "payload": data, "connection_generation": self.generation})
                except asyncio.QueueFull:
                    await ws.close(code=1013, message=b"Resynchronize")
                    break

    async def rpc(self, method: str, params: dict, negotiate: bool = False, authorize=None):
        if not negotiate:
            try:
                await asyncio.wait_for(self.ready.wait(), 8)
            except TimeoutError:
                raise APIError("offline", "Hermes is reconnecting. Try again when it is online.", 503) from None
            params = {**params, "profile": self.profile}
        if self.ws is None or self.ws.closed:
            raise ConnectionError("Hermes disconnected")
        if len(self.pending) >= 64:
            raise APIError("busy", "Hermes has too many pending requests. Try again shortly.", 503)
        key = str(uuid.uuid4())
        future = asyncio.get_running_loop().create_future()
        self.pending[key] = future
        try:
            payload = {"jsonrpc": "2.0", "id": key, "method": method, "params": params}
            raw = await asyncio.to_thread(encoded, payload) if method == "file.attach" else encoded(payload)
            if authorize:
                authorize()
            await self.ws.send_str(raw)
            return await asyncio.wait_for(future, 30)
        finally:
            self.pending.pop(key, None)

    async def rest(self, method: str, route: str, body=None, authorize=None, **query):
        query["profile"] = self.profile
        if authorize:
            authorize()
        async with self.http.request(method, self.url + route, params=query, json=body, allow_redirects=False) as response:
            raw = bytearray()
            async for chunk in response.content.iter_chunked(65536):
                raw.extend(chunk)
                if len(raw) > MAX_RESPONSE:
                    raise APIError("payload_too_large", "This Hermes result exceeds the safe page size. Narrow the request on the host.", 413)
            if response.status == 404:
                raise APIError("not_found", "That item is not available in the connected Hermes profile.", 404)
            if response.status >= 300:
                if method != "GET" and response.status >= 500:
                    raise ConnectionError("Hermes could not confirm the mutation outcome")
                raise UpstreamError(response.status)
            return await asyncio.to_thread(json.loads, raw) if len(raw) > 256 * 1024 else json.loads(raw)

    def session(self, live: Live) -> dict:
        return {"id": live.stored, "title": live.title or "New conversation", "updated_at": utc(), "profile": self.profile}

    async def sessions(self):
        result = await self.rpc("session.list", {"limit": 200})
        rows = [{"id": row["id"], "title": row.get("title") or row.get("preview") or "New conversation", "updated_at": utc(row.get("started_at") or 0), "profile": self.profile} for row in result["sessions"]]
        ids = {row["id"] for row in rows}
        rows[:0] = [self.session(live) for live in self.live.values() if live.stored not in ids]
        return {"sessions": rows[:200]}

    def reserve_live(self):
        if len(self.live) >= 128:
            idle = next((key for key, value in self.live.items() if value.state == "idle"), None)
            if idle is None:
                raise APIError("busy", "Close an active conversation before opening another.", 503)
            del self.live[idle]

    async def create(self, title: str | None, authorize=None):
        async with self.session_lock:
            self.reserve_live()
            result = await self.rpc("session.create", {"title": title or "New conversation", "source": "companion", "close_on_disconnect": False}, authorize=authorize)
            stored = result["stored_session_id"]
            live = Live(stored=stored, runtime=result["session_id"], title=title or "New conversation")
            self.live[stored] = live
            self._apply(live, result)
            return self.session(live)

    async def attach(self, stored: str, force=False) -> Live:
        async with self.session_lock:
            return await self._attach(stored, force)

    async def _attach(self, stored: str, force=False) -> Live:
        identifier(stored)
        live = self.live.get(stored)
        if live and live.generation == self.generation and not force:
            return live
        if live is None:
            self.reserve_live()
            await self.rest("GET", "/api/sessions/" + quote(stored, safe=""))
        result = await self.rpc("session.resume", {"session_id": stored, "lazy": True, "omit_messages": True, "defer_history": True, "close_on_disconnect": False})
        live = live or Live(stored=stored, runtime=result["session_id"])
        self.live[stored] = live
        self._apply(live, result)
        return live

    def _apply(self, live: Live, result: dict):
        live.runtime = result["session_id"]
        live.info = result.get("info", live.info)
        live.title = live.info.get("title") or live.title
        live.generation = self.generation
        live.requests = result.get("open_requests") or []
        if result.get("pending_approval") and not any(r.get("method") == "approval" for r in live.requests):
            pending = result["pending_approval"]
            live.requests.append({"id": "approval:" + str(pending["request_id"]), "method": "approval.pending", "params": pending})
        live.state = "waiting" if live.requests else "working" if result.get("running") or live.info.get("running") or result.get("status") in {"working", "streaming", "starting"} else "idle"
        live.controls_at = 0

    def requests(self, live: Live):
        rows = []
        for entry in live.requests:
            kind, params = entry.get("method"), entry.get("params", {})
            if kind in {"approval", "approval.pending"}:
                choices = [{"id": v, "label": {"once": "Allow once", "session": "Allow this session", "always": "Always allow", "deny": "Deny"}.get(v, v)} for v in params.get("choices", ["once", "deny"])]
                rows.append({"id": entry["id"], "generation": self.generation, "kind": "approval", "title": "Hermes needs approval", "description": params.get("description") or params.get("command", "Approve this action?"), "choices": choices})
            elif kind == "clarify" and not params.get("questions"):
                rows.append({"id": entry["id"], "generation": self.generation, "kind": "clarify", "title": params.get("question") or "Hermes has a question", "description": "", "allows_text": True, "choices": [{"id": v, "label": v} for v in params.get("choices") or []]})
            else:
                rows.append({"id": entry["id"], "generation": self.generation, "kind": "host_action", "title": "Continue on your Hermes host", "description": "This request requires a host interface. It remains pending in Hermes.", "choices": []})
        return rows

    async def controls(self, stored: str, refresh=False):
        live = await self.attach(stored)
        if live.controls and not refresh and time.monotonic() - live.controls_at < 10:
            return live.controls
        state = await self.rpc("session.activate", {"session_id": live.runtime, "omit_messages": True})
        self._apply(live, state)
        options, reasoning, catalog = await asyncio.gather(
            self.rpc("model.options", {"session_id": live.runtime}),
            self.rpc("config.get", {"session_id": live.runtime, "key": "reasoning"}),
            self.rpc("commands.catalog", {"session_id": live.runtime}))
        models = []
        for provider in options.get("providers", []):
            for model in provider.get("models", []):
                if isinstance(model, str):
                    models.append({"id": model, "provider": provider["slug"], "label": model, "reasoning": bool(provider.get("capabilities", {}).get(model, {}).get("reasoning", False))})
        current_model = live.info.get("model") or options.get("model", "")
        current_provider = live.info.get("provider") or options.get("provider", "")
        if live.pending_model and options.get("model") == live.pending_model and options.get("provider") == live.pending_provider and not live.info.get("lazy"):
            live.pending_model = None
            live.pending_provider = None
        if live.pending_model:
            current_model = options.get("model") or current_model
            current_provider = options.get("provider") or current_provider
        current = next((v for v in models if v["id"] == current_model and v["provider"] == current_provider), None)
        levels = catalog.get("sub", {}).get("/reasoning", catalog.get("sub", {}).get("reasoning", []))
        levels = [v for v in levels if v in {"none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}]
        if not current or not current["reasoning"]:
            levels = []
        pairs = catalog.get("pairs", [])
        commands = [{"name": pair[0].lstrip("/"), "description": pair[1]} for pair in pairs if len(pair) >= 2 and pair[0].lstrip("/") in SAFE_SLASH]
        live.controls = {"model": current_model, "provider": current_provider, "pending_model": live.pending_model, "reasoning": reasoning.get("value", ""), "reasoning_levels": levels, "models": models, "commands": commands}
        live.controls_at = time.monotonic()
        return live.controls

    def _cursor(self, stored, anchor, offset):
        raw = encoded({"session": stored, "anchor": anchor, "offset": offset}).encode()
        return base64.urlsafe_b64encode(raw + hmac.digest(self.cursor_key, raw, "sha256")).decode().rstrip("=")

    def _decode_cursor(self, value: str, stored: str):
        try:
            raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
            data, signature = raw[:-32], raw[-32:]
            if not hmac.compare_digest(signature, hmac.digest(self.cursor_key, data, "sha256")):
                raise ValueError()
            result = json.loads(data)
            if result["session"] != stored or type(result["offset"]) is not int or not 0 <= result["offset"] <= 10000000:
                raise ValueError()
            return result
        except (ValueError, TypeError, KeyError):
            raise APIError("invalid_cursor", "This history cursor is invalid. Refresh the conversation.") from None

    async def history(self, stored: str, before: str | None = None):
        identifier(stored)
        def bounded(rows):
            size, count = 0, 0
            for row in reversed(rows[-PAGE_SIZE:]):
                row_size = len(encoded(row).encode())
                if size + row_size > MAX_RESPONSE - 65536:
                    break
                size += row_size
                count += 1
            if rows and not count:
                raise APIError("payload_too_large", "This individual Hermes message exceeds the safe response size.", 413)
            return rows[-count:] if count else [], len(rows) - count

        async def page(offset):
            limit = PAGE_SIZE
            while True:
                try:
                    result = await self.rest("GET", f"/api/sessions/{quote(stored, safe='')}/messages", limit=limit, order="latest", offset=offset)
                    break
                except APIError as error:
                    if error.status == 404 and stored in self.live:
                        return [], True
                    if error.code == "payload_too_large" and limit > 1:
                        limit = max(1, limit // 2)
                        continue
                    raise
            return [self.project_message(stored, message(row)) for row in result["messages"]], len(result["messages"]) < limit
        if before is None:
            rows, ended = await page(0)
            distance = len(rows)
            rows, trimmed = await asyncio.to_thread(bounded, rows)
            distance -= trimmed
            has_more = not ended or trimmed > 0
        else:
            cursor = self._decode_cursor(text(before, "history cursor", 1200), stored)
            offset = max(0, cursor["offset"] - PAGE_SIZE)
            rows, found, ended, distance = [], False, False, offset
            for _ in range(32):
                batch, ended = await page(offset)
                if not found:
                    at = next((i for i, row in enumerate(batch) if row["id"] == cursor["anchor"]), None)
                    if at is not None:
                        found = True
                        rows = batch[:at]
                        distance = offset + len(batch)
                else:
                    rows = batch + rows
                    distance = offset + len(batch)
                if found:
                    limited, trimmed = await asyncio.to_thread(bounded, rows)
                    if len(rows) >= PAGE_SIZE or ended or trimmed:
                        distance -= trimmed
                        rows = limited
                        break
                if ended:
                    break
                offset += len(batch)
            else:
                raise APIError("history_changed", "History changed while paging. Refresh this conversation.", 409)
            if not found:
                raise APIError("history_changed", "The history anchor changed in Hermes. Refresh this conversation.", 409)
            has_more = not ended or len(rows) == PAGE_SIZE or trimmed > 0
        return {"messages": rows, "before": self._cursor(stored, rows[0]["id"], distance) if rows and has_more else None, "has_more": has_more}

    async def upload_attachment(self, stored, prepared, authorize):
        live = await self.attach(stored)
        route = "/api/sessions/" + quote(stored, safe="")
        try:
            await self.rest("GET", route)
        except APIError as error:
            if error.status != 404:
                raise
            result = await self.rpc("session.title", {"session_id": live.runtime, "title": live.title or "New conversation"}, authorize=authorize)
            if result.get("pending") is not False:
                raise APIError("attachment_session_unavailable", "Hermes could not save this conversation. Keep the files selected and try again.", 503)
            await self.rest("GET", route)
        return await self.rpc("file.attach", {"session_id": live.runtime, "name": prepared.gateway_name,
                              "data_url": "data:" + prepared.media_type + ";base64," + prepared.content_base64}, authorize=authorize)

    async def snapshot(self, stored: str):
        live = await self.attach(stored)
        result = await self.rpc("session.activate", {"session_id": live.runtime, "omit_messages": True})
        self._apply(live, result)
        page, controls = await asyncio.gather(self.history(stored), self.controls(stored))
        inflight = result.get("inflight") or {}
        if inflight.get("assistant") and live.state in {"working", "waiting"}:
            if len(page["messages"]) == PAGE_SIZE:
                page["messages"].pop(0)
                page["before"] = self._cursor(stored, page["messages"][0]["id"], PAGE_SIZE - 1)
                page["has_more"] = True
            page["messages"].append({"id": live.segment, "role": "assistant", "text": inflight["assistant"], "provisional": True})
        return {"session": self.session(live), "page": page, "state": live.state, "requests": self.requests(live), "controls": controls, "status_text": live.status_text}

    async def emit_snapshot(self, stored):
        snapshot = await self.snapshot(stored)
        await self.publish({"type": "snapshot", "session_id": stored, "payload": snapshot})
        return snapshot

    async def flush_deltas(self, stored):
        batch = self.deltas.pop(stored, None)
        if batch:
            await self.publish({"type": "delta", "session_id": stored, "payload": {"id": batch.segment, "text": "".join(batch.parts), "replace": False}})

    async def _stream_updates(self):
        while True:
            await asyncio.sleep(0.04)
            for stored in list(self.deltas):
                await self.flush_deltas(stored)

    async def command(self, stored: str, body: dict, authorize=None, queue_attachments=False):
        live = await self.attach(stored)
        kind = body.get("kind")
        receipt = {"operation_id": body["operation_id"], "status": "accepted"}
        if kind == "send":
            value = text(body.get("text"), "message", 200000)
            if value.startswith("/"):
                name, _, arg = value[1:].partition(" ")
                return await self.command(stored, {**body, "kind": "slash", "name": name, "arg": arg}, authorize)
            params = {"session_id": live.runtime, "text": value}
            if queue_attachments:
                params["queued"] = True
            result = await self.rpc("prompt.submit", params, authorize=authorize)
            receipt["status"] = {"streaming": "accepted"}.get(result.get("status"), result.get("status", "accepted"))
            if result.get("user_row_id"):
                receipt["user_row_id"] = str(result["user_row_id"])
        elif kind == "interrupt":
            await self.rpc("session.interrupt", {"session_id": live.runtime}, authorize=authorize)
        elif kind == "model":
            controls = await self.controls(stored, refresh=True)
            value = text(body.get("value"), "model", 200)
            provider = text(body.get("provider") or controls["provider"], "provider", 100)
            if not any(row["id"] == value and row["provider"] == provider for row in controls["models"]):
                raise APIError("unsupported_model", "Choose a model available through your Hermes provider.")
            if any(char.isspace() for char in value + provider) or "--" in value + provider:
                raise APIError("invalid_model", "Invalid model selection.")
            selection = value if provider == controls["provider"] else value + " --provider " + provider
            result = await self.rpc("config.set", {"session_id": live.runtime, "key": "model", "value": selection, "confirm_expensive_model": body.get("confirmed") is True}, authorize=authorize)
            if result.get("confirm_required"):
                receipt.update(status="rejected", message="Hermes requires confirmation for this model.", confirmation={"kind": "model", "value": value, "provider": provider, "message": result.get("confirm_message") or "Use this model? It may cost more."})
            else:
                live.pending_model, live.pending_provider = value, provider
                if result.get("deferred"):
                    receipt["message"] = "Hermes will switch models when the next turn starts."
            actual = await self.controls(stored, refresh=True)
            if actual["pending_model"] and not result.get("confirm_required") and not receipt.get("message"):
                receipt["message"] = "Model selected in Hermes. Its effective route will appear when the conversation starts."
            await self.publish({"type": "controls", "session_id": stored, "payload": actual})
        elif kind == "reasoning":
            controls = await self.controls(stored, refresh=True)
            value = text(body.get("value"), "reasoning", 30)
            if value not in controls["reasoning_levels"]:
                raise APIError("unsupported_reasoning", "This model does not advertise that reasoning level.")
            await self.rpc("config.set", {"session_id": live.runtime, "key": "reasoning", "value": value, "scope": "session"}, authorize=authorize)
            await self.publish({"type": "controls", "session_id": stored, "payload": await self.controls(stored, refresh=True)})
        elif kind == "answer":
            if body.get("generation") != self.generation:
                raise APIError("stale_request", "This request belongs to an earlier connection. Refresh it.", 409)
            result = await self.rpc("session.activate", {"session_id": live.runtime, "omit_messages": True})
            def authorize_answer():
                if authorize:
                    authorize()
                if body.get("generation") != self.generation:
                    raise APIError("stale_request", "This request belongs to an earlier connection. Refresh it.", 409)
            authorize_answer()
            self._apply(live, result)
            request = next((row for row in live.requests if row["id"] == body.get("request_id")), None)
            if not request:
                raise APIError("stale_request", "This request was already resolved or canceled.", 409)
            answer = text(body.get("answer"), "answer", 8192, empty=True)
            params = request.get("params", {})
            if request["method"] in {"approval", "approval.pending"}:
                if answer not in params.get("choices", ["once", "deny"]):
                    raise APIError("invalid_answer", "Choose one of the offered approval options.")
                if request["method"] == "approval.pending":
                    result = await self.rpc("approval.respond", {"session_id": live.runtime, "request_id": params["request_id"], "choice": answer}, authorize=authorize_answer)
                    if not result.get("resolved"):
                        raise APIError("stale_request", "This approval is no longer pending.", 409)
                else:
                    result = await self.rpc("request.answer", {"id": request["id"], "result": {"choice": answer}}, authorize=authorize_answer)
            elif request["method"] == "clarify" and not params.get("questions"):
                result = await self.rpc("request.answer", {"id": request["id"], "result": {"answer": answer}}, authorize=authorize_answer)
            else:
                raise APIError("host_action", "Resolve this request on your Hermes host.", 409)
            if result.get("status") == "expired":
                raise APIError("stale_request", "This request expired before Hermes accepted the answer.", 409)
            await self.emit_snapshot(stored)
        elif kind == "slash":
            name = text(body.get("name"), "command", 40).lstrip("/")
            arg = text(body.get("arg", ""), "command argument", 2000, empty=True)
            if name not in SAFE_SLASH:
                raise APIError("unsupported_command", "This command needs the Hermes host interface. It was not sent to the model.")
            if name in {"model", "reasoning"} and arg:
                return await self.command(stored, {**body, "kind": name, "value": arg}, authorize)
            if name == "stop":
                return await self.command(stored, {**body, "kind": "interrupt"}, authorize)
            if name in {"model", "reasoning", "help"}:
                controls = await self.controls(stored, refresh=True)
                receipt["message"] = f"Model: {controls['model']}\nProvider: {controls['provider']}\nReasoning: {controls['reasoning']}\nUse conversation controls to choose a model or reasoning level."
            else:
                method = {"status": "session.status", "usage": "session.usage", "context": "session.context_breakdown"}[name]
                result = await self.rpc(method, {"session_id": live.runtime})
                receipt["message"] = result.get("output") or encoded(result)
        else:
            raise APIError("invalid_command", "Unknown Companion command.")
        await self.publish({"type": "receipt", "session_id": stored, "payload": receipt})
        return receipt

    async def _events(self):
        while True:
            event = await self.events.get()
            try:
                if event.get("connection_generation") != self.generation:
                    continue
                live = next((value for value in self.live.values() if value.runtime == event.get("session_id")), None)
                if not live:
                    continue
                kind, payload = event.get("type"), event.get("payload") or {}
                seq = event.get("seq")
                if seq:
                    if seq <= live.seq:
                        continue
                    live.seq = seq
                if kind == "message.start":
                    await self.flush_deltas(live.stored)
                    live.state, live.segment = "working", str(uuid.uuid4())
                    await self.publish({"type": "connection", "session_id": live.stored, "payload": {"state": "working"}})
                elif kind == "message.delta":
                    batch = self.deltas.setdefault(live.stored, StreamBatch(live.segment))
                    delta = payload.get("text", "")
                    batch.parts.append(delta)
                    batch.characters += len(delta)
                    if batch.characters >= 65536:
                        await self.flush_deltas(live.stored)
                        await asyncio.sleep(0)
                elif kind == "message.interim":
                    await self.flush_deltas(live.stored)
                    live.segment = str(uuid.uuid4())
                    await self.emit_snapshot(live.stored)
                elif kind == "message.complete":
                    await self.flush_deltas(live.stored)
                    live.state = "failed" if payload.get("status") == "error" else "idle"
                    snapshot = await self.emit_snapshot(live.stored)
                    row_id = (payload.get("persisted_turn") or {}).get("final_assistant_row_id")
                    if not row_id:
                        row_id = next((row["id"] for row in reversed(snapshot["page"]["messages"]) if row["role"] == "assistant" and not row["provisional"] and row["text"] == payload.get("text")), None)
                    source = {"session_id": live.stored, "row_id": str(row_id) if row_id else None}
                    await self.on_update("turn:" + self.epoch + ":" + live.runtime + ":" + str(live.seq), {"kind": "error" if payload.get("status") == "error" else "result", "title": "Hermes finished" if payload.get("status") != "error" else "Hermes needs attention", "summary": str(payload.get("text") or "Open the conversation for details.")[:240], "session_id": live.stored}, source)
                elif kind == "server.request":
                    live.requests = [row for row in live.requests if row["id"] != payload["id"]] + [payload]
                    live.state = "waiting"
                    await self.publish({"type": "requests", "session_id": live.stored, "payload": {"requests": self.requests(live)}})
                    await self.on_update("request:" + self.generation + ":" + payload["id"], {"kind": "needs_you", "title": "Hermes needs you", "summary": "Open the conversation to review a pending request.", "session_id": live.stored}, {"session_id": live.stored, "request_id": payload["id"], "generation": self.generation})
                elif kind == "request.cancel":
                    live.requests = [row for row in live.requests if row["id"] != payload.get("id")]
                    await self.publish({"type": "requests", "session_id": live.stored, "payload": {"requests": self.requests(live)}})
                elif kind == "session.info":
                    live.info.update(payload)
                    live.controls_at = 0
                    await self.publish({"type": "controls", "session_id": live.stored, "payload": await self.controls(live.stored, refresh=True)})
                elif kind in {"status.update", "tool.start", "tool.complete", "error"}:
                    live.status_text = str(payload.get("text") or payload.get("message") or payload.get("name") or "Working")[:300]
                    await self.publish({"type": "connection", "session_id": live.stored, "payload": {"state": "failed" if kind == "error" else live.state, "message": live.status_text}})
            except (APIError, ConnectionError, TimeoutError, aiohttp.ClientError, KeyError, ValueError):
                await self.publish({"type": "connection", "payload": {"state": "synchronizing", "message": "Refreshing Hermes state."}})
