#if DEBUG
import CoreText
import OSLog
import SwiftUI
import UIKit
import cmark_gfm
import cmark_gfm_extensions

/// A deliberately narrow presentation experiment. The parser, typesetter and
/// highlighter produce value-only display data; neither CMark nor CoreText
/// objects cross the actor boundary. Unsupported input is returned explicitly.
struct NativeRichRowSnapshot: Sendable {
    struct Ink: Sendable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
        static let primary = Ink(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)
    }
    struct Run: Sendable {
        let text: String
        let pointSize: Double
        let bold: Bool
        let italic: Bool
        let monospaced: Bool
        let strike: Bool
        let ink: Ink
        let link: String?
    }
    struct Link: Sendable {
        let url: String
        let rect: CGRect
    }
    struct Line: Sendable {
        let text: String
        let runs: [Run]
        let frame: CGRect
        let baseline: Double
        let rightToLeft: Bool
        let links: [Link]
    }
    enum BlockKind: Sendable { case text, heading, code, table }
    struct Block: Sendable {
        let kind: BlockKind
        let frame: CGRect
        let lines: [Line]
        let code: String?
        let language: String?
        let tableRowY: [Double]
        let columnCount: Int
        let columnWidths: [Double]
    }
    let sourceBytes: [UInt8]
    let width: Double
    let height: Double
    let dark: Bool
    let wrapsCodeLines: Bool
    let blocks: [Block]
    let preparationMS: Double
}

enum NativeRichRowPreparation: Sendable {
    case ready(NativeRichRowSnapshot)
    case unsupported([String])
}

/// One signed-fixture handoff only: the actor finishes rich content before
/// ChatView mounts, and the existing viewport validates every presentation
/// dimension before accepting it. No application-wide message cache is implied.
@MainActor
enum NativePremountRichFixtureStore {
    struct Entry {
        let messageID: String
        let source: String
        let bodyWidth: Double
        let snapshot: NativeRichRowSnapshot

        func snapshot(dark: Bool, wrapsCodeLines: Bool) -> NativeRichRowSnapshot? {
            snapshot.dark == dark && snapshot.wrapsCodeLines == wrapsCodeLines ? snapshot : nil
        }
    }
    static var entry: Entry?
    static var target: Entry?
    static var path: [Int: Entry] = [:]
}

