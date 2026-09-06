# Slice 2 task sheet

Status: AWAITING IPHONE ACCEPTANCE. Updated September 6, 2026.
Integrator owns this sheet. Non-device checks complete with documented exception.

This is a progress index, not a new specification. The
[execution plan](semreh_tui_gateway_v3_execution_plan.md) owns scope and acceptance;
[verification ledger](slice2-verification.md) owns detailed commands and evidence.
Local `CURRENT.md` owns resumable runtime state. Checkboxes mean the stated check
passed, not that broader behavior or the entire slice is accepted.

## Boundaries

- Semreh targets official Hermes commit `29112bef099274229cadff79cdff7bf7b99c4b77`.
- No private backend requirement, personal Hermes changes, routes or deployment.
  Only the focused upstream compaction contribution is authorized for publication
  after review; Semreh push/release is not authorized.
- No Slice 3, redesign or future integrations. Luna handles bounded tasks;
  integrator reviews and independently verifies. No Astra trial currently planned.
- One Simulator/DerivedData owner: integrator. Workers do not edit shared notes.

## Completed checkpoint checks

App checkpoints: `a4e8257` and `4d040a3`. Evidence directory:
`/Users/maurice/workspace/semreh-slice1-evidence`.

- [x] Focused native controller/view-model/scroll tests: 113 pass, zero failures.
  Evidence: `slice2-stock-native-focused-v1.xcresult` and source snapshot patch.
- [x] Full native suite: 2014 pass, zero failures, 7 intentional opt-in skips.
  Evidence: `slice2-stock-full-native-v1.xcresult`.
- [x] Long-chat Simulator lab: two runs, each two passing tests; static 10k rows
  and three 10k-row conversations with append/scroll/switch/revisit.
  Evidence: `slice2-stock-long-chat-ui-v1.xcresult` and `v2` equivalent.
  Not physical-device, real-network long-history or FPS proof; old failures remain.
- [x] Stock HTTPS normal-turn protocol smoke and native reasoning smoke.
  Evidence: `slice2-stock-compatibility-v1.json` and
  `slice2-stock-native-reasoning-v1.xcresult`. Reasoning checks actual next request,
  busy deferral, unchanged sibling and cold resume; accepted race remains.
- [x] Combined pure fixture/launcher tests: 25 pass. Known-secret artifact audit:
  zero flags; evidence `slice2-stock-final-audit-v1.log`. Privacy exclusions apply.

## Remaining work

- [x] **S2-A — Stock production login/chat and cross-client gate.**
  Owner: Luna preparation/implementation; integrator execution/review.
  Status: implemented, independently reviewed and executed against stock.
  Adapt only the existing smoke launcher/test guards to explicitly accept stock
  mode. Preserve exact source/runtime guards and all product assertions. Exercise
  actual signed app navigation and stock bidirectional TUI continuity, not only a
  constructed view model. Record commands, counts and sanitized evidence.
  - [x] Stock production sign-in, Control startup, New Chat, send and visible ACK:
    `slice2-stock-production-ui-v1.xcresult`, 1 pass / 0 skips; screenshot inspected.
  - [x] Semreh-created durable `20260906_000301_0be890` rendered by literal stock
    TUI, exact prompt/ACK observed by integrator (PTY95629, normal exit).
  - [x] TUI-created durable `20260906_000444_8a36c3` opened in native app:
    `slice2-stock-cross-client-ui-v1.xcresult`, 1 pass / 0 skips; screenshots inspected.
