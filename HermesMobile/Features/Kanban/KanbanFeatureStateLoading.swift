import Foundation

extension KanbanFeatureState {
    func load() async {
        let previouslySelectedBoard = normalizedOptional(selectedBoardSlug)
        let previouslySelectedBoardName = selectedBoard?.name
        let hasSettledSnapshot = snapshot != nil

        if hasSettledSnapshot {
            prepareForLoad(preservingSnapshot: true)
            // Reentry owns the settled board until the replacement snapshot is
            // ready. Invalidate any older handshake so its optional reads and
            // stream start cannot publish after this refresh.
            activeLoadID = nil
            isLoading = false
            refreshFailed = false
            capabilityWarnings = []
            state = report?.isPartial == true ? .partial : .compatible

            await refresh()
            guard !Task.isCancelled else { return }
            if previouslySelectedBoard != nil,
               selectedBoardSlug == nil,
               snapshot == nil {
                await loadHandshake(
                    previouslySelectedBoard: previouslySelectedBoard,
                    previouslySelectedBoardName: previouslySelectedBoardName
                )
            } else {
                startLiveUpdatesIfReady()
            }
            return
        }

        await loadHandshake(
            previouslySelectedBoard: previouslySelectedBoard,
            previouslySelectedBoardName: previouslySelectedBoardName
        )
    }

    private func prepareForLoad(preservingSnapshot: Bool) {
        invalidateBoardMutation()
        invalidateDispatch()
        dispatcherCapabilityIsIncompatible = false
        unavailableWriteCapabilities = []
        archiveUndoTask?.cancel()
        archiveUndo = nil
        clearSettledMutationPresentation()
        resetLiveUpdates(clearCursor: !preservingSnapshot)
    }

    private func loadHandshake(
        previouslySelectedBoard: String?,
        previouslySelectedBoardName: String?
    ) async {
        prepareForLoad(preservingSnapshot: false)
        let loadID = UUID()
        activeLoadID = loadID
        activeBoardLoadID = nil
        isLoading = true
        refreshFailed = false
        state = .checking
        report = nil
        configuration = nil
        boards = []
        boardsResponse = nil
        snapshot = nil
        stats = nil
        assigneeHistory = nil
        capabilityWarnings = []
        defer {
            if activeLoadID == loadID {
                isLoading = false
                if Task.isCancelled, snapshot == nil {
                    report = nil
                    state = .idle
                }
            }
        }

        do {
            // Ordered exactly as §17.2 requires; every probe is a verified GET.
            let configuration = try await client.kanbanConfiguration()
            guard isCurrent(loadID) else { return }
            let boardsResponse = try await client.kanbanBoards()
            guard isCurrent(loadID) else { return }
            guard let currentBoard = normalized(boardsResponse.current) else {
                throw KanbanContractViolation.missingCurrentBoard
            }
            let availableBoards = boardsResponse.boards ?? []
            if let previouslySelectedBoard,
               !availableBoards.contains(where: { normalized($0.slug) == previouslySelectedBoard }) {
                let validationSnapshot = try await client.kanbanBoard(
                    KanbanBoardRequest(board: currentBoard)
                )
                guard isCurrent(loadID) else { return }
                let report = try KanbanCompatibilityValidator.validate(
                    configuration: configuration,
                    boardsResponse: boardsResponse,
                    boardSlug: currentBoard,
                    snapshot: validationSnapshot
                )
                guard isCurrent(loadID) else { return }
                self.configuration = configuration
                self.boardsResponse = boardsResponse
                boards = availableBoards
                handleRemovedBoard(previouslySelectedBoardName ?? previouslySelectedBoard)
                self.report = report
                state = report.isPartial ? .partial : .compatible
                return
            }
            let boardToLoad = previouslySelectedBoard ?? currentBoard
            let snapshot = try await client.kanbanBoard(KanbanBoardRequest(board: boardToLoad))
            guard isCurrent(loadID) else { return }

            let report = try KanbanCompatibilityValidator.validate(
                configuration: configuration,
                boardsResponse: boardsResponse,
                snapshot: snapshot
            )
            guard isCurrent(loadID) else { return }
            if selectedBoardSlug != nil, selectedBoardSlug != boardToLoad {
                resetCardSelection()
            }
            self.configuration = configuration
            self.boardsResponse = boardsResponse
            boards = availableBoards
            selectedBoardSlug = boardToLoad
            boardSelectionNotice = nil
            self.snapshot = snapshot
            markBoardActivity()
            detailRefreshRevision &+= 1
            liveCursor = max(0, snapshot.latestEventID ?? 0)
            self.report = report
            state = report.isPartial ? .partial : .compatible

            await loadSupplementaryReads(board: boardToLoad, loadID: loadID)
            guard isCurrent(loadID) else { return }
            startLiveUpdatesIfReady()
        } catch is CancellationError {
            guard activeLoadID == loadID else { return }
            report = nil
            state = .idle
        } catch {
            guard isCurrent(loadID) else { return }
            report = nil
            state = Self.classify(error)
            forwardAuthentication(error)
        }
    }

    func retry() async {
        if snapshot == nil {
            await load()
        } else {
            await refresh()
        }
    }

    func refresh() async {
        let previousRefreshFailed = refreshFailed
        refreshFailed = false
        let boardCollectionSucceeded = await reconcileBoardCollection()
        guard !Task.isCancelled else {
            refreshFailed = previousRefreshFailed
            return
        }
        if !boardCollectionSucceeded {
            reportBoardCollectionRefreshFailure()
        }
        guard let board = selectedBoardSlug else { return }
        let generation = liveGeneration
        let succeeded = await refreshBoard(
            usingCursor: false,
            refreshSupplementary: true,
            preserveRefreshFailure: !boardCollectionSucceeded
        )
        guard !Task.isCancelled else {
            if boardCollectionSucceeded {
                refreshFailed = previousRefreshFailed
            } else {
                reportBoardCollectionRefreshFailure()
            }
            return
        }
        guard isSameLiveGeneration(board: board, generation: generation) else { return }
        if succeeded {
            isOffline = false
            loadedDetailIsStale = false
            retryLiveStream()
        } else if isOffline {
            startPollingIfNeeded()
        }
        if !boardCollectionSucceeded {
            reportBoardCollectionRefreshFailure()
        }
    }

    func selectBoard(_ slug: String) async {
        guard activeCardMutationIDs.isEmpty,
              bulkActionPhase == nil,
              !boardMutationBlocksWrites,
              dispatchState?.phase.isInFlight != true,
              boards.contains(where: { normalized($0.slug) == slug }),
              slug != selectedBoardSlug else { return }
        dispatchState = nil
        clearCardSelection()
        archiveUndoTask?.cancel()
        archiveUndo = nil
        clearSettledMutationPresentation()
        resetLiveUpdates(clearCursor: true)
        selectedBoardSlug = slug
        boardSelectionNotice = nil
        snapshot = nil
        stats = nil
        assigneeHistory = nil
        report = nil
        capabilityWarnings = []
        state = .compatible
        let succeeded = await refreshBoard(usingCursor: false, refreshSupplementary: true)
        if succeeded { startLiveUpdatesIfReady() }
    }
}
