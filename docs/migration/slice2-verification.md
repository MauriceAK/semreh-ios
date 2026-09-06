# Slice 2 verification — in progress

## September 6 — stock gate closure checkpoint

Maurice accepted the reproduced compacted-row chronology bug on the tested stock
pin as a temporary documented limitation, not a blocking requirement. The failing
assertions remain intact. This does not exempt other paging/identity gates or
authorize a private backend requirement. Physical iPhone acceptance remains open.

Root independently reviewed Luna's explicit stock-mode launcher/probe changes and
ran the following against clean stock `29112bef099274229cadff79cdff7bf7b99c4b77`.
App source is `a4e8257` plus the bounded test/helper changes in this checkpoint;
no production app or Hermes source changed during this pass. Evidence below is
under `/Users/maurice/workspace/semreh-slice1-evidence`.

- `slice2-stock-foundation-v1.xcresult`: 1 passed, 0 failed/skipped. Existing
  `--https --slice2-foundation` launcher and signed test-without-building. Root
  source-confirmed ten exact durable user/assistant pairs, reconnect binding and
  discovery, plus server interrupt/terminal assertions in the selected method.
- `slice2-stock-native-flow-v1.xcresult`: 1 passed, 0 failed/skipped, same command
  with `--slice2-native`; constructs native view model, not production navigation.
- `slice2-stock-production-ui-v1.xcresult`: 1 passed, 0 failed/skipped. Signed
  UIVerification build-for-testing, launcher `--https --slice2-ui --stock-backend`,
  then test-without-building. Actual sign-in, Control startup, New Chat, send,
  exact visible ACK. Root inspected exported success screenshot.
- Stock literal TUI built with locked `npm ci --workspace ui-tui --include=dev
  --ignore-scripts --no-fund --no-audit`, then `npm run build --workspace ui-tui`.
  Explicit empty inherited environment, fixed disposable npm cache/TMPDIR and
  `/dev/null` user config; no HOME reassignment. Tracked backend source stayed
  clean. Logs `slice2-stock-tui-{npm-ci,build}-v1.log`.
- `direct_hermes_tui.py --stock-backend`, PTY52512: real input/Enter produced
  `SEMREH_TUI_CROSS_CLIENT_1` and rendered `SEMREH_SLICE1_ACK`; normal `/exit`.
  REST independently confirmed exact pair at durable `20260906_000444_8a36c3`.
- `slice2-stock-cross-client-ui-v1.xcresult`: 1 passed, 0 failed/skipped. Stock UI
  launcher with `--tui-created-session-id 20260906_000444_8a36c3`, same signed build;
  actual deep link rendered both markers, screenshots exported and inspected.
- Reverse direction: production-UI-created `20260906_000301_0be890`, confirmed by
  REST, then literal stock TUI `--resume-stored-id` displayed the exact app
  prompt/ACK, root-observed PTY95629; normal exit. TUI owns a separate stdio
  gateway sharing disposable state; this is not Desktop or shared-live-socket proof.
- Full native `slice2-stock-final-native-v1` produced no test stdout for ~4.5min.
  Root interrupted exact owned xcodebuild99457; exit73. Retained bundle/log; no
  passing-test or infrastructure-only diagnosis. Bounded v2 rerun PASS:
  `slice2-stock-final-native-v2.xcresult`: 2014 pass, 0 fail, 7 intentional opt-in
  skips (2021 total). Canonical signed `xcodebuild test`, owned Simulator/DerivedData,
  jobs2, no parallel tests, diagnosticsnever, test timeouts60/120s.
- Root pure helper discovery: `PYTHONPATH=scripts .../semreh-slice1-venv/bin/python
  -m unittest discover -s scripts -p 'test_direct_hermes_*.py' -q`: 53 passed.
  Root caught and required repair of a dropped development validator in the first
  steer adapter candidate; added boundary tests prove validation precedes reads.
- `direct_hermes_identity_probe.py --stock-backend --output <evidence>/slice2-stock-identity-live-v1.json`:
  PASS; strict fresh/live/cold/deferred/lazy identity, paging and durable assertions
  retained; HTTPS and unchanged global config, cleanup empty.
- `direct_hermes_steer_probe.py --stock-backend --output <evidence>/slice2-stock-steer-live-v1.json`:
  PASS; queued/rejected wire outcomes, exact durable turns; accepted is native
  compatibility enum coverage, not an invented stock wire status.
- `direct_hermes_compression_probe.py --mode rotate --stock-backend --output
  <evidence>/slice2-stock-rotation-live-v1.json`: PASS. Root validated stock source
  and rotation sibling before starting fixed localhost18793 with empty-env stock
  `hermes_cli.main serve --isolated`; PID4859/cwd externally checked. Actual24→22
  rows and14505→14182tokens; parent/child metadata, ancestor→tip pages, continuation
  and cold reload exactly once, cleanup empty/config unchanged. This proves child
  canonical pages, NOT reconstruction of every original parent row. PID4859
  normally TERM-stopped after the test; main stock18791/proxy unchanged.
- Upstream: no competing fix PR. Root posted independent public-API reproduction
  and targeted-test evidence on the existing author's PR:
  https://github.com/NousResearch/hermes-agent/pull/93869#issuecomment-5557664077 .
  Root reproduced baseline failure/local-fix success with a disposable DB and
  independently reran5publicAPI tests. Targeted pytest only; canonical upstream
  wrapper probes personal Hermes paths and was not used. No PR-branch full-suite
  claim, private-fork adoption or app deployment.

Final clean-checkout verification and physical-device acceptance remain pending.
Historical sections below retain earlier failures and superseded dev-only results.

Binding plan: `semreh_tui_gateway_v3_execution_plan.md`.
Hermes pin: `29112bef099274229cadff79cdff7bf7b99c4b77`.
Semreh branch: `chore/direct-hermes-v3-slice2`, based on verified `606b8a5`.

## Foundation checkpoint, September 4

**This is not a passed Slice 2 gate or a production UI cutover.**

Implemented foundation:

- One runtime-owned connect/reconnect task and ordered event consumer; active
  transport generation checks; recovery and ready-socket attachment barriers.
- Conversation-owned durable/runtime binding, lazy first-send creation, explicit
  profile, prompt/steer/interrupt, canonical transcript callbacks and stale-read
  protection. No automatic retry of an ambiguous prompt.
- Official profile-scoped session list and bounded latest transcript pages,
  canonical continuation IDs, numeric row IDs and compaction display projection.
- Explicit failure for conflicting aliases, unconfirmed stop, and disconnected
  draft cleanup. Event queue overflow fails closed, not silently lossily.

Signed builds and tests use only disposable Simulator
`D852F8F7-6C05-4FAE-8F05-CBCB7C4B3263` (iPhone 17e, iOS 26.5).
Build artifacts: `/Users/maurice/workspace/semreh-slice1-build`.
Evidence directory: `/Users/maurice/workspace/semreh-slice1-evidence`.

### Recorded results

- Signed app build passed.
- `slice2-runtime-foundation.xcresult`: initial 15 tests passed.
- `slice2-foundation-focused-v2.xcresult`: test compilation failed because a new
  test used a nonexistent response helper. Fixed; no test was skipped to pass.
