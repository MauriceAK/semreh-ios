import XCTest
@testable import HermesMobile

final class APIClientDirectSessionsTests: APIClientTestCase {
    func testDirectSessionsUsesExplicitDefaultProfileAndMapsNullableRows() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            XCTAssertEqual(query["profile"], "default")
            XCTAssertEqual(query["limit"], "20")
            XCTAssertEqual(query["offset"], "0")
            XCTAssertEqual(query["order"], "recent")

            return apiTestJSONResponse(
                #"""
                {
                  "sessions": [
                    {
                      "id": "durable-1",
                      "title": null,
                      "cwd": "/tmp/project",
                      "model": "fixture",
                      "source": "tui",
                      "started_at": 1770000000,
                      "last_active": 1770000001,
                      "message_count": 2,
                      "input_tokens": null,
                      "output_tokens": 4,
                      "estimated_cost_usd": null,
                      "actual_cost_usd": 0.25,
                      "profile": null,
                      "pinned": true,
                      "archived": false,
                      "future_field": {"ignored": true}
                    },
                    {"id": null, "title": "Legacy", "message_count": null}
                  ],
                  "total": 2,
                  "limit": 20,
                  "offset": 0,
                  "profile_totals": {"default": 2},
                  "errors": [{"profile": "other", "error": null}],
                  "future_top_level": true
                }
                """#,
                for: request
            )
        }

        let page = try await client.directSessions()

        XCTAssertEqual(page.sessions.count, 2)
        XCTAssertEqual(page.sessions[0].sessionId, "durable-1")
        XCTAssertEqual(page.sessions[0].workspace, "/tmp/project")
        XCTAssertEqual(page.sessions[0].profile, "default")
        XCTAssertEqual(page.sessions[0].estimatedCost, 0.25)
        XCTAssertEqual(page.sessions[0].pinned, true)
        XCTAssertNil(page.sessions[1].sessionId)
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.profileTotals?["default"], 2)
        XCTAssertEqual(page.errors?.first?.profile, "other")
        XCTAssertNil(page.errors?.first?.error)
    }

    func testDirectSessionMessagesUsesLatestCompactedPagingAndResolvedID() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions/ancestor/messages")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            XCTAssertEqual(query["profile"], "work")
            XCTAssertEqual(query["limit"], "120")
            XCTAssertEqual(query["offset"], "120")
            XCTAssertEqual(query["order"], "latest")
            XCTAssertEqual(query["include_compacted"], "true")

            return apiTestJSONResponse(
                #"""
                {
                  "session_id": "continuation-tip",
                  "messages": [
                    {
                      "id": 42,
                      "role": "assistant",
                      "content": "physical compacted row",
                      "display_content": "Visible compacted summary",
                      "timestamp": 1770000002,
                      "reasoning_content": null,
                      "future_message_field": [1, 2, 3]
                    },
                    {"id": null, "role": "user", "content": ["hello", {"type":"text", "text":" world"}]},
                    {"id": 43, "role": "assistant", "content": "internal summary", "display_kind": "hidden"}
                  ],
                  "pagination": {"limit": 120, "offset": 120, "order": "latest", "returned": 3},
                  "future_top_level": null
                }
                """#,
                for: request
            )
        }

        let page = try await client.directSessionMessages(
            sessionID: "ancestor",
            profile: "work",
            limit: 120,
            offset: 120
        )

        XCTAssertEqual(page.sessionID, "continuation-tip")
        XCTAssertEqual(page.messages.map(\.content), ["Visible compacted summary", "hello world", nil])
        XCTAssertEqual(page.messages.first?.messageId, "42")
        XCTAssertEqual(page.messages[1].contentParts?.count, 2)
        XCTAssertEqual(page.pagination?.offset, 120)
        XCTAssertEqual(page.pagination?.order, "latest")
        XCTAssertEqual(page.pagination?.returned, 3)
    }

    func testDirectSessionMessagesBoundsInputsAndPercentEncodesSessionRoute() async throws {
        let client = makeClient { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            XCTAssertEqual(query["profile"], "profile with space")
            XCTAssertEqual(query["limit"], "500")
            XCTAssertEqual(query["offset"], "0")
            XCTAssertTrue(components.percentEncodedPath.contains("ancestor%2Fwith%20space"))
            return apiTestJSONResponse(#"{"session_id":"resolved","messages":[]}"#, for: request)
        }

        _ = try await client.directSessionMessages(
            sessionID: "ancestor/with space",
            profile: " profile with space ",
            limit: 9_999,
            offset: -10
        )
    }

    func testDirectSessionMessagesRejectsBlankSessionIDBeforeRequest() async {
        let client = makeClient { _ in
            XCTFail("Blank session IDs must not issue a request")
            return apiTestJSONResponse(#"{"messages":[]}"#, for: URLRequest(url: URL(string: "https://example.test")!))
        }

        do {
            _ = try await client.directSessionMessages(sessionID: " \n ")
            XCTFail("Expected invalid session ID")
        } catch DirectHermesRESTError.invalidSessionID {
            // Expected.
        } catch {
            XCTFail("Expected invalid session ID, got \(error)")
        }
    }

    func testDirectSessionMessagesRejectsMissingCanonicalSessionID() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"messages":[]}"#, for: request)
        }

        do {
            _ = try await client.directSessionMessages(sessionID: "ancestor")
            XCTFail("Expected missing canonical session ID")
        } catch DirectHermesRESTError.missingCanonicalSessionID {
            // Expected path.
        } catch {
            XCTFail("Expected missing canonical session ID, got \(error)")
        }
    }

    func testDirectSessionsClassifiesStructuredAuthExpiry() async throws {
        let client = makeClient { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            let body = Data(#"{"error":"unauthenticated","detail":"Unauthorized"}"#.utf8)
            return (response, body)
        }

        do {
            _ = try await client.directSessions()
            XCTFail("Expected structured session-expiry error")
        } catch DirectHermesAuthError.sessionExpired {
            // Expected path.
        } catch {
            XCTFail("Expected DirectHermesAuthError.sessionExpired, got \(error)")
        }
    }
}
