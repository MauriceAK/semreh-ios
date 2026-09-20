import SwiftUI
import SwiftData
import UIKit
import UserNotifications

/// A Settings section a deep link can open when the screen opens — the avatar
/// long-press "Manage Servers" shortcut lands on Connections (#283).
enum SettingsScrollAnchor: Hashable {
    case servers
}

enum SettingsDestination: Hashable {
    case appearance
    case chat
    case connections
    case toolsAndHistory
    case aboutAndStorage

    var title: String {
        switch self {
        case .appearance:
            String(localized: "Appearance")
        case .chat:
            String(localized: "Chat")
        case .connections:
            String(localized: "Connections")
        case .toolsAndHistory:
            String(localized: "Tools & History")
        case .aboutAndStorage:
            String(localized: "About & Storage")
        }
    }
}

struct SettingsView: View {
    @Bindable var authManager: AuthManager
    let server: URL
    /// When set, Settings opens the matching destination once on first appear (#283).
    let initialScrollTarget: SettingsScrollAnchor?
    /// Optional content rendered above the existing settings cards (for example,
    /// the profile summary in the shell's You tab).
    let header: AnyView?
    let destination: SettingsDestination?

    init(
        authManager: AuthManager,
        server: URL,
        initialScrollTarget: SettingsScrollAnchor? = nil,
        header: AnyView? = nil
    ) {
        self.authManager = authManager
        self.server = server
        self.initialScrollTarget = initialScrollTarget
        self.header = header
        self.destination = nil
        _cliSessionsSync = State(initialValue: CliSessionsSyncModel(server: server))
    }

    init(authManager: AuthManager, server: URL, destination: SettingsDestination) {
        self.authManager = authManager
        self.server = server
        self.initialScrollTarget = nil
        self.header = nil
        self.destination = destination
        _cliSessionsSync = State(initialValue: CliSessionsSyncModel(server: server))
    }

