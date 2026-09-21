import Foundation
import AVFoundation
import MediaPlayer
import Observation
import SwiftData
#if DEBUG
import OSLog
#endif

enum ListenPlaybackPhase: Equatable {
    case idle
    case loading
    case playing
    case paused
}

enum ListenPlaybackSpeed: Double, CaseIterable, Identifiable {
    case half = 0.5
    case normal = 1
    case oneAndHalf = 1.5
    case double = 2

    static let storageKey = "Chat.listenPlaybackSpeed"
    static let defaultValue: ListenPlaybackSpeed = .normal

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .half:
            return "0.5x"
        case .normal:
            return "1x"
        case .oneAndHalf:
            return "1.5x"
        case .double:
            return "2x"
        }
    }

    static func stored(in userDefaults: UserDefaults) -> ListenPlaybackSpeed {
        let storedValue = userDefaults.double(forKey: storageKey)
        return allCases.first { abs($0.rawValue - storedValue) < 0.001 } ?? defaultValue
    }
}

struct ListenNowPlayingSnapshot: Equatable {
    let title: String
    let duration: TimeInterval
    let elapsedTime: TimeInterval
    let speed: ListenPlaybackSpeed
    let isPlaying: Bool
}

private enum DirectAttachmentSendFailure: Error {
    case staging(id: UUID, filename: String, error: DirectGatewayAttachmentStageError)

    var filename: String {
        if case .staging(_, let filename, _) = self { return filename }
        return "Attachment"
    }

    var error: DirectGatewayAttachmentStageError {
        if case .staging(_, _, let error) = self { return error }
        preconditionFailure("unreachable")
    }
}

@MainActor
protocol ListenRemoteControlControlling {
    func configure(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        togglePlayPause: @escaping @MainActor () -> Void,
        changePlaybackPosition: @escaping @MainActor (TimeInterval) -> Void
    )
    func update(_ snapshot: ListenNowPlayingSnapshot)
    func clear()
}

@MainActor
final class ListenRemoteControlController: ListenRemoteControlControlling {
    private var commandTargets: [(MPRemoteCommand, Any)] = []

    deinit {
        commandTargets.forEach { command, target in
            command.removeTarget(target)
            command.isEnabled = false
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func configure(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        togglePlayPause: @escaping @MainActor () -> Void,
        changePlaybackPosition: @escaping @MainActor (TimeInterval) -> Void
    ) {
        clearCommandTargets()

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandTargets.append((commandCenter.playCommand, commandCenter.playCommand.addTarget { _ in
            Task { @MainActor in play() }
            return .success
        }))

        commandCenter.pauseCommand.isEnabled = true
        commandTargets.append((commandCenter.pauseCommand, commandCenter.pauseCommand.addTarget { _ in
            Task { @MainActor in pause() }
            return .success
        }))

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandTargets.append((commandCenter.togglePlayPauseCommand, commandCenter.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in togglePlayPause() }
            return .success
        }))

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandTargets.append((
            commandCenter.changePlaybackPositionCommand,
            commandCenter.changePlaybackPositionCommand.addTarget { event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }
                Task { @MainActor in changePlaybackPosition(event.positionTime) }
                return .success
            }
        ))
    }

    func update(_ snapshot: ListenNowPlayingSnapshot) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: "Semreh",
            MPMediaItemPropertyPlaybackDuration: max(0, snapshot.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, snapshot.elapsedTime),
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? snapshot.speed.rawValue : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.speed.rawValue
        ]
        MPNowPlayingInfoCenter.default().playbackState = snapshot.isPlaying ? .playing : .paused
    }

    func clear() {
        clearCommandTargets()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func clearCommandTargets() {
        commandTargets.forEach { command, target in
            command.removeTarget(target)
            command.isEnabled = false
        }
        commandTargets.removeAll()
    }
}

struct ApprovalPromptState: Equatable, Identifiable {
    var id: String {
        "\(sessionID)-\(pending.id)"
    }

    let sessionID: String
    let pending: PendingApproval
    let pendingCount: Int

    var patternKeys: [String] {
        pending.displayPatternKeys
    }
}

struct ClarificationPromptState: Equatable, Identifiable {
    var id: String {
        "\(sessionID)-\(pending.id)"
    }

    let sessionID: String
    let pending: PendingClarification
    let pendingCount: Int
    let gatewayIdentity: GatewayBlockingPromptIdentity?
    let gatewayCancelOnly: Bool

    init(
        sessionID: String,
        pending: PendingClarification,
        pendingCount: Int,
        gatewayIdentity: GatewayBlockingPromptIdentity? = nil,
        gatewayCancelOnly: Bool = false
    ) {
        self.sessionID = sessionID
        self.pending = pending
        self.pendingCount = pendingCount
        self.gatewayIdentity = gatewayIdentity
        self.gatewayCancelOnly = gatewayCancelOnly
    }

    var question: String {
        pending.displayQuestion
    }

    var choices: [String] {
        pending.displayChoices
    }
}


struct ProfileSwitchOutcome: Equatable {
    let session: SessionSummary?
}

struct DirectAttachmentRecoveryTarget: Equatable {
    let server: URL
    let sessionID: String
    let profile: String
    let runtimeID: String
    let markerToken: UUID?
}

struct DirectPromptDeliveryRecoveryTarget: Equatable {
    let server: URL
    let sessionID: String
    let profile: String
    let markerToken: UUID
}

/// A direct branch owns an already-bound child controller. Consumers must
/// retain this handoff instead of constructing a new ChatViewModel from only
/// the summary, which would resume the child a second time.
struct DirectBranchHandoff: Equatable {
    let session: SessionSummary
    let viewModel: ChatViewModel
    let origin: URL
    let profile: String
    let identity: UUID

    static func == (lhs: DirectBranchHandoff, rhs: DirectBranchHandoff) -> Bool {
        lhs.identity == rhs.identity
    }
}

struct ChatPollingIntervals: Equatable {
    let approvalNanoseconds: UInt64
    let clarificationNanoseconds: UInt64
    let backgroundNanoseconds: UInt64

    static let standard = ChatPollingIntervals(
        approvalNanoseconds: 1_500_000_000,
        clarificationNanoseconds: 1_500_000_000,
        backgroundNanoseconds: 3_000_000_000
    )
}

private struct DirectBackgroundAttempt {
    let prompt: String
    let sessionID: String
    let profile: String
    var taskID: String?
}

private enum DirectBackgroundAttemptResolution: Equatable {
    case completed
    case unknown
}

enum ActiveStreamRecoveryState: Equatable {
    case idle
    case checking
    case reconnecting
}

@MainActor
@Observable
final class ChatViewModel {
#if DEBUG
    private static let olderLoadOutcomeLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "TranscriptActivationRecovery"
    )
#endif
    nonisolated private static let messagePageLimit = 50
    private static let directAmbiguousPromptDeliveryMessage =
        "Semreh cannot confirm the previous send. It was not resent; check the latest conversation before allowing a different message."
    private static let directConfirmedPromptCleanupMessage =
        "Hermes accepted the previous message, but Semreh could not clear its local safety record. It was not resent."
    private static let directPromptRecoveryFailureMessage =
        "The latest conversation could not be checked. The previous message may still appear, and no message was resent."
    @ObservationIgnored private var incrementalTranscriptMessageIndex: Int?
    @ObservationIgnored private var streamingAssistantMessageIndex: Int?
    @ObservationIgnored private var messageLoadGeneration = 0
    @ObservationIgnored private var contextUsageRevision = 0
    /// Monotonic invalidation key for transcript-rendering data. ChatView uses
    /// this instead of comparing every message/string when unrelated composer
    /// state changes cause the parent view to be reevaluated.
    private(set) var transcriptRenderRevision = 0

    let outgoingInsertionScope = UUID()
    @ObservationIgnored private var outgoingInsertionSequence: UInt64 = 0
    private(set) var outgoingInsertionEvent: OutgoingInsertionEvent?

    @ObservationIgnored private(set) var messages: [ChatMessage] = [] {
        didSet {
            transcriptRenderRevision &+= 1
            guard transcriptDerivedStateBatchDepth == 0 else {
                transcriptDerivedStateNeedsRecompute = true
                return
            }
            if let index = incrementalTranscriptMessageIndex {
                incrementalTranscriptMessageIndex = nil
                replaceDisplayedTranscriptMessage(at: index)
            } else {
                recomputeDisplayedTranscriptMessages()
            }
        }
    }
    /// Memoized transcript mapping, recomputed once whenever `messages` or
    /// `messagesOffset` changes. Views read this single cached value instead of
    /// re-running the full classification pass on every body evaluation.
    @ObservationIgnored private var transcriptDerivedStateBatchDepth = 0
    @ObservationIgnored private var transcriptDerivedStateNeedsRecompute = false
#if DEBUG
    private(set) var transcriptDerivedStateRecomputeCountForTesting = 0
#endif
    @ObservationIgnored private(set) var displayedTranscriptMessages: [TranscriptMessage] = []
    @ObservationIgnored private var displayedTranscriptRowIndexByLoadedIndex: [Int: Int] = [:]
    #if DEBUG
    @ObservationIgnored private(set) var transcriptFullRecomputeCountForTesting = 0
    #endif
    private(set) var isLoading = false
    private(set) var isLoadingOlderMessages = false
    private(set) var isStartingChat = false
    /// True only while a foreground scene re-entry performs its canonical
    /// transcript read (refreshAfterSceneActivation). The transient-empty
    /// protection keys on this exact re-entry window instead of every
    /// same-session empty page, so ordinary idle refreshes keep the
    /// authoritative-empty semantics.
    private(set) var isForegroundReentryRead = false
    /// True while a recorded voice note is being transcribed, uploaded, and sent.
    /// Spans all three steps so the composer can show progress and disable input.
    private(set) var isSendingVoiceNote = false
    private(set) var isForkingMessage = false
    private(set) var isEditingMessage = false
    private(set) var isRegeneratingMessage = false
    private(set) var isCompressingSession = false
    private(set) var isCancellingStream = false
    private(set) var isViewingCachedData = false
    var activeStreamID: String? {
        guard usesDirectGateway else { return nil }
        guard !directInvalidated, let controller = directConversation, controller.runState != .idle else { return nil }
        // UI liveness identity only; never a persisted gateway runtime ID.
        return controller.storedID.map { "direct-run:\($0)" } ?? "direct-draft-run"
    }
    private(set) var wasReusedFromOpenSessionStore = false

    var hasPreservedLiveRun: Bool {
        activeStreamID != nil || !liveToolCalls.isEmpty || !liveReasoningText.isEmpty
    }

    /// A transcript is preserved only once there are actual message rows in
    /// memory. A persisted live-run bookmark is chrome (reasoning/tools/cursor),
    /// not authoritative history; after process death we must still fetch the
    /// transcript before deciding to skip reload.
    var hasPreservedTranscript: Bool {
        !messages.isEmpty
    }

    private(set) var savedFollowingLatest = true
    private var savedVisibleMessageID: String?
    private let restoreStore: TranscriptRestoreStore
    private let localOrganizerStore: LocalOrganizerStore

    var transcriptRestoreTarget: ChatTranscriptRestoreTarget {
        ChatTranscriptRestorePolicy.target(
            wasFollowingLatest: savedFollowingLatest,
            lastVisibleMessageID: savedVisibleMessageID
        )
    }

    var isEstablishingConnection: Bool {
        ChatConnectionStatusPolicy.shouldShowConnecting(
            isLoading: isLoading,
            hasPaintedTranscript: hasPreservedTranscript,
            hasActiveStream: activeStreamID != nil,
            isStartingChat: isStartingChat,
            isVisiblySlow: isConnectionVisiblySlow
        )
    }
    var activeStreamRecoveryState: ActiveStreamRecoveryState { .idle }
    var liveTokensPerSecond: Double? { nil }
    private(set) var errorMessage: String?
    private(set) var sendErrorMessage: String?
    private(set) var messageActionErrorMessage: String?
    private(set) var cacheErrorMessage: String?
    private(set) var lastError: Error?
    private(set) var displayTitle: String
    private(set) var listeningMessageID: String?
    private(set) var streamingScrollTrigger = 0
    /// Bumped when a cache-first cold open (#289) finishes reconciling the network
    /// transcript over the instantly-rendered cached one. The richer server content
    /// (tool-call / reasoning cards, content parts) is taller than the lighter cached
    /// render, so the view re-pins to the bottom on this token *without* animation —
    /// otherwise the height growth produces a visible scroll jump.
    private(set) var cacheFirstReconcileScrollToken = 0
    private var cacheFirstMessagePlaceholder: [ChatMessage]?
    private var messagesBeforeCacheFirstPlaceholder: [ChatMessage] = []
    private var messagesOffsetBeforeCacheFirstPlaceholder = 0
    @ObservationIgnored private var pendingStreamingScrollTriggerTask: Task<Void, Never>?
    @ObservationIgnored private var pendingAssistantTextBuffer: String = ""
    @ObservationIgnored private var pendingReasoningTextBuffer: String = ""
    @ObservationIgnored private var pendingStreamingContentFlushTask: Task<Void, Never>?
    @ObservationIgnored private var isTranscriptPresentationActive = true
    @ObservationIgnored private let directFallbackRenderIdentityLedger = DirectFallbackRenderIdentityLedger()
    @ObservationIgnored private var isApplyingOlderDirectHistoryPage = false
    @ObservationIgnored private var connectionVisibilityTask: Task<Void, Never>?
    private var isConnectionVisiblySlow = false
    private(set) var completedToolCallGroups: [ToolCallGroup] = [] {
        didSet { transcriptRenderRevision &+= 1 }
    }
    private var completedToolCallGroupLookup = ToolCallGroupAnchorLookup()
    private(set) var completedReasoningGroups: [ReasoningGroup] = [] {
        didSet {
            transcriptRenderRevision &+= 1
            recomputeDisplayedReasoningGroups()
        }
    }
    private(set) var displayedReasoningGroups: [ReasoningGroup] = []
    private var displayedReasoningGroupLookup = ReasoningGroupAnchorLookup()
    func displayedReasoningGroupsForAnchor(_ anchorMessageID: String?) -> [ReasoningGroup] {
        displayedReasoningGroupLookup.groups(anchorMessageID: anchorMessageID)
    }
    func completedToolCallGroupsForAnchor(_ anchorMessageID: String?) -> [ToolCallGroup] {
        completedToolCallGroupLookup.groups(anchorMessageID: anchorMessageID)
    }

    /// Tool calls for the latest assistant turn, driving the in-chat "file changes" recap
    /// card and composer "N changes" capsule (#316). A turn often spans multiple assistant
    /// messages (tool calls on one, the final text on the next), and the archived tool group
    /// anchors to the *first* of them — so collect every completed group in the current turn
    /// (since the last user message) plus any still-live calls, not just one anchor.
    var latestTurnToolCalls: [ToolCall] {
        let turnAnchors = Set(
            TranscriptTurnClassifier.currentTurnAssistantAnchorIDs(in: messages, messageOffset: messagesOffset)
        )
        var calls = completedToolCallGroups
            .filter { group in group.anchorMessageID.map(turnAnchors.contains) ?? false }
            .flatMap(\.toolCalls)
        calls.append(contentsOf: liveToolCalls)
        return calls
    }

    private func withBatchedTranscriptDerivedState(_ update: () -> Void) {
        transcriptDerivedStateBatchDepth += 1
        update()
        transcriptDerivedStateBatchDepth -= 1

        guard transcriptDerivedStateBatchDepth == 0,
              transcriptDerivedStateNeedsRecompute
        else {
            return
        }

        transcriptDerivedStateNeedsRecompute = false
        incrementalTranscriptMessageIndex = nil
        recomputeDisplayedTranscriptMessages()
    }

    private func replaceStreamingMessage(at index: Int, with message: ChatMessage) {
        incrementalTranscriptMessageIndex = index
        messages[index] = message
    }

    private func appendStreamingMessage(_ message: ChatMessage) {
        // The first token creates the live assistant row. Mark its insertion as
        // incremental too; remapping 10k stable rows on that first token is a
        // visible main-thread hitch before paced rendering even begins.
        incrementalTranscriptMessageIndex = messages.endIndex
        messages.append(message)
    }

    private func replaceDisplayedTranscriptMessage(at loadedIndex: Int) {
        guard messages.indices.contains(loadedIndex) else {
            recomputeDisplayedTranscriptMessages()
            return
        }

        let message = messages[loadedIndex]
        guard message.role != "tool", !TranscriptTurnClassifier.isToolResultOnlyMessage(message) else {
            recomputeDisplayedTranscriptMessages()
            return
        }

        let offset = max(0, messagesOffset)
        let transcriptMessage = TranscriptMessage(
            loadedIndex: loadedIndex,
            renderID: Self.transcriptRenderID(for: message, absoluteIndex: offset + loadedIndex,
                                               preferDurableID: usesDirectGateway),
            anchorID: TranscriptTurnClassifier.anchorID(
                for: message,
                at: loadedIndex,
                messageOffset: messagesOffset
            ),
            message: message,
            attachmentDisplayContent: usesDirectGateway
                ? Self.directAttachmentDisplayContent(for: message)
                : nil
        )

        if let rowIndex = displayedTranscriptRowIndexByLoadedIndex[loadedIndex],
           displayedTranscriptMessages.indices.contains(rowIndex) {
            displayedTranscriptMessages[rowIndex] = transcriptMessage
            // Compression-card placement is keyed by loaded index/render ID,
            // neither of which changes while replacing a live assistant row.
            return
        }

        if loadedIndex == messages.index(before: messages.endIndex) {
            displayedTranscriptRowIndexByLoadedIndex[loadedIndex] = displayedTranscriptMessages.endIndex
            displayedTranscriptMessages.append(transcriptMessage)
            // An append cannot shift any existing transcript/reasoning anchor or
            // compression-card placement, so the stable prefix stays untouched.
            return
        }

        recomputeDisplayedTranscriptMessages()
    }

    private func recomputeDisplayedTranscriptMessages() {
#if DEBUG
        transcriptFullRecomputeCountForTesting &+= 1
        transcriptDerivedStateRecomputeCountForTesting += 1
#endif
        displayedTranscriptMessages = Self.transcriptMessages(
            from: messages,
            messageOffset: messagesOffset,
            hidingStreamingAssistantID: nil,
            preferDurableIDs: usesDirectGateway,
            fallbackLedger: usesDirectGateway ? directFallbackRenderIdentityLedger : nil,
            fallbackScope: directTranscriptFallbackScope,
            isOlderPagePrepend: isApplyingOlderDirectHistoryPage
        )
        displayedTranscriptRowIndexByLoadedIndex = Dictionary(
            uniqueKeysWithValues: displayedTranscriptMessages.enumerated().map { rowIndex, message in
                (message.loadedIndex, rowIndex)
            }
        )
        recomputeCompressionReferenceCard()
        recomputeDisplayedReasoningGroups()
    }

    private var directTranscriptFallbackScope: String? {
        guard usesDirectGateway,
              let historyID = directHistoryID,
              !historyID.isEmpty
        else { return nil }
        let profile = directConversation?.profile ?? (Self.nonEmpty(currentProfile) ?? "default")
        return "\(server.absoluteString)|\(profile)|\(historyID)"
    }

    private func recomputeDisplayedReasoningGroups() {
        let groups = Self.reasoningDisplayGroups(
            messages: messages,
            messageOffset: messagesOffset,
            archivedGroups: completedReasoningGroups
        )
        displayedReasoningGroups = groups
        displayedReasoningGroupLookup = ReasoningGroupAnchorLookup(groups: groups)
    }
    /// Synthesized "Context compaction · Reference only" card resolved from the
    /// session's `compression_anchor_*` metadata; nil when the session has no
    /// compaction metadata or the reference text is gated out.
    private(set) var compressionReferenceCard: CompressionReferenceCard? {
        didSet { transcriptRenderRevision &+= 1 }
    }
    @ObservationIgnored private var compressionAnchorMetadata: CompressionAnchorMetadata?
    private func applyCompressionAnchorMetadata(from session: SessionDetail?) {
        compressionAnchorMetadata = CompressionAnchorMetadata(from: session)
        recomputeCompressionReferenceCard()
    }
    private func clearCompressionAnchorMetadata() {
        compressionAnchorMetadata = nil
        compressionReferenceCard = nil
    }
    private func recomputeCompressionReferenceCard() {
        // Not folded into the messages/messagesOffset observers alone:
        // applyCompletedStreamSession can update the metadata without
        // reassigning messages, so metadata changes recompute here too. The
        // equality guard keeps the overlapping triggers observer-silent.
        let card = Self.compressionReferenceCard(
            messages: messages,
            messagesOffset: messagesOffset,
            transcriptMessages: displayedTranscriptMessages,
            metadata: compressionAnchorMetadata
        )
        guard compressionReferenceCard != card else { return }

        compressionReferenceCard = card
    }
    private(set) var liveToolCalls: [ToolCall] = [] {
        didSet { transcriptRenderRevision &+= 1 }
    }
    private(set) var liveReasoningText = "" {
        didSet { transcriptRenderRevision &+= 1 }
    }
    private(set) var streamingAssistantMessageID: String? {
        didSet {
            if streamingAssistantMessageID != oldValue {
                streamingAssistantMessageIndex = nil
            }
            transcriptRenderRevision &+= 1
        }
    }
    /// Assistant rows finalized by `message.interim` during the active turn.
    /// Hermes may later complete with either the same reply (which should
    /// reconcile in place) or a distinct post-tool reply (which must append).
    @ObservationIgnored private var sealedInterimAssistantMessageIDs: Set<String> = []
    private(set) var toolCallAnchorMessageID: String? {
        didSet { transcriptRenderRevision &+= 1 }
    }
    private(set) var reasoningAnchorMessageID: String? {
        didSet { transcriptRenderRevision &+= 1 }
    }
    private(set) var messagesOffset = 0 {
        didSet {
            transcriptRenderRevision &+= 1
            guard transcriptDerivedStateBatchDepth == 0 else {
                transcriptDerivedStateNeedsRecompute = true
                return
            }
            recomputeDisplayedTranscriptMessages()
        }
    }
    private(set) var hasOlderMessages = false
    private(set) var contextWindowSnapshot: ContextWindowSnapshot? {
        didSet { contextUsageRevision &+= 1 }
    }
    private(set) var responseCompletionHapticTrigger = 0
    private(set) var responseCompletionNeedsTranscriptRefresh = false
    private(set) var modelCatalogGroups: [ModelCatalogGroup] = []
    private var directModelOptions: DirectHermesModelOptions?
    private var directSessionReasoningSupported = false
    private(set) var isReasoningChangeDeferred = false
    @ObservationIgnored private var directReasoningRefreshTask: Task<Void, Never>?
    private(set) var agentCommands: [AgentCommand] = []
    private(set) var workspaceRoots: [WorkspaceRoot] = []
    private(set) var workspaceSuggestions: [String] = []
    private(set) var skillSlashSuggestions: [SkillSlashSuggestion] = []
    private var isSubmittingDirectSkill = false
    private(set) var profileOptions: [ProfileSummary] = []
    private(set) var isSingleProfileMode = false
    private(set) var selectedProfileName: String?
    private(set) var selectedReasoningEffort: String?
    /// Raw per-session override; nil means this session inherits the profile value.
    private(set) var sessionReasoningEffort: String?
    /// Model-aware effort vocabulary reported by the direct Hermes configuration.
    private(set) var supportedReasoningEfforts: [String]?
    /// `supports_reasoning_effort`; `false` hides the composer effort control.
    private(set) var supportsReasoningEffort: Bool?
    /// Only an explicit `true` authorizes a session-scoped effort change.
    private(set) var sessionScopedReasoning: Bool?
    /// Shared configuration mutation generation. Model and reasoning writes are
    /// optimistic, so a late response must never roll back a newer visible choice.
    private var composerConfigurationMutationToken = 0
    var showsReasoningEffortControl: Bool {
        ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: supportsReasoningEffort,
            supportedEfforts: supportedReasoningEfforts
        )
    }
    var selectedReasoningSelection: String? {
        if usesDirectGateway, canonicalSessionID != nil { return selectedReasoningEffort }
        guard sessionScopedReasoning == true else { return selectedReasoningEffort }
        return sessionReasoningEffort ?? ReasoningEffortOption.inheritID
    }
    var allowsReasoningInheritance: Bool {
        usesDirectGateway ? canonicalSessionID == nil : sessionScopedReasoning == true
    }
    var allowsReasoningChangesWhileStreaming: Bool {
        usesDirectGateway && directSessionReasoningSupported
    }
    private(set) var isLoadingComposerConfiguration = false
    private(set) var isUpdatingComposerConfiguration = false
    private(set) var composerConfigurationErrorMessage: String?
    var pendingAttachments: [PendingAttachment] { attachmentCoordinator.pendingAttachments }
    private(set) var directPendingAttachments: [DirectPendingAttachment] = []
    var directPendingAttachmentDisplayItems: [ComposerAttachmentDisplayItem] {
        directPendingAttachments.map { ComposerAttachmentDisplayItem(direct: $0) }
    }
    private(set) var isPreparingDirectAttachment = false
    private(set) var directAttachmentPreparationErrorMessage: String?
    var isUploadingAttachment: Bool {
        isPreparingDirectAttachment
    }
    var attachmentUploadCount: Int {
        directAttachmentPreparationCount
    }
    var attachmentUploadGeneration: Int {
        directAttachmentPreparationStartGeneration
    }
    var uploadAttachmentErrorMessage: String? {
        if let attachmentRecoveryErrorMessage { return attachmentRecoveryErrorMessage }
        if attachmentRecoveryNeedsReset {
            return attachmentRecoveryIsBusy
                ? String(localized: "Resetting unresolved attachment delivery…")
                : String(localized: "An attachment delivery is unresolved. Saved chat history is kept; reset the pending upload before continuing.")
        }
        return directAttachmentPreparationErrorMessage
    }
    var attachmentRecoveryNeedsReset: Bool {
        usesDirectGateway && directConversation?.attachmentRecoveryNeedsReset == true
    }
    var attachmentRecoveryIsBusy: Bool {
        usesDirectGateway && directConversation?.attachmentRecoveryIsBusy == true
    }
    var directConversationHasPromptDeliveryUncertainty: Bool {
        usesDirectGateway && directConversation?.hasAmbiguousPromptDelivery == true
    }
    var directPromptDeliverySafetyRecordUnavailable: Bool {
        usesDirectGateway && !directInvalidated
            && directConversation?.hasAmbiguousPromptDelivery == true
            && directConversation?.promptDeliveryUncertaintyToken == nil
    }
    var directBranchIdentity: (origin: URL, profile: String, sessionID: String)? {
        guard usesDirectGateway,
              !directInvalidated,
              let controller = directConversation,
              !controller.isDisposed,
              let controllerSessionID = controller.storedID,
              let binding = controller.binding,
              !controllerSessionID.isEmpty,
              binding.storedID == controllerSessionID,
              binding.profile == controller.profile,
              !binding.runtimeID.isEmpty,
              canonicalSessionID == controllerSessionID,
              controller.runtimeOrigin == server,
              controller.profile == (Self.nonEmpty(currentProfile) ?? "default") else {
            return nil
        }
        return (
            origin: controller.runtimeOrigin,
            profile: controller.profile,
            sessionID: controllerSessionID
        )
    }
    var directPromptDeliveryHasConfirmedAcceptance: Bool {
        usesDirectGateway && directConversation?.promptDeliveryUncertaintyHasConfirmedAcceptance == true
    }
    private func promptDeliveryWarning(for controller: GatewayConversationController?) -> String {
        controller?.promptDeliveryUncertaintyHasConfirmedAcceptance == true
            ? Self.directConfirmedPromptCleanupMessage
            : Self.directAmbiguousPromptDeliveryMessage
    }
    var directAttachmentRecoveryTarget: DirectAttachmentRecoveryTarget? {
        guard usesDirectGateway,
              let controller = directConversation,
              controller.attachmentRecoveryNeedsReset,
              let sessionID = controller.storedID,
              !sessionID.isEmpty,
              let runtimeID = controller.binding?.runtimeID,
              !runtimeID.isEmpty else { return nil }
        return DirectAttachmentRecoveryTarget(
            server: server,
            sessionID: sessionID,
            profile: controller.profile,
            runtimeID: runtimeID,
            markerToken: controller.unresolvedAttachmentMarkerToken
        )
    }
    var directPromptDeliveryRecoveryTarget: DirectPromptDeliveryRecoveryTarget? {
        guard usesDirectGateway,
              !directInvalidated,
              !promptDeliveryRecoveryIsBusy,
              !isStartingChat,
              !isUpdatingComposerConfiguration,
              activeStreamID == nil,
              !attachmentRecoveryIsBusy,
              let controller = directConversation,
              controller.hasAmbiguousPromptDelivery,
              controller.runState == .idle || controller.runState == .deliveryUnknown,
              let sessionID = controller.storedID,
              sessionID == canonicalSessionID,
              controller.profile == (Self.nonEmpty(currentProfile) ?? "default"),
              let markerToken = controller.promptDeliveryUncertaintyToken else { return nil }
        return DirectPromptDeliveryRecoveryTarget(
            server: server,
            sessionID: sessionID,
            profile: controller.profile,
            markerToken: markerToken
        )
    }
    var localAttachmentPreviews: [String: [String: Data]] { attachmentCoordinator.localAttachmentPreviews }
    private(set) var pinnedLocalNotices: [String] = []
    /// Direct Hermes blocking prompts are projections of the live controller;
    /// do not copy them into a second VM-owned queue that can outlive a rebind.
    var pendingApprovalPrompt: GatewayApprovalPrompt? {
        usesDirectGateway ? directConversation?.pendingApprovalPrompt : nil
    }
    var pendingSecretPrompt: GatewaySecretPrompt? {
        usesDirectGateway ? directConversation?.pendingSecretPrompt : nil
    }
    var pendingSudoPrompt: GatewaySudoPrompt? {
        usesDirectGateway ? directConversation?.pendingSudoPrompt : nil
    }
    var blockingInteractionResponseInFlight: Bool {
        usesDirectGateway && directConversation?.blockingInteractionResponseInFlight == true
    }
    var blockingInteractionErrorMessage: String? {
        guard usesDirectGateway,
              let identity = directBlockingInteractionErrorIdentity,
              let message = directBlockingInteractionErrorMessage else { return nil }
        let displayedIdentities = [
            pendingApprovalPrompt?.identity,
            pendingSecretPrompt?.identity,
            pendingSudoPrompt?.identity
        ].compactMap { $0 }
        return displayedIdentities.contains(identity) ? message : nil
    }
    func blockingInteractionErrorMessage(for identity: GatewayBlockingPromptIdentity) -> String? {
        guard usesDirectGateway,
              directBlockingInteractionErrorIdentity == identity else { return nil }
        return directBlockingInteractionErrorMessage
    }
    var clarificationPrompt: ClarificationPromptState? {
        directClarificationPrompt
    }
    var isRespondingToClarification: Bool {
        isRespondingToDirectClarification
    }
    var clarificationErrorMessage: String? {
        directClarificationErrorMessage
    }
    private(set) var currentGoal: SubmittedGoal?
    private(set) var isSubmittingGoal = false
    private(set) var goalErrorMessage: String?
    private(set) var hasActivatedGoalCommand = false
    private var directGoalStatusEventKeys: Set<String> = []

    private var sessionID: String?
    var usesDirectGateway: Bool { gatewayRuntimeProvider != nil }
    @ObservationIgnored private let gatewayRuntimeProvider: (@MainActor (APIClient) async throws -> HermesServerRuntime)?
    @ObservationIgnored private let directAttachmentPreparer: (@Sendable (Data, String, Data?) async throws -> DirectPendingAttachment)?
    @ObservationIgnored private let directAttachmentRecoveryMarkerStore: any DirectGatewayAttachmentRecoveryMarkerStoreProtocol
    @ObservationIgnored private let promptUncertaintyStore: any DirectPromptDeliveryUncertaintyStoreProtocol
    private var directConversation: GatewayConversationController?
    private var directRuntime: HermesServerRuntime?
    @ObservationIgnored private var directAttachmentTask: Task<GatewayConversationController, Error>?
    @ObservationIgnored private var contextUsageSnapshotTask: Task<Void, Never>?
    @ObservationIgnored private var contextUsageSnapshotTaskOwner: UUID?
    private var directInvalidated = false
    private var directVisible = false
    private var directLiveActivityRun: (owner: UUID, sessionID: String, profile: String)?
    /// Wall-clock start of the currently active direct run. Surfaced to the chat
    /// as the floating "working for X" pill (item 4 of the 2026-09-18 app-chat
    /// scope). Set whenever the gateway starts a response; cleared on terminal
    /// handling and whenever the owned run ends. Nil means "no elapsed readout"
    /// (e.g. a run resumed from the gateway that never emitted an observed
    /// `message.start` in this process).
    private(set) var activeRunStartedAt: Date?
    private(set) var directClarificationPrompt: ClarificationPromptState? = nil
    private(set) var isRespondingToDirectClarification = false
    private(set) var directClarificationErrorMessage: String? = nil
    private(set) var directBlockingInteractionErrorMessage: String? = nil
    private var directBlockingInteractionErrorIdentity: GatewayBlockingPromptIdentity?
    private var directClarificationOwnedSendError: String?
    private var directAttachmentSelectionGeneration = 0
    private var directAttachmentPreparationStartGeneration = 0
    private var directAttachmentPreparationCount = 0
    private var attachmentRecoveryErrorMessage: String?
    private(set) var promptDeliveryRecoveryIsBusy = false
    private var directComposerIsEditing = false
    private var directOlderOffset = 0
    private var directHistoryID: String?
    /// Session identity captured for the narrow resume-before-send window.
    /// This must not follow a controller's later canonical-ID adoption: an
    /// empty page for a newly adopted session must still replace old rows.
    private var sendTranscriptSessionID: String?
