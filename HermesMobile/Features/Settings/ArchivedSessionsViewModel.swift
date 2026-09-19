import Foundation
import Observation

private enum ArchivedSessionsViewModelError: LocalizedError {
    case paginationIncomplete
    case readbackMismatch

    var errorDescription: String? {
        switch self {
        case .paginationIncomplete:
            return String(localized: "Hermes did not return the complete archived-session collection.")
        case .readbackMismatch:
            return String(localized: "Hermes did not confirm that the session was unarchived.")
        }
    }
}

@MainActor
@Observable
final class ArchivedSessionsViewModel {
    private static let pageSize = 100

    private(set) var sessions: [SessionSummary] = []
    private(set) var isLoading = false
    private(set) var unarchivingSessionIDs: Set<String> = []
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    /// Last raw failure, exposed so the view can forward it to the shared
    /// API-error handler (401 → re-login), mirroring `SessionListViewModel`.
    private(set) var lastError: Error?

    private let client: APIClient
    private let profile: String
    private var loadGeneration = 0
    /// Successful unarchives remain hidden from reads that began before the
    /// confirmation. A fresh authoritative read is allowed to show the row if
    /// another client archived it again.
    private var locallyUnarchivedSessionRevisions: [String: Int] = [:]
    private var archiveMutationRevision = 0

    var isUnarchiving: Bool {
        !unarchivingSessionIDs.isEmpty
    }

    init(server: URL, profile: String = "default", client: APIClient? = nil) {
        self.client = client ?? APIClient(baseURL: server)
        let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profile = trimmedProfile.isEmpty ? "default" : trimmedProfile
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let loadRevision = archiveMutationRevision
        isLoading = true
        errorMessage = nil
        actionErrorMessage = nil
        lastError = nil

        do {
            var offset = 0
            var expectedTotal: Int?
            var loaded: [SessionSummary] = []
            var seenIDs: Set<String> = []

            while true {
                try Task.checkCancellation()
                let page = try await client.directSingleProfileSessions(
                    profile: profile,
                    limit: Self.pageSize,
                    offset: offset,
                    order: .recent,
                    archived: .only
                )
                guard generation == loadGeneration else { return }
                try Task.checkCancellation()

                if let total = page.total {
                    expectedTotal = max(expectedTotal ?? 0, total)
                }

                var pageAddedID = false
                for session in page.sessions where session.archived == true {
                    let identity = session.id
                    if seenIDs.insert(identity).inserted {
                        loaded.append(session)
                        pageAddedID = true
                    }
                }

                let returnedCount = page.sessions.count
                if returnedCount == 0 {
                    if let expectedTotal, loaded.count < expectedTotal {
                        throw ArchivedSessionsViewModelError.paginationIncomplete
                    }
                    break
                }

                if let expectedTotal, loaded.count >= expectedTotal {
                    break
                }

                let nextOffset = offset + Self.pageSize
                let hasMoreByTotal = expectedTotal.map { nextOffset < $0 } ?? false
                let hasMoreByPageSize = expectedTotal == nil && returnedCount >= Self.pageSize
                guard hasMoreByTotal || hasMoreByPageSize else { break }

                // Pinned rows may be back-filled past the requested window. A
                // repeated page means the stock endpoint cannot advance at its
                // bounded server limit; fail visibly instead of truncating.
                guard pageAddedID else {
                    throw ArchivedSessionsViewModelError.paginationIncomplete
                }
                offset = nextOffset
            }

            guard generation == loadGeneration else { return }
            let pending = unarchivingSessionIDs
            // A completed read that began after a local unarchive confirmation
            // is authoritative: it either confirms the row is absent or shows
            // a later re-archive from another client.
            let authoritativeTombstoneIDs = locallyUnarchivedSessionRevisions.compactMap { sessionID, revision in
                revision <= loadRevision ? sessionID : nil
            }
            for sessionID in authoritativeTombstoneIDs {
                locallyUnarchivedSessionRevisions.removeValue(forKey: sessionID)
            }
            let hiddenByOlderReads = Set(
                locallyUnarchivedSessionRevisions.compactMap { sessionID, revision in
                    revision > loadRevision ? sessionID : nil
                }
            )
            let hidden = pending.union(hiddenByOlderReads)
            sessions = loaded.filter { !hidden.contains($0.id) }
        } catch {
            // A cancelled load (pull-to-refresh superseding `.task`, or the view
            // disappearing) is not a failure — don't flash an error state.
            guard generation == loadGeneration else { return }
            if !Self.isCancellationError(error) {
                lastError = error
                errorMessage = error.localizedDescription
            }
        }

        if generation == loadGeneration {
            isLoading = false
        }
    }

    func unarchive(_ session: SessionSummary) async -> Bool {
        guard let rawSessionID = session.sessionId,
              let sessionId = Self.nonEmpty(rawSessionID),
              rawSessionID == sessionId else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }
        if let sessionProfile = Self.nonEmpty(session.profile), sessionProfile != profile {
            actionErrorMessage = String(localized: "This session belongs to a different profile.")
            return false
        }
        guard !unarchivingSessionIDs.contains(sessionId) else {
            return false
        }

        guard let removedSession = removeSession(withID: sessionId) else {
            return false
        }

        unarchivingSessionIDs.insert(sessionId)
        actionErrorMessage = nil
        lastError = nil
        defer {
            unarchivingSessionIDs.remove(sessionId)
        }

        do {
            try Task.checkCancellation()
            _ = try await client.directMutateSession(
                sessionID: sessionId,
                operation: .archived(false),
                profile: profile
            )
            try Task.checkCancellation()
            let confirmed = try await client.directSessionDetail(
                sessionID: sessionId,
                profile: profile
            )
            try Task.checkCancellation()
            guard confirmed.sessionId == sessionId,
                  confirmed.archived == false,
                  confirmed.profile == nil || confirmed.profile == profile else {
                throw ArchivedSessionsViewModelError.readbackMismatch
            }
            archiveMutationRevision &+= 1
            locallyUnarchivedSessionRevisions[sessionId] = archiveMutationRevision
            return true
        } catch {
            locallyUnarchivedSessionRevisions.removeValue(forKey: sessionId)
            restore(removedSession)
            if !Self.isCancellationError(error) {
                lastError = error
                actionErrorMessage = error.localizedDescription
            }
            return false
        }
    }

    func isUnarchiving(_ session: SessionSummary) -> Bool {
        guard let sessionId = session.sessionId else { return false }
        return unarchivingSessionIDs.contains(sessionId)
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    private func removeSession(withID sessionId: String) -> (index: Int, session: SessionSummary)? {
        guard let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) else {
            return nil
        }

        let removed = sessions.remove(at: index)
        return (index, removed)
    }

    private func restore(_ removedSession: (index: Int, session: SessionSummary)) {
        guard removedSession.session.sessionId != nil,
              !sessions.contains(where: { $0.sessionId == removedSession.session.sessionId })
        else {
            return
        }

        sessions.insert(removedSession.session, at: min(removedSession.index, sessions.count))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Mirrors `SessionListViewModel`'s cancellation check: a `CancellationError`
    /// or a (possibly `APIError.network`-wrapped) `URLError.cancelled`.
    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        guard let urlError = underlying as? URLError else { return false }
        return urlError.code == .cancelled
    }
}
