import Foundation
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SessionListViewModel {

    typealias GatewayRuntimeProvider = @MainActor (APIClient) async throws -> HermesServerRuntime

    var sessions: [SessionSummary] = []

    var isLoading = false

    var isCreatingSession = false

    var isCreatingProject = false

    var isLoadingProjects = false

    var isDeletingProject = false {
        didSet { sidebarRefreshStateChanged() }
    }

    var isRenamingSession = false {
        didSet { sidebarRefreshStateChanged() }
    }

    var isRenamingProject = false {
        didSet { sidebarRefreshStateChanged() }
    }

    var isMovingSession = false {
        didSet { sidebarRefreshStateChanged() }
    }

    var isViewingCachedData = false

    var projects: [ProjectSummary] = []

    var errorMessage: String?

    var actionErrorMessage: String?

    var cacheErrorMessage: String?

    var cachedSessionPreviews: [CachedSessionPreviewIdentity: CachedSessionPreview] = [:]

    var searchErrorMessage: String?

    var isSearchingRemoteSessions = false

    var sessionLoadError: Error?

    var lastError: Error?

    var activeProfileName: String?

    var activeProfileDisplayName: String?

    var activeProfileModel: String?

    var activeProfileProvider: String?

    var profileOptions: [ProfileSummary] = []

    var isSingleProfileMode = false

    var isLoadingActiveProfile = false

    var isSwitchingActiveProfile = false {
        didSet { sidebarRefreshStateChanged() }
    }

    var switchingActiveProfileName: String?

    var activeProfileErrorMessage: String?

    var mutatingSessionIDs: Set<String> = [] {
        didSet { sidebarRefreshStateChanged() }
    }

    /// Set when a shared gateway event invalidates the durable sidebar list.
    /// It remains set while an edit or destructive action is in progress so a
    /// refresh cannot replace the user's working rows underneath them.
    var isSidebarDirty = false

    /// Total archived sessions reported by the last successful list load
    /// (`archived_count`, issue #17). nil until a load succeeds or when an older
    /// server omits the field — the Archived entry stays hidden then.
    var archivedCount: Int?

    var remoteContentSearchSessionIDs: [String] = []

    var activeRemoteSearchQuery: String?

    var activeRemoteSearchProfile: String?

    var remoteResolvedRows: [String: SessionSummary] = [:]

    var orderedRemoteIDs: [String] = []

    var remoteSearchGeneration = 0

    let client: APIClient

    let sessionMutator: SessionMutator

    let organizerStore: LocalOrganizerStore

    let server: URL

    var loadGeneration = 0

    /// Monotonic generation of the newest successful canonical `/api/sessions`
    /// response. Optimistic rollbacks never overwrite a newer server result.
    var successfulLoadGeneration = 0

    var pendingSessionDeletions: [String: PendingSessionDeletion] = [:]

    /// Authoritative metadata received after a PATCH but before a later list
    /// response. It prevents an older overlapping sidebar response from
    /// erasing a confirmed pin/title/archive change.
    var pendingMetadataMutations: [PendingMetadataKey: PendingMetadataMutation] = [:]

    /// A duplicate may already exist after a dispatched branch loses its ACK,
    /// or after a known child cannot be read back. Never branch that source
    /// again blindly during this view-model lifetime.
    var duplicateOutcomeUnknownKeys: Set<PendingMetadataKey> = []

    /// A lost direct-delete acknowledgement must never trigger or permit a blind
    /// repeat for the same durable session/profile in this view-model lifetime.
    var deleteOutcomeUnknownKeys: Set<PendingMetadataKey> = []

    var activeProfileEpoch = 0

    var activeProfileLoadWaiters: [CheckedContinuation<Void, Never>] = []

    var metadataConfirmationRevision = 0

    var archivedCountRequestGeneration = 0

    /// Confirmed deletes remain hidden until a later process/session lifecycle;
    /// this prevents an eventually-consistent list response from resurrecting a
    /// row that the delete endpoint already acknowledged.
    var confirmedSessionDeletionIDs: Set<String> = []

    var cacheFirstSessionPlaceholder: [SessionSummary]?

    var sessionsBeforeCacheFirstPlaceholder: [SessionSummary] = []

    var localDraftSequence: UInt64 = 0

    @ObservationIgnored let gatewayRuntimeProvider: GatewayRuntimeProvider

    @ObservationIgnored var observedGatewayRuntime: HermesServerRuntime?

    @ObservationIgnored var gatewayObserverID: UUID?

    @ObservationIgnored var gatewayObservationGeneration = 0

    @ObservationIgnored var gatewayObservationTask: Task<Void, Never>?

    @ObservationIgnored var sidebarRefreshTask: Task<Void, Never>?

    var gatewayObservationEnabled = false

    var sidebarEditing = false

    var sidebarDestructiveActionPending = false

    init(
        server: URL,
        client: APIClient? = nil,
        gatewayRuntimeProvider: GatewayRuntimeProvider? = nil,
        organizerStore: LocalOrganizerStore? = nil
    ) {
        self.server = server
        let resolvedClient = client ?? APIClient(baseURL: server)
        self.client = resolvedClient
        self.sessionMutator = SessionMutator(client: resolvedClient)
        self.organizerStore = organizerStore ?? LocalOrganizerStore()
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
}
