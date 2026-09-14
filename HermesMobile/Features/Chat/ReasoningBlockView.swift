import SwiftUI

enum ReasoningDisplayText {
    /// Retained for existing display-model tests and callers that need a
    /// bounded preview. The reasoning disclosure itself intentionally uses the
    /// literal "Thinking" label and does not render this summary.
    private static let maximumParsedCharacters = 512

    static func shouldAnimateShine(isActive: Bool, reduceMotion: Bool) -> Bool {
        isActive && !reduceMotion
    }

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
    /// Live reasoning callers can opt into a gentle title shine. Completed
    /// reasoning keeps the quiet static label by default.
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey) private var startsExpanded = false
    @State private var userToggledExpansion: Bool?

    init(text: String, isActive: Bool = false) {
        self.text = text
        self.isActive = isActive
    }

    private var isExpanded: Bool {
        ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: startsExpanded
        )
    }

    var body: some View {
        if let trimmedText {
            VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
                Button {
                    withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
                        userToggledExpansion = !isExpanded
                    }
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Thinking"))
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            titleText
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
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

    private var trimmedText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
