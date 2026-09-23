import Highlightr
import MarkdownUI
import OSLog
import Splash
import SwiftUI
import UIKit

/// Paragraph-leading style for markdown bodies. `.standard` matches the chat
/// transcript; `.thinking` is the expanded-Thinking reading variant and is
/// driven by `AppFont.thinkingBodyLineSpacingMultiplier` (single taste knob).
private enum MarkdownBodyStyle {
    case standard
    case thinking

    var paragraphLeadingEm: CGFloat {
        switch self {
        case .standard:
            return Self.standardParagraphLeadingEm
        case .thinking:
            return Self.standardParagraphLeadingEm * AppFont.thinkingBodyLineSpacingMultiplier
        }
    }

    private static let standardParagraphLeadingEm: CGFloat = 0.18
}

private struct MarkdownBodyStyleEnvironmentKey: EnvironmentKey {
    static let defaultValue: MarkdownBodyStyle = .standard
}

private extension EnvironmentValues {
    var markdownBodyStyle: MarkdownBodyStyle {
        get { self[MarkdownBodyStyleEnvironmentKey.self] }
        set { self[MarkdownBodyStyleEnvironmentKey.self] = newValue }
    }
}

struct MarkdownRenderer: View {
    let content: String
    let isStreaming: Bool
    /// Renders through the expanded-Thinking paragraph rhythm when true.
    let isThinkingBody: Bool

    @Environment(\.colorScheme) private var colorScheme

    init(content: String, isStreaming: Bool = false, isThinkingBody: Bool = false) {
        self.content = content
        self.isStreaming = isStreaming
        self.isThinkingBody = isThinkingBody
    }

    /// Keeps the streaming renderer mounted briefly after streaming ends so
    /// the trailing text opacity reveal can finish before switching to the
    /// solid static renderer.
    @State private var lingersAfterStreaming = false
#if DEBUG
    @Environment(\.prototypeCodeViewport) private var nativeRichViewport
#endif

    var body: some View {
        Group {
            if isStreaming || lingersAfterStreaming {
                StreamingMarkdownRenderer(content: content)
            } else if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: " ")
            } else if let fallbackReason = MarkdownContentRenderingPolicy.fallbackReason(for: content) {
                PlainMarkdownFallbackView(
                    content: content,
                    reason: fallbackReason
                )
            } else {
#if DEBUG
                if (ProcessInfo.processInfo.arguments.contains("--native-rich-row-prototype")
                    || ProcessInfo.processInfo.arguments.contains("--native-rich-20-row-pilot")
                    || ProcessInfo.processInfo.arguments.contains("--native-rich-all-eligible-120")),
                   content.hasPrefix("## Response "), !isThinkingBody,
                   let snapshot = nativeRichViewport?.nativeRichSnapshot,
                   snapshot.sourceBytes == Array(content.utf8) {
                    NativeRichRowMountedView(snapshot: snapshot,
                                             onToggleCodeWrap: { nativeRichViewport?.nativeRichToggleCodeWrap?() })
                        .accessibilityIdentifier("native-rich-row-mounted")
                } else {
                    markdownContent
                }
#else
                markdownContent
#endif
            }
        }
        .environment(\.markdownBodyStyle, isThinkingBody ? .thinking : .standard)
        .onChange(of: isStreaming) { wasStreaming, nowStreaming in
            if wasStreaming, !nowStreaming {
                lingersAfterStreaming = true
            }
        }
        .task(id: isStreaming) {
            guard !isStreaming else { return }
            try? await Task.sleep(for: .seconds(StreamingTrailingContentReveal.pauseDelay))
            guard !Task.isCancelled else { return }
            lingersAfterStreaming = false
        }
    }


    @ViewBuilder
    private var markdownContent: some View {
        let segments = MarkdownMathSegmenter.segments(in: content)

        if segments.containsMath {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let markdown):
                        if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ChatMarkdownView(
                                content: markdown,
                                colorScheme: colorScheme,
                                isStreaming: isStreaming
                            )
                        }
                    case .displayMath(let latex):
                        DisplayMathView(latex: latex)
                    }
                }
            }
            .textSelection(.enabled)
        } else {
            ChatMarkdownView(
                content: MarkdownMathFormatter.replacingInlineMath(in: content),
                colorScheme: colorScheme,
                isStreaming: isStreaming
            )
            .textSelection(.enabled)
        }
    }
}

struct StreamingMarkdownRenderer: View {
    let content: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var displayedContent: String

    init(content: String) {
        self.content = content
        _displayedContent = State(initialValue: content)
    }

    var body: some View {
        Group {
            if displayedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: " ")
            } else if let fallbackReason = MarkdownContentRenderingPolicy.fallbackReason(for: displayedContent) {
                PlainMarkdownFallbackView(
                    content: displayedContent,
                    reason: fallbackReason
                )
            } else {
                streamingMarkdownContent
            }
        }
        .task(id: content) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard displayedContent != content else { return }
            displayedContent = content
        }
    }

    @ViewBuilder
    private var streamingMarkdownContent: some View {
        let segments = MarkdownMathSegmenter.segments(in: displayedContent)

        if segments.containsMath {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let markdown):
                        if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            StreamingMarkdownChunkedView(
                                content: markdown,
                                colorScheme: colorScheme
                            )
                        }
                    case .displayMath(let latex):
                        DisplayMathView(latex: latex)
                    }
                }
            }
        } else {
            StreamingMarkdownChunkedView(
                content: MarkdownMathFormatter.replacingInlineMath(in: displayedContent),
                colorScheme: colorScheme
            )
        }
    }

}

private struct StreamingMarkdownChunkedView: View {
    let content: String
    let colorScheme: ColorScheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(StreamedTextAnimationSettings.isEnabledKey) private var isStreamedTextAnimationEnabled = true

    /// First block ordinal still in the fade window. Starts at `Int.max`
    /// (everything solid) until `onAppear` anchors it at the current block,
    /// so text already on screen when the view mounts never fades.
    @State private var firstFadeOrdinal = Int.max
    /// Ordinal of the current block at mount; only blocks created after it
    /// arm their stores (pre-existing blocks take the solid baseline).
    @State private var mountBoundaryCount = Int.max
    @State private var lastBoundaryCount = 0
    @State private var lastTouchedAt: [Int: TimeInterval] = [:]
    @State private var fadesActive = false
    /// One reveal cursor for all fade blocks of this view, so consecutive
    /// blocks (paragraphs, list items) appear in reading order even when a
    /// fast stream backlogs a block's queue toward `maxStampLead`.
    @State private var chain = StreamingTextFadeStampChain()
    @State private var blockAccumulator = StreamingMarkdownBlockAccumulator()
    @State private var blockSegments = StreamingMarkdownBlockSegments(
        stableChunks: [],
        activeMarkdown: ""
    )

    init(content: String, colorScheme: ColorScheme) {
        self.content = content
        self.colorScheme = colorScheme
        var accumulator = StreamingMarkdownBlockAccumulator()
        let initialSegments = accumulator.update(content, appendOnly: false)
        _blockAccumulator = State(initialValue: accumulator)
        _blockSegments = State(initialValue: initialSegments)
    }

