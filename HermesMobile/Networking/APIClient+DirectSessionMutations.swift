import Foundation

/// One official profile-scoped metadata mutation on a durable direct-Hermes
/// session. Each request carries exactly one operation.
enum DirectHermesSessionMutation: Equatable, Sendable {
    case title(String)
    case pinned(Bool)
    case archived(Bool)

    fileprivate var responseField: String {
        switch self {
        case .title: return "title"
        case .pinned: return "pinned"
        case .archived: return "archived"
        }
    }
}

struct DirectHermesSessionMutationReceipt: Equatable, Sendable {
    let sessionID: String
    let profile: String
    let operation: DirectHermesSessionMutation
}

enum DirectHermesSessionMutationError: LocalizedError, Equatable {
    case invalidSessionID
    case invalidProfile
    case missingAcknowledgement
    case serverRejected
    case missingReadback(field: String)

    var errorDescription: String? {
        switch self {
        case .invalidSessionID:
            return String(localized: "Hermes returned an invalid session identifier.")
        case .invalidProfile:
            return String(localized: "Hermes requires an explicit profile for this session.")
        case .missingAcknowledgement:
            return String(localized: "Hermes did not acknowledge the session change.")
        case .serverRejected:
            return String(localized: "Hermes rejected the session change.")
        case let .missingReadback(field):
            return String(localized: "Hermes did not confirm the session \(field) change.")
        }
    }
}

private struct DirectHermesSessionMutationResponse: Decodable {
    let ok: Bool?
    let title: String?
    let pinned: Bool?
    let archived: Bool?
}

private struct DirectHermesSessionMutationRequest: Encodable {
    let profile: String
    let operation: DirectHermesSessionMutation

    private enum CodingKeys: String, CodingKey {
        case profile, title, pinned, archived
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profile, forKey: .profile)
        switch operation {
        case let .title(value): try container.encode(value, forKey: .title)
        case let .pinned(value): try container.encode(value, forKey: .pinned)
        case let .archived(value): try container.encode(value, forKey: .archived)
        }
    }
}

extension APIClient {
    /// Applies one exact-ID PATCH operation through the stock direct-Hermes
    /// route. Success requires both ``ok == true`` and matching field readback.
    func directMutateSession(
        sessionID: String,
        operation: DirectHermesSessionMutation,
        profile: String = "default"
    ) async throws -> DirectHermesSessionMutationReceipt {
        guard let sessionID = Self.validDirectMutationSessionID(sessionID) else {
            throw DirectHermesSessionMutationError.invalidSessionID
        }
        let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = trimmedProfile.isEmpty ? "default" : trimmedProfile
        let body = try JSONEncoder().encode(
            DirectHermesSessionMutationRequest(profile: profile, operation: operation)
        )
        let encodedID = Self.directMutationPathSegment(sessionID)
        let data = try await sendDirectData(
            path: "/api/sessions/\(encodedID)",
            method: "PATCH",
            encodedBody: body,
            classifyStructuredAuthExpiry: true
        )
        let response = try decode(DirectHermesSessionMutationResponse.self, from: data)
        guard let ok = response.ok else {
            throw DirectHermesSessionMutationError.missingAcknowledgement
        }
        guard ok else {
            throw DirectHermesSessionMutationError.serverRejected
        }
        let readbackMatches: Bool
        switch operation {
        case let .title(value): readbackMatches = response.title == value
        case let .pinned(value): readbackMatches = response.pinned == value
        case let .archived(value): readbackMatches = response.archived == value
        }
        guard readbackMatches else {
            throw DirectHermesSessionMutationError.missingReadback(field: operation.responseField)
        }
        return DirectHermesSessionMutationReceipt(sessionID: sessionID, profile: profile, operation: operation)
    }

    private static func validDirectMutationSessionID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !trimmed.isEmpty, trimmed.count <= 128 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let first = trimmed.unicodeScalars.first,
              CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").contains(first)
        else { return nil }
        return trimmed
    }

    private static func directMutationPathSegment(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        ) ?? value
    }
}
