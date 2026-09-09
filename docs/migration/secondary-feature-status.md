# Secondary feature migration status

Reconciled September 8, 2026 against app `628225f` Kanban/Insights checkpoint:
signed build-v5/UI-build-v1, focused corrections11/0/0 and68/0/0, production UI1/0/0;
integrated full2087/0/14, signing/ordinary launch passed. Backend pin:
`29112bef099274229cadff79cdff7bf7b99c4b77`.
This is the existing dispatch inventory, not release acceptance or a percentage.
The binding v3 execution plan owns scope and gates; root owns disposition.

Official first-party Hermes REST is retained. Source names `web_server.py` and
`web_routers` do not mean the separate WebUI product. “Legacy” means the app still
uses the old contract. “Implemented/tested” never means physical acceptance.
No unsupported feature below has been silently approved for permanent removal.

## Current consumers and remaining work

| Feature / action | Current implementation | Evidence and remaining gate |
| --- | --- | --- |
| Main chat transport | Shared direct runtime only; obsolete main-chat coordinator/status timers/cancel-status APIs removed. Queue drain now follows confirmed idle completion. | chat-transport-retirement full2102/0/14 and production login/new-chat/send UI1/0/0. Pacing/direct renderer/queue/privacy tests retained. Physical and final lifecycle gates remain. |
| BTW side questions | Direct shared-runtime `prompt.btw` and correlated `btw.complete`; local-only card, single active request and explicit unknown outcomes. Same-conversation local cards survive delayed canonical refresh; no cross-tip carry. Legacy BTW/chat SSE and APIs removed. | Signed build-v5/UI-build-v3, focused79/0/0, final full-v3:2070/0/14, production UI-v3:1/0/0 with inspected screenshot; targeted audit9901files/0flags. Completion-before-ACK, wrong task/session/question, disconnect/invalidation, no-blind-retry and reconcile tests. Owned stock live-v1 proves exact local answer and unchanged canonical history/config. No physical acceptance. |
| Background tasks | Implemented shared-runtime `prompt.background`, multiple task/session-correlated local cards, explicit unknown outcomes and no automatic retry. Same-scope canonical refresh retention; old HTTP/polling removed. | Audio/background focused-v2:106/0/0, full-v2:2092/0/14 and production UI-v2:1/0/0 with inspected screenshot. Owned stock live-v1 two exact ACK/results and unchanged history/config. Physical acceptance separate. |
| Goal controls | Guarded direct controller/VM implemented. Enable only session profile matching running gateway `current`; mismatch explicitly unavailable at this pin. Draft-first commands supported; status/pause/clear available while running without interrupting the turn. No client continuation loop. | Focused goal20/0/0, production login/new-chat/status UI1/0/0, full2096/0/14. Live E2E proves one submit → two server-driven turns/judges → done, exact canonical history and cleanup. Existing-gateway scope-v2 proves wrong-default placement for named profiles. Typed output/send, explicit ambiguity/no retry, connection/profile binding. Quickcommands/plugins keep stock precedence. No private backend patch, cross-profile or physical acceptance claim. |
| Kanban board live updates | Stock optional `/api/plugins/kanban` adapter + authenticated WebSocket; old HTTP endpoints/SSE dependency removed. | Focused checks, full2087/0/14 and production board navigation pass; owned live inert task edit/comment/link and WS readback passed, clean exact-board cleanup/config unchanged. Plugin absence differs from resource404; uncertain mutations never retry. Real dispatcher/provider and physical acceptance unverified. |
| Insights | Selected-profile direct session inventory and local analytics; old `/api/insights` removed. | Focused tests and production UI pass. Newest500 nonarchived rows, explicit partial/unknown-total label, local date filter, profile read errors rejected. Message/token/cost/top-session aggregates retained; server-only breakdowns unavailable as on prior local fallback. No unlimited-history or physical acceptance claim. |
| Profile inventory / sidebar selection | Direct `/api/profiles` and `/api/profiles/active`; local sidebar selection is not a global switch. | Integrated native tests. Keep current-running distinct from startup default. |
| Startup default / profile creation | Direct startup-default ACK/readback and create/configure workflow. Confirmed created identity survives optional configuration failure; no blind recreate. | `cd41f5b` includes creation; full2338/0/14. Same-value default live probe passed. Actual create/configuration/provider adoption and changed-default restart/UI remain unverified. |
| Tasks / cron | Scoped direct list/detail/runs/delivery, pause/resume, create/edit/trigger/delete. Sparse updates preserve fields outside editor; unknown-create inspection prevents automatic retry. | `0cc42ca` full2352/0/14. Inert future-job create/pause/resume/delete live probe passed with zero triggers. Actual trigger/provider execution, output/toast parity and physical UI remain open. |
| Default model picker | Direct scoped catalog and main-model POST/readback. Exact provider identities, explicit expensive/Nous confirmation, cached then fresh catalog. Applies to new sessions. | `0cc42ca` full2352/0/14. Actual model/provider adoption and production picker interaction unverified; no provider activation authorized. |
| Skills list/toggle/SKILL.md | Direct scoped `/api/skills`, `/api/skills/toggle`, `/api/skills/content`; selected profile reaches consumers. | Native tests; read-only live58rows plus one SKILL.md. Actual toggle/UI, related metadata and installed linked files remain open. Temporary unavailable notice is not feature-removal approval. |
| Chat skill activation/search | Still explicitly unavailable in direct chat. List-screen migration is not activation. | Stock command.dispatch lacks profile binding and resolves executable quickcommands/plugins before skills. Raw content omits runtime preprocessing/setup/config/supporting files. Need faithful supported handling or explicit disposition. |
| Inference provider inventory | Stock `/api/model/options` adapter including unconfigured rows, explicit default profile, selected provider, availability hints, warnings and model counts. | Focused and full native checks passed. UI distinguishes inventory from connection health and states credential sources are not reported; no login-provider substitution or activation. No new live provider/physical check. |
| Settings version / session-visibility preferences | Version uses stock `/api/status`. CLI/Claude visibility is explicitly device-local per server, using existing keys and read-only legacy fallback. | Signed build-v1, focused63/0/0 and full2265/0/14 passed. Immediate persistence, server isolation, fallback/override and independent child preference tested. No server settings mutation, import/deletion or sync claim. Physical Settings navigation remains unverified. |
| Shortcuts profile inventory | ProfileEntity now uses existing directProfiles with unchanged custom headers and cached fallback. | Focused App Intent tests and full native checkpoint passed. No new out-of-process cookie/auth mechanism or physical Siri acceptance claimed. |
| Server updates | Stock GET `/api/hermes/update/check?force=...`, bodyless POST `/api/hermes/update`, bounded action-status monitoring replace the legacy updater. | Focused native checks passed. Success requires the known POST action ID matching the durable completion marker, explicit non-running status and zero exit. Missing/lost ACK, cancellation or uncertain completion never enables blind retry or claims success. Raw log lines are not decoded. No actual updater execution against the pinned fixture/personal backend is authorized; that remains unverified. |
| Git reads / diff UI | Direct scoped session cwd → returned worktree root → status/review/branches/diff. Full review inventory beyond200; unknown flags retained. Unproven unstaged diff fails explicitly, avoiding false all-add fallback. | `0d9c6df`: full2368/0/14 plus dedicated91/0/0. `e43a571` live stock reads verified staged/unstaged separation. Native session-root navigation and physical UI not proved. |
| Git writes / remote operations | Stock explicit-file stage/unstage, clean existing-local switch and push implemented; old Git APIs/endpoints removed. Deferred controls hidden: fetch/pull, stash/new/remote checkout, generated/manual/selected/quick commit and discard. | Signed unit-build-v5/UI-build-v3, focused94/0/0, full2235/0/14, UI1/0/0 and Python45/0 passed. Fresh owned repository live stage/unstage/switch with readback passed; final UI-v3 screenshots inspected, audit14381files/0flags. Startup loading and canonical Git identity/child sheets fixed. No actual remote push or physical acceptance. Exact path/branch-sanitizer checks; partial/unknown outcomes; unknown push needs explicit refresh. Stock concurrent filesystem mutation is not atomic. Agent Git remains possible subject to permissions. |
| Memory / USER / SOUL | Direct profile scope, managed MEMORY/USER reads and atomic replacement, dedicated SOUL route. Baseline/readback and unknown-write barrier. | `cd41f5b` native2338/0/14. Managed transport live check passed, not actual memory-editor/model adoption. Concurrent-writer CAS and effective project-context discovery remain open. |
| File browser / preview | Direct managed list/read with canonical target checks, bounded bytes/PDF and cancellation. No unrestricted fs fallback. | `cd41f5b` native2338/0/14; `fd370bf` managed-file65byte live roundtrip. Real navigation/device and stock post-resolution filesystem race remain separate. |
| Voice transcription / speech | Direct JSON/base64 audio contracts and profile checks; voice-note send now transcribes/stages only its own clip, retaining unrelated draft attachments. Canonical absolute audio refs use guarded managed reads. | Audio/background focused-v2:106/0/0 and full-v2:2092/0/14. Real `.m4a` MIME mismatch fixed to `audio/mp4`. Actual microphone/audio provider/device and relative canonical audio refs remain unverified. |
| Workspace registry / projects | Local organizer implemented/native-tested; existing UI uses persistent scoped local metadata, not registry network mutations. | Maurice approved device-local groups/bookmarks separate from cache. No cross-device organization sync, backend patch, automatic personal-data import or deletion. Bookmarking is not remote directory creation. Physical navigation acceptance remains. |
| Session JSON / HTML export | Scoped stock JSON export; escaped self-contained HTML rendered locally, bounded I/O off main thread, cancellation/profile guards and owned-temp cleanup. | Signed build-v3/full-v5:2371/0/14. Stock HTTPS export live-v1:4rows/8264bytes; probe4/4 guards. Both formats and complete metadata preserved in native fixtures. Live HTML share navigation/physical UI remain unverified. |
| Session duplicate | Stock named branch via shared runtime and temporary controllers; exact child detail/list recovery, scoped unknown-outcome barrier, no successful parent/child close. | Signed build-v4/full-v3:2372/0/14 including named/default params, running refusal, profile-switch/detail failure, no repeat and surviving open controller. No live sidebar/physical acceptance or cross-relaunch idempotency claim. |
| Session move | Semreh-local group assignment implemented/native-tested, applied over cache, fresh list and search detail rows. | Does not relocate files or alter Hermes working directories. Scope/persistence/refresh/corrupt-data checks passed. Best-effort canonical transfer retains ancestor mapping; separately reassigned old/new entries can diverge. No separate backend. |
| Search / rename / pin / archive / counts | Direct work already integrated in earlier checkpoints. | Exact scope and ambiguous-mutation recovery remain relevant to final navigation/device gate; deletion writer concurrency and destructive history are separate core requirements. |
| Edit / regenerate / delete | Guarded stock `prompt.submit` durable-row truncation and exact-profile `session.delete`; existing confirmations retained, old REST deletion removed. | Focused native tests and owned HTTPS live-v2 passed. Exact target checks, queued/lost ACK no-repeat, profile changes and numeric row precision are covered. Attached sessions are refused, not implicitly closed. Maurice accepted the residual cross-client check/write race September 8; no atomicity claim. Native production navigation/device acceptance remains open. |
| Standalone tools/toolsets administration | No retained standalone consumer identified by bounded audit. | Do not create a new screen simply because stock routes exist. Chat tools/blocking are core migration work. |
| In-chat website login / native credential form | Temporary deferral approved September 8; obsolete overlays, SSE events, proprietary API controls and dedicated fixtures removed. | Signed login-retirement build-v1, focused140/0/0, full-v2:2197/0/14; signed launch passed. Pinned Gateway has no equivalent session-bound event/response/cancel contract; MCP OAuth is not equivalent. Normal app login and direct approval/clarify/secret/sudo remain supported. Friend’s Telegram plugin is an unreviewed future lead, not a migration dependency. Physical acceptance remains open. |

