import Foundation

/// Marker messages the agent emits around context compaction. The server sends
/// them as plain role-based messages with no structured flag, so — like the web
/// UI (`_isContextCompactionMessage` / `_isPreservedCompressionTaskListMessage`
/// in `ui.js`) — we detect them by content prefix.
enum ChatMarkerMessageKind: Equatable {
    case contextCompaction
    case preservedTaskList
    /// Synthesized "Context compaction · Reference only" anchor card built from
    /// session-level `compression_anchor_*` metadata — never produced by
    /// `classify`, which only sees literal marker messages.
    case compressionReference
    /// Hermes injects background-process completions as role=user
    /// (`source=process_wakeup`). Render as a system card, never a user bubble.
    case processWakeup

    var title: String {
        switch self {
        case .contextCompaction, .compressionReference:
            return String(localized: "Context compaction")
        case .preservedTaskList:
            return String(localized: "Preserved task list")
        case .processWakeup:
            return String(localized: "Background process")
        }
    }
}

enum ChatMarkerMessageClassifier {
    private static let preservedTaskListPrefix = "[your active task list was preserved across context compression]"
    private static let processWakeupPrefix = "[important: background process"
    private static let contextCompactionPrefixes = ["[context compaction", "context compaction"]

    static func classify(_ message: ChatMessage) -> ChatMarkerMessageKind? {
        guard let role = message.role, role != "tool" else { return nil }

        let text = trimmedContent(of: message)

        if role == "user", hasCaseInsensitivePrefix(text, preservedTaskListPrefix) {
            return .preservedTaskList
        }

        if role == "user", hasMarkerPrefix(text, processWakeupPrefix) {
            return .processWakeup
        }

        if isContextCompactionText(text) {
            return .contextCompaction
        }

        return nil
    }

    /// Mirrors the web UI's `_isContextCompactionText`: true when the text is
    /// itself a literal compaction marker (used both for classification and to
    /// gate the synthesized reference card).
    static func isContextCompactionText(_ text: String?) -> Bool {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return contextCompactionPrefixes.contains { hasMarkerPrefix(trimmed, $0) }
    }

    /// The card body with the preserved-task-list marker line stripped, so the
    /// preview/expanded text starts at the actual task list (mirrors the web
    /// UI's `_preservedCompressionTaskListPreview`).
    static func cardBody(for kind: ChatMarkerMessageKind, content: String?) -> String {
        let text = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard kind == .preservedTaskList,
              let markerRange = text.range(
                of: preservedTaskListPrefix,
                options: [.caseInsensitive, .anchored]
              )
        else {
            return text
        }

        return String(text[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedContent(of message: ChatMessage) -> String {
        (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasCaseInsensitivePrefix(_ text: String, _ prefix: String) -> Bool {
        text.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }

    /// Marker stems must end at a token boundary. Without this guard, ordinary
    /// user text such as "context compactional..." or a bracketed note about
    /// "background processes" is removed from the conversation as a system
    /// card merely because it begins with the same characters as a marker.
    private static func hasMarkerPrefix(_ text: String, _ prefix: String) -> Bool {
        guard let range = text.range(of: prefix, options: [.caseInsensitive, .anchored]) else {
            return false
        }
        guard range.upperBound < text.endIndex else { return true }

        let boundary = text[range.upperBound]
        return boundary.isWhitespace || boundary == "]" || boundary == ":"
    }
}
