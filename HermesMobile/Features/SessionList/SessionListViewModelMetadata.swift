import Foundation
import Observation
import SwiftData
import SwiftUI

extension SessionListViewModel {
    func rollbackPendingSessionDeletion(
        _ sessionID: String,
        modelContext: ModelContext?,
        animation: Animation?
    ) {
        guard let pendingDeletion = pendingSessionDeletions.removeValue(forKey: sessionID) else { return }
        confirmedSessionDeletionIDs.remove(sessionID)

        // Prefer the newest canonical response observed while the delete was
        // pending. It may contain a changed version of the row, and is the only
        // safe source after a refresh advanced successfulLoadGeneration.
        let canonicalSessions: [SessionSummary]
        let canonicalArchivedCount: Int?
        if let latestCanonicalSessions = pendingDeletion.latestCanonicalSessions {
            canonicalSessions = latestCanonicalSessions
            canonicalArchivedCount = pendingDeletion.latestCanonicalArchivedCount
        } else {
            // No refresh overlapped the mutation, so the exact pre-delete
            // snapshot is still the correct rollback source.
            guard successfulLoadGeneration <= pendingDeletion.successfulLoadGenerationAtStart else { return }
            canonicalSessions = pendingDeletion.sessionsBeforeDeletion
            canonicalArchivedCount = pendingDeletion.archivedCountBeforeDeletion
        }

        let hiddenSessionIDs = Set(pendingSessionDeletions.keys).union(confirmedSessionDeletionIDs)
        let restoredSessions = canonicalSessions.filter { session in
            guard let candidateID = Self.nonEmpty(session.sessionId) else { return true }
            return !hiddenSessionIDs.contains(candidateID)
        }
        applySessions(
            restoredSessions,
            archivedCount: canonicalArchivedCount,
            animation: animation
        )

        guard let restoredSession = canonicalSessions.first(where: {
            Self.nonEmpty($0.sessionId) == sessionID
        }), let modelContext else { return }
        do {
            try CacheStore.cacheSession(restoredSession, serverURL: server, in: modelContext)
        } catch {
            cacheErrorMessage = error.localizedDescription
        }
    }

    func beginSessionMutation(_ sessionId: String) -> Bool {
        mutatingSessionIDs.insert(sessionId).inserted
    }

    func endSessionMutation(_ sessionId: String) {
        mutatingSessionIDs.remove(sessionId)
    }

    func upsertProject(_ project: ProjectSummary) {
        guard let projectID = project.projectId, !projectID.isEmpty else { return }

        if let existingIndex = projects.firstIndex(where: { $0.projectId == projectID }) {
            projects[existingIndex] = project
        } else {
            projects.append(project)
        }
    }

