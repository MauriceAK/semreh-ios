import SwiftUI

struct DefaultModelPickerView: View {
    let server: URL
    let currentDefaultModel: String?
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var isLoading = false
    @State private var groups: [ModelCatalogGroup] = []
    @State private var defaultModel: String?
    @State private var customModel = ""
    @State private var selectedModel: String?
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var isSavingCustom = false
    @State private var saveError: String?
    @State private var profile: String?
    @State private var defaultProvider: String?
    @State private var customProvider: String?
    @State private var providerOptions: [String] = []
    @State private var selectedProvider: String?
    @State private var presentationGeneration = 0
    @State private var pendingConfirmation: PendingModelConfirmation?

    private struct PendingModelConfirmation {
        let model: String
        let provider: String
        let isCustom: Bool
        let expensive: Bool
        let message: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ModelPickerSearchField(text: $searchText)
                    Text("Applies to new sessions in the running profile. Existing chats keep their model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let profile {
                        Text("Profile: \(profile)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let saveError {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ModelPickerCard(title: String(localized: "Custom")) {
                        Picker("Provider", selection: $customProvider) {
                            ForEach(providerOptions, id: \.self) { provider in
                                Text(provider).tag(Optional(provider))
                            }
                        }
                        .disabled(isLoading || isSaving || pendingConfirmation != nil)
                        TextField("Custom model ID", text: $customModel)
                            .disabled(isSaving || pendingConfirmation != nil)
                            .font(.subheadline)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("Choose a provider and enter its bare model ID. For legacy @provider:model text, select that provider above and enter only the model ID.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ModelPickerButton(
                            String(localized: "Save Custom Model"),
                            isLoading: isSavingCustom
                        ) {
                            Task { await save(customModel, provider: customProvider, isCustom: true) }
                        }
                        .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving || isLoading || pendingConfirmation != nil || profile == nil || customProvider == nil)
                    }

