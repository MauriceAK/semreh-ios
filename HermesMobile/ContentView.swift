import SwiftUI

struct ContentView: View {
    @Bindable var authManager: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingSharedImport: SharedImport?
    @State private var pendingDeepLinkedSessionID: String?
    @State private var pendingNewChatRequest: NewChatRequest?
    @State private var didCheckInitialPendingShare = false
    @State private var needsGatewayForegroundRecovery = false
    @State private var intentRouter = AppIntentRouter.shared
    @State private var selectedSurface: AppShellSurface = .sessions
    @State private var isFreshOnboardingOrigin = false
    @State private var showsPostLoginPersonalization = false
    @AppStorage(OnboardingFlowPolicy.postLoginPersonalizationPendingStorageKey)
    private var isPostLoginPersonalizationPending = false

    var body: some View {
        content
            .onOpenURL(perform: handleOpenURL)
            .task {
                if OnboardingFlowPolicy.isFreshOnboardingOrigin(authManager.state) {
                    isFreshOnboardingOrigin = true
                }
                resumePostLoginPersonalizationIfNeeded(for: authManager.state)
                guard !didCheckInitialPendingShare else { return }
                didCheckInitialPendingShare = true
                importPendingSharedDraftIfAvailable()
                // Cold launch: an App Intent may have queued a deep link before this
                // view appeared (e.g. Action button "New Chat"). Drain it now (#337).
                drainPendingIntentDeepLink()
            }
            .onChange(of: intentRouter.pendingDeepLink) {
                // Warm launch: the intent set the deep link after the view appeared.
                drainPendingIntentDeepLink()
            }
            .onChange(of: authManager.state) { oldState, newState in
                handleAuthStateChange(from: oldState, to: newState)
            }
            .onChange(of: scenePhase) {
                if scenePhase == .background {
                    needsGatewayForegroundRecovery = true
                    return
                }
                guard scenePhase == .active else { return }
                importPendingSharedDraftIfAvailable()
                guard needsGatewayForegroundRecovery else { return }
                needsGatewayForegroundRecovery = false
                Task { await recoverActiveGatewayOnForeground() }
            }
            .fullScreenCover(
                isPresented: $showsPostLoginPersonalization,
                onDismiss: finishPostLoginPersonalization
            ) {
                NavigationStack {
                    ZStack {
                        SemrehBackdrop()
                            .ignoresSafeArea()
                        OnboardingAppearancePage()
                    }
                    .navigationTitle("Personalize")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Skip", action: finishPostLoginPersonalization)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done", action: finishPostLoginPersonalization)
                                .fontWeight(.semibold)
                        }
                    }
                }
                .environment(\.appColorPalette, .semreh)
            }
    }

    private func handleAuthStateChange(from oldState: AuthManager.State, to newState: AuthManager.State) {
        if OnboardingFlowPolicy.isFreshOnboardingOrigin(oldState) {
            // Carry the first-run origin across an AuthManager `.loggedOut` state
            // after rejected credentials. That transient state is not a saved reauth.
            isFreshOnboardingOrigin = true
        }
        if OnboardingFlowPolicy.shouldStartPostLoginPersonalization(
            hasFreshOnboardingOrigin: isFreshOnboardingOrigin,
            to: newState
        ) {
            // Persist only after the first connection actually reaches logged-in.
            // A failed or interrupted connection leaves this flag untouched.
            isPostLoginPersonalizationPending = true
            isFreshOnboardingOrigin = false
        }
        resumePostLoginPersonalizationIfNeeded(for: newState)
    }

    private func resumePostLoginPersonalizationIfNeeded(for state: AuthManager.State) {
        guard isPostLoginPersonalizationPending, case .loggedIn = state else { return }
        showsPostLoginPersonalization = true
    }

    private func finishPostLoginPersonalization() {
        isPostLoginPersonalizationPending = false
        showsPostLoginPersonalization = false
        isFreshOnboardingOrigin = false
    }

    private func recoverActiveGatewayOnForeground() async {
        guard case .loggedIn(let server) = authManager.state else { return }
        _ = await OpenChatSessionStore.shared.recoverGatewayOnForeground(for: server)
    }

    @ViewBuilder
    private var content: some View {
        switch authManager.state {
        case .unconfigured:
            OnboardingView(authManager: authManager)
        case .loggedOut(let server):
            OnboardingView(authManager: authManager, savedServer: server)
        case .loggedIn(let server):
            // Chat-only prototype: when PrototypeConfig.isEnabled the full
            // AppShellView is swapped for the prototype navigation shell.
            // Flipping the flag restores the `else` branch bit-for-bit.
            // Switching the active server keeps us in `.loggedIn`, so without a
            // per-server identity SwiftUI would reuse the same tab stack (and its
            // server-bound SessionListView view model), leaving stale sessions/chat on screen.
            // Keying on the server tears the whole stack down and rebuilds it
            // against the newly active server (#17).
            Group {
                if PrototypeConfig.isEnabled {
                    PrototypeRootView(authManager: authManager, server: server)
                } else {
                    AppShellView(
                        authManager: authManager,
                        server: server,
                        selectedSurface: $selectedSurface,
                        pendingSharedImport: $pendingSharedImport,
                        pendingDeepLinkedSessionID: $pendingDeepLinkedSessionID,
                        pendingNewChatRequest: $pendingNewChatRequest
                    )
                }
            }
            .id(server)
        }
    }

    private func handleOpenURL(_ url: URL) {
        // Deep links and shared drafts belong to the existing Chat surface. If the
        // user is currently looking at Teams, switch back before routing the request
        // through the established session navigation path.
        selectedSurface = .sessions

        // A fresh request each time (new `id`) so a repeat invocation re-triggers navigation
        // even if the previous one's value still lingers downstream. The voice variant carries
        // `autoStartsVoiceInput` so the composer begins dictation once it appears (#338).
        if HermesDeepLink.isNewChatVoiceURL(url) {
            pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: true)
            return
        }

        // The profile variant carries the chosen profile name, so the composer creates the
        // session pinned to it (#339). A malformed link with no profile falls back to a
        // plain new chat (server's active profile) rather than failing.
        if HermesDeepLink.isNewChatInProfileURL(url) {
            pendingNewChatRequest = NewChatRequest(
                profileName: HermesDeepLink.profileName(fromNewChatInProfile: url)
            )
            return
        }

        if HermesDeepLink.isNewChatURL(url) {
            pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: false)
            return
        }

        if let sessionID = HermesDeepLink.sessionID(from: url) {
            pendingDeepLinkedSessionID = sessionID
            return
        }

        guard HermesShareDraft.isShareOpenURL(url) else {
            return
        }

        importPendingSharedDraftIfAvailable()
    }

    /// Routes a deep link queued by an App Intent through the same `handleOpenURL` parser
    /// used for external URLs, then clears it so it routes exactly once (#337).
    private func drainPendingIntentDeepLink() {
        guard let url = intentRouter.pendingDeepLink else { return }
        intentRouter.pendingDeepLink = nil
        handleOpenURL(url)
    }

    private func importPendingSharedDraftIfAvailable() {
        guard let directory = HermesShareDraft.containerURL() else {
            return
        }

        do {
            if let sharedImport = try HermesShareDraft.loadPendingImport(from: directory) {
                pendingSharedImport = sharedImport
            }
        } catch {
            pendingSharedImport = nil
        }
    }
}

#Preview {
    ContentView(authManager: AuthManager())
}
