import Foundation
import Observation

@MainActor
final class DirectHermesCookieOriginLedger {
    static let shared = DirectHermesCookieOriginLedger()

    struct Reservation {
        let host: String
        let origin: String
        let shouldClearUnownedCookies: Bool
    }

    private var retainedOrigins: [String: String] = [:]
    private var reservations: [String: (origin: String, count: Int)] = [:]

    func remember(_ url: URL) {
        guard let host = url.host?.lowercased() else { return }
        retainedOrigins[host] = retainedOrigins[host] ?? url.absoluteString
    }

    func reserve(_ url: URL, knownOrigins: [URL]) throws -> Reservation {
        guard let host = url.host?.lowercased() else { throw APIError.invalidServerURL }
        let origin = url.absoluteString
        let owners = knownOrigins.compactMap { known -> String? in
            known.host?.lowercased() == host ? known.absoluteString : nil
        }
        if owners.contains(where: { $0 != origin }) || retainedOrigins[host].map({ $0 != origin }) == true {
            throw AuthManager.ServerOriginError.hostnameAlreadyConfigured
        }
        if let held = reservations[host] {
            guard held.origin == origin else { throw AuthManager.ServerOriginError.hostnameAlreadyConfigured }
            reservations[host] = (origin, held.count + 1)
            return Reservation(host: host, origin: origin, shouldClearUnownedCookies: false)
        }
        reservations[host] = (origin, 1)
        return Reservation(
            host: host,
            origin: origin,
            shouldClearUnownedCookies: owners.isEmpty && retainedOrigins[host] == nil
        )
    }

    func release(_ reservation: Reservation) {
        guard let held = reservations[reservation.host], held.origin == reservation.origin else { return }
        if held.count == 1 { reservations.removeValue(forKey: reservation.host) }
        else { reservations[reservation.host] = (held.origin, held.count - 1) }
    }
}

@MainActor
@Observable
final class AuthManager {
    enum ServerOriginError: LocalizedError, Equatable {
        case hostnameAlreadyConfigured

        var errorDescription: String? {
            switch self {
            case .hostnameAlreadyConfigured:
                String(localized: "A saved server already uses this hostname. Remove it before changing ports; if it was just removed, restart Semreh first.")
            }
        }
    }

    enum State: Equatable {
        case unconfigured
        case loggedOut(server: URL)
        case loggedIn(server: URL)

        /// The server this state refers to, if any — used to scope sign-out and
        /// session-expiry to the active server (#16). `unconfigured` has none.
        var server: URL? {
            switch self {
            case .unconfigured: return nil
            case .loggedOut(let server), .loggedIn(let server): return server
            }
        }
    }

    /// Shown when a server has auth on but explicitly reports password auth off,
    /// i.e. it signs in with passkeys (which we can't do yet). See issue #255.
    nonisolated static let passkeyOnlyMessage =
        String(localized: "This server signs in with passkeys, which Semreh doesn't support yet.")

    private(set) var state: State = .unconfigured {
        didSet {
            if case .loggedIn(let server) = state {
                OpenChatSessionStore.shared.activateGateway(server: server)
            } else {
                OpenChatSessionStore.shared.activateGateway(server: nil)
            }
        }
    }
    private(set) var lastErrorMessage: String?

    /// Observable snapshot of every configured server, mirrored from the
    /// `ServerRegistry` (the persistent source of truth) after each mutation so
    /// the Settings server list updates reactively (#17). The active server is the
    /// one whose `id` matches `state.server?.absoluteString`.
    private(set) var servers: [ServerAccount] = []

    private let keychain: any KeychainStoring
    private let clientFactory: (URL) -> any AuthAPIClient
    /// Builds a client bound to explicit headers (not the shared `CustomHeaderStore`)
    /// — used by `addServer` to probe a new server without disturbing the active
    /// server's live headers (#17).
    private let probeClientFactory: (URL, [CustomHeader]) -> any AuthAPIClient
    private let headerStore: CustomHeaderStore
    private let logoutTimeout: Duration
    private let serverRegistry: ServerRegistry
    private let cookieOriginLedger: DirectHermesCookieOriginLedger
    /// Structured expiry can arrive from a request started before a fresh login.
    /// Validate the current cookie first, and bind the result to this auth epoch.
    private var authEpoch = 0
    private var expiryValidationTask: Task<Void, Never>?
    private var expiryValidationOwner: UUID?
    private var expiryValidationServer: URL?
    private var expiryValidationEpoch: Int?

