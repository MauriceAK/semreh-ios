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
    /// Direct branch handoffs carry an already-bound child controller. Keep the
    /// identity-to-key association so a stale/replayed handoff cannot be adopted
    /// under a different server, profile, or durable session ID.
    private var adoptedBranchKeys: [UUID: OpenChatSessionKey] = [:]
    private var gitAvailabilityViewModels: [OpenChatSessionKey: GitWorkspaceAvailabilityViewModel] = [:]
    /// Oldest first. This is deliberately separate from the dictionary so eviction
    /// remains deterministic instead of depending on dictionary iteration order.
    /// Looking up a retained model during view construction touches this list.
    /// Observing that bookkeeping makes the caller invalidate its own body.
    @ObservationIgnored private var accessOrder: [OpenChatSessionKey] = []
    /// List refreshes only invalidate retained history. A visible chat consumes
    /// its own generation, so the list never renders every offscreen transcript.
    @ObservationIgnored private var staleHistoryGeneration: [OpenChatSessionKey: UInt64] = [:]
    @ObservationIgnored private var nextHistoryGeneration: UInt64 = 0
    @ObservationIgnored private var selectedHistoryRefreshes: [OpenChatSessionKey: SelectedHistoryRefresh] = [:]
    private struct SelectedHistoryRefresh {
        let id: UUID
        let generation: UInt64
        let task: Task<Bool, Never>
        var isCancelled = false
    }
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
    @ObservationIgnored private var foregroundRecoveryTask: Task<Error?, Never>?
    @ObservationIgnored private var foregroundRecoveryGeneration: Int?
    private let organizerStore: LocalOrganizerStore

    /// Authentication owns activation. A stale chat cannot reactivate a server
    /// after sign-out or an account switch. New sockets await the old teardown.
    func activateGateway(server: URL?) {
        guard activeGatewayOrigin != server else { return }
        foregroundRecoveryTask?.cancel()
        foregroundRecoveryTask = nil
        foregroundRecoveryGeneration = nil
        activeGatewayOrigin = server
        gatewayGeneration &+= 1
        let previousTeardown = gatewayTeardown
        let previousRuntime = gatewayRuntime
        gatewayRuntime = nil
        let previousModels = Array(viewModels.values)
        viewModels.removeAll()
        canonicalAliases.removeAll()
        adoptedBranchKeys.removeAll()
        gitAvailabilityViewModels.removeAll()
        accessOrder.removeAll()
        selectedHistoryRefreshes.values.forEach { $0.task.cancel() }
        selectedHistoryRefreshes.removeAll()
        staleHistoryGeneration.removeAll()
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

    /// Rebinds the single active gateway after the app becomes foregrounded.
    ///
    /// This is intentionally a store-level trigger rather than a second recovery
    /// loop: the runtime owns socket generations, observer resume hooks, and
    /// reconnect deduplication. A missing runtime is a normal cold-start state;
    /// the first visible direct conversation will create and attach it later.
    /// Errors are returned to the caller and never change authentication state.
    @discardableResult
    func recoverGatewayOnForeground(for server: URL) async -> Error? {
        guard activeGatewayOrigin == server, let runtime = gatewayRuntime else { return nil }
        let generation = gatewayGeneration
        if let foregroundRecoveryTask,
           foregroundRecoveryGeneration == generation {
            return await foregroundRecoveryTask.value
        }

        foregroundRecoveryTask?.cancel()
        let task = Task { @MainActor [weak self, runtime] () -> Error? in
            guard let self,
                  self.activeGatewayOrigin == server,
                  self.gatewayGeneration == generation,
                  self.gatewayRuntime === runtime else { return nil }
            do {
                try Task.checkCancellation()
                // Force a fresh ticket/socket even when the old runtime still
                // reports ready; iOS can suspend a socket without delivering a
                // close callback. HermesServerRuntime deduplicates concurrent
                // reconnects and runs the registered resume barrier.
                try await runtime.reconnect()
                return nil
            } catch {
                // Connectivity failures remain connectivity failures. The
                // auth owner decides whether a structured auth response merits
                // demotion; foreground recovery never logs the user out.
                return error
            }
        }
        foregroundRecoveryTask = task
        foregroundRecoveryGeneration = generation
        let result = await task.value
        if foregroundRecoveryGeneration == generation {
            foregroundRecoveryTask = nil
            foregroundRecoveryGeneration = nil
        }
        return result
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

#if DEBUG
    /// Installs an already-constructed runtime for focused lifecycle tests.
    /// Production code always obtains the runtime through `runtime(for:client:)`.
    func installGatewayRuntimeForTesting(_ runtime: HermesServerRuntime, for server: URL) {
        guard activeGatewayOrigin == server else { return }
        gatewayRuntime = runtime
    }
#endif

    var retainedSessionCountForTesting: Int { viewModels.count }

    init(
        retentionPolicy: OpenChatSessionStoreRetentionPolicy = .production,
        organizerStore: LocalOrganizerStore? = nil
    ) {
        self.retentionPolicy = retentionPolicy
        self.organizerStore = organizerStore ?? LocalOrganizerStore()
    }

    func viewModel(
        session: SessionSummary,
        server: URL,
        showsLiveActivityResponseExcerpts: Bool = false
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
            if let generation = staleHistoryGeneration.removeValue(forKey: key) {
                staleHistoryGeneration[target] = max(staleHistoryGeneration[target] ?? 0, generation)
            }
            if var refresh = selectedHistoryRefreshes[key] {
                refresh.task.cancel()
                refresh.isCancelled = true
                selectedHistoryRefreshes[key] = refresh
            }
            try? organizerStore.transferSessionAssignment(
                from: key.sessionID,
                to: target.sessionID,
                server: server,
                profile: target.profile
            )
            viewModels.removeValue(forKey: key)
            if let git = gitAvailabilityViewModels.removeValue(forKey: key) {
                git.rebindToCanonicalSession(sessionID: target.sessionID, profile: target.profile)
                gitAvailabilityViewModels[target] = git
            }
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
        created.rebindToCanonicalSession(sessionID: key.sessionID, profile: key.profile)
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

    /// Retains an already-bound direct branch without constructing or resuming a
    /// second ChatViewModel. Unlike the legacy `adoptedViewModel` test/import seam,
    /// this path is collision-safe: a different owner at the exact child key is
    /// rejected and neither owner is invalidated or disposed.
    @discardableResult
    func adoptBranch(_ handoff: DirectBranchHandoff) -> ChatViewModel? {
        let originKey = OpenChatSessionKey.normalizedServer(handoff.origin)
        guard let activeGatewayOrigin,
              OpenChatSessionKey.normalizedServer(activeGatewayOrigin) == originKey,
              handoff.viewModel.usesDirectGateway else {
            return nil
        }

        let sessionID = Self.normalizedSessionID(handoff.session)
        guard !sessionID.isEmpty else { return nil }
        let sessionKey = OpenChatSessionKey(
            server: handoff.origin,
            sessionID: sessionID,
            profile: handoff.session.profile
        )
        let handoffKey = OpenChatSessionKey(
            server: handoff.origin,
            sessionID: sessionID,
            profile: handoff.profile
        )
        guard sessionKey == handoffKey else { return nil }
        // The summary and handoff fields are caller data. The child VM must also
        // prove that its still-bound controller owns this exact origin/profile/
        // durable ID; otherwise a stale VM could be retained under a convincing
        // but unrelated handoff.
        guard let actual = handoff.viewModel.directBranchIdentity,
              OpenChatSessionKey.normalizedServer(actual.origin) == originKey,
              actual.profile.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == handoffKey.profile,
              actual.sessionID.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID else {
            return nil
        }

        if let previouslyAdoptedKey = adoptedBranchKeys[handoff.identity], previouslyAdoptedKey != handoffKey {
            return nil
        }
        // A canonical alias at the child key means another conversation already
        // owns that identity. Never redirect a branch into that owner.
        guard canonicalAliases[handoffKey] == nil else { return nil }

        if let existing = viewModels[handoffKey] {
            guard existing === handoff.viewModel else { return nil }
            adoptedBranchKeys[handoff.identity] = handoffKey
            touch(handoffKey)
            return existing
        }

        let child = handoff.viewModel
        let origin = handoff.origin
        let profile = handoff.profile
        child.onDirectCanonicalID = { [weak self, weak child] id in
            guard let self, let child else { return }
            self.rekey(child, server: origin, sessionID: id, profile: profile)
        }
        viewModels[handoffKey] = child
        adoptedBranchKeys[handoff.identity] = handoffKey
        touch(handoffKey)
        trimIdleViewModels(forServer: handoffKey.server)
        noteStreamingStateChanged()
        return handoff.viewModel
    }

    /// Releases a branch whose ownership transfer was rejected. The guard keeps
    /// a VM already retained by this store untouched, so collision handling cannot
    /// dispose an unrelated or previously adopted owner.
    func releaseUnadoptedBranch(_ handoff: DirectBranchHandoff) {
        guard !viewModels.values.contains(where: { $0 === handoff.viewModel }) else { return }
        handoff.viewModel.invalidateDirectConversation()
        Task { await handoff.viewModel.disposeDirectConversation() }
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
        _ = server
        return []
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

    /// A successful list/profile refresh makes only matching retained chats
    /// stale. The next visible owner performs its own canonical load.
    func markRetainedHistoriesStale(for server: URL, profile: String?) {
        let origin = OpenChatSessionKey.normalizedServer(server)
        let normalizedProfile = OpenChatSessionKey.normalizedProfile(profile)
        nextHistoryGeneration &+= 1
        let generation = nextHistoryGeneration
        for (key, model) in viewModels
            where key.server == origin && key.profile == normalizedProfile && model.hasServerBackedSession {
            staleHistoryGeneration[key] = generation
            cancelSelectedHistoryRefresh(for: key)
        }
        // A profile switch cannot leave a prior profile's selected load running.
        for key in Array(selectedHistoryRefreshes.keys)
            where key.server == origin && key.profile != normalizedProfile {
            cancelSelectedHistoryRefresh(for: key)
        }
    }

    /// Called only by the mounted chat. Concurrent appearances share the same
    /// per-conversation work; a newer generation waits for cancellation of an
    /// older load before starting, so its result cannot arrive first.
    @discardableResult
    func refreshStaleHistoryIfNeeded(
        for model: ChatViewModel,
        session: SessionSummary,
        server: URL,
        modelContext: ModelContext? = nil,
        loader: (@MainActor (ChatViewModel, ModelContext?) async -> Bool)? = nil
    ) async -> Bool {
        let requestedKey = OpenChatSessionKey(
            server: server, sessionID: Self.normalizedSessionID(session), profile: session.profile
        )
        let key = canonicalAliases[requestedKey] ?? requestedKey
        guard viewModels[key] === model,
              let generation = staleHistoryGeneration[key],
              model.activeStreamID == nil else { return false }

        if let existing = selectedHistoryRefreshes[key] {
            if existing.generation == generation && !existing.isCancelled {
                let succeeded = await existing.task.value
                guard succeeded, !Task.isCancelled,
                      selectedHistoryRefreshes[key]?.id == existing.id,
                      selectedHistoryRefreshes[key]?.isCancelled == false,
                      staleHistoryGeneration[key] == generation,
                      viewModels[key] === model else { return false }
                staleHistoryGeneration.removeValue(forKey: key)
                return true
            }
            existing.task.cancel()
            _ = await existing.task.value
            if selectedHistoryRefreshes[key]?.id == existing.id {
                selectedHistoryRefreshes.removeValue(forKey: key)
            }
        }
        guard !Task.isCancelled,
              staleHistoryGeneration[key] == generation,
              viewModels[key] === model else { return false }

        let id = UUID()
        let task = Task { @MainActor in
            if let loader {
                return await loader(model, modelContext)
            }
            await model.loadMessages(modelContext: modelContext)
            return !Task.isCancelled && model.lastError == nil && !model.isViewingCachedData
        }
        selectedHistoryRefreshes[key] = SelectedHistoryRefresh(id: id, generation: generation, task: task)
        let succeeded = await task.value
        let wasStillCurrent = selectedHistoryRefreshes[key]?.id == id
            && selectedHistoryRefreshes[key]?.isCancelled == false
        if selectedHistoryRefreshes[key]?.id == id {
            selectedHistoryRefreshes.removeValue(forKey: key)
        }
        guard succeeded, wasStillCurrent, !Task.isCancelled,
              staleHistoryGeneration[key] == generation,
              viewModels[key] === model else { return false }
        staleHistoryGeneration.removeValue(forKey: key)
        return true
    }

    /// Navigation and scene changes cancel the selected work but keep the
    /// history stale for the next appearance.
    func cancelSelectedHistoryRefresh(for model: ChatViewModel) {
        for key in Array(selectedHistoryRefreshes.keys) where viewModels[key] === model {
            cancelSelectedHistoryRefresh(for: key)
        }
    }

    private func cancelSelectedHistoryRefresh(for key: OpenChatSessionKey) {
        guard var refresh = selectedHistoryRefreshes[key] else { return }
        refresh.task.cancel()
        refresh.isCancelled = true
        selectedHistoryRefreshes[key] = refresh
    }

#if DEBUG
    func hasStaleHistoryForTesting(session: SessionSummary, server: URL) -> Bool {
        let requested = OpenChatSessionKey(
            server: server, sessionID: Self.normalizedSessionID(session), profile: session.profile
        )
        return staleHistoryGeneration[canonicalAliases[requested] ?? requested] != nil
    }
#endif

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
        foregroundRecoveryTask?.cancel()
        foregroundRecoveryTask = nil
        foregroundRecoveryGeneration = nil
        deferredRetentionTrimTask?.cancel()
        deferredRetentionTrimTask = nil
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
        viewModels.values.forEach { $0.stopSessionEventSync() }
        gitAvailabilityViewModels.removeAll()
        viewModels.removeAll()
        canonicalAliases.removeAll()
        adoptedBranchKeys.removeAll()
        accessOrder.removeAll()
        selectedHistoryRefreshes.values.forEach { $0.task.cancel() }
        selectedHistoryRefreshes.removeAll()
        staleHistoryGeneration.removeAll()
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
        viewModel.cleanupPollingTasks()
        viewModel.invalidateDirectConversation()
        Task { await viewModel.disposeDirectConversation() }
        let aliases = viewModels.keys.filter { viewModels[$0] === viewModel }
        for alias in aliases {
            selectedHistoryRefreshes[alias]?.task.cancel()
            selectedHistoryRefreshes.removeValue(forKey: alias)
            staleHistoryGeneration.removeValue(forKey: alias)
            viewModels.removeValue(forKey: alias)
            gitAvailabilityViewModels.removeValue(forKey: alias)
        }
        adoptedBranchKeys = adoptedBranchKeys.filter { !aliases.contains($0.value) }
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
        self.profile = Self.normalizedProfile(profile)
    }

    static func normalizedProfile(_ profile: String?) -> String {
        let normalized = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "default" : normalized
    }

    static func normalizedServer(_ server: URL) -> String {
        server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
