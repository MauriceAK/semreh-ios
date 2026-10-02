import SwiftUI

/// Chat-only prototype landing screen: the server's real profiles ("bots"),
/// bound to `APIClient.directProfiles()` exactly like AppShellBotsView.
struct BotListView: View {
    let server: URL
    @Binding var path: NavigationPath

    @State private var profiles: [ProfileSummary] = []
    @State private var isLoading = true
    @State private var apiError: Error?

    var body: some View {
        Group {
            if isLoading && profiles.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if profiles.isEmpty {
                ContentUnavailableView(
                    "No bots available",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(
                        apiError == nil
                            ? "The server returned no profiles."
                            : "Couldn't load profiles from the server."
                    )
                )
            } else {
                List(profiles) { profile in
                    Button {
                        path.append(PrototypeRoute.conversations(profile))
                    } label: {
                        HStack(spacing: 12) {
                            if let identity = BirdAvatarIdentity(server: server, profile: profile.name) {
                                BirdAvatarView(identity: identity)
                                    .frame(width: 40, height: 40)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.displayName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                if let model = Self.nonEmpty(profile.model) {
                                    Text(model)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Chats")
        .task { await load() }
    }

    @MainActor
    private func load() async {
        defer { isLoading = false }
        do {
            let response = try await APIClient(baseURL: server).directProfiles()
            profiles = AppShellBotCatalog.uniqueProfiles(response.profiles ?? [])
        } catch {
            apiError = error
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
