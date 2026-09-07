import XCTest
@testable import HermesMobile

final class APIClientDirectSessionsTests: APIClientTestCase {
    func testDirectSessionDetailDecodesRawStockRowAndIntegerFlags() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions/durable-1")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "profile" })?.value, "default")
            return apiTestJSONResponse(
                #"""
                {
                  "id":"durable-1", "title":"Linked fixture", "cwd":"/tmp/fixture",
                  "model":"fixture", "source":"tui", "started_at":1770000000,
                  "ended_at":1770000002, "last_activity_at":1770000001,
                  "message_count":4, "input_tokens":10, "output_tokens":8,
                  "pinned":0, "archived":1, "profile":"default",
                  "is_default_profile":true
                }
                """#,
                for: request
            )
        }

        let session = try await client.directSessionDetail(sessionID: "durable-1")
        XCTAssertEqual(session.sessionId, "durable-1")
        XCTAssertEqual(session.title, "Linked fixture")
        XCTAssertEqual(session.workspace, "/tmp/fixture")
        XCTAssertEqual(session.messageCount, 4)
        XCTAssertEqual(session.updatedAt, 1_770_000_001)
        XCTAssertEqual(session.pinned, false)
        XCTAssertEqual(session.archived, true)
        XCTAssertEqual(session.profile, "default")
    }

    func testDirectSessionDetailRejectsPrefixResolvedToDifferentIdentity() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/durable")
            return apiTestJSONResponse(#"{"id":"durable-1","profile":"default"}"#, for: request)
        }

        do {
            _ = try await client.directSessionDetail(sessionID: "durable")
            XCTFail("A prefix link must not be accepted as a different canonical session")
        } catch DirectHermesRESTError.sessionIDMismatch {
            // Expected path.
        } catch {
            XCTFail("Expected sessionIDMismatch, got \(error)")
        }
    }

    func testDirectSessionDetailRejectsProfileMismatchAndMissingIdentity() async throws {
        var requests = 0
        let client = makeClient { request in
            requests += 1
            if requests == 1 {
                return apiTestJSONResponse(#"{"id":"durable-1","profile":"work"}"#, for: request)
            }
            return apiTestJSONResponse(#"{"title":"missing id"}"#, for: request)
        }

        do {
            _ = try await client.directSessionDetail(sessionID: "durable-1", profile: "default")
            XCTFail("Expected profile mismatch")
        } catch DirectHermesRESTError.profileMismatch {
            // Expected path.
        } catch {
            XCTFail("Expected profileMismatch, got \(error)")
        }

        do {
            _ = try await client.directSessionDetail(sessionID: "durable-1", profile: "default")
            XCTFail("Expected missing canonical ID")
        } catch DirectHermesRESTError.missingCanonicalSessionID {
            // Expected path.
        } catch {
            XCTFail("Expected missingCanonicalSessionID, got \(error)")
        }
    }

    func testDirectSessionDetailRejectsUnsafeIDBeforeRequest() async {
        let client = makeClient { _ in
            XCTFail("An unsafe detail ID must not issue a request")
            return apiTestJSONResponse(#"{}"#, for: URLRequest(url: URL(string: "https://example.test")!))
        }

        do {
            _ = try await client.directSessionDetail(sessionID: "../durable-1")
            XCTFail("Expected invalid session ID")
        } catch DirectHermesRESTError.invalidSessionID {
            // Expected path.
        } catch {
            XCTFail("Expected invalidSessionID, got \(error)")
        }
    }

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
            XCTAssertEqual(query["archived"], "exclude")

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

    func testDirectSessionsUsesStockArchiveFilterAndCapsListInputs() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            XCTAssertEqual(query["profile"], "work")
            XCTAssertEqual(query["limit"], "500")
            XCTAssertEqual(query["offset"], "0")
            XCTAssertEqual(query["order"], "created")
            XCTAssertEqual(query["archived"], "only")
            return apiTestJSONResponse(
                #"""
                {
                  "sessions": [{
                    "id": "archived-1",
                    "profile": "work",
                    "archived": true,
                    "pinned": true
                  }],
                  "total": 1,
                  "limit": 500,
                  "offset": 0,
                  "profile_totals": {"work": 1},
                  "errors": []
                }
                """#,
                for: request
            )
        }

        let page = try await client.directSessions(
            profile: " work ",
            limit: 9_999,
            offset: -10,
            order: .created,
            archived: .only
        )

        XCTAssertEqual(page.sessions.first?.sessionId, "archived-1")
        XCTAssertEqual(page.sessions.first?.archived, true)
        XCTAssertEqual(page.limit, 500)
        XCTAssertEqual(page.offset, 0)
    }

    func testDirectSessionsSerializesEveryStockArchiveFilter() async throws {
        var expected = ["exclude", "only", "include"]
        let client = makeClient { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            XCTAssertEqual(query["archived"], expected.removeFirst())
            return apiTestJSONResponse(
                #"{"sessions":[],"total":0,"limit":20,"offset":0,"profile_totals":{"default":0},"errors":[]}"#,
                for: request
            )
        }

        _ = try await client.directSessions(archived: .exclude)
        _ = try await client.directSessions(archived: .only)
        _ = try await client.directSessions(archived: .include)
        XCTAssertTrue(expected.isEmpty)
    }

    func testDirectSearchSessionsUsesStockShapeAndPreservesSearchMetadata() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions/search")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            XCTAssertEqual(query["q"], "needle with spaces")
            XCTAssertEqual(query["profile"], "default")
            XCTAssertEqual(query["limit"], "100")
            return apiTestJSONResponse(
                #"""
                {
                  "results": [{
                    "session_id": "tip-1",
                    "lineage_root": "root-1",
                    "snippet": "needle with spaces",
                    "role": "user",
                    "source": "tui",
                    "model": "fixture",
                    "session_started": 1770000000,
                    "id": "tip-1",
                    "title": "Fixture",
                    "started_at": 1770000000,
                    "ended_at": null,
                    "last_active": 1770000001,
                    "is_active": true,
                    "message_count": 2,
                    "tool_call_count": 0,
                    "input_tokens": 10,
                    "output_tokens": 4,
                    "preview": "needle with spaces",
                    "parent_session_id": null,
                    "archived": false,
                    "future_result_field": {"ignored": true}
                  }],
                  "future_top_level": true
                }
                """#,
                for: request
            )
        }

        let response = try await client.directSearchSessions(
            query: "needle with spaces",
            profile: " default ",
            limit: 999
        )
        let result = try XCTUnwrap(response.results?.first)
        XCTAssertEqual(result.sessionID, "tip-1")
        XCTAssertEqual(result.lineageRoot, "root-1")
        XCTAssertEqual(result.role, "user")
        XCTAssertEqual(result.archived, false)
        XCTAssertEqual(result.messageCount, 2)
        XCTAssertEqual(result.parentSessionID, nil)
    }

    func testDirectSearchSessionsPreservesEmptyResultsAndNullableRole() async throws {
        var requests = 0
        let client = makeClient { request in
            requests += 1
            if requests == 1 {
                return apiTestJSONResponse(#"{"results":[]}"#, for: request)
            }
            return apiTestJSONResponse(
                #"{"results":[{"session_id":"tip-2","lineage_root":"root-2","snippet":"id hit","role":null,"archived":null}]}"#,
                for: request
            )
        }

        let empty = try await client.directSearchSessions(query: "missing")
        XCTAssertEqual(empty.results, [])
        let nullable = try await client.directSearchSessions(query: "tip-2", limit: 0)
        XCTAssertEqual(nullable.results?.first?.sessionID, "tip-2")
        XCTAssertNil(nullable.results?.first?.role)
        XCTAssertNil(nullable.results?.first?.archived)
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

    func testDirectSessionMessagesProjectsCanonicalUserAttachmentDirectives() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/attachment-session/messages")
            return apiTestJSONResponse(
                #"""
                {
                  "session_id": "attachment-session",
                  "messages": [
                    {
                      "id": 7,
                      "role": "user",
                      "content": "Inspect these\n@image:/home/images/upload.jpg\n@file:`attachments/notes with space.txt`"
                    }
                  ]
                }
                """#,
                for: request
            )
        }

        let page = try await client.directSessionMessages(sessionID: "attachment-session")
        let message = try XCTUnwrap(page.messages.first)

        XCTAssertEqual(message.content, "Inspect these\n@image:/home/images/upload.jpg\n@file:`attachments/notes with space.txt`")
        XCTAssertEqual(message.attachments?.map(\.name), ["upload.jpg", "notes with space.txt"])
        XCTAssertEqual(message.attachments?.map(\.path), [
            "/home/images/upload.jpg",
            "attachments/notes with space.txt"
        ])
        XCTAssertEqual(message.attachments?.map(\.isImage), [true, false])
    }

    func testDirectSessionMessagesProjectsCanonicalNativeVisionTextWithoutRewritingParts() async throws {
        let client = makeClient { request in
            return apiTestJSONResponse(
                #"""
                {
                  "session_id": "structured-session",
                  "messages": [
                    {
                      "id": 8,
                      "role": "user",
                      "content": [
                        {"type":"text","text":"@image:/local/photo.png"},
                        {"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}
                      ]
                    }
                  ]
                }
                """#,
                for: request
            )
        }

        let page = try await client.directSessionMessages(sessionID: "structured-session")
        let message = try XCTUnwrap(page.messages.first)

        XCTAssertEqual(message.content, "@image:/local/photo.png")
        XCTAssertEqual(message.attachments?.map(\.path), ["/local/photo.png"])
        XCTAssertEqual(message.contentParts?.count, 2)
        XCTAssertEqual(message.contentParts, [
            .object([
                "type": .string("text"),
                "text": .string("@image:/local/photo.png")
            ]),
            .object([
                "type": .string("image_url"),
                "image_url": .object(["url": .string("data:image/png;base64,AAAA")])
            ])
        ])
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
