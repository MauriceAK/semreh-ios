# Current navigation review — September 13, 2026

Design proposal, not an implemented or visually accepted navigation change. Root owns approval and integration; Luna implements bounded UI work and Sol owns native verification. No backend capabilities are added by this proposal.

## Direction and evidence

Keep **Bots / Sessions / Activity**, cream/charcoal, source-qualified birds, native glass, and the **centered bird with its name underneath** in conversation. Keep model/reasoning/context one tap away. The newest reference video was reviewed through its main slices: Bots, settings/resource index, Jobs, Sessions/filtering, new-chat profile selection, workspace selection, and Settings. Sources: `/Users/maurice/Pictures/Photos Library.photoslibrary/originals/7/71BEABC4-9694-4BD1-AEAD-FAF5B5598E4D.mp4` and `/tmp/semreh-new-reference-20260913-contact.jpg`.

Borrow the reference's separation of chatting, browsing, and configuration. Do not copy its plugin index, multi-recipient selector, branding, or unimplemented capabilities. Its empty bot/new-chat presentation is not proof of transport, presence, or administration features.

Current source inspected: `AppShellView`, `AppShellMenuView`, `SessionListView`, `SessionListComponents`, `ChatView`, composer controls/picker, `TasksView`, `SettingsView`, `YouView`, and `DefaultProfilePickerView`. Current UI is still undergoing a native gate; this document does not replace that evidence.

## Action placement

| Surface / feature | Primary interaction | Secondary location and exact meaning |
|---|---|---|
| All three root tabs | Browse that tab; consistent title and Settings gear | Gear always opens app/server Settings. Avoid an account-shaped icon implying a separate hosted account system. Do not duplicate Settings inside every ellipsis. |
| Bots list | Tap bird/name/row → new chat in that exact server profile | Separate labeled info accessory → **Bot details**. Make its hit target independent of the chat row. Do not make the same tap sometimes chat and sometimes edit. |
| Bot details | **New chat**; show actual profile name, model/provider when supplied | **View sessions** applies the existing bot filter. Show read-only metadata, not a fictitious general editor. Creation/default-profile capabilities remain explicitly named below. |
| Sessions | Tap row → existing conversation; compose button → existing bot picker → new chat | One Filters control owns bot, pinned, scheduled-history, and project filters; show a compact active-filter summary and Clear. Keep search continuously discoverable. Avoid simultaneous bot/pin/clock/projects control strips. |
| Session row actions | Open; retain useful pin/archive swipe actions | Existing row context menu retains rename, duplicate, move to project, export/deeplink, archive, and supported deletion. Keep destructive confirmations and existing capability guards. Do not duplicate all these in global overflow. |
| Projects | Sessions filter/organizer, scoped to local organization | Create/rename/delete through existing organizer actions. Name **Project** distinctly from chat **Workspace path**; neither label should silently mean the other. |
| Conversation identity | Centered standalone bird; name pill underneath → **Choose bot profile** | Menu includes current conversation title and existing profile choices. Changing a nonempty conversation retains the separate-session warning. This is profile selection, not editing the bot. |
| Conversation controls | Sliders → one sheet with current model, supported reasoning steps, context, and direct model choices | Favorites/recent/catalog remain directly available. Custom model fields stay in collapsed Advanced/Custom section. Reasoning commits on release; no request per drag tick. No extra current-model → All Models → second-sheet sequence. |
| Conversation overflow | Ellipsis → **Files**, **Workspace path** | Keep current scope/path visible. Conditional Goal/Git actions remain here with current guards. Files opens the existing browser; workspace changes use the existing picker. No global Settings or unrelated management list here. |
| Composer / messages | Separate plus; compact message field with mic; send/stop when applicable | Plus owns existing file/photo/camera attachment actions only. Message context actions retain copy/select/listen/edit/regenerate/fork where supported. No settings footer. Thinking remains an expandable in-order accessory, not a competing primary card. |
| Activity | Actual scheduled tasks, explicit profile scope; plus → existing task editor | Job row owns existing edit/run/pause/delete actions where supported. Scheduled execution history belongs to Sessions' scheduled-history filter. Do not label a history row as a still-scheduled job or invent an active-work feed. |
| Settings: personal/app preferences | Existing Profile & appearance and Chat & sessions categories | Preserve identity, appearance, dictation, response behavior, display, visibility, accessibility-related preferences and current alerts options. Settings labels must not promise working remote push delivery. |
| Settings: server configuration | Existing Servers & models category | Connections, headers, providers, default model, **Server default profile**, updates retain their actual flows. “Server default” is distinct from the bot selected for one chat and from the running process profile. |
| Settings: secondary tools | A clearly labeled **Tools** row, using existing destinations | Kanban, Skills, Memory, Insights and remaining organizer/history shortcuts stay accessible. Show profile scope for profile-bound resources. Replace the separate Tools toolbar + nested sheet arrangement with one coherent navigation path when safe. Keep maintenance/cache/export/support/shortcuts/sign-out in App & maintenance. |

