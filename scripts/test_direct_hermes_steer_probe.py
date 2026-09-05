"""Pure tests for the bounded queued-steer probe helpers."""

from __future__ import annotations

import asyncio
import unittest

from direct_hermes_steer_probe import (
    ORIGINAL_PROMPT,
    STEER_PROMPT,
    WARMUP_PROMPT,
    _assert_durable_rows,
    _close_owned,
    _wait_normal_terminal,
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
