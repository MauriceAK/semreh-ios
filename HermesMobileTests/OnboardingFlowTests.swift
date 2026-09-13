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
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 0), "Get Started")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 1), "Set Up")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 2), "Continue")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 3), "Continue")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 4), "Connect")
    }

    func testConnectFocusClearsWhenLeavingConnectPage() {
        XCTAssertTrue(OnboardingFlowPolicy.shouldClearConnectFocusWhenLeavingPage(3))
        XCTAssertFalse(OnboardingFlowPolicy.shouldClearConnectFocusWhenLeavingPage(OnboardingFlowPolicy.connectPageIndex))
    }

    func testServerShortcutShowsBeforeConnectPageOnly() {
        XCTAssertTrue(OnboardingFlowPolicy.showsServerShortcut(for: 0))
        XCTAssertTrue(OnboardingFlowPolicy.showsServerShortcut(for: 3))
        XCTAssertFalse(OnboardingFlowPolicy.showsServerShortcut(for: OnboardingFlowPolicy.connectPageIndex))
    }

    func testServerGuidanceUsesFirstPartyExistingServerContract() {
        XCTAssertEqual(OnboardingFlowPolicy.serverGuidancePageIndex, 2)
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
}
