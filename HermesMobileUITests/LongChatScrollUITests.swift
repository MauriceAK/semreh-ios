import XCTest
import UIKit
import UniformTypeIdentifiers
import Foundation
import CoreFoundation
import QuartzCore

extension XCTestCase {
    /// SwiftUI preserves ChatView's established chat-detail container identifier.
    /// Prove the selected surface through the unique children it actually owns.
    @MainActor
    func requireSelectedChatSurface(in app: XCUIApplication, muse: Bool, needsTranscript: Bool = true) {
        let composers = app.textViews.matching(identifier: "chat-composer-input")
        let native = app.collectionViews.matching(identifier: "chat-native-transcript-v2")
        let legacy = app.collectionViews.matching(identifier: "chat-transcript-scroll")
        let headers = app.otherElements.matching(identifier: "muse-chat-header")
        let docks = app.otherElements.matching(identifier: "muse-chat-dock")
        var failures: [String] = []
        if !composers.firstMatch.waitForExistence(timeout: 20) { failures.append("composer did not appear") }
        if needsTranscript, !(muse ? native : legacy).firstMatch.waitForExistence(timeout: 20) {
            failures.append("selected collection did not appear")
        }
        func requireCount(_ query: XCUIElementQuery, _ expected: Int, _ name: String) {
            let actual = query.count
            if actual != expected { failures.append("\(name): expected \(expected), observed \(actual)") }
        }
        requireCount(composers, 1, "editable composers")
        requireCount(native, muse && needsTranscript ? 1 : 0, "native collections")
        requireCount(legacy, !muse && needsTranscript ? 1 : 0, "legacy collections")
        requireCount(headers, muse ? 1 : 0, "Muse headers")
        requireCount(docks, muse ? 1 : 0, "Muse docks")
        if muse {
            let roots = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-detail:"))
            let root = roots.firstMatch
            requireCount(roots, 1, "selected chat-detail containers")
            requireCount(root.descendants(matching: .other).matching(identifier: "muse-chat-header"), 1, "owned header")
            requireCount(root.descendants(matching: .other).matching(identifier: "muse-chat-dock"), 1, "owned dock")
            requireCount(root.descendants(matching: .collectionView).matching(identifier: "chat-native-transcript-v2"),
                         needsTranscript ? 1 : 0, "owned collection")
            requireCount(root.descendants(matching: .textView).matching(identifier: "chat-composer-input"), 1, "owned composer")
            if roots.count == 1 && headers.count == 1 && docks.count == 1 && composers.count == 1
                && (!needsTranscript || native.count == 1) {
                var frames = [root.frame, headers.firstMatch.frame, docks.firstMatch.frame, composers.firstMatch.frame]
                if needsTranscript { frames.append(native.firstMatch.frame) }
                let valid = frames.allSatisfy {
                    !$0.isNull && !$0.isInfinite && $0.minX.isFinite && $0.minY.isFinite
                        && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
                }
                if !valid || !root.frame.contains(headers.firstMatch.frame)
                    || !root.frame.contains(docks.firstMatch.frame)
                    || headers.firstMatch.frame.maxY >= docks.firstMatch.frame.minY {
                    failures.append("selected header and dock must coexist inside a valid chat-detail frame")
                }
            }
        }
        if !failures.isEmpty {
            var structure = failures + ["Identifiers only; maximum 100 nodes; no labels or values"]
            do {
                let snapshot = try app.snapshot()
                var recorded = 0
                func visit(_ node: XCUIElementSnapshot) {
                    guard recorded < 100 else { return }
                    if !node.identifier.isEmpty {
                        structure.append("type=\(node.elementType.rawValue) frame=\(node.frame) identifier=\(node.identifier)")
                        recorded += 1
                    }
                    for child in node.children where recorded < 100 { visit(child) }
                }
                visit(snapshot)
            } catch {
                structure.append("snapshot_error_type=\(String(reflecting: type(of: error)))")
            }
            let attachment = XCTAttachment(string: structure.joined(separator: "\n"))
            attachment.name = "chat-surface-identity-failure-structure"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }
}

final class LongChatScrollUITests: XCTestCase {
    @MainActor
    func testReleaseChatSurfaceDefaultLegacyPersistenceAndFallback() throws {
#if DEBUG
        throw XCTSkip("Requires the ordinary Release Simulator build")
#else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--internal-chat-preview-smoke"]
        app.launch()
        func root() {
            let open = app.buttons["internal-preview-open-chat"]
            if !open.exists {
                let back = app.navigationBars.buttons.firstMatch
                if back.exists { back.tap() } else { app.buttons["Back"].firstMatch.tap() }
            }
            XCTAssertTrue(open.waitForExistence(timeout: 8))
        }
        func setLegacy(_ enabled: Bool) {
            root()
            app.buttons["internal-preview-settings"].tap()
            let toggle = app.switches["legacy-chat-surface-toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 8))
            if (toggle.value as? String == "1") != enabled { toggle.tap() }
            XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
            root()
        }
        func openChat(native: Bool) {
            app.buttons["internal-preview-open-chat"].tap()
            let composer = app.textViews["chat-composer-input"]
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            let viewport = app.collectionViews["chat-native-transcript-v2"]
            if native {
                XCTAssertTrue(viewport.waitForExistence(timeout: 8))
                requireSelectedChatSurface(in: app, muse: true)
                let code = app.textViews["native-inline-code-text"].firstMatch
                XCTAssertTrue(code.waitForExistence(timeout: 8))
                let source = code.value as? String ?? ""
                XCTAssertTrue(source.contains("let preview = true\nprint(preview)"))
                viewport.swipeDown()
                viewport.swipeUp()
                XCTAssertTrue(composer.exists)
            } else {
                XCTAssertFalse(viewport.exists)
                XCTAssertTrue(app.collectionViews["chat-transcript-scroll"].waitForExistence(timeout: 8))
                requireSelectedChatSurface(in: app, muse: false)
            }
            attachScreenshot(named: native ? "internal-release-native" : "internal-release-stable")
        }
        // No renderer launch override: this is the ordinary Release default.
        openChat(native: true)
        setLegacy(true)
        openChat(native: false)
        app.terminate()
        app.launch()
        root()
        openChat(native: false)
        setLegacy(false)
        openChat(native: true)
        app.terminate()
        app.launch()
        root()
        openChat(native: true)
#endif
    }

    func testNativeParagraphSelectionCopiesOnlySelectedPassage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Enable the existing fresh-draft predicate; the four-tall route wins
        // over the generic lab route. A prior keyboard journey may leave a draft.
        app.launchArguments = ["--chat-performance-lab", "--chat-performance-tall-lab", "--chat-performance-four-tall-lab",
                               "--chat-native-transcript-v2", "--chat-rich-native-code-text",
                               "--chat-full-inline-code", "--chat-viewport-follow-latest-open",
                               "--composer-test-fresh-draft"]
        app.launch()
        XCTAssertTrue(app.otherElements["chat-native-transcript-v2"].exists ||
                      app.staticTexts["chat-native-transcript-v2"].waitForExistence(timeout: 15))
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label == %@", "End of four-row mixed conversation."
        )).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 15))
        tail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3))
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        let paragraph = String(repeating: "A synthetic research finding has **emphasis**, `inline code`, a [local reference](https://example.invalid/reference), العربية, and Unicode 👩🏽‍💻. Its lines must wrap naturally without losing content. ", count: 36)
        let source = selection.value as? String ?? ""
        XCTAssertTrue(source.contains(paragraph))
        XCTAssertTrue(source.contains("SEMREH_FOUR_TALL_CODE_END"))
        // Exercise the product's real triple-tap paragraph gesture. This test
        // never injects selectedRange or clipboard contents.
        let passage = selection.descendants(matching: .textView).matching(NSPredicate(
            format: "label BEGINSWITH %@", "A synthetic research finding has"
        )).firstMatch
        XCTAssertTrue(passage.exists)
        passage.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        attachScreenshot(named: "r42-native-paragraph-highlight")
        XCTAssertTrue(app.buttons["Look Up"].exists || app.menuItems["Look Up"].exists,
                      "Require UIKit's selected-text menu, not the message context menu")
        let copyItem = app.menuItems["Copy"]
        let copyButton = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "Copy", "assistant-response-copy"
        )).firstMatch
        XCTAssertTrue(copyItem.waitForExistence(timeout: 2) || copyButton.waitForExistence(timeout: 2),
                      "Only the native edit menu may satisfy Copy; not the covered response action")
        if copyItem.exists { copyItem.tap() } else { copyButton.tap() }
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(selection.waitForNonExistence(timeout: 5))
        let composer = app.textViews["chat-composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        XCTAssertTrue((composer.value as? String ?? "").isEmpty || composer.value as? String == composer.placeholderValue,
                      "The isolated fixture must start with an empty draft before exact paste comparison")
        composer.press(forDuration: 1)
        let pasteItem = app.menuItems["Paste"]
        let pasteButton = app.buttons["Paste"].firstMatch
        XCTAssertTrue(pasteItem.waitForExistence(timeout: 2) || pasteButton.waitForExistence(timeout: 2))
        if pasteItem.exists { pasteItem.tap() } else { pasteButton.tap() }
        let pasted = composer.value as? String ?? ""
        let evidence = XCTAttachment(string: pasted)
        evidence.name = "r42-actual-native-paragraph-paste"
        evidence.lifetime = .keepAlways
        add(evidence)
        attachScreenshot(named: "r42-native-paragraph-pasted")
        XCTAssertEqual(pasted, paragraph, "Native Copy must preserve exactly the selected paragraph, not the entire response")
    }

    func testFullResponseSelectionSurvivesDisappearanceAndBackground() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-four-tall-lab", "--chat-windowed-eager",
                               "--chat-full-inline-code", "--chat-rich-native-code-text",
                               "--chat-viewport-follow-latest-open", "--composer-test-fresh-draft"]
        app.launch()
        // The native viewport is a UICollectionView; the legacy path is a ScrollView.
        let transcript = app.descendants(matching: .any)["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label == %@", "End of four-row mixed conversation."
        )).firstMatch
        assertHittable(tail, timeout: 25, message: "The actual terminal paragraph must be reachable")
        XCTAssertTrue(transcript.frame.contains(tail.frame))
        // Use the actual response context menu, never a presentation injection.
        tail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3))
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        let source = selection.value as? String ?? ""
        let expectedCode = String(repeating: "let value = Array(0..<1_000).reduce(0, +)\n", count: 320)
            + "\nlet fourTallFinalMarker = \"SEMREH_FOUR_TALL_CODE_END\""
        XCTAssertTrue(source.contains(expectedCode), "Selection must contain all code, including offscreen lines")
        XCTAssertTrue(source.contains("End of four-row mixed conversation."))
        XCTAssertFalse(selection.waitForNonExistence(timeout: 2),
                       "Underlying ChatView disappearance must not dismiss its own cover")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        XCTAssertEqual(selection.value as? String, source)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Foreground must not focus beneath selection")
        attachScreenshot(named: "r35-selection-after-foreground")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(selection.waitForNonExistence(timeout: 5))
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let composer = app.textViews["chat-composer-input"]
        assertHittable(composer, timeout: 5, message: "Dismissing selection must return to the composer")
        composer.tap()
        composer.typeText("R35 after selection")
        XCTAssertTrue((composer.value as? String ?? "").contains("R35 after selection"))
    }

    func testRetainedRootControlsSurviveBackgroundAndRestoreFocusAfterDismissal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-rich-switch-lab",
                               "--chat-performance-retained-roots", "--chat-windowed-eager",
                               "--chat-windowed-rows=12", "--composer-test-fresh-draft"]
        app.launch()
        let composer = app.textViews["chat-composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("R35 controls draft")
        app.buttons["Chat controls"].tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "Preserved focus intent must resume after the controls dismiss")
        app.buttons["Performance chat 2"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1),
                       "A hidden root must not restore its keyboard")
        app.buttons["Performance chat 1"].tap()
        XCTAssertTrue((composer.value as? String ?? "").contains("R35 controls draft"))
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1),
                       "A-B-A must not replay consumed focus intent")
    }

    func testRetainedRichRootsKeepKeyboardAndAccessibilityWithActiveComposer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-rich-switch-lab",
                               "--chat-performance-retained-roots", "--chat-windowed-eager",
                               "--chat-windowed-rows=12", "--chat-full-inline-code",
                               "--chat-rich-native-code-text"]
        app.launch()
        let inputs = app.textViews.matching(identifier: "chat-composer-input")
        let first = app.buttons["Performance chat 1"]
        let second = app.buttons["Performance chat 2"]
        XCTAssertTrue(inputs.firstMatch.waitForExistence(timeout: 30))
        XCTAssertEqual(inputs.count, 1)
        inputs.firstMatch.tap()
        inputs.firstMatch.typeText("R34 root A draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        second.tap()
        XCTAssertTrue(inputs.firstMatch.waitForExistence(timeout: 10))
        if inputs.count != 1 {
            attachScreenshot(named: "r35-hidden-composer-failure")
            attachAccessibilitySnapshot(named: "r35-hidden-composer-hierarchy", app: app)
        }
        XCTAssertEqual(inputs.count, 1, "Hidden retained root must be excluded from AX")
        XCTAssertEqual(app.scrollViews.matching(identifier: "chat-transcript-scroll").count, 1,
                       "Hidden retained transcript must also be excluded from AX")
        inputs.firstMatch.tap()
        inputs.firstMatch.typeText("R34 root B draft")
        first.tap()
        XCTAssertTrue(NSPredicate(format: "value CONTAINS %@", "R34 root A draft")
            .evaluate(with: inputs.firstMatch))
        inputs.firstMatch.tap()
        inputs.firstMatch.typeText(" active")
        second.tap()
        XCTAssertEqual(inputs.count, 1)
        XCTAssertTrue(NSPredicate(format: "value CONTAINS %@", "R34 root B draft")
            .evaluate(with: inputs.firstMatch))
        XCTAssertFalse((inputs.firstMatch.value as? String ?? "").contains(" active"))
        // Foregrounding must not expose/reactivate the hidden root's input.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(inputs.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(inputs.count, 1)
        inputs.firstMatch.tap()
        inputs.firstMatch.typeText(" foreground")
        first.tap()
        XCTAssertFalse((inputs.firstMatch.value as? String ?? "").contains(" foreground"))
    }

    func testFullChatActivityLabKeepsDistinctInlineStatusWithoutFloatingPill() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-full-activity-lab"]
        app.launch()

        let chat = app.otherElements["chat-detail:Activity full lab"]
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch
        let advance = app.buttons["full-activity-advance"]
        let phase = app.staticTexts["full-activity-phase"]
        let thinking = app.buttons.matching(NSPredicate(format: "label == %@", "Thinking"))
        let additional = app.buttons.matching(NSPredicate(format: "label == %@", "Additional thinking"))
        let preparing = app.staticTexts.matching(NSPredicate(
            format: "label == %@", "Semreh is preparing a response"
        ))
        let search = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search files"))
        let floating = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "Hermes is working"
        ))

        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        XCTAssertTrue(composer.exists && advance.isHittable)
        XCTAssertEqual(phase.label, "full activity phase 0")
        XCTAssertEqual(additional.count, 1, "Unattributed details should remain available separately.")
        XCTAssertEqual(thinking.count, 0, "Additional details must not impersonate the live turn.")
        XCTAssertEqual(preparing.count, 1, "The new run must not print a second Thinking label.")
        XCTAssertEqual(search.count, 0)
        XCTAssertEqual(floating.count, 0)

        // Hold the actual app scene through a full shine cycle. The UI test
        // checks stable AX geometry; a direct Simulator recording checks motion.
        let pendingFrame = preparing.firstMatch.frame
        let shineCycle = expectation(description: "Live status shines without row movement")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { shineCycle.fulfill() }
        wait(for: [shineCycle], timeout: 3)
        XCTAssertEqual(preparing.count, 1)
        XCTAssertEqual(preparing.firstMatch.frame.minY, pendingFrame.minY, accuracy: 1)
        XCTAssertEqual(preparing.firstMatch.frame.height, pendingFrame.height, accuracy: 1)

        advance.tap()
        XCTAssertEqual(phase.label, "full activity phase 1")
        XCTAssertEqual(additional.count, 1)
        XCTAssertEqual(thinking.count, 0)
        XCTAssertEqual(search.count, 1)
        XCTAssertEqual(floating.count, 0)

        advance.tap()
        XCTAssertEqual(phase.label, "full activity phase 2")
        XCTAssertEqual(additional.count, 1)
        XCTAssertEqual(thinking.count, 0)
        XCTAssertEqual(search.count, 1)
        XCTAssertEqual(floating.count, 0)
        XCTAssertTrue(composer.exists)
    }

    func testFullChatActivityAnchorsOlderThinkingBeforeNewTurnAndCurrentToolBesideResponse() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-full-activity-anchored-lab"]
        app.launch()

        let chat = app.otherElements["chat-detail:Activity full lab"]
        let advance = app.buttons["full-activity-advance"]
        let thinking = app.buttons.matching(NSPredicate(format: "label == %@", "Thinking"))
        let additional = app.buttons.matching(NSPredicate(format: "label == %@", "Additional thinking"))
        let currentUser = app.staticTexts["message-row:activity-full-current-user"]
        let currentResponse = app.staticTexts["message-row:activity-full-current-assistant"]
        let search = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search files"))
        let preparing = app.staticTexts.matching(NSPredicate(
            format: "label == %@", "Semreh is preparing a response"
        ))

        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        XCTAssertEqual(thinking.count, 1)
        XCTAssertEqual(additional.count, 0)
        XCTAssertEqual(preparing.count, 1, "The new turn must not show a second Thinking label.")
        XCTAssertTrue(currentUser.exists)
        XCTAssertLessThan(thinking.firstMatch.frame.maxY, currentUser.frame.minY,
                          "Old-turn reasoning must stay before the new user turn.")

        advance.tap()
        advance.tap()
        XCTAssertEqual(app.staticTexts["full-activity-phase"].label, "full activity phase 2")
        XCTAssertEqual(thinking.count, 1)
        XCTAssertEqual(search.count, 1)
        XCTAssertEqual(preparing.count, 0)
        XCTAssertTrue(currentResponse.exists)
        XCTAssertLessThan(thinking.firstMatch.frame.maxY, currentUser.frame.minY)
        XCTAssertLessThan(currentUser.frame.maxY, search.firstMatch.frame.minY)
        XCTAssertLessThan(search.firstMatch.frame.maxY, currentResponse.frame.minY)
        XCTAssertLessThan(currentResponse.frame.minY - search.firstMatch.frame.maxY, 40,
                          "The tool disclosure should stay adjacent to its own response.")
    }

    func testAppOwnedActivityHandoffKeepsOneDisclosureAndVisibleTranscript() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-activity-handoff-lab"]
        app.launch()

        let transcript = app.scrollViews["chat-transcript-scroll"]
        let advance = app.buttons["activity-handoff-advance"]
        let phase = app.staticTexts["activity-handoff-phase"]
        let prompt = app.staticTexts["message-row:activity-handoff-current-user"]
        let previousAnswer = app.staticTexts["message-row:activity-handoff-old-assistant"]
        let thinking = app.buttons.matching(NSPredicate(format: "label == %@", "Thinking"))
        let readFile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Read file"))

        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        XCTAssertTrue(advance.isHittable && phase.exists)
        XCTAssertTrue(prompt.exists && previousAnswer.exists)
        XCTAssertEqual(phase.label, "activity phase 0")
        XCTAssertEqual(thinking.count, 1, "Retained and live reasoning should share one disclosure.")
        XCTAssertEqual(readFile.count, 1, "The completed read_file action should remain inline.")
        XCTAssertFalse(app.staticTexts["Semreh is preparing a response"].exists,
                       "The ordinary bare status should not duplicate retained activity.")

        let promptFrame = prompt.frame
        let answerFrame = previousAnswer.frame
        let thinkingFrame = thinking.firstMatch.frame
        let readFrame = readFile.firstMatch.frame
        let windowFrame = app.windows.firstMatch.frame
        for frame in [promptFrame, answerFrame, thinkingFrame, readFrame] {
            XCTAssertGreaterThanOrEqual(frame.minX, windowFrame.minX - 1)
            XCTAssertLessThanOrEqual(frame.maxX, windowFrame.maxX + 1)
        }

        // A direct Simulator video records the uninterrupted handoff. Do not
        // ask XCTest to draw hierarchy snapshots while live chunks are arriving.
        let leadIn = expectation(description: "Stable app-window video lead-in")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { leadIn.fulfill() }
        wait(for: [leadIn], timeout: 2)
        advance.tap()
        let settled = expectation(description: "Live chunks finish and retained activity remains")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(phase.label, "activity phase 4")
        XCTAssertTrue(prompt.isHittable && previousAnswer.exists)
        XCTAssertEqual(thinking.count, 1)
        XCTAssertEqual(readFile.count, 1)
        XCTAssertFalse(app.staticTexts["Semreh is preparing a response"].exists)
        XCTAssertEqual(prompt.frame.minY, promptFrame.minY, accuracy: 4,
                       "Collapsed activity updates should not jump the preceding prompt.")
        XCTAssertEqual(previousAnswer.frame.minY, answerFrame.minY, accuracy: 4)
        XCTAssertEqual(thinking.firstMatch.frame.minY, thinkingFrame.minY, accuracy: 4)
        XCTAssertEqual(readFile.firstMatch.frame.minY, readFrame.minY, accuracy: 4)
        for frame in [prompt.frame, previousAnswer.frame, thinking.firstMatch.frame, readFile.firstMatch.frame] {
            XCTAssertGreaterThanOrEqual(frame.minX, windowFrame.minX - 1)
            XCTAssertLessThanOrEqual(frame.maxX, windowFrame.maxX + 1)
        }
        let visibleHold = expectation(description: "Keep scene visible for direct video after handoff")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { visibleHold.fulfill() }
        wait(for: [visibleHold], timeout: 2)
    }

    func testMountedOutgoingMotionFromPopulatedBottomStaysNearComposer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-lab", "--chat-outgoing-motion-lab",
                               "--chat-outgoing-motion-populated"]
        app.launch()

        let transcript = app.scrollViews["chat-transcript-scroll"]
        let priorTail = app.staticTexts["message-row:motion-history-11"]
        let composer = app.textViews["chat-composer-input"]
        let inject = app.buttons["outgoing-motion-inject"]
        let marker = app.staticTexts["outgoing-motion-marker"]
        let outgoing = app.staticTexts["message-row:local-motion-1"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        XCTAssertTrue(priorTail.waitForExistence(timeout: 15) && priorTail.isHittable)
        XCTAssertTrue(composer.isHittable && inject.isHittable)
        XCTAssertEqual(marker.label, "motion marker 0")
        XCTAssertFalse(outgoing.exists)

        // Match the common send state: keyboard open and the old tail visible.
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(priorTail.isHittable)
        let ready = expectation(description: "Near-bottom viewport settles before video marker")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ready.fulfill() }
        wait(for: [ready], timeout: 2)

        let priorTailBottom = priorTail.frame.maxY
        let baselineGap = composer.frame.minY - priorTailBottom
        XCTAssertGreaterThanOrEqual(baselineGap, -4)
        XCTAssertLessThan(baselineGap, 180, "The synthetic history must be near the composer before injection.")

        inject.tap()
        XCTAssertTrue(outgoing.waitForExistence(timeout: 10) && outgoing.isHittable)
        XCTAssertEqual(marker.label, "motion marker 1")
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:local-motion-1").count, 1)
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:motion-history-11").count, 1)
        let outgoingGap = composer.frame.minY - outgoing.frame.maxY
        XCTAssertGreaterThanOrEqual(outgoingGap, -4)
        XCTAssertLessThan(outgoingGap, 180, "The new bubble must settle beside the composer, not at the transcript top.")
        XCTAssertLessThan(priorTail.frame.maxY, priorTailBottom + 4)
        XCTAssertGreaterThan(priorTail.frame.maxY, priorTailBottom - 200,
                             "Inserting one bubble must not jump the old tail by a viewport.")
    }

    func testMountedOutgoingMotionFixtureKeepsOneBubblePerLocalSend() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-lab", "--chat-outgoing-motion-lab"]
        app.launch()

        let transcript = app.scrollViews["chat-transcript-scroll"]
        let chat = app.otherElements["chat-detail:Outgoing motion lab"]
        let inject = app.buttons["outgoing-motion-inject"]
        let marker = app.staticTexts["outgoing-motion-marker"]
        let first = app.staticTexts["message-row:local-motion-1"]
        let second = app.staticTexts["message-row:local-motion-2"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        XCTAssertTrue(inject.waitForExistence(timeout: 10) && inject.isHittable)
        XCTAssertTrue(marker.exists)
        XCTAssertFalse(first.exists, "The mounted fixture starts with no outgoing row.")

        // Leave the app settled before injection so a separately started
        // app-window video can align its first 300 ms to the marker flip.
        let ready = expectation(description: "Mounted app-window video lead-in")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ready.fulfill() }
        wait(for: [ready], timeout: 2)
        inject.tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:local-motion-1").count, 1)
        XCTAssertEqual(marker.label, "motion marker 1")

        inject.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:local-motion-1").count, 1)
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:local-motion-2").count, 1)
        XCTAssertEqual(marker.label, "motion marker 2")
        XCTAssertTrue(first.isHittable && second.isHittable)
    }

    func testNativeBottomEdgeManualTakeover20And120() {
        exerciseNativeBottomEdgeManualTakeover(singleSettlement: false)
    }

    func testNativeSingleSettlementManualTakeover20And120() {
        exerciseNativeBottomEdgeManualTakeover(singleSettlement: true)
    }

    private func exerciseNativeBottomEdgeManualTakeover(singleSettlement: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        for count in [20, 120] {
            app.terminate()
            app.launchArguments = ["--chat-performance-lab", "--representative-count=\(count)", "--native-baseline", "--native-bottom-edge", "--native-refinement-trace"]
            if singleSettlement { app.launchArguments.append("--native-edge-single-settlement") }
            app.launch()
            let scroll = app.scrollViews["native-baseline-scroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 15))
            app.buttons["native-baseline-jump"].tap()
            // Submit the real gesture immediately after tap. Phase logs decide
            // whether it overlapped animation; test success alone must not claim it.
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.2))
                .press(forDuration: 0.01, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.9)), withVelocity: .fast, thenHoldForDuration: 0)
            let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
            XCTAssertFalse(tail.isHittable, "Manual reading moves away from tail")
            let settled = expectation(description: "Observe no delayed native snap")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { settled.fulfill() }
            wait(for: [settled], timeout: 2)
            XCTAssertFalse(tail.isHittable, "Native bottom intent must not snap back after manual reading")
            attachScreenshot(named: "bottom-edge-manual-\(count)-single-settlement-\(singleSettlement)")
        }
    }

    func testNativeBaselineRepresentative20And120() {
        exerciseRepresentativeNativeControl(native: true)
    }

    func testProductionRepresentative20And120() {
        exerciseRepresentativeNativeControl(native: false)
    }

    private func exerciseRepresentativeNativeControl(native: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        for count in [20, 120] {
            app.terminate()
            app.launchArguments = ["--chat-performance-lab", "--representative-count=\(count)"]
            if native { app.launchArguments.append("--native-baseline") }
            app.launch()
            let scroll = app.scrollViews[native ? "native-baseline-scroll" : "chat-transcript-scroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 15))
            let arrow = app.buttons[native ? "native-baseline-jump" : scrollToLatestLabel]
            for cycle in 0..<2 {
                if cycle > 0 {
                    scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.3))
                        .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.75)))
                }
                XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
                arrow.tap()
                let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
                assertHittable(tail, timeout: 10, message: "Representative\(count) native=\(native) cycle=\(cycle) reaches concrete tail")
                attachScreenshot(named: "representative-\(count)-native-\(native)-cycle-\(cycle)")
            }
        }
    }

    private let performanceLabArgument = "--chat-performance-lab"
    private let performanceCycleLabArgument = "--chat-performance-cycle-lab"
    private let performanceSignpostsArgument = "--chat-performance-signposts"
    private let performanceMetricProbeEnvironment = "SEMREH_CHAT_PERFORMANCE_METRIC_PROBE"
    private let performanceFrameCallbackProbeArgument = "--chat-performance-frame-callback-probe"
    private let performanceFrameCallbackProbeEnvironment = "SEMREH_CHAT_FRAME_CALLBACK_PROBE"
    private let appWidePerformanceMonitorArgument = "--chat-performance-app-wide-monitor"
    private let appWidePerformanceMonitorEnvironment = "SEMREH_CHAT_APP_WIDE_MONITOR_UI"
    private let birdPaletteLabArgument = "--bird-palette-visual-lab"
    private let birdPaletteLabEnvironment = "SEMREH_BIRD_PALETTE_LAB_UI"
    private let approvedLiveOrigin = "https://semreh-slice1-test.tailda8427.ts.net"
    private let approvedLiveHost = "semreh-slice1-test.tailda8427.ts.net"
    private let stockBackendSHA = "29112bef099274229cadff79cdff7bf7b99c4b77"
    private let developmentBackendSHA = "8c50f84522a755d40346e73701a6847fbdde20ec"
    private let stockCredentialsPath = "/Users/maurice/workspace/semreh-slice1-runtime/credentials.json"
    private let stockToolCwd = "/Users/maurice/workspace/semreh-slice1-runtime/tools"
    private let developmentCredentialsPath = "/Users/maurice/workspace/semreh-slice2-runtime/credentials.json"
    private let developmentToolCwd = "/Users/maurice/workspace/semreh-slice2-runtime/tools"
    private let chatIdentifier = "chat-detail:10,000-row performance lab"
    private let scrollToLatestLabel = "Scroll to latest message"
    private let endMarker = "End of 10,000-row conversation."
    private let clarificationSingleMarker = "SEMREH_BLOCKING_CLARIFY"
    private let clarificationMultiSelectMarker = "SEMREH_BLOCKING_CLARIFY_MULTI_SELECT"
    private let clarificationBatchMarker = "SEMREH_BLOCKING_CLARIFY_BATCH"
    private let clarificationCardIdentifier = "direct.clarification.card"
    private let clarificationCancelIdentifier = "direct.clarification.cancel"
    private let singleAnswerAcknowledgement = "SEMREH_SLICE3_CLARIFY_ACK_SINGLE_ANSWER"
    private let singleCancelAcknowledgement = "SEMREH_SLICE3_CLARIFY_ACK_SINGLE_CANCEL"
    private let batchCancelAcknowledgement = "SEMREH_SLICE3_CLARIFY_ACK_BATCH_CANCEL"
    private let multiSelectCancelAcknowledgement = "SEMREH_SLICE3_CLARIFY_ACK_MULTI_SELECT_CANCEL"
    private let blockingApprovalMarker = "SEMREH_BLOCKING_APPROVAL"
    private let blockingSecretMarker = "SEMREH_BLOCKING_SECRET"
    private let blockingApprovalDenyIdentifier = "approval-request-choice-deny"
    private let blockingSecretCancelIdentifier = "direct-sensitive-prompt-cancel"
    private let blockingApprovalAcknowledgement = "SEMREH_SLICE3_BLOCKING_ACK_APPROVAL_DENY"
    private let blockingSecretAcknowledgement = "SEMREH_SLICE3_BLOCKING_ACK_SECRET_CANCEL"
    private let tuiSeedMarker = "SEMREH_TUI_CROSS_CLIENT_1"
    private let slice1Acknowledgement = "SEMREH_SLICE1_ACK"
    private let uncertaintyDelayedPromptPrefix = "SEMREH_INTERRUPT_FIXTURE SEMREH_SLICE3_PRE_ACK_LOSS_"
    private let uncertaintyNewPromptPrefix = "SEMREH_SLICE3_UNCERTAINTY_NEW_"
    private let uncertaintyBannerIdentifier = "direct-prompt-uncertainty-banner"
    private let uncertaintyAllowIdentifier = "direct-prompt-uncertainty-allow-new-message"

    @MainActor
    func testResponseMotionComponentsCompletion() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("The component fixture is simulator-only.")
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--chat-response-motion-components-lab"]
        app.launch()
        let append = app.buttons["motion-lab-append"]
        let complete = app.buttons["motion-lab-complete"]
        XCTAssertTrue(append.waitForExistence(timeout: 10) && append.isHittable)
        append.tap()
        XCTAssertTrue(complete.isHittable)
        complete.tap()
        XCTAssertEqual(complete.label, "Restart")
        XCTAssertFalse(append.isEnabled)
        let completed = app.staticTexts["Response complete"]
        for _ in 0..<8 {
            if completed.exists && completed.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(completed.exists && completed.isHittable)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Component response completed — not production completion evidence"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testOptInBirdPaletteVisualLabScreenshots() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("The bird palette visual lab is simulator-only.")
        #endif
        guard ProcessInfo.processInfo.environment[birdPaletteLabEnvironment] == "1" else {
            throw XCTSkip("The bird palette visual lab is opt-in.")
        }

        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [birdPaletteLabArgument]
        app.launch()

        let title = app.staticTexts["Bird palette visual lab"]
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "The server-free bird palette visual lab must launch.")
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5),
                      "The bird palette lab must expose its bounded scroll surface.")

        let light = app.staticTexts["Light appearance"]
        XCTAssertTrue(light.waitForExistence(timeout: 5) && light.isHittable,
                       "The lab must show the light appearance first.")
        attachScreenshot(named: "bird-palette-visual-lab-light")

        let dark = app.staticTexts["Dark appearance"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5),
                      "The lab must include a dark appearance panel.")
        // Move to the bounded end so the dark screenshot contains all eight
        // palette rows rather than only the first rows after one swipe.
        for _ in 0..<3 {
            scrollView.swipeUp()
        }
        attachScreenshot(named: "bird-palette-visual-lab-dark")
    }

    @MainActor
    func testOptInProductionLocalOrganizerCRUDInSessionsAndControl() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("A3 production organizer UI smoke is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_A3_ORGANIZER_UI"] == "1" else {
            throw XCTSkip("A3 production organizer UI smoke is opt-in.")
        }
        guard environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == stockBackendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == stockCredentialsPath,
              environment["SEMREH_SLICE2_TOOL_CWD"] == stockToolCwd,
              let profile = environment["SEMREH_A2_PROFILE_NAME"], !profile.isEmpty,
              profile != "default",
              let selectedSentinel = environment["SEMREH_A2_SELECTED_SENTINEL"], !selectedSentinel.isEmpty,
              let defaultSentinel = environment["SEMREH_A2_DEFAULT_SENTINEL"], !defaultSentinel.isEmpty
        else {
            XCTFail("A3 opt-in fixture data must identify the exact stock HTTPS fixture, non-default profile, and sentinels.")
            return
        }

        let credentials = try readCredentials(at: stockCredentialsPath)
        let suffix = UUID().uuidString.prefix(8)
        let createdName = "A3 Group \(suffix)"
        let renamedName = "A3 Renamed \(suffix)"
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = []
        app.launch()
        defer { clearPasteboard() }

        prepareNormalSignIn(app: app)
        let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
        if !app.textFields["onboarding-server-url"].exists {
            XCTAssertTrue(welcome.waitForExistence(timeout: 15), "Normal sign-out must return to Welcome.")
            let existingServer = app.buttons["Already have a server?"]
            XCTAssertTrue(existingServer.waitForExistence(timeout: 5))
            existingServer.tap()
        }
        let serverURL = app.textFields["onboarding-server-url"]
        XCTAssertTrue(serverURL.waitForExistence(timeout: 5))
        replacePublicText(serverURL, with: approvedLiveOrigin, app: app)
        app.buttons["Test Connection"].tap()
        let username = app.textFields["onboarding-username"]
        let password = app.secureTextFields["onboarding-password"]
        XCTAssertTrue(username.waitForExistence(timeout: 30))
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        replacePublicText(username, with: credentials.username, app: app)
        pasteSecret(credentials.password, into: password, app: app)
        app.buttons["Connect"].tap()
        dismissKnownPasswordSavePrompt(app: app)
        waitForPostLoginDestination(app: app)

        addTeardownBlock { @MainActor in
            guard !app.secureTextFields["onboarding-password"].exists else { return }
            self.attachScreenshot(named: "a3-organizer-final")
            self.attachAccessibilitySnapshot(named: "a3-organizer-final-accessibility", app: app)
        }

        app.buttons["Sessions"].tap()
        XCTAssertTrue(app.staticTexts[selectedSentinel].waitForExistence(timeout: 20),
                      "Sessions must show the selected-profile sentinel before organizer interaction.")
        XCTAssertFalse(app.staticTexts[defaultSentinel].exists,
                       "Sessions must not show the default-profile sentinel.")
        let expandSessions = app.buttons["Expand projects"]
        XCTAssertTrue(expandSessions.waitForExistence(timeout: 10))
        expandSessions.tap()
        XCTAssertTrue(app.buttons["Collapse projects"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[createdName].exists, "The synthetic group must be absent before creation.")
        XCTAssertFalse(app.buttons[renamedName].exists, "The synthetic renamed group must be absent before creation.")

        app.buttons["Add project"].tap()
        XCTAssertTrue(app.navigationBars["New Project"].waitForExistence(timeout: 5))
        let newName = app.textFields["Project name"]
        XCTAssertTrue(newName.waitForExistence(timeout: 5))
        newName.tap()
        newName.typeText(createdName)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons[createdName].waitForExistence(timeout: 10))

        app.buttons["Control"].tap()
        let controlExpand = app.buttons["Expand projects"]
        if controlExpand.waitForExistence(timeout: 3) { controlExpand.tap() }
        XCTAssertTrue(app.buttons[createdName].waitForExistence(timeout: 10))
        app.buttons["Project actions for \(createdName)"].tap()
        XCTAssertTrue(app.buttons["Rename Project"].waitForExistence(timeout: 5))
        app.buttons["Rename Project"].tap()
        XCTAssertTrue(app.navigationBars["Rename Project"].waitForExistence(timeout: 5))
        replacePublicText(app.textFields["Project name"], with: renamedName, app: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons[renamedName].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[createdName].exists)

        app.terminate()
        app.launch()
        waitForPostLoginDestination(app: app)
        app.buttons["Control"].tap()
        let relaunchExpand = app.buttons["Expand projects"]
        if relaunchExpand.waitForExistence(timeout: 3) { relaunchExpand.tap() }
        XCTAssertTrue(app.buttons[renamedName].waitForExistence(timeout: 10),
                      "The renamed local group must persist across one process relaunch.")

        app.buttons["Project actions for \(renamedName)"].tap()
        XCTAssertTrue(app.buttons["Delete Project"].waitForExistence(timeout: 5))
        app.buttons["Delete Project"].tap()
        let deleteDialog = app.sheets["Delete project?"]
        XCTAssertTrue(deleteDialog.waitForExistence(timeout: 5))
        deleteDialog.buttons["Delete"].tap()
        XCTAssertFalse(app.buttons[renamedName].waitForExistence(timeout: 3),
                       "UI cleanup must remove the synthetic local group.")
    }

    @MainActor
    func testOptInProductionNonDefaultProfileOwnsFirstControlAndSessionsSidebarLoad() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("A2 production UI smoke is simulator-only.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_A2_PROFILE_UI"] == "1" else {
            throw XCTSkip("A2 production UI smoke is opt-in.")
        }
        guard environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock",
              environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == stockBackendSHA,
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == stockCredentialsPath,
              environment["SEMREH_SLICE2_TOOL_CWD"] == stockToolCwd,
              let profile = environment["SEMREH_A2_PROFILE_NAME"], !profile.isEmpty,
              profile != "default",
              let selectedSentinel = environment["SEMREH_A2_SELECTED_SENTINEL"], !selectedSentinel.isEmpty,
              let defaultSentinel = environment["SEMREH_A2_DEFAULT_SENTINEL"], !defaultSentinel.isEmpty
        else {
            XCTFail("A2 opt-in fixture data must identify the exact stock HTTPS fixture, profile, and sentinels.")
            return
        }

        let credentials = try readCredentials(at: stockCredentialsPath)
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = []
        app.launch()
        defer { clearPasteboard() }

        prepareNormalSignIn(app: app)
        let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
        if !app.textFields["onboarding-server-url"].exists {
            XCTAssertTrue(welcome.waitForExistence(timeout: 15), "Normal sign-out must return to Welcome.")
            let existingServer = app.buttons["Already have a server?"]
            XCTAssertTrue(existingServer.waitForExistence(timeout: 5))
            existingServer.tap()
        }
        let serverURL = app.textFields["onboarding-server-url"]
        XCTAssertTrue(serverURL.waitForExistence(timeout: 5))
        replacePublicText(serverURL, with: approvedLiveOrigin, app: app)
        app.buttons["Test Connection"].tap()
        let username = app.textFields["onboarding-username"]
        let password = app.secureTextFields["onboarding-password"]
        XCTAssertTrue(username.waitForExistence(timeout: 30), "The approved HTTPS origin must advertise username auth.")
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        replacePublicText(username, with: credentials.username, app: app)
        pasteSecret(credentials.password, into: password, app: app)
        app.buttons["Connect"].tap()
        dismissKnownPasswordSavePrompt(app: app)
        waitForPostLoginDestination(app: app)

        for tabName in ["Control", "Sessions"] {
            let tab = app.buttons[tabName]
            assertHittable(tab, timeout: 15, message: "The production shell must expose \(tabName).")
            tab.tap()
            do {
                let evidenceName = "a2-\(tabName.lowercased())-owned-profile-first-load"
                defer {
                    attachScreenshot(named: evidenceName)
                    attachAccessibilitySnapshot(named: "\(evidenceName)-accessibility", app: app)
                }

                // Control exposes utility/profile rows, not chat history.
                // Check first-load session ownership only on the Sessions surface,
                // before interacting with any profile picker.
                if tabName == "Sessions" {
                    XCTAssertTrue(app.staticTexts[selectedSentinel].waitForExistence(timeout: 20),
                                  "Sessions must publish the selected-profile-only row on its first load.")
                    XCTAssertFalse(app.staticTexts[defaultSentinel].exists,
                                   "Sessions must not publish the default-profile sentinel.")
                    continue
                }

                let profileDisclosure = app.buttons["Expand active profile picker"]
                XCTAssertTrue(profileDisclosure.waitForExistence(timeout: 15),
                              "\(tabName) must expose the collapsed active-profile disclosure.")
                profileDisclosure.tap()

                let activeProfile = app.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH %@", "Active profile, \(profile),")
                ).firstMatch
                XCTAssertTrue(activeProfile.waitForExistence(timeout: 15),
                              "\(tabName) must identify the fixture profile as active without changing it.")
            }
        }
    }

    func testMuseComposerKeepsDraftAboveKeyboard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--composer-test-fresh-draft"]
        app.launch()
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        // This DEBUG fixture starts with an empty draft without modifying
        // any persisted drafts from earlier simulator sessions.
        let clearedDraft = (composer.value as? String) ?? ""
        XCTAssertTrue(clearedDraft.isEmpty || clearedDraft == composer.placeholderValue)
        composer.typeText("A short draft\nwith a second line")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(composer.frame.maxY, keyboard.frame.minY + 1)
        XCTAssertTrue(app.buttons["Composer options"].isHittable)
        let send = app.buttons["Send"]
        let voice = app.buttons["Voice input"]
        XCTAssertTrue(send.isHittable)
        XCTAssertTrue(voice.isHittable)
        let twoLineSendY = send.frame.midY
        let twoLineVoiceY = voice.frame.midY
        XCTAssertLessThanOrEqual(abs(twoLineSendY - twoLineVoiceY), 3,
                                 "Send and microphone must share a stable baseline at two lines.")
        attachScreenshot(named: "muse-composer-keyboard-two-lines")

        composer.typeText("\nthird line\nfourth line")
        XCTAssertLessThanOrEqual(composer.frame.maxY, keyboard.frame.minY + 1)
        XCTAssertGreaterThanOrEqual(composer.frame.height, 80,
                                    "Four draft lines should expand the text field instead of clipping it.")
        XCTAssertTrue(send.isHittable && voice.isHittable)
        XCTAssertLessThanOrEqual(abs(send.frame.midY - voice.frame.midY), 3,
                                 "The controls must stay aligned as the draft grows.")
        XCTAssertGreaterThan(send.frame.midY, twoLineSendY - 8,
                             "Growing the draft must not move the controls upward into the text.")
        attachScreenshot(named: "muse-composer-keyboard-four-lines")
        // No send: this fixture deliberately has no gateway or credentials.
    }

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

    func testTallMixedTranscriptRepeatedArrowReachesConcreteTail() {
        exerciseTallMixedTranscriptArrow(disableHighlighting: false)
    }

    func testFourTallMixedTranscriptColdManualArrowAndReopenDiagnostic() {
        continueAfterFailure = true
        let app = XCUIApplication()
        let terminalText = "End of four-row mixed conversation."

        for followsLatest in [false, true] {
            let args = ["--chat-performance-four-tall-lab", "--chat-viewport-diagnostic",
                        "--composer-test-fresh-draft"]
                + (followsLatest ? ["--chat-viewport-follow-latest-open"] : [])
            for visit in 1...2 {
                app.terminate()
                app.launchArguments = args
                print("FOUR_TALL_LAUNCH latest=\(followsLatest) visit=\(visit) epoch=\(Date().timeIntervalSince1970)")
                app.launch()
                let scroll = app.scrollViews["chat-transcript-scroll"]
                XCTAssertTrue(scroll.waitForExistence(timeout: 15))
                let firstRow = app.staticTexts["message-row:four-tall-message-0"]
                let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", terminalText)).firstMatch
                let firstReadable = followsLatest
                    ? tail.waitForExistence(timeout: 20) && tail.isHittable
                    : firstRow.waitForExistence(timeout: 20) && firstRow.isHittable
                print("FOUR_TALL_FIRST_READABLE latest=\(followsLatest) visit=\(visit) visible=\(firstReadable) epoch=\(Date().timeIntervalSince1970)")
                XCTAssertTrue(firstReadable, "Cold viewport must show its real selected row")
                guard visit == 1 else { continue }

                let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: followsLatest ? 0.25 : 0.82))
                let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: followsLatest ? 0.78 : 0.18))
                print("FOUR_TALL_MANUAL_BEGIN latest=\(followsLatest) epoch=\(Date().timeIntervalSince1970)")
                start.press(forDuration: 0.05, thenDragTo: end)
                print("FOUR_TALL_MANUAL_END latest=\(followsLatest) epoch=\(Date().timeIntervalSince1970)")
                let arrow = app.buttons[scrollToLatestLabel]
                XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
                if arrow.exists && arrow.isHittable {
                    print("FOUR_TALL_ARROW_TAP latest=\(followsLatest) epoch=\(Date().timeIntervalSince1970)")
                    arrow.tap()
                    let reachedTail = tail.waitForExistence(timeout: 20) && tail.isHittable
                    print("FOUR_TALL_ARROW_TAIL latest=\(followsLatest) visible=\(reachedTail) epoch=\(Date().timeIntervalSince1970)")
                    XCTAssertTrue(reachedTail, "Arrow must expose the real final rich source")
                }
            }
        }
        app.terminate()
    }

    func testFourTallCodePreviewOpensSelectableFullSource() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-four-tall-lab", "--chat-viewport-follow-latest-open",
                               "--chat-viewport-diagnostic", "--composer-test-fresh-draft"]
        print("FOUR_TALL_PREVIEW_LAUNCH epoch=\(Date().timeIntervalSince1970)")
        app.launch()
        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "End of four-row mixed conversation."
        )).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 20) && tail.isHittable,
                      "A previewed giant code block must not blank the cold real tail.")
        print("FOUR_TALL_PREVIEW_FIRST_READABLE epoch=\(Date().timeIntervalSince1970)")
        attachScreenshot(named: "four-tall-preview-cold-tail")

        let viewFull = app.buttons["view-full-code"].firstMatch
        for _ in 0..<8 where !viewFull.isHittable {
            transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.24))
                .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.78)))
        }
        XCTAssertTrue(viewFull.isHittable && viewFull.label.contains("View full code"),
                      "The compact code preview must expose an explicit full-source action.")
        viewFull.tap()
        let fullCode = app.textViews["full-code-text"]
        XCTAssertTrue(fullCode.waitForExistence(timeout: 10) && fullCode.isHittable)
        let source = fullCode.value as? String ?? ""
        XCTAssertTrue(source.contains("SEMREH_FOUR_TALL_CODE_END"),
                      "The selectable viewer must expose the actual last code line in AX.")
        XCTAssertEqual(source.components(separatedBy: "let value = Array(0..<1_000).reduce(0, +)").count - 1, 320)
        app.buttons["Copy full code"].tap()
        // The UI test runner cannot synchronously read the app's pasteboard on
        // this Simulator runtime. The production action assigns `content`
        // directly; the viewer's AX value above checks that full source.
        let sheetToolbar = app.navigationBars["Swift"]
        XCTAssertTrue(sheetToolbar.waitForExistence(timeout: 5))
        let enableWrap = sheetToolbar.buttons["Enable code line wrapping"]
        let disableWrap = sheetToolbar.buttons["Disable code line wrapping"]
        let inlineWrap = transcript.buttons["Enable code line wrapping"]
        XCTAssertFalse(inlineWrap.isHittable,
                       "The code block behind the modal sheet must not intercept its toolbar controls.")
        let initiallyWrapped = disableWrap.exists
        (initiallyWrapped ? disableWrap : enableWrap).tap()
        XCTAssertTrue((initiallyWrapped ? enableWrap : disableWrap).waitForExistence(timeout: 5))
        (initiallyWrapped ? enableWrap : disableWrap).tap()
        XCTAssertEqual(fullCode.value as? String, source,
                       "Wrap toggles must not change selectable code bytes.")
        fullCode.press(forDuration: 1)
        XCTAssertTrue(app.menuItems["Copy"].exists || app.buttons["Copy"].exists,
                      "The full-code text view must offer native text selection.")
        attachScreenshot(named: "four-tall-full-code-selection")

        app.buttons["Done"].tap()
        let dragStart = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.25))
        let dragEnd = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.78))
        print("FOUR_TALL_PREVIEW_MANUAL_BEGIN epoch=\(Date().timeIntervalSince1970)")
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        print("FOUR_TALL_PREVIEW_MANUAL_END epoch=\(Date().timeIntervalSince1970)")
        attachScreenshot(named: "four-tall-preview-after-manual-drag")
        let arrow = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
        print("FOUR_TALL_PREVIEW_ARROW_TAP epoch=\(Date().timeIntervalSince1970)")
        arrow.tap()
        XCTAssertTrue(tail.waitForExistence(timeout: 10) && tail.isHittable,
                      "Closing the full-code viewer must preserve the real transcript tail.")
        print("FOUR_TALL_PREVIEW_ARROW_TAIL epoch=\(Date().timeIntervalSince1970)")
        attachScreenshot(named: "four-tall-preview-return-tail")
    }

    func testTallMixedTranscriptWithoutHighlightingReachesConcreteTail() {
        exerciseTallMixedTranscriptArrow(disableHighlighting: true)
    }

    func testViewportPrototypeTallMixedRepeatedArrow() {
        exerciseTallMixedTranscriptArrow(disableHighlighting: false, prototype: true)
    }

    func testViewportPrototypeTenThousandRows() {
        exerciseViewportPrototypeTenThousandRows()
    }

    func testOptInStableViewportRepresentative120AndTenThousandRows() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for count in [120, 10_000] {
            app.terminate()
            app.launchArguments = [performanceLabArgument, "--chat-stable-viewport"]
            if count == 120 { app.launchArguments.append("--representative-count=120") }
            app.launch()
            let scroll = app.scrollViews["prototype-transcript-scroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 15), "Production-compiled viewport must be active in normal ChatView.")
            let arrow = app.buttons["Prototype scroll to latest"]
            XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
            arrow.tap()
            let marker = count == 120 ? "Representative conversation complete." : endMarker
            let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
            assertHittable(tail, timeout: 15, message: "Stable viewport must reach the concrete \(count)-row tail.")
            XCTAssertFalse(arrow.waitForExistence(timeout: 2))
            attachScreenshot(named: "stable-viewport-\(count)-tail")
        }
    }

    func testOptInSingleNativeRichRepresentativeRowIsMountedInChatView() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120", "--chat-stable-viewport", "--native-rich-row-prototype"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
        arrow.tap()
        let native = app.otherElements["native-rich-row-mounted"]
        XCTAssertTrue(native.waitForExistence(timeout: 15), "One native rich row must replace MarkdownUI in normal ChatView.")
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
        assertHittable(tail, timeout: 15, message: "Native rich row must expose the concrete 120-row tail.")
        attachScreenshot(named: "native-rich-one-row-120-tail")
        let copy = native.buttons["Copy code"].firstMatch
        for _ in 0..<5 {
            if copy.isHittable { break }
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.28))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.76)))
        }
        if !copy.isHittable { print("NATIVE_RICH_AX_COPY \(native.debugDescription)") }
        XCTAssertTrue(copy.isHittable, "Code Copy must be reachable in the mounted native row.")
        copy.tap()
        XCTAssertTrue(app.buttons["Copied code"].firstMatch.waitForExistence(timeout: 3))
        attachScreenshot(named: "native-rich-one-row-code-interaction")
        let codeLine = native.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "let answer = values.map")).firstMatch
        if !codeLine.isHittable { print("NATIVE_RICH_AX_LINE \(native.debugDescription)") }
        XCTAssertTrue(codeLine.isHittable, "Native code must expose its visible text for response actions.")
        codeLine.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3))
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        let fullText = selection.value as? String ?? ""
        XCTAssertTrue(fullText.contains("## Response 119"))
        XCTAssertTrue(fullText.contains("Representative conversation complete."))
    }

    func testOptInDirectTwoRowsPreserveActionsAndDisclosureFallback() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-two-row-proof",
                               "--native-rich-lifecycle-fixture"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        arrow.tap()
        let assistant = app.otherElements.containing(.staticText, identifier: "message-row:representative-119")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        let outgoing = app.otherElements.containing(.staticText, identifier: "message-row:representative-118")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        if !assistant.waitForExistence(timeout: 15) { print("DIRECT_TWO_AX \(app.debugDescription)") }
        XCTAssertTrue(assistant.exists, "The rich assistant must mount as a direct row in real ChatView")
        XCTAssertTrue(outgoing.exists, "The adjacent outgoing bubble must mount directly")
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:representative-119").count, 1,
                       "VoiceOver must not announce two response summaries")
        let tail = assistant.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
        assertHittable(tail, timeout: 10, message: "Direct response tail must be visible")
        attachScreenshot(named: "direct-two-tail")
        let originalHeight = assistant.frame.height
        app.buttons["Refresh rows"].tap()
        XCTAssertTrue(assistant.exists, "Unchanged render-revision bump must not tear down a direct row")
        XCTAssertEqual(assistant.frame.height, originalHeight, accuracy: 0.1,
                       "Equivalent cache revision must not cause a second height motion")
        assertHittable(tail, timeout: 10, message: "Revision refresh must preserve the visible response")

        let copyCode = assistant.buttons["Copy code"]
        XCTAssertTrue(copyCode.exists, "Code Copy must be exposed in the direct row AX tree: \(assistant.debugDescription)")
        XCTAssertTrue(copyCode.isHittable, "Code Copy must be available; frame=\(copyCode.frame) row=\(assistant.frame) tree=\(assistant.debugDescription)")
        copyCode.tap()
        XCTAssertTrue(assistant.buttons["Copied code"].waitForExistence(timeout: 3))
        let codeLine = assistant.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "let answer = values.map")).firstMatch
        XCTAssertTrue(codeLine.isHittable)
        codeLine.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3),
                      "The direct row must preserve full-response Select Text")
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        let selectedSource = selection.value as? String ?? ""
        XCTAssertTrue(selectedSource.contains("## Response 119"))
        XCTAssertTrue(selectedSource.contains("Representative conversation complete."))
        app.buttons["Done"].firstMatch.tap()

        let thinking = assistant.buttons["Thinking"]
        XCTAssertTrue(thinking.isHittable, "Collapsed thinking must have a real disclosure control")
        thinking.tap()
        XCTAssertFalse(assistant.exists, "Unsupported expanded detail must visibly fall back to the old row")
        let detail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Check the relevant evidence and explain the result.")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "Fallback must expand actual reasoning detail")
        let fallbackTail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
        assertHittable(fallbackTail, timeout: 10, message: "Disclosure fallback must preserve bottom reader anchor")
        attachScreenshot(named: "direct-two-expanded-thinking-fallback")
    }

    func testOptInBasicFirstVisibleRowsPreserveReadableActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-first-visible-basic"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "First readable response must mount native before the first frame")
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:representative-1").count, 1)
        XCTAssertTrue(first.staticTexts["Response 1"].isHittable)
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "A readable explanation with")).firstMatch.isHittable)
        for cell in ["Check", "State", "Rendering", "Ready"] {
            XCTAssertTrue(first.staticTexts[cell].exists, "Parsed table cell \(cell) must be visible and accessible")
        }
        let bodyCanvas = first.otherElements["native-rich-row"].firstMatch
        XCTAssertTrue(bodyCanvas.exists)
        XCTAssertFalse(bodyCanvas.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "| --- | --- |")).firstMatch.exists,
            "The table separator must not leak into visible body lines (the full-source AX summary stays intact)")
        attachScreenshot(named: "direct-basic-first-readable")

        let copyButtons = first.buttons.matching(identifier: "Copy code")
        XCTAssertEqual(copyButtons.count, 1, "The Swift block must retain its dedicated Copy control")
        XCTAssertTrue(copyButtons.element(boundBy: 0).isHittable)
        copyButtons.element(boundBy: 0).tap()
        XCTAssertTrue(first.buttons["Copied code"].waitForExistence(timeout: 3))

        let codeLine = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "let answer = values.map")).firstMatch
        XCTAssertTrue(codeLine.isHittable)
        codeLine.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3))
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        let source = selection.value as? String ?? ""
        XCTAssertTrue(source.contains("## Response 1"))
        XCTAssertTrue(source.contains("| Check | State |"))
        XCTAssertTrue(source.contains("Continue the review."))
        app.buttons["Done"].firstMatch.tap()

        let thinking = first.buttons["Thinking"]
        XCTAssertTrue(thinking.isHittable)
        let collapsedHeight = first.frame.height
        let anchoredTop = first.frame.minY
        thinking.tap()
        XCTAssertTrue(first.exists, "Thinking expansion must retain the native row")
        let detailFirstLine = first.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Check the relevant evidence")).firstMatch
        let detailLastLine = first.staticTexts["result."]
        XCTAssertTrue(detailFirstLine.waitForExistence(timeout: 10),
                      "Expanded Thinking source must expose its first visible line to AX")
        XCTAssertTrue(detailLastLine.isHittable, "Expanded Thinking must expose its wrapped continuation")
        XCTAssertEqual(detailFirstLine.label + detailLastLine.label,
                       "Check the relevant evidence and explain the result.",
                       "AX line order must reconstruct the canonical reasoning source")
        XCTAssertGreaterThan(first.frame.height, collapsedHeight + 10)
        XCTAssertEqual(first.frame.minY, anchoredTop, accuracy: 0.5,
                       "Disclosure must preserve the first visible row anchor")
        attachScreenshot(named: "direct-basic-native-thinking-expanded")
        first.buttons["Thinking"].tap()
        XCTAssertTrue(detailFirstLine.waitForNonExistence(timeout: 10))
        XCTAssertTrue(detailLastLine.waitForNonExistence(timeout: 10))
        XCTAssertEqual(first.frame.height, collapsedHeight, accuracy: 0.5,
                       "Repeating disclosure must return to the exact cached collapsed geometry")
        XCTAssertEqual(first.frame.minY, anchoredTop, accuracy: 0.5)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58))
            .press(forDuration: 0.06,
                   thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertLessThan(first.frame.minY, anchoredTop - 30,
                          "Vertical drag inside the native response must move its parent transcript")
    }

    func testOptInPremountRichFirstRowSemanticAndInteractionGate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-first-visible-basic", "--native-direct-premount-rich-one",
                               "--native-direct-premount-rich-link-bidi"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:representative-1").count, 1)
        let initialHeight = first.frame.height
        XCTAssertTrue(first.staticTexts["Response 1"].exists)
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "العربية تبدأ السطر")).firstMatch.exists)
        for cell in ["Check", "State", "Rendering", "Ready"] {
            XCTAssertTrue(first.staticTexts[cell].exists, "Direct-AST table cell \(cell) must retain AX")
        }
        XCTAssertTrue(first.buttons["Copy code"].exists)
        let link = first.links["Reference source"]
        XCTAssertTrue(link.exists, "Link must be independently discoverable by VoiceOver")
        XCTAssertTrue(link.isHittable, "Prepared link must be visible at its measured rect")
        link.tap() // The synthetic URL is intercepted by the DEBUG fixture, not opened externally.
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5,
                       "Link activation must not remount or refine the prepared row")
        attachScreenshot(named: "premount-rich-first-collapsed")

        let code = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "let answer = values.map")).firstMatch
        XCTAssertTrue(code.exists)
        code.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3))
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        let source = selection.value as? String ?? ""
        XCTAssertTrue(source.contains("## Response 1"))
        XCTAssertTrue(source.contains("| Check | State |"))
        XCTAssertTrue(source.contains("[Reference source](https://example.invalid/reference)"))
        app.buttons["Done"].firstMatch.tap()

        let thinking = first.buttons["Thinking"]
        XCTAssertTrue(thinking.exists)
        thinking.tap()
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Check the relevant evidence")).firstMatch.exists)
        XCTAssertGreaterThan(first.frame.height, initialHeight + 10)
        attachScreenshot(named: "premount-rich-first-thinking")
        thinking.tap()
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58))
            .press(forDuration: 0.06,
                   thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertLessThan(first.frame.minY, 0,
                          "Vertical drag on rich row must move the parent transcript")
    }

    func testOptInPremountRichFirstRowCombinedActivityAndGeometryGate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-first-visible-basic", "--native-direct-premount-rich-one",
                               "--native-direct-premount-rich-link-bidi",
                               "--native-direct-two-tool-first-fixture"]
        app.launch()
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15), "The first rich assistant must mount natively.")
        let initialHeight = first.frame.height
        let initialTop = first.frame.minY
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5,
                           "A premounted first row must not visibly swap heights while idle.")
        }
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:representative-1").count, 1)
        XCTAssertTrue(first.staticTexts["Response 1"].exists)
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "العربية تبدأ السطر")).firstMatch.exists)
        for cell in ["Check", "State", "Rendering", "Ready"] {
            XCTAssertTrue(first.staticTexts[cell].exists, "The native table must expose \(cell).")
        }
        let link = first.links["Reference source"]
        XCTAssertTrue(link.isHittable)
        link.tap() // The DEBUG fixture intercepts this synthetic URL.
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5)
        XCTAssertTrue(first.buttons["Copy code"].exists)
        let read = first.buttons["native-tool-action-first-action-read"]
        let search = first.buttons["native-tool-action-first-action-search"]
        XCTAssertTrue(read.isHittable && search.isHittable)
        XCTAssertTrue(first.buttons["Thinking"].isHittable)
        attachScreenshot(named: "native-one-row-combined-collapsed")

        first.buttons["Copy code"].tap()
        XCTAssertTrue(first.buttons["Copied code"].waitForExistence(timeout: 3))
        let code = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "let answer = values.map")).firstMatch
        XCTAssertTrue(code.isHittable)
        code.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3))
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        let source = selection.value as? String ?? ""
        XCTAssertTrue(source.contains("## Response 1"))
        XCTAssertTrue(source.contains("| Check | State |"))
        XCTAssertTrue(source.contains("[Reference source](https://example.invalid/reference)"))
        app.buttons["Done"].firstMatch.tap()

        first.buttons["Thinking"].tap()
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Check the relevant evidence")).firstMatch.exists)
        XCTAssertGreaterThan(first.frame.height, initialHeight + 10)
        XCTAssertEqual(first.frame.minY, initialTop, accuracy: 0.5)
        first.buttons["Thinking"].tap()
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5)
        read.tap()
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "fixtures/research.md")).firstMatch.exists)
        XCTAssertEqual(first.buttons.matching(identifier: "Copy code").count, 2)
        XCTAssertGreaterThan(first.frame.height, initialHeight + 20)
        XCTAssertEqual(first.frame.minY, initialTop, accuracy: 0.5)
        search.tap()
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "synthetic research question")).firstMatch.exists)
        XCTAssertGreaterThan(first.frame.height, initialHeight + 50)
        XCTAssertEqual(first.frame.minY, initialTop, accuracy: 0.5)
        attachScreenshot(named: "native-one-row-combined-activity-expanded")
        read.tap()
        search.tap()
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5)
        XCTAssertEqual(first.frame.minY, initialTop, accuracy: 0.5)
        XCTAssertTrue(first.exists, "Disclosures must not fall back to a legacy host.")
    }

    func testDebugNativeRichGroupedParityAndPreviewCard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-first-visible-basic", "--native-direct-premount-rich-one",
                               "--native-direct-premount-rich-link-bidi",
                               "--native-direct-two-tool-first-fixture", "--native-direct-parity-gate"]
        app.launch()
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let group = first.buttons["native-tool-action-__native_group__"]
        XCTAssertTrue(group.isHittable)
        XCTAssertEqual(group.label, "2 actions")
        XCTAssertEqual(group.value as? String, "Completed")
        XCTAssertFalse(first.buttons["native-tool-action-first-action-read"].exists)
        let preview = first.buttons["Link preview for example.invalid"]
        XCTAssertTrue(preview.exists, "The exact product preview host must mount in the native row")
        attachScreenshot(named: "native-grouped-parity-collapsed")
        group.tap()
        XCTAssertTrue(first.buttons["native-tool-action-first-action-read"].exists)
        XCTAssertTrue(first.buttons["native-tool-action-first-action-search"].exists)
        attachScreenshot(named: "native-grouped-parity-expanded")
        group.tap()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            .press(forDuration: 0.12,
                   thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58)),
                   withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(preview.isHittable)
        attachScreenshot(named: "native-grouped-parity-preview")
    }

    func testOptInPremountRichFirstRowLongCodeWrapGate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-first-visible-basic", "--native-direct-premount-rich-one",
                               "--native-direct-premount-rich-wrap-long"]
        app.launch()
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        if first.buttons["Disable code line wrapping"].exists {
            first.buttons["Disable code line wrapping"].tap()
        }
        let enable = first.buttons["Enable code line wrapping"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        let unwrappedHeight = first.frame.height
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "FAR_END_MARKER")).firstMatch.exists)
        enable.tap()
        XCTAssertTrue(first.buttons["Disable code line wrapping"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(first.frame.height, unwrappedHeight + 50)
        attachScreenshot(named: "premount-rich-first-wrapped")
        first.buttons["Disable code line wrapping"].tap()
        XCTAssertTrue(first.buttons["Enable code line wrapping"].waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.height, unwrappedHeight, accuracy: 0.5,
                       "Alternate actor snapshot must return to its exact cached height")
    }

    func testOptInPremountFourRowWindowPreviewWrapAndWidth() {
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-premount-window-gate",
                               "--native-direct-first-visible-basic", "--native-direct-premount-rich-one",
                               "--native-direct-premount-rich-link-bidi",
                               "--native-direct-premount-rich-wrap-long"]
        app.launch()
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let initialWidth = first.frame.width
        let initialHeight = first.frame.height
        let preview = first.buttons["Link preview for example.invalid"]
        XCTAssertTrue(preview.exists, "The existing preview card must remain separately accessible")
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        XCTAssertTrue(first.staticTexts["Response 1"].isHittable,
                      "The synthetic preview tap must stay inside the chat fixture")
        XCTAssertTrue(first.staticTexts["Response 1"].isHittable)
        attachScreenshot(named: "premount-window-preview-portrait")

        if first.buttons["Disable code line wrapping"].exists {
            first.buttons["Disable code line wrapping"].tap()
        }
        let enable = first.buttons["Enable code line wrapping"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        let unwrappedHeight = first.frame.height
        enable.tap()
        XCTAssertTrue(first.buttons["Disable code line wrapping"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(first.frame.height, unwrappedHeight + 50)
        XCTAssertTrue(preview.exists, "Wrap must retain the reserved preview card")
        first.buttons["Disable code line wrapping"].tap()
        XCTAssertTrue(first.buttons["Enable code line wrapping"].waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.height, unwrappedHeight, accuracy: 0.5)
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5)

        func waitForWidth(_ predicate: (CGFloat) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if predicate(first.frame.width) { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            }
            return false
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForWidth { $0 > initialWidth + 100 })
        XCTAssertEqual(app.staticTexts.matching(identifier: "message-row:representative-1").count, 1)
        XCTAssertTrue(first.staticTexts["Response 1"].exists)
        XCTAssertTrue(preview.exists)
        attachScreenshot(named: "premount-window-preview-landscape")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForWidth { $0 < initialWidth + 1 })
        let portraitDeadline = Date().addingTimeInterval(5)
        while abs(first.frame.height - initialHeight) >= 0.5 && Date() < portraitDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(first.frame.height, initialHeight, accuracy: 0.5)
        XCTAssertTrue(first.staticTexts["Response 1"].isHittable)
        XCTAssertTrue(preview.exists)
        attachScreenshot(named: "premount-window-preview-return-portrait")
    }

    func testOptInFirstVisibleNativeToolActionsExpandIndependently() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-first-visible-basic",
                               "--native-direct-two-tool-first-fixture"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let read = first.buttons["native-tool-action-first-action-read"]
        let search = first.buttons["native-tool-action-first-action-search"]
        XCTAssertTrue(read.isHittable)
        XCTAssertTrue(search.isHittable)
        XCTAssertEqual(read.label, "Read file")
        XCTAssertEqual(search.label, "Search web")
        XCTAssertEqual(read.value as? String, "Completed")
        XCTAssertEqual(first.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "native-tool-action-")).count, 2,
            "There must be one compact disclosure per action, not a duplicate group summary")
        let collapsedHeight = first.frame.height
        let anchoredTop = first.frame.minY
        attachScreenshot(named: "direct-two-tool-collapsed")

        read.tap()
        let path = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "fixtures/research.md")).firstMatch
        let readResult = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Read the synthetic research note.")).firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 10), "Read-file arguments must be native AX text")
        XCTAssertTrue(readResult.exists, "Read-file result must be native AX text")
        XCTAssertEqual(first.buttons.matching(identifier: "Copy code").count, 2,
                       "Tool detail and response code need separate Copy controls")
        first.buttons.matching(identifier: "Copy code").firstMatch.tap()
        XCTAssertTrue(first.buttons["Copied code"].waitForExistence(timeout: 3))
        XCTAssertGreaterThan(first.frame.height, collapsedHeight + 50)
        XCTAssertEqual(first.frame.minY, anchoredTop, accuracy: 0.5)
        XCTAssertTrue(search.isHittable, "The second action must remain directly reachable")
        let afterReadHeight = first.frame.height
        search.tap()
        let query = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "synthetic research question")).firstMatch
        let searchResult = first.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Two synthetic source matches found.")).firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        XCTAssertTrue(searchResult.exists)
        XCTAssertTrue(path.exists, "Opening the second action must not discard the first")
        XCTAssertGreaterThan(first.frame.height, afterReadHeight + 50)
        XCTAssertEqual(first.frame.minY, anchoredTop, accuracy: 0.5)
        attachScreenshot(named: "direct-two-tool-expanded")

        read.tap()
        XCTAssertTrue(path.waitForNonExistence(timeout: 10))
        XCTAssertTrue(query.exists, "The other action must stay expanded independently")
        search.tap()
        XCTAssertTrue(query.waitForNonExistence(timeout: 10))
        XCTAssertEqual(first.frame.height, collapsedHeight, accuracy: 0.5)
        XCTAssertEqual(first.frame.minY, anchoredTop, accuracy: 0.5)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.06,
                   thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertLessThan(first.frame.minY, anchoredTop - 30,
                          "Vertical drag on a tool-rich row must move the transcript")
    }

    func testOptInDirectTwoRowsLongCodeWrapAndVerticalDrag() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-two-row-proof",
                               "--native-rich-wrap-fixture"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        app.buttons["Prototype scroll to latest"].tap()
        let assistant = app.otherElements.containing(.staticText, identifier: "message-row:representative-119")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 15))
        let tail = assistant.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
        assertHittable(tail, timeout: 10, message: "Direct long-code tail must be present")
        if assistant.buttons["Disable code line wrapping"].exists {
            assistant.buttons["Disable code line wrapping"].tap()
        }
        let enable = assistant.buttons["Enable code line wrapping"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10))
        let originalHeight = assistant.frame.height
        let codeLine = assistant.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "FAR_END_MARKER")).firstMatch
        XCTAssertTrue(codeLine.exists)
        func horizontalOffset() -> Int {
            let words = (enable.value as? String ?? "").split(separator: " ")
            return words.count > 2 ? (Int(words[2]) ?? -1) : -1
        }
        XCTAssertEqual(horizontalOffset(), 0)
        let start = assistant.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.58))
        let end = assistant.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.58))
        for _ in 0..<10 { start.press(forDuration: 0.06, thenDragTo: end) }
        XCTAssertGreaterThan(horizontalOffset(), 500,
                             "Horizontal pan must move the actual code scroller, not merely keep its button visible")
        XCTAssertTrue(enable.isHittable)
        attachScreenshot(named: "direct-two-long-code-panned")

        enable.tap()
        XCTAssertTrue(assistant.buttons["Disable code line wrapping"].waitForExistence(timeout: 10))
        XCTAssertGreaterThan(assistant.frame.height, originalHeight + 50,
                             "Wrap must grow the direct measured row")
        assertHittable(tail, timeout: 10, message: "Wrapped direct row must retain the bottom anchor")
        attachScreenshot(named: "direct-two-long-code-wrapped")
        assistant.buttons["Disable code line wrapping"].tap()
        XCTAssertTrue(assistant.buttons["Enable code line wrapping"].waitForExistence(timeout: 10))
        assertHittable(tail, timeout: 10, message: "Second toggle must keep the tail")
        let beforeVertical = tail.frame.minY
        assistant.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            .press(forDuration: 0.06,
                   thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertGreaterThan(tail.frame.minY - beforeVertical, 30,
                             "Vertical drag inside direct code must move parent transcript")
    }

    func testOptInNativeRichLongCodeWrapPanAndSavedPreference() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let arguments = [performanceLabArgument, "--representative-count=120", "--chat-stable-viewport",
                         "--native-rich-row-prototype", "--native-rich-wrap-fixture"]
        app.launchArguments = arguments
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        arrow.tap()
        let native = app.otherElements["native-rich-row-mounted"]
        XCTAssertTrue(native.waitForExistence(timeout: 15))
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
        assertHittable(tail, timeout: 15, message: "Unwrapped long code must not hide the tail")

        // Persisted preference can be left enabled by a previous failed run.
        if native.buttons["Disable code line wrapping"].exists {
            native.buttons["Disable code line wrapping"].tap()
        }
        let enable = native.buttons["Enable code line wrapping"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10))
        let unwrappedHeight = native.frame.height
        attachScreenshot(named: "native-rich-long-code-unwrapped-start")
        let longCodeLine = native.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "FAR_END_MARKER")).firstMatch
        XCTAssertTrue(longCodeLine.exists)
        let codeLineStartX = longCodeLine.frame.minX
        let start = native.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.56))
        let end = native.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.56))
        for _ in 0..<10 { start.press(forDuration: 0.06, thenDragTo: end) }
        XCTAssertLessThan(longCodeLine.frame.minX, codeLineStartX - 500,
                          "Mounted code AX geometry must shift with the visible horizontal pan")
        attachScreenshot(named: "native-rich-long-code-unwrapped-panned")
        XCTAssertTrue(enable.isHittable, "Horizontal code pan must leave header control reachable")

        enable.tap()
        let disable = native.buttons["Disable code line wrapping"]
        XCTAssertTrue(disable.waitForExistence(timeout: 10), "Preprepared wrapped snapshot must remain native")
        XCTAssertGreaterThan(native.frame.height, unwrappedHeight + 50, "Wrapped code must grow the measured row")
        assertHittable(tail, timeout: 10, message: "Wrap reflow must preserve bottom reader anchor")
        attachScreenshot(named: "native-rich-long-code-wrapped")
        let copy = native.buttons["Copy code"]
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(native.buttons["Copied code"].waitForExistence(timeout: 3))

        app.terminate()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        app.buttons["Prototype scroll to latest"].tap()
        let reopened = app.otherElements["native-rich-row-mounted"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 15))
        XCTAssertTrue(reopened.buttons["Disable code line wrapping"].waitForExistence(timeout: 10),
                      "Reopen must honor persisted code wrapping")
        reopened.buttons["Disable code line wrapping"].tap()
        XCTAssertTrue(reopened.buttons["Enable code line wrapping"].waitForExistence(timeout: 10))
        assertHittable(tail, timeout: 10, message: "Second toggle must preserve bottom reader anchor")
        let beforeVertical = tail.frame.minY
        print("NATIVE_RICH_VERTICAL_BEFORE native=\(reopened.frame) scroll=\(scroll.frame) tailY=\(beforeVertical)")
        reopened.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            .press(forDuration: 0.06, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .fast, thenHoldForDuration: 0)
        let afterVertical = tail.frame.minY
        print("NATIVE_RICH_VERTICAL_AFTER tailY=\(afterVertical)")
        XCTAssertGreaterThan(afterVertical - beforeVertical, 30,
                             "Vertical drag inside code must move the transcript rather than being captured by horizontal pan")
    }

    func testOptInAllRich120WrapStreamAndReopenState() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120", "--chat-stable-viewport",
                               "--native-rich-all-eligible-120", "--native-rich-lifecycle-fixture"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        arrow.tap()
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Representative conversation complete.")).firstMatch
        assertHittable(tail, timeout: 15, message: "Native 120-row tail must arrive before lifecycle actions")
        let native = tail.descendants(matching: .other)
            .matching(identifier: "native-rich-row-mounted").firstMatch
        XCTAssertTrue(native.waitForExistence(timeout: 15), "Response 119 must mount its native row")
        if native.buttons["Disable code line wrapping"].exists {
            native.buttons["Disable code line wrapping"].tap()
        }
        native.buttons["Enable code line wrapping"].tap()
        XCTAssertTrue(native.buttons["Disable code line wrapping"].waitForExistence(timeout: 10))
        assertHittable(tail, timeout: 10, message: "Global wrap change must retain bottom anchor")
        native.buttons["Disable code line wrapping"].tap()
        XCTAssertTrue(native.buttons["Enable code line wrapping"].waitForExistence(timeout: 10))
        let codeLine = native.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "let answer = values.map")).firstMatch
        XCTAssertTrue(codeLine.isHittable)
        codeLine.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3))
        app.buttons["Select Text"].tap()
        let selection = app.textViews["selectable-response-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        XCTAssertTrue((selection.value as? String ?? "").contains("## Response 119"))
        app.buttons["Done"].firstMatch.tap()
        app.buttons["Stream rich test turn"].tap()
        let streamEnd = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "SEMREH_MULTI_CHAT_STREAM_1")).firstMatch
        XCTAssertTrue(streamEnd.waitForExistence(timeout: 15), "Stream must retain its final durable text")
        XCTAssertEqual(app.buttons["Reopen rich chat"].value as? String, "122 rows")
        attachScreenshot(named: "native-rich-120-after-stream")
        app.buttons["Reopen rich chat"].tap()
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["Reopen rich chat"].value as? String, "122 rows")
        if arrow.isHittable { arrow.tap() }
        assertHittable(streamEnd, timeout: 15, message: "Reopened retained ChatView must keep the streamed tail")
        attachScreenshot(named: "native-rich-120-after-reopen")
    }

    func testDebugHostedRich120NativeViewportMotionAndLifecycleGate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-rich-lifecycle-fixture",
                               "--native-hosted-rich120-gate"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        print("SEMREH_HOSTED_RICH_ARROW_TAP at=\(Date())")
        arrow.tap()
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Representative conversation complete."
        )).firstMatch
        assertHittable(tail, timeout: 15, message: "Native host must reach actual rich response 119.")
        attachScreenshot(named: "hosted-rich-120-tail")
        XCTAssertTrue(app.buttons["Copy code"].firstMatch.exists, "Product Markdown code action must survive native hosting.")
        XCTAssertTrue(app.buttons["Stream rich test turn"].exists)
        app.buttons["Stream rich test turn"].tap()
        let streamEnd = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "SEMREH_MULTI_CHAT_STREAM_1"
        )).firstMatch
        XCTAssertTrue(streamEnd.waitForExistence(timeout: 15), "Streaming row must be mounted and readable.")
        attachScreenshot(named: "hosted-rich-120-streamed-tail")
        app.buttons["Reopen rich chat"].tap()
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        if arrow.isHittable { arrow.tap() }
        assertHittable(streamEnd, timeout: 15, message: "Reopen must preserve streamed content and tail.")
        attachScreenshot(named: "hosted-rich-120-reopened-tail")
    }

    func testDebugDirectRich120ArrowStreamAndReopenMotionGate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-target-first-immediate-diagnostic",
                               "--native-direct-premount-rich-one", "--native-direct-first-visible-basic",
                               "--native-direct-parity-gate", "--native-direct-body-cache-gate",
                               "--native-rich-lifecycle-fixture", "--native-hosted-rich120-gate"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        print("SEMREH_DIRECT_RICH120_ARROW_TAP at=\(Date())")
        arrow.tap()
        attachScreenshot(named: "direct-rich120-immediate-posttap")
        XCTAssertFalse(app.staticTexts["native-direct-arrow-unready"].exists,
                       "A cold far-arrow that cannot animate real prepared rows is NO-GO.")
        let tail = app.otherElements.containing(.staticText, identifier: "message-row:representative-119")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 15),
                      "The far tail must be an actual native rich row, not a SwiftUI host or proxy.")
        XCTAssertTrue(tail.staticTexts["Response 119"].isHittable)
        XCTAssertTrue(tail.buttons["Copy code"].exists)
        attachScreenshot(named: "direct-rich120-tail")
        XCTAssertTrue(app.buttons["Stream rich test turn"].exists)
        print("SEMREH_DIRECT_RICH120_STREAM_TAP at=\(Date()) tailFrame=\(tail.frame)")
        app.buttons["Stream rich test turn"].tap()
        let streamed = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "SEMREH_MULTI_CHAT_STREAM_1")).firstMatch
        XCTAssertTrue(streamed.waitForExistence(timeout: 15))
        let outgoing = app.otherElements.containing(.staticText,
            identifier: "message-row:perf-stream-message-1-user")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        let assistant = app.otherElements.containing(.staticText,
            identifier: "message-row:perf-stream-message-1-assistant")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(outgoing.exists, "Appended outgoing row must remain native and accessible.")
        XCTAssertTrue(assistant.exists, "Appended assistant row must remain native and accessible.")
        XCTAssertTrue(streamed.isHittable, "Final observed stream bytes must be visibly readable.")
        let motionSettled = expectation(for: NSPredicate(
            format: "value CONTAINS %@", "stream motion settled"), evaluatedWith: scroll)
        wait(for: [motionSettled], timeout: 5)
        XCTAssertEqual(scroll.value as? String, "stream motion settled; unexpected moves 0",
                       "Only the viewport display link may move the unchanged old row while the stream grows.")
        XCTAssertTrue(tail.exists && tail.buttons["Copy code"].exists,
                      "The preceding rich row must remain mounted and source-accurate through stream growth.")
        print("SEMREH_DIRECT_RICH120_STREAM_READY at=\(Date()) tailFrame=\(tail.frame) assistantFrame=\(assistant.frame)")
        attachScreenshot(named: "direct-rich120-streamed")
        app.buttons["Reopen rich chat"].tap()
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        if arrow.isHittable { arrow.tap() }
        XCTAssertTrue(streamed.waitForExistence(timeout: 15))
        XCTAssertTrue(streamed.isHittable, "Reopen arrow must visibly return to the native streamed tail.")
        attachScreenshot(named: "direct-rich120-reopened")
    }

    func testDebugDirectRich120StreamKeepsReaderAwayAnchored() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--representative-count=120",
                               "--chat-stable-viewport", "--native-direct-all120-diagnostic",
                               "--native-direct-target-first-immediate-diagnostic",
                               "--native-direct-premount-rich-one", "--native-direct-first-visible-basic",
                               "--native-direct-parity-gate", "--native-direct-body-cache-gate",
                               "--native-rich-lifecycle-fixture", "--native-hosted-rich120-gate"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let first = app.otherElements.containing(.staticText, identifier: "message-row:representative-1")
            .matching(identifier: "native-direct-transcript-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let originalY = first.frame.minY
        app.buttons["Stream rich test turn"].tap()
        let count = expectation(for: NSPredicate(format: "value == %@", "122 rows"),
                                evaluatedWith: app.buttons["Reopen rich chat"])
        wait(for: [count], timeout: 15)
        XCTAssertEqual(first.frame.minY, originalY, accuracy: 1,
                       "Appending below an away reader must preserve the visible native row's screen position.")
        XCTAssertTrue(first.staticTexts["Response 1"].isHittable)
        XCTAssertFalse((scroll.value as? String)?.contains("stream motion active") == true,
                       "An away reader must not enter automatic stream-follow motion.")
    }

    func testOptInStableViewportStreamsAndReopensLongChat() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-multi-lab", "--chat-stable-viewport"]
        app.launch()

        let scroll = app.scrollViews["prototype-transcript-scroll"]
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        arrow.tap()
        let originalTail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "End of 10,000-row conversation 1."
        )).firstMatch
        assertHittable(originalTail, timeout: 20, message: "Original long-chat tail must be present.")

        app.buttons["Stream test turn"].tap()
        let streamedTail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "SEMREH_MULTI_CHAT_STREAM_1"
        )).firstMatch
        assertHittable(streamedTail, timeout: 20, message: "Appended stream must stay visible at the bottom.")
        scroll.swipeDown()
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        arrow.tap()
        assertHittable(streamedTail, timeout: 20, message: "Arrow must return to appended stream.")

        app.buttons["Performance chat 2"].tap()
        XCTAssertTrue(app.otherElements["chat-detail:10,000-row performance lab 2"].waitForExistence(timeout: 15))
        app.buttons["Performance chat 1"].tap()
        XCTAssertTrue(app.otherElements["chat-detail:10,000-row performance lab 1"].waitForExistence(timeout: 15))
        assertHittable(streamedTail, timeout: 20, message: "Reopening must retain the streamed tail and viewport.")
        attachScreenshot(named: "stable-viewport-stream-reopen-tail")
    }

    func testViewportPrototypeCostProfile() {
        exerciseViewportPrototypeTenThousandRows(profilePause: true)
    }

    private func exerciseViewportPrototypeTenThousandRows(profilePause: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [performanceLabArgument, "--chat-viewport-prototype"]
        app.launch()
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 15))
        // Give the external sampler time to attach. This is diagnostic only;
        // the offscreen final row is not created or prewarmed during the pause.
        if profilePause { Thread.sleep(forTimeInterval: 15) }
        for cycle in 1...2 {
            if cycle > 1 {
                let transcript = app.scrollViews["prototype-transcript-scroll"]
                transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.3))
                    .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.7)))
                XCTAssertTrue(arrow.waitForExistence(timeout: 5))
            }
            arrow.tap()
            let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", endMarker)).firstMatch
            assertHittable(tail, timeout: 10, message: "Prototype must reach the concrete 10,000-row tail, cycle \(cycle).")
            XCTAssertFalse(arrow.waitForExistence(timeout: 2))
        }
        attachScreenshot(named: "prototype-ten-thousand-tail")
        if profilePause { Thread.sleep(forTimeInterval: 8) }
    }

    func testPrototypeVirtualCodeTallRepeatedArrow() {
        exerciseTallMixedTranscriptArrow(disableHighlighting: false, prototype: true, virtualCode: true)
    }

    private func exerciseTallMixedTranscriptArrow(disableHighlighting: Bool, prototype: Bool = false, virtualCode: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-tall-lab"]
        if prototype { app.launchArguments.append("--chat-viewport-prototype") }
        if virtualCode { app.launchArguments.append("--viewport-virtual-code") }
        if disableHighlighting { app.launchArguments.append("--tail-geometry-no-highlight") }
        app.launch()
        XCTAssertTrue(app.otherElements["chat-detail:Tall mixed transcript lab"].waitForExistence(timeout: 15))
        let transcript = app.scrollViews[prototype ? "prototype-transcript-scroll" : "chat-transcript-scroll"]
        let arrow = app.buttons[prototype ? "Prototype scroll to latest" : scrollToLatestLabel]
        for cycle in 1...3 {
            if cycle > 1 {
                // Isolate the vertical transcript gesture from the nested
                // horizontally scrolling code block under the viewport center.
                let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.3))
                let end = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.7))
                start.press(forDuration: 0.05, thenDragTo: end)
                attachScreenshot(named: "tall-mixed-after-outer-drag-\(cycle)")
            }
            XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
            arrow.tap()
            let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "End of tall mixed conversation.")).firstMatch
            assertHittable(tail, timeout: 10, message: "A tall mixed row must reach its actual end, cycle \(cycle).")
            XCTAssertFalse(arrow.waitForExistence(timeout: 2))
        }
        let codeText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "let measuredHeight = rows.reduce(0)")
        ).firstMatch
        XCTAssertTrue(codeText.exists, "Highlighted code must remain exposed as readable accessibility text.")
        if virtualCode { XCTAssertTrue(app.otherElements["prototype-virtual-code"].firstMatch.exists, "Candidate must actually be mounted.") }
        attachScreenshot(named: "tall-mixed-real-scroll-tail")
    }

    func testPrototypeHighlightedCodeSelectionBaseline() {
        exercisePrototypeCodeSelection(virtualCode: false)
    }

    func testPrototypeVirtualCodeFullSelection() {
        exercisePrototypeCodeSelection(virtualCode: true)
    }

    func testPrototypeVirtualCodeWrapAndOffscreenAccessibility() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-tall-lab", "--chat-viewport-prototype", "--viewport-virtual-code"]
        app.launch()
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 15))
        arrow.tap()
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "End of tall mixed conversation.")).firstMatch
        assertHittable(tail, timeout: 10, message: "Start at the concrete tall tail.")
        XCTAssertTrue(app.otherElements["prototype-virtual-code"].firstMatch.exists)
        let lines = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "let measuredHeight = rows.reduce(0)"))
        XCTAssertGreaterThanOrEqual(lines.count, 96, "Offscreen logical lines must remain accessible.")
        let transcript = app.scrollViews["prototype-transcript-scroll"]
        let enable = app.buttons["Enable code line wrapping"]
        let disable = app.buttons["Disable code line wrapping"]
        for _ in 0..<9 {
            if enable.firstMatch.isHittable || disable.firstMatch.isHittable { break }
            transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.8)))
        }
        let toggle = enable.firstMatch.isHittable ? enable.firstMatch : disable.firstMatch
        XCTAssertTrue(toggle.isHittable, "Reach the actual code header with reader gestures.")
        let initiallyWrapped = disable.firstMatch.isHittable
        toggle.tap()
        let reverse = initiallyWrapped ? enable.firstMatch : disable.firstMatch
        XCTAssertTrue(reverse.waitForExistence(timeout: 5) && reverse.isHittable,
                      "Wrapping must keep the code header at the reader's anchor.")
        attachScreenshot(named: "prototype-code-wrap-reader-anchor")
        reverse.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5) && toggle.isHittable)
        let copy = app.buttons["Copy code"].firstMatch
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["Copied code"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(arrow.waitForExistence(timeout: 5))
        arrow.tap()
        assertHittable(tail, timeout: 10, message: "Wrap/copy changes must not lose the actual tail.")
        XCTAssertFalse(arrow.waitForExistence(timeout: 2))
        attachScreenshot(named: "prototype-code-wrap-tail-return")
    }

    private func exercisePrototypeCodeSelection(virtualCode: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-tall-lab", "--chat-viewport-prototype"]
        if virtualCode { app.launchArguments.append("--viewport-virtual-code") }
        app.launch()
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 15))
        arrow.tap()
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "End of tall mixed conversation.")).firstMatch
        assertHittable(tail, timeout: 10, message: "Selection baseline needs the concrete tall tail.")
        if virtualCode { XCTAssertTrue(app.otherElements["prototype-virtual-code"].firstMatch.exists, "Candidate must actually be mounted.") }
        let lines = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "let measuredHeight = rows.reduce(0)"))
        guard let visible = lines.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            return XCTFail("A visible highlighted line is required for native selection inspection.")
        }
        visible.press(forDuration: 1)
        attachScreenshot(named: "prototype-code-selection-baseline")
        let copy = app.buttons["Copy"]
        XCTAssertTrue(copy.firstMatch.waitForExistence(timeout: 3), "Native code selection must offer Copy.")
        let select = app.buttons["Select Text"]
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        select.tap()
        let selectable = app.textViews["selectable-response-text"]
        XCTAssertTrue(selectable.waitForExistence(timeout: 3))
        let fullText = selectable.value as? String ?? ""
        XCTAssertTrue(fullText.contains("End of tall mixed conversation."))
        XCTAssertGreaterThan(fullText.components(separatedBy: "let measuredHeight = rows.reduce(0)").count, 90,
                             "Full logical code must remain selectable, not just visible lines.")
        attachScreenshot(named: "prototype-full-response-selection-baseline")
    }

    func testRepeatedScrollAwayAndArrowReturnKeepsEndMarkerReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [performanceLabArgument]
        app.launch()

        let chat = app.otherElements[chatIdentifier]
        XCTAssertTrue(chat.waitForExistence(timeout: 15),
                      "The server-free 10,000-row ChatView performance lab must launch.")
        let transcript = app.scrollViews.firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let scrollToLatest = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(scrollToLatest.waitForExistence(timeout: 10))

        // Exercise more than one ordinary away/return cycle. This is a
        // correctness check for the public XCTest interaction path, not an
        // FPS or deceleration measurement.
        for cycle in 1...2 {
            transcript.swipeDown()
            XCTAssertTrue(
                scrollToLatest.waitForExistence(timeout: 10),
                "Scroll-to-latest must remain available after cycle \(cycle)'s swipe away."
            )
            scrollToLatest.tap()

            let endMarker = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", self.endMarker)
            ).firstMatch
            assertHittable(
                endMarker,
                timeout: 25,
                message: "Cycle \(cycle)'s arrow return must reveal the deterministic end marker."
            )
            XCTAssertFalse(
                scrollToLatest.waitForExistence(timeout: 2),
                "Cycle \(cycle)'s scroll-to-latest action must clear at the bottom."
            )
        }
    }

    func testSyntheticProductionOpenFlickAndArrow120And10kMixed() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for count in [120, 10_000] {
            app.terminate()
            app.launchArguments = [performanceLabArgument, "--chat-viewport-diagnostic"]
            if count == 120 {
                app.launchArguments.append("--representative-count=120")
            } else {
                app.launchArguments.append("--native-direct-mixed-rich-10k")
            }
            app.launch()

            let transcript = app.scrollViews["chat-transcript-scroll"]
            XCTAssertTrue(transcript.waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "message-row:"
            )).firstMatch.waitForExistence(timeout: 15), "The opened viewport must realize a message row.")
            attachScreenshot(named: "synthetic-production-\(count)-open")

            for _ in 0..<3 {
                transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.84))
                    .press(forDuration: 0.01,
                           thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.15)),
                           withVelocity: .fast, thenHoldForDuration: 0)
            }
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "message-row:"
            )).firstMatch.waitForExistence(timeout: 15), "Fast flicks must leave a realized message row.")
            attachScreenshot(named: "synthetic-production-\(count)-after-fast-flick")

            let arrow = app.buttons[scrollToLatestLabel]
            XCTAssertTrue(arrow.waitForExistence(timeout: 15))
            arrow.tap()
            let marker = count == 120 ? "Representative conversation complete." : endMarker
            let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", marker)).firstMatch
            assertHittable(tail, timeout: 30, message: "\(count) rich-row arrow must expose its real tail.")
            attachScreenshot(named: "synthetic-production-\(count)-arrow-tail")
        }
    }

    func testDiagnosticColdNearTailOpenAndFarArrowUsesRealizedRows() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [performanceLabArgument, "--native-direct-mixed-rich-10k",
                               "--chat-viewport-follow-latest-open", "--chat-viewport-diagnostic",
                               "--composer-test-fresh-draft"]
        app.launch()

        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", endMarker
        )).firstMatch
        assertHittable(tail, timeout: 25, message: "Cold bottom restore must reveal the concrete 10k tail.")
        attachScreenshot(named: "cold-near-tail-open")

        app.terminate()

        let farApp = XCUIApplication()
        farApp.launchArguments = [performanceLabArgument, "--native-direct-mixed-rich-10k",
                                  "--chat-viewport-diagnostic", "--composer-test-fresh-draft"]
        farApp.launch()
        let farTranscript = farApp.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(farTranscript.waitForExistence(timeout: 20))
        let arrow = farApp.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 15))
        attachScreenshot(named: "saved-row-20-before-far-arrow")
        print("SEMREH_FAR_ARROW_TAP at=\(Date())")
        arrow.tap()
        let farTail = farApp.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", endMarker
        )).firstMatch
        assertHittable(farTail, timeout: 30, message: "Far arrow must reveal the concrete 10k tail.")
        attachScreenshot(named: "saved-row-20-after-far-arrow")
    }

    func testDebugBoundedTailWindowFarArrowRichTail() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [performanceLabArgument, "--native-direct-mixed-rich-10k",
                               "--chat-viewport-diagnostic", "--chat-debug-bounded-tail-window",
                               "--composer-test-fresh-draft"]
        app.launch()
        let scroll = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 20))
        let arrow = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        attachScreenshot(named: "bounded-saved-row-before-arrow")
        print("SEMREH_BOUNDED_FAR_ARROW_TAP at=\(Date())")
        arrow.tap()
        let farTail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", endMarker
        )).firstMatch
        assertHittable(farTail, timeout: 20, message: "Bounded far arrow must show real 10k tail.")
        XCTAssertTrue(app.buttons["Copy code"].firstMatch.exists,
                      "Bounded tail must retain rich code actions.")
        attachScreenshot(named: "bounded-far-arrow-tail")
    }

    // MARK: - Windowed-eager prototype (flag-gated experiment, 2026-09-24)

    private let rich30Marker = "SEMREH_RICH30_END"

    func testWindowedEagerFourTallColdTailSingleTapArrow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-four-tall-lab", "--chat-windowed-eager",
                               "--chat-viewport-follow-latest-open", "--chat-viewport-diagnostic",
                               "--composer-test-fresh-draft"]
        app.launch()
        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        print("SEMREH_WIN_EAGER_FOURTALL_LAUNCH at=\(Date())")
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "SEMREH_FOUR_TALL_CODE_END"
        )).firstMatch
        assertHittable(tail, timeout: 25, message: "Windowed-eager cold open must reveal the four-tall tail.")
        print("SEMREH_WIN_EAGER_FOURTALL_FIRST_READABLE at=\(Date())")
        attachScreenshot(named: "win-eager-four-tall-cold-tail")
        XCTAssertTrue(app.buttons["View full code (322 lines)"].firstMatch.exists
                      || app.buttons["Copy code"].firstMatch.exists,
                      "Rich code affordances must be retained in the windowed-eager transcript.")
        transcript.swipeDown()
        transcript.swipeDown()
        let arrow = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10),
                      "Arrow must appear after scrolling away from the four-tall tail.")
        attachScreenshot(named: "win-eager-four-tall-away")
        print("SEMREH_WIN_EAGER_FOURTALL_ARROW_TAP at=\(Date())")
        arrow.tap()
        assertHittable(tail, timeout: 15, message: "Single arrow tap must land on the four-tall tail.")
        print("SEMREH_WIN_EAGER_FOURTALL_ARROW_TAIL at=\(Date())")
        attachScreenshot(named: "win-eager-four-tall-arrow-tail")
    }

    func testWindowedEagerRich30ColdOpenScrollArrow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-rich30-lab", "--chat-windowed-eager",
                               "--chat-viewport-follow-latest-open", "--chat-viewport-diagnostic",
                               "--composer-test-fresh-draft"]
        app.launch()
        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        print("SEMREH_WIN_EAGER_RICH30_LAUNCH at=\(Date())")
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", rich30Marker
        )).firstMatch
        assertHittable(tail, timeout: 30, message: "Rich30 cold open must reveal the tail marker.")
        print("SEMREH_WIN_EAGER_RICH30_FIRST_READABLE at=\(Date())")
        attachScreenshot(named: "win-eager-rich30-cold-tail")
        transcript.swipeDown()
        transcript.swipeDown()
        let arrow = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10),
                      "Arrow must appear after scrolling away from the rich30 tail.")
        print("SEMREH_WIN_EAGER_RICH30_ARROW_TAP at=\(Date())")
        arrow.tap()
        assertHittable(tail, timeout: 15, message: "Rich30 arrow must land on the tail.")
        print("SEMREH_WIN_EAGER_RICH30_ARROW_TAIL at=\(Date())")
        attachScreenshot(named: "win-eager-rich30-arrow-tail")
    }

    func testWindowedEagerPagingContractSlidesAndReturns() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-rich30-lab", "--chat-windowed-eager",
                               "--chat-windowed-rows=40", "--chat-viewport-follow-latest-open",
                               "--chat-viewport-diagnostic", "--composer-test-fresh-draft"]
        app.launch()
        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", rich30Marker)).firstMatch
        assertHittable(tail, timeout: 30, message: "Paging: cold open must reveal the tail.")
        attachScreenshot(named: "win-eager-paging-tail")

        // The bounded window must expose its in-transcript Load earlier affordance.
        XCTAssertTrue(app.buttons["chat-debug-older-loaded"].waitForExistence(timeout: 8),
                      "The bounded window must expose its Load earlier affordance.")

        let firstRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Rich group")).firstMatch
        XCTAssertTrue(firstRow.exists, "Reader must start on readable rich content.")
        let beforeLabel = firstRow.label

        // Repeated paging: slide the bounded window older several times.
        let pageOlder = app.buttons["windowed-page-older"]
        XCTAssertTrue(pageOlder.waitForExistence(timeout: 8), "Debug paging seam must be available.")
        var slides = 0
        for _ in 0..<3 {
            print("SEMREH_WIN_EAGER_PAGE_OLDER_\(slides) at=\(Date())")
            pageOlder.tap()
            slides += 1
            Thread.sleep(forTimeInterval: 0.8)
        }
        XCTAssertEqual(slides, 3, "Repeated paging taps must all dispatch.")
        let slidRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Rich group")).firstMatch
        XCTAssertTrue(slidRow.exists, "Sliding must leave readable rich content (no blank region).")
        XCTAssertNotEqual(slidRow.label, beforeLabel,
                          "The bounded window must actually slide to older content.")
        attachScreenshot(named: "win-eager-paging-older-readable")

        // Return to latest from the old region: single arrow tap.
        let arrow = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10), "Arrow must be available from the older region.")
        print("SEMREH_WIN_EAGER_PAGE_ARROW_TAP at=\(Date())")
        arrow.tap()
        assertHittable(tail, timeout: 15, message: "Arrow must return from the old region to the concrete tail.")
        print("SEMREH_WIN_EAGER_PAGE_ARROW_TAIL at=\(Date())")
        attachScreenshot(named: "win-eager-paging-return-tail")
    }

    func testWindowedEagerStreamingDoesNotDisplaceReader() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-rich30-lab", "--chat-windowed-eager",
                               "--chat-windowed-rows=40", "--chat-viewport-follow-latest-open",
                               "--chat-viewport-diagnostic", "--composer-test-fresh-draft"]
        app.launch()
        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", rich30Marker)).firstMatch
        assertHittable(tail, timeout: 30, message: "Streaming: cold open must reveal the tail.")

        // Park the reader in an older region via the debug paging seam.
        let pageOlder = app.buttons["windowed-page-older"]
        XCTAssertTrue(pageOlder.waitForExistence(timeout: 8), "Debug paging seam must be available.")
        pageOlder.tap()
        Thread.sleep(forTimeInterval: 0.8)
        attachScreenshot(named: "win-eager-stream-reader-old-region")
        let readerRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Rich group")).firstMatch
        XCTAssertTrue(readerRow.exists, "Reader must be parked on readable rich content before streaming.")
        let before = String(readerRow.label.prefix(40))

        // Stream a turn while the reader is parked.
        let streamButton = app.buttons["rich30-stream-turn"]
        XCTAssertTrue(streamButton.waitForExistence(timeout: 8), "Stream trigger must be available.")
        print("SEMREH_WIN_EAGER_STREAM_START at=\(Date())")
        streamButton.tap()
        Thread.sleep(forTimeInterval: 2.5)
        let afterRow = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", before)).firstMatch
        XCTAssertTrue(afterRow.exists,
                      "Streaming must not displace a reader parked in an older region.")
        attachScreenshot(named: "win-eager-stream-reader-unchanged")

        // Return to latest: a single arrow tap must reveal the streamed turn.
        let arrow = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10), "Arrow must be available after streaming.")
        arrow.tap()
        let streamTail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "SEMREH_MULTI_CHAT_STREAM_1"
        )).firstMatch
        assertHittable(streamTail, timeout: 15, message: "Returning to latest must reveal the streamed turn.")
        attachScreenshot(named: "win-eager-stream-tail")
    }

    func testWindowedEagerTailStaysLiveWhileFollowing() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-rich30-lab", "--chat-windowed-eager",
                               "--chat-viewport-follow-latest-open", "--chat-viewport-diagnostic",
                               "--composer-test-fresh-draft"]
        app.launch()
        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", rich30Marker)).firstMatch
        assertHittable(tail, timeout: 30, message: "Tail-live: cold open must reveal the tail.")
        let streamButton = app.buttons["rich30-stream-turn"]
        XCTAssertTrue(streamButton.waitForExistence(timeout: 8), "Stream trigger must be available.")
        print("SEMREH_WIN_EAGER_TAILLIVE_STREAM at=\(Date())")
        streamButton.tap()
        let streamTail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "SEMREH_MULTI_CHAT_STREAM_1"
        )).firstMatch
        assertHittable(streamTail, timeout: 15,
                       message: "A following reader at the tail must see the streamed turn arrive without extra taps.")
        print("SEMREH_WIN_EAGER_TAILLIVE_VISIBLE at=\(Date())")
        attachScreenshot(named: "win-eager-taillive-stream")
    }

    func testWindowedEagerTenThousandPagingWalk() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [performanceLabArgument, "--native-direct-mixed-rich-10k",
                               "--chat-windowed-eager", "--chat-windowed-rows=40",
                               "--chat-viewport-follow-latest-open", "--chat-viewport-diagnostic",
                               "--composer-test-fresh-draft"]
        app.launch()
        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        print("SEMREH_WIN_EAGER_10K_LAUNCH at=\(Date())")
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", endMarker)).firstMatch
        assertHittable(tail, timeout: 40, message: "10k windowed cold open must reveal the end marker.")
        print("SEMREH_WIN_EAGER_10K_FIRST_READABLE at=\(Date())")
        attachScreenshot(named: "win-eager-10k-cold-tail")
        let pageOlder = app.buttons["windowed-page-older"]
        XCTAssertTrue(pageOlder.waitForExistence(timeout: 8), "Debug paging seam must be available.")
        var slides = 0
        for _ in 0..<5 {
            print("SEMREH_WIN_EAGER_10K_PAGE_\(slides) at=\(Date())")
            pageOlder.tap()
            slides += 1
            Thread.sleep(forTimeInterval: 0.8)
        }
        XCTAssertEqual(slides, 5, "Repeated paging must dispatch on the 10k transcript.")
        let anyRow = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "quick brown fox"
        )).firstMatch
        XCTAssertTrue(anyRow.exists, "Paging on 10k must leave readable rows (no blank region).")
        attachScreenshot(named: "win-eager-10k-paging")
        let arrow = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10), "Arrow must be available from the 10k old region.")
        print("SEMREH_WIN_EAGER_10K_ARROW_TAP at=\(Date())")
        arrow.tap()
        assertHittable(tail, timeout: 20, message: "Arrow must return to the concrete 10k tail.")
        print("SEMREH_WIN_EAGER_10K_ARROW_TAIL at=\(Date())")
        attachScreenshot(named: "win-eager-10k-return-tail")
    }

    func testWindowedEagerRich30SmallWindowColdOpen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-rich30-lab", "--chat-windowed-eager",
                               "--chat-windowed-rows=24", "--chat-viewport-follow-latest-open",
                               "--chat-viewport-diagnostic", "--composer-test-fresh-draft"]
        app.launch()
        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        print("SEMREH_WIN_EAGER_SMALL_LAUNCH at=\(Date())")
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", rich30Marker
        )).firstMatch
        assertHittable(tail, timeout: 30, message: "Small-window rich30 cold open must reveal the tail marker.")
        print("SEMREH_WIN_EAGER_SMALL_FIRST_READABLE at=\(Date())")
        attachScreenshot(named: "win-eager-small-cold-tail")
    }

    func testWindowedEagerBackSmallWindowResponsiveness() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-rich30-lab", "--chat-windowed-eager",
                               "--chat-windowed-rows=24", "--chat-performance-rich30-back-lab",
                               "--chat-viewport-follow-latest-open", "--composer-test-fresh-draft"]
        app.launch()
        let open = app.buttons["Open rich30 chat"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20), "Back lab must expose the chat entry row.")
        let transcript = app.scrollViews["chat-transcript-scroll"]
        let back = app.buttons["Back"]
        for attempt in 1...3 {
            open.tap()
            _ = transcript.waitForExistence(timeout: 10)
            print("SEMREH_WIN_EAGER_BACKSMALL_TAP_\(attempt) at=\(Date())")
            if back.waitForExistence(timeout: 6) {
                back.tap()
            }
            XCTAssertTrue(open.waitForExistence(timeout: 12),
                          "Small-window Back must return to the list (attempt \(attempt)).")
            print("SEMREH_WIN_EAGER_BACKSMALL_RETURNED_\(attempt) at=\(Date())")
        }
    }

    // MARK: - Flag-off baselines (same build, windowed-eager disabled)

    func testBaselineFourTallFlagOffColdTailSingleTapArrow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-four-tall-lab",
                               "--chat-viewport-follow-latest-open", "--chat-viewport-diagnostic",
                               "--composer-test-fresh-draft"]
        app.launch()
        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        print("SEMREH_BASE_FOURTALL_LAUNCH at=\(Date())")
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "SEMREH_FOUR_TALL_CODE_END"
        )).firstMatch
        assertHittable(tail, timeout: 25, message: "Baseline cold open must reveal the four-tall tail.")
        print("SEMREH_BASE_FOURTALL_FIRST_READABLE at=\(Date())")
        attachScreenshot(named: "base-four-tall-cold-tail")
        transcript.swipeDown()
        transcript.swipeDown()
        let arrow = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10),
                      "Baseline arrow must appear after scrolling away.")
        print("SEMREH_BASE_FOURTALL_ARROW_TAP at=\(Date())")
        arrow.tap()
        assertHittable(tail, timeout: 15, message: "Baseline single arrow tap must land on the tail.")
        print("SEMREH_BASE_FOURTALL_ARROW_TAIL at=\(Date())")
        attachScreenshot(named: "base-four-tall-arrow-tail")
    }

    func testBaselineRich30FlagOffColdOpenScrollArrow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-rich30-lab",
                               "--chat-viewport-follow-latest-open", "--chat-viewport-diagnostic",
                               "--composer-test-fresh-draft"]
        app.launch()
        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        print("SEMREH_BASE_RICH30_LAUNCH at=\(Date())")
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", rich30Marker
        )).firstMatch
        assertHittable(tail, timeout: 30, message: "Baseline rich30 cold open must reveal the tail marker.")
        print("SEMREH_BASE_RICH30_FIRST_READABLE at=\(Date())")
        attachScreenshot(named: "base-rich30-cold-tail")
        transcript.swipeDown()
        transcript.swipeDown()
        let arrow = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10),
                      "Baseline rich30 arrow must appear after scrolling away.")
        print("SEMREH_BASE_RICH30_ARROW_TAP at=\(Date())")
        arrow.tap()
        assertHittable(tail, timeout: 15, message: "Baseline rich30 arrow must land on the tail.")
        print("SEMREH_BASE_RICH30_ARROW_TAIL at=\(Date())")
        attachScreenshot(named: "base-rich30-arrow-tail")
    }

    func testBaselineBackFlagOffResponsiveness() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-rich30-back-lab",
                               "--chat-viewport-follow-latest-open", "--chat-viewport-diagnostic",
                               "--composer-test-fresh-draft"]
        app.launch()
        let open = app.buttons["Open rich30 chat"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20), "Baseline back lab must expose the chat entry row.")
        for attempt in 1...3 {
            open.tap()
            let transcript = app.scrollViews["chat-transcript-scroll"]
            XCTAssertTrue(transcript.waitForExistence(timeout: 15))
            print("SEMREH_BASE_BACK_TAP_PREP_\(attempt) at=\(Date())")
            let back = app.buttons["Back"]
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            back.tap()
            XCTAssertTrue(open.waitForExistence(timeout: 10),
                          "Baseline back during preparation must return to the chat list (attempt \(attempt)).")
            print("SEMREH_BASE_BACK_RETURNED_PREP_\(attempt) at=\(Date())")
            attachScreenshot(named: "base-back-prep-\(attempt)")
        }
    }

    func testWindowedEagerBackResponsivenessPrepAndStreaming() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-rich30-back-lab", "--chat-windowed-eager",
                               "--chat-viewport-follow-latest-open", "--chat-viewport-diagnostic",
                               "--composer-test-fresh-draft"]
        app.launch()
        let open = app.buttons["Open rich30 chat"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20), "Back lab must expose the chat entry row.")

        for attempt in 1...3 {
            open.tap()
            let transcript = app.scrollViews["chat-transcript-scroll"]
            XCTAssertTrue(transcript.waitForExistence(timeout: 15))
            print("SEMREH_WIN_EAGER_BACK_TAP_PREP_\(attempt) at=\(Date())")
            let back = app.buttons["Back"]
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            back.tap()
            XCTAssertTrue(open.waitForExistence(timeout: 10),
                          "Back during preparation must return to the chat list (attempt \(attempt)).")
            print("SEMREH_WIN_EAGER_BACK_RETURNED_PREP_\(attempt) at=\(Date())")
            attachScreenshot(named: "win-eager-back-prep-\(attempt)")
        }

        open.tap()
        let transcript = app.scrollViews["chat-transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        let streamButton = app.buttons["rich30-stream-turn"]
        XCTAssertTrue(streamButton.waitForExistence(timeout: 10), "Stream trigger must be available.")
        streamButton.tap()
        print("SEMREH_WIN_EAGER_BACK_TAP_STREAM at=\(Date())")
        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 10),
                      "Back during streaming must return to the chat list.")
        print("SEMREH_WIN_EAGER_BACK_RETURNED_STREAM at=\(Date())")
        attachScreenshot(named: "win-eager-back-stream")
    }

    func testRepeatedMultiChatSwitchingRetainsEachOwnerAndMarker() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-multi-lab"]
        app.launch()

        let firstChat = app.otherElements["chat-detail:10,000-row performance lab 1"]
        XCTAssertTrue(firstChat.waitForExistence(timeout: 20))

        let initialArrow = app.buttons[scrollToLatestLabel]
        guard initialArrow.waitForExistence(timeout: 10) else {
            attachScreenshot(named: "repeated-switch-initial-arrow-missing")
            attachAccessibilitySnapshot(
                named: "repeated-switch-initial-arrow-missing-ax",
                app: app
            )
            XCTFail("Chat 1 must initially restore away from the bottom before switching.")
            return
        }

        let switchButtons = (1...3).map { app.buttons["Performance chat \($0)"] }
        for button in switchButtons {
            XCTAssertTrue(button.waitForExistence(timeout: 5),
                          "Every performance chat switch must be exposed.")
            XCTAssertTrue(button.isHittable,
                          "Every performance chat switch must be hittable before the rapid sequence.")
        }

        // Deliberately issue a bounded burst without waiting for each ChatView
        // to settle. XCTest still synchronizes individual actions, so this
        // does not claim frame-level or exact deceleration timing; it catches
        // owner loss, stale selection, and fixture replacement under repeated
        // user-level switching.
        for chatNumber in [2, 3, 1, 3, 2, 1] {
            switchButtons[chatNumber - 1].tap()
        }

        // Verify each owner after the burst. Returning to the bottom makes the
        // check a stable-content assertion rather than an assertion about a
        // transient accessibility snapshot during navigation.
        for chatNumber in 1...3 {
            let switchButton = switchButtons[chatNumber - 1]
            switchButton.tap()
            XCTAssertTrue(switchButton.isSelected,
                          "Rapid switching must leave chat \(chatNumber) selected when revisited.")

            let chat = app.otherElements["chat-detail:10,000-row performance lab \(chatNumber)"]
            XCTAssertTrue(chat.waitForExistence(timeout: 15),
                          "Chat \(chatNumber) must remain the selected owner after rapid switching.")

            let scrollToLatest = app.buttons[scrollToLatestLabel]
            guard scrollToLatest.waitForExistence(timeout: 10) else {
                // A missing affordance is the signal under test here: capture
                // the selected owner, realized rows, and visible chrome before
                // failing so a restore-to-bottom race is distinguishable from
                // a stale ChatView or an accessibility lookup failure.
                let endMarker = app.staticTexts.matching(
                    NSPredicate(
                        format: "label CONTAINS[c] %@",
                        "End of 10,000-row conversation \(chatNumber)."
                    )
                ).firstMatch
                let endMarkerIsVisible = endMarker.exists && endMarker.isHittable
                attachScreenshot(
                    named: "repeated-switch-chat-\(chatNumber)-arrow-missing"
                )
                attachAccessibilitySnapshot(
                    named: "repeated-switch-chat-\(chatNumber)-arrow-missing-ax",
                    app: app
                )
                XCTFail("Chat \(chatNumber) must retain its restored away-from-bottom state (endMarkerHittable=\(endMarkerIsVisible)).")
                return
            }
            scrollToLatest.tap()

            let endMarker = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "End of 10,000-row conversation \(chatNumber).")
            ).firstMatch
            assertHittable(
                endMarker,
                timeout: 25,
                message: "Chat \(chatNumber) must retain its deterministic end marker after rapid switching."
            )
        }
    }

    func testOptInTwentyLongChatEnterBackSwitchCycles() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SEMREH_CHAT_PERFORMANCE_CYCLES"] == "1" else {
            throw XCTSkip("The 20-cycle long-chat performance trace is opt-in.")
        }

        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [performanceCycleLabArgument, performanceSignpostsArgument]
        app.launch()

        let cycleLab = app.descendants(matching: .any)["performance-cycle-lab"]
        XCTAssertTrue(
            cycleLab.waitForExistence(timeout: 15),
            "The opt-in server-free long-chat cycle lab must launch."
        )

        let cycleCount = 20
        var measurements = [
            "# fixture=2 chats x 10,000 rows; pattern=alternating enter/back visits",
            "# enter_ms is tap-to-chat-root-hittable; return_ms is Back-to-list-button-hittable",
            "# These are XCTest wall-clock timings including accessibility waits; use Instruments for hitches/FPS.",
            "# signposts=subsystem=com.maurice.semreh category=ChatPerformance names=ChatPerformancePhase,ChatPerformanceTransition",
            "cycle,chat,enter_ms,return_ms,total_ms"
        ]

        for cycle in 1...cycleCount {
            // Alternating owners ensures every visit opens a different long
            // chat than the preceding visit, matching the reported repro while
            // keeping both retained fixtures deterministic.
            let chatNumber = cycle.isMultiple(of: 2) ? 2 : 1
            let entry = app.buttons["performance-cycle-chat-\(chatNumber)"]
            assertHittable(
                entry,
                timeout: 15,
                message: "Cycle \(cycle) must expose long chat \(chatNumber) in the lab list."
            )

            let cycleStarted = Date()
            let enterStarted = Date()
            entry.tap()

            let chat = app.otherElements["chat-detail:10,000-row performance lab \(chatNumber)"]
            assertHittable(
                chat,
                timeout: 25,
                message: "Cycle \(cycle) must enter long chat \(chatNumber)."
            )
            let enterMilliseconds = Date().timeIntervalSince(enterStarted) * 1_000

            let back = app.buttons["Back"]
            assertHittable(
                back,
                timeout: 10,
                message: "Cycle \(cycle) must expose the custom chat Back button."
            )
            let returnStarted = Date()
            back.tap()
            assertHittable(
                entry,
                timeout: 20,
                message: "Cycle \(cycle) must return to the performance lab list."
            )
            let returnMilliseconds = Date().timeIntervalSince(returnStarted) * 1_000
            let totalMilliseconds = Date().timeIntervalSince(cycleStarted) * 1_000

            measurements.append(String(format: "%d,%d,%.1f,%.1f,%.1f", cycle, chatNumber,
                                       enterMilliseconds, returnMilliseconds, totalMilliseconds))
        }

        attachPlainText(
            measurements.joined(separator: "\n"),
            named: "long-chat-enter-back-20-cycle-timings"
        )
    }

    @MainActor
    func testOptInCycleLabFrameCallbackProbeReadback() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("The DEBUG cycle-lab callback probe is Simulator-only.")
        #endif
        guard ProcessInfo.processInfo.environment[performanceFrameCallbackProbeEnvironment] == "1" else {
            throw XCTSkip("The cycle-lab callback timing probe is opt-in.")
        }

        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            performanceCycleLabArgument,
            performanceSignpostsArgument,
            performanceFrameCallbackProbeArgument
        ]
        app.launch()

        let cycleLab = app.descendants(matching: .any)["performance-cycle-lab"]
        XCTAssertTrue(cycleLab.waitForExistence(timeout: 15))
        let start = app.buttons["frame-callback-probe-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10) && start.isHittable)

        let scope = XCTAttachment(string: [
            "fixture=DEBUG cycle lab; 2 synthetic conversations x 10,000 rows",
            "instrument=opt-in CADisplayLink callback timing on the app main run loop",
            "reported=callback count, estimated target-interval gaps, max and histogram p95/p99",
            "not_measured=presented pixels, GPU frame lifetime, physical FPS, or hitch pass/fail",
            "lifecycle=sample pauses and drops timing baseline while scene is inactive",
            "no_per_frame_state_or_logging=true"
        ].joined(separator: "\n"))
        scope.name = "Frame callback probe claim boundary"
        scope.lifetime = .keepAlways
        add(scope)

        start.tap()

        for chatNumber in 1...2 {
            let entry = app.buttons["performance-cycle-chat-\(chatNumber)"]
            assertHittable(
                entry,
                timeout: 15,
                message: "The callback sample must expose long chat \(chatNumber) in the lab list."
            )
            entry.tap()

            let chat = app.otherElements["chat-detail:10,000-row performance lab \(chatNumber)"]
            assertHittable(chat, timeout: 25, message: "The callback sample must enter chat \(chatNumber).")
            let transcript = app.scrollViews.firstMatch
            XCTAssertTrue(transcript.waitForExistence(timeout: 10) && transcript.isHittable)
            transcript.swipeDown()

            let scrollToLatest = app.buttons[scrollToLatestLabel]
            XCTAssertTrue(
                scrollToLatest.waitForExistence(timeout: 10) && scrollToLatest.isHittable,
                "A real swipe must expose Scroll to latest for chat \(chatNumber)."
            )
            scrollToLatest.tap()

            let endMarker = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "End of 10,000-row conversation \(chatNumber).")
            ).firstMatch
            assertHittable(endMarker, timeout: 25, message: "Arrow return must reveal chat \(chatNumber)'s tail.")

            let back = app.buttons["Back"]
            XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable)
            back.tap()
            assertHittable(
                entry,
                timeout: 20,
                message: "The callback sample must return to the lab after chat \(chatNumber)."
            )
        }

        let stop = app.buttons["frame-callback-probe-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10) && stop.isHittable)
        stop.tap()

        let summary = app.staticTexts["chat-performance-frame-callback-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let report = summary.label
        XCTAssertTrue(report.contains("CADisplayLink main-run-loop callback timing only"))
        XCTAssertTrue(report.contains("estimated_missed_target_intervals="))
        XCTAssertTrue(report.contains("maximum_callback_gap_ms="))
        XCTAssertTrue(report.contains("p95_callback_gap_ms_upper_bin="))
        XCTAssertTrue(report.contains("p99_callback_gap_ms_upper_bin="))
        XCTAssertTrue(report.contains("histogram_storage_bins="))
        guard let callbackCountLine = report
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("callbacks=") })
        else {
            XCTFail("The callback report must include its aggregate callback count.")
            return
        }
        let callbackCountText = String(callbackCountLine.dropFirst("callbacks=".count))
        guard let callbackCount = Int(callbackCountText) else {
            XCTFail("The callback count must be a readable integer.")
            return
        }
        XCTAssertGreaterThan(callbackCount, 0, "The probe must sample callbacks, without a performance threshold.")
        attachPlainText(report, named: "long-chat-frame-callback-timing-summary")
    }

    @MainActor
    func testOptInAppWideCadenceMonitorReadback() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("The DEBUG app-wide cadence monitor is Simulator-only.")
        #endif
        guard ProcessInfo.processInfo.environment[appWidePerformanceMonitorEnvironment] == "1" else {
            throw XCTSkip("The app-wide cadence monitor readback is opt-in.")
        }

        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            performanceCycleLabArgument,
            performanceSignpostsArgument,
            appWidePerformanceMonitorArgument
        ]
        app.launch()

        let cycleLab = app.descendants(matching: .any)["performance-cycle-lab"]
        XCTAssertTrue(
            cycleLab.waitForExistence(timeout: 15),
            "The app-wide monitor must use the retained server-free cycle lab."
        )
        let stop = app.buttons["chat-performance-app-wide-monitor-stop"]
        XCTAssertTrue(
            stop.waitForExistence(timeout: 10) && stop.isHittable,
            "The explicit opt-in monitor must expose its bounded stop/readout control."
        )

        for chatNumber in 1...2 {
            let entry = app.buttons["performance-cycle-chat-\(chatNumber)"]
            assertHittable(
                entry,
                timeout: 15,
                message: "The app-wide cadence sample must expose long chat \(chatNumber)."
            )
            entry.tap()

            let chat = app.otherElements["chat-detail:10,000-row performance lab \(chatNumber)"]
            assertHittable(chat, timeout: 25, message: "The app-wide sample must enter chat \(chatNumber).")
            let back = app.buttons["Back"]
            XCTAssertTrue(
                back.waitForExistence(timeout: 10) && back.isHittable,
                "The app-wide sample must expose Back for chat \(chatNumber)."
            )
            back.tap()
            assertHittable(
                entry,
                timeout: 20,
                message: "The app-wide sample must return to the lab after chat \(chatNumber)."
            )
        }

        // Scene sleep is a lifecycle boundary for the accumulator. This
        // exercises pause/rebase accounting without turning background time
        // into a fabricated callback gap; it is not a rendered-frame claim.
        XCUIDevice.shared.press(.home)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        app.activate()
        XCTAssertTrue(cycleLab.waitForExistence(timeout: 10))
        XCTAssertTrue(stop.waitForExistence(timeout: 10) && stop.isHittable)

        stop.tap()
        let summary = app.staticTexts["chat-performance-app-wide-monitor-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let report = summary.label
        XCTAssertTrue(report.contains("CADisplayLink main-run-loop callback timing only"))
        XCTAssertTrue(report.contains("sample_duration_seconds="))
        XCTAssertTrue(report.contains("phase_marker_scope="))
        XCTAssertTrue(report.contains("p95_callback_gap_ms_upper_bin="))
        XCTAssertTrue(report.contains("p99_callback_gap_ms_upper_bin="))
        XCTAssertTrue(report.contains("interaction_duration_max_ms="))
        XCTAssertTrue(report.contains("phase_callback_timing_coverage="))
        XCTAssertTrue(report.contains("phase=entry phase_events=2"))
        XCTAssertTrue(report.contains("phase=back phase_events=2"))
        XCTAssertTrue(report.contains("phase=send"))
        XCTAssertTrue(report.contains("phase=scene_pause"))

        guard let callbackCountLine = report
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("callbacks=") })
        else {
            XCTFail("The app-wide report must include its aggregate callback count.")
            return
        }
        let callbackCountText = String(callbackCountLine.dropFirst("callbacks=".count))
        guard let callbackCount = Int(callbackCountText) else {
            XCTFail("The app-wide callback count must be a readable integer.")
            return
        }
        XCTAssertGreaterThan(callbackCount, 0, "The monitor must observe callbacks, without a smoothness threshold.")
        attachPlainText(report, named: "app-wide-cadence-timing-summary")
    }

    @MainActor
    func testOptInLongChatXCTestMetricCapabilityProbe() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("The metric capability probe is Simulator-only.")
        #endif
        guard ProcessInfo.processInfo.environment[performanceMetricProbeEnvironment] == "1" else {
            throw XCTSkip("The long-chat XCTest metric capability probe is opt-in.")
        }
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("XCTHitchMetric requires iOS 26.0 or later.")
        }

        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [performanceCycleLabArgument, performanceSignpostsArgument]
        app.launch()

        let cycleLab = app.descendants(matching: .any)["performance-cycle-lab"]
        XCTAssertTrue(
            cycleLab.waitForExistence(timeout: 15),
            "The metric probe must use the existing server-free two-chat cycle lab."
        )

        let options = XCTMeasureOptions()
        // XCTest runs one unrecorded warm-up and one measured iteration.
        // Each iteration visits both retained owners and includes a real swipe,
        // arrow return, and Back navigation.
        options.iterationCount = 1

        let metricNotes = XCTAttachment(string: [
            "fixture=DEBUG cycle lab; 2 synthetic conversations x 10,000 rows",
            "measured_iterations=1; XCTest discards one warm-up iteration",
            "requested=XCTHitchMetric(application), XCTCPUMetric(application), XCTMemoryMetric(application), navigationTransitionMetric, scrollingAndDecelerationMetric",
            "scope=presentation-only; app CPU is process aggregate, not main-thread CPU",
            "Simulator metric output only; do not interpret as physical FPS or device acceptance",
            "The numeric measurements must appear in the .xcresult performance results; missing values are not a pass"
        ].joined(separator: "\n"))
        metricNotes.name = "Long-chat XCTest metric probe scope"
        metricNotes.lifetime = .keepAlways
        add(metricNotes)

        measure(
            metrics: [
                XCTHitchMetric(application: app),
                XCTCPUMetric(application: app),
                XCTMemoryMetric(application: app),
                XCTOSSignpostMetric.navigationTransitionMetric,
                XCTOSSignpostMetric.scrollingAndDecelerationMetric
            ],
            options: options
        ) {
            for chatNumber in 1...2 {
                let entry = app.buttons["performance-cycle-chat-\(chatNumber)"]
                XCTAssertTrue(
                    entry.waitForExistence(timeout: 15) && entry.isHittable,
                    "The measured iteration must revisit chat \(chatNumber)'s seeded owner."
                )
                entry.tap()

                let chat = app.otherElements[
                    "chat-detail:10,000-row performance lab \(chatNumber)"
                ]
                assertHittable(
                    chat,
                    timeout: 25,
                    message: "The measured iteration must enter long chat \(chatNumber)."
                )

                let transcript = app.scrollViews.firstMatch
                XCTAssertTrue(transcript.waitForExistence(timeout: 5) && transcript.isHittable)
                transcript.swipeDown()

                let scrollToLatest = app.buttons[scrollToLatestLabel]
                XCTAssertTrue(
                    scrollToLatest.waitForExistence(timeout: 10) && scrollToLatest.isHittable,
                    "A real swipe away must expose Scroll to latest for chat \(chatNumber)."
                )
                scrollToLatest.tap()

                let endMarker = app.staticTexts.matching(
                    NSPredicate(
                        format: "label CONTAINS[c] %@",
                        "End of 10,000-row conversation \(chatNumber)."
                    )
                ).firstMatch
                assertHittable(
                    endMarker,
                    timeout: 25,
                    message: "Arrow return must reveal chat \(chatNumber)'s deterministic end marker."
                )
                XCTAssertFalse(
                    scrollToLatest.waitForExistence(timeout: 2),
                    "Scroll to latest must clear after the measured return."
                )

                let back = app.buttons["Back"]
                XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable)
                back.tap()
                assertHittable(
                    entry,
                    timeout: 20,
                    message: "The measured iteration must return to the cycle lab list."
                )
            }
        }
    }

    func testMultiChatPerformanceLabSwitchesStreamsAndScrolls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--chat-performance-multi-lab"]
        app.launch()

        let firstChat = app.otherElements["chat-detail:10,000-row performance lab 1"]
        XCTAssertTrue(firstChat.waitForExistence(timeout: 20))

        // Every fixture starts restored in the middle of a 10,000-row transcript.
        // Reach its existing tail before appending, then prove that the latest
        // streamed row survives a real away-from-bottom scroll and arrow return.
        exerciseMultiChat(app: app, chatNumber: 1, screenshotPrefix: "multi-chat-1")

        let switchToSecond = Date()
        app.buttons["Performance chat 2"].tap()
        let secondChat = app.otherElements["chat-detail:10,000-row performance lab 2"]
        XCTAssertTrue(secondChat.waitForExistence(timeout: 15))
        addTiming(named: "multi-chat-switch-to-chat-2", startedAt: switchToSecond)
        exerciseMultiChat(app: app, chatNumber: 2, screenshotPrefix: "multi-chat-2")

        let switchToThird = Date()
        app.buttons["Performance chat 3"].tap()
        let thirdChat = app.otherElements["chat-detail:10,000-row performance lab 3"]
        XCTAssertTrue(thirdChat.waitForExistence(timeout: 15))
        addTiming(named: "multi-chat-switch-to-chat-3", startedAt: switchToThird)
        exerciseMultiChat(app: app, chatNumber: 3, screenshotPrefix: "multi-chat-3")

        // Revisit all owners after streaming; switching must not recreate a
        // fixture or lose its appended latest marker.
        for chatNumber in 1...3 {
            app.buttons["Performance chat \(chatNumber)"].tap()
            let chat = app.otherElements["chat-detail:10,000-row performance lab \(chatNumber)"]
            XCTAssertTrue(chat.waitForExistence(timeout: 15))
            let marker = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "SEMREH_MULTI_CHAT_STREAM_1")
            ).firstMatch
            XCTAssertTrue(marker.waitForExistence(timeout: 10),
                          "Chat \(chatNumber) must retain its streamed latest marker after switching.")
        }
    }

    private func exerciseMultiChat(app: XCUIApplication, chatNumber: Int, screenshotPrefix: String) {
        let transcript = app.scrollViews.firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "Chat \(chatNumber) must expose its transcript scroll view.")
        let scrollToLatest = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(scrollToLatest.waitForExistence(timeout: 10),
                      "Chat \(chatNumber) must restore with scroll-to-latest available.")

        let baseMarker = "End of 10,000-row conversation \(chatNumber)."
        let reachInitialBottom = Date()
        scrollToLatest.tap()
        let initialEnd = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", baseMarker)
        ).firstMatch
        assertHittable(initialEnd, timeout: 25,
                       message: "Chat \(chatNumber) must expose its original deterministic tail after arrow return.")
        XCTAssertFalse(scrollToLatest.waitForExistence(timeout: 2),
                       "Chat \(chatNumber) must clear the arrow at the original bottom.")
        addTiming(named: "\(screenshotPrefix)-reach-original-bottom", startedAt: reachInitialBottom)
        attachScreenshot(named: "\(screenshotPrefix)-original-bottom")

        let streamStart = Date()
        app.buttons["Stream test turn"].tap()
        let latestMarker = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "SEMREH_MULTI_CHAT_STREAM_1")
        ).firstMatch
        assertHittable(latestMarker, timeout: 15,
                       message: "Chat \(chatNumber) must expose its paced appended stream marker at the bottom.")
        addTiming(named: "\(screenshotPrefix)-stream-append", startedAt: streamStart)
        attachScreenshot(named: "\(screenshotPrefix)-streamed-bottom")

        let scrollAwayStart = Date()
        transcript.swipeDown()
        XCTAssertTrue(scrollToLatest.waitForExistence(timeout: 10),
                      "Chat \(chatNumber) must show the arrow after scrolling away from its latest row.")
        scrollToLatest.tap()
        assertHittable(latestMarker, timeout: 25,
                       message: "Chat \(chatNumber) arrow return must reveal the newly appended latest marker.")
        XCTAssertFalse(scrollToLatest.waitForExistence(timeout: 2),
                       "Chat \(chatNumber) must clear the arrow after returning to the new bottom.")
        addTiming(named: "\(screenshotPrefix)-scroll-and-bottom-arrow", startedAt: scrollAwayStart)
        attachScreenshot(named: "\(screenshotPrefix)-new-bottom-after-arrow")
    }

    private func assertHittable(_ element: XCUIElement, timeout: TimeInterval, message: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        wait(for: [expectation], timeout: timeout)
        XCTAssertTrue(element.exists && element.isHittable, message)
    }

    @MainActor
    func testOptInLiveProductionLoginNewChatSend() async throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Live production UI smoke is simulator-only.")
        #endif

        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE2_UI_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] != nil
        else {
            throw XCTSkip("Live production UI smoke is opt-in.")
        }

        let stockBackend = environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "stock"
            && environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == stockBackendSHA
            && environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == stockCredentialsPath
            && environment["SEMREH_SLICE2_TOOL_CWD"] == stockToolCwd
        let developmentBackend = environment["SEMREH_SLICE2_UI_BACKEND_MODE"] == "development"
            && environment["SEMREH_SLICE2_UI_BACKEND_SHA"] == developmentBackendSHA
            && environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == developmentCredentialsPath
            && environment["SEMREH_SLICE2_TOOL_CWD"] == developmentToolCwd
        guard stockBackend || developmentBackend else {
            XCTFail("Slice 2 UI backend mode is invalid.")
            return
        }
        guard stockBackend != developmentBackend else {
            XCTFail("Slice 2 UI backend mode is ambiguous.")
            return
        }
        let credentialsPath = stockBackend ? stockCredentialsPath : developmentCredentialsPath

        let credentials = try readCredentials(at: credentialsPath)
        let app = XCUIApplication()
        app.terminate()
        let verifiesMuseSurface = environment["SEMREH_LIVE_MUSE_SURFACE"] == "1"
        app.launchArguments = verifiesMuseSurface ? ["--chat-native-transcript-v2"] : []
        app.launch()
        defer { clearPasteboard() }

        prepareNormalSignIn(app: app)
        let welcome = app.buttons["Get Started"]
        if !app.textFields["onboarding-server-url"].exists {
            XCTAssertTrue(welcome.waitForExistence(timeout: 15), "Normal sign-out must return to Welcome.")
            XCTAssertTrue(welcome.isHittable)
            welcome.tap()
        }

        let serverURL = app.textFields["onboarding-server-url"]
        XCTAssertTrue(serverURL.waitForExistence(timeout: 5))
        replacePublicText(serverURL, with: approvedLiveOrigin, app: app)
        app.buttons["Test Connection"].tap()

        let username = app.textFields["onboarding-username"]
        let password = app.secureTextFields["onboarding-password"]
        XCTAssertTrue(username.waitForExistence(timeout: 30), "The approved HTTPS origin must advertise username auth.")
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        attachScreenshot(named: "live-production-onboarding-password-form")
        replacePublicText(username, with: credentials.username, app: app)
        pasteSecret(credentials.password, into: password, app: app)
        app.buttons["Connect"].tap()
        dismissKnownPasswordSavePrompt(app: app)
        let personalize = app.navigationBars["Personalize"]
        if personalize.waitForExistence(timeout: 5) {
            dismissKnownPasswordSavePrompt(app: app)
            let skip = personalize.buttons["Skip"]
            XCTAssertTrue(skip.waitForExistence(timeout: 5) && skip.isHittable)
            skip.tap()
            XCTAssertFalse(personalize.waitForExistence(timeout: 1))
        }

        // The shell remembers the selected tab across normal sign-out/login.
        // Successful authentication need not land on Sessions automatically.
        if environment["SEMREH_SLICE3_UNCERTAINTY_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 uncertainty UI requires the pinned stock backend.")
                return
            }
            guard let storedID = environment["SEMREH_SLICE2_TUI_CREATED_SESSION_ID"],
                  storedID.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil,
                  let seedMarker = environment["SEMREH_SLICE3_RELAUNCH_SEED_TEXT"],
                  seedMarker.range(of: "^SEMREH_SLICE3_PRE_ACK_SEED_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$", options: .regularExpression) != nil
            else {
                XCTFail("Slice 3 uncertainty UI requires the exact pre-ACK seed session and marker.")
                return
            }
            try await waitForPromptUncertaintyEntryReadiness(app: app, seedMarker: seedMarker)
            try await exerciseOptInPromptUncertainty(
                app: app,
                storedID: storedID,
                seedMarker: seedMarker,
                credentials: credentials
            )
            return
        }

        // A persisted deep link can legitimately restore an authenticated chat
        // detail instead of the shell root. Return through that known chat's
        // navigation control before asserting the shell tabs.
        // AppShellView exposes the production conversation destination as Chats.
        let sessionsButtonLabel = "Chats"
        waitForPostLoginDestination(app: app, sessionsButtonLabel: sessionsButtonLabel)

        if environment["SEMREH_SLICE4_KANBAN_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 4 Kanban UI requires the pinned stock backend.")
                return
            }
            let control = app.buttons["Control"]
            assertHittable(control, timeout: 15,
                          message: "The authenticated production shell must expose Control.")
            control.tap()
            let kanban = app.buttons["Kanban"]
            assertHittable(kanban, timeout: 15,
                          message: "The production Control menu must expose the retained Kanban plugin.")
            kanban.tap()

            XCTAssertTrue(app.navigationBars["Kanban"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.scrollViews["KanbanStatusSelector"].waitForExistence(timeout: 30),
                          "The authenticated stock Board must reach compatible read-only content.")
            XCTAssertTrue(app.buttons["Switch Board"].exists,
                          "A live stock Board response must populate the Board selector.")
            XCTAssertFalse(app.staticTexts["The Kanban server is unavailable."].exists)
            XCTAssertFalse(app.staticTexts["This server's Kanban response is incompatible with Semreh."].exists)
            XCTAssertFalse(app.staticTexts["Loading Kanban"].exists)
            attachScreenshot(named: "slice4-kanban-stock-board-read-only")

            let backToControl = app.navigationBars["Kanban"].buttons["Back"]
            assertHittable(backToControl, timeout: 10,
                          message: "Kanban must preserve production back-navigation to Control.")
            backToControl.tap()
            let reopenedControl = app.buttons["Control"]
            assertHittable(reopenedControl, timeout: 10,
                          message: "Back-navigation must restore the production Control entrypoint.")
            reopenedControl.tap()
            let insights = app.buttons["Insights"]
            assertHittable(insights, timeout: 15,
                          message: "The production Control menu must expose retained Insights.")
            insights.tap()
            XCTAssertTrue(app.navigationBars["Usage Analytics"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts["Total Tokens"].waitForExistence(timeout: 30),
                          "The authenticated stock analytics response must render its summary cards.")
            XCTAssertTrue(app.staticTexts["Sessions"].exists)
            XCTAssertFalse(app.staticTexts["Could Not Load Analytics"].exists)
            XCTAssertFalse(app.staticTexts["Loading analytics..."].exists)
            attachScreenshot(named: "slice4-insights-stock-read-only")
            // Read-only production navigation check: do not select Cards, run
            // Dispatcher, create a Card, switch Boards, refresh, or mutate data.
            return
        }

        if let storedID = environment["SEMREH_SLICE4_GIT_UI_SESSION_ID"] {
            guard stockBackend,
                  storedID.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil else {
                XCTFail("Git UI verification requires the owned stock fixture and plain seeded ID.")
                return
            }
            try openSeededSession(app: app, storedID: storedID)
            assertHittable(app.staticTexts["SEMREH_SLICE4_GIT_UI_SEED"], timeout: 30,
                          message: "Open the owned Git fixture through the normal session deep link.")
            let gitMenu = app.buttons["Git actions"]
            assertHittable(gitMenu, timeout: 20, message: "The seeded repository must expose Git actions.")
            gitMenu.tap()
            XCTAssertTrue(app.buttons["Push"].waitForExistence(timeout: 10))
            for deferred in ["Fetch", "Pull", "Commit", "Commit & Push"] {
                XCTAssertFalse(app.buttons[deferred].exists, "Deferred action must not be offered: \(deferred)")
            }
            attachScreenshot(named: "slice4-git-supported-menu")
            let staging = app.buttons["Stage Changes…"]
            assertHittable(staging, timeout: 10, message: "Staging must remain reachable from production Git menu.")
            staging.tap()
            XCTAssertTrue(app.navigationBars["Stage Changes"].waitForExistence(timeout: 15))
            for deferred in ["Suggest message", "Commit", "Commit Selected", "Discard Changes"] {
                XCTAssertFalse(app.buttons[deferred].exists)
            }
            attachScreenshot(named: "slice4-git-staging-only")
            app.buttons["Done"].tap()
            // Read-only navigation check: never tap Push, stage, or branch writes.
            return
        }

        if environment["SEMREH_SLICE3_APP_KILL_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 app-kill UI requires the pinned stock backend.")
                return
            }
            guard let storedID = environment["SEMREH_SLICE2_TUI_CREATED_SESSION_ID"],
                  storedID.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil else {
                XCTFail("Slice 3 app-kill UI requires a valid pre-seeded durable session ID.")
                return
            }
            let seedMarker = environment["SEMREH_SLICE3_RELAUNCH_SEED_TEXT"] ?? tuiSeedMarker
            guard seedMarker.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$", options: .regularExpression) != nil else {
                XCTFail("Slice 3 app-kill UI requires a bounded synthetic seed marker.")
                return
            }
            try await exerciseOptInActiveAppKill(
                app: app,
                storedID: storedID,
                seedMarker: seedMarker,
                credentials: credentials
            )
            return
        }

        if environment["SEMREH_SLICE3_RELAUNCH_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 relaunch UI requires the pinned stock backend.")
                return
            }
            guard let storedID = environment["SEMREH_SLICE2_TUI_CREATED_SESSION_ID"],
                  storedID.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil else {
                XCTFail("Slice 3 relaunch UI requires a valid pre-seeded durable session ID.")
                return
            }
            let seedMarker = environment["SEMREH_SLICE3_RELAUNCH_SEED_TEXT"] ?? tuiSeedMarker
            guard seedMarker.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$", options: .regularExpression) != nil else {
                XCTFail("Slice 3 relaunch UI requires a bounded synthetic seed marker.")
                return
            }
            try exerciseOptInAppRelaunch(app: app, storedID: storedID, seedMarker: seedMarker)
            return
        }

        let sessionsTab = app.buttons[sessionsButtonLabel]
        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 10), "Successful login must reach the production shell.")
        sessionsTab.tap()
        let newSession = app.buttons["New chat"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 15), "Sessions must expose New chat.")
        attachScreenshot(named: "live-production-authenticated-sessions")
        newSession.tap()

        let defaultBot = app.buttons["bot-profile:default"]
        if defaultBot.waitForExistence(timeout: 5) {
            XCTAssertTrue(defaultBot.isHittable)
            defaultBot.tap()
        }

        let chat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        // SwiftUI propagates ChatView's identifier onto its UIKit text view.
        // Target the actual editable descendant observed in the AX hierarchy.
        let composers = app.descendants(matching: .any).matching(identifier: "chat-composer-input")
        let composer = composers.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composers.count, 1, "The open conversation must expose one composer.")
        if verifiesMuseSurface { requireMuseSurface(in: app, needsTranscript: false) }
        composer.tap()
        composer.typeText("SEMREH_SLICE1_PROMPT")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()

        let acknowledgement = app.staticTexts.matching(
            // Match the visible text leaf, not the combined row's accessibility
            // summary, which may be replaced during canonical reconciliation.
            NSPredicate(format: "label == %@", "SEMREH_SLICE1_ACK")
        ).firstMatch
        let appeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: acknowledgement
        )
        await fulfillment(of: [appeared], timeout: 90)
        XCTAssertTrue(acknowledgement.exists && acknowledgement.isHittable)
        if verifiesMuseSurface {
            requireMuseSurface(in: app)
            let transcript = app.collectionViews["chat-native-transcript-v2"]
            XCTAssertTrue(transcript.waitForExistence(timeout: 10),
                          "The real production send must render through the selected Muse collection.")
            try assertMuseReadableTranscript(app: app, transcript: transcript,
                                             phase: "live-production-reply")
        }
        attachScreenshot(named: "live-production-chat-success")

        if environment["SEMREH_SLICE4_BTW_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 4 BTW UI requires the pinned stock backend.")
                return
            }
            // The deterministic ACK can arrive as a delta before the terminal
            // message.complete. BTW intentionally requires an idle main turn,
            // so wait for the production action control to leave Stop state.
            waitForIdle(app: app)
            exerciseOptInDirectBTWFlow(app: app, composer: composer)
            return
        }

        if environment["SEMREH_SLICE4_BACKGROUND_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 4 background UI requires the pinned stock backend.")
                return
            }
            waitForIdle(app: app)
            exerciseOptInDirectBackgroundFlow(app: app, composer: composer)
            return
        }

        if environment["SEMREH_SLICE4_BRANCH_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 4 branch UI requires the pinned stock backend.")
                return
            }
            exerciseOptInDirectBranchFlow(app: app, parentComposer: composer)
            return
        }

        if environment["SEMREH_SLICE3_ATTACHMENT_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 attachment UI requires the pinned stock backend.")
                return
            }
            exerciseOptInDirectAttachmentFlow(app: app)
        }

        if environment["SEMREH_SLICE3_FILE_PICKER_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 Files picker UI requires the pinned stock backend.")
                return
            }
            exerciseOptInFilePickerFlow(app: app)
            return
        }

        if environment["SEMREH_SLICE3_CLARIFICATION_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 clarification UI requires the pinned stock backend.")
                return
            }
            exerciseOptInClarificationFlow(app: app)
        }

        if environment["SEMREH_SLICE3_BLOCKING_UI"] == "1" {
            guard stockBackend else {
                XCTFail("Slice 3 blocking UI requires the pinned stock backend.")
                return
            }
            exerciseOptInBlockingFlow(app: app)
        }

        if let storedID = environment["SEMREH_SLICE2_TUI_CREATED_SESSION_ID"] {
            XCTAssertNotNil(storedID.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression))
            var link = URLComponents()
            link.scheme = "semreh"
            link.host = "session"
            link.queryItems = [URLQueryItem(name: "id", value: storedID)]
            app.open(try XCTUnwrap(link.url))
            let tuiPrompt = app.staticTexts[tuiSeedMarker]
            assertHittable(tuiPrompt, timeout: 30,
                          message: "The actual TUI-created transcript must open through the production deep link.")
            assertHittable(acknowledgement, timeout: 15,
                          message: "The TUI-created assistant reply must also be visible.")
            attachScreenshot(named: "live-tui-created-session-in-semreh")
        }
    }

    @MainActor
    private func exerciseOptInDirectBTWFlow(app: XCUIApplication, composer: XCUIElement) {
        let question = "SEMREH_SLICE4_BTW_UI_\(UUID().uuidString)"
        composer.tap()
        composer.typeText("/btw \(question)")

        let send = app.buttons["Send"]
        assertHittable(send, timeout: 10, message: "The production composer must allow the BTW command.")
        send.tap()

        let questionText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", question)
        ).firstMatch
        assertHittable(questionText, timeout: 45,
                       message: "The local BTW card must retain its unique question.")

        XCTAssertNotNil(
            correlatedCardAnswer(app: app, anchor: questionText, answerText: slice1Acknowledgement),
            "The same local BTW card must replace its placeholder with the final stock answer."
        )
        attachScreenshot(named: "slice4-btw-local-answer")
    }

    @MainActor
    private func exerciseOptInDirectBackgroundFlow(app: XCUIApplication, composer: XCUIElement) {
        let prompt = "BG_\(UUID().uuidString): reply exactly \(slice1Acknowledgement)"
        XCTAssertLessThanOrEqual(prompt.count, 80)
        composer.tap()
        composer.typeText("/background \(prompt)")
        let send = app.buttons["Send"]
        assertHittable(send, timeout: 10, message: "The production composer must allow the background command.")
        send.tap()

        let promptText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", prompt)).firstMatch
        assertHittable(promptText, timeout: 45, message: "The local Background card must retain its unique prompt.")
        XCTAssertNotNil(
            correlatedCardAnswer(app: app, anchor: promptText, answerText: slice1Acknowledgement),
            "The correlated Background card must show the expected stock answer."
        )
        attachScreenshot(named: "slice4-background-local-answer")
    }

    @MainActor
    private func correlatedCardAnswer(
        app: XCUIApplication,
        anchor: XCUIElement,
        answerText: String
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(90)
        var correlatedAnswer: XCUIElement?
        repeat {
            correlatedAnswer = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", answerText)
            ).allElementsBoundByIndex.first { answer in
                answer.exists && answer.isHittable
                    && answer.frame.minY >= anchor.frame.maxY
                    && answer.frame.minY - anchor.frame.maxY < 160
                    && abs(answer.frame.minX - anchor.frame.minX) < 40
            }
            if correlatedAnswer != nil { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return correlatedAnswer
    }

    @MainActor
    private func exerciseOptInDirectBranchFlow(
        app: XCUIApplication,
        parentComposer: XCUIElement
    ) {
        let parentIdentifier = parentComposer.identifier
        XCTAssertTrue(parentIdentifier.hasPrefix("chat-detail:"))

        parentComposer.tap()
        parentComposer.typeText("/branch")
        let send = app.buttons["Send"]
        assertHittable(send, timeout: 10, message: "The production composer must allow the branch command.")
        send.tap()

        let deadline = Date().addingTimeInterval(45)
        var childComposer: XCUIElement?
        repeat {
            childComposer = app.textViews.matching(
                NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
            ).allElementsBoundByIndex.first {
                $0.exists && $0.isHittable && $0.identifier != parentIdentifier
            }
            if childComposer != nil { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        guard let childComposer else {
            XCTFail("The branch command must navigate to a distinct retained child chat.")
            return
        }

        let copiedDeadline = Date().addingTimeInterval(20)
        var copiedAcknowledgement: XCUIElement?
        repeat {
            copiedAcknowledgement = app.staticTexts.matching(
                NSPredicate(format: "label == %@", slice1Acknowledgement)
            ).allElementsBoundByIndex.first { $0.exists && $0.isHittable }
            if copiedAcknowledgement != nil { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        } while Date() < copiedDeadline
        XCTAssertNotNil(copiedAcknowledgement, "The child must display the copied parent acknowledgement.")
        attachScreenshot(named: "slice4-branch-child-copied-history")

        let childPrompt = "SEMREH_SLICE4_BRANCH_CHILD_\(UUID().uuidString)"
        childComposer.tap()
        childComposer.typeText(childPrompt)
        assertHittable(send, timeout: 10, message: "The retained child composer must allow an independent turn.")
        send.tap()
        let childPromptElement = app.staticTexts.matching(
            NSPredicate(format: "label == %@", childPrompt)
        ).firstMatch
        assertHittable(childPromptElement, timeout: 20, message: "The exact child-only prompt must appear.")
        XCTAssertNotNil(
            waitForVisibleAcknowledgement(below: childPromptElement, app: app),
            "The child-only turn must complete with exactly one visible fixture acknowledgement."
        )
        attachScreenshot(named: "slice4-branch-child-independent-turn")

        let back = app.buttons["BackButton"]
        assertHittable(back, timeout: 10, message: "The child chat must provide production back navigation.")
        back.tap()
        let parentPrompt = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "SEMREH_SLICE1_PROMPT")
        ).firstMatch
        assertHittable(parentPrompt, timeout: 20, message: "Back navigation must restore the parent transcript.")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label == %@", childPrompt))
                .allElementsBoundByIndex.contains { $0.exists && $0.isHittable },
            "The independent child prompt must not appear in the parent transcript."
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label == %@", slice1Acknowledgement))
                .allElementsBoundByIndex.contains { $0.exists && $0.isHittable },
            "The parent acknowledgement must remain visible and unchanged."
        )
        attachScreenshot(named: "slice4-branch-parent-unchanged")
    }

    @MainActor
    private func exerciseOptInPromptUncertainty(
        app: XCUIApplication,
        storedID: String,
        seedMarker: String,
        credentials: DisposableCredentials
    ) async throws {
        let observer = try await RelaunchCanonicalObserver(
            origin: try XCTUnwrap(URL(string: approvedLiveOrigin)),
            credentials: credentials
        )
        defer { observer.invalidate() }

        try openPromptUncertaintySeedIfNeeded(app: app, storedID: storedID, seedMarker: seedMarker)
        let baseline = try await waitForCanonicalTranscript(
            observer: observer,
            storedID: storedID,
            timeout: 15
        ) { page in
            self.matchesPromptUncertaintyBaseline(page, storedID: storedID, seedMarker: seedMarker)
        }
        try await assertPromptUncertaintyTranscriptVisible(app: app, seedMarker: seedMarker)
        assertComposerEmpty(app: app)
        _ = try requirePromptUncertaintyControls(
            app: app,
            failureScreenshot: "slice3-uncertainty-warning-missing-before-relaunch",
            context: "The fresh fixture must expose its uncertainty warning before relaunch."
        )
        attachScreenshot(named: "slice3-uncertainty-before-relaunch")

        app.terminate()
        app.launchArguments = []
        app.launch()
        try await waitForPromptUncertaintyEntryReadiness(app: app, seedMarker: seedMarker)
        try openPromptUncertaintySeedIfNeeded(app: app, storedID: storedID, seedMarker: seedMarker)
        try await assertPromptUncertaintyTranscriptVisible(app: app, seedMarker: seedMarker)
        assertComposerEmpty(app: app)
        attachScreenshot(named: "slice3-uncertainty-after-relaunch")
        let afterRelaunch = try await observer.transcript(storedID: storedID)
        try assertPromptUncertaintyBaseline(afterRelaunch, storedID: storedID, seedMarker: seedMarker)
        XCTAssertTrue(afterRelaunch.rows.elementsEqual(baseline.rows, by: canonicalRowsEqual),
                      "Relaunch must preserve the exact four canonical seed rows.")

        let (warning, allowNewMessage) = try requirePromptUncertaintyControls(
            app: app,
            failureScreenshot: "slice3-uncertainty-warning-not-ready",
            context: "The recreated chat must expose its visible uncertainty heading and allow-new-message action."
        )
        allowNewMessage.tap()

        let confirmation = app.alerts["Allow a New Message?"]
        assertHittable(confirmation, timeout: 10,
                       message: "Allow-new-message must require an explicit confirmation.")
        XCTAssertTrue(confirmation.buttons["Allow a new message"].exists,
                      "The confirmation must name the explicit new-message action.")
        XCTAssertTrue(confirmation.buttons["Cancel"].exists,
                      "The allow-new-message confirmation must expose Cancel.")
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(warning.waitForExistence(timeout: 10),
                      "Cancelling the confirmation must preserve the uncertainty warning.")
        assertHittable(allowNewMessage, timeout: 10,
                       message: "Cancelling the confirmation must preserve the recovery action.")
        let afterConfirmationCancel = try await observer.transcript(storedID: storedID)
        try assertPromptUncertaintyBaseline(
            afterConfirmationCancel,
            storedID: storedID,
            seedMarker: seedMarker
        )
        XCTAssertTrue(afterConfirmationCancel.rows.elementsEqual(baseline.rows, by: canonicalRowsEqual),
                      "Cancelling the confirmation must preserve the exact canonical seed transcript.")
        attachScreenshot(named: "slice3-uncertainty-confirmation-cancelled")

        allowNewMessage.tap()
        let confirmed = app.alerts["Allow a New Message?"]
        assertHittable(confirmed, timeout: 10,
                       message: "The second allow-new-message attempt must still require confirmation.")
        XCTAssertTrue(confirmed.buttons["Allow a new message"].exists)
        confirmed.buttons["Allow a new message"].tap()

        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: warning
        )
        await fulfillment(of: [cleared], timeout: 20)
        XCTAssertFalse(warning.exists, "The uncertainty warning must clear after explicit confirmation.")
        XCTAssertFalse(allowNewMessage.exists, "The uncertainty action must clear after explicit confirmation.")
        assertComposerEmpty(app: app)

        let afterAbandon = try await observer.transcript(storedID: storedID)
        try assertPromptUncertaintyBaseline(afterAbandon, storedID: storedID, seedMarker: seedMarker)
        XCTAssertTrue(afterAbandon.rows.elementsEqual(baseline.rows, by: canonicalRowsEqual),
                      "Allowing a fresh message must not mutate the canonical seed transcript.")
        attachScreenshot(named: "slice3-uncertainty-after-abandon")

        let newPrompt = uncertaintyNewPromptPrefix + UUID().uuidString
        sendLivePrompt(newPrompt, app: app, screenshotPrefix: "slice3-uncertainty-new-message")
        let final = try await waitForCanonicalTranscript(
            observer: observer,
            storedID: storedID,
            timeout: 30
        ) { page in
            self.matchesPromptUncertaintyFinal(
                page,
                storedID: storedID,
                seedMarker: seedMarker,
                newPrompt: newPrompt
            )
        }
        try assertPromptUncertaintyFinal(
            final,
            storedID: storedID,
            seedMarker: seedMarker,
            newPrompt: newPrompt
        )
        XCTAssertTrue(final.rows.prefix(baseline.rows.count).elementsEqual(baseline.rows, by: canonicalRowsEqual),
                      "The fresh turn must preserve every original canonical row and ID.")
        waitForIdle(app: app)
        assertComposerEmpty(app: app)
        attachPlainText(newPrompt, named: "slice3-uncertainty-new-marker")
        attachScreenshot(named: "slice3-uncertainty-new-message-complete")
    }

    @MainActor
    private func exerciseOptInAppRelaunch(
        app: XCUIApplication,
        storedID: String,
        seedMarker: String
    ) throws {
        try openSeededSession(app: app, storedID: storedID)
        assertSeededTranscriptVisible(app: app, seedMarker: seedMarker, context: "before app termination")
        attachScreenshot(named: "slice3-relaunch-before-terminate")

        app.terminate()
        app.launchArguments = []
        app.launch()
        waitForPostLoginDestination(app: app)

        try openSeededSession(app: app, storedID: storedID)
        assertSeededTranscriptVisible(app: app, seedMarker: seedMarker, context: "after app relaunch")
        attachScreenshot(named: "slice3-relaunch-after-terminate")

        let uniquePrompt = "SEMREH_SLICE3_RELAUNCH_\(UUID().uuidString)"
        sendLivePrompt(uniquePrompt, app: app, screenshotPrefix: "slice3-relaunch-follow-up")
        waitForAcknowledgementCount(
            2,
            app: app,
            message: "The relaunch follow-up must add exactly one terminal fixture ACK."
        )
        waitForIdle(app: app)
        attachScreenshot(named: "slice3-relaunch-follow-up-complete")
    }

    @MainActor
    private func exerciseOptInActiveAppKill(
        app: XCUIApplication,
        storedID: String,
        seedMarker: String,
        credentials: DisposableCredentials
    ) async throws {
        try openSeededSession(app: app, storedID: storedID)
        assertSeededTranscriptVisible(app: app, seedMarker: seedMarker, context: "before app termination")
        let observer = try await RelaunchCanonicalObserver(
            origin: try XCTUnwrap(URL(string: approvedLiveOrigin)),
            credentials: credentials
        )
        defer { observer.invalidate() }
        let baseline = try await observer.transcript(storedID: storedID)
        try assertExactCanonicalRows(
            baseline,
            storedID: storedID,
            users: [seedMarker],
            assistants: [slice1Acknowledgement]
        )

        let uniquePrompt = "SEMREH_INTERRUPT_FIXTURE SEMREH_SLICE3_APP_KILL_\(UUID().uuidString)"
        sendLivePrompt(uniquePrompt, app: app, screenshotPrefix: "slice3-app-kill-accepted")
        attachPlainText(uniquePrompt, named: "slice3-app-kill-marker")
        let accepted = try await waitForCanonicalTranscript(
            observer: observer,
            storedID: storedID,
            timeout: 8
        ) { page in
            self.matchesExactCanonicalRows(
                page,
                storedID: storedID,
                users: [seedMarker, uniquePrompt],
                assistants: [self.slice1Acknowledgement]
            )
        }
        XCTAssertTrue(accepted.rows.prefix(baseline.rows.count).elementsEqual(baseline.rows, by: canonicalRowsEqual))
        attachScreenshot(named: "slice3-app-kill-before-terminate")

        // This is the real XCTest process-death operation. No launch argument
        // resets the app's persisted server/auth state on the second launch.
        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "The accepted run must outlive an actually terminated app process.")

        // A first still-incomplete read after termination removes the race where
        // the fixture could have completed just before XCTest killed the app.
        let firstPostKill = try await observer.transcript(storedID: storedID)
        XCTAssertEqual(app.state, .notRunning)
        try assertExactCanonicalRows(
            firstPostKill,
            storedID: storedID,
            users: [seedMarker, uniquePrompt],
            assistants: [slice1Acknowledgement]
        )
        XCTAssertTrue(firstPostKill.rows.prefix(baseline.rows.count).elementsEqual(baseline.rows, by: canonicalRowsEqual))

        let completedWhileDead = try await waitForCanonicalTranscript(
            observer: observer,
            storedID: storedID,
            timeout: 30,
            beforeEachRead: {
                XCTAssertEqual(app.state, .notRunning, "The app must remain dead until canonical completion.")
            }
        ) { page in
            self.matchesExactCanonicalRows(
                page,
                storedID: storedID,
                users: [seedMarker, uniquePrompt],
                assistants: [self.slice1Acknowledgement, self.slice1Acknowledgement]
            )
        }
        XCTAssertEqual(app.state, .notRunning)
        XCTAssertTrue(completedWhileDead.rows.prefix(baseline.rows.count).elementsEqual(baseline.rows, by: canonicalRowsEqual))

        app.launchArguments = []
        app.launch()
        waitForPostLoginDestination(app: app)

        try openSeededSession(app: app, storedID: storedID)
        assertSeededTranscriptVisible(app: app, seedMarker: seedMarker, context: "after app relaunch")
        let uniqueUserRows = app.staticTexts.matching(NSPredicate(format: "label == %@", uniquePrompt))
        XCTAssertEqual(uniqueUserRows.count, 1, "Relaunch must render the accepted prompt exactly once.")
        waitForAcknowledgementCount(
            2,
            app: app,
            message: "Relaunch must render exactly the seeded and recovered fixture ACKs."
        )
        waitForIdle(app: app)
        let composer = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let composerValue = (composer.value as? String) ?? ""
        XCTAssertTrue(
            composerValue.isEmpty || composerValue == composer.placeholderValue,
            "The submitted prompt must not return as a stale composer draft."
        )
        XCTAssertFalse(composerValue.contains(uniquePrompt))

        let finalCanonical = try await observer.transcript(storedID: storedID)
        try assertExactCanonicalRows(
            finalCanonical,
            storedID: storedID,
            users: [seedMarker, uniquePrompt],
            assistants: [slice1Acknowledgement, slice1Acknowledgement]
        )
        XCTAssertTrue(finalCanonical.rows.prefix(baseline.rows.count).elementsEqual(baseline.rows, by: canonicalRowsEqual))
        XCTAssertTrue(finalCanonical.rows.elementsEqual(completedWhileDead.rows, by: canonicalRowsEqual))
        attachScreenshot(named: "slice3-app-kill-recovered")
    }

    @MainActor
    private func waitForCanonicalTranscript(
        observer: RelaunchCanonicalObserver,
        storedID: String,
        timeout: TimeInterval,
        beforeEachRead: () -> Void = {},
        matches: (RelaunchCanonicalTranscript) -> Bool
    ) async throws -> RelaunchCanonicalTranscript {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            beforeEachRead()
            let page = try await observer.transcript(storedID: storedID)
            if matches(page) { return page }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw NSError(
            domain: "LongChatScrollUITests",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Canonical transcript did not reach the exact expected state before the fixture deadline."]
        )
    }

    @MainActor
    private func assertExactCanonicalRows(
        _ page: RelaunchCanonicalTranscript,
        storedID: String,
        users: [String],
        assistants: [String]
    ) throws {
        guard matchesExactCanonicalRows(page, storedID: storedID, users: users, assistants: assistants) else {
            throw NSError(
                domain: "LongChatScrollUITests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Canonical transcript did not contain the exact expected user/assistant rows."]
            )
        }
    }

    @MainActor
    private func matchesExactCanonicalRows(
        _ page: RelaunchCanonicalTranscript,
        storedID: String,
        users: [String],
        assistants: [String]
    ) -> Bool {
        guard page.sessionID == storedID,
              page.rows.count == users.count + assistants.count else { return false }
        let durableIDs = page.rows.compactMap { canonicalDurableRowID($0["id"]) }
        guard durableIDs.count == page.rows.count,
              Set(durableIDs).count == durableIDs.count else { return false }
        let roles = page.rows.compactMap { $0["role"] as? String }
        let texts = page.rows.compactMap(canonicalRowText)
        var expectedRoles: [String] = []
        var expectedTexts: [String] = []
        for index in users.indices {
            expectedRoles.append("user")
            expectedTexts.append(users[index])
            if assistants.indices.contains(index) {
                expectedRoles.append("assistant")
                expectedTexts.append(assistants[index])
            }
        }
        return roles == expectedRoles && texts == expectedTexts
    }

    @MainActor
    private func canonicalDurableRowID(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return "s:" + string }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double else { return nil }
        return "n:" + number.stringValue
    }

    @MainActor
    private func canonicalRowText(_ row: [String: Any]) -> String? {
        if let text = row["content"] as? String { return text }
        guard let blocks = row["content"] as? [[String: Any]] else { return nil }
        return blocks.compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }

    @MainActor
    private func canonicalRowsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(NSDictionary(dictionary: rhs))
    }

    @MainActor
    private func openSeededSession(app: XCUIApplication, storedID: String) throws {
        var link = URLComponents()
        link.scheme = "semreh"
        link.host = "session"
        link.queryItems = [URLQueryItem(name: "id", value: storedID)]
        app.open(try XCTUnwrap(link.url))
    }

    @MainActor
    private func assertSeededTranscriptVisible(
        app: XCUIApplication,
        seedMarker: String,
        context: String
    ) {
        let prompt = app.staticTexts.matching(
            NSPredicate(format: "label == %@", seedMarker)
        ).firstMatch
        assertHittable(
            prompt,
            timeout: 30,
            message: "The pre-seeded session must expose its marker (\(context))."
        )
        let acknowledgement = app.staticTexts.matching(
            NSPredicate(format: "label == %@", slice1Acknowledgement)
        ).firstMatch
        assertHittable(
            acknowledgement,
            timeout: 15,
            message: "The pre-seeded session must expose its terminal ACK (\(context))."
        )
    }

    @MainActor
    private func waitForPromptUncertaintyEntryReadiness(
        app: XCUIApplication,
        seedMarker: String
    ) async throws {
        let seed = app.staticTexts.matching(NSPredicate(format: "label == %@", seedMarker)).firstMatch
        let sessions = app.buttons["Sessions"]
        let knownBackButton = app.navigationBars.buttons["BackButton"]
        let welcome = app.staticTexts["Control Semreh from iPhone or iPad."]
        let serverField = app.textFields["onboarding-server-url"]
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let onboardingIsAbsent = !welcome.exists && !serverField.exists
            if onboardingIsAbsent,
               (seed.exists && seed.isHittable
                || sessions.exists && sessions.isHittable
                || knownBackButton.exists && knownBackButton.isHittable) {
                attachScreenshot(named: "slice3-uncertainty-entry-ready")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        attachScreenshot(named: "slice3-uncertainty-entry-not-ready")
        XCTFail("Uncertainty recovery login must reach the exact seed, the Sessions shell, or a known restored chat without onboarding.")
        throw NSError(domain: "SemrehUncertaintyUI", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "The uncertainty recovery entry point was not ready; stopping before navigation assertions."
        ])
    }

    @MainActor
    private func openPromptUncertaintySeedIfNeeded(
        app: XCUIApplication,
        storedID: String,
        seedMarker: String
    ) throws {
        let seed = app.staticTexts.matching(NSPredicate(format: "label == %@", seedMarker)).firstMatch
        // Normal login/relaunch may already restore this exact synthetic chat.
        // XCUIApplication.open can launch a new process; don't add that distinct
        // cold-URL boundary to a test of an already-restored conversation.
        attachScreenshot(named: "slice3-uncertainty-before-ensure-chat")
        if seed.exists && seed.isHittable { return }
        let backButton = app.navigationBars.buttons["BackButton"]
        if backButton.exists && backButton.isHittable {
            let restoredChat = app.otherElements.matching(
                NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
            ).firstMatch
            backButton.tap()
            let leftRestoredChat = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: restoredChat
            )
            wait(for: [leftRestoredChat], timeout: 15)
            let sessions = app.buttons["Sessions"]
            guard !restoredChat.exists,
                  sessions.waitForExistence(timeout: 15), sessions.isHittable else {
                attachScreenshot(named: "slice3-uncertainty-restored-chat-back-failed")
                XCTFail("The known restored chat must navigate back to the Sessions shell before opening a different seed.")
                throw NSError(domain: "SemrehUncertaintyUI", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "The restored chat could not return to Sessions; stopping before the seed URL launch."
                ])
            }
        }
        try openSeededSession(app: app, storedID: storedID)
        attachScreenshot(named: "slice3-uncertainty-after-open-url")
    }

    @MainActor
    private func requirePromptUncertaintyControls(
        app: XCUIApplication,
        failureScreenshot: String,
        context: String
    ) throws -> (warning: XCUIElement, allowNewMessage: XCUIElement) {
        let warning = app.staticTexts[uncertaintyBannerIdentifier]
        let allowNewMessage = app.buttons[uncertaintyAllowIdentifier]
        guard warning.waitForExistence(timeout: 15), warning.isHittable,
              allowNewMessage.waitForExistence(timeout: 10), allowNewMessage.isHittable else {
            attachScreenshot(named: failureScreenshot)
            XCTFail(context)
            throw NSError(domain: "SemrehUncertaintyUI", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "The uncertainty warning controls were not ready; stopping before recovery actions."
            ])
        }
        return (warning, allowNewMessage)
    }

    @MainActor
    private func assertPromptUncertaintyTranscriptVisible(
        app: XCUIApplication,
        seedMarker: String
    ) async throws {
        let seed = app.staticTexts.matching(NSPredicate(format: "label == %@", seedMarker)).firstMatch
        let delayed = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", uncertaintyDelayedPromptPrefix)
        ).firstMatch
        let visible = NSPredicate(format: "exists == true AND hittable == true")
        await fulfillment(of: [
            XCTNSPredicateExpectation(predicate: visible, object: seed),
            XCTNSPredicateExpectation(predicate: visible, object: delayed)
        ], timeout: 15)
        guard seed.exists && seed.isHittable && delayed.exists && delayed.isHittable else {
            attachScreenshot(named: "slice3-uncertainty-missing-seed")
            throw NSError(domain: "SemrehUncertaintyUI", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The exact uncertainty chat was not visible; stopping before recovery actions."
            ])
        }
    }

    @MainActor
    private func assertComposerEmpty(app: XCUIApplication) {
        let composer = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15),
                      "The uncertainty chat must expose its production composer.")
        let value = (composer.value as? String) ?? ""
        XCTAssertTrue(value.isEmpty || value == composer.placeholderValue,
                      "The uncertainty recovery action must leave the composer empty.")
    }

    @MainActor
    private func matchesPromptUncertaintyBaseline(
        _ page: RelaunchCanonicalTranscript,
        storedID: String,
        seedMarker: String
    ) -> Bool {
        guard page.sessionID == storedID, page.rows.count == 4 else { return false }
        let durableIDs = page.rows.compactMap { canonicalDurableRowID($0["id"]) }
        guard durableIDs.count == 4, Set(durableIDs).count == 4 else { return false }
        let roles = page.rows.compactMap { $0["role"] as? String }
        let texts = page.rows.compactMap(canonicalRowText)
        guard roles == ["user", "assistant", "user", "assistant"], texts.count == 4 else {
            return false
        }
        return texts[0] == seedMarker
            && texts[1] == slice1Acknowledgement
            && texts[2].hasPrefix(uncertaintyDelayedPromptPrefix)
            && texts[3] == slice1Acknowledgement
    }

    @MainActor
    private func assertPromptUncertaintyBaseline(
        _ page: RelaunchCanonicalTranscript,
        storedID: String,
        seedMarker: String
    ) throws {
        guard matchesPromptUncertaintyBaseline(page, storedID: storedID, seedMarker: seedMarker) else {
            throw NSError(
                domain: "LongChatScrollUITests",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "The uncertainty seed transcript must contain exactly two canonical user/assistant pairs."]
            )
        }
    }

    @MainActor
    private func matchesPromptUncertaintyFinal(
        _ page: RelaunchCanonicalTranscript,
        storedID: String,
        seedMarker: String,
        newPrompt: String
    ) -> Bool {
        guard page.sessionID == storedID, page.rows.count == 6 else { return false }
        let durableIDs = page.rows.compactMap { canonicalDurableRowID($0["id"]) }
        guard durableIDs.count == 6, Set(durableIDs).count == 6 else { return false }
        let roles = page.rows.compactMap { $0["role"] as? String }
        let texts = page.rows.compactMap(canonicalRowText)
        guard roles == ["user", "assistant", "user", "assistant", "user", "assistant"], texts.count == 6 else {
            return false
        }
        return texts[0] == seedMarker
            && texts[1] == slice1Acknowledgement
            && texts[2].hasPrefix(uncertaintyDelayedPromptPrefix)
            && texts[3] == slice1Acknowledgement
            && texts[4] == newPrompt
            && texts[5] == slice1Acknowledgement
    }

    @MainActor
    private func assertPromptUncertaintyFinal(
        _ page: RelaunchCanonicalTranscript,
        storedID: String,
        seedMarker: String,
        newPrompt: String
    ) throws {
        guard matchesPromptUncertaintyFinal(page, storedID: storedID, seedMarker: seedMarker, newPrompt: newPrompt) else {
            throw NSError(
                domain: "LongChatScrollUITests",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "The uncertainty new-message turn must contain exactly three canonical user/assistant pairs."]
            )
        }
    }

    @MainActor
    private func waitForAcknowledgementCount(
        _ expected: Int,
        app: XCUIApplication,
        message: String
    ) {
        let deadline = Date().addingTimeInterval(90)
        let acknowledgements = app.staticTexts.matching(
            NSPredicate(format: "label == %@", slice1Acknowledgement)
        )
        while acknowledgements.count < expected && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(acknowledgements.count, expected, message)
    }

    @MainActor
    private func waitForVisibleAcknowledgement(
        below prompt: XCUIElement,
        app: XCUIApplication,
        timeout: TimeInterval = 90
    ) -> XCUIElement? {
        let acknowledgements = app.staticTexts.matching(
            NSPredicate(format: "label == %@", slice1Acknowledgement)
        )
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if prompt.exists && prompt.isHittable {
                if let acknowledgement = acknowledgements.allElementsBoundByIndex.first(where: {
                    $0.exists && $0.isHittable && $0.frame.minY >= prompt.frame.maxY
                }) {
                    let belowPrompt = acknowledgements.allElementsBoundByIndex.filter {
                        $0.exists && $0.isHittable && $0.frame.minY >= prompt.frame.maxY
                    }
                    XCTAssertEqual(
                        belowPrompt.count,
                        1,
                        "The new prompt must have exactly one visible fixture ACK below it."
                    )
                    return acknowledgement
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("The Files picker turn must expose a visible terminal ACK below its exact new prompt.")
        return nil
    }

    @MainActor
    private func exerciseOptInDirectAttachmentFlow(app: XCUIApplication) {
        let composers = app.textViews.matching(identifier: "chat-composer-input")
        let composer = composers.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The production chat must expose its composer for attachment staging.")
        let chat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "The attachment flow must expose its production chat.")
        let chatDetailIdentifier = chat.identifier
        XCTAssertTrue(
            chatDetailIdentifier.hasPrefix("chat-detail:"),
            "The attachment flow must remain scoped to the actual production chat identifier."
        )

        composer.tap()
        pastePNG(knownPNGData, into: composer, app: app)

        let chip = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Open attachment '")
        ).firstMatch
        assertHittable(
            chip,
            timeout: 15,
            message: "Pasting a PNG through the native composer must expose an attachment chip."
        )
        attachScreenshot(named: "slice3-attachment-chip")
        let attachmentName = chip.label.replacingOccurrences(of: "Open attachment ", with: "")
        XCTAssertFalse(attachmentName.isEmpty, "The native attachment chip must expose its generated filename.")

        chip.tap()
        let previewTitle = app.navigationBars.staticTexts[attachmentName]
        XCTAssertTrue(
            previewTitle.waitForExistence(timeout: 10),
            "Opening the attachment chip must present the native memory preview."
        )
        let previewImage = app.images[attachmentName]
        XCTAssertTrue(
            previewImage.waitForExistence(timeout: 10),
            "The direct PNG preview must render from retained memory bytes."
        )
        let done = app.buttons["Done"]
        assertHittable(done, timeout: 5, message: "The attachment preview must expose Done.")
        done.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: previewImage
        )
        wait(for: [dismissed], timeout: 10)
        XCTAssertFalse(previewImage.exists, "Dismissing the attachment preview must return to the composer.")
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "Dismissing preview must retain the pending attachment chip.")

        let priorAcknowledgementCount = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "SEMREH_SLICE1_ACK")
        ).count
        let prompt = "SEMREH_SLICE3_ATTACHMENT_UI_PROMPT_\(UUID().uuidString)"
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["Send"]
        assertHittable(send, timeout: 10, message: "The composer Send action must be available after attachment staging.")
        send.tap()

        // Stock canonical history appends its image reference to the user text.
        // Match this run's exact marker prefix, not a previous warm-up response.
        let marker = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", prompt, prompt + "\n")
        ).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 20), "The unique attachment prompt must appear in the transcript.")
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            // The broad discovery query can now resolve to the new canonical
            // transcript cell. Check the exact original composer filename.
            object: app.buttons["Open attachment " + attachmentName]
        )
        wait(for: [cleared], timeout: 20)
        XCTAssertFalse(app.buttons["Open attachment " + attachmentName].exists,
                       "Sending must clear the staged attachment chip.")

        let acknowledgement = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "SEMREH_SLICE1_ACK")
        )
        let newAcknowledgement = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > %d", priorAcknowledgementCount),
            object: acknowledgement
        )
        wait(for: [newAcknowledgement], timeout: 90)
        XCTAssertGreaterThan(
            acknowledgement.count,
            priorAcknowledgementCount,
            "The attachment turn must produce a new terminal ACK beyond the warm-up response."
        )
        waitForIdle(app: app)
        let canonicalAttachment = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Open attachment upload_'")
        ).firstMatch
        XCTAssertTrue(canonicalAttachment.waitForExistence(timeout: 15),
                      "Canonical image references must become attachment cells.")
        if !canonicalAttachment.isHittable {
            app.scrollViews.matching(
                NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
            ).firstMatch.swipeDown()
        }
        assertHittable(canonicalAttachment, timeout: 10,
                       message: "The canonical attachment must be reachable in the transcript.")
        let canonicalName = canonicalAttachment.label.replacingOccurrences(of: "Open attachment ", with: "")
        canonicalAttachment.tap()
        let canonicalImage = app.images[canonicalName]
        XCTAssertTrue(canonicalImage.waitForExistence(timeout: 15),
                      "The canonical image preview must load through the authenticated stock media route.")
        attachScreenshot(named: "slice3-attachment-canonical-media-preview")
        app.buttons["Done"].tap()
        let canonicalDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: canonicalImage
        )
        wait(for: [canonicalDismissed], timeout: 10)
        XCTAssertFalse(app.buttons["discard-pending-upload"].exists,
                       "A normally completed known upload must not leave an unresolved-upload recovery banner.")
        attachPlainText(
            "\(chatDetailIdentifier)\n\(prompt)",
            named: "slice3-attachment-chat-title-and-marker"
        )
        attachScreenshot(named: "slice3-attachment-send-success")
    }

    @MainActor
    private func exerciseOptInFilePickerFlow(app: XCUIApplication) {
        let composers = app.textViews.matching(identifier: "chat-composer-input")
        let composer = composers.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The production chat must expose its composer for Files picker attachment staging.")
        let textPrompt = "SEMREH_SLICE3_FILE_PICKER_TEXT_\(UUID().uuidString)"
        let pdfPrompt = "SEMREH_SLICE3_FILE_PICKER_PDF_\(UUID().uuidString)"
        attachPlainText("\(textPrompt)\n\(pdfPrompt)", named: "slice3-file-picker-prompts")

        exerciseFilePickerTurn(
            filename: "semreh-picker.txt",
            prompt: textPrompt,
            expectedText: "SEMREH_FILE_PICKER_TEXT_V1",
            expectedPDF: false,
            app: app,
            composer: composer
        )
        exerciseFilePickerTurn(
            filename: "semreh-picker.pdf",
            prompt: pdfPrompt,
            expectedText: nil,
            expectedPDF: true,
            app: app,
            composer: composer
        )
        XCTAssertFalse(
            app.buttons["discard-pending-upload"].exists,
            "Completed Files picker turns must not leave an unresolved-upload recovery banner."
        )
        attachScreenshot(named: "slice3-file-picker-roundtrip-complete")
    }

    @MainActor
    private func exerciseFilePickerTurn(
        filename: String,
        prompt: String,
        expectedText: String?,
        expectedPDF: Bool,
        app: XCUIApplication,
        composer: XCUIElement
    ) {
        let canonicalQuery = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Open attachment '")
        )
        let baselineCanonicalLabels = Set(canonicalQuery.allElementsBoundByIndex.map(\.label))
        guard openSyntheticFileFromDocumentPicker(filename: filename, app: app) else { return }

        let chip = app.buttons["Open attachment \(filename)"]
        assertHittable(
            chip,
            timeout: 20,
            message: "Selecting \(filename) through the production Files picker must expose its composer chip."
        )
        XCTAssertTrue(app.buttons["Remove attachment \(filename)"].exists)
        if expectedPDF {
            chip.tap()
            let localPDF = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "PDF document \(filename)")
            ).firstMatch
            guard localPDF.waitForExistence(timeout: 20), localPDF.isHittable else {
                attachAccessibilitySnapshot(named: "slice3-file-picker-local-pdf-not-found", app: app)
                attachScreenshot(named: "slice3-file-picker-local-pdf-not-found")
                XCTFail("The selected PDF must expose the local native PDF preview before sending.")
                return
            }
            let localDone = app.buttons["Done"]
            assertHittable(localDone, timeout: 10, message: "The local PDF preview must expose Done.")
            localDone.tap()
            assertHittable(chip, timeout: 10, message: "Closing the local PDF preview must retain the staged chip.")
        }
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["Send"]
        assertHittable(send, timeout: 10, message: "The Files picker attachment turn must expose Send.")
        send.tap()

        let promptElement = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", prompt, prompt + "\n")
        ).firstMatch
        assertHittable(promptElement, timeout: 25, message: "The Files picker prompt must appear in the transcript.")
        let removeChip = app.buttons["Remove attachment \(filename)"]
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: removeChip
        )
        wait(for: [cleared], timeout: 20)
        XCTAssertFalse(removeChip.exists, "Sending \(filename) must clear its staged composer chip.")

        guard waitForVisibleAcknowledgement(below: promptElement, app: app) != nil else { return }
        waitForIdle(app: app)

        guard let canonical = waitForExactlyOneNewCanonicalAttachment(
            app: app,
            baselineLabels: baselineCanonicalLabels
        ) else { return }
        assertHittable(
            canonical,
            timeout: 25,
            message: "The server-returned \(filename) attachment must be reachable in the transcript."
        )
        let canonicalName = canonical.label.replacingOccurrences(of: "Open attachment ", with: "")
        canonical.tap()

        let previewElement: XCUIElement
        if let expectedText {
            let text = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", expectedText)
            ).firstMatch
            assertHittable(text, timeout: 20, message: "The returned text attachment must render its exact fixture content.")
            XCTAssertTrue(text.label.contains("Synthetic file used only for the isolated Semreh migration test."))
            previewElement = text
        } else if expectedPDF {
            let pageImage = app.images[canonicalName]
            assertHittable(pageImage, timeout: 20, message: "The sent PDF must return a native page-image preview.")
            previewElement = pageImage
        } else {
            XCTFail("The Files picker roundtrip must specify a preview assertion.")
            return
        }

        attachScreenshot(named: "slice3-file-picker-returned-\(filename)")
        attachPlainText(prompt, named: "slice3-file-picker-marker-\(filename)")
        let done = app.buttons["Done"]
        assertHittable(done, timeout: 10, message: "The Files picker attachment preview must expose Done.")
        done.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: previewElement
        )
        wait(for: [dismissed], timeout: 10)
        XCTAssertFalse(previewElement.exists, "Dismissing the Files picker preview must return to the composer/transcript.")
    }

    @MainActor
    private func waitForExactlyOneNewCanonicalAttachment(
        app: XCUIApplication,
        baselineLabels: Set<String>,
        timeout: TimeInterval = 25
    ) -> XCUIElement? {
        let canonicalQuery = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Open attachment '")
        )
        let newCanonicalQuery = canonicalQuery.matching(
            NSPredicate(format: "NOT (label IN %@)", Array(baselineLabels))
        )
        let returnedAttachmentAppeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"),
            object: newCanonicalQuery
        )
        wait(for: [returnedAttachmentAppeared], timeout: timeout)
        let newCanonical = newCanonicalQuery.allElementsBoundByIndex
        XCTAssertEqual(
            newCanonical.count,
            1,
            "The one-page/file turn must add exactly one server-returned attachment cell beyond the prior transcript."
        )
        return newCanonical.first
    }

    @MainActor
    private func openSyntheticFileFromDocumentPicker(filename: String, app: XCUIApplication) -> Bool {
        let options = app.buttons["Composer options"]
        assertHittable(options, timeout: 10, message: "The production composer must expose Composer options.")
        options.tap()

        let attachFile = app.buttons["Attach File"]
        guard attachFile.waitForExistence(timeout: 10), attachFile.isHittable else {
            attachAccessibilitySnapshot(named: "slice3-file-picker-menu-not-found", app: app)
            XCTFail("Composer options must expose Attach File.")
            return false
        }
        attachFile.tap()

        // The first presentation normally opens Recents. Navigate through the
        // stock Browse/On My iPhone hierarchy; subsequent presentations may
        // remember the owned fixture folder, so both steps are conditional.
        let browse = app.buttons["Browse"]
        if browse.waitForExistence(timeout: 5) && browse.isHittable {
            browse.tap()
        }
        let onMyIPhone = app.buttons["On My iPhone"]
        if onMyIPhone.waitForExistence(timeout: 10) && onMyIPhone.isHittable {
            onMyIPhone.tap()
        }

        // Files hides extensions visually, but exposes basename/type in its
        // cell identifier (captured from the real system picker).
        let fileURL = URL(fileURLWithPath: filename)
        let file = app.cells["\(fileURL.deletingPathExtension().lastPathComponent), \(fileURL.pathExtension)"]
        // Files remembers the last directory after the first selection. If
        // the exact owned fixture is already visible, select it directly;
        // otherwise navigate through the seeded folder.
        if !file.waitForExistence(timeout: 5) {
            let folder = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "SemrehSyntheticFixtures")
            ).firstMatch
            guard folder.waitForExistence(timeout: 20), folder.isHittable else {
                attachAccessibilitySnapshot(named: "slice3-file-picker-folder-not-found", app: app)
                attachScreenshot(named: "slice3-file-picker-folder-not-found")
                XCTFail("The system Files picker must expose the owned synthetic fixture folder.")
                return false
            }
            folder.tap()
        }
        guard file.waitForExistence(timeout: 15), file.isHittable else {
            attachAccessibilitySnapshot(named: "slice3-file-picker-file-not-found", app: app)
            attachScreenshot(named: "slice3-file-picker-file-not-found")
            XCTFail("The system Files picker must expose \(filename).")
            return false
        }
        file.tap()

        let open = app.buttons["Open"]
        guard open.waitForExistence(timeout: 10), open.isHittable else {
            attachAccessibilitySnapshot(named: "slice3-file-picker-open-not-found", app: app)
            attachScreenshot(named: "slice3-file-picker-open-not-found")
            XCTFail("The system Files picker must expose Open after selecting \(filename).")
            return false
        }
        open.tap()
        let pickerDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: file
        )
        wait(for: [pickerDismissed], timeout: 15)
        return true
    }

    @MainActor
    private func exerciseOptInClarificationFlow(app: XCUIApplication) {
        // The model fixture uses exact markers. Each response is followed by a
        // distinct ordinary turn so this test proves the blocking request was
        // released; a previous ACK alone is not evidence of terminal delivery.
        runSingleClarificationAnswer(app: app)
        runSingleClarificationCancel(app: app)
        runCancelOnlyClarification(
            marker: clarificationBatchMarker,
            question: "multi-question clarification",
            acknowledgement: batchCancelAcknowledgement,
            screenshotPrefix: "slice3-clarification-batch",
            app: app
        )
        runCancelOnlyClarification(
            marker: clarificationMultiSelectMarker,
            question: "multi-select clarification",
            acknowledgement: multiSelectCancelAcknowledgement,
            screenshotPrefix: "slice3-clarification-multi-select",
            app: app
        )
    }

    @MainActor
    private func exerciseOptInBlockingFlow(app: XCUIApplication) {
        runBlockingApprovalDenial(app: app)
        runBlockingSecretCancellation(app: app)
    }

    @MainActor
    private func runBlockingApprovalDenial(app: XCUIApplication) {
        sendLivePrompt(
            blockingApprovalMarker,
            app: app,
            screenshotPrefix: "slice3-blocking-approval-request"
        )
        let heading = app.staticTexts["Approval required"]
        XCTAssertTrue(
            heading.waitForExistence(timeout: 30),
            "The synthetic approval marker must expose the stock approval heading."
        )
        let deny = app.buttons[blockingApprovalDenyIdentifier]
        XCTAssertFalse(app.buttons["approval-request-skip-all"].exists,
                       "Direct approval must not offer the legacy bulk bypass.")
        assertHittable(
            deny,
            timeout: 15,
            message: "The synthetic approval overlay must expose its deny action."
        )
        attachScreenshot(named: "slice3-blocking-approval-request-card")
        deny.tap()
        waitForBlockingElementToClear(
            heading,
            button: deny,
            screenshotName: "slice3-blocking-approval-cleared"
        )
        waitForBlockingAcknowledgement(
            blockingApprovalAcknowledgement,
            app: app,
            screenshotName: "slice3-blocking-approval-follow-up-ack"
        )
    }

    @MainActor
    private func runBlockingSecretCancellation(app: XCUIApplication) {
        sendLivePrompt(
            blockingSecretMarker,
            app: app,
            screenshotPrefix: "slice3-blocking-secret-request"
        )
        let heading = app.staticTexts["Secret required"]
        XCTAssertTrue(
            heading.waitForExistence(timeout: 30),
            "The synthetic secret marker must expose the cancel-only heading."
        )
        let explanation = app.staticTexts[
            "This app cannot securely enter this value yet. Cancel to unblock the request without sending a secret."
        ]
        XCTAssertTrue(
            explanation.waitForExistence(timeout: 10),
            "The secret prompt must explain that no secret entry is available."
        )
        XCTAssertEqual(
            app.textFields.count,
            0,
            "The secret cancellation prompt must not expose a regular text input field."
        )
        XCTAssertEqual(
            app.secureTextFields.count,
            0,
            "The secret cancellation prompt must not expose a secure input field."
        )
        let cancel = app.buttons[blockingSecretCancelIdentifier]
        assertHittable(
            cancel,
            timeout: 15,
            message: "The synthetic secret overlay must expose its explicit cancel action."
        )
        attachScreenshot(named: "slice3-blocking-secret-request-card")
        cancel.tap()
        waitForBlockingElementToClear(
            heading,
            button: cancel,
            screenshotName: "slice3-blocking-secret-cleared"
        )
        waitForBlockingAcknowledgement(
            blockingSecretAcknowledgement,
            app: app,
            screenshotName: "slice3-blocking-secret-follow-up-ack"
        )
    }

    @MainActor
    private func waitForBlockingElementToClear(
        _ element: XCUIElement,
        button: XCUIElement,
        screenshotName: String
    ) {
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        wait(for: [cleared], timeout: 30)
        XCTAssertFalse(element.exists, "The blocking prompt must clear after its response.")
        XCTAssertFalse(button.exists, "The blocking action must disappear after its response.")
        attachScreenshot(named: screenshotName)
    }

    @MainActor
    private func waitForBlockingAcknowledgement(
        _ acknowledgement: String,
        app: XCUIApplication,
        screenshotName: String
    ) {
        let terminal = app.staticTexts[acknowledgement]
        assertHittable(
            terminal,
            timeout: 90,
            message: "The blocking response must produce its unique terminal ACK."
        )
        waitForIdle(app: app)
        attachScreenshot(named: screenshotName)
    }

    @MainActor
    private func runSingleClarificationAnswer(app: XCUIApplication) {
        sendLivePrompt(
            clarificationSingleMarker,
            app: app,
            screenshotPrefix: "slice3-clarification-single-answer-request"
        )
        let card = waitForClarificationCard(app: app)
        assertSingleClarificationQuestion(in: card)
        let answer = card.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "answer")
        ).firstMatch
        assertHittable(answer, timeout: 10,
                       message: "Single clarification must expose its advertised answer choice.")
        answer.tap()
        waitForClarificationCardToClear(card,
                                        screenshotName: "slice3-clarification-single-answer-cleared")
        waitForNextTurnSuccess(
            prompt: "SEMREH_SLICE3_CLARIFY_AFTER_SINGLE_ANSWER",
            acknowledgement: singleAnswerAcknowledgement,
            app: app
        )
    }

    @MainActor
    private func runSingleClarificationCancel(app: XCUIApplication) {
        sendLivePrompt(
            clarificationSingleMarker,
            app: app,
            screenshotPrefix: "slice3-clarification-single-cancel-request"
        )
        let card = waitForClarificationCard(app: app)
        assertSingleClarificationQuestion(in: card)
        let cancel = app.buttons[clarificationCancelIdentifier]
        assertHittable(cancel, timeout: 10,
                       message: "Single clarification must expose an explicit cancel action.")
        cancel.tap()
        waitForClarificationCardToClear(card,
                                        screenshotName: "slice3-clarification-single-cancel-cleared")
        waitForNextTurnSuccess(
            prompt: "SEMREH_SLICE3_CLARIFY_AFTER_SINGLE_CANCEL",
            acknowledgement: singleCancelAcknowledgement,
            app: app
        )
    }

    @MainActor
    private func runCancelOnlyClarification(
        marker: String,
        question: String,
        acknowledgement: String,
        screenshotPrefix: String,
        app: XCUIApplication
    ) {
        sendLivePrompt(
            marker,
            app: app,
            screenshotPrefix: screenshotPrefix + "-request"
        )
        let card = waitForClarificationCard(app: app)
        let unsupportedQuestion = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", question)
        ).firstMatch
        XCTAssertTrue(
            unsupportedQuestion.waitForExistence(timeout: 5),
            "The unsupported clarification must render its cancel-only explanation."
        )
        let answer = card.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "answer")
        ).firstMatch
        XCTAssertFalse(answer.exists,
                       "Unsupported clarification must not expose an answer choice.")
        XCTAssertFalse(card.buttons["direct.clarification.submit"].exists,
                       "Unsupported clarification must not expose a submit action.")
        let cancel = app.buttons[clarificationCancelIdentifier]
        assertHittable(cancel, timeout: 10,
                       message: "Unsupported clarification must expose cancel-only dismissal.")
        attachScreenshot(named: screenshotPrefix + "-card")
        cancel.tap()
        waitForClarificationCardToClear(card,
                                        screenshotName: screenshotPrefix + "-cleared")
        waitForNextTurnSuccess(
            prompt: "SEMREH_SLICE3_CLARIFY_AFTER_" + marker,
            acknowledgement: acknowledgement,
            app: app
        )
    }

    @MainActor
    private func sendLivePrompt(
        _ prompt: String,
        app: XCUIApplication,
        screenshotPrefix: String
    ) {
        let composers = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        )
        let composer = composers.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The production chat must expose its composer.")
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["Send"]
        let sendDeadline = Date().addingTimeInterval(45)
        while (!send.exists || !send.isEnabled) && Date() < sendDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        assertHittable(send, timeout: 5, message: "The production chat Send action must be available.")
        send.tap()

        let marker = app.staticTexts.matching(
            NSPredicate(format: "label == %@", prompt)
        ).firstMatch
        XCTAssertTrue(
            marker.waitForExistence(timeout: 20),
            "The exact clarification marker must appear in the transcript."
        )
        attachScreenshot(named: screenshotPrefix + "-sent")
    }

    @MainActor
    private func waitForClarificationCard(app: XCUIApplication) -> XCUIElement {
        let card = app.otherElements[clarificationCardIdentifier]
        XCTAssertTrue(card.waitForExistence(timeout: 30),
                      "The direct clarification card must appear for the exact marker.")
        return card
    }

    @MainActor
    private func assertSingleClarificationQuestion(in card: XCUIElement) {
        let question = card.staticTexts["Choose a bounded fixture answer"]
        assertHittable(
            question,
            timeout: 10,
            message: "Single clarification must expose its exact readable question."
        )
    }

    @MainActor
    private func waitForClarificationCardToClear(
        _ card: XCUIElement,
        screenshotName: String
    ) {
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: card
        )
        wait(for: [cleared], timeout: 30)
        XCTAssertFalse(card.exists, "The clarification card must clear after its response.")
        attachScreenshot(named: screenshotName)
    }

    @MainActor
    private func waitForNextTurnSuccess(
        prompt: String,
        acknowledgement: String,
        app: XCUIApplication
    ) {
        sendLivePrompt(prompt, app: app, screenshotPrefix: "slice3-clarification-follow-up")
        let uniqueAcknowledgement = app.staticTexts[acknowledgement]
        assertHittable(uniqueAcknowledgement, timeout: 45,
                       message: "The clarification follow-up must produce its unique terminal ACK.")
        waitForIdle(app: app)
        attachScreenshot(named: "slice3-clarification-follow-up-complete")
    }

    @MainActor
    private func waitForIdle(app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let stop = app.buttons["Stop response"]
            let send = app.buttons["Send"]
            if !stop.exists && send.exists {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(app.buttons["Stop response"].exists,
                       "The response must settle instead of leaving a running response.")
        XCTAssertTrue(app.buttons["Send"].exists,
                      "An idle chat must restore the production Send action.")
    }

    private func waitForPostLoginDestination(app: XCUIApplication, sessionsButtonLabel: String = "Sessions") {
        let sessions = app.buttons[sessionsButtonLabel]
        let chat = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'chat-detail:'")
        ).firstMatch
        let deadline = Date().addingTimeInterval(45)
        while !sessions.exists && !chat.exists && Date() < deadline {
            dismissKnownPasswordSavePrompt(app: app, timeout: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        // The password sheet can arrive after the authenticated destination has
        // already appeared in the hierarchy. Resolve that known overlay before
        // evaluating navigation hittability.
        dismissKnownPasswordSavePrompt(app: app)
        guard sessions.exists || chat.exists else {
            XCTFail("Successful login must expose \(sessionsButtonLabel) or a known restored chat detail.")
            return
        }
        guard chat.exists else {
            XCTAssertTrue(sessions.isHittable, "The \(sessionsButtonLabel) destination must be hittable after login.")
            return
        }

        let currentBackButton = app.buttons.matching(
            NSPredicate(format: "label == %@", "Back")
        ).firstMatch
        let legacyBackButton = app.navigationBars.buttons["BackButton"]
        let backButton = currentBackButton.exists ? currentBackButton : legacyBackButton
        XCTAssertTrue(
            backButton.waitForExistence(timeout: 5),
            "A restored chat detail must expose its current Back control or legacy NavigationStack BackButton."
        )
        let navigationDeadline = Date().addingTimeInterval(5)
        while !backButton.isHittable && Date() < navigationDeadline {
            dismissKnownPasswordSavePrompt(app: app, timeout: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        dismissKnownPasswordSavePrompt(app: app, timeout: 0)
        XCTAssertTrue(backButton.isHittable, "The restored chat BackButton must be hittable.")
        guard backButton.exists && backButton.isHittable else { return }
        backButton.tap()

        let leftChat = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: chat
        )
        wait(for: [leftChat], timeout: 10)
        XCTAssertFalse(chat.exists, "BackButton must return from the restored chat detail to the shell.")
        dismissKnownPasswordSavePrompt(app: app)
    }

    private func prepareNormalSignIn(app: XCUIApplication) {
        let personalize = app.navigationBars["Personalize"]
        if personalize.exists {
            dismissKnownPasswordSavePrompt(app: app)
            let skip = personalize.buttons["Skip"]
            XCTAssertTrue(skip.waitForExistence(timeout: 5) && skip.isHittable)
            skip.tap()
        }
        let welcome = app.buttons["Get Started"]
        if welcome.waitForExistence(timeout: 5) && welcome.isHittable { return }
        // An expired cookie legitimately restores the existing Connect page,
        // rather than the first onboarding page or an authenticated shell.
        if app.staticTexts["Your session expired. Sign in again."].exists,
           app.textFields["onboarding-server-url"].exists {
            return
        }

        // Only dismiss known, non-auth startup surfaces. An unknown alert must
        // remain visible so the UI smoke reports the actual regression.
        let actionFailure = app.alerts["Session Action Failed"]
        if actionFailure.waitForExistence(timeout: 2) {
            XCTAssertTrue(actionFailure.buttons["OK"].exists)
            actionFailure.buttons["OK"].tap()
        }
        dismissKnownPasswordSavePrompt(app: app)

        let settings = app.buttons["Settings"]
        if !settings.waitForExistence(timeout: 5) {
            let customBack = app.buttons.matching(NSPredicate(format: "label == %@", "Back")).firstMatch
            let back = customBack.exists ? customBack : app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable,
                          "The authenticated app must be navigable back to the shell.")
            back.tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 10) && settings.isHittable,
                      "The authenticated app must expose Settings.")
        settings.tap()

        let host = app.staticTexts[approvedLiveHost]
        XCTAssertTrue(host.waitForExistence(timeout: 15), "Settings must show the approved test server.")
        let signOut = app.buttons["Sign Out of This Server"]
        if !signOut.exists {
            let aboutAndStorage = app.staticTexts["About & Storage"]
            for _ in 0..<8 where !aboutAndStorage.isHittable {
                let scrollView = app.scrollViews.firstMatch
                XCTAssertTrue(scrollView.exists, "Settings must expose a bounded scroll path to About & Storage.")
                scrollView.swipeUp()
            }
            XCTAssertTrue(aboutAndStorage.waitForExistence(timeout: 5) && aboutAndStorage.isHittable)
            aboutAndStorage.tap()
        }
        let singleServerFootnote = app.staticTexts[
            "Signs out of the active server and returns to onboarding."
        ]
        for _ in 0..<8 where !singleServerFootnote.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(singleServerFootnote.waitForExistence(timeout: 5) && singleServerFootnote.isHittable,
                      "Refusing sign-out unless the disposable fixture is the only configured server.")
        for _ in 0..<8 where !signOut.isHittable {
            let scrollView = app.scrollViews.firstMatch
            XCTAssertTrue(scrollView.exists, "Settings must expose a bounded scroll path to sign out.")
            scrollView.swipeUp()
        }
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        XCTAssertTrue(signOut.isHittable)
        signOut.tap()

        let confirmation = app.alerts["Sign out of this server?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Sign Out"].tap()
        XCTAssertTrue(welcome.waitForExistence(timeout: 20), "Normal sign-out must return to Welcome.")
    }

    private func replacePublicText(_ field: XCUIElement, with value: String, app: XCUIApplication) {
        let existingValue = (field.value as? String) ?? ""
        if existingValue == value { return }
        field.tap()
        if !existingValue.isEmpty, existingValue != field.placeholderValue {
            field.press(forDuration: 1.0)
            let selectAll = app.menuItems["Select All"]
            XCTAssertTrue(selectAll.waitForExistence(timeout: 3), "Existing public URL text must be replaceable without appending.")
            selectAll.tap()
        }
        field.typeText(value)
    }

    private func dismissKnownPasswordSavePrompt(app: XCUIApplication, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for title in ["Save Password?", "Save This Password?"] {
                // The captured iOS hierarchy exposes a remote Sheet titled
                // "Save Password?". Scope Not Now to that exact known surface;
                // an unrelated alert or button must never be dismissed.
                for prompt in [app.sheets[title], app.alerts[title]] where prompt.exists {
                    let notNow = prompt.buttons["Not Now"]
                    let hittable = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "exists == true AND hittable == true"),
                        object: notNow
                    )
                    XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed,
                                   "The known password-save prompt must expose a hittable Not Now button.")
                    guard notNow.exists && notNow.isHittable else { return }
                    notNow.tap()
                    let dismissed = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "exists == false"), object: prompt
                    )
                    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                                   "Not Now must dismiss the known password-save prompt.")
                    return
                }
            }
            guard Date() < deadline else { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
    }

    private struct DisposableCredentials: Decodable {
        let username: String
        let password: String
    }

    private struct RelaunchCanonicalTranscript {
        let sessionID: String
        let rows: [[String: Any]]
    }

    @MainActor
    private final class RelaunchCanonicalObserver {
        private let origin: URL
        private let session: URLSession

        init(origin: URL, credentials: DisposableCredentials) async throws {
            self.origin = origin
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpAdditionalHeaders = [:]
            configuration.httpShouldSetCookies = true
            configuration.httpCookieAcceptPolicy = .always
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            session = URLSession(
                configuration: configuration,
                delegate: RelaunchRedirectGuard(origin: origin),
                delegateQueue: nil
            )

            let body = try JSONSerialization.data(withJSONObject: [
                "provider": "basic",
                "username": credentials.username,
                "password": credentials.password,
                "next": "",
            ])
            let (data, response) = try await request(path: "/auth/password-login", method: "POST", body: body)
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (200..<300).contains(response.statusCode), payload?["ok"] as? Bool == true else {
                throw NSError(
                    domain: "LongChatScrollUITests",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Private canonical observer authentication failed."]
                )
            }
        }

        func invalidate() {
            session.invalidateAndCancel()
        }

        func transcript(storedID: String) async throws -> RelaunchCanonicalTranscript {
            var components = URLComponents()
            components.path = "/api/sessions/\(storedID)/messages"
            components.queryItems = [
                URLQueryItem(name: "profile", value: "default"),
                URLQueryItem(name: "include_compacted", value: "true"),
                URLQueryItem(name: "order", value: "oldest"),
                URLQueryItem(name: "limit", value: "20"),
                URLQueryItem(name: "offset", value: "0"),
            ]
            guard let path = components.string else {
                throw NSError(domain: "LongChatScrollUITests", code: 7)
            }
            let (data, response) = try await request(path: path, method: "GET")
            guard (200..<300).contains(response.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = object["session_id"] as? String,
                  let rows = object["messages"] as? [[String: Any]] else {
                throw NSError(
                    domain: "LongChatScrollUITests",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Canonical transcript response was invalid."]
                )
            }
            return RelaunchCanonicalTranscript(sessionID: sessionID, rows: rows)
        }

        private func request(
            path: String,
            method: String,
            body: Data? = nil
        ) async throws -> (Data, HTTPURLResponse) {
            guard let url = URL(string: path, relativeTo: origin)?.absoluteURL,
                  url.scheme == origin.scheme,
                  url.host == origin.host,
                  url.port == origin.port else {
                throw NSError(domain: "LongChatScrollUITests", code: 9)
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.httpMethod = method
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: "LongChatScrollUITests", code: 10)
            }
            return (data, http)
        }
    }

    private final class RelaunchRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let origin: URL

        init(origin: URL) {
            self.origin = origin
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let destination = request.url,
                  destination.scheme == origin.scheme,
                  destination.host == origin.host,
                  destination.port == origin.port else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    private func readCredentials(at path: String) throws -> DisposableCredentials {
        let url = URL(fileURLWithPath: path)
        guard url.resolvingSymlinksInPath().path == path else {
            throw NSError(domain: "LongChatScrollUITests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected disposable credentials path."])
        }
        let data = try Data(contentsOf: url)
        let credentials = try JSONDecoder().decode(DisposableCredentials.self, from: data)
        guard !credentials.username.isEmpty, !credentials.password.isEmpty else {
            throw NSError(domain: "LongChatScrollUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Disposable credentials are incomplete."])
        }
        return credentials
    }

    private func pasteSecret(_ value: String, into field: XCUIElement, app: XCUIApplication) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]
        )
        field.tap()
        field.press(forDuration: 1.1)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "Password must be entered through the local paste action.")
        paste.tap()
        let allowPaste = app.alerts.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 2) {
            allowPaste.tap()
        }
    }

    private func pastePNG(_ data: Data, into field: XCUIElement, app: XCUIApplication) {
        UIPasteboard.general.setItems(
            [[UTType.png.identifier: data]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]
        )
        field.tap()
        field.press(forDuration: 1.1)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "The composer must expose the native Paste action for a PNG.")
        paste.tap()
        let allowPaste = app.alerts.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 2) {
            allowPaste.tap()
        }
    }

    private var knownPNGData: Data {
        // A visible synthetic tile makes screenshots useful evidence of actual
        // image rendering; a transparent single pixel only proves decoding.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
            .pngData { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                UIColor.systemOrange.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                context.fill(CGRect(x: 32, y: 32, width: 32, height: 32))
            }
    }

    private func clearPasteboard() {
        UIPasteboard.general.setItems([], options: [.localOnly: true])
    }

    private func addTiming(named name: String, startedAt: Date) {
        let milliseconds = Date().timeIntervalSince(startedAt) * 1_000
        let text = String(format: "%@ duration_ms=%.1f", name, milliseconds)
        let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachAccessibilitySnapshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(
            data: Data(app.debugDescription.utf8),
            uniformTypeIdentifier: "public.plain-text"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachPlainText(_ text: String, named name: String) {
        let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Opt-in smoothness battery. Each selector is a real XCTest selector so
    // -only-testing cannot silently report a zero-test success. The attachment
    // records wall and monotonic event times; it is not a presented-frame trace.
    private func smoothnessEnabled() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The smoothness fixture is Simulator-only.")
        #endif
    }

    private func smoothnessArguments(_ fixture: String, candidate: Bool,
                                     fullInline: Bool = true, richStream: Bool = false) -> [String] {
        var arguments = [fixture, "--chat-performance-app-wide-monitor",
                         "--chat-viewport-follow-latest-open", "--chat-viewport-diagnostic",
                         "--composer-test-fresh-draft"]
        arguments += ["--chat-windowed-eager", "--chat-windowed-rows=60"]
        if candidate { arguments.append("--chat-rich-native-code-text") }
        if fullInline { arguments.append("--chat-full-inline-code") }
        if richStream { arguments.append("--chat-performance-stream-rich-code") }
        return arguments
    }

    private func smoothnessEvent(_ name: String, into events: inout [[String: Any]]) {
        events.append(["event": name, "wall_time_utc": ISO8601DateFormatter().string(from: Date()),
                       "clock_domain": "mach_absolute_seconds",
                       "mach_absolute_seconds": CACurrentMediaTime()])
    }

    private func attachSmoothnessEvidence(_ app: XCUIApplication, scenario: String,
                                          events: [[String: Any]]) {
        let stop = app.buttons["chat-performance-app-wide-monitor-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10) && stop.isHittable)
        stop.tap()
        let report = app.staticTexts["chat-performance-app-wide-monitor-summary"]
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        XCTAssertTrue(report.label.contains("callback_gaps_over_100_ms="))
        attachPlainText(report.label, named: "smoothness-\(scenario)-callback-report")
        if let data = try? JSONSerialization.data(withJSONObject: ["scenario": scenario,
            "clock_domain": "mach_absolute_seconds", "events": events],
                                                  options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            attachPlainText(text, named: "smoothness-\(scenario)-events-json")
        } else {
            XCTFail("The smoothness event attachment must serialize.")
        }
    }

    // Keep the rich30 timeline even when a disclosure or a streaming phase fails
    // before the normal monitor stop. Hierarchy collection is deliberately only
    // on failure: it can perturb the callback measurements during motion.
    private func attachRich30StreamEvidence(_ app: XCUIApplication, events: [[String: Any]],
                                            phase: String, failed: Bool) {
        attachScreenshot(named: "smoothness-rich30-\(phase)-screen")
        if let data = try? JSONSerialization.data(withJSONObject: [
            "scenario": "rich30_stream", "phase": phase,
            "clock_domain": "mach_absolute_seconds", "events": events
        ], options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
            attachPlainText(text, named: phase == "complete"
                ? "smoothness-rich30_stream-events-json"
                : "smoothness-rich30-\(phase)-events-json")
        }
        if failed {
            attachAccessibilitySnapshot(named: "smoothness-rich30-\(phase)-failure-hierarchy", app: app)
        }
    }

    private func rich30Visible(_ element: XCUIElement, in scroll: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let visibleFrame = element.frame.intersection(scroll.frame)
        return !visibleFrame.isNull && visibleFrame.width > 0 && visibleFrame.height > 0
    }

    @MainActor
    func testOptInSmoothnessFourTallMotionBaseline() throws {
        try exerciseSmoothnessFourTallMotion(candidate: false, fullInline: false)
    }

    @MainActor
    func testOptInSmoothnessFourTallMotionCandidate() throws {
        try exerciseSmoothnessFourTallMotion(candidate: true, fullInline: false)
    }

    @MainActor
    func testOptInSmoothnessFourTallFullInlineBaseline() throws {
        try exerciseSmoothnessFourTallMotion(candidate: false, fullInline: true)
    }

    @MainActor
    func testOptInSmoothnessFourTallFullInlineCandidate() throws {
        try exerciseSmoothnessFourTallMotion(candidate: true, fullInline: true)
    }

    @MainActor
    func testOptInSmoothnessFourTallEagerArrowBaseline() throws {
        try exerciseSmoothnessFourTallMotion(candidate: true, fullInline: true, eagerArrowMotion: false)
    }

    @MainActor
    func testOptInSmoothnessFourTallEagerArrowCandidate() throws {
        try exerciseSmoothnessFourTallMotion(candidate: true, fullInline: true, eagerArrowMotion: true)
    }

    // Motion observation deliberately ends before the independent selection gate.
    // Both variants retain native rendering and the complete full-inline fixture.
    @MainActor
    func testOptInSmoothnessFourTallEagerArrowMotionOnlyBaseline() throws {
        try exerciseSmoothnessFourTallMotion(candidate: true, fullInline: true,
                                            eagerArrowMotion: false, motionOnly: true)
    }

    @MainActor
    func testOptInSmoothnessFourTallEagerArrowMotionOnlyCandidate() throws {
        try exerciseSmoothnessFourTallMotion(candidate: true, fullInline: true,
                                            eagerArrowMotion: true, motionOnly: true)
    }

    @MainActor
    private func exerciseSmoothnessFourTallMotion(candidate: Bool, fullInline: Bool,
                                                eagerArrowMotion: Bool? = nil,
                                                motionOnly: Bool = false) throws {
        try smoothnessEnabled()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = smoothnessArguments("--chat-performance-four-tall-lab", candidate: candidate,
                                                  fullInline: fullInline)
        if eagerArrowMotion == true { app.launchArguments.append("--chat-eager-arrow-motion") }
        var events: [[String: Any]] = []
        let initialFailureCount = testRun?.failureCount ?? 0
        defer {
            if eagerArrowMotion != nil && (testRun?.failureCount ?? 0) > initialFailureCount {
                attachScreenshot(named: "smoothness-four-tall-eager-arrow-failure")
                if let data = try? JSONSerialization.data(withJSONObject: events, options: [.sortedKeys]),
                   let value = String(data: data, encoding: .utf8) {
                    attachPlainText(value, named: "smoothness-four-tall-eager-arrow-failure-events")
                }
                attachAccessibilitySnapshot(named: "smoothness-four-tall-eager-arrow-failure-hierarchy", app: app)
            }
        }
        smoothnessEvent("process_launch_request", into: &events)
        app.launch()
        let scroll = app.scrollViews["chat-transcript-scroll"]
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "End of four-row mixed conversation.")).firstMatch
        let scenario = eagerArrowMotion != nil
            ? (motionOnly ? "four_tall_eager_arrow_motion_only" : "four_tall_eager_arrow_motion")
            : (fullInline ? "four_tall_full_inline" : "four_tall_motion")
        let eagerFinalRow = app.staticTexts["message-row:four-tall-message-3"]
        func validFrame(_ frame: CGRect) -> Bool {
            !frame.isNull && frame.origin.x.isFinite && frame.origin.y.isFinite
                && frame.width.isFinite && frame.height.isFinite
                && frame.maxX.isFinite && frame.maxY.isFinite
                && frame.width > 0 && frame.height > 0
        }
        func endpointGeometry() -> (row: CGRect, viewport: CGRect, valid: Bool, readable: Bool, far: Bool) {
            let rowExists = eagerFinalRow.exists
            let viewportExists = scroll.exists
            let row = rowExists ? eagerFinalRow.frame : .null
            let viewport = viewportExists ? scroll.frame : .null
            let valid = rowExists && viewportExists && validFrame(row) && validFrame(viewport)
            // The AX label covers the entire giant row. Its trailing edge tracks
            // the terminal paragraph; a hittable slice of code does not.
            let readable = valid && row.maxX > viewport.minX && row.minX < viewport.maxX
                && row.maxY <= viewport.maxY && row.maxY >= viewport.minY + 120
            let far = valid && row.maxY - viewport.maxY >= viewport.height
            return (row, viewport, valid, readable, far)
        }
        func checkEagerEndpoint(_ phase: String, farRequired: Bool) -> Bool {
            let geometry = endpointGeometry()
            smoothnessEvent("\(phase)_endpoint_geometry", into: &events)
            events[events.count - 1]["row_frame"] = String(describing: geometry.row)
            events[events.count - 1]["viewport_frame"] = String(describing: geometry.viewport)
            events[events.count - 1]["frames_valid"] = geometry.valid
            if geometry.valid {
                events[events.count - 1]["row_end_below_viewport_points"] = geometry.row.maxY - geometry.viewport.maxY
            }
            events[events.count - 1]["endpoint_readable"] = geometry.readable
            events[events.count - 1]["endpoint_far"] = geometry.far
            let terminalLabelPresent = tail.exists
            events[events.count - 1]["terminal_label_present"] = terminalLabelPresent
            let passed = terminalLabelPresent && (farRequired ? geometry.far : geometry.readable)
            guard passed else {
                smoothnessEvent("\(phase)_endpoint_failure", into: &events)
                attachScreenshot(named: "smoothness-four-tall-eager-arrow-\(phase)-failure-screen")
                if let data = try? JSONSerialization.data(withJSONObject: events, options: [.sortedKeys]),
                   let value = String(data: data, encoding: .utf8) {
                    attachPlainText(value, named: "smoothness-four-tall-eager-arrow-\(phase)-failure-events")
                }
                attachAccessibilitySnapshot(named: "smoothness-four-tall-eager-arrow-\(phase)-failure-hierarchy", app: app)
                XCTFail(farRequired
                        ? "The row endpoint must be at least one viewport beyond the mounted window before the arrow tap."
                        : "The terminal paragraph must be within the transcript viewport at \(phase).")
                return false
            }
            return true
        }
        func waitForReadableEndpoint(timeout: TimeInterval) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                endpointGeometry().readable
            }, object: eagerFinalRow)
            _ = XCTWaiter.wait(for: [ready], timeout: timeout)
        }
        XCTAssertTrue(scroll.waitForExistence(timeout: 25))
        smoothnessEvent("transcript_constructed", into: &events)
        if eagerArrowMotion != nil {
            waitForReadableEndpoint(timeout: 30)
            guard checkEagerEndpoint("cold", farRequired: false) else { return }
        } else {
            assertHittable(tail, timeout: 30, message: "Four-tall cold tail must be readable.")
        }
        if fullInline {
            let finalRow = app.staticTexts["message-row:four-tall-message-3"]
            XCTAssertTrue(finalRow.waitForExistence(timeout: 10),
                          "The final assistant row must expose its real accessibility label.")
            let expected = String(repeating: "let value = Array(0..<1_000).reduce(0, +)\n", count: 320)
                + "\nlet fourTallFinalMarker = \"SEMREH_FOUR_TALL_CODE_END\""
            let label = finalRow.label
            XCTAssertEqual(label.components(separatedBy: "```swift\n").count, 2,
                           "The final row must have exactly one fenced Swift block in its accessibility label.")
            let openingFence = try XCTUnwrap(label.range(of: "```swift\n"))
            let afterOpeningFence = label[openingFence.upperBound...]
            let closingFence = try XCTUnwrap(afterOpeningFence.range(of: "\n```"))
            XCTAssertEqual(String(afterOpeningFence[..<closingFence.lowerBound]), expected,
                           "The real row accessibility label must contain the complete exact multiline Swift source.")
            XCTAssertFalse(finalRow.buttons.matching(NSPredicate(
                format: "identifier == %@ OR label BEGINSWITH %@", "view-full-code", "View full code ("
            )).firstMatch.exists, "Full-inline code must not show the 32-line View full code preview affordance.")
            if candidate {
                let codeLeaves = finalRow.textViews.matching(identifier: "native-inline-code-text")
                let code = codeLeaves.element(boundBy: 0)
                XCTAssertTrue(code.waitForExistence(timeout: 10),
                              "The native full-inline code view must be exposed to accessibility.")
                XCTAssertEqual(codeLeaves.count, 1, "The final code block must have one native accessibility leaf.")
                let returnedValue = try XCTUnwrap(code.value as? String)
                attachPlainText(returnedValue, named: "smoothness-four-tall-full-inline-native-code-ax-value")
                // The formatter renders each empty source line as one ASCII space.
                let expectedDisplayedValue = expected.components(separatedBy: "\n")
                    .map { $0.isEmpty ? " " : $0 }
                    .joined(separator: "\n")
                XCTAssertEqual(returnedValue, expectedDisplayedValue,
                               "The native code leaf must expose the complete formatted display text.")
            }
        }
        // launch-to-readable includes the AX observer queries above; only the
        // drag/arrow events below bracket motion, so it is not pure opening latency.
        smoothnessEvent("first_readable_tail", into: &events)
        attachScreenshot(named: "smoothness-four-tall-before-motion")
        smoothnessEvent("drag_begin", into: &events)
        scroll.swipeDown()
        scroll.swipeDown()
        let arrow = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
        if eagerArrowMotion != nil {
            guard checkEagerEndpoint("before-arrow", farRequired: true) else { return }
        }
        smoothnessEvent("drag_end_arrow_visible", into: &events)
        attachScreenshot(named: "smoothness-four-tall-away")
        smoothnessEvent("arrow_tap_request", into: &events)
        arrow.tap()
        if eagerArrowMotion != nil {
            waitForReadableEndpoint(timeout: 20)
            guard checkEagerEndpoint("after-arrow", farRequired: false) else { return }
        } else {
            assertHittable(tail, timeout: 20, message: "One arrow tap must reach the four-tall tail.")
        }
        if let eagerArrowMotion {
            let decision = app.staticTexts["chat-eager-arrow-motion-decision"]
            XCTAssertTrue(decision.waitForExistence(timeout: 5), "The DEBUG motion decision must be observable.")
            let settled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS %@", "state=settled"), object: decision
            )
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                           "Arrival must be confirmed by the current bottom-geometry token.")
            XCTAssertTrue(decision.label.contains("requested=\(eagerArrowMotion)"), decision.label)
            XCTAssertTrue(decision.label.contains("eligible=\(eagerArrowMotion)"), decision.label)
            XCTAssertTrue(decision.label.contains("sameMountedWindow=true"), decision.label)
            XCTAssertTrue(decision.label.contains("nearMotionBand=false"), decision.label)
            XCTAssertTrue(decision.label.contains("animated=true") || decision.label.contains("animated=false"),
                          decision.label)
            if eagerArrowMotion {
                XCTAssertTrue(decision.label.contains("animated=true"), decision.label)
            }
            XCTAssertTrue(decision.label.contains("reason=\(eagerArrowMotion ? "animate" : "flag_off")"), decision.label)
            attachPlainText(decision.label, named: "smoothness-four-tall-eager-arrow-decision")
            let finalRow = app.staticTexts["message-row:four-tall-message-3"]
            XCTAssertTrue(finalRow.exists)
            XCTAssertTrue(finalRow.label.contains("SEMREH_FOUR_TALL_CODE_END"),
                          "Arrow settlement must preserve the complete final source row.")
        }
        smoothnessEvent("arrow_tail_readable", into: &events)
        attachScreenshot(named: "smoothness-four-tall-tail")
        smoothnessEvent("motion_scored_interval_end", into: &events)
        if eagerArrowMotion != nil && !motionOnly {
            // The arrow phase is already settled. Stop publishes an undismissable,
            // selectable report over the transcript, so selection MUST precede it.
            // Aggregate callbacks include this separate correctness leg; only the
            // completed scroll/arrow phases describe motion in this combined test.
            XCTAssertFalse(app.staticTexts["chat-performance-app-wide-monitor-summary"].exists,
                           "The diagnostic report must not occlude the real message gesture.")
            smoothnessEvent("selection_correctness_begin", into: &events)
            func checkSelection(_ passed: Bool, phase: String, message: String) -> Bool {
                guard !passed else { return true }
                attachScreenshot(named: "smoothness-four-tall-selection-\(phase)-failure-screen")
                attachAccessibilitySnapshot(named: "smoothness-four-tall-selection-\(phase)-failure-hierarchy", app: app)
                XCTFail(message)
                return false
            }
            let tailLeaves = app.staticTexts.matching(NSPredicate(
                format: "label == %@", "End of four-row mixed conversation."
            ))
            guard checkSelection(tailLeaves.count == 1, phase: "unique-leaf",
                                 message: "The exact terminal paragraph must be a unique accessibility leaf.") else { return }
            let tailLeaf = tailLeaves.element(boundBy: 0)
            guard checkSelection(tailLeaf.label == "End of four-row mixed conversation.", phase: "leaf-label",
                                 message: "The selection leaf must retain the exact terminal paragraph.") else { return }
            let leafFrame = tailLeaf.frame
            let rowFrame = eagerFinalRow.frame
            let viewportFrame = scroll.frame
            let windowFrame = app.frame
            smoothnessEvent("selection_pre_press_geometry", into: &events)
            events[events.count - 1]["leaf_frame"] = String(describing: leafFrame)
            events[events.count - 1]["row_frame"] = String(describing: rowFrame)
            events[events.count - 1]["viewport_frame"] = String(describing: viewportFrame)
            events[events.count - 1]["window_frame"] = String(describing: windowFrame)
            attachPlainText(String(describing: events[events.count - 1]),
                            named: "smoothness-four-tall-selection-pre-press-geometry")
            guard checkSelection(validFrame(leafFrame) && validFrame(rowFrame)
                                 && validFrame(viewportFrame) && validFrame(windowFrame),
                                 phase: "valid-geometry",
                                 message: "Selection requires finite positive leaf, row, viewport, and app-window bounds.") else { return }
            guard checkSelection(leafFrame.height < 80, phase: "small-leaf",
                                 message: "Selection must target the small terminal paragraph, not the giant row.") else { return }
            guard checkSelection(rowFrame.contains(leafFrame), phase: "final-row",
                                 message: "The terminal paragraph must belong to the final assistant row.") else { return }
            guard checkSelection(viewportFrame.contains(leafFrame) && windowFrame.contains(leafFrame),
                                 phase: "visible-leaf",
                                 message: "The complete terminal paragraph must be within the transcript viewport and app window.") else { return }
            let pressPoint = CGPoint(x: leafFrame.midX, y: leafFrame.midY)
            let innerLeaf = leafFrame.insetBy(dx: leafFrame.width / 4, dy: leafFrame.height / 4)
            guard checkSelection(validFrame(innerLeaf) && innerLeaf.contains(pressPoint),
                                 phase: "press-point",
                                 message: "The measured press point must be clearly inside the visible terminal paragraph.") else { return }
            let localOffset = CGVector(dx: pressPoint.x - windowFrame.minX,
                                       dy: pressPoint.y - windowFrame.minY)
            events[events.count - 1]["press_point"] = String(describing: pressPoint)
            events[events.count - 1]["app_local_offset"] = String(describing: localOffset)
            attachPlainText(String(describing: events[events.count - 1]),
                            named: "smoothness-four-tall-selection-pre-press-coordinate")
            attachScreenshot(named: "smoothness-four-tall-selection-before-press")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(localOffset).press(forDuration: 1)
            guard checkSelection(app.buttons["Select Text"].waitForExistence(timeout: 3),
                                 phase: "select-text-menu",
                                 message: "The real terminal-paragraph press must offer Select Text.") else { return }
            app.buttons["Select Text"].tap()
            let selection = app.textViews["selectable-response-text"]
            guard checkSelection(selection.waitForExistence(timeout: 3), phase: "selection-view",
                                 message: "Select Text must open the selectable full response.") else { return }
            let source = selection.value as? String ?? ""
            let expectedCode = String(repeating: "let value = Array(0..<1_000).reduce(0, +)\n", count: 320)
                + "\nlet fourTallFinalMarker = \"SEMREH_FOUR_TALL_CODE_END\""
            guard checkSelection(source.contains(expectedCode), phase: "full-code-source",
                                 message: "Select Text must retain the exact full code source.") else { return }
            guard checkSelection(source.contains("End of four-row mixed conversation."),
                                 phase: "terminal-source",
                                 message: "Select Text must retain the terminal paragraph.") else { return }
            attachPlainText(source, named: "smoothness-four-tall-eager-arrow-selected-source")
            let done = app.buttons["Done"]
            guard checkSelection(done.exists && done.isHittable, phase: "dismiss-selection",
                                 message: "The real selection sheet must offer Done.") else { return }
            done.tap()
            guard checkSelection(selection.waitForNonExistence(timeout: 3), phase: "selection-dismissed",
                                 message: "Done must dismiss selection before publishing the report.") else { return }
            smoothnessEvent("selection_correctness_complete", into: &events)
        }
        attachSmoothnessEvidence(app, scenario: scenario, events: events)
    }

    @MainActor
    func testOptInSmoothnessRich30StreamBaseline() throws {
        try exerciseSmoothnessRich30Stream(candidate: false)
    }

    @MainActor
    func testOptInSmoothnessRich30StreamCandidate() throws {
        try exerciseSmoothnessRich30Stream(candidate: true)
    }

    @MainActor
    private func exerciseSmoothnessRich30Stream(candidate: Bool) throws {
        try smoothnessEnabled()
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = smoothnessArguments("--chat-performance-rich30-lab", candidate: candidate,
                                                  richStream: true)
        var events: [[String: Any]] = []
        var phase = "launch"
        var recordedFailure = false
        let initialFailureCount = testRun?.failureCount ?? 0
        func check(_ condition: Bool, _ message: String) -> Bool {
            guard condition else {
                recordedFailure = true
                smoothnessEvent("failure_\(phase)", into: &events)
                attachRich30StreamEvidence(app, events: events, phase: phase, failed: true)
                XCTFail(message)
                return false
            }
            return true
        }
        defer {
            if !recordedFailure {
                attachRich30StreamEvidence(app, events: events, phase: phase,
                                           failed: (testRun?.failureCount ?? 0) > initialFailureCount)
            }
        }
        smoothnessEvent("process_launch_request", into: &events)
        app.launch()
        let scroll = app.scrollViews["chat-transcript-scroll"]
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", rich30Marker)).firstMatch
        guard check(scroll.waitForExistence(timeout: 25), "Rich30 transcript must mount.") else { return }
        smoothnessEvent("transcript_constructed", into: &events)
        let tailReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: tail
        )
        guard check(XCTWaiter.wait(for: [tailReady], timeout: 35) == .completed,
                    "Rich30 cold tail must be readable.") else { return }
        let finalCodeLine = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "SEMREH_RICH30_CODE_END")).firstMatch
        guard check(finalCodeLine.waitForExistence(timeout: 10),
                    "Full-inline late code must be mounted in both variants.") else { return }
        smoothnessEvent("first_readable_tail", into: &events)
        phase = "reach-group-30-thinking"
        attachScreenshot(named: "smoothness-rich30-first-readable-tail")
        let groupUser = app.staticTexts["message-row:rich30-message-58"]
        let groupAssistant = app.staticTexts["message-row:rich30-message-59"]
        guard check(groupUser.waitForExistence(timeout: 10) && groupAssistant.waitForExistence(timeout: 10),
                    "The stable group-30 user and assistant rows must be mounted.") else { return }
        func group30Button(containing label: String) -> XCUIElement? {
            scroll.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", label))
                .allElementsBoundByIndex.last { button in
                    button.exists && button.frame.minY >= groupUser.frame.maxY - 8
                        && button.frame.maxY <= groupAssistant.frame.minY + 8
                }
        }
        let preparationDeadline = Date().addingTimeInterval(65)
        var thinking: XCUIElement?
        for gesture in 0..<40 {
            let current = group30Button(containing: "Thinking")
            if let current, rich30Visible(current, in: scroll), current.isHittable {
                thinking = current
                break
            }
            guard Date() < preparationDeadline else { break }
            smoothnessEvent("reasoning_scroll_\(gesture + 1)", into: &events)
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.28))
                .press(forDuration: 0.05,
                       thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.72)))
        }
        guard check(thinking != nil, "Group-30 Thinking was not visible after 40 bounded upward gestures (65 s).") else { return }
        smoothnessEvent("reasoning_disclosure_visible", into: &events)
        phase = "expand-group-30-thinking"
        guard let thinking else { return }
        thinking.tap()
        let reasoningBody = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "Group 30: check the bounded window")).firstMatch
        guard check(reasoningBody.waitForExistence(timeout: 10),
                    "Expanded group-30 reasoning must expose its real visible body.") else { return }
        for _ in 0..<4 where !rich30Visible(reasoningBody, in: scroll) {
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.70))
                .press(forDuration: 0.05,
                       thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.42)))
        }
        guard check(rich30Visible(reasoningBody, in: scroll),
                    "Expanded group-30 reasoning body must enter the viewport.") else { return }
        smoothnessEvent("reasoning_expanded", into: &events)
        attachScreenshot(named: "smoothness-rich30-expanded-reasoning")
        phase = "reach-group-30-tool"
        var tool: XCUIElement?
        let toolDeadline = Date().addingTimeInterval(25)
        for gesture in 0..<16 {
            let current = group30Button(containing: "Read file")
            if let current, rich30Visible(current, in: scroll), current.isHittable {
                tool = current
                break
            }
            guard Date() < toolDeadline else { break }
            smoothnessEvent("tool_scroll_\(gesture + 1)", into: &events)
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.72))
                .press(forDuration: 0.05,
                       thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.28)))
        }
        guard check(tool != nil, "Group-30 Read file was not visible after 16 bounded downward gestures (25 s).") else { return }
        smoothnessEvent("tool_disclosure_visible", into: &events)
        phase = "expand-group-30-tool"
        guard let tool else { return }
        tool.tap()
        let toolBody = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "fixtures/rich30-group-30.md")).firstMatch
        guard check(toolBody.waitForExistence(timeout: 10),
                    "Expanded group-30 tool must expose its real visible argument body.") else { return }
        for _ in 0..<4 where !rich30Visible(toolBody, in: scroll) {
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.70))
                .press(forDuration: 0.05,
                       thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.42)))
        }
        guard check(rich30Visible(toolBody, in: scroll),
                    "Expanded group-30 tool argument body must enter the viewport.") else { return }
        smoothnessEvent("tool_body_expanded", into: &events)
        attachScreenshot(named: "smoothness-rich30-expanded-tool")
        phase = "return-from-disclosures"
        let returnFromReasoning = app.buttons[scrollToLatestLabel]
        guard check(returnFromReasoning.waitForExistence(timeout: 10) && returnFromReasoning.isHittable,
                    "The return-to-latest arrow must be tappable after expanding group 30.") else { return }
        returnFromReasoning.tap()
        guard check(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: tail
        )], timeout: 20) == .completed,
                    "The expanded rich transcript must return to the tail with one tap.") else { return }
        smoothnessEvent("return_from_disclosures_readable", into: &events)
        phase = "stream-open-fence"
        let stream = app.buttons["rich30-stream-turn"]
        guard check(stream.waitForExistence(timeout: 10) && stream.isHittable,
                    "The rich streaming button must be tappable.") else { return }
        smoothnessEvent("stream_follow_request", into: &events)
        stream.tap()
        let firstStreamRow = app.staticTexts["message-row:perf-stream-message-1-assistant"]
        let openFenceLine = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "let lineOne =")).firstMatch
        let firstFinalCode = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "SEMREH_STREAM_CODE_END_1")).firstMatch
        guard check(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "let lineOne ="), object: firstStreamRow
        )], timeout: 10) == .completed
                    && firstStreamRow.label.contains("```swift\nlet lineOne =")
                    && !firstStreamRow.label.contains("SEMREH_STREAM_CODE_END_1")
                    && openFenceLine.exists && !firstFinalCode.exists,
                    "The first open code fence must be observed before its completed source line; XCTest may have consumed the intermediate chunks.") else { return }
        smoothnessEvent("stream_open_code_mounted", into: &events)
        attachScreenshot(named: "smoothness-rich30-open-code")
        phase = "stream-follow-tail"
        let streamed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "SEMREH_MULTI_CHAT_STREAM_1")).firstMatch
        guard check(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: streamed
        )], timeout: 20) == .completed, "Following stream must reach the tail.") else { return }
        guard check(firstFinalCode.exists, "Completed streamed code must retain its final source line.") else { return }
        smoothnessEvent("stream_follow_tail", into: &events)
        attachScreenshot(named: "smoothness-rich30-followed-stream-tail")
        phase = "parked-reader"
        scroll.swipeDown()
        scroll.swipeDown()
        let arrow = app.buttons[scrollToLatestLabel]
        guard check(arrow.waitForExistence(timeout: 10) && arrow.isHittable,
                    "A parked reader must have a tappable return arrow.") else { return }
        let parkedAnchor = groupAssistant
        guard check(parkedAnchor.exists && rich30Visible(parkedAnchor, in: scroll),
                    "Parked reading needs the visible stable group-30 assistant row.") else { return }
        let parkedAnchorY = parkedAnchor.frame.minY
        smoothnessEvent("parked_older", into: &events)
        attachScreenshot(named: "smoothness-rich30-parked-before-stream")
        guard check(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true"), object: stream
            )], timeout: 5) == .completed,
                    "The first streamed turn must finish before the parked stream starts.") else { return }
        phase = "stream-while-parked"
        smoothnessEvent("stream_parked_request", into: &events)
        stream.tap()
        let secondStreamRow = app.staticTexts["message-row:perf-stream-message-2-assistant"]
        let secondFinalCode = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "SEMREH_STREAM_CODE_END_2")).firstMatch
        guard check(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "let lineOne ="), object: secondStreamRow
        )], timeout: 10) == .completed
                    && secondStreamRow.label.contains("```swift\nlet lineOne =")
                    && !secondStreamRow.label.contains("SEMREH_STREAM_CODE_END_2")
                    && !secondFinalCode.exists,
                    "The parked second stream must expose an intermediate open fence before completion; XCTest may have consumed the chunks.") else { return }
        guard check(arrow.exists && parkedAnchor.exists && rich30Visible(parkedAnchor, in: scroll)
                    && abs(parkedAnchor.frame.minY - parkedAnchorY) <= 8,
                    "A parked reader must keep the same visible group-30 row and position during appends.") else { return }
        smoothnessEvent("stream_parked_open_code_observed", into: &events)
        guard check(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: stream
        )], timeout: 10) == .completed,
                    "The parked second stream must complete.") else { return }
        guard check(arrow.exists && parkedAnchor.exists && rich30Visible(parkedAnchor, in: scroll)
                    && abs(parkedAnchor.frame.minY - parkedAnchorY) <= 8,
                    "A parked reader must retain the same visible row position after completion.") else { return }
        smoothnessEvent("stream_parked_observed", into: &events)
        attachScreenshot(named: "smoothness-rich30-parked-after-stream")
        phase = "return-latest"
        smoothnessEvent("return_latest_tap_request", into: &events)
        arrow.tap()
        let secondStream = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "SEMREH_MULTI_CHAT_STREAM_2"
        )).firstMatch
        guard check(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: secondStream
        )], timeout: 20) == .completed,
                    "One tap must return to the second turn streamed while parked.") else { return }
        guard check(secondFinalCode.exists, "Completed parked stream must mount full source content.") else { return }
        smoothnessEvent("return_latest_readable", into: &events)
        attachScreenshot(named: "smoothness-rich30-stream-tail")
        phase = "monitor-report"
        let stop = app.buttons["chat-performance-app-wide-monitor-stop"]
        guard check(stop.waitForExistence(timeout: 10) && stop.isHittable,
                    "The rich30 callback monitor stop must be tappable.") else { return }
        stop.tap()
        let report = app.staticTexts["chat-performance-app-wide-monitor-summary"]
        guard check(report.waitForExistence(timeout: 10)
                    && report.label.contains("callback_gaps_over_100_ms="),
                    "The rich30 callback monitor must publish its gap report.") else { return }
        attachPlainText(report.label, named: "smoothness-rich30_stream-callback-report")
        phase = "complete"
    }

    @MainActor
    func testOptInSmoothnessRich30OpenBackBaseline() throws {
        try exerciseSmoothnessRich30OpenBack(candidate: false)
    }

    @MainActor
    func testOptInSmoothnessRich30OpenBackCandidate() throws {
        try exerciseSmoothnessRich30OpenBack(candidate: true)
    }

    @MainActor
    func testR24Window12RichHistoryJourney() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-rich30-back-lab", "--composer-test-fresh-draft",
                               "--chat-windowed-eager", "--chat-windowed-rows=12",
                               "--chat-rich-native-code-text", "--chat-full-inline-code",
                               "--chat-viewport-follow-latest-open"]
        let scroll = app.scrollViews["chat-transcript-scroll"]
        let open = app.buttons["Open rich30 chat"].firstMatch
        let older = app.buttons["windowed-page-older"]
        let arrow = app.buttons[scrollToLatestLabel]
        var phase = "open"
        var readback: [String] = []
        func check(_ condition: Bool, _ message: String) -> Bool {
            guard condition else {
                // Capture before XCTFail: continueAfterFailure=false can abort immediately.
                attachScreenshot(named: "r24-\(phase)-failure")
                attachAccessibilitySnapshot(named: "r24-\(phase)-failure-hierarchy", app: app)
                attachPlainText(readback.joined(separator: "\n"), named: "r24-failure-readback")
                XCTFail(message)
                return false
            }
            return true
        }
        func wait(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval = 15) -> Bool {
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: predicate), object: element
            )], timeout: timeout) == .completed
        }
        // One immutable application snapshot per boundary: window membership,
        // labels, leaf values and production shell geometry share the same instant.
        func boundary(_ name: String) throws -> (rows: [XCUIElementSnapshot], nodes: [XCUIElementSnapshot], readable: CGRect) {
            phase = name
            let root: XCUIElementSnapshot
            do { root = try app.snapshot() }
            catch {
                _ = check(false, "Unable to capture \(name): \(error)")
                throw error
            }
            var nodes: [XCUIElementSnapshot] = []
            func visit(_ node: XCUIElementSnapshot) {
                nodes.append(node)
                node.children.forEach(visit)
            }
            visit(root)
            let transcript = nodes.first { $0.identifier == "chat-transcript-scroll" }?.frame ?? .zero
            let back = nodes.first { $0.elementType == .button && $0.label == "Back" }?.frame ?? .zero
            let composer = nodes.first { $0.identifier == "chat-composer-input" }?.frame ?? .zero
            // ChatView.chatNavigationBar: Back is inset 4pt into a 96pt header;
            // its readability backdrop extends another 24pt below that header.
            // Exclude composer input plus its surrounding top padding conservatively.
            let top = max(transcript.minY, back.minY - 4 + 96 + 24)
            let bottom = min(transcript.maxY, composer.minY - 12)
            let readable = CGRect(x: transcript.minX, y: top, width: transcript.width,
                                  height: max(0, bottom - top))
            let rows = nodes.filter { $0.elementType == .staticText && $0.identifier.hasPrefix("message-row:") }
            readback.append("\(name): ids=\(rows.map(\.identifier)) count=\(rows.count) transcript=\(transcript) back=\(back) composer=\(composer) readable=\(readable)")
            for row in rows where row.frame.intersects(readable) {
                readback.append("  readable \(row.identifier) frame=\(row.frame)")
            }
            attachPlainText(readback.suffix(rows.count + 1).joined(separator: "\n"), named: "r24-\(name)-boundary")
            _ = check(back.height > 0 && composer.height > 0 && readable.height > 0,
                      "Production header/composer must define a nonempty readable region.")
            _ = check(!rows.isEmpty && rows.count <= 12, "Every boundary must mount 1...12 display rows.")
            return (rows, nodes, readable)
        }
        func readableRow(_ rows: [XCUIElementSnapshot], in region: CGRect) -> XCUIElementSnapshot? {
            rows.filter { $0.frame.intersection(region).height > 20 && $0.frame.intersection(region).width > 0 }
                .sorted { $0.frame.minY < $1.frame.minY }.first
        }
        func numbers(_ rows: [XCUIElementSnapshot]) -> Set<Int> {
            Set(rows.compactMap { Int($0.identifier.replacingOccurrences(of: "message-row:rich30-message-", with: "")) })
        }
        func dragOlder() {
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.30))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.76)))
        }
        defer { attachPlainText(readback.joined(separator: "\n"), named: "r24-coverage-and-readback") }
        app.launch()
        guard check(open.waitForExistence(timeout: 25) && open.isHittable, "The genuine rich30 list entry must be reachable.") else { return }
        open.tap()
        guard check(scroll.waitForExistence(timeout: 25), "Open must mount the transcript.") else { return }
        let tail = app.staticTexts.matching(NSPredicate(format: "label == %@", "Rich group 30 complete. SEMREH_RICH30_END")).firstMatch
        guard check(wait(tail, "exists == true AND hittable == true", timeout: 35), "The full terminal paragraph must be readable.") else { return }
        let cold = try boundary("cold-tail")
        guard check(numbers(cold.rows) == Set(48..<60), "Opening must mount the actual final 12 of 60 rows.") else { return }
        guard let finalRow = cold.rows.first(where: { $0.identifier == "message-row:rich30-message-59" }) else {
            _ = check(false, "Final rich row missing."); return
        }
        let expectedFinalCode = String(repeating: "let row29 = records.filter { $0.group == 29 }.map { $0.id }\n", count: 88)
            + "let richGroupFinalSourceLine30 = \"SEMREH_RICH30_CODE_END\""
        let finalLabel = app.staticTexts[finalRow.identifier].label
        guard check(finalLabel.contains("```swift\n" + expectedFinalCode + "\n```"), "Final row must retain all 88 code lines and its terminal source marker.") else { return }
        let finalCode = app.staticTexts[finalRow.identifier].textViews["native-inline-code-text"].firstMatch
        guard check((finalCode.value as? String) == expectedFinalCode,
                    "Full native inline code must expose the exact terminal block, without preview truncation.") else { return }
        guard check(!cold.nodes.contains { $0.identifier == "view-full-code" || $0.label.hasPrefix("View full code (") },
                    "The full-inline journey must not substitute collapsed code.") else { return }
        attachScreenshot(named: "r24-before-real-drag")
        dragOlder()
        let moved = try boundary("after-real-drag")
        guard check(moved.rows.contains { row in
            cold.rows.contains { $0.identifier == row.identifier && abs($0.frame.minY - row.frame.minY) > 20 }
        }, "A real drag must move mounted content by more than 20pt.") else { return }
        attachScreenshot(named: "r24-after-real-drag")

        // Mirrors the existing policy, not a hidden state injection:
        // debugMoveLoadedWindow uses overlap=max(1, limit/2); older() retains
        // min(overlap,current.count,limit-1), then clips only the lower edge.
        let limit = 12
        let total = 60
        let overlap = max(1, limit / 2)
        let maximumReplacements = (total - limit + (limit - overlap) - 1) / (limit - overlap)
        var expected = (total - limit)..<total
        var covered = numbers(cold.rows)
        var groups = Set<Int>()
        func collectGroups(_ rows: [XCUIElementSnapshot], nodes: [XCUIElementSnapshot]) {
            for number in numbers(rows) where number % 2 == 1 {
                if nodes.contains(where: { $0.elementType == .staticText && $0.label.hasPrefix("Rich group \(number / 2 + 1) complete.") }) {
                    groups.insert(number / 2 + 1)
                }
            }
        }
        collectGroups(cold.rows, nodes: cold.nodes)
        for page in 1...maximumReplacements {
            phase = "page-\(page)"
            guard check(older.exists && older.isHittable, "Existing older-page lab control must be reachable.") else { return }
            let retained = min(overlap, expected.count, limit - 1)
            let end = expected.lowerBound + retained
            expected = max(0, end - limit)..<end
            older.tap()
            let newFirst = app.staticTexts["message-row:rich30-message-\(expected.lowerBound)"]
            guard check(newFirst.waitForExistence(timeout: 15), "Replacement must expose its expected first row.") else { return }
            let pageState = try boundary(phase)
            guard check(numbers(pageState.rows) == Set(expected), "Actual replacement IDs must match the bounded policy range \(expected).") else { return }
            guard check(readableRow(pageState.rows, in: pageState.readable) != nil, "Completed replacement must leave readable transcript content.") else { return }
            covered.formUnion(numbers(pageState.rows))
            collectGroups(pageState.rows, nodes: pageState.nodes)
        }
        guard check(covered == Set(0..<total) && groups == Set(1...30), "All 60 distinct display rows and all 30 complete rich groups must be observed.") else { return }
        readback.append("coverage rows=\(covered.sorted()) groups=\(groups.sorted()) replacements=\(maximumReplacements); oldest=\(expected); no partial page exists for 60 rows / half-step 6")
        older.tap()
        let oldest = try boundary("oldest-no-op")
        guard check(numbers(oldest.rows) == Set(0..<12), "Paging beyond oldest must retain the first window.") else { return }
        attachScreenshot(named: "r24-oldest-window")

        // Reach an existing long-code toolbar through real scrolling. Group 1
        // has 40 ordinary lines plus three deliberately long wrapping lines.
        let firstAssistant = app.staticTexts["message-row:rich30-message-1"]
        let enable = firstAssistant.buttons["Enable code line wrapping"]
        let disable = firstAssistant.buttons["Disable code line wrapping"]
        phase = "reach-long-code"
        // Wrapping is a real persisted preference: the same full fixture can
        // place this toolbar ~15,700 or ~22,300pt away. Bound traversal by the
        // measured distance, not an assumed unwrapped height. No state reset.
        let toolbar = enable.exists ? enable : disable
        guard check(toolbar.exists, "Group 1 must expose its real wrapping control.") else { return }
        let viewportFrame = scroll.frame
        let initialDistance = oldest.readable.midY - toolbar.frame.midY
        guard check(initialDistance.isFinite && viewportFrame.height.isFinite && viewportFrame.height > 0,
                    "Toolbar traversal needs finite measured distance and viewport height.") else { return }
        let projectedFlings = min(44, abs(initialDistance) / max(viewportFrame.height * 0.75, 1))
        let seekBudget = min(48, max(24, Int(ceil(projectedFlings)) + 4))
        readback.append("wrap-seek-budget=\(seekBudget) initialDistance=\(initialDistance) viewport=\(viewportFrame)")
        var reached = false
        for attempt in 0..<seekBudget {
            if toolbar.isHittable { reached = true; break }
            // Resolve the unchanged wrap state once; query fresh endpoint
            // geometry per gesture without repeatedly snapshotting all leaves.
            let toolbarFrame = toolbar.frame
            let distance = oldest.readable.midY - toolbarFrame.midY
            readback.append("wrap-seek-\(attempt): toolbar=\(toolbarFrame) distance=\(distance)")
            if abs(distance) > viewportFrame.height {
                // The first run made real progress but 24 short drags stopped
                // 3,410pt before this toolbar. Use normal fast flings while far.
                if distance > 0 { scroll.swipeDown(velocity: .fast) }
                else { scroll.swipeUp(velocity: .fast) }
            } else {
                // Settle the actual endpoint into readable space without inertia.
                let translation = max(-0.30, min(0.30, distance / viewportFrame.height))
                scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.55))
                    .press(forDuration: 0.05,
                           thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.55 + translation)),
                           withVelocity: .slow, thenHoldForDuration: 0.15)
            }
        }
        reached = reached || toolbar.isHittable
        guard check(reached, "Group 1's real long-code wrap toolbar was unreachable after \(seekBudget) gestures; no substitute fixture used.") else { return }
        if disable.exists && disable.isHittable { disable.tap() }
        guard check(wait(enable, "exists == true AND hittable == true"), "Unwrapped code toolbar must be tappable.") else { return }
        _ = try boundary("long-code-unwrapped")
        let code = firstAssistant.textViews["native-inline-code-text"].firstMatch
        let source = String(repeating: "let row0 = records.filter { $0.group == 0 }.map { $0.id }\n", count: 40)
            + Array(repeating: "let wrapMarker0 = \"a deliberately long wrapping line that must wrap across the viewport without losing its tail marker 0\"", count: 3).joined(separator: "\n")
        // Resolve one exact leaf, then request its complete value. Archived AX
        // snapshots can truncate long strings; they remain the geometry oracle.
        guard check((code.value as? String) == source, "Group 1 must expose every source line before wrapping.") else { return }
        let beforeCodeFrame = code.frame
        attachScreenshot(named: "r24-before-wrap")
        enable.tap()
        guard check(wait(disable, "exists == true"), "Real wrapping action must change the toolbar state.") else { return }
        _ = try boundary("long-code-wrapped")
        let afterCodeFrame = code.frame
        guard check((code.value as? String) == source && afterCodeFrame.height > beforeCodeFrame.height + 20,
                    "Wrapping must retain the exact long-line endpoint and increase native code height.") else { return }
        guard check(code.exists, "Wrapped source must remain in the actual native code leaf.") else { return }
        attachScreenshot(named: "r24-after-wrap")

        // A real reader gesture precedes real production Back, never a callback.
        dragOlder()
        let beforeBack = try boundary("before-back")
        guard let selected = readableRow(beforeBack.rows, in: beforeBack.readable) else {
            _ = check(false, "No reader target in the production readable region before Back."); return
        }
        readback.append("selected-before-back id=\(selected.identifier) frame=\(selected.frame) readable=\(beforeBack.readable)")
        attachScreenshot(named: "r24-before-back")
        app.buttons["Back"].tap()
        phase = "back-list"
        guard check(open.waitForExistence(timeout: 20) && open.isHittable && !scroll.exists,
                    "Actual Back must remove the transcript and return to the list.") else { return }
        attachScreenshot(named: "r24-back-list")
        open.tap()
        guard check(scroll.waitForExistence(timeout: 20), "Reopen must restore the retained chat.") else { return }
        let reopened = try boundary("after-reopen")
        let restored = reopened.rows.first { $0.identifier == selected.identifier }
        readback.append("selected-after-reopen id=\(selected.identifier) frame=\(String(describing: restored?.frame)) readable=\(reopened.readable)")
        attachScreenshot(named: "r24-after-reopen")
        guard check(restored != nil && restored!.frame.intersection(reopened.readable).height > 20
                    && readableRow(reopened.rows, in: reopened.readable)?.identifier == selected.identifier,
                    "The selected reader target must remain first in the readable region after Back/reopen.") else { return }

        let beforeReadingOffset = selected.frame.minY - beforeBack.readable.minY
        let afterReadingOffset = restored!.frame.minY - reopened.readable.minY
        readback.append("reading-offset before=\(beforeReadingOffset) after=\(afterReadingOffset) delta=\(afterReadingOffset - beforeReadingOffset); beforeRow=\(selected.frame) beforeViewport=\(beforeBack.readable) afterRow=\(restored!.frame) afterViewport=\(reopened.readable)")
        guard check(abs(afterReadingOffset - beforeReadingOffset) <= 24,
                    "Back/reopen must preserve the viewport-relative intra-message reading offset within 24pt.") else { return }

        let stream = app.buttons["rich30-stream-turn"]
        phase = "parked-stream"
        guard check(stream.exists && stream.isHittable && stream.isEnabled, "The existing shared stream action must be reachable while parked.") else { return }
        attachScreenshot(named: "r24-before-parked-stream")
        stream.tap()
        // This short existing fixture may finish before AX observes disabled.
        // Completion plus continuity is asserted; no intermediate-frame claim.
        guard check(wait(stream, "enabled == true"), "Shared stream action must finish.") else { return }
        let parked = try boundary("after-parked-stream")
        let continued = parked.rows.first { $0.identifier == selected.identifier }
        guard check(numbers(parked.rows) == numbers(reopened.rows) && continued != nil
                    && continued!.frame.intersection(parked.readable).height > 20
                    && abs(continued!.frame.minY - restored!.frame.minY) < 24,
                    "Streaming while parked must retain the mounted older window and reader position.") else { return }
        attachScreenshot(named: "r24-after-parked-stream")
        guard check(arrow.exists && arrow.isHittable, "The real down arrow must remain available while parked old.") else { return }
        arrow.tap() // Exactly one return-to-latest action after the entire history walk.
        let streamTail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "SEMREH_MULTI_CHAT_STREAM_1")).firstMatch
        guard check(wait(streamTail, "exists == true AND hittable == true", timeout: 20), "One arrow tap must expose the completed streamed terminal content.") else { return }
        let latest = try boundary("latest-after-one-arrow")
        guard check(latest.rows.contains { $0.identifier == "message-row:perf-stream-message-1-assistant" && $0.label.contains("final chunk. SEMREH_MULTI_CHAT_STREAM_1") },
                    "Completed stream must leave a nonempty transcript with its complete terminal row.") else { return }
        guard check(latest.rows.contains { $0.identifier == finalRow.identifier }
                    && app.staticTexts[finalRow.identifier].label == finalLabel,
                    "Returning to latest must preserve the entire original rich terminal row.") else { return }
        attachScreenshot(named: "r24-latest-after-one-arrow")
    }

    @MainActor
    func testOptInNativeV2FourTallSingleLatestJourney() throws {
        try exerciseNativeV2Journey(readerReopen: false)
    }

    @MainActor
    func testOptInNativeV2Rich30ReaderBackReopenJourney() throws {
        try exerciseNativeV2Journey(readerReopen: true)
    }

    @MainActor
    func testOptInNativeV2Rich30MotionReaderJourney() throws {
        try exerciseNativeV2Journey(readerReopen: true, motionJourney: true)
    }

    @MainActor
    func testOptInNativeV2Rich30FarLatestComprehensiveJourney() throws {
        try exerciseNativeV2Journey(readerReopen: true, motionJourney: true, farLatest: true)
    }

    @MainActor
    func testBackOneTapAfterFlingAndLatestAcrossWarmReopens() throws {
        continueAfterFailure = false
        for native in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--chat-performance-rich30-back-lab", "--composer-test-fresh-draft"]
                + (native ? ["--chat-native-transcript-v2"] : [])
            app.terminate()
            app.launch()
            let open = app.buttons["Open rich30 chat"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 25))
            for cycle in 0..<4 {
                open.tap()
                let scroll = native ? app.collectionViews["chat-native-transcript-v2"]
                    : app.collectionViews["chat-transcript-scroll"]
                XCTAssertTrue(scroll.waitForExistence(timeout: 25))
                let back = app.buttons["chat-back"]
                XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable)
                let frame = back.frame
                // AX expresses global coordinates as floating-point subtraction.
                // Allow only two ULPs of representation noise, not a sub-point
                // reduction of the actual 44-point hit-target requirement.
                XCTAssertGreaterThanOrEqual(frame.width.nextUp.nextUp, 44)
                XCTAssertGreaterThanOrEqual(frame.height.nextUp.nextUp, 44)
                let backTap = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
                let dragStart = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.25))
                let dragEnd = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.80))
                if cycle == 2 {
                    let stream = app.buttons["rich30-stream-turn"]
                    XCTAssertTrue(stream.waitForExistence(timeout: 10))
                    stream.tap()
                }
                dragStart.press(forDuration: 0.01, thenDragTo: dragEnd,
                    withVelocity: .fast, thenHoldForDuration: 0)
                if cycle == 1 {
                    let latest = app.buttons[scrollToLatestLabel]
                    XCTAssertTrue(latest.waitForExistence(timeout: 10) && latest.isHittable)
                    latest.tap()
                }
                if cycle == 3 {
                    let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch
                    XCTAssertTrue(composer.waitForExistence(timeout: 10))
                    composer.tap()
                    composer.typeText("Back preserves the composer draft")
                    XCTAssertTrue(app.keyboards.firstMatch.exists)
                }
                // Exactly one delivered coordinate tap, without a retry. XCUI
                // may wait for idle; this does not prove physical momentum timing.
                backTap.tap()
                XCTAssertTrue(open.waitForExistence(timeout: 20))
                XCTAssertFalse(scroll.exists, "One Back tap must remove the actual transcript destination")
                attachScreenshot(named: "pass2-back-native-\(native)-cycle-\(cycle)")
            }
            app.terminate()
        }
    }

    @MainActor
    func testOptInNativeV2LatestAfterFastFling() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-rich30-back-lab", "--chat-native-transcript-v2",
            "--chat-rich-native-code-text", "--chat-full-inline-code", "--chat-viewport-follow-latest-open",
            "--composer-test-fresh-draft"]
        app.terminate()
        app.launch()
        let open = app.buttons["Open rich30 chat"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 25))
        open.tap()
        let scroll = app.collectionViews["chat-native-transcript-v2"]
        let marker = app.staticTexts["chat-native-transcript-v2"].firstMatch
        let tail = app.staticTexts.matching(NSPredicate(format: "label == %@",
            "Rich group 30 complete. SEMREH_RICH30_END")).firstMatch
        let arrow = app.buttons[scrollToLatestLabel]
        func wait(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval = 15) -> Bool {
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate),
                object: element)], timeout: timeout) == .completed
        }
        func fields(_ value: String) -> [String: String] {
            value.split(separator: ";").reduce(into: [:]) { result, field in
                let pair = field.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
            }
        }
        XCTAssertTrue(scroll.waitForExistence(timeout: 25) && marker.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(tail, "exists == true AND hittable == true"))
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.30))
            .press(forDuration: 0.08, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.76)))
        XCTAssertTrue(wait(arrow, "exists == true AND hittable == true"))
        let before = marker.value as? String ?? ""
        let beforeFields = fields(before)
        let beforeCompleted = try XCTUnwrap(beforeFields["motionCompleted"].flatMap(Int.init))
        let beforeTakeovers = try XCTUnwrap(beforeFields["decelerationTakeovers"].flatMap(Int.init))
        let button = arrow.frame
        let tap = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: button.midX, dy: button.midY))
        attachScreenshot(named: "r44-before-fast-fling")
        // No AX query between the fast fling and tap. Public XCUI still may wait
        // for quiescence; only the latched UIKit counter establishes takeover.
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.25))
            .press(forDuration: 0.01, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.80)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        tap.tap()
        let reached = wait(tail, "exists == true AND hittable == true", timeout: 20)
        let idle = wait(marker, "value CONTAINS 'motion=idle'", timeout: 5)
        let after = marker.value as? String ?? ""
        let afterFields = fields(after)
        let afterTakeovers = try XCTUnwrap(afterFields["decelerationTakeovers"].flatMap(Int.init))
        attachPlainText("before: \(before)\nafter: \(after)\nphysicalDecelerationTakeoverObserved=\(afterTakeovers > beforeTakeovers)\nXCUI may deliver the tap after momentum ends; false leaves physical takeover unverified.",
                        named: "r44-fast-fling-readback")
        attachScreenshot(named: "r44-after-fast-fling-latest")
        XCTAssertTrue(reached && idle, "One latest tap after a fast fling must settle at the terminal paragraph.")
        XCTAssertEqual(afterFields["state"], "following")
        XCTAssertEqual(afterFields["motionCompleted"].flatMap(Int.init), beforeCompleted + 1)
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch.frame
        let endpoint = tail.frame
        XCTAssertGreaterThan(endpoint.height, 0)
        XCTAssertLessThan(endpoint.height, 100)
        XCTAssertGreaterThanOrEqual(endpoint.minY, scroll.frame.minY)
        XCTAssertLessThanOrEqual(endpoint.maxY, composer.minY - 12)
    }

    @MainActor
    private func exerciseNativeV2Journey(readerReopen: Bool, motionJourney: Bool = false, farLatest: Bool = false,
                                         requiresMuseSurface: Bool = false, museSurface: Bool? = nil) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let enablesMuseSurface = museSurface ?? true
        let checksMuseGeometry = requiresMuseSurface || museSurface == true
        // The four-tall selector takes precedence over the generic tall route.
        app.launchArguments = (readerReopen ? ["--chat-performance-rich30-back-lab"]
            : ["--chat-performance-tall-lab", "--chat-performance-four-tall-lab"])
            + ["--chat-rich-native-code-text",
               "--chat-full-inline-code", "--chat-viewport-follow-latest-open",
               "--composer-test-fresh-draft"]
            + (readerReopen ? ["--chat-performance-stream-rich-code"] : [])
            + (enablesMuseSurface ? ["--chat-native-transcript-v2"] : [])
        if museSurface != nil {
            // Explicit DEBUG arguments select both sides independently of
            // persisted defaults. This compares current and legacy surfaces.
            if !enablesMuseSurface { app.launchArguments.append("--chat-legacy-transcript") }
            app.launchArguments += [
                                    "--chat-performance-app-wide-monitor",
                                    "--chat-performance-signposts"]
        }
        let name = museSurface.map { "muse-rich30-\($0 ? "candidate" : "baseline")" }
            ?? (requiresMuseSurface ? "muse-rich30" : farLatest ? "r39-native-far-latest" : motionJourney ? "r38-native-motion-reader" : readerReopen ? "r37-native-rich30" : "r37-native-four-tall")
        var events: [[String: Any]] = []
        func record(_ event: String) {
            guard museSurface != nil else { return }
            smoothnessEvent(event, into: &events)
        }
        record("process_launch_request")
        app.terminate()
        app.launch() // Configure and cold-launch before constructing any AX queries.
        // The internal renderer identifies its collection separately from the
        // DEBUG status text; resolve each by type, never an untyped firstMatch.
        let scroll = app.collectionViews[enablesMuseSurface ? "chat-native-transcript-v2" : "chat-transcript-scroll"]
        let marker = app.staticTexts["chat-native-transcript-v2"].firstMatch
        let open = app.buttons["Open rich30 chat"].firstMatch
        let arrow = app.buttons[scrollToLatestLabel]
        let terminal = readerReopen ? "Rich group 30 complete. SEMREH_RICH30_END"
            : "End of four-row mixed conversation."
        let tail = app.staticTexts.matching(NSPredicate(format: "label == %@", terminal)).firstMatch
        var phase = "launch"
        var evidence: [String] = []
        func check(_ passed: Bool, _ message: String) -> Bool {
            guard !passed else { return true }
            attachScreenshot(named: "\(name)-\(phase)-failure")
            // Bounded geometry/identifier evidence, never a giant live AX dump.
            attachPlainText(evidence.suffix(24).joined(separator: "\n") + "\nFailure: \(message)",
                            named: "\(name)-\(phase)-failure-geometry")
            XCTFail(message)
            return false
        }
        func wait(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval = 15) -> Bool {
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate),
                                                         object: element)], timeout: timeout) == .completed
        }
        func boundary(_ label: String) throws -> (rows: [XCUIElementSnapshot], readable: CGRect) {
            phase = label
            record(label)
            let snapshot: XCUIElementSnapshot
            do { snapshot = try scroll.snapshot() }
            catch {
                _ = check(false, "Transcript subtree snapshot failed: \(error)")
                throw error
            }
            let back = app.buttons["Back"].frame
            let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch.frame
            let readable: CGRect
            if checksMuseGeometry {
                readable = try museReadableRegion(app: app, transcriptFrame: snapshot.frame)
            } else {
                let top = max(snapshot.frame.minY, back.minY - 4 + 96 + 24)
                let bottom = min(snapshot.frame.maxY, composer.minY - 12)
                readable = CGRect(x: snapshot.frame.minX, y: top, width: snapshot.frame.width,
                                  height: max(0, bottom - top))
            }
            var rows: [XCUIElementSnapshot] = []
            var preview = false
            func visit(_ node: XCUIElementSnapshot) {
                if node.elementType == .staticText && node.identifier.hasPrefix("message-row:") { rows.append(node) }
                if node.identifier == "view-full-code" || node.label.hasPrefix("View full code (") { preview = true }
                node.children.forEach(visit)
            }
            visit(snapshot)
            evidence.append("\(label): scroll=\(snapshot.frame) back=\(back) composer=\(composer) readable=\(readable) mounted=\(rows.count)")
            evidence.append(contentsOf: rows.prefix(60).map { "\($0.identifier) frame=\($0.frame)" })
            attachPlainText(evidence.suffix(min(rows.count, 60) + 1).joined(separator: "\n"), named: "\(name)-\(label)-geometry")
            _ = check(back.height > 0 && composer.height > 0 && readable.height > 20,
                      "The production shell must leave a readable transcript.")
            _ = check(!rows.isEmpty && !preview, "Reused cells must retain full-inline content without source previews.")
            return (rows, readable)
        }
        func first(_ state: (rows: [XCUIElementSnapshot], readable: CGRect)) -> XCUIElementSnapshot? {
            state.rows.filter { $0.frame.intersection(state.readable).height > 20
                && $0.frame.intersection(state.readable).width > 0 }
                .sorted { $0.frame.minY < $1.frame.minY }.first
        }
        func visibleTail(_ region: CGRect) -> Bool {
            guard tail.exists else { return false }
            let frame = tail.frame
            return frame.height > 0 && frame.height < 100 && region.contains(frame)
        }
        func dragOlder() {
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.30))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.76)))
        }
        func motionCounters(_ label: String) -> (completed: Int, cancelled: Int, samples: Int)? {
            let value = marker.value as? String ?? ""
            evidence.append("\(label): \(value)")
            let fields = value.split(separator: ";").reduce(into: [String: String]()) { result, field in
                let pair = field.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
            }
            guard check(fields["motion"] == "idle" || fields["motion"] == "animating",
                        "Native motion probe must publish its state."),
                  let completed = fields["motionCompleted"].flatMap(Int.init),
                  let cancelled = fields["motionCancelled"].flatMap(Int.init),
                  let samples = fields["motionSamples"].flatMap(Int.init) else {
                _ = check(false, "Native motion probe must publish all latched counters.")
                return nil
            }
            return (completed, cancelled, samples)
        }
        defer { attachPlainText(evidence.joined(separator: "\n"), named: "\(name)-readback") }
        if museSurface != nil {
            attachPlainText(app.launchArguments.joined(separator: "\n"), named: "\(name)-launch-arguments")
        }
        if readerReopen {
            guard check(open.waitForExistence(timeout: 25) && open.isHittable, "Open rich30 entry must be reachable.") else { return }
            record("open_chat_request")
            open.tap()
        }
        if checksMuseGeometry { requireMuseSurface(in: app) }
        guard check(scroll.waitForExistence(timeout: 25) && marker.waitForExistence(timeout: 10),
                    "The actual native scroll and native-v2 controller marker must exist.") else { return }
        if museSurface == false {
            requireSelectedChatSurface(in: app, muse: false)
        }
        guard check(wait(tail, "exists == true", timeout: 25), "Complete terminal paragraph must mount.") else { return }
        let cold = try boundary("cold-tail")
        guard check(visibleTail(cold.readable) && first(cold) != nil, "Cold tail must be semantically visible and nonempty.") else { return }
        attachScreenshot(named: "\(name)-cold-tail")

        if farLatest {
            phase = "status-bar-to-first-group"
            // The target's native screenshot shows the OS clock here, but iOS
            // does not expose its status bar in this app's accessibility tree.
            // One physical clock-region tap; actual first-group arrival below
            // remains mandatory. No debug offset or corrective swipe ladder.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.04)).tap()
            let firstRequest = app.staticTexts["message-row:rich30-message-0"]
            guard check(wait(firstRequest, "exists == true AND hittable == true", timeout: 12),
                        "FAR coverage blocked: status-bar tap did not realize the first rich group.") else { return }
            let top = try boundary("far-first-group")
            guard check(top.rows.contains { $0.identifier == "message-row:rich30-message-0"
                        && $0.label.contains("Rich group 1 request.")
                        && $0.frame.intersection(top.readable).height > 20 },
                        "FAR origin must contain readable original first-group text.") else { return }
            // The unchanged first request is itself 502pt tall plus its link
            // preview. One ordinary reader drag reveals the response below it;
            // the two full messages cannot both fit above the composer at top.
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.80))
                .press(forDuration: 0.08, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.25)))
            let responseOrigin = try boundary("far-first-response")
            let firstResponse = app.staticTexts["message-row:rich30-message-1"]
            let firstInline = firstResponse.textViews["native-inline-code-text"].firstMatch
            let firstSource = String(repeating: "let row0 = records.filter { $0.group == 0 }.map { $0.id }\n", count: 40)
            guard check(responseOrigin.rows.contains { $0.identifier == "message-row:rich30-message-1"
                        && $0.label.contains("Rich group 1")
                        && $0.frame.intersection(responseOrigin.readable).height > 20 }
                        && firstResponse.label.contains(firstSource)
                        && firstInline.exists && (firstInline.value as? String ?? "").contains(firstSource),
                        "FAR origin must also realize the original rich response with readable geometry and complete repeated source."),
                  check(arrow.exists && arrow.isHittable, "FAR origin must expose latest."),
                  let before = motionCounters("far-before-latest") else { return }
            attachScreenshot(named: "\(name)-far-first-group")
            arrow.tap() // Exactly one latest action for the scored FAR landing.
            guard check(wait(tail, "exists == true AND hittable == true", timeout: 20),
                        "One FAR latest tap must reach the original terminal paragraph."),
                  check(wait(marker, "value CONTAINS 'motion=idle'", timeout: 5),
                        "FAR motion must finish before scoring its latched counters."),
                  let after = motionCounters("far-after-latest"),
                  check(after.completed == before.completed + 1 && after.cancelled == before.cancelled
                        && after.samples > before.samples,
                        "FAR latest must complete one sampled motion without cancellation.") else { return }
            let landed = try boundary("far-terminal")
            let original = String(repeating: "let row29 = records.filter { $0.group == 29 }.map { $0.id }\n", count: 88)
                + "let richGroupFinalSourceLine30 = \"SEMREH_RICH30_CODE_END\""
            let finalRow = app.staticTexts["message-row:rich30-message-59"]
            let inline = finalRow.textViews["native-inline-code-text"].firstMatch
            guard check(visibleTail(landed.readable) && finalRow.label.contains(original)
                        && inline.exists && (inline.value as? String ?? "").contains(original),
                        "FAR landing must retain every original terminal source line inline.") else { return }
            attachScreenshot(named: "\(name)-far-terminal")
        }

        // Finger moves down to move the viewport upward into older text; use
        // the outer trailing gutter to avoid nested code's horizontal scroller.
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.30))
            .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.76)))
        guard check(wait(arrow, "exists == true AND hittable == true", timeout: 10), "Real reader drag must expose latest action.") else { return }
        let parked = try boundary("reader-before-back")
        guard let selected = first(parked), let initial = first(cold) else {
            _ = check(false, "Real drag must leave readable content."); return
        }
        let offset = selected.frame.minY - parked.readable.minY
        guard check(selected.identifier != initial.identifier
                    || offset > initial.frame.minY - cold.readable.minY + 24,
                    "The drag must measurably move into older content, even within a tall row.") else { return }
        attachScreenshot(named: "\(name)-reader-before-back")
        if readerReopen {
            record("back_request")
            app.buttons["Back"].tap()
            phase = "back-list"
            guard check(open.waitForExistence(timeout: 20) && open.isHittable && !scroll.exists,
                        "Back must return to the actual list.") else { return }
            attachScreenshot(named: "\(name)-back-list")
            record("reopen_request")
            open.tap()
            guard check(scroll.waitForExistence(timeout: 20) && marker.exists, "Reopen must restore the native route.") else { return }
            if checksMuseGeometry { requireMuseSurface(in: app) }
            if museSurface == false {
                requireSelectedChatSurface(in: app, muse: false)
            }
            let reopened = try boundary("reopened-reader")
            guard let restored = first(reopened) else { _ = check(false, "Reopen must not be blank."); return }
            let delta = restored.frame.minY - reopened.readable.minY - offset
            evidence.append("restore id=\(selected.identifier) restored=\(restored.identifier) beforeOffset=\(offset) delta=\(delta)")
            guard check(restored.identifier == selected.identifier && abs(delta) <= 24,
                        "Back/reopen must preserve first readable content and intra-row offset within 24pt.") else { return }
            attachScreenshot(named: "\(name)-reopened-reader")
        }
        guard check(arrow.exists && arrow.isHittable, "Latest must remain available while parked.") else { return }
        let beforeMotion = motionJourney ? motionCounters("before-first-latest") : nil
        if motionJourney && beforeMotion == nil { return }
        record("latest_tap_request")
        arrow.tap() // One latest action; no corrective gesture for this scored landing.
        guard check(wait(tail, "exists == true AND hittable == true", timeout: 20), "One latest tap must reach the terminal paragraph.") else { return }
        let latest = try boundary("after-one-latest")
        guard check(visibleTail(latest.readable) && first(latest) != nil, "Latest must leave visible complete terminal content.") else { return }
        attachScreenshot(named: "\(name)-after-one-latest")
        if motionJourney {
            guard let beforeMotion, let completed = motionCounters("after-first-latest"),
                  check(completed.completed > beforeMotion.completed && completed.samples > beforeMotion.samples,
                        "One latest tap must complete sampled native motion; counters are not FPS.") else { return }
            dragOlder()
            guard check(wait(arrow, "exists == true AND hittable == true", timeout: 10),
                        "Repeat real drag must expose latest.") else { return }
            let repeatParked = try boundary("repeat-drag")
            guard let moved = first(repeatParked), let atLatest = first(latest),
                  check(moved.identifier != atLatest.identifier
                        || moved.frame.minY - repeatParked.readable.minY > atLatest.frame.minY - latest.readable.minY + 24,
                        "Repeated drag must produce actual displacement in immutable geometry.") else { return }
            arrow.tap()
            // Attempt an immediate finger interruption. XCUI may quiesce until
            // motion completes; latched cancellation is evidence, never assumed.
            dragOlder()
            let interrupted = try boundary("drag-after-repeat-latest")
            guard let reading = first(interrupted),
                  check(arrow.exists && arrow.isHittable
                        && (reading.identifier != atLatest.identifier
                            || reading.frame.minY - interrupted.readable.minY > atLatest.frame.minY - latest.readable.minY + 24),
                        "The immediate post-latest drag must leave a displaced readable viewport."),
                  let afterDrag = motionCounters("after-interruption-attempt"),
                  check(afterDrag.completed + afterDrag.cancelled > completed.completed + completed.cancelled
                        && afterDrag.samples > completed.samples,
                        "Repeated latest must record sampled motion and a completed or cancelled outcome.") else { return }
            evidence.append("interruptionObserved=\(afterDrag.cancelled > completed.cancelled); XCUI quiescence may consume motion before the drag")
            arrow.tap()
            guard check(wait(tail, "exists == true AND hittable == true", timeout: 20),
                        "One latest after the interruption attempt must restore the terminal paragraph.") else { return }
            let returned = try boundary("repeat-latest-tail")
            guard check(visibleTail(returned.readable), "Repeated latest must restore complete terminal geometry.") else { return }
        }
        if !readerReopen {
            let row = app.staticTexts["message-row:four-tall-message-3"]
            let expected = String(repeating: "let value = Array(0..<1_000).reduce(0, +)\n", count: 320)
                + "\nlet fourTallFinalMarker = \"SEMREH_FOUR_TALL_CODE_END\""
            let code = row.textViews["native-inline-code-text"].firstMatch
            let displayed = expected.components(separatedBy: "\n").map { $0.isEmpty ? " " : $0 }.joined(separator: "\n")
            guard check(row.exists && row.label.contains(expected) && code.exists
                        && (code.value as? String) == displayed,
                        "The complete final code, including its end marker, must remain inline without truncation.") else { return }
        } else {
            let row = app.staticTexts["message-row:rich30-message-59"]
            let expected = String(repeating: "let row29 = records.filter { $0.group == 29 }.map { $0.id }\n", count: 88)
                + "let richGroupFinalSourceLine30 = \"SEMREH_RICH30_CODE_END\""
            let code = row.textViews["native-inline-code-text"].firstMatch
            guard check(row.exists && row.label.contains(expected) && code.exists
                        && (code.value as? String ?? "").contains(expected),
                        "Rich30's terminal cell must retain all 88 source lines and the final code marker.") else { return }
            // Full-response Select Text is distinct from inline paragraph-range selection.
            phase = "full-response-selection"
            tail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
            let select = app.buttons["Select Text"]
            guard check(select.waitForExistence(timeout: 3), "Terminal paragraph must offer full-response Select Text.") else { return }
            select.tap()
            let selection = app.textViews["selectable-response-text"]
            guard check(selection.waitForExistence(timeout: 5), "Full-response selection must open.") else { return }
            let source = selection.value as? String ?? ""
            guard check(source.contains(expected) && source.contains(terminal),
                        "Full-response selection must retain every source line and terminal paragraph.") else { return }
            XCUIDevice.shared.press(.home)
            guard check(app.wait(for: .runningBackground, timeout: 5), "Selection journey must actually background the app.") else { return }
            app.activate()
            guard check(selection.waitForExistence(timeout: 5) && (selection.value as? String) == source
                        && !app.keyboards.firstMatch.exists,
                        "Foreground must preserve full-response source without focusing the composer.") else { return }
            app.buttons["Done"].firstMatch.tap()
            guard check(selection.waitForNonExistence(timeout: 5), "Done must dismiss full-response selection.") else { return }
            let afterSelection = try boundary("selection-return")
            guard check(marker.exists && visibleTail(afterSelection.readable), "Selection return must retain the native terminal paragraph.") else { return }

            dragOlder()
            guard check(wait(arrow, "exists == true AND hittable == true", timeout: 10), "Real drag must park before streaming.") else { return }
            let beforeStream = try boundary("parked-before-stream")
            guard let anchor = first(beforeStream) else { _ = check(false, "Parked stream needs readable content."); return }
            let stream = app.buttons["rich30-stream-turn"]
            guard check(stream.exists && stream.isHittable && stream.isEnabled, "Shared rich30 stream action must be usable.") else { return }
            record("parked_stream_request")
            stream.tap()
            guard check(wait(stream, "enabled == true", timeout: 20), "Shared stream must complete.") else { return }
            let afterStream = try boundary("parked-after-stream")
            guard let retained = afterStream.rows.first(where: { $0.identifier == anchor.identifier }),
                  check(arrow.exists && retained.frame.intersection(afterStream.readable).height > 20
                        && abs((retained.frame.minY - afterStream.readable.minY)
                               - (anchor.frame.minY - beforeStream.readable.minY)) <= 24,
                        "Parked streaming must preserve the same readable row and intra-row offset.") else { return }
            record("stream_latest_tap_request")
            arrow.tap()
            let streamedTail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "SEMREH_MULTI_CHAT_STREAM_1")).firstMatch
            guard check(wait(streamedTail, "exists == true AND hittable == true", timeout: 20), "One latest must expose the actual completed streamed response.") else { return }
            let streamed = try boundary("stream-completed-tail")
            let streamedCode = "let lineOne = \"a long synthetic line that wraps across the viewport and remains readable while the fence is open\"\n"
                + "let lineTwo = \"another long synthetic line that grows the open code block while the reader is parked away from the tail\"\n"
                + "let finalSourceLine = \"SEMREH_STREAM_CODE_END_1\""
            guard check(streamed.readable.contains(streamedTail.frame)
                        && streamed.rows.contains { $0.identifier == "message-row:perf-stream-message-1-assistant"
                            && $0.label.contains(streamedCode)
                            && $0.label.contains("SEMREH_MULTI_CHAT_STREAM_1") },
                        "Stream completion must retain the full final code marker and readable terminal content.") else { return }
            // Reuse the established composer action after restoration is scored.
            phase = "composer"
            let composer = app.textViews["chat-composer-input"]
            guard check(composer.exists && composer.isHittable, "Composer must remain usable.") else { return }
            composer.tap()
            guard check(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Composer tap must open the real keyboard.") else { return }
            composer.typeText("R37 reader draft")
            guard check((composer.value as? String ?? "").contains("R37 reader draft"), "Composer must retain typed text.") else { return }
            attachScreenshot(named: "\(name)-composer-keyboard")
        }
        if museSurface != nil {
            record("journey_complete")
            attachSmoothnessEvidence(app, scenario: name, events: events)
        }
    }

    func testRich30ReaderDragSurvivesBackAndReopen() throws {
        continueAfterFailure = false
        for eager in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--chat-performance-rich30-back-lab", "--composer-test-fresh-draft"]
                + (eager ? ["--chat-windowed-eager", "--chat-windowed-rows=60"] : [])
            app.launch()
            let open = app.buttons["Open rich30 chat"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 25))
            open.tap()
            let scroll = app.scrollViews["chat-transcript-scroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 20))

            func firstReadableRow() throws -> Int? {
                // Resolve the complete subtree once. Live element-property reads
                // took hundreds of AX snapshots before reaching the first drag.
                let snapshot = try scroll.snapshot()
                let viewport = snapshot.frame
                let prefix = "message-row:rich30-message-"
                var first: (number: Int, y: CGFloat)?
                func visit(_ row: XCUIElementSnapshot) {
                    if row.elementType == .staticText,
                       row.identifier.hasPrefix(prefix),
                       let number = Int(row.identifier.dropFirst(prefix.count)),
                       row.frame.maxY > viewport.minY + 1,
                       row.frame.minY < viewport.maxY - 1,
                       first == nil || row.frame.minY < first!.y {
                        first = (number, row.frame.minY)
                    }
                    for child in row.children { visit(child) }
                }
                visit(snapshot)
                return first?.number
            }

            let initialRow = try firstReadableRow()
            XCTAssertNotNil(initialRow, "The mounted chat must expose a readable display row")
            var changedRow: Int?
            for _ in 0..<8 where changedRow == nil {
                scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.82))
                    .press(forDuration: 0.05,
                           thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.18)))
                if let row = try firstReadableRow(), row != initialRow { changedRow = row }
            }
            guard let savedRow = changedRow else {
                XCTFail("A real drag must change the reader's logical row before Back")
                app.terminate()
                continue
            }
            let before = XCTAttachment(screenshot: app.screenshot())
            before.name = "Reader after real drag, before Back, eager=\(eager)"
            before.lifetime = .keepAlways
            add(before)

            let back = app.buttons["Back"]
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            let composer = app.descendants(matching: .any)
                .matching(identifier: "chat-composer-input").firstMatch
            XCTAssertTrue(composer.exists, "The production composer must be present during reader restoration")
            let beforeGeometry = XCTAttachment(string: "eager=\(eager) savedAXRow=\(savedRow) window=\(app.windows.firstMatch.frame) transcript=\(scroll.frame) headerBack=\(back.frame) composer=\(composer.frame)")
            beforeGeometry.name = "Reader production shell rectangles before Back"
            beforeGeometry.lifetime = .keepAlways
            add(beforeGeometry)
            back.tap()
            XCTAssertTrue(open.waitForExistence(timeout: 20))
            XCTAssertFalse(scroll.exists)
            open.tap()
            XCTAssertTrue(scroll.waitForExistence(timeout: 20))
            let reopenedRow = try firstReadableRow()
            let after = XCTAttachment(screenshot: app.screenshot())
            after.name = "Reader after retained ChatView reopen, eager=\(eager)"
            after.lifetime = .keepAlways
            add(after)
            let afterGeometry = XCTAttachment(string: "eager=\(eager) restoredAXRow=\(String(describing: reopenedRow)) window=\(app.windows.firstMatch.frame) transcript=\(scroll.frame) headerBack=\(app.buttons["Back"].frame) composer=\(composer.frame)")
            afterGeometry.name = "Reader production shell rectangles after reopen"
            afterGeometry.lifetime = .keepAlways
            add(afterGeometry)
            XCTAssertEqual(reopenedRow, savedRow,
                           "A real user drag must survive the production Back persistence and retained-model reopen path")
            app.terminate()
        }
    }

    @MainActor
    private func exerciseSmoothnessRich30OpenBack(candidate: Bool) throws {
        try smoothnessEnabled()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = smoothnessArguments("--chat-performance-rich30-back-lab", candidate: candidate)
        var events: [[String: Any]] = []
        smoothnessEvent("process_launch_request", into: &events)
        app.launch()
        let open = app.buttons["Open rich30 chat"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 25))
        smoothnessEvent("list_readable_after_preparation", into: &events)
        let chat = app.scrollViews["chat-transcript-scroll"]
        for cycle in 1...6 {
            smoothnessEvent("open_\(cycle)_tap_request", into: &events)
            open.tap()
            XCTAssertTrue(chat.waitForExistence(timeout: 25))
            smoothnessEvent("open_\(cycle)_transcript_readable", into: &events)
            let back = app.buttons["Back"]
            XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable)
            if cycle == 3 {
                let stream = app.buttons["rich30-stream-turn"]
                XCTAssertTrue(stream.waitForExistence(timeout: 10))
                smoothnessEvent("stream_back_request", into: &events)
                stream.tap()
            }
            smoothnessEvent("back_\(cycle)_tap_request", into: &events)
            back.tap()
            XCTAssertTrue(open.waitForExistence(timeout: 20))
            XCTAssertFalse(chat.exists, "Back must dismiss the chat destination.")
            smoothnessEvent("back_\(cycle)_list_readable", into: &events)
        }
        attachSmoothnessEvidence(app, scenario: "rich30_open_back", events: events)
    }

    @MainActor
    func testOptInSmoothnessRichSwitchBaseline() throws {
        try exerciseSmoothnessRichSwitch(candidate: false)
    }

    @MainActor
    func testOptInSmoothnessRichSwitchCandidate() throws {
        try exerciseSmoothnessRichSwitch(candidate: true)
    }

    @MainActor
    private func exerciseSmoothnessRichSwitch(candidate: Bool) throws {
        try smoothnessEnabled()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = smoothnessArguments("--chat-performance-rich-switch-lab", candidate: candidate)
        var events: [[String: Any]] = []
        smoothnessEvent("process_launch_request", into: &events)
        app.launch()
        for (visitIndex, chatNumber) in [1, 2, 1, 2, 1].enumerated() {
            let switchButton = app.buttons["Performance chat \(chatNumber)"]
            if visitIndex != 0 {
                smoothnessEvent("switch_\(chatNumber)_request", into: &events)
                switchButton.tap()
            }
            let chat = app.otherElements["chat-detail:Rich 30-group lab \(chatNumber)"]
            XCTAssertTrue(chat.waitForExistence(timeout: 20) && chat.isHittable)
            XCTAssertTrue(switchButton.isSelected, "Performance chat \(chatNumber) must be selected on visit \(visitIndex + 1).")
            smoothnessEvent("chat_\(chatNumber)_readable", into: &events)
        }
        attachScreenshot(named: "smoothness-multi-chat-return-a")
        attachSmoothnessEvidence(app, scenario: "rich30_switch", events: events)
    }

    @MainActor
    func testOptInSmoothnessRich30CoveragePagingBaseline() throws {
        try exerciseSmoothnessRich30CoveragePaging(candidate: false)
    }

    @MainActor
    func testOptInSmoothnessRich30CoveragePaging() throws {
        try exerciseSmoothnessRich30CoveragePaging(candidate: true)
    }

    @MainActor
    private func exerciseSmoothnessRich30CoveragePaging(candidate: Bool) throws {
        try smoothnessEnabled()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = smoothnessArguments("--chat-performance-rich30-lab", candidate: candidate)
            + ["--chat-performance-rich30-paging-spread"]
        var events: [[String: Any]] = []
        smoothnessEvent("process_launch_request", into: &events)
        app.launch()
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", rich30Marker)).firstMatch
        assertHittable(tail, timeout: 35, message: "Paging cold tail must be readable.")
        smoothnessEvent("first_readable_tail", into: &events)
        let older = app.buttons["windowed-page-older"]
        XCTAssertTrue(older.waitForExistence(timeout: 10) && older.isHittable)
        let firstRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Rich group")).firstMatch
        // This is the separate full-coverage run. The eager60 screening runs
        // do not imply that tool-card rows leave all 30 groups mounted.
        var coveredGroups = Set<Int>()
        let pattern = try NSRegularExpression(pattern: #"Rich group ([0-9]+) complete"#)
        func collectVisibleGroups() {
            for label in app.staticTexts.allElementsBoundByIndex.map(\.label) {
                let range = NSRange(label.startIndex..<label.endIndex, in: label)
                for match in pattern.matches(in: label, range: range) {
                    guard let numberRange = Range(match.range(at: 1), in: label),
                          let number = Int(label[numberRange]) else { continue }
                    coveredGroups.insert(number)
                }
            }
        }
        collectVisibleGroups()
        for page in 1...3 {
            let beforePage = firstRow.label
            smoothnessEvent("page_\(page)_request", into: &events)
            older.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label != %@", beforePage), object: firstRow
            )], timeout: 10), .completed, "Paging must publish a different mounted row.")
            collectVisibleGroups()
            smoothnessEvent("page_\(page)_readable", into: &events)
        }
        let scroll = app.scrollViews["chat-transcript-scroll"]
        for _ in 0..<35 where coveredGroups.count < 30 {
            if older.isHittable { older.tap() }
            scroll.swipeDown()
            collectVisibleGroups()
        }
        XCTAssertEqual(coveredGroups, Set(1...30), "Every rich group must be observed in the actual mounted transcript.")
        smoothnessEvent("rich_groups_covered_\(coveredGroups.count)", into: &events)
        attachScreenshot(named: "smoothness-rich30-older-readable")
        let arrow = app.buttons[scrollToLatestLabel]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
        smoothnessEvent("return_latest_request", into: &events)
        arrow.tap()
        assertHittable(tail, timeout: 20, message: "One tap must restore the rich30 tail.")
        smoothnessEvent("return_latest_readable", into: &events)
        attachScreenshot(named: "smoothness-rich30-restored-tail")
        attachSmoothnessEvidence(app, scenario: "rich30_paging", events: events)
    }

    func testDebugStrictNative10kColdFarArrowGate() throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["SEMREH_STRICT_10K_GATE"] == "1" else {
            throw XCTSkip("The rejected strict 10k viewport diagnostic is opt-in.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--chat-performance-lab", "--native-direct-mixed-rich-10k",
                               "--chat-stable-viewport", "--native-direct-strict-10k-gate"]
        app.launch()
        let scroll = app.scrollViews["prototype-transcript-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 20))
        let coldRow = app.staticTexts["message-row:perf-message-000020"]
        let coldAccessible = coldRow.waitForExistence(timeout: 2) && coldRow.isHittable
        print("SEMREH_STRICT_10K_COLD_AX row20=\(coldAccessible)")
        attachScreenshot(named: "strict-native-10k-cold")
        attachAccessibilitySnapshot(named: "strict-native-10k-cold-ax", app: app)
        let arrow = app.buttons["Prototype scroll to latest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10) && arrow.isHittable)
        print("SEMREH_STRICT_10K_TAP at=\(Date())")
        arrow.tap()
        attachScreenshot(named: "strict-native-10k-post-tap")
        XCTAssertTrue(coldAccessible,
                      "The saved row20 must be source-accurate and accessible at cold open.")
        XCTAssertFalse(app.staticTexts["native-direct-arrow-unready"].exists,
                       "The real-row corridor must be ready on the first cold far-arrow tap.")
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "End of 10,000-row conversation.")).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 15) && tail.isHittable,
                      "The far arrow must visibly reach the real source tail.")
        XCTAssertTrue(app.otherElements.containing(.staticText,
            identifier: "message-row:perf-message-009999")
            .matching(identifier: "native-direct-transcript-row").firstMatch.exists,
            "The far tail must remain a native row with its real accessibility tree.")
        attachScreenshot(named: "strict-native-10k-tail")
    }

}

