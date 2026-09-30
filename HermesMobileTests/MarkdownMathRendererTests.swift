import SwiftUI
import UIKit
import XCTest
import Observation
import MarkdownUI
import CoreText
#if DEBUG
import cmark_gfm
import cmark_gfm_extensions
#endif
@testable import HermesMobile

#if DEBUG
/// Feasibility proof only: no production consumers or cache. C nodes never escape.
private struct RenderBoundaryProof: Sendable {
    struct Block: Sendable {
        let kind: String
        let startLine: Int
        let endLine: Int
        let markdown: String
    }
    let copyBytes: [UInt8]
    let blocks: [Block]
    enum Failure: Error { case parser, serialization }

    init(_ source: String) throws {
        copyBytes = Array(source.utf8)
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { throw Failure.parser }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            guard let syntax = cmark_find_syntax_extension(name) else { throw Failure.parser }
            cmark_parser_attach_syntax_extension(parser, syntax)
        }
        cmark_parser_feed(parser, source, source.utf8.count)
        guard let document = cmark_parser_finish(parser) else { throw Failure.parser }
        defer { cmark_node_free(document) }
        var result: [Block] = []
        var child = cmark_node_first_child(document)
        while let node = child {
            child = cmark_node_next(node)
            // Independent blocks must not serialize separators for former siblings.
            cmark_node_unlink(node)
            defer { cmark_node_free(node) }
            guard let rendered = cmark_render_commonmark(node, CMARK_OPT_DEFAULT, 0) else { throw Failure.serialization }
            let markdown = String(cString: rendered)
            free(rendered)
            result.append(Block(kind: String(cString: cmark_node_get_type_string(node)),
                                startLine: Int(cmark_node_get_start_line(node)),
                                endLine: Int(cmark_node_get_end_line(node)), markdown: markdown))
        }
        blocks = result
    }
}

/// A direct, immutable copy of the public CMark tree. No C pointer or
/// serialized Markdown crosses the parser boundary.
private struct DirectCMarkDocument: Sendable {
    struct Node: Sendable {
        let kind: String
        let literal: String?
        let destination: String?
        let title: String?
        let startLine: Int
        let endLine: Int
        let listStart: Int
        let fenceInfo: String?
        let children: [Node]

        func descendants(of kind: String) -> [Node] {
            (self.kind == kind ? [self] : []) + children.flatMap { $0.descendants(of: kind) }
        }
    }

    let sourceBytes: [UInt8]
    let children: [Node]
    let html: String
    let unsupportedKinds: [String]

    enum Failure: Error { case parser, html }

    init(_ source: String) throws {
        sourceBytes = Array(source.utf8)
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { throw Failure.parser }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            guard let syntax = cmark_find_syntax_extension(name) else { throw Failure.parser }
            cmark_parser_attach_syntax_extension(parser, syntax)
        }
        cmark_parser_feed(parser, source, source.utf8.count)
        guard let document = cmark_parser_finish(parser) else { throw Failure.parser }
        defer { cmark_node_free(document) }
        guard let rendered = cmark_render_html(document, CMARK_OPT_DEFAULT, nil) else { throw Failure.html }
        html = String(cString: rendered)
        free(rendered)

        func copy(_ pointer: UnsafeMutablePointer<cmark_node>) -> Node {
            var children: [Node] = []
            var child = cmark_node_first_child(pointer)
            while let current = child {
                children.append(copy(current))
                child = cmark_node_next(current)
            }
            return Node(kind: String(cString: cmark_node_get_type_string(pointer)),
                        literal: cmark_node_get_literal(pointer).map(String.init(cString:)),
                        destination: cmark_node_get_url(pointer).map(String.init(cString:)),
                        title: cmark_node_get_title(pointer).map(String.init(cString:)),
                        startLine: Int(cmark_node_get_start_line(pointer)),
                        endLine: Int(cmark_node_get_end_line(pointer)),
                        listStart: Int(cmark_node_get_list_start(pointer)),
                        fenceInfo: cmark_node_get_fence_info(pointer).map(String.init(cString:)),
                        children: children)
        }
        var topLevel: [Node] = []
        var child = cmark_node_first_child(document)
        while let current = child {
            topLevel.append(copy(current))
            child = cmark_node_next(current)
        }
        children = topLevel
        let supported: Set<String> = ["paragraph", "text", "softbreak", "linebreak", "code", "emph", "strong", "strikethrough", "link", "code_block", "heading"]
        func unknown(_ node: Node) -> [String] {
            (supported.contains(node.kind) ? [] : [node.kind]) + node.children.flatMap(unknown)
        }
        unsupportedKinds = Array(Set(children.flatMap(unknown))).sorted()
    }
}

/// Test-only feasibility boundary: all CoreText objects live and die in one
/// actor operation. The returned line descriptors contain only value data.
private actor CoreTextLineLayoutProbe {
    struct Run: Sendable {
        let text: String
        let bold: Bool
        let italic: Bool
        let code: Bool
        let link: String?
        let strike: Bool
    }
    struct Line: Sendable, Equatable {
        let range: Range<Int>
        let top: Double
        let ascent: Double
        let descent: Double
        let leading: Double
        var height: Double { ascent + descent + leading }
    }
    struct Result: Sendable {
        let lineCount: Int
        let height: Double
        let lines: [Line]
        let runs: [Run]
        let isComplete: Bool
        let elapsedMS: Double
        let preparationMS: Double
    }

    func layout(_ node: DirectCMarkDocument.Node, width: Double, maxLines: Int? = nil) -> Result? {
        guard node.kind == "paragraph" || node.kind == "code_block" else { return nil }
        let start = CACurrentMediaTime()
        let attributed = NSMutableAttributedString(string: "")
        var runs: [Run] = []
        let base = UIFont.systemFont(ofSize: 16).fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 16) } ?? UIFont.systemFont(ofSize: 16)
        func append(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil, strike: Bool = false) {
            var font = code ? UIFont.monospacedSystemFont(ofSize: 14.08, weight: .regular) : base
            if bold || italic {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if bold { traits.insert(.traitBold) }
                if italic { traits.insert(.traitItalic) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let link, let url = URL(string: link) { attributes[.link] = url }
            if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            attributed.append(NSAttributedString(string: text, attributes: attributes))
            runs.append(Run(text: text, bold: bold, italic: italic, code: code, link: link, strike: strike))
        }
        func visit(_ node: DirectCMarkDocument.Node, bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil, strike: Bool = false) {
            switch node.kind {
            case "text", "code": append(node.literal ?? "", bold: bold, italic: italic, code: code || node.kind == "code", link: link, strike: strike)
            case "softbreak": append("\n", bold: bold, italic: italic, code: code, link: link, strike: strike)
            case "linebreak": append("\n", bold: bold, italic: italic, code: code, link: link, strike: strike)
            case "emph", "strong", "strikethrough", "link", "paragraph":
                for child in node.children {
                    visit(child, bold: bold || node.kind == "strong", italic: italic || node.kind == "emph", code: code,
                          link: node.kind == "link" ? node.destination : link, strike: strike || node.kind == "strikethrough")
                }
            default: break
            }
        }
        if node.kind == "code_block" {
            append(node.literal ?? "", code: true)
        } else {
            visit(node)
        }
        let prepared = CACurrentMediaTime()
        let typesetter = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
        var offset = 0
        var lineCount = 0
        var height = 0.0
        var lines: [Line] = []
        while offset < attributed.length && (maxLines == nil || lineCount < maxLines!) {
            let proposed = CTTypesetterSuggestLineBreak(typesetter, offset, width)
            let count = max(1, proposed)
            let line = CTTypesetterCreateLine(typesetter, CFRangeMake(offset, count))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            lines.append(Line(range: offset..<(offset + count), top: height,
                              ascent: Double(ascent), descent: Double(descent), leading: Double(leading)))
            height += Double(ascent + descent + leading)
            offset += count
            lineCount += 1
        }
        let finished = CACurrentMediaTime()
        return Result(lineCount: lineCount, height: height, lines: lines, runs: runs, isComplete: offset >= attributed.length,
                      elapsedMS: (finished - start) * 1_000, preparationMS: (prepared - start) * 1_000)
    }
}

/// Mounted drawing proof, not a replacement renderer: selection and the
/// production code-block controls are intentionally not claimed here.
@MainActor
private final class DirectCoreTextViewport: UIView {
    let layout: CoreTextLineLayoutProbe.Result
    let attributed: NSAttributedString
    let typesetter: CTTypesetter
    var visibleTop: Double = 0 { didSet { setNeedsDisplay(); rebuildAccessibility() } }
    private(set) var lastDrawLineCount = 0
    private(set) var lastDrawMS = 0.0

    init(layout: CoreTextLineLayoutProbe.Result, frame: CGRect) {
        self.layout = layout
        let output = NSMutableAttributedString(string: "")
        let base = UIFont.systemFont(ofSize: 16).fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 16) } ?? UIFont.systemFont(ofSize: 16)
        for run in layout.runs {
            var font = run.code ? UIFont.monospacedSystemFont(ofSize: 14.08, weight: .regular) : base
            if run.bold || run.italic {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if run.bold { traits.insert(.traitBold) }
                if run.italic { traits.insert(.traitItalic) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: run.link == nil ? UIColor.label : UIColor.systemBlue]
            if let link = run.link, let url = URL(string: link) { attributes[.link] = url }
            if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            output.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        attributed = output
        typesetter = CTTypesetterCreateWithAttributedString(output as CFAttributedString)
        super.init(frame: frame)
        backgroundColor = .white
        isOpaque = true
        isAccessibilityElement = false
        rebuildAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("DirectCoreTextViewport is test-only") }

    override func draw(_ rect: CGRect) {
        let start = CACurrentMediaTime()
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let lower = visibleTop
        let upper = visibleTop + Double(bounds.height)
        var count = 0
        for descriptor in layout.lines where descriptor.top + descriptor.height > lower && descriptor.top < upper {
            let range = descriptor.range
            let line = CTTypesetterCreateLine(typesetter, CFRangeMake(range.lowerBound, range.count))
            context.textPosition = CGPoint(x: 0, y: bounds.height - CGFloat(descriptor.top - visibleTop + descriptor.ascent))
            CTLineDraw(line, context)
            count += 1
        }
        lastDrawLineCount = count
        lastDrawMS = (CACurrentMediaTime() - start) * 1_000
    }

    private func rebuildAccessibility() {
        let lower = visibleTop
        let upper = visibleTop + Double(bounds.height)
        accessibilityElements = layout.lines.compactMap { descriptor -> UIAccessibilityElement? in
            guard descriptor.top + descriptor.height > lower && descriptor.top < upper else { return nil }
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = (attributed.string as NSString).substring(with: NSRange(location: descriptor.range.lowerBound, length: descriptor.range.count))
            element.accessibilityFrameInContainerSpace = CGRect(x: 0, y: descriptor.top - lower, width: Double(bounds.width), height: descriptor.height)
            element.accessibilityTraits = .staticText
            return element
        }
    }
}

#endif

final class MarkdownMathRendererTests: XCTestCase {
#if DEBUG
    @MainActor
    func testDocumentCacheReusesRichDocumentAcrossRepeatedRequests() {
        let source = """
        # Rich response

        [Reference][ref] with **bold**, `inline code`, and العربية 👩🏽‍💻.

        | Name | Value |
        | --- | --- |
        | one | two |

        ```swift
        \(String(repeating: "let value = 123 // full source\n", count: 300))
        ```

        [ref]: https://example.com/reference
        """
        let expected = MarkdownContent(source)
        let cache = MarkdownDocumentCache()
        for _ in 0..<20 {
            let actual = cache.document(for: source)
            XCTAssertEqual(actual.renderHTML(), expected.renderHTML())
            XCTAssertEqual(actual.renderPlainText(), expected.renderPlainText())
        }
        XCTAssertEqual(cache.preparationCount, 1, "Repeated view evaluation must not reparse unchanged source")
        XCTAssertEqual(cache.retainedSourceBytes, source.utf8.count)
    }

    @MainActor
    func testDocumentCacheReplacesStreamingAndSameLengthRevisions() {
        let cache = MarkdownDocumentCache()
        let revisions = [
            "```swift\nlet value = 1",
            "```swift\nlet value = 12\n```",
            "[one](https://example.com/a)",
            "[two](https://example.com/b)",
            "| A | B |\n| --- | --- |\n| C | D |",
            "replacement",
            ""
        ]
        for (index, source) in revisions.enumerated() {
            XCTAssertEqual(cache.document(for: source).renderHTML(), MarkdownContent(source).renderHTML())
            XCTAssertEqual(cache.preparationCount, index + 1)
            XCTAssertEqual(cache.retainedSourceBytes, source.utf8.count)
        }
        _ = cache.document(for: revisions[0])
        XCTAssertEqual(cache.preparationCount, revisions.count + 1, "Only the current revision may be retained")
    }

    @MainActor
    func testDocumentCacheBoundsBytesAndPreservesUnicodeSource() {
        let cache = MarkdownDocumentCache()
        let composed = "`caf\u{e9}`"
        let decomposed = "`cafe\u{301}`"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        _ = cache.document(for: composed)
        let replacement = cache.document(for: decomposed)
        XCTAssertEqual(Array(replacement.renderPlainText().utf8),
                       Array(MarkdownContent(decomposed).renderPlainText().utf8))
        XCTAssertEqual(cache.preparationCount, 2)

        let limit = MarkdownDocumentCache.maximumSourceBytes
        let atLimit = String(repeating: "x", count: limit)
        _ = cache.document(for: atLimit)
        _ = cache.document(for: atLimit)
        XCTAssertEqual(cache.preparationCount, 3)
        XCTAssertEqual(cache.retainedSourceBytes, limit)
        let oversized = String(repeating: "é", count: limit / 2 + 1)
        XCTAssertLessThan(oversized.count, limit)
        for _ in 0..<2 {
            XCTAssertEqual(cache.document(for: oversized).renderPlainText(),
                           MarkdownContent(oversized).renderPlainText())
            XCTAssertEqual(cache.retainedSourceBytes, 0)
        }
        XCTAssertEqual(cache.preparationCount, 5, "Oversized documents must not be retained")
    }

    @MainActor
    func testDocumentCachePreservesExistingMathSegmentationOutput() {
        let source = "Before $\\alpha$ and [link](https://example.com).\n\n$$x^2$$\n\n```math\nx^2\n```"
        let cache = MarkdownDocumentCache()
        for segment in MarkdownMathSegmenter.segments(in: source) {
            guard case .markdown(let markdown) = segment else { continue }
            XCTAssertEqual(cache.document(for: markdown).renderHTML(), MarkdownContent(markdown).renderHTML())
        }
    }
#endif

    func testMathDelimiterFreeFastPathsPreserveExactText() {
        let samples = ["", " ", "Plain **Markdown** with `code`.",
                       "emoji 👩🏽‍💻 العربية 中文\r\nnext\u{2028}line",
                       "```swift\nlet result = values.map { value in value + 1 }\n```",
                       String(repeating: "Long paragraph without math. ", count: 1_000)]
        for source in samples {
            XCTAssertEqual(MarkdownMathFormatter.replacingInlineMath(in: source), source)
            XCTAssertEqual(MarkdownMathSegmenter.segments(in: source), [.markdown(source)])
        }
    }

