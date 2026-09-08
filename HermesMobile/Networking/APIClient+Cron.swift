import Foundation

extension APIClient {
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

    func crons() async throws -> CronJobsResponse {
        try await send(endpoint: .crons, method: "GET")
    }

    func createCron(
        prompt: String,
        schedule: String,
        name: String?,
        deliver: String?,
        skills: [String],
        model: String?,
        provider: String?,
        profile: String?,
        toastNotifications: Bool
    ) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronCreate,
            method: "POST",
            body: CronCreateRequest(
                prompt: prompt,
                schedule: schedule,
                name: name,
                deliver: deliver,
                skills: skills,
                model: model,
                provider: provider,
                profile: profile,
                toastNotifications: toastNotifications
            )
        )
    }

    func updateCron(
        jobID: String,
        prompt: String?,
        schedule: String?,
        name: String?,
        deliver: String?,
        skills: [String]?,
        model: String?,
        provider: String?,
        profile: String?,
        toastNotifications: Bool?
    ) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronUpdate,
            method: "POST",
            body: CronUpdateRequest(
                jobId: jobID,
                prompt: prompt,
                schedule: schedule,
                name: name,
                deliver: deliver,
                skills: skills,
                model: model,
                provider: provider,
                profile: profile,
                toastNotifications: toastNotifications
            )
        )
    }

    func cronDeliveryOptions() async throws -> CronDeliveryOptionsResponse {
        try await send(endpoint: .cronDeliveryOptions, method: "GET")
    }

    func deleteCron(jobID: String) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronDelete,
            method: "POST",
            body: CronJobIDRequest(jobId: jobID, reason: nil)
        )
    }

    func runCron(jobID: String) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronRun,
            method: "POST",
            body: CronJobIDRequest(jobId: jobID, reason: nil)
        )
    }

    func pauseCron(jobID: String, reason: String? = nil) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronPause,
            method: "POST",
            body: CronJobIDRequest(jobId: jobID, reason: reason)
        )
    }

    func resumeCron(jobID: String) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronResume,
            method: "POST",
            body: CronJobIDRequest(jobId: jobID, reason: nil)
        )
    }

    func cronStatus(jobID: String? = nil) async throws -> CronStatusResponse {
        try await send(endpoint: .cronStatus(jobID: jobID), method: "GET")
    }

    func cronOutput(jobID: String, limit: Int? = 5) async throws -> CronOutputResponse {
        try await send(endpoint: .cronOutput(jobID: jobID, limit: limit), method: "GET")
    }
}

enum DirectCronReadError: Error { case invalidScope, invalidIdentity }

enum DirectCronMutationError: LocalizedError {
    case unsupportedPauseReason
    case unconfirmedResponse

    var errorDescription: String? {
        switch self {
        case .unsupportedPauseReason:
            String(localized: "This Hermes server does not support a pause reason.")
        case .unconfirmedResponse:
            String(localized: "Hermes did not confirm the task change. Refresh before trying again.")
        }
    }
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
