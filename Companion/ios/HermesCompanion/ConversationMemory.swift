import Foundation

@MainActor
final class ConversationMemory {
    private struct State: Codable {
        var selectedID: String?
        var drafts: [String: String] = [:]
        var recent: [String] = []
    }
    private let defaults: UserDefaults
    private let key: String
    private var state: State
    var selectedID: String? { state.selectedID }
    init(hostID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "conversation-memory-v1:" + hostID
        state = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }
    func draft(for id: String?) -> String { state.drafts[id ?? "new-conversation"] ?? "" }
    func select(_ id: String?) { state.selectedID = id; persist() }
    @discardableResult
    func saveDraft(_ text: String, for id: String?) -> Bool {
        let id = id ?? "new-conversation"
        state.recent.removeAll { $0 == id }
        state.drafts.removeValue(forKey: id)
        guard text.utf8.count <= 64 * 1024 else { persist(); return false }
        if !text.isEmpty { state.drafts[id] = text; state.recent.append(id) }
        while state.recent.count > 20 || state.drafts.values.reduce(0, { $0 + $1.utf8.count }) > 512 * 1024 {
            state.drafts.removeValue(forKey: state.recent.removeFirst())
        }
        persist()
        return true
    }
    private func persist() {
        let span = ChatPerformance.shared.begin(.draftPersistence, count: state.drafts.values.reduce(0) { $0 + $1.utf8.count })
        defer { ChatPerformance.shared.end(span) }
        defaults.set(try? JSONEncoder().encode(state), forKey: key)
    }
}
