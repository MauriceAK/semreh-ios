import Foundation
import Observation
import SwiftData
import SwiftUI

extension SessionListViewModel {
    func loadProjects() async {
        isLoadingProjects = true
        actionErrorMessage = nil
        lastError = nil
        defer { isLoadingProjects = false }

        do {
            projects = try organizerStore.groups(
                server: server,
                profile: Self.nonEmpty(activeProfileName) ?? "default"
            )
        } catch {
            guard !isCancellationError(error) else { return }

            lastError = error
            actionErrorMessage = error.localizedDescription
        }
    }

    func move(_ session: SessionSummary, to projectID: String?, modelContext: ModelContext? = nil) async {
        guard !isSearchOnlySession(session) else {
            actionErrorMessage = String(localized: "This search result cannot be moved yet.")
            return
        }
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return
        }

        guard beginSessionMutation(sessionId) else { return }
        defer { endSessionMutation(sessionId) }

        isMovingSession = true
        defer { isMovingSession = false }

        do {
            let profile = Self.nonEmpty(session.profile) ?? Self.nonEmpty(activeProfileName) ?? "default"
            try organizerStore.assignSession(sessionId, toGroup: projectID, server: server, profile: profile)
            sessions = sessions.map { candidate in
                candidate.sessionId == sessionId
                    && (Self.nonEmpty(candidate.profile) ?? profile) == profile
                    ? applyingLocalGroup(candidate, groupID: projectID) : candidate
            }
            if let modelContext { try? CacheStore.cacheSessions(sessions, serverURL: server, in: modelContext) }
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
        }
    }

    func createProject(
        named rawName: String,
        color: String,
        moving session: SessionSummary,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        guard !isSearchOnlySession(session) else {
            actionErrorMessage = String(localized: "This search result cannot be moved yet.")
            return false
        }
        guard let sessionId = session.sessionId else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isCreatingProject = true
        isMovingSession = true
        defer {
            isCreatingProject = false
            isMovingSession = false
        }

        do {
            let profile = Self.nonEmpty(session.profile) ?? Self.nonEmpty(activeProfileName) ?? "default"
            let project = try organizerStore.createGroup(name: name, color: color, server: server, profile: profile)
            guard let projectID = project.projectId else { throw LocalOrganizerStoreError.invalidValue }
            upsertProject(project)
            do {
                try organizerStore.assignSession(sessionId, toGroup: projectID, server: server, profile: profile)
            } catch {
                try? organizerStore.deleteGroup(id: projectID, server: server, profile: profile)
                projects.removeAll { $0.projectId == projectID }
                throw error
            }
            sessions = sessions.map {
                $0.sessionId == sessionId && (Self.nonEmpty($0.profile) ?? profile) == profile
                    ? applyingLocalGroup($0, groupID: projectID) : $0
            }
            if let modelContext { try? CacheStore.cacheSessions(sessions, serverURL: server, in: modelContext) }
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates a new project without moving any session into it.
    ///
    /// Mirrors ``createProject(named:color:moving:modelContext:)`` but skips the
    /// `sessionMutator.move(...)` step, so the Projects sidebar's standalone
    /// "Add project" button can make an empty, unassigned project.
    func createEmptyProject(
        named rawName: String,
        color: String,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isCreatingProject = true
        defer { isCreatingProject = false }

        do {
            let profile = Self.nonEmpty(activeProfileName) ?? "default"
            let project = try organizerStore.createGroup(name: name, color: color, server: server, profile: profile)
            upsertProject(project)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ project: ProjectSummary, modelContext: ModelContext? = nil) async -> Bool {
        guard let projectID = project.projectId, !projectID.isEmpty else {
            actionErrorMessage = String(localized: "The server did not provide a project ID.")
            return false
        }

        isDeletingProject = true
        actionErrorMessage = nil
        lastError = nil
        defer { isDeletingProject = false }

        do {
            let profile = Self.nonEmpty(activeProfileName) ?? "default"
            try organizerStore.deleteGroup(id: projectID, server: server, profile: profile)
            projects.removeAll { $0.projectId == projectID }
            sessions = sessions.map {
                $0.projectId == projectID && (Self.nonEmpty($0.profile) ?? profile) == profile
                    ? applyingLocalGroup($0, groupID: nil) : $0
            }
            if let modelContext { try? CacheStore.cacheSessions(sessions, serverURL: server, in: modelContext) }
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func rename(_ project: ProjectSummary, named rawName: String, color: String?) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        guard let projectID = project.projectId, !projectID.isEmpty else {
            actionErrorMessage = String(localized: "The server did not provide a project ID.")
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isRenamingProject = true
        defer { isRenamingProject = false }

        do {
            let profile = Self.nonEmpty(activeProfileName) ?? "default"
            let renamedProject = try organizerStore.renameGroup(
                id: projectID, name: name, color: color, server: server, profile: profile
            )
            upsertProject(renamedProject)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Opens a local draft. Backend creation is deferred until the first prompt
    /// is submitted, so opening New Chat performs no workspace/session request.
    func createSession(modelContext: ModelContext? = nil, profile: String? = nil) async -> SessionSummary? {
        isCreatingSession = true
        actionErrorMessage = nil
        lastError = nil
        defer { isCreatingSession = false }

        _ = modelContext // Local drafts are deliberately neither cached nor persisted.
        localDraftSequence &+= 1
        let timestamp = Date().timeIntervalSince1970
            + (Double(localDraftSequence) * 0.000001)
        return SessionSummary(
            sessionId: nil,
            title: "New Chat",
            createdAt: timestamp,
            updatedAt: timestamp,
            profile: Self.nonEmpty(profile) ?? Self.nonEmpty(activeProfileName) ?? "default"
        )
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    /// Drops any empty Untitled placeholders still held in memory. Used when
    /// returning from the pending new-chat flow so stale rows cannot flash during
    /// the navigation pop animation.
    func removeEmptySidebarPlaceholders() {
        let filtered = sessions.filter(\.shouldAppearInSessionList)
        guard filtered.count != sessions.count else { return }
        sessions = filtered
    }
}
