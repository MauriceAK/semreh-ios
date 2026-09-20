import Foundation

extension KanbanFeatureState {
    func performStatusMutation(
        _ card: KanbanCard,
        status: String,
        kind: KanbanCardMutationKind,
        confirmingRunningExit: Bool = false,
        write: ((String) async throws -> KanbanCardMutationEnvelope)? = nil
    ) async {
        guard status != "running",
              card.status?.rawValue != "running" || confirmingRunningExit,
              canMutateCard(card),
              let cardID = normalizedOptional(card.cardID),
              activeCardMutationIDs[cardID] == nil,
              let board = selectedBoardSlug else { return }

        let baseline = cardInSnapshot(cardID) ?? card
        uncertainProtectedCards[cardID] = nil
        settledDetailStatuses[cardID] = nil
        let mutationID = UUID()
        activeCardMutationIDs[cardID] = mutationID
        pendingOptimisticStatuses[cardID] = status
        cardMutationStates[cardID] = KanbanCardMutationState(kind: kind, phase: .updating)
        replaceCardInSnapshot(baseline.replacingStatus(status))

        do {
            let response: KanbanCardMutationEnvelope
            if let write {
                response = try await write(cardID)
            } else {
                response = try await client.setKanbanCardStatus(
                    KanbanCardStatusRequest(cardID: cardID, board: board, status: status)
                )
            }
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            let authoritative = try KanbanCardMutationValidator.validate(response, expectedCardID: cardID)
            guard authoritative.status?.rawValue == status else {
                throw KanbanMutationSettlementError.unexpectedStatus
            }
            settleSuccessfulStatusMutation(
                authoritative,
                baseline: baseline,
                kind: kind,
                mutationID: mutationID
            )
        } catch {
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            guard !isCancellation(error) else {
                restoreFailedOptimisticMutation(cardID: cardID, baseline: baseline, kind: kind, phase: .failed)
                return
            }
            forwardAuthentication(error)
            markCapabilityUnavailableIfNeeded(.cardWorkflow, error: error)
            if isDefinitiveWriteFailure(error) {
                restoreFailedOptimisticMutation(cardID: cardID, baseline: baseline, kind: kind, phase: .failed)
            } else {
                cardMutationStates[cardID] = KanbanCardMutationState(kind: kind, phase: .checkingResult)
                await reconcileStatusMutation(
                    cardID: cardID,
                    expectedStatus: status,
                    baseline: baseline,
                    kind: kind,
                    mutationID: mutationID
                )
            }
        }
    }

    private func reconcileStatusMutation(
        cardID: String,
        expectedStatus: String,
        baseline: KanbanCard,
        kind: KanbanCardMutationKind,
        mutationID: UUID
    ) async {
        guard let board = selectedBoardSlug else { return }
        do {
            let detail = try await client.kanbanCardDetail(
                KanbanCardDetailRequest(cardID: cardID, board: board)
            )
            try KanbanCardDetailValidator.validate(detail, requestedCardID: cardID)
            guard activeCardMutationIDs[cardID] == mutationID, let authoritative = detail.card else { return }
            if authoritative.status?.rawValue == expectedStatus {
                settleSuccessfulStatusMutation(
                    authoritative,
                    baseline: baseline,
                    kind: kind,
                    mutationID: mutationID
                )
            } else {
                restoreFailedOptimisticMutation(
                    cardID: cardID,
                    baseline: authoritative,
                    kind: kind,
                    phase: .failed
                )
            }
        } catch {
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            forwardAuthentication(error)
            if isNotFound(error) {
                removeCardFromSnapshot(cardID)
                finishMutation(cardID: cardID, kind: kind, phase: .failed)
            } else {
                restoreFailedOptimisticMutation(
                    cardID: cardID,
                    baseline: baseline,
                    kind: kind,
                    phase: .outcomeUncertain
                )
            }
        }
    }

    private func settleSuccessfulStatusMutation(
        _ authoritative: KanbanCard,
        baseline: KanbanCard,
        kind: KanbanCardMutationKind,
        mutationID: UUID
    ) {
        guard let cardID = normalizedOptional(authoritative.cardID),
              activeCardMutationIDs[cardID] == mutationID else { return }
        pendingOptimisticStatuses[cardID] = nil
        settledDetailStatuses[cardID] = authoritative.status?.rawValue
        replaceCardInSnapshot(authoritative)
        finishMutation(cardID: cardID, kind: kind, phase: .succeeded)
        if case let .archive(previousStatus) = kind {
            offerArchiveUndo(
                card: authoritative,
                title: baseline.title,
                previousStatus: previousStatus
            )
        }
    }
}
