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
| Profile inventory in sidebar, Settings summary and default-profile picker | These consumers still call `profiles()` in `APIClient+ServerPanels.swift`. `directProfiles()` already exists in `APIClient+DirectHermes.swift`. Sidebar profile switching is already local UI selection with explicitly scoped direct requests. | `GET /api/profiles` returns `{profiles:[…]}`; `hermes_cli/web_routers/profiles.py:777`. `GET /api/profiles/active` returns `{active,current}`; line 901. | Switch remaining inventory readers to direct transport, preserve local selection across reloads, and separately resolve the settings default/active label. Test stock profile rows and absence of old aggregate default fields. | No decision for inventory reads. Do not reinterpret local sidebar selection as a server mutation. |
| Default-profile change and create-profile form | `DefaultProfilePickerView` still uses `switchProfile`, `createProfile`, and legacy `models()` for its form. | `POST /api/profiles/active` with `name` returns `{ok,active}` and changes the sticky default for future CLI/gateway starts, **not** the already running server's profile (profiles.py:922). `POST /api/profiles` accepts stock `ProfileCreate` (line 788). | Map create fields against `web_models.ProfileCreate`; migrate form catalog. Treat default-profile write as a separate semantics package with durable readback. | Confirm intended default-profile meaning if the old UI promises immediate server retargeting. Profile cloning must preserve the selected config/state scope. |
| Tasks / cron list, create/edit, pause/resume/run/delete and output | `TasksViewModel` / `TaskDetailViewModel` call legacy `APIClient+Cron.swift`; methods include old create/update/status/output/delivery endpoints. Still reachable from utility menu. | `GET /api/cron/jobs?profile=…` returns a bare array (`web_routers/cron.py:63`; `web_server.py:13061`). Detail `GET /api/cron/jobs/{job_id}`; runs `GET …/{job_id}/runs`. Create `POST /api/cron/jobs`; edit `PUT …/{job_id}`; pause/resume/trigger `POST …/{job_id}/{pause,resume,trigger}`; delete `DELETE …/{job_id}`. Delivery `GET /api/cron/delivery-targets`. | Start with explicit-profile list/detail DTOs and list UI; separately map output/run history, schedule, notification and delivery fields. Never turn a legacy status/output response assumption into a stock contract. Live mutation checks require a dedicated inert job fixture. | No decision for supported reads. Ask only for unsupported retained fields/disposition or authority to execute a scheduled job/provider. Cron activation is not authorized by this inventory. |
| Skills inventory, enable/disable and SKILL.md | New `directSkills`, `directToggleSkill`, `directSkillContent`; Skills UI and both menu entrypoints propagate selected profile. Legacy helpers remain for separate chat consumers. | `GET /api/skills` bare array with `enabled`; `PUT /api/skills/toggle` `{name,enabled}` → `{ok,name,enabled}`; `GET /api/skills/content` with name/profile → `{name,content,path}` (`web_routers/skills.py:430,465,484`). | Root completes native/UI integration checks. Tag/related metadata and linked-file parity remain open. Direct UI displays linked-files unavailable; components retained. | Root approved the temporary unavailable notice, **not** permanent feature removal. No live toggle was performed. |
| Tools / toolset management | No standalone production tools/toolsets management consumer found in this bounded secondary-screen scan. Chat tool activity/blocking interactions are separate core work. | Stock `GET /api/tools/toolsets?profile=…`; `PUT /api/tools/toolsets/{name}` and config/provider/env routes exist (`web_routers/tools.py:62,128,233,466,608`). | Do not create a new tools screen merely because routes exist. If a retained control is identified, inventory its actual behavior before choosing a stock method. | New tools administration or activation would expand scope. |
| Default model picker | `DefaultModelPickerView` uses legacy `models()`, `modelsLive()`, `saveDefaultModel()`. Existing direct model catalog adapter is available elsewhere. | `GET /api/model/options` (web_server.py:7449); `POST /api/model/set` accepts `ModelAssignment`, `scope=main` or `auxiliary`, provider/model and optional profile (line 7719). Writes apply to **new sessions**, not the active session. | Move reads to profile-scoped direct catalog; preserve provider identity and selected/custom model. Verify the chosen catalog filtering policy. Implement main-slot write plus readback as its own package. | No decision for supported inventory. Clarify any UI promise that changes should affect an existing session; do not activate providers as verification. |
| Providers status catalog | `ProvidersViewModel` still uses legacy `providers()`; inventory previously found no exact stock `/api/providers` replacement. | `directProviders()` targets `/api/auth/providers`: login-provider discovery, **not inference provider health/configuration**. Stock model options and setup/OAuth routes do not by themselves replace the old screen. | Map each displayed status field to a first-party response, or present a concrete disposition proposal. Do not fabricate an aggregate status service. | Retained unsupported status/credential functionality needs disposition. |
| Git workspace status/branches/diffs and mutation menu | `GitWorkspaceViewModel` uses legacy session-ID based `APIClient+Git.swift`. Supported UI includes fetch/pull/push, checkout, stage/unstage/discard and commit workflows. | Stock reads are repository-path scoped: `GET /api/git/status?path=…`, `/api/git/branches?path=…`, `/api/git/file-diff?path=…&file=…`; richer review routes also exist (`web_routers/git.py:33,95,117`). | Resolve authoritative session cwd first, then map read DTOs without substituting session IDs for repository paths. Audit each retained write body independently; a matching operation name is insufficient. | Destructive/remote actions require their existing user confirmation and an owned test repo; no remote pushes or personal repo access for migration checks. |
| Memory editors (SOUL, MEMORY, USER, project context) | Reachable `MemoryView` / `MemoryViewModel` still use legacy `memory()` / `writeMemory()`. | Stock `GET/PUT /api/profiles/{name}/soul` supports SOUL content (`web_routers/profiles.py:1052,1063`). `GET /api/memory` is provider status/file sizes (web_server.py:14332), **not** editor text. | Build the profile-scoped SOUL adapter only within the selected disposition; preserve unsupported editor requirements until root gets the answer. No guessed filesystem paths or provider reset. | Pending user decision: SOUL migration with unsupported editors hidden versus retaining all editors as release requirements. |
| Workspace registry / projects | `WorkspaceRegistryViewModel` uses legacy workspace list/suggestions/add/remove/rename/reorder; sidebar projects use `APIClient+Projects.swift`. | Existing inventory identifies `projects` RPC and official profile project-tree reads (`GET /api/profiles/projects/tree`, profiles.py:621). No exact stock equivalence established for the full custom workspace registry's naming/order/removal semantics. | Separate cwd/project selection from app-maintained registry operations. Map project IDs and membership before mutation; propose concrete handling for unsupported registry fields. | Unsupported collection semantics need a product disposition, not silent replacement with arbitrary directories. |
| File browser and previews | `FileBrowserViewModel` / `FilePreviewViewModel` still have legacy directory/file/raw helpers in `APIClient+Workspace.swift`. `directReadManagedFile(path:)` already exists for a narrower managed-file responsibility. | Stock `GET /api/files`, `/api/files/read`, `/api/files/download`, `/api/files/stream` (web_server.py:2830–2960). | Migrate actual browser consumers using stock path/profile/access rules; keep managed attachment reads distinct from arbitrary workspace browsing. Validate response size/encoding and download behavior. | No decision for a supported read. Do not broaden filesystem access or synthesize host paths. |
| Voice transcription and server speech | `ComposerVoiceInputController` uses legacy multipart transcription adapter; `synthesizeSpeech` uses old `/api/tts` raw bytes with on-device fallback. | `POST /api/audio/transcribe` takes JSON `AudioTranscriptionRequest` with a base64 `data_url` and optional MIME/profile (web_server.py:5306), returning transcript fields. `POST /api/audio/speak` takes `TTSSpeakRequest` and returns a base64 audio data URL (line 5549), **not raw MPEG**. | Map payload/response and size limits, preserve local speech fallback and auth classification. Prepare synthetic contract tests; actual synthesis/transcription requires an approved fixture provider. | No provider activation or real external audio submission authorized here. Resolve unsupported voice/engine options before changing their behavior. |

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