                    modelListContent
                }
                .padding()
            }
            .navigationTitle("Default Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Refresh Models") { Task { await loadModels(refresh: true) } }
                        .disabled(isLoading || isSaving || pendingConfirmation != nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
            }
            .task {
                await loadModels(refreshAfterCached: true)
            }
            .interactiveDismissDisabled(isSaving)
            .onDisappear { presentationGeneration += 1 }
            .alert("Confirm Model Change", isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ), presenting: pendingConfirmation) { pending in
                Button("Confirm") {
                    pendingConfirmation = nil
                    Task { await save(pending.model, provider: pending.provider, isCustom: pending.isCustom,
                                      confirmedNous: true, confirmExpensive: pending.expensive) }
                }
                Button("Cancel", role: .cancel) { pendingConfirmation = nil }
            } message: { pending in
                Text(pending.message)
            }
        }
        .adaptiveFormPresentation()
    }

    @ViewBuilder
    private var modelListContent: some View {
        if isLoading && groups.isEmpty {
            ModelPickerCard(title: String(localized: "Models")) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading models...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let errorMessage, groups.isEmpty {
            ModelPickerCard(title: String(localized: "Models")) {
                Label("Could Not Load Models", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))

                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if filteredGroups.isEmpty {
            ModelPickerCard(title: String(localized: "Models")) {
                Label("No Matching Models", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))

                Text("Try a different model name or ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(filteredGroups) { group in
                ModelPickerCard(title: group.name) {
                    VStack(spacing: 0) {
                        ForEach(Array(group.models.enumerated()), id: \.element.id) { index, model in
                            modelRow(model)

                            if index < group.models.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var filteredGroups: [ModelCatalogGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return groups }

        return groups.compactMap { group in
            let matchingModels = group.models.filter { model in
                model.displayName.lowercased().contains(query)
                    || model.id.lowercased().contains(query)
                    || group.name.lowercased().contains(query)
            }

            guard !matchingModels.isEmpty else { return nil }
            return ModelCatalogGroup(
                id: group.id,
                name: group.name,
                providerID: group.providerID,
                models: matchingModels
            )
        }
    }

    private func modelRow(_ model: ModelCatalogOption) -> some View {
        Button {
            Task { await save(model.id, provider: model.providerID) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                    if !model.id.isEmpty && model.id != model.displayName {
                        Text(model.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    }
                }

                Spacer(minLength: 12)

                if isSaving && selectedModel == model.id && selectedProvider == model.providerID {
                    ProgressView()
                } else if model.id == defaultModel && model.providerID == defaultProvider {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving || isLoading || pendingConfirmation != nil || profile == nil)
        .accessibilityLabel(modelAccessibilityLabel(for: model))
        .accessibilityValue(model.id == defaultModel && model.providerID == defaultProvider ? "Selected" : "")
    }

    private func modelAccessibilityLabel(for model: ModelCatalogOption) -> String {
        guard !model.id.isEmpty, model.id != model.displayName else {
            return model.displayName
        }

        return "\(model.displayName), \(model.id)"
    }

    private func loadModels(refresh: Bool = false, refreshAfterCached: Bool = false) async {
        guard !isLoading else { return }
        let generation = presentationGeneration
        isLoading = true
        errorMessage = nil
        defer { if generation == presentationGeneration { isLoading = false } }
        do {
            let client = APIClient(baseURL: server)
            let scope: String
            if let profile {
                scope = profile
            } else {
                let active = try await client.directActiveProfile()
                guard let running = active.current?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !running.isEmpty else { throw DirectMainModelError.invalidSelection }
                scope = running
            }
            let response = try await client.directModelOptions(profile: scope, refresh: refresh)
            guard generation == presentationGeneration, !Task.isCancelled else { return }
            profile = scope
            applyCatalog(response)
            // Preserve the previous cached-first, fresh-on-open behavior.
            // Failure of the live catalog leaves the usable cached rows intact.
            if refreshAfterCached,
               let live = try? await client.directModelOptions(profile: scope, refresh: true) {
                guard generation == presentationGeneration, !Task.isCancelled, profile == scope else { return }
                applyCatalog(live)
            }
        } catch {
            guard generation == presentationGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func applyCatalog(_ response: DirectHermesModelOptions) {
        defaultModel = response.model
        defaultProvider = response.provider
        if customProvider == nil { customProvider = response.provider }
        var providers = (response.providers ?? []).filter { $0.authenticated != false }.compactMap(\.slug)
        if let customProvider, !providers.contains(customProvider) { providers.append(customProvider) }
        var seen = Set<String>()
        providerOptions = providers.filter { !$0.isEmpty && seen.insert($0).inserted }
        groups = response.catalogGroups
    }

    private func save(_ model: String, provider: String?, isCustom: Bool = false,
                      confirmedNous: Bool = false, confirmExpensive: Bool = false) async {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSaving, !isLoading, pendingConfirmation == nil, !trimmed.isEmpty,
              let provider, !provider.isEmpty, let profile else { return }
        if isCustom && trimmed.hasPrefix("@") {
            saveError = "Choose the provider above and enter only its model ID; legacy @provider:model syntax is not sent to Hermes."
            return
        }
        if provider.lowercased() == "nous" && !confirmedNous {
            pendingConfirmation = PendingModelConfirmation(model: trimmed, provider: provider,
                isCustom: isCustom, expensive: false,
                message: "Selecting Nous also lets Hermes configure currently unconfigured tools to use the Nous Tool Gateway. Existing explicit tool settings are preserved. Continue?")
            return
        }
        let generation = presentationGeneration
        isSaving = true
        isSavingCustom = isCustom
        saveError = nil
        selectedModel = trimmed
        selectedProvider = provider
        defer {
            if generation == presentationGeneration {
                isSaving = false
                isSavingCustom = false
            }
        }
        do {
            let result = try await APIClient(baseURL: server).directSetMainModel(
                profile: profile, provider: provider, model: trimmed, confirmExpensive: confirmExpensive)
            guard generation == presentationGeneration, !Task.isCancelled else { return }
            switch result {
            case .confirmationRequired(let message):
                pendingConfirmation = PendingModelConfirmation(model: trimmed, provider: provider,
                    isCustom: isCustom, expensive: true, message: message)
            case .confirmed(let model, let provider):
                defaultModel = model
                defaultProvider = provider
                onSave(model)
                dismiss()
            }
        } catch {
            guard generation == presentationGeneration, !Task.isCancelled else { return }
            saveError = error.localizedDescription
            selectedModel = nil
            selectedProvider = nil
            // A lost ACK/readback can follow a committed write. Reconcile by
            // reading the captured profile; never silently repeat the POST.
            await loadModels()
        }
    }

}

private struct ModelPickerSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search models", text: $text)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear model search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ModelPickerCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .textCase(.uppercase)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

private struct ModelPickerButton: View {
    let title: String
    var isLoading = false
    let action: () -> Void

    init(_ title: String, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    Text(title)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
