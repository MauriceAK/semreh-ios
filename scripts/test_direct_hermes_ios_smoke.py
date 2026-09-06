#!/usr/bin/env python3
"""Pure CLI rejection checks for hosted smoke backend-mode guards."""

import subprocess
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent / "direct_hermes_ios_smoke.py"


class IOSSmokeGuardTests(unittest.TestCase):
    def assertRejected(self, arguments, message):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn(message, result.stderr)

    def test_stock_requires_reasoning_phase(self):
        self.assertRejected(
            ["--stock-backend"],
            "--stock-backend requires --slice2-reasoning",
        )

    def test_reasoning_requires_exactly_one_backend_mode(self):
        self.assertRejected(
            ["--https", "--slice2-reasoning"],
            "Slice 2 reasoning requires exactly one backend mode",
        )
        self.assertRejected(
            [
                "--https", "--slice2-reasoning", "--stock-backend",
                "--development-backend-sha", "not-a-real-sha",
            ],
            "Slice 2 reasoning requires exactly one backend mode",
        )

    def test_development_sha_cannot_select_an_unrelated_phase(self):
        self.assertRejected(
            ["--development-backend-sha", "not-a-real-sha"],
            "--development-backend-sha requires --slice2-reasoning or --slice2-ui",
        )


if __name__ == "__main__":
    unittest.main()
