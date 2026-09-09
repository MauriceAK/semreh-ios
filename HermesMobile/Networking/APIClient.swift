import Foundation

enum PreviewDownloadError: LocalizedError, Equatable {
    case responseTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .responseTooLarge(let maximumBytes):
            let limit = ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)
            return String(localized: "This document is too large to preview. The preview limit is \(limit).")
        }
    }
}

actor APIClient {
    let baseURL: URL
    let session: URLSession
    let publicMediaSession: URLSession
    /// The redirect guard wired into both default sessions. Strips the user's
    /// custom headers when the server redirects a same-origin request to a
    /// cross-origin host (#277). `nonisolated` so tests can drive the exact
    /// delegate the client installs; it is immutable and `Sendable`.
    nonisolated let redirectHeaderStripper: CrossOriginHeaderStripper
    /// Sessions this client created (vs. ones a caller injected). A `URLSession`
    /// built with a delegate keeps a strong reference to it and to itself until
    /// invalidated, so we tear these down in `deinit` to avoid leaking them — many
    /// `APIClient`s are created ad hoc and discarded (#277).
    private let ownedSessions: [URLSession]
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    /// Read when building each request so live edits apply without rebuilding the
    /// client. Defaults to the process-wide store; tests inject a fixed list (#255).
    /// Internal, not private, because the upload and transcribe extensions build
    /// their multipart requests by hand and need the same header injection (#61).
    let customHeaderProvider: @Sendable () -> [CustomHeader]

    init(
        baseURL: URL,
        session: URLSession? = nil,
        publicMediaSession: URLSession? = nil,
        customHeaderProvider: @escaping @Sendable () -> [CustomHeader] = { CustomHeaderStore.shared.snapshot() }
    ) {
        self.baseURL = baseURL
        self.customHeaderProvider = customHeaderProvider

        // One redirect guard shared by both sessions (same origin + same header
        // provider). Wired into the default sessions so a server-issued
        // same-origin → cross-origin redirect can't forward the user's custom
        // headers off-origin (#277).
        let redirectHeaderStripper = CrossOriginHeaderStripper(
            baseURL: baseURL,
            customHeaderProvider: customHeaderProvider
        )
        self.redirectHeaderStripper = redirectHeaderStripper

        let resolvedSession = session ?? Self.makeDefaultSession(delegate: redirectHeaderStripper)
        let resolvedPublicMediaSession = publicMediaSession
            ?? Self.makeDefaultPublicMediaSession(delegate: redirectHeaderStripper)
        self.session = resolvedSession
        self.publicMediaSession = resolvedPublicMediaSession
        // Only the sessions we created carry our delegate and must be invalidated;
        // an injected session is the caller's to manage.
        var ownedSessions: [URLSession] = []
        if session == nil { ownedSessions.append(resolvedSession) }
        if publicMediaSession == nil { ownedSessions.append(resolvedPublicMediaSession) }
        self.ownedSessions = ownedSessions

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    deinit {
        // Break the session ↔ delegate retain so the sessions we created don't
        // outlive this client (#277). `finishTasksAndInvalidate` lets any in-flight
        // request finish first; by deinit there should be none, since an in-flight
        // actor call keeps `self` alive.
        for session in ownedSessions {
            session.finishTasksAndInvalidate()
        }
    }

    func send<Response: Decodable>(
        endpoint: Endpoint,
        method: String
    ) async throws -> Response {
        let data = try await sendData(endpoint: endpoint, method: method, encodedBody: nil)
        return try decode(Response.self, from: data)
    }

    func send<Response: Decodable, Body: Encodable>(
        endpoint: Endpoint,
        method: String,
        body: Body?,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        let encodedBody = try body.map { try encoder.encode($0) }
        let data = try await sendData(endpoint: endpoint, method: method, encodedBody: encodedBody, timeout: timeout)
        return try decode(Response.self, from: data)
    }

    func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    func sendData(
        endpoint: Endpoint,
        method: String
    ) async throws -> Data {
        try await sendData(endpoint: endpoint, method: method, encodedBody: nil)
    }

    func sendData<Body: Encodable>(
        endpoint: Endpoint,
        method: String,
        body: Body?
    ) async throws -> Data {
        let encodedBody = try body.map { try encoder.encode($0) }
        return try await sendData(endpoint: endpoint, method: method, encodedBody: encodedBody)
    }

    func sendData(
        endpoint: Endpoint,
        method: String,
        encodedBody: Data?,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        try await sendDataReturningResponse(
            endpoint: endpoint,
            method: method,
            encodedBody: encodedBody,
            timeout: timeout
        ).0
    }

    /// Same request/error contract as `sendData`, but also returns the
    /// `HTTPURLResponse` so callers can read response headers (e.g. the
    /// `Content-Disposition` filename on `GET /api/session/export`).
    ///
    /// `accept` overrides the default `application/json` Accept header for
    /// endpoints whose 2xx response is a file download rather than JSON.
    func sendDataReturningResponse(
        endpoint: Endpoint,
        method: String,
        encodedBody: Data?,
        timeout: TimeInterval? = nil,
        accept: String = "application/json"
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint.url(relativeTo: baseURL))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Slow server work (e.g. LLM commit-message generation) needs more than the
        // 60s session default, so callers can widen the per-request timeout.
        if let timeout { request.timeoutInterval = timeout }
        // Custom headers first, then built-ins so Accept/Content-Type always win.
        customHeaderProvider().apply(to: &request)
        request.setValue(accept, forHTTPHeaderField: "Accept")

        if let encodedBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = encodedBody
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.http(statusCode: -1, body: nil)
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.http(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }

        return (data, httpResponse)
    }

    /// Direct-Hermes transport kept separate from the legacy endpoint transport.
    ///
    /// The legacy path maps every HTTP 401 to `APIError.unauthorized`, which is
    /// intentionally not suitable for the direct auth contract: password-login
    /// uses 401 for invalid credentials, while protected routes use structured
    /// 401 bodies for an expired session. Direct callers opt into that narrower
    /// classification explicitly.
    func sendDirectData(
        path: String,
        method: String,
        encodedBody: Data? = nil,
        classifyStructuredAuthExpiry: Bool = false,
        acceptsRedirect: Bool = false
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        customHeaderProvider().apply(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let encodedBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = encodedBody
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(
                for: request, delegate: DirectHermesRedirectGuard(origin: baseURL)
            )
        } catch {
            throw APIError.network(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.http(statusCode: -1, body: nil)
        }

        if classifyStructuredAuthExpiry,
           DirectHermesAuthFailureClassifier.isSessionExpired(
               statusCode: httpResponse.statusCode,
               body: data
           ) {
            throw DirectHermesAuthError.sessionExpired
        }

        let isSuccess = (200..<300).contains(httpResponse.statusCode)
            || (acceptsRedirect && (300..<400).contains(httpResponse.statusCode))
        guard isSuccess else {
            throw DirectHermesRequestError.from(statusCode: httpResponse.statusCode, body: data)
        }

        return data
    }

    func boundedData(
        endpoint: Endpoint,
        maximumBytes: Int,
        accept: String = "*/*"
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint.url(relativeTo: baseURL))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        customHeaderProvider().apply(to: &request)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return try await boundedData(
            for: request,
            using: session,
            mapsUnauthorized: true,
            maximumBytes: maximumBytes
        )
    }

    func boundedData(
        for request: URLRequest,
        using session: URLSession,
        mapsUnauthorized: Bool,
        maximumBytes: Int,
        maximumBytesForResponse: ((HTTPURLResponse) -> Int)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        precondition(maximumBytes >= 0)

        let result: (URLSession.AsyncBytes, URLResponse)
        do {
            result = try await session.bytes(for: request)
        } catch {
            throw APIError.network(underlying: error)
        }

        let bytes = result.0
        defer { bytes.task.cancel() }
        guard let httpResponse = result.1 as? HTTPURLResponse else {
            throw APIError.http(statusCode: -1, body: nil)
        }

        let effectiveMaximumBytes = maximumBytesForResponse?(httpResponse) ?? maximumBytes
        precondition(effectiveMaximumBytes >= 0)

        if mapsUnauthorized && httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            var errorData = Data()
            do {
                for try await byte in bytes {
                    guard errorData.count < 64 * 1_024 else { break }
                    errorData.append(byte)
                }
            } catch {
                throw APIError.network(underlying: error)
            }
            throw APIError.http(
                statusCode: httpResponse.statusCode,
                body: String(data: errorData, encoding: .utf8)
            )
        }

        if httpResponse.expectedContentLength > Int64(effectiveMaximumBytes) {
            throw PreviewDownloadError.responseTooLarge(maximumBytes: effectiveMaximumBytes)
        }

        var data = Data()
        if httpResponse.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(httpResponse.expectedContentLength), effectiveMaximumBytes))
        }

        do {
            for try await byte in bytes {
                guard data.count < effectiveMaximumBytes else {
                    throw PreviewDownloadError.responseTooLarge(maximumBytes: effectiveMaximumBytes)
                }
                data.append(byte)
            }
        } catch let error as PreviewDownloadError {
            throw error
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.network(underlying: error)
        }

        return (data, httpResponse)
    }

    func downloadData(
        from url: URL,
        using session: URLSession,
        mapsUnauthorized: Bool
    ) async throws -> Data {
        try await downloadDataReturningResponse(
            from: url,
            using: session,
            mapsUnauthorized: mapsUnauthorized
        ).0
    }

    func downloadDataReturningResponse(
        from url: URL,
        using session: URLSession,
        mapsUnauthorized: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Same-origin media (incl. the user's own server via the cookie-less
        // publicMediaSession) traverses the proxy, so it carries the custom
        // headers. But downloadData also fetches *external* transcript media
        // (third-party image URLs); those must NOT receive the headers, which may
        // be secrets — that would leak them off-origin. Built-in Accept set after
        // so it wins (#255).
        if Self.isSameOrigin(url, as: baseURL) {
            customHeaderProvider().apply(to: &request)
        }
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.http(statusCode: -1, body: nil)
        }

        if mapsUnauthorized && httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.http(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }

        return (data, httpResponse)
    }

    static func isSameOrigin(_ url: URL, as baseURL: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let baseScheme = baseURL.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              let baseHost = baseURL.host?.lowercased()
        else {
            return false
        }

        return scheme == baseScheme
            && host == baseHost
            && normalizedPort(for: url) == normalizedPort(for: baseURL)
    }

    private static func normalizedPort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }

        switch url.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}

