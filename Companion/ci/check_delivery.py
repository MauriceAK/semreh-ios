import argparse
import hashlib
import json
import plistlib
import struct
import subprocess
import tempfile
import zipfile
from pathlib import Path


BUNDLE_ID = "com.maurice.semreh"
TEAM_ID = "6D65NQ2V3Q"
ROOT = Path(__file__).resolve().parent.parent
PRIVACY_PATH = Path("ios/HermesCompanion/PrivacyInfo.xcprivacy")


def check_privacy(data):
    manifest = plistlib.loads(data)
    accessed = manifest["NSPrivacyAccessedAPITypes"]
    defaults = [entry for entry in accessed
                if entry["NSPrivacyAccessedAPIType"] == "NSPrivacyAccessedAPICategoryUserDefaults"]
    assert len(defaults) == 1, "Privacy manifest must declare the app's UserDefaults access"
    assert "CA92.1" in defaults[0]["NSPrivacyAccessedAPITypeReasons"], "Privacy manifest must declare app-only UserDefaults use"
    clocks = [entry for entry in accessed
              if entry["NSPrivacyAccessedAPIType"] == "NSPrivacyAccessedAPICategorySystemBootTime"]
    assert len(clocks) == 1 and "35F9.1" in clocks[0]["NSPrivacyAccessedAPITypeReasons"], "Privacy manifest must declare app-local elapsed diagnostics"
    return manifest


def check_source():
    check_privacy((ROOT / PRIVACY_PATH).read_bytes())
    info = plistlib.loads((ROOT / "ios/HermesCompanion/Info.plist").read_bytes())
    assert info["CFBundleVersion"] == "$(CURRENT_PROJECT_VERSION)", "Build number must use build settings"
    assert info["CFBundleShortVersionString"] == "$(MARKETING_VERSION)", "Version must use build settings"
    icon = ROOT / "ios/HermesCompanion/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    data = icon.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "App icon must be a PNG"
    width, height, depth, color = struct.unpack(">IIBB", data[16:26])
    assert (width, height, depth, color) == (1024, 1024, 8, 2), "App icon must be opaque RGB, 1024 square"
    export = plistlib.loads((ROOT / "ci/CompanionInternalExport.plist").read_bytes())
    assert export["teamID"] == TEAM_ID and export["testFlightInternalTestingOnly"] is True
    assert export["manageAppVersionAndBuildNumber"] is False
    print("Delivery source metadata and opaque app icon passed")


def prepare_archive(path, version, number):
    assert path.is_dir() and path.suffix == ".xcarchive", "Expected an existing Xcode archive"
    properties = plistlib.loads((path / "Info.plist").read_bytes())["ApplicationProperties"]
    relative = Path(properties["ApplicationPath"])
    assert not relative.is_absolute() and ".." not in relative.parts
    assert relative.parts == ("Applications", "HermesCompanion.app"), "Unexpected archived application"
    products = (path / "Products").resolve()
    app = products / relative
    assert app.resolve().is_relative_to(products) and not app.is_symlink()
    info = plistlib.loads((app / "Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == BUNDLE_ID, "Archive has the wrong app identity"
    assert info["CFBundleShortVersionString"] == version and info["CFBundleVersion"] == number
    assert "iPhoneOS" in info["CFBundleSupportedPlatforms"], "Archive is not a physical-device build"
    assert not list(app.rglob("*.appex")) and not list(app.rglob("*.framework")), "Nested code requires a reviewed signing plan"
    source = plistlib.loads((ROOT / "ios/HermesCompanion/HermesCompanion.entitlements").read_bytes())
    assert source == {"aps-environment": "$(APNS_ENVIRONMENT)"}, "Review changed archive entitlements before signing"
    entitlements = {
        "aps-environment": "production",
        "application-identifier": f"{TEAM_ID}.{BUNDLE_ID}",
        "com.apple.developer.team-identifier": TEAM_ID,
        "get-task-allow": False,
    }
    with tempfile.TemporaryDirectory(prefix="companion-archive-entitlements-") as directory:
        entitlement_path = Path(directory) / "archive.plist"
        entitlement_path.write_bytes(plistlib.dumps(entitlements))
        subprocess.run(["codesign", "--force", "--sign", "-", "--generate-entitlement-der",
                        "--entitlements", str(entitlement_path), str(app)], check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True, capture_output=True)
    signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], check=True, capture_output=True)
    assert plistlib.loads(signed.stdout) == entitlements, "Archive signature did not preserve the reviewed entitlements"
    return {"archive_entitlements_verified": True, "archive_signature": "ad_hoc_intermediate"}


