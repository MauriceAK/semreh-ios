#!/usr/bin/env python3
"""Static containment regression for the stock fixture serve environment."""

import ast
from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("direct_hermes_probe.py")


class DirectHermesProbeEnvironmentTests(unittest.TestCase):
    def test_serve_pins_home_inside_validated_runtime_tree(self):
        tree = ast.parse(SCRIPT.read_text(encoding="utf-8"), filename=str(SCRIPT))
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


if __name__ == "__main__":
    unittest.main()
