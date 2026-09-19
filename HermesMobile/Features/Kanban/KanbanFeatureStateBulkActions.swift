import Foundation

extension KanbanFeatureState {
    func makeCardDetailState(cardID: String) -> KanbanCardDetailState? {
        guard let board = selectedBoardSlug else { return nil }
        return KanbanCardDetailState(
            cardID: cardID,
            board: board,
            client: client,
            onAPIError: onAPIError,
            onDetailLoaded: { [weak self] detail in
                self?.acknowledgeLoadedCardDetail(detail)
            },
            onCapabilityUnavailable: { [weak self] capability in
                self?.markCapabilityUnavailable(capability)
            }
        )
    }

    func makeCreateCardEditorState() -> KanbanCardEditorState? {
        guard canCreateCards, let board = selectedBoardSlug else { return nil }
        return KanbanCardEditorState(
            mode: .create,
            board: board,
            client: client,
            profileOptions: profileOptions,
            tenantOptions: tenantOptions,
            prerequisiteOptions: allCards.filter { $0.cardID != nil },
            baselineCards: allCards,
            onCapabilityUnavailable: { [weak self] capability in
                self?.markCapabilityUnavailable(capability)
            }
        )
    }

    func makeEditCardEditorState(detail: KanbanCardDetailEnvelope) -> KanbanCardEditorState? {
        guard canEditCards,
              let board = selectedBoardSlug,
              let card = detail.card,
              let cardID = normalized(card.cardID) else { return nil }
        return KanbanCardEditorState(
            mode: .edit(cardID: cardID),
            board: board,
            client: client,
            card: card,
            prerequisiteID: detail.links?.prerequisites?.first,
            profileOptions: profileOptions,
            tenantOptions: tenantOptions,
            prerequisiteOptions: allCards.filter { $0.cardID != nil && $0.cardID != cardID },
            baselineCards: allCards,
            onCapabilityUnavailable: { [weak self] capability in
                self?.markCapabilityUnavailable(capability)
            }
        )
    }

    func reconcileAfterCardMutation() async {
        _ = await refreshBoard(usingCursor: false, refreshSupplementary: true)
    }

    func performBulkAction(_ action: KanbanBulkAction, cardIDs: Set<String>) async {
        guard bulkActionsAvailability == .available,
              validate(action),
              !cardIDs.isEmpty,
              cardIDs == selectedCardIDs,
              let board = selectedBoardSlug else { return }
        let orderedIDs = cardIDs.sorted()
        let originalCards = Dictionary(
            uniqueKeysWithValues: orderedIDs.compactMap { cardID in
                (selectedCardsByID[cardID] ?? cardInSnapshot(cardID)).map { (cardID, $0) }
            }
        )
        guard originalCards.count == orderedIDs.count else { return }

        markBoardActivity()
        bulkActionSummary = nil
        bulkActionPhase = .submitting
        do {
            _ = try await client.performKanbanBulkAction(KanbanBulkActionRequest(
                board: board,
                cardIDs: orderedIDs,
                action: action
            ))
        } catch {
            forwardAuthentication(error)
            markCapabilityUnavailableIfNeeded(.bulkActions, error: error)
        }

        guard selectedBoardSlug == board else {
            bulkActionPhase = nil
            resetCardSelection()
            return
        }
        bulkActionPhase = .reconciling
        var members: [KanbanBulkMemberResult] = []
        let detailResults = await fetchBulkCardDetails(cardIDs: orderedIDs, board: board)

        for cardID in orderedIDs {
            let original = originalCards[cardID]
            switch detailResults[cardID] {
            case let .success(detail):
                guard selectedBoardSlug == board,
                      let authoritative = detail.card,
                      normalizedOptional(authoritative.cardID) == cardID else {
                    members.append(bulkMember(
                        cardID: cardID,
                        card: original,
                        outcome: .outcomeUncertain
                    ))
                    continue
                }
                replaceCardInSnapshot(authoritative)
                selectedCardsByID[cardID] = authoritative
                let intendedResultIsPresent = actionMatches(action, card: authoritative)
                members.append(bulkMember(
                    cardID: cardID,
                    card: authoritative,
                    outcome: intendedResultIsPresent ? .succeeded : .failed
                ))
            case let .failure(error):
                members.append(bulkMember(
                    cardID: cardID,
                    card: original,
                    outcome: .outcomeUncertain
                ))
                forwardAuthentication(error)
            case nil:
                members.append(bulkMember(
                    cardID: cardID,
                    card: original,
                    outcome: .outcomeUncertain
                ))
            }
        }

        guard selectedBoardSlug == board else {
            bulkActionPhase = nil
            resetCardSelection()
            return
        }
        let summary = KanbanBulkActionSummary(action: action, members: members)
        bulkActionSummary = summary
        let retainedIDs = Set(summary.needsAttention.map(\.cardID))
        selectedCardIDs = retainedIDs
        selectedCardsByID = selectedCardsByID.filter { retainedIDs.contains($0.key) }
        bulkActionPhase = nil
        _ = await refreshBoard(usingCursor: false, refreshSupplementary: true)
    }

