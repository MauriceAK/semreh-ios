import SwiftUI

/// Conversations for one bot, backed by the real SessionListViewModel
/// (same store, same profile-scoped session loading as the full app).
/// Rename/delete are intentionally absent: SessionMutator is private to the
/// view model with no trivial external wrapper.
struct ConversationListView: View {
    let server: URL
    let profile: ProfileSummary
    @Binding var path: NavigationPath

    @State private var viewModel: SessionListViewModel
    @State private var isCreatingChat = false
    @State private var createErrorMessage: String?

    init(server: URL, profile: ProfileSummary, path: Binding<NavigationPath>) {
        self.server = server
        self.profile = profile
        self._path = path
        self._viewModel = State(initialValue: SessionListViewModel(server: server))
    }

    var body: some View {
        List {
            ForEach(viewModel.sessions) { session in
                Button {
                    path.append(PrototypeRoute.chat(session: session, profile: profile))
                } label: {
                    conversationRow(for: session)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .navigationTitle(profile.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await startNewChat() }
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .disabled(isCreatingChat)
            }
        }
        .task { await load() }
        .alert(
            "Couldn't start a new chat",
            isPresented: Binding(
                get: { createErrorMessage != nil },
                set: { if !$0 { createErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if let createErrorMessage {
                Text(createErrorMessage)
            }
        }
    }

    @MainActor
    private func load() async {
        _ = await viewModel.switchActiveProfile(profile)
        _ = await viewModel.load()
    }

    @MainActor
    private func startNewChat() async {
        guard !isCreatingChat else { return }
        isCreatingChat = true
        defer { isCreatingChat = false }
        guard let session = await NewChatFlow.createSession(profile: profile, in: viewModel) else {
            createErrorMessage = "The session store didn't return a session. Try again."
            return
        }
        path.append(PrototypeRoute.chat(session: session, profile: profile))
    }

    private func conversationRow(for session: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Self.displayTitle(for: session))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if let timestamp = Self.lastActivity(of: session) {
                    Text(Self.relativeFormatter.string(for: timestamp) ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let preview = previewText(for: session) {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func previewText(for session: SessionSummary) -> String? {
        guard let sessionID = Self.nonEmpty(session.sessionId) else { return nil }
        let identity = CachedSessionPreviewIdentity(
            profile: Self.nonEmpty(session.profile) ?? "default",
            sessionID: sessionID
        )
        let text = viewModel.cachedSessionPreviews[identity]?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    private static func displayTitle(for session: SessionSummary) -> String {
        nonEmpty(session.title) ?? "New Chat"
    }

    private static func lastActivity(of session: SessionSummary) -> Date? {
        guard let timestamp = session.lastMessageAt ?? session.updatedAt ?? session.createdAt else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
