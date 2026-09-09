"""Offline guards for the bounded two-turn goal probe."""
import hashlib, json, unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
import direct_hermes_goal_e2e_probe as probe


class GoalE2EProbeTests(unittest.TestCase):
    def test_config_requires_exact_local_judge_and_zero_retries(self):
        with TemporaryDirectory() as raw:
            runtime = Path(raw)
            (runtime / "home").mkdir()
            config = {"model": {"provider": "custom", "default": "semreh-fixture",
                                  "base_url": "http://127.0.0.1:18792/v1"},
                      "auxiliary": {"transient_retries": 0,
                                    "goal_judge": dict(probe.EXPECTED_JUDGE)}}
            path = runtime / "home/config.yaml"; path.write_text(json.dumps(config))
            sha = hashlib.sha256(path.read_bytes()).hexdigest()
            with (patch.object(probe.stock, "RUNTIME", runtime),
                  patch.object(probe.stock, "validate"),
                  patch.object(probe.stock, "_validate_runtime_plugins"),
                  patch.object(probe.stock, "_validate_plugin_config"),
                  patch.object(probe.stock, "_validate_runtime_skill"),
                  patch.object(probe, "_backend_guard")):
                probe._config_preflight(123, sha)
                config["auxiliary"]["goal_judge"]["base_url"] = "https://example.invalid/v1"
                path.write_text(json.dumps(config))
                bad_sha = hashlib.sha256(path.read_bytes()).hexdigest()
                with self.assertRaises(RuntimeError): probe._config_preflight(123, bad_sha)

    def test_canonical_rows_require_four_role_rows(self):
        payload = {"messages": [{"role": "user", "content": "u"},
                                {"role": "assistant", "content": "a"}]}
        self.assertEqual(probe._rows(payload), [("user", "u"), ("assistant", "a")])
        with self.assertRaises(RuntimeError): probe._rows({"messages": None})

    def test_completion_count_includes_frames_buffered_during_rpc(self):
        frames = [{"id": 4, "result": {"status": "streaming"}},
                  {"params": {"type": "message.complete", "session_id": "owned"}},
                  {"params": {"type": "message.complete", "session_id": "sibling"}},
                  {"params": {"type": "message.complete", "session_id": "owned"}}]
        self.assertEqual(probe._completion_count(frames, "owned"), 2)


if __name__ == "__main__": unittest.main()
