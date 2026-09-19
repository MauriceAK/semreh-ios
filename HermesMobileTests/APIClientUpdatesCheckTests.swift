import XCTest
@testable import HermesMobile

final class APIClientUpdatesCheckTests: APIClientTestCase {
    func testPassiveCheckUsesStockGETQueryAndDecodesFlatPayload() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/hermes/update/check")
            XCTAssertEqual(request.url?.query, "force=false")
            return apiTestJSONResponse(#"{"install_method":"git","current_version":"0.21.0","behind":3,"update_available":true,"can_apply":true,"update_command":"hermes update","commits":[{"sha":"abc1234","summary":"Fix","author":"Dev","at":1770000000}]}"#, for: request)
        }
        let response = try await client.updatesCheck()
        XCTAssertEqual(response.currentVersion, "0.21.0")
        XCTAssertEqual(response.commits?.first?.sha, "abc1234")
        XCTAssertEqual(response.updateState, .updateAvailable(behind: 3))
    }

    func testForcedCheckUsesGETForceTrueWithoutBody() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/hermes/update/check")
            XCTAssertEqual(request.url?.query, "force=true")
            XCTAssertNil(apiTestBodyData(from: request))
            return apiTestJSONResponse(#"{"install_method":"git","behind":0,"update_available":false,"can_apply":true}"#, for: request)
        }
        let response = try await client.updatesCheckForced()
        XCTAssertEqual(response.forcedCheckOutcome, .upToDate)
    }

    func testUnknownBehindCanStillReportAvailable() throws {
        let response = try decode(#"{"behind":-1,"update_available":true,"can_apply":true}"#)
        XCTAssertEqual(response.forcedCheckOutcome, .updateAvailable(behind: nil))
    }

    func testManagedInstallIsDistinctFromCheckFailure() throws {
        let response = try decode(#"{"install_method":"docker","behind":null,"update_available":false,"can_apply":false,"message":"Update the container image."}"#)
        XCTAssertEqual(response.forcedCheckOutcome, .managed(message: "Update the container image."))
        XCTAssertEqual(response.updateState, .managed(message: "Update the container image."))
    }

    func testUnavailableWhenApplicableCheckHasNoResult() throws {
        XCTAssertEqual(try decode(#"{"can_apply":true,"behind":null}"#).updateState, .unavailable)
    }

    private func decode(_ json: String) throws -> UpdatesCheckResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UpdatesCheckResponse.self, from: Data(json.utf8))
    }
}
