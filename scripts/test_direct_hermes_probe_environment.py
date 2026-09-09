#!/usr/bin/env python3
"""Static containment regression for the stock fixture serve environment."""

import ast
from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("direct_hermes_probe.py")


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
        self.assertEqual(entries["HERMES_HOME"], "str(RUNTIME / 'home')")

    def test_auxiliary_fixture_routes_only_goal_judge_to_local_fixture(self):
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
        })

    def test_initialize_and_validate_share_auxiliary_fixture_constant(self):
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


if __name__ == "__main__":
    unittest.main()
