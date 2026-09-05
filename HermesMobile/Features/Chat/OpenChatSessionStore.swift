import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class OpenChatSessionStore {
    static let shared = OpenChatSessionStore()
    static let maxRetainedIdleSessionCount = 8

    /// The store keeps a small warm set so ordinary back-and-forth navigation can
    /// reuse transcripts, while repeated session opens cannot retain every chat for
    /// the lifetime of the process. Active streams are never counted as evictable.
    private let retentionPolicy: OpenChatSessionStoreRetentionPolicy
    private var viewModels: [OpenChatSessionKey: ChatViewModel] = [:]
    private var canonicalAliases: [OpenChatSessionKey: OpenChatSessionKey] = [:]
    private var gitAvailabilityViewModels: [OpenChatSessionKey: GitWorkspaceAvailabilityViewModel] = [:]
    /// Oldest first. This is deliberately separate from the dictionary so eviction
    /// remains deterministic instead of depending on dictionary iteration order.
    private var accessOrder: [OpenChatSessionKey] = []
    /// One canonical refresh task per server. Foreground, pull-to-refresh, reopen,
    /// and event hints may arrive together; they all await the same reconciliation
    /// instead of issuing duplicate `/api/session` loads for every retained chat.
    private var refreshTasks: [String: Task<Int, Never>] = [:]
    private var deferredRetentionTrimTask: Task<Void, Never>?
    private(set) var liveOwnershipGeneration = 0
    private var activeGatewayOrigin: URL?
    private var gatewayRuntime: HermesServerRuntime?
    @ObservationIgnored private var gatewayTeardown: Task<Void, Never>?
    private var gatewayGeneration = 0

    /// Authentication owns activation. A stale chat cannot reactivate a server
    /// after sign-out or an account switch. New sockets await the old teardown.
    func activateGateway(server: URL?) {
        guard activeGatewayOrigin != server else { return }
        activeGatewayOrigin = server
        gatewayGeneration &+= 1
        let previousTeardown = gatewayTeardown
        let previousRuntime = gatewayRuntime
        gatewayRuntime = nil
        let previousModels = Array(viewModels.values)
        viewModels.removeAll()
        canonicalAliases.removeAll()
        gitAvailabilityViewModels.removeAll()
        accessOrder.removeAll()
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
        // Invalidate immediately, before any asynchronous close can suspend.
        previousModels.forEach { $0.invalidateDirectConversation() }
        gatewayTeardown = Task {
            await previousTeardown?.value
            for model in previousModels { await model.disposeDirectConversation() }
            await previousRuntime?.stop()
        }
        noteStreamingStateChanged()
    }

    func runtime(for server: URL, client: APIClient) async throws -> HermesServerRuntime {
        guard activeGatewayOrigin == server else { throw DirectSessionError.stopped }
        let generation = gatewayGeneration
        await gatewayTeardown?.value
        guard generation == gatewayGeneration, activeGatewayOrigin == server else { throw DirectSessionError.staleOperation }
        if let gatewayRuntime { return gatewayRuntime }
        let created = try HermesServerRuntime(origin: server, client: client)
        gatewayRuntime = created
        return created
    }

    var retainedSessionCountForTesting: Int { viewModels.count }

    init(retentionPolicy: OpenChatSessionStoreRetentionPolicy = .production) {
        self.retentionPolicy = retentionPolicy
    }

    func viewModel(
        session: SessionSummary,
        server: URL,
        showsLiveActivityResponseExcerpts: Bool = false,
        sessionEventStreamClient: SSEStreamingClient? = nil
    ) -> ChatViewModel {
        let requestedKey = OpenChatSessionKey(server: server, sessionID: Self.normalizedSessionID(session), profile: session.profile)
        let key = canonicalAliases[requestedKey] ?? requestedKey
        if let existing = viewModels[key] {
            touch(key)
            existing.markReusedFromOpenSessionStore()
            // Session-event sync is owned by ChatView visibility, not store
            // retention: always-on background streams for every retained chat
            // caused main-thread churn (disk writes + transcript reloads) and
            // regressed per-conversation smoothness (build 19 regression).
            return existing
        }

        let created = ChatViewModel(
            session: session,
            server: server,
            sessionEventStreamClient: sessionEventStreamClient,
            showsLiveActivityResponseExcerpts: showsLiveActivityResponseExcerpts,
            gatewayRuntimeProvider: { [weak self] client in
                guard let self else { throw DirectSessionError.stopped }
                return try await self.runtime(for: server, client: client)
            }
        )
        created.onDirectCanonicalID = { [weak self, weak created] id in
            guard let self, let created else { return }
            self.rekey(created, server: server, sessionID: id, profile: session.profile)
        }
        viewModels[key] = created
        touch(key)
        trimIdleViewModels(forServer: key.server)
        return created
    }

    private func rekey(_ model: ChatViewModel, server: URL, sessionID: String, profile: String?) {
        let target = OpenChatSessionKey(server: server, sessionID: sessionID, profile: profile)
        // Aliases are redirects, not extra retained models or refresh entries.
        let oldKeys = viewModels.keys.filter { viewModels[$0] === model }
        if let displaced = viewModels[target], displaced !== model {
            displaced.invalidateDirectConversation()
            Task { await displaced.disposeDirectConversation() }
        }
        for key in oldKeys where key != target {
            viewModels.removeValue(forKey: key)
            if let git = gitAvailabilityViewModels.removeValue(forKey: key) { gitAvailabilityViewModels[target] = git }
            accessOrder.removeAll { $0 == key }
            canonicalAliases[key] = target
            for alias in Array(canonicalAliases.keys) where canonicalAliases[alias] == key {
                canonicalAliases[alias] = target
            }
        }
        viewModels[target] = model
        touch(target)
    }

    func gitAvailabilityViewModel(
        session: SessionSummary,
        server: URL,
        chatViewModel: ChatViewModel
    ) -> GitWorkspaceAvailabilityViewModel {
        let requestedKey = OpenChatSessionKey(server: server, sessionID: Self.normalizedSessionID(session), profile: session.profile)
        let key = canonicalAliases[requestedKey] ?? requestedKey
        if let existing = gitAvailabilityViewModels[key] {
            touch(key)
            return existing
        }

        let retainedChatViewModel: ChatViewModel
        if let existing = viewModels[key] {
            retainedChatViewModel = existing
        } else {
            viewModels[key] = chatViewModel
            touch(key)
            retainedChatViewModel = chatViewModel
        }

        let created = GitWorkspaceAvailabilityViewModel(
            session: session,
            server: server,
            apiClient: retainedChatViewModel.client
        )
        gitAvailabilityViewModels[key] = created
        touch(key)
        trimIdleViewModels(forServer: key.server)
        return created
    }

    @discardableResult
    func adoptedViewModel(
        session: SessionSummary,
        server: URL,
        creating viewModel: ChatViewModel
    ) -> ChatViewModel {
        let requestedKey = OpenChatSessionKey(server: server, sessionID: Self.normalizedSessionID(session), profile: session.profile)
        let key = canonicalAliases[requestedKey] ?? requestedKey
        viewModels[key] = viewModel
        touch(key)
        noteStreamingStateChanged()
        return viewModel
    }

    func liveSessionIDs(for server: URL) -> Set<String> {
        _ = liveOwnershipGeneration
        let serverKey = OpenChatSessionKey.normalizedServer(server)
        return Set(
            viewModels.compactMap { key, viewModel in
                guard key.server == serverKey, viewModel.activeStreamID != nil else { return nil }
                return key.sessionID
            }
        )
    }

    var allLiveSessionIDs: Set<String> {
        _ = liveOwnershipGeneration
        return Set(
            viewModels.compactMap { key, viewModel in
                guard viewModel.activeStreamID != nil else { return nil }
                return key.sessionID
            }
        )
    }

    func liveStreamIDs(for server: URL) -> [String] {
        _ = liveOwnershipGeneration
        let serverKey = OpenChatSessionKey.normalizedServer(server)
        return viewModels
            .compactMap { key, viewModel in
                // This list feeds the legacy sidebar status watcher. Direct UI
                // liveness values are not WebUI RPC IDs and must never go there.
                guard key.server == serverKey, !viewModel.usesDirectGateway else { return nil }
                return viewModel.activeStreamID?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .sorted()
    }

    #if DEBUG
    /// Narrow test-only visibility into the retention boundary. Production callers
    /// continue to use viewModel/liveSessionIDs rather than the retained collection.
    func retainedSessionIDsForTesting(for server: URL) -> [String] {
        let serverKey = OpenChatSessionKey.normalizedServer(server)
        return accessOrder.compactMap { key in
            guard key.server == serverKey, viewModels[key] != nil else { return nil }
            return key.sessionID
        }
    }

    func retainedViewModelCountForTesting(for server: URL) -> Int {
        retainedSessionIDsForTesting(for: server).count
    }
    #endif

    /// Reconciles transcripts for sessions that are already retained by the chat
    /// navigation store. The sidebar list endpoint returns summaries only; without
    /// this explicit pass, a message sent from TUI/WebUI can leave a warm iOS
    /// ChatViewModel showing an older transcript after pull-to-refresh.
    ///
    /// The server remains canonical. ChatViewModel owns its existing load-generation,
    /// optimistic-message, active-stream, and cache-preservation guards, so this
    /// method only coordinates the open models and never replaces them wholesale.
    @discardableResult
    func refreshOpenSessions(
        for server: URL,
        modelContext: ModelContext? = nil
    ) async -> Int {
        let serverKey = OpenChatSessionKey.normalizedServer(server)
        if let existingTask = refreshTasks[serverKey] {
            return await existingTask.value
        }

        let task = Task { @MainActor [weak self] in
            defer { self?.refreshTasks.removeValue(forKey: serverKey) }
            guard let self else { return 0 }
            return await self.refreshOpenSessionsUncoalesced(
                for: serverKey,
                modelContext: modelContext
            )
        }
        refreshTasks[serverKey] = task
        return await task.value
    }

    private func refreshOpenSessionsUncoalesced(
        for serverKey: String,
        modelContext: ModelContext?
    ) async -> Int {
        let openViewModels = viewModels.compactMap { (key, viewModel) -> ChatViewModel? in
            guard key.server == serverKey, viewModel.hasServerBackedSession else { return nil }
            return viewModel
        }
        var refreshedCount = 0
        for viewModel in openViewModels {
            guard !Task.isCancelled else { break }
            await viewModel.loadMessages(modelContext: modelContext)
            refreshedCount += 1
        }
        return refreshedCount
    }

    func noteStreamingStateChanged() {
        liveOwnershipGeneration &+= 1
        // Most callers notify while a stream is finalizing, before the model clears
        // activeStreamID. Trim now for ordinary changes and once more on the next
        // main-actor turn so active-to-idle transitions are handled safely.
        trimIdleViewModels()
        deferredRetentionTrimTask?.cancel()
        deferredRetentionTrimTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.deferredRetentionTrimTask = nil
            self.trimIdleViewModels()
        }
    }

    func resetForTesting() {
        activateGateway(server: nil)
        deferredRetentionTrimTask?.cancel()
        deferredRetentionTrimTask = nil
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
        viewModels.values.forEach { $0.stopSessionEventSync() }
        gitAvailabilityViewModels.removeAll()
        viewModels.removeAll()
        canonicalAliases.removeAll()
        accessOrder.removeAll()
        liveOwnershipGeneration = 0
    }

    private func touch(_ key: OpenChatSessionKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func trimIdleViewModels(forServer serverKey: String? = nil) {
        let servers: [String]
        if let serverKey {
            servers = [serverKey]
        } else {
            servers = Set(viewModels.keys.map(\.server)).sorted()
        }

        for server in servers {
            var idleCount = viewModels.reduce(into: 0) { count, entry in
                guard entry.key.server == server, entry.value.activeStreamID == nil else { return }
                count += 1
            }
            guard idleCount > retentionPolicy.maxIdleViewModelsPerServer else { continue }

            // Iterate over a snapshot because eviction removes keys from the live
            // access-order array. Active entries are skipped, allowing idle entries
            // behind them to be evicted without ever disturbing a live run.
            let orderedKeys = accessOrder
            for key in orderedKeys where key.server == server {
                guard idleCount > retentionPolicy.maxIdleViewModelsPerServer else { break }
                guard let viewModel = viewModels[key], viewModel.activeStreamID == nil else { continue }
                evict(key: key, viewModel: viewModel)
                idleCount -= 1
            }
        }
    }

    private func evict(key: OpenChatSessionKey, viewModel: ChatViewModel) {
        // Stop owned work before dropping the store's strong reference. These APIs
        // are also used by navigation/reset paths and avoid relying on deinit timing.
        viewModel.stopSessionEventSync()
        viewModel.cancelOwnedStreamStatusWatch()
        viewModel.cleanupPollingTasks()
        viewModel.invalidateDirectConversation()
        Task { await viewModel.disposeDirectConversation() }
        let aliases = viewModels.keys.filter { viewModels[$0] === viewModel }
        for alias in aliases {
            viewModels.removeValue(forKey: alias)
            gitAvailabilityViewModels.removeValue(forKey: alias)
        }
        accessOrder.removeAll { aliases.contains($0) }
        canonicalAliases = canonicalAliases.filter { !aliases.contains($0.value) }
    }
    private static func normalizedSessionID(_ session: SessionSummary) -> String {
        let raw = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty {
            return raw
        }
        return session.id
    }
}

struct OpenChatSessionStoreRetentionPolicy: Equatable {
    /// Eight idle models preserve normal warm navigation while bounding the
    /// transcript/client/task graph retained by a process that visits many chats.
    static let production = Self(maxIdleViewModelsPerServer: OpenChatSessionStore.maxRetainedIdleSessionCount)

    let maxIdleViewModelsPerServer: Int

    init(maxIdleViewModelsPerServer: Int) {
        self.maxIdleViewModelsPerServer = max(0, maxIdleViewModelsPerServer)
    }
}

@MainActor
final class SessionEventStreamCoordinator {
    private let streamClient: SSEStreamingClient
    private let server: URL
    private let sessionID: String
    private let profile: String?
    private let cursorStore: SessionEventCursorStore
    private var isRunning = false
    private var generation = 0
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var lastAcceptedEventID: String?
    private var seenEventIDs: Set<String>
    private var seenEventOrder: [String]
    /// Debounces synchronous UserDefaults writes. Streaming bursts deliver one
    /// event at a time on the main actor; writing the cursor and seen-ID array
    /// for every event hitches scrolling/typing (main-actor disk I/O).
    private var cursorPersistTask: Task<Void, Never>?


    var onSnapshot: (@MainActor (SessionSummary) -> Bool)?
    var onEvent: (@MainActor (SSEEvent) -> Void)?

    init(
        server: URL,
        sessionID: String,
        profile: String?,
        streamClient: SSEStreamingClient,
        userDefaults: UserDefaults = .standard
    ) {
        self.server = server
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profile = profile
        self.streamClient = streamClient
        self.cursorStore = SessionEventCursorStore(defaults: userDefaults)
        let persistedSeenIDs = cursorStore.loadSeenEventIDs(
            server: server,
            profile: profile,
            sessionID: self.sessionID
        )
        self.seenEventIDs = Set(persistedSeenIDs)
        self.seenEventOrder = persistedSeenIDs

    }

    var persistedEventID: String? {
        cursorStore.load(server: server, profile: profile, sessionID: sessionID)
    }

    func start() {
        guard !sessionID.isEmpty else { return }
        if isRunning {
            stop()
        }
        isRunning = true
        reconnectAttempt = 0
        connect()
    }

    func stop() {
        isRunning = false
        generation &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        streamClient.stop()
        flushCursorPersist()
    }

    /// Coalesces cursor + seen-ID persistence into one delayed write per burst.
    /// In-memory dedupe state stays immediately consistent; only the disk
    /// mirror is deferred. A crash within the window replays at most a few
    /// already-deduped events, which handleSessionEvent tolerates.
    private func scheduleCursorPersist() {
        cursorPersistTask?.cancel()
        cursorPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.cursorPersistTask = nil
            guard let eventID = self.lastAcceptedEventID else { return }
            self.cursorStore.save(
                eventID: eventID,
                server: self.server,
                profile: self.profile,
                sessionID: self.sessionID
            )
            self.cursorStore.saveSeenEventIDs(
                self.seenEventOrder,
                server: self.server,
                profile: self.profile,
                sessionID: self.sessionID
            )
        }
    }

    private func flushCursorPersist() {
        cursorPersistTask?.cancel()
        cursorPersistTask = nil
        guard let eventID = lastAcceptedEventID else { return }
        cursorStore.save(
            eventID: eventID,
            server: server,
            profile: profile,
            sessionID: sessionID
        )
        cursorStore.saveSeenEventIDs(
            seenEventOrder,
            server: server,
            profile: profile,
            sessionID: sessionID
        )
    }

    private func connect() {
        guard !sessionID.isEmpty else { return }
        generation &+= 1
        let connectionGeneration = generation
        let url = Endpoint.sessionEvents(sessionID: sessionID).url(relativeTo: server)
        // Prefer the in-memory cursor: persistence is debounced, so the disk
        // mirror can lag behind during a streaming burst while a reconnect is
        // already due.
        let resumeFrom = Self.normalizedEventID(lastAcceptedEventID)
            ?? cursorStore.load(server: server, profile: profile, sessionID: sessionID)
        lastAcceptedEventID = resumeFrom
        if let resumeFrom {
            remember(eventID: resumeFrom, persist: false)
        }
        streamClient.start(url: url, resumeFrom: resumeFrom, onEventWithID: { [weak self] event, eventID in
            guard let self, self.generation == connectionGeneration else { return }

            if case let .sessionSnapshot(snapshot) = event {
                guard Self.normalizedID(snapshot.sessionId ?? snapshot.id) == Self.normalizedID(self.sessionID),
                      let onSnapshot = self.onSnapshot,
                      onSnapshot(snapshot)
                else {
                    // A malformed, wrong-session, or rejected snapshot is not a
                    // recovery boundary. Keep the durable cursor so the next
                    // reconnect can retry the same authoritative state.
                    return
                }

                // A successfully applied snapshot means the server could not honor
                // the prior replay cursor. It is a recovery boundary: discard the
                // stale cursor and all prior dedupe state before the next reconnect.
                self.cursorPersistTask?.cancel()
                self.cursorPersistTask = nil
                self.lastAcceptedEventID = nil
                self.seenEventIDs.removeAll(keepingCapacity: true)
                self.seenEventOrder.removeAll(keepingCapacity: true)

                self.cursorStore.clear(
                    server: self.server,
                    profile: self.profile,
                    sessionID: self.sessionID
                )
                self.cursorStore.clearSeenEventIDs(
                    server: self.server,
                    profile: self.profile,
                    sessionID: self.sessionID
                )
                // Reconnect without Last-Event-ID. A snapshot is the server's
                // explicit signal that incremental replay is no longer safe.
                self.scheduleReconnect(connectionGeneration: connectionGeneration)
            } else {
                if case .transportError = event {
                    // Keep the attempt counter so an older Hermes server that
                    // does not expose session events cannot cause a tight retry
                    // loop. A later view appearance explicitly starts a fresh
                    // capability attempt.
                } else {
                    self.reconnectAttempt = 0
                }
                if Self.shouldAdvanceCursor(for: event),
                   let eventID = Self.normalizedEventID(eventID) {
                    guard !self.seenEventIDs.contains(eventID) else { return }
                    self.lastAcceptedEventID = eventID
                    self.remember(eventID: eventID, persist: false)
                    self.scheduleCursorPersist()
                }
                self.onEvent?(event)
                if Self.requiresReconnect(for: event) {
                    self.scheduleReconnect(connectionGeneration: connectionGeneration)
                }
            }
        })
    }

    private func scheduleReconnect(connectionGeneration: Int) {
        guard reconnectTask == nil, generation == connectionGeneration else { return }
        guard reconnectAttempt < 3 else { return }
        reconnectAttempt += 1
        let delay = UInt64(250_000_000 * (1 << min(reconnectAttempt - 1, 2)))
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, self.generation == connectionGeneration else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    private func remember(eventID: String, persist: Bool) {
        guard !seenEventIDs.contains(eventID) else { return }
        seenEventIDs.insert(eventID)
        seenEventOrder.append(eventID)
        while seenEventOrder.count > 256 {
            let removed = seenEventOrder.removeFirst()
            seenEventIDs.remove(removed)
        }

        if persist {
            cursorStore.saveSeenEventIDs(
                seenEventOrder,
                server: server,
                profile: profile,
                sessionID: sessionID
            )
        }
    }

    private static func normalizedID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private static func requiresReconnect(for event: SSEEvent) -> Bool {
        switch event {
        case .done, .streamEnd, .cancelled, .error, .lostWorkerBookkeeping, .transportError:
            return true
        default:
            return false
        }
    }

    private static func shouldAdvanceCursor(for event: SSEEvent) -> Bool {
        switch event {
        case .ignored:
            // The decoder could not establish a valid event payload. Advancing
            // past its ID would make an authoritative replay permanently skip it.
            return false
        default:
            return true
        }
    }

    private static func normalizedEventID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SessionEventCursorStore {
    private let defaults: UserDefaults
    private let keyPrefix = "semreh.session-events.cursor.v1"
    private let seenKeyPrefix = "semreh.session-events.seen.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(server: URL, profile: String?, sessionID: String) -> String? {
        guard let value = defaults.string(forKey: key(server: server, profile: profile, sessionID: sessionID)) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func save(eventID: String, server: URL, profile: String?, sessionID: String) {
        let trimmed = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: key(server: server, profile: profile, sessionID: sessionID))
    }

    func clear(server: URL, profile: String?, sessionID: String) {
        defaults.removeObject(forKey: key(server: server, profile: profile, sessionID: sessionID))
    }

    func loadSeenEventIDs(server: URL, profile: String?, sessionID: String) -> [String] {
        guard let values = defaults.array(forKey: seenKey(server: server, profile: profile, sessionID: sessionID)) as? [String] else {
            return []
        }
        return values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.suffix(256)
    }

    func saveSeenEventIDs(_ eventIDs: [String], server: URL, profile: String?, sessionID: String) {
        defaults.set(Array(eventIDs.suffix(256)), forKey: seenKey(server: server, profile: profile, sessionID: sessionID))
    }

    func clearSeenEventIDs(server: URL, profile: String?, sessionID: String) {
        defaults.removeObject(forKey: seenKey(server: server, profile: profile, sessionID: sessionID))
    }

    private func seenKey(server: URL, profile: String?, sessionID: String) -> String {
        let serverKey = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let profileKey = profile?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "default"
        let sessionKey = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(seenKeyPrefix).\(serverKey).\(profileKey).\(sessionKey)"
    }

    private func key(server: URL, profile: String?, sessionID: String) -> String {
        let serverKey = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let profileKey = profile?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "default"
        let sessionKey = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(keyPrefix).\(serverKey).\(profileKey).\(sessionKey)"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct OpenChatSessionKey: Hashable {
    let server: String
    let sessionID: String
    let profile: String

    init(server: URL, sessionID: String, profile: String? = nil) {
        self.server = Self.normalizedServer(server)
        self.sessionID = sessionID
        let normalized = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.profile = normalized.isEmpty ? "default" : normalized
    }

    static func normalizedServer(_ server: URL) -> String {
        server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

enum ChatNavigationLifecyclePolicy {
    static var shouldKeepLiveStreamOnDisappear: Bool { true }
}

@MainActor
enum ChatNavigationLifecycle {
    static func applyViewDisappear(to viewModel: ChatViewModel) {
        viewModel.stopListening()
        guard ChatNavigationLifecyclePolicy.shouldKeepLiveStreamOnDisappear else {
            viewModel.cancelStreamReconnectRetry()
            viewModel.suspendStreamForNavigation()
            viewModel.cleanupPollingTasks()
            return
        }
        viewModel.ensureOwnedStreamStatusWatch()
    }
}
