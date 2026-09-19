import XCTest
@testable import HermesMobile

@MainActor
final class CliSessionsSyncModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let serverA = URL(string: "https://alpha.example.test")!
    private let serverB = URL(string: "https://beta.example.test")!

    override func setUp() {
        super.setUp()
        suiteName = "CliSessionsSyncModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testTogglePersistsImmediatelyForRelaunch() {
        let model = CliSessionsSyncModel(server: serverA, defaults: defaults)
        model.setShowsCliSessions(false)
        model.setShowsClaudeCodeSessions(false)

        let relaunched = CliSessionsSyncModel(server: serverA, defaults: defaults)
        XCTAssertFalse(relaunched.showsCliSessions)
        XCTAssertFalse(relaunched.showsClaudeCodeSessions)
    }

    func testPreferencesAreIsolatedByServer() {
        let alpha = CliSessionsSyncModel(server: serverA, defaults: defaults)
        alpha.setShowsCliSessions(false)
        alpha.setShowsClaudeCodeSessions(false)

        let beta = CliSessionsSyncModel(server: serverB, defaults: defaults)
        XCTAssertTrue(beta.showsCliSessions)
        XCTAssertTrue(beta.showsClaudeCodeSessions)
    }

    func testCliPreferenceFallsBackToLegacyGlobalValueWithoutImportingIt() {
        defaults.set(false, forKey: SessionRowDisplaySettings.showCliSessionsKey)
        let model = CliSessionsSyncModel(server: serverA, defaults: defaults)

        XCTAssertFalse(model.showsCliSessions)
        XCTAssertNil(defaults.object(forKey: SessionRowDisplaySettings.showCliSessionsKey(for: serverA)))
        XCTAssertFalse(SessionRowDisplaySettings.showsCliSessions(for: serverB, in: defaults))
    }

    func testPerServerValueOverridesLegacyFallback() {
        defaults.set(false, forKey: SessionRowDisplaySettings.showCliSessionsKey)
        defaults.set(true, forKey: SessionRowDisplaySettings.showCliSessionsKey(for: serverA))

        XCTAssertTrue(CliSessionsSyncModel(server: serverA, defaults: defaults).showsCliSessions)
        XCTAssertFalse(CliSessionsSyncModel(server: serverB, defaults: defaults).showsCliSessions)
    }

    func testChangingParentDoesNotOverwriteIndependentClaudeCodeValue() {
        let model = CliSessionsSyncModel(server: serverA, defaults: defaults)
        model.setShowsClaudeCodeSessions(false)
        model.setShowsCliSessions(false)
        model.setShowsCliSessions(true)

        XCTAssertFalse(model.showsClaudeCodeSessions)
        XCTAssertFalse(
            SessionRowDisplaySettings.showsClaudeCodeSessions(for: serverA, in: defaults)
        )
    }
}
