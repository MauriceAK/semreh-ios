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
}

@MainActor
@Observable
private final class MountedMarkdownRendererModel {
    var content: String
    var isStreaming: Bool
    var colorScheme: ColorScheme = .light

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
