import Foundation

extension KanbanFeatureState {
    func performBoardMutation(
        kind: KanbanBoardMutationKind,
        write: () async throws -> KanbanBoardMutationEnvelope,
        intendedResult: @escaping (KanbanBoardsResponse) -> Bool
    ) async {
        guard canManageBoards else { return }
        markBoardActivity()
        boardMutationGeneration &+= 1
        let mutationGeneration = boardMutationGeneration
        boardMutationIntendedResult = intendedResult
        boardMutationState = KanbanBoardMutationState(kind: kind, phase: .updating)
        var definitiveFailure = false
        do {
            _ = try await write()
        } catch {
            if isCancellation(error) {
                clearBoardMutationIfCurrent(mutationGeneration)
                return
            }
            guard continueBoardMutation(mutationGeneration, kind: kind) else { return }
            forwardAuthentication(error)
            markCapabilityUnavailableIfNeeded(.boardManagement, error: error)
            definitiveFailure = isDefinitiveWriteFailure(error)
        }
        guard continueBoardMutation(mutationGeneration, kind: kind) else {
            clearBoardMutationIfCurrent(mutationGeneration)
            return
        }

        if !definitiveFailure {
            boardMutationState = KanbanBoardMutationState(kind: kind, phase: .checkingResult)
        }
        let response = await fetchBoardCollection(
            expectation: .boardMutation(generation: mutationGeneration)
        )
        guard continueBoardMutation(mutationGeneration, kind: kind) else {
            clearBoardMutationIfCurrent(mutationGeneration)
            return
        }
        if definitiveFailure {
            boardMutationState = KanbanBoardMutationState(kind: kind, phase: .failed)
        } else if let response {
            boardMutationState = KanbanBoardMutationState(
                kind: kind,
                phase: intendedResult(response) ? .succeeded : .failed
            )
        } else {
            boardMutationState = KanbanBoardMutationState(kind: kind, phase: .outcomeUncertain)
        }
    }

    @discardableResult
    func reconcileBoardCollection(
        expectation: KanbanBoardCollectionExpectation? = nil
    ) async -> Bool {
        await fetchBoardCollection(expectation: expectation) != nil
    }

    func fetchBoardCollection(
        expectation: KanbanBoardCollectionExpectation? = nil
    ) async -> KanbanBoardsResponse? {
        guard boardCollectionExpectationIsCurrent(expectation) else { return nil }
        do {
            let response = try await client.kanbanBoards()
            guard boardCollectionExpectationIsCurrent(expectation) else { return nil }
            guard let availableBoards = response.boards,
                  normalizedOptional(response.current) != nil else {
                return nil
            }
            let previousBoards = boards
            boardsResponse = response
            boards = availableBoards
            if let selectedBoardSlug,
               !availableBoards.contains(where: { normalized($0.slug) == selectedBoardSlug }) {
                let previousName = previousBoards
                    .first(where: { normalized($0.slug) == selectedBoardSlug })?
                    .name
                handleRemovedBoard(previousName ?? selectedBoardSlug)
            }
            isOffline = false
            return response
        } catch {
            guard boardCollectionExpectationIsCurrent(expectation) else { return nil }
            markOfflineIfNeeded(error)
            forwardAuthentication(error)
            return nil
        }
    }

    func boardCollectionExpectationIsCurrent(
        _ expectation: KanbanBoardCollectionExpectation?
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        switch expectation {
        case nil:
            return true
        case let .boardMutation(generation):
            return generation == boardMutationGeneration
        case let .dispatch(generation, board, mode):
            return continueDispatch(generation, board: board, mode: mode)
        }
    }

    var boardMutationBlocksWrites: Bool {
        if dispatchState?.mode == .run, dispatchState?.phase.isInFlight == true {
            return true
        }
        guard let phase = boardMutationState?.phase else { return false }
        return phase.isInFlight || phase == .outcomeUncertain
    }

    func markBoardActivity() {
        boardActivityGeneration &+= 1
    }

    @discardableResult
    func refreshBoard(
        usingCursor: Bool,
        refreshSupplementary: Bool = false,
        preserveRefreshFailure: Bool = false
    ) async -> Bool {
        guard let board = selectedBoardSlug else { return false }
        let boardLoadID = UUID()
        activeBoardLoadID = boardLoadID
        isRefreshing = true
        if !preserveRefreshFailure {
            refreshFailed = false
        }
        defer {
            if activeBoardLoadID == boardLoadID { isRefreshing = false }
        }

        let request = KanbanBoardRequest(
            board: board,
            tenant: selectedTenant,
            assignee: selectedProfile,
            includeArchived: includeArchived,
            onlyMine: onlyMine,
            since: usingCursor ? snapshot?.latestEventID : nil
        )
        do {
            let response = try await client.kanbanBoard(request)
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return false }
            if usingCursor, response.changed == false {
                // A cursor refresh may return the minimal unchanged envelope.
            } else {
                let report = try validateBrowsingSnapshot(response, board: board)
                snapshot = applyingPendingOptimism(to: response)
                markBoardActivity()
                detailRefreshRevision &+= 1
                self.report = report
                state = report.isPartial ? .partial : .compatible
            }
            liveCursor = max(liveCursor, response.latestEventID ?? 0)
            isOffline = false
            if preserveRefreshFailure {
                refreshFailed = true
            }
            if refreshSupplementary {
                await loadSupplementaryReads(board: board, boardLoadID: boardLoadID)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return false }
            if isNotFound(error) {
                _ = await reconcileBoardCollection()
                if selectedBoardSlug == nil { return false }
            }
            refreshFailed = true
            markOfflineIfNeeded(error)
            forwardAuthentication(error)
            return false
        }
    }
}
