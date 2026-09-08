import SwiftUI

/// Bounded staging sheet. Commit generation/creation and destructive discard are
/// deferred until stock Hermes can preserve the app's prior semantics.
struct GitCommitView: View {
    private let session: SessionSummary
    private let server: URL
    let writesDisabled: Bool
    let onAPIError: (Error) -> Void

    @State private var viewModel: GitCommitViewModel
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @Environment(\.dismiss) private var dismiss

    init(
        session: SessionSummary,
        server: URL,
        writesDisabled: Bool,
        onAPIError: @escaping (Error) -> Void
    ) {
        self.session = session
        self.server = server
        self.writesDisabled = writesDisabled
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: GitCommitViewModel(session: session, server: server))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Stage Changes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task {
                    await viewModel.load()
                    if let error = viewModel.lastError { onAPIError(error) }
                }
        }
        .presentationDetents([.large])
        .adaptivePagePresentation()
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.status == nil {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.loadErrorMessage != nil && viewModel.status == nil {
            ContentUnavailableView {
                Label("Could Not Load Changes", systemImage: "exclamationmark.triangle")
            } description: {
                if let detail = viewModel.loadErrorMessage { Text(detail) }
            } actions: {
                Button("Try Again") { Task { await viewModel.load() } }
            }
        } else if !viewModel.hasChanges {
            emptyState
        } else {
            fileList
        }
    }

    /// Surface any staging error even when the working tree has no visible rows.
    @ViewBuilder
    private var emptyState: some View {
        if let error = viewModel.actionErrorMessage {
            ContentUnavailableView {
                Label("Git Action Needs Attention", systemImage: "exclamationmark.icloud")
            } description: {
                Text(error)
            }
        } else {
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text("Your working tree is clean.")
            )
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                batchActionsBar

                if let error = viewModel.actionErrorMessage ?? viewModel.loadErrorMessage {
                    Text(error)
                        .font(AppFont.footnote())
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("git-staging-error")
                }

                Text("Commit, discard, and other Git work can be requested through chat.")
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)

                ForEach(viewModel.trackedFiles) { file in
                    GitCommitFileRow(
                        file: file,
                        isSelected: viewModel.isSelected(file),
                        onTap: { viewModel.toggleSelection(file) }
                    )
                }

                if viewModel.status?.truncated == true {
                    Text("Showing first 500 changed files.")
                        .font(AppFont.footnote())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }
            }
            .padding(16)
        }
        .refreshable { await viewModel.load() }
    }

    private var batchActionsBar: some View {
        HStack(spacing: 8) {
            Text(viewModel.hasSelection
                ? "\(viewModel.selectedPaths.count) selected"
                : "All changes")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            batchButton("Stage", systemImage: "plus.circle", running: viewModel.busyOperation == .staging) {
                Task { await viewModel.stageSelectedOrAll() }
            }
            batchButton("Unstage", systemImage: "minus.circle", running: viewModel.busyOperation == .unstaging) {
                Task { await viewModel.unstageSelectedOrAll() }
            }
        }
    }

    private func batchButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        running: Bool,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role) {
            HapticButtonHaptics.tap(isEnabled: isHapticsEnabled)
            action()
        } label: {
            HStack(spacing: 4) {
                if running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(AppFont.caption(weight: .semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(writesDisabled || viewModel.isBusy)
    }

}

/// One selectable changed-file row in the staging sheet, showing a selection checkbox,
/// the file name + path, diff counts, and whether it is currently staged.
private struct GitCommitFileRow: View {
    let file: GitFile
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(file.fileName)
                        .font(AppFont.subheadline(weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let parent = file.parentDirectory {
                        Text(parent)
                            .font(AppFont.mono(style: .caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 6)

                if file.staged == true {
                    Text("Staged")
                        .font(AppFont.caption2(weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                }
                DiffCountsLabel(additions: file.additions ?? 0, deletions: file.deletions ?? 0)
                GitStatusChip(kind: file.changeKind)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color(.separator).opacity(0.35), lineWidth: isSelected ? 1 : 0.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
