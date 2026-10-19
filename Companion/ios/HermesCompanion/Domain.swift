import Foundation

struct Invitation: Codable, Sendable {
    let version: Int
    let url: String
    let code: String

    static func parse(_ input: String) throws -> Invitation {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if trimmed.hasPrefix("hermes-companion:") {
            guard let components = URLComponents(string: trimmed),
                  let value = components.queryItems?.first(where: { $0.name == "invitation" })?.value else {
                throw ClientError.invalidInvitation
            }
            json = value
        } else {
            json = trimmed
        }
        let invitation = try JSONDecoder().decode(Invitation.self, from: Data(json.utf8))
        guard invitation.version == 1, !invitation.code.isEmpty else { throw ClientError.invalidInvitation }
        _ = try validatedBaseURL(invitation.url)
        return invitation
    }
}

func validatedBaseURL(_ raw: String) throws -> URL {
    guard let url = URL(string: raw), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let host = components.host, components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil,
          components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
        throw ClientError.insecureURL
    }
    return url
}

struct HostIdentity: Codable, Sendable { let name: String; let profile: String }
struct PairResult: Codable, Sendable { let version: Int; let deviceId: String; let token: String; let host: HostIdentity }
struct DeviceGrant: Codable, Sendable { let baseURL: String; let deviceID: String; let token: String; let host: HostIdentity }
struct ChatSession: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    let updatedAt: String
    let profile: String
}
struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let role: String
    var text: String
    var createdAt: String?
    var provisional: Bool
    var attachments: [AttachmentTicket]? = nil
    var displayText: String {
        let files = (attachments ?? []).map { "📎 " + $0.name }.joined(separator: "\n")
        return files.isEmpty ? text : text.isEmpty ? files : text + "\n\n" + files
    }
    var byteCount: Int { id.utf8.count + role.utf8.count + displayText.utf8.count + 128 }
}
struct HistoryPage: Codable, Sendable {
    let messages: [ChatMessage]
    let before: String?
    let hasMore: Bool
}
enum RunState: String, Codable, Sendable { case idle, working, waiting, synchronizing, offline, failed }
struct AgentChoice: Codable, Identifiable, Equatable, Sendable { let id: String; let label: String }
struct AgentRequest: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let generation: String
    let kind: String
    let title: String
    let description: String
    let choices: [AgentChoice]
    let allowsText: Bool?
}
struct ModelOption: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let provider: String
    let label: String
    let reasoning: Bool
    var key: String { provider + ":" + id }
}
struct SlashCommand: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let description: String
    var id: String { name }
}
struct AgentControls: Codable, Equatable, Sendable {
    let model: String
    let provider: String
    let pendingModel: String?
    let reasoning: String
    let reasoningLevels: [String]
    let models: [ModelOption]
    let commands: [SlashCommand]
}
struct SessionSnapshot: Codable, Sendable {
    let session: ChatSession
    let page: HistoryPage
    let state: RunState
    let requests: [AgentRequest]
    let controls: AgentControls
}
struct AgentCommand: Codable, Sendable {
    var operationId = UUID().uuidString.lowercased()
    let kind: String
    var text: String? = nil
    var attachmentIds: [String]? = nil
    var value: String? = nil
    var provider: String? = nil
    var confirmed: Bool? = nil
    var requestId: String? = nil
    var generation: String? = nil
    var answer: String? = nil
    var name: String? = nil
    var arg: String? = nil
}
enum ReceiptStatus: String, Codable, Sendable { case accepted, queued, steered, redirected, uncertain, rejected }
struct ModelConfirmation: Codable, Sendable { let kind: String; let value: String; let provider: String?; let message: String }
struct ConversationContext: Equatable, Sendable {
    let sessionID: String
    let hostGeneration: UUID
    let selectionGeneration: UUID
}
struct PendingModelConfirmation: Sendable {
    let details: ModelConfirmation
    let context: ConversationContext
}
struct CommandReceipt: Codable, Sendable {
    let operationId: String
    let status: ReceiptStatus
    let message: String?
    let userRowId: String?
    var confirmation: ModelConfirmation? = nil
}
struct FollowUpJob: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let instruction: String
    let schedule: String
    var enabled: Bool
    let sessionId: String?
    let nextRunAt: String?
    let lastStatus: String?
    let notify: String
}
struct AgentUpdate: Codable, Identifiable, Sendable {
    let id: String
    let kind: String
    let title: String
    let summary: String
    let createdAt: String
    let sessionId: String?
    let jobId: String?
    let resultSessionId: String?
}
struct UpdateDetail: Codable, Sendable { let update: AgentUpdate; let text: String; let resultSessionId: String? }
struct DeliveryPreferences: Codable, Sendable {
    var notificationsEnabled: Bool
    var quietStart: Int?
    var quietEnd: Int?
    var timeZone: String
    static var initial: Self { .init(notificationsEnabled: true, quietStart: nil, quietEnd: nil, timeZone: TimeZone.current.identifier) }
}
struct HostStatus: Decodable, Sendable {
    struct Capabilities: Decodable, Sendable { let notifications: Bool? }
    let version: Int
    let capabilities: Capabilities
}
struct SessionList: Decodable, Sendable { let sessions: [ChatSession] }
struct JobList: Decodable, Sendable { let jobs: [FollowUpJob] }
struct UpdateList: Decodable, Sendable { let updates: [AgentUpdate] }
struct RequestsPayload: Decodable, Sendable { let requests: [AgentRequest] }
struct ConnectionPayload: Decodable, Sendable { let state: String; let message: String? }
struct Delta: Codable, Sendable { let id: String; let text: String; let replace: Bool }
struct WireError: Decodable, Sendable { struct Detail: Decodable, Sendable { let code: String; let message: String }; let error: Detail }

