import SwiftUI
import SwiftData

extension SessionListView {

    @ViewBuilder
    func navigationDestination(_ destination: SessionNavigationDestination) -> some View {
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

    @ViewBuilder
    var navigationContainer: some View {
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

}
