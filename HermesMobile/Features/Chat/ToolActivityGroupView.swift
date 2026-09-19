import SwiftUI

struct ToolActivityGroupView: View {
    let group: ToolCallGroup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(ChatTranscriptDisplaySettings.toolCardsStartExpandedKey) private var startsExpanded = false
    @State private var userToggledExpansion: Bool?

    private var isExpanded: Bool {
        ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: startsExpanded
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 4 : 0) {
            Button {
                toggleExpansion()
            } label: {
                header
            }
            .buttonStyle(.plain)
            .chatMinimumHitTarget(horizontalPadding: 10, verticalPadding: 8, in: Rectangle())
            .accessibilityLabel(activityAccessibilityLabel)
            .accessibilityHint(isExpanded ? "Double tap to collapse details." : "Double tap to expand details.")

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.toolCalls) { toolCall in
                        ToolCallCardView(toolCall: toolCall)
                    }
                }
                .transition(disclosureTransition)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isExpanded ? 8 : 6)
        .chatTimelineAccessorySurface(
            fallbackMaterial: .thinMaterial,
            cornerRadius: 10
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .transaction { transaction in
            if reduceMotion {
                transaction.disablesAnimations = true
            }
        }
    }

    private var usesStackedHeader: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var header: some View {
        HStack(alignment: usesStackedHeader ? .top : .center, spacing: 8) {
            Image(systemName: activityIcon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(activityColor)
                .frame(width: 18, height: 18)

            if usesStackedHeader {
                VStack(alignment: .leading, spacing: 3) {
                    titleText
                    if let collapsedStateText {
                        collapsedStatus(text: collapsedStateText)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleText
                    if let collapsedStateText {
                        collapsedStatus(text: collapsedStateText)
                    }
                }
            }

            Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Compact visual row for standard sizes; accessibility sizes keep the
        // full 44pt minimum (touch height restored by the button slop above).
        .frame(minHeight: usesStackedHeader ? 44 : 28)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func collapsedStatus(text: String) -> some View {
        if group.hasFailedTool {
            TranscriptStatusPill(text: text, color: activityColor)
        } else {
            Text(text)
                .font(AppFont.caption2(weight: .semibold))
                .foregroundStyle(activityColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var titleText: some View {
        Text(actionSummary)
            .font(AppFont.subheadline())
            .lineLimit(1)
            .modifier(ReasoningTextShineModifier(isActive: !group.isComplete))
    }

    private var actionSummary: String {
        ToolActivityGroupPresentation.title(for: group)
    }

    private var activityIcon: String {
        if group.hasFailedTool {
            return "exclamationmark.triangle.fill"
        }

        return ToolActivityGroupPresentation.icon(for: group)
    }

    private var activityColor: Color {
        if group.hasFailedTool {
            return .red
        }

        return .secondary
    }

    private var collapsedStateText: String? {
        ToolActivityGroupPresentation.status(for: group)
    }

    private var activityAccessibilityLabel: String {
        guard let collapsedStateText else { return actionSummary }
        return "\(actionSummary), \(collapsedStateText)"
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

enum ToolActivityGroupPresentation {
    static func title(for group: ToolCallGroup) -> String {
        guard let latestToolCall = group.toolCalls.last else {
            return String(localized: "No actions")
        }
        return ToolCallPresentationLabel.title(for: latestToolCall)
    }

    static func icon(for group: ToolCallGroup) -> String {
        ToolCallPresentationLabel.icon(for: group.toolCalls.last?.name)
    }

    /// Reflects the most recent action without estimating a group duration.
    /// A duration is shown only when the latest completed tool supplied a
    /// finite, nonnegative value; missing/invalid values stay plain Completed.
    static func status(for group: ToolCallGroup) -> String? {
        if group.hasFailedTool {
            return String(localized: "Failed")
        }
        guard !group.toolCalls.isEmpty else { return nil }
        guard group.isComplete else { return String(localized: "Running") }

        if let duration = group.toolCalls.last?.duration,
           duration.isFinite,
           duration >= 0 {
            let formatted = duration.formatted(.number.precision(.fractionLength(0...1)))
            return String(localized: "Worked for \(formatted)s")
        }

        return String(localized: "Completed")
    }
}