    var body: some View {
        let blockSplit = StreamingTextFadeTailSplitter.split(
            blockSegments.activeMarkdown,
            firstFadeOrdinal: StreamedTextAnimationSettings.effectiveFirstFadeOrdinal(
                firstFadeOrdinal,
                reduceMotion: reduceMotion,
                isEnabled: isStreamedTextAnimationEnabled
            )
        )

        VStack(alignment: .leading, spacing: 0) {
            ForEach(blockSegments.stableChunks) { chunk in
                ChatMarkdownView(
                    content: chunk.text,
                    colorScheme: colorScheme,
                    isStreaming: false
                )
                .equatable()
            }

            if !blockSplit.head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ChatMarkdownView(
                    content: blockSplit.head,
                    colorScheme: colorScheme,
                    isStreaming: true
                )
            }

            if !blockSplit.blocks.isEmpty {
                // One shared frame clock for every fade block. Per frame only
                // the renderer's clock input changes; each block's markdown
                // inputs are untouched, so their bodies (and text layout) are
                // not re-evaluated.
                TimelineView(.animation(minimumInterval: nil, paused: !fadesActive)) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(blockSplit.blocks, id: \.ordinal) { block in
                            StreamingFadeBlockView(
                                text: block.text,
                                colorScheme: colorScheme,
                                fadeEnabled: block.fadeEnabled,
                                armOnAppear: block.ordinal > mountBoundaryCount,
                                clock: context.date.timeIntervalSinceReferenceDate,
                                chain: chain
                            )
                        }
                    }
                }
            }
        }
        .onAppear {
            anchorFadeWindowAtCurrentBlock()
        }
        .onChange(of: content) { oldContent, newContent in
            let activeWindow = updateBlockSegments(
                newContent,
                appendOnly: newContent.hasPrefix(oldContent)
            )
            advanceFadeWindow(from: activeWindow.old, to: activeWindow.new)
        }
        .onChange(of: isStreamedTextAnimationEnabled) { _, isEnabled in
            if isEnabled {
                anchorFadeWindowAtCurrentBlock()
            }
        }
        .onChange(of: reduceMotion) { _, reduceMotion in
            if !reduceMotion {
                anchorFadeWindowAtCurrentBlock()
            }
        }
        .task(id: content) {
            // Let queued reveals and the newest fade finish, then pause frame
            // updates until more content arrives (e.g. the stream stalls on
            // tool use). A new change cancels this task and restarts it.
            try? await Task.sleep(for: .seconds(StreamingTrailingContentReveal.pauseDelay))
            guard !Task.isCancelled else { return }
            fadesActive = false
        }
    }

    /// Anchors the fade window at the current block: everything visible now
    /// takes the solid baseline, only text streamed afterwards fades. Used at
    /// mount, and again whenever fading becomes active mid-stream (animation
    /// setting flipped on, Reduce Motion turned off) — the window bookkeeping
    /// keeps advancing while fades route to the head, so without re-anchoring
    /// the reopened window would arm blocks the user is already reading and
    /// visibly re-fade them.
    private func anchorFadeWindowAtCurrentBlock() {
        let split = StreamingTextFadeTailSplitter.split(blockSegments.activeMarkdown, firstFadeOrdinal: 0)
        firstFadeOrdinal = split.boundaryCount
        mountBoundaryCount = split.boundaryCount
        lastBoundaryCount = split.boundaryCount
        lastTouchedAt = [:]
    }

    private func updateBlockSegments(
        _ newContent: String,
        appendOnly: Bool
    ) -> (old: String, new: String) {
        let oldActive = blockSegments.activeMarkdown
        blockSegments = blockAccumulator.update(newContent, appendOnly: appendOnly)
        return (oldActive, blockSegments.activeMarkdown)
    }

    private func advanceFadeWindow(from oldActive: String, to newActive: String) {
        let now = Date().timeIntervalSinceReferenceDate
        let split = StreamingTextFadeTailSplitter.split(newActive, firstFadeOrdinal: firstFadeOrdinal)

        if !newActive.hasPrefix(oldActive) {
            // Replaced content or a sealed stable chunk shifted the active
            // window: ordinals no longer line up, so restart the fade window
            // at the current block (renders solid, then new text fades).
            lastTouchedAt = [:]
            firstFadeOrdinal = split.boundaryCount
            lastBoundaryCount = split.boundaryCount
            chain.reset()
            fadesActive = true
            return
        }

        // Only the current block and any blocks newly created by this append
        // were touched; everything earlier is frozen text aging toward
        // absorption. min() also covers an item boundary vanishing when its
        // nested child arrives (the merged block is current again).
        for block in split.blocks where block.ordinal >= min(lastBoundaryCount, split.boundaryCount) {
            lastTouchedAt[block.ordinal] = now
        }
        lastBoundaryCount = split.boundaryCount

        firstFadeOrdinal = StreamingTextFadeWindow.advanceStart(
            current: min(firstFadeOrdinal, split.boundaryCount),
            boundaryCount: split.boundaryCount,
            lastTouchedAt: lastTouchedAt,
            now: now
        )
        lastTouchedAt = lastTouchedAt.filter { $0.key >= firstFadeOrdinal }
        fadesActive = true
    }
}

/// One block of the streaming tail, drawn through a short opacity-only text
/// renderer with its own stamp store so neighbouring blocks' character offsets
/// never collide. Newly appended glyphs appear at their final layout positions
/// and fade together; they are not queued behind a per-token delay.
private struct StreamingFadeBlockView: View {
    let text: String
    let colorScheme: ColorScheme
    let fadeEnabled: Bool
    let armOnAppear: Bool
    let clock: TimeInterval

    @State private var store: StreamingTextFadeStampStore<Text.Layout.CharacterIndex>

    init(
        text: String,
        colorScheme: ColorScheme,
        fadeEnabled: Bool,
        armOnAppear: Bool,
        clock: TimeInterval,
        chain: StreamingTextFadeStampChain
    ) {
        self.text = text
        self.colorScheme = colorScheme
        self.fadeEnabled = fadeEnabled
        self.armOnAppear = armOnAppear
        self.clock = clock
        let store = StreamingTextFadeStampStore<Text.Layout.CharacterIndex>(chain: chain)
        if armOnAppear {
            store.rolloverReset()
        }
        _store = State(initialValue: store)
    }

    var body: some View {
        Group {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if fadeEnabled {
                    ChatMarkdownView(
                        content: text,
                        colorScheme: colorScheme,
                        isStreaming: true
                    )
                    .textRenderer(StreamingTrailingContentOpacityRenderer(clock: clock, store: store))
                } else {
                    ChatMarkdownView(
                        content: text,
                        colorScheme: colorScheme,
                        isStreaming: true
                    )
                }
            }
        }
    }
}

private enum StreamingTrailingContentReveal {
    static let duration: TimeInterval = 0.16
    static let pauseDelay = duration + 0.1
}

/// A layout-neutral fade for just-arrived trailing glyphs. A zero-stagger,
/// zero-lead stamp registers each renderer update immediately, so text stays
/// in reading order and fades over 160ms without waiting behind a token queue.
private struct StreamingTrailingContentOpacityRenderer: TextRenderer {
    let clock: TimeInterval
    let store: StreamingTextFadeStampStore<Text.Layout.CharacterIndex>

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var orderedKeys: [Text.Layout.CharacterIndex] = []
        for line in layout {
            for run in line {
                for slice in run {
                    if let key = slice.characterIndices.max() {
                        orderedKeys.append(key)
                    }
                }
            }
        }

