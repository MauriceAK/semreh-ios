import Foundation

extension KanbanFeatureState {
    func loadSupplementaryReads(board: String, loadID: UUID) async {
        do {
            let stats = try await client.kanbanStats(board: board)
            guard isCurrent(loadID), selectedBoardSlug == board else { return }
            self.stats = stats
        } catch {
            guard isCurrent(loadID), selectedBoardSlug == board else { return }
            capabilityWarnings.insert(.statsUnavailable)
            forwardAuthentication(error)
        }

        do {
            let history = try await client.kanbanAssignees(board: board)
            guard isCurrent(loadID), selectedBoardSlug == board else { return }
            assigneeHistory = history
        } catch {
            guard isCurrent(loadID), selectedBoardSlug == board else { return }
            capabilityWarnings.insert(.profileHistoryUnavailable)
            forwardAuthentication(error)
        }
        updatePartialState()
    }

    func loadSupplementaryReads(board: String, boardLoadID: UUID) async {
        do {
            let stats = try await client.kanbanStats(board: board)
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return }
            self.stats = stats
            capabilityWarnings.remove(.statsUnavailable)
        } catch {
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return }
            capabilityWarnings.insert(.statsUnavailable)
            forwardAuthentication(error)
        }

        do {
            let history = try await client.kanbanAssignees(board: board)
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return }
            assigneeHistory = history
            capabilityWarnings.remove(.profileHistoryUnavailable)
        } catch {
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return }
            capabilityWarnings.insert(.profileHistoryUnavailable)
            forwardAuthentication(error)
        }
        updatePartialState()
    }

    func validateBrowsingSnapshot(
        _ snapshot: KanbanBoardSnapshot,
        board: String
    ) throws -> KanbanCompatibilityReport {
        guard let configuration, let boardsResponse else {
            throw KanbanContractViolation.missingConfigurationColumns
        }
        return try KanbanCompatibilityValidator.validate(
            configuration: configuration,
            boardsResponse: boardsResponse,
            boardSlug: board,
            snapshot: snapshot
        )
    }

    func updatePartialState() {
        guard snapshot != nil else { return }
        state = report?.isPartial == true
            || !capabilityWarnings.isEmpty
            || !unavailableWriteCapabilities.isEmpty
            || dispatcherCapabilityIsIncompatible
            ? .partial
            : .compatible
    }

    func markCapabilityUnavailableIfNeeded(
        _ capability: KanbanWriteCapability,
        error: Error
    ) {
        guard KanbanEndpointCompatibility.isMissingCapability(error) else { return }
        markCapabilityUnavailable(capability)
    }

    func markCapabilityUnavailable(_ capability: KanbanWriteCapability) {
        unavailableWriteCapabilities.insert(capability)
        updatePartialState()
    }

    func isCurrent(_ loadID: UUID) -> Bool {
        activeLoadID == loadID && !Task.isCancelled
    }

    func isCurrentBoardLoad(_ loadID: UUID, board: String) -> Bool {
        activeBoardLoadID == loadID && selectedBoardSlug == board && !Task.isCancelled
    }

    func forwardAuthentication(_ error: Error) {
        if case APIError.unauthorized = error { onAPIError(error) }
    }

    static func classify(_ error: Error) -> KanbanCompatibilityState {
        if error as? DirectKanbanError == .pluginUnavailable {
            return .serverUnavailable
        }
        if error is KanbanContractViolation || error is KanbanResponseError {
            return .incompatibleContract
        }
        guard let apiError = error as? APIError else { return .networkUnavailable }
        switch apiError {
        case .unauthorized:
            return .authenticationRequired
        case .network:
            return .networkUnavailable
        case let .http(statusCode, _):
            return [502, 503, 504].contains(statusCode) ? .serverUnavailable : .incompatibleContract
        case .decoding, .invalidServerURL:
            return .incompatibleContract
        }
    }

    func normalized(_ value: String?) -> String? {
        Self.normalized(value)
    }

    func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { normalized($0) }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
