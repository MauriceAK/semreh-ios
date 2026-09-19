import SwiftUI

enum ReasoningDisplayText {
    struct Presentation: Equatable {
        let markdownSource: String?
        let latestActivity: String?
    }

    private static let maximumParsedCharacters = 512

    /// These exact face/verb pairs are the pinned upstream TUI spinner status
    /// tokens that currently travel through thinking.delta. Keep this a narrow
    /// presentation filter: the original reasoning payload remains untouched,
    /// and unrelated emoji, emoticons, Markdown, and code remain visible.
    private static let thinkingSpinnerPattern: NSRegularExpression = {
        let faces = [
            "(｡•́︿•̀｡)", "(◔_◔)", "(¬‿¬)", "( •_•)>⌐■-■", "(⌐■_■)",
            "(´･_･`)", "◉_◉", "(°ロ°)", "( ˘⌣˘)♡", "ヽ(>∀<☆)☆", "٩(๑❛ᴗ❛๑)۶",
            "(⊙_⊙)", "(¬_¬)", "( ͡° ͜ʖ ͡°)", "ಠ_ಠ"
        ]
        let verbs = [
            "pondering", "contemplating", "musing", "cogitating", "ruminating",
            "deliberating", "mulling", "reflecting", "processing", "reasoning",
            "analyzing", "computing", "synthesizing", "formulating", "brainstorming"
        ]
        let facePattern = faces
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let verbPattern = verbs
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "(?:\(facePattern))[\\t ]+(?:\(verbPattern))\\.\\.\\."
        )
    }()

    static func shouldAnimateShine(isActive: Bool, reduceMotion: Bool) -> Bool {
        isActive && !reduceMotion
    }

    static func shouldDisplayDisclosure(
        isActive: Bool,
        rawText: String,
        latestActivity: String?,
        markdownSource: String?
    ) -> Bool {
        !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (isActive || latestActivity != nil || markdownSource != nil)
    }

    static func summary(_ source: String, maximumCharacters: Int = 80) -> String {
        latestActivity(in: source, maximumCharacters: maximumCharacters)
            ?? String(localized: "Thinking…")
    }

    static func latestActivity(in source: String, maximumCharacters: Int = 80) -> String? {
        let boundedTail = String(source.suffix(maximumParsedCharacters))
        return presentation(for: boundedTail, maximumCharacters: maximumCharacters).latestActivity
    }

    static func markdownSource(_ source: String) -> String? {
        presentation(for: source).markdownSource
    }

    static func presentation(for source: String, maximumCharacters: Int = 80) -> Presentation {
        let lines = source.components(separatedBy: .newlines)
        let sourceLength = source.count
        let tailStart = max(0, sourceLength - maximumParsedCharacters)
        var sourceOffset = 0
        var currentFence: FenceMarker?
        var inlineCodeDelimiterLength: Int?
        var filteredLines: [String] = []
        var latestActivity: String?

        for line in lines {
            let lineStartOffset = sourceOffset
            let lineEndOffset = lineStartOffset + line.count
            let isInTail = lineEndOffset >= tailStart
            let cleanedLine: String
            let isCodeLine: Bool

            if let fence = currentFence {
                cleanedLine = line
                isCodeLine = true
                if isClosingFence(line, matching: fence) {
                    currentFence = nil
                    inlineCodeDelimiterLength = nil
                }
            } else if inlineCodeDelimiterLength == nil,
                      let openingFence = openingFence(in: line) {
                cleanedLine = line
                isCodeLine = true
                currentFence = openingFence
                inlineCodeDelimiterLength = nil
            } else if isIndentedCodeLine(line) {
                cleanedLine = line
                isCodeLine = true
                inlineCodeDelimiterLength = nil
            } else {
                isCodeLine = false
                let inlineCodeRanges = inlineCodeRanges(
                    in: line,
                    delimiterLength: &inlineCodeDelimiterLength
                )
                cleanedLine = removingThinkingSpinnerTokens(
                    from: line,
                    protectedRanges: inlineCodeRanges
                )
            }

            filteredLines.append(cleanedLine)

            let trimmedLine = cleanedLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if isInTail, !isCodeLine, !trimmedLine.isEmpty {
                let tailOffset = max(0, tailStart - lineStartOffset)
                let boundedLine = tailOffset > 0
                    ? String(cleanedLine.suffix(max(1, cleanedLine.count - tailOffset)))
                    : cleanedLine
                let candidate = boundedLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty,
                   let parsedCandidate = summaryLine(candidate, maximumCharacters: maximumCharacters) {
                    latestActivity = parsedCandidate
                }
            }

            sourceOffset = lineEndOffset + 1
        }

        let filteredSource = filteredLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let markdownSource = filteredSource.isEmpty ? nil : filteredSource

        return Presentation(markdownSource: markdownSource, latestActivity: latestActivity)
    }

    private struct FenceMarker: Equatable {
        let character: Character
        let length: Int
    }

    private static func openingFence(in line: String) -> FenceMarker? {
        guard let run = fenceRun(in: line), run.length >= 3 else { return nil }
        return FenceMarker(character: run.character, length: run.length)
    }

    private static func isClosingFence(_ line: String, matching fence: FenceMarker) -> Bool {
        guard let run = fenceRun(in: line),
              run.character == fence.character,
              run.length >= fence.length
        else {
            return false
        }

        return line[run.end...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func fenceRun(in line: String) -> (character: Character, length: Int, end: String.Index)? {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " ", leadingSpaces < 4 {
            leadingSpaces += 1
            index = line.index(after: index)
        }
        guard leadingSpaces <= 3, index < line.endIndex else { return nil }

        let marker = line[index]
        guard marker == "`" || marker == "~" else { return nil }
        var length = 0
        while index < line.endIndex, line[index] == marker {
            length += 1
            index = line.index(after: index)
        }
        return (marker, length, index)
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private static func inlineCodeRanges(
        in line: String,
        delimiterLength: inout Int?
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var spanStart = delimiterLength == nil ? nil : line.startIndex
        var index = line.startIndex

        while index < line.endIndex {
            guard line[index] == "`" else {
                index = line.index(after: index)
                continue
            }

            let runStart = index
            var runLength = 0
            while index < line.endIndex, line[index] == "`" {
                runLength += 1
                index = line.index(after: index)
            }

            guard !isEscaped(runStart, in: line) else { continue }

            if let openLength = delimiterLength {
                if runLength == openLength {
                    ranges.append((spanStart ?? line.startIndex)..<index)
                    delimiterLength = nil
                    spanStart = nil
                }
            } else {
                delimiterLength = runLength
                spanStart = runStart
            }
        }

        if delimiterLength != nil, let spanStart {
            ranges.append(spanStart..<line.endIndex)
        }
        return ranges
    }

    private static func isEscaped(_ index: String.Index, in source: String) -> Bool {
        var cursor = index
        var backslashCount = 0
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\\" else { break }
            backslashCount += 1
            cursor = previous
        }
        return backslashCount.isMultiple(of: 2) == false
    }

    private static func removingThinkingSpinnerTokens(
        from line: String,
        protectedRanges: [Range<String.Index>]
    ) -> String {
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        let tokenRanges = thinkingSpinnerPattern.matches(in: line, range: fullRange)
            .compactMap { Range($0.range, in: line) }
            .filter { match in
                !protectedRanges.contains { $0.overlaps(match) }
            }
        guard !tokenRanges.isEmpty else { return line }

        let expandedRanges = tokenRanges.map { tokenRange -> Range<String.Index> in
            if tokenRange.upperBound < line.endIndex,
               line[tokenRange.upperBound] == " " || line[tokenRange.upperBound] == "\t" {
                return tokenRange.lowerBound..<line.index(after: tokenRange.upperBound)
            }
            if tokenRange.lowerBound > line.startIndex {
                let previous = line.index(before: tokenRange.lowerBound)
                if line[previous] == " " || line[previous] == "\t" {
                    return previous..<tokenRange.upperBound
                }
            }
            return tokenRange
        }.sorted { $0.lowerBound < $1.lowerBound }

        var ranges: [Range<String.Index>] = []
        for range in expandedRanges {
            if let last = ranges.last, range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }

        var result = line
        for range in ranges.reversed() {
            result.removeSubrange(range)
        }
        return result
    }

    private static func summaryLine(_ source: String, maximumCharacters: Int) -> String? {
        guard maximumCharacters > 0 else { return nil }
        guard !isBacktickMarkerOnly(source) else { return nil }
        let markdownText = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)
        )).map { String($0.characters) } ?? source
        var oneLine = markdownText.trimmingCharacters(in: .whitespacesAndNewlines)

        // An incomplete leading emphasis delimiter is common in a live token
        // tail. Hide only that unmatched presentation marker in this summary;
        // the expanded Markdown source remains byte-for-byte readable.
        for marker in ["**", "__", "~~"] where source.hasPrefix(marker) {
            if !source.dropFirst(marker.count).contains(marker), oneLine.hasPrefix(marker) {
                oneLine.removeFirst(marker.count)
                break
            }
        }
        oneLine = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard oneLine.unicodeScalars.contains(where: {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.symbols.contains($0)
        }) else {
            return nil
        }

        if oneLine.count <= maximumCharacters {
            return oneLine
        }
        return "…\(oneLine.suffix(maximumCharacters - 1))"
    }

    private static func isBacktickMarkerOnly(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "`" }
    }
}

