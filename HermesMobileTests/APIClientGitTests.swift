import XCTest
@testable import HermesMobile

/// Request construction + tolerant decoding for the read-only workspace-git endpoints
/// (issue #312, Slice A). Mirrors `APIClientWorkspaceFileTests`.
final class APIClientGitTests: APIClientTestCase {

    private func directClient(status: String, review: String, branches: String = #"{"branches":[]}"#,
                              diff: String = #"{"diff":"@@ -1 +1 @@\n-old\n+new"}"#,
                              inspect: ((URLRequest) throws -> Void)? = nil) -> APIClient {
        makeClient { request in
            try inspect?(request)
            XCTAssertEqual(request.httpMethod, "GET")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let route = request.url!.path
            if route == "/api/sessions/chat" {
                XCTAssertEqual(items.first { $0.name == "profile" }?.value, "work")
                return apiTestJSONResponse(#"{"id":"chat","profile":"work","cwd":"/repo/nested"}"#, for: request)
            }
            XCTAssertNil(items.first { $0.name == "profile" })
            XCTAssertNil(items.first { $0.name == "session_id" })
            XCTAssertEqual(items.first { $0.name == "path" }?.value, route == "/api/git/worktrees" ? "/repo/nested" : "/repo")
            switch route {
            case "/api/git/worktrees": return apiTestJSONResponse(#"{"worktrees":[{"path":"/repo","isMain":true},{"path":"/other"}]}"#, for: request)
            case "/api/git/status": return apiTestJSONResponse(status, for: request)
            case "/api/git/review/list":
                XCTAssertEqual(items.first { $0.name == "scope" }?.value, "uncommitted")
                return apiTestJSONResponse(review, for: request)
            case "/api/git/branches": return apiTestJSONResponse(branches, for: request)
            case "/api/git/review/diff": return apiTestJSONResponse(diff, for: request)
            default: XCTFail("Unexpected direct Git route"); throw URLError(.badURL)
            }
        }
    }

    func testDirectStatusUsesFreshScopedCWDAndFullReviewBeyondMetadataCap() async throws {
        let rows = (0..<201).map { ["path": "file\($0)", "status": "M", "staged": true, "added": 2, "removed": 1] as [String: Any] }
        let flags = (0..<200).map { ["path": "file\($0)", "staged": true, "unstaged": false, "untracked": false, "conflicted": false] as [String: Any] }
        let status = String(data: try JSONSerialization.data(withJSONObject: ["branch": "main", "changed": 201, "files": flags]), encoding: .utf8)!
        let review = String(data: try JSONSerialization.data(withJSONObject: ["files": rows]), encoding: .utf8)!
        let result = try await directClient(status: status, review: review).directGitStatus(sessionID: "chat", profile: "work").git
        XCTAssertEqual(result?.files?.count, 201)
        XCTAssertEqual(result?.truncated, false)
        XCTAssertEqual(result?.files?.first?.unstaged, false)
        XCTAssertNil(result?.files?.last?.unstaged)
        XCTAssertNil(result?.files?.last?.untracked)
        XCTAssertNil(result?.upstream)
        XCTAssertEqual(result?.files?.last?.additions, 2)
    }

    func testDirectStatusDoesNotConfirmMismatchedOrDuplicateInventory() async throws {
        for review in [#"{"files":[]}"#, #"{"files":[{"path":"a"},{"path":"a"}]}"#] {
            let result = try await directClient(status: #"{"changed":2,"files":[]}"#, review: review)
                .directGitStatus(sessionID: "chat", profile: "work").git
            XCTAssertEqual(result?.truncated, true)
        }
    }

    func testDirectBranchesMapsStockIdentityWithoutInventedMetadata() async throws {
        let client = directClient(status: #"{"branch":"topic","detached":false,"ahead":2,"behind":0}"#,
            review: #"{"files":[]}"#, branches: #"{"branches":[{"name":"topic","isRemote":false},{"name":"origin/other","isRemote":true}]}"#)
        let value = try await client.directGitBranches(sessionID: "chat", profile: "work").branches
        XCTAssertEqual(value?.current, "topic")
        XCTAssertEqual(value?.local?.first?.name, "topic")
        XCTAssertEqual(value?.remote?.first?.name, "origin/other")
        XCTAssertNil(value?.local?.first?.sha)
        XCTAssertEqual(value?.ahead, 2)
    }

    func testDirectDiffRequestsExplicitStagingAndRepositoryRelativeFile() async throws {
        for staged in [false, true] {
            let client = directClient(status: #"{"files":[{"path":"a.swift","unstaged":true}]}"#,
                review: #"{"files":[{"path":"a.swift","staged":true}]}"#) { request in
                if request.url?.path == "/api/git/review/diff" {
                    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    XCTAssertEqual(items.first { $0.name == "staged" }?.value, staged ? "true" : "false")
                    XCTAssertEqual(items.first { $0.name == "scope" }?.value, "uncommitted")
                    XCTAssertEqual(items.first { $0.name == "file" }?.value, "a.swift")
                }
            }
            let result = try await client.directGitDiff(sessionID: "chat", profile: "work", path: "a.swift", staged: staged).diff
            XCTAssertEqual(result?.kind, staged ? "staged" : "unstaged")
            XCTAssertTrue(result?.diff?.contains("+new") == true)
        }
    }

    func testDirectDiffAvoidsStockCleanTrackedAllAddFallback() async throws {
        let client = directClient(status: #"{"files":[{"path":"a","unstaged":false}]}"#,
            review: #"{"files":[{"path":"a","staged":true}]}"#) { request in
                XCTAssertNotEqual(request.url?.path, "/api/git/review/diff")
            }
        let result = try await client.directGitDiff(sessionID: "chat", profile: "work", path: "a", staged: false).diff
        XCTAssertEqual(result?.diff, "")
    }

    func testDirectReadsRejectUnprovenRootWithoutGuessingParents() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sessions/chat": return apiTestJSONResponse(#"{"id":"chat","cwd":"/repo-link/nested"}"#, for: request)
            case "/api/git/worktrees": return apiTestJSONResponse(#"{"worktrees":[{"path":"/repo"}]}"#, for: request)
            case "/api/git/status": return apiTestJSONResponse(#"{"changed":1,"files":[]}"#, for: request)
            default: XCTFail("Must not guess a root or fetch a diff"); throw URLError(.badURL)
            }
        }
        do {
            _ = try await client.directGitStatus(sessionID: "chat", profile: "work")
            XCTFail("Unproven root accepted")
        } catch { XCTAssertTrue(error is DirectGitReadError) }
    }

    func testDirectDiffRejectsTraversalBeforeNetwork() async throws {
        let client = makeClient { _ in XCTFail("Invalid path reached network"); throw URLError(.badURL) }
        do {
            _ = try await client.directGitDiff(sessionID: "chat", profile: "work", path: "../other", staged: false)
            XCTFail("Traversal accepted")
        } catch { XCTAssertTrue(error is DirectGitReadError) }
    }

    func testDirectDiffRefusesUnknownUnstagedBeyondStockMetadataCap() async throws {
        let flags = (0..<200).map { ["path": "file\($0)", "unstaged": false] as [String: Any] }
        let status = String(data: try JSONSerialization.data(withJSONObject: ["files": flags]), encoding: .utf8)!
        let client = directClient(status: status,
            review: #"{"files":[{"path":"file200","staged":true}]}"#) { request in
                XCTAssertNotEqual(request.url?.path, "/api/git/review/diff")
            }
        do {
            _ = try await client.directGitDiff(sessionID: "chat", profile: "work", path: "file200", staged: false)
            XCTFail("Unknown unstaged state must not synthesize additions")
        } catch DirectGitReadError.unconfirmedUnstaged {
            // Explicitly unavailable, not an empty/clean diff or all-add fallback.
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testDirectStageUsesOneResolvedRootAndExplicitFiles() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sessions/chat":
                return apiTestJSONResponse(#"{"id":"chat","profile":"work","cwd":"/repo/nested"}"#, for: request)
            case "/api/git/worktrees":
                return apiTestJSONResponse(#"{"worktrees":[{"path":"/repo"}]}"#, for: request)
            case "/api/git/review/stage":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try self.jsonBody(request)
                XCTAssertEqual(body["path"] as? String, "/repo")
                XCTAssertTrue(["Sources/A.swift", "Sources/B.swift"].contains(body["file"] as? String))
                return apiTestJSONResponse(#"{"ok":true}"#, for: request)
            default: XCTFail("Unexpected route"); throw URLError(.badURL)
            }
        }
        let response = try await client.directGitStage(sessionID: "chat", profile: "work",
            paths: ["Sources/A.swift", "Sources/B.swift"], validateBeforeDispatch: { true })
        XCTAssertEqual(response.ok, true)
        XCTAssertNil(response.git)
    }

    func testDirectFileMutationsRejectEmptyMagicTraversalGlobAndDuplicatesBeforeNetwork() async {
        for paths in [[], [":"], ["../outside"], ["."], ["a//b"], ["*.swift"], ["a?"], ["[ab]"], ["a", "a"]] {
            let client = makeClient { _ in XCTFail("Invalid paths reached network"); throw URLError(.badURL) }
            do {
                _ = try await client.directGitUnstage(sessionID: "chat", profile: "work", paths: paths,
                    validateBeforeDispatch: { true })
                XCTFail("Invalid paths accepted")
            } catch is DirectGitWriteError {}
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testDirectFileMutationPreservesExactWhitespaceFilename() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sessions/chat": return apiTestJSONResponse(#"{"id":"chat","cwd":"/repo"}"#, for: request)
            case "/api/git/worktrees": return apiTestJSONResponse(#"{"worktrees":[{"path":"/repo"}]}"#, for: request)
            case "/api/git/review/stage":
                XCTAssertEqual(try self.jsonBody(request)["file"] as? String, " spaced ")
                return apiTestJSONResponse(#"{"ok":true}"#, for: request)
            default: XCTFail("Unexpected route"); throw URLError(.badURL)
            }
        }
        _ = try await client.directGitStage(sessionID: "chat", profile: "default", paths: [" spaced "],
            validateBeforeDispatch: { true })
    }

    func testDirectFileMutationRevalidatesBeforeEveryPost() async throws {
        let validation = GitWriteValidationSequence([true, false])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sessions/chat": return apiTestJSONResponse(#"{"id":"chat","cwd":"/repo"}"#, for: request)
            case "/api/git/worktrees": return apiTestJSONResponse(#"{"worktrees":[{"path":"/repo"}]}"#, for: request)
            case "/api/git/review/stage": return apiTestJSONResponse(#"{"ok":true}"#, for: request)
            default: XCTFail("Unexpected route"); throw URLError(.badURL)
            }
        }
        do {
            _ = try await client.directGitStage(sessionID: "chat", profile: "default", paths: ["a", "b"],
                validateBeforeDispatch: { await validation.next() })
            XCTFail("Changed second-file scope dispatched")
        } catch DirectGitWriteError.partial(let completed, let total) {
            XCTAssertEqual(completed, 1)
            XCTAssertEqual(total, 2)
        }
    }

    func testDirectMutationTreatsServerFailureAfterDispatchAsUnknown() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sessions/chat": return apiTestJSONResponse(#"{"id":"chat","cwd":"/repo"}"#, for: request)
            case "/api/git/worktrees": return apiTestJSONResponse(#"{"worktrees":[{"path":"/repo"}]}"#, for: request)
            case "/api/git/review/stage": return self.errorResponse(#"{"detail":"temporarily unavailable"}"#, status: 503, for: request)
            default: XCTFail("Unexpected route"); throw URLError(.badURL)
            }
        }
        do {
            _ = try await client.directGitStage(sessionID: "chat", profile: "default", paths: ["a"],
                validateBeforeDispatch: { true })
            XCTFail("Server failure was treated as definite")
        } catch DirectGitWriteError.unknown(let completed, let total) {
            XCTAssertEqual(completed, 0)
            XCTAssertEqual(total, 1)
        }
    }

    func testDirectStageRevalidatesAfterRootResolutionBeforePosting() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sessions/chat": return apiTestJSONResponse(#"{"id":"chat","cwd":"/repo"}"#, for: request)
            case "/api/git/worktrees": return apiTestJSONResponse(#"{"worktrees":[{"path":"/repo"}]}"#, for: request)
            default: XCTFail("Validation failure must prevent POST"); throw URLError(.badURL)
            }
        }
        do {
            _ = try await client.directGitStage(sessionID: "chat", profile: "default", paths: ["a"],
                validateBeforeDispatch: { false })
            XCTFail("Changed selection dispatched")
        } catch DirectGitWriteError.validationChanged {}
    }

    func testDirectPushRequiresAttachedBranchAndUsesStockBody() async throws {
        let detached = directWriteClient(status: #"{"branch":null,"detached":true,"changed":0}"#)
        do {
            _ = try await detached.directGitPush(sessionID: "chat", profile: "work",
                validateBeforeDispatch: { true })
            XCTFail("Detached push dispatched")
        } catch DirectGitWriteError.detachedHead {}

        let attached = directWriteClient(status: #"{"branch":"main","detached":false,"changed":0}"#)
        let response = try await attached.directGitPush(sessionID: "chat", profile: "work",
            validateBeforeDispatch: { true })
        XCTAssertEqual(response.ok, true)
    }

    func testDirectLocalSwitchRequiresCleanCompleteInventoryAndExactLocalTarget() async throws {
        let client = directWriteClient(status: #"{"branch":"main","detached":false,"changed":0}"#,
            review: #"{"files":[]}"#,
            branches: #"{"branches":[{"name":"topic","isRemote":false},{"name":"origin/remote","isRemote":true}]}"#)
        let response = try await client.directGitSwitchLocalBranch(sessionID: "chat", profile: "work",
            branch: "topic", validateBeforeDispatch: { true })
        XCTAssertEqual(response.currentBranch, "topic")
    }

    func testDirectLocalSwitchRejectsNamesChangedByStockTrailingSanitizer() async {
        for branch in ["topic-", "topic.", "topic/"] {
            let client = makeClient { _ in XCTFail("Sanitizer-changing branch reached network"); throw URLError(.badURL) }
            do {
                _ = try await client.directGitSwitchLocalBranch(sessionID: "chat", profile: "work",
                    branch: branch, validateBeforeDispatch: { true })
                XCTFail("Sanitizer-changing branch accepted")
            } catch DirectGitWriteError.unavailableLocalBranch {}
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    private func directWriteClient(
        status: String,
        review: String = #"{"files":[]}"#,
        branches: String = #"{"branches":[]}"#
    ) -> APIClient {
        makeClient { request in
            switch request.url?.path {
            case "/api/sessions/chat": return apiTestJSONResponse(#"{"id":"chat","profile":"work","cwd":"/repo/nested"}"#, for: request)
            case "/api/git/worktrees": return apiTestJSONResponse(#"{"worktrees":[{"path":"/repo"}]}"#, for: request)
            case "/api/git/status": return apiTestJSONResponse(status, for: request)
            case "/api/git/review/list": return apiTestJSONResponse(review, for: request)
            case "/api/git/branches": return apiTestJSONResponse(branches, for: request)
            case "/api/git/review/push":
                let body = try self.jsonBody(request)
                XCTAssertEqual(body["path"] as? String, "/repo")
                return apiTestJSONResponse(#"{"ok":true}"#, for: request)
            case "/api/git/branch/switch":
                let body = try self.jsonBody(request)
                XCTAssertEqual(body["path"] as? String, "/repo")
                XCTAssertEqual(body["branch"] as? String, "topic")
                return apiTestJSONResponse(#"{"branch":"topic"}"#, for: request)
            default: XCTFail("Unexpected route"); throw URLError(.badURL)
            }
        }
    }

    private func query(_ request: URLRequest) throws -> [String: String?] {
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
    }

    private func errorResponse(_ json: String, status: Int, for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(apiTestBodyData(from: request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

}

private actor GitWriteValidationSequence {
    private var values: [Bool]
    init(_ values: [Bool]) { self.values = values }
    func next() -> Bool { values.isEmpty ? false : values.removeFirst() }
}