## Source and evidence pointers

- Profiles: stock `web_routers/profiles.py`; default/create production consumer
  `DefaultProfilePickerView` plus profile networking helpers.
- Cron: stock `/api/cron/jobs` family; app `APIClient+Cron`, Tasks and TaskDetail.
- Model: stock `/api/model/options`, `/api/model/set`; app DefaultModelPicker.
- Skills: `web_routers/skills.py:430,465,484`; runtime invocation in
  `tui_gateway/methods_tools.py` and `agent/skill_commands.py`.
- Git: `web_routers/git.py`, `hermes_cli/web_git.py`; app `APIClient+Git`.
- Export: `web_routers/sessions.py:847–907` streams full JSON in500row keyset chunks.
- Evidence root: `/Users/maurice/workspace/semreh-slice1-evidence`.
  Relevant stems: `slice4-files-memory-profiles`, `slice4-send-cron-model`,
  `slice4-git-monitor-retirement`, `slice4-managed-files-live-v1.json`,
  `slice4-git-read-live-v1.json`, `slice4-skills-readonly-live-v1.json`.
- Full native suites contain14 intentional opt-in skips; their green result is
  not a claim every live/device gate ran. Sanitized audits have stated exclusions.
  Exact prior failure history remains in remaining-work/verification documents
  and retained artifacts, not erased by this inventory reconciliation.

## Dispatch priority after the no-drift audit

1. Close the three direct loading/recovery behavioral coverage holes and verify
   the current load/export batch. Do not count unrelated tests as replacements.
2. Complete legacy execution/auth/SSE/dependency removal while preserving actual
   direct user behavior, not dead protocol-specific fixture scaffolding.
3. Address core recovery/compression, destructive targeting and skill-activation
   contract gaps alongside remaining visible legacy features above.
4. Demonstrate WebUI-absent operation, cross-client continuity and physical-device
   acceptance. Deferred visual polish does not waive broken behavior.

Use `remaining-work.md` as the dispatch checklist and the binding plan as final
acceptance. Do not create another competing inventory or infer feature waivers.
