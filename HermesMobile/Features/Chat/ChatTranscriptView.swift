import OSLog
import SwiftUI
import UIKit

private struct VisibleTranscriptRowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

#if DEBUG
/// One bounded, in-memory observation for an automatic prepend. The raw row
/// ID is retained only long enough to match the next realized preference; logs
/// use the deterministic opaque key instead.
private struct ChatTranscriptPagingDebugEvidence {
    let sequence: Int
    let anchorID: String
    let anchorKey: String
    let beforeFrame: CGRect
    let beforeGlobalFrame: CGRect?
    let viewportGlobalFrame: CGRect?
    let startGeneration: Int
    var awaitsSettledPreference = false
    var minimumSettledGeneration = 0
    var correctionGeneration: Int? = nil
    var postCommandObservationCounts: [String: Int] = [:]
    var loggedSilentGuardReasons = Set<String>()
}
#endif

/// Owns the ScrollView's one native position binding for the initial saved
/// reader row. Latest-follow layout corrections use the existing proxy path so
/// this modifier never becomes a second persistent position owner. It stays
/// attached for stable ScrollView identity; its guarded setter does not turn
/// every scroll sample into ChatView state churn.
private struct ChatTranscriptInitialPositionModifier: ViewModifier {
    let targetMessageID: String?
    let transcriptScope: UUID?
    let isRestoreActive: Bool

    @State private var position: ScrollPosition
    @State private var hasRetiredInitialPosition: Bool

    init(
        targetMessageID: String?,
        transcriptScope: UUID?,
        isRestoreActive: Bool
    ) {
        self.targetMessageID = targetMessageID
        self.transcriptScope = transcriptScope
        self.isRestoreActive = isRestoreActive
        let shouldSeedPosition = targetMessageID != nil && isRestoreActive
        if shouldSeedPosition, let targetMessageID {
            _position = State(initialValue: ScrollPosition(id: targetMessageID, anchor: .top))
        } else {
            _position = State(initialValue: ScrollPosition(idType: String.self))
        }
        _hasRetiredInitialPosition = State(initialValue: !shouldSeedPosition)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .scrollPosition(positionBinding, anchor: .top)
            .onChange(of: isRestoreActive) { _, isActive in
                if isActive {
                    installPositionForCurrentTranscript()
                } else {
                    clearPosition()
                }
            }
            .onChange(of: transcriptScope) { _, _ in
                installPositionForCurrentTranscript()
            }
    }

    private var positionBinding: Binding<ScrollPosition> {
        Binding(
            get: { position },
            set: { proposedPosition in
                guard proposedPosition.isPositionedByUser else { return }

                // The binding can echo its seeded view ID before lazy geometry
                // confirms that the row is visible. Only a genuine user
                // position may retire the restore seed. ChatScrollObserver
                // supplies the parent with gesture metrics; no per-frame state
                // loop is needed here.
                let canRetireRestoreSeed = isRestoreActive
                    && !hasRetiredInitialPosition
                    && targetMessageID != nil
                guard canRetireRestoreSeed else { return }
                clearPosition()
            }
        )
    }

    private func installPositionForCurrentTranscript() {
        guard isRestoreActive, let targetMessageID else {
            clearPosition()
            return
        }

        hasRetiredInitialPosition = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position = ScrollPosition(id: targetMessageID, anchor: .top)
        }
    }

    private func clearPosition() {
        guard !hasRetiredInitialPosition else { return }
        hasRetiredInitialPosition = true
        // `idType` carries no edge, point, or view-ID request. Keeping this
        // empty value attached preserves modifier identity without issuing a
        // second position command on later body updates.
        position = ScrollPosition(idType: String.self)
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
    var pagingOperation = ChatTranscriptPagingOperationState()
    var automaticPagingAdmitted = false
    var pendingOlderMessagesAnchor: ChatTranscriptViewportAnchor?
    var pendingOlderMessagesLoadCompleted = false
    var pendingOlderMessagesBaselineMessageCount: Int?
    var pendingOlderMessagesBaselineRenderRevision: Int?
    var pendingOlderMessagesBaselineFirstLoadedRowID: String?
    var lastOlderMessagesPrefetchVisibleRowID: String?
    var layoutFollowState = ChatTranscriptLayoutFollowState()
    var hasPendingMeasuredLayoutGrowth = false
    var measuredLayoutFollowTask: Task<Void, Never>?
    var measuredLayoutFollowGeneration = 0
    var measuredLayoutFollowNextAllowedAt: Date?
    var pendingOlderMessagesReconciliation = ChatTranscriptPagingReconciliationState()
    var olderMessagesSettlementExpiryTask: Task<Void, Never>?
    /// The single measured correction is issued once per paging operation, but
    /// a prepend can still be realizing lazily (or a SwiftUI layout pass can
    /// overwrite a UIKit offset change) when the first displaced sample
    /// arrives. The same anchored baseline correction is then re-issued on
    /// fresh displaced samples, strictly bounded by this budget and by the
    /// existing settlement deadline. This never invents a new delta: every
    /// re-issue measures the same captured beforeFrame against the newest
    /// afterFrame.
    var pendingAnchorCorrectionReapplicationCount = 0
#if DEBUG
    var pagingEvidenceSequence = 0
    var pendingPagingEvidence: ChatTranscriptPagingDebugEvidence?
    /// Boundary diagnostics are reset for each paging sequence and capped by
    /// the view's small reason set. They never participate in row layout.
    var pendingAnchorDiagnosticKeys = Set<String>()
    var restoreConfirmationDiagnosticToken: Int?
    var restoreConfirmationDiagnosticDecisions = Set<String>()
#endif

    deinit {
        measuredLayoutFollowTask?.cancel()
    }
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
        // A stale dictionary can survive activation while every message frame
        // has moved outside the viewport (or the lazy stack has no realized
        // row). Treat that as empty geometry: waiting forever here is the
        // same failure mode as a blank transcript that only repaints after a
        // user nudges the scroll view. A cache with visible rows remains
        // conservative so a legitimate reader is never repositioned merely
        // because a preference callback did not repeat.
        return cachedFrameCount == 0 || visibleCachedRowCount == 0
            ? .evaluateEmptyCache
            : .waitForFreshGeometry(visibleCachedRowCount: visibleCachedRowCount)
    }
}

/// A row-frame preference can arrive while an older-page await is still
/// unwinding. Preserve that one reconciliation request until a completed
/// load has caused a fresh transcript view render with the prepended rows.
///
/// This is intentionally a tiny state machine rather than a one-shot bool
/// consumed by the first post-load callback. SwiftUI may deliver that callback
/// from the old message snapshot before the async load's new value has reached
/// the view. In that case the request must survive until the first eligible
/// post-prepend snapshot. A lazy stack can then expose the prepended rows while
/// the captured anchor is still unrealized; that case gets one bounded proxy
/// realization before the measured correction path is allowed to finish.
enum ChatTranscriptPagingReconciliationAction: Equatable {
    case waitForFreshSnapshot
    case requestAnchorRealization
    case applyMeasuredCorrection
    case confirmPreservation
}

/// Initial saved-row restoration and older-page reconciliation share one
/// viewport. A restore that has already produced the confirmed first-visible
/// row may yield to paging; an unconfirmed restore, an activation recovery,
/// or an explicit/user-owned operation keeps priority.
enum ChatTranscriptRestorePagingOwnershipPolicy {
    /// A saved restore is satisfied only by an attached first-visible row with
    /// the same durable ID. A merely visible row, a pre-window preference, or
    /// an unrelated row must not release the restore owner.
    static func hasConfirmedVisibleInitialTarget(
        initialRestoreTargetID: String?,
        firstVisibleMessageID: String?,
        isScrollViewAttached: Bool
    ) -> Bool {
        guard isScrollViewAttached,
              let initialRestoreTargetID,
              let firstVisibleMessageID
        else { return false }

        return initialRestoreTargetID == firstVisibleMessageID
    }

    static func shouldKeepRestoreOwner(
        hasSettlementTask: Bool,
        isInitialRestoreInProgress: Bool,
        hasConfirmedTargetGeometry: Bool,
        isInitialRestorePending: Bool
    ) -> Bool {
        // A viewport-recovery task has no initial-restore token and must retain
        // ownership even if an old saved target was previously observed.
        if hasSettlementTask && !isInitialRestoreInProgress {
            return true
        }
        if hasConfirmedTargetGeometry {
            return false
        }
        return isInitialRestoreInProgress || isInitialRestorePending
    }
}

struct ChatTranscriptPagingReconciliationState: Equatable {
    private(set) var hasPendingEarlyPreference = false
    private(set) var hasRequestedAnchorRealization = false
    private(set) var isCancelled = false
    private(set) var settlementDeadline: TimeInterval?
    private(set) var correctionGeneration: Int?
    // A cancellation ceiling for an idle/missing preference stream, not a
    // settling delay. Successful reconciliation does not wait for this timer.
    static let settlementLifetime: TimeInterval = 2

    mutating func startSettlement(at now: TimeInterval) {
        guard settlementDeadline == nil else { return }
        settlementDeadline = now + Self.settlementLifetime
    }

    /// A command is not proof of presentation. Keep the original deadline and
    /// the single realization budget while awaiting a newer measured sample.
    mutating func recordCorrectionIssued(generation: Int) {
        guard !isCancelled, correctionGeneration == nil else { return }
        correctionGeneration = generation
    }

    /// Expiry abandons preservation; it is never evidence of settled geometry.
    @discardableResult
    mutating func expireSettlement(at now: TimeInterval) -> Bool {
        guard let settlementDeadline, now >= settlementDeadline else { return false }
        cancel()
        return true
    }

    mutating func cancel() {
        reset()
        isCancelled = true
    }

    mutating func recordPreferenceBeforeLoadCompletion() {
        hasPendingEarlyPreference = true
    }

    func shouldRequestFreshViewPassAfterLoad(didLoad: Bool) -> Bool {
        didLoad && hasPendingEarlyPreference
    }

    /// Selects the bounded action for eligible post-prepend snapshots.
    /// The transcript view calls this only after its interaction/restore guards
    /// have established that paging still owns the viewport. A missing lazy
    /// anchor frame requests one existing proxy realization; no repeated
    /// request is permitted until the pending paging operation is reset.
    mutating func actionForEligibleSnapshot(
        loadCompleted: Bool,
        transcriptChanged: Bool,
        firstLoadedIDChanged: Bool,
        hasAnchorFrame: Bool,
        anchorNeedsCorrection: Bool = true,
        sampleGeneration: Int = 0,
        anchorIsVisible: Bool = true
    ) -> ChatTranscriptPagingReconciliationAction {
        guard !isCancelled, loadCompleted,
              transcriptChanged,
              firstLoadedIDChanged
        else {
            return .waitForFreshSnapshot
        }

        if let correctionGeneration {
            guard sampleGeneration > correctionGeneration else { return .waitForFreshSnapshot }
            if hasAnchorFrame {
                return !anchorNeedsCorrection && anchorIsVisible
                    ? .confirmPreservation : .waitForFreshSnapshot
            }
            guard !hasRequestedAnchorRealization else { return .waitForFreshSnapshot }
            hasRequestedAnchorRealization = true
            return .requestAnchorRealization
        }

        // Callback counts do not establish layout completion: several newer
        // preferences can still echo unchanged anchor geometry before lazy
        // layout displaces it. Keep observing within the cancellation ceiling
        // until the anchor actually moves or disappears. Stable no-op pages
        // expire unconfirmed without ever issuing a scroll or claiming success.
        if hasAnchorFrame, !anchorNeedsCorrection {
            return .waitForFreshSnapshot
        }

        guard hasAnchorFrame else {
            guard !hasRequestedAnchorRealization else {
                return .waitForFreshSnapshot
            }
            hasRequestedAnchorRealization = true
            return .requestAnchorRealization
        }

        hasPendingEarlyPreference = false
        return .applyMeasuredCorrection
    }

    @discardableResult
    mutating func consumeIfEligible(
        loadCompleted: Bool,
        transcriptChanged: Bool,
        firstLoadedIDChanged: Bool
    ) -> Bool {
        guard loadCompleted,
              transcriptChanged,
              firstLoadedIDChanged,
              hasPendingEarlyPreference
        else { return false }

        hasPendingEarlyPreference = false
        return true
    }

