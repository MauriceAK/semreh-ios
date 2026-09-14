import SwiftUI

enum ReasoningDisplayText {
    /// Collapsed cards need only a short preview. Bounding the parsed source
    /// keeps a long live reasoning stream from reparsing its full history on
    /// every token while still giving Markdown enough context for the header.
    private static let maximumParsedCharacters = 512

    static func summary(_ source: String, maximumCharacters: Int = 80) -> String {
        let maximumCharacters = max(0, maximumCharacters)
        let boundedSource = String(source.prefix(maximumParsedCharacters))
        // Full-document AttributedString conversion drops paragraph separators
        // from `.characters` ("heading" + "body" becomes "headingbody").
        // Parse bounded lines independently, then restore one visible boundary.
        let oneLine = boundedSource
            .components(separatedBy: .newlines)
            .map { line in
                (try? AttributedString(
                    markdown: line,
                    options: .init(interpretedSyntax: .full)
                )).map { String($0.characters) } ?? line
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            // Foundation preserves unmatched delimiters in an incomplete live
            // token tail. They are presentation syntax, not useful summary text.
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !oneLine.isEmpty else { return String(localized: "Thinking…") }

        if oneLine.count <= maximumCharacters {
            return oneLine
        }
        return "\(oneLine.prefix(maximumCharacters))..."
    }
}

struct ReasoningBlockView: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey) private var startsExpanded = false
    @State private var userToggledExpansion: Bool?

    private var isExpanded: Bool {
        ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: startsExpanded
        )
    }

    var body: some View {
        if let trimmedText {
            let summary = summary(for: trimmedText)

            VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
                Button {
                    withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
                        userToggledExpansion = !isExpanded
                    }
                } label: {
                    header(summary: summary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Thinking, \(summary)"))
                .accessibilityHint(isExpanded ? "Double tap to collapse details." : "Double tap to expand details.")

                if isExpanded {
                    Text(trimmedText)
                        .font(AppFont.caption())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var usesStackedHeader: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private func header(summary: String) -> some View {
        HStack(alignment: usesStackedHeader ? .top : .center, spacing: 8) {
            Image("LucideBrain")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            if usesStackedHeader {
                VStack(alignment: .leading, spacing: 1) {
                    titleText
                    summaryText(summary, lineLimit: 2)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleText
                    summaryText(summary, lineLimit: 1)
                }
            }

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        Text("Thinking")
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func summaryText(_ value: String, lineLimit: Int) -> some View {
        Text(value)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
    }

    private var trimmedText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func summary(for value: String) -> String {
        ReasoningDisplayText.summary(value)
    }
}
