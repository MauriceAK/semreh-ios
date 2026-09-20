import SwiftUI
import UIKit


extension KanbanStatusFocusView {
    var boardSelectionContent: some View {
        ContentUnavailableView {
            Label(
                model.boardSelectionNotice?.boardName ?? String(localized: "Board"),
                systemImage: "rectangle.stack.badge.minus"
            )
        } description: {
            Text("This Board no longer exists. Choose another Board.")
        } actions: {
            Menu("Choose Board") {
                ForEach(model.boards, id: \.slug) { board in
                    if let slug = board.slug {
                        Button(board.name ?? slug) {
                            Task { await model.selectBoard(slug) }
                        }
                    }
                }
            }
            .frame(minHeight: 44)
        }
    }

    var bulkProgressBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(model.bulkActionPhase == .submitting ? "Updating task..." : "Checking Result")
                .font(.footnote)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.secondary.opacity(0.1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(model.bulkActionPhase == .submitting ? "Updating task..." : "Checking Result")
        )
    }

    func bulkSummaryBanner(_ summary: KanbanBulkActionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    summary.needsAttention.isEmpty ? "Complete" : "Needs Attention",
                    systemImage: summary.needsAttention.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.footnote.weight(.semibold))
                Spacer()
                Button("Dismiss") { model.dismissBulkActionSummary() }
                    .font(.footnote)
            }
            HStack(spacing: 12) {
                Label {
                    HStack(spacing: 3) {
                        Text(verbatim: "\(summary.succeededCount)")
                        Text("Complete")
                    }
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                Label {
                    HStack(spacing: 3) {
                        Text(verbatim: "\(summary.failedCount)")
                        Text("Failed")
                    }
                } icon: {
                    Image(systemName: "xmark.circle")
                }
                Label {
                    HStack(spacing: 3) {
                        Text(verbatim: "\(summary.uncertainCount)")
                        Text("Outcome Uncertain")
                    }
                } icon: {
                    Image(systemName: "questionmark.circle")
                }
            }
            .font(.footnote)
            if !summary.needsAttention.isEmpty {
                ForEach(summary.needsAttention) { member in
                    Label {
                        HStack(spacing: 4) {
                            Text(member.cardTitle)
                            Text(member.outcome == .failed ? "Failed" : "Outcome Uncertain")
                        }
                    } icon: {
                        Image(systemName: member.outcome == .failed ? "xmark.circle" : "questionmark.circle")
                    }
                    .font(.footnote)
                }
            }
            if model.canRetryFailedBulkAction {
                Button("Retry Failed") {
                    Task {
                        await model.retryFailedBulkAction()
                        bulkSummaryIsFocused = true
                    }
                }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(summary.needsAttention.isEmpty ? Color.green.opacity(0.1) : Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(KanbanBulkAccessibility.resultLabel(summary))
        .accessibilityFocused($bulkSummaryIsFocused)
    }

    var selectionControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(KanbanCountFormatter.cards(model.selectedCardCount))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityLabel(
                        Text(KanbanCountFormatter.cards(model.selectedCardCount))
                        + Text(", ")
                        + Text("Selected")
                    )
                Spacer()
                Button("Bulk Actions") { showsBulkActions = true }
                    .disabled(model.bulkActionsAvailability != .available)
                    .fontWeight(.semibold)
                    .frame(minHeight: 44)
                Button("Done") {
                    model.clearCardSelection()
                }
                .frame(minHeight: 44)
            }
            if let explanation = bulkDisabledExplanation {
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.secondary.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityFocused($selectionControlsAreFocused)
    }

    private var bulkDisabledExplanation: String? {
        switch model.bulkActionsAvailability {
        case .available: nil
        case .noSelection: nil
        case .offline: String(localized: "Offline—showing previously loaded data")
        case .incompatible: String(localized: "Unavailable")
        case .readOnly: String(localized: "Read-only")
        case .refreshing: String(localized: "The Board is refreshing.")
        case .boardBusy: String(localized: "Updating task...")
        case .invalidSelection: String(localized: "The selection is no longer available. Refresh the Board and select the Cards again.")
        case .unknownStatus: String(localized: "Unknown Status")
        }
    }

    func archiveUndoBanner(_ undo: KanbanArchiveUndo) -> some View {
        let recoveryPhase = model.mutationState(for: undo.cardID)?.phase
        let statusText = recoveryPhase == .outcomeUncertain
            ? String(localized: "Outcome Uncertain")
            : recoveryPhase == .failed
                ? String(localized: "Update failed")
                : String(localized: "Archived")
        let hasRecoveryError = recoveryPhase == .outcomeUncertain || recoveryPhase == .failed
        return HStack {
            Label(
                statusText,
                systemImage: hasRecoveryError ? "exclamationmark.circle" : "archivebox"
            )
                .lineLimit(2)
            Spacer()
            if recoveryPhase == .outcomeUncertain {
                Button("Refresh") {
                    Task { await model.checkUncertainMutation(for: undo.card) }
                }
                .fontWeight(.semibold)
            } else {
                Button(recoveryPhase == .failed ? "Try Again" : "Undo") {
                    Task { await model.undoArchive() }
                }
                .fontWeight(.semibold)
            }
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                String.localizedStringWithFormat(
                    String(localized: "%@, %@"),
                    undo.cardTitle,
                    statusText
                )
            )
        )
        .accessibilityFocused($archiveUndoIsFocused)
    }

    var offlineBanner: some View {
        Label("Offline—showing previously loaded data", systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12))
            .accessibilityLabel(Text("Offline—showing previously loaded data"))
    }

    var liveUpdatesDelayedBanner: some View {
        Label("Live updates delayed", systemImage: "arrow.clockwise.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.08))
            .accessibilityLabel(Text("Live updates delayed"))
    }

    var compatibilityBanner: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kanban is available with limited capabilities.")
                if !model.unavailableWriteCapabilities.isEmpty {
                    Text("Unavailable")
                        + Text(verbatim: ": ")
                        + Text(verbatim: unavailableWriteCapabilityNames)
                }
            }
            .font(.footnote)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }

    private var unavailableWriteCapabilityNames: String {
        KanbanWriteCapability.allCases
            .filter(model.unavailableWriteCapabilities.contains)
            .map(\.title)
            .joined(separator: ", ")
    }

    var refreshErrorBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("Could not refresh this Board. Previously loaded Cards remain visible.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
            Spacer(minLength: 4)
            Button("Try Again") { Task { await model.refresh() } }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.red.opacity(0.1))
    }
}
