import SwiftUI

/// Keep native tab roots mounted; reveal only their content without animating
/// navigation state, destroying scroll identity, or fading through a blank frame.
private struct ShellTabReveal: ViewModifier {
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isSelected || reduceMotion ? 1 : 0.92)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
    }
}

/// Raw values remain stable for existing routes; labels describe the actual destinations.
enum AppShellSurface: String, CaseIterable, Hashable, Identifiable {
    case control, sessions, you
    static let primaryTabs: [Self] = [.control, .sessions, .you]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sessions: "Sessions"
        case .control: "Bots"
        case .you: "Activity"
        }
    }
    var systemImage: String {
        switch self {
        case .sessions: "bubble.left.and.bubble.right"
        case .control: "sparkles"
        case .you: "clock"
        }
    }
    var showsPrimaryAction: Bool { self == .sessions }
}

enum AppShellOrganizerPolicy {
    static let projectsEnabled = true

    static func showsProjects(isShell: Bool, hasProjects: Bool, hasSelection: Bool) -> Bool {
        !isShell || hasProjects || hasSelection
    }
}

enum AppShellSessionReturnPolicy {
    static func resetsOnDeparture(from previous: AppShellSurface, to next: AppShellSurface) -> Bool {
        previous == .sessions && next != .sessions
    }
}

enum AppShellSettingsAction {
    static let systemImage = "gearshape"
    static let accessibilityLabel = "Settings"
}

enum SessionShellFilter {
    /// Applies the shell's existing local filters without changing the
    /// server/session model. Cron rows are history here; this does not imply
    /// that a job is currently scheduled or running.
    static func matches(
        _ session: SessionSummary,
        bot: String?,
        pinnedOnly: Bool,
        scheduledHistoryOnly: Bool = false,
        projectID: String? = nil
    ) -> Bool {
        (bot == nil || session.profile == bot)
            && (!pinnedOnly || session.pinned == true)
            && (!scheduledHistoryOnly || session.isCronSession)
            && (projectID == nil || session.projectId == projectID)
    }
}

/// A one-shot route from Bot details to the Sessions tab. The profile name is
/// a filter only; it never changes the server's active/default profile.
struct SessionFilterRequest: Equatable {
    let id: UUID
    let profileName: String