    mutating func reset() {
        hasPendingEarlyPreference = false
        hasRequestedAnchorRealization = false
        isCancelled = false
        settlementDeadline = nil
        correctionGeneration = nil
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
    let onLoadOlderMessages: (ChatTranscriptOlderLoadIntent, @MainActor () -> Bool) async -> ChatTranscriptOlderLoadResult
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
    var initialRestoreRequest: ChatTranscriptRestoreRequest?
    var isPagingStartupReady = false
    var onInitialRestoreOutcome: (ChatTranscriptRestoreRequest, ChatTranscriptRestoreOutcome) -> Void = { _, _ in }
    var transcriptRestoreCancellationToken: Int = 0
    var followRejoinScrollToken: Int = 0
    var isComposerResizing = false
    var isUserInteractingWithScroll = false
    var transcriptRenderRevision = 0
    var outgoingInsertionScope: UUID?
    var outgoingInsertionEvent: OutgoingInsertionEvent?
    @State private var insertionLedger = OutgoingInsertionLedger()

    @State private var viewportTracker = ChatTranscriptViewportTracker()
    @State private var restoreSettlementTask: Task<Void, Never>?
    @State private var restoreSettlementState = ChatTranscriptRestoreState()
    @State private var hasCompletedInitialRestore = false
    @State private var hasObservedInitialTargetGeometry = false
    @State private var pendingInitialRestoreToken: Int?
    @State private var ownedInitialRestoreRequest: ChatTranscriptRestoreRequest?
    @State private var pendingOlderMessagesReconcileToken = 0
#if DEBUG
    @State private var pendingMessageCountDiagnostic: Int?
    @State private var hasLoggedExplicitBottomTarget = false
    @State private var hasLoggedFirstStreamingAssistantLayout = false
#endif
    private static let transcriptCoordinateSpaceName = "chatTranscript"
#if DEBUG
    private static let activationRecoveryLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "TranscriptActivationRecovery"
    )
    private static let maximumPagingDiagnosticEvents = 24
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

    private var initialRestoreMessageID: String? {
        ChatTranscriptRestorePolicy.initialPositionMessageID(for: restoreTarget)
    }

    private var isInitialRestoreInProgress: Bool {
        guard let pendingInitialRestoreToken else { return false }
        return pendingInitialRestoreToken == restoreScrollToken
    }

    private var automaticPagingAdmitted: Bool {
        ChatTranscriptPagingPolicy.admitsAutomaticLoad(
            startupReady: isPagingStartupReady,
            hasPendingRestore: initialRestoreRequest != nil
                || ownedInitialRestoreRequest != nil || isInitialRestoreInProgress
                || restoreSettlementTask != nil,
            isActive: scenePhase == .active,
            isAttached: viewportTracker.scrollView?.window != nil
        )
    }

#if DEBUG
    /// Records only the first rejected and first confirmed geometry decision
    /// for the current restore token. The target identity is intentionally
    /// reduced to booleans; this is a boundary probe, not transcript logging.
    private func logInitialRestoreConfirmationIfNeeded(
        visibleMessageID: String?,
        targetFrameVisible: Bool,
        isScrollViewAttached: Bool,
        source: String
    ) {
        guard initialRestoreMessageID != nil else { return }

        if viewportTracker.restoreConfirmationDiagnosticToken != restoreScrollToken {
            viewportTracker.restoreConfirmationDiagnosticToken = restoreScrollToken
            viewportTracker.restoreConfirmationDiagnosticDecisions.removeAll(keepingCapacity: true)
        }

        let targetFirstVisibleMatch = initialRestoreMessageID == visibleMessageID
        let isConfirmed = targetFirstVisibleMatch && targetFrameVisible && isScrollViewAttached
        let decision = isConfirmed ? "target_confirmed" : "target_rejected"
        guard !viewportTracker.restoreConfirmationDiagnosticDecisions.contains(decision),
              viewportTracker.restoreConfirmationDiagnosticDecisions.count < 2
        else { return }
        viewportTracker.restoreConfirmationDiagnosticDecisions.insert(decision)

        let stateToken = restoreSettlementState.restoreToken
        let currentMetrics = currentScrollMetricsForRecovery() ?? viewportTracker.latestScrollMetrics
        let directlyInteracting = currentMetrics?.isDirectlyInteracting ?? false
        let decelerating = currentMetrics?.isDecelerating ?? false
        let pendingTokenMatches = pendingInitialRestoreToken.map {
            $0 == restoreScrollToken
        } ?? false
        let stateTokenMatches = stateToken.map {
            $0 == restoreScrollToken
        } ?? false
        let pagingSequence = viewportTracker.pendingPagingEvidence
            .map { String($0.sequence) } ?? "none"

        Self.activationRecoveryLogger.debug("""
            event=initial_restore_confirmation decision=\(decision, privacy: .public) source=\(source, privacy: .public) \
            restoreToken=\(restoreScrollToken, privacy: .public) restoreTokenPresent=\(restoreScrollToken > 0, privacy: .public) \
            pendingRestoreTokenPresent=\(pendingInitialRestoreToken != nil, privacy: .public) pendingRestoreTokenMatches=\(pendingTokenMatches, privacy: .public) \
            stateRestoreTokenPresent=\(stateToken != nil, privacy: .public) stateRestoreTokenMatches=\(stateTokenMatches, privacy: .public) \
            targetFirstVisibleMatch=\(targetFirstVisibleMatch, privacy: .public) targetFrameVisible=\(targetFrameVisible, privacy: .public) attached=\(isScrollViewAttached, privacy: .public) \
            restoreCancelled=\(restoreSettlementState.isCancelled, privacy: .public) restoreTaskPresent=\(restoreSettlementTask != nil, privacy: .public) \
            hasCompletedInitialRestore=\(hasCompletedInitialRestore, privacy: .public) hasObservedInitialTargetGeometry=\(hasObservedInitialTargetGeometry, privacy: .public) \
            initialRestoreInProgress=\(isInitialRestoreInProgress, privacy: .public) initialRestorePending=\(isInitialRestorePending, privacy: .public) \
            pagingSequence=\(pagingSequence, privacy: .public) framesGeneration=\(viewportTracker.framesGeneration, privacy: .public) \
            directlyInteracting=\(directlyInteracting, privacy: .public) decelerating=\(decelerating, privacy: .public)
            """)
    }
#endif