    init(
        keychain: any KeychainStoring = KeychainStore(),
        clientFactory: @escaping (URL) -> any AuthAPIClient = { APIClient(baseURL: $0) },
        probeClientFactory: @escaping (URL, [CustomHeader]) -> any AuthAPIClient = { url, headers in
            APIClient(baseURL: url, customHeaderProvider: { headers })
        },
        headerStore: CustomHeaderStore = .shared,
        logoutTimeout: Duration = .seconds(5),
        serverRegistry: ServerRegistry = .shared,
        cookieOriginLedger: DirectHermesCookieOriginLedger = .shared
    ) {
        self.keychain = keychain
        self.clientFactory = clientFactory
        self.probeClientFactory = probeClientFactory
        self.headerStore = headerStore
        self.logoutTimeout = logoutTimeout
        self.serverRegistry = serverRegistry
        self.cookieOriginLedger = cookieOriginLedger
        serverRegistry.servers.compactMap { URL(string: $0.urlString) }.forEach { cookieOriginLedger.remember($0) }
        restoreSavedServer()
        refreshServers()
    }

    /// The active server's id (its normalized URL string), or nil when
    /// unconfigured. Used by the Settings list to mark which row is active.
    var activeServerID: String? { state.server?.absoluteString }

    /// Re-reads the registry into the observable `servers` snapshot. Called after
    /// every registry mutation routed through this manager.
    private func refreshServers() {
        servers = serverRegistry.servers
    }

    /// The headers currently in effect — used to prefill the editor on the connect
    /// and Settings screens.
    var currentCustomHeaders: [CustomHeader] {
        headerStore.snapshot()
    }

    func testConnection(
        serverURLString: String,
        customHeaders: [CustomHeader]? = nil
    ) async throws -> AuthStatusResponse {
        try Self.validateDirectHermesInput(serverURLString)
        let serverURL = try Self.normalizedServerURL(from: serverURLString)
        try Self.validateDirectHermesOrigin(serverURL)
        let reservation = try reserveCookieHostname(for: serverURL)
        defer { cookieOriginLedger.release(reservation) }
        if reservation.shouldClearUnownedCookies { clearSessionCookies(for: serverURL) }

        // Apply the in-progress headers only after all local origin checks pass,
        // before the first probe. Passing nil leaves the current headers untouched.
        if let customHeaders {
            headerStore.replace(with: customHeaders.sanitizedForStorage())
        }
        let client = clientFactory(serverURL)

        return try await testConnection(client: client)
    }

    private func testConnection(client: any AuthAPIClient) async throws -> AuthStatusResponse {
        let status = try await client.directStatus()
        guard let authRequired = status.authRequired else {
            throw APIError.http(statusCode: 200, body: nil)
        }
        let providers = try await client.directProviders()
        let passwordProvider = providers.providers?.first {
            $0.supportsPassword == true && !($0.name?.isEmpty ?? true)
        }
        return AuthStatusResponse(
            authEnabled: authRequired,
            loggedIn: nil,
            passwordAuthEnabled: authRequired ? passwordProvider != nil : false,
            passkeysEnabled: nil,
            passwordlessEnabled: nil
        )
    }