- `slice2-foundation-focused-v3.xcresult`: 35 passed, zero failed/skipped.
- `slice2-foundation-focused-v4.xcresult`: 37 passed, zero failed/skipped.
- `slice2-controller-live-https-v1.xcresult`: one opt-in hosted test passed,
  zero skipped. Ten deterministic turns produced exactly ten durable user rows
  and ten assistant rows, in expected user-text order. Direct discovery,
  second-controller resume, shared-runtime reconnect, and actual controller
  interruption with matching terminal event and server non-running state passed.
- `slice2-foundation-full-v1.xcresult`: 1,932 passed, zero failed; five deliberately
  opt-in live/cookie tests skipped in the default suite. The new live controller
  test was run separately above with zero skips.
- `slice2-foundation-full-v2.xcresult`: 1,936 passed, zero failed, the same five
  intentional opt-in skips, after adding the renderer value mapper. Its tests
  cover whitespace, stable tool IDs, actual gateway usage fields, and distinguishing
  control/unknown frames from terminal completion. UI consumers are not wired yet.
- Known-secret/bearer-pattern audit scanned 34,921 artifact/log/doc files,
  including exported full-suite and live-test console diagnostics: zero flags.
  This heuristic does not prove absence of every possible opaque secret.
- Repeated audit including full-v2 exported diagnostics: 40,530 files, zero flags.

### Reproducible commands

Run from the migration worktree. Do not substitute a personal Simulator/server.

```sh
xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=D852F8F7-6C05-4FAE-8F05-CBCB7C4B3263' \
  -derivedDataPath /Users/maurice/workspace/semreh-slice1-build \
  -parallel-testing-enabled NO -jobs 2 \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -resultBundlePath /path/to/new-result.xcresult -quiet
```

For the focused subset, add `-only-testing:HermesMobileTests/<class>` for
`HermesServerRuntimeTests`, `HermesGatewayClientTests`,
`GatewayConversationControllerTests`, and `APIClientDirectSessionsTests`.

With the existing guarded disposable model/backend/HTTPS proxy running:

```sh
/Users/maurice/workspace/semreh-slice1-venv/bin/python \
  scripts/direct_hermes_ios_smoke.py --https --slice2-foundation
xcodebuild test-without-building \
  -xctestrun /Users/maurice/workspace/semreh-slice1-build/Build/Products/SemrehSlice1Live.xctestrun \
  -destination 'platform=iOS Simulator,id=D852F8F7-6C05-4FAE-8F05-CBCB7C4B3263' \
  -parallel-testing-enabled NO \
  -resultBundlePath /path/to/new-live-result.xcresult -quiet
```

The fixture calls no external model/provider and exposes only the existing
bounded clarify toolset. Personal Hermes and personal Tailscale routes are not
targets. The hosted test uses ephemeral REST cookies and no personal headers.
Runtime credentials remain outside the repository and test plan.

## Review and remaining gates

Luna High implemented REST/auth scaffolding and tests; the integrator reviewed
and corrected integration errors, and a separate Luna High reviewer identified
runtime-generation, stale-refresh, and ready-socket resume races. Root independently
built and ran the tests and the live backend gate. Parsing alone was never treated
as runtime verification. A clean-checkout final Slice 2 rerun is still required.

Not yet verified/complete: production login and navigation cutover, native
renderer/composer/cache/Live Activity wiring, profile-aware navigation rekey,
compaction and cross-client fixture matrix, complete paging/prepend behavior,
physical-iPhone responsiveness, and the full Slice 2 gate. Foundation callbacks
do not replace those checks. Broad ambiguous-delivery/mobile lifecycle coverage
remains Slice 3 work; the current foundation blocks uncertain automatic resend.

## Native chat integration checkpoint, September 4

This checkpoint advances the production wiring; **Slice 2 remains incomplete**.
It is not a release or a physical-iPhone acceptance result.

Implemented:

- Direct authentication/provider discovery and username entry in onboarding and
  Add Server; protected probe before account persistence.
- Auth-driven active-origin runtime ownership in the retained chat store;
  synchronous conversation invalidation before asynchronous account teardown.
- Native ChatViewModel text send, resume/history, stop/retry, steer, and ordered
  text/reasoning/tool rendering through GatewayConversationController. Local
  drafts create only on first send; uncertain prompts are not automatically sent
  again. Native Live Activity updates use durable IDs, not gateway runtime IDs.
- Canonical-ID store redirects without duplicate retained/refresh entries;
  profile-scoped retained/cache identity; direct live state excluded from legacy
  sidebar stream-status RPCs and per-chat WebUI status watches.
- Direct profiled sidebar list and local draft creation. UI policy tests for
  legacy-only fields use explicit cached native models rather than pretending
  official REST provides project/runtime-stream fields.
- Explicit temporary guards for deferred WebUI actions; blocking gateway waits
  show an input-required banner, not a silent wait or WebUI fallback.

Verification:

- `slice2-native-integration-focused-v2.xcresult`: 47 passed, no failures/skips.
- `slice2-native-integration-full-v5.xcresult` and `full-v6.xcresult`: 1,955 passed,
  zero failed, six intentional opt-in skips. The additional skip is the new
  separate native ChatViewModel live test.
- Latest `slice2-native-integration-full-v7.xcresult`: 1,955 passed, zero failed,
  six intentional skips, including the final direct/legacy polling-boundary
  regression and ownership notifications restricted to run transitions.
- `slice2-native-chat-live-https-v2.xcresult`: one passed, zero skipped. Production
  APIClient/runtime/ChatViewModel sent through the actual disposable HTTPS
  gateway, reconciled exactly one canonical user/assistant pair with durable row
  IDs, and reopened the same conversation in a second native view model.
  This uses ephemeral cookies and an injected runtime, not AuthManager or UI
  automation. It is a deterministic provider test, not a real-model quality test.
- Earlier failed runs are retained: mock return/initializer-order compilation
  errors, old sidebar fixture assumptions, a renderer-wait test race, and a live
  test incorrectly requiring an unchanged-ID notification were corrected.
  Full-v4 was interrupted after XCTest failed to attach; only the disposable
  Simulator was restarted, and the next full run passed. No tests were skipped
  to make these failures disappear.
- Signed app launched on the disposable Simulator; the inspected welcome-screen
  capture is `slice2-native-signed-launch.png`. This is launch evidence, not a
  completed chat-navigation UI test. Legacy welcome copy remains cleanup work.
- Artifact audit including exported full-v7 and native-live-v2 console logs:
  66,120 files scanned, zero known-secret/obvious-bearer flags. This is a heuristic,
  not proof of absence of arbitrary opaque secrets. Owned fixture/backend/proxy
  processes were stopped afterward; test ports were confirmed free.

Reproduce the new live test using the same guarded backend and signed build:

```sh
/Users/maurice/workspace/semreh-slice1-venv/bin/python \
  scripts/direct_hermes_ios_smoke.py --https --slice2-native
```

Then use the `test-without-building` command above with a fresh result path.
Known-secret/bearer audit must include exported latest full/live diagnostics.

Luna High supplied bounded auth/sidebar/test patches; root integrated, corrected
and ran verification. One Terra Medium read-only review found the stop-retry
lockout (fixed and regression-tested), silent blocking waits (now surfaced), and
a remaining latest/older-page presentation race. Worker parsing was not counted
as a successful compile or runtime test.

Remaining gates: direct composer model/profile/reasoning controls (currently
guarded), sidebar gateway invalidation and secondary route disposition,
continuation/compression/cross-client fixtures, paging/reconcile ordering,
complete stop/steer/event coverage, actual UI navigation/cache/Live Activity
behavior and responsiveness, physical-iPhone checks, and final independent rerun.
Native blocking-response controls and broad mobile lifecycle/orphan recovery are
still Slice 3 work. No custom UI/redesign work was started.

