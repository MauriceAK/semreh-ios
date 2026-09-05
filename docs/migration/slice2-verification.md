# Slice 2 verification — in progress

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
