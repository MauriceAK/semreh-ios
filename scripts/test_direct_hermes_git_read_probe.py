"""Pure request/guard fixtures; no live server or local Git execution."""
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import direct_hermes_git_read_probe as probe

NAME = "semreh-git-read-" + "a" * 32


class Response:
    def __init__(self, body, status=200):
        self.body, self.status_code = body, status

    def json(self):
        return self.body


class Client:
    def __init__(self, root, failure=None, name=NAME):
        self.root, self.failure, self.calls, self.name = root, failure, [], name

    async def get(self, route, *, params):
        self.calls.append((route, params))
        path = self.root / "tools" / self.name
        if route == "/api/profiles":
            return Response({"profiles": [{"name": "default", "path": str(self.root / "home") if self.failure != "home" else "/private/home"}]})
        if route == "/api/profiles/active":
            return Response({"active": "default", "current": "default"})
        if self.failure == "http":
            return Response({}, 403)
        if route == "/api/git/worktrees":
            return Response({"worktrees": [{"path": str(path) if self.failure != "root" else "/wrong"}]})
        if route == "/api/git/status":
            return Response({"branch": "semreh-probe", "changed": 1,
                "files": [{"path": probe.FILE, "staged": True, "unstaged": True}]})
        if route == "/api/git/review/list":
            return Response({"files": [{"path": probe.FILE, "staged": True, "added": 2, "removed": 0}]})
        if route == "/api/git/branches":
            return Response({"branches": [{"name": "semreh-probe", "isRemote": False}]})
        if route == "/api/git/review/diff":
            text = "+staged café" if params["staged"] == "true" else "+unstaged 雪"
            return Response({"diff": text if self.failure != "diff" else "+staged café\n+unstaged 雪"})
        raise AssertionError("unexpected route")


class GitReadProbeTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        for name in ("tools", "tmp", "home"):
            (self.root / name).mkdir()
        self.runtime = patch.object(probe.stock_probe, "RUNTIME", self.root)
        self.runtime.start()

    def tearDown(self):
        self.runtime.stop()
        self.temp.cleanup()

    async def test_exact_get_only_contracts_and_recoverable_cleanup(self):
        client, evidence = Client(self.root), {}
        with patch.object(probe, "seed") as seed:
            await probe.exercise(client, evidence, NAME)
            seed.assert_called_once()
        self.assertEqual([route for route, _ in client.calls], [
            "/api/profiles", "/api/profiles/active", "/api/git/worktrees",
            "/api/git/status", "/api/git/review/list", "/api/git/branches",
            "/api/git/review/diff", "/api/git/review/diff"])
        path = str(self.root / "tools" / NAME)
        for route, params in client.calls[2:]:
            self.assertEqual(params["path"], path)
        self.assertEqual(client.calls[-1][1], {"path": path, "file": probe.FILE,
            "scope": "uncommitted", "staged": "false"})
        self.assertTrue(evidence["stock_read_shapes_verified"])
        self.assertTrue(evidence["cleanup_preserved"])
        self.assertFalse((self.root / "tools" / NAME).exists())
        self.assertTrue((self.root / "tmp" / (NAME + "-retired")).is_dir())
        encoded = json.dumps(evidence, ensure_ascii=False)
        for value in (str(self.root), "café", "雪", probe.FILE):
            self.assertNotIn(value, encoded)

    async def test_wrong_profile_home_prevents_any_fixture_write(self):
        with patch.object(probe, "prepare") as prepare, self.assertRaises(AssertionError):
            await probe.exercise(Client(self.root, "home"), {}, NAME)
        prepare.assert_not_called()

    async def test_read_failures_preserve_only_owned_fixture(self):
        for failure in ("http", "root", "diff"):
            with self.subTest(failure=failure):
                name = "semreh-git-read-" + {"http": "b", "root": "c", "diff": "d"}[failure] * 32
                evidence = {}
                client = Client(self.root, failure, name)
                with patch.object(probe, "seed"), self.assertRaises(AssertionError):
                    await probe.exercise(client, evidence, name)
                self.assertTrue(evidence["cleanup_preserved"])
                if failure == "diff":
                    self.assertEqual(client.calls[-1][0], "/api/git/review/diff")

    def test_names_collisions_symlinks_and_owner_mismatch(self):
        for name in ("../source", "tools", "MEMORY.md", "semreh-git-read-wrong"):
            with self.assertRaises(AssertionError):
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
        self.assertTrue(path.exists())

    def test_seed_commands_are_local_bounded_and_scrub_git_environment(self):
        path = probe.fixture_path(NAME)
        owner = probe.prepare(path)
        with patch.object(probe.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
            probe.seed(path, owner)
        self.assertEqual(run.call_count, 4)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(commands[0][-3:], ["init", "--template=", "--initial-branch=semreh-probe"])
        self.assertEqual(commands[1][-3:], ["add", "--", probe.FILE])
        self.assertEqual(commands[2][-4:], ["commit", "--quiet", "--message", "Disposable read fixture"])
        for call in run.call_args_list:
            self.assertEqual(call.kwargs["env"]["GIT_CONFIG_GLOBAL"], "/dev/null")
            self.assertNotIn("HOME", call.kwargs["env"])
            self.assertEqual(call.kwargs["timeout"], 15)
            self.assertIn(str(path), call.args[0])
        self.assertEqual((path / probe.FILE).read_bytes(), probe.WORKTREE)
        self.assertLessEqual(len(probe.WORKTREE), 1024)


if __name__ == "__main__":
    unittest.main()
