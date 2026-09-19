import Foundation
import Observation


/// Server-bound, transient Kanban browsing state. Each instance owns one
/// server's Board choice, filters, selection, and snapshots; nothing is shared
/// across servers or persisted by this slice.
@MainActor
@Observable
final class KanbanFeatureState {
    static let liveStatuses = ["triage", "todo", "ready", "running", "blocked", "done"]
    private static let bulkReconciliationConcurrency = 4

    let server: URL
    var state: KanbanCompatibilityState = .idle
    var report: KanbanCompatibilityReport?
    var configuration: KanbanConfiguration?
    var boards: [KanbanBoard] = []
    var snapshot: KanbanBoardSnapshot?
    var stats: KanbanStats?
    var assigneeHistory: KanbanAssigneeHistory?
    var capabilityWarnings: Set<KanbanReadCapabilityWarning> = []
    var unavailableWriteCapabilities: Set<KanbanWriteCapability> = []
    var isLoading = false
    var isRefreshing = false
    var refreshFailed = false
    var isOffline = false
    var liveUpdatesDelayed = false
    var loadedDetailIsStale = false
    var liveCursor = 0
    var detailRefreshRevision = 0
    var cardMutationStates: [String: KanbanCardMutationState] = [:]
    var archiveUndo: KanbanArchiveUndo?
    var isSelectingCards = false
    var selectedCardIDs: Set<String> = []
    var bulkActionPhase: KanbanBulkActionPhase?
    var bulkActionSummary: KanbanBulkActionSummary?
    var boardMutationState: KanbanBoardMutationState?
    var boardSelectionNotice: KanbanBoardSelectionNotice?
    var dispatchState: KanbanDispatchState?
    var dispatcherCapabilityIsIncompatible = false

    var selectedBoardSlug: String?
    var selectedStatus = "triage"
    var searchText = ""
    var selectedProfile: String?
    var selectedTenant: String?
    var includeArchived = false
    var onlyMine = false
    var groupByProfile = false

    var activeLoadID: UUID?
    var activeBoardLoadID: UUID?
    var boardsResponse: KanbanBoardsResponse?
    let client: any KanbanDataClient
    let streamClient: any KanbanEventStreamingClient
    let timing: KanbanLiveUpdateTiming
    let archiveUndoLifetime: TimeInterval
    let sleep: @MainActor @Sendable (Duration) async throws -> Void
    let now: @MainActor @Sendable () -> Date
    let onAPIError: (Error) -> Void
    var isVisible = false
    var sceneIsActive = true
    var liveGeneration = 0
    var streamAttemptID = 0
    var streamFailureCount = 0
    var reconnectTask: Task<Void, Never>?
    var coalescingTask: Task<Void, Never>?
    var pollingTask: Task<Void, Never>?
    var activeCardMutationIDs: [String: UUID] = [:]
    var pendingOptimisticStatuses: [String: String] = [:]
    var settledDetailStatuses: [String: String] = [:]
    var uncertainProtectedCards: [String: KanbanCard] = [:]
    var pendingDependencyChanges: [String: KanbanPendingDependencyChange] = [:]
    var archiveUndoTask: Task<Void, Never>?
    var selectedCardsByID: [String: KanbanCard] = [:]
    var boardMutationIntendedResult: ((KanbanBoardsResponse) -> Bool)?
    var boardMutationGeneration = 0
    var dispatchGeneration = 0
    var boardActivityGeneration = 0

    init(
        server: URL,
        client: (any KanbanDataClient)? = nil,
        streamClient: (any KanbanEventStreamingClient)? = nil,
        timing: KanbanLiveUpdateTiming = .production,
        archiveUndoLifetime: TimeInterval = 8,
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        now: @escaping @MainActor @Sendable () -> Date = { Date() },
        onAPIError: @escaping (Error) -> Void = { _ in }
    ) {
        self.server = server
        self.client = client ?? DirectKanbanDataClient(apiClient: APIClient(baseURL: server))
        self.streamClient = streamClient ?? KanbanEventStreamClient()
        self.timing = timing
        self.archiveUndoLifetime = archiveUndoLifetime
        self.sleep = sleep
        self.now = now
        self.onAPIError = onAPIError
    }
}
