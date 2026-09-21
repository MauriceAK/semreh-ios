import Foundation
import Observation
import SwiftData
import SwiftUI

extension SessionListViewModel {
    static func normalizedSearchQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func applyingLocalGroup(
        _ session: SessionSummary,
        assignments: [String: String],
        profile: String
    ) -> SessionSummary {
        guard (Self.nonEmpty(session.profile) ?? profile) == profile else {
            return session.withLocalOrganizerGroupID(nil)
        }
        guard let sessionID = Self.nonEmpty(session.sessionId) else {
            return session.withLocalOrganizerGroupID(nil)
        }
        return session.withLocalOrganizerGroupID(assignments[sessionID])
    }

    func localAssignments(for profile: String) -> [String: String] {
        do {
            return try organizerStore.snapshot(server: server, profile: profile).sessionAssignments
        } catch {
            actionErrorMessage = error.localizedDescription
            return [:]
        }
    }

    func applyingLocalGroup(_ session: SessionSummary, groupID: String?) -> SessionSummary {
        session.withLocalOrganizerGroupID(groupID)
    }

    static func sortedSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.sorted { left, right in
            if (left.pinned == true) != (right.pinned == true) {
                return left.pinned == true
            }

            return timestamp(for: left) > timestamp(for: right)
        }
    }

    static func timestamp(for session: SessionSummary) -> Double {
        session.lastMessageAt ?? session.updatedAt ?? session.createdAt ?? 0
    }

    static func searchableText(for session: SessionSummary) -> String {
        [
            session.title,
            session.workspace,
            session.model,
            session.modelProvider,
            session.profile,
            session.sourceLabel
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    }

    func sessionsAfterOptimisticDeletions(_ candidates: [SessionSummary]) -> [SessionSummary] {
        let hiddenSessionIDs = Set(pendingSessionDeletions.keys).union(confirmedSessionDeletionIDs)
        guard !hiddenSessionIDs.isEmpty else { return candidates }
        return candidates.filter { session in
            guard let sessionID = Self.nonEmpty(session.sessionId) else { return true }
            return !hiddenSessionIDs.contains(sessionID)
        }
    }

    /// `archivedCount` is applied inside the same transaction as the rows so the
    /// bottom Archived entry inserts/removes with the list mutation animation.
    func applySessions(
        _ newSessions: [SessionSummary],
        archivedCount newArchivedCount: Int?,
        animation: Animation?
    ) {
        guard let animation else {
            sessions = newSessions
            archivedCount = newArchivedCount
            return
        }

        withAnimation(animation) {
            sessions = newSessions
            archivedCount = newArchivedCount
        }
    }

    func timestamp(for session: SessionSummary) -> Double {
        Self.timestamp(for: session)
    }

    func date(for session: SessionSummary) -> Date? {
        let value = timestamp(for: session)
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    func duplicateTitle(for session: SessionSummary) -> String {
        let baseTitle = Self.nonEmpty(session.title) ?? String(localized: "Untitled Session")
        return String(localized: "\(baseTitle) (copy)")
    }

    func isCancellationError(_ error: Error) -> Bool {
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
