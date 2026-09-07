#!/usr/bin/env python3
"""Read-only canonical complement to the production attachment UI test.

Searches at most 20 recent conversations in the guarded disposable fixture.
Only the exact UUID-tagged UI marker is accepted; no raw response/auth data is
written to evidence. This does not claim rendered media or device acceptance.
"""
import argparse
import asyncio
import base64
import json
import re
from urllib.parse import quote

import direct_hermes_probe as stock
from direct_hermes_attachment_probe import _authenticated, _output_path, _text


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
    parser.add_argument("--marker", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--check-media", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"SEMREH_SLICE3_ATTACHMENT_UI_PROMPT_[A-Fa-f0-9-]{36}", args.marker):
        parser.error("Expected the synthetic UI test's UUID marker")
    output = _output_path(args.output)
    stock.validate()
    result = asyncio.run(check(args.marker, args.check_media))
    output.write_text(json.dumps({"outcome": "passed", "backend_sha": stock.PIN,
                                  "marker": args.marker, **result}, indent=2) + "\n")
    print("Native attachment canonical check passed")


if __name__ == "__main__":
    main()
