import XCTest
@testable import HermesMobile

@MainActor
final class GatewayConversationEventMappingTests: XCTestCase {
    func testTextInterimThinkingAndReasoningPreserveExactWhitespace() {
        let delta = GatewayConversationController.presentationEvent(for: event(
            type: "message.delta",
            payload: ["text": .string("  leading\n\ttrailing  ")]
        ))
        XCTAssertEqual(delta, .textDelta("  leading\n\ttrailing  "))

        let interim = GatewayConversationController.presentationEvent(for: event(
            type: "message.interim",
            payload: ["text": .string("\n  interim  "), "already_streamed": .bool(true)]
        ))
        XCTAssertEqual(interim, .interim(text: "\n  interim  ", alreadyStreamed: true))

        XCTAssertEqual(
            GatewayConversationController.presentationEvent(for: event(
                type: "thinking.delta", payload: ["text": .string(" think\n")]
            )),
            .thinkingDelta(" think\n")
        )
        XCTAssertEqual(
            GatewayConversationController.presentationEvent(for: event(
                type: "reasoning.delta", payload: ["text": .string(" reason\t")]
            )),
            .reasoningDelta(" reason\t")
        )
    }

    func testToolLifecycleRetainsStableIDAndKnownCompletionFields() {
        let payload: [String: JSONValue] = [
            "tool_id": .string("call-7"),
            "name": .string("terminal"),
            "args": .object(["command": .string("printf 'x  '")]),
            "result": .object(["output": .string("x  "), "exit_code": .number(0)]),
            "summary": .string("finished"),
            "duration_s": .number(1.25),
            "inline_diff": .string("@@ -1 +1 @@")
        ]
        let expected = GatewayConversationController.PresentationTool(
            toolID: "call-7",
            name: "terminal",
            args: ["command": .string("printf 'x  '")],
            result: .object(["output": .string("x  "), "exit_code": .number(0)]),
            summary: "finished",
            duration: 1.25,
            error: nil,
            diff: "@@ -1 +1 @@"
        )

        for type in ["tool.start", "tool.progress", "tool.complete"] {
            let mapped = GatewayConversationController.presentationEvent(for: event(type: type, payload: payload))
            switch (type, mapped) {
            case ("tool.start", .toolStart(let tool)),
                 ("tool.progress", .toolProgress(let tool)),
                 ("tool.complete", .toolComplete(let tool)):
                XCTAssertEqual(tool, expected)
            default:
                XCTFail("unexpected mapping for \(type): \(mapped)")
            }
        }
    }

    func testTerminalMapsTextStatusReasoningErrorAndTolerantUsage() {
        let mapped = GatewayConversationController.presentationEvent(for: event(
            type: "message.complete",
            payload: [
                "text": .string("final  \n"),
                "status": .string("error"),
                "reasoning": .string("kept separately"),
                "error": .string("provider failed"),
                "usage": .object([
                    "input": .number(123),
                    "output": .number(9),
                    "context_used": .number(123),
                    "context_max": .number(16_000),
                    "avg_tps": .number(4),
                    "total": .number(900_000),
                    "future_field": .object(["ignored": .bool(true)])
                ])
            ]
        ))
        guard case .terminal(let terminal) = mapped else {
            return XCTFail("expected terminal mapping, got \(mapped)")
        }
        XCTAssertEqual(terminal.text, "final  \n")
        XCTAssertEqual(terminal.status, "error")
        XCTAssertEqual(terminal.reasoning, "kept separately")
        XCTAssertEqual(terminal.error, "provider failed")
        XCTAssertEqual(terminal.usage, ContextWindowSnapshot(
            contextLength: 16_000,
            thresholdTokens: nil,
            lastPromptTokens: 123,
            inputTokens: 123,
            outputTokens: 9,
            estimatedCost: nil,
            tokensPerSecond: 4
        ))
    }

    func testUsageEventAndMalformedOrUnknownFramesRemainNonTerminal() {
        let usage = GatewayConversationController.presentationEvent(for: event(
            type: "session.usage",
            payload: ["usage": .object([
                "input": .number(4),
                "output": .number(2),
                "context_used": .number(4),
                "context_max": .number(100),
                "avg_tps": .number(3)
            ])]
        ))
        guard case .usage(let snapshot) = usage else {
            return XCTFail("expected usage mapping, got \(usage)")
        }
        XCTAssertEqual(snapshot.contextLength, 100)
        XCTAssertEqual(snapshot.inputTokens, 4)
        XCTAssertEqual(snapshot.outputTokens, 2)
        XCTAssertEqual(snapshot.lastPromptTokens, 4)
        XCTAssertEqual(snapshot.tokensPerSecond, 3)

        let malformedText = event(type: "message.delta", payload: ["text": .null])
        XCTAssertEqual(
            GatewayConversationController.presentationEvent(for: malformedText),
            .control(malformedText)
        )

        let malformedTool = event(type: "tool.complete", payload: [
            "tool_id": .null,
            "args": .string("not an object"),
            "duration_s": .string("not a number"),
            "result": .null,
            "error": .bool(true)
        ])
        guard case .toolComplete(let tool) = GatewayConversationController.presentationEvent(for: malformedTool) else {
            return XCTFail("malformed nullable tool payload should remain a tool event")
        }
        XCTAssertNil(tool.toolID)
        XCTAssertNil(tool.args)
        XCTAssertNil(tool.duration)
        XCTAssertNil(tool.error)
        XCTAssertEqual(tool.result, .null)

        let unknown = event(type: "future.new.event", payload: ["text": .string("not terminal")])
        XCTAssertEqual(GatewayConversationController.presentationEvent(for: unknown), .unknown(unknown))

        let knownControl = event(type: "status.update", payload: ["kind": .string("working")])
        XCTAssertEqual(GatewayConversationController.presentationEvent(for: knownControl), .control(knownControl))
    }

    private func event(type: String, payload: [String: JSONValue]? = nil) -> HermesGatewayEvent {
        HermesGatewayEvent(
            method: "event",
            type: type,
            sessionID: "runtime",
            sequence: 7,
            payload: payload.map(JSONValue.object),
            params: nil
        )
    }
}