## Composer draft and sidebar checkpoint, September 4

Slice 2 is still incomplete. This checkpoint adds profile-scoped model inventory
and local draft selections, not completed settings for existing conversations.

- `GET /api/model/options?profile=...&explicit_only=true` is the actual
  `hermes serve` contract: `hermes_cli/main.py:12294` starts
  `hermes_cli.web_server`; its handler at 7449–7499 enters `_profile_scope`
  inside the worker thread. The similarly named standalone API-server adapter
  is not this deployment's route owner. No `/p/...` routing is used here.
- Model/provider/reasoning/cwd picks remain local until `session.create`.
  Inventory capabilities gate reasoning visibility and disabling; the displayed
  levels are the pinned create parser vocabulary, not model-specific guarantees.
  Changing profile returns a new local draft without retargeting an existing
  controller or writing the host's active profile. Legacy composer suggestions
  and configuration writes are explicitly guarded in direct mode.
- Sidebar `sessions.changed` uses the existing active-origin runtime, a 300 ms
  debounce, editing/destructive-action deferral, and view lifecycle invalidation.
  The shared runtime supplies an optional ready callback after all recovery
  hooks, avoiding a separate sidebar recovery timer. No extra socket was added.

Important unresolved contract issue: pinned `tui_gateway/server.py:14520–14630`
implements `config.set` reasoning as a global profile configuration write when
the runtime session lookup is missing/stale, even if the caller asks for session
scope. Preflight cannot eliminate that race. `prompt.submit` has no reasoning
override; no verified fail-closed alternative was found. Root, Luna High, and
Sol Low independently checked this. Existing-chat reasoning remains unavailable;
Maurice must approve a temporary restriction or separate backend contract/pin
work. The backend clone/pin was not modified. Existing-chat model switching with
an explicit `--session` is separate unfinished integration, not the same blocker.

Verification, evidence rooted at `/Users/maurice/workspace/semreh-slice1-evidence`:

- `slice2-composer-sidebar-focused-v2.xcresult`: 27 passed, zero failures/skips.
  Covers draft inventory/picks/first-create values, non-reasoning and mandatory
  reasoning capabilities, legacy/global-write guards, local profile draft,
  sidebar debounce/deferral/stale-observer/profile behavior, and runtime barrier.
- `slice2-composer-sidebar-full-v1.xcresult`: 1,962 passed, zero failed, six
  intentional opt-in skips. Same signed full `xcodebuild test` command as above;
  focused run adds `-only-testing:HermesMobileTests/ChatViewModelDirectGatewayTests`,
  `.../SessionListGatewayInvalidationTests`, and `.../HermesServerRuntimeTests`.
- `slice2-composer-native-live-https-v1.xcresult`: one passed, no skips. Same
  `--https --slice2-native` generator and signed `test-without-building` procedure;
  now also reads the actual profiled model inventory before create, then verifies
  first send and canonical durable rows after reopening in another ChatViewModel.
  This remains deterministic view-model integration, not UI/physical-device proof.
- Focused-v1's test compilation failed (global fixture helper referenced as a
  member; private property assertion). Corrected before further feature work;
  failed evidence retained. No skipped/disabled assertions to obtain a pass.
- Exported console diagnostics: `slice2-composer-focused-v2-diagnostics`,
  `slice2-composer-full-v1-diagnostics`, `slice2-composer-live-v1-diagnostics`.
- Signed Simulator launch: inspected `slice2-composer-signed-launch-settled.png`.
  Welcome/onboarding only, not composer/sidebar visual acceptance. The first
  screenshot caught the launch animation and is retained separately.
- Guarded fixture/backend/proxy processes stopped afterward. Personal Hermes,
  routes, and credentials remained out of scope. The artifact audit now also
  covers private launcher logs in `runtime/logs`, not only Hermes home logs.
  Audit result: 71,689 files, zero known-secret/obvious-bearer flags, including
  exported full/live console logs. This remains a heuristic, not proof that
  arbitrary opaque secrets cannot occur.

Luna supplied the sidebar implementation and contract audit. Root corrected
lifecycle/recovery integration and test compilation, implemented composer wiring,
and ran all verification. Sol Low independently reviewed the reasoning issue;
its initial route concern was retracted after root traced the correct server.
Reviewer agreement is not used in place of source tracing or executable checks.

Still outstanding: existing-chat controls/disposition decision, late-provider
observer cancellation and slow recovery/sidebar UI stress coverage, latest/older
ordering, continuation/cross-client matrix, complete UI/cache/Live Activity
walkthrough, physical-device responsiveness, and independent final gate rerun.

## Long-chat paging and UI verification checkpoint, September 5

Slice 2 remains incomplete. Maurice authorized several very long synthetic
conversations and responsiveness checks before the slice gate. He also approved
bounded existing-session reasoning backend work in a separate development
checkout/runtime; that work remains outstanding, not blocked on another approval.
The clean backend pin and personal Hermes deployment are unchanged.

Implemented:

- Direct transcript render IDs now use durable message IDs, both for full
  projection and incremental live-row updates. The previous index-based IDs
  changed on prepend because direct paging has no stable forward absolute offset;
  this could retarget the saved scroll anchor. Legacy row IDs are unchanged.
- An overlapping, same-session canonical tail replaces its authoritative suffix
  without dropping the already-loaded durable prefix. Deleted rows within that
  suffix are removed, optimistic rows replaced, and the backward cursor adjusted.
  Disjoint tails reset to bounded canonical history rather than inventing
  continuity. Retained prefix rows are cached, not revalidated by the tail read.
- Latest-read generations reject superseded tail responses and older pages that
  cross a new tail read. Supersession does not show a misleading connection error.
- Generated fixtures provide three independent 2,000-row histories with Markdown
  and code. These are synthetic test inputs, not captured backend fixtures. Tests
  cover full paging, switching/reopening owners, stable render IDs, streamed-turn
  reconciliation to exactly 2,002 durable rows, removed suffix/cursor alignment,
  and disjoint-tail reset. Paging loops are bounded and fail on stalled progress.
- A separate opt-in `HermesMobileUIVerification` scheme and native UI-test target
  exercise the existing server-free 10,000-row DEBUG lab with real swipe/tap
  automation. The default unit-test scheme is unchanged. The lab gained an end
  marker after its 320-line code block and a corrected mixed-Markdown seed branch.

Verification (artifacts under the evidence root named above):

- `slice2-long-chat-focused-v2.xcresult`: 87 passed, zero failures/skips. Same
  signed test command, selecting ChatViewModelDirectGatewayTests,
  GatewayConversationControllerTests, ChatViewModelStreamingPaceTests, and
  ChatScrollPolicyTests. Export: `slice2-long-chat-focused-v2-diagnostics`.
- `slice2-long-chat-full-v1.xcresult`: 1,968 passed, zero failed, six existing
  intentional opt-in skips. Same signed full-suite command as previous checkpoints.
- `slice2-long-chat-native-live-v1.xcresult`: one passed, zero failures/skips,
  using the existing `--https --slice2-native` generator and signed
  test-without-building command. Actual disposable pinned backend/proxy,
  production VM/runtime, inventory/create/send/canonical durable rows/reopen;
  deterministic provider only, not a long-history real-backend or UI test.
