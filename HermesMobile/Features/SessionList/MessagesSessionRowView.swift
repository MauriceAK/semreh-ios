import SwiftUI

/// A Messages-inspired session row used only by the mobile shell. The existing
/// SessionRowView remains available for the desktop-like/sidebar presentation.
struct MessagesSessionRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var readStateStore = SessionReadStateStore.shared

    let session: SessionSummary
    let isViewingCachedData: Bool
    var server: URL? = nil
    var liveOwnerSessionIDs: Set<String> = []

    private var resolvedLiveOwnerSessionIDs: Set<String> {
        liveOwnerSessionIDs.union(OpenChatSessionStore.shared.allLiveSessionIDs)
    }

    private var rowState: MessagesSessionRowState {
        MessagesSessionRowFormatter.rowState(
            for: session,
            liveOwnerSessionIDs: resolvedLiveOwnerSessionIDs,
            isUnread: isUnread
        )
    }

    private var isUnread: Bool {
        guard let server else { return false }
        return readStateStore.isUnread(for: session, server: server)
    }

    private var previewText: String {
        MessagesSessionRowFormatter.previewText(
            for: session,
            isViewingCachedData: isViewingCachedData,
            liveOwnerSessionIDs: resolvedLiveOwnerSessionIDs,
            isUnread: isUnread
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            avatarWithStatusIndicator

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(SessionRowView.displayTitle(for: session))
                        .font(AppFont.body(weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    Text(relativeDate)
                        .font(AppFont.footnote())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(previewText)
                        .font(AppFont.subheadline())
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.forward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 68, alignment: .center)
        .background {
            Rectangle()
                .fill(Color.clear)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 0.5)
                        .padding(.leading, 70)
                }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var avatarWithStatusIndicator: some View {
        ZStack(alignment: .bottomTrailing) {
            SessionAvatarView(session: session, server: server)

            switch rowState {
            case .live:
                MessagesLiveStreamingIndicator()
                    .offset(x: 2, y: 2)
            case .unread:
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .overlay {
                        Circle()
                            .stroke(Color(.systemBackground), lineWidth: 1.5)
                    }
                    .offset(x: 2, y: 2)
            case .idle:
                EmptyView()
            }
        }
        .frame(width: 44, height: 44)
    }

    private var relativeDate: String {
        let timestamp = session.lastMessageAt ?? session.updatedAt ?? session.createdAt
        guard let timestamp, timestamp > 0 else { return "—" }

        return MessagesSessionDateFormatter.shared.localizedString(
            for: Date(timeIntervalSince1970: timestamp),
            relativeTo: Date()
        )
    }

    private var accessibilitySummary: String {
        var values = [SessionRowView.displayTitle(for: session), previewText, relativeDate]
        if rowState == .live {
            values.append("Live")
        } else if rowState == .unread {
            values.append("Unread")
        }
        if isViewingCachedData {
            values.append("Cached")
        }
        return values.joined(separator: ", ")
    }
}

private struct SessionAvatarView: View {
    let session: SessionSummary
    let server: URL?

    @ViewBuilder
    var body: some View {
        if let identity = BirdAvatarIdentity(server: server, profile: session.profile) {
            BirdAvatarView(identity: identity)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        } else {
            fallbackAvatar
        }
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            SemrehVisualTheme.energy().opacity(0.85),
                            Color.accentColor.opacity(0.42)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if session.isCliSession == true {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(initials)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 44, height: 44)
        .overlay {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        let title = SessionRowView.displayTitle(for: session)
        let words = title.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        if words.count > 1 {
            return String(words.prefix(2).compactMap(\.first)).uppercased()
        }

        return String(title.prefix(2)).uppercased()
    }
}

private struct MessagesLiveStreamingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 10, height: 10)
            .overlay {
                Circle()
                    .stroke(Color(.systemBackground), lineWidth: 1.5)
            }
            .scaleEffect(reduceMotion ? 1.0 : (isPulsing ? 1.25 : 0.95))
            .opacity(reduceMotion ? 1.0 : (isPulsing ? 1.0 : 0.75))
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
            .onChange(of: reduceMotion) { _, newValue in
                if newValue {
                    isPulsing = false
                } else {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        isPulsing = true
                    }
                }
            }
            .onDisappear {
                isPulsing = false
            }
    }
}