actor NativeRichRowPreparationActor {
    static let shared = NativeRichRowPreparationActor()

    private struct Node {
        let kind: String
        let literal: String
        let destination: String?
        let fenceInfo: String?
        let listStart: Int
        let children: [Node]
    }

    func prepare(source: String, width: Double, dark: Bool, wrapsCodeLines: Bool = false) async -> NativeRichRowPreparation {
        let started = CACurrentMediaTime()
        guard width > 40 else { return .unsupported(["invalid-width"]) }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return .unsupported(["parser"]) }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            guard let syntax = cmark_find_syntax_extension(name) else { return .unsupported(["extension-\(name)"]) }
            cmark_parser_attach_syntax_extension(parser, syntax)
        }
        cmark_parser_feed(parser, source, source.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return .unsupported(["document"]) }
        defer { cmark_node_free(document) }

        func copy(_ pointer: UnsafeMutablePointer<cmark_node>) -> Node {
            var children: [Node] = []
            var child = cmark_node_first_child(pointer)
            while let current = child {
                children.append(copy(current))
                child = cmark_node_next(current)
            }
            return Node(kind: String(cString: cmark_node_get_type_string(pointer)),
                        literal: cmark_node_get_literal(pointer).map(String.init(cString:)) ?? "",
                        destination: cmark_node_get_url(pointer).map(String.init(cString:)),
                        fenceInfo: cmark_node_get_fence_info(pointer).map(String.init(cString:)),
                        listStart: Int(cmark_node_get_list_start(pointer)), children: children)
        }
        var roots: [Node] = []
        var child = cmark_node_first_child(document)
        while let current = child {
            roots.append(copy(current))
            child = cmark_node_next(current)
        }
        let supported: Set<String> = ["heading", "paragraph", "text", "code", "softbreak", "linebreak", "strong", "emph", "strikethrough", "link", "list", "item", "code_block", "table", "table_header", "table_row", "table_cell"]
        func unsupported(_ node: Node) -> [String] {
            (supported.contains(node.kind) ? [] : [node.kind]) + node.children.flatMap(unsupported)
        }
        let unknown = Array(Set(roots.flatMap(unsupported))).sorted()
        guard unknown.isEmpty else { return .unsupported(unknown) }

        let primary = NativeRichRowSnapshot.Ink(red: dark ? 0.92 : 0.08, green: dark ? 0.93 : 0.09, blue: dark ? 0.96 : 0.11, alpha: 1)
        let secondary = NativeRichRowSnapshot.Ink(red: dark ? 0.73 : 0.29, green: dark ? 0.80 : 0.45, blue: dark ? 1.0 : 0.85, alpha: 1)
        var blocks: [NativeRichRowSnapshot.Block] = []
        var cursor = 0.0
        let usableWidth = width

        func inlineRuns(_ node: Node, bold: Bool = false, italic: Bool = false, mono: Bool = false, strike: Bool = false, link: String? = nil, size: Double = 16) -> [NativeRichRowSnapshot.Run] {
            switch node.kind {
            case "text", "code":
                return [.init(text: node.literal, pointSize: node.kind == "code" ? size * 0.88 : size,
                              bold: bold, italic: italic, monospaced: mono || node.kind == "code",
                              strike: strike, ink: link == nil ? primary : secondary, link: link)]
            case "softbreak", "linebreak":
                return [.init(text: "\n", pointSize: size, bold: bold, italic: italic,
                              monospaced: mono, strike: strike, ink: primary, link: link)]
            case "paragraph", "heading", "item", "list", "table_cell", "strong", "emph", "strikethrough", "link":
                return node.children.flatMap { inlineRuns($0, bold: bold || node.kind == "strong", italic: italic || node.kind == "emph",
                                                           mono: mono, strike: strike || node.kind == "strikethrough",
                                                           link: node.kind == "link" ? node.destination : link, size: size) }
            default: return []
            }
        }

        func font(_ run: NativeRichRowSnapshot.Run) -> UIFont {
            let plain = UIFont.systemFont(ofSize: run.pointSize, weight: run.bold ? .semibold : .regular)
            let rounded = plain.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: run.pointSize) } ?? plain
            let base = run.monospaced ? UIFont.monospacedSystemFont(ofSize: run.pointSize, weight: run.bold ? .semibold : .regular) : rounded
            guard run.italic, let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return base }
            return UIFont(descriptor: descriptor, size: run.pointSize)
        }

        func resolvedRightToLeft(_ runs: [NativeRichRowSnapshot.Run]) -> Bool {
            for scalar in runs.flatMap({ $0.text.unicodeScalars }) {
                switch scalar.value {
                case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
                case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x02AF: return false
                default: continue
                }
            }
            return false
        }

        func attributed(_ runs: [NativeRichRowSnapshot.Run], rightToLeft: Bool) -> NSAttributedString {
            let value = NSMutableAttributedString(string: "")
            let paragraph = NSMutableParagraphStyle()
            paragraph.baseWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
            for run in runs {
                let color = UIColor(red: run.ink.red, green: run.ink.green, blue: run.ink.blue, alpha: run.ink.alpha)
                var attributes: [NSAttributedString.Key: Any] = [.font: font(run), .foregroundColor: color, .paragraphStyle: paragraph]
                if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                value.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            return value.copy() as! NSAttributedString
        }

        func slice(_ runs: [NativeRichRowSnapshot.Run], range: NSRange) -> [NativeRichRowSnapshot.Run] {
            var result: [NativeRichRowSnapshot.Run] = []
            var start = 0
            for run in runs {
                let length = (run.text as NSString).length
                let overlap = NSIntersectionRange(NSRange(location: start, length: length), range)
                if overlap.length > 0 {
                    let text = (run.text as NSString).substring(with: NSRange(location: overlap.location - start, length: overlap.length))
                    result.append(.init(text: text, pointSize: run.pointSize, bold: run.bold, italic: run.italic,
                                        monospaced: run.monospaced, strike: run.strike, ink: run.ink, link: run.link))
                }
                start += length
            }
            return result
        }

        func layout(_ runs: [NativeRichRowSnapshot.Run], x: Double, y: Double, lineWidth: Double,
                    unwrapped: Bool = false) -> [NativeRichRowSnapshot.Line] {
            let rightToLeft = resolvedRightToLeft(runs)
            let value = attributed(runs, rightToLeft: rightToLeft)
            guard value.length > 0 else { return [] }
            let typesetter = CTTypesetterCreateWithAttributedString(value)
            var lines: [NativeRichRowSnapshot.Line] = []
            var offset = 0
            var top = y
            while offset < value.length {
                let suggested = CTTypesetterSuggestLineBreak(typesetter, offset, unwrapped ? 1_000_000 : max(1, lineWidth))
                let count = max(1, suggested)
                let ctLine = CTTypesetterCreateLine(typesetter, CFRangeMake(offset, count))
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let naturalWidth = CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
                let height = max(17, Double(ascent + descent + leading) + 2.8)
                let fragments = slice(runs, range: NSRange(location: offset, length: count))
                var links: [NativeRichRowSnapshot.Link] = []
                var local = 0
                for fragment in fragments {
                    let length = (fragment.text as NSString).length
                    if let url = fragment.link {
                        let x0 = CTLineGetOffsetForStringIndex(ctLine, offset + local, nil)
                        let x1 = CTLineGetOffsetForStringIndex(ctLine, offset + local + length, nil)
                        links.append(.init(url: url, rect: CGRect(x: x + min(x0, x1), y: top, width: abs(x1 - x0), height: height)))
                    }
                    local += length
                }
                lines.append(.init(text: (value.string as NSString).substring(with: NSRange(location: offset, length: count)),
                                   runs: fragments, frame: CGRect(x: x, y: top, width: unwrapped ? naturalWidth : max(lineWidth, naturalWidth), height: height),
                                   baseline: top + Double(ascent), rightToLeft: rightToLeft, links: links))
                top += height
                offset += count
            }
            return lines
        }

        func appendText(_ runs: [NativeRichRowSnapshot.Run], indent: Double = 0,
                        after: Double = 8, kind: NativeRichRowSnapshot.BlockKind = .text) {
            let top = cursor
            let lines = layout(runs, x: indent, y: cursor, lineWidth: usableWidth - indent)
            cursor = (lines.last.map { $0.frame.maxY } ?? cursor) + after
            blocks.append(.init(kind: kind, frame: CGRect(x: 0, y: top, width: width, height: cursor - top),
                                lines: lines, code: nil, language: nil, tableRowY: [], columnCount: 0, columnWidths: []))
        }

        for root in roots {
            switch root.kind {
            case "paragraph": appendText(inlineRuns(root))
            case "heading": appendText(inlineRuns(root, bold: true, size: 23), after: 20, kind: .heading)
            case "list":
                guard root.children.allSatisfy({ $0.kind == "item" && !$0.children.contains(where: { $0.kind == "list" }) }) else {
                    return .unsupported(["nested-list"])
                }
                let ordered = root.listStart > 0
                for (index, item) in root.children.enumerated() where item.kind == "item" {
                    let marker = ordered ? "\(root.listStart + index). " : "• "
                    let prefix = NativeRichRowSnapshot.Run(text: marker, pointSize: 16, bold: false, italic: false,
                                                           monospaced: false, strike: false, ink: primary, link: nil)
                    appendText([prefix] + inlineRuns(item), indent: 20, after: 3)
                }
                cursor += 8
            case "code_block":
                let language = root.fenceInfo?.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                guard MarkdownHighlightPolicy.normalizedLanguage(from: language) == "swift" else { return .unsupported(["code-language"]) }
                let highlighted = await MarkdownCodeHighlightWorker.shared.rawHighlightedCode(for: .init(code: root.literal, language: language, colorScheme: dark ? .dark : .light, isStreaming: false))
                guard case .highlighted(let source) = highlighted else { return .unsupported(["code-highlight"]) }
                var codeRuns: [NativeRichRowSnapshot.Run] = []
                source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
                    let text = (source.string as NSString).substring(with: range)
                    let uiColor = (attributes[.foregroundColor] as? UIColor)?.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)) ?? UIColor(red: primary.red, green: primary.green, blue: primary.blue, alpha: 1)
                    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                    uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                    codeRuns.append(.init(text: text, pointSize: 13, bold: false, italic: false, monospaced: true,
                                          strike: false, ink: .init(red: red, green: green, blue: blue, alpha: alpha), link: nil))
                }
                let top = cursor
                let lines = layout(codeRuns, x: 16, y: cursor + 54, lineWidth: usableWidth - 32,
                                   unwrapped: !wrapsCodeLines)
                cursor = max(cursor + 78, (lines.last.map { $0.frame.maxY } ?? cursor + 54) + 16) + 10
                blocks.append(.init(kind: .code, frame: CGRect(x: 0, y: top, width: width, height: cursor - top - 10),
                                    lines: lines, code: root.literal, language: language, tableRowY: [], columnCount: 0, columnWidths: []))
            case "table":
                let rows = root.children.flatMap { $0.kind == "table_row" || $0.kind == "table_header" ? [$0] : $0.children.filter { $0.kind == "table_row" || $0.kind == "table_header" } }
                guard let columns = rows.first?.children.count, columns > 0, rows.allSatisfy({ $0.children.count == columns }) else { return .unsupported(["table-shape"]) }
                let top = cursor
                let columnWidths: [Double] = (0..<columns).map { column in
                    let widest = rows.map { row -> Double in
                        let value = attributed(inlineRuns(row.children[column], bold: row.kind == "table_header"), rightToLeft: false)
                        guard value.length > 0 else { return 0 }
                        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(value), nil, nil, nil)
                    }.max() ?? 0
                    // MarkdownUI caps the content before the cell's 13pt side padding.
                    return min(260, max(96, widest)) + 26
                }
                let tableWidth = columnWidths.reduce(0, +)
                var tableLines: [NativeRichRowSnapshot.Line] = []
                var rowY: [Double] = [cursor]
                for row in rows {
                    let rowTop = cursor
                    var rowBottom = rowTop
                    for (column, cell) in row.children.enumerated() {
                        let lines = layout(inlineRuns(cell, bold: row.kind == "table_header"),
                                           x: columnWidths.prefix(column).reduce(0, +) + 13,
                                           y: rowTop + 6, lineWidth: columnWidths[column] - 26)
                        rowBottom = max(rowBottom, lines.last?.frame.maxY ?? rowTop + 20)
                        tableLines += lines
                    }
                    cursor = rowBottom + 6
                    rowY.append(cursor)
                }
                blocks.append(.init(kind: .table, frame: CGRect(x: 0, y: top, width: tableWidth, height: cursor - top),
                                    lines: tableLines, code: nil, language: nil, tableRowY: rowY, columnCount: columns, columnWidths: columnWidths))
                cursor += 16
            default: return .unsupported([root.kind])
            }
        }
        return .ready(.init(sourceBytes: Array(source.utf8), width: width, height: max(1, cursor), dark: dark,
                            wrapsCodeLines: wrapsCodeLines, blocks: blocks,
                            preparationMS: (CACurrentMediaTime() - started) * 1_000))
    }
}

