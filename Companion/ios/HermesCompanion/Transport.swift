import Foundation
import Security

struct CompanionAPI: Sendable {
    let baseURL: URL
    let token: String?
    var session: URLSession = .shared
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
    func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var url = baseURL
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ClientError.invalidResponse }
        components.queryItems = query.isEmpty ? nil : query
        guard let result = components.url else { throw ClientError.invalidResponse }
        return result
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = []) throws -> URLRequest {
        var request = URLRequest(url: try url(path, query: query))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }
    func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await perform(request(path, query: query))
    }
    func mutate<Body: Encodable & Sendable, Result: Decodable & Sendable>(_ path: String, method: String = "POST", body: Body) async throws -> Result {
        let data = try await Task.detached(priority: .userInitiated) {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return try encoder.encode(body)
        }.value
        return try await perform(request(path, method: method, body: data))
    }
    func perform<T: Decodable & Sendable>(_ request: URLRequest) async throws -> T {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard response.expectedContentLength <= TranscriptWindow.maxBytes else { throw ClientError.payloadTooLarge }
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), TranscriptWindow.maxBytes))
        for try await byte in bytes {
            guard data.count < TranscriptWindow.maxBytes else { throw ClientError.payloadTooLarge }
            data.append(byte)
        }
        return try Self.decodeResponse(data, status: response.statusCode)
    }
    static func decodeResponse<T: Decodable & Sendable>(_ data: Data, status: Int) throws -> T {
        if T.self == CommandReceipt.self, let receipt = try? decoder.decode(T.self, from: data) { return receipt }
        guard (200..<300).contains(status) else {
            let error = try? Self.decoder.decode(WireError.self, from: data)
            throw ClientError.server(status, error?.error.code ?? "http_error", error?.error.message ?? "The host could not complete the request.")
        }
        return try Self.decoder.decode(T.self, from: data)
    }
    func webSocket() throws -> URLSessionWebSocketTask {
        var request = try request("v1/events")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        request.url = components.url
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = TranscriptWindow.maxBytes
        return task
    }
}

enum GrantVault {
    private static let service = "org.hermescompanion.beta.device"
    static func save(_ grant: DeviceGrant) throws {
        let data = try JSONEncoder().encode(grant)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "paired-host"]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ClientError.server(0, "keychain", "Could not securely store this device grant.") }
        } else if status != errSecSuccess {
            throw ClientError.server(0, "keychain", "Could not securely store this device grant.")
        }
    }
    static func load() -> DeviceGrant? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "paired-host", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(DeviceGrant.self, from: data)
    }
    static func remove() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

struct PendingOperation: Codable, Sendable { let operationID: String; let sessionID: String; let kind: String }
@MainActor
final class OperationJournal {
    private let defaults: UserDefaults
    private let key = "pending-operations-v1"
    private(set) var pending: [PendingOperation]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pending = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([PendingOperation].self, from: $0) } ?? []
    }
    func begin(_ command: AgentCommand, sessionID: String) {
        pending.append(.init(operationID: command.operationId, sessionID: sessionID, kind: command.kind))
        persist()
    }
    func resolve(_ operationID: String) {
        pending.removeAll { $0.operationID.caseInsensitiveCompare(operationID) == .orderedSame }
        persist()
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(pending), forKey: key) }
}
