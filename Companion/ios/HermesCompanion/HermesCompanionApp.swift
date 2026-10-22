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
    var replacingHost = false
    @Environment(\.dismiss) private var dismiss
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
                .toolbar { if replacingHost { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } }
                .onChange(of: store.grant?.deviceID) { old, new in if replacingHost, new != nil, new != old { dismiss() } }
        }
    }
}

struct ChatView: View {
    @Bindable var store: AppStore
    @State private var sheet: ChatSheet?
    @State private var isDrawerOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var conversationsFocused: Bool
    @State private var transcriptFrame = CGRect.zero
    @State private var headerFrame = CGRect.zero
    @State private var dockFrame = CGRect.zero
    @State private var dockGeometry = TranscriptDockGeometry()
    private var dockHeight: CGFloat { dockFrame.isEmpty ? 80 : dockFrame.height }
    private var viewportInsets: UIEdgeInsets {
        guard !transcriptFrame.isEmpty, !headerFrame.isEmpty, !dockFrame.isEmpty else {
            return UIEdgeInsets(top: 80, left: 0, bottom: 80, right: 0)
        }
        return UIEdgeInsets(top: max(0, headerFrame.maxY - transcriptFrame.minY) + 8, left: 0,
            bottom: max(0, transcriptFrame.maxY - dockFrame.minY), right: 0)
    }
    enum ChatSheet: String, Identifiable { case controls, activity, settings, connect; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let drawerWidth = min(geometry.size.width * 0.8, max(0, geometry.size.width - 56))
                ZStack(alignment: .leading) {
                    if isDrawerOpen {
                        ConversationDrawer(store: store, onClose: { closeDrawer() }, onDestination: { closeDrawer(destination: $0) }, onSelect: { session in
                            closeDrawer()
                            if session.id != store.selectedSession?.id { Task { await store.select(session) } }
                        })
                        .frame(width: drawerWidth)
                        .transition(.opacity)
                    }
                    ZStack {
                        TranscriptContainer(store: store, viewportInsets: viewportInsets, dockGeometry: dockGeometry)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { transcriptFrame = $0 }
                            .ignoresSafeArea(.container)
                        VStack {
                            Rectangle().fill(.ultraThinMaterial)
                                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.85), location: 0.4), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                                .frame(height: viewportInsets.top)
                            Spacer(minLength: 0)
                        }.ignoresSafeArea(.container).allowsHitTesting(false).accessibilityHidden(true)
                        VStack(spacing: 0) {
                            header
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { headerFrame = $0 }
                            Spacer(minLength: 0)
                            dock
                                .background(TranscriptDockProbe(geometry: dockGeometry))
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dockFrame = $0 }
                        }
                        if store.newActivity || store.transcript.hasNewer || store.isReadingHistory || store.isFetchingLatest {
                            VStack {
                                Spacer()
                                Button { Task { await store.latest() } } label: {
                                    Group {
                                        if store.isFetchingLatest { ProgressView().tint(.white) }
                                        else { Image(systemName: "arrow.down").font(.system(size: 17, weight: .semibold)) }
                                    }.foregroundStyle(.white).frame(width: 44, height: 44)
                                        .background(Color.blue, in: Circle())
                                }.disabled(store.isFetchingLatest)
                                    .accessibilityLabel(store.isFetchingLatest ? "Loading latest messages" : "Latest messages").accessibilityIdentifier("latestMessages")
                                    .padding(.bottom, dockHeight + 8)
                            }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color(white: 0.055).ignoresSafeArea(.container))
                    .disabled(isDrawerOpen || sheet != nil)
                    .allowsHitTesting(!isDrawerOpen)
                    .accessibilityHidden(isDrawerOpen)
                    .overlay {
                        if isDrawerOpen {
                            Button { closeDrawer() } label: {
                                Color.black.opacity(0.12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Close conversations")
                                .accessibilityIdentifier("dismissConversations")
                                .keyboardShortcut(.cancelAction)
                        }
                    }
                    .clipShape(ChatPanelShape(cornerRadius: isDrawerOpen ? 28 : 0, topInset: geometry.safeAreaInsets.top, bottomInset: geometry.safeAreaInsets.bottom))
                    .offset(x: isDrawerOpen ? drawerWidth : 0)
                }
                .onChange(of: viewportInsets) { _, insets in
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--fixture-geometry") {
                        print("CHAT_CHROME transcript=\(transcriptFrame) header=\(headerFrame) dock=\(dockFrame) insets=\(insets) legacyBottom=\(geometry.safeAreaInsets.bottom + dockHeight + 8)")
                    }
                    #endif
                }
            }
            .background(Color(white: 0.055))
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $sheet) { item in
                Group {
                    switch item {
                    case .controls: ControlsView(store: store)
                    case .activity: ActivityView(store: store)
                    case .settings: SettingsView(store: store)
                    case .connect: PairingView(store: store, replacingHost: true)
                    }
                }.modifier(AppAlerts(store: store))
            }
            .onChange(of: store.routedUpdateID) { _, id in if id != nil { closeDrawer(destination: .activity) } }
            .modifier(AppAlerts(store: store, enabled: sheet == nil))
        }
    }

    private func closeDrawer(destination: ChatSheet? = nil) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        guard isDrawerOpen else { if let destination { sheet = destination }; return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
            isDrawerOpen = false
        } completion: {
            if let destination { sheet = destination }
            else { conversationsFocused = true }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    conversationsFocused = false
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { isDrawerOpen = true }
                } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 20)).frame(width: 44, height: 44)
                }.modifier(ChatGlass(cornerRadius: 22))
                    .accessibilityLabel("Conversations").accessibilityIdentifier("sessions")
                    .accessibilityFocused($conversationsFocused)
                Spacer(minLength: 12)
                VStack(spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle").font(.caption).foregroundStyle(.blue)
                        Text(store.grant?.host.profile ?? "Hermes").font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Text(store.statusLabel).font(.caption2).foregroundStyle(store.runState == .waiting ? .orange : .secondary)
                        .accessibilityIdentifier("agentStatus")
                }.padding(.horizontal, 14).padding(.vertical, 9).modifier(ChatGlass(cornerRadius: 20))
                Spacer(minLength: 12)
                Menu {
                    Button("Model & reasoning", systemImage: "slider.horizontal.3") { sheet = .controls }
                    Button("Follow-ups & updates", systemImage: "bell") { sheet = .activity }
                    Button("Settings", systemImage: "gearshape") { sheet = .settings }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20)).frame(width: 44, height: 44)
                }.modifier(ChatGlass(cornerRadius: 22))
                    .accessibilityIdentifier("chatMenu").accessibilityLabel("Chat options")
            }.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            if store.fixture {
                Text("CONTROLLED UI FIXTURE").font(.caption2.monospaced()).foregroundStyle(.orange)
                    .padding(5).modifier(ChatGlass(cornerRadius: 10)).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .accessibilityIdentifier("fixtureBanner")
            }
            if let connectionError = store.connectionError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(connectionError).font(.caption).accessibilityIdentifier("connectionError")
                    Spacer()
                    if store.requiresPairing {
                        Button("Connect host") { sheet = .connect }.frame(minHeight: 44).accessibilityIdentifier("repairHostConnection")
                    } else { Button("Reconnect") { store.reconnect() }.frame(minHeight: 44) }
                }.padding(.horizontal, 12).modifier(ChatGlass(cornerRadius: 16))
            }
        }.padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
    }

    private var dock: some View {
        VStack(spacing: 0) {
            if !store.currentUncertain.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("An action has an uncertain outcome").font(.subheadline.bold())
                    Text("Check the conversation before sending it again. It was not retried.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Refresh") { Task { await store.latest(forceRefresh: true) } }.frame(minHeight: 44)
                        Spacer()
                        Button("I checked") { store.currentUncertain.forEach { store.acknowledgeUncertain($0) } }.frame(minHeight: 44)
                    }.font(.caption)
                }.padding(12).modifier(ChatGlass(cornerRadius: 18)).padding(.horizontal, 12).accessibilityIdentifier("uncertainAction")
            }
            RequestTray(store: store).layoutPriority(2)
            if let notice = store.notice, store.connection == "Connected" {
                HStack(alignment: .center) {
                    Text(notice).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button { store.notice = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("Dismiss status")
                }.padding(.leading, 16).modifier(ChatGlass(cornerRadius: 18)).padding(.horizontal, 12)
            }
            ComposerView(store: store)
        }
    }
}