    func configure(
        serverURLString: String,
        username: String = "",
        password: String,
        customHeaders: [CustomHeader]? = nil
    ) async {
        advanceAuthEpoch()
        lastErrorMessage = nil
        // A rejected *fresh* login must not flip .unconfigured → .loggedOut:
        // ContentView renders those as different view branches, and the swap
        // destroys the OnboardingViewModel holding the typed username/password
        // (issue #21). Saved-server reauth still transitions to .loggedOut.
        let wasUnconfigured: Bool
        if case .unconfigured = state { wasUnconfigured = true } else { wasUnconfigured = false }

        do {
            try Self.validateDirectHermesInput(serverURLString)
            let serverURL = try Self.normalizedServerURL(from: serverURLString)
            try Self.validateDirectHermesOrigin(serverURL)
            let reservation = try reserveCookieHostname(for: serverURL)
            defer { cookieOriginLedger.release(reservation) }
            if reservation.shouldClearUnownedCookies { clearSessionCookies(for: serverURL) }

            if let customHeaders {
                headerStore.replace(with: customHeaders.sanitizedForStorage())
            }
            let client = clientFactory(serverURL)
            let authStatus = try await testConnection(client: client)

            // Passkey-only: auth is on but the server explicitly reports password
            // auth off. Only an explicit false counts — a missing field means an
            // older server that doesn't report it, so we must fall through to the
            // password path and never block a working password user (#255).
            if authStatus.authEnabled == true, authStatus.passwordAuthEnabled == false {
                lastErrorMessage = Self.passkeyOnlyMessage
                return
            }

            if authStatus.authEnabled == true {
                guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    lastErrorMessage = String(localized: "Enter the server username.")
                    return
                }
                guard !password.isEmpty else {
                    lastErrorMessage = String(localized: "Enter the server password.")
                    return
                }

                let providers = try await client.directProviders()
                guard let provider = providers.providers?.first(where: {
                    $0.supportsPassword == true && !($0.name?.isEmpty ?? true)
                })?.name else {
                    lastErrorMessage = String(localized: "This server does not advertise a supported password provider.")
                    return
                }
                let loginResponse = try await client.directPasswordLogin(
                    username: username,
                    password: password,
                    provider: provider
                )
                guard loginResponse.ok == true else {
                    // Stay .unconfigured on a rejected *fresh* login so the
                    // onboarding view keeps the typed username/password for
                    // retry (issue #21). Saved-server reauth still moves to
                    // .loggedOut, which prefills origin/headers.
                    if !wasUnconfigured {
                        state = .loggedOut(server: serverURL)
                    }
                    lastErrorMessage = String(localized: "The Hermes login was not accepted.")
                    return
                }
            }

            // Do not persist an origin merely because its public bootstrap
            // endpoints responded. This confirms the current cookie/auth state
            // for both authenticated and auth-disabled deployments.
            try await client.directProtectedProbe()

            // A protected expiry can arrive while this configure is suspended.
            // Retire that validation again immediately before committing the new
            // login so it cannot demote the freshly authenticated state.
            advanceAuthEpoch()

            // Persist only on success: the server URL and the headers that reached it.
            try keychain.save(serverURL.absoluteString, forKey: .serverURL)
            // Record (or re-activate) this server in the multi-server registry,
            // shadowing the Keychain `server_url` write above (#15). Dedupes by
            // normalized URL.
            serverRegistry.activate(url: serverURL)
            cookieOriginLedger.remember(serverURL)
            // Persist the headers that reached this server under its own scoped key
            // so they never apply to a different server (#16).
            persistCustomHeaders(for: serverURL)
            refreshServers()
            state = .loggedIn(server: serverURL)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Outcome of `addServer`, so the in-app add-server flow can reveal the
    /// password field only when the server actually needs one (#17).
    enum AddServerOutcome: Equatable {
        case added(URL)
        case needsPassword
        case failed
    }

    /// Adds (and switches to) another server from the in-app add-server flow.
    ///
    /// Unlike `configure` (the onboarding path), this NEVER mutates the active
    /// server's state or its live header store until the add fully succeeds: the
    /// new server is probed through a client bound to *its own* headers (via
    /// `probeClientFactory`), not the shared `CustomHeaderStore`. So a typo or an
    /// unreachable server can't bounce the user out of a working session, and the
    /// active server's concurrent requests (polling / SSE reconnect) never pick up
    /// the new server's headers during the async probe window. Rejects a URL that's
    /// already configured (no duplicate normalized URLs). On success the new server
    /// becomes active and its headers are persisted under its own scoped key (#16).
    @discardableResult
    func addServer(
        serverURLString: String,
        username: String = "",
        password: String,
        customHeaders: [CustomHeader] = []
    ) async -> AddServerOutcome {
        lastErrorMessage = nil

        let serverURL: URL
        let reservation: DirectHermesCookieOriginLedger.Reservation
        do {
            try Self.validateDirectHermesInput(serverURLString)
            serverURL = try Self.normalizedServerURL(from: serverURLString)
            try Self.validateDirectHermesOrigin(serverURL)
            reservation = try reserveCookieHostname(for: serverURL)
            if reservation.shouldClearUnownedCookies { clearSessionCookies(for: serverURL) }
        } catch {
            lastErrorMessage = error.localizedDescription
            return .failed
        }
        defer { cookieOriginLedger.release(reservation) }

        guard !serverRegistry.servers.contains(where: { $0.id == serverURL.absoluteString }) else {
            lastErrorMessage = String(localized: "This server is already configured.")
            return .failed
        }

        let newHeaders = customHeaders.sanitizedForStorage()
        // Probe with a client scoped to the NEW server's headers, leaving the live
        // header store (and the active server's in-flight/SSE requests) untouched.
        let client = probeClientFactory(serverURL, newHeaders)

        do {
            let authStatus = try await testConnection(client: client)

            if authStatus.authEnabled == true, authStatus.passwordAuthEnabled == false {
                lastErrorMessage = Self.passkeyOnlyMessage
                return .failed
            }

            if authStatus.authEnabled == true {
                guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    lastErrorMessage = String(localized: "Enter the server username.")
                    return .failed
                }
                guard !password.isEmpty else {
                    // Not an error — the UI reveals the password field and retries.
                    return .needsPassword
                }

                let providers = try await client.directProviders()
                guard let provider = providers.providers?.first(where: {
                    $0.supportsPassword == true && !($0.name?.isEmpty ?? true)
                })?.name else {
                    lastErrorMessage = String(localized: "This server does not advertise a supported password provider.")
                    return .failed
                }
                let loginResponse = try await client.directPasswordLogin(
                    username: username,
                    password: password,
                    provider: provider
                )
                guard loginResponse.ok == true else {
                    lastErrorMessage = String(localized: "The Hermes login was not accepted.")
                    return .failed
                }
            }

            try await client.directProtectedProbe()

            // Commit only now that the add succeeded: the new server becomes
            // active, so its headers move into the live store and persist under its
            // own scoped key (#16). The previous active server's headers were never
            // disturbed, and stay safe in their own scoped Keychain entry.
            //
            // Do the throwing Keychain write first so a write failure leaves the
            // live header store (and the active server) completely untouched.
            advanceAuthEpoch()
            try keychain.save(serverURL.absoluteString, forKey: .serverURL)
            headerStore.replace(with: newHeaders)
            serverRegistry.activate(url: serverURL)
            cookieOriginLedger.remember(serverURL)
            persistCustomHeaders(for: serverURL)
            refreshServers()
            state = .loggedIn(server: serverURL)
            return .added(serverURL)
        } catch {
            lastErrorMessage = error.localizedDescription
            return .failed
        }
    }

