import UIKit
import Vision
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

    func testNestedListColumnsFitOrdinalsAtLargestTextSize() async throws {
        let cell = BubbleCell(style: .default, reuseIdentifier: "large-list")
        cell.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        cell.updateTraitsIfNeeded()
        cell.frame = CGRect(x: 0, y: 0, width: 375, height: 2500)
        let source = "99. **A** outer.\n100. B outer.\n\n     9. *C* inner.\n     10. D inner."
        let parsed = try AttributedString(markdown: source, options: .init(interpretedSyntax: .full))
        XCTAssertTrue(parsed.runs.contains { run in
            (run.presentationIntent?.components ?? []).filter {
                if case .orderedList = $0.kind { return true }
                return false
            }.count == 2
        }, "The fixture must contain a parsed nested list.")
        cell.configure(message(source, provisional: false))
        let text = try XCTUnwrap(textView(in: cell))
        for _ in 0..<100 {
            if text.text.contains("100.\tB") && !text.text.contains("**") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        cell.layoutIfNeeded()
        let font = try XCTUnwrap(text.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(font.pointSize, 30)
        var bodyRects: [CGRect] = []
        for fragment in ["99.\tA", "100.\tB", "9.\tC", "10.\tD"] {
            let found = (text.text as NSString).range(of: fragment)
            guard found.location != NSNotFound else {
                XCTFail("Expected rendered list fragment \(fragment), got \(text.text ?? "")")
                return
            }
            let start = try XCTUnwrap(text.position(from: text.beginningOfDocument, offset: found.location))
            let ordinalEnd = try XCTUnwrap(text.position(from: start, offset: 1))
            let bodyStart = try XCTUnwrap(text.position(from: start, offset: found.length - 1))
            let bodyEnd = try XCTUnwrap(text.position(from: bodyStart, offset: 1))
            let ordinal = text.firstRect(for: try XCTUnwrap(text.textRange(from: start, to: ordinalEnd)))
            let body = text.firstRect(for: try XCTUnwrap(text.textRange(from: bodyStart, to: bodyEnd)))
            XCTAssertTrue(ordinal.minY.isFinite && body.minY.isFinite)
            XCTAssertEqual(ordinal.minY, body.minY, accuracy: 0.5, "List marker must share its body's line at the largest text size.")
            bodyRects.append(body)
        }
        XCTAssertEqual(bodyRects[0].minX, bodyRects[1].minX, accuracy: 0.5)
        XCTAssertEqual(bodyRects[2].minX, bodyRects[3].minX, accuracy: 0.5)
        XCTAssertGreaterThan(bodyRects[2].minX, bodyRects[0].minX)
    }

    func testTallCanonicalReplyRendersFinalLineAtLatestInAttachedWindow() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKeyWindow = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        let controller = TranscriptController()
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        controller.updateChrome(viewportInsets: .init(top: 80, left: 0, bottom: 400, right: 0), activity: .idle)
        let lines = (1...50).map {
            "\($0). Keep a small basket near the door for keys, sunglasses, transit cards, and other items needed before leaving home each morning."
        }
        let marker = "FINAL VISIBLE MARKER"
        let source = lines.joined(separator: "\n") + "\n\n" + marker
        let revision = UUID()
        controller.update(messages: [message(source)], hasMore: false, loading: false, latestRevision: revision)
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        controller.update(messages: [message(source, provisional: false)], hasMore: false, loading: false, latestRevision: revision)
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        CATransaction.flush()

        let table = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
        let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)))
        let text = try XCTUnwrap(textView(in: cell))
        XCTAssertTrue(text.text.contains("50.\tKeep"), "The captured row must have completed Markdown list formatting.")
        XCTAssertTrue(text.text.hasSuffix(marker))
        XCTAssertGreaterThan(cell.bounds.height, window.bounds.height * 3)

        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let imageAttachment = XCTAttachment(image: screenshot)
        imageAttachment.name = "tall-canonical-reply-at-latest"
        imageAttachment.lifetime = .keepAlways
        add(imageAttachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(screenshot.cgImage)).perform([request])
        let visibleText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")

        let markerRange = (text.text as NSString).range(of: marker)
        let start = try XCTUnwrap(text.position(from: text.beginningOfDocument, offset: markerRange.location))
        let end = try XCTUnwrap(text.position(from: start, offset: markerRange.length))
        let range = try XCTUnwrap(text.textRange(from: start, to: end))
        let markerRect = text.firstRect(for: range)
        let markerOnScreen = text.convert(markerRect, to: window)
        let lastItem = (text.text as NSString).range(of: "50.\tKeep")
        let ordinalStart = try XCTUnwrap(text.position(from: text.beginningOfDocument, offset: lastItem.location))
        let ordinalEnd = try XCTUnwrap(text.position(from: ordinalStart, offset: 3))
        let bodyStart = try XCTUnwrap(text.position(from: ordinalStart, offset: 4))
        let bodyEnd = try XCTUnwrap(text.position(from: bodyStart, offset: 4))
        let ordinalRect = text.firstRect(for: try XCTUnwrap(text.textRange(from: ordinalStart, to: ordinalEnd)))
        let bodyRect = text.firstRect(for: try XCTUnwrap(text.textRange(from: bodyStart, to: bodyEnd)))
        let evidence: [String: Any] = [
            "window": NSCoder.string(for: window.bounds),
            "row": NSCoder.string(for: cell.frame),
            "textBounds": NSCoder.string(for: text.bounds),
            "textContentSize": NSCoder.string(for: text.contentSize),
            "textContainerSize": NSCoder.string(for: text.textContainer.size),
            "tableContentSize": NSCoder.string(for: table.contentSize),
            "tableOffset": NSCoder.string(for: table.contentOffset),
            "markerRect": NSCoder.string(for: markerRect),
            "markerOnScreen": NSCoder.string(for: markerOnScreen),
            "lastOrdinalRect": NSCoder.string(for: ordinalRect),
            "lastItemBodyRect": NSCoder.string(for: bodyRect),
            "fittingAtDisplayedWidth": NSCoder.string(for: text.sizeThatFits(CGSize(width: text.bounds.width, height: .greatestFiniteMagnitude))),
            "fittingAtMeasuredWidth": NSCoder.string(for: text.sizeThatFits(CGSize(width: table.bounds.width * 0.91, height: .greatestFiniteMagnitude))),
            "visibleText": visibleText,
            "textKit2": text.textLayoutManager != nil
        ]
        let geometryAttachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        geometryAttachment.name = "tall-canonical-reply-geometry.json"
        geometryAttachment.lifetime = .keepAlways
        add(geometryAttachment)
        XCTAssertTrue(visibleText.contains(marker), "The final line must be present in rendered pixels at Latest. OCR read: \(visibleText)")
        XCTAssertLessThanOrEqual(text.bounds.maxY - markerRect.maxY, text.textContainerInset.bottom + 2,
                                 "A long reply must not end in an oversized empty bubble.")
        XCTAssertGreaterThan(markerOnScreen.minY, 80)
        XCTAssertLessThanOrEqual(markerOnScreen.maxY, window.bounds.height - 400)
        XCTAssertEqual(ordinalRect.minY, bodyRect.minY, accuracy: 0.5,
                       "A two-digit list marker and its body must start on the same line.")
    }

}
