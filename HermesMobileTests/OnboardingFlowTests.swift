import XCTest
@testable import HermesMobile

final class OnboardingFlowTests: XCTestCase {
    @MainActor
    func testConfirmedPairingOriginClearsPriorServerAuthenticationStateWithoutConnecting() throws {
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = "https://old.example.test"
        viewModel.username = "old-user"
        viewModel.password = "old-password"
        viewModel.customHeaders = [CustomHeader(name: "Authorization", value: "Bearer old")]
        viewModel.authStatus = AuthStatusResponse(authEnabled: true, passwordAuthEnabled: true)
        viewModel.connectionMessage = "old success"
        viewModel.errorMessage = "old error"

        let pairing = try PairingImport.validateOrigin("https://new.example.test:8443")
        viewModel.applyConfirmedPairingOrigin(pairing)

        XCTAssertEqual(viewModel.serverURLString, "https://new.example.test:8443")
        XCTAssertEqual(viewModel.username, "")
        XCTAssertEqual(viewModel.password, "")
        XCTAssertTrue(viewModel.customHeaders.isEmpty)
        XCTAssertNil(viewModel.authStatus)
        XCTAssertNil(viewModel.connectionMessage)
        XCTAssertNil(viewModel.errorMessage)
        // No AuthManager is accepted by applyConfirmedPairingOrigin; connection
        // and authentication remain exclusively explicit follow-up actions.
    }

    @MainActor
    func testSavedServerReauthenticationPrefillsOriginAndHeadersButNotCredentials() throws {
        let server = try XCTUnwrap(URL(string: "https://saved.example.test"))
        let headers = [CustomHeader(name: "X-Forwarded-Auth", value: "fixture-header")]
        let viewModel = OnboardingViewModel(
            savedServer: server,
            savedHeaders: headers,
            initialErrorMessage: "Your session expired. Sign in again."
        )

        XCTAssertEqual(viewModel.serverURLString, server.absoluteString)
        XCTAssertEqual(viewModel.customHeaders, headers)
        XCTAssertEqual(viewModel.username, "")
        XCTAssertEqual(viewModel.password, "")
        XCTAssertEqual(viewModel.errorMessage, "Your session expired. Sign in again.")
        XCTAssertNil(viewModel.authStatus)
        XCTAssertEqual(OnboardingFlowPolicy.initialPage(hasSavedServer: true), OnboardingFlowPolicy.connectPageIndex)
    }

    @MainActor
    func testRejectedFreshLoginLeavesOriginAndErrorAvailableForRetry() async throws {
        let server = try XCTUnwrap(URL(string: "https://retry.example.test"))
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(
            authStatus: AuthStatusResponse(authEnabled: true, passwordAuthEnabled: true),
            loginResponse: LoginResponse(ok: false, message: nil, error: "invalid_credentials")
        )
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            serverRegistry: .inMemory(keychain: keychain),
            cookieOriginLedger: DirectHermesCookieOriginLedger()
        )
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = server.absoluteString
        viewModel.username = "fixture-user"
        viewModel.password = "incorrect"
        viewModel.authStatus = AuthStatusResponse(authEnabled: true, passwordAuthEnabled: true)

        await viewModel.connect(authManager: manager)

