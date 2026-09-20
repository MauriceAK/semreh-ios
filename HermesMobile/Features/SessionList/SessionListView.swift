import SwiftUI
import SwiftData
import UIKit

@MainActor
struct SessionListView: View {
    static let searchChromeIconVisualSize: CGFloat = 36
    static let searchChromeIconHitTarget: CGFloat = 44

    @Bindable var authManager: AuthManager
    let server: URL
    let projectsEnabled: Bool
    let usesShellChrome: Bool
    let shellSurfaceVisitID: Int
    let onConversationVisibilityChanged: (Bool) -> Void
    let onNewChat: () -> Void
    let onAccount: () -> Void
    @Binding var pendingSharedImport: SharedImport?
    @Binding var pendingDeepLinkedSessionID: String?
    @Binding var requestedNewChat: NewChatRequest?
    @Binding var requestedSessionFilter: SessionFilterRequest?

    @Environment(\.modelContext) var modelContext
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appColorPalette) var palette
    @Environment(\.appAccent) var accent
    @State var viewModel: SessionListViewModel
    @State var navigationState: SessionNavigationState
    @State var sessionPendingRename: SessionSummary?
    @State var sessionPendingDeletion: SessionSummary?
    @State var sessionPendingProjectCreation: SessionSummary?
    @State var sessionExportShareItem: SessionExportShareItem?
    @State var isPresentingProjectCreation = false
    @State var isPresentingAddServer = false
    @State var projectPendingDeletion: ProjectSummary?
    @State var projectPendingRename: ProjectSummary?
    @State var searchText = ""
    @State var isSearchVisible = false
    @State var isSearchFocused = false
    @State var searchChromeIsExpanded = false
    @State var selectedProjectID: String?
    @State var selectedBot: String?
    @State var pinnedOnly = false
    @State var scheduledHistoryOnly = false
    @State var isPresentingSessionFilters = false
    @State var shouldPresentProjectCreationAfterFiltersDismissal = false
    @State var sidebarScrollPosition: String?
    @State var didCompleteInitialLoad = false
    @State private var returnRefreshID: UUID?
    @State private var foregroundRefreshTask: Task<Void, Never>?
    @State var newChatCreationTask: Task<Void, Never>?
    @State var isSessionListVisible = false
    @FocusState var searchFieldIsFocused: Bool
    @AppStorage(SessionSidebarDisclosureSettings.profilesAreExpandedKey)
    var profilesAreExpanded = SessionSidebarDisclosureSettings.defaultProfilesAreExpanded
    @AppStorage(SessionSidebarDisclosureSettings.projectsAreExpandedKey)
    var projectsAreExpanded = SessionSidebarDisclosureSettings.defaultProjectsAreExpanded
    @AppStorage(SessionSidebarDisclosureSettings.scheduledSessionsAreExpandedKey)
    var scheduledSessionsAreExpanded = SessionSidebarDisclosureSettings.defaultScheduledSessionsAreExpanded
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) var showsSessionMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) var showsSessionWorkspace = true
    @AppStorage(SessionRowDisplaySettings.showCronSessionsKey) var showsCronSessions = true
    @AppStorage(SessionRowDisplaySettings.showSubagentSessionsKey)
    private var showsSubagentSessions = SessionRowDisplaySettings.defaultShowsSubagentSessions
    @AppStorage(SectionVisibilitySettings.tasksKey) var showsTasksSection = true
    @AppStorage(SectionVisibilitySettings.kanbanKey) var showsKanbanSection = true
    @AppStorage(SectionVisibilitySettings.skillsKey) var showsSkillsSection = true
    @AppStorage(SectionVisibilitySettings.memoryKey) var showsMemorySection = true
    @AppStorage(SectionVisibilitySettings.insightsKey) var showsInsightsSection = true
    @AppStorage(SectionVisibilitySettings.activeProfileKey) var showsActiveProfileSection = true
    @AppStorage(SectionVisibilitySettings.projectsKey) var showsProjectsSection = true
    // Per-server key (#19): the CLI toggle mirrors the active server's
    // `show_cli_sessions`, so its cached value must not leak across servers.
    // Configured in `init`, where the server URL is known.
    @AppStorage private var showsCliSessions: Bool
    @AppStorage private var showsClaudeCodeSessions: Bool
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) var tintsPrimaryActions = false
    @AppStorage(GlassPreference.isEnabledKey) private var isGlassEnabled = GlassPreference.defaultIsEnabled
    @AppStorage(SessionIdentitySettings.displayNameKey) var identityDisplayName = ""
    @AppStorage(SessionIdentitySettings.initialsKey) var identityInitials = ""
    @AppStorage(AppHaptics.isEnabledKey) var isHapticsEnabled = true

    init(
        authManager: AuthManager,
        server: URL,
        projectsEnabled: Bool = true,
        pendingSharedImport: Binding<SharedImport?> = .constant(nil),
        pendingDeepLinkedSessionID: Binding<String?> = .constant(nil),
        requestedNewChat: Binding<NewChatRequest?> = .constant(nil),
        requestedSessionFilter: Binding<SessionFilterRequest?> = .constant(nil),
        usesShellChrome: Bool = false,
        shellSurfaceVisitID: Int = 0,
        onConversationVisibilityChanged: @escaping (Bool) -> Void = { _ in },
        onNewChat: @escaping () -> Void = {},
        onAccount: @escaping () -> Void = {}
    ) {
        self.authManager = authManager
        self.server = server
        self.projectsEnabled = projectsEnabled
        self.usesShellChrome = usesShellChrome
        self.shellSurfaceVisitID = shellSurfaceVisitID
        self.onConversationVisibilityChanged = onConversationVisibilityChanged
        self.onNewChat = onNewChat
        self.onAccount = onAccount
        _pendingSharedImport = pendingSharedImport
        _pendingDeepLinkedSessionID = pendingDeepLinkedSessionID
        _requestedNewChat = requestedNewChat
        _requestedSessionFilter = requestedSessionFilter
        _viewModel = State(initialValue: SessionListViewModel(server: server))
        _navigationState = State(
            initialValue: SessionNavigationState(
                lastSelectedSessionID: shellSurfaceVisitID == 0
                    ? SessionNavigationPersistence.load(for: server)
                    : nil
            )
        )
        _showsCliSessions = AppStorage(
            wrappedValue: SessionRowDisplaySettings.showsCliSessions(for: server),
            SessionRowDisplaySettings.showCliSessionsKey(for: server)
        )
        _showsClaudeCodeSessions = AppStorage(
            wrappedValue: SessionRowDisplaySettings.showsClaudeCodeSessions(for: server),
            SessionRowDisplaySettings.showClaudeCodeSessionsKey(for: server)
        )
    }

    var body: some View {
        navigationContainer
            .sheet(
                isPresented: $isPresentingSessionFilters,
                onDismiss: presentPendingProjectCreationIfNeeded
            ) {
                NavigationStack {
                    SessionFiltersSheet(
                        selectedBot: $selectedBot,
                        pinnedOnly: $pinnedOnly,
                        scheduledHistoryOnly: $scheduledHistoryOnly,
                        selectedProjectID: $selectedProjectID,
                        botOptions: availableBotNames,
                        projects: viewModel.projects,
                        projectsEnabled: projectsEnabled && showsProjectsSection,
                        clearFilters: clearSessionFilters,
                        createProject: {
                            shouldPresentProjectCreationAfterFiltersDismissal = true
                            isPresentingSessionFilters = false
                        }
                    )
                }
                .presentationDetents([.medium, .large])
                .adaptiveFormPresentation()
            }
            .sheet(item: $sessionExportShareItem) { item in
                SessionExportShareSheet(fileURL: item.fileURL)
                    .presentationDetents([.medium, .large])
                    .adaptiveFormPresentation()
                    .ignoresSafeArea()
                    // The temp file lives in its own UUID directory (see
                    // SessionListViewModel.export); remove the directory once
                    // the share sheet is gone, shared and cancelled alike.
                    .onDisappear {
                        try? FileManager.default.removeItem(
                            at: item.fileURL.deletingLastPathComponent()
                        )
                    }
            }
            .sheet(item: $sessionPendingRename) { session in
                SessionRenameSheet(
                    initialTitle: SessionRowView.displayTitle(for: session),
                    isSaving: viewModel.isRenamingSession
                ) {
                    sessionPendingRename = nil
                } onSave: { title in
                    Task {
                        guard let session = sessionPendingRename else { return }

                        let didRename = await rename(session, to: title)
                        if didRename {
                            sessionPendingRename = nil
                        }
                    }
                }
                .presentationDetents([.height(180), .medium])
            }
            .sheet(item: $sessionPendingProjectCreation) { session in
                ProjectCreationSheet(
                    existingProjectCount: viewModel.projects.count,
                    isSaving: viewModel.isCreatingProject || viewModel.isMovingSession
                ) {
                    sessionPendingProjectCreation = nil
                } onSave: { name, color in
                    Task {
                        let didMove = await viewModel.createProject(
                            named: name,
                            color: color,
                            moving: session,
                            modelContext: modelContext
                        )
                        handleLastError()

                        if didMove {
                            sessionPendingProjectCreation = nil
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingProjectCreation) {
                ProjectCreationSheet(
                    existingProjectCount: viewModel.projects.count,
                    isSaving: viewModel.isCreatingProject
                ) {
                    isPresentingProjectCreation = false
                } onSave: { name, color in
                    Task {
                        let didCreate = await viewModel.createEmptyProject(
                            named: name,
                            color: color,
                            modelContext: modelContext
                        )
                        handleLastError()

                        if didCreate {
                            isPresentingProjectCreation = false
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(item: $projectPendingRename) { project in
                ProjectRenameSheet(
                    project: project,
                    isSaving: viewModel.isRenamingProject
                ) {
                    projectPendingRename = nil
                } onSave: { name, color in
                    Task {
                        let didRename = await viewModel.rename(project, named: name, color: color)
                        handleLastError()

                        if didRename {
                            projectPendingRename = nil
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingAddServer) {
                // Reuse #17's add-server flow directly as a power-user shortcut.
                // On success `addServer` switches the active server, which
                // rebuilds this stack via ContentView's `.id(server)` (#283).
                AddServerView(authManager: authManager)
            }
            .task {
                // Paint the saved sidebar before the first network await. This lets
                // stored-chat restoration begin immediately while the live refresh
                // reconciles in parallel.
                viewModel.prepareInitialCachedSessions(modelContext: modelContext)

                // Start the normal refresh immediately so a slow direct session
                // request cannot leave the sidebar empty. Deep-link resolution still
                // owns navigation precedence; stored selection restoration happens
                // after it, but before the network refresh must finish.
                await SessionListInitialLoad.run(
                    resolvePendingDeepLink: {
                        await openPendingDeepLinkedSessionIfNeeded()
                    },
                    refreshSessionsAndActiveProfile: {
                        await refreshSessionsAndActiveProfile(reconcileOpenTranscripts: true)
                    },
                    restoreLastSelectedSession: { clearsMissingSelection in
                        restoreLastSelectedSessionIfNeeded(
                            clearsMissingSelection: clearsMissingSelection
                        )
                    }
                )
                guard !Task.isCancelled else { return }
                didCompleteInitialLoad = true
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else {
                    foregroundRefreshTask?.cancel()
                    foregroundRefreshTask = nil
                    return
                }
                guard SessionListForegroundRefreshPolicy.shouldRefresh(
                    didCompleteInitialLoad: didCompleteInitialLoad,
                    sceneIsActive: true
                ) else { return }

                foregroundRefreshTask?.cancel()
                foregroundRefreshTask = Task { @MainActor in
                    await refreshSessionsAndActiveProfile(reconcileOpenTranscripts: true)
                    guard !Task.isCancelled, scenePhase == .active else { return }
                }
            }
            .onDisappear {
                isSessionListVisible = false
                viewModel.invalidateGatewayObservation()
                foregroundRefreshTask?.cancel()
                foregroundRefreshTask = nil
                newChatCreationTask?.cancel()
                newChatCreationTask = nil
            }
            .task(id: remoteSearchTaskID) {
                await viewModel.searchSessions(query: searchText, content: true, depth: 5)
            }
            .task(id: activeSessionMonitorTaskID) {
                await monitorActiveSessionRows()
            }
            .task(id: returnRefreshID) {
                guard returnRefreshID != nil else { return }
                await refreshSessionsAndActiveProfile(reconcileOpenTranscripts: true)
            }
            .onAppear {
#if DEBUG
                ChatPerformanceCadenceMonitor.end(.back)
#endif
                isSessionListVisible = true
                viewModel.setSidebarEditing(sidebarHasPendingEdit)
                viewModel.setSidebarDestructiveActionPending(sidebarHasPendingDestructiveAction)
                viewModel.startGatewayObservation()
                drainPendingExternalNewChatRequestsIfIdle()
                refreshAfterReturningIfNeeded()
                applyPendingSessionFilterIfNeeded()
                onConversationVisibilityChanged(navigationState.isConversationPresented)
            }
            .onChange(of: sidebarHasPendingEdit) { _, editing in
                viewModel.setSidebarEditing(editing)
            }
            .onChange(of: sidebarHasPendingDestructiveAction) { _, pending in
                viewModel.setSidebarDestructiveActionPending(pending)
            }
            .onChange(of: pendingSharedImport) {
                drainPendingExternalNewChatRequestsIfIdle()
            }
            .onChange(of: pendingDeepLinkedSessionID) {
                Task { await openPendingDeepLinkedSessionIfNeeded() }
            }
            .onChange(of: requestedNewChat) {
                drainPendingExternalNewChatRequestsIfIdle()
            }
            .onChange(of: requestedSessionFilter) {
                applyPendingSessionFilterIfNeeded()
            }
            .onChange(of: showsProjectsSection) {
                // The "All" button that clears a project filter lives in the
                // Projects header, so hiding the section mid-filter would strand
                // the list on one project with no way back (#189).
                guard !showsProjectsSection else { return }
                selectedProjectID = nil
            }
            .onChange(of: shellSurfaceVisitID) { _, newValue in
                guard usesShellChrome, newValue > 0 else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    navigationState.resetForShellSurfaceSwitch()
                }
                persistLastSelectedSession()
                onConversationVisibilityChanged(false)
            }
            .onChange(of: navigationState.destination) { oldValue, newValue in
                onConversationVisibilityChanged(navigationState.isConversationPresented)
                if case .session(let session) = newValue {
                    SessionReadStateStore.shared.markRead(session, server: server)
                }
                SessionListNewChatReturn.run(
                    from: oldValue,
                    to: newValue,
                    suppressEmptyPlaceholders: viewModel.removeEmptySidebarPlaceholders,
                    refreshSessions: refreshAfterReturningIfNeeded
                )
            }
            .refreshable {
                await refreshSessionsAndActiveProfile(reconcileOpenTranscripts: true)
            }
            .modifier(
                SessionActionConfirmations(
                    viewModel: viewModel,
                    sessionPendingDeletion: $sessionPendingDeletion,
                    projectPendingDeletion: $projectPendingDeletion,
                    deleteSession: { session in
                        Task { await delete(session) }
                    },
                    deleteProject: { project in
                        Task { await delete(project) }
                    }
                )
            )
            .focusedSceneValue(\.hermexSceneActions, sceneActions)
    }

    private var sidebarHasPendingEdit: Bool {
        sessionPendingRename != nil || projectPendingRename != nil || searchFieldIsFocused
    }

    private var sidebarHasPendingDestructiveAction: Bool {
        sessionPendingDeletion != nil || projectPendingDeletion != nil
    }

    var automatedSessionVisibility: AutomatedSessionVisibility {
        AutomatedSessionVisibility(
            showsCron: showsCronSessions,
            showsCli: showsCliSessions,
            showsClaudeCode: showsClaudeCodeSessions,
            showsSubagents: showsSubagentSessions
        )
    }

    var emptySessionsDescription: String? {
        if hasActiveSessionFilter {
            return String(localized: "Try another search or filter.")
        }

        return String(localized: "Tap Chat to start.")
    }

    var newSessionButtonSurface: AdaptiveGlassSurface {
        AdaptiveGlassSurface.resolve(
            liquidGlassAvailable: GlassPreference.isLiquidGlassSupported,
            isGlassEnabled: isGlassEnabled,
            reduceTransparency: reduceTransparency
        )
    }

    var newSessionButtonGlassTint: Color {
        if newSessionButtonUsesThemeColor {
            return selectedHeaderLogoColor
        }

        return colorScheme == .dark ? .white : .black
    }

    private var sceneActions: SemrehSceneActions {
        SemrehSceneActions(
            canCreateNewChat: !viewModel.isViewingCachedData
                && !viewModel.isCreatingSession
                && !navigationState.isCreatingNewChat,
            createNewChat: openNewChatFromKeyboard,
            searchSessions: openSearchFromKeyboard
        )
    }

    private func refreshAfterReturningIfNeeded() {
        guard didCompleteInitialLoad else { return }
        returnRefreshID = UUID()
    }

    func duplicate(_ session: SessionSummary) async {
        let duplicatedSession = await viewModel.duplicate(session, modelContext: modelContext)
        handleLastError()

        if let duplicatedSession {
            selectSession(duplicatedSession)
        }
    }

}