struct ReasoningBlockView: View {
    let text: String
    /// Reasoning arrivals retained as separate segments; the expanded view
    /// renders one quiet sub-block per entry. Empty for legacy single-blob
    /// callers (and the live streaming path) — `text` is then the one block.
    let segments: [String]
    /// Live reasoning callers can opt into a gentle title shine. Completed
    /// reasoning keeps the quiet static label by default.
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey) private var startsExpanded = false
    @State private var userToggledExpansion: Bool?

    init(text: String, segments: [String] = [], isActive: Bool = false) {
        self.text = text
        self.segments = segments
        self.isActive = isActive
    }

    private var isExpanded: Bool {
        ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: startsExpanded
        )
    }

    var body: some View {
        let latestActivity = isExpanded ? nil : ReasoningDisplayText.latestActivity(in: text)
        let fullMarkdownSource = isExpanded || (!isActive && latestActivity == nil)
            ? ReasoningDisplayText.markdownSource(text)
            : nil
        let shouldDisplay = ReasoningDisplayText.shouldDisplayDisclosure(
            isActive: isActive,
            rawText: text,
            latestActivity: latestActivity,
            markdownSource: fullMarkdownSource
        )

        if shouldDisplay {
            VStack(alignment: .leading, spacing: isExpanded ? 4 : 0) {
                Button {
                    toggleExpansion()
                } label: {
                    header(latestActivity: latestActivity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Thinking"))
                .accessibilityHint(isExpanded ? "Double tap to collapse details." : "Double tap to expand details.")

                if isExpanded {
                    expandedReasoning
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(disclosureTransition)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Segments when the group retained them; legacy single-blob callers (and
    /// the live streaming path) fall back to `text` as the one block.
    private var resolvedSegments: [String] {
        segments.isEmpty ? [text] : segments
    }

    /// Expanded Thinking renders each preserved reasoning segment as its own
    /// sub-block: spaced paragraphs separated by a quiet hairline. The joined
    /// `text` blob is never rendered whole; boundaries survive from
    /// `ReasoningDisplayBuilder` through `ReasoningGroup.segments`.
    @ViewBuilder
    private var expandedReasoning: some View {
        let renderedSegments = resolvedSegments.compactMap { segment in
            ReasoningDisplayText.markdownSource(segment)
        }

        if !renderedSegments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(renderedSegments.enumerated()), id: \.offset) { index, markdown in
                    if index > 0 {
                        Divider().opacity(0.4)
                    }

                    MarkdownRenderer(
                        content: markdown,
                        isStreaming: isActive,
                        isThinkingBody: true
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if isActive {
            Text("Thinking…")
                .font(AppFont.thinkingBody)
                .foregroundStyle(.secondary)
        }
    }

    private func header(latestActivity: String?) -> some View {
        HStack(alignment: .center, spacing: 6) {
            titleText
            if let latestActivity {
                Text("· \(latestActivity)")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        Text("Thinking")
            .font(AppFont.subheadline())
            .lineLimit(1)
            .modifier(ReasoningTextShineModifier(isActive: isActive))
    }

    private var disclosureTransition: AnyTransition {
        reduceMotion ? .identity : ChatMotion.disclosureTransition(reduceMotion: false)
    }

    private func toggleExpansion() {
        let update = { userToggledExpansion = !isExpanded }
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        } else {
            withAnimation(ChatMotion.disclosure(reduceMotion: false), update)
        }
    }
}

/// A low-contrast repeating sweep makes an active reasoning disclosure legible
/// without turning completed history into an animated surface. The caller owns
/// lifecycle truth (`isActive`); the view does not infer it from text contents.
struct ReasoningTextShineModifier: ViewModifier {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shinePosition = -1.0
    @State private var isShining = false

    func body(content: Content) -> some View {
        Group {
            if isShining {
                content.foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: .secondary.opacity(0.62), location: 0),
                            .init(color: .primary.opacity(0.96), location: 0.5),
                            .init(color: .secondary.opacity(0.62), location: 1)
                        ],
                        startPoint: UnitPoint(x: shinePosition - 0.7, y: 0.5),
                        endPoint: UnitPoint(x: shinePosition + 0.7, y: 0.5)
                    )
                )
            } else {
                content.foregroundStyle(.secondary)
            }
        }
        .onAppear {
            updateShine()
        }
        .onChange(of: isActive) { _, _ in
            updateShine()
        }
        .onChange(of: reduceMotion) { _, _ in
            updateShine()
        }
        .onDisappear {
            stopShine()
        }
    }

    private func updateShine() {
        guard ReasoningDisplayText.shouldAnimateShine(isActive: isActive, reduceMotion: reduceMotion) else {
            stopShine()
            return
        }

        shinePosition = -1
        isShining = true
        withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
            shinePosition = 2
        }
    }

    private func stopShine() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isShining = false
            shinePosition = -1
        }
    }
}