#if DEBUG
    private var performanceLabStreamingTurnInFlight = false
#endif
    private var directResponseComplete = false
    private var directModelContext: ModelContext?
    var onDirectCanonicalID: ((String) -> Void)?
    var hasServerBackedSession: Bool {
        guard let sessionID else { return false }
        return !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var currentWorkspace: String?
    private var currentModel: String?
    private var currentModelProvider: String?
    private var currentProfile: String?
    private let isCLISession: Bool
    private let server: URL
    let client: APIClient
    private let attachmentCoordinator: ChatAttachmentCoordinator
    private let liveActivityManager: any AgentLiveActivityManaging
    private let speechSynthesizerFactory: () -> any ChatSpeechSynthesizing
    private let listenAudioSession: any ListenAudioSessionControlling
    private let listenRemoteControlCenter: any ListenRemoteControlControlling
    private let userDefaults: UserDefaults
    private let pollingIntervals: ChatPollingIntervals
    // Real-time window over which rapid streaming updates coalesce into a single
    // scroll trigger / first content flush. Injectable so tests can drive
    // coalescing deterministically; production keeps the 16ms default.
    private let streamingScrollCoalescingDelayNanoseconds: UInt64
    // Display pacing for streamed assistant text (issue #212): after the first
    // coalesced flush, buffered tokens are revealed word-by-word at this cadence,
    // with the per-tick quota scaling up so the display never trails the live
    // stream by more than the max lag. Pacing affects display timing only — the
    // buffer and final content are untouched. Injectable for tests.
    private let streamingWordRevealCadenceNanoseconds: UInt64
    private let streamingMaxRevealLagNanoseconds: UInt64
    private var speechSynthesizer: (any ChatSpeechSynthesizing)?
    private var speechDelegate: SpeechSynthesizerDelegate?
    // Identity of the utterance currently being spoken. A stale finish/cancel callback
    // from a superseded utterance (e.g. switching messages mid-playback) is ignored so
    // it can't clear the new listen state or deactivate the session. See #252.
    private var activeListeningUtteranceID: ObjectIdentifier?
    // Server-TTS playback seam (#15): the factory builds an audio player from the
    // server's synthesized bytes; injectable so tests never construct a real
    // `AVAudioPlayer` (which requires decodable audio data).
    private let serverTTSAudioPlayerFactory: @MainActor (Data) throws -> any ListenAudioPlaying
    private var listenAudioPlayer: (any ListenAudioPlaying)?
    // Identity of the server-TTS player currently playing. Mirrors
    // `activeListeningUtteranceID`: a stale finish callback from a superseded player
    // must not clear the new listen state or deactivate the session.
    private var activeListenPlayerID: ObjectIdentifier?
    // In-flight `POST /api/audio/speak` fetch for the Listen action. Cancelled by
    // `stopListening()`; exposed (read-only) so tests can await the async
    // server-first path deterministically.
    @ObservationIgnored private(set) var listenPreparationTask: Task<Void, Never>?
    // Identity of the Listen request the in-flight fetch belongs to. A response
    // arriving after stop/switch carries a stale ID and is dropped instead of
    // starting audio the user no longer wants.
    private var activeListenRequestID: UUID?
    private var listenPlaybackTitle = String(localized: "Semreh response")
    private(set) var listenPlaybackPhase: ListenPlaybackPhase = .idle
    private(set) var listenPlaybackElapsedTime: TimeInterval = 0
    private(set) var listenPlaybackDuration: TimeInterval = 0
    private(set) var listenPlaybackScrubTime: TimeInterval?
    private(set) var listenPlaybackSpeed: ListenPlaybackSpeed
    @ObservationIgnored private var listenPlaybackTicker: Timer?
    private var showsLiveActivityResponseExcerpts: Bool
    private var isStreamConnectionSuspended: Bool { usesDirectGateway && directRuntime?.state == .disconnected }
    var isActiveStreamConnectionSuspended: Bool { isStreamConnectionSuspended }
    private var hasLoadedSkillSlashSuggestions = false
    private var isLoadingSkillSlashSuggestions = false
    private var queuedSlashMessages: [QueuedSlashMessage] = []
    private var isDrainingQueuedSlashMessage = false
    private var activeBtwAttemptID: UUID?
    private var activeBtwTaskID: String?
    private var activeBtwProfile: String?
    private var activeBtwMessageID: String?
    private var activeBtwQuestion: String?
    private var activeBtwAnswer = ""
    /// Local BTW cards are history-independent presentation owned only by the
    /// exact canonical conversation/profile that created them.
    private var btwLocalRowScopes: [String: (sessionID: String, profile: String)] = [:]
    private var directBackgroundAttempts: [UUID: DirectBackgroundAttempt] = [:]
    private var directBackgroundStartsInFlight: Set<UUID> = []
    private var directBackgroundResolutions: [UUID: DirectBackgroundAttemptResolution] = [:]
    /// Background result cards, like BTW cards, are history-independent local
    /// presentation owned by one exact canonical conversation and profile.
    private var backgroundLocalRowScopes: [String: (sessionID: String, profile: String)] = [:]

    init(
        session: SessionSummary,
        server: URL,
        client: APIClient? = nil,
        liveActivityManager: (any AgentLiveActivityManaging)? = nil,
        showsLiveActivityResponseExcerpts: Bool = false,
        pollingIntervals: ChatPollingIntervals = .standard,
        streamingScrollCoalescingDelayNanoseconds: UInt64 = 16_000_000,
        streamingWordRevealCadenceNanoseconds: UInt64 = 48_000_000,
        streamingMaxRevealLagNanoseconds: UInt64 = 1_000_000_000,
        speechSynthesizerFactory: @escaping () -> any ChatSpeechSynthesizing = { AVSpeechSynthesizer() },
        listenAudioSession: (any ListenAudioSessionControlling)? = nil,
        listenRemoteControlCenter: (any ListenRemoteControlControlling)? = nil,
        serverTTSAudioPlayerFactory: (@MainActor (Data) throws -> any ListenAudioPlaying)? = nil,
        userDefaults: UserDefaults = .standard,
        gatewayRuntimeProvider: (@MainActor (APIClient) async throws -> HermesServerRuntime)? = nil,
        directAttachmentPreparer: (@Sendable (Data, String, Data?) async throws -> DirectPendingAttachment)? = nil,
        directAttachmentRecoveryMarkerStore: any DirectGatewayAttachmentRecoveryMarkerStoreProtocol = DirectGatewayAttachmentRecoveryMarkerStore(),
        promptUncertaintyStore: any DirectPromptDeliveryUncertaintyStoreProtocol = DirectPromptDeliveryUncertaintyStore(),
        initialDirectConversation: GatewayConversationController? = nil
    ) {
        sessionID = session.sessionId
        currentWorkspace = session.workspace
        currentModel = session.model
        currentModelProvider = session.modelProvider
        currentProfile = session.profile
        sessionReasoningEffort = Self.nonEmpty(session.reasoningEffort)
        isCLISession = session.isCliSession == true
        self.server = server
        self.gatewayRuntimeProvider = gatewayRuntimeProvider
        self.directAttachmentPreparer = directAttachmentPreparer
        self.directAttachmentRecoveryMarkerStore = directAttachmentRecoveryMarkerStore
        self.promptUncertaintyStore = promptUncertaintyStore
        self.directConversation = initialDirectConversation
        self.directRuntime = initialDirectConversation?.sharedRuntime
        let resolvedClient = client ?? APIClient(baseURL: server)
        let resolvedLiveActivityManager = liveActivityManager ?? AgentLiveActivityManager.shared
        self.client = resolvedClient
        self.attachmentCoordinator = ChatAttachmentCoordinator(client: resolvedClient)
        self.liveActivityManager = resolvedLiveActivityManager
        self.showsLiveActivityResponseExcerpts = showsLiveActivityResponseExcerpts
        self.pollingIntervals = pollingIntervals
        self.streamingScrollCoalescingDelayNanoseconds = streamingScrollCoalescingDelayNanoseconds
        self.streamingWordRevealCadenceNanoseconds = streamingWordRevealCadenceNanoseconds
        self.streamingMaxRevealLagNanoseconds = streamingMaxRevealLagNanoseconds
        self.speechSynthesizerFactory = speechSynthesizerFactory
        self.listenAudioSession = listenAudioSession ?? ListenAudioSessionController()
        self.listenRemoteControlCenter = listenRemoteControlCenter ?? ListenRemoteControlController()
        self.userDefaults = userDefaults
        self.restoreStore = TranscriptRestoreStore(defaults: userDefaults)
        self.localOrganizerStore = LocalOrganizerStore(defaults: userDefaults)
        let restorePoint = restoreStore.load(server: server, sessionID: session.sessionId ?? session.id)
        savedFollowingLatest = restorePoint.followingLatest
        savedVisibleMessageID = restorePoint.visibleMessageID
        self.listenPlaybackSpeed = ListenPlaybackSpeed.stored(in: userDefaults)
        self.serverTTSAudioPlayerFactory = serverTTSAudioPlayerFactory
            ?? { try ServerTTSAudioPlayer(data: $0) }
        displayTitle = Self.displayTitle(from: session.title)
        self.attachmentCoordinator.delegate = self
        if let initialDirectConversation {
            configureDirectConversation(initialDirectConversation)
        }
    }

    deinit {
        directReasoningRefreshTask?.cancel()
        pendingStreamingScrollTriggerTask?.cancel()
        pendingStreamingContentFlushTask?.cancel()
        connectionVisibilityTask?.cancel()
        listenPreparationTask?.cancel()
        contextUsageSnapshotTask?.cancel()
        listenPlaybackTicker?.invalidate()
    }

    // MARK: - Direct Hermes native bridge

    private func loadDirectComposerConfiguration() async {
        guard !directInvalidated, !isLoadingComposerConfiguration else { return }
        let profile = requestProfileName ?? "default"
        let mutation = composerConfigurationMutationToken
        isLoadingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        defer { isLoadingComposerConfiguration = false }
        do {
            async let inventory = client.directModelOptions(profile: profile)
            async let profiles = client.directProfiles()
            let (options, availableProfiles) = try await (inventory, profiles)
            guard !directInvalidated, profile == (requestProfileName ?? "default"),
                  mutation == composerConfigurationMutationToken else { return }
            directModelOptions = options
            modelCatalogGroups = options.catalogGroups
            profileOptions = availableProfiles.profiles ?? []
            isSingleProfileMode = availableProfiles.singleProfileMode ?? false
            selectedProfileName = profile
            await refreshWorkspaceRoots()
            // The catalog reports profile defaults, not this stored chat's
            // effective configuration. Only a new local draft inherits them.
            if canonicalSessionID == nil, currentModel == nil {
                currentModel = Self.nonEmpty(options.model)
                currentModelProvider = Self.nonEmpty(options.provider)
            }
            applyDirectReasoningGating()
            if canonicalSessionID != nil { try await loadDirectSessionReasoning() }
        } catch {
            guard !directInvalidated, profile == (requestProfileName ?? "default"),
                  mutation == composerConfigurationMutationToken else { return }
            if canonicalSessionID != nil {
                directSessionReasoningSupported = false
                isReasoningChangeDeferred = false
                applyDirectReasoningGating()
            }
            lastError = error
            composerConfigurationErrorMessage = "Hermes chat settings could not be loaded. Your draft was preserved."
        }
    }

    private func loadDirectSessionReasoning() async throws {
        guard !directInvalidated, let expectedID = canonicalSessionID else { return }
        let mutation = composerConfigurationMutationToken
        do {
            let controller = try await ensureDirectConversation()
            let configuration = try await controller.reasoningConfiguration()
            guard !directInvalidated, !Task.isCancelled, expectedID == canonicalSessionID,
                  mutation == composerConfigurationMutationToken else { return }
            applyDirectReasoningConfiguration(configuration)
        } catch {
            guard !directInvalidated, !Task.isCancelled, expectedID == canonicalSessionID,
                  mutation == composerConfigurationMutationToken else { return }
            directSessionReasoningSupported = false
            isReasoningChangeDeferred = false
            applyDirectReasoningGating()
            throw error
        }
    }

    private func applyDirectReasoningConfiguration(_ configuration: GatewayConversationController.ReasoningConfiguration) {
        directSessionReasoningSupported = configuration.supportsSessionChanges
        selectedReasoningEffort = configuration.effort
        sessionReasoningEffort = configuration.effort
        isReasoningChangeDeferred = configuration.deferred
        applyDirectReasoningGating()
    }

    private func applyDirectSessionInfo(_ payload: JSONValue?) {
        guard !directInvalidated else { return }
        let fields = payload?.gatewayFields ?? [:]
        if let model = Self.nonEmpty(fields["model"]?.gatewayString) { currentModel = model }
        if let provider = Self.nonEmpty(fields["provider"]?.gatewayString) { currentModelProvider = provider }
        if let cwd = Self.nonEmpty(fields["cwd"]?.gatewayString) { currentWorkspace = cwd }
        // Older metadata must not replace an in-flight optimistic selection.
        if !isUpdatingComposerConfiguration, directConversation?.pendingReasoningEffort == nil {
            if let effort = fields["reasoning_effort"]?.gatewayString {
                selectedReasoningEffort = Self.nonEmpty(effort)
                sessionReasoningEffort = selectedReasoningEffort
            }
            if case .bool(let deferred) = fields["reasoning_deferred"] {
                isReasoningChangeDeferred = deferred
            }
        }
        applyDirectReasoningGating()
    }

    private func selectDirectSessionReasoning(_ effort: String) async -> Bool {
        guard !directInvalidated, !isViewingCachedData, !isUpdatingComposerConfiguration,
              directSessionReasoningSupported, supportsReasoningEffort == true,
              supportedReasoningEfforts?.contains(effort) == true,
              let expectedID = canonicalSessionID else { return false }
        guard effort != selectedReasoningSelection else { return false }
        let previousEffort = selectedReasoningEffort
        let previousOverride = sessionReasoningEffort
        let previousDeferred = isReasoningChangeDeferred
        composerConfigurationMutationToken &+= 1
        let mutation = composerConfigurationMutationToken
        selectedReasoningEffort = effort
        sessionReasoningEffort = effort
        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        lastError = nil
        defer {
            if mutation == composerConfigurationMutationToken { isUpdatingComposerConfiguration = false }
        }
        do {
            let controller = try await ensureDirectConversation()
            let configuration = try await controller.setReasoningEffort(effort)
            guard !directInvalidated, expectedID == canonicalSessionID,
                  mutation == composerConfigurationMutationToken else { return false }
            applyDirectReasoningConfiguration(configuration)
            return true
        } catch {
            guard !directInvalidated, expectedID == canonicalSessionID,
                  mutation == composerConfigurationMutationToken else { return false }
            selectedReasoningEffort = previousEffort
            sessionReasoningEffort = previousOverride
            isReasoningChangeDeferred = previousDeferred
            // A lost acknowledgement can be ambiguous. Never retry the write;
            // require a fresh settings read before another selection.
            directSessionReasoningSupported = false
            applyDirectReasoningGating()
            lastError = error
            composerConfigurationErrorMessage = "Reasoning could not be confirmed. Reload chat settings before trying again."
            return false
        }
    }

    private func applyDirectReasoningGating() {
        let capability = directModelOptions?.providers?.first { $0.slug == currentModelProvider }?
            .capabilities?[currentModel ?? ""]
        // These are the pinned create-time parser's levels, not a claim that
        // every provider implements every level without coercion.
        supportedReasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
            .filter { $0 != "none" || capability?.canDisableReasoning != false }
        let configurable = canonicalSessionID == nil || directSessionReasoningSupported
        supportsReasoningEffort = capability?.reasoning == true && configurable
        sessionScopedReasoning = configurable
    }

    var allowsModelAndWorkspaceChanges: Bool {
        !usesDirectGateway || canonicalSessionID == nil
    }

    private func canConfigureDirectDraft() -> Bool {
        guard !directInvalidated, !isViewingCachedData, !isUpdatingComposerConfiguration,
              activeStreamID == nil else {
            composerConfigurationErrorMessage = "Wait until this chat is idle and connected to change its settings."
            return false
        }
        guard canonicalSessionID == nil else {
            composerConfigurationErrorMessage = "Model and workspace changes on an existing direct chat are not available yet. Choose them in New Chat before its first send."
            return false
        }
        composerConfigurationErrorMessage = nil
        return true
    }

    private func ensureDirectConversation() async throws -> GatewayConversationController {
        guard !directInvalidated, let gatewayRuntimeProvider else { throw DirectSessionError.stopped }
        if let directConversation { return directConversation }
        if let directAttachmentTask { return try await directAttachmentTask.value }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw DirectSessionError.stopped }
            let runtime = try await gatewayRuntimeProvider(self.client)
            guard !self.directInvalidated else { throw DirectSessionError.stopped }
            let controller = GatewayConversationController(
                runtime: runtime,
                client: self.client,
                storedID: self.canonicalSessionID,
                profile: Self.nonEmpty(self.currentProfile) ?? "default",
                recoveryMarkerStore: self.directAttachmentRecoveryMarkerStore,
                promptUncertaintyStore: self.promptUncertaintyStore
            )
            self.directRuntime = runtime
            self.directConversation = controller
            self.configureDirectConversation(controller)
            return controller
        }
        directAttachmentTask = task
        defer { directAttachmentTask = nil }
        return try await task.value
    }

    private func configureDirectConversation(_ controller: GatewayConversationController) {
        controller.isVisible = directVisible
        controller.isEditing = directComposerIsEditing
        controller.onRecoveredIdle = { [weak self, weak controller] recoveredID in
            guard let self, let controller,
                  !self.directInvalidated, self.directConversation === controller,
                  controller.storedID == recoveredID, self.canonicalSessionID == recoveredID,
                  self.directHistoryID == recoveredID,
                  let ownedRun = self.directLiveActivityRun,
                  ownedRun.sessionID == recoveredID, ownedRun.profile == controller.profile else { return }
            self.endDirectLiveActivity(status: .ended, activity: String(localized: "No longer running"))
        }
        controller.onBinding = { [weak self, weak controller] binding in
            guard let self, let controller,
                  !self.directInvalidated,
                  self.directConversation === controller else { return }
            self.adoptDirectID(binding.storedID)
        }
        controller.onCanonicalID = { [weak self, weak controller] id in
            guard let self, let controller,
                  !self.directInvalidated,
                  self.directConversation === controller else { return }
            self.adoptDirectID(id)
        }
        controller.onResume = { [weak self, weak controller] result in
            guard let self, let controller,
                  !self.directInvalidated,
                  self.directConversation === controller,
                  controller.storedID == self.canonicalSessionID else { return }
            self.applyDirectSessionInfo(result?.gatewayFields["info"])
            self.syncDirectClarificationPrompt()
            self.directBlockingInteractionErrorMessage = nil
            self.directBlockingInteractionErrorIdentity = nil
            if controller.hasAmbiguousPromptDelivery {
                self.sendErrorMessage = self.promptDeliveryWarning(for: controller)
            }
        }
        controller.onReasoningConfiguration = { [weak self, weak controller] configuration in
            guard let self, let controller,
                  !self.directInvalidated,
                  self.directConversation === controller,
                  controller.storedID == self.canonicalSessionID else { return }
            self.applyDirectReasoningConfiguration(configuration)
        }
        controller.onTranscript = { [weak self, weak controller] page, older in
            guard let self, let controller,
                  !self.directInvalidated,
                  self.directConversation === controller else { return }
            self.applyDirectTranscript(page, older: older)
        }
        controller.onEvent = { [weak self, weak controller] event in
            guard let self, let controller,
                  !self.directInvalidated,
                  self.directConversation === controller else { return }
            let previousPrompt = self.directClarificationPrompt
            self.applyDirectEvent(event,
                suppressUnwatermarkedContent: controller.suppressesColdResumedContent)
            if event.type == "clarify.request",
               let currentPrompt = controller.pendingBlockingPrompt,
               previousPrompt?.gatewayIdentity != currentPrompt.identity {
                self.clearDirectClarificationOwnedSendError()
                self.directClarificationErrorMessage = nil
            } else if event.type == "clarify.expire",
                      let requestID = event.payload?.gatewayFields["request_id"]?.gatewayString,
                      previousPrompt?.pending.clarifyId == requestID {
                let message = "That clarification expired before it was answered."
                self.directClarificationErrorMessage = message
                self.setDirectClarificationSendError(message)
            }
            self.syncDirectClarificationPrompt()
            if event.type == "message.complete",
               controller.runState == .idle,
               !controller.hasAmbiguousPromptDelivery {
                self.drainQueuedSlashMessageIfIdle()
            }
        }
        controller.onBtwOutcome = { [weak self, weak controller] outcome in
            guard let self, let controller,
                  !self.directInvalidated,
                  self.directConversation === controller,
                  controller.profile == self.activeBtwProfile else { return }
            self.applyDirectBtwOutcome(outcome)
        }
        controller.onBackgroundOutcome = { [weak self, weak controller] outcome in
            guard let self, let controller,
                  !self.directInvalidated,
                  self.directConversation === controller else { return }
            self.applyDirectBackgroundOutcome(outcome, controller: controller)
        }
        controller.onError = { [weak self, weak controller] error in
            guard let self, let controller,
                  !self.directInvalidated,
                  self.directConversation === controller else { return }
            if let blockingError = error as? GatewayBlockingError {
                let message = self.directClarificationMessage(for: blockingError)
                self.directClarificationErrorMessage = message
                if self.directClarificationPrompt == nil {
                    self.setDirectClarificationSendError(message)
                }
                return
            }
            self.lastError = error
            self.sendErrorMessage = "The Hermes connection needs attention. No message was automatically resent."
        }
    }

    /// Branches a direct Hermes conversation and transfers the already-bound
    /// child controller to a new ChatViewModel. The optional name is rejected
    /// explicitly until the controller seam carries the stock name field;
    /// it is never silently discarded.
    func branchDirectConversation(name: String = "") async -> SlashCommandExecutionResult {
        guard usesDirectGateway else {
            return .unsupported(friendlyMessage: "Branching is not available outside direct Hermes mode.")
        }
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unsupported(friendlyMessage: "Named direct branches are not available yet.")
        }
        guard !directInvalidated, !isViewingCachedData, !isStartingChat,
              activeStreamID == nil else {
            return .unsupported(friendlyMessage: "Wait for the current response to finish before branching.")
        }

        let expectedProfile = Self.nonEmpty(currentProfile) ?? "default"
        var detachedChild: GatewayConversationController?
        var detachedChildViewModel: ChatViewModel?
        do {
            let parent = try await ensureDirectConversation()
            guard !directInvalidated,
                  directConversation === parent,
                  parent.profile == expectedProfile,
                  parent.runtimeOrigin == server,
                  parent.runState == .idle else {
                throw DirectSessionError.ambiguousPrompt
            }
            try await parent.open()
            guard !directInvalidated,
                  directConversation === parent,
                  parent.profile == expectedProfile,
                  parent.runtimeOrigin == server,
                  parent.runState == .idle,
                  let expectedParentBinding = parent.binding,
                  let expectedParentID = parent.storedID,
                  expectedParentID == canonicalSessionID else {
                throw DirectSessionError.staleOperation
            }
            let expectedParentCanonicalID = canonicalSessionID
            let expectedParentRuntime = parent.sharedRuntime
            func parentScopeIsCurrent() -> Bool {
                !directInvalidated &&
                    directConversation === parent &&
                    parent.binding == expectedParentBinding &&
                    parent.storedID == expectedParentID &&
                    canonicalSessionID == expectedParentCanonicalID &&
                    parent.profile == expectedProfile &&
                    parent.runtimeOrigin == server &&
                    parent.sharedRuntime === expectedParentRuntime &&
                    directRuntime === expectedParentRuntime
            }

            let child = try await parent.branch()
            detachedChild = child
            guard parentScopeIsCurrent() else {
                throw DirectSessionError.staleOperation
            }
            guard child.profile == expectedProfile,
                  child.runtimeOrigin == server,
                  child.sharedRuntime === parent.sharedRuntime,
                  let childID = child.storedID,
                  !childID.isEmpty else {
                throw DirectSessionBranchError.invalidResponse
            }

            // Detail is the authoritative summary used by the session store;
            // do not synthesize sidebar metadata from the branch RPC.
            let summary = try await client.directSessionDetail(
                sessionID: childID,
                profile: expectedProfile
            )
            guard summary.sessionId == childID,
                  summary.profile == expectedProfile else {
                throw DirectHermesRESTError.profileMismatch
            }
            guard !directInvalidated,
                  parentScopeIsCurrent(),
                  parent.sharedRuntime === child.sharedRuntime else {
                throw DirectSessionError.staleOperation
            }

            let childViewModel = ChatViewModel(
                session: summary,
                server: server,
                client: client,
                liveActivityManager: liveActivityManager,
                showsLiveActivityResponseExcerpts: showsLiveActivityResponseExcerpts,
                pollingIntervals: pollingIntervals,
                userDefaults: userDefaults,
                gatewayRuntimeProvider: gatewayRuntimeProvider,
                directAttachmentPreparer: directAttachmentPreparer,
                directAttachmentRecoveryMarkerStore: directAttachmentRecoveryMarkerStore,
                promptUncertaintyStore: promptUncertaintyStore,
                initialDirectConversation: child
            )
            detachedChildViewModel = childViewModel

            // The controller performed its branch-time verification; refresh
            // once after callback wiring so the child VM owns its transcript.
            try await child.refresh()
            guard !childViewModel.directInvalidated,
                  childViewModel.directConversation === child,
                  child.storedID == childID,
                  parentScopeIsCurrent() else {
                throw DirectSessionError.staleOperation
            }

            let handoff = DirectBranchHandoff(
                session: summary,
                viewModel: childViewModel,
                origin: server,
                profile: expectedProfile,
                identity: UUID()
            )
            return .openedDirectBranch(handoff)
        } catch {
            if let detachedChildViewModel {
                detachedChildViewModel.invalidateDirectConversation()
                await detachedChildViewModel.disposeDirectConversation()
            } else if let detachedChild {
                detachedChild.invalidate()
                try? await detachedChild.dispose()
            }
            lastError = error
            return .unsupported(friendlyMessage: "The direct Hermes branch could not be opened safely.")
        }
    }

    private func adoptDirectID(_ id: String) {
        guard !directInvalidated, sessionID != id else { return }
        sessionID = id
        applyDirectReasoningGating()
        onDirectCanonicalID?(id)
    }

    func invalidateDirectConversation() {
        guard usesDirectGateway else { return }
        failActiveBtwAttempt(String(localized: "The Hermes connection changed before the side question finished."))
        failDirectBackgroundAttempts()
        btwLocalRowScopes.removeAll()
        backgroundLocalRowScopes.removeAll()
        directInvalidated = true
        sendTranscriptSessionID = nil
        directReasoningRefreshTask?.cancel()
        cancelContextUsageSnapshotTask()
        directSessionReasoningSupported = false
        isReasoningChangeDeferred = false
        directClarificationPrompt = nil
        directClarificationErrorMessage = nil
        directClarificationOwnedSendError = nil
        isRespondingToDirectClarification = false
        directBlockingInteractionErrorMessage = nil
        directBlockingInteractionErrorIdentity = nil
        clearDirectPendingAttachments()
        directConversation?.invalidate()
        directAttachmentTask?.cancel()
        stopSessionEventSync()
        cleanupPollingTasks()
        resetPendingStreamingContentBuffers()
        if directConversation?.runState != .idle { liveActivityManager.markStale() }
    }

    func setDirectComposerEditing(_ editing: Bool) {
        directComposerIsEditing = editing
        directConversation?.isEditing = editing
    }

    func disposeDirectConversation() async {
        guard usesDirectGateway else { return }
        invalidateDirectConversation()
        do { try await directConversation?.dispose() }
        catch {
            lastError = error
            sendErrorMessage = "The unused Hermes draft could not be confirmed closed."
        }
        directConversation = nil
        directRuntime = nil
    }

    @ObservationIgnored private var directLoadWaitOwner: UUID?

    private func cancelContextUsageSnapshotTask() {
        contextUsageSnapshotTask?.cancel()
        contextUsageSnapshotTask = nil
        contextUsageSnapshotTaskOwner = nil
    }

    private func scheduleContextUsageSnapshot(
        for controller: GatewayConversationController,
        loadGeneration: Int,
        requestedSessionID: String?,
        requestedProfile: String?
    ) {
        cancelContextUsageSnapshotTask()
        let owner = UUID()
        let usageRevision = contextUsageRevision
        contextUsageSnapshotTaskOwner = owner
        contextUsageSnapshotTask = Task { @MainActor [weak self, controller] in
            defer {
                if let self, self.contextUsageSnapshotTaskOwner == owner {
                    self.contextUsageSnapshotTask = nil
                    self.contextUsageSnapshotTaskOwner = nil
                }
            }

            guard let usage = try? await controller.contextUsageSnapshot(),
                  !Task.isCancelled,
                  let self,
                  self.contextUsageSnapshotTaskOwner == owner,
                  self.messageLoadGeneration == loadGeneration,
                  self.contextUsageRevision == usageRevision,
                  !self.directInvalidated,
                  self.directConversation === controller,
                  self.canonicalSessionID == requestedSessionID,
                  self.requestProfileName == requestedProfile,
                  controller.runState == .idle else { return }
            self.contextWindowSnapshot = usage
        }
    }

    private func loadDirectMessages(modelContext: ModelContext?) async {
        guard !directInvalidated else { return }
        messageLoadGeneration &+= 1
        cancelContextUsageSnapshotTask()
        let generation = messageLoadGeneration
        let requestedID = canonicalSessionID
        let requestedProfile = requestProfileName
        let modelContext = modelContext ?? directModelContext
        directModelContext = modelContext
        let waitOwner = UUID()
        directLoadWaitOwner = waitOwner
        beginConnectionWaitIfNeeded()
        if let sessionID, messages.isEmpty, let modelContext {
            _ = renderCachedMessagesBeforeReload(sessionID: sessionID, modelContext: modelContext)
        }
        let initialMessages = messages
        errorMessage = nil
        cacheErrorMessage = nil
        lastError = nil
        defer {
            if directLoadWaitOwner == waitOwner {
                directLoadWaitOwner = nil
                endConnectionWait()
            }
        }
        do {
            let wasAttached = directConversation?.binding != nil
            let controller = try await ensureDirectConversation()
            // open/resume already performs one canonical read. A warm idle
            // refresh needs another; never overwrite an active streamed turn.
            try await controller.open()
            if wasAttached, controller.runState == .idle { try await controller.refresh() }
            guard messageLoadGeneration == generation, !directInvalidated,
                  requestedProfile == requestProfileName else { return }
            // Usage ticks are emitted while a run is active. Cold-restored and
            // already-idle chats need one explicit snapshot so controls do not
            // misleadingly present context as unavailable until the next send.
            // This optional telemetry must not extend the transcript's loading
            // or connection-wait window.
            if controller.runState == .idle {
                scheduleContextUsageSnapshot(
                    for: controller,
                    loadGeneration: generation,
                    requestedSessionID: canonicalSessionID,
                    requestedProfile: requestedProfile
                )
            }
            errorMessage = nil
        } catch DirectSessionError.staleOperation {
            // A newer turn/read owns presentation; this is not a load failure.
        } catch {
            guard !Task.isCancelled, messageLoadGeneration == generation, !directInvalidated,
                  requestedID == canonicalSessionID, requestedProfile == requestProfileName else { return }
            lastError = error
            // Only a real cache adoption is offline presentation. Auth/server errors
            // must not turn a retained online transcript into purported cached data.
            let useCache: Bool
            if let gatewayError = error as? HermesGatewayError {
                switch gatewayError {
                case .closed, .notConnected, .timeout:
                    useCache = true
                case .transport(let operation):
                    // These are exact local failure codes emitted by our client,
                    // not server text. Encoding failures are not connectivity loss.
                    useCache = operation == "WebSocket receive failed" || operation == "WebSocket send failed"
                default:
                    useCache = false
                }
            } else if case DirectHermesRequestError.http(let status, _) = error {
                useCache = CacheFallbackPolicy.shouldUseCache(for: APIError.http(statusCode: status, body: nil))
            } else {
                useCache = CacheFallbackPolicy.shouldUseCache(for: error)
            }
            if useCache, !hasPreservedLiveRun, messages == initialMessages, let requestedID, let modelContext {
                do {
                    let cached = try CacheStore.cachedMessages(serverURL: server,
                        sessionID: transcriptCacheID(requestedID), in: modelContext,
                        limit: Self.messagePageLimit)
                    if !cached.isEmpty {
                        withBatchedTranscriptDerivedState {
                            messages = cached
                            messagesOffset = 0
                        }
                        hasOlderMessages = false
                        isViewingCachedData = true
                        clearCacheFirstMessagePlaceholder()
                        errorMessage = nil
                        return
                    }
                } catch { cacheErrorMessage = error.localizedDescription }
            }
            revertCacheFirstPlaceholderIfNeeded()
            isViewingCachedData = false
            errorMessage = error.localizedDescription
        }
    }

    private func loadOlderDirectMessages(modelContext: ModelContext?) async -> Bool {
#if DEBUG
        // One content-free result per invocation. -1 means refresh was never
        // dispatched; no session IDs, row IDs, errors, or response bodies log.
        let diagnosticCountBefore = messages.count
        var diagnosticRequestedOffset = -1
        var diagnosticOutcome = "guard_rejected"
        defer {
            Self.olderLoadOutcomeLogger.debug("""
                event=older_loader_outcome reason=\(diagnosticOutcome, privacy: .public) \
                requestedOffset=\(diagnosticRequestedOffset, privacy: .public) \
                messagesBefore=\(diagnosticCountBefore, privacy: .public) messagesAfter=\(self.messages.count, privacy: .public)
                """)
        }
#endif
        guard !directInvalidated, !isLoadingOlderMessages, hasOlderMessages,
              directConversation != nil else {
#if DEBUG
            diagnosticOutcome = directInvalidated ? "guard_invalidated"
                : isLoadingOlderMessages ? "guard_already_loading"
                : !hasOlderMessages ? "guard_no_older_messages"
                : "guard_missing_controller"
#endif
            return false
        }
        directModelContext = modelContext ?? directModelContext
        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }
        let count = messages.count
        do {
            let controller = try await ensureDirectConversation()
            let anchor = controller.runState == .idle ? nil : messages.first?.messageId
            guard controller.runState == .idle || anchor != nil else {
#if DEBUG
                diagnosticOutcome = "guard_active_without_anchor"
#endif
                return false
            }
#if DEBUG
            diagnosticRequestedOffset = directOlderOffset
#endif
            try await controller.refresh(limit: 120, offset: directOlderOffset, olderAnchorID: anchor)
#if DEBUG
            diagnosticOutcome = messages.count > count ? "refresh_count_increased" : "refresh_no_count_increase"
#endif
            return messages.count > count
        } catch GatewayConversationController.OlderPageError.canonicalChanged {
            // An active turn keeps its live identity. Terminal/reconnect owns
            // canonical revalidation; never retry this as a different page.
#if DEBUG
            diagnosticOutcome = "canonical_changed"
#endif
            return false
        } catch DirectSessionError.staleOperation {
            // A newer tail/rebind won the race. Its cursor is authoritative;
            // leave the current rows in place and allow another explicit page.
#if DEBUG
            diagnosticOutcome = "stale_operation"
#endif
            return false
        } catch {
#if DEBUG
            diagnosticOutcome = "other_error"
#endif
            lastError = error; errorMessage = "Could not load older messages."; return false
        }
    }

    private func applyDirectTranscript(_ page: DirectHermesTranscriptPage, older: Bool) {
        if older {
            // Paging expands only the existing durable history. It must not
            // reset the transient live tail, tool/reasoning groups, or timers.
            guard directHistoryID == page.sessionID else { return }
            streamingAssistantMessageIndex = nil
            isApplyingOlderDirectHistoryPage = true
            defer { isApplyingOlderDirectHistoryPage = false }
            withBatchedTranscriptDerivedState {
                messages = Self.prependingOlderMessages(page.messages, to: messages)
            }
            let knownToolIDs = Set(completedToolCallGroups.flatMap { $0.toolCalls.map(\.id) } + liveToolCalls.map(\.id))
            let olderGroups = ToolCallGroup.groups(persistedToolCalls: [], messages: messages, messageOffset: 0)
                .compactMap { group -> ToolCallGroup? in
                    let newTools = group.toolCalls.filter { !knownToolIDs.contains($0.id) }
                    guard !newTools.isEmpty else { return nil }
                    return ToolCallGroup(id: group.id, anchorMessageID: group.anchorMessageID, toolCalls: newTools)
                }
            var retainedGroups = completedToolCallGroups
            var prependedGroups: [ToolCallGroup] = []
            for group in olderGroups {
                if let index = retainedGroups.firstIndex(where: { $0.anchorMessageID == group.anchorMessageID }) {
                    let existing = retainedGroups[index]
                    retainedGroups[index] = ToolCallGroup(id: existing.id,
                        anchorMessageID: existing.anchorMessageID, toolCalls: group.toolCalls + existing.toolCalls)
                } else {
                    prependedGroups.append(group)
                }
            }
            setCompletedToolCallGroups(prependedGroups + retainedGroups)
            let returned = page.pagination?.returned ?? page.messages.count
            directOlderOffset = (page.pagination?.offset ?? directOlderOffset) + returned
            hasOlderMessages = returned >= (page.pagination?.limit ?? 120)
            cacheCurrentMessages(sessionID: page.sessionID, modelContext: directModelContext)
            return
        }
        // `sendDirectMessage` resumes an existing durable session before it
        // stages the new prompt.  Hermes can acknowledge that resume while its
        // canonical transcript read is still temporarily empty.  Do not turn
        // a populated, same-session transcript into the empty-state view during
        // that bounded send window; the later canonical tail owns the eventual
        // replacement.  The same transient race hits foreground re-entry and
        // old-chat detail reuse (P01): an empty canonical page for the session
        // already on screen must never silently blank populated rows.  The
        // protection is keyed to those exact transient windows only — never
        // to every same-session empty page.  An ordinary idle refresh, an
        // ambiguous-delivery resume (its empty canonical page is what drops
        // the unconfirmed optimistic ghost), a different canonical session,
        // an explicit clear, or a genuinely empty transcript still applies
        // authoritatively.
        if page.messages.isEmpty,
           !messages.isEmpty,
           (directHistoryID == nil || directHistoryID == page.sessionID),
           (isStartingChat && page.sessionID == sendTranscriptSessionID)
               || ((isForegroundReentryRead || wasReusedFromOpenSessionStore)
                   && page.sessionID == canonicalSessionID) {
            return
        }
        let renderedCache = cacheFirstMessagePlaceholder != nil
        flushPendingStreamingContent()
        resetPendingStreamingContentBuffers()
        let canonicalChanged = directHistoryID != nil && directHistoryID != page.sessionID
        let previouslyHadOlder = hasOlderMessages
        var retainedPrefix: [ChatMessage] = []
        if !older, directHistoryID == page.sessionID,
           let firstID = page.messages.first?.messageId,
           let overlap = messages.firstIndex(where: { $0.messageId == firstID }) {
            // The REST page owns its suffix, not all previously loaded history.
            // Only a durable overlap proves continuity. Never union a disjoint
            // tail, retain optimistic rows, or carry history across a new tip.
            let prefix = messages[..<overlap]
            let isCanonicalPrefix = prefix.allSatisfy { message in
                guard let id = message.messageId else { return false }
                return !id.isEmpty && !id.hasPrefix("local-")
            }
            if isCanonicalPrefix { retainedPrefix = Array(prefix) }
        }
        adoptDirectID(page.sessionID)
        directHistoryID = page.sessionID
        let profile = directConversation?.profile ?? (Self.nonEmpty(currentProfile) ?? "default")
        let retainedLocalRows: [ChatMessage]
        if older {
            retainedLocalRows = []
        } else {
            btwLocalRowScopes = btwLocalRowScopes.filter {
                $0.value.sessionID == page.sessionID && $0.value.profile == profile
            }
            backgroundLocalRowScopes = backgroundLocalRowScopes.filter {
                $0.value.sessionID == page.sessionID && $0.value.profile == profile
            }
            retainedLocalRows = messages.filter { message in
                guard let id = message.messageId else { return false }
                let scope = btwLocalRowScopes[id] ?? backgroundLocalRowScopes[id]
                guard let scope else { return false }
                return scope.sessionID == page.sessionID && scope.profile == profile
            }
        }
        withBatchedTranscriptDerivedState {
            let canonicalMessages = older && !canonicalChanged
                ? Self.prependingOlderMessages(page.messages, to: messages) : retainedPrefix + page.messages
            let canonicalIDs = Set(canonicalMessages.compactMap(\.messageId))
            messages = canonicalMessages + retainedLocalRows.filter { row in
                guard let id = row.messageId else { return false }
                return !canonicalIDs.contains(id)
            }
            // WebUI's forward absolute offset is not the direct backwards cursor.
            // Stable durable row IDs own transcript identity on this path.
            messagesOffset = 0
        }
        let returned = page.pagination?.returned ?? page.messages.count
        directOlderOffset = (page.pagination?.offset ?? (older ? directOlderOffset : 0)) + returned + retainedPrefix.count
        hasOlderMessages = !retainedPrefix.isEmpty ? previouslyHadOlder : returned >= (page.pagination?.limit ?? 120)
        setCompletedToolCallGroups(ToolCallGroup.groups(persistedToolCalls: [], messages: messages, messageOffset: 0))
        completedReasoningGroups = []
        streamingAssistantMessageID = nil
        streamingAssistantMessageIndex = nil
        sealedInterimAssistantMessageIDs.removeAll()
        liveToolCalls = []
        liveReasoningText = ""
        reasoningAnchorMessageID = nil
        toolCallAnchorMessageID = nil
        clearCacheFirstMessagePlaceholder()
        if renderedCache { cacheFirstReconcileScrollToken += 1 }
        isViewingCachedData = false
        responseCompletionNeedsTranscriptRefresh = false
        cacheCurrentMessages(sessionID: page.sessionID, modelContext: directModelContext)
    }


    private func sendDirectMessage(
        _ draft: String,
        modelContext: ModelContext?,
        selectedAttachmentIDs: Set<UUID>? = nil,
        removeSelectedAttachmentsOnAmbiguousDelivery: Bool = true,
        requiredController: GatewayConversationController? = nil,
        requiredSessionID: String? = nil,
        requiredProfile: String? = nil,
        requiredOrigin: URL? = nil,
        requiredConnectionGeneration: Int? = nil
    ) async -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !directInvalidated, !isStartingChat,
              !isUpdatingComposerConfiguration else { return false }
        guard !attachmentRecoveryIsBusy else {
            sendErrorMessage = "Resetting unresolved attachment delivery. Your draft was kept."
            return false
        }
        guard directConversation?.hasAmbiguousPromptDelivery != true else {
            sendErrorMessage = promptDeliveryWarning(for: directConversation)
            return false
        }
        guard directConversation?.runState == nil || directConversation?.runState == .idle else { return false }
        if attachmentRecoveryNeedsReset, directPendingAttachments.isEmpty {
            sendErrorMessage = "An attachment delivery is unresolved. Reset the pending upload before continuing."
            return false
        }
        guard pendingAttachments.isEmpty, !isPreparingDirectAttachment else {
            sendErrorMessage = "Direct Hermes attachments are not available yet. Your draft was kept."
            return false
        }
        directModelContext = modelContext ?? directModelContext
        isStartingChat = true
        // Capture before `open()`: resume may adopt a different canonical
        // session before its transcript callback arrives.  Only an empty
        // result for this original session can be the transient read race.
        sendTranscriptSessionID = canonicalSessionID
        cancelContextUsageSnapshotTask()
        sendErrorMessage = nil
        lastError = nil
        defer {
            sendTranscriptSessionID = nil
            isStartingChat = false
            OpenChatSessionStore.shared.noteStreamingStateChanged()
        }
        let localID = "local-\(UUID().uuidString)"
        let wasDraft = canonicalSessionID == nil
        let hasExplicitAttachmentSelection = selectedAttachmentIDs != nil
        let attachmentIDs = selectedAttachmentIDs ?? Set(directPendingAttachments.map(\.id))
        let selectionGeneration = directAttachmentSelectionGeneration
        do {
            let controller = try await ensureDirectConversation()
            guard requiredController == nil || directConversation === requiredController,
                  requiredController == nil || controller === requiredController,
                  requiredSessionID == nil || controller.storedID == requiredSessionID,
                  requiredProfile == nil || controller.profile == requiredProfile,
                  requiredOrigin == nil || controller.sharedRuntime.origin == requiredOrigin,
                  requiredConnectionGeneration == nil
                    || controller.sharedRuntime.connectionGeneration == requiredConnectionGeneration else {
                throw DirectSessionError.staleOperation
            }
            // Resume first so its canonical transcript cannot erase this new
            // optimistic row. Draft open remains completely local.
            try await controller.open()
            guard !directInvalidated, controller.runState == .idle,
                  requiredController == nil || controller === requiredController,
                  requiredSessionID == nil || controller.storedID == requiredSessionID,
                  requiredProfile == nil || controller.profile == requiredProfile,
                  requiredOrigin == nil || controller.sharedRuntime.origin == requiredOrigin,
                  requiredConnectionGeneration == nil
                    || controller.sharedRuntime.connectionGeneration == requiredConnectionGeneration,
                  requiredConnectionGeneration == nil || controller.sharedRuntime.state == .ready else {
                throw DirectSessionError.ambiguousPrompt
            }
            var creation: [String: JSONValue] = [:]
            if let value = Self.nonEmpty(currentWorkspace) { creation["cwd"] = .string(value) }
            if let value = Self.nonEmpty(currentModel) { creation["model"] = .string(value) }
            if let value = Self.nonEmpty(currentModelProvider) { creation["provider"] = .string(value) }
            if let value = Self.nonEmpty(sessionReasoningEffort) { creation["reasoning_effort"] = .string(value) }

            try await stageDirectAttachments(
                attachmentIDs: attachmentIDs,
                selectionGeneration: selectionGeneration,
                controller: controller,
                create: creation
            )
            try Task.checkCancellation()
            let currentAttachmentIDs = Set(directPendingAttachments.map(\.id))
            guard !directInvalidated,
                  selectionGeneration == directAttachmentSelectionGeneration,
                  (hasExplicitAttachmentSelection
                    ? attachmentIDs.isSubset(of: currentAttachmentIDs)
                    : attachmentIDs == currentAttachmentIDs),
                  requiredController == nil || controller === requiredController,
                  requiredSessionID == nil || controller.storedID == requiredSessionID,
                  requiredProfile == nil || controller.profile == requiredProfile,
                  requiredOrigin == nil || controller.sharedRuntime.origin == requiredOrigin,
                  requiredConnectionGeneration == nil
                    || controller.sharedRuntime.connectionGeneration == requiredConnectionGeneration,
                  requiredConnectionGeneration == nil || controller.sharedRuntime.state == .ready else {
                throw DirectSessionError.staleOperation
            }

            messageLoadGeneration &+= 1
            archiveLiveReasoningIfNeeded()
            archiveLiveToolCallsIfNeeded()
            resetPendingStreamingContentBuffers()
            streamingAssistantMessageID = nil
            liveToolCalls = []
            liveReasoningText = ""
            reasoningAnchorMessageID = nil
            toolCallAnchorMessageID = nil
            directResponseComplete = false
            outgoingInsertionSequence += 1
            outgoingInsertionEvent = OutgoingInsertionEvent(
                scope: outgoingInsertionScope, messageID: localID,
                sequence: outgoingInsertionSequence
            )
            messages.append(ChatMessage(
                role: "user",
                content: text,
                timestamp: Date().timeIntervalSince1970,
                messageId: localID
            ))
            // The protected interval ends at the optimistic insertion.  Any
            // later empty refresh is no longer the pre-submit race and must
            // retain the ordinary authoritative-empty semantics.
            sendTranscriptSessionID = nil
            let stagedAttachments = directPendingAttachments.filter { attachmentIDs.contains($0.id) }
            guard stagedAttachments.count == attachmentIDs.count else { throw DirectSessionError.staleOperation }
            try await controller.submit(text, stagedAttachments: stagedAttachments, create: creation)
            removeDirectPendingAttachments(ids: attachmentIDs)
            if wasDraft {
                // Discover per-session support after acceptance, without holding
                // up sending or creating another chat merely to read settings.
                directReasoningRefreshTask?.cancel()
                directReasoningRefreshTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do { try await self.loadDirectSessionReasoning() }
                    catch {
                        guard !self.directInvalidated, !Task.isCancelled else { return }
                        self.composerConfigurationErrorMessage = "Session reasoning controls could not be loaded. Open the model picker to reload chat settings."
                    }
                }
            }
            if let sessionID { cacheCurrentMessages(sessionID: sessionID, modelContext: directModelContext) }
            return true
        } catch let failure as DirectAttachmentSendFailure {
            lastError = failure.error
            switch failure.error {
            case .definiteBeforeStage:
                sendErrorMessage = "\(failure.filename) could not be staged. Your draft was kept."
            case .unknown:
                sendErrorMessage = "Staging \(failure.filename) is uncertain. Your draft was kept and will not be retried automatically."
            }
            rollbackOptimisticMessage(id: localID)
            return false
        } catch is DirectPromptDeliveryUncertaintyError {
            rollbackOptimisticMessage(id: localID)
            sendErrorMessage = "Semreh could not save the delivery safety state, so the message was not sent. Your draft was kept."
            return false
        } catch is CancellationError {
            if directConversation?.hasAmbiguousPromptDelivery == true
                || directConversation?.runState == .deliveryUnknown {
                if removeSelectedAttachmentsOnAmbiguousDelivery {
                    removeDirectPendingAttachments(ids: attachmentIDs)
                }
                sendErrorMessage = promptDeliveryWarning(for: directConversation)
                return true
            }
            rollbackOptimisticMessage(id: localID)
            return false
        } catch {
            lastError = error
            if directConversation?.hasAmbiguousPromptDelivery == true
                || directConversation?.runState == .deliveryUnknown {
                // Keep the staged row as uncertain. Canonical history is refreshed,
                // but only explicit local abandonment unlocks a different message.
                if removeSelectedAttachmentsOnAmbiguousDelivery {
                    removeDirectPendingAttachments(ids: attachmentIDs)
                }
                sendErrorMessage = promptDeliveryWarning(for: directConversation)
                return true
            }
            rollbackOptimisticMessage(id: localID)
            sendErrorMessage = "Hermes could not accept this message. Your draft was kept."
            return false
        }
    }

    private func stageDirectAttachments(
        attachmentIDs: Set<UUID>,
        selectionGeneration: Int,
        controller: GatewayConversationController,
        create: [String: JSONValue]
    ) async throws {
        guard !attachmentIDs.isEmpty else { return }
        let snapshot = directPendingAttachments.filter { attachmentIDs.contains($0.id) }
        guard snapshot.count == attachmentIDs.count else { throw DirectSessionError.staleOperation }
        var passedCreate = false

        for attachment in snapshot {
            try Task.checkCancellation()
            guard !directInvalidated,
                  selectionGeneration == directAttachmentSelectionGeneration,
                  directPendingAttachments.contains(where: { $0.id == attachment.id }) else {
                throw DirectSessionError.staleOperation
            }

            switch attachment.stageState {
            case .confirmed:
                continue
            case .unknown(let scope):
                // An earlier request may have reached Hermes without a usable
                // receipt. The controller deliberately rejects blind restage.
                throw DirectAttachmentSendFailure.staging(
                    id: attachment.id,
                    filename: attachment.displayFilename,
                    error: .unknown(
                        kind: attachment.source.kind,
                        scope: scope,
                        reason: .priorAttemptUnknown
                    )
                )
            case .pending:
                do {
                    let result = try await controller.stageAttachment(
                        attachment,
                        create: passedCreate ? [:] : create
                    )
                    passedCreate = true
                    guard !directInvalidated,
                          selectionGeneration == directAttachmentSelectionGeneration,
                          let index = directPendingAttachments.firstIndex(where: { $0.id == attachment.id }),
                          case .pending = directPendingAttachments[index].stageState else {
                        throw DirectSessionError.staleOperation
                    }
                    guard directPendingAttachments[index].confirm(
                        scope: result.scope,
                        referenceText: result.receipt.referenceText,
                        serverDetachPaths: result.receipt.detachPaths
                    ) else {
                        throw DirectSessionError.staleOperation
                    }
                    // Preserve a confirmed receipt if cancellation arrived
                    // after the server acknowledged the stage.
                    try Task.checkCancellation()
                } catch let error as DirectGatewayAttachmentStageError {
                    if case .unknown(_, let scope, _) = error,
                       let index = directPendingAttachments.firstIndex(where: { $0.id == attachment.id }),
                       case .pending = directPendingAttachments[index].stageState {
                        _ = directPendingAttachments[index].markUnknown(scope: scope)
                    }
                    throw DirectAttachmentSendFailure.staging(
                        id: attachment.id,
                        filename: attachment.displayFilename,
                        error: error
                    )
                }
            }
        }
    }

    private func applyDirectEvent(
        _ event: HermesGatewayEvent,
        suppressUnwatermarkedContent: Bool = false
    ) {
        if event.type == "status.update",
           event.payload?.gatewayFields["kind"]?.gatewayString == "goal",
           let text = event.payload?.gatewayFields["text"]?.gatewayString,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = "\(event.connectionGeneration.map { String($0) } ?? "none"):\(event.sequence.map { String($0) } ?? "none"):"
                + "\(event.sessionID ?? "none"):goal:\(text)"
            if directGoalStatusEventKeys.insert(key).inserted {
                appendLocalNoticeMessage(text)
            }
        }
        if event.type == "message.start" {
            cancelContextUsageSnapshotTask()
        }
        if !["message.delta", "thinking.delta", "reasoning.delta"].contains(event.type) {
            flushPendingStreamingContent()
        }
        defer {
            // A token is not an ownership transition. Avoid invalidating every
            // sidebar/live-session consumer and rescheduling retention per delta.
            if ["message.start", "message.complete", "error"].contains(event.type) {
                OpenChatSessionStore.shared.noteStreamingStateChanged()
            }
        }
        switch GatewayConversationController.presentationEvent(for: event) {
        case .textDelta(let text):
            guard !suppressUnwatermarkedContent else { break }
            _ = appendAssistantToken(text)
            if showsLiveActivityResponseExcerpts { liveActivityManager.update(.token(text)) }
        case .interim(let text, let alreadyStreamed):
            guard !suppressUnwatermarkedContent else { break }
            _ = appendInterimAssistant(InterimAssistantStreamEvent(text: text, alreadyStreamed: alreadyStreamed))
            if showsLiveActivityResponseExcerpts { liveActivityManager.update(.interimAssistant(text)) }
        case .thinkingDelta(let text), .reasoningDelta(let text):
            guard !suppressUnwatermarkedContent else { break }
            _ = appendReasoning(text)
            liveActivityManager.update(.reasoning(text))
        case .toolStart(let tool):
            _ = appendToolCall(directToolEvent(tool, completed: false))
            liveActivityManager.update(.toolStarted(name: tool.name))
        case .toolComplete(let tool):
            _ = completeToolCall(directToolEvent(tool, completed: true))
            liveActivityManager.update(.toolCompleted)
        case .toolProgress: break // Progress is not a second tool call.
        case .usage(let usage): contextWindowSnapshot = usage
        case .terminal(let terminal):
            flushPendingStreamingContent()
            if !suppressUnwatermarkedContent, let text = terminal.text, !text.isEmpty {
                prepareStreamingAssistantForTerminal(text)
            }
            if !suppressUnwatermarkedContent, let text = terminal.text, !text.isEmpty,
               let messageID = streamingAssistantMessageID,
               let index = streamingAssistantMessagePosition(for: messageID),
               messages[index].role == "assistant" {
                let current = messages[index]
                messages[index] = ChatMessage(role: current.role, content: text,
                    timestamp: current.timestamp, messageId: current.messageId,
                    name: current.name, toolCallId: current.toolCallId, toolUseId: current.toolUseId,
                    toolCalls: current.toolCalls, contentParts: current.contentParts,
                    reasoning: terminal.reasoning ?? current.reasoning, attachments: current.attachments,
                    turnTps: terminal.usage?.tokensPerSecond ?? current.turnTps)
            }
            if let usage = terminal.usage { contextWindowSnapshot = usage }
            directResponseComplete = true
            sealedInterimAssistantMessageIDs.removeAll()
            responseCompletionHapticTrigger += 1
            // Terminal handling is the single completion chokepoint (item 4): the
            // elapsed readout must not survive into an idle composer.
            activeRunStartedAt = nil
            if let terminalError = terminal.error {
                sendErrorMessage = terminalError
            } else if directConversation?.hasAmbiguousPromptDelivery == true {
                sendErrorMessage = promptDeliveryWarning(for: directConversation)
            } else {
                sendErrorMessage = nil
            }
            let cancelled = terminal.status == "cancelled" || terminal.status == "interrupted"
            endDirectLiveActivity(status: terminal.error != nil ? .failed : (cancelled ? .cancelled : .complete),
                activity: cancelled ? "Response stopped" : "Response complete", errorSummary: terminal.error)
        case .control(let raw):
            if raw.type == "message.start" {
                archiveDirectLiveTurnBeforeNewStart()
                isReasoningChangeDeferred = false
                directResponseComplete = false
                // Item 4: the elapsed readout starts when the gateway starts the
                // response, alongside the live-activity run.
                activeRunStartedAt = Date()
                streamingAssistantMessageID = nil
                streamingAssistantMessageIndex = nil
                if let sessionID {
                    // A local activity identity is not a gateway runtime ID.
                    let owner = UUID()
                    directLiveActivityRun = (owner, sessionID, directConversation?.profile ?? "default")
                    liveActivityManager.startDirect(owner: owner, sessionID: sessionID, sessionTitle: displayTitle)
                }
            } else if raw.type == "session.info" {
                applyDirectSessionInfo(raw.payload)
            } else if raw.type == "error" {
                sendErrorMessage = raw.payload?.gatewayFields["message"]?.gatewayString ?? "Hermes reported an error."
            } else if ["approval.request", "sudo.request", "secret.request"].contains(raw.type) {
                // The live controller owns the typed prompt projection. The
                // overlay observes that projection directly; do not route a
                // native request through the legacy HTTP error surface.
            }
        case .unknown: break
        }
    }

    private func endDirectLiveActivity(status: AgentRunActivityStatus, activity: String, errorSummary: String? = nil) {
        guard let ownedRun = directLiveActivityRun,
              ownedRun.sessionID == canonicalSessionID,
              ownedRun.profile == directConversation?.profile else { return }
        directLiveActivityRun = nil
        activeRunStartedAt = nil
        liveActivityManager.endDirect(owner: ownedRun.owner, status: status, activity: activity, errorSummary: errorSummary)
    }

    private func syncDirectClarificationPrompt() {
        guard usesDirectGateway else { return }
        guard let prompt = directConversation?.pendingBlockingPrompt else {
            directClarificationPrompt = nil
            return
        }

        let pending = PendingClarification(
            clarifyId: prompt.identity.requestID,
            question: prompt.kind.isCancelOnly ? prompt.displayQuestion : prompt.question,
            choicesOffered: prompt.kind.isCancelOnly ? [] : prompt.choices,
            sessionId: prompt.identity.storedID,
            kind: prompt.kind.rawValue
        )
        directClarificationPrompt = ClarificationPromptState(
            sessionID: prompt.identity.storedID,
            pending: pending,
            pendingCount: 1,
            gatewayIdentity: prompt.identity,
            gatewayCancelOnly: prompt.kind.isCancelOnly
        )
    }

    private func setDirectClarificationSendError(_ message: String) {
        directClarificationOwnedSendError = message
        sendErrorMessage = message
    }

    private func clearDirectClarificationOwnedSendError() {
        guard let ownedError = directClarificationOwnedSendError else { return }
        if sendErrorMessage == ownedError {
            sendErrorMessage = nil
        }
        directClarificationOwnedSendError = nil
    }

    private func directClarificationMessage(for error: GatewayBlockingError) -> String {
        switch error {
        case .malformedClarification:
            return "Hermes sent a clarification request this app cannot safely display."
        case .unsupportedBatchClarification:
            return "This multi-question clarification can only be cancelled from this app."
        case .unsupportedMultiSelectClarification:
            return "This multi-select clarification can only be cancelled from this app."
        case .noPendingClarification, .staleClarification:
            return "That clarification is no longer active."
        case .invalidClarificationResponse:
            return "This clarification can only be cancelled."
        case .responseInFlight:
            return "A clarification response is already being sent."
        }
    }

    /// A direct session can receive the next turn from another client while the
    /// previous terminal refresh is still in flight (or has failed). Keep the
    /// previous turn's live cards anchored before resetting the streaming row;
    /// otherwise the old state is merged into the new turn or rendered as a
    /// loose bottom card.
    private func archiveDirectLiveTurnBeforeNewStart() {
        guard !liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !liveToolCalls.isEmpty
        else {
            return
        }

        let anchorMessageID = directLiveTurnAnchorMessageID()
        if !directLiveAnchorBelongsToCurrentTurn(reasoningAnchorMessageID) {
            reasoningAnchorMessageID = anchorMessageID
        }
        if !directLiveAnchorBelongsToCurrentTurn(toolCallAnchorMessageID) {
            toolCallAnchorMessageID = anchorMessageID
        }

        archiveLiveReasoningIfNeeded()
        archiveLiveToolCallsIfNeeded()
        liveReasoningText = ""
        liveToolCalls = []
        reasoningAnchorMessageID = nil
        toolCallAnchorMessageID = nil
    }

    private func directLiveTurnAnchorMessageID() -> String {
        let currentTurnAnchors = TranscriptTurnClassifier.currentTurnAssistantAnchorIDs(
            in: messages,
            messageOffset: messagesOffset
        )
        if let streamingAssistantMessageID,
           messages.contains(where: { message in
               message.role == "assistant" && message.messageId == streamingAssistantMessageID
           }), currentTurnAnchors.contains(streamingAssistantMessageID) {
            return streamingAssistantMessageID
        }

        if let currentTurnAnchor = currentTurnAnchors.last {
            return currentTurnAnchor
        }

        // Direct live cards are normally created with an assistant row first.
        // If a reconnect/cache transition left that row unavailable, create a
        // concrete row before archiving so the old cards cannot become loose
        // bottom groups.
        streamingAssistantMessageID = nil
        streamingAssistantMessageIndex = nil
        return ensureStreamingAssistantMessage()
    }

    private func directLiveAnchorBelongsToCurrentTurn(_ anchorMessageID: String?) -> Bool {
        guard let anchorMessageID else { return false }
        return TranscriptTurnClassifier.currentTurnAssistantAnchorIDs(
            in: messages,
            messageOffset: messagesOffset
        ).contains(anchorMessageID)
    }

    private func directToolEvent(_ tool: GatewayConversationController.PresentationTool, completed: Bool) -> ToolStreamEvent {
        let resultText: String?
        if case .string(let text) = tool.result { resultText = text }
        else if let result = tool.result, let data = try? JSONEncoder().encode(result) { resultText = String(data: data, encoding: .utf8) }
        else { resultText = nil }
        return ToolStreamEvent(eventType: completed ? "tool_complete" : "tool_start", name: tool.name,
            preview: tool.error ?? tool.summary ?? resultText, args: tool.args, duration: tool.duration,
            isError: tool.error != nil, stableID: tool.toolID)
    }

    func setShowsLiveActivityResponseExcerpts(_ shows: Bool) {
        guard showsLiveActivityResponseExcerpts != shows else { return }

        showsLiveActivityResponseExcerpts = shows
        if !shows { liveActivityManager.update(.clearResponseExcerpt) }
    }

    var showsListenPlaybackBar: Bool {
        listenPlaybackPhase != .idle
    }

    var listenPlaybackDisplayTime: TimeInterval {
        listenPlaybackScrubTime ?? listenPlaybackElapsedTime
    }

    /// Chat visibility controls reconciliation on the shared direct gateway.
    /// Merely becoming visible does not create a runtime or open a second stream.
    func startSessionEventSync() {
        directVisible = true
        directConversation?.isVisible = true
    }

    func stopSessionEventSync() {
        directVisible = false
        directConversation?.isVisible = false
    }

    func markReusedFromOpenSessionStore() {
        wasReusedFromOpenSessionStore = true
    }

    func rememberTranscriptRestorePoint(followingLatest: Bool, visibleMessageID: String?) {
        savedFollowingLatest = followingLatest
        savedVisibleMessageID = followingLatest ? nil : visibleMessageID
        restoreStore.save(
            TranscriptRestorePoint(
                followingLatest: savedFollowingLatest,
                visibleMessageID: savedVisibleMessageID
            ),
            server: server,
            sessionID: sessionID ?? ""
        )
    }

    func markConversationConnectionInProgress() {
        beginConnectionWaitIfNeeded()
    }

    func markConnectionVisiblySlowForTesting() {
        isConnectionVisiblySlow = true
    }

    private func beginConnectionWaitIfNeeded() {
        if hasPreservedTranscript || activeStreamID != nil {
            return
        }
        isLoading = true
        guard connectionVisibilityTask == nil else { return }

        isConnectionVisiblySlow = false
        connectionVisibilityTask = Task { @MainActor [weak self] in
            let delay = UInt64(ChatConnectionStatusPolicy.visibleDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.connectionVisibilityTask = nil
            if self.isLoading {
                self.isConnectionVisiblySlow = true
            }
        }
    }

    private func endConnectionWait() {
        connectionVisibilityTask?.cancel()
        connectionVisibilityTask = nil
        isConnectionVisiblySlow = false
        isLoading = false
    }

    var selectedModelID: String? {
        currentModel
    }

    var selectedModelProviderID: String? {
        currentModelProvider
    }

    var selectedWorkspacePath: String? {
        currentWorkspace
    }

    var workspaceOrganizerProfile: String { requestProfileName ?? "default" }

    var selectedProfileTitle: String {
        let profileName = selectedProfileName ?? currentProfile
        guard let profileName, !profileName.isEmpty else {
            return String(localized: "Profile")
        }

        if let option = profileOptions.first(where: { $0.name == profileName }) {
            return option.displayName
        }

        return profileName == "default" ? String(localized: "Default") : profileName
    }

    var selectedModelTitle: String {
        guard let currentModel, !currentModel.isEmpty else {
            return String(localized: "Model")
        }

        let catalogName = modelCatalogGroups
            .flatMap(\.models)
            .firstMatchingSelection(modelID: currentModel, providerID: currentModelProvider)?
            .displayName

        return catalogName ?? Self.compactModelTitle(currentModel)
    }

    func isSelectedProfile(_ profile: ProfileSummary) -> Bool {
        guard let profileName = profile.normalizedName else { return false }
        return profileName == (Self.nonEmpty(selectedProfileName) ?? Self.nonEmpty(currentProfile))
    }

    var hasStreamingAssistantMessageContent: Bool {
        guard let streamingAssistantMessageID,
              let index = streamingAssistantMessagePosition(for: streamingAssistantMessageID),
              messages.indices.contains(index)
        else { return false }

        let message = messages[index]
        return message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func scheduleStreamingScrollTrigger() {
        guard isTranscriptPresentationActive else { return }
        guard pendingStreamingScrollTriggerTask == nil else { return }

        let expectedSessionID = sessionID
        let delay = streamingScrollCoalescingDelayNanoseconds
        pendingStreamingScrollTriggerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }

            self.pendingStreamingScrollTriggerTask = nil
            guard !Task.isCancelled, self.sessionID == expectedSessionID else { return }

            self.streamingScrollTrigger += 1
        }
    }

    private func cancelPendingStreamingScrollTrigger() {
        pendingStreamingScrollTriggerTask?.cancel()
        pendingStreamingScrollTriggerTask = nil
    }

    private func scheduleStreamingContentFlush(afterNanoseconds delay: UInt64? = nil) {
        guard isTranscriptPresentationActive else { return }
        guard pendingStreamingContentFlushTask == nil else { return }

        let expectedSessionID = sessionID
        let resolvedDelay = delay ?? streamingScrollCoalescingDelayNanoseconds
        pendingStreamingContentFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: resolvedDelay)
            guard let self else { return }

            self.pendingStreamingContentFlushTask = nil
            guard !Task.isCancelled, self.sessionID == expectedSessionID else { return }

            self.drainStreamingContentTick()
        }
    }

    /// One paced flush tick: drains a word-cadence quota of buffered assistant
    /// text (reasoning still flushes whole — pacing applies to assistant content
    /// only) and reschedules itself at the word cadence while a backlog remains.
    /// Completion paths (done/cancel/error/interim/snapshot) bypass pacing via
    /// `flushPendingStreamingContent()`, which cancels any scheduled tick.
    private func drainStreamingContentTick() {
        guard isTranscriptPresentationActive else { return }
        var didMutate = false
        let quota = StreamingWordDrain.drainQuota(
            backlogUnitCount: StreamingWordDrain.unitCount(in: pendingAssistantTextBuffer),
            cadenceNanoseconds: streamingWordRevealCadenceNanoseconds,
            maxLagNanoseconds: streamingMaxRevealLagNanoseconds
        )
        if flushAssistantTokens(maxWordUnits: quota) {
            didMutate = true
        }
        if flushReasoningChunks() {
            didMutate = true
        }

        if didMutate, ChatScrollPolicy.shouldBumpScrollTriggerForStreamingFlush() {
            scheduleStreamingScrollTrigger()
        }

        if !pendingAssistantTextBuffer.isEmpty {
            scheduleStreamingContentFlush(afterNanoseconds: streamingWordRevealCadenceNanoseconds)
        }
    }

    private func cancelPendingStreamingContentFlush() {
        pendingStreamingContentFlushTask?.cancel()
        pendingStreamingContentFlushTask = nil
    }

    /// Keep the session-owned transport alive while preventing an offscreen or
    /// background transcript from doing word-cadence state/layout work. The
    /// accumulated tail is presented immediately when the conversation returns.
    func setTranscriptPresentationActive(_ isActive: Bool) {
        guard isTranscriptPresentationActive != isActive else { return }
        isTranscriptPresentationActive = isActive

        if isActive {
            if !pendingAssistantTextBuffer.isEmpty || !pendingReasoningTextBuffer.isEmpty {
                scheduleStreamingContentFlush(afterNanoseconds: 0)
            }
        } else {
            cancelPendingStreamingContentFlush()
            cancelPendingStreamingScrollTrigger()
        }
    }

    private func resetPendingStreamingContentBuffers() {
        cancelPendingStreamingContentFlush()
        pendingAssistantTextBuffer = ""
        pendingReasoningTextBuffer = ""
    }

    func flushPendingStreamingContent() {
        cancelPendingStreamingContentFlush()

        var didMutate = false
        if flushAssistantTokens() {
            didMutate = true
        }
        if flushReasoningChunks() {
            didMutate = true
        }

        if didMutate, ChatScrollPolicy.shouldBumpScrollTriggerForStreamingFlush() {
            scheduleStreamingScrollTrigger()
        }
    }

    private var requestProfileName: String? {
        Self.nonEmpty(selectedProfileName) ?? Self.nonEmpty(currentProfile)
    }

    var voiceInputProfileName: String { requestProfileName ?? "default" }

    /// The canonical Hermes session ID is the server-provided `session_id`.
    /// `SessionSummary.id` may be a local synthetic fallback and must never be
    /// sent as a session-scoped reasoning identity.
    private var canonicalSessionID: String? {
        Self.nonEmpty(sessionID)
    }

    func loadComposerConfiguration() async {
        await loadDirectComposerConfiguration()
    }

    /// Refreshes the direct Hermes inventory when a picker opens.
    func refreshModelCatalogForPickerOpen() async {
        await loadDirectComposerConfiguration()
    }
    @discardableResult
    func selectComposerModel(_ option: ModelCatalogOption) async -> Bool {
        guard canConfigureDirectDraft(),
              modelCatalogGroups.flatMap(\.models).contains(option),
              !option.matchesSelection(modelID: currentModel, providerID: currentModelProvider) else {
            return false
        }
        composerConfigurationMutationToken &+= 1
        currentModel = option.id
        currentModelProvider = option.providerID
        sessionReasoningEffort = nil
        selectedReasoningEffort = nil
        applyDirectReasoningGating()
        return true
    }

    /// Reloads device-local workspace bookmarks after manager changes.
    func refreshWorkspaceRoots() async {
        workspaceRoots = []
        workspaceSuggestions = []
        do {
            workspaceRoots = try localOrganizerStore.workspaceBookmarks(
                server: server, profile: workspaceOrganizerProfile
            ).map { WorkspaceRoot(path: $0.path, name: $0.name) }
            workspaceSuggestions = workspaceRoots.compactMap(\.path)
        } catch {
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
        }
    }

    func loadWorkspaceSuggestions(prefix: String) async {
        let value = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaceSuggestions = workspaceRoots.compactMap(\.path).filter {
            value.isEmpty || $0.localizedCaseInsensitiveContains(value)
        }
    }

    func loadSkillSlashSuggestions() async {
        guard usesDirectGateway else { return }
        guard !isLoadingSkillSlashSuggestions else { return }

        isLoadingSkillSlashSuggestions = true
        defer { isLoadingSkillSlashSuggestions = false }

        do {
            let controller = try await ensureDirectConversation()
            _ = try await directSkillSuggestions(controller: controller, profile: controller.profile,
                origin: controller.sharedRuntime.origin)
        } catch {
            guard !Task.isCancelled, !directInvalidated,
                  (error as? DirectSessionError) != .staleOperation else { return }
            lastError = error
        }
    }

    @discardableResult
    func selectWorkspacePath(_ path: String) async -> Bool {
        let workspace = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else { return false }
        guard canConfigureDirectDraft(), workspace != currentWorkspace else { return false }
        composerConfigurationMutationToken &+= 1
        currentWorkspace = workspace
        return true
    }

    func switchProfile(_ profile: ProfileSummary, startNewSession: Bool) async -> ProfileSwitchOutcome? {
        guard !directInvalidated, !isViewingCachedData, !isUpdatingComposerConfiguration,
              activeStreamID == nil, let name = profile.normalizedName else { return nil }
        // A profile owns a different durable namespace. Return a new local
        // draft; never retarget this controller or change the host profile.
        guard startNewSession else {
            composerConfigurationErrorMessage = "Choose New Chat to use a different Hermes profile."
            return nil
        }
        return ProfileSwitchOutcome(
            session: SessionSummary(
                title: "New Chat",
                createdAt: Date().timeIntervalSince1970,
                profile: name
            )
        )
    }

    @discardableResult
    func selectReasoningEffort(_ effort: String) async -> Bool {
        let selectedEffort = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedEffort.isEmpty else { return false }
        if canonicalSessionID != nil {
            return await selectDirectSessionReasoning(selectedEffort.lowercased())
        }
        guard canConfigureDirectDraft() else { return false }
        let normalized = selectedEffort.lowercased()
        guard normalized == ReasoningEffortOption.inheritID ||
                (supportsReasoningEffort == true && supportedReasoningEfforts?.contains(normalized) == true) else {
            return false
        }
        composerConfigurationMutationToken &+= 1
        sessionScopedReasoning = true
        sessionReasoningEffort = normalized == ReasoningEffortOption.inheritID ? nil : normalized
        selectedReasoningEffort = sessionReasoningEffort
        return true
    }

    func uploadAttachment(data: Data, filename: String, previewData: Data? = nil) async {
        guard usesDirectGateway else {
            directAttachmentPreparationErrorMessage = "Direct Hermes connection is unavailable. The attachment was not uploaded."
            return
        }
        guard !directInvalidated, !isStartingChat else {
            directAttachmentPreparationErrorMessage = "Wait for the current direct message to finish before adding an attachment."
            return
        }
        guard !attachmentRecoveryNeedsReset, !attachmentRecoveryIsBusy else { return }

        let generation = directAttachmentSelectionGeneration
        directAttachmentPreparationStartGeneration &+= 1
        directAttachmentPreparationCount += 1
        isPreparingDirectAttachment = true
        directAttachmentPreparationErrorMessage = nil
        defer {
            if generation == directAttachmentSelectionGeneration {
                directAttachmentPreparationCount = max(0, directAttachmentPreparationCount - 1)
                isPreparingDirectAttachment = directAttachmentPreparationCount > 0
            }
        }

        let preparation: Task<DirectPendingAttachment, Error>
        if let directAttachmentPreparer {
            preparation = Task {
                try await directAttachmentPreparer(data, filename, previewData)
            }
        } else {
            preparation = Task.detached(priority: .utility) {
                () throws -> DirectPendingAttachment in
                try Task.checkCancellation()
                let source = try DirectGatewayAttachment(data: data, filename: filename)
                try Task.checkCancellation()
                let thumbnail: Data?
                if source.kind == .image {
                    thumbnail = ImagePreviewDownsampler.previewData(
                        from: previewData ?? data,
                        maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
                    )
                } else {
                    thumbnail = previewData
                }
                try Task.checkCancellation()
                return DirectPendingAttachment(source: source, thumbnailData: thumbnail)
            }
        }

        do {
            let pending = try await withTaskCancellationHandler(operation: {
                try await preparation.value
            }, onCancel: {
                preparation.cancel()
            })
            try Task.checkCancellation()
            guard generation == directAttachmentSelectionGeneration, !directInvalidated else { return }
            directPendingAttachments.append(pending)
        } catch is CancellationError {
            // Caller cancellation is transient and must not erase earlier files.
        } catch {
            guard generation == directAttachmentSelectionGeneration, !directInvalidated else { return }
            directAttachmentPreparationErrorMessage = directAttachmentPreparationMessage(for: error)
        }
    }

    func clearPendingAttachments() {
        if usesDirectGateway {
            guard !isStartingChat, !attachmentRecoveryNeedsReset, !attachmentRecoveryIsBusy else {
                directAttachmentPreparationErrorMessage = "Wait for the current direct message to finish before changing attachments."
                return
            }
            clearDirectPendingAttachments()
        } else {
            attachmentCoordinator.clearPendingAttachments()
        }
    }

    func removePendingAttachment(id: UUID) {
        if usesDirectGateway {
            guard !isStartingChat, !attachmentRecoveryIsBusy else {
                directAttachmentPreparationErrorMessage = "Wait for the current direct message to finish before changing attachments."
                return
            }
            guard let index = directPendingAttachments.firstIndex(where: { $0.id == id }) else { return }
            let attachment = directPendingAttachments[index]
            switch attachment.stageState {
            case .pending:
                guard !attachmentRecoveryNeedsReset else { return }
                directPendingAttachments.remove(at: index)
                directAttachmentPreparationErrorMessage = nil
            case .unknown:
                // An unknown server receipt is never guessed or removed by a
                // local chip action; the explicit recovery reset owns it.
                return
            case .confirmed:
                if attachment.isGenericFile {
                    guard directConversation?.runState == nil || directConversation?.runState == .idle else {
                        directAttachmentPreparationErrorMessage = "Wait for the current direct message to finish before changing attachments."
                        return
                    }
                    // The stock contract has no file.detach route. A confirmed
                    // file receipt is therefore only a local composer item;
                    // remove its chip without inventing a server cleanup RPC.
                    removeDirectPendingAttachments(ids: [id])
                    directAttachmentPreparationErrorMessage = nil
                    return
                }
                guard let controller = directConversation else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await controller.removeStagedAttachment(attachment)
                        guard !self.directInvalidated,
                              self.directConversation === controller,
                              self.directPendingAttachments.contains(where: { $0.id == id }) else {
                            return
                        }
                        self.removeDirectPendingAttachments(ids: [id])
                        self.attachmentRecoveryErrorMessage = nil
                    } catch {
                        guard !self.directInvalidated,
                              self.directConversation === controller else { return }
                        self.lastError = error
                        self.attachmentRecoveryErrorMessage = "The attachment could not be removed. It was kept safely; try again or reset the pending upload."
                    }
                }
            }
        } else {
            attachmentCoordinator.removePendingAttachment(id: id)
        }
    }

    /// Clears only the unresolved direct-attachment marker after the user has
    /// explicitly confirmed the affected live chat reset. The draft and saved
    /// transcript are intentionally untouched; local staged bytes are dropped
    /// only after the controller confirms the marker reset.
    func resetDirectAttachmentRecovery(_ target: DirectAttachmentRecoveryTarget) async -> Bool {
        guard usesDirectGateway,
              !directInvalidated,
              target.server == server,
              target.sessionID == canonicalSessionID,
              let controller = directConversation,
              controller.attachmentRecoveryNeedsReset,
              controller.storedID == target.sessionID,
              controller.profile == target.profile,
              controller.binding?.runtimeID == target.runtimeID,
              controller.unresolvedAttachmentMarkerToken == target.markerToken else {
            return false
        }

        attachmentRecoveryErrorMessage = nil

        do {
            try await controller.resetPendingAttachments(expectedToken: target.markerToken)
            guard !directInvalidated,
                  directConversation === controller,
                  target.server == server,
                  target.sessionID == canonicalSessionID,
                  controller.storedID == target.sessionID,
                  controller.profile == target.profile,
                  controller.attachmentRecoveryNeedsReset == false else {
                return false
            }
            discardDirectPendingAttachmentsAfterRecoveryReset()
            attachmentRecoveryErrorMessage = nil
            return true
        } catch {
            lastError = error
            attachmentRecoveryErrorMessage = String(localized: "The pending upload could not be reset. Saved chat history was kept; try again.")
            return false
        }
    }

    /// After explicit confirmation, refreshes the canonical conversation and
    /// removes only the matching local uncertainty barrier. It never resends the
    /// prior prompt, changes the draft, closes the runtime, or mutates history.
    func abandonDirectPromptDeliveryUncertainty(_ target: DirectPromptDeliveryRecoveryTarget) async -> Bool {
        guard usesDirectGateway,
              !directInvalidated,
              !promptDeliveryRecoveryIsBusy,
              target.server == server,
              target.sessionID == canonicalSessionID,
              let controller = directConversation,
              controller.storedID == target.sessionID,
              controller.profile == target.profile,
              controller.promptDeliveryUncertaintyToken == target.markerToken else {
            return false
        }

        promptDeliveryRecoveryIsBusy = true
        defer { promptDeliveryRecoveryIsBusy = false }
        do {
            try await controller.abandonPromptDeliveryUncertainty(expectedToken: target.markerToken)
            guard !directInvalidated,
                  directConversation === controller,
                  target.server == server,
                  target.sessionID == canonicalSessionID,
                  controller.storedID == target.sessionID,
                  controller.profile == target.profile,
                  controller.hasAmbiguousPromptDelivery == false else {
                return false
            }
            if sendErrorMessage == Self.directAmbiguousPromptDeliveryMessage
                || sendErrorMessage == Self.directConfirmedPromptCleanupMessage
                || sendErrorMessage == Self.directPromptRecoveryFailureMessage {
                sendErrorMessage = nil
            }
            return true
        } catch {
            guard !directInvalidated, directConversation === controller else { return false }
            lastError = error
            sendErrorMessage = Self.directPromptRecoveryFailureMessage
            return false
        }
    }

    private func removeDirectPendingAttachments(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        directAttachmentSelectionGeneration &+= 1
        directPendingAttachments.removeAll { ids.contains($0.id) }
    }

    private func clearDirectPendingAttachments() {
        directAttachmentSelectionGeneration &+= 1
        directAttachmentPreparationCount = 0
        isPreparingDirectAttachment = false
        directAttachmentPreparationErrorMessage = nil
        directPendingAttachments.removeAll { attachment in
            if case .pending = attachment.stageState { return true }
            return false
        }
    }

    private func discardDirectPendingAttachmentsAfterRecoveryReset() {
        directAttachmentSelectionGeneration &+= 1
        directAttachmentPreparationCount = 0
        isPreparingDirectAttachment = false
        directAttachmentPreparationErrorMessage = nil
        directPendingAttachments.removeAll()
    }

    private func directAttachmentPreparationMessage(for error: Error) -> String {
        guard let attachmentError = error as? DirectGatewayAttachmentError else {
            return "The attachment could not be prepared."
        }
        switch attachmentError {
        case .empty:
            return "The attachment is empty."
        case .malformed:
            return "The attachment could not be validated."
        case .unsupportedType, .unsupportedImageExtension:
            return "This attachment type is not supported."
        case .tooLarge:
            return "This attachment is too large."
        }
    }

    func setUploadAttachmentError(_ message: String?) {
        directAttachmentPreparationErrorMessage = message
    }

    func attachmentImageData(path: String) async -> Data? {
        if usesDirectGateway {
            guard !directInvalidated, let expectedSessionID = canonicalSessionID else { return nil }
            do {
                let data = try await client.directReadManagedFile(path: path).data
                guard !directInvalidated, expectedSessionID == canonicalSessionID else { return nil }
                let preview = await ImagePreviewDownsampler.previewDataAsync(
                    from: data,
                    maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
                )
                guard !directInvalidated, expectedSessionID == canonicalSessionID else { return nil }
                return preview
            } catch {
                return nil
            }
        }
        return nil
    }

    func attachmentRawData(path: String) async -> Data? {
        if usesDirectGateway {
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedPath.hasPrefix("/"), !directInvalidated,
                  let expectedSessionID = canonicalSessionID else { return nil }
            let expectedProfile = directConversation?.profile
                ?? (Self.nonEmpty(currentProfile) ?? "default")
            let expectedController = directConversation
            do {
                let data = try await client.directReadManagedFile(
                    path: trimmedPath,
                    maximumBytes: APIClient.maximumTranscriptionBytes
                ).data
                let currentProfile = directConversation?.profile
                    ?? (Self.nonEmpty(self.currentProfile) ?? "default")
                guard !directInvalidated, expectedSessionID == canonicalSessionID,
                      expectedProfile == currentProfile,
                      directConversation === expectedController else { return nil }
                return data
            } catch {
                return nil
            }
        }
        return nil
    }

    func transcriptMediaThumbnailData(for reference: TranscriptMediaReference) async -> Data? {
        await attachmentCoordinator.transcriptMediaThumbnailData(for: reference)
    }

    func transcriptMediaData(for reference: TranscriptMediaReference) async -> Data? {
        await attachmentCoordinator.transcriptMediaData(for: reference)
    }

    func loadMessages(
        modelContext: ModelContext? = nil,
        allowApplyDuringLocalStart: Bool = false
    ) async {
        await loadDirectMessages(modelContext: modelContext)
    }

    /// Performs only the fast, local portion of an existing session's first
    /// load. The network reconcile is intentionally started by `ChatView` after
    /// its navigation appearance completes so rendering a richer transcript
    /// cannot stall the system push animation.
    func prepareInitialMessageLoad(modelContext: ModelContext) {
        guard let sessionID else { return }
        guard messages.isEmpty else { return }

        _ = renderCachedMessagesBeforeReload(
            sessionID: sessionID,
            modelContext: modelContext
        )
        if messages.isEmpty {
            beginConnectionWaitIfNeeded()
        }
    }

    /// Cache-first render (#289): on a cold session open, paint the cached transcript
    /// immediately so the loading skeleton never appears, then let the in-flight
    /// `loadMessages` network reload reconcile silently in place. Keeps
    /// `isViewingCachedData` off because this is the success-expected window, not an
    /// offline failure — the offline indicator stays tied to a real network error.
    /// Returns the cached messages it rendered (empty if nothing was cached), so the
    /// caller can revert the placeholder if the reload surfaces an error instead of
    /// content — but only while the transcript is still that exact placeholder.
    private func renderCachedMessagesBeforeReload(
        sessionID: String,
        modelContext: ModelContext
    ) -> [ChatMessage] {
        let cachedMessages: [ChatMessage]
        do {
            cachedMessages = try CacheStore.cachedMessages(
                serverURL: server,
                sessionID: transcriptCacheID(sessionID),
                in: modelContext,
                limit: Self.messagePageLimit
            )
        } catch {
            // A cache read failure must not block the normal network load; fall back
            // to the existing skeleton-until-network behavior.
            return []
        }

        guard !cachedMessages.isEmpty else { return [] }

        if cacheFirstMessagePlaceholder == nil {
            messagesBeforeCacheFirstPlaceholder = messages
            messagesOffsetBeforeCacheFirstPlaceholder = messagesOffset
        }
        withBatchedTranscriptDerivedState {
            messages = cachedMessages
            messagesOffset = 0
        }
        hasOlderMessages = false
        isViewingCachedData = false
        cacheFirstMessagePlaceholder = cachedMessages
        return cachedMessages
    }

    /// Undo a cache-first placeholder (#289) when the reload fails without adopting
    /// the offline cache, so the existing error UI (empty transcript + message) shows
    /// instead of a stale cached transcript masquerading as live.
    private func revertCacheFirstPlaceholderIfNeeded() {
        defer { clearCacheFirstMessagePlaceholder() }
        // Only undo the cache-first paint if nothing mutated the transcript since the
        // prime (e.g. an optimistic send during the load window) — otherwise we'd wipe
        // in-flight local content while its send/stream is still running.
        guard let cacheFirstMessagePlaceholder,
              messages == cacheFirstMessagePlaceholder
        else { return }
        withBatchedTranscriptDerivedState {
            messages = messagesBeforeCacheFirstPlaceholder
            messagesOffset = messagesOffsetBeforeCacheFirstPlaceholder
        }
        hasOlderMessages = messagesOffsetBeforeCacheFirstPlaceholder > 0
    }

    private func clearCacheFirstMessagePlaceholder() {
        cacheFirstMessagePlaceholder = nil
        messagesBeforeCacheFirstPlaceholder = []
        messagesOffsetBeforeCacheFirstPlaceholder = 0
    }

    @discardableResult
    func loadOlderMessages(modelContext: ModelContext? = nil) async -> Bool {
        await loadOlderDirectMessages(modelContext: modelContext)
    }

    func actionContext(for message: ChatMessage, visibleIndex: Int) -> MessageActionContext? {
        MessageActionContext(
            message: message,
            visibleIndex: visibleIndex,
            messagesOffset: messagesOffset
        )
    }

    nonisolated static func precedingUserMessageText(
        in messages: [ChatMessage],
        beforeVisibleIndex visibleIndex: Int
    ) -> String? {
        guard !messages.isEmpty, visibleIndex > 0 else { return nil }

        let startIndex = min(visibleIndex - 1, messages.count - 1)
        guard startIndex >= 0 else { return nil }

        for index in stride(from: startIndex, through: 0, by: -1) {
            let message = messages[index]
            guard message.role == "user" else { continue }

            let text = message.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty {
                return text
            }
        }

        return nil
    }

    nonisolated static func mergingLoadedMessages(
        _ loadedMessages: [ChatMessage],
        withCachedLocalOptimisticMessages cachedMessages: [ChatMessage]
    ) -> [ChatMessage] {
        let localUserMessages = cachedMessages.filter { cachedMessage in
            isLocalOptimisticUserMessage(cachedMessage)
                && !loadedMessagesContainEquivalentUserMessage(loadedMessages, localMessage: cachedMessage)
        }

        guard !localUserMessages.isEmpty else {
            return loadedMessages
        }

        return localUserMessages.reduce(into: loadedMessages) { partialMessages, localMessage in
            insertLocalOptimisticMessage(localMessage, into: &partialMessages)
        }
    }

    nonisolated private static func prependingOlderMessages(
        _ olderMessages: [ChatMessage],
        to currentMessages: [ChatMessage]
    ) -> [ChatMessage] {
        guard !olderMessages.isEmpty else { return currentMessages }

        var seenIDs = Set(currentMessages.map(\.id))
        var uniqueOlderMessages: [ChatMessage] = []
        uniqueOlderMessages.reserveCapacity(olderMessages.count)

        for message in olderMessages {
            guard seenIDs.insert(message.id).inserted else { continue }
            uniqueOlderMessages.append(message)
        }

        return uniqueOlderMessages + currentMessages
    }

    private func applyReloadedMessages(
        _ reloadedMessages: [ChatMessage],
        from session: SessionDetail?,
        previousMessages: [ChatMessage],
        previousMessagesOffset: Int
    ) {
        let reloadedMessagesOffset = Self.resolvedMessagesOffset(
            from: session,
            loadedMessageCount: reloadedMessages.count
        )

        if let expandedMessages = Self.mergingReloadedMessages(
            reloadedMessages,
            intoCurrentMessages: previousMessages,
            currentMessagesOffset: previousMessagesOffset,
            reloadedMessagesOffset: reloadedMessagesOffset
        ) {
            withBatchedTranscriptDerivedState {
                messages = expandedMessages
                messagesOffset = previousMessagesOffset
            }
            hasOlderMessages = previousMessagesOffset > 0
            return
        }

        withBatchedTranscriptDerivedState {
            messages = reloadedMessages
            updateOlderMessagePagination(from: session, loadedMessageCount: reloadedMessages.count)
        }
    }

    nonisolated private static func mergingReloadedMessages(
        _ reloadedMessages: [ChatMessage],
        intoCurrentMessages currentMessages: [ChatMessage],
        currentMessagesOffset: Int,
        reloadedMessagesOffset: Int
    ) -> [ChatMessage]? {
        guard currentMessagesOffset < reloadedMessagesOffset,
              let firstReloadedMessage = reloadedMessages.first,
              let overlapIndex = currentMessages.firstIndex(where: { $0.id == firstReloadedMessage.id }),
              overlapIndex > currentMessages.startIndex
        else {
            return nil
        }

        return Array(currentMessages[..<overlapIndex]) + reloadedMessages
    }

    private func updateOlderMessagePagination(from session: SessionDetail?, loadedMessageCount: Int) {
        let resolvedOffset = Self.resolvedMessagesOffset(
            from: session,
            loadedMessageCount: loadedMessageCount
        )
        messagesOffset = resolvedOffset
        hasOlderMessages = resolvedOffset > 0 || session?.messagesTruncated == true
    }

    nonisolated private static func resolvedMessagesOffset(
        from session: SessionDetail?,
        loadedMessageCount: Int
    ) -> Int {
        if let messagesOffset = session?.messagesOffset {
            return max(0, messagesOffset)
        }

        guard session?.messagesTruncated == true,
              let messageCount = session?.messageCount
        else {
            return 0
        }

        return max(0, messageCount - loadedMessageCount)
    }

    nonisolated private static func hasAssistantResponseAfterLatestUser(in messages: [ChatMessage]) -> Bool {
        guard !messages.isEmpty else { return false }

        let searchRange: Range<Int>
        if let latestUserIndex = messages.lastIndex(where: { $0.role == "user" }) {
            searchRange = messages.index(after: latestUserIndex)..<messages.endIndex
        } else {
            searchRange = messages.startIndex..<messages.endIndex
        }

        return messages[searchRange].contains { message in
            guard message.role == "assistant" else { return false }
            return hasAssistantResponseContent(message)
        }
    }

    nonisolated private static func hasAssistantResponseContent(_ message: ChatMessage) -> Bool {
        if message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }

        if message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }

        if message.toolCalls?.isEmpty == false {
            return true
        }

        return hasAssistantContentParts(message.contentParts)
    }

    nonisolated private static func hasAssistantContentParts(_ parts: [JSONValue]?) -> Bool {
        guard let parts else { return false }

        return parts.contains { part in
            switch part {
            case .string(let value):
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            case .object(let object):
                if case .string(let type)? = object["type"] {
                    switch type {
                    case "tool_use", "thinking", "reasoning", "redacted_thinking":
                        return true
                    case "text":
                        if case .string(let text)? = object["text"] {
                            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        }
                    default:
                        break
                    }
                }

                return false
            case .number, .bool, .array, .null:
                return false
            }
        }
    }

    nonisolated private static func isLocalOptimisticUserMessage(_ message: ChatMessage) -> Bool {
        message.role == "user" && message.messageId?.hasPrefix("local-") == true
    }

    nonisolated private static func loadedMessagesContainEquivalentUserMessage(
        _ loadedMessages: [ChatMessage],
        localMessage: ChatMessage
    ) -> Bool {
        let localContent = normalizedUserMessageContent(localMessage.content)
        let localAttachmentKeys = attachmentKeys(for: localMessage)

        return loadedMessages.contains { loadedMessage in
            guard loadedMessage.role == "user" else { return false }

            if loadedMessage.messageId == localMessage.messageId {
                return true
            }

            guard normalizedUserMessageContent(loadedMessage.content) == localContent else {
                return false
            }

            if !localAttachmentKeys.isEmpty {
                let loadedAttachmentKeys = attachmentKeys(for: loadedMessage)
                guard !loadedAttachmentKeys.isEmpty,
                      loadedAttachmentKeys.isSuperset(of: localAttachmentKeys)
                else {
                    return false
                }
            }

            guard let localTimestamp = localMessage.timestamp,
                  let loadedTimestamp = loadedMessage.timestamp
            else {
                return true
            }

            return loadedTimestamp >= localTimestamp - 300
        }
    }

    nonisolated private static func insertLocalOptimisticMessage(
        _ localMessage: ChatMessage,
        into messages: inout [ChatMessage]
    ) {
        if !messages.contains(where: { $0.role == "user" }),
           let firstAssistantIndex = messages.firstIndex(where: { $0.role == "assistant" }) {
            messages.insert(localMessage, at: firstAssistantIndex)
            return
        }

        guard let localTimestamp = localMessage.timestamp,
              let insertionIndex = messages.firstIndex(where: { loadedMessage in
                  guard let loadedTimestamp = loadedMessage.timestamp else { return false }
                  return loadedTimestamp > localTimestamp
              })
        else {
            messages.append(localMessage)
            return
        }

        messages.insert(localMessage, at: insertionIndex)
    }

    nonisolated private static func latestAssistantAnchorID(in messages: [ChatMessage], messageOffset: Int?) -> String? {
        guard let index = messages.lastIndex(where: { $0.role == "assistant" }) else {
            return nil
        }

        return TranscriptTurnClassifier.anchorID(
            for: messages[index],
            at: index,
            messageOffset: messageOffset
        )
    }

    nonisolated static func deduplicatedReasoningTexts(_ texts: [String]) -> [String] {
        var seen: Set<String> = []

        return texts.compactMap { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let key = trimmed
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    nonisolated private static func normalizedUserMessageContent(_ content: String?) -> String {
        guard let content else { return "" }

        // Share the single marker parser with the display layer so the two can
        // never disagree about what counts as an attachment marker. Trim the
        // result because this normalized form is compared for dedup equality.
        return MessageAttachment
            .contentWithoutAttachedFilesMarker(in: content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func attachmentKeys(for message: ChatMessage) -> Set<String> {
        // Match on `MessageAttachment.identityKey` (lowercased basename): the
        // server returns attachment paths inconsistently on reload, so basename
        // matching is the only reliable way to dedupe an optimistic bubble
        // against its reloaded copy. See `identityKey` for the full rationale.
        Set((message.attachments ?? []).compactMap(\.identityKey))
    }

    func sendMessage(_ draft: String, modelContext: ModelContext? = nil) async -> Bool {
        guard usesDirectGateway else {
            sendErrorMessage = "Direct Hermes connection is unavailable."
            return false
        }
        guard !isSendingVoiceNote else { return false }
        return await sendDirectMessage(draft, modelContext: modelContext)
    }

    @discardableResult
    func sendVoiceNote(audioData: Data, filename: String, modelContext: ModelContext? = nil) async -> Bool {
        guard usesDirectGateway, !audioData.isEmpty, !isSendingVoiceNote,
              !isStartingChat, !directInvalidated,
              !isUpdatingComposerConfiguration else { return false }
        guard !attachmentRecoveryIsBusy else {
            sendErrorMessage = "Resetting unresolved attachment delivery. The voice note was not sent."
            return false
        }
        guard directConversation?.hasAmbiguousPromptDelivery != true else {
            sendErrorMessage = promptDeliveryWarning(for: directConversation)
            return false
        }
        guard directConversation?.runState == nil || directConversation?.runState == .idle else {
            return false
        }
        if attachmentRecoveryNeedsReset, directPendingAttachments.isEmpty {
            sendErrorMessage = "An attachment delivery is unresolved. Reset the pending upload before continuing."
            return false
        }
        guard pendingAttachments.isEmpty, !isPreparingDirectAttachment else {
            sendErrorMessage = "Wait for attachment preparation to finish before sending the voice note."
            return false
        }
        let expectedProfile = directConversation?.profile
            ?? (Self.nonEmpty(currentProfile) ?? "default")
        let expectedSessionID = canonicalSessionID
        let expectedController = directConversation
        let selectionGeneration = directAttachmentSelectionGeneration
        let expectedAttachmentIDs = Set(directPendingAttachments.map(\.id))
        isSendingVoiceNote = true
        setUploadAttachmentError(nil)
        sendErrorMessage = nil
        lastError = nil
        defer { isSendingVoiceNote = false }

        let pending: DirectPendingAttachment
        do {
            let source = try await Task.detached(priority: .utility) {
                try DirectGatewayAttachment.file(data: audioData, filename: filename)
            }.value
            try Task.checkCancellation()
            pending = DirectPendingAttachment(source: source, thumbnailData: audioData)
        } catch {
            lastError = error
            setUploadAttachmentError(directAttachmentPreparationMessage(for: error))
            return false
        }

        guard !directInvalidated, expectedSessionID == canonicalSessionID,
              expectedProfile == (directConversation?.profile
                ?? (Self.nonEmpty(self.currentProfile) ?? "default")),
              directConversation === expectedController,
              selectionGeneration == directAttachmentSelectionGeneration,
              Set(directPendingAttachments.map(\.id)) == expectedAttachmentIDs else {
            sendErrorMessage = "The chat changed before the voice note could be sent."
            return false
        }

        let transcript: String
        do {
            let response = try await client.transcribeAudio(
                data: audioData,
                mimeType: pending.mimeType,
                profile: expectedProfile
            )
            transcript = (response.transcript ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw DirectTranscriptionError.invalidAcknowledgement }
        } catch {
            lastError = error
            setUploadAttachmentError(error.localizedDescription)
            return false
        }

        let currentProfile = directConversation?.profile
            ?? (Self.nonEmpty(self.currentProfile) ?? "default")
        guard !directInvalidated, expectedSessionID == canonicalSessionID,
              expectedProfile == currentProfile,
              directConversation === expectedController,
              selectionGeneration == directAttachmentSelectionGeneration,
              Set(directPendingAttachments.map(\.id)) == expectedAttachmentIDs else {
            sendErrorMessage = "The chat changed before the voice note could be sent."
            return false
        }
        directPendingAttachments.append(pending)
        return await sendDirectMessage(
            transcript,
            modelContext: modelContext,
            selectedAttachmentIDs: Set([pending.id]),
            removeSelectedAttachmentsOnAmbiguousDelivery: false
        )
    }

    #if DEBUG
    /// State-only setup for retained legacy renderer/recovery tests. This does not
    /// submit a prompt or exercise the retired WebUI send endpoint.
    func seedTranscriptForTesting(_ rows: [ChatMessage], messagesOffset offset: Int = 0) {
        resetPendingStreamingContentBuffers()
        withBatchedTranscriptDerivedState {
            messages = rows
            messagesOffset = offset
        }
        hasOlderMessages = offset > 0
        streamingAssistantMessageID = nil
        streamingAssistantMessageIndex = nil
        sealedInterimAssistantMessageIDs.removeAll()
    }

    /// Transport-neutral renderer seam for pacing tests. This follows the same
    /// presentation path as shared-runtime events without opening a connection.
    func handleDirectEventForTesting(_ event: HermesGatewayEvent) {
        applyDirectEvent(event)
    }

    @discardableResult
    func enqueueMessageForTesting(_ text: String) -> Int {
        enqueueQueuedSlashMessage(text, attachments: [])
    }

    func drainQueuedMessagesForTesting() {
        drainQueuedSlashMessageIfIdle()
    }

    #endif

    func submitGoal(args rawArgs: String, modelContext: ModelContext? = nil) async -> Bool {
        let args = rawArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usesDirectGateway, !args.isEmpty, !isSubmittingGoal, !directInvalidated else { return false }
        isSubmittingGoal = true
        goalErrorMessage = nil
        defer { isSubmittingGoal = false }
        do {
            let controller = try await ensureDirectConversation()
            let expectedOrigin = controller.sharedRuntime.origin
            guard expectedOrigin == server else { throw DirectSessionError.staleOperation }
            try await controller.open()
            var creation: [String: JSONValue] = [:]
            if let value = Self.nonEmpty(currentWorkspace) { creation["cwd"] = .string(value) }
            if let value = Self.nonEmpty(currentModel) { creation["model"] = .string(value) }
            if let value = Self.nonEmpty(currentModelProvider) { creation["provider"] = .string(value) }
            if let value = Self.nonEmpty(sessionReasoningEffort) { creation["reasoning_effort"] = .string(value) }
            let runningControl = controller.runState == .running
                && GatewayConversationController.goalControlIsAllowedWhileRunning(args)
            let goalBinding: GatewaySessionBinding
            if runningControl, let binding = controller.binding,
               controller.storedID == binding.storedID, canonicalSessionID == binding.storedID {
                goalBinding = binding
            } else {
                goalBinding = try await controller.prepareGoalSession(create: creation)
            }
            let expectedRunState: GatewayConversationController.RunState = runningControl ? .running : .idle
            // Draft preparation may establish the first connection. Attest the
            // running profile only after that binding is ready, then keep this
            // generation fixed through lookup, dispatch and prompt delivery.
            let connectionGeneration = controller.sharedRuntime.connectionGeneration
            guard !directInvalidated, directConversation === controller,
                  controller.sharedRuntime.origin == expectedOrigin,
                  controller.sharedRuntime.state == .ready,
                  controller.sharedRuntime.connectionGeneration == connectionGeneration,
                  goalBinding == controller.binding,
                  let sessionID = controller.storedID,
                  sessionID == goalBinding.storedID,
                  sessionID == canonicalSessionID,
                  controller.runState == expectedRunState,
                  !controller.hasAmbiguousPromptDelivery else {
                throw DirectSessionError.staleOperation
            }
            let profile = controller.profile
            let activeProfile = try await client.directActiveProfile()
            guard let runningProfile = Self.nonEmpty(activeProfile.current) else {
                throw DirectGoalError.runningProfileUnavailable
            }
            guard runningProfile == profile else {
                throw DirectGoalError.runningProfileMismatch(selected: profile, current: runningProfile)
            }
            guard !directInvalidated, directConversation === controller,
                  controller.sharedRuntime.origin == expectedOrigin,
                  controller.sharedRuntime.state == .ready,
                  controller.sharedRuntime.connectionGeneration == connectionGeneration,
                  controller.storedID == sessionID, canonicalSessionID == sessionID,
                  controller.profile == profile, controller.runState == expectedRunState,
                  !controller.hasAmbiguousPromptDelivery else {
                throw DirectSessionError.staleOperation
            }

            let result = try await controller.dispatchGoal(args, profileContext: activeProfile)
            guard !directInvalidated, directConversation === controller,
                  controller.sharedRuntime.origin == expectedOrigin,
                  controller.sharedRuntime.state == .ready,
                  controller.sharedRuntime.connectionGeneration == connectionGeneration,
                  controller.storedID == sessionID, canonicalSessionID == sessionID,
                  controller.profile == profile else {
                throw DirectGoalError.outcomeUnknown
            }
            switch result {
            case .output(let text):
                appendLocalAssistantMessage(text)
                hasActivatedGoalCommand = true
                return true
            case .send(let notice, let message, let display):
                let sent = await sendDirectMessage(
                    message,
                    modelContext: modelContext,
                    selectedAttachmentIDs: [],
                    requiredController: controller,
                    requiredSessionID: sessionID,
                    requiredProfile: profile,
                    requiredOrigin: expectedOrigin,
                    requiredConnectionGeneration: connectionGeneration
                )
                guard sent, !controller.hasAmbiguousPromptDelivery,
                      controller.runState != .deliveryUnknown else {
                    goalErrorMessage = String(localized: "The goal command outcome is unknown. It was not retried; review Hermes before trying again.")
                    sendErrorMessage = goalErrorMessage
                    return false
                }
                for text in [notice, display].compactMap({ Self.nonEmpty($0) }) {
                    appendLocalNoticeMessage(text)
                }
                hasActivatedGoalCommand = true
                return true
            }
        } catch {
            lastError = error
            let message: String
            if (error as? DirectSessionError) == .staleOperation
                || (error as? DirectGoalError) == .runningProfileUnavailable {
                message = String(localized: "The chat or running Hermes profile changed, so the goal command was not sent.")
            } else if let goalError = error as? DirectGoalError,
                      case .runningProfileMismatch(_, _) = goalError {
                message = String(localized: "The selected chat profile is not the profile running Hermes, so the goal command was not sent.")
            } else if (error as? DirectGoalError) == .outcomeUnknown {
                message = String(localized: "The goal command outcome is unknown. It was not retried; review Hermes before trying again.")
            } else {
                message = error.localizedDescription
            }
            goalErrorMessage = message
            sendErrorMessage = message
            return false
        }
    }

    private func rollbackOptimisticMessage(id: String) {
        messages.removeAll { $0.messageId == id }
        attachmentCoordinator.removeLocalPreviews(messageID: id)
    }

    private func restorePendingAttachments(_ attachments: [PendingAttachment]) {
        attachmentCoordinator.restorePendingAttachments(attachments)
    }

    private func transcriptCacheID(_ durableID: String) -> String {
        guard usesDirectGateway else { return durableID }
        let profile = Self.nonEmpty(currentProfile) ?? "default"
        return "direct:\(profile.utf8.count):\(profile):\(durableID)"
    }

    private func cacheCurrentMessages(sessionID: String, modelContext: ModelContext?) {
        guard let modelContext else { return }

        do {
            let messageWindow = Self.cacheMessageWindow(from: messages)
            let previewIdentity = usesDirectGateway
                ? CachedSessionPreviewIdentity(
                    profile: Self.nonEmpty(currentProfile) ?? "default",
                    sessionID: sessionID
                )
                : nil
            try CacheStore.cacheMessages(
                messageWindow,
                serverURL: server,
                sessionID: transcriptCacheID(sessionID),
                previewIdentity: previewIdentity,
                in: modelContext
            )
        } catch {
            cacheErrorMessage = error.localizedDescription
        }
    }

    func cacheCompletedResponse(modelContext: ModelContext) {
        guard let sessionID else { return }
        cacheCurrentMessages(sessionID: sessionID, modelContext: modelContext)
    }

    func clearTranscript() {
        // An explicit clear always wins over a pending resume reconciliation.
        sendTranscriptSessionID = nil
        cancelPendingStreamingScrollTrigger()
        resetPendingStreamingContentBuffers()
        clearCompressionAnchorMetadata()
        withBatchedTranscriptDerivedState {
            messages = []
            messagesOffset = 0
        }
        hasOlderMessages = false
        setCompletedToolCallGroups([])
        completedReasoningGroups = []
        liveToolCalls = []
        liveReasoningText = ""
        pinnedLocalNotices = []
        btwLocalRowScopes.removeAll()
        backgroundLocalRowScopes.removeAll()
        directBackgroundAttempts.removeAll()
        directBackgroundStartsInFlight.removeAll()
        directBackgroundResolutions.removeAll()
        streamingAssistantMessageID = nil
        toolCallAnchorMessageID = nil
        reasoningAnchorMessageID = nil
        attachmentCoordinator.removeAllLocalPreviews()
        sendErrorMessage = nil
    }

    func executeSlashCommand(_ command: SlashCommand, args: String = "") async -> SlashCommandExecutionResult {
        switch command.handler {
        case .clientSide(let action):
            switch action {
            case .clear:
                clearTranscript()
                return .executed(message: nil)
            case .stop:
                await cancelActiveStream()
                return .executed(message: nil)
            case .new:
                return await createSessionFromSlashCommand()
            case .help:
                return .executed(message: Self.slashCommandHelpText)
            }
        case .serverSide(let action):
            return await executeServerSideSlashCommand(action, args: args)
        case .unsupported:
            return .unsupported(friendlyMessage: SlashCommandExecutor.unsupportedMessage(for: command.name))
        }
    }

    private func executeServerSideSlashCommand(
        _ action: ServerSideAction,
        args: String
    ) async -> SlashCommandExecutionResult {
        switch action {
        case .model:
            return await switchModelFromSlashCommand(args)
        case .workspace:
            return await switchWorkspaceFromSlashCommand(args)
        case .reasoning:
            return await switchReasoningFromSlashCommand(args)
        case .title:
            return await renameSessionFromSlashCommand(args)
        case .personality:
            return await setPersonalityFromSlashCommand(args)
        case .skills:
            return await searchSkillsFromSlashCommand(args)
        case .branch:
            return await branchSessionFromSlashCommand(args)
        case .undo:
            return await undoLastExchangeFromSlashCommand()
        case .retry:
            return await retryLastTurnFromSlashCommand()
        case .compress:
            return await compressSessionFromSlashCommand(args)
        case .queue:
            return await queueMessageFromSlashCommand(args)
        case .steer:
            return await steerResponseFromSlashCommand(args)
        case .interrupt:
            return await interruptResponseFromSlashCommand(args)
        case .status:
            return .executed(message: statusMessageFromSlashCommand())
        case .btw:
            return await askBtwFromSlashCommand(args)
        case .background:
            return await startBackgroundFromSlashCommand(args)
        case .goal:
            return await submitGoalFromSlashCommand(args)
        }
    }

    func submitStreamingMessage(
        _ draft: String,
        behavior: StreamingSendBehavior
    ) async -> SlashCommandExecutionResult {
        switch behavior {
        case .steer:
            return await steerResponseFromSlashCommand(draft)
        case .interrupt:
            return await interruptResponseFromSlashCommand(draft)
        case .queue:
            return await queueMessageFromSlashCommand(draft)
        }
    }

    private func queueMessageFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let message = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /queue <message>"))
        }

        guard activeStreamID != nil else {
            let sent = await sendMessage(message)
            return sent ? .executed(message: nil) : .unsupported(friendlyMessage: sendErrorMessage ?? String(localized: "Could not send the queued message."))
        }

        let position = enqueueQueuedSlashMessage(message, attachments: attachmentCoordinator.consumePendingAttachments())
        return .executed(message: String(localized: "Queued for next turn (#\(position))."))
    }

    private func steerResponseFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        if usesDirectGateway {
            do {
                let controller = try await ensureDirectConversation()
                let outcome = try await controller.steer(args)
                switch outcome {
                case .accepted: return .executed(message: "Steering hint delivered.")
                case .queued: return .executed(message: "Steering hint queued by Hermes.")
                case .rejected: return .unsupported(friendlyMessage: "Hermes rejected this steering hint; the current response was not interrupted.")
                }
            } catch {
                lastError = error
                return .unsupported(friendlyMessage: "Could not deliver the steering hint. The message was not resent.")
            }
        }
        return .unsupported(friendlyMessage: "Direct Hermes connection is unavailable.")
    }

    private func interruptResponseFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let message = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /interrupt <message>"))
        }

        guard activeStreamID != nil else {
            let sent = await sendMessage(message)
            return sent ? .executed(message: nil) : .unsupported(friendlyMessage: sendErrorMessage ?? String(localized: "Could not send the interrupt message."))
        }

        enqueueQueuedSlashMessage(message, attachments: attachmentCoordinator.consumePendingAttachments(), atFront: true)
        await cancelActiveStream()

        if activeStreamID != nil {
            return .executed(message: String(localized: "Could not stop the current response yet, so the interrupt message was queued for the next turn."))
        }

        return .executed(message: String(localized: "Interrupted the current response and queued your message to send next."))
    }

    private func statusMessageFromSlashCommand() -> String {
        let running = activeStreamID == nil ? String(localized: "No") : String(localized: "Yes")
        let queued = queuedSlashMessages.count
        let backgroundTasks = directBackgroundAttempts.count
        let profile = selectedProfileName ?? currentProfile ?? "default"
        let workspace = currentWorkspace ?? String(localized: "Unknown")
        let model = currentModel ?? String(localized: "Unknown")
        let provider = currentModelProvider ?? providerFromModel(model) ?? String(localized: "Unknown")
        let messageCount = messages.filter { $0.role != "tool" }.count
        let tokens = statusTokenLine()

        return String(localized: """
        Session status:

        - Session ID: \(sessionID ?? "Unknown")
        - Title: \(displayTitle)
        - Model: \(model)
        - Provider: \(provider)
        - Profile: \(profile)
        - Workspace: \(workspace)
        - Agent running: \(running)
        - Queued messages: \(queued)
        - Background tasks: \(backgroundTasks)
        - Messages loaded: \(messageCount)
        - Tokens: \(tokens)
        """)
    }

    private func askBtwFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let question = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /btw <question>"))
        }
        guard usesDirectGateway, !directInvalidated, !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to Hermes to ask a side question."))
        }
        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before using /btw."))
        }
        guard activeBtwAttemptID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current /btw answer to finish first."))
        }

        do {
            let controller = try await ensureDirectConversation()
            try await controller.open()
            guard !directInvalidated, directConversation === controller else {
                throw DirectSessionError.staleOperation
            }
            guard activeBtwAttemptID == nil else {
                return .unsupported(friendlyMessage: String(localized: "Wait for the current /btw answer to finish first."))
            }
            let attemptID = UUID()
            let profile = controller.profile
            activeBtwAttemptID = attemptID
            activeBtwTaskID = nil
            activeBtwProfile = profile
            activeBtwQuestion = question
            activeBtwAnswer = ""
            activeBtwMessageID = appendLocalAssistantMessage(Self.btwMessageText(question: question, answer: nil, isLoading: true))
            if let messageID = activeBtwMessageID,
               let sessionID = controller.storedID {
                btwLocalRowScopes[messageID] = (sessionID, profile)
            }

            do {
                let taskID = try await controller.startBtw(question, attemptID: attemptID)
                // Completion may have arrived while startBtw was awaiting its ACK.
                if activeBtwAttemptID == attemptID,
                   !directInvalidated,
                   directConversation === controller,
                   activeBtwProfile == profile {
                    activeBtwTaskID = taskID
                }
                return .executed(message: nil)
            } catch {
                if activeBtwAttemptID == attemptID {
                    let unknown = error is DirectBtwError && (error as? DirectBtwError) == .outcomeUnknown
                    activeBtwAnswer = unknown
                        ? String(localized: "Outcome unknown. Check Hermes before asking again.")
                        : String(localized: "The side question was not accepted by Hermes.")
                    updateActiveBtwMessage(isLoading: false)
                    clearActiveBtwAttempt()
                }
                lastError = error
                return .unsupported(friendlyMessage: error.localizedDescription)
            }
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: String(localized: "Could not start the side question."))
        }
    }

    private func startBackgroundFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let prompt = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /background <prompt>"))
        }
        guard usesDirectGateway, !directInvalidated, !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to Hermes to start a background task."))
        }
        do {
            let controller = try await ensureDirectConversation()
            try await controller.open()
            guard !directInvalidated, directConversation === controller,
                  let sessionID = controller.storedID,
                  canonicalSessionID == sessionID else {
                throw DirectSessionError.staleOperation
            }
            let attemptID = UUID()
            let profile = controller.profile
            directBackgroundAttempts[attemptID] = DirectBackgroundAttempt(
                prompt: prompt, sessionID: sessionID, profile: profile, taskID: nil
            )
            directBackgroundStartsInFlight.insert(attemptID)
            do {
                let taskID = try await controller.startBackground(prompt, attemptID: attemptID)
                directBackgroundStartsInFlight.remove(attemptID)
                let resolution = directBackgroundResolutions.removeValue(forKey: attemptID)
                guard !directInvalidated, directConversation === controller,
                      canonicalSessionID == sessionID,
                      controller.storedID == sessionID,
                      controller.profile == profile else {
                    directBackgroundAttempts.removeValue(forKey: attemptID)
                    lastError = DirectBackgroundError.outcomeUnknown
                    return .unsupported(friendlyMessage: String(localized: "Outcome unknown. Check Hermes before starting the background task again."))
                }
                if var attempt = directBackgroundAttempts[attemptID] {
                    attempt.taskID = taskID
                    directBackgroundAttempts[attemptID] = attempt
                } else if resolution != .completed {
                    lastError = DirectBackgroundError.outcomeUnknown
                    return .unsupported(friendlyMessage: String(localized: "Outcome unknown. Check Hermes before starting the background task again."))
                }
                return .executed(message: String(localized: "Background task started. I'll add the result here when it completes."))
            } catch {
                directBackgroundStartsInFlight.remove(attemptID)
                let wasAlreadyUnknown = directBackgroundResolutions.removeValue(forKey: attemptID) == .unknown
                let unknown = wasAlreadyUnknown || (error as? DirectBackgroundError) == .outcomeUnknown
                let attempt = directBackgroundAttempts.removeValue(forKey: attemptID)
                if let attempt, unknown {
                    appendDirectBackgroundResult(
                        prompt: attempt.prompt,
                        answer: String(localized: "Outcome unknown. Check Hermes before starting it again."),
                        sessionID: attempt.sessionID,
                        profile: attempt.profile
                    )
                }
                lastError = error
                let message = unknown
                    ? String(localized: "Outcome unknown. Check Hermes before starting the background task again.")
                    : error.localizedDescription
                return .unsupported(friendlyMessage: message)
            }
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func submitGoalFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let goalArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let didSubmit = await submitGoal(args: goalArgs.isEmpty ? "status" : goalArgs)
        return didSubmit ? .executed(message: nil) : .unsupported(friendlyMessage: goalErrorMessage ?? String(localized: "Could not submit the goal command."))
    }

    private func switchModelFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        _ = args
        return .unsupported(friendlyMessage: "Use the model picker in New Chat before sending its first message.")
    }

    private func switchWorkspaceFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let changed = await selectWorkspacePath(args)
        return changed
            ? .executed(message: nil)
            : .unsupported(friendlyMessage: composerConfigurationErrorMessage ?? "Workspace was not changed.")
    }

    private func switchReasoningFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let changed = await selectReasoningEffort(args)
        return changed
            ? .executed(message: nil)
            : .unsupported(
                friendlyMessage: composerConfigurationErrorMessage
                    ?? "Use a supported reasoning level in New Chat. Server-wide display changes are not available here."
            )
    }

    private func renameSessionFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        _ = args
        return .unsupported(friendlyMessage: String(localized: "/title is not available in direct Hermes mode yet."))
    }

    private func setPersonalityFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        _ = args
        return .unsupported(friendlyMessage: String(localized: "/personality is temporarily unavailable."))
    }

    private func searchSkillsFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        if usesDirectGateway {
            guard !isSubmittingDirectSkill else {
                return .unsupported(friendlyMessage: "Wait for the current skill invocation to finish.")
            }
            isSubmittingDirectSkill = true
            defer { isSubmittingDirectSkill = false }
            do {
                let controller = try await ensureDirectConversation()
                let profile = controller.profile
                let origin = controller.sharedRuntime.origin
                let suggestions = try await directSkillSuggestions(
                    controller: controller, profile: profile, origin: origin
                )
                if let invocation = SlashSkillFormatter.invocation(from: args, suggestions: suggestions) {
                    return .unsupported(friendlyMessage: directSkillInvocationUnavailableMessage)
                }
                return .executed(message: SlashSkillFormatter.message(for: suggestions,
                    query: SlashSkillFormatter.skillQuery(from: args)))
            } catch {
                if Task.isCancelled || directInvalidated
                    || (error as? DirectSessionError) == .staleOperation {
                    return .executed(message: nil)
                }
                lastError = error
                return .unsupported(friendlyMessage: error.localizedDescription)
            }
        }
        return .unsupported(friendlyMessage: "Skills require a direct Hermes connection.")
    }

    func executeSkillShortcutCommand(name: String, args: String) async -> SlashCommandExecutionResult? {
        if usesDirectGateway {
            guard !isSubmittingDirectSkill else {
                return .unsupported(friendlyMessage: "Wait for the current skill invocation to finish.")
            }
            isSubmittingDirectSkill = true
            defer { isSubmittingDirectSkill = false }
            do {
                let controller = try await ensureDirectConversation()
                let profile = controller.profile
                let origin = controller.sharedRuntime.origin
                let suggestions = try await directSkillSuggestions(
                    controller: controller, profile: profile, origin: origin
                )
                guard let skill = SlashSkillFormatter.skill(named: name, in: suggestions) else { return nil }
                let message = args.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else {
                    return .executed(message: directSkillDetailMessage(for: skill))
                }
                return .unsupported(friendlyMessage: directSkillInvocationUnavailableMessage)
            } catch {
                if Task.isCancelled || directInvalidated
                    || (error as? DirectSessionError) == .staleOperation {
                    return .executed(message: nil)
                }
                lastError = error
                return .unsupported(friendlyMessage: error.localizedDescription)
            }
        }
        _ = name
        _ = args
        return .unsupported(friendlyMessage: "Skills require a direct Hermes connection.")
    }

    private func directSkillSuggestions(
        controller: GatewayConversationController,
        profile: String,
        origin: URL
    ) async throws -> [SkillSlashSuggestion] {
        func requireCurrentScope() throws {
            try Task.checkCancellation()
            guard !directInvalidated, directConversation === controller,
                  controller.profile == profile,
                  (Self.nonEmpty(currentProfile) ?? "default") == profile,
                  controller.sharedRuntime.origin == origin,
                  origin == server else { throw DirectSessionError.staleOperation }
        }
        try requireCurrentScope()
        let response: SkillsResponse
        do { response = try await client.directSkills(profile: profile) }
        catch {
            try requireCurrentScope()
            throw error
        }
        try requireCurrentScope()
        let suggestions = SlashSkillFormatter.suggestions(from: response.skills ?? [])
        skillSlashSuggestions = suggestions
        hasLoadedSkillSlashSuggestions = true
        return suggestions
    }

    private var directSkillInvocationUnavailableMessage: String {
        String(localized: "Skill invocation is temporarily unavailable in direct Hermes mode. You can still browse installed skills with `/skills`.")
    }

    private func directSkillDetailMessage(for skill: SkillSlashSuggestion) -> String {
        var lines = ["### `/\(skill.slashName)`", "", "**\(skill.name)**"]
        if let category = skill.category { lines += ["", "Category: \(category)"] }
        if let description = skill.description { lines += ["", description] }
        lines += ["", directSkillInvocationUnavailableMessage]
        return lines.joined(separator: "\n")
    }

    private func branchSessionFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        await branchDirectConversation(name: args)
    }

    private func createSessionFromSlashCommand() async -> SlashCommandExecutionResult {
        .unsupported(friendlyMessage: String(localized: "Use New Chat; direct Hermes creates sessions on first send."))
    }

    private func compressDirectSessionFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        guard !directInvalidated, !isViewingCachedData, !isStartingChat,
              !isCompressingSession, activeStreamID == nil else {
            return .unsupported(friendlyMessage: "Wait for the current response to finish before compressing context.")
        }
        let expectedProfile = Self.nonEmpty(currentProfile) ?? "default"
        isCompressingSession = true
        defer { isCompressingSession = false }
        do {
            let controller = try await ensureDirectConversation()
            try await controller.open()
            guard !directInvalidated, directConversation === controller,
                  controller.profile == expectedProfile, controller.runtimeOrigin == server,
                  controller.storedID == canonicalSessionID else { throw DirectSessionError.staleOperation }
            let outcome = try await controller.compress(focusTopic: args)
            guard !directInvalidated, directConversation === controller,
                  controller.profile == expectedProfile, controller.runtimeOrigin == server,
                  controller.storedID == canonicalSessionID else { throw DirectSessionError.staleOperation }
            switch outcome {
            case .compressed: return .executed(message: "Context compressed.")
            case .unchanged: return .executed(message: "No changes from compression.")
            case .aborted: return .executed(message: "Compression was aborted; context was preserved.")
            case .lockSkipped: return .executed(message: "Compression was skipped because the session's compression lock was unavailable.")
            }
        } catch DirectSessionCompressionError.outcomeUnknown {
            return .unsupported(friendlyMessage: "The compression outcome could not be confirmed. It has not been retried; sending and compression are paused for this open chat.")
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: "Context could not be compressed safely.")
        }
    }

    private func compressSessionFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        await compressDirectSessionFromSlashCommand(args)
    }

    private func undoLastExchangeFromSlashCommand() async -> SlashCommandExecutionResult {
        .unsupported(friendlyMessage: String(localized: "Undo is not available in direct Hermes mode yet."))
    }

    private func retryLastTurnFromSlashCommand() async -> SlashCommandExecutionResult {
        // Legacy truncate-and-resubmit is retired. Direct retry remains unavailable
        // until its destructive targeting contract is explicitly resolved.
        return .unsupported(friendlyMessage: String(localized: "Retry is not available in direct Hermes mode yet."))
    }




    @discardableResult
    func appendLocalAssistantMessage(_ text: String) -> String? {
        appendLocalMessage(text, role: "local_assistant", idPrefix: "local-slash")
    }

    @discardableResult
    func appendLocalNoticeMessage(_ text: String) -> String? {
        appendLocalMessage(text, role: "local_notice", idPrefix: "local-notice")
    }

    func pinLocalNoticeMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pinnedLocalNotices.append(trimmed)
    }

    private func appendLocalMessage(_ text: String, role: String, idPrefix: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let messageID = "\(idPrefix)-\(UUID().uuidString)"
        messages.append(
            ChatMessage(
                role: role,
                content: trimmed,
                timestamp: Date().timeIntervalSince1970,
                messageId: messageID
            )
        )
        scheduleStreamingScrollTrigger()
        return messageID
    }

    private func updateLocalMessage(id: String, content: String) {
        guard let index = messages.firstIndex(where: { $0.messageId == id }) else { return }
        let existing = messages[index]
        messages[index] = ChatMessage(
            role: existing.role,
            content: content,
            timestamp: existing.timestamp,
            messageId: existing.messageId,
            name: existing.name,
            toolCallId: existing.toolCallId,
            toolUseId: existing.toolUseId,
            toolCalls: existing.toolCalls,
            contentParts: existing.contentParts,
            reasoning: existing.reasoning,
            attachments: existing.attachments,
            turnTps: existing.turnTps
        )
        scheduleStreamingScrollTrigger()
    }

    func setSendErrorMessage(_ message: String?) {
        sendErrorMessage = message
    }

    func forkFromMessage(_ context: MessageActionContext, modelContext: ModelContext? = nil) async -> SessionSummary? {
        _ = context
        _ = modelContext
        messageActionErrorMessage = String(localized: "Forking is not available in direct Hermes mode yet.")
        return nil
    }

    func editMessage(_ context: MessageActionContext, newText: String, modelContext: ModelContext? = nil) async -> Bool {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return await submitDestructiveMessage(
            context: context,
            replacementText: text,
            expectedRole: .user,
            modelContext: modelContext
        )
    }

    func regenerateAssistantResponse(
        _ context: MessageActionContext,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        await submitDestructiveMessage(
            context: context,
            replacementText: nil,
            expectedRole: .assistant,
            modelContext: modelContext
        )
    }

    private func submitDestructiveMessage(
        context: MessageActionContext,
        replacementText: String?,
        expectedRole: MessageActionContext.Role,
        modelContext: ModelContext?
    ) async -> Bool {
        guard usesDirectGateway, !directInvalidated, !isViewingCachedData,
              activeStreamID == nil, !isStartingChat, !isEditingMessage,
              !isRegeneratingMessage, !isUpdatingComposerConfiguration,
              directPendingAttachments.isEmpty, pendingAttachments.isEmpty,
              !isPreparingDirectAttachment, !attachmentRecoveryIsBusy else {
            messageActionErrorMessage = String(localized: "Reconnect, finish the active response, and clear pending attachments before changing history.")
            return false
        }
        guard context.role == expectedRole else {
            messageActionErrorMessage = String(localized: "That message is no longer a valid history target.")
            return false
        }

        directModelContext = modelContext ?? directModelContext
        if expectedRole == .user { isEditingMessage = true }
        else { isRegeneratingMessage = true }
        messageActionErrorMessage = nil
        lastError = nil
        defer {
            isEditingMessage = false
            isRegeneratingMessage = false
            OpenChatSessionStore.shared.noteStreamingStateChanged()
        }

        do {
            let controller = try await ensureDirectConversation()
            guard controller.runState == .idle,
                  controller.profile == (requestProfileName ?? "default"),
                  controller.storedID == canonicalSessionID,
                  controller.storedID == directHistoryID else {
                throw DirectSessionError.staleOperation
            }

            // Re-read the canonical tail immediately before selecting the row.
            // This detects ordinary stale/mismatched targets, while the approved
            // stock cross-client check/write race remains explicitly non-atomic.
            try await controller.refresh()
            guard controller.runState == .idle,
                  controller.profile == (requestProfileName ?? "default"),
                  controller.storedID == canonicalSessionID,
                  controller.storedID == directHistoryID,
                  let selectedIndex = messages.firstIndex(where: { $0.messageId == context.messageID }),
                  messages[selectedIndex].role == (expectedRole == .user ? "user" : "assistant"),
                  messages[selectedIndex].content == context.copyText else {
                throw DirectSessionError.staleOperation
            }

            let targetIndex: Int
            let prompt: String
            if expectedRole == .user {
                targetIndex = selectedIndex
                prompt = replacementText ?? ""
            } else {
                guard selectedIndex > messages.startIndex,
                      let origin = messages[..<selectedIndex].lastIndex(where: {
                          TranscriptTurnClassifier.isUserTurnBoundary($0)
                      }),
                      let content = messages[origin].content?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty else {
                    throw DirectSessionError.staleOperation
                }
                targetIndex = origin
                prompt = content
            }
            guard messages[targetIndex].role == "user",
                  let rowString = messages[targetIndex].messageId,
                  rowString == rowString.trimmingCharacters(in: .whitespacesAndNewlines),
                  let rowID = Int(rowString), rowID > 0,
                  Double(exactly: rowID) != nil else {
                throw DirectSessionError.staleOperation
            }

            let priorUserCount = messages[..<targetIndex].filter {
                TranscriptTurnClassifier.isUserTurnBoundary($0)
            }.count
            let ordinal = hasOlderMessages ? nil : priorUserCount
            try await controller.submit(
                prompt,
                destructiveTarget: .init(
                    userRowID: rowID,
                    userOrdinal: ordinal,
                    permitsEmptyTranscript: priorUserCount == 0 && !hasOlderMessages
                )
            )
            return true
        } catch {
            lastError = error
            if directConversation?.hasAmbiguousPromptDelivery == true {
                messageActionErrorMessage = String(localized: "Hermes may have queued or started the replacement. It was not resent; refresh after the run settles before trying again.")
            } else if case let HermesGatewayError.server(code, _, data, method, _, _) = error,
                      method == "prompt.submit", code == 4018,
                      case .number(let segment)? = data?.gatewayFields["segment_ordinal"],
                      segment < 0 {
                messageActionErrorMessage = String(localized: "That turn is in the immutable compacted history and cannot be changed from this continuation.")
            } else if let directError = error as? DirectSessionError,
                      directError == .staleOperation {
                messageActionErrorMessage = String(localized: "The conversation changed, so no history was replaced. Review the latest messages and try again.")
            } else {
                messageActionErrorMessage = String(localized: "Hermes refused to change this history. No automatic retry was attempted.")
            }
            return false
        }
    }

    @discardableResult
    func cancelActiveStream() async -> Bool {
        guard !isCancellingStream else { return false }
        isCancellingStream = true
        defer { isCancellingStream = false }
        do {
            let controller = try await ensureDirectConversation()
            try await controller.interrupt()
            OpenChatSessionStore.shared.noteStreamingStateChanged()
            return true
        } catch {
            lastError = error
            sendErrorMessage = "Hermes has not confirmed that the response stopped."
            return false
        }
    }

    func clearMessageActionError() {
        messageActionErrorMessage = nil
    }

    func toggleListening(to context: MessageActionContext) {
        guard context.role == .assistant else { return }

        guard let listenText = context.listenText else {
            messageActionErrorMessage = String(localized: "There is no assistant text to listen to.")
            return
        }

        // Tapping the message that is already listening — fetching server audio or
        // playing on either engine — toggles it off. Matching on `listeningMessageID`
        // alone (not `isSpeaking`) also debounces rapid double-taps: the second tap
        // stops cleanly instead of firing a second `/api/audio/speak` call into the server's
        // ~2 s rate limit or stacking audio (#15).
        if listeningMessageID == context.messageID {
            stopListening()
            return
        }

        stopListening()
        // The audio session is NOT activated here: `/api/audio/speak` can be slow or
        // unreachable, and activating the non-mixable playback session before the
        // fetch would silence other audio while Semreh has nothing to play (review
        // on #35). Activation happens at the two playback-start points instead —
        // `startServerAudioPlayback` and `speakWithOnDeviceSynthesizer`.
        listeningMessageID = context.messageID
        beginListenPlaybackPreparation(for: context)

        guard ServerTTSPolicy.shouldUseServerTTS(for: listenText) else {
            // Over the client's 5000-char Listen cap: go straight to the on-device
            // path (chunking is a non-goal of #15).
            clearListenPlaybackState()
            speakWithOnDeviceSynthesizer(listenText)
            return
        }

        // Prefer the server's neural TTS; on any failure (offline, 4xx/5xx, rate
        // limit, undecodable audio) fall back silently to the on-device
        // synthesizer — no error alert (#15).
        let requestID = UUID()
        activeListenRequestID = requestID
        let speechProfile = requestProfileName ?? "default"
        listenPreparationTask = Task { [weak self, client] in
            guard !Task.isCancelled else {
                // Stopped before the fetch began (e.g. a rapid second tap): skip
                // the request entirely instead of issuing one whose response
                // would be dropped anyway.
                return
            }
            let audioData: Data?
            do {
                audioData = try await client.synthesizeSpeech(
                    text: listenText, profile: speechProfile
                )
            } catch {
                audioData = nil
            }

            guard let self, !Task.isCancelled, self.activeListenRequestID == requestID else {
                // Stopped or superseded while the fetch was in flight — the user no
                // longer wants this audio; never start playback from a stale response.
                return
            }

            guard (self.requestProfileName ?? "default") == speechProfile else {
                self.finishListening()
                return
            }
            if let audioData, self.startServerAudioPlayback(audioData, title: self.listenPlaybackTitle) {
                return
            }
            self.clearListenPlaybackState()
            self.speakWithOnDeviceSynthesizer(listenText)
        }
    }

    func stopListening() {
        // Cancel any in-flight server-TTS fetch so a late response can't start
        // audio after the user asked to stop (or switched messages).
        listenPreparationTask?.cancel()
        listenPreparationTask = nil
        activeListenRequestID = nil

        // `AVAudioPlayer.stop()` does not fire the finish delegate, so no stale
        // callback follows; state is torn down synchronously in `finishListening()`.
        listenAudioPlayer?.stop()

        if let speechSynthesizer, speechSynthesizer.isSpeaking || speechSynthesizer.isPaused {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        finishListening()
    }

    func toggleListenPlaybackPlayPause() {
        switch listenPlaybackPhase {
        case .playing:
            pauseListenPlayback()
        case .paused:
            resumeListenPlayback()
        case .idle, .loading:
            break
        }
    }

    func setListenPlaybackSpeed(_ speed: ListenPlaybackSpeed) {
        guard listenPlaybackSpeed != speed else { return }
        listenPlaybackSpeed = speed
        userDefaults.set(speed.rawValue, forKey: ListenPlaybackSpeed.storageKey)
        listenAudioPlayer?.rate = Float(speed.rawValue)
        updateListenNowPlaying()
    }

    func scrubListenPlayback(to time: TimeInterval) {
        listenPlaybackScrubTime = boundedListenPlaybackTime(time)
    }

    func setListenPlaybackScrubbing(_ scrubbing: Bool) {
        if scrubbing {
            listenPlaybackScrubTime = listenPlaybackElapsedTime
        } else if let target = listenPlaybackScrubTime {
            seekListenPlayback(to: target)
            listenPlaybackScrubTime = nil
        }
    }

    func refreshListenPlaybackProgressAfterSceneActivation() {
        guard listenPlaybackPhase == .playing || listenPlaybackPhase == .paused else { return }

        updateListenPlaybackProgressFromPlayer()
        if listenPlaybackPhase == .playing {
            startListenPlaybackTicker()
        }
    }

    func cleanupPollingTasks() {
        failDirectBackgroundAttempts()
        directBackgroundStartsInFlight.removeAll()
        directBackgroundResolutions.removeAll()
    }

    /// Reconciles an open chat when the scene becomes active. A known suspended
    /// run takes the fast replay path; a chat with no locally known run first
    /// refreshes its bounded 50-message window so work started elsewhere becomes
    /// visible, then attaches replay if that response reveals an active stream.
    func refreshAfterSceneActivation(modelContext: ModelContext? = nil) async {
        if activeStreamID == nil,
           !isStartingChat,
           !isEditingMessage,
           !isRegeneratingMessage {
            isForegroundReentryRead = true
            defer { isForegroundReentryRead = false }
            await loadMessages(modelContext: modelContext)
            guard !Task.isCancelled else { return }
        }
        await reconnectStreamIfNeeded(modelContext: modelContext)
    }

    @discardableResult
    func reconnectStreamIfNeeded(modelContext: ModelContext? = nil) async -> Bool {
        do {
            let controller = try await ensureDirectConversation()
            try await controller.open()
            return activeStreamID != nil
        } catch { lastError = error; return false }
    }

    /// Sends a direct approval only for the identity captured from the
    /// rendered prompt.
    func respondToApproval(
        _ choice: GatewayApprovalChoice,
        expectedIdentity: GatewayBlockingPromptIdentity
    ) async throws -> GatewayBlockingResponse {
        let controller = try directBlockingController(
            expectedIdentity: expectedIdentity,
            currentIdentity: pendingApprovalPrompt?.identity
        )
        directBlockingInteractionErrorMessage = nil
        directBlockingInteractionErrorIdentity = nil
        do {
            let response = try await controller.respondToApproval(
                choice,
                expectedIdentity: expectedIdentity
            )
            try validateDirectBlockingController(controller, expectedIdentity: expectedIdentity)
            directBlockingInteractionErrorMessage = nil
            directBlockingInteractionErrorIdentity = nil
            return response
        } catch {
            recordDirectBlockingError(error, controller: controller, expectedIdentity: expectedIdentity, currentIdentity: pendingApprovalPrompt?.identity)
            throw error
        }
    }

    func cancelSecret(
        expectedIdentity: GatewayBlockingPromptIdentity
    ) async throws -> GatewayBlockingResponse {
        let controller = try directBlockingController(
            expectedIdentity: expectedIdentity,
            currentIdentity: pendingSecretPrompt?.identity
        )
        directBlockingInteractionErrorMessage = nil
        directBlockingInteractionErrorIdentity = nil
        do {
            let response = try await controller.cancelSecret(expectedIdentity: expectedIdentity)
            try validateDirectBlockingController(controller, expectedIdentity: expectedIdentity)
            directBlockingInteractionErrorMessage = nil
            directBlockingInteractionErrorIdentity = nil
            return response
        } catch {
            recordDirectBlockingError(error, controller: controller, expectedIdentity: expectedIdentity, currentIdentity: pendingSecretPrompt?.identity)
            throw error
        }
    }

    func cancelSudo(
        expectedIdentity: GatewayBlockingPromptIdentity
    ) async throws -> GatewayBlockingResponse {
        let controller = try directBlockingController(
            expectedIdentity: expectedIdentity,
            currentIdentity: pendingSudoPrompt?.identity
        )
        directBlockingInteractionErrorMessage = nil
        directBlockingInteractionErrorIdentity = nil
        do {
            let response = try await controller.cancelSudo(expectedIdentity: expectedIdentity)
            try validateDirectBlockingController(controller, expectedIdentity: expectedIdentity)
            directBlockingInteractionErrorMessage = nil
            directBlockingInteractionErrorIdentity = nil
            return response
        } catch {
            recordDirectBlockingError(error, controller: controller, expectedIdentity: expectedIdentity, currentIdentity: pendingSudoPrompt?.identity)
            throw error
        }
    }

    private func directBlockingController(
        expectedIdentity: GatewayBlockingPromptIdentity,
        currentIdentity: GatewayBlockingPromptIdentity?
    ) throws -> GatewayConversationController {
        guard usesDirectGateway,
              !directInvalidated,
              directBlockingOriginMatches(expectedIdentity.origin),
              let controller = directConversation,
              controller.storedID == expectedIdentity.storedID,
              controller.profile == expectedIdentity.profile,
              controller.binding?.runtimeID == expectedIdentity.runtimeID,
              currentIdentity == expectedIdentity else {
            throw GatewayBlockingContractError.staleInteraction
        }
        return controller
    }

    private func validateDirectBlockingController(
        _ controller: GatewayConversationController,
        expectedIdentity: GatewayBlockingPromptIdentity
    ) throws {
        guard !directInvalidated,
              directConversation === controller,
              directBlockingOriginMatches(expectedIdentity.origin),
              controller.storedID == expectedIdentity.storedID,
              controller.profile == expectedIdentity.profile,
              controller.binding?.runtimeID == expectedIdentity.runtimeID else {
            throw GatewayBlockingContractError.staleInteraction
        }
    }

    private func directBlockingOriginMatches(_ rawOrigin: String) -> Bool {
        guard let expected = try? AuthManager.normalizedServerURL(from: rawOrigin),
              let current = try? AuthManager.normalizedServerURL(from: server.absoluteString) else {
            return false
        }
        return expected == current
    }

    private func recordDirectBlockingError(
        _ error: Error,
        controller: GatewayConversationController,
        expectedIdentity: GatewayBlockingPromptIdentity,
        currentIdentity: GatewayBlockingPromptIdentity?
    ) {
        guard !directInvalidated,
              directConversation === controller,
              currentIdentity == expectedIdentity else { return }
        directBlockingInteractionErrorMessage = directBlockingErrorMessage(for: error)
        directBlockingInteractionErrorIdentity = expectedIdentity
    }

    private func directBlockingErrorMessage(for error: Error) -> String {
        if let contractError = error as? GatewayBlockingContractError {
            switch contractError {
            case .approvalNotResolved:
                return "Hermes did not confirm that approval. Keep the request open and try again."
            case .staleInteraction:
                return "That Hermes request is no longer active."
            case .malformedApproval, .malformedSecret, .malformedSudo, .unsupportedApprovalChoice, .invalidResponse:
                return "Hermes sent a blocking request this app cannot safely answer."
            }
        }
        if let blockingError = error as? GatewayBlockingError,
           blockingError == .responseInFlight {
            return "A response is already being delivered."
        }
        return "The Hermes response could not be delivered. Try again if the request is still shown."
    }

    @discardableResult
    func respondToDirectClarification(
        _ responseText: String,
        expectedIdentity: GatewayBlockingPromptIdentity
    ) async -> Bool {
        guard usesDirectGateway,
              !directInvalidated,
              !isRespondingToDirectClarification,
              directClarificationPrompt?.gatewayIdentity == expectedIdentity,
              let controller = directConversation else {
            return false
        }

        isRespondingToDirectClarification = true
        directClarificationErrorMessage = nil
        defer { isRespondingToDirectClarification = false }

        do {
            let response = try await controller.respondToBlockingPrompt(
                responseText,
                expectedIdentity: expectedIdentity
            )
            guard !directInvalidated else { return false }
            syncDirectClarificationPrompt()
            if response == .expired {
                guard !directInvalidated,
                      directClarificationPrompt == nil
                        || directClarificationPrompt?.gatewayIdentity == expectedIdentity else {
                    return false
                }
                let message = "That clarification expired before it was answered."
                directClarificationErrorMessage = message
                setDirectClarificationSendError(message)
                return false
            }
            return true
        } catch let error as GatewayBlockingError {
            guard !directInvalidated,
                  directClarificationPrompt?.gatewayIdentity == expectedIdentity else {
                return false
            }
            directClarificationErrorMessage = directClarificationMessage(for: error)
            return false
        } catch {
            guard !directInvalidated,
                  directClarificationPrompt?.gatewayIdentity == expectedIdentity else {
                return false
            }
            lastError = error
            directClarificationErrorMessage = "The clarification could not be delivered. No response was retried."
            return false
        }
    }


    private func applyDirectBtwOutcome(_ outcome: GatewayConversationController.BtwOutcome) {
        switch outcome {
        case .completed(let attemptID, let taskID, let question, let text):
            guard activeBtwAttemptID == attemptID,
                  activeBtwTaskID == nil || activeBtwTaskID == taskID,
                  activeBtwQuestion == question else { return }
            activeBtwTaskID = taskID
            activeBtwAnswer = text
            updateActiveBtwMessage(isLoading: false)
            clearActiveBtwAttempt()
        case .unknown(let attemptID):
            guard activeBtwAttemptID == attemptID else { return }
            activeBtwAnswer = String(localized: "Outcome unknown. Check Hermes before asking again.")
            updateActiveBtwMessage(isLoading: false)
            clearActiveBtwAttempt()
        }
    }

    private func updateActiveBtwMessage(isLoading: Bool) {
        guard let activeBtwMessageID, let activeBtwQuestion else { return }
        updateLocalMessage(
            id: activeBtwMessageID,
            content: Self.btwMessageText(
                question: activeBtwQuestion,
                answer: activeBtwAnswer,
                isLoading: isLoading
            )
        )
    }

    private func clearActiveBtwAttempt() {
        activeBtwAttemptID = nil
        activeBtwTaskID = nil
        activeBtwProfile = nil
        activeBtwMessageID = nil
        activeBtwQuestion = nil
        activeBtwAnswer = ""
    }

    private func failActiveBtwAttempt(_ message: String) {
        guard activeBtwAttemptID != nil else { return }
        activeBtwAnswer = message
        updateActiveBtwMessage(isLoading: false)
        clearActiveBtwAttempt()
    }

    private func applyDirectBackgroundOutcome(
        _ outcome: GatewayConversationController.BackgroundOutcome,
        controller: GatewayConversationController
    ) {
        switch outcome {
        case .completed(let attemptID, let taskID, let prompt, let text):
            guard let attempt = directBackgroundAttempts[attemptID],
                  attempt.taskID == nil || attempt.taskID == taskID,
                  attempt.prompt == prompt,
                  attempt.sessionID == canonicalSessionID,
                  attempt.sessionID == controller.storedID,
                  attempt.profile == controller.profile else { return }
            directBackgroundAttempts.removeValue(forKey: attemptID)
            if directBackgroundStartsInFlight.contains(attemptID) {
                directBackgroundResolutions[attemptID] = .completed
            }
            appendDirectBackgroundResult(
                prompt: prompt, answer: text,
                sessionID: attempt.sessionID, profile: attempt.profile
            )
        case .unknown(let attemptID):
            guard let attempt = directBackgroundAttempts.removeValue(forKey: attemptID) else { return }
            if directBackgroundStartsInFlight.contains(attemptID) {
                directBackgroundResolutions[attemptID] = .unknown
            }
            appendDirectBackgroundResult(
                prompt: attempt.prompt,
                answer: String(localized: "Outcome unknown. Check Hermes before starting it again."),
                sessionID: attempt.sessionID,
                profile: attempt.profile
            )
        }
    }

    private func appendDirectBackgroundResult(
        prompt: String,
        answer: String,
        sessionID: String,
        profile: String
    ) {
        guard !directInvalidated, canonicalSessionID == sessionID,
              directConversation?.storedID == sessionID,
              directConversation?.profile == profile,
              let messageID = appendLocalAssistantMessage(
                Self.backgroundResultText(prompt: prompt, answer: answer)
              ) else { return }
        backgroundLocalRowScopes[messageID] = (sessionID, profile)
    }

    private func failDirectBackgroundAttempts() {
        let attempts = directBackgroundAttempts
        directBackgroundAttempts.removeAll()
        directBackgroundStartsInFlight.removeAll()
        directBackgroundResolutions.removeAll()
        for (_, attempt) in attempts {
            appendDirectBackgroundResult(
                prompt: attempt.prompt,
                answer: String(localized: "Outcome unknown. Check Hermes before starting it again."),
                sessionID: attempt.sessionID,
                profile: attempt.profile
            )
        }
    }

    @discardableResult
    private func appendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool {
        let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return false }

        flushPendingStreamingContent()

        var didAppend = false
        if payload.alreadyStreamed != true {
            didAppend = appendInterimTextIfNeeded(text)
            flushPendingStreamingContent()
        } else if streamingAssistantMessageID == nil {
            // A reconnect can deliver the seal without replaying its deltas.
            // The interim payload is still the authoritative visible segment.
            didAppend = appendAssistantToken(text)
            flushPendingStreamingContent()
        }

        guard let messageID = streamingAssistantMessageID,
              let index = streamingAssistantMessagePosition(for: messageID),
              !(messages[index].content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return didAppend }

        sealedInterimAssistantMessageIDs.insert(messageID)
        streamingAssistantMessageID = nil
        streamingAssistantMessageIndex = nil
        return true
    }

    @discardableResult
    private func appendInterimTextIfNeeded(_ text: String) -> Bool {

        if let streamingAssistantMessageID,
           let index = streamingAssistantMessagePosition(for: streamingAssistantMessageID) {
            let existing = messages[index]
            let currentContent = existing.content ?? ""
            let textToAppend = text
            guard !textToAppend.isEmpty else { return false }

            let shouldUseSeparator = currentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let separator = shouldUseSeparator ? "\n\n" : ""
            replaceStreamingMessage(at: index, with: ChatMessage(
                role: existing.role,
                content: currentContent + separator + textToAppend,
                timestamp: existing.timestamp,
                messageId: existing.messageId,
                name: existing.name,
                toolCallId: existing.toolCallId,
                toolUseId: existing.toolUseId,
                toolCalls: existing.toolCalls,
                contentParts: existing.contentParts,
                reasoning: existing.reasoning,
                attachments: existing.attachments,
                turnTps: existing.turnTps
            ))
            return true
        }

        return appendAssistantToken(text)
    }

    private func prepareStreamingAssistantForTerminal(_ terminalText: String) {
        guard streamingAssistantMessageID == nil,
              let index = messages.lastIndex(where: { message in
                  guard let messageID = message.messageId else { return false }
                  return message.role == "assistant"
                      && sealedInterimAssistantMessageIDs.contains(messageID)
              })
        else {
            _ = ensureStreamingAssistantMessage()
            return
        }

        let interimText = (messages[index].content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = terminalText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Match pinned Desktop behavior: exact/prefix continuity is a
        // compatibility heuristic for a terminal that completes the last
        // sealed segment, not a protocol-level message identity guarantee.
        let isSameAssistantSegment = !interimText.isEmpty && !finalText.isEmpty
            && (finalText == interimText
                || finalText.hasPrefix(interimText)
                || interimText.hasPrefix(finalText))

        if isSameAssistantSegment {
            streamingAssistantMessageID = messages[index].messageId
            streamingAssistantMessageIndex = index
        } else {
            _ = ensureStreamingAssistantMessage()
        }
    }

    private func applyCompletedStreamSession(_ completedSession: SessionDetail) {
        if let completedSessionID = completedSession.sessionId,
           let sessionID,
           completedSessionID != sessionID {
            return
        }

        applyCompressionAnchorMetadata(from: completedSession)

        var didApplyCompletedTranscript = false
        if let completedMessages = completedSession.messages,
           !completedMessages.isEmpty {
            let previousMessages = messages
            let previousMessagesOffset = messagesOffset
            let reloadedMessages = Self.mergingLoadedMessages(
                completedMessages,
                withCachedLocalOptimisticMessages: messages
            )
            applyReloadedMessages(
                reloadedMessages,
                from: completedSession,
                previousMessages: previousMessages,
                previousMessagesOffset: previousMessagesOffset
            )
            didApplyCompletedTranscript = true
        }

        if let title = completedSession.title {
            applyLiveActivitySessionTitle(title)
        }

        currentWorkspace = completedSession.workspace ?? currentWorkspace
        currentModel = completedSession.model ?? currentModel
        currentModelProvider = completedSession.modelProvider ?? currentModelProvider
        currentProfile = completedSession.profile ?? currentProfile

        contextWindowSnapshot = ContextWindowSnapshot(
            contextLength: completedSession.contextLength,
            thresholdTokens: completedSession.thresholdTokens,
            lastPromptTokens: completedSession.lastPromptTokens,
            inputTokens: completedSession.inputTokens,
            outputTokens: completedSession.outputTokens,
            estimatedCost: completedSession.estimatedCost
        )
        if didApplyCompletedTranscript || completedSession.toolCalls != nil {
            let rebuiltToolCallGroups = ToolCallGroup.groups(
                persistedToolCalls: completedSession.toolCalls ?? [],
                messages: messages,
                messageOffset: messagesOffset
            )
            if !liveToolCalls.isEmpty {
                let fallbackAnchorMessageID = currentTurnToolCallFallbackAnchorMessageID()
                setCompletedToolCallGroups(ToolCallGroup.coalescingByAssistantTurn(
                    ToolCallGroup.merging(
                        primaryGroups: rebuiltToolCallGroups,
                        fallbackGroups: [
                            ToolCallGroup(
                                id: "completed-live-tools-\(fallbackAnchorMessageID ?? "unanchored")",
                                anchorMessageID: fallbackAnchorMessageID,
                                toolCalls: liveToolCalls
                            )
                        ]
                    ),
                    messages: messages,
                    messageOffset: messagesOffset
                ))
            } else {
                setCompletedToolCallGroups(rebuiltToolCallGroups)
            }
            liveToolCalls = []
        }

        if didApplyCompletedTranscript {
            completedReasoningGroups = []
            liveReasoningText = ""
            toolCallAnchorMessageID = nil
            reasoningAnchorMessageID = nil
            attachmentCoordinator.removeAllLocalPreviews()
            scheduleStreamingScrollTrigger()
        }
    }

    private func setCompletedToolCallGroups(_ groups: [ToolCallGroup]) {
        let lookup = ToolCallGroupAnchorLookup(groups: groups)
        guard completedToolCallGroups != groups else { return }

        completedToolCallGroups = groups
        completedToolCallGroupLookup = lookup
    }

    private func appendCompletedToolCallGroup(_ group: ToolCallGroup) {
        setCompletedToolCallGroups(completedToolCallGroups + [group])
    }

    private func archiveLiveToolCallsIfNeeded() {
        guard !liveToolCalls.isEmpty else { return }

        appendCompletedToolCallGroup(
            ToolCallGroup(
                anchorMessageID: toolCallAnchorMessageID,
                toolCalls: liveToolCalls
            )
        )
    }

    private func currentTurnToolCallFallbackAnchorMessageID() -> String? {
        if let toolCallAnchorMessageID,
           messages.enumerated().contains(where: { index, message in
               TranscriptTurnClassifier.anchorID(for: message, at: index, messageOffset: messagesOffset) == toolCallAnchorMessageID
           }) {
            return toolCallAnchorMessageID
        }

        return TranscriptTurnClassifier.currentTurnAssistantAnchorIDs(in: messages, messageOffset: messagesOffset).first
            ?? Self.latestAssistantAnchorID(in: messages, messageOffset: messagesOffset)
    }

    private func archiveLiveReasoningIfNeeded() {
        guard !liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        completedReasoningGroups.append(
            ReasoningGroup(
                anchorMessageID: reasoningAnchorMessageID,
                text: liveReasoningText
            )
        )
    }

    @discardableResult
    private func ensureStreamingAssistantMessage() -> String {
        if let streamingAssistantMessageID {
            return streamingAssistantMessageID
        }

        let messageID = "stream-\(UUID().uuidString)"
        streamingAssistantMessageID = messageID
        appendStreamingMessage(
            ChatMessage(
                role: "assistant",
                content: "",
                timestamp: Date().timeIntervalSince1970,
                messageId: messageID
            )
        )
        streamingAssistantMessageIndex = messages.indices.last
        return messageID
    }

    /// Resolve the active row once, then validate the cached position in O(1)
    /// on every token. Structural transcript changes may shift the row; those
    /// pay for one backward lookup rather than one full scan per flush.
    private func streamingAssistantMessagePosition(for messageID: String) -> Int? {
        if let index = streamingAssistantMessageIndex,
           messages.indices.contains(index),
           messages[index].messageId == messageID {
            return index
        }

        let index = messages.lastIndex(where: { $0.messageId == messageID })
        streamingAssistantMessageIndex = index
        return index
    }

    @discardableResult
    private func appendReasoning(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        // Match appendAssistantToken's progress contract: return true for a
        // nonempty received chunk while deferring mutation to the coalesced flush.
        _ = ensureStreamingAssistantMessage()
        pendingReasoningTextBuffer.append(text)
        scheduleStreamingContentFlush()
        return true
    }

    @discardableResult
    private func flushReasoningChunks() -> Bool {
        guard !pendingReasoningTextBuffer.isEmpty else { return false }

        // Reasoning chunks flush in their received order as one concatenation.
        let appendedText = pendingReasoningTextBuffer
        pendingReasoningTextBuffer = ""

        let messageID = ensureStreamingAssistantMessage()
        if reasoningAnchorMessageID == nil {
            reasoningAnchorMessageID = messageID
        }

        liveReasoningText += appendedText
        return true
    }

    @discardableResult
    private func appendToolCall(_ payload: ToolStreamEvent) -> Bool {
        let messageID = ensureStreamingAssistantMessage()
        if toolCallAnchorMessageID == nil {
            toolCallAnchorMessageID = messageID
        }

        liveToolCalls.append(
            ToolCall(
                id: payload.stableID ?? "live-tool-\(UUID().uuidString)",
                name: payload.name,
                preview: payload.preview,
                args: payload.args
            )
        )
        return true
    }

    @discardableResult
    private func completeToolCall(_ payload: ToolStreamEvent) -> Bool {
        let messageID = ensureStreamingAssistantMessage()
        if toolCallAnchorMessageID == nil {
            toolCallAnchorMessageID = messageID
        }

        guard let index = liveToolCallCompletionIndex(for: payload) else {
            liveToolCalls.append(
                ToolCall(
                    id: payload.stableID ?? "live-tool-\(UUID().uuidString)",
                    name: payload.name,
                    preview: payload.preview,
                    args: payload.args,
                    duration: payload.duration,
                    isError: payload.isError,
                    isCompleted: true
                )
            )
            return true
        }

        liveToolCalls[index] = liveToolCalls[index].applyingCompletionPayload(payload)
        return true
    }

    private func liveToolCallCompletionIndex(for payload: ToolStreamEvent) -> Int? {
        if let stableID = payload.stableID?.nonEmptyToolMatchText,
           let stableIndex = liveToolCalls.lastIndex(where: { toolCall in
               !toolCall.isCompleted && toolCall.matchesStableToolID(stableID)
           }) {
            return stableIndex
        }

        return liveToolCalls.lastIndex { toolCall in
            !toolCall.isCompleted && (payload.name == nil || toolCall.name == payload.name)
        }
    }

    @discardableResult
    private func appendAssistantToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }

        // A nonempty received chunk is a synchronous progress signal for the
        // watchdog while transcript mutation stays behind the coalesced flush.
        _ = ensureStreamingAssistantMessage()
        pendingAssistantTextBuffer.append(token)
        scheduleStreamingContentFlush()
        return true
    }

    @discardableResult
    private func flushAssistantTokens(maxWordUnits: Int? = nil) -> Bool {
        guard !pendingAssistantTextBuffer.isEmpty else { return false }

        // A word-unit limit moves only the head of the buffer into the visible
        // message; the tail stays pending so paced rendering retains received text.
        let pendingText = pendingAssistantTextBuffer
        let appendedContent: String
        if let maxWordUnits {
            let (head, tail) = StreamingWordDrain.splitAtUnitBoundary(pendingText, unitCount: maxWordUnits)
            guard !head.isEmpty else { return false }
            appendedContent = head
            pendingAssistantTextBuffer = tail
        } else {
            appendedContent = pendingText
            pendingAssistantTextBuffer = ""
        }

        let messageID = ensureStreamingAssistantMessage()
        if !liveReasoningText.isEmpty && reasoningAnchorMessageID == nil {
            reasoningAnchorMessageID = messageID
        }
        if !liveToolCalls.isEmpty && toolCallAnchorMessageID == nil {
            toolCallAnchorMessageID = messageID
        }

        if let index = streamingAssistantMessagePosition(for: messageID) {
            let existing = messages[index]
            replaceStreamingMessage(
                at: index,
                with: ChatMessage(
                    role: existing.role,
                    content: (existing.content ?? "") + appendedContent,
                    timestamp: existing.timestamp,
                    messageId: existing.messageId,
                    name: existing.name,
                    toolCallId: existing.toolCallId,
                    toolUseId: existing.toolUseId,
                    toolCalls: existing.toolCalls,
                    contentParts: existing.contentParts,
                    reasoning: existing.reasoning,
                    attachments: existing.attachments,
                    turnTps: existing.turnTps
                )
            )
            return true
        }

        messages.append(
            ChatMessage(
                role: "assistant",
                content: appendedContent,
                timestamp: Date().timeIntervalSince1970,
                messageId: messageID
            )
        )
        return true
    }

    private func flushPinnedLocalNoticesToTranscript() {
        let notices = pinnedLocalNotices
        pinnedLocalNotices.removeAll()
        for notice in notices {
            appendLocalNoticeMessage(notice)
        }
    }

    @discardableResult
    private func enqueueQueuedSlashMessage(
        _ text: String,
        attachments: [PendingAttachment],
        atFront: Bool = false
    ) -> Int {
        let message = QueuedSlashMessage(text: text, attachments: attachments)
        if atFront {
            queuedSlashMessages.insert(message, at: 0)
        } else {
            queuedSlashMessages.append(message)
        }
        return queuedSlashMessages.count
    }

    private func drainQueuedSlashMessageIfIdle() {
        guard activeStreamID == nil,
              !isStartingChat,
              !isDrainingQueuedSlashMessage,
              !queuedSlashMessages.isEmpty
        else { return }

        let next = queuedSlashMessages.removeFirst()
        isDrainingQueuedSlashMessage = true

        Task { @MainActor in
            let savedAttachments = attachmentCoordinator.pendingAttachments
            attachmentCoordinator.replacePendingAttachments(next.attachments)
            let sent = await sendMessage(next.text)
            if !sent {
                queuedSlashMessages.insert(next, at: 0)
            }
            attachmentCoordinator.replacePendingAttachments(savedAttachments)
            isDrainingQueuedSlashMessage = false
            // Only chain-drain after a *successful* send. A failed send requeues the message and
            // waits for the next natural trigger (a queue append, stream completion, or an explicit
            // user send) instead of immediately re-firing the drain — which, with a persistently
            // failing send, was a tight retry loop hammering the network and CPU (issue #202).
            if sent, activeStreamID == nil {
                drainQueuedSlashMessageIfIdle()
            }
        }
    }

    private func applyLiveActivitySessionTitle(_ title: String) {
        displayTitle = Self.displayTitle(from: title)
        liveActivityManager.update(.sessionTitle(displayTitle))
    }

    private func finishListening() {
        activeListeningUtteranceID = nil
        activeListenPlayerID = nil
        activeListenRequestID = nil
        listenAudioPlayer = nil
        listeningMessageID = nil
        clearListenPlaybackState()
        // Release the shared session so any audio we interrupted can resume. Safe to
        // call when nothing was speaking: `setActive(false)` no-ops via `try?`.
        listenAudioSession.deactivate()
    }

    private func beginListenPlaybackPreparation(for context: MessageActionContext) {
        listenPlaybackTitle = String(localized: "Semreh response \(context.visibleIndex + 1)")
        listenPlaybackPhase = .loading
        listenPlaybackElapsedTime = 0
        listenPlaybackDuration = 0
        listenPlaybackScrubTime = nil
        stopListenPlaybackTicker()
        listenRemoteControlCenter.clear()
    }

    private func clearListenPlaybackState() {
        listenPlaybackPhase = .idle
        listenPlaybackElapsedTime = 0
        listenPlaybackDuration = 0
        listenPlaybackScrubTime = nil
        stopListenPlaybackTicker()
        listenRemoteControlCenter.clear()
    }

    /// Speaks `text` with the on-device `AVSpeechSynthesizer` — the pre-#15 Listen
    /// path, kept as the offline/failure fallback for server TTS.
    private func speakWithOnDeviceSynthesizer(_ text: String) {
        // Route speech to the speaker (not the receiver/earpiece) immediately before
        // speech starts — not when the Listen tap lands — so a slow `/api/audio/speak` fetch
        // never interrupts other audio while Semreh is silent (review on #35).
        // Released again in `finishListening()` once playback ends. See #252.
        listenAudioSession.activate()
        let speechSynthesizer = speechSynthesizerForListening()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        activeListeningUtteranceID = ObjectIdentifier(utterance)
        speechSynthesizer.speak(utterance)
    }

    /// Attempts to start playback of server-synthesized audio bytes. Returns
    /// `false` when the bytes can't be decoded into a player or playback fails to
    /// start, so the caller can fall back to the on-device synthesizer.
    private func startServerAudioPlayback(_ audioData: Data, title: String) -> Bool {
        guard let player = try? serverTTSAudioPlayerFactory(audioData) else {
            return false
        }

        let playerID = ObjectIdentifier(player)
        player.onFinish = { [weak self] in
            self?.handleListenPlayerCompletion(for: playerID)
        }
        player.prepareToPlay()
        player.rate = Float(listenPlaybackSpeed.rawValue)
        listenPlaybackTitle = title
        listenPlaybackElapsedTime = player.currentTime
        listenPlaybackDuration = player.duration
        listenPlaybackScrubTime = nil
        configureListenRemoteControls()

        // Activate the session only once decodable audio is in hand, immediately
        // before playback, so the network wait never held it (review on #35). If
        // `play()` still fails, the on-device fallback re-activates for itself —
        // `activate()` is idempotent, and `finishListening()` releases it either way.
        listenAudioSession.activate()
        guard player.play() else {
            return false
        }

        listenAudioPlayer = player
        activeListenPlayerID = playerID
        listenPlaybackPhase = .playing
        startListenPlaybackTicker()
        updateListenPlaybackProgressFromPlayer()
        updateListenNowPlaying()
        return true
    }

    private func pauseListenPlayback() {
        guard listenPlaybackPhase == .playing, let player = listenAudioPlayer else { return }
        player.pause()
        updateListenPlaybackProgressFromPlayer()
        listenPlaybackPhase = .paused
        stopListenPlaybackTicker()
        updateListenNowPlaying()
    }

    private func resumeListenPlayback() {
        guard listenPlaybackPhase == .paused, let player = listenAudioPlayer else { return }
        player.rate = Float(listenPlaybackSpeed.rawValue)
        listenAudioSession.activate()
        guard player.play() else { return }
        listenPlaybackPhase = .playing
        startListenPlaybackTicker()
        updateListenPlaybackProgressFromPlayer()
        updateListenNowPlaying()
    }

    private func seekListenPlayback(to time: TimeInterval) {
        guard let player = listenAudioPlayer else { return }
        let boundedTime = boundedListenPlaybackTime(time)
        player.currentTime = boundedTime
        listenPlaybackElapsedTime = boundedTime
        updateListenNowPlaying()
    }

    private func boundedListenPlaybackTime(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        let upperBound = listenPlaybackDuration > 0 ? listenPlaybackDuration : max(time, 0)
        return min(max(0, time), upperBound)
    }

    private func startListenPlaybackTicker() {
        stopListenPlaybackTicker()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateListenPlaybackProgressFromPlayer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        listenPlaybackTicker = timer
    }

    private func stopListenPlaybackTicker() {
        listenPlaybackTicker?.invalidate()
        listenPlaybackTicker = nil
    }

    private func updateListenPlaybackProgressFromPlayer() {
        guard listenPlaybackScrubTime == nil, let player = listenAudioPlayer else { return }
        listenPlaybackElapsedTime = boundedListenPlaybackTime(player.currentTime)
        listenPlaybackDuration = max(0, player.duration)
    }

    private func configureListenRemoteControls() {
        listenRemoteControlCenter.configure(
            play: { [weak self] in self?.resumeListenPlayback() },
            pause: { [weak self] in self?.pauseListenPlayback() },
            togglePlayPause: { [weak self] in self?.toggleListenPlaybackPlayPause() },
            changePlaybackPosition: { [weak self] position in self?.seekListenPlayback(to: position) }
        )
    }

    private func updateListenNowPlaying() {
        guard listenPlaybackPhase == .playing || listenPlaybackPhase == .paused else { return }
        listenRemoteControlCenter.update(ListenNowPlayingSnapshot(
            title: listenPlaybackTitle,
            duration: listenPlaybackDuration,
            elapsedTime: listenPlaybackElapsedTime,
            speed: listenPlaybackSpeed,
            isPlaying: listenPlaybackPhase == .playing
        ))
    }

    /// Completion routed from the server-TTS audio player. Mirrors
    /// `handleListenCompletion(for:)`: a stale callback from a superseded player
    /// must not clear the new listen state or deactivate the session.
    private func handleListenPlayerCompletion(for playerID: ObjectIdentifier) {
        guard playerID == activeListenPlayerID else { return }
        finishListening()
    }

    /// Completion routed from the speech-synthesizer delegate. Switching messages mid-
    /// playback cancels the previous utterance, whose `didCancel` arrives asynchronously
    /// *after* the next utterance has started — ignore that stale callback so we don't
    /// clear the new listen state or deactivate the session under live speech. See #252.
    private func handleListenCompletion(for utteranceID: ObjectIdentifier) {
        guard utteranceID == activeListeningUtteranceID else { return }
        finishListening()
    }

    private func speechSynthesizerForListening() -> any ChatSpeechSynthesizing {
        if let speechSynthesizer {
            return speechSynthesizer
        }

        let speechSynthesizer = speechSynthesizerFactory()
        if speechDelegate == nil {
            speechDelegate = SpeechSynthesizerDelegate { [weak self] finishedUtteranceID in
                self?.handleListenCompletion(for: finishedUtteranceID)
            }
        }
        speechSynthesizer.delegate = speechDelegate
        self.speechSynthesizer = speechSynthesizer
        return speechSynthesizer
    }

    private func statusTokenLine() -> String {
        guard let contextWindowSnapshot else {
            return String(localized: "Unavailable")
        }

        let input = contextWindowSnapshot.inputTokens ?? 0
        let output = contextWindowSnapshot.outputTokens ?? 0
        let total = input + output
        let cost = contextWindowSnapshot.estimatedCost ?? 0

        if total == 0 && cost == 0 {
            return String(localized: "No token usage available")
        }

        let inputText = Self.formatTokenCount(input)
        let outputText = Self.formatTokenCount(output)
        guard cost > 0 else {
            return String(localized: "\(inputText) in / \(outputText) out")
        }

        return String(localized: "\(inputText) in / \(outputText) out (~\(cost.formattedCost()))")
    }

    private func providerFromModel(_ model: String) -> String? {
        let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count > 1 else { return nil }
        return parts[0]
    }

    private static func formatTokenCount(_ value: Int) -> String {
        value.formatted(.number)
    }

    private static func displayTitle(from title: String?) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedTitle, !trimmedTitle.isEmpty else {
            return String(localized: "Untitled Session")
        }
        return trimmedTitle
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func compactModelTitle(_ modelID: String) -> String {
        let raw = modelID.split(separator: ":").last.map(String.init) ?? modelID
        let suffix = raw.split(separator: "/").last.map(String.init) ?? raw
        return suffix.replacingOccurrences(of: "gpt-", with: "GPT-", options: [.caseInsensitive])
    }


    private static func btwMessageText(question: String, answer: String?, isLoading: Bool) -> String {
        let trimmedAnswer = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body: String
        if trimmedAnswer.isEmpty {
            body = isLoading ? "..." : String(localized: "No answer produced.")
        } else {
            body = trimmedAnswer
        }

        return """
        **BTW** \(question)

        \(body)
        """
    }

    private static func backgroundResultText(prompt: String, answer: String?) -> String {
        let trimmedAnswer = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = trimmedAnswer.isEmpty ? String(localized: "No answer produced.") : trimmedAnswer
        let summary = prompt.count > 80 ? "\(prompt.prefix(80))..." : prompt

        return """
        **Background** \(summary)

        \(body)
        """
    }

    private static let slashCommandHelpText = String(localized: """
    Available mobile commands:

    `/help` - Show this command list.
    `/clear` - Clear the local transcript.
    `/stop` - Stop the current response.
    `/new` - Open a fresh session.
    `/model <id>` - Switch this session's model.
    `/workspace <path>` - Switch this session's workspace.
    `/reasoning <level>` - Set reasoning display or effort.
    `/title <text>` - Rename this session.
    `/skills [query]` - Search available skills.
    `/queue <message>` - Queue a message for the next turn.
    `/steer <message>` - Steer the active response.
    `/interrupt <message>` - Stop the active response and send a new message.
    `/status` - Show session status.
    `/btw <question>` - Ask a side question without changing this chat.
    `/background <prompt>` - Run a parallel task and post the result here.
    `/bg <prompt>` - Alias for `/background`.
    `/branch [name]` - Fork this conversation.
    `/fork [name]` - Alias for `/branch`.
    `/compress [focus]` - Compress this session's context.
    `/compact [focus]` - Alias for `/compress`.
    `/undo` - Undo the last exchange.
    `/retry` - Retry the last turn.
    """)
}

