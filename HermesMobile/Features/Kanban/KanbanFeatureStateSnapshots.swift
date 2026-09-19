import Foundation

extension KanbanFeatureState {
    func cardInSnapshot(_ cardID: String) -> KanbanCard? {
        allCards.first { normalizedOptional($0.cardID) == cardID }
    }

    func replaceCardInSnapshot(_ card: KanbanCard) {
        guard let snapshot, let cardID = normalizedOptional(card.cardID),
              let destination = normalizedOptional(card.status?.rawValue) else { return }
        markBoardActivity()
        var destinationFound = false
        var columns = (snapshot.columns ?? []).map { column in
            var cards = (column.cards ?? []).filter { normalizedOptional($0.cardID) != cardID }
            if column.name == destination {
                cards.append(card)
                destinationFound = true
            }
            return KanbanColumn(name: column.name, cards: cards)
        }
        if !destinationFound, destination != "archived" || includeArchived {
            columns.append(KanbanColumn(name: destination, cards: [card]))
        }
        self.snapshot = snapshotReplacingColumns(snapshot, columns: columns)
    }

    func removeCardFromSnapshot(_ cardID: String) {
        guard let snapshot else { return }
        markBoardActivity()
        let columns = (snapshot.columns ?? []).map { column in
            KanbanColumn(
                name: column.name,
                cards: (column.cards ?? []).filter { normalizedOptional($0.cardID) != cardID }
            )
        }
        self.snapshot = snapshotReplacingColumns(snapshot, columns: columns)
    }

    func applyingPendingOptimism(to response: KanbanBoardSnapshot) -> KanbanBoardSnapshot {
        var result = response
        for card in uncertainProtectedCards.values {
            result = snapshotReplacing(card, in: result)
        }
        for (cardID, status) in pendingOptimisticStatuses {
            guard let card = (result.columns ?? []).flatMap({ $0.cards ?? [] }).first(where: {
                normalizedOptional($0.cardID) == cardID
            }) ?? cardInSnapshot(cardID) else { continue }
            result = snapshotReplacing(card.replacingStatus(status), in: result)
        }
        return result
    }

    private func snapshotReplacing(_ card: KanbanCard, in snapshot: KanbanBoardSnapshot) -> KanbanBoardSnapshot {
        guard let cardID = normalizedOptional(card.cardID),
              let destination = normalizedOptional(card.status?.rawValue) else { return snapshot }
        var destinationFound = false
        var columns = (snapshot.columns ?? []).map { column in
            var cards = (column.cards ?? []).filter { normalizedOptional($0.cardID) != cardID }
            if column.name == destination {
                cards.append(card)
                destinationFound = true
            }
            return KanbanColumn(name: column.name, cards: cards)
        }
        if !destinationFound, destination != "archived" || includeArchived {
            columns.append(KanbanColumn(name: destination, cards: [card]))
        }
        return snapshotReplacingColumns(snapshot, columns: columns)
    }

    private func snapshotReplacingColumns(
        _ snapshot: KanbanBoardSnapshot,
        columns: [KanbanColumn]
    ) -> KanbanBoardSnapshot {
        KanbanBoardSnapshot(
            columns: columns,
            tenants: snapshot.tenants,
            assignees: snapshot.assignees,
            filters: snapshot.filters,
            changed: snapshot.changed,
            latestEventID: snapshot.latestEventID,
            readOnly: snapshot.readOnly
        )
    }

    func isDefinitiveWriteFailure(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return error is KanbanRequestError }
        switch apiError {
        case .unauthorized, .invalidServerURL:
            return true
        case let .http(statusCode, _):
            return (400..<500).contains(statusCode) && statusCode != 408
        case .network, .decoding:
            return false
        }
    }

    func isNotFound(_ error: Error) -> Bool {
        guard case let APIError.http(statusCode, _) = error else { return false }
        return statusCode == 404
    }

    func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        if case let APIError.network(underlying) = error {
            return (underlying as? URLError)?.code == .cancelled
        }
        return false
    }
}