/// First-visible-row proof only. This deliberately does not invoke the
/// highlighter or table renderer on the main thread. Unsupported syntax is a
/// separate, readable preformatted source block; the original response bytes
/// remain the authority for Select Text and Copy.
enum NativeBasicFirstRowPreparation {
    private struct Node {
        let kind: String
        let literal: String
        let destination: String?
        let fenceInfo: String?
        let listStart: Int
        let firstLine: Int
        let lastLine: Int
        let children: [Node]
    }

    static func prepare(source: String, width: Double, dark: Bool,
                        wrapsCodeLines: Bool, asLiteral: Bool = false) -> NativeRichRowPreparation {
        let started = CACurrentMediaTime()
        guard width > 80, source.utf8.count < 10_000 else { return .unsupported(["basic-row-bound"]) }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return .unsupported(["basic-parser"]) }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            guard let syntax = cmark_find_syntax_extension(name) else { return .unsupported(["basic-extension-\(name)"]) }
            cmark_parser_attach_syntax_extension(parser, syntax)
        }
        cmark_parser_feed(parser, source, source.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return .unsupported(["basic-document"]) }
        defer { cmark_node_free(document) }

        func copy(_ pointer: UnsafeMutablePointer<cmark_node>) -> Node {
            var children: [Node] = []
            var child = cmark_node_first_child(pointer)
            while let current = child {
                children.append(copy(current))
                child = cmark_node_next(current)
            }
            return Node(kind: String(cString: cmark_node_get_type_string(pointer)),
                        literal: cmark_node_get_literal(pointer).map(String.init(cString:)) ?? "",
                        destination: cmark_node_get_url(pointer).map(String.init(cString:)),
                        fenceInfo: cmark_node_get_fence_info(pointer).map(String.init(cString:)),
                        listStart: Int(cmark_node_get_list_start(pointer)),
                        firstLine: Int(cmark_node_get_start_line(pointer)),
                        lastLine: Int(cmark_node_get_end_line(pointer)), children: children)
        }
        var roots: [Node] = []
        var child = cmark_node_first_child(document)
        while let current = child {
            roots.append(copy(current))
            child = cmark_node_next(current)
        }

        let primary = NativeRichRowSnapshot.Ink(red: dark ? 0.92 : 0.08,
                                                green: dark ? 0.93 : 0.09,
                                                blue: dark ? 0.96 : 0.11, alpha: 1)
        let linkInk = NativeRichRowSnapshot.Ink(red: dark ? 0.73 : 0.29,
                                                green: dark ? 0.80 : 0.45,
                                                blue: dark ? 1.00 : 0.85, alpha: 1)
        let sourceLines = source.components(separatedBy: "\n")
        var blocks: [NativeRichRowSnapshot.Block] = []
        var cursor = 0.0

        func original(_ node: Node) -> String {
            let first = max(0, node.firstLine - 1)
            let end = min(sourceLines.count, max(first + 1, node.lastLine))
            return first < end ? sourceLines[first..<end].joined(separator: "\n") : node.literal
        }
        func run(_ text: String, size: Double = 16, bold: Bool = false,
                 italic: Bool = false, mono: Bool = false, link: String? = nil) -> NativeRichRowSnapshot.Run {
            .init(text: text, pointSize: size, bold: bold, italic: italic,
                  monospaced: mono, strike: false, ink: link == nil ? primary : linkInk, link: link)
        }
        func inline(_ node: Node, bold: Bool = false, italic: Bool = false,
                    link: String? = nil, size: Double = 16) -> [NativeRichRowSnapshot.Run]? {
            switch node.kind {
            case "text": return [run(node.literal, size: size, bold: bold, italic: italic, link: link)]
            case "code": return [run(node.literal, size: size * 0.88, bold: bold, mono: true, link: link)]
            case "softbreak", "linebreak": return [run("\n", size: size, bold: bold, italic: italic)]
            case "paragraph", "item", "table_cell", "strong", "emph", "link":
                var result: [NativeRichRowSnapshot.Run] = []
                for child in node.children {
                    guard let fragments = inline(child, bold: bold || node.kind == "strong",
                                                 italic: italic || node.kind == "emph",
                                                 link: node.kind == "link" ? node.destination : link,
                                                 size: size) else { return nil }
                    result += fragments
                }
                return result
            default: return nil
            }
        }
        func font(_ run: NativeRichRowSnapshot.Run) -> UIFont {
            if run.monospaced {
                return .monospacedSystemFont(ofSize: run.pointSize,
                                             weight: run.bold ? .semibold : .regular)
            }
            let base = UIFont.systemFont(ofSize: run.pointSize, weight: run.bold ? .semibold : .regular)
            let rounded = base.fontDescriptor.withDesign(.rounded).map {
                UIFont(descriptor: $0, size: run.pointSize)
            } ?? base
            guard run.italic,
                  let descriptor = rounded.fontDescriptor.withSymbolicTraits(
                    rounded.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return rounded }
            return UIFont(descriptor: descriptor, size: run.pointSize)
        }
        func layout(_ runs: [NativeRichRowSnapshot.Run], x: Double, y: Double,
                    lineWidth: Double, unwrapped: Bool = false) -> [NativeRichRowSnapshot.Line] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.baseWritingDirection = .natural
            let value = NSMutableAttributedString(string: "")
            for fragment in runs {
                let ink = fragment.ink
                value.append(NSAttributedString(string: fragment.text, attributes: [
                    .font: font(fragment),
                    .foregroundColor: UIColor(red: ink.red, green: ink.green,
                                              blue: ink.blue, alpha: ink.alpha),
                    .paragraphStyle: paragraph
                ]))
            }
            guard value.length > 0 else { return [] }
            let typesetter = CTTypesetterCreateWithAttributedString(value)
            var result: [NativeRichRowSnapshot.Line] = []
            var offset = 0
            var top = y
            while offset < value.length {
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, offset,
                    unwrapped ? 1_000_000 : max(1, lineWidth)))
                let ctLine = CTTypesetterCreateLine(typesetter, CFRangeMake(offset, count))
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let naturalWidth = CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
                let height = max(17, Double(ascent + descent + leading) + 2.8)
                var fragments: [NativeRichRowSnapshot.Run] = []
                var links: [NativeRichRowSnapshot.Link] = []
                var start = 0
                for fragment in runs {
                    let length = (fragment.text as NSString).length
                    let overlap = NSIntersectionRange(NSRange(location: start, length: length),
                                                      NSRange(location: offset, length: count))
                    if overlap.length > 0 {
                        let text = (fragment.text as NSString).substring(with: NSRange(
                            location: overlap.location - start, length: overlap.length))
                        fragments.append(run(text, size: fragment.pointSize,
                                             bold: fragment.bold, italic: fragment.italic,
                                             mono: fragment.monospaced, link: fragment.link))
                        if let url = fragment.link {
                            let x0 = CTLineGetOffsetForStringIndex(ctLine, overlap.location, nil)
                            let x1 = CTLineGetOffsetForStringIndex(ctLine, overlap.location + overlap.length, nil)
                            links.append(.init(url: url, rect: CGRect(x: x + min(x0, x1),
                                y: top, width: abs(x1 - x0), height: height)))
                        }
                    }
                    start += length
                }
                result.append(.init(text: (value.string as NSString).substring(with: NSRange(
                    location: offset, length: count)), runs: fragments,
                    frame: CGRect(x: x, y: top,
                                  width: unwrapped ? naturalWidth : max(lineWidth, naturalWidth),
                                  height: height), baseline: top + Double(ascent),
                    rightToLeft: false, links: links))
                top += height
                offset += count
            }
            return result
        }
        func appendText(_ fragments: [NativeRichRowSnapshot.Run], indent: Double = 0,
                        after: Double = 8,
                        kind: NativeRichRowSnapshot.BlockKind = .text) {
            let top = cursor
            let lines = layout(fragments, x: indent, y: cursor, lineWidth: width - indent)
            cursor = Double(lines.last?.frame.maxY ?? CGFloat(cursor)) + after
            blocks.append(.init(kind: kind, frame: CGRect(x: 0, y: top, width: width,
                height: cursor - top), lines: lines, code: nil, language: nil,
                tableRowY: [], columnCount: 0, columnWidths: []))
        }
        func appendCode(_ code: String, language: String?) {
            let top = cursor
            let lines = layout([run(code, size: 13, mono: true)], x: 16,
                               y: cursor + 54, lineWidth: width - 32,
                               unwrapped: !wrapsCodeLines)
            cursor = max(cursor + 78,
                         Double(lines.last?.frame.maxY ?? CGFloat(cursor + 54)) + 16) + 10
            blocks.append(.init(kind: .code, frame: CGRect(x: 0, y: top, width: width,
                height: cursor - top - 10), lines: lines, code: code,
                language: language, tableRowY: [], columnCount: 0, columnWidths: []))
        }
        func appendTable(_ table: Node) -> Bool {
            let rows = table.children.flatMap { child -> [Node] in
                child.kind == "table_row" || child.kind == "table_header"
                    ? [child]
                    : child.children.filter { $0.kind == "table_row" || $0.kind == "table_header" }
            }
            guard let columns = rows.first?.children.count, columns > 0,
                  rows.allSatisfy({ $0.children.count == columns }) else { return false }
            var contents: [[[NativeRichRowSnapshot.Run]]] = []
            for row in rows {
                var cells: [[NativeRichRowSnapshot.Run]] = []
                for cell in row.children {
                    guard let fragments = inline(cell, bold: row.kind == "table_header") else { return false }
                    cells.append(fragments)
                }
                contents.append(cells)
            }
            let widths: [Double] = (0..<columns).map { column in
                let widest = contents.map { row -> Double in
                    let value = NSMutableAttributedString(string: "")
                    for fragment in row[column] {
                        value.append(NSAttributedString(string: fragment.text,
                            attributes: [.font: font(fragment)]))
                    }
                    guard value.length > 0 else { return 0 }
                    return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(value),
                                                     nil, nil, nil)
                }.max() ?? 0
                return min(260, max(96, widest)) + 26
            }
            let tableWidth = widths.reduce(0, +)
            // This first-row proof has no native horizontal table scroller.
            // Keep wider tables as an explicit source block, never clip cells.
            guard tableWidth <= width else { return false }
            let top = cursor
            var tableLines: [NativeRichRowSnapshot.Line] = []
            var rowY: [Double] = [cursor]
            for row in contents {
                let rowTop = cursor
                var rowBottom = rowTop
                for (column, cell) in row.enumerated() {
                    let lines = layout(cell, x: widths.prefix(column).reduce(0, +) + 13,
                                       y: rowTop + 6, lineWidth: widths[column] - 26)
                    rowBottom = max(rowBottom, lines.last?.frame.maxY ?? rowTop + 20)
                    tableLines += lines
                }
                cursor = rowBottom + 6
                rowY.append(cursor)
            }
            blocks.append(.init(kind: .table,
                frame: CGRect(x: 0, y: top, width: tableWidth, height: cursor - top),
                lines: tableLines, code: nil, language: nil,
                tableRowY: rowY, columnCount: columns, columnWidths: widths))
            cursor += 16
            return true
        }

        if asLiteral {
            appendCode(source, language: "Details")
            return .ready(.init(sourceBytes: Array(source.utf8), width: width,
                                height: max(1, cursor), dark: dark,
                                wrapsCodeLines: wrapsCodeLines, blocks: blocks,
                                preparationMS: (CACurrentMediaTime() - started) * 1_000))
        }
        for node in roots {
            switch node.kind {
            case "paragraph":
                if let fragments = inline(node) { appendText(fragments) }
                else { appendCode(original(node), language: "Source") }
            case "heading":
                var fragments: [NativeRichRowSnapshot.Run] = []
                var supported = true
                for child in node.children {
                    guard let next = inline(child, bold: true, size: 23) else {
                        supported = false
                        break
                    }
                    fragments += next
                }
                if supported { appendText(fragments, after: 20, kind: .heading) }
                else { appendCode(original(node), language: "Source") }
            case "list":
                if node.children.allSatisfy({ $0.kind == "item" && !$0.children.contains(where: { $0.kind == "list" }) }) {
                    for (index, item) in node.children.enumerated() {
                        guard let content = inline(item) else { appendCode(original(item), language: "Source"); continue }
                        let marker = node.listStart > 0 ? "\(node.listStart + index). " : "• "
                        appendText([run(marker)] + content, indent: 20, after: 3)
                    }
                    cursor += 8
                } else { appendCode(original(node), language: "Source") }
            case "code_block":
                let language = node.fenceInfo?.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                appendCode(node.literal, language: language ?? "Code")
            case "table":
                if !appendTable(node) { appendCode(original(node), language: "Source") }
            default:
                appendCode(original(node), language: "Source")
            }
        }
        return .ready(.init(sourceBytes: Array(source.utf8), width: width,
                            height: max(1, cursor), dark: dark,
                            wrapsCodeLines: wrapsCodeLines, blocks: blocks,
                            preparationMS: (CACurrentMediaTime() - started) * 1_000))
    }
}

