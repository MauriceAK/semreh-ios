# Secondary feature migration status

Reconciled September 7, 2026 against committed app `32be0ac` plus the sidebar
duplicate diff verified by signed build-v4/full-v3. Backend contract pin:
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
| Profile inventory / sidebar selection | Direct `/api/profiles` and `/api/profiles/active`; local sidebar selection is not a global switch. | Integrated native tests. Keep current-running distinct from startup default. |
| Startup default / profile creation | Direct startup-default ACK/readback and create/configure workflow. Confirmed created identity survives optional configuration failure; no blind recreate. | `cd41f5b` includes creation; full2338/0/14. Same-value default live probe passed. Actual create/configuration/provider adoption and changed-default restart/UI remain unverified. |
| Tasks / cron | Scoped direct list/detail/runs/delivery, pause/resume, create/edit/trigger/delete. Sparse updates preserve fields outside editor; unknown-create inspection prevents automatic retry. | `0cc42ca` full2352/0/14. Inert future-job create/pause/resume/delete live probe passed with zero triggers. Actual trigger/provider execution, output/toast parity and physical UI remain open. |
| Default model picker | Direct scoped catalog and main-model POST/readback. Exact provider identities, explicit expensive/Nous confirmation, cached then fresh catalog. Applies to new sessions. | `0cc42ca` full2352/0/14. Actual model/provider adoption and production picker interaction unverified; no provider activation authorized. |
| Skills list/toggle/SKILL.md | Direct scoped `/api/skills`, `/api/skills/toggle`, `/api/skills/content`; selected profile reaches consumers. | Native tests; read-only live58rows plus one SKILL.md. Actual toggle/UI, related metadata and installed linked files remain open. Temporary unavailable notice is not feature-removal approval. |
| Chat skill activation/search | Still explicitly unavailable in direct chat. List-screen migration is not activation. | Stock command.dispatch lacks profile binding and resolves executable quickcommands/plugins before skills. Raw content omits runtime preprocessing/setup/config/supporting files. Need faithful supported handling or explicit disposition. |
| Inference provider status | ProvidersViewModel still calls legacy `providers()`. Login-provider discovery is not inference health/configuration. | Map actual displayed fields to stock responses or request disposition; no invented aggregate service or provider activation. |
| Git reads / diff UI | Direct scoped session cwd → returned worktree root → status/review/branches/diff. Full review inventory beyond200; unknown flags retained. Unproven unstaged diff fails explicitly, avoiding false all-add fallback. | `0d9c6df`: full2368/0/14 plus dedicated91/0/0. `e43a571` live stock reads verified staged/unstaged separation. Native session-root navigation and physical UI not proved. |
| Git writes / remote operations | Existing checkout/stash, stage/unstage/discard, generated commit message, commit/selected commit, fetch/pull/push still legacy. | Audit each workflow, not just route names. Stock auto-stage/discard/selection semantics differ. No personal/remote mutation verification authorized. |
| Memory / USER / SOUL | Direct profile scope, managed MEMORY/USER reads and atomic replacement, dedicated SOUL route. Baseline/readback and unknown-write barrier. | `cd41f5b` native2338/0/14. Managed transport live check passed, not actual memory-editor/model adoption. Concurrent-writer CAS and effective project-context discovery remain open. |
| File browser / preview | Direct managed list/read with canonical target checks, bounded bytes/PDF and cancellation. No unrestricted fs fallback. | `cd41f5b` native2338/0/14; `fd370bf` managed-file65byte live roundtrip. Real navigation/device and stock post-resolution filesystem race remain separate. |
| Voice transcription / speech | Direct JSON/base64 audio contracts, profile checks, local fallback preserved. | `3eb648f` native2314/0/14. Actual microphone/audio provider/device unverified. Sending recorded voice attachments remains unavailable, not accepted removal. |
| Workspace registry / projects | WorkspaceRegistry and project mutations still legacy; stock cwd/project-tree reads are not equivalent to naming/order/membership workflows. | Map exact retained semantics. No arbitrary-directory substitution or unapproved deletion. |
| Session JSON / HTML export | Scoped stock JSON export; escaped self-contained HTML rendered locally, bounded I/O off main thread, cancellation/profile guards and owned-temp cleanup. | Signed build-v3/full-v5:2371/0/14. Stock HTTPS export live-v1:4rows/8264bytes; probe4/4 guards. Both formats and complete metadata preserved in native fixtures. Live HTML share navigation/physical UI remain unverified. |
| Session duplicate | Stock named branch via shared runtime and temporary controllers; exact child detail/list recovery, scoped unknown-outcome barrier, no successful parent/child close. | Signed build-v4/full-v3:2372/0/14 including named/default params, running refusal, profile-switch/detail failure, no repeat and surviving open controller. No live sidebar/physical acceptance or cross-relaunch idempotency claim. |
| Session move | SessionMutator move remains legacy; stock metadata PATCH has no equivalent project-membership mutation. | Defer-and-hide recommendation pending explicit approval. Separate API-server fork is not a substitute for this deployed serve surface. |
| Search / rename / pin / archive / counts | Direct work already integrated in earlier checkpoints. | Exact scope and ambiguous-mutation recovery remain relevant to final navigation/device gate; deletion writer concurrency and destructive history are separate core requirements. |
| Standalone tools/toolsets administration | No retained standalone consumer identified by bounded audit. | Do not create a new screen simply because stock routes exist. Chat tools/blocking are core migration work. |

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
