import SwiftUI

struct ToolCallCardView: View {
    let toolCall: ToolCall
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
        let statusDisplay = ToolCallStatusDisplay(toolCall: toolCall)

        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button {
                toggleExpansion()
            } label: {
                header(statusDisplay: statusDisplay)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "\(actionTitle), \(statusDisplay.detailText)"))
            .accessibilityHint(isExpanded ? "Double tap to collapse details." : "Double tap to expand details.")

            if isExpanded {
                expandedContent(statusDisplay: statusDisplay)
                    .transition(disclosureTransition)
            }
        }
        .padding(.bottom, isExpanded ? 4 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Tool-call bodies are commands, JSON, file paths, and results — code-like
        // content that must stay left-to-right inside an RTL message (#259). The
        // group's summary header above (ToolActivityGroupView) still mirrors.
        .forcedLeftToRight()
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

    private func expandedContent(statusDisplay: ToolCallStatusDisplay) -> some View {
        let displayContent = ToolCallDisplayFormatter.content(for: toolCall)

        return VStack(alignment: .leading, spacing: 7) {
            if !displayContent.argumentRows.isEmpty {
                argumentsSection(displayContent.argumentRows)
            }

            if let result = displayContent.result {
                resultSection(result)
            }

            if shouldShowStatusDetail(displayContent: displayContent) {
                statusDetail(statusDisplay.detailText)
            }
        }
    }

    private var usesStackedHeader: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private func header(statusDisplay: ToolCallStatusDisplay) -> some View {
        HStack(alignment: usesStackedHeader ? .top : .center, spacing: 8) {
            Image(systemName: statusIcon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(statusColor)
                .frame(width: 18, height: 18)

            if usesStackedHeader {
                VStack(alignment: .leading, spacing: 3) {
                    titleText
                    if let collapsedText = statusDisplay.collapsedText {
                        collapsedStatus(text: collapsedText)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleText
                    if let collapsedText = statusDisplay.collapsedText {
                        collapsedStatus(text: collapsedText)
                    }
                }
            }

            Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func collapsedStatus(text: String) -> some View {
        if toolCall.isError == true {
            TranscriptStatusPill(text: text, color: statusColor)
        } else {
            ToolCallStatusCaption(text: text, color: statusColor)
        }
    }

    private var titleText: some View {
        Text(actionTitle)
            .font(AppFont.subheadline())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var actionTitle: String {
        ToolCallPresentationLabel.title(for: toolCall)
    }

    private var statusIcon: String {
        if toolCall.isError == true {
            return "exclamationmark.triangle.fill"
        }

        return ToolCallPresentationLabel.icon(for: toolCall.name)
    }

    private var statusColor: Color {
        if toolCall.isError == true {
            return .red
        }

        return .secondary
    }

    private func shouldShowStatusDetail(displayContent: ToolCallDisplayContent) -> Bool {
        let hasPrimaryContent = !displayContent.argumentRows.isEmpty || displayContent.result != nil
        return !hasPrimaryContent || !toolCall.isCompleted || toolCall.isError == true || toolCall.duration != nil
    }

    private func statusDetail(_ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Status")
                .font(AppFont.caption2(weight: .semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(AppFont.caption())
                .foregroundStyle(statusColor)
                .textSelection(.enabled)
        }
    }

    private func argumentsSection(_ rows: [ToolCallArgumentDisplay]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Arguments")
                .font(AppFont.caption2(weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row in
                    argumentRow(row)
                }
            }
            .padding(7)
            .chatTimelineAccessoryInsetSurface()
        }
    }

    private func resultSection(_ result: ToolCallResultDisplay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(result.title)
                .font(AppFont.caption2(weight: .semibold))
                .foregroundStyle(.secondary)

            Text(result.text)
                .font(result.isMonospaced ? AppFont.mono(style: .caption) : AppFont.caption())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .chatTimelineAccessoryInsetSurface()
        }
    }

    @ViewBuilder
    private func argumentRow(_ row: ToolCallArgumentDisplay) -> some View {
        if usesStackedHeader {
            VStack(alignment: .leading, spacing: 2) {
                argumentKey(row.key)
                argumentValue(row.value)
            }
        } else {
            HStack(alignment: .top, spacing: 7) {
                argumentKey(row.key)
                    .frame(width: 78, alignment: .leading)

                argumentValue(row.value)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func argumentKey(_ value: String) -> some View {
        Text(value)
            .font(AppFont.mono(style: .caption2, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func argumentValue(_ value: String) -> some View {
        Text(value)
            .font(AppFont.mono(style: .caption))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
    }
}

private struct ToolCallStatusCaption: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(AppFont.caption2(weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

struct ToolCallStatusDisplay: Equatable {
    let collapsedText: String?
    let detailText: String

    init(toolCall: ToolCall) {
        if toolCall.isError == true {
            collapsedText = String(localized: "Failed")
            detailText = String(localized: "Failed")
            return
        }

        if toolCall.isCompleted {
            collapsedText = nil
            if let duration = toolCall.duration {
                detailText = "Completed in \(duration.formatted(.number.precision(.fractionLength(1))))s"
            } else {
                detailText = String(localized: "Completed")
            }
            return
        }

        collapsedText = String(localized: "Running")
        detailText = String(localized: "Running")
    }
}

struct TranscriptStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(AppFont.caption2(weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}
