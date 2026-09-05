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
