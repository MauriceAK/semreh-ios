import SwiftUI

/// BrowserLab entry point.
///
/// A standalone development fixture for the remote browser workspace. It is
/// not shipped: unique bundle ID `com.mauricekenon.semreh.browserlab`,
/// always carries the simulated-session banner, and only ever talks to the
/// scripted `SimulatedBrowserAdapter`.
@main
struct BrowserLabApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserLabView()
        }
    }
}
