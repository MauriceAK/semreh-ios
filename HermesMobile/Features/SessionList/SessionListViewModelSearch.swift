import Foundation
import Observation
import SwiftData
import SwiftUI

extension SessionListViewModel {
    var sections: [SessionListSection] {
        let sortedSessions = sessions.sorted { left, right in
            timestamp(for: left) > timestamp(for: right)
        }
        let pinned = sortedSessions.filter { $0.pinned == true }
        let unpinned = sortedSessions.filter { $0.pinned != true }

        let calendar = Calendar.current
        let today = unpinned.filter { session in
            guard let date = date(for: session) else { return false }
            return calendar.isDateInToday(date)
        }
        let yesterday = unpinned.filter { session in
            guard let date = date(for: session) else { return false }
            return calendar.isDateInYesterday(date)
        }
        let earlier = unpinned.filter { session in
            guard let date = date(for: session) else { return true }
            return !calendar.isDateInToday(date) && !calendar.isDateInYesterday(date)
        }

        return [
            SessionListSection(kind: .pinned, title: String(localized: "Pinned"), sessions: pinned),
            SessionListSection(kind: .today, title: String(localized: "Today"), sessions: today),
            SessionListSection(kind: .yesterday, title: String(localized: "Yesterday"), sessions: yesterday),
            SessionListSection(kind: .earlier, title: String(localized: "Earlier"), sessions: earlier)
        ]
        .filter { !$0.sessions.isEmpty }
    }

