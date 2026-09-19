import Foundation
import Observation
import SwiftData
import SwiftUI

extension SessionListViewModel {
    func setPinned(
        _ pinned: Bool,
        for session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        await mutateDirectMetadata(
            session,
            modelContext: modelContext,
            animation: animation,
            field: .pinned(pinned)
        ) { [sessionMutator] sessionID, profile in
            try await sessionMutator.setPinned(pinned, sessionID: sessionID, profile: profile)
        }
    }

    func archive(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        let profile = Self.nonEmpty(activeProfileName) ?? "default"
        let profileEpoch = activeProfileEpoch
        let succeeded = await mutateDirectMetadata(
            session,
            modelContext: modelContext,
            animation: animation,
            field: .archived(true)
        ) { [sessionMutator] sessionID, profile in
            try await sessionMutator.archive(sessionID: sessionID, profile: profile)
        }
        guard succeeded, activeProfileEpoch == profileEpoch else { return false }
        await refreshArchivedCountForProfile(profile)
        // A count failure does not undo a confirmed archive. A replaced UI
        // scope must not consume this completion as its own navigation action.
        return !Task.isCancelled && activeProfileEpoch == profileEpoch
    }

    func delete(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to delete a session.")
            return false
        }
        guard !isSearchOnlySession(session) else {
            actionErrorMessage = String(localized: "This search result cannot be deleted yet.")
            return false
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let profile = Self.nonEmpty(session.profile) ?? Self.nonEmpty(activeProfileName) ?? "default"
        let activeProfile = Self.nonEmpty(activeProfileName) ?? "default"
        guard profile == activeProfile else {
            actionErrorMessage = String(localized: "Switch to this session's profile before deleting it.")
            return false
        }
        let scope = PendingMetadataKey(profile: profile, sessionID: sessionId)
        guard !deleteOutcomeUnknownKeys.contains(scope) else {
            actionErrorMessage = DirectSessionDeleteError.outcomeUnknown.localizedDescription
            return false
        }
        let profileEpoch = activeProfileEpoch

        guard beginSessionMutation(sessionId) else { return false }
        defer { endSessionMutation(sessionId) }

        actionErrorMessage = nil
        lastError = nil
        let pendingDeletion = PendingSessionDeletion(
            sessionsBeforeDeletion: sessions,
            archivedCountBeforeDeletion: archivedCount,
            successfulLoadGenerationAtStart: successfulLoadGeneration,
            latestCanonicalSessions: nil,
            latestCanonicalArchivedCount: nil
        )
        pendingSessionDeletions[sessionId] = pendingDeletion

        // The destructive confirmation has already happened in the view. Remove
        // the row before the network round trip so the list responds immediately.
        applySessions(
            sessions.filter { Self.nonEmpty($0.sessionId) != sessionId },
            archivedCount: archivedCount,
            animation: animation
        )
        if let modelContext {
            do {
                try CacheStore.deleteSession(
                    sessionID: sessionId,
                    serverURL: server,
                    profile: profile,
                    in: modelContext
                )
            } catch {
                cacheErrorMessage = error.localizedDescription
            }
        }

        do {
            let runtime = try await gatewayRuntimeProvider(client)
            guard !Task.isCancelled, activeProfileEpoch == profileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile else {
                rollbackPendingSessionDeletion(sessionId, modelContext: modelContext, animation: animation)
                return false
            }
            try await sessionMutator.delete(
                sessionID: sessionId,
                profile: profile,
                runtime: runtime,
                validateBeforeDispatch: { [weak self] in
                    guard let self else { return false }
                    return !Task.isCancelled && self.activeProfileEpoch == profileEpoch
                        && (Self.nonEmpty(self.activeProfileName) ?? "default") == profile
                }
            )

            // The exact delete is confirmed, but a replacement profile must not
            // inherit this profile's pending state or global row tombstone.
            guard !Task.isCancelled, activeProfileEpoch == profileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile else {
                pendingSessionDeletions.removeValue(forKey: sessionId)
                return false
            }

            // Keep the tombstone active while the follow-up list load runs so an
            // eventually-consistent response cannot resurrect the acknowledged row.
            confirmedSessionDeletionIDs.insert(sessionId)
            _ = await load(modelContext: modelContext, animation: animation)
            pendingSessionDeletions.removeValue(forKey: sessionId)
            guard !Task.isCancelled, activeProfileEpoch == profileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile else { return false }
            actionErrorMessage = nil
            lastError = nil
            return true
        } catch DirectSessionDeleteError.outcomeUnknown {
            deleteOutcomeUnknownKeys.insert(scope)
            rollbackPendingSessionDeletion(sessionId, modelContext: modelContext, animation: animation)
            guard !Task.isCancelled, activeProfileEpoch == profileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile else { return false }
            actionErrorMessage = DirectSessionDeleteError.outcomeUnknown.localizedDescription
            return false
        } catch {
            let wasCancelled = isCancellationError(error)
            rollbackPendingSessionDeletion(sessionId, modelContext: modelContext, animation: animation)
            guard !wasCancelled, activeProfileEpoch == profileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func isMutating(_ session: SessionSummary) -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else { return false }
        return mutatingSessionIDs.contains(sessionId)
    }

    func rename(_ session: SessionSummary, to rawTitle: String, modelContext: ModelContext? = nil) async -> Bool {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to rename a session.")
            return false
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard let title = Self.nonEmpty(rawTitle) else {
            actionErrorMessage = String(localized: "Enter a session title.")
            return false
        }

        isRenamingSession = true
        defer { isRenamingSession = false }
        return await mutateDirectMetadata(
            session,
            modelContext: modelContext,
            animation: nil,
            field: .title(title)
        ) { [sessionMutator] sessionID, profile in
            let response = try await sessionMutator.rename(
                sessionID: sessionID,
                title: title,
                profile: profile
            )
            return response.session ?? session
        }
    }

    func duplicate(_ session: SessionSummary, modelContext: ModelContext? = nil) async -> SessionSummary? {
        guard !isSearchOnlySession(session) else {
            actionErrorMessage = String(localized: "This search result cannot be duplicated yet.")
            return nil
        }
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        let profile = Self.nonEmpty(session.profile) ?? Self.nonEmpty(activeProfileName) ?? "default"
        let activeProfile = Self.nonEmpty(activeProfileName) ?? "default"
        guard profile == activeProfile else {
            actionErrorMessage = String(localized: "Switch to this session's profile before duplicating it.")
            return nil
        }
        let scope = PendingMetadataKey(profile: profile, sessionID: sessionId)
        guard !duplicateOutcomeUnknownKeys.contains(scope) else {
            actionErrorMessage = String(localized: "Hermes may already have duplicated this session. Inspect the session list for the copy; another duplicate is blocked.")
            return nil
        }
        let profileEpoch = activeProfileEpoch

        guard beginSessionMutation(sessionId) else { return nil }
        defer { endSessionMutation(sessionId) }

        actionErrorMessage = nil
        lastError = nil

        do {
            let runtime = try await gatewayRuntimeProvider(client)
            guard !Task.isCancelled, activeProfileEpoch == profileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile else { return nil }
            let result = try await sessionMutator.duplicate(
                sessionID: sessionId,
                title: duplicateTitle(for: session),
                profile: profile,
                runtime: runtime
            )

            if result.session == nil, result.createdSessionID != nil {
                // Record this against the original scope before considering the
                // currently displayed profile. The child exists even if the UI
                // switched profiles while its detail read was pending.
                duplicateOutcomeUnknownKeys.insert(scope)
            }
            guard !Task.isCancelled, activeProfileEpoch == profileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile else { return nil }

            guard let duplicatedSession = result.session else {
                if let childID = result.createdSessionID {
                    await load(modelContext: modelContext)
                    guard !Task.isCancelled, activeProfileEpoch == profileEpoch,
                          (Self.nonEmpty(activeProfileName) ?? "default") == profile else { return nil }
                    if let recovered = sessions.first(where: {
                        Self.nonEmpty($0.sessionId) == childID
                            && (Self.nonEmpty($0.profile) ?? profile) == profile
                    }) {
                        duplicateOutcomeUnknownKeys.remove(scope)
                        return recovered
                    }
                }
                actionErrorMessage = result.errorMessage
                return nil
            }

            await load(modelContext: modelContext)
            guard !Task.isCancelled, activeProfileEpoch == profileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile else { return nil }
            if !sessions.contains(where: { $0.sessionId == duplicatedSession.sessionId }) {
                sessions.insert(duplicatedSession, at: 0)

                if let modelContext {
                    do {
                        try CacheStore.cacheSessions(sessions, serverURL: server, in: modelContext)
                    } catch {
                        cacheErrorMessage = error.localizedDescription
                    }
                }
            }
            return duplicatedSession
        } catch DirectSessionBranchError.outcomeUnknown {
            duplicateOutcomeUnknownKeys.insert(scope)
            guard !Task.isCancelled, activeProfileEpoch == profileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile else { return nil }
            actionErrorMessage = String(localized: "Hermes may already have duplicated this session. Inspect the session list for the copy; another duplicate is blocked.")
            return nil
        } catch {
            guard !Task.isCancelled, activeProfileEpoch == profileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile else { return nil }
            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Downloads the scoped stock transcript and writes
    /// it to a unique temp directory so the share sheet can offer it as a file
    /// with a real filename. Returns the file URL, or nil after surfacing the
    /// failure through the standard action-error alert. The caller owns
    /// cleanup of the returned file's parent directory after sharing.
    func export(_ session: SessionSummary, format: SessionExportFormat,
                writeFile: (@Sendable (Data, URL) async throws -> Void)? = nil) async -> URL? {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to export a session.")
            return nil
        }
        guard !isSearchOnlySession(session) else {
            actionErrorMessage = String(localized: "This search result cannot be exported yet.")
            return nil
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        // Reuses the per-session mutation gate: it disables the row's other
        // actions while the download runs (the "progress state") and blocks a
        // double-tap from firing two exports.
        guard beginSessionMutation(sessionId) else { return nil }
        defer { endSessionMutation(sessionId) }
        let profileEpoch = activeProfileEpoch
        let profile = Self.nonEmpty(session.profile) ?? "default"

        actionErrorMessage = nil
        lastError = nil

        do {
            let file = try await client.exportSession(
                id: sessionId,
                format: format,
                fallbackTitle: session.title,
                profile: profile
            )

            try Task.checkCancellation()
            guard activeProfileEpoch == profileEpoch else { return nil }

            let directory = Self.exportsRootDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let fileURL = directory.appendingPathComponent(file.filename)
            do {
                if let writeFile { try await writeFile(file.data, fileURL) }
                else { try await SessionExportFile.write(file.data, to: fileURL) }
                try Task.checkCancellation()
                guard activeProfileEpoch == profileEpoch else { throw CancellationError() }
                return fileURL
            } catch {
                // Only this operation's new UUID directory; never sweep other shares.
                await Task.detached { try? FileManager.default.removeItem(at: directory) }.value
                throw error
            }
        } catch {
            guard activeProfileEpoch == profileEpoch else { return nil }
            guard !isCancellationError(error) else { return nil }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }
}
