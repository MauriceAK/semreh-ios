import XCTest
import SwiftUI
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

final class ChatCodeInlinePreviewPolicyTests: XCTestCase {
    func testLongCodeShowsOnlyFirst32ExactLinesAndKeepsLastMarkerForFullViewer() {
        let line = "let value = Array(0..<1_000).reduce(0, +)\n"
        let source = String(repeating: line, count: 320) + "let finalMarker = \"SEMREH_FOUR_TALL_CODE_END\""
        let inline = ChatCodeInlinePreviewPolicy.displaySource(for: source)

        XCTAssertEqual(inline, String(repeating: line, count: 32))
        XCTAssertEqual(inline.components(separatedBy: line).count - 1, 32)
        XCTAssertFalse(inline.contains("SEMREH_FOUR_TALL_CODE_END"))
        XCTAssertTrue(source.contains("SEMREH_FOUR_TALL_CODE_END"))
    }

    func testShortCodeRemainsByteIdenticalIncludingUnicodeAndLineBreaks() {
        let source = "let emoji = \"👩🏽‍💻\"\r\nlet arabic = \"العربية\"\n"
        XCTAssertEqual(ChatCodeInlinePreviewPolicy.displaySource(for: source), source)
    }
}

final class ToolActivityGroupPresentationTests: XCTestCase {
    func testCollapsedMultiActionUsesNeutralSummaryAndRunningState() {
        let group = ToolCallGroup(
            anchorMessageID: "assistant-1",
            toolCalls: [
                ToolCall(name: "terminal", preview: nil, args: nil, isCompleted: true),
                ToolCall(name: "read_file", preview: nil, args: nil, isCompleted: false)
            ]
        )

        XCTAssertEqual(ToolActivityGroupPresentation.title(for: group), "2 actions")
        XCTAssertEqual(ToolActivityGroupPresentation.icon(for: group), "square.stack.3d.up")
        XCTAssertEqual(ToolActivityGroupPresentation.status(for: group), "Running")
    }

    func testCompletedMultiActionDoesNotMisstateItsDuration() {
        let group = ToolCallGroup(
            anchorMessageID: "assistant-1",
            toolCalls: [
                ToolCall(name: "terminal", preview: nil, args: nil, duration: 88, isCompleted: true),
                ToolCall(name: "read_file", preview: nil, args: nil, duration: 1.24, isCompleted: true)
            ]
        )

        XCTAssertEqual(ToolActivityGroupPresentation.status(for: group), "Completed")
    }

    func testSingleActionKeepsItsSpecificTitleIconAndDuration() {
        let group = ToolCallGroup(
            anchorMessageID: "assistant-1",
            toolCalls: [ToolCall(
                name: "read_file", preview: nil, args: nil,
                duration: 1.24, isCompleted: true
            )]
        )

        XCTAssertEqual(ToolActivityGroupPresentation.title(for: group), "Read file")
        XCTAssertEqual(ToolActivityGroupPresentation.icon(for: group), "book")
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

@MainActor
final class TranscriptActivityDisclosureLayoutTests: XCTestCase {
    func testThinkingAndToolRowsShareCompactGeometry() {
        for size in [DynamicTypeSize.large, .accessibility1] {
            let thinking = rowHeight(status: nil, symbol: "ellipsis.bubble", title: "Thinking", dynamicTypeSize: size)
            let readFile = rowHeight(status: nil, symbol: "book", title: "Read file", dynamicTypeSize: size)
            let running = rowHeight(status: "Running", dynamicTypeSize: size)

            XCTAssertEqual(thinking, readFile, accuracy: 0.5)
            if size == .large {
                XCTAssertEqual(thinking, 34, accuracy: 0.5)
                XCTAssertEqual(thinking, running, accuracy: 0.5)
            } else {
                XCTAssertGreaterThanOrEqual(thinking, 44)
            }
        }
    }

    func testRunningAndCompletedStatusKeepTheSameRowHeight() {
        for size in [DynamicTypeSize.large, .accessibility1] {
            let running = rowHeight(status: "Running", dynamicTypeSize: size)
            let completed = rowHeight(status: "Completed", dynamicTypeSize: size)
            let duration = rowHeight(status: "Worked for 1.2s", dynamicTypeSize: size)

            XCTAssertEqual(running, completed, accuracy: 0.5)
            XCTAssertEqual(running, duration, accuracy: 0.5)
            if size == .large {
                XCTAssertLessThan(running, 44, "Standard tool rows should remain visually compact.")
            } else {
                XCTAssertGreaterThanOrEqual(running, 44, "Accessibility text keeps a full-height row.")
            }
        }
    }

    private func rowHeight(
        status: String?, symbol: String = "book", title: String = "Read transcript",
        dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat {
        let row = TranscriptActivityDisclosureLabel(
            symbol: symbol,
            title: title,
            status: status,
            isExpanded: false,
            isCompact: true
        )
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        let host = UIHostingController(rootView: row)
        return host.sizeThatFits(in: CGSize(width: 330, height: 1_000)).height
    }

    func testSyntheticActivityStatesProduceReviewableScreenshots() throws {
        #if !DEBUG
        throw XCTSkip("The activity fixture uses the DEBUG disclosure hook.")
        #endif
        let toolKey = ChatTranscriptDisplaySettings.toolCardsStartExpandedKey
        let thinkingKey = ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey
        let previousToolValue = UserDefaults.standard.object(forKey: toolKey)
        let previousThinkingValue = UserDefaults.standard.object(forKey: thinkingKey)
        defer {
            restoreDefault(previousToolValue, forKey: toolKey)
            restoreDefault(previousThinkingValue, forKey: thinkingKey)
        }

        UserDefaults.standard.set(false, forKey: toolKey)
        UserDefaults.standard.set(false, forKey: thinkingKey)
        try captureActivityScreenshot(named: "Activity collapsed, dark")
        try captureActivityScreenshot(named: "Activity one action expanded, dark", expandSingle: true)
        try captureActivityScreenshot(named: "Activity three actions expanded, dark", expandMultiple: true)
    }

    private func captureActivityScreenshot(
        named name: String,
        expandSingle: Bool = false,
        expandMultiple: Bool = false
    ) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let singleViewport = PrototypeCodeViewport()
        let multipleViewport = PrototypeCodeViewport()
        #if DEBUG
        singleViewport.forceExpandTool = expandSingle
        multipleViewport.forceExpandTool = expandMultiple
        #endif
        let root = VStack(alignment: .leading, spacing: 14) {
            ReasoningBlockView(text: "Checking the relevant evidence.", isActive: true)
            ToolActivityGroupView(group: ToolCallGroup(
                anchorMessageID: "synthetic-active",
                toolCalls: [ToolCall(
                    name: "search_files", preview: nil,
                    args: ["query": .string("synthetic example")], isCompleted: false
                )]
            ))
            .environment(\.prototypeCodeViewport, singleViewport)
            ToolActivityGroupView(group: ToolCallGroup(
                anchorMessageID: "synthetic-complete",
                toolCalls: [
                    ToolCall(
                        name: "terminal", preview: "Synthetic command output",
                        args: ["command": .string("pwd")], isCompleted: true
                    ),
                    ToolCall(
                        name: "read_file", preview: "Synthetic note content",
                        args: ["path": .string("fixtures/example.md")], isCompleted: true
                    ),
                    ToolCall(
                        name: "web_search", preview: "Two synthetic results",
                        args: ["query": .string("synthetic example")], isCompleted: true
                    )
                ]
            ))
            .environment(\.prototypeCodeViewport, multipleViewport)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(screenshot.size.width, 0)
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func restoreDefault(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
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
