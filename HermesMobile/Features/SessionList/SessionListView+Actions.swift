import SwiftUI
import SwiftData

extension SessionListView {

    func openNewChatFromKeyboard() {
        guard !viewModel.isViewingCachedData,
              !viewModel.isCreatingSession,
              !navigationState.isCreatingNewChat
        else { return }
        openNewChat()
    }

    /// Applies a one-shot profile filter from Bot details. This only changes the
    /// Sessions list predicate; it never switches the server's active profile.
    func applyPendingSessionFilterIfNeeded() {
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

    func presentPendingProjectCreationIfNeeded() {
        guard shouldPresentProjectCreationAfterFiltersDismissal else { return }
        shouldPresentProjectCreationAfterFiltersDismissal = false
        isPresentingProjectCreation = true
    }

    func monitorActiveSessionRows() async {
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

    func loadSessions() async {
        await viewModel.load(modelContext: modelContext)
        guard !Task.isCancelled else { return }
        handleLastError()

        if projectsEnabled, !viewModel.isViewingCachedData {
            await viewModel.loadProjects()
            guard !Task.isCancelled else { return }
            handleLastError()
        }
    }

    func openPendingSharedImportIfNeeded() {
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
    func openPendingDeepLinkedSessionIfNeeded() async {
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

    func openDeepLinkedSession(id sessionID: String) async {
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
    func openRequestedNewChatIfNeeded() {
        guard let request = requestedNewChat else { return }
        guard startNewChat(
            PendingNewChatRoute(
                autoStartsVoiceInput: request.autoStartsVoiceInput,
                profileName: request.profileName
            )
        ) else { return }
        requestedNewChat = nil
    }

    func openNewChat() {
        startNewChat(PendingNewChatRoute())
    }

    @discardableResult
    func startNewChat(_ route: PendingNewChatRoute) -> Bool {
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

    func drainPendingExternalNewChatRequestsIfIdle() {
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

    func selectSession(_ session: SessionSummary) {
#if DEBUG
        ChatPerformanceCadenceMonitor.begin(.entry)
#endif
        navigationState.select(session)
        persistLastSelectedSession()
    }

    func removeSessionFromNavigation(_ session: SessionSummary) {
        navigationState.remove(sessionID: session.sessionId)
        persistLastSelectedSession()
    }

    func restoreLastSelectedSessionIfNeeded(clearsMissingSelection: Bool) {
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

    func persistLastSelectedSession() {
        SessionNavigationPersistence.save(navigationState.lastSelectedSessionID, for: server)
    }

}
