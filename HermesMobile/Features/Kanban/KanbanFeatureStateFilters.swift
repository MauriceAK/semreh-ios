import Foundation

extension KanbanFeatureState {
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible {
            startLiveUpdatesIfReady()
        } else {
            suspendLiveUpdates()
        }
    }

    func setSceneActive(_ active: Bool) async {
        guard sceneIsActive != active else { return }
        sceneIsActive = active
        if !active {
            suspendLiveUpdates()
            return
        }
        guard isVisible, snapshot != nil else { return }
        let previousRefreshFailed = refreshFailed
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
        guard isCurrentLiveWork(board: board, generation: generation) else { return }
        if succeeded {
            isOffline = false
            loadedDetailIsStale = false
            retryLiveStream()
        } else {
            startPollingIfNeeded()
        }
        if !boardCollectionSucceeded {
            reportBoardCollectionRefreshFailure()
        }
    }

    func setProfileFilter(_ profile: String?) async {
        selectedProfile = normalized(profile)
        if selectedProfile != nil { onlyMine = false }
        await refreshBoard(usingCursor: false)
    }

    func setTenantFilter(_ tenant: String?) async {
        selectedTenant = normalized(tenant)
        await refreshBoard(usingCursor: false)
    }

    func setIncludeArchived(_ included: Bool) async {
        includeArchived = included
        if !included, selectedStatus == "archived" { selectedStatus = "triage" }
        await refreshBoard(usingCursor: false)
    }

    func setOnlyMine(_ enabled: Bool) async {
        onlyMine = enabled
        if enabled { selectedProfile = nil }
        await refreshBoard(usingCursor: false)
    }

    func applyFilters(profile: String?, tenant: String?, includeArchived: Bool, onlyMine: Bool) async {
        selectedProfile = onlyMine ? nil : normalized(profile)
        selectedTenant = normalized(tenant)
        self.includeArchived = includeArchived
        self.onlyMine = onlyMine
        if !includeArchived, selectedStatus == "archived" { selectedStatus = "triage" }
        await refreshBoard(usingCursor: false)
    }

    func clearFilters() async {
        searchText = ""
        selectedProfile = nil
        selectedTenant = nil
        includeArchived = false
        onlyMine = false
        if selectedStatus == "archived" { selectedStatus = "triage" }
        await refreshBoard(usingCursor: false)
    }

    func beginSelectingCards() {
        guard bulkActionPhase == nil else { return }
        isSelectingCards = true
        bulkActionSummary = nil
    }

    func toggleCardSelection(_ card: KanbanCard) {
        guard isSelectingCards,
              bulkActionPhase == nil,
              let cardID = normalizedOptional(card.cardID) else { return }
        if selectedCardIDs.remove(cardID) != nil {
            selectedCardsByID[cardID] = nil
        } else {
            selectedCardIDs.insert(cardID)
            selectedCardsByID[cardID] = card
        }
    }

    func clearCardSelection() {
        guard bulkActionPhase == nil else { return }
        resetCardSelection()
    }

    func resetCardSelection() {
        isSelectingCards = false
        selectedCardIDs = []
        selectedCardsByID = [:]
        bulkActionSummary = nil
    }

    func dismissBulkActionSummary() {
        bulkActionSummary = nil
    }

    func performBulkAction(_ action: KanbanBulkAction) async {
        await performBulkAction(action, cardIDs: selectedCardIDs)
    }

    func retryFailedBulkAction() async {
        guard canRetryFailedBulkAction,
              let summary = bulkActionSummary else { return }
        let failedIDs = summary.failedCardIDs
        selectedCardIDs = failedIDs
        selectedCardsByID = selectedCardsByID.filter { failedIDs.contains($0.key) }
        await performBulkAction(summary.action, cardIDs: failedIDs)
    }
}