def check_ipa(path, version, number):
    assert path.is_file() and path.stat().st_size > 0, "The archive did not produce an IPA"
    with zipfile.ZipFile(path) as archive:
        infos = [name for name in archive.namelist() if name.startswith("Payload/")
                 and len(name.split("/")) == 3 and name.endswith(".app/Info.plist")]
        assert len(infos) == 1, "IPA must contain exactly one app"
        info = plistlib.loads(archive.read(infos[0]))
        assert info["CFBundleIdentifier"] == BUNDLE_ID, "IPA has the wrong app identity"
        assert info["CFBundleShortVersionString"] == version, "IPA has the wrong marketing version"
        assert info["CFBundleVersion"] == number, "IPA has the wrong build number"
        assert "iPhoneOS" in info["CFBundleSupportedPlatforms"], "IPA is not a physical-device build"
        assert info["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconName"] == "AppIcon"
        privacy_path = str(Path(infos[0]).parent / "PrivacyInfo.xcprivacy")
        assert privacy_path in archive.namelist(), "IPA is missing its privacy manifest resource"
        privacy = check_privacy(archive.read(privacy_path))
        assert privacy == check_privacy((ROOT / PRIVACY_PATH).read_bytes()), "IPA privacy manifest differs from the reviewed source"
        assert all(not name.startswith("/") and ".." not in Path(name).parts for name in archive.namelist())
    with tempfile.TemporaryDirectory(prefix="companion-ipa-") as directory:
        subprocess.run(["ditto", "-xk", str(path), directory], check=True, capture_output=True)
        app = Path(directory) / Path(infos[0]).parent
        requirement = f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM_ID}"'
        subprocess.run(["codesign", "--verify", "--strict", "--test-requirement", requirement, str(app)],
                       check=True, capture_output=True)
        signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], check=True, capture_output=True)
        entitlements = plistlib.loads(signed.stdout)
        assert entitlements["application-identifier"] == f"{TEAM_ID}.{BUNDLE_ID}"
        assert entitlements["com.apple.developer.team-identifier"] == TEAM_ID
        assert entitlements["aps-environment"] == "production"
        assert entitlements.get("get-task-allow", False) is False
        profile = subprocess.run(["security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")], check=True, capture_output=True)
        provisioning = plistlib.loads(profile.stdout)
        assert TEAM_ID in provisioning["TeamIdentifier"]
        assert "ProvisionedDevices" not in provisioning and not provisioning.get("ProvisionsAllDevices", False)
        assert provisioning["Entitlements"]["application-identifier"] == f"{TEAM_ID}.{BUNDLE_ID}"
        assert provisioning["Entitlements"]["com.apple.developer.team-identifier"] == TEAM_ID
        assert provisioning["Entitlements"]["aps-environment"] == "production"
        assert provisioning["Entitlements"].get("get-task-allow", False) is False
        certificate_prefix = Path(directory) / "signing-certificate"
        subprocess.run(["codesign", "-d", f"--extract-certificates={certificate_prefix}", str(app)],
                       check=True, capture_output=True)
        certificate = Path(str(certificate_prefix) + "0").read_bytes()
        assert certificate in provisioning["DeveloperCertificates"], "App signature is not authorized by its distribution profile"
    return {"bundle_id": BUNDLE_ID, "version": version, "build_number": number,
            "ipa_sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "signed_ipa_verified": True,
            "privacy_manifest_verified": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--ipa", type=Path)
    mode.add_argument("--archive", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--build-number")
    args = parser.parse_args()
    if args.ipa or args.archive:
        if not args.version or not args.build_number:
            parser.error("--version and --build-number are required")
        result = (prepare_archive(args.archive, args.version, args.build_number) if args.archive
                  else check_ipa(args.ipa, args.version, args.build_number))
        print(json.dumps(result))
    else:
        check_source()
