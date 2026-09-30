import SwiftUI
import SwiftData
import OSLog
import Foundation
import CoreFoundation
import UserNotifications
#if DEBUG
import UIKit
#endif

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

#if DEBUG
/// A narrowly scoped setup transaction for the real automatic-prepend UI
/// diagnostic. It seeds the existing persisted reader contract before the
/// normal ChatViewModel initializer runs; it does not alter paging or inject
/// transcript data. The UI test must explicitly clean up with the matching
/// cleanup arguments after the disposable run.
struct ChatP09DiagnosticRestoreRequest: Equatable {
    enum Operation: Equatable {
        case seed
        case cleanup
    }

    static let seedArgument = "--chat-p09-seed-restore"
    static let cleanupArgument = "--chat-p09-cleanup-restore"
    static let serverArgumentPrefix = "--chat-p09-restore-server="
    static let sessionArgumentPrefix = "--chat-p09-restore-session="
    static let messageArgumentPrefix = "--chat-p09-restore-message="
    static let approvedOrigin = "https://semreh-slice1-test.tailda8427.ts.net"

    let operation: Operation
    let server: URL
    let sessionID: String
    let visibleMessageID: String?

    /// Parses only the P09-specific arguments. Any malformed, incomplete, or
    /// out-of-scope P09 argument rejects the request rather than falling back
    /// to a guessed server/session/message.
    static func parse(arguments: [String]) -> Self? {
        let seedCount = arguments.filter { $0 == seedArgument }.count
        let cleanupCount = arguments.filter { $0 == cleanupArgument }.count
        let hasP09Argument = seedCount > 0 || cleanupCount > 0

        guard hasP09Argument else { return nil }
        guard (seedCount == 1 && cleanupCount == 0)
                || (seedCount == 0 && cleanupCount == 1) else {
            return nil
        }

        let p09Arguments = arguments.filter { $0.hasPrefix("--chat-p09-") }
        guard p09Arguments.allSatisfy(isRecognizedArgument) else { return nil }

        let serverValues = values(for: serverArgumentPrefix, in: arguments)
        let sessionValues = values(for: sessionArgumentPrefix, in: arguments)
        let messageValues = values(for: messageArgumentPrefix, in: arguments)
        guard serverValues.count == 1,
              sessionValues.count == 1,
              let server = approvedServer(from: serverValues[0]),
              isCanonicalIdentifier(sessionValues[0])
        else { return nil }

        let operation: Operation
        let visibleMessageID: String?
        if seedCount == 1 {
            guard messageValues.count == 1,
                  isCanonicalIdentifier(messageValues[0]) else { return nil }
            operation = .seed
            visibleMessageID = messageValues[0]
        } else {
            // Cleanup is deliberately scoped to the exact server/session
            // backup. A message argument here would make the cleanup scope
            // ambiguous, so reject it instead of ignoring it.
            guard messageValues.isEmpty else { return nil }
            operation = .cleanup
            visibleMessageID = nil
        }

        return Self(
            operation: operation,
            server: server,
            sessionID: sessionValues[0],
            visibleMessageID: visibleMessageID
        )
    }

    private static func values(for prefix: String, in arguments: [String]) -> [String] {
        arguments
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private static func isRecognizedArgument(_ argument: String) -> Bool {
        argument == seedArgument
            || argument == cleanupArgument
            || argument.hasPrefix(serverArgumentPrefix)
            || argument.hasPrefix(sessionArgumentPrefix)
            || argument.hasPrefix(messageArgumentPrefix)
    }

    private static func isCanonicalIdentifier(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$",
            options: .regularExpression
        ) != nil
    }

    private static func approvedServer(from rawValue: String) -> URL? {
        guard let url = URL(string: rawValue),
              url.scheme == "https",
              url.host == "semreh-slice1-test.tailda8427.ts.net",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { return nil }

        // TranscriptRestoreStore trims a trailing slash when forming its key;
        // permit only that equivalent spelling, not arbitrary subpaths.
        let normalized = rawValue.hasSuffix("/")
            ? String(rawValue.dropLast())
            : rawValue
        guard normalized == approvedOrigin else { return nil }
        return URL(string: approvedOrigin)
    }
}

/// Pure one-shot state shared with focused tests. No timer can release a load.
struct ChatP09CalibrationState: Equatable {
    enum Phase: Equatable { case unused, waiting, released, aborted }
    private(set) var phase: Phase = .unused
    private(set) var scope: UUID?

    mutating func begin(scope: UUID) -> Bool {
        guard phase == .unused else { return false }
        self.scope = scope
        phase = .waiting
        return true
    }

    mutating func finish(scope: UUID, released: Bool) -> Bool {
        guard phase == .waiting, self.scope == scope else { return false }
        phase = released ? .released : .aborted
        return true
    }

    static func nonce(arguments: [String], environment: [String: String]) -> String? {
        guard let request = ChatP09DiagnosticRestoreRequest.parse(arguments: arguments),
              request.operation == .seed,
              let raw = environment["SEMREH_P09_CALIBRATION_NONCE"],
              let nonce = UUID(uuidString: raw), nonce.uuidString == raw else { return nil }
        return raw
    }

    static func matchesFixture(arguments: [String], server: URL, sessionID: String) -> Bool {
        guard let request = ChatP09DiagnosticRestoreRequest.parse(arguments: arguments) else { return false }
        return request.operation == .seed && request.server == server && request.sessionID == sessionID
    }
}

#if targetEnvironment(simulator)
/// A test-process handshake, not a paging implementation. Only a validated
/// contained P09 seed can hold one automatic request; timeout aborts it.
@MainActor
final class ChatP09PagingCalibration {
    static let shared = ChatP09PagingCalibration()
    private var state = ChatP09CalibrationState()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?
    private var releaseName: String?
    private let center = CFNotificationCenterGetDarwinNotifyCenter()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Semreh", category: "TranscriptActivationRecovery")

    func waitIfConfigured(server: URL, sessionID: String, scope: UUID) async -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_P09_CALIBRATION_NONCE"] != nil else { return true }
        let arguments = ProcessInfo.processInfo.arguments
        guard let nonce = ChatP09CalibrationState.nonce(arguments: arguments, environment: environment),
              ChatP09CalibrationState.matchesFixture(arguments: arguments, server: server, sessionID: sessionID),
              !Task.isCancelled, state.begin(scope: scope) else { return false }
        let release = "semreh.p09.calibration.\(nonce).release"
        releaseName = release
        CFNotificationCenterAddObserver(center, Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
            guard let observer else { return }
            let gate = Unmanaged<ChatP09PagingCalibration>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in gate.finish(released: true) }
        }, release as CFString, nil, .deliverImmediately)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { finish(released: false); return }
                timeout = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    finish(released: false)
                }
                logger.debug("event=p09_calibration_paused loaderDispatched=false")
                CFNotificationCenterPostNotification(center,
                    CFNotificationName("semreh.p09.calibration.\(nonce).paused" as CFString), nil, nil, true)
            }
        } onCancel: {
            Task { @MainActor in self.cancel(scope: scope) }
        }
    }

    func cancel(scope: UUID?) {
        guard state.scope == scope else { return }
        finish(released: false)
    }

    private func finish(released: Bool) {
        guard let scope = state.scope, state.finish(scope: scope, released: released) else { return }
        logger.debug("event=p09_calibration_completed released=\(released, privacy: .public)")
        if let releaseName {
            CFNotificationCenterRemoveObserver(center, Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(releaseName as CFString), nil)
        }
        releaseName = nil
        timeout?.cancel()
        timeout = nil
        let resumed = continuation
        continuation = nil
        resumed?.resume(returning: released)
    }
}
#endif

@MainActor
enum ChatP09DiagnosticRestoreBootstrap {
    enum Outcome: Equatable {
        case ignored
        case rejected
        case installed
        case restored
    }

    private static let backupKeyPrefix = "semreh.debug.chatP09.restore-backup."

