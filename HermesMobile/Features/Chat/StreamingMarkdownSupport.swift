import Foundation
import MarkdownUI

/// The platform can reject Unicode shaping for a single very long paragraph.
/// Keep independent final layout units bounded without changing the parsed text.
struct BoundedMarkdownParagraph {
    static let minimumSourceBytes = 4_096
    static let maximumLeafCharacters = 1_024
    static let maximumLeafUTF8Bytes = 4_096
    static let maximumLeafUTF16Units = 2_048

    let text: AttributedString
    let leaves: [AttributedString]

    static func prepare(_ content: MarkdownContent) -> Self? {
        let markdown = content.renderMarkdown()
        guard markdown.utf8.count > minimumSourceBytes,
              let attributed = try? AttributedString(markdown: markdown,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)),
              let reconstructed = reconstruct(attributed), reconstructed == content,
              let leaves = split(attributed) else { return nil }
        return Self(text: attributed, leaves: leaves)
    }

    /// Foundation is a compatibility parser here, not the source of truth.
    /// Require the public MarkdownUI AST to match before accepting its runs.
    /// Images, HTML, breaks and unmatched nesting retain the original renderer.
    private static func reconstruct(_ attributed: AttributedString) -> MarkdownContent? {
        var parts: [InlineContent] = []
        let supported: InlinePresentationIntent = [.emphasized, .stronglyEmphasized, .strikethrough, .code]
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            guard intent.subtracting(supported).isEmpty else { return nil }
            let text = String(attributed[run.range].characters)
            var part = intent.contains(.code) ? Code(text)._inlineContent : InlineContentBuilder.buildExpression(text)
            if intent.contains(.emphasized) { let child = part; part = Emphasis { child }._inlineContent }
            if intent.contains(.stronglyEmphasized) { let child = part; part = Strong { child }._inlineContent }
            if intent.contains(.strikethrough) { let child = part; part = Strikethrough { child }._inlineContent }
            if let link = run.link { let child = part; part = InlineLink(destination: link) { child }._inlineContent }
            parts.append(part)
        }
        return MarkdownContent { Paragraph { for part in parts { part } } }
    }

    private static func split(_ attributed: AttributedString) -> [AttributedString]? {
        let source = String(attributed.characters)
        var ranges: [Range<String.Index>] = []
        var start = source.startIndex
        while start < source.endIndex {
            var end = start
            var characters = 0, bytes = 0, units = 0
            var whitespaceEnd: String.Index?
            while end < source.endIndex {
                let next = source.index(after: end)
                let grapheme = source[end..<next]
                let nextBytes = grapheme.utf8.count, nextUnits = grapheme.utf16.count
                guard characters < maximumLeafCharacters,
                      bytes + nextBytes <= maximumLeafUTF8Bytes,
                      units + nextUnits <= maximumLeafUTF16Units else { break }
                characters += 1; bytes += nextBytes; units += nextUnits
                if source[end].isWhitespace { whitespaceEnd = next }
                end = next
            }
            // Never cut inside a grapheme, including a pathological single
            // cluster larger than the budget. Such content uses the old path.
            guard end > start else { return nil }
            if end < source.endIndex, let whitespaceEnd { end = whitespaceEnd }
            ranges.append(start..<end)
            start = end
        }
        var cursor = attributed.startIndex
        return ranges.map { range in
            let end = attributed.characters.index(cursor, offsetBy: source[range].count)
            defer { cursor = end }
            return AttributedString(attributed[cursor..<end])
        }
    }
}

struct StreamingMarkdownChunk: Identifiable, Equatable {
    let id: Int
    let text: String
}

struct StreamingMarkdownBlockSegments: Equatable {
    let stableChunks: [StreamingMarkdownChunk]
    let activeMarkdown: String
}

enum StreamingMarkdownBlockSplitter {
    // Semantic boundaries are useful, but an unbounded number of MarkdownUI
    // subtrees makes each streaming flush increasingly expensive. Keep the
    // cheap fine-grained chunks up to this cap, then fall back to larger
    // ~6k-character chunks for the rest of a long response.
    static let maxSemanticStableChunkCount = 64
    static let stableChunkTargetCharacterCount = 6_000