- [x] **S2-B — Independent clean-checkout final verification.**
  Owner: integrator with bounded worker review. Clean detached worktree full suite
  at `30e22ff`: 2014 pass / 0 fail / 7 intentional skips. At `e775814`:55 pure
  helper tests pass; signed production/cross-client UI v2 pass1/0skip. Production
  app and native unit-test source identical between commits; final changes were
  UI-test navigation and probe diagnostics. Existing build/package cache reused.
  Evidence: `slice2-clean-stock-native-v1.xcresult` and
  `slice2-clean-stock-cross-client-ui-v2.xcresult`.
  Verify the exact committed source and all binding Slice 2 gates against the
  pinned stock backend. Label prior dev-only evidence, skips and blockers honestly;
  do not turn this into another broad implementation pass.
  - [x] Stock foundation and native-flow reruns: each 1 pass / 0 skips;
    `slice2-stock-foundation-v1.xcresult`, `slice2-stock-native-flow-v1.xcresult`.
  - [x] Stock identity and queued/rejected steer probes: both live PASS, empty
    cleanup errors and unchanged config (`slice2-stock-{identity,steer}-live-v1.json`).
    Root caught missing dev validation; corrected and regression-tested before use.
  - [x] Stock rotation/ancestor probe: live PASS, actual24→22rows, child canonical
    paging/continuation/cold reload (`slice2-stock-rotation-live-v1.json`). This
    does not claim full original-parent transcript reconstruction.
  - [x] Final full native run: v1 interrupted after no test output; v2 PASS,
    2014 passed / 0 failed / 7 intentional opt-in skips.
    Retain v1 failure/runner evidence; no infrastructure-only diagnosis claimed.
  - [x] Clean UI failure investigated: authenticated restored chat hid shell tabs.
    Corrected test uses known chat BackButton before shell checks. Main corrected
    run and clean v2 passed; original clean-v1 failure remains in the ledger.
- [x] **S2-C — Document accepted compacted-history chronology limitation.**
  Owner: integrator. Status: Maurice explicitly accepted temporary exception.
  Real compression exposed copied-head ordering in stock include_compacted REST.
  A separate local Hermes fix exists at `a9a8836a2`; not adopted or published by us.
  The chronology check remains failed on the tested pin; this checkbox records
  the documented acceptance decision, not a fix. No private-fork adoption or
  weakened assertions. Other paging/identity/duplicate gates remain required.
  `slice2-stock-inplace-counts-v2.json` confirms all24original fixture rows exactly
  once, archived rows present and latest pages reconstructing the display set;
  strict chronology still FAILS as accepted, cleanup empty/config unchanged.
- [x] **UP-1 — Separate upstream contribution (not a Slice 2 blocker).**
  Owner: Luna upstream_contribution_check + integrator. Posted independently
  reproduced stock failure/local-fix success and targeted5test results on the
  existing author's PR; no duplicate fix PR or private-fork adoption:
  https://github.com/NousResearch/hermes-agent/pull/93869#issuecomment-5557664077 .
  This completes the evidence contribution, not upstream merge/release. Additional
  test-code contribution can follow maintainer feedback separately.
- [ ] **S2-D — Physical iPhone responsiveness acceptance.**
  Owner: Maurice + integrator. Status: ready to arrange a separately approved
  test-build delivery method; do not replace the installed production app. Guide long-chat
  scrolling, bottom arrow, chat/tab switching, sending and thinking-card lifecycle.
  Record device/build and observed failures; Simulator success cannot check this box.
  - [ ] Approve delivery/install of a separate test build and record device/build.
  - [ ] Scroll long chats up/down; jump-to-bottom; interrupt jump with a gesture.
  - [ ] Switch among multiple long chats and Sessions/Control/You, then return.
  - [ ] Send/stop; verify transcript stability and thinking/tool-card lifecycle.
  - [ ] Change reasoning while idle/busy; confirm pending/applied feedback.
  - [ ] Record observed responsiveness/glitches and Maurice's acceptance or fixes.
- [ ] **S2-E — Final acceptance and handoff.**
  Owner: integrator. Status: pending S2-D; UP-1 merge/release is independent.
  Reconcile every binding gate with evidence, unresolved risks and user decisions.
  Report implemented versus tested versus still unverified. No automatic Slice 3.

## Next update format

Report boxes closed, checks run, remaining blockers and whether Maurice is needed.
Do not present checked-box count as a percentage of implementation or time left.
