import XCTest
@testable import HermesMobile

final class CacheFallbackPolicyTests: XCTestCase {
    func testUsesCacheForConnectivityErrors() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .cannotFindHost,
            .dataNotAllowed,
            .timedOut
        ]

        for code in codes {
            XCTAssertTrue(
                CacheFallbackPolicy.shouldUseCache(for: APIError.network(underlying: URLError(code))),
                "\(code) should use cache fallback"
            )
        }
    }

    func testUsesCacheForTransientUnavailableHTTPStatuses() {
        for statusCode in [408, 502, 503, 504] {
            XCTAssertTrue(
                CacheFallbackPolicy.shouldUseCache(for: APIError.http(statusCode: statusCode, body: nil)),
                "HTTP \(statusCode) should use cache fallback"
            )
        }
    }

    func testDoesNotUseCacheForServerApplicationErrors() {
        let cases: [(name: String, error: Error)] = [
            ("invalid server URL", APIError.invalidServerURL),
            ("unauthorized", APIError.unauthorized),
            ("bad request", APIError.http(statusCode: 400, body: nil)),
            ("forbidden", APIError.http(statusCode: 403, body: nil)),
            ("not found", APIError.http(statusCode: 404, body: nil)),
            ("rate limited", APIError.http(statusCode: 429, body: nil)),
            ("server error", APIError.http(statusCode: 500, body: nil)),
            ("decoding", APIError.decoding(underlying: URLError(.badServerResponse))),
            ("cancelled", APIError.network(underlying: URLError(.cancelled))),
            ("bad URL", APIError.network(underlying: URLError(.badURL))),
            ("certificate", APIError.network(underlying: URLError(.secureConnectionFailed))),
            ("plain cancellation", CancellationError())
        ]

        for testCase in cases {
            XCTAssertFalse(
                CacheFallbackPolicy.shouldUseCache(for: testCase.error),
                "\(testCase.name) should not use cache fallback"
            )
        }
    }

    func testRawURLErrorUsesSameConnectivityRules() {
        XCTAssertTrue(CacheFallbackPolicy.shouldUseCache(for: URLError(.timedOut)))
        XCTAssertFalse(CacheFallbackPolicy.shouldUseCache(for: URLError(.badURL)))
    }

    func testTransientBlipsAreNotAnnouncedAsServerOutages() {
        let blips: [Error] = [
            APIError.network(underlying: URLError(.networkConnectionLost)),
            APIError.network(underlying: URLError(.cannotConnectToHost)),
            APIError.network(underlying: URLError(.timedOut)),
            URLError(.networkConnectionLost),
            APIError.http(statusCode: 408, body: nil),
            APIError.http(statusCode: 429, body: nil),
            APIError.http(statusCode: 500, body: nil)
        ]

        for error in blips {
            XCTAssertTrue(CacheFallbackPolicy.isTransientBlip(error), "\(error) should be a transient blip")
            XCTAssertFalse(
                CacheFallbackPolicy.shouldAnnounceAsServerOutage(error),
                "\(error) should not claim the server is down"
            )
        }
    }

    func testConfirmedOutagesStillUseTheSetupBanner() {
        let outages: [Error] = [
            APIError.network(underlying: URLError(.cannotFindHost)),
            APIError.network(underlying: URLError(.dnsLookupFailed)),
            APIError.http(statusCode: 502, body: nil),
            APIError.http(statusCode: 503, body: nil),
            APIError.http(statusCode: 504, body: nil)
        ]

        for error in outages {
            XCTAssertTrue(
                CacheFallbackPolicy.shouldAnnounceAsServerOutage(error),
                "\(error) should still be treated as a real outage"
            )
        }
    }

    func testComposerKeepsQuietOnTransientBlips() {
        let error = APIError.network(underlying: URLError(.networkConnectionLost))
        XCTAssertNil(CacheFallbackPolicy.composerBannerMessage(for: error))
    }

    func testSendUsesQuietRetryCopyForTransientBlips() {
        let error = APIError.network(underlying: URLError(.cannotConnectToHost))
        XCTAssertEqual(
            CacheFallbackPolicy.sendBannerMessage(for: error),
            "Couldn't reach the server. Try again."
        )
        XCTAssertNotEqual(
            CacheFallbackPolicy.sendBannerMessage(for: error),
            "Could not connect to the server. Check that Hermes is running and the tunnel is connected."
        )
    }
}
