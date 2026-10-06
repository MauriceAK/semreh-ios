import SwiftUI

// MARK: - Prototype shell contract

/// Server URL for the prototype chat, supplied by the prototype shell
/// (WORKER-NAV) via `.environment(\.protoChatServerURL, server)` on the
/// navigation destination. `PrototypeChatView` keeps its prescribed
/// `init(session:profile:)` signature, so the server cannot travel through
/// the initializer.
struct ProtoChatServerURLKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    var protoChatServerURL: URL? {
        get { self[ProtoChatServerURLKey.self] }
        set { self[ProtoChatServerURLKey.self] = newValue }
    }
}

/// Bottom-distance probe for the prototype transcript's follow/reader logic.
private struct ProtoTranscriptBottomDistanceKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

// MARK: - PrototypeChatView

/// The polished prototype chat screen (PROTO-CHAT-01 / WORKER-CHAT).
///
/// Muse-app feel, Semreh identity: the near-black look comes from the
/// existing `chatgpt` palette via `SemrehVisualTheme` tokens (documented
/// choice — no hardcoded grays), the bird avatar stays, and all behavior
/// (send/stream/cancel/retry, reasoning + tool-call state, scrolling) is
/// driven by the real `ChatViewModel` obtained from `OpenChatSessionStore`,
/// never a mock.
///
/// Owned paths: this file only, plus the additive `ChatMotion` presets in
/// `Features/Chat/ChatMotion.swift`. The placeholder
/// `PrototypeChatViewPlaceholder.swift` is superseded by this file.
struct PrototypeChatView: View {
    let session: SessionSummary
    let profile: ProfileSummary

    /// iOS system blue, matching the reference chat app deliberately.
    /// This is NOT a theme token: the reference reserves this exact blue for
    /// user bubbles, the send/stop button, and the scroll-to-bottom
    /// affordance (#0A84FF).
    private static let actionBlue = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    /// Deliberate palette choice (documented): the reference demands
    /// near-black surfaces, and the existing `chatgpt` palette provides them
    /// (#212121 canvas / #2F2F2F panel in dark mode) through
    /// `SemrehVisualTheme` instead of hardcoded hex. Light/dark scheme is
    /// still respected; the user's global palette choice is intentionally
    /// overridden for this prototype surface only.
    private static let palette = AppColorPalette.chatgpt
    private static let bottomAnchorID = "proto-chat-bottom"
    private static let transcriptSpace = "proto-chat-transcript"

    @Environment(\.protoChatServerURL) private var serverURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    @State private var viewModel: ChatViewModel?
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    // Follow/reader scroll state (decisions via ChatScrollPolicy).
    @State private var scrollProxy: ScrollViewProxy?
    @State private var distanceFromBottom: CGFloat = 0
    @State private var isUserInteracting = false
    @State private var cooldownUntil: Date?

    @State private var didCancelStream = false
    @State private var showingDetails = false
    @State private var showingAttachmentsUnavailable = false
    @State private var showingVoiceUnavailable = false

    private let draftStore = ComposerDraftStore.shared

    // MARK: - Body

