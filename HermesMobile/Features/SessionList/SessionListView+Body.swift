import SwiftUI
import SwiftData

extension SessionListView {

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

}