@MainActor
final class NativeRichRowCanvas: UIView, UIScrollViewDelegate {
    private final class LinkElement: UIAccessibilityElement {
        var activate: (() -> Void)?
        override func accessibilityActivate() -> Bool {
            activate?()
            return activate != nil
        }
    }
    var snapshot: NativeRichRowSnapshot? { didSet { codeHorizontalOffset = 0; rebuildControls(); setNeedsDisplay() } }
    var onOpenLink: ((URL) -> Void)?
    var onToggleCodeWrap: (() -> Void)?
    private var copyButtons: [UIButton] = []
    private var wrapButtons: [UIButton] = []
    private var lineElements: [UIAccessibilityElement] = []
    private var codeHorizontalOffset: CGFloat = 0
    private let codeScroller = UIScrollView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        contentMode = .redraw
        accessibilityIdentifier = "native-rich-row"
        codeScroller.delegate = self
        codeScroller.backgroundColor = .clear
        codeScroller.isOpaque = false
        codeScroller.showsHorizontalScrollIndicator = false
        codeScroller.showsVerticalScrollIndicator = false
        codeScroller.alwaysBounceHorizontal = true
        codeScroller.alwaysBounceVertical = false
        codeScroller.isDirectionalLockEnabled = true
        codeScroller.accessibilityElementsHidden = true
        addSubview(codeScroller)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func rebuildControls() {
        copyButtons.forEach { $0.removeFromSuperview() }
        wrapButtons.forEach { $0.removeFromSuperview() }
        copyButtons = []
        wrapButtons = []
        lineElements = []
        guard let snapshot else { return }
        if let code = snapshot.blocks.first(where: { $0.kind == .code }), !snapshot.wrapsCodeLines {
            codeScroller.isHidden = false
            codeScroller.frame = CGRect(x: code.frame.minX + 16, y: code.frame.minY + 50,
                                        width: code.frame.width - 32,
                                        height: code.frame.height - 60)
            codeScroller.contentSize = CGSize(width: codeScroller.frame.width + maximumCodeOffset(for: code),
                                              height: codeScroller.frame.height)
            codeScroller.contentOffset = .zero
        } else {
            codeScroller.isHidden = true
            codeScroller.contentOffset = .zero
        }
        var orderedAccessibilityElements: [Any] = []
        for block in snapshot.blocks {
            if block.kind == .code {
                let wrap = UIButton(type: .system)
                wrap.setImage(UIImage(systemName: snapshot.wrapsCodeLines ? "arrow.turn.down.left" : "arrow.left.and.right"), for: .normal)
                wrap.accessibilityLabel = snapshot.wrapsCodeLines ? "Disable code line wrapping" : "Enable code line wrapping"
                wrap.accessibilityValue = snapshot.wrapsCodeLines ? "Wrapped" :
                    "Horizontal offset 0 of \(Int(maximumCodeOffset(for: block))) points"
                wrap.frame = CGRect(x: block.frame.maxX - 94, y: block.frame.minY + 10, width: 36, height: 36)
                wrap.addAction(UIAction { [weak self] _ in self?.onToggleCodeWrap?() }, for: .touchUpInside)
                addSubview(wrap)
                wrapButtons.append(wrap)
                orderedAccessibilityElements.append(wrap)
                let button = UIButton(type: .system)
                button.setImage(UIImage(systemName: "square.on.square"), for: .normal)
                button.accessibilityLabel = "Copy code"
                button.frame = CGRect(x: block.frame.maxX - 50, y: block.frame.minY + 10, width: 40, height: 36)
                button.addAction(UIAction { [weak button] _ in
                    UIPasteboard.general.string = block.code
                    button?.accessibilityLabel = "Copied code"
                }, for: .touchUpInside)
                addSubview(button)
                copyButtons.append(button)
                orderedAccessibilityElements.append(button)
            }
            for line in block.lines {
                let wholeLineLink = line.links.count == 1
                    && line.runs.allSatisfy { $0.link == line.links[0].url }
                if !wholeLineLink {
                    let element = UIAccessibilityElement(accessibilityContainer: self)
                    element.accessibilityLabel = line.text
                    element.accessibilityTraits = .staticText
                    element.accessibilityFrameInContainerSpace = line.frame
                    lineElements.append(element)
                    orderedAccessibilityElements.append(element)
                }
                for link in line.links {
                    guard let url = URL(string: link.url),
                          let scheme = url.scheme?.lowercased(),
                          ["http", "https", "mailto"].contains(scheme) else { continue }
                    let element = LinkElement(accessibilityContainer: self)
                    element.accessibilityLabel = line.runs.filter { $0.link == link.url }
                        .map(\.text).joined()
                    element.accessibilityTraits = .link
                    element.accessibilityFrameInContainerSpace = link.rect
                    element.activate = { [weak self] in self?.onOpenLink?(url) }
                    if wholeLineLink { lineElements.append(element) }
                    orderedAccessibilityElements.append(element)
                }
            }
        }
        accessibilityElements = orderedAccessibilityElements
    }

