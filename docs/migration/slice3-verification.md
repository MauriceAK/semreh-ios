# Slice 3 verification ledger

Slice status: IN PROGRESS, not accepted. See [task sheet](slice3-tasks.md).

## First bounded implementation checkpoint — September 6, 2026

App baseline `ad3ddbc`, branch `chore/direct-hermes-v3-slice3`, plus the
foreground recovery and stock media adapter diff. Official Hermes pin remains
`29112bef099274229cadff79cdff7bf7b99c4b77`; guarded disposable configuration
validated again, listener `127.0.0.1:18791` still owned by PID42082.

Two Luna High workers implemented disjoint responsibilities. Root inspected
the runtime/store/lifecycle and pinned media source, requested corrections to
cold-start reconnect, invalidation-test synchronization, raw preview limits and
decoding-specific assertions. Worker static checks are not executable evidence.

Changes replace no backend behavior: app-level background→active recovery uses
the existing runtime owner; `/api/media` JSON is decoded at the existing app API
boundary, preserving legacy raw responses. No new dependency or Hermes patch.

### Commands and results

Evidence root: `/Users/maurice/workspace/semreh-slice1-evidence`.

```sh
xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=D852F8F7-6C05-4FAE-8F05-CBCB7C4B3263' \
  -derivedDataPath /Users/maurice/workspace/semreh-slice1-build \
  -parallel-testing-enabled NO -jobs 2 -collect-test-diagnostics never \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120 \
  -only-testing:HermesMobileTests/OpenChatSessionStoreTests \
  -only-testing:HermesMobileTests/APIClientWorkspaceFileTests \
  -only-testing:HermesMobileTests/HermesServerRuntimeTests \
  -only-testing:HermesMobileTests/ChatAttachmentCoordinatorTests \
  -resultBundlePath /Users/maurice/workspace/semreh-slice1-evidence/slice3-first-focused-v1.xcresult \
  -quiet
```

Focused result: **109 passed, 0 failed, 0 skipped**. Signed full suite used
the same command minus the four `-only-testing` filters, result/log stem
`slice3-first-full-v1`: **runner failure before test execution**, exit65,
0 passed/1 runner failure/0 skipped. Xcode reports the runner hung before
establishing its connection after360seconds; cause not established. Failed
bundle and exported diagnostics retained. Unchanged-build retry uses
`test-without-building`, otherwise the same full command, fresh stem
`slice3-first-full-v2`: **2031 passed, 0 failed, 7 intentional opt-in skips**.
This successful retry does not establish the cause of the first runner failure.
Full-v1/v2 consoles exported into matching `-diagnostics` directories.
Focused console exported to
`slice3-first-focused-v1-diagnostics` with OS diagnostics collection disabled.

Live stock media probe: `python scripts/direct_hermes_media_probe.py` using the
disposable venv. **Passed** through the actual dedicated HTTPS proxy: authenticated
PNG JSON decoded to exact fixture bytes, unauthenticated401, outside-root403,
unsupported-extension415. Evidence `slice3-stock-media-v1.json`. Retained synthetic
image path recorded there. Root verified PID42082's Python executable, runtime/tools
cwd and loopback18791 listener before running. No model/tool execution involved.
This proves HTTP contract/proxy behavior, not native rendered media UX.

Independent Luna review of the foreground implementation found no concrete bug;
it explicitly left scene-phase navigation and post-switch event integration
unverified. Actual app foreground navigation and physical acceptance are not
inferred from store-level unit tests. No new build installed on the owner's phone.

Root verified the signed Simulator app with `codesign --verify --deep --strict`
and launched `com.maurice.semreh.dev` on the owned Simulator; launch evidence
`slice3-first-simulator-launch-v1.txt`. This is startup only, not scene-phase
integration proof.

Artifact audit: disposable venv `python scripts/direct_hermes_audit_artifacts.py`,
evidence `slice3-first-artifact-audit-v1.json`: **126458 files, 0 flags,
64 exported console logs**. Main fixture's current known secrets/obvious bearer
patterns only; historical credentials, opaque unknown secrets, media OCR and
private quarantined diagnostics are not covered. No expanded sibling-runtime
audit claimed (main temporary phone password intentionally differs).

