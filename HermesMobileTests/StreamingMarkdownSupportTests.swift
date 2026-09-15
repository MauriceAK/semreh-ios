import XCTest
@testable import HermesMobile

final class ReasoningDisplayTextTests: XCTestCase {
    func testReasoningBlockDefaultsToCompletedStaticPresentation() {
        XCTAssertFalse(ReasoningBlockView(text: "Actual reasoning").isActive)
        XCTAssertFalse(ReasoningDisplayText.shouldAnimateShine(isActive: false, reduceMotion: false))
    }

    func testReasoningShineOnlyRunsForActiveReasoningWhenMotionIsAllowed() {
        XCTAssertTrue(ReasoningDisplayText.shouldAnimateShine(isActive: true, reduceMotion: false))
        XCTAssertFalse(ReasoningDisplayText.shouldAnimateShine(isActive: true, reduceMotion: true))
        XCTAssertFalse(ReasoningDisplayText.shouldAnimateShine(isActive: false, reduceMotion: true))
    }

    func testSummaryPreservesPlainText() {
        XCTAssertEqual(ReasoningDisplayText.summary("Checking the available sources."), "Checking the available sources.")
    }

    func testSummaryRendersMarkdownInsteadOfShowingSourceMarkers() {
        XCTAssertEqual(
            ReasoningDisplayText.summary("# Searching Reddit\n\nFound **compensation sources** and [interviews](https://example.test)."),
            "Found compensation sources and interviews."
        )
    }

    func testSummaryUsesLatestMeaningfulActivityFromTheBoundedTail() {
        let earlierHistory = String(repeating: "Older reasoning note.\n", count: 40)
        let source = earlierHistory + "◉_◉ computing...\n\n**Latest status**"

        XCTAssertEqual(ReasoningDisplayText.latestActivity(in: source), "Latest status")
    }

    func testSummaryBoundsTheLatestLineFromItsTail() {
        XCTAssertEqual(
            ReasoningDisplayText.summary("Prior status\n\n12345 67890", maximumCharacters: 8),
            "…5 67890"
        )
        XCTAssertEqual(ReasoningDisplayText.summary("Latest meaningful status\n\n# "), "Latest meaningful status")
    }

    func testSummaryHidesIncompleteStreamingMarkdownDelimiter() {
        XCTAssertEqual(ReasoningDisplayText.summary("**Searching the latest sources"), "Searching the latest sources")
    }

    func testSummaryNeverBecomesEmptyForMarkerOnlyInput() {
        XCTAssertEqual(ReasoningDisplayText.summary("`"), "Thinking…")
        XCTAssertEqual(ReasoningDisplayText.summary("```"), "Thinking…")
        XCTAssertEqual(ReasoningDisplayText.summary("`search term`"), "search term")
    }

    func testCompletedSpinnerOnlyReasoningDoesNotLeaveTrailingDisclosure() {
        let spinnerOnly = ReasoningDisplayText.presentation(for: "◉_◉ computing...")

        XCTAssertTrue(ReasoningDisplayText.shouldDisplayDisclosure(
            isActive: true,
            rawText: "◉_◉ computing...",
            latestActivity: spinnerOnly.latestActivity,
            markdownSource: nil
        ))
        XCTAssertFalse(ReasoningDisplayText.shouldDisplayDisclosure(
            isActive: false,
            rawText: "◉_◉ computing...",
            latestActivity: spinnerOnly.latestActivity,
            markdownSource: spinnerOnly.markdownSource
        ))

        let meaningfulHistory = ReasoningDisplayText.presentation(for: "Checked the matching transcript row.")
        XCTAssertTrue(ReasoningDisplayText.shouldDisplayDisclosure(
            isActive: false,
            rawText: "Checked the matching transcript row.",
            latestActivity: meaningfulHistory.latestActivity,
            markdownSource: nil
        ), "completed meaningful reasoning remains available as history")
        XCTAssertFalse(ReasoningDisplayText.shouldDisplayDisclosure(
            isActive: true,
            rawText: " \n ",
            latestActivity: nil,
            markdownSource: nil
        ), "blank payloads have no disclosure body or header to expand")
    }

    func testPresentationRemovesOnlyVerifiedSpinnerTokensOutsideCode() {
        let source = """
        **Searching** ◉_◉ computing...
        `◉_◉ analyzing...` and ◉_◉ custom note
        ```swift
        let status = "ಠ_ಠ cogitating..."
        ```
        (¬_¬) custom emoticon remains
        """

        let presentation = ReasoningDisplayText.presentation(for: source)

        XCTAssertEqual(
            presentation.markdownSource,
            """
            **Searching**
            `◉_◉ analyzing...` and ◉_◉ custom note
            ```swift
            let status = "ಠ_ಠ cogitating..."
            ```
            (¬_¬) custom emoticon remains
            """
        )
        XCTAssertEqual(presentation.latestActivity, "(¬_¬) custom emoticon remains")
    }

    func testPresentationPreservesMarkdownForExpandedReasoning() {
        let source = "**Bold** and `inline code`\n\n- First item\n- Second item"

        XCTAssertEqual(ReasoningDisplayText.markdownSource(source), source)
    }

    func testMissingEmptyAndSpinnerOnlyReasoningHaveNoExpandedMarkdown() {
        for source in ["", " \n \t", "◉_◉ computing...", "ಠ_ಠ brainstorming..."] {
            let presentation = ReasoningDisplayText.presentation(for: source)
            XCTAssertNil(presentation.markdownSource, "unexpected Markdown for \(source)")
            XCTAssertNil(presentation.latestActivity, "unexpected summary for \(source)")
            XCTAssertEqual(ReasoningDisplayText.summary(source), "Thinking…")
        }
    }
}

final class ToolActivityGroupPresentationTests: XCTestCase {
    func testCollapsedActivityUsesTheLatestActionAndItsState() {
        let group = ToolCallGroup(
            anchorMessageID: "assistant-1",
            toolCalls: [
                ToolCall(name: "terminal", preview: nil, args: nil, isCompleted: true),
                ToolCall(name: "read_file", preview: nil, args: nil, isCompleted: false)
            ]
        )

        XCTAssertEqual(ToolActivityGroupPresentation.title(for: group), "Read file")
        XCTAssertEqual(ToolActivityGroupPresentation.icon(for: group), "book")
        XCTAssertEqual(ToolActivityGroupPresentation.status(for: group), "Running")
    }

    func testCompletedActivityUsesOnlyTheLatestRealDuration() {
        let group = ToolCallGroup(
            anchorMessageID: "assistant-1",
            toolCalls: [
                ToolCall(name: "terminal", preview: nil, args: nil, duration: 88, isCompleted: true),
                ToolCall(name: "read_file", preview: nil, args: nil, duration: 1.24, isCompleted: true)
            ]
        )

        XCTAssertEqual(ToolActivityGroupPresentation.status(for: group), "Worked for 1.2s")
    }

    func testMissingOrInvalidDurationNeverProducesAnEstimatedDuration() {
        for duration in [Double?.none, .some(.nan), .some(-1)] {
            let group = ToolCallGroup(
                anchorMessageID: "assistant-1",
                toolCalls: [
                    ToolCall(
                        name: "terminal",
                        preview: nil,
                        args: nil,
                        duration: duration,
                        isCompleted: true
                    )
                ]
            )

            XCTAssertEqual(ToolActivityGroupPresentation.status(for: group), "Completed")
        }
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
