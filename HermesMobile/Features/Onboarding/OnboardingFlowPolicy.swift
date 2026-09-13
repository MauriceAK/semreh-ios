import Foundation

enum OnboardingFlowPolicy {
    static let pageCount = 2
    static let connectPageIndex = 1
    static let serverGuidanceSteps: [(title: String, detail: String)] = [
        (
            String(localized: "Use first-party Hermes"),
            String(localized: "Install and configure Hermes using the documentation for your installed version. Semreh does not install or replace Hermes for you.")
        ),
        (
            String(localized: "Run the Hermes server"),
            String(localized: "Use the stock `hermes serve` workflow documented by your installed Hermes version. Preserve any existing configuration and managed service.")
        ),
        (
            String(localized: "Use authenticated HTTPS"),
            String(localized: "Ask your server administrator for a dedicated authenticated HTTPS address and sign-in. Tailscale is the recommended private-network option, but another trusted HTTPS deployment can work.")
        ),
    ]

    static let tailscaleAppStoreURL = URL(string: "itms-apps://apps.apple.com/us/app/tailscale/id1470499037")!

    static let tailscaleAppStoreFallbackURL = URL(string: "https://apps.apple.com/us/app/tailscale/id1470499037")!

    static func primaryButtonTitle(for page: Int) -> String {
        switch page {
        case 0:
            return String(localized: "Get Started")
        case connectPageIndex:
            return String(localized: "Connect")
        default:
            return String(localized: "Continue")
        }
    }

    static func shouldClearConnectFocusWhenLeavingPage(_ page: Int) -> Bool {
        page != connectPageIndex
    }

    static func initialPage(hasSavedServer: Bool) -> Int {
        hasSavedServer ? connectPageIndex : 0
    }
}
