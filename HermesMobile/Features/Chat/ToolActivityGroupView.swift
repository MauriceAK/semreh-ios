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
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button {
                withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
                    userToggledExpansion = !isExpanded
                }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activityAccessibilityLabel)
            .accessibilityHint(isExpanded ? "Double tap to collapse details." : "Double tap to expand details.")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.toolCalls) { toolCall in
                        ToolCallCardView(toolCall: toolCall)
                    }
                }
                .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
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
                        TranscriptStatusPill(text: collapsedStateText, color: activityColor)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleText
                    if let collapsedStateText {
                        TranscriptStatusPill(text: collapsedStateText, color: activityColor)
                    }
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
        Text(actionSummary)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var actionSummary: String {
        ToolCallPresentationLabel.groupTitle(for: group.toolCalls)
    }

    private var activityIcon: String {
        if group.hasFailedTool {
            return "exclamationmark.triangle.fill"
        }

        return group.isComplete ? "checkmark.circle.fill" : "wrench.and.screwdriver.fill"
    }

    private var activityColor: Color {
        if group.hasFailedTool {
            return .red
        }

        return .secondary
    }

    private var collapsedStateText: String? {
        if group.hasFailedTool {
            return String(localized: "Failed")
        }

        return group.isComplete ? nil : String(localized: "Running")
    }

    private var activityAccessibilityLabel: String {
        "\(actionSummary), \(activityStateText)"
    }

    private var activityStateText: String {
        if group.hasFailedTool {
            return String(localized: "Failed")
        }

        return group.isComplete ? String(localized: "Completed") : String(localized: "Running")
    }
}
