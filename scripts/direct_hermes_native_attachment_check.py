#!/usr/bin/env python3
"""Read-only canonical complement to the production attachment UI test.

Searches at most 20 recent conversations in the guarded disposable fixture.
Only the exact UUID-tagged UI marker is accepted; no raw response/auth data is
written to evidence. This does not claim rendered media or device acceptance.
"""
import argparse
import asyncio
import base64
import binascii
import json
from pathlib import Path
import re
from urllib.parse import quote

import direct_hermes_probe as stock
from direct_hermes_attachment_probe import _authenticated, _output_path, _text


FILE_PICKER_TEXT_BYTES = (
    b"SEMREH_FILE_PICKER_TEXT_V1\n"
    b"Synthetic file used only for the isolated Semreh migration test.\n"
)
FILE_PICKER_TEXT_MARKER = re.compile(
    r"SEMREH_SLICE3_FILE_PICKER_TEXT_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\Z"
)
FILE_PICKER_PDF_MARKER = re.compile(
    r"SEMREH_SLICE3_FILE_PICKER_PDF_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\Z"
)


async def _canonical_pages(client):
    """Return bounded oldest-first canonical pages without exposing payloads."""
    response = await client.get("/api/profiles/sessions", params={
        "profile": "default", "limit": 20, "offset": 0, "order": "recent",
    })
    if response.status_code != 200:
        raise RuntimeError("Disposable session discovery failed")
    discovery = response.json()
    if not isinstance(discovery, dict):
        raise RuntimeError("Unexpected disposable discovery response")
    sessions = discovery.get("sessions")
    if not isinstance(sessions, list) or len(sessions) > 20:
        raise RuntimeError("Unexpected bounded discovery response")

    pages = []
    for session in sessions:
        if not isinstance(session, dict):
            raise RuntimeError("Unexpected disposable session record")
        stored_id = session.get("id")
        if not isinstance(stored_id, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", stored_id):
            raise RuntimeError("Unexpected disposable session identity")
        response = await client.get(
            f"/api/sessions/{quote(stored_id, safe='')}/messages",
            params={"profile": "default", "include_compacted": "true",
                    "order": "oldest", "limit": 100, "offset": 0},
        )
        if response.status_code != 200:
            raise RuntimeError("Disposable canonical read failed")
        payload = response.json()
        if not isinstance(payload, dict):
            raise RuntimeError("Canonical response malformed")
        canonical_session_id = payload.get("session_id")
        if not isinstance(canonical_session_id, str) or not canonical_session_id.strip():
            raise RuntimeError("Canonical session ID missing")
        rows = payload.get("messages")
        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise RuntimeError("Canonical messages malformed")
        pages.append((canonical_session_id.strip(), rows))
    return pages


def _row_ids_are_durable(rows):
    ids = [row.get("id") for row in rows]
    return (
        all(
            isinstance(row_id, (str, int))
            and not isinstance(row_id, bool)
            and (not isinstance(row_id, str) or row_id.strip())
            for row_id in ids
        )
        and len(set(ids)) == len(ids)
    )


def _decode_data_url(payload, *, expected_mime, expected_bytes=None):
    data_url = payload.get("data_url") if isinstance(payload, dict) else None
    if not isinstance(data_url, str) or len(data_url) > 2 * 1024 * 1024:
        raise RuntimeError("Authenticated managed-file response malformed or oversized")
    header, separator, encoded = data_url.partition(",")
    if not separator or header != f"data:{expected_mime};base64":
        raise RuntimeError("Authenticated managed-file data URL malformed")
    try:
        content = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise RuntimeError("Authenticated managed-file bytes malformed") from error
    if not content:
        raise RuntimeError("Authenticated managed-file bytes empty")
    if expected_bytes is not None and content != expected_bytes:
        raise RuntimeError("Synthetic text file contents changed")
    return content


def _owned_reference(text, prefix, home, expected_name=None):
    references = [line[len(prefix):].strip() for line in text.splitlines()
                  if line.startswith(prefix)]
    if len(references) != 1:
        raise RuntimeError("Canonical file-picker reference count invalid")
    path = Path(references[0])
    if not path.is_absolute() or (expected_name is not None and path.name != expected_name):
        raise RuntimeError("Canonical file-picker reference malformed")
    resolved_home = home.resolve()
    if not resolved_home in path.resolve().parents:
        raise RuntimeError("Canonical file-picker reference escaped owned home")
    return path


def _exact_turn(rows, start, end):
    if end - start != 2:
        raise RuntimeError("Each file-picker marker must be followed by exactly one terminal ACK")
    if rows[start + 1].get("role") != "assistant" or _text(rows[start + 1]) != "SEMREH_SLICE1_ACK":
        raise RuntimeError("Each file-picker marker must be followed by exactly one terminal ACK")
    return start + 1


async def check_file_picker(text_marker, pdf_marker):
    """Verify both opt-in Files-picker turns in one canonical session."""
    credentials = json.loads((stock.RUNTIME / "credentials.json").read_text())
    matches = []
    async with _authenticated(credentials) as (client, _):
        for canonical_session_id, rows in await _canonical_pages(client):
            text_hits = [i for i, row in enumerate(rows)
                         if row.get("role") == "user"
                         and _text(row).split("\n", 1)[0] == text_marker]
            pdf_hits = [i for i, row in enumerate(rows)
                        if row.get("role") == "user"
                        and _text(row).split("\n", 1)[0] == pdf_marker]
            if not text_hits and not pdf_hits:
                continue
            if len(text_hits) != 1 or len(pdf_hits) != 1:
                raise RuntimeError("File-picker markers must each occur exactly once")
            text_index, pdf_index = text_hits[0], pdf_hits[0]
            if text_index >= pdf_index:
                raise RuntimeError("File-picker markers are in the wrong order")
            if not _row_ids_are_durable(rows):
                raise RuntimeError("Canonical durable row identities invalid")
            text_ack = _exact_turn(rows, text_index, pdf_index)
            pdf_ack = _exact_turn(rows, pdf_index, len(rows))

            text_row = rows[text_index]
            pdf_row = rows[pdf_index]
            text_path = _owned_reference(
                _text(text_row), "@file:", stock.RUNTIME / "home" / "attachments"
            )
            image_path = _owned_reference(
                _text(pdf_row), "@image:", stock.RUNTIME / "home" / "images",
                None
            )
            if image_path.suffix.lower() != ".png":
                raise RuntimeError("Canonical PDF page reference is not a PNG image")

            file_response = await client.get("/api/files/read", params={"path": str(text_path)})
            if file_response.status_code != 200:
                raise RuntimeError("Authenticated text file read failed")
            file_payload = file_response.json()
            text_bytes = _decode_data_url(
                file_payload, expected_mime="text/plain", expected_bytes=FILE_PICKER_TEXT_BYTES
            )
            if file_payload.get("path") != str(text_path) or file_payload.get("size") != len(text_bytes):
                raise RuntimeError("Authenticated text file metadata mismatch")

            media_response = await client.get("/api/media", params={"path": str(image_path)})
            if media_response.status_code != 200:
                raise RuntimeError("Authenticated PDF page read failed")
            image_bytes = _decode_data_url(media_response.json(), expected_mime="image/png")
            matches.append({
                "canonical_session_id": canonical_session_id,
                "text_user_row_id": text_row["id"],
                "text_terminal_row_id": rows[text_ack]["id"],
                "pdf_user_row_id": pdf_row["id"],
                "pdf_terminal_row_id": rows[pdf_ack]["id"],
                "row_count": len(rows),
                "text_file_reference_count": 1,
                "pdf_image_reference_count": 1,
                "text_contents_exact": True,
                "pdf_one_page_image": True,
                "authenticated_text_read": True,
                "authenticated_pdf_image_read": True,
                "text_bytes": len(text_bytes),
                "pdf_image_bytes": len(image_bytes),
            })
    if len(matches) != 1:
        raise RuntimeError("File-picker markers must identify one disposable conversation")
    return matches[0]


async def check(marker, check_media=False):
    credentials = json.loads((stock.RUNTIME / "credentials.json").read_text())
    matches = []
    async with _authenticated(credentials) as (client, _):
        response = await client.get("/api/profiles/sessions", params={
            "profile": "default", "limit": 20, "offset": 0, "order": "recent",
        })
        if response.status_code != 200:
            raise RuntimeError("Disposable session discovery failed")
        discovery = response.json()
        if not isinstance(discovery, dict):
            raise RuntimeError("Unexpected disposable discovery response")
        sessions = discovery.get("sessions")
        if not isinstance(sessions, list) or len(sessions) > 20:
            raise RuntimeError("Unexpected bounded discovery response")
        for session in sessions:
            if not isinstance(session, dict):
                raise RuntimeError("Unexpected disposable session record")
            stored_id = session.get("id")
            if not isinstance(stored_id, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", stored_id):
                raise RuntimeError("Unexpected disposable session identity")
            response = await client.get(
                f"/api/sessions/{quote(stored_id, safe='')}/messages",
                params={"profile": "default", "include_compacted": "true",
                        "order": "latest", "limit": 100, "offset": 0},
            )
            if response.status_code != 200:
                raise RuntimeError("Disposable canonical read failed")
            payload = response.json()
            if not isinstance(payload, dict):
                raise RuntimeError("Canonical response malformed")
            canonical_session_id = payload.get("session_id")
            if not isinstance(canonical_session_id, str) or not canonical_session_id.strip():
                raise RuntimeError("Canonical session ID missing")
            rows = payload.get("messages")
            if not isinstance(rows, list):
                raise RuntimeError("Canonical messages missing")
            if any(not isinstance(row, dict) for row in rows):
                raise RuntimeError("Canonical messages malformed")
            hits = [i for i, row in enumerate(rows)
                    if row.get("role") == "user"
                    and _text(row).split("\n", 1)[0] == marker]
            if not hits:
                continue
            if len(hits) != 1 or hits[0] + 1 != len(rows) - 1:
                raise RuntimeError("Native marker is duplicated or not the final turn")
            row = rows[hits[0]]
            terminal = rows[-1]
            if terminal.get("role") != "assistant" or _text(terminal) != "SEMREH_SLICE1_ACK":
                raise RuntimeError("Native attachment terminal ACK missing")
            ids = [str(item.get("id")) for item in rows]
            if any(item.get("id") is None for item in rows) or len(set(ids)) != len(ids):
                raise RuntimeError("Canonical durable row identities invalid")
            references = _text(row).split("\n")[1:]
            image_prefix = "@image:" + str(stock.RUNTIME / "home/images") + "/"
            if len(references) != 1 or not references[0].startswith(image_prefix):
                raise RuntimeError("Expected one owned canonical image reference")
            media_evidence = {}
            if check_media:
                path = references[0].removeprefix("@image:")
                # The exact synthetic UI row owns this path; never probe other
                # host files or infer a path from a display filename.
                from pathlib import Path
                owned_images = (stock.RUNTIME / "home/images").resolve()
                if not Path(path).resolve().is_relative_to(owned_images):
                    raise RuntimeError("Canonical image escaped the owned fixture")
                decoded = []
                for route in ("/api/media", "/api/files/read"):
                    media_response = await client.get(route, params={"path": path})
                    if media_response.status_code != 200:
                        raise RuntimeError("Owned native media route failed")
                    media_payload = media_response.json()
                    data_url = media_payload.get("data_url") if isinstance(media_payload, dict) else None
                    if not isinstance(data_url, str) or len(data_url) > 2 * 1024 * 1024:
                        raise RuntimeError("Synthetic media response malformed or oversized")
                    header, separator, encoded = data_url.partition(",")
                    if not separator or not header.startswith("data:image/") or not header.endswith(";base64"):
                        raise RuntimeError("Synthetic media data URL malformed")
                    content = base64.b64decode(encoded, validate=True)
                    if not content:
                        raise RuntimeError("Synthetic image bytes empty")
                    decoded.append(content)
                    if route == "/api/files/read":
                        if media_payload.get("path") != path or media_payload.get("size") != len(content):
                            raise RuntimeError("Managed image metadata mismatch")
                if decoded[0] != decoded[1]:
                    raise RuntimeError("Stock media routes disagree on image bytes")
                media_evidence = {"authenticated_media_read": True,
                                  "authenticated_managed_file_read": True,
                                  "matching_decoded_bytes": len(decoded[0])}
            matches.append({"canonical_session_id": canonical_session_id.strip(),
                            "user_row_id": row["id"], "terminal_row_id": terminal["id"],
                            "row_count": len(rows), "image_reference_count": 1,
                            **media_evidence})
    if len(matches) != 1:
        raise RuntimeError("Exact native marker must identify one disposable conversation")
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--marker")
    parser.add_argument("--file-picker-text-marker")
    parser.add_argument("--file-picker-pdf-marker")
    parser.add_argument("--output", required=True)
    parser.add_argument("--check-media", action="store_true")
    args = parser.parse_args()
    old_mode = args.marker is not None
    picker_mode = args.file_picker_text_marker is not None or args.file_picker_pdf_marker is not None
    if old_mode == picker_mode:
        parser.error("Provide either --marker or both file-picker markers")
    if args.check_media and picker_mode:
        parser.error("--check-media is only valid with --marker")
    if old_mode:
        if not re.fullmatch(r"SEMREH_SLICE3_ATTACHMENT_UI_PROMPT_[A-Fa-f0-9-]{36}", args.marker):
            parser.error("Expected the synthetic UI test's UUID marker")
    elif not (args.file_picker_text_marker and args.file_picker_pdf_marker):
        parser.error("File-picker mode requires both text and PDF markers")
    elif not FILE_PICKER_TEXT_MARKER.fullmatch(args.file_picker_text_marker):
        parser.error("Expected the synthetic Files-picker text UUID marker")
    elif not FILE_PICKER_PDF_MARKER.fullmatch(args.file_picker_pdf_marker):
        parser.error("Expected the synthetic Files-picker PDF UUID marker")
    output = _output_path(args.output)
    stock.validate()
    if old_mode:
        result = asyncio.run(check(args.marker, args.check_media))
        evidence = {"outcome": "passed", "backend_sha": stock.PIN,
                    "marker": args.marker, **result}
        print("Native attachment canonical check passed")
    else:
        result = asyncio.run(check_file_picker(
            args.file_picker_text_marker, args.file_picker_pdf_marker
        ))
        evidence = {"outcome": "passed", "backend_sha": stock.PIN,
                    "text_marker": args.file_picker_text_marker,
                    "pdf_marker": args.file_picker_pdf_marker, **result}
        print("Native Files-picker canonical check passed")
    output.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
