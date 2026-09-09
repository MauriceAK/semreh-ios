import Foundation

enum Endpoint {
    case officialCapabilities
    case officialSessions
    case officialSession(id: String)
    case officialSessionMessages(id: String, limit: Int?, offset: Int?, order: String?)
    case officialCreateSession
    case officialSessionChatStream(id: String)
    case sessions(includeArchived: Bool = false, archivedLimit: Int? = nil)
    case sessionsSearch(query: String, content: Bool, depth: Int)
    case session(id: String, includeMessages: Bool, messageLimit: Int?, messageBefore: Int?, expandRenderable: Bool = false)
    case newSession
    case renameSession
    case pinSession
    case archiveSession
    case branchSession
    case compressSession
    case undoSession
    case retrySession
    case truncateSession
    case updateSession
    case exportSession(sessionID: String, format: SessionExportFormat)
    case submitGoal
    case directoryList(sessionID: String, path: String?)
    case file(sessionID: String, path: String)
    case rawFile(sessionID: String, path: String)
    case media(sessionID: String, path: String)
    case personalities
    case setPersonality
    case memory
    case memoryWrite
    case skills
    case skillContent(name: String, file: String?)
    case toggleSkill
    case upload
    case transcribe

    var path: String {
        switch self {
        case .officialCapabilities:
            return "/v1/capabilities"
        case .officialSessions, .officialCreateSession:
            return "/api/sessions"
        case let .officialSession(id), let .officialSessionMessages(id, _, _, _), let .officialSessionChatStream(id):
            let encodedID = id.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? id
            switch self {
            case .officialSession:
                return "/api/sessions/\(encodedID)"
            case .officialSessionMessages:
                return "/api/sessions/\(encodedID)/messages"
            case .officialSessionChatStream:
                return "/api/sessions/\(encodedID)/chat/stream"
            default:
                return "/api/sessions/\(encodedID)"
            }
        case .sessions:
            return "/api/sessions"
        case .sessionsSearch:
            return "/api/sessions/search"
        case .session:
            return "/api/session"
        case .newSession:
            return "/api/session/new"
        case .renameSession:
            return "/api/session/rename"
        case .pinSession:
            return "/api/session/pin"
        case .archiveSession:
            return "/api/session/archive"
        case .branchSession:
            return "/api/session/branch"
        case .compressSession:
            return "/api/session/compress"
        case .undoSession:
            return "/api/session/undo"
        case .retrySession:
            return "/api/session/retry"
        case .truncateSession:
            return "/api/session/truncate"
        case .updateSession:
            return "/api/session/update"
        case .exportSession:
            return "/api/session/export"
        case .submitGoal:
            return "/api/goal"
        case .directoryList:
            return "/api/list"
        case .file:
            return "/api/file"
        case .rawFile:
            return "/api/file/raw"
        case .media:
            return "/api/media"
        case .personalities:
            return "/api/personalities"
        case .setPersonality:
            return "/api/personality/set"
        case .memory:
            return "/api/memory"
        case .memoryWrite:
            return "/api/memory/write"
        case .skills:
            return "/api/skills"
        case .skillContent:
            return "/api/skills/content"
        case .toggleSkill:
            return "/api/skills/toggle"
        case .upload:
            return "/api/upload"
        case .transcribe:
            return "/api/transcribe"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case let .officialSessionMessages(_, limit, offset, order):
            var items: [URLQueryItem] = []
            if let limit {
                items.append(URLQueryItem(name: "limit", value: "\(max(0, limit))"))
            }
            if let offset {
                items.append(URLQueryItem(name: "offset", value: "\(max(0, offset))"))
            }
            if let order {
                items.append(URLQueryItem(name: "order", value: order))
            }
            return items
        case .officialCapabilities, .officialSessions, .officialSession, .officialCreateSession, .officialSessionChatStream:
            return []
        case let .sessions(includeArchived, archivedLimit):
            // Opt-in (issue #17): the server's default response excludes archived
            // rows, so the main list request stays byte-identical when off.
            // `archived_limit` only means something alongside `include_archived=1`
            // (`_query_positive_int` in upstream routes.py), so it is only sent then.
            guard includeArchived else { return [] }

            var items = [URLQueryItem(name: "include_archived", value: "1")]
            if let archivedLimit {
                items.append(URLQueryItem(name: "archived_limit", value: "\(archivedLimit)"))
            }
            return items
        case let .sessionsSearch(query, content, depth):
            return [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "content", value: content ? "1" : "0"),
                URLQueryItem(name: "depth", value: "\(depth)")
            ]
        case let .session(id, includeMessages, messageLimit, messageBefore, expandRenderable):
            var items = [
                URLQueryItem(name: "session_id", value: id),
                URLQueryItem(name: "messages", value: includeMessages ? "1" : "0")
            ]

            if let messageLimit {
                items.append(URLQueryItem(name: "msg_limit", value: "\(messageLimit)"))
            }

            if let messageBefore {
                items.append(URLQueryItem(name: "msg_before", value: "\(messageBefore)"))
            }

            // Opt-in (upstream #3790): on cold load only, ask the server to widen the
            // window until it holds ~msg_limit *renderable* rows so tool-heavy sessions
            // don't open showing 1–2 bubbles. Omitted when false; older servers ignore it.
            if expandRenderable {
                items.append(URLQueryItem(name: "expand_renderable", value: "1"))
            }

            return items
        case let .exportSession(sessionID, format):
            return [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "format", value: format.rawValue)
            ]
        case let .directoryList(sessionID, path):
            var items = [URLQueryItem(name: "session_id", value: sessionID)]
            if let path {
                items.append(URLQueryItem(name: "path", value: path))
            }
            return items
        case let .file(sessionID, path),
            let .rawFile(sessionID, path):
            return [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "path", value: path)
            ]
        case let .media(sessionID, path):
            return [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "path", value: path)
            ]
        case let .skillContent(name, file):
            var items = [URLQueryItem(name: "name", value: name)]
            if let file {
                items.append(URLQueryItem(name: "file", value: file))
            }
            return items
        default:
            return []
        }
    }

    func url(relativeTo baseURL: URL) -> URL {
        let url: URL
        switch self {
        case let .officialSession(id):
            url = officialSessionURL(relativeTo: baseURL, id: id)
        case let .officialSessionMessages(id, _, _, _):
            url = officialSessionURL(relativeTo: baseURL, id: id, suffix: "/messages")
        case let .officialSessionChatStream(id):
            url = officialSessionURL(relativeTo: baseURL, id: id, suffix: "/chat/stream")
        default:
            url = baseURL.appending(path: path)
        }
        guard !queryItems.isEmpty else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        return components?.url ?? url
    }

    private func officialSessionURL(relativeTo baseURL: URL, id: String, suffix: String = "") -> URL {
        let root = baseURL.appending(path: "/api/sessions")
        guard var components = URLComponents(url: root, resolvingAgainstBaseURL: false),
              let encodedID = id.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed)
        else {
            return root
        }
        components.percentEncodedPath += "/\(encodedID)\(suffix)"
        return components.url ?? root
    }

    /// RFC 3986 unreserved characters minus `.`. Encoding dots as well keeps
    /// the special `.` and `..` path segments inert while preserving the exact
    /// Card identity after the server decodes the segment.
    private static let pathSegmentAllowed = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_~"))
}
