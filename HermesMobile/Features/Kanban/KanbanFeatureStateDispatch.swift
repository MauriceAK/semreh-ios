import Foundation

extension KanbanFeatureState {
    func previewDispatch() async {
        await performDispatch(mode: .preview)
    }

    func runDispatcher() async {
        await performDispatch(mode: .run)
    }

    func dismissDispatchResult() {
        guard let dispatch = dispatchState,
              !dispatch.phase.isInFlight,
              dispatch.phase != .outcomeUncertain
                || dispatch.canAcknowledgeUncertainOutcome else { return }
        dispatchState = nil
    }

    func refreshUncertainDispatchOutcome() async {
        guard let dispatch = dispatchState,
              dispatch.mode == .run,
              dispatch.phase == .outcomeUncertain,
              selectedBoardSlug == dispatch.boardSlug,
              !isOffline,
              !isRefreshing,
              bulkActionPhase == nil,
              activeCardMutationIDs.isEmpty,
              !boardMutationBlocksWrites else { return }
        dispatchGeneration &+= 1
        let generation = dispatchGeneration
        dispatchState = KanbanDispatchState(
            mode: .run,
            boardSlug: dispatch.boardSlug,
            phase: .reconciling,
            result: dispatch.result,
            completedAt: dispatch.completedAt,
            boardActivityGeneration: boardActivityGeneration
        )
        await reconcileRun(
            board: dispatch.boardSlug,
            generation: generation,
            result: dispatch.result,
            completedAt: dispatch.completedAt ?? now(),
            requestOutcomeIsUncertain: dispatch.result == nil,
            allowsAcknowledgementAfterSuccessfulRefresh: true
        )
    }

    func dismissBoardMutationResult() {
        guard boardMutationState?.phase.isInFlight != true,
              boardMutationState?.phase != .outcomeUncertain else { return }
        boardMutationState = nil
        boardMutationIntendedResult = nil
    }

    func checkBoardMutationResult() async {
        guard let mutation = boardMutationState,
              mutation.phase == .outcomeUncertain,
              let intendedResult = boardMutationIntendedResult else { return }
        boardMutationGeneration &+= 1
        let mutationGeneration = boardMutationGeneration
        boardMutationState = KanbanBoardMutationState(kind: mutation.kind, phase: .checkingResult)
        let response = await fetchBoardCollection(
            expectation: .boardMutation(generation: mutationGeneration)
        )
        guard continueBoardMutation(mutationGeneration, kind: mutation.kind) else {
            clearBoardMutationIfCurrent(mutationGeneration)
            return
        }
        if let response {
            boardMutationState = KanbanBoardMutationState(
                kind: mutation.kind,
                phase: intendedResult(response) ? .succeeded : .failed
            )
        } else {
            boardMutationState = KanbanBoardMutationState(
                kind: mutation.kind,
                phase: .outcomeUncertain
            )
        }
    }

