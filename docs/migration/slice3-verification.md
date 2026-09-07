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

## Canonical socket-recovery probe (after59ec07d)

Root reviewed/hardened the bounded Luna probe: warm nonempty baseline, stable
complete identity/role/text prefix, unique durable IDs, exact ordered new suffix,
and matching clarify tool-call/result IDs. Twelve pure negative/positive tests
passed; no backend/provider/config expansion was needed.

```sh
PYTHONPATH=scripts /Users/maurice/workspace/semreh-slice1-venv/bin/python \
  -m unittest scripts.test_direct_hermes_recovery_probe
/Users/maurice/workspace/semreh-slice1-venv/bin/python \
  scripts/direct_hermes_recovery_probe.py \
  --output /Users/maurice/workspace/semreh-slice1-evidence/slice3-canonical-recovery-v1.json
```

Livev1 **passed**, cleanup_errors empty:
- Accepted delayed turn: disconnect after explicit streaming ACK/running, fresh
  ticket/resume, normal terminal. Canonical2-to4rows, unchanged baseline identity,
  one new user and one terminal assistant row, no duplicate prompt.
- Clarify wait: disconnect/resume restores exact pending request; empty cancellation
  completes and pending clears. Canonical2-to6rows; new user, clarify call/result
  pair and terminal assistant, matching tool IDs and preserved baseline.

This is raw stock HTTPS/WebSocket evidence. It does not prove native foreground/
background, app kill, host restart, pre-write loss or pre-terminal loss handling,
nor negative acceptance proof or permission to retry an ambiguous prompt. New
artifacts have not yet received the next audit. Probe files not yet committed.

## Attachment staging/local selection focused checkpoint

After59ec07d, controller single-attachment staging and VM local-byte selection
passed `slice3-attachment-stage-focused-v2.xcresult`: **106 passed, 0 failed,
0 skipped**. Root ran signed Debug on the owned iPhone17e Simulator with
`-collect-test-diagnostics never`, single-worker execution and the attachment,
controller, blocking, direct-VM, receipt/display and legacy-coordinator test classes.
The first attempt had105passes/1failure: the test's synthetic turn event omitted
the required connection generation and was correctly dropped. Root supplied the
fake's generation and used a bounded condition deadline; no product assertion was
weakened. Both attempts are retained.

Covered: three exact RPC shapes, partial/unknown outcome classification, stale
generation/turn/disposal, concurrent stage/submit, local selection without RPC,
invalid selection preserving prior bytes, late preparation invalidation, and
send blocked while preparation remains unfinished. These are mocked native tests,
not picker/send production integration. The PDF-only135second timeout correction
and subsequent UI/send edits are newer than this focused result and require rerun.

## Native attachment send integration (pre late-ACK correction)

`slice3-attachment-send-focused-v1.xcresult` passed135/0fail/0skip. Includes
sequential VM staging, controller turn-scoped submit guards, exact generic-file
references, PDF135second timeout, partial failures, unknown-stage no-retry,
selection invalidation, cancellation after dispatch and direct memory preview.
Python smoke-driver/recovery checks passed22tests. These results predate the
subsequent sticky late-ACK ambiguity fix; that requires a fresh native run.

Signed UI buildv1 passed. `slice3-attachment-production-ui-v1.xcresult` failed
one test assertion after actual paste/preview/send: the exact-text selector did
not allow stock's appended `@image:` canonical reference. Root inspected AX and
found the new user marker plus new ACK, corrected the selector to the exact
per-run marker or marker-plus-newline prefix, and retained the failed attempt.
Signed UI buildv2 and `slice3-attachment-production-ui-v2.xcresult` passed1/0/0.
Actual production HTTPS login/new-chat, native clipboard Paste, visible chip,
memory image preview, dismissal, send, chip clearing, second ACK and idle checked.
This is paste entrypoint evidence, not Photos/Files/PDF picker or device evidence.

Root viewed final screenshot
`slice3-attachment-production-ui-v2-attachments/D28C9A6B-0A2F-43E6-82BC-6802A439BC51.png`.
It also demonstrates a remaining product gap: transcript displays raw `@image:`
reference, not an image bubble. No rendered transcript-media claim is made.
The exported chat-detail identifier contains the TITLE, not the durable ID.

Root's bounded read-only `scripts/direct_hermes_native_attachment_check.py`
matched the exact UUID-tagged UI turn in stock REST. Evidence
`slice3-native-attachment-canonical-v1.json`: canonical session
`20260906_192050_62a0c9`, four rows with unique durable IDs, final user216 and
assistant217, exactly one owned image reference and terminal fixture ACK.
No duplicate marker in the bounded20-session discovery. This supplements native
UI evidence without inferring durable persistence from a screenshot.

Independent Luna review identified two open issues: known-stage removal silently
no-ops, and terminal-before-late-submit-error can restore a potentially delivered
draft. The latter is being corrected; neither attachment/recovery gate is closed.
New UIv1/v2 exports still need the next artifact audit. Full-suite checkpoint and
physical acceptance remain pending for this uncommitted batch.

## Attachment media integration review and current verification

`slice3-attachment-media-full-v1` failed compilation at a missing `try` in a new
test initializer; corrected. Fullv2 executed **2107 pass, 1 fail, 7 intentional
skips**. Its sole failure was the projection test expectation omitting the closing
four-backtick fence that the implementation correctly preserved. Root corrected
that expectation; `slice3-attachment-projection-focused-v1` passed **9/0/0**.
Both failed attempts remain available. Neither is described as a full-suite pass.

