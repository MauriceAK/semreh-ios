# Slice 4 task outline

Status: NOT STARTED. Refine owners/file boundaries after Slice3 interfaces stabilize.
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
