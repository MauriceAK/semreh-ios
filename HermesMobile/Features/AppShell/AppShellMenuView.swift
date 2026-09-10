import SwiftUI
import SwiftData

@MainActor
struct ControlView: View {
    @Bindable var authManager: AuthManager
    let server: URL
    let projectsEnabled: Bool
    let isActive: Bool
    let onNestedDestinationVisibilityChanged: (Bool) -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var viewModel: SessionListViewModel
    @State private var navigationState = ControlNavigationState()
    @State private var profilesAreExpanded = SessionSidebarDisclosureSettings.defaultProfilesAreExpanded
    @State private var projectsAreExpanded = SessionSidebarDisclosureSettings.defaultProjectsAreExpanded
    @State private var selectedProjectID: String?
    @State private var projectPendingDeletion: ProjectSummary?
    @State private var projectPendingRename: ProjectSummary?
    @State private var isPresentingProjectCreation = false

    @AppStorage(SessionSidebarDisclosureSettings.profilesAreExpandedKey)
    private var persistedProfilesAreExpanded = SessionSidebarDisclosureSettings.defaultProfilesAreExpanded
    @AppStorage(SessionSidebarDisclosureSettings.projectsAreExpandedKey)
    private var persistedProjectsAreExpanded = SessionSidebarDisclosureSettings.defaultProjectsAreExpanded
    @AppStorage(SessionRowDisplaySettings.showCronSessionsKey)
    private var showsCronSessions = true
    @AppStorage(SessionRowDisplaySettings.showSubagentSessionsKey)
    private var showsSubagentSessions = SessionRowDisplaySettings.defaultShowsSubagentSessions
    @AppStorage(SectionVisibilitySettings.tasksKey)
    private var showsTasksSection = true
    @AppStorage(SectionVisibilitySettings.kanbanKey)
    private var showsKanbanSection = true
    @AppStorage(SectionVisibilitySettings.skillsKey)
    private var showsSkillsSection = true
    @AppStorage(SectionVisibilitySettings.memoryKey)
    private var showsMemorySection = true
    @AppStorage(SectionVisibilitySettings.insightsKey)
    private var showsInsightsSection = true
    @AppStorage(SectionVisibilitySettings.activeProfileKey)
    private var showsActiveProfileSection = true
    @AppStorage(SectionVisibilitySettings.projectsKey)
    private var showsProjectsSection = true
    @AppStorage private var showsCliSessions: Bool
    @AppStorage private var showsClaudeCodeSessions: Bool

