# B01: Remote browser workspace (issue #44)

Owner: Muse Spark 1.3 via the Astra runtime (provider `astra-runtime`). Status: implementation complete, PR CI pending, awaiting verifier.

## Outcome

A remote browser workspace for Hermes: the user watches a live remote surface, takes explicit exclusive control, drives it with direct/trackpad gestures and committed-text entry, and hands control back to Hermes with an explicit resume. The default configuration honestly reports the browser as unavailable — no simulated session may ever present itself as a live Hermes connection.

Own this bounded engineering task through implementation, green CI, `needs-verify`, and all returned verifier repairs until accepted. Never merge or self-approve.

## Exclusive write scope

```text
Packages/SemrehRemoteBrowser/**
BrowserLab/**
.github/workflows/remote-browser-lab.yml
docs/agents/assignments/remote-browser-workspace.md
```

Existing app sources, tests, `HermesMobile.xcodeproj`, and `.github/workflows/pr-ci.yml` are read-only. No third-party dependencies, no production entry point, no backend/API invention, no live-Hermes claims, no personal-service access, no Tailscale changes.

## What was built

**`Packages/SemrehRemoteBrowser`** (SwiftPM, iOS 17+/macOS 13+):

- `SemrehRemoteBrowserCore` — ownership state machine (`BrowserSessionController`), adapter contract (`BrowserAdapter`), viewport geometry, bounded frame pipeline, committed-text draft lifecycle. Unit-tested: `OwnershipStateTests`, `ViewportGeometryTests`, `FramePipelineTests`, `TextDraftTests`.
- `SemrehRemoteBrowserUI` — native SwiftUI chrome (`RemoteBrowserWorkspaceView`) around a UIKit gesture viewport (`RemoteViewportView`), bridged by `RemoteBrowserViewModel`. Required states/copy, accessibility identifiers (`browser.close`, `browser.takeControl`, `browser.resume`, `browser.status`, `browser.keyboard`, `browser.insertText`, `browser.mode`, `browser.fit`, `browser.viewport`), watch/direct/trackpad gesture separation, keyboard draft with Insert and special keys, safe-area/material/Dynamic Type behavior. The default adapter reports unavailable; fixtures inject only from BrowserLab/tests.

**`BrowserLab/`** — standalone fixture app (never shipped):

- Bundle ID `com.mauricekenon.semreh.browserlab` (unique; the shipping app is `com.mauricekenon.semreh`). Always shows the persistent simulated-session banner.
- `SimulatedBrowserAdapter`: synthetic changing frames (moving box, sequence stamps), scripted grants/rejections, delayed or lost acknowledgements, surface rotation, accepted-command counters and readback, event log.
- Control panel reaches every required workspace state: connect/disconnect/reconnect, control grant/reject/hold, ack delay/loss, frame start/stop, surface rotation, terminal end-session.
- Committed Xcode project + shared `BrowserLab` scheme; focused UI tests (`BrowserLabUITests`): banner presence, take-control flow, keyboard draft insert, stale-frame shield on disconnect.
- `BrowserLab/Tools/validate-scope.py`: static scope/project validation (runs on Linux too).

**CI** — `.github/workflows/remote-browser-lab.yml` (additive): static validation, `swift test` on the package, then `xcodebuild build-for-testing` / `test-without-building` for the BrowserLab scheme on an iPhone simulator.

## Running the lab locally

```bash
python3 BrowserLab/Tools/validate-scope.py
swift test --package-path Packages/SemrehRemoteBrowser
open BrowserLab/BrowserLab.xcodeproj  # run the BrowserLab scheme
```

## Verifier target (native, Sol)

CI is the admission gate, not acceptance. Verify on the exact PR head SHA, one warm simulator:

1. Launch BrowserLab; the simulated-session banner is visible and never claims a live Hermes connection.
2. Connect → watch state ("Watching Hermes", remote input disabled). Watch gestures never emit remote input (readback counter stays put).
3. Take control → manual state ("You're in control"); direct tap/scroll and trackpad cursor/scroll increment the accepted-command counter; black-bar taps are rejected.
4. Keyboard draft: type locally, Insert sends committed text exactly once; killing the ack keeps the draft preserved and marked unconfirmed — never resent.
5. Resume Hermes disables input before dispatch; a lost acknowledgement leaves the outcome unknown and replays nothing.
6. Disconnect shields the last frame as stale; reconnect restores; end-session is terminal.
7. Required-state appearance: named-state screenshots for watching / request-pending / manual / resume-unknown / disconnected / ended.

No physical-device claims from simulator evidence. No product tests may use personal Hermes services or state.

## Repair route

Failed findings return to this owner and this branch. Reproduce via the fixture knobs first, repair without weakening any assertion, re-run the exact-head CI (package tests + BrowserLab scheme), and keep the PR at `needs-verify` until the verifier accepts. Two failed repair attempts on the same hypothesis escalate to the coordinator rather than repeating.
