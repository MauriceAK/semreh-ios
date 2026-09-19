import Foundation

/// The direct provider-discovery response. Fields remain optional because the
/// server may add or rename provider metadata without breaking the client.
struct DirectHermesAuthProvidersResponse: Decodable, Equatable {
    let providers: [DirectHermesAuthProvider]?
}

struct DirectHermesAuthProvider: Decodable, Equatable {
    let name: String?
    let displayName: String?
    let supportsPassword: Bool?
}

/// Public `/api/status` fields used by the direct auth bootstrap. The full
/// status document is intentionally not modeled here; unknown fields are
/// ignored and all captured fields are optional.
struct DirectHermesStatusResponse: Decodable, Equatable {
    let version: String?
    let releaseDate: String?
    let authRequired: Bool?
    let authProviders: [String]?
    let authFlows: [String]?
    let overall: String?
}

struct DirectHermesPasswordLoginResponse: Decodable, Equatable {
    let ok: Bool?
    let next: String?
}

struct DirectHermesWSTicketResponse: Decodable, Equatable {
    let ticket: String?
    let ttlSeconds: Int?
}

/// Structured 401 payloads emitted by protected Hermes routes.
struct DirectHermesAuthFailurePayload: Decodable, Equatable {
    let error: String?
    let detail: String?
    let reason: String?
    let loginURL: String?
}

enum DirectHermesAuthFailureClassifier {
    /// Only a 401 with one of Hermes' recognized structured error values is an
    /// expiry. Login's generic invalid-credential 401, 403, 429, and 503 are
    /// deliberately not classified here.
    static func isSessionExpired(statusCode: Int, body: Data) -> Bool {
        guard statusCode == 401,
              let payload = decodePayload(body),
              let error = payload.error?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else {
            return false
        }

        return error == "unauthenticated" || error == "session_expired"
    }

    private static func decodePayload(_ body: Data) -> DirectHermesAuthFailurePayload? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(DirectHermesAuthFailurePayload.self, from: body)
    }
}

enum DirectHermesHTTPFailureReason: Equatable {
    case invalidCredentials
    case unauthorized
    case forbidden
    case rateLimited
    case unavailable
    case other
}

/// A bounded direct-Hermes transport error. It retains only an HTTP status and
/// a small reason vocabulary; arbitrary response bodies are never carried into
/// UI errors or logs because a server could echo a credential or ticket.
enum DirectHermesRequestError: LocalizedError, Equatable {
    case http(statusCode: Int, reason: DirectHermesHTTPFailureReason)

    var errorDescription: String? {
        switch self {
        case let .http(statusCode, reason):
            switch reason {
            case .invalidCredentials:
                return String(localized: "The Hermes username or password was rejected.")
            case .unauthorized:
                return String(localized: "Hermes requires authentication for this request.")
            case .forbidden:
                return String(localized: "Hermes refused access to this request.")
            case .rateLimited:
                return String(localized: "Hermes is rate limiting requests. Try again shortly.")
            case .unavailable:
                return String(localized: "The Hermes authentication service is unavailable.")
            case .other:
                return String(localized: "Hermes returned HTTP \(statusCode).")
            }
        }
    }

    static func from(statusCode: Int, body: Data) -> Self {
        let payload = decodePayload(body)
        let detail = payload?.detail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let reason: DirectHermesHTTPFailureReason
        switch statusCode {
        case 401:
            reason = detail == "invalid credentials" ? .invalidCredentials : .unauthorized
        case 403:
            reason = .forbidden
        case 429:
            reason = .rateLimited
        case 503:
            reason = .unavailable
        default:
            reason = .other
        }
        return .http(statusCode: statusCode, reason: reason)
    }

    private static func decodePayload(_ body: Data) -> DirectHermesAuthFailurePayload? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(DirectHermesAuthFailurePayload.self, from: body)
    }
}

enum DirectHermesAuthError: LocalizedError, Equatable {
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .sessionExpired:
            return String(localized: "The Hermes session expired. Sign in again.")
        }
    }
}
