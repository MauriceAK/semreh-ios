"""Offline guards for the bounded MEMORY adoption probe."""
import hashlib, json, unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
import direct_hermes_memory_adoption_probe as probe


class MemoryAdoptionProbeTests(unittest.TestCase):
    def test_preflight_requires_enabled_default_local_model_and_absent_memory(self):
        with TemporaryDirectory() as raw:
            runtime = Path(raw); home = runtime / "home"; home.mkdir()
            config = {"model": dict(probe.EXPECTED_MODEL), "memory": {
                "memory_enabled": True, "user_profile_enabled": False, "provider": ""}}
            config_path = home / "config.yaml"
            config_path.write_text(json.dumps(config))
            diagnostic = runtime / "model.log"; diagnostic.write_text("")
            sha = hashlib.sha256(config_path.read_bytes()).hexdigest()
            validate = patch.object(probe.stock, "validate")
            guards = (patch.object(probe.stock, "RUNTIME", runtime),
                      validate,
                      patch.object(probe.stock, "_validate_runtime_plugins"),
                      patch.object(probe.stock, "_validate_plugin_config"),
                      patch.object(probe.stock, "_validate_runtime_skill"),
                      patch.object(probe, "_backend_guard"))
            with guards[0], guards[1] as validate_mock, guards[2], guards[3], guards[4], guards[5]:
                _, memory, original = probe._preflight(123, sha, diagnostic)
                validate_mock.assert_called_once_with(allow_memory_adoption=True)
                self.assertFalse(memory.exists()); self.assertEqual(original, config_path.read_bytes())
                memory.parent.mkdir(); memory.write_text("existing")
                with self.assertRaises(RuntimeError): probe._preflight(123, sha, diagnostic)

    def test_diagnostic_requires_exactly_one_true_boolean(self):
        prefix = b"SEMREH_FIXTURE_DIAGNOSTIC "
        base = {"memory_adoption_request": True, "fixture_kind": None,
                "advertised_tool_count": 3,
                "advertised_tools": probe.EXPECTED_MAIN_TOOLS}
        false = prefix + json.dumps({**base, "exact_memory_marker_in_system": False}).encode()
        true = prefix + json.dumps({**base, "exact_memory_marker_in_system": True}).encode()
        auxiliary = prefix + json.dumps({"memory_adoption_request": True,
            "fixture_kind": None, "advertised_tool_count": 0, "advertised_tools": [],
            "exact_memory_marker_in_system": False}).encode()
        self.assertFalse(probe._diagnostic_proves_adoption(false))
        self.assertFalse(probe._diagnostic_proves_adoption(false + b"\n" + true))
        self.assertFalse(probe._diagnostic_proves_adoption(true + b"\n" + true))
        self.assertEqual(probe._diagnostic_summary(auxiliary + b"\n" + true), (True, 1))
        self.assertFalse(probe._diagnostic_proves_adoption(prefix + b"not-json"))

    def test_marker_and_scope_are_fixed_and_benign(self):
        self.assertEqual(probe.PROFILE, "default")
        self.assertRegex(probe.MEMORY_ADOPTION_MARKER, r"^SEMREH_MEMORY_ADOPTION_BENIGN_V1$")
        self.assertNotIn(probe.MEMORY_ADOPTION_MARKER, probe.PROMPT)
        self.assertIn(probe.MEMORY_ADOPTION_REQUEST, probe.PROMPT)


if __name__ == "__main__": unittest.main()
