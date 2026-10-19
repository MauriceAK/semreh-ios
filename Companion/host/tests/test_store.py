import tempfile
import unittest
from datetime import datetime
from pathlib import Path

from companion.domain import APIError, is_quiet, preferences
from companion.store import Store


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = str(Path(self.temp.name) / "state.db")
        self.store = Store(self.path, "test-profile")

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def test_pairing_is_one_use_expiring_hashed_scoped_and_revocable(self):
        code = self.store.invite(now=100, scopes={"read"})
        pair = self.store.pair(code, "Phone", now=101)
        with self.assertRaises(APIError):
            self.store.pair(code, "Other phone", now=102)
        device = self.store.authenticate(pair["token"])
        self.assertEqual(device["id"], pair["device_id"])
        self.assertNotEqual(device["hash"], pair["token"])
        with self.assertRaises(APIError) as raised:
            self.store.authenticate(pair["token"], "chat")
        self.assertEqual(raised.exception.status, 403)
        self.store.revoke(device["id"])
        with self.assertRaises(APIError):
            self.store.authenticate(pair["token"])
        expired = self.store.invite(now=100)
        with self.assertRaises(APIError):
            self.store.pair(expired, "Late", now=700)

    def test_operation_crash_is_uncertain_and_payload_change_conflicts(self):
        self.assertIsNone(self.store.begin("device", "operation", "same-input"))
        self.store.close()
        self.store = Store(self.path, "test-profile")
        result, status = self.store.begin("device", "operation", "same-input")
        self.assertEqual((result["status"], status), ("uncertain", 409))
        with self.assertRaises(APIError) as raised:
            self.store.begin("device", "operation", "new-input")
        self.assertEqual(raised.exception.code, "operation_conflict")

    def test_finished_operation_returns_exact_outcome(self):
        self.store.begin("device", "id", "input")
        response = {"id": "canonical-hermes-id"}
        self.store.finish("device", "id", response)
        self.assertEqual(self.store.begin("device", "id", "input"), (response, 200))

    def test_profile_store_cannot_be_retargeted(self):
        with self.assertRaises(APIError) as raised:
            Store(self.path, "other-profile")
        self.assertEqual(raised.exception.code, "profile_mismatch")

    def test_quiet_hours_use_local_wall_clock_across_dst(self):
        prefs = preferences(dict(notifications_enabled=True, quiet_start=60, quiet_end=150, time_zone="America/Los_Angeles"))
        first_130 = datetime.fromisoformat("2026-11-01T08:30:00+00:00").timestamp()
        second_130 = datetime.fromisoformat("2026-11-01T09:30:00+00:00").timestamp()
        after = datetime.fromisoformat("2026-11-01T10:31:00+00:00").timestamp()
        self.assertTrue(is_quiet(prefs, first_130))
        self.assertTrue(is_quiet(prefs, second_130))
        self.assertFalse(is_quiet(prefs, after))
        prefs.update(quiet_start=22 * 60, quiet_end=7 * 60)
        self.assertTrue(is_quiet(prefs, first_130))

    def test_updates_deduplicate_and_survive_restart(self):
        device = self.store.pair(self.store.invite(), "Phone")
        update = self.store.add_update("hermes-run-1", {"kind": "result", "title": "Done", "summary": "Controlled fixture"}, {"run_id": "canonical-run"}, now=100)
        self.assertIsNone(self.store.add_update("hermes-run-1", {"kind": "result"}, {}, now=101))
        self.store.close()
        self.store = Store(self.path, "test-profile")
        self.assertEqual(self.store.updates(), [update])
        pending = self.store.deliveries(101)
        self.assertEqual((len(pending), pending[0]["device"]), (1, device["device_id"]))