// These acceptance selectors exercise the real ChatView with deterministic
// server-free rich history. They prove sampled presentation/interaction states;
// a separate native-timestamp recording is required to inspect intervening frames.
extension LongChatScrollUITests {
    @MainActor
    func testOptInMuseSurfaceRich30Baseline() throws {
        try smoothnessEnabled()
        try exerciseNativeV2Journey(readerReopen: true, motionJourney: true, museSurface: false)
    }

    @MainActor
    func testOptInMuseSurfaceRich30Candidate() throws {
        try smoothnessEnabled()
        try exerciseNativeV2Journey(readerReopen: true, motionJourney: true, museSurface: true)
    }

    @MainActor
    func testMuseSurfaceComposerKeyboardAndDraftGeometry() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let intendedArguments = ["--chat-performance-lab", "--chat-performance-tall-lab", "--chat-performance-four-tall-lab",
                               "--chat-native-transcript-v2", "--chat-rich-native-code-text",
                               "--chat-full-inline-code", "--chat-viewport-follow-latest-open",
                               "--composer-test-fresh-draft"]
        app.launchArguments = intendedArguments
        app.terminate()
        let configuredArguments = app.launchArguments
        let launchReceipt = String(decoding: try JSONSerialization.data(withJSONObject: [
            "marker": "SEMREH_MUSE_KEYBOARD_ENTRY",
            "matches_intended": configuredArguments == intendedArguments,
            "argument_count": configuredArguments.count,
            "known_arguments": configuredArguments.filter { intendedArguments.contains($0) }
        ], options: [.sortedKeys]), as: UTF8.self)
        attachPlainText(launchReceipt, named: "muse-keyboard-launch-arguments")
        print("SEMREH_MUSE_KEYBOARD_ENTRY \(launchReceipt)")
        XCTAssertTrue(configuredArguments == intendedArguments,
                      "The launch-argument property must retain exactly the eight configured lab flags.")
        app.launch()
        requireMuseSurface(in: app)
        let transcript = app.collectionViews["chat-native-transcript-v2"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 25))
        let tail = app.staticTexts.matching(NSPredicate(
            format: "label == %@", "End of four-row mixed conversation."
        )).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 15) && tail.isHittable)
        try assertMuseReadableTranscript(app: app, transcript: transcript, phase: "composer-unfocused")

        let inputs = app.textViews.matching(identifier: "chat-composer-input")
        let composer = inputs.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(inputs.count, 1, "The selected surface must expose exactly one editable composer.")
        let initialDraft = composer.value as? String ?? ""
        XCTAssertTrue(initialDraft.isEmpty || initialDraft == composer.placeholderValue)
        let options = app.buttons["Composer options"]
        let voice = app.buttons["Voice input"]
        XCTAssertTrue(options.isHittable && voice.isHittable)
        XCTAssertLessThanOrEqual(abs(options.frame.midY - voice.frame.midY), 3,
                                 "Collapsed plus and microphone must share one control baseline.")
        composer.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        composer.typeText("Muse draft")
        XCTAssertEqual(composer.value as? String, "Muse draft")
        let singleLineHeight = composer.frame.height
        try assertMuseComposerAboveKeyboard(app: app, composer: composer, keyboard: keyboard)
        try assertMuseReadableTranscript(app: app, transcript: transcript, phase: "composer-single-line")

        let multilineDraft = "Muse draft\nSecond line\nThird line\nFourth line"
        composer.typeText("\nSecond line\nThird line\nFourth line")
        XCTAssertEqual(composer.value as? String, multilineDraft,
                       "Expanding the composer must preserve focus and every typed line.")
        XCTAssertTrue(keyboard.exists)
        XCTAssertGreaterThanOrEqual(composer.frame.height, singleLineHeight + 24,
                                    "Four lines must expand the text field instead of clipping the draft.")
        try assertMuseComposerAboveKeyboard(app: app, composer: composer, keyboard: keyboard)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.isHittable && voice.isHittable)
        XCTAssertLessThanOrEqual(abs(send.frame.midY - voice.frame.midY), 3,
                                 "Send and microphone must retain their shared baseline as the draft grows.")
        XCTAssertTrue(options.isHittable)
        XCTAssertLessThanOrEqual(abs(options.frame.midY - voice.frame.midY), 3,
                                 "Multiline plus and microphone must share one control baseline.")
        XCTAssertLessThanOrEqual(abs(options.frame.midY - send.frame.midY), 3,
                                 "Multiline plus and Send must share one control baseline.")
        XCTAssertLessThanOrEqual(composer.frame.maxY, min(options.frame.minY, send.frame.minY) + 2,
                                 "Expanded draft text must sit above the controls, using the capsule width.")
        XCTAssertGreaterThan(composer.frame.width, 300,
                             "Expanded text must reclaim the collapsed control columns.")
        try assertMuseReadableTranscript(app: app, transcript: transcript, phase: "composer-four-lines")

        // Tap the real software Delete key. This Simulator collapsed a repeated
        // hardware-delete payload to one event and ignored hardware Command-A.
        let deleteKey = keyboard.keys["delete"]
        XCTAssertTrue(deleteKey.waitForExistence(timeout: 3))
        for _ in multilineDraft { deleteKey.tap() }
        let cleared = composer.value as? String ?? ""
        XCTAssertTrue(cleared.isEmpty || cleared == composer.placeholderValue,
                      "Deleting the complete known draft must leave the composer empty.")
        XCTAssertTrue(keyboard.exists, "Clearing a multiline draft must retain keyboard focus.")
        XCTAssertLessThanOrEqual(composer.frame.height, singleLineHeight + 4,
                                 "Clearing must collapse the same composer back to one-line height.")
        XCTAssertEqual(inputs.count, 1)
        XCTAssertTrue(options.isHittable && voice.isHittable)
        XCTAssertLessThanOrEqual(abs(options.frame.midY - voice.frame.midY), 3,
                                 "Clearing must restore the collapsed plus/microphone baseline.")
        try assertMuseComposerAboveKeyboard(app: app, composer: composer, keyboard: keyboard)
        let focusedRegion = try museReadableRegion(app: app, transcriptFrame: transcript.frame)
        try assertMuseReadableTranscript(app: app, transcript: transcript, phase: "composer-cleared")

        // Tap the transcript's trailing gutter through the production dismiss
        // gesture; avoid code links, selectable text and the overlaid dock.
        transcript.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: focusedRegion.maxX - 6 - transcript.frame.minX,
                                 dy: focusedRegion.midY - transcript.frame.minY)).tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5),
                      "A transcript tap must dismiss the real keyboard.")
        try assertMuseReadableTranscript(app: app, transcript: transcript, phase: "composer-keyboard-dismissed")
        let dismissedRegion = try museReadableRegion(app: app, transcriptFrame: transcript.frame)
        XCTAssertGreaterThan(dismissedRegion.height, focusedRegion.height + 100,
                             "Dismissing the keyboard must restore the transcript's usable height.")
        composer.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        composer.typeText("Focus restored")
        XCTAssertEqual(composer.value as? String, "Focus restored")
        try assertMuseComposerAboveKeyboard(app: app, composer: composer, keyboard: keyboard)
        try assertMuseReadableTranscript(app: app, transcript: transcript, phase: "composer-refocused")
        let wrappedSuffix = " while typing a longer paragraph that wraps naturally across several lines without inserting a newline."
        composer.typeText(wrappedSuffix)
        XCTAssertEqual(composer.value as? String, "Focus restored" + wrappedSuffix)
        XCTAssertGreaterThan(composer.frame.width, 300)
        XCTAssertLessThanOrEqual(composer.frame.maxY, options.frame.minY + 2,
                                 "Soft wrapping must use the expanded layout without losing the editor.")
        XCTAssertTrue(keyboard.exists)
        try assertMuseComposerAboveKeyboard(app: app, composer: composer, keyboard: keyboard)
        try assertMuseReadableTranscript(app: app, transcript: transcript, phase: "composer-soft-wrapped")
        // No send: this rich local fixture has no gateway or credentials.
    }

    @MainActor
    func testMuseSurfaceRich30ReaderLatestBackAndReopen() throws {
        // Reuse the complete existing history, selection, stream-while-reading,
        // one-tap Latest, real drag, Back and warm-reader restoration assertions.
        try exerciseNativeV2Journey(readerReopen: true, motionJourney: true,
                                    requiresMuseSurface: true)
    }

    @MainActor
    private func requireMuseSurface(in app: XCUIApplication, needsTranscript: Bool = true) {
        requireSelectedChatSurface(in: app, muse: true, needsTranscript: needsTranscript)
    }

    @MainActor
    private func museReadableRegion(app: XCUIApplication, transcriptFrame: CGRect) throws -> CGRect {
        let header = app.descendants(matching: .any).matching(identifier: "muse-chat-header").firstMatch
        let dock = app.descendants(matching: .any).matching(identifier: "muse-chat-dock").firstMatch
        let window = app.windows.firstMatch.frame
        let headerFrame = header.frame
        let dockFrame = dock.frame
        let viewport = transcriptFrame.intersection(window)
        let probe = app.staticTexts["chat-native-transcript-v2"].firstMatch
        let probeFields = (probe.value as? String ?? "").split(separator: ";")
            .reduce(into: [String: String]()) { fields, entry in
                let pair = entry.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
        guard let surfaceTop = probeFields["surfaceTop"].flatMap(Double.init),
              let surfaceBottom = probeFields["surfaceBottom"].flatMap(Double.init),
              surfaceTop.isFinite && surfaceBottom.isFinite && surfaceTop > 0 && surfaceBottom > 0 else {
            attachPlainText("surfaceTop=\(probeFields["surfaceTop"] ?? "missing") surfaceBottom=\(probeFields["surfaceBottom"] ?? "missing")",
                            named: "muse-invalid-native-clearance")
            XCTFail("The native viewport must publish finite positive measured header and dock clearance.")
            throw NSError(domain: "MuseSurfaceUI", code: 2)
        }
        let frames = [headerFrame, dockFrame, viewport]
        let valid = header.exists && dock.exists && frames.allSatisfy {
            !$0.isNull && $0.origin.x.isFinite && $0.origin.y.isFinite
                && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
        }
        let top = max(viewport.minY + CGFloat(surfaceTop), headerFrame.maxY)
        let bottom = min(viewport.maxY - CGFloat(surfaceBottom), dockFrame.minY)
        let region = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, bottom - top))
        attachPlainText("surfaceTop=\(surfaceTop) surfaceBottom=\(surfaceBottom) viewport=\(viewport) readable=\(region)",
                        named: "muse-native-clearance")
        guard valid && region.height > 20 else {
            attachScreenshot(named: "muse-invalid-readable-geometry")
            attachPlainText("transcript=\(transcriptFrame) header=\(headerFrame) dock=\(dockFrame) window=\(window)",
                            named: "muse-invalid-readable-geometry")
            XCTFail("The measured header and dock must leave a real, nonempty collection viewport.")
            throw NSError(domain: "MuseSurfaceUI", code: 1)
        }
        return region
    }

    @MainActor
    private func assertMuseComposerAboveKeyboard(app: XCUIApplication, composer: XCUIElement,
                                                 keyboard: XCUIElement) throws {
        let dock = app.descendants(matching: .any).matching(identifier: "muse-chat-dock").firstMatch
        let probe = app.staticTexts["chat-native-transcript-v2"].firstMatch
        let fields = (probe.value as? String ?? "").split(separator: ";")
            .reduce(into: [String: String]()) { fields, entry in
                let pair = entry.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
        let keyboardExists = keyboard.exists
        let keyboardFrame = keyboardExists ? keyboard.frame : .null
        let windowFrame = app.windows.firstMatch.frame
        let dockFrame = dock.exists ? dock.frame : .null
        let inputFrame = composer.exists ? composer.frame : .null
        attachPlainText("keyboardTop=\(fields["keyboardTop"] ?? "missing") keyboardHeight=\(fields["keyboardHeight"] ?? "missing")\nAXkeyboardExists=\(keyboardExists) AXkeyboard=\(keyboardFrame)\ndock=\(dockFrame) input=\(inputFrame) window=\(windowFrame)",
                        named: "muse-keyboard-observed-geometry")
        attachScreenshot(named: "muse-keyboard-observed-geometry")
        guard let keyboardTop = fields["keyboardTop"].flatMap(Double.init),
              let keyboardHeight = fields["keyboardHeight"].flatMap(Double.init),
              keyboardTop.isFinite && keyboardHeight.isFinite && keyboardTop > 0 && keyboardHeight > 100 else {
            XCTFail("The observed native keyboard frame must report a finite positive top and an occupied height above 100pt.")
            throw NSError(domain: "MuseSurfaceUI", code: 3)
        }
        let observedTop = CGFloat(keyboardTop)
        let observedBottom = observedTop + CGFloat(keyboardHeight)
        XCTAssertTrue(composer.isHittable && keyboardExists && dock.exists)
        XCTAssertTrue(!windowFrame.isNull && !windowFrame.isInfinite && windowFrame.height > 0)
        XCTAssertGreaterThanOrEqual(observedTop, windowFrame.minY)
        XCTAssertLessThanOrEqual(observedBottom, windowFrame.maxY + 1,
                                 "The full occupied keyboard frame must stay inside the application window.")
        XCTAssertLessThanOrEqual(observedTop, keyboardFrame.minY,
                                 "The observed keyboard frame includes the prediction row omitted from keyboard AX bounds.")
        XCTAssertGreaterThan(inputFrame.height, 0)
        XCTAssertLessThanOrEqual(inputFrame.maxY, observedTop + 1,
                                 "The native keyboard must not cover the draft.")
        let dockGap = observedTop - dockFrame.maxY
        XCTAssertGreaterThanOrEqual(dockGap, -1, "The composer dock must not overlap the keyboard.")
        XCTAssertLessThanOrEqual(dockGap, 12,
                                 "The dock must sit beside the keyboard without duplicate bottom clearance.")
        XCTAssertTrue(dockFrame.insetBy(dx: -1, dy: -1).contains(inputFrame),
                      "The editable composer must remain inside its measured dock.")
    }

    @MainActor
    private func assertMuseReadableTranscript(app: XCUIApplication, transcript: XCUIElement,
                                               phase: String) throws {
        let snapshot = try transcript.snapshot()
        let region = try museReadableRegion(app: app, transcriptFrame: snapshot.frame)
        var visible: [XCUIElementSnapshot] = []
        func visit(_ node: XCUIElementSnapshot) {
            if node.identifier.hasPrefix("message-row:"), !node.label.isEmpty,
               node.frame.intersection(region).height > 20,
               node.frame.intersection(region).width > 0 {
                visible.append(node)
            }
            node.children.forEach(visit)
        }
        visit(snapshot)
        attachPlainText("scope=sampled settled boundary; not an intervening-frame or FPS measurement\nphase=\(phase)\nreadable=\(region)\n"
            + visible.prefix(12).map { "\($0.identifier) frame=\($0.frame)" }.joined(separator: "\n"),
                        named: "muse-\(phase)-geometry")
        attachScreenshot(named: "muse-\(phase)")
        XCTAssertFalse(visible.isEmpty, "The actual collection must contain readable transcript content at \(phase).")
    }
}