    private func maximumCodeOffset(for block: NativeRichRowSnapshot.Block) -> CGFloat {
        max(0, (block.lines.map(\.frame.maxX).max() ?? block.frame.maxX) - block.frame.maxX + 16)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === codeScroller, let block = snapshot?.blocks.first(where: { $0.kind == .code }) else { return }
        codeHorizontalOffset = min(maximumCodeOffset(for: block), max(0, scrollView.contentOffset.x))
        wrapButtons.first?.accessibilityValue =
            "Horizontal offset \(Int(codeHorizontalOffset)) of \(Int(maximumCodeOffset(for: block))) points"
        setNeedsDisplay(block.frame)
        var index = 0
        for item in snapshot?.blocks ?? [] {
            for line in item.lines {
                var frame = line.frame
                if item.kind == .code { frame.origin.x -= codeHorizontalOffset }
                if lineElements.indices.contains(index) { lineElements[index].accessibilityFrameInContainerSpace = frame }
                index += 1
            }
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === codeScroller, let block = snapshot?.blocks.first(where: { $0.kind == .code }) else { return }
        Logger(subsystem: "com.maurice.semreh", category: "NativeRichRow").debug(
            "event=native_code_horizontal_end offset=\(self.codeHorizontalOffset, privacy: .public) max=\(self.maximumCodeOffset(for: block), privacy: .public)"
        )
    }

    override func draw(_ rect: CGRect) {
        guard let snapshot, let context = UIGraphicsGetCurrentContext() else { return }
        for block in snapshot.blocks where block.frame.intersects(rect) {
            if block.kind == .code {
                let fill = snapshot.dark
                    ? UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
                    : UIColor.secondarySystemBackground
                fill.setFill()
                UIBezierPath(roundedRect: block.frame, cornerRadius: 24).fill()
                UIColor.separator.withAlphaComponent(0.35).setStroke()
                let border = UIBezierPath(roundedRect: block.frame.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 24)
                border.lineWidth = 1
                border.stroke()
                let header = (block.language ?? "Code").capitalized
                (header as NSString).draw(at: CGPoint(x: block.frame.minX + 16, y: block.frame.minY + 15), withAttributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: UIColor.label])
            } else if block.kind == .heading, let last = block.lines.last {
                UIColor.separator.withAlphaComponent(0.45).setStroke()
                let rule = UIBezierPath()
                rule.move(to: CGPoint(x: 0, y: last.frame.maxY + 8))
                rule.addLine(to: CGPoint(x: block.frame.width, y: last.frame.maxY + 8))
                rule.lineWidth = 0.5
                rule.stroke()
            } else if block.kind == .table {
                for row in 0..<max(0, block.tableRowY.count - 1) {
                    let color: UIColor = snapshot.dark
                        ? (row.isMultiple(of: 2) ? UIColor(red: 0.094, green: 0.098, blue: 0.114, alpha: 1)
                                                   : UIColor(red: 0.145, green: 0.149, blue: 0.165, alpha: 1))
                        : (row.isMultiple(of: 2) ? .white : UIColor(red: 0.969, green: 0.969, blue: 0.976, alpha: 1))
                    color.setFill()
                    UIBezierPath(rect: CGRect(x: block.frame.minX, y: block.tableRowY[row],
                                              width: block.frame.width, height: block.tableRowY[row + 1] - block.tableRowY[row])).fill()
                }
                (snapshot.dark ? UIColor(red: 0.259, green: 0.267, blue: 0.306, alpha: 1)
                               : UIColor(red: 0.894, green: 0.894, blue: 0.91, alpha: 1)).setStroke()
                let path = UIBezierPath(rect: block.frame)
                for y in block.tableRowY.dropFirst().dropLast() {
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: block.frame.maxX, y: y))
                }
                for column in 1..<block.columnCount {
                    let x = block.columnWidths.prefix(column).reduce(0, +)
                    path.move(to: CGPoint(x: x, y: block.frame.minY)); path.addLine(to: CGPoint(x: x, y: block.frame.maxY))
                }
                path.lineWidth = 0.5
                path.stroke()
            }
            for line in block.lines where line.frame.intersects(rect) {
                let value = NSMutableAttributedString(string: "")
                let paragraph = NSMutableParagraphStyle()
                paragraph.baseWritingDirection = line.rightToLeft ? .rightToLeft : .leftToRight
                for run in line.runs {
                    let plain = UIFont.systemFont(ofSize: run.pointSize, weight: run.bold ? .semibold : .regular)
                    let rounded = plain.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: run.pointSize) } ?? plain
                    let base = run.monospaced ? UIFont.monospacedSystemFont(ofSize: run.pointSize, weight: run.bold ? .semibold : .regular) : rounded
                    let font = run.italic && base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic)) != nil
                        ? UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic))!, size: run.pointSize) : base
                    let color = UIColor(red: run.ink.red, green: run.ink.green, blue: run.ink.blue, alpha: run.ink.alpha)
                    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
                    if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    value.append(NSAttributedString(string: run.text, attributes: attributes))
                }
                let ctLine = CTLineCreateWithAttributedString(value)
                if block.kind == .text {
                    var offset = 0
                    for run in line.runs {
                        let length = (run.text as NSString).length
                        if run.monospaced {
                            let x0 = CTLineGetOffsetForStringIndex(ctLine, offset, nil)
                            let x1 = CTLineGetOffsetForStringIndex(ctLine, offset + length, nil)
                            let color = snapshot.dark
                                ? UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1)
                                : UIColor.tertiarySystemGroupedBackground
                            color.setFill()
                            UIBezierPath(roundedRect: CGRect(x: line.frame.minX + min(x0, x1), y: line.frame.minY,
                                                             width: abs(x1 - x0), height: line.frame.height - 2), cornerRadius: 3).fill()
                        }
                        offset += length
                    }
                }
                context.saveGState()
                if block.kind == .code {
                    context.clip(to: CGRect(x: block.frame.minX + 16, y: block.frame.minY + 50,
                                            width: block.frame.width - 32,
                                            height: block.frame.height - 60))
                }
                context.textMatrix = .identity
                context.translateBy(x: line.frame.minX - (block.kind == .code ? codeHorizontalOffset : 0), y: line.baseline)
                context.scaleBy(x: 1, y: -1)
                CTLineDraw(ctLine, context)
                context.restoreGState()
            }
        }
    }

    @discardableResult
    func activateLink(at point: CGPoint) -> Bool {
        guard let url = snapshot?.blocks.lazy.flatMap(\.lines).lazy.flatMap(\.links)
            .first(where: { $0.rect.contains(point) }).flatMap({ URL(string: $0.url) }),
              let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme)
        else { return false }
        onOpenLink?(url)
        return true
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let point = touches.first?.location(in: self), activateLink(at: point) { return }
        super.touchesEnded(touches, with: event)
    }
}

