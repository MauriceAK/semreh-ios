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

### Approved recovery and stock reset proof

Maurice approved restart-persistent unresolved-upload metadata and explicit
per-chat runtime reset preserving saved history. Binding plan records authority.
Root extended the same guarded probe with `--verify-reset`: after hot resume,
close only the probe-owned runtime, reopen the saved chat, compare canonical
history before/after reset, then send ordinary text and require zero orphan images.
`slice3-attachment-reset-contract-v2.json` passed with a new runtime, unchanged
saved history and no cleanup errors. Earlier v1 passed assertions but mislabeled
the created-runtime evidence field; retained, corrected in v2. Neither is native
UI, literal app-kill or deliberately lost-frame evidence.

Root and independent Luna source review confirm the queue is runtime-local:
hot resume reuses the queue; a newly allocated cold runtime starts empty. Marker
lookup therefore uses normalized origin/profile/live runtime ID; durable session
ID is metadata so compression rotation cannot bypass recovery. Persisted runtime
ID alone is not authority to close anything: reset requires a current proven
binding and captured confirmation identity. No backend changes were made.

`slice3-attachment-reset-audit-v1.jsonl`: **151044 files, 0 flags, 85 exported
consoles**. Same known-secret/pattern exclusions as above. Native implementation,
managed-file previews and corresponding new tests are under integration review;
no new native pass or slice acceptance claimed in this entry.

Native integration attempts for the recovery batch (same signed Simulator and
test flags as earlier; filters: DirectGatewayAttachmentRecoveryMarkerTests,
GatewayConversationAttachmentTests, ChatViewModelDirectGatewayTests,
APIClientChatEndpointTests):

- `slice3-attachment-recovery-focused-v1`: build failed before tests. Root reused
  a PBX identifier already assigned to managed-file tests; new marker file was
  resolved in the test directory. Corrected unique IDs; duplicate-object check0.
- `slice3-attachment-recovery-focused-v2`: build failed before tests. SwiftUI
  could not type-check the extended ChatView alert chain within compiler limits.
  Luna extracted the confirmation into a dedicated modifier; rerun pending.
- `slice3-attachment-recovery-python-v1.log`: **29 tests passed** for existing
  smoke/recovery/native-canonical helper suites.

One bounded Sol Low read-only review supplements Luna implementation and root
review for this high-risk recovery logic. It found stuck recovery after a lost
close acknowledgment, unreadable-marker recovery, and missing second-upload
unknown-state coverage. These must be resolved before checkpoint acceptance;
worker syntax checks are not executed XCTest evidence.

- Focusedv3 failed compilation: observed cleanup-task property referenced from
  deinit; root marked it ObservationIgnored like the existing task handles.
- Focusedv4 still failed SwiftUI expression type-checking; Luna split the base
  presentation/sheet chain from alerts without changing behavior.
- Focusedv5 failed compilation: test helper gained a local variable but omitted
  its now-required return; root corrected it.
- Focusedv6 **96 passed, 4 failed, 0 skipped**. Failures exposed reset quarantine
  not set on close dispatch, stale-status-proof error expectations, a fake
  returning the closed runtime after reset, and busy/error guard precedence.
  Production safety correction retains quarantine after uncertain reset; the
  fake now models stock fresh-runtime behavior. Failed artifacts retained.
- Focusedv7 **99 passed, 1 failed, 0 skipped**. Concurrent submit was blocked
  correctly but reported unresolved upload instead of the prior busy outcome.
  Root prioritized the in-flight stage guard without weakening the no-submit
  assertion. Focusedv8 **100 passed, 0 failed, 0 skipped**. V6/v7/v8 console
  exports retained; subsequent full-suite run below.

