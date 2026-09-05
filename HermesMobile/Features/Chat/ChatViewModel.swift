import Foundation
import AVFoundation
import MediaPlayer
import Observation
import SwiftData

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

    var question: String {
        pending.displayQuestion
    }

    var choices: [String] {
        pending.displayChoices
    }
}

struct NativeAuthPromptState: Equatable, Identifiable {
    let contextID: String
    let ownerSessionID: String
    let streamID: String
    var components: [NativeAuthWireComponent]
    var state: NativeAuthWireState?

    var id: String { contextID }

    var inputComponents: [NativeAuthWireComponent] {
        components.filter { [.identifier, .secret, .oneTimeCode, .recoveryCode].contains($0.kind) }
    }

    var submitComponent: NativeAuthWireComponent? {
        components.first { $0.kind == .submit }
    }
}

private struct PendingNativeAuthSubmission: Equatable {
    let ownerSessionID: String
    let streamID: String
    let contextID: String
    let component: NativeAuthWireComponent
    let actionHandle: String
    let envelope: NativeAuthWireEnvelope
}

private extension NativeAuthWireStatus {
    var nativeAuthOrder: Int {
        switch self {
        case .available: 0
        case .focused: 1
        case .awaitingBrowser: 2
        case .completed, .cancelled, .blocked, .unavailable: 3
        }
    }

    var isTerminalNativeAuthStatus: Bool {
        switch self {
        case .completed, .cancelled, .blocked, .unavailable: true
        case .available, .focused, .awaitingBrowser: false
        }
    }
}