    /// Updates the in-effect headers from the Settings editor while signed in. The
    /// in-memory snapshot always updates immediately (so live requests pick them
    /// up), but the Keychain write is opt-in: the editor refreshes on every
    /// keystroke (`persist: false`, cheap) and persists once on dismiss
    /// (`persist: true`), since Keychain writes are slow enough to stutter typing
    /// (#255).
    func updateCustomHeaders(_ headers: [CustomHeader], persist: Bool = true) {
        headerStore.replace(with: headers.sanitizedForStorage())
        // Persist under the active server's scoped key. The Settings editor is only
        // reachable while signed in, so a server is always present here; if somehow
        // unconfigured there's nothing to scope to, so we skip the write (#16).
        if persist, let server = state.server {
            persistCustomHeaders(for: server)
        }
    }

    /// Signs out of the **active** server: best-effort server-side logout, then
    /// drops it locally and auto-switches to the next remaining server — returning
    /// to onboarding only when none remain (#17). A single-server install behaves
    /// exactly as before (sign out → onboarding).
    func signOut() async {
        advanceAuthEpoch()
        guard let active = state.server else {
            // Defensive: nothing is active. Safe full reset to onboarding.
            clearLocalAuth(for: nil)
            state = .unconfigured
            return
        }

        if case .loggedIn = state {
            OpenChatSessionStore.shared.activateGateway(server: nil)
            await attemptBestEffortServerLogout(server: active)
        }

        advanceAfterRemoving(activeServer: active)
    }

