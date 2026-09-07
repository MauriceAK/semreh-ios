# Slice 4 task outline

Status: bounded S4-S search/detail integration verified; metadata and archive
consumer integration underway. Other packages remain
open. Refine remaining owners/file boundaries as Slice3 interfaces stabilize.
The [execution plan](semreh_tui_gateway_v3_execution_plan.md) remains binding.
This outline supports later parallelism; it is not permission to publish a release.

- [ ] **S4-D — Destructive history.** Verified durable row targeting for edit,
  regenerate/truncation; stale identity/external mutation must leave history intact.
- [ ] **S4-L — Lineage actions.** Branch/compress preserve canonical IDs and lineage.
- [ ] **S4-F — Feature disposition inventory.** Every secondary feature explicitly
  migrated, removed or deferred-and-hidden. Identify choices needing owner input;
  no visible action may silently call WebUI.
- [ ] **S4-S — Session conveniences.** Search/rename/pin/archive/delete only through
  verified first-party contracts; coordinate destructive behavior with D.
- [ ] **S4-C — WebUI removal.** Remove legacy chat/SSE/status/auth, old prompt paths,
  sidecar and obsolete fixtures/dependencies after replacements pass. No broad
  deletion before searching consumers and validating retained behavior.
- [ ] **S4-V — Independent cutover verification.** WebUI absent, every visible
  network action audited, no fallback, blocking prompt handling retained, full
  native/direct-backend tests and physical product acceptance.
- [ ] **S4-P — Release-readiness performance review.** Revisit explicitly accepted
  limits in `performance-followups.md`; keep correctness distinct from visual polish.

### Current S4-S integration checklist

- [x] Verify direct search/list and exact linked-detail consumers (checkpoint35d20c3).
- [x] Capture stock metadata PATCH and authoritative detail contracts.
- [x] Capture official single-profile `/api/sessions` filters/offset envelope:
  `slice4-single-profile-list-live-v1.json`, six reads, auth cleanup passed.
- [x] Finish metadata consumers and independent refresh/profile race review.
- [x] Switch archives to the verified single-profile paging route; the aggregate
  route caps source rows at500 and cannot support complete large archives.
- [x] Run focused native mutation/archive tests and actual-VM stock live smoke.
- [x] Run integration suite and signed app launch before committing the cohort.
- [ ] Finish full-scale search and separately scoped safe deletion.

Archive-count follow-up:

- [x] Use the explicit single-profile archive-only `limit=0` response's `total`,
  never its row count (pinned rows may still be returned).
- [x] Publish visible sessions before count completion; preserve a prior valid
  same-profile count on transient failure. Missing/negative totals fail safely.
- [x] Clear counts on profile changes and independently invalidate older count
  requests. Confirmed archive and successful unarchive explicitly refresh the count.
- [x] Verify actual native view-model count transitions against stock Hermes.

Evidence: `slice4-archive-count-live-v1.json` passed all nine single-profile
filter/offset/count captures; `slice4-count-native-live-v1` passed 1/0/0 and proves
baseline → baseline+1 after archive → baseline after unarchive, plus unchanged
sibling/transcript and owned-fixture restoration/cleanup. Full native
`slice4-count-full-v1` passed 2,246/0/13 intentional opt-in skips. Strict signing
verification and ordinary Simulator launch 43963 passed. Python count probe
checks passed 9/9. No physical acceptance is implied.

Failures retained: count-focused-v1 failed compilation on a shadowed test callback
assignment, corrected by root; v2 ran 104 passing and three failing older fixtures
that had omitted the count route or counted it as a visible-list refresh. Fixtures
were corrected explicitly, preserving coalescing and overlap assertions, before
the full-suite pass. Root also wired the post-archive refresh omitted from the
worker handoff; independent review and the live transition test cover it.
Count artifact audit passed with zero flagged paths; see
`slice4-count-audit-v1.jsonl` for the exact file and exported-console counts. Its
scope remains known fixture secrets and obvious bearer formats, not opaque-secret
proof, screenshot OCR, or quarantined OS diagnostics.

First cohort native attempt `slice4-metadata-focused-v1` failed compilation on six
missing `try` expressions in the new opt-in live test; no tests ran. The owner
corrected them; a subsequent native result is still required. Python smoke
selector35/35 and session probe8/8 passed. The live list fixture has82 unarchived
rows and no archives: it proves route/schema/filter handling, not >500 live scale.

Successor metadata cohort: focused-v5 passed87/0/0; native-live-v1 passed1/0/0
against stock29112bef. Actual SessionList/Archived view models perform rename,
pin, archive and unarchive; separate exact detail checks, sibling metadata and
canonical transcript equality pass. Original metadata restoration and owned runtime
close/auth cleanup pass. This is native VM evidence, not literal UI or device
acceptance. Archive501-row/six-page and pinned-backfill coverage is mocked.

