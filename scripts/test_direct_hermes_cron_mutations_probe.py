import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import direct_hermes_cron_mutations_probe as probe
from test_direct_hermes_skills_probe import Response


class Client:
    def __init__(self, lost_create=False, fail_pause=False, existing=False):
        self.job = {"id": "preexisting"} if existing else None
        self.calls = []
        self.lost_create, self.fail_pause = lost_create, fail_pause

    async def get(self, path, *, params=None):
        self.calls.append(("GET", path, params))
        if path == "/api/profiles":
            return Response({"profiles": [{"name": probe.PROFILE, "path": str(probe.stock_probe.RUNTIME / "home")}]})
        return Response(([dict(self.job)] if self.job else []) if path == probe.ROUTE else dict(self.job))

    async def post(self, path, *, params, json=None):
        self.calls.append(("POST", path, params))
        if path == probe.ROUTE:
            self.job = {**json, "id": "fixture-id", "profile": probe.PROFILE,
                        "schedule": {"kind": "once", "run_at": probe.SCHEDULE},
                        "enabled": True, "state": "scheduled", "next_run_at": probe.SCHEDULE}
            if self.lost_create:
                raise TimeoutError("unlogged raw response")
        else:
            paused = path.endswith("/pause")
            if paused and self.fail_pause:
                return Response({}, 500)
            self.job.update(enabled=not paused, state="paused" if paused else "scheduled")
        return Response(dict(self.job))

    async def delete(self, path, *, params):
        self.calls.append(("DELETE", path, params))
        self.job = None
        return Response({"ok": True})


class ProbeTests(unittest.IsolatedAsyncioTestCase):
    async def test_untrusted_receipt_cannot_delete_a_different_job(self):
        class Untrusted(Client):
            async def post(self, path, *, params, json=None):
                response = await super().post(path, params=params, json=json)
                if path == probe.ROUTE:
                    return Response({**response.json(), "id": "other-job"})
                return response

            async def get(self, path, *, params=None):
                if path.endswith("/other-job"):
                    self.calls.append(("GET", path, params))
                    return Response({"id": "other-job", "name": "someone-else", "profile": probe.PROFILE})
                return await super().get(path, params=params)

        client = Untrusted()
        evidence = {"cleanup_errors": []}
        with self.assertRaises(RuntimeError):
            await probe.exercise(client, evidence)
        self.assertFalse(any(method == "DELETE" for method, _, _ in client.calls))
        self.assertEqual(evidence["operation_error_type"], "AssertionError")
        self.assertEqual(evidence["cleanup_errors"], [{"operation": "owned_job_delete", "type": "AssertionError"}])

    async def test_cleanup_failure_keeps_primary_failure_diagnostic(self):
        class FailedCleanup(Client):
            async def delete(self, path, *, params):
                self.calls.append(("DELETE", path, params))
                return Response({}, 500)

        client = FailedCleanup(fail_pause=True)
        evidence = {"cleanup_errors": []}
        with self.assertRaises(RuntimeError):
            await probe.exercise(client, evidence)
        self.assertEqual(evidence["phase"], "pause")
        self.assertEqual(evidence["operation_error_type"], "RuntimeError")
        self.assertEqual(len(evidence["cleanup_errors"]), 1)
        self.assertEqual(sum(method == "DELETE" for method, _, _ in client.calls), 1)

    async def test_exact_scoped_writes_restore_empty_inventory(self):
        client = Client()
        evidence = {"cleanup_errors": []}
        await probe.exercise(client, evidence)
        writes = [(method, path) for method, path, _ in client.calls if method != "GET"]
        self.assertEqual(writes, [("POST", probe.ROUTE), ("POST", probe.ROUTE + "/fixture-id/pause"),
                                  ("POST", probe.ROUTE + "/fixture-id/resume"), ("DELETE", probe.ROUTE + "/fixture-id")])
        self.assertTrue(all(params == {"profile": probe.PROFILE} for _, path, params in client.calls if path != "/api/profiles"))
        self.assertTrue(evidence["restored_empty_inventory"])
        self.assertNotIn("SEMREH_CRON_PROBE", json.dumps(evidence))

    async def test_lost_create_ack_uses_lookup_not_retry(self):
        client = Client(lost_create=True)
        evidence = {"cleanup_errors": []}
        await probe.exercise(client, evidence)
        self.assertTrue(evidence["create_ack_recovered_by_unique_lookup"])
        self.assertEqual(sum(method == "POST" and path == probe.ROUTE for method, path, _ in client.calls), 1)

    async def test_failed_pause_cleans_only_owned_fixture(self):
        client = Client(fail_pause=True)
        evidence = {"cleanup_errors": []}
        with self.assertRaises(RuntimeError):
            await probe.exercise(client, evidence)
        self.assertTrue(evidence["restored_empty_inventory"])
        self.assertFalse(any(path.endswith("/resume") for _, path, _ in client.calls))

    async def test_preexisting_job_prevents_every_mutation(self):
        client = Client(existing=True)
        with self.assertRaises(AssertionError):
            await probe.exercise(client, {"cleanup_errors": []})
        self.assertEqual([method for method, _, _ in client.calls], ["GET", "GET"])

    async def test_wrong_profile_root_prevents_create(self):
        class WrongRoot(Client):
            async def get(self, path, *, params=None):
                self.calls.append(("GET", path, params))
                return Response({"profiles": [{"name": probe.PROFILE, "path": "/unapproved/home"}]})

        client = WrongRoot()
        with self.assertRaises(AssertionError):
            await probe.exercise(client, {"cleanup_errors": []})
        self.assertEqual(client.calls, [("GET", "/api/profiles", None)])


if __name__ == "__main__":
    unittest.main()