    @ScaledMetric(relativeTo: .body) var settingsCardSpacing: CGFloat = 18
    @State var isConfirmingReconfigure = false
    @State var didScrollToInitialTarget = false
    @State var isPresentingInitialServerDestination = false
    @State var isPresentingAddServer = false
    @State var isConfirmingClearCache = false
    @State var isClearingCache = false
    @State var cacheStatusMessage: String?
    @State var isLoadingServerSettings = false
    @State var serverVersion: String?
    @State var serverSettingsError: String?
    @State var serverUpdateState: UpdatesCheckResponse.UpdateState?
    @State var updateApplyPhase: ServerUpdateApplyPhase = .idle
    @State var isConfirmingUpdate = false
    @State var updateApplyMessage: String?
    @State var isCheckingForUpdates = false
    @State var forcedCheckOutcome: UpdatesCheckResponse.ForcedCheckOutcome?
    @State var isPresentingForcedCheckResult = false
    @State var updateOperation: Task<Void, Never>?
    @State var defaultModel: String?
    @State var defaultProfileName: String?
    @State var defaultProfileDisplayName: String?
    @State var isLoadingDefaultModel = false
    @State var isLoadingDefaultProfile = false
    @State var showDefaultModelPicker = false
    @State var showDefaultProfilePicker = false
    @State var notificationPermissionStatus: UNAuthorizationStatus?
    @State var notificationStatusMessage: String?
    @AppStorage(AppTheme.storageKey) var appThemeRawValue = AppTheme.system.rawValue
    @AppStorage(AppAccent.storageKey) var appAccentRawValue = AppAccent.defaultValue.rawValue
    @AppStorage(AppHaptics.isEnabledKey) var isHapticsEnabled = true
    @AppStorage(ResponseCompletionNotifications.isEnabledKey) var isResponseCompletionNotificationsEnabled = false
    @AppStorage(ResponseCompletionNotifications.hasRequestedPermissionKey) var hasRequestedResponseCompletionNotificationPermission = false
    @AppStorage(AgentRunLiveActivityPrivacy.showsResponseExcerptsKey) var showsLiveActivityResponseExcerpts = false
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) var showsSessionMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) var showsSessionWorkspace = true
    @AppStorage(SessionRowDisplaySettings.showCronSessionsKey) var showsCronSessions = true
    @AppStorage(SessionRowDisplaySettings.showSubagentSessionsKey)
    var showsSubagentSessions = SessionRowDisplaySettings.defaultShowsSubagentSessions
    @State var cliSessionsSync: CliSessionsSyncModel
    @AppStorage(StreamingSendBehavior.storageKey) var streamingSendBehaviorRawValue = StreamingSendBehavior.steer.rawValue
    @AppStorage(ComposerSTTProviderPreference.storageKey) var sttProviderPreferenceRawValue = ComposerSTTProviderPreference.defaultValue.rawValue
    @AppStorage(ChatTranscriptDisplaySettings.showsThinkingAndToolCardsKey) var showsThinkingAndToolCards = true
    @AppStorage(ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey) var thinkingCardsStartExpanded = false
    @AppStorage(ChatTranscriptDisplaySettings.toolCardsStartExpandedKey) var toolCardsStartExpanded = false
    @AppStorage(ChatTranscriptDisplaySettings.hidesAttachmentPathsKey) var hidesAttachmentPaths = true
    @AppStorage(ChatTranscriptDisplaySettings.showsAssistantTurnTimestampsKey) var showsAssistantTurnTimestamps = false
    @AppStorage(ChatTranscriptDisplaySettings.showsResponseSpeedKey) var showsResponseSpeed = false
    @AppStorage(ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey) var wrapsCodeBlockLines = false
    @AppStorage(ChatTranscriptDisplaySettings.rtlChatLayoutEnabledKey) var rtlChatLayoutEnabled = ChatTranscriptDisplaySettings.rtlChatLayoutDefaultEnabled
    @AppStorage(StreamedTextAnimationSettings.isEnabledKey) var isStreamedTextAnimationEnabled = true
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) var tintsPrimaryActions = false
    // These legacy identity values remain persisted and are still consumed by
    // the server registry/session list. The editor is intentionally not on the
    // settings index; per-server identity remains available from Connections.
    @AppStorage(SessionIdentitySettings.displayNameKey) var identityDisplayName = ""
    @AppStorage(SessionIdentitySettings.initialsKey) var identityInitials = ""
    @AppStorage(SectionVisibilitySettings.tasksKey) var showsTasksSection = true
    @AppStorage(SectionVisibilitySettings.kanbanKey) var showsKanbanSection = true
    @AppStorage(SectionVisibilitySettings.skillsKey) var showsSkillsSection = true
    @AppStorage(SectionVisibilitySettings.memoryKey) var showsMemorySection = true
    @AppStorage(SectionVisibilitySettings.insightsKey) var showsInsightsSection = true
    @AppStorage(SectionVisibilitySettings.activeProfileKey) var showsActiveProfileSection = true
    @AppStorage(SectionVisibilitySettings.projectsKey) var showsProjectsSection = true
    @AppStorage(SectionVisibilitySettings.chatFilesKey) var showsChatFilesButton = true
    @AppStorage(SectionVisibilitySettings.chatGitKey) var showsChatGitControls = true
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appColorPalette) var palette

    var body: some View {
        ScrollView {
            VStack(spacing: settingsCardSpacing) {
                if destination == nil {
                    if let header {
                        header
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Make Semreh yours.").font(SemrehTypography.heading)
                            Text("Your preferences, conversations, and connected servers.")
                                .font(SemrehTypography.body).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }

                    settingsDestinationIndex
                }


                if destination == .appearance {
                    appearanceSection
                }

                if destination == .chat {
                    chatSection
                }

                if destination == .toolsAndHistory {
                    toolsAndHistorySection
                }

                if destination == .connections {
                    connectionsSection
                }

                if destination == .aboutAndStorage {
                    aboutAndStorageSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 36)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
        .background { SemrehVisualTheme.canvas(for: colorScheme, palette: palette).ignoresSafeArea() }
        .navigationTitle(destination?.title ?? "Settings")
        .toolbar(header == nil ? .visible : .hidden, for: .navigationBar)
        .task {
            if destination == .connections {
                await loadServerSettings()
            } else if destination == .chat {
                await refreshNotificationPermissionStatus()
            }
        }
        .onDisappear {
            updateOperation?.cancel()
            updateOperation = nil
            if isUpdateApplyInFlight {
                updateApplyMessage = String(localized: "Update monitoring stopped. Check the server status before trying again.")
                updateApplyPhase = .unknown
            }
        }
        .alert("Clear this server's cache?", isPresented: $isConfirmingClearCache) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Cache", role: .destructive) {
                Task {
                    await clearOfflineCache()
                }
            }
        } message: {
            Text("This server's cached sessions and messages will be deleted. Other servers and online server data are not affected.")
        }
        .alert("Update server?", isPresented: $isConfirmingUpdate) {
            Button("Cancel", role: .cancel) {}
            Button("Update") {
                updateOperation = Task {
                    await applyServerUpdate()
                }
            }
        } message: {
            Text("This pulls the latest Hermes server version and restarts it. Active chats may be interrupted briefly; the app reconnects when the server is back.")
        }
        // Result of a manual "Check for updates" tap (#308). The outcome is kept
        // set after dismissal so the title/message read off it without blanking
        // mid-animation; a fresh check overwrites it before re-presenting.
        .alert(
            forcedCheckAlertTitle,
            isPresented: $isPresentingForcedCheckResult
        ) {
            if case .updateAvailable = forcedCheckOutcome {
                // The popup already carries the restart warning, so Update applies
                // directly — no second confirmation dialog (issue #308).
                Button("Update") {
                    updateOperation = Task {
                        await applyServerUpdate()
                    }
                }
                Button("Dismiss", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(forcedCheckAlertMessage)
        }
        .alert("Sign out of this server?", isPresented: $isConfirmingReconfigure) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task {
                    // Purge this server's offline cache before signing out, while
                    // the view (and its modelContext) is still alive — sign-out
                    // forgets the active server from the registry, so its cache
                    // would otherwise be orphaned. Mirrors the server-detail
                    // remove path (#18). Best-effort: the cache is server-keyed,
                    // so a leftover row can never surface as another server's.
                    try? CacheStore.clearCache(for: server, in: modelContext)
                    await authManager.signOut()
                    dismiss()
                }
            }
        } message: {
            Text(signOutMessage)
        }
        // Identity edits persist to the active server; its visual accent follows
        // the selected app theme rather than a per-profile color preference.
        .onChange(of: identityDisplayName) { syncActiveServerIdentity() }
        .onChange(of: identityInitials) { syncActiveServerIdentity() }
        .sheet(isPresented: $isPresentingAddServer) {
            AddServerView(authManager: authManager)
        }
        .sheet(isPresented: $showDefaultModelPicker) {
            DefaultModelPickerView(
                server: server,
                currentDefaultModel: defaultModel,
                onSave: { model in
                    defaultModel = model
                }
            )
        }
        .sheet(isPresented: $showDefaultProfilePicker) {
            DefaultProfilePickerView(
                server: server,
                currentDefaultProfileName: defaultProfileName,
                onSave: { selection in
                    defaultProfileName = selection.name
                    defaultProfileDisplayName = selection.displayName
                    if let defaultModel = selection.defaultModel, !defaultModel.isEmpty {
                        self.defaultModel = defaultModel
                    }
                }
            )
        }
        .navigationDestination(isPresented: $isPresentingInitialServerDestination) {
            SettingsView(authManager: authManager, server: server, destination: .connections)
        }
        .onAppear {
            // Land on the Connections destination when opened via the avatar's
            // "Manage Servers" deep link. The one-shot guard prevents popping
            // back from a server detail screen from reopening it (#283).
            guard destination == nil,
                  initialScrollTarget == .servers,
                  !didScrollToInitialTarget else { return }
            didScrollToInitialTarget = true
            DispatchQueue.main.async {
                isPresentingInitialServerDestination = true
            }
        }
    }
}


#Preview {
    NavigationStack {
        SettingsView(authManager: AuthManager(), server: URL(staticString: "https://webui.example.test"))
    }
}