Reasonable sync decision (root + independent Sol review): stock REST writes and
reads the selected SQLite DB synchronously; no eventual response cache is proven.
Protect only list requests begun before local confirmation using per-field
confirmation revisions. Fresh post-confirmation reads are authoritative, including
conflicting Desktop/TUI edits. Never retain indefinite exact-match overlays that
could mask external changes. Profile/session keys and actual profile-change epoch
guard metadata mutations. Async-held response tests prove overlap and subsequent
conflicting title/pin truth; archive test proves subsequent external rearchive.
Residual coverage: profile-epoch test gates use timeout semaphores, and reused-ID
cross-profile pending isolation lacks a direct dedicated regression; code reviewed.

Attempt history retained: focused-v2 built and ran80pass/6fail (legacy sanitized
error expectations, request count including detail GET, fixture interpolation/cwd,
archive semaphore deadlock). Corrected fixtures and genuine asynchronous response
gates. v3 invocation failed on root's misspelled DerivedData flag before build;
v4 compile failed on duplicate test-local `session`, corrected by root; v5 passed.
No failures are labeled unexplained infrastructure. Full integration
`slice4-metadata-full-v1` passed2237/0/13 intentional opt-in skips (root inspected
all skip reasons); metadata opt-in ran separately and passed. Strict signed-app
verification and ordinary Simulator launch29179 passed. Root exported failed-v2,
focused-v5, native-live-v1 and full-v1 diagnostics for the artifact audit. No phone
install, personal-state change or publication. Archive count/search/deletion and
other S4 packages remain open; this is a bounded cohort, not slice acceptance.
Artifact audit `slice4-metadata-audit-v1.jsonl`:242758 files,0 flagged paths,
145 exported consoles. Scope is known disposable secrets/obvious bearer formats;
not arbitrary opaque secrets, screenshot OCR or quarantined OS diagnostics.

Potential parallel lanes: feature inventory, independent screen implementations,
contract tests and deletion audit. Shared chat/history/runtime files stay single-owner.

## Preparatory source inventory — September7

Read-only Luna inventory, root checked transport boundary at stock pin29112bef.
`hermes serve` mounts official REST and `/api/ws` (delegating to tui_gateway.ws);
headless mode disables the SPA, not those APIs (web_server.py17618,17834,19553).
Using verified official REST is already part of the binding architecture and is
not a legacy WebUI fallback. Bare stdio gateway lacks REST, but is not our mobile
deployment target. Do not conflate filenames under web_server/web_routers with a
browser-UI dependency, or assume a route shape without a live capture.

- RPC candidates: profiles, projects, cron.manage, skills.manage/reload,
  model.options/config, insights.get, session.cwd.set/workspace.move.
- Official headless REST candidates: session content search, Git, memory, plus
  profile/cron/skill/admin endpoints. Exact app-to-stock shape mapping and safe
  live contract checks remain unexecuted; preserve features where supported.
- Workspace collection list/suggestion/add/remove/rename/reorder has no exact
  scoped stock match yet. Inventory alternatives before proposing disposition.
- Legacy retirement consumers: APIClient+Chat, SSEClient, OfficialHermesContinuity,
  ChatStreamCoordinator, ChatPendingActionCoordinator and legacy ChatViewModel
  branches; first prove all production constructors use the direct runtime.
- History edit/regenerate/fork remain disabled in direct mode pending exact
  row-ID/lineage contracts. No silent feature removal authorized by this inventory.

## Session-convenience preparation — September7

Luna read-only mapping; root checked stock PATCH/DELETE/search source. No live
contract capture or S4 implementation pass yet.

- Direct list currently uses official `/api/profiles/sessions`, but archive filter/
  count plumbing remains incomplete. Stock `archived=exclude|only|include` is not
  legacy `include_archived=1`.
- Search stock returns `results`; existing SessionSearchResponse expects `sessions`.
  Adapt explicitly, retaining local search; do not assume legacy content/depth flags.
- Rename/pin/archive currently use legacy mutation consumers. Stock profile-aware
  PATCH `/api/sessions/{id}` accepts title/pinned/archived and returns ok/readback.
- Stock DELETE `/api/sessions/{id}` is idempotent for absent rows, but source alone
  does not prove safe active-run deletion: it mutates DB without stopping a live
  runtime. Coordinate active behavior/full durable IDs with S4-D before integration;
  do not blindly substitute this route for every legacy delete case.
- Potential disjoint packages after S3 contracts stabilize: direct typed adapters/
  focused contract tests; session-list optimistic mutation integration; archived
  collection/count integration; remote search shape/match integration. Preserve
  tombstone/rollback semantics, server/profile/session scoping and visible features.

## Read-only contract probe preparation — September7

Root+Luna are preparing exact disposable GET captures before adapters. No S4
production change yet. Source profiles.py347-355 deliberately backfills pinned
rows beyond `limit`; even `limit=0` can include pinned rows. Do not assume a
zero-row count endpoint, enforce an invalid row_count<=limit invariant, or claim
strict response bounding from the requested limit alone. Root corrected that
preliminary assertion suggestion before live execution. Search remains separately
limited; verify actual stock envelopes and positive/empty archive cases distinctly.

