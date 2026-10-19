from __future__ import annotations

import asyncio
import base64
import contextlib
import json
import os
import re
import time
from pathlib import Path
from urllib.parse import quote

import aiohttp
import httpx
import jwt

from .domain import APIError, digest, identifier, is_quiet, silent_result, text


class APNs:
    def __init__(self, key_path: str, key_id: str, team_id: str, topic: str):
        self.key = Path(key_path).read_text()
        self.key_id, self.team_id, self.topic = key_id, team_id, topic
        jwt.encode({"iss": team_id, "iat": int(time.time())}, self.key, algorithm="ES256", headers={"kid": key_id})
        self.client = httpx.AsyncClient(http2=True, timeout=15)
        self.jwt, self.jwt_at = "", 0

    async def close(self):
        await self.client.aclose()

    async def send(self, device: dict, update: dict) -> str:
        now = int(time.time())
        if now - self.jwt_at > 2400:
            self.jwt = jwt.encode({"iss": self.team_id, "iat": now}, self.key, algorithm="ES256", headers={"kid": self.key_id})
            self.jwt_at = now
        server = "api.sandbox.push.apple.com" if device["environment"] == "sandbox" else "api.push.apple.com"
        response = await self.client.post(f"https://{server}/3/device/{device['push_token']}", headers={
            "authorization": "bearer " + self.jwt, "apns-topic": self.topic, "apns-push-type": "alert",
            "apns-priority": "10", "apns-collapse-id": update["id"], "apns-expiration": str(now + 86400),
        }, json={"aps": {"alert": {"title": "Hermes", "body": "Your agent has an update. Open Companion to review it."}, "sound": "default"}, "update_id": update["id"], "session_id": update.get("session_id")})
        if response.status_code == 200:
            return "sent"
        try:
            reason = response.json().get("reason")
        except (ValueError, AttributeError):
            reason = None
        if response.status_code == 410 or (response.status_code == 400 and reason == "BadDeviceToken"):
            return "invalid_token"
        if response.status_code in {429, 500, 503}:
            return "retry"
        return "configuration_error"


