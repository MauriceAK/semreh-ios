import Foundation

struct SessionDuplicateResult {
    let session: SessionSummary?
    let createdSessionID: String?
    let errorMessage: String?
}

private struct SessionDuplicateWhileRunningError: LocalizedError {
    var errorDescription: String? {
        String(localized: "This session is still responding, so it can't be duplicated yet. Try again when it finishes.")
    }
}

/// The server refuses `/api/session/move` with a 503 while the session is
/// streaming (it holds the per-session agent lock). Surface that as a specific,
/// actionable message instead of the generic "server unavailable" copy (issue #25).
struct SessionMoveWhileStreamingError: LocalizedError, Equatable {
    var errorDescription: String? {
        String(localized: "This session is still responding, so it can't be moved yet. Try again when it finishes.")
    }
}

struct SessionMutator {
    let client: APIClient

    func setPinned(_ pinned: Bool, sessionID: String, profile: String = "default") async throws -> SessionSummary {
        let detail = try await directMetadataSession(
            sessionID: sessionID,
            profile: profile,
            operation: .pinned(pinned)
        )
        guard detail.pinned == pinned else {
            throw DirectHermesSessionMutationError.missingReadback(field: "pinned")
        }
        return detail
    }

    func archive(sessionID: String, profile: String = "default") async throws -> SessionSummary {
        let detail = try await directMetadataSession(
            sessionID: sessionID,
            profile: profile,
            operation: .archived(true)
        )
        guard detail.archived == true else {
            throw DirectHermesSessionMutationError.missingReadback(field: "archived")
        }
        return detail
    }

    func delete(sessionID: String) async throws -> SessionMutationResponse {
        try await client.deleteSession(id: sessionID)
    }

    func rename(
        sessionID: String,
        title: String,
        profile: String = "default"
    ) async throws -> SessionMutationResponse {
        let detail = try await directMetadataSession(
            sessionID: sessionID,
            profile: profile,
            operation: .title(title)
        )
        guard detail.title == title else {
            throw DirectHermesSessionMutationError.missingReadback(field: "title")
        }
        return SessionMutationResponse(ok: true, session: detail, error: nil)
    }

    private func directMetadataSession(
        sessionID: String,
        profile rawProfile: String,
        operation: DirectHermesSessionMutation
    ) async throws -> SessionSummary {
        let profile = rawProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "default"
            : rawProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        let receipt = try await client.directMutateSession(
            sessionID: sessionID,
            operation: operation,
            profile: profile
        )
        guard receipt.sessionID == sessionID, receipt.profile == profile else {
            throw DirectHermesSessionMutationError.missingReadback(field: "identity")
        }

        let detail = try await client.directSessionDetail(sessionID: sessionID, profile: profile)
        guard detail.sessionId == sessionID,
              (detail.profile ?? profile) == profile
        else {
            throw DirectHermesSessionMutationError.missingReadback(field: "identity")
        }
        return detail
    }

    func move(sessionID: String, to projectID: String?) async throws {
        do {
            _ = try await client.moveSession(id: sessionID, projectID: projectID)
        } catch let error as APIError {
            // Only a 503 carrying the server's JSON error payload is the documented
            // "session is busy (streaming)" refusal; a proxy/tunnel 503 has no JSON
            // body and keeps the generic connectivity message.
            guard case .http(let statusCode, _) = error,
                  statusCode == 503,
                  error.serverMessage != nil
            else { throw error }

            throw SessionMoveWhileStreamingError()
        }
    }

    @MainActor
    func duplicate(
        sessionID: String,
        title: String,
        profile: String,
        runtime: HermesServerRuntime
    ) async throws -> SessionDuplicateResult {
        let parent = GatewayConversationController(
            runtime: runtime,
            client: client,
            storedID: sessionID,
            profile: profile
        )
        defer { parent.invalidate() }
        try await parent.open()
        guard parent.runState == .idle else { throw SessionDuplicateWhileRunningError() }

        let child = try await parent.branch(name: title)
        defer { child.invalidate() }
        guard let childID = child.storedID, !childID.isEmpty,
              child.profile == profile else {
            throw DirectSessionBranchError.invalidResponse
        }

        do {
            let detail = try await client.directSessionDetail(sessionID: childID, profile: profile)
            guard detail.sessionId == childID, (detail.profile ?? profile) == profile else {
                throw DirectHermesRESTError.profileMismatch
            }
            return SessionDuplicateResult(session: detail, createdSessionID: childID, errorMessage: nil)
        } catch {
            return SessionDuplicateResult(
                session: nil,
                createdSessionID: childID,
                errorMessage: String(localized: "The session was duplicated, but its details could not be loaded.")
            )
        }
    }
}
