import SwiftUI
import SwiftData


/// Chooses the compact shell-only pinned strip without changing the server
/// session model. Pinned identity is a conversation ID, never a profile: two
/// chats using the same bot therefore remain separate entries.
enum PinnedSessionStripPolicy {
    static func shouldShow(
        usesShellChrome: Bool,
        isSearchActive: Bool,
        hasActiveFilters: Bool,
        searchText: String
    ) -> Bool {
        usesShellChrome
            && !isSearchActive
            && !hasActiveFilters
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func pinnedSessions(from sessions: [SessionSummary]) -> [SessionSummary] {
        var seenIDs = Set<String>()

        return sessions.filter { session in
            guard session.pinned == true else { return false }
            return seenIDs.insert(sessionIdentity(for: session)).inserted
        }
    }

    static func ordinarySessions(
        from sessions: [SessionSummary],
        excluding pinnedSessions: [SessionSummary]
    ) -> [SessionSummary] {
        let pinnedIDs = Set(pinnedSessions.map { sessionIdentity(for: $0) })
        var seenIDs = Set<String>()

        return sessions.filter { session in
            let identity = sessionIdentity(for: session)
            guard !pinnedIDs.contains(identity) else { return false }
            return seenIDs.insert(identity).inserted
        }
    }

    static func shortTitle(for session: SessionSummary, maxCharacters: Int = 18) -> String {
        let title = SessionRowView.displayTitle(for: session)
        guard maxCharacters > 1, title.count > maxCharacters else { return title }
        return String(title.prefix(maxCharacters - 1)) + "…"
    }

    static func accessibilityLabel(for session: SessionSummary) -> String {
        let title = SessionRowView.displayTitle(for: session)
        let bot: String
        if let profile = session.profile {
            let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
            bot = trimmedProfile.isEmpty ? "default" : trimmedProfile
        } else {
            bot = "default"
        }
        return "\(title), bot \(bot)"
    }

    private static func sessionIdentity(for session: SessionSummary) -> String {
        if let sessionID = session.sessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            return "session:\(sessionID)"
        }

        return "fallback:\(session.id)"
    }
}

struct PinnedSessionStrip: View {
    let viewModel: SessionListViewModel
    let sessions: [SessionSummary]
    let server: URL
    let actions: SessionListRowActions

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(sessions) { session in
                    PinnedSessionStripItem(
                        viewModel: viewModel,
                        session: session,
                        server: server,
                        actions: actions
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
        // Keep the compact baseline while allowing the caption to grow under
        // Dynamic Type instead of clipping the strip at its fixed baseline.
        .frame(minHeight: 76)
        .accessibilityElement(children: .contain)
    }
}

struct PinnedSessionStripItem: View {
    let viewModel: SessionListViewModel
    let session: SessionSummary
    let server: URL
    let actions: SessionListRowActions

    var actionCapabilities: SessionRowActionPolicy.Capabilities {
        SessionRowActionPolicy.Capabilities(
            isSearchOnlySession: viewModel.isSearchOnlySession(session),
            isViewingCachedData: viewModel.isViewingCachedData
        )
    }

    var body: some View {
        Button {
            actions.open(session)
        } label: {
            VStack(spacing: 3) {
                avatar
                    .frame(width: 48, height: 48)

                Text(PinnedSessionStripPolicy.shortTitle(for: session))
                    .font(AppFont.caption2(weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 76)
            }
            .frame(width: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PinnedSessionStripPolicy.accessibilityLabel(for: session))
        .accessibilityHint("Opens this conversation.")
        .contextMenu {
            SessionRowContextMenu(
                session: session,
                projects: viewModel.projects,
                isViewingCachedData: viewModel.isViewingCachedData,
                isRenamingSession: viewModel.isRenamingSession,
                isCreatingProject: viewModel.isCreatingProject,
                isMovingSession: viewModel.isMovingSession,
                isLoadingProjects: viewModel.isLoadingProjects,
                isMutating: viewModel.isMutating(session),
                capabilities: actionCapabilities,
                actions: actions
            )
        }
    }

    @ViewBuilder
    var avatar: some View {
        if let identity = BirdAvatarIdentity(server: server, profile: session.profile) {
            BirdAvatarView(identity: identity)
        } else {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.28))
                Text(fallbackInitials)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .overlay {
                Circle()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            }
        }
    }