    func mutate(
        modelContext: ModelContext? = nil,
        animation: Animation? = nil,
        _ operation: () async throws -> Void
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        do {
            try await operation()
            return await load(modelContext: modelContext, animation: animation)
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func mutateDirectMetadata(
        _ session: SessionSummary,
        modelContext: ModelContext?,
        animation: Animation?,
        field: PendingMetadataField,
        operation: (String, String) async throws -> SessionSummary
    ) async -> Bool {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to modify a session.")
            return false
        }
        guard let rawSessionID = session.sessionId,
              let sessionID = Self.nonEmpty(rawSessionID),
              rawSessionID == sessionID
        else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let activeProfile = Self.nonEmpty(activeProfileName) ?? "default"
        let profileEpoch = activeProfileEpoch
        let sessionProfile = Self.nonEmpty(session.profile) ?? "default"
        guard activeProfile == sessionProfile else {
            actionErrorMessage = String(localized: "Switch to this session's profile to modify it.")
            return false
        }
        let searchOnly = isSearchOnlySession(session)
        let capturedSearchQuery = activeRemoteSearchQuery
        let capturedSearchProfile = activeRemoteSearchProfile
        let capturedSearchGeneration = remoteSearchGeneration
        guard beginSessionMutation(sessionID) else { return false }
        defer { endSessionMutation(sessionID) }

        actionErrorMessage = nil
        lastError = nil
        let capturedServer = server

        do {
            let authoritative = try await operation(sessionID, activeProfile)
            guard isCurrentMetadataScope(
                server: capturedServer,
                profile: activeProfile,
                epoch: profileEpoch
            ),
                  authoritative.sessionId == sessionID,
                  (Self.nonEmpty(authoritative.profile) ?? activeProfile) == activeProfile
            else {
                return false
            }
            if searchOnly,
               !isCurrentRemoteSearchScope(
                   query: capturedSearchQuery,
                   profile: capturedSearchProfile,
                   generation: capturedSearchGeneration
               ) {
                return false
            }

            let base = sessions.first(where: { $0.sessionId == sessionID }) ?? session
            let updated = mergedMetadataSession(base, authoritative: authoritative)
            if searchOnly {
                if updated.archived == true {
                    remoteResolvedRows.removeValue(forKey: sessionID)
                    orderedRemoteIDs.removeAll { $0 == sessionID }
                    remoteContentSearchSessionIDs.removeAll { $0 == sessionID }
                } else {
                    remoteResolvedRows[sessionID] = updated
                }
            } else {
                let pendingKey = PendingMetadataKey(profile: activeProfile, sessionID: sessionID)
                var pending = pendingMetadataMutations[pendingKey]
                    ?? PendingMetadataMutation(title: nil, pinned: nil, archived: nil)
                metadataConfirmationRevision &+= 1
                let revision = metadataConfirmationRevision
                switch field {
                case let .title(title): pending.title = PendingMetadataValue(value: title, revision: revision)
                case let .pinned(pinned): pending.pinned = PendingMetadataValue(value: pinned, revision: revision)
                case let .archived(archived): pending.archived = PendingMetadataValue(value: archived, revision: revision)
                }
                pendingMetadataMutations[pendingKey] = pending
            }
            if updated.archived == true {
                if !searchOnly {
                    applySessions(
                        sessions.filter { $0.sessionId != sessionID },
                        archivedCount: archivedCount,
                        animation: animation
                    )
                }
            } else if let index = sessions.firstIndex(where: { $0.sessionId == sessionID }) {
                var updatedSessions = sessions
                updatedSessions[index] = updated
                applySessions(updatedSessions, archivedCount: archivedCount, animation: animation)
            }

            if let modelContext, !searchOnly {
                do {
                    try CacheStore.cacheSession(updated, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }
            return true
        } catch {
            guard !isCancellationError(error) else { return false }
            guard isCurrentMetadataScope(
                server: capturedServer,
                profile: activeProfile,
                epoch: profileEpoch
            ) else { return false }
            if searchOnly,
               !isCurrentRemoteSearchScope(
                   query: capturedSearchQuery,
                   profile: capturedSearchProfile,
                   generation: capturedSearchGeneration
               ) {
                return false
            }
            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    private func isCurrentMetadataScope(
        server capturedServer: URL,
        profile: String,
        epoch: Int
    ) -> Bool {
        !Task.isCancelled
            && server == capturedServer
            && (Self.nonEmpty(activeProfileName) ?? "default") == profile
            && activeProfileEpoch == epoch
    }

    private func isCurrentRemoteSearchScope(
        query: String?,
        profile: String?,
        generation: Int
    ) -> Bool {
        remoteSearchGeneration == generation
            && activeRemoteSearchQuery == query
            && activeRemoteSearchProfile == profile
            && profile == (Self.nonEmpty(activeProfileName) ?? "default")
    }

    func applyingPendingMetadata(
        _ session: SessionSummary,
        pending: PendingMetadataMutation,
        newerThan revision: Int
    ) -> SessionSummary {
        session.replacingListMetadata(
            title: pending.title.flatMap { $0.revision > revision ? $0.value : nil } ?? session.title,
            pinned: pending.pinned.flatMap { $0.revision > revision ? $0.value : nil } ?? session.pinned,
            archived: pending.archived.flatMap { $0.revision > revision ? $0.value : nil } ?? session.archived
        )
    }

    private func mergedMetadataSession(
        _ local: SessionSummary,
        authoritative: SessionSummary
    ) -> SessionSummary {
        SessionSummary(
            sessionId: local.sessionId ?? authoritative.sessionId,
            title: authoritative.title ?? local.title,
            workspace: authoritative.workspace ?? local.workspace,
            model: authoritative.model ?? local.model,
            modelProvider: authoritative.modelProvider ?? local.modelProvider,
            reasoningEffort: authoritative.reasoningEffort ?? local.reasoningEffort,
            messageCount: authoritative.messageCount ?? local.messageCount,
            createdAt: authoritative.createdAt ?? local.createdAt,
            updatedAt: authoritative.updatedAt ?? local.updatedAt,
            lastMessageAt: authoritative.lastMessageAt ?? local.lastMessageAt,
            pinned: authoritative.pinned ?? local.pinned,
            archived: authoritative.archived ?? local.archived,
            projectId: local.projectId,
            profile: authoritative.profile ?? local.profile,
            inputTokens: authoritative.inputTokens ?? local.inputTokens,
            outputTokens: authoritative.outputTokens ?? local.outputTokens,
            estimatedCost: authoritative.estimatedCost ?? local.estimatedCost,
            activeStreamId: local.activeStreamId,
            isStreaming: local.isStreaming,
            isCliSession: authoritative.isCliSession ?? local.isCliSession,
            userMessageCount: local.userMessageCount,
            hasPendingUserMessage: local.hasPendingUserMessage,
            pendingStartedAt: local.pendingStartedAt,
            worktreePath: local.worktreePath,
            sourceTag: authoritative.sourceTag ?? local.sourceTag,
            rawSource: authoritative.rawSource ?? local.rawSource,
            sessionSource: authoritative.sessionSource ?? local.sessionSource,
            sourceLabel: authoritative.sourceLabel ?? local.sourceLabel,
            parentSessionId: authoritative.parentSessionId ?? local.parentSessionId,
            relationshipType: local.relationshipType,
            readOnly: authoritative.readOnly ?? local.readOnly,
            isReadOnly: authoritative.isReadOnly ?? local.isReadOnly,
            matchType: local.matchType
        )
    }
}
