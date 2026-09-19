import SwiftUI
import UIKit
import Combine

/// Server-scoped local read markers for the shell's Messages-style rows.
///
/// The sessions endpoint provides message counts and timestamps, but it does
/// not provide a last-read marker. We therefore persist only the local marker
/// and derive unread state from a later timestamp when the payload proves that
/// non-user messages exist. First sight of an existing session is seeded as
/// read so opening the shell does not mark the entire history unread.
final class SessionReadStateStore: ObservableObject {
    static let shared = SessionReadStateStore()

    private static let keyPrefix = "semreh.session.last-read-at.v1"

    @Published private(set) var revision = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isUnread(for session: SessionSummary, server: URL) -> Bool {
        guard let marker = latestAgentActivityMarker(for: session),
              let key = markerKey(for: session, server: server)
        else {
            return false
        }

        guard let storedMarker = defaults.object(forKey: key) as? Double else {
            defaults.set(marker, forKey: key)
            return false
        }

        return marker > storedMarker
    }

    func markRead(_ session: SessionSummary, server: URL) {
        guard let marker = latestActivityMarker(for: session),
              let key = markerKey(for: session, server: server)
        else {
            return
        }

        defaults.set(marker, forKey: key)
        revision &+= 1
    }

    static func hasAgentReplySignal(_ session: SessionSummary) -> Bool {
        guard let totalMessages = session.messageCount,
              let userMessages = session.userMessageCount
        else {
            return false
        }

        return totalMessages > userMessages
    }

    private func latestAgentActivityMarker(for session: SessionSummary) -> Double? {
        guard Self.hasAgentReplySignal(session) else { return nil }
        return latestActivityMarker(for: session)
    }

    private func latestActivityMarker(for session: SessionSummary) -> Double? {
        let marker = session.lastMessageAt ?? session.updatedAt ?? session.createdAt
        guard let marker, marker > 0 else { return nil }
        return marker
    }

    private func markerKey(for session: SessionSummary, server: URL) -> String? {
        let sessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionID, !sessionID.isEmpty else { return nil }

        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        let serverKey = components?.string ?? server.host ?? "unknown-server"

        return "\(Self.keyPrefix).\(serverKey).\(sessionID)"
    }
}

/// Which of the session list's optional navigation rows are shown, so a user can
/// hide the parts of the app they never use (issue #189).
struct SidebarSectionVisibility: Equatable {
    var tasks: Bool
    var kanban: Bool
    var skills: Bool
    var memory: Bool
    var insights: Bool
    var activeProfile: Bool
    var projects: Bool

    /// Show every row, primarily for previews and tests.
    static let showAll = SidebarSectionVisibility(
        tasks: true,
        kanban: true,
        skills: true,
        memory: true,
        insights: true,
        activeProfile: true,
        projects: true
    )

    /// The five plain links share one List row, so that row is dropped entirely
    /// once all of them are hidden rather than leaving an empty padded gap.
    var showsAnyUtilityLink: Bool {
        tasks || kanban || skills || memory || insights
    }
}

enum SessionListUtilityRowsVisibilityPolicy {
    static func visibleSections(
        usesShellChrome: Bool,
        projectsEnabled: Bool,
        isSearchingSessions: Bool,
        userVisibility: SidebarSectionVisibility
    ) -> SidebarSectionVisibility? {
        guard !isSearchingSessions else { return nil }
        var effectiveVisibility = userVisibility
        effectiveVisibility.projects = projectsEnabled && userVisibility.projects
        guard usesShellChrome else { return effectiveVisibility }
        guard effectiveVisibility.projects else { return nil }

        return SidebarSectionVisibility(
            tasks: false,
            kanban: false,
            skills: false,
            memory: false,
            insights: false,
            activeProfile: false,
            projects: true
        )
    }
}

/// Pure, testable backing model for the session-list avatar's long-press server
/// switcher (#283). Maps `AuthManager.servers` + the active server id into the
/// rows the context menu renders, deriving each row's display name the same way
/// the Settings server list does, so the menu's contents — and which server is
/// marked active — are unit-testable without standing up the view.
struct AvatarServerSwitcherModel: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: String
        let account: ServerAccount
        let displayName: String
        let isActive: Bool
    }

    let entries: [Entry]

    /// The id of the entry marked active, or nil when the active id matches no
    /// configured server (a defensive transient, e.g. mid-removal).
    var activeID: String? { entries.first(where: \.isActive)?.id }

    init(servers: [ServerAccount], activeServerID: String?) {
        entries = servers.map { account in
            let hostFallback = URL(string: account.urlString)?.host ?? account.urlString
            let displayName = account.displayName.isEmpty ? hostFallback : account.displayName
            return Entry(
                id: account.id,
                account: account,
                displayName: displayName,
                isActive: account.id == activeServerID
            )
        }
    }
}
