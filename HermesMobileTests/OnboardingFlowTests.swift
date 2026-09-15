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
