import UIKit
import XCTest
@testable import HermesCompanion

@MainActor
final class TranscriptStreamingTests: XCTestCase {
    private func message(_ text: String, id: String = "stream", provisional: Bool = true) -> ChatMessage {
        .init(id: id, role: "assistant", text: text, provisional: provisional)
    }
    private func textView(in view: UIView) -> UITextView? {
        if let text = view as? UITextView { return text }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }
    private func cell(_ text: String) throws -> (BubbleCell, UITextView) {
        let cell = BubbleCell(style: .default, reuseIdentifier: "bubble")
        cell.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        cell.configure(message(text))
        cell.layoutIfNeeded()
        return (cell, try XCTUnwrap(textView(in: cell)))
    }
    func testProvisionalAppendPreservesExactUnicodeSelectionAndAccessibility() throws {
        let (cell, text) = try cell("cafe")
        text.selectedRange = NSRange(location: 0, length: 3)
        let chunks = ["cafe\u{301} 👩", "cafe\u{301} 👩\u{200D}💻 🇺", "cafe\u{301} 👩\u{200D}💻 🇺🇸\nComplete"]
        for value in chunks {
            cell.appendProvisional(message(value))
            XCTAssertEqual(Array(text.text.utf16), Array(value.utf16))
            XCTAssertEqual(text.selectedRange, NSRange(location: 0, length: 3))
            XCTAssertEqual(text.accessibilityLabel, "Hermes. " + value)
            XCTAssertEqual(text.accessibilityIdentifier, "message-stream")
        }
    }
    func testNonPrefixCorrectionReplacesRealTextViewContent() throws {
        let (cell, text) = try cell("Original provisional content")
        cell.appendProvisional(message("A corrected answer 🧭"))
        XCTAssertEqual(text.text, "A corrected answer 🧭")
        XCTAssertEqual(text.accessibilityLabel, "Hermes. A corrected answer 🧭")
        cell.appendProvisional(message("A corrected answer 🧭 continues"))
        XCTAssertEqual(text.text, "A corrected answer 🧭 continues")
    }
    func testReusedCellDoesNotAppendPreviousRowsText() throws {
        let (cell, text) = try cell("Previous row")
        cell.prepareForReuse()
        cell.appendProvisional(message("New row", id: "new-row"))
        XCTAssertEqual(text.text, "New row")
        XCTAssertEqual(text.accessibilityIdentifier, "message-new-row")
        cell.appendProvisional(message("New row continues", id: "new-row"))
        XCTAssertEqual(text.text, "New row continues")
    }
    func testCanonicalCompletionStillReplacesAndFormatsMarkdown() async throws {
        let (cell, text) = try cell("**Partial")
        cell.appendProvisional(message("**Done**", provisional: false))
        for _ in 0..<100 {
            if text.text == "Done" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(text.text, "Done")
        let font = try XCTUnwrap(text.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertEqual(text.accessibilityLabel, "Hermes. **Done**")
    }
}
