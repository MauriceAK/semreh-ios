import Foundation

enum SessionNavigationDestination: Hashable, Identifiable {
    case session(SessionSummary)
    case newChat(session: SessionSummary, route: PendingNewChatRoute)
    case utility(SessionListUtilityDestination)

    var id: Self { self }

    var selectedSessionID: String? {
        switch self {
        case .session(let session), .newChat(let session, _):
            return session.sessionId
        case .utility:
            return nil
        }
    }

    var loadsInitialMessages: Bool {
        if case .session = self { return true }
        return false
    }
}

enum SessionNewChatExternalRequestKind: Equatable {
    case sharedImport
    case appIntent
}

enum SessionNewChatExternalRequestPolicy {
    static func next(
        sharedImportPending: Bool,
        appIntentPending: Bool
    ) -> SessionNewChatExternalRequestKind? {
        if sharedImportPending { return .sharedImport }
        if appIntentPending { return .appIntent }
        return nil
    }
}

struct SessionNavigationState: Equatable {
    private enum DestinationOrigin: Equatable {
        case explicit
        case restored
    }

    private(set) var destination: SessionNavigationDestination?
    private(set) var lastSelectedSessionID: String?
    private(set) var rootRevision = 0
    private var pendingNewChatRoute: PendingNewChatRoute?
    private var deepLinkedSessionLoadID: String?
    private var destinationOrigin: DestinationOrigin?

    init(lastSelectedSessionID: String? = nil) {
        self.lastSelectedSessionID = Self.normalized(lastSelectedSessionID)
    }

    var selectedSessionID: String? {
        destination?.selectedSessionID
    }

    var isConversationPresented: Bool {
        switch destination {
        case .session, .newChat:
            true
        case .utility, nil:
            false
        }
    }

    var isCreatingNewChat: Bool {
        pendingNewChatRoute != nil
    }

    mutating func select(_ session: SessionSummary) {
        rootRevision += 1
        pendingNewChatRoute = nil
        destination = .session(session)
        destinationOrigin = .explicit
        remember(session)
    }

    @discardableResult
    mutating func beginNewChatCreation(_ route: PendingNewChatRoute) -> Bool {
        guard pendingNewChatRoute == nil else { return false }
        pendingNewChatRoute = route
        return true
    }

    @discardableResult
    mutating func completeNewChatCreation(
        _ session: SessionSummary,
        for route: PendingNewChatRoute
    ) -> Bool {
        // Direct New Chat is a local draft until first send. The route owns
        // navigation identity; a durable server ID is not required to open it.
        guard pendingNewChatRoute?.id == route.id else { return false }

        rootRevision += 1
        pendingNewChatRoute = nil
        destination = .newChat(session: session, route: route)
        destinationOrigin = .explicit
        remember(session)
        return true
    }

    mutating func cancelNewChatCreation(for route: PendingNewChatRoute? = nil) {
        guard route == nil || pendingNewChatRoute?.id == route?.id else { return }
        pendingNewChatRoute = nil
    }

    mutating func select(_ utility: SessionListUtilityDestination) {
        rootRevision += 1
        pendingNewChatRoute = nil
        destination = .utility(utility)
        destinationOrigin = .explicit
    }

    mutating func remember(_ session: SessionSummary) {
        guard let sessionID = Self.normalized(session.sessionId) else { return }
        lastSelectedSessionID = sessionID
    }

    mutating func clearDestination() {
        destination = nil
        pendingNewChatRoute = nil
        destinationOrigin = nil
    }

    /// The shell's surface switch is an explicit request to return to the
    /// Sessions root rather than reopen the last conversation. This is scoped to
    /// the shell presentation; regular session-list callers keep the existing
    /// last-session restoration behavior.
    mutating func resetForShellSurfaceSwitch() {
        destination = nil
        lastSelectedSessionID = nil
        pendingNewChatRoute = nil
        destinationOrigin = nil
    }

    mutating func beginDeepLinkedSessionLoad(id: String?) -> String? {
        guard deepLinkedSessionLoadID == nil,
              let sessionID = Self.normalized(id)
        else { return nil }

        deepLinkedSessionLoadID = sessionID
        return sessionID
    }

    mutating func finishDeepLinkedSessionLoad(id: String?) {
        guard Self.normalized(id) == deepLinkedSessionLoadID else { return }
        deepLinkedSessionLoadID = nil
    }

    /// Restores only when no explicit route already won. Deep links, shared drafts,
    /// and App Intent requests therefore take precedence over the stored selection.
    /// A pending or in-flight deep link (not yet resolved into a destination) also
    /// blocks the restore, so its network load is never pre-empted by the stored
    /// selection; the stored ID is kept for a later restore.
    mutating func restoreIfNeeded(
        from sessions: [SessionSummary],
        clearsMissingSelection: Bool = true,
        pendingDeepLinkedSessionID: String? = nil
    ) {
        guard destination == nil,
              pendingNewChatRoute == nil,
              deepLinkedSessionLoadID == nil,
              Self.normalized(pendingDeepLinkedSessionID) == nil,
              let lastSelectedSessionID
        else { return }

        guard let session = sessions.first(where: {
            Self.normalized($0.sessionId) == lastSelectedSessionID
        }) else {
            if clearsMissingSelection {
                self.lastSelectedSessionID = nil
            }
            return
        }

        destination = .session(session)
        destinationOrigin = .restored
    }

    /// Reconciles an already-restored (or still-empty) destination against the
    /// authoritative live session list. Unlike `restoreIfNeeded`, this can evict a
    /// destination that was opened from cache and later disappeared on the server.
    /// Explicit `select()` destinations — including deep-linked archived/hidden
    /// sessions that never appear in the sidebar — are left alone.
    mutating func reconcileAuthoritativeSelection(
        from sessions: [SessionSummary],
        pendingDeepLinkedSessionID: String? = nil
    ) {
        guard deepLinkedSessionLoadID == nil,
              Self.normalized(pendingDeepLinkedSessionID) == nil
        else { return }

        if destinationOrigin == .explicit {
            return
        }

        if case .session(let selected) = destination {
            let selectedID = Self.normalized(selected.sessionId)
            let stillExists = sessions.contains {
                Self.normalized($0.sessionId) == selectedID
            }
            if stillExists {
                return
            }
            destination = nil
            pendingNewChatRoute = nil
            destinationOrigin = nil
            if lastSelectedSessionID == selectedID {
                lastSelectedSessionID = nil
            }
            return
        }

        restoreIfNeeded(from: sessions, clearsMissingSelection: true, pendingDeepLinkedSessionID: pendingDeepLinkedSessionID)
    }

    /// Invalidates both the visible detail and stored restoration target when the
    /// removed session is the selected or most recently selected session.
    mutating func remove(sessionID: String?) {
        guard let sessionID = Self.normalized(sessionID) else { return }

        if selectedSessionID == sessionID {
            destination = nil
            pendingNewChatRoute = nil
            destinationOrigin = nil
        }

        if lastSelectedSessionID == sessionID {
            lastSelectedSessionID = nil
        }
    }

    private static func normalized(_ sessionID: String?) -> String? {
        guard let sessionID else { return nil }
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum SessionNavigationPersistence {
    private static let keyPrefix = "sessionNavigation.lastSelectedSessionID."

    static func key(for server: URL) -> String {
        keyPrefix + server.absoluteString
    }

    static func load(for server: URL, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(for: server))
    }

    static func save(_ sessionID: String?, for server: URL, defaults: UserDefaults = .standard) {
        let key = key(for: server)
        if let sessionID {
            defaults.set(sessionID, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