        store.register(orderedKeys, clock: clock, glyphStagger: 0, maxStampLead: 0)

        for line in layout {
            for run in line {
                for slice in run {
                    let opacity = store.opacity(
                        for: slice.characterIndices.max(),
                        clock: clock,
                        fadeDuration: StreamingTrailingContentReveal.duration
                    )

                    if opacity >= 1 {
                        context.draw(slice)
                    } else if opacity > 0 {
                        var faded = context
                        faded.opacity = opacity
                        faded.draw(slice)
                    }
                }
            }
        }

        store.finishBaseline()
    }
}

private struct ChatMarkdownView: View, Equatable {
    let content: String
    let colorScheme: ColorScheme
    let isStreaming: Bool

    @Environment(\.markdownBodyStyle) private var markdownBodyStyle

    static func == (lhs: ChatMarkdownView, rhs: ChatMarkdownView) -> Bool {
        lhs.content == rhs.content
            && lhs.colorScheme == rhs.colorScheme
            && lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        Markdown(content)
            .markdownTheme(MarkdownUI.Theme.chat(colorScheme: colorScheme, isStreaming: isStreaming))
            .markdownTextStyle {
                ForegroundColor(.primary)
                BackgroundColor(nil)
            }
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                BackgroundColor(SwiftUI.Color(.tertiarySystemGroupedBackground))
            }
            .markdownCodeSyntaxHighlighter(.plainText)
            .markdownBlockStyle(\.paragraph) { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(markdownBodyStyle.paragraphLeadingEm))
                    .markdownMargin(top: 0, bottom: 8)
                    .prototypeMeasuredBlock("paragraph")
            }
    }
}

/// Routes a fenced code block to display-math rendering when its language is a
/// math language (`math`/`latex`/`tex`) and the body parses as math; otherwise
/// renders it as a normal syntax-highlighted code block. A math fence whose
/// body SwiftMath can't parse falls back to the code block too, so nothing is
/// lost.
private struct MathFenceOrCodeBlock: View {
    let language: String?
    let content: String
    let isStreaming: Bool

    var body: some View {
        if MathFenceLanguage.matches(language), MathLaTeX.isRenderable(content) {
            DisplayMathView(latex: content)
        } else {
            ChatCodeBlock(
                language: language,
                content: content,
                isStreaming: isStreaming
            )
        }
    }
}

private extension View {
    @ViewBuilder func prototypeMeasuredBlock(_ kind: String) -> some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--viewport-block-costs") {
            PrototypeTimedBlockLayout(kind: kind) { self }
        } else {
            self
        }
#else
        self
#endif
    }
}

#if DEBUG
/// Diagnostic-only pass-through layout. Unlike a standalone synthetic host,
/// this measures the actual child under the production Markdown proposal.
private struct PrototypeTimedBlockLayout: Layout {
    let kind: String
    private static let logger = Logger(subsystem: "com.maurice.semreh", category: "ViewportPrototype")

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let start = CACurrentMediaTime()
        let result = child.sizeThatFits(proposal)
        let milliseconds = (CACurrentMediaTime() - start) * 1_000
        if milliseconds >= 1 {
            Self.logger.debug("event=prototype_block_measure kind=\(kind, privacy: .public) elapsedMs=\(milliseconds, privacy: .public) width=\(proposal.width ?? -1, privacy: .public) height=\(result.height, privacy: .public)")
        }
        return result
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}
#endif

enum ChatCodeInlinePreviewPolicy {
    static let maximumVisibleLines = 32

    static func displaySource(for content: String) -> String {
        guard MarkdownHighlightPolicy.lineCount(in: content, stoppingAfter: maximumVisibleLines) > maximumVisibleLines else {
            return content
        }
        var completedLines = 0
        for index in content.indices where content[index].isNewline {
            completedLines += 1
            if completedLines == maximumVisibleLines {
                return String(content[...index])
            }
        }
        return content
    }
}

private struct ChatCodeBlock: View {
    let language: String?
    let content: String
    let isStreaming: Bool
    var allowsInlinePreview = true

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey) private var wrapsCodeBlockLines = false
    @State private var didCopy = false
    @State private var highlightedCode: MarkdownPreparedCode?
    @State private var showsFullCode = false
#if DEBUG
    @Environment(\.prototypeCodeViewport) private var prototypeViewport
    @Environment(\.nativePreparedHighlights) private var nativePreparedHighlights
#endif

    private let logger = Logger.hermesMarkdownRendering

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(displayLanguage)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button {
                    wrapsCodeBlockLines.toggle()
                } label: {
                    Image(systemName: wrapsCodeBlockLines ? "arrow.turn.down.left" : "arrow.left.and.right")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SwiftUI.Color.primary)
                .accessibilityLabel(wrapsCodeBlockLines ? "Disable code line wrapping" : "Enable code line wrapping")

                Button {
                    UIPasteboard.general.string = content
                    didCopy = true
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "square.on.square")
                        .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SwiftUI.Color.primary)
                .accessibilityLabel(didCopy ? "Copied code" : "Copy code")
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)

            if wrapsCodeBlockLines {
                styledCodeText(fixedHorizontal: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    styledCodeText(fixedHorizontal: true)
                }
            }

            if isInlinePreview {
                Button {
                    showsFullCode = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text("View full code (\(logicalLineCount) lines)")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("view-full-code")
            }
        }
        .background(codeBlockBackground)
#if DEBUG
        .modifier(NativeRefinementProbe(name: "code-\(content.count)-\(displayHighlightedCode == nil ? "plain" : "highlighted")"))
#endif
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(SwiftUI.Color(.separator).opacity(0.35), lineWidth: 1)
        }
        .onChange(of: content) { _, _ in
            didCopy = false
        }
        .task(id: highlightRequest) {
            await updateHighlightedCode(for: highlightRequest)
        }
        .sheet(isPresented: $showsFullCode) {
            FullCodeSheet(language: language, content: content)
        }
        // Code (and diff) blocks must never mirror inside an RTL message (#259):
        // the language header, copy/wrap controls, and the source itself stay LTR.
        .forcedLeftToRight()
    }

    private var codeBlockBackground: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 0.04, green: 0.05, blue: 0.07)
            : SwiftUI.Color(.secondarySystemBackground)
    }

    @ViewBuilder
    private var codeText: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--viewport-virtual-code"), let prototypeViewport {
            PrototypeVirtualCodeText(source: content, prepared: highlightedCode, wraps: wrapsCodeBlockLines, viewport: prototypeViewport)
        } else {
            originalCodeText
        }
#else
        originalCodeText