- `slice2-long-chat-ui-v3.xcresult`: one passed, zero failures/skips. Same signed
  Simulator/destination/DerivedData command with scheme
  `HermesMobileUIVerification` and a 120-second test allowance. Assertions require
  a real transcript swipe, the bottom-arrow tap, a visible/hittable end marker,
  and disappearance of the arrow. Root inspected all three screenshots in
  `slice2-long-chat-ui-v3-attachments`: before scroll, after swipe, and at the
  actual end of the large code block. This is real UI interaction, not just VM
  assertions, but still a static single-chat render lab, not a direct-gateway
  multi-chat/send/tab-switch or physical-device performance gate.
- Failed evidence retained: focused-v1 failed test-fixture compilation because
  optional query values produced String??. Root corrected the fixture; parser
  success and worker review had not established compilation. UI-v1 reached
  welcome; an explicit app termination now precedes launch. UI-v2 reached the
  lab but incorrectly asserted the SwiftUI grouping container was hittable;
  the test now targets the actual scroll view. No product gate was skipped.
- Exported full/UI/live diagnostics are `slice2-long-chat-full-v1-diagnostics`,
  `slice2-long-chat-ui-v3-diagnostics`, and
  `slice2-long-chat-native-live-v1-diagnostics`. Artifact audit: 81,207 files,
  zero known-test-secret/obvious-bearer flags. This remains a heuristic, not
  proof of all opaque-secret absence. Guarded model/backend/proxy processes
  60553/60570/60593 were TERM-stopped and absent afterward; ports 18791/18792 free.

Luna High implemented bounded fixture/UI-test work and found the direct row-ID
issue during read-only review. Root implemented the production fixes, strengthened
the regression cases, corrected fixture compilation and UI-test targeting,
independently reviewed screenshots, and ran all tests. No model upgrade was used
for this checkpoint. Review/parse claims were not treated as executable proof.

Remaining performance work: multiple direct chats and tab changes while actively
streaming in native UI, repeated scroll/arrow/older-page cycles, measurements of
frame hitches and memory, and physical-device acceptance. The existing 1k/10k VM
hot-path scaling test passed, but does not measure SwiftUI diff/layout or FPS.
Disjoint-history/large external-append presentation still needs a deliberate
recovery UX; the current safe reset is not proof of uninterrupted scroll position.
This checkpoint does not diagnose every reported legacy WebUI glitch or claim
overall smoothness is solved. No renderer rewrite or new runtime owner was added.

## Per-session reasoning checkpoint, September 5

Slice 2 remains incomplete. The approved backend extension is on the independent
development branch `fix/semreh-session-reasoning`, commits `a19afe8846d6525a287aa4edcb1ec183e82030bd`
and `8c50f84522a755d40346e73701a6847fbdde20ec`. The clean baseline at
`29112bef099274229cadff79cdff7bf7b99c4b77` and personal deployment are untouched.
The guarded development launcher requires the exact clean development SHA and
also validates the unchanged baseline. A separate disposable runtime/home/DB
uses only the prior test fixture's configuration/auth, with a new tool directory.

Backend behavior:

- Explicit missing/stale/closing session IDs and mismatched profiles fail closed,
  including legacy requests that supply a stale ID without an explicit scope.
  Display aliases cannot be mistaken for session effort changes.
- Accepted session choices are saved and read back before a durable ACK. Missing
  durable rows do not produce false success. Busy choices preserve the current
  agent and apply at the existing next-turn acceptance boundary; subsequent
  runtime metadata saves cannot erase the pending choice.
- Cold/deferred resume preserves stored reasoning even when the stored provider
  identity must fall back to the configured endpoint. This was a real-network
  defect missed by initial mocks, not just a speculative hardening change.
- `config.get key=reasoning` advertises `session_reasoning_contract: 1`. Valid
  older replies are read-only in the app. The native controller requires a fresh
  handshake, exact runtime/profile binding and socket generation, and a matching
  scoped, persisted ACK for each write. Settings writes serialize, stale reads
  cannot overwrite a newer selection, and sends cannot race an in-flight write.
- Native VM integration optimistically updates the effort label, rolls back an
  unconfirmed save without retrying, and supports next-turn choices while running.
  Model/workspace controls retain their separate idle/draft gating. Inheritance
  remains a draft choice, not an unsupported existing-session clear operation.
  Failed support discovery has an explicit reload message; stale capability is
  disabled after refresh failure. No extra token-driven configuration polling.

Backend verification (evidence root as above):

- `slice2-reasoning-prefixed-tests-v1.log`: pre-fix scope reproduction, four
  failures/nine passes. Scope-fixed checks then passed 13 tests.
- `slice2-reasoning-next-turn-v1.log`: focused server/scope/next-turn checks,
  644 passed. Full gateway suite-v1 had one collection error (missing declared
  aiohttp test dependency); it was not called green. After installing that
  declared dependency into the disposable venv, suite-v2 passed 1,556 with one
  existing skip. No application dependency was added.
- `slice2-reasoning-cold-build-focused-v1.log`: 44 passed. Final
  `slice2-reasoning-backend-suite-v3.log`: 100 files, 1,557 passed, zero failed,
  one existing skip, exit zero. This is the gateway suite, not all Hermes tests.
- Tests use the repository's `scripts/run_tests_parallel.py` directly under
  `env -i` with explicit disposable Python/PATH, UTC/C.UTF-8, two workers and
  `--file-retries 0`. This is a safety deviation from `run_tests.sh`, whose
  environment bootstrap probes personal Hermes. The same subprocess runner and
  test conftest isolation are retained; no personal configuration is loaded.
- `slice2-reasoning-live-v1.json/.log`: retained FAILED cold-resume evidence.
  Actual model requests used low/medium/low/high, then omitted effort on resume
  while storage/UI still reported high. The deferred-build fix followed this.
- `slice2-reasoning-live-v2.json/.log`: PASSED actual dedicated HTTPS login,
  WS RPCs, delayed old-effort turn, queued high selection, subsequent high turn,
  stale/missing/profile rejection, unchanged sibling/global configuration, cold
  close/resume, and exact durable role/content ordering via profiled REST.
- After root TERM-stopped only the owned backend and relaunched the same guarded
  SHA, `slice2-reasoning-restart-v2.json/.log` PASSED retained history and actual
  high/medium requests from both resumed sessions. Restart-v1 failed during
  authentication because the new process was not ready; retained, then an HTTP
  readiness check preceded v2. No test assertion was removed to pass.
- These requests use the local deterministic `--reasoning-probe` fixture, where
  `gpt-5` is a local protocol-test name, not an external OpenAI model invocation.
  They prove propagation/persistence, not external-provider reasoning quality.

Native verification so far:

- `slice2-reasoning-controller-focused-v3.xcresult`: 26 passed, no failures/skips.
  V1 found two fake-call argument-label compile errors; v2 found a test that
  incorrectly called an already-running response "submitting." Root/worker
  corrections use an explicit prompt gate and actual state assertions.
- `slice2-reasoning-native-focused-v1.xcresult`: 44 passed, no failures/skips,
  signed controller + native VM tests. Includes optimistic state, rollback,
  running/deferred settings, old-backend read-only behavior, stale refresh, and
  visible retry guidance after first-send discovery failure.
