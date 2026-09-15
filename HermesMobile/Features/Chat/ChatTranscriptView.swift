import OSLog
import SwiftUI
import UIKit

private struct VisibleTranscriptRowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

enum ChatTranscriptRenderSequence {
    static func includes(
        _ transcriptMessage: TranscriptMessage,
        showsThinkingAndToolCards: Bool,
        compressionAfterRenderID: String?,
        reasoningGroupsForAnchor: (String?) -> [ReasoningGroup],
        toolCallGroupsForAnchor: (String?) -> [ToolCallGroup],
        liveAccessoryAnchorIDs: Set<String>,
        shouldRenderMessage: (ChatMessage) -> Bool
    ) -> Bool {
        shouldRenderMessage(transcriptMessage.message)
            || compressionAfterRenderID == transcriptMessage.renderID
            || (showsThinkingAndToolCards
                && (!reasoningGroupsForAnchor(transcriptMessage.anchorID).isEmpty
                    || !toolCallGroupsForAnchor(transcriptMessage.anchorID).isEmpty
                    || liveAccessoryAnchorIDs.contains(transcriptMessage.anchorID)))
    }

    static func filtering(
        _ messages: [TranscriptMessage],
        showsThinkingAndToolCards: Bool,
        compressionAfterRenderID: String?,
        reasoningGroupsForAnchor: (String?) -> [ReasoningGroup],
        toolCallGroupsForAnchor: (String?) -> [ToolCallGroup],
        liveAccessoryAnchorIDs: Set<String>,
        shouldRenderMessage: (ChatMessage) -> Bool
    ) -> [TranscriptMessage] {
        messages.filter {
            includes(
                $0,
                showsThinkingAndToolCards: showsThinkingAndToolCards,
                compressionAfterRenderID: compressionAfterRenderID,
                reasoningGroupsForAnchor: reasoningGroupsForAnchor,
                toolCallGroupsForAnchor: toolCallGroupsForAnchor,
                liveAccessoryAnchorIDs: liveAccessoryAnchorIDs,
                shouldRenderMessage: shouldRenderMessage
            )
        }
    }
}

/// Preference and UIKit metrics arrive at frame/layout frequency. Keep their
/// small amount of bookkeeping in a stable reference so recording an anchor
/// does not invalidate the entire transcript body on every sample.
private final class ChatTranscriptViewportTracker {
    weak var scrollView: UIScrollView?
    var visibleRowID: String?
    var visibleRowFrame: CGRect?
    var viewportHeight: CGFloat = 0
    var activationRecoveryState = ChatTranscriptActivationRecoveryState()
    var latestFrames: [String: CGRect] = [:]
    var framesGeneration = 0
    var activationBaselineFramesGeneration = 0
    var latestScrollMetrics: ChatScrollMetrics?
    var olderMessagesLoadInFlight = false
    var pendingOlderMessagesAnchor: ChatTranscriptViewportAnchor?
    var pendingOlderMessagesLoadCompleted = false
    var pendingOlderMessagesBaselineMessageCount: Int?
    var pendingOlderMessagesBaselineRenderRevision: Int?
    var pendingOlderMessagesBaselineFirstLoadedRowID: String?
    var lastOlderMessagesPrefetchVisibleRowID: String?
}

struct ChatTranscriptActivationRecoveryState: Equatable {
    private(set) var hasObservedRows = false
    private(set) var isArmed = false

    mutating func recordPreferenceSample(hasVisibleMessageRows: Bool) {
        if hasVisibleMessageRows {
            hasObservedRows = true
        }
    }

    @discardableResult
    mutating func armForActivation() -> Bool {
        isArmed = hasObservedRows
        return isArmed
    }

    mutating func disarm() {
        isArmed = false
    }

    mutating func reset() {
        hasObservedRows = false
        isArmed = false
    }
}

enum ChatTranscriptActivationProbeDisposition: Equatable {
    case freshGeometryArrived
    case evaluateEmptyCache
    case waitForFreshGeometry(visibleCachedRowCount: Int)

    static func resolve(
        currentFramesGeneration: Int,
        activationBaselineFramesGeneration: Int,
        cachedFrameCount: Int,
        visibleCachedRowCount: Int
    ) -> Self {
        if currentFramesGeneration > activationBaselineFramesGeneration {
            return .freshGeometryArrived
        }
        return cachedFrameCount == 0
            ? .evaluateEmptyCache
            : .waitForFreshGeometry(visibleCachedRowCount: visibleCachedRowCount)
    }
}

struct ChatTranscriptView: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let isLoading: Bool
    let errorMessage: String?
    let messages: [ChatMessage]
    let displayedTranscriptMessages: [TranscriptMessage]
    let compressionReferenceCard: CompressionReferenceCard?
    let reasoningGroupsForAnchor: (String?) -> [ReasoningGroup]
    let completedToolCallGroupsForAnchor: (String?) -> [ToolCallGroup]
    let liveReasoningText: String
    let reasoningAnchorMessageID: String?
    let liveToolCalls: [ToolCall]
    let toolCallAnchorMessageID: String?
    let streamingAssistantMessageID: String?
    let liveTokensPerSecond: Double?
    let activeStreamRecoveryState: ActiveStreamRecoveryState
    let clarificationPrompt: ClarificationPromptState?
    let isRespondingToClarification: Bool
    let clarificationErrorMessage: String?
    let hidesRunStatusAccessibility: Bool
    let showsThinkingAndToolCards: Bool
    let showsAssistantTypingIndicator: Bool
    let showsScrollToBottomButton: Bool
    var hasExplicitBottomScrollRequest = false
    let shouldFollowLatestMessage: Bool
    let latestTranscriptMessageRole: String?
    let isScrolledNearBottom: Bool
    let activeStreamID: String?
    let streamingScrollTrigger: Int
    let cacheFirstReconcileScrollToken: Int
    let bottomAnchorID: String
    let transcriptMessageSpacing: CGFloat
    let transcriptBlockSpacing: CGFloat
    let transcriptBottomInsetHeight: CGFloat
    let scrollToBottomButtonBottomPadding: CGFloat
    let localAttachmentPreviews: [String: [String: Data]]
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasOlderMessages: Bool
    let isLoadingOlderMessages: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let loadAttachmentImage: (String) async -> Data?
    let loadAttachmentData: (String) async -> Data?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let actionContext: (ChatMessage, Int) -> MessageActionContext?
    let shouldRenderMessageRow: (ChatMessage) -> Bool
    let onLoadMessages: () async -> Void
    let onLoadOlderMessages: () async -> Bool
    let onUpdateScrollMetrics: (ChatScrollMetrics) -> Void
    let onDismissKeyboard: () -> Void
    let onScrollToBottom: (ScrollViewProxy) -> Void
    let onScrollToLatestTranscriptMessage: (ScrollViewProxy) -> Void
    let onScrollToLatestContent: (ScrollViewProxy, Bool) -> Void
    var onScrollToTranscriptMessage: (ScrollViewProxy, String, Bool) -> Void = { _, _, _ in }
    var onVisibleTranscriptRowIDChange: (String?) -> Void = { _ in }
    var onTranscriptTailVisibilityChange: (_ latestRow: Bool, _ bottom: Bool) -> Void = { _, _ in }
    let onPreviewAttachment: (MessageAttachment, Data?) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onSubmitClarification: (String, GatewayBlockingPromptIdentity?) -> Void
    let onCancelClarification: (GatewayBlockingPromptIdentity?) -> Void
    let onSelectText: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void
    /// Non-nil shows the inline "Commit & Push" button under the latest assistant turn
    /// (issue #315, Slice C, surface B). Nil hides it (non-git chats, no changes, etc.).
    var inlineCommitContext: ChatInlineCommitContext? = nil
    var onInlineCommit: () -> Void = {}
    /// Non-nil shows the turn-end "File changes" recap card under the latest assistant turn
    /// (issue #316, Slice D, surface B). Nil hides it (non-git chats, no changes, streaming).
    var turnChangesSummary: TurnFileChangeSummary? = nil
    var onOpenTurnDiff: () -> Void = {}
    var onOpenTurnFileDiff: (GitFile) -> Void = { _ in }
    var restoreScrollToken: Int = 0
    var restoreTarget: ChatTranscriptRestoreTarget = .latest
    var transcriptRestoreCancellationToken: Int = 0
    var followRejoinScrollToken: Int = 0
    var isComposerResizing = false
    var transcriptRenderRevision = 0
    var outgoingInsertionScope: UUID?
    var outgoingInsertionEvent: OutgoingInsertionEvent?
    @State private var insertionLedger = OutgoingInsertionLedger()

    @State private var viewportTracker = ChatTranscriptViewportTracker()
    @State private var restoreSettlementTask: Task<Void, Never>?
    @State private var restoreSettlementState = ChatTranscriptRestoreState()
#if DEBUG
    @State private var pendingMessageCountDiagnostic: Int?
    @State private var hasLoggedExplicitBottomTarget = false
#endif
    private static let transcriptCoordinateSpaceName = "chatTranscript"
#if DEBUG
    private static let activationRecoveryLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "TranscriptActivationRecovery"
    )