    init(
        authManager: AuthManager,
        server: URL,
        projectsEnabled: Bool = true,
        isActive: Bool = true,
        onNestedDestinationVisibilityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.authManager = authManager
        self.server = server
        self.projectsEnabled = projectsEnabled
        self.isActive = isActive
        self.onNestedDestinationVisibilityChanged = onNestedDestinationVisibilityChanged
        _viewModel = State(initialValue: SessionListViewModel(server: server))
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
        NavigationStack {
            List {
                SessionSidebarUtilityRows(
                    viewModel: viewModel,
                    topPadding: 8,
                    automatedVisibility: automatedVisibility,
                    sectionVisibility: sidebarSectionVisibility,
                    profilesAreExpanded: $profilesAreExpanded,
                    projectsAreExpanded: $projectsAreExpanded,
                    selectedProjectID: $selectedProjectID,
                    projectPendingDeletion: $projectPendingDeletion,
                    projectPendingRename: $projectPendingRename,
                    openDestination: { destination in
                        navigationState.select(destination)
                    },
                    switchActiveProfile: { profile in
                        Task {
                            let didSwitch = await viewModel.switchActiveProfile(profile)
                            if !didSwitch, let error = viewModel.lastError {
                                authManager.handleAPIError(error)
                            }
                        }
                    },
                    presentProjectCreation: {
                        isPresentingProjectCreation = true
                    }
                )

                Section("Session history") {
                    Button {
                        navigationState.select(.archived)
                    } label: {
                        Label("Archived Sessions", systemImage: "archivebox")
                    }
                }

                Section("Connection") {
                    Button {
                        navigationState.select(.settings(nil))
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }

                    Button {
                        navigationState.select(.settings(.servers))
                    } label: {
                        Label("Manage Servers", systemImage: "server.rack")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 108, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(SemrehBackdrop().ignoresSafeArea())
            .navigationDestination(item: $navigationState.destination) { destination in
                utilityDestination(destination)
            }
            .task {
                profilesAreExpanded = persistedProfilesAreExpanded
                projectsAreExpanded = persistedProjectsAreExpanded
                await loadSidebarData()
            }
            .onAppear {
                onNestedDestinationVisibilityChanged(navigationState.isNestedDestinationPresented)
            }
            .onChange(of: navigationState.destination) { _, destination in
                onNestedDestinationVisibilityChanged(destination != nil)
            }
            .onChange(of: isActive) { _, active in
                guard !active else { return }
                navigationState.resetForSurfaceDeactivation()
                onNestedDestinationVisibilityChanged(false)
            }
        }
        .sheet(isPresented: $isPresentingProjectCreation) {
            ProjectCreationSheet(
                existingProjectCount: viewModel.projects.count,
                isSaving: viewModel.isCreatingProject,
                onCancel: { isPresentingProjectCreation = false },
                onSave: { name, color in
                    Task {
                        _ = await viewModel.createEmptyProject(
                            named: name,
                            color: color,
                            modelContext: modelContext
                        )
                        isPresentingProjectCreation = false
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .adaptiveFormPresentation()
        }
        .sheet(item: $projectPendingRename) { project in
            ProjectRenameSheet(
                project: project,
                isSaving: viewModel.isRenamingProject,
                onCancel: { projectPendingRename = nil },
                onSave: { name, color in
                    Task {
                        _ = await viewModel.rename(project, named: name, color: color)
                        projectPendingRename = nil
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .adaptiveFormPresentation()
        }
        .confirmationDialog(
            "Delete project?",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let project = projectPendingDeletion else { return }
                projectPendingDeletion = nil
                Task {
                    _ = await viewModel.delete(project, modelContext: modelContext)
                }
            }
            Button("Cancel", role: .cancel) {
                projectPendingDeletion = nil
            }
        } message: {
            Text("Sessions in this project will remain available without a project.")
        }
        .presentationDetents([.medium, .large])
        .adaptiveFormPresentation()
    }

    private var sidebarSectionVisibility: SidebarSectionVisibility {
        SidebarSectionVisibility(
            tasks: showsTasksSection,
            kanban: showsKanbanSection,
            skills: showsSkillsSection,
            memory: showsMemorySection,
            insights: showsInsightsSection,
            activeProfile: showsActiveProfileSection,
            projects: showsProjectsSection && projectsEnabled
        )
    }

    private var automatedVisibility: AutomatedSessionVisibility {
        AutomatedSessionVisibility(
            showsCron: showsCronSessions,
            showsCli: showsCliSessions,
            showsClaudeCode: showsClaudeCodeSessions,
            showsSubagents: showsSubagentSessions
        )
    }

    @ViewBuilder
    private func utilityDestination(_ destination: SessionListUtilityDestination) -> some View {
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
            ArchivedSessionsView(server: server, onAPIError: authManager.handleAPIError)
        case .scheduled:
            ScheduledSessionsView(
                viewModel: viewModel,
                showsCronSessions: showsCronSessions,
                showsMessageCount: true,
                showsWorkspace: true,
                selectedSessionID: nil,
                actions: controlRowActions
            )
        }
    }

    private var controlRowActions: SessionListRowActions {
        SessionListRowActions(
            retryLoad: { Task { _ = await viewModel.load(modelContext: modelContext) } },
            open: { _ in },
            togglePinned: { _ in },
            archive: { _ in },
            delete: { _ in },
            rename: { _ in },
            duplicate: { _ in },
            move: { _, _ in },
            createProject: { _ in },
            refreshProjects: {
                guard projectsEnabled else { return }
                Task { await viewModel.loadProjects() }
            },
            export: { _, _ in },
            projectsEnabled: projectsEnabled
        )
    }

    private func loadSidebarData() async {
        await SidebarLoadOrdering.run(
            resolveActiveProfile: { await viewModel.loadActiveProfile() },
            loadSessions: { _ = await viewModel.load(modelContext: modelContext) }
        )
    }

}

#Preview {
    ControlView(
        authManager: AuthManager(),
        server: URL(staticString: "https://hermes.example.test")
    )
}