    func createBoard(_ request: KanbanCreateBoardRequest) async {
        guard let slug = normalizedOptional(request.slug),
              let name = normalizedOptional(request.name),
              canManageBoards else { return }
        let normalizedRequest = KanbanCreateBoardRequest(
            slug: slug,
            name: name,
            description: request.description.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: request.icon.trimmingCharacters(in: .whitespacesAndNewlines),
            color: request.color.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        await performBoardMutation(kind: .create(slug: slug)) {
            try await self.client.createKanbanBoard(normalizedRequest)
        } intendedResult: { response in
            response.boards?.contains(where: { self.normalized($0.slug) == slug }) == true
        }
    }

    func editBoard(_ request: KanbanEditBoardRequest) async {
        guard let slug = normalizedOptional(request.slug),
              let name = normalizedOptional(request.name),
              boards.contains(where: { normalized($0.slug) == slug }),
              canManageBoards else { return }
        let normalizedRequest = KanbanEditBoardRequest(
            slug: slug,
            name: name,
            description: request.description.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: request.icon.trimmingCharacters(in: .whitespacesAndNewlines),
            color: request.color.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        await performBoardMutation(kind: .edit(slug: slug)) {
            try await self.client.editKanbanBoard(normalizedRequest)
        } intendedResult: { response in
            guard let board = response.boards?.first(where: { self.normalized($0.slug) == slug }) else {
                return false
            }
            return self.normalizedOptional(board.name) == normalizedRequest.name
                && self.normalizedOptional(board.description) == self.normalizedOptional(normalizedRequest.description)
                && self.normalizedOptional(board.icon) == self.normalizedOptional(normalizedRequest.icon)
                && self.normalizedOptional(board.color) == self.normalizedOptional(normalizedRequest.color)
        }
    }

    func archiveBoard(slug: String) async {
        guard let slug = normalizedOptional(slug),
              slug != "default",
              boards.contains(where: { normalized($0.slug) == slug }),
              canManageBoards else { return }
        await performBoardMutation(kind: .archive(slug: slug)) {
            try await self.client.archiveKanbanBoard(KanbanBoardMutationRequest(slug: slug))
        } intendedResult: { response in
            response.boards?.contains(where: { self.normalized($0.slug) == slug }) != true
        }
    }

    func makeBoardActive(slug: String) async {
        guard let slug = normalizedOptional(slug),
              boards.contains(where: { normalized($0.slug) == slug }),
              canManageBoards else { return }
        await performBoardMutation(kind: .makeActive(slug: slug)) {
            try await self.client.makeKanbanBoardActive(KanbanBoardMutationRequest(slug: slug))
        } intendedResult: { response in
            self.normalized(response.current) == slug
        }
    }

    private func performDispatch(mode: KanbanDispatchMode) async {
        guard dispatcherAvailability == .available,
              let board = selectedBoardSlug else { return }
        if mode == .run {
            markBoardActivity()
        }
        dispatchGeneration &+= 1
        let generation = dispatchGeneration
        let startingBoardActivityGeneration = boardActivityGeneration
        dispatchState = KanbanDispatchState(
            mode: mode,
            boardSlug: board,
            phase: .submitting,
            result: nil,
            completedAt: nil,
            boardActivityGeneration: startingBoardActivityGeneration
        )

        do {
            let result = try await client.dispatchKanban(
                KanbanDispatchRequest(board: board, dryRun: mode == .preview)
            )
            guard continueDispatch(generation, board: board, mode: mode) else { return }
            let completedAt = now()
            if mode == .preview {
                dispatchState = KanbanDispatchState(
                    mode: .preview,
                    boardSlug: board,
                    phase: .succeeded,
                    result: result,
                    completedAt: completedAt,
                    boardActivityGeneration: startingBoardActivityGeneration
                )
                return
            }
            dispatchState = KanbanDispatchState(
                mode: .run,
                boardSlug: board,
                phase: .reconciling,
                result: result,
                completedAt: completedAt,
                boardActivityGeneration: boardActivityGeneration
            )
            await reconcileRun(
                board: board,
                generation: generation,
                result: result,
                completedAt: completedAt,
                requestOutcomeIsUncertain: false
            )
        } catch {
            guard continueDispatch(generation, board: board, mode: mode) else { return }
            if isCancellation(error) {
                clearDispatchIfCurrent(generation)
                return
            }
            forwardAuthentication(error)
            markOfflineIfNeeded(error)
            if isDispatcherIncompatible(error) {
                dispatcherCapabilityIsIncompatible = true
                updatePartialState()
            }
            let completedAt = now()
            if isDefinitiveWriteFailure(error) {
                dispatchState = KanbanDispatchState(
                    mode: mode,
                    boardSlug: board,
                    phase: .refused,
                    result: nil,
                    completedAt: completedAt,
                    boardActivityGeneration: boardActivityGeneration
                )
            } else if mode == .preview {
                dispatchState = KanbanDispatchState(
                    mode: .preview,
                    boardSlug: board,
                    phase: .failed,
                    result: nil,
                    completedAt: completedAt,
                    boardActivityGeneration: startingBoardActivityGeneration
                )
            } else {
                dispatchState = KanbanDispatchState(
                    mode: .run,
                    boardSlug: board,
                    phase: .reconciling,
                    result: nil,
                    completedAt: completedAt,
                    boardActivityGeneration: boardActivityGeneration
                )
                await reconcileRun(
                    board: board,
                    generation: generation,
                    result: nil,
                    completedAt: completedAt,
                    requestOutcomeIsUncertain: true
                )
            }
        }
    }

    private func reconcileRun(
        board: String,
        generation: Int,
        result: KanbanDispatchResult?,
        completedAt: Date,
        requestOutcomeIsUncertain: Bool,
        allowsAcknowledgementAfterSuccessfulRefresh: Bool = false
    ) async {
        guard continueDispatch(generation, board: board, mode: .run) else { return }
        let collectionSucceeded = await reconcileBoardCollection(
            expectation: .dispatch(generation: generation, board: board, mode: .run)
        )
        guard continueDispatch(generation, board: board, mode: .run) else { return }
        guard selectedBoardSlug == board else {
            dispatchState = KanbanDispatchState(
                mode: .run,
                boardSlug: board,
                phase: .boardUnavailable,
                result: result,
                completedAt: completedAt,
                boardActivityGeneration: boardActivityGeneration
            )
            return
        }
        let boardSucceeded = await refreshBoard(usingCursor: false, refreshSupplementary: true)
        guard continueDispatch(generation, board: board, mode: .run) else { return }
        dispatchState = KanbanDispatchState(
            mode: .run,
            boardSlug: board,
            phase: requestOutcomeIsUncertain || !collectionSucceeded || !boardSucceeded
                ? .outcomeUncertain
                : .succeeded,
            result: result,
            completedAt: completedAt,
            boardActivityGeneration: boardActivityGeneration,
            canAcknowledgeUncertainOutcome: requestOutcomeIsUncertain
                && collectionSucceeded
                && boardSucceeded
                && allowsAcknowledgementAfterSuccessfulRefresh
        )
    }

    func continueDispatch(
        _ generation: Int,
        board: String,
        mode: KanbanDispatchMode
    ) -> Bool {
        generation == dispatchGeneration
            && dispatchState?.boardSlug == board
            && dispatchState?.mode == mode
            && !Task.isCancelled
    }

    private func clearDispatchIfCurrent(_ generation: Int) {
        guard generation == dispatchGeneration else { return }
        dispatchState = nil
    }

    func invalidateDispatch() {
        dispatchGeneration &+= 1
        dispatchState = nil
    }

    private func isDispatcherIncompatible(_ error: Error) -> Bool {
        guard case let APIError.http(statusCode, _) = error else { return false }
        return statusCode == 404 || statusCode == 405
    }

    func continueBoardMutation(
        _ generation: Int,
        kind: KanbanBoardMutationKind
    ) -> Bool {
        generation == boardMutationGeneration
            && boardMutationState?.kind == kind
            && !Task.isCancelled
    }

    func clearBoardMutationIfCurrent(_ generation: Int) {
        guard generation == boardMutationGeneration else { return }
        boardMutationState = nil
        boardMutationIntendedResult = nil
    }

    func invalidateBoardMutation() {
        boardMutationGeneration &+= 1
        boardMutationState = nil
        boardMutationIntendedResult = nil
    }

    func reportBoardCollectionRefreshFailure() {
        refreshFailed = !isOffline
    }

    func handleRemovedBoard(_ boardDisplayName: String) {
        markBoardActivity()
        activeBoardLoadID = nil
        isRefreshing = false
        resetLiveUpdates(clearCursor: true)
        resetCardSelection()
        archiveUndoTask?.cancel()
        archiveUndo = nil
        clearSettledMutationPresentation()
        activeCardMutationIDs.removeAll()
        pendingOptimisticStatuses.removeAll()
        pendingDependencyChanges.removeAll()
        uncertainProtectedCards.removeAll()
        bulkActionPhase = nil
        bulkActionSummary = nil
        selectedBoardSlug = nil
        snapshot = nil
        stats = nil
        assigneeHistory = nil
        report = nil
        capabilityWarnings = []
        refreshFailed = false
        boardSelectionNotice = KanbanBoardSelectionNotice(boardName: boardDisplayName)
    }

    func normalizedOptional(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    var searchMatchedCards: [KanbanCard] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allCards }
        return allCards.filter { card in
            [card.cardID, card.title, card.body, card.assignee, card.tenant]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
        }
    }
}
