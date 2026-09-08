# Secondary feature migration status

September 7, 2026; bounded source inventory against app `471b8e3` plus the current
uncommitted integration cohort. Backend contract pin:
`29112bef099274229cadff79cdff7bf7b99c4b77`. This is a dispatch inventory, not a
release acceptance report or a completion percentage. Root owns final disposition.

Sources: `slice4-tasks.md` secondary/provider inventories, the binding execution
plan and reference appendix, current production destinations and their adapters,
and the independently pinned backend source. Backend paths below are relative to
that source. Official `hermes serve` REST remains available without the browser
SPA; `web_server.py`/`web_routers` filenames do not imply a WebUI dependency.
“Legacy” below means the app still uses its old adapter/contract, even where the
stock server happens to expose the same route name. A source-supported candidate
is not evidence of successful UI execution.

| Feature / visible action | Current adapter and state | Exact known stock contract / source | Concrete remaining task | Owner decision required |
| --- | --- | --- | --- | --- |
| Profile inventory in sidebar, Settings summary and default-profile picker | Migrated to direct profile inventory; sidebar local selection preserved across reloads, startup default distinct from running current. | `GET /api/profiles`, `GET /api/profiles/active` at pinned stock. | Integrated native tests passed. | No new selection or server-mutation semantics. |
| Default-profile change and create-profile form | Startup-default setter uses stock POST plus GET confirmation; no running profile/model retarget. Form catalog now uses running current's direct model options (new tests pending). Create writes/inputs remain legacy. | `POST /api/profiles/active`; `POST /api/profiles`; profile-scoped config/model endpoints support follow-up settings. | Finish multi-step create and optional Base URL/API key configuration with explicit partial-success recovery; never repeat creation automatically. Same-value default live probe passed, changed-default/restart/native-picker gates open. | Clarify clone source in UI; preserve entered credentials/custom URL, do not silently drop fields. No provider activation for verification. |
| Tasks / cron list, create/edit, pause/resume/run/delete and output | Direct scoped list/detail/runs/delivery reads and pause/resume migrated. Execution badge derives from list enrichment, not un-enriched detail. Create/edit/run/delete remain legacy. | `/api/cron/jobs` plus scoped detail, runs, pause/resume; `/api/cron/delivery-targets`. | Map remaining mutation/output fields. Native pause/resume tests and inert future-job live create/pause/resume/delete probe passed; zero triggers and empty inventory restored. | Unsupported notification/output semantics remain open; no scheduler execution/provider activation authorized. |
| Skills inventory, enable/disable and SKILL.md | New `directSkills`, `directToggleSkill`, `directSkillContent`; Skills UI and both menu entrypoints propagate selected profile. Legacy helpers remain for separate chat consumers. | `GET /api/skills` bare array with `enabled`; `PUT /api/skills/toggle` `{name,enabled}` → `{ok,name,enabled}`; `GET /api/skills/content` with name/profile → `{name,content,path}` (`web_routers/skills.py:430,465,484`). | Root completes native/UI integration checks. Tag/related metadata and linked-file parity remain open. Direct UI displays linked-files unavailable; components retained. | Root approved the temporary unavailable notice, **not** permanent feature removal. No live toggle was performed. |
| Tools / toolset management | No standalone production tools/toolsets management consumer found in this bounded secondary-screen scan. Chat tool activity/blocking interactions are separate core work. | Stock `GET /api/tools/toolsets?profile=…`; `PUT /api/tools/toolsets/{name}` and config/provider/env routes exist (`web_routers/tools.py:62,128,233,466,608`). | Do not create a new tools screen merely because routes exist. If a retained control is identified, inventory its actual behavior before choosing a stock method. | New tools administration or activation would expand scope. |
| Default model picker | `DefaultModelPickerView` uses legacy `models()`, `modelsLive()`, `saveDefaultModel()`. Existing direct model catalog adapter is available elsewhere. | `GET /api/model/options` (web_server.py:7449); `POST /api/model/set` accepts `ModelAssignment`, `scope=main` or `auxiliary`, provider/model and optional profile (line 7719). Writes apply to **new sessions**, not the active session. | Move reads to profile-scoped direct catalog; preserve provider identity and selected/custom model. Verify the chosen catalog filtering policy. Implement main-slot write plus readback as its own package. | No decision for supported inventory. Clarify any UI promise that changes should affect an existing session; do not activate providers as verification. |
| Providers status catalog | `ProvidersViewModel` still uses legacy `providers()`; inventory previously found no exact stock `/api/providers` replacement. | `directProviders()` targets `/api/auth/providers`: login-provider discovery, **not inference provider health/configuration**. Stock model options and setup/OAuth routes do not by themselves replace the old screen. | Map each displayed status field to a first-party response, or present a concrete disposition proposal. Do not fabricate an aggregate status service. | Retained unsupported status/credential functionality needs disposition. |
| Git workspace status/branches/diffs and mutation menu | `GitWorkspaceViewModel` uses legacy session-ID based `APIClient+Git.swift`. Supported UI includes fetch/pull/push, checkout, stage/unstage/discard and commit workflows. | Stock reads are repository-path scoped: `GET /api/git/status?path=…`, `/api/git/branches?path=…`, `/api/git/file-diff?path=…&file=…`; richer review routes also exist (`web_routers/git.py:33,95,117`). | Resolve authoritative session cwd first, then map read DTOs without substituting session IDs for repository paths. Audit each retained write body independently; a matching operation name is insufficient. | Destructive/remote actions require their existing user confirmation and an owned test repo; no remote pushes or personal repo access for migration checks. |
| Memory editors (SOUL, MEMORY, USER, project context) | Direct built-in editors authored; final upload/review/native checks pending. Legacy memory callers removed in working tree. | SOUL dedicated profile route; profile inventory supplies home; stock memory tool defines `memories/MEMORY.md` and `USER.md`; managed file read/upload-stream retains server policy. Global `/api/memory` is metadata, not editor text. | Verify bounded reads, baseline conflict checks, atomic file replacement and confirmed readback; uncertain writes require refresh, never automatic retry. Atomic replacement does not provide concurrent-writer CAS. | Built-in editors are supported, correcting the earlier unsupported inventory. Effective project-context discovery remains open; no permanent removal approved. |
| Workspace registry / projects | `WorkspaceRegistryViewModel` uses legacy workspace list/suggestions/add/remove/rename/reorder; sidebar projects use `APIClient+Projects.swift`. | Existing inventory identifies `projects` RPC and official profile project-tree reads (`GET /api/profiles/projects/tree`, profiles.py:621). No exact stock equivalence established for the full custom workspace registry's naming/order/removal semantics. | Separate cwd/project selection from app-maintained registry operations. Map project IDs and membership before mutation; propose concrete handling for unsupported registry fields. | Unsupported collection semantics need a product disposition, not silent replacement with arbitrary directories. |
| File browser and previews | Direct consumer migration authored and independently reviewed; native tests pending. | Stock `/api/files` and bounded `/api/files/read` envelopes, canonical returned path checked against authoritative session cwd. Profile scopes session discovery, not global file routes. | Run focused/native integration; preserve exact binary bytes, PDF limits and cancellation ownership. Raw download avoided because it has no canonical-path receipt. | No access expansion/home fallback. Base64 memory cost bounded; stock post-resolution filesystem race remains. Git/workspace registry separate. |
| Voice transcription and server speech | Listen and composer transcription migrated, including synchronous live-profile check before inserting transcription. Local commit `3eb648f`; full suite2314/0/14 intentional skips. | `/api/audio/speak` takes text, profile query; `/api/audio/transcribe` takes JSON data URL plus MIME/profile. | Actual audio/device integration remains unverified; dormant voice-note upload/send path separate. | Server-configured voice replaces internal hardcoded voice (no user picker), documented root microdecision. No provider activation/real external audio submission authorized. |

