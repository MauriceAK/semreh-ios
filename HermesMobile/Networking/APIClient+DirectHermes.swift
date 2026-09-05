import Foundation

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
