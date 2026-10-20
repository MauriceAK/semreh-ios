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
    func testBlockMarkdownRendersListsHeadingsLinksAndCode() async throws {
        let source = "# A clear answer\n\n- **First** item\n- *Second* item\n\n1. Ordered entry\n2. Another entry\n\n[Open reference](https://example.com/reference)\n\n```swift\nlet value = 42\n```"
        let (cell, text) = try cell("")
        cell.appendProvisional(message(source, provisional: false))
        for _ in 0..<100 {
            if text.text.contains("•\tFirst") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(text.text.hasPrefix("A clear answer\n"))
        XCTAssertTrue(text.text.contains("•\tFirst item\n•\tSecond item"))
        XCTAssertTrue(text.text.contains("1.\tOrdered entry\n2.\tAnother entry"))
        XCTAssertFalse(text.text.contains("**"))
        XCTAssertFalse(text.text.contains("```"))
        let value = try XCTUnwrap(text.attributedText)
        func attributes(_ fragment: String) throws -> [NSAttributedString.Key: Any] {
            let range = (value.string as NSString).range(of: fragment)
            XCTAssertNotEqual(range.location, NSNotFound)
            return value.attributes(at: range.location, effectiveRange: nil)
        }
        let headingFont = try XCTUnwrap(try attributes("A clear answer")[.font] as? UIFont)
        let bodyFont = try XCTUnwrap(try attributes("item")[.font] as? UIFont)
        XCTAssertGreaterThan(headingFont.pointSize, bodyFont.pointSize)
        XCTAssertTrue(headingFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(try XCTUnwrap(try attributes("First")[.font] as? UIFont).fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(try XCTUnwrap(try attributes("Second")[.font] as? UIFont).fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertEqual(try attributes("Open reference")[.link] as? URL, URL(string: "https://example.com/reference"))
        XCTAssertTrue(try XCTUnwrap(try attributes("let value")[.font] as? UIFont).fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        let codeParagraph = try XCTUnwrap(try attributes("let value")[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(codeParagraph.paragraphSpacing, 0, "Code source lines must not acquire prose paragraph gaps.")
    }

    func testStreamingFormatsBeforeCompletionAndCanonicalReplacementWins() async throws {
        let (cell, text) = try cell("## Working answer\n\n- **First** result")
        for _ in 0..<100 {
            if text.text.contains("•\tFirst result") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(text.text.contains("•\tFirst result"), "A still-provisional response must render Markdown.")
        cell.appendProvisional(message("## Working answer\n\n- **First** result\n- **Second** result"))
        cell.appendProvisional(message("**Final canonical answer**", provisional: false))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(text.text, "Final canonical answer")
        XCTAssertEqual(text.accessibilityLabel, "Hermes. **Final canonical answer**")
    }

    func testReusedCellRejectsPendingStreamingFormatting() async throws {
        let (cell, text) = try cell("A **partial")
        cell.appendProvisional(message("A **partial** answer with [a link](https://example.com)"))
        cell.prepareForReuse()
        cell.configure(message("A different cell’s answer", id: "replacement", provisional: false))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(text.text, "A different cell’s answer")
        XCTAssertEqual(text.accessibilityIdentifier, "message-replacement")
    }

    func testCanonicalSameTextFinishesFormattingAppendedMarkdownSuffix() async throws {
        let (cell, text) = try cell("**First** result")
        for _ in 0..<100 {
            if text.text == "First result" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(text.text, "First result")
        let completed = "**First** result\n\n- **Second** result"
        cell.appendProvisional(message(completed))
        cell.appendProvisional(message(completed, provisional: false))
        for _ in 0..<100 {
            if text.text.contains("•\tSecond result") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(text.text, "First result\n•\tSecond result")
        XCTAssertFalse(text.text.contains("**"))
    }

    func testStreamingAppendKeepsHeadingAndBodyFontSizesStable() async throws {
        let (cell, text) = try cell("# Stable heading")
        for _ in 0..<100 {
            if text.text == "Stable heading" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(text.text, "Stable heading")
        let headingBefore = try XCTUnwrap(text.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let bodySize = UIFont.preferredFont(forTextStyle: .body, compatibleWith: cell.traitCollection).pointSize
        cell.appendProvisional(message("# Stable heading\n\nA body paragraph"))
        for _ in 0..<100 {
            if text.text == "Stable heading\nA body paragraph" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(text.text, "Stable heading\nA body paragraph")
        let headingAfter = try XCTUnwrap(text.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let bodyRange = (text.text as NSString).range(of: "A body paragraph")
        XCTAssertNotEqual(bodyRange.location, NSNotFound)
        let bodyAfter = try XCTUnwrap(text.attributedText.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(headingAfter.pointSize, headingBefore.pointSize, accuracy: 0.01)
        XCTAssertEqual(bodyAfter.pointSize, bodySize, accuracy: 0.01)
    }

    func testCodeParagraphBoundaryPreservesInteriorLinesWithoutExtraBlankLine() async {
        let source = "Before.\n\n```swift\nlet first = 1\n\nlet second = 2\n```\n\nAfter."
        let rendered = await MarkdownCache().format(source)
        XCTAssertEqual(String(rendered.characters), "Before.\nlet first = 1\n\nlet second = 2\nAfter.")
    }

}
