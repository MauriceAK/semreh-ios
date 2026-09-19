import SwiftUI
import UIKit



enum KanbanCardAction: Equatable {
    case move(String)
    case block
    case unblock
    case complete
    case archive
}

enum KanbanCardRowPrimaryAction: Equatable {
    case openDetail(String)
    case toggleSelection(String)

    static func resolve(for card: KanbanCard, isSelecting: Bool) -> Self? {
        guard let cardID = card.cardID else { return nil }
        return isSelecting ? .toggleSelection(cardID) : .openDetail(cardID)
    }

    static func focusTarget(afterDismissing cardID: String, visibleCards: [KanbanCard]) -> String? {
        visibleCards.contains { $0.cardID == cardID } ? cardID : nil
    }
}

struct KanbanPendingCardAction: Identifiable, Equatable {
    let id = UUID()
    let card: KanbanCard
    let action: KanbanCardAction

    static func == (lhs: KanbanPendingCardAction, rhs: KanbanPendingCardAction) -> Bool {
        lhs.id == rhs.id
    }
}

enum KanbanDispatcherPresentation {
    static func hasResult(_ state: KanbanDispatchState?) -> Bool {
        guard let state, state.result != nil else { return false }
        switch state.phase {
        case .succeeded, .outcomeUncertain:
            return true
        case .submitting, .reconciling, .refused, .failed, .boardUnavailable:
            return false
        }
    }

    static func requiresAttention(_ state: KanbanDispatchState?) -> Bool {
        state?.phase == .outcomeUncertain && state?.result == nil
    }

    static func toolbarSystemImage(for state: KanbanDispatchState?) -> String {
        if requiresAttention(state) {
            return "exclamationmark.circle.fill"
        }
        if hasResult(state) {
            return "bolt.horizontal.circle.fill"
        }
        return "bolt.horizontal.circle"
    }

    static func toolbarAccessibilityLabel(for state: KanbanDispatchState?) -> String {
        if requiresAttention(state) {
            return String(localized: "Dispatcher, attention required")
        }
        if hasResult(state) {
            return String(localized: "Dispatcher, result available")
        }
        return String(localized: "Dispatcher")
    }
}

@MainActor
struct KanbanFiltersDraft {
    var profile: String?
    var tenant: String?
    var includesArchived: Bool
    var onlyMine: Bool
    var groupsByProfile: Bool

    init(model: KanbanFeatureState) {
        profile = model.selectedProfile
        tenant = model.selectedTenant
        includesArchived = model.includeArchived
        onlyMine = model.onlyMine
        groupsByProfile = model.groupByProfile
    }

    func apply(to model: KanbanFeatureState) async {
        let serverFiltersChanged = profile != model.selectedProfile
            || tenant != model.selectedTenant
            || includesArchived != model.includeArchived
            || onlyMine != model.onlyMine
        model.groupByProfile = groupsByProfile
        guard serverFiltersChanged else { return }
        await model.applyFilters(
            profile: profile,
            tenant: tenant,
            includeArchived: includesArchived,
            onlyMine: onlyMine
        )
    }
}