#endif

    private var renderedTranscriptMessages: [TranscriptMessage] {
        return ChatTranscriptRenderSequence.filtering(
            displayedTranscriptMessages,
            showsThinkingAndToolCards: showsThinkingAndToolCards,
            compressionAfterRenderID: compressionReferenceCard?.afterRenderID,
            reasoningGroupsForAnchor: reasoningGroupsForAnchor,
            toolCallGroupsForAnchor: completedToolCallGroupsForAnchor,
            liveAccessoryAnchorIDs: liveAccessoryAnchorIDs,
            shouldRenderMessage: shouldRenderMessageRow
        )
    }

    private var liveAccessoryAnchorIDs: Set<String> {
        guard showsThinkingAndToolCards, activeStreamID != nil else { return [] }
        var anchorIDs = Set<String>()
        if hasLiveReasoningText, let reasoningAnchorMessageID {
            anchorIDs.insert(reasoningAnchorMessageID)
        }
        if !liveToolCalls.isEmpty, let toolCallAnchorMessageID {
            anchorIDs.insert(toolCallAnchorMessageID)
        }
        return anchorIDs
    }

    var body: some View {
        ZStack {
        if isLoading && messages.isEmpty && clarificationPrompt == nil {
            ChatTranscriptLoadingSkeletonView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, messages.isEmpty, clarificationPrompt == nil {
            ContentUnavailableView {
                Label("Could Not Load Messages", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await onLoadMessages() }
                }
            }
        } else if messages.isEmpty && clarificationPrompt == nil {
            ContentUnavailableView {
                Image(systemName: "bubble.left.and.bubble.right")
            } description: {
                Text("Send a message to start the conversation.")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onDismissKeyboard()
            }
        } else {
            transcriptScrollView
        }
        }
        .onAppear { insertionLedger.mount(scope: outgoingInsertionScope, through: outgoingInsertionEvent?.sequence ?? 0) }
        .onDisappear { insertionLedger.unmount() }
        .onChange(of: outgoingInsertionScope) { _, scope in
            insertionLedger.mount(scope: scope, through: outgoingInsertionEvent?.sequence ?? 0)
            resetViewportForNewTranscript()
        }
        .onChange(of: restoreScrollToken) { _, _ in
            insertionLedger.discardPending(through: outgoingInsertionEvent?.sequence ?? 0)
        }
        .onChange(of: shouldFollowLatestMessage) { _, follows in
            if !follows { insertionLedger.discardPending(through: outgoingInsertionEvent?.sequence ?? 0) }
        }
        .onChange(of: outgoingInsertionEvent) { _, event in
            if !shouldFollowLatestMessage || restoreSettlementTask != nil {
                insertionLedger.discardPending(through: event?.sequence ?? 0)
            }
        }
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                let viewportWidth = max(0, viewport.size.width)
                let contentWidth = transcriptContentWidth(for: viewportWidth)
                let renderedMessages = renderedTranscriptMessages
                let latestRenderedID = renderedMessages.last?.renderID

                ZStack(alignment: .bottom) {
                    ScrollView {
                        transcriptScrollContent(
                            proxy: proxy,
                            viewportWidth: viewportWidth,
                            contentWidth: contentWidth,
                            renderedMessages: renderedMessages
                        )
                    }
                    .defaultScrollAnchor(
                        ChatScrollPolicy.initialTranscriptAnchor,
                        for: .initialOffset
                    )
                    .defaultScrollAnchor(
                        ChatScrollPolicy.sizeChangeAnchor(
                            shouldFollowLatestMessage: shouldFollowLatestMessage,
                            isComposerResizing: isComposerResizing
                        ),
                        for: .sizeChanges
                    )
                    .frame(width: viewportWidth)
                    .refreshable {
                        if hasOlderMessages {
                            await loadOlderMessagesPreservingPosition(proxy: proxy)
                        } else {
                            await onLoadMessages()
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .coordinateSpace(name: Self.transcriptCoordinateSpaceName)
                    .accessibilityIdentifier("chat-transcript-scroll")
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear
                            .frame(height: transcriptBottomInsetHeight)
                            .accessibilityHidden(true)
                    }
                    .adaptiveSoftScrollEdges()
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            guard clarificationPrompt == nil else { return }
                            onDismissKeyboard()
                        }
                    )

                    ZStack {
                        if showsScrollToBottomButton {
                            ChatScrollToBottomButton(
                                bottomPadding: scrollToBottomButtonBottomPadding,
                                onTap: {
#if DEBUG
                                    let frames = viewportTracker.latestFrames
                                    let latestRowVisible = ChatTranscriptVisibilityPolicy.isVisible(
                                        frame: latestRenderedID.flatMap { frames[$0] },
                                        viewportHeight: viewport.size.height,
                                        bottomInset: transcriptBottomInsetHeight
                                    )
                                    let tailVisible = ChatTranscriptVisibilityPolicy.isVisible(
                                        frame: frames[bottomAnchorID],
                                        viewportHeight: viewport.size.height,
                                        bottomInset: transcriptBottomInsetHeight
                                    )
                                    logTranscriptScrollSnapshot(
                                        event: "explicit_bottom_tap",
                                        decision: "dispatch_scroll_request",
                                        viewportHeight: viewport.size.height,
                                        targetKind: "latest_row_or_tail",
                                        targetExists: latestRenderedID != nil,
                                        targetVisible: latestRowVisible || tailVisible,
                                        attempt: 0
                                    )
#endif
                                    cancelTranscriptRestore()
                                    onScrollToBottom(proxy)
                                }
                            )
                            .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                        }
                    }
                    // Animate the affordance, not coincident lazy transcript
                    // measurements or content-offset corrections beneath it.
                    .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsScrollToBottomButton)
                }
                .background(Color.clear)
                .onAppear {
                    // A tab/navigation return may reuse the transcript view
                    // without a new restore token. Arm only a geometry check;
                    // the preference callback decides whether any recovery is
                    // actually needed.
                    viewportTracker.activationRecoveryState.armForActivation()
                    viewportTracker.activationBaselineFramesGeneration = viewportTracker.framesGeneration
#if DEBUG
                    if viewportTracker.activationRecoveryState.isArmed {
                        logTranscriptScrollSnapshot(
                            event: "appear_armed",
                            decision: "await_fresh_geometry",
                            viewportHeight: viewport.size.height
                        )
                    }
#endif
                    scheduleActivationRecoveryProbe(
                        proxy: proxy,
                        viewportHeight: viewport.size.height,
                        latestRenderedID: latestRenderedID
                    )
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    // Foregrounding is not itself a reason to scroll. Wait for
                    // the next realized-row sample before deciding whether the
                    // retained viewport is blank or out of range.
                    viewportTracker.activationRecoveryState.armForActivation()
                    viewportTracker.activationBaselineFramesGeneration = viewportTracker.framesGeneration
#if DEBUG
                    if viewportTracker.activationRecoveryState.isArmed {
                        logTranscriptScrollSnapshot(
                            event: "foreground_armed",
                            decision: "await_fresh_geometry",
                            viewportHeight: viewport.size.height
                        )
                    }
#endif
                    scheduleActivationRecoveryProbe(
                        proxy: proxy,
                        viewportHeight: viewport.size.height,
                        latestRenderedID: latestRenderedID
                    )
                }
                .onChange(of: messages.count) {
                    let isLatestUserRow = latestTranscriptMessageRole == "user"
#if DEBUG
                    let frames = viewportTracker.latestFrames
                    let latestRowVisible = ChatTranscriptVisibilityPolicy.isVisible(
                        frame: latestRenderedID.flatMap { frames[$0] },
                        viewportHeight: viewport.size.height,
                        bottomInset: transcriptBottomInsetHeight
                    )
                    let tailVisible = ChatTranscriptVisibilityPolicy.isVisible(
                        frame: frames[bottomAnchorID],
                        viewportHeight: viewport.size.height,
                        bottomInset: transcriptBottomInsetHeight
                    )
                    let isOutgoingUserInsertion = isLatestUserRow
                        && outgoingInsertionEvent?.scope == outgoingInsertionScope
                        && outgoingInsertionEvent?.messageID == latestRenderedID
                    logTranscriptScrollSnapshot(
                        event: "message_count_change",
                        decision: shouldFollowLatestMessage
                            ? (isLatestUserRow ? "follow_latest_user_row" : "follow_latest_content")
                            : "preserve_reader_position",
                        viewportHeight: viewport.size.height,
                        targetKind: isLatestUserRow ? "latest_row" : "latest_content",
                        targetExists: latestRenderedID != nil,
                        targetVisible: isLatestUserRow ? latestRowVisible : tailVisible,
                        attempt: 0,
                        outgoingUserInsertion: isOutgoingUserInsertion
                    )
#endif
                    guard shouldFollowLatestMessage else { return }
#if DEBUG
                    pendingMessageCountDiagnostic = messages.count
#endif

                    if isLatestUserRow {
                        onScrollToLatestTranscriptMessage(proxy)
                    } else {
                        onScrollToLatestContent(proxy, true)
                    }
                }
                .onChange(of: streamingScrollTrigger) {
                    guard ChatScrollPolicy.shouldProgrammaticallyFollowStreamTokens(
                        shouldFollowLatestMessage: shouldFollowLatestMessage
                    ) else { return }
                    onScrollToLatestContent(proxy, true)
                }
                .onChange(of: restoreScrollToken, initial: true) {
                    // The loaded branch may first mount with a pending request.
                    // Observing only later changes misses that initial restore.
                    guard restoreScrollToken > 0 else { return }
                    applyTranscriptRestore(proxy, viewportHeight: viewport.size.height)
                }
                .onChange(of: transcriptRestoreCancellationToken) {
                    cancelTranscriptRestore()
                }
#if DEBUG
                .onChange(of: hasExplicitBottomScrollRequest) { _, active in
                    hasLoggedExplicitBottomTarget = false
                    let frames = viewportTracker.latestFrames
                    let latestRowVisible = ChatTranscriptVisibilityPolicy.isVisible(
                        frame: latestRenderedID.flatMap { frames[$0] },
                        viewportHeight: viewport.size.height,
                        bottomInset: transcriptBottomInsetHeight
                    )
                    let tailVisible = ChatTranscriptVisibilityPolicy.isVisible(
                        frame: frames[bottomAnchorID],
                        viewportHeight: viewport.size.height,
                        bottomInset: transcriptBottomInsetHeight
                    )
                    logTranscriptScrollSnapshot(
                        event: active ? "explicit_bottom_state_started" : "explicit_bottom_state_ended",
                        decision: active ? "settling" : "ended",
                        viewportHeight: viewport.size.height,
                        targetKind: "latest_row_or_tail",
                        targetExists: latestRenderedID != nil,
                        targetVisible: latestRowVisible || tailVisible,
                        attempt: 0
                    )
                }
