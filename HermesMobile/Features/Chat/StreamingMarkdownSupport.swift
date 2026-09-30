import Foundation

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
    private var stableChunks: [StreamingMarkdownChunk] = []
    private var chunkStartUTF16Offset = 0
    private var pendingLineStartUTF16Offset = 0
    private var newlineSearchUTF8Offset = 0
    private var isInsideFenceBeforePendingLine = false
    private var lastTextUTF16Length = 0
    private var isInitialized = false

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

            if let stableBoundaryOffset,
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
        guard !chunkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

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
