import Foundation

/// Loads read-only git status for a chat session's workspace (issue #312, Slice A).
///
/// State is per session: each view model owns one `SessionSummary` and only ever sends that
/// session's `session_id` to the server, which resolves the workspace path (same rule as
/// `FileBrowserViewModel`). Two sessions on the same folder therefore see the same git state;
/// different folders see independent state.
@Observable
final class GitWorkspaceViewModel {
    private let session: SessionSummary
    private let apiClient: APIClient
    private var readGeneration = 0

    private(set) var status: GitStatus?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?
    private var hasLoaded = false

    init(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        self.session = session
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    /// True once a status has loaded and the workspace is not a git repository
    /// (`is_git == false`). Drives the non-blocking empty state.
    var isNonRepository: Bool {
        status?.isGit == false
    }

    /// True once a real git status has loaded (a repo with `is_git == true`).
    var hasRepository: Bool {
        status?.isGit == true
    }

    @MainActor
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    @MainActor
    func load() async {
        readGeneration += 1
        let generation = readGeneration
        defer { if generation == readGeneration { isLoading = false } }
        guard let sessionID = session.sessionId else {
            errorMessage = String(localized: "Session ID is missing.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil

        do {
            let response = try await apiClient.directGitStatus(sessionID: sessionID, profile: session.profile ?? "default")
            guard generation == readGeneration, !Task.isCancelled else { return }
            status = response.git
            hasLoaded = true
        } catch {
            guard generation == readGeneration, !Task.isCancelled else { return }
            lastError = error
            errorMessage = error.localizedDescription
        }

    }
}

/// Lightweight toolbar probe for whether a chat session's workspace is a git repository.
/// The toolbar stays hidden unless the server confirms `is_git == true`.
@Observable
final class GitWorkspaceAvailabilityViewModel {
    private let apiClient: APIClient
    private var boundSessionID: String?
    private var boundProfile: String
    private var readGeneration = 0
    private var branchGeneration = 0

    private(set) var hasRepository = false
    private(set) var isLoading = false
    private(set) var isStatusLoading = false
    private(set) var lastError: Error?
    private(set) var gitInfo: GitInfo?
    private(set) var status: GitStatus?
    private(set) var statusError: Error?
    private(set) var branches: GitBranches?
    private(set) var branchesError: Error?
    private(set) var isLoadingBranches = false
    private(set) var isSwitchingBranch = false
    private(set) var runningRemoteAction: GitRemoteAction?
    private(set) var commitPhase: GitCommitPhase?
    private(set) var actionErrorMessage: String?
    private(set) var lastActionMessage: String?
    private var hasLoaded = false
    private var pushOutcomeUnknown = false

    #if DEBUG
    func seedStatusForTesting(_ value: GitStatus) {
        status = value
        hasRepository = value.isGit == true
    }

    var bindingForTesting: (sessionID: String?, profile: String) {
        (boundSessionID, boundProfile)
    }
    #endif

    init(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        self.apiClient = apiClient ?? APIClient(baseURL: server)
        self.boundSessionID = session.sessionId
        self.boundProfile = session.profile ?? "default"
    }

    func rebindToCanonicalSession(sessionID: String, profile: String) {
        guard !sessionID.isEmpty, !profile.isEmpty,
              sessionID != boundSessionID || profile != boundProfile else { return }
        readGeneration &+= 1
        branchGeneration &+= 1
        boundSessionID = sessionID
        boundProfile = profile
        hasLoaded = false
        isLoading = false
        isStatusLoading = false
        isLoadingBranches = false
        status = nil
        gitInfo = nil
        branches = nil
        hasRepository = false
        statusError = nil
        branchesError = nil
        lastError = nil
        actionErrorMessage = nil
        lastActionMessage = nil
    }

    /// Minimal identity projection for Git child views. Workspace/root metadata
    /// is resolved from Hermes reads for this exact durable session and profile.
    var requestSession: SessionSummary {
        SessionSummary(sessionId: boundSessionID, profile: boundProfile)
    }

    @MainActor
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    @MainActor
    func load() async {
        readGeneration += 1
        let generation = readGeneration
        defer { if generation == readGeneration { isLoading = false; isStatusLoading = false } }
        guard let sessionID = boundSessionID else {
            hasRepository = false
            lastError = nil
            return
        }

        isLoading = true
        isStatusLoading = true
        do {
            let response = try await apiClient.directGitStatus(sessionID: sessionID, profile: boundProfile)
            guard generation == readGeneration, !Task.isCancelled else { return }
            status = response.git
            gitInfo = response.git.map { GitInfo(branch: $0.branch, dirty: $0.totals?.changed,
                modified: nil, untracked: $0.totals?.untracked, ahead: $0.ahead, behind: $0.behind, isGit: $0.isGit) }
            hasRepository = response.git?.isGit == true
            lastError = nil
            statusError = nil
            pushOutcomeUnknown = false
            hasLoaded = true
            isStatusLoading = false

            if hasRepository {
                await loadBranches()
            } else {
                status = nil
                statusError = nil
                branches = nil
                branchesError = nil
                hasLoaded = true
            }
        } catch {
            guard generation == readGeneration, !Task.isCancelled else { return }
            hasRepository = false
            gitInfo = nil
            status = nil
            statusError = error
            lastError = error
        }

    }

    var currentBranchName: String {
        let value = branches?.current ?? gitInfo?.branch ?? status?.branch
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? String(localized: "Branch") : trimmed
    }

    var isRunningGitAction: Bool {
        isSwitchingBranch || runningRemoteAction != nil || commitPhase != nil
    }

    /// True while a quick-commit pipeline (menu row or inline turn button) is running.
    var isCommitting: Bool { commitPhase != nil }

    /// True when there is at least one non-ignored changed file to commit.
    var hasCommittableChanges: Bool {
        !(status?.trackedFiles.isEmpty ?? true)
    }

    @MainActor
    func loadBranches() async {
        let generation = readGeneration
        guard let sessionID = boundSessionID, hasRepository else { return }
        branchGeneration += 1
        let branchRequest = branchGeneration
        isLoadingBranches = true
        defer { if branchRequest == branchGeneration { isLoadingBranches = false } }
        branchesError = nil
        do {
            let refreshed = try await apiClient.directGitBranches(sessionID: sessionID, profile: boundProfile).branches
            guard generation == readGeneration, branchRequest == branchGeneration, !Task.isCancelled else { return }
            branches = refreshed
        } catch {
            guard generation == readGeneration, branchRequest == branchGeneration, !Task.isCancelled else { return }
            branchesError = error
        }
    }

    @MainActor
    func checkout(_ target: GitCheckoutTarget, stashingChanges: Bool = false) async -> GitCheckoutOutcome {
        guard let sessionID = boundSessionID, !isSwitchingBranch else { return .failure }
        guard !stashingChanges, target.mode == .local, target.newBranch == nil, !target.track else {
            actionErrorMessage = String(localized: "This branch action is not available with the connected Hermes version.")
            return .failure
        }
        readGeneration += 1
        let generation = readGeneration
        isSwitchingBranch = true
        isLoading = false
        isStatusLoading = false
        actionErrorMessage = nil
        defer { isSwitchingBranch = false }

        do {
            let response = try await apiClient.directGitSwitchLocalBranch(
                sessionID: sessionID,
                profile: boundProfile,
                branch: target.ref,
                validateBeforeDispatch: { [weak self] in
                    guard let self else { return false }
                    return self.readGeneration == generation && !Task.isCancelled
                }
            )
            guard response.ok == true, generation == readGeneration, !Task.isCancelled else { return .failure }
            await refreshGitInfo()
            // Reload the branch list so the picker + composer pill reflect the new
            // current branch (a freshly created branch isn't in the cached list yet).
            await loadBranches()
            guard generation == readGeneration, !Task.isCancelled else { return .failure }
            lastActionMessage = String(localized: "Branch switched")
            return .success
        } catch {
            guard generation == readGeneration, !Task.isCancelled else { return .failure }
            actionErrorMessage = friendlyMessage(for: error)
            return .failure
        }
    }

    @MainActor
    func performRemoteAction(_ action: GitRemoteAction) async -> Bool {
        guard let sessionID = boundSessionID, runningRemoteAction == nil else { return false }
        if action == .push, pushOutcomeUnknown {
            actionErrorMessage = String(localized: "The previous push outcome is unknown. Refresh Git status before trying again.")
            return false
        }
        readGeneration += 1
        runningRemoteAction = action
        isLoading = false
        isStatusLoading = false
        actionErrorMessage = nil
        defer { runningRemoteAction = nil }

        guard action == .push else {
            actionErrorMessage = String(localized: "Fetch and pull are not available with the connected Hermes version.")
            return false
        }
        let generation = readGeneration

        do {
            let response = try await apiClient.directGitPush(
                sessionID: sessionID,
                profile: boundProfile,
                validateBeforeDispatch: { [weak self] in
                    guard let self else { return false }
                    return self.readGeneration == generation && !Task.isCancelled
                }
            )
            guard generation == readGeneration, !Task.isCancelled else { return false }
            status = response.status ?? status
            lastActionMessage = response.message
            await loadBranches()
            await refreshGitInfo()
            guard generation == readGeneration, !Task.isCancelled else { return false }
            return response.ok != false
        } catch {
            guard generation == readGeneration, !Task.isCancelled else { return false }
            if case .some(.unknown) = error as? DirectGitWriteError { pushOutcomeUnknown = true }
            actionErrorMessage = friendlyMessage(for: error)
            return false
        }
    }

    /// Compatibility refusal while the unmatched quick-commit UI is retired.
    @MainActor
    func quickCommit(push: Bool, onPhase: ((GitCommitPhase) -> Void)? = nil) async -> GitQuickCommitOutcome {
        guard boundSessionID != nil, commitPhase == nil else { return .failure }
        actionErrorMessage = String(localized: "Quick commit is not available with the connected Hermes version.")
        return .failure
    }

    /// Re-fetch info, status and branches after the advanced staging sheet mutates the
    /// working tree, so the toolbar badge and Changes row stay in sync.
    @MainActor
    func refreshAfterExternalMutation() async {
        readGeneration += 1
        let generation = readGeneration
        isLoading = false
        isStatusLoading = false
        guard let sessionID = boundSessionID else { return }
        do {
            guard let refreshed = try await apiClient.directGitStatus(sessionID: sessionID, profile: boundProfile).git else {
                throw DirectGitReadError.invalidResponse
            }
            guard generation == readGeneration, !Task.isCancelled else { return }
            status = refreshed
            gitInfo = GitInfo(branch: refreshed.branch, dirty: refreshed.totals?.changed,
                modified: nil, untracked: refreshed.totals?.untracked, ahead: refreshed.ahead,
                behind: refreshed.behind, isGit: refreshed.isGit)
            hasRepository = refreshed.isGit == true
            statusError = nil
            pushOutcomeUnknown = false
            lastError = nil
        } catch {
            guard generation == readGeneration, !Task.isCancelled else { return }
            status = nil
            statusError = error
            lastError = error
            hasLoaded = false
            return
        }
        guard generation == readGeneration, !Task.isCancelled else { return }
        await loadBranches()
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    @MainActor
    private func refreshGitInfo() async {
        let generation = readGeneration
        guard let sessionID = boundSessionID else { return }
        if let response = try? await apiClient.directGitInfo(sessionID: sessionID, profile: boundProfile) {
            guard generation == readGeneration, !Task.isCancelled else { return }
            gitInfo = response.git
            hasRepository = response.git?.isGit == true
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        gitWriteFriendlyMessage(for: error)
    }
}

/// Maps server git errors to short, friendly copy shared by every git write surface
/// (branch switching, remote sync, and the commit flow). Unknown codes fall back to the
/// server's own message, then the generic localized description.
func gitWriteFriendlyMessage(for error: Error) -> String {
    guard let apiError = error as? APIError else { return error.localizedDescription }
    switch apiError.serverCode {
    case "destructive_git_disabled":
        return String(localized: "Writes disabled on server. Enable HERMES_WEBUI_WORKSPACE_GIT_DESTRUCTIVE=1 on the server to use this.")
    case "active_stream":
        return String(localized: "Wait for the active response to finish before changing this repository.")
    default:
        return apiError.serverMessage ?? apiError.localizedDescription
    }
}

enum GitRemoteAction: String, Equatable, Identifiable {
    case fetch
    case pull
    case push

    var id: String { rawValue }

    var progressTitle: String {
        switch self {
        case .fetch: String(localized: "Fetching...")
        case .pull: String(localized: "Pulling...")
        case .push: String(localized: "Pushing...")
        }
    }

    var successTitle: String {
        switch self {
        case .fetch: String(localized: "Fetch complete")
        case .pull: String(localized: "Pull complete")
        case .push: String(localized: "Push complete")
        }
    }
}

enum GitCheckoutOutcome: Equatable {
    case success
    case requiresStash
    case failure
}

/// The visible phases of the one-tap commit pipeline (issue #315, Slice C). Staging
/// happens under `generatingMessage` so the toast shows the same sequence the spec
/// describes: "Generating commit message…" → "Committing…" → "Pushing…".
enum GitCommitPhase: Equatable {
    case generatingMessage
    case committing
    case pushing

    var progressTitle: String {
        switch self {
        case .generatingMessage: String(localized: "Generating commit message...")
        case .committing: String(localized: "Committing...")
        case .pushing: String(localized: "Pushing...")
        }
    }

    /// Short label used inside the inline turn-end button while running.
    var inlineTitle: String {
        switch self {
        case .generatingMessage, .committing: String(localized: "Committing...")
        case .pushing: String(localized: "Pushing...")
        }
    }
}

struct GitQuickCommitResult: Equatable {
    let shortSHA: String?
    let branch: String?
    let message: String?
    let truncatedMessage: Bool
    let didPush: Bool
    /// Set when the commit succeeded but a requested push failed; carries the friendly
    /// push error so the caller can report partial success instead of a clean toast.
    var pushFailureMessage: String? = nil
}

enum GitQuickCommitOutcome: Equatable {
    case success(GitQuickCommitResult)
    case nothingToCommit
    /// The server truncated the status list (>500 changed files), so the client only knows
    /// the first 500. Quick-commit refuses rather than silently committing a partial set.
    case tooManyChanges
    case failure
}

struct GitWriteAvailability: Equatable {
    let isStreaming: Bool
    let isViewingCachedData: Bool

    var writesDisabled: Bool { isStreaming || isViewingCachedData }
    var fetchDisabled: Bool { isViewingCachedData }
}

enum GitToolbarStatusDot: Equatable {
    case gray
}

/// Pure presentation state for the toolbar menu, kept outside UIKit so its edge cases are testable.
struct GitToolbarPresentation: Equatable {
    let hasRepository: Bool
    let isLoading: Bool
    let info: GitInfo?
    let status: GitStatus?
    let statusFailed: Bool

    var statusDot: GitToolbarStatusDot? {
        guard hasRepository else { return nil }
        if (info?.dirty ?? 0) > 0 || (info?.behind ?? 0) > 0 { return .gray }
        return nil
    }

    var accessibilityValue: String {
        guard hasRepository else { return String(localized: "Repository status unavailable") }
        let dirty = (info?.dirty ?? 0) > 0
        let ahead = (info?.ahead ?? 0) > 0
        let behind = (info?.behind ?? 0) > 0
        if dirty && behind { return String(localized: "Local changes exist and remote branch moved ahead") }
        if dirty { return String(localized: "Local repository has uncommitted changes") }
        if ahead && behind { return String(localized: "Local and remote branches diverged") }
        if behind { return String(localized: "Remote branch ahead of local branch") }
        if ahead { return String(localized: "Local branch ahead of remote") }
        return String(localized: "Repository up to date")
    }

    var changesTitle: String {
        if statusFailed { return String(localized: "Changes unavailable") }
        guard let status else { return String(localized: "No changes") }
        guard status.changedCount > 0 else { return String(localized: "No changes") }
        return "+\(status.totalAdditions) −\(status.totalDeletions)  \(status.changedCount)"
    }

    var changesAreEnabled: Bool { !isLoading && (status != nil || statusFailed) }
}

/// Which mutating operation the advanced staging sheet is currently running, used to
/// disable controls and show the right inline spinner.
enum GitCommitOperation: Equatable {
    case staging
    case unstaging
    case discarding
    case committing
    case suggesting
}

/// View model for the advanced staging & commit sheet (issue #315, Slice C).
///
/// Self-contained per session: it loads its own status so the sheet always reflects the
/// current working tree, and owns the file selection, commit-message field, and the
/// stage / unstage / discard / suggest / commit operations.
@MainActor
@Observable
final class GitCommitViewModel {
    private let session: SessionSummary
    private let apiClient: APIClient
    private var readGeneration = 0

    private(set) var status: GitStatus?
    private(set) var isLoading = false
    private(set) var loadErrorMessage: String?
    private(set) var lastError: Error?

    /// Paths the user has checked for batch stage/unstage/discard and "Commit selected".
    private(set) var selectedPaths: Set<String> = []

    /// The commit-message field (two-way bound from the sheet).
    var message: String = ""
    private(set) var messageWasTruncated = false
    private(set) var busyOperation: GitCommitOperation?
    private(set) var actionErrorMessage: String?
    private(set) var lastCommitSHA: String?
    /// Bumps after every successful commit so the host can refresh the toolbar badge.
    private(set) var committedRevision = 0

    init(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        self.session = session
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    var trackedFiles: [GitFile] { status?.trackedFiles ?? [] }
    var stagedFiles: [GitFile] { trackedFiles.filter { $0.staged == true } }
    var hasChanges: Bool { !trackedFiles.isEmpty }
    var hasStagedChanges: Bool { !stagedFiles.isEmpty }
    var hasSelection: Bool { !selectedPaths.isEmpty }
    var isBusy: Bool { busyOperation != nil }
    var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    func isSelected(_ file: GitFile) -> Bool { selectedPaths.contains(file.id) }

    func toggleSelection(_ file: GitFile) {
        if selectedPaths.contains(file.id) {
            selectedPaths.remove(file.id)
        } else {
            selectedPaths.insert(file.id)
        }
    }

    func clearSelection() { selectedPaths.removeAll() }

    func clearActionError() { actionErrorMessage = nil }

    /// Server paths for the current selection, or all changed files when nothing is
    /// selected (the "operate on everything" default for the batch buttons).
    private var targetPaths: [String] {
        let files = hasSelection ? trackedFiles.filter { selectedPaths.contains($0.id) } : trackedFiles
        return files.compactMap(serverPath)
    }

    private func serverPath(_ file: GitFile) -> String? {
        let path = file.path ?? file.workspacePath
        return (path?.isEmpty == false) ? path : nil
    }

    func load() async {
        readGeneration += 1
        let generation = readGeneration
        defer { if generation == readGeneration { isLoading = false } }
        guard let sessionID = session.sessionId else {
            loadErrorMessage = String(localized: "Session ID is missing.")
            return
        }
        isLoading = true
        loadErrorMessage = nil
        lastError = nil
        do {
            let refreshed = try await apiClient.directGitStatus(sessionID: sessionID, profile: session.profile ?? "default").git
            guard generation == readGeneration, !Task.isCancelled else { return }
            status = refreshed
            pruneSelectionToCurrentFiles()
        } catch {
            guard generation == readGeneration, !Task.isCancelled else { return }
            lastError = error
            loadErrorMessage = error.localizedDescription
        }
    }

    func stageSelectedOrAll() async {
        await mutate(.staging, paths: targetPaths)
    }

    func unstageSelectedOrAll() async {
        await mutate(.unstaging, paths: targetPaths)
    }

    func discardSelectedOrAll(deleteUntracked: Bool) async {
        actionErrorMessage = String(localized: "Discard is not available with the connected Hermes version.")
    }

    /// Compatibility refusal while generated-message controls are retired.
    func suggestMessage() async {
        actionErrorMessage = String(localized: "Generated commit messages are not available with the connected Hermes version.")
    }

    /// Compatibility refusal while dedicated commit controls are retired.
    func commit(push: Bool) async -> Bool {
        actionErrorMessage = String(localized: "Commit is not available with the connected Hermes version.")
        return false
    }

    /// Compatibility refusal while dedicated selected-commit controls are retired.
    func commitSelected(push: Bool) async -> Bool {
        actionErrorMessage = String(localized: "Commit is not available with the connected Hermes version.")
        return false
    }

    private func mutate(
        _ operation: GitCommitOperation,
        paths: [String]
    ) async {
        guard let sessionID = session.sessionId, busyOperation == nil, !paths.isEmpty else { return }
        readGeneration += 1
        isLoading = false
        busyOperation = operation
        actionErrorMessage = nil
        defer { busyOperation = nil }
        let generation = readGeneration
        do {
            let profile = session.profile ?? "default"
            switch operation {
            case .staging:
                _ = try await apiClient.directGitStage(
                    sessionID: sessionID, profile: profile, paths: paths,
                    validateBeforeDispatch: { [weak self] in
                        guard let self else { return false }
                        return self.readGeneration == generation && self.targetPaths == paths
                            && !Task.isCancelled
                    }
                )
            case .unstaging:
                _ = try await apiClient.directGitUnstage(
                    sessionID: sessionID, profile: profile, paths: paths,
                    validateBeforeDispatch: { [weak self] in
                        guard let self else { return false }
                        return self.readGeneration == generation && self.targetPaths == paths
                            && !Task.isCancelled
                    }
                )
            default:
                return
            }
            guard generation == readGeneration, !Task.isCancelled else { return }
            await load()
            pruneSelectionToCurrentFiles()
        } catch {
            guard generation == readGeneration, !Task.isCancelled else { return }
            actionErrorMessage = gitWriteFriendlyMessage(for: error)
        }
    }

    private func pruneSelectionToCurrentFiles() {
        let valid = Set(trackedFiles.map(\.id))
        selectedPaths.formIntersection(valid)
    }
}