Recovery fullv1 passed **2144 tests, 0 failed, 7 intentional opt-in skips**.
Signed recovery UIbuildv1 and live production UIv1 passed **1/0/0** through real
HTTPS login, new chat, native image Paste/local preview, staged send, canonical
image cell and authenticated managed-file preview. The normal completed upload
does not leave the reset banner visible. Root viewed the colored image in
`slice3-attachment-recovery-ui-v1-attachments/F1DA6A43-744A-4C99-B709-A0C0E2A452CA.png`
(transcript) and `69ADE1D9-B1A9-410D-9CED-046611F0EEC1.png` (preview).
This is production UI evidence, not a literal app-kill or reset-dialog exercise.
Full-suite/UI diagnostics and UI attachments were exported with OS diagnostic
collection disabled. Post-export audit `slice3-attachment-recovery-audit-v1.jsonl`
passed **156288 files, 0 flags, 90 exported consoles**, with the same known-current
fixture-secret/pattern-only exclusions (not arbitrary secrets/OCR/quarantine).
`slice3-attachment-recovery-canonical-v1.json` independently matched the exact UI
UUID prompt to durable rows240/241:4unique rows,1image reference, authenticated
media and managed-file reads both529bytes. No physical-device claim.

Additional bounded native-controller/live-gateway recovery test is in preparation
to join actual staging, persisted marker recreation, explicit reset, preserved
history, and a subsequent plain-text turn. Reset abandons the queue; stock does
not promise deletion of the physical uploaded file, and no file-deletion claim
or new backend dependency is introduced.

### Native controller recovery against stock gateway

App production checkpoint `62f9d8a`, plus additive opt-in live test/selector only.
No production/backend changes for this test. Signed native buildv1 passed.
`direct_hermes_ios_smoke.py --https --stock-backend --slice3-recovery` selects
`DirectHermesLiveSmokeTests/testOptInHostedSlice3NativeAttachmentRecovery` in
`SemrehSlice1Live.xctestrun`; run using test-without-building on the same owned
Simulator with diagnostics collection disabled.

`slice3-native-recovery-live-v1.xcresult`: **1 passed, 0 failed, 0 skipped**.
The actual pinned HTTPS gateway completed a seed turn; the native controller
staged an image and wrote the disk marker before its disposal. A recreated store
and controller found the marker and rejected plain send/new staging. Explicit
reset preserved the exact baseline messages; another controller resumed and sent
ordinary text. Exact baseline prefix, unique user/assistant counts, and absence
of image/file references or attachments were checked. Only its own final live
runtime was closed with acknowledgment; transcript retained. Diagnostics exported.
This proves native controller/store recreation, not literal app process kill,
dropped frames, reset-dialog interaction or physical-device acceptance.

Selector/recovery/canonical Python helper suites: **31 passed** in
`slice3-native-recovery-python-v1.log`. Final recovery-full-v2 passed **2144 tests,
0 failed, 8 intentional opt-in skips** (new live test separately passed above).
Final audit `slice3-native-recovery-final-audit-v1.jsonl`: **160688 files, 0 flags,
92 exported consoles**, same known-secret/pattern-only exclusions. Signed ordinary
dev app verified and launched in the owned Simulator; no phone install or release.

### September 7 — Blocking models and known-stage removal (in progress)

Base `4d37468` plus dirty bounded production/test/fixture changes. Stock pin
unchanged. Root registered `GatewayBlockingPromptModelTests` in the existing target.
Signed `xcodebuild test` used the same project/scheme/Simulator/DerivedData,
jobs2, parallel testing disabled and `-collect-test-diagnostics never`.
Selected classes: GatewayBlockingPromptModelTests,
GatewayConversationAttachmentTests, ChatViewModelDirectGatewayTests,
GatewayConversationBlockingTests.

- `slice3-blocking-removal-focused-v1.xcresult` and `.log`: failed compilation,
  missing `await` on a new test's actor-isolated gate release. No test pass claim.
- `slice3-blocking-removal-focused-v2.xcresult` and `.log`: **82 passed, 0 failed,
  0 skipped** after correction. Independent review still found confirmed-file
  local-removal and selection-generation races; fixes/tests are pending.
- Root Python unittest discovery: `test_direct_hermes*fixture.py` **15 passed**
  (`slice3-blocking-fixture-python-v1.log`); approval-secret probe tests **4 passed**
  (`slice3-blocking-probe-python-v1.log`). These are not live gateway evidence.