    /// A completed semantic Markdown block is safe to freeze. The active tail
    /// remains the only block MarkdownUI reparses while tokens arrive.
    static func split(_ text: String) -> StreamingMarkdownBlockSegments {
        var lineStart = text.startIndex
        var chunkStart = text.startIndex
        var isInsideFence = false
        var stableChunks: [StreamingMarkdownChunk] = []

        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let nextLineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            let hasLineBreak = lineEnd < text.endIndex
            let trimmedLine = String(text[lineStart..<lineEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var stableBoundary: String.Index?
            if isFenceDelimiter(trimmedLine) {
                isInsideFence.toggle()
                if !isInsideFence {
                    stableBoundary = nextLineStart
                }
            } else if !isInsideFence, hasLineBreak {
                if trimmedLine.isEmpty || isStableSingleLineBlock(trimmedLine) {
                    stableBoundary = nextLineStart
                }
            }

            if let stableBoundary,
               shouldSealChunk(
                   in: text,
                   from: chunkStart,
                   to: stableBoundary,
                   stableChunkCount: stableChunks.count
               ) {
                appendChunk(in: text, from: chunkStart, to: stableBoundary, into: &stableChunks)
                chunkStart = stableBoundary
            }

            lineStart = nextLineStart
        }

        return StreamingMarkdownBlockSegments(
            stableChunks: stableChunks,
            activeMarkdown: String(text[chunkStart...])
        )
    }

    private static func shouldSealChunk(
        in text: String,
        from start: String.Index,
        to boundary: String.Index,
        stableChunkCount: Int
    ) -> Bool {
        // `boundary` is a blank-line, heading, or closed-fence boundary. Once
        // there is content after it, that block cannot change as the live tail
        // grows, so keep it out of the hot MarkdownUI layout path.
        guard boundary > start, boundary < text.endIndex else { return false }
        guard stableChunkCount >= maxSemanticStableChunkCount else { return true }
        return text.distance(from: start, to: boundary) >= stableChunkTargetCharacterCount
    }

    private static func appendChunk(
        in text: String,
        from start: String.Index,
        to end: String.Index,
        into chunks: inout [StreamingMarkdownChunk]
    ) {
        guard start < end else { return }
        let chunkText = String(text[start..<end])
        guard !chunkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chunks.append(
            StreamingMarkdownChunk(
                id: chunks.count,
                text: chunkText
            )
        )
    }

    fileprivate static func isFenceDelimiter(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~")
    }

    fileprivate static func isStableSingleLineBlock(_ trimmedLine: String) -> Bool {
        let headingMarkerCount = trimmedLine.prefix(while: { $0 == "#" }).count
        let isHeading = (1...6).contains(headingMarkerCount)
            && trimmedLine.dropFirst(headingMarkerCount).first?.isWhitespace == true
        return isHeading || trimmedLine == "---" || trimmedLine == "***"
    }
}

/// Incremental counterpart to `StreamingMarkdownBlockSplitter` for append-only
/// response updates. The regular splitter remains the reference implementation
/// and is used when content is replaced (replay, reload, or a new response).
///
/// The previous implementation rescanned every completed line from the start of
/// the response on every streaming flush. This accumulator keeps the last line
/// provisional, because a boundary at the end of the current string cannot be
/// sealed until more content arrives, and resumes from that line on the next
/// append. A separate byte cursor avoids searching the unfinished line again.
/// Stable chunks retain the same IDs and text as the reference splitter.
struct StreamingMarkdownBlockAccumulator {
    /// Raw-source streaming must not seal a blank line out of a math expression.
    /// Conservatively retain the tail after the first math opener; the bounded
    /// literal lane handles a long tail, and canonical completion resolves it.
    var preservesRawMath = false
    private var stableChunks: [StreamingMarkdownChunk] = []
    private var rawMathObserved = false
    private var chunkStartUTF16Offset = 0
    private var pendingLineStartUTF16Offset = 0
    private var newlineSearchUTF8Offset = 0
    private var isInsideFenceBeforePendingLine = false
    private var lastTextUTF16Length = 0
    private var isInitialized = false

    init(preservesRawMath: Bool = false) {
        self.preservesRawMath = preservesRawMath
    }