    func visibleSessions(
        searchText rawSearchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility = .showAll
    ) -> [SessionSummary] {
        let query = Self.normalizedSearchQuery(rawSearchText)
        let baseSessions = sessions.filter { automatedVisibility.shows($0) }
        let projectFilteredSessions = baseSessions.filter { session in
            guard let selectedProjectID else { return true }
            return session.projectId == selectedProjectID
        }
        let localMatches = projectFilteredSessions.filter { session in
            guard !query.isEmpty else { return true }
            return Self.searchableText(for: session).contains(query)
        }
        let sortedLocalMatches = Self.sortedSessions(localMatches)

        guard !query.isEmpty, activeRemoteSearchQuery == query else {
            return sortedLocalMatches
        }

        let localMatchIDs = Set(sortedLocalMatches.compactMap(\.sessionId))
        let sessionsByID = Dictionary(
            projectFilteredSessions.compactMap { session -> (String, SessionSummary)? in
                guard let sessionID = session.sessionId, !sessionID.isEmpty else { return nil }
                return (sessionID, session)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteMatches = orderedRemoteIDs.compactMap { sessionID -> SessionSummary? in
            guard !localMatchIDs.contains(sessionID) else { return nil }
            let candidate = sessionsByID[sessionID] ?? remoteResolvedRows[sessionID]
            guard let candidate,
                  candidate.archived != true,
                  automatedVisibility.shows(candidate),
                  selectedProjectID == nil || candidate.projectId == selectedProjectID,
                  !confirmedSessionDeletionIDs.contains(sessionID),
                  pendingSessionDeletions[sessionID] == nil
            else { return nil }
            return candidate
        }

        // Keep the existing transcript/sidebar ordering contract for remote
        // content matches: the search route determines membership, while the
        // same recency sort used for local matches determines presentation.
        return sortedLocalMatches + Self.sortedSessions(remoteMatches)
    }

    /// True when a search result was resolved from Hermes but is not part of
    /// the canonical sidebar page. Such rows may be opened and have their
    /// metadata changed, but destructive/legacy-only actions stay unavailable.
    func isSearchOnlySession(_ session: SessionSummary) -> Bool {
        guard let sessionID = Self.nonEmpty(session.sessionId) else { return false }
        return remoteResolvedRows[sessionID] != nil
            && !sessions.contains { Self.nonEmpty($0.sessionId) == sessionID }
    }

    func scheduledSessionGroups(
        searchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility = .showAll
    ) -> ScheduledSessionGroups {
        let candidates = visibleSessions(
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedVisibility
        )

        return ScheduledSessionGroups.partition(
            candidates,
            totalScheduledCount: automatedVisibility.showsCron
                ? sessions.filter { $0.isCronSession && $0.archived != true }.count
                : 0
        )
    }

    func searchSessions(
        query rawQuery: String,
        content: Bool = true,
        depth: Int = 5,
        debounceNanoseconds: UInt64 = 350_000_000
    ) async {
        let query = Self.normalizedSearchQuery(rawQuery)
        let profile = Self.nonEmpty(activeProfileName) ?? "default"
        remoteSearchGeneration &+= 1
        let generation = remoteSearchGeneration
        activeRemoteSearchQuery = query
        activeRemoteSearchProfile = profile
        remoteContentSearchSessionIDs = []
        orderedRemoteIDs = []
        remoteResolvedRows = [:]
        searchErrorMessage = nil
        defer {
            if remoteSearchGeneration == generation {
                isSearchingRemoteSessions = false
            }
        }

        guard !query.isEmpty, !isViewingCachedData else {
            isSearchingRemoteSessions = false
            return
        }

        do {
            if debounceNanoseconds > 0 {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            }

            guard !Task.isCancelled,
                  remoteSearchGeneration == generation,
                  activeRemoteSearchQuery == query,
                  activeRemoteSearchProfile == profile,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile
            else { return }

            isSearchingRemoteSessions = true
            // The verified stock search route has no content/depth query
            // flags. `content` remains source-compatible for existing callers;
            // it controls which returned match kinds are admitted below.
            _ = depth
            let response = try await client.directSearchSessions(
                query: query,
                profile: profile,
                limit: 20
            )

            guard !Task.isCancelled,
                  remoteSearchGeneration == generation,
                  activeRemoteSearchQuery == query,
                  activeRemoteSearchProfile == profile,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile
            else { return }

            let candidateIDs = remoteSearchIDs(
                from: response.results ?? [],
                content: content
            )
            let assignments = localAssignments(for: profile)
            var resolvedRows: [String: SessionSummary] = [:]
            var acceptedIDs: [String] = []
            var fatalResolutionError: Error?
            let knownIDs = Set(sessions.compactMap { session -> String? in
                guard session.archived != true,
                      (Self.nonEmpty(session.profile) ?? "default") == profile,
                      let sessionID = Self.nonEmpty(session.sessionId)
                else { return nil }
                return sessionID
            })

            for sessionID in candidateIDs {
                guard !Task.isCancelled,
                      remoteSearchGeneration == generation,
                      activeRemoteSearchQuery == query,
                      activeRemoteSearchProfile == profile,
                      (Self.nonEmpty(activeProfileName) ?? "default") == profile
                else { return }
                guard !confirmedSessionDeletionIDs.contains(sessionID),
                      pendingSessionDeletions[sessionID] == nil
                else { continue }

                if knownIDs.contains(sessionID) {
                    acceptedIDs.append(sessionID)
                    continue
                }

                do {
                    let resolved = try await client.directSessionDetail(
                        sessionID: sessionID,
                        profile: profile
                    )
                    guard resolved.sessionId == sessionID,
                          (Self.nonEmpty(resolved.profile) ?? profile) == profile,
                          resolved.archived == false
                    else { continue }
                    resolvedRows[sessionID] = applyingLocalGroup(
                        resolved,
                        assignments: assignments,
                        profile: profile
                    )
                    acceptedIDs.append(sessionID)
                } catch {
                    if Self.isSearchResolutionAuthFailure(error) {
                        throw error
                    }
                    if !Self.isSearchResolutionMiss(error) {
                        fatalResolutionError = error
                        break
                    }
                }
            }

            guard !Task.isCancelled,
                  remoteSearchGeneration == generation,
                  activeRemoteSearchQuery == query,
                  activeRemoteSearchProfile == profile,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile
            else { return }

            orderedRemoteIDs = acceptedIDs
            remoteContentSearchSessionIDs = acceptedIDs
            remoteResolvedRows = resolvedRows
            isSearchingRemoteSessions = false
            if let fatalResolutionError {
                lastError = fatalResolutionError
                searchErrorMessage = fatalResolutionError.localizedDescription
            }
        } catch {
            guard remoteSearchGeneration == generation,
                  activeRemoteSearchQuery == query,
                  activeRemoteSearchProfile == profile,
                  (Self.nonEmpty(activeProfileName) ?? "default") == profile
            else { return }

            isSearchingRemoteSessions = false
            guard !isCancellationError(error) else { return }

            remoteContentSearchSessionIDs = []
            orderedRemoteIDs = []
            remoteResolvedRows = [:]
            searchErrorMessage = error.localizedDescription
            lastError = error
        }
    }

    func clearSearchResults() {
        remoteSearchGeneration &+= 1
        activeRemoteSearchQuery = nil
        activeRemoteSearchProfile = nil
        remoteContentSearchSessionIDs = []
        orderedRemoteIDs = []
        remoteResolvedRows = [:]
        searchErrorMessage = nil
        isSearchingRemoteSessions = false
    }

    private var loadFailureRefreshResult: ActiveSessionStateRefreshResult {
        lastError == nil ? .unchanged : .failed
    }

    @discardableResult
    func refreshActiveSessionStatesIfNeeded(
        modelContext: ModelContext? = nil
    ) async -> ActiveSessionStateRefreshResult {
        guard !Task.isCancelled, !isViewingCachedData, !isLoading,
              !sidebarRefreshBlocked else { return .unchanged }
        // Connected direct sessions use the existing coalesced invalidation path.
        // The slow monitor is only a fallback while gateway observation is unavailable.
        if gatewayObservationEnabled, gatewayObserverID != nil,
           let observedGatewayRuntime, observedGatewayRuntime.origin == server,
           observedGatewayRuntime.state == .ready { return .unchanged }
        return await load(modelContext: modelContext) ? .reloaded : loadFailureRefreshResult
    }

    private func remoteSearchIDs(
        from results: [DirectHermesSessionSearchResult],
        content: Bool
    ) -> [String] {
        var seenSessionIDs = Set<String>()

        return results.prefix(20).compactMap { result in
            // The stock route uses a null role for direct session-ID hits. A
            // content-disabled caller keeps those exact ID matches but drops
            // FTS message hits; no lineage fallback is safe here.
            guard content || result.role == nil,
                  result.archived != true,
                  let sessionID = Self.nonEmpty(result.sessionID),
                  !seenSessionIDs.contains(sessionID)
            else {
                return nil
            }

            seenSessionIDs.insert(sessionID)
            return sessionID
        }
    }

    private static func isSearchResolutionMiss(_ error: Error) -> Bool {
        if let error = error as? DirectHermesRESTError {
            switch error {
            case .invalidSessionID, .missingCanonicalSessionID, .sessionIDMismatch, .profileMismatch:
                return true
            }
        }
        if case DirectHermesRequestError.http(let statusCode, _) = error {
            return statusCode == 404
        }
        if case APIError.http(let statusCode, _) = error {
            return statusCode == 404
        }
        return false
    }

    private static func isSearchResolutionAuthFailure(_ error: Error) -> Bool {
        if error is DirectHermesAuthError {
            return true
        }
        if case APIError.unauthorized = error {
            return true
        }
        if case DirectHermesRequestError.http(let statusCode, _) = error {
            return statusCode == 401 || statusCode == 403
        }
        return false
    }
}
