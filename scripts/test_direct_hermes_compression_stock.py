"""Pure guards for the compression probe's explicit stock mode."""

from pathlib import Path
import sys
import unittest
from unittest.mock import patch


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import direct_hermes_compression_probe as probe  # noqa: E402


class CompressionStockTests(unittest.TestCase):
    def test_in_place_multiset_diagnostic_separates_order_from_row_loss(self):
        prompts = ["p1", "p2"]
        assistants = ["a1", "a2"]
        reordered = [
            {"role": "user", "content": "p2"},
            {"role": "assistant", "content": "a2"},
            {"role": "user", "content": "p1"},
            {"role": "assistant", "content": "a1"},
        ]

        evidence = probe.original_fixture_multiset_evidence(
            reordered, prompts, assistants
        )

        self.assertTrue(evidence["original_fixture_multiset_match"])
        self.assertEqual(evidence["original_fixture_expected_rows"], 4)
        self.assertEqual(evidence["original_fixture_observed_rows"], 4)
        self.assertEqual(evidence["original_fixture_missing_rows"], 0)
        self.assertEqual(evidence["original_fixture_duplicate_rows"], 0)
        with self.assertRaises(AssertionError):
            probe.assert_originals_once_in_order(reordered, prompts, assistants)

    def test_in_place_multiset_diagnostic_reports_missing_and_duplicate_rows(self):
        evidence = probe.original_fixture_multiset_evidence(
            [
                {"role": "user", "content": "p1"},
                {"role": "assistant", "content": "a1"},
                {"role": "user", "content": "p1"},
                {"role": "user", "content": "p2"},
            ],
            ["p1", "p2"],
            ["a1", "a2"],
        )

        self.assertFalse(evidence["original_fixture_multiset_match"])
        self.assertEqual(evidence["original_fixture_missing_rows"], 1)
        self.assertEqual(evidence["original_fixture_duplicate_rows"], 1)

    def test_stock_fixture_selects_exact_pin_and_requested_sibling(self):
        fixture = probe.select_fixture(
            "rotate", stock_backend=True, backend_sha=None
        )

        self.assertTrue(fixture.stock)
        self.assertEqual(fixture.backend_sha, probe.STOCK_PIN)
        self.assertEqual(fixture.runtime, probe.runtime("rotate"))

    def test_stock_rejects_mixed_backend_sha_and_dev_requires_sha(self):
        with self.assertRaisesRegex(ValueError, "cannot be combined"):
            probe.select_fixture(
                "rotate", stock_backend=True, backend_sha=probe.STOCK_PIN
            )
        with self.assertRaisesRegex(ValueError, "required"):
            probe.select_fixture("rotate", stock_backend=False, backend_sha=None)

    def test_stock_validation_checks_baseline_and_compression_overlay(self):
        fixture = probe.CompressionFixture(
            runtime=probe.runtime("rotate"),
            backend_sha=probe.STOCK_PIN,
            stock=True,
        )
        with patch.object(
            probe, "_validated_baseline_fixture",
            return_value=("baseline-config", "baseline-credentials"),
        ) as baseline, patch.object(probe, "_validate_runtime") as runtime:
            probe.validate_fixture(fixture, "rotate")

        baseline.assert_called_once_with()
        runtime.assert_called_once_with(
            "baseline-config",
            "baseline-credentials",
            compression_mode="rotate",
        )

    def test_stock_validation_rejects_forged_pin_or_sibling_mode(self):
        forged = probe.CompressionFixture(
            runtime=probe.runtime("rotate"),
            backend_sha="b" * 40,
            stock=True,
        )
        with self.assertRaisesRegex(RuntimeError, "approved stock pin"):
            probe.validate_fixture(forged, "rotate")

        wrong_mode = probe.CompressionFixture(
            runtime=probe.runtime("rotate"),
            backend_sha=probe.STOCK_PIN,
            stock=True,
        )
        with self.assertRaisesRegex(RuntimeError, "does not match"):
            probe.validate_fixture(wrong_mode, "in-place")

    def test_development_validation_remains_exact_sha_path(self):
        fixture = probe.CompressionFixture(
            runtime=probe.runtime("in-place"),
            backend_sha="a" * 40,
            stock=False,
        )
        with patch.object(probe, "_validate_all") as validate:
            probe.validate_fixture(fixture, "in-place")

        validate.assert_called_once_with("a" * 40, compression_mode="in-place")


if __name__ == "__main__":
    unittest.main()
