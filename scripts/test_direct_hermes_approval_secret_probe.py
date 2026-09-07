"""Pure guards for the opt-in synthetic approval/secret fixture."""

from __future__ import annotations

import asyncio
from pathlib import Path
import json
import importlib.util
import shutil
import sys
import tempfile
import types
import unittest
from unittest import mock

import direct_hermes_approval_secret_probe as probe
import direct_hermes_model_fixture as model
import direct_hermes_probe as launcher


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "semreh-blocking-fixture"


class ApprovalSecretFixtureTests(unittest.TestCase):
    def test_fixture_manifest_and_skill_are_owned_and_exact(self) -> None:
        manifest = (FIXTURE / "plugin.yaml").read_text()
        skill = (FIXTURE / "skills" / "empty_secret" / "SKILL.md").read_text()
        self.assertIn("name: semreh-blocking-fixture", manifest)
        self.assertIn("required_environment_variables:", skill)
        self.assertIn(probe.EMPTY_SECRET_ENV, skill)
        source = (FIXTURE / "__init__.py").read_text()
        self.assertNotIn("import subprocess", source)
        self.assertNotIn("subprocess.", source)
        self.assertNotIn("os.system", source)

    def test_launcher_fixture_mode_is_explicit_and_uses_only_owned_toolset(self) -> None:
        self.assertEqual(launcher.BLOCKING_FIXTURE_TOOLSET, "semreh_blocking_fixture")
        self.assertTrue((launcher.BLOCKING_FIXTURE_PLUGINS / "semreh-blocking-fixture").is_dir())
        source = Path(launcher.__file__).read_text()
        self.assertIn("--approval-secret-fixture", source)
        self.assertEqual(
            launcher.BLOCKING_FIXTURE_DEPLOYED,
            launcher.RUNTIME / "home" / "plugins",
        )
        self.assertNotIn("environment['HERMES_BUNDLED_PLUGINS']", source)
        self.assertIn("HERMES_TUI_TOOLSETS", source)

    def test_repository_fixture_matches_launcher_tree_and_digests(self) -> None:
        launcher._validate_fixture_tree(launcher.BLOCKING_FIXTURE_PLUGINS, label="Repository")

    def test_fixture_tree_rejects_extra_file_and_wrong_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / "plugins"
            shutil.copytree(launcher.BLOCKING_FIXTURE_PLUGINS, root)
            (root / "unexpected.txt").write_text("not part of fixture")
            with self.assertRaisesRegex(RuntimeError, "unexpected files"):
                launcher._validate_fixture_tree(root, label="Temporary")

            (root / "unexpected.txt").unlink()
            with (root / "semreh-blocking-fixture" / "plugin.yaml").open("a") as stream:
                stream.write("\nextra: rejected\n")
            with self.assertRaisesRegex(RuntimeError, "digest mismatch"):
                launcher._validate_fixture_tree(root, label="Temporary")

    def test_fixture_tree_rejects_symlink_and_default_rejects_plugins(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / "plugins"
            shutil.copytree(launcher.BLOCKING_FIXTURE_PLUGINS, root)
            target = root / "semreh-blocking-fixture" / "plugin.yaml"
            target.unlink()
            target.symlink_to(launcher.BLOCKING_FIXTURE_PLUGINS / "semreh-blocking-fixture" / "plugin.yaml")
            with self.assertRaisesRegex(RuntimeError, "escaped path"):
                launcher._validate_fixture_tree(root, label="Temporary")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / "plugins"
            root.mkdir()
            (root / "unexpected-plugin").mkdir()
            with mock.patch.object(launcher, "BLOCKING_FIXTURE_DEPLOYED", root):
                with self.assertRaisesRegex(RuntimeError, "must not contain plugins"):
                    launcher._validate_runtime_plugins(approval_secret_fixture=False)

    def test_plugin_allowlist_is_exact_only_for_opt_in_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary).resolve()
            home = runtime / "home"
            home.mkdir()
            config = home / "config.yaml"
            with mock.patch.object(launcher, "RUNTIME", runtime):
                config.write_text(json.dumps({}))
                with self.assertRaisesRegex(RuntimeError, "not enabled"):
                    launcher._validate_plugin_config(approval_secret_fixture=True)

                config.write_text(json.dumps({"plugins": {"enabled": ["other"]}}))
                with self.assertRaisesRegex(RuntimeError, "unexpected plugin"):
                    launcher._validate_plugin_config(approval_secret_fixture=True)

                config.write_text(json.dumps({
                    "plugins": {"enabled": [launcher.BLOCKING_FIXTURE_PLUGIN_ID]},
                    "tools": launcher.BLOCKING_FIXTURE_TOOLS_CONFIG,
                }))
                launcher._validate_plugin_config(approval_secret_fixture=True)

                config.write_text(json.dumps({
                    "plugins": {"enabled": [launcher.BLOCKING_FIXTURE_PLUGIN_ID]},
                    "tools": {"tool_search": {"enabled": "on"}},
                }))
                with self.assertRaisesRegex(RuntimeError, "disable tool_search"):
                    launcher._validate_plugin_config(approval_secret_fixture=True)

                with self.assertRaisesRegex(RuntimeError, "must not enable"):
                    launcher._validate_plugin_config(approval_secret_fixture=False)
                config.write_text(json.dumps({"plugins": {"enabled": []}}))
                launcher._validate_plugin_config(approval_secret_fixture=False)

    def test_runtime_skill_validation_ignores_unrelated_bundled_skills(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            skills_root = Path(temporary).resolve() / "skills"
            fixture_root = skills_root / "semreh-fixture-empty-secret"
            fixture_root.mkdir(parents=True)
            shutil.copy2(
                FIXTURE / "skills" / "empty_secret" / "SKILL.md",
                fixture_root / "SKILL.md",
            )
            bundled = skills_root / ".bundled_manifest"
            bundled.mkdir()
            (bundled / "manifest.json").write_text("stock")
            with mock.patch.object(launcher, "BLOCKING_FIXTURE_SKILL_DEPLOYED", fixture_root):
                launcher._validate_runtime_skill(approval_secret_fixture=True)
                with self.assertRaisesRegex(RuntimeError, "must not contain"):
                    launcher._validate_runtime_skill(approval_secret_fixture=False)

    def test_request_summary_never_retains_secret_value_or_identifiers(self) -> None:
        approval = probe._request_shape(
            "approval.request",
            {"params": {"type": "approval.request", "session_id": "runtime"}},
            {"request_id": "opaque", "choices": ["once", "deny"], "command": "<fixture>"},
            "runtime",
        )
        secret = probe._request_shape(
            "secret.request",
            {"params": {"type": "secret.request", "session_id": "runtime"}},
            {"request_id": "opaque", "env_var": probe.EMPTY_SECRET_ENV, "prompt": "fixture"},
            "runtime",
        )
        self.assertNotIn("request_id", approval)
        self.assertNotIn("command", approval)
        self.assertNotIn("request_id", secret)
        self.assertNotIn("prompt", secret)
        self.assertTrue(secret["env_var_matches"])

    def test_model_fixture_markers_match_probe_tool_names(self) -> None:
        self.assertEqual(model.APPROVAL_TOOL_NAME, "semreh_fixture_approval")
        self.assertEqual(model.SECRET_TOOL_NAME, "semreh_fixture_secret")
        self.assertEqual(model.SECRET_MARKER, "SEMREH_BLOCKING_SECRET")
        self.assertEqual(model.APPROVAL_MARKER, "SEMREH_BLOCKING_APPROVAL")

    def test_fixture_handlers_accept_stock_forwarded_context_kwargs(self) -> None:
        approval_calls = []
        skill_calls = []
        tools_package = types.ModuleType("tools")
        tools_package.__path__ = []
        approval_module = types.ModuleType("tools.approval")
        skills_module = types.ModuleType("tools.skills_tool")

        def fake_approval(*args, **kwargs):
            approval_calls.append((args, kwargs))
            return {"approved": False}

        def fake_skill(*args, **kwargs):
            skill_calls.append((args, kwargs))
            return "fixture-skill-result"

        approval_module.request_tool_approval = fake_approval
        skills_module.skill_view = fake_skill
        module_path = FIXTURE / "__init__.py"
        spec = importlib.util.spec_from_file_location("semreh_fixture_test_module", module_path)
        module = importlib.util.module_from_spec(spec)
        with mock.patch.dict(sys.modules, {
            "tools": tools_package,
            "tools.approval": approval_module,
            "tools.skills_tool": skills_module,
        }):
            old_dont_write = sys.dont_write_bytecode
            sys.dont_write_bytecode = True
            try:
                spec.loader.exec_module(module)
            finally:
                sys.dont_write_bytecode = old_dont_write
            result = module._approval({}, task_id="t", session_id="s", user_task="u")
            secret = module._secret({}, task_id="t", session_id="s", user_task="u")

        self.assertIn('"approved":false', result)
        self.assertEqual(approval_calls[0][1], {
            "rule_key": "semreh-blocking-fixture:approval",
        })
        self.assertEqual(skill_calls[0], (
            ("semreh-fixture-empty-secret",), {"preprocess": False},
        ))
        self.assertEqual(secret, "fixture-skill-result")

    def test_stale_approval_response_requires_zero_resolution(self) -> None:
        class FakeProbe:
            def __init__(self, resolved: int) -> None:
                self.resolved = resolved

            async def rpc(self, method: str, params: dict) -> dict:
                self.method = method
                self.params = params
                return {"resolved": self.resolved}

        good = FakeProbe(0)
        result = asyncio.run(probe._expect_stale_approval(
            good, "runtime", "opaque"
        ))
        self.assertEqual(result, {"resolved_count": 0})
        self.assertEqual(good.method, "approval.respond")

        with self.assertRaisesRegex(AssertionError, "resolved=0"):
            asyncio.run(probe._expect_stale_approval(
                FakeProbe(1), "runtime", "opaque"
            ))


if __name__ == "__main__":
    unittest.main()