- `slice3-approval-secret-contract-v1.json` and `.log`: failed before exercising
  requests. Overriding bundled-plugin discovery removed stock dashboard auth;
  gateway correctly refused public URL startup. Keep authentication intact and
  deploy only the reviewed synthetic plugin into the disposable home/plugins
  instead. Original fixture config unchanged; personal routes/state untouched.

No native response integration, full-suite checkpoint, production blocking UI,
physical acceptance or final artifact-audit claim for this work yet. Failed
attempts are retained; root continues integration after bounded corrections.

Further removal checkpoint evidence:

- Focused-v3 failed compilation: new VM tests referenced a private backing error
  instead of the existing view-facing error projection. Corrected tests, not API
  visibility. Focused-v4 added recovery-marker/lifecycle classes: **99 passed,
  0 failed, 0 skipped**.
- `slice3-blocking-removal-full-v1.xcresult`: **2160 passed, 0 failed, 8 intentional
  opt-in skips**. Console diagnostics exported. Production diff frozen during run.
- `slice3-removal-live-build-v1.log`: signed build-for-testing passed. Additive
  existing `--slice3-recovery` test now also stages a known image, verifies its
  marker, removes exact acknowledged path, verifies marker gone and byte-equal
  saved history, then sends plain text with no media. `slice3-removal-live-v1.xcresult`:
  **1 passed, 0 failed, 0 skipped** on actual stock HTTPS gateway. Diagnostics
  exported. This is native controller evidence, not physical or removal-button UI.
- `slice3-removal-app-launch-v1.txt`: ordinary signed dev app launched in the owned
  Simulator. No phone install or publication.

Retained fixture iterations (not backend/app failures): gateway-blocking-v2 kept
auth but missing user-plugin enablement; contract-v2 timed out. Gateway-v3 enabled
the plugin, but handlers lacked stock forwarded kwargs; contract-v3 timed out.
Root also found namespaced plugin skills bypass secret capture; fixed bare fixture
skill lookup. Gateway-v4 rejected normal bundled-skill siblings; narrowed checks to
exact fixture subtree. Gateway-v5 rejected stale nested skill digest during root
deployment; synchronized the renamed synthetic skill. Gateway-v6 launched;
contract-v4/v5 timed out because stock tool-search deferral hid plugin schemas.
Provider safe diagnostics proved exact marker plus bridge tools, not actual fixture
schemas. Exact fixture-only `tools.tool_search.enabled=off` chosen for gateway-v7.
All startup logs remain private runtime evidence until audit. No real secret was
submitted; authentication remained enabled and stock source stayed unchanged.

`slice3-approval-secret-contract-v6.json` **passed** on gateway-blocking-v7 with
exact fixture plugin/flat skill, stock auth and tool-search deferral off only in
this disposable runtime. Approval event has request ID/four choices; pending
registry identity matches (no choices there), resume matches with four choices,
deny resolves exactly one, and terminal arrives. Secret event has the expected
synthetic env name; explicit empty response returns ok and terminal arrives.
Two tool executions, zero cleanup errors, fixture config unchanged during probe.
Provider diagnostics confirm only clarify and the two approved synthetic schemas
were advertised for these turns. No live sudo, native prompt UI or phone claim.

Final bounded Python suites: **16+10 passed** in blocking-fixture-python-v3 and
blocking-probe-python-v3 logs. `slice3-blocking-removal-audit-v1.jsonl` passed:
**165626 files, 0 flags, 94 exported consoles**. Same exclusions apply: current
known fixture secrets and obvious bearer patterns only, not arbitrary secrets,
OCR or quarantined OS diagnostics. No publication of private runtime state.

## Native blocking integration — September 7, in progress

Dirty successor to774ca10, same clean stock pin. Controller/VM now connect typed
approval and cancel-only sensitive cards without legacy response endpoints.
Exact identity guards, terminal queue clearing and renderer-scoped errors received
root review plus a bounded Sol Low read-only review. Full integration gate pending.

