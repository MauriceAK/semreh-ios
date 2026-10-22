import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor @Observable
final class AppStore {
    var grant: DeviceGrant?
    var sessions: [ChatSession] = []
    var selectedSession: ChatSession? { didSet { selectionChanged(from: oldValue) } }
    var transcript = TranscriptWindow()
    var controls: AgentControls?
    var requests: [AgentRequest] = []
    var jobs: [FollowUpJob] = []
    var updates: [AgentUpdate] = []
    var preferences = DeliveryPreferences.initial
    var runState: RunState = .synchronizing
    var connection = ""
    var connectionError: String?
    private(set) var requiresPairing = false
    var error: String?
    var notice: String?
    var draft = "" { didSet { if oldValue != draft { draftRevision = UUID() }; persistDraft() } }
    private var draftRevision = UUID()
    private struct DraftOrigin: Hashable { let host: UUID; let sessionID: String? }
    private var savedDraftRevisions: [DraftOrigin: UUID] = [:]
    private var snapshotRevision: UInt64 = 0
    var isPairing = false
    enum PendingAction { case creating, uploading, command(String) }
    private struct ActionOwner: Equatable {
        let host: UUID
        let operationID: String
    }
    private struct OwnedAction {
        let owner: ActionOwner
        let action: PendingAction
    }
    private var pendingOperation: OwnedAction?
    var pendingAction: PendingAction? { pendingOperation?.action }
    var isSending: Bool { pendingOperation != nil }
    private var sendIntent = UUID()
    private var pendingInterrupt: ActionOwner?
    var isStopping: Bool { pendingInterrupt != nil }
    var isWorking: Bool { runState == .working || runState == .waiting }
    private struct OutboundSubmission {
        enum Delivery { case awaitingReceipt, accepted(String?), uncertain }
        let operationID: String
        let context: ConversationContext
        let text: String
        let attachments: [AttachmentTicket]
        let precedingIDs: Set<String>
        let submittedDraft: String?
        let submittedDraftRevision: UUID?
        let submittedAttachmentIDs: Set<UUID>
        var draftAcknowledged = false
        var previewRetired = false
        var acceptanceRevision: UInt64?
        var delivery = Delivery.awaitingReceipt
        var awaitingHTTPReceipt = true
        var userRowID: String? {
            if case .accepted(let id) = delivery { return id }
            return nil
        }
    }
    private var outboundSubmissions: [OutboundSubmission] = []
    private var pendingSendPresentations: [SendPresentationIntent] = []
    private struct CanonicalSendOperation {
        let context: ConversationContext
        let operationID: String
    }
    private var canonicalSendOperations: [String: CanonicalSendOperation] = [:]
    var sendPresentations: [SendPresentationIntent] {
        pendingSendPresentations.filter { $0.context == commandContext }
    }
    func sendPresentationFinished(_ intent: SendPresentationIntent, outcome: SendPresentationOutcome) {
        guard intent.context == commandContext else { return }
        pendingSendPresentations.removeAll { $0 == intent }
    }
    private var currentSubmissions: [OutboundSubmission] {
        outboundSubmissions.filter { $0.context == commandContext }
    }
    var displayMessages: [ChatMessage] {
        let projection = ChatPerformance.shared.beginStage(.projection, count: transcript.messages.count)
        defer { ChatPerformance.shared.endStage(projection) }
        ChatPerformance.shared.add(.projectionCanonicalRows, count: transcript.messages.count)
        ChatPerformance.shared.add(.projectionOutboundRows, count: currentSubmissions.count)
        guard !isReadingHistory, !transcript.hasNewer else {
            ChatPerformance.shared.add(.projectionResultRows, count: transcript.messages.count)
            return transcript.messages
        }
        var messages = transcript.messages
        for index in messages.indices {
            if let operation = canonicalSendOperations[messages[index].id], operation.context == commandContext {
                messages[index].operationId = operation.operationID
            }
        }
        for submission in currentSubmissions {
            if submission.previewRetired { continue }
            let canonicalIndex = messages.firstIndex {
                $0.operationId?.caseInsensitiveCompare(submission.operationID) == .orderedSame ||
                    (submission.userRowID != nil && $0.id == submission.userRowID)
            }
            if let canonicalIndex {
                messages[canonicalIndex].operationId = submission.operationID
                continue
            }
            if case .awaitingReceipt = submission.delivery {
                messages.removeAll { !submission.precedingIDs.contains($0.id) && $0.operationId == nil }
            }
            let state: OutgoingDelivery
            switch submission.delivery {
            case .awaitingReceipt: state = .sending
            case .accepted: state = .accepted
            case .uncertain: state = .uncertain
            }
            let index = messages.firstIndex { !submission.precedingIDs.contains($0.id) } ?? messages.endIndex
            messages.insert(.init(id: submission.userRowID ?? "outbound:" + submission.operationID.lowercased(),
                role: "user", text: submission.text, provisional: false,
                attachments: submission.attachments.isEmpty ? nil : submission.attachments,
                operationId: submission.operationID, delivery: state), at: index)
        }
        ChatPerformance.shared.add(.projectionResultRows, count: messages.count)
        ChatPerformance.shared.projected(messages)
        return messages
    }
    var transcriptActivity: TranscriptActivity {
        if isStopping { return .stopping }
        if runState == .waiting { return .waiting }
        return isWorking ? .working : .idle
    }
    var isLoadingHistory = false
    var isReadingHistory = false
    var newActivity = false
    var latestRevision = UUID()
    private var latestFetchIntent: UUID?
    var isFetchingLatest: Bool { latestFetchIntent != nil }
    private(set) var uncertain: [PendingOperation] = []
    private(set) var unassignedUncertain: [PendingOperation] = []
    var confirmation: PendingModelConfirmation?
    var routedUpdateID: String?
    var notificationStatus = "Not enabled"
    var hostStatus: HostStatus?
    private(set) var fixture = false
    var attachmentDrafts = AttachmentDrafts(hostID: "unpaired")
    var attachments: [DraftAttachment] { attachmentDrafts.items(for: selectedSession?.id) }
    var hasDraftContent: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    var canSendDraft: Bool { hasDraftContent && attachments.allSatisfy { $0.payload != nil && !$0.uncertainUpload && $0.uploadError == nil } }
    private var conversationMemory: ConversationMemory?
    private var restoringConversation = false
    private var api: CompanionAPI?
    private struct SynchronizationEpisode {
        let id: UUID
        let host: UUID
        let api: CompanionAPI
        let socket: URLSessionWebSocketTask?
    }
    private struct FreshAuthority {
        let host: UUID
        let episode: UUID
        let context: ConversationContext?
    }
    private var episode: SynchronizationEpisode?
    private var connectionGeneration = UUID()
    private var sceneIsActive = true
    private var freshAuthority: FreshAuthority?
    private var authorityRevision: UInt64 = 0
    private var displayCache: ConversationDisplayCache
    private var cachedConversations: [String: CachedConversation] = [:]
    private var cacheLoadTask: Task<Void, Never>?
    private var cacheWrites: [UUID: Task<Void, Never>] = [:]
    private var lastCacheWrite: Task<Void, Never>?
    private var canonicalRevision: UInt64 = 0
    private var readerIntent = UUID()
    private var readerPosition = ReaderPosition.latest
    private(set) var readerRestoration: ReaderRestoration?
    private var recentTail: DisplayWindow?
    private var lastCanonicalFetch = Date.distantPast
    private var connectionTask: Task<Void, Never>?
    private var deltaTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private struct QueuedDelta {
        let delta: Delta
        let position: StreamPosition?
    }
    private struct StreamProgress {
        let epoch: String
        var snapshotSequence: Int
        var receivedSequence: Int
        var appliedSequence: Int
    }
    private var selectedStream: StreamProgress?
    private var awaitingStreamEpoch: String?
    private var retiredStreamEpochs = Set<String>()
    private var bufferedStreamEvents: [WireEvent] = []
    private var bufferedStreamBytes = 0
    private enum StreamRecovery {
        case idle, running(UUID, Task<Void, Never>), exhausted
        var id: UUID? {
            if case .running(let id, _) = self { return id }
            return nil
        }
    }
    private var streamRecovery = StreamRecovery.idle
    private var pendingDeltas: [QueuedDelta] = []
    private var pendingDeltaBytes = 0
    private var journal = OperationJournal()
    private var historyIntent = UUID()
    private var selectionGeneration = UUID()
    private var hostGeneration = UUID()
    private var knownUpdateIDs = Set<String>()
    private var hasLoadedUpdates = false
    private var notificationToken: String?
    private var fixtureOldest = 9880
    private var fixtureTimer: Task<Void, Never>?
    #if DEBUG
    var fixtureHoldWork = false
    #endif

