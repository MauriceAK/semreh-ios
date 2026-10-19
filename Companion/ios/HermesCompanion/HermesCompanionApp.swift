import SwiftUI
import UserNotifications

@main
struct HermesCompanionApp: App {
    @UIApplicationDelegateAdaptor(NotificationsDelegate.self) private var delegate
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .preferredColorScheme(.dark)
                .tint(.blue)
                .task { delegate.store = store; await store.start() }
                .onOpenURL { url in Task { await store.pair(url.absoluteString) } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.foreground() }
                    else if phase == .background { store.background() }
                }
        }
    }
}

@MainActor
final class NotificationsDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var store: AppStore? {
        didSet {
            if let route = pendingRoute {
                pendingRoute = nil
                Task { await store?.routeNotification(updateID: route.update, sessionID: route.session) }
            }
        }
    }
    private var pendingRoute: (update: String?, session: String?)?
    private func route(update: String?, session: String?) async {
        if let store { await store.routeNotification(updateID: update, sessionID: session) }
        else { pendingRoute = (update, session) }
    }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await store?.registerPush(token) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        store?.notificationStatus = "Remote push is unavailable on this build"
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let update = response.notification.request.content.userInfo["update_id"] as? String
        let session = response.notification.request.content.userInfo["session_id"] as? String
        Task { @MainActor in
            await route(update: update, session: session)
            completionHandler()
        }
    }
}

struct RootView: View {
    @Bindable var store: AppStore
    var body: some View {
        Group {
            if store.grant != nil { ChatView(store: store) }
            else { PairingView(store: store).modifier(AppAlerts(store: store)) }
        }

    }
}


struct AppAlerts: ViewModifier {
    @Bindable var store: AppStore
    var enabled = true
    func body(content: Content) -> some View {
        content
        .alert("Couldn’t complete that", isPresented: Binding(get: { enabled && store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Confirm model change", isPresented: Binding(get: { enabled && store.confirmation != nil }, set: { if !$0 { store.confirmation = nil } })) {
            Button("Change model") {
                guard let confirmation = store.confirmation else { return }
                store.confirmation = nil
                Task { await store.confirmModelChange(confirmation) }
            }
            Button("Cancel", role: .cancel) { store.confirmation = nil }
        } message: { Text(store.confirmation?.details.message ?? "") }
    }
}

struct PairingView: View {
    @Bindable var store: AppStore
    @State private var invitation = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "sparkle").font(.system(size: 46, weight: .light)).foregroundStyle(.blue).padding(.top, 20)
                    Text("Your agent.\nWithin reach.").font(.system(size: 38, weight: .semibold, design: .rounded))
                    Text("Chat with Hermes wherever you are.").font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connect Hermes").font(.headline)
                        Text("Open your invitation link, or paste it here. Keep the computer running Hermes online.").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Paste invitation", text: $invitation, axis: .vertical)
                            .lineLimit(1...3).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityIdentifier("invitation")
                        Button { Task { await store.pair(invitation) } } label: {
                            HStack { Spacer(); if store.isPairing { ProgressView() }; Text(store.isPairing ? "Connecting…" : "Connect Hermes"); Spacer() }
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(invitation.isEmpty || store.isPairing).accessibilityIdentifier("pair")
                    }.padding(20).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 24))
                    Text("Need an invitation? Create one in Companion on the computer running Hermes. You can reconnect here if a link expires.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }.background(Color(white: 0.055)).navigationTitle("Hermes Companion").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ChatView: View {
    @Bindable var store: AppStore
    @State private var sheet: ChatSheet?
    enum ChatSheet: String, Identifiable { case sessions, controls, activity, settings; var id: String { rawValue } }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.fixture {
                    Text("CONTROLLED UI FIXTURE · 10,000 messages").font(.caption2.monospaced()).foregroundStyle(.orange).padding(.vertical, 5).accessibilityIdentifier("fixtureBanner")
                }
                if store.connection != "Connected" {
                    HStack(spacing: 8) { ProgressView().controlSize(.mini); Text(store.connection + ". Your draft stays here.").font(.caption); Spacer(); Button("Reconnect") { store.connect() } }.padding(12).background(.orange.opacity(0.12))
                }
                TranscriptContainer(store: store)
                if !store.currentUncertain.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("An action has an uncertain outcome").font(.subheadline.bold())
                        Text("Check the conversation before sending it again. It was not retried.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Refresh") { Task { await store.latest() } }
                            Spacer()
                            Button("I checked") { store.currentUncertain.forEach { store.acknowledgeUncertain($0) } }
                        }.font(.caption)
                    }.padding(12).background(.orange.opacity(0.12)).accessibilityIdentifier("uncertainAction")
                }
                RequestTray(store: store).layoutPriority(2)
                if let notice = store.notice, store.connection == "Connected" {
                    HStack(alignment: .top) {
                        Text(notice).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button { store.notice = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss status")
                    }.padding(.horizontal, 16).padding(.vertical, 10).background(.white.opacity(0.04))
                }
            }
            .background(Color(white: 0.055))
            .safeAreaInset(edge: .bottom, spacing: 0) { ComposerView(store: store) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { sheet = .sessions } label: { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Conversations").accessibilityIdentifier("sessions") }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        HStack(spacing: 6) { Image(systemName: "sparkle").font(.caption).foregroundStyle(.blue); Text(store.grant?.host.profile ?? "Hermes").font(.subheadline.weight(.semibold)).lineLimit(1) }
                        Text(store.statusLabel).font(.caption2).foregroundStyle(store.runState == .waiting ? .orange : .secondary).accessibilityIdentifier("agentStatus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Model & reasoning", systemImage: "slider.horizontal.3") { sheet = .controls }
                        Button("Follow-ups & updates", systemImage: "bell") { sheet = .activity }
                        Button("Settings", systemImage: "gearshape") { sheet = .settings }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("chatMenu").accessibilityLabel("Chat options")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $sheet) { item in
                Group {
                    switch item {
                    case .sessions: SessionsView(store: store)
                    case .controls: ControlsView(store: store)
                    case .activity: ActivityView(store: store)
                    case .settings: SettingsView(store: store)
                    }
                }.modifier(AppAlerts(store: store))
            }
            .onChange(of: store.routedUpdateID) { _, id in if id != nil { sheet = .activity } }
            .modifier(AppAlerts(store: store, enabled: sheet == nil))
        }
    }
}

