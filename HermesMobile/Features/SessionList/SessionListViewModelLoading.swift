import Foundation
import Observation
import SwiftData
import SwiftUI

extension SessionListViewModel {
    /// Publishes the saved sidebar before any network await so cold-launch
    /// navigation can restore the last selected chat immediately.
    func prepareInitialCachedSessions(modelContext: ModelContext) {
        refreshCachedSessionPreviews(modelContext: modelContext)
        _ = renderCachedSessionsBeforeReload(modelContext: modelContext)
    }

    @discardableResult
    func load(modelContext: ModelContext? = nil, animation: Animation? = nil) async -> Bool {
        loadGeneration &+= 1
        let generation = loadGeneration
        let requestedProfile = Self.nonEmpty(activeProfileName) ?? "default"
        let requestedProfileEpoch = activeProfileEpoch
        archivedCountRequestGeneration &+= 1
        let countRequestGeneration = archivedCountRequestGeneration
        let requestRevision = metadataConfirmationRevision
        isLoading = true
        errorMessage = nil
        cacheErrorMessage = nil
        sessionLoadError = nil
        lastError = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
                if isSidebarDirty { sidebarRefreshStateChanged() }
            }
        }

        refreshCachedSessionPreviews(modelContext: modelContext)
        _ = renderCachedSessionsBeforeReload(modelContext: modelContext)

        do {
            let response = try await client.directSessions(
                profile: requestedProfile,
                limit: 500,
                offset: 0,
                order: .recent
            )
            guard !Task.isCancelled,
                  loadGeneration == generation,
                  activeProfileEpoch == requestedProfileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == requestedProfile
            else { return false }
            let rawSessions = response.sessions
            let assignments: [String: String]
            do {
                let organizer = try organizerStore.snapshot(server: server, profile: requestedProfile)
                projects = organizer.groups
                assignments = organizer.sessionAssignments
            } catch {
                // Local organizer corruption cannot block the canonical Hermes
                // session list. Preserve the currently rendered local grouping
                // and surface that organizer writes are unavailable.
                assignments = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
                    guard (Self.nonEmpty(session.profile) ?? requestedProfile) == requestedProfile,
                          let id = Self.nonEmpty(session.sessionId),
                          let group = Self.nonEmpty(session.projectId) else { return nil }
                    return (id, group)
                })
                actionErrorMessage = error.localizedDescription
            }
            let canonicalVisibleSessions = rawSessions
                .map { applyingLocalGroup($0, assignments: assignments, profile: requestedProfile) }
                .map { session -> SessionSummary in
                    guard let sessionID = Self.nonEmpty(session.sessionId),
                          let pending = pendingMetadataMutations[
                              PendingMetadataKey(profile: requestedProfile, sessionID: sessionID)
                          ]
                    else { return session }
                    return applyingPendingMetadata(
                        session,
                        pending: pending,
                        newerThan: requestRevision
                    )
                }
                .filter { $0.archived != true && $0.shouldAppearInSessionList }
            for sessionID in pendingSessionDeletions.keys {
                pendingSessionDeletions[sessionID]?.latestCanonicalSessions = canonicalVisibleSessions
                pendingSessionDeletions[sessionID]?.latestCanonicalArchivedCount = archivedCount
            }
            let visibleSessions = sessionsAfterOptimisticDeletions(canonicalVisibleSessions)
            successfulLoadGeneration = generation
            applySessions(visibleSessions, archivedCount: archivedCount, animation: animation)
            for (key, var pending) in Array(pendingMetadataMutations)
                where key.profile == requestedProfile {
                if pending.title?.revision ?? .min <= requestRevision { pending.title = nil }
                if pending.pinned?.revision ?? .min <= requestRevision { pending.pinned = nil }
                if pending.archived?.revision ?? .min <= requestRevision { pending.archived = nil }
                if pending.title == nil, pending.pinned == nil, pending.archived == nil {
                    pendingMetadataMutations.removeValue(forKey: key)
                } else {
                    pendingMetadataMutations[key] = pending
                }
            }
            isViewingCachedData = false
            clearCacheFirstSessionPlaceholder()

            if let modelContext {
                do {
                    try CacheStore.cacheSessions(visibleSessions, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            // The profile-aggregate list is the canonical visible-row load, but
            // its total is not an archive count. Fetch the archive-only total
            // independently so a count failure cannot discard rows that have
            // already been applied above.
            await refreshArchivedCount(
                profile: requestedProfile,
                generation: generation,
                profileEpoch: requestedProfileEpoch,
                requestGeneration: countRequestGeneration
            )

            return true
        } catch {
            guard loadGeneration == generation,
                  activeProfileEpoch == requestedProfileEpoch,
                  (Self.nonEmpty(activeProfileName) ?? "default") == requestedProfile
            else { return false }
            guard !isCancellationError(error) else { return false }

            lastError = error
            sessionLoadError = error
            if CacheFallbackPolicy.shouldUseCache(for: error), let modelContext {
                do {
                    let profile = Self.nonEmpty(activeProfileName) ?? "default"
                    let assignments = localAssignments(for: profile)
                    let cachedSessions = sessionsAfterOptimisticDeletions(
                        try CacheStore.cachedSessions(serverURL: server, in: modelContext)
                            .map { applyingLocalGroup($0, assignments: assignments, profile: profile) }
                            .filter(\.shouldAppearInSessionList)
                    )
                    if !cachedSessions.isEmpty {
                        sessions = cachedSessions
                        isViewingCachedData = true
                        errorMessage = nil
                        clearCacheFirstSessionPlaceholder()
                    } else {
                        revertCacheFirstSessionPlaceholderIfNeeded()
                        isViewingCachedData = false
                        errorMessage = error.localizedDescription
                    }
                } catch {
                    revertCacheFirstSessionPlaceholderIfNeeded()
                    cacheErrorMessage = error.localizedDescription
                    isViewingCachedData = false
                    errorMessage = lastError?.localizedDescription
                }
            } else {
                revertCacheFirstSessionPlaceholderIfNeeded()
                isViewingCachedData = false
                errorMessage = error.localizedDescription
            }

            return false
        }
    }

    private func refreshCachedSessionPreviews(modelContext: ModelContext?) {
        guard let modelContext else {
            cachedSessionPreviews = [:]
            return
        }

        do {
            cachedSessionPreviews = try CacheStore.cachedSessionPreviews(
                serverURL: server,
                in: modelContext
            )
        } catch {
            cachedSessionPreviews = [:]
            cacheErrorMessage = error.localizedDescription
        }
    }

    private func refreshArchivedCount(
        profile requestedProfile: String,
        generation: Int,
        profileEpoch: Int,
        requestGeneration: Int
    ) async {
        guard !Task.isCancelled,
              loadGeneration == generation,
              activeProfileEpoch == profileEpoch,
              archivedCountRequestGeneration == requestGeneration,
              (Self.nonEmpty(activeProfileName) ?? "default") == requestedProfile
        else { return }

        do {
            let response = try await client.directSingleProfileSessions(
                profile: requestedProfile,
                limit: 0,
                offset: 0,
                order: .recent,
                archived: .only
            )

            guard !Task.isCancelled,
                  loadGeneration == generation,
                  activeProfileEpoch == profileEpoch,
                  archivedCountRequestGeneration == requestGeneration,
                  (Self.nonEmpty(activeProfileName) ?? "default") == requestedProfile
            else { return }

            guard let total = response.total, total >= 0 else {
                throw ArchivedCountResponseError()
            }

            archivedCount = total
            lastError = nil
            errorMessage = nil
            for sessionID in pendingSessionDeletions.keys {
                pendingSessionDeletions[sessionID]?.latestCanonicalArchivedCount = total
            }
        } catch {
            guard !Task.isCancelled,
                  loadGeneration == generation,
                  activeProfileEpoch == profileEpoch,
                  archivedCountRequestGeneration == requestGeneration,
                  (Self.nonEmpty(activeProfileName) ?? "default") == requestedProfile,
                  !isCancellationError(error)
            else { return }

            // Keep the successful visible-row load successful. This message is
            // deliberately nonblocking: it is only shown by the existing list
            // error surface when no rows are available, and never triggers the
            // cache fallback/retry path for a count-only failure.
            lastError = error
            errorMessage = CacheFallbackPolicy.sendBannerMessage(for: error)
        }
    }

    /// Refreshes only the archive total after an archive mutation. The
    /// operation is scoped to the currently selected profile and cannot
    /// publish after a newer load, profile switch, or cancellation.
    func refreshArchivedCountForProfile(_ profile: String) async {
        let requestedProfile = Self.nonEmpty(profile) ?? "default"
        guard !isViewingCachedData,
              requestedProfile == (Self.nonEmpty(activeProfileName) ?? "default")
        else { return }

        archivedCountRequestGeneration &+= 1
        let requestGeneration = archivedCountRequestGeneration
        let generation = loadGeneration
        let profileEpoch = activeProfileEpoch
        await refreshArchivedCount(
            profile: requestedProfile,
            generation: generation,
            profileEpoch: profileEpoch,
            requestGeneration: requestGeneration
        )
    }

    /// Paints the last known sidebar immediately on a cold launch while the live
    /// `/api/sessions` reconcile is in flight. This is an optimistic placeholder,
    /// not offline mode: `isViewingCachedData` stays false unless the request fails.
    private func renderCachedSessionsBeforeReload(modelContext: ModelContext?) -> Bool {
        guard sessions.isEmpty, let modelContext else { return false }

        do {
            let profile = Self.nonEmpty(activeProfileName) ?? "default"
            let assignments: [String: String]
            do {
                assignments = try organizerStore.snapshot(server: server, profile: profile).sessionAssignments
            } catch {
                assignments = [:]
                actionErrorMessage = error.localizedDescription
            }
            let cachedSessions = sessionsAfterOptimisticDeletions(
                try CacheStore.cachedSessions(serverURL: server, in: modelContext)
                    .map { applyingLocalGroup($0, assignments: assignments, profile: profile) }
                    .filter(\.shouldAppearInSessionList)
            )
            guard !cachedSessions.isEmpty else { return false }
            sessionsBeforeCacheFirstPlaceholder = sessions
            let placeholder = Self.sortedSessions(cachedSessions)
            sessions = placeholder
            cacheFirstSessionPlaceholder = placeholder
            return true
        } catch {
            // Cache corruption or migration failure must never delay the live request.
            cacheErrorMessage = error.localizedDescription
            return false
        }
    }

    private func revertCacheFirstSessionPlaceholderIfNeeded() {
        defer { clearCacheFirstSessionPlaceholder() }
        guard let cacheFirstSessionPlaceholder,
              sessions == cacheFirstSessionPlaceholder
        else { return }

        sessions = sessionsBeforeCacheFirstPlaceholder
    }

    private func clearCacheFirstSessionPlaceholder() {
        cacheFirstSessionPlaceholder = nil
        sessionsBeforeCacheFirstPlaceholder = []
    }

    func loadSessionForDeepLink(id rawSessionID: String, modelContext: ModelContext? = nil) async -> SessionSummary? {
        let sessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return nil }
        guard !confirmedSessionDeletionIDs.contains(sessionID),
              pendingSessionDeletions[sessionID] == nil
        else { return nil }

        let requestedProfile = Self.nonEmpty(activeProfileName) ?? "default"
        let generation = loadGeneration
        let requestedServer = server
        let isCurrentRequest: () -> Bool = { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled
                && self.loadGeneration == generation
                && self.server == requestedServer
                && (Self.nonEmpty(self.activeProfileName) ?? "default") == requestedProfile
        }

        if let loadedSession = sessions.first(where: {
            $0.sessionId == sessionID
                && (Self.nonEmpty($0.profile) ?? "default") == requestedProfile
        }) {
            return loadedSession
        }

        actionErrorMessage = nil
        lastError = nil

        if let modelContext {
            do {
                if let cachedSession = try CacheStore.cachedSessions(serverURL: server, in: modelContext)
                    .first(where: {
                        $0.sessionId == sessionID
                            && (Self.nonEmpty($0.profile) ?? "default") == requestedProfile
                    }) {
                    return cachedSession
                }
            } catch {
                cacheErrorMessage = error.localizedDescription
            }
        }

        do {
            let session = try await client.directSessionDetail(
                sessionID: sessionID,
                profile: requestedProfile
            )
            guard isCurrentRequest(),
                  session.sessionId == sessionID,
                  (Self.nonEmpty(session.profile) ?? requestedProfile) == requestedProfile,
                  !confirmedSessionDeletionIDs.contains(sessionID),
                  pendingSessionDeletions[sessionID] == nil
            else { return nil }

            if session.archived != true,
               session.shouldAppearInSessionList,
               !sessions.contains(where: { $0.sessionId == session.sessionId }) {
                sessions.insert(session, at: 0)
            }

            if let modelContext, session.shouldAppearInSessionList {
                do {
                    try CacheStore.cacheSession(session, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            return session
        } catch {
            guard isCurrentRequest() else { return nil }
            guard !isCancellationError(error) else { return nil }
            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }
}
