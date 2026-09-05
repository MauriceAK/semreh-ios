import SwiftUI
import SwiftData

struct SemrehSceneActions {
    let canCreateNewChat: Bool
    let createNewChat: () -> Void
    let searchSessions: () -> Void
}

private struct SemrehSceneActionsKey: FocusedValueKey {
    typealias Value = SemrehSceneActions
}

extension FocusedValues {
    var hermexSceneActions: SemrehSceneActions? {
        get { self[SemrehSceneActionsKey.self] }
        set { self[SemrehSceneActionsKey.self] = newValue }
    }
}

struct SemrehCommands: Commands {
    @FocusedValue(\.hermexSceneActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                actions?.createNewChat()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(actions?.canCreateNewChat != true)
        }

        CommandGroup(after: .newItem) {
            Button("Search Sessions") {
                actions?.searchSessions()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(actions == nil)
        }
    }
}

@main
struct HermesMobileApp: App {
    @State private var authManager = AuthManager()
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // Launch argument hooks for deterministic, server-free simulator diagnosis:
            // `xcrun simctl launch <udid> com.jacobmoore.semreh --streaming-lab`
            // `xcrun simctl launch <udid> com.jacobmoore.semreh --chat-performance-lab`
            // `xcrun simctl launch <udid> com.jacobmoore.semreh --sidebar-brand-lab`
            if ProcessInfo.processInfo.arguments.contains("--chat-performance-lab") {
                NavigationStack {
                    ChatPerformanceLabView()
                }
                .semrehAppTheme()
            } else if ProcessInfo.processInfo.arguments.contains("--chat-performance-multi-lab") {
                NavigationStack {
                    ChatPerformanceMultiLabView()
                }
                .semrehAppTheme()
            } else if ProcessInfo.processInfo.arguments.contains("--sidebar-brand-lab") {
                SidebarBrandLabView()
                    .semrehAppTheme()
                    .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
            } else if ProcessInfo.processInfo.arguments.contains("--streaming-lab") {
                NavigationStack {
                    StreamingLabView()
                }
                .semrehAppTheme()
            } else {
                ContentView(authManager: authManager)
                    .semrehAppTheme()
                    .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
            }
            #else
            ContentView(authManager: authManager)
                .semrehAppTheme()
                .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
            #endif
        }
        .modelContainer(for: [CachedSession.self, CachedMessage.self])
        .commands {
            SemrehCommands()
            SidebarCommands()
        }
    }
}

#if DEBUG
private struct ChatPerformanceLabView: View {
    private let fixture: (session: SessionSummary, server: URL, viewModel: ChatViewModel)

    init() {
        fixture = ChatViewModel.makePerformanceLabFixture()
    }

    var body: some View {
        ChatView(
            session: fixture.session,
            server: fixture.server,
            onAPIError: { _ in },
            loadsInitialMessages: false,
            retainedViewModel: fixture.viewModel,
            disablesExternalLifecycle: true
        )
    }
}

private struct ChatPerformanceMultiLabView: View {
    @State private var fixtures: [(
        session: SessionSummary,
        server: URL,
        viewModel: ChatViewModel
    )]
    @State private var selectedChat = 0
    @State private var isStreamingFixture = false
    @State private var streamingTask: Task<Void, Never>?

    init() {
        _fixtures = State(initialValue: ChatViewModel.makePerformanceLabFixtures())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(fixtures.indices, id: \.self) { index in
                    Button("Performance chat \(index + 1)") {
                        selectedChat = index
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedChat == index ? .accentColor : .secondary)
                    .accessibilityLabel("Performance chat \(index + 1)")
                    .accessibilityAddTraits(selectedChat == index ? .isSelected : [])
                }

                Button("Stream test turn") {
                    guard !isStreamingFixture else { return }
                    isStreamingFixture = true
                    let viewModel = fixtures[selectedChat].viewModel
                    streamingTask = Task { @MainActor in
                        await viewModel.appendPerformanceLabStreamingTurn()
                        isStreamingFixture = false
                        streamingTask = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isStreamingFixture)
                .accessibilityLabel("Stream test turn")
                .accessibilityValue(isStreamingFixture ? "Streaming" : "Ready")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            let fixture = fixtures[selectedChat]
            ChatView(
                session: fixture.session,
                server: fixture.server,
                onAPIError: { _ in },
                loadsInitialMessages: false,
                retainedViewModel: fixture.viewModel,
                disablesExternalLifecycle: true
            )
            .id(fixture.session.id)
        }
        .onDisappear {
            streamingTask?.cancel()
            streamingTask = nil
            isStreamingFixture = false
        }
    }
}

private struct SidebarBrandLabView: View {
    var body: some View {
        ZStack {
            SemrehBackdrop().ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Spacer(minLength: 0)

                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 44, height: 44)

                        Text("JM")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(SemrehVisualTheme.energyForeground())
                            .frame(width: 44, height: 44)
                            .background(SemrehVisualTheme.energy(), in: Circle())
                    }
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(SemrehVisualTheme.energyGradient)
                        .frame(height: 2)
                        .padding(.horizontal, 24)
                        .offset(y: 11)
                }

                VStack(alignment: .leading, spacing: 18) {
                    Label("Sessions", systemImage: "bubble.left.and.bubble.right")
                        .font(.title2.bold())
                    Text("Sidebar brand fixture")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 56)

                Spacer()
            }
        }
    }
}
#endif
