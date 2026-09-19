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

enum DirectSessionDeleteError: LocalizedError, Equatable {
    case identityMismatch
    case activeSession
    case rejected(String)
    case outcomeUnknown

    var errorDescription: String? {
        switch self {
        case .identityMismatch:
            return String(localized: "Hermes did not confirm the exact session and profile to delete.")
        case .activeSession:
            return String(localized: "This session is open in Hermes, so it can't be deleted. Close it there, then try again.")
        case let .rejected(message):
            return message
        case .outcomeUnknown:
            return String(localized: "Hermes may have deleted this session, but the result could not be confirmed. Refresh to check the result; this app will not repeat the delete automatically.")
        }
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

    @MainActor
    func delete(
        sessionID: String,
        profile: String,
        runtime: HermesServerRuntime,
        validateBeforeDispatch: @MainActor () -> Bool
    ) async throws {
        let detail = try await client.directSessionDetail(sessionID: sessionID, profile: profile)
        guard detail.sessionId == sessionID, detail.profile == profile else {
            throw DirectSessionDeleteError.identityMismatch
        }
        guard validateBeforeDispatch() else { throw DirectSessionError.staleOperation }

        do {
            let result = try await runtime.request("session.delete", params: [
                "session_id": .string(sessionID),
                "profile": .string(profile)
            ])
            guard case .object(let fields) = result,
                  fields["deleted"]?.gatewayString == sessionID else {
                throw DirectSessionDeleteError.outcomeUnknown
            }
        } catch let error as HermesGatewayError {
            if case let .server(code, message, _, _, _, _) = error {
                if code == 4023 { throw DirectSessionDeleteError.activeSession }
                throw DirectSessionDeleteError.rejected(message)
            }
            throw DirectSessionDeleteError.outcomeUnknown
        } catch let error as DirectSessionDeleteError {
            throw error
        } catch {
            // Once request() starts, cancellation, reconnect-generation changes,
            // and decoding failures cannot prove whether Hermes deleted the row.
            throw DirectSessionDeleteError.outcomeUnknown
        }
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
