import Foundation

enum LocalOrganizerStoreError: LocalizedError, Equatable {
    case unavailable
    case invalidValue

    var errorDescription: String? {
        switch self {
        case .unavailable: "Local organization data is unavailable and was left unchanged."
        case .invalidValue: "The local organizer value is invalid."
        }
    }
}

struct LocalWorkspaceBookmark: Codable, Equatable, Identifiable {
    let path: String
    var name: String?
    var id: String { path }
}

struct LocalOrganizerSnapshot: Equatable {
    let groups: [ProjectSummary]
    let sessionAssignments: [String: String]
    let workspaceBookmarks: [LocalWorkspaceBookmark]
}

/// Device-local presentation metadata. It never mutates Hermes sessions,
/// workspaces, paths, or files, and is deliberately separate from disposable caches.
@MainActor
struct LocalOrganizerStore {
    private struct Envelope: Codable {
        var version: Int
        var scopes: [String: Scope]
    }

    private struct Scope: Codable {
        var groups: [Group] = []
        var sessionAssignments: [String: String] = [:]
        var workspaceBookmarks: [LocalWorkspaceBookmark] = []
    }

    private struct Group: Codable {
        let id: String
        var name: String
        var color: String?
    }

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "localOrganizer.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func snapshot(server: URL, profile: String) throws -> LocalOrganizerSnapshot {
        let scope = try read().scopes[scopeKey(server: server, profile: profile)] ?? Scope()
        return LocalOrganizerSnapshot(
            groups: scope.groups.map { ProjectSummary(projectId: $0.id, name: $0.name, color: $0.color, createdAt: nil) },
            sessionAssignments: scope.sessionAssignments,
            workspaceBookmarks: scope.workspaceBookmarks
        )
    }

    func groups(server: URL, profile: String) throws -> [ProjectSummary] {
        try snapshot(server: server, profile: profile).groups
    }

    func createGroup(name rawName: String, color: String?, server: URL, profile: String) throws -> ProjectSummary {
        let name = try nonEmpty(rawName)
        let group = Group(id: "local-group-\(UUID().uuidString.lowercased())", name: name, color: normalized(color))
        try mutate(server: server, profile: profile) { $0.groups.append(group) }
        return ProjectSummary(projectId: group.id, name: group.name, color: group.color, createdAt: nil)
    }

    func renameGroup(id: String, name rawName: String, color: String?, server: URL, profile: String) throws -> ProjectSummary {
        let name = try nonEmpty(rawName)
        var result: Group?
        try mutate(server: server, profile: profile) { scope in
            guard let index = scope.groups.firstIndex(where: { $0.id == id }) else { throw LocalOrganizerStoreError.invalidValue }
            scope.groups[index].name = name
            scope.groups[index].color = normalized(color)
            result = scope.groups[index]
        }
        guard let result else { throw LocalOrganizerStoreError.invalidValue }
        return ProjectSummary(projectId: result.id, name: result.name, color: result.color, createdAt: nil)
    }

    func deleteGroup(id: String, server: URL, profile: String) throws {
        try mutate(server: server, profile: profile) { scope in
            guard scope.groups.contains(where: { $0.id == id }) else { throw LocalOrganizerStoreError.invalidValue }
            scope.groups.removeAll { $0.id == id }
            scope.sessionAssignments = scope.sessionAssignments.filter { $0.value != id }
        }
    }

    func assignSession(_ sessionID: String, toGroup groupID: String?, server: URL, profile: String) throws {
        let sessionID = try nonEmpty(sessionID)
        try mutate(server: server, profile: profile) { scope in
            if let groupID {
                guard scope.groups.contains(where: { $0.id == groupID }) else { throw LocalOrganizerStoreError.invalidValue }
                scope.sessionAssignments[sessionID] = groupID
            } else {
                scope.sessionAssignments.removeValue(forKey: sessionID)
            }
        }
    }

    func groupID(forSession sessionID: String, server: URL, profile: String) throws -> String? {
        try snapshot(server: server, profile: profile).sessionAssignments[sessionID]
    }

    func transferSessionAssignment(from oldID: String, to newID: String, server: URL, profile: String) throws {
        guard oldID != newID else { return }
        try mutate(server: server, profile: profile) { scope in
            guard let group = scope.sessionAssignments[oldID] else { return }
            if scope.sessionAssignments[newID] == nil { scope.sessionAssignments[newID] = group }
        }
    }

    func workspaceBookmarks(server: URL, profile: String) throws -> [LocalWorkspaceBookmark] {
        try snapshot(server: server, profile: profile).workspaceBookmarks
    }

    func addWorkspaceBookmark(path rawPath: String, name: String?, server: URL, profile: String) throws {
        let path = try nonEmpty(rawPath)
        try mutate(server: server, profile: profile) { scope in
            guard !scope.workspaceBookmarks.contains(where: { $0.path == path }) else { throw LocalOrganizerStoreError.invalidValue }
            scope.workspaceBookmarks.append(.init(path: path, name: normalized(name)))
        }
    }

    func renameWorkspaceBookmark(path: String, name: String, server: URL, profile: String) throws {
        let name = try nonEmpty(name)
        try mutate(server: server, profile: profile) { scope in
            guard let index = scope.workspaceBookmarks.firstIndex(where: { $0.path == path }) else { throw LocalOrganizerStoreError.invalidValue }
            scope.workspaceBookmarks[index].name = name
        }
    }

    func removeWorkspaceBookmark(path: String, server: URL, profile: String) throws {
        try mutate(server: server, profile: profile) { scope in
            guard scope.workspaceBookmarks.contains(where: { $0.path == path }) else { throw LocalOrganizerStoreError.invalidValue }
            scope.workspaceBookmarks.removeAll { $0.path == path }
        }
    }

    func reorderWorkspaceBookmarks(paths: [String], server: URL, profile: String) throws {
        try mutate(server: server, profile: profile) { scope in
            let requested = paths.compactMap { path in scope.workspaceBookmarks.first { $0.path == path } }
            guard Set(requested.map(\.path)).count == paths.count else { throw LocalOrganizerStoreError.invalidValue }
            let requestedPaths = Set(paths)
            scope.workspaceBookmarks = requested + scope.workspaceBookmarks.filter { !requestedPaths.contains($0.path) }
        }
    }

    private func mutate(server: URL, profile: String, _ body: (inout Scope) throws -> Void) throws {
        var envelope = try read()
        let key = scopeKey(server: server, profile: profile)
        var scope = envelope.scopes[key] ?? Scope()
        try body(&scope)
        envelope.scopes[key] = scope
        let data = try JSONEncoder().encode(envelope)
        defaults.set(data, forKey: storageKey)
    }

    private func read() throws -> Envelope {
        guard defaults.object(forKey: storageKey) != nil else { return Envelope(version: 1, scopes: [:]) }
        guard let data = defaults.data(forKey: storageKey) else { throw LocalOrganizerStoreError.unavailable }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1 else {
            throw LocalOrganizerStoreError.unavailable
        }
        return envelope
    }

    private func scopeKey(server: URL, profile: String) -> String {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        components?.user = nil
        components?.password = nil
        if (components?.scheme == "https" && components?.port == 443)
            || (components?.scheme == "http" && components?.port == 80) {
            components?.port = nil
        }
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        var origin = components?.url?.absoluteString ?? server.absoluteString
        while origin.last == "/" { origin.removeLast() }
        let profile = normalized(profile) ?? "default"
        let tuple = try? JSONEncoder().encode([origin, profile])
        return tuple?.base64EncodedString() ?? ""
    }

    private func nonEmpty(_ value: String) throws -> String {
        guard let value = normalized(value) else { throw LocalOrganizerStoreError.invalidValue }
        return value
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
