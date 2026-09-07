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
}
