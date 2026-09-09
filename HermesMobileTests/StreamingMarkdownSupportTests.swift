import XCTest
@testable import HermesMobile

final class ReasoningDisplayTextTests: XCTestCase {
    func testSummaryPreservesPlainText() {
        XCTAssertEqual(ReasoningDisplayText.summary("Checking the available sources."), "Checking the available sources.")
    }

    func testSummaryRendersMarkdownInsteadOfShowingSourceMarkers() {
        XCTAssertEqual(
            ReasoningDisplayText.summary("# Searching Reddit\n\nFound **compensation sources** and [interviews](https://example.test)."),
            "Searching Reddit Found compensation sources and interviews."
        )
    }

    func testSummaryCollapsesWhitespaceAndBoundsRenderedCharacters() {
        let summary = ReasoningDisplayText.summary("**12345**\n\n67890", maximumCharacters: 8)

        XCTAssertEqual(summary, "12345 67...")
    }

    func testSummaryHidesIncompleteStreamingMarkdownDelimiter() {
        XCTAssertEqual(ReasoningDisplayText.summary("**Searching the latest sources"), "Searching the latest sources")
    }

    func testSummaryNeverBecomesEmptyForMarkerOnlyInput() {
        XCTAssertEqual(ReasoningDisplayText.summary("`"), "Thinking…")
    }
}

final class StreamingMarkdownBlockSplitterTests: XCTestCase {
    func testShortTextStaysInActiveMarkdown() {
        let text = "Hello from Hermes."
        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertTrue(segments.stableChunks.isEmpty)
        XCTAssertEqual(segments.activeMarkdown, text)
    }

    func testCompletedFenceSealsStableChunk() {
        let stableBody = String(repeating: "A", count: 6_100)
        let text = """
        \(stableBody)
        ```swift
        let answer = 42
        ```
        Still streaming
        """

        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertEqual(segments.stableChunks.count, 1)
        XCTAssertTrue(segments.stableChunks[0].text.contains(stableBody))
        XCTAssertTrue(segments.activeMarkdown.contains("Still streaming"))
    }

    func testHeadingBoundaryCanSealWithoutFence() {
        let prose = String(repeating: "Line of prose.\n", count: 500)
        let text = prose + "## Next section\nMore text"

        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertFalse(segments.stableChunks.isEmpty)
        XCTAssertTrue(segments.activeMarkdown.contains("More text"))
    }

    func testTabSeparatedHeadingCountsAsStableBoundary() {
        let prose = String(repeating: "Line of prose.\n", count: 500)
        let text = prose + "##\tTab heading\nMore text"

        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertFalse(segments.stableChunks.isEmpty)
        XCTAssertTrue(segments.activeMarkdown.contains("More text"))
    }

    func testCompletedParagraphSealsWithoutWaitingForThousandsOfCharacters() {
        let text = "First paragraph is done.\n\nSecond paragraph is still grow"
        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertEqual(segments.stableChunks.map(\.text).joined(), "First paragraph is done.\n\n")
        XCTAssertEqual(segments.activeMarkdown, "Second paragraph is still grow")
    }

    func testShortCompletedFenceSealsEvenWhenTheBodyIsSmall() {
        let text = """
        ```swift
        let answer = 42
        ```
        Still streaming
        """
        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertEqual(segments.stableChunks.count, 1)
        XCTAssertTrue(segments.stableChunks[0].text.contains("let answer = 42"))
        XCTAssertEqual(segments.activeMarkdown.trimmingCharacters(in: .whitespacesAndNewlines), "Still streaming")
    }

    func testIncompleteLastParagraphStaysInTheActiveTail() {
        let segments = StreamingMarkdownBlockSplitter.split("Only this growing sentence")
        XCTAssertTrue(segments.stableChunks.isEmpty)
        XCTAssertEqual(segments.activeMarkdown, "Only this growing sentence")
    }