struct KanbanStatusFocusView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: KanbanFeatureState
    @State var showsFilters = false
    @State var showsBoardManagement = false
    @State var visibleModel: KanbanFeatureState?
    @State var cardEditor: KanbanCardEditorState?
    @State var pendingRunningAction: KanbanPendingCardAction?
    @State var showsBulkActions = false
    @State var confirmsBulkArchive = false
    @State var confirmsRunDispatcher = false
    @State var showsDispatcher = false
    @State var presentedCardID: String?
    @AccessibilityFocusState var focusedCardID: String?
    @AccessibilityFocusState var archiveUndoIsFocused: Bool
    @AccessibilityFocusState var selectionControlsAreFocused: Bool
    @AccessibilityFocusState var bulkSummaryIsFocused: Bool
    @AccessibilityFocusState var dispatchSummaryIsFocused: Bool
    @AccessibilityFocusState var dispatcherButtonIsFocused: Bool


    var body: some View {
        Group {
            switch model.state {
            case .idle, .checking:
                loadingContent
            case .compatible, .partial:
                boardContent
            case .authenticationRequired:
                unavailableContent(
                    title: String(localized: "Sign in is required for Kanban."),
                    detail: String(localized: "Return to the server login screen, then try again."),
                    systemImage: "lock"
                )
            case .networkUnavailable:
                unavailableContent(
                    title: String(localized: "Kanban could not reach the server."),
                    detail: String(localized: "Check your connection, then try again."),
                    systemImage: "wifi.exclamationmark"
                )
            case .serverUnavailable:
                unavailableContent(
                    title: String(localized: "The Kanban server is unavailable."),
                    detail: String(localized: "Check that the Hermes server is awake, then try again."),
                    systemImage: "server.rack"
                )
            case .incompatibleContract:
                unavailableContent(
                    title: String(localized: "This server's Kanban response is incompatible with Semreh."),
                    detail: String(localized: "No Kanban changes were made."),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .navigationDestination(item: $presentedCardID) { cardID in
            KanbanCardDetailView(featureModel: model, cardID: cardID)
        }
        .navigationTitle(String(localized: "Kanban"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.searchText, prompt: Text("Search Cards"))
        .toolbar { toolbarContent }
        .sheet(isPresented: $showsFilters) {
            KanbanFiltersView(model: model)
        }
        .sheet(isPresented: $showsDispatcher, onDismiss: {
            dispatcherButtonIsFocused = true
        }) {
            dispatcherSheet
        }
        .sheet(isPresented: $showsBoardManagement) {
            NavigationStack {
                KanbanBoardManagementView(model: model)
            }
        }
        .sheet(item: $cardEditor) { editor in
            KanbanCardEditorView(
                state: editor,
                allowsMutation: editor.isEditing ? model.canEditCards : model.canCreateCards,
                onSaved: { await model.reconcileAfterCardMutation() }
            )
        }
        .sheet(isPresented: $showsBulkActions, onDismiss: {
            selectionControlsAreFocused = true
        }) {
            KanbanBulkActionsView(
                model: model,
                onArchive: {
                    showsBulkActions = false
                    confirmsBulkArchive = true
                },
                onFinished: {
                    showsBulkActions = false
                    bulkSummaryIsFocused = true
                }
            )
        }
        .onAppear { activateCurrentModel() }
        .onDisappear {
            visibleModel?.setVisible(false)
            visibleModel = nil
        }
        .onChange(of: ObjectIdentifier(model)) { _, _ in
            activateCurrentModel()
            updateSceneActivity(scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in
            updateSceneActivity(phase)
        }
        .onChange(of: model.isRefreshing) { wasRefreshing, isRefreshing in
            if wasRefreshing, !isRefreshing, model.isSelectingCards {
                selectionControlsAreFocused = true
            }
        }
        .onChange(of: model.dispatchState?.phase) { oldPhase, newPhase in
            if oldPhase?.isInFlight == true, newPhase?.isInFlight == false {
                if showsDispatcher {
                    dispatchSummaryIsFocused = true
                } else {
                    dispatcherButtonIsFocused = true
                }
            }
        }
        .onChange(of: presentedCardID) { previousCardID, currentCardID in
            guard currentCardID == nil, let previousCardID else { return }
            Task { @MainActor in
                await Task.yield()
                focusedCardID = KanbanCardRowPrimaryAction.focusTarget(
                    afterDismissing: previousCardID,
                    visibleCards: model.visibleCards
                )
            }
        }
        .alert(
            "Leave Running?",
            isPresented: Binding(
                get: { pendingRunningAction != nil },
                set: { if !$0 { pendingRunningAction = nil } }
            ),
            presenting: pendingRunningAction
        ) { pending in
            Button("Cancel", role: .cancel) { pendingRunningAction = nil }
            Button("Continue", role: .destructive) {
                pendingRunningAction = nil
                perform(pending.action, for: pending.card, confirmingRunningExit: true)
            }
        } message: { _ in
            Text("Leaving Running may clear the Card's claim and worker state.")
        }
        .alert("Archive Cards", isPresented: $confirmsBulkArchive) {
            Button("Cancel", role: .cancel) {
                selectionControlsAreFocused = true
            }
            Button("Archive Cards", role: .destructive) {
                Task {
                    await model.performBulkAction(.archiveCards)
                    bulkSummaryIsFocused = true
                }
            }
        } message: {
            Text("The selected Cards will be moved to the archive.")
        }
    }

    private func activateCurrentModel() {
        guard visibleModel !== model else {
            model.setVisible(true)
            return
        }
        visibleModel?.setVisible(false)
        visibleModel = model
        model.setVisible(true)
    }

    private func updateSceneActivity(_ phase: ScenePhase) {
        let isActive = phase == .active
        Task { await model.setSceneActive(isActive) }
    }

    private var loadingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading Kanban")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Loading Kanban"))
    }

    private var boardContent: some View {
        VStack(spacing: 0) {
            if model.state == .partial {
                compatibilityBanner
            }
            if model.isOffline {
                offlineBanner
            } else if model.liveUpdatesDelayed {
                liveUpdatesDelayedBanner
            }
            if model.refreshFailed {
                refreshErrorBanner
            }
            if model.hasAvailableArchiveUndo, let undo = model.archiveUndo {
                archiveUndoBanner(undo)
            }
            if model.bulkActionPhase != nil {
                bulkProgressBanner
            } else if let summary = model.bulkActionSummary {
                bulkSummaryBanner(summary)
            }
            if model.requiresBoardSelection {
                boardSelectionContent
            } else {
                if model.isSelectingCards {
                    selectionControls
                }
                statusSelector
                Divider()
                cardList
            }
        }
    }
}