struct TranscriptContainer: View {
    var store: AppStore
    var viewportInsets: UIEdgeInsets = .zero
    var dockGeometry: TranscriptDockGeometry?
    var body: some View {
        ZStack {
            TranscriptView(messages: store.displayMessages, hasMore: store.transcript.hasMore,
                loading: store.isLoadingHistory, latestRevision: store.latestRevision,
                viewportInsets: viewportInsets, activity: store.transcriptActivity, sessionID: store.selectedSession?.id,
                conversationContext: store.readerContext, sends: store.sendPresentations,
                readerRestoration: store.readerRestoration, dockGeometry: dockGeometry,
                onReaderPosition: { store.readerPositionChanged($0, context: $1) },
                onSendPresentation: { store.sendPresentationFinished($0, outcome: $1) },
                onUserScrollBegan: { store.userScrollBegan() },
                onOlder: { Task { await store.loadOlder() } }, onReadingHistory: { store.isReadingHistory = $0 })
            if store.displayMessages.isEmpty && store.transcriptActivity == .idle && !store.transcript.hasMore {
                GeometryReader { geometry in
                    let availableHeight = max(0, geometry.size.height - viewportInsets.top - viewportInsets.bottom)
                    ScrollView {
                        VStack(spacing: 12) {
                            Image(systemName: "sparkle").font(.system(size: 36, weight: .light)).foregroundStyle(.blue)
                            Text(store.selectedSession == nil ? "What’s on your mind?" : "Start with a thought.").font(.title2.weight(.medium))
                            Text("Ask a question, work on an idea, or give your agent something to follow through on.").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: 290)
                        }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .frame(maxWidth: .infinity, minHeight: availableHeight)
                    }.scrollIndicators(.hidden)
                        .padding(.top, viewportInsets.top).padding(.bottom, viewportInsets.bottom)
                        .accessibilityIdentifier("emptyConversation")
                }
            }
        }.accessibilityValue("\(store.displayMessages.count) loaded messages")
    }
}