/// Pure state and formatting helpers for Messages-style session rows.
enum MessagesSessionRowState: Equatable {
    case live
    case unread
    case idle
}

enum MessagesSessionRowFormatter {
    /// Evaluates live work before local unread state so a response in progress
    /// displays the green activity indicator rather than a stale unread dot.
    static func rowState(
        for session: SessionSummary,
        liveOwnerSessionIDs: Set<String> = [],
        isUnread: Bool = false
    ) -> MessagesSessionRowState {
        if SessionRowView.isActiveStreaming(session, liveOwnerSessionIDs: liveOwnerSessionIDs)
            || session.hasPendingUserMessage == true {
            return .live
        }

        if isUnread {
            return .unread
        }

        return .idle
    }

    /// Formats the secondary row preview, prioritizing useful latest activity over
    /// repeated metadata strings.
    static func previewText(
        for session: SessionSummary,
        isViewingCachedData: Bool = false,
        liveOwnerSessionIDs: Set<String> = [],
        isUnread: Bool = false
    ) -> String {
        // 1. Live activity / pending input takes highest priority
        if SessionRowView.isActiveStreaming(session, liveOwnerSessionIDs: liveOwnerSessionIDs) {
            return "Streaming response…"
        }
        if session.hasPendingUserMessage == true {
            return "Waiting for your message…"
        }

        if isUnread {
            return "New agent reply"
        }

        // 2. Specialized session run context
        if session.isCronSession {
            if let workspace = normalizedWorkspace(session.workspace) {
                return "Scheduled run · \(workspace)"
            }
            return "Scheduled run"
        }
        if session.isDelegatedSubagentSession {
            if let workspace = normalizedWorkspace(session.workspace) {
                return "Subagent run · \(workspace)"
            }
            return "Subagent run"
        }
        if session.isCliSession == true {
            if let workspace = normalizedWorkspace(session.workspace) {
                return "CLI session · \(workspace)"
            }
            return "CLI session"
        }

        // 3. Model in use (provides actionable model context)
        if let model = session.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            if let workspace = normalizedWorkspace(session.workspace) {
                return "\(model) · \(workspace)"
            } else if let profile = normalizedProfile(session.profile) {
                return "\(model) · \(profile)"
            } else {
                return model
            }
        }

        // 4. Secondary fallback: message count, workspace, profile metadata
        var parts: [String] = []
        if let count = session.messageCount, count > 0 {
            parts.append(count == 1 ? "1 message" : "\(count) messages")
        }
        if let workspace = normalizedWorkspace(session.workspace) {
            parts.append(workspace)
        }
        if let profile = normalizedProfile(session.profile) {
            parts.append(profile)
        }

        if parts.isEmpty {
            return isViewingCachedData ? "Cached Hermes session" : "Hermes session"
        }

        return parts.joined(separator: " · ")
    }

    static func normalizedWorkspace(_ rawWorkspace: String?) -> String? {
        guard let workspace = rawWorkspace?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspace.isEmpty
        else {
            return nil
        }

        let basename = (workspace as NSString).lastPathComponent
        return basename.isEmpty ? workspace : basename
    }

    static func normalizedProfile(_ rawProfile: String?) -> String? {
        guard let profile = rawProfile?.trimmingCharacters(in: .whitespacesAndNewlines),
              !profile.isEmpty
        else {
            return nil
        }

        return profile
    }
}

private enum MessagesSessionDateFormatter {
    static let shared: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

#Preview {
    MessagesSessionRowView(
        session: SessionSummary(
            sessionId: "preview",
            title: "Design the Semreh shell",
            workspace: "/Users/maurice/workspace/goku-ios",
            messageCount: 18,
            lastMessageAt: Date().addingTimeInterval(-86_400).timeIntervalSince1970,
            profile: "Chabby"
        ),
        isViewingCachedData: false
    )
    .padding(.horizontal)
    .background(Color.black)
}
