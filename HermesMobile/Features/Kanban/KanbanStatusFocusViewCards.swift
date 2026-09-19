import SwiftUI
import UIKit


extension KanbanStatusFocusView {
    var cardList: some View {
        List {
            if model.isRefreshing {
                HStack {
                    Spacer()
                    ProgressView("Refreshing Board")
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }

            if model.isRefreshing, model.snapshot == nil {
                EmptyView()
            } else if model.visibleCards.isEmpty {
                emptyContent
                    .listRowSeparator(.hidden)
            } else if model.groupByProfile {
                ForEach(Array(model.groupedVisibleCards.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group.cards, id: \.cardID) { card in
                            cardNavigationLink(card)
                        }
                    } header: {
                        Text(group.profile ?? String(localized: "Unassigned"))
                    }
                }
            } else {
                ForEach(model.visibleCards, id: \.cardID) { card in
                    cardNavigationLink(card)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    func cardNavigationLink(_ card: KanbanCard) -> some View {
        if model.isSelectingCards {
            Button {
                activateCard(card)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: model.selectedCardIDs.contains(card.cardID ?? "")
                          ? "checkmark.circle.fill"
                          : "circle")
                        .font(.title3)
                    KanbanCardSummaryView(card: card)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityLabel(
                KanbanBulkAccessibility.selectionLabel(
                    card,
                    isSelected: model.selectedCardIDs.contains(card.cardID ?? "")
                )
            )
            .accessibilityAddTraits(
                model.selectedCardIDs.contains(card.cardID ?? "")
                    ? .isSelected
                    : AccessibilityTraits()
            )
        } else {
            ZStack(alignment: .trailing) {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        activateCard(card)
                    } label: {
                        KanbanCardSummaryView(card: card, reservesTrailingActionSpace: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .disabled(card.cardID == nil)
                    .accessibilityLabel(KanbanCardAccessibility.summary(card))
                    .accessibilityFocused($focusedCardID, equals: card.cardID)

                    mutationStatus(for: card)
                }

                cardActionsMenu(card)
            }
        }
    }

    func activateCard(_ card: KanbanCard) {
        switch KanbanCardRowPrimaryAction.resolve(for: card, isSelecting: model.isSelectingCards) {
        case let .openDetail(cardID):
            focusedCardID = cardID
            presentedCardID = cardID
        case .toggleSelection:
            model.toggleCardSelection(card)
            selectionControlsAreFocused = true
        case nil:
            break
        }
    }

    func cardActionsMenu(_ card: KanbanCard) -> some View {
        Menu {
            let destinations = model.moveDestinations(for: card)
            if !destinations.isEmpty {
                Menu("Move") {
                    ForEach(destinations, id: \.self) { destination in
                        Button(KanbanStatusPresentation(destination).title) {
                            request(.move(destination), for: card)
                        }
                    }
                }
            }
            if card.status?.rawValue == "blocked" {
                Button("Unblock") { request(.unblock, for: card) }
            } else if card.status?.rawValue != "archived" {
                Button("Block") { request(.block, for: card) }
            }
            if card.status?.rawValue != "done", card.status?.rawValue != "archived" {
                Button("Complete") { request(.complete, for: card) }
            }
            if card.status?.rawValue != "archived" {
                Button("Archive", role: .destructive) { request(.archive, for: card) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.primary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .tint(.primary)
        .disabled(!model.canMutateCard(card) || model.isMutatingCard(card.cardID))
        .accessibilityLabel(Text("Card Actions"))
    }

    @ViewBuilder
    func mutationStatus(for card: KanbanCard) -> some View {
        if let mutation = model.mutationState(for: card.cardID) {
            switch mutation.phase {
            case .updating:
                Label("Updating task...", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.secondary)
            case .checkingResult:
                Label("Checking Result", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.secondary)
            case .succeeded:
                Label("Updated", systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(.green)
            case .failed:
                HStack {
                    Label("Update failed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                    Button("Try Again") { retryMutation(for: card) }
                }
                .font(.footnote)
            case .outcomeUncertain:
                HStack {
                    Label("Outcome Uncertain", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                    Button("Refresh") { Task { await model.checkUncertainMutation(for: card) } }
                }
                .font(.footnote)
            }
        }
    }

    func request(_ action: KanbanCardAction, for card: KanbanCard) {
        if card.status?.rawValue == "running" {
            pendingRunningAction = KanbanPendingCardAction(card: card, action: action)
        } else {
            perform(action, for: card)
        }
    }

    func perform(
        _ action: KanbanCardAction,
        for card: KanbanCard,
        confirmingRunningExit: Bool = false
    ) {
        Task {
            switch action {
            case let .move(status):
                await model.moveCard(card, to: status, confirmingRunningExit: confirmingRunningExit)
                if model.mutationState(for: card.cardID)?.phase == .succeeded {
                    model.selectedStatus = status
                    await Task.yield()
                    focusedCardID = card.cardID
                }
            case .block:
                await model.blockCard(card, reason: nil, confirmingRunningExit: confirmingRunningExit)
                if model.mutationState(for: card.cardID)?.phase == .succeeded {
                    model.selectedStatus = "blocked"
                    await Task.yield()
                    focusedCardID = card.cardID
                }
            case .unblock:
                await model.unblockCard(card)
                if model.mutationState(for: card.cardID)?.phase == .succeeded {
                    model.selectedStatus = "ready"
                    await Task.yield()
                    focusedCardID = card.cardID
                }
            case .complete:
                await model.completeCard(card, confirmingRunningExit: confirmingRunningExit)
                if model.mutationState(for: card.cardID)?.phase == .succeeded {
                    model.selectedStatus = "done"
                    await Task.yield()
                    focusedCardID = card.cardID
                }
            case .archive:
                await model.archiveCard(card, confirmingRunningExit: confirmingRunningExit)
                if model.hasAvailableArchiveUndo {
                    archiveUndoIsFocused = true
                }
            }
        }
    }

    func retryMutation(for card: KanbanCard) {
        guard card.status?.rawValue == "running",
              let mutation = model.mutationState(for: card.cardID) else {
            Task { await model.retryMutation(for: card) }
            return
        }
        switch mutation.kind {
        case let .status(status): request(status == "done" ? .complete : .move(status), for: card)
        case .block: request(.block, for: card)
        case .archive: request(.archive, for: card)
        default: Task { await model.retryMutation(for: card) }
        }
    }

    var emptyContent: some View {
        ContentUnavailableView {
            Label(
                model.hasActiveFilters ? String(localized: "No matching Cards") : String(localized: "No Cards in this Status"),
                systemImage: model.hasActiveFilters ? "line.3.horizontal.decrease.circle" : "rectangle.stack"
            )
        } description: {
            Text(model.hasActiveFilters
                 ? String(localized: "Change or clear the filters to see more Cards.")
                 : String(localized: "Choose another Status or refresh the Board."))
        } actions: {
            if model.hasActiveFilters {
                Button("Clear Filters") { Task { await model.clearFilters() } }
                    .frame(minHeight: 44)
            }
        }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(model.boards, id: \.slug) { board in
                    if let slug = board.slug {
                        Button {
                            Task { await model.selectBoard(slug) }
                        } label: {
                            if slug == model.selectedBoardSlug {
                                Label(board.name ?? slug, systemImage: "checkmark")
                            } else {
                                Text(board.name ?? slug)
                            }
                        }
                    }
                }
                Divider()
                Button {
                    showsBoardManagement = true
                } label: {
                    Label("Manage", systemImage: "slider.horizontal.3")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.selectedBoard?.name ?? model.selectedBoardSlug ?? String(localized: "Board"))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .frame(minHeight: 44)
            }
            .accessibilityLabel(String(localized: "Switch Board"))
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                if model.isSelectingCards {
                    model.clearCardSelection()
                } else {
                    model.beginSelectingCards()
                    selectionControlsAreFocused = true
                }
            } label: {
                Image(systemName: model.isSelectingCards ? "xmark" : "checkmark.circle")
            }
            .disabled(model.bulkActionPhase != nil || !model.canUseBulkActions)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(model.isSelectingCards ? Text("Cancel") : Text("Select Cards"))

            Button {
                cardEditor = model.makeCreateCardEditorState()
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!model.canCreateCards)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text("New Card"))

            Button {
                showsDispatcher = true
            } label: {
                Label(
                    "Dispatcher",
                    systemImage: KanbanDispatcherPresentation.toolbarSystemImage(
                        for: model.dispatchState
                    )
                )
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(
                Text(KanbanDispatcherPresentation.toolbarAccessibilityLabel(for: model.dispatchState))
            )
            .accessibilityFocused($dispatcherButtonIsFocused)

            Button {
                showsFilters = true
            } label: {
                Image(systemName: model.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text("Card Filters"))
        }
    }

    func unavailableContent(title: String, detail: String, systemImage: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            Button("Try Again") { Task { await model.retry() } }
                .frame(minHeight: 44)
        }
    }
}