extension ChatViewModel: ChatAttachmentCoordinatorDelegate {
    var attachmentSessionID: String? { sessionID }
}

private struct QueuedSlashMessage {
    let text: String
    let attachments: [PendingAttachment]
}

struct ReasoningGroup: Identifiable, Equatable {
    let id: String
    let anchorMessageID: String?
    let text: String
    /// Per-arrival reasoning segments retained for the expanded Thinking view.
    /// `text` stays the canonical joined form (collapse summaries and echo
    /// stripping keep reading it); rendering walks the segments instead.
    let segments: [String]

    init(id: String = UUID().uuidString, anchorMessageID: String?, text: String, segments: [String] = []) {
        self.id = id
        self.anchorMessageID = anchorMessageID
        self.text = text
        self.segments = segments
    }
}

struct ReasoningGroupAnchorLookup: Equatable {
    private let groupsByAnchor: [String?: [ReasoningGroup]]

    init(groups: [ReasoningGroup] = []) {
        groupsByAnchor = Dictionary(grouping: groups) { group in
            group.anchorMessageID
        }
    }

    func groups(anchorMessageID: String?) -> [ReasoningGroup] {
        groupsByAnchor[anchorMessageID] ?? []
    }
}

/// Ephemeral UI evidence of this view model's exact local append. Never persisted
/// or used as a delivery acknowledgement, routing identity, or scroll request.
struct OutgoingInsertionEvent: Equatable {
    let id = UUID()
    let scope: UUID
    let messageID: String
    let sequence: UInt64
}

