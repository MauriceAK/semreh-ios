import Foundation

enum DirectStartupDefaultWriteError: Error, Equatable, LocalizedError {
    case invalidName
    case unconfirmed

    var errorDescription: String? {
        switch self {
        case .invalidName: "The profile name is empty."
        case .unconfirmed: "The startup default could not be confirmed. Refresh its value before trying again."
        }
    }
}

extension APIClient {
    /// Stock changes the sticky default for subsequent Hermes invocations. It
    /// does not switch this app's selection or the running gateway's profile.
    /// A POST acknowledgement alone is not durable readback; never retry here.
    func directSetStartupDefaultProfile(name: String) async throws -> DirectHermesActiveProfile {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { throw DirectStartupDefaultWriteError.invalidName }
        let body = try JSONEncoder().encode(StartupDefaultRequest(name: normalized))
        let data = try await sendDirectData(path: "/api/profiles/active", method: "POST",
                                            encodedBody: body, classifyStructuredAuthExpiry: true)
        let acknowledgement = try decode(StartupDefaultAcknowledgement.self, from: data)
        guard acknowledgement.ok == true, acknowledgement.active == normalized else {
            throw DirectStartupDefaultWriteError.unconfirmed
        }
        let persisted = try await directActiveProfile()
        guard persisted.startupDefaultName == normalized else {
            throw DirectStartupDefaultWriteError.unconfirmed
        }
        return persisted
    }
}

private struct StartupDefaultRequest: Encodable { let name: String }
private struct StartupDefaultAcknowledgement: Decodable {
    let ok: Bool?
    let active: String?
}
