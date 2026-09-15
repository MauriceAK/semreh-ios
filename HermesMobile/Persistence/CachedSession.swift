import Foundation
import SwiftData

enum CachePolicy {
    static let ttl: TimeInterval = 7 * 24 * 60 * 60
    static let maxMessages = 5_000
}

@Model
final class CachedSession {
    @Attribute(.unique) var cacheKey: String
    var serverURLString: String
    var sessionID: String
    var title: String?
    var workspace: String?
    var model: String?
    var modelProvider: String?
    var messageCount: Int?
    var createdAt: Double?
    var updatedAt: Double?
    var lastMessageAt: Double?
    var pinned: Bool?
    var archived: Bool?
    var projectId: String?
    var profile: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var estimatedCost: Double?
    var activeStreamId: String?
    var isStreaming: Bool?
    var isCliSession: Bool?
    var userMessageCount: Int?
    var hasPendingUserMessage: Bool?
    var pendingStartedAt: Double?
    var worktreePath: String?
    var sourceTag: String?
    var rawSource: String?
    var sessionSource: String?
    var sourceLabel: String?
    var parentSessionId: String?
    var relationshipType: String?
    var readOnly: Bool?
    var isReadOnly: Bool?
    var cachedAt: Date
    var expiresAt: Date

    init(serverURLString: String, session: SessionSummary, cachedAt: Date = Date()) {
        let sessionID = session.sessionId ?? session.id
        self.cacheKey = Self.cacheKey(serverURLString: serverURLString, sessionID: sessionID)
        self.serverURLString = serverURLString
        self.sessionID = sessionID
        self.cachedAt = cachedAt
        self.expiresAt = cachedAt.addingTimeInterval(CachePolicy.ttl)
        apply(session, cachedAt: cachedAt)
    }

    static func cacheKey(serverURLString: String, sessionID: String) -> String {
        "\(serverURLString)|session|\(sessionID)"
    }

    func apply(_ session: SessionSummary, cachedAt: Date = Date()) {
        title = session.title
        workspace = session.workspace
        model = session.model
        modelProvider = session.modelProvider
        messageCount = session.messageCount
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        lastMessageAt = session.lastMessageAt
        pinned = session.pinned
        archived = session.archived
        projectId = session.projectId
        profile = session.profile
        inputTokens = session.inputTokens
        outputTokens = session.outputTokens
        estimatedCost = session.estimatedCost
        activeStreamId = session.activeStreamId
        isStreaming = session.isStreaming
        isCliSession = session.isCliSession
        userMessageCount = session.userMessageCount
        hasPendingUserMessage = session.hasPendingUserMessage
        pendingStartedAt = session.pendingStartedAt
        worktreePath = session.worktreePath
        sourceTag = session.sourceTag
        rawSource = session.rawSource
        sessionSource = session.sessionSource
        sourceLabel = session.sourceLabel
        parentSessionId = session.parentSessionId
        relationshipType = session.relationshipType
        readOnly = session.readOnly
        isReadOnly = session.isReadOnly
        self.cachedAt = cachedAt
        expiresAt = cachedAt.addingTimeInterval(CachePolicy.ttl)
    }
}

/// Stable, bounded display data learned from a locally cached transcript.
/// Session-list DTO metadata is intentionally not used as a message preview.
struct CachedSessionPreviewIdentity: Hashable {
    let profile: String
    let sessionID: String

    init(profile: String, sessionID: String) {
        let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profile = trimmedProfile.isEmpty ? "default" : trimmedProfile
        self.sessionID = sessionID
    }
}

struct CachedSessionPreview: Equatable {
    let text: String
    /// Timestamp from the exact message used for `text`; never a session heartbeat.
    let messageTimestamp: Double?
    /// When this device last recomputed the preview from its cached transcript.
    /// This says nothing about messages created later by another client.
    let locallyObservedAt: Date?

    init(text: String, messageTimestamp: Double?, locallyObservedAt: Date? = nil) {
        self.text = text
        self.messageTimestamp = messageTimestamp
        self.locallyObservedAt = locallyObservedAt
    }
}

/// A compact sidecar avoids changing CachedSession's server/session-only cache
/// identity and keeps direct-profile previews isolated without copying bodies.
@Model
final class CachedSessionPreviewRecord {
    @Attribute(.unique) var cacheKey: String
    var serverURLString: String
    var profile: String
    var sessionID: String
    var previewText: String
    var messageTimestamp: Double?
    var cachedAt: Date
    var expiresAt: Date

    init(
        serverURLString: String,
        identity: CachedSessionPreviewIdentity,
        preview: CachedSessionPreview,
        cachedAt: Date = Date()
    ) {
        self.cacheKey = Self.cacheKey(
            serverURLString: serverURLString,
            profile: identity.profile,
            sessionID: identity.sessionID
        )
        self.serverURLString = serverURLString
        self.profile = identity.profile
        self.sessionID = identity.sessionID
        self.previewText = preview.text
        self.messageTimestamp = preview.messageTimestamp
        self.cachedAt = cachedAt
        self.expiresAt = cachedAt.addingTimeInterval(CachePolicy.ttl)
    }

    static func cacheKey(serverURLString: String, profile: String, sessionID: String) -> String {
        // Length-prefix each component so arbitrary profile/session text cannot
        // alias another tuple merely by containing the delimiter.
        "preview|\(serverURLString.utf8.count):\(serverURLString)\(profile.utf8.count):\(profile)\(sessionID.utf8.count):\(sessionID)"
    }

    func apply(_ preview: CachedSessionPreview, cachedAt: Date = Date()) {
        previewText = preview.text
        messageTimestamp = preview.messageTimestamp
        self.cachedAt = cachedAt
        expiresAt = cachedAt.addingTimeInterval(CachePolicy.ttl)
    }
}

enum CachedSessionPreviewBuilder {
    static let maximumCharacters = 240

    /// Selects the newest visible chat message from the caller's bounded tail.
    /// The caller supplies the same at-most-50-message window used by the cache.
    static func latest(in messages: [ChatMessage]) -> CachedSessionPreview? {
        for message in messages.reversed() {
            guard message.role == "user" || message.role == "assistant",
                  !TranscriptTurnClassifier.isToolResultOnlyMessage(message)
            else {
                continue
            }

            guard ChatMarkerMessageClassifier.classify(message) == nil else { continue }

            let rawText: String
            if let content = message.content,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rawText = content
            } else if let attachmentCount = message.attachments?.count, attachmentCount > 0 {
                rawText = attachmentCount == 1 ? "Sent an attachment" : "Sent \(attachmentCount) attachments"
            } else {
                continue
            }

            guard let previewText = normalizedPreview(rawText) else { continue }
            let timestamp = message.timestamp.flatMap { value in
                value.isFinite && value > 0 ? value : nil
            }
            return CachedSessionPreview(text: previewText, messageTimestamp: timestamp)
        }

        return nil
    }

    private static func normalizedPreview(_ rawText: String) -> String? {
        let compact = rawText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        guard compact.count > maximumCharacters else { return compact }
        return String(compact.prefix(maximumCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
