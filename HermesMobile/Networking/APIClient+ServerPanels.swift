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

    func updatesCheck(force: Bool = false) async throws -> UpdatesCheckResponse {
        let path = "/api/hermes/update/check?force=\(force ? "true" : "false")"
        return try decode(UpdatesCheckResponse.self, from: await sendDirectData(
            path: path, method: "GET", classifyStructuredAuthExpiry: true
        ))
    }

    func updatesCheckForced() async throws -> UpdatesCheckResponse {
        try await updatesCheck(force: true)
    }

    /// Starts the stock Hermes updater. The acknowledgement is not completion;
    /// callers must correlate its action ID with the durable action status.
    func applyUpdate() async throws -> UpdatesApplyResponse {
        try decode(UpdatesApplyResponse.self, from: await sendDirectData(
            path: "/api/hermes/update", method: "POST", classifyStructuredAuthExpiry: true
        ))
    }

    func hermesUpdateStatus() async throws -> HermesUpdateStatusResponse {
        try decode(HermesUpdateStatusResponse.self, from: await sendDirectData(
            path: "/api/actions/hermes-update/status?lines=1", method: "GET",
            classifyStructuredAuthExpiry: true
        ))
    }

    func insights(days: Int) async throws -> InsightsResponse {
        try await send(endpoint: .insights(days: days), method: "GET")
    }
}

private struct PersonalitySetRequest: Encodable {
    let sessionId: String
    let name: String
}
