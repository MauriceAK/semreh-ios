import XCTest
import SwiftUI
import UIKit
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
            let thinking = rowHeight(status: nil, title: "Thinking", dynamicTypeSize: size)
            let readFile = rowHeight(status: nil, title: "Read file", dynamicTypeSize: size)
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
        status: String?, title: String = "Read transcript",
        dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat {
        let row = TranscriptActivityDisclosureLabel(
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
    @MainActor
    func testMountedChunkObservesCanonicalByteReplacementBeforeNextAppend() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let model = ByteExactStreamingChunkModel()
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: ByteExactStreamingChunkRoot(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
        }
        let composed = "é paragraph.\n\npending"
        let decomposed = "e\u{301} paragraph.\n\npending"
        XCTAssertEqual(composed, decomposed)
        XCTAssertFalse(composed.utf8.elementsEqual(decomposed.utf8))
        for content in [composed, decomposed, decomposed + "\n\nTail", composed, composed + " appended"] {
            let prior = model.observations
            model.content = content
            let deadline = CACurrentMediaTime() + 2
            repeat {
                try await Task.sleep(for: .milliseconds(20))
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
            } while (!model.observed.utf8.elementsEqual(content.utf8) || model.observations <= prior)
                && CACurrentMediaTime() < deadline
            XCTAssertGreaterThan(model.observations, prior, "The actual mounted chunk must observe this revision")
            XCTAssertTrue(model.observed.utf8.elementsEqual(content.utf8), "Stored segments must match exact source bytes")
        }
    }


    func testLongPendingParagraphAppendsMatchReferenceAtEveryUpdate() {
        assertAppendsMatchReference(
            ["Completed paragraph.\n\n"]
                + Array(repeating: String(repeating: "long prose 👩🏽‍💻 ", count: 80), count: 32)
                + ["\n", "\n", "Next paragraph", "\n\n", "Tail"]
        )
    }

    func testLongOpenFenceLineAppendsMatchReferenceAtEveryUpdate() {
        assertAppendsMatchReference(
            ["Introduction\n\n```swift\n"]
                + Array(repeating: String(repeating: "let value = 42; ", count: 100), count: 32)
                + ["\n", "```", "\n", "Tail", "\n\n", "More"]
        )
    }

    func testUnicodeScalarAppendsMatchReferenceAcrossExtendedGraphemes() {
        let text = "# e\u{301}\n\n👩🏽‍💻 family 👩‍👩‍👧‍👦\r\n"
            + "```\nvalue e\u{301} 👩🏽‍💻\n```\n\u{301}\n\nTail"
        assertAppendsMatchReference(text.unicodeScalars.map { String($0) })
    }

    func testSplitCRLFAppendsPreserveReferenceCharacterSemantics() {
        assertAppendsMatchReference([
            "# Heading", "\r", "\n", "body", "\r", "\n",
            "\n", "\n", "```", "\r", "\n", "value",
            "\n", "```", "\r", "\n", "tail", "\n", "\n", "More"
        ])
    }

    func testTerminalLFAndProvisionalBlankBoundariesMatchReference() {
        assertAppendsMatchReference([
            "\n", "", "\n", "# Heading", "\n", "", "\u{301}",
            "\n", "\n", "", "Paragraph", "\n", " ", "\n", "",
            "Tail", "\n```\nvalue\n```", "", "\n", "", "Next"
        ])
    }

    func testLongPendingLineNoChangeShrinkReplacementAndResetMatchReference() {
        var accumulator = StreamingMarkdownBlockAccumulator()
        let long = "Sealed.\n\n" + String(repeating: "pending 👩🏽‍💻 ", count: 2_000)
        for text in [long, long, "Short", "Short\n\nTail"] {
            assertMatchesReference(accumulator.update(text, appendOnly: true), text: text)
        }
        let replacement = "# Replacement\n" + String(repeating: "x", count: 40_000)
        assertMatchesReference(accumulator.update(replacement, appendOnly: false), text: replacement)
        accumulator.reset()
        assertMatchesReference(accumulator.update("\n\nNew", appendOnly: true), text: "\n\nNew")
        assertMatchesReference(accumulator.update("", appendOnly: true), text: "")

        // Mirror the renderer gate: canonical equality must not reuse byte offsets.
        let composed = "# é\n\n" + String(repeating: "pending", count: 1_000)
        let decomposed = "# e\u{301}\n\n" + String(repeating: "pending", count: 1_000)
        assertMatchesReference(accumulator.update(composed, appendOnly: false), text: composed)
        XCTAssertTrue(decomposed.hasPrefix(composed))
        let appendOnly = decomposed.utf8.starts(with: composed.utf8)
        XCTAssertFalse(appendOnly)
        assertMatchesReference(accumulator.update(decomposed, appendOnly: appendOnly), text: decomposed)
        let extended = decomposed + "\n\nTail"
        assertMatchesReference(accumulator.update(extended, appendOnly: true), text: extended)
    }

    private func assertAppendsMatchReference(
        _ appends: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        var accumulator = StreamingMarkdownBlockAccumulator()
        var text = ""
        for append in appends {
            text += append
            assertMatchesReference(
                accumulator.update(text, appendOnly: true), text: text, file: file, line: line
            )
        }
    }

    private func assertMatchesReference(
        _ actual: StreamingMarkdownBlockSegments, text: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = StreamingMarkdownBlockSplitter.split(text)
        XCTAssertEqual(actual, expected, file: file, line: line)
        XCTAssertEqual(
            actual.stableChunks.map { Array($0.text.utf8) },
            expected.stableChunks.map { Array($0.text.utf8) }, file: file, line: line
        )
        XCTAssertEqual(Array(actual.activeMarkdown.utf8), Array(expected.activeMarkdown.utf8), file: file, line: line)
    }

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


@MainActor
private final class ByteExactStreamingChunkModel: ObservableObject {
    @Published var content = ""
    var observed = ""
    var observations = 0
}

private struct ByteExactStreamingChunkRoot: View {
    @ObservedObject var model: ByteExactStreamingChunkModel

    var body: some View {
        StreamingMarkdownChunkedView(content: model.content, colorScheme: .light) { _, segments in
            model.observed = segments.stableChunks.map(\.text).joined() + segments.activeMarkdown
            model.observations += 1
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

    func testProposedWidthExperimentSkipsOnlyUnusedIdealMeasurement() {
        for proposed: CGFloat in [0, 40, 96, 150, 260, 999, .infinity] {
            var baselineProposals: [ProposedViewSize] = []
            var candidateProposals: [ProposedViewSize] = []
            func measure(_ proposal: ProposedViewSize) -> CGSize {
                // A long cell grows vertically when its column narrows.
                CGSize(width: proposal.width ?? 1_200,
                       height: ceil(1_200 / (proposal.width ?? 1_200)) * 20)
            }
            let baseline = TableCellWidthCap.measuredSize(
                proposedWidth: proposed, minWidth: minWidth, maxWidth: maxWidth,
                skipsRedundantIdealMeasurement: false
            ) { baselineProposals.append($0); return measure($0) }
            let candidate = TableCellWidthCap.measuredSize(
                proposedWidth: proposed, minWidth: minWidth, maxWidth: maxWidth,
                skipsRedundantIdealMeasurement: true
            ) { candidateProposals.append($0); return measure($0) }
            XCTAssertEqual(candidate, baseline)
            XCTAssertEqual(baselineProposals.count, 2)
            XCTAssertNil(baselineProposals.first?.width)
            XCTAssertEqual(candidateProposals.count, 1)
            XCTAssertEqual(candidateProposals.first?.width, candidate.width)
            XCTAssertNil(candidateProposals.first?.height)
        }
    }

    func testUnspecifiedWidthExperimentRetainsIdealAndWrappedHeightMeasurements() {
        for ideal: CGFloat in [40, 150, 1_200] {
            var proposals: [ProposedViewSize] = []
            let size = TableCellWidthCap.measuredSize(
                proposedWidth: nil, minWidth: minWidth, maxWidth: maxWidth,
                skipsRedundantIdealMeasurement: true
            ) {
                proposals.append($0)
                return CGSize(width: $0.width ?? ideal, height: $0.width == nil ? 20 : 80)
            }
            XCTAssertEqual(proposals.count, 2)
            XCTAssertNil(proposals.first?.width)
            XCTAssertEqual(proposals.last?.width, min(max(ideal, minWidth), maxWidth))
            XCTAssertNil(proposals.last?.height)
            XCTAssertEqual(size.height, 80)
        }
    }

    func testProposedWidthExperimentRemeasuresChangedContentAndWidth() {
        var calls = 0
        for (width, height): (CGFloat, CGFloat) in [(200, 40), (200, 100), (120, 180)] {
            let size = TableCellWidthCap.measuredSize(
                proposedWidth: width, minWidth: minWidth, maxWidth: maxWidth,
                skipsRedundantIdealMeasurement: true
            ) {
                calls += 1
                XCTAssertEqual($0.width, width)
                return CGSize(width: width, height: height)
            }
            XCTAssertEqual(size, CGSize(width: width, height: height))
        }
        XCTAssertEqual(calls, 3)
    }
}

final class StreamingLiteralProjectionTests: XCTestCase {
    func testHundredKilobyteParagraphKeepsLeavesBoundedAndEveryByte() {
        let source = String(repeating: "A long paragraph keeps growing without a newline. ", count: 2_100)
        XCTAssertGreaterThan(source.utf8.count, 100_000)
        var state = StreamingLiteralAccumulator()
        var previous: [StreamingMarkdownChunk] = []
        for length in stride(from: 1_013, to: source.utf8.count, by: 1_013) {
            let next = String(decoding: source.utf8.prefix(length), as: UTF8.self)
            state.update(next)
            XCTAssertEqual(Array(state.stableChunks.prefix(previous.count)), previous)
            XCTAssertTrue(state.stableChunks.allSatisfy { $0.text.count <= StreamingMarkdownRenderBudget.literalLeafCharacters })
            XCTAssertLessThanOrEqual(state.tail.count, StreamingMarkdownRenderBudget.literalLeafCharacters)
            XCTAssertEqual(Array((state.stableChunks.map(\.text).joined() + state.tail).utf8), Array(next.utf8))
            previous = state.stableChunks
        }
        state.update(source)
        XCTAssertEqual(state.appendedUTF8Bytes, source.utf8.count, "Only new suffix bytes enter the projection")
        XCTAssertEqual(Array((state.stableChunks.map(\.text).joined() + state.tail).utf8), Array(source.utf8))
    }

    func testCombiningAndZWJArrivalsCannotChangeSealedLeaf() {
        var state = StreamingLiteralAccumulator()
        let prefix = String(repeating: "a", count: StreamingMarkdownRenderBudget.literalLeafCharacters)
        var source = prefix + "e"
        state.update(source)
        let stable = state.stableChunks
        for addition in ["\u{301}", " 👩", "🏽", "\u{200D}", "💻", "\r", "\n"] {
            source += addition
            state.update(source)
            XCTAssertEqual(state.stableChunks, stable)
            XCTAssertEqual(Array((state.stableChunks.map(\.text).joined() + state.tail).utf8), Array(source.utf8))
        }
    }

    func testCanonicalReplacementAndShrinkResetLiteralProjection() {
        var state = StreamingLiteralAccumulator()
        state.update(String(repeating: "old ", count: 1_000))
        state.update("caf\u{e9}")
        state.update("cafe\u{301}")
        XCTAssertTrue(state.stableChunks.isEmpty)
        XCTAssertEqual(Array(state.tail.utf8), Array("cafe\u{301}".utf8))
        state.update("")
        XCTAssertEqual(state.source, "")
        XCTAssertEqual(state.tail, "")
    }

    func testRichTailBudgetUsesBytesAndBoundsHugeOpenFence() {
        XCTAssertFalse(StreamingMarkdownRenderBudget.usesLiteralTail(String(repeating: "a", count: 4_096)))
        XCTAssertTrue(StreamingMarkdownRenderBudget.usesLiteralTail(String(repeating: "a", count: 4_097)))
        XCTAssertTrue(StreamingMarkdownRenderBudget.usesLiteralTail(String(repeating: "👩🏽‍💻", count: 300)))
        let fence = "```swift\n" + String(repeating: "let value = 42\n", count: 8_000)
        var state = StreamingMarkdownBlockAccumulator(preservesRawMath: true)
        let result = state.update(fence, appendOnly: false)
        XCTAssertTrue(result.stableChunks.isEmpty)
        XCTAssertTrue(StreamingMarkdownRenderBudget.usesLiteralTail(result.activeMarkdown))
        XCTAssertEqual(Array(result.activeMarkdown.utf8), Array(fence.utf8))
    }

    func testRawMathProtectionKeepsMultilineMathTogetherAndPreservesWhitespace() {
        var state = StreamingMarkdownBlockAccumulator(preservesRawMath: true)
        let first = "\n\nIntroduction.\n\n$$\nx + y\n\n"
        _ = state.update(first, appendOnly: false)
        let final = first + "z\n$$\n\nFinal words"
        let result = state.update(final, appendOnly: true)
        XCTAssertTrue(result.activeMarkdown.contains("$$\nx + y\n\nz\n$$"))
        XCTAssertEqual(Array((result.stableChunks.map(\.text).joined() + result.activeMarkdown).utf8), Array(final.utf8))
    }
}

@MainActor
final class StreamingRawWhitespaceLayoutTests: XCTestCase {
    func testRawLeadingAndInterblockWhitespaceDoesNotAddPlaceholderRows() {
        func height(_ source: String) -> CGFloat {
            let host = UIHostingController(rootView:
                StreamingMarkdownRenderer(content: source)
                    .frame(width: 320, alignment: .leading))
            host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 2_000)
            host.view.layoutIfNeeded()
            return host.sizeThatFits(in: CGSize(width: 320, height: 10_000)).height
        }
        let compact = "# Heading\nParagraph being streamed."
        let spaced = "\n\n# Heading\n\n\nParagraph being streamed."
        XCTAssertGreaterThan(height(compact), 0)
        XCTAssertEqual(height(spaced), height(compact), accuracy: 0.5,
                       "Raw blank chunks must not mount MarkdownRenderer's placeholder Text rows")
    }
}

extension StreamingLiteralProjectionTests {
    func testOrdinaryWordsStayWholeAtLeafBoundaryWithoutLosingSeparators() {
        let source = String(repeating: "a ", count: 510) + "their eyes stay on these words "
            + String(repeating: "more words café 👩🏽‍💻 العربية ", count: 150)
        var state = StreamingLiteralAccumulator()
        state.update(source)
        XCTAssertEqual(state.stableChunks.first?.text, String(repeating: "a ", count: 510))
        XCTAssertTrue(state.stableChunks.allSatisfy { $0.text.last?.isWhitespace == true })
        XCTAssertTrue(state.stableChunks.allSatisfy { $0.text.count <= StreamingMarkdownRenderBudget.literalLeafCharacters })
        XCTAssertEqual(Array((state.stableChunks.map(\.text).joined() + state.tail).utf8), Array(source.utf8))
        let sealed = state.stableChunks
        state.update(source + " fresh append")
        XCTAssertEqual(Array(state.stableChunks.prefix(sealed.count)), sealed)
    }

    func testNearbyCRLFBoundaryIsRetainedOnceWithoutExtraDisplayedNewline() {
        let firstLine = String(repeating: "word ", count: 180)
        let source = firstLine + "\r\n" + String(repeating: "next ", count: 80)
        var state = StreamingLiteralAccumulator()
        state.update(source)
        let first = state.stableChunks.first?.text ?? ""
        XCTAssertEqual(Array(first.utf8), Array((firstLine + "\r\n").utf8))
        XCTAssertEqual(StreamingLiteralAccumulator.displayText(forSealedLeaf: first), firstLine)
        XCTAssertEqual(StreamingLiteralAccumulator.displayText(forSealedLeaf: "one\n\n"), "one\n",
                       "Only the separator supplied by VStack is omitted; intentional blank lines remain")
        XCTAssertEqual(Array((state.stableChunks.map(\.text).joined() + state.tail).utf8), Array(source.utf8))
    }

    func testWhitespaceFreeOverlongTokenUsesBoundedGraphemeFallback() {
        let source = String(repeating: "👩🏽‍💻", count: 2_049)
        var state = StreamingLiteralAccumulator()
        state.update(source)
        XCTAssertEqual(state.stableChunks.map { $0.text.count }, [1_024, 1_024])
        XCTAssertEqual(state.tail.count, 1)
        XCTAssertEqual(Array((state.stableChunks.map(\.text).joined() + state.tail).utf8), Array(source.utf8))
    }
}

extension StreamingRawWhitespaceLayoutTests {
    func testSealedCRLFBoundaryDoesNotAddAnotherVisualBlankLine() {
        let source = String(repeating: "word ", count: 180) + "\r\n" + String(repeating: "next ", count: 80)
        var state = StreamingLiteralAccumulator()
        state.update(source)
        let whole = UIHostingController(rootView: Text(verbatim: source).font(AppFont.body()))
        let split = UIHostingController(rootView: VStack(alignment: .leading, spacing: 0) {
            ForEach(state.stableChunks) { chunk in
                Text(verbatim: StreamingLiteralAccumulator.displayText(forSealedLeaf: chunk.text)).font(AppFont.body())
            }
            Text(verbatim: state.tail).font(AppFont.body())
        })
        let proposal = CGSize(width: 320, height: 10_000)
        XCTAssertEqual(split.sizeThatFits(in: proposal).height, whole.sizeThatFits(in: proposal).height, accuracy: 2,
                       "A leaf separator already supplies the source CRLF; it must not insert a second blank line")
    }
}
