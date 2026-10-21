import XCTest

@MainActor
final class PickerDiagnosticTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func hasContent(_ app: XCUIApplication) -> Bool {
        let empty = app.staticTexts.matching(NSPredicate(
            format: "label IN %@", ["No Recents", "No Recent Documents", "No Items", "This Folder is Empty", "On My iPhone is Empty", "No Results", "No Results Found"]
        )).firstMatch
        return empty.exists || app.collectionViews.cells.firstMatch.exists || app.tables.cells.firstMatch.exists
    }

    func testMinimalFileImporterCancellation() {
        let app = XCUIApplication()
        addTeardownBlock { @MainActor in self.capture(app, "minimal-final") }
        app.launch()
        let open = app.buttons["openPicker"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        var previousReadiness = ""
        let ready = NSPredicate { _, _ in
            let cancelExists = cancel.exists
            let searchExists = app.searchFields.firstMatch.exists
            let contentExists = self.hasContent(app)
            let readiness = "cancel=\(cancelExists) search=\(searchExists) content=\(contentExists)"
            if readiness != previousReadiness {
                print("PICKER_READINESS \(Date().timeIntervalSince1970) \(readiness)")
                previousReadiness = readiness
            }
            return cancelExists && cancel.isHittable && searchExists && contentExists
        }
        expectation(for: ready, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        capture(app, "minimal-ready")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        let restored = NSPredicate { _, _ in
            app.staticTexts["pickerState"].label == "Picker dismissed" && open.isHittable
        }
        expectation(for: restored, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        capture(app, "minimal-restored")
    }

    func testBuiltInFilesBrowseAndSearch() {
        XCTAssertFalse(FilesIdentity.bundleIdentifier.isEmpty, "Files identity must come from the selected runtime.")
        let app = XCUIApplication(bundleIdentifier: FilesIdentity.bundleIdentifier)
        addTeardownBlock { @MainActor in self.capture(app, "files-final") }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let browse = app.tabBars.buttons["Browse"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        XCTAssertTrue(browse.isHittable)
        capture(app, "files-initial")
        browse.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(hasContent(app), "Browse must show locations, items, or an empty state.")
        capture(app, "files-browse")
        search.tap()
        let query = "picker-diagnostic-no-such-file-20261021"
        search.typeText(query)
        let keyboardEducation = app.staticTexts["Speed up your typing by sliding your finger across the letters to compose a word."]
        if keyboardEducation.exists {
            capture(app, "files-keyboard-education")
            app.buttons["Continue"].tap()
        }
        let submitSearch = app.keyboards.buttons["Search"].firstMatch
        XCTAssertTrue(submitSearch.isHittable)
        submitSearch.tap()
        let noResults = app.staticTexts.matching(NSPredicate(
            format: "label IN %@", ["No Results", "No Results Found", "No Results for “\(query)”"]
        )).firstMatch
        XCTAssertTrue(noResults.waitForExistence(timeout: 10), "Search must resolve to a real empty result.")
        capture(app, "files-search-empty")
    }
}