    /// `appendOnly` requires a byte-exact UTF-8 extension of the previous input,
    /// including unchanged input. Canonically equivalent replacements must reset.
    mutating func update(
        _ text: String,
        appendOnly: Bool
    ) -> StreamingMarkdownBlockSegments {
        let textLength = text.utf16.count
        if !isInitialized || !appendOnly || textLength < lastTextUTF16Length {
            reset()
        }

        guard !isInitialized || textLength != lastTextUTF16Length else {
            return result(in: text)
        }

        scanNewLines(in: text)
        lastTextUTF16Length = textLength
        isInitialized = true
        return result(in: text)
    }

    mutating func reset() {
        stableChunks = []
        rawMathObserved = false
        chunkStartUTF16Offset = 0
        pendingLineStartUTF16Offset = 0
        newlineSearchUTF8Offset = 0
        isInsideFenceBeforePendingLine = false
        lastTextUTF16Length = 0
        isInitialized = false
    }

    private mutating func scanNewLines(in text: String) {
        let endOffset = text.utf16.count
        var lineStartOffset = pendingLineStartUTF16Offset
        var isInsideFence = isInsideFenceBeforePendingLine

        guard lineStartOffset <= endOffset else {
            reset()
            return
        }

        let bytes = text.utf8
        var searchStart = bytes.index(bytes.startIndex, offsetBy: newlineSearchUTF8Offset)
        while let lf = bytes[searchStart...].firstIndex(of: 0x0A) {
            newlineSearchUTF8Offset += bytes.distance(from: searchStart, to: lf)
            searchStart = bytes.index(after: lf)

            // Character-based firstIndex(of: "\n") skips CRLF, which is one
            // Character. Look behind even when CR arrived in the prior append.
            if lf > bytes.startIndex, bytes[bytes.index(before: lf)] == 0x0D {
                newlineSearchUTF8Offset += 1
                continue
            }

            // A standalone LF is a complete Character regardless of adjacent
            // combining/ZWJ scalars. Convert only here, never at an old string's
            // end offset, which may now lie inside an extended grapheme.
            let lineEnd = String.Index(lf, within: text)!
            let nextLineStart = text.index(after: lineEnd)
            let nextLineOffset = nextLineStart.utf16Offset(in: text)

            // A boundary at the end of the current string is provisional. Keep
            // this line and its pre-line fence state for the next append.
            guard nextLineOffset < endOffset else {
                // Revisit this LF once it has following content, without
                // searching the pending line that precedes it again.
                pendingLineStartUTF16Offset = lineStartOffset
                isInsideFenceBeforePendingLine = isInsideFence
                return
            }

            let lineStart = String.Index(utf16Offset: lineStartOffset, in: text)
            let line = text[lineStart..<lineEnd]
            let trimmedLine = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if preservesRawMath,
               trimmedLine.contains("$") || trimmedLine.contains(#"\("#) || trimmedLine.contains(#"\["#) {
                rawMathObserved = true
            }
            var stableBoundaryOffset: Int?

            if StreamingMarkdownBlockSplitter.isFenceDelimiter(trimmedLine) {
                isInsideFence.toggle()
                if !isInsideFence {
                    stableBoundaryOffset = nextLineOffset
                }
            } else if !isInsideFence, lineEnd < text.endIndex {
                if trimmedLine.isEmpty || StreamingMarkdownBlockSplitter.isStableSingleLineBlock(trimmedLine) {
                    stableBoundaryOffset = nextLineOffset
                }
            }

            if !rawMathObserved, let stableBoundaryOffset,
               shouldSealChunk(
                   in: text,
                   boundaryOffset: stableBoundaryOffset
               ) {
                appendChunk(
                    in: text,
                    from: chunkStartUTF16Offset,
                    to: stableBoundaryOffset
                )
                chunkStartUTF16Offset = stableBoundaryOffset
            }

            lineStartOffset = nextLineOffset
            newlineSearchUTF8Offset += 1
        }

        newlineSearchUTF8Offset += bytes.distance(from: searchStart, to: bytes.endIndex)
        pendingLineStartUTF16Offset = lineStartOffset
        isInsideFenceBeforePendingLine = isInsideFence
    }

    private func shouldSealChunk(
        in text: String,
        boundaryOffset: Int
    ) -> Bool {
        guard boundaryOffset > chunkStartUTF16Offset else { return false }
        guard stableChunks.count >= StreamingMarkdownBlockSplitter.maxSemanticStableChunkCount else {
            return true
        }

        let chunkStart = String.Index(utf16Offset: chunkStartUTF16Offset, in: text)
        let boundary = String.Index(utf16Offset: boundaryOffset, in: text)
        return text.distance(from: chunkStart, to: boundary)
            >= StreamingMarkdownBlockSplitter.stableChunkTargetCharacterCount
    }

