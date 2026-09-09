import Foundation

extension APIClient {
    func directSkills(profile: String) async throws -> SkillsResponse {
        let data = try await sendDirectData(
            path: directSkillsPath("/api/skills", profile: profile), method: "GET",
            classifyStructuredAuthExpiry: true
        )
        let rows = try decode([DirectSkillSummary].self, from: data)
        return SkillsResponse(skills: rows.map { row in
            SkillSummary(name: row.name, category: row.category, description: row.description,
                         path: nil, disabled: row.enabled.map { !$0 })
        })
    }

    func directToggleSkill(name: String, enabled: Bool, profile: String) async throws -> ToggleSkillResponse {
        let data = try await sendDirectData(
            path: directSkillsPath("/api/skills/toggle", profile: profile), method: "PUT",
            encodedBody: JSONEncoder().encode(ToggleSkillRequest(name: name, enabled: enabled)),
            classifyStructuredAuthExpiry: true
        )
        let response = try decode(ToggleSkillResponse.self, from: data)
        guard response.ok == true, response.name == name, response.enabled == enabled else {
            throw DirectSkillsError.invalidAcknowledgement
        }
        return response
    }

    func directSkillContent(name: String, profile: String) async throws -> SkillDetailResponse {
        let data = try await sendDirectData(
            path: directSkillsPath("/api/skills/content", profile: profile,
                                   query: [URLQueryItem(name: "name", value: name)]),
            method: "GET", classifyStructuredAuthExpiry: true
        )
        return try decode(SkillDetailResponse.self, from: data)
    }

    private func directSkillsPath(_ path: String, profile: String, query: [URLQueryItem] = []) throws -> String {
        guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DirectSkillsError.invalidProfile
        }
        var components = URLComponents()
        components.path = path
        components.queryItems = [URLQueryItem(name: "profile", value: profile)] + query
        guard let result = components.string else { throw APIError.invalidServerURL }
        return result
    }

}

// Stock skills.py returns a bare array and uses enabled, not WebUI's disabled.
private struct DirectSkillSummary: Decodable {
    let name: String?
    let category: String?
    let description: String?
    let enabled: Bool?
}

enum DirectSkillsError: LocalizedError {
    case invalidProfile
    case invalidAcknowledgement

    var errorDescription: String? {
        switch self {
        case .invalidProfile: String(localized: "Select a Hermes profile to manage skills.")
        case .invalidAcknowledgement: String(localized: "Hermes did not confirm the skill change. Refresh before trying again.")
        }
    }
}
