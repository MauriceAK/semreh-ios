import SwiftUI
import SwiftData
import UIKit

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
    @Binding var pendingSharedImport: SharedImport?
    @Binding var pendingDeepLinkedSessionID: String?
    @Binding var requestedNewChat: NewChatRequest?
    @Binding var requestedSessionFilter: SessionFilterRequest?

    @Environment(\.modelContext) var modelContext
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.scenePhase) var scenePhase
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
    @State var returnRefreshID: UUID?
    @State var foregroundRefreshTask: Task<Void, Never>?
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
    var showsSubagentSessions = SessionRowDisplaySettings.defaultShowsSubagentSessions
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
    @AppStorage var showsCliSessions: Bool
    @AppStorage var showsClaudeCodeSessions: Bool
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) var tintsPrimaryActions = false
    @AppStorage(GlassPreference.isEnabledKey) var isGlassEnabled = GlassPreference.defaultIsEnabled
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

    var sidebarHasPendingEdit: Bool {
        sessionPendingRename != nil || projectPendingRename != nil || searchFieldIsFocused
    }

    var sidebarHasPendingDestructiveAction: Bool {
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

    var sidebarSectionVisibility: SidebarSectionVisibility {
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

    var emptySessionsDescription: String? {
        if hasActiveSessionFilter {
            return String(localized: "Try another search or filter.")
        }

        return String(localized: "Tap Chat to start.")
    }

    func isActiveProfile(_ profile: ProfileSummary) -> Bool {
        guard let profileName = profile.normalizedName else { return false }

        if let activeProfileName = viewModel.activeProfileName {
            return profileName == activeProfileName
        }

        return profile.isActive == true
    }

    var newSessionButtonSurface: AdaptiveGlassSurface {
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
    var newSessionButtonSolidThemeFill: Color? {
        guard newSessionButtonUsesThemeColor, newSessionButtonSurface != .liquidGlass else {
            return nil
        }

        return selectedHeaderLogoColor
    }

    var newSessionButtonGlassTint: Color {
        if newSessionButtonUsesThemeColor {
            return selectedHeaderLogoColor
        }

        return colorScheme == .dark ? .white : .black
    }

    func refreshSessionsAndActiveProfile(reconcileOpenTranscripts: Bool = false) async {
        await SidebarLoadOrdering.run(
            resolveActiveProfile: { await viewModel.loadActiveProfile() },
            loadSessions: { await loadSessions() }
        )
        guard !Task.isCancelled, reconcileOpenTranscripts else { return }
        _ = await OpenChatSessionStore.shared.refreshOpenSessions(
            for: server,
            modelContext: modelContext
        )
    }

    var sceneActions: SemrehSceneActions {
        SemrehSceneActions(
            canCreateNewChat: !viewModel.isViewingCachedData
                && !viewModel.isCreatingSession
                && !navigationState.isCreatingNewChat,
            createNewChat: openNewChatFromKeyboard,
            searchSessions: openSearchFromKeyboard
        )
    }

    func refreshAfterReturningIfNeeded() {
        guard didCompleteInitialLoad else { return }
        returnRefreshID = UUID()
    }

    @MainActor
    func switchActiveProfile(_ profile: ProfileSummary) async {
        let didSwitch = await viewModel.switchActiveProfile(profile)
        handleLastError()

        guard didSwitch else { return }

        withAnimation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion)) {
            profilesAreExpanded = false
        }

        await loadSessions()
    }

    func togglePinned(_ session: SessionSummary) async {
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

    func archive(_ session: SessionSummary) async {
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

    func delete(_ session: SessionSummary) async {
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

    func rename(_ session: SessionSummary, to title: String) async -> Bool {
        let didChangeTitle = normalizedTitle(title) != normalizedTitle(session.title)
        let didRename = await viewModel.rename(session, to: title, modelContext: modelContext)
        handleLastError()

        if didRename, didChangeTitle {
            SessionHaptics.sessionRenamed(isEnabled: isHapticsEnabled)
        }

        return didRename
    }

    func duplicate(_ session: SessionSummary) async {
        let duplicatedSession = await viewModel.duplicate(session, modelContext: modelContext)
        handleLastError()

        if let duplicatedSession {
            selectSession(duplicatedSession)
        }
    }

    func move(_ session: SessionSummary, to projectID: String?) async {
        await viewModel.move(session, to: projectID, modelContext: modelContext)
        handleLastError()
    }

    func export(_ session: SessionSummary, format: SessionExportFormat) async {
        let fileURL = await viewModel.export(session, format: format)
        handleLastError()

        if let fileURL {
            sessionExportShareItem = SessionExportShareItem(fileURL: fileURL)
        }
    }

    func delete(_ project: ProjectSummary) async {
        let deletedProjectID = project.projectId
        let didDelete = await viewModel.delete(project, modelContext: modelContext)
        handleLastError()

        if didDelete, selectedProjectID == deletedProjectID {
            selectedProjectID = nil
        }
    }

    func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func handleLastError() {
        if let lastError = viewModel.lastError {
            authManager.handleAPIError(lastError)
        }
    }

}
