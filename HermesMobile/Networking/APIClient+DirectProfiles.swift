import Foundation
import Observation

struct DirectProfileCreationReceipt: Decodable {
    let ok: Bool?
    let name: String?
    let path: String?
    let modelSet: Bool?
}

enum DirectProfileCreationError: LocalizedError {
    case invalidInput, unconfirmed
    var errorDescription: String? {
        switch self {
        case .invalidInput: "The profile name or model configuration is invalid."
        case .unconfirmed: "The server did not confirm profile creation. Refresh the profile list before trying again."
        }
    }
}

extension APIClient {
    func directCreateProfile(name: String, cloneFrom: String?, model: String?, provider: String?) async throws -> DirectProfileCreationReceipt {
        guard ProfileNameRules.isValid(name), name != "default" else { throw DirectProfileCreationError.invalidInput }
        var body: [String: JSONValue] = ["name": .string(name), "clone_all": .bool(false)]
        if let cloneFrom { body["clone_from"] = .string(cloneFrom) }
        if let model { body["model"] = .string(model) }
        if let provider { body["provider"] = .string(provider) }
        let data = try await sendDirectData(path: "/api/profiles", method: "POST",
            encodedBody: JSONEncoder().encode(body), classifyStructuredAuthExpiry: true)
        let receipt = try decode(DirectProfileCreationReceipt.self, from: data)
        guard receipt.ok == true, receipt.name == name,
              let path = receipt.path, path.hasPrefix("/"), !path.contains("\0") else {
            throw DirectProfileCreationError.unconfirmed
        }
        return receipt
    }

    func directCompleteProfileConfiguration(name: String, model: [String: String]) async throws {
        guard ProfileNameRules.isValid(name), name != "default", !model.isEmpty else {
            throw DirectProfileCreationError.invalidInput
        }
        var path = URLComponents()
        path.path = "/api/config"
        path.queryItems = [URLQueryItem(name: "profile", value: name)]
        let data = try await sendDirectData(path: path.string!, method: "PUT",
            encodedBody: JSONEncoder().encode(["config": ["model": model]]),
            classifyStructuredAuthExpiry: true)
        let receipt = try decode(ProfileConfigurationAcknowledgement.self, from: data)
        guard receipt.ok == true else { throw DirectProfileCreationError.unconfirmed }
    }
}

private struct ProfileConfigurationAcknowledgement: Decodable { let ok: Bool? }

/// A create is never automatically repeated. Confirmed identity survives a
/// follow-up failure, and Retry can only write its captured remaining config.
@MainActor @Observable
final class DirectProfileCreationWorkflow {
    private(set) var isWorking = false
    private(set) var created: DirectProfileCreationReceipt?
    private(set) var creationUncertain = false
    private(set) var completed = false
    private(set) var modelAssignmentUnconfirmed = false
    private(set) var errorMessage: String?
    private var pendingModel: [String: String] = [:]
    var canRetryConfiguration: Bool { created != nil && !pendingModel.isEmpty && !completed }

    func create(client: APIClient, name: String, cloneConfig: Bool,
                model: String?, provider: String?, baseURL: String?, apiKey: String?) async {
        guard !isWorking, created == nil, !creationUncertain else { return }
        guard ProfileNameRules.isValid(name), name != "default",
              baseURL == nil || ProfileNameRules.isValidBaseURL(baseURL!) else {
            errorMessage = DirectProfileCreationError.invalidInput.localizedDescription
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        // Resolve the running source explicitly; sticky startup default is not
        // the current process and must never silently retarget the clone.
        let running: String
        do {
            let active = try await client.directActiveProfile()
            guard let current = active.current?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !current.isEmpty else { throw DirectProfileCreationError.invalidInput }
            running = current
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        do {
            let receipt = try await client.directCreateProfile(name: name,
                cloneFrom: cloneConfig ? running : nil, model: model, provider: provider)
            created = receipt
            if let baseURL { pendingModel["base_url"] = baseURL }
            if let apiKey { pendingModel["api_key"] = apiKey }
            // Stock normalizes model assignments and clears cross-provider
            // credentials. Do not emulate that using an incomplete config patch.
            modelAssignmentUnconfirmed = model != nil && receipt.modelSet != true
            await finishConfiguration(client: client)
        } catch {
            // Even a 500 can follow directory creation. No second create and
            // no automatic deletion when its outcome is not confirmed.
            creationUncertain = true
            errorMessage = "Creation was not confirmed. The profile may already exist. Close this form and refresh the profile list before taking another action."
        }
    }

    func retryConfiguration(client: APIClient) async {
        guard !isWorking, canRetryConfiguration else { return }
        isWorking = true
        defer { isWorking = false }
        await finishConfiguration(client: client)
    }

    private func finishConfiguration(client: APIClient) async {
        guard let name = created?.name else { return }
        errorMessage = nil
        do {
            if !pendingModel.isEmpty {
                try await client.directCompleteProfileConfiguration(name: name, model: pendingModel)
            }
            pendingModel = [:]
            completed = !modelAssignmentUnconfirmed
            if modelAssignmentUnconfirmed {
                errorMessage = "This profile exists, but Hermes did not confirm the selected model. Any supplied endpoint settings were acknowledged. Close this form and configure the model separately; creating it again is not a recovery action."
            }
        } catch {
            errorMessage = "Profile '\(name)' was created, but its configuration was not confirmed. Retry Configuration repeats only that update; it will not create or delete a profile."
        }
    }
}

enum DirectStartupDefaultWriteError: Error, Equatable, LocalizedError {
    case invalidName
    case unconfirmed

    var errorDescription: String? {
        switch self {
        case .invalidName: "The profile name is empty."
        case .unconfirmed: "The startup default could not be confirmed. Refresh its value before trying again."
        }
    }
}

extension APIClient {
    /// Stock changes the sticky default for subsequent Hermes invocations. It
    /// does not switch this app's selection or the running gateway's profile.
    /// A POST acknowledgement alone is not durable readback; never retry here.
    func directSetStartupDefaultProfile(name: String) async throws -> DirectHermesActiveProfile {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { throw DirectStartupDefaultWriteError.invalidName }
        let body = try JSONEncoder().encode(StartupDefaultRequest(name: normalized))
        let data = try await sendDirectData(path: "/api/profiles/active", method: "POST",
                                            encodedBody: body, classifyStructuredAuthExpiry: true)
        let acknowledgement = try decode(StartupDefaultAcknowledgement.self, from: data)
        guard acknowledgement.ok == true, acknowledgement.active == normalized else {
            throw DirectStartupDefaultWriteError.unconfirmed
        }
        let persisted = try await directActiveProfile()
        guard persisted.startupDefaultName == normalized else {
            throw DirectStartupDefaultWriteError.unconfirmed
        }
        return persisted
    }
}

private struct StartupDefaultRequest: Encodable { let name: String }
private struct StartupDefaultAcknowledgement: Decodable {
    let ok: Bool?
    let active: String?
}
