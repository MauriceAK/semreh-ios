# Remaining migration work

September 7 checkpoint. Binding scope: `semreh_tui_gateway_v3_execution_plan.md`;
details/evidence: `slice3-tasks.md`, `slice3-verification.md`, `slice4-tasks.md`.
This is the current dispatch checklist, not a new architecture or acceptance waiver.
Preserve completed Luna work. Root owns integration, notes and native execution.

## Implementation batches

- [x] **Branch UI handoff:** signed production UI-v2 passed1/0/0; root inspected
  copied-child, independent-child-turn and unchanged-parent screenshots. Existing
  native controller live-v3 separately proves exact durable row identities.
  Check cold/warm parent, exact child ownership, no duplicate resume, parent
  unchanged, rejection cleanup; production `/branch` navigation smoke.
  First focused run:155pass/2fail. Mock durable ID fixed; successor run interrupted
  after no result for roughly5minutes (exit73), not accepted. Root also added
  adopted-child canonical rekey callback and regression assertion.
- [ ] **Lineage/compression:** complete supported compression and ancestor-to-tip
  recovery without losing delivery warnings. Astra Low worker scopes next cut.
  Check canonical IDs, scoped markers and conflict handling; real compression
  required before claiming continuation acceptance.
- [x] **Continuity-sidecar retirement:** remove callers, old auth/config hooks and
  implementation while retaining direct credentials/accounts. Astra Low owner.
  Check direct login/restore/logout and absence of executable sidecar fallback.
  Implementation/settings/auth hooks removed, compatibility regression added;
  integrated focused152/0/0 and successor full suites passed. Source search again
  finds no OfficialHermesContinuity/continuitySidecar implementation or callers.
  Old account metadata/keys preserved. Broader WebUI cutover remains separate.
- [ ] **Legacy chat/SSE retirement:** remove replaced chat/event/prompt branches,
  obsolete DTOs/tests/fixtures and unused package references after caller removal.
  Check direct send/recovery/blocking prompts, build, and repository caller search.
- [ ] **Older history during an active response:** implementation and deterministic
  native tests now pass; actual-device acceptance remains. Older-page application
  preserves the live response/tools/reasoning and seeks an exact boundary anchor
  across at most eight overlapping reads. Missing/unproven anchors leave history
  intact. Tests cover250new durable rows, stale terminal/turn/binding responses,
  historical tool visibility and canonical rollover. Idle rollover refreshes the
  canonical tail/rebinds; active rollover leaves live identity intact. This is a
  functional improvement, not proof of physical scrolling smoothness.
- [ ] **Secondary feature migration:** finish supported first-party consumers;
  Astra Low worker selects a disjoint supported feature first.
  Check exact stock request/response and visible behavior; do not invent routes.
  Skills list/toggle/SKILL.md and active-profile UI propagation authored. Linked
  files explicitly unavailable pending parity decision; no legacy detail request.
  Skills screen migration does not include chat skill-shortcut execution:
  executeSkillShortcutCommand/searchSkills still explicitly refuse direct mode.
  That pre-existing gap is a separate retained requirement, not accepted removal.
  Source-backed invocation contract is being mapped; literal slash text alone
  must not be called verified skill activation.
- [ ] **Session conveniences:** remaining duplicate/move/export and deletion
  disposition; search, rename, pin, archive and counts already have verified work.
  Check exact profile/identity, rollback and no ambiguous automatic retry.
- [ ] **Feature disposition inventory:** every remaining visible action migrated
  or explicitly approved for removal/deferral. Unsupported items listed below.

## Decisions / limitations that implementation workers must not silently resolve

- [ ] Memory parity: source audit found builtin MEMORY/USER supported through
  selected profile's returned home plus stock-defined memories paths and managed
  file APIs; SOUL has its dedicated contract. Implementing, not removal candidates.
  Effective project-context discovery remains open (current UI is read-only).
- [ ] Edit/regenerate release treatment: stock external-rewrite safety gap.
- [ ] Deletion treatment: stock active-writer concurrency limitation.
- [ ] Corrupt/unresolvable delivery-marker recovery UX; no silent/global reset.
- [ ] Generic text attachment ingestion limitation; staging is not model receipt.
- [ ] Mobile orphan grace / host deployment persistence and physical boundaries.

## Integration and acceptance