struct ProfileSwitchOutcome: Equatable {
    let session: SessionSummary?
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

enum ActiveStreamRecoveryState: Equatable {
    case idle
    case checking
    case reconnecting
}

@MainActor
@Observable
final class ChatViewModel {
    nonisolated private static let messagePageLimit = 50
    @ObservationIgnored private var incrementalTranscriptMessageIndex: Int?
    @ObservationIgnored private var streamingAssistantMessageIndex: Int?
    @ObservationIgnored private var messageLoadGeneration = 0
    /// Monotonic invalidation key for transcript-rendering data. ChatView uses
    /// this instead of comparing every message/string when unrelated composer
    /// state changes cause the parent view to be reevaluated.
    private(set) var transcriptRenderRevision = 0

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
        guard usesDirectGateway else { return streamCoordinator.activeStreamID }
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
    private let liveRunBookmarkStore: LiveRunBookmarkStore

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
    var activeStreamRecoveryState: ActiveStreamRecoveryState { streamCoordinator.recoveryState }
    var liveTokensPerSecond: Double? { streamCoordinator.liveTokensPerSecond }
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
            renderID: "transcript:\(offset + loadedIndex)",
            anchorID: TranscriptTurnClassifier.anchorID(
                for: message,
                at: loadedIndex,
                messageOffset: messagesOffset
            ),
            message: message
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
            messageOffset: messagesOffset
        )
        displayedTranscriptRowIndexByLoadedIndex = Dictionary(
            uniqueKeysWithValues: displayedTranscriptMessages.enumerated().map { rowIndex, message in
                (message.loadedIndex, rowIndex)
            }
        )
        recomputeCompressionReferenceCard()
        recomputeDisplayedReasoningGroups()
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
    private(set) var contextWindowSnapshot: ContextWindowSnapshot?
    private(set) var responseCompletionHapticTrigger = 0
    private(set) var responseCompletionNeedsTranscriptRefresh = false
    private(set) var modelCatalogGroups: [ModelCatalogGroup] = []
    private var directModelOptions: DirectHermesModelOptions?
    private(set) var agentCommands: [AgentCommand] = []
    private(set) var workspaceRoots: [WorkspaceRoot] = []
    private(set) var workspaceSuggestions: [String] = []
    private(set) var personalitySuggestions: [String] = ["none"]
    private(set) var skillSlashSuggestions: [SkillSlashSuggestion] = []
    private(set) var profileOptions: [ProfileSummary] = []
    private(set) var isSingleProfileMode = false
    private(set) var selectedProfileName: String?
    private(set) var selectedReasoningEffort: String?
    /// Raw per-session override; nil means this session inherits the profile value.
    private(set) var sessionReasoningEffort: String?
    /// Model-aware effort vocabulary (`supported_efforts` from `GET /api/reasoning`).
    /// `nil` on older servers → the composer falls back to the static list (issue #18).
    private(set) var supportedReasoningEfforts: [String]?
    /// `supports_reasoning_effort`; `false` hides the composer effort control.
    private(set) var supportsReasoningEffort: Bool?
    /// `session_scoped_reasoning`; only an explicit `true` authorizes a
    /// session-bearing effort POST. `nil` preserves legacy global behavior.
    private(set) var sessionScopedReasoning: Bool?
    /// Drops out-of-order `GET /api/reasoning` responses after rapid model switches
    /// so the gating never reflects a stale model (upstream #3750 class of bug).
    private var reasoningGatingFetchToken = 0
    /// Drops an effort-write response after a newer effort selection starts.
    private var reasoningSelectionToken = 0
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
        guard sessionScopedReasoning == true else { return selectedReasoningEffort }
        return sessionReasoningEffort ?? ReasoningEffortOption.inheritID
    }
    private(set) var isLoadingComposerConfiguration = false
    private(set) var isUpdatingComposerConfiguration = false
    private(set) var composerConfigurationErrorMessage: String?
    var pendingAttachments: [PendingAttachment] { attachmentCoordinator.pendingAttachments }
    var isUploadingAttachment: Bool { attachmentCoordinator.isUploadingAttachment }
    var attachmentUploadCount: Int { attachmentCoordinator.uploadInFlightCount }
    var attachmentUploadGeneration: Int { attachmentCoordinator.uploadStartGeneration }
    var uploadAttachmentErrorMessage: String? { attachmentCoordinator.uploadAttachmentErrorMessage }
    var localAttachmentPreviews: [String: [String: Data]] { attachmentCoordinator.localAttachmentPreviews }
    private(set) var pinnedLocalNotices: [String] = []
    var approvalPrompt: ApprovalPromptState? { pendingActionCoordinator.approvalPrompt }
    var isRespondingToApproval: Bool { pendingActionCoordinator.isRespondingToApproval }
    var approvalErrorMessage: String? { pendingActionCoordinator.approvalErrorMessage }
    var isSessionApprovalBypassEnabled: Bool { pendingActionCoordinator.isSessionApprovalBypassEnabled }
    var clarificationPrompt: ClarificationPromptState? { pendingActionCoordinator.clarificationPrompt }
    var isRespondingToClarification: Bool { pendingActionCoordinator.isRespondingToClarification }
    var clarificationErrorMessage: String? { pendingActionCoordinator.clarificationErrorMessage }
    private(set) var nativeAuthPrompt: NativeAuthPromptState?
    private(set) var nativeAuthErrorMessage: String?
    private var quarantinedNativeAuthContextIDs = Set<String>()
    private var quarantinedNativeAuthStreamIDs = Set<String>()
    private var nativeAuthStateOrderByContextID: [String: Int] = [:]
    private var bufferedNativeAuthStates: [
        String: (streamID: String, state: NativeAuthWireState)
    ] = [:]
    private var pendingNativeAuthSubmission: PendingNativeAuthSubmission?
    private var nativeAuthRequestGeneration = 0
    private var isNativeAuthRequestInFlight = false
    #if DEBUG
    private var nativeAuthE2EAutoSubmitController: NativeAuthE2EAutoSubmitController?
    var hasPendingNativeAuthSubmissionForTesting: Bool {
        pendingNativeAuthSubmission != nil
    }
    #endif
    var nativeAuthCanRetrySubmission: Bool {
        guard let prompt = nativeAuthPrompt, let pendingNativeAuthSubmission else { return false }
        return pendingNativeAuthSubmission.ownerSessionID == prompt.ownerSessionID
            && pendingNativeAuthSubmission.streamID == prompt.streamID
            && pendingNativeAuthSubmission.contextID == prompt.contextID
    }
    private(set) var websiteLoginPrompt: WebsiteLoginRequest?
    private(set) var websiteLoginErrorMessage: String?
    private var resolvedWebsiteLoginRequestIDs = Set<String>()
    private(set) var currentGoal: SubmittedGoal?
    private(set) var isSubmittingGoal = false
    private(set) var goalErrorMessage: String?
    private(set) var hasActivatedGoalCommand = false

    private var sessionID: String?
    var usesDirectGateway: Bool { gatewayRuntimeProvider != nil }
    @ObservationIgnored private let gatewayRuntimeProvider: (@MainActor (APIClient) async throws -> HermesServerRuntime)?
    private var directConversation: GatewayConversationController?
    private var directRuntime: HermesServerRuntime?
    @ObservationIgnored private var directAttachmentTask: Task<GatewayConversationController, Error>?
    private var directInvalidated = false
    private var directVisible = false
    private var directComposerIsEditing = false
    private var directOlderOffset = 0
    private var directHistoryID: String?
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
    private let streamCoordinator: ChatStreamCoordinator
    private let pendingActionCoordinator: ChatPendingActionCoordinator
    private let attachmentCoordinator: ChatAttachmentCoordinator
    private let btwStreamClient: SSEStreamingClient
    private let sessionEventStreamCoordinator: SessionEventStreamCoordinator
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
    // In-flight `POST /api/tts` fetch for the Listen action. Cancelled by
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
    private var hasCompletedCurrentResponse: Bool { usesDirectGateway ? directResponseComplete : streamCoordinator.hasCompletedCurrentResponse }
    private var isStreamConnectionSuspended: Bool { usesDirectGateway ? directRuntime?.state == .disconnected : streamCoordinator.isConnectionSuspended }
    var isActiveStreamConnectionSuspended: Bool { isStreamConnectionSuspended }
    private var hasLoadedPersonalitySuggestions = false
    private var isLoadingPersonalitySuggestions = false
    private var hasLoadedSkillSlashSuggestions = false
    private var isLoadingSkillSlashSuggestions = false
    private var queuedSlashMessages: [QueuedSlashMessage] = []
    private var isDrainingQueuedSlashMessage = false
    private var activeBtwStreamID: String?
    private var activeBtwMessageID: String?
    private var activeBtwQuestion: String?
    private var activeBtwAnswer = ""
    private var backgroundPromptsByTaskID: [String: String] = [:]
    @ObservationIgnored private var backgroundPollTask: Task<Void, Never>?
    @ObservationIgnored private var sessionEventReconcileTask: Task<Void, Never>?
    @ObservationIgnored private var didStartSessionEventSync = false
    @ObservationIgnored private var streamStatusWatchTask: Task<Void, Never>?
    private var isRefreshingCompletedResponseTitle = false
    private var isActiveStreamReplayConnection: Bool { streamCoordinator.isReplayConnection }
    private var activeStreamReplayMatchedPrefixLength = 0
    private var activeStreamReplayMatchedInterimLength = 0
    private var activeStreamReplayMatchedReasoningLength = 0
    private var activeStreamReplayToolMatchIndex = 0
    private var activeStreamReplayPendingToolMatchIndex: Int?
    private var latestServerLoadHadAssistantResponseAfterLatestUser = false
    private var needsComposerConfigurationReload = false
    private var pendingExplicitModelPick = false

    init(
        session: SessionSummary,
        server: URL,
        client: APIClient? = nil,
        streamClient: SSEStreamingClient? = nil,
        approvalStreamClient: SSEStreamingClient? = nil,
        clarifyStreamClient: SSEStreamingClient? = nil,
        btwStreamClient: SSEStreamingClient? = nil,
        sessionEventStreamClient: SSEStreamingClient? = nil,
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
        gatewayRuntimeProvider: (@MainActor (APIClient) async throws -> HermesServerRuntime)? = nil
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
        #if DEBUG
        self.nativeAuthE2EAutoSubmitController = NativeAuthE2EAutoSubmitController.processController(
            serverURL: server
        )
        #endif
        let resolvedClient = client ?? APIClient(baseURL: server)
        let resolvedStreamClient = streamClient ?? OfficialHermesStreamClient(
            client: resolvedClient,
            serverURL: server
        )
        let resolvedLiveActivityManager = liveActivityManager ?? AgentLiveActivityManager.shared
        self.client = resolvedClient
        self.streamCoordinator = ChatStreamCoordinator(
            client: resolvedClient,
            streamClient: resolvedStreamClient,
            liveActivityManager: resolvedLiveActivityManager,
            showsLiveActivityResponseExcerpts: showsLiveActivityResponseExcerpts
        )
        self.pendingActionCoordinator = ChatPendingActionCoordinator(
            client: resolvedClient,
            approvalStreamClient: approvalStreamClient ?? SSEClient(allowedServerURL: server),
            clarifyStreamClient: clarifyStreamClient ?? SSEClient(allowedServerURL: server),
            pollingIntervals: pollingIntervals
        )
        self.attachmentCoordinator = ChatAttachmentCoordinator(client: resolvedClient)
        self.btwStreamClient = btwStreamClient ?? SSEClient(allowedServerURL: server)
        self.sessionEventStreamCoordinator = SessionEventStreamCoordinator(
            server: server,
            sessionID: session.sessionId ?? "",
            profile: session.profile,
            streamClient: sessionEventStreamClient ?? SSEClient(allowedServerURL: server),
            userDefaults: userDefaults
        )
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
        self.liveRunBookmarkStore = LiveRunBookmarkStore(defaults: userDefaults)
        let restorePoint = restoreStore.load(server: server, sessionID: session.sessionId ?? session.id)
        savedFollowingLatest = restorePoint.followingLatest
        savedVisibleMessageID = restorePoint.visibleMessageID
        if gatewayRuntimeProvider == nil, let bookmark = liveRunBookmarkStore.load(server: server, sessionID: session.sessionId ?? session.id),
           bookmark.streamID == session.activeStreamId {
            liveReasoningText = bookmark.liveReasoningText
            streamingAssistantMessageID = bookmark.streamingAssistantMessageID
            liveToolCalls = bookmark.liveToolCalls
            streamCoordinator.restoreLastEventID(bookmark.lastEventID)
        }
        self.listenPlaybackSpeed = ListenPlaybackSpeed.stored(in: userDefaults)
        self.serverTTSAudioPlayerFactory = serverTTSAudioPlayerFactory
            ?? { try ServerTTSAudioPlayer(data: $0) }
        displayTitle = Self.displayTitle(from: session.title)
        self.sessionEventStreamCoordinator.onSnapshot = { [weak self] snapshot in
            self?.applySessionEventSnapshot(snapshot) ?? false
        }
        self.sessionEventStreamCoordinator.onEvent = { [weak self] event in
            self?.handleSessionEvent(event)
        }
        self.streamCoordinator.attach(delegate: self)
        self.pendingActionCoordinator.delegate = self
        self.attachmentCoordinator.delegate = self
        if gatewayRuntimeProvider == nil { streamCoordinator.adoptKnownLiveStreamIfNeeded(session.activeStreamId) }
    }

    deinit {
        backgroundPollTask?.cancel()
        sessionEventReconcileTask?.cancel()
        streamStatusWatchTask?.cancel()
        pendingStreamingScrollTriggerTask?.cancel()
        pendingStreamingContentFlushTask?.cancel()
        connectionVisibilityTask?.cancel()
        listenPreparationTask?.cancel()
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
            // The catalog reports profile defaults, not this stored chat's
            // effective configuration. Only a new local draft inherits them.
            if canonicalSessionID == nil, currentModel == nil {
                currentModel = Self.nonEmpty(options.model)
                currentModelProvider = Self.nonEmpty(options.provider)
            }
            applyDirectReasoningGating()
        } catch {
            guard !directInvalidated, profile == (requestProfileName ?? "default"),
                  mutation == composerConfigurationMutationToken else { return }
            lastError = error
            composerConfigurationErrorMessage = "Hermes model settings could not be loaded. Your draft was preserved."
        }
    }

    private func applyDirectReasoningGating() {
        let capability = directModelOptions?.providers?.first { $0.slug == currentModelProvider }?
            .capabilities?[currentModel ?? ""]
        // These are the pinned create-time parser's levels, not a claim that
        // every provider implements every level without coercion.
        supportedReasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
            .filter { $0 != "none" || capability?.canDisableReasoning != false }
        supportsReasoningEffort = capability?.reasoning ?? false
        sessionScopedReasoning = canonicalSessionID == nil
    }

    private func canConfigureDirectDraft() -> Bool {
        guard !directInvalidated, !isViewingCachedData, !isUpdatingComposerConfiguration,
              activeStreamID == nil else {
            composerConfigurationErrorMessage = "Wait until this chat is idle and connected to change its settings."
            return false
        }
        guard canonicalSessionID == nil else {
            composerConfigurationErrorMessage = "Changing settings on an existing direct chat is not available yet. New Chat supports model and reasoning choices before its first send."
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
            let controller = GatewayConversationController(runtime: runtime, client: self.client,
                storedID: self.canonicalSessionID, profile: Self.nonEmpty(self.currentProfile) ?? "default")
            controller.isVisible = self.directVisible
            controller.isEditing = self.directComposerIsEditing
            controller.onBinding = { [weak self] binding in self?.adoptDirectID(binding.storedID) }
            controller.onCanonicalID = { [weak self] id in self?.adoptDirectID(id) }
            controller.onTranscript = { [weak self] page, older in
                guard let self, !self.directInvalidated else { return }
                self.applyDirectTranscript(page, older: older)
            }
            controller.onEvent = { [weak self] event in
                guard let self, !self.directInvalidated else { return }
                self.applyDirectEvent(event)
            }
            controller.onError = { [weak self] error in
                guard let self, !self.directInvalidated else { return }
                self.lastError = error
                self.sendErrorMessage = "The Hermes connection needs attention. No message was automatically resent."
            }
            self.directRuntime = runtime
            self.directConversation = controller
            return controller
        }
        directAttachmentTask = task
        defer { directAttachmentTask = nil }
        return try await task.value
    }

    private func adoptDirectID(_ id: String) {
        guard !directInvalidated, sessionID != id else { return }
        sessionID = id
        onDirectCanonicalID?(id)
    }

    func invalidateDirectConversation() {
        guard usesDirectGateway else { return }
        directInvalidated = true
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

    private func loadDirectMessages(modelContext: ModelContext?) async {
        guard !directInvalidated else { return }
        directModelContext = modelContext ?? directModelContext
        if let sessionID, messages.isEmpty, let modelContext {
            _ = renderCachedMessagesBeforeReload(sessionID: sessionID, modelContext: modelContext)
        }
        beginConnectionWaitIfNeeded()
        defer { endConnectionWait() }
        do {
            let wasAttached = directConversation?.binding != nil
            let controller = try await ensureDirectConversation()
            // open/resume already performs one canonical read. A warm idle
            // refresh needs another; never overwrite an active streamed turn.
            try await controller.open()
            if wasAttached, controller.runState == .idle { try await controller.refresh() }
            errorMessage = nil
        } catch {
            lastError = error
            errorMessage = "Could not load this Hermes conversation."
            isViewingCachedData = !messages.isEmpty
        }
    }

    private func loadOlderDirectMessages(modelContext: ModelContext?) async -> Bool {
        guard !directInvalidated, !isLoadingOlderMessages, hasOlderMessages,
              directConversation?.runState == .idle else { return false }
        directModelContext = modelContext ?? directModelContext
        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }
        let count = messages.count
        do {
            let controller = try await ensureDirectConversation()
            try await controller.refresh(limit: 120, offset: directOlderOffset)
            return messages.count > count
        } catch { lastError = error; errorMessage = "Could not load older messages."; return false }
    }

    private func applyDirectTranscript(_ page: DirectHermesTranscriptPage, older: Bool) {
        let renderedCache = cacheFirstMessagePlaceholder != nil
        flushPendingStreamingContent()
        resetPendingStreamingContentBuffers()
        let canonicalChanged = directHistoryID != nil && directHistoryID != page.sessionID
        adoptDirectID(page.sessionID)
        directHistoryID = page.sessionID
        withBatchedTranscriptDerivedState {
            messages = older && !canonicalChanged
                ? Self.prependingOlderMessages(page.messages, to: messages) : page.messages
            // WebUI's forward absolute offset is not the direct backwards cursor.
            // Stable durable row IDs own transcript identity on this path.
            messagesOffset = 0
        }
        let returned = page.pagination?.returned ?? page.messages.count
        directOlderOffset = (page.pagination?.offset ?? (older ? directOlderOffset : 0)) + returned
        hasOlderMessages = returned >= (page.pagination?.limit ?? 120)
        setCompletedToolCallGroups(ToolCallGroup.groups(persistedToolCalls: [], messages: messages, messageOffset: 0))
        completedReasoningGroups = []
        streamingAssistantMessageID = nil
        streamingAssistantMessageIndex = nil
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

    private func sendDirectMessage(_ draft: String, modelContext: ModelContext?) async -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !directInvalidated, !isStartingChat,
              (directConversation?.runState == nil || directConversation?.runState == .idle) else { return false }
        guard pendingAttachments.isEmpty else {
            sendErrorMessage = "Direct Hermes attachments are not available yet. Your draft was kept."
            return false
        }
        directModelContext = modelContext ?? directModelContext
        isStartingChat = true
        sendErrorMessage = nil
        lastError = nil
        defer {
            isStartingChat = false
            OpenChatSessionStore.shared.noteStreamingStateChanged()
        }
        let localID = "local-\(UUID().uuidString)"
        do {
            let controller = try await ensureDirectConversation()
            // Resume first so its canonical transcript cannot erase this new
            // optimistic row. Draft open remains completely local.
            try await controller.open()
            guard !directInvalidated, controller.runState == .idle else { throw DirectSessionError.ambiguousPrompt }
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
            messages.append(ChatMessage(role: "user", content: text, timestamp: Date().timeIntervalSince1970, messageId: localID))
            var creation: [String: JSONValue] = [:]
            if let value = Self.nonEmpty(currentWorkspace) { creation["cwd"] = .string(value) }
            if let value = Self.nonEmpty(currentModel) { creation["model"] = .string(value) }
            if let value = Self.nonEmpty(currentModelProvider) { creation["provider"] = .string(value) }
            if let value = Self.nonEmpty(sessionReasoningEffort) { creation["reasoning_effort"] = .string(value) }
            try await controller.submit(text, create: creation)
            if let sessionID { cacheCurrentMessages(sessionID: sessionID, modelContext: directModelContext) }
            return true
        } catch {
            lastError = error
            if directConversation?.runState == .deliveryUnknown {
                // Keep the staged row as uncertain. Restoring the composer would
                // invite an accidental duplicate; a canonical reload resolves it.
                sendErrorMessage = "Delivery is uncertain. This message was not resent; reconnect to check the transcript."
                return true
            }
            rollbackOptimisticMessage(id: localID)
            sendErrorMessage = "Hermes could not accept this message. Your draft was kept."
            return false
        }
    }

    private func applyDirectEvent(_ event: HermesGatewayEvent) {
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
            _ = appendAssistantToken(text)
            if showsLiveActivityResponseExcerpts { liveActivityManager.update(.token(text)) }
        case .interim(let text, let alreadyStreamed):
            _ = appendInterimAssistant(InterimAssistantStreamEvent(text: text, alreadyStreamed: alreadyStreamed))
        case .thinkingDelta(let text), .reasoningDelta(let text):
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
            if let text = terminal.text, !text.isEmpty { _ = ensureStreamingAssistantMessage() }
            if let text = terminal.text, !text.isEmpty,
               let index = messages.indices.last, messages[index].role == "assistant" {
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
            responseCompletionHapticTrigger += 1
            sendErrorMessage = terminal.error
            let cancelled = terminal.status == "cancelled" || terminal.status == "interrupted"
            liveActivityManager.end(status: terminal.error != nil ? .failed : (cancelled ? .cancelled : .complete),
                activity: cancelled ? "Response stopped" : "Response complete", errorSummary: terminal.error)
        case .control(let raw):
            if raw.type == "message.start" {
                directResponseComplete = false
                streamingAssistantMessageID = nil
                streamingAssistantMessageIndex = nil
                if let sessionID {
                    // A local activity identity is not a gateway runtime ID.
                    liveActivityManager.start(sessionID: sessionID, sessionTitle: displayTitle, streamID: nil)
                }
            } else if raw.type == "error" {
                sendErrorMessage = raw.payload?.gatewayFields["message"]?.gatewayString ?? "Hermes reported an error."
            } else if ["approval.request", "clarify.request", "sudo.request", "secret.request"].contains(raw.type) {
                // Native blocking-interaction controls are Slice 3. Until then,
                // surface the wait explicitly instead of silently dropping it
                // or trying the WebUI approval/clarification endpoints.
                sendErrorMessage = "Hermes is waiting for input. This migration build cannot answer that request yet; use the TUI or stop this response."
            }
        case .unknown: break
        }
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
        streamCoordinator.setShowsLiveActivityResponseExcerpts(shows)
    }

    var showsListenPlaybackBar: Bool {
        listenPlaybackPhase != .idle
    }

    var listenPlaybackDisplayTime: TimeInterval {
        listenPlaybackScrubTime ?? listenPlaybackElapsedTime
    }

    nonisolated static func resetActiveStreamSnapshotsForTesting() {
        ActiveChatStreamSnapshotStore.shared.removeAll()
    }

    func startSessionEventSync() {
        if usesDirectGateway {
            directVisible = true
            directConversation?.isVisible = true
            return
        }
        guard !didStartSessionEventSync else { return }
        didStartSessionEventSync = true

        // Preserve the mature WebUI lifecycle synchronously. Only a configured
        // official sidecar needs an asynchronous capability decision.
        guard client.officialContinuityClient != nil else {
            sessionEventStreamCoordinator.start()
            return
        }

        // `/api/sessions/{id}/events` is a community-WebUI journal route, not
        // part of the official continuity surface. Avoid opening it for an
        // official session; completed-turn reconciliation uses GET messages.
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await client.continuityTransport() == .webUI else {
                didStartSessionEventSync = false
                return
            }
            guard didStartSessionEventSync else { return }
            sessionEventStreamCoordinator.start()
        }
    }

    func stopSessionEventSync() {
        directVisible = false
        directConversation?.isVisible = false
        guard !usesDirectGateway else { return }
        didStartSessionEventSync = false
        sessionEventReconcileTask?.cancel()
        sessionEventReconcileTask = nil
        sessionEventStreamCoordinator.stop()
    }

    private func handleSessionEvent(_ event: SSEEvent) {
        switch event {
        case .done, .streamEnd, .cancelled, .error, .lostWorkerBookkeeping:
            scheduleSessionEventReconcile()
        default:
            break
        }
    }

    private func scheduleSessionEventReconcile() {
        sessionEventReconcileTask?.cancel()
        sessionEventReconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.loadMessages()
        }
    }

    private func applySessionEventSnapshot(_ snapshot: SessionSummary) -> Bool {
        let snapshotID = (snapshot.sessionId ?? snapshot.id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionID, snapshotID == sessionID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }

        // Snapshots are metadata deltas in the current server contract. Older or
        // partially populated snapshots may omit fields; absence must not erase
        // the warm session's known values while transcript reconciliation runs.
        if let workspace = snapshot.workspace {
            currentWorkspace = workspace
        }
        if let model = snapshot.model {
            currentModel = model
        }
        if let provider = snapshot.modelProvider {
            currentModelProvider = provider
        }
        currentProfile = snapshot.profile ?? currentProfile
        if let title = snapshot.title {
            displayTitle = Self.displayTitle(from: title)
        }

        // A session snapshot is metadata, not an authoritative transcript. Reconcile
        // the transcript separately and keep the visible/live state until that load
        // wins its own generation check.
        if activeStreamID == nil {
            sessionEventReconcileTask?.cancel()
            sessionEventReconcileTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.loadMessages()
            }
        }
        return true
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

    // Test seam: deterministically await the in-flight coalesced scroll-trigger task
    // so streaming assertions never depend on the real coalescing window elapsing.
    // No-op when no trigger is pending.
    func awaitPendingStreamingScrollTriggerForTesting() async {
        await pendingStreamingScrollTriggerTask?.value
    }

    private struct ActiveStreamMessageMerge {
        let messages: [ChatMessage]
        let streamingAssistantMessageID: String?
        let usedSnapshotMessagesOffset: Bool
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
        // Chunks are deduplicated at append time, so the replay matched-prefix
        // counters can reference unflushed content; dropping the buffers makes them
        // stale. Reset only the counters — the replay connection may still be live
        // (e.g. loadOlderMessages pagination mid-catch-up), so dedup must stay armed.
        activeStreamReplayMatchedPrefixLength = 0
        activeStreamReplayMatchedReasoningLength = 0
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

    /// The canonical Hermes session ID is the server-provided `session_id`.
    /// `SessionSummary.id` may be a local synthetic fallback and must never be
    /// sent as a session-scoped reasoning identity.
    private var canonicalSessionID: String? {
        Self.nonEmpty(sessionID)
    }

    private var requestModelProvider: String? {
        Self.nonEmpty(currentModelProvider)
    }

    private func explicitModelPickForChatStart() -> Bool {
        pendingExplicitModelPick && Self.nonEmpty(currentModel) != nil
    }

    private func completeExplicitModelPickForChatStart(_ explicitModelPick: Bool) {
        if explicitModelPick {
            pendingExplicitModelPick = false
        }
    }

    func loadComposerConfiguration() async {
        if usesDirectGateway { await loadDirectComposerConfiguration(); return }
        if isLoadingComposerConfiguration {
            needsComposerConfigurationReload = true
            return
        }

        isLoadingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        lastError = nil
        defer { isLoadingComposerConfiguration = false }

        repeat {
            needsComposerConfigurationReload = false

            let initialState = composerConfigurationState
            let result = await ChatComposerConfigLoader(client: client)
                .loadConfiguration(from: initialState, sessionID: canonicalSessionID)

            guard composerConfigurationState == initialState else {
                needsComposerConfigurationReload = true
                continue
            }

            applyComposerConfigurationState(result.state)

            if let error = result.configurationError {
                lastError = error
                composerConfigurationErrorMessage = CacheFallbackPolicy.composerBannerMessage(for: error)
            }
        } while needsComposerConfigurationReload
    }

    /// Refreshes the model catalog when a picker opens: refetch `/api/models`
    /// (so the sheet stops pinning the chat-load-time snapshot), then overlay
    /// the active provider's live list from `/api/models/live`. Failures are
    /// silent by design — the picker keeps whatever it already shows.
    func refreshModelCatalogForPickerOpen() async {
        if usesDirectGateway { await loadDirectComposerConfiguration(); return }
        if let response = try? await client.models() {
            let groups = response.catalogGroups
            if !groups.isEmpty {
                modelCatalogGroups = groups
            }
        }

        if let live = try? await client.modelsLive() {
            modelCatalogGroups = modelCatalogGroups.mergingLiveModels(from: live)
        }
    }

    private var composerConfigurationState: ChatComposerConfigState {
        ChatComposerConfigState(
            currentWorkspace: currentWorkspace,
            currentModel: currentModel,
            currentModelProvider: currentModelProvider,
            currentProfile: currentProfile,
            selectedProfileName: selectedProfileName,
            selectedReasoningEffort: selectedReasoningEffort,
            sessionReasoningEffort: sessionReasoningEffort,
            supportedReasoningEfforts: supportedReasoningEfforts,
            supportsReasoningEffort: supportsReasoningEffort,
            sessionScopedReasoning: sessionScopedReasoning,
            modelCatalogGroups: modelCatalogGroups,
            agentCommands: agentCommands,
            workspaceRoots: workspaceRoots,
            workspaceSuggestions: workspaceSuggestions,
            profileOptions: profileOptions,
            isSingleProfileMode: isSingleProfileMode
        )
    }

    private func applyComposerConfigurationState(_ state: ChatComposerConfigState) {
        currentWorkspace = state.currentWorkspace
        currentModel = state.currentModel
        currentModelProvider = state.currentModelProvider
        currentProfile = state.currentProfile
        selectedProfileName = state.selectedProfileName
        selectedReasoningEffort = state.selectedReasoningEffort
        sessionReasoningEffort = state.sessionReasoningEffort
        supportedReasoningEfforts = state.supportedReasoningEfforts
        supportsReasoningEffort = state.supportsReasoningEffort
        sessionScopedReasoning = state.sessionScopedReasoning
        modelCatalogGroups = state.modelCatalogGroups
        agentCommands = state.agentCommands
        workspaceRoots = state.workspaceRoots
        workspaceSuggestions = state.workspaceSuggestions
        profileOptions = state.profileOptions
        isSingleProfileMode = state.isSingleProfileMode
    }

    func refreshApprovalBypassState() async {
        guard !usesDirectGateway else { return }
        await pendingActionCoordinator.refreshApprovalBypassState()
    }

    @discardableResult
    func selectComposerModel(_ option: ModelCatalogOption) async -> Bool {
        if usesDirectGateway {
            guard canConfigureDirectDraft(),
                  modelCatalogGroups.flatMap(\.models).contains(option),
                  !option.matchesSelection(modelID: currentModel, providerID: currentModelProvider) else { return false }
            composerConfigurationMutationToken &+= 1
            currentModel = option.id
            currentModelProvider = option.providerID
            sessionReasoningEffort = nil
            selectedReasoningEffort = nil
            applyDirectReasoningGating()
            return true
        }
        guard !option.matchesSelection(modelID: currentModel, providerID: currentModelProvider) else {
            return false
        }

        guard !isViewingCachedData else {
            composerConfigurationErrorMessage = String(localized: "Reconnect to the server to change models.")
            return false
        }

        guard activeStreamID == nil else {
            composerConfigurationErrorMessage = String(localized: "Wait for the current response to finish before changing models.")
            return false
        }

        guard let sessionID else {
            composerConfigurationErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let previousModel = currentModel
        let previousProvider = currentModelProvider
        let previousWorkspace = currentWorkspace
        let previousPendingExplicitModelPick = pendingExplicitModelPick
        composerConfigurationMutationToken &+= 1
        let mutationToken = composerConfigurationMutationToken

        // Update the chip immediately. Sending remains disabled for the short
        // persistence window, while rollback below restores the exact prior
        // selection if the server rejects the change.
        currentModel = option.id
        currentModelProvider = option.providerID
        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        lastError = nil
        defer {
            if composerConfigurationMutationToken == mutationToken {
                isUpdatingComposerConfiguration = false
            }
        }

        do {
            let response = try await client.updateSession(
                id: sessionID,
                workspace: currentWorkspace,
                model: option.id,
                modelProvider: option.providerID
            )

            guard composerConfigurationMutationToken == mutationToken,
                  currentModel == option.id,
                  currentModelProvider == option.providerID
            else { return false }

            currentModel = response.session?.model ?? option.id
            currentModelProvider = response.session?.modelProvider ?? option.providerID
            currentWorkspace = response.session?.workspace ?? currentWorkspace
            pendingExplicitModelPick = true
            // Still inside the isUpdatingComposerConfiguration window, so the
            // effort menu stays disabled until the new model's gating lands —
            // no interactable flash of the previous model's options (issue #18).
            await refreshReasoningEffortGating()
            guard composerConfigurationMutationToken == mutationToken else { return false }
            return true
        } catch {
            guard composerConfigurationMutationToken == mutationToken else { return false }
            currentModel = previousModel
            currentModelProvider = previousProvider
            currentWorkspace = previousWorkspace
            pendingExplicitModelPick = previousPendingExplicitModelPick
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Re-queries `GET /api/reasoning` for the current model/provider and updates
    /// the effort gating (issue #18). Failures are silent to the user, but reset
    /// the gating to the "unknown" fallback (static effort list, control shown) —
    /// keeping the previous model's gating after a successful model switch could
    /// hide the control for a model that supports it, or offer efforts the new
    /// model rejects. If the selected effort is no longer supported, snaps to the
    /// server's coerced `reasoning_effort`.
    func refreshReasoningEffortGating() async {
        if usesDirectGateway { applyDirectReasoningGating(); return }
        guard !isViewingCachedData else { return }

        reasoningGatingFetchToken += 1
        let token = reasoningGatingFetchToken
        let expectedSessionID = canonicalSessionID
        let expectedModel = currentModel
        let expectedProvider = currentModelProvider

        guard let response = try? await client.reasoning(
            model: Self.nonEmpty(currentModel),
            provider: Self.nonEmpty(currentModelProvider),
            sessionID: Self.nonEmpty(expectedSessionID)
        ) else {
            if token == reasoningGatingFetchToken,
               expectedSessionID == canonicalSessionID,
               expectedModel == currentModel,
               expectedProvider == currentModelProvider {
                supportedReasoningEfforts = nil
                supportsReasoningEffort = nil
                sessionScopedReasoning = nil
            }
            return
        }

        guard token == reasoningGatingFetchToken,
              expectedSessionID == canonicalSessionID,
              expectedModel == currentModel,
              expectedProvider == currentModelProvider
        else { return }

        supportedReasoningEfforts = response.normalizedSupportedEfforts
        supportsReasoningEffort = response.supportsReasoningEffort
        sessionScopedReasoning = response.sessionScopedReasoning
        if response.sessionScopedReasoning == true {
            // The session-aware endpoint is authoritative, including a nil
            // override after selecting Default/inherit.
            sessionReasoningEffort = response.normalizedSessionReasoningEffort
        } else if let rawEffort = response.normalizedSessionReasoningEffort {
            sessionReasoningEffort = rawEffort
        }

        if let selected = Self.nonEmpty(selectedReasoningEffort)?.lowercased(),
           let supported = supportedReasoningEfforts,
           !supported.contains(selected),
           let serverEffort = Self.nonEmpty(response.effectiveEffort) {
            selectedReasoningEffort = serverEffort
        }
    }

    /// Refetches the workspace registry after the manager sheet mutated it
    /// (issue #22), so the picker reflects adds/removes/renames/reorders.
    func refreshWorkspaceRoots() async {
        guard !usesDirectGateway else { return }
        guard !isViewingCachedData else { return }

        do {
            let response = try await client.workspaces()
            workspaceRoots = response.workspaces ?? []
            workspaceSuggestions = workspaceRoots.compactMap(\.path)
        } catch {
            lastError = error
        }
    }

    func loadWorkspaceSuggestions(prefix: String) async {
        guard !usesDirectGateway else { return }
        guard !isViewingCachedData else {
            workspaceSuggestions = workspaceRoots.compactMap(\.path)
            return
        }

        do {
            let response = try await client.workspaceSuggestions(prefix: prefix)
            workspaceSuggestions = response.suggestions ?? []
        } catch {
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
        }
    }

    func loadPersonalitySuggestions() async {
        guard !usesDirectGateway else { return }
        guard !hasLoadedPersonalitySuggestions else { return }
        guard !isLoadingPersonalitySuggestions else { return }

        isLoadingPersonalitySuggestions = true
        defer { isLoadingPersonalitySuggestions = false }

        do {
            personalitySuggestions = (try await client.personalities()).slashAutocompleteNames
            hasLoadedPersonalitySuggestions = true
        } catch {
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            if personalitySuggestions.isEmpty {
                personalitySuggestions = ["none"]
            }
        }
    }

    func loadSkillSlashSuggestions() async {
        guard !usesDirectGateway else { return }
        guard !hasLoadedSkillSlashSuggestions else { return }
        guard !isLoadingSkillSlashSuggestions else { return }

        isLoadingSkillSlashSuggestions = true
        defer { isLoadingSkillSlashSuggestions = false }

        do {
            let response = try await client.skills()
            skillSlashSuggestions = SlashSkillFormatter.suggestions(from: response.skills ?? [])
            hasLoadedSkillSlashSuggestions = true
        } catch {
            lastError = error
        }
    }

    @discardableResult
    func selectWorkspacePath(_ path: String) async -> Bool {
        let workspace = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else { return false }
        if usesDirectGateway {
            guard canConfigureDirectDraft(), workspace != currentWorkspace else { return false }
            composerConfigurationMutationToken &+= 1
            currentWorkspace = workspace
            return true
        }

        guard workspace != currentWorkspace else {
            return false
        }

        guard !isViewingCachedData else {
            composerConfigurationErrorMessage = String(localized: "Reconnect to the server to change workspace.")
            return false
        }

        guard activeStreamID == nil else {
            composerConfigurationErrorMessage = String(localized: "Wait for the current response to finish before changing workspace.")
            return false
        }

        guard let sessionID else {
            composerConfigurationErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let previousWorkspace = currentWorkspace
        currentWorkspace = workspace
        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        lastError = nil
        defer { isUpdatingComposerConfiguration = false }

        do {
            let response = try await client.updateSession(
                id: sessionID,
                workspace: workspace,
                model: currentModel,
                modelProvider: currentModelProvider
            )

            currentWorkspace = response.session?.workspace ?? workspace
            currentModel = response.session?.model ?? currentModel
            currentModelProvider = response.session?.modelProvider ?? currentModelProvider
            return true
        } catch {
            currentWorkspace = previousWorkspace
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return false
        }
    }

    func switchProfile(_ profile: ProfileSummary, startNewSession: Bool) async -> ProfileSwitchOutcome? {
        if usesDirectGateway {
            guard !directInvalidated, !isViewingCachedData, !isUpdatingComposerConfiguration,
                  activeStreamID == nil, let name = profile.normalizedName else { return nil }
            // A profile owns a different durable namespace. Return a new local
            // draft; never retarget this controller or change the host profile.
            guard startNewSession else {
                composerConfigurationErrorMessage = "Choose New Chat to use a different Hermes profile."
                return nil
            }
            return ProfileSwitchOutcome(session: SessionSummary(title: "New Chat", createdAt: Date().timeIntervalSince1970, profile: name))
        }
        guard !isViewingCachedData else {
            composerConfigurationErrorMessage = String(localized: "Reconnect to the server to change profiles.")
            return nil
        }

        guard activeStreamID == nil else {
            composerConfigurationErrorMessage = String(localized: "Wait for the current response to finish before changing profiles.")
            return nil
        }

        guard let profileName = profile.normalizedName else {
            composerConfigurationErrorMessage = String(localized: "The server did not provide a profile name.")
            return nil
        }

        if !startNewSession, isSelectedProfile(profile) {
            return nil
        }

        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        lastError = nil
        defer { isUpdatingComposerConfiguration = false }

        do {
            let response = try await client.switchProfile(name: profileName)
            profileOptions = response.profiles ?? profileOptions
            selectedProfileName = response.active ?? profileName
            currentProfile = selectedProfileName

            if let defaultWorkspace = response.defaultWorkspace, !defaultWorkspace.isEmpty {
                currentWorkspace = defaultWorkspace
            }

            if let defaultModel = response.defaultModel, !defaultModel.isEmpty {
                currentModel = defaultModel
                currentModelProvider = Self.nonEmpty(profile.provider)
            }
            pendingExplicitModelPick = false

            await loadComposerConfiguration()

            guard startNewSession else {
                return ProfileSwitchOutcome(session: nil)
            }

            let newSessionResponse = try await client.createSession(
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName
            )

            guard let session = newSessionResponse.session else {
                composerConfigurationErrorMessage = String(localized: "The server did not return the new profile session.")
                return nil
            }

            return ProfileSwitchOutcome(session: SessionSummary(from: session))
        } catch {
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func selectReasoningEffort(_ effort: String) async -> Bool {
        let selectedEffort = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedEffort.isEmpty else { return false }
        if usesDirectGateway {
            guard canConfigureDirectDraft() else { return false }
            let normalized = selectedEffort.lowercased()
            guard normalized == ReasoningEffortOption.inheritID ||
                    (supportsReasoningEffort == true && supportedReasoningEfforts?.contains(normalized) == true) else { return false }
            composerConfigurationMutationToken &+= 1
            sessionScopedReasoning = true
            sessionReasoningEffort = normalized == ReasoningEffortOption.inheritID ? nil : normalized
            selectedReasoningEffort = sessionReasoningEffort
            return true
        }

        let normalizedEffort = selectedEffort.lowercased()
        let clearsSessionOverride = normalizedEffort == ReasoningEffortOption.inheritID
        if clearsSessionOverride && sessionScopedReasoning != true {
            composerConfigurationErrorMessage = String(localized: "Session reasoning inheritance is unavailable on this server.")
            return false
        }

        guard selectedEffort != selectedReasoningSelection else {
            return false
        }

        guard !isViewingCachedData else {
            composerConfigurationErrorMessage = String(localized: "Reconnect to the server to change reasoning.")
            return false
        }

        guard activeStreamID == nil else {
            composerConfigurationErrorMessage = String(localized: "Wait for the current response to finish before changing reasoning.")
            return false
        }

        let previousSelectedReasoningEffort = selectedReasoningEffort
        let previousSessionReasoningEffort = sessionReasoningEffort
        let previousSessionScopedReasoning = sessionScopedReasoning
        let expectedSessionID = canonicalSessionID
        let expectedModel = currentModel
        let expectedProvider = currentModelProvider
        composerConfigurationMutationToken &+= 1
        let mutationToken = composerConfigurationMutationToken

        // Reflect the selection immediately. The composer is disabled only while
        // persistence is in flight; a failed request restores the prior effective
        // value and raw session override below.
        if clearsSessionOverride {
            sessionReasoningEffort = nil
        } else if sessionScopedReasoning == true {
            sessionReasoningEffort = selectedEffort
        } else {
            selectedReasoningEffort = selectedEffort
        }

        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        lastError = nil
        defer {
            if composerConfigurationMutationToken == mutationToken {
                isUpdatingComposerConfiguration = false
            }
        }

        reasoningSelectionToken &+= 1
        let selectionToken = reasoningSelectionToken
        if sessionScopedReasoning == true && expectedSessionID == nil {
            if composerConfigurationMutationToken == mutationToken {
                selectedReasoningEffort = previousSelectedReasoningEffort
                sessionReasoningEffort = previousSessionReasoningEffort
                sessionScopedReasoning = previousSessionScopedReasoning
                composerConfigurationErrorMessage = String(localized: "The server did not provide a session ID.")
            }
            return false
        }

        do {
            let wireEffort = clearsSessionOverride ? "" : selectedEffort
            let response = try await client.saveReasoningEffort(
                wireEffort,
                sessionID: sessionScopedReasoning == true ? expectedSessionID : nil
            )
            guard selectionToken == reasoningSelectionToken,
                  composerConfigurationMutationToken == mutationToken,
                  expectedSessionID == canonicalSessionID,
                  expectedModel == currentModel,
                  expectedProvider == currentModelProvider
            else { return false }

            sessionScopedReasoning = response.sessionScopedReasoning ?? sessionScopedReasoning
            sessionReasoningEffort = response.normalizedSessionReasoningEffort
                ?? (sessionScopedReasoning == true && !clearsSessionOverride ? wireEffort : nil)
            selectedReasoningEffort = response.effectiveEffort
                ?? (clearsSessionOverride ? selectedReasoningEffort : selectedEffort)
            return true
        } catch {
            guard composerConfigurationMutationToken == mutationToken else { return false }
            selectedReasoningEffort = previousSelectedReasoningEffort
            sessionReasoningEffort = previousSessionReasoningEffort
            sessionScopedReasoning = previousSessionScopedReasoning
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return false
        }
    }

    func uploadAttachment(data: Data, filename: String, previewData: Data? = nil) async {
        guard !usesDirectGateway else {
            setUploadAttachmentError("Direct Hermes attachments are not available yet.")
            return
        }
        await attachmentCoordinator.uploadAttachment(data: data, filename: filename, previewData: previewData)
    }

    func clearPendingAttachments() {
        attachmentCoordinator.clearPendingAttachments()
    }

    func removePendingAttachment(id: UUID) {
        attachmentCoordinator.removePendingAttachment(id: id)
    }

    func setUploadAttachmentError(_ message: String?) {
        attachmentCoordinator.setUploadAttachmentError(message)
    }

    func attachmentImageData(path: String) async -> Data? {
        await attachmentCoordinator.attachmentImageData(path: path)
    }

    func attachmentRawData(path: String) async -> Data? {
        await attachmentCoordinator.attachmentRawData(path: path)
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
        if usesDirectGateway {
            await loadDirectMessages(modelContext: modelContext)
            return
        }
        guard let sessionID else {
            errorMessage = String(localized: "The server did not provide a session ID.")
            return
        }

        messageLoadGeneration &+= 1
        let generation = messageLoadGeneration
        let streamIDAtLoadStart = activeStreamID
        if streamIDAtLoadStart == nil {
            resetPendingStreamingContentBuffers()
        }
        latestServerLoadHadAssistantResponseAfterLatestUser = false
        let streamLoadPreparation = streamCoordinator.prepareForSessionLoad()
        beginConnectionWaitIfNeeded()
        errorMessage = nil
        cacheErrorMessage = nil
        lastError = nil
        defer {
            if messageLoadGeneration == generation {
                endConnectionWait()
            }
        }

        // Cache-first render (#289): reconcile successful server data against the
        // transcript that existed *before* an optimistic cache placeholder. A
        // prepared placeholder may overlap a shifted server page; treating it as
        // real history would retain stale prefix rows and reset pagination to zero.
        let isUsingPreparedCachePlaceholder = cacheFirstMessagePlaceholder != nil
            && messages == cacheFirstMessagePlaceholder
        let previousMessages = isUsingPreparedCachePlaceholder
            ? messagesBeforeCacheFirstPlaceholder
            : messages
        let previousMessagesOffset = isUsingPreparedCachePlaceholder
            ? messagesOffsetBeforeCacheFirstPlaceholder
            : messagesOffset
        if messages.isEmpty, let modelContext {
            _ = renderCachedMessagesBeforeReload(
                sessionID: sessionID,
                modelContext: modelContext
            )
        }
        let renderedCacheFirst = cacheFirstMessagePlaceholder != nil

        do {
            let response = try await client.session(
                id: sessionID,
                includeMessages: true,
                messageLimit: Self.messagePageLimit
            )
            guard messageLoadGeneration == generation else { return }
            guard allowApplyDuringLocalStart || (!isStartingChat && !isEditingMessage && !isRegeneratingMessage) else { return }
            guard streamIDAtLoadStart != nil || activeStreamID == nil else { return }
            let session = response.session
            let loadedMessages = session?.messages ?? []
            let loadedActiveStreamID = session?.activeStreamId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reloadedMessages: [ChatMessage]
            if let modelContext {
                do {
                    let cachedMessages = try CacheStore.cachedMessages(
                        serverURL: server,
                        sessionID: sessionID,
                        in: modelContext,
                        limit: Self.messagePageLimit
                    )
                    reloadedMessages = Self.mergingLoadedMessages(
                        loadedMessages,
                        withCachedLocalOptimisticMessages: cachedMessages
                    )
                } catch {
                    cacheErrorMessage = error.localizedDescription
                    reloadedMessages = loadedMessages
                }
            } else {
                reloadedMessages = loadedMessages
            }
            applyCompressionAnchorMetadata(from: session)
            applyReloadedMessages(
                reloadedMessages,
                from: session,
                previousMessages: previousMessages,
                previousMessagesOffset: previousMessagesOffset
            )
            if renderedCacheFirst {
                // The taller server transcript has now replaced the lighter cache-first
                // render; signal the view to re-pin to the bottom without a visible jump.
                cacheFirstReconcileScrollToken += 1
            }
            clearCacheFirstMessagePlaceholder()
            latestServerLoadHadAssistantResponseAfterLatestUser = Self.hasAssistantResponseAfterLatestUser(
                in: messages
            )
            responseCompletionNeedsTranscriptRefresh = false
            isViewingCachedData = false
            contextWindowSnapshot = ContextWindowSnapshot(
                contextLength: session?.contextLength,
                thresholdTokens: session?.thresholdTokens,
                lastPromptTokens: session?.lastPromptTokens,
                inputTokens: session?.inputTokens,
                outputTokens: session?.outputTokens,
                estimatedCost: session?.estimatedCost
            )
            if let modelContext {
                do {
                    try CacheStore.cacheMessages(Self.cacheMessageWindow(from: messages), serverURL: server, sessionID: sessionID, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }
            if let title = session?.title {
                displayTitle = Self.displayTitle(from: title)
            }
            setCompletedToolCallGroups(ToolCallGroup.groups(
                persistedToolCalls: session?.toolCalls ?? [],
                messages: messages,
                messageOffset: messagesOffset
            ))
            let preserveLiveChrome = ChatLiveReconcilePolicy.shouldPreserveLiveRunChrome(
                loadedActiveStreamID: loadedActiveStreamID,
                localActiveStreamID: activeStreamID ?? streamIDAtLoadStart
            )
            if !preserveLiveChrome {
                completedReasoningGroups = []
                liveToolCalls = []
                liveReasoningText = ""
                pinnedLocalNotices = []
                toolCallAnchorMessageID = nil
                reasoningAnchorMessageID = nil
                attachmentCoordinator.removeAllLocalPreviews()
            }
            streamCoordinator.reconcileSessionLoad(
                loadedActiveStreamID: loadedActiveStreamID,
                preparation: streamLoadPreparation,
                usedCacheFallback: false
            )
        } catch {
            guard messageLoadGeneration == generation else { return }
            guard allowApplyDuringLocalStart || (!isStartingChat && !isEditingMessage && !isRegeneratingMessage) else { return }
            guard streamIDAtLoadStart != nil || activeStreamID == nil else { return }
            lastError = error
            latestServerLoadHadAssistantResponseAfterLatestUser = false
            if CacheFallbackPolicy.shouldUseCache(for: error), let modelContext {
                do {
                    let cachedMessages = try CacheStore.cachedMessages(
                        serverURL: server,
                        sessionID: sessionID,
                        in: modelContext,
                        limit: Self.messagePageLimit
                    )
                    if !cachedMessages.isEmpty {
                        clearCompressionAnchorMetadata()
                        withBatchedTranscriptDerivedState {
                            messages = cachedMessages
                            messagesOffset = 0
                        }
                        latestServerLoadHadAssistantResponseAfterLatestUser = Self.hasAssistantResponseAfterLatestUser(
                            in: messages
                        )
                        responseCompletionNeedsTranscriptRefresh = false
                        hasOlderMessages = false
                        isViewingCachedData = true
                        contextWindowSnapshot = nil
                        errorMessage = nil
                        setCompletedToolCallGroups([])
                        completedReasoningGroups = []
                        liveToolCalls = []
                        liveReasoningText = ""
                        pinnedLocalNotices = []
                        toolCallAnchorMessageID = nil
                        reasoningAnchorMessageID = nil
                        streamingAssistantMessageID = nil
                        attachmentCoordinator.removeAllLocalPreviews()
                        clearCacheFirstMessagePlaceholder()
                        streamCoordinator.reconcileSessionLoad(
                            loadedActiveStreamID: nil,
                            preparation: streamLoadPreparation,
                            usedCacheFallback: true
                        )
                    } else {
                        revertCacheFirstPlaceholderIfNeeded()
                        isViewingCachedData = false
                        errorMessage = error.localizedDescription
                    }
                } catch {
                    revertCacheFirstPlaceholderIfNeeded()
                    cacheErrorMessage = error.localizedDescription
                    isViewingCachedData = false
                    errorMessage = lastError?.localizedDescription
                }
            } else {
                revertCacheFirstPlaceholderIfNeeded()
                isViewingCachedData = false
                errorMessage = error.localizedDescription
            }
        }
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
        if usesDirectGateway { return await loadOlderDirectMessages(modelContext: modelContext) }
        guard let sessionID else {
            errorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard !isLoadingOlderMessages, hasOlderMessages else {
            return false
        }

        guard messagesOffset > 0 else {
            hasOlderMessages = false
            return false
        }

        resetPendingStreamingContentBuffers()
        let messageBefore = messagesOffset
        isLoadingOlderMessages = true
        errorMessage = nil
        cacheErrorMessage = nil
        lastError = nil
        defer { isLoadingOlderMessages = false }

        do {
            let response = try await client.session(
                id: sessionID,
                includeMessages: true,
                messageLimit: Self.messagePageLimit,
                messageBefore: messageBefore
            )
            guard let session = response.session else {
                hasOlderMessages = false
                return false
            }

            let olderMessages = session.messages ?? []
            let mergedMessages = Self.prependingOlderMessages(olderMessages, to: messages)
            let didAddMessages = mergedMessages.count > messages.count
            applyCompressionAnchorMetadata(from: session)
            withBatchedTranscriptDerivedState {
                messages = mergedMessages
                updateOlderMessagePagination(from: session, loadedMessageCount: mergedMessages.count)
            }
            latestServerLoadHadAssistantResponseAfterLatestUser = Self.hasAssistantResponseAfterLatestUser(
                in: messages
            )
            responseCompletionNeedsTranscriptRefresh = false
            isViewingCachedData = false
            contextWindowSnapshot = ContextWindowSnapshot(
                contextLength: session.contextLength,
                thresholdTokens: session.thresholdTokens,
                lastPromptTokens: session.lastPromptTokens,
                inputTokens: session.inputTokens,
                outputTokens: session.outputTokens,
                estimatedCost: session.estimatedCost
            )
            if let title = session.title {
                displayTitle = Self.displayTitle(from: title)
            }
            currentWorkspace = session.workspace ?? currentWorkspace
            currentModel = session.model ?? currentModel
            currentModelProvider = session.modelProvider ?? currentModelProvider
            currentProfile = session.profile ?? currentProfile
            setCompletedToolCallGroups(ToolCallGroup.groups(
                persistedToolCalls: session.toolCalls ?? [],
                messages: messages,
                messageOffset: messagesOffset
            ))
            completedReasoningGroups = []

            if let modelContext {
                do {
                    try CacheStore.cacheMessages(Self.cacheMessageWindow(from: messages), serverURL: server, sessionID: sessionID, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            return didAddMessages
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
            return false
        }
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

    nonisolated private static func mergingLoadedMessages(
        _ loadedMessages: [ChatMessage],
        withActiveStreamSnapshot snapshot: ActiveChatStreamSnapshot
    ) -> ActiveStreamMessageMerge {
        guard !snapshot.messages.isEmpty else {
            return ActiveStreamMessageMerge(
                messages: loadedMessages,
                streamingAssistantMessageID: latestAssistantMessageID(in: loadedMessages),
                usedSnapshotMessagesOffset: false
            )
        }

        guard let snapshotAssistantMessageID = snapshot.streamingAssistantMessageID,
              let snapshotAssistant = snapshot.messages.first(where: { $0.messageId == snapshotAssistantMessageID })
        else {
            if loadedMessages.isEmpty {
                return ActiveStreamMessageMerge(
                    messages: snapshot.messages,
                    streamingAssistantMessageID: latestAssistantMessageID(in: snapshot.messages),
                    usedSnapshotMessagesOffset: true
                )
            }

            return ActiveStreamMessageMerge(
                messages: loadedMessages,
                streamingAssistantMessageID: latestAssistantMessageID(in: loadedMessages),
                usedSnapshotMessagesOffset: false
            )
        }

        guard !loadedMessages.isEmpty else {
            return ActiveStreamMessageMerge(
                messages: snapshot.messages,
                streamingAssistantMessageID: snapshotAssistant.messageId,
                usedSnapshotMessagesOffset: true
            )
        }

        var mergedMessages = loadedMessages
        let latestUserIndex = mergedMessages.lastIndex { $0.role == "user" }
        let assistantSearchRange: Range<Int>
        if let latestUserIndex {
            assistantSearchRange = mergedMessages.index(after: latestUserIndex)..<mergedMessages.endIndex
        } else {
            assistantSearchRange = mergedMessages.startIndex..<mergedMessages.endIndex
        }

        if let assistantIndex = assistantSearchRange.reversed().first(where: { mergedMessages[$0].role == "assistant" }) {
            let loadedAssistant = mergedMessages[assistantIndex]
            mergedMessages[assistantIndex] = ChatMessage(
                role: loadedAssistant.role,
                content: reconciledActiveStreamContent(
                    loadedContent: loadedAssistant.content,
                    snapshotContent: snapshotAssistant.content
                ),
                timestamp: loadedAssistant.timestamp ?? snapshotAssistant.timestamp,
                messageId: loadedAssistant.messageId ?? snapshotAssistant.messageId,
                name: loadedAssistant.name ?? snapshotAssistant.name,
                toolCallId: loadedAssistant.toolCallId ?? snapshotAssistant.toolCallId,
                toolUseId: loadedAssistant.toolUseId ?? snapshotAssistant.toolUseId,
                toolCalls: loadedAssistant.toolCalls ?? snapshotAssistant.toolCalls,
                contentParts: loadedAssistant.contentParts ?? snapshotAssistant.contentParts,
                reasoning: loadedAssistant.reasoning ?? snapshotAssistant.reasoning,
                attachments: loadedAssistant.attachments ?? snapshotAssistant.attachments,
                turnTps: loadedAssistant.turnTps ?? snapshotAssistant.turnTps
            )
            return ActiveStreamMessageMerge(
                messages: mergedMessages,
                streamingAssistantMessageID: mergedMessages[assistantIndex].messageId,
                usedSnapshotMessagesOffset: false
            )
        }

        if !messagesContainEquivalentMessage(mergedMessages, candidate: snapshotAssistant) {
            mergedMessages.append(snapshotAssistant)
        }

        return ActiveStreamMessageMerge(
            messages: mergedMessages,
            streamingAssistantMessageID: snapshotAssistant.messageId,
            usedSnapshotMessagesOffset: false
        )
    }

    nonisolated private static func reconciledActiveStreamContent(
        loadedContent: String?,
        snapshotContent: String?
    ) -> String? {
        let loaded = loadedContent ?? ""
        let snapshot = snapshotContent ?? ""

        if loaded.isEmpty {
            return snapshotContent
        }

        if snapshot.isEmpty {
            return loadedContent
        }

        if loaded.hasPrefix(snapshot) {
            return loadedContent
        }

        if snapshot.hasPrefix(loaded) {
            return snapshotContent
        }

        return loadedContent
    }

    nonisolated private static func messagesContainEquivalentMessage(
        _ messages: [ChatMessage],
        candidate: ChatMessage
    ) -> Bool {
        if let candidateID = candidate.messageId,
           messages.contains(where: { $0.messageId == candidateID }) {
            return true
        }

        let candidateContent = candidate.content?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidateContent?.isEmpty == false else { return false }

        return messages.contains { message in
            message.role == candidate.role &&
                message.content?.trimmingCharacters(in: .whitespacesAndNewlines) == candidateContent
        }
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

    nonisolated private static func remappedAnchorMessageID(
        _ anchorMessageID: String?,
        from snapshotStreamingAssistantMessageID: String?,
        to restoredStreamingAssistantMessageID: String?
    ) -> String? {
        guard let anchorMessageID,
              anchorMessageID == snapshotStreamingAssistantMessageID,
              snapshotStreamingAssistantMessageID != restoredStreamingAssistantMessageID
        else {
            return anchorMessageID
        }

        return restoredStreamingAssistantMessageID ?? anchorMessageID
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

    nonisolated private static func latestAssistantMessageID(in messages: [ChatMessage]) -> String? {
        messages.last(where: { $0.role == "assistant" })?.messageId
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

    private func prepareForNewResponse() {
        // A response started locally supersedes any transcript refresh that began
        // while the chat was idle. Invalidate before the start request awaits so a
        // delayed `/api/session` response cannot replace optimistic/live rows or
        // clear the new stream ID.
        messageLoadGeneration &+= 1
        endConnectionWait()
        clearCacheFirstMessagePlaceholder()
        streamCoordinator.prepareForNewResponse()
    }

    func sendMessage(_ draft: String, modelContext: ModelContext? = nil) async -> Bool {
        if usesDirectGateway { return await sendDirectMessage(draft, modelContext: modelContext) }
        guard !isViewingCachedData else {
            sendErrorMessage = String(localized: "Reconnect to the server to send a message.")
            return false
        }

        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return false }

        guard let sessionID else {
            sendErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let localMessageID = "local-\(UUID().uuidString)"
        let attachmentPreparation = attachmentCoordinator.prepareForSend(localMessageID: localMessageID)

        return await performChatSend(
            sessionID: sessionID,
            localMessageID: localMessageID,
            displayContent: message,
            messageForAPI: attachmentPreparation.chatMessageText(draft: message),
            messageAttachments: attachmentPreparation.messageAttachments,
            apiPayloads: attachmentPreparation.apiPayloads,
            attachmentsToRestoreOnFailure: attachmentPreparation.attachments,
            modelContext: modelContext
        )
    }

    /// Records → transcribes → uploads → sends a server-transcribed voice note
    /// (Telegram-style). The sent message's text is the transcript and its sole
    /// attachment is the audio clip, rendered as a playable note by the inline
    /// audio player. Aborts (toast, no partial send) if transcription fails or
    /// returns nothing. Returns true only if the chat send started.
    @discardableResult
    func sendVoiceNote(audioData: Data, filename: String, modelContext: ModelContext? = nil) async -> Bool {
        guard !usesDirectGateway else {
            sendErrorMessage = "Direct Hermes voice attachments are not available yet."
            return false
        }
        // Reentrancy guard: bail if a voice note OR a regular chat send is already
        // in flight. `performChatSend` has no internal guard, so two overlapping
        // sends would both flip `isStartingChat`/`isSendingVoiceNote` and race their
        // `defer { … = false }` (clearing the flag while the other still runs, and
        // firing two concurrent `startChat`s). The UI already blocks this; the guard
        // keeps a future caller (accessibility shortcut, test harness) safe too.
        guard !isSendingVoiceNote, !isStartingChat else { return false }
        guard !isViewingCachedData else {
            setUploadAttachmentError(String(localized: "Reconnect to the server to send a voice note."))
            return false
        }
        guard !audioData.isEmpty else { return false }
        guard let sessionID else {
            setUploadAttachmentError(String(localized: "The server did not provide a session ID."))
            return false
        }

        isSendingVoiceNote = true
        setUploadAttachmentError(nil)
        sendErrorMessage = nil
        lastError = nil
        defer { isSendingVoiceNote = false }

        // 1. Transcribe via server STT. Any error or empty transcript aborts the
        //    whole send — no fallback, no partial message (per the issue).
        let transcript: String
        do {
            let response = try await client.transcribeAudio(data: audioData, filename: filename)
            if let serverError = response.error?.trimmingCharacters(in: .whitespacesAndNewlines),
               !serverError.isEmpty {
                setUploadAttachmentError(serverError)
                return false
            }
            let text = (response.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                setUploadAttachmentError(String(localized: "Couldn't transcribe that voice note. Try recording again."))
                return false
            }
            transcript = text
        } catch {
            lastError = error
            setUploadAttachmentError(error.localizedDescription)
            return false
        }

        // 2. Upload the clip as a standalone attachment (kept out of the composer's
        //    pending list). On failure the coordinator already surfaced the error.
        guard let pending = await attachmentCoordinator.uploadStandaloneAttachment(
            data: audioData,
            filename: filename
        ) else {
            return false
        }

        // 3. Send a chat message: text = transcript, attachments = [the clip].
        let messageAttachment = MessageAttachment(
            name: pending.name,
            path: pending.path,
            mime: pending.mime,
            size: pending.size,
            isImage: pending.isImage
        )
        let localMessageID = "local-\(UUID().uuidString)"
        // The API message text is the bare transcript — NOT chatMessageText(…),
        // which would append a "[Attached files: <clip>.m4a]" suffix. That suffix
        // is the agent's only signal about a non-image attachment (the server
        // strips attachment metadata before the model call and never embeds audio),
        // so it makes the agent try to "inspect" / transcribe the clip itself
        // instead of just answering the transcript. The clip still rides along in
        // `messageAttachments` / `apiPayloads` purely so the inline player renders
        // and persists; it's display-only and never reaches the model. (#330)
        return await performChatSend(
            sessionID: sessionID,
            localMessageID: localMessageID,
            displayContent: transcript,
            messageForAPI: transcript,
            messageAttachments: [messageAttachment],
            apiPayloads: [pending.toJSONValue()],
            attachmentsToRestoreOnFailure: [],
            modelContext: modelContext
        )
    }

    /// Shared optimistic-append + `startChat` + rollback core used by both the
    /// text composer (`sendMessage`) and the voice-note flow (`sendVoiceNote`).
    /// `attachmentsToRestoreOnFailure` is re-staged into the composer if the send
    /// fails — empty for voice notes, whose clip isn't a composer attachment.
    private func performChatSend(
        sessionID: String,
        localMessageID: String,
        displayContent: String,
        messageForAPI: String,
        messageAttachments: [MessageAttachment],
        apiPayloads: [JSONValue]?,
        attachmentsToRestoreOnFailure: [PendingAttachment],
        modelContext: ModelContext?
    ) async -> Bool {
        do {
            try await client.validateChatAttachments(apiPayloads)
        } catch {
            sendErrorMessage = error.localizedDescription
            lastError = error
            return false
        }
        isStartingChat = true
        sendErrorMessage = nil
        lastError = nil
        archiveLiveReasoningIfNeeded()
        archiveLiveToolCallsIfNeeded()
        liveReasoningText = ""
        liveToolCalls = []
        reasoningAnchorMessageID = nil
        toolCallAnchorMessageID = nil
        prepareForNewResponse()
        responseCompletionNeedsTranscriptRefresh = false
        defer { isStartingChat = false }

        let optimisticMessage = ChatMessage(
            role: "user",
            content: displayContent,
            timestamp: Date().timeIntervalSince1970,
            messageId: localMessageID,
            attachments: messageAttachments.isEmpty ? nil : messageAttachments
        )
        messages.append(optimisticMessage)

        cacheCurrentMessages(sessionID: sessionID, modelContext: modelContext)

        do {
            let explicitModelPick = explicitModelPickForChatStart()
            let response = try await client.startChat(
                sessionID: sessionID,
                message: messageForAPI,
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName,
                explicitModelPick: explicitModelPick,
                attachments: apiPayloads
            )

            guard let streamID = response.streamId else {
                sendErrorMessage = response.error ?? String(localized: "The server did not return a stream ID.")
                rollbackOptimisticMessage(id: localMessageID)
                cacheCurrentMessages(sessionID: sessionID, modelContext: modelContext)
                restorePendingAttachments(attachmentsToRestoreOnFailure)
                return false
            }

            completeExplicitModelPickForChatStart(explicitModelPick)
            messageLoadGeneration &+= 1
            streamCoordinator.start(streamID: streamID)
            return true
        } catch {
            if let streamID = (error as? APIError)?.activeStreamID {
                rollbackOptimisticMessage(id: localMessageID)
                cacheCurrentMessages(sessionID: sessionID, modelContext: modelContext)
                restorePendingAttachments(attachmentsToRestoreOnFailure)
                // The existing run may have started outside this view model. Reconcile
                // the server transcript first so the SSE tokens attach to the persisted
                // assistant turn instead of creating a second bubble with only the tail.
                await loadMessages(modelContext: modelContext, allowApplyDuringLocalStart: true)
                _ = restoreActiveStreamSnapshotIfAvailable(streamID: streamID)
                streamingAssistantMessageID = TranscriptTurnClassifier
                    .currentTurnAssistantAnchorIDs(in: messages, messageOffset: messagesOffset)
                    .first
                streamCoordinator.start(streamID: streamID)
                // The server kept the earlier run, not this newly submitted text.
                // Report an unaccepted send so ChatView restores the draft while
                // the coordinator reconnects to the existing response.
                return false
            }
            lastError = error
            sendErrorMessage = CacheFallbackPolicy.sendBannerMessage(for: error)
            rollbackOptimisticMessage(id: localMessageID)
            cacheCurrentMessages(sessionID: sessionID, modelContext: modelContext)
            restorePendingAttachments(attachmentsToRestoreOnFailure)
            return false
        }
    }

    func submitGoal(args rawArgs: String, modelContext: ModelContext? = nil) async -> Bool {
        guard !usesDirectGateway else {
            goalErrorMessage = String(localized: "Goals are not available in direct Hermes mode yet.")
            sendErrorMessage = goalErrorMessage
            return false
        }

        guard !isViewingCachedData else {
            goalErrorMessage = String(localized: "Reconnect to the server to manage goals.")
            sendErrorMessage = goalErrorMessage
            return false
        }

        let args = rawArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !args.isEmpty else { return false }

        guard let sessionID else {
            goalErrorMessage = String(localized: "The server did not provide a session ID.")
            sendErrorMessage = goalErrorMessage
            return false
        }

        guard activeStreamID == nil else {
            goalErrorMessage = String(localized: "Wait for the current response to finish before changing goals.")
            sendErrorMessage = goalErrorMessage
            return false
        }

        isSubmittingGoal = true
        goalErrorMessage = nil
        sendErrorMessage = nil
        lastError = nil
        defer { isSubmittingGoal = false }

        do {
            let response = try await client.submitGoal(
                sessionID: sessionID,
                args: args,
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName
            )

            currentGoal = response.goal

            if response.ok == false || response.action?.lowercased() == "error" {
                goalErrorMessage = response.displayMessage ?? String(localized: "Goal request failed.")
                sendErrorMessage = goalErrorMessage
                return false
            }

            hasActivatedGoalCommand = true

            guard response.kickoffPromptText != nil else {
                if let message = response.displayMessage {
                    appendLocalNoticeMessage(message)
                }
                return true
            }

            return await attachGoalKickoffStream(
                noticeMessage: response.displayMessage,
                modelContext: modelContext
            )
        } catch {
            lastError = error
            goalErrorMessage = error.localizedDescription
            sendErrorMessage = goalErrorMessage
            return false
        }
    }

    private func attachGoalKickoffStream(noticeMessage: String?, modelContext: ModelContext?) async -> Bool {
        guard !usesDirectGateway else {
            goalErrorMessage = String(localized: "Goals are not available in direct Hermes mode yet.")
            sendErrorMessage = goalErrorMessage
            return false
        }

        await loadMessages(modelContext: modelContext)

        if let errorMessage {
            goalErrorMessage = errorMessage
            sendErrorMessage = errorMessage
            return false
        }

        guard let streamID = activeStreamID else {
            if let noticeMessage {
                appendLocalNoticeMessage(noticeMessage)
            }
            return true
        }

        if streamingAssistantMessageID == nil {
            restoreActiveStreamSnapshotIfAvailable(streamID: streamID)
        }
        if streamingAssistantMessageID == nil {
            streamingAssistantMessageID = Self.latestAssistantMessageID(in: messages)
        }
        if let noticeMessage {
            pinLocalNoticeMessage(noticeMessage)
        }

        streamCoordinator.start(streamID: streamID)
        return true
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
            try CacheStore.cacheMessages(Self.cacheMessageWindow(from: messages), serverURL: server, sessionID: transcriptCacheID(sessionID), in: modelContext)
        } catch {
            cacheErrorMessage = error.localizedDescription
        }
    }

    func cacheCompletedResponse(modelContext: ModelContext) {
        guard let sessionID else { return }
        cacheCurrentMessages(sessionID: sessionID, modelContext: modelContext)
    }

    func clearTranscript() {
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
        let message = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /steer <message>"))
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard activeStreamID != nil else {
            let sent = await sendMessage(message)
            return sent ? .executed(message: nil) : .unsupported(friendlyMessage: sendErrorMessage ?? String(localized: "Could not send the steering message."))
        }

        do {
            let response = try await client.steerChat(sessionID: sessionID, text: message)
            if response.accepted == true {
                return .executed(message: String(localized: "Steering hint delivered."))
            }
        } catch {
            lastError = error
        }

        _ = enqueueQueuedSlashMessage(message, attachments: attachmentCoordinator.consumePendingAttachments())
        await cancelActiveStream()
        return .executed(message: String(localized: "Steer was unavailable, so the message was queued and the current response was stopped."))
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
        let backgroundTasks = backgroundPromptsByTaskID.count
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
        guard !usesDirectGateway else {
            return .unsupported(friendlyMessage: String(localized: "/btw is not available in direct Hermes mode yet."))
        }

        let question = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /btw <question>"))
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to ask a side question."))
        }

        guard !isCLISession else {
            return .unsupported(friendlyMessage: String(localized: "/btw is available for WebUI sessions only."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before using /btw."))
        }

        guard activeBtwStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current /btw answer to finish first."))
        }

        do {
            let response = try await client.startBtw(sessionID: sessionID, question: question)
            if let error = response.error, !error.isEmpty {
                return .unsupported(friendlyMessage: error)
            }

            guard let streamID = response.streamId, !streamID.isEmpty else {
                return .unsupported(friendlyMessage: String(localized: "The server did not return a /btw stream."))
            }

            startBtwStream(streamID: streamID, question: question)
            return .executed(message: nil)
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func startBackgroundFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        guard !usesDirectGateway else {
            return .unsupported(friendlyMessage: String(localized: "/background is not available in direct Hermes mode yet."))
        }

        let prompt = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /background <prompt>"))
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to start a background task."))
        }

        guard !isCLISession else {
            return .unsupported(friendlyMessage: String(localized: "/background is available for WebUI sessions only."))
        }

        do {
            let response = try await client.startBackground(sessionID: sessionID, prompt: prompt)
            if let error = response.error, !error.isEmpty {
                return .unsupported(friendlyMessage: error)
            }

            guard let taskID = response.taskId, !taskID.isEmpty else {
                return .unsupported(friendlyMessage: String(localized: "The server did not return a background task."))
            }

            backgroundPromptsByTaskID[taskID] = prompt
            startBackgroundPollingIfNeeded(parentSessionID: sessionID)
            return .executed(message: String(localized: "Background task started. I'll add the result here when it completes."))
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
        guard !usesDirectGateway else {
            return .unsupported(friendlyMessage: "Use the model picker in New Chat before sending its first message.")
        }
        let requestedModel = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedModel.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /model <id>"))
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard canRunConfigurationSlashCommand(String(localized: "change models")) else {
            return .unsupported(friendlyMessage: composerConfigurationErrorMessage ?? String(localized: "Model switching is unavailable."))
        }

        let match = modelOption(matching: requestedModel)

        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        sendErrorMessage = nil
        lastError = nil
        defer { isUpdatingComposerConfiguration = false }

        do {
            let response = try await client.updateSession(
                id: sessionID,
                workspace: currentWorkspace,
                model: match?.id ?? requestedModel,
                modelProvider: match?.providerID
            )

            currentModel = response.session?.model ?? match?.id ?? requestedModel
            currentModelProvider = response.session?.modelProvider ?? match?.providerID ?? currentModelProvider
            currentWorkspace = response.session?.workspace ?? currentWorkspace
            pendingExplicitModelPick = true
            await refreshReasoningEffortGating()
            return .executed(message: nil)
        } catch {
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func switchWorkspaceFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        if usesDirectGateway {
            let changed = await selectWorkspacePath(args)
            return changed ? .executed(message: nil) : .unsupported(friendlyMessage: composerConfigurationErrorMessage ?? "Workspace was not changed.")
        }
        let requestedWorkspace = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedWorkspace.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /workspace <path>"))
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard canRunConfigurationSlashCommand(String(localized: "change workspace")) else {
            return .unsupported(friendlyMessage: composerConfigurationErrorMessage ?? String(localized: "Workspace switching is unavailable."))
        }

        let workspace = workspacePath(matching: requestedWorkspace) ?? requestedWorkspace

        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        sendErrorMessage = nil
        lastError = nil
        defer { isUpdatingComposerConfiguration = false }

        do {
            let response = try await client.updateSession(
                id: sessionID,
                workspace: workspace,
                model: currentModel,
                modelProvider: currentModelProvider
            )

            currentWorkspace = response.session?.workspace ?? workspace
            currentModel = response.session?.model ?? currentModel
            currentModelProvider = response.session?.modelProvider ?? currentModelProvider
            workspaceSuggestions = workspaceRoots.compactMap(\.path)
            return .executed(message: nil)
        } catch {
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func switchReasoningFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        if usesDirectGateway {
            let changed = await selectReasoningEffort(args)
            return changed ? .executed(message: nil) : .unsupported(friendlyMessage: composerConfigurationErrorMessage ?? "Use a supported reasoning level in New Chat. Server-wide display changes are not available here.")
        }
        let reasoning = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !reasoning.isEmpty else {
            let levels = SlashCommandCatalog.availableReasoningLevels(
                forSupportedEfforts: supportedReasoningEfforts
            )
            let usage = (["show", "hide"] + levels).joined(separator: "|")
            return .unsupported(friendlyMessage: String(localized: "Usage: /reasoning \(usage)|inherit"))
        }

        guard canRunConfigurationSlashCommand(String(localized: "change reasoning")) else {
            return .unsupported(friendlyMessage: composerConfigurationErrorMessage ?? String(localized: "Reasoning changes are unavailable."))
        }

        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        sendErrorMessage = nil
        lastError = nil
        defer { isUpdatingComposerConfiguration = false }

        reasoningSelectionToken &+= 1
        let selectionToken = reasoningSelectionToken
        let expectedSessionID = canonicalSessionID
        let expectedModel = currentModel
        let expectedProvider = currentModelProvider

        do {
            if Self.reasoningDisplayArgs.contains(reasoning) {
                _ = try await client.saveReasoningDisplay(reasoning)
            } else if Self.reasoningClearArgs.contains(reasoning) {
                guard sessionScopedReasoning == true else {
                    return .unsupported(friendlyMessage: String(localized: "Session reasoning inheritance is unavailable on this server."))
                }
                guard let expectedSessionID else {
                    return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
                }
                let response = try await client.saveReasoningEffort(
                    "",
                    sessionID: expectedSessionID
                )
                guard selectionToken == reasoningSelectionToken,
                      expectedSessionID == canonicalSessionID,
                      expectedModel == currentModel,
                      expectedProvider == currentModelProvider
                else {
                    return .unsupported(
                        friendlyMessage: composerConfigurationErrorMessage
                            ?? String(localized: "Reasoning changes are unavailable.")
                    )
                }

                sessionScopedReasoning = response.sessionScopedReasoning ?? sessionScopedReasoning
                sessionReasoningEffort = nil
                selectedReasoningEffort = response.effectiveEffort ?? selectedReasoningEffort
            } else if Self.reasoningEffortArgs.contains(reasoning)
                || supportedReasoningEfforts?.contains(reasoning) == true {
                if sessionScopedReasoning == true && expectedSessionID == nil {
                    return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
                }
                let response = try await client.saveReasoningEffort(
                    reasoning,
                    sessionID: sessionScopedReasoning == true ? expectedSessionID : nil
                )
                guard selectionToken == reasoningSelectionToken,
                      expectedSessionID == canonicalSessionID,
                      expectedModel == currentModel,
                      expectedProvider == currentModelProvider
                else {
                    return .unsupported(
                        friendlyMessage: composerConfigurationErrorMessage
                            ?? String(localized: "Reasoning changes are unavailable.")
                    )
                }

                sessionScopedReasoning = response.sessionScopedReasoning ?? sessionScopedReasoning
                sessionReasoningEffort = response.normalizedSessionReasoningEffort
                    ?? (sessionScopedReasoning == true ? reasoning : nil)
                selectedReasoningEffort = response.effectiveEffort ?? reasoning
            } else {
                return .unsupported(friendlyMessage: String(localized: "Unknown reasoning level: \(reasoning)."))
            }
            return .executed(message: nil)
        } catch {
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func renameSessionFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        guard !usesDirectGateway else {
            return .unsupported(friendlyMessage: String(localized: "/title is not available in direct Hermes mode yet."))
        }

        let title = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return .executed(message: String(localized: "Current title: **\(displayTitle)**\n\nUse `/title <text>` to rename this session."))
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before renaming the session."))
        }

        lastError = nil
        sendErrorMessage = nil

        do {
            let response = try await client.renameSession(id: sessionID, title: title)
            if let error = response.error {
                return .unsupported(friendlyMessage: error)
            }
            displayTitle = Self.displayTitle(from: response.session?.title ?? title)
            return .executed(message: String(localized: "Title set to **\(displayTitle)**."))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func setPersonalityFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        guard !usesDirectGateway else {
            return .unsupported(friendlyMessage: String(localized: "/personality is not available in direct Hermes mode yet."))
        }

        let requestedPersonality = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedPersonality.isEmpty else {
            return await personalityListMessage()
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before changing personality."))
        }

        let normalized = requestedPersonality.lowercased()
        let name = Self.personalityClearArgs.contains(normalized) ? "" : requestedPersonality

        lastError = nil
        sendErrorMessage = nil

        do {
            let response = try await client.setPersonality(sessionID: sessionID, name: name)
            if let error = response.error {
                return .unsupported(friendlyMessage: error)
            }

            if name.isEmpty || response.personality == nil {
                return .executed(message: String(localized: "Personality cleared."))
            }

            return .executed(message: String(localized: "Personality set to **\(response.personality ?? name)**."))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func personalityListMessage() async -> SlashCommandExecutionResult {
        guard !usesDirectGateway else {
            return .unsupported(friendlyMessage: String(localized: "/personality is not available in direct Hermes mode yet."))
        }

        do {
            let personalities = (try await client.personalities()).personalities ?? []
            guard !personalities.isEmpty else {
                return .executed(message: String(localized: "No personalities are configured on the server."))
            }

            let list = personalities.compactMap { personality -> String? in
                guard let name = personality.name, !name.isEmpty else { return nil }
                if let description = personality.description, !description.isEmpty {
                    return "- **\(name)** - \(description)"
                }
                return "- **\(name)**"
            }
            .joined(separator: "\n")

            return .executed(message: String(localized: "Available personalities:\n\n\(list)\n\nUse `/personality <name>` or `/personality none`."))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func searchSkillsFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        guard !usesDirectGateway else {
            return .unsupported(friendlyMessage: String(localized: "Skills are not available in direct Hermes mode yet."))
        }

        do {
            let suggestions = try await skillSuggestionsForSlashCommand()
            if let invocation = SlashSkillFormatter.invocation(from: args, suggestions: suggestions) {
                let sent = await sendMessage(SlashSkillFormatter.messageText(for: invocation))
                if sent {
                    return .executed(message: nil)
                }
                return .unsupported(friendlyMessage: sendErrorMessage ?? String(localized: "Could not send the skill message."))
            }

            return .executed(message: SlashSkillFormatter.message(for: suggestions, query: SlashSkillFormatter.skillQuery(from: args)))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    func executeSkillShortcutCommand(name: String, args: String) async -> SlashCommandExecutionResult? {
        guard !usesDirectGateway else {
            return .unsupported(friendlyMessage: String(localized: "Skills are not available in direct Hermes mode yet."))
        }

        do {
            let suggestions = try await skillSuggestionsForSlashCommand()
            guard let skill = SlashSkillFormatter.skill(named: name, in: suggestions) else {
                return nil
            }

            let message = args.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                return .executed(message: SlashSkillFormatter.detailMessage(for: skill))
            }

            let commandText = "/\(skill.slashName) \(message)"
            let sent = await sendMessage(commandText)
            if sent {
                return .executed(message: nil)
            }
            return .unsupported(friendlyMessage: sendErrorMessage ?? String(localized: "Could not send the skill message."))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func skillSuggestionsForSlashCommand() async throws -> [SkillSlashSuggestion] {
        if hasLoadedSkillSlashSuggestions {
            return skillSlashSuggestions
        }

        let response = try await client.skills()
        let suggestions = SlashSkillFormatter.suggestions(from: response.skills ?? [])
        skillSlashSuggestions = suggestions
        hasLoadedSkillSlashSuggestions = true
        return suggestions
    }

    private func branchSessionFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        guard !usesDirectGateway else {
            return .unsupported(friendlyMessage: String(localized: "Forking is not available in direct Hermes mode yet."))
        }

        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to fork a conversation."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before forking."))
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        let title = args.trimmingCharacters(in: .whitespacesAndNewlines)

        isForkingMessage = true
        messageActionErrorMessage = nil
        lastError = nil
        sendErrorMessage = nil
        defer { isForkingMessage = false }

        do {
            let response = try await client.branchSession(
                id: sessionID,
                title: title.isEmpty ? nil : title
            )

            guard let forkedSessionID = response.sessionId else {
                return .unsupported(
                    friendlyMessage: response.error ?? String(localized: "The server did not return the forked session ID.")
                )
            }

            let forkedResponse = try await client.session(
                id: forkedSessionID,
                includeMessages: false,
                messageLimit: nil
            )

            guard let forkedSessionDetail = forkedResponse.session else {
                return .unsupported(friendlyMessage: String(localized: "The server did not return the forked session."))
            }

            return .openedSession(SessionSummary(from: forkedSessionDetail))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func createSessionFromSlashCommand() async -> SlashCommandExecutionResult {
        guard !usesDirectGateway else {
            return .unsupported(friendlyMessage: String(localized: "Use New Chat; direct Hermes creates sessions on first send."))
        }

        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to start a new session."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before starting a new session."))
        }

        isUpdatingComposerConfiguration = true
        lastError = nil
        sendErrorMessage = nil
        composerConfigurationErrorMessage = nil
        defer { isUpdatingComposerConfiguration = false }

        do {
            let response = try await client.createSession(
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName
            )

            guard let session = response.session else {
                return .unsupported(friendlyMessage: String(localized: "The server did not return the new session."))
            }

            return .openedSession(SessionSummary(from: session))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func compressSessionFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        guard !usesDirectGateway else {
            return .unsupported(friendlyMessage: String(localized: "Compression is not available in direct Hermes mode yet."))
        }

        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to compress context."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before compressing context."))
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        let focusTopic = args.trimmingCharacters(in: .whitespacesAndNewlines)

        isCompressingSession = true
        lastError = nil
        sendErrorMessage = nil
        messageActionErrorMessage = nil
        defer { isCompressingSession = false }

        do {
            let response = try await client.compressSession(
                id: sessionID,
                focusTopic: focusTopic.isEmpty ? nil : focusTopic
            )

            if let error = response.error {
                return .unsupported(friendlyMessage: error)
            }

            guard let session = response.session else {
                return .unsupported(friendlyMessage: String(localized: "The server did not return the compressed session."))
            }

            applyCompressionAnchorMetadata(from: session)
            withBatchedTranscriptDerivedState {
                messages = session.messages ?? []
                updateOlderMessagePagination(from: session, loadedMessageCount: messages.count)
            }
            isViewingCachedData = false
            let snapshot = ContextWindowSnapshot(
                contextLength: session.contextLength,
                thresholdTokens: session.thresholdTokens,
                lastPromptTokens: session.lastPromptTokens,
                inputTokens: session.inputTokens,
                outputTokens: session.outputTokens,
                estimatedCost: session.estimatedCost
            )
            contextWindowSnapshot = snapshot.replacingTokensUsed(response.summary?.compressedTokenEstimate)
            if let title = session.title {
                displayTitle = Self.displayTitle(from: title)
            }
            currentWorkspace = session.workspace ?? currentWorkspace
            currentModel = session.model ?? currentModel
            currentModelProvider = session.modelProvider ?? currentModelProvider
            currentProfile = session.profile ?? currentProfile
            setCompletedToolCallGroups(ToolCallGroup.groups(
                persistedToolCalls: session.toolCalls ?? [],
                messages: messages,
                messageOffset: messagesOffset
            ))
            completedReasoningGroups = []
            liveToolCalls = []
            liveReasoningText = ""
            streamingAssistantMessageID = nil
            toolCallAnchorMessageID = nil
            reasoningAnchorMessageID = nil
            prepareForNewResponse()
            responseCompletionNeedsTranscriptRefresh = false
            attachmentCoordinator.removeAllLocalPreviews()

            let headline = response.summary?.headline?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokenLine = response.summary?.tokenLine?.trimmingCharacters(in: .whitespacesAndNewlines)
            let focus = response.focusTopic?.trimmingCharacters(in: .whitespacesAndNewlines)
            let details = [headline, tokenLine, focus.map { String(localized: "Focus: \($0)") }]
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: "\n")

            if details.isEmpty {
                return .executed(message: String(localized: "Context compressed."))
            }

            return .executed(message: String(localized: "Context compressed.\n\n\(details)"))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func undoLastExchangeFromSlashCommand() async -> SlashCommandExecutionResult {
        guard !usesDirectGateway else {
            return .unsupported(friendlyMessage: String(localized: "Undo is not available in direct Hermes mode yet."))
        }

        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to undo messages."))
        }

        guard !isCLISession else {
            return .unsupported(friendlyMessage: String(localized: "Undo is available for WebUI sessions only."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before undoing messages."))
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        lastError = nil
        sendErrorMessage = nil

        do {
            let response = try await client.undoSession(id: sessionID)
            if let error = response.error {
                return .unsupported(friendlyMessage: error)
            }

            await loadMessages()
            if let lastError {
                return .unsupported(friendlyMessage: lastError.localizedDescription)
            }

            return .executed(message: nil)
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func retryLastTurnFromSlashCommand() async -> SlashCommandExecutionResult {
        guard !usesDirectGateway else {
            return .unsupported(friendlyMessage: String(localized: "Retry is not available in direct Hermes mode yet."))
        }

        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to retry messages."))
        }

        guard !isCLISession else {
            return .unsupported(friendlyMessage: String(localized: "Retry is available for WebUI sessions only."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before retrying messages."))
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        isStartingChat = true
        lastError = nil
        sendErrorMessage = nil
        archiveLiveReasoningIfNeeded()
        archiveLiveToolCallsIfNeeded()
        liveReasoningText = ""
        liveToolCalls = []
        reasoningAnchorMessageID = nil
        toolCallAnchorMessageID = nil
        prepareForNewResponse()
        responseCompletionNeedsTranscriptRefresh = false
        defer { isStartingChat = false }

        do {
            let retryResponse = try await client.retrySession(id: sessionID)
            if let error = retryResponse.error {
                return .unsupported(friendlyMessage: error)
            }

            let lastUserText = retryResponse.lastUserText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !lastUserText.isEmpty else {
                return .unsupported(friendlyMessage: String(localized: "The server did not return a message to retry."))
            }

            // Post-retry reload is NOT treated as a cold load (issue #168 non-goal): the
            // user already has the transcript in view, so keep the raw msg_limit cap and
            // leave expandRenderable at its default false.
            let sessionResponse = try await client.session(
                id: sessionID,
                includeMessages: true,
                messageLimit: Self.messagePageLimit
            )
            if let session = sessionResponse.session {
                withBatchedTranscriptDerivedState {
                    messages = session.messages ?? []
                    updateOlderMessagePagination(from: session, loadedMessageCount: messages.count)
                }
                setCompletedToolCallGroups(ToolCallGroup.groups(
                    persistedToolCalls: session.toolCalls ?? [],
                    messages: messages,
                    messageOffset: messagesOffset
                ))
                completedReasoningGroups = []
            } else {
                await loadMessages()
                if let lastError {
                    return .unsupported(friendlyMessage: lastError.localizedDescription)
                }
            }

            liveToolCalls = []
            liveReasoningText = ""
            toolCallAnchorMessageID = nil
            reasoningAnchorMessageID = nil
            attachmentCoordinator.removeAllLocalPreviews()

            let explicitModelPick = explicitModelPickForChatStart()
            let chatResponse = try await client.startChat(
                sessionID: sessionID,
                message: lastUserText,
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName,
                explicitModelPick: explicitModelPick
            )

            guard let streamID = chatResponse.streamId else {
                return .unsupported(friendlyMessage: chatResponse.error ?? String(localized: "The server did not return a stream ID after retrying."))
            }

            completeExplicitModelPickForChatStart(explicitModelPick)
            messages.append(
                ChatMessage(
                    role: "user",
                    content: lastUserText,
                    timestamp: Date().timeIntervalSince1970,
                    messageId: "local-\(UUID().uuidString)"
                )
            )

            messageLoadGeneration &+= 1
            streamCoordinator.start(streamID: streamID)
            return .executed(message: nil)
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func canRunConfigurationSlashCommand(_ actionDescription: String) -> Bool {
        if isViewingCachedData {
            composerConfigurationErrorMessage = String(localized: "Reconnect to the server to \(actionDescription).")
            return false
        }

        if activeStreamID != nil {
            composerConfigurationErrorMessage = String(localized: "Wait for the current response to finish before you \(actionDescription).")
            return false
        }

        return true
    }

    private func modelOption(matching query: String) -> ModelCatalogOption? {
        let normalizedQuery = query.lowercased()
        let options = modelCatalogGroups.flatMap(\.slashAutocompleteModels)

        if let exact = options.first(where: { $0.id.lowercased() == normalizedQuery }) {
            return exact
        }

        return options.first {
            $0.id.lowercased().contains(normalizedQuery) ||
            $0.displayName.lowercased().contains(normalizedQuery)
        }
    }

    private func workspacePath(matching query: String) -> String? {
        let normalizedQuery = query.lowercased()
        let roots = workspaceRoots.compactMap { root -> (path: String, name: String?)? in
            guard let path = root.path, !path.isEmpty else { return nil }
            return (path, root.name)
        }

        if let exact = roots.first(where: { $0.path.lowercased() == normalizedQuery }) {
            return exact.path
        }

        return roots.first {
            $0.path.lowercased().contains(normalizedQuery) ||
            ($0.name?.lowercased().contains(normalizedQuery) == true)
        }?.path
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
        guard !usesDirectGateway else {
            messageActionErrorMessage = String(localized: "Forking is not available in direct Hermes mode yet.")
            return nil
        }

        guard !isViewingCachedData else {
            messageActionErrorMessage = String(localized: "Reconnect to the server to fork a conversation.")
            return nil
        }

        guard activeStreamID == nil else {
            messageActionErrorMessage = String(localized: "Wait for the current response to finish before forking.")
            return nil
        }

        guard let sessionID else {
            messageActionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        isForkingMessage = true
        messageActionErrorMessage = nil
        lastError = nil
        defer { isForkingMessage = false }

        do {
            let response = try await client.branchSession(
                id: sessionID,
                keepCount: context.keepCountThroughMessage
            )

            guard let forkedSessionID = response.sessionId else {
                messageActionErrorMessage = response.error ?? String(localized: "The server did not return the forked session ID.")
                return nil
            }

            let forkedResponse = try await client.session(
                id: forkedSessionID,
                includeMessages: false,
                messageLimit: nil
            )

            guard let forkedSessionDetail = forkedResponse.session else {
                messageActionErrorMessage = String(localized: "The server did not return the forked session.")
                return nil
            }

            let forkedSession = SessionSummary(from: forkedSessionDetail)
            if let modelContext {
                do {
                    try CacheStore.cacheSession(forkedSession, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }
            return forkedSession
        } catch {
            lastError = error
            messageActionErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Edit a user message: truncate to just before the selected message, then send the edited text.
    func editMessage(_ context: MessageActionContext, newText: String, modelContext: ModelContext? = nil) async -> Bool {
        guard !usesDirectGateway else {
            messageActionErrorMessage = String(localized: "Editing is not available in direct Hermes mode yet.")
            return false
        }

        guard context.role == .user else {
            messageActionErrorMessage = String(localized: "Only user messages can be edited.")
            return false
        }

        guard !isViewingCachedData else {
            messageActionErrorMessage = String(localized: "Reconnect to the server to edit a message.")
            return false
        }

        guard activeStreamID == nil else {
            messageActionErrorMessage = String(localized: "Wait for the current response to finish before editing.")
            return false
        }

        guard let sessionID else {
            messageActionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let editedText = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editedText.isEmpty else {
            messageActionErrorMessage = String(localized: "The edited message cannot be empty.")
            return false
        }

        isEditingMessage = true
        messageActionErrorMessage = nil
        lastError = nil
        defer { isEditingMessage = false }

        do {
            // Truncate to remove the selected user message and everything after it
            let truncateResponse = try await client.truncateSession(
                id: sessionID,
                keepCount: context.fullHistoryIndex
            )

            // Update local state from the truncated response
            if let session = truncateResponse.session {
                withBatchedTranscriptDerivedState {
                    messages = session.messages ?? []
                    updateOlderMessagePagination(from: session, loadedMessageCount: messages.count)
                }
                setCompletedToolCallGroups(ToolCallGroup.groups(
                    persistedToolCalls: session.toolCalls ?? [],
                    messages: messages,
                    messageOffset: messagesOffset
                ))
                completedReasoningGroups = []
                liveToolCalls = []
                liveReasoningText = ""
                toolCallAnchorMessageID = nil
                reasoningAnchorMessageID = nil

                if let modelContext {
                    do {
                        try CacheStore.cacheMessages(Self.cacheMessageWindow(from: messages), serverURL: server, sessionID: sessionID, in: modelContext)
                    } catch {
                        cacheErrorMessage = error.localizedDescription
                    }
                }
            }

            // Now send the edited text through the normal chat flow
            let explicitModelPick = explicitModelPickForChatStart()
            prepareForNewResponse()
            responseCompletionNeedsTranscriptRefresh = false
            let chatResponse = try await client.startChat(
                sessionID: sessionID,
                message: editedText,
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName,
                explicitModelPick: explicitModelPick
            )

            guard let streamID = chatResponse.streamId else {
                messageActionErrorMessage = chatResponse.error ?? String(localized: "The server did not return a stream ID after editing.")
                return false
            }

            completeExplicitModelPickForChatStart(explicitModelPick)
            // Append the optimistic user message
            messages.append(
                ChatMessage(
                    role: "user",
                    content: editedText,
                    timestamp: Date().timeIntervalSince1970,
                    messageId: "local-\(UUID().uuidString)"
                )
            )

            messageLoadGeneration &+= 1
            streamCoordinator.start(streamID: streamID)
            return true
        } catch {
            lastError = error
            messageActionErrorMessage = error.localizedDescription
            return false
        }
    }

    func regenerateAssistantResponse(
        _ context: MessageActionContext,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        guard !usesDirectGateway else {
            messageActionErrorMessage = String(localized: "Regeneration is not available in direct Hermes mode yet.")
            return false
        }

        guard context.role == .assistant else {
            messageActionErrorMessage = String(localized: "Only assistant messages can be regenerated.")
            return false
        }

        guard !isViewingCachedData else {
            messageActionErrorMessage = String(localized: "Reconnect to the server to regenerate a response.")
            return false
        }

        guard activeStreamID == nil else {
            messageActionErrorMessage = String(localized: "Wait for the current response to finish before regenerating.")
            return false
        }

        guard let sessionID else {
            messageActionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard let userText = Self.precedingUserMessageText(in: messages, beforeVisibleIndex: context.visibleIndex) else {
            messageActionErrorMessage = String(localized: "Load older messages before regenerating this response.")
            return false
        }

        isRegeneratingMessage = true
        messageActionErrorMessage = nil
        lastError = nil
        stopListening()
        defer { isRegeneratingMessage = false }

        do {
            let truncateResponse = try await client.truncateSession(
                id: sessionID,
                keepCount: context.fullHistoryIndex
            )

            if let session = truncateResponse.session {
                withBatchedTranscriptDerivedState {
                    messages = session.messages ?? []
                    updateOlderMessagePagination(from: session, loadedMessageCount: messages.count)
                }
                setCompletedToolCallGroups(ToolCallGroup.groups(
                    persistedToolCalls: session.toolCalls ?? [],
                    messages: messages,
                    messageOffset: messagesOffset
                ))
                completedReasoningGroups = []
                liveToolCalls = []
                liveReasoningText = ""
                toolCallAnchorMessageID = nil
                reasoningAnchorMessageID = nil

                if let modelContext {
                    do {
                        try CacheStore.cacheMessages(Self.cacheMessageWindow(from: messages), serverURL: server, sessionID: sessionID, in: modelContext)
                    } catch {
                        cacheErrorMessage = error.localizedDescription
                    }
                }
            }

            let explicitModelPick = explicitModelPickForChatStart()
            prepareForNewResponse()
            responseCompletionNeedsTranscriptRefresh = false
            let chatResponse = try await client.startChat(
                sessionID: sessionID,
                message: userText,
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName,
                explicitModelPick: explicitModelPick
            )

            guard let streamID = chatResponse.streamId else {
                messageActionErrorMessage = chatResponse.error ?? String(localized: "The server did not return a stream ID after regenerating.")
                return false
            }

            completeExplicitModelPickForChatStart(explicitModelPick)
            messageLoadGeneration &+= 1
            streamCoordinator.start(streamID: streamID)
            return true
        } catch {
            lastError = error
            messageActionErrorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func cancelActiveStream() async -> Bool {
        if usesDirectGateway {
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
        guard activeStreamID != nil else { return false }

        isCancellingStream = true
        sendErrorMessage = nil
        lastError = nil
        defer { isCancellingStream = false }

        do {
            guard let response = try await streamCoordinator.cancelActiveStream() else { return false }
            if response.ok == false {
                sendErrorMessage = response.error ?? String(localized: "The server could not stop the current response.")
                return false
            }

            return true
        } catch {
            lastError = error
            sendErrorMessage = error.localizedDescription
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
        // stops cleanly instead of firing a second `/api/tts` call into the server's
        // ~2 s rate limit or stacking audio (#15).
        if listeningMessageID == context.messageID {
            stopListening()
            return
        }

        stopListening()
        // The audio session is NOT activated here: `/api/tts` can be slow or
        // unreachable, and activating the non-mixable playback session before the
        // fetch would silence other audio while Semreh has nothing to play (review
        // on #35). Activation happens at the two playback-start points instead —
        // `startServerAudioPlayback` and `speakWithOnDeviceSynthesizer`.
        listeningMessageID = context.messageID
        beginListenPlaybackPreparation(for: context)

        guard ServerTTSPolicy.shouldUseServerTTS(for: listenText) else {
            // Over the server's 5000-char request cap: go straight to the on-device
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
                    text: listenText,
                    voice: ServerTTSPolicy.defaultVoice
                )
            } catch {
                audioData = nil
            }

            guard let self, !Task.isCancelled, self.activeListenRequestID == requestID else {
                // Stopped or superseded while the fetch was in flight — the user no
                // longer wants this audio; never start playback from a stale response.
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

    func suspendStreamForBackground() {
        suspendActiveStreamConnection()
    }

    func suspendStreamForNavigation() {
        suspendActiveStreamConnection()
    }

    func cancelStreamReconnectRetry() {
        guard !usesDirectGateway else { return }
        streamCoordinator.cancelReconnectRetry()
    }

    func ensureOwnedStreamStatusWatch() {
        guard !usesDirectGateway else { return }
        guard streamStatusWatchTask == nil, activeStreamID != nil else { return }
        streamStatusWatchTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard self.activeStreamID != nil else { return }
                await self.recoverStaleActiveStreamIfNeeded()
            }
        }
    }

    func cancelOwnedStreamStatusWatch() {
        streamStatusWatchTask?.cancel()
        streamStatusWatchTask = nil
    }

    func cleanupPollingTasks() {
        stopBackgroundPolling(clearTrackedPrompts: true)
        pendingActionCoordinator.stopMonitoring(clearPrompt: true)
    }

    private func suspendActiveStreamConnection() {
        guard !usesDirectGateway else { return }
        streamCoordinator.suspendActiveStreamConnection()
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
            await loadMessages(modelContext: modelContext)
            guard !Task.isCancelled else { return }
        }
        await reconnectStreamIfNeeded(modelContext: modelContext)
    }

    @discardableResult
    func reconnectStreamIfNeeded(modelContext: ModelContext? = nil) async -> Bool {
        if usesDirectGateway {
            do {
                let controller = try await ensureDirectConversation()
                try await controller.open()
                return activeStreamID != nil
            } catch { lastError = error; return false }
        }
        return await streamCoordinator.reconnectIfNeeded(modelContext: modelContext)
    }

    func refreshTranscriptIfActiveStreamCompleted(
        streamID expectedStreamID: String,
        modelContext: ModelContext? = nil
    ) async {
        guard !usesDirectGateway else { return }
        await streamCoordinator.refreshTranscriptIfCompleted(
            streamID: expectedStreamID,
            modelContext: modelContext
        )
    }

    func recoverStaleActiveStreamIfNeeded(
        now: Date = Date(),
        modelContext: ModelContext? = nil
    ) async {
        guard !usesDirectGateway else { return }
        await streamCoordinator.recoverStaleStreamIfNeeded(now: now, modelContext: modelContext)
    }

    private var hasRunningLiveToolCall: Bool {
        liveToolCalls.contains { !$0.isCompleted }
    }

    private func saveActiveStreamSnapshotIfNeeded() {
        guard !usesDirectGateway else { return }
        guard let sessionID,
              let activeStreamID,
              !hasCompletedCurrentResponse
        else { return }

        ActiveChatStreamSnapshotStore.shared.save(
            ActiveChatStreamSnapshot(
                messages: messages,
                messagesOffset: messagesOffset,
                displayTitle: displayTitle,
                completedToolCallGroups: completedToolCallGroups,
                completedReasoningGroups: completedReasoningGroups,
                liveToolCalls: liveToolCalls,
                liveReasoningText: liveReasoningText,
                activeStreamLastEventID: streamCoordinator.lastEventID,
                streamingAssistantMessageID: streamingAssistantMessageID,
                toolCallAnchorMessageID: toolCallAnchorMessageID,
                reasoningAnchorMessageID: reasoningAnchorMessageID,
                contextWindowSnapshot: contextWindowSnapshot,
                localAttachmentPreviews: attachmentCoordinator.localAttachmentPreviews,
                pinnedLocalNotices: pinnedLocalNotices
            ),
            server: server,
            sessionID: sessionID,
            streamID: activeStreamID
        )
        liveRunBookmarkStore.save(
            LiveRunBookmark(
                streamID: activeStreamID,
                lastEventID: streamCoordinator.lastEventID,
                liveReasoningText: liveReasoningText,
                streamingAssistantMessageID: streamingAssistantMessageID,
                liveToolCalls: liveToolCalls
            ),
            server: server,
            sessionID: sessionID
        )
    }

    @discardableResult
    private func restoreActiveStreamSnapshotIfAvailable(streamID: String) -> String? {
        guard let sessionID,
              let snapshot = ActiveChatStreamSnapshotStore.shared.snapshot(
                server: server,
                sessionID: sessionID,
                streamID: streamID
              )
        else { return nil }

        let merge = Self.mergingLoadedMessages(messages, withActiveStreamSnapshot: snapshot)
        withBatchedTranscriptDerivedState {
            messages = merge.messages
            if merge.usedSnapshotMessagesOffset {
                messagesOffset = snapshot.messagesOffset
            }
        }
        if merge.usedSnapshotMessagesOffset {
            hasOlderMessages = snapshot.messagesOffset > 0
        }
        displayTitle = displayTitle.isEmpty ? snapshot.displayTitle : displayTitle
        setCompletedToolCallGroups(snapshot.completedToolCallGroups)
        completedReasoningGroups = snapshot.completedReasoningGroups
        liveToolCalls = snapshot.liveToolCalls
        liveReasoningText = snapshot.liveReasoningText
        streamingAssistantMessageID = merge.streamingAssistantMessageID ?? snapshot.streamingAssistantMessageID
        toolCallAnchorMessageID = Self.remappedAnchorMessageID(
            snapshot.toolCallAnchorMessageID,
            from: snapshot.streamingAssistantMessageID,
            to: streamingAssistantMessageID
        )
        reasoningAnchorMessageID = Self.remappedAnchorMessageID(
            snapshot.reasoningAnchorMessageID,
            from: snapshot.streamingAssistantMessageID,
            to: streamingAssistantMessageID
        )
        contextWindowSnapshot = contextWindowSnapshot ?? snapshot.contextWindowSnapshot
        attachmentCoordinator.mergeLocalAttachmentPreviews(snapshot.localAttachmentPreviews)
        pinnedLocalNotices = snapshot.pinnedLocalNotices
        scheduleStreamingScrollTrigger()
        return snapshot.activeStreamLastEventID
    }

    private func removeActiveStreamSnapshot(streamID: String?) {
        guard let sessionID,
              let streamID
        else { return }

        ActiveChatStreamSnapshotStore.shared.remove(
            server: server,
            sessionID: sessionID,
            streamID: streamID
        )
        liveRunBookmarkStore.remove(server: server, sessionID: sessionID)
    }

    @discardableResult
    func respondToApproval(_ choice: ApprovalChoice) async -> Bool {
        await pendingActionCoordinator.respondToApproval(choice)
    }

    @discardableResult
    func skipApprovalsForCurrentSession() async -> Bool {
        await pendingActionCoordinator.skipApprovalsForCurrentSession()
    }

    func applyApprovalUpdate(_ update: ApprovalPendingResponse, sessionID: String) {
        pendingActionCoordinator.applyApprovalUpdate(update, sessionID: sessionID)
    }

    @discardableResult
    func respondToClarification(_ responseText: String) async -> Bool {
        await pendingActionCoordinator.respondToClarification(responseText)
    }

    func applyClarificationUpdate(_ update: ClarificationPendingResponse, sessionID: String) {
        pendingActionCoordinator.applyClarificationUpdate(update, sessionID: sessionID)
    }

    @discardableResult
    func completeWebsiteLogin(requestID: String) async -> Bool {
        await finishWebsiteLogin(requestID: requestID, result: .completed)
    }

    @discardableResult
    func cancelWebsiteLogin(requestID: String) async -> Bool {
        await finishWebsiteLogin(requestID: requestID, result: .cancelled)
    }

    @discardableResult
    func failWebsiteLogin(requestID: String) async -> Bool {
        await finishWebsiteLogin(requestID: requestID, result: .failed)
    }

    private func finishWebsiteLogin(requestID: String, result: WebsiteLoginResult) async -> Bool {
        guard let sessionID,
              let prompt = websiteLoginPrompt,
              prompt.requestID == requestID,
              !requestID.isEmpty
        else {
            websiteLoginErrorMessage = String(localized: "This website login request is no longer active.")
            return false
        }

        websiteLoginErrorMessage = nil
        do {
            let response = try await client.finishWebsiteLogin(
                requestID: requestID,
                sessionID: sessionID,
                result: result
            )
            guard response.requestID == requestID, response.result == result else {
                websiteLoginErrorMessage = String(localized: "The website login response was not accepted.")
                return false
            }
            resolvedWebsiteLoginRequestIDs.insert(requestID)
            websiteLoginPrompt = nil
            return true
        } catch {
            websiteLoginErrorMessage = String(localized: "Could not send the website login result. Try again.")
            return false
        }
    }

    private func startBtwStream(streamID: String, question: String) {
        activeBtwStreamID = streamID
        activeBtwQuestion = question
        activeBtwAnswer = ""
        activeBtwMessageID = appendLocalAssistantMessage(Self.btwMessageText(question: question, answer: nil, isLoading: true))

        btwStreamClient.start(url: client.chatStreamURL(streamID: streamID)) { [weak self] event in
            self?.handleBtwStreamEvent(event)
        }
    }

    private func handleBtwStreamEvent(_ event: SSEEvent) {
        switch event {
        case .token(let text):
            activeBtwAnswer += text
            updateActiveBtwMessage(isLoading: true)
        case .interimAssistant(let payload):
            guard payload.alreadyStreamed != true else { break }
            let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { break }
            if activeBtwAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                activeBtwAnswer = text
            } else {
                activeBtwAnswer += "\n\n\(text)"
            }
            updateActiveBtwMessage(isLoading: true)
        case .done:
            updateActiveBtwMessage(isLoading: false)
        case .approvalPending, .clarificationPending, .websiteLoginPending, .nativeComponent, .nativeComponentState:
            break
        case .streamEnd, .cancelled:
            finishBtwStream()
        case .error(let message):
            activeBtwAnswer = "Error: \(message)"
            updateActiveBtwMessage(isLoading: false)
            finishBtwStream()
        case .transportError(let message):
            activeBtwAnswer = "Error: \(message)"
            updateActiveBtwMessage(isLoading: false)
            finishBtwStream()
        case .heartbeat, .ignored, .reasoning, .toolStarted, .toolCompleted, .title, .sessionSnapshot, .metering, .pendingSteerLeftover, .lostWorkerBookkeeping:
            break
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

    private func finishBtwStream() {
        btwStreamClient.stop()
        activeBtwStreamID = nil
        activeBtwMessageID = nil
        activeBtwQuestion = nil
        activeBtwAnswer = ""
    }

    private func stopBackgroundPolling(clearTrackedPrompts: Bool) {
        backgroundPollTask?.cancel()
        backgroundPollTask = nil
        if clearTrackedPrompts {
            backgroundPromptsByTaskID.removeAll()
        }
    }

    private func startBackgroundPollingIfNeeded(parentSessionID: String) {
        guard backgroundPollTask == nil else { return }

        let pollingInterval = pollingIntervals.backgroundNanoseconds
        backgroundPollTask = Task { @MainActor [weak self] in
            pollingLoop: while !Task.isCancelled {
                do {
                    guard let self,
                          !self.backgroundPromptsByTaskID.isEmpty
                    else { break pollingLoop }

                    do {
                        let response = try await self.client.backgroundStatus(sessionID: parentSessionID)
                        self.handleBackgroundResults(response.results ?? [])
                    } catch {
                        self.lastError = error
                    }

                    guard !Task.isCancelled, !self.backgroundPromptsByTaskID.isEmpty else {
                        break pollingLoop
                    }
                }

                try? await Task.sleep(nanoseconds: pollingInterval)
            }

            if !Task.isCancelled {
                self?.backgroundPollTask = nil
            }
        }
    }

    private func handleBackgroundResults(_ results: [BackgroundResult]) {
        for result in results {
            let prompt: String
            if let taskID = result.taskId,
               let trackedPrompt = backgroundPromptsByTaskID.removeValue(forKey: taskID) {
                prompt = trackedPrompt
            } else if let resultPrompt = result.prompt, !resultPrompt.isEmpty {
                prompt = resultPrompt
            } else {
                prompt = "Background task"
            }

            appendLocalAssistantMessage(
                Self.backgroundResultText(
                    prompt: prompt,
                    answer: result.answer
                )
            )
        }
    }

    @discardableResult
    private func appendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool {
        guard payload.alreadyStreamed != true else { return false }

        let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return false }

        flushPendingStreamingContent()

        if let streamingAssistantMessageID,
           let index = streamingAssistantMessagePosition(for: streamingAssistantMessageID) {
            let existing = messages[index]
            let currentContent = existing.content ?? ""
            let textToAppend = deduplicatedReplayText(
                text,
                existingContent: currentContent,
                matchedPrefixLength: &activeStreamReplayMatchedInterimLength
            )
            guard !textToAppend.isEmpty else { return false }

            let shouldAppendReplaySuffixDirectly = isActiveStreamReplayConnection && textToAppend != text
            let shouldUseSeparator = currentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && !shouldAppendReplaySuffixDirectly
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

        // Same append-time dedup contract as appendAssistantToken: return true iff
        // the event contributed new content, mutate only via the coalesced flush.
        _ = ensureStreamingAssistantMessage()
        let effectiveContent = liveReasoningText + pendingReasoningTextBuffer
        let remainder = deduplicatedReplayText(
            text,
            existingContent: effectiveContent,
            matchedPrefixLength: &activeStreamReplayMatchedReasoningLength
        )
        guard !remainder.isEmpty else { return false }

        pendingReasoningTextBuffer.append(remainder)
        scheduleStreamingContentFlush()
        return true
    }

    @discardableResult
    private func flushReasoningChunks() -> Bool {
        guard !pendingReasoningTextBuffer.isEmpty else { return false }

        // Chunks were deduplicated at append time, so flushing is pure concatenation.
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

        if let duplicateReplayIndex = duplicateReplayToolStartIndex(for: payload) {
            activeStreamReplayPendingToolMatchIndex = duplicateReplayIndex
            return false
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

        if let duplicateReplayIndex = duplicateReplayToolCompletionIndex(for: payload) {
            let wasAlreadyCompleted = liveToolCalls[duplicateReplayIndex].isCompleted
            activeStreamReplayToolMatchIndex = duplicateReplayIndex + 1
            activeStreamReplayPendingToolMatchIndex = nil

            guard !wasAlreadyCompleted else { return false }

            liveToolCalls[duplicateReplayIndex] = liveToolCalls[duplicateReplayIndex].applyingCompletionPayload(payload)
            return true
        }

        activeStreamReplayPendingToolMatchIndex = nil

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

    private func duplicateReplayToolStartIndex(for payload: ToolStreamEvent) -> Int? {
        guard isActiveStreamReplayConnection else { return nil }

        if let stableIndex = stableReplayToolIndex(for: payload) {
            return stableIndex
        }

        guard activeStreamReplayToolMatchIndex < liveToolCalls.count else { return nil }

        let index = activeStreamReplayToolMatchIndex
        return liveToolCalls[index].matchesReplayToolStart(payload) ? index : nil
    }

    private func duplicateReplayToolCompletionIndex(for payload: ToolStreamEvent) -> Int? {
        guard isActiveStreamReplayConnection else { return nil }

        if let stableIndex = stableReplayToolIndex(for: payload) {
            return stableIndex
        }

        if let pendingIndex = activeStreamReplayPendingToolMatchIndex,
           pendingIndex < liveToolCalls.count,
           liveToolCalls[pendingIndex].matchesReplayToolCompletion(payload) {
            return pendingIndex
        }

        guard activeStreamReplayToolMatchIndex < liveToolCalls.count else { return nil }

        let index = activeStreamReplayToolMatchIndex
        guard liveToolCalls[index].isCompleted,
              liveToolCalls[index].matchesReplayToolCompletion(payload)
        else {
            return nil
        }

        return index
    }

    private func stableReplayToolIndex(for payload: ToolStreamEvent) -> Int? {
        guard let stableID = payload.stableID?.nonEmptyReplayMatchText else { return nil }

        return liveToolCalls.firstIndex { toolCall in
            toolCall.matchesStableToolID(stableID)
        }
    }

    private func liveToolCallCompletionIndex(for payload: ToolStreamEvent) -> Int? {
        if let stableID = payload.stableID?.nonEmptyReplayMatchText,
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

        // Dedup at append time against effective content (flushed + pending) so the
        // return value stays a synchronous progress signal for the reconnect watchdog
        // while transcript mutation stays batched behind the coalesced flush.
        let messageID = ensureStreamingAssistantMessage()
        let flushedContent = streamingAssistantMessagePosition(for: messageID)
            .flatMap { messages[$0].content } ?? ""
        let effectiveContent = flushedContent + pendingAssistantTextBuffer
        let remainder = deduplicatedReplayToken(token, existingContent: effectiveContent)
        guard !remainder.isEmpty else { return false }

        pendingAssistantTextBuffer.append(remainder)
        scheduleStreamingContentFlush()
        return true
    }

    @discardableResult
    private func flushAssistantTokens(maxWordUnits: Int? = nil) -> Bool {
        guard !pendingAssistantTextBuffer.isEmpty else { return false }

        // Chunks were deduplicated at append time, so flushing is pure concatenation.
        // A word-unit limit moves only the head of the buffer into the visible
        // message; the tail stays pending, keeping the replay-dedup invariant that
        // flushed + pending text is the full received content.
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

    private func deduplicatedReplayToken(_ token: String, existingContent: String) -> String {
        guard isActiveStreamReplayConnection, !existingContent.isEmpty else {
            resetActiveStreamReplayTokenState()
            return token
        }

        let matchedPrefixLength = min(activeStreamReplayMatchedPrefixLength, existingContent.count)
        let expectedReplayRemainder = String(existingContent.dropFirst(matchedPrefixLength))
        if expectedReplayRemainder.hasPrefix(token) {
            activeStreamReplayMatchedPrefixLength = matchedPrefixLength + token.count
            if activeStreamReplayMatchedPrefixLength >= existingContent.count {
                resetActiveStreamReplayTokenState()
            }
            return ""
        }

        if token.hasPrefix(expectedReplayRemainder) {
            resetActiveStreamReplayTokenState()
            return String(token.dropFirst(expectedReplayRemainder.count))
        }

        if existingContent.hasSuffix(token) || existingContent.hasPrefix(token) {
            resetActiveStreamReplayTokenState()
            return ""
        }

        if token.hasPrefix(existingContent) {
            resetActiveStreamReplayTokenState()
            return String(token.dropFirst(existingContent.count))
        }

        let maximumOverlap = min(existingContent.count, token.count)
        guard maximumOverlap > 0 else {
            resetActiveStreamReplayTokenState()
            return token
        }

        for overlapLength in stride(from: maximumOverlap, through: 1, by: -1) {
            let contentSuffix = existingContent.suffix(overlapLength)
            let tokenPrefix = token.prefix(overlapLength)
            if contentSuffix == tokenPrefix {
                resetActiveStreamReplayTokenState()
                return String(token.dropFirst(overlapLength))
            }
        }

        resetActiveStreamReplayTokenState()
        return token
    }

    private func deduplicatedReplayText(
        _ text: String,
        existingContent: String,
        matchedPrefixLength: inout Int
    ) -> String {
        guard isActiveStreamReplayConnection, !existingContent.isEmpty else {
            matchedPrefixLength = 0
            return text
        }

        let matchedLength = min(matchedPrefixLength, existingContent.count)
        let expectedReplayRemainder = String(existingContent.dropFirst(matchedLength))
        if expectedReplayRemainder.hasPrefix(text) {
            matchedPrefixLength = matchedLength + text.count
            if matchedPrefixLength >= existingContent.count {
                matchedPrefixLength = 0
            }
            return ""
        }

        if text.hasPrefix(expectedReplayRemainder) {
            matchedPrefixLength = 0
            return String(text.dropFirst(expectedReplayRemainder.count))
        }

        if existingContent.hasSuffix(text) || existingContent.hasPrefix(text) {
            matchedPrefixLength = 0
            return ""
        }

        if text.hasPrefix(existingContent) {
            matchedPrefixLength = 0
            return String(text.dropFirst(existingContent.count))
        }

        let maximumOverlap = min(existingContent.count, text.count)
        guard maximumOverlap > 0 else {
            matchedPrefixLength = 0
            return text
        }

        for overlapLength in stride(from: maximumOverlap, through: 1, by: -1) {
            let contentSuffix = existingContent.suffix(overlapLength)
            let textPrefix = text.prefix(overlapLength)
            if contentSuffix == textPrefix {
                matchedPrefixLength = 0
                return String(text.dropFirst(overlapLength))
            }
        }

        matchedPrefixLength = 0
        return text
    }

    private func resetActiveStreamReplayTokenState() {
        streamCoordinator.clearReplayConnection()
        activeStreamReplayMatchedPrefixLength = 0
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

    @discardableResult
    private func updateTitle(_ payload: TitleStreamEvent) -> Bool {
        if let payloadSessionID = payload.sessionId, payloadSessionID != sessionID {
            return false
        }

        guard let title = payload.title else { return false }
        applyLiveActivitySessionTitle(title)
        return true
    }

    private func refreshCompletedResponseTitleIfNeeded() {
        guard !isRefreshingCompletedResponseTitle else { return }
        guard let sessionID else { return }

        isRefreshingCompletedResponseTitle = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isRefreshingCompletedResponseTitle = false }

            do {
                let response = try await client.session(id: sessionID, includeMessages: false, messageLimit: nil)
                if let title = response.session?.title {
                    applyLiveActivitySessionTitle(title)
                }
            } catch {
                // Title refresh is opportunistic; the transcript has already completed successfully.
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
        // speech starts — not when the Listen tap lands — so a slow `/api/tts` fetch
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

    private static let reasoningDisplayArgs: Set<String> = ["show", "hide", "on", "off"]
    private static let reasoningEffortArgs: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh"]
    private static let reasoningClearArgs: Set<String> = [ReasoningEffortOption.inheritID, "clear", "default"]
    private static let personalityClearArgs: Set<String> = ["none", "default", "clear"]

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
    `/personality <name>` - Set or clear this session's personality.
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

extension ChatViewModel: ChatPendingActionCoordinatorDelegate {
    var pendingActionSessionID: String? { sessionID }
    var pendingActionHasActiveStream: Bool { activeStreamID != nil }
    var pendingActionIsStreamConnectionSuspended: Bool { isStreamConnectionSuspended }

    func pendingActionCoordinatorWillSubmitAction() {
        sendErrorMessage = nil
        lastError = nil
    }

    func pendingActionCoordinatorDidFailAction(_ error: Error) {
        lastError = error
        sendErrorMessage = CacheFallbackPolicy.sendBannerMessage(for: error)
    }
}

extension ChatViewModel: ChatAttachmentCoordinatorDelegate {
    var attachmentSessionID: String? { sessionID }
    var attachmentIsViewingCachedData: Bool { isViewingCachedData }

    func attachmentCoordinatorWillUpload() {
        lastError = nil
    }

    func attachmentCoordinatorDidFail(_ error: Error) {
        lastError = error
    }
}

extension ChatViewModel: ChatStreamCoordinatorDelegate {
    var streamCoordinatorSessionID: String? { sessionID }
    var streamCoordinatorDisplayTitle: String { displayTitle }
    var streamCoordinatorHasRunningLiveToolCall: Bool { hasRunningLiveToolCall }
    var streamCoordinatorHasPendingPrompt: Bool {
        pendingActionCoordinator.hasPendingPrompt
    }
    var streamCoordinatorHasNativeAuthLocalInputPrompt: Bool {
        nativeAuthPrompt?.inputComponents.isEmpty == false
    }
    var streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser: Bool {
        latestServerLoadHadAssistantResponseAfterLatestUser
    }
    var streamCoordinatorStreamingAssistantMessageID: String? {
        get { streamingAssistantMessageID }
        set {
            if newValue == nil {
                flushPendingStreamingContent()
            }
            streamingAssistantMessageID = newValue
        }
    }

    func streamCoordinatorLoadMessages(modelContext: ModelContext?) async {
        await loadMessages(modelContext: modelContext)
    }

    func streamCoordinatorLatestAssistantMessageID() -> String? {
        Self.latestAssistantMessageID(in: messages)
    }

    func streamCoordinatorStartAuxiliaryMonitoring() {
        pendingActionCoordinator.startMonitoring()
        OpenChatSessionStore.shared.noteStreamingStateChanged()
    }

    func streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: Bool) {
        pendingActionCoordinator.stopMonitoring(clearPrompt: clearPrompt)
        if activeStreamID == nil {
            cancelOwnedStreamStatusWatch()
        }
        OpenChatSessionStore.shared.noteStreamingStateChanged()
    }

    func streamCoordinatorSaveSnapshotIfNeeded() {
        flushPendingStreamingContent()
        saveActiveStreamSnapshotIfNeeded()
    }

    @discardableResult
    func streamCoordinatorRestoreSnapshotIfAvailable(streamID: String) -> String? {
        restoreActiveStreamSnapshotIfAvailable(streamID: streamID)
    }

    func streamCoordinatorRemoveSnapshot(streamID: String?) {
        removeActiveStreamSnapshot(streamID: streamID)
    }

    func streamCoordinatorFlushPinnedLocalNoticesToTranscript() {
        flushPinnedLocalNoticesToTranscript()
    }

    func streamCoordinatorDrainQueuedSlashMessageIfIdle() {
        drainQueuedSlashMessageIfIdle()
    }

    func streamCoordinatorRefreshCompletedResponseTitleIfNeeded() {
        refreshCompletedResponseTitleIfNeeded()
    }

    func streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: Bool) {
        responseCompletionNeedsTranscriptRefresh = needsTranscriptRefresh
        responseCompletionHapticTrigger += 1
    }

    func streamCoordinatorDidFinishStream() {
        flushPendingStreamingContent()
        responseCompletionNeedsTranscriptRefresh = false
        // Native auth is a user-owned continuation that can outlive the model
        // response. Its browser-issued component remains valid until the native
        // submit/cancel/expiry state arrives; clearing it here makes the secure
        // overlay disappear at the exact point the user needs to enter values.
    }

    func streamCoordinatorDidReceiveErrorMessage(_ message: String) {
        sendErrorMessage = message
    }

    func streamCoordinatorDidReceiveRecoveryError(_ error: Error) {
        lastError = error
        if CacheFallbackPolicy.isTransientBlip(error) {
            return
        }
        sendErrorMessage = CacheFallbackPolicy.sendBannerMessage(for: error)
    }

    func streamCoordinatorDidStartConnection(isReplay: Bool) {
        activeStreamReplayMatchedPrefixLength = 0
        activeStreamReplayMatchedInterimLength = 0
        activeStreamReplayMatchedReasoningLength = 0
        activeStreamReplayToolMatchIndex = 0
        activeStreamReplayPendingToolMatchIndex = nil
    }

    func streamCoordinatorDidResetRecoveryState() {
        activeStreamReplayMatchedPrefixLength = 0
        activeStreamReplayMatchedInterimLength = 0
        activeStreamReplayMatchedReasoningLength = 0
        activeStreamReplayToolMatchIndex = 0
        activeStreamReplayPendingToolMatchIndex = nil
    }

    @discardableResult
    func streamCoordinatorAppendToken(_ text: String) -> Bool {
        appendAssistantToken(text)
    }

    @discardableResult
    func streamCoordinatorAppendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool {
        appendInterimAssistant(payload)
    }

    @discardableResult
    func streamCoordinatorAppendReasoning(_ text: String) -> Bool {
        appendReasoning(text)
    }

    @discardableResult
    func streamCoordinatorAppendToolCall(_ payload: ToolStreamEvent) -> Bool {
        appendToolCall(payload)
    }

    @discardableResult
    func streamCoordinatorCompleteToolCall(_ payload: ToolStreamEvent) -> Bool {
        completeToolCall(payload)
    }

    @discardableResult
    func streamCoordinatorUpdateTitle(_ payload: TitleStreamEvent) -> Bool {
        updateTitle(payload)
    }

    @discardableResult
    func streamCoordinatorApplyDone(_ payload: DoneStreamEvent) -> Bool {
        flushPendingStreamingContent()
        let currentStreamingAssistantID = streamingAssistantMessageID
        let hasCompletedTranscript = payload.session?.messages?.isEmpty == false
        if let completedSession = payload.session {
            applyCompletedStreamSession(completedSession)
        }
        if let usage = payload.usage {
            contextWindowSnapshot = usage
        }
        if let finalTokensPerSecond = payload.usage?.tokensPerSecond,
           finalTokensPerSecond.isFinite,
           finalTokensPerSecond > 0,
           let currentStreamingAssistantID {
            let currentAssistantIndex = messages.firstIndex(where: { $0.messageId == currentStreamingAssistantID })
                ?? TranscriptTurnClassifier
                    .currentTurnAssistantAnchorIDs(in: messages, messageOffset: messagesOffset)
                    .last
                    .flatMap { currentAssistantAnchorID in
                        messages.indices.first { index in
                            TranscriptTurnClassifier.anchorID(
                                for: messages[index],
                                at: index,
                                messageOffset: messagesOffset
                            ) == currentAssistantAnchorID
                        }
                    }
            guard let index = currentAssistantIndex else {
                return hasCompletedTranscript
            }
            let message = messages[index]
            messages[index] = ChatMessage(
                role: message.role,
                content: message.content,
                timestamp: message.timestamp,
                messageId: message.messageId,
                name: message.name,
                toolCallId: message.toolCallId,
                toolUseId: message.toolUseId,
                toolCalls: message.toolCalls,
                contentParts: message.contentParts,
                reasoning: message.reasoning,
                attachments: message.attachments,
                turnTps: finalTokensPerSecond
            )
        }
        return hasCompletedTranscript
    }

    func streamCoordinatorApplyApprovalUpdate(_ update: ApprovalPendingResponse) {
        guard let sessionID else { return }
        applyApprovalUpdate(update, sessionID: sessionID)
    }

    func streamCoordinatorApplyClarificationUpdate(_ update: ClarificationPendingResponse) {
        guard let sessionID else { return }
        applyClarificationUpdate(update, sessionID: sessionID)
    }

    func streamCoordinatorApplyNativeAuthComponent(_ component: NativeAuthWireComponent) {
        guard let sessionID, let activeStreamID else { return }
        guard !quarantinedNativeAuthContextIDs.contains(component.contextID),
              !quarantinedNativeAuthStreamIDs.contains(activeStreamID)
        else { return }

        if var prompt = nativeAuthPrompt {
            guard prompt.contextID == component.contextID else {
                quarantineNativeAuth(
                    contextIDs: [prompt.contextID, component.contextID],
                    streamID: prompt.streamID,
                    message: String(localized: "The browser sent conflicting authentication requests. Start the browser action again.")
                )
                return
            }
            guard nativeAuthComponent(component, matches: prompt) else {
                quarantineNativeAuth(
                    contextIDs: [component.contextID],
                    streamID: prompt.streamID,
                    message: String(localized: "The browser changed this authentication request. Start the browser action again.")
                )
                return
            }
            if let existing = prompt.components.first(where: { $0.componentID == component.componentID }) {
                guard existing == component else {
                    quarantineNativeAuth(
                        contextIDs: [component.contextID],
                        streamID: prompt.streamID,
                        message: String(localized: "The browser changed this authentication request. Start the browser action again.")
                    )
                    return
                }
                applyBufferedNativeAuthStateIfPossible(contextID: component.contextID)
                return
            }
            guard !prompt.components.contains(where: {
                $0.field == component.field || $0.actionHandle == component.actionHandle
            }) else {
                quarantineNativeAuth(
                    contextIDs: [component.contextID],
                    streamID: prompt.streamID,
                    message: String(localized: "The browser sent conflicting authentication components. Start the browser action again.")
                )
                return
            }
            prompt.components.append(component)
            nativeAuthPrompt = prompt
            nativeAuthRequestGeneration &+= 1
            nativeAuthErrorMessage = nil
            applyBufferedNativeAuthStateIfPossible(contextID: component.contextID)
            scheduleNativeAuthE2EAutoSubmitIfEligible()
            return
        }

        nativeAuthPrompt = NativeAuthPromptState(
            contextID: component.contextID,
            ownerSessionID: sessionID,
            streamID: activeStreamID,
            components: [component],
            state: nil
        )
        nativeAuthRequestGeneration &+= 1
        nativeAuthErrorMessage = nil
        applyBufferedNativeAuthStateIfPossible(contextID: component.contextID)
        scheduleNativeAuthE2EAutoSubmitIfEligible()
    }

    func streamCoordinatorApplyNativeAuthState(_ state: NativeAuthWireState) {
        guard sessionID != nil, let activeStreamID else { return }
        if state.status.isTerminalNativeAuthStatus {
            bufferedNativeAuthStates[state.contextID] = nil
            quarantinedNativeAuthContextIDs.insert(state.contextID)
            if nativeAuthPrompt?.contextID == state.contextID {
                nativeAuthPrompt = nil
                pendingNativeAuthSubmission = nil
                nativeAuthRequestGeneration &+= 1
            }
            return
        }
        guard !quarantinedNativeAuthContextIDs.contains(state.contextID) else { return }
        guard var prompt = nativeAuthPrompt else {
            bufferNativeAuthState(state, streamID: activeStreamID)
            return
        }
        guard prompt.contextID == state.contextID else { return }
        guard nativeAuthState(state, matches: prompt) else {
            if !prompt.components.contains(where: { $0.componentID == state.componentID }) {
                bufferNativeAuthState(state, streamID: activeStreamID)
            } else {
                quarantineNativeAuth(
                    contextIDs: [state.contextID],
                    streamID: prompt.streamID,
                    message: String(localized: "The browser sent conflicting authentication state. Start the browser action again.")
                )
            }
            return
        }
        bufferedNativeAuthStates[state.contextID] = nil

        let order = state.status.nativeAuthOrder
        guard order >= (nativeAuthStateOrderByContextID[state.contextID] ?? -1) else { return }
        if order == nativeAuthStateOrderByContextID[state.contextID], prompt.state != state {
            quarantineNativeAuth(
                contextIDs: [state.contextID],
                streamID: prompt.streamID,
                message: String(localized: "The browser sent conflicting authentication state. Start the browser action again.")
            )
            return
        }
        guard prompt.state != state else { return }
        nativeAuthStateOrderByContextID[state.contextID] = order
        prompt.state = state
        nativeAuthPrompt = prompt
        nativeAuthRequestGeneration &+= 1
        nativeAuthErrorMessage = nil
        scheduleNativeAuthE2EAutoSubmitIfEligible()
    }

    private func scheduleNativeAuthE2EAutoSubmitIfEligible() {
        #if DEBUG
        guard let controller = nativeAuthE2EAutoSubmitController else { return }
        Task { @MainActor [weak self] in
            guard let self, let prompt = self.nativeAuthPrompt else { return }
            let contextID = prompt.contextID
            let attempted = await controller.submitIfEligible(prompt: prompt) { [weak self] values, component, actionHandle in
                guard let self else { return false }
                return await self.submitNativeAuth(
                    values: values,
                    component: component,
                    actionHandle: actionHandle
                )
            }
            guard attempted, self.nativeAuthPrompt?.contextID == contextID else { return }
            // Auto-submit is intentionally never retryable. Success already
            // terminalized through the production path; an ambiguous/failing
            // result is also closed here so no envelope or retry state remains.
            self.terminalizeNativeAuth(contextID: contextID)
        }
        #endif
    }

    #if DEBUG
    func setNativeAuthE2EAutoSubmitControllerForTesting(_ controller: NativeAuthE2EAutoSubmitController?) {
        nativeAuthE2EAutoSubmitController = controller
    }
    #endif

    @discardableResult
    func submitNativeAuth(
        values: [String: String],
        component: NativeAuthWireComponent,
        actionHandle: String
    ) async -> Bool {
        guard let sessionID, let prompt = nativeAuthPrompt,
              prompt.ownerSessionID == sessionID,
              prompt.components.contains(component),
              component.kind == .submit,
              component.actionHandle == actionHandle,
              !component.isExpired,
              !isNativeAuthRequestInFlight
        else {
            nativeAuthErrorMessage = String(localized: "This authentication request is no longer active.")
            return false
        }

        let pending: PendingNativeAuthSubmission
        if let existing = pendingNativeAuthSubmission {
            guard existing.ownerSessionID == sessionID,
                  existing.streamID == prompt.streamID,
                  existing.contextID == prompt.contextID,
                  existing.component == component,
                  existing.actionHandle == actionHandle
            else {
                quarantineNativeAuth(
                    contextIDs: [prompt.contextID],
                    streamID: prompt.streamID,
                    message: String(localized: "The authentication retry no longer matches the browser request.")
                )
                return false
            }
            pending = existing
        } else {
            let allowedFields = Set(prompt.inputComponents.map(\.field))
            guard !values.isEmpty,
                  Set(values.keys).isSubset(of: allowedFields),
                  values.values.allSatisfy({ !$0.isEmpty })
            else {
                nativeAuthErrorMessage = String(localized: "Enter the requested information before continuing.")
                return false
            }
            do {
                pending = PendingNativeAuthSubmission(
                    ownerSessionID: sessionID,
                    streamID: prompt.streamID,
                    contextID: prompt.contextID,
                    component: component,
                    actionHandle: actionHandle,
                    envelope: try NativeAuthWireEnvelope.encrypt(
                        component: component,
                        values: values,
                        actionHandle: actionHandle
                    )
                )
                pendingNativeAuthSubmission = pending
            } catch {
                nativeAuthErrorMessage = String(localized: "Could not prepare the secure authentication request.")
                return false
            }
        }

        let requestGeneration = nativeAuthRequestGeneration
        isNativeAuthRequestInFlight = true
        defer { isNativeAuthRequestInFlight = false }
        do {
            _ = try await client.submitNativeAuth(
                sessionID: pending.ownerSessionID,
                streamID: pending.streamID,
                envelope: pending.envelope
            )
            guard nativeAuthRequestGeneration == requestGeneration,
                  pendingNativeAuthSubmission == pending,
                  nativeAuthPrompt?.contextID == pending.contextID
            else { return false }
            terminalizeNativeAuth(contextID: pending.contextID)
            return true
        } catch let error as NativeAuthControlError {
            guard nativeAuthRequestGeneration == requestGeneration,
                  pendingNativeAuthSubmission == pending
            else { return false }
            if error.outcome.retryable {
                nativeAuthErrorMessage = String(localized: "The browser is busy. Retry the same secure request.")
            } else {
                quarantineNativeAuth(
                    contextIDs: [pending.contextID],
                    streamID: pending.streamID,
                    message: String(localized: "The browser rejected this authentication request. Start the browser action again.")
                )
            }
            return false
        } catch {
            guard nativeAuthRequestGeneration == requestGeneration,
                  pendingNativeAuthSubmission == pending
            else { return false }
            nativeAuthErrorMessage = String(localized: "The result is unknown. Retry sends the same secure request.")
            return false
        }
    }

    @discardableResult
    func cancelNativeAuth() async -> Bool {
        guard let sessionID, let prompt = nativeAuthPrompt,
              prompt.ownerSessionID == sessionID,
              !isNativeAuthRequestInFlight
        else { return false }
        let requestGeneration = nativeAuthRequestGeneration
        isNativeAuthRequestInFlight = true
        defer { isNativeAuthRequestInFlight = false }
        do {
            _ = try await client.cancelNativeAuth(
                sessionID: prompt.ownerSessionID,
                streamID: prompt.streamID,
                contextID: prompt.contextID
            )
            guard nativeAuthRequestGeneration == requestGeneration,
                  nativeAuthPrompt?.contextID == prompt.contextID
            else { return false }
            terminalizeNativeAuth(contextID: prompt.contextID)
            return true
        } catch let error as NativeAuthControlError {
            guard nativeAuthRequestGeneration == requestGeneration else { return false }
            if error.outcome.retryable {
                nativeAuthErrorMessage = String(localized: "The browser is busy. Try cancelling again.")
            } else {
                quarantineNativeAuth(
                    contextIDs: [prompt.contextID],
                    streamID: prompt.streamID,
                    message: String(localized: "The browser no longer accepts this authentication request.")
                )
            }
            return false
        } catch {
            guard nativeAuthRequestGeneration == requestGeneration else { return false }
            nativeAuthErrorMessage = String(localized: "Could not confirm cancellation. Try again.")
            return false
        }
    }

    private func nativeAuthComponent(
        _ component: NativeAuthWireComponent,
        matches prompt: NativeAuthPromptState
    ) -> Bool {
        guard prompt.ownerSessionID == sessionID,
              prompt.streamID == activeStreamID,
              let anchor = prompt.components.first
        else { return false }
        let bindingMatches: Bool
        switch (component.binding, anchor.binding) {
        case (nil, nil):
            bindingMatches = true
        case let (.some(componentBinding), .some(anchorBinding)):
            bindingMatches = componentBinding.tabHandle == anchorBinding.tabHandle
                && componentBinding.frameHandle == anchorBinding.frameHandle
                && componentBinding.documentGeneration == anchorBinding.documentGeneration
        default:
            bindingMatches = false
        }
        return component.contextID == anchor.contextID
            && component.browserSessionID == anchor.browserSessionID
            && component.providerOrigin == anchor.providerOrigin
            && component.path == anchor.path
            && component.runtimePublicKey == anchor.runtimePublicKey
            && component.keyID == anchor.keyID
            && component.expiresAt == anchor.expiresAt
            && bindingMatches
    }

    private func nativeAuthState(_ state: NativeAuthWireState, matches prompt: NativeAuthPromptState) -> Bool {
        guard let anchor = prompt.components.first,
              state.browserSessionID == anchor.browserSessionID,
              state.providerOrigin == anchor.providerOrigin,
              state.path == anchor.path
        else { return false }
        guard let component = prompt.components.first(where: { $0.componentID == state.componentID }) else {
            return false
        }
        return component.actionHandle == state.actionHandle && component.kind == state.kind
    }

    private func bufferNativeAuthState(_ state: NativeAuthWireState, streamID: String) {
        bufferedNativeAuthStates = bufferedNativeAuthStates.filter { $0.value.streamID == streamID }
        if let existing = bufferedNativeAuthStates[state.contextID] {
            guard existing.streamID == streamID, existing.state == state else {
                quarantineNativeAuth(
                    contextIDs: [state.contextID],
                    streamID: streamID,
                    message: String(localized: "The browser sent conflicting authentication state. Start the browser action again.")
                )
                return
            }
            return
        }
        guard bufferedNativeAuthStates.count < 8 else {
            quarantineNativeAuth(
                contextIDs: [state.contextID],
                streamID: streamID,
                message: String(localized: "The browser sent too many authentication requests. Start the browser action again.")
            )
            return
        }
        bufferedNativeAuthStates[state.contextID] = (streamID, state)
    }

    private func applyBufferedNativeAuthStateIfPossible(contextID: String) {
        guard let buffered = bufferedNativeAuthStates[contextID],
              let prompt = nativeAuthPrompt,
              prompt.contextID == contextID,
              prompt.streamID == buffered.streamID,
              nativeAuthState(buffered.state, matches: prompt)
        else { return }
        bufferedNativeAuthStates[contextID] = nil
        streamCoordinatorApplyNativeAuthState(buffered.state)
    }

    private func terminalizeNativeAuth(contextID: String) {
        quarantinedNativeAuthContextIDs.insert(contextID)
        nativeAuthStateOrderByContextID[contextID] = nil
        bufferedNativeAuthStates[contextID] = nil
        pendingNativeAuthSubmission = nil
        if nativeAuthPrompt?.contextID == contextID { nativeAuthPrompt = nil }
        nativeAuthRequestGeneration &+= 1
        nativeAuthErrorMessage = nil
    }

    private func quarantineNativeAuth(contextIDs: Set<String>, streamID: String, message: String) {
        quarantinedNativeAuthContextIDs.formUnion(contextIDs)
        quarantinedNativeAuthStreamIDs.insert(streamID)
        for contextID in contextIDs {
            bufferedNativeAuthStates[contextID] = nil
        }
        pendingNativeAuthSubmission = nil
        nativeAuthPrompt = nil
        nativeAuthRequestGeneration &+= 1
        nativeAuthErrorMessage = message
    }

    func streamCoordinatorApplyWebsiteLogin(_ request: WebsiteLoginRequest) {
        guard sessionID != nil,
              !resolvedWebsiteLoginRequestIDs.contains(request.requestID)
        else { return }
        websiteLoginErrorMessage = nil
        websiteLoginPrompt = request
    }

    @discardableResult
    func streamCoordinatorEnqueuePendingSteerLeftover(_ text: String) -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return false }

        _ = enqueueQueuedSlashMessage(message, attachments: [])
        appendLocalNoticeMessage(String(localized: "Steering hint was not consumed before the response ended, so it was queued for the next turn."))
        return true
    }
}

private struct ActiveChatStreamSnapshot: Equatable {
    let messages: [ChatMessage]
    let messagesOffset: Int
    let displayTitle: String
    let completedToolCallGroups: [ToolCallGroup]
    let completedReasoningGroups: [ReasoningGroup]
    let liveToolCalls: [ToolCall]
    let liveReasoningText: String
    let activeStreamLastEventID: String?
    let streamingAssistantMessageID: String?
    let toolCallAnchorMessageID: String?
    let reasoningAnchorMessageID: String?
    let contextWindowSnapshot: ContextWindowSnapshot?
    let localAttachmentPreviews: [String: [String: Data]]
    let pinnedLocalNotices: [String]
}

private struct ActiveChatStreamSnapshotKey: Hashable {
    let server: String
    let sessionID: String
    let streamID: String
}

private final class ActiveChatStreamSnapshotStore {
    static let shared = ActiveChatStreamSnapshotStore()

    private let lock = NSLock()
    private var snapshots: [ActiveChatStreamSnapshotKey: ActiveChatStreamSnapshot] = [:]

    private init() {}

    func save(
        _ snapshot: ActiveChatStreamSnapshot,
        server: URL,
        sessionID: String,
        streamID: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        snapshots[key(server: server, sessionID: sessionID, streamID: streamID)] = snapshot
    }

    func snapshot(server: URL, sessionID: String, streamID: String) -> ActiveChatStreamSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[key(server: server, sessionID: sessionID, streamID: streamID)]
    }

    func remove(server: URL, sessionID: String, streamID: String) {
        lock.lock()
        defer { lock.unlock() }
        snapshots.removeValue(forKey: key(server: server, sessionID: sessionID, streamID: streamID))
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        snapshots.removeAll()
    }

    private func key(server: URL, sessionID: String, streamID: String) -> ActiveChatStreamSnapshotKey {
        ActiveChatStreamSnapshotKey(
            server: server.absoluteString,
            sessionID: sessionID,
            streamID: streamID
        )
    }
}

private struct QueuedSlashMessage {
    let text: String
    let attachments: [PendingAttachment]
}

struct ReasoningGroup: Identifiable, Equatable {
    let id: String
    let anchorMessageID: String?
    let text: String

    init(id: String = UUID().uuidString, anchorMessageID: String?, text: String) {
        self.id = id
        self.anchorMessageID = anchorMessageID
        self.text = text
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

struct TranscriptMessage: Identifiable, Equatable {
    let loadedIndex: Int
    let renderID: String
    let anchorID: String
    let message: ChatMessage

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
        hidingStreamingAssistantID streamingAssistantID: String?
    ) -> [TranscriptMessage] {
        let offset = max(0, messageOffset ?? 0)
        var transcriptMessages: [TranscriptMessage] = []
        transcriptMessages.reserveCapacity(messages.count)

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
            let renderID = "transcript:\(absoluteIndex)"

            transcriptMessages.append(TranscriptMessage(
                loadedIndex: loadedIndex,
                renderID: renderID,
                anchorID: anchorID,
                message: message
            ))
        }

        return transcriptMessages
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
            text: segments.joined(separator: "\n\n")
        )
    }
}

private extension ToolCall {
    func matchesStableToolID(_ stableID: String) -> Bool {
        id.nonEmptyStableToolID == stableID
    }

    func matchesReplayToolStart(_ payload: ToolStreamEvent) -> Bool {
        matchesReplayToolIdentity(payload)
    }

    func matchesReplayToolCompletion(_ payload: ToolStreamEvent) -> Bool {
        matchesReplayToolIdentity(payload)
    }

    private func matchesReplayToolIdentity(_ payload: ToolStreamEvent) -> Bool {
        if let payloadStableID = payload.stableID?.nonEmptyReplayMatchText,
           let stableID = id.nonEmptyStableToolID {
            return stableID == payloadStableID
        }

        var didCompareStableField = false

        if let payloadName = payload.name?.nonEmptyReplayMatchText {
            didCompareStableField = true
            guard name?.nonEmptyReplayMatchText == payloadName else { return false }
        }

        if let payloadArgs = payload.args {
            didCompareStableField = true
            guard args == payloadArgs else { return false }
        }

        if didCompareStableField {
            return true
        }

        guard let payloadPreview = payload.preview?.nonEmptyReplayMatchText,
              let preview = preview?.nonEmptyReplayMatchText
        else {
            return false
        }

        return preview == payloadPreview
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
    var nonEmptyReplayMatchText: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nonEmptyStableToolID: String? {
        guard let stableID = nonEmptyReplayMatchText,
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
/// (`POST /api/tts`, edge engine — no API key needed) and fall back to the
/// on-device synthesizer when the server can't serve the request.
enum ServerTTSPolicy {
    /// Server-enforced request cap (`400 text too long` above it); longer text
    /// routes straight to the on-device synthesizer (chunking is a non-goal).
    static let maximumTextLength = 5000
    /// The server's own default voice is `zh-CN-XiaoxiaoNeural`, so the client
    /// must always send an explicit voice. A voice picker is a non-goal of #15;
    /// this is the issue-specified default (verified live 2026-07-02).
    static let defaultVoice = "en-US-AriaNeural"

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

    private func seedPerformanceLab(messageCount: Int) {
        precondition(messageCount > 20)

        messages = (0..<messageCount).map { index in
            let role = index.isMultiple(of: 2) ? "user" : "assistant"
            let content: String
            if index == messageCount - 1 {
                content = """
                ## Deterministic long Markdown tail

                This final response exercises the production streaming/Markdown surface after the 10,000-row history.

                ```swift
                \(String(repeating: "let value = Array(0..<1_000).reduce(0, +)\n", count: 320))
                ```
                """
            } else if role == "assistant", index.isMultiple(of: 250) {
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
