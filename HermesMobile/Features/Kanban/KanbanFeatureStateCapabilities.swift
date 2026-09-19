import Foundation

extension KanbanFeatureState {
    /// Future write slices must use this single seam before exposing any
    /// mutation, Dispatcher, or shared-state action.
    var canUseServerAuthoritativeActions: Bool {
        snapshot != nil && !isOffline && !isRefreshing && !refreshFailed
    }

    var canUseWrites: Bool {
        canUseServerAuthoritativeActions
            && configuration?.readOnly == false
            && boardsResponse?.readOnly == false
            && snapshot?.readOnly == false
            && selectedBoard?.readOnly != true
            && !boardMutationBlocksWrites
    }

    var canAddComments: Bool {
        canUseWrites && !unavailableWriteCapabilities.contains(.comments)
    }

    var canMutateCards: Bool {
        canUseWrites
            && bulkActionPhase == nil
            && Set(KanbanCardEditorState.createStatuses).isSubset(of: Set(configuration?.columns ?? []))
    }

    var canCreateCards: Bool {
        canMutateCards && !unavailableWriteCapabilities.contains(.createCard)
    }

    var canEditCards: Bool {
        canMutateCards && !unavailableWriteCapabilities.contains(.editCard)
    }

    var canUseCardWorkflow: Bool {
        canMutateCards && !unavailableWriteCapabilities.contains(.cardWorkflow)
    }

    var canUseBulkActions: Bool {
        canMutateCards && !unavailableWriteCapabilities.contains(.bulkActions)
    }

    var canManageBoards: Bool {
        canUseWrites
            && bulkActionPhase == nil
            && activeCardMutationIDs.isEmpty
            && dispatchState?.phase.isInFlight != true
            && !unavailableWriteCapabilities.contains(.boardManagement)
    }

    var dispatcherAvailability: KanbanDispatcherAvailability {
        if dispatchState?.phase.isInFlight == true
            || boardMutationBlocksWrites
            || bulkActionPhase != nil
            || !activeCardMutationIDs.isEmpty {
            return .busy
        }
        if isOffline { return .offline }
        if isRefreshing { return .refreshing }
        if refreshFailed { return .refreshFailed }
        if dispatchState?.mode == .run, dispatchState?.phase == .outcomeUncertain {
            return .outcomeUncertain
        }
        guard !dispatcherCapabilityIsIncompatible,
              state == .compatible || state == .partial,
              snapshot != nil,
              selectedBoardSlug != nil else {
            return .incompatible
        }
        if configuration?.readOnly == true
            || boardsResponse?.readOnly == true
            || snapshot?.readOnly == true
            || selectedBoard?.readOnly == true {
            return .readOnly
        }
        guard configuration?.readOnly == false,
              boardsResponse?.readOnly == false,
              snapshot?.readOnly == false else {
            return .incompatible
        }
        return .available
    }

    var isPreviewStale: Bool {
        guard let dispatchState, dispatchState.mode == .preview,
              dispatchState.phase == .succeeded else { return false }
        return dispatchState.boardSlug != selectedBoardSlug
            || dispatchState.boardActivityGeneration != boardActivityGeneration
    }

    var sharedActiveBoardSlug: String? {
        normalizedOptional(boardsResponse?.current)
    }

    var requiresBoardSelection: Bool {
        selectedBoardSlug == nil && !boards.isEmpty
    }

    func canArchiveBoard(_ board: KanbanBoard) -> Bool {
        canManageBoards && normalizedOptional(board.slug) != "default"
    }

    var selectedCardCount: Int { selectedCardIDs.count }

    var bulkActionsAvailability: KanbanBulkActionsAvailability {
        bulkActionsAvailability(for: selectedCardIDs)
    }

    func bulkActionsAvailability(for cardIDs: Set<String>) -> KanbanBulkActionsAvailability {
        if cardIDs.isEmpty { return .noSelection }
        if bulkActionPhase != nil
            || !activeCardMutationIDs.isEmpty
            || dispatchState?.phase.isInFlight == true
            || boardMutationBlocksWrites {
            return .boardBusy
        }
        if isOffline { return .offline }
        if isRefreshing { return .refreshing }
        guard state == .compatible || state == .partial,
              snapshot != nil,
              Set(KanbanCardEditorState.createStatuses).isSubset(of: Set(configuration?.columns ?? [])),
              !unavailableWriteCapabilities.contains(.bulkActions)
        else { return .incompatible }
        guard configuration?.readOnly == false,
              boardsResponse?.readOnly == false,
              snapshot?.readOnly == false,
              selectedBoard?.readOnly != true
        else { return .readOnly }
        let selectedCards = cardIDs.compactMap { selectedCardsByID[$0] ?? cardInSnapshot($0) }
        guard selectedCards.count == cardIDs.count else { return .invalidSelection }
        guard selectedCards.allSatisfy({ $0.status?.isSupported == true }) else { return .unknownStatus }
        return .available
    }

    var canRetryFailedBulkAction: Bool {
        guard let summary = bulkActionSummary, !summary.failedCardIDs.isEmpty else { return false }
        return bulkActionsAvailability(for: summary.failedCardIDs) == .available
            && validate(summary.action)
    }

    func canSubmitBulkAction(_ action: KanbanBulkAction) -> Bool {
        bulkActionsAvailability == .available && validate(action)
    }

    var hasAvailableArchiveUndo: Bool {
        guard let archiveUndo else { return false }
        return archiveUndo.expiresAt > Date()
    }
}
