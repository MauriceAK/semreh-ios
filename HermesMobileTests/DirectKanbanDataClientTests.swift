import XCTest
@testable import HermesMobile

final class DirectKanbanDataClientTests: APIClientTestCase {
    func testRealisticStockReadShapesProduceWritableCompatibleHandshakeAndFlattenedStats() async throws {
        let adapter = makeAdapter { request in
            switch request.url?.path {
            case "/api/plugins/kanban/config":
                return apiTestJSONResponse(#"{"default_tenant":"app","lane_by_profile":true,"include_archived_by_default":false,"render_markdown":true}"#, for: request)
            case "/api/plugins/kanban/boards":
                return apiTestJSONResponse(#"{"boards":[{"slug":"main","name":"Main"}],"current":"main"}"#, for: request)
            case "/api/plugins/kanban/board":
                return apiTestJSONResponse(#"{"columns":[{"name":"triage","tasks":[{"id":"t_1","title":"Audit","status":"triage"}]},{"name":"todo","tasks":[]},{"name":"scheduled","tasks":[]},{"name":"ready","tasks":[]},{"name":"running","tasks":[]},{"name":"blocked","tasks":[]},{"name":"review","tasks":[]},{"name":"done","tasks":[]}],"tenants":["app"],"assignees":["builder"],"latest_event_id":7,"now":"2026-09-08T00:00:00Z"}"#, for: request)
            case "/api/plugins/kanban/stats":
                return apiTestJSONResponse(#"{"by_status":{"triage":1,"ready":2,"done":3},"by_assignee":{"builder":{"ready":2,"done":1},"reviewer":{"done":2}},"oldest_ready_age_seconds":12,"now":"2026-09-08T00:00:00Z"}"#, for: request)
            default:
                XCTFail("Unexpected stock route \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let configuration = try await adapter.kanbanConfiguration()
        let boards = try await adapter.kanbanBoards()
        let snapshot = try await adapter.kanbanBoard(.init(board: "main"))
        let stats = try await adapter.kanbanStats(board: "main")

        XCTAssertEqual(configuration.columns, [
            "triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"
        ])
        XCTAssertEqual(configuration.readOnly, false)
        XCTAssertEqual(boards.readOnly, false)
        XCTAssertEqual(snapshot.readOnly, false)
        XCTAssertNoThrow(try KanbanCompatibilityValidator.validate(
            configuration: configuration, boardsResponse: boards, snapshot: snapshot
        ))
        XCTAssertEqual(stats.total, 6)
        XCTAssertEqual(stats.byStatus, ["triage": 1, "ready": 2, "done": 3])
        XCTAssertEqual(stats.byAssignee, ["builder": 3, "reviewer": 2])
    }

    func testExplicitColumnsAndReadOnlySafetyFieldsAreNeverOverwritten() async throws {
        let adapter = makeAdapter { request in
            switch request.url?.path {
            case "/api/plugins/kanban/config":
                return apiTestJSONResponse(#"{"columns":["custom"],"read_only":true}"#, for: request)
            case "/api/plugins/kanban/boards":
                return apiTestJSONResponse(#"{"boards":[{"slug":"main"}],"current":"main","read_only":true}"#, for: request)
            case "/api/plugins/kanban/board":
                return apiTestJSONResponse(#"{"columns":[{"name":"custom","tasks":[]}],"read_only":true}"#, for: request)
            default:
                XCTFail("Unexpected route")
                throw URLError(.badURL)
            }
        }

        let configuration = try await adapter.kanbanConfiguration()
        let boards = try await adapter.kanbanBoards()
        let snapshot = try await adapter.kanbanBoard(.init(board: "main"))

        XCTAssertEqual(configuration.columns, ["custom"])
        XCTAssertEqual(configuration.readOnly, true)
        XCTAssertEqual(boards.readOnly, true)
        XCTAssertEqual(snapshot.readOnly, true)
    }

    func testBoardReadUsesAuthenticatedStockPluginRoutesAndExactQuery() async throws {
        var paths: [String] = []
        let adapter = makeAdapter { request in
            paths.append(try XCTUnwrap(request.url?.path))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            if request.url?.path == "/api/plugins/kanban/config" {
                return apiTestJSONResponse(#"{"lane_by_profile":true}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/plugins/kanban/board")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                .init(name: "board", value: "release board"),
                .init(name: "tenant", value: "mobile"),
                .init(name: "include_archived", value: "true")
            ])
            return apiTestJSONResponse(#"{"columns":[{"name":"triage","tasks":[{"id":"t_1","title":"Audit","status":"triage","age":{"created_age_seconds":12}}]}],"tenants":["mobile"],"assignees":["review"],"latest_event_id":7}"#, for: request)
        }

        let snapshot = try await adapter.kanbanBoard(.init(board: "release board", tenant: "mobile", includeArchived: true))
        XCTAssertEqual(paths, ["/api/plugins/kanban/board"])
        XCTAssertEqual(snapshot.columns?.first?.cards?.first?.cardID, "t_1")
        XCTAssertEqual(snapshot.columns?.first?.cards?.first?.ageSeconds, 12)
        XCTAssertEqual(snapshot.latestEventID, 7)
    }

    func testTriageCreateUsesExactStockBodyAndDoesNotRetry() async throws {
        var taskRequests = 0
        let adapter = makeAdapter { request in
            if request.url?.path == "/api/plugins/kanban/config" {
                return apiTestJSONResponse("{}", for: request)
            }
            taskRequests += 1
            XCTAssertEqual(request.url?.path, "/api/plugins/kanban/tasks")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(body["title"] as? String, "Audit")
            XCTAssertEqual(body["triage"] as? Bool, true)
            XCTAssertEqual(body["idempotency_key"] as? String, "attempt-1")
            XCTAssertNil(body["status"])
            return apiTestJSONResponse(#"{"task":{"id":"t_1","title":"Audit","status":"triage"}}"#, for: request)
        }
        let response = try await adapter.createKanbanCard(.init(
            board: "main", title: "Audit", body: nil, status: "triage", priority: nil,
            assignee: nil, tenant: nil, workspaceKind: "scratch", workspacePath: nil,
            skills: nil, maxRuntimeSeconds: nil, prerequisiteID: nil, idempotencyKey: "attempt-1"
        ))
        XCTAssertEqual(response.card?.cardID, "t_1")
        XCTAssertEqual(taskRequests, 1)
    }

    func testUnavailablePluginAndUnrepresentableCreateAreExplicit() async {
        var requests = 0
        let unavailable = makeAdapter { request in
            requests += 1
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!,
                Data(#"{"detail":"Not Found"}"#.utf8)
            )
        }
        do { _ = try await unavailable.kanbanConfiguration(); XCTFail("Expected unavailable plugin") }
        catch { XCTAssertEqual(error as? DirectKanbanError, .pluginUnavailable) }
        XCTAssertEqual(requests, 1)

        let refused = makeAdapter { _ in
            XCTFail("A non-representable create must not dispatch")
            throw URLError(.badServerResponse)
        }
        do {
            _ = try await refused.createKanbanCard(.init(
                board: "main", title: "Audit", body: nil, status: "todo", priority: nil,
                assignee: "work", tenant: nil, workspaceKind: "scratch", workspacePath: nil,
                skills: nil, maxRuntimeSeconds: nil, prerequisiteID: nil, idempotencyKey: "attempt-2"
            ))
            XCTFail("Expected exact status refusal")
        } catch { XCTAssertEqual(error as? DirectKanbanError, .createStatusNotRepresentable("todo")) }
    }

    func testExistingPluginResource404MapsToRetainedNotFoundError() async {
        let adapter = makeAdapter { request in
            if request.url?.path == "/api/plugins/kanban/config" {
                return apiTestJSONResponse("{}", for: request)
            }
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!,
                Data(#"{"detail":"Not Found"}"#.utf8)
            )
        }

        do {
            _ = try await adapter.kanbanCardDetail(.init(cardID: "missing", board: "main"))
            XCTFail("Expected a retained not-found error")
        } catch APIError.http(let statusCode, let body) {
            XCTAssertEqual(statusCode, 404)
            XCTAssertNil(body)
        } catch {
            XCTFail("Expected APIError.http, got \(error)")
        }
    }

    func testForbiddenMapsToRetainedHTTPFailureWithoutAvailabilityProbe() async {
        var requests = 0
        let adapter = makeAdapter { request in
            requests += 1
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 403, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!,
                Data(#"{"detail":"Forbidden"}"#.utf8)
            )
        }

        do {
            _ = try await adapter.kanbanBoards()
            XCTFail("Expected forbidden")
        } catch APIError.http(let statusCode, let body) {
            XCTAssertEqual(statusCode, 403)
            XCTAssertNil(body)
        } catch {
            XCTFail("Expected APIError.http, got \(error)")
        }
        XCTAssertEqual(requests, 1)
    }

    func testUnauthorizedMapsToRetainedAuthenticationError() async {
        let adapter = makeAdapter { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!,
                Data(#"{"detail":"Unauthorized"}"#.utf8)
            )
        }

        do {
            _ = try await adapter.kanbanBoards()
            XCTFail("Expected authentication failure")
        } catch APIError.unauthorized {
            // Retained Kanban state recognizes this as an authentication boundary.
        } catch {
            XCTFail("Expected APIError.unauthorized, got \(error)")
        }
    }

    func testCreateStatusMismatchIsReportedWithoutRetry() async {
        var taskRequests = 0
        let adapter = makeAdapter { request in
            if request.url?.path == "/api/plugins/kanban/config" {
                return apiTestJSONResponse("{}", for: request)
            }
            taskRequests += 1
            return apiTestJSONResponse(#"{"task":{"id":"t_race","title":"Race","status":"todo"}}"#, for: request)
        }
        do {
            _ = try await adapter.createKanbanCard(.init(
                board: "main", title: "Race", body: nil, status: "ready", priority: nil,
                assignee: "work", tenant: nil, workspaceKind: "scratch", workspacePath: nil,
                skills: nil, maxRuntimeSeconds: nil, prerequisiteID: nil, idempotencyKey: "attempt-race"
            ))
            XCTFail("Expected the authoritative status mismatch")
        } catch {
            XCTAssertEqual(error as? DirectKanbanError, .createStatusMismatch(expected: "ready", actual: "todo"))
        }
        XCTAssertEqual(taskRequests, 1)
    }

    func testTenantChangeRefusesBeforePatch() async {
        var paths: [String] = []
        let adapter = makeAdapter { request in
            paths.append(try XCTUnwrap(request.url?.path))
            if request.url?.path == "/api/plugins/kanban/config" {
                return apiTestJSONResponse("{}", for: request)
            }
            XCTAssertEqual(request.httpMethod, "GET")
            return apiTestJSONResponse(#"{"task":{"id":"t_1","title":"Audit","status":"triage","tenant":"old"}}"#, for: request)
        }
        do {
            _ = try await adapter.editKanbanCard(.init(cardID: "t_1", board: "main", title: "Audit",
                body: "", tenant: "new", priority: 0, assignee: nil, status: nil))
            XCTFail("Expected tenant refusal")
        } catch { XCTAssertEqual(error as? DirectKanbanError, .tenantMutationNotSupported) }
        XCTAssertEqual(paths, ["/api/plugins/kanban/tasks/t_1"])
    }

    func testRetainedMutationsUseExactStockRoutesBodiesAndAcknowledgements() async throws {
        var operations: [(String, String)] = []
        let adapter = makeAdapter { request in
            let path = try XCTUnwrap(request.url?.path)
            if path == "/api/plugins/kanban/config" { return apiTestJSONResponse("{}", for: request) }
            let method = try XCTUnwrap(request.httpMethod)
            operations.append((method, path))
            switch (method, path) {
            case ("DELETE", "/api/plugins/kanban/boards/release"):
                XCTAssertNil(apiTestBodyData(from: request))
                XCTAssertNil(request.url?.query?.contains("delete="))
                return apiTestJSONResponse(#"{"result":{"action":"archived"},"current":"main"}"#, for: request)
            case ("POST", "/api/plugins/kanban/boards/release/switch"):
                XCTAssertNil(apiTestBodyData(from: request))
                return apiTestJSONResponse(#"{"current":"release"}"#, for: request)
            case ("GET", "/api/plugins/kanban/tasks/t_1"):
                XCTAssertNil(apiTestBodyData(from: request))
                return apiTestJSONResponse(#"{"task":{"id":"t_1","title":"Old","status":"triage","tenant":"mobile"}}"#, for: request)
            case ("PATCH", "/api/plugins/kanban/tasks/t_1"):
                let body = try apiTestJSONBody(from: request)
                if body["title"] != nil {
                    XCTAssertEqual(Set(body.keys), ["title", "body", "priority", "assignee"])
                    XCTAssertEqual(body["assignee"] as? String, "")
                    XCTAssertNil(body["tenant"])
                    return apiTestJSONResponse(#"{"task":{"id":"t_1","title":"New","status":"triage","tenant":"mobile"}}"#, for: request)
                }
                let status = try XCTUnwrap(body["status"] as? String)
                if status == "blocked" { XCTAssertEqual(body["block_reason"] as? String, "waiting") }
                return apiTestJSONResponse("{\"task\":{\"id\":\"t_1\",\"title\":\"New\",\"status\":\"\(status)\"}}", for: request)
            case ("POST", "/api/plugins/kanban/tasks/t_1/comments"):
                let body = try apiTestJSONBody(from: request)
                XCTAssertEqual(body["body"] as? String, "Reviewed")
                return apiTestJSONResponse(#"{"ok":true}"#, for: request)
            case ("POST", "/api/plugins/kanban/links"):
                let body = try apiTestJSONBody(from: request)
                XCTAssertEqual(body["parent_id"] as? String, "t_parent")
                XCTAssertEqual(body["child_id"] as? String, "t_1")
                return apiTestJSONResponse(#"{"ok":true}"#, for: request)
            case ("DELETE", "/api/plugins/kanban/links"):
                XCTAssertNil(apiTestBodyData(from: request))
                return apiTestJSONResponse(#"{"ok":true}"#, for: request)
            case ("POST", "/api/plugins/kanban/tasks/bulk"):
                let body = try apiTestJSONBody(from: request)
                XCTAssertEqual(body["ids"] as? [String], ["t_1"])
                XCTAssertEqual(body["archive"] as? Bool, true)
                return apiTestJSONResponse(#"{"results":[{"id":"t_1","ok":true}]}"#, for: request)
            case ("POST", "/api/plugins/kanban/dispatch"):
                XCTAssertNil(apiTestBodyData(from: request))
                XCTAssertEqual(request.url?.query, "board=release&dry_run=true&max=8")
                return apiTestJSONResponse(#"{"spawned":[],"promoted":0,"reclaimed":0,"skipped_unassigned":[],"skipped_nonspawnable":[],"auto_blocked":[],"timed_out":[],"crashed":[]}"#, for: request)
            default:
                XCTFail("Unexpected operation \(method) \(path)")
                throw URLError(.badURL)
            }
        }

        _ = try await adapter.archiveKanbanBoard(.init(slug: "release"))
        _ = try await adapter.makeKanbanBoardActive(.init(slug: "release"))
        _ = try await adapter.editKanbanCard(.init(cardID: "t_1", board: "release", title: "New",
            body: "Body", tenant: "mobile", priority: 2, assignee: nil, status: nil))
        _ = try await adapter.setKanbanCardStatus(.init(cardID: "t_1", board: "release", status: "done"))
        _ = try await adapter.blockKanbanCard(.init(cardID: "t_1", board: "release", reason: "waiting"))
        _ = try await adapter.unblockKanbanCard(.init(cardID: "t_1", board: "release", reason: nil))
        let comment = try await adapter.addKanbanComment(.init(cardID: "t_1", board: "release", body: "Reviewed"))
        XCTAssertEqual(comment.ok, true)
        let link = try await adapter.addKanbanDependency(.init(board: "release", prerequisiteID: "t_parent", dependentID: "t_1"))
        XCTAssertEqual(link.prerequisiteID, "t_parent")
        let removedLink = try await adapter.removeKanbanDependency(.init(
            board: "release", prerequisiteID: "t_parent", dependentID: "t_1"
        ))
        XCTAssertEqual(removedLink.ok, true)
        let bulk = try await adapter.performKanbanBulkAction(.init(
            board: "release", cardIDs: ["t_1"], action: .archiveCards
        ))
        XCTAssertEqual(bulk.results?.first?.ok, true)
        _ = try await adapter.dispatchKanban(.init(board: "release", dryRun: true))

        XCTAssertEqual(operations.count, 12)
    }

    private func makeAdapter(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> DirectKanbanDataClient {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: configuration),
            customHeaderProvider: { [CustomHeader(name: "Authorization", value: "Bearer fixture")] }
        )
        return DirectKanbanDataClient(apiClient: client)
    }
}
