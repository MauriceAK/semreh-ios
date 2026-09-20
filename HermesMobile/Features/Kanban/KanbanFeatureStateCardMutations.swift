import Foundation

extension KanbanFeatureState {
    func moveCard(
        _ card: KanbanCard,
        to status: String,
        confirmingRunningExit: Bool = false
    ) async {
        guard status != "running", moveDestinations(for: card).contains(status) else { return }
        await performStatusMutation(
            card,
            status: status,
            kind: .status(status),
            confirmingRunningExit: confirmingRunningExit
        )
    }

    func completeCard(_ card: KanbanCard, confirmingRunningExit: Bool = false) async {
        guard card.status?.rawValue != "done", card.status?.rawValue != "archived" else { return }
        await performStatusMutation(
            card,
            status: "done",
            kind: .status("done"),
            confirmingRunningExit: confirmingRunningExit
        )
    }

    func archiveCard(_ card: KanbanCard, confirmingRunningExit: Bool = false) async {
        guard let previousStatus = card.status?.rawValue, previousStatus != "archived" else { return }
        await performStatusMutation(
            card,
            status: "archived",
            kind: .archive(previousStatus: previousStatus),
            confirmingRunningExit: confirmingRunningExit
        )
    }

    func blockCard(
        _ card: KanbanCard,
        reason: String?,
        confirmingRunningExit: Bool = false
    ) async {
        guard canMutateCard(card), card.status?.rawValue != "blocked", card.status?.rawValue != "archived" else { return }
        let reason = normalizedOptional(reason)
        await performStatusMutation(
            card,
            status: "blocked",
            kind: .block(reason),
            confirmingRunningExit: confirmingRunningExit
        ) { [client, selectedBoardSlug] cardID in
            guard let board = selectedBoardSlug else { throw CancellationError() }
            return try await client.blockKanbanCard(
                KanbanCardActionRequest(cardID: cardID, board: board, reason: reason)
            )
        }
    }

    func unblockCard(_ card: KanbanCard) async {
        guard canMutateCard(card), card.status?.rawValue == "blocked" else { return }
        await performStatusMutation(card, status: "ready", kind: .unblock) { [client, selectedBoardSlug] cardID in
            guard let board = selectedBoardSlug else { throw CancellationError() }
            return try await client.unblockKanbanCard(
                KanbanCardActionRequest(cardID: cardID, board: board, reason: nil)
            )
        }
    }

    func addPrerequisite(_ prerequisiteID: String, to card: KanbanCard) async {
        await mutatePrerequisite(prerequisiteID, card: card, isAdding: true)
    }

    func removePrerequisite(_ prerequisiteID: String, from card: KanbanCard) async {
        await mutatePrerequisite(prerequisiteID, card: card, isAdding: false)
    }

    func undoArchive() async {
        guard hasAvailableArchiveUndo,
              let undo = archiveUndo,
              let board = selectedBoardSlug else {
            archiveUndo = nil
            return
        }
        archiveUndoTask?.cancel()
        do {
            let detail = try await client.kanbanCardDetail(
                KanbanCardDetailRequest(cardID: undo.cardID, board: board)
            )
            try KanbanCardDetailValidator.validate(detail, requestedCardID: undo.cardID)
            guard let card = detail.card, card.status?.rawValue == "archived" else {
                archiveUndo = nil
                if let card = detail.card { replaceCardInSnapshot(card) }
                cardMutationStates[undo.cardID] = KanbanCardMutationState(
                    kind: .undoArchive(status: undo.previousStatus), phase: .failed
                )
                detailRefreshRevision &+= 1
                return
            }
            archiveUndo = nil
            await performStatusMutation(
                card,
                status: undo.previousStatus,
                kind: .undoArchive(status: undo.previousStatus)
            )
            if let phase = cardMutationStates[undo.cardID]?.phase,
               phase == .failed || phase == .outcomeUncertain {
                archiveUndo = recoveryUndo(from: undo, card: card)
            }
        } catch {
            forwardAuthentication(error)
            if isNotFound(error) {
                archiveUndo = nil
                uncertainProtectedCards[undo.cardID] = nil
                removeCardFromSnapshot(undo.cardID)
                cardMutationStates[undo.cardID] = KanbanCardMutationState(
                    kind: .undoArchive(status: undo.previousStatus), phase: .failed
                )
                detailRefreshRevision &+= 1
                return
            }
            archiveUndo = recoveryUndo(from: undo, card: undo.card)
            cardMutationStates[undo.cardID] = KanbanCardMutationState(
                kind: .undoArchive(status: undo.previousStatus), phase: .outcomeUncertain
            )
        }
    }

    func retryMutation(for card: KanbanCard) async {
        guard let cardID = normalizedOptional(card.cardID),
              let mutation = cardMutationStates[cardID],
              mutation.phase == .failed else { return }
        switch mutation.kind {
        case let .status(status):
            await performStatusMutation(card, status: status, kind: mutation.kind)
        case let .block(reason):
            await blockCard(card, reason: reason)
        case .unblock:
            await unblockCard(card)
        case let .addPrerequisite(prerequisiteID):
            await addPrerequisite(prerequisiteID, to: card)
        case let .removePrerequisite(prerequisiteID):
            await removePrerequisite(prerequisiteID, from: card)
        case .archive:
            await archiveCard(card)
        case let .undoArchive(status):
            await performStatusMutation(card, status: status, kind: mutation.kind)
        }
    }

    func checkUncertainMutation(for card: KanbanCard) async {
        guard let cardID = normalizedOptional(card.cardID),
              let mutation = cardMutationStates[cardID],
              mutation.phase == .outcomeUncertain,
              activeCardMutationIDs[cardID] == nil,
              let board = selectedBoardSlug else { return }
        cardMutationStates[cardID] = KanbanCardMutationState(
            kind: mutation.kind,
            phase: .checkingResult
        )
        do {
            let detail = try await client.kanbanCardDetail(
                KanbanCardDetailRequest(cardID: cardID, board: board)
            )
            try KanbanCardDetailValidator.validate(detail, requestedCardID: cardID)
            guard let authoritative = detail.card else { throw KanbanMutationSettlementError.unexpectedStatus }
            uncertainProtectedCards[cardID] = nil
            replaceCardInSnapshot(authoritative)
            let succeeded: Bool
            switch mutation.kind {
            case let .status(status), let .undoArchive(status):
                succeeded = authoritative.status?.rawValue == status
            case .block:
                succeeded = authoritative.status?.rawValue == "blocked"
            case .unblock:
                succeeded = authoritative.status?.rawValue == "ready"
            case .archive:
                succeeded = authoritative.status?.rawValue == "archived"
            case let .addPrerequisite(prerequisiteID):
                succeeded = detail.links?.prerequisites?.contains(prerequisiteID) == true
            case let .removePrerequisite(prerequisiteID):
                succeeded = detail.links?.prerequisites?.contains(prerequisiteID) != true
            }
            cardMutationStates[cardID] = KanbanCardMutationState(
                kind: mutation.kind,
                phase: succeeded ? .succeeded : .failed
            )
            if case .undoArchive = mutation.kind, succeeded { archiveUndo = nil }
            detailRefreshRevision &+= 1
        } catch {
            forwardAuthentication(error)
            if isNotFound(error) {
                uncertainProtectedCards[cardID] = nil
                removeCardFromSnapshot(cardID)
                if case .undoArchive = mutation.kind { archiveUndo = nil }
            }
            cardMutationStates[cardID] = KanbanCardMutationState(
                kind: mutation.kind,
                phase: isNotFound(error) ? .failed : .outcomeUncertain
            )
        }
    }
}