    private mutating func appendChunk(
        in text: String,
        from startOffset: Int,
        to endOffset: Int
    ) {
        guard startOffset < endOffset else { return }

        let start = String.Index(utf16Offset: startOffset, in: text)
        let end = String.Index(utf16Offset: endOffset, in: text)
        let chunkText = String(text[start..<end])
        guard preservesRawMath || !chunkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        stableChunks.append(
            StreamingMarkdownChunk(
                id: stableChunks.count,
                text: chunkText
            )
        )
    }

    private func result(in text: String) -> StreamingMarkdownBlockSegments {
        let activeStart = String.Index(
            utf16Offset: min(chunkStartUTF16Offset, text.utf16.count),
            in: text
        )
        return StreamingMarkdownBlockSegments(
            stableChunks: stableChunks,
            activeMarkdown: String(text[activeStart...])
        )
    }
}

/// Rendering budgets, independent of transport cadence. A long unfinished
/// paragraph/fence must not grow the Markdown parser or per-glyph fade workload.
enum StreamingMarkdownRenderBudget {
    static let maximumRichTailUTF8Bytes = 4_096
    static let literalLeafCharacters = 1_024

    static func usesLiteralTail(_ source: String) -> Bool {
        source.utf8.count > maximumRichTailUTF8Bytes
    }
}

/// Exact raw text sliced only for provisional layout. Stable leaves never change
/// on append; one trailing grapheme remains mutable so later combining marks or
/// ZWJ scalars cannot invalidate a sealed boundary. Concatenation is byte-exact.
/// These are not Markdown blocks: canonical completion must still parse the
/// original source, including cross-block links, math, lists and fence state.
struct StreamingLiteralAccumulator {
    private(set) var stableChunks: [StreamingMarkdownChunk] = []
    private(set) var tail = ""
    private(set) var source = ""
    private(set) var appendedUTF8Bytes = 0

    mutating func update(_ next: String) {
        guard !source.utf8.elementsEqual(next.utf8) else { return }
        if next.utf8.starts(with: source.utf8) {
            let addition = String(decoding: next.utf8.dropFirst(source.utf8.count), as: UTF8.self)
            tail.append(addition)
            appendedUTF8Bytes += addition.utf8.count
        } else {
            stableChunks = []
            tail = next
            appendedUTF8Bytes = next.utf8.count
        }
        source = next
        let limit = StreamingMarkdownRenderBudget.literalLeafCharacters
        var start = tail.startIndex
        while let hardBoundary = tail.index(start, offsetBy: limit, limitedBy: tail.endIndex), hardBoundary < tail.endIndex {
            let window = tail[start..<hardBoundary]
            // Adjacent Text leaves supply a line break. Prefer a source line
            // ending near the cap, otherwise finish a word rather than showing
            // fragments such as "th" / "eir" in ordinary prose.
            let nearbyStart = tail.index(hardBoundary, offsetBy: -min(256, limit))
            let lineEnd = tail[nearbyStart..<hardBoundary].lastIndex(where: \.isNewline)
            let whitespace = lineEnd ?? window.lastIndex(where: \.isWhitespace)
            let boundary: String.Index
            if let whitespace,
               tail[whitespace].isNewline || window[..<whitespace].contains(where: { !$0.isWhitespace }) {
                boundary = tail.index(after: whitespace)
            } else {
                // An individual whitespace-free run longer than the cap still
                // needs ordinary grapheme-safe wrapping to bound layout work.
                boundary = hardBoundary
            }
            stableChunks.append(StreamingMarkdownChunk(id: stableChunks.count, text: String(tail[start..<boundary])))
            start = boundary
        }
        tail = String(tail[start...])
    }

    /// VStack already supplies the visual boundary after a sealed leaf. Omit
    /// exactly one terminal newline from its display, including a CRLF grapheme,
    /// so it does not add an extra empty line. Raw chunk/canonical bytes retain it.
    static func displayText(forSealedLeaf source: String) -> String {
        guard source.last?.isNewline == true else { return source }
        return String(source.dropLast())
    }
}