class Proactivity:
    def __init__(self, gateway, store, publish, apns=None, poll_interval=10):
        self.gateway, self.store, self.publish, self.apns = gateway, store, publish, apns
        self.poll_interval = poll_interval
        self.tasks = []
        self.poll_problem = None
        self.worker_failure = None
        with store.db:
            store.db.execute("INSERT OR IGNORE INTO metadata VALUES('observations_since',?)", (str(time.time()),))
        self.since = float(store.db.execute("SELECT value FROM metadata WHERE key='observations_since'").fetchone()[0])

    async def start(self):
        self.tasks = [asyncio.create_task(self._poll()), asyncio.create_task(self._deliver())]
        for task in self.tasks:
            task.add_done_callback(self.worker_finished)

    @property
    def problem(self):
        return self.worker_failure or self.poll_problem

    def worker_finished(self, task):
        if not task.cancelled() and task.exception() is not None:
            self.worker_failure = "A background delivery worker stopped. Restart Companion and check for a compatible Hermes version."

    async def close(self):
        for task in self.tasks:
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)
        if self.apns:
            await self.apns.close()

    async def add_update(self, event_key: str, payload: dict, source: dict):
        update = self.store.add_update(event_key, payload, source)
        if update:
            await self.publish({"type": "update", "session_id": update.get("session_id"), "payload": update})

    def job(self, row):
        link = self.store.job_link(row["id"])
        result = {"id": row["id"], "name": row.get("name") or "Follow-up", "instruction": row.get("prompt") or "", "schedule": row.get("schedule_display") or str(row.get("schedule", "")), "enabled": bool(row.get("enabled")) and row.get("state") != "paused", "notify": link["notify"], "session_id": link["session_id"], "next_run_at": row.get("next_run_at"), "last_status": row.get("last_status")}
        return result

    async def jobs(self):
        rows = await self.gateway.rest("GET", "/api/cron/jobs")
        if not isinstance(rows, list):
            raise APIError("upstream_contract", "Hermes returned an unsupported schedule response.", 502)
        if len(rows) > 500:
            raise APIError("too_many_jobs", "This beta supports up to 500 routines per connected profile.", 413)
        return {"jobs": [self.job(row) for row in rows]}

    async def create(self, body, authorize=None):
        session = identifier(body.get("session_id"))
        await self.gateway.attach(session)
        name = text(body.get("name"), "routine name", 160)
        instruction = text(body.get("instruction"), "routine instruction", 32000)
        schedule = text(body.get("schedule"), "schedule", 200)
        notify = body.get("notify", "changes")
        if notify not in {"changes", "all"}:
            raise APIError("invalid_notify", "Choose changes or all for routine notifications.")
        row = await self.gateway.rest("POST", "/api/cron/jobs", {"name": name, "prompt": instruction, "schedule": schedule, "deliver": "local"}, authorize=authorize)
        self.store.link_job(row["id"], session, notify)
        return self.job(row)

    async def change(self, job: str, enabled: bool, authorize=None):
        identifier(job)
        if type(enabled) is not bool:
            raise APIError("invalid_enabled", "Set enabled to true or false.")
        row = await self.gateway.rest("POST", f"/api/cron/jobs/{quote(job, safe='')}/" + ("resume" if enabled else "pause"), authorize=authorize)
        return self.job(row)

    async def remove(self, job: str, authorize=None):
        identifier(job)
        await self.gateway.rest("DELETE", f"/api/cron/jobs/{quote(job, safe='')}", authorize=authorize)
        return {"removed": True}

    async def result_text(self, source: dict) -> tuple[str, str | None]:
        if source.get("session_id"):
            session = identifier(source["session_id"])
            cursor = None
            if source.get("row_id"):
                for _ in range(32):
                    page = await self.gateway.history(session, cursor)
                    row = next((row for row in page["messages"] if row["id"] == source["row_id"] and row["role"] == "assistant"), None)
                    if row:
                        return row["text"], session
                    cursor = page["before"]
                    if not cursor:
                        break
            raise APIError("result_unavailable", "This result row is no longer available. Open its conversation to review the current Hermes state.", 404)
        job, run = identifier(source["job_id"]), identifier(source["run_id"])
        rows = await self.gateway.rest("GET", f"/api/cron/jobs/{quote(job, safe='')}/runs", limit=100)
        row = next((r for r in rows["runs"] if r["id"] == run), None)
        if not row:
            raise APIError("result_unavailable", "Hermes no longer lists this routine result.", 404)
        if row.get("source") == "cron":
            raise APIError("result_unavailable", "This older update has no saved result identity. Open its conversation to review the current Hermes state.", 404)
        match = re.fullmatch(r"cron_output:([A-Za-z0-9_-]+):(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})", run)
        if row.get("source") == "cron_output" and match and match.group(1) == job:
            profile = await self.gateway.rpc("config.get", {"key": "profile"})
            home = Path(profile["home"])
            path = home / "cron" / "output" / job / (match.group(2) + ".md")
            result = await self.gateway.rest("GET", "/api/files/read", path=str(path))
            data_url = result.get("data_url", "")
            if ";base64," not in data_url:
                raise APIError("upstream_contract", "Hermes returned an unsupported result document.", 502)
            try:
                return base64.b64decode(data_url.split(";base64,", 1)[1], validate=True).decode("utf-8"), None
            except (ValueError, UnicodeError):
                raise APIError("result_unavailable", "This result is not a readable text document.", 502) from None
        raise APIError("result_unavailable", "Hermes recorded this execution without a retrievable output document.", 404)

    async def detail(self, key):
        update, source = self.store.update(key)
        if source.get("request_id"):
            snapshot = await self.gateway.snapshot(source["session_id"])
            valid = any(r["id"] == source["request_id"] and r["generation"] == source["generation"] for r in snapshot["requests"])
            return {"update": update, "text": "Open the conversation to respond." if valid else "This request has already been resolved or replaced.", "request_active": valid}
        result, session = await self.result_text(source)
        return {"update": update, "text": result, "result_session_id": session}

    async def poll_once(self):
        jobs = await self.gateway.rest("GET", "/api/cron/jobs")
        if not isinstance(jobs, list) or len(jobs) > 500:
            raise APIError("upstream_contract", "The Hermes routine list is too large or unsupported.", 502)
        for job in jobs:
            job_id = identifier(job["id"])
            runs = await self.gateway.rest("GET", f"/api/cron/jobs/{quote(job_id, safe='')}/runs", limit=30)
            for run in reversed(runs["runs"]):
                run_id = identifier(run["id"])
                if self.store.observed(job_id, run_id) or run.get("is_active"):
                    continue
                if run.get("source") == "cron" and not run.get("ended_at"):
                    continue
                source = {"job_id": job_id, "run_id": run_id}
                try:
                    if run.get("source") == "cron":
                        page = await self.gateway.history(run_id)
                        answer = next((row for row in reversed(page["messages"]) if row["role"] == "assistant" and not row.get("provisional")), None)
                        if not answer or not answer["text"]:
                            raise APIError("result_pending", "Hermes is still saving the result. Check again shortly.", 409)
                        source.update(session_id=run_id, row_id=answer["id"])
                    result, result_session = await self.result_text(source)
                except APIError as error:
                    if error.code in {"result_pending", "result_unavailable", "not_found"}:
                        continue
                    raise
                fingerprint = digest(" ".join(result.split()))
                link = self.store.job_link(job_id)
                silent = silent_result(result)
                old = float(run.get("started_at") or 0) < self.since
                unchanged = link["notify"] == "changes" and link["last_fingerprint"] == fingerprint
                if not (silent or old or unchanged):
                    error = str(run.get("end_reason") or "").endswith("error") or result.startswith("[CRON_FAILURE]") or "failed" in str(run.get("title", "")).lower()
                    payload = {"kind": "error" if error else "result", "title": job.get("name") or "Routine update", "summary": result[:240], "job_id": job_id}
                    if link["session_id"]:
                        payload["session_id"] = link["session_id"]
                    if result_session:
                        payload["result_session_id"] = result_session
                    await self.add_update("cron:" + job_id + ":" + run_id, payload, source)
                self.store.observe(job_id, run_id, link["last_fingerprint"] if silent else fingerprint)

    async def _poll(self):
        while True:
            try:
                await self.poll_once()
                self.poll_problem = None
            except (APIError, aiohttp.ClientError, ConnectionError, TimeoutError, ValueError, KeyError):
                self.poll_problem = "Routine updates are waiting for Hermes."
            await asyncio.sleep(self.poll_interval)

    async def deliver_once(self, now=None):
        now = time.time() if now is None else now
        for row in self.store.deliveries(now):
            prefs = json.loads(row["preferences"])
            if not prefs["notifications_enabled"]:
                self.store.delivery_result(row["device"], row["update_id"], "disabled", now)
                continue
            if is_quiet(prefs, now) or not self.apns or not row["push_token"]:
                self.store.delivery_result(row["device"], row["update_id"], "pending", now + 60)
                continue
            update, source = self.store.update(row["update_id"])
            if source.get("request_id"):
                detail = await self.detail(row["update_id"])
                if not detail["request_active"]:
                    self.store.delivery_result(row["device"], row["update_id"], "stale", now)
                    continue
            if not self.store.active(row["device"]):
                continue
            try:
                result = await self.apns.send(row, update)
            except (httpx.HTTPError, ConnectionError, TimeoutError):
                result = "retry"
            if result == "invalid_token":
                self.store.register_push(row["device"], None, row["environment"])
            state = result if result in {"sent", "invalid_token"} else "pending"
            next_attempt = now + min(3600, 5 * (2 ** min(row["attempts"], 10)))
            self.store.delivery_result(row["device"], row["update_id"], state, next_attempt, increment=True)

    async def _deliver(self):
        while True:
            try:
                await self.deliver_once()
            except (APIError, aiohttp.ClientError, httpx.HTTPError, ConnectionError, TimeoutError):
                pass
            await asyncio.sleep(2)


