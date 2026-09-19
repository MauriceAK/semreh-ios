"""Pure tests for the bounded queued-steer probe helpers."""

from __future__ import annotations

import asyncio
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import direct_hermes_steer_probe as probe
from direct_hermes_steer_probe import (
    ORIGINAL_PROMPT,
    STOCK_PIN,
    STEER_PROMPT,
    WARMUP_PROMPT,
    _assert_durable_rows,
    _close_owned,
    _wait_normal_terminal,
    select_fixture,
)


def _rows(prompts: list[str]) -> list[dict]:
    return [
            item
            for prompt in prompts
            for item in (
                {"role": "user", "content": prompt},
                {"role": "assistant", "content": "SEMREH_SLICE1_ACK"},
            )
    ]


class _BufferedProbe:
    def __init__(self) -> None:
        self.frames = [
            {"params": {"type": "message.complete", "session_id": "r", "payload": {"status": "complete"}}},
            {"params": {"type": "message.complete", "session_id": "r", "payload": {"status": "complete"}}},
        ]

    async def wait_terminal(self, session_id: str, start: int) -> dict:
        for frame in self.frames[start:]:
            params = frame["params"]
            if params["session_id"] == session_id:
                return frame
        raise AssertionError("buffer did not contain a terminal")


class _OpenSocket:
    def __init__(self) -> None:
        self.open = False

    async def __aenter__(self):
        self.open = True
        return self

    async def __aexit__(self, exc_type, exc, tb):
        self.open = False


class _CloseProbe:
    def __init__(self, socket: _OpenSocket) -> None:
        self.socket = socket
        self.calls: list[str] = []

    async def rpc(self, method: str, params: dict) -> dict:
        if not self.socket.open:
            raise AssertionError("close RPC ran after the WebSocket context ended")
        self.calls.append(params["session_id"])
        return {"closed": True}


class SteerProbeHelperTests(unittest.TestCase):
    def test_run_validates_selected_backend_before_credentials_or_network(self) -> None:
        async def no_exercise(*_args, **_kwargs) -> None:
            return None

        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary)
            (runtime / "credentials.json").write_text("{}", encoding="utf-8")
            for stock, backend_sha in ((True, probe.STOCK_PIN), (False, "dev-sha")):
                fixture = SimpleNamespace(
                    runtime=runtime,
                    stock=stock,
                    backend_sha=backend_sha,
                    origin="https://fixture.test",
                )
                with self.subTest(stock=stock), \
                        patch.object(probe, "select_fixture", return_value=fixture), \
                        patch.object(probe.stock_probe, "validate") as stock_validate, \
                        patch.object(probe, "_validate_all") as development_validate, \
                        patch.object(probe, "_config_hash", return_value="same"), \
                        patch.object(probe, "_exercise", new=no_exercise), \
                        patch.object(probe, "_persist_failure"):
                    asyncio.run(probe._run(runtime / "evidence.json", backend_sha, stock_backend=stock))
                if stock:
                    stock_validate.assert_called_once_with()
                    development_validate.assert_not_called()
                else:
                    stock_validate.assert_not_called()
                    development_validate.assert_called_once_with(backend_sha)

    def test_run_validation_failure_prevents_credential_read_and_exercise(self) -> None:
        fixture = SimpleNamespace(
            runtime=Path("/private/nonexistent/steer-fixture"),
            stock=True,
            backend_sha=probe.STOCK_PIN,
            origin="https://fixture.test",
        )
        async def should_not_exercise(*_args, **_kwargs) -> None:
            self.fail("exercise must not run after fixture validation fails")

        with patch.object(probe, "select_fixture", return_value=fixture), \
                patch.object(probe.stock_probe, "validate", side_effect=RuntimeError("invalid fixture")), \
                patch.object(probe.Path, "read_text") as read_text, \
                patch.object(probe, "_exercise", new=should_not_exercise):
            with self.assertRaisesRegex(RuntimeError, "invalid fixture"):
                asyncio.run(probe._run(Path("/private/nonexistent/evidence.json"), stock_backend=True))
        read_text.assert_not_called()

    def test_stock_backend_fixture_is_explicitly_baseline_scoped(self) -> None:
        fixture = select_fixture(stock_backend=True, backend_sha=None)
        self.assertTrue(fixture.stock)
        self.assertEqual(fixture.backend_sha, STOCK_PIN)

    def test_warmup_does_not_require_steer_but_final_snapshot_does(self) -> None:
        _assert_durable_rows(_rows([WARMUP_PROMPT]), [WARMUP_PROMPT])
        with self.assertRaises(AssertionError):
            _assert_durable_rows(
                _rows([WARMUP_PROMPT]),
                [WARMUP_PROMPT],
                require_steer=True,
            )
        _assert_durable_rows(
            _rows([WARMUP_PROMPT, ORIGINAL_PROMPT, STEER_PROMPT]),
            [WARMUP_PROMPT, ORIGINAL_PROMPT, STEER_PROMPT],
            require_steer=True,
        )

    def test_buffered_second_terminal_advances_from_matching_frame(self) -> None:
        async def run() -> None:
            probe = _BufferedProbe()
            first = await _wait_normal_terminal(probe, "r", 0)
            second = await _wait_normal_terminal(probe, "r", first)
            self.assertEqual(first, 1)
            self.assertEqual(second, 2)

        asyncio.run(run())

    def test_failed_body_closes_owned_runtime_while_socket_is_open(self) -> None:
        async def run() -> None:
            socket = _OpenSocket()
            probe = _CloseProbe(socket)
            owned = {"runtime-b", "runtime-a"}
            errors: list[dict[str, str]] = []
            async with socket:
                with self.assertRaises(RuntimeError):
                    try:
                        raise RuntimeError("synthetic body failure")
                    finally:
                        await _close_owned(probe, owned, errors)
            self.assertEqual(probe.calls, ["runtime-a", "runtime-b"])
            self.assertEqual(errors, [])

        asyncio.run(run())


if __name__ == "__main__":
    unittest.main()