/// Main-thread presentation ledger. Consumption deliberately does not publish a
/// view update: the already-mounted bubble owns its own animation completion.
final class OutgoingInsertionLedger {
    private var scope: UUID?
    private var observedThrough: UInt64 = 0
    private var consumedThrough: UInt64 = 0

    func mount(scope: UUID?, through sequence: UInt64) {
        self.scope = scope
        observedThrough = sequence
        consumedThrough = sequence
    }

    func unmount() {
        scope = nil
    }

    func discardPending(through sequence: UInt64) {
        observedThrough = max(observedThrough, sequence)
    }

    func isEligible(_ event: OutgoingInsertionEvent?, messageID: String,
                    role: String?, allowed: Bool) -> Bool {
        guard allowed, role == "user", let event, let scope,
              event.scope == scope, event.messageID == messageID,
              event.sequence > observedThrough,
              event.sequence > consumedThrough else { return false }
        return true
    }

    func claim(_ event: OutgoingInsertionEvent?, messageID: String,
               role: String?, allowed: Bool) -> Bool {
        guard isEligible(event, messageID: messageID, role: role, allowed: allowed),
              let event else { return false }
        consumedThrough = event.sequence
        return true
    }
}

/// Stable identity used by the Direct transcript path. Durable backend IDs
/// must be namespaced before they become SwiftUI row IDs so they cannot
/// collide with the legacy position-based transcript IDs.
enum TranscriptRenderIdentity {
    static let directPrefix = "transcript:row:"
    private static let directFallbackPrefix = "transcript:row:fallback:"

