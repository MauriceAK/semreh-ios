# Slice 3 task sheet

Status: FIRST BOUNDED IMPLEMENTATIONS IN PROGRESS. Authorized September 6, 2026.
Integrator owns this sheet. [Execution plan](semreh_tui_gateway_v3_execution_plan.md)
and [reference appendix](semreh_tui_gateway_v3_reference_appendix.md) own scope;
this sheet does not invent contracts or mark unexecuted checks passed.

## Boundaries and sequencing

- Official stock pin remains29112bef099274229cadff79cdff7bf7b99c4b77. No private
  Hermes patch, personal service/route change, release upload or unrestricted tools.
- Slice2 residual functional phone checks remain in its task sheet. Owner accepted
  remaining jump/switch lag; deferred work is in `performance-followups.md`.
- One writer per production responsibility; root owns integration, shared notes,
  Simulator/DerivedData, disposable runtime and device. Worker handoff must state
  changed files, executed/authored tests, evidence and gaps.
- First freeze verified contract/task ownership, then parallelize independent
  implementations. Shared controller/view-model edits are serialized.
- No sequence replay implementation unless canonical-recovery matrix proves need.

## Work packages

- [x] **S3-0 — Contract and current-code gap inventory.** Two Luna High audits
  completed; root reconciled first implementation boundaries against runtime,
  store, app lifecycle and pinned media/attachment source. This is a source/code
  inventory, not a live-contract pass. Approval request identity, blocking resume,
  attachment roundtrip and mobile recovery still require their own evidence.
- [ ] **S3-R1 — Ambiguous-send and canonical recovery.** Before-write, after
  acceptance, text/tool, pre-terminal, completed-while-away cases. No automatic
  resend; no Retry until nonacceptance is proved. Preserve durable identity and
  interleaved conversations. Unit failures plus disposable stock/proxy evidence.
  - [x] **R1a — App foreground trigger (implementation/unit checkpoint).** Luna recovery
    worker owns ContentView/OpenChatSessionStore/HermesServerRuntime and matching
    tests. Reconnect through the single runtime even outside a visible chat;
    deduplicate concurrent triggers, invalidate old-server/logout work, preserve
    connectivity errors. No prompt resend, replay, orphan config or notification
    expansion. Root review, independent Luna review and signed tests passed;
    actual scene-phase delivery/mobile continuity remain S3-R2/V/P gates.
- [ ] **S3-R2 — Mobile/host lifecycle and orphan policy.** App background, kill,
  host restart and connectivity loss. Select finite grace from evidence; no silent
  personal-host configuration change. If zero is proposed, demonstrate cleanup
  and caps first. Record required short/long phone intervals before acceptance.
- [ ] **S3-B — Blocking interaction.** Approval, clarification, sudo/secret and
  expiry. Key requests by server/session/generation/request; explicit deterministic
  cancellation if full UI unsupported. No sensitive response in persistence/logs.
  Shared event/controller changes coordinated with R1, not overlapping writers.
  - [ ] **B1 — Freeze request identity/resume contracts.** Capture clarification
    with the existing bounded fixture. Resolve approval's missing event request ID
    from the stock pending registry before defining native response targeting.
    Terminal/sudo or expanded provider tests require scope reassessment first.
  - [ ] **B2 — Typed direct request lifecycle and responses.** One owner for
    controller/events/VM. Cover answer, cancel, expiry and stale generation/session
    rejection; do not reuse legacy HTTP pending-action endpoints.
  - [ ] **B3 — Native transient prompt UI.** Secure input stays memory-only;
    reconstruct outstanding requests after resume, clear only matching expiry,
    and prove no secret persistence or diagnostic exposure.
- [ ] **S3-A — Attachment staging.** Capture image/text-code/PDF stock contracts,
  limits, references and failure behavior before implementation. Stage bytes before
  prompt; failure preserves draft and prevents submit. No host use of phone paths.
  - [ ] **A1 — Capture stock staging/limits and PDF availability.** Record
    returned references, image/PDF/file failure responses and canonical history.
  - [ ] **A2 — Retain local bytes and stage before prompt.** Attachment owner
    prepares bytes/metadata; shared controller writer integrates ordered staging,
    returned file references and failure-without-submit/draft preservation.
- [ ] **S3-M — Authenticated media.** Same-origin cookie auth, external credential
  isolation, Range, resource-scoped caching. No tickets in media URLs. Coordinate
  attachment metadata boundary with A; avoid generic speculative DTOs.
  - [x] **M1 — Stock image response decoding (API checkpoint).** Interaction worker owns
    APIClient+Workspace and narrow helper/tests. Decode stock JSON `data_url`,
    preserve legacy raw bytes, bound encoded/decoded sizes and reject malformed
    images. Existing auth mapping unchanged. Root review, focused/full tests and
    live stock HTTPS contract probe passed; native rendered UX, streaming, cache
    isolation and real device media acceptance remain separate gates.
- [ ] **S3-V — Canonical recovery matrix and independent integration.** Real stock
  backend/proxy cases, exact durable row counts, session targeting, prompt expiry,
  artifacts audit and full XCTest. If canonical recovery cannot meet requirements,
  report evidence and scope bounded replay transaction before implementation.
- [ ] **S3-P — Physical acceptance.** Agreed background intervals, app kill/relaunch,
  completed-while-away reconciliation and ordinary attachment/blocking UX. Simulator
  does not close these checks. Root requests focused owner steps when build ready.

## Handoff

Report completed boxes, executed commands/results, accepted exceptions, unresolved
decisions and next device check. No percentage inferred from checkbox count.