#endif
                .onDisappear {
                    restoreSettlementTask?.cancel()
                    restoreSettlementTask = nil
                    viewportTracker.activationRecoveryState.disarm()
                }
                .onChange(of: followRejoinScrollToken) {
                    guard followRejoinScrollToken > 0 else { return }
                    onScrollToLatestContent(proxy, false)
                }
                .onChange(of: cacheFirstReconcileScrollToken) {
                    // Cache-first reconcile (#289): the server transcript just replaced
                    // the lighter cached render, so snap back to the bottom (no
                    // animation) unless the reader has scrolled away in the meantime.
                    guard shouldFollowLatestMessage else { return }
                    onScrollToLatestContent(proxy, false)
                }
                .onChange(of: clarificationPrompt?.id) {
                    guard clarificationPrompt != nil, shouldFollowLatestMessage else { return }
                    onScrollToBottom(proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    guard shouldFollowLatestMessage, isScrolledNearBottom else { return }
                    onScrollToLatestContent(proxy, false)
                }
                .onPreferenceChange(VisibleTranscriptRowFramesKey.self) { frames in
                    viewportTracker.latestFrames = frames
                    viewportTracker.framesGeneration += 1
                    let latestFrame = latestRenderedID.flatMap { frames[$0] }
                    func isVisible(_ frame: CGRect?) -> Bool {
                        ChatTranscriptVisibilityPolicy.isVisible(
                            frame: frame,
                            viewportHeight: viewport.size.height,
                            bottomInset: transcriptBottomInsetHeight
                        )
                    }
                    let isLatestRowVisible = isVisible(latestFrame)
                    let isBottomVisible = isVisible(frames[bottomAnchorID])
#if DEBUG
                    if pendingMessageCountDiagnostic == messages.count {
                        let isLatestUserRow = latestTranscriptMessageRole == "user"
                        logTranscriptScrollSnapshot(
                            event: "message_count_layout_sample",
                            decision: isLatestUserRow
                                ? (isLatestRowVisible ? "latest_user_row_visible" : "latest_user_row_not_visible")
                                : (isBottomVisible ? "tail_visible" : "tail_not_visible"),
                            viewportHeight: viewport.size.height,
                            targetKind: isLatestUserRow ? "latest_row" : "latest_content",
                            targetExists: latestRenderedID != nil,
                            targetVisible: isLatestUserRow ? isLatestRowVisible : isBottomVisible,
                            attempt: 0,
                            outgoingUserInsertion: isLatestUserRow
                                && outgoingInsertionEvent?.scope == outgoingInsertionScope
                                && outgoingInsertionEvent?.messageID == latestRenderedID
                        )
                        pendingMessageCountDiagnostic = nil
                    }
                    if hasExplicitBottomScrollRequest,
                       !hasLoggedExplicitBottomTarget,
                       isLatestRowVisible || isBottomVisible {
                        hasLoggedExplicitBottomTarget = true
                        logTranscriptScrollSnapshot(
                            event: "explicit_bottom_target_visible",
                            decision: "visible_geometry_sample",
                            viewportHeight: viewport.size.height,
                            targetKind: "latest_row_or_tail",
                            targetExists: latestRenderedID != nil,
                            targetVisible: true,
                            attempt: 0
                        )
                    }
#endif
                    restoreSettlementState.recordTailVisibility(isBottomVisible)
                    onTranscriptTailVisibilityChange(isLatestRowVisible, isBottomVisible)
                    let visibleRow = ChatTranscriptVisibilityPolicy.firstVisibleMessage(
                        frames: frames.filter { $0.key != bottomAnchorID },
                        viewportHeight: viewport.size.height
                    )
                    viewportTracker.activationRecoveryState.recordPreferenceSample(
                        hasVisibleMessageRows: visibleRow != nil
                    )
                    evaluateActivationRecovery(
                        proxy: proxy,
                        viewportHeight: viewport.size.height,
                        frames: frames,
                        latestRenderedID: latestRenderedID,
                        isFreshActivationSample: true
                    )

                    if let visibleRow {
                        viewportTracker.visibleRowFrame = visibleRow.frame
                        viewportTracker.viewportHeight = viewport.size.height
                    }

                    let visibleID = ChatTranscriptVisibilityPolicy.retainedVisibleMessageID(
                        currentID: viewportTracker.visibleRowID,
                        incomingID: visibleRow?.id,
                        hasMessages: !messages.isEmpty
                    )
                    if viewportTracker.visibleRowID != visibleID {
                        viewportTracker.visibleRowID = visibleID
                        onVisibleTranscriptRowIDChange(visibleID)
                    }

                    reconcilePendingOlderMessagesAnchor(
                        frames: frames,
                        proxy: proxy,
                        currentFirstLoadedRowID: renderedMessages.first?.renderID
                    )

                    let firstLoadedRow = renderedMessages.first.flatMap { message in
                        frames[message.renderID].map {
                            ChatTranscriptVisibilityPolicy.VisibleRow(
                                id: message.renderID,
                                frame: $0
                            )
                        }
                    }

                    if !hasOlderMessages {
                        viewportTracker.lastOlderMessagesPrefetchVisibleRowID = nil
                    } else if ChatTranscriptPagingPolicy.shouldPrefetchOlderMessages(
                        firstLoadedRow: firstLoadedRow,
                        firstVisibleRow: visibleRow,
                        viewportHeight: viewport.size.height,
                        hasOlderMessages: hasOlderMessages,
                        isLoadingOlderMessages: isLoadingOlderMessages || viewportTracker.olderMessagesLoadInFlight,
                        hasPendingRestore: restoreSettlementTask != nil,
                        shouldFollowLatest: shouldFollowLatestMessage,
                        lastRequestedVisibleRowID: viewportTracker.lastOlderMessagesPrefetchVisibleRowID
                    ), let visibleRow {
                        viewportTracker.lastOlderMessagesPrefetchVisibleRowID = visibleRow.id
                        beginOlderMessagesPrefetch(proxy: proxy, row: visibleRow)
                    }
                }
            }
        }
    }

    private func evaluateActivationRecovery(
        proxy: ScrollViewProxy,
        viewportHeight: CGFloat,
        frames: [String: CGRect],
        latestRenderedID: String?,
        isFreshActivationSample: Bool
    ) {
        guard viewportTracker.activationRecoveryState.isArmed else { return }

        let messageFrames = frames.filter { $0.key != bottomAnchorID }
        func isVisible(_ frame: CGRect?) -> Bool {
            ChatTranscriptVisibilityPolicy.isVisible(
                frame: frame,
                viewportHeight: viewportHeight,
                bottomInset: transcriptBottomInsetHeight
            )
        }
        let visibleRow = ChatTranscriptVisibilityPolicy.firstVisibleMessage(
            frames: messageFrames,
            viewportHeight: viewportHeight
        )
        let hasVisibleRows = visibleRow != nil || messageFrames.contains { isVisible($0.value) }
        // A cached frame dictionary can be left over from before foregrounding.
        // Keep the check armed while those frames look healthy; only a fresh
        // post-activation preference sample may disarm a healthy result.
        if !isFreshActivationSample && hasVisibleRows {
            return
        }
        viewportTracker.activationRecoveryState.disarm()

        let currentMetrics = currentScrollMetricsForRecovery() ?? viewportTracker.latestScrollMetrics
        let isNearBottom = currentMetrics.map {
            ChatScrollPolicy.isNearBottom(
                distanceFromBottom: max(0, $0.distanceFromBottom),
                isStreaming: activeStreamID != nil
            )
        } ?? isScrolledNearBottom
        let isTailVisible = isVisible(frames[bottomAnchorID])
            || isVisible(latestRenderedID.flatMap { frames[$0] })
        let shouldRecover = ChatTranscriptViewportRecoveryPolicy.shouldRecoverAfterActivation(
            hasMessages: !messages.isEmpty,
            hadObservedRows: viewportTracker.activationRecoveryState.hasObservedRows,
            hasVisibleRows: hasVisibleRows,
            shouldFollowLatest: shouldFollowLatestMessage,
            isNearBottom: isNearBottom,
            isTailVisible: isTailVisible,
            isDirectlyInteracting: currentMetrics?.isDirectlyInteracting ?? false,
            isDecelerating: currentMetrics?.isDecelerating ?? false
        )
#if DEBUG
        logTranscriptScrollSnapshot(
            event: isFreshActivationSample ? "fresh_sample" : "empty_cache_sample",
            decision: shouldRecover ? "restore_saved_viewport" : "keep_viewport",
            viewportHeight: viewportHeight
        )
#endif
        guard shouldRecover else { return }

        applyTranscriptViewportRecovery(proxy, viewportHeight: viewportHeight)
    }

    private func scheduleActivationRecoveryProbe(
        proxy: ScrollViewProxy,
        viewportHeight: CGFloat,
        latestRenderedID: String?
    ) {
        guard viewportTracker.activationRecoveryState.isArmed, viewportHeight > 0 else { return }
        let baselineGeneration = viewportTracker.activationBaselineFramesGeneration
        Task { @MainActor in
            // Let SwiftUI/UIKit publish a new layout sample without introducing
            // an arbitrary timer delay. A preference callback with a newer
            // generation owns the normal path below.
            await Task.yield()
            guard scenePhase == .active, viewportTracker.activationRecoveryState.isArmed else { return }
            viewportTracker.scrollView?.setNeedsLayout()
            viewportTracker.scrollView?.layoutIfNeeded()

            let visibleCachedRowCount = viewportTracker.latestFrames.filter { $0.key != bottomAnchorID }
                .filter {
                    ChatTranscriptVisibilityPolicy.isVisible(
                        frame: $0.value,
                        viewportHeight: viewportHeight,
                        bottomInset: transcriptBottomInsetHeight
                    )
                }
                .count
            let disposition = ChatTranscriptActivationProbeDisposition.resolve(
                currentFramesGeneration: viewportTracker.framesGeneration,
                activationBaselineFramesGeneration: baselineGeneration,
                cachedFrameCount: viewportTracker.latestFrames.count,
                visibleCachedRowCount: visibleCachedRowCount
            )

            if case .freshGeometryArrived = disposition {
#if DEBUG
                logTranscriptScrollSnapshot(
                    event: "probe_fresh_geometry",
                    decision: "preference_callback_owns_recovery",
                    viewportHeight: viewportHeight
                )
#endif
                return
            }

            // Cached nonempty frames may predate a long suspension. Do not
            // reposition a reader based on them; record the ambiguity and wait
            // for a real post-activation preference sample instead.
            guard case .evaluateEmptyCache = disposition else {
#if DEBUG
                logTranscriptScrollSnapshot(
                    event: "probe_stale_nonempty_cache",
                    decision: "wait_for_fresh_geometry",
                    viewportHeight: viewportHeight
                )
#endif
                return
            }
#if DEBUG
            logTranscriptScrollSnapshot(
                event: "probe_empty_cache",
                decision: "evaluate_empty_geometry",
                viewportHeight: viewportHeight
            )
#endif
            evaluateActivationRecovery(
                proxy: proxy,
                viewportHeight: viewportHeight,
                frames: viewportTracker.latestFrames,
                latestRenderedID: latestRenderedID,
                isFreshActivationSample: false
            )
        }
    }