    static func directID(for canonicalMessageID: String?) -> String? {
        guard let canonicalMessageID,
              !canonicalMessageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return "\(directPrefix)\(canonicalMessageID)"
    }

    /// Direct history normally supplies a durable message ID, but tolerant
    /// decoding also admits older/partial rows without one. Falling back to a
    /// loaded index makes every existing SwiftUI row change identity when an
    /// older page is prepended, which defeats the measured anchor-preservation
    /// path. Use a deterministic content fingerprint for those exceptional
    /// rows instead. The per-fingerprint occurrence suffix keeps duplicate
    /// rows distinct within a rendered transcript.
    static func directFallbackID(for message: ChatMessage, occurrence: Int) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037

        func combine(_ value: String?) {
            for byte in (value ?? "<nil>").utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            // Preserve field boundaries ("ab" + "c" must not equal "a" + "bc").
            hash ^= 0xff
            hash &*= 1_099_511_628_211
        }

        combine(message.role)
        combine(message.timestamp.map { String($0.bitPattern, radix: 16) })
        combine(message.content)
        combine(message.name)
        combine(message.toolCallId)
        combine(message.toolUseId)
        return "\(directFallbackPrefix)\(String(hash, radix: 16)):\(occurrence)"
    }
}

/// Session-scoped identity for the exceptional direct-history rows that have no
/// durable Hermes ID. The ledger retains only the current rendered window. An
/// explicit older-page prepend resolves the otherwise unknowable lineage of
/// identical rows from the suffix; ordinary tail growth resolves it from the
/// prefix. A scope change drops every prior assignment.
final class DirectFallbackRenderIdentityLedger {
    private struct Entry {
        let fingerprint: String
        let renderID: String
    }

