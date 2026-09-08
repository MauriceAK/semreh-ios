"""Offline request-shape and ownership guards; no Git or server execution."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parent))
import direct_hermes_git_mutation_probe as probe  # noqa: E402


NAME = "semreh-git-mutation-" + "a" * 32


class Response:
    status_code = 200

    def __init__(self, payload):
        self.payload = payload

    def json(self):
        return self.payload


class Client:
    def __init__(self, root: Path):
        self.root = root
        self.phase = "modified"
        self.branch = probe.INITIAL_BRANCH
        self.calls = []

    async def get(self, route, *, params):
        self.calls.append(("GET", route, dict(params)))
        if route == "/api/git/status":
            counts = {
                "modified": (0, 1), "staged": (1, 0),
                "unstaged": (0, 1), "clean": (0, 0), "switched": (0, 0),
            }[self.phase]
            changed = int(bool(sum(counts)))
            return Response({
                "branch": self.branch, "staged": counts[0], "unstaged": counts[1],
                "changed": changed,
                "files": [] if not changed else [{"path": probe.FILE}],
            })
        raise AssertionError("unexpected GET")

    async def post(self, route, *, json):
        self.calls.append(("POST", route, dict(json)))
        if route == "/api/git/review/stage":
            self.phase = "staged"
            return Response({"ok": True})
        if route == "/api/git/review/unstage":
            self.phase = "unstaged"
            return Response({"ok": True})
        if route == "/api/git/branch/switch":
            self.phase = "switched"
            self.branch = probe.OTHER_BRANCH
            return Response({"branch": probe.OTHER_BRANCH})
        raise AssertionError("unexpected POST")


class GitMutationProbeTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        for child in ("tools", "tmp", "home"):
            (self.root / child).mkdir()
        self.runtime = patch.object(probe.stock_probe, "RUNTIME", self.root)
        self.runtime.start()

    def tearDown(self):
        self.runtime.stop()
        self.temp.cleanup()

    async def test_exact_mutation_allowlist_and_explicit_file(self):
        path = probe.fixture_path(NAME)
        owner = probe.prepare(path)
        (path / probe.FILE).write_bytes(probe.MODIFIED)
        client, evidence = Client(self.root), {}

        original_write = Path.write_bytes

        def tracked_write(target, data):
            result = original_write(target, data)
            if target == path / probe.FILE and data == probe.BASE:
                client.phase = "clean"
            elif target == path / probe.FILE and data == probe.MODIFIED:
                client.phase = "modified"
            return result

        with patch.object(Path, "write_bytes", tracked_write):
            await probe._exercise_prepared(client, path, owner, evidence)

        mutations = [(route, body) for method, route, body in client.calls if method == "POST"]
        self.assertEqual(mutations, [
            ("/api/git/review/stage", {"path": str(path), "file": probe.FILE}),
            ("/api/git/review/unstage", {"path": str(path), "file": probe.FILE}),
            ("/api/git/branch/switch", {"path": str(path), "branch": probe.OTHER_BRANCH}),
        ])
        encoded = json.dumps(evidence)
        self.assertNotIn(str(path), encoded)
        self.assertNotIn(probe.FILE, encoded)
        self.assertEqual(evidence["contract"]["remote_operations"], 0)
        self.assertEqual(evidence["contract"]["discard_or_clean_operations"], 0)

    def test_name_collision_symlink_and_owner_guards(self):
        for name in ("../source", "semreh-git-read-" + "a" * 32, "wrong"):
            with self.subTest(name=name), self.assertRaises(AssertionError):
                probe.fixture_path(name)
        path = probe.fixture_path(NAME)
        owner = probe.prepare(path)
        with self.assertRaises(AssertionError):
            probe.prepare(path)
        with self.assertRaises(AssertionError):
            probe.preserve_cleanup(path, (0, 0))
        (path / "link").symlink_to(self.root / "home")
        with self.assertRaises(AssertionError):
            probe.preserve_cleanup(path, owner)

    def test_cli_rejects_target_and_operation_overrides(self):
        parser = probe.build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args([])
        for option in (
            "--path", "--profile", "--origin", "--branch", "--file",
            "--push", "--fetch", "--pull", "--discard", "--clean",
        ):
            with self.subTest(option=option), self.assertRaises(SystemExit):
                parser.parse_args(["--output", "/tmp/evidence.json", option, "unsafe"])

    def test_status_requires_exact_owned_file_and_counts(self):
        probe.assert_status({
            "branch": probe.INITIAL_BRANCH, "staged": 1, "unstaged": 0,
            "changed": 1, "files": [{"path": probe.FILE}],
        }, branch=probe.INITIAL_BRANCH, staged=1, unstaged=0)
        with self.assertRaises(AssertionError):
            probe.assert_status({
                "branch": probe.INITIAL_BRANCH, "staged": 1, "unstaged": 0,
                "changed": 1, "files": [{"path": "other"}],
            }, branch=probe.INITIAL_BRANCH, staged=1, unstaged=0)


if __name__ == "__main__":
    unittest.main()
