from __future__ import annotations

import base64
import binascii
import json
import re
import time
import unicodedata
import uuid
from dataclasses import dataclass
from pathlib import PurePosixPath

from .domain import APIError, encoded, text

MAX_UPLOAD_BODY = 7 * 1024 * 1024
MAX_TUNNEL_FRAME = 8 * 1024 * 1024
MAX_FILE_BYTES = 5 * 1024 * 1024
MAX_TEXT_BYTES = 128 * 1024
MAX_SEND_BYTES = 16 * 1024 * 1024
MAX_ATTACHMENTS = 4
EXPIRY_SECONDS = 86400
UPLOAD_ROUTE = re.compile(r"/v1/sessions/[A-Za-z0-9_.:-]+/attachments")
MEDIA_EXTENSIONS = {
    "image/jpeg": {".jpg", ".jpeg"}, "image/png": {".png"}, "application/pdf": {".pdf"},
    "text/plain": None, "text/markdown": {".md", ".markdown"}, "text/csv": {".csv"},
    "application/json": {".json"}, "text/x-python": {".py"},
    "text/javascript": {".js", ".mjs"}, "application/javascript": {".js", ".mjs"},
    "text/x-swift": {".swift"}, "text/x-c": {".c", ".h"}, "text/x-c++": {".cc", ".cpp", ".hpp"},
    "text/html": {".html", ".htm"}, "text/css": {".css"},
    "application/xml": {".xml"}, "text/xml": {".xml"},
    "application/yaml": {".yaml", ".yml"}, "text/yaml": {".yaml", ".yml"},
}
LIMITS = {"max_file_bytes": MAX_FILE_BYTES, "max_text_bytes": MAX_TEXT_BYTES,
          "max_count": MAX_ATTACHMENTS, "max_total_bytes": MAX_SEND_BYTES,
          "expires_after_seconds": EXPIRY_SECONDS}


def is_upload(method, path):
    return method == "POST" and isinstance(path, str) and UPLOAD_ROUTE.fullmatch(path) is not None


@dataclass(frozen=True)
class PreparedAttachment:
    id: str
    name: str
    media_type: str
    byte_count: int
    content_base64: str

    @property
    def gateway_name(self):
        return "companion-" + self.id + "-" + self.name


