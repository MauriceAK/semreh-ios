import SwiftUI

struct GitActionsMenuButton: View {
    let presentation: GitToolbarPresentation
    let isEnabled: Bool
    let writesDisabled: Bool
    let isRunningAction: Bool
    let onTap: () -> Void
    let onChanges: () -> Void
    let onStageEdit: () -> Void
    let onPush: () -> Void

    private var hasChanges: Bool {
        (presentation.status?.changedCount ?? 0) > 0
    }

    var body: some View {
        Menu {
            Section("Changes") {
                Button(action: onChanges) {
                    changesLabel
                }
                .disabled(!presentation.changesAreEnabled)

                Button(action: onStageEdit) {
                    Label("Stage Changes…", systemImage: "checklist")
                }
                .disabled(!presentation.changesAreEnabled || !hasChanges)
            }

            Section("Write") {
                HapticButton(feedbackStyle: .medium, action: onPush) {
                    Label("Push", systemImage: "arrow.up.circle")
                }
                .disabled(writesDisabled || isRunningAction)
            }

            Section {
                Text("Other Git work can be requested through chat.")
            }
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .frame(width: 24, height: 24)
        }
        .disabled(!isEnabled)
        .simultaneousGesture(TapGesture().onEnded(onTap))
        .frame(minWidth: 28, minHeight: 28)
        .accessibilityLabel("Git actions")
        .accessibilityValue(Text(presentation.accessibilityValue))
    }

    @ViewBuilder
    private var changesLabel: some View {
        if presentation.statusFailed {
            Label("Changes unavailable", systemImage: "exclamationmark.circle")
        } else if let status = presentation.status, status.changedCount > 0 {
            Label {
                Text("+\(status.totalAdditions)").foregroundStyle(.green)
                + Text("  −\(status.totalDeletions)").foregroundStyle(.red)
                + Text("  \(status.changedCount)").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "doc.text.magnifyingglass")
            }
        } else {
            Label("No changes", systemImage: "checkmark.circle")
        }
    }
}
