import Foundation

/// Visual identity only: never used for routing or authorization.
struct BirdAvatarIdentity: Equatable {
    let serverID: String
    let profileID: String

    init?(server: URL?, profile: String?) {
        guard let server,
              let profile,
              !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        // Use the caller's actual source URL, never the globally active server.
        serverID = server.absoluteString
        profileID = profile
    }

    var presetIndex: Int {
        // Fixed FNV-1a, unlike Swift Hasher which changes between processes.
        // Length prefix makes component boundaries unambiguous.
        let key = "\(serverID.utf8.count):\(serverID)\(profileID.utf8.count):\(profileID)"
        let hash = key.utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        return Int(hash % 6)
    }
}
