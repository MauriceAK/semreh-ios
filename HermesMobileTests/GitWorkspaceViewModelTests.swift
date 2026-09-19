import XCTest
@testable import HermesMobile

/// Holds one stock read without blocking URLProtocol's delivery queue.
private final class GitReadFixtureGate: URLProtocol {
    private static let lock = NSLock()
    private static var route = ""
    private static var observed: XCTestExpectation?
    private static var held: GitReadFixtureGate?
    private static var count = 0

    static func configure(route: String, observed: XCTestExpectation) {
        lock.lock(); defer { lock.unlock() }
        self.route = route; self.observed = observed; held = nil; count = 0
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        held = nil; observed = nil
    }
    static func release() {
        lock.lock()
        let pending = held
        held = nil
        lock.unlock()
        pending?.respond(pending?.request.url?.path == "/api/git/branches"
            ? #"{"branches":[{"name":"older","isRemote":false}]}"#
            : #"{"branch":"older","changed":0,"files":[]}"#)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }
    override func startLoading() {
        Self.lock.lock()
        if request.url?.path == Self.route {
            Self.count += 1
            if Self.count == 1 {
                Self.held = self
                let observed = Self.observed
                Self.lock.unlock()
                observed?.fulfill()
                return
            }
        }
        Self.lock.unlock()
        switch request.url?.path {
        case "/api/sessions/s1":
            respond(#"{"id":"s1","profile":"default","cwd":"/tmp/s1"}"#)
        case "/api/git/worktrees":
            respond(#"{"worktrees":[{"path":"/tmp/s1"}]}"#)
        case "/api/git/status":
            respond(#"{"branch":"newer","changed":0,"files":[]}"#)
        case "/api/git/review/list":
            respond(#"{"files":[]}"#)
        case "/api/git/branches":
            respond(#"{"branches":[{"name":"newer","isRemote":false}]}"#)
        default:
            XCTFail("Unexpected stock Git fixture route")
            respond("{}")
        }
    }
    private func respond(_ json: String) {
        let (response, data) = apiTestJSONResponse(json, for: request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// View-model behaviour + diff parsing for the workspace-git feature (issue #312, Slice A).
final class GitWorkspaceViewModelTests: APIClientTestCase {
    @MainActor
    func testDeferredGitControlsRefuseWithoutNetworkRequests() async throws {
        let client = makeClient { request in
            XCTFail("Deferred Git control sent \(request.httpMethod ?? "?") \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let row = try session(id: "s1")
        let availability = GitWorkspaceAvailabilityViewModel(
            session: row, server: URL(string: "https://example.test")!, apiClient: client
        )
        let commit = GitCommitViewModel(
            session: row, server: URL(string: "https://example.test")!, apiClient: client
        )

        let stash = await availability.checkout(
            GitCheckoutTarget(ref: "feature", mode: .local), stashingChanges: true
        )
        let remote = await availability.checkout(GitCheckoutTarget(ref: "origin/feature", mode: .remote))
        let fetched = await availability.performRemoteAction(.fetch)
        let pulled = await availability.performRemoteAction(.pull)
        let quick = await availability.quickCommit(push: true)
        await commit.suggestMessage()
        await commit.discardSelectedOrAll(deleteUntracked: true)
        let committed = await commit.commit(push: true)
        let selected = await commit.commitSelected(push: true)

        XCTAssertEqual(stash, .failure)
        XCTAssertEqual(remote, .failure)
        XCTAssertFalse(fetched)
        XCTAssertFalse(pulled)
        XCTAssertEqual(quick, .failure)
        XCTAssertFalse(committed)
        XCTAssertFalse(selected)
        XCTAssertNotNil(commit.actionErrorMessage)
    }

    @MainActor
    func testDirectStageAndUnstageReloadStatusAndPreserveExplicitProfile() async throws {
        var staged = false
        var posts: [String] = []
        let client = directWriteClient { request in
            if request.httpMethod == "POST" {
                posts.append(request.url?.path ?? "")
                staged = request.url?.path == "/api/git/review/stage"
                return apiTestJSONResponse(#"{"ok":true}"#, for: request)
            }
            return self.directGitReadResponse(request, branch: "main", staged: staged)
        }
        let vm = GitCommitViewModel(
            session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client
        )
        await vm.load()
        XCTAssertEqual(vm.trackedFiles.first?.staged, false)
        await vm.stageSelectedOrAll()
        XCTAssertEqual(vm.trackedFiles.first?.staged, true)
        await vm.unstageSelectedOrAll()
        XCTAssertEqual(vm.trackedFiles.first?.staged, false)
        XCTAssertEqual(posts, ["/api/git/review/stage", "/api/git/review/unstage"])
        XCTAssertNil(vm.actionErrorMessage)
    }

    @MainActor
    func testDirectStagePreservesWhitespaceInExactFilename() async throws {
        var sentFile: String?
        let client = directWriteClient { request in
            if request.url?.path == "/api/git/review/stage" {
                let body = try XCTUnwrap(apiTestBodyData(from: request))
                sentFile = (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["file"] as? String
                return apiTestJSONResponse(#"{"ok":true}"#, for: request)
            }
            return self.directGitReadResponse(request, branch: "main", staged: false, file: " spaced.swift ")
        }
        let vm = GitCommitViewModel(
            session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client
        )
        await vm.load()
        await vm.stageSelectedOrAll()
        XCTAssertEqual(sentFile, " spaced.swift ")
    }

    @MainActor
    func testDirectCleanLocalSwitchAndPushReloadCanonicalReads() async throws {
        var branch = "main"
        var posts: [String] = []
        let client = directWriteClient { request in
            if request.httpMethod == "POST" {
                let path = request.url?.path ?? ""
                posts.append(path)
                if path == "/api/git/branch/switch" { branch = "feature" }
                return apiTestJSONResponse(
                    path == "/api/git/branch/switch" ? #"{"branch":"feature"}"# : #"{"ok":true}"#,
                    for: request
                )
            }
            return self.directGitReadResponse(request, branch: branch, staged: false, changed: 0)
        }
        let vm = GitWorkspaceAvailabilityViewModel(
            session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client
        )
        await vm.load()
        let switched = await vm.checkout(GitCheckoutTarget(ref: "feature", mode: .local))
        let pushed = await vm.performRemoteAction(.push)
        XCTAssertEqual(switched, .success)
        XCTAssertTrue(pushed)
        XCTAssertEqual(vm.currentBranchName, "feature")
        XCTAssertEqual(posts, ["/api/git/branch/switch", "/api/git/review/push"])
    }

    @MainActor
    func testUnknownPushBlocksRepeatUntilExplicitSuccessfulReadback() async throws {
        var pushAttempts = 0
        let client = directWriteClient { request in
            if request.url?.path == "/api/git/review/push" {
                pushAttempts += 1
                throw URLError(.networkConnectionLost)
            }
            return self.directGitReadResponse(request, branch: "main", staged: false, changed: 0)
        }
        let vm = GitWorkspaceAvailabilityViewModel(
            session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client
        )
        await vm.load()
        let first = await vm.performRemoteAction(.push)
        let repeated = await vm.performRemoteAction(.push)
        XCTAssertFalse(first)
        XCTAssertFalse(repeated)
        XCTAssertEqual(pushAttempts, 1)
        await vm.load()
        let afterReadback = await vm.performRemoteAction(.push)
        XCTAssertFalse(afterReadback)
        XCTAssertEqual(pushAttempts, 2)
    }

    private func directWriteClient(
        _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        makeClient(handler: handler)
    }

    private func directGitReadResponse(
        _ request: URLRequest,
        branch: String,
        staged: Bool,
        changed: Int = 1,
        file: String = "a.swift"
    ) -> (HTTPURLResponse, Data) {
        switch request.url?.path {
        case "/api/sessions/s1":
            return apiTestJSONResponse(#"{"id":"s1","profile":"default","cwd":"/tmp/s1"}"#, for: request)
        case "/api/git/worktrees":
            return apiTestJSONResponse(#"{"worktrees":[{"path":"/tmp/s1"}]}"#, for: request)
        case "/api/git/status":
            let files = changed == 0 ? "[]" : "[{\"path\":\"\(file)\",\"unstaged\":\(!staged)}]"
            return apiTestJSONResponse("{\"branch\":\"\(branch)\",\"detached\":false,\"changed\":\(changed),\"files\":\(files)}", for: request)
        case "/api/git/review/list":
            let files = changed == 0 ? "[]" : "[{\"path\":\"\(file)\",\"status\":\"M\",\"staged\":\(staged),\"added\":1,\"removed\":0}]"
            return apiTestJSONResponse("{\"files\":\(files)}", for: request)
        case "/api/git/branches":
            return apiTestJSONResponse(#"{"branches":[{"name":"main","isRemote":false},{"name":"feature","isRemote":false}]}"#, for: request)
        default:
            return apiTestJSONResponse("{}", for: request)
        }
    }

    /// Reuses semantic Git rows for these behavior tests, but emits only the
    /// pinned stock read envelopes. Write fixtures remain unchanged.
    private func makeStockGitClient(nonRepository: Bool = false,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        makeClient { request in
            let route = request.url?.path ?? ""
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if route.hasPrefix("/api/sessions/") {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(query.first { $0.name == "profile" }?.value, "default")
                let id = request.url!.lastPathComponent
                return apiTestJSONResponse(#"{"id":"\#(id)","profile":"default","cwd":"/tmp/\#(id)"}"#, for: request)
            }
            if route == "/api/git/worktrees" {
                let root = try XCTUnwrap(query.first { $0.name == "path" }?.value)
                XCTAssertTrue(root.hasPrefix("/tmp/"))
                return apiTestJSONResponse(nonRepository ? #"{"worktrees":[]}"# : #"{"worktrees":[{"path":"\#(root)"}]}"#, for: request)
            }
            let response = try handler(request)
            guard request.httpMethod == "GET", response.0.statusCode == 200,
                  ["/api/git/status", "/api/git/review/list", "/api/git/branches"].contains(route) else { return response }
            XCTAssertNotNil(query.first { $0.name == "path" })
            XCTAssertNil(query.first { $0.name == "session_id" })
            let fixture = try JSONSerialization.jsonObject(with: response.1) as? [String: Any] ?? [:]
            let git = fixture["git"] as? [String: Any] ?? [:]
            let rows = (git["files"] as? [[String: Any]] ?? []).filter { ($0["ignored"] as? Bool) != true }
            let body: Any
            if route == "/api/git/branches" {
                let branches = fixture["branches"] as? [String: Any] ?? [:]
                var values: [[String: Any]] = []
                for key in ["local", "remote"] {
                    values += (branches[key] as? [[String: Any]] ?? []).map { ["name": $0["name"] ?? "", "isRemote": key == "remote"] }
                }
                body = ["branches": values]
            } else if route == "/api/git/review/list" {
                XCTAssertEqual(query.first { $0.name == "scope" }?.value, "uncommitted")
                body = ["files": rows.map { row -> [String: Any] in
                    ["path": row["path"] ?? "", "status": row["status"] ?? "M",
                     "staged": row["staged"] ?? false, "added": row["additions"] ?? 0,
                     "removed": row["deletions"] ?? 0]
                }]
            } else if nonRepository {
                body = NSNull()
            } else {
                var status = git
                status.removeValue(forKey: "is_git")
                status.removeValue(forKey: "totals")
                status.removeValue(forKey: "truncated")
                status["files"] = rows
                status["changed"] = (git["totals"] as? [String: Any])?["changed"] ?? rows.count
                body = status
            }
            return (response.0, try JSONSerialization.data(withJSONObject: body, options: .fragmentsAllowed))
        }
    }

    private func session(id: String) throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id": "\#(id)", "title": "T", "workspace": "/tmp/\#(id)"}"#.utf8)
        )
    }

    private static let statusWithIgnored = """
    {
      "git": {
        "is_git": true, "branch": "main",
        "totals": {"changed": 1},
        "files": [
          {"path": "a.swift", "status": "M", "unstaged": true, "additions": 3, "deletions": 1, "ignored": false},
          {"path": ".DS_Store", "status": "Ignored", "ignored": true, "additions": 0, "deletions": 0}
        ],
        "truncated": false
      }
    }
    """

    // MARK: - Loading

    @MainActor
    func testNewerStockLoadOwnsStatusAfterOlderResponseFinishes() async throws {
        let observed = expectation(description: "older status held")
        let client = gatedStockClient(route: "/api/git/status", observed: observed)
        defer { GitReadFixtureGate.reset() }
        let vm = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        let older = Task { await vm.load() }
        await fulfillment(of: [observed], timeout: 2)
        await vm.load()
        XCTAssertEqual(vm.status?.branch, "newer")
        GitReadFixtureGate.release()
        await older.value
        XCTAssertEqual(vm.status?.branch, "newer")
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testCancelledStockBranchReadCannotPublishHeldBranches() async throws {
        let observed = expectation(description: "branches held")
        let client = gatedStockClient(route: "/api/git/branches", observed: observed)
        defer { GitReadFixtureGate.reset() }
        let vm = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        vm.seedStatusForTesting(try decodedStatus(Self.statusWithOneFile))
        let loading = Task { await vm.loadBranches() }
        await fulfillment(of: [observed], timeout: 2)
        loading.cancel()
        GitReadFixtureGate.release()
        await loading.value
        XCTAssertNil(vm.branches)
        XCTAssertFalse(vm.isLoadingBranches)
    }

    @MainActor
    func testCanonicalRebindInvalidatesOldTargetReadPublication() async throws {
        let observed = expectation(description: "old target status held")
        let client = gatedStockClient(route: "/api/git/status", observed: observed)
        defer { GitReadFixtureGate.reset() }
        let vm = GitWorkspaceAvailabilityViewModel(
            session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client
        )
        let loading = Task { await vm.load() }
        await fulfillment(of: [observed], timeout: 2)

        vm.rebindToCanonicalSession(sessionID: "durable-id", profile: "work")
        GitReadFixtureGate.release()
        await loading.value

        XCTAssertNil(vm.status)
        XCTAssertFalse(vm.hasRepository)
        XCTAssertEqual(vm.bindingForTesting.sessionID, "durable-id")
        XCTAssertEqual(vm.bindingForTesting.profile, "work")
        XCTAssertEqual(vm.requestSession.sessionId, "durable-id")
        XCTAssertEqual(vm.requestSession.profile, "work")
    }

    private func gatedStockClient(route: String, observed: XCTestExpectation) -> APIClient {
        GitReadFixtureGate.configure(route: route, observed: observed)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitReadFixtureGate.self]
        return APIClient(baseURL: URL(string: "https://example.test")!, session: URLSession(configuration: configuration))
    }

    private func decodedStatus(_ json: String) throws -> GitStatus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try XCTUnwrap(decoder.decode(GitStatusResponse.self, from: Data(json.utf8)).git)
    }

    @MainActor
    func testGenericTruncatedStateBlocksQuickCommitWithoutAnyRequest() async throws {
        let client = makeClient { _ in
            XCTFail("A structurally truncated state must block all writes")
            throw URLError(.badURL)
        }
        let vm = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        vm.seedStatusForTesting(try decodedStatus(Self.truncatedStatus))
        let result = await vm.quickCommit(push: true)
        XCTAssertEqual(result, .failure)
        XCTAssertNil(vm.commitPhase)
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    @MainActor
    func testDuplicateStockReviewInventoryCannotQuickCommit() async throws {
        var writes = 0
        let client = makeStockGitClient { request in
            if request.httpMethod != "GET" { writes += 1 }
            return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"main","totals":{"changed":2},"files":[{"path":"same.swift","status":"M"},{"path":"same.swift","status":"M"}]}}"#, for: request)
        }
        let vm = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()
        XCTAssertEqual(vm.status?.truncated, true)
        let result = await vm.quickCommit(push: true)
        XCTAssertEqual(result, .failure)
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testEmptyStockReviewWithReportedChangesIsNotNothingToCommit() async throws {
        var writes = 0
        let client = makeStockGitClient { request in
            if request.httpMethod != "GET" { writes += 1 }
            return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"main","totals":{"changed":3},"files":[]}}"#, for: request)
        }
        let vm = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()
        XCTAssertEqual(vm.status?.truncated, true)
        XCTAssertEqual(vm.status?.trackedFiles.count, 0)
        let result = await vm.quickCommit(push: false)
        XCTAssertEqual(result, .failure, "Quick commit remains unavailable on stock Hermes.")
        XCTAssertNotNil(vm.actionErrorMessage)
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testFailedExternalRefreshBlocksPreviouslyCommittableInventoryUntilReload() async throws {
        var failRead = false
        var writes = 0
        let client = makeStockGitClient { request in
            if request.httpMethod != "GET" { writes += 1 }
            if failRead && request.url?.path == "/api/git/review/list" {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            return apiTestJSONResponse(Self.statusWithOneFile, for: request)
        }
        let vm = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()
        XCTAssertTrue(vm.hasCommittableChanges)
        XCTAssertEqual(vm.status?.truncated, false)
        failRead = true
        await vm.refreshAfterExternalMutation()
        XCTAssertNil(vm.status)
        XCTAssertNotNil(vm.statusError)
        XCTAssertNotNil(vm.lastError)
        let outcome = await vm.quickCommit(push: true)
        XCTAssertEqual(outcome, .failure)
        XCTAssertNotNil(vm.actionErrorMessage)
        XCTAssertEqual(writes, 0)
        failRead = false
        await vm.loadIfNeeded()
        XCTAssertTrue(vm.hasCommittableChanges)
        XCTAssertNil(vm.statusError)
        XCTAssertNil(vm.lastError)
        XCTAssertEqual(writes, 0, "Recovery reads must not retry the blocked commit.")
    }

    @MainActor
    func testLoadExcludesIgnoredFilesFromCountsAndTotals() async throws {
        let client = makeStockGitClient { request in
            apiTestJSONResponse(Self.statusWithIgnored, for: request)
        }
        let viewModel = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()

        XCTAssertTrue(viewModel.hasRepository)
        XCTAssertFalse(viewModel.isNonRepository)
        let status = try XCTUnwrap(viewModel.status)
        XCTAssertEqual(status.files?.count, 1, "Stock inventory excludes ignored paths.")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let legacyRows = try decoder.decode(GitStatusResponse.self, from: Data(Self.statusWithIgnored.utf8))
        XCTAssertEqual(legacyRows.git?.files?.count, 2)
        XCTAssertEqual(legacyRows.git?.trackedFiles.count, 1, "Generic ignored-row presentation remains covered independently.")
        XCTAssertEqual(status.trackedFiles.count, 1)
        XCTAssertEqual(status.changedCount, 1)
        XCTAssertEqual(status.totalAdditions, 3)
        XCTAssertEqual(status.totalDeletions, 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testRefreshReplacesStaleData() async throws {
        var dirty = true
        let client = makeStockGitClient { request in
            let json = dirty ? Self.statusWithIgnored : #"{"git": {"is_git": true, "branch": "main", "files": [], "totals": {"changed": 0}}}"#
            return apiTestJSONResponse(json, for: request)
        }
        let viewModel = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()
        XCTAssertEqual(viewModel.status?.trackedFiles.count, 1)

        dirty = false
        await viewModel.load()
        XCTAssertEqual(viewModel.status?.trackedFiles.count, 0, "Refreshing replaces, not appends.")
        XCTAssertEqual(viewModel.status?.changedCount, 0)
    }

    @MainActor
    func testDifferentSessionsHaveIndependentState() async throws {
        // One handler that answers per session_id; two view models, each scoped to its session.
        let client = makeStockGitClient { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let workspace = components?.queryItems?.first { $0.name == "path" }?.value
            let branch = workspace == "/tmp/s1" ? "main" : "feature/x"
            return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "\#(branch)", "files": []}}"#, for: request)
        }

        let vm1 = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        let vm2 = GitWorkspaceViewModel(session: try session(id: "s2"), server: URL(string: "https://example.test")!, apiClient: client)

        await vm1.load()
        await vm2.load()

        XCTAssertEqual(vm1.status?.branch, "main")
        XCTAssertEqual(vm2.status?.branch, "feature/x")
    }

    @MainActor
    func testLoadIfNeededLoadsOnlyOnce() async throws {
        var requestCount = 0
        let client = makeStockGitClient { request in
            requestCount += 1
            return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "main", "files": []}}"#, for: request)
        }
        let viewModel = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        XCTAssertEqual(requestCount, 2, "One load reads stock status and review inventory.")
    }

    @MainActor
    func testLoadIfNeededRetriesAfterTransientFailure() async throws {
        var shouldFail = true
        var requestCount = 0
        let client = makeStockGitClient { request in
            if request.url?.path == "/api/git/status" { requestCount += 1 }
            if shouldFail && request.url?.path == "/api/git/status" {
                shouldFail = false
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error": "boom"}"#.utf8))
            }

            return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "main", "files": []}}"#, for: request)
        }
        let viewModel = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.loadIfNeeded()
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(requestCount, 1)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.status?.branch, "main")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testNonRepositoryWorkspaceSetsEmptyState() async throws {
        let client = makeStockGitClient(nonRepository: true) { request in
            apiTestJSONResponse(#"{"git": {"is_git": false}}"#, for: request)
        }
        let viewModel = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()

        XCTAssertTrue(viewModel.isNonRepository)
        XCTAssertFalse(viewModel.hasRepository)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testLoadSurfacesErrorOnHTTPFailure() async throws {
        let client = makeStockGitClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error": "boom"}"#.utf8))
        }
        let viewModel = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()

        XCTAssertNil(viewModel.status)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    // MARK: - Toolbar availability

    @MainActor
    func testAvailabilityShowsOnlyWhenGitInfoConfirmsRepository() async throws {
        let client = makeStockGitClient { request in
            if request.url?.path == "/api/git-info" {
                return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "main"}}"#, for: request)
            }
            if ["/api/git/status", "/api/git/review/list"].contains(request.url?.path ?? "") {
                return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "main", "files": []}}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/git/branches")
            return apiTestJSONResponse(#"{"branches":{"is_git":true,"current":"main"}}"#, for: request)
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        XCTAssertFalse(viewModel.hasRepository)

        await viewModel.load()

        XCTAssertTrue(viewModel.hasRepository)
        XCTAssertEqual(viewModel.status?.changedCount, 0)
        XCTAssertNil(viewModel.lastError)
    }

    func testToolbarPresentationMapsRepositoryStates() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func info(_ json: String) throws -> GitInfo? {
            try decoder.decode(GitInfoResponse.self, from: Data(json.utf8)).git
        }

        let dirty = try info(#"{"git":{"is_git":true,"dirty":2,"behind":0}}"#)
        let behind = try info(#"{"git":{"is_git":true,"dirty":0,"behind":1}}"#)
        let clean = try info(#"{"git":{"is_git":true,"dirty":0,"behind":0}}"#)

        XCTAssertEqual(GitToolbarPresentation(hasRepository: true, isLoading: false, info: dirty, status: nil, statusFailed: false).statusDot, .gray)
        XCTAssertEqual(GitToolbarPresentation(hasRepository: true, isLoading: false, info: behind, status: nil, statusFailed: false).statusDot, .gray)
        XCTAssertNil(GitToolbarPresentation(hasRepository: true, isLoading: false, info: clean, status: nil, statusFailed: false).statusDot)
        XCTAssertNil(GitToolbarPresentation(hasRepository: false, isLoading: false, info: dirty, status: nil, statusFailed: false).statusDot)
    }

    func testToolbarPresentationEnablesChangesAfterStatusFailure() {
        let failed = GitToolbarPresentation(
            hasRepository: true,
            isLoading: false,
            info: nil,
            status: nil,
            statusFailed: true
        )
        let loading = GitToolbarPresentation(
            hasRepository: true,
            isLoading: true,
            info: nil,
            status: nil,
            statusFailed: true
        )

        XCTAssertTrue(failed.changesAreEnabled, "The status sheet provides the manual retry path.")
        XCTAssertFalse(loading.changesAreEnabled)
    }

    @MainActor
    func testAvailabilityHidesForNonRepositoryAndNullGitInfo() async throws {
        var returnsNullGit = false
        let client = makeStockGitClient(nonRepository: true) { request in
            let json = returnsNullGit ? #"{"git": null}"# : #"{"git": {"is_git": false}}"#
            return apiTestJSONResponse(json, for: request)
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()
        XCTAssertFalse(viewModel.hasRepository)

        returnsNullGit = true
        await viewModel.load()
        XCTAssertFalse(viewModel.hasRepository)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testAvailabilityHidesOnHTTPFailure() async throws {
        let client = makeStockGitClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error": "boom"}"#.utf8))
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()

        XCTAssertFalse(viewModel.hasRepository)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testAvailabilityLoadIfNeededRetriesAfterTransientFailure() async throws {
        var shouldFail = true
        var requestCount = 0
        let client = makeStockGitClient { request in
            if request.url?.path == "/api/git/status" { requestCount += 1 }
            if shouldFail && request.url?.path == "/api/git/status" {
                shouldFail = false
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error": "boom"}"#.utf8))
            }

            return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "main"}}"#, for: request)
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.loadIfNeeded()
        XCTAssertFalse(viewModel.hasRepository)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertEqual(requestCount, 1)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(requestCount, 3, "One failed status, one successful snapshot, and branches status read.")
        XCTAssertTrue(viewModel.hasRepository)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testAvailabilityLoadIfNeededRetriesAfterTransientStatusFailure() async throws {
        var reviewCount = 0
        var requestCount = 0
        let client = makeStockGitClient { request in
            if request.url?.path == "/api/git/status" { requestCount += 1 }
            if request.url?.path == "/api/git/review/list" { reviewCount += 1 }
            if request.url?.path == "/api/git/review/list" && reviewCount == 1 {
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error": "boom"}"#.utf8))
            }
            return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "main", "files": []}}"#, for: request)
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.loadIfNeeded()
        XCTAssertFalse(viewModel.hasRepository, "Failed first stock snapshot cannot prove a repository.")
        XCTAssertNil(viewModel.status)
        XCTAssertNotNil(viewModel.statusError)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(viewModel.status?.changedCount, 0)
        XCTAssertNil(viewModel.statusError)
    }

    func testWriteAvailabilityDisablesWritesDuringStreamAndCachedMode() {
        XCTAssertFalse(GitWriteAvailability(isStreaming: false, isViewingCachedData: false).writesDisabled)
        XCTAssertTrue(GitWriteAvailability(isStreaming: true, isViewingCachedData: false).writesDisabled)
        XCTAssertTrue(GitWriteAvailability(isStreaming: false, isViewingCachedData: true).writesDisabled)
        XCTAssertFalse(GitWriteAvailability(isStreaming: true, isViewingCachedData: false).fetchDisabled)
        XCTAssertTrue(GitWriteAvailability(isStreaming: false, isViewingCachedData: true).fetchDisabled)
    }

    func testDisabledGitWriteUsesCurrentServerGuidance() {
        let error = APIError.http(
            statusCode: 403,
            body: #"{"error":"Destructive git writes are disabled","code":"destructive_git_disabled"}"#
        )

        XCTAssertEqual(
            gitWriteFriendlyMessage(for: error),
            "This Hermes server does not allow this Git operation."
        )
    }

    // MARK: - Diff parsing

    func testDiffParserDropsPreambleAndClassifiesLines() {
        let raw = """
        diff --git a/App.swift b/App.swift
        index 1234567..89abcde 100644
        --- a/App.swift
        +++ b/App.swift
        @@ -1,3 +1,3 @@
         context line
        -removed line
        +added line
        """
        let hunks = DiffHunk.parse(raw)

        XCTAssertEqual(hunks.count, 1)
        let hunk = try! XCTUnwrap(hunks.first)
        XCTAssertEqual(hunk.header, "@@ -1,3 +1,3 @@")
        XCTAssertEqual(hunk.lines.count, 3)
        XCTAssertEqual(hunk.lines[0].kind, .context)
        XCTAssertEqual(hunk.lines[1].kind, .deletion)
        XCTAssertEqual(hunk.lines[2].kind, .addition)
        XCTAssertEqual(hunk.lines[2].text, "+added line")
    }

    func testDiffParserHandlesMultipleHunks() {
        let raw = """
        @@ -1,1 +1,1 @@
        -a
        +b
        @@ -10,2 +10,3 @@
         keep
        +new
        """
        let hunks = DiffHunk.parse(raw)

        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].id, 0)
        XCTAssertEqual(hunks[1].id, 1)
        XCTAssertEqual(hunks[1].header, "@@ -10,2 +10,3 @@")
        XCTAssertEqual(hunks[1].lines.map(\.kind), [.context, .addition])
        XCTAssertEqual(hunks[1].displayLabel, "Lines 10-12")
        XCTAssertEqual(hunks[1].lines[0].newLineNumber, 10)
        XCTAssertEqual(hunks[1].lines[1].newLineNumber, 11)
    }

    func testDiffParserCreatesSyntheticPatchWithoutHunkHeader() {
        let hunks = DiffHunk.parse("--- a/a.txt\n+++ b/a.txt\n-old\n+new")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertTrue(hunks[0].isSynthetic)
        XCTAssertEqual(hunks[0].displayLabel, "Patch 1 of 1")
        XCTAssertEqual(hunks[0].additions, 1)
        XCTAssertEqual(hunks[0].deletions, 1)
    }

    func testSyntheticDiffParserKeepsChangedLinesBeginningWithHeaderLikePrefixes() {
        let hunks = DiffHunk.parse("--- a/a.txt\n+++ b/a.txt\n---actual content\n+++actual content")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].lines.map(\.text), ["---actual content", "+++actual content"])
        XCTAssertEqual(hunks[0].lines.map(\.kind), [.deletion, .addition])
    }

    func testDiffParserNumbersMultipleSyntheticPatches() {
        let hunks = DiffHunk.parse("diff --git a/a b/a\n-a\n+b\ndiff --git a/b b/b\n-c\n+d")

        XCTAssertEqual(hunks.map(\.displayLabel), ["Patch 1 of 2", "Patch 2 of 2"])
    }

    func testDiffParserEmptyInputReturnsNoHunks() {
        XCTAssertTrue(DiffHunk.parse("").isEmpty)
        XCTAssertTrue(DiffHunk.parse("diff --git a/x b/x\nindex 1..2\n").isEmpty, "No hunk header → nothing to show.")
    }

    @MainActor
    func testToastProgressSuccessAndAutoDismiss() async {
        let state = GitActionToastState()
        state.showProgress(GitActionProgress(title: "Working", detailLines: ["• Fetching"]))
        XCTAssertNotNil(state.progress)
        XCTAssertNil(state.success)

        state.showSuccess(GitActionSuccess(title: "Done"), autoDismissAfter: .milliseconds(10))
        XCTAssertNil(state.progress)
        XCTAssertNotNil(state.success)

        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(state.success)
    }

    @MainActor
    func testToastRapidReplacementDoesNotDismissLatestSuccess() async {
        let state = GitActionToastState()
        state.showSuccess(GitActionSuccess(title: "First"), autoDismissAfter: .milliseconds(5))
        state.showSuccess(GitActionSuccess(title: "Second"), autoDismissAfter: .seconds(1))

        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.success?.title, "Second")
        state.dismissSuccess()
    }

    // MARK: - Quick commit pipeline (issue #315, Slice C)

    /// Status with a single committable file, used to seed the availability/commit VMs.
    private static let statusWithOneFile = """
    {"git":{"is_git":true,"branch":"main","totals":{"changed":1},"files":[
      {"path":"a.swift","status":"M","unstaged":true,"additions":3,"deletions":1}
    ]}}
    """

    /// Status flagged `truncated` (server capped the list at 500 changed files). Reports a
    /// non-empty list so `hasCommittableChanges` is true and only the truncation blocks the commit.
    private static let truncatedStatus = """
    {"git":{"is_git":true,"branch":"main","totals":{"changed":501},"truncated":true,"files":[
      {"path":"a.swift","status":"M","unstaged":true,"additions":3,"deletions":1}
    ]}}
    """

    private func commitPipelineClient(
        stageStatus: Int = 200,
        pushStatus: Int = 200,
        truncated: Bool = false,
        record: ((String) -> Void)? = nil
    ) -> APIClient {
        makeStockGitClient { request in
            let path = request.url?.path ?? ""
            record?(path)
            switch path {
            case "/api/git-info":
                return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"main","dirty":1}}"#, for: request)
            case "/api/git/status", "/api/git/review/list":
                return apiTestJSONResponse(truncated ? Self.truncatedStatus : Self.statusWithOneFile, for: request)
            case "/api/git/branches":
                return apiTestJSONResponse(#"{"branches":{"is_git":true,"current":"main","local":[],"remote":[]}}"#, for: request)
            case "/api/git/stage":
                if stageStatus != 200 {
                    let response = HTTPURLResponse(url: request.url!, statusCode: stageStatus, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, Data(#"{"error":"Destructive git writes are disabled","code":"destructive_git_disabled"}"#.utf8))
                }
                return apiTestJSONResponse(#"{"ok":true,"git":{"is_git":true,"branch":"main","totals":{"staged":1}}}"#, for: request)
            case "/api/git/commit-message":
                return apiTestJSONResponse(#"{"ok":true,"message":"Generated message","truncated":false}"#, for: request)
            case "/api/git/commit":
                return apiTestJSONResponse(#"{"ok":true,"commit":"abc1234","status":{"is_git":true,"branch":"main","totals":{"changed":0},"files":[]}}"#, for: request)
            case "/api/git/push":
                if pushStatus != 200 {
                    let response = HTTPURLResponse(url: request.url!, statusCode: pushStatus, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, Data(#"{"error":"Remote rejected the push","code":"push_failed"}"#.utf8))
                }
                return apiTestJSONResponse(#"{"ok":true,"message":"pushed","status":{"is_git":true,"branch":"main","files":[]}}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
    }

    @MainActor
    func testRefreshAfterExternalMutationPicksUpNewStatus() async throws {
        var changed = true
        let client = makeStockGitClient { request in
            switch request.url?.path {
            case "/api/git-info":
                return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"main"}}"#, for: request)
            case "/api/git/branches":
                return apiTestJSONResponse(#"{"branches":{"is_git":true,"current":"main"}}"#, for: request)
            default:
                let json = changed ? Self.statusWithOneFile : #"{"git":{"is_git":true,"branch":"main","files":[],"totals":{"changed":0}}}"#
                return apiTestJSONResponse(json, for: request)
            }
        }
        let vm = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()
        XCTAssertEqual(vm.status?.changedCount, 1)

        changed = false
        await vm.refreshAfterExternalMutation()

        XCTAssertEqual(vm.status?.changedCount, 0, "Refreshing after an agent turn surfaces the new working-tree state.")
    }

    // MARK: - Advanced staging sheet view model (GitCommitViewModel)

    private func commitSheetClient(
        suggestSelectedMessage: String = "selected msg",
        discardStatus: Int = 200,
        pushStatus: Int = 200
    ) -> APIClient {
        makeStockGitClient { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/git/push":
                if pushStatus != 200 {
                    let response = HTTPURLResponse(url: request.url!, statusCode: pushStatus, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, Data(#"{"error":"Remote rejected the push","code":"push_failed"}"#.utf8))
                }
                return apiTestJSONResponse(#"{"ok":true,"message":"pushed","status":{"is_git":true,"branch":"main","files":[]}}"#, for: request)
            case "/api/git/status", "/api/git/review/list":
                return apiTestJSONResponse(Self.statusWithOneFile, for: request)
            case "/api/git/commit-message":
                return apiTestJSONResponse(#"{"ok":true,"message":"Generated message","truncated":true}"#, for: request)
            case "/api/git/commit-message-selected":
                return apiTestJSONResponse(#"{"ok":true,"message":"\#(suggestSelectedMessage)","truncated":false}"#, for: request)
            case "/api/git/commit":
                return apiTestJSONResponse(#"{"ok":true,"commit":"abc1234","status":{"is_git":true,"branch":"main","files":[]}}"#, for: request)
            case "/api/git/commit-selected":
                return apiTestJSONResponse(#"{"ok":true,"commit":"deadbee","paths":["a.swift"],"status":{"is_git":true,"branch":"main","files":[]}}"#, for: request)
            case "/api/git/stage":
                return apiTestJSONResponse(#"{"ok":true,"git":{"is_git":true,"branch":"main"}}"#, for: request)
            case "/api/git/discard":
                if discardStatus != 200 {
                    let response = HTTPURLResponse(url: request.url!, statusCode: discardStatus, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, Data(#"{"error":"Destructive git writes are disabled","code":"destructive_git_disabled"}"#.utf8))
                }
                return apiTestJSONResponse(#"{"ok":true,"git":{"is_git":true,"branch":"main","files":[]}}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
    }

}