- `slice2-reasoning-native-full-v1.xcresult`: 1,983 passed, zero failures,
  seven intentional opt-in skips. Signed full native suite; latest subsequent
  shell/UI edits still require a full rerun before the app commit.
- `slice2-reasoning-native-https-v1.xcresult`: one passed, zero failures/skips.
  Actual ChatViewModel/production runtime over dedicated HTTPS: low current turn,
  high queued during a running response, subsequent high, sibling medium, and
  VM reopen retaining high. Reopening the VM can reuse a live server runtime;
  separate Python close/resume and process-restart probes establish cold behavior.
- `slice2-reasoning-ui-lab-v1.xcresult`: one passed, zero failed, one opt-in
  live-test skip. Root inspected the three fresh 10,000-row screenshots; this
  remains static scroll/bottom-navigation evidence, not full performance proof.
- `slice2-live-ui-build-for-testing-v1.log`: signed UI build succeeded.
  `slice2-production-ui-https-v1.xcresult`: one FAILED real production UI test.
  Welcome, HTTPS connection and username/password login reached the session
  shell, but a blocking startup alert prevented opening the local New Chat draft.
  Root traced automatic legacy `loadProjects()` to `GET /api/projects`; an
  independent authenticated request confirmed 404 while `/api/profiles` and
  `/api/sessions` returned 200. The failed result, attachments and diagnostics
  are retained. The temporary direct-shell project gate is being corrected and
  must pass the real UI rerun before this checkpoint is complete. Legacy project
  models/preferences remain for Slice 4's explicit feature disposition.

Luna High supplied bounded backend/client tests and native integration harnesses;
root implemented backend/VM/UI changes and independently ran verification. Sol
Low source review identified valid persistence and read/write lifecycle issues,
which were fixed and regression-tested. Parse/worker review was never treated as
test execution. The current artifact audit scanned 82,497 files with no known
fixture-secret/obvious-bearer flags, including development logs; newest XCTest
console diagnostics still need export and a final rescan.

Live UI artifact handling: the next audit (90,542 files) found the disposable
test password once in the v1 simulator OS `logdata.LiveData.tracev3`, despite no
password `typeText` or explicit test logging. No personal credentials are used.
The v1 raw result bundle and diagnostics were preserved under the owner-only
`/Users/maurice/workspace/semreh-slice2-runtime/private-ui-diagnostics/` directory,
outside shareable evidence. This is a documented quarantine, not a clean audit
claim. Subsequent tests use `-collect-test-diagnostics never`; selected XCTest
results/attachments still require audit. Opaque/compressed raw bundles must not
be treated as proven secret-free.

Production UI follow-up:

- The temporary direct shell disables legacy project startup/refresh requests
  and hides the project section/context submenu. Stored preferences and legacy
  API/model code remain intact for Slice 4 disposition.
- UI-v2 completed normal sign-out and login but failed a harness assumption:
  login retained the You tab. The test now explicitly selects Sessions.
- UI-v3 reached Sessions/Control but found a real local-draft navigation defect:
  `SessionNavigationState.completeNewChatCreation` still required a durable ID.
  It now accepts a matching pending local route without a server ID, retaining
  stale/cancelled-route guards. Three new navigation regressions cover this.
- UI-v4 visibly opened New Chat, then failed to find a proposed UIKit-only
  composer identifier because SwiftUI propagates the parent chat identifier.
  The test now requires exactly one actual editable text view under that chat
  identifier. The ineffective new production identifier was removed.
- Signed UI builds v2–v5 passed. `slice2-production-ui-https-v5.xcresult`
  passed one test, zero failures/skips: normal scoped sign-out, actual Welcome
  login, Sessions/Control/Sessions, local draft navigation, typing/send and
  visible/hittable `SEMREH_SLICE1_ACK` from the dedicated gateway/model fixture.
  Root inspected `slice2-production-ui-https-v5-attachments/88503F26-B623-49FB-BD54-6BA8F061F6CB.png`:
  the actual user/assistant rows are visible; an iOS first-use slide-to-type tip
  overlays the keyboard area. This is functional UI evidence, not a polished
  device-performance acceptance.
  Failure artifacts remain recorded, not silently retried into a green claim.
  V2 raw bundle/attachments also remain in the owner-only private directory;
  v3 onward use `-collect-test-diagnostics never`. Post-quarantine shareable
  artifact scan: 89,053 files, zero flags; this excludes private raw diagnostics.
- Full-native-v2 failed before executing tests: Xcode reported "The test runner
  hung before establishing connection" after 364 seconds. A host sample showed
  an idle app main thread and no loaded XCTest test bundle; the exact cause is
  not established. It was not treated as a passing or code-regression result.
- `slice2-reasoning-native-full-v3.xcresult`: 1,986 passed, zero failed, seven
  intentional opt-in skips (1,993 total). Same signed build and original generated
  `HermesMobile_HermesMobile_iphonesimulator26.5-arm64.xctestrun`, run with
  `test-without-building`, the same approved Simulator, no Only/Skip filters,
  parallel testing disabled, 60-second test allowance and
  `-collect-test-diagnostics never`. No code/test changes between v2 and v3.
  Full-v3 and live-UI-v5 console diagnostics were exported for final audit.
- `slice2-reasoning-native-https-v2.xcresult`: final current-build reasoning
  rerun passed one, zero failures/skips, 23 seconds, using the approved dev SHA
  and `--https --slice2-reasoning` generated opt-in plan. Diagnostics exported.
  The signed app was then launched normally on the same owned Simulator.
- Final checkpoint artifact audit: 93,448 files, zero known-fixture-secret or
  obvious-bearer flags, including 32 exported XCTest console logs and final
  live/full/UI diagnostics. The private v1/v2 raw UI quarantine remains excluded
  and unshareable; this is not a claim that raw OS archives are secret-free.

Still open: actual bidirectional TUI/Desktop use, the real-backend
cold/deferred/lazy/continuation identity matrix, successful compression lineage
and ancestor-to-tip recovery, accepted/queued steer outcomes, long multi-chat
streaming/tab/scroll performance measurements, independent final clean-checkout
verification, and physical-iPhone responsiveness acceptance. Raw gateway RPC
probes alone are not proof of actual TUI/Desktop UI acceptance. Draft-only
model/workspace changes are not themselves a binding Slice 2 gate and must not
silently expand this checkpoint. No personal deployment or Slice 3 work occurred.

## September 5 continuation — identity, literal TUI preparation, multi-chat lab

Work follows app checkpoint `4e40d40`, backend development checkpoint
`8c50f84522a755d40346e73701a6847fbdde20ec`, unchanged independent baseline
`29112bef099274229cadff79cdff7bf7b99c4b77`. This section is not Slice 2 acceptance.
Evidence paths below are under `/Users/maurice/workspace/semreh-slice1-evidence`.

### Live identity and latest paging

`scripts/direct_hermes_identity_probe.py` reuses the guarded development fixture,
real password/cookie/ticket HTTPS path, and deterministic localhost model. It
creates its own disposable chat and closes only owned runtime handles.

```sh
/Users/maurice/workspace/semreh-slice1-venv/bin/python scripts/direct_hermes_identity_probe.py \
  --backend-sha 8c50f84522a755d40346e73701a6847fbdde20ec \
  --output /Users/maurice/workspace/semreh-slice1-evidence/slice2-identity-live-v3.json
/Users/maurice/workspace/semreh-slice1-venv/bin/python -m unittest scripts.test_direct_hermes_identity_probe -v
```