- `slice3-blocking-integration-focused-v1`: compile failed, two missing returns in
  legacy VM guards; corrected.
- Focused-v2: **103 passed, 3 failed**. Two fakes rejected permitted canonical
  transcript GET; old clarification test relied on removed unsupported-approval
  placeholder. Corrected fixtures without permitting legacy writes.
- Focused-v3: **105 passed, 1 failed**, another instance of the strict GET fake.
- Focused-v4: **106 passed, 0 failed, 0 skipped**. Subsequent expiry correction
  below still requires a new native run.
- `slice3-blocking-ui-build-v1.log`: signed build-for-testing passed.
- `slice3-blocking-production-ui-v1`: **0 passed, 1 failed** waiting for the
  approval container accessibility identifier. Exported screenshot proves the
  card rendered; hierarchy contains exact action identifiers but not its parent
  identifier. Correct test to require the visible heading/action, disappearance,
  and terminal ACK. Root also observed keyboard left open under approval; reuse
  existing clarification keyboard dismissal for the other direct prompt types.
- `slice3-approval-secret-contract-v7.json`: failed newly added stale approval
  assumption4009. Actual pinned methods_prompt/approval implementation and v8
  prove repeated approval response returns **resolved0**, repeated secret cancel
  returns **status expired**. V8 passed, zero cleanup errors/config unchanged.
  Remove invented approval4009 expiry shortcut; unknown errors retain the card.
  Zero resolution remains non-success. Regression added; all failures retained.
- Selector Pythonv2 **14 passed**; approval-secret Pythonv4 **11 passed**.

Reproduce focused gates with signed `xcodebuild test`, scheme HermesMobile,
owned Simulator/DerivedData, jobs2, parallel-testing NO, diagnostics never;
select GatewayBlockingPromptModelTests, GatewayConversationBlockingTests,
ChatViewModelDirectGatewayTests and GatewayConversationControllerTests.
Production UI uses signed HermesMobileUIVerification build-for-testing, then
`direct_hermes_ios_smoke.py --https --stock-backend --slice2-ui --slice3-blocking`
and generated SemrehSlice2LiveUI.xctestrun with test-without-building. Use fresh
evidence paths. No native sudo, physical-device or slice-completion claim.

Focused-v5 compiled, then failed before the test runner established connection
(369seconds, zero tests executed). Retained result/diagnostics. Unchanged-build
test-without-building focused-v6 passed **107 tests, 0 failures, 0 skips**,
including unknown approval4009 rejection. Retry does not establish the first
runner failure's cause. UI buildv2/rerun pending. Interim audit of UIv1 output:
166612files, zero flagged paths,95exported consoles, same exclusions as above.

Signed UI buildv2 passed; production UIv2 passed its approval denial/ACK steps,
then failed waiting for the sensitive parent AX identifier (0whole-tests passed,
1failed). Root screenshot shows the secret cancellation card with no keyboard;
test now anchors visible heading, explanatory text and exact cancel button,
requires zero app-wide regular/secure text fields, disappearance and terminalACK.
No product response pass inferred for secret cancellation yet. V3 rerun pending.

Signed UI buildv3 passed; production UIv3 passed **1 test, 0 failures, 0 skips**.
Actual login/new-chat/approval-deny/secret-empty-cancel all reach unique terminal
ACKs; no bulk action or secret input fields. Root inspected approval card
205F0ECB-0D02-496A-9CAA-D5384C0335F3.png and final secret ACK
187F1590-F929-430D-A51B-D86E831C849F.png in its exported attachments. Keyboard is
dismissed; final cards clear. This is stock HTTPS Simulator evidence, not phone
acceptance, credential entry, live sudo or multi-client blocking handoff.

