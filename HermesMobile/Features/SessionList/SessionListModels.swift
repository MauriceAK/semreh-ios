import Foundation
import Observation
import SwiftData
import SwiftUI

struct SessionListSection: Identifiable {
    enum Kind: String {
        case pinned
        case today
        case yesterday
        case earlier
    }

    let kind: Kind
    let title: String
    let sessions: [SessionSummary]

    var id: String { kind.rawValue }
}

struct ScheduledSessionGroups: Equatable {
    let ordinary: [SessionSummary]
    let scheduled: [SessionSummary]
    let totalScheduledCount: Int

    static func partition(
        _ candidates: [SessionSummary],
        totalScheduledCount: Int
    ) -> Self {
        Self(
            ordinary: candidates.filter { !$0.isCronSession },
            scheduled: candidates.filter { $0.isCronSession && $0.archived != true },
            totalScheduledCount: totalScheduledCount
        )
    }

    var scheduledPreview: [SessionSummary] {
        Array(scheduled.prefix(5))
    }

    var hasAdditionalScheduledSessions: Bool {
        scheduled.count > scheduledPreview.count
    }

    func showsDisclosure(isSearchActive: Bool) -> Bool {
        totalScheduledCount > 0 && (!isSearchActive || !scheduled.isEmpty)
    }
}

enum ActiveSessionStateRefreshResult: Equatable {
    case unchanged
    case reloaded
    case failed
}

struct PendingSessionDeletion {
    let sessionsBeforeDeletion: [SessionSummary]
    let archivedCountBeforeDeletion: Int?
    let successfulLoadGenerationAtStart: Int
    var latestCanonicalSessions: [SessionSummary]?
    var latestCanonicalArchivedCount: Int?
}

enum PendingMetadataField {
    case title(String)
    case pinned(Bool)
    case archived(Bool)
}

struct PendingMetadataMutation {
    var title: PendingMetadataValue<String>?
    var pinned: PendingMetadataValue<Bool>?
    var archived: PendingMetadataValue<Bool>?
}

struct PendingMetadataValue<Value> {
    let value: Value
    let revision: Int
}

struct PendingMetadataKey: Hashable {
    let profile: String
    let sessionID: String
}

struct ArchivedCountResponseError: LocalizedError {
    var errorDescription: String? {
        String(localized: "Hermes did not return a valid archived session count.")
    }
}