### Remaining gates

The foreground trigger is only groundwork, not the complete interruption matrix.
Ambiguous-send recovery, blocked prompts, attachment staging, resource cache/Range
behavior, orphan policy and physical background/kill/relaunch remain open.
Existing Slice2 residual phone checks and accepted performance deferral remain
explicit in their task sheets; this checkpoint does not close them.

## Blocking and attachment contract captures — continuation after 5deb68d

Root reviewed Luna-authored probes and deterministic model fixture changes.
`PYTHONPATH=scripts <disposable-venv-python> -m unittest
scripts/test_direct_hermes_model_fixture.py`: **6 passed**. Exact-marker clarify
tool calls added only to the local synthetic provider; ordinary ACK/reasoning/
compression behavior retained. Root verified PID27017 executable, arguments and
cwd, stopped only that owned provider, and relaunched PID18170 on18792 with an
allowlisted environment. Gateway PID42082/config/pin remained unchanged.

- `direct_hermes_blocking_probe.py --output <evidence>/slice3-blocking-contract-v1.json`:
  **passed** via actual dedicated HTTPS/WS. Single-question answer, empty cancel,
  reconnect pending identity, wrong-ID expired responses and cleanup checked.
  Stock accepted a valid pending request ID with a wrong session ID: app-side
  identity validation is required; no backend owner-validation guarantee claimed.
  Live expiry, approval and sudo/secret remain unverified. Current timeout is
  3600seconds; the probe did not change configuration or wait an hour.
- `direct_hermes_attachment_probe.py --output <evidence>/slice3-attachment-contract-v1.json`:
  **failed probe assertion**, after image/detach checks. Probe wrongly required
  a workspace-relative file reference; pinned source explicitly permits an
  absolute reference for profile-home attachments. Failed evidence retained.
  Before live execution, root also caught an invalid synthetic PNG checksum;
  replaced by generated/decoded valid PNG, not a backend change.
- Same probe, corrected, output `slice3-attachment-contract-v2.json`: **passed
  available cases**: image attach/detach, generic file upload/name/ref metadata,
  image/file canonical REST roundtrip, unsupported-image no-submit, cleanup.
  PDF returned5028; successful PDF render/roundtrip and live page-cap check were
  **not run**, not passed. Source-declared image25MiB/PDF50MiB/25page limits read;
  cap-sized payload allocation intentionally avoided. No dependency installed.

These are protocol/fixture checks, not native UI acceptance. Controller and local
attachment implementation are under review; no new Swift verification claimed yet.

### Native controller/attachment focused attempts

Root used signed Debug `xcodebuild test`, owned Simulator/DerivedData,
`-parallel-testing-enabled NO -jobs 2 -collect-test-diagnostics never`, selecting
GatewayConversationBlockingTests, DirectGatewayAttachmentTests,
GatewayConversationControllerTests and HermesServerRuntimeTests.

- `slice3-blocking-attachment-focused-v1.xcresult`/`.log`: **compile failed**;
  new expiry-event test helper omitted the JSONValue.object wrapper. Root fixed
  that helper; no executed-test claim for this attempt.
- `slice3-blocking-attachment-focused-v2.xcresult`/`.log`: **62 passed, 2 failed,
  0 skipped**. Malformed/batch callback test observed only the first asynchronously
  delivered error. Image preparation accepted malformed short image data because
  creating an ImageIO source alone did not establish a valid image. Corrections
  under review; failures retained, no new implementation acceptance or commit yet.
- `slice3-blocking-attachment-focused-v3.xcresult`/`.log`: **62 passed, 2 failed,
  0 skipped**. The prior two failing cases passed after corrections, but matching
  expiry and existing early-resume event tests observed incomplete asynchronous
  delivery. Workers replaced scheduling assumptions with explicit callback
  expectations across the new blocking tests and that existing resume test.
  Root reviewed those test-only corrections; v4 is the subsequent run.
- `slice3-blocking-attachment-focused-v4.xcresult`/`.log`: **64 passed, 0 failed,
  0 skipped**. Signed focused test gate passes; full suite and native feature UI
  integration remain open. No new commit or phone deployment from this patch.

