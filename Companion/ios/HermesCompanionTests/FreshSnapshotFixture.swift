import Foundation
import XCTest
@testable import HermesCompanion

@MainActor
extension AppStore {
    func receiveFreshSnapshotForTesting(state: RunState = .idle, messages: [ChatMessage] = [], before: String? = nil, hasMore: Bool = false) throws {
        let session = try XCTUnwrap(selectedSession)
        let snapshot = SessionSnapshot(session: session, page: .init(messages: messages, before: before, hasMore: hasMore),
            state: state, requests: [], controls: .init(model: "test", provider: "test", pendingModel: nil,
                reasoning: "medium", reasoningLevels: [], models: [], commands: []))
        let payload = try JSONSerialization.jsonObject(with: CompanionAPI.encoder.encode(snapshot))
        let data = try JSONSerialization.data(withJSONObject: ["type": "snapshot", "session_id": session.id, "payload": payload])
        try receive(CompanionAPI.decoder.decode(WireEvent.self, from: data))
    }
}