    init(profileName: String) {
        self.id = UUID()
        self.profileName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SessionFilterRouteState: Equatable {
    let profileName: String
    let pinnedOnly: Bool
    let scheduledHistoryOnly: Bool
    let projectID: String?
    let searchText: String
}

enum SessionFilterRoutePolicy {
    /// "View sessions" is a fresh profile-history route. Clear unrelated
    /// Sessions controls so a previous visit cannot silently narrow the
    /// requested profile by pin, schedule, project, or search state.
    static func profileHistoryRoute(profileName: String) -> SessionFilterRouteState? {
        let normalizedProfileName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProfileName.isEmpty else { return nil }

        return SessionFilterRouteState(
            profileName: normalizedProfileName,
            pinnedOnly: false,
            scheduledHistoryOnly: false,
            projectID: nil,
            searchText: ""
        )
    }
}

@MainActor
struct AppShellView: View {
    @Bindable var authManager: AuthManager
    let server: URL
    @Binding var selectedSurface: AppShellSurface
    @Binding var pendingSharedImport: SharedImport?
    @Binding var pendingDeepLinkedSessionID: String?
    @Binding var pendingNewChatRequest: NewChatRequest?
    @State private var isSessionConversationPresented = false
    @State private var showsSettings = false
    @State private var showsBotPicker = false
    @State private var pendingSessionFilterRequest: SessionFilterRequest? = nil
    @State private var sessionSurfaceVisitID = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        // Keep each tab's identity stable while explicitly resetting the Sessions
        // conversation when leaving that tab; drafts remain owned by their chat.
        TabView(selection: $selectedSurface) {
            NavigationStack {
                AppShellBotsView(
                    server: server,
                    onAPIError: authManager.handleAPIError,
                    onViewSessions: { name in
                        pendingSessionFilterRequest = SessionFilterRequest(profileName: name)
                        selectedSurface = .sessions
                    }
                ) { name in
                    pendingNewChatRequest = NewChatRequest(profileName: name)
                    selectedSurface = .sessions
                }
                .navigationTitle("Bots")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { accountButton }
                }
                .toolbarBackground(SemrehVisualTheme.canvas(for: colorScheme, palette: palette), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
            }
            .modifier(ShellTabReveal(isSelected: selectedSurface == .control))
            .tabItem { Image(uiImage: BirdTabIcon.image).accessibilityLabel("Bots") }
            .tag(AppShellSurface.control)

            SessionListView(
                authManager: authManager,
                server: server,
                projectsEnabled: AppShellOrganizerPolicy.projectsEnabled,
                pendingSharedImport: $pendingSharedImport,
                pendingDeepLinkedSessionID: $pendingDeepLinkedSessionID,
                requestedNewChat: $pendingNewChatRequest,
                requestedSessionFilter: $pendingSessionFilterRequest,
                usesShellChrome: true,
                shellSurfaceVisitID: sessionSurfaceVisitID,
                onConversationVisibilityChanged: { isSessionConversationPresented = $0 },
                onNewChat: { showsBotPicker = true },
                onAccount: { showsSettings = true }
            )
            .modifier(ShellTabReveal(isSelected: selectedSurface == .sessions))
            .toolbar(isSessionConversationPresented ? .hidden : .visible, for: .tabBar)
            .tabItem { Image(systemName: AppShellSurface.sessions.systemImage).accessibilityLabel("Sessions") }
            .tag(AppShellSurface.sessions)

            NavigationStack {
                AppShellActivityView(server: server, onAPIError: authManager.handleAPIError)
                    .navigationTitle("Activity")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { accountButton } }
                    .toolbarBackground(SemrehVisualTheme.canvas(for: colorScheme, palette: palette), for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            }
            .modifier(ShellTabReveal(isSelected: selectedSurface == .you))
            .tabItem { Image(systemName: AppShellSurface.you.systemImage).accessibilityLabel("Activity") }
            .tag(AppShellSurface.you)
        }
        .onChange(of: selectedSurface) { oldValue, newValue in
            // Reset the inactive stack on departure, not on return: a bot or
            // external link can still deliberately open a new conversation.
            if AppShellSessionReturnPolicy.resetsOnDeparture(from: oldValue, to: newValue) {
                sessionSurfaceVisitID += 1
                isSessionConversationPresented = false
            }
        }
        .sheet(isPresented: $showsBotPicker) {
            NavigationStack {
                AppShellBotsView(server: server, onAPIError: authManager.handleAPIError) { name in
                    showsBotPicker = false
                    pendingNewChatRequest = NewChatRequest(profileName: name)
                    selectedSurface = .sessions
                }
                .navigationTitle("New chat")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showsBotPicker = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showsSettings) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { showsSettings = false }
                }
                .padding()
                .background(SemrehVisualTheme.canvas(for: colorScheme, palette: palette))

                YouView(authManager: authManager, server: server)
                    .clipped()
            }
            .background(SemrehVisualTheme.canvas(for: colorScheme, palette: palette).ignoresSafeArea())
            .presentationBackground(SemrehVisualTheme.canvas(for: colorScheme, palette: palette))
        }
    }

    private var accountButton: some View {
        Button { showsSettings = true } label: {
            Image(systemName: AppShellSettingsAction.systemImage)
        }
        .accessibilityLabel(AppShellSettingsAction.accessibilityLabel)
    }
}

/// Existing server profiles only. Choosing one starts a new profile-bound chat;
/// it never changes the startup default or the identity of an open conversation.
private struct AppShellBotsView: View {
    let server: URL
    let onAPIError: (Error) -> Void
    let onViewSessions: ((String) -> Void)?
    let onOpenChat: (String) -> Void
    @State private var profiles: [ProfileSummary] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var loadIdentity: AppShellLoadIdentity?
    @State private var selectedProfileForDetails: ProfileSummary?

    init(
        server: URL,
        onAPIError: @escaping (Error) -> Void,
        onViewSessions: ((String) -> Void)? = nil,
        onOpenChat: @escaping (String) -> Void
    ) {
        self.server = server
        self.onAPIError = onAPIError
        self.onViewSessions = onViewSessions
        self.onOpenChat = onOpenChat
    }

