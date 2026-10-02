# PROTO-CHAT-01 / WORKER-INTEGRATE — wiring verification, fixes, verification notes

## Unit ID / ownership / dependencies

- **Unit ID:** PROTO-CHAT-01 / WORKER-INTEGRATE
- **Kind:** implementation (not device verification — no Xcode exists on this Linux VM, so nothing here was compiled or run; see "UNVERIFIED" below)
- **Owned paths:** `HermesMobile/Features/Prototype/**` only, plus exactly one approved edit outside it:
  - `HermesMobile/Features/Prototype/Shell/PrototypeRootView.swift` — added `.environment(\.protoChatServerURL, server)` to the `.chat` navigation destination (required by `PrototypeChatView`'s server contract)
  - `HermesMobile/Features/Prototype/Chat/PrototypeChatView.swift` — 3 fixes (below)
  - `HermesMobile/Features/Prototype/PROTO-CHAT-01-NOTES.md` — this file (added)
- **Dependencies:** the real `ChatViewModel` (`HermesMobile/Features/Chat/ChatViewModel.swift`), `GatewayConversationController` (`HermesMobile/Networking/GatewayConversationController.swift`), `OpenChatSessionStore`, `ComposerDraftStore`, `ChatScrollPolicy`, `ChatActiveRunStatusPolicy`, `ChatMotion` presets (landed by WORKER-CHAT), `SemrehVisualTheme`/`AppColorPalette`, `SessionListViewModel`, `APIClient.directProfiles()`, `SessionSummary`/`ProfileSummary` models. No mocks, no invented endpoints, no new dependencies.
- **Acceptance checks performed (static, by source inspection):**
  1. `PrototypeRootView` injects `protoChatServerURL` on the chat destination — done.
  2. Grep of `Features/Prototype/` for placeholder references (only a doc comment noting the placeholder was superseded), duplicate type definitions (none), non-app-target imports (only SwiftUI/Foundation — none).
  3. Every `ChatViewModel`/`GatewayConversationController`-adjacent call in `PrototypeChatView` matched against a real method signature — 2 compile defects found and fixed (below).
  4. `RunState` case coverage preserved via public VM signals (below).
  5. No force-unwraps in the prototype tree; no invented endpoints (all network goes through the real store/VM/APIClient paths).
  6. Restoration path: reopening a chat calls `loadMessages()` + cached-first rendering; foreground re-entry now triggers `refreshAfterSceneActivation()` → `reconnectStreamIfNeeded()` — was missing, now fixed (below).

## Defects found and fixed

1. **`PrototypeRootView.swift`** — `.chat` destination rendered `PrototypeChatView` without the `protoChatServerURL` environment value, so every chat would show "Chat unavailable". Fixed: `.environment(\.protoChatServerURL, server)`.
2. **`PrototypeChatView.swift` — `runStatusText`** — read `vm.directConversation?.runState`, but `ChatViewModel.directConversation` is `private` (ChatViewModel.swift:1029), so this could never compile. Rewrote to derive the same status from public VM signals: `isCancellingStream` → "is stopping"; `isStartingChat` / `directConversationHasPromptDeliveryUncertainty` → "is responding"; `activeStreamID != nil` → tool name / "is thinking" / "is working"; otherwise nil. Covers all five `RunState` cases (`idle, submitting, running, stopping, deliveryUnknown`).
3. **`PrototypeChatView.swift` — `stableRowID`** — used `transcriptMessage.index`, which does not exist on `TranscriptMessage` (fields: `loadedIndex`, `renderID`, `anchorID`, `message`). Fixed to `loadedIndex`.
4. **`PrototypeChatView.swift` — foreground re-entry** — had no `scenePhase` handling at all, so backgrounding never re-attached a live stream. Added `@Environment(\.scenePhase)` + `handleScenePhaseChange` mirroring production `ChatView`: background → `setTranscriptPresentationActive(false)` + persist draft; active → `setTranscriptPresentationActive(true)` + `await vm.refreshAfterSceneActivation()` (which reloads cached-first and calls `reconnectStreamIfNeeded()`); inactive → pause presentation. Extracted `persistDraft()` from `teardown()`. The per-session event sync still only stops on `.onDisappear`, exactly like production.

## Defects found but NOT fixed

None. Everything found was within owned paths and fixed.

## Assumptions (details the references don't show)

- `ChatViewModel.loadMessages()` populates `displayedTranscriptMessages` from the local cache synchronously enough that the skeleton rule (`isLoading && isEmpty && !hasPreservedTranscript`) renders cached messages without a blank flash — assumed from the VM's cached-first design; only a device run confirms it.
- `OpenChatSessionStore.shared.viewModel(session:server:)` reuses the VM for a session across navigation (so `resolveViewModel`'s `viewModel == nil` guard is the only resolution path) — assumed from the "Open" session store semantics and production `ChatView`'s retained-VM pattern.
- `startSessionEventSync()` before `loadMessages()` matches the production ordering (production's `.task` starts sync on appearance before its load path).
- `refreshAfterSceneActivation()` with no active stream re-runs `loadMessages()` — accepted as production behavior; the prototype inherits it verbatim.
- Prototype palette override (`AppColorPalette.chatgpt` + `.environment(\.appColorPalette, ...)`) only affects this surface, matching WORKER-CHAT's documented intent; the user's global palette choice is respected elsewhere.
- Skipped `wasReusedFromOpenSessionStore`-gated load skipping that production `ChatView` does: the prototype always calls `loadMessages()` on resolution. Assumed idempotent/cached-first; harmless but one extra reconcile on reopen.

## Deliberate differences from the reference behavior

- **Header status via public VM signals instead of `RunState`:** the controller is private to the VM; the five-way mapping above is behaviorally equivalent for display purposes.
- **`.task(id: serverURL)` resolution instead of production's startup-scope orchestration:** simpler; production's skip-load/warm-reuse dance isn't needed for a chat-only prototype.
- **Attachments/mic buttons show "unavailable" alerts** instead of production pickers — honest prototype scope, no fake functionality.
- **`ChatActiveRunStatusPolicy` called with `hasActiveRunPassedElapsedThreshold: false`** — the header pill already covers near-bottom runs, so the floating pill intentionally appears only when scrolled away.
- **No App Intents, deep links, share-extension imports, or Live Activities** in the prototype shell — documented in `PrototypeRootView`.
- **No message rename/delete** — `SessionMutator` is private to `SessionListViewModel` with no external wrapper.

## What works vs what remains UNVERIFIED

**Claimed working (by source inspection only):** navigation shell (bot list → conversations → chat), VM resolution through `OpenChatSessionStore`, send/stream/cancel/retry via the real `ChatViewModel`, reasoning/tool-call rendering, follow/reader scroll policy, cached-first restoration, foreground reconnect, draft persistence, error banner + retry.

**UNVERIFIED — no Xcode on this Linux VM, so:**
- The app target and `HermesMobileTests` have NOT been compiled; "compiling by construction" rests on manual signature matching above, not a build.
- Nothing was run on a simulator or device: no streaming behavior, no scroll smoothness, no frame-time/hitch data. Compilation alone says nothing about smoothness.
- The `protoChatServerURL` environment injection has not been observed to reach `PrototypeChatView` at runtime.
- Keyboard show/dismiss interplay with the composer, scroll-to-bottom affordance timing, and the "no blank flash" claim are all asserted from code reading, not recordings.

## Native verification steps (device + simulator)

Run on a **simulator (iPhone 17, iOS 18+, signed Debug build)** first, then repeat the full sequence on a **device** (physical device is required for credible keyboard/haptics/smoothness judgments). Use a real Hermes server reachable from the machine.

1. **Bot list → conversation list → chat.** Launch → land on "Chats" bot list. Expect real profiles with bird avatars, model subtitles. Tap a bot → conversation list with real sessions (titles, relative timestamps, previews). Expect no spinner beyond initial load; no "unavailable" states.
2. **New chat.** Tap the compose button → new chat opens. Type in the composer; confirm the "+" and mic buttons show honest "unavailable" alerts; the send button appears only with non-empty text.
3. **Send → streaming.** Send a prompt. Expect: user bubble appears immediately, scroll pins to bottom, blue stop-square replaces send, header shows "is working", then tokens stream into a Markdown-rendered assistant bubble. Haptic on completion (device).
4. **Thinking/tool states.** Send a prompt that triggers reasoning or a tool call. Expect: live reasoning disclosure ("is thinking"), tool activity group with the tool's display name in the header status ("is <tool name>"), completed tool groups collapsing into the transcript.
5. **Keyboard show/dismiss.** Tap the field (keyboard up, transcript stays pinned), swipe to dismiss keyboard, send via return. Expect: no transcript jump, composer stays visible, scroll anchor preserved.
6. **Scroll-away-and-back.** While streaming, scroll up. Expect: follow pauses, blue chevron-down button appears, quiet active-run pill overlays (never shifts rows). Tap chevron → smooth return to bottom, follow resumes.
7. **Background/foreground.** Background the app mid-stream, foreground it. Expect: stream re-attaches or completes cleanly, transcript shows no jump/duplicate, cached messages render instantly (no blank flash), draft text survives.
8. **Long conversation.** Open a long session with markdown, code blocks, and tool activity. Expect: day separators, "Load earlier messages" at top, no per-token row recreation, no insertion-animation retrigger mid-stream.
9. **Error retry.** Force a send error (airplane mode / bad server). Expect: inline error banner with Retry + dismiss; Retry re-sends; dismiss clears. `Chat unavailable` screen only when the server URL is genuinely missing.

**Capturing frame-time/hitch data (Xcode Instruments):**
- Simulator is indicative only — always confirm on device. In Xcode: Product → Profile (⌘I) → choose the **Core Animation FPS** template (or "SwiftUI" → **Hangs** template for hang detection). Record while repeating steps 4–8 (streaming tokens, scroll-away-and-back, background/foreground, long markdown transcript).
- Observe: FPS staying at 60/120 during streaming token appends; zero "hangs" > 100ms in the SwiftUI Hangs instrument during scroll gestures; frame-time graph without sustained spikes when tool-activity groups expand or code blocks render.
- Attach the trace (`.trace`) to the verification report. If FPS drops or hangs appear, note the exact gesture + transcript state (streaming vs idle, row count) so the cause is reproducible.

## Files changed

- `HermesMobile/Features/Prototype/Shell/PrototypeRootView.swift` (edited — the one approved non-Prototype-path edit: `.environment(\.protoChatServerURL, server)`)
- `HermesMobile/Features/Prototype/Chat/PrototypeChatView.swift` (edited — runStatusText rewrite, stableRowID fix, scenePhase handling)
- `HermesMobile/Features/Prototype/PROTO-CHAT-01-NOTES.md` (added — this file)