private extension APIClient {
    static func makeDefaultSession(delegate: URLSessionDelegate?) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    static func makeDefaultPublicMediaSession(delegate: URLSessionDelegate?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

/// A `URLSession` redirect guard that removes the user's custom request headers
/// when the server redirects a **same-origin** request to a **cross-origin** host.
///
/// `APIClient` only attaches custom headers (e.g. `Authorization`, `X-Api-Key`)
/// to same-origin requests (#255). But if the server answers a same-origin
/// request with a 3xx redirect to another host, `URLSession` would by default
/// forward those headers to the new host. `URLSession` already strips
/// `Authorization` (and a few sensitive headers) on cross-origin redirects, so
/// the realistic residual leak is a non-`Authorization` custom header (e.g.
/// `X-Api-Key`) — which may be a secret. This delegate closes that gap (#277).
///
/// Same-origin → same-origin redirects keep the headers (a proxy path rewrite
/// still needs them); a request with no custom headers is left byte-identical.
/// Only `willPerformHTTPRedirection` is implemented, so every other delegate
/// responsibility (TLS trust, auth challenges) falls back to `URLSession`'s
/// default handling — unchanged from when these sessions had no delegate.
///
/// `@unchecked Sendable` is safe: both stored properties are immutable and
/// `Sendable` (the header provider is `@Sendable`); `NSObject` just isn't
/// `Sendable` on its own.
final class CrossOriginHeaderStripper: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let baseURL: URL
    private let customHeaderProvider: @Sendable () -> [CustomHeader]

    init(baseURL: URL, customHeaderProvider: @escaping @Sendable () -> [CustomHeader]) {
        self.baseURL = baseURL
        self.customHeaderProvider = customHeaderProvider
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Same-origin (or an indeterminate destination): follow the redirect with
        // headers untouched. We only strip when we can prove the hop is off-origin.
        guard let destination = request.url,
              !APIClient.isSameOrigin(destination, as: baseURL) else {
            completionHandler(request)
            return
        }

        // Cross-origin hop: drop every configured custom header by name so none of
        // the user's (possibly secret) headers reach the new host. Names match
        // case-insensitively because HTTP field names are case-insensitive.
        //
        // The strip set is read from the live config here — the same source that
        // applied the headers. If the user removed a header from the store between
        // a request being sent and its redirect arriving, that header's value could
        // slip through unstripped (a sub-second live-edit race; see #277 review).
        // Accepted as a known narrow gap; closing it would require carrying the
        // applied-name set through the redirect.
        let namesToStrip = Set(
            customHeaderProvider()
                .filter { $0.isApplicable }
                .map { $0.sanitizedName.lowercased() }
        )
        guard !namesToStrip.isEmpty, let fields = request.allHTTPHeaderFields else {
            completionHandler(request)
            return
        }

        // Remove each matching header by its real (original-case) name. We clear
        // fields individually via `setValue(nil:)` rather than reassigning
        // `allHTTPHeaderFields`, because that setter merges new keys instead of
        // deleting omitted ones, so a filtered dictionary would not drop anything.
        var sanitized = request
        for name in fields.keys where namesToStrip.contains(name.lowercased()) {
            sanitized.setValue(nil, forHTTPHeaderField: name)
        }
        completionHandler(sanitized)
    }
}
