import Foundation

enum DirectMainModelResult {
    case confirmed(model: String, provider: String)
    case confirmationRequired(String)
}

enum DirectMainModelError: LocalizedError {
    case invalidSelection, unconfirmed
    var errorDescription: String? {
        switch self {
        case .invalidSelection: "A profile, provider, and model are required."
        case .unconfirmed: "The model change could not be confirmed. Refresh the current model before trying again."
        }
    }
}

private struct DirectMainModelReceipt: Decodable {
    let ok: Bool?
    let scope: String?
    let provider: String?
    let model: String?
    let confirmRequired: Bool?
    let confirmMessage: String?
}

extension APIClient {
    /// Stock persists the main model for new sessions only. Confirmation is
    /// returned to the caller, never silently approved or automatically retried.
    func directSetMainModel(profile: String, provider: String, model: String,
                            confirmExpensive: Bool = false) async throws -> DirectMainModelResult {
        guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.contains("\0") else { throw DirectMainModelError.invalidSelection }
        var components = URLComponents()
        components.path = "/api/model/set"
        components.queryItems = [URLQueryItem(name: "profile", value: profile)]
        let body: [String: JSONValue] = ["scope": .string("main"), "provider": .string(provider),
            "model": .string(model), "confirm_expensive_model": .bool(confirmExpensive)]
        let bytes = try await sendDirectData(path: components.string!, method: "POST",
            encodedBody: JSONEncoder().encode(body), classifyStructuredAuthExpiry: true)
        let receipt = try decode(DirectMainModelReceipt.self, from: bytes)
        guard receipt.scope == "main", receipt.provider == provider else { throw DirectMainModelError.unconfirmed }
        if receipt.confirmRequired == true {
            guard receipt.ok == false, receipt.model == model, !confirmExpensive else { throw DirectMainModelError.unconfirmed }
            return .confirmationRequired(receipt.confirmMessage ?? "Hermes requires confirmation before selecting this model.")
        }
        guard receipt.ok == true, let acknowledgedModel = receipt.model, !acknowledgedModel.isEmpty else {
            throw DirectMainModelError.unconfirmed
        }
        let persisted = try await directModelOptions(profile: profile)
        guard persisted.provider == provider, persisted.model == acknowledgedModel else {
            throw DirectMainModelError.unconfirmed
        }
        return .confirmed(model: acknowledgedModel, provider: provider)
    }

    func personalities() async throws -> PersonalitiesResponse {
        try await send(endpoint: .personalities, method: "GET")
    }

    func setPersonality(sessionID: String, name: String) async throws -> PersonalitySetResponse {
        try await send(
            endpoint: .setPersonality,
            method: "POST",
            body: PersonalitySetRequest(sessionId: sessionID, name: name)
        )
    }

    /// Stock inventory reports credential availability, not a live inference
    /// health check or the old WebUI credential-source metadata.
    func providers(profile: String = "default") async throws -> ProvidersResponse {
        let options = try await directModelOptions(profile: profile, includeUnconfigured: true)
        return ProvidersResponse(
            providers: options.providers?.map { row in
                ProviderSummary(
                    id: row.slug,
                    displayName: row.name,
                    authError: row.warning,
                    models: row.models?.map { ProviderModel(id: $0) },
                    modelsTotal: row.totalModels,
                    credentialsAvailable: row.authenticated
                )
            },
            activeProvider: options.provider
        )
    }

    func updatesCheck() async throws -> UpdatesCheckResponse {
        try await send(endpoint: .updatesCheck, method: "GET")
    }

    /// Forces a *live* update check: `POST /api/updates/check` with `{ "force": true }`.
    /// Upstream runs a real `git fetch` for this path (`check_for_updates(force=True)`),
    /// whereas the plain GET only returns the cached status. Same response shape, so
    /// `UpdatesCheckResponse` is reused. Used by the manual "Check for updates" button (#308).
    func updatesCheckForced() async throws -> UpdatesCheckResponse {
        try await send(
            endpoint: .updatesCheck,
            method: "POST",
            body: UpdatesCheckForceRequest(force: true)
        )
    }

    /// Applies a pending repo update. The server pulls `--ff-only` and then
    /// restarts itself, so the caller must tolerate a brief connection outage
    /// and re-poll afterwards. Defaults to the `webui` target (issue #180 scope;
    /// no `agent` target, `/force`, or `/summary`).
    func applyUpdate(target: String = "webui") async throws -> UpdatesApplyResponse {
        try await send(
            endpoint: .updatesApply,
            method: "POST",
            body: UpdatesApplyRequest(target: target)
        )
    }

    func insights(days: Int) async throws -> InsightsResponse {
        try await send(endpoint: .insights(days: days), method: "GET")
    }
}

private struct PersonalitySetRequest: Encodable {
    let sessionId: String
    let name: String
}

private struct UpdatesApplyRequest: Encodable {
    let target: String
}

private struct UpdatesCheckForceRequest: Encodable {
    let force: Bool
}