## Evidence and corrections to older inventory

The skills read-only probe now supplies stock runtime evidence, superseding the
older blanket “secondary live checks unexecuted” statement for **skills reads
only**: `/Users/maurice/workspace/semreh-slice1-evidence/slice4-skills-readonly-live-v1.json`.
It observed 58 list rows and one nonempty SKILL.md with matching name; no names,
content or host paths were retained. Authentication cleanup passed. Zero skill
mutations. Its six Python tests passed. This does not prove literal Skills UI,
non-default-profile behavior, or toggle execution on the stock runtime.

Sidebar selection is already local and must not regress to the old global
profile-switch endpoint. Default-profile settings remain a distinct action.
Providers login discovery remains unrelated to inference-provider status.
Stock audio uses JSON/base64 contracts, so retaining the legacy multipart/raw
transport cannot be counted as voice migration. Tools route availability does
not establish an existing tools administration product requirement.

## Next independent implementation package

**Profile inventory reader cutover** is the smallest supported package without
an unresolved feature-removal or provider decision. Reuse `directProfiles()` for
the remaining secondary readers in `SessionListViewModel`, `SettingsView` and
`DefaultProfilePickerView`, with focused stock-shape tests. Preserve the sidebar's
existing local active selection. Do not combine this with create-profile or
sticky-default writes. First inspect the stock row flags and existing
`ProfilesResponse` fallback logic so missing legacy envelope fields do not reset
the selected profile or mislabel the configured default.

Coordinate Settings ownership with the active retirement worker; root owns
native execution. Acceptance should demonstrate refresh retaining a non-default
local selection and the picker displaying the stock catalog without legacy auth
classification. A read-only stock capture can cover inventory; it does not prove
profile creation, sticky-default mutation, or full profile UI acceptance.

Next larger independent package: explicit-profile cron list/detail adapters and
DTOs, followed by an inert read-only fixture. Keep mutation and unsupported
output/notification mapping as explicit follow-ups rather than claiming the
whole Tasks screen migrated.