        XCTAssertEqual(viewModel.serverURLString, server.absoluteString)
        XCTAssertEqual(viewModel.errorMessage, "The Hermes login was not accepted.")
        // A rejected *fresh* login stays .unconfigured so the typed
        // username/password survive for retry (issue #21); it must not flip
        // to .loggedOut and destroy the onboarding view model.
        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertNil(keychain.savedValues[.serverURL])
        XCTAssertEqual(client.loginUsernames, ["fixture-user"])
    }

    func testPairingPayloadRequiresExactVersionedSecretFreeSchema() throws {
        let payload = #"{"type":"semreh-pairing","version":1,"origin":"https://Example.test:8443"}"#

        let pairing = try PairingImport.parse(payload)

        XCTAssertEqual(pairing.origin, URL(string: "https://example.test:8443"))
        XCTAssertThrowsError(
            try PairingImport.parse(#"{"type":"semreh-pairing","version":1,"origin":"https://example.test","password":"secret"}"#),
            "Pairing imports must not accept credential-bearing or extra fields."
        )
        XCTAssertThrowsError(
            try PairingImport.parse(#"{"type":"semreh-pairing","version":2,"origin":"https://example.test"}"#),
            "Unknown pairing payload versions must fail closed."
        )
        XCTAssertThrowsError(
            try PairingImport.parse(#"{"type":"semreh-pairing","version":true,"origin":"https://example.test"}"#),
            "A Boolean must not be accepted as the numeric version."
        )
    }

    func testPairingPayloadAcceptsPlainHTTPSOriginQR() throws {
        let rawOrigin = "https://EXAMPLE.test:8443/"

        let parsed = try PairingImport.parse(rawOrigin)
        let validated = try PairingImport.validateOrigin(rawOrigin)

        XCTAssertEqual(parsed, validated)
        XCTAssertEqual(parsed.origin, URL(string: "https://example.test:8443"))
    }

    func testPairingPayloadRejectsUnsafePlainOriginQRs() {
        for rawOrigin in [
            "http://example.test",
            "https://user:password@example.test",
            "https://example.test/path",
            "https://example.test?token=secret",
            "https://example.test#fragment",
            "https://example.test:0",
            "https://example.test:65536",
            "https://münich.example",
            "https://xn--bcher-kva.example",
        ] {
            XCTAssertThrowsError(
                try PairingImport.parse(rawOrigin),
                "Unexpectedly accepted unsafe plain QR origin: \(rawOrigin)"
            )
        }
    }

    func testPairingOriginAcceptsOnlyRootHTTPSOriginsAndNormalizesHostAndDefaultPort() throws {
        let defaultPort = try PairingImport.validateOrigin("https://EXAMPLE.test:443")
        XCTAssertEqual(defaultPort.origin, URL(string: "https://example.test"))

        let nonDefaultPort = try PairingImport.validateOrigin("https://example.test:8443/")
        XCTAssertEqual(nonDefaultPort.origin, URL(string: "https://example.test:8443"))

        for origin in [
            "http://example.test",
            "https://user:password@example.test",
            "https://example.test/api",
            "https://example.test?token=secret",
            "https://example.test#fragment",
            "https://example.test:",
            "https://example.test:0",
            "https://example.test:65536",
            "https://münich.example",
            "https://xn--bcher-kva.example",
        ] {
            XCTAssertThrowsError(
                try PairingImport.validateOrigin(origin),
                "Unexpectedly accepted unsupported pairing origin: \(origin)"
            )
        }
    }

    func testPairingScanPolicyKeepsScanningAfterInvalidCodeAndConsumesOneValidCode() throws {
        var policy = PairingScanPolicy()
        policy.setActive(true)
        let generation = policy.generation
        let payload = "https://example.test"

        XCTAssertThrowsError(try policy.admit("not a pairing code", generation: generation))
        XCTAssertFalse(policy.consumed)

        let pairing = try PairingImport.parse(payload)
        let accepted = try XCTUnwrap(policy.admit(payload, generation: generation))
        XCTAssertEqual(accepted, pairing)
        XCTAssertTrue(policy.consumed)
        XCTAssertNil(try policy.admit(payload, generation: generation))
    }

    func testPairingScanPolicyRejectsCallbacksAfterScannerDismissalOrFromOldGeneration() throws {
        var policy = PairingScanPolicy()
        policy.setActive(true)
        let dismissedGeneration = policy.generation
        let payload = #"{"type":"semreh-pairing","version":1,"origin":"https://example.test"}"#

        policy.setActive(false)
        XCTAssertNil(try policy.admit(payload, generation: dismissedGeneration))

        policy.setActive(true)
        XCTAssertNotEqual(policy.generation, dismissedGeneration)
        XCTAssertNil(try policy.admit(payload, generation: dismissedGeneration))
        XCTAssertNotNil(try policy.admit(payload, generation: policy.generation))
    }

    func testPrimaryButtonTitlesFollowPagerFlow() {
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: OnboardingFlowPolicy.welcomePageIndex), "Get Started")
        XCTAssertEqual(
            OnboardingFlowPolicy.primaryButtonTitle(for: OnboardingFlowPolicy.connectPageIndex),
            "Connect"
        )
        XCTAssertEqual(OnboardingFlowPolicy.pageCount, 2)
    }

    func testConnectFocusClearsWhenLeavingConnectPage() {
        XCTAssertTrue(OnboardingFlowPolicy.shouldClearConnectFocusWhenLeavingPage(0))
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldClearConnectFocusWhenLeavingPage(
                OnboardingFlowPolicy.welcomePageIndex
            )
        )
        XCTAssertFalse(OnboardingFlowPolicy.shouldClearConnectFocusWhenLeavingPage(OnboardingFlowPolicy.connectPageIndex))
    }

    func testFreshSetupStartsAtWelcomeThenConnectAndSavedServerSkipsIntro() {
        XCTAssertEqual(
            OnboardingFlowPolicy.initialPage(hasSavedServer: false),
            OnboardingFlowPolicy.welcomePageIndex
        )
        XCTAssertEqual(OnboardingFlowPolicy.initialPage(hasSavedServer: true), OnboardingFlowPolicy.connectPageIndex)
        XCTAssertEqual(OnboardingFlowPolicy.connectPageIndex, OnboardingFlowPolicy.welcomePageIndex + 1)
    }

    func testServerGuidanceUsesFirstPartyExistingServerContract() {
        let guidance = OnboardingFlowPolicy.serverGuidanceSteps
            .flatMap { [$0.title, $0.detail] }.joined(separator: " ")
        XCTAssertEqual(OnboardingFlowPolicy.serverGuidanceSteps.count, 3)
        XCTAssertTrue(guidance.contains("first-party Hermes"))
        XCTAssertTrue(guidance.contains("installed version"))
        XCTAssertTrue(guidance.contains("hermes serve"))
        XCTAssertTrue(guidance.contains("dedicated authenticated HTTPS"))
        XCTAssertTrue(guidance.contains("Tailscale is the recommended"))
        XCTAssertTrue(guidance.contains("another trusted HTTPS deployment can work"))
    }

    func testTailscaleAppStoreURLUsesITMSDeepLink() {
        XCTAssertEqual(
            OnboardingFlowPolicy.tailscaleAppStoreURL.absoluteString,
            "itms-apps://apps.apple.com/us/app/tailscale/id1470499037"
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.tailscaleAppStoreFallbackURL.absoluteString,
            "https://apps.apple.com/us/app/tailscale/id1470499037"
        )
    }

    func testConnectPageIndexIsFinalPagerPage() {
        XCTAssertEqual(OnboardingFlowPolicy.connectPageIndex, OnboardingFlowPolicy.pageCount - 1)
    }

    func testFirstRunBackNavigationReturnsFromConnectToWelcomeAndSavedServerSkipsIntro() {
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowBackButton(
                for: OnboardingFlowPolicy.welcomePageIndex,
                hasSavedServer: false
            )
        )
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldShowBackButton(
                for: OnboardingFlowPolicy.connectPageIndex,
                hasSavedServer: false
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowBackButton(
                for: OnboardingFlowPolicy.connectPageIndex,
                hasSavedServer: true
            )
        )

        XCTAssertNil(
            OnboardingFlowPolicy.previousPage(
                for: OnboardingFlowPolicy.welcomePageIndex,
                hasSavedServer: false
            )
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.previousPage(
                for: OnboardingFlowPolicy.connectPageIndex,
                hasSavedServer: false
            ),
            OnboardingFlowPolicy.welcomePageIndex
        )
        XCTAssertNil(
            OnboardingFlowPolicy.previousPage(
                for: OnboardingFlowPolicy.connectPageIndex,
                hasSavedServer: true
            )
        )
    }

    @MainActor
    func testFailedFirstLoginRetainsOriginForRetryButSavedReauthenticationDoesNot() {
        let server = URL(string: "https://server.example.com")!
        let anotherServer = URL(string: "https://other.example.com")!
        let freshOnboardingOrigin = OnboardingFlowPolicy.isFreshOnboardingOrigin(.unconfigured)

        XCTAssertTrue(freshOnboardingOrigin)
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldStartPostLoginPersonalization(
                hasFreshOnboardingOrigin: freshOnboardingOrigin,
                to: .loggedIn(server: server)
            )
        )

        // An interrupted probe remains unconfigured and a rejected password moves
        // to loggedOut. Neither marks personalization pending, but the separate
        // fresh origin survives so the next successful login can present it.
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldStartPostLoginPersonalization(
                hasFreshOnboardingOrigin: freshOnboardingOrigin,
                to: .unconfigured
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldStartPostLoginPersonalization(
                hasFreshOnboardingOrigin: freshOnboardingOrigin,
                to: .loggedOut(server: server)
            )
        )
        XCTAssertFalse(OnboardingFlowPolicy.isFreshOnboardingOrigin(.loggedOut(server: server)))
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldStartPostLoginPersonalization(
                hasFreshOnboardingOrigin: freshOnboardingOrigin,
                to: .loggedIn(server: server)
            )
        )

        // Existing-server reauthentication and server switching are not first run.
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldStartPostLoginPersonalization(
                hasFreshOnboardingOrigin: false,
                to: .loggedIn(server: server)
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldStartPostLoginPersonalization(
                hasFreshOnboardingOrigin: false,
                to: .loggedIn(server: anotherServer)
            )
        )
    }

    func testAppearanceUsesExistingPersistedPreferenceKeysAndChoices() {
        XCTAssertEqual(AppTheme.storageKey, "appTheme")
        XCTAssertEqual(AppAccent.storageKey, "appearance.appAccent")
        XCTAssertEqual(
            AppAccent.allCases.map(\.rawValue),
            ["warm", "violet", "blue", "mint", "rose"]
        )
        XCTAssertEqual(
            AppAccent.allCases.map(\.title),
            ["Warm", "Violet", "Blue", "Mint", "Rose"]
        )
    }
}
