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

## Current bounded decisions — September 6

- Continue without routine owner check-ins; record choices here. Hard blockers,
  personal-state access, publication and physical acceptance still require the owner.
- Synthetic approval and secret-cancellation fixture expansion is approved in the
  binding plan. Root reviews exact plugin contents before deployment; stock source
  stays unchanged. Sudo execution and real secret entry are not fixture scope.
- Use explicit cancel-only native secret/sudo presentation for this migration
  checkpoint, as allowed by appendix G.2/G.3. Do not add a secret-entry/storage
  subsystem. Native sudo cancellation can have unit/contract coverage without
  claiming a live sudo-tool test. Any remaining live gate must stay visible.
- Reuse approval presentation, restrict buttons to stock-advertised choices and
  never send bulk approval. Require positive `resolved` acknowledgment; the stock
  fallback behavior makes captured request/session/generation checks essential.
- Resume may restore approval/clarification from its authoritative payload;
  it does not restore secret/sudo. Do not recreate sensitive cards from cache.
- Known-stage attachment removal uses only exact acknowledged `image.detach`
  paths. Partial/uncertain cleanup stays quarantined; generic files do not gain an
  invented detach endpoint. This improves composer behavior, not host-file deletion.
- Fixture deployment uses the stock user-plugin location and exact `plugins.enabled`
  allowlist, retaining bundled authentication. The fixed secret fixture uses the
  ordinary skill lookup because namespaced plugin skills bypass stock secret
  capture. Disable tool-search deferral only in this deterministic fixture so
  its two already-authorized synthetic tool schemas are directly advertised;
  do not broaden toolsets or alter app/backend production behavior.
- September7: pinned approval response with no matching pending request returns
  `resolved: 0`, not an expiry RPC code. Keep the card/error rather than inventing
  success or expiry. Sensitive explicit `status: expired` remains supported.
- Next recovery check uses controller/runtime recreation and exact canonical
  history to prove a run completed while its client owner was absent. This is
  useful native recovery evidence, but does not replace literal app-kill or phone
  background gates. No production test hook or new backend tool is needed.

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
  - [x] **R1b — Completed-away native connection recovery.** Stock HTTPS smoke
    completed-away-live-v1 passed1/0/0: accepted delayed turn, disposed controller,
    stopped original socket, waited for durable completion, connected fresh runtime
    and reopened same stored session. Exact baseline prefix, exact-once turn and
    idle recovered transcript verified. Not literal app kill, host restart or phone.
- [ ] **S3-R2 — Mobile/host lifecycle and orphan policy.** App background, kill,
  host restart and connectivity loss. Select finite grace from evidence; no silent
  personal-host configuration change. If zero is proposed, demonstrate cleanup
  and caps first. Record required short/long phone intervals before acceptance.
- [ ] **S3-B — Blocking interaction.** Approval, clarification, sudo/secret and
  expiry. Key requests by server/session/generation/request; explicit deterministic
  cancellation if full UI unsupported. No sensitive response in persistence/logs.
  Shared event/controller changes coordinated with R1, not overlapping writers.
  - [x] **B1 — Freeze request identity/resume contracts.** Existing clarification
    capture plus approval-secret-contract-v6 passed on stock HTTPS. Approval events
    contain request IDs; pending registry matches, and resume restores the same
    request with choices. Deny resolves exactly one request; empty secret response
    returns ok and the run completes. Sudo remains source/unit-only until a bounded
    live path is authorized; no sudo tool execution is implied by this checkpoint.
  - [ ] **B2 — Typed direct request lifecycle and responses.** One owner for
    controller/events/VM. Cover answer, cancel, expiry and stale generation/session
    rejection; do not reuse legacy HTTP pending-action endpoints.
    - [x] **B2a — Single-clarification controller foundation.** Exact captured
      identity, answer/empty cancel, stale response and replacement guards,
      single-flight responses, expiry and resume reconstruction. Root focused
      64pass and full2047pass/7intentional skips. Not yet connected to native UI;
      approval/sudo/secret and unsupported clarification cancellation remain open.
    - [x] **B2b — Native clarification checkpoint.** Single answer/explicit empty
      cancel plus cancel-only batch/multi-select, transient captured identity,
      stale/duplicate/expiry guards and visible error handling. Signed production
      navigation through the stock HTTPS fixture passed all four flows in UIv3;
      full nativev2 passed2067/0fail/7intentional skips. Root inspected screenshots
      and corrected small-phone keyboard clipping. Approval/sudo/secret, mobile
      recovery and physical blocking acceptance remain open; this does not close B.
    - [x] **B2c — Native approval/sensitive cancellation checkpoint.** Identity-scoped
      queues, exact advertised approval choice, positive resolution only, secret/
      sudo explicit-empty responses, scoped expiry/errors and no legacy writes.
      Production UIv3 passed approval denial and secret cancellation/terminalACK;
      full blocking-recovery-v1 passed2172/0fail/9opt-in skips. Sudo remains
      source/unit-only; mobile, multi-client and physical gates remain open.
  - [ ] **B3 — Native transient prompt UI.** Secure input stays memory-only;
    reconstruct outstanding requests after resume, clear only matching expiry,
    and prove no secret persistence or diagnostic exposure.
