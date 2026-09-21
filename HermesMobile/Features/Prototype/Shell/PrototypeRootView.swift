import SwiftUI

/// Chat-only prototype navigation: bot list → conversation list → chat.
///
/// Deep links, App Intents, and share-extension imports are not routed in
/// prototype mode; ContentView still owns them for the full app.
enum PrototypeRoute: Hashable {
    case conversations(ProfileSummary)
    case chat(session: SessionSummary, profile: ProfileSummary)
}

struct PrototypeRootView: View {
    @Bindable var authManager: AuthManager
    let server: URL

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            BotListView(server: server, path: $path)
                .navigationDestination(for: PrototypeRoute.self) { route in
                    switch route {
                    case .conversations(let profile):
                        ConversationListView(server: server, profile: profile, path: $path)
                    case .chat(let session, let profile):
                        PrototypeChatView(session: session, profile: profile)
                            .environment(\.protoChatServerURL, server)
                    }
                }
        }
    }
}
