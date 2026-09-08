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