    /// Removes a configured server. When it's the active one this behaves like
    /// `signOut` (best-effort server logout + auto-switch / onboarding). A
    /// non-active server is just dropped locally — its registry row, scoped
    /// headers, and cookies — leaving the active server's auth untouched (#17).
    func removeServer(_ account: ServerAccount) async {
        guard let serverURL = URL(string: account.urlString) else { return }
        let isActive = state.server?.absoluteString == account.id

        if isActive {
            advanceAuthEpoch()
            if case .loggedIn = state {
                OpenChatSessionStore.shared.activateGateway(server: nil)
                await attemptBestEffortServerLogout(server: serverURL)
            }
            advanceAfterRemoving(activeServer: serverURL)
        } else {
            clearLocalArtifacts(for: serverURL)
            serverRegistry.remove(id: account.id)
            refreshServers()
        }
    }

    /// Switches the active server to an already-registered one (the Settings
    /// switcher). Mirrors the cold-launch path: persist the URL, set it active,
    /// hydrate its scoped headers, and optimistically enter `.loggedIn`. A stale
    /// cookie is demoted to `.loggedOut` by the first request's 401
    /// (`handleAPIError`), exactly like a relaunch — so no extra round-trip here.
    func switchActiveServer(to account: ServerAccount) {
        guard account.id != state.server?.absoluteString,
              let serverURL = URL(string: account.urlString) else { return }

        do {
            try Self.validateDirectHermesOrigin(serverURL)
            let reservation = try reserveCookieHostname(for: serverURL)
            cookieOriginLedger.release(reservation)
        } catch {
            lastErrorMessage = error.localizedDescription
            return
        }

        advanceAuthEpoch()
        serverRegistry.setActive(id: account.id)
        refreshServers()
        try? keychain.save(serverURL.absoluteString, forKey: .serverURL)
        hydrateCustomHeaders(for: serverURL)
        // Drop the App Intents profile picker cache (#339): it holds the previous server's
        // profiles, which would leak into Shortcuts / Siri if the new server's fetch is
        // delayed or fails. The new server's profiles reload on the next foreground fetch.
        ProfileEntityCache.shared.save([])
        lastErrorMessage = nil
        state = .loggedIn(server: serverURL)
    }

    /// Updates a server's per-server identity (display name, initials, Header Logo
    /// Color). When `account` is the active server the registry mirrors the new
    /// identity into the global identity defaults, so the avatar / header tint
    /// update live (#17).
    func updateServerIdentity(
        _ account: ServerAccount,
        displayName: String,
        initials: String,
        headerLogoColorHex: String
    ) {
        var updated = account
        updated.displayName = displayName
        updated.initials = initials
        updated.headerLogoColorHex = headerLogoColorHex
        serverRegistry.update(updated)
        refreshServers()
    }

    /// Drops the active server locally + from the registry, then auto-switches to
    /// the next remaining server, or returns to onboarding when none remain. The
    /// shared core of `signOut` and active-server `removeServer` (#17).
    private func advanceAfterRemoving(activeServer server: URL) {
        // Always drop any pre-#16 global header remnant on a sign-out path.
        try? keychain.delete(.customHeaders)
        clearLocalArtifacts(for: server)
        // Drop the App Intents profile picker cache (#339): the cached profiles belong to the
        // server being removed, so they're stale whether we switch to another server (its
        // profiles reload on the next foreground fetch) or return to onboarding.
        ProfileEntityCache.shared.save([])

        let nextActive = serverRegistry.remove(id: server.absoluteString)
        refreshServers()

        if let nextActive, let nextURL = URL(string: nextActive.urlString) {
            try? keychain.save(nextURL.absoluteString, forKey: .serverURL)
            hydrateCustomHeaders(for: nextURL)
            lastErrorMessage = nil
            state = .loggedIn(server: nextURL)
        } else {
            try? keychain.delete(.serverURL)
            headerStore.replace(with: [])
            state = .unconfigured
        }
    }

    /// Deletes one server's local auth artifacts — its scoped custom headers and
    /// its cookies — without touching the registry or the global `server_url` key.
    private func clearLocalArtifacts(for server: URL) {
        try? keychain.delete(.customHeaders, scope: server.absoluteString)
        try? keychain.delete(.officialAPIKey, scope: server.absoluteString)
        clearSessionCookies(for: server)
    }

