# Cold Files diagnostic

This workflow compares three fixture-only cases once on separate new iPhone 17 Pro
simulators. It requires Xcode 26.6 build 17F113 and iOS 26.4.1 build 23E254a. A
missing identity fails setup. The workflow runs only on pushes to
`companion/picker-diagnostics-20261021`, without an environment, signing secrets,
archive, TestFlight upload, or release action.

## Cases

| Case | Selection | Required behavior |
| --- | --- | --- |
| A: real app | 112 existing native unit tests, then the three original `ChatPolishUITests` below | Every original assertion, including real Cancel within 10 seconds |
| B: minimal importer | `testMinimalFileImporterCancellation` | Real Cancel, search, and list or empty content within one 10-second readiness budget; cancellation and actionable restored host |
| C: built-in Files | `testBuiltInFilesBrowseAndSearch` | Actionable Browse, real list or empty content, then search resolving to an empty result |

The selected original UI tests are
`testAccessibilityLongDraftAndAttachmentStayInsideKeyboardViewport`,
`testApprovalWithKeyboard`, and `testComposerGeometryAndPickerCancellation`.
`expected-tests.json` contains the exact 115/1/1 selections. Its original IDs come
from the committed delivery selection for source
`646da9a9debddea281248b76a9421682c89997cb`, independently matched against cloud run
39658130842. The runner verifies IDs from the new raw result and records actual
UI start order. The original 112 unit tests must precede those three UI tests in
their original order. A changed prefix sets `baseline_context_matches` to false
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
- Simulator state changes and observational `bootstatus` output. Observation
  starts after the state becomes Booted and never gates test launch. Its recorded
  completion time is the next observation, which can lag while inventories or
  resource samples run.
- A filtered live simulator log stream at debug level from observed Booted until
  test exit or observed device shutdown. Each natural stream exit records its
  observation time, raw exit, and device state. An exit observed while Booted
  makes evidence incomplete even if the device later shuts down. The predicate
  covers Files, DocumentManager, FileProvider, RunningBoard, FrontBoard,
  SpringBoard, launchd, and picker remote views. Early entries before streaming
  starts depend on retained logs when available. After testing, the runner reads
  actual device state. It collects the retained 20-minute log slice and an extra
  screenshot only while Booted. Shutdown makes those supplemental captures
  explicitly unavailable; the runner never reboots for collection. The live
  stream, raw xcresult, and exported session diagnostics remain required.
  Missing log entries do not prove no service failure occurred.
- Host process CPU/memory snapshots without command arguments, memory/load
  counters, and simulator process names/PIDs at a target 10-second interval.
  Commands can delay samples. These are pressure observations, not profiling or
  an FPS/latency benchmark. No sysdiagnose or personal logs are collected.
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

The lifecycle checks use mocked commands and do not launch a simulator:

```sh
python3 -B -m unittest discover -s Companion/diagnostics/picker -p test_run.py -v
```

## Interpretation limits

The simulator devices are fresh, unlike the earlier cloud run's existing device.
A selects the 112-unit and three-UI-test prefix, but it does not run
the remainder of the 145-test suite. Raw UI order must be checked before calling
the preceding context identical. The control project is a separate app with a
different lifecycle and less work before presentation. Logging and sampling add
some load to all cases. B and C do not replace product acceptance.

A-only failure directs investigation toward app context. B failure with healthy
Files directs investigation toward importer/remote-view startup. Files failure
supports investigating shared services. None establishes an OS-only cause.
Three passing cases mean this bounded comparison did not reproduce the failure;
they neither certify the release nor authorize repeating until green.
