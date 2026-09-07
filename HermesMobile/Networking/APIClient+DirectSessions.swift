import Foundation

/// The official session-list ordering accepted by Hermes' profile-aware REST
/// route.  `recent` is the sidebar order; `created` is retained for callers
/// that need stable creation ordering.
enum DirectHermesSessionListOrder: String, Equatable, Sendable {
    case recent
    case created
}

/// The stock profile-aware session list's archive selector.  This is not the
/// legacy `include_archived` boolean: Hermes accepts exactly these values.
enum DirectHermesSessionArchiveFilter: String, Equatable, Sendable {
    case exclude
    case only
    case include
}

struct DirectHermesProfileReadError: Decodable, Equatable, Sendable {
    let profile: String?
    let error: String?
}

/// A bounded, profile-scoped official session-list page.  The domain rows are
/// mapped to the existing native `SessionSummary` type so callers do not need
/// a second sidebar model.
struct DirectHermesSessionPage: Equatable {
    let sessions: [SessionSummary]
    let total: Int?
    let limit: Int?
    let offset: Int?
    let profileTotals: [String: Int]?
    let errors: [DirectHermesProfileReadError]?
}

/// One result from Hermes' official `/api/sessions/search` route.  The
/// optional fields mirror the stock route's tolerant projection: a hit can be
/// produced from an ID or message-content match, and older rows may not have
/// every merged session metadata field.
struct DirectHermesSessionSearchResult: Decodable, Equatable, Sendable {
    let sessionID: String?
    let lineageRoot: String?
    let snippet: String?
    let role: String?
    let source: String?
    let model: String?
    let sessionStarted: Double?
    let id: String?
    let title: String?
    let startedAt: Double?
    let endedAt: Double?
    let lastActive: Double?
    let isActive: Bool?
    let messageCount: Int?
    let toolCallCount: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let preview: String?
    let parentSessionID: String?
    let archived: Bool?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case lineageRoot
        case snippet
        case role
        case source
        case model
        case sessionStarted
        case id
        case title
        case startedAt
        case endedAt
        case lastActive
        case isActive
        case messageCount
        case toolCallCount
        case inputTokens
        case outputTokens
        case preview
        case parentSessionID = "parentSessionId"
        case archived
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = container.decodeLossyStringIfPresent(forKey: .sessionID)
        lineageRoot = container.decodeLossyStringIfPresent(forKey: .lineageRoot)
        snippet = container.decodeLossyStringIfPresent(forKey: .snippet)
        role = container.decodeLossyStringIfPresent(forKey: .role)
        source = container.decodeLossyStringIfPresent(forKey: .source)
        model = container.decodeLossyStringIfPresent(forKey: .model)
        sessionStarted = container.decodeLossyDoubleIfPresent(forKey: .sessionStarted)
        id = container.decodeLossyStringIfPresent(forKey: .id)
        title = container.decodeLossyStringIfPresent(forKey: .title)
        startedAt = container.decodeLossyDoubleIfPresent(forKey: .startedAt)
        endedAt = container.decodeLossyDoubleIfPresent(forKey: .endedAt)
        lastActive = container.decodeLossyDoubleIfPresent(forKey: .lastActive)
        isActive = container.decodeLossyBoolIfPresent(forKey: .isActive)
        messageCount = container.decodeLossyIntIfPresent(forKey: .messageCount)
        toolCallCount = container.decodeLossyIntIfPresent(forKey: .toolCallCount)
        inputTokens = container.decodeLossyIntIfPresent(forKey: .inputTokens)
        outputTokens = container.decodeLossyIntIfPresent(forKey: .outputTokens)
        preview = container.decodeLossyStringIfPresent(forKey: .preview)
        parentSessionID = container.decodeLossyStringIfPresent(forKey: .parentSessionID)
        archived = container.decodeLossyBoolIfPresent(forKey: .archived)
    }
}

struct DirectHermesSessionSearchResponse: Decodable, Equatable, Sendable {
    let results: [DirectHermesSessionSearchResult]?
}

struct DirectHermesTranscriptPagination: Decodable, Equatable, Sendable {
    let limit: Int?
    let offset: Int?
    let order: String?
    let returned: Int?
}

