import Foundation
import Observation
import SwiftData
import SwiftUI

struct SessionListSection: Identifiable {
    enum Kind: String {
        case pinned
        case today
        case yesterday
        case earlier
    }

    let kind: Kind
    let title: String
    let sessions: [SessionSummary]

    var id: String { kind.rawValue }
}

struct ScheduledSessionGroups: Equatable {
    let ordinary: [SessionSummary]
    let scheduled: [SessionSummary]
    let totalScheduledCount: Int

    static func partition(
        _ candidates: [SessionSummary],
        totalScheduledCount: Int
    ) -> Self {
        Self(
            ordinary: candidates.filter { !$0.isCronSession },
            scheduled: candidates.filter { $0.isCronSession && $0.archived != true },
            totalScheduledCount: totalScheduledCount
        )
    }

    var scheduledPreview: [SessionSummary] {
        Array(scheduled.prefix(5))
    }

    var hasAdditionalScheduledSessions: Bool {
        scheduled.count > scheduledPreview.count
    }

    func showsDisclosure(isSearchActive: Bool) -> Bool {
        totalScheduledCount > 0 && (!isSearchActive || !scheduled.isEmpty)
    }
}

enum ActiveSessionStateRefreshResult: Equatable {
    case unchanged
    case reloaded
    case failed
}

private struct PendingSessionDeletion {
    let sessionsBeforeDeletion: [SessionSummary]
    let archivedCountBeforeDeletion: Int?
    let successfulLoadGenerationAtStart: Int
    var latestCanonicalSessions: [SessionSummary]?
    var latestCanonicalArchivedCount: Int?
}

private enum PendingMetadataField {
    case title(String)
    case pinned(Bool)
    case archived(Bool)
}

private struct PendingMetadataMutation {
    var title: PendingMetadataValue<String>?
    var pinned: PendingMetadataValue<Bool>?
    var archived: PendingMetadataValue<Bool>?
}

private struct PendingMetadataValue<Value> {
    let value: Value
    let revision: Int
}

private struct PendingMetadataKey: Hashable {
    let profile: String
    let sessionID: String
}

private struct SessionMutationRejectedError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct ArchivedCountResponseError: LocalizedError {
    var errorDescription: String? {
        String(localized: "Hermes did not return a valid archived session count.")
    }
}

@MainActor
@Observable
final class SessionListViewModel {
    typealias GatewayRuntimeProvider = @MainActor (APIClient) async throws -> HermesServerRuntime

    private(set) var sessions: [SessionSummary] = []
    private(set) var isLoading = false
    private(set) var isCreatingSession = false
    private(set) var isCreatingProject = false
    private(set) var isLoadingProjects = false
    private(set) var isDeletingProject = false {
        didSet { sidebarRefreshStateChanged() }
    }
    private(set) var isRenamingSession = false {
        didSet { sidebarRefreshStateChanged() }
    }
    private(set) var isRenamingProject = false {
        didSet { sidebarRefreshStateChanged() }
    }
    private(set) var isMovingSession = false {
        didSet { sidebarRefreshStateChanged() }
    }
    private(set) var isViewingCachedData = false
    private(set) var projects: [ProjectSummary] = []
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var cacheErrorMessage: String?
    private(set) var searchErrorMessage: String?
    private(set) var isSearchingRemoteSessions = false
    private(set) var sessionLoadError: Error?
    private(set) var lastError: Error?
    private(set) var activeProfileName: String?
    private(set) var activeProfileDisplayName: String?
    private(set) var activeProfileModel: String?
    private(set) var activeProfileProvider: String?
    private(set) var profileOptions: [ProfileSummary] = []
    private(set) var isSingleProfileMode = false
    private(set) var isLoadingActiveProfile = false
    private(set) var isSwitchingActiveProfile = false {
        didSet { sidebarRefreshStateChanged() }
    }
    private(set) var switchingActiveProfileName: String?
    private(set) var activeProfileErrorMessage: String?
    private(set) var mutatingSessionIDs: Set<String> = [] {
        didSet { sidebarRefreshStateChanged() }
    }
    /// Set when a shared gateway event invalidates the durable sidebar list.
    /// It remains set while an edit or destructive action is in progress so a
    /// refresh cannot replace the user's working rows underneath them.
    private(set) var isSidebarDirty = false
    /// Total archived sessions reported by the last successful list load
    /// (`archived_count`, issue #17). nil until a load succeeds or when an older
    /// server omits the field — the Archived entry stays hidden then.
    private(set) var archivedCount: Int?

    private(set) var remoteContentSearchSessionIDs: [String] = []
    private var activeRemoteSearchQuery: String?
    private var activeRemoteSearchProfile: String?
    private var remoteResolvedRows: [String: SessionSummary] = [:]
    private var orderedRemoteIDs: [String] = []
    private var remoteSearchGeneration = 0

    private let client: APIClient
    private let sessionMutator: SessionMutator
    private let server: URL
    private var loadGeneration = 0
    /// Monotonic generation of the newest successful canonical `/api/sessions`
    /// response. Optimistic rollbacks never overwrite a newer server result.
    private var successfulLoadGeneration = 0
    private var pendingSessionDeletions: [String: PendingSessionDeletion] = [:]
    /// Authoritative metadata received after a PATCH but before a later list
    /// response. It prevents an older overlapping sidebar response from
    /// erasing a confirmed pin/title/archive change.
    private var pendingMetadataMutations: [PendingMetadataKey: PendingMetadataMutation] = [:]
    private var activeProfileEpoch = 0
    private var metadataConfirmationRevision = 0
    private var archivedCountRequestGeneration = 0
    /// Confirmed deletes remain hidden until a later process/session lifecycle;
    /// this prevents an eventually-consistent list response from resurrecting a
    /// row that the delete endpoint already acknowledged.
    private var confirmedSessionDeletionIDs: Set<String> = []
    private var cacheFirstSessionPlaceholder: [SessionSummary]?
    private var sessionsBeforeCacheFirstPlaceholder: [SessionSummary] = []
    private var localDraftSequence: UInt64 = 0
    @ObservationIgnored private let gatewayRuntimeProvider: GatewayRuntimeProvider
    @ObservationIgnored private var observedGatewayRuntime: HermesServerRuntime?
    @ObservationIgnored private var gatewayObserverID: UUID?
    @ObservationIgnored private var gatewayObservationGeneration = 0
    @ObservationIgnored private var gatewayObservationTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarRefreshTask: Task<Void, Never>?
    private var gatewayObservationEnabled = false
    private var sidebarEditing = false
    private var sidebarDestructiveActionPending = false

    init(
        server: URL,
        client: APIClient? = nil,
        gatewayRuntimeProvider: GatewayRuntimeProvider? = nil
    ) {
        self.server = server
        let resolvedClient = client ?? APIClient(baseURL: server)
        self.client = resolvedClient
        self.sessionMutator = SessionMutator(client: resolvedClient)
        self.gatewayRuntimeProvider = gatewayRuntimeProvider ?? { client in
            try await OpenChatSessionStore.shared.runtime(for: server, client: client)
        }

        // Sweep exports leaked by a previous app run (view dismissed while a
        // download was in flight, so the share sheet — and its on-dismiss
        // cleanup — never appeared). `State(initialValue:)` re-runs this init
        // on every parent redraw, so the sweep must be once-per-process (the
        // lazy static below), or it would delete a file an active share sheet
        // is presenting. The first-ever init always precedes the first export,
        // so the single sweep can never race an in-flight export.
        _ = Self.sweepLeakedExportsOnce
    }

    /// Defers invalidation refreshes while the sidebar is editing a row or
    /// preparing a destructive action. The caller should clear this when the
    /// edit UI closes; a dirty list then refreshes on the next safe turn.
    func setSidebarEditing(_ editing: Bool) {
        sidebarEditing = editing
        sidebarRefreshStateChanged()
    }