#endif
    }

    @ViewBuilder private var originalCodeText: some View {
        if let highlightedCode = displayHighlightedCode {
            HighlightedCodeBlockText(content: highlightedCode, wraps: wrapsCodeBlockLines)
        } else {
            PlainCodeBlockText(content: inlineCode, wraps: wrapsCodeBlockLines)
        }
    }

    private var logicalLineCount: Int {
        MarkdownHighlightPolicy.lineCount(in: content)
    }

    private var isInlinePreview: Bool {
        allowsInlinePreview && logicalLineCount > ChatCodeInlinePreviewPolicy.maximumVisibleLines
    }

    private var inlineCode: String {
        isInlinePreview ? ChatCodeInlinePreviewPolicy.displaySource(for: content) : content
    }

    private var displayHighlightedCode: MarkdownPreparedCode? {
#if DEBUG
        if let prepared = nativePreparedHighlights.first(where: { $0.request == highlightRequest }) { return prepared.code }
#endif
        return highlightedCode
    }

    /// The code body with its shared monospaced styling and padding. `fixedHorizontal`
    /// is `true` inside the horizontal `ScrollView` (each line keeps its natural width)
    /// and `false` when wrapping (lines reflow to the bubble width, growing vertically).
    private func styledCodeText(fixedHorizontal: Bool) -> some View {
        codeText
            .fixedSize(horizontal: fixedHorizontal, vertical: true)
            .relativeLineSpacing(.em(0.18))
            .markdownTextStyle {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.84))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
    }

    private var highlightRequest: MarkdownCodeHighlightRequest {
        MarkdownCodeHighlightRequest(
            code: inlineCode,
            language: language,
            colorScheme: colorScheme,
            isStreaming: isStreaming
        )
    }

    @MainActor
    private func updateHighlightedCode(for request: MarkdownCodeHighlightRequest) async {
#if DEBUG
        if nativePreparedHighlights.contains(where: { $0.request == request }) {
            Logger(subsystem: "com.maurice.semreh", category: "NativeBaseline").debug("event=highlight_prepared_hit")
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--viewport-virtual-code") {
            Logger(subsystem: "com.maurice.semreh", category: "ViewportPrototype").debug("event=virtual_code_gate hasViewport=\(self.prototypeViewport != nil, privacy: .public)")
        }
        if ProcessInfo.processInfo.arguments.contains("--tail-geometry-no-highlight") { return }
#endif
        highlightedCode = nil
        await Task.yield()

        guard !Task.isCancelled else { return }

        let result = await MarkdownCodeHighlightWorker.shared.highlightedCode(for: request)
        guard !Task.isCancelled else { return }

        switch result {
        case .highlighted(let attributedString):
            highlightedCode = attributedString
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-refinement-trace") {
                Logger(subsystem: "com.maurice.semreh", category: "NativeBaseline").debug("event=highlight_applied characters=\(request.code.count, privacy: .public)")
            }
#endif
        case .plain(let reason, let normalizedLanguage):
            highlightedCode = nil
            logFallback(
                reason: reason,
                normalizedLanguage: normalizedLanguage,
                code: request.code
            )
        }
    }

    private var displayLanguage: String {
        guard let name = normalizedLanguage else {
            return String(localized: "Code")
        }

        switch name {
        case "js":
            return "JavaScript"
        case "ts":
            return "TypeScript"
        case "py":
            return "Python"
        default:
            return name.uppercased() == name ? name : name.capitalized
        }
    }

    private var normalizedLanguage: String? {
        language?
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    private func logFallback(reason: MarkdownHighlightFallbackReason, normalizedLanguage: String?, code: String) {
        guard reason != .empty else { return }

        logger.info(
            "Syntax highlighting fallback reason=\(reason.rawValue, privacy: .public) languageCategory=\(MarkdownHighlightPolicy.languageLogCategory(for: normalizedLanguage), privacy: .public) characters=\(code.count, privacy: .public) lines=\(MarkdownHighlightPolicy.lineCount(in: code), privacy: .public)"
        )
    }
}

/// Very long code stays source-complete without making the transcript row itself
/// thousands of points tall. The separate native text view owns scrolling and
/// selection; highlighting only changes attributes, never its source or font.
private struct FullCodeSheet: View {
    let language: String?
    let content: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey) private var wrapsCodeBlockLines = false
    @State private var prepared: MarkdownPreparedCode?
    @State private var preparedRevision = 0

    var body: some View {
        NavigationStack {
            FullCodeTextView(
                source: content,
                prepared: prepared,
                preparedRevision: preparedRevision,
                wraps: wrapsCodeBlockLines,
                colorScheme: colorScheme
            )
            .accessibilityIdentifier("full-code-text")
            .navigationTitle(language?.capitalized ?? "Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        wrapsCodeBlockLines.toggle()
                    } label: {
                        Image(systemName: wrapsCodeBlockLines ? "arrow.turn.down.left" : "arrow.left.and.right")
                    }
                    .accessibilityLabel(wrapsCodeBlockLines ? "Disable code line wrapping" : "Enable code line wrapping")

                    Button {
                        UIPasteboard.general.string = content
                    } label: {
                        Image(systemName: "square.on.square")
                    }
                    .accessibilityLabel("Copy full code")
                }
            }
        }
        .task(id: highlightRequest) {
            prepared = nil
            preparedRevision &+= 1
            let result = await MarkdownCodeHighlightWorker.shared.highlightedCode(for: highlightRequest)
            guard !Task.isCancelled else { return }
            if case .highlighted(let value) = result {
                prepared = value
                preparedRevision &+= 1
            }
        }
    }

    private var highlightRequest: MarkdownCodeHighlightRequest {
        MarkdownCodeHighlightRequest(
            code: content,
            language: language,
            colorScheme: colorScheme,
            isStreaming: false
        )
    }
}

private struct FullCodeTextView: UIViewRepresentable {
    let source: String
    let prepared: MarkdownPreparedCode?
    let preparedRevision: Int
    let wraps: Bool
    let colorScheme: ColorScheme

    final class Coordinator {
        var source = ""
        var preparedRevision = -1
        var colorScheme: ColorScheme?
        var wraps: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = []
        view.semanticContentAttribute = .forceLeftToRight
        view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        view.accessibilityLabel = "Full code"
        view.accessibilityIdentifier = "full-code-text"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        let appearanceChanged = coordinator.colorScheme != colorScheme
        view.backgroundColor = colorScheme == .dark
            ? UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
            : .secondarySystemBackground

        if coordinator.source != source || coordinator.preparedRevision != preparedRevision || appearanceChanged {
            let priorOffset = view.contentOffset
            let priorSelection = view.selectedRange
            let monospacedFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            if let prepared, String(prepared.fullText.characters) == source {
                let attributed = NSMutableAttributedString(attributedString: NSAttributedString(prepared.fullText))
                attributed.addAttribute(.font, value: monospacedFont, range: NSRange(location: 0, length: attributed.length))
                view.attributedText = attributed
            } else {
                view.attributedText = NSAttributedString(
                    string: source,
                    attributes: [
                        .font: monospacedFont,
                        .foregroundColor: UIColor.label
                    ]
                )
            }
            view.selectedRange = NSRange(
                location: min(priorSelection.location, (source as NSString).length),
                length: min(priorSelection.length, max(0, (source as NSString).length - priorSelection.location))
            )
            if coordinator.source == source {
                view.contentOffset = priorOffset
            }
            coordinator.source = source
            coordinator.preparedRevision = preparedRevision
            coordinator.colorScheme = colorScheme
        }

        if coordinator.wraps != wraps {
            view.textContainer.widthTracksTextView = wraps
            if wraps {
                view.textContainer.size = CGSize(width: max(view.bounds.width, 1), height: .greatestFiniteMagnitude)
            } else {
                let longestLine = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    .map(\.utf16.count).max() ?? 0
                view.textContainer.size = CGSize(width: max(view.bounds.width, CGFloat(longestLine) * 8 + 32), height: .greatestFiniteMagnitude)
            }
            view.alwaysBounceHorizontal = !wraps
            view.showsHorizontalScrollIndicator = !wraps
            coordinator.wraps = wraps
        }
    }
}