struct NativeRichRowMountedView: UIViewRepresentable {
    let snapshot: NativeRichRowSnapshot
    let onToggleCodeWrap: () -> Void
    @Environment(\.openURL) private var openURL
    func makeUIView(context: Context) -> NativeRichRowCanvas { NativeRichRowCanvas(frame: .zero) }
    func updateUIView(_ uiView: NativeRichRowCanvas, context: Context) {
        if uiView.snapshot?.sourceBytes != snapshot.sourceBytes || uiView.snapshot?.width != snapshot.width
            || uiView.snapshot?.dark != snapshot.dark || uiView.snapshot?.wrapsCodeLines != snapshot.wrapsCodeLines {
            uiView.snapshot = snapshot
        }
        uiView.onOpenLink = { url in openURL(url) }
        uiView.onToggleCodeWrap = onToggleCodeWrap
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NativeRichRowCanvas, context: Context) -> CGSize? {
        CGSize(width: snapshot.width, height: snapshot.height)
    }
}

/// The two-row viewport proof owns whole-row geometry. It deliberately keeps
/// the existing CoreText body snapshot. A prepared Thinking detail can be
/// composed above the same body without relaying out that body on a tap.
struct NativeDirectPreparedRow {
    struct LinkPreview {
        let url: URL
        let frame: CGRect
    }
    struct ToolAction {
        let id: String
        let title: String
        let symbol: String
        let accessibilityStatus: String
        let headerFrame: CGRect
        let isExpanded: Bool
        let detail: NativeRichRowSnapshot?
        let detailFrame: CGRect?
    }
    enum Content {
        case outgoing(text: String, textFrame: CGRect, bubbleFrame: CGRect,
                      fillHex: String, foregroundHex: String, borderHex: String)
        case pendingAssistant(status: String)
        case assistant(body: NativeRichRowSnapshot, canvasFrame: CGRect,
                       bubbleFrame: CGRect, thinkingTitle: String?,
                       thinkingDetail: NativeRichRowSnapshot?, thinkingDetailFrame: CGRect?,
                       toolActions: [ToolAction], linkPreview: LinkPreview?, copyFrame: CGRect?)
    }
    let height: CGFloat
    let rowIdentifier: String
    let rowLabel: String
    let content: Content
}

