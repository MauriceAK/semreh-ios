import XCTest

final class LongChatScrollUITests: XCTestCase {
    private let performanceLabArgument = "--chat-performance-lab"
    private let chatIdentifier = "chat-detail:10,000-row performance lab"
    private let scrollToLatestLabel = "Scroll to latest message"
    private let endMarker = "End of 10,000-row conversation."

    func testTenThousandRowChatScrollsAndScrollToLatestReachesEndMarker() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Do not inherit a unit-test host or a previous ordinary app launch.
        app.terminate()
        app.launchArguments = [performanceLabArgument]
        app.launch()

        let chat = app.otherElements[chatIdentifier]
        XCTAssertTrue(
            chat.waitForExistence(timeout: 15),
            "The server-free 10,000-row ChatView performance lab must launch."
        )
        attachScreenshot(named: "long-chat-before-scroll")
        // The SwiftUI grouping container need not itself expose a hit point;
        // interact with the actual transcript scroll view inside it.
        let transcript = app.scrollViews.firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertTrue(transcript.isHittable, "The transcript scroll view must be interactive.")

        let scrollToLatest = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(
            scrollToLatest.waitForExistence(timeout: 10),
            "A restored mid-history viewport must expose the scroll-to-latest action."
        )

        // Exercise a real user scroll before using the recovery affordance. The
        // performance lab is deliberately static: this test proves lazy rendering
        // and bottom navigation only, not direct transport, sending, or tab routing.
        transcript.swipeUp()
        XCTAssertTrue(
            app.buttons[scrollToLatestLabel].waitForExistence(timeout: 5),
            "The scroll-to-latest action must remain available after a real swipe."
        )
        attachScreenshot(named: "long-chat-after-swipe")

        app.buttons[scrollToLatestLabel].tap()

        let endMarker = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", self.endMarker)
        ).firstMatch
        let reachedEnd = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: endMarker
        )
        wait(for: [reachedEnd], timeout: 25)
        XCTAssertTrue(
            endMarker.exists && endMarker.isHittable,
            "Tapping Scroll to latest message must make the deterministic end marker visible and hittable."
        )
        XCTAssertFalse(
            app.buttons[scrollToLatestLabel].waitForExistence(timeout: 2),
            "The scroll-to-latest action must clear after the viewport reaches the bottom."
        )
        attachScreenshot(named: "long-chat-after-scroll-to-latest")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
