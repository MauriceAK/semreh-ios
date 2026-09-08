import Foundation

extension GatewayConversationController {
    /// Values needed by the retained chat renderer. This is deliberately a
    /// pure projection of one gateway frame; it does not interpret rendered
    /// terminal/ANSI text as Markdown and it does not synthesize missing IDs.
    struct PresentationTool: Equatable {
        let toolID: String?
        let name: String?
        let args: [String: JSONValue]?
        let result: JSONValue?
        let summary: String?
        let duration: Double?
        let error: String?
        let diff: String?
    }

    struct PresentationTerminal: Equatable {
        let text: String?
        let status: String?
        let reasoning: String?
        let error: String?
        let usage: ContextWindowSnapshot?
    }

    enum PresentationEvent: Equatable {
        case textDelta(String)
        case interim(text: String, alreadyStreamed: Bool)
        case thinkingDelta(String)
        case reasoningDelta(String)
        case toolStart(PresentationTool)
        case toolProgress(PresentationTool)
        case toolComplete(PresentationTool)
        case usage(ContextWindowSnapshot)
        case terminal(PresentationTerminal)
        /// A recognized gateway/control frame that is intentionally not a
        /// renderer terminal event (for example `message.start` or `status.update`).
        case control(HermesGatewayEvent)
        /// An event vocabulary not known by this client version.
        case unknown(HermesGatewayEvent)
    }

    static func presentationEvent(for event: HermesGatewayEvent) -> PresentationEvent {
        guard knownPresentationEventTypes.contains(event.type) else {
            return .unknown(event)
        }

        switch event.type {
        case "message.delta":
            guard let text = event.payload?.gatewayFields["text"]?.presentationString else {
                return .control(event)
            }
            return .textDelta(text)

        case "message.interim":
            guard let text = event.payload?.gatewayFields["text"]?.presentationString else {
                return .control(event)
            }
            let alreadyStreamed = event.payload?.gatewayFields["already_streamed"]?.presentationBool ?? false
            return .interim(text: text, alreadyStreamed: alreadyStreamed)

        case "thinking.delta":
            guard let text = event.payload?.gatewayFields["text"]?.presentationString else {
                return .control(event)
            }
            return .thinkingDelta(text)

        case "reasoning.delta":
            guard let text = event.payload?.gatewayFields["text"]?.presentationString else {
                return .control(event)
            }
            return .reasoningDelta(text)

        case "session.usage":
            guard let usage = decodeUsage(from: event.payload?.gatewayFields["usage"]) else {
                return .control(event)
            }
            return .usage(usage)

        case "tool.start":
            return .toolStart(tool(from: event.payload))

        case "tool.progress":
            return .toolProgress(tool(from: event.payload))

        case "tool.complete":
            return .toolComplete(tool(from: event.payload))

        case "message.complete":
            return .terminal(terminal(from: event.payload))

        default:
            return .control(event)
        }
    }

    private static let knownPresentationEventTypes: Set<String> = [
        "gateway.ready", "session.info", "session.usage",
        "message.start", "message.delta", "message.interim", "message.complete",
        "thinking.delta", "reasoning.delta", "reasoning.available", "status.update",
        "tool.start", "tool.progress", "tool.complete", "tool.generating",
        "todo.updated", "clarify.request", "approval.request", "sudo.request",
        "secret.request", "background.complete", "error", "skin.changed",
        "sessions.changed", "cron.changed", "btw.complete"
    ]

    private static func tool(from payload: JSONValue?) -> PresentationTool {
        let fields = payload?.gatewayFields ?? [:]
        return PresentationTool(
            toolID: fields["tool_id"]?.presentationString,
            name: fields["name"]?.presentationString,
            args: fields["args"]?.presentationObject,
            result: fields["result"],
            summary: fields["summary"]?.presentationString,
            duration: fields["duration_s"]?.presentationDouble,
            error: fields["error"]?.presentationString,
            diff: fields["inline_diff"]?.presentationString
        )
    }

    private static func terminal(from payload: JSONValue?) -> PresentationTerminal {
        let fields = payload?.gatewayFields ?? [:]
        return PresentationTerminal(
            text: fields["text"]?.presentationString,
            status: fields["status"]?.presentationString,
            reasoning: fields["reasoning"]?.presentationString,
            error: fields["error"]?.presentationString,
            usage: decodeUsage(from: fields["usage"])
        )
    }

    private static func decodeUsage(from value: JSONValue?) -> ContextWindowSnapshot? {
        guard let fields = value?.presentationObject else { return nil }
        let knownKeys = ["input", "output", "context_used", "context_max", "avg_tps"]
        guard fields.keys.contains(where: knownKeys.contains) else { return nil }

        // The gateway usage contract names cumulative input/output separately
        // from current-window occupancy. Never use `total` for occupancy: it is
        // a lifetime counter and can be much larger than the context window.
        return ContextWindowSnapshot(
            contextLength: integer(in: fields, keys: ["context_max"]),
            thresholdTokens: nil,
            lastPromptTokens: integer(in: fields, keys: ["context_used"]),
            inputTokens: integer(in: fields, keys: ["input"]),
            outputTokens: integer(in: fields, keys: ["output"]),
            estimatedCost: nil,
            tokensPerSecond: double(in: fields, keys: ["avg_tps"])
        )
    }

    private static func integer(in fields: [String: JSONValue], keys: [String]) -> Int? {
        for key in keys {
            guard let value = fields[key] else { continue }
            switch value {
            case .number(let number):
                if let integer = Int(exactly: number) { return integer }
            case .string(let text):
                if let integer = Int(text) { return integer }
                if let number = Double(text), let integer = Int(exactly: number) { return integer }
            default:
                continue
            }
        }
        return nil
    }

    private static func double(in fields: [String: JSONValue], keys: [String]) -> Double? {
        for key in keys {
            guard let value = fields[key] else { continue }
            switch value {
            case .number(let number) where number.isFinite:
                return number
            case .string(let text):
                if let number = Double(text), number.isFinite { return number }
            default:
                continue
            }
        }
        return nil
    }
}

private extension JSONValue {
    var presentationString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var presentationBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var presentationDouble: Double? {
        guard case .number(let value) = self, value.isFinite else { return nil }
        return value
    }

    var presentationObject: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