/// A canonical transcript page.  Hermes returns rows in chronological order
/// even when `order=latest`; `offset` is measured backwards from the newest
/// row.  `sessionID` is the server-resolved continuation/tip identity.
struct DirectHermesTranscriptPage: Equatable {
    let sessionID: String
    let messages: [ChatMessage]
    let pagination: DirectHermesTranscriptPagination?
}

enum DirectHermesRESTError: LocalizedError, Equatable {
    case invalidSessionID
    case missingCanonicalSessionID
    case sessionIDMismatch
    case profileMismatch

    var errorDescription: String? {
        switch self {
        case .invalidSessionID:
            return String(localized: "Hermes returned an invalid session identifier.")
        case .missingCanonicalSessionID:
            return String(localized: "Hermes did not return a canonical Hermes session identifier.")
        case .sessionIDMismatch:
            return String(localized: "Hermes returned a different session than the requested link.")
        case .profileMismatch:
            return String(localized: "Hermes returned the linked session from a different profile.")
        }
    }
}

private struct DirectHermesSessionListEnvelope: Decodable {
    let sessions: [DirectHermesSessionRow]?
    let total: Int?
    let limit: Int?
    let offset: Int?
    let profileTotals: [String: Int]?
    let errors: [DirectHermesProfileReadError]?
}

/// Fields are deliberately optional: the profile aggregator can contain rows
/// written by older Hermes versions and may add fields independently.
private struct DirectHermesSessionRow: Decodable {
    let id: String?
    let title: String?
    let cwd: String?
    let model: String?
    let source: String?
    let startedAt: Double?
    let lastActive: Double?
    let messageCount: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let estimatedCostUsd: Double?
    let actualCostUsd: Double?
    let parentSessionId: String?
    let pinned: Bool?
    let archived: Bool?
    let profile: String?
    let isActive: Bool?
    let isCliSession: Bool?
    let userMessageCount: Int?
    let unread: Bool?
    let preview: String?
    let readOnly: Bool?
    let isReadOnly: Bool?

    func summary(defaultProfile: String) -> SessionSummary {
        SessionSummary(
            sessionId: id,
            title: title,
            workspace: cwd,
            model: model,
            messageCount: messageCount,
            createdAt: startedAt,
            updatedAt: lastActive,
            lastMessageAt: lastActive,
            pinned: pinned,
            archived: archived,
            profile: profile ?? defaultProfile,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCost: estimatedCostUsd ?? actualCostUsd,
            isStreaming: nil,
            isCliSession: isCliSession,
            userMessageCount: userMessageCount,
            hasPendingUserMessage: nil,
            sourceTag: source,
            rawSource: source,
            sessionSource: source,
            sourceLabel: source,
            parentSessionId: parentSessionId,
            readOnly: readOnly,
            isReadOnly: isReadOnly
        )
    }
}

