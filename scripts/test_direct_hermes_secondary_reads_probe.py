import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import direct_hermes_secondary_reads_probe as probe
from test_direct_hermes_skills_probe import Client, Response


class SecondaryReadsTests(unittest.IsolatedAsyncioTestCase):
    def prefix(self, jobs):
        return [Response({"active": "private-name", "current": "default"}), Response(jobs),
                Response({"targets": [{"id": "private-target", "name": "private-label"}]})]

    async def test_empty_inventory_keeps_detail_unverified(self):
        client = Client(self.prefix([]))
        evidence = {}
        await probe.exercise(client, evidence)
        self.assertEqual(len(client.calls), 3)
        self.assertFalse(evidence["detail_runs"]["verified"])
        self.assertEqual(client.calls[0], ("/api/profiles/active", None))
        self.assertEqual(client.calls[1], ("/api/cron/jobs", {"profile": probe.PROFILE}))
        self.assertEqual(client.calls[2], ("/api/cron/delivery-targets", None))

    async def test_scoped_detail_runs_and_sanitization(self):
        job = {"id": "private-job", "profile": probe.PROFILE, "prompt": "private-prompt",
               "hermes_home": "/private/home", "enabled": False, "schedule": {}}
        client = Client(self.prefix([job]) + [Response(job), Response({"runs": [
            {"id": "cron_private-job_123", "profile": probe.PROFILE, "title": "private-title"}], "limit": 5})])
        evidence = {}
        await probe.exercise(client, evidence)
        self.assertEqual(client.calls[3], ("/api/cron/jobs/private-job", {"profile": probe.PROFILE}))
        self.assertEqual(client.calls[4], ("/api/cron/jobs/private-job/runs", {"profile": probe.PROFILE, "limit": 5}))
        self.assertTrue(evidence["detail_runs"]["verified"])
        self.assertNotIn("private", json.dumps(evidence))

    async def test_rejects_wrong_profile_and_legacy_list(self):
        for jobs in ({"jobs": []}, [{"id": "one", "profile": "other"}]):
            with self.assertRaises(AssertionError):
                await probe.exercise(Client(self.prefix(jobs)), {})

    async def test_rejects_wrong_run_lineage(self):
        job = {"id": "one", "profile": probe.PROFILE}
        client = Client(self.prefix([job]) + [Response(job), Response({"runs": [
            {"id": "cron_other_123", "profile": probe.PROFILE}], "limit": 5})])
        with self.assertRaises(AssertionError):
            await probe.exercise(client, {})

    async def test_http_error_never_marks_success(self):
        with self.assertRaises(RuntimeError):
            await probe.exercise(Client([Response({}, 401)]), {})


if __name__ == "__main__":
    unittest.main()