#if DEBUG
    /// Emits bounded, content-free transcript viewport evidence. It omits
    /// transcript text, row IDs, profile names, and paths.
    private func logTranscriptScrollSnapshot(
        event: String,
        decision: String,
        viewportHeight: CGFloat,
        targetKind: String = "none",
        targetExists: Bool? = nil,
        targetVisible: Bool? = nil,
        attempt: Int? = nil,
        animated: Bool? = nil,
        outgoingUserInsertion: Bool? = nil
    ) {
        let frames = viewportTracker.latestFrames
        let rowFrames = frames.filter { $0.key != bottomAnchorID }.map(\.value)
        let visibleRowCount = rowFrames.filter {
            ChatTranscriptVisibilityPolicy.isVisible(
                frame: $0,
                viewportHeight: viewportHeight,
                bottomInset: transcriptBottomInsetHeight
            )
        }.count
        let scrollView = viewportTracker.scrollView
        let bounds = scrollView?.bounds.size ?? .zero
        let contentSize = scrollView?.contentSize ?? .zero
        let contentOffset = scrollView?.contentOffset ?? .zero
        let insets = scrollView?.adjustedContentInset ?? .zero
        let hostVisibleHeight = max(0, bounds.height - insets.top - insets.bottom)
        let normalizedOffset = contentOffset.y + insets.top
        let maximumOffset = contentSize.height - hostVisibleHeight
        let signedDistanceToMax = maximumOffset - normalizedOffset
        let contentFitsViewport = contentSize.height >= hostVisibleHeight
        let isPastMaxOffset = contentFitsViewport && normalizedOffset > maximumOffset + 1
        let isPastMinOffset = normalizedOffset < -1
        let frameMinY = rowFrames.map(\.minY).min() ?? .nan
        let frameMaxY = rowFrames.map(\.maxY).max() ?? .nan
        let currentMetrics = currentScrollMetricsForRecovery() ?? viewportTracker.latestScrollMetrics
        let latestFrame = renderedTranscriptMessages.last.flatMap { frames[$0.renderID] }
        let tailVisible = ChatTranscriptVisibilityPolicy.isVisible(
            frame: frames[bottomAnchorID] ?? latestFrame,
            viewportHeight: viewportHeight,
            bottomInset: transcriptBottomInsetHeight
        )
        let targetExistsValue = targetExists.map { $0 ? "true" : "false" } ?? "unknown"
        let targetVisibleValue = targetVisible.map { $0 ? "true" : "false" } ?? "unknown"
        let attemptValue = attempt.map(String.init) ?? "none"
        let animatedValue = animated.map { $0 ? "true" : "false" } ?? "unknown"
        let outgoingValue = outgoingUserInsertion.map { $0 ? "true" : "false" } ?? "unknown"

        Self.activationRecoveryLogger.debug("""
            event=\(event, privacy: .public) decision=\(decision, privacy: .public) sceneActive=\(scenePhase == .active, privacy: .public) \
            targetKind=\(targetKind, privacy: .public) targetExists=\(targetExistsValue, privacy: .public) targetVisible=\(targetVisibleValue, privacy: .public) attempt=\(attemptValue, privacy: .public) animated=\(animatedValue, privacy: .public) outgoingUserInsertion=\(outgoingValue, privacy: .public) \
            messages=\(messages.count, privacy: .public) displayedRows=\(displayedTranscriptMessages.count, privacy: .public) renderedRows=\(renderedTranscriptMessages.count, privacy: .public) \
            hasObservedRows=\(viewportTracker.activationRecoveryState.hasObservedRows, privacy: .public) recoveryArmed=\(viewportTracker.activationRecoveryState.isArmed, privacy: .public) frames=\(frames.count, privacy: .public) visibleFrames=\(visibleRowCount, privacy: .public) \
            frameY=\(Double(frameMinY), privacy: .public)...\(Double(frameMaxY), privacy: .public) generation=\(viewportTracker.framesGeneration, privacy: .public) baseline=\(viewportTracker.activationBaselineFramesGeneration, privacy: .public) \
            viewportHeight=\(Double(viewportHeight), privacy: .public) followLatest=\(shouldFollowLatestMessage, privacy: .public) nearBottom=\(isScrolledNearBottom, privacy: .public) tailVisible=\(tailVisible, privacy: .public) explicitBottomRequest=\(hasExplicitBottomScrollRequest, privacy: .public) \
            streamActive=\(activeStreamID != nil, privacy: .public) hostInWindow=\(scrollView?.window != nil, privacy: .public) \
            hostBounds=\(Double(bounds.width), privacy: .public)x\(Double(bounds.height), privacy: .public) hostVisibleHeight=\(Double(hostVisibleHeight), privacy: .public) \
            contentSize=\(Double(contentSize.width), privacy: .public)x\(Double(contentSize.height), privacy: .public) contentOffset=\(Double(contentOffset.x), privacy: .public),\(Double(contentOffset.y), privacy: .public) insets=\(Double(insets.top), privacy: .public),\(Double(insets.bottom), privacy: .public) \
            maxOffset=\(Double(maximumOffset), privacy: .public) normalizedOffset=\(Double(normalizedOffset), privacy: .public) signedDistanceToMax=\(Double(signedDistanceToMax), privacy: .public) contentFitsViewport=\(contentFitsViewport, privacy: .public) pastMin=\(isPastMinOffset, privacy: .public) pastMax=\(isPastMaxOffset, privacy: .public) \
            distanceFromBottomClamped=\(Double(currentMetrics?.distanceFromBottom ?? .nan), privacy: .public) tracking=\(scrollView?.isTracking ?? false, privacy: .public) dragging=\(scrollView?.isDragging ?? false, privacy: .public) decelerating=\(scrollView?.isDecelerating ?? false, privacy: .public)
            """)
    }