private struct PlainCodeBlockText: View {
    let content: String
    /// When `true`, each line's 500-char segments are concatenated into a single
    /// `Text` so SwiftUI soft-wraps the line; when `false`, they stay side by side
    /// in an `HStack` for the horizontal-scroll layout.
    var wraps = false

    private var lines: [MarkdownPlainCodeLine] {
        MarkdownPlainCodeFormatter.lines(in: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines) { line in
                if wraps {
                    combinedText(for: line)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        ForEach(line.segments) { segment in
                            Text(verbatim: segment.text)
                        }
                    }
                }
            }
        }
        .font(.system(size: 13, weight: .regular, design: .monospaced))
        .foregroundStyle(.primary)
    }

    private func combinedText(for line: MarkdownPlainCodeLine) -> Text {
        line.segments.reduce(Text(verbatim: "")) { partial, segment in
            partial + Text(verbatim: segment.text)
        }
    }
}

#if DEBUG
actor PrototypeCodeGeometryWorker {
    static let shared = PrototypeCodeGeometryWorker()
    func sizes(_ lines: [MarkdownPreparedCode.Line], width: CGFloat?, scale: CGFloat) throws -> [CGSize] {
        try lines.map { line in
            try Task.checkCancellation()
            let text = NSMutableAttributedString(string: "")
            for segment in line.segments { text.append(NSAttributedString(segment.text)) }
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if value == nil { text.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: range) }
            }
            let size = text.boundingRect(with: CGSize(width: width ?? 100_000, height: 1_000_000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
            return CGSize(width: ceil(size.width * scale) / scale, height: max(1, ceil(size.height * scale) / scale))
        }
    }
}

@MainActor private final class PrototypeCodeLineModel: ObservableObject {
    @Published var revision = 0
    var lines: [MarkdownPreparedCode.Line] = []
    var positions: [CGFloat] = [0]
    var maxWidth: CGFloat = 1
    var origin: CGFloat = 0
    var width: CGFloat = 340
    var source = ""
    var prepared: MarkdownPreparedCode?
    var wraps = false
    var task: Task<Void, Never>?
    var sizesCache: [CGFloat: [CGSize]] = [:]
    var viewport: PrototypeCodeViewport
    var scale: CGFloat

    init(source: String, prepared: MarkdownPreparedCode?, wraps: Bool, viewport: PrototypeCodeViewport, scale: CGFloat) {
        self.viewport = viewport
        self.scale = scale
        update(source: source, prepared: prepared, wraps: wraps, force: true)
    }

    var height: CGFloat { max(1, (positions.last ?? 3) - 3) }
    func index(at value: CGFloat) -> Int {
        var low = 0, high = min(lines.count, max(0, positions.count - 1))
        while low + 1 < high {
            let middle = (low + high) / 2
            if positions[middle] <= value { low = middle } else { high = middle }
        }
        return low
    }

    func update(source: String, prepared: MarkdownPreparedCode?, wraps: Bool, force: Bool = false) {
        guard force || self.source != source || self.prepared != prepared || self.wraps != wraps else { return }
        let changedContent = self.source != source || self.prepared != prepared
        self.source = source; self.prepared = prepared; self.wraps = wraps
        if changedContent || force {
            lines = prepared?.lines ?? MarkdownPlainCodeFormatter.lines(in: source).map { line in
                MarkdownPreparedCode.Line(id: line.id, segments: line.segments.map { MarkdownPreparedCode.Segment(id: $0.id, text: AttributedString($0.text)) })
            }
            sizesCache.removeAll()
        }
        let estimatedLineHeight = ceil(UIFont.monospacedSystemFont(ofSize: 13, weight: .regular).lineHeight * scale) / scale
        let estimates = lines.map { line -> CGSize in
            let count = line.segments.reduce(0) { $0 + $1.text.characters.count }
            let naturalWidth = CGFloat(max(1, count)) * 13
            let visualLines = wraps ? max(1, ceil(naturalWidth / max(1, width))) : 1
            return CGSize(width: naturalWidth, height: estimatedLineHeight * visualLines)
        }
        apply(estimates, compensate: !force)
        measure()
    }

    func measure() {
        task?.cancel()
        let cacheKey: CGFloat = wraps ? width : -1
        if let cached = sizesCache[cacheKey] { apply(cached); return }
        let lines = lines, measuredWidth: CGFloat? = wraps ? width : nil, scale = scale
        task = Task { [weak self] in
            guard let sizes = try? await PrototypeCodeGeometryWorker.shared.sizes(lines, width: measuredWidth, scale: scale), !Task.isCancelled,
                  let self else { return }
            if self.sizesCache.count >= 2 { self.sizesCache.removeAll() }
            self.sizesCache[cacheKey] = sizes
            self.apply(sizes)
        }
    }

    func apply(_ sizes: [CGSize], compensate: Bool = true) {
        let localTop = viewport.rect.minY - origin
        let anchor = index(at: max(0, localTop))
        let oldPosition = positions.indices.contains(anchor) ? positions[anchor] : 0
        positions = [0]
        for size in sizes { positions.append(positions.last! + size.height + 3) }
        maxWidth = max(1, sizes.map(\.width).max() ?? 1)
        if compensate, localTop >= 0, positions.indices.contains(anchor) {
            viewport.correctAnchor(positions[anchor] - oldPosition)
        }
        revision += 1
    }

    deinit { task?.cancel() }
}

private struct PrototypeVirtualCodeText: View {
    let source: String
    let prepared: MarkdownPreparedCode?
    let wraps: Bool
    @ObservedObject var viewport: PrototypeCodeViewport
    @Environment(\.displayScale) private var displayScale
    @StateObject private var model: PrototypeCodeLineModel

    init(source: String, prepared: MarkdownPreparedCode?, wraps: Bool, viewport: PrototypeCodeViewport) {
        self.source = source; self.prepared = prepared; self.wraps = wraps; self.viewport = viewport
        _model = StateObject(wrappedValue: PrototypeCodeLineModel(source: source, prepared: prepared, wraps: wraps, viewport: viewport, scale: 3))
    }

    var body: some View {
        let _ = model.revision
        let top = viewport.rect.minY - model.origin
        let bottom = viewport.rect.maxY - model.origin
        let first = model.index(at: max(0, top - 100))
        let last = model.index(at: max(0, bottom + 100))
        ZStack(alignment: .topLeading) {
            if !model.lines.isEmpty, bottom >= -100, top <= model.height + 100 {
                ForEach(first...max(first, last), id: \.self) { index in
                    codeLine(model.lines[index])
                        .offset(y: model.positions[index])
                }
            }
        }
        .frame(width: wraps ? nil : model.maxWidth, height: model.height, alignment: .topLeading)
        .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
        .font(.system(size: 13, weight: .regular, design: .monospaced))
        .foregroundStyle(.primary)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("prototype-row")) } action: { frame in
            if abs(model.origin - frame.minY) > 0.5 { model.origin = frame.minY; model.revision += 1 }
            if wraps, frame.width > 1, abs(model.width - frame.width) > 0.5 { model.width = frame.width; model.measure() }
        }
        .onChange(of: source) { _, _ in model.update(source: source, prepared: prepared, wraps: wraps) }
        .onChange(of: prepared) { _, _ in model.update(source: source, prepared: prepared, wraps: wraps) }
        .onChange(of: wraps) { _, _ in model.update(source: source, prepared: prepared, wraps: wraps) }
        .onChange(of: displayScale, initial: true) { _, scale in
            if model.scale != scale { model.scale = scale; model.sizesCache.removeAll(); model.measure() }
        }
        .accessibilityRepresentation {
            if let prepared {
                HighlightedCodeBlockText(content: prepared, wraps: wraps)
            } else {
                PlainCodeBlockText(content: source, wraps: wraps)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("prototype-virtual-code")
    }

    @ViewBuilder private func codeLine(_ line: MarkdownPreparedCode.Line) -> some View {
        if wraps {
            line.segments.reduce(Text(verbatim: "")) { $0 + Text($1.text) }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(line.segments) { Text($0.text) }
            }.fixedSize()
        }
    }
}