    private var scope: String?
    private var entries: [Entry] = []
    private var scopeGeneration: UInt64 = 0
    private var nextSequence: UInt64 = 0

    func renderIDs(
        for messages: [(loadedIndex: Int, message: ChatMessage)],
        scope newScope: String?,
        isOlderPagePrepend: Bool
    ) -> [Int: String] {
        guard let newScope else {
            reset()
            return Dictionary(uniqueKeysWithValues: messages.map {
                ($0.loadedIndex, TranscriptRenderIdentity.directFallbackID(for: $0.message, occurrence: $0.loadedIndex))
            })
        }
        if scope != newScope {
            scope = newScope
            entries.removeAll(keepingCapacity: true)
            scopeGeneration &+= 1
            nextSequence = 0
        }

        let fingerprints = messages.map {
            TranscriptRenderIdentity.directFallbackID(for: $0.message, occurrence: 0)
        }
        var reconciled = fingerprints.map { Entry(fingerprint: $0, renderID: "") }

        let oldFingerprints = entries.map(\.fingerprint)
        let sharedCount = min(entries.count, fingerprints.count)
        let rawPrefixCount = sharedPrefixLength(oldFingerprints, fingerprints)
        let rawSuffixCount = sharedSuffixLength(oldFingerprints, fingerprints)
        // Older pages are known head insertions, while a smaller ordinary
        // window is normally the newest suffix. Favoring that side resolves
        // equal duplicate rows deterministically without scanning candidate
        // offsets or allocating an Array slice for every offset.
        // A middle deletion of indistinguishable ID-less rows has no
        // recoverable lineage; only the proven prefix/suffix is retained.
        let preferSuffix = isOlderPagePrepend || fingerprints.count < entries.count
        let suffixCount: Int
        let prefixCount: Int
        if preferSuffix {
            suffixCount = min(rawSuffixCount, sharedCount)
            prefixCount = min(rawPrefixCount, sharedCount - suffixCount)
        } else {
            prefixCount = min(rawPrefixCount, sharedCount)
            suffixCount = min(rawSuffixCount, sharedCount - prefixCount)
        }

        for index in 0..<prefixCount {
            reconciled[index] = entries[index]
        }
        if suffixCount > 0 {
            let newStart = fingerprints.count - suffixCount
            let oldStart = entries.count - suffixCount
            for offset in 0..<suffixCount {
                reconciled[newStart + offset] = entries[oldStart + offset]
            }
        }

        for index in reconciled.indices where reconciled[index].renderID.isEmpty {
            nextSequence &+= 1
            reconciled[index] = Entry(
                fingerprint: fingerprints[index],
                renderID: "\(fingerprints[index]):ledger:\(scopeGeneration):\(nextSequence)"
            )
        }
        entries = reconciled
        return Dictionary(uniqueKeysWithValues: zip(messages, reconciled).map {
            ($0.0.loadedIndex, $0.1.renderID)
        })
    }

