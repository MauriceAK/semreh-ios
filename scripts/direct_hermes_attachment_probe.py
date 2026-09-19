#!/usr/bin/env python3
"""Bounded stock HTTPS/WebSocket attachment-contract probe.

Uses only the exact pinned disposable fixture and official gateway RPCs. The
probe keeps raw frames, credentials, tickets, and backend error payloads out of
evidence; it stages only synthetic PNG/text/PDF bytes and never edits backend
configuration or personal Hermes state.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import binascii
from contextlib import asynccontextmanager
import json
from pathlib import Path
import struct
import time
import uuid
import zlib

import httpx
from websockets.asyncio.client import connect

from direct_hermes_capture import write_fixture
import direct_hermes_probe as stock_probe


EVIDENCE_ROOT = Path("/Users/maurice/workspace/semreh-slice1-evidence")
PROFILE = "default"
RPC_TIMEOUT = 35.0
TURN_TIMEOUT = 55.0
HTTP_TIMEOUT = httpx.Timeout(10.0, connect=5.0)
IMAGE_CAP_BYTES = 25 * 1024 * 1024
PDF_CAP_BYTES = 50 * 1024 * 1024
PDF_CAP_PAGES = 25
TEXT_BYTES = b"Semreh attachment probe text/code fixture\n"


def _png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)
    )


def _make_png() -> bytes:
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
    scanline = b"\x00\x00\x00\x00\x00"  # filter byte + one transparent RGBA pixel
    return b"\x89PNG\r\n\x1a\n" + _png_chunk(b"IHDR", ihdr) + _png_chunk(
        b"IDAT", zlib.compress(scanline)
    ) + _png_chunk(b"IEND", b"")


PNG_BYTES = _make_png()


def _output_path(raw: str) -> Path:
    path = Path(raw)
    if not path.is_absolute() or path.is_symlink() or path.exists():
        raise RuntimeError("Evidence output must be a new absolute non-symlink path")
    if path.parent.resolve() != EVIDENCE_ROOT.resolve():
        raise RuntimeError("Evidence output must be directly under the evidence root")
    return path


def _source_contract() -> dict:
    methods = stock_probe.SOURCE / "tui_gateway" / "methods_prompt.py"
    server = stock_probe.SOURCE / "tui_gateway" / "server.py"
    for path in (methods, server):
        if path.is_symlink() or path.resolve() != path or not path.is_file():
            raise RuntimeError("Pinned attachment source path is not ordinary")
    method_text = methods.read_text(encoding="utf-8")
    server_text = server.read_text(encoding="utf-8")
    required_methods = ("image.attach_bytes", "file.attach", "pdf.attach", "image.detach")
    if any(f'@method("{name}")' not in method_text for name in required_methods):
        raise RuntimeError("Pinned source attachment RPC contract is incomplete")
    required_limits = (
        "_ATTACH_BYTES_MAX_BYTES = 25 * 1024 * 1024",
        "_PDF_ATTACH_MAX_BYTES = 50 * 1024 * 1024",
        "_PDF_ATTACH_MAX_PAGES = 25",
    )
    if any(value not in server_text for value in required_limits):
        raise RuntimeError("Pinned source attachment limits changed")
    if "def _sanitize_attachment_name" not in server_text:
        raise RuntimeError("Pinned source filename sanitization is missing")
    return {
        "rpc_methods": list(required_methods),
        "image_cap_bytes": IMAGE_CAP_BYTES,
        "pdf_cap_bytes": PDF_CAP_BYTES,
        "pdf_cap_pages": PDF_CAP_PAGES,
        "filename_sanitization_source_checked": True,
    }


def _tiny_pdf() -> bytes:
    """Build one blank, valid PDF page without reading/writing a local file."""
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] /Resources << >> /Contents 4 0 R >>",
        b"<< /Length 4 >>\nstream\nq\nQ\nendstream",
    ]
    result = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for index, body in enumerate(objects, start=1):
        offsets.append(len(result))
        result.extend(f"{index} 0 obj\n".encode("ascii"))
        result.extend(body)
        result.extend(b"\nendobj\n")
    xref = len(result)
    result.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    result.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        result.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    result.extend(
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref}\n%%EOF\n".encode("ascii")
    )
    return bytes(result)


def _validate_png_bytes(payload: bytes) -> None:
    """Decode the tiny PNG with standard-library parsing before any RPC."""
    if payload[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError("synthetic PNG signature invalid")
    offset = 8
    idat = bytearray()
    saw_iend = False
    width = height = bit_depth = color_type = None
    while offset + 12 <= len(payload):
        length = struct.unpack(">I", payload[offset : offset + 4])[0]
        chunk_type = payload[offset + 4 : offset + 8]
        start = offset + 8
        end = start + length
        if end + 4 > len(payload):
            raise RuntimeError("synthetic PNG chunk truncated")
        chunk = payload[start:end]
        expected_crc = struct.unpack(">I", payload[end : end + 4])[0]
        if binascii.crc32(chunk_type + chunk) & 0xFFFFFFFF != expected_crc:
            raise RuntimeError("synthetic PNG chunk CRC invalid")
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", chunk[:10])
        elif chunk_type == b"IDAT":
            idat.extend(chunk)
        elif chunk_type == b"IEND":
            saw_iend = True
            break
        offset = end + 4
    if (width, height, bit_depth, color_type) != (1, 1, 8, 6) or not saw_iend:
        raise RuntimeError("synthetic PNG metadata invalid")
    if zlib.decompress(bytes(idat)) != b"\x00\x00\x00\x00\x00":
        raise RuntimeError("synthetic PNG pixel decode invalid")


def _text(row: dict) -> str:
    content = row.get("content")
    if isinstance(content, list):
        return " ".join(str(part.get("text", "")) for part in content if isinstance(part, dict))
    return str(content or row.get("display_content") or "")


def _phase(evidence: dict, value: str) -> None:
    evidence["phase"] = value


class RPCError(Exception):
    def __init__(self, code: int | None):
        self.code = code


class RPC:
    def __init__(self, websocket):
        self.websocket = websocket
        self.next_id = 1
        self.frames_seen = 0
        self.pending = []

    async def _receive(self, deadline: float) -> dict:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("bounded WebSocket deadline expired")
        frame = json.loads(await asyncio.wait_for(self.websocket.recv(), remaining))
        if not isinstance(frame, dict):
            raise RuntimeError("gateway frame was not an object")
        self.frames_seen += 1
        return frame

    async def call(self, method: str, params: dict) -> object:
        request_id = self.next_id
        self.next_id += 1
        await self.websocket.send(json.dumps({
            "jsonrpc": "2.0", "id": request_id, "method": method, "params": params,
        }))
        deadline = time.monotonic() + RPC_TIMEOUT
        while True:
            frame = await self._receive(deadline)
            if frame.get("id") != request_id:
                self.pending.append(frame)
                continue
            if "error" in frame:
                error = frame.get("error") or {}
                raise RPCError(error.get("code"))
            return frame.get("result")

    async def error_code(self, method: str, params: dict) -> int:
        request_id = self.next_id
        self.next_id += 1
        await self.websocket.send(json.dumps({
            "jsonrpc": "2.0", "id": request_id, "method": method, "params": params,
        }))
        deadline = time.monotonic() + RPC_TIMEOUT
        while True:
            frame = await self._receive(deadline)
            if frame.get("id") != request_id:
                self.pending.append(frame)
                continue
            error = frame.get("error")
            if not isinstance(error, dict) or not isinstance(error.get("code"), int):
                raise RuntimeError(f"{method} returned an unclassified RPC error")
            return error["code"]

    async def expect_error_code(self, method: str, params: dict, expected: int) -> None:
        if await self.error_code(method, params) != expected:
            raise RuntimeError(f"{method} returned an unexpected categorical error")

    async def wait_terminal(self, session_id: str) -> None:
        deadline = time.monotonic() + TURN_TIMEOUT
        while True:
            for index, frame in enumerate(self.pending):
                params = frame.get("params") or {}
                if params.get("type") == "message.complete" and params.get("session_id") == session_id:
                    self.pending.pop(index)
                    payload = params.get("payload") or {}
                    if payload.get("status") == "error":
                        raise RuntimeError("deterministic provider turn failed")
                    return
            frame = await self._receive(deadline)
            params = frame.get("params") or {}
            if params.get("type") != "message.complete" or params.get("session_id") != session_id:
                self.pending.append(frame)
                continue
            payload = params.get("payload") or {}
            if payload.get("status") == "error":
                raise RuntimeError("deterministic provider turn failed")
            return

    async def wait_idle(self, session_id: str) -> None:
        deadline = time.monotonic() + TURN_TIMEOUT
        while True:
            status = await self.call("session.status", {"session_id": session_id})
            if "Agent Running: No" in str((status or {}).get("output", "")):
                return
            if time.monotonic() >= deadline:
                raise TimeoutError("deterministic provider remained busy")
            await asyncio.sleep(0.25)


@asynccontextmanager
async def _authenticated(credentials: dict):
    async with httpx.AsyncClient(
        base_url=stock_probe.HTTPS_ORIGIN,
        trust_env=False,
        follow_redirects=False,
        timeout=HTTP_TIMEOUT,
    ) as client:
        login = await client.post("/auth/password-login", json={
            "provider": "basic", **credentials, "next": "",
        })
        if login.status_code not in (200, 302, 303):
            raise RuntimeError("fixture login failed")
        try:
            ticket_response = await client.post("/api/auth/ws-ticket")
            if ticket_response.status_code != 200:
                raise RuntimeError("fixture ticket request failed")
            ticket = ticket_response.json().get("ticket")
            if not isinstance(ticket, str) or not ticket:
                raise RuntimeError("fixture ticket missing")
            yield client, ticket
        finally:
            logout = await client.post("/auth/logout")
            if logout.status_code != 302 or logout.headers.get("location") != "/login":
                raise RuntimeError("fixture logout failed")


async def _rest_rows(client: httpx.AsyncClient, stored_id: str) -> list[dict]:
    response = await client.get(
        f"/api/sessions/{stored_id}/messages",
        params={"profile": PROFILE, "include_compacted": "true", "order": "oldest", "limit": 100, "offset": 0},
    )
    if response.status_code != 200:
        raise RuntimeError("canonical REST transcript request failed")
    payload = response.json()
    rows = payload.get("messages") if isinstance(payload, dict) else None
    if rows is None and isinstance(payload, dict):
        rows = payload.get("data")
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise RuntimeError("canonical REST transcript rows missing")
    return rows


def _assert_latest_turn(rows: list[dict], marker: str, required: tuple[str, ...]) -> None:
    if len(rows) < 2 or [row.get("role") for row in rows[-2:]] != ["user", "assistant"]:
        raise RuntimeError("canonical transcript did not end in a user/assistant pair")
    user, assistant = rows[-2:]
    user_text = _text(user)
    if marker not in user_text or any(value not in user_text for value in required):
        raise RuntimeError("canonical attachment reference was missing")
    if "SEMREH_SLICE1_ACK" not in _text(assistant):
        raise RuntimeError("deterministic provider ACK missing")


async def _exercise(credentials: dict, evidence: dict) -> None:
    _validate_png_bytes(PNG_BYTES)
    pdf_bytes = _tiny_pdf()
    image_b64 = base64.b64encode(PNG_BYTES).decode("ascii")
    text_b64 = base64.b64encode(TEXT_BYTES).decode("ascii")
    pdf_b64 = base64.b64encode(pdf_bytes).decode("ascii")
    evidence["pdf_dependency"] = {"checked_via_pdf_attach_rpc": True}
    evidence["result_shapes"] = {}
    evidence["categorical_errors"] = {
        "unsupported_image_extension": 4016,
        "pdf_page_cap": 4019,
        "pdf_unavailable": 5028,
    }
    runtime_id = None
    async with _authenticated(credentials) as (client, ticket):
        async with connect(
            stock_probe.HTTPS_ORIGIN.replace("https://", "wss://") + f"/api/ws?ticket={ticket}",
            origin=stock_probe.HTTPS_ORIGIN,
            proxy=None,
        ) as websocket:
            ready = json.loads(await asyncio.wait_for(websocket.recv(), RPC_TIMEOUT))
            if ready.get("params", {}).get("type") != "gateway.ready":
                raise RuntimeError("gateway.ready missing")
            rpc = RPC(websocket)
            _phase(evidence, "session.create")
            created = await rpc.call("session.create", {
                "profile": PROFILE,
                "cwd": str(stock_probe.RUNTIME / "tools"),
                "model": "semreh-fixture",
                "provider": "custom",
            })
            if not isinstance(created, dict):
                raise RuntimeError("session.create returned no object")
            runtime_id = created.get("session_id")
            stored_id = created.get("stored_session_id")
            if not all(isinstance(value, str) and value for value in (runtime_id, stored_id)):
                raise RuntimeError("session.create identity missing")
            try:
                _phase(evidence, "image.failure.baseline_rest")
                before = await client.get(
                    f"/api/sessions/{stored_id}/messages",
                    params={"profile": PROFILE, "include_compacted": "true", "order": "oldest", "limit": 100, "offset": 0},
                )
                if before.status_code != 404:
                    raise RuntimeError("fresh draft unexpectedly had durable rows")
                _phase(evidence, "image.failure.unsupported_extension")
                await rpc.expect_error_code("image.attach_bytes", {
                    "session_id": runtime_id,
                    "content_base64": image_b64,
                    "filename": "not-an-image.exe",
                }, 4016)
                after = await client.get(
                    f"/api/sessions/{stored_id}/messages",
                    params={"profile": PROFILE, "include_compacted": "true", "order": "oldest", "limit": 100, "offset": 0},
                )
                if after.status_code != 404:
                    raise RuntimeError("failed attachment changed the unpersisted draft")
                evidence["checks"].append("unsupported image stage failed before durable submit")

                _phase(evidence, "image.attach_bytes.success")
                image = await rpc.call("image.attach_bytes", {
                    "session_id": runtime_id,
                    "content_base64": image_b64,
                    "filename": "camera-shot.png",
                })
                if not isinstance(image, dict) or image.get("attached") is not True:
                    raise RuntimeError("image.attach_bytes did not attach")
                image_path = image.get("path")
                if not isinstance(image_path, str) or not image_path.endswith(".png"):
                    raise RuntimeError("image attachment reference metadata missing")
                required_image_keys = {"attached", "path", "count", "remainder", "text", "bytes"}
                if not required_image_keys.issubset(image):
                    raise RuntimeError("image attachment result shape is incomplete")
                image_name = image.get("name")
                if not isinstance(image_name, str):
                    raise RuntimeError("image attachment name metadata missing")
                evidence["result_shapes"]["image.attach_bytes"] = {
                    "keys": sorted(image),
                    "attached": image.get("attached") is True,
                    "path_reference": {"kind": "generated_gateway_path", "suffix": ".png"},
                    "remainder_empty": image.get("remainder") == "",
                    "text_contains_generated_name": image_name in str(image.get("text", "")),
                    "bytes_is_integer": isinstance(image.get("bytes"), int),
                }
                _phase(evidence, "image.detach.success")
                detached = await rpc.call("image.detach", {"session_id": runtime_id, "path": image_path})
                if not isinstance(detached, dict) or detached.get("detached") is not True:
                    raise RuntimeError("image.detach did not remove staged image")
                if not {"detached", "count"}.issubset(detached) or not isinstance(detached.get("count"), int):
                    raise RuntimeError("image.detach result shape is incomplete")
                evidence["result_shapes"]["image.detach"] = {
                    "keys": sorted(detached),
                    "detached": detached.get("detached") is True,
                    "count_is_integer": isinstance(detached.get("count"), int),
                }
                _phase(evidence, "image.attach_bytes.reattach")
                image = await rpc.call("image.attach_bytes", {
                    "session_id": runtime_id,
                    "content_base64": image_b64,
                    "filename": "camera-shot.png",
                })
                image_path = image.get("path") if isinstance(image, dict) else None
                if not isinstance(image_path, str):
                    raise RuntimeError("image reattach reference missing")
                evidence["checks"].append("image.attach_bytes and image.detach contract")

                file_name = f"../../attachment-probe-{uuid.uuid4().hex}\n.txt"
                expected_file_name = Path(file_name).name.replace("\n", "_")
                _phase(evidence, "file.attach.data_url")
                file_result = await rpc.call("file.attach", {
                    "session_id": runtime_id,
                    "data_url": f"data:text/plain;base64,{text_b64}",
                    "name": file_name,
                })
                if not isinstance(file_result, dict) or file_result.get("attached") is not True:
                    raise RuntimeError("file.attach did not attach")
                if file_result.get("name") != expected_file_name:
                    raise RuntimeError("file.attach filename sanitization differed")
                ref_text = file_result.get("ref_text")
                if not isinstance(ref_text, str) or not ref_text.startswith("@file:"):
                    raise RuntimeError("file.attach ref_text missing")
                ref_path = file_result.get("ref_path")
                if not isinstance(ref_path, str):
                    raise RuntimeError("file.attach ref_path missing")
                workspace = (stock_probe.RUNTIME / "tools").resolve()
                attachments_root = (stock_probe.RUNTIME / "home" / "attachments").resolve()
                if Path(ref_path).is_absolute():
                    if attachments_root not in Path(ref_path).resolve().parents:
                        raise RuntimeError("file.attach absolute ref escaped disposable attachments")
                    ref_path_kind = "profile_home_absolute"
                else:
                    resolved_ref = (workspace / ref_path).resolve()
                    if workspace not in resolved_ref.parents:
                        raise RuntimeError("file.attach relative ref escaped workspace")
                    ref_path_kind = "workspace_relative"
                required_file_keys = {"attached", "name", "path", "ref_path", "ref_text", "uploaded"}
                if not required_file_keys.issubset(file_result):
                    raise RuntimeError("file attachment result shape is incomplete")
                evidence["result_shapes"]["file.attach"] = {
                    "keys": sorted(file_result),
                    "attached": file_result.get("attached") is True,
                    "sanitized_name": file_result.get("name"),
                    "ref_path_kind": ref_path_kind,
                    "ref_text_prefix": "@file:",
                    "uploaded": file_result.get("uploaded") is True,
                }
                evidence["checks"].append("file.attach data_url, sanitized name, and ref_text")

                marker = "SEMREH_ATTACHMENT_PROBE_IMAGE_FILE"
                _phase(evidence, "prompt.submit.image_file")
                await rpc.call("prompt.submit", {"session_id": runtime_id, "text": f"{marker}\n{ref_text}"})
                await rpc.wait_terminal(runtime_id)
                await rpc.wait_idle(runtime_id)
                _phase(evidence, "rest.roundtrip.image_file")
                rows = await _rest_rows(client, stored_id)
                _assert_latest_turn(rows, marker, ("@image:", "@file:"))
                evidence["checks"].append("image/file attachment canonical REST roundtrip")

                _phase(evidence, "pdf.attach.availability")
                try:
                    pdf_result = await rpc.call("pdf.attach", {
                        "session_id": runtime_id,
                        "content_base64": pdf_b64,
                        "filename": "one-page.pdf",
                    })
                    pdf_available = True
                except RPCError as error:
                    if error.code != 5028:
                        raise RuntimeError("pdf.attach returned an unexpected categorical error")
                    pdf_available = False
                    evidence["pdf_dependency"]["availability"] = "unavailable_5028"
                if pdf_available:
                    evidence["pdf_dependency"]["availability"] = "available_via_rpc"
                    _phase(evidence, "pdf.attach.page_cap")
                    await rpc.expect_error_code("pdf.attach", {
                        "session_id": runtime_id,
                        "content_base64": pdf_b64,
                        "filename": "one-page.pdf",
                        "first_page": 1,
                        "last_page": PDF_CAP_PAGES + 1,
                    }, 4019)
                    evidence["checks"].append("pdf page cap rejected without large allocation")
                    if not isinstance(pdf_result, dict) or pdf_result.get("attached") is not True:
                        raise RuntimeError("pdf.attach did not attach")
                    if pdf_result.get("pages_attached") != 1:
                        raise RuntimeError("pdf.attach did not render one page")
                    if not {"attached", "filename", "pages_attached", "pages", "count", "text"}.issubset(pdf_result):
                        raise RuntimeError("PDF attachment result shape is incomplete")
                    pages = pdf_result.get("pages")
                    if not isinstance(pages, list) or len(pages) != 1 or not isinstance(pages[0], dict):
                        raise RuntimeError("PDF page reference metadata is incomplete")
                    if not {"path", "page"}.issubset(pages[0]):
                        raise RuntimeError("PDF page path metadata is incomplete")
                    evidence["result_shapes"]["pdf.attach"] = {
                        "keys": sorted(pdf_result),
                        "attached": pdf_result.get("attached") is True,
                        "filename": pdf_result.get("filename"),
                        "pages_attached": pdf_result.get("pages_attached"),
                        "page_keys": sorted(pages[0]),
                        "page_path_reference": {"kind": "generated_gateway_path", "suffix": ".png"},
                    }
                    marker = "SEMREH_ATTACHMENT_PROBE_PDF"
                    _phase(evidence, "prompt.submit.pdf")
                    await rpc.call("prompt.submit", {"session_id": runtime_id, "text": marker})
                    await rpc.wait_terminal(runtime_id)
                    await rpc.wait_idle(runtime_id)
                    _phase(evidence, "rest.roundtrip.pdf")
                    rows = await _rest_rows(client, stored_id)
                    _assert_latest_turn(rows, marker, ("@image:",))
                    evidence["checks"].append("PDF attachment canonical REST roundtrip")
                else:
                    evidence["checks"].append("PDF availability failure returned 5028")
            finally:
                _phase(evidence, "session.close")
                closed = await rpc.call("session.close", {"session_id": runtime_id})
                if not isinstance(closed, dict) or closed.get("closed") is not True:
                    raise RuntimeError("session.close was not confirmed")
                evidence["result_shapes"]["session.close"] = {
                    "keys": sorted(closed),
                    "closed": closed.get("closed") is True,
                }


async def _run(output: Path) -> dict:
    evidence = {
        "sanitized": True,
        "source_pin": stock_probe.PIN,
        "deployment": "dedicated disposable HTTPS fixture",
        "checks": [],
        "not_verified": [
            "physical iPhone attachment presentation",
            "provider/model vision quality beyond deterministic ACK",
            "cap-sized byte payload allocations intentionally avoided",
        ],
    }
    try:
        stock_probe.validate()
        evidence["source_contract"] = _source_contract()
        credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text(encoding="utf-8"))
        await _exercise(credentials, evidence)
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["outcome"] = "failed"
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError("Attachment probe failed; sanitized evidence retained") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    return evidence


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = _output_path(args.output)
    try:
        evidence = asyncio.run(_run(output))
    except Exception as error:
        print(json.dumps({
            "outcome": "failed",
            "error_type": type(error).__name__,
            "evidence_written": True,
            "secrets_or_auth_payloads_printed": False,
        }, sort_keys=True))
        raise SystemExit(1) from None
    print(json.dumps({
        "outcome": evidence["outcome"],
        "checks": evidence["checks"],
        "source_pin": evidence["source_pin"],
        "evidence_written": True,
        "secrets_or_auth_payloads_printed": False,
    }, sort_keys=True))


if __name__ == "__main__":
    main()
