import SwiftUI

struct SkillsView: View {
    let server: URL
    let profile: String
    let onAPIError: (Error) -> Void

    @State private var viewModel: SkillsViewModel
    @State private var selectedSkill: SkillSummary?
    @State private var searchText = ""

    init(server: URL, profile: String, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.profile = profile
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: SkillsViewModel(server: server, profile: profile))
    }

    var body: some View {
        content
            .background { SemrehBackdrop().ignoresSafeArea() }
            .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            .navigationTitle("Skills")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadSkills() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .task {
                await loadSkills()
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search skills...")
    }

    private var filteredGroups: [(category: String, skills: [SkillSummary])] {
        viewModel.filteredGroupedSkills(searchText: searchText)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.skills.isEmpty {
            ProgressView("Loading skills...")
        } else if let errorMessage = viewModel.errorMessage, viewModel.skills.isEmpty {
            ContentUnavailableView {
                Label("Could Not Load Skills", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await loadSkills() }
                }
            }
        } else if viewModel.skills.isEmpty {
            ContentUnavailableView {
                Label("No Skills", systemImage: "hammer")
            } description: {
                Text("Skills from the Hermes server will appear here.")
            }
        } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filteredGroups.isEmpty {
            ContentUnavailableView {
                Label("No Results", systemImage: "magnifyingglass")
            } description: {
                Text("No skills match \"\(searchText)\".")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(filteredGroups, id: \.category) { group in
                        SkillCategorySection(
                            category: group.category,
                            skills: group.skills,
                            server: server,
                            profile: profile,
                            togglingSkillNames: viewModel.togglingSkillNames,
                            onToggleSkill: { skill, enabled in
                                await toggle(skill: skill, enabled: enabled)
                            },
                            onAPIError: onAPIError
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable {
                await loadSkills()
            }
            .background(Color.clear)
        }
    }

    private func loadSkills() async {
        await viewModel.load()
        if let error = viewModel.lastError {
            onAPIError(error)
        }
    }

    private func toggle(skill: SkillSummary, enabled: Bool) async {
        await viewModel.setSkill(skill, enabled: enabled)
        if let error = viewModel.lastError {
            onAPIError(error)
        }
    }
}

private struct SkillCategorySection: View {
    let category: String
    let skills: [SkillSummary]
    let server: URL
    let profile: String
    let togglingSkillNames: Set<String>
    let onToggleSkill: (SkillSummary, Bool) async -> Void
    let onAPIError: (Error) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category)
                .textCase(.uppercase)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(skills.enumerated()), id: \.offset) { index, skill in
                    NavigationLink {
                        SkillDetailView(
                            skill: skill,
                            server: server,
                            profile: profile,
                            onAPIError: onAPIError
                        )
                    } label: {
                        SkillRow(
                            skill: skill,
                            isToggling: isToggling(skill),
                            onToggle: canToggle(skill) ? { enabled in
                                Task { await onToggleSkill(skill, enabled) }
                            } : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .opacity(skill.disabled == true ? 0.55 : 1)
                    .contextMenu {
                        if canToggle(skill) {
                            let isDisabled = skill.disabled == true
                            Button {
                                Task { await onToggleSkill(skill, isDisabled) }
                            } label: {
                                Label(isDisabled ? "Enable" : "Disable", systemImage: isDisabled ? "checkmark.circle" : "pause.circle")
                            }
                            .disabled(isToggling(skill))
                        }
                    }

                    if index < skills.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func canToggle(_ skill: SkillSummary) -> Bool {
        guard skill.disabled != nil else { return false }
        let name = skill.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(name ?? "").isEmpty
    }

    private func isToggling(_ skill: SkillSummary) -> Bool {
        guard let name = skill.name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return togglingSkillNames.contains(name)
    }
}

private struct SkillRow: View {
    let skill: SkillSummary
    var isToggling: Bool = false
    var onToggle: ((Bool) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if skill.disabled == true || !tags.isEmpty {
                    HStack(spacing: 6) {
                        if skill.disabled == true {
                            Text("Disabled")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .foregroundStyle(.secondary)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }

                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .foregroundStyle(.secondary)
                                .background(Color(.secondarySystemFill).opacity(0.8), in: Capsule())
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            if let onToggle {
                Toggle(skill.disabled == true ? "Enable" : "Disable", isOn: Binding(
                    get: { skill.disabled != true },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .scaleEffect(0.8, anchor: .trailing)
                .disabled(isToggling)
                .padding(.top, 6)
            }

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let onToggle {
                Button(skill.disabled == true ? "Enable" : "Disable") {
                    guard !isToggling else { return }
                    onToggle(skill.disabled == true)
                }
            }
        }
    }

    private var displayName: String {
        let name = skill.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else {
            return String(localized: "Unnamed Skill")
        }
        return name
    }

    private var description: String? {
        let text = skill.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private var tags: [String] {
        (skill.tags ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct SkillDetailView: View {
    let skill: SkillSummary
    let server: URL
    let profile: String
    let onAPIError: (Error) -> Void

    @State private var detail: SkillDetailResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        content
            .background { SemrehBackdrop().ignoresSafeArea() }
            .navigationTitle(skill.name ?? String(localized: "Skill"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadDetail() }
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoading)
                }
            }
            .task {
                await loadDetail()
            }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && detail == nil {
            ProgressView("Loading skill...")
        } else if let errorMessage, detail == nil {
            ContentUnavailableView {
                Label("Could Not Load Skill", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await loadDetail() }
                }
            }
        } else if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let content = detail.content, !content.isEmpty {
                        MarkdownRenderer(content: content)
                            .padding(.horizontal)
                    }

                }
                .padding(.vertical)
            }
        } else {
            ContentUnavailableView {
                Label("No Content", systemImage: "doc.text")
            } description: {
                Text("This skill has no content.")
            }
        }
    }

    private func loadDetail() async {
        guard let name = skill.name else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await APIClient(baseURL: server).directSkillContent(name: name, profile: profile)
            detail = response
        } catch {
            errorMessage = error.localizedDescription
            onAPIError(error)
        }
    }

}
