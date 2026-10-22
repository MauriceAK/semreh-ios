#if DEBUG
import CoreFoundation
import Foundation

/// Token-scoped controls for the visibly labeled, local UI fixture only.
@MainActor
final class FixtureControl {
    static let shared = FixtureControl()
    private weak var store: AppStore?
    private var commands: [String: String] = [:]

    func connect(_ store: AppStore) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in commands.keys {
            CFNotificationCenterRemoveObserver(center, nil, CFNotificationName(rawValue: name as CFString), nil)
        }
        commands.removeAll()
        self.store = nil
        let args = ProcessInfo.processInfo.arguments
        guard store.fixture, let index = args.firstIndex(of: "--fixture-control"), args.indices.contains(index + 1),
              let token = UUID(uuidString: args[index + 1])?.uuidString else { return }
        self.store = store
        store.fixtureHoldWork = false
        for action in ["hold-work", "offline", "online", "cancel-request", "synchronizing", "short-message", "tool-status", "host-request"] {
            let name = "org.hermescompanion.fixture." + token + "." + action
            commands[name] = action
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name = name?.rawValue as String? else { return }
                Task { @MainActor in FixtureControl.shared.receive(name) }
            }, name as CFString, nil, .deliverImmediately)
        }
    }
    private func receive(_ name: String) {
        guard let action = commands[name], let store, store.fixture else { return }
        switch action {
        case "hold-work": store.fixtureHoldWork = true
        case "host-request":
            store.requests = [.init(id: "host-1", generation: "generation-1", kind: "host_action", title: "Continue on your Hermes host", description: "This request requires a host interface. It remains pending in Hermes.", choices: [], allowsText: false)]
            store.runState = .waiting
        case "synchronizing": store.connection = "Synchronizing"
        case "short-message":
            try? store.transcript.replace(.init(messages: [.init(id: "fixture-short-hi", role: "user", text: "hi", provisional: false)], before: nil, hasMore: false))
            store.runState = .idle
            store.latestRevision = UUID()
        case "tool-status":
            guard let sessionID = store.selectedSession?.id,
                  let data = try? JSONSerialization.data(withJSONObject: ["type": "connection", "session_id": sessionID, "payload": ["state": "working", "message": "mcp__gbrain__recall"]]),
                  let event = try? CompanionAPI.decoder.decode(WireEvent.self, from: data) else { return }
            try? store.receive(event)
        case "offline":
            store.connection = "Reconnecting"
            store.connectionError = "The connection to Hermes was lost."
            store.requests = []
        case "online":
            store.connection = "Connected"
            store.connectionError = nil
            store.notice = nil
        case "cancel-request":
            store.requests = []
            store.runState = .idle
            store.notice = "Fixture request canceled on the host."
        default: return
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: (name + ".ack") as CFString), nil, nil, true)
    }
}
#endif
