import SwiftUI
import UIKit


struct KanbanBoardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: KanbanFeatureState
    let mode: KanbanBoardEditorMode
    @State private var slug: String
    @State private var name: String
    @State private var description: String
    @State private var icon: String
    @State private var color: String
    @State private var showsSlugError = false
    @State private var showsNameError = false

    init(model: KanbanFeatureState, mode: KanbanBoardEditorMode) {
        self.model = model
        self.mode = mode
        switch mode {
        case .create:
            _slug = State(initialValue: "")
            _name = State(initialValue: "")
            _description = State(initialValue: "")
            _icon = State(initialValue: "")
            _color = State(initialValue: "")
        case let .edit(board):
            _slug = State(initialValue: board.slug ?? "")
            _name = State(initialValue: board.name ?? "")
            _description = State(initialValue: board.description ?? "")
            _icon = State(initialValue: board.icon ?? "")
            _color = State(initialValue: board.color ?? "")
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Slug", text: $slug)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isEditing)
                    .accessibilityHint(Text("The slug cannot be changed after the Board is created."))
                if showsSlugError {
                    Text("Required")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField("Name", text: $name)
                if showsNameError {
                    Text("Required")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Icon", text: $icon)
                TextField("Color", text: $color)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Creating a Board does not make it active.")
            }

            if let mutation = model.boardMutationState,
               mutation.kind.slug == slug,
               mutation.phase == .failed || mutation.phase == .outcomeUncertain {
                Section {
                    Text(mutation.phase == .failed ? "Failed" : "Outcome Uncertain")
                        .foregroundStyle(.red)
                    Text("Refresh the Board before trying again.")
                        .font(.footnote)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { SemrehBackdrop().ignoresSafeArea() }
        .navigationTitle(isEditing ? "Edit" : "Create")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { submit() }
                    .disabled(!model.canManageBoards)
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    private func submit() {
        let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        showsSlugError = trimmedSlug.isEmpty
        showsNameError = trimmedName.isEmpty
        guard !showsSlugError, !showsNameError else { return }
        Task {
            if isEditing {
                await model.editBoard(KanbanEditBoardRequest(
                    slug: trimmedSlug,
                    name: trimmedName,
                    description: description,
                    icon: icon,
                    color: color
                ))
            } else {
                await model.createBoard(KanbanCreateBoardRequest(
                    slug: trimmedSlug,
                    name: trimmedName,
                    description: description,
                    icon: icon,
                    color: color
                ))
            }
            if model.boardMutationState?.phase == .succeeded {
                dismiss()
            }
        }
    }
}

struct KanbanBulkActionsView: View {
    @Environment(\.dismiss) private var dismiss
    let model: KanbanFeatureState
    let onArchive: () -> Void
    let onFinished: () -> Void
    @State private var status = "todo"
    @State private var profile: String?
    @State private var priority = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(KanbanCountFormatter.cards(model.selectedCardCount))
                        .font(.headline)
                }

                Section("Change Status") {
                    Picker("Status", selection: $status) {
                        ForEach(statusOptions, id: \.self) { value in
                            Text(KanbanStatusPresentation(value).title).tag(value)
                        }
                    }
                    Button("Change Status") {
                        submit(.changeStatus(status))
                    }
                    .disabled(!model.canSubmitBulkAction(.changeStatus(status)))
                    .frame(minHeight: 44)
                }

                Section("Assign Profile") {
                    Picker("Profile", selection: $profile) {
                        Text("Unassigned").tag(String?.none)
                        ForEach(model.profileOptions, id: \.self) { value in
                            Text(value).tag(Optional(value))
                        }
                    }
                    Button("Assign Profile") {
                        submit(.assignProfile(profile))
                    }
                    .disabled(!model.canSubmitBulkAction(.assignProfile(profile)))
                    .frame(minHeight: 44)
                }

                Section("Set Priority") {
                    Stepper(value: $priority, in: -100...100) {
                        HStack {
                            Text("Priority")
                            Text(verbatim: "\(priority)")
                        }
                    }
                    Button("Set Priority") {
                        submit(.setPriority(priority))
                    }
                    .disabled(!model.canSubmitBulkAction(.setPriority(priority)))
                    .frame(minHeight: 44)
                }

                Section {
                    Button("Archive Cards", role: .destructive) {
                        onArchive()
                    }
                    .disabled(!model.canSubmitBulkAction(.archiveCards))
                    .frame(minHeight: 44)
                }
            }
            .scrollContentBackground(.hidden)
            .background { SemrehBackdrop().ignoresSafeArea() }
            .navigationTitle("Bulk Actions")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.bulkActionPhase != nil)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.bulkActionPhase != nil)
                }
            }
        }
    }

    private var statusOptions: [String] {
        (model.configuration?.columns ?? []).filter { $0 != "running" }
    }

    private func submit(_ action: KanbanBulkAction) {
        Task {
            await model.performBulkAction(action)
            onFinished()
        }
    }
}

struct KanbanFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    let model: KanbanFeatureState
    @State private var draft: KanbanFiltersDraft

    init(model: KanbanFeatureState) {
        self.model = model
        _draft = State(initialValue: KanbanFiltersDraft(model: model))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    Picker("Assigned Profile", selection: $draft.profile) {
                        Text("All Profiles").tag(String?.none)
                        ForEach(model.profileOptions, id: \.self) { value in
                            Text(value).tag(Optional(value))
                        }
                    }
                    .disabled(draft.onlyMine)
                    Toggle("Only Mine", isOn: $draft.onlyMine)
                        .onChange(of: draft.onlyMine) { _, enabled in
                            if enabled { draft.profile = nil }
                        }
                }

                Section("Tenant") {
                    Picker("Tenant", selection: $draft.tenant) {
                        Text("All Tenants").tag(String?.none)
                        ForEach(model.tenantOptions, id: \.self) { value in
                            Text(value).tag(Optional(value))
                        }
                    }
                }

                Section("Archived Cards") {
                    Toggle("Include Archived Cards", isOn: $draft.includesArchived)
                }

                Section("Display") {
                    Toggle("Group by Profile", isOn: $draft.groupsByProfile)
                }

                if model.hasActiveFilters {
                    Section {
                        Button("Clear Filters", role: .destructive) {
                            Task {
                                await model.clearFilters()
                                dismiss()
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { SemrehBackdrop().ignoresSafeArea() }
            .navigationTitle("Card Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        Task {
                            await draft.apply(to: model)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
