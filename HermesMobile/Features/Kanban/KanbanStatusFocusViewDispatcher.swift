import SwiftUI
import UIKit


extension KanbanStatusFocusView {
    var dispatcherSheet: some View {
        NavigationStack {
            ScrollView {
                dispatcherPanel
                    .padding()
            }
            .navigationTitle("Dispatcher")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsDispatcher = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .alert("Run Dispatcher", isPresented: $confirmsRunDispatcher) {
            Button("Cancel", role: .cancel) {}
            Button("Run Dispatcher", role: .destructive) {
                Task { await model.runDispatcher() }
            }
        } message: {
            Text(KanbanDispatchCopy.runConfirmation)
        }
    }

    var dispatcherPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    previewDispatchButton
                    runDispatcherButton
                }
                VStack(spacing: 8) {
                    previewDispatchButton
                        .frame(maxWidth: .infinity)
                    runDispatcherButton
                        .frame(maxWidth: .infinity)
                }
            }

            Text("Preview is advisory and may become stale. It never starts workers.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let dispatcherUnavailableReason,
               model.dispatchState?.phase.isInFlight != true {
                Text(dispatcherUnavailableReason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let dispatch = model.dispatchState {
                Divider()
                dispatchSummary(dispatch)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var previewDispatchButton: some View {
        Button("Preview Dispatch") {
            Task { await model.previewDispatch() }
        }
        .buttonStyle(.bordered)
        .disabled(model.dispatcherAvailability != .available)
        .frame(minHeight: 44)
    }

    var runDispatcherButton: some View {
        Button("Run Dispatcher") {
            confirmsRunDispatcher = true
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.dispatcherAvailability != .available)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    func dispatchSummary(_ dispatch: KanbanDispatchState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(dispatchModeTitle(dispatch.mode))
                    .font(.subheadline.weight(.semibold))
                if let completedAt = dispatch.completedAt {
                    Text(completedAt, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !dispatch.phase.isInFlight, dispatch.phase != .outcomeUncertain {
                    Button("Dismiss") { model.dismissDispatchResult() }
                        .font(.footnote)
                }
            }

            if dispatch.phase.isInFlight {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(String(localized: dispatch.phase.statusTitle))
                }
                .font(.footnote)
            } else {
                Label {
                    Text(String(localized: dispatch.phase.statusTitle))
                } icon: {
                    Image(systemName: dispatchStatusIcon(dispatch))
                }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(dispatchStatusColor(dispatch))
            }

            if model.isPreviewStale {
                Label("This Preview is stale. Run Preview Dispatch again before relying on it.", systemImage: "clock.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if let result = dispatch.result {
                dispatchMetrics(result)
            }

            if dispatch.phase == .outcomeUncertain {
                Text("Semreh refreshed the Board, but cannot prove whether workers started. Review the current Board before running Dispatcher again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if dispatch.canAcknowledgeUncertainOutcome {
                    Button("I Reviewed the Board") {
                        model.dismissDispatchResult()
                    }
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 44)
                }
                Button("Refresh") {
                    Task { await model.refreshUncertainDispatchOutcome() }
                }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
            } else if dispatch.phase == .refused {
                Text("The server refused this Dispatcher request. Semreh did not retry it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if dispatch.phase == .boardUnavailable {
                Text("This Board no longer exists. Choose another Board.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(KanbanDispatchAccessibility.summary(dispatch, isStale: model.isPreviewStale))
        )
        .accessibilityFocused($dispatchSummaryIsFocused)
    }

    func dispatchMetrics(_ result: KanbanDispatchResult) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
            dispatchMetricRow("Spawned", result.spawned, "Promoted", result.promoted)
            dispatchMetricRow("Reclaimed", result.reclaimed, "Skipped—No Assignee", result.skippedUnassigned)
            dispatchMetricRow("Skipped—Unknown Profile", result.skippedNonspawnable, "Auto-blocked", result.autoBlocked)
            dispatchMetricRow("Timed Out", result.timedOut, "Crashed", result.crashed)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    func dispatchMetricRow(
        _ firstLabel: LocalizedStringKey,
        _ firstCount: Int?,
        _ secondLabel: LocalizedStringKey,
        _ secondCount: Int?
    ) -> some View {
        GridRow {
            dispatchMetric(firstLabel, firstCount)
            dispatchMetric(secondLabel, secondCount)
        }
    }

    func dispatchMetric(_ label: LocalizedStringKey, _ count: Int?) -> some View {
        HStack(spacing: 4) {
            Text(label)
            Text(count.map(String.init) ?? String(localized: "Unknown"))
                .fontWeight(.semibold)
        }
    }

    var dispatcherUnavailableReason: LocalizedStringKey? {
        switch model.dispatcherAvailability {
        case .available: nil
        case .busy: "Another Board action is in progress."
        case .outcomeUncertain: "Outcome Uncertain"
        case .offline: "Offline—showing previously loaded data"
        case .incompatible: "Dispatcher is unavailable on this server."
        case .readOnly: "Read-only"
        case .refreshing: "The Board is refreshing."
        case .refreshFailed: "Refresh failed. Try again before using Dispatcher."
        }
    }

    func dispatchModeTitle(_ mode: KanbanDispatchMode) -> LocalizedStringKey {
        switch mode {
        case .preview: "Preview Dispatch"
        case .run: "Run Dispatcher"
        }
    }

    func dispatchStatusIcon(_ dispatch: KanbanDispatchState) -> String {
        switch dispatch.phase {
        case .succeeded: model.isPreviewStale ? "clock.badge.exclamationmark" : "checkmark.circle.fill"
        case .submitting, .reconciling: "arrow.triangle.2.circlepath"
        case .refused, .failed: "xmark.circle.fill"
        case .outcomeUncertain, .boardUnavailable: "questionmark.circle.fill"
        }
    }

    func dispatchStatusColor(_ dispatch: KanbanDispatchState) -> Color {
        switch dispatch.phase {
        case .succeeded: model.isPreviewStale ? .orange : .green
        case .submitting, .reconciling: .secondary
        case .refused, .failed: .red
        case .outcomeUncertain, .boardUnavailable: .orange
        }
    }
}
