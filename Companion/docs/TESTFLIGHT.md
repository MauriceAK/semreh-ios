# Get Companion updates through Semreh TestFlight

The selected beta route reuses the existing Semreh App Store Connect app and its
GitHub credentials. Installing this build replaces the installed Semreh app with
Companion. Semreh's `master` branch and native source remain unchanged. A later
Semreh release can replace Companion again because both use the same app slot.

Local preparation is complete only after the checks below pass. No uploaded
Companion build is established by the presence of these files. Apple processing,
tester availability, and installation require the workflow's real result.

## Prepare the verified source

Finish the native checks and commit the exact Companion source, including the
regenerated Xcode project. Run the packager from the Companion repository with
that full revision and the isolated Semreh worktree path.

```sh
python3 ci/package_semreh.py \
	--revision VERIFIED_COMPANION_COMMIT \
	--destination /path/to/semreh-companion-testflight
```

The destination must be on `companion/chat-beta-testflight` at Semreh commit
`5fbef12e385716ac24cc6528ae0a8ff8da142a78`. The packager copies only application
source, tests, build metadata, and delivery files into `Companion/`. It records
each copied file's hash and the original revision in `Companion/SOURCE.json`.
Personal notes, downloaded references, recordings, credentials, and verification
artifacts are excluded. Review the complete staged file list before publication.

The local simulator keeps `org.hermescompanion.beta`. The archive lane explicitly
sets `com.maurice.semreh`, team `6D65NQ2V3Q`, and marketing version `1.0`. It queries
Apple for the latest build and allocates the next integer. The workflow shares
Semreh's `internal-testflight` concurrency group so those two upload workflows
cannot allocate a build number at the same time.

## Publish the delivery branch

Review the isolated worktree diff and verify that existing Semreh files are
unchanged. Commit the `Companion/` subtree and new workflow. Push the named branch
to the explicit remote below. Some local Semreh worktrees have a different
`origin`, so do not infer the destination from that alias.

```sh
git push https://github.com/MauriceAK/semreh-ios.git \
	HEAD:refs/heads/companion/chat-beta-testflight
```

The branch push starts **Companion TestFlight**. A new workflow need not be added
to `master` to receive a matching push event. The existing Semreh upload workflow
runs on `master` and is not triggered by this branch push. Keep this delivery
branch separate from Semreh's release branch.

The workflow uses these existing secrets from `internal-testflight`.

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`

The key stays in the runner's temporary directory with mode `0600` and is removed
after the upload step. No credential value belongs in source, logs, or receipts.
The lane finds Semreh's existing populated internal groups. It does not create
testers, invite people, enable a public link, or submit Beta App Review.

## Check the delivery result

Before upload, CI runs host tests, native unit tests, and fixture UI tests. Real
Hermes and physical-device tests remain separate gates. The archive check verifies
the IPA's app identity, version, build, signature, distribution profile, production
APNs entitlement, and compiled icon metadata.

The native command excludes named tests that require a paired host, a seeded
photo library, notification injection, or a real history session. It also excludes
`PerformanceFlowUITests`, whose workloads require a configured real host. Every
ordinary fixture test remains selected, including the composer and attachment
regression tests. Any selected test that skips causes the CI check to fail.
Bundler uses Semreh's root `Gemfile` explicitly while the commands run inside
`Companion/`.

Fastlane waits for Apple processing. A second API read must return the exact build
as `VALID`, usable for internal testing, and assigned to every selected internal
group. Missing artifacts, processing failures, and absent group membership fail
the job. A green job preserves `testflight.json`, the IPA hash, both source
revisions, native test results, and the verified IPA as GitHub artifacts.

If the job fails after upload, inspect App Store Connect for the recorded version
and build before retrying. The previous upload may still be processing. Do not
reset the build number or assume that a timeout means no upload occurred.

Open Semreh in TestFlight on the phone and install that exact build. Confirm the
Companion interface, pair with the host, and verify off-network access and push
delivery separately. A TestFlight upload does not establish those runtime checks
or physical 120 Hz performance.

## Reproduce local delivery checks

```sh
python3 ci/check_delivery.py
ruby ci/test_testflight_contract.rb
python3 -m unittest discover -s ci -p 'test_*.py' -v
ruby -c fastlane/Fastfile
bash -n ci/test_native.sh
plutil -lint ci/CompanionInternalExport.plist
xcrun swift ci/generate_app_icon.swift /tmp/companion-app-icon.png
cmp /tmp/companion-app-icon.png ios/HermesCompanion/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

The dependency lock was copied from the verified Semreh revision above. It pins
Fastlane `2.238.0` and Bundler `2.7.1`. The workflow uses Ruby `3.3.8`, matching the
successful Semreh pipeline. No Semreh preview compilation flag is added.

The processing and group checks use the pinned
[Fastlane upload contract](https://docs.fastlane.tools/actions/upload_to_testflight/)
and its
[build API model](https://github.com/fastlane/fastlane/blob/2.238.0/spaceship/lib/spaceship/connect_api/models/build.rb).
Apple associates an uploaded binary with its app record using the bundle ID and
version metadata. See [Apple's upload guidance](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).
