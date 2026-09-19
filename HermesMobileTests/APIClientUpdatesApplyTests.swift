import XCTest
@testable import HermesMobile

final class APIClientUpdatesApplyTests: APIClientTestCase {
    func testApplyUsesStockPOSTWithoutBody() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/hermes/update")
            XCTAssertNil(apiTestBodyData(from: request))
            return apiTestJSONResponse(#"{"ok":true,"action_id":"new-action"}"#, for: request)
        }
        let response = try await client.applyUpdate()
        XCTAssertEqual(response.actionId, "new-action")
    }

    func testStatusUsesBoundedTailAndDoesNotExposeRawLines() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/actions/hermes-update/status")
            XCTAssertEqual(request.url?.query, "lines=1")
            return apiTestJSONResponse(#"{"running":false,"exit_code":0,"action_id":"new-action","lines":["secret output"],"receipt":{"outcome":"success","post_version":"0.22.0"}}"#, for: request)
        }
        let status = try await client.hermesUpdateStatus()
        XCTAssertEqual(status.actionId, "new-action")
        XCTAssertEqual(status.receipt?.postVersion, "0.22.0")
    }

    func testOnlyMatchingDurableMarkerAndZeroExitConfirmsSuccess() {
        XCTAssertEqual(HermesUpdateCompletion.evaluate(expectedActionID: "new", status: status(running: false, exit: 0, actionID: "new")), .succeeded)
        XCTAssertEqual(HermesUpdateCompletion.evaluate(expectedActionID: "new", status: status(running: true, exit: nil, actionID: nil)), .waiting)
        XCTAssertEqual(HermesUpdateCompletion.evaluate(expectedActionID: "new", status: status(running: false, exit: 0, actionID: "old", receipt: .init(outcome: "success", postVersion: "latest"))), .unknown)
        XCTAssertEqual(HermesUpdateCompletion.evaluate(expectedActionID: "new", status: status(running: false, exit: 1, actionID: "new")), .unknown)
        XCTAssertEqual(HermesUpdateCompletion.evaluate(expectedActionID: "new", status: status(running: false, exit: 0, actionID: "new"), isCancelled: true), .unknown)
    }

    func testLostAcknowledgementAndAlreadyRunningWithoutIDRemainUnowned() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let lost = try decoder.decode(UpdatesApplyResponse.self, from: Data(#"{"ok":true}"#.utf8))
        let existing = try decoder.decode(UpdatesApplyResponse.self, from: Data(#"{"ok":true,"already_running":true}"#.utf8))
        XCTAssertNil(lost.actionId)
        XCTAssertNil(existing.actionId)
        XCTAssertTrue(existing.alreadyRunning == true)
        XCTAssertEqual(HermesUpdateStart.evaluate(lost), .unknown)
        XCTAssertEqual(HermesUpdateStart.evaluate(existing), .unknown)
    }

    func testOnlyExplicitRefusalIsRetryableAndKnownIDCanBeMonitored() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let malformed = try decoder.decode(UpdatesApplyResponse.self, from: Data(#"{"action_id":"id"}"#.utf8))
        let refused = try decoder.decode(UpdatesApplyResponse.self, from: Data(#"{"ok":false}"#.utf8))
        let accepted = try decoder.decode(UpdatesApplyResponse.self, from: Data(#"{"ok":true,"action_id":"id"}"#.utf8))
        XCTAssertEqual(HermesUpdateStart.evaluate(malformed), .unknown)
        XCTAssertEqual(HermesUpdateStart.evaluate(refused), .refused)
        XCTAssertEqual(HermesUpdateStart.evaluate(accepted), .monitor(actionID: "id"))
    }

    func testNilRunningDoesNotComplete() {
        XCTAssertEqual(HermesUpdateCompletion.evaluate(expectedActionID: "new", status: status(running: nil, exit: 0, actionID: "new")), .waiting)
    }

    func testManagedRefusalRetainsGuidance() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(UpdatesApplyResponse.self, from: Data(#"{"ok":false,"error":"apt_update_required","message":"Run pkg upgrade."}"#.utf8))
        XCTAssertEqual(response.displayMessage(default: "fallback"), "Run pkg upgrade.")
    }

    private func status(running: Bool?, exit: Int?, actionID: String?, receipt: HermesUpdateReceiptSummary? = nil) -> HermesUpdateStatusResponse {
        HermesUpdateStatusResponse(running: running, exitCode: exit, actionId: actionID, receipt: receipt)
    }
}