    var body: some View {
        ZStack {
            SemrehVisualTheme.canvas(for: colorScheme, palette: Self.palette)
                .ignoresSafeArea()

            if let serverURL {
                if let viewModel {
                    chatContent(viewModel, server: serverURL)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(String(localized: "Loading conversation"))
                }
            } else {
                serverMissingView
            }
        }
        .environment(\.appColorPalette, Self.palette)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: serverURL) {
            await resolveViewModel()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
        .onDisappear {
            teardown()
        }
        .alert(
            String(localized: "Attachments unavailable"),
            isPresented: $showingAttachmentsUnavailable
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "File attachments aren't available in this prototype yet."))
        }
        .alert(
            String(localized: "Voice input unavailable"),
            isPresented: $showingVoiceUnavailable
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "Voice input isn't available in this prototype yet."))
        }
        .sheet(isPresented: $showingDetails) {
            detailsSheet
        }
    }

    // MARK: - Content

    private func chatContent(_ vm: ChatViewModel, server: URL) -> some View {
        VStack(spacing: 0) {
            header(vm, server: server)
            transcriptArea(vm)
            composerBar(vm)
        }
        .onChange(of: vm.activeStreamID) { _, newStreamID in
            guard newStreamID == nil else { return }
            if didCancelStream {
                didCancelStream = false
            } else {
                ChatHaptics.assistantResponseCompleted(isEnabled: isHapticsEnabled)
            }
        }
    }

    private var serverMissingView: some View {
        ContentUnavailableView(
            String(localized: "Chat unavailable"),
            systemImage: "exclamationmark.bubble",
            description: Text(String(localized: "The prototype shell must provide a server URL via the protoChatServerURL environment value."))
        )
    }

    // MARK: - Header

    /// Hamburger (back to the conversation list), centered bird avatar with
    /// the name pill + live RunState status pill, and a minimal "..." menu.
    private func header(_ vm: ChatViewModel, server: URL) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .background(headerChromeFill, in: Circle())
                    .overlay(Circle().strokeBorder(headerChromeStroke, lineWidth: 0.5))
            }
            .buttonStyle(.chatTactile(.icon))
            .accessibilityLabel(String(localized: "Back to conversations"))

            Spacer(minLength: 0)

            VStack(spacing: 5) {
                if let identity = BirdAvatarIdentity(server: server, profile: profile.name) {
                    BirdAvatarView(identity: identity)
                        .frame(width: 46, height: 46)
                        .clipShape(Circle())
                }
                namePill(vm)
            }

            Spacer(minLength: 0)

            Menu {
                Button(String(localized: "Details")) {
                    showingDetails = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .background(headerChromeFill, in: Circle())
                    .overlay(Circle().strokeBorder(headerChromeStroke, lineWidth: 0.5))
            }
            .buttonStyle(.chatTactile(.icon))
            .accessibilityLabel(String(localized: "Conversation options"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var headerChromeFill: Color {
        SemrehVisualTheme.panel(for: colorScheme, palette: Self.palette).opacity(0.72)
    }

    private var headerChromeStroke: Color {
        SemrehVisualTheme.subtleStroke(for: colorScheme, palette: Self.palette).opacity(0.6)
    }

    /// Name pill; the status line appears only while the run is live and
    /// settles back to the bare name on completion.
    /// `directConversation` is private to the view model, so the header
    /// derives status from the VM's public run signals instead of reading
    /// `GatewayConversationController.RunState` directly: stopping →
    /// "is stopping", starting/delivery-uncertain → "is responding",
    /// active stream → tool name / "is thinking" / "is working".
    private func namePill(_ vm: ChatViewModel) -> some View {
        let status = runStatusText(vm)
        return VStack(spacing: 1) {
            Text(profile.displayName)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            SemrehVisualTheme.panel(for: colorScheme, palette: Self.palette).opacity(0.85),
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(headerChromeStroke, lineWidth: 0.5)
        )
        .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: status)
    }

    /// Live status derived from the view model's public run signals
    /// (`isCancellingStream`, `isStartingChat`,
    /// `directConversationHasPromptDeliveryUncertainty`, `activeStreamID`),
    /// which mirror `GatewayConversationController.RunState`'s idle /
    /// submitting / running / stopping / deliveryUnknown without touching
    /// the private controller.
    private func runStatusText(_ vm: ChatViewModel) -> String? {
        if vm.isCancellingStream {
            return String(localized: "is stopping")
        }
        if vm.isStartingChat || vm.directConversationHasPromptDeliveryUncertainty {
            return String(localized: "is responding")
        }
        guard vm.activeStreamID != nil else {
            return nil
        }
        if let toolName = vm.liveToolCalls.last?.displayName,
           !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return toolName
        }
        if !vm.liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "is thinking")
        }
        return String(localized: "is working")
    }

    // MARK: - Transcript

    private func transcriptArea(_ vm: ChatViewModel) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if vm.hasOlderMessages {
                            loadOlderButton(vm)
                        }
                        if isShowingSkeleton(vm) {
                            skeletonRows
                        } else {
                            ForEach(transcriptRows(vm), id: \.id) { row in
                                transcriptRow(row, vm: vm, maxBubbleWidth: viewport.size.width * 0.75)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                            .background(
                                GeometryReader { sentinel in
                                    Color.clear.preference(
                                        key: ProtoTranscriptBottomDistanceKey.self,
                                        value: sentinel.frame(in: .named(Self.transcriptSpace)).minY
                                    )
                                }
                            )
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                    .animation(
                        ChatMotion.messageInsert(reduceMotion: reduceMotion),
                        value: transcriptRowIDs(vm)
                    )
                }
                .defaultScrollAnchor(shouldFollowLatest(vm) ? .bottom : nil)
                .coordinateSpace(name: Self.transcriptSpace)
                .onPreferenceChange(ProtoTranscriptBottomDistanceKey.self) { minY in
                    guard let minY else { return }
                    distanceFromBottom = max(0, viewport.size.height - minY)
                }
                .onScrollPhaseChange { _, phase in
                    let interacting = phase == .interacting
                    if isUserInteracting, !interacting {
                        cooldownUntil = ChatScrollPolicy.cooldownDeadline()
                    }
                    isUserInteracting = interacting
                }
                .onAppear {
                    scrollProxy = proxy
                    // Pin to the tail on first paint when cached messages are
                    // already rendered; the post-load pin in resolveViewModel
                    // covers the fresh-fetch case.
                    scrollToBottom(proxy: proxy, animated: false)
                }
                .overlay(alignment: .bottom) {
                    transcriptOverlays(vm, proxy: proxy)
                }
            }
        }
    }

    // MARK: Scroll decisions (ChatScrollPolicy)

    private func isStreaming(_ vm: ChatViewModel) -> Bool {
        vm.activeStreamID != nil
    }

    private func isNearBottom(_ vm: ChatViewModel) -> Bool {
        ChatScrollPolicy.isNearBottom(
            distanceFromBottom: distanceFromBottom,
            isStreaming: isStreaming(vm)
        )
    }

    private func shouldFollowLatest(_ vm: ChatViewModel) -> Bool {
        isNearBottom(vm)
            && !ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: isUserInteracting,
                cooldownUntil: cooldownUntil
            )
    }

    private func scrollToBottom(proxy: ScrollViewProxy?, animated: Bool) {
        guard let proxy else { return }
        cooldownUntil = nil
        isUserInteracting = false
        if animated, let animation = ChatMotion.scrollToLatest(reduceMotion: reduceMotion) {
            withAnimation(animation) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    // MARK: Transcript overlays (never shift the conversation)

    /// Floating overlays pinned above the composer: the quiet active-run
    /// pill, the inline error banner, and the scroll-to-bottom affordance.
    /// Overlays — not transcript rows — so status pills and errors never
    /// move message layout.
    private func transcriptOverlays(_ vm: ChatViewModel, proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            if let presentation = activeRunPresentation(vm) {
                ChatActiveRunStatusView(presentation: presentation)
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            }
            if let errorText = inlineErrorText(vm) {
                errorBanner(text: errorText, vm: vm)
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            }
            if ChatScrollPolicy.shouldShowScrollToBottomButton(
                isNearBottom: isNearBottom(vm),
                hasExplicitBottomRequest: false,
                hasActiveStream: isStreaming(vm),
                shouldFollowLatestMessage: shouldFollowLatest(vm)
            ) {
                scrollToBottomButton(proxy: proxy)
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(
            ChatMotion.quickState(reduceMotion: reduceMotion),
            value: overlaySignature(vm)
        )
    }

    private func overlaySignature(_ vm: ChatViewModel) -> String {
        let run = activeRunPresentation(vm) != nil
        let error = inlineErrorText(vm) != nil
        let scroll = ChatScrollPolicy.shouldShowScrollToBottomButton(
            isNearBottom: isNearBottom(vm),
            hasExplicitBottomRequest: false,
            hasActiveStream: isStreaming(vm),
            shouldFollowLatestMessage: shouldFollowLatest(vm)
        )
        return "\(run)-\(error)-\(scroll)"
    }

    /// The existing quiet active-run pill, reused as-is; the elapsed readout
    /// gate is intentionally left off in the prototype because the header
    /// status pill already covers near-bottom runs, so the floating pill only
    /// appears when the reader has scrolled away (per
    /// `ChatActiveRunElapsedPolicy`'s scrolled-away rule).
    private func activeRunPresentation(_ vm: ChatViewModel) -> ChatActiveRunStatusPresentation? {
        ChatActiveRunStatusPolicy.presentation(
            isStartingChat: vm.isStartingChat,
            hasActiveStream: isStreaming(vm),
            activeStreamRecoveryState: vm.activeStreamRecoveryState,
            isCancellingStream: vm.isCancellingStream,
            isScrolledNearBottom: isNearBottom(vm),
            isEstablishingConnection: vm.isEstablishingConnection,
            activeRunStartedAt: vm.activeRunStartedAt,
            hasActiveRunPassedElapsedThreshold: false
        )
    }

    private func inlineErrorText(_ vm: ChatViewModel) -> String? {
        vm.sendErrorMessage ?? vm.errorMessage
    }

    private func errorBanner(text: String, vm: ChatViewModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(3)
            Spacer(minLength: 8)
            if vm.sendErrorMessage != nil {
                Button(String(localized: "Retry")) {
                    retrySend(vm)
                }
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(Self.actionBlue)
            }
            Button {
                vm.setSendErrorMessage(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(String(localized: "Dismiss error"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            SemrehVisualTheme.panel(for: colorScheme, palette: Self.palette),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    SemrehVisualTheme.subtleStroke(for: colorScheme, palette: Self.palette),
                    lineWidth: 0.5
                )
        )
    }

    private func retrySend(_ vm: ChatViewModel) {
        vm.setSendErrorMessage(nil)
        guard let lastAssistant = vm.displayedTranscriptMessages.last(where: { $0.message.role == "assistant" }),
              let context = vm.actionContext(
                  for: lastAssistant.message,
                  visibleIndex: lastAssistant.loadedIndex
              )
        else { return }
        Task {
            await vm.regenerateAssistantResponse(context)
        }
    }

    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(proxy: proxy, animated: true)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Self.actionBlue, in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
        .buttonStyle(.chatTactile(.icon))
        .accessibilityLabel(String(localized: "Scroll to latest message"))
    }

    private func loadOlderButton(_ vm: ChatViewModel) -> some View {
        Button {
            Task {
                await vm.loadOlderMessages()
            }
        } label: {
            if vm.isLoadingOlderMessages {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                Text(String(localized: "Load earlier messages"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .buttonStyle(.plain)
        .disabled(vm.isLoadingOlderMessages)
        .accessibilityLabel(String(localized: "Load earlier messages"))
    }

    /// Cached messages render immediately on first paint; the skeleton only
    /// appears when there is genuinely nothing to show yet.
    private func isShowingSkeleton(_ vm: ChatViewModel) -> Bool {
        vm.isLoading && vm.displayedTranscriptMessages.isEmpty && !vm.hasPreservedTranscript
    }

    private var skeletonRows: some View {
        ForEach(0..<3, id: \.self) { index in
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.secondary.opacity(0.15))
                .frame(height: index == 1 ? 120 : 64)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Transcript rows

    private enum TranscriptRow {
        case separator(id: String, title: String)
        case message(id: String, message: TranscriptMessage)

        var id: String {
            switch self {
            case .separator(let id, _):
                return id
            case .message(let id, _):
                return id
            }
        }
    }

    /// Messages interleaved with centered day separators. Row identity is
    /// the message's own ID (assigned once — `"stream-…"`, `"local-…"`, or
    /// the server ID — and never changed by streaming updates), so
    /// per-token text changes never recreate rows or retrigger the
    /// insertion animation. `renderID` is deliberately NOT used here: it
    /// folds in a content hash that changes on every streaming token.
    private func transcriptRows(_ vm: ChatViewModel) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(vm.displayedTranscriptMessages.count)
        var lastDay: Date?
        for transcriptMessage in vm.displayedTranscriptMessages {
            if let day = dayStart(for: transcriptMessage.message.timestamp), day != lastDay {
                rows.append(.separator(
                    id: "day-\(day.timeIntervalSince1970)",
                    title: dayTitle(for: day)
                ))
                lastDay = day
            }
            rows.append(.message(
                id: stableRowID(for: transcriptMessage),
                message: transcriptMessage
            ))
        }
        return rows
    }

    /// Stable identity for a transcript row. `messageId` is assigned once
    /// when the message is created and never changes during streaming; the
    /// index fallback only covers transient messages without an ID yet.
    private func stableRowID(for transcriptMessage: TranscriptMessage) -> String {
        if let messageId = transcriptMessage.message.messageId, !messageId.isEmpty {
            return messageId
        }
        return "pending-\(transcriptMessage.message.role ?? "?")-\(transcriptMessage.loadedIndex)"
    }

    private func transcriptRowIDs(_ vm: ChatViewModel) -> [String] {
        transcriptRows(vm).map(\.id)
    }

    private func dayStart(for timestamp: Double?) -> Date? {
        guard let timestamp else { return nil }
        return Calendar.current.startOfDay(for: Date(timeIntervalSince1970: timestamp))
    }

    private func dayTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) {
            return String(localized: "Today")
        }
        if calendar.isDateInYesterday(day) {
            return String(localized: "Yesterday")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }

    @ViewBuilder
    private func transcriptRow(
        _ row: TranscriptRow,
        vm: ChatViewModel,
        maxBubbleWidth: CGFloat
    ) -> some View {
        switch row {
        case .separator(_, let title):
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
        case .message(_, let transcriptMessage):
            messageBlock(transcriptMessage, vm: vm, maxBubbleWidth: maxBubbleWidth)
                .transition(ChatMotion.messageInsertTransition(reduceMotion: reduceMotion))
        }
    }

    /// One transcript block: reasoning disclosures, live reasoning, tool
    /// activity groups, live tool activity, then the message itself — the
    /// same composition order as the production transcript.
    private func messageBlock(
        _ transcriptMessage: TranscriptMessage,
        vm: ChatViewModel,
        maxBubbleWidth: CGFloat
    ) -> some View {
        let message = transcriptMessage.message
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(vm.displayedReasoningGroupsForAnchor(transcriptMessage.anchorID)) { group in
                ReasoningBlockView(text: group.text, segments: group.segments)
            }
            if isLiveReasoningVisible(vm, anchorID: transcriptMessage.anchorID) {
                ReasoningBlockView(text: vm.liveReasoningText, isActive: true)
            }
            ForEach(vm.completedToolCallGroupsForAnchor(transcriptMessage.anchorID)) { group in
                ToolActivityGroupView(group: group)
            }
            if isLiveToolActivityVisible(vm, anchorID: transcriptMessage.anchorID) {
                ToolActivityGroupView(group: ToolCallGroup.live(
                    anchorMessageID: transcriptMessage.anchorID,
                    toolCalls: vm.liveToolCalls
                ))
            }
            if shouldRenderMessageRow(message) {
                messageContent(message, vm: vm, maxBubbleWidth: maxBubbleWidth)
            }
        }
    }

    private func isLiveReasoningVisible(_ vm: ChatViewModel, anchorID: String) -> Bool {
        isStreaming(vm)
            && vm.reasoningAnchorMessageID == anchorID
            && !vm.liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isLiveToolActivityVisible(_ vm: ChatViewModel, anchorID: String) -> Bool {
        isStreaming(vm)
            && vm.toolCallAnchorMessageID == anchorID
            && !vm.liveToolCalls.isEmpty
    }

    /// Same row-visibility rule as the production chat: non-empty content, or
    /// a user message carrying attachments.
    private func shouldRenderMessageRow(_ message: ChatMessage) -> Bool {
        if message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        return message.role == "user" && message.attachments?.isEmpty == false
    }

    @ViewBuilder
    private func messageContent(
        _ message: ChatMessage,
        vm: ChatViewModel,
        maxBubbleWidth: CGFloat
    ) -> some View {
        if message.role == "user" {
            userBubble(
                text: message.content ?? "",
                attachments: message.attachments,
                maxWidth: maxBubbleWidth
            )
        } else {
            MarkdownRenderer(
                content: message.content ?? "",
                isStreaming: message.messageId != nil
                    && message.messageId == vm.streamingAssistantMessageID
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    private func userBubble(
        text: String,
        attachments: [MessageAttachment]?,
        maxWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.white)
                }
                if let attachments, !attachments.isEmpty {
                    Label(
                        String(localized: "\(attachments.count) attachments"),
                        systemImage: "paperclip"
                    )
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Self.actionBlue,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .frame(maxWidth: maxWidth, alignment: .trailing)
            .accessibilityLabel(text.isEmpty ? String(localized: "Attachment message") : text)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Composer

    /// Dark rounded bar: "+" (attachments — honestly unavailable in the
    /// prototype), "Message in <chat name>…" field, mic (voice — honestly
    /// unavailable), and the action button: blue up-arrow to send, blue
    /// stop-square to cancel while streaming.
    private func composerBar(_ vm: ChatViewModel) -> some View {
        let streaming = isStreaming(vm)
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !streaming
        return HStack(spacing: 2) {
            Button {
                showingAttachmentsUnavailable = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.chatTactile(.icon))
            .accessibilityLabel(String(localized: "Add attachment"))

            TextField(
                String(localized: "Message in \(chatName(vm))…"),
                text: $draft,
                axis: .vertical
            )
            .lineLimit(1...4)
            .font(.body)
            .focused($composerFocused)

            Button {
                showingVoiceUnavailable = true
            } label: {
                Image(systemName: "mic")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.chatTactile(.icon))
            .accessibilityLabel(String(localized: "Voice input"))

            Group {
                if streaming {
                    Button {
                        cancelStream(vm)
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Self.actionBlue, in: Circle())
                    }
                    .buttonStyle(.chatTactile(.icon))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel(String(localized: "Stop responding"))
                } else if canSend {
                    Button {
                        sendDraft(vm)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Self.actionBlue, in: Circle())
                    }
                    .buttonStyle(.chatTactile(.icon))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel(String(localized: "Send message"))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            SemrehVisualTheme.panel(for: colorScheme, palette: Self.palette),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    SemrehVisualTheme.subtleStroke(for: colorScheme, palette: Self.palette),
                    lineWidth: 0.5
                )
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(ChatMotion.composerChrome(reduceMotion: reduceMotion), value: streaming)
        .animation(ChatMotion.composerChrome(reduceMotion: reduceMotion), value: canSend)
    }

    private func chatName(_ vm: ChatViewModel) -> String {
        let title = vm.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? profile.displayName : title
    }

    private func sendDraft(_ vm: ChatViewModel) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming(vm) else { return }
        draft = ""
        scrollToBottom(proxy: scrollProxy, animated: true)
        Task {
            let started = await vm.sendMessage(text)
            if started {
                ChatHaptics.messageSent(isEnabled: isHapticsEnabled)
            } else if draft.isEmpty {
                draft = text
            }
        }
    }

    private func cancelStream(_ vm: ChatViewModel) {
        didCancelStream = true
        Task {
            let cancelled = await vm.cancelActiveStream()
            if cancelled {
                ChatHaptics.streamCancelled(isEnabled: isHapticsEnabled)
            }
        }
    }

    // MARK: - Details sheet (read-only, real profile data)

    private var detailsSheet: some View {
        NavigationStack {
            List {
                LabeledContent(
                    String(localized: "Name"),
                    value: profile.displayName
                )
                if let model = profile.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !model.isEmpty
                {
                    LabeledContent(String(localized: "Model"), value: model)
                }
                if let provider = profile.provider?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !provider.isEmpty
                {
                    LabeledContent(String(localized: "Provider"), value: provider)
                }
                if let skillCount = profile.skillCount {
                    LabeledContent(
                        String(localized: "Skills"),
                        value: "\(skillCount)"
                    )
                }
            }
            .navigationTitle(String(localized: "Details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        showingDetails = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - View-model lifecycle (real gateway path only)

    /// Resolves the view model exclusively through `OpenChatSessionStore`,
    /// which injects the direct-Hermes gateway runtime provider — the same
    /// path the production `ChatView` uses.
    private func resolveViewModel() async {
        guard viewModel == nil, let server = serverURL else { return }
        let sessionID = session.sessionId ?? session.id
        draft = draftStore.load(server: server, sessionID: sessionID)
        let vm = OpenChatSessionStore.shared.viewModel(session: session, server: server)
        viewModel = vm
        vm.startSessionEventSync()
        await vm.loadMessages()
        await vm.reconnectStreamIfNeeded()
        // Cached messages render immediately; pin to the tail before the user
        // sees the view (ChatScrollPolicy.initialTranscriptAnchor).
        scrollToBottom(proxy: scrollProxy, animated: false)
    }

    private func teardown() {
        persistDraft()
        viewModel?.stopSessionEventSync()
    }

    private func persistDraft() {
        if let server = serverURL {
            draftStore.save(draft, server: server, sessionID: session.sessionId ?? session.id)
        }
    }

    // MARK: - Scene lifecycle

    /// Background/foreground parity with the production `ChatView`: on
    /// background the transcript presentation pauses and the draft is
    /// persisted; on foreground the view model reconciles the transcript
    /// (cached-first, no jump) and re-attaches any live stream via
    /// `refreshAfterSceneActivation` (which calls `reconnectStreamIfNeeded`).
    /// The per-session event sync keeps running across backgrounding exactly
    /// like production — it only stops when the chat is left (`.onDisappear`).
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        guard let vm = viewModel else { return }
        switch phase {
        case .background:
            vm.setTranscriptPresentationActive(false)
            persistDraft()
        case .active:
            vm.setTranscriptPresentationActive(true)
            Task {
                await vm.refreshAfterSceneActivation()
            }
        case .inactive:
            vm.setTranscriptPresentationActive(false)
        @unknown default:
            break
        }
    }
}
