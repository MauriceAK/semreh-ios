import Foundation
import XCTest
@testable import HermesMobile

private func mutationHTTPResponse(
    statusCode: Int,
    body: String,
    for request: URLRequest
) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(body.utf8))
}

final class APIClientDirectSessionMutationTests: APIClientTestCase {
    func testRenameUsesOfficialPatchWithExactDurableIDProfileAndOneOperation() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/api/sessions/durable-1")
            XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.query)
            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["profile"] as? String, "default")
            XCTAssertEqual(object["title"] as? String, "Renamed")
            XCTAssertEqual(Set(object.keys), Set(["profile", "title"]))
            return apiTestJSONResponse(#"{"ok":true,"title":"Renamed","future":true}"#, for: request)
        }
        let receipt = try await client.directMutateSession(sessionID: "durable-1", operation: .title("Renamed"))
        XCTAssertEqual(receipt, DirectHermesSessionMutationReceipt(
            sessionID: "durable-1", profile: "default", operation: .title("Renamed")
        ))
    }

    func testPinnedAndArchivedRequireMatchingTypedReadback() async throws {
        var expected: [String] = ["pinned", "archived"]
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let field = try XCTUnwrap(expected.first)
            expected.removeFirst()
            XCTAssertEqual(Set(object.keys), Set(["profile", field]))
            if field == "pinned" {
                XCTAssertEqual(object[field] as? Bool, true)
                return apiTestJSONResponse(#"{"ok":true,"pinned":true}"#, for: request)
            }
            XCTAssertEqual(object[field] as? Bool, false)
            return apiTestJSONResponse(#"{"ok":true,"archived":false}"#, for: request)
        }
        _ = try await client.directMutateSession(sessionID: "durable-1", operation: .pinned(true))
        _ = try await client.directMutateSession(sessionID: "durable-1", operation: .archived(false))
        XCTAssertTrue(expected.isEmpty)
    }

    func testFalseOrMissingReadbackFailsClosed() async throws {
        var response = #"{"ok":false,"pinned":true}"#
        let client = makeClient { request in
            let current = response
            response = #"{"ok":true}"#
            return apiTestJSONResponse(current, for: request)
        }
        do {
            _ = try await client.directMutateSession(sessionID: "durable-1", operation: .pinned(true))
            XCTFail("false acknowledgement must fail")
        } catch let error as DirectHermesSessionMutationError {
            XCTAssertEqual(error, .serverRejected)
        }
        do {
            _ = try await client.directMutateSession(sessionID: "durable-1", operation: .pinned(true))
            XCTFail("missing readback must fail")
        } catch let error as DirectHermesSessionMutationError {
            XCTAssertEqual(error, .missingReadback(field: "pinned"))
        }
    }

    func testMalformedAndOppositeBooleanReadbackFailsClosed() async throws {
        var responses = [
            Data("not-json".utf8),
            Data(#"{"ok":true,"pinned":false}"#.utf8)
        ]
        let client = makeClient { _ in
            let body = responses.removeFirst()
            let response = HTTPURLResponse(
                url: URL(string: "https://example.test/api/sessions/durable-1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        do {
            _ = try await client.directMutateSession(sessionID: "durable-1", operation: .pinned(true))
            XCTFail("malformed response must fail")
        } catch is APIError {
            // The direct decoder must not turn malformed success data into a
            // successful mutation receipt.
        }
        do {
            _ = try await client.directMutateSession(sessionID: "durable-1", operation: .pinned(true))
            XCTFail("opposite readback must fail")
        } catch let error as DirectHermesSessionMutationError {
            XCTAssertEqual(error, .missingReadback(field: "pinned"))
        }
    }

    func testEmptyAndInvalidIDsFailBeforeNetwork() async throws {
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            return apiTestJSONResponse(#"{"ok":true,"pinned":true}"#, for: request)
        }
        let invalid = ["", "   ", " durable-1 ", "ancestor/tip", "../session", String(repeating: "a", count: 129)]
        for sessionID in invalid {
            do {
                _ = try await client.directMutateSession(sessionID: sessionID, operation: .pinned(true))
                XCTFail("invalid ID should fail: \(sessionID)")
            } catch let error as DirectHermesSessionMutationError {
                XCTAssertEqual(error, .invalidSessionID)
            }
        }
        XCTAssertEqual(requestCount, 0)
    }

    func testExplicitProfileIsTrimmedAndAlwaysSent() async throws {
        let client = makeClient { request in
            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["profile"] as? String, "default")
            return apiTestJSONResponse(#"{"ok":true,"archived":true}"#, for: request)
        }
        let receipt = try await client.directMutateSession(
            sessionID: "durable-1", operation: .archived(true), profile: " default "
        )
        XCTAssertEqual(receipt.profile, "default")

        let emptyProfileClient = makeClient { request in
            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["profile"] as? String, "default")
            return apiTestJSONResponse(#"{"ok":true,"archived":false}"#, for: request)
        }
        let fallback = try await emptyProfileClient.directMutateSession(
            sessionID: "durable-1", operation: .archived(false), profile: "   "
        )
        XCTAssertEqual(fallback.profile, "default")
    }

    func testAuthAndGenericHTTPFailuresRemainTransportErrors() async throws {
        let authClient = makeClient { request in
            mutationHTTPResponse(statusCode: 401, body: #"{"detail":"invalid credentials"}"#, for: request)
        }
        do {
            _ = try await authClient.directMutateSession(sessionID: "durable-1", operation: .pinned(true))
            XCTFail("auth response must fail")
        } catch let error as DirectHermesRequestError {
            XCTAssertEqual(error, .http(statusCode: 401, reason: .invalidCredentials))
        }
        let serverClient = makeClient { request in
            mutationHTTPResponse(statusCode: 503, body: #"{"detail":"fixture unavailable"}"#, for: request)
        }
        do {
            _ = try await serverClient.directMutateSession(sessionID: "durable-1", operation: .pinned(true))
            XCTFail("generic server response must fail")
        } catch let error as DirectHermesRequestError {
            XCTAssertEqual(error, .http(statusCode: 503, reason: .unavailable))
        }
    }

    func testNonDefaultProfileIsSentWithoutFallingBackToDefault() async throws {
        let client = makeClient { request in
            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["profile"] as? String, "work")
            XCTAssertEqual(Set(object.keys), Set(["profile", "pinned"]))
            return apiTestJSONResponse(#"{"ok":true,"pinned":false}"#, for: request)
        }
        let receipt = try await client.directMutateSession(
            sessionID: "durable-1", operation: .pinned(false), profile: "work"
        )
        XCTAssertEqual(receipt.profile, "work")
    }
}