#endif

    private func currentScrollMetricsForRecovery() -> ChatScrollMetrics? {
        guard let scrollView = viewportTracker.scrollView else { return nil }

        let insets = scrollView.adjustedContentInset
        let visibleHeight = scrollView.bounds.height - insets.top - insets.bottom
        guard visibleHeight > 0 else { return nil }

        let currentOffset = scrollView.contentOffset.y + insets.top
        let maximumOffset = scrollView.contentSize.height - visibleHeight
        let isDirectlyInteracting = scrollView.isDragging || scrollView.isTracking
        return ChatScrollMetrics(
            distanceFromBottom: max(0, maximumOffset - currentOffset),
            isUserInteracting: isDirectlyInteracting || scrollView.isDecelerating,
            isDirectlyInteracting: isDirectlyInteracting,
            isDecelerating: scrollView.isDecelerating
        )
    }

    private func transcriptScrollContent(
        proxy: ScrollViewProxy,
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        renderedMessages: [TranscriptMessage]
    ) -> some View {
        let latestCompletedAssistantRenderID = AssistantResponseActionPolicy.latestCompletedAssistantRenderID(
            in: renderedMessages,
            hasActiveStream: activeStreamID != nil,
            streamingAssistantMessageID: streamingAssistantMessageID
        )

        return LazyVStack(spacing: transcriptMessageSpacing) {
            olderMessagesButton(proxy: proxy)

            if let compressionReferenceCard, compressionReferenceCard.afterRenderID == nil {
                compressionReferenceCardView(compressionReferenceCard)
            }

            ForEach(renderedMessages) { transcriptMessage in
                // Scope live-streaming state to the row that actually displays it.
                // Non-anchor / non-streaming rows receive stable empty/nil values so
                // their inputs don't change on every ~16ms flush; combined with the
                // `.equatable()` wrapper below, SwiftUI then skips re-evaluating their
                // (markdown-heavy) bodies while a response streams in.
                let isReasoningAnchor = reasoningAnchorMessageID == transcriptMessage.anchorID
                let isToolCallAnchor = toolCallAnchorMessageID == transcriptMessage.anchorID
                let isStreamingRow = streamingAssistantMessageID != nil
                    && transcriptMessage.message.messageId == streamingAssistantMessageID

                // One lazy child per transcript item, even when it owns a
                // compression card. Variable child counts force eager discovery.
                VStack(alignment: .leading, spacing: transcriptMessageSpacing) {
                    ChatTranscriptMessageBlock(
                        transcriptMessage: transcriptMessage,
                        latestCompletedAssistantRenderID: latestCompletedAssistantRenderID,
                        outgoingInsertionEvent: outgoingInsertionEvent?.messageID == transcriptMessage.message.id
                            ? outgoingInsertionEvent : nil,
                        insertionLedger: insertionLedger,
                        allowsOutgoingMotion: shouldFollowLatestMessage && restoreSettlementTask == nil,
                        transcriptBlockSpacing: transcriptBlockSpacing,
                        showsThinkingAndToolCards: showsThinkingAndToolCards,
                        reasoningGroups: reasoningGroupsForAnchor(transcriptMessage.anchorID),
                        toolCallGroups: completedToolCallGroupsForAnchor(transcriptMessage.anchorID),
                        liveReasoningText: isReasoningAnchor ? liveReasoningText : "",
                        reasoningAnchorMessageID: isReasoningAnchor ? reasoningAnchorMessageID : nil,
                        liveToolCalls: isToolCallAnchor ? liveToolCalls : [],
                        toolCallAnchorMessageID: isToolCallAnchor ? toolCallAnchorMessageID : nil,
                        streamingAssistantMessageID: isStreamingRow ? streamingAssistantMessageID : nil,
                        liveTokensPerSecond: isStreamingRow ? liveTokensPerSecond : nil,
                        localAttachmentPreviews: localAttachmentPreviews[transcriptMessage.message.id],
                        listeningMessageID: listeningMessageID,
                        isViewingCachedData: isViewingCachedData,
                        hasActiveStream: activeStreamID != nil,
                        isRegeneratingMessage: isRegeneratingMessage,
                        isEditingMessage: isEditingMessage,
                        isForkingMessage: isForkingMessage,
                        loadAttachmentImage: loadAttachmentImage,
                        loadAttachmentData: loadAttachmentData,
                        loadTranscriptMediaImage: loadTranscriptMediaImage,
                        loadTranscriptMediaData: loadTranscriptMediaData,
                        transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
                        actionContext: actionContext,
                        shouldRenderMessageRow: shouldRenderMessageRow,
                        onPreviewAttachment: onPreviewAttachment,
                        onPreviewTranscriptMedia: onPreviewTranscriptMedia,
                        onToggleListening: onToggleListening,
                        onSelectText: onSelectText,
                        onRegenerate: onRegenerate,
                        onEdit: onEdit,
                        onFork: onFork,
                        onCopy: onCopy
                    )
                    .equatable()
                    .background {
                        GeometryReader { rowProxy in
                            Color.clear.preference(
                                key: VisibleTranscriptRowFramesKey.self,
                                value: [
                                    transcriptMessage.renderID: rowProxy.frame(
                                        in: .named(Self.transcriptCoordinateSpaceName)
                                    )
                                ]
                            )
                        }
                    }
                    .id(transcriptMessage.renderID)

                    if let compressionReferenceCard,
                       compressionReferenceCard.afterRenderID == transcriptMessage.renderID {
                        compressionReferenceCardView(compressionReferenceCard)
                    }
                }
            }

            transcriptLooseBlocks
            liveResponseBlocks(renderedMessages: renderedMessages)
            inlineClarificationCard
            typingIndicator
            turnChangesCard
            inlineCommitButton

            Color.clear
                .frame(height: 1)
                .background {
                    GeometryReader { anchorProxy in
                        Color.clear.preference(
                            key: VisibleTranscriptRowFramesKey.self,
                            value: [bottomAnchorID: anchorProxy.frame(in: .named(Self.transcriptCoordinateSpaceName))]
                        )
                    }
                }
                .id(bottomAnchorID)
                .allowsHitTesting(false)
        }
        .padding(.top, 16)
        .frame(width: contentWidth, alignment: .leading)
        .padding(.horizontal, transcriptHorizontalPadding)
        .frame(width: viewportWidth, alignment: .leading)
        .clipped()
        .background {
            ZStack {
                ChatScrollObserver(
                    isStreaming: activeStreamID != nil,
                    onMetrics: { metrics in
                        handleScrollMetrics(metrics)
                    },
                    onScrollViewReady: { scrollView in
                        viewportTracker.scrollView = scrollView
                    }
                )

                ChatVerticalScrollAxisGuard()
            }
            .accessibilityHidden(true)
        }
    }

    private func compressionReferenceCardView(_ card: CompressionReferenceCard) -> some View {
        MarkerMessageCardView(kind: .compressionReference, content: card.referenceText)
    }

    private var transcriptHorizontalPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 20 : 16
    }

    private func transcriptContentWidth(for viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - (transcriptHorizontalPadding * 2))
    }

#if DEBUG
    private func restoreTargetDiagnostic(
        _ target: ChatTranscriptRestoreTarget,
        viewportHeight: CGFloat
    ) -> (kind: String, exists: Bool, visible: Bool) {
        let frames = viewportTracker.latestFrames
        switch target {
        case .latest:
            let latestID = renderedTranscriptMessages.last?.renderID
            let latestVisible = ChatTranscriptVisibilityPolicy.isVisible(
                frame: latestID.flatMap { frames[$0] },
                viewportHeight: viewportHeight,
                bottomInset: transcriptBottomInsetHeight
            )
            let tailVisible = ChatTranscriptVisibilityPolicy.isVisible(
                frame: frames[bottomAnchorID],
                viewportHeight: viewportHeight,
                bottomInset: transcriptBottomInsetHeight
            )
            return ("latest_content", latestID != nil, latestVisible || tailVisible)
        case .message(let id):
            let exists = renderedTranscriptMessages.contains { $0.renderID == id }
            let visible = ChatTranscriptVisibilityPolicy.isVisible(
                frame: frames[id],
                viewportHeight: viewportHeight,
                bottomInset: transcriptBottomInsetHeight
            )
            return ("saved_message", exists, visible)
        }
    }