Latest integrated snapshot: `slice4-final-batch-full-v1` passed
2287tests/0fail/14intentional opt-in skips after signed `final-batch-build-v1`.
This covers journal removal, lineage ACK fixes, direct cancellation/reconnect,
manual compression mocks, scoped Live Activity idle recovery, profiles/cron reads,
external-run discovery and task-load freshness. Actual compression and physical
mobile acceptance remain unverified. The previous full run's lone legacy
foreground-discovery fixture was migrated to direct behavior assertions, not
silently deleted. Independent worker review checked the new discovery/freshness
assertions; root reran the full suite.
Production branch UI-v1 failed before branch execution because Apple's known
Save Password sheet obscured restored-chat navigation. Specific Not Now handling
now preserves navigation assertions; signed UI-build-v2 and UI-v2 passed.
Evidence: `slice4-branch-production-ui-v2.xcresult` and exported attachments in
the owned evidence root. Root viewed 7DBFE14B (copied history), 25A7693B (child
turn), BD9C35F3 (parent). This is Simulator production navigation, not physical
acceptance. Strict code signing and ordinary app launch64653 also passed.

Next bounded batch: cron pause/resume, startup-default profile writes, and server
speech synthesis. Reasonable migration decision: Listen uses stock Hermes's
configured voice; old AriaNeural was an internal hardcoded constant, not a user
picker. Preserve on-device fallback; remove the obsolete voice request argument
rather than silently ignoring it. No server configuration/provider activation.
`slice4-secondary-writes-build-v1` and `full-v1` passed2306/0/14intentional skips.
This snapshot includes exact scoped task pause/resume, authoritative list-derived
execution status (pausing a schedule does not interrupt its current run),
startup-default ACK/readback, and profile-scoped bounded speech audio decoding.
Mock/native fallback tests passed; actual audio provider activation remains out
of scope. Bounded live endpoint probes are being prepared, not yet executed.

Successor checkpoint: `slice4-paging-retirement-full-v1` passed2302/0/14.
Six legacy paging test methods were retired/migrated (including obsolete WebUI
offset/SSE-only expectations), two direct paging regressions added, and the
structural prepend/index performance assertion retained. This snapshot does not
cover the subsequent active-response paging implementation currently in review.

Live probes: `slice4-startup-default-live-v1.json` confirms one same-value default
POST plus unchanged active/current/config/file state; it does not prove a changed
default or restart/native-picker behavior. `slice4-cron-mutations-live-v1.json`
confirms exact scoped pause/resume receipts and readback on one future2099 job,
then exact owned deletion and empty inventory restoration, zero triggers and
cleanup errors. Python probe tests passed12/12 and7/7. Audit
`slice4-secondary-paging-audit-v1.jsonl`:286671files,0flags,170exported consoles;
known-secret/obviousbearer scope only, not opaque/OCR/quarantined diagnostics.

Active paging integration: `slice4-active-paging-build-v1` and `full-v1` passed
2311/0/14intentional skips, including the updated profile-create catalog reads.
Independent reviewer found/fixed moving-tail ordering, missing historical tool
groups and idle canonical rollover before native verification. Strict signing and
ordinary Simulator launch91834 passed. Audit-v1:291375files/0flags/171consoles,
same limited scope above. Subsequent transcription edits are not covered here.

Transcription successor: `slice4-transcription-build-v1` and `full-v1` passed
2314/0/14intentional skips. Explicit actual chat profile, JSON data URL/WAV or
MP4 MIME,25MiB pre-upload cap, stock ACK, native fallback and synchronous live-
profile check at draft insertion. Independent reviewer caught the deferred
SwiftUI-cancellation race; commit-time scope check and held-result regression
address it. Signed launch99715 passed. No microphone/device/provider execution
claim. Existing dormant voice-note upload/send paths remain separate legacy work.
Targeted transcription artifact audit passed:4766files/0flags/1exported console,
covering that build, suite and exported diagnostics plus migration docs/runtime
logs. Older evidence was not rescanned; opaque/OCR/unexported contents excluded.

Edit/regenerate contract re-audit confirms missing public atomic precondition:
internal DB rewind has expected-row/content guards, public undo wrappers do not
expose them; no registered session.rewind RPC. TUI retry is undo then resubmit,
not guarded row-addressed edit. Async user disposition requested; no waiver yet.
Skills read-only stock probe verified58rows and one SKILL.md; no skill mutations.
Combined build-and-test attempts twice produced no result and were interrupted;
separate build-for-testing then test-without-building produced the passing runs.
Root will use that sequence, retaining the incomplete attempts without attributing
them to a proven product or infrastructure cause.

- [ ] Cross-client saved messages appear promptly; distinguish actual TUI/Desktop
  observation from raw protocol smoke.
- [ ] Remaining recovery/attachment interruption boundaries (see Slice3 evidence).
- [ ] WebUI-absent cutover; every visible network action has a supported contract.
- [ ] Full XCTest/direct stock tests, signed app launch and independent review.
- [ ] Physical iPhone acceptance; performance issues in `performance-followups.md`.

## Cadence

