import Foundation
import Observation

enum CronJobListMutation: Equatable {
    case upsert(CronJob)
    case delete(jobID: String)
}

@MainActor
@Observable
final class TasksViewModel {
    private(set) var jobs: [CronJob] = []
    private(set) var runningJobs: [String: Double] = [:]
    /// Server-provided deliver targets; `nil` while unknown or when the
    /// endpoint is unavailable (the editor then falls back to free text).
    private(set) var deliveryOptions: [CronDeliveryOption]?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var lastError: Error?
    private(set) var creationNeedsInspection = false
    private(set) var creationInspectionProfile: String?
    private(set) var creationInspectionJobs: [CronJob] = []
    private(set) var creationInspectionReady = false
    private(set) var isInspectingCreation = false

    private let client: APIClient
    private let profile: String
    private var loadGeneration = 0

    init(server: URL, client: APIClient? = nil, profile: String = "default") {
        self.client = client ?? APIClient(baseURL: server)
        self.profile = profile
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { if generation == loadGeneration { isLoading = false } }

        do {
            // The jobs endpoint is the required list payload. Publish it as
            // soon as it is ready; delivery-target discovery is optional and
            // must not hold the list behind a slow or unavailable endpoint.
            let jobsResult = try await client.directCronJobs(profile: profile)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            runningJobs = Dictionary(jobsResult.compactMap { job in
                guard let id = job.jobId, let elapsed = job.latestExecution?.runningElapsed() else { return nil }
                return (id, elapsed)
            }, uniquingKeysWith: { _, newest in newest })
            jobs = jobsResult.sorted(by: sortJobs)
            isLoading = false

            // Optional endpoint: failure must not break the task list, and a
            // nil result keeps the editor's free-text deliver fallback.
            let options = try? await client.directCronDeliveryOptions()
            guard generation == loadGeneration, !Task.isCancelled else { return }
            deliveryOptions = options
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    func runningElapsed(for job: CronJob) -> Double? {
        guard let jobID = job.jobId else { return nil }
        return runningJobs[jobID]
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    /// Explicit read-only inspection; ordinary list refresh never unlocks creation.
    func inspectCreationOutcome() async {
        guard creationNeedsInspection, !isInspectingCreation,
              let scope = creationInspectionProfile else { return }
        isInspectingCreation = true
        creationInspectionReady = false
        lastError = nil
        defer { isInspectingCreation = false }
        do {
            let result = try await client.directCronJobs(profile: scope)
            guard !Task.isCancelled, creationNeedsInspection, creationInspectionProfile == scope else { return }
            creationInspectionJobs = result
            creationInspectionReady = true
        } catch {
            guard !Task.isCancelled else { return }
            lastError = error
            actionErrorMessage = "Could not inspect saved tasks. Creation remains paused; refresh the inspection before continuing."
        }
    }

    func acknowledgeCreationInspection() {
        guard creationNeedsInspection, creationInspectionReady, !isInspectingCreation else { return }
        creationNeedsInspection = false
        creationInspectionProfile = nil
        creationInspectionJobs = []
        creationInspectionReady = false
        actionErrorMessage = nil
    }

    func create(from draft: CronJobEditorDraft) async -> Bool {
        guard !isMutating, !creationNeedsInspection else { return false }
        guard draft.validationMessage == nil else {
            actionErrorMessage = draft.validationMessage
            return false
        }

        isMutating = true
        loadGeneration += 1
        isLoading = false
        actionErrorMessage = nil
        lastError = nil
        defer { isMutating = false }

        do {
            let owningProfile = draft.trimmedProfile ?? profile
            let job = try await client.directCreateCron(draft: draft, profile: owningProfile)
            if owningProfile == profile { apply(.upsert(job)) }
            return true
        } catch DirectCronMutationError.savedUnregistered(let id) {
            creationNeedsInspection = true
            let owningProfile = draft.trimmedProfile ?? profile
            creationInspectionProfile = owningProfile
            if let saved = try? await client.directCronJob(jobID: id, profile: owningProfile), owningProfile == profile {
                apply(.upsert(saved))
            }
            actionErrorMessage = DirectCronMutationError.savedUnregistered(jobID: id).localizedDescription
            return false
        } catch {
            if case DirectCronMutationError.unconfirmed(let underlying) = error {
                creationNeedsInspection = true
                creationInspectionProfile = draft.trimmedProfile ?? profile
                lastError = underlying
            } else { lastError = error }
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func apply(_ mutation: CronJobListMutation) {
        switch mutation {
        case .upsert(let job):
            upsert(job)
        case .delete(let jobID):
            jobs.removeAll { $0.jobId == jobID }
            runningJobs.removeValue(forKey: jobID)
        }
    }

    var activeRunningCount: Int {
        runningJobs.count
    }

    private func upsert(_ job: CronJob) {
        let matchingIndex: Int?
        if let jobID = job.jobId {
            matchingIndex = jobs.firstIndex { $0.jobId == jobID }
        } else if let name = job.name {
            matchingIndex = jobs.firstIndex { $0.jobId == nil && $0.name == name }
        } else {
            matchingIndex = nil
        }

        if let index = matchingIndex {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        jobs.sort(by: sortJobs)
    }

    private func sortJobs(_ left: CronJob, _ right: CronJob) -> Bool {
        if runningElapsed(for: left) != nil, runningElapsed(for: right) == nil {
            return true
        }

        if runningElapsed(for: left) == nil, runningElapsed(for: right) != nil {
            return false
        }

        switch (left.nextRunAt?.date, right.nextRunAt?.date) {
        case let (leftDate?, rightDate?):
            return leftDate < rightDate
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }
}
