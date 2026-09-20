import XCTest
@testable import SemrehRemoteBrowserCore

final class TextDraftTests: XCTestCase {

    func testCommittedTextInsertedExactlyOnce() {
        var draft = TextDraft()
        draft.edit("Hello café 👨‍👩‍👧‍👦")

        let first = draft.beginCommit()
        XCTAssertEqual(first, "Hello café 👨‍👩‍👧‍👦")
        XCTAssertEqual(draft.delivery, .sending)

        // A second commit while sending is impossible: no double send.
        XCTAssertNil(draft.beginCommit())
    }

    func testEmptyDraftCommitsNothing() {
        var draft = TextDraft()
        XCTAssertNil(draft.beginCommit())
    }

    func testAckLossPreservesDraftWithoutResend() {
        var draft = TextDraft()
        draft.edit("retry me")
        _ = draft.beginCommit()

        draft.markUnconfirmed()

        XCTAssertEqual(draft.delivery, .unconfirmed)
        XCTAssertEqual(draft.text, "retry me", "draft must be preserved")
        // No API resends: beginCommit is blocked while unconfirmed only via
        // explicit user action (edit resets to idle first).
        XCTAssertNil(draft.beginCommit())
    }

    func testClearOnlyAfterConfirmedReceipt() {
        var draft = TextDraft()
        draft.edit("hello")
        _ = draft.beginCommit()

        draft.clearAfterConfirmation()
        XCTAssertEqual(draft.text, "hello", "must not clear before confirmation")

        draft.markConfirmed()
        draft.clearAfterConfirmation()
        XCTAssertEqual(draft.text, "")
        XCTAssertEqual(draft.delivery, .idle)
    }

    func testRejectedDraftPreserved() {
        var draft = TextDraft()
        draft.edit("hello")
        _ = draft.beginCommit()

        draft.markRejected(reason: "surface busy")

        XCTAssertEqual(draft.text, "hello")
        if case .rejected(let reason) = draft.delivery {
            XCTAssertEqual(reason, "surface busy")
        } else {
            XCTFail("expected rejected, got \(draft.delivery)")
        }
    }

    func testEditDuringSendIsIgnored() {
        var draft = TextDraft()
        draft.edit("hello")
        _ = draft.beginCommit()
        draft.edit("changed mid-send")
        XCTAssertEqual(draft.text, "hello")
        XCTAssertEqual(draft.delivery, .sending)
    }

    func testEditAfterConfirmationStartsFreshDraft() {
        var draft = TextDraft()
        draft.edit("hello")
        _ = draft.beginCommit()
        draft.markConfirmed()
        draft.clearAfterConfirmation()

        draft.edit("next")
        XCTAssertEqual(draft.text, "next")
        XCTAssertEqual(draft.delivery, .idle)
        XCTAssertEqual(draft.beginCommit(), "next")
    }
}