struct WireEvent: Decodable, Sendable {
    enum Payload: Sendable {
        case snapshot(SessionSnapshot), delta(Delta), requests([AgentRequest]), controls(AgentControls)
        case receipt(CommandReceipt), update(AgentUpdate), connection(ConnectionPayload), ignored
    }
    let sessionId: String?
    let payload: Payload
    enum CodingKeys: String, CodingKey { case type, sessionId, payload }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        switch try container.decode(String.self, forKey: .type) {
        case "snapshot": payload = .snapshot(try container.decode(SessionSnapshot.self, forKey: .payload))
        case "delta": payload = .delta(try container.decode(Delta.self, forKey: .payload))
        case "requests": payload = .requests(try container.decode(RequestsPayload.self, forKey: .payload).requests)
        case "controls": payload = .controls(try container.decode(AgentControls.self, forKey: .payload))
        case "receipt": payload = .receipt(try container.decode(CommandReceipt.self, forKey: .payload))
        case "update": payload = .update(try container.decode(AgentUpdate.self, forKey: .payload))
        case "connection": payload = .connection(try container.decode(ConnectionPayload.self, forKey: .payload))
        default: payload = .ignored
        }
    }
}

enum ClientError: Error, LocalizedError, Sendable {
    case invalidInvitation, insecureURL, notPaired, payloadTooLarge, invalidResponse
    case server(Int, String, String)
    var errorDescription: String? {
        switch self {
        case .invalidInvitation: "This invitation is invalid. Create a new invitation on your Hermes host."
        case .insecureURL: "Remote hosts require HTTPS. Only loopback development hosts can use HTTP."
        case .notPaired: "Connect your Hermes host first."
        case .payloadTooLarge: "This response exceeds the safe display limit. Your conversation remains on Hermes."
        case .invalidResponse: "The host returned an unsupported response. Update Companion on both devices."
        case .server(_, _, let message): message
        }
    }
    var isDefiniteRejection: Bool {
        guard case .server(_, let code, _) = self else { return false }
        return ["unauthorized", "forbidden", "invalid_json", "stale_request", "host_action", "invalid_attachment", "attachment_limit", "attachment_expired", "attachment_not_found", "attachment_unavailable", "unsupported_attachment", "attachment_quota", "unsupported_media_type", "payload_too_large"].contains(code)
    }
}

struct TranscriptWindow: Sendable {
    static let maxRows = 500
    static let maxBytes = 8 * 1024 * 1024
    private(set) var messages: [ChatMessage] = []
    private(set) var before: String?
    private(set) var hasMore = false
    private(set) var hasNewer = false
    var byteCount: Int { messages.reduce(0) { $0 + $1.byteCount } }

    mutating func replace(_ page: HistoryPage) throws {
        try validate(page.messages)
        messages = deduplicated(page.messages)
        before = page.before
        hasMore = page.hasMore
        hasNewer = false
        trim(keepNewest: true)
    }
    mutating func prepend(_ page: HistoryPage) throws {
        try validate(page.messages)
        messages = deduplicated(page.messages + messages)
        before = page.before
        hasMore = page.hasMore
        trim(keepNewest: false)
    }
    mutating func apply(_ delta: Delta) throws {
        if hasNewer { return }
        if let index = messages.firstIndex(where: { $0.id == delta.id }) {
            let text = delta.replace ? delta.text : messages[index].text + delta.text
            guard text.utf8.count < Self.maxBytes else { throw ClientError.payloadTooLarge }
            messages[index].text = text
        } else {
            guard delta.text.utf8.count < Self.maxBytes else { throw ClientError.payloadTooLarge }
            messages.append(.init(id: delta.id, role: "assistant", text: delta.text, provisional: true))
        }
        trim(keepNewest: true)
    }
    private func validate(_ rows: [ChatMessage]) throws {
        guard rows.count <= 120, rows.reduce(0, { $0 + $1.byteCount }) <= Self.maxBytes else {
            throw ClientError.payloadTooLarge
        }
    }
    private func deduplicated(_ rows: [ChatMessage]) -> [ChatMessage] {
        var ids = Set<String>()
        return rows.filter { ids.insert($0.id).inserted }
    }
    private mutating func trim(keepNewest: Bool) {
        var bytes = byteCount
        while messages.count > Self.maxRows || bytes > Self.maxBytes {
            let removed = keepNewest ? messages.removeFirst() : messages.removeLast()
            bytes -= removed.byteCount
            if keepNewest { hasMore = true } else { hasNewer = true }
        }
    }
}
