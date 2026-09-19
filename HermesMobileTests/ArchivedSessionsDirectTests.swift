import XCTest
@testable import HermesMobile

@MainActor
final class ArchivedSessionsDirectTests: APIClientTestCase {
    /// Synthetic client-loop coverage for the official single-profile route.
    /// The fixture is deliberately larger than one bounded page so the model's
    /// offset progression and exact collection guard are exercised.
    func testSyntheticDirectPageLoopPaginatesBeyondOnePage() async throws {
        var offsets: [Int] = []
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions")
            let query = Dictionary(uniqueKeysWithValues: URLComponents(
                url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false
            )?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            XCTAssertEqual(query["profile"], "work")
            XCTAssertEqual(query["archived"], "only")
            XCTAssertEqual(query["order"], "recent")
            XCTAssertEqual(query["limit"], "100")
            let offset = try XCTUnwrap(Int(query["offset"] ?? "-1"))
            offsets.append(offset)
            XCTAssertEqual(offset % 100, 0)
            let start = offset
            let end = min(start + 100, 501)
            let rows = (start..<end).map { index in
                "{\"id\":\"archived-\(index)\",\"profile\":\"work\",\"archived\":true}"
            }.joined(separator: ",")
            return apiTestJSONResponse(
                "{\"sessions\":[\(rows)],\"total\":501,\"limit\":100,\"offset\":\(offset)}",
                for: request
            )
        }
        let viewModel = ArchivedSessionsViewModel(
            server: URL(string: "https://example.test")!,
            profile: " work ",
            client: client
        )

        await viewModel.load()

        XCTAssertEqual(offsets, [0, 100, 200, 300, 400, 500])
        XCTAssertEqual(viewModel.sessions.count, 501)
        XCTAssertEqual(viewModel.sessions.first?.sessionId, "archived-0")
        XCTAssertEqual(viewModel.sessions.last?.sessionId, "archived-500")
        XCTAssertNil(viewModel.lastError)
    }

