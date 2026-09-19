"""Pure guard/config tests for the opt-in compression fixture modes."""

from __future__ import annotations

import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import direct_hermes_development as development


BASE_CONFIG = {
    "terminal": {"cwd": "/unrelated/working-directory"},
    "auxiliary": {"background_review": {"enabled": False}},
}
BASE_CREDENTIALS = {"username": "semreh-test", "password": "nonsecret-test"}


def _write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value), encoding="utf-8")
    path.chmod(0o600)


def _materialize_runtime(runtime: Path, mode: str | None, config: dict) -> None:
    runtime.mkdir(mode=0o700)
    for name in development.RUNTIME_DIRS:
        (runtime / name).mkdir(mode=0o700)
    (runtime / "home" / "home").mkdir(mode=0o700)
    (runtime / "home" / "state.db").touch(mode=0o600)
    _write_json(runtime / "credentials.json", BASE_CREDENTIALS)
    _write_json(runtime / "marker.json", development._marker(compression_mode=mode))
    _write_json(runtime / "home" / "config.yaml", config)


class CompressionFixtureTests(unittest.TestCase):
    def test_ordinary_config_only_rehomes_terminal(self) -> None:
        original = copy.deepcopy(BASE_CONFIG)
        actual = development._expected_config(BASE_CONFIG)
        self.assertEqual(BASE_CONFIG, original)
        self.assertEqual(
            actual,
            {
                "terminal": {
                    "cwd": str(development.DEV_RUNTIME / "tools"),
                },
                "auxiliary": {"background_review": {"enabled": False}},
            },
        )
        self.assertEqual(
            development._marker(),
            {
                "marker": development.MARKER,
                "devsource": str(development.DEV_SOURCE),
                "runtime": str(development.DEV_RUNTIME),
                "base_pin": development.BASE_PIN,
                "port": development.PORT,
                "model_port": development.MODEL_PORT,
            },
        )

    def test_both_compression_modes_have_exact_overlay(self) -> None:
        original = copy.deepcopy(BASE_CONFIG)
        for mode, in_place in (("rotate", False), ("in-place", True)):
            actual = development._expected_config(BASE_CONFIG, compression_mode=mode)
            self.assertEqual(actual["terminal"]["cwd"], str(
                development._runtime_for_mode(mode) / "tools"
            ))
            self.assertEqual(
                actual["compression"],
                {
                    "in_place": in_place,
                    "protect_last_n": 2,
                    "min_tail_user_messages": 1,
                    "target_ratio": 0.10,
                },
            )
            self.assertEqual(
                actual["auxiliary"]["compression"],
                {
                    "provider": "custom",
                    "model": "semreh-fixture",
                    "base_url": "http://127.0.0.1:18792/v1",
                    "api_key": development.COMPRESSION_AUX_API_KEY,
                    "timeout": 120,
                    "reasoning_effort": "none",
                    "fallback_chain": [],
                },
            )
            self.assertEqual(actual["auxiliary"]["background_review"], {"enabled": False})
            self.assertEqual(development._port_for_mode(mode), development.COMPRESSION_PORT)
        self.assertEqual(BASE_CONFIG, original)

    def test_wrong_marker_config_and_mode_do_not_fallback(self) -> None:
        with tempfile.TemporaryDirectory(prefix="semreh-compression-guard-") as raw:
            root = Path(raw).resolve()
            normal_runtime = root / "normal"
            rotate_runtime = root / "rotate"
            inplace_runtime = root / "inplace"
            with patch.object(development, "DEV_RUNTIME", normal_runtime), patch.object(
                development, "COMPRESSION_RUNTIME", rotate_runtime
            ), patch.object(development, "IN_PLACE_COMPRESSION_RUNTIME", inplace_runtime):
                normal_config = development._expected_config(BASE_CONFIG)
                _materialize_runtime(normal_runtime, None, normal_config)
                development._validate_runtime(BASE_CONFIG, BASE_CREDENTIALS)

                # The requested compression mode must inspect its own fixed
                # sibling, never silently accept the ordinary runtime.
                with self.assertRaises(RuntimeError):
                    development._validate_runtime(
                        BASE_CONFIG, BASE_CREDENTIALS, compression_mode="rotate"
                    )

                rotate_config = development._expected_config(BASE_CONFIG, compression_mode="rotate")
                _materialize_runtime(rotate_runtime, "rotate", rotate_config)
                development._validate_runtime(
                    BASE_CONFIG, BASE_CREDENTIALS, compression_mode="rotate"
                )

                bad_marker = development._marker(compression_mode="in-place")
                _write_json(rotate_runtime / "marker.json", bad_marker)
                with self.assertRaises(RuntimeError):
                    development._validate_runtime(
                        BASE_CONFIG, BASE_CREDENTIALS, compression_mode="rotate"
                    )

                _write_json(
                    rotate_runtime / "marker.json",
                    development._marker(compression_mode="rotate"),
                )
                bad_config = copy.deepcopy(rotate_config)
                bad_config["compression"]["target_ratio"] = 0.20
                _write_json(rotate_runtime / "home" / "config.yaml", bad_config)
                with self.assertRaises(RuntimeError):
                    development._validate_runtime(
                        BASE_CONFIG, BASE_CREDENTIALS, compression_mode="rotate"
                    )


if __name__ == "__main__":
    unittest.main()
