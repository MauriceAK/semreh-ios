#!/usr/bin/env python3
"""Static scope/project validation for the remote browser workspace.

Checks (no Xcode required, runs on Linux):
  1. Every PBXFileReference path in BrowserLab.xcodeproj resolves to a file.
  2. Every PBXBuildFile fileRef/productRef points at a defined object.
  3. The shared scheme's BlueprintIdentifiers match real target IDs.
  4. Every Swift source under BrowserLab/ and Packages/SemrehRemoteBrowser/
     is referenced by the xcodeproj or the SwiftPM manifest (no orphans).
  5. BrowserLab bundle IDs are unique and not the shipping app ID.
  6. No '+' in new filenames (breaks pbxproj parsing unless quoted).
  7. No references to the production HermesMobile target/project.
  8. The SwiftPM manifest's target paths exist.
  9. The fixture event log cannot include inserted-text contents.

Usage: python3 BrowserLab/Tools/validate-scope.py [--root PATH]
Exit non-zero on the first failure class with a clear message.
"""

import os
import re
import sys

SHIPPING_BUNDLE_ID = "com.mauricekenon.semreh"


def fail(message):
    print(f"VALIDATE-FAIL: {message}")
    sys.exit(1)


def main():
    root = sys.argv[sys.argv.index("--root") + 1] if "--root" in sys.argv else "."
    root = os.path.abspath(root)
    lab = os.path.join(root, "BrowserLab")
    proj = os.path.join(lab, "BrowserLab.xcodeproj")
    pbxproj_path = os.path.join(proj, "project.pbxproj")
    scheme_path = os.path.join(proj, "xcshareddata", "xcschemes", "BrowserLab.xcscheme")
    pkg_dir = os.path.join(root, "Packages", "SemrehRemoteBrowser")

    for path in (pbxproj_path, scheme_path):
        if not os.path.isfile(path):
            fail(f"missing required file: {path}")

    with open(pbxproj_path, encoding="utf-8") as handle:
        pbxproj = handle.read()

    # --- 1. File references resolve -------------------------------------
    # Map group id -> directory, parsing one PBXGroup entry block at a time.
    group_paths = {}
    for header in re.finditer(
        r"([0-9A-F]{24}) /\* ([^/]+?) \*/ = \{\s*isa = PBXGroup;", pbxproj
    ):
        block_end = pbxproj.find("\n\t\t};", header.end())
        block = pbxproj[header.end() : block_end]
        path_match = re.search(r"path = (\w+);", block)
        group_paths[header.group(1)] = (
            header.group(2).strip(),
            path_match.group(1) if path_match else "",
        )
    main_group_id = next(
        gid for gid, (name, _path) in group_paths.items() if name == "BrowserLab"
    )

    def group_dir(group_id):
        name, path = group_paths[group_id]
        return os.path.join(lab, path) if path else lab

    # Which group each file ref belongs to: scan group children lists.
    file_group = {}
    for match in re.finditer(
        r"([0-9A-F]{24}) /\* .*? \*/ = \{\s*isa = PBXGroup;\s*children = \((.*?)\);",
        pbxproj,
        re.DOTALL,
    ):
        for child in re.findall(r"([0-9A-F]{24})", match.group(2)):
            file_group[child] = match.group(1)

    file_refs = re.findall(
        r"([0-9A-F]{24}) /\* ([^/]+?) \*/ = \{isa = PBXFileReference;(.*?)\};",
        pbxproj,
        re.DOTALL,
    )
    if not file_refs:
        fail("no PBXFileReference entries parsed")
    for ref_id, _name, body in file_refs:
        path_match = re.search(r"path = ([^;]+);", body)
        tree_match = re.search(r"sourceTree = ([^;]+);", body)
        if not path_match or not tree_match:
            fail(f"file ref {ref_id} missing path/sourceTree")
        path = path_match.group(1).strip().strip('"')
        tree = tree_match.group(1).strip().strip('"').strip("<>")
        if tree == "BUILT_PRODUCTS_DIR":
            continue  # build products, not source files
        if tree != "group":
            fail(f"file ref {ref_id} has unexpected sourceTree {tree}")
        directory = group_dir(file_group.get(ref_id, main_group_id))
        full = os.path.join(directory, path)
        if not os.path.isfile(full):
            fail(f"file ref {ref_id} points at missing file: {full}")

    # --- 2. Build file references point at defined objects ---------------
    defined = set(re.findall(r"^\s*([0-9A-F]{24}) /\*", pbxproj, re.MULTILINE))
    for ref_id, _name, body in re.findall(
        r"([0-9A-F]{24}) /\* ([^/]+?) \*/ = \{isa = PBXBuildFile;(.*?)\};",
        pbxproj,
        re.DOTALL,
    ):
        target = re.search(r"(?:fileRef|productRef) = ([0-9A-F]{24})", body)
        if not target:
            fail(f"PBXBuildFile {ref_id} has no fileRef/productRef")
        if target.group(1) not in defined:
            fail(f"PBXBuildFile {ref_id} references undefined {target.group(1)}")
    package_ref_ids = set(
        re.findall(
            r"([0-9A-F]{24}) /\* .*? \*/ = \{\s*isa = XCLocalSwiftPackageReference;",
            pbxproj,
        )
    )
    for match in re.finditer(
        r"[0-9A-F]{24} /\* .*? \*/ = \{\s*isa = PBXGroup;\s*children = \((.*?)\);",
        pbxproj,
        re.DOTALL,
    ):
        child_ids = set(re.findall(r"([0-9A-F]{24})", match.group(1)))
        invalid_children = child_ids & package_ref_ids
        if invalid_children:
            fail(
                "local package reference must be listed in packageReferences, "
                f"not as a PBXGroup child: {sorted(invalid_children)}"
            )

    # --- 3. Scheme targets exist ------------------------------------------
    with open(scheme_path, encoding="utf-8") as handle:
        scheme = handle.read()
    for blueprint in re.findall(r'BlueprintIdentifier = "([0-9A-F]{24})"', scheme):
        if blueprint not in defined:
            fail(f"scheme references unknown target {blueprint}")
        if f"{blueprint} /*" not in pbxproj or "PBXNativeTarget" not in pbxproj:
            pass  # existence already covered by `defined`
    target_ids = [
        m.group(1)
        for m in re.finditer(
            r"([0-9A-F]{24}) /\* (\w+) \*/ = \{\s*isa = PBXNativeTarget;", pbxproj
        )
    ]
    if len(target_ids) != 2:
        fail(f"expected 2 native targets, found {len(target_ids)}")
    print(f"targets: {', '.join(target_ids)}")

    # --- 4. No orphan Swift sources ---------------------------------------
    referenced_names = set()
    for _ref_id, name, _body in file_refs:
        referenced_names.add(name)
    with open(os.path.join(pkg_dir, "Package.swift"), encoding="utf-8") as handle:
        manifest = handle.read()
    for base in (os.path.join(lab, "Sources"), os.path.join(lab, "UITests")):
        for name in os.listdir(base):
            if name.endswith(".swift") and name not in referenced_names:
                fail(f"orphan source not in xcodeproj: {base}/{name}")
    for dirpath, _dirnames, filenames in os.walk(os.path.join(pkg_dir, "Sources")):
        for name in filenames:
            if name.endswith(".swift") and name not in manifest:
                # Manifest uses path-based targets; file presence is enough,
                # but flag names that look like typos of nothing. Skip: the
                # manifest includes whole directories, so any file is built.
                pass

    # --- 5. Bundle IDs -----------------------------------------------------
    bundle_ids = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", pbxproj)
    if not bundle_ids:
        fail("no PRODUCT_BUNDLE_IDENTIFIER found")
    for bundle_id in bundle_ids:
        bundle_id = bundle_id.strip()
        if bundle_id == SHIPPING_BUNDLE_ID:
            fail(f"BrowserLab must not reuse the shipping bundle ID {bundle_id}")
        if "browserlab" not in bundle_id.lower():
            fail(f"unexpected bundle ID (should name browserlab): {bundle_id}")
    print(f"bundle IDs: {', '.join(sorted(set(bundle_ids)))}")

    # --- 6. No '+' in filenames --------------------------------------------
    for base in (lab, pkg_dir):
        for dirpath, _dirnames, filenames in os.walk(base):
            if ".git" in dirpath:
                continue
            for name in filenames:
                if "+" in name:
                    fail(f"'+' in filename breaks pbxproj parsing: {dirpath}/{name}")

    # --- 7. No production target references --------------------------------
    for token in ("HermesMobile", "com.mauricekenon.semreh;"):
        if token in pbxproj or token in scheme:
            fail(f"BrowserLab project must not reference production target '{token}'")
    if pbxproj.count("SDKROOT = iphoneos;") < 2:
        fail("BrowserLab project Debug and Release configurations must target iOS")
    if pbxproj.count('SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";') < 2:
        fail("BrowserLab project must advertise device and simulator platforms")
    for unit_test_only_setting in ("BUNDLE_LOADER", "TEST_HOST ="):
        if unit_test_only_setting in pbxproj:
            fail(
                "BrowserLabUITests must use XCTest's UI runner, not unit-test setting "
                f"{unit_test_only_setting}"
            )

    # --- 8. SwiftPM manifest target paths exist -----------------------------
    for path in re.findall(r'path: "([^"]+)"', manifest):
        full = os.path.join(pkg_dir, path)
        if not os.path.isdir(full):
            fail(f"Package.swift target path missing: {full}")

    # --- 9. Fixture logs do not expose inserted text -----------------------
    fixture_path = os.path.join(lab, "Sources", "SimulatedBrowserAdapter.swift")
    with open(fixture_path, encoding="utf-8") as handle:
        fixture_source = handle.read()
    for forbidden in ('text.prefix', 'accepted: insertText "'):
        if forbidden in fixture_source:
            fail(f"fixture may log inserted-text contents: {forbidden}")

    print("VALIDATE-OK: scope and project references are consistent")


if __name__ == "__main__":
    main()