- Live-v3 passed: pre-first-send REST404; fresh empty live reuse; first send;
  persisted live reuse; confirmed close then new runtime for cold, deferred-history,
  and separate lazy/watch resumes; a successful turn after each; five exact durable
  user/assistant pairs; four latest-ordered pages reconstruct the exact chronological
  transcript; logout302 `/login` then protected401; no cleanup errors; unchanged
  fixture global config. Cold/deferred/lazy RPC acknowledgments were approximately
  30/31/29ms on this fixture, NOT end-to-end UI or production latency measurements.
- Six pure Python tests passed independently in worker and root runs.
- Sol Low reviewed the harness; root strengthened close/new-runtime, fresh REST
  absence, cleanup and failure-path config evidence. Live-v1 passed weaker checks;
  live-v2 retained a harness failure because HTTPX treats the source-defined logout
  redirect as an exceptional status. Live-v3 checks its actual302 contract.
- No compression/continuation or literal TUI/Semreh UI gate claimed by this probe.

### Real TUI preparation and first turn

- Installed only the existing lockfile's TUI workspace dependencies with `npm ci
  --workspace ui-tui --include=dev --ignore-scripts --no-fund --no-audit`, using
  explicit empty inherited environment, disposable HOME/npm cache and `/dev/null`
  npm user configuration. No new application dependency or lockfile change.
- `npm run build --workspace ui-tui` passed; self-contained bundle is3.6MB. Logs:
  `slice2-tui-npm-ci-v1.log` and `slice2-tui-build-v1.log`. Dependencies/cache consumed
  approximately148/35MB; development tracked tree remained clean.
- Luna authored `scripts/direct_hermes_tui.py`; root inspected its allowlisted
  environment and exact dev/runtime/bundle guards, then launched actual PTY52066.
  Typed `SEMREH_TUI_CROSS_CLIENT_1`, submitted with Enter, and observed rendered
  `SEMREH_SLICE1_ACK`. Normal `/exit` completed with code0. Official default-profile
  REST separately confirmed exactly one user/assistant pair at durable ID
  `20260905_122641_f43016`, including the exact prompt and reply.
- The TUI active-session hint held runtime ID `ff3f91d2`, not a durable ID. It must
  not be used as a REST/deep-link identifier. TUI normally owns a separate stdio
  gateway sharing the disposable DB; this is not same-live-gateway proof.
- Upstream's automatic update banner may fetch GitHub into the independent
  checkout's remote refs/cache. No disable flag was found in pinned source. This
  incidental update check is not model-provider access or personal Hermes access;
  no backend source upgrade was performed. The deterministic model stays local.
- Actual TUI↔Semreh handoff remains open; a TUI turn plus REST is not that gate.

### Multi-chat verification failures retained

Luna extended the DEBUG lab to three10,000-row conversations with paced synthetic
appends and actual ChatView scroll surfaces. These remain presentation fixtures,
not network streaming, measured FPS, or physical-device acceptance.

- UI-v1 failed initial accessibility lookup: an unnecessary lab ancestor identifier
  replaced existing child identifiers. Root removed the wrapper ID after inspecting
  the captured accessibility hierarchy.
- UI-v2 failed original-tail navigation; review found the fixture used raw message
  ID `perf-message-000020` instead of rendered restore ID `transcript:20`. Root
  corrected it; UI-v3 reached the original tail, then froze during the stream step.
- UI-v4 repeated the stream failure on the same build while root captured a bounded
  main-thread sample. UI-v5 still failed after switching the lab from full transcript
  recomputation to the existing incremental row helpers. Thus full-recompute cost
  alone was not the demonstrated cause of the persistent freeze.
- The sample directly includes `ChatPerformanceMultiLabView.body → ChatView.init →
  OpenChatSessionStore.gitAvailabilityViewModel → touch → accessOrder.modify →
  ObservationRegistrar → ObservationCenter.invalidate`. Internal LRU bookkeeping
  was observable and repeatedly invalidated the view performing the lookup.
- New `OpenChatSessionStoreTests.testExistingGitModelLookupDoesNotInvalidateItsObservingView`
  failed before the fix in `slice2-lru-observation-red-v1.xcresult`, demonstrating
  unwanted observation invalidation. Root added `@ObservationIgnored` to the one
  internal access-order field; no cache/eviction algorithm or renderer rewrite.
  Sol independently confirmed no production UI reader depends on that field.
- `slice2-lru-observation-green-v1.xcresult`: 40 focused tests passed, zero failed
  or skipped, including store regression and incremental three-fixture test.
- UI-v6 opened onboarding for the multi-lab case (cause unproven), but static10k
  passed. Same-build UI-v7 failed multi with UI-query snapshot timeout; static10k
  again passed. Its sample implicated SwiftUI lazy child prefetch rather than LRU.
- Luna made each transcript ForEach item one fixed VStack child while preserving
  message identity, row geometry and compression-card spacing. Root reviewed;
  UI-v8 signed build passed and the multi test reached both original tail and
  appended stream marker. After swipe-away and arrow return it became blank and
  failed the 25-second visible-marker assertion. Static10k passed. Root inspected
  `slice2-multi-chat-ui-v8-attachments/F7994C2C-57C8-4BA4-84A4-FDC2387CC002.png`
  (successful append), video-derived `slice2-multi-chat-ui-v8-away.png`, and blank
  `slice2-multi-chat-ui-v8-progress.png`. V8 sample was mostly idle, not a CPU loop.
- UI-v9 lab-only scroll/row-frame diagnostics reproduced the arrow failure:
  distance=0 while latest frame was nil and no rows were realized, followed by
  estimated maximum offset1.72M→4.82M. This confirms false metric convergence,
  without claiming to identify every SwiftUI internal cause of the estimate jump.
- UI-v10 first targeted the concrete last row, then the sentinel. Chat1/2 completed
  append/away/arrow, but chat3 failed that same arrow assertion; static10k passed.
  V10 metrics showed another estimate jump4.4M→10.6M and no realized latest row.
- UI-v11 failed compilation on root's helper argument order; corrected. UI-v12
  tested bounded repeated latest-row targeting until visible, and
  requiring both near-bottom metrics and visible latest-row/bottom-anchor geometry
  to finish settlement. Luna authored pure policy tests; root owns integration.
  but still failed multi/static passed. UI-v13 moved explicit identity to the outer
  lazy row; CPU-heavy prefetch returned and multi failed, static passed. Reverted.
- UI-v14 scoped arrow animation to a persistent overlay container, excluding the
  ScrollView; multi still failed/static passed. UI-v15 additionally deferred
  automatic-follow and composer expansion until explicit navigation had reached
  the visible tail, and stopped raw near-bottom callbacks from racing that request.
  **UI-v15 passed both tests, zero failures/skips**, including all three10k chats'
  append/away/arrow/revisit and the original static lab. Root inspected successful
  chat1/chat3 arrow screenshots `80F8F79A-582D-4926-8FEE-BA73E4BCA40B.png` and
  `FD8C58E4-FC49-4EA9-BAEA-D1DE0F87F374.png` in the v15 attachments directory.
  Synthetic paced append durations .610/.334/.339s include scheduled waits and
  produced zero full transcript recomputations; these are not FPS measurements.
- UI-v16 reruns with noisy geometry logs removed and the tested pure visibility
  helper wired. Final full-native suite, broader live performance/device gates
  remain pending. Failed evidence retained; no functional assertion removed.

### Completed September 5 performance/cross-client checkpoint

- UI-v16 completed: **2 passed, zero failed/skipped**, repeating v15 after cleanup.
  Evidence `slice2-multi-chat-ui-v16.xcresult`, log, attachments and diagnostics.
  Root inspected chat2 arrow screenshot `DBB54DE9-19E8-47ED-8DED-66EC811E7C1C.png`.
  Paced synthetic append .565/.340/.350s; zero full recomputations, not FPS.
- `slice2-performance-full-native-v1.xcresult`: **1,999 passed, zero failed,
  7 intentional opt-in skips**, original unrestricted HermesMobile suite. Signed
  Debug build, owned Simulator, parallel testing NO, jobs2, diagnostics never,
  default allowance60. Production sources unchanged after this suite.
- Real TUI created durable `20260905_122641_f43016` with exact
  `SEMREH_TUI_CROSS_CLIENT_1` / `SEMREH_SLICE1_ACK` pair. Production UI v3
  used actual app URL opening and asserted both rows visible/hittable: **1 passed**.
  Root inspected `slice2-cross-client-production-ui-v3-attachments/6BF97A8F-C566-420C-B9BD-736086EA1CB5.png`.
  Manual `slice2-tui-created-opened-in-semreh-v1.png` shows only an iOS open
  confirmation and does not establish this gate.
- Production UI v2: **1 passed**, actual normal new-chat/send. Before/after REST
  found exactly one new durable session `20260905_132840_b23b51`, exact
  `SEMREH_SLICE1_PROMPT` / `SEMREH_SLICE1_ACK` pair. Guarded actual TUI
  `scripts/direct_hermes_tui.py --backend-sha 8c50f84522a755d40346e73701a6847fbdde20ec
  --resume-stored-id 20260905_132840_b23b51` rendered that pair twice; normal
  `/exit`, code0. Capture `slice2-semreh-created-opened-in-tui-v1.txt`.
  This is bidirectional literal TUI/native-app evidence, not Hermes Desktop or
  shared-live-gateway proof: TUI owns a stdio gateway sharing disposable state.
- Cross-client production UI v1 failed a harness assumption: persisted auth had
  expired and the app legitimately displayed Connect with session-expiry message.
  Harness now accepts this state before normal login; no production auth changes.
  v2/v3 logs, result bundles, attachments and v3 exported diagnostics retained.
  Generate live plan with `direct_hermes_ios_smoke.py --https --slice2-ui
  --tui-created-session-id 20260905_122641_f43016 --development-backend-sha
  8c50f84522a755d40346e73701a6847fbdde20ec`, then owned Simulator
  test-without-building, diagnostics never, allowance180, fresh evidence paths.
- Root reviewed/corrected Luna's queued-steer probe, then ran
  `PYTHONPATH=scripts python -m unittest scripts.test_direct_hermes_steer_probe
  scripts.test_direct_hermes_identity_probe -v`: **9 passed**. Live
  `scripts/direct_hermes_steer_probe.py --backend-sha 8c50f84522a755d40346e73701a6847fbdde20ec
  --output <evidence>/slice2-steer-live-v1.json` passed exact three pairs,
  warmup, normal original/followup terminals, queued correction persisted once,
  no cleanup errors and unchanged fixture config. Durable `20260905_133411_6f477a`.
  Pinned session.steer wire returns queued/rejected; accepted is compatibility
  enum coverage, not a claimed live wire status. No tool-batch/redirect proof.
- Artifact audit `slice2-performance-cross-client-final-audit-v1.log`: 99,524
  files scanned, zero flagged paths. Known fixture secrets/obvious bearer formats
  only; private quarantine and runtime credentials/config/DB remain excluded and
  are not claimed sanitized. No personal state or routes changed.
- Slice 2 remains open: actual rotated compression/continuation, broader
  performance edges, independent clean-checkout rerun and physical iPhone gate.

### Follow-up experiments after 06e7e64 (not slice acceptance)

- Source review identified a latest-message visibility limitation when trailing
  live/tool/clarification content follows the message, plus direct-drag versus
  completion precedence. A sentinel-only settlement candidate with cancel-first
  handling compiled, but `slice2-bottom-sentinel-ui-v1` and same-build `v2` each
  failed multi-chat appended-marker visibility at chat2; static test passed.
  Root inspected the failure video frame: old code rows and arrow remained,
  not the new marker. Candidate rejected and all three native files restored to
  06e7e64. Patch retained as `slice2-bottom-sentinel-rejected-v1.patch`; failed
  bundles/logs/attachments retained. Trailing content and follow races remain open.
  A checkpoint UI recheck is recorded separately when it finishes.
- In-place and rotating compression fixtures use explicit modes in the existing
  guarded launcher, separate sibling homes/DBs and port18793. Both pin compression
  auxiliary requests to the same deterministic localhost18792 model and preserve
  baseline auth/tools restrictions. Empty auxiliary fallback_chain does not disable
  the main-model safety fallback; that route is also exact-guarded localhost.
  Ordinary runtime/hostname/routes remain unchanged. No personal provider used.
- Root independently ran3 launcher tests and8 compression-probe tests:11 passed.
  In-place live-v1/v2 both failed the actual-reduction gate with cleanup[] and
  unchanged config. V2 records status=compressed but removed0,24→24 rows,
  14462→14462 tokens, summary.refused_would_grow=true. Neither is a compression pass.
  Source audit found lean summary preserves up to24000 user characters, making
  a bulky-user/tiny-assistant corpus unsuitable. The bounded replacement corpus
  uses short unique user markers and bulky synthetic assistant responses; auxiliary
  summaries remain short. No compressor behavior/assertion is being weakened.

### September 5 compression results and approval boundary

- Root reviewed the marker-only streaming model extension and independently ran
  16 pure tests:5 model,8 probe,3 fixture guard; all passed. Exactly12 short user
  markers receive distinct4096-byte assistant bodies. Nonstreaming auxiliary
  summaries and ordinary/reasoning prompts retain their original response path.
  Root verified and restarted only owned model PID13767; replacement PID27017,
  same localhost18792, same --reasoning-probe command. No personal service touched.
- In-place live-v3 performed actual compression:24→22 rows,14510→14187 tokens,
  non-aborted/no fallback. However chronological original-history assertion FAILED.
  Sanitized REST inspection of `20260905_140051_27ad0c` confirmed older archived
  assistant01(id52) and user02(id53) precede recopied protected user00(id73),
  assistant00(id74), user01(id75). Original rows remain present but misordered.
  Cleanup[] and unchanged config. Evidence `slice2-compression-inplace-live-v3.json`.
- Root and independent Sol review confirmed a backend bug in baseline29112bef
  and dev8c50f845: `hermes_state.py` include_compacted deduplication selects the
  desired active/newest copy, then sorts by that copy's new physical row ID.
  This relocates copied protected head rows behind archived middle rows.
  Minimal proposed fix: retain preferred representative but sort each dedupe
  group by its earliest original physical row ID, then page as before. Add
  first/second-generation chronology, preferred-live-row and latest-page tests.
  This general backend paging change is outside the specifically approved
  reasoning patch. Await Maurice's explicit approval; neither backend edited.
- Rotation live-v1 PASSED:24→22 rows,14501→14183 tokens; ancestor
  `20260905_140244_5f4794`→tip `20260905_140246_b7cd5a`; exact metadata links,
  ancestor/child canonical pages agree, distinct cold runtime IDs, continuation
  exact user/ACK pair once and persisted after second cold resume, latest pages
  reconstruct child history. Cleanup[]/config unchanged. Child-only history is
  explicitly NOT claimed to reconstruct full parent originals. Evidence
  `slice2-compression-rotation-live-v1.json`. Reproduce with
  `scripts/direct_hermes_compression_probe.py --mode rotate --backend-sha
  8c50f84522a755d40346e73701a6847fbdde20ec --output <fresh evidence path>` after
  guarded mode init/serve. Loopback proof, not a new HTTPS/device gate.
- Both temporary compression backend processes stopped normally via verified
  owned PIDs18504/28078. Sibling data/logs retained. Original backend52223 and
  HTTPS13817 unchanged; model replacement27017 remains running.
- `slice2-performance-checkpoint-recheck-v1` rebuilt original06e7e64 native code:
  multi-chat arrow-return visibility failed25s; static passed. Thus the earlier
  v15/v16 passes are retained but do NOT establish repeatable long-chat reliability.
  Sentinel candidate was rejected; failure is not solely attributable to it.
  Independent review identified inherited deceleration/cooldown ownership and
  stale visibility booleans as source-backed risks needing isolated regression
  tests. No new native fix accepted. UI artifacts/diagnostics retained. Signed
  original app launched normally on owned Simulator after testing.
- Final audit `slice2-compression-final-audit-v1.log`:100077files,zero flags,
  42exported console logs, including both compression sibling log directories.
  Known-secret/bearer scan only; private quarantine/config/credentials/DB excluded.
  Local checkpoint remains06e7e64; new fixture tooling and this ledger remain
  uncommitted pending the backend decision and unresolved live/UI gates.

### Stock-release realignment checkpoint — September 5

- Local fixture checkpoint4d040a3; combined pure fixture/launcher tests25passed.
  Final known-secret audit `slice2-stock-final-audit-v1.log`:104717files,0flags,
  45exported test consoles. This includes current stock runtime logs and new
  native result exports; private exclusions and heuristic limits still apply.
- Signed full native `slice2-stock-full-native-v1.xcresult`:2014passed,
  0failed,7intentional opt-in skips (2021total). This rebuilt the explicit stock
  native reasoning gate. Source remains checkpoint06e7e64 plus scoped dirty diff
  until the local checkpoint commit; no slice-completion claim.
- Long-chat UI `slice2-stock-long-chat-ui-v1.xcresult` and same-build v2 each
  PASS2/0fail/0skip. Signed HermesMobileUIVerification, same owned Simulator,
  `-collect-test-diagnostics never`; filters select static10k and three-chat10k
  append/away/arrow/revisit tests. v2 uses test-without-building. Attachments
  exported under corresponding `*-attachments` directories. Root inspected
  v1/E1EB563C-260F-49EF-9CEA-EE69A6B59685.png: third chat's streamed marker visible
  after arrow return. Server-free fixtures, not real long network history/FPS or
  physical-device proof. Historical failed runs remain in the ledger.
- Stock native reasoning `slice2-stock-native-reasoning-v1.xcresult` PASS1/0skip.
  Generated plan with `direct_hermes_ios_smoke.py --https --slice2-reasoning
  --stock-backend`, then signed test-without-building using SemrehSlice1Live
  xctestrun, owned Simulator, parallel testingNO, diagnosticsnever. Unmodified
  baseline29112/PID85233, same HTTPS/deterministic model. Existing assertions
  retained: actual low request; selection while response running remains deferred;
  next actual request high; sibling medium; close/resume first remains high and
  next actual resumed request high. No global reasoning key present afterward.
  This exercises the named custom-provider fixture, not every provider-healing
  combination or the concurrent-close race accepted by Maurice.
- Smoke launcher invalid-mode subprocess tests: root3passed. New native focused,
  full and live reasoning console diagnostics exported for artifact audit. Signed
  ordinary app launched with no lab arguments, PID98005. No Simulator gate equals
  physical iPhone acceptance; compressed-history chronology blocker still open.
- Signed focused native run `slice2-stock-native-focused-v1.xcresult` PASS:
  113 tests,0failures,0skips. Classes ChatScrollPolicyTests,
  GatewayConversationControllerTests,ChatViewModelDirectGatewayTests. Command:
  canonical signed `xcodebuild test` above, explicit owned Simulator/DerivedData,
  `-collect-test-diagnostics never`, jobs2, parallel testingNO, three only-testing
  filters. Exact dirty source snapshot `slice2-stock-native-focused-v1.patch`.
  Root independently ran and inspected xcresult summary. Authored new regressions
  were NOT run red against the original checkpoint; no red/green claim.
- Review corrected initial cooldown-only scroll patch, stock unknown-contract
  fallback, original-snapshot checking after readback and ambiguous-write retry
  state before this pass. An independent claimed duplicate-drain counter leak
  was retracted after root requested an actual interleaving; no speculative
  deduplication layer added. UI reliability still requires repeated live tests.
- Subsequent continuation: root independently switched only the disposable
  listener from dev PID52223 to stock PID85233. Verified old cwd/listener, TERM,
  exit/free port, then used `direct_hermes_probe.py serve`; new cwd is the baseline
  runtime tools directory and independent source is clean29112bef. HTTPS13817 and
  model27017 unchanged. This is external process attestation for the probe below.
- Root reran revised stock probe pure tests:6passed. Independent worker/root
  review corrected early terminal-event loss, bounded receive deadlines, exact
  assistant ACK and failed-cleanup evidence before live use.
- `SEMREH_SLICE1_HTTPS=1 .../semreh-slice1-venv/bin/python
  scripts/direct_hermes_stock_compatibility.py --backend-sha
  29112bef099274229cadff79cdff7bf7b99c4b77 --output
  .../semreh-slice1-evidence/slice2-stock-compatibility-v1.json`: PASS. Ready,
  fresh runtime/durable identity, stock reasoning read, normal deterministic turn,
  idle, canonical exact durable pair, cleanup[],configuration unchanged. This is
  real HTTPS stock protocol evidence, NOT native UI or reasoning-write proof.
- Pre-native known-secret audit:100083files,0flags,42previous exported consoles;
  `slice2-stock-pre-native-audit-v1.log`. Private credential/config/DB and prior
  quarantined OS diagnostics remain excluded and unshareable.
- Binding plan now explicitly supersedes the private reasoning extension as a
  release dependency and records the approved five-worker ceiling. No backend
  adoption, deployment, push or PR publication occurred.
- Root independently reran pure fixture checks from app HEAD06e7e648 plus the
  existing dirty script scope, using `semreh-slice1-venv/bin/python -m unittest
  discover -s scripts -p 'test_direct_hermes_compression*.py' -v` (11 passed) and
  the same command with `test_direct_hermes_model_fixture.py` (5 passed).
  These prove helper behavior, not live compression, stock compatibility or UI.
- Stock reasoning audit independently source-checked by root: baseline
  `config.set reasoning` falls back to global when its runtime is missing;
  stock `config.get`/ACK lack our experimental capability fields. Compatibility
  changes await the user's residual-risk decision; no guards removed. The audit
  found normal attached-session eviction protected, but concurrent close/teardown
  can still race a status preflight. No runtime reproduction claimed here.
- Long-chat correction and thinking-card audit are in progress. Earlier failed
  UI runs remain acceptance failures, not superseded by these pure helper passes.
