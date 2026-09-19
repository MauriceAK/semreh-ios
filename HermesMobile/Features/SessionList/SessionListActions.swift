import SwiftUI
import UIKit
import Combine

struct SessionListRowActions {
    let retryLoad: () -> Void
    let open: (SessionSummary) -> Void
    let togglePinned: (SessionSummary) -> Void
    let archive: (SessionSummary) -> Void
    let delete: (SessionSummary) -> Void
    let rename: (SessionSummary) -> Void
    let duplicate: (SessionSummary) -> Void
    let move: (SessionSummary, String?) -> Void
    let createProject: (SessionSummary) -> Void
    let refreshProjects: () -> Void
    let export: (SessionSummary, SessionExportFormat) -> Void
    var projectsEnabled: Bool = true
}

enum SessionRowActionPolicy {
    /// Capabilities that depend on where a row came from rather than on the
    /// server's metadata. Search-only rows are authoritative enough for the
    /// verified metadata endpoints, but are not part of the canonical sidebar
    /// collection until the collection mutation contracts are migrated.
    struct Capabilities: Equatable {
        var isSearchOnlySession = false
        var isViewingCachedData = false

        static let canonical = Self()

        func includingCachedData(_ isCached: Bool) -> Self {
            var effective = self
            effective.isViewingCachedData = effective.isViewingCachedData || isCached
            return effective
        }
    }

    static func offersMutationActions(for session: SessionSummary) -> Bool {
        !session.isSessionReadOnly
    }

    static func offersMetadataActions(
        for session: SessionSummary,
        capabilities: Capabilities = .canonical
    ) -> Bool {
        !session.isSessionReadOnly
            && !capabilities.isViewingCachedData
            && hasServerSessionID(session)
    }

    static func offersCollectionActions(
        for session: SessionSummary,
        capabilities: Capabilities = .canonical
    ) -> Bool {
        offersMetadataActions(for: session, capabilities: capabilities)
            && !capabilities.isSearchOnlySession
    }

    static func canExport(_ session: SessionSummary, isViewingCachedData: Bool) -> Bool {
        !isViewingCachedData && hasServerSessionID(session)
    }

    static func canExport(
        _ session: SessionSummary,
        capabilities: Capabilities
    ) -> Bool {
        !capabilities.isViewingCachedData
            && !capabilities.isSearchOnlySession
            && hasServerSessionID(session)
    }

    static func deepLinkURL(
        for session: SessionSummary,
        isViewingCachedData: Bool,
        isMutating: Bool
    ) -> URL? {
        guard !isMutating,
              canExport(session, isViewingCachedData: isViewingCachedData),
              let sessionID = session.sessionId
        else {
            return nil
        }

        return HermesDeepLink.sessionURL(sessionID: sessionID)
    }
}

enum SessionListMotion {
    static func disclosureAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.28, extraBounce: 0)
    }

    static func searchChromeAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.24, extraBounce: 0)
    }

    static func searchFocusAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    static func pressAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.18, extraBounce: 0)
    }

    static func sessionMutationAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0)
    }

    static func sessionRowTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    static func disclosureContentTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}


func hasServerSessionID(_ session: SessionSummary) -> Bool {
    guard let sessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return false
    }

    return !sessionID.isEmpty
}
