import asyncio
import base64
import copy
import time
import uuid

from aiohttp import web


class HermesFixture:
    classification = "controlled official HTTP and JSON-RPC contract fixture"

    def __init__(self):
        self.profile = "fixture-profile"
        self.admin_token = "controlled-upstream-admin-secret"
        self.calls = []
        self.ws = []
        self.seq = 0
        self.epoch = "fixture-epoch-1"
        self.runtimes = {"long-session": "runtime-long"}
        self.histories = {"long-session": [{"id": i, "role": "user" if i % 2 else "assistant", "content": f"Message {i}", "timestamp": time.time()} for i in range(1, 10001)]}
        self.models = {"long-session": "small-model"}
        self.reasoning = "medium"
        self.requests = []
        self.jobs = {}
        self.runs = {}
        self.outputs = {}
        self.submissions = 0
        self.answers = 0
        self.background = set()
        self.block_method = None
        self.blocked = asyncio.Event()
        self.release = asyncio.Event()
        self.inflight = None
        self.lazy_model_options = False
        self.files = {}
        self.drop_upload_ack = False
        self.drop_prompt_ack = False
        self.queue_prompt = False
        self.lazy_created_sessions = False
        self.unpersisted = set()
        self.app = web.Application()
        self.app.router.add_get("/api/ws", self.websocket)
        self.app.router.add_route("*", "/{path:.*}", self.rest)

    def stored(self, runtime):
        return next((s for s, r in self.runtimes.items() if r == runtime), runtime)

    def snapshot(self, stored):
        return {"session_id": self.runtimes[stored], "session_key": stored, "messages": [], "messages_omitted": True, "message_count": len(self.histories[stored]), "info": {"model": self.models.get(stored, "small-model"), "provider": "fixture-provider", "title": "Controlled conversation", "profile_name": self.profile}, "open_requests": copy.deepcopy(self.requests), "running": self.inflight is not None, "status": "working" if self.inflight else "idle", "inflight": self.inflight}

    async def event(self, kind, payload=None, runtime="runtime-long"):
        self.seq += 1
        for ws in list(self.ws):
            if not ws.closed:
                await ws.send_json({"jsonrpc": "2.0", "method": "event", "params": {"type": kind, "session_id": runtime, "payload": payload or {}, "seq": self.seq}})

    async def websocket(self, request):
        if request.query.get("token") != self.admin_token:
            raise web.HTTPUnauthorized()
        ws = web.WebSocketResponse(max_msg_size=8 * 1024 * 1024)
        await ws.prepare(request)
        self.ws.append(ws)
        await ws.send_json({"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {"skin": {}, "change_events": True, "replay_epoch": self.epoch}}})
        try:
            async for frame in ws:
                data = frame.json()
                method, params = data["method"], data["params"]
                self.calls.append((method, copy.deepcopy(params)))
                if method != "client.capabilities" and params.get("profile") != self.profile:
                    raise AssertionError("RPC escaped the selected profile")
                result = await self.rpc(method, params, ws)
                if result is not None and not ws.closed:
                    await ws.send_json({"jsonrpc": "2.0", "id": data["id"], "result": result})
        finally:
            self.ws.remove(ws)
        return ws

    async def rpc(self, method, params, ws):
        if method == self.block_method:
            self.blocked.set()
            await self.release.wait()
        stored = self.stored(params.get("session_id"))
        if method == "client.capabilities":
            return {"server_requests": ["approval", "clarify"]}
        if method == "session.list":
            return {"sessions": [{"id": key, "title": "Controlled conversation", "started_at": time.time()} for key in self.histories]}
        if method == "session.create":
            stored = "session-" + uuid.uuid4().hex
            self.runtimes[stored] = "runtime-" + uuid.uuid4().hex[:8]
            self.histories[stored], self.models[stored] = [], "small-model"
            if self.lazy_created_sessions:
                self.unpersisted.add(stored)
            return {**self.snapshot(stored), "stored_session_id": stored}
        if method == "session.title":
            self.unpersisted.discard(stored)
            return {"pending": False, "title": params["title"]}
        if method in {"session.activate", "session.resume"}:
            assert params.get("omit_messages") is True
            result = self.snapshot(stored)
            result["info"]["lazy"] = self.lazy_model_options
            return result
        if method == "session.events.since":
            return {"events": [], "latest_seq": self.seq, "truncated": True, "epoch": self.epoch, "open_requests": self.requests}
        if method == "model.options":
            return {"model": "small-model" if self.lazy_model_options else self.models.get(stored, "small-model"), "provider": "fixture-provider", "providers": [{"slug": "fixture-provider", "name": "Fixture", "authenticated": True, "models": ["small-model", "expensive-model"], "capabilities": {"small-model": {"reasoning": True}, "expensive-model": {"reasoning": True}}}]}
        if method == "config.get":
            if params["key"] == "profile":
                return {"home": "/controlled/profile"}
            assert params["key"] == "reasoning"
            return {"value": self.reasoning, "display": "show"}
        if method == "commands.catalog":
            return {"pairs": [["/model", "Change model"], ["/reasoning", "Reasoning"], ["/status", "Status"], ["/shell", "Unsafe route"]], "sub": {"/reasoning": ["none", "low", "medium", "high"]}}
        if method == "config.set":
            if params["key"] == "reasoning":
                self.reasoning = params["value"]
                return {"key": "reasoning", "value": self.reasoning}
            value = params["value"].split(" --provider ")[0]
            if " --provider " not in params["value"]:
                self.lazy_model_options = False
            if value == "expensive-model" and not params.get("confirm_expensive_model"):
                return {"key": "model", "confirm_required": True, "confirm_message": "This model costs more."}
            self.models[stored] = value
            return {"key": "model", "value": value, "scope": "session"}
        if method == "prompt.submit":
            self.submissions += 1
            if params["text"] == "DROP_ACK" or self.drop_prompt_ack:
                await ws.close()
                return None
            row = max([r["id"] for r in self.histories[stored]] or [0]) + 1
            prompt = params["text"]
            if any(ref in prompt for ref in self.files):
                prompt += "\n\n--- Attached Context ---\n\nControlled expanded attachment content"
            self.histories[stored].append({"id": row, "role": "user", "content": prompt})
            task = asyncio.create_task(self.complete(stored, row + 1, burst=params["text"] == "STREAM_BURST"))
            self.background.add(task)
            task.add_done_callback(self.background.discard)
            return {"status": "queued"} if self.queue_prompt else {"status": "streaming", "user_row_id": row}
        if method == "file.attach":
            assert set(params) == {"session_id", "profile", "name", "data_url"}
            ref = "@file:attachments/" + params["name"]
            self.files[ref] = base64.b64decode(params["data_url"].split(",", 1)[1])
            if self.drop_upload_ack:
                await ws.close()
                return None
            return {"attached": True, "name": params["name"], "ref_text": ref, "uploaded": True}
        if method == "request.answer":
            if not any(row["id"] == params["id"] for row in self.requests):
                return {"status": "expired"}
            assert params["result"] in ({"choice": "once"}, {"choice": "deny"}, {"answer": "Yes"})
            self.answers += 1
            self.requests = []
            return {"status": "ok"}
        if method == "session.interrupt":
            self.requests = []
            return {"status": "interrupted"}
        if method == "session.status":
            return {"output": "Controlled status"}
        raise AssertionError("Unexpected RPC " + method)

    async def complete(self, stored, row, burst=False):
        await asyncio.sleep(0.03)
        await self.event("message.start", runtime=self.runtimes[stored])
        chunks = ["word "] * 500 if burst else ["Controlled ", "answer"]
        for chunk in chunks:
            await self.event("message.delta", {"text": chunk}, self.runtimes[stored])
        answer = "".join(chunks)
        self.histories[stored].append({"id": row, "role": "assistant", "content": answer})
        await self.event("message.complete", {"text": answer, "status": "complete", "persisted_turn": {"final_assistant_row_id": row}}, self.runtimes[stored])

    async def rest(self, request):
        if request.headers.get("Authorization") != "Bearer " + self.admin_token:
            raise web.HTTPUnauthorized()
        assert request.query.get("profile") == self.profile, "REST escaped selected profile"
        self.calls.append((request.method + " " + request.path, dict(request.query)))
        parts = request.path.strip("/").split("/")
        if parts[:2] == ["api", "sessions"]:
            stored = parts[2]
            if stored not in self.histories or stored in self.unpersisted:
                raise web.HTTPNotFound()
            if len(parts) == 3:
                return web.json_response({"id": stored, "profile": self.profile, "message_count": len(self.histories[stored])})
            if parts[3] == "messages":
                rows = self.histories[stored]
                limit, offset = int(request.query["limit"]), int(request.query["offset"])
                end = max(0, len(rows) - offset)
                result = rows[max(0, end - limit):end]
                return web.json_response({"session_id": stored, "profile": self.profile, "messages": result, "pagination": {"returned": len(result)}})
        if request.path == "/api/cron/jobs":
            if request.method == "GET":
                return web.json_response(list(self.jobs.values()))
            body = await request.json()
            key = uuid.uuid4().hex[:12]
            row = {"id": key, "name": body["name"], "prompt": body["prompt"], "schedule_display": body["schedule"], "enabled": True, "state": "scheduled"}
            self.jobs[key], self.runs[key] = row, []
            return web.json_response(row)
        if parts[:3] == ["api", "cron", "jobs"]:
            job = parts[3]
            if len(parts) == 5 and parts[4] == "runs":
                return web.json_response({"runs": self.runs.get(job, [])})
            if len(parts) == 5 and parts[4] in {"pause", "resume"}:
                self.jobs[job]["enabled"] = parts[4] == "resume"
                return web.json_response(self.jobs[job])
            if request.method == "DELETE":
                del self.jobs[job]
                return web.json_response({"deleted": True})
        if request.path == "/api/files/read":
            output = self.outputs.get(request.query["path"])
            if output is None:
                raise web.HTTPNotFound()
            return web.json_response({"data_url": output})
        raise web.HTTPNotFound()