## Concrete inconsistencies to resolve

- Bots currently exposes “Default bot” prominently, but its row tap starts a chat and there is no general bot-details editor. Move the startup-default shortcut to its canonical Settings location; explain the actual effect there. An explicit Bot details surface can show existing metadata without claiming edit permissions.
- `DefaultProfilePickerView` already contains a guarded create-profile flow. Preserve it as **New server profile**, with the existing single-profile restrictions and configuration/error handling. Do not present generic “Customize bot” or import as working features. A direct shortcut is a later placement task, not a new creation implementation.
- Settings → Tools currently loops back to Settings/Manage Servers and repeats Tasks/Archived/Profile entry points. Remove navigation loops when consolidating; retain canonical destinations and intentional shortcuts, not duplicate implementations.
- Files visibility is still called “Files Button” in Settings although Files now lives in chat overflow. Rename the preference to **Files access** or **Show Files in chat menu**, preserving its storage key and behavior. Apply the same naming audit to Git and Tools visibility.
- The old single-profile/running-profile chooser in Tools and startup-default picker must never look interchangeable. A resource chooser should state its scope and must not retarget an open conversation.

## Bounded implementation order and acceptance

1. **Finish the current chat header/controls gate first.** Bird/name center must match viewport center at narrow and normal widths; Back and two trailing controls do not collide. Verify back tap/swipe and Files round trip. Empty/typed/multiline composer remains aligned with keyboard on/off. One sliders tap opens model/reasoning/context together; supported levels and unavailable context are truthful. Inspect light/dark screenshots plus scrolling video.
2. **Normalize root actions and Settings routes.** Same Settings gear/action on Bots, Sessions, Activity; Sessions compose remains explicit. Make Tools a normal Settings destination and remove circular Settings links. Verify every existing secondary resource and every preference remains reachable; dismiss/back returns exactly one level. No fourth tab.
3. **Make Bots tap behavior explicit.** Row tap creates the exact-profile chat through `NewChatRequest`; independent info opens metadata/details. Details' New chat and View sessions use that same profile. Test single-profile mode, missing metadata, long names, API failure, and that viewing details never changes startup defaults or an existing chat identity.
4. **Consolidate Sessions filtering.** Reuse existing predicates/organizer; one filter entry with visible active summary. Test each filter and combinations, Clear, search, row actions and scheduled-history semantics. Verify the actual last row remains reachable above search/native tabs and tab taps work after scrolling.
5. **Polish Activity and secondary naming.** Align root title/settings placement, retain selected profile scope and task editor/mutation guards, clarify scheduled tasks versus history. Audit renamed visibility settings and all Tools routes. No new job scheduler or unsupported activity categories.
6. **Thinking/send motion stays a separate bounded gate.** Isolated candidate is not accepted by this proposal. Preserve reasoning order and expansion state; prove new-local-message-only animation with no replay on restore/pagination/reconciliation. Record real send motion, reduced motion, reading earlier history, and attachment sends. No smoothness claim from a screenshot.

For each slice, root approves actual visual evidence before accepting. Stop feature expansion: no teams/friends/group chat, generic bot administration, plugin marketplace, remote computer, terminal, or push-delivery promise enters this navigation cleanup.
