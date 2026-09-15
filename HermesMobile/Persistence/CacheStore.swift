import Foundation
import SwiftData

enum CacheStore {
    @MainActor
    static func cachedSessions(
        serverURL: URL,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> [SessionSummary] {
        let serverURLString = serverURL.absoluteString
        let descriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.serverURLString == serverURLString
            }
        )

        return try context.fetch(descriptor)
            .filter { $0.archived != true && $0.expiresAt > now }
            .map(SessionSummary.init(cachedSession:))
    }

    /// Loads all compact, locally observed previews for one server. The list
    /// joins by profile plus raw durable session ID without per-row cache reads
    /// or decoding transcript bodies.
    @MainActor
    static func cachedSessionPreviews(
        serverURL: URL,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> [CachedSessionPreviewIdentity: CachedSessionPreview] {
        let serverURLString = serverURL.absoluteString
        let descriptor = FetchDescriptor<CachedSessionPreviewRecord>(
            predicate: #Predicate { preview in
                preview.serverURLString == serverURLString
                    && preview.expiresAt > now
            }
        )

        return Dictionary(
            try context.fetch(descriptor).map { record in
                (
                    CachedSessionPreviewIdentity(profile: record.profile, sessionID: record.sessionID),
                    CachedSessionPreview(
                        text: record.previewText,
                        messageTimestamp: record.messageTimestamp,
                        locallyObservedAt: record.cachedAt
                    )
                )
            },
            uniquingKeysWith: { current, _ in current }
        )
    }

    @MainActor
    static func cachedMessages(
        serverURL: URL,
        sessionID: String,
        in context: ModelContext,
        limit: Int? = nil,
        now: Date = Date()
    ) throws -> [ChatMessage] {
        if let limit, limit <= 0 {
            return []
        }

        let serverURLString = serverURL.absoluteString
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { cachedMessage in
                cachedMessage.serverURLString == serverURLString
                    && cachedMessage.sessionID == sessionID
                    && cachedMessage.expiresAt > now
            },
            sortBy: [
                SortDescriptor(
                    \CachedMessage.sortIndex,
                    order: limit == nil ? .forward : .reverse
                )
            ]
        )
        if let limit {
            descriptor.fetchLimit = limit
        }

        let cachedMessages = try context.fetch(descriptor)
        if limit != nil {
            return cachedMessages.reversed().map(ChatMessage.init(cachedMessage:))
        }
        return cachedMessages.map(ChatMessage.init(cachedMessage:))
    }

    @MainActor
    static func cacheSessions(
        _ sessions: [SessionSummary],
        serverURL: URL,
        in context: ModelContext,
        cachedAt: Date = Date()
    ) throws {
        let serverURLString = serverURL.absoluteString
        let cacheableSessions = sessions.filter { $0.archived != true && $0.sessionId != nil }
        let existingDescriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.serverURLString == serverURLString
            }
        )
        let existingSessions = try context.fetch(existingDescriptor)
        var existingByKey = Dictionary(
            existingSessions.map { ($0.cacheKey, $0) },
            uniquingKeysWith: { current, _ in current }
        )

        for session in cacheableSessions {
            guard let sessionID = session.sessionId else { continue }
            let cacheKey = CachedSession.cacheKey(serverURLString: serverURLString, sessionID: sessionID)
            if let cachedSession = existingByKey.removeValue(forKey: cacheKey) {
                cachedSession.apply(session, cachedAt: cachedAt)
            } else {
                context.insert(CachedSession(serverURLString: serverURLString, session: session, cachedAt: cachedAt))
            }
        }

        for staleSession in existingByKey.values {
            context.delete(staleSession)
        }
        // This existing metadata cache is server/session keyed, while previews
        // are profile scoped. A profile-filtered session refresh cannot safely
        // identify which profile's missing previews should be purged; explicit
        // delete/archive, server clear, and TTL maintenance own that cleanup.

        try performMaintenance(in: context, now: cachedAt)
        try context.save()
    }

    @MainActor
    static func deleteSession(
        sessionID: String,
        serverURL: URL,
        profile: String? = nil,
        in context: ModelContext
    ) throws {
        let serverURLString = serverURL.absoluteString
        let cacheKey = CachedSession.cacheKey(serverURLString: serverURLString, sessionID: sessionID)
        let cachedSession = try cachedSession(cacheKey: cacheKey, in: context)
        if let cachedSession {
            context.delete(cachedSession)
        }
        try deleteSessionPreviews(
            serverURLString: serverURLString,
            sessionID: sessionID,
            profile: profile ?? cachedSession?.profile ?? "default",
            in: context
        )
        try context.save()
    }

    @MainActor
    static func cacheSession(
        _ session: SessionSummary,
        serverURL: URL,
        in context: ModelContext,
        cachedAt: Date = Date()
    ) throws {
        guard let sessionID = session.sessionId else { return }

        let serverURLString = serverURL.absoluteString
        let cacheKey = CachedSession.cacheKey(serverURLString: serverURLString, sessionID: sessionID)

        if session.archived == true {
            let cachedSession = try cachedSession(cacheKey: cacheKey, in: context)
            if let cachedSession {
                context.delete(cachedSession)
            }
            try deleteSessionPreviews(
                serverURLString: serverURLString,
                sessionID: sessionID,
                profile: session.profile ?? cachedSession?.profile ?? "default",
                in: context
            )
        } else if let cachedSession = try cachedSession(cacheKey: cacheKey, in: context) {
            cachedSession.apply(session, cachedAt: cachedAt)
        } else {
            context.insert(CachedSession(serverURLString: serverURLString, session: session, cachedAt: cachedAt))
        }

        try performMaintenance(in: context, now: cachedAt)
        try context.save()
    }

    @MainActor
    static func cacheMessages(
        _ messages: [ChatMessage],
        serverURL: URL,
        sessionID: String,
        previewIdentity: CachedSessionPreviewIdentity? = nil,
        in context: ModelContext,
        cachedAt: Date = Date()
    ) throws {
        let serverURLString = serverURL.absoluteString
        let existingDescriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { cachedMessage in
                cachedMessage.serverURLString == serverURLString
                    && cachedMessage.sessionID == sessionID
            }
        )
        let existingMessages = try context.fetch(existingDescriptor)
        var existingByKey = Dictionary(
            existingMessages.map { ($0.cacheKey, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var freshKeys = Set<String>()
        freshKeys.reserveCapacity(messages.count)

        for (offset, message) in messages.enumerated() {
            let cacheKey = CachedMessage.cacheKey(
                serverURLString: serverURLString,
                sessionID: sessionID,
                message: message,
                sortIndex: offset
            )
            freshKeys.insert(cacheKey)
            if let cachedMessage = existingByKey.removeValue(forKey: cacheKey) {
                cachedMessage.apply(message, sortIndex: offset, cachedAt: cachedAt)
            } else {
                context.insert(CachedMessage(
                    serverURLString: serverURLString,
                    sessionID: sessionID,
                    message: message,
                    sortIndex: offset,
                    cachedAt: cachedAt
                ))
            }
        }

        for staleMessage in existingByKey.values where !freshKeys.contains(staleMessage.cacheKey) {
            context.delete(staleMessage)
        }

        if let previewIdentity {
            if messages.isEmpty {
                try deleteSessionPreviews(
                    serverURLString: serverURLString,
                    sessionID: previewIdentity.sessionID,
                    profile: previewIdentity.profile,
                    in: context
                )
            } else if let preview = CachedSessionPreviewBuilder.latest(in: messages) {
                try upsertSessionPreview(
                    preview,
                    serverURLString: serverURLString,
                    identity: previewIdentity,
                    cachedAt: cachedAt,
                    in: context
                )
            } else {
                try deleteSessionPreviews(
                    serverURLString: serverURLString,
                    sessionID: previewIdentity.sessionID,
                    profile: previewIdentity.profile,
                    in: context
                )
            }
        }

        try performMaintenance(in: context, now: cachedAt)
        try context.save()
    }

    /// Deletes only the cached sessions and messages belonging to `serverURL`,
    /// leaving every other configured server's offline data intact (#18). Backs
    /// the Settings "Clear Offline Cache" action (active server) and the purge
    /// of a server's cache when it is removed, so a removed/reset server never
    /// leaves orphaned rows behind.
    @MainActor
    static func clearCache(for serverURL: URL, in context: ModelContext) throws {
        let serverURLString = serverURL.absoluteString

        let sessionDescriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.serverURLString == serverURLString
            }
        )
        for cachedSession in try context.fetch(sessionDescriptor) {
            context.delete(cachedSession)
        }

        let messageDescriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { cachedMessage in
                cachedMessage.serverURLString == serverURLString
            }
        )
        for cachedMessage in try context.fetch(messageDescriptor) {
            context.delete(cachedMessage)
        }

        let previewDescriptor = FetchDescriptor<CachedSessionPreviewRecord>(
            predicate: #Predicate { preview in
                preview.serverURLString == serverURLString
            }
        )
        for preview in try context.fetch(previewDescriptor) {
            context.delete(preview)
        }

        try context.save()
    }

    @MainActor
    private static func performMaintenance(in context: ModelContext, now: Date) throws {
        try deleteExpiredSessions(in: context, now: now)
        try deleteExpiredMessages(in: context, now: now)
        try deleteExpiredSessionPreviews(in: context, now: now)
        try evictOldestMessagesIfNeeded(in: context)
    }

    @MainActor
    private static func deleteExpiredSessions(in context: ModelContext, now: Date) throws {
        let descriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { $0.expiresAt <= now }
        )
        for session in try context.fetch(descriptor) {
            context.delete(session)
        }
    }

    @MainActor
    private static func deleteExpiredMessages(in context: ModelContext, now: Date) throws {
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.expiresAt <= now }
        )
        for message in try context.fetch(descriptor) {
            context.delete(message)
        }
    }

    @MainActor
    private static func deleteExpiredSessionPreviews(in context: ModelContext, now: Date) throws {
        let descriptor = FetchDescriptor<CachedSessionPreviewRecord>(
            predicate: #Predicate { $0.expiresAt <= now }
        )
        for preview in try context.fetch(descriptor) {
            context.delete(preview)
        }
    }

    @MainActor
    private static func evictOldestMessagesIfNeeded(in context: ModelContext) throws {
        let descriptor = FetchDescriptor<CachedMessage>()
        // Include pending inserts/deletes from reconciliation and expiration.
        // Most writes fit within the cap and need no full message fetch or sort.
        guard try context.fetchCount(descriptor) > CachePolicy.maxMessages else { return }
        let messages = try context.fetch(descriptor)
        let overflowCount = messages.count - CachePolicy.maxMessages
        guard overflowCount > 0 else { return }

        let messagesToEvict = messages
            .sorted { left, right in
                if left.cachedAt != right.cachedAt {
                    return left.cachedAt < right.cachedAt
                }

                if left.timestamp != right.timestamp {
                    return (left.timestamp ?? 0) < (right.timestamp ?? 0)
                }

                return left.sortIndex < right.sortIndex
            }
            .prefix(overflowCount)

        for message in messagesToEvict {
            context.delete(message)
        }
    }

    @MainActor
    private static func upsertSessionPreview(
        _ preview: CachedSessionPreview,
        serverURLString: String,
        identity: CachedSessionPreviewIdentity,
        cachedAt: Date,
        in context: ModelContext
    ) throws {
        let cacheKey = CachedSessionPreviewRecord.cacheKey(
            serverURLString: serverURLString,
            profile: identity.profile,
            sessionID: identity.sessionID
        )
        if let record = try cachedSessionPreview(cacheKey: cacheKey, in: context) {
            record.apply(preview, cachedAt: cachedAt)
        } else {
            context.insert(CachedSessionPreviewRecord(
                serverURLString: serverURLString,
                identity: identity,
                preview: preview,
                cachedAt: cachedAt
            ))
        }
    }

    @MainActor
    private static func deleteSessionPreviews(
        serverURLString: String,
        sessionID: String,
        profile: String,
        in context: ModelContext
    ) throws {
        let normalizedProfile = CachedSessionPreviewIdentity(profile: profile, sessionID: sessionID).profile
        let descriptor = FetchDescriptor<CachedSessionPreviewRecord>(
            predicate: #Predicate { preview in
                preview.serverURLString == serverURLString
                    && preview.sessionID == sessionID
                    && preview.profile == normalizedProfile
            }
        )
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
    }

    @MainActor
    private static func cachedSession(cacheKey: String, in context: ModelContext) throws -> CachedSession? {
        var descriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.cacheKey == cacheKey
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @MainActor
    private static func cachedSessionPreview(
        cacheKey: String,
        in context: ModelContext
    ) throws -> CachedSessionPreviewRecord? {
        var descriptor = FetchDescriptor<CachedSessionPreviewRecord>(
            predicate: #Predicate { preview in
                preview.cacheKey == cacheKey
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

private extension SessionSummary {
    init(cachedSession: CachedSession) {
        // These fields came from the removed WebUI list projection and describe
        // process-local state that cannot still be authoritative after a cache
        // restore. Direct Hermes list responses intentionally omit them; current
        // activity is supplied by OpenChatSessionStore's live owner instead.
        self.init(
            sessionId: cachedSession.sessionID,
            title: cachedSession.title,
            workspace: cachedSession.workspace,
            model: cachedSession.model,
            modelProvider: cachedSession.modelProvider,
            messageCount: cachedSession.messageCount,
            createdAt: cachedSession.createdAt,
            updatedAt: cachedSession.updatedAt,
            lastMessageAt: cachedSession.lastMessageAt,
            pinned: cachedSession.pinned,
            archived: cachedSession.archived,
            projectId: cachedSession.projectId,
            profile: cachedSession.profile,
            inputTokens: cachedSession.inputTokens,
            outputTokens: cachedSession.outputTokens,
            estimatedCost: cachedSession.estimatedCost,
            isCliSession: cachedSession.isCliSession,
            userMessageCount: cachedSession.userMessageCount,
            worktreePath: cachedSession.worktreePath,
            sourceTag: cachedSession.sourceTag,
            rawSource: cachedSession.rawSource,
            sessionSource: cachedSession.sessionSource,
            sourceLabel: cachedSession.sourceLabel,
            parentSessionId: cachedSession.parentSessionId,
            relationshipType: cachedSession.relationshipType,
            readOnly: cachedSession.readOnly,
            isReadOnly: cachedSession.isReadOnly
        )
    }
}

private extension ChatMessage {
    init(cachedMessage: CachedMessage) {
        let attachments: [MessageAttachment]?
        if let data = cachedMessage.attachmentsData {
            attachments = try? JSONDecoder().decode([MessageAttachment].self, from: data)
        } else {
            attachments = nil
        }
        let toolCalls: [JSONValue]?
        if let data = cachedMessage.toolCallsData {
            toolCalls = try? JSONDecoder().decode([JSONValue].self, from: data)
        } else {
            toolCalls = nil
        }
        let contentParts: [JSONValue]?
        if let data = cachedMessage.contentPartsData {
            contentParts = try? JSONDecoder().decode([JSONValue].self, from: data)
        } else {
            contentParts = nil
        }
        self.init(
            role: cachedMessage.role,
            content: cachedMessage.content,
            timestamp: cachedMessage.timestamp,
            messageId: cachedMessage.messageId,
            name: cachedMessage.name,
            toolCallId: cachedMessage.toolCallId,
            toolUseId: cachedMessage.toolUseId,
            toolCalls: toolCalls,
            contentParts: contentParts,
            reasoning: cachedMessage.reasoning,
            attachments: attachments,
            turnTps: cachedMessage.turnTps
        )
    }
}