Root review required canonical `ChatMessage.content` to retain raw references;
cleanup now belongs only to the memoized transcript display field and respects
the existing attachment-path visibility setting. Luna also added a bounded stock
`/api/files/read` primitive, not yet generic-file UI acceptance. Independent review
of prompt-submit errors excluded storage failures5070/5071/5072: they occur after
inflight state mutation and are not proof that no submission was accepted.
Unknown/internal/wrong-method errors keep the sticky no-resend barrier.

`slice3-native-attachment-media-contract-v1.json` passed read-only authentication
and matching decoded image bytes through both `/api/media` and `/api/files/read`,
using the exact earlier synthetic native turn and its owned image path. Managed
metadata matched the path and68-byte payload. No named-profile or generic/PDF
preview claim follows from that image-only capture. Python native-check tests:
**7 pass**, including malformed metadata rejection and no extra local writes.

`slice3-attachment-media-audit-v1.json` reports141931 files, no flagged paths;
includes exported fullv2/focused-projection consoles. Scope remains known current
fixture secrets and obvious bearer patterns, not arbitrary secrets/OCR/private
quarantined diagnostics. New fullv3/native UI artifacts require a subsequent audit.

Fullv3 failed compilation at a helper accepting `HermesGatewayError` from an
untyped catch; root corrected conditional casting. Fullv4 executed **2113 pass,
5 fail, 7 skips**. Three failures exposed a product JSON mapping bug in the new
managed-file DTO (`data_url` becomes `dataUrl` under the shared decoder); fixed
without altering wire fixtures. Two old cleanup tests invented RPC404; the pinned
`_sess_nowait` returns4001, while the separate REST404 assertion remains unchanged.
Root corrected those mocks. `slice3-attachment-media-corrections-focused-v1`
passed **54/0/0**, including the affected suites and prompt ambiguity safety tests.
Python smoke/recovery/native-check suite totals **29 pass**.

Independent Luna review also identified full-resolution local image preview
decoding and named-profile `/api/media` limitations. Bounded local downsampling
is the next correction; explicit stock managed-file preview wiring remains next
batch. Final signed native image rendering/remote-preview, full-suite and physical
gates remain open. Known-stage removal and positive canonical ambiguity
reconciliation are still follow-on work, not waived requirements.

## Verified native attachment checkpoint

- Full `slice3-attachment-media-full-v5.xcresult`: **2119 pass, 0 fail,
  7 intentional opt-in skips**. Includes large local image downsampling and
  preservation of original send bytes. Root constrained its synthetic renderer
  to scale1 to avoid needlessly allocating a9000px image in tests.
- Signed production UI buildv3 passed. UIv3 failed because a broad attachment
  query switched from the cleared composer chip to the newly rendered canonical
  cell. Exported AX proves that distinction. Root changed the removal assertion
  to the exact original composer filename, not a global absence of attachments.
- Signed UI buildv4 and `slice3-attachment-production-ui-v4.xcresult`:
  **1 pass, 0 fail, 0 skip**. Actual HTTPS login/new chat, native image Paste,
  local preview, send, composer clearing, unique new ACK, canonical image cell,
  authenticated remote image preview and dismissal passed.
- Root viewed the colored synthetic tile in both canonical transcript and remote
  preview screenshots, respectively
  `slice3-attachment-production-ui-v4-attachments/E4639166-4569-463F-B912-9D2B1986218E.png`
  and `81F5AA8A-CF6C-49FD-9577-C601A20D1DD8.png` in that same directory. Raw
  attachment references no longer occupy the user bubble; canonical text remains
  intact for matching/editing/cache.
- `slice3-native-attachment-canonical-v2.json` passed the exact native UUID turn,
  ordered unique durable rows, single image reference, and matching authenticated
  media/managed-file bytes. No phone or named-profile media claim.
- Artifact audit `slice3-attachment-media-audit-v2.json`: **151039 files,
  0 flagged paths, 85 exported consoles**. Includes current full-suite and UI
  attempts. Same known-secret/pattern-only exclusions as above. Signed app
  verification passed and the ordinary dev app was launched in the owned Simulator.

### Restart safety issue requiring owner alignment

Independent source review found that stock live `session.resume` retains
`attached_images` but does not expose that queue in its payload. The app's
memory-only staged receipts disappear on eviction/kill; an unknown queued image
can then be consumed by the next ordinary text prompt. Source: pinned
`methods_prompt.py:1135-1193`, `server.py:13851-13869`, live resume payload
`server.py:10972-11044`, queue consumption`server.py:12753-12755`; app invalidation
and persisted-controller disposal currently discard only local state.

Known receipts allow exact-path `image.detach`. Unknown receipts require a
restart-persistent per-session safety marker plus an explicit resolution policy,
or another owner-approved lifecycle change. No queue-list RPC exists, and a
guessed path/automatic retry is not acceptable. This remains an attachment gate
blocker; the checkpoint above is not Slice3 completion or release approval.

Root reproduced the server half with
`python scripts/direct_hermes_orphan_attachment_probe.py --output <evidence>/slice3-orphan-attachment-v1.json`.
Result: the dedicated stock runtime survived socket replacement, omitted queue
state from resume, and included exactly one orphan image in the next plain-text
turn. Cleanup confirmed closing only the probe-created runtime; zero cleanup
errors. This deliberately forgets a successfully received stage receipt to model
client state loss; it is not a literal dropped-frame or native app-kill test.
It confirms the queue behavior underlying the client recovery-policy decision.
Post-probe artifact audit`slice3-orphan-attachment-audit-v1.json` passed:
151041files,0flags,85exportedconsoles, same known-secret/pattern-only exclusions.
