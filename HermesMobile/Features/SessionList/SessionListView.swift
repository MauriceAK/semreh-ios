import SwiftUI
import SwiftData
import UIKit
import OSLog

@MainActor
struct SessionListView: View {
    private static let searchChromeIconVisualSize: CGFloat = 36
    private static let searchChromeIconHitTarget: CGFloat = 44

    @Bindable var authManager: AuthManager
    let server: URL
    let projectsEnabled: Bool
    let usesShellChrome: Bool
    let shellSurfaceVisitID: Int
    let onConversationVisibilityChanged: (Bool) -> Void
    let onNewChat: () -> Void
    let onAccount: () -> Void
    @Binding private var pendingSharedImport: SharedImport?
    @Binding private var pendingDeepLinkedSessionID: String?
    @Binding private var requestedNewChat: NewChatRequest?
    @Binding private var requestedSessionFilter: SessionFilterRequest?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appColorPalette) private var palette
    @Environment(\.appAccent) private var accent
    @State private var viewModel: SessionListViewModel
    @State private var navigationState: SessionNavigationState
    @State private var sessionPendingRename: SessionSummary?
    @State private var sessionPendingDeletion: SessionSummary?
    @State private var sessionPendingProjectCreation: SessionSummary?
    @State private var sessionExportShareItem: SessionExportShareItem?
    @State private var isPresentingProjectCreation = false
    @State private var isPresentingAddServer = false
    @State private var projectPendingDeletion: ProjectSummary?
    @State private var projectPendingRename: ProjectSummary?
    @State private var searchText = ""
    @State private var isSearchVisible = false
    @State private var isSearchFocused = false
    @State private var searchChromeIsExpanded = false
    @State private var selectedProjectID: String?
    @State private var selectedBot: String?
    @State private var pinnedOnly = false
    @State private var scheduledHistoryOnly = false
    @State private var isPresentingSessionFilters = false
    @State private var shouldPresentProjectCreationAfterFiltersDismissal = false
    @State private var sidebarScrollPosition: String?
    @State private var didCompleteInitialLoad = false
    @State private var returnRefreshID: UUID?
    @State private var foregroundRefreshTask: Task<Void, Never>?
    @State private var newChatCreationTask: Task<Void, Never>?
    @State private var isSessionListVisible = false
    @FocusState private var searchFieldIsFocused: Bool
    @AppStorage(SessionSidebarDisclosureSettings.profilesAreExpandedKey)
    private var profilesAreExpanded = SessionSidebarDisclosureSettings.defaultProfilesAreExpanded
    @AppStorage(SessionSidebarDisclosureSettings.projectsAreExpandedKey)
    private var projectsAreExpanded = SessionSidebarDisclosureSettings.defaultProjectsAreExpanded
    @AppStorage(SessionSidebarDisclosureSettings.scheduledSessionsAreExpandedKey)
    private var scheduledSessionsAreExpanded = SessionSidebarDisclosureSettings.defaultScheduledSessionsAreExpanded
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) private var showsSessionMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) private var showsSessionWorkspace = true
    @AppStorage(SessionRowDisplaySettings.showCronSessionsKey) private var showsCronSessions = true
    @AppStorage(SessionRowDisplaySettings.showSubagentSessionsKey)
    private var showsSubagentSessions = SessionRowDisplaySettings.defaultShowsSubagentSessions
    @AppStorage(SectionVisibilitySettings.tasksKey) private var showsTasksSection = true
    @AppStorage(SectionVisibilitySettings.kanbanKey) private var showsKanbanSection = true
    @AppStorage(SectionVisibilitySettings.skillsKey) private var showsSkillsSection = true
    @AppStorage(SectionVisibilitySettings.memoryKey) private var showsMemorySection = true
    @AppStorage(SectionVisibilitySettings.insightsKey) private var showsInsightsSection = true
    @AppStorage(SectionVisibilitySettings.activeProfileKey) private var showsActiveProfileSection = true
    @AppStorage(SectionVisibilitySettings.projectsKey) private var showsProjectsSection = true
    // Per-server key (#19): the CLI toggle mirrors the active server's
    // `show_cli_sessions`, so its cached value must not leak across servers.
    // Configured in `init`, where the server URL is known.
    @AppStorage private var showsCliSessions: Bool
    @AppStorage private var showsClaudeCodeSessions: Bool
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @AppStorage(GlassPreference.isEnabledKey) private var isGlassEnabled = GlassPreference.defaultIsEnabled
    @AppStorage(SessionIdentitySettings.displayNameKey) private var identityDisplayName = ""
    @AppStorage(SessionIdentitySettings.initialsKey) private var identityInitials = ""
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

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
                        await refreshSessionsAndActiveProfile(markRetainedHistoriesStale: true)
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
                    await refreshSessionsAndActiveProfile(markRetainedHistoriesStale: true)
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
                await refreshSessionsAndActiveProfile(markRetainedHistoriesStale: true)
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
#if DEBUG
                let refreshStartedAt = Date()
                let refreshLogger = Logger(subsystem: "com.maurice.semreh", category: "SessionListRefresh")
                refreshLogger.debug("event=pull_refresh_started rows=\(viewModel.sessions.count, privacy: .public)")
#endif
                // The selected chat will reconcile its own retained history
                // when opened; the list never reloads offscreen transcripts.
                await refreshSessionsAndActiveProfile(markRetainedHistoriesStale: true)
#if DEBUG
                refreshLogger.debug("event=pull_refresh_list_finished elapsedMs=\(Int(Date().timeIntervalSince(refreshStartedAt) * 1000), privacy: .public) rows=\(viewModel.sessions.count, privacy: .public) failed=\(viewModel.sessionLoadError != nil, privacy: .public)")
