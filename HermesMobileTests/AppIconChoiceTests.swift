import XCTest
@testable import HermesMobile

final class AppIconChoiceTests: XCTestCase {
    func testSemrehUsesOneCanonicalIcon() {
        XCTAssertEqual(AppIconChoice.allCases, [.system])
        XCTAssertEqual(AppIconChoice.system.title, "Semreh")
        XCTAssertEqual(AppIconChoice.system.subtitle, "Canonical Semreh icon")
        XCTAssertNil(AppIconChoice.system.alternateIconName)
        XCTAssertEqual(AppIconChoice.system.previewImageName, "SemrehAppIcon")
        XCTAssertEqual(AppIconChoice.resolved(from: nil), .system)
        XCTAssertEqual(AppIconChoice.resolved(from: "LegacyAlternateIcon"), .system)
    }

    func testSidebarHeaderHasNoProductWordmark() throws {
        XCTAssertFalse(SemrehHeaderLogo.showsProductWordmark)
        XCTAssertFalse(SemrehHeaderLogo.showsPortraitMedallion)
        XCTAssertTrue(SemrehHeaderLogo.productName.isEmpty)
        XCTAssertTrue(SemrehHeaderLogo.productDescriptor.isEmpty)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sessionListSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("HermesMobile/Features/SessionList/SessionListView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(sessionListSource.contains("MOBILE AGENT"))
        XCTAssertFalse(sessionListSource.contains("Text(Self.productName)"))
        XCTAssertFalse(sessionListSource.contains("SemrehHeaderLogo()"))
    }

    func testPrivacyPolicyUsesSemrehControlledPublicURL() {
        XCTAssertEqual(
            AppConfig.privacyPolicyURL.absoluteString,
            "https://github.com/jmogainz/semreh-ios/blob/master/PRIVACY.md"
        )
    }

    func testSupportUsesSemrehRepositoryIssues() {
        XCTAssertEqual(
            AppConfig.supportURL.absoluteString,
            "https://github.com/jmogainz/semreh-ios/issues"
        )
    }

    func testForegroundRefreshTasksAreSceneOwnedAndCancelled() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chatSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("HermesMobile/Features/Chat/ChatView.swift"),
            encoding: .utf8
        )
        let sessionListSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("HermesMobile/Features/SessionList/SessionListView.swift"),
            encoding: .utf8
        )

        for source in [chatSource, sessionListSource] {
            XCTAssertTrue(source.contains("@State private var foregroundRefreshTask: Task<Void, Never>?"))
            XCTAssertTrue(source.contains("foregroundRefreshTask?.cancel()"))
            XCTAssertTrue(source.contains("scenePhase == .active"))
        }
        XCTAssertTrue(chatSource.contains("viewModel.stopSessionEventSync()"))
        XCTAssertTrue(chatSource.contains("await viewModel.reconnectStreamIfNeeded(modelContext: modelContext)"))
        XCTAssertFalse(chatSource.contains("cancelOwnedStreamStatusWatch"))
        XCTAssertTrue(chatSource.contains("ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear"))
    }
}
