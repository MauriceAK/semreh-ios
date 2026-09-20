import XCTest
@testable import HermesMobile

@MainActor
final class AuthManagerStateTests: XCTestCase {
    private struct PreconditionFailure: Error {}

    private static let sessionExpiredMessage = "Your session expired. Sign in again."

    // These tests assert against the global HTTPCookieStorage; reset it on both
    // sides so pre-existing cookies or a mid-test failure can't leak across tests.
    nonisolated override func setUp() {
        super.setUp()
        Self.clearSharedCookies()
    }

    nonisolated override func tearDown() {
        Self.clearSharedCookies()
        super.tearDown()
    }

    private nonisolated static func clearSharedCookies() {
        HTTPCookieStorage.shared.cookies?.forEach {
            HTTPCookieStorage.shared.deleteCookie($0)
        }
    }

    func testUnauthorizedWhileLoggedInKeepsServerAndMovesToLoggedOut() async throws {
        let keychain = InMemoryKeychainStore()
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = ProbeAuthClient(server: server, probes: [.succeed, .expired])
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: server.absoluteString,
            client: client
        )
        let cookieStorage = HTTPCookieStorage.shared
        cookieStorage.setCookie(try makeSessionCookie(for: server, value: "expired-cookie"))

        manager.handleAPIError(DirectHermesAuthError.sessionExpired)
        await waitForProbe(client, count: 2)