Recovery cleanup review found stale A failure could quarantine rebound B. Scoped
task-owner UUID/finalizer and adoption retirement now reload B's own marker;
explicit reset retains independent ownership. No automatic cleanup retry added.
Bounded SolLow review found no remaining concrete production blocker. Native
blocking-recovery-focused-v1 passed136/failed2 new regression fixtures: initial
resume erroneously started on B, so A cleanup never began. Corrected initial A
binding, before/after B marker checks and gated request completion; v2 pending.

Blocking-recovery-focused-v2 compiled but runner hung before establishing its
connection: zero tests executed. Unchanged-build v3 passed **138 tests, 0 failures,
0 skips**. Failed attempt retained with exported diagnostics. Final full suite
still pending; completed-away runtime/controller recreation smoke now executing.

### Blocking/recovery checkpoint gates

- `slice3-completed-away-live-v1.xcresult`: **1 passed, 0 failed, 0 skipped**.
  Native controller accepted a delayed stock-fixture turn, was disposed without
  session.close, and its runtime/socket stopped. Canonical polling observed durable
  completion before the replacement runtime connected. Reopened same storedID is
  idle, exact baseline prefix retained, user/assistant suffix appears exactly once,
  and loaded/canonical transcripts match. Only owned live runtime closed; logout
  cleanup passed. Not literal app kill, host restart, or physical background.
- `slice3-blocking-recovery-full-v1.xcresult`: **2172 passed, 0 failed, 9 intentional
  opt-in skips**. Generated original HermesMobile xctestrun has no test filter;
  full test-without-building run uses the focused-v2/v3 signed build. New live
  completed-away opt-in test ran separately above, not silently claimed by its skip.
- `slice3-blocking-recovery-app-launch-v1.txt`: ordinary development app launched
  on owned Simulator; codesign strict verification passed. No phone install.
- Selector tests including completed-away phase: **16 passed**, evidence
  `slice3-completed-away-selector-python-v1.log`.

Completed-away selector: `direct_hermes_ios_smoke.py --https --stock-backend
--slice3-completed-away`; generated SemrehSlice1Live.xctestrun, same owned
Simulator/diagnostics-never, test-without-building. No backend source changes.
All test diagnostics exported before final artifact audit. Failed runner attempts
remain: app launched but XCTest test bundle did not establish its connection;
root cause unknown. If repeated, explicitly terminate only the owned dev app
before an unchanged-build retry; a cold owned-Simulator restart is a bounded
fallback. This is a suggested launch preflight, not a demonstrated fix.

Final `slice3-blocking-recovery-audit-v1.jsonl` completed: **172401 files scanned,
0 flagged paths,103 exported consoles**. Known current fixture secrets/obvious
bearer formats only; no arbitrary-secret, OCR or quarantined diagnostic guarantee.

## Lifecycle successor to ff5abfd — verified checkpoint

Minimal uncertainty-banner fix retains explanation across benign terminal and
same-controller resume; no Retry, resend or acceptance heuristic. Stock submit/
inflight/events expose no durable client-request correlation. Matching text/new
rowIDs alone cannot prove which concurrent client submitted a turn. R1 remains
open; the in-memory barrier is not durable across controller recreation.

- lifecycle-banner-focused-v1 compiled **88pass/1fail**: new regression wrongly
  required unconfirmed optimistic row to survive authoritative empty history.
  Corrected to canonical removal plus retained uncertainty message/no newsubmit;
  strengthened terminal synchronization. No ghost-row behavior added.
- lifecycle-banner-focused-v2: **89pass/0fail/0skip**. Explicit owned-app terminate
  preflight preceded these unit runs; no runnerhang in either. Not proof of a fix.
- lifecycle-selector-python-v1: **23pass** (relaunch/restart guards and helper).
- relaunch-seed-v1 JSONRPC-created stock seed: passed, exact two canonical rows
  and baselinehash retained. No literalTUI or apprelaunch claim from this helper.
