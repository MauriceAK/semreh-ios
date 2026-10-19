import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import check_delivery


class IPAContractTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.ipa = Path(self.directory.name) / "HermesCompanion.ipa"

    def write_ipa(self, **overrides):
        info = {
            "CFBundleIdentifier": "com.maurice.semreh", "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "35", "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}},
        }
        info.update(overrides)
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/HermesCompanion.app/Info.plist", plistlib.dumps(info))

    def test_missing_artifact_fails(self):
        with self.assertRaises(AssertionError):
            check_delivery.check_ipa(self.ipa, "1.0", "35")

    def test_wrong_identity_version_build_and_simulator_fail_before_signing(self):
        for change in [dict(CFBundleIdentifier="org.hermescompanion.beta"),
                       dict(CFBundleShortVersionString="0.1.0"), dict(CFBundleVersion="34"),
                       dict(CFBundleSupportedPlatforms=["iPhoneSimulator"]), dict(CFBundleIcons={})]:
            self.write_ipa(**change)
            with patch("check_delivery.subprocess.run") as command:
                with self.assertRaises((AssertionError, KeyError)):
                    check_delivery.check_ipa(self.ipa, "1.0", "35")
                command.assert_not_called()

    def command_result(self, entitlements=None, provisioning=None):
        entitlements = entitlements or {
            "application-identifier": "6D65NQ2V3Q.com.maurice.semreh",
            "com.apple.developer.team-identifier": "6D65NQ2V3Q",
            "aps-environment": "production", "get-task-allow": False,
        }
        provisioning = provisioning or {"TeamIdentifier": ["6D65NQ2V3Q"]}

        def run(command, **kwargs):
            output = b""
            if command[0] == "security":
                output = plistlib.dumps(provisioning)
            elif "--entitlements" in command:
                output = plistlib.dumps(entitlements)
            return subprocess.CompletedProcess(command, 0, stdout=output, stderr=b"")
        return run

    def test_receipt_requires_successful_signature_and_release_entitlements(self):
        self.write_ipa()
        with patch("check_delivery.subprocess.run", side_effect=self.command_result()) as command:
            receipt = check_delivery.check_ipa(self.ipa, "1.0", "35")
            self.assertTrue(receipt["signed_ipa_verified"])
            self.assertEqual(len(receipt["ipa_sha256"]), 64)
            self.assertTrue(any("--verify" in call.args[0] for call in command.call_args_list))
        with patch("check_delivery.subprocess.run", side_effect=subprocess.CalledProcessError(1, "codesign")):
            with self.assertRaises(subprocess.CalledProcessError):
                check_delivery.check_ipa(self.ipa, "1.0", "35")

    def test_development_push_or_device_limited_profile_fail(self):
        self.write_ipa()
        entitlements = {
            "application-identifier": "6D65NQ2V3Q.com.maurice.semreh",
            "com.apple.developer.team-identifier": "6D65NQ2V3Q", "aps-environment": "development",
        }
        cases = [self.command_result(entitlements=entitlements),
                 self.command_result(provisioning={"TeamIdentifier": ["6D65NQ2V3Q"], "ProvisionedDevices": ["fixture"]})]
        for command in cases:
            with patch("check_delivery.subprocess.run", side_effect=command):
                with self.assertRaises(AssertionError):
                    check_delivery.check_ipa(self.ipa, "1.0", "35")


if __name__ == "__main__":
    unittest.main()
