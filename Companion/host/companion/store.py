from __future__ import annotations

import os
import secrets
import sqlite3
import time
import uuid
from pathlib import Path

from .domain import APIError, SCOPES, digest, encoded, preferences, utc
import json


class Store:
    def __init__(self, path: str, profile: str, recover: bool = True):
        target = Path(path)
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        os.chmod(path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS invitations (hash TEXT PRIMARY KEY, expires REAL NOT NULL, scopes TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, hash TEXT UNIQUE NOT NULL, name TEXT NOT NULL,
                scopes TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, push_token TEXT, environment TEXT,
                preferences TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS operations (device TEXT NOT NULL, id TEXT NOT NULL, signature TEXT NOT NULL,
                state TEXT NOT NULL, response TEXT, status INTEGER NOT NULL DEFAULT 200, PRIMARY KEY(device,id));
            CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, session_id TEXT, notify TEXT NOT NULL,
                last_fingerprint TEXT);
            CREATE TABLE IF NOT EXISTS observations (job_id TEXT NOT NULL, run_id TEXT NOT NULL, PRIMARY KEY(job_id,run_id));
            CREATE TABLE IF NOT EXISTS updates (id TEXT PRIMARY KEY, event_key TEXT UNIQUE NOT NULL, payload TEXT NOT NULL,
                source TEXT NOT NULL, created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS outbox (device TEXT NOT NULL, update_id TEXT NOT NULL, state TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL, PRIMARY KEY(device,update_id));
            CREATE TABLE IF NOT EXISTS attachments (id TEXT PRIMARY KEY, device TEXT NOT NULL, session TEXT NOT NULL,
                name TEXT NOT NULL, media_type TEXT NOT NULL, byte_count INTEGER NOT NULL, gateway_ref TEXT,
                state TEXT NOT NULL, expires REAL NOT NULL, send_operation TEXT);
            CREATE TABLE IF NOT EXISTS attachment_usage (owner TEXT PRIMARY KEY, bytes INTEGER NOT NULL, count INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS attachment_sends (device TEXT NOT NULL, operation TEXT NOT NULL, session TEXT NOT NULL,
                original TEXT NOT NULL, submitted TEXT NOT NULL, tickets TEXT NOT NULL, state TEXT NOT NULL, row_id TEXT,
                created REAL NOT NULL DEFAULT 0, PRIMARY KEY(device,operation));
            CREATE INDEX IF NOT EXISTS attachment_sends_session ON attachment_sends(session,row_id);
        """)
        with self.db:
            if "created" not in {row[1] for row in self.db.execute("PRAGMA table_info(attachment_sends)")}:
                self.db.execute("ALTER TABLE attachment_sends ADD COLUMN created REAL NOT NULL DEFAULT 0")
            row = self.db.execute("SELECT value FROM metadata WHERE key='profile'").fetchone()
            if row and row[0] != profile:
                raise APIError("profile_mismatch", "This delivery store belongs to a different Hermes profile.")
            self.db.execute("INSERT OR IGNORE INTO metadata VALUES('profile',?)", (profile,))
            self.db.execute("INSERT OR IGNORE INTO metadata VALUES('cursor_key',?)", (secrets.token_urlsafe(32),))
            if recover:
                self.db.execute("UPDATE operations SET state='uncertain',response=NULL WHERE state='dispatching'")
                self.db.execute("UPDATE attachments SET state='upload_uncertain' WHERE state='uploading'")
                self.db.execute("UPDATE attachments SET state='uncertain' WHERE state='sending'")
                self.db.execute("UPDATE attachment_sends SET state='uncertain' WHERE state='sending'")
        self.profile = profile
        self.cursor_key = self.db.execute("SELECT value FROM metadata WHERE key='cursor_key'").fetchone()[0]

    def close(self):
        self.db.close()

    def invite(self, now: float | None = None, scopes=SCOPES) -> str:
        now = time.time() if now is None else now
        if not set(scopes) <= SCOPES or not scopes:
            raise ValueError("Invalid device scope")
        code = secrets.token_urlsafe(18)
        with self.db:
            self.db.execute("DELETE FROM invitations WHERE expires<=?", (now,))
            self.db.execute("INSERT INTO invitations VALUES(?,?,?)", (digest(code), now + 600, encoded(sorted(scopes))))
        return code

    def pair(self, code: str, name: str, now: float | None = None) -> dict:
        now = time.time() if now is None else now
        token, device = secrets.token_urlsafe(32), str(uuid.uuid4())
        prefs = preferences(dict(notifications_enabled=True, quiet_start=None, quiet_end=None, time_zone="UTC"))
        with self.db:
            row = self.db.execute("DELETE FROM invitations WHERE hash=? AND expires>? RETURNING scopes", (digest(code), now)).fetchone()
            if row is None:
                raise APIError("invalid_invitation", "This pairing invitation is invalid, used, or expired.", 401)
            self.db.execute("INSERT INTO devices(id,hash,name,scopes,preferences) VALUES(?,?,?,?,?)",
                            (device, digest(token), name, row[0], encoded(prefs)))
        return {"device_id": device, "token": token}

    def authenticate(self, token: str, scope: str = "read") -> dict:
        row = self.db.execute("SELECT * FROM devices WHERE hash=? AND revoked=0", (digest(token),)).fetchone()
        if not row:
            raise APIError("unauthorized", "Pair this device to continue.", 401)
        if scope not in json.loads(row["scopes"]):
            raise APIError("forbidden", "This device cannot perform that action.", 403)
        return dict(row)

    def active(self, device: str) -> bool:
        return bool(self.db.execute("SELECT 1 FROM devices WHERE id=? AND revoked=0", (device,)).fetchone())

    def revoke(self, device: str):
        with self.db:
            self.db.execute("UPDATE devices SET revoked=1,push_token=NULL WHERE id=?", (device,))
            self.db.execute("UPDATE outbox SET state='revoked' WHERE device=? AND state='pending'", (device,))
            self.db.execute("UPDATE attachments SET state='removed' WHERE device=? AND state='ready'", (device,))

    def begin(self, device: str, operation: str, signature: str) -> tuple[dict, int] | None:
        with self.db:
            row = self.db.execute("SELECT * FROM operations WHERE device=? AND id=?", (device, operation)).fetchone()
            if row:
                if row["signature"] != signature:
                    raise APIError("operation_conflict", "This operation ID was already used for a different action.", 409)
                if row["response"]:
                    return json.loads(row["response"]), row["status"]
                return {"operation_id": operation, "status": "uncertain", "message": "Hermes may have received this action. Check its state before sending a new action."}, 409
            self.db.execute("INSERT INTO operations(device,id,signature,state) VALUES(?,?,?,'dispatching')", (device, operation, signature))
        return None

    def finish(self, device: str, operation: str, result: dict, status: int = 200):
        with self.db:
            self.db.execute("UPDATE operations SET state=?,response=?,status=? WHERE device=? AND id=?",
                            ("uncertain" if result.get("status") == "uncertain" else "finished", encoded(result), status, device, operation))

    def get_preferences(self, device: str) -> dict:
        return json.loads(self.db.execute("SELECT preferences FROM devices WHERE id=?", (device,)).fetchone()[0])

    def set_preferences(self, device: str, value: dict):
        with self.db:
            self.db.execute("UPDATE devices SET preferences=? WHERE id=?", (encoded(value), device))

    def register_push(self, device: str, token: str, environment: str):
        with self.db:
            self.db.execute("UPDATE devices SET push_token=?,environment=? WHERE id=?", (token, environment, device))

    def link_job(self, job: str, session: str | None, notify: str):
        with self.db:
            self.db.execute("INSERT INTO jobs(id,session_id,notify) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET session_id=excluded.session_id,notify=excluded.notify",
                            (job, session, notify))

    def job_link(self, job: str) -> dict:
        row = self.db.execute("SELECT * FROM jobs WHERE id=?", (job,)).fetchone()
        return dict(row) if row else {"session_id": None, "notify": "changes", "last_fingerprint": None}

    def observed(self, job: str, run: str) -> bool:
        return bool(self.db.execute("SELECT 1 FROM observations WHERE job_id=? AND run_id=?", (job, run)).fetchone())

    def observe(self, job: str, run: str, fingerprint: str):
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO observations VALUES(?,?)", (job, run))
            self.db.execute("INSERT INTO jobs(id,notify,last_fingerprint) VALUES(?,'changes',?) ON CONFLICT(id) DO UPDATE SET last_fingerprint=excluded.last_fingerprint", (job, fingerprint))

    def add_update(self, event_key: str, payload: dict, source: dict, now: float | None = None) -> dict | None:
        now = time.time() if now is None else now
        update = {"id": str(uuid.uuid4()), "created_at": utc(now), **payload}
        with self.db:
            cursor = self.db.execute("INSERT OR IGNORE INTO updates VALUES(?,?,?,?,?)", (update["id"], event_key, encoded(update), encoded(source), now))
            if not cursor.rowcount:
                return None
            self.db.execute("INSERT INTO outbox(device,update_id,state,next_attempt) SELECT id,?,'pending',? FROM devices WHERE revoked=0", (update["id"], now))
        return update

    def updates(self) -> list[dict]:
        return [json.loads(row[0]) for row in self.db.execute("SELECT payload FROM updates ORDER BY created DESC LIMIT 200")]

    def update(self, key: str) -> tuple[dict, dict]:
        row = self.db.execute("SELECT payload,source FROM updates WHERE id=?", (key,)).fetchone()
        if not row:
            raise APIError("not_found", "That update is no longer available.", 404)
        return json.loads(row[0]), json.loads(row[1])

    def deliveries(self, now: float) -> list[dict]:
        rows = self.db.execute("SELECT o.*,d.push_token,d.environment,d.preferences FROM outbox o JOIN devices d ON d.id=o.device WHERE o.state='pending' AND o.next_attempt<=? AND d.revoked=0 ORDER BY o.next_attempt LIMIT 50", (now,))
        return [dict(row) for row in rows]

    def delivery_result(self, device: str, update: str, state: str, next_attempt: float, increment: bool = False):
        with self.db:
            self.db.execute("UPDATE outbox SET state=?,next_attempt=?,attempts=attempts+? WHERE device=? AND update_id=? AND state='pending'", (state, next_attempt, int(increment), device, update))
