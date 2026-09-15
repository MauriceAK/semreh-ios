import SwiftUI
import SwiftData
import OSLog

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
            // `xcrun simctl launch <udid> com.jacobmoore.semreh --chat-performance-cycle-lab --chat-performance-signposts`
            // `xcrun simctl launch <udid> com.jacobmoore.semreh --sidebar-brand-lab`
            if ProcessInfo.processInfo.arguments.contains("--chat-performance-lab") {
                NavigationStack {
                    ChatPerformanceLabView()
                }
                .semrehAppTheme()
            } else if ProcessInfo.processInfo.arguments.contains("--chat-response-motion-components-lab") {
                NavigationStack {
                    ChatResponseMotionComponentsLabView()
                }
                .semrehAppTheme()
            } else if ProcessInfo.processInfo.arguments.contains("--chat-performance-cycle-lab") {
                NavigationStack {
                    ChatPerformanceCycleLabView()
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
        .modelContainer(for: [CachedSession.self, CachedMessage.self, CachedSessionPreviewRecord.self])
        .commands {
            SemrehCommands()
            SidebarCommands()
        }
    }
}

#if DEBUG
private enum ChatPerformanceInstrumentation {
    enum Phase: String {
        case cycleLabAppeared = "cycle_lab_appeared"
        case cycleLabDisappeared = "cycle_lab_disappeared"
        case enterRequested = "enter_requested"
        case enterTransition = "enter_transition"
        case chatAppeared = "chat_appeared"
        case chatDisappeared = "chat_disappeared"
        case returnObserved = "return_observed"
    }

    private static let log = OSLog(
        subsystem: "com.jacobmoore.semreh",
        category: "ChatPerformance"
    )

    /// Signposts are deliberately opt-in so ordinary DEBUG launches keep the
    /// same behavior and logging volume as before. The UI test supplies this
    /// argument only for an Instruments trace.
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--chat-performance-signposts")
    }

    static func event(
        _ phase: Phase,
        chatNumber: Int? = nil,
        visitNumber: Int? = nil
    ) {
        guard isEnabled else { return }

        os_signpost(
            .event,
            log: log,
            name: "ChatPerformancePhase",
            "%{public}s",
            details(for: phase, chatNumber: chatNumber, visitNumber: visitNumber)
        )
    }

    /// The cycle lab has one visit in flight at a time, so the default
    /// exclusive signpost ID gives Instruments a transition interval without
    /// keeping mutable timing state in the view hierarchy.
    static func begin(
        _ phase: Phase,
        chatNumber: Int? = nil,
        visitNumber: Int? = nil
    ) {
        guard isEnabled else { return }

        os_signpost(
            .begin,
            log: log,
            name: "ChatPerformanceTransition",
            "%{public}s",
            details(for: phase, chatNumber: chatNumber, visitNumber: visitNumber)
        )
    }

    static func end(
        _ phase: Phase,
        chatNumber: Int? = nil,
        visitNumber: Int? = nil
    ) {
        guard isEnabled else { return }

        os_signpost(
            .end,
            log: log,
            name: "ChatPerformanceTransition",
            "%{public}s",
            details(for: phase, chatNumber: chatNumber, visitNumber: visitNumber)
        )
    }

    private static func details(
        for phase: Phase,
        chatNumber: Int?,
        visitNumber: Int?
    ) -> String {
        var details = phase.rawValue
        if let chatNumber {
            details += " chat=\(chatNumber)"
        }
        if let visitNumber {
            details += " visit=\(visitNumber)"
        }

        return details
    }
}

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

