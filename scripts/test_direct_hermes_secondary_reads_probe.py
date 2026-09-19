import json
from pathlib import Path
import sys
import unittest
import tempfile
from unittest.mock import patch
from contextlib import asynccontextmanager

sys.path.insert(0, str(Path(__file__).resolve().parent))
import direct_hermes_secondary_reads_probe as probe
from test_direct_hermes_skills_probe import Client, Response


class StartupClient(Client):
    async def post(self, path, *, json):
        self.calls.append((path, json, "POST"))
        return self.responses.pop(0)


class SecondaryReadsTests(unittest.IsolatedAsyncioTestCase):
    def test_startup_snapshot_rejects_existing_or_symlinked_active_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            home = root / "home"
            home.mkdir()
            (home / "config.yaml").write_bytes(b"fixture-config")
            with patch.object(probe.stock_probe, "RUNTIME", root), \
                    patch.object(probe.stock_probe, "validate") as validate:
                self.assertEqual(len(probe.startup_default_snapshot()), 32)
                validate.assert_called_once()
                active = home / "active_profile"
                active.symlink_to(home / "missing")
                with self.assertRaises(AssertionError):
                    probe.startup_default_snapshot()
                active.unlink()
                active.write_text("default")
                with self.assertRaises(AssertionError):
                    probe.startup_default_snapshot()

    def startup_responses(self):
        return [Response({"profiles": [{"name": "default", "path": str(probe.stock_probe.RUNTIME / "home")}]}),
                Response({"active": "default", "current": "default"}),
                Response({"ok": True, "active": "default"}),
                Response({"active": "default", "current": "default"})]

    async def test_startup_default_opt_in_exact_post_readback_and_sanitization(self):
        client = StartupClient(self.startup_responses())
        evidence = {}
        with patch.object(probe, "startup_default_snapshot", return_value=b"stable") as snapshot:
            await probe.verify_startup_default_same_value(client, evidence)
        self.assertEqual(snapshot.call_count, 3)
        self.assertEqual(client.calls, [("/api/profiles", None), ("/api/profiles/active", None),
                                       ("/api/profiles/active", {"name": "default"}, "POST"),
                                       ("/api/profiles/active", None)])
        state = evidence["startup_default_same_value"]
        self.assertTrue(state["verified"])
        self.assertFalse(state["changed_default_tested"])
        self.assertFalse(state["restart_tested"])
        self.assertFalse(state["native_picker_tested"])
        self.assertNotIn(str(probe.stock_probe.RUNTIME), json.dumps(evidence))

    async def test_startup_default_rejects_wrong_root_or_profile_before_post(self):
        for bad_index, bad_response in [
            (0, Response({"profiles": [{"name": "default", "path": "/unowned"}]})),
            (1, Response({"active": "other", "current": "default"})),
            (1, Response({"active": "default", "current": "other"}))
        ]:
            responses = self.startup_responses()
            responses[bad_index] = bad_response
            client = StartupClient(responses)
            with patch.object(probe, "startup_default_snapshot", return_value=b"stable"):
                with self.assertRaises(AssertionError):
                    await probe.verify_startup_default_same_value(client, {})
            self.assertFalse(any(len(call) == 3 for call in client.calls))

    async def test_startup_default_guard_failure_and_config_drift_prevent_post(self):
        for snapshots in [[AssertionError("unsafe local path")], [b"before", b"changed"]]:
            client = StartupClient(self.startup_responses())
            with patch.object(probe, "startup_default_snapshot", side_effect=snapshots):
                with self.assertRaises(AssertionError):
                    await probe.verify_startup_default_same_value(client, {})
            self.assertFalse(any(len(call) == 3 for call in client.calls))

    async def test_startup_default_ack_or_readback_failure_never_retries(self):
        for bad_index, bad_response in [(2, Response({"ok": False, "active": "default"})),
                                        (3, Response({"active": "other", "current": "default"}))]:
            responses = self.startup_responses()
            responses[bad_index] = bad_response
            client = StartupClient(responses)
            evidence = {}
            with patch.object(probe, "startup_default_snapshot", return_value=b"stable") as snapshot:
                with self.assertRaises(AssertionError):
                    await probe.verify_startup_default_same_value(client, evidence)
            self.assertEqual(snapshot.call_count, 3)
            self.assertEqual(sum(len(call) == 3 for call in client.calls), 1)
            self.assertFalse(evidence["startup_default_same_value"]["verified"])

    async def test_startup_default_postwrite_local_drift_never_marks_verified(self):
        client = StartupClient(self.startup_responses())
        evidence = {}
        with patch.object(probe, "startup_default_snapshot", side_effect=[b"stable", b"stable", b"changed"]):
            with self.assertRaises(AssertionError):
                await probe.verify_startup_default_same_value(client, evidence)
        self.assertFalse(evidence["startup_default_same_value"]["verified"])

    async def test_authenticated_default_does_not_invoke_write_probe(self):
        client = Client(self.prefix([]))
        @asynccontextmanager
        async def authentication(*args, **kwargs):
            yield client, None
        with patch.object(probe, "authenticated", authentication), \
                patch.object(probe, "verify_startup_default_same_value") as write_probe:
            await probe._run_authenticated({}, {})
        write_probe.assert_not_called()

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