    /// Tells the server to end the session, but never lets an unreachable or
    /// slow server block local sign-out. The request is best-effort and bounded
    /// by `logoutTimeout`; on failure, timeout, or cancellation we just move on
    /// so the caller can always clear local auth and return to onboarding.
    ///
    /// Order matters: this runs while the session cookie still exists, so a
    /// reachable server is logged out server-side before `clearLocalAuth()`
    /// deletes the cookie. See issue #249.
    private func attemptBestEffortServerLogout(server: URL) async {
        let client = clientFactory(server)
        // Copy to a local so the timeout task captures only the value, not `self`.
        let timeout = logoutTimeout

        let logoutTask = Task { @MainActor in
            try await client.directLogout()
        }
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            logoutTask.cancel()
        }

        _ = try? await logoutTask.value
        timeoutTask.cancel()
    }

    func handleAPIError(_ error: Error) {
        guard let authError = error as? DirectHermesAuthError,
              authError == .sessionExpired else {
            return
        }

        switch state {
        case .loggedIn(let server):
            beginExpiryValidation(for: server)
        case .loggedOut(let server):
            commitSessionExpiry(for: server)
        case .unconfigured:
            lastErrorMessage = String(localized: "Your session expired. Sign in again.")
            clearLocalAuth(for: nil)
        }
    }

    /// A protected 401 is not authoritative when it may belong to an older
    /// request. Re-check the current cookie through the active client first.
    /// The task is coalesced and its completion is scoped by owner, server, and
    /// auth epoch so cancellation cannot mutate a later login or server switch.
    private func beginExpiryValidation(for server: URL) {
        guard expiryValidationTask == nil else { return }

        let owner = UUID()
        let epoch = authEpoch
        let client = clientFactory(server)
        let timeout = logoutTimeout
        expiryValidationOwner = owner
        expiryValidationServer = server
        expiryValidationEpoch = epoch
        expiryValidationTask = Task { @MainActor [weak self, client] in
            let outcome: Result<Void, Error>
            do {
                try await Self.runBoundedProtectedProbe(client: client, timeout: timeout)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.finishExpiryValidation(
                owner: owner,
                server: server,
                epoch: epoch,
                outcome: outcome
            )
        }
    }

    private func finishExpiryValidation(
        owner: UUID,
        server: URL,
        epoch: Int,
        outcome: Result<Void, Error>
    ) {
        guard expiryValidationOwner == owner,
              expiryValidationServer == server,
              expiryValidationEpoch == epoch else {
            return
        }

        expiryValidationTask = nil
        expiryValidationOwner = nil
        expiryValidationServer = nil
        expiryValidationEpoch = nil

        guard authEpoch == epoch,
              case .loggedIn(let currentServer) = state,
              currentServer == server else {
            return
        }

        guard case .failure(let error) = outcome,
              let authError = error as? DirectHermesAuthError,
              authError == .sessionExpired else {
            // A successful or inconclusive validation must not sign the user out.
            return
        }

        commitSessionExpiry(for: server)
    }

    private func commitSessionExpiry(for server: URL) {
        lastErrorMessage = String(localized: "Your session expired. Sign in again.")
        switch state {
        case .loggedIn(let currentServer), .loggedOut(let currentServer):
            guard currentServer == server else { return }
            // The server is still valid; only the session cookie is stale. Keep the
            // Keychain entry so re-login is a one-field affair, and clear only this
            // server's cookies so other configured servers stay signed in (#16).
            clearSessionCookies(for: server)
            state = .loggedOut(server: server)
        case .unconfigured:
            return
        }
    }

    private func advanceAuthEpoch() {
        authEpoch &+= 1
        expiryValidationTask?.cancel()
        expiryValidationTask = nil
        expiryValidationOwner = nil
        expiryValidationServer = nil
        expiryValidationEpoch = nil
    }

    private struct ProtectedProbeTimeout: Error {}

    private static func runBoundedProtectedProbe(
        client: any AuthAPIClient,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await client.directProtectedProbe()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProtectedProbeTimeout()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Clears local auth for `server` (a full per-server sign-out): forgets that
    /// server's saved URL, its scoped custom headers, and its cookies, leaving any
    /// other configured server untouched (#16). (Session-expiry via
    /// `handleAPIError` keeps the URL + headers so re-login behind a proxy is a
    /// one-field affair — see #255.)
    ///
    /// When `server` is nil (a 401 while unconfigured) there's no active server to
    /// scope to, so we fall back to clearing the global remnants and the whole
    /// cookie jar as a safe reset.
    private func clearLocalAuth(for server: URL?) {
        // The legacy single-server URL key is global; always clear it on sign-out.
        try? keychain.delete(.serverURL)
        // Drop any pre-#16 global header blob too, so it can't linger or be
        // re-migrated after the user has signed out.
        try? keychain.delete(.customHeaders)

        if let server {
            try? keychain.delete(.customHeaders, scope: server.absoluteString)
            clearSessionCookies(for: server)
        } else {
            clearAllSessionCookies()
        }

        // Forget the active server in the registry (leaves other servers intact).
        serverRegistry.forgetActiveServer()
        refreshServers()
        headerStore.replace(with: [])
        // Drop the App Intents profile picker cache (#339) so a signed-out user doesn't see
        // the previous server's profiles lingering in Shortcuts / Siri.
        ProfileEntityCache.shared.save([])
    }

    /// Mirrors the in-memory header snapshot to `server`'s scoped Keychain entry:
    /// writes it when non-empty, deletes it when empty so no stale list lingers for
    /// that server (#16).
    private func persistCustomHeaders(for server: URL) {
        let scope = server.absoluteString
        let headers = headerStore.snapshot()
        if let encoded = headers.encodedForStorage() {
            try? keychain.save(encoded, forKey: .customHeaders, scope: scope)
        } else {
            try? keychain.delete(.customHeaders, scope: scope)
        }
    }

    /// Loads `server`'s custom headers into the live snapshot before any client is
    /// built, so the first request after launch already carries them (#255). On the
    /// first launch after the per-server split there's no scoped entry yet, so we
    /// migrate the pre-#16 global blob in place — write it under the scoped key and
    /// drop the global remnant — and use it. One scoped Keychain read on the
    /// steady-state path (#16).
    private func hydrateCustomHeaders(for server: URL) {
        let scope = server.absoluteString
        let stored: String?
        if let scoped = try? keychain.load(.customHeaders, scope: scope) {
            stored = scoped
        } else if let legacy = try? keychain.load(.customHeaders) {
            try? keychain.save(legacy, forKey: .customHeaders, scope: scope)
            try? keychain.delete(.customHeaders)
            stored = legacy
        } else {
            stored = nil
        }
        headerStore.replace(with: [CustomHeader].decodeFromStorage(stored))
    }

    /// Deletes only the cookies that would be sent to `server` (matched by host,
    /// path, and security via `HTTPCookieStorage.cookies(for:)`), so signing out of
    /// or expiring one server leaves other servers' cookies intact (#16).
    ///
    /// Different-host servers are fully isolated this way. Two servers that share a
    /// host but differ only by port still share a cookie jar (cookies aren't
    /// port-scoped) — a documented limitation; closing it would need the per-server
    /// cookie snapshot/restore deferred to the #17 switcher.
    private func clearSessionCookies(for server: URL) {
        let storage = HTTPCookieStorage.shared
        storage.cookies(for: server)?.forEach { storage.deleteCookie($0) }
    }

    /// Clears the entire shared cookie jar. Used only as a fallback when there's no
    /// active server to scope to (a 401 while unconfigured).
    private func clearAllSessionCookies() {
        HTTPCookieStorage.shared.cookies?.forEach {
            HTTPCookieStorage.shared.deleteCookie($0)
        }
    }

    private func restoreSavedServer() {
        guard
            let savedValue = try? keychain.load(.serverURL),
            let savedURL = URL(string: savedValue),
            (try? Self.validateDirectHermesOrigin(savedURL)) != nil,
            (try? reserveAndReleaseCookieHostname(for: savedURL)) != nil
        else {
            // No saved server: nothing is active, so no scoped headers apply.
            state = .unconfigured
            return
        }

        // One-time migration of the saved single server into the multi-server
        // registry (#15). Idempotent: an already-registered server is just
        // re-activated, and its per-server identity is only seeded on first
        // insert, so #17 edits survive relaunch.
        serverRegistry.activate(url: savedURL)
        cookieOriginLedger.remember(savedURL)
        // Hydrate this server's headers (migrating the pre-#16 global blob on the
        // first launch after the split) before any client is built, so the first
        // request after launch carries the saved headers (#255/#16).
        hydrateCustomHeaders(for: savedURL)
        state = .loggedIn(server: savedURL)
    }

    /// Direct Hermes auth relies on host-scoped Secure cookies. A configured
    /// production origin must therefore be HTTPS and root-scoped. AuthManager
    /// separately permits only one configured origin per hostname because ports
    /// cannot isolate cookie jars. Loopback HTTP is available
    /// only through an explicit test seam and is never used by production calls.
    nonisolated static func validateDirectHermesOrigin(
        _ url: URL,
        allowLoopbackHTTP: Bool = false
    ) throws {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.path.isEmpty || url.path == "/",
              url.query == nil,
              url.fragment == nil
        else {
            throw APIError.invalidServerURL
        }

        if scheme == "http" {
            guard allowLoopbackHTTP,
                  host == "localhost" || host == "127.0.0.1" || host == "::1" else {
                throw APIError.invalidServerURL
            }
            return
        }

        guard scheme == "https",
              url.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw APIError.invalidServerURL
        }
    }

    /// Cookies are hostname-scoped, not port-scoped. Refuse a second origin for
    /// the same hostname before constructing a client so a probe or login cannot
    /// send one configured account's cookie to another port.
    private func reserveCookieHostname(for candidate: URL) throws -> DirectHermesCookieOriginLedger.Reservation {
        var known = serverRegistry.servers.compactMap { try? Self.normalizedServerURL(from: $0.urlString) }
        if let current = state.server { known.append(current) }
        return try cookieOriginLedger.reserve(candidate, knownOrigins: known)
    }

    private func reserveAndReleaseCookieHostname(for candidate: URL) throws {
        let reservation = try reserveCookieHostname(for: candidate)
        cookieOriginLedger.release(reservation)
    }

    /// Validates the user-entered origin before normalization can erase a
    /// path/query/fragment that would otherwise turn a non-root deployment into
    /// a seemingly valid root origin.
    nonisolated static func validateDirectHermesInput(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.invalidServerURL }

        let valueWithScheme = trimmed.contains("://")
            ? trimmed
            : "\(defaultScheme(forSchemalessServer: trimmed))://\(trimmed)"
        guard let components = URLComponents(string: valueWithScheme),
              let url = components.url else {
            throw APIError.invalidServerURL
        }
        try validateDirectHermesOrigin(url)
    }

    nonisolated static func normalizedServerURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.invalidServerURL
        }

        let valueWithScheme = trimmed.contains("://") ? trimmed : "\(defaultScheme(forSchemalessServer: trimmed))://\(trimmed)"
        guard var components = URLComponents(string: valueWithScheme), components.host != nil else {
            throw APIError.invalidServerURL
        }

        components.host = normalizedHost(components.host)
        if components.scheme?.lowercased() == "https", components.port == 443 {
            components.port = nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let url = components.url, url.scheme == "https" || url.scheme == "http" else {
            throw APIError.invalidServerURL
        }

        return url
    }

    private nonisolated static func normalizedHost(_ host: String?) -> String? {
        guard let host else { return nil }

        var canonicalHost = host.lowercased()
        if canonicalHost.hasSuffix(".") {
            canonicalHost.removeLast()
        }
        return canonicalHost
    }

    private nonisolated static func defaultScheme(forSchemalessServer rawValue: String) -> String {
        guard
            let host = URLComponents(string: "http://\(rawValue)")?.host?.lowercased(),
            shouldDefaultToPlainHTTP(host: host)
        else {
            return "https"
        }

        return "http"
    }

    private nonisolated static func shouldDefaultToPlainHTTP(host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" {
            return true
        }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }

        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}

protocol AuthAPIClient: Sendable {
    func directStatus() async throws -> DirectHermesStatusResponse
    func directProviders() async throws -> DirectHermesAuthProvidersResponse
    func directPasswordLogin(
        username: String,
        password: String,
        provider: String
    ) async throws -> DirectHermesPasswordLoginResponse
    func directProtectedProbe() async throws
    func directLogout() async throws
}

extension APIClient: AuthAPIClient {}