#endif

private struct HighlightedCodeBlockText: View {
    let content: MarkdownPreparedCode
    /// See `PlainCodeBlockText.wraps`; the concatenated `Text` preserves each
    /// segment's syntax-highlight attributes.
    var wraps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(content.lines) { line in
                if wraps {
                    combinedText(for: line)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        ForEach(line.segments) { segment in
                            Text(segment.text)
                        }
                    }
                }
            }
        }
    }

    private func combinedText(for line: MarkdownPreparedCode.Line) -> Text {
        line.segments.reduce(Text(verbatim: "")) { partial, segment in
            partial + Text(segment.text)
        }
    }
}

/// One immutable display-ready revision, owned by the mounted code block.
/// Preparation runs on the existing highlight actor, not in SwiftUI bodies.
/// There is no process-wide cache: replacement/unmount releases this value.
/// Wrapping and environment layout reuse the same attributes and stable IDs;
/// content/language/theme/streaming changes restart the existing request task.
struct MarkdownPreparedCode: Equatable, Sendable {
    struct Segment: Equatable, Identifiable, Sendable {
        let id: Int
        let text: AttributedString
    }

    struct Line: Equatable, Identifiable, Sendable {
        let id: Int
        let segments: [Segment]
    }

    let lines: [Line]
    let fullText: AttributedString

    init(_ source: NSAttributedString) {
        fullText = AttributedString(source)
        lines = MarkdownAttributedCodeFormatter.lines(in: source).map { line in
            Line(id: line.id, segments: line.segments.map { segment in
                Segment(id: segment.id, text: AttributedString(segment.attributedText))
            })
        }
    }
}

struct MarkdownPlainCodeLine: Equatable, Identifiable {
    let id: Int
    let segments: [MarkdownPlainCodeSegment]
}

struct MarkdownPlainCodeSegment: Equatable, Identifiable {
    let id: Int
    let text: String
}

struct MarkdownAttributedCodeLine: Identifiable {
    let id: Int
    let segments: [MarkdownAttributedCodeSegment]
}

struct MarkdownAttributedCodeSegment: Identifiable {
    let id: Int
    let attributedText: NSAttributedString
}

enum MarkdownPlainCodeFormatter {
    static let maxSegmentLength = 500

    static func lines(in code: String) -> [MarkdownPlainCodeLine] {
        let normalizedCode = code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")

        let rawLines = normalizedCode
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let renderedLines = rawLines.isEmpty ? [""] : rawLines

        return renderedLines.enumerated().map { lineIndex, line in
            MarkdownPlainCodeLine(
                id: lineIndex,
                segments: segments(in: line)
            )
        }
    }

    private static func segments(in line: String) -> [MarkdownPlainCodeSegment] {
        guard !line.isEmpty else {
            return [MarkdownPlainCodeSegment(id: 0, text: " ")]
        }

        var segments: [MarkdownPlainCodeSegment] = []
        var startIndex = line.startIndex
        var segmentID = 0

        while startIndex < line.endIndex {
            let endIndex = line.index(
                startIndex,
                offsetBy: maxSegmentLength,
                limitedBy: line.endIndex
            ) ?? line.endIndex
            segments.append(
                MarkdownPlainCodeSegment(
                    id: segmentID,
                    text: String(line[startIndex..<endIndex])
                )
            )
            startIndex = endIndex
            segmentID += 1
        }

        return segments
    }
}

enum MarkdownAttributedCodeFormatter {
    static let maxSegmentLength = MarkdownPlainCodeFormatter.maxSegmentLength

    static func lines(in attributedCode: NSAttributedString) -> [MarkdownAttributedCodeLine] {
        let string = attributedCode.string as NSString
        guard string.length > 0 else {
            return [
                MarkdownAttributedCodeLine(
                    id: 0,
                    segments: [MarkdownAttributedCodeSegment(id: 0, attributedText: NSAttributedString(string: " "))]
                )
            ]
        }

        var lines: [MarkdownAttributedCodeLine] = []
        var lineStart = 0
        var index = 0

        while index < string.length {
            let character = string.character(at: index)
            if isLineSeparator(character) {
                lines.append(
                    MarkdownAttributedCodeLine(
                        id: lines.count,
                        segments: segments(in: NSRange(location: lineStart, length: index - lineStart), of: attributedCode)
                    )
                )

                if character == 13,
                   index + 1 < string.length,
                   string.character(at: index + 1) == 10 {
                    index += 1
                }
                lineStart = index + 1
            }

            index += 1
        }

        lines.append(
            MarkdownAttributedCodeLine(
                id: lines.count,
                segments: segments(
                    in: NSRange(location: lineStart, length: string.length - lineStart),
                    of: attributedCode
                )
            )
        )

        return lines
    }

    private static func segments(in range: NSRange, of attributedCode: NSAttributedString) -> [MarkdownAttributedCodeSegment] {
        guard range.length > 0 else {
            return [MarkdownAttributedCodeSegment(id: 0, attributedText: NSAttributedString(string: " "))]
        }

        var segments: [MarkdownAttributedCodeSegment] = []
        var location = range.location
        let upperBound = range.location + range.length

        while location < upperBound {
            let length = min(maxSegmentLength, upperBound - location)
            let segmentRange = NSRange(location: location, length: length)
            segments.append(
                MarkdownAttributedCodeSegment(
                    id: segments.count,
                    attributedText: attributedCode.attributedSubstring(from: segmentRange)
                )
            )
            location += length
        }

        return segments
    }

    private static func isLineSeparator(_ character: unichar) -> Bool {
        switch character {
        case 10, 13, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }
}

enum MarkdownContentFallbackReason: String, Equatable {
    case tooManyCharacters
    case tooManyLines
}

enum MarkdownContentRenderingPolicy {
    static let maxMarkdownCharacterCount = 80_000
    static let maxMarkdownLineCount = 2_000

