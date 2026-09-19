import Foundation

enum Endpoint {
    case media(sessionID: String, path: String)

    var path: String {
        switch self {
        case .media:
            return "/api/media"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case let .media(sessionID, path):
            return [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "path", value: path)
            ]
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
