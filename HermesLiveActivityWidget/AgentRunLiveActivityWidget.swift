import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HermesLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget { AgentRunLiveActivityWidget() }
}

struct AgentRunLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentRunActivityAttributes.self) { context in
            AgentRunSummaryView(state: context.state, systemIsStale: context.isStale)
                .padding(16)
                .activityBackgroundTint(AgentRunLiveActivityTheme.background)
                .activitySystemActionForegroundColor(AgentRunLiveActivityTheme.primaryText)
                .widgetURL(HermesDeepLink.sessionURL(sessionID: context.state.sessionID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Semreh")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AgentRunLiveActivityTheme.secondaryText)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AgentRunTimeView(state: context.state, systemIsStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    AgentRunSummaryView(state: context.state, systemIsStale: context.isStale, showsHeader: false)
                        .padding(.bottom, 4)
                }
            } compactLeading: {
                AgentRunStatusSymbol(state: context.state, systemIsStale: context.isStale)
            } compactTrailing: {
                Text(!context.state.isFinal && (context.state.isStale || context.isStale)
                     ? String(localized: "Stale") : context.state.status.compactTitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AgentRunLiveActivityTheme.primaryText)
                    .lineLimit(1)
                    .accessibilityLabel(context.state.displayStatus(systemIsStale: context.isStale))
            } minimal: {
                AgentRunStatusSymbol(state: context.state, systemIsStale: context.isStale)
            }
            .widgetURL(HermesDeepLink.sessionURL(sessionID: context.state.sessionID))
            .keylineTint(AgentRunLiveActivityTheme.secondaryText)
        }
    }
}

private struct AgentRunSummaryView: View {
    let state: AgentRunActivityAttributes.ContentState
    let systemIsStale: Bool
    var showsHeader = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                HStack {
                    Text("Semreh")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AgentRunLiveActivityTheme.secondaryText)
                    Spacer(minLength: 8)
                    AgentRunTimeView(state: state, systemIsStale: systemIsStale)
                }
            }
            Text(state.sessionTitle)
                .font(.headline)
                .foregroundStyle(AgentRunLiveActivityTheme.primaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            Label {
                Text(state.displayStatus(systemIsStale: systemIsStale))
            } icon: {
                AgentRunStatusSymbol(state: state, systemIsStale: systemIsStale)
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .foregroundStyle(AgentRunLiveActivityTheme.primaryText)
            .lineLimit(2)

            if !dynamicTypeSize.isAccessibilitySize,
               let detail = state.displayDetail(systemIsStale: systemIsStale) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AgentRunLiveActivityTheme.secondaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentRunTimeView: View {
    let state: AgentRunActivityAttributes.ContentState
    let systemIsStale: Bool

    var body: some View {
        // System time needs no app updates. Stale and terminal snapshots freeze
        // at the last update; failed/cancelled/unknown outcomes never say Done.
        Group {
            if state.isFinal || state.isStale || systemIsStale {
                Text(AgentRunElapsedTimeFormatter.label(startedAt: state.startedAt, updatedAt: state.updatedAt))
            } else {
                Text(timerInterval: state.startedAt...state.startedAt.addingTimeInterval(99 * 60 + 59),
                     countsDown: false, showsHours: false)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .foregroundStyle(AgentRunLiveActivityTheme.secondaryText)
        .lineLimit(1)
        .frame(maxWidth: 64, alignment: .trailing)
    }
}

private struct AgentRunStatusSymbol: View {
    let state: AgentRunActivityAttributes.ContentState
    let systemIsStale: Bool

    private var isStale: Bool { !state.isFinal && (state.isStale || systemIsStale) }

    var body: some View {
        Image(systemName: isStale ? "clock" : symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AgentRunLiveActivityTheme.primaryText)
            .accessibilityLabel(state.displayStatus(systemIsStale: systemIsStale))
    }

    private var symbol: String {
        switch state.status {
        case .starting, .thinking: "ellipsis"
        case .usingTool: "wrench"
        case .searchingFiles: "magnifyingglass"
        case .readingFiles: "doc.text"
        case .runningCommand: "terminal"
        case .responding: "text.bubble"
        case .waitingForApproval: "hand.raised"
        case .waitingForClarification: "questionmark.bubble"
        case .complete: "checkmark"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark"
        case .ended: "minus"
        }
    }
}

private enum AgentRunLiveActivityTheme {
    // Warm charcoal complements cream/sand. Both text tones retain >4.5:1
    // contrast on this surface and the black Dynamic Island.
    static let background = Color(red: 0.110, green: 0.102, blue: 0.094) // #1C1A18
    static let primaryText = Color(red: 0.957, green: 0.937, blue: 0.894) // #F4EFE4
    static let secondaryText = Color(red: 0.753, green: 0.706, blue: 0.643) // #C0B4A4
}
