import SwiftUI

/// A Messages-inspired session row used only by the mobile shell. The existing
/// SessionRowView remains available for the desktop-like/sidebar presentation.
struct MessagesSessionRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var readStateStore = SessionReadStateStore.shared

    let session: SessionSummary
    let isViewingCachedData: Bool
    var server: URL? = nil
    /// Supplied only when an existing local transcript cache has a message for
    /// the row. It may lag other clients. The stock list preview is the first
    /// user message, so it is intentionally not inferred from SessionSummary.
    var latestMessagePreview: String? = nil
    /// A true message timestamp, not the session list's last-active heartbeat.
    var latestMessageTimestamp: Double? = nil
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
            latestMessagePreview: latestMessagePreview,
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

                    if let relativeDate {
                        Text(relativeDate)
                            .font(AppFont.footnote())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
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

    private var relativeDate: String? {
        guard let latestMessageTimestamp, latestMessageTimestamp > 0 else { return nil }

        return MessagesSessionDateFormatter.localizedString(
            for: Date(timeIntervalSince1970: latestMessageTimestamp)
        )
    }

    private var accessibilitySummary: String {
        var values = [SessionRowView.displayTitle(for: session), previewText]
        if let relativeDate {
            values.append(relativeDate)
        }
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
        latestMessagePreview: String? = nil,
        isViewingCachedData: Bool = false,
        liveOwnerSessionIDs: Set<String> = [],
        isUnread: Bool = false
    ) -> String {
        // Activity has its own row indicator. Keep verified message text stable
        // while heartbeat/status metadata changes during a refresh or run.
        if let latestMessagePreview = normalizedLatestMessagePreview(latestMessagePreview) {
            return latestMessagePreview
        }

        if SessionRowView.isActiveStreaming(session, liveOwnerSessionIDs: liveOwnerSessionIDs) {
            return "Streaming response…"
        }
        if session.hasPendingUserMessage == true {
            return "Waiting for your message…"
        }

        if isUnread {
            return "New agent reply"
        }

        // Missing preview evidence is not an empty conversation, nor proof of
        // an in-flight request. Keep one honest placeholder across metadata loads.
        return "No message preview yet"
    }

    /// Keeps the Messages row focused on a real message when one is supplied;
    /// a neutral placeholder is used until a verified message is available.
    static func normalizedLatestMessagePreview(_ rawPreview: String?) -> String? {
        guard let rawPreview else { return nil }
        let compact = rawPreview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty else { return nil }

        let maximumCharacters = 240
        guard compact.count > maximumCharacters else { return compact }
        return String(compact.prefix(maximumCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
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

enum MessagesSessionDateFormatter {
    static func localizedString(
        for date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone

        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday", locale: locale)
        }

        let dateTemplate = calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
            ? "MMMd"
            : "yMMMd"
        formatter.setLocalizedDateFormatFromTemplate(dateTemplate)
        return formatter.string(from: date)
    }
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