/// DEBUG-only component fixture for Thinking, tool activity, and Markdown.
/// It intentionally does not mount ChatView or claim production callsite coverage.
private struct ChatResponseMotionComponentsLabView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var isComplete = false
    @State private var response = Self.initialResponse

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Component-only response-motion fixture. No provider, network, or authentication is used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Append paragraph") {
                        response += Self.appendedParagraph
                    }
                    .buttonStyle(.bordered)
                    .disabled(isComplete)
                    .accessibilityIdentifier("motion-lab-append")

                    Button(isComplete ? "Restart" : "Complete response") {
                        if isComplete {
                            response = Self.initialResponse
                            isComplete = false
                        } else {
                            isComplete = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("motion-lab-complete")
                }

                Divider()

                Text("Thinking disclosure")
                    .font(.headline)
                ReasoningBlockView(text: Self.reasoningFixture, isActive: !isComplete)

                Text("Thinking payload rendered as Markdown")
                    .font(.headline)
                MarkdownRenderer(content: Self.reasoningFixture)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Preserved task list")
                    .font(.headline)
                MarkerMessageCardView(kind: .preservedTaskList, content: """
                [Your active task list was preserved across context compression]
                ## Follow-up
                - [ ] **Check** the `message_id` anchor
                - [x] Keep completed work visible
                """)

                Divider()

                Text("Tool activity")
                    .font(.headline)
                ToolActivityGroupView(group: toolGroup)

                Divider()

                HStack(spacing: 8) {
                    Text(isComplete ? "Response complete" : "Response streaming")
                        .font(.headline)
                    if !isComplete {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                MarkdownRenderer(content: response, isStreaming: !isComplete)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(systemReduceMotion
                     ? "System Reduce Motion is enabled."
                     : "Use Simulator Accessibility settings to test system Reduce Motion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .background { SemrehBackdrop().ignoresSafeArea() }
        .navigationTitle("Response Motion Components")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var toolGroup: ToolCallGroup {
        ToolCallGroup(
            id: "response-motion-fixture-tools",
            anchorMessageID: "response-motion-fixture-assistant",
            toolCalls: [
                ToolCall(
                    id: "response-motion-fixture-search",
                    name: "search",
                    preview: "Found two relevant messages.",
                    args: ["query": .string("latest meaningful activity")],
                    isCompleted: isComplete
                ),
                ToolCall(
                    id: "response-motion-fixture-read",
                    name: "read_file",
                    preview: "Read the matching transcript row.",
                    args: ["path": .string("conversation/messages")],
                    isCompleted: isComplete
                )
            ]
        )
    }

    private static let reasoningFixture = """
    ◉_◉ computing... **Searching...**

    ## Current thread
    - Locate the retained message by `message_id`.
    - Preserve the reader's current viewport while new content arrives.

    ```swift
    let anchor = "assistant-42"
    let hasMeaningfulHistory = true
    ```
    """

    private static let initialResponse = "The matching session is selected. **The visible transcript stays anchored.**"

    private static let appendedParagraph = """


    A second paragraph arrived at a block boundary, with `new content` still readable.
    """
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

/// A server-free navigation harness for the reported repeated long-chat
/// enter/back/switch slowdown. It deliberately uses the same retained,
/// 10,000-row fixtures as the existing labs and leaves production navigation
/// untouched. The UI test drives the 20 alternating visits.
private struct ChatPerformanceCycleLabView: View {
    private let fixtures: [(
        session: SessionSummary,
        server: URL,
        viewModel: ChatViewModel
    )]

    @State private var selectedChatIndex: Int?
    @State private var visitCount = 0

    init() {
        fixtures = ChatViewModel.makePerformanceLabFixtures(count: 2)
    }

    var body: some View {
        List {
            Section {
                ForEach(fixtures.indices, id: \.self) { index in
                    Button {
                        visitCount += 1
                        ChatPerformanceInstrumentation.begin(
                            .enterTransition,
                            chatNumber: index + 1,
                            visitNumber: visitCount
                        )
                        ChatPerformanceInstrumentation.event(
                            .enterRequested,
                            chatNumber: index + 1,
                            visitNumber: visitCount
                        )
                        selectedChatIndex = index
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Long chat \(index + 1)")
                                .font(.headline)
                            Text("10,000-row server-free fixture")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("performance-cycle-chat-\(index + 1)")
                }
            } header: {
                Text("Repeat enter → Back → switch")
            } footer: {
                Text("Opt-in diagnostic lab. It does not contact a server.")
            }
        }
        .navigationTitle("Performance cycles")
        .accessibilityIdentifier("performance-cycle-lab")
        .onAppear {
            ChatPerformanceInstrumentation.event(.cycleLabAppeared)
        }
        .onDisappear {
            ChatPerformanceInstrumentation.event(.cycleLabDisappeared)
        }
        .navigationDestination(
            isPresented: Binding(
                get: { selectedChatIndex != nil },
                set: { isPresented in
                    guard !isPresented else { return }
                    ChatPerformanceInstrumentation.event(
                        .returnObserved,
                        chatNumber: selectedChatIndex.map { $0 + 1 },
                        visitNumber: visitCount
                    )
                    selectedChatIndex = nil
                }
            )
        ) {
            if let selectedChatIndex {
                let fixture = fixtures[selectedChatIndex]
                ChatPerformanceCycleDestination(
                    session: fixture.session,
                    server: fixture.server,
                    viewModel: fixture.viewModel,
                    chatNumber: selectedChatIndex + 1,
                    visitNumber: visitCount
                )
            } else {
                Color.clear
            }
        }
    }
}

private struct ChatPerformanceCycleDestination: View {
    let session: SessionSummary
    let server: URL
    let viewModel: ChatViewModel
    let chatNumber: Int
    let visitNumber: Int

    var body: some View {
        ChatView(
            session: session,
            server: server,
            onAPIError: { _ in },
            loadsInitialMessages: false,
            retainedViewModel: viewModel,
            disablesExternalLifecycle: true
        )
        .onAppear {
            ChatPerformanceInstrumentation.end(
                .enterTransition,
                chatNumber: chatNumber,
                visitNumber: visitNumber
            )
            ChatPerformanceInstrumentation.event(
                .chatAppeared,
                chatNumber: chatNumber,
                visitNumber: visitNumber
            )
        }
        .onDisappear {
            ChatPerformanceInstrumentation.event(
                .chatDisappeared,
                chatNumber: chatNumber,
                visitNumber: visitNumber
            )
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
