import Foundation

extension APIClient {
    func directCreateCron(draft: CronJobEditorDraft, profile: String) async throws -> CronJob {
        let path = try directCronPath("/api/cron/jobs", profile: profile)
        let body = try JSONEncoder().encode(DirectCronCreateRequest(prompt: draft.trimmedPrompt,
            schedule: draft.trimmedSchedule, name: draft.trimmedName ?? "", deliver: draft.trimmedDeliver ?? "local",
            skills: draft.skills, model: draft.trimmedModel, provider: draft.trimmedProvider))
        do {
            let data = try await directCronMutationData(path: path, method: "POST", body: body)
            let job = try decode(CronJob.self, from: data)
            guard let id = job.jobId, !id.isEmpty, job.profile == profile else { throw DirectCronReadError.invalidIdentity }
            let confirmed = try await directCronJob(jobID: id, profile: profile)
            guard confirmed.prompt == draft.trimmedPrompt else { throw DirectCronMutationError.unconfirmedResponse }
            return confirmed
        } catch DirectCronMutationError.savedUnregistered(let id) { throw DirectCronMutationError.savedUnregistered(jobID: id) }
        catch { throw DirectCronMutationError.unconfirmed(error) }
    }

    func directUpdateCron(jobID: String, profile: String, draft: CronJobEditorDraft) async throws -> CronJob {
        guard draft.trimmedProfile == nil || draft.trimmedProfile == profile else { throw DirectCronMutationError.unsupportedProfileMove }
        let path = try directCronJobPath(jobID, profile: profile)
        // Only fields owned by the current editor are sent. Stock script,
        // workdir, context_from, enabled_toolsets and other fields are retained.
        let updates: [String: JSONValue] = [
            "prompt": .string(draft.trimmedPrompt), "schedule": .string(draft.trimmedSchedule),
            "name": .string(draft.name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "deliver": .string(draft.trimmedDeliver ?? "local"),
            "skills": .array(draft.skills.map(JSONValue.string)),
            "model": draft.trimmedModel.map(JSONValue.string) ?? .null,
            "provider": draft.trimmedProvider.map(JSONValue.string) ?? .null
        ]
        let body = try JSONEncoder().encode(JSONValue.object(["updates": .object(updates)]))
        do {
            let data = try await directCronMutationData(path: path, method: "PUT", body: body)
            let receipt = try decode(CronJob.self, from: data)
            guard receipt.jobId == jobID, receipt.profile == profile else { throw DirectCronReadError.invalidIdentity }
            let confirmed = try await directCronJob(jobID: jobID, profile: profile)
            guard confirmed.prompt == draft.trimmedPrompt else { throw DirectCronMutationError.unconfirmedResponse }
            return confirmed
        } catch { throw DirectCronMutationError.unconfirmed(error) }
    }

    /// Stock runs this request end-to-end, not as a queued-start acknowledgement.
    /// A completed one-shot can already have removed itself from the job store.
    func directTriggerCron(jobID: String, profile: String) async throws -> CronJob {
        let path = try directCronJobPath(jobID, profile: profile, suffix: "/trigger")
        do {
            let data = try await directCronMutationData(path: path, method: "POST")
            let job = try decode(CronJob.self, from: data)
            guard job.jobId == jobID, job.profile == profile else { throw DirectCronReadError.invalidIdentity }
            return job
        } catch { throw DirectCronMutationError.unconfirmed(error) }
    }

    func directDeleteCron(jobID: String, profile: String) async throws {
        let path = try directCronJobPath(jobID, profile: profile)
        do {
            let data = try await directCronMutationData(path: path, method: "DELETE")
            let receipt = try decode(DirectCronDeleteReceipt.self, from: data)
            guard receipt.ok == true else { throw DirectCronMutationError.unconfirmedResponse }
            let remaining = try await directCronJobs(profile: profile)
            guard !remaining.contains(where: { $0.jobId == jobID }) else { throw DirectCronMutationError.unconfirmedResponse }
        } catch { throw DirectCronMutationError.unconfirmed(error) }
    }

    private func directCronMutationData(path: String, method: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        customHeaderProvider().apply(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            return try await boundedSameOriginData(
                for: request, maximumBytes: 2 * 1024 * 1024
            ).0
        } catch let APIError.http(statusCode, body) {
            let bytes = Data((body ?? "").utf8)
            if statusCode == 424,
               let partial = try? decode(DirectCronPartialReceipt.self, from: bytes),
               partial.detail?.jobSaved == true, partial.detail?.schedulerRegistered == false,
               partial.detail?.retryCreate == false, let id = partial.detail?.jobId, !id.isEmpty {
                throw DirectCronMutationError.savedUnregistered(jobID: id)
            }
            if DirectHermesAuthFailureClassifier.isSessionExpired(statusCode: statusCode, body: bytes) { throw DirectHermesAuthError.sessionExpired }
            throw DirectHermesRequestError.from(statusCode: statusCode, body: bytes)
        }
    }

    func directPauseCron(jobID: String, profile: String, reason: String? = nil) async throws -> CronJob {
        guard reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw DirectCronMutationError.unsupportedPauseReason
        }
        return try await directCronPauseResume(jobID: jobID, profile: profile, paused: true)
    }

    func directResumeCron(jobID: String, profile: String) async throws -> CronJob {
        try await directCronPauseResume(jobID: jobID, profile: profile, paused: false)
    }

