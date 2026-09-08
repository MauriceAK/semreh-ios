import Foundation
import Observation
import OSLog
import SwiftData

private let chatStreamCoordinatorLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "ChatStreamCoordinator"
)

struct ChatStreamCoordinatorTiming: Equatable {
    let checkingInterval: TimeInterval
    let reconnectInterval: TimeInterval
    let runningToolReconnectInterval: TimeInterval
    let statusPollCooldown: TimeInterval
    // Transport quieter than this is treated as provably alive; must sit above
    // the server's ~5s SSE heartbeat cadence and below reconnectInterval (#227).
    let transportFreshInterval: TimeInterval

    static let standard = ChatStreamCoordinatorTiming(
        checkingInterval: 5,
        reconnectInterval: 18,
        runningToolReconnectInterval: 25,
        statusPollCooldown: 4,
        transportFreshInterval: 12
    )
}

struct ChatStreamLoadPreparation: Equatable {
    let activeStreamIDBeforeLoad: String?
    let shouldPrepareSuspendedStreamResume: Bool
}

@MainActor
protocol ChatStreamCoordinatorDelegate: AnyObject {
    var streamCoordinatorSessionID: String? { get }
    var streamCoordinatorDisplayTitle: String { get }
    var streamCoordinatorHasRunningLiveToolCall: Bool { get }
    var streamCoordinatorHasPendingPrompt: Bool { get }
    var streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser: Bool { get }
    var streamCoordinatorStreamingAssistantMessageID: String? { get set }

