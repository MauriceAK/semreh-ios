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
    static let primaryTabs: [Self] = [.control, .sessions]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sessions: "Chats"
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
    /// Explicitly select the filled SF Symbol variant for the active system-icon tab.
    /// Bots uses its custom bird artwork, which has separate outline and filled images.
    func tabBarSystemImage(isSelected: Bool) -> String {
        guard isSelected else { return systemImage }
        return switch self {
        case .control: systemImage
        case .sessions: "bubble.left.and.bubble.right.fill"
        case .you: "clock.fill"
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
        false
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
    @State private var pendingSessionFilterRequest: SessionFilterRequest? = nil
    @State private var sessionSurfaceVisitID = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        // Keep each tab and its open conversation mounted across tab switches.
        // Explicit back navigation and incoming routes still own destination changes.
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
                // Rehydrate before the first frame for a different server, including
                // its detail-sheet state, even when this shell keeps its identity.
                .id(server)
                .navigationTitle("Bots")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { accountButton }
                }
                .toolbarBackground(SemrehVisualTheme.canvas(for: colorScheme, palette: palette), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
            }
            .modifier(ShellTabReveal(isSelected: selectedSurface == .control))
            .tabItem {
                Image(uiImage: selectedSurface == .control ? BirdTabIcon.selectedImage : BirdTabIcon.image)
                    .accessibilityLabel("Bots")
                Text("Bots")
            }
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
                onNewChat: {
                    if pendingNewChatRequest == nil, pendingSharedImport == nil,
                       pendingDeepLinkedSessionID == nil {
                        pendingNewChatRequest = .defaultChat()
                    }
                    selectedSurface = .sessions
                },
                onAccount: { showsSettings = true }
            )
            .modifier(ShellTabReveal(isSelected: selectedSurface == .sessions))
            .toolbar(.visible, for: .tabBar)
            .tabItem {
                Image(systemName: AppShellSurface.sessions.tabBarSystemImage(isSelected: selectedSurface == .sessions))
                    .accessibilityLabel("Chats")
                    .environment(\.symbolVariants, .none)
                Text("Chats")
            }
            .tag(AppShellSurface.sessions)

        }
        .onChange(of: selectedSurface) { oldValue, newValue in
            // Reset the inactive stack on departure, not on return: a bot or
            // external link can still deliberately open a new conversation.
            if AppShellSessionReturnPolicy.resetsOnDeparture(from: oldValue, to: newValue) {
                sessionSurfaceVisitID += 1
                isSessionConversationPresented = false
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
    @State private var catalog: AppShellBotCatalogState
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
        _catalog = State(initialValue: AppShellBotCatalogState(
            server: server, cachedProfiles: CacheStore.cachedBotProfiles(serverURL: server)
        ))
    }

    var body: some View {
        List {
            Section("Your Team") {
                if catalog.showsSkeleton {
                    ForEach(0..<3) { index in
                        AppShellBotSkeletonRow(index: index)
                    }
                } else if catalog.showsRetry {
                    Button("Retry", systemImage: "arrow.clockwise") { Task { await load() } }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Retry loading bots")
                        .accessibilityIdentifier("bots-retry")
                } else if catalog.profiles.isEmpty {
                    Text("No server profiles are available.").foregroundStyle(.secondary)
                } else {
                    ForEach(catalog.profiles, id: \.normalizedName) { profile in
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
        .onDisappear { catalog.cancelLoad() }
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
        let cachedProfiles = catalog.server == server ? nil : CacheStore.cachedBotProfiles(serverURL: server)
        let request = catalog.beginLoad(server: server, cachedProfiles: cachedProfiles)
        let cacheGeneration = CacheStore.botCatalogWriteGeneration
        defer { catalog.finishLoad(request) }
        do {
            let response = try await APIClient(baseURL: server).directProfiles()
            guard catalog.accept(response.profiles ?? [], for: request, cancelled: Task.isCancelled) else { return }
            CacheStore.cacheBotProfiles(catalog.profiles, serverURL: server,
                                        expectedGeneration: cacheGeneration)
        } catch {
            guard catalog.fail(request, cancelled: Task.isCancelled) else { return }
            onAPIError(error)
        }
    }
}

private struct AppShellBotSkeletonRow: View {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var shimmers = false

    private var shapes: some View {
        HStack(spacing: 14) {
            Circle().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 8) {
                Capsule().frame(width: index == 1 ? 112 : 88, height: 13)
                Capsule().frame(width: index == 2 ? 148 : 128, height: 10)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        shapes
            .foregroundStyle(Color.primary.opacity(0.08))
            .overlay {
                if !reduceMotion, scenePhase == .active {
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, Color.primary.opacity(0.08), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.7)
                            .offset(x: shimmers ? geometry.size.width : -geometry.size.width)
                    }
                    .mask(shapes)
                }
            }
            .animation(reduceMotion || scenePhase != .active ? nil
                       : .linear(duration: 1.6).repeatForever(autoreverses: false), value: shimmers)
            .onAppear { shimmers = !reduceMotion && scenePhase == .active }
            .onChange(of: reduceMotion) { shimmers = !reduceMotion && scenePhase == .active }
            .onChange(of: scenePhase) { shimmers = !reduceMotion && scenePhase == .active }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Keeps the last authoritative catalog while a fresh read is outstanding. An
/// empty successful response remains authoritative; failure never erases rows.
struct AppShellBotCatalogState {
    private(set) var server: URL
    private(set) var profiles: [ProfileSummary]
    private(set) var hasSnapshot: Bool
    private(set) var isLoading = true
    private(set) var loadIdentity: AppShellLoadIdentity?

    init(server: URL, cachedProfiles: [ProfileSummary]?) {
        self.server = server
        profiles = AppShellBotCatalog.uniqueProfiles(cachedProfiles ?? [])
        hasSnapshot = cachedProfiles != nil
    }

    var showsSkeleton: Bool { isLoading && !hasSnapshot }
    var showsRetry: Bool { !isLoading && !hasSnapshot }

    mutating func beginLoad(server: URL, cachedProfiles: [ProfileSummary]? = nil) -> AppShellLoadIdentity {
        if self.server != server {
            self = Self(server: server, cachedProfiles: cachedProfiles)
        }
        let request = AppShellLoadIdentity(server: server)
        loadIdentity = request
        isLoading = true
        return request
    }

    mutating func accept(_ profiles: [ProfileSummary], for request: AppShellLoadIdentity,
                         cancelled: Bool) -> Bool {
        guard request.accepts(current: loadIdentity, cancelled: cancelled), request.server == server else { return false }
        self.profiles = AppShellBotCatalog.uniqueProfiles(profiles)
        hasSnapshot = true
        isLoading = false
        loadIdentity = nil
        return true
    }

    mutating func fail(_ request: AppShellLoadIdentity, cancelled: Bool) -> Bool {
        guard request.accepts(current: loadIdentity, cancelled: cancelled), request.server == server else { return false }
        isLoading = false
        loadIdentity = nil
        return true
    }

    mutating func finishLoad(_ request: AppShellLoadIdentity) {
        guard loadIdentity == request else { return }
        loadIdentity = nil
        isLoading = false
    }

    mutating func cancelLoad() {
        loadIdentity = nil
        isLoading = false
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
            if isLoading && profileName == nil {
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
        .onDisappear {
            loadIdentity = nil
            isLoading = false
        }
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