@MainActor
final class NativeDirectTranscriptRowView: UIView, UIContextMenuInteractionDelegate {
    weak var hostingParent: UIViewController?
    var onSelectText: (() -> Void)?
    var onCopyResponse: (() -> Void)?
    var onToggleCodeWrap: (() -> Void)?
    var onOpenLink: ((URL) -> Void)?
    var onUnsupportedDisclosure: ((String) -> Void)?
    var onToggleTool: ((String) -> Void)?
    private var installed: NativeDirectPreparedRow?
    private var previewHost: UIHostingController<AnyView>?
    private var previewURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        accessibilityIdentifier = "native-direct-transcript-row"
        addInteraction(UIContextMenuInteraction(delegate: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil {
            previewHost?.willMove(toParent: nil)
            previewHost?.removeFromParent()
            previewHost = nil
            previewURL = nil
        }
    }

    private static func color(_ hex: String) -> UIColor {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = UInt64(digits, radix: 16), digits.count == 6 else { return .label }
        return UIColor(red: CGFloat((value >> 16) & 0xff) / 255,
                       green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    func install(_ row: NativeDirectPreparedRow) {
        installed = row
        subviews.forEach { $0.removeFromSuperview() }
        let summary = UIAccessibilityElement(accessibilityContainer: self)
        summary.accessibilityIdentifier = row.rowIdentifier
        summary.accessibilityLabel = row.rowLabel
        summary.accessibilityTraits = .staticText
        var ordered: [Any] = []
        switch row.content {
        case let .pendingAssistant(status):
            let label = UILabel(frame: CGRect(x: 12, y: 4, width: bounds.width - 24, height: 36))
            label.text = status
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabel
            label.isAccessibilityElement = true
            label.accessibilityTraits = .staticText
            addSubview(label)
            ordered.append(label)
        case let .outgoing(text, textFrame, bubbleFrame, fillHex, foregroundHex, borderHex):
            let bubble = UIView(frame: bubbleFrame)
            bubble.backgroundColor = Self.color(fillHex)
            bubble.layer.cornerRadius = 20
            bubble.layer.borderWidth = 0.5
            bubble.layer.borderColor = Self.color(borderHex).withAlphaComponent(0.82).cgColor
            addSubview(bubble)
            let selection = UITextView(frame: textFrame)
            selection.text = text
            selection.font = .preferredFont(forTextStyle: .body)
            selection.textColor = Self.color(foregroundHex)
            selection.backgroundColor = .clear
            selection.textContainerInset = .zero
            selection.textContainer.lineFragmentPadding = 0
            selection.isScrollEnabled = false
            selection.isEditable = false
            selection.isSelectable = true
            addSubview(selection)
            summary.accessibilityFrameInContainerSpace = bubbleFrame
            ordered.append(summary)
            ordered.append(selection)
        case let .assistant(body, canvasFrame, bubbleFrame, thinkingTitle,
                            thinkingDetail, thinkingDetailFrame, toolActions, linkPreview, copyFrame):
            var headerY: CGFloat = 0
            if let thinkingTitle {
                let button = disclosureButton(title: thinkingTitle, symbol: "ellipsis.bubble", y: headerY,
                                              expanded: thinkingDetail != nil)
                addSubview(button)
                ordered.append(button)
                headerY += 48
                if let thinkingDetail, let thinkingDetailFrame {
                    let detail = NativeRichRowCanvas(frame: thinkingDetailFrame)
                    detail.snapshot = thinkingDetail
                    detail.onOpenLink = { [weak self] url in self?.onOpenLink?(url) }
                    addSubview(detail)
                    ordered.append(detail)
                    headerY = thinkingDetailFrame.maxY + 8
                }
            }
            for action in toolActions {
                let button = disclosureButton(title: action.title, symbol: action.symbol,
                    frame: action.headerFrame, expanded: action.isExpanded,
                    onTap: { [weak self] in self?.onToggleTool?(action.id) })
                button.accessibilityIdentifier = "native-tool-action-\(action.id)"
                button.accessibilityValue = action.accessibilityStatus
                addSubview(button)
                ordered.append(button)
                if let detail = action.detail, let frame = action.detailFrame {
                    let canvas = NativeRichRowCanvas(frame: frame)
                    canvas.snapshot = detail
                    canvas.onOpenLink = { [weak self] url in self?.onOpenLink?(url) }
                    addSubview(canvas)
                    ordered.append(canvas)
                }
            }
            let bubble = UIView(frame: bubbleFrame)
            bubble.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.8)
            bubble.layer.cornerRadius = 18
            addSubview(bubble)
            let canvas = NativeRichRowCanvas(frame: canvasFrame)
            canvas.snapshot = body
            canvas.onOpenLink = { [weak self] url in self?.onOpenLink?(url) }
            canvas.onToggleCodeWrap = { [weak self] in self?.onToggleCodeWrap?() }
            canvas.addInteraction(UIContextMenuInteraction(delegate: self))
            addSubview(canvas)
            // Keep the full-response AX summary focusable without covering the
            // code controls and link hit targets in the body below the heading.
            summary.accessibilityFrameInContainerSpace = CGRect(
                x: bubbleFrame.minX, y: bubbleFrame.minY,
                width: bubbleFrame.width, height: min(36, bubbleFrame.height))
            ordered.append(summary)
            ordered.append(canvas)
            if let linkPreview, let hostingParent {
                var createdHost = false
                if previewURL != linkPreview.url || previewHost == nil {
                    previewHost?.willMove(toParent: nil)
                    previewHost?.removeFromParent()
                    let root = TranscriptLinkPreviewView(url: linkPreview.url)
                        .environment(\.openURL, OpenURLAction { [weak self] url in
                            self?.onOpenLink?(url)
                            return .handled
                        })
                    let host = UIHostingController(rootView: AnyView(root))
                    host.view.backgroundColor = .clear
                    hostingParent.addChild(host)
                    previewHost = host
                    previewURL = linkPreview.url
                    createdHost = true
                }
                if let previewHost {
                    let previewView = previewHost.view!
                    previewView.frame = linkPreview.frame
                    previewView.accessibilityElementsHidden = true
                    addSubview(previewView)
                    if createdHost {
                        previewHost.didMove(toParent: hostingParent)
                    }
                    let previewButton = UIButton(type: .custom)
                    previewButton.frame = linkPreview.frame
                    previewButton.backgroundColor = .clear
                    previewButton.accessibilityLabel = linkPreview.url.host.map {
                        "Link preview for \($0)"
                    } ?? "Link preview"
                    previewButton.accessibilityHint = "Opens in the external browser"
                    previewButton.addAction(UIAction { [weak self] _ in
                        self?.onOpenLink?(linkPreview.url)
                    }, for: .touchUpInside)
                    addSubview(previewButton)
                    ordered.append(previewButton)
                }
            } else if let previewHost {
                previewHost.willMove(toParent: nil)
                previewHost.removeFromParent()
                self.previewHost = nil
                previewURL = nil
            }
            if let copyFrame {
                let button = UIButton(type: .system)
                button.setTitle("Copy", for: .normal)
                button.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
                button.tintColor = .secondaryLabel
                button.accessibilityIdentifier = "assistant-response-copy"
                button.frame = copyFrame
                button.addAction(UIAction { [weak self] _ in self?.onCopyResponse?() }, for: .touchUpInside)
                addSubview(button)
                ordered.append(button)
            }
        }
        accessibilityElements = ordered
    }

    private func disclosureButton(title: String, symbol: String, y: CGFloat,
                                  expanded: Bool = false, onTap: (() -> Void)? = nil) -> UIButton {
        disclosureButton(title: title, symbol: symbol,
                         frame: CGRect(x: 0, y: y, width: bounds.width, height: 44),
                         expanded: expanded, onTap: onTap)
    }

    private func disclosureButton(title: String, symbol: String, frame: CGRect,
                                  expanded: Bool = false, onTap: (() -> Void)? = nil) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)), for: .normal)
        button.setTitle("  \(title)", for: .normal)
        button.contentHorizontalAlignment = .leading
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 26)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .subheadline)
        button.tintColor = .secondaryLabel
        button.accessibilityLabel = title
        button.accessibilityHint = expanded ? "Double tap to collapse details." : "Double tap to expand details."
        button.frame = frame
        let chevron = UIImageView(image: UIImage(systemName: expanded ? "chevron.down" : "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
        chevron.tintColor = .secondaryLabel
        chevron.frame = CGRect(x: frame.width - 22, y: 15, width: 12, height: 14)
        chevron.isAccessibilityElement = false
        chevron.isUserInteractionEnabled = false
        button.addSubview(chevron)
        button.addAction(UIAction { [weak self] _ in
            if let onTap { onTap() }
            else { self?.onUnsupportedDisclosure?(title) }
        }, for: .touchUpInside)
        return button
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Select Text", image: UIImage(systemName: "text.cursor")) { _ in self?.onSelectText?() },
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in self?.onCopyResponse?() }
            ])
        }
    }
}

#endif
