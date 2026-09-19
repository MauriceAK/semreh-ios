# Performance and feel follow-ups

Owner: integrator. This is a bounded follow-up list, not an expansion of the
[migration plan](semreh_tui_gateway_v3_execution_plan.md).

September 6 decision: Maurice accepts residual large-jump/chat-switch lag in
Semreh Dev build8 temporarily so migration can continue. No claim of iMessage-like
smoothness, optimized-build latency, or universal resolution. Correctness defects
remain actionable immediately; cosmetic work waits until after migration.

- [ ] **PF-1 — Establish optimized-device baseline.** Same physical phone and
  three10k-row fixtures; measure initial/repeated switch and large-jump latency,
  scrolling hitches and resource usage. Compare Debug separately; no XCTest
  quiescence duration presented as frame-time measurement.
- [ ] **PF-2 — Large jump latency.** Profile target realization/layout and
  settlement attempts. Prefer bounded targeted improvements; preserve reliable
  bottom reach, subsequent gesture override and no blank/disappearing transcript.
- [ ] **PF-3 — Chat-switch latency.** Measure first and repeated switches with
  cached realistic histories. Investigate view recreation versus parsing/layout;
  do not remove per-chat identity resets or retain unlimited transcript views.
- [ ] **PF-4 — Real-history scrolling and opening.** Cache-first opening, older-page
  prefetch, stable prepend position, mixed Markdown/tools/media, streaming while
  reading. Synthetic lab does not prove live-network long-history behavior.
- [ ] **PF-5 — Sending and transition polish.** After migration, assess entrance
  animation, easing, transitions and perceived responsiveness. Freezing typing,
  duplicate submissions or lost drafts are correctness work, not deferred polish.
- [ ] **PF-6 — Thinking/tool lifecycle review.** Recheck long real conversations
  for stale/misplaced cards; never hide a blocking request as a cosmetic fix.

September9 personal pilot observations (original reports; progress below):
- [ ] Large blank gap between collapsed activity and thinking/final response;
  raw Markdown markers visible in thinking preview. Reproduce mixed-tool layout.
- [ ] User reports a large Markdown block appearing then disappearing across
  background work. Supplied screenshots show only the later state, so content
  loss is not proven. Compare live rows with saved history on return; distinguish
  intentional cold-resume reconciliation from missing durable content.
- [ ] Guardrail response visible while Stop button/dot and later sidebar
  "Streaming response..." remain. Verify actual server terminal state versus
  stale client running state before attributing blame or hiding indicators.
  Follow-up screenshot confirms failed Stop with "Hermes has not confirmed that
  the response stopped." Current UI uses that generic copy for every interrupt
  error. Controller requires interrupt ACK, status Agent Running: No AND a
  terminalReceipt, polling40x250ms plus RPC time. Missing terminal event can
  therefore leave Stop unconfirmed even if server is idle; not yet reproduced.
  Earlier screenshot now supplied: large rendered heading "Searching Reddit Ads
  interviews and compensation sources" before the final guardrail response.
  Establish whether it was interim content absent from durable history, terminal
  replacement, or client loss. Do not label it injected instructions or proven
  background recovery failure based on appearance alone.
- [ ] "Scheduled sessions" groups cron-marked history, not future jobs. Consider
  clearer "Scheduled task history" wording; inspect row markers if classification
  seems wrong. This disclosure existed in the pre-migration product base.

The exact loop_web_search_cap response originates in stock Hermes run_agent.py;
agent/tool_guardrails.py counts per-turn web_search calls. Its generic wording
does not prove every counted search failed or repeated identical arguments.
Investigate tool results separately; do not increase/disable guardrails as UI fix.

September9 stabilization progress (uncommitted successor to18f8c78):
- Missing-terminal cancellation reproduced failing before the fix. Controller
  now reconciles canonical history and confirms scoped idle, including rotated
  tip/rebind retries, without submitting again. Focused controller82/0/0;
  signed production fixture UI Stop->send->reply->idle1/0/0, screenshot inspected.
- Collapsed reasoning previews render bounded Markdown as plain text; expanded
  typography unchanged.5preview regressions pass. Whole-document parse initially
  joined paragraphs, caught by2tests and corrected with bounded linewise parsing.
-68-tool regression proves67 content-free/accessory-free assistant rows created
  phantom LazyVStack spacing. Presentation-only filter removes those children,
  preserves all canonical rows and visible accessory/compression anchors, and
  keeps scrolling targets consistent. TranscriptMessageTests28/0/0 pass.
- Mounted streaming Markdown shrink regression passed without a renderer change;
  persistent renderer height was not reproduced. Interim text is currently
  replaced by message.complete terminal text; that is not proof of durable loss.
  Exact phone guardrail run/history and physical smoothness remain unverified.

Verified checkpoint: ad3ddbc fixes competing explicit scroll/restore work and a
reproduced saved-reading-position race. Native2018pass/0fail/7intentional skips;
long-chat UI4pass/0skip. Owner confirms mid-scroll arrow works on build8, but
large-jump/switch lag remains. Evidence lives in `slice2-verification.md`.

User reports upstream chronology fix merged; release inclusion/pin upgrade and
ordering regression rerun are separate compatibility work, not verified here.

September8 bounded improvement: AppShell's perpetual60Hz selection-capsule timeline
now schedules only frames through transition settlement, preserving retargeting,
residual deformation and Reduce Motion. Motion tests16/0/0 and production chat/
background UI1/0/0 passed. Earlier UI attempt exceeded180s amid repeated animation
idle waits; some waits remained after the change. This removes continuous work,
but is not proof of the timeout's sole cause or a measured long-chat/device win.