    var body: some View {
        List {
            Section {
                Text("Choose a server profile to start a chat.")
                    .foregroundStyle(.secondary)
                if isLoading {
                    ProgressView("Loading bots")
                } else if loadFailed {
                    Text("Bots couldn’t be loaded.").foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                } else if profiles.isEmpty {
                    Text("No server profiles are available.").foregroundStyle(.secondary)
                } else {
                    ForEach(profiles, id: \.normalizedName) { profile in
                        if let name = profile.normalizedName {
                            botProfileRow(profile, name: name)
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { SemrehBackdrop().ignoresSafeArea() }
        .task(id: server) { await load() }
        .onDisappear { loadIdentity = nil }
        .refreshable { await load() }
        .sheet(item: $selectedProfileForDetails) { profile in
            NavigationStack {
                AppShellBotDetailsView(
                    profile: profile,
                    onNewChat: {
                        selectedProfileForDetails = nil
                        if let name = profile.normalizedName {
                            onOpenChat(name)
                        }
                    },
                    onViewSessions: onViewSessions.map { handler in
                        {
                            selectedProfileForDetails = nil
                            if let name = profile.normalizedName {
                                handler(name)
                            }
                        }
                    }
                )
            }
        }
    }

    private func botProfileRow(_ profile: ProfileSummary, name: String) -> some View {
        HStack(spacing: 10) {
            Button { onOpenChat(name) } label: {
                HStack(spacing: 14) {
                    if let identity = BirdAvatarIdentity(server: server, profile: name) {
                        BirdAvatarView(identity: identity)
                            .frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.displayName)
                            .font(SemrehTypography.label)
                            .multilineTextAlignment(.leading)
                        if let model = profile.model, !model.isEmpty {
                            Text(model)
                                .font(SemrehTypography.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "bubble.left").accessibilityHidden(true)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chat with \(profile.displayName)")
            .accessibilityIdentifier("bot-profile:\(name)")

            Button {
                selectedProfileForDetails = profile
            } label: {
                Image(systemName: "info.circle")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View details for \(profile.displayName)")
            .accessibilityHint("Shows read-only profile information.")
            .accessibilityIdentifier("bot-profile-info:\(name)")
        }
    }

    @MainActor private func load() async {
        let request = AppShellLoadIdentity(server: server)
        loadIdentity = request
        isLoading = true
        loadFailed = false
        defer {
            if loadIdentity == request { isLoading = false }
        }
        do {
            let response = try await APIClient(baseURL: server).directProfiles()
            guard request.accepts(current: loadIdentity, cancelled: Task.isCancelled) else { return }
            profiles = AppShellBotCatalog.uniqueProfiles(response.profiles ?? [])
        } catch {
            guard request.accepts(current: loadIdentity, cancelled: Task.isCancelled) else { return }
            loadFailed = true
            onAPIError(error)
        }
    }
}

private struct AppShellBotDetailsView: View {
    let profile: ProfileSummary
    let onNewChat: () -> Void
    let onViewSessions: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Profile") {
                AppShellBotMetadataRow(title: "Name", value: profile.displayName)
                if let provider = nonEmpty(profile.provider) {
                    AppShellBotMetadataRow(title: "Provider", value: provider)
                }
                if let model = nonEmpty(profile.model) {
                    AppShellBotMetadataRow(title: "Model", value: model)
                }
            }

            if !profileStatusRows.isEmpty {
                Section("Available metadata") {
                    ForEach(profileStatusRows) { row in
                        AppShellBotMetadataRow(title: row.title, value: row.value)
                    }
                }
            }

            Section {
                Button("New chat", systemImage: "square.and.pencil", action: onNewChat)
                    .accessibilityIdentifier("bot-details-new-chat")
                if let onViewSessions {
                    Button("View sessions", systemImage: "bubble.left.and.bubble.right", action: onViewSessions)
                        .accessibilityIdentifier("bot-details-view-sessions")
                }
            } footer: {
                Text("This profile view is read-only. Server defaults and active profiles are managed in Settings.")
            }
        }
        .navigationTitle(profile.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .scrollContentBackground(.hidden)
        .background { SemrehBackdrop().ignoresSafeArea() }
    }

    private var profileStatusRows: [AppShellBotMetadataItem] {
        var rows: [AppShellBotMetadataItem] = []
        if let gatewayRunning = profile.gatewayRunning {
            rows.append(AppShellBotMetadataItem(title: "Gateway", value: gatewayRunning ? "Running" : "Stopped"))
        }
        if let hasEnv = profile.hasEnv {
            rows.append(AppShellBotMetadataItem(title: "Environment", value: hasEnv ? "Configured" : "Not configured"))
        }
        if let skillCount = profile.skillCount {
            rows.append(AppShellBotMetadataItem(title: "Skills", value: String(skillCount)))
        }
        if profile.isDefault == true {
            rows.append(AppShellBotMetadataItem(title: "Server default", value: "Yes"))
        }
        if profile.isActive == true {
            rows.append(AppShellBotMetadataItem(title: "Active profile", value: "Yes"))
        }
        return rows
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct AppShellBotMetadataItem: Identifiable {
    let title: String
    let value: String

    var id: String { title }
}

private struct AppShellBotMetadataRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AppShellActivityView: View {
    let server: URL
    let onAPIError: (Error) -> Void
    @State private var profileName: String?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var loadIdentity: AppShellLoadIdentity?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading activity").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let profileName {
                TasksView(server: server, profile: profileName, onAPIError: onAPIError)
                    .id(profileName)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Text("Scheduled work · Profile: \(profileName)")
                            .font(SemrehTypography.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(SemrehVisualTheme.canvas(for: colorScheme, palette: palette))
                    }
            } else {
                ContentUnavailableView {
                    Label("Activity unavailable", systemImage: "clock")
                } description: {
                    Text(loadFailed ? "Activity couldn’t be loaded." : "No server profile is available for scheduled work.")
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { SemrehBackdrop().ignoresSafeArea() }
        .task(id: server) { await load() }
        .onDisappear { loadIdentity = nil }
        .refreshable { await load() }
    }

    @MainActor private func load() async {
        let request = AppShellLoadIdentity(server: server)
        loadIdentity = request
        isLoading = true
        loadFailed = false
        defer {
            if loadIdentity == request { isLoading = false }
        }
        do {
            let client = APIClient(baseURL: server)
            let response = try await client.directActiveProfile()
            guard request.accepts(current: loadIdentity, cancelled: Task.isCancelled) else { return }
            if let current = AppShellActivityScope.resolve(current: response.current, inventory: nil) {
                profileName = current
            } else {
                let inventory = try await client.directProfiles()
                guard request.accepts(current: loadIdentity, cancelled: Task.isCancelled) else { return }
                profileName = AppShellActivityScope.resolve(current: nil, inventory: inventory)
            }
        } catch {
            guard request.accepts(current: loadIdentity, cancelled: Task.isCancelled) else { return }
            loadFailed = true
            profileName = nil
            onAPIError(error)
        }
    }
}

/// Scheduling remains available without a running gateway profile; inventory
/// fallback selects a read scope, never the server's active/startup profile.
enum AppShellActivityScope {
    static func resolve(current: String?, inventory: ProfilesResponse?) -> String? {
        if let name = current?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return inventory?.effectiveDefaultProfileName
    }
}

/// Every load has both a server and a unique generation. Cancelled, replaced,
/// and departed-screen responses cannot update the current presentation.
struct AppShellLoadIdentity: Equatable {
    let server: URL
    let generation = UUID()

    func accepts(current: Self?, cancelled: Bool) -> Bool {
        !cancelled && current == self
    }
}

enum AppShellBotCatalog {
    static func uniqueProfiles(_ profiles: [ProfileSummary]) -> [ProfileSummary] {
        var names = Set<String>()
        return profiles.filter { profile in
            guard let name = profile.normalizedName else { return false }
            return names.insert(name).inserted
        }
    }
}

enum AppShellChromePolicy {
    static func showsTopBar(
        surface: AppShellSurface,
        isSessionConversationPresented: Bool,
        isControlDestinationPresented: Bool
    ) -> Bool {
        surface != .you
            && !isSessionConversationPresented
            && !(surface == .control && isControlDestinationPresented)
    }

    static func showsBottomBar(
        isConversationPresented: Bool,
        isControlDestinationPresented: Bool
    ) -> Bool {
        !isConversationPresented && !isControlDestinationPresented
    }

    static func showsBottomBar(isConversationPresented: Bool) -> Bool {
        !isConversationPresented
    }
}

struct ControlNavigationState: Equatable {
    var destination: SessionListUtilityDestination?

    var isNestedDestinationPresented: Bool {
        destination != nil
    }

    mutating func select(_ destination: SessionListUtilityDestination) {
        self.destination = destination
    }

    mutating func resetForSurfaceDeactivation() {
        destination = nil
    }
}
