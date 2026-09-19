import Foundation

/// Presentation-only payloads shared by direct gateway rendering and any
/// transport-specific adapters. They deliberately contain no SSE behavior.
struct ToolStreamEvent: Decodable, Equatable {
    let eventType: String?
    let name: String?
    let preview: String?
    let args: [String: JSONValue]?
    let duration: Double?
    let isError: Bool?
    let stableID: String?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case name
        case preview
        case args
        case duration
        case isError = "is_error"
        case tid
        case id
        case toolCallID = "tool_call_id"
        case toolUseID = "tool_use_id"
        case callID = "call_id"
    }

    init(
        eventType: String?,
        name: String?,
        preview: String?,
        args: [String: JSONValue]?,
        duration: Double?,
        isError: Bool?,
        stableID: String? = nil
    ) {
        self.eventType = eventType
        self.name = name
        self.preview = preview
        self.args = args
        self.duration = duration
        self.isError = isError
        self.stableID = stableID?.nonEmptyToolStreamID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = container.decodeLossyStringIfPresent(forKey: .eventType)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        preview = container.decodeLossyStringIfPresent(forKey: .preview)
        args = try? container.decodeIfPresent([String: JSONValue].self, forKey: .args)
        duration = container.decodeLossyDoubleIfPresent(forKey: .duration)
        isError = container.decodeLossyBoolIfPresent(forKey: .isError)
        stableID = [
            container.decodeLossyStringIfPresent(forKey: .tid),
            container.decodeLossyStringIfPresent(forKey: .id),
            container.decodeLossyStringIfPresent(forKey: .toolCallID),
            container.decodeLossyStringIfPresent(forKey: .toolUseID),
            container.decodeLossyStringIfPresent(forKey: .callID)
        ].compactMap { $0?.nonEmptyToolStreamID }.first
    }
}

struct InterimAssistantStreamEvent: Decodable, Equatable {
    let text: String?
    let alreadyStreamed: Bool?

    enum CodingKeys: String, CodingKey {
        case text
        case alreadyStreamed = "already_streamed"
    }

    init(text: String? = nil, alreadyStreamed: Bool? = nil) {
        self.text = text
        self.alreadyStreamed = alreadyStreamed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = container.decodeLossyStringIfPresent(forKey: .text)
        alreadyStreamed = container.decodeLossyBoolIfPresent(forKey: .alreadyStreamed)
    }
}

private extension String {
    var nonEmptyToolStreamID: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
