import Foundation

enum Endpoint {
    case exportSession(sessionID: String, format: SessionExportFormat)
    case rawFile(sessionID: String, path: String)
    case media(sessionID: String, path: String)
    case personalities
    case setPersonality
    case skills
    case skillContent(name: String, file: String?)
    case toggleSkill
    case upload
    case transcribe

    var path: String {
        switch self {
        case .exportSession:
            return "/api/session/export"
        case .rawFile:
            return "/api/file/raw"
        case .media:
            return "/api/media"
        case .personalities:
            return "/api/personalities"
        case .setPersonality:
            return "/api/personality/set"
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
        case let .exportSession(sessionID, format):
            return [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "format", value: format.rawValue)
            ]
        case let .rawFile(sessionID, path):
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
        let url = baseURL.appending(path: path)
        guard !queryItems.isEmpty else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        return components?.url ?? url
    }
}
