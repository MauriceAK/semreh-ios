"""Offline-only guards for the existing-gateway goal probe."""
import json, sqlite3, subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch
import direct_hermes_goal_live_probe as probe

class GoalLiveProbeTests(unittest.TestCase):
    def test_backend_guard_requires_owned_home_hermes_home_listener_and_cwd(self):
        command = (f"{probe.stock.PYTHON} -m hermes_cli.main serve "
                   f"HOME={probe.OWNED_HOME} HERMES_HOME={probe.stock.RUNTIME / 'home'}")
        replies = [Mock(stdout=command), Mock(stdout="123\n"),
                   Mock(stdout=f"p123\nfcwd\nn{probe.stock.RUNTIME / 'tools'}\n")]
        with patch.object(subprocess, "run", side_effect=replies): probe._backend_guard(123)
        replies[0] = Mock(stdout=command.replace(str(probe.OWNED_HOME), "/Users/personal"))
        with patch.object(subprocess, "run", side_effect=replies):
            with self.assertRaises(RuntimeError): probe._backend_guard(123)

    def test_readonly_meta_and_match(self):
        with TemporaryDirectory() as raw:
            path = Path(raw).resolve() / "state.db"
            with sqlite3.connect(path) as db:
                db.execute("CREATE TABLE state_meta (key TEXT PRIMARY KEY, value TEXT)")
                db.execute("INSERT INTO state_meta VALUES (?, ?)", ("goal:x", json.dumps({"goal":"m","status":"active"})))
            with patch.object(probe.stock, "RUNTIME", Path(raw).resolve()):
                self.assertTrue(probe._matches(probe._meta(path, "goal:x"), "m", "active"))
                cleared = json.dumps({"goal": "m", "status": "cleared"})
                self.assertTrue(probe._matches(cleared, "m", "cleared"))
                self.assertFalse(probe._matches(cleared, "m", "active"))

    def test_clone_config_allows_only_exact_stock_migration_additions(self):
        with TemporaryDirectory() as raw:
            root = Path(raw)
            source, clone = root / "source.yaml", root / "clone.yaml"
            source.write_text("model: fixture\ntools:\n  tool_search:\n    enabled: off\n")
            clone.write_text("model: fixture\ntools:\n  tool_search:\n    enabled: off\nagent: {}\n_config_version: 39\n")
            self.assertTrue(probe._migrated_clone_matches(source, clone))
            clone.write_text(clone.read_text() + "memory: {}\n")
            self.assertFalse(probe._migrated_clone_matches(source, clone))
            clone.write_text("model: fixture\nagent: {}\n_config_version: 38\n")
            self.assertFalse(probe._migrated_clone_matches(source, clone))

if __name__ == "__main__": unittest.main()
