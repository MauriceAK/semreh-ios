# Cold Files diagnostic

This workflow compares three fixture-only cases once on separate new iPhone 17 Pro
simulators. It requires Xcode 26.6 build 17F113 and iOS 26.4.1 build 23E254a. A
missing identity fails setup. The workflow runs only on pushes to
`companion/picker-diagnostics-20261021`, without an environment, signing secrets,
archive, TestFlight upload, or release action.

## Cases

| Case | Selection | Required behavior |
| --- | --- | --- |
| A: real app | 180 current native unit tests, then the three original `ChatPolishUITests` below | Every original assertion, including real Cancel within 10 seconds |
| B: minimal importer | `testMinimalFileImporterCancellation` | Real Cancel, search, and list or empty content within one 10-second readiness budget; cancellation and actionable restored host |
| C: built-in Files | `testBuiltInFilesBrowseAndSearch` | Actionable Browse, real list or empty content, then search resolving to an empty result |

The selected original UI tests are
`testAccessibilityLongDraftAndAttachmentStayInsideKeyboardViewport`,
`testApprovalWithKeyboard`, and `testComposerGeometryAndPickerCancellation`.
`expected-tests.json` contains the exact 183/1/1 selections. Its A IDs come
from the current delivery selection for source
`e5e760bda47d1c0074e6d7c6e2ee10434e7d7a45`, independently matched against the first
183 test starts in cloud run 39732992774. The runner verifies IDs from the new raw result and records actual
UI start order. All 183 test starts must match the frozen observed order exactly. A changed prefix sets `baseline_context_matches` to false
and makes comparison evidence incomplete, without rewriting the test result.

B uses the production SwiftUI overload exactly:

```swift
.fileImporter(isPresented: $pickerPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { _ in }
```

The host contains one button, a state label, and this importer. It has no app
store, network, voice, menu, or keyboard path. Cancel recovery observes the
presentation binding and actionable host, because cancellation need not invoke
`onCompletion`. Files itself has no picker Cancel criterion. Its bundle ID comes
from the selected runtime's actual application Info.plist and must also appear
in that simulator's installed application inventory.

## Execution and evidence

The checked-in Xcode project is generated with existing XcodeGen tooling:

```sh
cd Companion/diagnostics/picker
xcodegen generate --spec project.yml
```

The cloud command, from repository root, is:

```sh
python3 Companion/diagnostics/picker/run.py
```

The runner rejects non-GitHub-hosted environments. It does not collect local
personal system logs. Each case creates a shutdown device and lets `xcodebuild
test` boot it automatically. No Files prewarm, boot readiness gate, retry,
assertion relaxation, or production change is applied. Cases run sequentially.
Each test command has a 15-minute process limit; this does not alter XCTest's
10-second picker criterion. The job allows 90 minutes to preserve bounded
collection and artifact upload even if all test processes time out.
A failed case stays failed while later cases collect their comparisons. Each
owned simulator must be confirmed Shutdown after collection. If Xcode has already
shut it down, cleanup records that state without another shutdown command.
Otherwise cleanup preserves the shutdown exit and checks the actual state again.
An observed shutdown in progress gets a bounded 60-second poll. If an
observer cannot stop, the runner stops the comparison rather than overlap cases.

`$RUNNER_TEMP/PickerDiagnosticEvidence` contains the following evidence:

- Runner, source revision, Xcode, runtime, device type, and source/product hashes.
  The existing production delivery manifest is checked before any case runs.
- Per-case commands, start/end timestamps, raw exits, raw `Tests.xcresult`, test
  summaries, exact ID readback, actual test device IDs, and attachment/diagnostic
  exports. The original app's XCTest failure attachments remain unchanged.
- Simulator state changes and observational `bootstatus` output. Bootstatus
  starts after observed Booted, without `-b`, and never gates test launch.
  Inventory, app discovery, and resource commands have separate timestamped
  receipts. Failed inventory samples record Unknown. A command failure or
  malformed inventory does not stop continuous logging. Sampling can delay the
  observed boot completion timestamp.
