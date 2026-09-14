# Preview decisions

Recorded September 13, 2026. Decisions describe intended behavior, not a claim that implementation or verification is complete. Current execution status lives in local `CURRENT.md`.

| Decision | Reason / constraint |
|---|---|
| Finish existing-feature public preview before A2A, terminal, streaming, or remote push expansion. | Reliable everyday chats and cohesive navigation are the release priority. Preserve isolated feature candidates; do not market unverified integrations. |
| Keep Bots, Sessions, and Activity. | Bots represent server profiles; Sessions contain conversation history; Activity contains actual scheduled tasks. |
| Keep a centered bird with its name underneath in chat. | Explicit user requirement. Identity must not be displaced by trailing actions. |
| Use the approved swept-wing bird, with basic coordinated colors and no enclosing circle. | Preserve existing deterministic profile buckets; customization, accessories, and animation remain deferred. |
| Enlarge the header bird to roughly 48 points with a glass name capsule and no dropdown chevron. | Match the latest reference proportions; keep profile switching available in controls and preserve accessible hit targets. |
| Use a soft palette-matched fade behind the floating chat header and status bar. | Real screenshots showed transcript text competing with controls. Preserve scroll-under and avoid a hard-edged panel, extra layout space, or intercepted touches. |
| Present thinking/actions as compact muted icon-and-summary disclosure rows. | Keep truthful event labels, expandable details, and error/approval states without bulky decorative cards. |
| Explicit Back wins over a late startup restore for the current view lifetime. | Preserve the remembered chat for cold launch, but do not undo an intentional dismissal during refresh. |
| Blank-transcript acceptance requires repeated cold reopen with messages visible before interaction. | A screenshot after scrolling or an accessibility-only observation cannot establish that the reported glitch is gone. |
| Use sliders for model/reasoning/context; ellipsis for Files, workspace, and conditional secondary actions. | Frequent configuration is one tap away without a crowded header. Preserve existing guards and destinations. |
| Open a single controls sheet with direct model choices and supported discrete reasoning levels. | Remove the current-model → All models → second-sheet sequence. Preview slider movement locally; submit on release. |
| Show context only from authoritative usage data; fetch optional snapshots without delaying chat readiness. | Cumulative token totals are not context occupancy. Missing data remains explicitly unavailable, and stale results cannot overwrite newer state. |
| Use a separate plus and aligned text/mic/send composer. | Keep message entry visually simple. Preserve attachments, dictation, multiline input, and stop behavior. |
| Treat cron-origin conversations as scheduled history, not active jobs. | History provenance does not prove that a schedule still exists. Keep Hermes's deletion protections. |
| Hide empty Projects and consolidate Sessions filters while retaining organizer actions. | Reduce idle UI clutter without removing capabilities. Project and workspace path remain distinct concepts. |
| Show pinned conversations as an unlabelled top bird/name strip in the unfiltered Sessions view. | Matches the latest reference without an extra section heading. Keep same-bot conversations distinct, avoid duplicate ordinary rows, and retain pinned matches in filtered/search results. |
| Make bot-row taps start a chat; provide a separate read-only details action. | Avoid ambiguous tap behavior or implying a general profile editor exists. Server-default/profile creation remain in their real Settings flows. |
| Use consistent Settings access and remove circular Tools/Settings routes. | Keep current capabilities reachable through predictable navigation. |
| Use Kadu navigation and density as references, not as a template for copying assets or unsupported features. | Retain Semreh's cream/charcoal palette and original bird identity. Compare actual screens and motion, not source code alone. |
| Scope send animation to a newly submitted local message. | Restoring, paging, or reconciling history must not replay it or move the reader. Respect Reduce Motion. |
| Default implementation to Luna Max; use Sol Low for verification/escalation and Astra Low for visual design. | Control usage while retaining independent judgment for acceptance. |
| Serialize native verification on one simulator; root reviews substantial UI and integration. | Avoid shared-resource contention. The verifier must judge evidence, not only capture it. Each verdict applies to its tested source. |
| Keep working through bounded repairs; stop for actual blockers rather than routine design questions. | User authorized reasonable decisions with a log, not unbounded feature expansion or release deployment. |

Future A2A testing may use the user's WSL machine with a temporary, isolated Hermes instance. No instance has been started; exact host, isolation, lifetime, and cleanup must be resolved before using it.
