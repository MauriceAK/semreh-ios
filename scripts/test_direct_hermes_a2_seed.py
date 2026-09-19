#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("direct_hermes_a2_seed.py")


def load_seed():
    spec = importlib.util.spec_from_file_location("direct_hermes_a2_seed_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class A2SeedTests(unittest.TestCase):
    def test_profile_and_title_allowlist_is_exact(self):
        seed = load_seed()
        self.assertEqual(seed.TITLES, {
            "default": "SEMREH_A2_DEFAULT_V1",
            "semreh-goal-scope-8f059a8ae784": "SEMREH_A2_SELECTED_V1",
        })

    def test_binding_and_sidebar_readback_are_bounded(self):
        seed = load_seed()
        runtime, stored = seed._binding({
            "session_id": "runtime-1", "stored_session_id": "stored-1"})
        self.assertEqual((runtime, stored), ("runtime-1", "stored-1"))
        summary = seed._matching_row({"sessions": [{
            "id": stored, "profile": "default", "title": seed.TITLES["default"]
        }]}, profile="default", stored=stored, title=seed.TITLES["default"])
        self.assertEqual(summary, {"stored_id": stored, "profile": "default",
                                   "title": "SEMREH_A2_DEFAULT_V1"})
        with self.assertRaisesRegex(RuntimeError, "profile/title"):
            seed._matching_row({"sessions": [{
                "id": stored, "profile": seed.NAMED,
                "title": seed.TITLES["default"]
            }]}, profile="default", stored=stored, title=seed.TITLES["default"])

    def test_fixture_validation_selects_named_home_and_all_plugin_guards(self):
        seed = load_seed()
        named_home = Path("/owned/named")
        with mock.patch.object(seed.stock_probe, "validate") as validate, \
                mock.patch.object(seed.stock_probe, "_fixture_home",
                                  return_value=named_home) as fixture_home, \
                mock.patch.object(seed.stock_probe, "_validate_plugin_config") as config, \
                mock.patch.object(seed.stock_probe, "_validate_runtime_skill") as skill, \
                mock.patch.object(seed.stock_probe, "_validate_runtime_plugins") as plugins:
            seed._validate_fixture(seed.NAMED)
        validate.assert_called_once_with(profile=seed.NAMED)
        fixture_home.assert_called_once_with(seed.NAMED)
        config.assert_called_once_with(approval_secret_fixture=True,
                                       hermes_home=named_home)
        skill.assert_called_once_with(approval_secret_fixture=True,
                                      hermes_home=named_home)
        plugins.assert_called_once_with(approval_secret_fixture=True,
                                        hermes_home=named_home)

    def test_default_validation_preserves_root_selection(self):
        seed = load_seed()
        with mock.patch.object(seed.stock_probe, "validate") as validate, \
                mock.patch.object(seed.stock_probe, "_fixture_home",
                                  return_value=Path("/owned/root")), \
                mock.patch.object(seed.stock_probe, "_validate_plugin_config"), \
                mock.patch.object(seed.stock_probe, "_validate_runtime_skill"), \
                mock.patch.object(seed.stock_probe, "_validate_runtime_plugins"):
            seed._validate_fixture("default")
        validate.assert_called_once_with(profile=None)


if __name__ == "__main__":
    unittest.main()