    func setSidebarDestructiveActionPending(_ pending: Bool) {
        sidebarDestructiveActionPending = pending
        sidebarRefreshStateChanged()
    }

    /// Starts the one observation/connect task for the already-owned shared
    /// runtime. This is intentionally separate from `load`: the sidebar can
    /// paint its cache/list without waiting for gateway setup, while the first
    /// direct gateway event is still observed before any chat is opened.
    func startGatewayObservation() {
        gatewayObservationEnabled = true
        guard gatewayObservationTask == nil else { return }

        if gatewayObserverID == nil {
            gatewayObservationGeneration &+= 1
        }
        let generation = gatewayObservationGeneration
        gatewayObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.establishGatewayObservation(generation: generation)
            if self.gatewayObservationGeneration == generation {
                self.gatewayObservationTask = nil
            }
        }
    }

    /// Removes the shared-runtime observer when the owning sidebar surface is
    /// discarded. Old callbacks are generation-checked and cannot refresh a
    /// replacement account/profile; a later view must explicitly call
    /// `startGatewayObservation()` before it reattaches.
    func invalidateGatewayObservation() {
        gatewayObservationGeneration &+= 1
        gatewayObservationEnabled = false
        loadGeneration &+= 1
        isLoading = false
        gatewayObservationTask?.cancel()
        gatewayObservationTask = nil
        sidebarRefreshTask?.cancel()
        sidebarRefreshTask = nil
        if let gatewayObserverID, let observedGatewayRuntime {
            observedGatewayRuntime.removeObserver(gatewayObserverID)
        }
        gatewayObserverID = nil
        observedGatewayRuntime = nil
        isSidebarDirty = false
    }

    /// Root temp directory holding one UUID subdirectory per export
    /// (see `export(_:format:)`).
    nonisolated static var exportsRootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("session-exports", isDirectory: true)
    }

    /// Lazy static ⇒ runs exactly once per process, on first access.
    nonisolated private static let sweepLeakedExportsOnce: Void = {
        try? FileManager.default.removeItem(at: exportsRootDirectory)
    }()

    var sections: [SessionListSection] {
        let sortedSessions = sessions.sorted { left, right in
            timestamp(for: left) > timestamp(for: right)
        }
        let pinned = sortedSessions.filter { $0.pinned == true }
        let unpinned = sortedSessions.filter { $0.pinned != true }

        let calendar = Calendar.current
        let today = unpinned.filter { session in
            guard let date = date(for: session) else { return false }
            return calendar.isDateInToday(date)
        }
        let yesterday = unpinned.filter { session in
            guard let date = date(for: session) else { return false }
            return calendar.isDateInYesterday(date)
        }
        let earlier = unpinned.filter { session in
            guard let date = date(for: session) else { return true }
            return !calendar.isDateInToday(date) && !calendar.isDateInYesterday(date)
        }

        return [
            SessionListSection(kind: .pinned, title: String(localized: "Pinned"), sessions: pinned),
            SessionListSection(kind: .today, title: String(localized: "Today"), sessions: today),
            SessionListSection(kind: .yesterday, title: String(localized: "Yesterday"), sessions: yesterday),
            SessionListSection(kind: .earlier, title: String(localized: "Earlier"), sessions: earlier)
        ]
        .filter { !$0.sessions.isEmpty }
    }

    func visibleSessions(
        searchText rawSearchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility = .showAll
    ) -> [SessionSummary] {
        let query = Self.normalizedSearchQuery(rawSearchText)
        let baseSessions = sessions.filter { automatedVisibility.shows($0) }
        let projectFilteredSessions = baseSessions.filter { session in
            guard let selectedProjectID else { return true }
            return session.projectId == selectedProjectID
        }
        let localMatches = projectFilteredSessions.filter { session in
            guard !query.isEmpty else { return true }
            return Self.searchableText(for: session).contains(query)
        }
        let sortedLocalMatches = Self.sortedSessions(localMatches)

        guard !query.isEmpty, activeRemoteSearchQuery == query else {
            return sortedLocalMatches
        }

        let localMatchIDs = Set(sortedLocalMatches.compactMap(\.sessionId))
        let sessionsByID = Dictionary(
            projectFilteredSessions.compactMap { session -> (String, SessionSummary)? in
                guard let sessionID = session.sessionId, !sessionID.isEmpty else { return nil }
                return (sessionID, session)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteMatches = orderedRemoteIDs.compactMap { sessionID -> SessionSummary? in
            guard !localMatchIDs.contains(sessionID) else { return nil }
            let candidate = sessionsByID[sessionID] ?? remoteResolvedRows[sessionID]
            guard let candidate,
                  candidate.archived != true,
                  automatedVisibility.shows(candidate),
                  selectedProjectID == nil || candidate.projectId == selectedProjectID,
                  !confirmedSessionDeletionIDs.contains(sessionID),
                  pendingSessionDeletions[sessionID] == nil
            else { return nil }
            return candidate
        }

        // Keep the existing transcript/sidebar ordering contract for remote
        // content matches: the search route determines membership, while the
        // same recency sort used for local matches determines presentation.
        return sortedLocalMatches + Self.sortedSessions(remoteMatches)
    }

    /// True when a search result was resolved from Hermes but is not part of
    /// the canonical sidebar page. Such rows may be opened and have their
    /// metadata changed, but destructive/legacy-only actions stay unavailable.
    func isSearchOnlySession(_ session: SessionSummary) -> Bool {
        guard let sessionID = Self.nonEmpty(session.sessionId) else { return false }
        return remoteResolvedRows[sessionID] != nil
            && !sessions.contains { Self.nonEmpty($0.sessionId) == sessionID }
    }

    func scheduledSessionGroups(
        searchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility = .showAll
    ) -> ScheduledSessionGroups {
        let candidates = visibleSessions(
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedVisibility
        )

        return ScheduledSessionGroups.partition(
            candidates,
            totalScheduledCount: automatedVisibility.showsCron
                ? sessions.filter { $0.isCronSession && $0.archived != true }.count
                : 0
        )
    }

    /// Publishes the saved sidebar before any network await so cold-launch
    /// navigation can restore the last selected chat immediately.
    func prepareInitialCachedSessions(modelContext: ModelContext) {
        _ = renderCachedSessionsBeforeReload(modelContext: modelContext)
    }

    @discardableResult
    func load(modelContext: ModelContext? = nil, animation: Animation? = nil) async -> Bool {
        loadGeneration &+= 1
        let generation = loadGeneration
        let requestedProfile = Self.nonEmpty(activeProfileName) ?? "default"
        let requestedProfileEpoch = activeProfileEpoch
        archivedCountRequestGeneration &+= 1
        let countRequestGeneration = archivedCountRequestGeneration
        let requestRevision = metadataConfirmationRevision
        isLoading = true
        errorMessage = nil
        cacheErrorMessage = nil
        sessionLoadError = nil
        lastError = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
                if isSidebarDirty { sidebarRefreshStateChanged() }
            }
        }

        _ = renderCachedSessionsBeforeReload(modelContext: modelContext)

        do {
            let response = try await client.directSessions(
                profile: requestedProfile,
                limit: 500,
                offset: 0,
                order: .recent
            )
            guard !Task.isCancelled,
                  loadGeneration == generation,
                  activeProfileEpoch == requestedProfileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == requestedProfile
            else { return false }
            let rawSessions = response.sessions
            let canonicalVisibleSessions = rawSessions
                .map { session -> SessionSummary in
                    guard let sessionID = Self.nonEmpty(session.sessionId),
                          let pending = pendingMetadataMutations[
                              PendingMetadataKey(profile: requestedProfile, sessionID: sessionID)
                          ]
                    else { return session }
                    return applyingPendingMetadata(
                        session,
                        pending: pending,
                        newerThan: requestRevision
                    )
                }
                .filter { $0.archived != true && $0.shouldAppearInSessionList }
            for sessionID in pendingSessionDeletions.keys {
                pendingSessionDeletions[sessionID]?.latestCanonicalSessions = canonicalVisibleSessions
                pendingSessionDeletions[sessionID]?.latestCanonicalArchivedCount = archivedCount
            }
            let visibleSessions = sessionsAfterOptimisticDeletions(canonicalVisibleSessions)
            successfulLoadGeneration = generation
            applySessions(visibleSessions, archivedCount: archivedCount, animation: animation)
            for (key, var pending) in Array(pendingMetadataMutations)
                where key.profile == requestedProfile {
                if pending.title?.revision ?? .min <= requestRevision { pending.title = nil }
                if pending.pinned?.revision ?? .min <= requestRevision { pending.pinned = nil }
                if pending.archived?.revision ?? .min <= requestRevision { pending.archived = nil }
                if pending.title == nil, pending.pinned == nil, pending.archived == nil {
                    pendingMetadataMutations.removeValue(forKey: key)
                } else {
                    pendingMetadataMutations[key] = pending
                }
            }
            isViewingCachedData = false
            clearCacheFirstSessionPlaceholder()

            if let modelContext {
                do {
                    try CacheStore.cacheSessions(visibleSessions, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            // The profile-aggregate list is the canonical visible-row load, but
            // its total is not an archive count. Fetch the archive-only total
            // independently so a count failure cannot discard rows that have
            // already been applied above.
            await refreshArchivedCount(
                profile: requestedProfile,
                generation: generation,
                profileEpoch: requestedProfileEpoch,
                requestGeneration: countRequestGeneration
            )

            return true
        } catch {
            guard loadGeneration == generation,
                  activeProfileEpoch == requestedProfileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == requestedProfile
            else { return false }
            guard !isCancellationError(error) else { return false }

            lastError = error
            sessionLoadError = error
            if CacheFallbackPolicy.shouldUseCache(for: error), let modelContext {
                do {
                    let cachedSessions = sessionsAfterOptimisticDeletions(
                        try CacheStore.cachedSessions(serverURL: server, in: modelContext)
                            .filter(\.shouldAppearInSessionList)
                    )
                    if !cachedSessions.isEmpty {
                        sessions = cachedSessions
                        isViewingCachedData = true
                        errorMessage = nil
                        clearCacheFirstSessionPlaceholder()
                    } else {
                        revertCacheFirstSessionPlaceholderIfNeeded()
                        isViewingCachedData = false
                        errorMessage = error.localizedDescription
                    }
                } catch {
                    revertCacheFirstSessionPlaceholderIfNeeded()
                    cacheErrorMessage = error.localizedDescription
                    isViewingCachedData = false
                    errorMessage = lastError?.localizedDescription
                }
            } else {
                revertCacheFirstSessionPlaceholderIfNeeded()
                isViewingCachedData = false
                errorMessage = error.localizedDescription
            }

            return false
        }
    }

    private func refreshArchivedCount(
        profile requestedProfile: String,
        generation: Int,
        profileEpoch: Int,
        requestGeneration: Int
    ) async {
        guard !Task.isCancelled,
              loadGeneration == generation,
              activeProfileEpoch == profileEpoch,
              archivedCountRequestGeneration == requestGeneration,
              (Self.nonEmpty(activeProfileName) ?? "default") == requestedProfile
        else { return }

        do {
            let response = try await client.directSingleProfileSessions(
                profile: requestedProfile,
                limit: 0,
                offset: 0,
                order: .recent,
                archived: .only
            )

            guard !Task.isCancelled,
                  loadGeneration == generation,
                  activeProfileEpoch == profileEpoch,
                  archivedCountRequestGeneration == requestGeneration,
                  (Self.nonEmpty(activeProfileName) ?? "default") == requestedProfile
            else { return }

            guard let total = response.total, total >= 0 else {
                throw ArchivedCountResponseError()
            }

            archivedCount = total
            lastError = nil
            errorMessage = nil
            for sessionID in pendingSessionDeletions.keys {
                pendingSessionDeletions[sessionID]?.latestCanonicalArchivedCount = total
            }
        } catch {
            guard !Task.isCancelled,
                  loadGeneration == generation,
                  activeProfileEpoch == profileEpoch,
                  archivedCountRequestGeneration == requestGeneration,
                  (Self.nonEmpty(activeProfileName) ?? "default") == requestedProfile,
                  !isCancellationError(error)
            else { return }

            // Keep the successful visible-row load successful. This message is
            // deliberately nonblocking: it is only shown by the existing list
            // error surface when no rows are available, and never triggers the
            // cache fallback/retry path for a count-only failure.
            lastError = error
            errorMessage = CacheFallbackPolicy.sendBannerMessage(for: error)
        }
    }

    /// Refreshes only the archive total after an archive mutation. The
    /// operation is scoped to the currently selected profile and cannot
    /// publish after a newer load, profile switch, or cancellation.
    func refreshArchivedCountForProfile(_ profile: String) async {
        let requestedProfile = Self.nonEmpty(profile) ?? "default"
        guard !isViewingCachedData,
              requestedProfile == (Self.nonEmpty(activeProfileName) ?? "default")
        else { return }

        archivedCountRequestGeneration &+= 1
        let requestGeneration = archivedCountRequestGeneration
        let generation = loadGeneration
        let profileEpoch = activeProfileEpoch
        await refreshArchivedCount(
            profile: requestedProfile,
            generation: generation,
            profileEpoch: profileEpoch,
            requestGeneration: requestGeneration
        )
    }

    /// Paints the last known sidebar immediately on a cold launch while the live
    /// `/api/sessions` reconcile is in flight. This is an optimistic placeholder,
    /// not offline mode: `isViewingCachedData` stays false unless the request fails.
    private func renderCachedSessionsBeforeReload(modelContext: ModelContext?) -> Bool {
        guard sessions.isEmpty, let modelContext else { return false }

        do {
            let cachedSessions = sessionsAfterOptimisticDeletions(
                try CacheStore.cachedSessions(serverURL: server, in: modelContext)
                    .filter(\.shouldAppearInSessionList)
            )
            guard !cachedSessions.isEmpty else { return false }
            sessionsBeforeCacheFirstPlaceholder = sessions
            let placeholder = Self.sortedSessions(cachedSessions)
            sessions = placeholder
            cacheFirstSessionPlaceholder = placeholder
            return true
        } catch {
            // Cache corruption or migration failure must never delay the live request.
            cacheErrorMessage = error.localizedDescription
            return false
        }
    }

    private func revertCacheFirstSessionPlaceholderIfNeeded() {
        defer { clearCacheFirstSessionPlaceholder() }
        guard let cacheFirstSessionPlaceholder,
              sessions == cacheFirstSessionPlaceholder
        else { return }

        sessions = sessionsBeforeCacheFirstPlaceholder
    }

    private func clearCacheFirstSessionPlaceholder() {
        cacheFirstSessionPlaceholder = nil
        sessionsBeforeCacheFirstPlaceholder = []
    }

    private var sidebarRefreshBlocked: Bool {
        sidebarEditing || sidebarDestructiveActionPending
            || isDeletingProject || isRenamingSession || isRenamingProject
            || isMovingSession || isSwitchingActiveProfile || !mutatingSessionIDs.isEmpty
    }

    private func sidebarRefreshStateChanged() {
        guard isSidebarDirty, !sidebarRefreshBlocked else { return }
        scheduleSidebarRefresh()
    }

    private func establishGatewayObservation(generation: Int) async {
        guard gatewayObservationEnabled, generation == gatewayObservationGeneration else { return }

        let runtime: HermesServerRuntime
        if let observedGatewayRuntime, gatewayObserverID != nil {
            runtime = observedGatewayRuntime
        } else {
            guard let resolved = try? await gatewayRuntimeProvider(client),
                  gatewayObservationEnabled,
                  generation == gatewayObservationGeneration,
                  resolved.origin == server
            else { return }

            runtime = resolved
            observedGatewayRuntime = runtime
            gatewayObserverID = runtime.observe(event: { [weak self] event in
                guard let self, self.gatewayObservationGeneration == generation else { return }
                self.receiveGatewayEvent(event)
            }, recover: { _ in }, ready: { [weak self] in
                guard let self, self.gatewayObservationEnabled,
                      self.gatewayObservationGeneration == generation else { return }
                self.isSidebarDirty = true
                self.scheduleSidebarRefresh()
            })
        }

        do {
            try await runtime.connect()
            guard gatewayObservationEnabled, generation == gatewayObservationGeneration else { return }
        } catch {
            guard gatewayObservationEnabled, generation == gatewayObservationGeneration else { return }
            // The shared runtime owns reconnect policy. Keep the observer so a
            // later explicit start can retry connection without another socket.
        }
    }

    private func receiveGatewayEvent(_ event: HermesGatewayEvent) {
        guard event.method == "event", event.type == "sessions.changed" else { return }
        isSidebarDirty = true
        scheduleSidebarRefresh()
    }

    private func scheduleSidebarRefresh() {
        guard isSidebarDirty, !sidebarRefreshBlocked else { return }
        sidebarRefreshTask?.cancel()
        let observationGeneration = gatewayObservationGeneration
        sidebarRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self,
                      self.gatewayObservationGeneration == observationGeneration,
                      self.isSidebarDirty,
                      !self.sidebarRefreshBlocked,
                      !self.isLoading
                else { return }

                self.sidebarRefreshTask = nil
                self.isSidebarDirty = false
                let refreshed = await self.load()
                guard self.gatewayObservationEnabled,
                      self.gatewayObservationGeneration == observationGeneration
                else { return }
                if !refreshed {
                    self.isSidebarDirty = true
                }
            } catch {
                // Cancellation is the normal debounce path. A failed refresh
                // leaves the dirty bit set for the next safe transition/event.
                if let self, !Task.isCancelled {
                    self.sidebarRefreshTask = nil
                    self.isSidebarDirty = true
                }
            }
        }
    }

    func loadActiveProfile() async {
        guard !isLoadingActiveProfile else { return }

        isLoadingActiveProfile = true
        activeProfileErrorMessage = nil
        defer { isLoadingActiveProfile = false }

        do {
            let response = try await client.directProfiles()
            // Resolve the local selection after the await: a user may have
            // switched profiles while this inventory request was pending.
            let scoped = ProfilesResponse(profiles: response.profiles,
                                          active: locallySelectedProfileName ?? response.active,
                                          singleProfileMode: response.singleProfileMode)
            applyActiveProfile(scoped)
        } catch {
            guard !isCancellationError(error) else { return }

            activeProfileErrorMessage = error.localizedDescription
        }
    }

    private var locallySelectedProfileName: String?

    func switchActiveProfile(_ profile: ProfileSummary) async -> Bool {
        guard !isViewingCachedData else {
            activeProfileErrorMessage = String(localized: "Reconnect to the server to change profiles.")
            return false
        }

        guard let profileName = Self.nonEmpty(profile.name) else {
            activeProfileErrorMessage = String(localized: "The server did not provide a profile name.")
            return false
        }

        locallySelectedProfileName = profileName
        guard profileName != activeProfileName else {
            return true
        }

        isSwitchingActiveProfile = true
        switchingActiveProfileName = profileName
        activeProfileErrorMessage = nil
        lastError = nil
        defer {
            isSwitchingActiveProfile = false
            switchingActiveProfileName = nil
        }

        // Profile selection is local UI state. The direct sidebar request
        // carries this profile explicitly; switching must not mutate a global
        // server/WebUI profile or issue a legacy `/api/profile/switch` call.
        let profileResponse = ProfilesResponse(
            profiles: profileOptions,
            active: profileName,
            singleProfileMode: isSingleProfileMode
        )
        applyActiveProfile(
            profileResponse,
            fallbackProfile: profile,
            fallbackDefaultModel: profile.model
        )
        return true
    }

    func searchSessions(
        query rawQuery: String,
        content: Bool = true,
        depth: Int = 5,
        debounceNanoseconds: UInt64 = 350_000_000
    ) async {
        let query = Self.normalizedSearchQuery(rawQuery)
        let profile = Self.nonEmpty(activeProfileName) ?? "default"
        remoteSearchGeneration &+= 1
        let generation = remoteSearchGeneration
        activeRemoteSearchQuery = query
        activeRemoteSearchProfile = profile
        remoteContentSearchSessionIDs = []
        orderedRemoteIDs = []
        remoteResolvedRows = [:]
        searchErrorMessage = nil
        defer {
            if remoteSearchGeneration == generation {
                isSearchingRemoteSessions = false
            }
        }

        guard !query.isEmpty, !isViewingCachedData else {
            isSearchingRemoteSessions = false
            return
        }

        do {
            if debounceNanoseconds > 0 {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            }

            guard !Task.isCancelled,
                  remoteSearchGeneration == generation,
                  activeRemoteSearchQuery == query,
                  activeRemoteSearchProfile == profile,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile
            else { return }

            isSearchingRemoteSessions = true
            // The verified stock search route has no content/depth query
            // flags. `content` remains source-compatible for existing callers;
            // it controls which returned match kinds are admitted below.
            _ = depth
            let response = try await client.directSearchSessions(
                query: query,
                profile: profile,
                limit: 20
            )

            guard !Task.isCancelled,
                  remoteSearchGeneration == generation,
                  activeRemoteSearchQuery == query,
                  activeRemoteSearchProfile == profile,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile
            else { return }

            let candidateIDs = remoteSearchIDs(
                from: response.results ?? [],
                content: content
            )
            var resolvedRows: [String: SessionSummary] = [:]
            var acceptedIDs: [String] = []
            var fatalResolutionError: Error?
            let knownIDs = Set(sessions.compactMap { session -> String? in
                guard session.archived != true,
                      (Self.nonEmpty(session.profile) ?? "default") == profile,
                      let sessionID = Self.nonEmpty(session.sessionId)
                else { return nil }
                return sessionID
            })

            for sessionID in candidateIDs {
                guard !Task.isCancelled,
                      remoteSearchGeneration == generation,
                      activeRemoteSearchQuery == query,
                      activeRemoteSearchProfile == profile,
                      (Self.nonEmpty(activeProfileName) ?? "default") == profile
                else { return }
                guard !confirmedSessionDeletionIDs.contains(sessionID),
                      pendingSessionDeletions[sessionID] == nil
                else { continue }

                if knownIDs.contains(sessionID) {
                    acceptedIDs.append(sessionID)
                    continue
                }

                do {
                    let resolved = try await client.directSessionDetail(
                        sessionID: sessionID,
                        profile: profile
                    )
                    guard resolved.sessionId == sessionID,
                          (Self.nonEmpty(resolved.profile) ?? profile) == profile,
                          resolved.archived == false
                    else { continue }
                    resolvedRows[sessionID] = resolved
                    acceptedIDs.append(sessionID)
                } catch {
                    if Self.isSearchResolutionAuthFailure(error) {
                        throw error
                    }
                    if !Self.isSearchResolutionMiss(error) {
                        fatalResolutionError = error
                        break
                    }
                }
            }

            guard !Task.isCancelled,
                  remoteSearchGeneration == generation,
                  activeRemoteSearchQuery == query,
                  activeRemoteSearchProfile == profile,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile
            else { return }

            orderedRemoteIDs = acceptedIDs
            remoteContentSearchSessionIDs = acceptedIDs
            remoteResolvedRows = resolvedRows
            isSearchingRemoteSessions = false
            if let fatalResolutionError {
                lastError = fatalResolutionError
                searchErrorMessage = fatalResolutionError.localizedDescription
            }
        } catch {
            guard remoteSearchGeneration == generation,
                  activeRemoteSearchQuery == query,
                  activeRemoteSearchProfile == profile,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile
            else { return }

            isSearchingRemoteSessions = false
            guard !isCancellationError(error) else { return }

            remoteContentSearchSessionIDs = []
            orderedRemoteIDs = []
            remoteResolvedRows = [:]
            searchErrorMessage = error.localizedDescription
            lastError = error
        }
    }

    func clearSearchResults() {
        remoteSearchGeneration &+= 1
        activeRemoteSearchQuery = nil
        activeRemoteSearchProfile = nil
        remoteContentSearchSessionIDs = []
        orderedRemoteIDs = []
        remoteResolvedRows = [:]
        searchErrorMessage = nil
        isSearchingRemoteSessions = false
    }

    private var loadFailureRefreshResult: ActiveSessionStateRefreshResult {
        lastError == nil ? .unchanged : .failed
    }

    @discardableResult
    func refreshActiveSessionStatesIfNeeded(
        streamIDs rawStreamIDs: [String],
        modelContext: ModelContext? = nil
    ) async -> ActiveSessionStateRefreshResult {
        guard !isViewingCachedData, !isLoading else { return .unchanged }

        let streamIDs = Self.normalizedStreamIDs(rawStreamIDs)
        guard !streamIDs.isEmpty else {
            return await load(modelContext: modelContext) ? .reloaded : loadFailureRefreshResult
        }

        for streamID in streamIDs {
            do {
                let response = try await client.chatStreamStatus(streamID: streamID)
                guard response.active == false else { continue }
                return await load(modelContext: modelContext) ? .reloaded : loadFailureRefreshResult
            } catch {
                guard !isCancellationError(error) else { return .unchanged }
                if case APIError.unauthorized = error {
                    lastError = error
                    return .failed
                }
                continue
            }
        }

        return .unchanged
    }

    func loadSessionForDeepLink(id rawSessionID: String, modelContext: ModelContext? = nil) async -> SessionSummary? {
        let sessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return nil }
        guard !confirmedSessionDeletionIDs.contains(sessionID),
              pendingSessionDeletions[sessionID] == nil
        else { return nil }

        let requestedProfile = Self.nonEmpty(activeProfileName) ?? "default"
        let generation = loadGeneration
        let requestedServer = server
        let isCurrentRequest: () -> Bool = { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled
                && self.loadGeneration == generation
                && self.server == requestedServer
                && (Self.nonEmpty(self.activeProfileName) ?? "default") == requestedProfile
        }

        if let loadedSession = sessions.first(where: {
            $0.sessionId == sessionID
                && (Self.nonEmpty($0.profile) ?? "default") == requestedProfile
        }) {
            return loadedSession
        }

        actionErrorMessage = nil
        lastError = nil

        if let modelContext {
            do {
                if let cachedSession = try CacheStore.cachedSessions(serverURL: server, in: modelContext)
                    .first(where: {
                        $0.sessionId == sessionID
                            && (Self.nonEmpty($0.profile) ?? "default") == requestedProfile
                    }) {
                    return cachedSession
                }
            } catch {
                cacheErrorMessage = error.localizedDescription
            }
        }

        do {
            let session = try await client.directSessionDetail(
                sessionID: sessionID,
                profile: requestedProfile
            )
            guard isCurrentRequest(),
                  session.sessionId == sessionID,
                  (Self.nonEmpty(session.profile) ?? requestedProfile) == requestedProfile,
                  !confirmedSessionDeletionIDs.contains(sessionID),
                  pendingSessionDeletions[sessionID] == nil
            else { return nil }

            if session.archived != true,
               session.shouldAppearInSessionList,
               !sessions.contains(where: { $0.sessionId == session.sessionId }) {
                sessions.insert(session, at: 0)
            }

            if let modelContext, session.shouldAppearInSessionList {
                do {
                    try CacheStore.cacheSession(session, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            return session
        } catch {
            guard isCurrentRequest() else { return nil }
            guard !isCancellationError(error) else { return nil }
            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func setPinned(
        _ pinned: Bool,
        for session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        await mutateDirectMetadata(
            session,
            modelContext: modelContext,
            animation: animation,
            field: .pinned(pinned)
        ) { [sessionMutator] sessionID, profile in
            try await sessionMutator.setPinned(pinned, sessionID: sessionID, profile: profile)
        }
    }

    func archive(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        let profile = Self.nonEmpty(activeProfileName) ?? "default"
        let profileEpoch = activeProfileEpoch
        let succeeded = await mutateDirectMetadata(
            session,
            modelContext: modelContext,
            animation: animation,
            field: .archived(true)
        ) { [sessionMutator] sessionID, profile in
            try await sessionMutator.archive(sessionID: sessionID, profile: profile)
        }
        guard succeeded, activeProfileEpoch == profileEpoch else { return false }
        await refreshArchivedCountForProfile(profile)
        // A count failure does not undo a confirmed archive. A replaced UI
        // scope must not consume this completion as its own navigation action.
        return !Task.isCancelled && activeProfileEpoch == profileEpoch
    }

    func delete(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to delete a session.")
            return false
        }
        guard !isSearchOnlySession(session) else {
            actionErrorMessage = String(localized: "This search result cannot be deleted yet.")
            return false
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard beginSessionMutation(sessionId) else { return false }
        defer { endSessionMutation(sessionId) }

        actionErrorMessage = nil
        lastError = nil
        let pendingDeletion = PendingSessionDeletion(
            sessionsBeforeDeletion: sessions,
            archivedCountBeforeDeletion: archivedCount,
            successfulLoadGenerationAtStart: successfulLoadGeneration,
            latestCanonicalSessions: nil,
            latestCanonicalArchivedCount: nil
        )
        pendingSessionDeletions[sessionId] = pendingDeletion

        // The destructive confirmation has already happened in the view. Remove
        // the row before the network round trip so the list responds immediately.
        applySessions(
            sessions.filter { Self.nonEmpty($0.sessionId) != sessionId },
            archivedCount: archivedCount,
            animation: animation
        )
        if let modelContext {
            do {
                try CacheStore.deleteSession(sessionID: sessionId, serverURL: server, in: modelContext)
            } catch {
                cacheErrorMessage = error.localizedDescription
            }
        }

        do {
            let response = try await sessionMutator.delete(sessionID: sessionId)
            if response.ok == false {
                throw SessionMutationRejectedError(
                    message: Self.nonEmpty(response.error)
                        ?? String(localized: "The server did not delete the session.")
                )
            }

            // Keep the tombstone active while the follow-up list load runs so an
            // eventually-consistent response cannot resurrect the acknowledged row.
            confirmedSessionDeletionIDs.insert(sessionId)
            _ = await load(modelContext: modelContext, animation: animation)
            pendingSessionDeletions.removeValue(forKey: sessionId)
            actionErrorMessage = nil
            lastError = nil
            return true
        } catch {
            let wasCancelled = isCancellationError(error)
            rollbackPendingSessionDeletion(sessionId, modelContext: modelContext, animation: animation)
            guard !wasCancelled else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func isMutating(_ session: SessionSummary) -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else { return false }
        return mutatingSessionIDs.contains(sessionId)
    }

    func rename(_ session: SessionSummary, to rawTitle: String, modelContext: ModelContext? = nil) async -> Bool {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to rename a session.")
            return false
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard let title = Self.nonEmpty(rawTitle) else {
            actionErrorMessage = String(localized: "Enter a session title.")
            return false
        }

        isRenamingSession = true
        defer { isRenamingSession = false }
        return await mutateDirectMetadata(
            session,
            modelContext: modelContext,
            animation: nil,
            field: .title(title)
        ) { [sessionMutator] sessionID, profile in
            let response = try await sessionMutator.rename(
                sessionID: sessionID,
                title: title,
                profile: profile
            )
            return response.session ?? session
        }
    }

    func duplicate(_ session: SessionSummary, modelContext: ModelContext? = nil) async -> SessionSummary? {
        guard !isSearchOnlySession(session) else {
            actionErrorMessage = String(localized: "This search result cannot be duplicated yet.")
            return nil
        }
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        guard beginSessionMutation(sessionId) else { return nil }
        defer { endSessionMutation(sessionId) }

        actionErrorMessage = nil
        lastError = nil

        do {
            let result = try await sessionMutator.duplicate(
                sessionID: sessionId,
                title: duplicateTitle(for: session)
            )

            guard let duplicatedSession = result.session else {
                actionErrorMessage = result.errorMessage
                return nil
            }

            await load(modelContext: modelContext)
            if !sessions.contains(where: { $0.sessionId == duplicatedSession.sessionId }) {
                sessions.insert(duplicatedSession, at: 0)

                if let modelContext {
                    do {
                        try CacheStore.cacheSessions(sessions, serverURL: server, in: modelContext)
                    } catch {
                        cacheErrorMessage = error.localizedDescription
                    }
                }
            }
            return duplicatedSession
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Downloads the session transcript (`GET /api/session/export`) and writes
    /// it to a unique temp directory so the share sheet can offer it as a file
    /// with a real filename. Returns the file URL, or nil after surfacing the
    /// failure through the standard action-error alert. The caller owns
    /// cleanup of the returned file's parent directory after sharing.
    func export(_ session: SessionSummary, format: SessionExportFormat) async -> URL? {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to export a session.")
            return nil
        }
        guard !isSearchOnlySession(session) else {
            actionErrorMessage = String(localized: "This search result cannot be exported yet.")
            return nil
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        // Reuses the per-session mutation gate: it disables the row's other
        // actions while the download runs (the "progress state") and blocks a
        // double-tap from firing two exports.
        guard beginSessionMutation(sessionId) else { return nil }
        defer { endSessionMutation(sessionId) }

        actionErrorMessage = nil
        lastError = nil

        do {
            let file = try await client.exportSession(
                id: sessionId,
                format: format,
                fallbackTitle: session.title
            )

            let directory = Self.exportsRootDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let fileURL = directory.appendingPathComponent(file.filename)
            try file.data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            guard !isCancellationError(error) else { return nil }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func loadProjects() async {
        isLoadingProjects = true
        actionErrorMessage = nil
        lastError = nil
        defer { isLoadingProjects = false }

        do {
            let response = try await client.projects()
            projects = response.projects ?? []
        } catch {
            guard !isCancellationError(error) else { return }

            lastError = error
            actionErrorMessage = error.localizedDescription
        }
    }

    func move(_ session: SessionSummary, to projectID: String?, modelContext: ModelContext? = nil) async {
        guard !isSearchOnlySession(session) else {
            actionErrorMessage = String(localized: "This search result cannot be moved yet.")
            return
        }
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return
        }

        guard beginSessionMutation(sessionId) else { return }
        defer { endSessionMutation(sessionId) }

        isMovingSession = true
        defer { isMovingSession = false }

        _ = await mutate(modelContext: modelContext) {
            try await sessionMutator.move(sessionID: sessionId, to: projectID)
        }
    }

    func createProject(
        named rawName: String,
        color: String,
        moving session: SessionSummary,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        guard !isSearchOnlySession(session) else {
            actionErrorMessage = String(localized: "This search result cannot be moved yet.")
            return false
        }
        guard let sessionId = session.sessionId else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isCreatingProject = true
        isMovingSession = true
        defer {
            isCreatingProject = false
            isMovingSession = false
        }

        do {
            let createResponse = try await client.createProject(name: name, color: color)
            guard let project = createResponse.project else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project.")
                return false
            }

            guard let projectID = project.projectId, !projectID.isEmpty else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project ID.")
                return false
            }

            upsertProject(project)
            try await sessionMutator.move(sessionID: sessionId, to: projectID)
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates a new project without moving any session into it.
    ///
    /// Mirrors ``createProject(named:color:moving:modelContext:)`` but skips the
    /// `sessionMutator.move(...)` step, so the Projects sidebar's standalone
    /// "Add project" button can make an empty, unassigned project.
    func createEmptyProject(
        named rawName: String,
        color: String,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isCreatingProject = true
        defer { isCreatingProject = false }

        do {
            let createResponse = try await client.createProject(name: name, color: color)
            guard let project = createResponse.project else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project.")
                return false
            }

            guard let projectID = project.projectId, !projectID.isEmpty else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project ID.")
                return false
            }

            upsertProject(project)
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ project: ProjectSummary, modelContext: ModelContext? = nil) async -> Bool {
        guard let projectID = project.projectId, !projectID.isEmpty else {
            actionErrorMessage = String(localized: "The server did not provide a project ID.")
            return false
        }

        isDeletingProject = true
        actionErrorMessage = nil
        lastError = nil
        defer { isDeletingProject = false }

        do {
            _ = try await client.deleteProject(id: projectID)
            projects.removeAll { $0.projectId == projectID }
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func rename(_ project: ProjectSummary, named rawName: String, color: String?) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        guard let projectID = project.projectId, !projectID.isEmpty else {
            actionErrorMessage = String(localized: "The server did not provide a project ID.")
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isRenamingProject = true
        defer { isRenamingProject = false }

        do {
            let response = try await client.renameProject(id: projectID, name: name, color: color)
            guard let renamedProject = response.project else {
                actionErrorMessage = response.error ?? String(localized: "The server did not return the renamed project.")
                return false
            }

            guard renamedProject.projectId?.isEmpty == false else {
                actionErrorMessage = response.error ?? String(localized: "The server did not return the renamed project ID.")
                return false
            }

            upsertProject(renamedProject)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Opens a local draft. Backend creation is deferred until the first prompt
    /// is submitted, so opening New Chat performs no workspace/session request.
    func createSession(modelContext: ModelContext? = nil, profile: String? = nil) async -> SessionSummary? {
        isCreatingSession = true
        actionErrorMessage = nil
        lastError = nil
        defer { isCreatingSession = false }

        _ = modelContext // Local drafts are deliberately neither cached nor persisted.
        localDraftSequence &+= 1
        let timestamp = Date().timeIntervalSince1970
            + (Double(localDraftSequence) * 0.000001)
        return SessionSummary(
            sessionId: nil,
            title: "New Chat",
            createdAt: timestamp,
            updatedAt: timestamp,
            profile: Self.nonEmpty(profile) ?? Self.nonEmpty(activeProfileName) ?? "default"
        )
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    /// Drops any empty Untitled placeholders still held in memory. Used when
    /// returning from the pending new-chat flow so stale rows cannot flash during
    /// the navigation pop animation.
    func removeEmptySidebarPlaceholders() {
        let filtered = sessions.filter(\.shouldAppearInSessionList)
        guard filtered.count != sessions.count else { return }
        sessions = filtered
    }

    private static func normalizedSearchQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func activeStreamIDs(in sessions: [SessionSummary]) -> [String] {
        normalizedStreamIDs(sessions.compactMap(\.activeStreamId))
    }

    private static func normalizedStreamIDs(_ rawStreamIDs: [String]) -> [String] {
        Array(Set(rawStreamIDs.compactMap(nonEmpty))).sorted()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sortedSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.sorted { left, right in
            if (left.pinned == true) != (right.pinned == true) {
                return left.pinned == true
            }

            return timestamp(for: left) > timestamp(for: right)
        }
    }

    private static func timestamp(for session: SessionSummary) -> Double {
        session.lastMessageAt ?? session.updatedAt ?? session.createdAt ?? 0
    }

    private static func searchableText(for session: SessionSummary) -> String {
        [
            session.title,
            session.workspace,
            session.model,
            session.modelProvider,
            session.profile,
            session.sourceLabel
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    }

    private func sessionsAfterOptimisticDeletions(_ candidates: [SessionSummary]) -> [SessionSummary] {
        let hiddenSessionIDs = Set(pendingSessionDeletions.keys).union(confirmedSessionDeletionIDs)
        guard !hiddenSessionIDs.isEmpty else { return candidates }
        return candidates.filter { session in
            guard let sessionID = Self.nonEmpty(session.sessionId) else { return true }
            return !hiddenSessionIDs.contains(sessionID)
        }
    }

    /// `archivedCount` is applied inside the same transaction as the rows so the
    /// bottom Archived entry inserts/removes with the list mutation animation.
    private func applySessions(
        _ newSessions: [SessionSummary],
        archivedCount newArchivedCount: Int?,
        animation: Animation?
    ) {
        guard let animation else {
            sessions = newSessions
            archivedCount = newArchivedCount
            return
        }

        withAnimation(animation) {
            sessions = newSessions
            archivedCount = newArchivedCount
        }
    }

    private func remoteSearchIDs(
        from results: [DirectHermesSessionSearchResult],
        content: Bool
    ) -> [String] {
        var seenSessionIDs = Set<String>()

        return results.prefix(20).compactMap { result in
            // The stock route uses a null role for direct session-ID hits. A
            // content-disabled caller keeps those exact ID matches but drops
            // FTS message hits; no lineage fallback is safe here.
            guard content || result.role == nil,
                  result.archived != true,
                  let sessionID = Self.nonEmpty(result.sessionID),
                  !seenSessionIDs.contains(sessionID)
            else {
                return nil
            }

            seenSessionIDs.insert(sessionID)
            return sessionID
        }
    }

    private static func isSearchResolutionMiss(_ error: Error) -> Bool {
        if let error = error as? DirectHermesRESTError {
            switch error {
            case .invalidSessionID, .missingCanonicalSessionID, .sessionIDMismatch, .profileMismatch:
                return true
            }
        }
        if case DirectHermesRequestError.http(let statusCode, _) = error {
            return statusCode == 404
        }
        if case APIError.http(let statusCode, _) = error {
            return statusCode == 404
        }
        return false
    }

    private static func isSearchResolutionAuthFailure(_ error: Error) -> Bool {
        if error is DirectHermesAuthError {
            return true
        }
        if case APIError.unauthorized = error {
            return true
        }
        if case DirectHermesRequestError.http(let statusCode, _) = error {
            return statusCode == 401 || statusCode == 403
        }
        return false
    }

    private func timestamp(for session: SessionSummary) -> Double {
        Self.timestamp(for: session)
    }

    private func date(for session: SessionSummary) -> Date? {
        let value = timestamp(for: session)
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private func duplicateTitle(for session: SessionSummary) -> String {
        let baseTitle = Self.nonEmpty(session.title) ?? String(localized: "Untitled Session")
        return String(localized: "\(baseTitle) (copy)")
    }

    private func rollbackPendingSessionDeletion(
        _ sessionID: String,
        modelContext: ModelContext?,
        animation: Animation?
    ) {
        guard let pendingDeletion = pendingSessionDeletions.removeValue(forKey: sessionID) else { return }
        confirmedSessionDeletionIDs.remove(sessionID)

        // Prefer the newest canonical response observed while the delete was
        // pending. It may contain a changed version of the row, and is the only
        // safe source after a refresh advanced successfulLoadGeneration.
        let canonicalSessions: [SessionSummary]
        let canonicalArchivedCount: Int?
        if let latestCanonicalSessions = pendingDeletion.latestCanonicalSessions {
            canonicalSessions = latestCanonicalSessions
            canonicalArchivedCount = pendingDeletion.latestCanonicalArchivedCount
        } else {
            // No refresh overlapped the mutation, so the exact pre-delete
            // snapshot is still the correct rollback source.
            guard successfulLoadGeneration <= pendingDeletion.successfulLoadGenerationAtStart else { return }
            canonicalSessions = pendingDeletion.sessionsBeforeDeletion
            canonicalArchivedCount = pendingDeletion.archivedCountBeforeDeletion
        }

        let hiddenSessionIDs = Set(pendingSessionDeletions.keys).union(confirmedSessionDeletionIDs)
        let restoredSessions = canonicalSessions.filter { session in
            guard let candidateID = Self.nonEmpty(session.sessionId) else { return true }
            return !hiddenSessionIDs.contains(candidateID)
        }
        applySessions(
            restoredSessions,
            archivedCount: canonicalArchivedCount,
            animation: animation
        )

        guard let restoredSession = canonicalSessions.first(where: {
            Self.nonEmpty($0.sessionId) == sessionID
        }), let modelContext else { return }
        do {
            try CacheStore.cacheSession(restoredSession, serverURL: server, in: modelContext)
        } catch {
            cacheErrorMessage = error.localizedDescription
        }
    }

    private func beginSessionMutation(_ sessionId: String) -> Bool {
        mutatingSessionIDs.insert(sessionId).inserted
    }

    private func endSessionMutation(_ sessionId: String) {
        mutatingSessionIDs.remove(sessionId)
    }

    private func upsertProject(_ project: ProjectSummary) {
        guard let projectID = project.projectId, !projectID.isEmpty else { return }

        if let existingIndex = projects.firstIndex(where: { $0.projectId == projectID }) {
            projects[existingIndex] = project
        } else {
            projects.append(project)
        }
    }

    private func applyActiveProfile(
        _ response: ProfilesResponse,
        fallbackProfile: ProfileSummary? = nil,
        fallbackDefaultModel: String? = nil
    ) {
        profileOptions = response.profiles ?? profileOptions

        // Tolerant: only a present field moves the flag, so an older server
        // (or the carried-forward switch-response value) keeps today's behavior.
        if let singleProfileMode = response.singleProfileMode {
            isSingleProfileMode = singleProfileMode
        }

        // Keep the App Intents profile cache fresh so the "New Chat in <Profile>" picker
        // (#339) stays populated when the Shortcuts app resolves it in the background, where
        // a live, authenticated fetch may not be possible, then nudge the system to (re-)index
        // the parameterized App Shortcut (iOS only indexes it once its suggested values exist).
        // A nil `profiles` (field absent/undecoded) is left untouched — tolerant decoding — but
        // an explicit empty list is forwarded so `save([])` can clear a stale picker if the
        // server ever reports none.
        if let profiles = response.profiles {
            let changed = ProfileEntityCache.shared.save(profiles)
            ProfileEntityProvider.refreshAppShortcuts(changed: changed)
        }

        let profileName = response.effectiveDefaultProfileName
        let profile = response.profile(matching: profileName) ?? fallbackProfile

        if activeProfileName != profileName {
            activeProfileEpoch &+= 1
            archivedCountRequestGeneration &+= 1
            archivedCount = nil
            // A response for the previous profile must never repopulate a
            // same-query search after a profile switch.
            remoteSearchGeneration &+= 1
            activeRemoteSearchQuery = nil
            activeRemoteSearchProfile = nil
            remoteContentSearchSessionIDs = []
            orderedRemoteIDs = []
            remoteResolvedRows = [:]
            isSearchingRemoteSessions = false
        }
        activeProfileName = profileName
        activeProfileDisplayName = response.displayName(for: profileName)
            ?? profile?.displayName
        activeProfileModel = Self.nonEmpty(profile?.model) ?? Self.nonEmpty(fallbackDefaultModel)
        activeProfileProvider = Self.nonEmpty(profile?.provider)
    }

    private func mutate(
        modelContext: ModelContext? = nil,
        animation: Animation? = nil,
        _ operation: () async throws -> Void
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        do {
            try await operation()
            return await load(modelContext: modelContext, animation: animation)
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    private func mutateDirectMetadata(
        _ session: SessionSummary,
        modelContext: ModelContext?,
        animation: Animation?,
        field: PendingMetadataField,
        operation: (String, String) async throws -> SessionSummary
    ) async -> Bool {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to modify a session.")
            return false
        }
        guard let rawSessionID = session.sessionId,
              let sessionID = Self.nonEmpty(rawSessionID),
              rawSessionID == sessionID
        else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let activeProfile = Self.nonEmpty(activeProfileName) ?? "default"
        let profileEpoch = activeProfileEpoch
        let sessionProfile = Self.nonEmpty(session.profile) ?? "default"
        guard activeProfile == sessionProfile else {
            actionErrorMessage = String(localized: "Switch to this session's profile to modify it.")
            return false
        }
        let searchOnly = isSearchOnlySession(session)
        let capturedSearchQuery = activeRemoteSearchQuery
        let capturedSearchProfile = activeRemoteSearchProfile
        let capturedSearchGeneration = remoteSearchGeneration
        guard beginSessionMutation(sessionID) else { return false }
        defer { endSessionMutation(sessionID) }

        actionErrorMessage = nil
        lastError = nil
        let capturedServer = server

        do {
            let authoritative = try await operation(sessionID, activeProfile)
            guard isCurrentMetadataScope(
                server: capturedServer,
                profile: activeProfile,
                epoch: profileEpoch
            ),
                  authoritative.sessionId == sessionID,
                  (Self.nonEmpty(authoritative.profile) ?? activeProfile) == activeProfile
            else {
                return false
            }
            if searchOnly,
               !isCurrentRemoteSearchScope(
                   query: capturedSearchQuery,
                   profile: capturedSearchProfile,
                   generation: capturedSearchGeneration
               ) {
                return false
            }

            let base = sessions.first(where: { $0.sessionId == sessionID }) ?? session
            let updated = mergedMetadataSession(base, authoritative: authoritative)
            if searchOnly {
                if updated.archived == true {
                    remoteResolvedRows.removeValue(forKey: sessionID)
                    orderedRemoteIDs.removeAll { $0 == sessionID }
                    remoteContentSearchSessionIDs.removeAll { $0 == sessionID }
                } else {
                    remoteResolvedRows[sessionID] = updated
                }
            } else {
                let pendingKey = PendingMetadataKey(profile: activeProfile, sessionID: sessionID)
                var pending = pendingMetadataMutations[pendingKey]
                    ?? PendingMetadataMutation(title: nil, pinned: nil, archived: nil)
                metadataConfirmationRevision &+= 1
                let revision = metadataConfirmationRevision
                switch field {
                case let .title(title): pending.title = PendingMetadataValue(value: title, revision: revision)
                case let .pinned(pinned): pending.pinned = PendingMetadataValue(value: pinned, revision: revision)
                case let .archived(archived): pending.archived = PendingMetadataValue(value: archived, revision: revision)
                }
                pendingMetadataMutations[pendingKey] = pending
            }
            if updated.archived == true {
                if !searchOnly {
                    applySessions(
                        sessions.filter { $0.sessionId != sessionID },
                        archivedCount: archivedCount,
                        animation: animation
                    )
                }
            } else if let index = sessions.firstIndex(where: { $0.sessionId == sessionID }) {
                var updatedSessions = sessions
                updatedSessions[index] = updated
                applySessions(updatedSessions, archivedCount: archivedCount, animation: animation)
            }

            if let modelContext, !searchOnly {
                do {
                    try CacheStore.cacheSession(updated, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }
            return true
        } catch {
            guard !isCancellationError(error) else { return false }
            guard isCurrentMetadataScope(
                server: capturedServer,
                profile: activeProfile,
                epoch: profileEpoch
            ) else { return false }
            if searchOnly,
               !isCurrentRemoteSearchScope(
                   query: capturedSearchQuery,
                   profile: capturedSearchProfile,
                   generation: capturedSearchGeneration
               ) {
                return false
            }
            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    private func isCurrentMetadataScope(
        server capturedServer: URL,
        profile: String,
        epoch: Int
    ) -> Bool {
        !Task.isCancelled
            && server == capturedServer
            && (Self.nonEmpty(activeProfileName) ?? "default") == profile
            && activeProfileEpoch == epoch
    }

    private func isCurrentRemoteSearchScope(
        query: String?,
        profile: String?,
        generation: Int
    ) -> Bool {
        remoteSearchGeneration == generation
            && activeRemoteSearchQuery == query
            && activeRemoteSearchProfile == profile
            && profile == (Self.nonEmpty(activeProfileName) ?? "default")
    }

    private func applyingPendingMetadata(
        _ session: SessionSummary,
        pending: PendingMetadataMutation,
        newerThan revision: Int
    ) -> SessionSummary {
        SessionSummary(
            sessionId: session.sessionId,
            title: pending.title.flatMap { $0.revision > revision ? $0.value : nil } ?? session.title,
            workspace: session.workspace,
            model: session.model,
            modelProvider: session.modelProvider,
            reasoningEffort: session.reasoningEffort,
            messageCount: session.messageCount,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            lastMessageAt: session.lastMessageAt,
            pinned: pending.pinned.flatMap { $0.revision > revision ? $0.value : nil } ?? session.pinned,
            archived: pending.archived.flatMap { $0.revision > revision ? $0.value : nil } ?? session.archived,
            projectId: session.projectId,
            profile: session.profile,
            inputTokens: session.inputTokens,
            outputTokens: session.outputTokens,
            estimatedCost: session.estimatedCost,
            activeStreamId: session.activeStreamId,
            isStreaming: session.isStreaming,
            isCliSession: session.isCliSession,
            userMessageCount: session.userMessageCount,
            hasPendingUserMessage: session.hasPendingUserMessage,
            pendingStartedAt: session.pendingStartedAt,
            worktreePath: session.worktreePath,
            sourceTag: session.sourceTag,
            rawSource: session.rawSource,
            sessionSource: session.sessionSource,
            sourceLabel: session.sourceLabel,
            parentSessionId: session.parentSessionId,
            relationshipType: session.relationshipType,
            readOnly: session.readOnly,
            isReadOnly: session.isReadOnly,
            matchType: session.matchType
        )
    }

    private func mergedMetadataSession(
        _ local: SessionSummary,
        authoritative: SessionSummary
    ) -> SessionSummary {
        SessionSummary(
            sessionId: local.sessionId ?? authoritative.sessionId,
            title: authoritative.title ?? local.title,
            workspace: authoritative.workspace ?? local.workspace,
            model: authoritative.model ?? local.model,
            modelProvider: authoritative.modelProvider ?? local.modelProvider,
            reasoningEffort: authoritative.reasoningEffort ?? local.reasoningEffort,
            messageCount: authoritative.messageCount ?? local.messageCount,
            createdAt: authoritative.createdAt ?? local.createdAt,
            updatedAt: authoritative.updatedAt ?? local.updatedAt,
            lastMessageAt: authoritative.lastMessageAt ?? local.lastMessageAt,
            pinned: authoritative.pinned ?? local.pinned,
            archived: authoritative.archived ?? local.archived,
            projectId: local.projectId,
            profile: authoritative.profile ?? local.profile,
            inputTokens: authoritative.inputTokens ?? local.inputTokens,
            outputTokens: authoritative.outputTokens ?? local.outputTokens,
            estimatedCost: authoritative.estimatedCost ?? local.estimatedCost,
            activeStreamId: local.activeStreamId,
            isStreaming: local.isStreaming,
            isCliSession: authoritative.isCliSession ?? local.isCliSession,
            userMessageCount: local.userMessageCount,
            hasPendingUserMessage: local.hasPendingUserMessage,
            pendingStartedAt: local.pendingStartedAt,
            worktreePath: local.worktreePath,
            sourceTag: authoritative.sourceTag ?? local.sourceTag,
            rawSource: authoritative.rawSource ?? local.rawSource,
            sessionSource: authoritative.sessionSource ?? local.sessionSource,
            sourceLabel: authoritative.sourceLabel ?? local.sourceLabel,
            parentSessionId: authoritative.parentSessionId ?? local.parentSessionId,
            relationshipType: local.relationshipType,
            readOnly: authoritative.readOnly ?? local.readOnly,
            isReadOnly: authoritative.isReadOnly ?? local.isReadOnly,
            matchType: local.matchType
        )
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        guard let urlError = underlying as? URLError else { return false }
        return urlError.code == .cancelled
    }

}