    /// Applies one explicit seed or cleanup operation. The backup is kept in
    /// one separate, exact-scope UserDefaults key so the prior reader point is
    /// restorable without clearing unrelated app settings.
    @discardableResult
    static func apply(
        arguments: [String],
        defaults: UserDefaults = .standard
    ) -> Outcome {
        let hasP09Argument = arguments.contains(ChatP09DiagnosticRestoreRequest.seedArgument)
            || arguments.contains(ChatP09DiagnosticRestoreRequest.cleanupArgument)
        guard hasP09Argument else { return .ignored }
        guard let request = ChatP09DiagnosticRestoreRequest.parse(arguments: arguments) else {
            return .rejected
        }

        let store = TranscriptRestoreStore(defaults: defaults)
        let restoreKey = restoreKey(for: request)
        let backupKey = backupKey(for: request)

        switch request.operation {
        case .seed:
            guard let canonicalMessageID = request.visibleMessageID,
                  let visibleMessageID = TranscriptRenderIdentity.directID(
                      for: canonicalMessageID
                  ),
                  defaults.object(forKey: backupKey) == nil else {
                return .rejected
            }

            // Keep the raw value, including an absent or malformed value, so
            // cleanup can restore the exact prior local state rather than
            // silently normalizing it to `.followingLatest`.
            let previousObject = defaults.object(forKey: restoreKey)
            let previousData: Data?
            if let previousObject {
                guard let data = previousObject as? Data else {
                    return .rejected
                }
                previousData = data
            } else {
                previousData = nil
            }
            let backup = RestoreBackup(data: previousData)
            guard let backupData = try? JSONEncoder().encode(backup) else {
                return .rejected
            }
            defaults.set(backupData, forKey: backupKey)

            let seeded = TranscriptRestorePoint(
                followingLatest: false,
                visibleMessageID: visibleMessageID
            )
            store.save(seeded, server: request.server, sessionID: request.sessionID)
            guard store.load(server: request.server, sessionID: request.sessionID) == seeded else {
                restoreRawData(previousData, forKey: restoreKey, defaults: defaults)
                defaults.removeObject(forKey: backupKey)
                return .rejected
            }
            return .installed

        case .cleanup:
            guard let backupObject = defaults.object(forKey: backupKey),
                  let backupData = backupObject as? Data,
                  let backup = try? JSONDecoder().decode(RestoreBackup.self, from: backupData)
            else { return .rejected }

            // A non-Data restore value may have been written by another
            // owner after the diagnostic seed. Never overwrite that corrupt
            // or out-of-contract value while attempting cleanup.
            if let currentRestoreObject = defaults.object(forKey: restoreKey),
               !(currentRestoreObject is Data) {
                return .rejected
            }
            restoreRawData(backup.data, forKey: restoreKey, defaults: defaults)
            guard restoreData(forKey: restoreKey, defaults: defaults) == backup.data else {
                return .rejected
            }
            defaults.removeObject(forKey: backupKey)
            return .restored
        }
    }

    private static func backupKey(for request: ChatP09DiagnosticRestoreRequest) -> String {
        let serverKey = request.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(backupKeyPrefix)\(serverKey)|\(request.sessionID)"
    }

    private static func restoreKey(for request: ChatP09DiagnosticRestoreRequest) -> String {
        let serverKey = request.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(TranscriptRestoreStore.visibilityKeyPrefix)\(serverKey)|\(request.sessionID)"
    }

    private static func restoreRawData(
        _ data: Data?,
        forKey key: String,
        defaults: UserDefaults
    ) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func restoreData(forKey key: String, defaults: UserDefaults) -> Data? {
        guard let object = defaults.object(forKey: key) else { return nil }
        return object as? Data
    }

    private struct RestoreBackup: Codable {
        let data: Data?
    }
}
#endif

@main
struct HermesMobileApp: App {
    @State private var authManager = AuthManager()
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue

    init() {
        // Route taps on "response complete" notifications into the app's existing
        // deep-link path (item 4). Set during app init so a cold-launch tap on a
        // killed app still lands before the first scene connects.
        UNUserNotificationCenter.current().delegate = ResponseCompletionNotificationDelegate.shared
#if DEBUG
        _ = ChatPerformanceAutoSwitchLaunch.appInit
        // This is intentionally before ContentView/ChatViewModel creation so
        // the normal persisted restore reader consumes the seeded row.
        _ = ChatP09DiagnosticRestoreBootstrap.apply(
            arguments: ProcessInfo.processInfo.arguments
        )
#endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // Launch argument hooks for deterministic, server-free simulator diagnosis:
            // `xcrun simctl launch <udid> com.maurice.semreh --streaming-lab`
            // `xcrun simctl launch <udid> com.maurice.semreh --chat-performance-lab`
            // `xcrun simctl launch <udid> com.maurice.semreh --chat-performance-lab --chat-outgoing-motion-lab`
            // `xcrun simctl launch <udid> com.maurice.semreh --chat-performance-cycle-lab --chat-performance-signposts`
            // `xcrun simctl launch <udid> com.maurice.semreh --chat-performance-app-wide-monitor`
            // `xcrun simctl launch <udid> com.maurice.semreh --chat-performance-rich-switch-lab --chat-performance-auto-switch --chat-performance-auto-switch-run-id=<UUID>`
            // `xcrun simctl launch <udid> com.maurice.semreh --sidebar-brand-lab`
            // `xcrun simctl launch <udid> com.maurice.semreh --bird-palette-visual-lab`
            Group {
                if ProcessInfo.processInfo.arguments.contains("--chat-performance-four-tall-lab") {
                    NavigationStack {
                        ChatPerformanceLabView(fourTallMessages: true)
                    }
                    .semrehAppTheme()
                } else if ProcessInfo.processInfo.arguments.contains("--chat-performance-rich30-back-lab") {
                    NavigationStack {
                        ChatPerformanceLabView(richThirtyMessages: true)
                    }
                    .semrehAppTheme()
                } else if ProcessInfo.processInfo.arguments.contains("--chat-performance-rich30-lab") {
                    NavigationStack {
                        ChatPerformanceLabView(richThirtyMessages: true)
                    }
                    .semrehAppTheme()
                } else if ProcessInfo.processInfo.arguments.contains("--chat-performance-tall-lab") {
                    NavigationStack {
                        ChatPerformanceLabView(tallMessages: true)
                    }
                    .semrehAppTheme()
                } else if ProcessInfo.processInfo.arguments.contains("--chat-performance-lab") {
                    NavigationStack {
                        ChatPerformanceLabView()
                    }
                    .semrehAppTheme()
                } else if ProcessInfo.processInfo.arguments.contains("--chat-response-motion-components-lab") {
                    NavigationStack {
                        ChatResponseMotionComponentsLabView()
                    }
                    .semrehAppTheme()
                } else if ProcessInfo.processInfo.arguments.contains("--chat-activity-handoff-lab") {
                    NavigationStack {
                        ChatActivityHandoffLabView()
                    }
                    .semrehAppTheme()
                } else if ProcessInfo.processInfo.arguments.contains("--chat-full-activity-lab") {
                    NavigationStack {
                        ChatFullActivityLabView()
                    }
                    .semrehAppTheme()
                } else if ProcessInfo.processInfo.arguments.contains("--chat-full-activity-anchored-lab") {
                    NavigationStack {
                        ChatFullActivityLabView(anchoredHistory: true)
                    }
                    .semrehAppTheme()
                } else if ProcessInfo.processInfo.arguments.contains("--chat-performance-cycle-lab") {
                    ChatPerformanceCycleLabContainer()
                        .semrehAppTheme()
                } else if ProcessInfo.processInfo.arguments.contains("--chat-performance-rich-switch-lab") {
                    NavigationStack {
                        ChatPerformanceMultiLabView(richThirty: true)
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
                } else if ProcessInfo.processInfo.arguments.contains("--bird-palette-visual-lab") {
                    BirdPaletteVisualLabView()
                        .semrehAppTheme()
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
            }
            .overlay {
                if ChatPerformanceCadenceMonitor.isAppWideOptedIn {
                    ChatPerformanceAppWideMonitorHost()
                }
            }
            #else
            Group {
#if SEMREH_INTERNAL_CHAT_PREVIEW && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--internal-chat-preview-smoke") {
                    InternalChatPreviewSmokeView()
                } else {
                    ContentView(authManager: authManager)
                }
#else
                ContentView(authManager: authManager)
#endif
            }
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

/// Turns a tap on a "response complete" local notification into the same session
/// deep link the app already routes from links and App Intents
/// (`semreh://session?id=<storedID>` → `ContentView.handleOpenURL` → the session
/// navigation path). The completion payload carries the session's stored ID,
/// which is exactly what `HermesDeepLink.sessionURL(sessionID:)` expects, so no
/// extra ID mapping is needed. Scheduling itself is unchanged: the service still
/// fires only while the scene is inactive (`ResponseCompletionNotificationPolicy`).
final class ResponseCompletionNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ResponseCompletionNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let url = Self.deepLinkURL(for: response.notification.request.content.userInfo) else { return }
        await MainActor.run {
            AppIntentRouter.shared.requestDeepLink(url)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The scheduling policy already gates on the scene being inactive; a
        // foreground delivery is only a reactivation race. Suppress it to keep
        // the pre-delegate behavior of silent foreground delivery.
        []
    }

    /// Pure payload → deep-link mapping, unit-tested without live notifications.
    static func deepLinkURL(for userInfo: [AnyHashable: Any]) -> URL? {
        guard let sessionID = userInfo[ResponseCompletionNotificationRequest.sessionIDUserInfoKey] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return HermesDeepLink.sessionURL(sessionID: sessionID)
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
        subsystem: "com.maurice.semreh",
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

/// DEBUG fixtures are intentionally scene-lifetime values. Recreating 10k rows
/// during SwiftUI body updates distorts the viewport's first-frame measurement.
@MainActor private enum ChatPerformanceLabFixtureCache {
    typealias Fixture = (session: SessionSummary, server: URL, viewModel: ChatViewModel)
    static var standard: Fixture?
    static var tall: Fixture?
    static var fourTall: Fixture?
    static var richThirty: Fixture?

    static func value(tallMessages: Bool, fourTallMessages: Bool, richThirtyMessages: Bool = false) -> Fixture {
        if richThirtyMessages {
            if let richThirty { return richThirty }
            let fixture = ChatViewModel.makeRichThirtyPerformanceLabFixture()
            richThirty = fixture
            return fixture
        }
        if fourTallMessages {
            if let fourTall { return fourTall }
            let fixture = ChatViewModel.makeFourTallPerformanceLabFixture()
            fourTall = fixture
            return fixture
        }
        if tallMessages {
            if let tall { return tall }
            let fixture = ChatViewModel.makeTallPerformanceLabFixture()
            tall = fixture
            return fixture
        }
        if let standard { return standard }
        let fixture = ChatViewModel.makePerformanceLabFixture()
        standard = fixture
        return fixture
    }
}

/// DEBUG-only shared-Back seam: no XCTest idle wait and no external lifecycle.
struct ChatNavigationTimingProbe: ViewModifier {
    let onBack: () -> Void
    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.arguments.contains("--chat-navigation-script") {
            content.onReceive(NotificationCenter.default.publisher(for: Notification.Name("semreh.lab.navigationBack"))) { _ in
                onBack()
            }
        } else {
            content
        }
    }
}

private struct ChatPerformanceLabView: View {
    @State private var fixture: (session: SessionSummary, server: URL, viewModel: ChatViewModel)
    @Environment(\.colorScheme) private var colorScheme
    @State private var prepared: [NativePreparedHighlight] = []
    @State private var preparationComplete = false
    @State private var nativeRichLifecycleGeneration = 0
    @State private var nativeRichLifecycleStreaming = false
    @State private var outgoingMotionMarker: UInt64 = 0
    @State private var premountRichReady = false
    @State private var premountRichFailed = false
    @State private var navigationProbePresented = false
    @State private var navigationProbeCycle = 0
    @State private var navigationProbeBackTime = 0.0
    @State private var navigationProbeTask: Task<Void, Never>?

    private var preparesOneRichBeforeMount: Bool {
        ProcessInfo.processInfo.arguments.contains("--native-direct-premount-rich-one")
            && (fixture.session.sessionId == "representative-120"
                || (fixture.session.sessionId == "semreh-chat-performance-lab"
                    && (ProcessInfo.processInfo.arguments.contains("--native-direct-windowed-10k-diagnostic")
                        || ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic"))))
    }

    private var nativeRichLifecycleFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("--native-rich-lifecycle-fixture")
            && (ProcessInfo.processInfo.arguments.contains("--native-rich-all-eligible-120")
                || ProcessInfo.processInfo.arguments.contains("--native-direct-two-row-proof")
                || ProcessInfo.processInfo.arguments.contains("--native-hosted-rich120-gate"))
            && fixture.session.sessionId == "representative-120"
    }

    private var richThirtyStreamingFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("--chat-performance-rich30-lab")
            && fixture.session.sessionId == "semreh-rich30-lab"
    }

    private var richThirtyBackLabFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("--chat-performance-rich30-back-lab")
            && fixture.session.sessionId == "semreh-rich30-lab"
    }

    @ViewBuilder
    private var windowedPageControls: some View {
        HStack(spacing: 12) {
            Button("Page older (debug)") {
                NotificationCenter.default.post(name: .semrehWindowedTranscriptPageOlder, object: nil)
            }
            .accessibilityIdentifier("windowed-page-older")
            Button("Page newer (debug)") {
                NotificationCenter.default.post(name: .semrehWindowedTranscriptPageNewer, object: nil)
            }
            .accessibilityIdentifier("windowed-page-newer")
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func logNavigationProbe(_ event: String, detail: String = "") {
        let now = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
        fputs("SEMREH_NAV_PROBE event=\(event) cycle=\(navigationProbeCycle) uptime=\(now) \(detail)\n", stderr)
    }

    /// This script measures the shared action handler, NOT physical touch latency.
    /// The early Back deadline is established before SwiftUI begins the rich mount.
    @MainActor private func runNavigationProbe() async {
        for cycle in 1...3 {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            navigationProbeCycle = cycle
            let began = ProcessInfo.processInfo.systemUptime
            logNavigationProbe("open_request")
            navigationProbePresented = true
            let backDelay = cycle == 1 ? 0.1 : 2.0
            do { try await Task.sleep(for: .seconds(backDelay)) } catch { return }
            if cycle == 3 {
                logNavigationProbe("stream_start")
                Task { @MainActor in await fixture.viewModel.appendPerformanceLabStreamingTurn() }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            navigationProbeBackTime = ProcessInfo.processInfo.systemUptime
            let deadlineLag = max(0, navigationProbeBackTime - began - backDelay - (cycle == 3 ? 0.1 : 0))
            logNavigationProbe("back_request", detail: "scheduled_delay_s=\(backDelay) deadline_lag_ms=\(deadlineLag * 1000)")
            NotificationCenter.default.post(name: Notification.Name("semreh.lab.navigationBack"), object: nil)
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            logNavigationProbe("cycle_end", detail: "still_presented=\(navigationProbePresented)")
        }
        logNavigationProbe("script_complete")
    }

    private var scriptedBackLab: some View {
        NavigationStack {
            List {
                NavigationLink(isActive: $navigationProbePresented) {
                    VStack(spacing: 0) {
                        windowedPageControls
                        HStack {
                            Button("Stream rich test turn") {
                                guard !nativeRichLifecycleStreaming else { return }
                                nativeRichLifecycleStreaming = true
                                Task { @MainActor in
                                    await fixture.viewModel.appendPerformanceLabStreamingTurn()
                                    nativeRichLifecycleStreaming = false
                                }
                            }
                            .disabled(nativeRichLifecycleStreaming)
                            .accessibilityIdentifier("rich30-stream-turn")
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        chat.environment(\.nativePreparedHighlights, prepared)
                    }
                    .onAppear { logNavigationProbe("chat_appeared") }
                    .onDisappear { logNavigationProbe("chat_disappeared") }
                } label: {
                    Text("Open rich30 chat")
                        .onAppear {
                            let elapsed = navigationProbeBackTime == 0 ? 0 : (ProcessInfo.processInfo.systemUptime - navigationProbeBackTime) * 1000
                            logNavigationProbe("list_appeared", detail: "since_back_ms=\(elapsed)")
                        }
                }
            }
        }
        .task {
            // The navigation subtree can cancel its view-scoped task on push.
            // Retain this explicitly bounded, DEBUG-only three-cycle runner.
            guard navigationProbeTask == nil else { return }
            navigationProbeTask = Task { @MainActor in await runNavigationProbe() }
        }
    }

    private var outgoingMotionFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("--chat-outgoing-motion-lab")
            && fixture.session.sessionId?.hasPrefix("outgoing-motion-lab-") == true
    }

    private var preparesHighlights: Bool {
        ProcessInfo.processInfo.arguments.contains("--native-prepared-highlights")
            && fixture.session.sessionId?.hasPrefix("representative-") == true
    }

    init(tallMessages: Bool = false, fourTallMessages: Bool = false, richThirtyMessages: Bool = false) {
        NativeOpeningTrace.shared.begin()
        _fixture = State(initialValue: ChatPerformanceLabFixtureCache.value(
            tallMessages: tallMessages, fourTallMessages: fourTallMessages,
            richThirtyMessages: richThirtyMessages
        ))
    }

    var body: some View {
        Group {
            if preparesOneRichBeforeMount && !premountRichReady {
                if premountRichFailed {
                    Text("Rich fixture preparation failed")
                } else {
                    ProgressView("Preparing rich response")
                }
            } else if preparesHighlights && !preparationComplete {
                ProgressView("Preparing fixture highlighting")
            } else if outgoingMotionFixture {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Button("Inject local send") {
                            if let sequence = fixture.viewModel.appendOutgoingMotionFixtureMessage() {
                                outgoingMotionMarker = sequence
                            }
                        }
                        .accessibilityIdentifier("outgoing-motion-inject")
                        Text("motion marker \(outgoingMotionMarker)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.black)
                            .frame(width: 144, height: 28)
                            .background(outgoingMotionMarker.isMultiple(of: 2) ? Color.yellow : Color.green)
                            .accessibilityIdentifier("outgoing-motion-marker")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    chat
                }
            } else if nativeRichLifecycleFixture {
                VStack(spacing: 0) {
                    HStack {
                        Button("Stream rich test turn") {
                            guard !nativeRichLifecycleStreaming else { return }
                            nativeRichLifecycleStreaming = true
                            Task { @MainActor in
                                await fixture.viewModel.appendPerformanceLabStreamingTurn()
                                nativeRichLifecycleStreaming = false
                            }
                        }
                        .disabled(nativeRichLifecycleStreaming)
                        Button("Reopen rich chat") {
                            Logger(subsystem: "com.maurice.semreh", category: "NativeRichLifecycle")
                                .debug("event=fixture_reopen_before rows=\(fixture.viewModel.messages.count, privacy: .public)")
                            nativeRichLifecycleGeneration += 1
                        }
                        .accessibilityValue("\(fixture.viewModel.messages.count) rows")
                        if ProcessInfo.processInfo.arguments.contains("--native-direct-two-row-proof") {
                            Button("Refresh rows") {
                                fixture.viewModel.bumpUnchangedTranscriptRevisionForTesting()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    chat.environment(\.nativePreparedHighlights, prepared)
                        .id(nativeRichLifecycleGeneration)
                        .task(id: nativeRichLifecycleGeneration) {
                            Logger(subsystem: "com.maurice.semreh", category: "NativeRichLifecycle")
                                .debug("event=fixture_reopen_after rows=\(fixture.viewModel.messages.count, privacy: .public)")
                        }
                }
            } else if richThirtyBackLabFixture && ProcessInfo.processInfo.arguments.contains("--chat-navigation-script") {
                scriptedBackLab
            } else if richThirtyBackLabFixture {
                NavigationStack {
                    List {
                        NavigationLink("Open rich30 chat") {
                            VStack(spacing: 0) {
                                windowedPageControls
                                HStack {
                                    Button("Stream rich test turn") {
                                        guard !nativeRichLifecycleStreaming else { return }
                                        nativeRichLifecycleStreaming = true
                                        Task { @MainActor in
                                            await fixture.viewModel.appendPerformanceLabStreamingTurn()
                                            nativeRichLifecycleStreaming = false
                                        }
                                    }
                                    .disabled(nativeRichLifecycleStreaming)
                                    .accessibilityIdentifier("rich30-stream-turn")
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 4)
                                chat.environment(\.nativePreparedHighlights, prepared)
                            }
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            ChatPerformanceCadenceMonitor.begin(.entry)
                        })
                    }
                    .onAppear { ChatPerformanceCadenceMonitor.end(.back) }
                }
            } else if richThirtyStreamingFixture {
                VStack(spacing: 0) {
                    windowedPageControls
                    HStack {
                        Button("Stream rich test turn") {
                            guard !nativeRichLifecycleStreaming else { return }
                            nativeRichLifecycleStreaming = true
                            Task { @MainActor in
                                await fixture.viewModel.appendPerformanceLabStreamingTurn()
                                nativeRichLifecycleStreaming = false
                            }
                        }
                        .disabled(nativeRichLifecycleStreaming)
                        .accessibilityIdentifier("rich30-stream-turn")
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    chat.environment(\.nativePreparedHighlights, prepared)
                }
            } else if ProcessInfo.processInfo.arguments.contains("--chat-windowed-eager") {
                VStack(spacing: 0) {
                    windowedPageControls
                    chat.environment(\.nativePreparedHighlights, prepared)
                }
            } else {
                chat.environment(\.nativePreparedHighlights, prepared)
            }
        }
        .task {
            guard preparesOneRichBeforeMount, !premountRichReady, !premountRichFailed else { return }
            let started = CACurrentMediaTime()
            let logger = Logger(subsystem: "com.maurice.semreh", category: "ViewportPrototype")
            NativePremountRichFixtureStore.entry = nil
            NativePremountRichFixtureStore.target = nil
            NativePremountRichFixtureStore.path = [:]
            guard fixture.viewModel.messages.indices.contains(1),
                  let source = fixture.viewModel.messages[1].content,
                  let id = fixture.viewModel.messages[1].messageId else {
                premountRichFailed = true
                logger.error("event=premount_rich_missing_source")
                return
            }
            let width = Double(UIScreen.main.bounds.width - 80)
            if ProcessInfo.processInfo.arguments.contains("--native-direct-premount-rich-link-bidi"),
               let syntheticURL = URL(string: "https://example.invalid/reference") {
                // The signed fixture exercises the existing card and cache
                // semantics without issuing a metadata request to the network.
                await TranscriptLinkPreviewCache.shared.store(
                    TranscriptLinkPreviewSnapshot(displayURL: syntheticURL), for: syntheticURL)
            }
            let dark = colorScheme == .dark
            let wraps = UserDefaults.standard.bool(forKey: ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey)
            let result = await NativeRichRowPreparationActor.shared.prepare(
                source: source, width: width, dark: dark, wrapsCodeLines: wraps)
            guard case .ready(let body) = result,
                  body.sourceBytes == Array(source.utf8),
                  body.dark == dark, body.wrapsCodeLines == wraps else {
                premountRichFailed = true
                logger.error("event=premount_rich_unsupported wallMs=\(Int((CACurrentMediaTime() - started) * 1_000), privacy: .public)")
                return
            }
            NativePremountRichFixtureStore.entry = .init(messageID: id, source: source,
                bodyWidth: width, snapshot: body)
            if ProcessInfo.processInfo.arguments.contains("--native-direct-target-first-immediate-diagnostic")
                || ProcessInfo.processInfo.arguments.contains("--native-direct-windowed-10k-diagnostic")
                || ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic") {
                guard let last = fixture.viewModel.messages.last,
                      let targetSource = last.content, let targetID = last.messageId,
                      case .ready(let targetBody) = await NativeRichRowPreparationActor.shared.prepare(
                        source: targetSource, width: width, dark: dark, wrapsCodeLines: wraps),
                      targetBody.sourceBytes == Array(targetSource.utf8),
                      targetBody.dark == dark, targetBody.wrapsCodeLines == wraps else {
                    premountRichFailed = true
                    logger.error("event=premount_rich_target_unsupported")
                    return
                }
                NativePremountRichFixtureStore.target = .init(messageID: targetID,
                    source: targetSource, bodyWidth: width, snapshot: targetBody)
                logger.debug("event=premount_rich_target_ready wallMs=\(Int((CACurrentMediaTime() - started) * 1_000), privacy: .public) height=\(targetBody.height, privacy: .public)")
            }
            if ProcessInfo.processInfo.arguments.contains("--native-direct-bounded-path-immediate-diagnostic")
                || ProcessInfo.processInfo.arguments.contains("--native-direct-windowed-10k-diagnostic") {
                // Only measured cold-jump rows in this 120-row synthetic proof;
                // every snapshot is prepared from its actual source and ID.
                let pathIndices = ProcessInfo.processInfo.arguments.contains("--native-direct-windowed-10k-diagnostic")
                    ? [3] : [5, 7, 23, 25, 69, 71, 99, 101, 111, 113, 115, 117]
                var path: [Int: NativePremountRichFixtureStore.Entry] = [:]
                for index in pathIndices {
                    guard fixture.viewModel.messages.indices.contains(index),
                          let messageSource = fixture.viewModel.messages[index].content,
                          let messageID = fixture.viewModel.messages[index].messageId,
                          case .ready(let snapshot) = await NativeRichRowPreparationActor.shared.prepare(
                            source: messageSource, width: width, dark: dark, wrapsCodeLines: wraps),
                          snapshot.sourceBytes == Array(messageSource.utf8),
                          snapshot.dark == dark, snapshot.wrapsCodeLines == wraps else {
                        premountRichFailed = true
                        logger.error("event=premount_rich_path_unsupported index=\(index, privacy: .public)")
                        return
                    }
                    path[index] = .init(messageID: messageID, source: messageSource,
                        bodyWidth: width, snapshot: snapshot)
                }
                NativePremountRichFixtureStore.path = path
                logger.debug("event=premount_rich_path_ready count=\(path.count, privacy: .public) wallMs=\(Int((CACurrentMediaTime() - started) * 1_000), privacy: .public)")
            }
            logger.debug("event=premount_rich_ready wallMs=\(Int((CACurrentMediaTime() - started) * 1_000), privacy: .public) width=\(width, privacy: .public) variants=1")
            premountRichReady = true
        }
        .task(id: colorScheme) {
            guard preparesHighlights else { return }
            preparationComplete = false
            let started = CACurrentMediaTime()
            var values: [NativePreparedHighlight] = []
            // Exactly the code bytes emitted by this bounded representative fixture,
            // after MarkdownUI removes its terminal newline. Preparation is visible opening
            // work and timed in full, not an offscreen target view warm-up.
            for index in fixture.viewModel.messages.indices where !index.isMultiple(of: 2) {
                let request = MarkdownCodeHighlightRequest(code: "let answer = values.map { $0 + \(index) }\nprint(answer)", language: "swift", colorScheme: colorScheme, isStreaming: false)
                if case .highlighted(let code) = await MarkdownCodeHighlightWorker.shared.highlightedCode(for: request) {
                    values.append(NativePreparedHighlight(request: request, code: code))
                }
                guard !Task.isCancelled else { return }
            }
            prepared = values
            preparationComplete = true
            Logger(subsystem: "com.maurice.semreh", category: "NativeBaseline").debug("event=fixture_preparation count=\(values.count, privacy: .public) elapsedMS=\((CACurrentMediaTime()-started)*1000, privacy: .public)")
        }
    }

    private var chat: some View {
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

/// App-owned, server-free proof of the ordinary transcript's live → retained
/// activity handoff. Unlike the component lab, this mounts ChatTranscriptView
/// in the real scene and keeps message/render IDs stable across every update.
private struct ChatActivityHandoffLabView: View {
    @State private var liveReasoningText = "Inspecting the current source segment."
    @State private var phase = 0
    @State private var updateTask: Task<Void, Never>?

    private let activeAnchor = "activity-handoff-current-assistant"
    private let bottomAnchor = "activity-handoff-bottom"

    private var messages: [ChatMessage] {
        [
            ChatMessage(role: "user", content: "Review the previous result.",
                        timestamp: 1, messageId: "activity-handoff-old-user"),
            ChatMessage(role: "assistant", content: "The previous result is available.",
                        timestamp: 2, messageId: "activity-handoff-old-assistant"),
            ChatMessage(role: "user", content: "Inspect the source.",
                        timestamp: 3, messageId: "activity-handoff-current-user"),
            ChatMessage(role: "assistant", content: "",
                        timestamp: 4, messageId: activeAnchor)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Advance activity") { advanceActivity() }
                    .disabled(updateTask != nil)
                    .accessibilityIdentifier("activity-handoff-advance")

                Text("activity phase \(phase)")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .frame(width: 150, height: 28)
                    .background(phase.isMultiple(of: 2) ? Color.yellow : Color.green)
                    .foregroundStyle(.black)
                    .accessibilityIdentifier("activity-handoff-phase")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ChatTranscriptView(
                isLoading: false, errorMessage: nil,
                messages: messages,
                displayedTranscriptMessages: messages.enumerated().map { index, message in
                    TranscriptMessage(loadedIndex: index, renderID: message.id,
                                      anchorID: message.id, message: message)
                },
                compressionReferenceCard: nil,
                reasoningGroupsForAnchor: { anchor in
                    guard anchor == activeAnchor else { return [] }
                    return [ReasoningGroup(id: "activity-handoff-retained", anchorMessageID: activeAnchor,
                                           text: "Retained source analysis.")]
                },
                completedToolCallGroupsForAnchor: { anchor in
                    guard anchor == activeAnchor else { return [] }
                    return [ToolCallGroup(id: "activity-handoff-tools", anchorMessageID: activeAnchor,
                                          toolCalls: [ToolCall(
                                            id: "activity-handoff-read", name: "read_file",
                                            preview: "Synthetic source content.",
                                            args: ["path": .string("fixtures/example.md")],
                                            isCompleted: true, startedAt: 5
                                          )])]
                },
                liveReasoningText: liveReasoningText,
                reasoningAnchorMessageID: activeAnchor,
                liveToolCalls: [], toolCallAnchorMessageID: nil,
                streamingAssistantMessageID: activeAnchor, liveTokensPerSecond: nil,
                activeStreamRecoveryState: .idle, clarificationPrompt: nil,
                isRespondingToClarification: false, clarificationErrorMessage: nil,
                hidesRunStatusAccessibility: false, showsThinkingAndToolCards: true,
                showsAssistantTypingIndicator: liveReasoningText.isEmpty,
                showsScrollToBottomButton: false, shouldFollowLatestMessage: true,
                latestTranscriptMessageRole: "assistant", isScrolledNearBottom: true,
                activeStreamID: "activity-handoff-synthetic-run", streamingScrollTrigger: 0,
                cacheFirstReconcileScrollToken: 0, bottomAnchorID: bottomAnchor,
                transcriptMessageSpacing: 10, transcriptBlockSpacing: 4,
                transcriptBottomInsetHeight: 0, scrollToBottomButtonBottomPadding: 0,
                localAttachmentPreviews: [:], listeningMessageID: nil,
                isViewingCachedData: false, hasOlderMessages: false, isLoadingOlderMessages: false,
                isRegeneratingMessage: false, isEditingMessage: false, isForkingMessage: false,
                loadAttachmentImage: { _ in nil }, loadAttachmentData: { _ in nil },
                loadTranscriptMediaImage: { _ in nil }, loadTranscriptMediaData: { _ in nil },
                transcriptMediaCacheNamespace: "activity-handoff-synthetic",
                actionContext: { _, _ in nil },
                shouldRenderMessageRow: { message in
                    message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                },
                onLoadMessages: {}, onLoadOlderMessages: { _, _ in .noProgress },
                onUpdateScrollMetrics: { _ in }, onDismissKeyboard: {},
                onScrollToBottom: { _, _, _, _ in }, onScrollToLatestTranscriptMessage: { _ in },
                onScrollToLatestContent: { _, _ in },
                onPreviewAttachment: { _, _ in }, onPreviewTranscriptMedia: { _ in },
                onToggleListening: { _ in }, onSubmitClarification: { _, _ in },
                onCancelClarification: { _ in }, onSelectText: { _ in },
                onRegenerate: { _ in }, onEdit: { _ in }, onFork: { _ in }, onCopy: { _ in },
                transcriptRenderRevision: phase
            )
            .equatable()
        }
        .navigationTitle("Activity handoff")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { updateTask?.cancel() }
    }

    private func advanceActivity() {
        guard updateTask == nil else { return }
        updateTask = Task { @MainActor in
            for (index, chunk) in [
                " Checking the retained evidence.",
                " Comparing the next source segment.",
                " Preparing a concise result."
            ].enumerated() {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                liveReasoningText += chunk
                phase = index + 1
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            liveReasoningText = ""
            phase = 4
            updateTask = nil
        }
    }
}

/// Local-only activity lifecycle inside the actual ChatView and composer.
/// The first phase deliberately has old unanchored reasoning and a newer user
/// turn, so the two statuses must not print the same visible Thinking label.
private struct ChatFullActivityLabView: View {
    @State private var fixture: (session: SessionSummary, server: URL, viewModel: ChatViewModel)
    @State private var phase = 0

    init(anchoredHistory: Bool = false) {
        _fixture = State(initialValue: ChatViewModel.makeFullActivityLabFixture(
            anchoredHistory: anchoredHistory
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Advance activity state") {
                    guard phase < 2 else { return }
                    phase += 1
                    fixture.viewModel.advanceFullActivityLab(to: phase)
                }
                .disabled(phase >= 2)
                .accessibilityIdentifier("full-activity-advance")

                Text("full activity phase \(phase)")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .frame(width: 160, height: 28)
                    .background(phase.isMultiple(of: 2) ? Color.yellow : Color.green)
                    .foregroundStyle(.black)
                    .accessibilityIdentifier("full-activity-phase")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ChatView(
                session: fixture.session, server: fixture.server,
                onAPIError: { _ in }, loadsInitialMessages: false,
                retainedViewModel: fixture.viewModel, disablesExternalLifecycle: true
            )
        }
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


#if DEBUG
/// Both clocks are recorded because systemUptime is the interval clock and
/// epoch time lets an external native trace identify the same process run.
private struct ChatPerformanceSwitchStamp: Encodable {
    let uptimeSeconds: TimeInterval
    let epochMilliseconds: Int64

    static func now() -> Self {
        Self(
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            epochMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
    }
}

private enum ChatPerformanceAutoSwitchLaunch {
    static let appInit = ChatPerformanceSwitchStamp.now()
    static let flag = "--chat-performance-auto-switch"
    static let runIDPrefix = "--chat-performance-auto-switch-run-id="

    static func runID(arguments: [String]) -> UUID? {
        guard arguments.filter({ $0 == flag }).count == 1 else { return nil }
        let values = arguments.filter { $0.hasPrefix(runIDPrefix) }
        guard values.count == 1 else { return nil }
        let raw = String(values[0].dropFirst(runIDPrefix.count))
        guard let id = UUID(uuidString: raw), id.uuidString == raw.uppercased() else { return nil }
        return id
    }
}

private struct ChatPerformanceAutoSwitchStep: Encodable {
    let processID: Int32
    let requestedChatNumber: Int
    let generation: Int
    let request: ChatPerformanceSwitchStamp
    let destinationLifecycleOnAppear: ChatPerformanceSwitchStamp?
    var destinationActivationObserved: ChatPerformanceSwitchStamp? = nil
    let outcome: String
}

private struct ChatPerformanceAutoSwitchReport: Encodable {
    let schema: String
    let runID: String
    let processID: Int32
    let clockDomain: String
    let readinessScope: String
    let preparationScope: String
    let appInit: ChatPerformanceSwitchStamp
    let fixtureInitStart: ChatPerformanceSwitchStamp
    let fixtureInitEnd: ChatPerformanceSwitchStamp
    let driverStart: ChatPerformanceSwitchStamp
    let initialDestinationLifecycleOnAppear: ChatPerformanceSwitchStamp?
    let steps: [ChatPerformanceAutoSwitchStep]
    let finished: ChatPerformanceSwitchStamp
    let outcome: String
    let appWideCallbackReport: String?
    var retainedRootCount: Int? = nil
    var rootMountCount: Int? = nil
    var rootActivationCount: Int? = nil
    var activeChatIdentity: String? = nil
}
#endif

/// DEBUG rich-multi lab only. SwiftUI owns one representable per visited ID;
/// each representable owns one hosting controller for its entire lifetime.
/// Controller containment and root identity remain stable; inactive native views
/// detach from the window while their hosting controller and state stay retained.
private struct ChatPerformanceRetainedRootHost<Content: View>: UIViewControllerRepresentable {
    let isActive: Bool
    let content: Content
    let onMount: () -> Void

    /// A hosting boundary does not inherit the surrounding SwiftUI graph.
    /// Forward all environment values (including modelContext, scenePhase,
    /// palette, color scheme and dynamic type) on every update. Navigation
    /// preferences cannot cross that boundary, so each retained tree owns its
    /// own stable stack, including file/branch destinations and presentations.
    struct Root: View {
        var content: Content
        var environment: EnvironmentValues

        var body: some View {
            NavigationStack {
                content
            }
            .environment(\.self, environment)
        }
    }

    /// SwiftUI owns the representable's outer view. Keep the retained hosting
    /// view behind a separate UIKit containment boundary so inactive content is
    /// genuinely outside the window/AX tree, not merely transparent within it.
    final class Container: UIViewController {
        final class Surface: UIView {
            var acceptsInteraction = true
            override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
                guard acceptsInteraction else { return nil }
                return super.hitTest(point, with: event)
            }
        }

        let host: UIHostingController<Root>
        private var selected = false

        init(root: Root) {
            host = UIHostingController(rootView: root)
            super.init(nibName: nil, bundle: nil)
            host.safeAreaRegions = .container
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func loadView() {
            view = Surface()
            view.backgroundColor = .clear
            addChild(host)
            host.view.backgroundColor = .clear
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.didMove(toParent: self)
        }

        func update(root: Root, active: Bool) {
            loadViewIfNeeded()
            host.rootView = root
            selected = active
            (view as? Surface)?.acceptsInteraction = active
            host.view.isUserInteractionEnabled = active
            host.view.accessibilityElementsHidden = !active
            if active {
                if host.view.superview == nil {
                    host.view.frame = view.bounds
                    view.addSubview(host.view)
                }
            } else {
                // Retain the controller, root state, native view and its last
                // geometry. Detach only the inactive view from the visible tree.
                host.view.removeFromSuperview()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if selected { host.view.frame = view.bounds }
        }
    }

    func makeUIViewController(context: Context) -> Container {
        let container = Container(root: Root(content: content, environment: context.environment))
        container.update(root: Root(content: content, environment: context.environment), active: isActive)
        let didMount = onMount
        DispatchQueue.main.async { didMount() }
        return container
    }

    func updateUIViewController(_ container: Container, context: Context) {
        container.update(root: Root(content: content, environment: context.environment), active: isActive)
    }
}

private struct ChatPerformanceMultiLabView: View {
    @State private var fixtures: [(
        session: SessionSummary,
        server: URL,
        viewModel: ChatViewModel
    )]
    @State private var selectedChat = 0
    @State private var visitedRoots: Set<Int> = [0]
    @State private var activationObservations: [Int: ChatPerformanceSwitchStamp] = [:]
    @State private var rootMountCount = 0
    @State private var rootActivationCount = 0
    @State private var producerGeneration = 0
    private var retainsRoots: Bool {
        richThirty && ProcessInfo.processInfo.arguments.contains("--chat-performance-retained-roots")
    }
    @State private var isStreamingFixture = false
    @State private var streamingTask: Task<Void, Never>?
    @State private var switchGeneration = 0
    @State private var lifecycleAppearances: [Int: ChatPerformanceSwitchStamp] = [:]
    @State private var autoRunStarted = false
    @State private var autoRunFinished = false
    private let richThirty: Bool
    private let fixtureInitStart: ChatPerformanceSwitchStamp
    private let fixtureInitEnd: ChatPerformanceSwitchStamp
    private let autoRunID: UUID?

    init(richThirty: Bool = false) {
        self.richThirty = richThirty
        fixtureInitStart = .now()
        let preparedFixtures = richThirty
            ? (1...2).map { ChatViewModel.makeRichThirtyPerformanceLabFixture(identity: $0) }
            : ChatViewModel.makePerformanceLabFixtures()
        fixtureInitEnd = .now()
        _fixtures = State(initialValue: preparedFixtures)
        autoRunID = richThirty
            ? ChatPerformanceAutoSwitchLaunch.runID(arguments: ProcessInfo.processInfo.arguments)
            : nil
    }

    @MainActor private func selectChat(_ index: Int) {
        guard selectedChat != index else { return }
        ChatPerformanceCadenceMonitor.begin(.switchChat)
        if retainsRoots {
            streamingTask?.cancel()
            visitedRoots.insert(index)
        }
        if retainsRoots || (autoRunID != nil && !autoRunFinished) { switchGeneration += 1 }
        selectedChat = index
    }

    /// A bounded wait for the actual destination lifecycle callback. Its
    /// 20 ms check cadence is not used as a readiness or frame measurement.
    @MainActor private func waitForAppearance(
        generation: Int,
        timeoutSeconds: TimeInterval = 6
    ) async -> ChatPerformanceSwitchStamp? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        ChatPerformanceInvalidationProbe.shared?.record("driver_wait_begin", a: min(generation, 1_000_000))
        while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
            if let appearance = (retainsRoots ? activationObservations[generation] : lifecycleAppearances[generation]) {
                ChatPerformanceInvalidationProbe.shared?.record("driver_appearance_found", a: min(generation, 1_000_000))
                return appearance
            }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch {
                ChatPerformanceInvalidationProbe.shared?.record("driver_wait_cancelled", a: min(generation, 1_000_000))
                return nil
            }
        }
        ChatPerformanceInvalidationProbe.shared?.record(
            Task.isCancelled ? "driver_wait_cancelled" : "driver_wait_deadline",
            a: min(generation, 1_000_000)
        )
        return retainsRoots ? activationObservations[generation] : lifecycleAppearances[generation]
    }

    @MainActor private func writeAutoReport(_ report: ChatPerformanceAutoSwitchReport) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONEncoder().encode(report) else { return }
        let url = documents.appendingPathComponent("chat-performance-auto-switch-\(report.runID).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // The diagnostic is finite even if the sandbox cannot persist its report.
            fputs("SEMREH_AUTO_SWITCH report_write_failed run_id=\(report.runID)\n", stderr)
        }
    }

    @MainActor private func runAutoSwitch(runID: UUID) async {
        let driverStart = ChatPerformanceSwitchStamp.now()
        var steps: [ChatPerformanceAutoSwitchStep] = []
        let initialAppearance = await waitForAppearance(generation: 0)
        var outcome = initialAppearance == nil ? (Task.isCancelled ? "cancelled" : "initial_destination_timeout") : "complete"

        if initialAppearance != nil {
            // Diagnostic-only finite repetition; ordinary four-switch baseline
            // and all production routing remain unchanged. No unbounded loop.
            let switchCount = ProcessInfo.processInfo.arguments.contains(
                "--chat-performance-repeat-switches") ? 24 : 4
            for visit in 0..<switchCount {
                let destination = visit.isMultiple(of: 2) ? 1 : 0
                if Task.isCancelled { outcome = "cancelled"; break }
                let request = ChatPerformanceSwitchStamp.now()
                ChatPerformanceInvalidationProbe.shared?.record("driver_switch_request", a: destination + 1)
                selectChat(destination)
                let generation = switchGeneration
                let appearance = await waitForAppearance(generation: generation)
                ChatPerformanceInvalidationProbe.shared?.record("driver_wait_return", a: min(generation, 1_000_000), b: appearance == nil ? 0 : 1)
                let stepOutcome = appearance != nil ? (retainsRoots ? "destination_activation_observed" : "destination_lifecycle_on_appear") : (Task.isCancelled ? "cancelled" : "timeout")
                steps.append(ChatPerformanceAutoSwitchStep(
                    processID: ProcessInfo.processInfo.processIdentifier,
                    requestedChatNumber: destination + 1,
                    generation: generation,
                    request: request,
                    destinationLifecycleOnAppear: retainsRoots ? lifecycleAppearances[generation] : appearance,
                    destinationActivationObserved: retainsRoots ? appearance : nil,
                    outcome: stepOutcome
                ))
                if appearance == nil { outcome = stepOutcome; break }
                // Separate actions after an observed callback; this delay is
                // outside the scored request-to-callback interval.
                ChatPerformanceInvalidationProbe.shared?.record("driver_sleep_begin", a: min(generation, 1_000_000))
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { outcome = "cancelled"; break }
                ChatPerformanceInvalidationProbe.shared?.record("driver_sleep_end", a: min(generation, 1_000_000))
            }
        }
        if Task.isCancelled && outcome == "complete" { outcome = "cancelled" }

        writeAutoReport(ChatPerformanceAutoSwitchReport(
            schema: "semreh.chat.auto_switch.v1",
            runID: runID.uuidString,
            processID: ProcessInfo.processInfo.processIdentifier,
            clockDomain: "ProcessInfo.systemUptime seconds since boot; epochMilliseconds Unix wall clock",
            readinessScope: retainsRoots
                ? "retained ChatView current-generation activity callback; SwiftUI onAppear recorded separately; mounts count native host creation; not rendered frame or FPS"
                : "destination ChatView wrapper lifecycle onAppear; not first presented frame, FPS, or physical tap latency",
            preparationScope: "appInit is HermesMobileApp.init entry; fixtureInitStart/End bracket lab fixture creation; process launch, Swift runtime and App construction before appInit are unmeasured",
            appInit: ChatPerformanceAutoSwitchLaunch.appInit,
            fixtureInitStart: fixtureInitStart,
            fixtureInitEnd: fixtureInitEnd,
            driverStart: driverStart,
            initialDestinationLifecycleOnAppear: retainsRoots ? lifecycleAppearances[0] : initialAppearance,
            steps: steps,
            finished: .now(),
            outcome: outcome,
            appWideCallbackReport: ChatPerformanceCadenceMonitor.isAppWideOptedIn
                ? ChatPerformanceCadenceMonitor.shared.summary().formattedReport : nil,
            retainedRootCount: retainsRoots ? visitedRoots.count : nil,
            rootMountCount: retainsRoots ? rootMountCount : nil,
            rootActivationCount: retainsRoots ? rootActivationCount : nil,
            activeChatIdentity: retainsRoots ? fixtures[selectedChat].session.id : nil
        ))
        autoRunFinished = true
        if outcome == "complete",
           ProcessInfo.processInfo.arguments.contains("--chat-performance-auto-stream"),
           ProcessInfo.processInfo.arguments.contains("--chat-performance-paced-stream") {
            let model = fixtures[selectedChat].viewModel
            let producer = startStreamingTurn()
            await withTaskCancellationHandler {
                await producer.value
            } onCancel: {
                producer.cancel()
            }
            if var evidence = model.pacedPerformanceLabEvidence,
               let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                evidence["run_id"] = runID.uuidString
                evidence["process_id"] = ProcessInfo.processInfo.processIdentifier
                evidence["clock_domain"] = "ProcessInfo.systemUptime seconds since boot"
                evidence["app_wide_callback_report"] = ChatPerformanceCadenceMonitor.shared.summary().formattedReport
                if let probe = StreamingFadeWorkProbe.shared {
                    evidence["fade_draw_work"] = probe.snapshot()
                }
                do {
                    let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                    try data.write(to: documents.appendingPathComponent("chat-performance-paced-stream-\(runID.uuidString).json"), options: .atomic)
                } catch {
                    fputs("SEMREH_PACED_STREAM report_write_failed\n", stderr)
                }
            }
        }
        // Keep the same run UUID as the switch and paced-stream reports.
        // Export after the awaited stream, or after switches in switch-only mode.
        ChatPerformanceInvalidationProbe.shared?.write(runID: runID)
    }

    /// All producers share one chain: cancel and join the predecessor before
    /// touching the next model. Generation ownership prevents stale cleanup.
    @MainActor private func startStreamingTurn() -> Task<Void, Never> {
        let previous = streamingTask
        previous?.cancel()
        producerGeneration += 1
        let generation = producerGeneration
        let index = selectedChat
        let model = fixtures[index].viewModel
        isStreamingFixture = true
        let task = Task { @MainActor in
            if let previous { await previous.value }
            if !Task.isCancelled, generation == producerGeneration, selectedChat == index {
                await model.appendPerformanceLabStreamingTurn()
            }
            guard generation == producerGeneration else { return }
            isStreamingFixture = false
            streamingTask = nil
        }
        streamingTask = task
        return task
    }

    private func retainedRoot(_ index: Int) -> some View {
        let fixture = fixtures[index]
        let active = selectedChat == index
        return ChatView(
            session: fixture.session,
            server: fixture.server,
            onAPIError: { _ in },
            loadsInitialMessages: false,
            retainedViewModel: fixture.viewModel,
            disablesExternalLifecycle: true,
            isPresentationActive: active,
            onPresentationActivation: {
                guard selectedChat == index else { return }
                // This callback follows the destination's effective activity gate.
                activationObservations[switchGeneration] = .now()
                rootActivationCount += 1
                ChatPerformanceCadenceMonitor.end(.switchChat)
            }
        )
        .onAppear {
            if selectedChat == index { lifecycleAppearances[switchGeneration] = .now() }
        }

    }

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(fixtures.indices, id: \.self) { index in
                    Button {
                        selectChat(index)
                    } label: {
                        Text("Performance chat \(index + 1)")
                            .font(.caption)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedChat == index ? .accentColor : .secondary)
                    .accessibilityLabel("Performance chat \(index + 1)")
                    .accessibilityAddTraits(selectedChat == index ? .isSelected : [])
                }

                Button {
                    guard !isStreamingFixture else { return }
                    _ = startStreamingTurn()
                } label: {
                    Text("Stream test turn")
                        .font(.caption)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isStreamingFixture)
                .accessibilityLabel("Stream test turn")
                .accessibilityValue(isStreamingFixture ? "Streaming" : "Ready")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if retainsRoots {
                ZStack {
                    ForEach(visitedRoots.sorted(), id: \.self) { index in
                        ChatPerformanceRetainedRootHost(
                            isActive: selectedChat == index,
                            content: retainedRoot(index),
                            onMount: { rootMountCount += 1 }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                // The child hosts own navigation; suppress only the lab's
                // otherwise empty outer bar. Production routing is untouched.
                .toolbar(.hidden, for: .navigationBar)
            } else {
            let fixture = fixtures[selectedChat]
            ChatView(
                session: fixture.session,
                server: fixture.server,
                onAPIError: { _ in },
                loadsInitialMessages: false,
                retainedViewModel: fixture.viewModel,
                disablesExternalLifecycle: true
            )
            .onAppear {
                if autoRunID != nil && !autoRunFinished {
                    lifecycleAppearances[switchGeneration] = .now()
                }
            }
            // The observer must be inside the replaced destination identity.
            // An observer outside .id remains mounted across A/B switches.
            .id(fixture.session.id)
            }
        }
        // Diagnostic controls must not enlarge the viewport offered to ChatView.
        // Keep the real device width; do not clip an already oversized transcript.
        .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task {
            guard let autoRunID, !autoRunStarted else { return }
            autoRunStarted = true
            await runAutoSwitch(runID: autoRunID)
        }
        .onDisappear {
            streamingTask?.cancel()
            // Keep the cancelled task until its generation-owned cleanup joins it.

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
    @Binding private var isFrameCallbackProbeSampling: Bool
    @Binding private var frameCallbackProbeSummary: String?
    @Binding private var frameCallbackAccumulator: ChatFrameCallbackTimingAccumulator?
    private let frameCallbackProbeEnabled: Bool

    init(
        frameCallbackProbeEnabled: Bool,
        isFrameCallbackProbeSampling: Binding<Bool>,
        frameCallbackProbeSummary: Binding<String?>,
        frameCallbackAccumulator: Binding<ChatFrameCallbackTimingAccumulator?>,
        fixtures: [(
            session: SessionSummary,
            server: URL,
            viewModel: ChatViewModel
        )]
    ) {
        self.frameCallbackProbeEnabled = frameCallbackProbeEnabled
        self._isFrameCallbackProbeSampling = isFrameCallbackProbeSampling
        self._frameCallbackProbeSummary = frameCallbackProbeSummary
        self._frameCallbackAccumulator = frameCallbackAccumulator
        self.fixtures = fixtures
    }

    var body: some View {
        List {
            if frameCallbackProbeEnabled {
                Section {
                    if isFrameCallbackProbeSampling {
                        Button("Stop and read callback summary") {
                            frameCallbackAccumulator?.pause()
                            isFrameCallbackProbeSampling = false
                            frameCallbackProbeSummary = frameCallbackAccumulator?.summary().formattedReport
                        }
                        .accessibilityIdentifier("frame-callback-probe-stop")
                    } else {
                        Button(frameCallbackProbeSummary == nil ? "Start callback sample" : "Start new callback sample") {
                            let accumulator = ChatFrameCallbackTimingAccumulator()
                            accumulator.reset()
                            frameCallbackAccumulator = accumulator
                            frameCallbackProbeSummary = nil
                            isFrameCallbackProbeSampling = true
                        }
                        .accessibilityIdentifier("frame-callback-probe-start")
                    }

                    if let frameCallbackProbeSummary {
                        Text(frameCallbackProbeSummary)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("chat-performance-frame-callback-summary")
                    } else {
                        Text("Callback timing only; this is not presented-frame or FPS evidence.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Callback timing probe")
                }
            }

            Section {
                ForEach(fixtures.indices, id: \.self) { index in
                    Button {
                        visitCount += 1
                        ChatPerformanceCadenceMonitor.begin(.entry)
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
                    ChatPerformanceCadenceMonitor.end(.back)
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

/// Keeps the opt-in callback probe host attached above the navigation push so
/// its sampling window spans both the lab list and the long-chat destinations.
private struct ChatPerformanceCycleLabContainer: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var fixtureStore = ChatPerformanceCycleLabFixtureStore()
    @State private var isFrameCallbackProbeSampling = false
    @State private var frameCallbackProbeSummary: String?
    @State private var frameCallbackAccumulator: ChatFrameCallbackTimingAccumulator?

    private var frameCallbackProbeEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--chat-performance-frame-callback-probe")
    }

    var body: some View {
        NavigationStack {
            ChatPerformanceCycleLabView(
                frameCallbackProbeEnabled: frameCallbackProbeEnabled,
                isFrameCallbackProbeSampling: $isFrameCallbackProbeSampling,
                frameCallbackProbeSummary: $frameCallbackProbeSummary,
                frameCallbackAccumulator: $frameCallbackAccumulator,
                fixtures: fixtureStore.fixtures
            )
        }
        .overlay(alignment: .topLeading) {
            if frameCallbackProbeEnabled,
               isFrameCallbackProbeSampling,
               let frameCallbackAccumulator {
                ChatFrameCallbackTimingLinkHost(
                    accumulator: frameCallbackAccumulator,
                    isSampling: true,
                    sceneIsActive: scenePhase == .active
                )
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// A DEBUG-only app-wide callback monitor. Its only visible affordance is
/// available under the explicit launch argument and is intentionally limited
/// to stopping and reading the aggregate report; callback ticks never update
/// this view's state.
private struct ChatPerformanceAppWideMonitorHost: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSampling = false
    @State private var hasStarted = false
    @State private var report: String?
    private let monitor = ChatPerformanceCadenceMonitor.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ChatFrameCallbackTimingLinkHost(
                recorder: monitor,
                isSampling: isSampling,
                sceneIsActive: scenePhase == .active
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if isSampling {
                Button("Stop app-wide cadence monitor") {
                    report = monitor.stopSampling().formattedReport
                    isSampling = false
                }
                .accessibilityIdentifier("chat-performance-app-wide-monitor-stop")
            } else if let report {
                Text(report)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("chat-performance-app-wide-monitor-summary")
            }
        }
        .onAppear {
            guard !hasStarted else { return }
            monitor.startSampling()
            monitor.setSceneActive(scenePhase == .active)
            hasStarted = true
            isSampling = true
        }
        .onChange(of: scenePhase) { _, phase in
            guard isSampling else { return }
            monitor.setSceneActive(phase == .active)
        }
    }
}

/// Retained separately from the probe UI state so start/stop and lifecycle
/// updates never regenerate the expensive synthetic transcripts.
@MainActor
private final class ChatPerformanceCycleLabFixtureStore: ObservableObject {
    let fixtures = ChatViewModel.makePerformanceLabFixtures(count: 2)
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
            ChatPerformanceCadenceMonitor.end(.entry)
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

#if SEMREH_INTERNAL_CHAT_PREVIEW && targetEnvironment(simulator) && !DEBUG
/// Signed Release smoke route, compiled only for the internal simulator build.
/// Settings and each newly opened chat use their production preference policy.
@MainActor
private struct InternalChatPreviewSmokeView: View {
    @State private var authManager = AuthManager()
    @State private var fixture = ChatViewModel.makeInternalChatPreviewSmokeFixture()

    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Chat settings") {
                    SettingsView(authManager: authManager, server: fixture.server, destination: .chat)
                }
                .accessibilityIdentifier("internal-preview-settings")
                NavigationLink("Open preview chat") {
                    ChatView(session: fixture.session, server: fixture.server,
                             onAPIError: { _ in }, loadsInitialMessages: false,
                             retainedViewModel: fixture.viewModel, disablesExternalLifecycle: true)
                }
                .accessibilityIdentifier("internal-preview-open-chat")
            }
            .navigationTitle("Internal renderer smoke")
        }
    }
}
#endif