- Separate host and known-device simulator log streams start independently of
  inventory polling. The host predicate covers CoreSimulator and accessibility.
  The simulator predicate covers Files, DocumentManager, FileProvider,
  RunningBoard, FrontBoard, SpringBoard, launchd, remote views, and accessibility.
  These collectors only observe. They do not boot the device or launch Files.
  A failed stream setup is retained and retried after ten seconds while the
  original test command continues. Test commands and assertions are never retried.
  `stream-segments.json` retains every start, exit, gap, and cleanup result.
  Stream output and stderr remain separate. Each receipt has UTC and monotonic
  timestamps. Cleanup signals the owned process group even when its leader has
  exited. It waits two seconds after SIGTERM, then sends SIGKILL and verifies the
  group is gone within another two seconds. A surviving group or failed leader
  reap stays a cleanup failure. Sampler cleanup failures make evidence incomplete,
  even if tests and continuous logs otherwise pass.
- `stream-coverage.json` evaluates the target test from recording start through
  its final attachment. Both host and simulator need one uninterrupted segment
  with parseable events spanning that interval. Simulator events must identify
  a Files, DocumentManager, or FileProvider process during the interval, or
  correlate a remote PID from the target accessibility tree. If a remote PID is
  available, the report requires a matching process ID or an explicit PID in a
  lifecycle message. It preserves the process identities and correlation type
  for inspection. Nonempty unrelated logs, missing recording timestamps,
  missing target events, and a collector gap remain incomplete. A later Shutdown
  does not repair an earlier gap. This is coverage evidence, not proof of cause
  or proof that the system recorded every event.
- After testing, the runner reads actual device state. It collects retained
  logs for the last 20 minutes and an extra screenshot only while Booted. Shutdown
  makes these supplemental captures explicitly unavailable. The runner never
  reboots for collection. The live streams, raw xcresult, and exported session
  diagnostics remain required. Missing log entries do not prove no service
  failure occurred.
- Host process CPU and memory snapshots without command arguments, memory and
  load counters, and simulator process names and PIDs at a target ten-second
  interval. Each sample is bounded and retained separately. Commands can delay
  samples. These are pressure observations, not profiling or an FPS benchmark.
  No sysdiagnose or personal logs are collected.
- The latest exported PNG from the target test, verified against attachment
  metadata, device identity, and PNG signature. `final-screen-attachment.json`
  records its original name, timestamp, and exported filename. This is the final
  available test screenshot, which may precede test termination.
- Control-test accessibility hierarchies and screenshots,
  readiness milestones, and per-case `verdict.json`. `tests_passed` and
  `evidence_complete` are separate; both are needed for a successful job.

Artifacts contain private fixture diagnostic data and have seven-day retention.
No artifact is a public-sharing approval. Inspect raw evidence before publishing
an excerpt. Raw XCTest diagnostics can contain runner paths and metadata.

The offline checks execute the real observation loops with injected inventory,
stream, discovery, and resource failures. Owned-process cancellation tests use
short Python child processes, including an exited leader with a descendant that
ignores SIGTERM. Exact-prefix checks reject swapped starts even when every test
ID is present. Coverage cases include unrelated and malformed
logs, missing timestamps, a missing remote PID, and stream gaps. The checks do
not launch a simulator or collect local system logs:

```sh
python3 -B -m unittest discover -s Companion/diagnostics/picker -p test_run.py -v
```

## Interpretation limits

The simulator devices are fresh, unlike the earlier cloud run's existing device.
A selects the 180-unit and three-UI-test prefix, but it does not run
the remainder of the 214-test suite. Raw UI order must be checked before calling
the preceding context identical. The control project is a separate app with a
different lifecycle and less work before presentation. Logging and sampling add
some load to all cases. B and C do not replace product acceptance.

A-only failure directs investigation toward app context. B failure with healthy
Files directs investigation toward importer/remote-view startup. Files failure
supports investigating shared services. None establishes an OS-only cause.
Three passing cases mean this bounded comparison did not reproduce the failure;
they neither certify the release nor authorize repeating until green.
