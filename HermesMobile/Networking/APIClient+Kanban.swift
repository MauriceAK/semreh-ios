import Foundation

protocol KanbanDataClient: Sendable {
    func kanbanConfiguration() async throws -> KanbanConfiguration
    func kanbanBoards() async throws -> KanbanBoardsResponse
    func createKanbanBoard(_ request: KanbanCreateBoardRequest) async throws -> KanbanBoardMutationEnvelope
    func editKanbanBoard(_ request: KanbanEditBoardRequest) async throws -> KanbanBoardMutationEnvelope
    func archiveKanbanBoard(_ request: KanbanBoardMutationRequest) async throws -> KanbanBoardMutationEnvelope
    func makeKanbanBoardActive(_ request: KanbanBoardMutationRequest) async throws -> KanbanBoardMutationEnvelope
    func dispatchKanban(_ request: KanbanDispatchRequest) async throws -> KanbanDispatchResult
    func kanbanBoard(_ request: KanbanBoardRequest) async throws -> KanbanBoardSnapshot
    func kanbanStats(board: String) async throws -> KanbanStats
    func kanbanAssignees(board: String) async throws -> KanbanAssigneeHistory
    func kanbanEvents(_ request: KanbanEventsRequest) async throws -> KanbanEventsEnvelope
    func kanbanCardDetail(_ request: KanbanCardDetailRequest) async throws -> KanbanCardDetailEnvelope
    func kanbanWorkerLog(_ request: KanbanWorkerLogRequest) async throws -> KanbanWorkerLog
    func addKanbanComment(_ request: KanbanAddCommentRequest) async throws -> KanbanAddCommentResponse
    func createKanbanCard(_ request: KanbanCreateCardRequest) async throws -> KanbanCardMutationEnvelope
    func performKanbanBulkAction(_ request: KanbanBulkActionRequest) async throws -> KanbanBulkActionEnvelope
    func editKanbanCard(_ request: KanbanEditCardRequest) async throws -> KanbanCardMutationEnvelope
    func setKanbanCardStatus(_ request: KanbanCardStatusRequest) async throws -> KanbanCardMutationEnvelope
    func blockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope
    func unblockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope
    func addKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope
    func removeKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope
}

extension KanbanDataClient {
    func createKanbanBoard(_ request: KanbanCreateBoardRequest) async throws -> KanbanBoardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.createBoard
    }

    func editKanbanBoard(_ request: KanbanEditBoardRequest) async throws -> KanbanBoardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.editBoard
    }

    func archiveKanbanBoard(_ request: KanbanBoardMutationRequest) async throws -> KanbanBoardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.archiveBoard
    }

    func makeKanbanBoardActive(_ request: KanbanBoardMutationRequest) async throws -> KanbanBoardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.makeBoardActive
    }

    func dispatchKanban(_ request: KanbanDispatchRequest) async throws -> KanbanDispatchResult {
        throw KanbanUnsupportedClientMethod.dispatch
    }

    func kanbanCardDetail(_ request: KanbanCardDetailRequest) async throws -> KanbanCardDetailEnvelope {
        throw KanbanUnsupportedClientMethod.cardDetail
    }

    func kanbanWorkerLog(_ request: KanbanWorkerLogRequest) async throws -> KanbanWorkerLog {
        throw KanbanUnsupportedClientMethod.workerLog
    }

    func addKanbanComment(_ request: KanbanAddCommentRequest) async throws -> KanbanAddCommentResponse {
        throw KanbanUnsupportedClientMethod.addComment
    }

    func createKanbanCard(_ request: KanbanCreateCardRequest) async throws -> KanbanCardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.createCard
    }

    func performKanbanBulkAction(_ request: KanbanBulkActionRequest) async throws -> KanbanBulkActionEnvelope {
        throw KanbanUnsupportedClientMethod.bulkAction
    }

    func editKanbanCard(_ request: KanbanEditCardRequest) async throws -> KanbanCardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.editCard
    }

    func setKanbanCardStatus(_ request: KanbanCardStatusRequest) async throws -> KanbanCardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.cardStatus
    }

    func blockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.blockCard
    }

    func unblockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.unblockCard
    }

    func addKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope {
        throw KanbanUnsupportedClientMethod.addDependency
    }

    func removeKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope {
        throw KanbanUnsupportedClientMethod.removeDependency
    }
}

private enum KanbanUnsupportedClientMethod: Error {
    case createBoard
    case editBoard
    case archiveBoard
    case makeBoardActive
    case dispatch
    case cardDetail
    case workerLog
    case addComment
    case createCard
    case bulkAction
    case editCard
    case cardStatus
    case blockCard
    case unblockCard
    case addDependency
    case removeDependency
}

enum KanbanRequestError: Error, Equatable {
    case runningStatusRequiresDispatcher
}