    private func sharedPrefixLength(_ lhs: [String], _ rhs: [String]) -> Int {
        let limit = min(lhs.count, rhs.count)
        var count = 0
        while count < limit, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }

    private func sharedSuffixLength(_ lhs: [String], _ rhs: [String]) -> Int {
        let limit = min(lhs.count, rhs.count)
        var count = 0
        while count < limit,
              lhs[lhs.count - count - 1] == rhs[rhs.count - count - 1] {
            count += 1
        }
        return count
    }

    private func reset() {
        scope = nil
        entries.removeAll(keepingCapacity: false)
        nextSequence = 0
    }
}

struct TranscriptMessage: Identifiable, Equatable {
    let loadedIndex: Int
    let renderID: String
    let anchorID: String
    let message: ChatMessage
    /// Presentation-only direct attachment projection. `message.content` remains
    /// the canonical raw text for actions, caching, recovery, and persistence.
    let attachmentDisplayContent: String?

    init(
        loadedIndex: Int,
        renderID: String,
        anchorID: String,
        message: ChatMessage,
        attachmentDisplayContent: String? = nil
    ) {
        self.loadedIndex = loadedIndex
        self.renderID = renderID
        self.anchorID = anchorID
        self.message = message
        self.attachmentDisplayContent = attachmentDisplayContent
    }

