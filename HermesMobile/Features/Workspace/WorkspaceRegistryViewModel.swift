import Foundation
import Observation

/// Drives Semreh's device-local workspace bookmarks. A bookmark records a path
/// label for later selection; it does not verify, create, move, or delete files.
@MainActor
@Observable
final class WorkspaceRegistryViewModel {
    private(set) var workspaces: [WorkspaceRoot] = []
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?
    private(set) var didMutateRegistry = false
    private(set) var pendingRemoval: WorkspaceRoot?

    private let store: LocalOrganizerStore
    private let server: URL
    private let profile: String

    init(server: URL, profile: String, store: LocalOrganizerStore? = nil) {
        self.server = server
        self.profile = profile
        self.store = store ?? LocalOrganizerStore()
    }

    var rows: [WorkspaceRoot] { workspaces.filter { $0.path?.isEmpty == false } }

    func load() async {
        isLoading = true
        clearError()
        defer { isLoading = false }
        reload()
    }

    /// Local bookmarks are the only safe suggestions available without a
    /// stock gateway filesystem-completion contract.
    func loadSuggestions(prefix: String) async -> [String] {
        let value = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.compactMap(\.path).filter {
            value.isEmpty || $0.localizedCaseInsensitiveContains(value)
        }
    }

    @discardableResult
    func addWorkspace(path: String, name: String?) async -> Bool {
        await mutate {
            try store.addWorkspaceBookmark(path: path, name: name, server: server, profile: profile)
        }
    }

    @discardableResult
    func renameWorkspace(path: String, to name: String) async -> Bool {
        await mutate {
            try store.renameWorkspaceBookmark(path: path, name: name, server: server, profile: profile)
        }
    }

    func requestRemoval(of workspace: WorkspaceRoot) { pendingRemoval = workspace }
    func cancelPendingRemoval() { pendingRemoval = nil }

    @discardableResult
    func confirmRemoval(of workspace: WorkspaceRoot) async -> Bool {
        pendingRemoval = nil
        guard let path = workspace.path, !path.isEmpty else { return false }
        return await mutate {
            try store.removeWorkspaceBookmark(path: path, server: server, profile: profile)
        }
    }

    @discardableResult
    func moveWorkspaces(fromOffsets source: IndexSet, toOffset destination: Int) async -> Bool {
        var reordered = rows
        reordered.move(fromOffsets: source, toOffset: destination)
        guard reordered != rows else { return true }
        return await mutate {
            try store.reorderWorkspaceBookmarks(
                paths: reordered.compactMap(\.path), server: server, profile: profile
            )
        }
    }

    private func mutate(_ operation: () throws -> Void) async -> Bool {
        isMutating = true
        clearError()
        defer { isMutating = false }
        do {
            try operation()
            reload()
            guard lastError == nil else { return false }
            didMutateRegistry = true
            return true
        } catch {
            record(error)
            return false
        }
    }

    private func reload() {
        do {
            workspaces = try store.workspaceBookmarks(server: server, profile: profile).map {
                WorkspaceRoot(path: $0.path, name: $0.name)
            }
        } catch {
            record(error)
        }
    }

    private func clearError() {
        errorMessage = nil
        lastError = nil
    }

    private func record(_ error: Error) {
        lastError = error
        errorMessage = error.localizedDescription
    }
}
