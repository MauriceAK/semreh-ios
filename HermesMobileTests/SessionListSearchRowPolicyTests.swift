import XCTest
@testable import HermesMobile

final class SessionListSearchRowPolicyTests: XCTestCase {
    func testCanonicalRowRetainsMetadataCollectionAndExportCapabilities() {
        let session = SessionSummary(sessionId: "canonical")
        let capabilities = SessionRowActionPolicy.Capabilities.canonical

        XCTAssertTrue(SessionRowActionPolicy.offersMetadataActions(for: session, capabilities: capabilities))
        XCTAssertTrue(SessionRowActionPolicy.offersCollectionActions(for: session, capabilities: capabilities))
        XCTAssertTrue(SessionRowActionPolicy.canExport(session, capabilities: capabilities))
    }

    func testSearchOnlyRowRetainsMetadataAndLocalDeepLinkButNotCollectionActions() throws {
        let session = SessionSummary(sessionId: "search-only")
        let capabilities = SessionRowActionPolicy.Capabilities(isSearchOnlySession: true)

        XCTAssertTrue(SessionRowActionPolicy.offersMetadataActions(for: session, capabilities: capabilities))
        XCTAssertFalse(SessionRowActionPolicy.offersCollectionActions(for: session, capabilities: capabilities))
        XCTAssertFalse(SessionRowActionPolicy.canExport(session, capabilities: capabilities))

        let deepLink = try XCTUnwrap(
            SessionRowActionPolicy.deepLinkURL(
                for: session,
                isViewingCachedData: false,
                isMutating: false
            )
        )
        XCTAssertEqual(HermesDeepLink.sessionID(from: deepLink), "search-only")
    }

    func testReadOnlyRowSuppressesMetadataAndCollectionButRetainsCanonicalExport() {
        let session = SessionSummary(sessionId: "read-only", readOnly: true)
        let capabilities = SessionRowActionPolicy.Capabilities.canonical

        XCTAssertFalse(SessionRowActionPolicy.offersMetadataActions(for: session, capabilities: capabilities))
        XCTAssertFalse(SessionRowActionPolicy.offersCollectionActions(for: session, capabilities: capabilities))
        XCTAssertTrue(SessionRowActionPolicy.canExport(session, capabilities: capabilities))
    }

    func testCachedSearchOnlyRowSuppressesNetworkAndDeepLinkActions() {
        let session = SessionSummary(sessionId: "cached-search-only")
        let capabilities = SessionRowActionPolicy.Capabilities(
            isSearchOnlySession: true,
            isViewingCachedData: true
        )

        XCTAssertFalse(SessionRowActionPolicy.offersMetadataActions(for: session, capabilities: capabilities))
        XCTAssertFalse(SessionRowActionPolicy.offersCollectionActions(for: session, capabilities: capabilities))
        XCTAssertFalse(SessionRowActionPolicy.canExport(session, capabilities: capabilities))
        XCTAssertNil(
            SessionRowActionPolicy.deepLinkURL(
                for: session,
                isViewingCachedData: true,
                isMutating: false
            )
        )
    }

    func testLegacyOfflineFlagIsMergedWithCanonicalDefaultCapabilities() {
        let session = SessionSummary(sessionId: "offline-canonical")
        let effective = SessionRowActionPolicy.Capabilities.canonical.includingCachedData(true)

        XCTAssertFalse(SessionRowActionPolicy.offersMetadataActions(for: session, capabilities: effective))
        XCTAssertFalse(SessionRowActionPolicy.offersCollectionActions(for: session, capabilities: effective))
        XCTAssertFalse(SessionRowActionPolicy.canExport(session, capabilities: effective))
    }

    func testSessionFiltersIntersectBotPinScheduledHistoryAndProject() {
        let rows = [
            SessionSummary(
                sessionId: "scheduled-match",
                pinned: true,
                projectId: "client",
                profile: "research",
                sourceTag: "cron"
            ),
            SessionSummary(
                sessionId: "ordinary-same-project",
                pinned: true,
                projectId: "client",
                profile: "research"
            ),
            SessionSummary(
                sessionId: "scheduled-other-project",
                pinned: true,
                projectId: "personal",
                profile: "research",
                sourceTag: "cron"
            ),
            SessionSummary(
                sessionId: "scheduled-unpinned",
                pinned: false,
                projectId: "client",
                profile: "research",
                sourceTag: "cron"
            ),
            SessionSummary(
                sessionId: "scheduled-other-bot",
                pinned: true,
                projectId: "client",
                profile: "default",
                sourceTag: "cron"
            )
        ]

        let matches = rows.filter {
            SessionShellFilter.matches(
                $0,
                bot: "research",
                pinnedOnly: true,
                scheduledHistoryOnly: true,
                projectID: "client"
            )
        }

        XCTAssertEqual(matches.compactMap(\.sessionId), ["scheduled-match"])
    }

