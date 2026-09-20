import Foundation

extension KanbanFeatureState {
    var selectedBoard: KanbanBoard? {
        guard let selectedBoardSlug else { return nil }
        return boards.first { normalized($0.slug) == selectedBoardSlug }
    }

    var availableStatuses: [String] {
        var result = Self.liveStatuses
        if includeArchived { result.append("archived") }
        for column in snapshot?.columns ?? [] {
            guard let name = normalized(column.name), !result.contains(name) else { continue }
            result.append(name)
        }
        return result
    }

    var profileOptions: [String] {
        sortedUnique(
            (configuration?.assignees ?? [])
                + (assigneeHistory?.assignees ?? [])
                + (snapshot?.assignees ?? [])
                + allCards.compactMap(\.assignee)
        )
    }

    var tenantOptions: [String] {
        sortedUnique((snapshot?.tenants ?? []) + allCards.compactMap(\.tenant))
    }

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedProfile != nil
            || selectedTenant != nil
            || includeArchived
            || onlyMine
    }

    var allCards: [KanbanCard] {
        (snapshot?.columns ?? []).flatMap { $0.cards ?? [] }
    }

    var visibleCards: [KanbanCard] {
        searchMatchedCards.filter { $0.status?.rawValue == selectedStatus }
    }

    var groupedVisibleCards: [(profile: String?, cards: [KanbanCard])] {
        let groups = Dictionary(grouping: visibleCards, by: { normalized($0.assignee) })
        return groups
            .map { (profile: $0.key, cards: $0.value) }
            .sorted {
                switch ($0.profile, $1.profile) {
                case (nil, nil): false
                case (nil, _): true
                case (_, nil): false
                case let (left?, right?): left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                }
            }
    }

    func statusCount(_ status: String) -> Int {
        searchMatchedCards.count { $0.status?.rawValue == status }
    }

    func canMutateCard(_ card: KanbanCard) -> Bool {
        guard canUseCardWorkflow,
              normalizedOptional(card.cardID) != nil,
              let status = card.status?.rawValue else { return false }
        return Self.liveStatuses.contains(status) || status == "archived"
    }

    func isMutatingCard(_ cardID: String?) -> Bool {
        guard let cardID = normalizedOptional(cardID) else { return false }
        return activeCardMutationIDs[cardID] != nil
    }

    func mutationState(for cardID: String?) -> KanbanCardMutationState? {
        guard let cardID = normalizedOptional(cardID) else { return nil }
        return cardMutationStates[cardID]
    }

    func moveDestinations(for card: KanbanCard) -> [String] {
        guard canMutateCard(card) else { return [] }
        let ordinaryDestinations = Set(["triage", "todo", "ready"])
        return (configuration?.columns ?? [])
            .filter { ordinaryDestinations.contains($0) && $0 != card.status?.rawValue }
    }

    func displayedPrerequisites(for cardID: String, canonical: [String]) -> [String] {
        guard let change = pendingDependencyChanges[cardID] else { return canonical }
        var result = canonical.filter { $0 != change.prerequisiteID }
        if change.isAdding { result.append(change.prerequisiteID) }
        return Array(Set(result)).sorted()
    }

    func displayedCard(_ canonical: KanbanCard) -> KanbanCard {
        guard let cardID = normalizedOptional(canonical.cardID),
              let status = pendingOptimisticStatuses[cardID] ?? settledDetailStatuses[cardID] else {
            return canonical
        }
        return canonical.replacingStatus(status)
    }

    func acknowledgeLoadedCardDetail(_ detail: KanbanCardDetailEnvelope) {
        guard let cardID = normalizedOptional(detail.card?.cardID),
              activeCardMutationIDs[cardID] == nil,
              cardMutationStates[cardID]?.phase == .succeeded else { return }
        settledDetailStatuses[cardID] = nil
        pendingDependencyChanges[cardID] = nil
    }
}
