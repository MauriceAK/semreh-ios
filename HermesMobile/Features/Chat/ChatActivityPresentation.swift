import Foundation

/// Small, semantic chrome states. Never derive a label from reasoning, tool
/// arguments/results, or Hermes's decorative spinner phrases.
enum ChatActivityPhase: Equatable {
    case working
    case searching
    case reading
    case replying
    case summarizing

    var label: String {
        switch self {
        case .working: return String(localized: "Working")
        case .searching: return String(localized: "Searching")
        case .reading: return String(localized: "Reading")
        case .replying: return String(localized: "Replying")
        case .summarizing: return String(localized: "Summarizing")
        }
    }

    static func tool(named name: String?) -> Self {
        // Exact built-in names from the pinned Hermes tool registry. Unknown
        // tools (including custom/MCP tools) do not reveal their raw names.
        switch name {
        case "web_search", "search_files": return .searching
        case "read_file", "web_extract", "browser_snapshot", "browser_get_images", "browser_vision": return .reading
        default: return .working
        }
    }

    static func semanticStatus(kind: String?) -> Self? {
        // tui_gateway.server._status_update explicitly marks compaction. Other
        // status text can be notices or arbitrary content, so leave it alone.
        kind == "compacting" ? .summarizing : nil
    }

    static func endsSemanticStatus(kind: String?, text: String?) -> Bool {
        // _status_update(sid, "ready") is the explicit compaction completion.
        kind == "status" && text == "ready"
    }
}

extension LocalMessageDelivery {
    /// Pending stays dim but quiet. Keep its truthful accessibility label and
    /// the same reserved footer as accepted/failed/uncertain attempts.
    var showsVisibleLabel: Bool {
        self == .notSent || self == .unconfirmed
    }
}
