import CoreFoundation
import XCTest

@MainActor
final class HostRequestUITests: XCTestCase {
    func testUnsupportedRequestIsCompactAndDetailsNeverAnswerIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let token = UUID().uuidString
        app.launchArguments = ["--fixture", "--fixture-control", token]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixtureBanner"].waitForExistence(timeout: 10))
        signal("host-request", token: token)
        let title = app.staticTexts["Continue on your Hermes host"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        attach(app, "unsupported-request-before-details")
        let details = app.buttons["hostRequestDetails"]
        XCTAssertTrue(details.isHittable, "An unsupported request needs an honest explanation without occupying the transcript.")
        XCTAssertLessThan(app.otherElements["hostRequestSummary"].frame.height, 110)
        details.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "This request is not supported in Companion yet. Open Hermes on your host to continue. It remains pending until answered or canceled there.")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'answer-'")).firstMatch.exists)
        attach(app, "unsupported-request-details")
        app.buttons["Done"].tap()
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fixture request resolved."].exists)
        details.tap()
        signal("cancel-request", token: token)
        XCTAssertTrue(app.staticTexts["This request is no longer pending."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertFalse(details.exists)
    }

    private func signal(_ action: String, token: String) {
        let name = "org.hermescompanion.fixture." + token + "." + action
        let done = expectation(description: action)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(done).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<XCTestExpectation>.fromOpaque(observer).takeUnretainedValue().fulfill()
        }, (name + ".ack") as CFString, nil, .deliverImmediately)
        defer { CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(rawValue: (name + ".ack") as CFString), nil) }
        CFNotificationCenterPostNotification(center, CFNotificationName(rawValue: name as CFString), nil, nil, true)
        wait(for: [done], timeout: 10)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