        XCTAssertEqual(manager.state, .loggedOut(server: server))
        XCTAssertEqual(keychain.savedValues[.serverURL], server.absoluteString)
        XCTAssertEqual(cookieStorage.cookies?.isEmpty, true)
        XCTAssertEqual(manager.lastErrorMessage, Self.sessionExpiredMessage)
    }

    func testUnauthorizedWhileAlreadyLoggedOutStaysLoggedOutWithServer() async throws {
        let keychain = InMemoryKeychainStore()
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = ProbeAuthClient(server: server, probes: [.succeed, .expired])
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: server.absoluteString,
            client: client
        )

        manager.handleAPIError(DirectHermesAuthError.sessionExpired)
        await waitForProbe(client, count: 2)
        manager.handleAPIError(DirectHermesAuthError.sessionExpired)

        XCTAssertEqual(manager.state, .loggedOut(server: server))
        XCTAssertEqual(keychain.savedValues[.serverURL], server.absoluteString)
    }

    func testLateExpiryFromOlderRequestCannotDemoteFreshLogin() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let keychain = InMemoryKeychainStore()
        let client = ProbeAuthClient(server: server, probes: [.succeed, .wait, .succeed])
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: server.absoluteString,
            client: client
        )

        manager.handleAPIError(DirectHermesAuthError.sessionExpired)
        await waitForProbe(client, count: 2)

        await manager.configure(
            serverURLString: server.absoluteString,
            username: "test-user",
            password: "new-secret"
        )
        await Task.yield()

        XCTAssertEqual(manager.state, .loggedIn(server: server))
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: server)?.first?.value, "login-2")
        XCTAssertNil(manager.lastErrorMessage)

        await manager.signOut()
    }

    func testExpiryArrivingDuringConfigureCannotDemoteFreshCommit() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = ProbeAuthClient(server: server, probes: [.succeed, .manual, .manual])
        let manager = try await makeLoggedInManager(
            keychain: InMemoryKeychainStore(),
            serverURLString: server.absoluteString,
            client: client
        )

        let configureTask = Task { @MainActor in
            await manager.configure(
                serverURLString: server.absoluteString,
                username: "test-user",
                password: "new-secret"
            )
        }
        await waitForProbe(client, count: 2)

        // The configure protected probe is suspended while an unrelated stale
        // request reports expiry. The second epoch advance occurs only at the
        // successful configure commit below.
        manager.handleAPIError(DirectHermesAuthError.sessionExpired)
        await waitForProbe(client, count: 3)

        client.releaseProbe(2, with: .success(()))
        await configureTask.value
        XCTAssertEqual(manager.state, .loggedIn(server: server))

        client.releaseProbe(3, with: .failure(DirectHermesAuthError.sessionExpired))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))

        XCTAssertEqual(manager.state, .loggedIn(server: server))
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: server)?.first?.value, "login-2")
        XCTAssertNil(manager.lastErrorMessage)
    }

    func testExpiryValidationCoalescesAndNetworkFailurePreservesCurrentCookie() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let keychain = InMemoryKeychainStore()
        let client = ProbeAuthClient(server: server, probes: [.succeed, .wait, .network])
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: server.absoluteString,
            client: client
        )

        manager.handleAPIError(DirectHermesAuthError.sessionExpired)
        manager.handleAPIError(DirectHermesAuthError.sessionExpired)
        await waitForProbe(client, count: 2)
        XCTAssertEqual(client.probeCallCount, 2, "Concurrent expiry reports must share one validation probe.")

        await manager.signOut()

        let secondClient = ProbeAuthClient(server: server, probes: [.succeed, .network])
        let secondManager = try await makeLoggedInManager(
            keychain: InMemoryKeychainStore(),
            serverURLString: server.absoluteString,
            client: secondClient
        )
        secondManager.handleAPIError(DirectHermesAuthError.sessionExpired)
        await waitForProbe(secondClient, count: 2)

        XCTAssertEqual(secondManager.state, .loggedIn(server: server))
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: server)?.first?.value, "login-1")
        XCTAssertNil(secondManager.lastErrorMessage)
    }

    func testSwitchAndLogoutRetirePendingExpiryValidation() async throws {
        let serverA = try XCTUnwrap(URL(string: "https://a.example.test"))
        let serverB = try XCTUnwrap(URL(string: "https://b.example.test"))
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        registry.activate(url: serverB)
        let client = ProbeAuthClient(server: serverA, probes: [.succeed, .wait])
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: serverA.absoluteString,
            client: client,
            serverRegistry: registry
        )
        let accountB = try XCTUnwrap(registry.servers.first { $0.id == serverB.absoluteString })

        manager.handleAPIError(DirectHermesAuthError.sessionExpired)
        await waitForProbe(client, count: 2)
        manager.switchActiveServer(to: accountB)
        await Task.yield()

        XCTAssertEqual(manager.state, .loggedIn(server: serverB))
        XCTAssertNil(manager.lastErrorMessage)

        manager.handleAPIError(DirectHermesAuthError.sessionExpired)
        await manager.signOut()
        // Signing out B preserves the other configured account and activates A.
        // The validation retired during the switch/sign-out must not demote A.
        XCTAssertEqual(manager.state, .loggedIn(server: serverA))
        XCTAssertNil(manager.lastErrorMessage)
    }

    func testUnauthorizedWhileUnconfiguredKeepsFullClearBehavior() {
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain) { _ in
            MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        }

        manager.handleAPIError(DirectHermesAuthError.sessionExpired)

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertNil(keychain.savedValues[.serverURL])
        XCTAssertEqual(manager.lastErrorMessage, Self.sessionExpiredMessage)
    }

    func testRejectedFreshLoginStaysUnconfiguredSoRetryKeepsTypedCredentials() async throws {
        // Issue #21: a rejected first login must not flip .unconfigured to
        // .loggedOut — ContentView renders those as different view branches,
        // and the swap destroys the OnboardingViewModel holding the typed
        // username/password. Saved-server reauth still moves to .loggedOut.
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = MockAuthAPIClient(
            authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false),
            loginResponse: LoginResponse(ok: false, message: nil, error: "nope")
        )
        let manager = AuthManager(
            keychain: InMemoryKeychainStore(),
            clientFactory: { _ in client },
            serverRegistry: ServerRegistry.inMemory()
        )
        XCTAssertEqual(manager.state, .unconfigured)

        await manager.configure(
            serverURLString: server.absoluteString,
            username: "test-user",
            password: "wrong"
        )

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertEqual(manager.lastErrorMessage, "The Hermes login was not accepted.")
    }

    func testRejectedSavedServerReauthStillMovesToLoggedOut() async throws {
        // Counterpart to the fresh-login test above: a rejected reauth from
        // .loggedOut must keep .loggedOut (saved-server branch with prefilled
        // origin/headers), not fall back to .unconfigured.
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let keychain = InMemoryKeychainStore()
        let succeeding = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let expiringProbe = ProbeAuthClient(server: server, probes: [.expired])
        let rejecting = MockAuthAPIClient(
            authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false),
            loginResponse: LoginResponse(ok: false, message: nil, error: "nope")
        )
        var phase = 0
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in
                phase += 1
                switch phase {
                case 1: return succeeding
                case 2: return expiringProbe
                default: return rejecting
                }
            },
            serverRegistry: ServerRegistry.inMemory()
        )
        await manager.configure(serverURLString: server.absoluteString, username: "test-user", password: "secret")
        guard case .loggedIn = manager.state else {
            XCTFail("Expected loggedIn after configure, got \(manager.state)")
            return
        }

        manager.handleAPIError(DirectHermesAuthError.sessionExpired)
        await waitForProbe(expiringProbe, count: 1)
        XCTAssertEqual(manager.state, .loggedOut(server: server))

        await manager.configure(serverURLString: server.absoluteString, username: "test-user", password: "wrong")
        XCTAssertEqual(manager.state, .loggedOut(server: server))
        XCTAssertEqual(manager.lastErrorMessage, "The Hermes login was not accepted.")
    }

    func testNonUnauthorizedErrorDoesNotChangeState() async throws {
        let keychain = InMemoryKeychainStore()
        let manager = try await makeLoggedInManager(keychain: keychain, serverURLString: "https://example.test")
        let server = try XCTUnwrap(URL(string: "https://example.test"))

        manager.handleAPIError(APIError.http(statusCode: 502, body: ""))

        XCTAssertEqual(manager.state, .loggedIn(server: server))
        XCTAssertEqual(keychain.savedValues[.serverURL], server.absoluteString)
    }

    func testGenericUnauthorizedDoesNotDemoteDirectAuth() async throws {
        let keychain = InMemoryKeychainStore()
        let manager = try await makeLoggedInManager(keychain: keychain, serverURLString: "https://example.test")
        let server = try XCTUnwrap(URL(string: "https://example.test"))

        manager.handleAPIError(APIError.unauthorized)

        XCTAssertEqual(manager.state, .loggedIn(server: server))
        XCTAssertEqual(keychain.savedValues[.serverURL], server.absoluteString)
    }

    func testSignOutFullyClearsServerAndReturnsToUnconfigured() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: "https://example.test",
            client: client
        )

        await manager.signOut()

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertNil(keychain.savedValues[.serverURL])
        // Server-side logout is still attempted best-effort when reachable.
        XCTAssertEqual(client.logoutCallCount, 1)
    }

    func testSignOutClearsLocalAuthWhenServerLogoutFails() async throws {
        let keychain = InMemoryKeychainStore()
        // Server unreachable: the best-effort logout throws, but local sign-out
        // must still succeed so the user can reach onboarding (issue #249).
        let client = MockAuthAPIClient(
            authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false),
            logoutBehavior: .fail(APIError.network(underlying: URLError(.notConnectedToInternet)))
        )
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: "https://example.test",
            client: client
        )

        await manager.signOut()

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertNil(keychain.savedValues[.serverURL])
        XCTAssertEqual(client.logoutCallCount, 1)
    }

    func testSignOutCompletesWhenServerLogoutHangs() async throws {
        let keychain = InMemoryKeychainStore()
        // Server accepts the connection but never responds: sign-out must still
        // finish once the bounded logout times out, not hang indefinitely.
        let client = MockAuthAPIClient(
            authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false),
            logoutBehavior: .hang
        )
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: "https://example.test",
            client: client,
            logoutTimeout: .milliseconds(50)
        )

        await manager.signOut()

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertNil(keychain.savedValues[.serverURL])
        XCTAssertEqual(client.logoutCallCount, 1)
    }

    func testSignOutClearsSessionCookies() async throws {
        let keychain = InMemoryKeychainStore()
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: "https://example.test",
            client: client
        )
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: server))

        await manager.signOut()

        XCTAssertEqual(HTTPCookieStorage.shared.cookies?.isEmpty, true)
        XCTAssertEqual(manager.state, .unconfigured)
    }

    // MARK: - Per-server isolation (#16)

    func testSignOutClearsOnlyActiveServerCookies() async throws {
        let keychain = InMemoryKeychainStore()
        let serverA = try XCTUnwrap(URL(string: "https://a.test"))
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))
        let manager = try await makeLoggedInManager(keychain: keychain, serverURLString: "https://a.test")
        // Both servers hold a session cookie in the shared jar (which both APIClient
        // and SSEClient stream against).
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverA, value: "a-cookie"))
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverB, value: "b-cookie"))

        await manager.signOut()

        // A's cookie is cleared; B (a different host) is untouched.
        XCTAssertTrue(HTTPCookieStorage.shared.cookies(for: serverA)?.isEmpty ?? true)
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: serverB)?.map(\.value), ["b-cookie"])
    }

    func testUnauthorizedClearsOnlyActiveServerCookies() async throws {
        let keychain = InMemoryKeychainStore()
        let serverA = try XCTUnwrap(URL(string: "https://a.test"))
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))
        let client = ProbeAuthClient(server: serverA, probes: [.succeed, .expired])
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: serverA.absoluteString,
            client: client
        )
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverA, value: "a-cookie"))
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverB, value: "b-cookie"))

        manager.handleAPIError(DirectHermesAuthError.sessionExpired)
        await waitForProbe(client, count: 2)

        // Only the active server's auth is affected by its 401.
        XCTAssertEqual(manager.state, .loggedOut(server: serverA))
        XCTAssertTrue(HTTPCookieStorage.shared.cookies(for: serverA)?.isEmpty ?? true)
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: serverB)?.map(\.value), ["b-cookie"])
    }

    func testSignOutLeavesOtherServerHeadersAndRegistryIntact() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory()
        // Pre-seed server B: a registry entry plus its scoped custom headers.
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))
        registry.activate(url: serverB)
        let bHeaders = try XCTUnwrap([CustomHeader(name: "X-B", value: "b-token")].encodedForStorage())
        try keychain.save(bHeaders, forKey: .customHeaders, scope: "https://b.test")

        // Sign in to server A as the active server, with its own scoped headers.
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            headerStore: CustomHeaderStore(),
            serverRegistry: registry
        )
        await manager.configure(
            serverURLString: "https://a.test",
            password: "",
            customHeaders: [CustomHeader(name: "X-A", value: "a-token")]
        )
        XCTAssertNotNil(keychain.scopedValue(.customHeaders, scope: "https://a.test"))

        await manager.signOut()

        // A's scoped headers + registry entry are gone; B's are untouched.
        XCTAssertNil(keychain.scopedValue(.customHeaders, scope: "https://a.test"))
        XCTAssertNotNil(keychain.scopedValue(.customHeaders, scope: "https://b.test"))
        XCTAssertEqual(registry.servers.map(\.id), ["https://b.test"])
    }

    // MARK: - Multi-server switch / remove / identity (#17)

    func testSwitchActiveServerMakesItActiveAndOptimisticallyLoggedIn() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, _, bAccount) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))

        manager.switchActiveServer(to: bAccount)

        XCTAssertEqual(manager.state, .loggedIn(server: serverB))
        XCTAssertEqual(keychain.savedValues[.serverURL], "https://b.test")
        XCTAssertEqual(registry.activeServerID, "https://b.test")
        XCTAssertEqual(manager.activeServerID, "https://b.test")
    }

    func testSwitchToTheAlreadyActiveServerIsANoOp() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, aAccount, _) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let serverA = try XCTUnwrap(URL(string: "https://a.test"))

        manager.switchActiveServer(to: aAccount)

        XCTAssertEqual(manager.state, .loggedIn(server: serverA))
        XCTAssertEqual(registry.activeServerID, "https://a.test")
    }

    func testRemoveActiveServerAutoSwitchesToRemaining() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, aAccount, _) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))

        await manager.removeServer(aAccount)

        XCTAssertEqual(manager.state, .loggedIn(server: serverB))
        XCTAssertEqual(registry.servers.map(\.id), ["https://b.test"])
        XCTAssertEqual(keychain.savedValues[.serverURL], "https://b.test")
    }

    func testRemoveLastServerReturnsToOnboarding() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry
        )
        await manager.configure(serverURLString: "https://a.test", password: "")
        let aAccount = try XCTUnwrap(registry.servers.first { $0.id == "https://a.test" })

        await manager.removeServer(aAccount)

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertTrue(registry.servers.isEmpty)
        XCTAssertNil(keychain.savedValues[.serverURL])
    }

    func testRemoveNonActiveServerLeavesActiveLoggedIn() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, _, bAccount) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let serverA = try XCTUnwrap(URL(string: "https://a.test"))

        await manager.removeServer(bAccount)

        XCTAssertEqual(manager.state, .loggedIn(server: serverA))
        XCTAssertEqual(registry.servers.map(\.id), ["https://a.test"])
        XCTAssertEqual(keychain.savedValues[.serverURL], "https://a.test")
    }

    func testRemoveNonActiveServerClearsOnlyItsCookies() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, _, bAccount) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let serverA = try XCTUnwrap(URL(string: "https://a.test"))
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverA, value: "a-cookie"))
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverB, value: "b-cookie"))

        await manager.removeServer(bAccount)

        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: serverA)?.map(\.value), ["a-cookie"])
        XCTAssertTrue(HTTPCookieStorage.shared.cookies(for: serverB)?.isEmpty ?? true)
    }

    func testSignOutWithRemainingServerAutoSwitches() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, _, _) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))

        await manager.signOut()

        XCTAssertEqual(manager.state, .loggedIn(server: serverB))
        XCTAssertEqual(registry.servers.map(\.id), ["https://b.test"])
    }

    func testConfiguringASecondServerAddsItAndMakesItActive() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry
        )

        await manager.configure(serverURLString: "https://a.test", password: "")
        await manager.configure(serverURLString: "https://b.test", password: "")

        XCTAssertEqual(Set(manager.servers.map(\.id)), ["https://a.test", "https://b.test"])
        XCTAssertEqual(manager.activeServerID, "https://b.test")
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://b.test"))))
    }

    func testAddServerNeedsPasswordWhenAuthEnabledAndNoPassword() async {
        let manager = AuthManager(
            keychain: InMemoryKeychainStore(),
            probeClientFactory: { _, _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false)) },
            serverRegistry: ServerRegistry.inMemory()
        )

        let outcome = await manager.addServer(serverURLString: "https://needs-pw.test", username: "test-user", password: "")

        XCTAssertEqual(outcome, .needsPassword)
        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertTrue(manager.servers.isEmpty)
    }

    func testAddServerRejectsAnAlreadyConfiguredURL() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry
        )
        await manager.configure(serverURLString: "https://a.test", password: "")

        let outcome = await manager.addServer(serverURLString: "https://a.test", password: "")

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(manager.lastErrorMessage, "This server is already configured.")
        XCTAssertEqual(manager.servers.map(\.id), ["https://a.test"])
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://a.test"))))
    }

    func testAddServerSucceedsAndSwitchesActive() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            probeClientFactory: { _, _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry
        )
        await manager.configure(serverURLString: "https://a.test", password: "")

        let outcome = await manager.addServer(serverURLString: "https://b.test", password: "")

        XCTAssertEqual(outcome, .added(try XCTUnwrap(URL(string: "https://b.test"))))
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://b.test"))))
        XCTAssertEqual(Set(manager.servers.map(\.id)), ["https://a.test", "https://b.test"])
        XCTAssertEqual(keychain.savedValues[.serverURL], "https://b.test")
    }

    func testAddServerFailureKeepsActiveServerAndItsHeaders() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let clientA = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let clientB = MockAuthAPIClient(
            authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false),
            loginResponse: LoginResponse(ok: false, message: nil, error: "nope")
        )
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { $0.absoluteString.contains("a.test") ? clientA : clientB },
            probeClientFactory: { url, _ in url.absoluteString.contains("a.test") ? clientA : clientB },
            headerStore: CustomHeaderStore(),
            serverRegistry: registry
        )
        await manager.configure(
            serverURLString: "https://a.test",
            username: "test-user",
            password: "secret",
            customHeaders: [CustomHeader(name: "X-A", value: "a-token")]
        )
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://a.test"))))

        let outcome = await manager.addServer(
            serverURLString: "https://b.test",
            username: "test-user",
            password: "wrong",
            customHeaders: [CustomHeader(name: "X-B", value: "b-token")]
        )

        XCTAssertEqual(outcome, .failed)
        // The active server, its state, registry, and live headers are untouched.
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://a.test"))))
        XCTAssertEqual(manager.servers.map(\.id), ["https://a.test"])
        XCTAssertEqual(manager.currentCustomHeaders.map(\.name), ["X-A"])
        XCTAssertEqual(manager.currentCustomHeaders.map(\.value), ["a-token"])
    }

    func testServersSnapshotMirrorsRegistry() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, _, _) = try await makeTwoServerManager(keychain: keychain, registry: registry)

        XCTAssertEqual(Set(manager.servers.map(\.id)), ["https://a.test", "https://b.test"])
        XCTAssertEqual(manager.activeServerID, "https://a.test")
    }

    func testNonDefaultHTTPSPortIsAcceptedWhenHostnameIsUnique() async throws {
        let server = try XCTUnwrap(URL(string: "https://example.test:8443"))
        XCTAssertNoThrow(try AuthManager.validateDirectHermesOrigin(server))
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { url in
                XCTAssertEqual(url, server)
                return MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
            },
            serverRegistry: registry,
            cookieOriginLedger: DirectHermesCookieOriginLedger()
        )

        await manager.configure(serverURLString: server.absoluteString, password: "")

        XCTAssertEqual(manager.state, .loggedIn(server: server))
        XCTAssertEqual(registry.servers.map(\.id), [server.absoluteString])
    }

    func testGenuinelyUnownedHostnamePurgesStaleCookieBeforeClientCreation() async throws {
        let server = try XCTUnwrap(URL(string: "https://unowned-cookie.test:8443"))
        let staleCookie = try makeSessionCookie(for: server, value: "must-not-cross-origin")
        HTTPCookieStorage.shared.setCookie(staleCookie)
        defer { HTTPCookieStorage.shared.deleteCookie(staleCookie) }
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        var clientCreated = false
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { url in
                clientCreated = true
                XCTAssertEqual(url, server)
                XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: url)?.isEmpty ?? true, true)
                return MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
            },
            serverRegistry: registry,
            cookieOriginLedger: DirectHermesCookieOriginLedger()
        )

        _ = try await manager.testConnection(serverURLString: server.absoluteString)

        XCTAssertTrue(clientCreated)
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: server)?.isEmpty ?? true, true)
    }

    func testSameHostnameDifferentPortIsRefusedBeforeProbeOrHeaderMutation() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        registry.activate(url: try XCTUnwrap(URL(string: "https://example.test")))
        let headers = CustomHeaderStore()
        headers.replace(with: [CustomHeader(name: "X-Existing", value: "keep")])
        var clientCreations = 0
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in
                clientCreations += 1
                return MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
            },
            probeClientFactory: { _, _ in
                clientCreations += 1
                return MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
            },
            headerStore: headers,
            serverRegistry: registry,
            cookieOriginLedger: DirectHermesCookieOriginLedger()
        )

        do {
            _ = try await manager.testConnection(
                serverURLString: "https://example.test:8443",
                customHeaders: [CustomHeader(name: "X-New", value: "must-not-apply")]
            )
            XCTFail("Expected the shared-cookie hostname guard to refuse the probe")
        } catch {
            XCTAssertEqual(error as? AuthManager.ServerOriginError, .hostnameAlreadyConfigured)
        }
        await manager.configure(serverURLString: "https://example.test:8443", password: "")
        let outcome = await manager.addServer(serverURLString: "https://example.test:8443", password: "")

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(clientCreations, 0)
        XCTAssertEqual(headers.snapshot(), [CustomHeader(name: "X-Existing", value: "keep")])
        XCTAssertEqual(registry.servers.map(\.id), ["https://example.test"])
        XCTAssertEqual(manager.lastErrorMessage, AuthManager.ServerOriginError.hostnameAlreadyConfigured.localizedDescription)
    }

    func testRestoreAndSwitchRefusePersistedSameHostnameOrigins() throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let defaultOrigin = try XCTUnwrap(URL(string: "https://example.test"))
        let alternatePort = try XCTUnwrap(URL(string: "https://example.test:8443"))
        registry.activate(url: defaultOrigin)
        registry.activate(url: alternatePort)
        try keychain.save(alternatePort.absoluteString, forKey: .serverURL)
        let manager = AuthManager(
            keychain: keychain,
            serverRegistry: registry,
            cookieOriginLedger: DirectHermesCookieOriginLedger()
        )

        XCTAssertEqual(manager.state, .unconfigured)
        let defaultAccount = try XCTUnwrap(registry.servers.first { $0.id == defaultOrigin.absoluteString })
        manager.switchActiveServer(to: defaultAccount)
        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertEqual(manager.lastErrorMessage, AuthManager.ServerOriginError.hostnameAlreadyConfigured.localizedDescription)
    }

    func testInflightConfigureReservesHostnameAgainstDifferentPortAdd() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let heldClient = ProbeAuthClient(
            server: try XCTUnwrap(URL(string: "https://race.test")),
            probes: [.manual]
        )
        var alternateClientCreations = 0
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in heldClient },
            probeClientFactory: { _, _ in
                alternateClientCreations += 1
                return MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
            },
            serverRegistry: registry,
            cookieOriginLedger: DirectHermesCookieOriginLedger()
        )
        let configure = Task {
            await manager.configure(
                serverURLString: "https://race.test",
                username: "test-user",
                password: "secret"
            )
        }
        await waitForProbe(heldClient, count: 1)

        let outcome = await manager.addServer(serverURLString: "https://race.test:8443", password: "")

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(alternateClientCreations, 0)
        heldClient.releaseProbe(1, with: .success(()))
        await configure.value
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://race.test"))))
    }

    func testRemovedOriginTombstoneRefusesDifferentPortUntilProcessRestart() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let ledger = DirectHermesCookieOriginLedger()
        var clientCreations = 0
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in
                clientCreations += 1
                return MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
            },
            probeClientFactory: { _, _ in
                clientCreations += 1
                return MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
            },
            serverRegistry: registry,
            cookieOriginLedger: ledger
        )
        await manager.configure(serverURLString: "https://retired.test", password: "")
        let account = try XCTUnwrap(manager.servers.first)
        await manager.removeServer(account)
        let creationsAfterRemoval = clientCreations

        let outcome = await manager.addServer(serverURLString: "https://retired.test:8443", password: "")

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(clientCreations, creationsAfterRemoval)
        XCTAssertEqual(manager.lastErrorMessage, AuthManager.ServerOriginError.hostnameAlreadyConfigured.localizedDescription)
    }

    func testUpdateServerIdentityPersistsAndMirrorsTheActiveServer() async throws {
        let keychain = InMemoryKeychainStore()
        let defaults = UserDefaults.ephemeral()
        let registry = ServerRegistry(keychain: keychain, identityDefaults: defaults)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry
        )
        await manager.configure(serverURLString: "https://a.test", password: "")
        let aAccount = try XCTUnwrap(registry.servers.first { $0.id == "https://a.test" })

        manager.updateServerIdentity(
            aAccount,
            displayName: "Work",
            initials: "WK",
            headerLogoColorHex: "#5B7CFF"
        )

        let updated = try XCTUnwrap(manager.servers.first { $0.id == "https://a.test" })
        XCTAssertEqual(updated.displayName, "Work")
        XCTAssertEqual(updated.initials, "WK")
        XCTAssertEqual(updated.headerLogoColorHex, "#5B7CFF")
        // The active server's identity is mirrored into the global defaults.
        XCTAssertEqual(defaults.string(forKey: SessionIdentitySettings.displayNameKey), "Work")
        XCTAssertEqual(defaults.string(forKey: HeaderLogoColor.storageKey), "#5B7CFF")
    }

    func testRetiredSidecarMetadataDoesNotDisturbDirectAccountsOnRestoreAndSwitch() throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let a = try XCTUnwrap(URL(string: "https://a.test"))
        let b = try XCTUnwrap(URL(string: "https://b.test"))
        for server in [a, b] {
            registry.activate(url: server)
            var account = try XCTUnwrap(registry.activeServer)
            account.officialAPIURLString = "https://retired-sidecar.test"
            registry.update(account)
            try keychain.save("legacy-test-key", forKey: .officialAPIKey, scope: server.absoluteString)
            let headers = [CustomHeader(name: "X-Test-Server", value: server.host!)]
            try keychain.save(try XCTUnwrap(headers.encodedForStorage()), forKey: .customHeaders, scope: server.absoluteString)
            HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: server, value: "direct-test-cookie"))
        }
        try keychain.save(a.absoluteString, forKey: .serverURL)
        let headers = CustomHeaderStore()
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in
                XCTFail("Restoring or switching a direct account must not probe a retired sidecar")
                return MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
            },
            headerStore: headers,
            serverRegistry: registry
        )

        XCTAssertEqual(manager.state, .loggedIn(server: a))
        XCTAssertEqual(headers.snapshot().first?.value, "a.test")
        manager.switchActiveServer(to: try XCTUnwrap(registry.servers.first { $0.id == b.absoluteString }))
        XCTAssertEqual(manager.state, .loggedIn(server: b))
        XCTAssertEqual(headers.snapshot().first?.value, "b.test")
        XCTAssertEqual(registry.servers.count, 2)
        for server in [a, b] {
            XCTAssertEqual(keychain.scopedValue(.officialAPIKey, scope: server.absoluteString), "legacy-test-key")
            XCTAssertEqual(registry.servers.first { $0.id == server.absoluteString }?.officialAPIURLString, "https://retired-sidecar.test")
            XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: server)?.first?.value, "direct-test-cookie")
        }
    }

    /// Builds a manager with two registered servers: `a.test` signed in + active,
    /// `b.test` present but inactive. Returns the manager and both accounts.
    private func makeTwoServerManager(
        keychain: InMemoryKeychainStore,
        registry: ServerRegistry
    ) async throws -> (AuthManager, ServerAccount, ServerAccount) {
        // Pre-seed B (becomes inactive once A signs in), then sign in to A.
        registry.activate(url: try XCTUnwrap(URL(string: "https://b.test")))
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry
        )
        await manager.configure(serverURLString: "https://a.test", password: "")

        guard case .loggedIn = manager.state else {
            XCTFail("Expected loggedIn after configure, got \(manager.state)")
            throw PreconditionFailure()
        }

        let aAccount = try XCTUnwrap(registry.servers.first { $0.id == "https://a.test" })
        let bAccount = try XCTUnwrap(registry.servers.first { $0.id == "https://b.test" })
        return (manager, aAccount, bAccount)
    }

    private func makeLoggedInManager(
        keychain: InMemoryKeychainStore,
        serverURLString: String,
        client providedClient: (any AuthAPIClient)? = nil,
        logoutTimeout: Duration = .seconds(5),
        serverRegistry: ServerRegistry? = nil
    ) async throws -> AuthManager {
        let client = providedClient
            ?? MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            logoutTimeout: logoutTimeout,
            serverRegistry: serverRegistry ?? ServerRegistry.inMemory()
        )

        await manager.configure(serverURLString: serverURLString, username: "test-user", password: "secret")

        guard case .loggedIn = manager.state else {
            XCTFail("Expected loggedIn state after configure, got \(manager.state)")
            throw PreconditionFailure()
        }

        return manager
    }

    private func waitForProbe(_ client: ProbeAuthClient, count: Int) async {
        for _ in 0..<100 {
            if client.probeCallCount >= count {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for protected probe (count).")
    }

    private func makeSessionCookie(for server: URL, value: String = "stale-session-token") throws -> HTTPCookie {
        try XCTUnwrap(
            HTTPCookie(properties: [
                .domain: try XCTUnwrap(server.host),
                .path: "/",
                .name: "hermes_session",
                .value: value,
            ])
        )
    }

    private final class ProbeAuthClient: AuthAPIClient, @unchecked Sendable {
        enum ProbeBehavior {
            case succeed
            case expired
            case network
            case wait
            case manual
        }

        let server: URL
        private let lock = NSLock()
        private var probes: [ProbeBehavior]
        private var nextProbe = 0
        private var loginCount = 0
        private var waitingProbes: [Int: CheckedContinuation<Void, Error>] = [:]

        init(server: URL, probes: [ProbeBehavior]) {
            self.server = server
            self.probes = probes
        }

        var probeCallCount: Int {
            withLock { nextProbe }
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        func releaseProbe(_ number: Int, with result: Result<Void, Error>) {
            let continuation = withLock { waitingProbes.removeValue(forKey: number) }
            continuation?.resume(with: result)
        }

        func directStatus() async throws -> DirectHermesStatusResponse {
            DirectHermesStatusResponse(
                version: nil,
                releaseDate: nil,
                authRequired: true,
                authProviders: ["basic"],
                authFlows: nil,
                overall: nil
            )
        }

        func directProviders() async throws -> DirectHermesAuthProvidersResponse {
            DirectHermesAuthProvidersResponse(
                providers: [DirectHermesAuthProvider(name: "basic", displayName: nil, supportsPassword: true)]
            )
        }

        func directPasswordLogin(
            username: String,
            password: String,
            provider: String
        ) async throws -> DirectHermesPasswordLoginResponse {
            let value = withLock {
                loginCount += 1
                return "login-\(loginCount)"
            }
            guard let host = server.host else { throw APIError.invalidServerURL }
            if let cookie = HTTPCookie(properties: [
                .domain: host,
                .path: "/",
                .name: "hermes_session",
                .value: value
            ]) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            return DirectHermesPasswordLoginResponse(ok: true, next: nil)
        }

        func directProtectedProbe() async throws {
            let (index, behavior) = withLock {
                let index = nextProbe
                nextProbe += 1
                let behavior = index < probes.count ? probes[index] : .succeed
                return (index + 1, behavior)
            }

            switch behavior {
            case .succeed:
                return
            case .expired:
                throw DirectHermesAuthError.sessionExpired
            case .network:
                throw APIError.network(underlying: URLError(.notConnectedToInternet))
            case .wait:
                try await Task.sleep(for: .seconds(3600))
            case .manual:
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    withLock { waitingProbes[index] = continuation }
                }
            }
        }

        func directLogout() async throws {}
    }
}
