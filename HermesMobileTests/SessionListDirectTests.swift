import XCTest
@testable import HermesMobile

final class SessionListDirectTests: APIClientTestCase {
    @MainActor
    func testDeepLinkCacheMissUsesExactDirectDetailAndKeepsArchivedSessionOpenable() async throws {
        var detailRequests = 0
        let client = makeClient { request in
            detailRequests += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions/archived-1")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "profile" })?.value, "default")
            return apiTestJSONResponse(
                #"""
                {
                  "id":"archived-1", "title":"Archived linked chat", "profile":"default",
                  "started_at":1770000000, "last_activity_at":1770000001,
                  "message_count":4, "pinned":0, "archived":1
                }
                """#,
                for: request
            )
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)

        let session = await viewModel.loadSessionForDeepLink(id: "archived-1")

        XCTAssertEqual(session?.sessionId, "archived-1")
        XCTAssertEqual(session?.title, "Archived linked chat")
        XCTAssertEqual(session?.archived, true)
        XCTAssertEqual(detailRequests, 1)
        XCTAssertTrue(viewModel.sessions.isEmpty, "Archived deep links open but do not enter the visible sidebar")
    }

    @MainActor
    func testDeepLinkDetailResponseIsDiscardedAfterActiveProfileChanges() async throws {
        let detailStarted = expectation(description: "direct detail started")
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(
                    #"{"profiles":[{"name":"default","is_default":true},{"name":"work"}],"active":"default","single_profile_mode":false}"#,
                    for: request
                )
            case "/api/sessions/durable-1":
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first(where: { $0.name == "profile" })?.value, "default")
                detailStarted.fulfill()
                Thread.sleep(forTimeInterval: 0.15)
                return apiTestJSONResponse(
                    #"{"id":"durable-1","title":"old profile","profile":"default","archived":0}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected deep-link request: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)
        await viewModel.loadActiveProfile()
        let work = try XCTUnwrap(viewModel.profileOptions.first(where: { $0.name == "work" }))

        let loadTask = Task { @MainActor in
            await viewModel.loadSessionForDeepLink(id: "durable-1")
        }
        await fulfillment(of: [detailStarted], timeout: 1)
        let switched = await viewModel.switchActiveProfile(work)
        XCTAssertTrue(switched)

        let result = await loadTask.value
        XCTAssertNil(result)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testCancelledDeepLinkDoesNotPublishDetailOrError() async throws {
        let detailStarted = expectation(description: "direct detail started")
        let releaseDetail = DispatchSemaphore(value: 0)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/durable-1")
            detailStarted.fulfill()
            _ = releaseDetail.wait(timeout: .now() + 2)
            return apiTestJSONResponse(
                #"{"id":"durable-1","title":"cancelled","profile":"default","archived":0}"#,
                for: request
            )
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)

        let loadTask = Task { @MainActor in
            await viewModel.loadSessionForDeepLink(id: "durable-1")
        }
        await fulfillment(of: [detailStarted], timeout: 1)
        loadTask.cancel()
        releaseDetail.signal()

        let result = await loadTask.value
        XCTAssertNil(result)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertNil(viewModel.lastError)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testNewChatIsLocalDraftAndDoesNotIssueNetworkRequest() async throws {
        let client = makeClient { request in
            XCTFail("New Chat must not issue a request: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)

        let firstDraft = await viewModel.createSession(profile: "work")
        let secondDraft = await viewModel.createSession(profile: "work")
        let first = try XCTUnwrap(firstDraft)
        let second = try XCTUnwrap(secondDraft)

        XCTAssertNil(first.sessionId)
        XCTAssertEqual(first.title, "New Chat")
        XCTAssertEqual(first.profile, "work")
        XCTAssertNotNil(first.createdAt)
        XCTAssertNotEqual(first.createdAt, second.createdAt)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertFalse(viewModel.isCreatingSession)
    }

    @MainActor
    func testProfileSelectionLoadsOnlySelectedProfileFromDirectRoute() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(
                    #"{"profiles":[{"name":"default","is_default":true},{"name":"work"}],"active":"default","single_profile_mode":false}"#,
                    for: request
                )
            case "/api/profiles/sessions":
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first(where: { $0.name == "profile" })?.value, "work")
                XCTAssertEqual(query?.first(where: { $0.name == "limit" })?.value, "500")
                XCTAssertEqual(query?.first(where: { $0.name == "offset" })?.value, "0")
                XCTAssertEqual(query?.first(where: { $0.name == "order" })?.value, "recent")
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"work-2","title":"Recent","cwd":"/tmp/work","started_at":20,"last_active":30,"profile":"work"},{"id":"work-1","title":"Older","started_at":10,"last_active":15,"profile":"work"}],"total":2,"limit":500,"offset":0,"profile_totals":{"work":2}}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)

        await viewModel.loadActiveProfile()
        let work = try XCTUnwrap(viewModel.profileOptions.first(where: { $0.name == "work" }))
        let didSwitch = await viewModel.switchActiveProfile(work)
        XCTAssertTrue(didSwitch)
        XCTAssertEqual(viewModel.activeProfileName, "work")
        let didLoad = await viewModel.load()
        XCTAssertTrue(didLoad)

        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["work-2", "work-1"])
        XCTAssertTrue(viewModel.sessions.allSatisfy { $0.profile == "work" })
    }

    @MainActor
    func testRemoteSearchUsesDirectResultsAndKeepsOnlyKnownUnarchivedIDs() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse(
                    #"""
                    {
                      "sessions":[
                        {"id":"id-hit","title":"ID hit","profile":"default","message_count":2,"archived":false},
                        {"id":"content-hit","title":"Content hit","profile":"default","message_count":2,"archived":false},
                        {"id":"archived-hit","title":"Archived hit","profile":"default","message_count":2,"archived":true}
                      ],
                      "total":3,"limit":500,"offset":0,"profile_totals":{"default":3},"errors":[]
                    }
                    """#,
                    for: request
                )
            case "/api/sessions/search":
                let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
                let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["q"], "needle")
                XCTAssertEqual(query["profile"], "default")
                XCTAssertEqual(query["limit"], "20")
                XCTAssertNil(query["content"])
                XCTAssertNil(query["depth"])
                return apiTestJSONResponse(
                    #"""
                    {
                      "results":[
                        {"session_id":"id-hit","lineage_root":"id-hit","snippet":"Session ID: id-hit","role":null,"archived":false},
                        {"session_id":"content-hit","lineage_root":"content-hit","snippet":"needle","role":"user","archived":false},
                        {"session_id":"archived-hit","lineage_root":"archived-hit","snippet":"needle","role":null,"archived":true},
                        {"session_id":"unknown-hit","lineage_root":"unknown-hit","snippet":"needle","role":null,"archived":false}
                      ]
                    }
                    """#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)

        let initialLoaded = await viewModel.load()
        XCTAssertTrue(initialLoaded)
        XCTAssertEqual(
            Set(viewModel.sessions.compactMap(\.sessionId)),
            Set(["id-hit", "content-hit"]),
            "The direct session fixture must load both unarchived search targets before filtering."
        )
        await viewModel.searchSessions(query: "needle", content: false, depth: 99, debounceNanoseconds: 0)
        XCTAssertEqual(viewModel.remoteContentSearchSessionIDs, ["id-hit"])

        await viewModel.searchSessions(query: "needle", content: true, debounceNanoseconds: 0)
        XCTAssertEqual(viewModel.remoteContentSearchSessionIDs, ["id-hit", "content-hit"])
    }

    @MainActor
    func testSameQueryFromOldProfileCannotReplaceNewProfileSearch() async throws {
        let oldSearchStarted = expectation(description: "default profile search started")
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(
                    #"{"profiles":[{"name":"default","is_default":true},{"name":"work"}],"active":"default","single_profile_mode":false}"#,
                    for: request
                )
            case "/api/profiles/sessions":
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                let profile = query?.first(where: { $0.name == "profile" })?.value
                let id = profile == "work" ? "work-hit" : "default-hit"
                return apiTestJSONResponse(
                    #"""
                    {"sessions":[{"id":"\#(id)","title":"\#(id)","profile":"\#(profile ?? "default")","message_count":2,"archived":false}],"total":1,"limit":500,"offset":0,"profile_totals":{"\#(profile ?? "default")":1},"errors":[]}
                    """#,
                    for: request
                )
            case "/api/sessions/search":
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                let profile = query?.first(where: { $0.name == "profile" })?.value
                if profile == "default" {
                    oldSearchStarted.fulfill()
                    Thread.sleep(forTimeInterval: 0.15)
                    return apiTestJSONResponse(
                        #"{"results":[{"session_id":"default-hit","lineage_root":"default-hit","snippet":"same","role":null,"archived":false}]}"#,
                        for: request
                    )
                }
                XCTAssertEqual(profile, "work")
                return apiTestJSONResponse(
                    #"{"results":[{"session_id":"work-hit","lineage_root":"work-hit","snippet":"same","role":null,"archived":false}]}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)

        await viewModel.loadActiveProfile()
        let initialLoaded = await viewModel.load()
        XCTAssertTrue(initialLoaded)
        let oldSearch = Task { @MainActor in
            await viewModel.searchSessions(query: "same", debounceNanoseconds: 0)
        }
        await fulfillment(of: [oldSearchStarted], timeout: 1)

        let work = try XCTUnwrap(viewModel.profileOptions.first(where: { $0.name == "work" }))
        let switched = await viewModel.switchActiveProfile(work)
        XCTAssertTrue(switched)
        let workLoaded = await viewModel.load()
        XCTAssertTrue(workLoaded)
        XCTAssertEqual(
            Set(viewModel.sessions.compactMap(\.sessionId)),
            Set(["work-hit"]),
            "The switched-profile fixture must load the search target before filtering."
        )
        await viewModel.searchSessions(query: "same", debounceNanoseconds: 0)
        await oldSearch.value

        XCTAssertEqual(viewModel.activeProfileName, "work")
        XCTAssertEqual(viewModel.remoteContentSearchSessionIDs, ["work-hit"])
    }
}
