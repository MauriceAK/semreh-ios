import Foundation

enum DirectGitReadError: LocalizedError {
    case unprovenRoot, invalidResponse, invalidPath, unconfirmedUnstaged
    var errorDescription: String? {
        switch self {
        case .unprovenRoot: "Hermes could not prove the repository root for this session's workspace."
        case .invalidResponse: "Hermes returned an incomplete Git response."
        case .invalidPath: "The repository-relative file path is invalid."
        case .unconfirmedUnstaged: "Hermes did not provide unstaged metadata for this file. Refresh or view staged changes; an unstaged diff cannot be confirmed."
        }
    }
}

extension APIClient {
    private func directGitRead(_ route: String, path: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents()
        components.path = route
        components.queryItems = [URLQueryItem(name: "path", value: path)] + query
        var request = URLRequest(url: URL(string: components.string!, relativeTo: baseURL)!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        customHeaderProvider().apply(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let protected = URLSession(configuration: session.configuration,
            delegate: DirectHermesRedirectGuard(origin: baseURL), delegateQueue: nil)
        defer { protected.invalidateAndCancel() }
        do {
            return try await boundedData(for: request, using: protected, mapsUnauthorized: false,
                maximumBytes: 8 * 1_024 * 1_024).0
        } catch let APIError.http(statusCode, body) {
            let bytes = Data((body ?? "").utf8)
            if DirectHermesAuthFailureClassifier.isSessionExpired(statusCode: statusCode, body: bytes) {
                throw DirectHermesAuthError.sessionExpired
            }
            throw DirectHermesRequestError.from(statusCode: statusCode, body: bytes)
        }
    }

    private func directGitRoot(sessionID: String, profile: String) async throws -> String? {
        let detail = try await directSessionDetail(sessionID: sessionID, profile: profile)
        guard let cwd = detail.workspace, cwd.hasPrefix("/"), !cwd.contains("\0") else { throw DirectGitReadError.unprovenRoot }
        let data = try await directGitRead("/api/git/worktrees", path: cwd)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trees = envelope["worktrees"] as? [[String: Any]] else { throw DirectGitReadError.invalidResponse }
        let matches = Set(trees.compactMap { $0["path"] as? String }.filter {
            $0.hasPrefix("/") && !$0.contains("\0") && (cwd == $0 || cwd.hasPrefix($0 == "/" ? "/" : $0 + "/"))
        }).sorted { $0.count > $1.count }
        if let root = matches.first { return root }
        let status = try await directGitRead("/api/git/status", path: cwd)
        if (try JSONSerialization.jsonObject(with: status, options: .fragmentsAllowed)) is NSNull { return nil }
        throw DirectGitReadError.unprovenRoot
    }

    func directGitStatus(sessionID: String, profile: String) async throws -> GitStatusResponse {
        guard let root = try await directGitRoot(sessionID: sessionID, profile: profile) else {
            return GitStatusResponse(git: GitStatus(isGit: false, branch: nil, upstream: nil, ahead: nil,
                behind: nil, totals: nil, files: [], truncated: false))
        }
        async let statusData = directGitRead("/api/git/status", path: root)
        async let reviewData = directGitRead("/api/git/review/list", path: root,
            query: [URLQueryItem(name: "scope", value: "uncommitted")])
        let (statusBytes, reviewBytes) = try await (statusData, reviewData)
        guard let status = try JSONSerialization.jsonObject(with: statusBytes, options: .fragmentsAllowed) as? [String: Any],
              let review = try JSONSerialization.jsonObject(with: reviewBytes) as? [String: Any],
              let rows = review["files"] as? [[String: Any]] else { throw DirectGitReadError.invalidResponse }
        let flags = Dictionary((status["files"] as? [[String: Any]] ?? []).compactMap { row -> (String, [String: Any])? in
            guard let path = row["path"] as? String else { return nil }
            return (path, row)
        }, uniquingKeysWith: { first, _ in first })
        let files = try rows.map { row -> [String: Any] in
            guard let path = row["path"] as? String else { throw DirectGitReadError.invalidResponse }
            var file: [String: Any] = ["path": path]
            for (from, to) in [("status", "status"), ("staged", "staged"), ("added", "additions"), ("removed", "deletions")] {
                file[to] = row[from]
            }
            if let detail = flags[path] {
                for key in ["unstaged", "untracked"] { file[key] = detail[key] }
                file["conflict"] = detail["conflicted"]
            }
            // Beyond stock status.files' 200-row cap these flags stay unknown.
            return file
        }
        let uniquePaths = Set(files.compactMap { $0["path"] as? String })
        let incomplete = uniquePaths.count != files.count || (status["changed"] as? Int) != files.count
        var mapped: [String: Any] = ["is_git": true, "files": files, "truncated": incomplete]
        for key in ["branch", "ahead", "behind"] { mapped[key] = status[key] }
        var totals: [String: Any] = [:]
        for key in ["changed", "staged", "unstaged", "untracked"] { totals[key] = status[key] }
        totals["conflicts"] = status["conflicted"]
        mapped["totals"] = totals
        return try decode(GitStatusResponse.self, from: JSONSerialization.data(withJSONObject: ["git": mapped]))
    }

    func directGitInfo(sessionID: String, profile: String) async throws -> GitInfoResponse {
        let status = try await directGitStatus(sessionID: sessionID, profile: profile).git
        return GitInfoResponse(git: GitInfo(branch: status?.branch, dirty: status?.totals?.changed,
            modified: nil, untracked: status?.totals?.untracked, ahead: status?.ahead, behind: status?.behind,
            isGit: status?.isGit))
    }

    func directGitBranches(sessionID: String, profile: String) async throws -> GitBranchesResponse {
        guard let root = try await directGitRoot(sessionID: sessionID, profile: profile) else {
            throw DirectGitReadError.unprovenRoot
        }
        async let branchData = directGitRead("/api/git/branches", path: root)
        async let statusData = directGitRead("/api/git/status", path: root)
        let (branchBytes, statusBytes) = try await (branchData, statusData)
        guard let envelope = try JSONSerialization.jsonObject(with: branchBytes) as? [String: Any],
              let rows = envelope["branches"] as? [[String: Any]],
              let status = try JSONSerialization.jsonObject(with: statusBytes) as? [String: Any] else { throw DirectGitReadError.invalidResponse }
        var mapped: [String: Any] = ["is_git": true,
            "local": rows.filter { ($0["isRemote"] as? Bool) == false }.map { ["name": $0["name"] ?? NSNull()] },
            "remote": rows.filter { ($0["isRemote"] as? Bool) == true }.map { ["name": $0["name"] ?? NSNull()] }]
        mapped["current"] = status["branch"]
        for key in ["detached", "ahead", "behind"] { mapped[key] = status[key] }
        return try decode(GitBranchesResponse.self, from: JSONSerialization.data(withJSONObject: ["branches": mapped]))
    }

    func directGitDiff(sessionID: String, profile: String, path: String, staged: Bool) async throws -> GitDiffResponse {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else { throw DirectGitReadError.invalidPath }
        guard let root = try await directGitRoot(sessionID: sessionID, profile: profile) else { throw DirectGitReadError.unprovenRoot }
        guard let review = try JSONSerialization.jsonObject(with: await directGitRead("/api/git/review/list", path: root,
            query: [URLQueryItem(name: "scope", value: "uncommitted")])) as? [String: Any],
              let rows = review["files"] as? [[String: Any]] else { throw DirectGitReadError.invalidResponse }
        let row = rows.first { ($0["path"] as? String) == path }
        guard let row else {
            return GitDiffResponse(diff: GitDiff(path: path, kind: staged ? "staged" : "unstaged",
                binary: nil, tooLarge: false, additions: nil, deletions: nil, diff: ""))
        }
        let status = try JSONSerialization.jsonObject(with: await directGitRead("/api/git/status", path: root)) as? [String: Any]
        let flags = (status?["files"] as? [[String: Any]])?.first { ($0["path"] as? String) == path }
        if (staged && row["staged"] as? Bool == false) || (!staged && flags?["unstaged"] as? Bool == false) {
            return GitDiffResponse(diff: GitDiff(path: path, kind: staged ? "staged" : "unstaged",
                binary: nil, tooLarge: false, additions: nil, deletions: nil, diff: ""))
        }
        // Stock's empty unstaged diff fallback can synthesize an all-add patch for
        // a clean tracked file. Beyond its metadata cap we cannot safely use it.
        if !staged, flags?["unstaged"] as? Bool != true {
            throw DirectGitReadError.unconfirmedUnstaged
        }
        let data = try await directGitRead("/api/git/review/diff", path: root, query: [
            URLQueryItem(name: "file", value: path), URLQueryItem(name: "scope", value: "uncommitted"),
            URLQueryItem(name: "staged", value: staged ? "true" : "false")])
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = envelope["diff"] as? String else { throw DirectGitReadError.invalidResponse }
        let tooLarge = text.utf8.count > 512 * 1_024
        let binary = text.split(separator: "\n").contains { $0.hasPrefix("Binary files ") || $0 == "GIT binary patch" }
        return GitDiffResponse(diff: GitDiff(path: path, kind: staged ? "staged" : "unstaged",
            binary: binary, tooLarge: tooLarge, additions: nil, deletions: nil, diff: tooLarge ? "" : text))
    }
}

// Workspace Git calls. Every call is scoped to a chat session via `session_id`; the
// server resolves the workspace path itself, mirroring `APIClient+Workspace.swift`.
extension APIClient {
    func gitInfo(sessionID: String) async throws -> GitInfoResponse {
        try await send(endpoint: .gitInfo(sessionID: sessionID), method: "GET")
    }

    func gitStatus(sessionID: String) async throws -> GitStatusResponse {
        try await send(endpoint: .gitStatus(sessionID: sessionID), method: "GET")
    }

    func gitBranches(sessionID: String) async throws -> GitBranchesResponse {
        try await send(endpoint: .gitBranches(sessionID: sessionID), method: "GET")
    }

    func gitDiff(sessionID: String, path: String, kind: String = "unstaged") async throws -> GitDiffResponse {
        try await send(
            endpoint: .gitDiff(sessionID: sessionID, path: path, kind: kind),
            method: "GET"
        )
    }

    func gitFetch(sessionID: String) async throws -> GitRemoteActionResponse {
        try await send(endpoint: .gitFetch, method: "POST", body: GitSessionRequest(sessionID: sessionID))
    }

    func gitPull(sessionID: String) async throws -> GitRemoteActionResponse {
        try await send(endpoint: .gitPull, method: "POST", body: GitSessionRequest(sessionID: sessionID))
    }

    func gitPush(sessionID: String) async throws -> GitRemoteActionResponse {
        try await send(endpoint: .gitPush, method: "POST", body: GitSessionRequest(sessionID: sessionID))
    }

    func gitCheckout(sessionID: String, target: GitCheckoutTarget) async throws -> GitCheckoutResponse {
        try await send(
            endpoint: .gitCheckout,
            method: "POST",
            body: GitCheckoutRequest(sessionID: sessionID, target: target, includesDirtyMode: true)
        )
    }

    func gitStashCheckout(sessionID: String, target: GitCheckoutTarget) async throws -> GitCheckoutResponse {
        try await send(
            endpoint: .gitStashCheckout,
            method: "POST",
            body: GitCheckoutRequest(sessionID: sessionID, target: target, includesDirtyMode: false)
        )
    }

    // MARK: - Commit flow (issue #315, Slice C)

    func gitStage(sessionID: String, paths: [String]) async throws -> GitMutationResponse {
        try await send(endpoint: .gitStage, method: "POST", body: GitPathsRequest(sessionID: sessionID, paths: paths))
    }

    func gitUnstage(sessionID: String, paths: [String]) async throws -> GitMutationResponse {
        try await send(endpoint: .gitUnstage, method: "POST", body: GitPathsRequest(sessionID: sessionID, paths: paths))
    }

    func gitDiscard(sessionID: String, paths: [String], deleteUntracked: Bool = false) async throws -> GitMutationResponse {
        try await send(
            endpoint: .gitDiscard,
            method: "POST",
            body: GitDiscardRequest(sessionID: sessionID, paths: paths, deleteUntracked: deleteUntracked)
        )
    }

    func gitCommit(sessionID: String, message: String) async throws -> GitCommitResponse {
        try await send(endpoint: .gitCommit, method: "POST", body: GitCommitRequest(sessionID: sessionID, message: message))
    }

    func gitCommitSelected(sessionID: String, message: String, paths: [String]) async throws -> GitCommitResponse {
        try await send(
            endpoint: .gitCommitSelected,
            method: "POST",
            body: GitCommitSelectedRequest(sessionID: sessionID, message: message, paths: paths)
        )
    }

    /// Generate a commit message from the staged diff. Not gated by the destructive flag.
    /// Generation runs an LLM server-side, so it gets a wider timeout than other calls.
    func gitCommitMessage(sessionID: String) async throws -> GitCommitMessageResponse {
        try await send(
            endpoint: .gitCommitMessage,
            method: "POST",
            body: GitSessionRequest(sessionID: sessionID),
            timeout: Self.commitMessageTimeout
        )
    }

    /// Generate a commit message from the selected paths' diff. Not gated by the destructive flag.
    func gitCommitMessageSelected(sessionID: String, paths: [String]) async throws -> GitCommitMessageResponse {
        try await send(
            endpoint: .gitCommitMessageSelected,
            method: "POST",
            body: GitPathsRequest(sessionID: sessionID, paths: paths),
            timeout: Self.commitMessageTimeout
        )
    }

    /// LLM commit-message generation can take far longer than the 60s session default,
    /// especially over a cold tunnel; allow up to two minutes before timing out.
    private static let commitMessageTimeout: TimeInterval = 120
}

private struct GitSessionRequest: Encodable {
    let sessionID: String
}

private struct GitPathsRequest: Encodable {
    let sessionID: String
    let paths: [String]
}

private struct GitDiscardRequest: Encodable {
    let sessionID: String
    let paths: [String]
    let deleteUntracked: Bool
}

private struct GitCommitRequest: Encodable {
    let sessionID: String
    let message: String
}

private struct GitCommitSelectedRequest: Encodable {
    let sessionID: String
    let message: String
    let paths: [String]
}

private struct GitCheckoutRequest: Encodable {
    let sessionID: String
    let ref: String
    let mode: String
    let newBranch: String?
    let track: Bool?
    let dirtyMode: String?

    init(sessionID: String, target: GitCheckoutTarget, includesDirtyMode: Bool) {
        self.sessionID = sessionID
        ref = target.ref
        // Creating a brand-new local branch must use the server's "new" mode. The
        // "local" mode only switches to an existing branch and ignores `new_branch`
        // entirely, so sending it for a create silently switches to `ref` instead
        // (a no-op when already on it). Remote checkouts keep "remote" — that mode
        // creates a tracking branch itself.
        mode = (target.mode == .local && target.newBranch != nil) ? "new" : target.mode.rawValue
        newBranch = target.newBranch
        track = target.track ? true : nil
        dirtyMode = includesDirtyMode ? "block" : nil
    }
}