    var voiceContext: VoiceDraftContext {
        .init(sessionID: selectedSession?.id, hostGeneration: hostGeneration, selectionGeneration: selectionGeneration)
    }
    var readerContext: ConversationContext? { commandContext }
    var canCommand: Bool {
        guard sceneIsActive, !requiresPairing else { return false }
        if fixture { return connection == "Connected" }
        guard let freshAuthority else { return false }
        return freshAuthority.host == hostGeneration && freshAuthority.episode == connectionGeneration && freshAuthority.context == commandContext
    }
    private var canCreateSession: Bool {
        guard sceneIsActive, !requiresPairing else { return false }
        if fixture { return canCommand }
        guard let freshAuthority else { return false }
        return freshAuthority.host == hostGeneration && freshAuthority.episode == connectionGeneration
    }
    private var hostScope: HostScope? { grant.map(HostScope.init) }
    var currentUncertain: [PendingOperation] {
        uncertain.filter { $0.sessionID == selectedSession?.id && $0.scope == hostScope }
    }
    private func publishUncertainty() {
        uncertain = journal.pending.filter { $0.scope == hostScope }
        unassignedUncertain = journal.pending.filter { $0.scope == nil }
    }
    private func finishAction(_ owner: ActionOwner) {
        if pendingOperation?.owner == owner { pendingOperation = nil }
    }
    private func revokeCommandAuthority() {
        authorityRevision &+= 1
        freshAuthority = nil
        confirmation = nil
    }
    @discardableResult
    private func handleAuthorizationFailure(_ error: Error) -> Bool {
        guard case ClientError.server(let status, _, _) = error, status == 401 || status == 403 else { return false }
        requiresPairing = true
        revokeCommandAuthority()
        requests = []
        controls = nil
        connectionError = "This device can no longer access Hermes. Connect the host again."
        return true
    }
    var statusLabel: String {
        if connectionError != nil { return "Host unavailable" }
        switch runState {
        case .idle: return "Ready"
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .synchronizing: return ""
        case .offline: return "Host offline"
        case .failed: return "Needs attention"
        }
    }
    init(api testAPI: CompanionAPI? = nil, journal testJournal: OperationJournal? = nil, memory testMemory: ConversationMemory? = nil, displayCache: ConversationDisplayCache = ConversationDisplayCache()) {
        self.displayCache = displayCache
        if let testJournal { journal = testJournal }
        conversationMemory = testMemory
        if let testAPI { api = testAPI; publishUncertainty(); restoreConversation(); return }
        #if DEBUG
        fixture = ProcessInfo.processInfo.arguments.contains("--fixture")
        #endif
        if fixture {
            loadFixture()
            #if DEBUG
            FixtureControl.shared.connect(self)
            #endif
            return
        }
        grant = GrantVault.load()
        publishUncertainty()
        if let grant, let client = try? CompanionAPI(baseURL: validatedBaseURL(grant.baseURL), token: grant.token) {
            usePairedHost(grant, api: client)
        }
    }
    isolated deinit {
        for task in refreshTasks.values { task.cancel() }
        connectionTask?.cancel()
        episode?.socket?.cancel(with: .goingAway, reason: nil)
        cacheLoadTask?.cancel()
        deltaTask?.cancel()
        fixtureTimer?.cancel()
    }
    func usePairedHost(_ grant: DeviceGrant, api: CompanionAPI, memory: ConversationMemory? = nil) {
        rememberCurrentConversation()
        stopConnection()
        for task in refreshTasks.values { task.cancel() }
        refreshTask = nil
        cacheLoadTask?.cancel()
        self.grant = grant
        self.api = api
        attachmentDrafts = AttachmentDrafts(hostID: grant.baseURL + "|" + grant.deviceID)
        cancelLatestFetch()
        historyIntent = UUID()
        hostGeneration = UUID()
        selectionGeneration = UUID()
        canonicalRevision &+= 1
        readerIntent = UUID()
        outboundSubmissions.removeAll()
        pendingDeltas.removeAll()
        pendingDeltaBytes = 0
        deltaTask?.cancel()
        deltaTask = nil
        sessions = []
        restoringConversation = true
        selectedSession = nil
        restoringConversation = false
        transcript = TranscriptWindow()
        recentTail = nil
        cachedConversations.removeAll()
        requests = []
        controls = nil
        updates = []
        jobs = []
        hostStatus = nil
        knownUpdateIDs.removeAll()
        hasLoadedUpdates = false
        preferences = .initial
        runState = .synchronizing
        connection = ""
        connectionError = nil
        requiresPairing = false
        error = nil
        notice = nil
        routedUpdateID = nil
        publishUncertainty()
        pendingOperation = nil
        pendingInterrupt = nil
        sendIntent = UUID()
        isReadingHistory = false
        isLoadingHistory = false
        newActivity = false
        readerPosition = .latest
        readerRestoration = nil
        lastCanonicalFetch = .distantPast
        conversationMemory = memory ?? ConversationMemory(hostID: grant.baseURL + "|" + grant.deviceID)
        confirmation = nil
        restoreConversation()
        loadCachedHost()
    }
    private var commandContext: ConversationContext? {
        selectedSession.map { ConversationContext(sessionID: $0.id, hostGeneration: hostGeneration, selectionGeneration: selectionGeneration) }
    }
    @discardableResult
    func confirmModelChange(_ pending: PendingModelConfirmation) async -> Bool {
        guard pending.context == commandContext else {
            notice = "This model confirmation expired when the conversation or host changed. Choose the model again."
            return false
        }
        return await execute(.init(kind: "model", value: pending.details.value, provider: pending.details.provider, confirmed: true))
    }
    private func restoreConversation() {
        restoringConversation = true
        defer { restoringConversation = false }
        let args = ProcessInfo.processInfo.arguments
        let requested = args.firstIndex(of: "--session").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let id = requested ?? conversationMemory?.selectedID
        selectedSession = id.map { ChatSession(id: $0, title: "Conversation", updatedAt: "", profile: grant?.host.profile ?? "") }
        draft = conversationMemory?.draft(for: id) ?? ""
    }
    private func selectionChanged(from old: ChatSession?) {
        if old?.id != selectedSession?.id, let id = selectedSession?.id { ChatPerformance.shared.selectConversation(id) }
        guard !restoringConversation, old?.id != selectedSession?.id else { return }
        resetStream()
        outboundSubmissions.removeAll()
        pendingSendPresentations.removeAll()
        canonicalSendOperations.removeAll()
        confirmation = nil
        if old == nil, let id = selectedSession?.id { attachmentDrafts.moveNewDraft(to: id) }
        let newDraft = old == nil && !draft.isEmpty ? draft : conversationMemory?.draft(for: selectedSession?.id) ?? ""
        draft = newDraft
        conversationMemory?.select(selectedSession?.id)
    }
    private func loadCachedHost() {
        guard let scope = hostScope else { return }
        let host = hostGeneration
        let cache = displayCache
        let revision = canonicalRevision
        cacheLoadTask = Task { [weak self] in
            let sessions = await cache.sessions(in: scope)
            guard let self, !Task.isCancelled, host == self.hostGeneration, revision == self.canonicalRevision else { return }
            if self.sessions.isEmpty { self.sessions = sessions }
            await self.restoreCachedSelection()
        }
    }
    private func loadCachedSelection() {
        if let id = selectedSession?.id, let cached = cachedConversations[id] {
            restoreCached(cached)
            return
        }
        cacheLoadTask = Task { [weak self] in await self?.restoreCachedSelection() }
    }
    private func restoreCachedSelection() async {
        guard let scope = hostScope, let context = commandContext else { return }
        let revision = canonicalRevision
        let reader = readerIntent
        let cached = await displayCache.conversation(context.sessionID, in: scope)
        guard !Task.isCancelled, context == commandContext, revision == canonicalRevision,
              reader == readerIntent, let cached else { return }
        restoreCached(cached)
    }
    private func restoreCached(_ cached: CachedConversation) {
        guard cached.scope == hostScope, cached.session.id == selectedSession?.id else { return }
        do { try transcript.restore(cached.window) } catch { return }
        selectedSession = cached.session
        recentTail = cached.recentTail ?? (cached.window.hasNewer ? nil : cached.window)
        lastCanonicalFetch = cached.fetchedAt
        readerPosition = cached.reader
        if case .anchored(let id, _) = readerPosition,
           !transcript.messages.contains(where: { $0.id == id || $0.renderID == id }) {
            readerPosition = transcript.messages.first.map { .anchored(messageID: $0.renderID, offsetFromUsableTop: 0) } ?? .latest
        }
        isReadingHistory = readerPosition != .latest || cached.window.hasNewer
        readerRestoration = .init(id: UUID(), position: readerPosition)
        retainInMemory(cached)
    }
    private func retainInMemory(_ cached: CachedConversation) {
        cachedConversations[cached.session.id] = cached
        while cachedConversations.count > ConversationDisplayCache.maxConversations || cachedConversations.values.reduce(0, { $0 + $1.byteCount }) > ConversationDisplayCache.maxBytes {
            guard let oldest = cachedConversations.values.min(by: { $0.viewedAt < $1.viewedAt }) else { break }
            cachedConversations.removeValue(forKey: oldest.session.id)
        }
    }
    private func rememberCurrentConversation() {
        guard let scope = hostScope, let session = selectedSession, lastCanonicalFetch != .distantPast else { return }
        let cached = CachedConversation(scope: scope, session: session, window: DisplayWindow(transcript),
            recentTail: recentTail, reader: readerPosition, fetchedAt: lastCanonicalFetch)
        retainInMemory(cached)
        let id = UUID()
        let cache = displayCache
        let predecessor = lastCacheWrite
        let task = Task { [weak self] in
            await predecessor?.value
            await cache.remember(cached)
            self?.cacheWrites.removeValue(forKey: id)
        }
        cacheWrites[id] = task
        lastCacheWrite = task
    }
    func readerPositionChanged(_ position: ReaderPosition, context: ConversationContext) {
        guard context == commandContext else { return }
        if case .anchored(_, let offset) = position, !offset.isFinite { return }
        readerPosition = position
        isReadingHistory = position != .latest || transcript.hasNewer
        rememberCurrentConversation()
    }
    func prepareTranscriptForSend() {
        guard isReadingHistory || transcript.hasNewer else { return }
        historyIntent = UUID()
        readerIntent = UUID()
        cancelLatestFetch()
        readerPosition = .latest
        readerRestoration = nil
        if let recentTail { try? transcript.restore(recentTail) }
        else { transcript = TranscriptWindow() }
        isReadingHistory = false
        newActivity = false
        latestRevision = UUID()
        scheduleRefresh(forceHistory: true)
    }
    private func persistDraft() {
        savedDraftRevisions[.init(host: hostGeneration, sessionID: selectedSession?.id)] = draftRevision
        guard !restoringConversation, let conversationMemory else { return }
        if !conversationMemory.saveDraft(draft, for: selectedSession?.id) {
            notice = "This large draft cannot be restored after closing the app. Copy it before closing."
        }
    }
    func start() async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--attachment-file"), args.indices.contains(index + 1) {
            await importFile(URL(fileURLWithPath: args[index + 1]))
        }
        #endif
        if fixture { return }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--invitation"), arguments.indices.contains(index + 1) {
            await pair(arguments[index + 1])
        } else if api != nil { connect() }
        await updateNotificationStatus()
    }
    func pair(_ invitationText: String) async {
        guard !isPairing else { return }
        isPairing = true
        defer { isPairing = false }
        do {
            let invitation = try Invitation.parse(invitationText)
            let baseURL = try validatedBaseURL(invitation.url)
            let client = CompanionAPI(baseURL: baseURL, token: nil)
            struct PairBody: Encodable, Sendable { let code: String; let deviceName: String }
            let result: PairResult = try await client.mutate("v1/pair", body: PairBody(code: invitation.code, deviceName: UIDevice.current.name))
            guard result.version == 1 else { throw ClientError.invalidResponse }
            let newGrant = DeviceGrant(baseURL: invitation.url, deviceID: result.deviceId, token: result.token, host: result.host)
            try GrantVault.save(newGrant)
            usePairedHost(newGrant, api: CompanionAPI(baseURL: baseURL, token: result.token))
            error = nil
            connect()
        } catch { self.error = error.localizedDescription }
    }
    func connect() {
        guard !fixture, sceneIsActive, !requiresPairing, let api, connectionTask == nil else { return }
        let host = hostGeneration
        connectionTask = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                guard let self, self.hostGeneration == host else { return }
                let attempt = UUID()
                self.connectionGeneration = attempt
                self.resetStream()
                self.freshAuthority = nil
                self.confirmation = nil
                self.requests = []
                var ownedSocket: URLSessionWebSocketTask?
                do {
                    let socket = try api.webSocket()
                    ownedSocket = socket
                    let episode = SynchronizationEpisode(id: attempt, host: host, api: api, socket: socket)
                    self.episode = episode
                    socket.resume()
                    try await self.synchronize(episode)
                    try self.requireCurrent(episode)
                    self.connection = "Connected"
                    if self.canCommand { self.connectionError = nil }
                    delay = 1
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        try self.requireCurrent(episode)
                        let data: Data
                        switch message {
                        case .data(let bytes): data = bytes
                        case .string(let string): data = Data(string.utf8)
                        @unknown default: continue
                        }
                        let decodeSpan = ChatPerformance.shared.begin(.socketDecode, count: data.count)
                        let event: WireEvent
                        do { event = try CompanionAPI.decoder.decode(WireEvent.self, from: data); ChatPerformance.shared.end(decodeSpan) }
                        catch { ChatPerformance.shared.end(decodeSpan, outcome: .failed); throw error }
                        try self.receive(event)
                    }
                } catch {
                    ownedSocket?.cancel(with: .goingAway, reason: nil)
                    guard !Task.isCancelled, self.hostGeneration == host, self.connectionGeneration == attempt else { return }
                    self.flushDeltas()
                    self.revokeCommandAuthority()
                    self.connection = ""
                    self.requests = []
                    self.controls = nil
                    self.confirmation = nil
                    self.connectionError = error.localizedDescription
                    if self.handleAuthorizationFailure(error) {
                        self.connectionTask = nil
                        self.episode = nil
                        return
                    }
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard self.hostGeneration == host, self.connectionGeneration == attempt else { return }
                    delay = min(delay * 2, 20)
                }
            }
        }
    }
    func reconnect() {
        guard sceneIsActive, !requiresPairing else { return }
        flushDeltas()
        stopConnection()
        connection = ""
        requests = []
        controls = nil
        runState = .synchronizing
        connect()
    }
    private func stopConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        episode?.socket?.cancel(with: .goingAway, reason: nil)
        episode = nil
        connectionGeneration = UUID()
        resetStream()
        revokeCommandAuthority()
    }
    func background() {
        sceneIsActive = false
        rememberCurrentConversation()
        for task in refreshTasks.values { task.cancel() }
        refreshTask = nil
        if fixture { return }
        flushDeltas()
        stopConnection()
        connection = ""
        requests = []
        controls = nil
        runState = .synchronizing
    }
    func waitForScheduledRefreshes() -> Task<Void, Never> {
        let tasks = Array(refreshTasks.values) + Array(cacheWrites.values) + [cacheLoadTask].compactMap { $0 }
        return Task {
            for task in tasks { await task.value }
        }
    }
    func foreground() {
        sceneIsActive = true
        attachmentDrafts.refreshExpiredTickets()
        if !fixture && api != nil { connect() }
    }
    private func requireCurrent(_ episode: SynchronizationEpisode) throws {
        try Task.checkCancellation()
        guard episode.host == hostGeneration, episode.id == connectionGeneration else { throw CancellationError() }
    }
    func synchronize() async throws {
        guard let api else { throw ClientError.notPaired }
        let episode = self.episode ?? SynchronizationEpisode(id: connectionGeneration, host: hostGeneration, api: api, socket: nil)
        try await synchronize(episode)
    }
    private func synchronize(_ episode: SynchronizationEpisode) async throws {
        let status: HostStatus = try await episode.api.get("v1/host")
        try requireCurrent(episode)
        guard status.version == 1, status.profile == nil || status.profile == hostScope?.profile else { throw ClientError.invalidResponse }
        hostStatus = status
        let list: SessionList = try await episode.api.get("v1/sessions")
        try requireCurrent(episode)
        sessions = list.sessions
        if let selected = selectedSession {
            if let updated = sessions.first(where: { $0.id == selected.id }) { selectedSession = updated }
        } else if let first = sessions.first {
            beginSelection(first)
        }
        if selectedSession != nil { try await refreshCurrent() }
        else { freshAuthority = .init(host: hostGeneration, episode: connectionGeneration, context: nil) }
        try requireCurrent(episode)
        connection = "Connected"
        if canCommand { connectionError = nil }
        let updateList: UpdateList = try await episode.api.get("v1/updates")
        try requireCurrent(episode)
        updates = Array(updateList.updates.prefix(200))
        knownUpdateIDs = Set(updates.map(\.id))
        hasLoadedUpdates = true
        let preferences: DeliveryPreferences = try await episode.api.get("v1/preferences")
        try requireCurrent(episode)
        self.preferences = preferences
        if let notificationToken {
            await registerPush(notificationToken)
            try requireCurrent(episode)
        }
    }
    func select(_ session: ChatSession) async {
        beginSelection(session)
        if fixture { loadFixtureTranscript(); return }
        let context = commandContext
        do { try await refreshCurrent() }
        catch {
            guard context == commandContext, !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            if !handleAuthorizationFailure(error) { connectionError = error.localizedDescription }
        }
    }
    func openResultConversation(_ id: String) async throws {
        if fixture { await select(Self.fixtureSession); return }
        guard let api else { throw ClientError.notPaired }
        let host = hostGeneration
        let selection = selectionGeneration
        let connection = connectionGeneration
        let authority = authorityRevision
        let snapshot: SessionSnapshot = try await api.get("v1/sessions/\(id)/snapshot")
        guard host == hostGeneration, selection == selectionGeneration, connection == connectionGeneration, authority == authorityRevision else { throw CancellationError() }
        guard snapshot.session.id == id,
              hostScope == nil || snapshot.session.profile == hostScope?.profile else { throw ClientError.invalidResponse }
        var history = TranscriptWindow()
        try history.replace(snapshot.page)
        beginSelection(snapshot.session)
        transcript = history
        try apply(snapshot, forceHistory: true)
        if !sessions.contains(where: { $0.id == id }) { sessions.insert(snapshot.session, at: 0) }
    }
    private func beginSelection(_ session: ChatSession) {
        rememberCurrentConversation()
        resetStream()
        freshAuthority = nil
        cacheLoadTask?.cancel()
        readerIntent = UUID()
        readerPosition = .latest
        readerRestoration = nil
        recentTail = nil
        lastCanonicalFetch = .distantPast
        refreshTask?.cancel()
        refreshTask = nil
        selectedSession = session
        latestRevision = UUID()
        selectionGeneration = UUID()
        cancelLatestFetch()
        historyIntent = UUID()
        transcript = TranscriptWindow()
        requests = []
        controls = nil
        runState = .synchronizing
        isReadingHistory = false
        newActivity = false
        pendingDeltas.removeAll()
        pendingDeltaBytes = 0
        loadCachedSelection()
    }
    private func scheduleRefresh(forceHistory: Bool = false) {
        refreshTask?.cancel()
        guard sceneIsActive, let api, let context = commandContext else { return }
        let intent = historyIntent
        let id = UUID()
        let observationRevision = snapshotRevision
        let connection = connectionGeneration
        let authority = authorityRevision
        let task = Task { [weak self] in
            defer { self?.refreshTasks.removeValue(forKey: id) }
            do {
                try Task.checkCancellation()
                let snapshot: SessionSnapshot = try await api.get("v1/sessions/\(context.sessionID)/snapshot")
                try Task.checkCancellation()
                guard let self, context == self.commandContext, intent == self.historyIntent, connection == self.connectionGeneration, authority == self.authorityRevision else { return }
                try self.apply(snapshot, forceHistory: forceHistory, observationRevision: observationRevision)
            } catch {
                guard let self, context == self.commandContext, connection == self.connectionGeneration else { return }
                self.handleAuthorizationFailure(error)
            }
        }
        refreshTasks[id] = task
        refreshTask = task
    }
    func refreshCurrent(forceHistory: Bool = false) async throws {
        guard let api, let context = commandContext else { return }
        let intent = historyIntent
        let connection = connectionGeneration
        let authority = authorityRevision
        let observationRevision = snapshotRevision
        let snapshot: SessionSnapshot = try await api.get("v1/sessions/\(context.sessionID)/snapshot")
        try Task.checkCancellation()
        guard context == commandContext, intent == historyIntent, connection == connectionGeneration, authority == authorityRevision else { return }
        try apply(snapshot, forceHistory: forceHistory, observationRevision: observationRevision)
    }
    @discardableResult
    private func apply(_ snapshot: SessionSnapshot, forceHistory: Bool = false, observationRevision: UInt64? = nil) throws -> Bool {
        guard snapshot.session.id == selectedSession?.id,
              hostScope == nil || snapshot.session.profile == hostScope?.profile else { throw ClientError.invalidResponse }
        var tail = TranscriptWindow()
        try tail.replace(snapshot.page)
        guard acceptSnapshotPosition(snapshot.streamPosition) else { return false }
        selectedSession = snapshot.session
        controls = snapshot.controls
        requests = snapshot.requests
        runState = snapshot.state
        if forceHistory || !isReadingHistory {
            transcript = tail
            ChatPerformance.shared.markConversation(.conversationSnapshotReady, sessionID: snapshot.session.id, count: transcript.messages.count)
            newActivity = false
        } else { newActivity = true }
        recentTail = DisplayWindow(tail)
        canonicalRevision &+= 1
        lastCanonicalFetch = Date()
        if sceneIsActive && !requiresPairing && snapshot.state != .offline && snapshot.state != .synchronizing {
            freshAuthority = .init(host: hostGeneration, episode: connectionGeneration, context: commandContext)
            connectionError = nil
        } else { revokeCommandAuthority(); requests = [] }
        reconcileSubmissions(messages: snapshot.page.messages, observationRevision: observationRevision)
        rememberCurrentConversation()
        if snapshot.streamPosition != nil {
            let buffered = bufferedStreamEvents
            bufferedStreamEvents.removeAll()
            bufferedStreamBytes = 0
            for event in buffered { try receive(event) }
            if !pendingDeltas.isEmpty { flushDeltas() }
        }
        return true
    }
    private func reconcileSubmissions(messages: [ChatMessage], observationRevision: UInt64? = nil) {
        let rowIDs = Set(messages.map(\.id)).union(currentSubmissions.compactMap(\.userRowID))
        canonicalSendOperations = canonicalSendOperations.filter { rowIDs.contains($0.key) && $0.value.context == commandContext }
        for index in outboundSubmissions.indices {
            guard outboundSubmissions[index].context == commandContext else { continue }
            if let observationRevision, let acceptanceRevision = outboundSubmissions[index].acceptanceRevision,
               observationRevision >= acceptanceRevision, case .accepted(nil) = outboundSubmissions[index].delivery {
                outboundSubmissions[index].previewRetired = true
            }
            guard let row = messages.first(where: {
                      $0.role == "user" && $0.operationId?.caseInsensitiveCompare(outboundSubmissions[index].operationID) == .orderedSame
                  }) else { continue }
            canonicalSendOperations[row.id] = .init(context: outboundSubmissions[index].context, operationID: outboundSubmissions[index].operationID)
            outboundSubmissions[index].delivery = .accepted(row.id)
            journal.resolve(outboundSubmissions[index].operationID)
            publishUncertainty()
            acknowledgeSubmittedDraft(at: index)
        }
        let retired = Set(outboundSubmissions.filter { $0.previewRetired }.map(\.operationID))
        pendingSendPresentations.removeAll { intent in
            retired.contains(intent.operationID) && !messages.contains { $0.renderID == intent.renderID }
        }
        outboundSubmissions.removeAll { submission in
            guard submission.context == commandContext, !submission.awaitingHTTPReceipt else { return false }
            if submission.previewRetired { return true }
            guard let id = submission.userRowID else { return false }
            return messages.contains { $0.id == id }
        }
    }
    func latest(forceRefresh: Bool = false) async {
        guard !isFetchingLatest else { return }
        ChatPerformance.shared.mark(.latestRequested)
        let intent = UUID()
        historyIntent = intent
        if !forceRefresh && !transcript.hasNewer && !newActivity {
            ChatPerformance.shared.mark(.latestWindowReady)
            isReadingHistory = false
            readerPosition = .latest
            readerRestoration = nil
            readerIntent = UUID()
            latestRevision = UUID()
            rememberCurrentConversation()
            return
        }
        if fixture {
            loadFixtureTranscript()
            newActivity = false
            isReadingHistory = false
            ChatPerformance.shared.mark(.latestWindowReady)
            latestRevision = UUID()
            return
        }
        guard let api, let context = commandContext else {
            ChatPerformance.shared.mark(.latestCancelled)
            return
        }
        latestFetchIntent = intent
        let connection = connectionGeneration
        let authority = authorityRevision
        let fetchSpan = ChatPerformance.shared.begin(.latestFetch)
        defer { if latestFetchIntent == intent { latestFetchIntent = nil } }
        let observationRevision = snapshotRevision
        do {
            let snapshot: SessionSnapshot = try await api.get("v1/sessions/\(context.sessionID)/snapshot")
            try Task.checkCancellation()
            guard context == commandContext, intent == historyIntent, connection == connectionGeneration, authority == authorityRevision else {
                ChatPerformance.shared.end(fetchSpan, outcome: .cancelled)
                return
            }
            guard snapshot.session.id == context.sessionID else { throw ClientError.invalidResponse }
            guard try apply(snapshot, forceHistory: true, observationRevision: observationRevision) else {
                ChatPerformance.shared.end(fetchSpan, outcome: .cancelled)
                return
            }
            ChatPerformance.shared.end(fetchSpan)
            ChatPerformance.shared.mark(.latestWindowReady)
            isReadingHistory = false
            readerPosition = .latest
            readerRestoration = nil
            readerIntent = UUID()
            latestRevision = UUID()
            rememberCurrentConversation()
        } catch {
            ChatPerformance.shared.end(fetchSpan, outcome: error is CancellationError ? .cancelled : .failed)
            guard context == commandContext, intent == historyIntent, connection == connectionGeneration, authority == authorityRevision else { return }
            ChatPerformance.shared.mark(.latestCancelled)
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    func userScrollBegan() {
        historyIntent = UUID()
        readerIntent = UUID()
        readerRestoration = nil
        cancelLatestFetch()
    }
    private func cancelLatestFetch() {
        if latestFetchIntent != nil { ChatPerformance.shared.mark(.latestCancelled) }
        latestFetchIntent = nil
    }
    func loadOlder() async {
        guard !isLoadingHistory, transcript.hasMore, let id = selectedSession?.id else { return }
        cancelLatestFetch()
        let intent = UUID()
        historyIntent = intent
        isLoadingHistory = true
        isReadingHistory = true
        defer { isLoadingHistory = false }
        if fixture {
            let lower = max(0, fixtureOldest - 120)
            try? transcript.prepend(fixturePage(lower..<fixtureOldest))
            fixtureOldest = lower
            return
        }
        guard let api, let before = transcript.before else { return }
        let generation = selectionGeneration
        let host = hostGeneration
        let connection = connectionGeneration
        do {
            let page: HistoryPage = try await api.get("v1/sessions/\(id)/history", query: [.init(name: "before", value: before)])
            guard generation == selectionGeneration, host == hostGeneration, connection == connectionGeneration, intent == historyIntent else { return }
            try transcript.prepend(page)
            rememberCurrentConversation()
        } catch {
            guard generation == selectionGeneration, host == hostGeneration, connection == connectionGeneration, intent == historyIntent else { return }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    @discardableResult
    func newSession(refresh: Bool = true) async -> String? {
        guard canCreateSession, !isSending else { return nil }
        if fixture { await select(Self.fixtureSession); return Self.fixtureSession.id }
        guard let api else { return nil }
        let host = hostGeneration
        let selection = selectionGeneration
        let connection = connectionGeneration
        struct Body: Encodable, Sendable { let operationId = UUID().uuidString }
        let body = Body()
        let owner = ActionOwner(host: host, operationID: body.operationId)
        pendingOperation = .init(owner: owner, action: .creating)
        defer { finishAction(owner) }
        do {
            let session: ChatSession = try await api.mutate("v1/sessions", body: body)
            guard host == hostGeneration, connection == connectionGeneration else { return nil }
            sessions.insert(session, at: 0)
            guard selection == selectionGeneration else { return nil }
            beginSelection(session)
            if refresh { scheduleRefresh(forceHistory: true) }
            else { try await refreshCurrent(forceHistory: true) }
            return session.id
        } catch {
            guard host == hostGeneration, connection == connectionGeneration else { return nil }
            self.error = error.localizedDescription + " The creation may have completed. Refresh before creating another chat."
            return nil
        }
    }
    struct AttachmentImportContext {
        let drafts: AttachmentDrafts
        let sessionID: String?
        let id: UUID
    }
    func beginAttachmentImport(name: String) -> AttachmentImportContext? {
        if let rejection = attachmentDrafts.importRejection(for: selectedSession?.id) { error = rejection; return nil }
        guard attachments.count < AttachmentDrafts.maxCount else { error = "Attach up to 4 files per message."; return nil }
        let item = DraftAttachment(id: UUID(), name: name, state: .importing)
        attachmentDrafts.set(attachments + [item], for: selectedSession?.id)
        return .init(drafts: attachmentDrafts, sessionID: selectedSession?.id, id: item.id)
    }
    func finishAttachmentImport(_ context: AttachmentImportContext, result: Result<AttachmentPayload, Error>) {
        guard context.drafts.contains(context.id) else {
            if case .success(let payload) = result {
                try? FileManager.default.removeItem(at: payload.fileURL)
                if let preview = payload.previewURL { try? FileManager.default.removeItem(at: preview) }
            }
            return
        }
        context.drafts.update(context.id, sessionID: context.drafts.sessionID(for: context.id)) { item in
            switch result {
            case .success(let payload): item.name = payload.name; item.state = .ready(payload)
            case .failure(let error): item.state = .failed(error.localizedDescription)
            }
        }
    }
    func importFile(_ url: URL) async {
        guard let context = beginAttachmentImport(name: url.lastPathComponent) else { return }
        do { finishAttachmentImport(context, result: .success(try await AttachmentImport.file(url, directory: context.drafts.directory, id: context.id))) }
        catch { finishAttachmentImport(context, result: .failure(error)) }
    }
    func retryAttachmentUpload(_ item: DraftAttachment) {
        guard item.payload != nil, !item.uncertainUpload, item.uploadError != nil, !isSending else { return }
        attachmentDrafts.update(item.id, sessionID: selectedSession?.id) {
            $0.uploadOperationID = UUID().uuidString.lowercased()
            $0.uploadError = nil
            $0.ticket = nil
            $0.uploadedAt = nil
        }
    }
    func removeAttachment(_ item: DraftAttachment) {
        let sessionID = selectedSession?.id
        attachmentDrafts.remove([item.id], sessionID: sessionID)
        if let ticket = item.ticket, let api, let sessionID {
            Task {
                struct Body: Encodable, Sendable { let operationId = UUID().uuidString }
                struct Removed: Decodable, Sendable { let removed: Bool? }
                let _: Removed? = try? await api.mutate("v1/sessions/\(sessionID)/attachments/\(ticket.id)", method: "DELETE", body: Body())
            }
        }
    }
    func send() async {
        attachmentDrafts.refreshExpiredTickets()
        let submittedDraft = draft
        let submittedDraftRevision = draftRevision
        let originatingMemory = conversationMemory
        let originatingAttachments = attachmentDrafts
        let originatingHost = hostGeneration
        let text = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendDraft, !isSending, !isStopping else { return }
        let intent = UUID()
        sendIntent = intent
        if !attachments.isEmpty, text.hasPrefix("/") {
            error = "Send attachments with a message. Remove them before using a slash command."
            return
        }
        if selectedSession == nil { guard await newSession(refresh: false) != nil else { return } }
        guard let submittedSessionID = selectedSession?.id, canCommand, originatingHost == hostGeneration, intent == sendIntent else { return }
        let origin = commandContext
        let submittedItems = attachments
        guard submittedItems.compactMap(\.payload).reduce(0, { $0 + $1.byteCount }) <= AttachmentDrafts.maxTotalBytes else {
            error = "Attachments must total 16 MB or less per message."; return
        }
        var ticketIDs: [String] = []
        if !submittedItems.isEmpty {
            guard !fixture, let api else { error = "Attachment delivery requires a connected Hermes host."; return }
            let owner = ActionOwner(host: originatingHost, operationID: intent.uuidString)
            pendingOperation = .init(owner: owner, action: .uploading)
            defer { finishAction(owner) }
            for item in submittedItems {
                guard origin == commandContext, intent == sendIntent else { return }
                if let ticket = item.ticket { ticketIDs.append(ticket.id); continue }
                guard let payload = item.payload else { return }
                do {
                    struct Body: Encodable, Sendable {
                        let operationId: String
                        let name: String
                        let mediaType: String
                        let contentBase64: String
                    }
                    let content = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: payload.fileURL).base64EncodedString() }.value
                    guard origin == commandContext, intent == sendIntent else { return }
                    let uploadedAt = Date()
                    let ticket: AttachmentTicket = try await api.mutate("v1/sessions/\(submittedSessionID)/attachments", body: Body(operationId: item.uploadOperationID, name: payload.name, mediaType: payload.mediaType, contentBase64: content))
                    guard ticket.status == "ready" else { throw ClientError.invalidResponse }
                    originatingAttachments.update(item.id, sessionID: submittedSessionID) { $0.ticket = ticket; $0.uploadedAt = uploadedAt; $0.uploadError = nil }
                    ticketIDs.append(ticket.id)
                } catch {
                    let definite = (error as? ClientError)?.isDefiniteRejection == true
                    originatingAttachments.update(item.id, sessionID: submittedSessionID) {
                        $0.uploadError = definite ? error.localizedDescription : "Upload was not confirmed. Remove this item and check the conversation before trying again."
                        $0.uncertainUpload = !definite
                    }
                    if origin == commandContext { self.error = error.localizedDescription }
                    return
                }
            }
        }
        guard origin == commandContext, intent == sendIntent else { return }
        var command = AgentCommand(kind: "send", text: text)
        command.attachmentIds = ticketIDs.isEmpty ? nil : ticketIDs
        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if let name = parts.first, controls?.commands.contains(where: { $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == name }) == true {
                command = AgentCommand(kind: "slash", name: String(name), arg: parts.count > 1 ? String(parts[1]) : "")
            }
        }
        if await execute(command, submittedDraft: submittedDraft, submittedDraftRevision: submittedDraftRevision, submittedAttachmentIDs: Set(submittedItems.map(\.id))) {
            originatingAttachments.remove(Set(submittedItems.map(\.id)), sessionID: submittedSessionID)
            if hostGeneration == originatingHost && selectedSession?.id == submittedSessionID {
                if draftRevision == submittedDraftRevision && draft == submittedDraft { draft = "" }
            } else if hostGeneration == originatingHost,
                      savedDraftRevisions[.init(host: originatingHost, sessionID: submittedSessionID)] == submittedDraftRevision,
                      originatingMemory?.draft(for: submittedSessionID) == submittedDraft {
                originatingMemory?.saveDraft("", for: submittedSessionID)
            }
        }
    }
    @discardableResult
    func execute(_ command: AgentCommand, submittedDraft: String? = nil, submittedDraftRevision: UUID? = nil, submittedAttachmentIDs: Set<UUID> = []) async -> Bool {
        guard canCommand, let id = selectedSession?.id else { return false }
        let interrupt = command.kind == "interrupt"
        guard interrupt ? !isStopping : (!isSending && !isStopping) else { return false }
        if command.kind == "send" { ChatPerformance.shared.beginSend(operationID: command.operationId, sessionID: id) }
        let owner = ActionOwner(host: hostGeneration, operationID: command.operationId)
        if interrupt { pendingInterrupt = owner; sendIntent = UUID() }
        else { pendingOperation = .init(owner: owner, action: .command(command.kind)) }
        defer {
            if interrupt {
                if pendingInterrupt == owner { pendingInterrupt = nil }
            } else { finishAction(owner) }
            if let index = outboundSubmissions.firstIndex(where: { $0.operationID == command.operationId }) {
                outboundSubmissions[index].awaitingHTTPReceipt = false
                reconcileSubmissions(messages: transcript.messages)
            }
        }
        if fixture { fixtureCommand(command); return true }
        guard let api else { return false }
        let origin = commandContext
        let originatingConnection = connectionGeneration
        if command.kind == "send", let origin {
            prepareTranscriptForSend()
            pendingSendPresentations.removeAll { $0.context != origin }
            pendingSendPresentations.append(.init(context: origin, operationID: command.operationId))
            let tickets = attachments.compactMap(\.ticket).filter { command.attachmentIds?.contains($0.id) == true }
            outboundSubmissions.append(.init(operationID: command.operationId, context: origin,
                text: command.text ?? "", attachments: tickets, precedingIDs: Set(displayMessages.map(\.id)),
                submittedDraft: submittedDraft, submittedDraftRevision: submittedDraftRevision, submittedAttachmentIDs: submittedAttachmentIDs))
        }
        journal.begin(command, sessionID: id, scope: hostScope)
        let receiptSpan = ChatPerformance.shared.begin(.sendReceipt)
        do {
            let receipt: CommandReceipt = try await api.mutate("v1/sessions/\(id)/commands", body: command)
            guard receipt.operationId.caseInsensitiveCompare(command.operationId) == .orderedSame else { throw ClientError.invalidResponse }
            let accepted = [.accepted, .queued, .steered, .redirected].contains(receipt.status)
            ChatPerformance.shared.end(receiptSpan, outcome: accepted ? .completed : .failed)
            receiveReceipt(receipt, origin: origin, episode: originatingConnection)
            let userRowID = receipt.userRowId ?? outboundSubmissions.first { $0.operationID == command.operationId }?.userRowID
            if accepted, origin == commandContext, originatingConnection == connectionGeneration, sceneIsActive, command.kind == "send",
               !transcript.messages.contains(where: { $0.id == userRowID }) {
                runState = requests.isEmpty ? .working : .waiting
            }
            if origin == commandContext, originatingConnection == connectionGeneration, sceneIsActive { scheduleRefresh() }
            return accepted
        } catch {
            ChatPerformance.shared.end(receiptSpan, outcome: .failed)
            if let submission = outboundSubmissions.first(where: { $0.operationID == command.operationId }),
               case .accepted = submission.delivery {
                if origin == commandContext, originatingConnection == connectionGeneration, sceneIsActive { scheduleRefresh() }
                return true
            }
            if (error as? ClientError)?.isDefiniteRejection == true {
                outboundSubmissions.removeAll { $0.operationID == command.operationId }
                pendingSendPresentations.removeAll { $0.operationID == command.operationId }
                journal.resolve(command.operationId)
                publishUncertainty()
                if origin == commandContext, originatingConnection == connectionGeneration, sceneIsActive {
                    if !handleAuthorizationFailure(error) { self.error = error.localizedDescription }
                }
            } else {
                if let index = outboundSubmissions.firstIndex(where: { $0.operationID == command.operationId }) {
                    outboundSubmissions[index].delivery = .uncertain
                }
                publishUncertainty()
                if origin == commandContext, originatingConnection == connectionGeneration, sceneIsActive {
                    self.error = "The host did not confirm this action. It may have completed. Check the conversation before sending again."
                    scheduleRefresh()
                }
            }
            return false
        }
    }
    func acknowledgeUncertain(_ operation: PendingOperation) {
        pendingSendPresentations.removeAll { $0.operationID.caseInsensitiveCompare(operation.operationID) == .orderedSame }
        journal.resolve(operation.operationID)
        publishUncertainty()
        outboundSubmissions.removeAll { submission in
            guard submission.operationID.caseInsensitiveCompare(operation.operationID) == .orderedSame else { return false }
            if case .uncertain = submission.delivery { return true }
            return false
        }
    }
    private func acknowledgeSubmittedDraft(at index: Int) {
        let submission = outboundSubmissions[index]
        guard !submission.draftAcknowledged else { return }
        outboundSubmissions[index].draftAcknowledged = true
        guard submission.context == commandContext else { return }
        if let submitted = submission.submittedDraft, draftRevision == submission.submittedDraftRevision, draft == submitted { draft = "" }
        attachmentDrafts.remove(submission.submittedAttachmentIDs, sessionID: selectedSession?.id)
    }
    private func receiveReceipt(_ receipt: CommandReceipt, origin: ConversationContext? = nil, episode: UUID? = nil, publish: Bool = true) {
        if let index = outboundSubmissions.firstIndex(where: { $0.operationID.caseInsensitiveCompare(receipt.operationId) == .orderedSame }) {
            switch receipt.status {
            case .accepted, .queued, .steered, .redirected:
                let rowID = receipt.userRowId.flatMap { $0.isEmpty ? nil : $0 } ?? outboundSubmissions[index].userRowID
                let firstAcceptance = outboundSubmissions[index].acceptanceRevision == nil
                if firstAcceptance {
                    snapshotRevision &+= 1
                    outboundSubmissions[index].acceptanceRevision = snapshotRevision
                }
                if let rowID, outboundSubmissions[index].context == commandContext {
                    canonicalSendOperations[rowID] = .init(context: outboundSubmissions[index].context, operationID: outboundSubmissions[index].operationID)
                }
                outboundSubmissions[index].delivery = .accepted(rowID)
                acknowledgeSubmittedDraft(at: index)
                if publish && firstAcceptance && rowID == nil && origin == nil && outboundSubmissions[index].context == commandContext { scheduleRefresh() }
            case .uncertain: outboundSubmissions[index].delivery = .uncertain
            case .rejected:
                pendingSendPresentations.removeAll { $0.operationID == outboundSubmissions[index].operationID }
                outboundSubmissions.remove(at: index)
            }
        }
        if receipt.status != .uncertain { journal.resolve(receipt.operationId) }
        publishUncertainty()
        guard publish, sceneIsActive, origin == nil || origin == commandContext,
              episode == nil || episode == connectionGeneration else { return }
        notice = receipt.message
        if let details = receipt.confirmation, let origin {
            if origin == commandContext {
                if episode == connectionGeneration, canCommand { confirmation = .init(details: details, context: origin) }
            } else { notice = "The model change needs confirmation in its original conversation. Choose the model there again." }
        } else if origin != nil { confirmation = nil }
        if receipt.status == .uncertain { error = "Delivery is uncertain. Check Hermes before sending again." }
        else if receipt.status == .rejected && receipt.confirmation == nil { error = receipt.message ?? "Hermes rejected the action." }
    }
    func answer(_ request: AgentRequest, answer: String) async {
        guard requests.contains(where: { $0.id == request.id && $0.generation == request.generation }) else { return }
        _ = await execute(.init(kind: "answer", requestId: request.id, generation: request.generation, answer: answer))
    }
    private func resetStream() {
        selectedStream = nil
        awaitingStreamEpoch = nil
        retiredStreamEpochs.removeAll()
        bufferedStreamEvents.removeAll()
        bufferedStreamBytes = 0
        resetStreamRecovery()
        pendingDeltas.removeAll()
        pendingDeltaBytes = 0
        deltaTask?.cancel()
        deltaTask = nil
    }
    private func resetStreamRecovery() {
        if case .running(_, let task) = streamRecovery { task.cancel() }
        streamRecovery = .idle
    }
    private func requestStreamRecovery() {
        guard case .idle = streamRecovery, sceneIsActive, !requiresPairing,
              let api, let context = commandContext else { return }
        revokeCommandAuthority()
        requests = []
        controls = nil
        let id = UUID()
        let connection = connectionGeneration
        let authority = authorityRevision
        let task = Task { [weak self] in
            defer {
                self?.refreshTasks.removeValue(forKey: id)
                if self?.streamRecovery.id == id { self?.streamRecovery = .idle }
            }
            for delay in [0, 250, 1000] {
                do {
                    if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                    try Task.checkCancellation()
                    guard let self, self.streamRecovery.id == id, self.sceneIsActive,
                          context == self.commandContext, connection == self.connectionGeneration,
                          authority == self.authorityRevision, !self.requiresPairing else { return }
                    let observationRevision = self.snapshotRevision
                    let snapshot: SessionSnapshot = try await api.get("v1/sessions/\(context.sessionID)/snapshot")
                    try Task.checkCancellation()
                    guard self.streamRecovery.id == id, self.sceneIsActive,
                          context == self.commandContext, connection == self.connectionGeneration,
                          authority == self.authorityRevision, !self.requiresPairing else { return }
                    if try self.apply(snapshot, observationRevision: observationRevision) { return }
                } catch {
                    guard let self, !Task.isCancelled, self.streamRecovery.id == id, self.sceneIsActive,
                          context == self.commandContext, connection == self.connectionGeneration,
                          authority == self.authorityRevision else { return }
                    if self.handleAuthorizationFailure(error) { return }
                    if case ClientError.server(let status, _, _) = error,
                       status == 409 || status == 429 || (500...599).contains(status) { continue }
                    if let error = error as? URLError, error.code != .cancelled { continue }
                    self.streamRecovery = .exhausted
                    self.connectionError = error.localizedDescription
                    return
                }
            }
            guard let self, self.streamRecovery.id == id, self.sceneIsActive,
                  context == self.commandContext, connection == self.connectionGeneration,
                  authority == self.authorityRevision else { return }
            self.streamRecovery = .exhausted
            self.connectionError = "Hermes could not synchronize this conversation. Reconnect to try again."
        }
        streamRecovery = .running(id, task)
        refreshTasks[id] = task
    }
    private func acceptSnapshotPosition(_ position: StreamPosition?) -> Bool {
        guard let position else { return selectedStream == nil && awaitingStreamEpoch == nil }
        guard !retiredStreamEpochs.contains(position.epoch) else { return false }
        if let awaitingStreamEpoch, position.epoch != awaitingStreamEpoch { return false }
        if let progress = selectedStream, progress.epoch == position.epoch {
            guard position.sequence > progress.snapshotSequence else { return false }
            guard position.sequence > progress.appliedSequence else {
                requestStreamRecovery()
                return false
            }
        } else if let progress = selectedStream {
            guard retiredStreamEpochs.count < 8 else { requestStreamRecovery(); return false }
            retiredStreamEpochs.insert(progress.epoch)
        }
        let received = selectedStream.flatMap { $0.epoch == position.epoch ? $0.receivedSequence : nil } ?? position.sequence
        selectedStream = .init(epoch: position.epoch, snapshotSequence: position.sequence,
            receivedSequence: max(received, position.sequence), appliedSequence: position.sequence)
        awaitingStreamEpoch = nil
        resetStreamRecovery()
        pendingDeltas.removeAll { $0.position?.epoch != position.epoch || ($0.position?.sequence ?? -1) <= position.sequence }
        pendingDeltaBytes = pendingDeltas.reduce(0) { $0 + $1.delta.text.utf8.count }
        return true
    }
    private func acceptStreamEvent(_ event: WireEvent) throws -> Bool {
        guard let position = event.streamPosition else {
            guard selectedStream == nil, awaitingStreamEpoch == nil else { throw ClientError.invalidResponse }
            return true
        }
        guard !retiredStreamEpochs.contains(position.epoch) else { return false }
        if var progress = selectedStream, progress.epoch == position.epoch {
            guard position.sequence > progress.receivedSequence else { return false }
            progress.receivedSequence = position.sequence
            selectedStream = progress
            if case .delta = event.payload {} else { markStreamApplied(position) }
            return true
        }
        if awaitingStreamEpoch != position.epoch {
            guard retiredStreamEpochs.count < 8 else { throw ClientError.invalidResponse }
            if let previous = selectedStream?.epoch ?? awaitingStreamEpoch { retiredStreamEpochs.insert(previous) }
            flushDeltas()
            selectedStream = nil
            awaitingStreamEpoch = position.epoch
            bufferedStreamEvents.removeAll()
            bufferedStreamBytes = 0
            resetStreamRecovery()
        }
        let bytes: Int
        switch event.payload {
        case .delta(let delta): bytes = delta.text.utf8.count + delta.id.utf8.count
        case .requests(let requests): bytes = try CompanionAPI.encoder.encode(requests).count
        case .controls(let controls): bytes = try CompanionAPI.encoder.encode(controls).count
        case .connection(let connection): bytes = connection.state.utf8.count + (connection.message?.utf8.count ?? 0)
        default: bytes = 0
        }
        guard bufferedStreamEvents.count < 1024, bufferedStreamBytes + bytes + 256 < TranscriptWindow.maxBytes else { throw ClientError.payloadTooLarge }
        bufferedStreamEvents.append(event)
        bufferedStreamBytes += bytes + 256
        requestStreamRecovery()
        return false
    }
    private func markStreamApplied(_ position: StreamPosition?) {
        guard let position, var progress = selectedStream, progress.epoch == position.epoch else { return }
        progress.appliedSequence = max(progress.appliedSequence, position.sequence)
        selectedStream = progress
    }
    func receive(_ event: WireEvent) throws {
        if case .update(let update) = event.payload {
            updates.removeAll { $0.id == update.id }
            updates.insert(update, at: 0)
            updates = Array(updates.prefix(200))
            if hasLoadedUpdates && knownUpdateIDs.insert(update.id).inserted { notify(update) }
            knownUpdateIDs.formIntersection(updates.map(\.id))
            return
        }
        if let sessionID = event.sessionId {
            guard sessionID == selectedSession?.id else { return }
            if case .snapshot(let snapshot) = event.payload {
                guard event.streamPosition == nil || event.streamPosition == snapshot.streamPosition else { throw ClientError.invalidResponse }
                if snapshot.streamPosition == nil { flushDeltas() }
                try apply(snapshot)
                return
            }
            if case .receipt(let receipt) = event.payload {
                let currentEpoch = selectedStream?.epoch ?? awaitingStreamEpoch
                let publish = event.streamPosition.map { !retiredStreamEpochs.contains($0.epoch) && (currentEpoch == nil || currentEpoch == $0.epoch) } ?? true
                receiveReceipt(receipt, publish: publish)
                return
            }
            guard try acceptStreamEvent(event) else { return }
        }
        if case .connection(let value) = event.payload {
            if let sessionID = event.sessionId {
                guard sessionID == selectedSession?.id else { return }
                guard let state = RunState(rawValue: value.state) else { throw ClientError.invalidResponse }
                runState = state
                if state == .offline || state == .synchronizing { requests = []; revokeCommandAuthority() }
            } else {
                connection = value.state == "connected" ? "Connected" : ""
                if value.state == "connected", canCommand { connectionError = nil }
                if value.state != "connected" { requests = []; revokeCommandAuthority() }
            }
            if value.state == "failed" { error = value.message ?? "Hermes could not finish this request." }
            if value.state == "offline" { connectionError = value.message ?? "The Hermes host is unavailable." }
            return
        }
        guard event.sessionId == selectedSession?.id else { return }
        switch event.payload {
        case .delta(let delta):
            guard pendingDeltas.count < 1024, pendingDeltaBytes + delta.text.utf8.count < TranscriptWindow.maxBytes else {
                throw ClientError.payloadTooLarge
            }
            ChatPerformance.shared.mark(.deltaQueued, count: delta.text.utf8.count)
            ChatPerformance.shared.add(.deltaQueuedItems)
            pendingDeltas.append(.init(delta: delta, position: event.streamPosition))
            pendingDeltaBytes += delta.text.utf8.count
            runState = .working
            if deltaTask == nil {
                deltaTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    self?.flushDeltas()
                }
            }
        case .requests(let value):
            guard canCommand else { return }
            requests = value
            if !value.isEmpty { runState = .waiting }
        case .controls(let value): if canCommand { controls = value }
        case .receipt(let value): receiveReceipt(value)
        default: break
        }
    }
    private func flushDeltas() {
        let span = ChatPerformance.shared.begin(.deltaFlush, count: pendingDeltas.count)
        var outcome = ChatPerformance.Outcome.completed
        var applied = 0
        defer { ChatPerformance.shared.end(span, outcome: outcome, count: applied) }
        deltaTask?.cancel()
        deltaTask = nil
        do {
            for queued in pendingDeltas {
                let delta = queued.delta
                let ignored = transcript.hasNewer
                try transcript.apply(delta)
                markStreamApplied(queued.position)
                if ignored {
                    ChatPerformance.shared.add(.deltaIgnoredItems)
                    ChatPerformance.shared.add(.deltaIgnoredUTF8Bytes, count: delta.text.utf8.count)
                } else {
                    applied += 1
                    ChatPerformance.shared.add(.deltaAppliedItems)
                    ChatPerformance.shared.add(.deltaAppliedUTF8Bytes, count: delta.text.utf8.count)
                }
            }
            if isReadingHistory { newActivity = true }
        } catch { outcome = .failed; self.error = error.localizedDescription }
        pendingDeltas.removeAll(keepingCapacity: true)
        pendingDeltaBytes = 0
    }
    func loadActivity() async {
        guard !fixture, let api else { return }
        let host = hostGeneration
        do {
            let jobList: JobList = try await api.get("v1/jobs")
            guard host == hostGeneration else { return }
            jobs = jobList.jobs
            let updateList: UpdateList = try await api.get("v1/updates")
            guard host == hostGeneration else { return }
            updates = Array(updateList.updates.prefix(200))
        } catch { if host == hostGeneration { self.error = error.localizedDescription } }
    }
    func createJob(name: String, instruction: String, schedule: String, notify: String) async -> Bool {
        guard !fixture, let api, let sessionId = selectedSession?.id else {
            if fixture { notice = "Fixture mode does not create Hermes schedules." }; return false
        }
        struct Body: Encodable, Sendable {
            let operationId = UUID().uuidString
            let sessionId: String; let name: String; let instruction: String; let schedule: String; let notify: String
        }
        do {
            let job: FollowUpJob = try await api.mutate("v1/jobs", body: Body(sessionId: sessionId, name: name, instruction: instruction, schedule: schedule, notify: notify))
            jobs.insert(job, at: 0)
            return true
        } catch { self.error = error.localizedDescription + " Check follow-ups before creating it again."; return false }
    }
    func toggleJob(_ job: FollowUpJob) async {
        guard !fixture, let api else { return }
        struct Body: Encodable, Sendable { let operationId = UUID().uuidString; let enabled: Bool }
        do {
            let updated: FollowUpJob = try await api.mutate("v1/jobs/\(job.id)", method: "PATCH", body: Body(enabled: !job.enabled))
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = updated }
        } catch { self.error = error.localizedDescription; await loadActivity() }
    }
    func updateDetail(_ id: String) async throws -> UpdateDetail {
        if fixture, let update = updates.first(where: { $0.id == id }) {
            return .init(update: update, text: "Controlled fixture result. A real result is read from Hermes.", resultSessionId: Self.fixtureSession.id)
        }
        guard let api else { throw ClientError.notPaired }
        return try await api.get("v1/updates/\(id)")
    }
    func savePreferences(_ value: DeliveryPreferences) async -> Bool {
        if fixture { preferences = value; return true }
        guard let api else { return false }
        let host = hostGeneration
        do {
            let saved: DeliveryPreferences = try await api.mutate("v1/preferences", method: "PUT", body: value)
            guard host == hostGeneration else { return false }
            preferences = saved
            return true
        } catch { if host == hostGeneration { self.error = error.localizedDescription }; return false }
    }
    func disconnect() async {
        guard !fixture, let api else { return }
        let host = hostGeneration
        let scope = hostScope
        struct Revoked: Decodable, Sendable { let revoked: Bool }
        do {
            let _: Revoked = try await api.perform(api.request("v1/device", method: "DELETE"))
            guard host == hostGeneration else { return }
            background()
            cacheLoadTask?.cancel()
            GrantVault.remove()
            grant = nil
            requiresPairing = false
            publishUncertainty()
            routedUpdateID = nil
            pendingOperation = nil
            pendingInterrupt = nil
            sendIntent = UUID()
            hostGeneration = UUID()
            selectionGeneration = UUID()
            self.api = nil
            restoringConversation = true
            selectedSession = nil
            draft = ""
            restoringConversation = false
            conversationMemory = nil
            sessions = []
            transcript = TranscriptWindow()
            cachedConversations.removeAll()
            recentTail = nil
            readerRestoration = nil
            updates = []
            jobs = []
            hostStatus = nil
            requests = []
            controls = nil
            notice = nil
            connectionError = nil
            if let scope {
                await lastCacheWrite?.value
                await displayCache.retire(scope)
            }
        } catch { if host == hostGeneration { self.error = error.localizedDescription } }
    }
    func enableNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            await updateNotificationStatus()
        } catch { self.error = error.localizedDescription }
    }
    func updateNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus == .authorized ? "Enabled on this iPhone" : "Not enabled on this iPhone"
    }
    func registerPush(_ token: String) async {
        notificationToken = token
        guard !fixture, let api else { return }
        struct Body: Encodable, Sendable { let pushToken: String; let environment: String }
        struct Result: Decodable, Sendable { let registered: Bool }
        let host = hostGeneration
        let connection = connectionGeneration
        do {
            let entitlementEnvironment = Bundle.main.object(forInfoDictionaryKey: "CompanionPushEnvironment") as? String
            let environment = entitlementEnvironment == "production" ? "production" : "sandbox"
            let _: Result = try await api.mutate("v1/device", method: "PATCH", body: Body(pushToken: token, environment: environment))
        } catch {
            guard host == hostGeneration, connection == connectionGeneration else { return }
            notice = "Push registration is unavailable. In-app updates remain available."
        }
    }
    func routeNotification(updateID: String?, sessionID: String?) async {
        let host = hostGeneration
        if !fixture, api != nil { try? await synchronize() }
        guard host == hostGeneration else { return }
        if let sessionID, let session = sessions.first(where: { $0.id == sessionID }) { await select(session) }
        guard host == hostGeneration else { return }
        if let updateID { routedUpdateID = updateID }
        else { try? await refreshCurrent() }
    }
    private func notify(_ update: AgentUpdate) {
        guard preferences.notificationsEnabled else { return }
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: preferences.timeZone) ?? .current
        let minutes = calendar.component(.hour, from: Date()) * 60 + calendar.component(.minute, from: Date())
        if let start = preferences.quietStart, let end = preferences.quietEnd {
            let quiet = start <= end ? (start..<end).contains(minutes) : minutes >= start || minutes < end
            if quiet { return }
        }
        let content = UNMutableNotificationContent()
        content.title = update.kind == "needs_you" ? "Hermes needs you" : "Hermes has an update"
        content.body = "Open Companion to see the details."
        content.userInfo = ["update_id": update.id, "session_id": update.sessionId ?? ""]
        UNUserNotificationCenter.current().add(.init(identifier: update.id, content: content, trigger: nil))
    }
}

