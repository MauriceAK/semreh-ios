import SwiftUI

/// Device-local workspace bookmark management. Paths remain references only:
/// this sheet never creates, moves, verifies, or deletes server files.
struct WorkspaceManagerView: View {
    @State private var viewModel: WorkspaceRegistryViewModel

    /// Called when the sheet disappears after at least one successful mutation,
    /// so the presenting surface can refresh its own copy of the registry.
    private let onRegistryChanged: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showsAddSheet = false
    @State private var renameTargetPath: String?
    @State private var renameText = ""

    init(server: URL, profile: String, onRegistryChanged: @escaping () async -> Void) {
        _viewModel = State(initialValue: WorkspaceRegistryViewModel(server: server, profile: profile))
        self.onRegistryChanged = onRegistryChanged
    }

    init(viewModel: WorkspaceRegistryViewModel, onRegistryChanged: @escaping () async -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.onRegistryChanged = onRegistryChanged
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !viewModel.rows.isEmpty {
                    Section {
                        ForEach(viewModel.rows, id: \.path) { workspace in
                            // moveDisabled/deleteDisabled block new drags and
                            // swipe-deletes while a mutation is in flight:
                            // actor reentrancy across the network await would
                            // otherwise let overlapping mutations race (the
                            // view model's generation guard is the second
                            // line of defense).
                            workspaceRow(workspace)
                                .moveDisabled(viewModel.isMutating)
                                .deleteDisabled(viewModel.isMutating)
                        }
                        .onMove { source, destination in
                            Task {
                                await viewModel.moveWorkspaces(fromOffsets: source, toOffset: destination)
                            }
                        }
                        .onDelete { offsets in
                            guard let index = offsets.first, viewModel.rows.indices.contains(index) else { return }
                            viewModel.requestRemoval(of: viewModel.rows[index])
                        }
                    } footer: {
                        Text("Bookmarks are saved on this device. Removing one does not delete files or change Hermes.")
                    }
                } else if !viewModel.isLoading {
                    ContentUnavailableView {
                        Label("No Workspaces", systemImage: "folder")
                    } description: {
                        Text("Add a workspace to make it available when starting sessions.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { SemrehBackdrop().ignoresSafeArea() }
            .navigationTitle("Manage Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                        .disabled(viewModel.rows.isEmpty)

                    Button {
                        showsAddSheet = true
                    } label: {
                        Label("Add Workspace", systemImage: "plus")
                    }
                    .disabled(viewModel.isMutating)
                }
            }
            .overlay {
                if viewModel.isLoading && viewModel.rows.isEmpty {
                    ProgressView()
                }
            }
            .task {
                await viewModel.load()
            }
            .sheet(isPresented: $showsAddSheet) {
                WorkspaceAddSheet(viewModel: viewModel)
            }
            .alert(
                "Rename Workspace",
                isPresented: renameAlertBinding
            ) {
                TextField("Workspace name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    renameTargetPath = nil
                }
                Button("Save") {
                    let path = renameTargetPath
                    let name = renameText
                    renameTargetPath = nil
                    guard let path else { return }
                    Task {
                        await viewModel.renameWorkspace(path: path, to: name)
                    }
                }
            }
            .confirmationDialog(
                "Remove Workspace?",
                isPresented: removalDialogBinding,
                titleVisibility: .visible,
                presenting: viewModel.pendingRemoval
            ) { workspace in
                // `presenting:` hands the staged workspace to this closure at
                // presentation time — the dismissal binding clears
                // `pendingRemoval` before this async task runs, so the target
                // must not be re-read from the view model here.
                Button("Remove", role: .destructive) {
                    Task { @MainActor in
                        await viewModel.confirmRemoval(of: workspace)
                    }
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cancelPendingRemoval()
                }
            } message: { _ in
                Text("Removing this device-local bookmark does not delete files or change Hermes.")
            }
            .onDisappear {
                guard viewModel.didMutateRegistry else { return }
                Task {
                    await onRegistryChanged()
                }
            }
        }
        .adaptiveFormPresentation()
    }

    private func workspaceRow(_ workspace: WorkspaceRoot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayName(for: workspace))
                .font(.body)

            if let path = workspace.path {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                renameText = workspace.name ?? ""
                renameTargetPath = workspace.path
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
            .disabled(viewModel.isMutating)
        }
    }

    private func displayName(for workspace: WorkspaceRoot) -> String {
        if let name = workspace.name, !name.isEmpty {
            return name
        }
        return workspace.path?.lastPathComponentFallback ?? ""
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTargetPath != nil },
            set: { isPresented in
                if !isPresented {
                    renameTargetPath = nil
                }
            }
        )
    }

    private var removalDialogBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.cancelPendingRemoval()
                }
            }
        )
    }
}

/// Adds a device-local path bookmark. The path is not verified or created.
private struct WorkspaceAddSheet: View {
    let viewModel: WorkspaceRegistryViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var name = ""
    @State private var suggestions: [String] = []
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Workspace path", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Name (optional)", text: $name)

                } footer: {
                    Text("This saves a bookmark only. It does not verify or create the folder on the Hermes host.")
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !filteredSuggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(filteredSuggestions, id: \.self) { suggestion in
                            Button {
                                path = suggestion
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(Color(.secondaryLabel))
                                    Text(suggestion)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { SemrehBackdrop().ignoresSafeArea() }
            .navigationTitle("Add Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        submit()
                    }
                    .disabled(trimmedPath.isEmpty || isSubmitting)
                }
            }
            .task(id: path) {
                if !path.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                }
                suggestions = await viewModel.loadSuggestions(prefix: path)
            }
        }
        .adaptiveFormPresentation()
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredSuggestions: [String] {
        var seen = Set<String>()
        return suggestions.filter { !$0.isEmpty && $0 != trimmedPath && seen.insert($0).inserted }
    }

    private func submit() {
        guard !trimmedPath.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            let succeeded = await viewModel.addWorkspace(path: trimmedPath, name: name)
            isSubmitting = false
            if succeeded {
                dismiss()
            }
        }
    }
}
