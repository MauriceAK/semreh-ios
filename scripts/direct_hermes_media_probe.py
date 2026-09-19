#!/usr/bin/env python3
"""Bounded authenticated GET /api/media probe against the pinned fixture.

This probe uses only the disposable stock fixture validated by
``direct_hermes_probe``. It creates one unique tiny PNG under that fixture's
guarded ``home/images`` directory and deliberately retains it for inspection.
No WebSocket, provider, backend configuration, or personal Hermes route is
used.
"""

import asyncio
import base64
from contextlib import asynccontextmanager
import json
import os
from pathlib import Path
import secrets

import httpx

import direct_hermes_probe as stock_probe


TIMEOUT = httpx.Timeout(10.0, connect=5.0)
_PNG_BYTES = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk"
    "YAAAAAYAAjCB0C8AAAAASUVORK5CYII="
)


def _guarded_images_dir() -> Path:
    """Return the disposable media root after rejecting symlinked parents."""
    home = stock_probe.RUNTIME / "home"
    if home.is_symlink() or home.resolve() != home or not home.is_dir():
        raise RuntimeError("Disposable Hermes home is not a guarded directory")
    images = home / "images"
    if images.exists():
        if images.is_symlink() or images.resolve() != images or not images.is_dir():
            raise RuntimeError("Disposable media directory is not a guarded directory")
    else:
        images.mkdir(mode=0o700)
    if images.is_symlink() or images.resolve() != images:
        raise RuntimeError("Disposable media directory changed unexpectedly")
    return images


def _write_retained_fixture() -> tuple[Path, bytes]:
    images = _guarded_images_dir()
    name = f"semreh-media-probe-{secrets.token_hex(12)}.png"
    path = images / name
    if path.parent != images or path.is_symlink() or path.resolve() != path:
        raise RuntimeError("Synthetic media path escaped its guarded parent")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(_PNG_BYTES)
    if path.is_symlink() or path.resolve() != path or path.read_bytes() != _PNG_BYTES:
        raise RuntimeError("Retained synthetic media fixture failed validation")
    return path, _PNG_BYTES


@asynccontextmanager
async def _authenticated(credentials: dict):
    async with httpx.AsyncClient(
        base_url=stock_probe.HTTPS_ORIGIN,
        trust_env=False,
        follow_redirects=False,
        timeout=TIMEOUT,
    ) as client:
        login = await client.post("/auth/password-login", json={
            "provider": "basic", **credentials, "next": "",
        })
        if login.status_code not in (200, 302, 303):
            raise RuntimeError("fixture login failed")
        try:
            yield client
        finally:
            logout = await client.post("/auth/logout")
            if logout.status_code != 302 or logout.headers.get("location") != "/login":
                raise RuntimeError("fixture logout failed")


async def _run() -> dict:
    # This validates the pinned source/runtime configuration only; live listener
    # identity is externally attested by the bounded operator run.
    stock_probe.validate()
    credentials = json.loads((stock_probe.RUNTIME / "credentials.json").read_text(encoding="utf-8"))
    image_path, image_bytes = _write_retained_fixture()
    checks = []

    async with _authenticated(credentials) as client:
        authenticated = await client.get("/api/media", params={"path": str(image_path)})
        if authenticated.status_code != 200:
            raise RuntimeError("authenticated media request failed")
        payload = authenticated.json()
        data_url = payload.get("data_url") if isinstance(payload, dict) else None
        prefix = "data:image/png;base64,"
        if not isinstance(data_url, str) or not data_url.startswith(prefix):
            raise RuntimeError("media response omitted a PNG data URL")
        try:
            decoded = base64.b64decode(data_url[len(prefix):], validate=True)
        except (ValueError, TypeError):
            raise RuntimeError("media response contained invalid base64") from None
        if decoded != image_bytes:
            raise RuntimeError("media data URL bytes differed from the retained fixture")
        checks.append("authenticated data_url bytes match retained PNG")

        unsupported = await client.get(
            "/api/media", params={"path": str(image_path.with_suffix(".txt"))}
        )
        if unsupported.status_code != 415:
            raise RuntimeError("unsupported media extension was not rejected")
        checks.append("unsupported extension rejected with 415")

        outside = stock_probe.RUNTIME / "tools" / f"semreh-media-outside-{secrets.token_hex(8)}.png"
        outside_response = await client.get("/api/media", params={"path": str(outside)})
        if outside_response.status_code != 403:
            raise RuntimeError("outside-root media path was not rejected")
        checks.append("outside media root rejected with 403")

    async with httpx.AsyncClient(
        base_url=stock_probe.HTTPS_ORIGIN,
        trust_env=False,
        follow_redirects=False,
        timeout=TIMEOUT,
    ) as unauthenticated_client:
        unauthenticated = await unauthenticated_client.get(
            "/api/media", params={"path": str(image_path)}
        )
    if unauthenticated.status_code != 401:
        raise RuntimeError("unauthenticated media request was not rejected")
    checks.append("unauthenticated media request rejected with 401")

    return {
        "outcome": "passed",
        "source_pin": stock_probe.PIN,
        "checks": checks,
        "retained_fixture": True,
        "retained_fixture_path": str(image_path.relative_to(stock_probe.RUNTIME)),
        "fixture_bytes": len(image_bytes),
        "fixture_extension": image_path.suffix,
        "secrets_or_auth_payloads_printed": False,
    }


def main() -> None:
    try:
        result = asyncio.run(_run())
    except Exception as error:
        print(json.dumps({
            "outcome": "failed",
            "error_type": type(error).__name__,
            "secrets_or_auth_payloads_printed": False,
        }, sort_keys=True))
        raise SystemExit(1) from None
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