    func testStalledSingleProfilePageDoesNotPublishPartialCollection() async throws {
        let firstPage = (0..<100).map { index in
            "{\"id\":\"capped-\(index)\",\"profile\":\"work\",\"archived\":true}"
        }.joined(separator: ",")
        let lock = NSLock()
        var offsets: [Int] = []
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            let query = Dictionary(uniqueKeysWithValues: URLComponents(
                url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false
            )?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            XCTAssertEqual(query["profile"], "work")
            XCTAssertEqual(query["archived"], "only")
            XCTAssertEqual(query["limit"], "100")
            let offset = try XCTUnwrap(Int(query["offset"] ?? "-1"))
            lock.lock()
            offsets.append(offset)
            let requestNumber = offsets.count
            lock.unlock()

            if requestNumber == 1 {
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"stable-archived","profile":"work","archived":true}],"total":1}"#,
                    for: request
                )
            }
            if offset == 0 {
                return apiTestJSONResponse(
                    "{\"sessions\":[\(firstPage)],\"total\":501,\"limit\":100,\"offset\":0}",
                    for: request
                )
            }
            XCTAssertEqual(offset, 100)
            return apiTestJSONResponse(
                #"{"sessions":[],"total":501,"limit":100,"offset":100}"#,
                for: request
            )
        }
        let viewModel = ArchivedSessionsViewModel(
            server: URL(string: "https://example.test")!, profile: "work", client: client
        )
        await viewModel.load()
        let before = viewModel.sessions

        await viewModel.load()

        XCTAssertEqual(offsets, [0, 0, 100])
        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testPaginationDeduplicatesPinnedBackfillRows() async throws {
        var offsets: [Int] = []
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            let query = Dictionary(uniqueKeysWithValues: URLComponents(
                url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false
            )?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            XCTAssertEqual(query["profile"], "work")
            XCTAssertEqual(query["archived"], "only")
            XCTAssertEqual(query["order"], "recent")
            XCTAssertEqual(query["limit"], "100")
            let offset = try XCTUnwrap(Int(query["offset"] ?? "-1"))
            offsets.append(offset)
            let normalStart = offset
            let normalEnd = normalStart + 100
            let normalRows = (normalStart..<normalEnd).map { index in
                "{\"id\":\"normal-\(index)\",\"profile\":\"work\",\"archived\":true}"
            }
            let rows = normalRows + [#"{"id":"pinned-backfill","profile":"work","archived":true}"#]
            return apiTestJSONResponse(
                "{\"sessions\":[\(rows.joined(separator: ","))],\"total\":201,\"limit\":100,\"offset\":\(offset)}",
                for: request
            )
        }
        let viewModel = ArchivedSessionsViewModel(
            server: URL(string: "https://example.test")!, profile: "work", client: client
        )

        await viewModel.load()

        XCTAssertEqual(offsets, [0, 100])
        XCTAssertEqual(viewModel.sessions.count, 201)
        XCTAssertEqual(Set(viewModel.sessions.map(\.id)).count, 201)
        XCTAssertEqual(viewModel.sessions.filter { $0.id == "pinned-backfill" }.count, 1)
        XCTAssertNil(viewModel.lastError)
    }

    func testUnarchiveUsesExactProfilePatchThenAuthoritativeDetailReadback() async throws {
        var methodsAndPaths: [(String, String)] = []
        let client = makeClient { request in
            methodsAndPaths.append((request.httpMethod ?? "", request.url?.path ?? ""))
            switch (request.url?.path) {
            case "/api/sessions":
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"archived-1","profile":"work","archived":true}],"total":1}"#,
                    for: request
                )
            case "/api/sessions/archived-1":
                if request.httpMethod == "PATCH" {
                    let body = try XCTUnwrap(apiTestBodyData(from: request))
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    XCTAssertEqual(object["profile"] as? String, "work")
                    XCTAssertEqual(object["archived"] as? Bool, false)
                    XCTAssertEqual(Set(object.keys), Set(["profile", "archived"]))
                    return apiTestJSONResponse(#"{"ok":true,"archived":false}"#, for: request)
                }
                XCTAssertEqual(request.httpMethod, "GET")
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first(where: { $0.name == "profile" })?.value, "work")
                return apiTestJSONResponse(
                    #"{"id":"archived-1","profile":"work","archived":false}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected direct archive request")
                throw URLError(.badURL)
            }
        }
        let viewModel = ArchivedSessionsViewModel(
            server: URL(string: "https://example.test")!, profile: "work", client: client
        )
        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first)

        let didUnarchive = await viewModel.unarchive(session)
        XCTAssertTrue(didUnarchive)
        XCTAssertEqual(methodsAndPaths.map { "\($0.0) \($0.1)" }, [
            "GET /api/sessions",
            "PATCH /api/sessions/archived-1",
            "GET /api/sessions/archived-1"
        ])
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertFalse(viewModel.isUnarchiving)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    func testFreshArchiveReadCanShowARearchiveAfterLocalUnarchive() async throws {
        var listCount = 0
        let client = makeClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/sessions"):
                listCount += 1
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"archived-1","profile":"work","archived":true}],"total":1}"#,
                    for: request
                )
            case ("PATCH", "/api/sessions/archived-1"):
                return apiTestJSONResponse(#"{"ok":true,"archived":false}"#, for: request)
            case ("GET", "/api/sessions/archived-1"):
                return apiTestJSONResponse(
                    #"{"id":"archived-1","profile":"work","archived":false}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected direct archive request")
                throw URLError(.badURL)
            }
        }
        let viewModel = ArchivedSessionsViewModel(
            server: URL(string: "https://example.test")!, profile: "work", client: client
        )
        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first)
        let didUnarchive = await viewModel.unarchive(session)
        XCTAssertTrue(didUnarchive)
        XCTAssertTrue(viewModel.sessions.isEmpty)

        // The second list is authoritative and represents another client
        // archiving the same ID after our confirmed unarchive.
        await viewModel.load()

        XCTAssertEqual(listCount, 2)
        XCTAssertEqual(viewModel.sessions.map(\.sessionId), ["archived-1"])
        XCTAssertNil(viewModel.lastError)
    }

    func testMismatchedProfilePageIsRejectedBeforePublishOrMutation() async throws {
        var mutationCount = 0
        let client = makeClient { request in
            if request.url?.path == "/api/sessions" {
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"archived-1","profile":"other","archived":true}],"total":1}"#,
                    for: request
                )
            }
            mutationCount += 1
            XCTFail("A different-profile row must not be mutated")
            throw URLError(.badURL)
        }
        let viewModel = ArchivedSessionsViewModel(
            server: URL(string: "https://example.test")!, profile: "work", client: client
        )
        await viewModel.load()
        XCTAssertEqual(mutationCount, 0)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    func testReadbackMismatchRestoresRowWithoutRetryingPatch() async throws {
        var patchCount = 0
        var detailCount = 0
        let client = makeClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/sessions"):
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"archived-1","profile":"work","archived":true}],"total":1}"#,
                    for: request
                )
            case ("PATCH", "/api/sessions/archived-1"):
                patchCount += 1
                return apiTestJSONResponse(#"{"ok":true,"archived":false}"#, for: request)
            case ("GET", "/api/sessions/archived-1"):
                detailCount += 1
                return apiTestJSONResponse(#"{"id":"archived-1","profile":"work","archived":true}"#, for: request)
            default:
                XCTFail("Unexpected direct archive request")
                throw URLError(.badURL)
            }
        }
        let viewModel = ArchivedSessionsViewModel(
            server: URL(string: "https://example.test")!, profile: "work", client: client
        )
        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first)

        let didUnarchive = await viewModel.unarchive(session)
        XCTAssertFalse(didUnarchive)
        XCTAssertEqual(patchCount, 1)
        XCTAssertEqual(detailCount, 1)
        XCTAssertEqual(viewModel.sessions.map(\.sessionId), ["archived-1"])
        XCTAssertTrue(viewModel.actionErrorMessage?.contains("confirm") == true)
    }

    func testLateLoadCannotResurrectOptimisticallyRemovedRow() async throws {
        let listStarted = expectation(description: "overlapping archive refresh started")
        ArchivedSessionsDelayedURLProtocol.configure { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/sessions"):
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"archived-1","profile":"work","archived":true}],"total":1}"#,
                    for: request
                )
            case ("PATCH", "/api/sessions/archived-1"):
                return apiTestJSONResponse(#"{"ok":true,"archived":false}"#, for: request)
            case ("GET", "/api/sessions/archived-1"):
                return apiTestJSONResponse(#"{"id":"archived-1","profile":"work","archived":false}"#, for: request)
            default:
                XCTFail("Unexpected direct archive request")
                throw URLError(.badURL)
            }
        }
        ArchivedSessionsDelayedURLProtocol.onSecondListStarted = {
            listStarted.fulfill()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchivedSessionsDelayedURLProtocol.self]
        let transportSession = URLSession(configuration: configuration)
        let client = APIClient(baseURL: URL(string: "https://example.test")!, session: transportSession)
        defer {
            ArchivedSessionsDelayedURLProtocol.releaseDelayedList()
            ArchivedSessionsDelayedURLProtocol.reset()
            transportSession.invalidateAndCancel()
        }
        let viewModel = ArchivedSessionsViewModel(
            server: URL(string: "https://example.test")!, profile: "work", client: client
        )
        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first)

        let oldLoad = Task { await viewModel.load() }
        await fulfillment(of: [listStarted], timeout: 2)
        let didUnarchive = await viewModel.unarchive(session)
        XCTAssertTrue(didUnarchive)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        ArchivedSessionsDelayedURLProtocol.releaseDelayedList()
        await oldLoad.value

        XCTAssertTrue(viewModel.sessions.isEmpty)
    }

    func testCancelledRefreshDoesNotPublishErrorOrClearExistingRows() async throws {
        let listStarted = expectation(description: "cancelled archive refresh started")
        let releaseList = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var listCount = 0
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            lock.lock()
            listCount += 1
            let currentCount = listCount
            lock.unlock()
            if currentCount == 2 {
                listStarted.fulfill()
                releaseList.wait()
            }
            return apiTestJSONResponse(
                #"{"sessions":[{"id":"archived-1","profile":"work","archived":true}],"total":1}"#,
                for: request
            )
        }
        let viewModel = ArchivedSessionsViewModel(
            server: URL(string: "https://example.test")!, profile: "work", client: client
        )
        await viewModel.load()
        let before = viewModel.sessions

        let refresh = Task { await viewModel.load() }
        await fulfillment(of: [listStarted], timeout: 2)
        refresh.cancel()
        releaseList.signal()
        await refresh.value

        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isLoading)
    }
}

private final class ArchivedSessionsDelayedURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var listRequestCount = 0
    private static var delayedList: (owner: ArchivedSessionsDelayedURLProtocol, response: HTTPURLResponse, data: Data)?
    static var onSecondListStarted: (() -> Void)?

    static func configure(
        _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.lock()
        requestHandler = handler
        listRequestCount = 0
        delayedList = nil
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        requestHandler = nil
        listRequestCount = 0
        delayedList = nil
        onSecondListStarted = nil
        lock.unlock()
    }

    static func releaseDelayedList() {
        lock.lock()
        let pending = delayedList
        delayedList = nil
        lock.unlock()
        guard let pending else { return }
        pending.owner.finish(response: pending.response, data: pending.data)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let result = try handler(request)
            if request.url?.path == "/api/sessions", Self.captureSecondListIfNeeded(
                owner: self,
                response: result.0,
                data: result.1
            ) {
                return
            }
            finish(response: result.0, data: result.1)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func captureSecondListIfNeeded(
        owner: ArchivedSessionsDelayedURLProtocol,
        response: HTTPURLResponse,
        data: Data
    ) -> Bool {
        lock.lock()
        listRequestCount += 1
        let shouldDelay = listRequestCount == 2
        if shouldDelay {
            delayedList = (owner, response, data)
        }
        let callback = shouldDelay ? onSecondListStarted : nil
        lock.unlock()
        callback?()
        return shouldDelay
    }

    private func finish(response: HTTPURLResponse, data: Data) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