struct TranscriptContainer: View {
    var store: AppStore
    var body: some View {
        ZStack(alignment: .top) {
            if store.transcript.messages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "sparkle").font(.system(size: 36, weight: .light)).foregroundStyle(.blue)
                    Text(store.selectedSession == nil ? "What’s on your mind?" : "Start with a thought.").font(.title2.weight(.medium))
                    Text("Ask a question, work on an idea, or give your agent something to follow through on.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 290)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptView(messages: store.transcript.messages, hasMore: store.transcript.hasMore, loading: store.isLoadingHistory, latestRevision: store.latestRevision, onOlder: { Task { await store.loadOlder() } }, onReadingHistory: { store.isReadingHistory = $0 })
            }
            LinearGradient(colors: [Color(white: 0.055), Color(white: 0.055).opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 36).allowsHitTesting(false).accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            if store.newActivity || store.transcript.hasNewer || store.isReadingHistory {
                LinearGradient(colors: [Color(white: 0.055).opacity(0), Color(white: 0.055)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 20).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.newActivity || store.transcript.hasNewer || store.isReadingHistory {
                HStack {
                    Spacer()
                    Button { Task { await store.latest() } } label: {
                        Label("Latest", systemImage: "arrow.down").font(.footnote.weight(.semibold)).padding(.horizontal, 14).frame(height: 36).background(.regularMaterial, in: Capsule())
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }.accessibilityLabel("Latest messages").accessibilityIdentifier("latestMessages")
                }.padding(.horizontal, 12).background(Color(white: 0.055))
            }
        }
        .accessibilityValue("\(store.transcript.messages.count) loaded messages")
    }
}

struct RequestTray: View {
    var store: AppStore
    @State private var selectedID: String?
    private var selected: AgentRequest? { store.requests.first(where: { $0.id == selectedID }) ?? store.requests.first }
    var body: some View {
        if let request = selected {
            VStack(spacing: 4) {
                if store.requests.count > 1 {
                    Menu {
                        ForEach(store.requests) { item in Button(item.title) { selectedID = item.id } }
                    } label: {
                        Label("\(store.requests.count) requests · Choose a request", systemImage: "list.bullet").font(.caption).frame(minHeight: 44)
                    }
                }
                RequestCard(store: store, request: request).id(request.id)
            }
        }
    }
}
struct RequestCard: View {
    var store: AppStore
    let request: AgentRequest
    @State private var answer = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Label(request.title, systemImage: "hand.raised").font(.headline)
                    Text(request.description).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 120).accessibilityIdentifier("requestDetails")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { choices.fixedSize(horizontal: true, vertical: false) }
                VStack(alignment: .leading, spacing: 8) { choices }
            }.fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            if request.allowsText == true {
                HStack {
                    TextField("Your answer", text: $answer).textFieldStyle(.roundedBorder)
                    Button("Reply") { Task { await store.answer(request, answer: answer) } }.frame(minWidth: 44, minHeight: 44).disabled(answer.isEmpty)
                }.layoutPriority(1)
            }
        }.disabled(!store.canCommand || store.isSending || store.isStopping)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.orange.opacity(0.25)))
            .padding(.horizontal, 12).padding(.vertical, 6)
    }
    private var choices: some View {
        ForEach(request.choices) { choice in
            Button { Task { await store.answer(request, answer: choice.id) } } label: {
                Text(choice.label).frame(minHeight: 44)
            }.buttonStyle(.bordered).accessibilityIdentifier("answer-" + choice.id)
        }
    }
}