- gateway-restart-live-v1: **1pass/0fail/0skip**. Native test retained its login,
  controller and cookiejar while root stopped verified ownedPID63934, observed
  exit/listenerabsence, relaunched sameguardedheadlessfixture asPID20145, verified
  HTTP200 and unchanged configSHA. New runtime binding, exact native+REST baseline,
  unique new postrestart turn/no duplicate and ownedcleanup/logout passed.
  Root coordination attestation: slice3-gateway-restart-root-v1.json. No personal
  route/service changed. Not hostOSreboot, servicemanager recovery or in-flight
  run continuation. Only idle processrestart is proved.

Host restart uses standalone selector --slice3-gateway-restart plus a fresh safe
--gateway-restart-nonce. Native writes exact private nonce-bound ready marker;
root verifiesPID/paths, SIGTERMs onlyownedgateway, launches with both
--with-pdf-renderer --approval-secret-fixture, verifiesstatus/config, writes
restart-complete ACK viaapply_patch. No credentials or sessionIDs in handshake.
Full successor suite and actual apprelaunch results follow.

Lifecycle fullv1 passed **2173 tests,0failures,10intentional opt-in skips**.
Signed relaunch-ui-build-v1 passed. Relaunch-production-ui-v1 passed **1/0/0**:
actual XCUIApplication terminate/launch, existing auth retained, same seeded stored
session opened through production deep link, then one unique new message/ACK.
Relaunch-canonical-v1 passed exact four rows and unchanged two-row baselinehash;
this is not merely cached UI evidence. Root inspected exported
8CC0C66A-A34E-44C1-AE5D-ACAF332771F3.png (reopened seed) and
1904B09F-5C9F-4B36-883A-32E90FFB5EA8.png (newturn). This gate killed an idle app,
not an accepted in-flight run. Physical/background/orphan-policy gates remain.
Strict codesign and lifecycle-app-launch-v1 passed on the owned Simulator.

Root located the isolated Simulator's built-in FileProvider.LocalStorage group
via container metadata and seeded only its new SemrehSyntheticFixtures folder
with semreh-picker.txt and a461-byte one-page blank PDF (pdfinfo validated).
No app entitlement, newprovider, iCloud, personalfile or productioncode change.
This is preparation, not proof that the system picker exposes/selects the files.

Lifecycle artifact audit v1 completed: **177368 files scanned, 0 flagged paths,
107 exported consoles**. Scope remains known current fixture secrets and obvious
bearer formats, excluding arbitrary-secret/OCR and quarantined OS diagnostics.

## Files picker / active socket-loss successor to e1d0099 — in progress

Direct composer now saves its cleared draft before awaiting submission. Existing
definite-failure restoration/newer-draft preservation remains. Store-only tests
cover clearing A without touching B and restoring A; they do not prove UI call
ordering, crash durability or durable ambiguous-delivery resolution.

Root review corrected picker test timing/identity: baseline attachment labels
captured before selection, exact removal-chip disappearance, one new returned
cell and PDF local document versus returned page image. Native active socket
test is separately authored; controlled URLSession socket cancellation is not
WiFi or proxy-outage evidence. No production backend change.

Picker-ui-build-v1 failed compilation because root used a nonexistent attachment
helper name; corrected to existing attachPlainText. Picker-ui-build-v2 signed
build passed. Picker-production-ui-v1 running; no picker gate claimed yet.
Selector Python suite with active-socket standalone guards passed27 tests.

Picker UIv1 failed on MenuItem selector despite visible Attach File; corrected
to stock SwiftUI button, signed buildv3 passed. UIv2 reached the synthetic Files
folder but failed on literal filename selector: Files hides extensions and exposes
cell identifier `semreh-picker, txt` / `semreh-picker, pdf`. Root inspected live
screenshot and exported AX hierarchy A7467A99-5574-4BFE-A0ED-838E6BC4A6F9.txt;
corrected exact cell identifier, buildv4 pending. Both failures retained/exported,
no product picker failure proved and no pass claimed.

Bounded SolLow review of active-socket test caught misplaced binding counter in
the previous test and potential cancellation of a stale first socket. Root moved
the counter into the correct method, reverted unintended previous-test edits and
requires unchanged connection generation/exactly one socket/still-running before
cancelling. Native execution pending. This remains controlled socket cancellation,
not a separate proxy/WiFi loss gate.

