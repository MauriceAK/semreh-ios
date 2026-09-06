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
