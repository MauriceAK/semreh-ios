#!/usr/bin/env python3
"""Static containment regression for the stock fixture serve environment."""

import ast
import copy
from contextlib import redirect_stdout
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import io


SCRIPT = Path(__file__).with_name("direct_hermes_probe.py")


def load_probe():
    spec = importlib.util.spec_from_file_location("direct_hermes_probe_fixture_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DirectHermesProbeEnvironmentTests(unittest.TestCase):
    def parsed_tree(self):
        return ast.parse(SCRIPT.read_text(encoding="utf-8"), filename=str(SCRIPT))

    def test_serve_pins_home_inside_validated_runtime_tree(self):
        tree = self.parsed_tree()
        serve = next(
            node for node in tree.body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "serve"
        )
        environment = next(
            node.value for node in ast.walk(serve)
            if isinstance(node, ast.Assign)
            and any(isinstance(target, ast.Name) and target.id == "environment"
                    for target in node.targets)
            and isinstance(node.value, ast.Dict)
        )
        entries = {
            key.value: ast.unparse(value)
            for key, value in zip(environment.keys, environment.values)
            if isinstance(key, ast.Constant) and isinstance(key.value, str)
        }
        self.assertEqual(entries["HOME"], "str(RUNTIME / 'home' / 'home')")
        self.assertEqual(entries["HERMES_HOME"], "str(hermes_home)")

    def test_auxiliary_fixture_routes_goal_and_compression_only_to_local_fixture(self):
        tree = self.parsed_tree()
        assignment = next(
            node for node in tree.body
            if isinstance(node, ast.Assign)
            and any(isinstance(target, ast.Name) and target.id == "AUXILIARY_FIXTURE_CONFIG"
                    for target in node.targets)
        )
        self.assertEqual(ast.literal_eval(assignment.value), {
            "background_review": {"enabled": False},
            "transient_retries": 0,
            "goal_judge": {
                "provider": "custom",
                "model": "semreh-fixture",
                "base_url": "http://127.0.0.1:18792/v1",
                "api_key": "no-key-required",
                "api_mode": "chat_completions",
                "timeout": 5,
                "max_tokens": 128,
                "fallback_chain": [],
            },
            "compression": {
                "provider": "custom",
                "model": "semreh-fixture",
                "base_url": "http://127.0.0.1:18792/v1",
                "api_key": "no-key-required",
                "api_mode": "chat_completions",
                "timeout": 120,
                "reasoning_effort": "none",
                "fallback_chain": [],
            },
        })

    def test_rotation_compression_fixture_matches_current_stock_probe(self):
        tree = self.parsed_tree()
        assignment = next(
            node for node in tree.body
            if isinstance(node, ast.Assign)
            and any(isinstance(target, ast.Name) and target.id == "COMPRESSION_FIXTURE_CONFIG"
                    for target in node.targets)
        )
        self.assertEqual(ast.literal_eval(assignment.value), {
            "in_place": False,
            "protect_last_n": 2,
            "min_tail_user_messages": 1,
            "target_ratio": 0.10,
        })

    def test_initialize_and_validate_share_fixture_constants(self):
        tree = self.parsed_tree()
        for function_name in ("initialize", "validate"):
            function = next(
                node for node in tree.body
                if isinstance(node, ast.FunctionDef) and node.name == function_name
            )
            auxiliary_values = [
                value for node in ast.walk(function) if isinstance(node, ast.Dict)
                for key, value in zip(node.keys, node.values)
                if isinstance(key, ast.Constant) and key.value == "auxiliary"
            ]
            self.assertEqual(len(auxiliary_values), 1, function_name)
            self.assertIsInstance(auxiliary_values[0], ast.Name, function_name)
            self.assertEqual(auxiliary_values[0].id, "AUXILIARY_FIXTURE_CONFIG", function_name)
            compression_values = [
                value for node in ast.walk(function) if isinstance(node, ast.Dict)
                for key, value in zip(node.keys, node.values)
                if isinstance(key, ast.Constant) and key.value == "compression"
            ]
            self.assertEqual(len(compression_values), 1, function_name)
            self.assertIsInstance(compression_values[0], ast.Name, function_name)
            self.assertEqual(compression_values[0].id, "COMPRESSION_FIXTURE_CONFIG", function_name)

    def test_memory_adoption_validation_is_keyword_only_and_defaults_off(self):
        validate = next(
            node for node in self.parsed_tree().body
            if isinstance(node, ast.FunctionDef) and node.name == "validate"
        )
        self.assertEqual([arg.arg for arg in validate.args.kwonlyargs],
                         ["allow_memory_adoption", "profile"])
        self.assertEqual([ast.literal_eval(value) for value in validate.args.kw_defaults],
                         [False, None])

    def test_named_profile_allowlist_is_exact(self):
        probe = load_probe()
        self.assertEqual(probe.NAMED_FIXTURE_PROFILES,
                         {"semreh-goal-scope-8f059a8ae784"})
        with self.assertRaisesRegex(RuntimeError, "not allowlisted"):
            probe._fixture_home("work")

    def test_named_validation_uses_same_complete_safe_model_config(self):
        probe = load_probe()
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory).resolve()
            home = runtime / "home"
            named = home / "profiles" / "semreh-goal-scope-8f059a8ae784"
            named.mkdir(parents=True, mode=0o700)
            (runtime / "credentials.json").write_text("{}")
            (runtime / "marker.json").write_text("{}")
            (home / "config.yaml").write_text("{}")
            for path in (runtime / "credentials.json", runtime / "marker.json",
                         home / "config.yaml"):
                path.chmod(0o600)
            for child in ("home", "tools", "tmp", "cache", "logs"):
                (runtime / child).mkdir(parents=True, exist_ok=True)
            config = {
                "model": {"provider": "custom", "default": "semreh-fixture",
                          "base_url": "http://127.0.0.1:18792/v1"},
                "terminal": {"backend": "local", "cwd": str(runtime / "tools"),
                             "home_mode": "profile"},
                "memory": {"memory_enabled": False, "user_profile_enabled": False,
                           "provider": ""},
                "compression": copy.deepcopy(probe.COMPRESSION_FIXTURE_CONFIG),
                "auxiliary": copy.deepcopy(probe.AUXILIARY_FIXTURE_CONFIG),
                "curator": {"enabled": False}, "mcp_servers": {}, "platforms": {},
                "kanban": {"dispatch_in_gateway": False, "review_dispatch": False},
                "security": {"allow_lazy_installs": False},
                "cron": {"allow_agent_scheduling": False}, "toolsets": [],
                "platform_toolsets": {"cli": [], "tui": []},
                "dashboard": {"public_url": "http://semreh-slice1.test:18791",
                              "basic_auth": {"username": "semreh-test",
                                             "password_hash": "scrypt$fixture",
                                             "secret": "x" * 32}},
            }
            (named / "config.yaml").write_text(json.dumps(config))
            (named / "config.yaml").chmod(0o600)
            probe.RUNTIME = runtime
            probe.BLOCKING_FIXTURE_DEPLOYED = home / "plugins"
            probe.BLOCKING_FIXTURE_SKILL_DEPLOYED = home / "skills" / "semreh-fixture-empty-secret"
            marker = {"marker": probe.MARKER, "source": str(probe.SOURCE),
                      "port": probe.PORT}
            (runtime / "marker.json").write_text(json.dumps(marker))
            with mock.patch.object(probe, "checked_paths"):
                with redirect_stdout(io.StringIO()):
                    probe.validate(profile="semreh-goal-scope-8f059a8ae784")
            del config["auxiliary"]["goal_judge"]
            (named / "config.yaml").write_text(json.dumps(config))
            with mock.patch.object(probe, "checked_paths"), self.assertRaisesRegex(
                    RuntimeError, "configuration drifted"):
                probe.validate(profile="semreh-goal-scope-8f059a8ae784")

    def test_named_serve_sets_matching_home_and_explicit_profile(self):
        probe = load_probe()
        profile = "semreh-goal-scope-8f059a8ae784"
        named = probe.RUNTIME / "home" / "profiles" / profile
        captured = {}
        class FakeSocket:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def setsockopt(self, *args): pass
            def bind(self, *args): pass
        def capture_exec(path, argv, environment):
            captured.update(path=path, argv=argv, environment=environment)
            raise RuntimeError("captured")
        with mock.patch.object(probe, "validate"), \
                mock.patch.object(probe, "_fixture_home", return_value=named), \
                mock.patch.object(probe, "_validate_plugin_config"), \
                mock.patch.object(probe, "_validate_runtime_skill"), \
                mock.patch.object(probe, "_validate_runtime_plugins"), \
                mock.patch.object(probe.socket, "socket", return_value=FakeSocket()), \
                mock.patch.object(probe.os, "chdir"), \
                mock.patch.object(probe.os, "execve", side_effect=capture_exec), \
                self.assertRaisesRegex(RuntimeError, "captured"):
            probe.serve(profile=profile)
        self.assertEqual(captured["environment"]["HERMES_HOME"], str(named))
        self.assertEqual(captured["argv"][3:5], ["-p", profile])
        self.assertIn("--isolated", captured["argv"])

    def test_default_serve_keeps_root_home_and_omits_profile_flag(self):
        probe = load_probe()
        root_home = probe.RUNTIME / "home"
        captured = {}
        class FakeSocket:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def setsockopt(self, *args): pass
            def bind(self, *args): pass
        def capture_exec(path, argv, environment):
            captured.update(argv=argv, environment=environment)
            raise RuntimeError("captured")
        with mock.patch.object(probe, "validate"), \
                mock.patch.object(probe, "_fixture_home", return_value=root_home), \
                mock.patch.object(probe, "_validate_plugin_config"), \
                mock.patch.object(probe, "_validate_runtime_skill"), \
                mock.patch.object(probe, "_validate_runtime_plugins"), \
                mock.patch.object(probe.socket, "socket", return_value=FakeSocket()), \
                mock.patch.object(probe.os, "chdir"), \
                mock.patch.object(probe.os, "execve", side_effect=capture_exec), \
                self.assertRaisesRegex(RuntimeError, "captured"):
            probe.serve()
        self.assertEqual(captured["environment"]["HERMES_HOME"], str(root_home))
        self.assertNotIn("-p", captured["argv"])
        self.assertEqual(captured["argv"][3], "serve")


if __name__ == "__main__":
    unittest.main()
