import XCTest
@testable import HermesMobile

/// Contract coverage for presentation payloads shared by direct gateway rendering.
final class ChatPresentationEventsTests: XCTestCase {
    func testToolPayloadDecodesLossyFieldsAndPreferredStableIdentity() throws {
        let payload = try JSONDecoder().decode(
            ToolStreamEvent.self,
            from: Data(#"{"event_type":7,"name":42,"preview":true,"duration":"1.25","is_error":"false","tid":"  ","tool_call_id":"call-7","args":{"path":"README.md"}}"#.utf8)
        )
        XCTAssertEqual(payload.eventType, "7")
        XCTAssertEqual(payload.name, "42")
        XCTAssertEqual(payload.preview, "true")
        XCTAssertEqual(payload.duration, 1.25)
        XCTAssertEqual(payload.isError, false)
        XCTAssertEqual(payload.stableID, "call-7")
        XCTAssertEqual(payload.args, ["path": .string("README.md")])
    }

    func testToolStableIdentityUsesExistingAliasPrecedenceAndTrimsValues() throws {
        let aliases: [(String, String)] = [
            ("tid", "tid-1"), ("id", "id-1"), ("tool_call_id", "call-1"),
            ("tool_use_id", "use-1"), ("call_id", "legacy-1")
        ]
        for (key, expected) in aliases {
            let data = try JSONSerialization.data(withJSONObject: [key: "  \(expected)  "])
            let payload = try JSONDecoder().decode(ToolStreamEvent.self, from: data)
            XCTAssertEqual(payload.stableID, expected, "alias \(key)")
        }
    }

    func testInterimPayloadPreservesTextAndLossyAlreadyStreamedFlag() throws {
        let payload = try JSONDecoder().decode(
            InterimAssistantStreamEvent.self,
            from: Data(#"{"text":123,"already_streamed":"true"}"#.utf8)
        )
        XCTAssertEqual(payload.text, "123")
        XCTAssertEqual(payload.alreadyStreamed, true)
        XCTAssertEqual(
            InterimAssistantStreamEvent(text: "Draft", alreadyStreamed: false),
            InterimAssistantStreamEvent(text: "Draft", alreadyStreamed: false)
        )
    }

    func testToolMemberwiseInitializerRejectsBlankStableIdentity() {
        let payload = ToolStreamEvent(
            eventType: "tool_start", name: "read_file", preview: nil,
            args: nil, duration: nil, isError: nil, stableID: "  "
        )
        XCTAssertNil(payload.stableID)
    }
}