    static func fallbackReason(for content: String) -> MarkdownContentFallbackReason? {
        if content.count > maxMarkdownCharacterCount {
            return .tooManyCharacters
        }

        if MarkdownHighlightPolicy.lineCount(in: content, stoppingAfter: maxMarkdownLineCount) > maxMarkdownLineCount {
            return .tooManyLines
        }

        return nil
    }
}

enum MarkdownHighlightEngine: Equatable {
    case splashSwift
    case highlightr
}

enum MarkdownHighlightFallbackReason: String, Equatable, Sendable {
    case streaming
    case empty
    case missingLanguage
    case unsupportedLanguage
    case highRiskLanguage
    case tooManyCharacters
    case tooManyLines
    case lineTooLong
    case highlighterUnavailable
}

enum MarkdownHighlightDecision: Equatable {
    case highlight(language: String, engine: MarkdownHighlightEngine)
    case plain(reason: MarkdownHighlightFallbackReason, normalizedLanguage: String?)
}

enum MarkdownHighlightPolicy {
    static let maxHighlightedCodeCharacterCount = 80_000
    static let maxHighlightedCodeLineCount = 2_000
    static let maxHighlightedCodeLineLength = 4_000

    private static let splashSwiftLanguages: Set<String> = ["swift"]
    private static let highRiskLanguages: Set<String> = [
        "ansi",
        "console",
        "diff",
        "log",
        "logs",
        "output",
        "patch",
        "plain",
        "terminal",
        "text",
        "txt"
    ]
    private static let highlightrLanguages: Set<String> = [
        "bash",
        "c",
        "cpp",
        "css",
        "go",
        "html",
        "java",
        "javascript",
        "json",
        "kotlin",
        "markdown",
        "objectivec",
        "python",
        "ruby",
        "rust",
        "scss",
        "sql",
        "toml",
        "typescript",
        "xml",
        "yaml"
    ]
    private static let languageAliases: [String: String] = [
        "c++": "cpp",
        "htm": "html",
        "js": "javascript",
        "jsx": "javascript",
        "jsonc": "json",
        "kt": "kotlin",
        "m": "objectivec",
        "md": "markdown",
        "mm": "objectivec",
        "objc": "objectivec",
        "py": "python",
        "rb": "ruby",
        "rs": "rust",
        "sh": "bash",
        "shell": "bash",
        "ts": "typescript",
        "tsx": "typescript",
        "yml": "yaml",
        "zsh": "bash"
    ]

    static func decision(for code: String, language: String?, isStreaming: Bool) -> MarkdownHighlightDecision {
        if isStreaming {
            return .plain(reason: .streaming, normalizedLanguage: normalizedLanguage(from: language))
        }

        if code.isEmpty {
            return .plain(reason: .empty, normalizedLanguage: normalizedLanguage(from: language))
        }

        if code.count > maxHighlightedCodeCharacterCount {
            return .plain(reason: .tooManyCharacters, normalizedLanguage: normalizedLanguage(from: language))
        }

        if lineCount(in: code, stoppingAfter: maxHighlightedCodeLineCount) > maxHighlightedCodeLineCount {
            return .plain(reason: .tooManyLines, normalizedLanguage: normalizedLanguage(from: language))
        }

        if containsLineLongerThan(maxHighlightedCodeLineLength, in: code) {
            return .plain(reason: .lineTooLong, normalizedLanguage: normalizedLanguage(from: language))
        }

        guard let normalizedLanguage = normalizedLanguage(from: language) else {
            return .plain(reason: .missingLanguage, normalizedLanguage: nil)
        }

        if highRiskLanguages.contains(normalizedLanguage) {
            return .plain(reason: .highRiskLanguage, normalizedLanguage: normalizedLanguage)
        }

        if splashSwiftLanguages.contains(normalizedLanguage) {
            return .highlight(language: normalizedLanguage, engine: .splashSwift)
        }

        if highlightrLanguages.contains(normalizedLanguage) {
            return .highlight(language: normalizedLanguage, engine: .highlightr)
        }

        return .plain(reason: .unsupportedLanguage, normalizedLanguage: normalizedLanguage)
    }

    static func normalizedLanguage(from language: String?) -> String? {
        guard let token = language?
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
        else {
            return nil
        }

        return languageAliases[token] ?? token
    }

    static func languageLogCategory(for normalizedLanguage: String?) -> String {
        guard let normalizedLanguage else {
            return "missing"
        }

        if splashSwiftLanguages.contains(normalizedLanguage) {
            return "splashSwift"
        }

        if highlightrLanguages.contains(normalizedLanguage) {
            return "highlightr"
        }

        if highRiskLanguages.contains(normalizedLanguage) {
            return "highRisk"
        }

        return "unsupported"
    }

    static func lineCount(in text: String, stoppingAfter limit: Int? = nil) -> Int {
        guard !text.isEmpty else { return 0 }

        var count = 1
        var index = text.unicodeScalars.startIndex

        while index < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[index]
            let nextIndex = text.unicodeScalars.index(after: index)

            if isLineSeparator(scalar) {
                count += 1
                if let limit, count > limit {
                    return count
                }

                if scalar.value == 13,
                   nextIndex < text.unicodeScalars.endIndex,
                   text.unicodeScalars[nextIndex].value == 10 {
                    index = text.unicodeScalars.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
            } else {
                index = nextIndex
            }
        }

        return count
    }

    static func containsLineLongerThan(_ maxLength: Int, in text: String) -> Bool {
        guard maxLength >= 0 else { return true }

        var currentLength = 0
        var index = text.unicodeScalars.startIndex

        while index < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[index]
            let nextIndex = text.unicodeScalars.index(after: index)

            if isLineSeparator(scalar) {
                currentLength = 0
                if scalar.value == 13,
                   nextIndex < text.unicodeScalars.endIndex,
                   text.unicodeScalars[nextIndex].value == 10 {
                    index = text.unicodeScalars.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
            } else {
                currentLength += 1
                if currentLength > maxLength {
                    return true
                }
                index = nextIndex
            }
        }

        return false
    }

    private static func isLineSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 10, 13, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }
}

#if DEBUG
/// Per-mount, bounded representative-fixture payload. No production cache.
struct NativePreparedHighlight: Sendable {
    let request: MarkdownCodeHighlightRequest
    let code: MarkdownPreparedCode
}
private struct NativePreparedHighlightsKey: EnvironmentKey {
    static let defaultValue: [NativePreparedHighlight] = []
}
extension EnvironmentValues {
    var nativePreparedHighlights: [NativePreparedHighlight] {
        get { self[NativePreparedHighlightsKey.self] }
        set { self[NativePreparedHighlightsKey.self] = newValue }
    }
}
#endif

struct MarkdownCodeHighlightRequest: Equatable, @unchecked Sendable {
    let code: String
    let language: String?
    let colorScheme: ColorScheme
    let isStreaming: Bool
}

enum MarkdownCodeHighlightResult: @unchecked Sendable {
    case highlighted(NSAttributedString)
    case plain(reason: MarkdownHighlightFallbackReason, normalizedLanguage: String?)
}

enum MarkdownPreparedCodeResult: Sendable {
    case highlighted(MarkdownPreparedCode)
    case plain(reason: MarkdownHighlightFallbackReason, normalizedLanguage: String?)
}

enum MarkdownCodeHighlighter {
    static func highlightedCode(for request: MarkdownCodeHighlightRequest) -> MarkdownCodeHighlightResult {
        let decision = MarkdownHighlightPolicy.decision(
            for: request.code,
            language: request.language,
            isStreaming: request.isStreaming
        )

        switch decision {
        case .highlight(_, .splashSwift):
            return .highlighted(
                SplashSwiftCodeHighlighter.highlightedAttributedString(
                    for: request.code,
                    colorScheme: request.colorScheme
                )
            )
        case .highlight(let normalizedLanguage, .highlightr):
            guard let highlighted = StableHighlightrStore.shared.highlight(
                request.code,
                language: normalizedLanguage,
                colorScheme: request.colorScheme
            ) else {
                return .plain(reason: .highlighterUnavailable, normalizedLanguage: normalizedLanguage)
            }

            return .highlighted(highlighted)
        case .plain(let reason, let normalizedLanguage):
            return .plain(reason: reason, normalizedLanguage: normalizedLanguage)
        }
    }
}

