import SwiftUI

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
}

enum SessionShellFilter {
    static func matches(_ session: SessionSummary, bot: String?, pinnedOnly: Bool) -> Bool {
        (bot == nil || session.profile == bot) && (!pinnedOnly || session.pinned == true)
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
    @State private var showsTools = false
    @State private var showsBotPicker = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        // Keep each tab's identity stable so changing tabs retains the chat stack and draft.
        TabView(selection: $selectedSurface) {
            NavigationStack {
                AppShellBotsView(server: server, onAPIError: authManager.handleAPIError, allowsConfiguration: true) { name in
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
            .tabItem { Image(systemName: AppShellSurface.control.systemImage).accessibilityLabel("Bots") }
            .tag(AppShellSurface.control)

            SessionListView(
                authManager: authManager,
                server: server,
                projectsEnabled: AppShellOrganizerPolicy.projectsEnabled,
                pendingSharedImport: $pendingSharedImport,
                pendingDeepLinkedSessionID: $pendingDeepLinkedSessionID,
                requestedNewChat: $pendingNewChatRequest,
                usesShellChrome: true,
                shellSurfaceVisitID: 0,
                onConversationVisibilityChanged: { isSessionConversationPresented = $0 },
                onNewChat: { showsBotPicker = true },
                onAccount: { showsSettings = true }
            )
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
            .tabItem { Image(systemName: AppShellSurface.you.systemImage).accessibilityLabel("Activity") }
            .tag(AppShellSurface.you)
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
                    Button("Tools", systemImage: "square.grid.2x2") { showsTools = true }
                    Spacer()
                    Button("Done") { showsSettings = false }
                }
                .padding()
                .background(.bar)

                YouView(authManager: authManager, server: server)
                    .clipped()
            }
            .sheet(isPresented: $showsTools) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Tools").font(SemrehTypography.label)
                        Spacer()
                        Button("Done") { showsTools = false }
                    }
                    .padding()
                    .background(.bar)

                    ControlView(authManager: authManager, server: server)
                        .clipped()
                }
            }
        }
    }

    private var accountButton: some View {
        Button { showsSettings = true } label: {
            Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Account and settings")
    }
}

/// Existing server profiles only. Choosing one starts a new profile-bound chat;
/// it never changes the startup default or the identity of an open conversation.
private struct AppShellBotsView: View {
    let server: URL
    let onAPIError: (Error) -> Void
    var allowsConfiguration = false
    let onOpenChat: (String) -> Void
    @State private var profiles: [ProfileSummary] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var loadIdentity: AppShellLoadIdentity?
    @State private var defaultProfileName: String?
    @State private var showsDefaultBot = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

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
                            Button { onOpenChat(name) } label: {
                                HStack(spacing: 14) {
                                    if let identity = BirdAvatarIdentity(server: server, profile: name) {
                                        BirdAvatarView(identity: identity)
                                            .frame(width: 48, height: 48)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(profile.displayName).font(SemrehTypography.label)
                                        if let model = profile.model, !model.isEmpty {
                                            Text(model).font(SemrehTypography.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "bubble.left").accessibilityHidden(true)
                                }
                                .padding(.vertical, 4)
                            }
                            .accessibilityLabel("Chat with \(profile.displayName)")
                            .accessibilityIdentifier("bot-profile:\(name)")
                        }
                    }
                }
            } header: {
                Text("Your bots")
            } footer: {
                Text("Bots use profiles configured on your connected Hermes server.")
            }
            .listRowBackground(SemrehVisualTheme.raisedPanel(for: colorScheme, palette: palette))
        }
        .scrollContentBackground(.hidden)
        .background { SemrehBackdrop().ignoresSafeArea() }
        .task(id: server) { await load() }
        .onDisappear { loadIdentity = nil }
        .refreshable { await load() }
        .toolbar {
            if allowsConfiguration {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Default bot", systemImage: "slider.horizontal.3") { showsDefaultBot = true }
                        .disabled(isLoading || loadFailed)
                }
            }
        }
        .sheet(isPresented: $showsDefaultBot, onDismiss: { Task { await load() } }) {
            DefaultProfilePickerView(server: server, currentDefaultProfileName: defaultProfileName) { selection in
                defaultProfileName = selection.name
                showsDefaultBot = false
            }
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
            defaultProfileName = response.effectiveDefaultProfileName
        } catch {
            guard request.accepts(current: loadIdentity, cancelled: Task.isCancelled) else { return }
            loadFailed = true
            onAPIError(error)
        }
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