struct RequestTray: View {
    var store: AppStore
    @State private var selectedID: String?
    @State private var details: HostRequestDetails?
    private var selected: AgentRequest? { store.requests.first(where: { $0.id == selectedID }) ?? store.requests.first }
    var body: some View {
        VStack(spacing: 0) {
            if let request = selected {
                VStack(spacing: 4) {
                    if store.requests.count > 1 {
                        Menu {
                            ForEach(store.requests) { item in Button(item.title) { selectedID = item.id } }
                        } label: {
                            Label("\(store.requests.count) requests · Choose a request", systemImage: "list.bullet").font(.caption).frame(minHeight: 44)
                        }
                    }
                    if request.kind == "host_action" {
                        HStack(spacing: 10) {
                            Image(systemName: "hand.raised").foregroundStyle(.orange)
                            Text(request.title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button("Details") { details = HostRequestDetails(request: request, store: store) }
                                .frame(minHeight: 44).accessibilityIdentifier("hostRequestDetails")
                        }.padding(.horizontal, 14).padding(.vertical, 4)
                            .modifier(ChatGlass(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.orange.opacity(0.25)))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .accessibilityElement(children: .contain).accessibilityIdentifier("hostRequestSummary")
                    } else { RequestCard(store: store, request: request).id(request.id) }
                }
            }
        }.sheet(item: $details) { details in
            HostRequestDetailView(store: store, details: details)
        }
    }
}

private struct HostRequestDetails: Identifiable {
    let request: AgentRequest
    let scope: [String]
    var id: String { request.generation + ":" + request.id }
    @MainActor init(request: AgentRequest, store: AppStore) {
        self.request = request
        scope = Self.scope(store)
    }
    @MainActor static func scope(_ store: AppStore) -> [String] {
        [store.grant?.baseURL ?? "", store.grant?.deviceID ?? "", store.grant?.host.profile ?? "", store.selectedSession?.id ?? ""]
    }
}

private struct HostRequestDetailView: View {
    var store: AppStore
    let details: HostRequestDetails
    @Environment(\.dismiss) private var dismiss
    private var pending: Bool {
        HostRequestDetails.scope(store) == details.scope && store.requests.contains {
            $0.id == details.request.id && $0.generation == details.request.generation && $0.kind == "host_action"
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(details.request.title, systemImage: "hand.raised").font(.headline)
                    Text(pending
                        ? "This request is not supported in Companion yet. Open Hermes on your host to continue. It remains pending until answered or canceled there."
                        : "This request is no longer pending.")
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.navigationTitle("Pending request").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.medium, .large])
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
            .modifier(ChatGlass(cornerRadius: 18))
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