Root read-only live-v1 passed against stock HTTPS/default: exclude/include20rows,
total78; archive-only0rows/total0; each limit0 request returned0rows in this
unpinned fixture. Search returned1synthetic user-content match under `results`.
Cleanup passed; evidence records only exact request shapes/schema/counts. Root
Python7/7 passed. Positive archived rows and actual pinned overfetch are not live
verified by this empty/unpinned fixture. Luna now owns direct API adapters/tests
only; no session UI, mutation or legacy retirement is accepted from this capture.

Successor: direct search/list adapters and SessionList search integration authored
by Luna, root reviewed. Explicit profile/query/generation guards; server search
results map only to known visible unarchived IDs, preserving local project filter
and tombstones. No unsupported legacy content/depth query flags. Native full-v4
passed2205/0/12opt-in skips, including these tests. Earlier new search fixture
failures corrected title/message_count, not product visibility. No rename/pin/
archive mutation or archive screen/count cutover is claimed by this checkpoint.

## Bounded metadata mutation capture — September7

Root reviewed Luna's new session_mutation_probe; corrected a final sibling-map
argument error before execution and required whole-flow fake coverage, unique
per-run titles, and guarded metadata restoration on failure. Python-v1:6pass/
1mock-protocol error; corrected fake connect. Exact fixture Python-v2:7/0.
Live-v1 passed on clean pin29112bef/unchanged HTTPS fixture: created two own idle
synthetic chats, title/pin/archive/unarchive PATCH plus independent list readback,
sibling metadata unchanged, positive archive-only count1, exclude omits archived
target, original metadata restored, own runtimes closed and auth cleanup passed.
No DB deletion, personal state, active-run policy or app mutation UI claim.
Next Luna owns only new typed direct mutation adapter/test files; root registers
and verifies before consumer cutover. Preserve optimistic rollback and explicit
profile/full durable target; DELETE/edit/regenerate remain separate.

Typed metadata adapter and tests are now implemented and registered; native
full-v8 passed2214/0/12, with the live mutation probe providing separate durable
readback evidence. No production rename/pin/archive consumer cutover yet.
Receipt identity echoes the requested full ID, not a server-resolved ID; callers
must supply canonical IDs. Boolean response echo alone is not durable readback.

## Secondary provider/model inventory — September7

Read-only Luna source audit: directProviders() is login-provider discovery at
/api/auth/providers, not inference-provider status. It cannot replace the visible
Providers screen's credential/status catalog; no exact /api/providers route exists
at the pin. Do not combine unrelated env/OAuth/custom-endpoint routes into an
invented status contract. Providers disposition remains open, not silently hidden.
Default Model picker can use existing directModelOptions(profile:) for reads,
but explicit_only policy and stock /api/model/set write need separate verification.
Legacy /api/models, /api/models/live and /api/default-model remain consumers to
replace; no live catalog or picker acceptance claim from this source audit.

## Linked-chat detail cutover — September7

Production uncertainty UI-v6 exposed legacy client.session on a linked ID absent
from list/cache. Replace that miss path with explicit stock detail; cache-first
opening stays, no auth-capability fallback or latest-descendant guess. Root's
session-detail-live-v1 GET capture passed on exact synthetic seed in default profile:
raw top-level row, integer pinned/archived, last_activity_at, exact id/profile and
four messages. Evidence contains field types only, not prompt/config values.
Luna owns adapter/consumer and focused tests; native acceptance pending.

Scale follow-up: current remote search admits only IDs in the loaded unarchived
profile page (up to500 requested rows). Hits outside that page can be omitted.
Do not describe this as complete unlimited search; use verified exact detail or
bounded paging to resolve such hits in a later S4-S package without cross-profile
or lineage guesses. This is not a reason to widen the current recovery fix.

## Legacy retirement ordering — September7

Read-only production audit confirms OpenChatSessionStore supplies the direct
runtime provider; core direct send/recovery bypass legacy SSE. However legacy
coordinators are still allocated, sidecar settings remain reachable, and secondary
actions still have old API consumers. They are not all dead code.
The binding plan already selects direct-only and removes the continuity sidecar;
no new decision to retain legacy servers is needed. Preserve account credentials
and saved chats during app-local configuration migration; never alter host services.

Order: prove release constructors/direct status isolation, finish visible feature
contracts and destructive/lineage replacements, retire sidecar settings/config,
then remove legacy chat/SSE/auth code and obsolete fixtures. Old APIClient
health/authStatus/login/logout have no production callers in this audit and are
early removal candidates after endpoint-test updates. Live Activity orphan
reconciler currently sits behind a ContentView no-op; replace/verify its direct
behavior before deleting its tests. Direct activity start/end remains active.
No removal or full cutover acceptance is claimed by this source-only audit.

Verified bounded checkpoint: direct search/list and exact linked-detail consumers,
typed metadata mutation adapter (not yet consumed by rename/pin/archive UI), stock
read-only/detail and owned mutation probes. Full native2223/0/12; productionUI-v7
proves a fresh uncached link opens against stock without the legacy detail fallback.
S4-S remains open for metadata consumers, archive/count, delete and full-scale
search; no broad WebUI removal or secondary-screen migration claimed yet.