    func streamCoordinatorLoadMessages(modelContext: ModelContext?) async
    func streamCoordinatorLatestAssistantMessageID() -> String?
    func streamCoordinatorStartAuxiliaryMonitoring()
    func streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: Bool)
    func streamCoordinatorSaveSnapshotIfNeeded()
    @discardableResult
    func streamCoordinatorRestoreSnapshotIfAvailable(streamID: String) -> String?
    func streamCoordinatorRemoveSnapshot(streamID: String?)
    func streamCoordinatorFlushPinnedLocalNoticesToTranscript()
    func streamCoordinatorDrainQueuedSlashMessageIfIdle()
    func streamCoordinatorRefreshCompletedResponseTitleIfNeeded()
    func streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: Bool)
    func streamCoordinatorDidFinishStream()
    func streamCoordinatorDidReceiveErrorMessage(_ message: String)
    func streamCoordinatorDidReceiveRecoveryError(_ error: Error)
    func streamCoordinatorDidStartConnection(isReplay: Bool)
    func streamCoordinatorDidResetRecoveryState()

    @discardableResult
    func streamCoordinatorAppendToken(_ text: String) -> Bool
    @discardableResult
    func streamCoordinatorAppendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorAppendReasoning(_ text: String) -> Bool
    @discardableResult
    func streamCoordinatorAppendToolCall(_ payload: ToolStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorCompleteToolCall(_ payload: ToolStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorUpdateTitle(_ payload: TitleStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorApplyDone(_ payload: DoneStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorEnqueuePendingSteerLeftover(_ text: String) -> Bool
}

@MainActor
@Observable
final class ChatStreamCoordinator {
    private static let reconnectRetryLimit = 3
    @ObservationIgnored private weak var delegate: (any ChatStreamCoordinatorDelegate)?
    private let client: APIClient
    private let streamClient: SSEStreamingClient
    private let liveActivityManager: any AgentLiveActivityManaging
    private let timing: ChatStreamCoordinatorTiming
    private var showsLiveActivityResponseExcerpts: Bool

    private(set) var activeStreamID: String?
    private(set) var recoveryState: ActiveStreamRecoveryState = .idle
    private(set) var isConnectionSuspended = false
    private(set) var hasCompletedCurrentResponse = false
    private(set) var lastEventID: String?
    private(set) var lastProgressDate: Date?
    private(set) var lastTransportActivityDate: Date?
    private(set) var liveTokensPerSecond: Double?
    private var lastRecoveryStatusCheckDate: Date?
    private(set) var isReplayConnection = false
    @ObservationIgnored private var reconnectRetryTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectInFlightTask: Task<Void, Never>?
    private var reconnectLifecycleGeneration = 0
    // Bumped whenever the active run starts or finalizes. Captured before an async
    // transcript load so a concurrent cancel/completion during the load can't be
    // double-finalized (PR #266 review #2).
    private var runGeneration = 0
    /// Same-stream journal replay already emitted lost-worker bookkeeping.
    /// A second copy must not reopen SSE (that just re-emits the red banner).
    private var lostWorkerBookkeepingStreamID: String?

    init(
        client: APIClient,
        streamClient: SSEStreamingClient,
        liveActivityManager: any AgentLiveActivityManaging,
        showsLiveActivityResponseExcerpts: Bool,
        timing: ChatStreamCoordinatorTiming = .standard
    ) {
        self.client = client
        self.streamClient = streamClient
        self.liveActivityManager = liveActivityManager
        self.showsLiveActivityResponseExcerpts = showsLiveActivityResponseExcerpts
        self.timing = timing
    }

    func adoptKnownLiveStreamIfNeeded(_ rawStreamID: String?) {
        let streamID = rawStreamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeStreamID == nil, let streamID, !streamID.isEmpty else { return }
        activeStreamID = streamID
        isConnectionSuspended = true
        recoveryState = .checking
    }

    func restoreLastEventID(_ rawEventID: String?) {
        let eventID = rawEventID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let eventID, !eventID.isEmpty else { return }
        lastEventID = eventID
    }

    func attach(delegate: any ChatStreamCoordinatorDelegate) {
        self.delegate = delegate
    }

    func setShowsLiveActivityResponseExcerpts(_ shows: Bool) {
        guard showsLiveActivityResponseExcerpts != shows else { return }

        showsLiveActivityResponseExcerpts = shows
        if !shows, activeStreamID != nil {
            liveActivityManager.update(.clearResponseExcerpt)
        }
    }

    func prepareForNewResponse() {
        hasCompletedCurrentResponse = false
        isConnectionSuspended = false
        liveTokensPerSecond = nil
    }

    func start(
        streamID: String,
        replayAfterSeq: Int? = nil,
        recoveryState: ActiveStreamRecoveryState = .idle
    ) {
        reconnectRetryTask?.cancel()
        reconnectRetryTask = nil
        hasCompletedCurrentResponse = false
        liveTokensPerSecond = nil
        runGeneration &+= 1
        if activeStreamID != streamID {
            lostWorkerBookkeepingStreamID = nil
        }
        activeStreamID = streamID
        isConnectionSuspended = false
        if replayAfterSeq == nil {
            lastEventID = nil
        }

        markConnectionStarted(
            isReplay: replayAfterSeq != nil,
            recoveryState: recoveryState
        )
        startLiveActivity(streamID: streamID)
        streamClient.start(
            url: client.chatStreamURL(
                streamID: streamID,
                replayAfterSeq: replayAfterSeq
            )
        ) { [weak self] event in
            self?.handle(event)
        }
        delegate?.streamCoordinatorStartAuxiliaryMonitoring()
    }

    func cancelActiveStream() async throws -> ChatCancelResponse? {
        guard let activeStreamID else { return nil }

        let response = try await client.cancelChat(streamID: activeStreamID)
        guard self.activeStreamID == activeStreamID else { return response }
        guard response.ok != false else { return response }

        liveActivityManager.end(status: .cancelled, activity: String(localized: "Response cancelled"), errorSummary: nil)
        finishStream()
        return response
    }

    func suspendActiveStreamConnection() {
        // A foreground status failure may have queued a coordinator-owned retry
        // after the view's outer task completed. Always cancel it on lifecycle
        // suspension, even when the SSE connection is already suspended.
        cancelReconnectRetry()
        guard activeStreamID != nil, !hasCompletedCurrentResponse, !isConnectionSuspended else { return }

        lastEventID = streamClient.lastEventID ?? lastEventID
        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        isConnectionSuspended = true
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
    }

    func cancelReconnectRetry() {
        reconnectRetryTask?.cancel()
        reconnectRetryTask = nil
        reconnectInFlightTask?.cancel()
        reconnectInFlightTask = nil
        reconnectLifecycleGeneration &+= 1
    }

    func prepareForSessionLoad() -> ChatStreamLoadPreparation {
        liveTokensPerSecond = nil
        let activeStreamIDBeforeLoad = activeStreamID
        if activeStreamIDBeforeLoad != nil, !hasCompletedCurrentResponse {
            delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        }

        return ChatStreamLoadPreparation(
            activeStreamIDBeforeLoad: activeStreamIDBeforeLoad,
            shouldPrepareSuspendedStreamResume: activeStreamID == nil || isConnectionSuspended
        )
    }

    func reconcileSessionLoad(
        loadedActiveStreamID rawLoadedActiveStreamID: String?,
        preparation: ChatStreamLoadPreparation,
        usedCacheFallback: Bool
    ) {
        hasCompletedCurrentResponse = false
        liveTokensPerSecond = nil

        if usedCacheFallback {
            activeStreamID = nil
            isConnectionSuspended = false
            delegate?.streamCoordinatorStreamingAssistantMessageID = nil
            resetRecoveryState()
            return
        }

        let loadedActiveStreamID = rawLoadedActiveStreamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if preparation.shouldPrepareSuspendedStreamResume {
            delegate?.streamCoordinatorStreamingAssistantMessageID = nil
            if let streamID = loadedActiveStreamID, !streamID.isEmpty {
                activeStreamID = streamID
                delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                isConnectionSuspended = true
                restoreSnapshotIfAvailable(streamID: streamID)
            } else {
                activeStreamID = nil
                isConnectionSuspended = false
                resetRecoveryState()
            }
        } else {
            let streamID = loadedActiveStreamID?.isEmpty == false
                ? loadedActiveStreamID
                : preparation.activeStreamIDBeforeLoad
            if let streamID {
                activeStreamID = streamID
                delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                restoreSnapshotIfAvailable(streamID: streamID)
                if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                    delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                }
            }
            isConnectionSuspended = false
        }
    }

    @discardableResult
    func reconnectIfNeeded(modelContext: ModelContext? = nil) async -> Bool {
        await reconnectIfNeeded(modelContext: modelContext, retryAttempt: 0)
    }

    /// Returns true when this reconnect path had to reload the transcript itself.
    /// Callers that already own an initial/foreground load can use that result to
    /// avoid issuing a second lock-bound `/api/session` request.
    private func reconnectIfNeeded(
        modelContext: ModelContext?,
        retryAttempt: Int
    ) async -> Bool {
        guard let activeStreamID, isConnectionSuspended else { return false }
        reconnectRetryTask?.cancel()
        reconnectRetryTask = nil
        let generation = runGeneration
        let lifecycleGeneration = reconnectLifecycleGeneration

        do {
            let response = try await client.chatStreamStatus(streamID: activeStreamID)
            guard !Task.isCancelled,
                  self.reconnectLifecycleGeneration == lifecycleGeneration,
                  self.activeStreamID == activeStreamID,
                  isConnectionSuspended
            else { return false }

            if response.active == true {
                let streamIDToResume = activeStreamID
                if response.replayAvailable == true {
                    // The local transcript/snapshot is already on screen. Reattach to
                    // the run journal immediately and replay only events produced while
                    // the app was suspended; a full `/api/session` reload here used to
                    // serialize status → transcript → SSE and visibly stall foregrounding.
                    let replayAfterSeq = Self.runJournalReplayAfterSeq(from: lastEventID) ?? 0
                    if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                        restoreSnapshotIfAvailable(streamID: streamIDToResume)
                    }
                    if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                        delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                    }
                    isConnectionSuspended = false
                    start(
                        streamID: streamIDToResume,
                        replayAfterSeq: replayAfterSeq,
                        recoveryState: .reconnecting
                    )
                    return false
                } else {
                    // Compatibility path for servers that explicitly report no run
                    // journal: attach a live-only SSE first. The transcript request
                    // can be blocked by the agent's session lock; it must not delay
                    // the first visible in-progress response state.
                    if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                        restoreSnapshotIfAvailable(streamID: streamIDToResume)
                    }
                    if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                        delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                    }
                    isConnectionSuspended = false
                    start(streamID: streamIDToResume, recoveryState: .reconnecting)
                    await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                    guard !Task.isCancelled,
                          self.reconnectLifecycleGeneration == lifecycleGeneration,
                          self.activeStreamID == activeStreamID
                    else { return true }
                    return true
                }
            } else if response.replayAvailable == true {
                let replayAfterSeq = Self.runJournalReplayAfterSeq(from: lastEventID) ?? 0
                self.activeStreamID = activeStreamID
                isConnectionSuspended = false
                start(streamID: activeStreamID, replayAfterSeq: replayAfterSeq)
                return false
            } else {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                // Bail if a concurrent completion/cancel/new run finalized or
                // replaced this run during the load (see canFinalizeRunAfterLoad).
                guard canFinalizeRunAfterLoad(streamID: activeStreamID, capturedGeneration: generation) else { return true }

                // #246: the server reports the run is over. Finalize it (and end
                // the Live Activity) instead of re-arming and leaving it dangling
                // "running" when no assistant reply surfaced.
                finalizeInactiveStream(streamID: activeStreamID)
                return true
            }
        } catch {
            guard !Task.isCancelled,
                  self.reconnectLifecycleGeneration == lifecycleGeneration,
                  self.activeStreamID == activeStreamID,
                  isConnectionSuspended
            else { return false }
            if (error as? APIError)?.indicatesMissingStream == true {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                guard canFinalizeRunAfterLoad(streamID: activeStreamID, capturedGeneration: generation) else { return true }
                finalizeInactiveStream(streamID: activeStreamID)
                return true
            }
            guard !Self.isCancellationError(error) else { return false }
            guard Self.shouldRetryReconnect(after: error) else {
                delegate?.streamCoordinatorDidReceiveRecoveryError(error)
                return false
            }
            if retryAttempt >= Self.reconnectRetryLimit {
                if !CacheFallbackPolicy.isTransientBlip(error) {
                    delegate?.streamCoordinatorDidReceiveRecoveryError(error)
                }
                return false
            }
            scheduleReconnectRetry(
                streamID: activeStreamID,
                capturedGeneration: generation,
                capturedLifecycleGeneration: lifecycleGeneration,
                modelContext: modelContext,
                retryAttempt: retryAttempt + 1
            )
            return false
        }
    }

    private func scheduleReconnectRetry(
        streamID: String,
        capturedGeneration: Int,
        capturedLifecycleGeneration: Int,
        modelContext: ModelContext?,
        retryAttempt: Int
    ) {
        guard reconnectRetryTask == nil else { return }
        let baseDelay = max(timing.statusPollCooldown, 0.01)
        let boundedAttempt = min(retryAttempt, 4)
        let backoff = pow(2, Double(max(0, boundedAttempt - 1)))
        let delayNanoseconds = UInt64(baseDelay * backoff * 1_000_000_000)

        reconnectRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let self else { return }
            guard !Task.isCancelled,
                  self.reconnectLifecycleGeneration == capturedLifecycleGeneration,
                  self.activeStreamID == streamID,
                  self.runGeneration == capturedGeneration,
                  self.isConnectionSuspended
            else {
                self.reconnectRetryTask = nil
                return
            }

            self.reconnectRetryTask = nil
            _ = await self.reconnectIfNeeded(
                modelContext: modelContext,
                retryAttempt: retryAttempt
            )
        }
    }

    private nonisolated static func shouldRetryReconnect(after error: Error) -> Bool {
        if isCancellationError(error) {
            return false
        }

        if let apiError = error as? APIError {
            switch apiError {
            case .network:
                return true
            case .http(let statusCode, _):
                return [408, 429, 500, 502, 503, 504].contains(statusCode)
            case .invalidServerURL, .decoding, .unauthorized:
                return false
            }
        }

        return error is URLError
    }

    private nonisolated static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        return (underlying as? URLError)?.code == .cancelled
    }

    func refreshTranscriptIfCompleted(
        streamID expectedStreamID: String,
        modelContext: ModelContext? = nil
    ) async {
        guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }
        let generation = runGeneration

        do {
            let response = try await client.chatStreamStatus(streamID: expectedStreamID)
            guard response.active == false else { return }

            await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
            // Bail if a concurrent completion/cancel/new run finalized or replaced
            // this run during the load (see canFinalizeRunAfterLoad).
            guard canFinalizeRunAfterLoad(streamID: expectedStreamID, capturedGeneration: generation) else { return }

            guard delegate?.streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser == true else {
                // Foreground safety net: the live SSE is still connected and owns
                // completion, so a status poll that briefly reports inactive must
                // not finalize the run — keep waiting for the real `.done`. (This
                // is why #246's finalize-on-reopen fix deliberately excludes this
                // path; see finalizeInactiveStream.)
                activeStreamID = expectedStreamID
                isConnectionSuspended = false
                return
            }

            completeResponseFromRefreshedTranscriptAndFinishStream(streamID: expectedStreamID)
        } catch {
            // This is a foreground safety net. The primary SSE path owns visible
            // stream errors; a failed status poll should not interrupt it.
            chatStreamCoordinatorLogger.warning(
                "Active stream status refresh failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )
        }
    }

    func recoverStaleStreamIfNeeded(
        now: Date = Date(),
        modelContext: ModelContext? = nil
    ) async {
        guard let activeStreamID,
              !isConnectionSuspended,
              !hasCompletedCurrentResponse
        else {
            recoveryState = .idle
            return
        }

        guard delegate?.streamCoordinatorHasPendingPrompt != true else {
            recoveryState = .idle
            return
        }

        let reconnectInterval = delegate?.streamCoordinatorHasRunningLiveToolCall == true
            ? timing.runningToolReconnectInterval
            : timing.reconnectInterval
        guard let lastProgressDate else {
            guard let lastTransportActivityDate,
                  now.timeIntervalSince(lastTransportActivityDate) >= reconnectInterval
            else {
                recoveryState = .idle
                return
            }

            recoveryState = .checking
            lastRecoveryStatusCheckDate = now
            await recoverStaleStream(
                streamID: activeStreamID,
                forceReconnect: true,
                modelContext: modelContext
            )
            return
        }

        let elapsed = now.timeIntervalSince(lastProgressDate)
        guard elapsed >= timing.checkingInterval else {
            recoveryState = .idle
            return
        }

        let transportElapsed = now.timeIntervalSince(lastTransportActivityDate ?? lastProgressDate)
        guard transportElapsed >= timing.transportFreshInterval else {
            // #227: heartbeats prove the connection is alive during a
            // semantically quiet window (model thinking / slow tool call), so
            // stay idle and skip status polls. A genuinely silent transport
            // still escalates below once past transportFreshInterval.
            recoveryState = .idle
            return
        }

        recoveryState = .checking
        let shouldForceReconnect = transportElapsed >= reconnectInterval
        guard shouldForceReconnect || shouldPollStatus(now: now) else { return }

        lastRecoveryStatusCheckDate = now
        await recoverStaleStream(
            streamID: activeStreamID,
            forceReconnect: shouldForceReconnect,
            modelContext: modelContext
        )
    }

    func markProgress(now: Date = Date()) {
        lastProgressDate = now
        lastTransportActivityDate = now
        lastRecoveryStatusCheckDate = nil
        recoveryState = .idle
    }

    func clearReplayConnection() {
        isReplayConnection = false
    }

    nonisolated static func runJournalReplayAfterSeq(from eventID: String?) -> Int? {
        guard let eventID = eventID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !eventID.isEmpty
        else {
            return nil
        }

        let sequenceText: Substring
        if let delimiterIndex = eventID.lastIndex(of: ":") {
            sequenceText = eventID[eventID.index(after: delimiterIndex)...]
        } else {
            sequenceText = Substring(eventID)
        }

        guard let sequence = Int(sequenceText) else {
            return nil
        }

        return max(0, sequence)
    }

    private func handle(_ event: SSEEvent) {
        lastEventID = streamClient.lastEventID ?? lastEventID
        lastTransportActivityDate = Date()

        switch event {
        case .token(let text):
            if showsLiveActivityResponseExcerpts {
                liveActivityManager.update(.token(text))
            }
            if delegate?.streamCoordinatorAppendToken(text) == true {
                markProgress()
            }
        case .interimAssistant(let payload):
            if showsLiveActivityResponseExcerpts,
               payload.alreadyStreamed != true,
               let text = payload.text {
                liveActivityManager.update(.interimAssistant(text))
            }
            if delegate?.streamCoordinatorAppendInterimAssistant(payload) == true {
                markProgress()
            }
        case .reasoning(let text):
            liveActivityManager.update(.reasoning(text))
            if delegate?.streamCoordinatorAppendReasoning(text) == true {
                markProgress()
            }
        case .toolStarted(let payload):
            liveActivityManager.update(.toolStarted(name: payload.name))
            if delegate?.streamCoordinatorAppendToolCall(payload) == true {
                markProgress()
            }
        case .toolCompleted(let payload):
            liveActivityManager.update(.toolCompleted)
            if delegate?.streamCoordinatorCompleteToolCall(payload) == true {
                markProgress()
            }
        case .title(let payload):
            if delegate?.streamCoordinatorUpdateTitle(payload) == true {
                markProgress()
            }
        case .sessionSnapshot:
            // Session-wide snapshots are owned by SessionEventStreamCoordinator.
            // A chat stream must not mutate metadata or transcript state from them.
            break
        case .metering(let payload):
            guard payload.sessionId == nil || payload.sessionId == delegate?.streamCoordinatorSessionID else {
                break
            }
            liveTokensPerSecond = payload.displayableTokensPerSecond
        case .done(let payload):
            let hasCompletedTranscript = delegate?.streamCoordinatorApplyDone(payload) == true
            completeCurrentResponse(needsTranscriptRefresh: !hasCompletedTranscript)
        case .approvalPending(let update):
            liveActivityManager.update(.waitingForApproval)
            _ = update
            markProgress()
        case .clarificationPending(let update):
            liveActivityManager.update(.waitingForClarification)
            _ = update
            markProgress()
        case .pendingSteerLeftover(let text):
            if delegate?.streamCoordinatorEnqueuePendingSteerLeftover(text) == true {
                markProgress()
            }
        case .streamEnd:
            if !hasCompletedCurrentResponse {
                liveActivityManager.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
            }
            finishStream()
        case .cancelled:
            liveActivityManager.end(status: .cancelled, activity: String(localized: "Response cancelled"), errorSummary: nil)
            finishStream()
        case .error(let message):
            if !hasCompletedCurrentResponse {
                delegate?.streamCoordinatorDidReceiveErrorMessage(message)
            }
            liveActivityManager.end(status: .failed, activity: String(localized: "Response failed"), errorSummary: nil)
            finishStream()
        case .lostWorkerBookkeeping:
            // Journal replay already painted. The live SSE socket is gone.
            // Do not put WebUI bookkeeping in the composer as a red error.
            if lostWorkerBookkeepingStreamID == activeStreamID {
                if !hasCompletedCurrentResponse {
                    liveActivityManager.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
                }
                finishStream()
            } else {
                lostWorkerBookkeepingStreamID = activeStreamID
                handleTransportError("lost-worker-bookkeeping")
            }
        case .transportError(let message):
            handleTransportError(message)
        case .heartbeat:
            // #227: a heartbeat proves the transport is alive without carrying
            // semantic progress — drop an already-shown "Checking stream" state
            // immediately. Never demote .reconnecting; that chip is owned by
            // the reconnect flow until real progress lands.
            if recoveryState == .checking {
                recoveryState = .idle
            }
        case .ignored:
            break
        }
    }

    private func handleTransportError(_ message: String) {
        liveTokensPerSecond = nil
        guard activeStreamID != nil, !hasCompletedCurrentResponse else {
            if !hasCompletedCurrentResponse {
                delegate?.streamCoordinatorDidReceiveErrorMessage(message)
            }
            finishStream()
            return
        }

        guard !isConnectionSuspended else { return }

        lastEventID = streamClient.lastEventID ?? lastEventID
        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        isConnectionSuspended = true
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)

        startOwnedReconnect()
    }

    private func startOwnedReconnect(modelContext: ModelContext? = nil) {
        reconnectInFlightTask?.cancel()
        let lifecycleGeneration = reconnectLifecycleGeneration
        reconnectInFlightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconnectIfNeeded(modelContext: modelContext)
            guard self.reconnectLifecycleGeneration == lifecycleGeneration else { return }
            self.reconnectInFlightTask = nil
        }
    }

    private func shouldPollStatus(now: Date) -> Bool {
        guard let lastRecoveryStatusCheckDate else { return true }

        return now.timeIntervalSince(lastRecoveryStatusCheckDate) >= timing.statusPollCooldown
    }

    private func recoverStaleStream(
        streamID expectedStreamID: String,
        forceReconnect: Bool,
        modelContext: ModelContext?
    ) async {
        guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }
        let generation = runGeneration

        do {
            let response = try await client.chatStreamStatus(streamID: expectedStreamID)
            guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }

            if response.active == false {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                // Same generation/clobber guard as the reconnect and refresh paths;
                // the extra `!isConnectionSuspended` keeps the reconnect path owning
                // a stream that was suspended mid-load. (PR #266 review #3)
                guard canFinalizeRunAfterLoad(streamID: expectedStreamID, capturedGeneration: generation),
                      !isConnectionSuspended else { return }

                finalizeInactiveStream(streamID: expectedStreamID)
                return
            }

            // PR #238 review: recoveryState was set to .checking before this
            // await. If it changed mid-flight (a heartbeat or real progress
            // demoted it to .idle), the transport just proved itself alive —
            // don't resurrect the chip or churn a live connection; the next
            // recovery tick re-evaluates from scratch.
            guard recoveryState == .checking, forceReconnect else { return }

            reconnectStaleStream(
                streamID: expectedStreamID,
                usesReplay: response.replayAvailable == true
            )
        } catch {
            chatStreamCoordinatorLogger.warning(
                "Stale stream recovery status check failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )

            if (error as? APIError)?.indicatesMissingStream == true,
               activeStreamID == expectedStreamID,
               !isConnectionSuspended {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                guard canFinalizeRunAfterLoad(streamID: expectedStreamID, capturedGeneration: generation),
                      !isConnectionSuspended else { return }
                finalizeInactiveStream(streamID: expectedStreamID)
                return
            }

            // Same mid-flight demotion guard as the success path (PR #238
            // review): only a still-.checking state may escalate.
            guard recoveryState == .checking,
                  forceReconnect,
                  activeStreamID == expectedStreamID,
                  !isConnectionSuspended
            else { return }

            reconnectStaleStream(streamID: expectedStreamID, usesReplay: true)
        }
    }

    private func reconnectStaleStream(streamID: String, usesReplay: Bool) {
        guard activeStreamID == streamID, !isConnectionSuspended else { return }

        lastEventID = streamClient.lastEventID ?? lastEventID
        let replayAfterSeq = usesReplay ? Self.runJournalReplayAfterSeq(from: lastEventID) ?? 0 : nil
        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        recoveryState = .reconnecting
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
        start(
            streamID: streamID,
            replayAfterSeq: replayAfterSeq,
            recoveryState: .reconnecting
        )
    }

    private func completeCurrentResponse(needsTranscriptRefresh: Bool) {
        runGeneration &+= 1
        liveActivityManager.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
        delegate?.streamCoordinatorRemoveSnapshot(streamID: activeStreamID)
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
        activeStreamID = nil
        lastEventID = nil
        liveTokensPerSecond = nil
        delegate?.streamCoordinatorStreamingAssistantMessageID = nil
        hasCompletedCurrentResponse = true
        delegate?.streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: needsTranscriptRefresh)
        resetRecoveryState()
    }

    private func completeResponseFromRefreshedTranscriptAndFinishStream(streamID completedStreamID: String?) {
        completeCurrentResponse(needsTranscriptRefresh: false)
        delegate?.streamCoordinatorRemoveSnapshot(streamID: completedStreamID)
        finishStream()
    }

    /// Whether `self` may still finalize the run captured before an awaited
    /// transcript load. Returns false (bail) when a concurrent completion / cancel
    /// / new run bumped the generation — finalizing would double-finalize — or when
    /// a *different* run is now active — finalizing would clobber the newer stream.
    /// A run reconciled to `nil` during the load still passes: it should be
    /// finalized from the refreshed transcript so its Live Activity can't dangle on
    /// "running" (#246). Shared by all three post-load finalize paths
    /// (reconnect-after-suspend, foreground refresh, stale recovery) so they stay in
    /// lockstep — recoverStaleStream previously used a stricter, hand-rolled guard.
    /// (PR #266 review #3)
    private func canFinalizeRunAfterLoad(streamID: String, capturedGeneration: Int) -> Bool {
        guard runGeneration == capturedGeneration else { return false }
        return activeStreamID == nil || activeStreamID == streamID
    }

    /// The server reports this stream is no longer active. Complete from the
    /// just-refreshed transcript when an assistant reply surfaced, otherwise
    /// finalize as failed. Either branch ends the Live Activity, so it can never
    /// dangle on "running" after the run is over (#246). Shared by the two paths
    /// with no live SSE behind them — reconnect-after-suspend and stale recovery.
    /// The foreground transcript-refresh safety net deliberately keeps waiting
    /// instead, because its live SSE still owns completion.
    private func finalizeInactiveStream(streamID: String?) {
        if delegate?.streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser == true {
            completeResponseFromRefreshedTranscriptAndFinishStream(streamID: streamID)
        } else {
            liveActivityManager.end(status: .failed, activity: String(localized: "Response failed"), errorSummary: nil)
            finishStream()
        }
    }

    private func finishStream() {
        runGeneration &+= 1
        let completedNormally = hasCompletedCurrentResponse
        let finishedStreamID = activeStreamID
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
        delegate?.streamCoordinatorFlushPinnedLocalNoticesToTranscript()
        delegate?.streamCoordinatorRemoveSnapshot(streamID: finishedStreamID)
        activeStreamID = nil
        lastEventID = nil
        liveTokensPerSecond = nil
        delegate?.streamCoordinatorStreamingAssistantMessageID = nil
        hasCompletedCurrentResponse = false
        delegate?.streamCoordinatorDidFinishStream()
        isConnectionSuspended = false
        resetRecoveryState()
        delegate?.streamCoordinatorDrainQueuedSlashMessageIfIdle()
        if completedNormally {
            delegate?.streamCoordinatorRefreshCompletedResponseTitleIfNeeded()
        }
    }

    private func markConnectionStarted(
        isReplay: Bool,
        recoveryState: ActiveStreamRecoveryState
    ) {
        let startedAt = Date()
        lastProgressDate = isReplay ? startedAt : nil
        lastTransportActivityDate = startedAt
        lastRecoveryStatusCheckDate = nil
        self.recoveryState = recoveryState
        isReplayConnection = isReplay
        delegate?.streamCoordinatorDidStartConnection(isReplay: isReplay)
    }

    private func resetRecoveryState() {
        reconnectRetryTask?.cancel()
        reconnectRetryTask = nil
        recoveryState = .idle
        lastProgressDate = nil
        lastTransportActivityDate = nil
        lastRecoveryStatusCheckDate = nil
        isReplayConnection = false
        delegate?.streamCoordinatorDidResetRecoveryState()
    }

    private func startLiveActivity(streamID: String) {
        guard let sessionID = delegate?.streamCoordinatorSessionID else { return }

        liveActivityManager.start(
            sessionID: sessionID,
            sessionTitle: delegate?.streamCoordinatorDisplayTitle ?? String(localized: "Untitled Session"),
            streamID: streamID
        )
    }

    private func restoreSnapshotIfAvailable(streamID: String) {
        guard lastEventID == nil else {
            _ = delegate?.streamCoordinatorRestoreSnapshotIfAvailable(streamID: streamID)
            return
        }

        lastEventID = delegate?.streamCoordinatorRestoreSnapshotIfAvailable(streamID: streamID) ?? lastEventID
    }
}
