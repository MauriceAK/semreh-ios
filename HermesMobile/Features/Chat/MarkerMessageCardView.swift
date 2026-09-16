import SwiftUI

enum MarkerMessageCardPresentation {
    private static let leadingTaskMarkerPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:[-*+]\s+|\d+[.)]\s+))?\[(?:\s|[xX>])\]\s*"#
    )

    static func latestTaskSummary(in source: String) -> String? {
        guard let latestActivity = ReasoningDisplayText.latestActivity(in: source) else {
            return nil
        }

        let range = NSRange(latestActivity.startIndex..<latestActivity.endIndex, in: latestActivity)
        let summary = (leadingTaskMarkerPattern
            .firstMatch(in: latestActivity, range: range)
            .flatMap { Range($0.range, in: latestActivity) }
            .map { latestActivity.replacingCharacters(in: $0, with: "") } ?? latestActivity)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return summary.isEmpty ? nil : summary
    }
}

/// Collapsible card for context-compaction marker messages, replacing the user
/// bubble they would otherwise render as. Mirrors the web UI's collapsed cards
/// and follows the `ReasoningBlockView` disclosure pattern.
struct MarkerMessageCardView: View {
    let kind: ChatMarkerMessageKind
    let content: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isExpanded = false

    var body: some View {
        let cardBody = ChatMarkerMessageClassifier.cardBody(for: kind, content: content)
        let summary = summary(for: cardBody)

        VStack(alignment: .leading, spacing: isExpanded ? 4 : 0) {
            Button {
                toggleExpansion()
            } label: {
                header(summary: summary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary.map { "\(kind.title), \($0)" } ?? kind.title)
            .accessibilityHint(isExpanded ? String(localized: "Double tap to collapse details.") : String(localized: "Double tap to expand details."))

            if isExpanded {
                Group {
                    if cardBody.isEmpty {
                        Text(kind.title)
                            .font(AppFont.caption())
                            .foregroundStyle(.primary)
                    } else {
                        MarkdownRenderer(content: cardBody)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(disclosureTransition)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var usesStackedHeader: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var iconName: String {
        switch kind {
        case .contextCompaction:
            return "arrow.down.right.and.arrow.up.left"
        case .preservedTaskList:
            return "checklist"
        case .compressionReference:
            return "star"
        case .processWakeup:
            return "terminal"
        }
    }

    private func header(summary: String?) -> some View {
        HStack(alignment: usesStackedHeader ? .top : .center, spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            if usesStackedHeader {
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let summary {
                            summaryText(summary, lineLimit: 2)
                        }
                        disclosureChevron
                    }
                }
            } else {
                titleText
                if let summary {
                    summaryText(summary, lineLimit: 1)
                }
                disclosureChevron
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        Text(kind.title)
            .font(AppFont.subheadline())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func summaryText(_ value: String, lineLimit: Int) -> some View {
        Text("· \(value)")
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
    }

    private var disclosureChevron: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var disclosureTransition: AnyTransition {
        reduceMotion ? .identity : ChatMotion.disclosureTransition(reduceMotion: false)
    }

    private func toggleExpansion() {
        let update = { isExpanded.toggle() }
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        } else {
            withAnimation(ChatMotion.disclosure(reduceMotion: false), update)
        }
    }

    private func summary(for value: String) -> String? {
        let oneLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The synthesized anchor card mirrors the web UI's
        // "Reference only · <preview>" collapsed line.
        if kind == .compressionReference {
            guard !oneLine.isEmpty else { return String(localized: "Reference only") }
            return String(localized: "Reference only · \(truncated(oneLine))")
        }

        if kind == .preservedTaskList {
            guard let latestTask = MarkerMessageCardPresentation.latestTaskSummary(in: value) else {
                return nil
            }
            return truncated(latestTask)
        }

        if oneLine.isEmpty {
            return nil
        }

        return truncated(oneLine)
    }

    private func truncated(_ oneLine: String) -> String {
        if oneLine.count <= 80 {
            return oneLine
        }

        return "\(oneLine.prefix(80))..."
    }
}