    private func fetchBulkCardDetails(
        cardIDs: [String],
        board: String
    ) async -> [String: Result<KanbanCardDetailEnvelope, Error>] {
        await withTaskGroup(
            of: (String, Result<KanbanCardDetailEnvelope, Error>).self,
            returning: [String: Result<KanbanCardDetailEnvelope, Error>].self
        ) { group in
            var remainingIDs = cardIDs.makeIterator()
            for _ in 0..<min(Self.bulkReconciliationConcurrency, cardIDs.count) {
                guard let cardID = remainingIDs.next() else { break }
                addBulkDetailTask(cardID: cardID, board: board, to: &group)
            }

            var results: [String: Result<KanbanCardDetailEnvelope, Error>] = [:]
            while let (cardID, result) = await group.next() {
                results[cardID] = result
                if let nextCardID = remainingIDs.next() {
                    addBulkDetailTask(cardID: nextCardID, board: board, to: &group)
                }
            }
            return results
        }
    }

    private func addBulkDetailTask(
        cardID: String,
        board: String,
        to group: inout TaskGroup<(String, Result<KanbanCardDetailEnvelope, Error>)>
    ) {
        group.addTask { [client] in
            do {
                let detail = try await client.kanbanCardDetail(
                    KanbanCardDetailRequest(cardID: cardID, board: board)
                )
                return (cardID, .success(detail))
            } catch {
                return (cardID, .failure(error))
            }
        }
    }

    func validate(_ action: KanbanBulkAction) -> Bool {
        switch action {
        case let .changeStatus(status):
            guard let normalizedStatus = normalized(status) else { return false }
            return normalizedStatus != "running"
                && (configuration?.columns ?? []).contains(normalizedStatus)
        case let .assignProfile(profile):
            guard let profile = normalizedOptional(profile) else { return profile == nil }
            return profileOptions.contains(profile)
        case let .setPriority(priority):
            return (-100...100).contains(priority)
        case .archiveCards:
            return true
        }
    }

    private func actionMatches(_ action: KanbanBulkAction, card: KanbanCard) -> Bool {
        switch action {
        case let .changeStatus(status):
            return card.status?.rawValue == normalized(status)
        case let .assignProfile(profile):
            return normalizedOptional(card.assignee) == normalizedOptional(profile)
        case let .setPriority(priority):
            return (card.priority ?? 0) == priority
        case .archiveCards:
            return card.status?.rawValue == "archived"
        }
    }

    private func bulkMember(
        cardID: String,
        card: KanbanCard?,
        outcome: KanbanBulkMemberOutcome
    ) -> KanbanBulkMemberResult {
        KanbanBulkMemberResult(
            cardID: cardID,
            cardTitle: normalizedOptional(card?.title) ?? cardID,
            outcome: outcome
        )
    }
}