def prepare(body):
    name = text(body.get("name"), "filename", 180)
    if len(name.encode()) > 180:
        raise APIError("invalid_attachment", "Shorten this filename to 180 UTF-8 bytes or fewer.")
    if name in {".", ".."} or any(char in '/\\\"\'`@[]' or unicodedata.category(char).startswith("C") for char in name):
        raise APIError("invalid_attachment", "Choose a filename without paths, control characters, or reference syntax.")
    media = body.get("media_type")
    if not isinstance(media, str) or media not in MEDIA_EXTENSIONS:
        raise APIError("unsupported_attachment", "Choose a JPEG, PNG, PDF, or UTF-8 text file.")
    extensions = MEDIA_EXTENSIONS[media]
    if extensions and PurePosixPath(name).suffix.lower() not in extensions:
        raise APIError("unsupported_attachment", "The filename does not match its file type.")
    content = body.get("content_base64")
    if not isinstance(content, str) or not content:
        raise APIError("invalid_attachment", "This attachment has no content.")
    if len(content) > ((MAX_FILE_BYTES + 2) // 3) * 4:
        raise APIError("payload_too_large", "Attachments must be 5 MiB or smaller.", 413)
    try:
        data = base64.b64decode(content, validate=True)
    except (binascii.Error, ValueError):
        raise APIError("invalid_attachment", "Attachment content must be valid base64.") from None
    if not data:
        raise APIError("invalid_attachment", "Empty files cannot be attached.")
    if len(data) > MAX_FILE_BYTES:
        raise APIError("payload_too_large", "Attachments must be 5 MiB or smaller.", 413)
    if media == "image/jpeg":
        valid = data.startswith(b"\xff\xd8\xff") and data.endswith(b"\xff\xd9")
    elif media == "image/png":
        valid = data.startswith(b"\x89PNG\r\n\x1a\n")
    elif media == "application/pdf":
        valid = data.startswith(b"%PDF-")
    else:
        if len(data) > MAX_TEXT_BYTES:
            raise APIError("payload_too_large", "Text and code files must be 128 KiB or smaller.", 413)
        try:
            value = data.decode("utf-8")
            valid = "\x00" not in value
        except UnicodeDecodeError:
            valid = False
    if not valid:
        raise APIError("invalid_attachment", "The attachment bytes do not match the selected file type.")
    return PreparedAttachment(str(uuid.uuid4()), name, media, len(data), content)


def public_ticket(row):
    return {key: row[key] for key in ("id", "name", "media_type", "byte_count")} | {"status": "ready"}


def attachment_ids(body):
    values = body.get("attachment_ids", [])
    if not isinstance(values, list) or len(values) > MAX_ATTACHMENTS or any(not isinstance(value, str) or not re.fullmatch(r"[a-f0-9-]{36}", value) for value in values):
        raise APIError("invalid_attachment", "Choose at most four valid attachments.")
    if len(set(values)) != len(values):
        raise APIError("invalid_attachment", "An attachment cannot appear twice in one message.")
    if values and (body.get("kind") != "send" or str(body.get("text", "")).lstrip().startswith("/")):
        raise APIError("invalid_attachment", "Send attachments with a message, not a slash command.")
    return values


def prompt_with_attachments(value, tickets):
    refs = "\n".join(row["gateway_ref"] for row in tickets)
    parts = [value, refs] if value else [refs]
    if any(row["media_type"].startswith("image/") for row in tickets):
        parts.append("Use vision_analyze to examine the attached image files. If image analysis is unavailable, explain that limitation.")
    return "\n\n".join(parts)


class Attachments:
    def __init__(self, store):
        self.store = store

    def reserve(self, device, session, prepared):
        now = time.time()
        db = self.store.db
        with db:
            db.execute("DELETE FROM attachments WHERE expires<=? AND state IN ('ready','removed','failed','expired')", (now - EXPIRY_SECONDS,))
            for owner, maximum, count in ((device, 256 * 1024 * 1024, 4096), ("*", 1024 * 1024 * 1024, 16384)):
                row = db.execute("SELECT bytes,count FROM attachment_usage WHERE owner=?", (owner,)).fetchone()
                if row and (row[0] + prepared.byte_count > maximum or row[1] >= count):
                    raise APIError("attachment_quota", "The host attachment storage allowance is full. Ask the host owner to review Hermes attachment storage.", 429)
            for owner in (device, "*"):
                db.execute("INSERT INTO attachment_usage VALUES(?,?,1) ON CONFLICT(owner) DO UPDATE SET bytes=bytes+excluded.bytes,count=count+1", (owner, prepared.byte_count))
            db.execute("INSERT INTO attachments(id,device,session,name,media_type,byte_count,state,expires) VALUES(?,?,?,?,?,?,'uploading',?)",
                       (prepared.id, device, session, prepared.name, prepared.media_type, prepared.byte_count, now + EXPIRY_SECONDS))

    def uploaded(self, prepared, result):
        ref = result.get("ref_text")
        if result.get("attached") is not True or not isinstance(ref, str) or not ref.startswith("@file:") or len(ref) > 8192 or "\n" in ref or "\r" in ref:
            raise APIError("upstream_contract", "Hermes did not confirm a usable attachment reference.", 502)
        with self.store.db:
            self.store.db.execute("UPDATE attachments SET gateway_ref=?,state='ready' WHERE id=?", (ref, prepared.id))
        return public_ticket(prepared.__dict__)

    def upload_failed(self, prepared, uncertain):
        with self.store.db:
            self.store.db.execute("UPDATE attachments SET state=? WHERE id=?", ("upload_uncertain" if uncertain else "failed", prepared.id))

    def resolve(self, device, session, ids):
        rows = []
        for key in ids:
            row = self.store.db.execute("SELECT * FROM attachments WHERE id=? AND device=? AND session=?", (key, device, session)).fetchone()
            if not row:
                raise APIError("attachment_not_found", "This attachment belongs to another draft or is no longer available.", 404)
            if row["state"] in {"sending", "uncertain", "upload_uncertain"}:
                raise APIError("attachment_uncertain", "Hermes may have received this attachment. Review the conversation before sending again.", 409)
            if row["state"] != "ready":
                raise APIError("attachment_unavailable", "This attachment was already sent or removed. Add it again if needed.", 409)
            if row["expires"] <= time.time():
                raise APIError("attachment_expired", "This unsent attachment expired. Add it again to continue.", 410)
            rows.append(dict(row))
        if sum(row["byte_count"] for row in rows) > MAX_SEND_BYTES:
            raise APIError("payload_too_large", "The attachments in one message must total 16 MiB or less.", 413)
        return rows

    def remove(self, device, session, key):
        rows = self.resolve(device, session, [key])
        with self.store.db:
            self.store.db.execute("UPDATE attachments SET state='removed' WHERE id=?", (rows[0]["id"],))
        return {"removed": True}

    def claim(self, device, session, operation, value, submitted, tickets):
        ticket_json = encoded([public_ticket(row) for row in tickets])
        size = len(value.encode()) + len(submitted.encode()) + len(ticket_json.encode())
        with self.store.db:
            self.store.db.execute("DELETE FROM attachment_sends WHERE tickets='[]' AND row_id IS NULL AND created<? AND state NOT IN ('sending','uncertain')", (time.time() - EXPIRY_SECONDS,))
            for owner, maximum in ((device, 8 * 1024 * 1024), (None, 32 * 1024 * 1024)):
                query = "SELECT COALESCE(SUM(length(CAST(original AS BLOB))+length(CAST(submitted AS BLOB))+length(CAST(tickets AS BLOB))),0) FROM attachment_sends"
                used = self.store.db.execute(query + (" WHERE device=?" if owner else ""), (owner,) if owner else ()).fetchone()[0]
                if used + size > maximum:
                    raise APIError("attachment_quota", "The host attachment history allowance is full. Ask the host owner to review Companion storage.", 429)
            self.store.db.execute("INSERT INTO attachment_sends(device,operation,session,original,submitted,tickets,state,created) VALUES(?,?,?,?,?,?,'sending',?)",
                                  (device, operation, session, value, submitted, ticket_json, time.time()))
            for row in tickets:
                self.store.db.execute("UPDATE attachments SET state='sending',send_operation=? WHERE id=?", (operation, row["id"]))

    def sent(self, device, operation, state, row_id=None):
        with self.store.db:
            self.store.db.execute("UPDATE attachment_sends SET state=?,row_id=COALESCE(?,row_id) WHERE device=? AND operation=?", (state, row_id, device, operation))
            self.store.db.execute("UPDATE attachments SET state=? WHERE device=? AND send_operation=?", ("consumed" if state == "queued" else state if state in {"consumed", "uncertain"} else "ready", device, operation))

    def track_plain(self, device, session, operation, value):
        try:
            self.claim(device, session, operation, value, value, [])
            return True
        except APIError as error:
            pending = self.store.db.execute("SELECT 1 FROM attachment_sends WHERE session=? AND state IN ('queued','sending') AND tickets!='[]' LIMIT 1", (session,)).fetchone()
            if error.code != "attachment_quota" or pending:
                raise
            return False

    def finish_plain(self, device, operation, result):
        status = result.get("status")
        if status in {"queued", "uncertain"}:
            self.sent(device, operation, status)
        else:
            with self.store.db:
                self.store.db.execute("DELETE FROM attachment_sends WHERE device=? AND operation=? AND tickets='[]'", (device, operation))

    def project(self, session, message):
        if message["role"] != "user":
            return message
        value = message["text"]
        ids = set(re.findall(r"companion-([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})-", value))
        if not ids or len(ids) > 256:
            return message
        placeholders = ",".join("?" for _ in ids)
        rows = self.store.db.execute(f"SELECT DISTINCT s.* FROM attachment_sends s JOIN attachments a ON a.device=s.device AND a.send_operation=s.operation WHERE s.session=? AND s.state IN ('sending','queued','consumed','uncertain') AND a.id IN ({placeholders})", (session, *ids)).fetchall()
        row_ids = {row["row_id"] for row in rows if row["row_id"]} | {message["id"]}
        placeholders = ",".join("?" for _ in row_ids)
        rows += self.store.db.execute(f"SELECT * FROM attachment_sends WHERE session=? AND tickets='[]' AND state IN ('sending','queued','consumed','uncertain') AND (row_id IS NULL OR row_id IN ({placeholders}))", (session, *row_ids)).fetchall()
        spans = []
        for row in rows:
            submitted = row["submitted"].strip()
            if not submitted:
                continue
            offset = 0
            for _ in range(256):
                start = value.find(submitted, offset)
                if start < 0:
                    break
                end = start + len(submitted)
                offset = end
                if (start and value[max(0, start - 2):start] != "\n\n") or (end < len(value) and value[end:end + 2] != "\n\n"):
                    continue
                spans.append((start, end, row))
        spans.sort(key=lambda span: (span[0], -span[1]))
        matched, last = [], -1
        for span in spans:
            if span[0] >= last:
                matched.append(span)
                last = span[1]
        if not matched:
            return message
        prefix_count = 1
        while prefix_count < len(matched) and value[matched[prefix_count - 1][1]:matched[prefix_count][0]] == "\n\n":
            prefix_count += 1
        suffix = value[matched[prefix_count - 1][1]:]
        complete = matched[0][0] == 0 and (not suffix or suffix.startswith(("\n\n--- Attached Context ---\n\n", "\n\n--- Context Warnings ---\n")))
        if complete:
            matched = matched[:prefix_count]
            value = value[:matched[-1][1]]
        for start, end, row in reversed(matched):
            value = value[:start] + row["original"] + value[end:]
        tickets = []
        with self.store.db:
            for _, _, row in matched:
                self.store.db.execute("UPDATE attachment_sends SET row_id=? WHERE device=? AND operation=?", (message["id"], row["device"], row["operation"]))
                if complete and suffix:
                    self.store.db.execute("UPDATE attachment_sends SET state='consumed' WHERE device=? AND operation=? AND state='queued'", (row["device"], row["operation"]))
                tickets.extend(json.loads(row["tickets"]))
        return {**message, "text": value, "attachments": list({ticket["id"]: ticket for ticket in tickets}.values())}
