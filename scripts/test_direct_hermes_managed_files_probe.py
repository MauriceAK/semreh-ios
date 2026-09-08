"""Local disposable-directory fixtures only; never contacts a server."""
import base64
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import direct_hermes_managed_files_probe as probe

NAME = "semreh-managed-probe-" + "a" * 32 + ".md"


class Response:
    def __init__(self, body, status=200):
        self.body, self.status_code = body, status

    def json(self):
        return self.body


class Client:
    def __init__(self, root, failure=None):
        self.root, self.failure, self.calls = root, failure, []

    async def get(self, route, *, params):
        self.calls.append(("GET", route, params))
        target = self.root / "tools" / NAME
        if route == "/api/profiles":
            home = self.root / "home" if self.failure != "profile" else Path("/private/home")
            return Response({"profiles": [{"name": "default", "path": str(home)}]})
        if route == "/api/profiles/active":
            return Response({"active": "default", "current": "default"})
        if route == "/api/files":
            return Response({"path": str(target.parent), "root": str(target.parent),
                "locked_root": str(target.parent), "entries": [
                    {"name": target.name, "path": str(target), "is_directory": False}
                ] if target.exists() else []})
        if route == "/api/files/read":
            if self.failure == "changed":
                target.write_bytes(b"changed by another writer")
                return Response({}, 500)
            if self.failure == "read":
                return Response({}, 500)
            return Response({"name": target.name, "path": str(target), "size": len(probe.CONTENT),
                "data_url": "data:text/markdown;base64," + base64.b64encode(probe.CONTENT).decode()})
        raise AssertionError("unexpected read")

    async def post(self, route, *, data, files):
        self.calls.append(("POST", route, {"data": data, "files": files}))
        target = Path(data["path"])
        target.write_bytes(files["file"][1])
        if self.failure == "lost_receipt":
            raise RuntimeError("private transport error")
        if self.failure == "bad_receipt":
            return Response({"ok": True, "path": "/wrong"})
        return Response({"ok": True, "path": str(target)})

    async def request(self, method, route, *, json):
        self.calls.append((method, route, json))
        if self.failure == "delete":
            return Response({}, 500)
        Path(json["path"]).unlink()
        return Response({"ok": True})


class ManagedFileProbeTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        (self.root / "tools").mkdir()
        (self.root / "home").mkdir()
        self.runtime = patch.object(probe.stock_probe, "RUNTIME", self.root)
        self.runtime.start()

    def tearDown(self):
        self.runtime.stop()
        self.temp.cleanup()

    async def test_exact_multipart_roundtrip_listing_cleanup_and_sanitized_evidence(self):
        client, evidence = Client(self.root), {}
        await probe.exercise(client, evidence, NAME)
        self.assertEqual([c[:2] for c in client.calls], [
            ("GET", "/api/profiles"), ("GET", "/api/profiles/active"),
            ("GET", "/api/files"), ("POST", "/api/files/upload-stream"),
            ("GET", "/api/files/read"), ("GET", "/api/files"), ("DELETE", "/api/files")])
        target = str(self.root / "tools" / NAME)
        self.assertEqual(client.calls[3][2], {"data": {"path": target, "overwrite": "false"},
            "files": {"file": (NAME, probe.CONTENT, "text/markdown")}})
        self.assertEqual(client.calls[-1][2], {"path": target, "recursive": False})
        self.assertTrue(evidence["roundtrip_verified"])
        self.assertTrue(evidence["cleanup_verified"])
        self.assertFalse(evidence["uncertain_leftover"])
        self.assertLessEqual(evidence["byte_count"], 1024)
        for value in (str(self.root), NAME, probe.CONTENT.decode()):
            self.assertNotIn(value, json.dumps(evidence))

    async def test_unknown_upload_never_deletes_even_identical_bytes(self):
        for failure in ("lost_receipt", "bad_receipt"):
            with self.subTest(failure=failure):
                client, evidence = Client(self.root, failure), {}
                with self.assertRaises((RuntimeError, AssertionError)):
                    await probe.exercise(client, evidence, NAME)
                self.assertFalse(any(c[0] == "DELETE" for c in client.calls))
                self.assertTrue(evidence["uncertain_leftover"])
                (self.root / "tools" / NAME).unlink()

    async def test_confirmed_upload_read_failure_still_cleans_owned_file(self):
        client, evidence = Client(self.root, "read"), {}
        with self.assertRaises(AssertionError):
            await probe.exercise(client, evidence, NAME)
        self.assertTrue(evidence["cleanup_verified"])
        self.assertEqual(client.calls[-1][0], "DELETE")

    async def test_profile_collision_and_symlink_refuse_before_write(self):
        client = Client(self.root, "profile")
        with self.assertRaises(AssertionError):
            await probe.exercise(client, {}, NAME)
        self.assertFalse(any(c[0] == "POST" for c in client.calls))
        target = self.root / "tools" / NAME
        target.write_bytes(b"existing")
        with self.assertRaises(AssertionError):
            await probe.exercise(Client(self.root), {}, NAME)
        self.assertEqual(target.read_bytes(), b"existing")
        target.unlink()
        target.symlink_to(self.root / "missing")
        with self.assertRaises(AssertionError):
            probe.guarded_target(NAME)

    async def test_changed_file_refuses_cleanup_and_delete_failure_is_not_success(self):
        for failure in ("changed", "delete"):
            with self.subTest(failure=failure):
                client, evidence = Client(self.root, failure), {}
                with self.assertRaises(AssertionError):
                    await probe.exercise(client, evidence, NAME)
                self.assertFalse(evidence["cleanup_verified"])
                self.assertTrue((self.root / "tools" / NAME).exists())
                if failure == "changed":
                    self.assertFalse(any(c[0] == "DELETE" for c in client.calls))
                (self.root / "tools" / NAME).unlink()

    def test_forbidden_names_and_policy_roots(self):
        for name in ("MEMORY.md", "USER.md", "SOUL.md", "../escape", "probe.md"):
            with self.assertRaises(AssertionError):
                probe.guarded_target(name)
        with self.assertRaises(AssertionError):
            probe.check_listing({"path": str(self.root / "tools"), "root": "/private",
                "locked_root": "/private", "entries": []}, self.root / "tools")


if __name__ == "__main__":
    unittest.main()
