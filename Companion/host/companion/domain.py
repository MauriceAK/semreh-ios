from __future__ import annotations

import hashlib
import json
import re
import uuid
import unicodedata
from datetime import datetime, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

MAX_BODY = 256 * 1024
MAX_RESPONSE = 4 * 1024 * 1024
PAGE_SIZE = 120
SCOPES = frozenset({"read", "chat", "controls", "jobs"})
SAFE_SLASH = {"status", "usage", "context", "model", "reasoning", "stop", "help"}


class APIError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


def utc(timestamp: float | None = None) -> str:
    when = datetime.now(timezone.utc) if timestamp is None else datetime.fromtimestamp(timestamp, timezone.utc)
    return when.isoformat().replace("+00:00", "Z")


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def encoded(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def text(value, field: str, maximum: int = 8192, empty: bool = False) -> str:
    if not isinstance(value, str) or len(value) > maximum or (not empty and not value.strip()):
        raise APIError("invalid_input", f"Invalid {field}.")
    return value


def identifier(value: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,200}", value):
        raise APIError("invalid_id", "Invalid resource identifier.")
    return value


def operation_id(value) -> str:
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise APIError("invalid_operation", "A UUID operation_id is required.") from None


def preferences(body: dict) -> dict:
    if not isinstance(body.get("notifications_enabled"), bool):
        raise APIError("invalid_preferences", "Choose whether notifications are enabled.")
    start, end = body.get("quiet_start"), body.get("quiet_end")
    if (start is None) != (end is None):
        raise APIError("invalid_preferences", "Set both quiet-hour times or neither.")
    for value in (start, end):
        if value is not None and (type(value) is not int or not 0 <= value < 1440):
            raise APIError("invalid_preferences", "Quiet hours must be minutes since midnight.")
    zone = text(body.get("time_zone"), "time zone", 80)
    try:
        ZoneInfo(zone)
    except ZoneInfoNotFoundError:
        raise APIError("invalid_preferences", "Unknown time zone.") from None
    return dict(notifications_enabled=body["notifications_enabled"], quiet_start=start, quiet_end=end, time_zone=zone)


def is_quiet(prefs: dict, timestamp: float) -> bool:
    start, end = prefs["quiet_start"], prefs["quiet_end"]
    if start is None or start == end:
        return False
    local = datetime.fromtimestamp(timestamp, ZoneInfo(prefs["time_zone"]))
    minute = local.hour * 60 + local.minute
    return start <= minute < end if start < end else minute >= start or minute < end


def silent_result(value: str) -> bool:
    normalized = value.strip().upper()
    markers = {"SILENT", "[SILENT]", "NO_REPLY", "NO REPLY", "[静默]", "静默", "[沉默]", "沉默"}
    if normalized.startswith(tuple(marker for marker in markers if marker.startswith("["))):
        return True
    lines = [line.strip() for line in normalized.splitlines() if line.strip()]
    for candidate in (normalized, *(lines[:1] + lines[-1:])):
        if not 0 < len(candidate) <= 64:
            continue
        while candidate and candidate[0] not in "[]" and unicodedata.category(candidate[0]).startswith("P"):
            candidate = candidate[1:]
        while candidate and candidate[-1] not in "[]" and unicodedata.category(candidate[-1]).startswith("P"):
            candidate = candidate[:-1]
        if " ".join(candidate.split()) in markers:
            return True
    return False


def message_id(row: dict) -> str:
    key = row.get("id", row.get("_row_id", row.get("row_id")))
    if key is None:
        raise APIError("upstream_contract", "Hermes returned a message without a canonical row ID.", 502)
    return str(key)


def message(row: dict) -> dict | None:
    role = row.get("role")
    if role not in {"user", "assistant"} or row.get("display_kind") not in {None, "", "steer"}:
        return None
    content = row.get("display_content", row.get("content", row.get("text", "")))
    if isinstance(content, list):
        parts = []
        for part in content:
            if isinstance(part, str):
                parts.append(part)
            elif isinstance(part, dict):
                if part.get("type") in {"text", "input_text", "output_text"} and isinstance(part.get("text"), str):
                    parts.append(part["text"])
                elif role == "user" and part.get("type") in {"image", "image_url", "input_image", "input_audio", "file"}:
                    parts.append("[Attachment]")
        content = "\n".join(parts)
    if not isinstance(content, str) or not content.strip():
        return None
    result = {"id": message_id(row), "role": role, "text": content, "provisional": False}
    stamp = row.get("timestamp")
    if isinstance(stamp, (int, float)):
        result["created_at"] = utc(stamp)
    elif isinstance(stamp, str):
        result["created_at"] = stamp
    return result
