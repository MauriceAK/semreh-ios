import Foundation

/// The official session-list ordering accepted by Hermes' profile-aware REST
/// route.  `recent` is the sidebar order; `created` is retained for callers
/// that need stable creation ordering.
enum DirectHermesSessionListOrder: String, Equatable, Sendable {
    case recent
    case created
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

    var errorDescription: String? {
        switch self {
        case .invalidSessionID:
            return String(localized: "Hermes returned an invalid session identifier.")
        case .missingCanonicalSessionID:
            return String(localized: "Hermes did not return a canonical Hermes session identifier.")
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
        let projection = Self.text(from: value)
        return ChatMessage(
            role: role,
            content: projection,
            timestamp: timestamp,
            messageId: id,
            name: name ?? toolName,
            toolCallId: toolCallId,
            toolUseId: toolUseId,
            toolCalls: isHidden ? nil : toolCalls,
            contentParts: parts,
            reasoning: isHidden ? nil : reasoning ?? reasoningContent,
            attachments: isHidden ? nil : attachments,
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
    /// Official durable session discovery.  The profile is always explicit;
    /// callers should use the default value rather than the cross-profile
    /// `all` aggregator for the active Semreh server.
    func directSessions(
        profile: String = "default",
        limit: Int = 20,
        offset: Int = 0,
        order: DirectHermesSessionListOrder = .recent
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
                URLQueryItem(name: "order", value: order.rawValue)
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