/// The detail route returns the raw database row rather than the list
/// projection. In the pinned stock response, `archived` and `pinned` are
/// integer 0/1 values and activity is named `last_activity_at`; decode those
/// fields lossily without weakening the list-row contract above.
private struct DirectHermesSessionDetailRow: Decodable {
    let id: String?
    let title: String?
    let cwd: String?
    let model: String?
    let source: String?
    let startedAt: Double?
    let endedAt: Double?
    let lastActivityAt: Double?
    let messageCount: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let estimatedCostUsd: Double?
    let actualCostUsd: Double?
    let parentSessionId: String?
    let pinned: Bool?
    let archived: Bool?
    let profile: String?
    let profileName: String?
    let isDefaultProfile: Bool?
    let isCliSession: Bool?
    let readOnly: Bool?
    let isReadOnly: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyStringIfPresent(forKey: .id)
        title = container.decodeLossyStringIfPresent(forKey: .title)
        cwd = container.decodeLossyStringIfPresent(forKey: .cwd)
        model = container.decodeLossyStringIfPresent(forKey: .model)
        source = container.decodeLossyStringIfPresent(forKey: .source)
        startedAt = container.decodeLossyDoubleIfPresent(forKey: .startedAt)
        endedAt = container.decodeLossyDoubleIfPresent(forKey: .endedAt)
        lastActivityAt = container.decodeLossyDoubleIfPresent(forKey: .lastActivityAt)
        messageCount = container.decodeLossyIntIfPresent(forKey: .messageCount)
        inputTokens = container.decodeLossyIntIfPresent(forKey: .inputTokens)
        outputTokens = container.decodeLossyIntIfPresent(forKey: .outputTokens)
        estimatedCostUsd = container.decodeLossyDoubleIfPresent(forKey: .estimatedCostUsd)
        actualCostUsd = container.decodeLossyDoubleIfPresent(forKey: .actualCostUsd)
        parentSessionId = container.decodeLossyStringIfPresent(forKey: .parentSessionId)
        pinned = container.decodeLossyBoolIfPresent(forKey: .pinned)
        archived = container.decodeLossyBoolIfPresent(forKey: .archived)
        profile = container.decodeLossyStringIfPresent(forKey: .profile)
        profileName = container.decodeLossyStringIfPresent(forKey: .profileName)
        isDefaultProfile = container.decodeLossyBoolIfPresent(forKey: .isDefaultProfile)
        isCliSession = container.decodeLossyBoolIfPresent(forKey: .isCliSession)
        readOnly = container.decodeLossyBoolIfPresent(forKey: .readOnly)
        isReadOnly = container.decodeLossyBoolIfPresent(forKey: .isReadOnly)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, cwd, model, source, startedAt, endedAt, lastActivityAt
        case messageCount, inputTokens, outputTokens, estimatedCostUsd, actualCostUsd
        case parentSessionId, pinned, archived, profile, profileName, isDefaultProfile
        case isCliSession, readOnly, isReadOnly
    }

    func summary(defaultProfile: String) -> SessionSummary {
        let resolvedProfile = profile ?? profileName ?? defaultProfile
        return SessionSummary(
            sessionId: id,
            title: title,
            workspace: cwd,
            model: model,
            messageCount: messageCount,
            createdAt: startedAt,
            updatedAt: lastActivityAt ?? endedAt,
            lastMessageAt: lastActivityAt,
            pinned: pinned,
            archived: archived,
            profile: resolvedProfile,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCost: estimatedCostUsd ?? actualCostUsd,
            isCliSession: isCliSession,
            sourceTag: source,
            rawSource: source,
            sessionSource: source,
            sourceLabel: source,
            parentSessionId: parentSessionId,
            readOnly: readOnly,
            isReadOnly: isReadOnly
        )
    }
}

