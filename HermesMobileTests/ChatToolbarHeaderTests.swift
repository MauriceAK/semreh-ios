import XCTest
import UIKit
@testable import HermesMobile

final class ChatToolbarHeaderTests: XCTestCase {
    func testSubtitleUsesWorkspaceBasenameBeforeProfile() {
        XCTAssertEqual(
            ChatToolbarSubtitleResolver.subtitle(
                workspacePath: "/Users/example/hermes-mobile",
                profileTitle: "Default"
            ),
            "hermes-mobile"
        )
    }

    func testSubtitleFallsBackToStableProfileTitle() {
        XCTAssertEqual(
            ChatToolbarSubtitleResolver.subtitle(
                workspacePath: nil,
                profileTitle: "Work"
            ),
            "Work"
        )
    }

    func testSubtitleOmitsGenericOrBlankContext() {
        XCTAssertNil(ChatToolbarSubtitleResolver.subtitle(workspacePath: nil, profileTitle: "Profile"))
        XCTAssertNil(ChatToolbarSubtitleResolver.subtitle(workspacePath: "   ", profileTitle: "   "))
    }
}

@MainActor
final class ChatChromeActivationTests: XCTestCase {
    func testOneTouchUpUsesLatestActionWithoutTouchDownOrDuplicateDispatch() {
        let button = ChatChromeButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        var calls: [String] = []
        button.onActivate = { calls.append("old") }
        button.sendActions(for: .touchDown)
        XCTAssertTrue(calls.isEmpty)
        // SwiftUI may update the closure during streaming or a held press.
        button.onActivate = { calls.append("current") }
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, ["current"])
        XCTAssertTrue(button.isAccessibilityElement)
        XCTAssertTrue(button.accessibilityTraits.contains(.button))
        XCTAssertEqual(button.bounds.size, CGSize(width: 44, height: 44))
        button.isEnabled = false
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, ["current"])
    }

    func testFirstActivationClearsDestinationAndBlocksLateAuthoritativeRestore() {
        let session = SessionSummary(sessionId: "reader", title: "Reader")
        var navigation = SessionNavigationState(lastSelectedSessionID: "reader")
        navigation.select(session)
        let button = ChatChromeButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        button.onActivate = { navigation.clearDestination() }
        button.sendActions(for: .touchUpInside)
        XCTAssertNil(navigation.destination)
        navigation.reconcileAuthoritativeSelection(from: [session])
        XCTAssertNil(navigation.destination)
        XCTAssertEqual(navigation.lastSelectedSessionID, "reader")
    }
}
