#!/usr/bin/env python3
"""Pure routing and sanitized-contract checks for the read-only skills probe."""

import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import direct_hermes_skills_probe as probe


class Response:
    def __init__(self, payload, status=200):
        self.payload, self.status_code = payload, status

    def json(self):
        return self.payload


class Client:
    def __init__(self, responses):
        self.responses, self.calls = list(responses), []

    async def get(self, path, *, params):
        self.calls.append((path, params))
        return self.responses.pop(0)


class SkillsProbeTests(unittest.IsolatedAsyncioTestCase):
    async def test_routes_are_get_only_scoped_and_evidence_omits_values(self):
        name = "private skill & /name"
        client = Client([
            Response([{"name": name, "enabled": False, "description": "private description",
                       "private-key": "secret"}]),
            Response({"name": name, "content": "private content", "path": "/private/host/SKILL.md"}),
        ])
        evidence = {}
        await probe.exercise(client, evidence)
        self.assertEqual(client.calls, [
            ("/api/skills", {"profile": probe.PROFILE}),
            ("/api/skills/content", {"profile": probe.PROFILE, "name": name}),
        ])
        self.assertTrue(evidence["content"]["verified"])
        self.assertEqual(evidence["list"]["response"]["disabled_count"], 1)
        encoded = json.dumps(evidence)
        for value in (name, "private description", "private content", "/private/host", "private-key", "secret"):
            self.assertNotIn(value, encoded)

    async def test_empty_list_skips_content_and_marks_unverified(self):
        client = Client([Response([])])
        evidence = {}
        await probe.exercise(client, evidence)
        self.assertEqual(len(client.calls), 1)
        self.assertEqual(evidence["content"], {"verified": False, "reason": "empty_inventory"})

    async def test_missing_listed_skill_remains_unverified(self):
        client = Client([Response([{"name": "gone", "enabled": True}]), Response({}, 404)])
        evidence = {}
        await probe.exercise(client, evidence)
        self.assertFalse(evidence["content"]["verified"])
        self.assertEqual(evidence["content"]["reason"], "listed_skill_unavailable")

    async def test_http_failure_is_not_shape_success(self):
        for responses in ([Response({}, 401)],
                          [Response([{"name": "one", "enabled": True}]), Response({}, 500)]):
            with self.assertRaises(RuntimeError):
                await probe.exercise(Client(responses), {})

    def test_rejects_legacy_and_malformed_list_shapes(self):
        for payload in ({"skills": []}, [{}], [{"name": "one", "disabled": False}],
                        [{"name": "one", "enabled": 1}], ["one"]):
            with self.subTest(payload=payload), self.assertRaises(AssertionError):
                probe.list_summary(payload)

    def test_rejects_mismatched_content_and_invalid_fields(self):
        for payload in ({"name": "other", "content": "x", "path": "x"},
                        {"name": "one", "content": None, "path": "x"},
                        {"name": "one", "content": "x"}):
            with self.subTest(payload=payload), self.assertRaises(AssertionError):
                probe.content_summary(payload, "one")


if __name__ == "__main__":
    unittest.main()