    func testNoDisplayDelimiterStillRunsInlineAndCodeProtectionRules() {
        let source = #"Inline $x^2$ and \(y_1\), protected `$z^2$`."#
        XCTAssertEqual(MarkdownMathSegmenter.segments(in: source),
                       [.markdown(MarkdownMathFormatter.replacingInlineMath(in: source))])
        let fenced = "```swift\nlet value = rows.reduce(0) { $0 + $1.height }\n```"
        XCTAssertEqual(MarkdownMathSegmenter.segments(in: fenced), [.markdown(fenced)])
        for display in ["$$x^2$$", #"\[x^2\]"#] {
            XCTAssertTrue(MarkdownMathSegmenter.segments(in: display).containsMath)
        }
    }
#if DEBUG
    @MainActor
    func testNativeRichRowTwentyDistinctPreparationCostEvidence() async throws {
        let indices = ChatStableViewportPrototype.Controller.nativeRichPilotIndices
        XCTAssertEqual(indices.count, 20)
        let sources = indices.map { index in
            "## Response \(index)\n\nA **readable** explanation with `inline code`, العربية and Unicode 👩🏽‍💻.\n\n- Preserve the current reader position.\n- Keep the completed result available.\n\n```swift\nlet answer = values.map { $0 + \(index) }\nprint(answer)\n```\n\n| Check | State |\n| --- | --- |\n| Rendering | Ready |\n\n\(index == 119 ? "Representative conversation complete." : "Continue the review.")"
        }
        var rows: [[Double]] = []
        var walls: [Double] = []
        for _ in 0..<2 {
            var measurements: [Double] = []
            let passStart = CACurrentMediaTime()
            for (index, source) in zip(indices, sources) {
                let result = await NativeRichRowPreparationActor.shared.prepare(source: source, width: 322, dark: true)
                guard case .ready(let snapshot) = result else { return XCTFail("Distinct representative row unexpectedly fell back: \(result)") }
                XCTAssertEqual(snapshot.sourceBytes, Array(source.utf8))
                XCTAssertTrue(snapshot.blocks.flatMap(\.lines).map(\.text).joined().contains("Response \(index)"))
                XCTAssertEqual(snapshot.blocks.filter { $0.kind == .code }.count, 1)
                XCTAssertEqual(snapshot.blocks.filter { $0.kind == .table }.count, 1)
                let canvas = NativeRichRowCanvas(frame: CGRect(x: 0, y: 0, width: 322, height: snapshot.height))
                canvas.snapshot = snapshot
                XCTAssertEqual(canvas.subviews.compactMap { $0 as? UIButton }.count, 2)
                XCTAssertTrue((canvas.accessibilityElements?.count ?? 0) >= snapshot.blocks.flatMap(\.lines).count + 2)
                measurements.append(snapshot.preparationMS)
            }
            rows.append(measurements)
            walls.append((CACurrentMediaTime() - passStart) * 1_000)
        }
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "first=%.1f median=%.1f p95=%.1f sum=%.1f", values[0], sorted[sorted.count / 2], sorted[18], values.reduce(0, +))
        }
        let report = "20 distinct rich assistant rows, width=322 dark, same actor; no snapshot cache.\nCold: \(stats(rows[0])) wall=\(String(format: "%.1f", walls[0]))ms\nWarm: \(stats(rows[1])) wall=\(String(format: "%.1f", walls[1]))ms\nCold per row: \(rows[0].map { String(format: "%.1f", $0) }.joined(separator: ","))\nWarm per row: \(rows[1].map { String(format: "%.1f", $0) }.joined(separator: ","))"
        let attachment = XCTAttachment(string: report)
        attachment.name = "native-rich-20-row-preparation"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("NATIVE_RICH_20_COST \(report.replacingOccurrences(of: "\n", with: " | "))")
    }

    @MainActor
    func testNativeRichRowRepresentativeSnapshotAndMountedGeometry() async throws {
        let source = "## Response 119\n\nA **readable** explanation with `inline code`, العربية and Unicode 👩🏽‍💻.\n\n- Preserve the current reader position.\n- Keep the completed result available.\n\n```swift\nlet answer = values.map { $0 + 119 }\nprint(answer)\n```\n\n| Check | State |\n| --- | --- |\n| Rendering | Ready |\n\nRepresentative conversation complete."
        let result = await NativeRichRowPreparationActor.shared.prepare(source: source, width: 340, dark: false)
        guard case .ready(let snapshot) = result else { return XCTFail("Representative fixture must not silently fall back: \(result)") }
        XCTAssertEqual(snapshot.sourceBytes, Array(source.utf8))
        XCTAssertGreaterThan(snapshot.height, 250)
        XCTAssertEqual(snapshot.blocks.filter { $0.kind == .code }.count, 1)
        XCTAssertEqual(snapshot.blocks.filter { $0.kind == .table }.count, 1)
        let visibleText = snapshot.blocks.flatMap(\.lines).map(\.text).joined(separator: " ")
        for expected in ["Response 119", "readable", "العربية", "👩🏽‍💻", "Preserve the current reader", "let answer", "Rendering", "Ready", "Representative conversation complete."] {
            XCTAssertTrue(visibleText.contains(expected), "Missing mounted semantic text: \(expected)")
        }
        let canvas = NativeRichRowCanvas(frame: CGRect(x: 0, y: 0, width: 340, height: snapshot.height))
        canvas.snapshot = snapshot
        XCTAssertEqual(canvas.accessibilityIdentifier, "native-rich-row")
        XCTAssertEqual(canvas.subviews.compactMap { $0 as? UIButton }.count, 2)
        XCTAssertEqual(canvas.accessibilityElements?.count, snapshot.blocks.flatMap(\.lines).count + 2)
        XCTAssertEqual(canvas.intrinsicContentSize.height, UIView.noIntrinsicMetric)
        let image = UIGraphicsImageRenderer(size: canvas.bounds.size).image { _ in canvas.drawHierarchy(in: canvas.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "native-rich-one-row-proof"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("NATIVE_RICH_ROW_ONE width=340 height=\(snapshot.height) blocks=\(snapshot.blocks.count) prepMS=\(snapshot.preparationMS) ax=\(canvas.accessibilityElements?.count ?? -1)")
    }

    @MainActor
    func testNativeRichCodeWrapAndHorizontalGeometryShareOriginalSource() async throws {
        let source = "## Response 119\n\n```swift\nlet horizontalProbe = \"START\" + "
            + String(repeating: "\"segment\" + ", count: 15) + "\"FAR_END_MARKER\"\n```\n"
        let unwrappedResult = await NativeRichRowPreparationActor.shared.prepare(source: source, width: 322, dark: true)
        let wrappedResult = await NativeRichRowPreparationActor.shared.prepare(source: source, width: 322, dark: true, wrapsCodeLines: true)
        guard case .ready(let unwrapped) = unwrappedResult, case .ready(let wrapped) = wrappedResult,
              let plainCode = unwrapped.blocks.first(where: { $0.kind == .code }),
              let wrappedCode = wrapped.blocks.first(where: { $0.kind == .code }) else {
            return XCTFail("Both code geometries must prepare before mounting")
        }
        XCTAssertEqual(unwrapped.sourceBytes, Array(source.utf8))
        XCTAssertEqual(wrapped.sourceBytes, Array(source.utf8))
        XCTAssertFalse(unwrapped.wrapsCodeLines)
        XCTAssertTrue(wrapped.wrapsCodeLines)
        XCTAssertTrue(plainCode.lines.contains(where: { $0.frame.maxX > plainCode.frame.maxX + 100 }),
                      "Unwrapped code must have real offscreen horizontal content")
        XCTAssertGreaterThan(wrappedCode.lines.count, plainCode.lines.count)
        XCTAssertGreaterThan(wrapped.height, unwrapped.height + 50)
        XCTAssertTrue(wrappedCode.lines.map(\.text).joined().contains("FAR_END_MARKER"))
        XCTAssertEqual(unwrapped.blocks.flatMap(\.lines).map(\.text).joined().contains("FAR_END_MARKER"), true)
    }

    @MainActor
    func testNativeRichRowLinkBiDiAndUnsupportedFailClosed() async throws {
        let source = String(repeating: "A long English prefix ", count: 4) + "[العربية 👩🏽‍💻](https://example.org/path) then **bold** and ~~strike~~."
        let result = await NativeRichRowPreparationActor.shared.prepare(source: source, width: 340, dark: false)
        guard case .ready(let snapshot) = result else { return XCTFail("Inline semantics unexpectedly unsupported: \(result)") }
        XCTAssertEqual(snapshot.sourceBytes, Array(source.utf8))
        let links = snapshot.blocks.flatMap(\.lines).flatMap(\.links)
        XCTAssertGreaterThanOrEqual(links.count, 1)
        XCTAssertEqual(links.first?.url, "https://example.org/path")
        XCTAssertGreaterThan(links.first?.rect.width ?? 0, 10)
        XCTAssertGreaterThan(links.first?.rect.minY ?? 0, snapshot.blocks.first?.lines.first?.frame.minY ?? 0,
                             "BiDi link must map to its later visual line, not the first line's local index")
        let canvas = NativeRichRowCanvas(frame: CGRect(x: 0, y: 0, width: 340, height: snapshot.height))
        canvas.snapshot = snapshot
        var opened: URL?
        canvas.onOpenLink = { opened = $0 }
        XCTAssertTrue(canvas.activateLink(at: CGPoint(x: links[0].rect.midX, y: links[0].rect.midY)))
        XCTAssertEqual(opened?.absoluteString, "https://example.org/path")
        XCTAssertFalse(canvas.activateLink(at: CGPoint(x: 1, y: snapshot.height - 1)))
        XCTAssertTrue(snapshot.blocks.flatMap(\.lines).flatMap(\.runs).contains(where: { $0.strike && $0.text == "strike" }))
        let unsupported = await NativeRichRowPreparationActor.shared.prepare(source: "![alt](image.png)", width: 340, dark: false)
        guard case .unsupported(let kinds) = unsupported else { return XCTFail("Image must visibly fall back") }
        XCTAssertTrue(kinds.contains("image"))
        let nested = await NativeRichRowPreparationActor.shared.prepare(source: "- parent\n  - child\n", width: 340, dark: false)
        guard case .unsupported(let nestedKinds) = nested else { return XCTFail("Nested list must not silently flatten") }
        XCTAssertTrue(nestedKinds.contains("nested-list"))
    }

    @MainActor
    func testPublicParagraphFragmentFeasibilityIncludesPreparation() throws {
        let source = String(repeating: "A **rich** paragraph with العربية 👩🏽‍💻 and `inline code`. ", count: 700)
        let copyBytes = Array(source.utf8)
        for run in 0..<2 {
            let start = CACurrentMediaTime()
            let parsed = try AttributedString(markdown: source)
            let parsedAt = CACurrentMediaTime()
            let plain = String(parsed.characters)
            XCTAssertEqual(plain, MarkdownContent(source).renderPlainText().trimmingCharacters(in: .newlines))
            let attributed = NSMutableAttributedString(string: plain)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 16 * 0.18
            attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
            var offset = 0
            for part in parsed.runs {
                let length = String(parsed[part.range].characters).utf16.count
                let range = NSRange(location: offset, length: length)
                let intent = part.inlinePresentationIntent ?? []
                var descriptor = UIFont.systemFont(ofSize: 16).fontDescriptor.withDesign(.rounded)!
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if !traits.isEmpty { descriptor = descriptor.withSymbolicTraits(traits)! }
                let font = intent.contains(.code) ? UIFont.monospacedSystemFont(ofSize: 16 * 0.88, weight: .regular) : UIFont(descriptor: descriptor, size: 16)
                attributed.addAttribute(.font, value: font, range: range)
                if let link = part.link { attributed.addAttribute(.link, value: link, range: range) }
                if intent.contains(.strikethrough) { attributed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
                offset += length
            }
            let preparedAt = CACurrentMediaTime()
            let content = NSTextContentStorage()
            let layout = NSTextLayoutManager()
            content.addTextLayoutManager(layout)
            let container = NSTextContainer(size: CGSize(width: 370, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.textContainer = container
            content.textStorage?.setAttributedString(attributed)
            let setupAt = CACurrentMediaTime()
            layout.ensureLayout(for: CGRect(x: 0, y: 0, width: 370, height: 600))
            let laidOutAt = CACurrentMediaTime()
            var fragments = 0
            var lines = 0
            var height: CGFloat = 0
            layout.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
                fragments += 1
                lines += fragment.textLineFragments.count
                height = max(height, fragment.layoutFragmentFrame.maxY)
                return false
            }
            XCTAssertGreaterThan(lines, 0)
            XCTAssertEqual(content.textStorage?.string, plain)
            XCTAssertEqual(copyBytes, Array(source.utf8))
            print("FRAGMENT_COST run=\(run) parseMS=\((parsedAt-start)*1000) mapMS=\((preparedAt-parsedAt)*1000) setupMS=\((setupAt-preparedAt)*1000) layoutMS=\((laidOutAt-setupAt)*1000) totalMS=\((laidOutAt-start)*1000) fragments=\(fragments) lines=\(lines) fragmentHeight=\(height) viewportHeight=600 bytes=\(copyBytes.count)")
        }
    }

    func testPublicParagraphAttributedSemantics() throws {
        let source = "**bold** *italic* `code` [link][late] العربية 👩🏽‍💻 e\u{301}\n\n[late]: https://example.invalid/path\n"
        let value = try AttributedString(markdown: source)
        XCTAssertEqual(String(value.characters), MarkdownContent(source).renderPlainText().trimmingCharacters(in: .newlines))
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(value.runs.contains { $0.link?.absoluteString == "https://example.invalid/path" })
    }

    func testRenderBoundaryPreservesFullDocumentSemanticsAndCopyBytes() throws {
        let samples = [
            "[early][later]\n\n[later]: https://example.invalid/path \"title\"\n",
            "- tight\n  - nested **bold**\n- next\n\n1. loose\n\n   paragraph\n\n2. next\n\n- [x] done\n- [ ] pending\n",
            "Setext\n======\n\n~~~swift\nlet text = \"```\"\n~~~\n\n```math\nx^2\n```\n",
            "| left | right |\n| :--- | ---: |\n| العربية | 👩🏽‍💻 中文 |\n\n> quote\n>\n> second\n",
            "Original  spaces\r\n\r\nUnicode e\u{301} 👩🏽‍💻 العربية\n\n---\n"
        ]
        for source in samples {
            let document = try RenderBoundaryProof(source)
            XCTAssertEqual(document.copyBytes, Array(source.utf8))
            XCTAssertEqual(document.blocks.map { MarkdownContent($0.markdown).renderHTML() }.joined(),
                           MarkdownContent(source).renderHTML(), source)
        }
    }

    func testRenderBoundaryMathUsesExistingSegmentationBeforeParsing() throws {
        let source = "Before $x_1$.\n\n$$x^2$$\n\nAfter \\(y\\).\n"
        for segment in MarkdownMathSegmenter.segments(in: source) {
            if case .markdown(let markdown) = segment {
                let document = try RenderBoundaryProof(markdown)
                XCTAssertEqual(document.blocks.map { MarkdownContent($0.markdown).renderHTML() }.joined(), MarkdownContent(markdown).renderHTML())
            }
        }
        XCTAssertEqual(Array(source.utf8), try RenderBoundaryProof(source).copyBytes)
    }

    func testRenderBoundaryRecordsNestedListSerializationLimitation() throws {
        // A negative feasibility gate, not accepted semantic parity. Detaching the
        // top-level block cannot remove the serializer's nested sibling context.
        let source = "> - unordered\n>\n> 1. ordered\n"
        let document = try RenderBoundaryProof(source)
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertTrue(document.blocks[0].markdown.contains("<!-- end list -->"))
        XCTAssertNotEqual(MarkdownContent(document.blocks[0].markdown).renderHTML(),
                          MarkdownContent(source).renderHTML())
        XCTAssertEqual(document.copyBytes, Array(source.utf8))
    }

    func testDirectCMarkSnapshotPreservesNestedSemanticsWithoutRoundTrip() throws {
        let samples = [
            "> - unordered\n>\n> 1. ordered\n",
            "- tight\n  - nested **bold**\n- next\n\n1. loose\n\n   paragraph\n\n2. next\n\n- [x] done\n- [ ] pending\n",
            "| left | right |\n| :--- | ---: |\n| العربية | 👩🏽‍💻 中文 |\n",
            "[early][later] and ~~strike~~ e\u{301} שלום\n\n[later]: https://example.invalid/path \"title\"\n",
            "```swift\nlet value = 42\n```\n"
        ]
        for source in samples {
            let snapshot = try DirectCMarkDocument(source)
            XCTAssertEqual(snapshot.sourceBytes, Array(source.utf8))
            if source.hasPrefix("| left") || source.hasPrefix("[early]") {
                // MarkdownUI's BlockNode reconstruction drops table cell HTML
                // and link titles. The direct AST deliberately retains them;
                // HTML strings are not a valid equivalence oracle here.
                XCTAssertNotEqual(snapshot.html, MarkdownContent(source).renderHTML(), source)
            } else {
                XCTAssertEqual(snapshot.html, MarkdownContent(source).renderHTML(), source)
            }
            XCTAssertFalse(snapshot.children.isEmpty)
            XCTAssertTrue(snapshot.children.allSatisfy { $0.startLine > 0 && $0.endLine >= $0.startLine })
            if source.hasPrefix("> - unordered") {
                let lists = snapshot.children.flatMap { $0.descendants(of: "list") }
                XCTAssertEqual(lists.count, 2)
                XCTAssertFalse(snapshot.html.contains("<!-- end list -->"))
                XCTAssertTrue(snapshot.unsupportedKinds.contains("block_quote"), "Nested block remains an explicit renderer fallback")
            }
            if source.hasPrefix("[early]") {
                let links = snapshot.children.flatMap { $0.descendants(of: "link") }
                XCTAssertEqual(links.map(\.destination), ["https://example.invalid/path"])
                XCTAssertEqual(links.map(\.title), ["title"])
                XCTAssertFalse(snapshot.unsupportedKinds.contains("link"))
            }
            if source.hasPrefix("```swift") {
                XCTAssertEqual(snapshot.children[0].literal, "let value = 42\n")
                XCTAssertEqual(snapshot.children[0].fenceInfo, "swift")
            }
            print("DIRECT_CMARK_SEMANTICS bytes=\(snapshot.sourceBytes.count) blocks=\(snapshot.children.count) fallback=\(snapshot.unsupportedKinds)")
        }
    }

    func testDirectCMarkLayoutCorpusSeparatesRichInlineDataFromFallbackBlocks() async throws {
        let rich = "**bold** *italic* `code` [link][late] ~~gone~~ العربية 👩🏽‍💻 e\u{301} שלום\n\n[late]: https://example.invalid/path \"title\"\n"
        let richDocument = try DirectCMarkDocument(rich)
        let paragraph = try XCTUnwrap(richDocument.children.first)
        let measured = await CoreTextLineLayoutProbe().layout(paragraph, width: 370)
        let layout = try XCTUnwrap(measured)
        XCTAssertEqual(richDocument.sourceBytes, Array(rich.utf8))
        let directText = layout.runs.map(\.text).joined()
        XCTAssertEqual(directText, "bold italic code link gone العربية 👩🏽‍💻 e\u{301} שלום")
        XCTAssertNotEqual(directText, MarkdownContent(rich).renderPlainText().trimmingCharacters(in: .newlines),
                          "MarkdownUI plain-text serialization inserts tildes for strike; it is not a source or selection oracle")
        XCTAssertTrue(layout.runs.contains { $0.bold && $0.text == "bold" })
        XCTAssertTrue(layout.runs.contains { $0.italic && $0.text == "italic" })
        XCTAssertTrue(layout.runs.contains { $0.code && $0.text == "code" })
        XCTAssertTrue(layout.runs.contains { $0.strike && $0.text == "gone" })
        XCTAssertEqual(layout.runs.compactMap(\.link), ["https://example.invalid/path"])
        XCTAssertTrue(layout.isComplete)
        XCTAssertFalse(layout.lines.isEmpty)
        print("DIRECT_CORETEXT_INLINE bytes=\(rich.utf8.count) lines=\(layout.lineCount) layoutMS=\(layout.elapsedMS) links=\(layout.runs.compactMap(\.link).count)")

        let unsupported = [
            ("nested-list", "> - unordered\n>\n> 1. ordered\n", "list"),
            ("table", "| A | B |\n| --- | --- |\n| left | right |\n", "table"),
            ("image", "![image](https://example.invalid/asset.png)\n", "image")
        ]
        for (name, source, kind) in unsupported {
            let document = try DirectCMarkDocument(source)
            XCTAssertEqual(document.sourceBytes, Array(source.utf8))
            XCTAssertTrue(document.unsupportedKinds.contains(kind), "\(name) must visibly use the existing renderer, not disappear")
            XCTAssertNotNil(document.children.first)
            print("DIRECT_CMARK_FALLBACK name=\(name) kinds=\(document.unsupportedKinds)")
        }
    }

    @MainActor
    func testDirectCMarkCoreTextGiantBlockLayoutGate() async throws {
        let fixtures = [
            ("paragraph", String(repeating: "A **rich** paragraph with العربية 👩🏽‍💻 and `inline code`. ", count: 700)),
            ("code", "```swift\n" + String(repeating: "let value = items.map { $0.description }\n", count: 1500) + "```\n")
        ]
        let worker = CoreTextLineLayoutProbe()
        for (name, source) in fixtures {
            let snapshot = try DirectCMarkDocument(source)
            XCTAssertEqual(snapshot.children.count, 1)
            XCTAssertTrue(snapshot.unsupportedKinds.isEmpty, "Only supported direct nodes may enter CoreText proof")
            let node = snapshot.children[0]
            let measured = await worker.layout(node, width: 370)
            let result = try XCTUnwrap(measured)
            let prefixMeasured = await worker.layout(node, width: 370, maxLines: 40)
            let prefix = try XCTUnwrap(prefixMeasured)
            let host = UIHostingController(rootView: MarkdownRenderer(content: source).frame(width: 370))
            let rendererStart = CACurrentMediaTime()
            let reference = host.sizeThatFits(in: CGSize(width: 370, height: CGFloat.greatestFiniteMagnitude))
            let rendererMS = (CACurrentMediaTime() - rendererStart) * 1_000
            XCTAssertGreaterThan(result.lineCount, 500)
            XCTAssertEqual(prefix.lineCount, 40)
            XCTAssertFalse(prefix.isComplete)
            XCTAssertEqual(prefix.lines.first?.range.lowerBound, 0)
            XCTAssertEqual(prefix.lines, Array(result.lines.prefix(40)), "Prefix layout must be stable when the full document finishes")
            XCTAssertEqual(snapshot.sourceBytes, Array(source.utf8))
            print("DIRECT_CORETEXT_LAYOUT name=\(name) bytes=\(source.utf8.count) lines=\(result.lineCount) prefixMS=\(prefix.elapsedMS) prefixPrepareMS=\(prefix.preparationMS) fullMS=\(result.elapsedMS) ctHeight=\(result.height) rendererFitMS=\(rendererMS) rendererHeight=\(reference.height) heightDelta=\(result.height - Double(reference.height))")
            XCTAssertGreaterThan(abs(result.height - Double(reference.height)), 0.5,
                                 "Old SwiftUI geometry must never be mixed with this new CoreText layout")
        }
    }

    @MainActor
    func testDirectCoreTextMountedVisibleLineDrawingProof() async throws {
        let fixtures = [
            ("paragraph", String(repeating: "A **rich** paragraph with العربية 👩🏽‍💻 and `inline code`. ", count: 700)),
            ("code", "```swift\n" + String(repeating: "let value = items.map { $0.description }\n", count: 1500) + "```\n")
        ]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 370, height: 600)
        window.backgroundColor = .white
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        let worker = CoreTextLineLayoutProbe()
        for (name, source) in fixtures {
            let node = try XCTUnwrap(DirectCMarkDocument(source).children.first)
            let measured = await worker.layout(node, width: 370)
            let result = try XCTUnwrap(measured)
            let container = UIViewController()
            window.rootViewController = container
            window.makeKeyAndVisible()
            container.view.frame = window.bounds
            let mountStart = CACurrentMediaTime()
            let viewport = DirectCoreTextViewport(layout: result, frame: window.bounds)
            container.view.addSubview(viewport)
            let mountMS = (CACurrentMediaTime() - mountStart) * 1_000
            for (position, top) in [("top", 0.0), ("middle", result.height / 2)] {
                viewport.visibleTop = top
                viewport.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "direct-coretext-\(name)-\(position)"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertGreaterThan(viewport.lastDrawLineCount, 0)
                XCTAssertLessThan(viewport.lastDrawLineCount, 50, "Only viewport lines may draw")
                let accessible = viewport.accessibilityElements as? [UIAccessibilityElement] ?? []
                XCTAssertEqual(accessible.count, viewport.lastDrawLineCount)
                XCTAssertTrue(accessible.allSatisfy { !($0.accessibilityLabel ?? "").isEmpty })
                print("DIRECT_CORETEXT_MOUNT name=\(name) position=\(position) mountMS=\(mountMS) drawMS=\(viewport.lastDrawMS) drawnLines=\(viewport.lastDrawLineCount) axLines=\(accessible.count) totalHeight=\(result.height)")
            }
            viewport.removeFromSuperview()
        }
    }

    @MainActor
    func testTextKitOneCodeSelectionGeometryFeasibility() throws {
        let line = "let value = items.map { $0.description }\n"
        let source = String(repeating: line, count: 1500)
        let attributed = NSMutableAttributedString(string: source, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: UIColor.label
        ])
        let keyword = "let" as NSString
        let nsSource = source as NSString
        for row in 0..<1500 {
            let index = row * (line as NSString).length
            if index + keyword.length <= attributed.length {
                attributed.addAttribute(.foregroundColor, value: UIColor.systemPurple, range: NSRange(location: index, length: keyword.length))
            }
        }
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 370, height: 600))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.backgroundColor = .white
        let setStart = CACurrentMediaTime()
        textView.attributedText = attributed
        let setMS = (CACurrentMediaTime() - setStart) * 1_000
        let fitStart = CACurrentMediaTime()
        let fit = textView.sizeThatFits(CGSize(width: 370, height: CGFloat.greatestFiniteMagnitude))
        let fitMS = (CACurrentMediaTime() - fitStart) * 1_000
        XCTAssertGreaterThan(fit.height, 20_000)
        XCTAssertEqual(textView.text, nsSource as String)
        XCTAssertTrue(textView.isSelectable)
        textView.selectedRange = NSRange(location: 0, length: 3)
        XCTAssertEqual((textView.text as NSString).substring(with: textView.selectedRange), "let")
        print("TEXTKIT1_CODE_FEASIBILITY bytes=\(source.utf8.count) setMS=\(setMS) fitMS=\(fitMS) height=\(fit.height) axLabelLength=\(textView.accessibilityLabel?.count ?? -1)")
    }

    @MainActor
    func testRenderBoundaryGiantBlockConstructionCeiling() throws {
        let fixtures = [
            ("paragraph", String(repeating: "A **rich** paragraph with العربية 👩🏽‍💻 and `inline code`. ", count: 700)),
            ("table", "| A | B |\n| --- | --- |\n" + String(repeating: "| **rich** text | العربية `code` |\n", count: 500)),
            ("code", "```swift\n" + String(repeating: "let value = items.map { $0.description }\n", count: 1500) + "```\n")
        ]
        for (name, source) in fixtures {
            let parseStart = CACurrentMediaTime()
            let document = try RenderBoundaryProof(source)
            let parseMS = (CACurrentMediaTime() - parseStart) * 1000
            XCTAssertEqual(document.blocks.count, 1, "A giant block remains indivisible at this public boundary")
            for (variant, markdown) in [("original", source), ("roundtrip", document.blocks[0].markdown)] {
                for run in 0..<2 {
                    let start = CACurrentMediaTime()
                    let host = UIHostingController(rootView: MarkdownRenderer(content: markdown).frame(width: 370))
                    let constructed = CACurrentMediaTime()
                    let size = host.sizeThatFits(in: CGSize(width: 370, height: CGFloat.greatestFiniteMagnitude))
                    let finish = CACurrentMediaTime()
                    XCTAssertTrue(size.height.isFinite && size.height > 0)
                    print("BOUNDARY_COST name=\(name) variant=\(variant) run=\(run) parseMS=\(parseMS) constructMS=\((constructed-start)*1000) fitMS=\((finish-constructed)*1000) height=\(size.height) bytes=\(source.utf8.count)")
                }
            }
        }
    }

    @MainActor
    func testRenderBoundaryLimitedMountedParity() async throws {
        let samples = [
            "- first\n  - nested **bold**\n- second\n",
            "1. loose\n\n   paragraph\n\n2. second\n",
            "- [x] done\n- [ ] pending\n",
            "| left | right |\n| :--- | ---: |\n| العربية | 👩🏽‍💻 中文 |\n",
            "~~~swift\nlet text = \"```\"\n~~~\n",
            "Setext\n======\n",
            "[early][later]\n\n[later]: https://example.invalid/path \"title\"\n"
        ]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 370, height: 600)
        window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .white
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        for (index, source) in samples.enumerated() {
            let document = try RenderBoundaryProof(source)
            XCTAssertEqual(document.blocks.count, 1)
            var heights: [CGFloat] = []
            for (variant, value) in [("original", source), ("descriptor", document.blocks[0].markdown)] {
                let host = UIHostingController(rootView: MarkdownRenderer(content: value)
                    .environment(\.colorScheme, .light).frame(width: 370, alignment: .topLeading))
                window.rootViewController = host
                host.view.backgroundColor = .white
                window.makeKeyAndVisible()
                host.view.frame = window.bounds
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                host.view.layoutIfNeeded()
                heights.append(host.sizeThatFits(in: CGSize(width: 370, height: CGFloat.greatestFiniteMagnitude)).height)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "boundary-\(index)-\(variant)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTAssertEqual(heights[0], heights[1], accuracy: 0.5, "Single-block public roundtrip height parity: \(index)")
        }
    }

    @MainActor
    func testPrototypeCodeGeometryMatchesRenderedWrappedAndUnwrappedLines() async throws {
        for source in ["let value = 42", String(repeating: "long word ", count: 24), "emoji 👩🏽‍💻 and العربية 中文", " "] {
            let value = NSAttributedString(string: source, attributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
            let prepared = MarkdownPreparedCode(value)
            for width: CGFloat? in [nil, 120] {
                let sizes = try await PrototypeCodeGeometryWorker.shared.sizes(prepared.lines, width: width, scale: 3)
                let text = prepared.lines[0].segments.reduce(Text(verbatim: "")) { $0 + Text($1.text) }
                let host = UIHostingController(rootView: text
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .fixedSize(horizontal: width == nil, vertical: true)
                    .environment(\.displayScale, 3))
                let measured = host.sizeThatFits(in: CGSize(width: width ?? 100_000, height: 100_000))
                XCTAssertEqual(sizes[0].height, measured.height, accuracy: 0.5, "Geometry must match actual Text, width=\(String(describing: width)), source=\(source.prefix(20))")
                if width == nil { XCTAssertEqual(sizes[0].width, measured.width, accuracy: 0.5) }
            }
        }
    }
#endif
    func testPreparedHighlightedCodeMatchesExistingConversionAndLineIDs() {
        let text = String(repeating: "x", count: 1200) + "\r\n\nemoji 👩🏽‍💻\u{2028}العربية\u{2029}"
        let source = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 19, weight: .medium),
            .foregroundColor: UIColor.systemPurple
        ])
        source.addAttribute(.kern, value: 3, range: NSRange(location: 480, length: 40))
        let old = MarkdownAttributedCodeFormatter.lines(in: source)
        let prepared = MarkdownPreparedCode(source)
        XCTAssertEqual(prepared.lines.map(\.id), old.map(\.id))
        for (actual, expected) in zip(prepared.lines, old) {
            XCTAssertEqual(actual.segments.map(\.id), expected.segments.map(\.id))
            XCTAssertEqual(actual.segments.map(\.text), expected.segments.map { AttributedString($0.attributedText) })
        }
    }

    func testPreparedHighlightedCodeOwnsImmutableSnapshot() {
        let source = NSMutableAttributedString(string: "let value = 1", attributes: [.foregroundColor: UIColor.red])
        let prepared = MarkdownPreparedCode(source)
        let expected = prepared
        source.mutableString.setString("replacement")
        source.addAttribute(.foregroundColor, value: UIColor.blue, range: NSRange(location: 0, length: source.length))
        XCTAssertEqual(prepared, expected)
        XCTAssertEqual(String(prepared.lines[0].segments[0].text.characters), "let value = 1")
    }

    func testPreparedHighlightedEmptyAndSeparatorLinesMatchExistingRendering() {
        for text in ["", "\n", "\r\n", "a\rb\u{2028}c\u{2029}"] {
            let source = NSAttributedString(string: text)
            let expected = MarkdownAttributedCodeFormatter.lines(in: source)
            let prepared = MarkdownPreparedCode(source)
            XCTAssertEqual(prepared.lines.map { $0.segments.map(\.text) },
                           expected.map { $0.segments.map { AttributedString($0.attributedText) } })
        }
    }

    @MainActor
    func testPreparedWorkerRefreshesContentThemeAndStreamingBoundary() async throws {
        let lightRequest = MarkdownCodeHighlightRequest(code: "let value = 1", language: "swift", colorScheme: .light, isStreaming: false)
        let darkRequest = MarkdownCodeHighlightRequest(code: lightRequest.code, language: "swift", colorScheme: .dark, isStreaming: false)
        guard case .highlighted(let light) = await MarkdownCodeHighlightWorker.shared.highlightedCode(for: lightRequest),
              case .highlighted(let dark) = await MarkdownCodeHighlightWorker.shared.highlightedCode(for: darkRequest) else {
            return XCTFail("Both theme revisions must produce prepared highlighting.")
        }
        XCTAssertNotEqual(light, dark)
        let changed = MarkdownCodeHighlightRequest(code: "return 2", language: "swift", colorScheme: .light, isStreaming: false)
        guard case .highlighted(let changedValue) = await MarkdownCodeHighlightWorker.shared.highlightedCode(for: changed) else {
            return XCTFail("Content revision must be prepared independently.")
        }
        XCTAssertEqual(changedValue.lines[0].segments.map { String($0.text.characters) }.joined(), "return 2")
        let streaming = MarkdownCodeHighlightRequest(code: changed.code, language: "swift", colorScheme: .light, isStreaming: true)
        guard case .plain(let reason, _) = await MarkdownCodeHighlightWorker.shared.highlightedCode(for: streaming) else {
            return XCTFail("Streaming must not reuse a completed highlight revision.")
        }
        XCTAssertEqual(reason, .streaming)
        let unknown = MarkdownCodeHighlightRequest(code: changed.code, language: nil, colorScheme: .light, isStreaming: false)
        guard case .plain(let missingReason, _) = await MarkdownCodeHighlightWorker.shared.highlightedCode(for: unknown) else {
            return XCTFail("Language change must invalidate completed highlighting.")
        }
        XCTAssertEqual(missingReason, .missingLanguage)
    }

    func testPreparedHighlightedWrapRejoinsIdenticalAttributes() {
        let source = NSMutableAttributedString(string: String(repeating: "x", count: 1200), attributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        source.addAttribute(.foregroundColor, value: UIColor.green, range: NSRange(location: 490, length: 40))
        let prepared = MarkdownPreparedCode(source)
        var wrapped = AttributedString("")
        for segment in prepared.lines[0].segments { wrapped.append(segment.text) }
        XCTAssertEqual(wrapped, AttributedString(source))
        XCTAssertEqual(prepared.lines[0].segments.map(\.id), [0, 1, 2])
    }

    @MainActor
    func testMountedPreparedHighlightKeepsWrapAndThemeLayout() async throws {
        let key = ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)
        let model = MountedMarkdownRendererModel(
            content: "```swift\nlet description = \"" + String(repeating: "long value ", count: 45) + "\"\n```",
            isStreaming: false
        )
        let fixture = MountedMarkdownRendererFixture(model: model, width: 340)
        defer { fixture.tearDown() }
        try await Task.sleep(for: .milliseconds(300))
        await fixture.settle()
        let unwrappedHeight = fixture.height()
        UserDefaults.standard.set(true, forKey: key)
        try await Task.sleep(for: .milliseconds(300))
        await fixture.settle()
        let wrappedHeight = fixture.height()
        XCTAssertGreaterThan(wrappedHeight, unwrappedHeight + 20)
        model.colorScheme = .dark
        try await Task.sleep(for: .milliseconds(300))
        await fixture.settle()
        XCTAssertEqual(fixture.height(), wrappedHeight, accuracy: 2)
        UserDefaults.standard.set(false, forKey: key)
        try await Task.sleep(for: .milliseconds(300))
        await fixture.settle()
        XCTAssertEqual(fixture.height(), unwrappedHeight, accuracy: 2)
    }

    func testInlineMathReplacesCommonLatexCommands() {
        let input = #"Inline: the quadratic formula $x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}$ works."#

        let rendered = MarkdownMathFormatter.replacingInlineMath(in: input)

        XCTAssertFalse(rendered.contains("$"))
        XCTAssertFalse(rendered.contains(#"\frac"#))
        XCTAssertFalse(rendered.contains(#"\sqrt"#))
        XCTAssertTrue(rendered.contains("±"))
        XCTAssertTrue(rendered.contains("√"))
        XCTAssertTrue(rendered.contains("²"))
    }

    func testSingleTokenInlineMathAndEscapedDollars() {
        let input = #"Where $m$ is count, $y$ is label, and \$not math\$ stays literal."#

        let rendered = MarkdownMathFormatter.replacingInlineMath(in: input)

        XCTAssertTrue(rendered.contains("Where m is count"))
        XCTAssertTrue(rendered.contains("y is label"))
        XCTAssertTrue(rendered.contains(#"\$not math\$"#))
    }

    func testInlineScreenshotCommandsDoNotLeakRawLatex() {
        let input = #"Probability: $P(A \mid B) = \frac{P(B \mid A)P(A)}{P(B)}$ and norm $\Vert x \rVert_2 = \sqrt{\sum_{i=1}^n x_i^2}$."#

        let rendered = MarkdownMathFormatter.replacingInlineMath(in: input)

        XCTAssertFalse(rendered.contains(#"\mid"#))
        XCTAssertFalse(rendered.contains(#"\Vert"#))
        XCTAssertFalse(rendered.contains(#"\rVert"#))
        XCTAssertTrue(rendered.contains("P(A | B)"))
        XCTAssertTrue(rendered.contains("‖ x ‖₂"))
        XCTAssertTrue(rendered.contains("∑ᵢ₌₁ⁿ"))
        XCTAssertTrue(rendered.contains("xᵢ²"))
    }

    func testLongerCommandsWinBeforeShorterCommandPrefixes() {
        let input = #"Attention: $\mathrm{softmax}(QK^\top/\sqrt{d_k})V$ and $a \leftarrow b \to c$."#

        let rendered = MarkdownMathFormatter.replacingInlineMath(in: input)

        XCTAssertTrue(rendered.contains("QK^⊤/√dₖ"))
        XCTAssertTrue(rendered.contains("a ← b → c"))
        XCTAssertFalse(rendered.contains("→p"))
        XCTAssertFalse(rendered.contains(#"\top"#))
        XCTAssertFalse(rendered.contains(#"\leftarrow"#))
    }

    func testDisplayMathSegmentsAndRendersMatrices() {
        let input = #"**Matrices** $$\begin{pmatrix} a & b \\ c & d \end{pmatrix}^{-1} = \frac{1}{ad-bc}\begin{pmatrix} d & -b \\ -c & a \end{pmatrix}$$"#

        let segments = MarkdownMathSegmenter.segments(in: input)

        XCTAssertEqual(segments.count, 2)
        guard case .displayMath(let latex) = segments.last else {
            return XCTFail("Expected trailing display math segment.")
        }

        let rendered = MarkdownMathFormatter.renderedText(for: latex)
        XCTAssertFalse(rendered.contains("$"))
        XCTAssertFalse(rendered.contains(#"\begin"#))
        XCTAssertTrue(rendered.contains("⎛"))
        XCTAssertTrue(rendered.contains("⎞"))
        XCTAssertTrue(rendered.contains("⁻¹"))
        XCTAssertTrue(rendered.contains("ad-bc"))
    }

    func testInlineMathSkipsCodeSpansAndFencedBlocks() {
        let input = #"""
        Code `$x = \frac{1}{2}$` stays.

        ```swift
        let value = "$$\\frac{1}{2}$$"
        ```

        But $x^2$ changes.
        """#

        let rendered = MarkdownMathFormatter.replacingInlineMath(in: input)

        XCTAssertTrue(rendered.contains(#"`$x = \frac{1}{2}$`"#))
        XCTAssertTrue(rendered.contains(#"$$\\frac{1}{2}$$"#))
        XCTAssertTrue(rendered.contains("x²"))
    }

    func testDisplayMathSegmentationSkipsFencedCodeBlocks() {
        let input = #"""
        ```md
        $$\frac{1}{2}$$
        ```

        $$\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}$$
        """#

        let mathSegments = MarkdownMathSegmenter.segments(in: input).compactMap { segment -> String? in
            if case .displayMath(let latex) = segment {
                return latex
            }
            return nil
        }

        XCTAssertEqual(mathSegments.count, 1)
        let rendered = MarkdownMathFormatter.renderedText(for: mathSegments[0])
        XCTAssertTrue(rendered.contains("∑"))
        XCTAssertTrue(rendered.contains("∞"))
        XCTAssertTrue(rendered.contains("π²"))
    }

    func testInlineParenDelimitersRenderBeforeMarkdownEscapesThem() {
        let input = #"Inline: \(e^{i\pi}+1=0\)"#

        let rendered = MarkdownMathFormatter.replacingInlineMath(in: input)

        XCTAssertEqual(rendered, "Inline: eⁱπ+1=0")
        XCTAssertFalse(rendered.contains(#"\("#))
        XCTAssertFalse(rendered.contains(#"\pi"#))
    }

    func testBracketDisplayDelimitersSegmentAndRenderScreenshotExamples() {
        let input = #"""
        Block:

        \[
        \int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
        \]

        Matrix:

        \[
        A = \begin{bmatrix} 1 & 2 \\ 3 & 4 \end{bmatrix},
        \quad \det(A)=1\cdot4-2\cdot3=-2
        \]

        Aligned:

        \[
        \begin{aligned} \nabla \cdot \mathbf{E} &= \frac{\rho}{\varepsilon_0} \\ \nabla \cdot \mathbf{B} &= 0 \\ \nabla \times \mathbf{E} &= -\frac{\partial \mathbf{B}}{\partial t} \end{aligned}
        \]
        """#

        let mathSegments = MarkdownMathSegmenter.segments(in: input).compactMap { segment -> String? in
            if case .displayMath(let latex) = segment {
                return latex
            }
            return nil
        }

        XCTAssertEqual(mathSegments.count, 3)
        let rendered = mathSegments.map(MarkdownMathFormatter.renderedText(for:))
        XCTAssertTrue(rendered[0].contains("∫₋∞^∞"))
        XCTAssertTrue(rendered[0].contains("√π"))
        XCTAssertTrue(rendered[1].contains("⎡ 1 2 ⎤"))
        XCTAssertTrue(rendered[1].contains("det(A)=1·4-2·3=-2"))
        XCTAssertTrue(rendered[2].contains("∇ · E = ρ/ε₀"))
        XCTAssertTrue(rendered[2].contains("∇ × E = -∂B/∂t"))
        XCTAssertFalse(rendered.joined().contains(#"\begin"#))
        XCTAssertFalse(rendered.joined().contains(#"\mathbf"#))
    }

    func testFinalStressTestDoesNotLeakRawCommands() {
        let input = #"""
        \[
        \boxed{
        \mathcal{L}(\theta)
        =
        -\sum_{i=1}^{n}
        [
        y_i \log \hat{y}_i
        +
        (1-y_i)\log(1-\hat{y}_i)
        ]
        }
        \]
        """#

        guard case .displayMath(let latex) = MarkdownMathSegmenter.segments(in: input).first else {
            return XCTFail("Expected display math.")
        }

        let rendered = MarkdownMathFormatter.renderedText(for: latex)

        XCTAssertTrue(rendered.contains("ℒ(θ)"))
        XCTAssertTrue(rendered.contains("-∑ᵢ₌₁ⁿ"))
        XCTAssertTrue(rendered.contains("yᵢ log ŷᵢ"))
        XCTAssertTrue(rendered.contains("(1-yᵢ)log(1-ŷᵢ)"))
        XCTAssertFalse(rendered.contains(#"\boxed"#))
        XCTAssertFalse(rendered.contains(#"\mathcal"#))
        XCTAssertFalse(rendered.contains(#"\log"#))
        XCTAssertFalse(rendered.contains(#"\hat"#))
    }

    func testCasesAndOptimizationCommandsRenderFromDisplayMath() {
        let input = #"""
        \[
        \begin{cases}
        2x + y = 5 \\
        x - y = 1
        \end{cases}
        \Rightarrow x = 2, y = 1
        \]

        \[
        \theta^* = \arg\min_{\theta} \frac{1}{n}\sum_{i=1}^{n}(y_i - f_\theta(x_i))^2
        \]

        \[
        \theta^\* = \arg\min_{\theta} J(\theta)
        \]
        """#

        let rendered = MarkdownMathSegmenter.segments(in: input).compactMap { segment -> String? in
            if case .displayMath(let latex) = segment {
                return MarkdownMathFormatter.renderedText(for: latex)
            }
            return nil
        }
        .joined(separator: "\n")

        XCTAssertTrue(rendered.contains("⎧ 2x + y = 5"))
        XCTAssertTrue(rendered.contains("⎩ x - y = 1"))
        XCTAssertTrue(rendered.contains("⇒ x = 2, y = 1"))
        XCTAssertTrue(rendered.contains("θ^* = argminθ"))
        XCTAssertFalse(rendered.contains(#"θ^\*"#))
        XCTAssertTrue(rendered.contains("∑ᵢ₌₁ⁿ"))
        XCTAssertFalse(rendered.contains(#"\begin"#))
        XCTAssertFalse(rendered.contains(#"\end"#))
        XCTAssertFalse(rendered.contains(#"\Rightarrow"#))
        XCTAssertFalse(rendered.contains(#"\arg"#))
    }

    func testMarkdownHighlightPolicyUsesSplashForNormalSwiftCode() {
        let decision = MarkdownHighlightPolicy.decision(
            for: "let value = 1",
            language: "swift",
            isStreaming: false
        )

        XCTAssertEqual(decision, .highlight(language: "swift", engine: .splashSwift))
    }

    func testMarkdownHighlightPolicyNormalizesCommonAliases() {
        XCTAssertEqual(MarkdownHighlightPolicy.normalizedLanguage(from: "py"), "python")
        XCTAssertEqual(MarkdownHighlightPolicy.normalizedLanguage(from: "zsh session"), "bash")
        XCTAssertEqual(MarkdownHighlightPolicy.normalizedLanguage(from: "TSX"), "typescript")
    }

    func testMarkdownHighlightPolicyLanguageLogCategoryDoesNotExposeUnsupportedLanguage() {
        let normalized = MarkdownHighlightPolicy.normalizedLanguage(from: "password-secret-token")
        let category = MarkdownHighlightPolicy.languageLogCategory(for: normalized)

        XCTAssertEqual(category, "unsupported")
        XCTAssertFalse(category.contains("password"))
        XCTAssertFalse(category.contains("secret"))
        XCTAssertFalse(category.contains("token"))
    }

    func testMarkdownHighlightPolicyLanguageLogCategoryUsesFixedBuckets() {
        XCTAssertEqual(MarkdownHighlightPolicy.languageLogCategory(for: nil), "missing")
        XCTAssertEqual(MarkdownHighlightPolicy.languageLogCategory(for: "swift"), "splashSwift")
        XCTAssertEqual(MarkdownHighlightPolicy.languageLogCategory(for: "json"), "highlightr")
        XCTAssertEqual(MarkdownHighlightPolicy.languageLogCategory(for: "log"), "highRisk")
    }

    func testMarkdownHighlightPolicySkipsStreamingCode() {
        let decision = MarkdownHighlightPolicy.decision(
            for: "let value = 1",
            language: "swift",
            isStreaming: true
        )

        XCTAssertEqual(decision, .plain(reason: .streaming, normalizedLanguage: "swift"))
    }

    func testMarkdownHighlightPolicySkipsMissingLanguageInsteadOfAutoDetecting() {
        let decision = MarkdownHighlightPolicy.decision(
            for: "let value = 1",
            language: nil,
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .missingLanguage, normalizedLanguage: nil))
    }

    func testMarkdownHighlightPolicySkipsLogLikeLanguages() {
        let decision = MarkdownHighlightPolicy.decision(
            for: "2026-05-26 warning: retrying",
            language: "log",
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .highRiskLanguage, normalizedLanguage: "log"))
    }

    func testMarkdownHighlightPolicySkipsExtremeCodeBlocks() {
        let decision = MarkdownHighlightPolicy.decision(
            for: String(repeating: "x", count: MarkdownHighlightPolicy.maxHighlightedCodeCharacterCount + 1),
            language: "json",
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .tooManyCharacters, normalizedLanguage: "json"))
    }

    func testMarkdownHighlightPolicySkipsExcessiveLineCounts() {
        let code = Array(repeating: "print(1)", count: MarkdownHighlightPolicy.maxHighlightedCodeLineCount + 1)
            .joined(separator: "\n")

        let decision = MarkdownHighlightPolicy.decision(
            for: code,
            language: "python",
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .tooManyLines, normalizedLanguage: "python"))
    }

    func testMarkdownHighlightPolicyCountsCarriageReturnLines() {
        let code = Array(repeating: "print(1)", count: MarkdownHighlightPolicy.maxHighlightedCodeLineCount + 1)
            .joined(separator: "\r")

        let decision = MarkdownHighlightPolicy.decision(
            for: code,
            language: "python",
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .tooManyLines, normalizedLanguage: "python"))
    }

    func testMarkdownHighlightPolicyCountsUnicodeSeparatorLines() {
        let code = Array(repeating: "print(1)", count: MarkdownHighlightPolicy.maxHighlightedCodeLineCount + 1)
            .joined(separator: "\u{2028}")

        let decision = MarkdownHighlightPolicy.decision(
            for: code,
            language: "python",
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .tooManyLines, normalizedLanguage: "python"))
    }

    func testMarkdownHighlightPolicySkipsLongSingleLineCode() {
        let code = String(repeating: "x", count: MarkdownHighlightPolicy.maxHighlightedCodeLineLength + 1)

        let decision = MarkdownHighlightPolicy.decision(
            for: code,
            language: "json",
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .lineTooLong, normalizedLanguage: "json"))
    }

    func testMarkdownHighlightPolicyAllowsLongCodeSplitAcrossLines() {
        let code = Array(repeating: String(repeating: "x", count: 250), count: 20)
            .joined(separator: "\r\n")

        let decision = MarkdownHighlightPolicy.decision(
            for: code,
            language: "json",
            isStreaming: false
        )

        XCTAssertEqual(decision, .highlight(language: "json", engine: .highlightr))
    }

    @MainActor
    func testMarkdownCodeHighlighterRendersSwiftCodeWithSplash() {
        let result = MarkdownCodeHighlighter.highlightedCode(
            for: MarkdownCodeHighlightRequest(
                code: "let value = 1",
                language: "swift",
                colorScheme: .light,
                isStreaming: false
            )
        )

        guard case .highlighted(let highlightedCode) = result else {
            return XCTFail("Expected Splash to highlight Swift code.")
        }

        XCTAssertEqual(highlightedCode.string, "let value = 1")
    }

    @MainActor
    func testMarkdownCodeHighlighterRendersLightModeSwiftForegroundColors() {
        let result = MarkdownCodeHighlighter.highlightedCode(
            for: MarkdownCodeHighlightRequest(
                code: "func greet(name: String) -> String {\n    return \"Hello\"\n}",
                language: "swift",
                colorScheme: .light,
                isStreaming: false
            )
        )

        guard case .highlighted(let highlightedCode) = result else {
            return XCTFail("Expected Splash to highlight Swift code.")
        }

        let colors = foregroundColorSignatures(in: highlightedCode, userInterfaceStyle: .light)
        XCTAssertGreaterThan(colors.count, 1)
    }

    @MainActor
    func testMarkdownCodeHighlighterRendersNonSwiftCodeWithHighlightr() {
        let result = MarkdownCodeHighlighter.highlightedCode(
            for: MarkdownCodeHighlightRequest(
                code: #"{"value": 1}"#,
                language: "json",
                colorScheme: .dark,
                isStreaming: false
            )
        )

        guard case .highlighted(let highlightedCode) = result else {
            return XCTFail("Expected Highlightr to highlight JSON code.")
        }

        let renderedCode = highlightedCode.string
        XCTAssertTrue(renderedCode.contains("value"))
        XCTAssertTrue(renderedCode.contains("1"))
    }

    @MainActor
    func testMarkdownCodeHighlighterRendersLightModeNonSwiftForegroundColors() {
        let result = MarkdownCodeHighlighter.highlightedCode(
            for: MarkdownCodeHighlightRequest(
                code: """
                {
                  "enabled": true,
                  "name": "test"
                }
                """,
                language: "json",
                colorScheme: .light,
                isStreaming: false
            )
        )

        guard case .highlighted(let highlightedCode) = result else {
            return XCTFail("Expected Highlightr to highlight JSON code.")
        }

        let colors = foregroundColorSignatures(in: highlightedCode, userInterfaceStyle: .light)
        XCTAssertGreaterThan(colors.count, 1)
    }

    @MainActor
    func testMarkdownCodeHighlighterSkipsStreamingBlocks() {
        let result = MarkdownCodeHighlighter.highlightedCode(
            for: MarkdownCodeHighlightRequest(
                code: #"{"value": 1}"#,
                language: "json",
                colorScheme: .light,
                isStreaming: true
            )
        )

        guard case .plain(let reason, let normalizedLanguage) = result else {
            return XCTFail("Expected streaming code to render as plain text.")
        }

        XCTAssertEqual(reason, .streaming)
        XCTAssertEqual(normalizedLanguage, "json")
    }

    func testMarkdownHighlightPolicyAllowsLargeCodeBlocksWithinMarkdownLimit() {
        let code = Array(
            repeating: #""enabled": true, "retries": 5, "mode": "verbose""#,
            count: 350
        )
        .joined(separator: "\n")

        XCTAssertGreaterThan(code.count, 12_000)

        let decision = MarkdownHighlightPolicy.decision(
            for: code,
            language: "json",
            isStreaming: false
        )

        XCTAssertEqual(decision, .highlight(language: "json", engine: .highlightr))
    }

    func testMarkdownPlainCodeFormatterPreservesVisibleBlankLines() {
        let lines = MarkdownPlainCodeFormatter.lines(in: "first\n\nthird")

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].segments.map(\.text), ["first"])
        XCTAssertEqual(lines[1].segments.map(\.text), [" "])
        XCTAssertEqual(lines[2].segments.map(\.text), ["third"])
    }

    func testMarkdownPlainCodeFormatterSegmentsVeryLongLines() {
        let longLine = String(repeating: "x", count: MarkdownPlainCodeFormatter.maxSegmentLength + 12)
        let lines = MarkdownPlainCodeFormatter.lines(in: longLine)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].segments.count, 2)
        XCTAssertEqual(lines[0].segments[0].text.count, MarkdownPlainCodeFormatter.maxSegmentLength)
        XCTAssertEqual(lines[0].segments[1].text.count, 12)
    }

    func testMarkdownAttributedCodeFormatterSegmentsVeryLongHighlightedLines() {
        let longLine = String(repeating: "x", count: MarkdownAttributedCodeFormatter.maxSegmentLength + 12)
        let attributedCode = NSAttributedString(string: "first\n\(longLine)")

        let lines = MarkdownAttributedCodeFormatter.lines(in: attributedCode)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].segments.map(\.attributedText.string), ["first"])
        XCTAssertEqual(lines[1].segments.count, 2)
        XCTAssertEqual(
            lines[1].segments[0].attributedText.string.count,
            MarkdownAttributedCodeFormatter.maxSegmentLength
        )
        XCTAssertEqual(lines[1].segments[1].attributedText.string.count, 12)
    }

    func testMarkdownAttributedCodeFormatterPreservesForegroundColors() {
        let attributedCode = NSMutableAttributedString(
            string: "let value = true",
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor.label
            ]
        )
        attributedCode.addAttributes(
            [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.systemPink
            ],
            range: NSRange(location: 0, length: 3)
        )
        attributedCode.addAttribute(
            .foregroundColor,
            value: UIColor.systemBlue,
            range: NSRange(location: 12, length: 4)
        )

        let segments = MarkdownAttributedCodeFormatter.lines(in: attributedCode)
            .flatMap(\.segments)

        XCTAssertEqual(segments.map(\.attributedText.string), ["let value = true"])
        XCTAssertGreaterThan(
            foregroundColorSignatures(in: segments[0].attributedText, userInterfaceStyle: .light).count,
            1
        )

        let firstFont = segments[0].attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertTrue(firstFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
        XCTAssertEqual(
            colorSignature(in: segments[0].attributedText, at: 0, userInterfaceStyle: .light),
            colorSignature(for: .systemPink, userInterfaceStyle: .light)
        )
        XCTAssertEqual(
            colorSignature(in: segments[0].attributedText, at: 12, userInterfaceStyle: .light),
            colorSignature(for: .systemBlue, userInterfaceStyle: .light)
        )
    }

    func testMarkdownContentRenderingPolicyAllowsNormalMarkdown() {
        XCTAssertNil(MarkdownContentRenderingPolicy.fallbackReason(for: "**Hello** world"))
    }

    func testMarkdownContentRenderingPolicyFallsBackForVeryLargeMarkdown() {
        let content = String(
            repeating: "a",
            count: MarkdownContentRenderingPolicy.maxMarkdownCharacterCount + 1
        )

        XCTAssertEqual(
            MarkdownContentRenderingPolicy.fallbackReason(for: content),
            .tooManyCharacters
        )
    }

    func testMarkdownContentRenderingPolicyFallsBackForTooManyLines() {
        let content = Array(
            repeating: "line",
            count: MarkdownContentRenderingPolicy.maxMarkdownLineCount + 1
        )
        .joined(separator: "\n")

        XCTAssertEqual(
            MarkdownContentRenderingPolicy.fallbackReason(for: content),
            .tooManyLines
        )
    }

    func testMarkdownContentRenderingPolicyFallsBackForCarriageReturnLines() {
        let content = Array(
            repeating: "line",
            count: MarkdownContentRenderingPolicy.maxMarkdownLineCount + 1
        )
        .joined(separator: "\r")

        XCTAssertEqual(
            MarkdownContentRenderingPolicy.fallbackReason(for: content),
            .tooManyLines
        )
    }

    func testCompletedCodeHighlightingRunsOnDedicatedWorker() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HermesMobile/Features/Chat/MarkdownRenderer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let updateStart = try XCTUnwrap(source.range(of: "private func updateHighlightedCode"))
        let updateEnd = try XCTUnwrap(
            source.range(of: "private var displayLanguage", range: updateStart.upperBound..<source.endIndex)
        )
        let updateSource = String(source[updateStart.lowerBound..<updateEnd.lowerBound])

        XCTAssertTrue(source.contains("actor MarkdownCodeHighlightWorker"))
        XCTAssertTrue(updateSource.contains("await MarkdownCodeHighlightWorker.shared.highlightedCode"))
        XCTAssertFalse(
            updateSource.contains("MarkdownCodeHighlighter.highlightedCode"),
            "Completed syntax highlighting must not parse and color code synchronously on MainActor."
        )
    }

    @MainActor
    func testMountedStreamingRendererShrinksAfterRapidTerminalReplacement() async throws {
        let longMarkdown = (0..<36).map { index in
            "## Research section \(index)\n\nEvidence paragraph \(index) with enough words to wrap at phone width."
        }.joined(separator: "\n\n")
        let supersededTerminal = (0..<8).map { index in
            "Superseded terminal section \(index) that must not remain rendered."
        }.joined(separator: "\n\n")
        let finalGuardrail = "Search stopped after reaching the tool-use limit."
        let model = MountedMarkdownRendererModel(content: longMarkdown, isStreaming: true)
        let fixture = MountedMarkdownRendererFixture(model: model, width: 340)
        defer { fixture.tearDown() }

        await fixture.settle()
        let longHeight = fixture.height()

        model.content = supersededTerminal
        model.content = finalGuardrail
        model.isStreaming = false
        try await Task.sleep(for: .seconds(StreamingTextFadeDefaults.framePauseDelay + 0.2))
        await fixture.settle()
        let settledHeight = fixture.height()

        let baseline = MountedMarkdownRendererFixture(
            model: MountedMarkdownRendererModel(content: finalGuardrail, isStreaming: false),
            width: 340
        )
        defer { baseline.tearDown() }
        await baseline.settle()
        let baselineHeight = baseline.height()

        XCTAssertEqual(model.content, finalGuardrail)
        XCTAssertGreaterThan(longHeight, baselineHeight)
        XCTAssertEqual(settledHeight, baselineHeight, accuracy: 2)
    }

#if DEBUG
    @MainActor
    func testMountedStreamingBlockStateInitializesOncePerIdentityAndKeepsFullContent() async throws {
        let paragraph = String(repeating: "A long Unicode paragraph العربية 👩🏽‍💻 stays readable. ", count: 28)
        let firstCode = "let first = \"👩🏽‍💻\"\nprint(first)"
        let initial = "\(paragraph)\n\n```swift\n\(firstCode)"
        let model = MountedStreamingBlockModel(content: initial)
        let probe = MountedStreamingBlockProbe()
        let fixture = MountedStreamingBlockFixture(model: model, probe: probe)
        defer { fixture.tearDown() }

        let initialHeight = fixture.height()
        XCTAssertEqual(probe.initializationCount, 1)
        XCTAssertEqual(probe.fullContent, initial, "Initial body must contain all content before any onAppear seeding")
        XCTAssertGreaterThan(initialHeight, 0)
        let initialCodeView = await fixture.waitForCode(firstCode, content: initial)
        XCTAssertNotNil(initialCodeView)

        for index in 1...5 {
            model.reevaluation = index
            model.colorScheme = index.isMultiple(of: 2) ? .light : .dark
            await fixture.settle()
            XCTAssertEqual(probe.initializationCount, 1, "Same-identity parent/theme changes must not split from scratch")
            XCTAssertEqual(probe.fullContent, initial)
        }

        let appendedCode = firstCode + "\nprint(\"appended العربية\")"
        let appended = "\(paragraph)\n\n```swift\n\(appendedCode)"
        model.content = appended
        let appendedCodeView = await fixture.waitForCode(appendedCode, content: appended)
        XCTAssertNotNil(appendedCodeView)
        XCTAssertEqual(probe.fullContent, appended)
        XCTAssertEqual(probe.initializationCount, 1)

        let completed = appended + "\n```"
        model.content = completed
        let completedCodeView = await fixture.waitForCode(appendedCode, content: completed)
        XCTAssertNotNil(completedCodeView)
        XCTAssertEqual(probe.fullContent, completed)
        XCTAssertEqual(probe.initializationCount, 1)

        let replacementCode = "let replacement = \"中文\""
        let replacement = "Replacement paragraph.\n\n```swift\n\(replacementCode)"
        model.content = replacement
        let replacementCodeView = await fixture.waitForCode(replacementCode, content: replacement)
        XCTAssertNotNil(replacementCodeView)
        XCTAssertEqual(probe.fullContent, replacement)
        XCTAssertEqual(probe.initializationCount, 1)

        fixture.hideAndShow()
        await fixture.settle()
        XCTAssertEqual(probe.initializationCount, 1, "Visibility alone must retain mounted state")

        model.identity += 1
        let freshCode = "let fresh = \"new identity\""
        let fresh = "Fresh response.\n\n```swift\n\(freshCode)"
        model.content = fresh
        let freshCodeView = await fixture.waitForCode(freshCode, content: fresh)
        XCTAssertNotNil(freshCodeView)
        XCTAssertEqual(probe.initializationCount, 2)
        XCTAssertEqual(probe.fullContent, fresh)
    }

    @MainActor
    func testNativeCodeSingleBridgePreservesLegacyAttributedAssembly() {
        let sources = [
            "", "\n", "\r\n\r", "first\r\n\nlast\n",
            "العربية\u{2028}👩🏽‍💻\u{2029}中文", "\ta\tb\rfinal",
            (0..<320).map { "let value_\($0) = \($0) // full inline code" }.joined(separator: "\n")
        ]
        for source in sources {
            let colored = NSMutableAttributedString(string: source, attributes: [
                .foregroundColor: UIColor.systemPink,
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            ])
            if colored.length > 2 {
                colored.addAttribute(.kern, value: 1.5, range: NSRange(location: 0, length: 2))
            }
            let matching = MarkdownPreparedCode(colored)
            let stale = MarkdownPreparedCode(NSAttributedString(string: "stale revision"))
            for prepared in [nil, matching, stale] {
                // Independent oracle: the pre-R15 per-segment bridge and
                // assembly, including unstyled separators/empty placeholders.
                let lines: [[NSAttributedString]]
                if let prepared, String(prepared.fullText.characters) == source {
                    lines = prepared.lines.map { $0.segments.map { NSAttributedString($0.text) } }
                } else {
                    lines = MarkdownPlainCodeFormatter.lines(in: source).map {
                        $0.segments.map { NSAttributedString(string: $0.text) }
                    }
                }
                let expected = NSMutableAttributedString(string: "")
                var ranges: [NSRange] = []
                for line in lines {
                    if !ranges.isEmpty { expected.append(NSAttributedString(string: "\n")) }
                    let start = expected.length
                    for segment in line { expected.append(segment) }
                    ranges.append(NSRange(location: start, length: expected.length - start))
                }
                let fullRange = NSRange(location: 0, length: expected.length)
                for (key, fallback) in [
                    (NSAttributedString.Key.font, UIFont.monospacedSystemFont(ofSize: 13, weight: .regular) as Any),
                    (NSAttributedString.Key.foregroundColor, UIColor.label as Any)
                ] {
                    expected.enumerateAttribute(key, in: fullRange) { value, range, _ in
                        if value == nil { expected.addAttribute(key, value: fallback, range: range) }
                    }
                }
                for (index, range) in ranges.enumerated() {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.paragraphSpacing = index == ranges.count - 1 ? 0 : 3
                    paragraph.lineSpacing = 13 * 0.18
                    expected.addAttribute(.paragraphStyle, value: paragraph, range: range)
                }
                let actual = MarkdownNativeCodeText.displayText(source: source, prepared: prepared)
                XCTAssertTrue(actual.isEqual(to: expected),
                              "Attributes/source must match for \(source.utf8.count) bytes, prepared=\(prepared != nil)")
            }
        }
    }

    @MainActor
    func testNativePreparedDisplayBuildsOnceAcrossCopiesAndRejectsStaleSource() {
        let source = (0..<320).map { "let value_\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let prepared = MarkdownPreparedCode(NSAttributedString(string: source, attributes: [
            .foregroundColor: UIColor.systemPink
        ]))
        let copy = prepared
        XCTAssertEqual(prepared.nativeDisplay.constructionCount, 0, "Legacy paths must not eagerly allocate native display")
        let first = MarkdownNativeCodeText.displayText(source: source, prepared: prepared)
        for _ in 0..<10 {
            XCTAssertTrue(MarkdownNativeCodeText.displayText(source: source, prepared: copy) === first)
        }
        XCTAssertEqual(prepared.nativeDisplay.constructionCount, 1)
        XCTAssertEqual(prepared, copy)
        let stale = MarkdownNativeCodeText.displayText(source: "replacement", prepared: copy)
        XCTAssertEqual(stale.string, "replacement")
        XCTAssertEqual(prepared.nativeDisplay.constructionCount, 1)
        XCTAssertTrue(MarkdownNativeCodeText.displayText(source: source, prepared: prepared) === first)

        let recolored = MarkdownPreparedCode(NSAttributedString(string: source, attributes: [
            .foregroundColor: UIColor.systemBlue
        ]))
        let dark = MarkdownNativeCodeText.displayText(source: source, prepared: recolored)
        XCTAssertFalse(dark === first)
        XCTAssertFalse(dark.isEqual(to: first))
        XCTAssertEqual(dark.string, first.string)
        XCTAssertEqual(recolored.nativeDisplay.constructionCount, 1)
        XCTAssertNotEqual(prepared, recolored)
        let equalRevision = MarkdownPreparedCode(NSAttributedString(string: source, attributes: [
            .foregroundColor: UIColor.systemPink
        ]))
        XCTAssertEqual(equalRevision, prepared, "Independent revisions retain value equality")
        XCTAssertEqual(equalRevision.nativeDisplay.constructionCount, 0)
    }

    @MainActor
    func testNativeMeasurementReuseAcrossRemountAndLayoutInvalidation() {
        let source = "let value = 1\n" + String(repeating: "wide code ", count: 30)
        let prepared = MarkdownPreparedCode(NSAttributedString(string: source))
        func mount(_ prepared: MarkdownPreparedCode, source: String,
                   scheme: ColorScheme = .light) -> (UITextView, MarkdownNativeCodeText.Coordinator) {
            let view = UITextView()
            view.isScrollEnabled = false
            view.isEditable = false
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            let state = MarkdownNativeCodeText.Coordinator()
            MarkdownNativeCodeText(source: source, prepared: prepared, wraps: true,
                                   colorScheme: scheme).update(view, state: state)
            return (view, state)
        }
        let (first, firstState) = mount(prepared, source: source)
        func size(_ view: UITextView, _ state: MarkdownNativeCodeText.Coordinator,
                  width: CGFloat = 220, wraps: Bool = true,
                  scheme: ColorScheme = .light) -> CGSize {
            MarkdownNativeCodeText.measuredSize(view, width: width, wraps: wraps,
                                               colorScheme: scheme, measurements: state.measurements)
        }
        let expected = size(first, firstState)
        XCTAssertEqual(firstState.measurements.measurementCount, 1)
        let (second, secondState) = mount(prepared, source: source)
        XCTAssertTrue(firstState.measurements === secondState.measurements)
        XCTAssertFalse(first.textStorage === second.textStorage)
        XCTAssertEqual(size(second, secondState), expected)
        XCTAssertEqual(secondState.measurements.measurementCount, 1, "Remount must skip native measurement")
        second.selectedRange = NSRange(location: 4, length: 5)
        MarkdownNativeCodeText(source: source, prepared: prepared, wraps: true,
                               colorScheme: .light).update(second, state: secondState)
        XCTAssertEqual(second.selectedRange, NSRange(location: 4, length: 5))
        XCTAssertEqual(size(second, secondState), expected)
        XCTAssertEqual(secondState.measurements.measurementCount, 1)
        _ = size(second, secondState, width: 340)
        XCTAssertEqual(secondState.measurements.measurementCount, 2)
        _ = size(second, secondState, width: 220)
        XCTAssertEqual(secondState.measurements.measurementCount, 2, "Both retained widths must hit")
        second.textContainer.lineBreakMode = .byClipping
        _ = size(second, secondState, width: 100_000, wraps: false)
        XCTAssertEqual(secondState.measurements.measurementCount, 3)
        _ = size(second, secondState, width: 100_000, wraps: false, scheme: .dark)
        XCTAssertEqual(secondState.measurements.measurementCount, 4)
        XCTAssertEqual(secondState.measurements.count, 2)

        for replacement in [NSAttributedString(string: source + " changed"),
                            NSAttributedString(string: source, attributes: [.font: UIFont.systemFont(ofSize: 25)])] {
            let revision = MarkdownPreparedCode(replacement)
            let (leaf, state) = mount(revision, source: replacement.string)
            XCTAssertFalse(state.measurements === firstState.measurements)
            _ = size(leaf, state)
            XCTAssertEqual(state.measurements.measurementCount, 1)
        }
    }

    @MainActor
    func testNativeMeasurementTraitsAndBoundedEvictionSkipWorkOnlyForExactIdentity() {
        let cache = MarkdownNativeCodeMeasurements()
        let normal = UITraitCollection(traitsFrom: [
            UITraitCollection(preferredContentSizeCategory: .large), UITraitCollection(displayScale: 2)
        ])
        let large = UITraitCollection(traitsFrom: [
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
            UITraitCollection(displayScale: 2)
        ])
        let scaled = UITraitCollection(traitsFrom: [
            UITraitCollection(preferredContentSizeCategory: .large), UITraitCollection(displayScale: 3)
        ])
        var operations = 0
        func measure(_ traits: UITraitCollection) -> CGSize {
            cache.value(width: 220, wraps: true, colorScheme: .light, traits: traits) {
                operations += 1
                return CGSize(width: 220, height: CGFloat(operations))
            }
        }
        XCTAssertEqual(measure(normal), measure(UITraitCollection(traitsFrom: [normal])))
        XCTAssertEqual(operations, 1)
        _ = measure(large)
        _ = measure(normal) // refresh normal, making large the eviction victim
        _ = measure(scaled)
        XCTAssertEqual(operations, 3)
        XCTAssertEqual(cache.count, 2)
        _ = measure(normal)
        XCTAssertEqual(operations, 3)
        _ = measure(large)
        XCTAssertEqual(operations, 4)
        XCTAssertEqual(cache.count, 2)
    }

    @MainActor
    func testNativePreparedDisplayRejectsCanonicalEquivalentDifferentBytes() {
        let composed = "caf\u{00e9}"
        let decomposed = "cafe\u{0301}"
        let prepared = MarkdownPreparedCode(NSAttributedString(string: composed))
        let original = MarkdownNativeCodeText.displayText(source: composed, prepared: prepared)
        let stale = MarkdownNativeCodeText.displayText(source: decomposed, prepared: prepared)
        XCTAssertEqual(Array(stale.string.utf8), Array(decomposed.utf8))
        XCTAssertNil(prepared.nativeDisplay.measurements(for: stale))
        XCTAssertNotNil(prepared.nativeDisplay.measurements(for: original))
        let state = MarkdownNativeCodeText.Coordinator()
        let view = UITextView()
        MarkdownNativeCodeText(source: composed, prepared: prepared, wraps: true,
                               colorScheme: .light).update(view, state: state)
        let oldMeasurements = state.measurements
        MarkdownNativeCodeText(source: decomposed, prepared: prepared, wraps: true,
                               colorScheme: .light).update(view, state: state)
        XCTAssertEqual(Array(view.attributedText.string.utf8), Array(decomposed.utf8))
        XCTAssertFalse(state.measurements === oldMeasurements)
    }

    @MainActor
    func testNativePreparedDisplayLifetimeEndsWithLastRevisionCopy() {
        weak var holder: MarkdownNativeCodeDisplay?
        var retainedCopy: MarkdownPreparedCode?
        autoreleasepool {
            let prepared = MarkdownPreparedCode(NSAttributedString(string: "let value = 1"))
            holder = prepared.nativeDisplay
            retainedCopy = prepared
            _ = MarkdownNativeCodeText.displayText(source: "let value = 1", prepared: prepared)
        }
        XCTAssertNotNil(holder)
        XCTAssertEqual(retainedCopy?.nativeDisplay.constructionCount, 1)
        retainedCopy = nil
        XCTAssertNil(holder, "No global cache or captured preparation closure may retain a revision")
    }

    @MainActor
    func testNativePreparedDisplayReusedByRemountedLeavesWithoutSharingTextStorage() throws {
        let source = "let value = 1\n\n" + String(repeating: "long code ", count: 20) + "\n"
        let prepared = MarkdownPreparedCode(NSAttributedString(string: source, attributes: [
            .foregroundColor: UIColor.systemPink
        ]))
        let expected = MarkdownNativeCodeText.displayText(source: source, prepared: prepared)
        func findText(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.lazy.compactMap { findText($0) }.first
        }
        // New hosts force new representable coordinators, as on warm remount.
        // Width/wrap are layout inputs, not display-representation keys.
        for (width, wraps) in [(CGFloat(220), false), (CGFloat(340), true), (CGFloat(220), true)] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
            let host = UIHostingController(rootView: MarkdownNativeCodeText(
                source: source, prepared: prepared, wraps: wraps, colorScheme: .light
            ))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            let leaf = try XCTUnwrap(findText(host.view))
            let directReference = UITextView()
            directReference.attributedText = expected
            directReference.textContainer.lineBreakMode = wraps ? .byWordWrapping : .byClipping
            // UIKit supplies default paragraph tab stops when installing text.
            // Compare every installed attribute with an independently assigned
            // UIKit reference, plus exact source bytes, rather than raw storage.
            XCTAssertTrue(leaf.attributedText.isEqual(to: directReference.attributedText))
            XCTAssertEqual(Array(leaf.attributedText.string.utf8), Array(expected.string.utf8))
            XCTAssertEqual(leaf.accessibilityAttributedValue?.string, expected.string)
            XCTAssertTrue(leaf.isSelectable)
            leaf.selectedRange = NSRange(location: 4, length: 5)
            XCTAssertEqual(leaf.selectedRange, NSRange(location: 4, length: 5))
            leaf.textStorage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "var")
            XCTAssertTrue(expected.string.hasPrefix("let"), "Each TextKit leaf must own its mutable storage")
            XCTAssertEqual(prepared.nativeDisplay.constructionCount, 1)
        }
    }

    @MainActor
    func testNativeUnwrappedTextKitSizingMatchesAttributedDrawingMetrics() {
        let tall = (0..<320).map { "let value_\($0) = Array(0..<1_000).reduce(0, +)" }.joined(separator: "\n")
        let cases = [
            "", "\n", "first\n\nlast\n", "a\tb\t中文", "emoji 👩🏽‍💻 and العربية",
            String(repeating: "wide λ ", count: 50), tall,
            (0..<320).map { "line \($0) let value = \($0) // λ👩🏽‍💻" }.joined(separator: "\n")
        ]
        for source in cases {
            let highlighted = NSMutableAttributedString(string: source, attributes: [
                .foregroundColor: UIColor.systemPink
            ])
            if highlighted.length > 0 {
                highlighted.addAttribute(.foregroundColor, value: UIColor.systemBlue,
                                         range: NSRange(location: 0, length: min(8, highlighted.length)))
            }
            for prepared in [nil, MarkdownPreparedCode(highlighted)] {
                let text = MarkdownNativeCodeText.displayText(source: source, prepared: prepared)
                let view = UITextView()
                view.isScrollEnabled = false
                view.textContainerInset = .zero
                view.textContainer.lineFragmentPadding = 0
                view.textContainer.lineBreakMode = .byClipping
                view.attributedText = text
                let mountedText = view.attributedText!
                XCTAssertEqual(mountedText.string, text.string)
                if source == tall {
                    XCTAssertTrue(MarkdownNativeCodeText.isTextKitSizingEligible(mountedText),
                                  "The rich-code sized fixture must exercise the TextKit path")
                } else if source.contains("\t") || source.contains("λ") || source.contains("👩🏽‍💻") {
                    XCTAssertFalse(MarkdownNativeCodeText.isTextKitSizingEligible(mountedText),
                                   "Unicode and tab metrics must retain the baseline operation")
                }
                let baseline = mountedText.boundingRect(
                    with: CGSize(width: 100_000, height: 1_000_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
                ).size
                let measured = MarkdownNativeCodeText.unwrappedTextKitSize(view, width: 100_000)
                XCTAssertEqual(ceil(measured.width), ceil(baseline.width), accuracy: 1,
                               "Width differs for \(source.utf8.count) bytes, highlighted=\(prepared != nil)")
                XCTAssertEqual(ceil(measured.height), ceil(baseline.height), accuracy: 2,
                               "Height differs for \(source.utf8.count) bytes, highlighted=\(prepared != nil)")
            }
        }
    }

    private func nativeCodeCopySelections() -> [(source: String, range: NSRange, expected: String)] {
        var cases: [(source: String, range: NSRange, expected: String)] = []
        for source in ["", "\n", "a\n\nb", "\n\na\n", "a\r\n\r\nb\r\n",
                       "a\rb", "😀\u{2028}\u{2029}z", "e\u{301}\r\n中文"] {
            let display = MarkdownNativeCodeText.displayText(source: source, prepared: nil)
            cases.append((source, NSRange(location: 0, length: display.length), source))
        }
        cases += [
            ("a\n\nb", NSRange(location: 2, length: 1), ""), // Only the blank-line placeholder.
            ("a\n\nb", NSRange(location: 1, length: 3), "\n\n"),
            ("a\n\nb", NSRange(location: 3, length: 2), "\nb"),
            ("secret\npublic\nhidden", NSRange(location: 7, length: 3), "pub"),
            ("a\r\n\r\nb", NSRange(location: 1, length: 1), "\r\n"),
            ("a\r\n\r\nb", NSRange(location: 2, length: 2), "\r\n"),
            ("a\r\n\r\nb", NSRange(location: 4, length: 1), "b"),
            ("a\rb", NSRange(location: 1, length: 1), "\r"),
            ("😀\u{2028}\u{2029}z", NSRange(location: 0, length: 2), "😀"),
            ("😀\u{2028}\u{2029}z", NSRange(location: 2, length: 3), "\u{2028}\u{2029}"),
            ("😀\u{2028}\u{2029}z", NSRange(location: 3, length: 1), ""),
            ("😀\u{2028}\u{2029}z", NSRange(location: 5, length: 1), "z"),
            ("e\u{301}\r\n中文", NSRange(location: 0, length: 2), "e\u{301}"),
            ("e\u{301}\r\n中文", NSRange(location: 3, length: 1), "中")
        ]
        return cases
    }

    @MainActor
    func testNativeCodeCopyRangeMappingPreservesSourceSeparatorsAndSelection() {
        for item in nativeCodeCopySelections() {
            let result = MarkdownNativeCodeTextView.selectedSourceText(item.source, displayRange: item.range)
            XCTAssertEqual(result.map { Array($0.utf8) }, Array(item.expected.utf8),
                           "Source: \(String(reflecting: item.source)), range: \(item.range)")
        }
        XCTAssertEqual(MarkdownNativeCodeTextView.selectedSourceText("a\n\nb",
            displayRange: NSRange(location: 2, length: 0)), "")
        for range in [NSRange(location: NSNotFound, length: 1),
                      NSRange(location: 6, length: 0), NSRange(location: 4, length: Int.max)] {
            XCTAssertNil(MarkdownNativeCodeTextView.selectedSourceText("a\n\nb", displayRange: range))
        }
    }

    @MainActor
    func testNativeCodeTextViewCopyUsesOnlySelectedOriginalSource() {
        let savedItems = UIPasteboard.general.items
        defer { UIPasteboard.general.items = savedItems }
        let view = MarkdownNativeCodeTextView()
        view.isEditable = false
        view.isSelectable = true
        let state = MarkdownNativeCodeText.Coordinator()
        for item in nativeCodeCopySelections() {
            MarkdownNativeCodeText(source: item.source, prepared: nil, wraps: true,
                                   colorScheme: .light).update(view, state: state)
            view.selectedRange = item.range
            UIPasteboard.general.string = "sentinel"
            view.copy(nil)
            XCTAssertEqual(UIPasteboard.general.string.map { Array($0.utf8) }, Array(item.expected.utf8),
                           "Source: \(String(reflecting: item.source)), range: \(item.range)")
            XCTAssertEqual(view.attributedText.string,
                           MarkdownNativeCodeText.displayText(source: item.source, prepared: nil).string)
        }
        view.selectedRange = NSRange(location: 0, length: 0)
        UIPasteboard.general.string = "sentinel"
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "sentinel")
    }

    func testNativeCodeEligibilityAndLineContentParity() {
        XCTAssertTrue(MarkdownNativeCodeText.isEligible(String(repeating: "a\n", count: 8_192)))
        XCTAssertTrue(MarkdownNativeCodeText.isEligible(String(repeating: "x", count: 500)))
        XCTAssertFalse(MarkdownNativeCodeText.isEligible(String(repeating: "x", count: 501)))
        XCTAssertFalse(MarkdownNativeCodeText.isEligible(String(repeating: "a\n", count: 32_769)))

        for source in ["", "\n", "first\r\n\r\nlast\r\n", "العربية\u{2028}👩🏽‍💻\u{2029}中文"] {
            let expected = MarkdownPlainCodeFormatter.lines(in: source)
                .map { $0.segments.map(\.text).joined() }.joined(separator: "\n")
            XCTAssertEqual(MarkdownNativeCodeText.displayText(source: source, prepared: nil).string, expected)
            let highlighted = NSMutableAttributedString(string: source, attributes: [.foregroundColor: UIColor.systemPink])
            let prepared = MarkdownPreparedCode(highlighted)
            let attributed = MarkdownNativeCodeText.displayText(source: source, prepared: prepared)
            XCTAssertEqual(attributed.string, expected)
            if source.contains(where: { !$0.isNewline }) {
                XCTAssertTrue(foregroundColorSignatures(in: attributed, userInterfaceStyle: .light)
                    .contains(colorSignature(for: .systemPink, userInterfaceStyle: .light)!))
            } else {
                // The legacy attributed formatter inserts unstyled spaces for
                // empty lines; separator-only input has no colored source glyph.
                XCTAssertFalse(foregroundColorSignatures(in: attributed, userInterfaceStyle: .light)
                    .contains(colorSignature(for: .systemPink, userInterfaceStyle: .light)!))
            }
        }
    }

    @MainActor
    func testMountedNativeCodeLeafPreservesSourceSpacingWrapAndSelection() async throws {
        let key = ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)
        let source = String(repeating: "wrap this long code line ", count: 6) + "\n\nend\n"
        let model = MountedMarkdownRendererModel(content: "```text\n\(source)```", isStreaming: false)
        model.nativeCodeText = true
        model.fullInlineCode = true
        let fixture = MountedMarkdownRendererFixture(model: model, width: 220)
        defer { fixture.tearDown() }
        let legacyModel = MountedMarkdownRendererModel(content: model.content, isStreaming: false)
        let legacyFixture = MountedMarkdownRendererFixture(model: legacyModel, width: 220)
        defer { legacyFixture.tearDown() }
        await fixture.settle()
        await legacyFixture.settle()
        let leaf = try XCTUnwrap(fixture.nativeCodeTextView())
        // MarkdownUI excludes the newline before the closing fence from the
        // code-block content; direct formatter coverage above owns true tails.
        let parsedCode = String(source.dropLast())
        let expected = MarkdownPlainCodeFormatter.lines(in: parsedCode).map { $0.segments.map(\.text).joined() }.joined(separator: "\n")
        XCTAssertEqual(leaf.attributedText.string, expected)
        XCTAssertTrue(leaf.isSelectable)
        XCTAssertTrue(leaf.isAccessibilityElement)
        XCTAssertEqual(leaf.accessibilityValue, expected)
        XCTAssertEqual(leaf.accessibilityAttributedValue?.string, expected)
        XCTAssertEqual(leaf.textContainerInset, .zero)
        let paragraph = try XCTUnwrap(leaf.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.paragraphSpacing, 3)
        XCTAssertEqual(paragraph.lineSpacing, 13 * 0.18, accuracy: 0.01)
        let lastParagraph = try XCTUnwrap(leaf.attributedText.attribute(
            .paragraphStyle, at: leaf.attributedText.length - 1, effectiveRange: nil
        ) as? NSParagraphStyle)
        XCTAssertEqual(lastParagraph.paragraphSpacing, 0)
        let unwrappedHeight = fixture.height()
        XCTAssertGreaterThan(leaf.bounds.width, 220, "Unwrapped code must keep horizontal overflow.")
        XCTAssertEqual(unwrappedHeight, legacyFixture.height(), accuracy: 8)
        UserDefaults.standard.set(true, forKey: key)
        try await Task.sleep(for: .milliseconds(300))
        await fixture.settle()
        await legacyFixture.settle()
        let wrappedHeight = fixture.height()
        XCTAssertGreaterThan(wrappedHeight, unwrappedHeight + 10)
        XCTAssertEqual(wrappedHeight, legacyFixture.height(), accuracy: 8)
        XCTAssertEqual(fixture.nativeCodeTextView()?.attributedText.string, expected)
        XCTAssertEqual(fixture.nativeCodeTextView()?.accessibilityValue, expected)
    }

    @MainActor
    func testMountedNativeHighlightedCodeHasCompletePlainAccessibilityValueAndSelection() async throws {
        let tail = "let final_Ω = \"最後 👩🏽‍💻\""
        let code = (0..<240).map { "let value_\($0) = \"λ👩🏽‍💻 \($0)\" // syntax" }
            .joined(separator: "\n") + "\n" + tail
        XCTAssertTrue(MarkdownNativeCodeText.isEligible(code))
        let model = MountedMarkdownRendererModel(content: "```swift\n\(code)\n```", isStreaming: false)
        model.nativeCodeText = true
        model.fullInlineCode = true
        let fixture = MountedMarkdownRendererFixture(model: model, width: 340)
        defer { fixture.tearDown() }

        let deadline = CACurrentMediaTime() + 8
        var highlightedLeaf: UITextView?
        repeat {
            await fixture.settle()
            if let leaf = fixture.nativeCodeTextView(), leaf.attributedText.string == code,
               foregroundColorSignatures(in: leaf.attributedText, userInterfaceStyle: .light).count > 1 {
                highlightedLeaf = leaf
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        } while CACurrentMediaTime() < deadline
        let leaf = try XCTUnwrap(highlightedLeaf, "Long Swift code did not mount with syntax colors")
        let lightColors = foregroundColorSignatures(in: leaf.attributedText, userInterfaceStyle: .light)
        XCTAssertTrue(leaf.isSelectable)
        XCTAssertTrue(leaf.isAccessibilityElement)
        XCTAssertEqual(leaf.accessibilityValue, code)
        // iOS Simulator 26.5 accepts these AX blocks but does not implement
        // their getter selectors. Check the mounted view's effective values.
        let spoken = try XCTUnwrap(leaf.accessibilityAttributedValue)
        XCTAssertEqual(spoken.string, code)
        XCTAssertTrue(spoken.attributes(at: 0, effectiveRange: nil).isEmpty,
                      "AX value must not serialize syntax, font, or paragraph runs")
        var spokenRuns = 0
        spoken.enumerateAttributes(in: NSRange(location: 0, length: spoken.length)) { _, _, _ in spokenRuns += 1 }
        XCTAssertEqual(spokenRuns, 1)
        let tailRange = (code as NSString).range(of: tail)
        XCTAssertNotEqual(tailRange.location, NSNotFound)
        leaf.selectedRange = tailRange
        XCTAssertEqual(leaf.selectedRange, tailRange)
        XCTAssertEqual(leaf.text(in: try XCTUnwrap(leaf.selectedTextRange)), tail)

        model.colorScheme = .dark
        let darkDeadline = CACurrentMediaTime() + 5
        repeat {
            await fixture.settle()
            if let current = fixture.nativeCodeTextView(),
               current.attributedText.string == code,
               foregroundColorSignatures(in: current.attributedText, userInterfaceStyle: .light) != lightColors,
               current.accessibilityValue == code {
                XCTAssertTrue(current.isSelectable)
                if current === leaf {
                    XCTAssertEqual(current.selectedRange, tailRange,
                                   "Same-source recoloring must retain the selection")
                }
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        } while CACurrentMediaTime() < darkDeadline
        XCTFail("Recolored code did not retain full accessible text")
    }

    @MainActor
    func testMountedNativeCodeFallbackAndHighlightedRevision() async throws {
        let rejected = MountedMarkdownRendererModel(
            content: "```text\n\(String(repeating: "x", count: 501))\n```", isStreaming: false
        )
        rejected.nativeCodeText = true
        let rejectedFixture = MountedMarkdownRendererFixture(model: rejected, width: 340)
        defer { rejectedFixture.tearDown() }
        await rejectedFixture.settle()
        XCTAssertNil(rejectedFixture.nativeCodeTextView())

        let model = MountedMarkdownRendererModel(content: "```swift\nlet value = 1\n```", isStreaming: false)
        model.nativeCodeText = true
        let fixture = MountedMarkdownRendererFixture(model: model, width: 340)
        defer { fixture.tearDown() }
        let initialLeaf = await fixture.waitForNativeCodeTextView(matching: "let value = 1", timeout: 2)
        let leaf = try XCTUnwrap(initialLeaf)
        XCTAssertEqual(leaf.attributedText.string, "let value = 1")
        XCTAssertEqual(leaf.accessibilityValue, "let value = 1")
        XCTAssertTrue(leaf.isSelectable)
        model.content = "```swift\nlet value = 2\n```"
        let revisedLeaf = await fixture.waitForNativeCodeTextView(matching: "let value = 2", timeout: 2)
        XCTAssertEqual(revisedLeaf?.attributedText.string, "let value = 2")
        XCTAssertEqual(revisedLeaf?.accessibilityValue, "let value = 2")
        XCTAssertEqual(revisedLeaf?.accessibilityAttributedValue?.string, "let value = 2")
        XCTAssertFalse(revisedLeaf?.accessibilityValue?.contains("value = 1") ?? true)
    }

    @MainActor
    func testNativeCodeFullInlineAndStreamingToCompleted() async throws {
        let code = (0..<96).map { "line \($0) = \($0)" }.joined(separator: "\n")
        let markdown = "```text\n\(code)\n```"
        let previewModel = MountedMarkdownRendererModel(content: markdown, isStreaming: false)
        let previewFixture = MountedMarkdownRendererFixture(model: previewModel, width: 340)
        defer { previewFixture.tearDown() }
        await previewFixture.settle()
        let controlModel = MountedMarkdownRendererModel(content: markdown, isStreaming: false)
        controlModel.fullInlineCode = true
        let controlFixture = MountedMarkdownRendererFixture(model: controlModel, width: 340)
        defer { controlFixture.tearDown() }
        await controlFixture.settle()
        XCTAssertNil(controlFixture.nativeCodeTextView())
        XCTAssertGreaterThan(controlFixture.height(), previewFixture.height() + 100)

        let firstChunk = (0..<8).map { "line \($0) = \($0)" }.joined(separator: "\n")
        let model = MountedMarkdownRendererModel(content: "```text\n\(firstChunk)", isStreaming: true)
        model.nativeCodeText = true
        model.fullInlineCode = true
        let fixture = MountedMarkdownRendererFixture(model: model, width: 340)
        defer { fixture.tearDown() }
        let openLeaf = await fixture.waitForNativeCodeTextView(containing: "line 7 = 7", timeout: 2)
        XCTAssertNotNil(openLeaf, "Open streaming fence did not publish its current code")
        XCTAssertTrue(openLeaf?.attributedText.string.contains("line 0 = 0") == true)
        let appendedCode = (0..<95).map { "line \($0) = \($0)" }.joined(separator: "\n")
        model.content = "```text\n\(appendedCode)"
        let appendedLeaf = await fixture.waitForNativeCodeTextView(containing: "line 94 = 94", timeout: 2)
        XCTAssertNotNil(appendedLeaf, "Appended open fence did not publish its current code")
        model.content = markdown
        XCTAssertTrue(model.isStreaming)
        let closedStreamingLeaf = await fixture.waitForNativeCodeTextView(matching: code, timeout: 2)
        XCTAssertNotNil(closedStreamingLeaf, "Closed streaming fence did not publish complete code")
        model.isStreaming = false
        let mountedLeaf = await fixture.waitForNativeCodeTextView(matching: code, timeout: 2)
        let leaf = try XCTUnwrap(mountedLeaf, "Native code leaf did not mount within 2 seconds after streaming ended")
        XCTAssertTrue(leaf.attributedText.string.contains("line 95 = 95"))
        XCTAssertEqual(leaf.attributedText.string.components(separatedBy: "\n").count, 96)
        XCTAssertEqual(leaf.accessibilityValue, code)

        model.content = "```text\nreplacement\n```"
        let replacementLeaf = await fixture.waitForNativeCodeTextView(matching: "replacement", timeout: 2)
        XCTAssertEqual(replacementLeaf?.attributedText.string, "replacement")
        XCTAssertEqual(replacementLeaf?.accessibilityValue, "replacement")
    }
#endif
}

#if DEBUG
@MainActor
@Observable
private final class MountedStreamingBlockModel {
    var content: String
    var colorScheme: ColorScheme = .light
    var reevaluation = 0
    var identity = 0

    init(content: String) { self.content = content }
}

@MainActor
private final class MountedStreamingBlockProbe {
    private(set) var initializationCount = 0
    private(set) var fullContent = ""

    func observe(isInitialization: Bool, segments: StreamingMarkdownBlockSegments) {
        if isInitialization { initializationCount += 1 }
        fullContent = segments.stableChunks.map(\.text).joined() + segments.activeMarkdown
    }
}

private struct MountedStreamingBlockRoot: View {
    let model: MountedStreamingBlockModel
    let probe: MountedStreamingBlockProbe

    var body: some View {
        StreamingMarkdownChunkedView(
            content: model.content,
            colorScheme: model.colorScheme,
            onBlockStateChange: probe.observe
        )
        .id(model.identity)
        .padding(.top, CGFloat(model.reevaluation % 2))
        .environment(\.chatNativeCodeText, true)
        .environment(\.chatFullInlineCode, true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private final class MountedStreamingBlockFixture {
    private let window: UIWindow
    private let host: UIHostingController<MountedStreamingBlockRoot>
    private let probe: MountedStreamingBlockProbe

    init(model: MountedStreamingBlockModel, probe: MountedStreamingBlockProbe) {
        self.probe = probe
        host = UIHostingController(rootView: MountedStreamingBlockRoot(model: model, probe: probe))
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 340, height: 900))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
    }

    func height() -> CGFloat {
        host.sizeThatFits(in: CGSize(width: 340, height: UIView.layoutFittingCompressedSize.height)).height
    }

    func settle() async {
        await Task.yield()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await Task.yield()
    }

    func waitForCode(_ expected: String, content: String) async -> UITextView? {
        let deadline = CACurrentMediaTime() + 2
        repeat {
            await settle()
            if probe.fullContent == content, let view = codeView(), view.attributedText.string == expected,
               view.accessibilityValue == expected, view.isSelectable {
                return view
            }
            try? await Task.sleep(for: .milliseconds(20))
        } while CACurrentMediaTime() < deadline
        return nil
    }

    func hideAndShow() {
        window.isHidden = true
        window.isHidden = false
        host.view.layoutIfNeeded()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func codeView() -> UITextView? {
        func find(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView, text.accessibilityIdentifier == "native-inline-code-text" {
                return text
            }
            for child in view.subviews {
                if let match = find(child) { return match }
            }
            return nil
        }
        return find(host.view)
    }
}
#endif

@MainActor
@Observable
private final class MountedMarkdownRendererModel {
    var content: String
    var isStreaming: Bool
    var colorScheme: ColorScheme = .light
#if DEBUG
    var nativeCodeText = false
    var fullInlineCode = false
#endif

    init(content: String, isStreaming: Bool) {
        self.content = content
        self.isStreaming = isStreaming
    }
}

private struct MountedMarkdownRendererRoot: View {
    let model: MountedMarkdownRendererModel

    var body: some View {
        MarkdownRenderer(content: model.content, isStreaming: model.isStreaming)
            .environment(\.colorScheme, model.colorScheme)
#if DEBUG
            .environment(\.chatNativeCodeText, model.nativeCodeText)
            .environment(\.chatFullInlineCode, model.fullInlineCode)
#endif
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private final class MountedMarkdownRendererFixture {
    private let width: CGFloat
    private let window: UIWindow
    private let hostingController: UIHostingController<MountedMarkdownRendererRoot>

    init(model: MountedMarkdownRendererModel, width: CGFloat) {
        self.width = width
        hostingController = UIHostingController(rootView: MountedMarkdownRendererRoot(model: model))
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        window.rootViewController = hostingController
        window.isHidden = false
        hostingController.view.frame = window.bounds
        hostingController.view.layoutIfNeeded()
    }

    func height() -> CGFloat {
        hostingController.sizeThatFits(
            in: CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        ).height
    }

    func settle() async {
        await Task.yield()
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        await Task.yield()
    }

#if DEBUG
    func waitForNativeCodeTextView(
        matching expected: String? = nil,
        containing fragment: String? = nil,
        timeout: TimeInterval
    ) async -> UITextView? {
        let deadline = CACurrentMediaTime() + timeout
        repeat {
            await settle()
            if let view = nativeCodeTextView(),
               (expected == nil || view.attributedText.string == expected),
               (fragment.map { view.attributedText.string.contains($0) } ?? true) {
                return view
            }
            try? await Task.sleep(for: .milliseconds(20))
        } while CACurrentMediaTime() < deadline
        return nil
    }

    func nativeCodeTextView() -> UITextView? {
        func find(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView, text.accessibilityIdentifier == "native-inline-code-text" { return text }
            for child in view.subviews {
                if let match = find(child) { return match }
            }
            return nil
        }
        return find(hostingController.view)
    }
#endif

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

private func foregroundColorSignatures(in attributedString: NSAttributedString, userInterfaceStyle: UIUserInterfaceStyle) -> Set<String> {
    var colors: Set<String> = []
    attributedString.enumerateAttribute(
        .foregroundColor,
        in: NSRange(location: 0, length: attributedString.length)
    ) { value, _, _ in
        guard let color = value as? UIColor,
              let signature = colorSignature(for: color, userInterfaceStyle: userInterfaceStyle) else {
            return
        }

        colors.insert(signature)
    }
    return colors
}

private func colorSignature(for color: UIColor?, userInterfaceStyle: UIUserInterfaceStyle) -> String? {
    guard let color else { return nil }

    let resolvedColor = color.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: userInterfaceStyle)
    )
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0

    if resolvedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
        return [red, green, blue, alpha]
            .map { String(format: "%.3f", Double($0)) }
            .joined(separator: ",")
    }

    var white: CGFloat = 0
    if resolvedColor.getWhite(&white, alpha: &alpha) {
        return [white, alpha]
            .map { String(format: "%.3f", Double($0)) }
            .joined(separator: ",")
    }

    return nil
}

private func colorSignature(in attributedString: NSAttributedString, at location: Int, userInterfaceStyle: UIUserInterfaceStyle) -> String? {
    colorSignature(
        for: attributedString.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor,
        userInterfaceStyle: userInterfaceStyle
    )
}

final class MathFenceLanguageTests: XCTestCase {
    func testMathLanguagesMatch() {
        XCTAssertTrue(MathFenceLanguage.matches("math"))
        XCTAssertTrue(MathFenceLanguage.matches("latex"))
        XCTAssertTrue(MathFenceLanguage.matches("tex"))
    }

    func testMatchingIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(MathFenceLanguage.matches("Math"))
        XCTAssertTrue(MathFenceLanguage.matches("  LaTeX  "))
        XCTAssertTrue(MathFenceLanguage.matches("TEX"))
    }

    func testFirstInfoTokenIsUsed() {
        // Markdown info strings can carry extra tokens after the language.
        XCTAssertTrue(MathFenceLanguage.matches("math title=Quadratic"))
    }

    func testNonMathLanguagesDoNotMatch() {
        XCTAssertFalse(MathFenceLanguage.matches("swift"))
        XCTAssertFalse(MathFenceLanguage.matches("python"))
        XCTAssertFalse(MathFenceLanguage.matches("json"))
    }

    func testNilOrEmptyLanguageDoesNotMatch() {
        XCTAssertFalse(MathFenceLanguage.matches(nil))
        XCTAssertFalse(MathFenceLanguage.matches(""))
        XCTAssertFalse(MathFenceLanguage.matches("   "))
    }
}

#if DEBUG
extension MarkdownMathRendererTests {
    private func cachedRequest(_ code: String = "let value = 1", language: String? = "swift",
                               scheme: ColorScheme = .light, streaming: Bool = false) -> MarkdownCodeHighlightRequest {
        MarkdownCodeHighlightRequest(code: code, language: language, colorScheme: scheme, isStreaming: streaming)
    }

    private func cachedPrepared(_ worker: MarkdownCodeHighlightWorker,
                                _ request: MarkdownCodeHighlightRequest) async throws -> MarkdownPreparedCode {
        guard case .highlighted(let value) = await worker.highlightedCode(for: request) else {
            XCTFail("Expected a completed highlighted revision")
            throw NSError(domain: "PreparedRevisionTest", code: 1)
        }
        return value
    }

    @MainActor
    func testPreparedRevisionCacheReusesCompletedIdentityWithoutSharingNativeStorage() async throws {
        let worker = MarkdownCodeHighlightWorker(cacheConfiguration: .nativeExperiment)
        let request = cachedRequest()
        let first = try await cachedPrepared(worker, request)
        let second = try await cachedPrepared(worker, request)
        XCTAssertTrue(first.nativeDisplay === second.nativeDisplay)
        let display = MarkdownNativeCodeText.displayText(source: request.code, prepared: first)
        XCTAssertTrue(display === MarkdownNativeCodeText.displayText(source: request.code, prepared: second))
        let a = UITextView()
        let b = UITextView()
        a.attributedText = display
        b.attributedText = display
        XCTAssertFalse(a.textStorage === b.textStorage)
        XCTAssertFalse(a.layoutManager === b.layoutManager)
        a.textStorage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "var")
        XCTAssertEqual(b.textStorage.string, display.string)
        XCTAssertEqual(display.string, request.code)
        XCTAssertEqual(first.nativeDisplay.constructionCount, 1)
    }

    @MainActor
    func testPreparedRevisionCacheSeparatesExactBytesLanguageThemeAndStreaming() async throws {
        let worker = MarkdownCodeHighlightWorker(cacheConfiguration: .nativeExperiment)
        let original = cachedRequest("let café = 1")
        let first = try await cachedPrepared(worker, original)
        let variants = [cachedRequest("let cafe\u{301} = 1"), cachedRequest("let café = 2"),
                        cachedRequest(original.code, language: "Swift"),
                        cachedRequest(original.code, scheme: .dark)]
        XCTAssertEqual(original.code, variants[0].code, "Exercise canonical-equivalent Swift strings")
        for request in variants {
            let value = try await cachedPrepared(worker, request)
            XCTAssertFalse(first.nativeDisplay === value.nativeDisplay)
            XCTAssertEqual(Array(String(value.fullText.characters).utf8), Array(request.code.utf8))
        }
        guard case .plain(let reason, let language) = await worker.highlightedCode(
            for: cachedRequest(original.code, streaming: true)) else {
            return XCTFail("Streaming must stay plain even after a completed cache hit")
        }
        XCTAssertEqual(reason, .streaming)
        XCTAssertEqual(language, "swift")
        let again = try await cachedPrepared(worker, original)
        XCTAssertTrue(first.nativeDisplay === again.nativeDisplay)
    }

    @MainActor
    func testPreparedRevisionCacheEvictsLeastRecentlyUsedByCountAndCost() async throws {
        let a = cachedRequest("let a = 1")
        let b = cachedRequest("let b = 2")
        let c = cachedRequest("let c = 3")
        let worker = MarkdownCodeHighlightWorker(cacheConfiguration: .init(maxEntries: 2, maxCost: 1_000_000))
        let firstA = try await cachedPrepared(worker, a)
        let firstB = try await cachedPrepared(worker, b)
        let hitA = try await cachedPrepared(worker, a)
        XCTAssertTrue(firstA.nativeDisplay === hitA.nativeDisplay)
        _ = try await cachedPrepared(worker, c)
        let retainedA = try await cachedPrepared(worker, a)
        XCTAssertTrue(firstA.nativeDisplay === retainedA.nativeDisplay)
        let replacedB = try await cachedPrepared(worker, b)
        XCTAssertFalse(firstB.nativeDisplay === replacedB.nativeDisplay)
        let usage = await worker.preparedCacheUsage
        XCTAssertEqual(usage.count, 2)
        XCTAssertLessThanOrEqual(usage.cost, 1_000_000)

        let cost = MarkdownCodeHighlightWorker.preparedRevisionCost(firstA, for: a)
        let bounded = MarkdownCodeHighlightWorker(cacheConfiguration: .init(maxEntries: 10, maxCost: cost))
        let boundedA = try await cachedPrepared(bounded, a)
        let boundedHit = try await cachedPrepared(bounded, a)
        XCTAssertTrue(boundedA.nativeDisplay === boundedHit.nativeDisplay, "Exact budget fits")
        _ = try await cachedPrepared(bounded, b)
        let evictedA = try await cachedPrepared(bounded, a)
        XCTAssertFalse(boundedA.nativeDisplay === evictedA.nativeDisplay)
        let boundedUsage = await bounded.preparedCacheUsage
        XCTAssertEqual(boundedUsage.count, 1)
        XCTAssertLessThanOrEqual(boundedUsage.cost, cost)

        let tooSmall = MarkdownCodeHighlightWorker(cacheConfiguration: .init(maxEntries: 10, maxCost: cost - 1))
        let uncached = try await cachedPrepared(tooSmall, a)
        let repeated = try await cachedPrepared(tooSmall, a)
        XCTAssertFalse(uncached.nativeDisplay === repeated.nativeDisplay)
        let empty = await tooSmall.preparedCacheUsage
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.cost, 0)
    }

    @MainActor
    func testPreparedRevisionCachePreservesPlainOutcomesAndOptOut() async throws {
        let worker = MarkdownCodeHighlightWorker(cacheConfiguration: .nativeExperiment)
        let requests = [cachedRequest(""), cachedRequest(language: nil),
                        cachedRequest(language: "not-a-language"), cachedRequest(language: "text"),
                        cachedRequest(streaming: true), cachedRequest(String(repeating: "x", count: 4_001)),
                        cachedRequest(String(repeating: "x\n", count: 2_001)),
                        cachedRequest(String(repeating: "x", count: 80_001))]
        for request in requests {
            guard case .plain(let expectedReason, let expectedLanguage) = MarkdownCodeHighlighter.highlightedCode(for: request) else {
                return XCTFail("Fixture must take a plain path")
            }
            for _ in 0..<2 {
                guard case .plain(let reason, let language) = await worker.highlightedCode(for: request) else {
                    return XCTFail("Cache must not relabel plain results")
                }
                XCTAssertEqual(reason, expectedReason)
                XCTAssertEqual(language, expectedLanguage)
            }
        }
        let usage = await worker.preparedCacheUsage
        XCTAssertEqual(usage.count, 0)
        for arguments in [[], ["--chat-rich-native-code-text", "--chat-native-prepared-cache-disabled"]] {
            let disabled = MarkdownCodeHighlightWorker(cacheConfiguration: .experiment(arguments: arguments))
            let a = try await cachedPrepared(disabled, cachedRequest())
            let b = try await cachedPrepared(disabled, cachedRequest())
            XCTAssertFalse(a.nativeDisplay === b.nativeDisplay)
            let disabledUsage = await disabled.preparedCacheUsage
            XCTAssertEqual(disabledUsage.count, 0)
        }
        XCTAssertEqual(MarkdownPreparedRevisionCacheConfiguration.experiment(
            arguments: ["--chat-rich-native-code-text"]).maxEntries, 32)
    }

    @MainActor
    func testPreparedRevisionCacheSkipsOversizedKeysWithoutEvictingCurrentEntry() async throws {
        let worker = MarkdownCodeHighlightWorker(cacheConfiguration: .nativeExperiment)
        let request = cachedRequest()
        let original = try await cachedPrepared(worker, request)
        let before = await worker.preparedCacheKeyConstructionCount
        for oversized in [cachedRequest(String(repeating: "x", count: 80_001)),
                          cachedRequest(String(repeating: "x\n", count: 2_001)),
                          cachedRequest(language: String(repeating: "x", count: 80_001))] {
            guard case .plain = await worker.highlightedCode(for: oversized) else {
                return XCTFail("Oversized or unsupported input must keep its plain fallback")
            }
        }
        let after = await worker.preparedCacheKeyConstructionCount
        XCTAssertEqual(after, before, "Fallback inputs must not allocate copied cache keys")
        let usage = await worker.preparedCacheUsage
        XCTAssertEqual(usage.count, 1)
        let retained = try await cachedPrepared(worker, request)
        XCTAssertTrue(original.nativeDisplay === retained.nativeDisplay)

        let cost = MarkdownCodeHighlightWorker.preparedRevisionCost(original, for: request)
        let small = MarkdownCodeHighlightWorker(cacheConfiguration: .init(maxEntries: 2, maxCost: cost))
        let first = try await cachedPrepared(small, request)
        let countBefore = await small.preparedCacheKeyConstructionCount
        // Highlight-eligible, but its cheap source charge alone cannot fit.
        _ = try await cachedPrepared(small, cachedRequest(String(repeating: "let value = 1\n", count: 100)))
        let countAfter = await small.preparedCacheKeyConstructionCount
        XCTAssertEqual(countAfter, countBefore)
        let again = try await cachedPrepared(small, request)
        XCTAssertTrue(first.nativeDisplay === again.nativeDisplay)
    }

    @MainActor
    func testPreparedRevisionCacheReleasesEvictedHolder() async throws {
        let worker = MarkdownCodeHighlightWorker(cacheConfiguration: .init(maxEntries: 1, maxCost: 1_000_000))
        weak var holder: MarkdownNativeCodeDisplay?
        do {
            let first = try await cachedPrepared(worker, cachedRequest())
            holder = first.nativeDisplay
        }
        XCTAssertNotNil(holder, "Cache keeps the completed revision alive after unmount")
        _ = try await cachedPrepared(worker, cachedRequest("let other = 2"))
        XCTAssertNil(holder, "Eviction releases a revision with no mounted owners")
    }

    @MainActor
    func testPreparedRevisionCacheFitsRichThirtySourceFamily() async throws {
        // Code generation mirrors makeRichThirtyPerformanceLabFixture, without
        // constructing its model or touching its process-wide restore store.
        let worker = MarkdownCodeHighlightWorker(cacheConfiguration: .nativeExperiment)
        var revisions: [MarkdownPreparedCode] = []
        var requests: [MarkdownCodeHighlightRequest] = []
        for index in 0..<30 {
            let codeLines = 40 + (index % 5) * 12
            var code = String(repeating: "let row\(index) = records.filter { $0.group == \(index) }.map { $0.id }\n", count: codeLines)
            if index % 3 == 0 {
                code += String(repeating: "let wrapMarker\(index) = \"a deliberately long wrapping line that must wrap across the viewport without losing its tail marker \(index)\"\n", count: 3)
            }
            if index == 29 {
                code += "let richGroupFinalSourceLine30 = \"SEMREH_RICH30_CODE_END\"\n"
            }
            XCTAssertTrue(MarkdownNativeCodeText.isEligible(code))
            let request = cachedRequest(code)
            requests.append(request)
            revisions.append(try await cachedPrepared(worker, request))
        }
        for (request, revision) in zip(requests, revisions) {
            let remount = try await cachedPrepared(worker, request)
            XCTAssertTrue(revision.nativeDisplay === remount.nativeDisplay)
        }
        let usage = await worker.preparedCacheUsage
        XCTAssertEqual(usage.count, 30)
        XCTAssertLessThanOrEqual(usage.cost, MarkdownPreparedRevisionCacheConfiguration.nativeExperiment.maxCost)
    }

    @MainActor
    func testPreparedRevisionCacheConcurrentRequestsPublishOneRevision() async throws {
        let worker = MarkdownCodeHighlightWorker(cacheConfiguration: .nativeExperiment)
        let request = cachedRequest()
        let results = await withTaskGroup(of: MarkdownPreparedCodeResult.self) { group in
            for _ in 0..<12 {
                group.addTask { await worker.highlightedCode(for: request) }
            }
            var values: [MarkdownPreparedCode] = []
            for await result in group {
                if case .highlighted(let value) = result { values.append(value) }
            }
            return values
        }
        XCTAssertEqual(results.count, 12)
        let first = try XCTUnwrap(results.first)
        XCTAssertTrue(results.allSatisfy { $0.nativeDisplay === first.nativeDisplay })
        let usage = await worker.preparedCacheUsage
        XCTAssertEqual(usage.count, 1)
    }
}
#endif

#if DEBUG
extension MarkdownMathRendererTests {
    @MainActor
    func testPreparedSyncHitReusesIdentityAndMemoizesColdMiss() async throws {
        let worker = MarkdownCodeHighlightWorker(cacheConfiguration: .nativeExperiment)
        let request = cachedRequest()
        let flags = ["--chat-native-prepared-sync-hit"]
        let cold = MarkdownPreparedSyncLookup()
        XCTAssertNil(cold.completedCode(for: request, worker: worker, nativeEnabled: true, arguments: flags))
        let empty = await worker.preparedCacheUsage
        XCTAssertEqual(empty.count, 0, "Synchronous lookup must never prepare")
        let keys = await worker.preparedCacheKeyConstructionCount
        XCTAssertNil(cold.completedCode(for: request, worker: worker, nativeEnabled: true, arguments: flags))
        let repeatedKeys = await worker.preparedCacheKeyConstructionCount
        XCTAssertEqual(keys, repeatedKeys)
        let prepared = try await cachedPrepared(worker, request)
        let warm = MarkdownPreparedSyncLookup()
        let hit = try XCTUnwrap(warm.completedCode(for: request, worker: worker, nativeEnabled: true, arguments: flags))
        XCTAssertTrue(hit.nativeDisplay === prepared.nativeDisplay)
        XCTAssertEqual(hit.nativeDisplay.constructionCount, 0, "Lookup must not construct native display")
        let warmKeys = await worker.preparedCacheKeyConstructionCount
        XCTAssertTrue(warm.completedCode(for: request, worker: worker, nativeEnabled: true, arguments: flags)?.nativeDisplay === hit.nativeDisplay)
        let after = await worker.preparedCacheKeyConstructionCount
        XCTAssertEqual(warmKeys, after)
    }

    @MainActor
    func testPreparedSyncHitInvalidatesExactSourceThemeLanguageAndStream() async throws {
        let worker = MarkdownCodeHighlightWorker(cacheConfiguration: .nativeExperiment)
        let original = cachedRequest("let café = 1")
        _ = try await cachedPrepared(worker, original)
        let lookup = MarkdownPreparedSyncLookup()
        let flags = ["--chat-native-prepared-sync-hit"]
        for changed in [cachedRequest("let cafe\u{301} = 1"), cachedRequest("let café = 2"),
                        cachedRequest(original.code, language: "Swift"),
                        cachedRequest(original.code, scheme: .dark),
                        cachedRequest(original.code, streaming: true)] {
            XCTAssertNotNil(lookup.completedCode(for: original, worker: worker, nativeEnabled: true, arguments: flags))
            XCTAssertNil(lookup.completedCode(for: changed, worker: worker, nativeEnabled: true, arguments: flags))
        }
    }

    @MainActor
    func testPreparedSyncHitDefaultOptOutAndEvictionBudget() async throws {
        let request = cachedRequest()
        let worker = MarkdownCodeHighlightWorker(cacheConfiguration: .init(maxEntries: 1, maxCost: 1_000_000))
        _ = try await cachedPrepared(worker, request)
        let lookup = MarkdownPreparedSyncLookup()
        for flags in [[], ["--chat-native-prepared-sync-hit", "--chat-native-prepared-cache-disabled"]] {
            XCTAssertNil(lookup.completedCode(for: request, worker: worker, nativeEnabled: true, arguments: flags))
        }
        let flags = ["--chat-native-prepared-sync-hit"]
        XCTAssertNil(lookup.completedCode(for: request, worker: worker, nativeEnabled: false, arguments: flags))
        let disabled = MarkdownCodeHighlightWorker()
        _ = try await cachedPrepared(disabled, request)
        XCTAssertNil(disabled.completedCode(for: request))
        _ = try await cachedPrepared(worker, cachedRequest("let other = 2"))
        XCTAssertNil(lookup.completedCode(for: request, worker: worker, nativeEnabled: true, arguments: flags))
        let usage = await worker.preparedCacheUsage
        XCTAssertEqual(usage.count, 1)
        XCTAssertLessThanOrEqual(usage.cost, 1_000_000)
        let tiny = MarkdownCodeHighlightWorker(cacheConfiguration: .init(maxEntries: 1, maxCost: 1_024))
        _ = try await cachedPrepared(tiny, request)
        XCTAssertNil(tiny.completedCode(for: request))
        let tinyUsage = await tiny.preparedCacheUsage
        XCTAssertEqual(tinyUsage.count, 0)
    }

    @MainActor
    func testMountedPreparedSyncHitIsHighlightedBeforeAsyncYield() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--chat-rich-native-code-text"),
              MarkdownPreparedSyncLookup.isEnabled(nativeEnabled: true, arguments: arguments) else {
            throw XCTSkip("Run with --chat-rich-native-code-text --chat-native-prepared-sync-hit")
        }
        let code = "let warmValue = 42 // first mounted layout"
        _ = try await cachedPrepared(.shared, cachedRequest(code))
        let model = MountedMarkdownRendererModel(content: "```swift\n\(code)\n```", isStreaming: false)
        model.nativeCodeText = true
        model.fullInlineCode = true
        let fixture = MountedMarkdownRendererFixture(model: model, width: 340)
        defer { fixture.tearDown() }
        // No settle/yield: this checks the initial real ChatCodeBlock leaf.
        _ = fixture.height()
        let leaf = try XCTUnwrap(fixture.nativeCodeTextView())
        XCTAssertEqual(leaf.attributedText.string, code)
        XCTAssertGreaterThan(foregroundColorSignatures(in: leaf.attributedText, userInterfaceStyle: .light).count, 1)
        XCTAssertTrue(leaf.isSelectable)
        XCTAssertEqual(leaf.accessibilityValue, code)
    }
}
#endif

extension MarkdownMathRendererTests {
    /// Independently compose the pre-repair renderer, including its leaf decision.
    private func legacyPresentationBytes(_ source: String) -> [[UInt8]] {
        let segments = MarkdownMathSegmenter.segments(in: source)
        if segments.containsMath {
            return [[1]] + segments.map { segment in
                switch segment {
                case .markdown(let text): return [0] + Array(text.utf8)
                case .displayMath(let text): return [1] + Array(text.utf8)
                }
            }
        }
        return [[0], Array(MarkdownMathFormatter.replacingInlineMath(in: source).utf8)]
    }

    private func presentationBytes(_ value: MarkdownMathPresentation) -> [[UInt8]] {
        if value.segments.containsMath {
            return [[1]] + value.segments.map { segment in
                switch segment {
                case .markdown(let text): return [0] + Array(text.utf8)
                case .displayMath(let text): return [1] + Array(text.utf8)
                }
            }
        }
        return [[0], Array(value.inlineMarkdown.utf8)]
    }

    private var presentationFixtures: [String] {
        [
            "", "plain markdown **bold**\n", "Price $5 and $10.00; $x^2$",
            #"Inline \(\alpha + x_2\) and $\beta$."#,
            #"Escaped \$x$ and \$$x$$ and \\[x\]"#,
            #"`$x$ $$y$$ \[z\]` outside $a_1$"#,
            "```swift\nlet rows = records.map { $0.id }\n```\n$x$",
            "~~~text\n$$x$$ \\[y\\]\n~~~\nend",
            "```swift\nlet value = $0\n$$unfinished",
            "before $$x^2$$ after $a$", #"before \[x^2\] after"#,
            "before $$unfinished $a$", #"before \[unfinished $a$"#,
            "before $$$$ after", "before $$ \n $$ after $a$",
            #"before \[\] after"#, "before \\[ \n \\] after",
            "$$$$", #"\[\]"#, "$$ $$ $$x$$ tail", #"\[\] \[x\] tail"#,
            "café cafe\u{301} 👩🏽‍💻 🇳🇱 \u{2067}שלום\u{2069} $x_2$",
            "e\u{301} $$x$$ 👨‍👩‍👧‍👦 \u{202E}abc\u{202C}",
            "$\u{301}$ and \\[\u{301}x\\]"
        ]
    }

    func testPresentationMatchesLegacyExactBytesAndLeafShape() {
        for source in presentationFixtures {
            let expected = legacyPresentationBytes(source)
            XCTAssertEqual(presentationBytes(MarkdownMathSegmenter.presentation(
                in: source, duplicateInlinePreprocessing: false)), expected, source.debugDescription)
            XCTAssertEqual(presentationBytes(MarkdownMathSegmenter.presentation(
                in: source, duplicateInlinePreprocessing: true)), expected, source.debugDescription)
            XCTAssertEqual(presentationBytes(MarkdownMathSegmenter.presentation(in: source)),
                           expected, source.debugDescription)
        }
    }

    func testPresentationAppendPrefixesMatchLegacyExactBytes() {
        for source in presentationFixtures {
            // Scalar boundaries include partially appended combining/emoji clusters.
            for end in source.unicodeScalars.indices {
                let prefix = String(source[..<end])
                let expected = legacyPresentationBytes(prefix)
                for duplicate in [false, true] {
                    XCTAssertEqual(presentationBytes(MarkdownMathSegmenter.presentation(
                        in: prefix, duplicateInlinePreprocessing: duplicate)), expected,
                        prefix.debugDescription)
                }
            }
        }
    }

    func testPresentationPreservesEmptyDisplayDelimitersInOriginalLeaf() {
        for source in ["before $$$$ after", #"before \[\] after"#,
                       "before $$ \n $$ after", "before \\[ \n \\] after"] {
            let result = MarkdownMathSegmenter.presentation(in: source, duplicateInlinePreprocessing: false)
            XCTAssertFalse(result.segments.containsMath)
            XCTAssertEqual(Array(result.inlineMarkdown.utf8),
                           Array(MarkdownMathFormatter.replacingInlineMath(in: source).utf8))
            // Ensure these fixtures actually exercise the incompatible segmented result.
            let segmented = MarkdownMathSegmenter.segments(in: source).compactMap { segment -> String? in
                if case .markdown(let value) = segment { return value }
                return nil
            }.joined()
            XCTAssertNotEqual(Array(segmented.utf8), Array(result.inlineMarkdown.utf8))
        }
    }
}

#if DEBUG
extension MarkdownMathRendererTests {
    func testPresentationCommonPathFormatsOnceVersusLegacyTwice() {
        for source in ["", "plain café 👩🏽‍💻", "$x_2$ and $5",
                       "```swift\nlet rows = records.filter { $0.id > 0 }\n```"] {
            for duplicate in [false, true] {
                var counts: [Int] = []
                let result = MarkdownMathSegmenter.presentation(
                    in: source, duplicateInlinePreprocessing: duplicate
                ) { input in
                    counts.append(input.utf8.count)
                    return MarkdownMathFormatter.replacingInlineMath(in: input)
                }
                XCTAssertEqual(counts, Array(repeating: source.utf8.count, count: duplicate ? 2 : 1))
                XCTAssertEqual(presentationBytes(result), legacyPresentationBytes(source))
            }
        }
    }
}
#endif

#if DEBUG
extension MarkdownMathRendererTests {
    @MainActor
    private func mountPlain(_ source: String, cache: MarkdownNativePlainCodeCache,
                            streaming: Bool = false, prepared: MarkdownPreparedCode? = nil,
                            scheme: ColorScheme = .light) -> (UITextView, MarkdownNativeCodeText.Coordinator) {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        let state = MarkdownNativeCodeText.Coordinator()
        MarkdownNativeCodeText(source: source, prepared: prepared, wraps: true,
                               colorScheme: scheme, isStreaming: streaming, plainCache: cache)
            .update(view, state: state)
        return (view, state)
    }

    @MainActor
    func testPlainNativeCacheRemountPreservesDisplayAndIndependentStorage() throws {
        let cache = MarkdownNativePlainCodeCache()
        let source = "café 👩🏽‍💻\r\n\nlet value = 1\u{2028}"
        let (first, a) = mountPlain(source, cache: cache)
        first.selectedRange = NSRange(location: 1, length: 3)
        let (second, b) = mountPlain(source, cache: cache)
        let (reference, uncached) = mountPlain(source, cache: MarkdownNativePlainCodeCache(enabled: false))
        let holder = try XCTUnwrap(a.plainDisplay)
        XCTAssertTrue(holder === b.plainDisplay)
        XCTAssertEqual(holder.constructionCount, 1)
        XCTAssertTrue(first.attributedText.isEqual(to: reference.attributedText))
        XCTAssertTrue(second.attributedText.isEqual(to: reference.attributedText))
        XCTAssertEqual(Array(a.source.utf8), Array(source.utf8))
        XCTAssertEqual(second.accessibilityValue, reference.accessibilityValue)
        XCTAssertEqual(second.textContainer.lineBreakMode, .byWordWrapping)
        XCTAssertFalse(first.textStorage === second.textStorage)
        XCTAssertFalse(first.textContainer === second.textContainer)
        XCTAssertEqual(second.selectedRange.length, 0)
        XCTAssertEqual(first.selectedRange, NSRange(location: 1, length: 3))
        XCTAssertNil(uncached.plainDisplay)
        for width: CGFloat in [180, 220, 340] {
            let expected = reference.sizeThatFits(CGSize(width: width, height: 1_000_000))
            let measured = MarkdownNativeCodeText.measuredSize(second, width: width, wraps: true,
                colorScheme: .light, measurements: b.measurements)
            XCTAssertEqual(measured, CGSize(width: width, height: max(1, ceil(expected.height))))
        }
        if !ProcessInfo.processInfo.arguments.contains("--chat-native-code-size-cache-disabled") {
            XCTAssertTrue(a.measurements === b.measurements)
        } else {
            XCTAssertFalse(a.measurements === b.measurements)
        }
    }

    @MainActor
    func testPlainNativeCacheStreamingTransitionsAndStalePreparedBypass() throws {
        let cache = MarkdownNativePlainCodeCache()
        let source = "let value = 1"
        let (view, state) = mountPlain(source, cache: cache, streaming: true)
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(state.plainDisplay)
        view.selectedRange = NSRange(location: 4, length: 5)
        func update(_ streaming: Bool, prepared: MarkdownPreparedCode? = nil) {
            MarkdownNativeCodeText(source: source, prepared: prepared, wraps: false,
                                   colorScheme: .light, isStreaming: streaming, plainCache: cache)
                .update(view, state: state)
            XCTAssertEqual(view.selectedRange, NSRange(location: 4, length: 5))
            XCTAssertEqual(view.textContainer.lineBreakMode, .byClipping)
        }
        update(false)
        let completed = try XCTUnwrap(state.plainDisplay)
        XCTAssertEqual(cache.count, 1)
        update(true)
        XCTAssertNil(state.plainDisplay)
        for prefix in ["l", "let", "let value"] {
            _ = mountPlain(prefix, cache: cache, streaming: true)
        }
        XCTAssertEqual(cache.count, 1)
        update(false)
        XCTAssertTrue(state.plainDisplay === completed)
        cache.removeAll()
        let stale = MarkdownPreparedCode(NSAttributedString(string: "old source"))
        update(false, prepared: stale)
        XCTAssertNil(state.plainDisplay)
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(stale.nativeDisplay.constructionCount, 0)
        XCTAssertEqual(view.attributedText.string, source)
        let prepared = MarkdownPreparedCode(NSAttributedString(string: source, attributes: [.foregroundColor: UIColor.red]))
        let authoritative = MarkdownNativeCodeText.displayText(source: source, prepared: prepared)
        update(false, prepared: prepared)
        let installedReference = UITextView()
        installedReference.attributedText = authoritative
        XCTAssertTrue(view.attributedText.isEqual(to: installedReference.attributedText))
        XCTAssertEqual(prepared.nativeDisplay.constructionCount, 1)
        XCTAssertEqual(cache.count, 0)
    }

    @MainActor
    func testPlainNativeCacheExactBytesSchemeAndAdmission() throws {
        let cache = MarkdownNativePlainCodeCache()
        let composed = "café"
        let decomposed = "cafe\u{301}"
        let (_, a) = mountPlain(composed, cache: cache)
        let (view, b) = mountPlain(decomposed, cache: cache)
        XCTAssertFalse(a.plainDisplay === b.plainDisplay)
        XCTAssertEqual(Array(view.attributedText.string.utf8), Array(decomposed.utf8))
        let (_, dark) = mountPlain(composed, cache: cache, scheme: .dark)
        XCTAssertFalse(a.plainDisplay === dark.plainDisplay)
        for source in ["", String(repeating: "x", count: 501), String(repeating: "x\n", count: 32_769)] {
            XCTAssertNil(cache.revision(source: source, colorScheme: .light, isStreaming: false, hasPrepared: false))
        }
        XCTAssertEqual(cache.count, 3)
        XCTAssertTrue(MarkdownNativePlainCodeCache.isEnabled(arguments: []))
        XCTAssertFalse(MarkdownNativePlainCodeCache.isEnabled(arguments: ["--chat-native-plain-code-cache-disabled"]))
        XCTAssertTrue(MarkdownNativePlainCodeCache.isEnabled(arguments: ["--chat-native-code-size-cache-disabled"]))
        let disabled = MarkdownNativePlainCodeCache(enabled: false)
        XCTAssertNil(mountPlain(composed, cache: disabled).1.plainDisplay)
        XCTAssertEqual(disabled.count, 0)
    }

    @MainActor
    func testPlainNativeCacheLRUCostAndMountedLifetime() throws {
        let charge = MarkdownNativePlainCodeCache.estimatedCost("a")
        let cache = MarkdownNativePlainCodeCache(maxEntries: 2, maxCost: charge * 2)
        var mounted: MarkdownNativeCodeText.Coordinator? = mountPlain("a", cache: cache).1
        weak var retained = mounted?.plainDisplay
        weak var victim: MarkdownNativeCodeDisplay?
        do { victim = mountPlain("b", cache: cache).1.plainDisplay }
        XCTAssertNotNil(victim)
        XCTAssertTrue(mountPlain("a", cache: cache).1.plainDisplay === retained)
        _ = mountPlain("c", cache: cache)
        XCTAssertNil(victim)
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.cost, charge * 2)
        XCTAssertNil(cache.revision(source: String(repeating: "z", count: 100),
                                    colorScheme: .light, isStreaming: false, hasPrepared: false))
        XCTAssertEqual(cache.count, 2, "Over-budget admission must not evict")
        cache.removeAll()
        XCTAssertEqual(cache.cost, 0)
        XCTAssertNotNil(retained, "Mounted coordinator retains evicted revision")
        XCTAssertEqual(retained?.constructionCount, 1)
        mounted = nil
        XCTAssertNil(retained)
        let costBound = MarkdownNativePlainCodeCache(maxEntries: 16, maxCost: charge)
        _ = mountPlain("a", cache: costBound)
        _ = mountPlain("b", cache: costBound)
        XCTAssertEqual(costBound.count, 1)
        XCTAssertEqual(costBound.cost, charge)
    }

    @MainActor
    func testPlainNativeCacheMeasurementsKeepFullLayoutIdentityAndTwoEntries() throws {
        let cache = MarkdownNativePlainCodeCache()
        let (_, state) = mountPlain("let value = 1", cache: cache)
        let sizes = state.measurements
        let normal = UITraitCollection(displayScale: 2)
        let changed = UITraitCollection(displayScale: 3)
        var calls = 0
        func measure(_ width: CGFloat = 220, _ wraps: Bool = true,
                     _ scheme: ColorScheme = .light, _ traits: UITraitCollection? = nil) {
            _ = sizes.value(width: width, wraps: wraps, colorScheme: scheme, traits: traits ?? normal) {
                calls += 1
                return CGSize(width: width, height: 20)
            }
        }
        measure(); measure()
        XCTAssertEqual(calls, 1)
        measure(221); measure(221, false); measure(221, false, .dark)
        measure(221, false, .dark, changed)
        XCTAssertEqual(calls, 5)
        XCTAssertEqual(sizes.count, 2)
        measure(221, false, .dark)
        XCTAssertEqual(calls, 5)
        measure()
        XCTAssertEqual(calls, 6)
    }
}
#endif
