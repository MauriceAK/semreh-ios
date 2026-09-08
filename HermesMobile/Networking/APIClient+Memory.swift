import Foundation

struct DirectMemoryScope: Equatable {
    let profile: String
    let home: String
    let memoryEnabled: Bool
    let userEnabled: Bool
    let externalProvider: String?
}

struct DirectMemoryDocument: Equatable {
    let section: MemorySection
    let path: String
    let content: String
    let exists: Bool
}

enum DirectMemoryError: LocalizedError {
    case invalidScope, invalidDocument, conflict
    case unconfirmed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidScope: "The selected Hermes profile directory could not be verified."
        case .invalidDocument: "Hermes returned an invalid or unsupported memory document."
        case .conflict: "This document changed on the server. Close the editor and refresh before saving."
        case .unconfirmed: "The save could not be confirmed. Do not retry it; close the editor and refresh to check the server copy."
        }
    }
}

extension APIClient {
    /// Resolve only a server-advertised profile home. These reads never select
    /// a provider or enable either built-in memory surface.
    func directMemoryScope(profile: String) async throws -> DirectMemoryScope {
        guard profile.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw DirectMemoryError.invalidScope
        }
        let inventory = try await directProfiles()
        let matches = (inventory.profiles ?? []).filter { $0.name == profile }
        guard matches.count == 1, let path = matches.first?.path,
              path.hasPrefix("/"), path != "/", !path.contains("\0"),
              !path.split(separator: "/").contains("..") else { throw DirectMemoryError.invalidScope }
        let home = path.hasSuffix("/") ? String(path.dropLast()) : path
        var components = URLComponents()
        components.path = "/api/config"
        components.queryItems = [URLQueryItem(name: "profile", value: profile)]
        guard let configPath = components.string else { throw DirectMemoryError.invalidScope }
        let data = try await directMemoryJSON(path: configPath, method: "GET")
        let config = try decode(DirectMemoryConfig.self, from: data)
        return DirectMemoryScope(profile: profile, home: home,
            memoryEnabled: config.memory?.memoryEnabled ?? true,
            userEnabled: config.memory?.userProfileEnabled ?? true,
            externalProvider: config.memory?.provider?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func directMemoryDocument(section: MemorySection, scope: DirectMemoryScope) async throws -> DirectMemoryDocument {
        let path = scope.home + (section == .soul ? "/SOUL.md" : "/memories/\(section == .memory ? "MEMORY" : "USER").md")
        if section == .soul {
            let data = try await directMemoryJSON(path: "/api/profiles/\(scope.profile)/soul", method: "GET")
            let soul = try decode(DirectSoulDocument.self, from: data)
            guard let content = soul.content, let exists = soul.exists else { throw DirectMemoryError.invalidDocument }
            try Self.validateMemoryText(content)
            return DirectMemoryDocument(section: section, path: path, content: content, exists: exists)
        }
        do {
            let file = try await directReadManagedFile(path: path, maximumBytes: 512 * 1024)
            guard file.path == path, let content = String(data: file.data, encoding: .utf8) else {
                throw DirectMemoryError.invalidDocument
            }
            try Self.validateMemoryText(content)
            return DirectMemoryDocument(section: section, path: path, content: content, exists: true)
        } catch DirectHermesRequestError.http(statusCode: 404, reason: _) {
            return DirectMemoryDocument(section: section, path: path, content: "", exists: false)
        }
    }

    /// Managed multipart upload stages a sibling temporary file before atomic
    /// replacement. This is not compare-and-swap: a concurrent writer can still
    /// be overwritten between preflight and replacement. No automatic retry.
    func directSaveMemory(_ content: String, baseline: DirectMemoryDocument, scope: DirectMemoryScope) async throws -> DirectMemoryDocument {
        try Self.validateMemoryText(content)
        let currentScope = try await directMemoryScope(profile: scope.profile)
        guard currentScope.home == scope.home else { throw DirectMemoryError.conflict }
        let current = try await directMemoryDocument(section: baseline.section, scope: currentScope)
        guard current == baseline else { throw DirectMemoryError.conflict }
        let body: Data
        let endpoint: String
        let method: String
        let contentType: String
        if baseline.section == .soul {
            endpoint = "/api/profiles/\(scope.profile)/soul"
            method = "PUT"
            body = try JSONEncoder().encode(DirectSoulWrite(content: content))
            contentType = "application/json"
        } else {
            endpoint = "/api/files/upload-stream"
            method = "POST"
            let boundary = "Memory-\(UUID().uuidString)"
            contentType = "multipart/form-data; boundary=\(boundary)"
            var multipart = Data()
            multipart.appendMultipart(textField: "path", value: baseline.path, boundary: boundary)
            multipart.appendMultipart(textField: "overwrite", value: baseline.exists ? "true" : "false", boundary: boundary)
            multipart.appendMultipart(fileField: "file", filename: baseline.section == .memory ? "MEMORY.md" : "USER.md",
                data: Data(content.utf8), boundary: boundary)
            multipart.appendMultipartClosingBoundary(boundary)
            body = multipart
        }
        do {
            let data = try await directMemoryJSON(path: endpoint, method: method, body: body, contentType: contentType)
            let receipt = try decode(DirectMemoryWriteReceipt.self, from: data)
            guard receipt.ok == true,
                  baseline.section == .soul || receipt.path == baseline.path else { throw DirectMemoryError.invalidDocument }
            let confirmed = try await directMemoryDocument(section: baseline.section, scope: currentScope)
            guard confirmed.exists, confirmed.content == content, confirmed.path == baseline.path else {
                throw DirectMemoryError.invalidDocument
            }
            let confirmedScope = try await directMemoryScope(profile: scope.profile)
            guard confirmedScope.home == currentScope.home else { throw DirectMemoryError.conflict }
            return confirmed
        } catch { throw DirectMemoryError.unconfirmed(error) }
    }

    private static func validateMemoryText(_ text: String) throws {
        guard text.utf8.count <= 512 * 1024, !text.contains("\0") else { throw DirectMemoryError.invalidDocument }
    }

    /// Bounded editor JSON, including worst-case JSON escaping of the 512 KiB
    /// text cap. Uses the same protected redirect/error policy as managed reads.
    private func directMemoryJSON(path: String, method: String, body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        customHeaderProvider().apply(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let protectedSession = URLSession(configuration: session.configuration,
            delegate: DirectHermesRedirectGuard(origin: baseURL), delegateQueue: nil)
        defer { protectedSession.invalidateAndCancel() }
        do {
            let (data, response) = try await boundedData(for: request, using: protectedSession,
                mapsUnauthorized: false, maximumBytes: 4 * 1024 * 1024)
            guard response.mimeType?.lowercased() == "application/json" else { throw DirectMemoryError.invalidDocument }
            return data
        } catch let APIError.http(statusCode, body) {
            let data = Data((body ?? "").utf8)
            if DirectHermesAuthFailureClassifier.isSessionExpired(statusCode: statusCode, body: data) {
                throw DirectHermesAuthError.sessionExpired
            }
            throw DirectHermesRequestError.from(statusCode: statusCode, body: data)
        }
    }
}

private struct DirectSoulDocument: Decodable { let content: String?; let exists: Bool? }
private struct DirectSoulWrite: Encodable { let content: String }
private struct DirectMemoryWriteReceipt: Decodable { let ok: Bool?; let path: String? }
private struct DirectMemoryConfig: Decodable {
    let memory: Flags?
    enum CodingKeys: String, CodingKey { case memory }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        memory = try? values.decode(Flags.self, forKey: .memory)
    }
    struct Flags: Decodable {
        let memoryEnabled: Bool?
        let userProfileEnabled: Bool?
        let provider: String?
        enum CodingKeys: String, CodingKey { case memoryEnabled, userProfileEnabled, provider }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            memoryEnabled = Self.flag(try? values.decode(JSONValue.self, forKey: .memoryEnabled))
            userProfileEnabled = Self.flag(try? values.decode(JSONValue.self, forKey: .userProfileEnabled))
            provider = try? values.decode(String.self, forKey: .provider)
        }
        // Mirrors stock utils.is_truthy_value; missing/null flags default on.
        private static func flag(_ value: JSONValue?) -> Bool? {
            switch value {
            case .bool(let value): value
            case .string(let value): ["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            case .number(let value): value != 0
            case .array(let value): !value.isEmpty
            case .object(let value): !value.isEmpty
            case .null, nil: nil
            }
        }
    }
}