    var id: String { renderID }
}

/// Display model for the synthesized "Context compaction · Reference only" card.
struct CompressionReferenceCard: Equatable {
    let referenceText: String
    /// `renderID` of the transcript row the card renders directly after;
    /// nil places the card above the loaded transcript.
    let afterRenderID: String?
}

struct MessageActionContext: Equatable, Identifiable {
    var id: String { messageID }

    enum Role: Equatable {
        case user
        case assistant
    }

    let role: Role
    let visibleIndex: Int
    let fullHistoryIndex: Int
    let keepCountThroughMessage: Int
    let messageID: String
    let copyText: String
    let listenText: String?

    init?(message: ChatMessage, visibleIndex: Int, messagesOffset: Int?) {
        guard visibleIndex >= 0 else { return nil }

        switch message.role {
        case "user":
            role = .user
        case "assistant":
            role = .assistant
        default:
            return nil
        }

        let content = message.content ?? ""
        guard !content.isEmpty else { return nil }

        self.visibleIndex = visibleIndex
        fullHistoryIndex = max(0, messagesOffset ?? 0) + visibleIndex
        keepCountThroughMessage = fullHistoryIndex + 1
        messageID = message.id
        copyText = content
        listenText = role == .assistant ? SpeechTextNormalizer.normalizedAssistantText(content) : nil
    }
}

extension ChatViewModel {
    nonisolated static func reasoningDisplayGroups(
        messages: [ChatMessage],
        messageOffset: Int? = nil,
        archivedGroups: [ReasoningGroup]
    ) -> [ReasoningGroup] {
        let assistantMessagesByID = messages.enumerated().reduce(into: [String: ChatMessage]()) { result, entry in
            let message = entry.element
            guard message.role == "assistant" else { return }
            result[TranscriptTurnClassifier.anchorID(for: message, at: entry.offset, messageOffset: messageOffset)] = message
        }

        var turnKeysByMessageID: [String: String] = [:]
        var currentTurnKey = "turn:start"
        for (messageIndex, message) in messages.enumerated() {
            if TranscriptTurnClassifier.isUserTurnBoundary(message) {
                if let messageID = message.messageId?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !messageID.isEmpty {
                    currentTurnKey = "turn:user:\(messageID)"
                } else if let timestamp = message.timestamp {
                    currentTurnKey = "turn:user:timestamp:\(timestamp)"
                } else {
                    let absoluteIndex = max(0, messageOffset ?? 0) + messageIndex
                    currentTurnKey = "turn:user:raw:\(absoluteIndex):\(normalizedReasoningKey(message.content ?? ""))"
                }
            }

            if message.role == "assistant" {
                turnKeysByMessageID[TranscriptTurnClassifier.anchorID(
                    for: message,
                    at: messageIndex,
                    messageOffset: messageOffset
                )] = currentTurnKey
            }
        }

        var buildersByTurnKey: [String: ReasoningDisplayBuilder] = [:]
        var turnOrder: [String] = []

        func append(text: String, anchorMessageID: String?, turnKey: String, visibleText: String?) {
            guard let text = strippedVisibleAssistantEcho(fromReasoning: text, visibleText: visibleText) else {
                return
            }

            if buildersByTurnKey[turnKey] == nil {
                buildersByTurnKey[turnKey] = ReasoningDisplayBuilder(turnKey: turnKey)
                turnOrder.append(turnKey)
            }
            buildersByTurnKey[turnKey]?.append(
                text: text,
                anchorMessageID: anchorMessageID,
                visibleText: visibleText
            )
        }

        for group in archivedGroups {
            let visibleText = group.anchorMessageID.flatMap { assistantMessagesByID[$0]?.content }
            append(
                text: group.text,
                anchorMessageID: group.anchorMessageID,
                turnKey: group.anchorMessageID.flatMap { turnKeysByMessageID[$0] } ?? "archived:\(group.anchorMessageID ?? group.id)",
                visibleText: visibleText,
            )
        }

        for (messageIndex, message) in messages.enumerated() where message.role == "assistant" {
            let anchorID = TranscriptTurnClassifier.anchorID(
                for: message,
                at: messageIndex,
                messageOffset: messageOffset
            )
            let turnKey = turnKeysByMessageID[anchorID] ?? "message:\(anchorID)"
            if message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
               buildersByTurnKey[turnKey] != nil {
                buildersByTurnKey[turnKey]?.updateAnchor(anchorID)
            }
            for text in reasoningTexts(from: message) {
                append(
                    text: text,
                    anchorMessageID: anchorID,
                    turnKey: turnKey,
                    visibleText: message.content,
                )
            }
        }

        return turnOrder.compactMap { turnKey in
            guard let builder = buildersByTurnKey[turnKey] else { return nil }
            return builder.group
        }
    }

    nonisolated static func cacheMessageWindow(from messages: [ChatMessage]) -> [ChatMessage] {
        Array(messages.suffix(messagePageLimit))
    }

    nonisolated static func transcriptMessages(from messages: [ChatMessage], messageOffset: Int? = nil) -> [TranscriptMessage] {
        transcriptMessages(from: messages, messageOffset: messageOffset, hidingStreamingAssistantID: nil)
    }

    nonisolated static func transcriptMessages(
        from messages: [ChatMessage],
        messageOffset: Int? = nil,
        hidingStreamingAssistantID streamingAssistantID: String?,
        preferDurableIDs: Bool = false,
        fallbackLedger: DirectFallbackRenderIdentityLedger? = nil,
        fallbackScope: String? = nil,
        isOlderPagePrepend: Bool = false
    ) -> [TranscriptMessage] {
        let offset = max(0, messageOffset ?? 0)
        var transcriptMessages: [TranscriptMessage] = []
        transcriptMessages.reserveCapacity(messages.count)
        var directFallbackOccurrences: [String: Int] = [:]
        let fallbackRows: [(loadedIndex: Int, message: ChatMessage)] = messages.enumerated().compactMap { loadedIndex, message in
            guard preferDurableIDs,
                  message.role != "tool",
                  !TranscriptTurnClassifier.isToolResultOnlyMessage(message),
                  TranscriptRenderIdentity.directID(for: message.messageId) == nil
            else { return nil }
            if let streamingAssistantID, message.messageId == streamingAssistantID { return nil }
            return (loadedIndex: loadedIndex, message: message)
        }
        let ledgerRenderIDs = fallbackLedger?.renderIDs(
            for: fallbackRows,
            scope: fallbackScope,
            isOlderPagePrepend: isOlderPagePrepend
        ) ?? [:]

        for (loadedIndex, message) in messages.enumerated() {
            guard message.role != "tool" else { continue }
            guard !TranscriptTurnClassifier.isToolResultOnlyMessage(message) else { continue }
            if let streamingAssistantID, message.messageId == streamingAssistantID {
                continue
            }

            let anchorID = TranscriptTurnClassifier.anchorID(
                for: message,
                at: loadedIndex,
                messageOffset: messageOffset
            )
            let absoluteIndex = offset + loadedIndex
            let renderID: String
            if preferDurableIDs, TranscriptRenderIdentity.directID(for: message.messageId) == nil {
                let fallbackKey = TranscriptRenderIdentity.directFallbackID(for: message, occurrence: 0)
                let occurrence = directFallbackOccurrences[fallbackKey, default: 0]
                directFallbackOccurrences[fallbackKey] = occurrence + 1
                let deterministicRenderID = TranscriptRenderIdentity.directFallbackID(
                    for: message,
                    occurrence: occurrence
                )
                renderID = ledgerRenderIDs[loadedIndex] ?? deterministicRenderID
            } else {
                renderID = transcriptRenderID(
                    for: message,
                    absoluteIndex: absoluteIndex,
                    preferDurableID: preferDurableIDs
                )
            }

            transcriptMessages.append(TranscriptMessage(
                loadedIndex: loadedIndex,
                renderID: renderID,
                anchorID: anchorID,
                message: message,
                attachmentDisplayContent: preferDurableIDs
                    ? directAttachmentDisplayContent(for: message)
                    : nil
            ))
        }

        return transcriptMessages
    }

    nonisolated private static func directAttachmentDisplayContent(for message: ChatMessage) -> String? {
        guard message.role == "user" else { return nil }

        let projection: DirectHermesMessageAttachmentProjection?
        if let parts = message.contentParts {
            projection = DirectHermesMessageAttachmentProjection.project(userParts: parts)
        } else if let content = message.content {
            projection = DirectHermesMessageAttachmentProjection.project(userContent: content)
        } else {
            projection = nil
        }

        guard let projection, !projection.attachments.isEmpty else { return nil }
        return projection.cleanedText
    }

    nonisolated private static func transcriptRenderID(
        for message: ChatMessage, absoluteIndex: Int, preferDurableID: Bool
    ) -> String {
        // Direct pages have backwards cursors, not WebUI's stable absolute
        // offsets. Position-based IDs would retarget scroll anchors on prepend.
        // Keep legacy identity unchanged until that path is removed in Slice 4.
        if preferDurableID, let directID = TranscriptRenderIdentity.directID(
            for: message.messageId
        ) {
            return directID
        }
        return "transcript:\(absoluteIndex)"
    }

    nonisolated static func compressionReferenceCard(
        messages: [ChatMessage],
        messagesOffset: Int,
        transcriptMessages: [TranscriptMessage],
        metadata: CompressionAnchorMetadata?
    ) -> CompressionReferenceCard? {
        guard let resolution = CompressionAnchorResolver.resolve(
            messages: messages,
            messagesOffset: messagesOffset,
            metadata: metadata
        ) else {
            return nil
        }

        switch resolution.placement {
        case .top:
            return CompressionReferenceCard(referenceText: resolution.referenceText, afterRenderID: nil)
        case .afterLoadedMessageIndex(let loadedIndex):
            // The anchor message itself may be filtered out of the transcript
            // (e.g. tool-result-only); attach to the closest preceding row.
            let afterRenderID = transcriptMessages.last { $0.loadedIndex <= loadedIndex }?.renderID
            return CompressionReferenceCard(referenceText: resolution.referenceText, afterRenderID: afterRenderID)
        }
    }

    nonisolated private static func reasoningTexts(from message: ChatMessage) -> [String] {
        if let partsText = reasoningText(fromContentParts: message.contentParts) {
            return [partsText]
        }

        if let reasoning = nonEmptyReasoningText(message.reasoning) {
            return [reasoning]
        }

        if let contentReasoning = reasoningText(fromContent: message.content) {
            return [contentReasoning]
        }

        return []
    }

    nonisolated private static func reasoningText(fromContentParts parts: [JSONValue]?) -> String? {
        guard let parts else { return nil }

        let text = parts.compactMap { part -> String? in
            guard case .object(let object) = part,
                  let type = jsonStringValue(object["type"]),
                  type == "thinking" || type == "reasoning"
            else {
                return nil
            }

            return jsonStringValue(object["thinking"])
                ?? jsonStringValue(object["reasoning"])
                ?? jsonStringValue(object["text"])
        }
        .joined(separator: "\n")

        return nonEmptyReasoningText(text)
    }

    nonisolated private static func reasoningText(fromContent content: String?) -> String? {
        guard let content = nonEmptyReasoningText(content) else { return nil }

        if let text = leadingDelimitedText(in: content, open: "<think>", close: "</think>") {
            return text
        }

        if let text = leadingDelimitedText(in: content, open: "<|channel|>thought", close: "<channel|>") {
            return text
        }

        return leadingDelimitedText(in: content, open: "<|turn|>thinking\n", close: "<turn|>")
    }

    nonisolated private static func leadingDelimitedText(in content: String, open: String, close: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(open),
              let closeRange = trimmed.range(of: close, range: trimmed.index(trimmed.startIndex, offsetBy: open.count)..<trimmed.endIndex)
        else {
            return nil
        }

        let text = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: open.count)..<closeRange.lowerBound])
        return nonEmptyReasoningText(text)
    }

    nonisolated private static func strippedVisibleAssistantEcho(
        fromReasoning reasoning: String,
        visibleText: String?
    ) -> String? {
        var output = reasoning
        let visibleParagraphs = visibleText?
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 20 } ?? []

        for paragraph in visibleParagraphs {
            output = output.replacingOccurrences(of: paragraph, with: "")
        }

        return nonEmptyReasoningText(output)
    }

    nonisolated private static func normalizedReasoningKey(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated private static func nonEmptyReasoningText(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    nonisolated private static func jsonStringValue(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let value):
            return value
        case .number(let value):
            return value.formatted()
        case .bool(let value):
            return value ? "true" : "false"
        case .object, .array, .null, nil:
            return nil
        }
    }
}

private struct ReasoningDisplayBuilder {
    let turnKey: String
    private(set) var anchorMessageID: String?
    private(set) var segments: [String] = []
    private var normalizedSegments: Set<String> = []

    init(turnKey: String) {
        self.turnKey = turnKey
    }

    mutating func append(text: String, anchorMessageID: String?, visibleText: String?) {
        if let visibleText, !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.anchorMessageID = anchorMessageID
        }

        let normalizedText = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard normalizedSegments.insert(normalizedText).inserted else { return }
        segments.append(text)
    }

    mutating func updateAnchor(_ anchorMessageID: String) {
        self.anchorMessageID = anchorMessageID
    }

    var group: ReasoningGroup {
        ReasoningGroup(
            id: "reasoning-turn-\(turnKey)",
            anchorMessageID: anchorMessageID,
            text: segments.joined(separator: "\n\n"),
            segments: segments
        )
    }
}

private extension ToolCall {
    func matchesStableToolID(_ stableID: String) -> Bool {
        id.nonEmptyStableToolID == stableID
    }

    func applyingCompletionPayload(_ payload: ToolStreamEvent) -> ToolCall {
        ToolCall(
            id: id.nonEmptyStableToolID == nil ? payload.stableID ?? id : id,
            name: payload.name ?? name,
            preview: payload.preview ?? preview,
            args: payload.args ?? args,
            duration: payload.duration,
            isError: payload.isError,
            isCompleted: true,
            startedAt: startedAt
        )
    }
}

private extension String {
    var nonEmptyToolMatchText: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nonEmptyStableToolID: String? {
        guard let stableID = nonEmptyToolMatchText,
              !stableID.hasPrefix("live-tool-"),
              !stableID.hasPrefix("message-tool-"),
              !stableID.hasPrefix("persisted-tool-")
        else {
            return nil
        }

        return stableID
    }
}

struct SpeechTextNormalizer {
    static func normalizedAssistantText(_ text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "`", with: "")
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .replacingOccurrences(of: #"^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\s{0,3}[-*+]\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\s{0,3}>\s?"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            }

        let normalized = lines
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalized.isEmpty ? nil : normalized
    }
}

/// Routing policy for the "Listen" action (#15): prefer the server's neural TTS
/// (`POST /api/audio/speak`, configured profile provider/voice) and fall back to the
/// on-device synthesizer when the server can't serve the request.
enum ServerTTSPolicy {
    /// Client-side Listen cap; longer text routes straight to the on-device
    /// synthesizer to preserve the existing bounded playback policy.
    static let maximumTextLength = 5000
    static func shouldUseServerTTS(for text: String) -> Bool {
        text.count <= maximumTextLength
    }
}

/// Playback seam for server-synthesized "Listen" audio. Injectable so tests can
/// drive playback outcomes without constructing a real `AVAudioPlayer` (which
/// requires decodable audio bytes).
@MainActor
protocol ListenAudioPlaying: AnyObject {
    /// Fired on the main actor when playback finishes naturally.
    /// `stop()` must not fire it.
    var onFinish: (@MainActor () -> Void)? { get set }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var rate: Float { get set }

    func prepareToPlay()
    @discardableResult
    func play() -> Bool
    func pause()
    func stop()
}

/// Production `ListenAudioPlaying`: wraps `AVAudioPlayer` and forwards its finish
/// delegate onto the main actor. `init` throws when the bytes aren't decodable
/// audio, which the caller treats as "fall back to the on-device synthesizer".
@MainActor
final class ServerTTSAudioPlayer: NSObject, ListenAudioPlaying {
    private let player: AVAudioPlayer
    var onFinish: (@MainActor () -> Void)?
    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }
    var duration: TimeInterval { player.duration }
    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    init(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        super.init()
        player.delegate = self
        player.enableRate = true
    }

    func prepareToPlay() {
        player.prepareToPlay()
    }

    @discardableResult
    func play() -> Bool {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.stop()
    }
}

extension ServerTTSAudioPlayer: AVAudioPlayerDelegate {
    // `AVAudioPlayer` may call its delegate off the main thread; hop back before
    // touching main-actor listen state. Finished-with-error still ends playback,
    // so both flag values route to `onFinish`.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.onFinish?()
        }
    }

    // A mid-playback decode error fires this callback instead of (or as well as)
    // the finish one — without it the listen state would stay stuck "listening"
    // forever. Route it to `onFinish` too; a double fire is harmless because the
    // completion handler drops callbacks from a no-longer-active player.
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.onFinish?()
        }
    }
}

protocol ChatSpeechSynthesizing: AnyObject {
    var delegate: (any AVSpeechSynthesizerDelegate)? { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }

    func speak(_ utterance: AVSpeechUtterance)

    @discardableResult
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: ChatSpeechSynthesizing {}

/// Audio-session settings for the "Listen" (TTS) feature. `.playback` routes audio
/// to the speaker by default instead of the receiver/earpiece, and `.spokenAudio` is
/// the mode Apple recommends for synthesized speech (it pauses other spoken-word audio
/// rather than ducking it). Exposed as constants so the routing intent is unit-testable
/// without driving the live `AVAudioSession`. See #252.
enum ListenAudioSessionConfiguration {
    static let category = AVAudioSession.Category.playback
    static let mode = AVAudioSession.Mode.spokenAudio
    static let deactivationOptions = AVAudioSession.SetActiveOptions.notifyOthersOnDeactivation
}

/// Activates/deactivates the shared audio session around a "Listen" utterance.
/// Injectable so tests can assert the call sequence without touching real hardware.
@MainActor
protocol ListenAudioSessionControlling {
    func activate()
    func deactivate()
}

/// Production `ListenAudioSessionControlling`: drives the real shared `AVAudioSession`.
@MainActor
final class ListenAudioSessionController: ListenAudioSessionControlling {
    func activate() {
        // If composer dictation is capturing the mic, leave the shared session alone:
        // switching it to `.playback` would tear down the live recording engine. Mirrors
        // `InlineAudioPlayerView`'s guard so the two playback paths stay consistent.
        guard !ComposerAudioCaptureState.shared.isCapturing else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            ListenAudioSessionConfiguration.category,
            mode: ListenAudioSessionConfiguration.mode
        )
        try? session.setActive(true)
    }

    func deactivate() {
        guard !ComposerAudioCaptureState.shared.isCapturing else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: ListenAudioSessionConfiguration.deactivationOptions
        )
    }
}

private final class SpeechSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onFinished: @MainActor @Sendable (ObjectIdentifier) -> Void

    init(onFinished: @escaping @MainActor @Sendable (ObjectIdentifier) -> Void) {
        self.onFinished = onFinished
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishOnMainActor(for: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishOnMainActor(for: utterance)
    }

    private func finishOnMainActor(for utterance: AVSpeechUtterance) {
        // Capture identity synchronously; `ObjectIdentifier` is `Sendable`, so nothing
        // non-`Sendable` crosses the actor hop into the `@MainActor` task below.
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [onFinished] in
            onFinished(utteranceID)
        }
    }
}

#if DEBUG
extension ChatViewModel {
    /// Structural reducer coverage only; this does not enable gateway paging during a run.
    func prependMessagesForTesting(_ olderMessages: [ChatMessage]) {
        withBatchedTranscriptDerivedState {
            messages = Self.prependingOlderMessages(olderMessages, to: messages)
            messagesOffset = max(0, messagesOffset - olderMessages.count)
        }
    }

    /// Server-free fixture that exercises the exact production ChatView,
    /// transcript rows, Markdown renderer, restoration, and bottom-scroll loop.
    @MainActor
    static func makePerformanceLabFixture() -> (
        session: SessionSummary,
        server: URL,
        viewModel: ChatViewModel
    ) {
        let server = URL(string: "http://127.0.0.1:9")!
        let session = SessionSummary(
            sessionId: "semreh-chat-performance-lab",
            title: "10,000-row performance lab"
        )
        TranscriptRestoreStore.shared.save(
            TranscriptRestorePoint(
                followingLatest: false,
                visibleMessageID: "transcript:20"
            ),
            server: server,
            sessionID: session.sessionId ?? session.id
        )

        let viewModel = ChatViewModel(session: session, server: server)
        viewModel.seedPerformanceLab(messageCount: 10_000)
        return (session, server, viewModel)
    }

    /// A bounded multi-owner variant of the server-free performance fixture. Each
    /// owner is a real ChatView/ChatTranscriptView with an independent 10,000-row
    /// model; this remains presentation evidence, not direct-gateway proof.
    @MainActor
    static func makePerformanceLabFixtures(count: Int = 3) -> [(
        session: SessionSummary,
        server: URL,
        viewModel: ChatViewModel
    )] {
        precondition(count > 1)
        return (0..<count).map { index in
            let server = URL(string: "http://127.0.0.1:9")!
            let chatNumber = index + 1
            let session = SessionSummary(
                sessionId: "semreh-chat-performance-lab-\(chatNumber)",
                title: "10,000-row performance lab \(chatNumber)"
            )
            TranscriptRestoreStore.shared.save(
                TranscriptRestorePoint(
                    followingLatest: false,
                    visibleMessageID: "transcript:20"
                ),
                server: server,
                sessionID: session.sessionId ?? session.id
            )

            let viewModel = ChatViewModel(session: session, server: server)
            viewModel.seedPerformanceLab(messageCount: 10_000, conversationIndex: chatNumber)
            return (session, server, viewModel)
        }
    }

    /// Appends one deterministic user/assistant turn in small chunks so the
    /// multi-chat lab exercises the same rendered transcript while content grows.
    @MainActor
    func appendPerformanceLabStreamingTurn() async {
        guard !messages.isEmpty, !performanceLabStreamingTurnInFlight else { return }
        performanceLabStreamingTurnInFlight = true
        let started = ContinuousClock.now
        let fullRecomputesBefore = transcriptFullRecomputeCountForTesting
        defer {
            performanceLabStreamingTurnInFlight = false
            print("SEMREH_LAB_STREAM elapsed=\(started.duration(to: .now)) rows=\(messages.count) full_recomputes=\(transcriptFullRecomputeCountForTesting - fullRecomputesBefore)")
        }
        let sequence = (messages.count - 10_000) / 2 + 1
        let timestamp = (messages.last?.timestamp ?? 10_000) + 1
        let assistantID = "perf-stream-message-\(sequence)-assistant"
        appendStreamingMessage(ChatMessage(
            role: "user",
            content: "SEMREH multi-chat streaming prompt \(sequence)",
            timestamp: timestamp,
            messageId: "perf-stream-message-\(sequence)-user"
        ))
        appendStreamingMessage(ChatMessage(
            role: "assistant",
            content: "Streaming turn \(sequence): ",
            timestamp: timestamp + 0.001,
            messageId: assistantID
        ))

        let chunks = [
            "Streaming turn \(sequence): first chunk. ",
            "Streaming turn \(sequence): first chunk. second chunk. ",
            "Streaming turn \(sequence): first chunk. second chunk. final chunk. ",
            "Streaming turn \(sequence): first chunk. second chunk. final chunk. SEMREH_MULTI_CHAT_STREAM_\(sequence)"
        ]
        for chunk in chunks {
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let index = messages.lastIndex(where: { $0.messageId == assistantID }) else { return }
            let current = messages[index]
            replaceStreamingMessage(at: index, with: ChatMessage(
                role: current.role,
                content: chunk,
                timestamp: current.timestamp,
                messageId: current.messageId,
                name: current.name,
                toolCallId: current.toolCallId,
                toolUseId: current.toolUseId,
                toolCalls: current.toolCalls,
                contentParts: current.contentParts,
                reasoning: current.reasoning,
                attachments: current.attachments,
                turnTps: current.turnTps
            ))
        }
    }

    private func seedPerformanceLab(messageCount: Int, conversationIndex: Int = 0) {
        precondition(messageCount > 20)

        messages = (0..<messageCount).map { index in
            let role = index.isMultiple(of: 2) ? "user" : "assistant"
            let content: String
            if index == messageCount - 1 {
                content = """
                ## Deterministic long Markdown tail \(conversationIndex)

                This final response exercises the production streaming/Markdown surface after the 10,000-row history.

                ```swift
                \(String(repeating: "let value = Array(0..<1_000).reduce(0, +)\n", count: 320))
                ```

                End of 10,000-row conversation\(conversationIndex == 0 ? "" : " \(conversationIndex)").
                """
            } else if role == "assistant", index.isMultiple(of: 251) {
                content = """
                ### Checkpoint \(index)

                - Stable row identity
                - Lazy transcript layout
                - Markdown parsing and reuse

                `row_\(index)` remains deterministic across launches.
                """
            } else {
                content = role == "user"
                    ? "Synthetic user turn \(index) for deterministic large-conversation QA."
                    : "Synthetic assistant turn \(index). The quick brown fox keeps this row stable and readable."
            }

            return ChatMessage(
                role: role,
                content: content,
                timestamp: Double(index),
                messageId: String(format: "perf-message-%06d", index)
            )
        }
        isLoading = false
        errorMessage = nil
        hasOlderMessages = false
    }
}
#endif
