import Foundation
import XCTest
@testable import HermesMobile

final class APIClientDirectProfilesTests: APIClientTestCase {
    func testStartupDefaultWriteUsesStockPostAndDurableReadbackWithoutChangingCurrent() async throws {
        var methods: [String] = []
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/active")
            XCTAssertNil(request.url?.query)
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                let body = try XCTUnwrap(apiTestJSONBody(from: request) as? [String: String])
                XCTAssertEqual(body, ["name": "work"])
                return apiTestJSONResponse(#"{"ok":true,"active":"work"}"#, for: request)
            }
            XCTAssertEqual(request.httpMethod, "GET")
            return apiTestJSONResponse(#"{"active":"work","current":"personal"}"#, for: request)
        }
        let result = try await client.directSetStartupDefaultProfile(name: " Work ")
        XCTAssertEqual(methods, ["POST", "GET"])
        XCTAssertEqual(result.startupDefaultName, "work")
        XCTAssertEqual(result.current, "personal")
    }

    func testStartupDefaultWriteRejectsMismatchedReadbackWithoutRetry() async throws {
        var methods: [String] = []
        let client = makeClient { request in
            methods.append(request.httpMethod ?? "")
            return apiTestJSONResponse(request.httpMethod == "POST"
                ? #"{"ok":true,"active":"work"}"#
                : #"{"active":"other","current":"personal"}"#, for: request)
        }
        do { _ = try await client.directSetStartupDefaultProfile(name: "work"); XCTFail("Readback must match") }
        catch DirectStartupDefaultWriteError.unconfirmed { }
        XCTAssertEqual(methods, ["POST", "GET"])
    }

    func testStartupDefaultWriteRejectsMissingOrConflictingAcknowledgement() async throws {
        for response in [#"{"active":"work"}"#, #"{"ok":false,"active":"work"}"#, #"{"ok":true,"active":"other"}"#] {
            var count = 0
            let client = makeClient { request in
                count += 1
                XCTAssertEqual(request.httpMethod, "POST")
                return apiTestJSONResponse(response, for: request)
            }
            do { _ = try await client.directSetStartupDefaultProfile(name: "work"); XCTFail("Unproven ACK") }
            catch DirectStartupDefaultWriteError.unconfirmed { }
            XCTAssertEqual(count, 1)
        }
    }

    func testStartupDefaultAcknowledgementDoesNotSucceedWhenReadbackFails() async throws {
        var methods: [String] = []
        let client = makeClient { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                return apiTestJSONResponse(#"{"ok":true,"active":"work"}"#, for: request)
            }
            throw URLError(.timedOut)
        }
        do { _ = try await client.directSetStartupDefaultProfile(name: "work"); XCTFail("ACK alone is insufficient") }
        catch { }
        XCTAssertEqual(methods, ["POST", "GET"])
    }

    func testStartupDefaultLostPostAcknowledgementIsNotRetried() async throws {
        var count = 0
        let client = makeClient { _ in
            count += 1
            throw URLError(.timedOut)
        }
        do { _ = try await client.directSetStartupDefaultProfile(name: "work"); XCTFail("Unconfirmed write") }
        catch { }
        XCTAssertEqual(count, 1)
    }

    func testStartupDefaultEmptyNameDoesNotDispatch() async throws {
        let client = makeClient { _ in
            XCTFail("Empty name must not dispatch")
            throw URLError(.badURL)
        }
        do { _ = try await client.directSetStartupDefaultProfile(name: " \n "); XCTFail("Expected invalid name") }
        catch DirectStartupDefaultWriteError.invalidName { }
    }
}