class Scheduler:
    def __init__(self, gateway, command: list[str], working_directory: str | None):
        self.gateway, self.command, self.cwd = gateway, command, working_directory
        self.task = None
        self.process = None
        self.owns = False
        self.status = "waiting"

    async def start(self):
        self.task = asyncio.create_task(self.run())

    async def close(self):
        if self.task:
            self.task.cancel()
            await asyncio.gather(self.task, return_exceptions=True)
        if self.process and self.process.returncode is None:
            self.process.terminate()
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(self.process.wait(), 15)

    async def run(self):
        while True:
            try:
                jobs = await self.gateway.rest("GET", "/api/cron/jobs")
                fresh = any(isinstance(j.get("scheduler_heartbeat_age_s"), (float, int)) and j["scheduler_heartbeat_age_s"] < 90 for j in jobs)
                if fresh and not self.owns:
                    self.status = "existing_owner"
                else:
                    profile = await self.gateway.rpc("config.get", {"key": "profile"})
                    env = dict(os.environ)
                    env.pop("HERMES_DESKTOP", None)
                    env["HERMES_HOME"] = profile["home"]
                    env["HERMES_PROFILE"] = self.gateway.profile
                    self.process = await asyncio.create_subprocess_exec(*self.command, "--profile", self.gateway.profile, "cron", "tick", cwd=self.cwd, env=env, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
                    status = await self.process.wait()
                    self.owns = status == 0
                    self.status = "running" if self.owns else "failed"
            except (APIError, OSError, aiohttp.ClientError, ConnectionError, TimeoutError):
                self.status = "offline"
            await asyncio.sleep(30)
