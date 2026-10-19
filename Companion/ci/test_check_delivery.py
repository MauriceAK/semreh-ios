import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import check_delivery


PRIVACY = {
    "NSPrivacyAccessedAPITypes": [{
        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
        "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
    }, {
        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime",
        "NSPrivacyAccessedAPITypeReasons": ["35F9.1"],
    }],
    "NSPrivacyCollectedDataTypes": [], "NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [],
}


class IPAContractTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.ipa = Path(self.directory.name) / "HermesCompanion.ipa"
        source = Path(self.directory.name) / check_delivery.PRIVACY_PATH
        source.parent.mkdir(parents=True)
        source.write_bytes(plistlib.dumps(PRIVACY))
        root = patch("check_delivery.ROOT", Path(self.directory.name))
        root.start()
        self.addCleanup(root.stop)

    def write_ipa(self, privacy=PRIVACY, **overrides):
        info = {
            "CFBundleIdentifier": "com.maurice.semreh", "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "35", "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}},
        }
        info.update(overrides)
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/HermesCompanion.app/Info.plist", plistlib.dumps(info))
            if privacy is not None:
                contents = privacy if isinstance(privacy, bytes) else plistlib.dumps(privacy)
                archive.writestr("Payload/HermesCompanion.app/PrivacyInfo.xcprivacy", contents)

    def test_missing_malformed_or_incorrect_privacy_manifest_fails_before_signing(self):
        cases = [None, b"invalid plist", {}, {"NSPrivacyAccessedAPITypes": []},
                 {"NSPrivacyAccessedAPITypes": PRIVACY["NSPrivacyAccessedAPITypes"][:1]},
                 {"NSPrivacyAccessedAPITypes": [{
                     "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                     "NSPrivacyAccessedAPITypeReasons": ["1C8F.1"],
                 }]}]
        for privacy in cases:
            with self.subTest(privacy=privacy):
                self.write_ipa(privacy=privacy)
                with patch("check_delivery.subprocess.run") as command:
                    with self.assertRaises((AssertionError, KeyError, plistlib.InvalidFileException)):
                        check_delivery.check_ipa(self.ipa, "1.0", "35")
                    command.assert_not_called()

    def test_packaged_privacy_manifest_must_match_reviewed_source(self):
        self.write_ipa(privacy={**PRIVACY, "NSPrivacyTracking": True})
        with patch("check_delivery.subprocess.run") as command:
            with self.assertRaisesRegex(AssertionError, "differs from the reviewed source"):
                check_delivery.check_ipa(self.ipa, "1.0", "35")
            command.assert_not_called()

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
        provisioning = provisioning or {
            "TeamIdentifier": ["6D65NQ2V3Q"],
            "Entitlements": {
                "application-identifier": "6D65NQ2V3Q.com.maurice.semreh",
                "com.apple.developer.team-identifier": "6D65NQ2V3Q",
                "aps-environment": "production", "get-task-allow": False,
            },
            "DeveloperCertificates": [b"fixture-distribution-certificate"],
        }

        def run(command, **kwargs):
            output = b""
            if command[0] == "security":
                output = plistlib.dumps(provisioning)
            elif "--entitlements" in command:
                output = plistlib.dumps(entitlements)
            for argument in command:
                if argument.startswith("--extract-certificates="):
                    Path(argument.split("=", 1)[1] + "0").write_bytes(b"fixture-distribution-certificate")
            return subprocess.CompletedProcess(command, 0, stdout=output, stderr=b"")
        return run

    def test_receipt_requires_successful_signature_and_release_entitlements(self):
        self.write_ipa()
        with patch("check_delivery.subprocess.run", side_effect=self.command_result()) as command:
            receipt = check_delivery.check_ipa(self.ipa, "1.0", "35")
            self.assertTrue(receipt["signed_ipa_verified"])
            self.assertTrue(receipt["privacy_manifest_verified"])
            self.assertEqual(len(receipt["ipa_sha256"]), 64)
            self.assertTrue(any("--verify" in call.args[0] for call in command.call_args_list))
            self.assertTrue(any("--test-requirement" in call.args[0] for call in command.call_args_list))
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

    def test_ad_hoc_final_signature_is_rejected_by_apple_requirement(self):
        self.write_ipa()
        def reject_ad_hoc(command, **kwargs):
            if "--test-requirement" in command:
                self.assertIn('anchor apple generic and certificate leaf[subject.OU] = "6D65NQ2V3Q"', command)
                raise subprocess.CalledProcessError(1, command)
            return self.command_result()(command, **kwargs)
        with patch("check_delivery.subprocess.run", side_effect=reject_ad_hoc):
            with self.assertRaises(subprocess.CalledProcessError):
                check_delivery.check_ipa(self.ipa, "1.0", "35")

    def test_profile_must_authorize_production_push_identity_and_signing_certificate(self):
        self.write_ipa()
        required = {
            "application-identifier": "6D65NQ2V3Q.com.maurice.semreh",
            "com.apple.developer.team-identifier": "6D65NQ2V3Q", "aps-environment": "production",
        }
        for field in required:
            entitlements = {key: value for key, value in required.items() if key != field}
            profile = {"TeamIdentifier": ["6D65NQ2V3Q"], "Entitlements": entitlements,
                       "DeveloperCertificates": [b"fixture-distribution-certificate"]}
            with patch("check_delivery.subprocess.run", side_effect=self.command_result(provisioning=profile)):
                with self.assertRaises((AssertionError, KeyError)):
                    check_delivery.check_ipa(self.ipa, "1.0", "35")
        profile = {"TeamIdentifier": ["6D65NQ2V3Q"], "Entitlements": required,
                   "DeveloperCertificates": [b"different-certificate"]}
        with patch("check_delivery.subprocess.run", side_effect=self.command_result(provisioning=profile)):
            with self.assertRaisesRegex(AssertionError, "not authorized"):
                check_delivery.check_ipa(self.ipa, "1.0", "35")


class ArchivePreparationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.archive = root / "HermesCompanion.xcarchive"
        self.app = self.archive / "Products/Applications/HermesCompanion.app"
        self.app.mkdir(parents=True)
        self.info = {"CFBundleIdentifier": "com.maurice.semreh", "CFBundleShortVersionString": "1.0",
                     "CFBundleVersion": "35", "CFBundleSupportedPlatforms": ["iPhoneOS"]}
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))
        (self.archive / "Info.plist").write_bytes(plistlib.dumps({"ApplicationProperties": {
            "ApplicationPath": "Applications/HermesCompanion.app"}}))
        self.source = root / "ios/HermesCompanion/HermesCompanion.entitlements"
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(plistlib.dumps({"aps-environment": "$(APNS_ENVIRONMENT)"}))
        scope = patch("check_delivery.ROOT", root)
        scope.start()
        self.addCleanup(scope.stop)

    def test_intermediate_archive_preserves_reviewed_production_entitlements(self):
        captured = {}
        def run(command, **kwargs):
            if "--sign" in command:
                self.assertEqual(command[command.index("--sign") + 1], "-")
                captured.update(plistlib.loads(Path(command[command.index("--entitlements") + 1]).read_bytes()))
            output = plistlib.dumps(captured) if "-d" in command else b""
            return subprocess.CompletedProcess(command, 0, stdout=output, stderr=b"")
        with patch("check_delivery.subprocess.run", side_effect=run):
            receipt = check_delivery.prepare_archive(self.archive, "1.0", "35")
        self.assertEqual(captured["aps-environment"], "production")
        self.assertEqual(captured["application-identifier"], "6D65NQ2V3Q.com.maurice.semreh")
        self.assertTrue(receipt["archive_entitlements_verified"])
        self.assertEqual(receipt["archive_signature"], "ad_hoc_intermediate")
        self.assertNotIn("signed_ipa_verified", receipt)

    def test_wrong_archive_identity_or_unreviewed_entitlements_fail_before_signing(self):
        for info in [{**self.info, "CFBundleIdentifier": "org.hermescompanion.beta"},
                     {**self.info, "CFBundleVersion": "34"},
                     {**self.info, "CFBundleSupportedPlatforms": ["iPhoneSimulator"]}]:
            (self.app / "Info.plist").write_bytes(plistlib.dumps(info))
            with patch("check_delivery.subprocess.run") as command:
                with self.assertRaises(AssertionError):
                    check_delivery.prepare_archive(self.archive, "1.0", "35")
                command.assert_not_called()
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))
        self.source.write_bytes(plistlib.dumps({"aps-environment": "production", "unexpected-capability": True}))
        with patch("check_delivery.subprocess.run") as command:
            with self.assertRaises(AssertionError):
                check_delivery.prepare_archive(self.archive, "1.0", "35")
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
