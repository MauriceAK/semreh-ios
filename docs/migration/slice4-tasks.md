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