/// Serializes the non-thread-safe JavaScript/Splash highlighters on a dedicated
/// executor. `ChatCodeBlock` awaits this actor from MainActor, allowing scrolling,
/// typing, and layout to continue while completed code is parsed and colored.
actor MarkdownCodeHighlightWorker {
    static let shared = MarkdownCodeHighlightWorker()

#if DEBUG
    func rawHighlightedCode(for request: MarkdownCodeHighlightRequest) -> MarkdownCodeHighlightResult {
        MarkdownCodeHighlighter.highlightedCode(for: request)
    }
#endif

    func highlightedCode(for request: MarkdownCodeHighlightRequest) -> MarkdownPreparedCodeResult {
        switch MarkdownCodeHighlighter.highlightedCode(for: request) {
        case .highlighted(let source):
            return .highlighted(MarkdownPreparedCode(source))
        case .plain(let reason, let language):
            return .plain(reason: reason, normalizedLanguage: language)
        }
    }
}

private enum SplashSwiftCodeHighlighter {
    static func highlightedAttributedString(for code: String, colorScheme: ColorScheme) -> NSAttributedString {
        let font = Splash.Font(size: 13)
        let theme = colorScheme == .dark
            ? Splash.Theme.wwdc17(withFont: font)
            : Splash.Theme.presentation(withFont: font)
        let highlighter = SyntaxHighlighter(
            format: AttributedStringOutputFormat(theme: theme)
        )
        return highlighter.highlight(code)
    }
}

private final class StableHighlightrStore {
    static let shared = StableHighlightrStore()

    private enum ThemeKey: Hashable {
        case light
        case dark
    }

    private var highlightrs: [ThemeKey: Highlightr] = [:]

    private init() {}

    func highlight(_ code: String, language: String, colorScheme: ColorScheme) -> NSAttributedString? {
        return highlightr(for: colorScheme)?.highlight(code, as: language, fastRender: true)
    }

    private func highlightr(for colorScheme: ColorScheme) -> Highlightr? {
        let key: ThemeKey = colorScheme == .dark ? .dark : .light
        if let highlightr = highlightrs[key] {
            return highlightr
        }

        guard let highlightr = Highlightr() else {
            return nil
        }

        highlightr.setTheme(to: key == .dark ? "github-dark" : "xcode")
        highlightrs[key] = highlightr
        return highlightr
    }
}

private struct PlainMarkdownFallbackView: View {
    let content: String
    let reason: MarkdownContentFallbackReason

    private let logger = Logger.hermesMarkdownRendering

    var body: some View {
        Text(verbatim: content)
            .font(AppFont.body())
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .onAppear {
                logger.info(
                    "Markdown plain fallback reason=\(reason.rawValue, privacy: .public) characters=\(content.count, privacy: .public) lines=\(MarkdownHighlightPolicy.lineCount(in: content), privacy: .public)"
                )
            }
    }
}

private extension MarkdownUI.Theme {
    static func chat(colorScheme: ColorScheme, isStreaming: Bool) -> MarkdownUI.Theme {
        MarkdownUI.Theme.gitHub
            .text {
                ForegroundColor(.primary)
                BackgroundColor(nil)
                FontFamily(.system(.rounded))
                FontSize(16)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                BackgroundColor(
                    colorScheme == .dark
                        ? SwiftUI.Color(red: 0.08, green: 0.09, blue: 0.12)
                        : SwiftUI.Color(.tertiarySystemGroupedBackground)
                )
            }
            .codeBlock { configuration in
                MathFenceOrCodeBlock(
                    language: configuration.language,
                    content: configuration.content,
                    isStreaming: isStreaming
                )
                .markdownMargin(top: 4, bottom: 12)
                .prototypeMeasuredBlock("code")
            }
            .table { configuration in
                ChatMarkdownTable(
                    label: configuration.label,
                    colorScheme: colorScheme
                )
                .markdownMargin(top: 0, bottom: 16)
                .prototypeMeasuredBlock("table")
            }
            .tableCell { configuration in
                TableCellWidthCap(
                    minWidth: ChatMarkdownTable.cellMinWidth,
                    maxWidth: ChatMarkdownTable.cellMaxWidth
                ) {
                    configuration.label
                        .markdownTextStyle {
                            if configuration.row == 0 {
                                FontWeight(.semibold)
                            }
                            BackgroundColor(nil)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 13)
                .relativeLineSpacing(.em(0.25))
            }
    }
}

private struct ChatMarkdownTable: View {
    static let cellMinWidth: CGFloat = 96
    static let cellMaxWidth: CGFloat = 260

    let label: MarkdownUI.BlockConfiguration.Label
    let colorScheme: ColorScheme

    var body: some View {
        ScrollView(.horizontal) {
            label
                .fixedSize(horizontal: true, vertical: true)
                .markdownTableBorderStyle(.init(color: borderColor))
                .markdownTableBackgroundStyle(
                    .alternatingRows(backgroundColor, secondaryBackgroundColor)
                )
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private var backgroundColor: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 0.094, green: 0.098, blue: 0.114)
            : SwiftUI.Color.white
    }

    private var secondaryBackgroundColor: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 0.145, green: 0.149, blue: 0.165)
            : SwiftUI.Color(red: 0.969, green: 0.969, blue: 0.976)
    }

    private var borderColor: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 0.259, green: 0.267, blue: 0.306)
            : SwiftUI.Color(red: 0.894, green: 0.894, blue: 0.91)
    }
}

/// Single-child layout that caps a table cell's width while reporting the
/// height the content needs *at that capped width*.
///
/// `Grid` sizes table rows from each cell's ideal size. A plain
/// `.frame(maxWidth:)` caps the ideal width but still reports the
/// single-line ideal height, so long cell text wraps at render time without
/// the row growing — rows end up overlapping (issue #233). Measuring the
/// child at the clamped width makes the reported height match what is
/// actually drawn.
struct TableCellWidthCap: Layout {
    let minWidth: CGFloat
    let maxWidth: CGFloat

    /// Pure clamp used by `sizeThatFits`: fill the proposed (column) width
    /// when the parent offers one, otherwise fall back to the child's ideal
    /// width, always bounded to `minWidth...maxWidth`.
    static func resolvedWidth(
        idealWidth: CGFloat,
        proposedWidth: CGFloat?,
        minWidth: CGFloat,
        maxWidth: CGFloat
    ) -> CGFloat {
        min(max(proposedWidth ?? idealWidth, minWidth), maxWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let idealWidth = subview.sizeThatFits(.unspecified).width
        let width = Self.resolvedWidth(
            idealWidth: idealWidth,
            proposedWidth: proposal.width,
            minWidth: minWidth,
            maxWidth: maxWidth
        )
        let measured = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: measured.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Logger {
    static let hermesMarkdownRendering = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "MarkdownRendering"
    )
}