extension AppStore {
    static let fixtureSession = ChatSession(id: "fixture-history", title: "A thoughtful workspace", updatedAt: "2026-10-19T00:00:00Z", profile: "UI test fixture")
    private func fixturePage(_ range: Range<Int>) -> HistoryPage {
        let messages = range.map { index in
            ChatMessage(id: "fixture-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant", text: index == 9999 ? "I’ve organized the next steps. We can explore an idea, work through code, or keep an eye on something important.\n\nYour agent stays on your own computer." : "Message \(index + 1). " + (index.isMultiple(of: 13) ? "A longer note with enough detail to read while the conversation continues.\n\n```swift\nlet nextStep = idea.refined()\n```\nThe context remains in Hermes." : "A small step toward a useful result."), provisional: false)
        }
        return .init(messages: messages, before: range.lowerBound > 0 ? String(range.lowerBound) : nil, hasMore: range.lowerBound > 0)
    }
    private func loadFixture() {
        attachmentDrafts = AttachmentDrafts(hostID: "ui-fixture")
        attachmentDrafts.set([], for: Self.fixtureSession.id)
        grant = .init(baseURL: "http://127.0.0.1", deviceID: "fixture", token: "fixture-not-a-credential", host: .init(name: "UI fixture", profile: "Isolated fixture"))
        sessions = [Self.fixtureSession]
        if ProcessInfo.processInfo.arguments.contains("--fixture-drawer-sessions") {
            sessions += (0..<24).map {
                ChatSession(id: "fixture-drawer-\($0)", title: "Conversation \($0 + 1) about a useful next step", updatedAt: "", profile: "fixture")
            }
        }
        selectedSession = Self.fixtureSession
        connection = "Connected"
        loadFixtureTranscript()
        controls = .init(model: "fixture-model", provider: "fixture", pendingModel: nil, reasoning: "medium", reasoningLevels: ["low", "medium", "high"], models: [.init(id: "fixture-model", provider: "fixture", label: "Fixture model", reasoning: true), .init(id: "fixture-other", provider: "fixture", label: "Another fixture model", reasoning: true)], commands: [.init(name: "model", description: "Choose a model"), .init(name: "reasoning", description: "Change reasoning"), .init(name: "status", description: "Show status")])
        if ProcessInfo.processInfo.arguments.contains("--fixture-approval") {
            requests = [.init(id: "approval-1", generation: "generation-1", kind: "approval", title: "Review this action", description: "The fixture agent wants to publish a draft. This controlled fixture performs no external action.", choices: [.init(id: "allow", label: "Approve once"), .init(id: "deny", label: "Decline")], allowsText: false)]
            runState = .waiting
        }
        if ProcessInfo.processInfo.arguments.contains("--fixture-reconnect") {
            fixtureTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.connection = "Reconnecting"
                self?.requests = []
                try? await Task.sleep(for: .seconds(4))
                self?.connection = "Connected"
                self?.notice = "Fixture connection restored. No command was replayed."
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--fixture-no-push") { hostStatus = .init(version: 1, capabilities: .init(notifications: false)) }
        if ProcessInfo.processInfo.arguments.contains("--fixture-working") { runState = .working }
        if ProcessInfo.processInfo.arguments.contains("--fixture-multiline") { draft = "Help me refine this idea.\nKeep the important details.\nShow me the next useful step." }
        if ProcessInfo.processInfo.arguments.contains("--fixture-empty") { transcript = TranscriptWindow() }
        if ProcessInfo.processInfo.arguments.contains("--fixture-attachment-importing") {
            attachmentDrafts.set([.init(id: UUID(), name: "Photo", state: .importing)], for: selectedSession?.id)
        }
        if ProcessInfo.processInfo.arguments.contains("--fixture-attachment-failed") {
            attachmentDrafts.set([.init(id: UUID(), name: "Large document.pdf", state: .failed("Each file must be 5 MB or smaller."))], for: selectedSession?.id)
        }
        updates = [.init(id: "fixture-update", kind: "result", title: "A useful change", summary: "A completed follow-up appears here with its original result.", createdAt: "2026-10-19T00:00:00Z", sessionId: Self.fixtureSession.id, jobId: nil, resultSessionId: Self.fixtureSession.id)]
    }
    private func loadFixtureTranscript() {
        fixtureOldest = 9880
        if ProcessInfo.processInfo.arguments.contains("--fixture-muse") {
            let conversation: [(String, String)] = [
                ("assistant", "The project is ready for a focused review. I’ve kept your decisions together so we can pick up where we left off.\n\nThe next step is to check the experience on a real conversation, including the small details that make it comfortable to use."),
                ("user", "What should we look at first?"),
                ("assistant", "Start with the conversation itself. The message you’re reading should stay in place while new text arrives, and your draft should stay intact when you switch tasks.\n\nThen check the controls. You should be able to send a message, add a picture, or stop the agent without hunting for the right button."),
                ("user", "Can you make a short checklist?"),
                ("assistant", "## A useful first pass\n\n- **Read comfortably:** keep the conversation visible behind the controls.\n- **Stay in control:** preserve a draft while the agent works.\n- **Show the result:** present the actual answer with clear formatting.\n\n### Before sharing\n\n1. Try a long conversation.\n2. Scroll back while a reply streams.\n3. Return to the newest message.\n\nA small example:\n\n```swift\nlet message = \"A useful next step\"\nprint(message)\n```\n\nKeep **bold**, *emphasis*, and [links](https://example.com) readable. Literal code such as `<untrusted_tool_result>` and `{\"ok\": true}` remains visible when it is part of the answer."),
                ("user", "That sounds right. Keep going."),
                ("assistant", "I’ll work through those checks and keep the results in this conversation.\n\nYou can keep writing while I work. If something needs your decision, the question will appear here with the relevant details.")
            ]
            let messages = conversation.enumerated().map { index, row in
                ChatMessage(id: "muse-\(index)", role: row.0, text: row.1, provisional: false)
            }
            try? transcript.replace(.init(messages: messages, before: nil, hasMore: false))
        } else if ProcessInfo.processInfo.arguments.contains("--fixture-long-code") {
            let code = (1...200).map { "let line\($0) = \($0) // a readable source line" }.joined(separator: "\n")
            try? transcript.replace(.init(messages: [.init(id: "fixture-code", role: "assistant", text: "A code example.\n\n```swift\n" + code + "\n```\nCode ends here.", provisional: false)], before: nil, hasMore: false))
        } else { try? transcript.replace(fixturePage(9880..<10000)) }
        runState = .idle
        newActivity = false
    }
    private func fixtureCommand(_ command: AgentCommand) {
        if command.kind == "answer" { requests = []; runState = .idle; notice = "Fixture request resolved." }
        if command.kind == "interrupt" { fixtureTimer?.cancel(); runState = .idle }
        if command.kind == "model" || command.kind == "reasoning", let old = controls {
            controls = .init(model: command.kind == "model" ? command.value! : old.model, provider: "fixture", pendingModel: nil, reasoning: command.kind == "reasoning" ? command.value! : old.reasoning, reasoningLevels: old.reasoningLevels, models: old.models, commands: old.commands)
        }
        if command.kind == "send" {
            let user = ChatMessage(id: "fixture-user-" + command.operationId, role: "user", text: command.text ?? "", provisional: false)
            try? transcript.replace(.init(messages: Array(transcript.messages.suffix(119)) + [user], before: transcript.before, hasMore: transcript.hasMore))
            runState = .working
            fixtureTimer?.cancel()
            fixtureTimer = Task { [weak self] in
                for index in 0..<80 {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    try? self?.transcript.apply(.init(id: "fixture-stream", text: index == 0 ? "Controlled streaming fixture. " : "A new thought arrives. ", replace: index == 0))
                }
                #if DEBUG
                if self?.fixtureHoldWork == true { return }
                #endif
                self?.runState = .idle
            }
        }
    }
}
