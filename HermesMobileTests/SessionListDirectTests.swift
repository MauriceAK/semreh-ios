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
            case "/api/sessions":
                let query = Dictionary(
                    uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? [])
                        .map { ($0.name, $0.value ?? "") }
                )
                XCTAssertEqual(query["profile"], "work")
                XCTAssertEqual(query["archived"], "only")
                XCTAssertEqual(query["limit"], "0")
                XCTAssertEqual(query["offset"], "0")
                XCTAssertEqual(query["order"], "recent")
                return apiTestJSONResponse(
                    #"{"sessions":[],"total":0,"limit":0,"offset":0}"#,
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
            case "/api/sessions":
                let query = Dictionary(
                    uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? [])
                        .map { ($0.name, $0.value ?? "") }
                )
                XCTAssertEqual(query["profile"], "default")
                XCTAssertEqual(query["archived"], "only")
                XCTAssertEqual(query["limit"], "0")
                XCTAssertEqual(query["offset"], "0")
                XCTAssertEqual(query["order"], "recent")
                return apiTestJSONResponse(
                    #"{"sessions":[],"total":1,"limit":0,"offset":0}"#,
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
            case "/api/sessions/unknown-hit":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"not found"}"#.utf8))
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
    func testRemoteSearchResolvesUnknownExactIDWithoutChangingCanonicalRows() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse(#"{"sessions":[],"total":0,"limit":500,"offset":0}"#, for: request)
            case "/api/sessions":
                return apiTestJSONResponse(#"{"sessions":[],"total":0,"limit":0,"offset":0}"#, for: request)
            case "/api/sessions/search":
                return apiTestJSONResponse(
                    #"{"results":[{"session_id":"search-only-1","role":null,"archived":false}]}"#,
                    for: request
                )
            case "/api/sessions/search-only-1":
                XCTAssertEqual(request.httpMethod, "GET")
                return apiTestJSONResponse(
                    #"{"id":"search-only-1","title":"Exact search result","profile":"default","pinned":0,"archived":0}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected search request: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)

        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)
        await viewModel.searchSessions(query: "exact", content: false, debounceNanoseconds: 0)

        let visible = viewModel.visibleSessions(searchText: "exact", selectedProjectID: nil)
        XCTAssertEqual(visible.compactMap(\.sessionId), ["search-only-1"])
        XCTAssertTrue(viewModel.sessions.isEmpty, "Search resolution must not insert into canonical sidebar state")
        XCTAssertEqual(viewModel.remoteContentSearchSessionIDs, ["search-only-1"])
        let resolved = try XCTUnwrap(visible.first)
        XCTAssertTrue(viewModel.isSearchOnlySession(resolved))
    }

    @MainActor
    func testRemoteSearchDropsArchivedAndMissingResolvedRowsButKeepsKnownHits() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"known","title":"Known","profile":"default","archived":false}],"total":1}"#,
                    for: request
                )
            case "/api/sessions":
                return apiTestJSONResponse(#"{"sessions":[],"total":0,"limit":0,"offset":0}"#, for: request)
            case "/api/sessions/search":
                return apiTestJSONResponse(
                    #"{"results":[{"session_id":"known","role":null,"archived":false},{"session_id":"archived","role":null,"archived":false},{"session_id":"missing","role":null,"archived":false},{"session_id":"missing-archived","role":null,"archived":false}]}"#,
                    for: request
                )
            case "/api/sessions/archived":
                return apiTestJSONResponse(#"{"id":"archived","title":"Old","profile":"default","archived":1}"#, for: request)
            case "/api/sessions/missing":
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error":"not found"}"#.utf8))
            case "/api/sessions/missing-archived":
                return apiTestJSONResponse(
                    #"{"id":"missing-archived","title":"No archived flag","profile":"default"}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected search request: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)

        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)
        await viewModel.searchSessions(query: "known", content: false, debounceNanoseconds: 0)

        XCTAssertEqual(viewModel.remoteContentSearchSessionIDs, ["known"])
        XCTAssertEqual(viewModel.visibleSessions(searchText: "known", selectedProjectID: nil).compactMap(\.sessionId), ["known"])
        XCTAssertNil(viewModel.searchErrorMessage)
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["known"])
    }

    @MainActor
    func testSearchOnlyMetadataUpdatesDoNotCreateCanonicalOrCachedRows() async throws {
        var patchCount = 0
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse(#"{"sessions":[],"total":0,"limit":500,"offset":0}"#, for: request)
            case "/api/sessions":
                return apiTestJSONResponse(#"{"sessions":[],"total":0,"limit":0,"offset":0}"#, for: request)
            case "/api/sessions/search":
                return apiTestJSONResponse(#"{"results":[{"session_id":"search-only-1","role":null,"archived":false}]}"#, for: request)
            case "/api/sessions/search-only-1":
                if request.httpMethod == "PATCH" {
                    patchCount += 1
                    return patchCount == 1
                        ? apiTestJSONResponse(#"{"ok":true,"pinned":true}"#, for: request)
                        : apiTestJSONResponse(#"{"ok":true,"title":"Renamed search result"}"#, for: request)
                }
                return patchCount == 1
                    ? apiTestJSONResponse(#"{"id":"search-only-1","title":"Search result","profile":"default","pinned":1,"archived":0}"#, for: request)
                    : apiTestJSONResponse(#"{"id":"search-only-1","title":"Renamed search result","profile":"default","pinned":1,"archived":0}"#, for: request)
            default:
                XCTFail("Unexpected search mutation request: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)

        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)
        await viewModel.searchSessions(query: "search", content: false, debounceNanoseconds: 0)
        let original = try XCTUnwrap(viewModel.visibleSessions(searchText: "search", selectedProjectID: nil).first)
        XCTAssertTrue(viewModel.isSearchOnlySession(original))

        let pinnedResult = await viewModel.setPinned(true, for: original)
        XCTAssertTrue(pinnedResult)
        let pinned = try XCTUnwrap(viewModel.visibleSessions(searchText: "search", selectedProjectID: nil).first)
        XCTAssertTrue(pinned.pinned == true)
        let renamedResult = await viewModel.rename(pinned, to: "Renamed search result")
        XCTAssertTrue(renamedResult)

        let updated = try XCTUnwrap(viewModel.visibleSessions(searchText: "search", selectedProjectID: nil).first)
        XCTAssertEqual(updated.title, "Renamed search result")
        XCTAssertTrue(updated.pinned == true)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertEqual(patchCount, 2)
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
            case "/api/sessions":
                let query = Dictionary(
                    uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? [])
                        .map { ($0.name, $0.value ?? "") }
                )
                XCTAssertTrue(query["profile"] == "default" || query["profile"] == "work")
                XCTAssertEqual(query["archived"], "only")
                XCTAssertEqual(query["limit"], "0")
                XCTAssertEqual(query["offset"], "0")
                XCTAssertEqual(query["order"], "recent")
                return apiTestJSONResponse(
                    #"{"sessions":[],"total":0,"limit":0,"offset":0}"#,
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

    @MainActor
    func testStaleSearchOnlyRenameFailureDoesNotPublishAfterSearchIsCleared() async throws {
        let gate = SearchOnlyRenameFailureGate()
        SearchOnlyRenameURLProtocol.configure(gate: gate) { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse(
                    #"{"sessions":[],"total":0,"limit":500,"offset":0}"#,
                    for: request
                )
            case "/api/sessions":
                return apiTestJSONResponse(
                    #"{"sessions":[],"total":0,"limit":0,"offset":0}"#,
                    for: request
                )
            case "/api/sessions/search":
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "q" })?.value
                if query == "replacement" {
                    return apiTestJSONResponse(
                        #"{"results":[]}"#,
                        for: request
                    )
                }
                return apiTestJSONResponse(
                    #"{"results":[{"session_id":"search-only-stale","role":null,"archived":false}]}"#,
                    for: request
                )
            case "/api/sessions/search-only-stale":
                XCTAssertEqual(request.httpMethod, "GET")
                return apiTestJSONResponse(
                    #"{"id":"search-only-stale","title":"Before rename","profile":"default","pinned":0,"archived":0}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected stale-search request: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchOnlyRenameURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: session
        )
        let viewModel = SessionListViewModel(
            server: URL(string: "https://example.test")!,
            client: client
        )
        defer {
            gate.releaseFailure()
            session.invalidateAndCancel()
            SearchOnlyRenameURLProtocol.reset()
        }

        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)
        await viewModel.searchSessions(query: "stale", content: false, debounceNanoseconds: 0)
        let searchOnly = try XCTUnwrap(
            viewModel.visibleSessions(searchText: "stale", selectedProjectID: nil).first
        )
        XCTAssertTrue(viewModel.isSearchOnlySession(searchOnly))

        let renameTask = Task { @MainActor in
            await viewModel.rename(searchOnly, to: "Should not publish")
        }
        await gate.waitForPatchStart()

        viewModel.clearSearchResults()
        await viewModel.searchSessions(query: "replacement", content: false, debounceNanoseconds: 0)
        gate.releaseFailure()

        let renamed = await renameTask.value
        XCTAssertFalse(renamed)
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.lastError)
        XCTAssertNil(viewModel.searchErrorMessage)
        XCTAssertTrue(viewModel.remoteContentSearchSessionIDs.isEmpty)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertTrue(
            viewModel.visibleSessions(searchText: "replacement", selectedProjectID: nil).isEmpty,
            "A replaced search must not receive the stale mutation failure or row"
        )
    }
}

private final class SearchOnlyRenameFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var patchStarted = false
    private var released = false
    private var patchWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markPatchStarted() {
        lock.lock()
        patchStarted = true
        let waiters = patchWaiters
        patchWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func waitForPatchStart() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if patchStarted {
                lock.unlock()
                continuation.resume()
            } else {
                patchWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func releaseFailure() {
        lock.lock()
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class SearchOnlyRenameURLProtocol: URLProtocol {
    private static var gate: SearchOnlyRenameFailureGate?
    private static var responseHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func configure(
        gate: SearchOnlyRenameFailureGate,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        self.gate = gate
        responseHandler = handler
    }

    static func reset() {
        gate = nil
        responseHandler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.responseHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        if request.httpMethod == "PATCH" {
            guard let gate = Self.gate else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            gate.markPatchStarted()
            Task {
                await gate.waitForRelease()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"detail":"distinctive stale rename failure"}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
