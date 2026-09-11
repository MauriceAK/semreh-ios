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

enum DirectGitWriteError: LocalizedError {
    case invalidPaths
    case validationChanged
    case incompleteStatus
    case dirtyWorktree
    case unavailableLocalBranch
    case detachedHead
    case partial(completed: Int, total: Int)
    case unknown(completed: Int, total: Int)

    var errorDescription: String? {
        switch self {
        case .invalidPaths: "Select explicit repository-relative files before changing Git state."
        case .validationChanged: "The Git selection changed before the request was sent. Refresh and review it again."
        case .incompleteStatus: "Hermes could not confirm the complete Git state. Refresh before trying again."
        case .dirtyWorktree: "Commit or discard local changes before switching branches."
        case .unavailableLocalBranch: "That local branch is no longer available. Refresh the branch list."
        case .detachedHead: "Push is unavailable while the repository has no checked-out branch."
        case let .partial(completed, total): "Git changed \(completed) of \(total) selected files before an error. Refresh before retrying."
        case let .unknown(completed, total): "The outcome is unknown after \(completed) of \(total) selected files were confirmed. Refresh before retrying."
        }
    }
}

private struct DirectGitOKResponse: Decodable { let ok: Bool? }
private struct DirectGitBranchSwitchResponse: Decodable { let branch: String? }

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
        return try await boundedSameOriginDirectData(
            for: request, maximumBytes: 8 * 1_024 * 1_024
        ).0
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

    private func directGitPost(_ route: String, body: [String: Any]) async throws -> DirectGitOKResponse {
        let bytes = try JSONSerialization.data(withJSONObject: body)
        return try decode(DirectGitOKResponse.self, from: await sendDirectData(
            path: route, method: "POST", encodedBody: bytes, classifyStructuredAuthExpiry: true
        ))
    }

    private func validatedDirectGitPaths(_ paths: [String]) throws -> [String] {
        guard !paths.isEmpty else { throw DirectGitWriteError.invalidPaths }
        var seen = Set<String>()
        let result = try paths.map { raw -> String in
            let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
            guard !raw.isEmpty, raw != ".", !raw.hasPrefix("/"), !raw.hasPrefix(":"),
                  !raw.contains("\0"), !raw.contains(where: { "*?[".contains($0) }),
                  !parts.contains(""), !parts.contains("."), !parts.contains(".."),
                  seen.insert(raw).inserted else { throw DirectGitWriteError.invalidPaths }
            return raw
        }
        return result
    }

    private func isAmbiguousDirectGitDispatchError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let apiError = error as? APIError {
            switch apiError {
            case .network, .decoding: return true
            case .http(let statusCode, _): return statusCode < 0 || statusCode >= 500
            case .invalidServerURL, .unauthorized: return false
            }
        }
        if let directError = error as? DirectHermesRequestError,
           case let .http(statusCode, _) = directError {
            return statusCode >= 500
        }
        return false
    }

    private func directGitFilesMutation(
        route: String,
        sessionID: String,
        profile: String,
        paths: [String],
        validateBeforeDispatch: @MainActor @Sendable () async -> Bool
    ) async throws -> GitMutationResponse {
        let files = try validatedDirectGitPaths(paths)
        guard let root = try await directGitRoot(sessionID: sessionID, profile: profile) else {
            throw DirectGitReadError.unprovenRoot
        }
        var completed = 0
        for file in files {
            guard await validateBeforeDispatch(), !Task.isCancelled else {
                if completed > 0 {
                    throw DirectGitWriteError.partial(completed: completed, total: files.count)
                }
                throw DirectGitWriteError.validationChanged
            }
            do {
                let response = try await directGitPost(route, body: ["path": root, "file": file])
                guard response.ok == true else {
                    throw DirectGitWriteError.unknown(completed: completed, total: files.count)
                }
                completed += 1
            } catch let error as DirectGitWriteError {
                throw error
            } catch {
                if isAmbiguousDirectGitDispatchError(error) {
                    throw DirectGitWriteError.unknown(completed: completed, total: files.count)
                }
                if completed > 0 { throw DirectGitWriteError.partial(completed: completed, total: files.count) }
                throw error
            }
        }
        return GitMutationResponse(ok: true, git: nil)
    }

    func directGitStage(
        sessionID: String, profile: String, paths: [String],
        validateBeforeDispatch: @MainActor @Sendable () async -> Bool
    ) async throws -> GitMutationResponse {
        try await directGitFilesMutation(route: "/api/git/review/stage", sessionID: sessionID,
            profile: profile, paths: paths, validateBeforeDispatch: validateBeforeDispatch)
    }

    func directGitUnstage(
        sessionID: String, profile: String, paths: [String],
        validateBeforeDispatch: @MainActor @Sendable () async -> Bool
    ) async throws -> GitMutationResponse {
        try await directGitFilesMutation(route: "/api/git/review/unstage", sessionID: sessionID,
            profile: profile, paths: paths, validateBeforeDispatch: validateBeforeDispatch)
    }

    func directGitPush(
        sessionID: String, profile: String,
        validateBeforeDispatch: @MainActor @Sendable () async -> Bool
    ) async throws -> GitRemoteActionResponse {
        guard let root = try await directGitRoot(sessionID: sessionID, profile: profile) else {
            throw DirectGitReadError.unprovenRoot
        }
        let status = try JSONSerialization.jsonObject(with: await directGitRead("/api/git/status", path: root)) as? [String: Any]
        guard status?["detached"] as? Bool == false,
              let branch = status?["branch"] as? String, !branch.isEmpty else {
            throw DirectGitWriteError.detachedHead
        }
        guard await validateBeforeDispatch(), !Task.isCancelled else { throw DirectGitWriteError.validationChanged }
        do {
            let response = try await directGitPost("/api/git/review/push", body: ["path": root])
            guard response.ok == true else { throw DirectGitWriteError.unknown(completed: 0, total: 1) }
        } catch {
            if isAmbiguousDirectGitDispatchError(error) {
                throw DirectGitWriteError.unknown(completed: 0, total: 1)
            }
            throw error
        }
        return GitRemoteActionResponse(ok: true, message: nil, status: nil)
    }

    func directGitSwitchLocalBranch(
        sessionID: String, profile: String, branch: String,
        validateBeforeDispatch: @MainActor @Sendable () async -> Bool
    ) async throws -> GitCheckoutResponse {
        let target = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./-"))
        guard !target.isEmpty, target == branch, !target.contains("\0"),
              target.unicodeScalars.allSatisfy(allowed.contains),
              !target.hasPrefix("-"), !target.hasPrefix("."), !target.hasPrefix("/"),
              !target.hasSuffix("-"), !target.hasSuffix("."), !target.hasSuffix("/"),
              !target.contains(".."), !target.contains("//"), !target.contains("--") else {
            throw DirectGitWriteError.unavailableLocalBranch
        }
        guard let root = try await directGitRoot(sessionID: sessionID, profile: profile) else {
            throw DirectGitReadError.unprovenRoot
        }
        async let statusBytes = directGitRead("/api/git/status", path: root)
        async let reviewBytes = directGitRead("/api/git/review/list", path: root,
            query: [URLQueryItem(name: "scope", value: "uncommitted")])
        async let branchBytes = directGitRead("/api/git/branches", path: root)
        let (rawStatus, rawReview, rawBranches) = try await (statusBytes, reviewBytes, branchBytes)
        guard let status = try JSONSerialization.jsonObject(with: rawStatus) as? [String: Any],
              let review = try JSONSerialization.jsonObject(with: rawReview) as? [String: Any],
              let files = review["files"] as? [[String: Any]],
              let changed = status["changed"] as? Int,
              Set(files.compactMap { $0["path"] as? String }).count == files.count,
              changed == files.count else {
            throw DirectGitWriteError.incompleteStatus
        }
        guard changed == 0 else { throw DirectGitWriteError.dirtyWorktree }
        guard let envelope = try JSONSerialization.jsonObject(with: rawBranches) as? [String: Any],
              let rows = envelope["branches"] as? [[String: Any]],
              rows.contains(where: { ($0["name"] as? String) == target && ($0["isRemote"] as? Bool) == false }) else {
            throw DirectGitWriteError.unavailableLocalBranch
        }
        guard await validateBeforeDispatch(), !Task.isCancelled else { throw DirectGitWriteError.validationChanged }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["path": root, "branch": target])
            let response = try decode(DirectGitBranchSwitchResponse.self, from: await sendDirectData(
                path: "/api/git/branch/switch", method: "POST", encodedBody: body,
                classifyStructuredAuthExpiry: true
            ))
            guard response.branch == target else { throw DirectGitWriteError.unknown(completed: 0, total: 1) }
        } catch {
            if isAmbiguousDirectGitDispatchError(error) {
                throw DirectGitWriteError.unknown(completed: 0, total: 1)
            }
            throw error
        }
        return GitCheckoutResponse(ok: true, message: nil, status: nil, git: nil, branches: nil,
            currentBranch: target, stashName: nil, stashed: nil, restoredStash: nil,
            restoreFailed: nil, restoreError: nil, restoreStash: nil)
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