    func testClearingEverySessionFilterRestoresAllRows() {
        let rows = [
            SessionSummary(sessionId: "one", pinned: true, projectId: "client", profile: "research", sourceTag: "cron"),
            SessionSummary(sessionId: "two", pinned: false, projectId: "personal", profile: "default", sourceTag: "cron")
        ]

        let filtered = rows.filter {
            SessionShellFilter.matches(
                $0,
                bot: "research",
                pinnedOnly: true,
                scheduledHistoryOnly: true,
                projectID: "client"
            )
        }
        let cleared = rows.filter {
            SessionShellFilter.matches(
                $0,
                bot: nil,
                pinnedOnly: false,
                scheduledHistoryOnly: false,
                projectID: nil
            )
        }

        XCTAssertEqual(filtered.compactMap(\.sessionId), ["one"])
        XCTAssertEqual(cleared.compactMap(\.sessionId), ["one", "two"])
    }

    func testEmptyShellProjectsHideUntilASelectionNeedsClear() {
        XCTAssertFalse(AppShellOrganizerPolicy.showsProjects(isShell: true, hasProjects: false, hasSelection: false))
        XCTAssertTrue(AppShellOrganizerPolicy.showsProjects(isShell: true, hasProjects: false, hasSelection: true))
        XCTAssertTrue(AppShellOrganizerPolicy.showsProjects(isShell: false, hasProjects: false, hasSelection: false))
    }

    func testPinnedStripKeepsSameBotConversationsSeparateAndRemovesTheirDuplicates() {
        let first = SessionSummary(
            sessionId: "first",
            title: "First conversation",
            pinned: true,
            profile: "research"
        )
        let second = SessionSummary(
            sessionId: "second",
            title: "Second conversation",
            pinned: true,
            profile: "research"
        )
        let ordinary = SessionSummary(
            sessionId: "ordinary",
            title: "Ordinary conversation",
            pinned: false,
            profile: "research"
        )
        let staleDuplicate = SessionSummary(
            sessionId: "first",
            title: "First conversation",
            pinned: false,
            profile: "research"
        )

        let rows = [first, second, staleDuplicate, ordinary]
        let pinned = PinnedSessionStripPolicy.pinnedSessions(from: rows)
        let history = PinnedSessionStripPolicy.ordinarySessions(from: rows, excluding: pinned)

        XCTAssertEqual(pinned.compactMap(\.sessionId), ["first", "second"])
        XCTAssertEqual(history.compactMap(\.sessionId), ["ordinary"])
    }

    func testPinnedStripOnlyAppearsForAnUnfilteredShellSurface() {
        XCTAssertTrue(
            PinnedSessionStripPolicy.shouldShow(
                usesShellChrome: true,
                isSearchActive: false,
                hasActiveFilters: false,
                searchText: ""
            )
        )
        XCTAssertFalse(
            PinnedSessionStripPolicy.shouldShow(
                usesShellChrome: true,
                isSearchActive: true,
                hasActiveFilters: false,
                searchText: ""
            )
        )
        XCTAssertFalse(
            PinnedSessionStripPolicy.shouldShow(
                usesShellChrome: true,
                isSearchActive: false,
                hasActiveFilters: true,
                searchText: ""
            )
        )
        XCTAssertFalse(
            PinnedSessionStripPolicy.shouldShow(
                usesShellChrome: false,
                isSearchActive: false,
                hasActiveFilters: false,
                searchText: ""
            )
        )
    }

    func testAFilteredPinnedConversationRemainsInTheNormalRows() {
        let pinned = SessionSummary(
            sessionId: "research-pinned",
            title: "Research thread",
            pinned: true,
            profile: "research"
        )
        let rows = [pinned]

        let filteredRows = rows.filter {
            SessionShellFilter.matches(
                $0,
                bot: "research",
                pinnedOnly: false,
                scheduledHistoryOnly: false,
                projectID: nil
            )
        }

        XCTAssertFalse(
            PinnedSessionStripPolicy.shouldShow(
                usesShellChrome: true,
                isSearchActive: false,
                hasActiveFilters: true,
                searchText: ""
            )
        )
        XCTAssertEqual(
            PinnedSessionStripPolicy.ordinarySessions(from: filteredRows, excluding: []),
            rows
        )
    }

    func testPinnedAccessibilityUsesFullConversationTitleAndBot() {
        let session = SessionSummary(
            sessionId: "long-title",
            title: "A conversation title that is intentionally long",
            pinned: true,
            profile: "research"
        )

        XCTAssertEqual(
            PinnedSessionStripPolicy.accessibilityLabel(for: session),
            "A conversation title that is intentionally long, bot research"
        )
        XCTAssertEqual(
            PinnedSessionStripPolicy.shortTitle(for: session),
            "A conversation ti…"
        )
    }
}