Git/monitor/caller retirement batch: stock Git reads now scope via session profile,
returned workspace and worktree root; initial screen refresh uses one status
snapshot. Full review inventory is retained beyond200 files; unknown unstaged
metadata refuses an unprovable diff rather than stock's misleading all-add fallback.
Incomplete inventory and failed external refresh block quick commit; Git write
routes themselves remain legacy/unmigrated and this is not whole Git parity.
Session-list monitor no longer requests WebUI stream status. Ready observation
uses existing coalesced gateway invalidation; disconnected fallback is15s (was1s),
with cache/loading/edit/mutation/cancellation guards. Tests cover ready/no-fetch
and disconnect/direct refresh. Three remaining ChatVM startChat callers removed;
edit/regenerate/retry still refuse, and their required product disposition is open.
Signed build-v2 and full-v3 passed2368/0/14. Full-v2's sole new auth fixture failure
was corrected to pinned middleware's unauthenticated value, without broadening
expiry classification. Full-v1 runner option typo failed before testing. One
additional generic-401 negative test landed after build-v2; build-v3 and dedicated
SessionListMutation suite passed91/0/0, including that exact added test. Strict
signing and ordinary Simulator launch60977 passed. Targeted audit-v1 scanned
9925files/zero flags/three exported consoles, including failed test evidence;
unselected/opaque/unexported contents are excluded as usual.
No live Git, production Git UI, physical device, or whole-cutover acceptance claim.

Managed file transport live proof: `slice4-managed-files-live-v1.json` passed on
the pinned isolated HTTPS gateway: unique 65-byte Markdown multipart upload with
overwrite=false, exact byte readback, listing and receipt/identity-guarded cleanup.
Six local probe tests passed; targeted audit-v1 scanned58files/zero flags.
This does not establish memory-editor adoption, provider ingestion, or native UI.
Ambiguous upload receipts deliberately leave possible files untouched for review.

Latest native checkpoint: ordinary send fallback retirement, scoped cron mutations,
and main-model picker passed signed `slice4-send-cron-model-build-v4` and
`slice4-send-cron-model-full-v2`: 2352 passed, zero failed, 14 intentional skips.
Strict code signing and Simulator launch46616 passed. Targeted audit-v1 scanned
9649 files with zero flags and both exported test consoles; unselected evidence,
opaque secrets and unexported compressed contents remain outside that claim.
Retained build-v1/v2 compiler errors and full-v1 39 failures were corrected;
renderer-only setups now explicitly seed state, not the removed WebUI send API.
Direct send regressions exercise real direct orchestration with mock transport.
This is not live model/cron execution or physical-device acceptance.

Newly confirmed recovery gap: stock REST returns durable rows, not live partial
assistant text. `session.resume.inflight` carries that text without an atomic
event watermark; blindly appending later deltas can duplicate it. Completed
durable interim assistant rows must not absorb subsequent stream segments.
Investigate proven warm cursor replay separately; cold prefix/corrections recovery
remains unaccepted. No duplicated snapshot UI or unsafe last-row merge approved.
Skill activation also remains open: raw skill-content REST omits runtime setup,
configuration, supporting files and optional shell preprocessing. command.dispatch
is not profile-bound and resolves executable quick commands/plugins before skills.
Do not label raw text submission equivalent to TUI skill activation.

Current next cohort: direct file browser/preview and built-in memory/SOUL saves
are authored and independently reviewed, awaiting native integration alongside
profile creation. Memory uses managed multipart atomic replacement, never an
unrestricted filesystem fallback; concurrent writers still have no CAS guard.
Profile creation preserves confirmed identity across optional configuration
failure. Retry only repeats captured configuration, not creation. A stock
best-effort model-assignment failure stays explicitly partial; the app does not
invent a model-config repair that could retain wrong-provider credentials.
Native checkpoint now passed: signed build-v3 and full-v2,2338pass/0fail/
14intentional opt-in skips, strict code signing and ordinary Simulator launch19578.
Retained failures: build-v1 test raw-string delimiter; full-v1 four multipart
mock-parser failures (Swift CRLF is one Character, dropLast(2) truncated paths).
Exact delimiter parser fixed, path/overwrite/filename assertions strengthened;
product code and existing success/failure assertions not weakened. These checks
do not prove actual memory/profile writes on stock runtime or physical UI.
Targeted artifact audit-v1 passed9579files/0flags/2exported consoles across this
cohort's successful and failed builds/tests plus migration docs/runtime logs.
No claim for unselected older evidence, opaque/OCR/unexported contents.

Three disjoint implementation workers while root integrates/verifies. Compile and
targeted checks per batch; full/live gates at meaningful integration checkpoints.
Do not rerun passed gates merely to reconstruct context. Only one native/build
owner. Do not edit files while root compiles their shared source snapshot.
Report code-ready separately from tested and accepted; no percentage increase
solely because more code was authored. No personal Hermes changes/private patches.
