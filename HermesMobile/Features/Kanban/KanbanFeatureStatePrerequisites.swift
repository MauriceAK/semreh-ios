import Foundation

extension KanbanFeatureState {
    func mutatePrerequisite(_ prerequisiteID: String, card: KanbanCard, isAdding: Bool) async {
        guard canMutateCard(card),
              let cardID = normalizedOptional(card.cardID),
              let prerequisiteID = normalizedOptional(prerequisiteID),
              prerequisiteID != cardID,
              activeCardMutationIDs[cardID] == nil,
              let board = selectedBoardSlug else { return }

        let kind: KanbanCardMutationKind = isAdding
            ? .addPrerequisite(prerequisiteID)
            : .removePrerequisite(prerequisiteID)
        let request = KanbanDependencyMutationRequest(
            board: board,
            prerequisiteID: prerequisiteID,
            dependentID: cardID
        )
        let mutationID = UUID()
        markBoardActivity()
        activeCardMutationIDs[cardID] = mutationID
        pendingDependencyChanges[cardID] = KanbanPendingDependencyChange(
            prerequisiteID: prerequisiteID,
            isAdding: isAdding
        )
        cardMutationStates[cardID] = KanbanCardMutationState(kind: kind, phase: .updating)

        do {
            let response = try await (isAdding
                ? client.addKanbanDependency(request)
                : client.removeKanbanDependency(request))
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            try KanbanDependencyMutationValidator.validate(response, request: request)
            cardMutationStates[cardID] = KanbanCardMutationState(kind: kind, phase: .checkingResult)
            await reconcileDependencyMutation(
                request: request,
                shouldExist: isAdding,
                kind: kind,
                mutationID: mutationID
            )
        } catch {
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            forwardAuthentication(error)
            markCapabilityUnavailableIfNeeded(.cardWorkflow, error: error)
            if isDefinitiveWriteFailure(error) {
                pendingDependencyChanges[cardID] = nil
                finishMutation(cardID: cardID, kind: kind, phase: .failed)
            } else {
                cardMutationStates[cardID] = KanbanCardMutationState(kind: kind, phase: .checkingResult)
                await reconcileDependencyMutation(
                    request: request,
                    shouldExist: isAdding,
                    kind: kind,
                    mutationID: mutationID
                )
            }
        }
    }

    private func reconcileDependencyMutation(
        request: KanbanDependencyMutationRequest,
        shouldExist: Bool,
        kind: KanbanCardMutationKind,
        mutationID: UUID
    ) async {
        let cardID = request.dependentID
        do {
            let detail = try await client.kanbanCardDetail(
                KanbanCardDetailRequest(cardID: cardID, board: request.board)
            )
            try KanbanCardDetailValidator.validate(detail, requestedCardID: cardID)
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            let exists = detail.links?.prerequisites?.contains(request.prerequisiteID) == true
            let succeeded = exists == shouldExist
            if !succeeded { pendingDependencyChanges[cardID] = nil }
            finishMutation(cardID: cardID, kind: kind, phase: succeeded ? .succeeded : .failed)
        } catch {
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            forwardAuthentication(error)
            pendingDependencyChanges[cardID] = nil
            finishMutation(
                cardID: cardID,
                kind: kind,
                phase: isNotFound(error) ? .failed : .outcomeUncertain
            )
        }
    }

    func offerArchiveUndo(card: KanbanCard, title: String?, previousStatus: String) {
        guard let cardID = normalizedOptional(card.cardID) else { return }
        archiveUndoTask?.cancel()
        let undo = KanbanArchiveUndo(
            cardID: cardID,
            cardTitle: normalizedOptional(title) ?? cardID,
            previousStatus: previousStatus,
            expiresAt: Date().addingTimeInterval(archiveUndoLifetime),
            card: card
        )
        archiveUndo = undo
        archiveUndoTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.archiveUndoLifetime))
            guard !Task.isCancelled, self.archiveUndo == undo else { return }
            self.archiveUndo = nil
        }
    }

    func recoveryUndo(from undo: KanbanArchiveUndo, card: KanbanCard) -> KanbanArchiveUndo {
        KanbanArchiveUndo(
            cardID: undo.cardID,
            cardTitle: undo.cardTitle,
            previousStatus: undo.previousStatus,
            expiresAt: .distantFuture,
            card: card
        )
    }

    func restoreFailedOptimisticMutation(
        cardID: String,
        baseline: KanbanCard,
        kind: KanbanCardMutationKind,
        phase: KanbanCardMutationPhase
    ) {
        pendingOptimisticStatuses[cardID] = nil
        settledDetailStatuses[cardID] = nil
        uncertainProtectedCards[cardID] = phase == .outcomeUncertain ? baseline : nil
        replaceCardInSnapshot(baseline)
        finishMutation(cardID: cardID, kind: kind, phase: phase)
    }

    func finishMutation(
        cardID: String,
        kind: KanbanCardMutationKind,
        phase: KanbanCardMutationPhase
    ) {
        activeCardMutationIDs[cardID] = nil
        if phase != .outcomeUncertain { uncertainProtectedCards[cardID] = nil }
        cardMutationStates[cardID] = KanbanCardMutationState(kind: kind, phase: phase)
        detailRefreshRevision &+= 1
    }

    func clearSettledMutationPresentation() {
        let activeCardIDs = Set(activeCardMutationIDs.keys)
        cardMutationStates = cardMutationStates.filter { activeCardIDs.contains($0.key) }
        pendingOptimisticStatuses = pendingOptimisticStatuses.filter { activeCardIDs.contains($0.key) }
        settledDetailStatuses = settledDetailStatuses.filter { activeCardIDs.contains($0.key) }
        pendingDependencyChanges = pendingDependencyChanges.filter { activeCardIDs.contains($0.key) }
        uncertainProtectedCards = uncertainProtectedCards.filter { activeCardIDs.contains($0.key) }
    }
}
