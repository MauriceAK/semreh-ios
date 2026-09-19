import Foundation

/// `active` is the sticky startup default; `current` belongs to the running
/// server process. Neither overrides the sidebar's explicit local selection.
struct DirectHermesActiveProfile: Decodable, Equatable {
    let active: String?
    let current: String?

    var startupDefaultName: String? {
        guard let value = active?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// Pinned first-party `/api/model/options` inventory. Do not decode the old
/// WebUI `/api/models` envelope or infer the provider from a model's slash prefix.
struct DirectHermesModelOptions: Decodable, Sendable {
    struct Provider: Decodable, Sendable {
        struct Capability: Decodable, Sendable {
            let reasoning: Bool?
            let canDisableReasoning: Bool?
        }
        let slug: String?
        let name: String?
        let models: [String]?
        let authenticated: Bool?
        let totalModels: Int?
        let warning: String?
        let capabilities: [String: Capability]?
    }
    let model: String?
    let provider: String?
    let providers: [Provider]?

    var catalogGroups: [ModelCatalogGroup] {
        (providers ?? []).compactMap { row in
            guard let slug = row.slug, !slug.isEmpty, row.authenticated != false else { return nil }
            var seen = Set<String>()
            let models = (row.models ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }
                .map { ModelCatalogOption(id: $0, displayName: $0, providerID: slug) }
            guard !models.isEmpty else { return nil }
            return ModelCatalogGroup(id: slug, name: row.name ?? slug, providerID: slug, models: models)
        }
    }
}

/// A direct auth request may contain a password in its body. Header stripping
/// alone cannot protect a 307/308 redirect, so refuse every off-origin hop.
final class DirectHermesRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let origin: URL

    init(origin: URL) { self.origin = origin }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
              APIClient.isSameOrigin(destination, as: origin) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private struct DirectHermesPasswordLoginRequest: Encodable {
    let provider: String
    let username: String
    let password: String
    let next: String
}

extension APIClient {
    func directModelOptions(profile: String, refresh: Bool = false, includeUnconfigured: Bool = false) async throws -> DirectHermesModelOptions {
        var path = URLComponents()
        path.path = "/api/model/options"
        path.queryItems = [URLQueryItem(name: "profile", value: profile),
                          URLQueryItem(name: "explicit_only", value: "true")]
        if refresh { path.queryItems?.append(URLQueryItem(name: "refresh", value: "true")) }
        if includeUnconfigured { path.queryItems?.append(URLQueryItem(name: "include_unconfigured", value: "true")) }
        guard let encodedPath = path.string else { throw APIError.invalidServerURL }
        let data = try await sendDirectData(path: encodedPath, method: "GET", classifyStructuredAuthExpiry: true)
        return try decode(DirectHermesModelOptions.self, from: data)
    }

    func directProfiles() async throws -> ProfilesResponse {
        let data = try await sendDirectData(path: "/api/profiles", method: "GET", classifyStructuredAuthExpiry: true)
        return try decode(ProfilesResponse.self, from: data)
    }

    func directActiveProfile() async throws -> DirectHermesActiveProfile {
        let data = try await sendDirectData(path: "/api/profiles/active", method: "GET",
                                            classifyStructuredAuthExpiry: true)
        return try decode(DirectHermesActiveProfile.self, from: data)
    }

    /// Canonical direct-Hermes provider discovery. This does not consult any
    /// legacy WebUI endpoint or fallback transport.
    func directProviders() async throws -> DirectHermesAuthProvidersResponse {
        let data = try await sendDirectData(path: "/api/auth/providers", method: "GET")
        return try decode(DirectHermesAuthProvidersResponse.self, from: data)
    }

    /// Password login deliberately does not classify its 401 as session expiry:
    /// Hermes uses that status for invalid credentials before any session exists.
    func directPasswordLogin(
        username: String,
        password: String,
        provider: String = "basic"
    ) async throws -> DirectHermesPasswordLoginResponse {
        let encoder = JSONEncoder()
        let body = try encoder.encode(
            DirectHermesPasswordLoginRequest(
                provider: provider,
                username: username,
                password: password,
                next: ""
            )
        )
        let data = try await sendDirectData(
            path: "/auth/password-login",
            method: "POST",
            encodedBody: body
        )
        return try decode(DirectHermesPasswordLoginResponse.self, from: data)
    }

    /// Public direct-Hermes deployment/auth status. This route is not the
    /// detailed provider-discovery contract, so callers should use
    /// `directProviders()` for provider selection.
    func directStatus() async throws -> DirectHermesStatusResponse {
        let data = try await sendDirectData(path: "/api/status", method: "GET")
        return try decode(DirectHermesStatusResponse.self, from: data)
    }

    /// Protected REST probe used to distinguish a structured expired session
    /// from generic authorization/proxy/server failures.
    func directProtectedProbe() async throws {
        _ = try await sendDirectData(
            path: "/api/sessions",
            method: "GET",
            classifyStructuredAuthExpiry: true
        )
    }

    /// Mints one short-lived, single-use ticket immediately before a socket
    /// connection. The ticket is returned to the caller and never persisted or
    /// logged by this transport.
    func directWSTicket() async throws -> DirectHermesWSTicketResponse {
        let data = try await sendDirectData(
            path: "/api/auth/ws-ticket",
            method: "POST",
            classifyStructuredAuthExpiry: true
        )
        return try decode(DirectHermesWSTicketResponse.self, from: data)
    }

    /// Hermes responds to logout with a redirect to the login page. Accept it
    /// as a successful server logout while leaving cookie cleanup to the
    /// cookie-enabled session and the future auth manager wiring.
    func directLogout() async throws {
        _ = try await sendDirectData(
            path: "/auth/logout",
            method: "POST",
            classifyStructuredAuthExpiry: true,
            acceptsRedirect: true
        )
    }
}
