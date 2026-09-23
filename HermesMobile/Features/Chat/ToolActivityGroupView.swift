import SwiftUI

struct ToolActivityGroupView: View {
    let group: ToolCallGroup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChatTranscriptDisplaySettings.toolCardsStartExpandedKey) private var startsExpanded = false
    @State private var userToggledExpansion: Bool?
#if DEBUG
    @Environment(\.prototypeCodeViewport) private var directViewport
#endif

    private var isExpanded: Bool {
#if DEBUG
        if directViewport?.forceExpandTool == true, userToggledExpansion == nil { return true }
#endif
        return ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: startsExpanded
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 2 : 0) {
            Button {
                toggleExpansion()
            } label: {
                header
            }
            .buttonStyle(.plain)
            .chatMinimumHitTarget(horizontalPadding: 0, verticalPadding: 5, in: Rectangle())
            .accessibilityLabel(activityAccessibilityLabel)
            .accessibilityHint(isExpanded ? "Double tap to collapse details." : "Double tap to expand details.")

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if group.toolCalls.count == 1, let toolCall = group.toolCalls.first {
                        ToolCallCardView(toolCall: toolCall, showsHeader: false)
                    } else {
                        ForEach(group.toolCalls) { toolCall in
                            ToolCallCardView(toolCall: toolCall)
                        }
                    }
                }
                .padding(.leading, 28)
                .transition(disclosureTransition)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .transaction { transaction in
            if reduceMotion {
                transaction.disablesAnimations = true
            }
        }
    }

    private var header: some View {
        TranscriptActivityDisclosureLabel(
            symbol: activityIcon,
            title: actionSummary,
            status: group.hasFailedTool ? collapsedStateText : nil,
            isExpanded: isExpanded,
            isFailure: group.hasFailedTool,
            isActive: !group.isComplete && !group.hasFailedTool,
            isCompact: true
        )
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
        if group.toolCalls.count > 1 {
            return String(localized: "\(group.toolCalls.count) actions")
        }
        return ToolCallPresentationLabel.title(for: latestToolCall)
    }

    static func icon(for group: ToolCallGroup) -> String {
        if group.toolCalls.count > 1 { return "square.stack.3d.up" }
        return ToolCallPresentationLabel.icon(for: group.toolCalls.last?.name)
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

        // A latest-action duration is not the duration of an entire group.
        guard group.toolCalls.count == 1 else { return String(localized: "Completed") }

        if let duration = group.toolCalls.last?.duration,
           duration.isFinite,
           duration >= 0 {
            let formatted = duration.formatted(.number.precision(.fractionLength(0...1)))
            return String(localized: "Worked for \(formatted)s")
        }

        return String(localized: "Completed")
    }
}