    private func directCronPauseResume(jobID: String, profile: String, paused: Bool) async throws -> CronJob {
        let path = try directCronJobPath(jobID, profile: profile, suffix: paused ? "/pause" : "/resume")
        let data = try await sendDirectData(path: path, method: "POST", classifyStructuredAuthExpiry: true)
        let job = try decode(CronJob.self, from: data)
        guard job.jobId == jobID, job.profile == profile, job.enabled == !paused,
              job.state == (paused ? "paused" : "scheduled") else {
            throw DirectCronMutationError.unconfirmedResponse
        }
        return job
    }

    func directCronJobs(profile: String) async throws -> [CronJob] {
        let data = try await sendDirectData(path: directCronPath("/api/cron/jobs", profile: profile),
                                            method: "GET", classifyStructuredAuthExpiry: true)
        let jobs = try decode([CronJob].self, from: data)
        guard jobs.allSatisfy({ $0.profile == profile && $0.jobId?.isEmpty == false }) else {
            throw DirectCronReadError.invalidIdentity
        }
        return jobs
    }

    func directCronJob(jobID: String, profile: String) async throws -> CronJob {
        let path = try directCronJobPath(jobID, profile: profile)
        let data = try await sendDirectData(path: path, method: "GET", classifyStructuredAuthExpiry: true)
        let job = try decode(CronJob.self, from: data)
        guard job.jobId == jobID, job.profile == profile else { throw DirectCronReadError.invalidIdentity }
        return job
    }

    func directCronRuns(jobID: String, profile: String, limit: Int = 5) async throws -> [DirectCronRun] {
        guard (1...100).contains(limit) else { throw DirectCronReadError.invalidScope }
        let path = try directCronJobPath(jobID, profile: profile, suffix: "/runs", limit: limit)
        let data = try await sendDirectData(path: path, method: "GET", classifyStructuredAuthExpiry: true)
        let response = try decode(DirectCronRunsResponse.self, from: data)
        guard response.limit == limit, let runs = response.runs, runs.count <= limit,
              runs.allSatisfy({ $0.profile == profile && $0.id?.hasPrefix("cron_\(jobID)_") == true }) else {
            throw DirectCronReadError.invalidIdentity
        }
        return runs
    }

    func directCronDeliveryOptions() async throws -> [CronDeliveryOption] {
        // Stock discovery is process-global: the handler accepts no profile.
        let data = try await sendDirectData(path: "/api/cron/delivery-targets", method: "GET",
                                            classifyStructuredAuthExpiry: true)
        let response = try decode(DirectCronDeliveryTargets.self, from: data)
        return (response.targets ?? []).map { CronDeliveryOption(value: $0.id, label: $0.name) }
    }

    private func directCronPath(_ path: String, profile: String, limit: Int? = nil) throws -> String {
        guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, profile.lowercased() != "all" else {
            throw DirectCronReadError.invalidScope
        }
        var components = URLComponents()
        components.path = path
        components.queryItems = [URLQueryItem(name: "profile", value: profile)]
        if let limit { components.queryItems?.append(URLQueryItem(name: "limit", value: String(limit))) }
        guard let result = components.string else { throw APIError.invalidServerURL }
        return result
    }

    private func directCronJobPath(_ jobID: String, profile: String, suffix: String = "", limit: Int? = nil) throws -> String {
        guard !jobID.isEmpty, jobID != ".", jobID != "..", !jobID.contains("/"), !jobID.contains("\\") else {
            throw DirectCronReadError.invalidIdentity
        }
        return try directCronPath("/api/cron/jobs/\(jobID)\(suffix)", profile: profile, limit: limit)
    }

}

enum DirectCronReadError: Error { case invalidScope, invalidIdentity }

enum DirectCronMutationError: LocalizedError {
    case unsupportedPauseReason
    case unconfirmedResponse
    case unsupportedProfileMove
    case savedUnregistered(jobID: String)
    case unconfirmed(Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedProfileMove:
            String(localized: "A task cannot be moved to another profile in this editor.")
        case .savedUnregistered:
            String(localized: "The task was saved, but its scheduler registration failed. Do not create it again; inspect the saved task.")
        case .unconfirmed:
            String(localized: "The task change could not be confirmed. Refresh and inspect its state before considering another action; this request will not be retried.")
        case .unsupportedPauseReason:
            String(localized: "This Hermes server does not support a pause reason.")
        case .unconfirmedResponse:
            String(localized: "Hermes did not confirm the task change. Refresh before trying again.")
        }
    }
}

private struct DirectCronCreateRequest: Encodable {
    let prompt: String; let schedule: String; let name: String; let deliver: String
    let skills: [String]; let model: String?; let provider: String?
}
private struct DirectCronDeleteReceipt: Decodable { let ok: Bool? }
private struct DirectCronPartialReceipt: Decodable {
    struct Detail: Decodable {
        let jobId: String?; let jobSaved: Bool?; let schedulerRegistered: Bool?; let retryCreate: Bool?
    }
    let detail: Detail?
}

private struct DirectCronRunsResponse: Decodable {
    let runs: [DirectCronRun]?
    let limit: Int?
}

private struct DirectCronDeliveryTargets: Decodable {
    struct Target: Decodable { let id: String?; let name: String? }
    let targets: [Target]?
}

private struct CronCreateRequest: Encodable {
    let prompt: String
    let schedule: String
    let name: String?
    let deliver: String?
    let skills: [String]
    let model: String?
    let provider: String?
    let profile: String?
    let toastNotifications: Bool
}

private struct CronUpdateRequest: Encodable {
    let jobId: String
    let prompt: String?
    let schedule: String?
    let name: String?
    let deliver: String?
    let skills: [String]?
    let model: String?
    let provider: String?
    let profile: String?
    let toastNotifications: Bool?
}

private struct CronJobIDRequest: Encodable {
    let jobId: String
    let reason: String?
}
