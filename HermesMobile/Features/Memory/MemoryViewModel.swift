import Foundation
import Observation

@MainActor
@Observable
final class MemoryViewModel {
    private(set) var memoryText: String?
    private(set) var userText: String?
    private(set) var soulText: String?
    private(set) var memoryMtime: Date?
    private(set) var userMtime: Date?
    private(set) var soulMtime: Date?
    private(set) var projectContextText: String?
    private(set) var projectContextName: String?
    private(set) var projectContextWorkspace: String?
    private(set) var projectContextMtime: Date?
    private(set) var isProjectContextShadowed = false
    private(set) var isExternalNotesEnabled: Bool?
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var lastError: Error?
    private(set) var scope: DirectMemoryScope?
    private(set) var sectionErrors: [String: String] = [:]
    private(set) var hasUnconfirmedSave = false
    let profile: String
    private var documents: [DirectMemoryDocument] = []
    private var editingBaseline: DirectMemoryDocument?
    private var loadGeneration = 0

    private let client: APIClient

    init(server: URL, profile: String, client: APIClient? = nil) {
        self.profile = profile
        self.client = client ?? APIClient(baseURL: server)
    }

    func load() async {
        guard !isSaving else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { if generation == loadGeneration { isLoading = false } }

        do {
            try Task.checkCancellation()
            let resolved = try await client.directMemoryScope(profile: profile)
            var loaded: [DirectMemoryDocument] = []
            var failures: [String: String] = [:]
            var firstError: Error?
            for section in MemorySection.allCases {
                try Task.checkCancellation()
                do { loaded.append(try await client.directMemoryDocument(section: section, scope: resolved)) }
                catch {
                    if Task.isCancelled { throw CancellationError() }
                    failures[section.rawValue] = error.localizedDescription
                    firstError = firstError ?? error
                }
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            scope = resolved
            documents = loaded
            sectionErrors = failures
            memoryText = loaded.first { $0.section == .memory }?.content
            userText = loaded.first { $0.section == .user }?.content
            soulText = loaded.first { $0.section == .soul }?.content
            hasLoaded = true
            lastError = firstError
            if failures.isEmpty { hasUnconfirmedSave = false }
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    func canEdit(_ section: MemorySection) -> Bool {
        !isSaving && !isLoading && !hasUnconfirmedSave && documents.contains { $0.section == section }
    }

    func beginEditing(_ section: MemorySection) {
        editingBaseline = documents.first { $0.section == section }
        clearActionError()
    }

    /// The read-only project-context section only appears when the server sent a
    /// non-empty document. Servers without the field (or with an empty/blank one,
    /// which is what upstream returns when no readable context file exists) render
    /// the screen exactly as before.
    var showsProjectContext: Bool {
        guard let text = projectContextText else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Non-localized "name — workspace" detail line for the project-context section.
    var projectContextDetail: String? {
        let parts = [projectContextName, projectContextWorkspace]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    func content(for section: MemorySection) -> String {
        switch section {
        case .memory:
            return memoryText ?? ""
        case .user:
            return userText ?? ""
        case .soul:
            return soulText ?? ""
        }
    }

    func modifiedAt(for section: MemorySection) -> Date? {
        switch section {
        case .memory:
            return memoryMtime
        case .user:
            return userMtime
        case .soul:
            return soulMtime
        }
    }

    func save(section: MemorySection, content: String) async -> Bool {
        guard canEdit(section), let scope,
              let baseline = editingBaseline?.section == section ? editingBaseline : documents.first(where: { $0.section == section }) else { return false }
        isSaving = true
        actionErrorMessage = nil
        lastError = nil
        defer { isSaving = false }

        do {
            let confirmed = try await client.directSaveMemory(content, baseline: baseline, scope: scope)
            documents.removeAll { $0.section == section }
            documents.append(confirmed)
            editingBaseline = nil
            switch section {
            case .memory: memoryText = confirmed.content
            case .user: userText = confirmed.content
            case .soul: soulText = confirmed.content
            }
            return true
        } catch {
            if case DirectMemoryError.unconfirmed(let underlying) = error {
                hasUnconfirmedSave = true
                lastError = underlying
            } else { lastError = error }
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Retained presentation seam for future authoritative context discovery.
    /// The stock memory adapter does not fabricate this projection from filenames.
    func applyProjectContext(_ response: MemoryResponse) {
        projectContextText = response.projectContext
        projectContextName = response.projectContextName
        projectContextWorkspace = response.projectContextWorkspace
        projectContextMtime = response.projectContextMtime.map { Date(timeIntervalSince1970: $0) }
        isProjectContextShadowed = response.projectContextShadowed ?? false
        isExternalNotesEnabled = response.externalNotesEnabled
    }
}