    func testManyCompletedParagraphsKeepStableChunkCountBounded() {
        let text = (0..<500)
            .map { "Paragraph \($0) is complete.\n\n" }
            .joined()
            + "Still streaming"

        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertLessThan(
            segments.stableChunks.count,
            StreamingMarkdownBlockSplitter.maxSemanticStableChunkCount + 16
        )
        XCTAssertTrue(segments.activeMarkdown.contains("Still streaming"))
    }
}

final class StreamingMarkdownBlockAccumulatorTests: XCTestCase {
    func testAppendOnlyUpdatesMatchReferenceSplitter() {
        let text = (0..<120)
            .map { "Paragraph \($0) is complete.\n\n" }
            .joined()
            + "The final paragraph keeps growing."
        var accumulator = StreamingMarkdownBlockAccumulator()

        for length in stride(from: 1, through: text.count, by: 7) {
            let end = text.index(text.startIndex, offsetBy: length)
            let prefix = String(text[..<end])
            let incremental = accumulator.update(prefix, appendOnly: length > 1)
            XCTAssertEqual(
                incremental,
                StreamingMarkdownBlockSplitter.split(prefix),
                "mismatch at prefix length \(length)"
            )
        }
    }

    func testReplacementResetsIncrementalState() {
        var accumulator = StreamingMarkdownBlockAccumulator()
        _ = accumulator.update("First paragraph.\n\nOld tail", appendOnly: false)

        let replacement = "New heading\n\nNew tail"
        XCTAssertEqual(
            accumulator.update(replacement, appendOnly: false),
            StreamingMarkdownBlockSplitter.split(replacement)
        )
    }

    func testUnicodeAppendPreservesReferenceBoundaries() {
        let text = "👩‍👩‍👧‍👦 first paragraph.\n\n第二段仍在增长。"
        var accumulator = StreamingMarkdownBlockAccumulator()
        var prefix = ""
        var isFirstPrefix = true

        for character in text {
            prefix.append(character)
            XCTAssertEqual(
                accumulator.update(prefix, appendOnly: !isFirstPrefix),
                StreamingMarkdownBlockSplitter.split(prefix)
            )
            isFirstPrefix = false
        }
    }
}

/// Width resolution for chat markdown table cells (issue #233). The layout
/// itself needs a render pass to verify; this covers the pure clamp that
/// decides the wrap width the cell height is measured at.
final class TableCellWidthCapTests: XCTestCase {
    private let minWidth: CGFloat = 96
    private let maxWidth: CGFloat = 260

    func testIdealWidthBelowMinClampsToMin() {
        let width = TableCellWidthCap.resolvedWidth(
            idealWidth: 40, proposedWidth: nil, minWidth: minWidth, maxWidth: maxWidth
        )
        XCTAssertEqual(width, minWidth)
    }

    func testIdealWidthWithinBoundsIsUsedAsIs() {
        let width = TableCellWidthCap.resolvedWidth(
            idealWidth: 150, proposedWidth: nil, minWidth: minWidth, maxWidth: maxWidth
        )
        XCTAssertEqual(width, 150)
    }

    func testIdealWidthAboveMaxClampsToMax() {
        let width = TableCellWidthCap.resolvedWidth(
            idealWidth: 1_200, proposedWidth: nil, minWidth: minWidth, maxWidth: maxWidth
        )
        XCTAssertEqual(width, maxWidth)
    }

    func testProposedColumnWidthOverridesIdealWidth() {
        let width = TableCellWidthCap.resolvedWidth(
            idealWidth: 40, proposedWidth: 200, minWidth: minWidth, maxWidth: maxWidth
        )
        XCTAssertEqual(width, 200)
    }

    func testProposedColumnWidthIsStillClamped() {
        let width = TableCellWidthCap.resolvedWidth(
            idealWidth: 40, proposedWidth: 999, minWidth: minWidth, maxWidth: maxWidth
        )
        XCTAssertEqual(width, maxWidth)
    }
}