Main artifact audit `slice3-blocking-attachment-audit-v1.json` passed126830files,
zero flags and66 exported consoles, before v4. Scope remains current known main
test secrets and obvious bearer formats, not arbitrary opaque secrets or OCR.
Root exported v4 console diagnostics; these have not yet been re-audited.
Storage fell to1.6GiB; broader builds paused for precise old-cache cleanup approval.
No files deleted. Active source/backend pin remains unchanged and stock clean.

### Full checkpoint after approved storage cleanup

Maurice approved deleting only the six previously identified old temporary Build/
ModuleCache directories plus obsolete iPhone18,2 iOS26.6(23G71) debugging support.
Root rechecked exact ordinary directories and no active matching xcodebuild;
cleanup completed, free space approximately10GiB. Current26.6.1 support, active
Simulator/DerivedData, source, logs, test results and personal Hermes preserved.

Same signed command as focusedv4, omitting all `-only-testing` selections:
`slice3-blocking-attachment-full-v1.xcresult`/`.log`: **2047 passed, 0 failed,
7 intentional opt-in skips**. No Swift changes since focusedv4. Root reran six
Python model-fixture tests: **6 passed**. `git diff --check` clean.
Fullv1 diagnostics exported for console audit; artifact auditv2 completed with
zero flagged paths under the existing known-secret/bearer scope, including the
new focusedv4/fullv1 exported consoles. No arbitrary opaque-secret/OCR claim.

This is the B2a/A2a foundation checkpoint, not Slice3 completion. Native picker/
send staging and blocking UI are not wired yet. Successful PDF fixture rendering
requires unavailable `pdftoppm`; no install authorized/performed. Physical gates,
orphan policy and remaining blocking interactions stay open.

## B2/B3 and A2 continuation — stock contracts

User approved installing the missing PDF renderer. Root installed Poppler26.08.0
with Homebrew auto-update and automatic cleanup disabled; install log
`slice3-poppler-install-v1.log`. Fixture launcher now has explicit
`serve --with-pdf-renderer`, adding only `/opt/homebrew/opt/poppler/bin` to its
allowlisted PATH; default launch unchanged. Root validated old gateway42082 and
restarted only that disposable gateway as99285. No backend source/config change,
personal Hermes access, personal route change or new model toolset.

- `slice3-attachment-contract-v3.json`/`.log`: **passed**, including real one-page
  PDF rendering, canonical history roundtrip, and page-range cap4019. Image/file
  checks also passed. Generic upload now omits `path` exactly as intended by the
  native adapter. `categorical_errors` contains expected-code constants, not a
  list of errors encountered; PDF was available in this run. Physical attachment
  presentation and model vision quality are not established by this fixture.
- Root reviewed additional exact batch/multiselect markers, fixed unhashable
  multimodal-input handling, and changed the probe to verify empty cancellation
  for both unsupported forms instead of merely ordinary batch answers.
  `slice3-blocking-contract-v2.json`/`.log`: **passed**. Both cancellation forms
  reached a terminal ACK and `session.resume` showed no pending clarification.
  Existing single answer/cancel, reconnect, late duplicate and targeting cases
  retained. Provider restarted only after verifying owned PID18170; existing
  clarify-only toolset remains unchanged. Native UI verification still pending.

Native focused `slice3-clarification-ui-focused-v1.xcresult`/`.log`: **75 passed,
1 test crashed, 0 skipped**. Exported console identifies an XCTest expectation
API violation: a helper retained its already-fulfilled `onEvent` callback, so
a later malformed event fulfilled it again. This is a test-helper defect, not
an unexplained infrastructure failure. Fix required before further integration.
The new direct ViewModel routing/single-flight/replacement/invalidation tests
passed in this run; failure and diagnostic evidence retained.

After restoring the helper's prior callback, focusedv2 passed **76 tests, 0
failures, 0 skips**. A subsequent narrow ViewModel guard prevents an expired
old response from attaching an error to a replacement prompt; full-suite
verification of that final guard remains pending.