Picker buildv4 passed; UIv3 passed actual text selection/send/canonical text
preview, then failed local-PDF accessibility assertion after selection. Root saw
authenticated text content in screenshot and preserved AX/video. No PDF pass:
added explicit systempicker-dismissal wait and diagnostic snapshot on localPDF
failure to distinguish presentation timing from missing accessibility metadata.
Buildv5/rerun pending. Not a reason to weaken the PDF gate.

Buildv5 passed. UIv4 confirmed the actual product gap, not just test AX timing:
localPDF sheet displays `This attachment does not have a server file path.`
Root inspected screenshot61CA03EC-7414-4398-8658-50F76B2C3E4A.png and
AX00CA4FCB-322A-46A3-8874-17C34C39E92B.txt. ComposerAttachmentDisplayItem
intentionally projected original bytes only for images; no-path preview loader
handled only images. Luna now extends only local PDF preview with retained bytes,
existing PDF loader/size limits/cancellation guards, no backend or persistence.
Both text roundtrip and failure evidence retained; full picker gate remains open.

Local PDF projection/preview implementation and tests now integrated. Root full
signed `slice3-picker-socket-full-v1.xcresult`: **2179 passed, 0 failures,
11 intentional opt-in skips**. Includes valid/malformed/declared-oversize/cancelled
local PDF without network, preserved image behavior and direct draft clearing.
New active-socket live smoke typechecked; standalone live execution still required.

`slice3-active-socket-loss-live-v1.xcresult`: **1 passed,0 failures,0 skips**.
Native test observes canonical accepted user/no new assistant and running state,
requires sole original socket/unchanged generation, cancels real URLSession socket,
then requires a new socket/generation/binding on the same controller/stored ID.
Scoped terminal, unchanged exact baseline, one new user/ACK pair, native refreshed
history equal to canonical REST and exactly two prompt-submit attempts (seed plus
delayed turn) passed. Exact owned close/logout cleanup passed. No automatic retry
or backend change; not WiFi, proxy loss, app termination or all recovery-matrix cases.

Picker buildv6 passed. UIv5 passed local PDF preview and sent its page, then failed
global accessibility ACK count (2 versus3): older rows were outside the visible
transcript. Root saw latest PDF marker/page and ACK onscreen. Separate guarded
`slice3-file-picker-canonical-v5.json` **passed**: exact text/PDF UUID markers in
one six-row conversation, exact ordered user/ACK pairs, unique durable IDs,
92 original text bytes and one authenticated PNG page. This does not erase UIv5
failure or prove its final returned-image preview step, which never ran.

UI-only correction now awaits the visible ACK below the exact new prompt instead
of counting offscreen old rows; returned attachment discovery uses unseen labels,
not increasing total visible-cell count. The separate canonical check still owns
exact durable counts. Full product suite above remains current; UI rerun pending.

Signed picker buildv7 completed. `slice3-file-picker-production-ui-v6.xcresult`
passed **1/0/0** through production login, actual Files text/PDF selection, local
PDF preview, both sends, and authenticated returned text/page-image previews.
Root inspected exported 3B8F526D-D569-4086-81F9-0C310F6ED892.png (text) and
8D9437DE-0F07-401D-9D66-EF0053923A03.png (PDF page). Diagnostics exported without
OS collection. `slice3-file-picker-canonical-v6.json` passed the separate exact
ordered six-row/unique-ID/text-byte/page-image check. Physical acceptance remains.

Important newly observed gap: running-v6 screenshot shows a stock context warning
for the staged text reference outside its allowed workspace. Storage/readback/UI
preview passes do NOT prove file contents reach inference. Investigation remains
open; no broadened workspace permissions or backend patch is authorized/implied.

Bounded independent SolLow review found no blocking issue in the production
draft-save/PDF diffs. Existing detached PDFKit decode may continue after dismissal;
cancellation prevents publication, not preempting synchronous parsing. Retain the
existing 20MiB cap/off-main loader rather than adding a cancellation framework.
Mid-decode cancellation and production definite-failure draft restoration remain
coverage gaps; pre-cancel and store-only tests do not establish those claims.