#endif
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

    @ViewBuilder
    private var navigationContainer: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                sessionListSurface
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
            } detail: {
                NavigationStack {
                    regularWidthDetail
                }
            }
            .navigationSplitViewStyle(.balanced)
            .id(navigationState.rootRevision)
        } else {
            NavigationStack {
                sessionListSurface
                    .navigationDestination(item: navigationDestinationBinding) { destination in
                        navigationDestination(destination)
                    }
            }
        }
    }

    private var sessionListSurface: some View {
        ZStack(alignment: .bottom) {
            SemrehBackdrop()
                .ignoresSafeArea()

            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if usesShellChrome {
                        shellSearchBar
                            .padding(.horizontal, 18)
                            .padding(.bottom, 10)
                    }
                }

            if !usesShellChrome, !isSearchingSessions {
                newSessionButton
                    .padding(.trailing, 24)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

        }
        .navigationTitle(usesShellChrome ? "Chats" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if usesShellChrome {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil", action: onNewChat)
                    Button(AppShellSettingsAction.accessibilityLabel, systemImage: AppShellSettingsAction.systemImage, action: onAccount)
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var regularWidthDetail: some View {
        if let destination = navigationState.destination {
            navigationDestination(destination)
        } else {
            ContentUnavailableView {
                Label("Select a Chat", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Choose a session from the sidebar or start a new chat.")
            } actions: {
                Button("New Chat", action: openNewChat)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func navigationDestination(_ destination: SessionNavigationDestination) -> some View {
        switch destination {
        case .session(let session):
            ChatView(
                session: session,
                server: server,
                onAPIError: authManager.handleAPIError,
                onParentBack: {
                    navigationState.clearDestination()
                },
                loadsInitialMessages: destination.loadsInitialMessages
            )
                .id(session.id)
        case .newChat(let session, let route):
            ChatView(
                session: session,
                server: server,
                onAPIError: authManager.handleAPIError,
                onParentBack: {
                    navigationState.clearDestination()
                },
                initialDraft: route.initialDraft,
                initialAttachments: route.initialAttachments,
                loadsInitialMessages: destination.loadsInitialMessages,
                autoStartsVoiceInput: route.autoStartsVoiceInput
            )
            .id(session.id)
        case .utility(let destination):
            utilityDestination(destination)
        }
    }

    @ViewBuilder
    private func utilityDestination(_ destination: SessionListUtilityDestination) -> some View {
        Group {
            switch destination {
            case .settings(let scrollTo):
                SettingsView(authManager: authManager, server: server, initialScrollTarget: scrollTo)
            case .tasks:
                TasksView(server: server, profile: viewModel.activeProfileName ?? "default", onAPIError: authManager.handleAPIError)
                    .id(viewModel.activeProfileName ?? "default")
            case .kanban:
                KanbanView(server: server, onAPIError: authManager.handleAPIError)
            case .skills:
                SkillsView(server: server, profile: viewModel.activeProfileName ?? "default", onAPIError: authManager.handleAPIError)
                    .id(viewModel.activeProfileName ?? "default")
            case .memory:
                MemoryView(server: server, profile: viewModel.activeProfileName ?? "default", onAPIError: authManager.handleAPIError)
                    .id(viewModel.activeProfileName ?? "default")
            case .insights:
                InsightsView(server: server, profile: viewModel.activeProfileName ?? "default", onAPIError: authManager.handleAPIError)
                    .id(viewModel.activeProfileName ?? "default")
            case .archived:
                let archiveProfile = viewModel.activeProfileName ?? "default"
                ArchivedSessionsView(
                    server: server,
                    profile: archiveProfile,
                    onAPIError: authManager.handleAPIError,
                    onSessionsChanged: {
                        await viewModel.refreshArchivedCountForProfile(archiveProfile)
                        handleLastError()
                    }
                )
            case .scheduled:
                ScheduledSessionsView(
                    viewModel: viewModel,
                    showsCronSessions: showsCronSessions,
                    showsMessageCount: showsSessionMessageCount,
                    showsWorkspace: showsSessionWorkspace,
                    selectedSessionID: horizontalSizeClass == .regular
                        ? navigationState.selectedSessionID
                        : nil,
                    actions: sessionRowActions
                )
            }
        }
        .adaptiveSecondaryNavigationTitle()
    }

    private var navigationDestinationBinding: Binding<SessionNavigationDestination?> {
        Binding(
            get: { navigationState.destination },
            set: { destination in
                guard destination == nil else { return }
                navigationState.clearDestination()
            }
        )
    }

    private var content: some View {
        let sessionGroups = scheduledSessionGroups
        let pinnedSessions = shellPinnedSessions

        return List {
            if usesShellChrome {
                sessionFilters
                    .sessionsScreenListRow()
            } else {
                header
                    .sessionsTopChromeListRow()
            }

            if viewModel.isViewingCachedData {
                if usesShellChrome {
                    shellOfflineStatus
                        .sessionsScreenListRow()
                } else {
                    OfflineCacheBanner()
                        .padding(.top, 16)
                        .sessionsScreenListRow()
                }
            }

            if let utilityRowsVisibility = SessionListUtilityRowsVisibilityPolicy.visibleSections(
                usesShellChrome: usesShellChrome,
                projectsEnabled: projectsEnabled && AppShellOrganizerPolicy.showsProjects(
                    isShell: usesShellChrome,
                    hasProjects: !viewModel.projects.isEmpty,
                    hasSelection: selectedProjectID != nil
                ),
                isSearchingSessions: isSearchingSessions,
                userVisibility: sidebarSectionVisibility
            ) {
                SessionSidebarUtilityRows(
                    viewModel: viewModel,
                    topPadding: 10,
                    automatedVisibility: automatedSessionVisibility,
                    sectionVisibility: utilityRowsVisibility,
                    profilesAreExpanded: $profilesAreExpanded,
                    projectsAreExpanded: $projectsAreExpanded,
                    selectedProjectID: $selectedProjectID,
                    projectPendingDeletion: $projectPendingDeletion,
                    projectPendingRename: $projectPendingRename,
                    openDestination: { destination in
                        navigationState.select(destination)
                    },
                    switchActiveProfile: { profile in
                        Task { await switchActiveProfile(profile) }
                    },
                    presentProjectCreation: {
                        isPresentingProjectCreation = true
                    }
                )
            }

            if !pinnedSessions.isEmpty {
                PinnedSessionStrip(
                    viewModel: viewModel,
                    sessions: pinnedSessions,
                    server: server,
                    actions: sessionRowActions
                )
                .sessionsScreenListRow(
                    insets: EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0)
                )
            }

            if !usesShellChrome, sessionGroups.showsDisclosure(isSearchActive: isSearchingSessions) {
                ScheduledSessionsDisclosure(
                    viewModel: viewModel,
                    sessions: sessionGroups.scheduled,
                    totalCount: sessionGroups.totalScheduledCount,
                    isSearchActive: isSearchingSessions,
                    showsMessageCount: showsSessionMessageCount,
                    showsWorkspace: showsSessionWorkspace,
                    selectedSessionID: horizontalSizeClass == .regular
                        ? navigationState.selectedSessionID
                        : nil,
                    userIsExpanded: $scheduledSessionsAreExpanded,
                    actions: sessionRowActions,
                    viewAll: { navigationState.select(.scheduled) }
                )
            }

            SessionListRowsSection(
                viewModel: viewModel,
                server: server,
                latestMessagePreviews: viewModel.cachedSessionPreviews,
                sessions: usesShellChrome ? shellHistorySessions : sessionGroups.ordinary,
                emptyTitle: emptySessionsTitle,
                emptyDescription: emptySessionsDescription,
                isSearchActive: isSearchingSessions,
                showsMessageCount: showsSessionMessageCount,
                showsWorkspace: showsSessionWorkspace,
                selectedSessionID: horizontalSizeClass == .regular
                    ? navigationState.selectedSessionID
                    : nil,
                actions: sessionRowActions,
                suppressEmptyState: usesShellChrome
                    ? !pinnedSessions.isEmpty
                    : !sessionGroups.scheduled.isEmpty,
                useMessagesStyle: usesShellChrome,
                showsSectionHeader: !usesShellChrome
            )

            if showsArchivedEntry {
                archivedEntryRow
                    .sessionsScreenListRow()
            }

            if !usesShellChrome {
                Color.clear
                    .frame(height: 104)
                    .sessionsScreenListRow()
                    .accessibilityHidden(true)
            }
        }
        .listStyle(.plain)
        // Let rows hug their content instead of the 44pt default minimum, so the
        // single-line utility/disclosure rows aren't padded out and stay aligned
        // with the tightly-packed navigation rows.
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .scrollPosition(id: $sidebarScrollPosition)
        .background { SemrehBackdrop().ignoresSafeArea() }
        .scrollDismissesKeyboard(.interactively)
        // Disclosure subrows are real List rows; drive their fold from the List
        // so insert/remove animates. Value-based so it works with @AppStorage.
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: profilesAreExpanded)
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: projectsAreExpanded)
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: scheduledSessionsAreExpanded)
    }

    private var header: some View {
        searchChrome
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(SemrehVisualTheme.energyGradient(for: palette))
                .frame(height: 2)
                .padding(.horizontal, 24)
                .offset(y: 11)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion), value: searchChromeIsExpanded)
        .animation(SessionListMotion.searchFocusAnimation(reduceMotion: reduceMotion), value: showsSearchClearButton)
        .onChange(of: searchFieldIsFocused) { _, newValue in
            handleSearchFieldFocusChange(newValue)
        }
    }

    private var shellOfflineStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .semibold))
            Text("Offline · cached sessions")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Offline, viewing cached sessions")
    }

    private var searchChrome: some View {
        HStack(spacing: searchChromeIsExpanded ? 8 : 4) {
            HapticButton {
                if searchChromeIsExpanded {
                    searchFieldIsFocused = true
                } else {
                    openSearch()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(searchChromeIsExpanded ? .secondary : .primary)
                    .frame(width: Self.searchChromeIconVisualSize, height: Self.searchChromeIconVisualSize)
                    .frame(width: Self.searchChromeIconHitTarget, height: Self.searchChromeIconHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searchChromeIsExpanded ? "Focus session search" : "Search sessions")
            .accessibilityHint("Shows the session search field.")
            .accessibilityHidden(searchChromeIsExpanded)

            searchTextField

            if showsSearchClearButton {
                searchClearButton
                    .transition(.scale.combined(with: .opacity))
            }

            searchTrailingButton
        }
        .padding(.vertical, 2)
        .frame(maxWidth: searchChromeIsExpanded ? .infinity : nil, alignment: .trailing)
        .sessionsChromeGlass(
            isInteractive: true,
            in: Capsule()
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
    }

    private var shellSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)

            if searchChromeIsExpanded {
                TextField("Search sessions", text: $searchText)
                    .font(AppFont.body())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFieldIsFocused)
                    .submitLabel(.done)
                    .lineLimit(1)
                    .accessibilityLabel("Search sessions")
            } else {
                Text("Search")
                    .font(AppFont.body())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 0)

            if searchChromeIsExpanded {
                Button {
                    closeSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close search")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .adaptiveGlass(
            .regular,
            isInteractive: true,
            fallbackMaterial: .ultraThinMaterial,
            in: Capsule()
        )
        .contentShape(Capsule())
        .onTapGesture {
            guard !searchChromeIsExpanded else { return }
            openSearch()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(searchChromeIsExpanded ? "Session search" : "Search sessions")
    }

    private var searchTextField: some View {
        TextField("Search sessions", text: $searchText)
            .font(AppFont.subheadline())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($searchFieldIsFocused)
            .submitLabel(.done)
            .lineLimit(1)
            .layoutPriority(1)
            .frame(maxWidth: searchChromeIsExpanded ? .infinity : 0)
            .opacity(searchChromeIsExpanded ? 1 : 0)
            .clipped()
            .accessibilityHidden(!searchChromeIsExpanded)
    }

    private var searchClearButton: some View {
        Button {
            searchText = ""
            searchFieldIsFocused = true
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
                .frame(width: Self.searchChromeIconVisualSize, height: Self.searchChromeIconVisualSize)
                .frame(width: Self.searchChromeIconHitTarget, height: Self.searchChromeIconHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
    }

    private var searchTrailingButton: some View {
        HapticButton(feedbackStyle: .medium) {
            if searchChromeIsExpanded {
                closeSearch()
            } else {
                navigationState.select(.settings(nil))
            }
        } label: {
            ZStack {
                Image(systemName: AppShellSettingsAction.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: Self.searchChromeIconVisualSize, height: Self.searchChromeIconVisualSize)
                    .opacity(searchChromeIsExpanded ? 0 : 1)
                    .scaleEffect(searchChromeIsExpanded ? 0.72 : 1)
                    .rotationEffect(.degrees(searchChromeIsExpanded ? -18 : 0))

                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: Self.searchChromeIconVisualSize, height: Self.searchChromeIconVisualSize)
                    .opacity(searchChromeIsExpanded ? 1 : 0)
                    .scaleEffect(searchChromeIsExpanded ? 1 : 0.72)
                    .rotationEffect(.degrees(searchChromeIsExpanded ? 0 : 18))
            }
            .frame(width: Self.searchChromeIconHitTarget, height: Self.searchChromeIconHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchChromeIsExpanded ? "Close search" : "Settings")
        .accessibilityHint(
            searchChromeIsExpanded
                ? "Closes search and clears the current query."
                : "Opens Settings. Long press to switch servers."
        )
        // Long-press the settings control to switch the active server, reusing #17's
        // switch/add actions. Suppressed while search is expanded so the
        // "close search" tap state is untouched (#283). The plain tap above is
        // preserved — `contextMenu` adds long-press without stealing the tap.
        .contextMenu {
            if !searchChromeIsExpanded {
                AvatarServerSwitcherMenu(
                    model: AvatarServerSwitcherModel(
                        servers: authManager.servers,
                        activeServerID: authManager.activeServerID
                    ),
                    switchToServer: { account in
                        authManager.switchActiveServer(to: account)
                    },
                    addServer: { isPresentingAddServer = true },
                    manageServers: { navigationState.select(.settings(.servers)) }
                )
            }
        }
    }

    private var newSessionButton: some View {
        HapticButton(feedbackStyle: .medium) {
            openNewChat()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.title3.weight(.semibold))

                Text("Chat")
                    .font(.headline.weight(.semibold))
            }
            .foregroundStyle(newSessionButtonForegroundColor)
            .padding(.horizontal, 22)
            .frame(height: 58)
            // Lock the hit region to the visible capsule so taps in the padding,
            // rounded ends, and icon↔text gap start a new chat instead of falling
            // through to the session row behind the FAB (issue #242).
            .contentShape(Capsule())
            .background {
                if let fill = newSessionButtonSolidThemeFill {
                    Capsule().fill(fill)
                }
            }
            .sessionsChromeGlass(
                isInteractive: true,
                tint: newSessionButtonGlassTint,
                fallbackMaterial: .regularMaterial,
                in: Capsule()
            )
        }
        .buttonStyle(SessionListFloatingChatButtonStyle())
        .disabled(
            viewModel.isViewingCachedData
                || viewModel.isCreatingSession
                || navigationState.isCreatingNewChat
        )
        .opacity(viewModel.isViewingCachedData ? 0.45 : 1)
        .accessibilityLabel("New Session")
    }

    private var visibleSessions: [SessionSummary] {
        viewModel.visibleSessions(
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedSessionVisibility
        )
    }

    private var scheduledSessionGroups: ScheduledSessionGroups {
        let groups = viewModel.scheduledSessionGroups(
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedSessionVisibility
        )
        guard usesShellChrome else { return groups }
        let ordinary = groups.ordinary.filter(matchesShellFilters)
        let scheduled = groups.scheduled.filter(matchesShellFilters)
        return ScheduledSessionGroups(
            ordinary: ordinary,
            scheduled: scheduled,
            totalScheduledCount: selectedBot == nil
                && !pinnedOnly
                && !scheduledHistoryOnly
                && selectedProjectID == nil
                ? groups.totalScheduledCount
                : scheduled.count
        )
    }

    private var shellHistorySessions: [SessionSummary] {
        // The shell is a history list. Scheduled rows stay in the same
        // recency-sorted collection, and the explicit scheduled-history filter
        // selects cron-origin rows without implying an active job.
        let sessions = visibleSessions.filter(matchesShellFilters)
        guard shouldShowPinnedSessionStrip else { return sessions }

        return PinnedSessionStripPolicy.ordinarySessions(
            from: sessions,
            excluding: shellPinnedSessions
        )
    }

    private var shellPinnedSessions: [SessionSummary] {
        guard PinnedSessionStripPolicy.shouldShow(
            usesShellChrome: usesShellChrome,
            isSearchActive: isSearchingSessions,
            hasActiveFilters: hasActiveSessionFilters,
            searchText: normalizedSearchText
        ) else {
            return []
        }

        return PinnedSessionStripPolicy.pinnedSessions(
            from: visibleSessions.filter(matchesShellFilters)
        )
    }

    private var shouldShowPinnedSessionStrip: Bool {
        !shellPinnedSessions.isEmpty
    }

    private func matchesShellFilters(_ session: SessionSummary) -> Bool {
        SessionShellFilter.matches(
            session,
            bot: selectedBot,
            pinnedOnly: pinnedOnly,
            scheduledHistoryOnly: scheduledHistoryOnly,
            projectID: selectedProjectID
        )
    }

    private var availableBotNames: [String] {
        var names = Set<String>(
            viewModel.sessions.compactMap { profile in
                guard let profile = profile.profile?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !profile.isEmpty else { return nil }
                return profile
            }
        )
        if let selectedBot, !selectedBot.isEmpty {
            names.insert(selectedBot)
        }
        return names.sorted()
    }

    private var selectedProjectName: String? {
        guard let selectedProjectID else { return nil }
        return viewModel.projects.first(where: { $0.projectId == selectedProjectID })?.name
            .flatMap { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            ?? String(localized: "Project")
    }

    private var hasActiveSessionFilters: Bool {
        selectedBot != nil || pinnedOnly || scheduledHistoryOnly || selectedProjectID != nil
    }

    private var activeSessionFilterSummary: String? {
        var parts: [String] = []
        if let selectedBot {
            parts.append(selectedBot)
        }
        if pinnedOnly {
            parts.append(String(localized: "Pinned"))
        }
        if scheduledHistoryOnly {
            parts.append(String(localized: "Scheduled history"))
        }
        if let selectedProjectName {
            parts.append(selectedProjectName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func clearSessionFilters() {
        selectedBot = nil
        pinnedOnly = false
        scheduledHistoryOnly = false
        selectedProjectID = nil
    }

    private var sessionFilters: some View {
        HStack(spacing: 8) {
            Button { isPresentingSessionFilters = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: hasActiveSessionFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                    Text("Filters")
                    if let activeSessionFilterSummary {
                        Text(activeSessionFilterSummary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Session filters")
            .accessibilityValue(activeSessionFilterSummary ?? "None")
            .accessibilityHint("Filters sessions by bot, pinned state, scheduled history, or project.")

            if hasActiveSessionFilters {
                Button("Clear", action: clearSessionFilters)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .accessibilityHint("Clears all session filters.")
            }
            Spacer(minLength: 0)
        }
        .font(AppFont.subheadline(weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
    }

    private var automatedSessionVisibility: AutomatedSessionVisibility {
        AutomatedSessionVisibility(
            showsCron: showsCronSessions,
            showsCli: showsCliSessions,
            showsClaudeCode: showsClaudeCodeSessions,
            showsSubagents: showsSubagentSessions
        )
    }

    private var sidebarSectionVisibility: SidebarSectionVisibility {
        SidebarSectionVisibility(
            tasks: showsTasksSection,
            kanban: showsKanbanSection,
            skills: showsSkillsSection,
            memory: showsMemorySection,
            insights: showsInsightsSection,
            activeProfile: showsActiveProfileSection,
            projects: showsProjectsSection
        )
    }

    /// Bottom-of-list entry to the Archived screen (issue #17). Hidden while
    /// searching, offline (cached data cannot fetch archived rows), and when the
    /// server reports zero archived sessions or omits `archived_count` (older
    /// server) — so the list is unchanged for users with nothing archived.
    private var showsArchivedEntry: Bool {
        guard !isSearchingSessions, !viewModel.isViewingCachedData else { return false }
        return (viewModel.archivedCount ?? 0) > 0
    }

    private var archivedEntryRow: some View {
        HapticButton {
            navigationState.select(.archived)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "archivebox")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                Text("Archived Sessions")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let archivedCount = viewModel.archivedCount {
                    Text("\(archivedCount)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .accessibilityHint("Shows archived sessions.")
    }

    private var emptySessionsTitle: String {
        if hasActiveSessionFilter {
            return String(localized: "No matching sessions")
        }

        return String(localized: "No sessions yet")
    }

    private var emptySessionsDescription: String? {
        if hasActiveSessionFilter {
            return String(localized: "Try another search or filter.")
        }

        return String(localized: "Tap Chat to start.")
    }

    private var hasActiveSessionFilter: Bool {
        hasActiveSessionFilters || !normalizedSearchText.isEmpty
    }

    private var showsSearchClearButton: Bool {
        searchChromeIsExpanded && !searchText.isEmpty
    }

    private func isActiveProfile(_ profile: ProfileSummary) -> Bool {
        guard let profileName = profile.normalizedName else { return false }

        if let activeProfileName = viewModel.activeProfileName {
            return profileName == activeProfileName
        }

        return profile.isActive == true
    }

    private var settingsInitials: String {
        SessionIdentitySettings.displayInitials(
            displayName: identityDisplayName,
            storedInitials: identityInitials,
            fallbackFullName: NSFullUserName()
        )
    }

    private var selectedHeaderLogoColor: Color {
        SemrehVisualTheme.brandActionColor(for: palette, accent: accent)
    }

    private var newSessionButtonUsesThemeColor: Bool {
        PrimaryActionTintSettings.usesThemeColor(
            isEnabled: tintsPrimaryActions,
            controlIsEnabled: !viewModel.isViewingCachedData
        )
    }

    private var newSessionButtonSurface: AdaptiveGlassSurface {
        AdaptiveGlassSurface.resolve(
            liquidGlassAvailable: GlassPreference.isLiquidGlassSupported,
            isGlassEnabled: isGlassEnabled,
            reduceTransparency: reduceTransparency
        )
    }

    // The glass tint is dropped on the material/opaque fallback surfaces, so a
    // themed button would otherwise show its contrast-picked foreground over a
    // neutral material (e.g. black-on-dark for a light theme color). Draw a
    // solid header-color fill there so the button stays themed and readable;
    // the liquid-glass surface keeps tinting via `newSessionButtonGlassTint`.
    private var newSessionButtonSolidThemeFill: Color? {
        guard newSessionButtonUsesThemeColor, newSessionButtonSurface != .liquidGlass else {
            return nil
        }

        return selectedHeaderLogoColor
    }

    private var newSessionButtonGlassTint: Color {
        if newSessionButtonUsesThemeColor {
            return selectedHeaderLogoColor
        }

        return colorScheme == .dark ? .white : .black
    }

    private var newSessionButtonForegroundColor: Color {
        if newSessionButtonUsesThemeColor {
            return SemrehVisualTheme.energyForeground(for: palette, accent: accent)
        }

        return colorScheme == .dark ? .black : .white
    }

    private var initialsAvatarForegroundColor: Color {
        SemrehVisualTheme.energyForeground(for: palette, accent: accent)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isSearchingSessions: Bool {
        isSearchVisible || isSearchFocused
    }

    private var remoteSearchTaskID: SessionSearchTaskID {
        SessionSearchTaskID(query: normalizedSearchText, isViewingCachedData: viewModel.isViewingCachedData)
    }

    private var activeSessionMonitorTaskID: ActiveSessionMonitorTaskID {
        let liveOwnerSessionIDs = OpenChatSessionStore.shared.liveSessionIDs(for: server)
        let activeSessions = visibleSessions.filter {
            SessionRowView.isActiveStreaming($0, liveOwnerSessionIDs: liveOwnerSessionIDs)
        }
        return ActiveSessionMonitorTaskID(
            hasActiveRows: !activeSessions.isEmpty || !liveOwnerSessionIDs.isEmpty,
            isViewingCachedData: viewModel.isViewingCachedData
        )
    }

    private var sessionRowActions: SessionListRowActions {
        SessionListRowActions(
            retryLoad: {
                Task { await refreshSessionsAndActiveProfile() }
            },
            open: { session in
                selectSession(session)
            },
            togglePinned: { session in
                Task { await togglePinned(session) }
            },
            archive: { session in
                Task { await archive(session) }
            },
            delete: { session in
                sessionPendingDeletion = session
            },
            rename: { session in
                sessionPendingRename = session
            },
            duplicate: { session in
                Task { await duplicate(session) }
            },
            move: { session, projectID in
                Task { await move(session, to: projectID) }
            },
            createProject: { session in
                sessionPendingProjectCreation = session
            },
            refreshProjects: {
                guard projectsEnabled else { return }
                Task { await viewModel.loadProjects() }
            },
            export: { session, format in
                Task { await export(session, format: format) }
            },
            projectsEnabled: projectsEnabled
        )
    }

    private func refreshSessionsAndActiveProfile(markRetainedHistoriesStale: Bool = false) async {
        await SidebarLoadOrdering.run(
            resolveActiveProfile: { await viewModel.loadActiveProfile() },
            loadSessions: { await loadSessions() }
        )
        guard !Task.isCancelled, markRetainedHistoriesStale,
              viewModel.sessionLoadError == nil else { return }
        OpenChatSessionStore.shared.markRetainedHistoriesStale(
            for: server, profile: viewModel.activeProfileName
        )
    }

    private func closeSearch() {
        searchText = ""
        searchFieldIsFocused = false
        isSearchFocused = false

        withAnimation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion)) {
            searchChromeIsExpanded = false
            isSearchVisible = false
        }
    }

    private func openSearch() {
        withAnimation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion)) {
            isSearchVisible = true
            searchChromeIsExpanded = true
        }
        searchFieldIsFocused = true
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

    private func openNewChatFromKeyboard() {
        guard !viewModel.isViewingCachedData,
              !viewModel.isCreatingSession,
              !navigationState.isCreatingNewChat
        else { return }
        openNewChat()
    }

    private func openSearchFromKeyboard() {
        searchFieldIsFocused = false

        if horizontalSizeClass != .regular {
            navigationState.clearDestination()
        }

        Task { @MainActor in
            await Task.yield()
            openSearch()
        }
    }

    /// Applies a one-shot profile filter from Bot details. This only changes the
    /// Sessions list predicate; it never switches the server's active profile.
    private func applyPendingSessionFilterIfNeeded() {
        guard let request = requestedSessionFilter else { return }
        requestedSessionFilter = nil
        guard let route = SessionFilterRoutePolicy.profileHistoryRoute(profileName: request.profileName) else {
            return
        }

        selectedBot = route.profileName
        pinnedOnly = route.pinnedOnly
        scheduledHistoryOnly = route.scheduledHistoryOnly
        selectedProjectID = route.projectID
        searchText = route.searchText
        closeSearch()
    }

    private func presentPendingProjectCreationIfNeeded() {
        guard shouldPresentProjectCreationAfterFiltersDismissal else { return }
        shouldPresentProjectCreationAfterFiltersDismissal = false
        isPresentingProjectCreation = true
    }

    private func handleSearchFieldFocusChange(_ isFocused: Bool) {
        guard isFocused else {
            isSearchFocused = false
            return
        }

        guard searchChromeIsExpanded || isSearchVisible else {
            searchFieldIsFocused = false
            isSearchFocused = false
            return
        }

        isSearchFocused = true
    }

    private func refreshAfterReturningIfNeeded() {
        guard didCompleteInitialLoad else { return }
        returnRefreshID = UUID()
    }

    private func monitorActiveSessionRows() async {
        while !Task.isCancelled {
            let taskID = activeSessionMonitorTaskID
            guard taskID.hasActiveRows, !taskID.isViewingCachedData else { return }

            do {
                try await Task.sleep(nanoseconds: 15_000_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            let refreshResult = await viewModel.refreshActiveSessionStatesIfNeeded(
                modelContext: modelContext
            )
            if refreshResult == .reloaded || refreshResult == .failed {
                handleLastError()
            }
        }
    }

    @MainActor
    private func switchActiveProfile(_ profile: ProfileSummary) async {
        let didSwitch = await viewModel.switchActiveProfile(profile)
        handleLastError()

        guard didSwitch else { return }

        withAnimation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion)) {
            profilesAreExpanded = false
        }

        await loadSessions()
    }

    private func loadSessions() async {
        await viewModel.load(modelContext: modelContext)
        guard !Task.isCancelled else { return }
        handleLastError()

        if projectsEnabled, !viewModel.isViewingCachedData {
            await viewModel.loadProjects()
            guard !Task.isCancelled else { return }
            handleLastError()
        }
    }

    private func togglePinned(_ session: SessionSummary) async {
        let didChangePinState = await viewModel.setPinned(
            !(session.pinned ?? false),
            for: session,
            modelContext: modelContext,
            animation: SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion)
        )
        handleLastError()

        if didChangePinState {
            SessionHaptics.pinStateChanged(isEnabled: isHapticsEnabled)
        }
    }

    private func archive(_ session: SessionSummary) async {
        let didArchive = await viewModel.archive(
            session,
            modelContext: modelContext,
            animation: SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion)
        )
        handleLastError()

        if didArchive {
            removeSessionFromNavigation(session)
            SessionHaptics.archiveStateChanged(isEnabled: isHapticsEnabled)
        }
    }

    private func delete(_ session: SessionSummary) async {
        await SessionHaptics.commitSessionDeletion(isEnabled: isHapticsEnabled) {
            let didDelete = await viewModel.delete(
                session,
                modelContext: modelContext,
                animation: SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion)
            )
            handleLastError()

            if didDelete {
                removeSessionFromNavigation(session)
            }
        }
    }

    private func rename(_ session: SessionSummary, to title: String) async -> Bool {
        let didChangeTitle = normalizedTitle(title) != normalizedTitle(session.title)
        let didRename = await viewModel.rename(session, to: title, modelContext: modelContext)
        handleLastError()

        if didRename, didChangeTitle {
            SessionHaptics.sessionRenamed(isEnabled: isHapticsEnabled)
        }

        return didRename
    }

    private func duplicate(_ session: SessionSummary) async {
        let duplicatedSession = await viewModel.duplicate(session, modelContext: modelContext)
        handleLastError()

        if let duplicatedSession {
            selectSession(duplicatedSession)
        }
    }

    private func move(_ session: SessionSummary, to projectID: String?) async {
        await viewModel.move(session, to: projectID, modelContext: modelContext)
        handleLastError()
    }

    private func export(_ session: SessionSummary, format: SessionExportFormat) async {
        let fileURL = await viewModel.export(session, format: format)
        handleLastError()

        if let fileURL {
            sessionExportShareItem = SessionExportShareItem(fileURL: fileURL)
        }
    }

    private func delete(_ project: ProjectSummary) async {
        let deletedProjectID = project.projectId
        let didDelete = await viewModel.delete(project, modelContext: modelContext)
        handleLastError()

        if didDelete, selectedProjectID == deletedProjectID {
            selectedProjectID = nil
        }
    }

    private func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func handleLastError() {
        if let lastError = viewModel.lastError {
            authManager.handleAPIError(lastError)
        }
    }

    private func openPendingSharedImportIfNeeded() {
        guard let sharedImport = pendingSharedImport else {
            return
        }

        let draft = HermesShareDraft.composerDraft(from: sharedImport.draft)
        guard !draft.isEmpty || !sharedImport.attachments.isEmpty else {
            pendingSharedImport = nil
            return
        }

        guard startNewChat(
            PendingNewChatRoute(
                initialDraft: draft,
                initialAttachments: sharedImport.attachments
            )
        ) else { return }
        pendingSharedImport = nil
    }

    /// Awaited (not fire-and-forget) so the cold-start `.task` can resolve it before
    /// `restoreLastSelectedSessionIfNeeded()` — otherwise the restore races the deep
    /// link's network load and wins with the previous session.
    private func openPendingDeepLinkedSessionIfNeeded() async {
        guard !Task.isCancelled else { return }

        while let sessionID = navigationState.beginDeepLinkedSessionLoad(
            id: pendingDeepLinkedSessionID
        ) {
            pendingDeepLinkedSessionID = nil
            await openDeepLinkedSession(id: sessionID)
            navigationState.finishDeepLinkedSessionLoad(id: sessionID)
            guard !Task.isCancelled else { return }
        }
    }

    private func openDeepLinkedSession(id sessionID: String) async {
        if let loadedSession = viewModel.sessions.first(where: { $0.sessionId == sessionID }) {
            selectSession(loadedSession)
            return
        }

        let session = await viewModel.loadSessionForDeepLink(id: sessionID, modelContext: modelContext)
        // Re-checked post-await: the view (and this task) may have been torn down —
        // e.g. dismissed, or the active server changed under `.id(server)` — while
        // the network load was in flight. Selecting or persisting for a session
        // whose owning view no longer exists is stale work, not a real navigation.
        guard !Task.isCancelled else { return }
        if let session {
            selectSession(session)
        }
        handleLastError()
    }

    /// Opens the New Chat composer in response to the "New Chat" App Intents (#337/#338),
    /// mirroring the "+" button. Carries `autoStartsVoiceInput` so the voice variant begins
    /// dictation once the composer appears. The request is cleared so it fires once per
    /// invocation.
    private func openRequestedNewChatIfNeeded() {
        guard let request = requestedNewChat else { return }
        guard startNewChat(
            PendingNewChatRoute(
                autoStartsVoiceInput: request.autoStartsVoiceInput,
                profileName: request.profileName
            )
        ) else { return }
        requestedNewChat = nil
    }

    private func openNewChat() {
        startNewChat(PendingNewChatRoute())
    }

    @discardableResult
    private func startNewChat(_ route: PendingNewChatRoute) -> Bool {
        guard !viewModel.isViewingCachedData,
              !viewModel.isCreatingSession,
              navigationState.beginNewChatCreation(route)
        else { return false }

#if DEBUG
        ChatPerformanceCadenceMonitor.begin(.entry)
#endif
        newChatCreationTask?.cancel()
        newChatCreationTask = Task { @MainActor in
            let session = await viewModel.createSession(
                modelContext: modelContext,
                profile: route.profileName
            )
            guard !Task.isCancelled else {
                navigationState.cancelNewChatCreation(for: route)
                newChatCreationTask = nil
                drainPendingExternalNewChatRequestsIfIdle()
                return
            }

            if let session {
                SessionHaptics.sessionCreated(isEnabled: isHapticsEnabled)
                if navigationState.completeNewChatCreation(session, for: route) {
                    persistLastSelectedSession()
                }
            } else {
                navigationState.cancelNewChatCreation(for: route)
                handleLastError()
            }
            newChatCreationTask = nil
            drainPendingExternalNewChatRequestsIfIdle()
        }
        return true
    }

    private func drainPendingExternalNewChatRequestsIfIdle() {
        guard isSessionListVisible,
              !viewModel.isViewingCachedData,
              !viewModel.isCreatingSession,
              !navigationState.isCreatingNewChat
        else { return }

        while let next = SessionNewChatExternalRequestPolicy.next(
            sharedImportPending: pendingSharedImport != nil,
            appIntentPending: requestedNewChat != nil
        ) {
            switch next {
            case .sharedImport:
                openPendingSharedImportIfNeeded()
            case .appIntent:
                openRequestedNewChatIfNeeded()
            }

            if navigationState.isCreatingNewChat || viewModel.isCreatingSession {
                return
            }
        }
    }

    private func selectSession(_ session: SessionSummary) {
        // The list remains mounted behind the detail. Do not carry its keyboard
        // focus into the conversation or resurrect it when returning to Chats.
        searchFieldIsFocused = false
#if DEBUG
        ChatPerformanceCadenceMonitor.begin(.entry)
#endif
        navigationState.select(session)
        persistLastSelectedSession()
    }

    private func removeSessionFromNavigation(_ session: SessionSummary) {
        navigationState.remove(sessionID: session.sessionId)
        persistLastSelectedSession()
    }

    private func restoreLastSelectedSessionIfNeeded(clearsMissingSelection: Bool) {
        if clearsMissingSelection, viewModel.sessionLoadError == nil {
            navigationState.reconcileAuthoritativeSelection(
                from: viewModel.sessions,
                pendingDeepLinkedSessionID: pendingDeepLinkedSessionID
            )
        } else {
            navigationState.restoreIfNeeded(
                from: viewModel.sessions,
                clearsMissingSelection: false,
                pendingDeepLinkedSessionID: pendingDeepLinkedSessionID
            )
        }
        persistLastSelectedSession()
    }

    private func persistLastSelectedSession() {
        SessionNavigationPersistence.save(navigationState.lastSelectedSessionID, for: server)
    }

}

/// Chooses the compact shell-only pinned strip without changing the server
/// session model. Pinned identity is a conversation ID, never a profile: two
/// chats using the same bot therefore remain separate entries.
enum PinnedSessionStripPolicy {
    static func shouldShow(
        usesShellChrome: Bool,
        isSearchActive: Bool,
        hasActiveFilters: Bool,
        searchText: String
    ) -> Bool {
        usesShellChrome
            && !isSearchActive
            && !hasActiveFilters
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func pinnedSessions(from sessions: [SessionSummary]) -> [SessionSummary] {
        var seenIDs = Set<String>()

        return sessions.filter { session in
            guard session.pinned == true else { return false }
            return seenIDs.insert(sessionIdentity(for: session)).inserted
        }
    }

    static func ordinarySessions(
        from sessions: [SessionSummary],
        excluding pinnedSessions: [SessionSummary]
    ) -> [SessionSummary] {
        let pinnedIDs = Set(pinnedSessions.map { sessionIdentity(for: $0) })
        var seenIDs = Set<String>()

        return sessions.filter { session in
            let identity = sessionIdentity(for: session)
            guard !pinnedIDs.contains(identity) else { return false }
            return seenIDs.insert(identity).inserted
        }
    }

    static func shortTitle(for session: SessionSummary, maxCharacters: Int = 18) -> String {
        let title = SessionRowView.displayTitle(for: session)
        guard maxCharacters > 1, title.count > maxCharacters else { return title }
        return String(title.prefix(maxCharacters - 1)) + "…"
    }

    static func accessibilityLabel(for session: SessionSummary) -> String {
        let title = SessionRowView.displayTitle(for: session)
        let bot: String
        if let profile = session.profile {
            let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
            bot = trimmedProfile.isEmpty ? "default" : trimmedProfile
        } else {
            bot = "default"
        }
        return "\(title), bot \(bot)"
    }

    private static func sessionIdentity(for session: SessionSummary) -> String {
        if let sessionID = session.sessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            return "session:\(sessionID)"
        }

        return "fallback:\(session.id)"
    }
}

private struct PinnedSessionStrip: View {
    let viewModel: SessionListViewModel
    let sessions: [SessionSummary]
    let server: URL
    let actions: SessionListRowActions

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(sessions) { session in
                    PinnedSessionStripItem(
                        viewModel: viewModel,
                        session: session,
                        server: server,
                        actions: actions
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
        // Keep the compact baseline while allowing the caption to grow under
        // Dynamic Type instead of clipping the strip at its fixed baseline.
        .frame(minHeight: 76)
        .accessibilityElement(children: .contain)
    }
}

private struct PinnedSessionStripItem: View {
    let viewModel: SessionListViewModel
    let session: SessionSummary
    let server: URL
    let actions: SessionListRowActions

    private var actionCapabilities: SessionRowActionPolicy.Capabilities {
        SessionRowActionPolicy.Capabilities(
            isSearchOnlySession: viewModel.isSearchOnlySession(session),
            isViewingCachedData: viewModel.isViewingCachedData
        )
    }

    var body: some View {
        Button {
            actions.open(session)
        } label: {
            VStack(spacing: 3) {
                avatar
                    .frame(width: 48, height: 48)

                Text(PinnedSessionStripPolicy.shortTitle(for: session))
                    .font(AppFont.caption2(weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 76)
            }
            .frame(width: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PinnedSessionStripPolicy.accessibilityLabel(for: session))
        .accessibilityHint("Opens this conversation.")
        .contextMenu {
            SessionRowContextMenu(
                session: session,
                projects: viewModel.projects,
                isViewingCachedData: viewModel.isViewingCachedData,
                isRenamingSession: viewModel.isRenamingSession,
                isCreatingProject: viewModel.isCreatingProject,
                isMovingSession: viewModel.isMovingSession,
                isLoadingProjects: viewModel.isLoadingProjects,
                isMutating: viewModel.isMutating(session),
                capabilities: actionCapabilities,
                actions: actions
            )
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let identity = BirdAvatarIdentity(server: server, profile: session.profile) {
            BirdAvatarView(identity: identity)
        } else {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.28))
                Text(fallbackInitials)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .overlay {
                Circle()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            }
        }
    }

    private var fallbackInitials: String {
        let title = SessionRowView.displayTitle(for: session)
        let words = title.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        if words.count > 1 {
            return String(words.prefix(2).compactMap(\.first)).uppercased()
        }

        return String(title.prefix(2)).uppercased()
    }
}

/// Compact native filter surface for the shell Sessions list. The controls are
/// deliberately local: they only change the existing sidebar predicates and do
/// not introduce a new server-side filter model.
private struct SessionFiltersSheet: View {
    @Binding var selectedBot: String?
    @Binding var pinnedOnly: Bool
    @Binding var scheduledHistoryOnly: Bool
    @Binding var selectedProjectID: String?

    let botOptions: [String]
    let projects: [ProjectSummary]
    let projectsEnabled: Bool
    let clearFilters: () -> Void
    let createProject: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Picker("Bot", selection: $selectedBot) {
                    Text("All bots").tag(nil as String?)
                    ForEach(botOptions, id: \.self) { name in
                        Text(name).tag(Optional(name))
                    }
                }
            } header: {
                Text("Bot")
            }

            Section {
                Toggle("Pinned only", isOn: $pinnedOnly)
                Toggle("Scheduled history", isOn: $scheduledHistoryOnly)
                Text("Scheduled history shows past cron-origin sessions; it does not indicate an active job.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("History")
            }

            if projectsEnabled {
                Section {
                    Button {
                        selectedProjectID = nil
                    } label: {
                        filterChoiceLabel(
                            title: String(localized: "All projects"),
                            systemImage: "square.grid.2x2",
                            isSelected: selectedProjectID == nil
                        )
                    }
                    .buttonStyle(.plain)

                    ForEach(projects) { project in
                        Button {
                            selectedProjectID = project.projectId
                        } label: {
                            filterChoiceLabel(
                                title: projectDisplayName(project),
                                systemImage: "folder",
                                isSelected: selectedProjectID == project.projectId
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(project.projectId == nil)
                    }

                    Button("New project", systemImage: "folder.badge.plus", action: createProject)
                } header: {
                    Text("Project")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background { SemrehBackdrop().ignoresSafeArea() }
        .navigationTitle("Filters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Clear", action: clearFilters)
                    .disabled(!hasActiveFilters)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var hasActiveFilters: Bool {
        selectedBot != nil
            || pinnedOnly
            || scheduledHistoryOnly
            || selectedProjectID != nil
    }

    private func filterChoiceLabel(title: String, systemImage: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .frame(minHeight: 30)
    }

    private func projectDisplayName(_ project: ProjectSummary) -> String {
        let name = project.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else {
            return String(localized: "Untitled Project")
        }
        return name
    }
}

enum SessionListForegroundRefreshPolicy {
    static func shouldRefresh(
        didCompleteInitialLoad: Bool,
        sceneIsActive: Bool
    ) -> Bool {
        didCompleteInitialLoad && sceneIsActive
    }
}

enum SessionListInitialLoad {
    @MainActor
    static func run(
        resolvePendingDeepLink: @escaping @MainActor () async -> Void,
        refreshSessionsAndActiveProfile: @escaping @MainActor () async -> Void,
        restoreLastSelectedSession: @escaping @MainActor (_ clearsMissingSelection: Bool) async -> Void
    ) async {
        async let initialRefresh: Void = refreshSessionsAndActiveProfile()
        await resolvePendingDeepLink()
        guard !Task.isCancelled else { return }
        // Cached rows are optimistic and may be empty or stale. Preserve the
        // persisted selection until the live list becomes authoritative.
        await restoreLastSelectedSession(false)
        await initialRefresh
        guard !Task.isCancelled else { return }
        // Reconcile against the authoritative list too. The first pass restores
        // instantly from cache; this second pass restores an empty/expired cache
        // and evicts a cache-restored session that disappeared on the server.
        await restoreLastSelectedSession(true)
    }
}

enum SidebarLoadOrdering {
    @MainActor
    static func run(
        resolveActiveProfile: @escaping @MainActor () async -> Void,
        loadSessions: @escaping @MainActor () async -> Void,
        loadProjects: (@MainActor () async -> Void)? = nil
    ) async {
        await resolveActiveProfile()
        guard !Task.isCancelled else { return }
        await loadSessions()
        guard !Task.isCancelled else { return }
        await loadProjects?()
    }
}

enum SessionListNewChatReturn {
    static func run(
        from oldValue: SessionNavigationDestination?,
        to newValue: SessionNavigationDestination?,
        suppressEmptyPlaceholders: () -> Void,
        refreshSessions: () -> Void
    ) {
        guard case .newChat = oldValue else { return }
        if case .newChat = newValue { return }

        // Keep this synchronous so an empty Untitled placeholder cannot flash
        // during the navigation transition. The refresh then adopts the server's
        // latest metadata for a new chat that has become contentful.
        suppressEmptyPlaceholders()
        refreshSessions()
    }
}

struct SemrehHeaderLogo: View {
    static let productName = ""
    static let productDescriptor = ""
    static let accessibilityLabelText = ""
    static let showsPortraitMedallion = false
    static let showsProductWordmark = false

    var body: some View {
        EmptyView()
    }
}

/// A request from `ContentView` to open the New Chat composer. Carries whether voice
/// dictation should auto-start (the "New Chat with Voice" App Intent, #338) and an optional
/// profile name to pin the new session to (the "New Chat in <Profile>" App Intent, #339).
/// A fresh `id` each time so a repeat invocation re-triggers navigation even if the previous
/// value lingers.
struct NewChatRequest: Equatable {
    let id: UUID
    let autoStartsVoiceInput: Bool
    /// When set, the new session is created pinned to this profile; nil uses the server's
    /// active profile (the plain "+" / "New Chat" behavior).
    let profileName: String?

    init(autoStartsVoiceInput: Bool = false, profileName: String? = nil) {
        self.id = UUID()
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
    }
}

struct PendingNewChatRoute: Identifiable, Hashable {
    let id = UUID()
    let initialDraft: String
    let initialAttachments: [SharedAttachmentImport]
    /// When true, the composer auto-starts voice dictation on appear (#338).
    let autoStartsVoiceInput: Bool
    /// When set, the new session is created pinned to this profile (#339).
    let profileName: String?

    init(
        initialDraft: String = "",
        initialAttachments: [SharedAttachmentImport] = [],
        autoStartsVoiceInput: Bool = false,
        profileName: String? = nil
    ) {
        self.initialDraft = initialDraft
        self.initialAttachments = initialAttachments
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
    }

    static func == (lhs: PendingNewChatRoute, rhs: PendingNewChatRoute) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum SessionListUtilityDestination: Hashable, Identifiable {
    /// Optional section to scroll to when Settings opens — "Manage Servers"
    /// passes `.servers`, a plain avatar tap passes `nil` (#283).
    case settings(SettingsScrollAnchor?)
    case tasks
    case kanban
    case skills
    case memory
    case insights
    /// Archived sessions screen (issue #17), also reachable from Settings.
    case archived
    case scheduled

    var id: Self { self }
}

private struct SessionSearchTaskID: Hashable {
    let query: String
    let isViewingCachedData: Bool
}

private struct ActiveSessionMonitorTaskID: Hashable {
    let hasActiveRows: Bool
    let isViewingCachedData: Bool
}

#Preview("Sessions Header") {
    Color.clear
        .frame(height: 80)
        .padding(24)
        .background(Color.black)
        .preferredColorScheme(.dark)
}
