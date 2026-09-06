# Slice 2 task sheet

Status: OPEN. Updated September 5, 2026. Integrator owns this sheet.

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

- [ ] **S2-A — Stock production login/chat and cross-client gate.**
  Owner: Luna preparation/implementation; integrator execution/review.
  Status: Luna stock_ui_enable and stock_tui_enable implementing disjoint launcher
  and test guards; integrator retains all live execution and acceptance.
  Adapt only the existing smoke launcher/test guards to explicitly accept stock
  mode. Preserve exact source/runtime guards and all product assertions. Exercise
  actual signed app navigation and stock bidirectional TUI continuity, not only a
  constructed view model. Record commands, counts and sanitized evidence.
  - [x] Stock production sign-in, Control startup, New Chat, send and visible ACK:
    `slice2-stock-production-ui-v1.xcresult`, 1 pass / 0 skips; screenshot inspected.
  - [x] Semreh-created durable `20260906_000301_0be890` rendered by literal stock
    TUI, exact prompt/ACK observed by integrator (PTY95629, normal exit).
  - [ ] TUI-created durable `20260906_000444_8a36c3` opened in native app. Literal
    stock TUI creation and REST exact pair verified; app deep-link rerun pending.
- [ ] **S2-B — Independent clean-checkout final verification.**
  Owner: integrator with bounded worker review. Status: pending S2-A.
  Verify the exact committed source and all binding Slice 2 gates against the
  pinned stock backend. Label prior dev-only evidence, skips and blockers honestly;
  do not turn this into another broad implementation pass.
  - [x] Stock foundation and native-flow reruns: each 1 pass / 0 skips;
    `slice2-stock-foundation-v1.xcresult`, `slice2-stock-native-flow-v1.xcresult`.
  - [ ] Stock identity and queued/rejected steer probes: Luna adapting guards;
    root caught missing dev validation and requested correction before live use.
  - [ ] Stock rotation/ancestor probe: Luna adapting explicit stock validation.
  - [ ] Final full native run: v1 interrupted after no test output; v2 pending.
    Retain v1 failure/runner evidence; no infrastructure-only diagnosis claimed.
- [x] **S2-C — Document accepted compacted-history chronology limitation.**
  Owner: integrator. Status: Maurice explicitly accepted temporary exception.
  Real compression exposed copied-head ordering in stock include_compacted REST.
  A separate local Hermes fix exists at `a9a8836a2`; not adopted or published by us.
  The chronology check remains failed on the tested pin; this checkbox records
  the documented acceptance decision, not a fix. No private-fork adoption or
  weakened assertions. Other paging/identity/duplicate gates remain required.
- [ ] **UP-1 — Separate upstream contribution (not a Slice 2 blocker).**
  Owner: Luna upstream_contribution_check + integrator. Status: existing PR being
  checked read-only before publication. Contribute original evidence/tests to the
  existing PR if sufficient, otherwise independently verify and submit focused fix.
- [ ] **S2-D — Physical iPhone responsiveness acceptance.**
  Owner: Maurice + integrator. Status: not requested yet; prepare automated gates
  first. Arrange an explicitly approved test-build delivery method. Guide long-chat
  scrolling, bottom arrow, chat/tab switching, sending and thinking-card lifecycle.
  Record device/build and observed failures; Simulator success cannot check this box.
- [ ] **S2-E — Final acceptance and handoff.**
  Owner: integrator. Status: pending S2-A, S2-B and S2-D; UP-1 is independent.
  Reconcile every binding gate with evidence, unresolved risks and user decisions.
  Report implemented versus tested versus still unverified. No automatic Slice 3.

## Next update format

Report boxes closed, checks run, remaining blockers and whether Maurice is needed.
Do not present checked-box count as a percentage of implementation or time left.