Root final Python rerun with approved disposable venv passed **32 tests** in
slice3-picker-final-python-v1.log. Initial accidental system-Python invocation
failed two imports because that interpreter lacks websockets; no code change.
Strict codesign and ordinary owned-Simulator app launch passed (PID62042).

Final picker/socket artifact auditv1 completed with zero flagged paths. Exact
counts retained in slice3-picker-socket-final-audit-v1.jsonl. Scope is known
fixture secrets/obvious bearer formats and exported consoles, not arbitrary
opaque secrets, image OCR or quarantined OS diagnostics.

Text-file warning diagnosis: Luna read-only audit and root source confirmation
agree. Stock server.py13897-13922/13987-14026 returns profile-home attachment
absolute refs. server.py12880-12898 preprocesses with allowed_root=cwd;
agent/context_references.py471-480 rejects outside paths. Semreh's remote
data_url/name payload and preserved ref_text match the supported contract.
No app-only relative-path rewrite is justified: it would address a different or
missing file. No backend/config change made. Generic-file inference remains an
explicit open gate even though native selection/storage/readback/preview pass.

## Accepted-run app-kill successor — in progress

Luna changed mixed-attachment regression to exact stock absolute profile-home ref
and strict outgoing prompt equality (transport only, not ingestion). Root full
signed absolute-ref-full-v1 passed **2179/0/11 intentional opt-in skips**;
diagnostics exported. No production changes after2dca7e6.
Fresh app-kill-seed-v1 created an exact two-row JSON-RPC baseline, then closed its
owned runtime; no appkill claim. SolLow authors an isolated production UI opt-in
with separate ephemeral REST observer, accepted-before-kill and completed-while-
dead assertions. Root requires old idle-relaunch check retained independently.

App-kill signed UIbuildv1 passed with async-context XCTestwait warning; root used
await fulfillment at the newly async entrypoint, buildv2 passed clean. Root
selectorv1 omitted PYTHONPATH and failed15imports; correct v2 passed29. Luna
restored misplaced completed-away assertions to their correctly named test,
same29 passed. No production code changes.

App-kill productionUIv1 FAILED before submitting the delayed turn. Login reached
Sessions, then production seed deep-link triggered an app launch and the expected
seed did not appear; exported AX shows Connect/session-expired. xcresult reports
both runnerexit75 and seedvisibility timeout, zero passed. No accepted-run or
process-death claim. Root retains all diagnostics/attachments and is making a
same-build retry with the still-guarded two-row seed; underlying cause unresolved.

Same-build app-kill productionUIv2 **passed1/0/0**. The separate authenticated
observer proved exact accepted user/no new assistant before termination, first
post-termination read still incomplete, and exact completion while the app
remained notRunning. Relaunch restored the same conversation, one accepted prompt,
two total ACKs including seed, idle UI and empty composer. Exact canonical prefix
and durable IDs preserved. Root viewed before F5D45D43-2F04-47D7-9F06-36A772453EA5.png
and recovered A77E88DF-9D05-43CE-886B-3949AEB3C56A.png. Diagnostics exported.
Independent app-kill-canonical-v2 passed exact four rows and unchanged baseline
hash. This proves this short accepted-run process-death case, not physical long
background, pre-ACK delivery ambiguity, proxy failure, or general auth reliability.
UIv1 remains a real immediate-launch auth-persistence failure of unresolved cause;
the passing retry does not erase it or justify adding a sleep to hide the boundary.
Strict codesign and ordinary signed Simulator launch passed (PID75143).

Final selectorPythonv3 passed29 after assertion-grouping tidy. App-kill artifact
auditv1 completed with zero flagged paths; exact counts retained in JSONL. Known
fixture secrets/obvious bearer formats/exported consoles only; same exclusions as
previous audits. The successful checkpoint does not close R2c auth follow-up.