private struct DirectHermesMessageRow: Decodable {
    let id: String?
    let role: String?
    let content: JSONValue?
    let displayContent: JSONValue?
    let displayKind: String?
    let timestamp: Double?
    let reasoning: String?
    let reasoningContent: String?
    let name: String?
    let toolName: String?
    let toolCallId: String?
    let toolUseId: String?
    let toolCalls: [JSONValue]?
    let attachments: [MessageAttachment]?
    let turnTps: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case displayContent
        case displayKind
        case timestamp
        case reasoning
        case reasoningContent
        case name
        case toolName
        case toolCallId
        case toolUseId
        case toolCalls
        case attachments
        case turnTps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Hermes' durable SQLite row id is numeric; older projections may
        // stringify it.  Keep one stable native string identity either way.
        id = container.decodeLossyStringIfPresent(forKey: .id)
        role = container.decodeLossyStringIfPresent(forKey: .role)
        content = try? container.decodeIfPresent(JSONValue.self, forKey: .content)
        displayContent = try? container.decodeIfPresent(JSONValue.self, forKey: .displayContent)
        displayKind = container.decodeLossyStringIfPresent(forKey: .displayKind)
        timestamp = container.decodeLossyDoubleIfPresent(forKey: .timestamp)
        reasoning = container.decodeLossyStringIfPresent(forKey: .reasoning)
        reasoningContent = container.decodeLossyStringIfPresent(forKey: .reasoningContent)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        toolName = container.decodeLossyStringIfPresent(forKey: .toolName)
        toolCallId = container.decodeLossyStringIfPresent(forKey: .toolCallId)
        toolUseId = container.decodeLossyStringIfPresent(forKey: .toolUseId)
        toolCalls = try? container.decodeIfPresent([JSONValue].self, forKey: .toolCalls)
        attachments = try? container.decodeIfPresent([MessageAttachment].self, forKey: .attachments)
        turnTps = container.decodeLossyDoubleIfPresent(forKey: .turnTps)
    }

    func chatMessage() -> ChatMessage {
        let isHidden = displayKind == "hidden"
        let value: JSONValue?
        if isHidden {
            value = nil
        } else if let displayContent, displayContent != .null {
            value = displayContent
        } else {
            value = content
        }
        let parts = isHidden ? nil : Self.parts(from: value)
        let rawProjection = Self.text(from: value)
        let directProjection: DirectHermesMessageAttachmentProjection? = {
            guard !isHidden, role == "user" else { return nil }
            switch value {
            case .string(let text):
                return DirectHermesMessageAttachmentProjection.project(userContent: text)
            case .array(let parts):
                return DirectHermesMessageAttachmentProjection.project(userParts: parts)
            default:
                return nil
            }
        }()
        let projectedAttachments = isHidden
            ? nil
            : DirectHermesMessageAttachmentProjection.merge(
                explicit: attachments,
                inferred: directProjection?.attachments ?? []
            )
        return ChatMessage(
            role: role,
            // Preserve the server's canonical text. Attachment directives are
            // display-only and are removed by the transcript presentation
            // layer; edit/copy/matching/cache paths must retain the raw refs.
            content: rawProjection,
            timestamp: timestamp,
            messageId: id,
            name: name ?? toolName,
            toolCallId: toolCallId,
            toolUseId: toolUseId,
            toolCalls: isHidden ? nil : toolCalls,
            contentParts: parts,
            reasoning: isHidden ? nil : reasoning ?? reasoningContent,
            attachments: projectedAttachments,
            turnTps: turnTps
        )
    }

    private static func text(from value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text):
            return text
        case .number(let number):
            return String(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return nil
        case .array(let values):
            let text = values.compactMap { part -> String? in
                if case .string(let string) = part { return string }
                if case .object(let object) = part,
                   case .string(let string) = object["text"] {
                    return string
                }
                return nil
            }.joined()
            return text.isEmpty ? nil : text
        case .object(let object):
            if case .string(let type) = object["type"],
               type == "text",
               case .string(let text) = object["text"] {
                return text
            }
            // Unknown structured content belongs in contentParts when it is an
            // array; it must not become a visible JSON blob in the transcript.
            return nil
        }
    }

    private static func parts(from value: JSONValue?) -> [JSONValue]? {
        guard case .array(let values) = value else { return nil }
        return values
    }
}

private struct DirectHermesTranscriptEnvelope: Decodable {
    let sessionID: String?
    let messages: [DirectHermesMessageRow]?
    let pagination: DirectHermesTranscriptPagination?

    enum CodingKeys: String, CodingKey {
        // APIClient uses convertFromSnakeCase before matching these keys.
        case sessionID = "sessionId"
        case messages
        case pagination
    }
}

extension APIClient {
    /// Reads one exact durable session through Hermes' stock detail route.
    /// The route accepts prefixes, so callers must still receive the exact
    /// requested identity before using the result for a deep link.
    func directSessionDetail(
        sessionID rawSessionID: String,
        profile rawProfile: String = "default"
    ) async throws -> SessionSummary {
        guard let sessionID = Self.validDirectDetailSessionID(rawSessionID) else {
            throw DirectHermesRESTError.invalidSessionID
        }
        let profile = Self.directHermesProfile(rawProfile)
        let path = Self.directHermesPath(
            "/api/sessions/\(Self.directHermesPathSegment(sessionID))",
            queryItems: [URLQueryItem(name: "profile", value: profile)]
        )
        let data = try await sendDirectData(
            path: path,
            method: "GET",
            classifyStructuredAuthExpiry: true
        )
        let row = try decode(DirectHermesSessionDetailRow.self, from: data)
        guard let returnedID = row.id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !returnedID.isEmpty
        else {
            throw DirectHermesRESTError.missingCanonicalSessionID
        }
        guard returnedID == sessionID else {
            throw DirectHermesRESTError.sessionIDMismatch
        }
        if let returnedProfile = row.profile ?? row.profileName,
           !returnedProfile.isEmpty,
           returnedProfile != profile {
            throw DirectHermesRESTError.profileMismatch
        }
        return row.summary(defaultProfile: profile)
    }