    var fallbackInitials: String {
        let title = SessionRowView.displayTitle(for: session)
        let words = title.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        if words.count > 1 {
            return String(words.prefix(2).compactMap(\.first)).uppercased()
        }

        return String(title.prefix(2)).uppercased()
    }
}

/// Compact native filter surface for the shell Sessions list. The controls are
/// deliberately local: they only change the existing sidebar predicates and do
/// not introduce a new server-side filter model.
struct SessionFiltersSheet: View {
    @Binding var selectedBot: String?
    @Binding var pinnedOnly: Bool
    @Binding var scheduledHistoryOnly: Bool
    @Binding var selectedProjectID: String?

    let botOptions: [String]
    let projects: [ProjectSummary]
    let projectsEnabled: Bool
    let clearFilters: () -> Void
    let createProject: () -> Void

    @Environment(\.dismiss) var dismiss

    var body: some View {
        List {
            Section {
                Picker("Bot", selection: $selectedBot) {
                    Text("All bots").tag(nil as String?)
                    ForEach(botOptions, id: \.self) { name in
                        Text(name).tag(Optional(name))
                    }
                }
            } header: {
                Text("Bot")
            }

            Section {
                Toggle("Pinned only", isOn: $pinnedOnly)
                Toggle("Scheduled history", isOn: $scheduledHistoryOnly)
                Text("Scheduled history shows past cron-origin sessions; it does not indicate an active job.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("History")
            }

            if projectsEnabled {
                Section {
                    Button {
                        selectedProjectID = nil
                    } label: {
                        filterChoiceLabel(
                            title: String(localized: "All projects"),
                            systemImage: "square.grid.2x2",
                            isSelected: selectedProjectID == nil
                        )
                    }
                    .buttonStyle(.plain)

                    ForEach(projects) { project in
                        Button {
                            selectedProjectID = project.projectId
                        } label: {
                            filterChoiceLabel(
                                title: projectDisplayName(project),
                                systemImage: "folder",
                                isSelected: selectedProjectID == project.projectId
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(project.projectId == nil)
                    }

                    Button("New project", systemImage: "folder.badge.plus", action: createProject)
                } header: {
                    Text("Project")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background { SemrehBackdrop().ignoresSafeArea() }
        .navigationTitle("Filters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Clear", action: clearFilters)
                    .disabled(!hasActiveFilters)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    var hasActiveFilters: Bool {
        selectedBot != nil
            || pinnedOnly
            || scheduledHistoryOnly
            || selectedProjectID != nil
    }

    func filterChoiceLabel(title: String, systemImage: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .frame(minHeight: 30)
    }

    func projectDisplayName(_ project: ProjectSummary) -> String {
        let name = project.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else {
            return String(localized: "Untitled Project")
        }
        return name
    }
}

enum SessionListForegroundRefreshPolicy {
    static func shouldRefresh(
        didCompleteInitialLoad: Bool,
        sceneIsActive: Bool
    ) -> Bool {
        didCompleteInitialLoad && sceneIsActive
    }
}

enum SessionListInitialLoad {
    @MainActor
    static func run(
        resolvePendingDeepLink: @escaping @MainActor () async -> Void,
        refreshSessionsAndActiveProfile: @escaping @MainActor () async -> Void,
        restoreLastSelectedSession: @escaping @MainActor (_ clearsMissingSelection: Bool) async -> Void
    ) async {
        async let initialRefresh: Void = refreshSessionsAndActiveProfile()
        await resolvePendingDeepLink()
        guard !Task.isCancelled else { return }
        // Cached rows are optimistic and may be empty or stale. Preserve the
        // persisted selection until the live list becomes authoritative.
        await restoreLastSelectedSession(false)
        await initialRefresh
        guard !Task.isCancelled else { return }
        // Reconcile against the authoritative list too. The first pass restores
        // instantly from cache; this second pass restores an empty/expired cache
        // and evicts a cache-restored session that disappeared on the server.
        await restoreLastSelectedSession(true)
    }
}

enum SidebarLoadOrdering {
    @MainActor
    static func run(
        resolveActiveProfile: @escaping @MainActor () async -> Void,
        loadSessions: @escaping @MainActor () async -> Void,
        loadProjects: (@MainActor () async -> Void)? = nil
    ) async {
        await resolveActiveProfile()
        guard !Task.isCancelled else { return }
        await loadSessions()
        guard !Task.isCancelled else { return }
        await loadProjects?()
    }
}

enum SessionListNewChatReturn {
    static func run(
        from oldValue: SessionNavigationDestination?,
        to newValue: SessionNavigationDestination?,
        suppressEmptyPlaceholders: () -> Void,
        refreshSessions: () -> Void
    ) {
        guard case .newChat = oldValue else { return }
        if case .newChat = newValue { return }

        // Keep this synchronous so an empty Untitled placeholder cannot flash
        // during the navigation transition. The refresh then adopts the server's
        // latest metadata for a new chat that has become contentful.
        suppressEmptyPlaceholders()
        refreshSessions()
    }
}

struct SemrehHeaderLogo: View {
    static let productName = ""
    static let productDescriptor = ""
    static let accessibilityLabelText = ""
    static let showsPortraitMedallion = false
    static let showsProductWordmark = false

    var body: some View {
        EmptyView()
    }
}

/// A request from `ContentView` to open the New Chat composer. Carries whether voice
/// dictation should auto-start (the "New Chat with Voice" App Intent, #338) and an optional
/// profile name to pin the new session to (the "New Chat in <Profile>" App Intent, #339).
/// A fresh `id` each time so a repeat invocation re-triggers navigation even if the previous
/// value lingers.
struct NewChatRequest: Equatable {
    let id: UUID
    let autoStartsVoiceInput: Bool
    /// When set, the new session is created pinned to this profile; nil uses the server's
    /// active profile (the plain "+" / "New Chat" behavior).
    let profileName: String?

    init(autoStartsVoiceInput: Bool = false, profileName: String? = nil) {
        self.id = UUID()
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
    }
}

struct PendingNewChatRoute: Identifiable, Hashable {
    let id = UUID()
    let initialDraft: String
    let initialAttachments: [SharedAttachmentImport]
    /// When true, the composer auto-starts voice dictation on appear (#338).
    let autoStartsVoiceInput: Bool
    /// When set, the new session is created pinned to this profile (#339).
    let profileName: String?

    init(
        initialDraft: String = "",
        initialAttachments: [SharedAttachmentImport] = [],
        autoStartsVoiceInput: Bool = false,
        profileName: String? = nil
    ) {
        self.initialDraft = initialDraft
        self.initialAttachments = initialAttachments
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
    }

    static func == (lhs: PendingNewChatRoute, rhs: PendingNewChatRoute) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum SessionListUtilityDestination: Hashable, Identifiable {
    /// Optional section to scroll to when Settings opens — "Manage Servers"
    /// passes `.servers`, a plain avatar tap passes `nil` (#283).
    case settings(SettingsScrollAnchor?)
    case tasks
    case kanban
    case skills
    case memory
    case insights
    /// Archived sessions screen (issue #17), also reachable from Settings.
    case archived
    case scheduled

    var id: Self { self }
}

struct SessionSearchTaskID: Hashable {
    let query: String
    let isViewingCachedData: Bool
}

struct ActiveSessionMonitorTaskID: Hashable {
    let hasActiveRows: Bool
    let isViewingCachedData: Bool
}

#Preview("Sessions Header") {
    Color.clear
        .frame(height: 80)
        .padding(24)
        .background(Color.black)
        .preferredColorScheme(.dark)
}