#endif

    private func applyTranscriptRestore(
        _ proxy: ScrollViewProxy,
        target: ChatTranscriptRestoreTarget? = nil,
        isViewportRecovery: Bool = false,
        viewportHeight: CGFloat
    ) {
        guard ChatTranscriptRestorePolicy.shouldProgrammaticallyRestoreOnAppear(hasMessages: !messages.isEmpty) else {
            return
        }

        restoreSettlementTask?.cancel()
        let didBegin: Bool
        if isViewportRecovery {
            didBegin = restoreSettlementState.beginViewportRecovery(token: restoreScrollToken)
        } else {
            didBegin = restoreSettlementState.beginRestore(token: restoreScrollToken)
        }
        guard didBegin else {
            restoreSettlementTask = nil
            return
        }
        let target = target ?? restoreTarget
#if DEBUG
        let startDiagnostic = restoreTargetDiagnostic(target, viewportHeight: viewportHeight)
        logTranscriptScrollSnapshot(
            event: isViewportRecovery ? "viewport_recovery_start" : "initial_restore_start",
            decision: "settling_target",
            viewportHeight: viewportHeight,
            targetKind: startDiagnostic.kind,
            targetExists: startDiagnostic.exists,
            targetVisible: startDiagnostic.visible,
            attempt: 0,
            animated: false
        )
#endif
        restoreSettlementTask = Task { @MainActor in
            var attempt = 0
            for delay in ChatTranscriptRestorePolicy.settlementDelays {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                } else {
                    await Task.yield()
                }

                guard !Task.isCancelled else { return }
                guard !restoreSettlementState.isCancelled else { return }
                if restoreSettlementState.shouldSettle(
                    target: target,
                    firstVisibleMessageID: viewportTracker.visibleRowID
                ) {
#if DEBUG
                    let settledDiagnostic = restoreTargetDiagnostic(
                        target,
                        viewportHeight: viewportHeight
                    )
                    logTranscriptScrollSnapshot(
                        event: isViewportRecovery ? "viewport_recovery_settled" : "initial_restore_settled",
                        decision: "target_confirmed",
                        viewportHeight: viewportHeight,
                        targetKind: settledDiagnostic.kind,
                        targetExists: settledDiagnostic.exists,
                        targetVisible: settledDiagnostic.visible,
                        attempt: attempt,
                        animated: false
                    )
#endif
                    restoreSettlementTask = nil
                    return
                }

                // Count the attempt immediately before issuing the proxy call.
                // A default near-bottom value is not allowed to short-circuit the
                // first real restore pass.
                attempt += 1
                restoreSettlementState.recordRestoreAttempt()
#if DEBUG
                let attemptDiagnostic = restoreTargetDiagnostic(
                    target,
                    viewportHeight: viewportHeight
                )
                logTranscriptScrollSnapshot(
                    event: isViewportRecovery ? "viewport_recovery_attempt" : "initial_restore_attempt",
                    decision: "issue_scroll_target",
                    viewportHeight: viewportHeight,
                    targetKind: attemptDiagnostic.kind,
                    targetExists: attemptDiagnostic.exists,
                    targetVisible: attemptDiagnostic.visible,
                    attempt: attempt,
                    animated: false
                )
#endif
                switch target {
                case .latest:
                    onScrollToLatestContent(proxy, false)
                case .message(let id):
                    onScrollToTranscriptMessage(proxy, id, false)
                }
            }

            guard !Task.isCancelled else { return }
#if DEBUG
            let exhaustedDiagnostic = restoreTargetDiagnostic(
                target,
                viewportHeight: viewportHeight
            )
            logTranscriptScrollSnapshot(
                event: isViewportRecovery ? "viewport_recovery_exhausted" : "initial_restore_exhausted",
                decision: "bounded_attempts_finished",
                viewportHeight: viewportHeight,
                targetKind: exhaustedDiagnostic.kind,
                targetExists: exhaustedDiagnostic.exists,
                targetVisible: exhaustedDiagnostic.visible,
                attempt: attempt,
                animated: false
            )
#endif
            restoreSettlementTask = nil
        }
    }

    private func applyTranscriptViewportRecovery(
        _ proxy: ScrollViewProxy,
        viewportHeight: CGFloat
    ) {
        let target: ChatTranscriptRestoreTarget
        if shouldFollowLatestMessage {
            target = .latest
        } else if let visibleRowID = viewportTracker.visibleRowID {
            target = .message(id: visibleRowID)
        } else {
            target = restoreTarget
        }

        applyTranscriptRestore(
            proxy,
            target: target,
            isViewportRecovery: true,
            viewportHeight: viewportHeight
        )
    }

    private func cancelTranscriptRestore() {
        restoreSettlementTask?.cancel()
        restoreSettlementTask = nil
        restoreSettlementState.cancel()
    }

    private func resetViewportForNewTranscript() {
        restoreSettlementTask?.cancel()
        restoreSettlementTask = nil
        restoreSettlementState = ChatTranscriptRestoreState()
        viewportTracker.visibleRowID = nil
        viewportTracker.visibleRowFrame = nil
        viewportTracker.viewportHeight = 0
        viewportTracker.activationRecoveryState.reset()
        viewportTracker.latestFrames = [:]
        viewportTracker.latestScrollMetrics = nil
        viewportTracker.olderMessagesLoadInFlight = false
        viewportTracker.pendingOlderMessagesAnchor = nil
        viewportTracker.pendingOlderMessagesLoadCompleted = false
        viewportTracker.pendingOlderMessagesBaselineMessageCount = nil
        viewportTracker.pendingOlderMessagesBaselineRenderRevision = nil
        viewportTracker.pendingOlderMessagesBaselineFirstLoadedRowID = nil
        viewportTracker.lastOlderMessagesPrefetchVisibleRowID = nil
    }

    private func handleScrollMetrics(_ metrics: ChatScrollMetrics) {
        viewportTracker.latestScrollMetrics = metrics
        let isNearBottom = ChatScrollPolicy.isNearBottom(
            distanceFromBottom: max(0, metrics.distanceFromBottom),
            isStreaming: activeStreamID != nil
        )
        restoreSettlementState.recordMetrics(
            isNearBottom: isNearBottom,
            isDirectlyInteracting: metrics.isDirectlyInteracting,
            isDecelerating: metrics.isDecelerating
        )

        if restoreSettlementState.isCancelled {
            // Invalidate the pending task in the same main-actor callback that
            // observed the finger drag, so a later sleep wake cannot yank the
            // viewport back. Deceleration and layout-only samples never enter
            // this branch.
            restoreSettlementTask?.cancel()
            restoreSettlementTask = nil
        }

        onUpdateScrollMetrics(metrics)
    }

    @ViewBuilder
    private func olderMessagesButton(proxy: ScrollViewProxy) -> some View {
        if hasOlderMessages {
            LoadOlderMessagesButton(isLoading: isLoadingOlderMessages) {
                Task { await loadOlderMessagesPreservingPosition(proxy: proxy) }
            }
        }
    }

    private func currentTranscriptViewportAnchor() -> ChatTranscriptViewportAnchor? {
        if let visibleRowID = viewportTracker.visibleRowID {
            return ChatTranscriptViewportAnchor(
                messageID: visibleRowID,
                frame: viewportTracker.visibleRowFrame,
                viewportHeight: viewportTracker.viewportHeight > 0
                    ? viewportTracker.viewportHeight : nil
            )
        }

        guard let firstRenderedID = renderedTranscriptMessages.first?.renderID else {
            return nil
        }
        return ChatTranscriptViewportAnchor(messageID: firstRenderedID, frame: nil, viewportHeight: nil)
    }

    private func beginOlderMessagesPrefetch(
        proxy: ScrollViewProxy,
        row: ChatTranscriptVisibilityPolicy.VisibleRow
    ) {
        guard !viewportTracker.olderMessagesLoadInFlight, !isLoadingOlderMessages else { return }

        // Reserve the slot before yielding to the async loader. The row ID key
        // also prevents repeated preference passes at the same boundary from
        // starting another request after a failed/no-progress response.
        viewportTracker.olderMessagesLoadInFlight = true
        let anchor = ChatTranscriptViewportAnchor(
            messageID: row.id,
            frame: row.frame,
            viewportHeight: viewportTracker.viewportHeight > 0
                ? viewportTracker.viewportHeight : nil
        )
        Task { @MainActor in
            await loadOlderMessagesPreservingPosition(
                proxy: proxy,
                anchor: anchor,
                hasReservedLoadSlot: true
            )
        }
    }

    private func loadOlderMessagesPreservingPosition(
        proxy: ScrollViewProxy,
        anchor: ChatTranscriptViewportAnchor? = nil,
        hasReservedLoadSlot: Bool = false
    ) async {
        guard hasOlderMessages, !isLoadingOlderMessages else {
            if hasReservedLoadSlot { viewportTracker.olderMessagesLoadInFlight = false }
            return
        }
        guard hasReservedLoadSlot || !viewportTracker.olderMessagesLoadInFlight else { return }

        viewportTracker.olderMessagesLoadInFlight = true
        let anchor = anchor ?? currentTranscriptViewportAnchor()
        viewportTracker.pendingOlderMessagesAnchor = anchor
        viewportTracker.pendingOlderMessagesLoadCompleted = false
        viewportTracker.pendingOlderMessagesBaselineMessageCount = messages.count
        viewportTracker.pendingOlderMessagesBaselineRenderRevision = transcriptRenderRevision
        viewportTracker.pendingOlderMessagesBaselineFirstLoadedRowID = renderedTranscriptMessages.first?.renderID
        let didLoad = await onLoadOlderMessages()
        viewportTracker.olderMessagesLoadInFlight = false
        viewportTracker.pendingOlderMessagesLoadCompleted = didLoad

        guard didLoad, let anchor else {
            clearPendingOlderMessagesAnchor()
            return
        }

        // When no row geometry was available before the request, there is no
        // screen-space offset to compare. The durable row identity is still a
        // useful fallback; all normal paths wait for the preference callback
        // below and avoid a jump when SwiftUI already preserved the offset.
        if anchor.frame == nil {
            clearPendingOlderMessagesAnchor()
            onScrollToTranscriptMessage(proxy, anchor.messageID, false)
        }
    }

    private func reconcilePendingOlderMessagesAnchor(
        frames: [String: CGRect],
        proxy: ScrollViewProxy,
        currentFirstLoadedRowID: String?
    ) {
        guard let anchor = viewportTracker.pendingOlderMessagesAnchor else { return }
        guard viewportTracker.pendingOlderMessagesLoadCompleted else { return }
        let didChangeTranscript = (viewportTracker.pendingOlderMessagesBaselineMessageCount.map {
            messages.count > $0
        } ?? false) || (viewportTracker.pendingOlderMessagesBaselineRenderRevision.map {
            transcriptRenderRevision != $0
        } ?? false)
        guard didChangeTranscript else { return }
        if let baselineFirstLoadedRowID = viewportTracker.pendingOlderMessagesBaselineFirstLoadedRowID {
            guard let currentFirstLoadedRowID,
                  currentFirstLoadedRowID != baselineFirstLoadedRowID
            else { return }
        }
        guard let afterFrame = frames[anchor.messageID] else { return }

        let currentMetrics = currentScrollMetricsForRecovery() ?? viewportTracker.latestScrollMetrics
        if currentMetrics?.isDirectlyInteracting == true
            || currentMetrics?.isDecelerating == true {
            // A new gesture owns the viewport. Do not apply a page correction
            // after the reader has deliberately moved on.
            clearPendingOlderMessagesAnchor()
            return
        }

        clearPendingOlderMessagesAnchor()
        guard ChatTranscriptPagingPolicy.shouldRestorePrependedAnchor(
            beforeFrame: anchor.frame,
            afterFrame: afterFrame
        ) else { return }

        // A prepend is a viewport-preserving operation. If the measured anchor
        // moved materially, restore its measured alignment without animation
        // rather than always scrolling the first loaded row to the top.
        if preservePrependedAnchorWithUIKit(
            anchor: anchor,
            afterFrame: afterFrame
        ) {
            return
        }

        if let viewportHeight = anchor.viewportHeight,
           let alignment = ChatTranscriptPagingPolicy.preservedAnchorAlignment(
               beforeFrame: anchor.frame,
               viewportHeight: viewportHeight
           ) {
            proxy.scrollTo(anchor.messageID, anchor: alignment)
        } else {
            // A viewport as tall as the anchor cannot represent a distinct
            // preserved top edge. The durable row remains the safest bounded
            // fallback, and this path is only taken after measured displacement.
            onScrollToTranscriptMessage(proxy, anchor.messageID, false)
        }
    }

    private func preservePrependedAnchorWithUIKit(
        anchor: ChatTranscriptViewportAnchor,
        afterFrame: CGRect
    ) -> Bool {
        guard let scrollView = viewportTracker.scrollView,
              let beforeFrame = anchor.frame
        else { return false }

        let displacement = afterFrame.minY - beforeFrame.minY
        guard abs(displacement) > ChatTranscriptPagingPolicy.anchorPreservationTolerance else {
            return true
        }

        let insets = scrollView.adjustedContentInset
        let minimumOffsetY = -insets.top
        let maximumOffsetY = max(
            minimumOffsetY,
            scrollView.contentSize.height - scrollView.bounds.height + insets.bottom
        )
        let proposedOffsetY = min(
            maximumOffsetY,
            max(minimumOffsetY, scrollView.contentOffset.y + displacement)
        )
        guard abs(proposedOffsetY - scrollView.contentOffset.y) > 0.5 else { return true }

        UIView.performWithoutAnimation {
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: proposedOffsetY),
                animated: false
            )
        }
        return true
    }

    private func clearPendingOlderMessagesAnchor() {
        viewportTracker.pendingOlderMessagesAnchor = nil
        viewportTracker.pendingOlderMessagesLoadCompleted = false
        viewportTracker.pendingOlderMessagesBaselineMessageCount = nil
        viewportTracker.pendingOlderMessagesBaselineRenderRevision = nil
        viewportTracker.pendingOlderMessagesBaselineFirstLoadedRowID = nil
    }

    @ViewBuilder
    private var transcriptLooseBlocks: some View {
        reasoningBlocks(anchorMessageID: nil)
        toolCallGroups(anchorMessageID: nil)
    }

    @ViewBuilder
    private func liveResponseBlocks(renderedMessages: [TranscriptMessage]) -> some View {
        if activeStreamID != nil {
            if showsThinkingAndToolCards {
                if hasLiveReasoningText,
                   !hasDisplayedTranscriptMessage(
                    anchorID: reasoningAnchorMessageID,
                    in: renderedMessages
                   ) {
                    ReasoningBlockView(text: liveReasoningText, isActive: true)
                }

                if !liveToolCalls.isEmpty,
                   !hasDisplayedTranscriptMessage(
                    anchorID: toolCallAnchorMessageID,
                    in: renderedMessages
                   ) {
                    ToolActivityGroupView(
                        group: ToolCallGroup.live(
                            anchorMessageID: toolCallAnchorMessageID,
                            toolCalls: liveToolCalls
                        )
                    )
                }
            }

            if activeStreamRecoveryState != .idle {
                StreamRecoveryStatusView(state: activeStreamRecoveryState)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(hidesRunStatusAccessibility)
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            }
        }
    }

    @ViewBuilder
    private var inlineClarificationCard: some View {
        if let clarificationPrompt {
            ClarificationRequestCard(
                prompt: clarificationPrompt,
                isResponding: isRespondingToClarification,
                errorMessage: clarificationErrorMessage,
                onSubmit: onSubmitClarification,
                onCancel: onCancelClarification
            )
            .id(clarificationPrompt.id)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder
    private var typingIndicator: some View {
        if showsAssistantTypingIndicator {
            AssistantTypingIndicatorView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(hidesRunStatusAccessibility)
        }
    }

    @ViewBuilder
    private var turnChangesCard: some View {
        if let summary = turnChangesSummary {
            GitTurnChangesCard(
                summary: summary,
                onOpenAll: onOpenTurnDiff,
                onOpenFile: onOpenTurnFileDiff
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var inlineCommitButton: some View {
        if let context = inlineCommitContext {
            GitInlineCommitButton(
                runningPhase: context.runningPhase,
                isDisabled: context.isDisabled,
                action: onInlineCommit
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
    }

    private var hasLiveReasoningText: Bool {
        !liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hasDisplayedTranscriptMessage(
        anchorID: String?,
        in renderedMessages: [TranscriptMessage]
    ) -> Bool {
        guard let anchorID else { return false }

        return renderedMessages.contains { $0.anchorID == anchorID }
    }

    @ViewBuilder
    private func reasoningBlocks(anchorMessageID: String?) -> some View {
        if showsThinkingAndToolCards {
            ForEach(reasoningGroupsForAnchor(anchorMessageID)) { group in
                ReasoningBlockView(text: group.text)
            }
        }
    }

    @ViewBuilder
    private func toolCallGroups(anchorMessageID: String?) -> some View {
        if showsThinkingAndToolCards {
            ForEach(completedToolCallGroupsForAnchor(anchorMessageID)) { group in
                ToolActivityGroupView(group: group)
            }
        }
    }
}

extension ChatTranscriptView {
    /// Function-valued callbacks are stable behavior supplied by `ChatView`; all
    /// data that can change transcript output is represented by the render
    /// revision or the small layout/interaction fields below. Keeping this
    /// comparison explicit lets composer keystrokes avoid rebuilding every lazy
    /// transcript row.
    static func == (lhs: ChatTranscriptView, rhs: ChatTranscriptView) -> Bool {
        lhs.outgoingInsertionEvent == rhs.outgoingInsertionEvent &&
            lhs.outgoingInsertionScope == rhs.outgoingInsertionScope &&
            lhs.transcriptRenderRevision == rhs.transcriptRenderRevision &&
            lhs.isLoading == rhs.isLoading &&
            lhs.errorMessage == rhs.errorMessage &&
            lhs.messages.count == rhs.messages.count &&
            lhs.messages.isEmpty == rhs.messages.isEmpty &&
            lhs.compressionReferenceCard == rhs.compressionReferenceCard &&
            lhs.activeStreamRecoveryState == rhs.activeStreamRecoveryState &&
            lhs.clarificationPrompt == rhs.clarificationPrompt &&
            lhs.isRespondingToClarification == rhs.isRespondingToClarification &&
            lhs.clarificationErrorMessage == rhs.clarificationErrorMessage &&
            lhs.hidesRunStatusAccessibility == rhs.hidesRunStatusAccessibility &&
            lhs.showsThinkingAndToolCards == rhs.showsThinkingAndToolCards &&
            lhs.showsAssistantTypingIndicator == rhs.showsAssistantTypingIndicator &&
            lhs.showsScrollToBottomButton == rhs.showsScrollToBottomButton &&
            lhs.hasExplicitBottomScrollRequest == rhs.hasExplicitBottomScrollRequest &&
            lhs.shouldFollowLatestMessage == rhs.shouldFollowLatestMessage &&
            lhs.latestTranscriptMessageRole == rhs.latestTranscriptMessageRole &&
            lhs.liveTokensPerSecond == rhs.liveTokensPerSecond &&
            lhs.isScrolledNearBottom == rhs.isScrolledNearBottom &&
            lhs.activeStreamID == rhs.activeStreamID &&
            lhs.streamingScrollTrigger == rhs.streamingScrollTrigger &&
            lhs.cacheFirstReconcileScrollToken == rhs.cacheFirstReconcileScrollToken &&
            lhs.bottomAnchorID == rhs.bottomAnchorID &&
            lhs.transcriptMessageSpacing == rhs.transcriptMessageSpacing &&
            lhs.transcriptBlockSpacing == rhs.transcriptBlockSpacing &&
            lhs.transcriptBottomInsetHeight == rhs.transcriptBottomInsetHeight &&
            lhs.scrollToBottomButtonBottomPadding == rhs.scrollToBottomButtonBottomPadding &&
            lhs.localAttachmentPreviews == rhs.localAttachmentPreviews &&
            lhs.listeningMessageID == rhs.listeningMessageID &&
            lhs.isViewingCachedData == rhs.isViewingCachedData &&
            lhs.hasOlderMessages == rhs.hasOlderMessages &&
            lhs.isLoadingOlderMessages == rhs.isLoadingOlderMessages &&
            lhs.isRegeneratingMessage == rhs.isRegeneratingMessage &&
            lhs.isEditingMessage == rhs.isEditingMessage &&
            lhs.isForkingMessage == rhs.isForkingMessage &&
            lhs.transcriptMediaCacheNamespace == rhs.transcriptMediaCacheNamespace &&
            lhs.inlineCommitContext == rhs.inlineCommitContext &&
            lhs.turnChangesSummary == rhs.turnChangesSummary &&
            lhs.restoreScrollToken == rhs.restoreScrollToken &&
            lhs.restoreTarget == rhs.restoreTarget &&
            lhs.transcriptRestoreCancellationToken == rhs.transcriptRestoreCancellationToken &&
            lhs.followRejoinScrollToken == rhs.followRejoinScrollToken &&
            lhs.isComposerResizing == rhs.isComposerResizing
    }
}

private struct ChatTranscriptMessageBlock: View, Equatable {
    let transcriptMessage: TranscriptMessage
    let latestCompletedAssistantRenderID: String?
    let outgoingInsertionEvent: OutgoingInsertionEvent?
    let insertionLedger: OutgoingInsertionLedger
    let allowsOutgoingMotion: Bool
    let transcriptBlockSpacing: CGFloat
    let showsThinkingAndToolCards: Bool
    let reasoningGroups: [ReasoningGroup]
    let toolCallGroups: [ToolCallGroup]
    let liveReasoningText: String
    let reasoningAnchorMessageID: String?
    let liveToolCalls: [ToolCall]
    let toolCallAnchorMessageID: String?
    let streamingAssistantMessageID: String?
    let liveTokensPerSecond: Double?
    let localAttachmentPreviews: [String: Data]?
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasActiveStream: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let loadAttachmentImage: (String) async -> Data?
    let loadAttachmentData: (String) async -> Data?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let actionContext: (ChatMessage, Int) -> MessageActionContext?
    let shouldRenderMessageRow: (ChatMessage) -> Bool
    let onPreviewAttachment: (MessageAttachment, Data?) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onSelectText: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void

    // Equality over the value inputs only. The closures are pure functions of
    // these values (e.g. `actionContext` is fully determined by
    // `transcriptMessage`), so two blocks that compare equal render identically.
    // This lets `.equatable()` skip re-evaluating rows whose data is unchanged
    // even though their closure props are recreated on every parent body pass.
    static func == (lhs: ChatTranscriptMessageBlock, rhs: ChatTranscriptMessageBlock) -> Bool {
        lhs.outgoingInsertionEvent == rhs.outgoingInsertionEvent &&
        lhs.allowsOutgoingMotion == rhs.allowsOutgoingMotion &&
        lhs.transcriptMessage == rhs.transcriptMessage &&
        lhs.latestCompletedAssistantRenderID == rhs.latestCompletedAssistantRenderID &&
        lhs.transcriptBlockSpacing == rhs.transcriptBlockSpacing &&
        lhs.showsThinkingAndToolCards == rhs.showsThinkingAndToolCards &&
        lhs.reasoningGroups == rhs.reasoningGroups &&
        lhs.toolCallGroups == rhs.toolCallGroups &&
        lhs.liveReasoningText == rhs.liveReasoningText &&
        lhs.reasoningAnchorMessageID == rhs.reasoningAnchorMessageID &&
        lhs.liveToolCalls == rhs.liveToolCalls &&
        lhs.toolCallAnchorMessageID == rhs.toolCallAnchorMessageID &&
        lhs.streamingAssistantMessageID == rhs.streamingAssistantMessageID &&
        lhs.liveTokensPerSecond == rhs.liveTokensPerSecond &&
        lhs.localAttachmentPreviews == rhs.localAttachmentPreviews &&
        lhs.listeningMessageID == rhs.listeningMessageID &&
        lhs.isViewingCachedData == rhs.isViewingCachedData &&
        lhs.hasActiveStream == rhs.hasActiveStream &&
        lhs.isRegeneratingMessage == rhs.isRegeneratingMessage &&
        lhs.isEditingMessage == rhs.isEditingMessage &&
        lhs.isForkingMessage == rhs.isForkingMessage &&
        lhs.transcriptMediaCacheNamespace == rhs.transcriptMediaCacheNamespace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: transcriptBlockSpacing) {
            reasoningBlocks
            liveReasoningBlock
            toolActivityGroups
            liveToolActivityGroup

            if shouldRenderMessageRow(transcriptMessage.message) {
                ChatTranscriptMessageRow(
                    message: transcriptMessage.message,
                    accessibilityRowIdentifier: ChatMessageAccessibility.rowIdentifier(
                        messageID: transcriptMessage.message.messageId,
                        renderID: transcriptMessage.renderID
                    ),
                    accessibilityRowLabel: ChatMessageAccessibility.rowLabel(
                        role: transcriptMessage.message.role,
                        content: transcriptMessage.message.content,
                        visibleContent: transcriptMessage.attachmentDisplayContent,
                        attachmentCount: transcriptMessage.message.attachments?.count ?? 0
                    ),
                    visibleIndex: transcriptMessage.loadedIndex,
                    actionContext: actionContext(transcriptMessage.message, transcriptMessage.loadedIndex),
                    isLatestCompletedAssistant: latestCompletedAssistantRenderID == transcriptMessage.renderID,
                    localAttachmentPreviews: localAttachmentPreviews,
                    listeningMessageID: listeningMessageID,
                    isViewingCachedData: isViewingCachedData,
                    hasActiveStream: hasActiveStream,
                    isStreaming: ChatTranscriptDisplaySettings.shouldUseStreamingBubbleRendering(
                        hasActiveStream: hasActiveStream,
                        messageRole: transcriptMessage.message.role,
                        messageID: transcriptMessage.message.messageId,
                        streamingAssistantMessageID: streamingAssistantMessageID
                    ),
                    liveTokensPerSecond: liveTokensPerSecond,
                    isRegeneratingMessage: isRegeneratingMessage,
                    isEditingMessage: isEditingMessage,
                    isForkingMessage: isForkingMessage,
                    loadAttachmentImage: loadAttachmentImage,
                    loadAttachmentData: loadAttachmentData,
                    loadTranscriptMediaImage: loadTranscriptMediaImage,
                    loadTranscriptMediaData: loadTranscriptMediaData,
                    transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
                    attachmentDisplayContent: transcriptMessage.attachmentDisplayContent,
                    onPreviewAttachment: onPreviewAttachment,
                    onPreviewTranscriptMedia: onPreviewTranscriptMedia,
                    onToggleListening: onToggleListening,
                    onSelectText: onSelectText,
                    onRegenerate: onRegenerate,
                    onEdit: onEdit,
                    onFork: onFork,
                    onCopy: onCopy
                )
                .modifier(OutgoingBubbleInsertionModifier(
                    event: outgoingInsertionEvent,
                    message: transcriptMessage.message,
                    ledger: insertionLedger,
                    isAllowed: allowsOutgoingMotion
                ))
            }
        }
    }

    @ViewBuilder
    private var reasoningBlocks: some View {
        if showsThinkingAndToolCards {
            ForEach(reasoningGroups) { group in
                ReasoningBlockView(text: group.text)
            }
        }
    }

    @ViewBuilder
    private var liveReasoningBlock: some View {
        if shouldRenderLiveReasoningBlock {
            ReasoningBlockView(text: liveReasoningText, isActive: true)
        }
    }

    @ViewBuilder
    private var toolActivityGroups: some View {
        if showsThinkingAndToolCards {
            ForEach(toolCallGroups) { group in
                ToolActivityGroupView(group: group)
            }
        }
    }

    @ViewBuilder
    private var liveToolActivityGroup: some View {
        if shouldRenderLiveToolActivityGroup {
            ToolActivityGroupView(
                group: ToolCallGroup.live(
                    anchorMessageID: toolCallAnchorMessageID,
                    toolCalls: liveToolCalls
                )
            )
        }
    }

    private var shouldRenderLiveReasoningBlock: Bool {
        hasActiveStream &&
            showsThinkingAndToolCards &&
            reasoningAnchorMessageID == transcriptMessage.anchorID &&
            !liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldRenderLiveToolActivityGroup: Bool {
        hasActiveStream &&
            showsThinkingAndToolCards &&
            toolCallAnchorMessageID == transcriptMessage.anchorID &&
            !liveToolCalls.isEmpty
    }
}

private struct ChatTranscriptMessageRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let message: ChatMessage
    let accessibilityRowIdentifier: String
    let accessibilityRowLabel: String
    let visibleIndex: Int
    let actionContext: MessageActionContext?
    let isLatestCompletedAssistant: Bool
    let localAttachmentPreviews: [String: Data]?
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasActiveStream: Bool
    let isStreaming: Bool
    let liveTokensPerSecond: Double?
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let loadAttachmentImage: (String) async -> Data?
    let loadAttachmentData: (String) async -> Data?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let attachmentDisplayContent: String?
    let onPreviewAttachment: (MessageAttachment, Data?) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onSelectText: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compaction marker messages render as collapsible cards (matching
            // the web UI), never as user bubbles — and without bubble actions,
            // which don't apply to system-emitted markers.
            if let markerKind = ChatMarkerMessageClassifier.classify(message) {
                MarkerMessageCardView(kind: markerKind, content: message.content)
            } else if let actionContext {
                bubble
                    .contextMenu {
                        ChatMessageActionMenu(
                            context: actionContext,
                            listeningMessageID: listeningMessageID,
                            isViewingCachedData: isViewingCachedData,
                            hasActiveStream: hasActiveStream,
                            isRegeneratingMessage: isRegeneratingMessage,
                            isEditingMessage: isEditingMessage,
                            isForkingMessage: isForkingMessage,
                            onToggleListening: onToggleListening,
                            onSelectText: onSelectText,
                            onRegenerate: onRegenerate,
                            onEdit: onEdit,
                            onFork: onFork,
                            onCopy: onCopy
                        )
                    }
                responseActionRow(for: actionContext)
            } else {
                bubble
            }
        }
        // Expose one truthful, stable row while retaining all descendants. In
        // particular, link and attachment buttons remain independently
        // discoverable/actionable to VoiceOver and UI tests.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityRowIdentifier)
        .accessibilityLabel(accessibilityRowLabel)
        .accessibilityAddTraits(.isStaticText)
    }

    private var bubble: some View {
        MessageBubbleView(
            message: message,
            loadAttachmentImage: loadAttachmentImage,
            loadAttachmentData: loadAttachmentData,
            loadTranscriptMediaImage: loadTranscriptMediaImage,
            loadTranscriptMediaData: loadTranscriptMediaData,
            transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
            attachmentDisplayContent: attachmentDisplayContent,
            localAttachmentPreviews: localAttachmentPreviews,
            onPreviewAttachment: onPreviewAttachment,
            onPreviewTranscriptMedia: onPreviewTranscriptMedia,
            isStreaming: isStreaming,
            liveTokensPerSecond: liveTokensPerSecond
        )
    }

    private func responseActionRow(for context: MessageActionContext) -> some View {
        Group {
            if shouldShowResponseActions(for: context) {
                AssistantResponseActionRow(context: context, onCopy: onCopy)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.15),
            value: shouldShowResponseActions(for: context)
        )
    }

    private func shouldShowResponseActions(for context: MessageActionContext) -> Bool {
        AssistantResponseActionPolicy.shouldShowPersistentCopy(
            context: context,
            messageRole: message.role,
            isStreaming: isStreaming,
            isLatestCompletedAssistant: isLatestCompletedAssistant
        )
    }
}

private struct OutgoingBubbleInsertionModifier: ViewModifier {
    let event: OutgoingInsertionEvent?
    let message: ChatMessage
    let ledger: OutgoingInsertionLedger
    let isAllowed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled: Bool

    init(event: OutgoingInsertionEvent?, message: ChatMessage,
         ledger: OutgoingInsertionLedger, isAllowed: Bool) {
        self.event = event
        self.message = message
        self.ledger = ledger
        self.isAllowed = isAllowed
        _settled = State(initialValue: !ledger.isEligible(
            event, messageID: message.id, role: message.role,
            allowed: isAllowed
        ))
    }

    private var shouldAnimate: Bool {
        !settled && !reduceMotion && ledger.isEligible(
            event,
            messageID: message.id,
            role: message.role,
            allowed: isAllowed
        )
    }

    func body(content: Content) -> some View {
        content
            // Eligibility is part of the visible-state guard as well as the
            // initial state. If a lazy row is reused after follow/restore is
            // withdrawn, it must become visible immediately rather than retain
            // a stale opacity-zero state.
            .opacity(shouldAnimate ? 0 : 1)
            .offset(y: shouldAnimate ? 8 : 0)
            .onAppear {
                let accepted = ledger.claim(event, messageID: message.id, role: message.role,
                                            allowed: isAllowed)
                if accepted && !reduceMotion {
                    withAnimation(.easeOut(duration: 0.18)) { settled = true }
                } else {
                    settled = true
                }
            }
            .onChange(of: reduceMotion) { _, enabled in
                if enabled { settled = true }
            }
            .onChange(of: isAllowed) { _, allowed in
                if !allowed { settled = true }
            }
            .onChange(of: event) { _, _ in
                if !ledger.isEligible(
                    event,
                    messageID: message.id,
                    role: message.role,
                    allowed: isAllowed
                ) {
                    settled = true
                }
            }
            .onDisappear { settled = true }
    }
}

private struct ChatScrollToBottomButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let bottomPadding: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(.primary)
                .adaptiveGlass(
                    .regular,
                    isInteractive: true,
                    fallbackMaterial: .regularMaterial,
                    in: Circle()
                )
                .chatMinimumHitTarget(in: Circle())
        }
        .buttonStyle(.chatTactile(
            .icon,
            shadow: ChatTactileButtonStyle.Shadow(
                color: .black,
                opacity: colorScheme == .dark ? 0.32 : 0.16,
                radius: 8,
                y: 4,
                pressedOpacity: colorScheme == .dark ? 0.18 : 0.08,
                pressedRadius: 3,
                pressedY: 2
            )
        ))
        .padding(.bottom, bottomPadding)
        .accessibilityLabel("Scroll to latest message")
    }
}

private struct LoadOlderMessagesButton: View {
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }

                Text(isLoading ? String(localized: "Loading older messages") : String(localized: "Load older messages"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(.separator).opacity(0.32), lineWidth: 0.5)
            )
        }
        .buttonStyle(.chatTactile(.capsule))
        .disabled(isLoading)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(isLoading ? String(localized: "Loading older messages") : String(localized: "Load older messages"))
    }
}