    /// Official durable session discovery.  The profile is always explicit;
    /// callers should use the default value rather than the cross-profile
    /// `all` aggregator for the active Semreh server.
    func directSessions(
        profile: String = "default",
        limit: Int = 20,
        offset: Int = 0,
        order: DirectHermesSessionListOrder = .recent,
        archived: DirectHermesSessionArchiveFilter = .exclude
    ) async throws -> DirectHermesSessionPage {
        let profile = Self.directHermesProfile(profile)
        let boundedLimit = min(max(limit, 0), 500)
        let boundedOffset = max(offset, 0)
        let path = Self.directHermesPath(
            "/api/profiles/sessions",
            queryItems: [
                URLQueryItem(name: "profile", value: profile),
                URLQueryItem(name: "limit", value: String(boundedLimit)),
                URLQueryItem(name: "offset", value: String(boundedOffset)),
                URLQueryItem(name: "order", value: order.rawValue),
                URLQueryItem(name: "archived", value: archived.rawValue)
            ]
        )
        let data = try await sendDirectData(
            path: path,
            method: "GET",
            classifyStructuredAuthExpiry: true
        )
        let response = try decode(DirectHermesSessionListEnvelope.self, from: data)
        return DirectHermesSessionPage(
            sessions: response.sessions?.map { $0.summary(defaultProfile: profile) } ?? [],
            total: response.total,
            limit: response.limit,
            offset: response.offset,
            profileTotals: response.profileTotals,
            errors: response.errors
        )
    }

    /// Official read-only session-content/ID search.  The stock route caps a
    /// positive limit at 100; unlike the profile list it does not accept a
    /// meaningful zero-page request, so callers are bounded to 1...100.
    func directSearchSessions(
        query: String,
        profile: String = "default",
        limit: Int = 20
    ) async throws -> DirectHermesSessionSearchResponse {
        let profile = Self.directHermesProfile(profile)
        let boundedLimit = min(max(limit, 1), 100)
        let path = Self.directHermesPath(
            "/api/sessions/search",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "profile", value: profile),
                URLQueryItem(name: "limit", value: String(boundedLimit))
            ]
        )
        let data = try await sendDirectData(
            path: path,
            method: "GET",
            classifyStructuredAuthExpiry: true
        )
        return try decode(DirectHermesSessionSearchResponse.self, from: data)
    }

    /// Reads a bounded canonical transcript tail/page.  Hermes resolves old
    /// compression ancestors to the current durable tip in `session_id`.
    func directSessionMessages(
        sessionID: String,
        profile: String = "default",
        limit: Int = 120,
        offset: Int = 0
    ) async throws -> DirectHermesTranscriptPage {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DirectHermesRESTError.invalidSessionID
        }
        let profile = Self.directHermesProfile(profile)
        let boundedLimit = min(max(limit, 1), 500)
        let boundedOffset = max(offset, 0)
        let encodedID = Self.directHermesPathSegment(sessionID)
        let path = Self.directHermesPath(
            "/api/sessions/\(encodedID)/messages",
            queryItems: [
                URLQueryItem(name: "profile", value: profile),
                URLQueryItem(name: "limit", value: String(boundedLimit)),
                URLQueryItem(name: "offset", value: String(boundedOffset)),
                URLQueryItem(name: "order", value: "latest"),
                URLQueryItem(name: "include_compacted", value: "true")
            ]
        )
        let data = try await sendDirectData(
            path: path,
            method: "GET",
            classifyStructuredAuthExpiry: true
        )
        let response = try decode(DirectHermesTranscriptEnvelope.self, from: data)
        guard let sessionID = response.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else {
            throw DirectHermesRESTError.missingCanonicalSessionID
        }
        return DirectHermesTranscriptPage(
            sessionID: sessionID,
            messages: response.messages?.map { $0.chatMessage() } ?? [],
            pagination: response.pagination
        )
    }

    private static func directHermesProfile(_ profile: String) -> String {
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    private static func validDirectDetailSessionID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !trimmed.isEmpty, trimmed.count <= 128 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let first = trimmed.unicodeScalars.first,
              CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").contains(first)
        else { return nil }
        return trimmed
    }

    private static func directHermesPathSegment(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "-_~"))
        ) ?? value
    }

    private static func directHermesPath(_ path: String, queryItems: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.percentEncodedPath = path
        components.queryItems = queryItems
        return components.string ?? path
    }
}