- [ ] **S3-A — Attachment staging.** Capture image/text-code/PDF stock contracts,
  limits, references and failure behavior before implementation. Stage bytes before
  prompt; failure preserves draft and prevents submit. No host use of phone paths.
  - [ ] **A3 — Restart-safe unresolved staging (approved, implementing).** Stock live
    resume retains queued images but does not report them. Memory-only pending
    state can disappear on app kill/eviction, allowing the next ordinary prompt
    to consume an unknown staged image. Known receipts need exact-path detach;
    unknown receipts require durable per-session quarantine and an explicit
    resolution policy. Maurice approved metadata-only persistence and explicit
    confirmed per-chat runtime reset preserving saved history. The live stock
    `--verify-reset` probe passes (reset-contract-v2); native controller/store
    recreation and reset integration also passed (native-recovery-live-v1).
    Literal app-kill and physical restart acceptance remain unverified. No personal
    gateway resets, fabricated paths, automatic retries, or safety waiver.
    - [x] **A3a — Persistent marker/reset implementation checkpoint.** Runtime-keyed
      metadata, hot-reopen quarantine, terminal+idle exact-path cleanup, explicit
      reset with lost-ACK/corrupt-marker handling. Focused100/full2144 passed;
      native normal image flow passed with no stuck banner. Live native-controller
      reset passed with exact saved rows retained and no image in subsequent text.
      Literal app-kill/physical acceptance are still separate open checks.
    - [x] **A3b — Known-stage removal checkpoint.** Fresh idle proof and exact
      image/PDF receipt detach; uncertainty keeps the chip/quarantine. Generic-file
      receipts remove locally, with no invented endpoint. Focused99/full2160 passed;
      native live removal preserved exact saved history, cleared the marker, and
      subsequent plain text had no media. Physical/removal-button UI remains open.
  - [ ] **A1 — Capture stock staging/limits and PDF availability.** Record
    returned references, image/PDF/file failure responses and canonical history.
  - [ ] **A2 — Retain local bytes and stage before prompt.** Attachment owner
    prepares bytes/metadata; shared controller writer integrates ordered staging,
    returned file references and failure-without-submit/draft preservation.
    - [x] **A2a — Local byte preparation foundation.** Retained in-memory bytes,
      bounded off-main base64 and exact image/file/PDF RPC parameter shapes;
      local validation and cancellation tests pass in focused/full runs above.
      Not yet wired into picker/send staging. Live image/file contract passed;
      PDF success subsequently passed attachment-contract-v3 after the approved
      Poppler install; this does not establish native picker/send integration.
    - [x] **A2b — Pending/display/receipt foundations.** Memory-only bytes and
      origin/binding/generation-scoped stage state, metadata-only composer display,
      exact stock image/file/PDF receipt parsing. Full nativev2 above passes.
      Picker/send/partial-failure integration is still open. Unexpected PDF errors
      may follow partial page queueing; do not treat every RPC error as unstaged.
    - [x] **A2c — Native stage/send checkpoint (not attachment gate).** Sequential
      stage/confirm, exact file references, PDF timeout and final dispatch scope
      guards; root135focused tests passed. Signed production Paste/preview/send
      UIv2 passed and exact turn/image reference found in canonical REST. Photos/
      Files/PDF picker flows, known-stage removal, late-ACK safety correction,
      transcript media rendering, final fullsuite and device checks remain open.
- [ ] **S3-M — Authenticated media.** Same-origin cookie auth, external credential
  isolation, Range, resource-scoped caching. No tickets in media URLs. Coordinate
  attachment metadata boundary with A; avoid generic speculative DTOs.
  - [x] **M1 — Stock image response decoding (API checkpoint).** Interaction worker owns
    APIClient+Workspace and narrow helper/tests. Decode stock JSON `data_url`,
    preserve legacy raw bytes, bound encoded/decoded sizes and reject malformed
    images. Existing auth mapping unchanged. Root review, focused/full tests and
    live stock HTTPS contract probe passed; native rendered UX, streaming, cache
    isolation and real device media acceptance remain separate gates.
  - [x] **M2 — Direct managed-file preview checkpoint.** Existing native preview
    surfaces now use the explicit authenticated stock file-read route for supported
    absolute resources, without legacy fallback. Text/Markdown display capped256KiB;
    uploads unchanged. Focused/full tests pass; actual native image preview passed.
    Native generic-file/PDF picker/preview and physical checks remain open.
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
