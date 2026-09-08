import Foundation
import Observation

@MainActor
@Observable
final class TaskDetailViewModel {
    private(set) var job: CronJob
    private(set) var runningElapsed: Double?

    private(set) var outputs: [CronOutputItem] = []
    private(set) var runs: [DirectCronRun] = []
    /// Server-provided deliver targets; `nil` while unknown or when the
    /// endpoint is unavailable (the editor then falls back to free text).
    private(set) var deliveryOptions: [CronDeliveryOption]?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var lastError: Error?
    private(set) var lastMutation: CronJobListMutation?

    private let client: APIClient
    private let profile: String
    private var loadGeneration = 0

    init(job: CronJob, runningElapsed: Double?, server: URL, client: APIClient? = nil, profile: String = "default") {
        self.job = job
        self.runningElapsed = runningElapsed
        self.client = client ?? APIClient(baseURL: server)
        self.profile = profile
    }

    func load() async {
        guard !isMutating else { return }
        loadGeneration += 1
        let generation = loadGeneration
        guard let jobID = job.jobId else {
            errorMessage = String(localized: "Missing job identifier.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { if generation == loadGeneration { isLoading = false } }

        // Optional endpoint: failure must not break the detail view, and a
        // nil result keeps the editor's free-text deliver fallback.
        async let deliveryOptionsResponse = try? client.directCronDeliveryOptions()

        do {
            async let detail = client.directCronJob(jobID: jobID, profile: profile)
            async let history = client.directCronRuns(jobID: jobID, profile: profile)
            // Stock get_job omits execution enrichment; only list_jobs adds it.
            async let inventory = client.directCronJobs(profile: profile)
            let (freshJob, freshRuns, jobs) = try await (detail, history, inventory)
            guard let executionJob = jobs.first(where: { $0.jobId == jobID }) else {
                throw DirectCronReadError.invalidIdentity
            }
            let options = await deliveryOptionsResponse
            guard generation == loadGeneration else { return }
            job = freshJob
            runs = freshRuns
            runningElapsed = executionJob.latestExecution?.runningElapsed()
            deliveryOptions = options
        } catch {
            let options = await deliveryOptionsResponse
            guard generation == loadGeneration else { return }
            lastError = error
            errorMessage = error.localizedDescription
            deliveryOptions = options
        }
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    func runNow() async -> Bool {
        let success = await mutateJob { jobID in
            try await client.runCron(jobID: jobID)
        }
        if success {
            runningElapsed = 0
        }
        return success
    }

    func pause(reason: String? = nil) async -> Bool {
        let success = await mutateJob { jobID in
            let updated = try await client.directPauseCron(jobID: jobID, profile: profile, reason: reason)
            return CronMutationResponse(ok: true, job: updated, error: nil)
        }
        if success {
            await load()
        }
        return success
    }

    func resume() async -> Bool {
        let success = await mutateJob { jobID in
            let updated = try await client.directResumeCron(jobID: jobID, profile: profile)
            return CronMutationResponse(ok: true, job: updated, error: nil)
        }
        if success { await load() }
        return success
    }

    func update(from draft: CronJobEditorDraft) async -> Bool {
        guard draft.validationMessage == nil else {
            actionErrorMessage = draft.validationMessage
            return false
        }

        return await mutateJob { jobID in
            try await client.updateCron(
                jobID: jobID,
                prompt: draft.trimmedPrompt,
                schedule: draft.trimmedSchedule,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                deliver: draft.deliver.trimmingCharacters(in: .whitespacesAndNewlines),
                skills: draft.skills,
                model: draft.model.trimmingCharacters(in: .whitespacesAndNewlines),
                provider: draft.provider.trimmingCharacters(in: .whitespacesAndNewlines),
                profile: draft.profile.trimmingCharacters(in: .whitespacesAndNewlines),
                toastNotifications: draft.toastNotifications
            )
        }
    }

    func delete() async -> Bool {
        guard !isMutating else { return false }
        guard let jobID = job.jobId else {
            actionErrorMessage = String(localized: "Missing job identifier.")
            return false
        }

        isMutating = true
        actionErrorMessage = nil
        lastError = nil
        lastMutation = nil
        defer { isMutating = false }

        do {
            let response = try await client.deleteCron(jobID: jobID)
            guard response.ok != false else {
                actionErrorMessage = response.error ?? String(localized: "Could not delete task.")
                return false
            }

            lastMutation = .delete(jobID: jobID)
            return true
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    private func mutateJob(
        action: (String) async throws -> CronMutationResponse
    ) async -> Bool {
        guard !isMutating else { return false }
        guard let jobID = job.jobId else {
            actionErrorMessage = String(localized: "Missing job identifier.")
            return false
        }

        isMutating = true
        // A pre-mutation read may no longer publish its old job or error.
        loadGeneration += 1
        isLoading = false
        actionErrorMessage = nil
        lastError = nil
        lastMutation = nil
        defer { isMutating = false }

        do {
            let response = try await action(jobID)
            guard response.ok != false else {
                actionErrorMessage = response.error ?? String(localized: "Could not update task.")
                return false
            }

            if let updatedJob = response.job {
                job = updatedJob
                lastMutation = .upsert(updatedJob)
            }
            return true
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }
}
