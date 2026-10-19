from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import socket
from pathlib import Path
from urllib.parse import urlsplit

from aiohttp import web

from .delivery import APNs, Scheduler
from .gateway import Gateway
from .service import Service, app_for
from .store import Store
from .tunnel import Tunnel


def secret(name: str) -> str:
    path = os.environ.get(name + "_FILE")
    if path:
        source = Path(path)
        if source.stat().st_mode & 0o077:
            raise ValueError(name + "_FILE must be readable only by its owner")
        return source.read_text().strip()
    value = os.environ.get(name, "")
    if not value:
        raise ValueError(name + "_FILE is required")
    return value


def main():
    parser = argparse.ArgumentParser(description="Pair your phone with one official Hermes profile")
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("serve")
    invite = commands.add_parser("invite")
    invite.add_argument("--url", required=True, help="Direct or relay base URL before /v1")
    invite.add_argument("--output", required=True, help="Write one-use invitation JSON to this private file")
    args = parser.parse_args()
    profile = os.environ.get("COMPANION_PROFILE", "")
    state = os.environ.get("COMPANION_STATE", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", profile) or not state:
        parser.error("Set COMPANION_PROFILE and COMPANION_STATE explicitly")
    try:
        if args.action == "invite":
            url = urlsplit(args.url)
            if url.scheme != "https" and not (url.scheme == "http" and url.hostname in {"localhost", "127.0.0.1", "::1"}):
                parser.error("Remote pairing requires HTTPS")
            if url.query or url.fragment or url.username or url.path.rstrip("/").endswith("/v1"):
                parser.error("Use a base URL before /v1 without credentials or query parameters")
            store = Store(state, profile, recover=False)
            try:
                invitation = {"version": 1, "url": args.url.rstrip("/"), "code": store.invite()}
                destination = Path(args.output)
                destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(descriptor, "w") as handle:
                    os.fchmod(handle.fileno(), 0o600)
                    json.dump(invitation, handle)
                    handle.write("\n")
                print("Pairing invitation written. It expires in ten minutes.")
            finally:
                store.close()
            return
        Path(state).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock = open(state + ".lock", "a")
        os.chmod(state + ".lock", 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("A Companion process already owns this state store")
        store = Store(state, profile)
        gateway = Gateway(os.environ.get("COMPANION_GATEWAY_URL", "http://127.0.0.1:19219"), secret("COMPANION_GATEWAY_TOKEN"), profile, store.cursor_key)
        apns = None
        if os.environ.get("COMPANION_APNS_KEY_FILE"):
            apns = APNs(os.environ["COMPANION_APNS_KEY_FILE"], os.environ["COMPANION_APNS_KEY_ID"], os.environ["COMPANION_APNS_TEAM_ID"], os.environ["COMPANION_APNS_TOPIC"])
        scheduler = None
        if os.environ.get("COMPANION_SCHEDULER") == "owned":
            command = json.loads(os.environ.get("COMPANION_HERMES_COMMAND", '["hermes"]'))
            if not isinstance(command, list) or not command or not all(isinstance(part, str) for part in command):
                parser.error("COMPANION_HERMES_COMMAND must be a JSON argument list")
            scheduler = Scheduler(gateway, command, os.environ.get("COMPANION_HERMES_CWD"))
        service = Service(gateway, store, os.environ.get("COMPANION_NAME", socket.gethostname()), apns, scheduler)
        if os.environ.get("COMPANION_RELAY_URL"):
            service.relay = Tunnel(service, os.environ["COMPANION_RELAY_URL"], os.environ["COMPANION_RELAY_HOST"], secret("COMPANION_RELAY_TOKEN"))
        bind = os.environ.get("COMPANION_BIND", "127.0.0.1")
        if bind not in {"127.0.0.1", "::1", "localhost"}:
            parser.error("Companion direct HTTP binds to loopback. Use the outbound TLS relay for remote access")
        web.run_app(app_for(service), host=bind, port=int(os.environ.get("COMPANION_PORT", "19220")), access_log=None, print=None)
        lock.close()
    except (ValueError, KeyError, OSError) as error:
        parser.exit(2, "Companion configuration is invalid. Check the required environment and private credential files.\n")


if __name__ == "__main__":
    main()
