import Foundation
import Observation

/// Device-local, per-server session visibility preferences. These values only
/// filter Semreh's presentation and are never read from or written to Hermes.
@MainActor
@Observable
final class CliSessionsSyncModel {
    private(set) var showsCliSessions: Bool
    private(set) var showsClaudeCodeSessions: Bool

    private let server: URL
    private let defaults: UserDefaults

    init(server: URL, defaults: UserDefaults = .standard) {
        self.server = server
        self.defaults = defaults
        showsCliSessions = SessionRowDisplaySettings.showsCliSessions(for: server, in: defaults)
        showsClaudeCodeSessions = SessionRowDisplaySettings.showsClaudeCodeSessions(
            for: server, in: defaults
        )
    }

    func setShowsCliSessions(_ newValue: Bool) {
        guard newValue != showsCliSessions else { return }
        showsCliSessions = newValue
        defaults.set(newValue, forKey: SessionRowDisplaySettings.showCliSessionsKey(for: server))
    }

    /// The child preference stays saved independently when the parent CLI
    /// category is hidden, so re-enabling CLI rows restores the user's choice.
    func setShowsClaudeCodeSessions(_ newValue: Bool) {
        guard newValue != showsClaudeCodeSessions else { return }
        showsClaudeCodeSessions = newValue
        defaults.set(
            newValue,
            forKey: SessionRowDisplaySettings.showClaudeCodeSessionsKey(for: server)
        )
    }
}