Signed UI buildv1 passed. Production-navigation UIv1 failed **0 passed, 1 failed**
at a test helper's marker-hittability check, before the clarification card checks.
Exported accessibility evidence places that marker at y=-117 (offscreen). The
helper now checks exact-label existence; actual response controls still require
hittability, card clearing, and unique follow-up terminal acknowledgements.
Failed evidence is retained in `slice3-clarification-production-ui-v1.xcresult`
and its attachments directory. This failure does not establish a product pass.
Signed UI buildv2 passed. Production UIv2 failed **0 passed, 1 failed** at card
accessibility-container existence. Its exported post-send screenshot proves the
card renders, but the retained composer keyboard clips the question under the
navigation bar on iPhone17e. The next bounded fix dismisses ordinary composer
focus on a new direct request and applies the card identifier after accessibility
containment. UI assertions now also require the exact single question hittable.
No physical-device claim. Current artifact auditv1 passes132093files, zero flagged
paths,71 exported consoles; scope is current known main test secrets and obvious
bearer formats, excluding private/quarantined diagnostics and arbitrary-secret
or image-OCR guarantees. Later v3/full-suite artifacts need a fresh audit.

Independent review also corrected expired-response success feedback and cleared
only clarification-owned stale composer errors on replacement. Two focused VM
regression tests were added. Receipt helper is now registered with the project;
required response fields remain strict while optional name metadata is tolerant.
UI buildv3 failed compilation on a missing pattern-match initializer in that new
helper; root corrected `case .string(let value) = value`. No UI test ran from
buildv3. Buildv4 then failed SwiftUI type-check complexity in the existing large
ChatView body after adding the focus observer. The next fix moves that observer
to the existing small backdrop modifier chain without changing its behavior.
All failed artifacts retained; neither failed build ran UI tests.

### Production clarification checkpoint

Signed UI buildv5 passed. `slice3-clarification-production-ui-v3.xcresult`/`.log`
passed **1 production-navigation test, 0 failures, 0 skips**. It logs in through
the real test HTTPS proxy, creates a chat, verifies single answer and explicit
cancel, batch/multi-select cancel-only UI, card clearing and each unique next-turn
ACK. Root inspected exported single/multi-select screenshots: question and actions
are visible with the ordinary composer keyboard dismissed. This is deterministic
stock-backend Simulator evidence, not physical acceptance or other prompt types.

Root reran Python fixture/CLI tests: **18 passed**. Added CLI opt-in/stock/HTTPS
guards and verified the default plan does not enable clarification tests.

Full nativev1 (`slice3-clarification-foundations-full-v1`) built but the runner
hung before establishing its connection after roughly363seconds: **0 tests
executed**, not a product test failure or pass. Result summary records one runner
failure. Exported diagnostics retained. Fullv2 retries the unchanged native build
via its generated arm64 xctestrun; no Swift changes between attempts.

Fullv2 passed **2067 tests, 0 failures, 7 intentional opt-in skips**. It includes
the registered pending/display/receipt tests and final VM regressions. Root
verified the app signature and launched the ordinary signed development app in
the owned Simulator after testing. The failed pre-connection attempt is retained;
its cause is not explained merely by the retry passing. No new phone install.

Reproduction of the unchanged-build retry:

```sh
xcodebuild test-without-building \
  -xctestrun /Users/maurice/workspace/semreh-slice1-build/Build/Products/HermesMobile_HermesMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=D852F8F7-6C05-4FAE-8F05-CBCB7C4B3263' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120 \
  -resultBundlePath /Users/maurice/workspace/semreh-slice1-evidence/slice3-clarification-foundations-full-v2.xcresult -quiet
```

Use a fresh result path for any rerun. Native attachment picker/send staging,
approval/sudo/secret, recovery matrix and physical acceptance remain unverified.
No private Hermes change or release/push is part of this checkpoint.

Final artifact auditv2 passed **136456 files, 0 flagged paths, 74 exported
consoles**, including production UIv3 and fullv2 output. Scope remains known main
test secrets and obvious bearer formats; private/quarantined diagnostics and
arbitrary opaque-secret/media-OCR guarantees are excluded.