    /// Records the only geometry that can hand the shared viewport from the
    /// initial saved-row restore to older-page reconciliation. This is called
    /// from both the normal preference pass and the paging handoff because the
    /// latter can be the first callback that still has the captured first row
    /// after a native seed has positioned the transcript.
    @discardableResult
    private func confirmInitialRestoreTargetIfVisible(
        visibleMessageID: String?,
        isScrollViewAttached: Bool
    ) -> Bool {
        guard ChatTranscriptRestorePagingOwnershipPolicy.hasConfirmedVisibleInitialTarget(
            initialRestoreTargetID: initialRestoreMessageID,
            firstVisibleMessageID: visibleMessageID,
            isScrollViewAttached: isScrollViewAttached
        ) else {
            return false
        }

        if let request = ownedInitialRestoreRequest,
           case let .message(requestedID) = request.target,
           requestedID != visibleMessageID {
            return false
        }
        hasObservedInitialTargetGeometry = true
        if isInitialRestoreInProgress {
            // The saved row is already the first visible geometry. Transfer
            // ownership to a pending page instead of letting the restore task
            // wake later and issue a competing jump.
            restoreSettlementTask?.cancel()
            restoreSettlementTask = nil
            hasCompletedInitialRestore = true
            pendingInitialRestoreToken = nil
            completeInitialRestore(.success, request: ownedInitialRestoreRequest)
        }
        return true
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
        .onDisappear {
            clearPendingOlderMessagesAnchor(reason: "disappear")
            insertionLedger.unmount()
            invalidateMeasuredLayoutFollow()
#if DEBUG
            viewportTracker.pendingPagingEvidence = nil
#endif
        }
        .onChange(of: outgoingInsertionScope) { _, scope in
            invalidateMeasuredLayoutFollow()
            insertionLedger.mount(scope: scope, through: outgoingInsertionEvent?.sequence ?? 0)
            resetViewportForNewTranscript()
        }
        .onChange(of: restoreScrollToken) { _, _ in
            invalidateMeasuredLayoutFollow()
            clearPendingOlderMessagesAnchor(reason: "restore_token_changed")
            hasObservedInitialTargetGeometry = false
            insertionLedger.discardPending(through: outgoingInsertionEvent?.sequence ?? 0)
#if DEBUG
            viewportTracker.pendingPagingEvidence = nil
#endif
        }
        .onChange(of: shouldFollowLatestMessage) { _, follows in
            if follows {
                // Latest-follow ownership supersedes an unresolved older-page
                // realization. Do not let a stale reader correction block the
                // send/latest path indefinitely.
                clearPendingOlderMessagesAnchor(reason: "follow_latest_ownership")
            } else {
                invalidateMeasuredLayoutFollow()
                insertionLedger.discardPending(through: outgoingInsertionEvent?.sequence ?? 0)
#if DEBUG
                viewportTracker.pendingPagingEvidence = nil
#endif
            }
        }
        .onChange(of: isUserInteractingWithScroll) { _, isInteracting in
            if isInteracting {
                invalidateMeasuredLayoutFollow()
                clearPendingOlderMessagesAnchor(reason: "user_or_deceleration_owned")
#if DEBUG
                viewportTracker.pendingPagingEvidence = nil
#endif
            }
        }
        .onChange(of: isLoadingOlderMessages) { _, isLoading in
            if isLoading {
                invalidateMeasuredLayoutFollow()
            }
        }
        .onChange(of: outgoingInsertionEvent) { _, event in
            if !shouldFollowLatestMessage || restoreSettlementTask != nil || isInitialRestoreInProgress {
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
                let hasSavedRestoreMessage = initialRestoreMessageID.map { messageID in
                    renderedMessages.contains { $0.renderID == messageID }
                } ?? false

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
                        ChatTranscriptRestorePolicy.initialTranscriptAnchor(
                            for: restoreTarget,
                            hasSavedMessage: hasSavedRestoreMessage
                        ),
                        for: .initialOffset
                    )
                    .defaultScrollAnchor(
                        ChatScrollPolicy.sizeChangeAnchor(
                            shouldFollowLatestMessage: shouldFollowLatestMessage,
                            isComposerResizing: isComposerResizing
                        ),
                        for: .sizeChanges
                    )
                    .modifier(ChatTranscriptInitialPositionModifier(
                        targetMessageID: initialRestoreMessageID,
                        transcriptScope: outgoingInsertionScope,
                        isRestoreActive: initialRestoreMessageID != nil
                            && !hasCompletedInitialRestore
                            && !hasObservedInitialTargetGeometry
                    ))
                    .frame(width: viewportWidth)
                    .refreshable {
                        if hasOlderMessages {
                            await loadOlderMessagesPreservingPosition(proxy: proxy, intent: .explicitUserRequest)
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
                                    cancelTranscriptRestore(reason: "explicit_bottom")
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
                    guard phase == .active else {
                        restoreSettlementState.invalidateVisibilityEvidence()
                        if ownedInitialRestoreRequest != nil || restoreSettlementTask != nil {
                            cancelTranscriptRestore(reason: "scene_inactive")
                        }
                        clearPendingOlderMessagesAnchor(reason: "scene_inactive")
                        invalidateMeasuredLayoutFollow()
#if DEBUG
                        viewportTracker.pendingPagingEvidence = nil
#endif
                        return
                    }
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
                    reconcilePendingOlderMessagesAnchorAfterEarlyPreference(
                        proxy: proxy,
                        currentFirstLoadedRowID: renderedMessages.first?.renderID
                    )
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
                .onChange(of: pendingOlderMessagesReconcileToken) {
                    reconcilePendingOlderMessagesAnchorAfterEarlyPreference(
                        proxy: proxy,
                        currentFirstLoadedRowID: renderedMessages.first?.renderID
                    )
                }
                .onChange(of: automaticPagingAdmitted) { _, admitted in
                    viewportTracker.automaticPagingAdmitted = admitted
                    guard admitted else { return }
                    // Ownership handoff must not force a synchronous layout:
                    // layoutIfNeeded() mid-update re-enters lazy placement and
                    // scroll-anchor translation from the handoff's own output
                    // (P16 livelock). The reconcile token stands; the next
                    // natural preference sample admits a load. Never poll/load.
                    pendingOlderMessagesReconcileToken &+= 1
                }
#if DEBUG
                .onChange(of: activeStreamID) { oldStreamID, newStreamID in
                    if newStreamID != nil {
                        hasLoggedFirstStreamingAssistantLayout = false
                    } else if oldStreamID != nil {
                        logTranscriptScrollSnapshot(
                            event: "stream_completion_geometry",
                            decision: "stream_active_to_nil",
                            viewportHeight: viewport.size.height,
                            targetKind: "latest_content"
                        )
                        hasLoggedFirstStreamingAssistantLayout = false
                    }
                }
#endif
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
                    invalidateMeasuredLayoutFollow()
                    hasCompletedInitialRestore = false
                    pendingInitialRestoreToken = restoreScrollToken
                    applyTranscriptRestore(proxy, viewportHeight: viewport.size.height)
                }
                .onChange(of: transcriptRestoreCancellationToken) {
                    cancelTranscriptRestore(reason: "cancellation_token")
                }
                .onChange(of: hasExplicitBottomScrollRequest) { _, active in
                    if active {
                        clearPendingOlderMessagesAnchor(reason: "explicit_bottom_owned")
                        invalidateMeasuredLayoutFollow()
                    }
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
                    restoreSettlementState.invalidateVisibilityEvidence()
                    completeInitialRestore(.cancelled, request: ownedInitialRestoreRequest)
                    restoreSettlementTask?.cancel()
                    restoreSettlementTask = nil
                    invalidateMeasuredLayoutFollow()
                    viewportTracker.activationRecoveryState.disarm()
#if DEBUG
                    viewportTracker.pendingPagingEvidence = nil
#endif
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
#if DEBUG
                    logFirstStreamingAssistantLayoutIfNeeded(
                        frames: frames,
                        renderedMessages: renderedMessages,
                        viewportHeight: viewport.size.height
                    )
#endif
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
                    let isAttachedToActiveScene = scenePhase == .active
                        && viewportTracker.scrollView?.window != nil
                    restoreSettlementState.recordTailVisibility(
                        isBottomVisible, isAttachedToActiveScene: isAttachedToActiveScene
                    )
                    onTranscriptTailVisibilityChange(isLatestRowVisible, isBottomVisible)
                    let visibleRow = ChatTranscriptVisibilityPolicy.firstVisibleMessage(
                        frames: frames.filter { $0.key != bottomAnchorID },
                        viewportHeight: viewport.size.height
                    )
                    let isScrollViewAttached = viewportTracker.scrollView?.window != nil
                    // SwiftUI can publish a pre-window preference pass. It is
                    // useful for neither first-paint nor settlement evidence:
                    // recording it could let a target echo retire the seed
                    // before the host is actually attached.
#if DEBUG
                    logInitialRestoreConfirmationIfNeeded(
                        visibleMessageID: visibleRow?.id,
                        targetFrameVisible: isVisible(visibleRow?.frame),
                        isScrollViewAttached: isScrollViewAttached,
                        source: "visible_row_preference"
                    )
#endif
                    restoreSettlementState.recordVisibleMessageSample(
                        visibleRow?.id, isAttachedToActiveScene: isAttachedToActiveScene
                    )
                    confirmInitialRestoreTargetIfVisible(
                        visibleMessageID: visibleRow?.id,
                        isScrollViewAttached: isScrollViewAttached
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
#if DEBUG
                    recordPagingEvidenceAfterPreferenceIfReady(
                        frames: frames,
                        viewportHeight: viewport.size.height
                    )
#endif

                    let firstLoadedRow = renderedMessages.first.flatMap { message in
                        frames[message.renderID].map {
                            ChatTranscriptVisibilityPolicy.VisibleRow(
                                id: message.renderID,
                                frame: $0
                            )
                        }
                    }

                    viewportTracker.automaticPagingAdmitted = automaticPagingAdmitted
                    if !hasOlderMessages {
                        viewportTracker.lastOlderMessagesPrefetchVisibleRowID = nil
                    } else if ChatTranscriptPagingPolicy.shouldPrefetchOlderMessages(
                        firstLoadedRow: firstLoadedRow,
                        firstVisibleRow: visibleRow,
                        viewportHeight: viewport.size.height,
                        hasOlderMessages: hasOlderMessages,
                        isLoadingOlderMessages: isLoadingOlderMessages
                            || viewportTracker.olderMessagesLoadInFlight
                            || viewportTracker.pendingOlderMessagesAnchor != nil,
                        hasPendingRestore: !automaticPagingAdmitted,
                        shouldFollowLatest: shouldFollowLatestMessage,
                        lastRequestedVisibleRowID: viewportTracker.lastOlderMessagesPrefetchVisibleRowID
                    ), let visibleRow {
                        beginOlderMessagesPrefetch(proxy: proxy, row: visibleRow)
                    }

                    scheduleMeasuredLayoutFollowIfReady(
                        proxy: proxy,
                        frames: frames,
                        latestRenderedID: latestRenderedID
                    )
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
    private func debugOpaquePagingAnchorKey(_ anchorID: String) -> String {
        // Swift's String.hashValue is intentionally randomized between
        // launches. FNV-1a keeps this diagnostic key stable without exposing
        // the transcript row ID or adding a dependency.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in anchorID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func currentTranscriptViewportGlobalFrame() -> CGRect? {
        guard let scrollView = viewportTracker.scrollView,
              scrollView.window != nil,
              !scrollView.bounds.isEmpty
        else { return nil }

        // The row preference is in the SwiftUI named transcript space. UIKit's
        // conversion of its bounds to the window base space supplies the
        // actual visible viewport origin for an explicit local-to-global
        // transform. Runtime UI evidence must still compare this against AX.
        return scrollView.convert(scrollView.bounds, to: nil)
    }

    private func globalFrame(
        for transcriptFrame: CGRect,
        viewportGlobalFrame: CGRect?
    ) -> CGRect? {
        guard let viewportGlobalFrame else { return nil }
        return CGRect(
            x: viewportGlobalFrame.minX + transcriptFrame.minX,
            y: viewportGlobalFrame.minY + transcriptFrame.minY,
            width: transcriptFrame.width,
            height: transcriptFrame.height
        )
    }

    private func nextPagingEvidenceSequence() -> Int {
        if viewportTracker.pagingEvidenceSequence == Int.max {
            viewportTracker.pagingEvidenceSequence = 1
        } else {
            viewportTracker.pagingEvidenceSequence += 1
        }
        return viewportTracker.pagingEvidenceSequence
    }

    private func shouldRecordPagingDiagnostic(_ key: String) -> Bool {
        guard !viewportTracker.pendingAnchorDiagnosticKeys.contains(key),
              viewportTracker.pendingAnchorDiagnosticKeys.count
                < Self.maximumPagingDiagnosticEvents
        else { return false }
        viewportTracker.pendingAnchorDiagnosticKeys.insert(key)
        return true
    }

    private func pagingDiagnosticIdentity(
        anchor: ChatTranscriptViewportAnchor? = nil,
        evidence: ChatTranscriptPagingDebugEvidence? = nil
    ) -> (sequence: String, anchorKey: String) {
        let sequence = evidence.map { String($0.sequence) } ?? "none"
        let anchorKey = evidence?.anchorKey
            ?? anchor.map { debugOpaquePagingAnchorKey($0.messageID) }
            ?? "none"
        return (sequence, anchorKey)
    }

    private func logPendingOlderMessagesAnchorClearIfNeeded(reason: String) {
        let anchor = viewportTracker.pendingOlderMessagesAnchor
        let evidence = viewportTracker.pendingPagingEvidence
        guard anchor != nil || evidence != nil else { return }

        let identity = pagingDiagnosticIdentity(anchor: anchor, evidence: evidence)
        let key = "pending_clear|\(identity.sequence)|\(identity.anchorKey)|\(reason)"
        guard shouldRecordPagingDiagnostic(key) else { return }

        let anchorFrame = anchor?.frame ?? evidence?.beforeFrame
        let anchorViewportHeight = anchor?.viewportHeight
            ?? (viewportTracker.viewportHeight > 0 ? viewportTracker.viewportHeight : nil)
        let anchorFrameVisible = anchorFrame.map {
            ChatTranscriptVisibilityPolicy.isVisible(
                frame: $0,
                viewportHeight: anchorViewportHeight ?? 0,
                bottomInset: transcriptBottomInsetHeight
            )
        } ?? false
        let metrics = currentScrollMetricsForRecovery() ?? viewportTracker.latestScrollMetrics
        let stateToken = restoreSettlementState.restoreToken
        let stateTokenMatches = stateToken.map { $0 == restoreScrollToken } ?? false
        let pendingTokenMatches = pendingInitialRestoreToken.map {
            $0 == restoreScrollToken
        } ?? false
        let directlyInteracting = metrics?.isDirectlyInteracting ?? false
        let decelerating = metrics?.isDecelerating ?? false

        Self.activationRecoveryLogger.debug("""
            event=older_anchor_pending_clear decision=\(reason, privacy: .public) \
            pagingSequence=\(identity.sequence, privacy: .public) pagingAnchorKey=\(identity.anchorKey, privacy: .public) \
            pendingAnchorPresent=\(anchor != nil, privacy: .public) pendingEvidencePresent=\(evidence != nil, privacy: .public) \
            capturedBeforeFramePresent=\(anchorFrame != nil, privacy: .public) capturedBeforeFrameVisible=\(anchorFrameVisible, privacy: .public) \
            restoreToken=\(restoreScrollToken, privacy: .public) restoreTokenPresent=\(restoreScrollToken > 0, privacy: .public) \
            pendingRestoreTokenPresent=\(pendingInitialRestoreToken != nil, privacy: .public) pendingRestoreTokenMatches=\(pendingTokenMatches, privacy: .public) \
            stateRestoreTokenPresent=\(stateToken != nil, privacy: .public) stateRestoreTokenMatches=\(stateTokenMatches, privacy: .public) \
            restoreCancelled=\(restoreSettlementState.isCancelled, privacy: .public) restoreTaskPresent=\(restoreSettlementTask != nil, privacy: .public) \
            hasCompletedInitialRestore=\(hasCompletedInitialRestore, privacy: .public) hasObservedInitialTargetGeometry=\(hasObservedInitialTargetGeometry, privacy: .public) \
            initialRestoreInProgress=\(isInitialRestoreInProgress, privacy: .public) initialRestorePending=\(isInitialRestorePending, privacy: .public) \
            shouldFollowLatest=\(shouldFollowLatestMessage, privacy: .public) explicitBottomRequest=\(hasExplicitBottomScrollRequest, privacy: .public) \
            directlyInteracting=\(directlyInteracting, privacy: .public) decelerating=\(decelerating, privacy: .public) attached=\(viewportTracker.scrollView?.window != nil, privacy: .public) \
            framesGeneration=\(viewportTracker.framesGeneration, privacy: .public) pendingLoadCompleted=\(viewportTracker.pendingOlderMessagesLoadCompleted, privacy: .public) \
            reconcileToken=\(pendingOlderMessagesReconcileToken, privacy: .public) messages=\(messages.count, privacy: .public) renderRevision=\(transcriptRenderRevision, privacy: .public)
            """)
    }

    private func logPagingReconcileDispositionIfNeeded(
        decision: String,
        anchor: ChatTranscriptViewportAnchor,
        frames: [String: CGRect],
        currentFirstLoadedRowID: String?,
        transcriptChanged: Bool? = nil,
        firstLoadedIDChanged: Bool? = nil,
        restoreOwnsViewport: Bool? = nil,
        userOwned: Bool? = nil
    ) {
        let evidence = viewportTracker.pendingPagingEvidence
        let identity = pagingDiagnosticIdentity(anchor: anchor, evidence: evidence)
        let key = "reconcile|\(identity.sequence)|\(identity.anchorKey)|\(decision)"
        guard shouldRecordPagingDiagnostic(key) else { return }

        let anchorFrame = frames[anchor.messageID]
        let viewportHeight = anchor.viewportHeight ?? viewportTracker.viewportHeight
        let anchorFrameVisible = anchorFrame.map {
            ChatTranscriptVisibilityPolicy.isVisible(
                frame: $0,
                viewportHeight: viewportHeight,
                bottomInset: transcriptBottomInsetHeight
            )
        } ?? false
        let baselineFirstLoadedRowID = viewportTracker.pendingOlderMessagesBaselineFirstLoadedRowID
        let knownFirstLoadedIDChanged = baselineFirstLoadedRowID.flatMap { baselineID in
            currentFirstLoadedRowID.map { currentID in baselineID != currentID }
        }
        let metrics = currentScrollMetricsForRecovery() ?? viewportTracker.latestScrollMetrics
        let stateToken = restoreSettlementState.restoreToken
        let stateTokenMatches = stateToken.map { $0 == restoreScrollToken } ?? false
        let pendingTokenMatches = pendingInitialRestoreToken.map {
            $0 == restoreScrollToken
        } ?? false
        let optionalBool: (Bool?) -> String = { value in
            value.map { $0 ? "true" : "false" } ?? "unknown"
        }

        Self.activationRecoveryLogger.debug("""
            event=older_anchor_reconcile decision=\(decision, privacy: .public) \
            pagingSequence=\(identity.sequence, privacy: .public) pagingAnchorKey=\(identity.anchorKey, privacy: .public) \
            loadCompleted=\(viewportTracker.pendingOlderMessagesLoadCompleted, privacy: .public) \
            transcriptChanged=\(optionalBool(transcriptChanged), privacy: .public) \
            firstLoadedIDChanged=\(optionalBool(firstLoadedIDChanged ?? knownFirstLoadedIDChanged), privacy: .public) \
            anchorFramePresent=\(anchorFrame != nil, privacy: .public) anchorFrameVisible=\(anchorFrameVisible, privacy: .public) \
            hasPendingEarlyPreference=\(viewportTracker.pendingOlderMessagesReconciliation.hasPendingEarlyPreference, privacy: .public) \
            hasRequestedAnchorRealization=\(viewportTracker.pendingOlderMessagesReconciliation.hasRequestedAnchorRealization, privacy: .public) \
            restoreOwnsViewport=\(optionalBool(restoreOwnsViewport), privacy: .public) userOwned=\(optionalBool(userOwned), privacy: .public) \
            restoreToken=\(restoreScrollToken, privacy: .public) restoreTokenPresent=\(restoreScrollToken > 0, privacy: .public) \
            pendingRestoreTokenPresent=\(pendingInitialRestoreToken != nil, privacy: .public) pendingRestoreTokenMatches=\(pendingTokenMatches, privacy: .public) \
            stateRestoreTokenPresent=\(stateToken != nil, privacy: .public) stateRestoreTokenMatches=\(stateTokenMatches, privacy: .public) \
            restoreCancelled=\(restoreSettlementState.isCancelled, privacy: .public) restoreTaskPresent=\(restoreSettlementTask != nil, privacy: .public) \
            hasCompletedInitialRestore=\(hasCompletedInitialRestore, privacy: .public) hasObservedInitialTargetGeometry=\(hasObservedInitialTargetGeometry, privacy: .public) \
            shouldFollowLatest=\(shouldFollowLatestMessage, privacy: .public) explicitBottomRequest=\(hasExplicitBottomScrollRequest, privacy: .public) \
            directlyInteracting=\(metrics?.isDirectlyInteracting ?? false, privacy: .public) decelerating=\(metrics?.isDecelerating ?? false, privacy: .public) \
            attached=\(viewportTracker.scrollView?.window != nil, privacy: .public) framesGeneration=\(viewportTracker.framesGeneration, privacy: .public) \
            reconcileToken=\(pendingOlderMessagesReconcileToken, privacy: .public) messages=\(messages.count, privacy: .public) renderRevision=\(transcriptRenderRevision, privacy: .public)
            """)
    }

    private func logPagingLoadBoundary(
        event: String,
        decision: String,
        viewportHeight: CGFloat,
        sequence: Int?,
        anchorKey: String?,
        messagesBefore: Int,
        messagesAfter: Int,
        didLoad: Bool? = nil,
        elapsedMilliseconds: Double? = nil,
        taskCancelled: Bool? = nil
    ) {
        let sequenceValue = sequence.map(String.init) ?? "none"
        let anchorKeyValue = anchorKey ?? "none"
        let didLoadValue = didLoad.map { $0 ? "true" : "false" } ?? "unknown"
        let elapsedValue = elapsedMilliseconds.map { String(format: "%.3f", $0) } ?? "unknown"
        let cancelledValue = taskCancelled.map { $0 ? "true" : "false" } ?? "unknown"

        Self.activationRecoveryLogger.debug("""
            event=\(event, privacy: .public) decision=\(decision, privacy: .public) targetKind=older_anchor \
            pagingSequence=\(sequenceValue, privacy: .public) pagingAnchorKey=\(anchorKeyValue, privacy: .public) \
            viewportHeight=\(Double(viewportHeight), privacy: .public) messagesBefore=\(messagesBefore, privacy: .public) messagesAfter=\(messagesAfter, privacy: .public) \
            didLoad=\(didLoadValue, privacy: .public) elapsedMilliseconds=\(elapsedValue, privacy: .public) taskCancelled=\(cancelledValue, privacy: .public)
            """)
    }

    private func logPagingSilentGuardIfNeeded(
        decision: String,
        viewportHeight: CGFloat
    ) {
        guard var evidence = viewportTracker.pendingPagingEvidence,
              !evidence.loggedSilentGuardReasons.contains(decision)
        else { return }

        evidence.loggedSilentGuardReasons.insert(decision)
        viewportTracker.pendingPagingEvidence = evidence
        logTranscriptScrollSnapshot(
            event: "older_anchor_silent_guard",
            decision: decision,
            viewportHeight: viewportHeight,
            targetKind: "older_anchor",
            targetExists: true,
            pagingSequence: evidence.sequence,
            pagingAnchorKey: evidence.anchorKey,
            pagingStartGeneration: evidence.startGeneration
        )
    }

    private func recordPagingEvidenceBeforeLoad(
        anchor: ChatTranscriptViewportAnchor,
        viewportHeight: CGFloat
    ) {
        guard let beforeFrame = anchor.frame else { return }

        if viewportTracker.pendingPagingEvidence != nil {
            logPagingEvidenceWithoutSettledFrame(
                decision: "next_prefetch_before_settlement",
                viewportHeight: viewportHeight
            )
        }

        let viewportGlobalFrame = currentTranscriptViewportGlobalFrame()
        let beforeGlobalFrame = globalFrame(
            for: beforeFrame,
            viewportGlobalFrame: viewportGlobalFrame
        )
        let sequence = nextPagingEvidenceSequence()
        let anchorKey = debugOpaquePagingAnchorKey(anchor.messageID)
        viewportTracker.pendingPagingEvidence = ChatTranscriptPagingDebugEvidence(
            sequence: sequence,
            anchorID: anchor.messageID,
            anchorKey: anchorKey,
            beforeFrame: beforeFrame,
            beforeGlobalFrame: beforeGlobalFrame,
            viewportGlobalFrame: viewportGlobalFrame,
            startGeneration: viewportTracker.framesGeneration
        )
        logTranscriptScrollSnapshot(
            event: "older_prefetch_started",
            decision: "automatic_anchor_capture",
            viewportHeight: viewportHeight,
            targetKind: "older_anchor",
            targetExists: true,
            targetVisible: ChatTranscriptVisibilityPolicy.isVisible(
                frame: beforeFrame,
                viewportHeight: viewportHeight,
                bottomInset: transcriptBottomInsetHeight
            ),
            attempt: 0,
            focusedFrame: beforeFrame,
            focusedGlobalFrame: beforeGlobalFrame,
            viewportGlobalFrame: viewportGlobalFrame,
            pagingSequence: sequence,
            pagingAnchorKey: anchorKey,
            pagingStartGeneration: viewportTracker.framesGeneration
        )
    }

    private func armPagingEvidenceForSettledPreference() {
        guard var evidence = viewportTracker.pendingPagingEvidence else { return }
        evidence.awaitsSettledPreference = true
        evidence.minimumSettledGeneration = viewportTracker.framesGeneration + 1
        viewportTracker.pendingPagingEvidence = evidence
    }

    private func recordPagingEvidenceAfterPreferenceIfReady(
        frames: [String: CGRect],
        viewportHeight: CGFloat
    ) {
        guard let evidence = viewportTracker.pendingPagingEvidence,
              evidence.awaitsSettledPreference,
              viewportTracker.framesGeneration >= evidence.minimumSettledGeneration
        else { return }
        recordPagingPostCommandObservation(source: "preference", frames: frames)

        let currentMetrics = currentScrollMetricsForRecovery() ?? viewportTracker.latestScrollMetrics
        guard !isUserInteractingWithScroll,
              currentMetrics?.isDirectlyInteracting != true,
              currentMetrics?.isDecelerating != true
        else {
            logTranscriptScrollSnapshot(
                event: "older_anchor_observation_cancelled",
                decision: "user_interaction_owned_viewport",
                viewportHeight: viewportHeight,
                targetKind: "older_anchor",
                targetExists: true,
                focusedGlobalFrame: nil,
                pagingSequence: evidence.sequence,
                pagingAnchorKey: evidence.anchorKey,
                pagingStartGeneration: evidence.startGeneration
            )
            viewportTracker.pendingPagingEvidence = nil
            return
        }

        guard let afterFrame = frames[evidence.anchorID],
              !ChatTranscriptPagingPolicy.shouldRestorePrependedAnchor(
                beforeFrame: evidence.beforeFrame, afterFrame: afterFrame
              ),
              ChatTranscriptVisibilityPolicy.isVisible(
                frame: afterFrame, viewportHeight: viewportHeight,
                bottomInset: transcriptBottomInsetHeight
              ),
              let viewportGlobalFrame = currentTranscriptViewportGlobalFrame() else { return }
        logTranscriptScrollSnapshot(
            event: "older_anchor_after_correction",
            decision: "correction_target_confirmed",
            viewportHeight: viewportHeight,
            targetKind: "older_anchor",
            targetExists: true,
            targetVisible: ChatTranscriptVisibilityPolicy.isVisible(
                frame: afterFrame,
                viewportHeight: viewportHeight,
                bottomInset: transcriptBottomInsetHeight
            ),
            attempt: 0,
            focusedFrame: afterFrame,
            focusedGlobalFrame: globalFrame(
                for: afterFrame,
                viewportGlobalFrame: viewportGlobalFrame
            ),
            viewportGlobalFrame: viewportGlobalFrame,
            pagingSequence: evidence.sequence,
            pagingAnchorKey: evidence.anchorKey,
            pagingStartGeneration: evidence.startGeneration,
            correctionGeneration: evidence.correctionGeneration,
            correctionAfterFrameMinY: afterFrame.minY
        )
        viewportTracker.pendingPagingEvidence = nil
    }

    /// Scalar-only bounded observations. Missing lazy rows are evidence too;
    /// metrics/content-size callbacks label their cached preference generation
    /// rather than claiming they measured a fresh row frame.
    private func recordPagingPostCommandObservation(source: String, frames: [String: CGRect]) {
        guard var evidence = viewportTracker.pendingPagingEvidence,
              let correctionGeneration = evidence.correctionGeneration else { return }
        let count = evidence.postCommandObservationCounts[source, default: 0]
        guard count < (source == "preference" ? 4 : 2) else { return }
        evidence.postCommandObservationCounts[source] = count + 1
        viewportTracker.pendingPagingEvidence = evidence
        let frame = frames[evidence.anchorID]
        let offsetY = viewportTracker.scrollView?.contentOffset.y ?? .nan
        let contentHeight = viewportTracker.scrollView?.contentSize.height ?? .nan
        let boundsHeight = viewportTracker.scrollView?.bounds.height ?? .nan
        let insetTop = viewportTracker.scrollView?.adjustedContentInset.top ?? .nan
        let insetBottom = viewportTracker.scrollView?.adjustedContentInset.bottom ?? .nan
        Self.activationRecoveryLogger.debug("""
            event=older_anchor_post_command_observation source=\(source, privacy: .public) \
            pagingSequence=\(evidence.sequence, privacy: .public) pagingAnchorKey=\(evidence.anchorKey, privacy: .public) \
            correctionGeneration=\(correctionGeneration, privacy: .public) framesGeneration=\(viewportTracker.framesGeneration, privacy: .public) \
            anchorPresent=\(frame != nil, privacy: .public) capturedBeforeMinY=\(Double(evidence.beforeFrame.minY), privacy: .public) \
            sampledMinY=\(Double(frame?.minY ?? .nan), privacy: .public) \
            contentOffsetY=\(Double(offsetY), privacy: .public) contentSizeHeight=\(Double(contentHeight), privacy: .public) \
            boundsHeight=\(Double(boundsHeight), privacy: .public) insetTop=\(Double(insetTop), privacy: .public) insetBottom=\(Double(insetBottom), privacy: .public)
            """)
    }

    private func logPagingEvidenceWithoutSettledFrame(
        decision: String,
        viewportHeight: CGFloat
    ) {
        guard let evidence = viewportTracker.pendingPagingEvidence else { return }
        logTranscriptScrollSnapshot(
            event: "older_anchor_observation_incomplete",
            decision: decision,
            viewportHeight: viewportHeight,
            targetKind: "older_anchor",
            targetExists: true,
            pagingSequence: evidence.sequence,
            pagingAnchorKey: evidence.anchorKey,
            pagingStartGeneration: evidence.startGeneration
        )
        viewportTracker.pendingPagingEvidence = nil
    }

    private func logPagingCorrectionOffsetTransitionIfNeeded(
        afterFrame: CGRect,
        contentOffsetBeforeY: CGFloat?,
        contentOffsetAfterY: CGFloat?
    ) {
        guard var evidence = viewportTracker.pendingPagingEvidence,
              evidence.correctionGeneration == nil
        else { return }

        let correctionGeneration = viewportTracker.framesGeneration
        evidence.correctionGeneration = correctionGeneration
        viewportTracker.pendingPagingEvidence = evidence

        let beforeOffset = contentOffsetBeforeY.map {
            String(format: "%.3f", Double($0))
        } ?? "unknown"
        let afterOffset = contentOffsetAfterY.map {
            String(format: "%.3f", Double($0))
        } ?? "unknown"
        Self.activationRecoveryLogger.debug("""
            event=older_anchor_correction_offset_transition decision=correction_boundary \
            pagingSequence=\(evidence.sequence, privacy: .public) pagingAnchorKey=\(evidence.anchorKey, privacy: .public) \
            correctionGeneration=\(correctionGeneration, privacy: .public) afterFrameMinY=\(Double(afterFrame.minY), privacy: .public) \
            contentOffsetBeforeY=\(beforeOffset, privacy: .public) contentOffsetImmediatelyAfterY=\(afterOffset, privacy: .public)
            """)
    }

    private func cancelPagingEvidenceForUserInteraction(viewportHeight: CGFloat) {
        guard let evidence = viewportTracker.pendingPagingEvidence else { return }
        logTranscriptScrollSnapshot(
            event: "older_anchor_observation_cancelled",
            decision: "user_interaction_owned_viewport",
            viewportHeight: viewportHeight,
            targetKind: "older_anchor",
            targetExists: true,
            pagingSequence: evidence.sequence,
            pagingAnchorKey: evidence.anchorKey,
            pagingStartGeneration: evidence.startGeneration
        )
        viewportTracker.pendingPagingEvidence = nil
    }

    /// Emits bounded, content-free transcript viewport evidence. It omits
    /// transcript text, raw row IDs, profile names, and paths.
    private func logTranscriptScrollSnapshot(
        event: String,
        decision: String,
        viewportHeight: CGFloat,
        targetKind: String = "none",
        targetExists: Bool? = nil,
        targetVisible: Bool? = nil,
        attempt: Int? = nil,
        animated: Bool? = nil,
        outgoingUserInsertion: Bool? = nil,
        focusedFrame: CGRect? = nil,
        focusedGlobalFrame: CGRect? = nil,
        viewportGlobalFrame: CGRect? = nil,
        pagingSequence: Int? = nil,
        pagingAnchorKey: String? = nil,
        pagingStartGeneration: Int? = nil,
        correctionGeneration: Int? = nil,
        correctionAfterFrameMinY: CGFloat? = nil
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
        let focusedFrameMinY = focusedFrame?.minY ?? .nan
        let focusedFrameMaxY = focusedFrame?.maxY ?? .nan
        let focusedGlobalFrameMinX = focusedGlobalFrame?.minX ?? .nan
        let focusedGlobalFrameMaxX = focusedGlobalFrame?.maxX ?? .nan
        let focusedGlobalFrameMinY = focusedGlobalFrame?.minY ?? .nan
        let focusedGlobalFrameMaxY = focusedGlobalFrame?.maxY ?? .nan
        let viewportGlobalFrameMinX = viewportGlobalFrame?.minX ?? .nan
        let viewportGlobalFrameMaxX = viewportGlobalFrame?.maxX ?? .nan
        let viewportGlobalFrameMinY = viewportGlobalFrame?.minY ?? .nan
        let viewportGlobalFrameMaxY = viewportGlobalFrame?.maxY ?? .nan
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
        let pagingSequenceValue = pagingSequence.map(String.init) ?? "none"
        let pagingAnchorKeyValue = pagingAnchorKey ?? "none"
        let pagingStartGenerationValue = pagingStartGeneration.map(String.init) ?? "none"
        let correctionGenerationValue = correctionGeneration.map(String.init) ?? "none"
        let correctionAfterFrameMinYValue = correctionAfterFrameMinY.map {
            String(format: "%.3f", Double($0))
        } ?? "none"

        Self.activationRecoveryLogger.debug("""
            event=\(event, privacy: .public) decision=\(decision, privacy: .public) sceneActive=\(scenePhase == .active, privacy: .public) \
            targetKind=\(targetKind, privacy: .public) targetExists=\(targetExistsValue, privacy: .public) targetVisible=\(targetVisibleValue, privacy: .public) attempt=\(attemptValue, privacy: .public) animated=\(animatedValue, privacy: .public) outgoingUserInsertion=\(outgoingValue, privacy: .public) \
            messages=\(messages.count, privacy: .public) displayedRows=\(displayedTranscriptMessages.count, privacy: .public) renderedRows=\(renderedTranscriptMessages.count, privacy: .public) \
            hasObservedRows=\(viewportTracker.activationRecoveryState.hasObservedRows, privacy: .public) recoveryArmed=\(viewportTracker.activationRecoveryState.isArmed, privacy: .public) frames=\(frames.count, privacy: .public) visibleFrames=\(visibleRowCount, privacy: .public) \
            frameY=\(Double(frameMinY), privacy: .public)...\(Double(frameMaxY), privacy: .public) focusedFrameY=\(Double(focusedFrameMinY), privacy: .public)...\(Double(focusedFrameMaxY), privacy: .public) \
            focusedGlobalFrameX=\(Double(focusedGlobalFrameMinX), privacy: .public)...\(Double(focusedGlobalFrameMaxX), privacy: .public) focusedGlobalFrameY=\(Double(focusedGlobalFrameMinY), privacy: .public)...\(Double(focusedGlobalFrameMaxY), privacy: .public) \
            viewportGlobalFrameX=\(Double(viewportGlobalFrameMinX), privacy: .public)...\(Double(viewportGlobalFrameMaxX), privacy: .public) viewportGlobalFrameY=\(Double(viewportGlobalFrameMinY), privacy: .public)...\(Double(viewportGlobalFrameMaxY), privacy: .public) \
            coordinateTransform=viewport_global_origin_plus_transcript_named_frame pagingSequence=\(pagingSequenceValue, privacy: .public) pagingAnchorKey=\(pagingAnchorKeyValue, privacy: .public) pagingStartGeneration=\(pagingStartGenerationValue, privacy: .public) correctionGeneration=\(correctionGenerationValue, privacy: .public) correctionAfterFrameMinY=\(correctionAfterFrameMinYValue, privacy: .public) generation=\(viewportTracker.framesGeneration, privacy: .public) baseline=\(viewportTracker.activationBaselineFramesGeneration, privacy: .public) \
            viewportHeight=\(Double(viewportHeight), privacy: .public) followLatest=\(shouldFollowLatestMessage, privacy: .public) nearBottom=\(isScrolledNearBottom, privacy: .public) tailVisible=\(tailVisible, privacy: .public) explicitBottomRequest=\(hasExplicitBottomScrollRequest, privacy: .public) \
            streamActive=\(activeStreamID != nil, privacy: .public) hostInWindow=\(scrollView?.window != nil, privacy: .public) \
            hostBounds=\(Double(bounds.width), privacy: .public)x\(Double(bounds.height), privacy: .public) hostVisibleHeight=\(Double(hostVisibleHeight), privacy: .public) \
            contentSize=\(Double(contentSize.width), privacy: .public)x\(Double(contentSize.height), privacy: .public) contentOffset=\(Double(contentOffset.x), privacy: .public),\(Double(contentOffset.y), privacy: .public) insets=\(Double(insets.top), privacy: .public),\(Double(insets.bottom), privacy: .public) \
            maxOffset=\(Double(maximumOffset), privacy: .public) normalizedOffset=\(Double(normalizedOffset), privacy: .public) signedDistanceToMax=\(Double(signedDistanceToMax), privacy: .public) contentFitsViewport=\(contentFitsViewport, privacy: .public) pastMin=\(isPastMinOffset, privacy: .public) pastMax=\(isPastMaxOffset, privacy: .public) \
            distanceFromBottomClamped=\(Double(currentMetrics?.distanceFromBottom ?? .nan), privacy: .public) tracking=\(scrollView?.isTracking ?? false, privacy: .public) dragging=\(scrollView?.isDragging ?? false, privacy: .public) decelerating=\(scrollView?.isDecelerating ?? false, privacy: .public)
            """)
    }

    private func logFirstStreamingAssistantLayoutIfNeeded(
        frames: [String: CGRect],
        renderedMessages: [TranscriptMessage],
        viewportHeight: CGFloat
    ) {
        guard activeStreamID != nil,
              !hasLoggedFirstStreamingAssistantLayout,
              viewportTracker.scrollView?.window != nil,
              let streamingAssistantMessageID,
              let streamingMessage = renderedMessages.first(where: {
                  $0.message.messageId == streamingAssistantMessageID
              }),
              let streamingFrame = frames[streamingMessage.renderID]
        else {
            return
        }

        hasLoggedFirstStreamingAssistantLayout = true
        let targetVisible = ChatTranscriptVisibilityPolicy.isVisible(
            frame: streamingFrame,
            viewportHeight: viewportHeight,
            bottomInset: transcriptBottomInsetHeight
        )
        logTranscriptScrollSnapshot(
            event: "stream_first_assistant_layout",
            decision: "assistant_row_realized",
            viewportHeight: viewportHeight,
            targetKind: "stream_assistant_row",
            targetExists: true,
            targetVisible: targetVisible,
            focusedFrame: streamingFrame
        )
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

    private var isInitialRestorePending: Bool {
        initialRestoreMessageID != nil
            && !hasCompletedInitialRestore
    }

    private var isMeasuredLayoutFollowAllowed: Bool {
        scenePhase == .active
            && shouldFollowLatestMessage
            && !isUserInteractingWithScroll
            && !(viewportTracker.latestScrollMetrics?.isDirectlyInteracting ?? false)
            && !(viewportTracker.latestScrollMetrics?.isDecelerating ?? false)
            && !hasExplicitBottomScrollRequest
            && !isLoadingOlderMessages
            && !viewportTracker.olderMessagesLoadInFlight
            && viewportTracker.pendingOlderMessagesAnchor == nil
            && restoreSettlementTask == nil
            && !isInitialRestoreInProgress
            && !isInitialRestorePending
    }

    private func recordMeasuredContentSize(
        _ contentSize: CGSize,
        proxy: ScrollViewProxy
    ) {
#if DEBUG
        recordPagingPostCommandObservation(source: "content_size", frames: viewportTracker.latestFrames)
#endif
        let change = viewportTracker.layoutFollowState.recordContentHeight(contentSize.height)
        guard change == .grew else { return }

        viewportTracker.hasPendingMeasuredLayoutGrowth = true
        scheduleMeasuredLayoutFollowIfReady(
            proxy: proxy,
            frames: viewportTracker.latestFrames,
            latestRenderedID: renderedTranscriptMessages.last?.renderID
        )
    }

    private func scheduleMeasuredLayoutFollowIfReady(
        proxy: ScrollViewProxy,
        frames: [String: CGRect],
        latestRenderedID: String?
    ) {
        guard viewportTracker.hasPendingMeasuredLayoutGrowth else { return }

        // A content-size notification can precede window attachment. Keep the
        // measured growth pending for the first in-window row preference rather
        // than issuing a proxy command against a pre-window ScrollView.
        guard viewportTracker.scrollView?.window != nil else { return }

        guard isMeasuredLayoutFollowAllowed else {
            invalidateMeasuredLayoutFollow()
            return
        }

        let hasRealizedLatestContent = latestRenderedID.map { frames[$0] != nil } == true
            || (frames[bottomAnchorID] != nil && latestRenderedID != nil)
        guard hasRealizedLatestContent else { return }
        guard ChatTranscriptLayoutFollowPolicy.shouldSchedule(
            change: .grew,
            hasRealizedLatestContent: true,
            shouldFollowLatestMessage: shouldFollowLatestMessage,
            isUserInteracting: isUserInteractingWithScroll,
            isDecelerating: viewportTracker.latestScrollMetrics?.isDecelerating ?? false,
            hasPendingRestore: restoreSettlementTask != nil || isInitialRestorePending,
            hasExplicitBottomRequest: hasExplicitBottomScrollRequest,
            isPaging: isLoadingOlderMessages
                || viewportTracker.olderMessagesLoadInFlight
                || viewportTracker.pendingOlderMessagesAnchor != nil
        ) else { return }

        guard viewportTracker.measuredLayoutFollowTask == nil else { return }

        let generation = viewportTracker.measuredLayoutFollowGeneration
        let now = Date()
        let rateLimitDelay = viewportTracker.measuredLayoutFollowNextAllowedAt.map {
            max(0, $0.timeIntervalSince(now))
        } ?? 0
        let delay = max(ChatTranscriptLayoutFollowPolicy.coalescingDelay, rateLimitDelay)

        viewportTracker.measuredLayoutFollowTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard !Task.isCancelled,
                  generation == viewportTracker.measuredLayoutFollowGeneration
            else { return }

            viewportTracker.measuredLayoutFollowTask = nil
            guard viewportTracker.hasPendingMeasuredLayoutGrowth else { return }

            guard isMeasuredLayoutFollowAllowed else {
                invalidateMeasuredLayoutFollow()
                return
            }

            let latestRenderedID = renderedTranscriptMessages.last?.renderID
            let frames = viewportTracker.latestFrames
            let hasRealizedLatestContent = latestRenderedID.map { frames[$0] != nil } == true
                || (frames[bottomAnchorID] != nil && latestRenderedID != nil)
            guard hasRealizedLatestContent else { return }
            guard ChatTranscriptLayoutFollowPolicy.shouldSchedule(
                change: .grew,
                hasRealizedLatestContent: true,
                shouldFollowLatestMessage: shouldFollowLatestMessage,
                isUserInteracting: isUserInteractingWithScroll,
                isDecelerating: viewportTracker.latestScrollMetrics?.isDecelerating ?? false,
                hasPendingRestore: restoreSettlementTask != nil || isInitialRestorePending,
                hasExplicitBottomRequest: hasExplicitBottomScrollRequest,
                isPaging: isLoadingOlderMessages
                    || viewportTracker.olderMessagesLoadInFlight
                    || viewportTracker.pendingOlderMessagesAnchor != nil
            ) else {
                invalidateMeasuredLayoutFollow()
                return
            }

            viewportTracker.hasPendingMeasuredLayoutGrowth = false
            viewportTracker.measuredLayoutFollowNextAllowedAt = Date().addingTimeInterval(
                ChatTranscriptLayoutFollowPolicy.minimumCommandInterval
            )
            onScrollToLatestContent(proxy, false)
        }
    }

    private func invalidateMeasuredLayoutFollow() {
        viewportTracker.measuredLayoutFollowGeneration &+= 1
        viewportTracker.measuredLayoutFollowTask?.cancel()
        viewportTracker.measuredLayoutFollowTask = nil
        viewportTracker.hasPendingMeasuredLayoutGrowth = false
        viewportTracker.layoutFollowState.reset()
        viewportTracker.measuredLayoutFollowNextAllowedAt = nil
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
                        allowsOutgoingMotion: ChatTranscriptRestorePolicy.shouldAllowOutgoingInsertionMotion(
                            shouldFollowLatestMessage: shouldFollowLatestMessage,
                            isRestoreInProgress: isInitialRestoreInProgress || restoreSettlementTask != nil
                        ),
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

            transcriptAccessoryBlocks(renderedMessages: renderedMessages)
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
        .scrollTargetLayout()
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
                    onContentSizeChange: { contentSize in
                        recordMeasuredContentSize(contentSize, proxy: proxy)
                    },
                    onScrollViewReady: { scrollView in
                        let didChangeScrollView = viewportTracker.scrollView !== scrollView
                        viewportTracker.scrollView = scrollView
                        if didChangeScrollView || scrollView == nil {
                            invalidateMeasuredLayoutFollow()
                        }
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

    private func completeInitialRestore(
        _ outcome: ChatTranscriptRestoreOutcome,
        request: ChatTranscriptRestoreRequest?
    ) {
        guard let request, ownedInitialRestoreRequest == request else { return }
        ownedInitialRestoreRequest = nil
#if DEBUG
        Self.activationRecoveryLogger.debug("""
            event=initial_restore_outcome generation=\(request.generation, privacy: .public) \
            outcome=\(String(describing: outcome), privacy: .public)
            """)
#endif
        onInitialRestoreOutcome(request, outcome)
    }

    private func applyTranscriptRestore(
        _ proxy: ScrollViewProxy,
        target: ChatTranscriptRestoreTarget? = nil,
        isViewportRecovery: Bool = false,
        viewportHeight: CGFloat
    ) {
        invalidateMeasuredLayoutFollow()
        if isViewportRecovery || ownedInitialRestoreRequest != initialRestoreRequest {
            completeInitialRestore(.cancelled, request: ownedInitialRestoreRequest)
        }
        if !isViewportRecovery {
            ownedInitialRestoreRequest = initialRestoreRequest
        }
        let request = isViewportRecovery ? nil : ownedInitialRestoreRequest
        guard ChatTranscriptRestorePolicy.shouldProgrammaticallyRestoreOnAppear(hasMessages: !messages.isEmpty) else {
            if !isViewportRecovery {
                completeInitialRestore(.unavailable, request: request)
                hasCompletedInitialRestore = true
                pendingInitialRestoreToken = nil
            }
            return
        }

        restoreSettlementTask?.cancel()
        let didBegin: Bool
        if isViewportRecovery {
            didBegin = restoreSettlementState.beginViewportRecovery(token: restoreScrollToken)
        } else {
            didBegin = restoreSettlementState.beginRestore(token: restoreScrollToken)
        }
        if didBegin {
            clearPendingOlderMessagesAnchor(reason: "restore_owned")
        }
#if DEBUG
        let stateToken = restoreSettlementState.restoreToken
        let stateTokenMatches = stateToken.map { $0 == restoreScrollToken } ?? false
        Self.activationRecoveryLogger.debug("""
            event=transcript_restore_begin decision=\(didBegin ? "accepted" : "rejected", privacy: .public) \
            kind=\(isViewportRecovery ? "viewport_recovery" : "initial_restore", privacy: .public) \
            restoreToken=\(restoreScrollToken, privacy: .public) restoreTokenPresent=\(restoreScrollToken > 0, privacy: .public) \
            stateRestoreTokenPresent=\(stateToken != nil, privacy: .public) stateRestoreTokenMatches=\(stateTokenMatches, privacy: .public) \
            restoreCancelled=\(restoreSettlementState.isCancelled, privacy: .public) pendingRestoreTokenPresent=\(pendingInitialRestoreToken != nil, privacy: .public) \
            initialRestoreInProgress=\(isInitialRestoreInProgress, privacy: .public) initialRestorePending=\(isInitialRestorePending, privacy: .public) \
            hasCompletedInitialRestore=\(hasCompletedInitialRestore, privacy: .public) hasObservedInitialTargetGeometry=\(hasObservedInitialTargetGeometry, privacy: .public) \
            restoreTaskPresent=\(restoreSettlementTask != nil, privacy: .public) framesGeneration=\(viewportTracker.framesGeneration, privacy: .public)
            """)
#endif
        guard didBegin else {
            restoreSettlementTask = nil
            if !isViewportRecovery {
                completeInitialRestore(.cancelled, request: request)
                hasCompletedInitialRestore = true
                pendingInitialRestoreToken = nil
            }
            return
        }
        let target = target ?? request?.target ?? restoreTarget
        if !isViewportRecovery, !isLoading, !isViewingCachedData,
           case let .message(id) = target,
           !renderedTranscriptMessages.contains(where: { $0.renderID == id }) {
            completeInitialRestore(.unavailable, request: request)
            hasCompletedInitialRestore = true
            pendingInitialRestoreToken = nil
            restoreSettlementTask = nil
            return
        }
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
                if let request, ownedInitialRestoreRequest != request { return }
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
                    if !isViewportRecovery {
                        completeInitialRestore(.success, request: request)
                        hasCompletedInitialRestore = true
                        pendingInitialRestoreToken = nil
                    }
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
            if let request, ownedInitialRestoreRequest != request { return }
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
            if !isViewportRecovery {
                completeInitialRestore(.exhausted, request: request)
                hasCompletedInitialRestore = true
                pendingInitialRestoreToken = nil
            }
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

    private func cancelTranscriptRestore(reason: String) {
        completeInitialRestore(.cancelled, request: ownedInitialRestoreRequest)
#if DEBUG
        let stateToken = restoreSettlementState.restoreToken
        let stateTokenMatches = stateToken.map { $0 == restoreScrollToken } ?? false
        let preservePagingEvidenceForActiveLoad = reason == "cancellation_token"
            && viewportTracker.olderMessagesLoadInFlight
            && viewportTracker.pendingOlderMessagesAnchor != nil
            && viewportTracker.pendingPagingEvidence != nil
        let pagingIdentity = pagingDiagnosticIdentity(
            anchor: viewportTracker.pendingOlderMessagesAnchor,
            evidence: viewportTracker.pendingPagingEvidence
        )
        Self.activationRecoveryLogger.debug("""
            event=transcript_restore_cancelled decision=\(reason, privacy: .public) \
            restoreToken=\(restoreScrollToken, privacy: .public) stateRestoreTokenPresent=\(stateToken != nil, privacy: .public) \
            stateRestoreTokenMatches=\(stateTokenMatches, privacy: .public) restoreCancelledBefore=\(restoreSettlementState.isCancelled, privacy: .public) \
            pendingRestoreTokenPresent=\(pendingInitialRestoreToken != nil, privacy: .public) initialRestoreInProgress=\(isInitialRestoreInProgress, privacy: .public) \
            initialRestorePending=\(isInitialRestorePending, privacy: .public) pendingAnchorPresent=\(viewportTracker.pendingOlderMessagesAnchor != nil, privacy: .public) \
            pagingSequence=\(pagingIdentity.sequence, privacy: .public) pagingAnchorKey=\(pagingIdentity.anchorKey, privacy: .public) \
            framesGeneration=\(viewportTracker.framesGeneration, privacy: .public) pagingEvidencePreserved=\(preservePagingEvidenceForActiveLoad, privacy: .public)
            """)
#endif
        invalidateMeasuredLayoutFollow()
        restoreSettlementTask?.cancel()
        restoreSettlementTask = nil
        restoreSettlementState.cancel()
        hasCompletedInitialRestore = true
        pendingInitialRestoreToken = nil
#if DEBUG
        if !preservePagingEvidenceForActiveLoad {
            viewportTracker.pendingPagingEvidence = nil
        }
        viewportTracker.pendingAnchorDiagnosticKeys.removeAll(keepingCapacity: true)
        viewportTracker.restoreConfirmationDiagnosticToken = nil
        viewportTracker.restoreConfirmationDiagnosticDecisions.removeAll(keepingCapacity: true)
#endif
    }

    private func resetViewportForNewTranscript() {
        completeInitialRestore(.cancelled, request: ownedInitialRestoreRequest)
        clearPendingOlderMessagesAnchor(reason: "transcript_changed")
        invalidateMeasuredLayoutFollow()
        restoreSettlementTask?.cancel()
        restoreSettlementTask = nil
        restoreSettlementState = ChatTranscriptRestoreState()
        hasCompletedInitialRestore = false
        hasObservedInitialTargetGeometry = false
        pendingInitialRestoreToken = nil
        viewportTracker.visibleRowID = nil
        viewportTracker.visibleRowFrame = nil
        viewportTracker.viewportHeight = 0
        viewportTracker.activationRecoveryState.reset()
        viewportTracker.latestFrames = [:]
        viewportTracker.latestScrollMetrics = nil
        viewportTracker.olderMessagesLoadInFlight = false
        viewportTracker.pendingOlderMessagesAnchor = nil
        viewportTracker.pendingOlderMessagesLoadCompleted = false
        viewportTracker.pendingOlderMessagesReconciliation.reset()
        viewportTracker.pendingOlderMessagesBaselineMessageCount = nil
        viewportTracker.pendingOlderMessagesBaselineRenderRevision = nil
        viewportTracker.pendingOlderMessagesBaselineFirstLoadedRowID = nil
        viewportTracker.lastOlderMessagesPrefetchVisibleRowID = nil
#if DEBUG
        viewportTracker.pendingPagingEvidence = nil
        viewportTracker.pendingAnchorDiagnosticKeys.removeAll(keepingCapacity: true)
        viewportTracker.restoreConfirmationDiagnosticToken = nil
        viewportTracker.restoreConfirmationDiagnosticDecisions.removeAll(keepingCapacity: true)
#endif
    }

    private func handleScrollMetrics(_ metrics: ChatScrollMetrics) {
#if DEBUG
        recordPagingPostCommandObservation(source: "metrics", frames: viewportTracker.latestFrames)
#endif
        viewportTracker.latestScrollMetrics = metrics
        if metrics.isDirectlyInteracting || metrics.isDecelerating {
            clearPendingOlderMessagesAnchor(reason: "user_or_deceleration_owned")
        }
#if DEBUG
        if metrics.isDirectlyInteracting || metrics.isDecelerating {
            cancelPagingEvidenceForUserInteraction(viewportHeight: viewportTracker.viewportHeight)
        }
#endif
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
            completeInitialRestore(.cancelled, request: ownedInitialRestoreRequest)
            // Invalidate the pending task in the same main-actor callback that
            // observed the finger drag, so a later sleep wake cannot yank the
            // viewport back. Deceleration and layout-only samples never enter
            // this branch.
            restoreSettlementTask?.cancel()
            restoreSettlementTask = nil
            hasCompletedInitialRestore = true
            pendingInitialRestoreToken = nil
        }

        onUpdateScrollMetrics(metrics)
    }

    @ViewBuilder
    private func olderMessagesButton(proxy: ScrollViewProxy) -> some View {
        if hasOlderMessages {
            LoadOlderMessagesButton(isLoading: isLoadingOlderMessages) {
                Task { await loadOlderMessagesPreservingPosition(proxy: proxy, intent: .explicitUserRequest) }
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
        guard automaticPagingAdmitted,
              let scope = outgoingInsertionScope,
              !viewportTracker.olderMessagesLoadInFlight, !isLoadingOlderMessages else { return }

        invalidateMeasuredLayoutFollow()

        // Reserve the slot before yielding to the async loader. The row ID key
        // also prevents repeated preference passes at the same boundary from
        // starting another request after a failed/no-progress response.
        viewportTracker.olderMessagesLoadInFlight = true
        let generation = viewportTracker.pagingOperation.begin(scope: scope)
        let anchor = ChatTranscriptViewportAnchor(
            messageID: row.id,
            frame: row.frame,
            viewportHeight: viewportTracker.viewportHeight > 0
                ? viewportTracker.viewportHeight : nil
        )
#if DEBUG
        recordPagingEvidenceBeforeLoad(
            anchor: anchor,
            viewportHeight: viewportTracker.viewportHeight
        )
#endif
        Task { @MainActor in
            await loadOlderMessagesPreservingPosition(
                proxy: proxy,
                intent: .automaticPrefetch,
                anchor: anchor,
                reservedGeneration: generation
            )
        }
    }

    private func loadOlderMessagesPreservingPosition(
        proxy: ScrollViewProxy,
        intent: ChatTranscriptOlderLoadIntent,
        anchor: ChatTranscriptViewportAnchor? = nil,
        reservedGeneration: Int? = nil
    ) async {
        guard let scope = outgoingInsertionScope else { return }
        let hasReservedLoadSlot = reservedGeneration != nil
        if let reservedGeneration {
            guard viewportTracker.pagingOperation.matches(scope: scope, generation: reservedGeneration) else { return }
        }
        if intent == .automaticPrefetch,
           (!viewportTracker.automaticPagingAdmitted || !automaticPagingAdmitted) {
            if hasReservedLoadSlot { clearPendingOlderMessagesAnchor(reason: "automatic_admission_rejected") }
            return
        }
        guard hasOlderMessages, !isLoadingOlderMessages else {
            if hasReservedLoadSlot { viewportTracker.olderMessagesLoadInFlight = false }
#if DEBUG
            logPagingEvidenceWithoutSettledFrame(
                decision: "load_not_started",
                viewportHeight: viewportTracker.viewportHeight
            )
#endif
            return
        }
        guard hasReservedLoadSlot || !viewportTracker.olderMessagesLoadInFlight else { return }
        let generation = reservedGeneration ?? viewportTracker.pagingOperation.begin(scope: scope)

        invalidateMeasuredLayoutFollow()
#if DEBUG
        // Start a fresh bounded diagnostic budget with each paging operation;
        // the production paging state is unchanged.
        viewportTracker.pendingAnchorDiagnosticKeys.removeAll(keepingCapacity: true)
#endif

        viewportTracker.olderMessagesLoadInFlight = true
        let anchor = anchor ?? currentTranscriptViewportAnchor()
        viewportTracker.olderMessagesSettlementExpiryTask?.cancel()
        viewportTracker.pendingOlderMessagesReconciliation.reset()
        viewportTracker.pendingOlderMessagesAnchor = anchor
        viewportTracker.pendingAnchorCorrectionReapplicationCount = 0
        viewportTracker.pendingOlderMessagesLoadCompleted = false
        viewportTracker.pendingOlderMessagesBaselineMessageCount = messages.count
        viewportTracker.pendingOlderMessagesBaselineRenderRevision = transcriptRenderRevision
        viewportTracker.pendingOlderMessagesBaselineFirstLoadedRowID = renderedTranscriptMessages.first?.renderID
#if DEBUG
        let pagingLoadStartedAt = ProcessInfo.processInfo.systemUptime
        let pagingLoadMessagesBefore = messages.count
        let pagingLoadSequence = viewportTracker.pendingPagingEvidence?.sequence
        let pagingLoadAnchorKey = viewportTracker.pendingPagingEvidence?.anchorKey
        logPagingLoadBoundary(
            event: "older_prefetch_load_entered",
            decision: "await_on_load_older_messages",
            viewportHeight: viewportTracker.viewportHeight,
            sequence: pagingLoadSequence,
            anchorKey: pagingLoadAnchorKey,
            messagesBefore: pagingLoadMessagesBefore,
            messagesAfter: pagingLoadMessagesBefore
        )
#endif
        let previousPrefetchBoundary = viewportTracker.lastOlderMessagesPrefetchVisibleRowID
        if intent == .automaticPrefetch {
            viewportTracker.lastOlderMessagesPrefetchVisibleRowID = anchor?.messageID
        }
        let result = await onLoadOlderMessages(intent) {
            viewportTracker.pagingOperation.matches(scope: scope, generation: generation)
                && viewportTracker.scrollView?.window != nil
                && (intent.acceptsUserIntent || viewportTracker.automaticPagingAdmitted)
        }
        guard viewportTracker.pagingOperation.matches(scope: scope, generation: generation) else { return }
        if !result.wasDispatched, intent == .automaticPrefetch {
            viewportTracker.lastOlderMessagesPrefetchVisibleRowID = previousPrefetchBoundary
        }
        let didLoad = result == .progress
#if DEBUG
        let pagingLoadElapsedMilliseconds = max(
            0,
            (ProcessInfo.processInfo.systemUptime - pagingLoadStartedAt) * 1_000
        )
        logPagingLoadBoundary(
            event: "older_prefetch_load_returned",
            decision: didLoad ? "page_reported_progress" : "no_progress",
            viewportHeight: viewportTracker.viewportHeight,
            sequence: pagingLoadSequence,
            anchorKey: pagingLoadAnchorKey,
            messagesBefore: pagingLoadMessagesBefore,
            messagesAfter: messages.count,
            didLoad: didLoad,
            elapsedMilliseconds: pagingLoadElapsedMilliseconds,
            taskCancelled: Task.isCancelled
        )
#endif
        viewportTracker.olderMessagesLoadInFlight = false
        viewportTracker.pendingOlderMessagesLoadCompleted = didLoad
        if didLoad, viewportTracker.pendingOlderMessagesAnchor != nil {
            viewportTracker.pendingOlderMessagesReconciliation.startSettlement(
                at: ProcessInfo.processInfo.systemUptime
            )
            viewportTracker.olderMessagesSettlementExpiryTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(ChatTranscriptPagingReconciliationState.settlementLifetime))
                guard !Task.isCancelled else { return }
                if viewportTracker.pendingOlderMessagesReconciliation.expireSettlement(
                    at: ProcessInfo.processInfo.systemUptime
                ) {
#if DEBUG
                    recordPagingPostCommandObservation(source: "expiry", frames: viewportTracker.latestFrames)
#endif
                    clearPendingOlderMessagesAnchor(reason: "settlement_expired_unconfirmed")
                }
            }
        }
        if viewportTracker.pendingOlderMessagesReconciliation
            .shouldRequestFreshViewPassAfterLoad(didLoad: didLoad) {
            // The preference callback may have observed the prepended layout
            // before this await resumed. A single state token asks the fresh
            // ChatTranscriptView value to reconcile with its updated messages.
            pendingOlderMessagesReconcileToken &+= 1
        }

        guard didLoad, let anchor else {
#if DEBUG
            logPagingEvidenceWithoutSettledFrame(
                decision: didLoad ? "anchor_unavailable" : "load_no_progress",
                viewportHeight: viewportTracker.viewportHeight
            )
#endif
            clearPendingOlderMessagesAnchor(
                reason: didLoad ? "anchor_unavailable" : "load_no_progress"
            )
            return
        }
        // A gesture/restore/scene cancellation during the await is final even
        // though this async view value still retains its local captured anchor.
        guard viewportTracker.pendingOlderMessagesAnchor != nil else { return }

        // When no row geometry was available before the request, there is no
        // screen-space offset to compare. The durable row identity is still a
        // useful fallback; all normal paths wait for the preference callback
        // below and avoid a jump when SwiftUI already preserved the offset.
        if anchor.frame == nil {
#if DEBUG
            logPagingEvidenceWithoutSettledFrame(
                decision: "anchor_frame_unavailable",
                viewportHeight: viewportTracker.viewportHeight
            )
#endif
            clearPendingOlderMessagesAnchor(reason: "anchor_frame_unavailable")
            onScrollToTranscriptMessage(proxy, anchor.messageID, false)
        }
    }

    private func reconcilePendingOlderMessagesAnchor(
        frames: [String: CGRect],
        proxy: ScrollViewProxy,
        currentFirstLoadedRowID: String?
    ) {
        guard let anchor = viewportTracker.pendingOlderMessagesAnchor else { return }
        guard scenePhase == .active, viewportTracker.scrollView?.window != nil else {
            clearPendingOlderMessagesAnchor(reason: "inactive_or_detached")
            return
        }
        if viewportTracker.pendingOlderMessagesReconciliation.expireSettlement(
            at: ProcessInfo.processInfo.systemUptime
        ) {
#if DEBUG
            recordPagingPostCommandObservation(source: "expiry", frames: frames)
            logPagingEvidenceWithoutSettledFrame(
                decision: "settlement_expired_unconfirmed",
                viewportHeight: viewportTracker.viewportHeight
            )
#endif
            clearPendingOlderMessagesAnchor(reason: "settlement_expired_unconfirmed")
            return
        }

        let currentMetrics = currentScrollMetricsForRecovery() ?? viewportTracker.latestScrollMetrics
        let isViewportOwnedByUser = isUserInteractingWithScroll
            || currentMetrics?.isDirectlyInteracting == true
            || currentMetrics?.isDecelerating == true
        if isViewportOwnedByUser {
            // A new gesture owns the viewport. Cancel before the lazy-stack
            // realization fallback can issue a proxy command.
#if DEBUG
            logPagingReconcileDispositionIfNeeded(
                decision: "user_owned",
                anchor: anchor,
                frames: frames,
                currentFirstLoadedRowID: currentFirstLoadedRowID,
                userOwned: true
            )
#endif
#if DEBUG
            cancelPagingEvidenceForUserInteraction(
                viewportHeight: anchor.viewportHeight ?? viewportTracker.viewportHeight
            )
#endif
            clearPendingOlderMessagesAnchor(reason: "user_or_deceleration_owned")
            return
        }

        // Initial restore and an explicit bottom jump are separate viewport
        // owners. A confirmed saved-row sample transfers initial ownership to
        // this pending page; an unconfirmed initial/activation restore still
        // wins without allowing a delayed page callback to reposition it.
        //
        // The prefetch anchor is itself the first-visible row that caused the
        // load. Use it as a second confirmation opportunity when the native
        // seed reached the saved row but the separate visible-row preference
        // did not update `hasObservedInitialTargetGeometry` first. This keeps
        // the handoff tied to the durable target and attached geometry rather
        // than treating any pending restore as permanently dominant.
        let isScrollViewAttached = viewportTracker.scrollView?.window != nil
#if DEBUG
        logInitialRestoreConfirmationIfNeeded(
            visibleMessageID: anchor.messageID,
            targetFrameVisible: ChatTranscriptVisibilityPolicy.isVisible(
                frame: anchor.frame,
                viewportHeight: anchor.viewportHeight ?? viewportTracker.viewportHeight,
                bottomInset: transcriptBottomInsetHeight
            ),
            isScrollViewAttached: isScrollViewAttached,
            source: "paging_anchor_preference"
        )
#endif
        let hasCapturedVisibleInitialRestoreTarget =
            ChatTranscriptRestorePagingOwnershipPolicy.hasConfirmedVisibleInitialTarget(
                initialRestoreTargetID: initialRestoreMessageID,
                firstVisibleMessageID: anchor.messageID,
                isScrollViewAttached: isScrollViewAttached
            ) && ChatTranscriptVisibilityPolicy.isVisible(
                frame: anchor.frame,
                viewportHeight: anchor.viewportHeight ?? viewportTracker.viewportHeight,
                bottomInset: transcriptBottomInsetHeight
            )
        if hasCapturedVisibleInitialRestoreTarget {
            confirmInitialRestoreTargetIfVisible(
                visibleMessageID: anchor.messageID,
                isScrollViewAttached: isScrollViewAttached
            )
        }
        let restoreOwnsViewport = ChatTranscriptRestorePagingOwnershipPolicy.shouldKeepRestoreOwner(
            hasSettlementTask: restoreSettlementTask != nil,
            isInitialRestoreInProgress: isInitialRestoreInProgress,
            hasConfirmedTargetGeometry: hasObservedInitialTargetGeometry,
            isInitialRestorePending: isInitialRestorePending
        )
        guard !hasExplicitBottomScrollRequest, !restoreOwnsViewport
        else {
#if DEBUG
            logPagingReconcileDispositionIfNeeded(
                decision: hasExplicitBottomScrollRequest
                    ? "explicit_bottom_owned"
                    : "restore_owned",
                anchor: anchor,
                frames: frames,
                currentFirstLoadedRowID: currentFirstLoadedRowID,
                restoreOwnsViewport: restoreOwnsViewport
            )
#endif
            clearPendingOlderMessagesAnchor(
                reason: hasExplicitBottomScrollRequest
                    ? "explicit_bottom_owned"
                    : "restore_owned"
            )
            return
        }

        guard viewportTracker.pendingOlderMessagesLoadCompleted else {
            // SwiftUI may publish the new row preference while the async load
            // continuation still owns the completion flag. Ask that
            // continuation for one fresh view pass instead of losing the
            // measured prepend reconciliation.
#if DEBUG
            logPagingReconcileDispositionIfNeeded(
                decision: "wait_load_incomplete",
                anchor: anchor,
                frames: frames,
                currentFirstLoadedRowID: currentFirstLoadedRowID
            )
#endif
            viewportTracker.pendingOlderMessagesReconciliation
                .recordPreferenceBeforeLoadCompletion()
            return
        }
        let didChangeTranscript = (viewportTracker.pendingOlderMessagesBaselineMessageCount.map {
            messages.count > $0
        } ?? false) || (viewportTracker.pendingOlderMessagesBaselineRenderRevision.map {
            transcriptRenderRevision != $0
        } ?? false)
        guard didChangeTranscript else {
#if DEBUG
            logPagingReconcileDispositionIfNeeded(
                decision: "wait_no_transcript_change",
                anchor: anchor,
                frames: frames,
                currentFirstLoadedRowID: currentFirstLoadedRowID,
                transcriptChanged: false
            )
#endif
#if DEBUG
            if !viewportTracker.pendingOlderMessagesReconciliation.hasPendingEarlyPreference {
                logPagingEvidenceWithoutSettledFrame(
                    decision: "load_no_transcript_change",
                    viewportHeight: viewportTracker.viewportHeight
                )
            }
#endif
            return
        }
        if let baselineFirstLoadedRowID = viewportTracker.pendingOlderMessagesBaselineFirstLoadedRowID {
            guard let currentFirstLoadedRowID,
                  currentFirstLoadedRowID != baselineFirstLoadedRowID
            else {
#if DEBUG
                logPagingReconcileDispositionIfNeeded(
                    decision: "wait_first_loaded_id_unchanged",
                    anchor: anchor,
                    frames: frames,
                    currentFirstLoadedRowID: currentFirstLoadedRowID,
                    transcriptChanged: didChangeTranscript,
                    firstLoadedIDChanged: false
                )
#endif
#if DEBUG
                logPagingSilentGuardIfNeeded(
                    decision: "first_id_unchanged",
                    viewportHeight: viewportTracker.viewportHeight
                )
#endif
                return
            }
        }
        let reconciliationAction = viewportTracker.pendingOlderMessagesReconciliation
            .actionForEligibleSnapshot(
                loadCompleted: viewportTracker.pendingOlderMessagesLoadCompleted,
                transcriptChanged: didChangeTranscript,
                firstLoadedIDChanged: true,
                hasAnchorFrame: frames[anchor.messageID] != nil,
                anchorNeedsCorrection: ChatTranscriptPagingPolicy.shouldRestorePrependedAnchor(
                    beforeFrame: anchor.frame,
                    afterFrame: frames[anchor.messageID]
                ),
                sampleGeneration: viewportTracker.framesGeneration,
                anchorIsVisible: ChatTranscriptVisibilityPolicy.isVisible(
                    frame: frames[anchor.messageID],
                    viewportHeight: viewportTracker.viewportHeight,
                    bottomInset: transcriptBottomInsetHeight
                )
            )
        switch reconciliationAction {
        case .confirmPreservation:
#if DEBUG
            recordPagingEvidenceAfterPreferenceIfReady(
                frames: frames, viewportHeight: viewportTracker.viewportHeight
            )
#endif
            clearPendingOlderMessagesAnchor(reason: "fresh_target_confirmed")
            return
        case .waitForFreshSnapshot:
            if frames[anchor.messageID] != nil {
                // After the single measured correction was issued, a fresh
                // sample can still show the anchor displaced because the
                // prepend kept realizing lazily or a view pass overwrote the
                // UIKit offset change. Re-issue the same anchored baseline
                // correction (bounded, and the settlement deadline still
                // bounds the whole window) instead of waiting out the budget
                // with the reader left displaced.
                if let correctionGeneration = viewportTracker.pendingOlderMessagesReconciliation.correctionGeneration,
                   viewportTracker.framesGeneration > correctionGeneration,
                   Self.shouldReapplyPagingCorrection(displacement: Self.measuredDisplacement(
                       beforeFrame: anchor.frame, afterFrame: frames[anchor.messageID]
                   )),
                   viewportTracker.pendingAnchorCorrectionReapplicationCount < Self.maximumPagingCorrectionReapplications {
                    viewportTracker.pendingAnchorCorrectionReapplicationCount += 1
                    applyMeasuredPrependedAnchorCorrection(anchor: anchor, afterFrame: frames[anchor.messageID], proxy: proxy)
                } else {
#if DEBUG
                    logPagingReconcileDispositionIfNeeded(
                        decision: viewportTracker.pendingOlderMessagesReconciliation.correctionGeneration == nil
                            ? "wait_unchanged_anchor_confirmation" : "wait_post_correction_confirmation",
                        anchor: anchor,
                        frames: frames,
                        currentFirstLoadedRowID: currentFirstLoadedRowID,
                        transcriptChanged: didChangeTranscript,
                        firstLoadedIDChanged: true
                    )
#endif
                }
                return
            }
#if DEBUG
            logPagingReconcileDispositionIfNeeded(
                decision: "wait_anchor_frame_missing_after_request",
                anchor: anchor,
                frames: frames,
                currentFirstLoadedRowID: currentFirstLoadedRowID,
                transcriptChanged: didChangeTranscript,
                firstLoadedIDChanged: true
            )
#endif
#if DEBUG
            logPagingSilentGuardIfNeeded(
                decision: "captured_frame_missing",
                viewportHeight: viewportTracker.viewportHeight
            )
#endif
            return
        case .requestAnchorRealization:
            // The captured row was visible before the prepend, but lazy layout
            // currently realizes only the newly prepended boundary. Use the
            // existing proxy once to realize the durable row ID. The next
            // preference with its measured frame returns through this same
            // state machine and applies the existing displacement correction;
            // no whole-content offset is guessed here.
#if DEBUG
            logPagingReconcileDispositionIfNeeded(
                decision: "request_anchor_realization",
                anchor: anchor,
                frames: frames,
                currentFirstLoadedRowID: currentFirstLoadedRowID,
                transcriptChanged: didChangeTranscript,
                firstLoadedIDChanged: true
            )
#endif
#if DEBUG
            logTranscriptScrollSnapshot(
                event: "older_anchor_realization_requested",
                decision: "proxy_scroll_to_realize",
                viewportHeight: anchor.viewportHeight ?? viewportTracker.viewportHeight,
                targetKind: "older_anchor",
                targetExists: true,
                targetVisible: false,
                pagingSequence: viewportTracker.pendingPagingEvidence?.sequence,
                pagingAnchorKey: viewportTracker.pendingPagingEvidence?.anchorKey,
                pagingStartGeneration: viewportTracker.pendingPagingEvidence?.startGeneration
            )
#endif
            // The existing proxy realization is issued while this operation's
            // scene/user/restore/deadline guards still hold. Do not enqueue the
            // parent's delayed hop: it could outlive paging cancellation.
            var realizationTransaction = Transaction(animation: nil)
            realizationTransaction.disablesAnimations = true
            withTransaction(realizationTransaction) {
                proxy.scrollTo(anchor.messageID, anchor: .top)
            }
            return
        case .applyMeasuredCorrection:
#if DEBUG
            logPagingReconcileDispositionIfNeeded(
                decision: "apply_measured_correction",
                anchor: anchor,
                frames: frames,
                currentFirstLoadedRowID: currentFirstLoadedRowID,
                transcriptChanged: didChangeTranscript,
                firstLoadedIDChanged: true
            )
#endif
            break
        }

        applyMeasuredPrependedAnchorCorrection(
            anchor: anchor,
            afterFrame: frames[anchor.messageID],
            proxy: proxy
        )
    }

    /// Re-application budget for the single measured prepend correction. The
    /// correction delta is always derived from the same captured anchor
    /// baseline; fresh displaced samples may re-issue it while a lazy prepend
    /// is still realizing or a view pass overwrote the UIKit offset change.
    /// The existing settlement deadline still bounds the whole window.
    private static let maximumPagingCorrectionReapplications = 3

    private static func measuredDisplacement(
        beforeFrame: CGRect?,
        afterFrame: CGRect?
    ) -> CGFloat? {
        guard let beforeFrame, let afterFrame else { return nil }
        return afterFrame.minY - beforeFrame.minY
    }

    private static func shouldReapplyPagingCorrection(displacement: CGFloat?) -> Bool {
        guard let displacement else { return false }
        return abs(displacement) > ChatTranscriptPagingPolicy.anchorPreservationTolerance
    }

    /// Issues the measured prepend correction against the captured anchor
    /// baseline and its bounded re-applications. The reconciliation state
    /// machine records the correction generation once; later displaced samples
    /// re-enter here from the wait branch with the same baseline.
    private func applyMeasuredPrependedAnchorCorrection(
        anchor: ChatTranscriptViewportAnchor,
        afterFrame: CGRect?,
        proxy: ScrollViewProxy
    ) {
        guard let afterFrame else {
#if DEBUG
            logPagingReconcileDispositionIfNeeded(
                decision: "wait_anchor_frame_disappeared",
                anchor: anchor,
                frames: viewportTracker.latestFrames,
                currentFirstLoadedRowID: nil,
                transcriptChanged: true,
                firstLoadedIDChanged: true
            )
#endif
            return
        }

        guard ChatTranscriptPagingPolicy.shouldRestorePrependedAnchor(
            beforeFrame: anchor.frame,
            afterFrame: afterFrame
        ) else {
            // Keep unchanged geometry provisional even if the state-machine
            // call above is refactored; callback count is never settlement.
            return
        }
        viewportTracker.pendingOlderMessagesReconciliation.recordCorrectionIssued(
            generation: viewportTracker.framesGeneration
        )

        // A prepend is a viewport-preserving operation. If the measured anchor
        // moved materially, restore its measured alignment without animation
        // rather than always scrolling the first loaded row to the top.
#if DEBUG
        let offsetBeforeCorrection = viewportTracker.scrollView?.contentOffset.y
#endif
        if preservePrependedAnchorWithUIKit(
            anchor: anchor,
            afterFrame: afterFrame
        ) {
#if DEBUG
            let offsetAfterCorrection = viewportTracker.scrollView?.contentOffset.y
            logPagingCorrectionOffsetTransitionIfNeeded(
                afterFrame: afterFrame,
                contentOffsetBeforeY: offsetBeforeCorrection,
                contentOffsetAfterY: offsetAfterCorrection
            )
            // Keep one bounded post-correction preference observation even when
            // UIKit reports no immediate offset delta. That distinguishes a
            // tolerance/clamp no-op from a correction overwritten by the next
            // SwiftUI layout transaction without changing production state.
            armPagingEvidenceForSettledPreference()
#endif
            return
        }

        if let viewportHeight = anchor.viewportHeight,
           let alignment = ChatTranscriptPagingPolicy.preservedAnchorAlignment(
               beforeFrame: anchor.frame,
               viewportHeight: viewportHeight
           ) {
            proxy.scrollTo(anchor.messageID, anchor: alignment)
#if DEBUG
            armPagingEvidenceForSettledPreference()
#endif
        } else {
            // A viewport as tall as the anchor cannot represent a distinct
            // preserved top edge. The durable row remains the safest bounded
            // fallback, and this path is only taken after measured displacement.
            onScrollToTranscriptMessage(proxy, anchor.messageID, false)
#if DEBUG
            armPagingEvidenceForSettledPreference()
#endif
        }
    }

    private func reconcilePendingOlderMessagesAnchorAfterEarlyPreference(
        proxy: ScrollViewProxy,
        currentFirstLoadedRowID: String?
    ) {
        guard viewportTracker.pendingOlderMessagesReconciliation.hasPendingEarlyPreference,
              viewportTracker.pendingOlderMessagesLoadCompleted
        else { return }

        reconcilePendingOlderMessagesAnchor(
            frames: viewportTracker.latestFrames,
            proxy: proxy,
            currentFirstLoadedRowID: currentFirstLoadedRowID
        )
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

    private func clearPendingOlderMessagesAnchor(reason: String) {
#if DEBUG && targetEnvironment(simulator)
        ChatP09PagingCalibration.shared.cancel(scope: viewportTracker.pagingOperation.scope)
#endif
#if DEBUG
        logPendingOlderMessagesAnchorClearIfNeeded(reason: reason)
        recordPagingPostCommandObservation(source: "terminal", frames: viewportTracker.latestFrames)
        logPagingEvidenceWithoutSettledFrame(
            decision: reason, viewportHeight: viewportTracker.viewportHeight
        )
#endif
        viewportTracker.pagingOperation.cancel()
        viewportTracker.olderMessagesLoadInFlight = false
        viewportTracker.pendingOlderMessagesAnchor = nil
        viewportTracker.pendingAnchorCorrectionReapplicationCount = 0
        viewportTracker.olderMessagesSettlementExpiryTask?.cancel()
        viewportTracker.olderMessagesSettlementExpiryTask = nil
        viewportTracker.pendingOlderMessagesLoadCompleted = false
        viewportTracker.pendingOlderMessagesReconciliation.cancel()
        viewportTracker.pendingOlderMessagesBaselineMessageCount = nil
        viewportTracker.pendingOlderMessagesBaselineRenderRevision = nil
        viewportTracker.pendingOlderMessagesBaselineFirstLoadedRowID = nil
    }

    private var hasLooseTranscriptBlocks: Bool {
        showsThinkingAndToolCards
            && (!reasoningGroupsForAnchor(nil).isEmpty || !completedToolCallGroupsForAnchor(nil).isEmpty)
    }

    private func hasLiveResponseBlocks(in renderedMessages: [TranscriptMessage]) -> Bool {
        guard activeStreamID != nil else { return false }

        return activeStreamRecoveryState != .idle
            || (showsThinkingAndToolCards
                && hasLiveReasoningText
                && !hasDisplayedTranscriptMessage(
                    anchorID: reasoningAnchorMessageID,
                    in: renderedMessages
                ))
            || (showsThinkingAndToolCards
                && !liveToolCalls.isEmpty
                && !hasDisplayedTranscriptMessage(
                    anchorID: toolCallAnchorMessageID,
                    in: renderedMessages
                ))
    }

    @ViewBuilder
    private func transcriptAccessoryBlocks(renderedMessages: [TranscriptMessage]) -> some View {
        if hasLooseTranscriptBlocks || hasLiveResponseBlocks(in: renderedMessages) {
            VStack(alignment: .leading, spacing: transcriptBlockSpacing) {
                if hasLooseTranscriptBlocks {
                    transcriptLooseBlocks
                }

                if hasLiveResponseBlocks(in: renderedMessages) {
                    liveResponseBlocks(renderedMessages: renderedMessages)
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptLooseBlocks: some View {
        if hasLooseTranscriptBlocks {
            VStack(alignment: .leading, spacing: transcriptBlockSpacing) {
                reasoningBlocks(anchorMessageID: nil)
                toolCallGroups(anchorMessageID: nil)
            }
        }
    }

    @ViewBuilder
    private func liveResponseBlocks(renderedMessages: [TranscriptMessage]) -> some View {
        if hasLiveResponseBlocks(in: renderedMessages) {
            VStack(alignment: .leading, spacing: transcriptBlockSpacing) {
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
                ReasoningBlockView(text: group.text, segments: group.segments)
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
            lhs.isPagingStartupReady == rhs.isPagingStartupReady &&
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
            lhs.initialRestoreRequest == rhs.initialRestoreRequest &&
            lhs.transcriptRestoreCancellationToken == rhs.transcriptRestoreCancellationToken &&
            lhs.followRejoinScrollToken == rhs.followRejoinScrollToken &&
            lhs.isComposerResizing == rhs.isComposerResizing &&
            lhs.isUserInteractingWithScroll == rhs.isUserInteractingWithScroll
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
                ReasoningBlockView(text: group.text, segments: group.segments)
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
