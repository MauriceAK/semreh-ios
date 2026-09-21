import Foundation

extension KanbanFeatureState {
    func load() async {
        let previouslySelectedBoard = normalizedOptional(selectedBoardSlug)
        let previouslySelectedBoardName = selectedBoard?.name
        let hasSettledSnapshot = snapshot != nil
        let previousRefreshFailed = refreshFailed
        let previousIsOffline = isOffline
        let previousLiveUpdatesDelayed = liveUpdatesDelayed
        let previousLoadedDetailIsStale = loadedDetailIsStale
        let hadVisibleLiveUpdates = hasSettledSnapshot && isVisible && sceneIsActive

        if hasSettledSnapshot {
            prepareForLoad(preservingSnapshot: true)
            // Reentry owns the settled board until the replacement snapshot is
            // ready. Invalidate any older handshake so its optional reads and
            // stream start cannot publish after this refresh.
            activeLoadID = nil
            isLoading = false
            refreshFailed = previousRefreshFailed
            isOffline = previousIsOffline
            liveUpdatesDelayed = previousLiveUpdatesDelayed
            loadedDetailIsStale = previousLoadedDetailIsStale
            updatePartialState()

            let loadID = UUID()
            activeLoadID = loadID
            await refresh(loadID: loadID)
            guard ownsLoad(loadID) else { return }
            guard !Task.isCancelled else {
                refreshFailed = previousRefreshFailed
                isOffline = previousIsOffline
                liveUpdatesDelayed = previousLiveUpdatesDelayed
                loadedDetailIsStale = previousLoadedDetailIsStale
                resumeLiveUpdatesAfterCancelledLoad(
                    wasVisible: hadVisibleLiveUpdates,
                    wasOffline: previousIsOffline,
                    wasLiveUpdatesDelayed: previousLiveUpdatesDelayed
                )
                return
            }
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
        archiveUndoTask?.cancel()
        archiveUndo = nil
        clearSettledMutationPresentation()
        isRefreshing = false
        resetLiveUpdates(clearCursor: !preservingSnapshot)
    }

    func ownsLoad(_ loadID: UUID?) -> Bool {
        guard let loadID else { return true }
        return activeLoadID == loadID
    }

    func isCurrentLoad(_ loadID: UUID?) -> Bool {
        ownsLoad(loadID) && !Task.isCancelled
    }

    private func resumeLiveUpdatesAfterCancelledLoad(
        wasVisible: Bool,
        wasOffline: Bool,
        wasLiveUpdatesDelayed: Bool
    ) {
        guard wasVisible, snapshot != nil, selectedBoardSlug != nil else { return }
        if wasOffline || wasLiveUpdatesDelayed {
            startPollingIfNeeded()
        } else {
            startLiveUpdatesIfReady()
        }
    }

    private func loadHandshake(
        previouslySelectedBoard: String?,
        previouslySelectedBoardName: String?
    ) async {
        prepareForLoad(preservingSnapshot: false)
        dispatcherCapabilityIsIncompatible = false
        unavailableWriteCapabilities = []
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

    func refresh(loadID: UUID? = nil) async {
        let ownerID = loadID ?? UUID()
        if loadID == nil {
            guard !Task.isCancelled else { return }
            activeLoadID = ownerID
            // A plain refresh supersedes any reentry board request before its
            // own board-list read reaches refreshBoard. Do not let that older
            // response publish through the previous board-load token.
            activeBoardLoadID = UUID()
            isRefreshing = false
        } else {
            guard isCurrentLoad(ownerID) else { return }
        }
        let previousRefreshFailed = refreshFailed
        let previousIsOffline = isOffline
        let previousLiveUpdatesDelayed = liveUpdatesDelayed
        let previousLoadedDetailIsStale = loadedDetailIsStale
        refreshFailed = false
        let expectation = KanbanBoardCollectionExpectation.load(ownerID)
        let boardCollectionSucceeded = await reconcileBoardCollection(expectation: expectation)
        guard ownsLoad(ownerID) else { return }
        guard !Task.isCancelled else {
            refreshFailed = previousRefreshFailed
            isOffline = previousIsOffline
            liveUpdatesDelayed = previousLiveUpdatesDelayed
            loadedDetailIsStale = previousLoadedDetailIsStale
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
            preserveRefreshFailure: !boardCollectionSucceeded,
            resetCapabilitiesOnSuccess: loadID != nil && boardCollectionSucceeded,
            loadID: ownerID
        )
        guard ownsLoad(ownerID) else { return }
        guard !Task.isCancelled else {
            if boardCollectionSucceeded {
                refreshFailed = previousRefreshFailed
            } else {
                reportBoardCollectionRefreshFailure()
            }
            isOffline = previousIsOffline
            liveUpdatesDelayed = previousLiveUpdatesDelayed
            loadedDetailIsStale = previousLoadedDetailIsStale
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
