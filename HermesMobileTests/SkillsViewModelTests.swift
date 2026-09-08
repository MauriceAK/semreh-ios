import XCTest
@testable import HermesMobile

final class SkillsViewModelTests: APIClientTestCase {
    @MainActor
    func testDirectListPreservesGroupingSearchAndDisabledSkills() async throws {
        let client = makeClient { request in
            return apiTestJSONResponse("""
            [{"name":"zeta","category":"coding","description":"Swift helper","enabled":false},
             {"name":"Alpha","category":"coding","description":"Other","enabled":true}]
            """, for: request)
        }
        let model = SkillsViewModel(client: client, profile: "work")
        await model.load()
        XCTAssertEqual(model.groupedSkills.first?.skills.map(\.name), ["Alpha", "zeta"])
        XCTAssertEqual(model.filteredGroupedSkills(searchText: "Swift").first?.skills.first?.name, "zeta")
        XCTAssertEqual(model.skills.first?.disabled, true)
    }

    @MainActor
    func testUnconfirmedToggleSurfacesErrorAndRestoresDisplayedState() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/skills" {
                return apiTestJSONResponse("[{\"name\":\"tool\",\"enabled\":true}]", for: request)
            }
            return apiTestJSONResponse("{\"ok\":true,\"name\":\"wrong\",\"enabled\":false}", for: request)
        }
        let model = SkillsViewModel(client: client, profile: "work")
        await model.load()
        await model.setSkill(try XCTUnwrap(model.skills.first), enabled: false)
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.skills.first?.disabled, false)
        XCTAssertTrue(model.togglingSkillNames.isEmpty)
    }

    @MainActor
    func testGroupedSkillsNormalizesBlankCategoriesAndSortsRows() {
        let groups = SkillsViewModel.groupedSkills(for: [
            SkillSummary(name: "zed", category: " coding ", description: nil, path: nil),
            SkillSummary(name: "Alpha", category: "coding", description: nil, path: nil),
            SkillSummary(name: "loose", category: "   ", description: nil, path: nil),
            SkillSummary(name: nil, category: nil, description: nil, path: nil)
        ])

        XCTAssertEqual(groups.map(\.category), ["coding", "Uncategorized"])
        XCTAssertEqual(groups.first?.skills.map(\.name), ["Alpha", "zed"])
        XCTAssertEqual(groups.last?.skills.map { $0.name ?? "Unnamed Skill" }, ["loose", "Unnamed Skill"])
    }

    @MainActor
    func testToggleSkillOptimisticallyUpdatesThenReloadsServerState() async throws {
        var paths: [String] = []
        var skillsLoadCount = 0
        let client = makeClient { request in
            paths.append(request.url?.path ?? "")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "work")
            switch request.url?.path {
            case "/api/skills":
                skillsLoadCount += 1
                let disabled = skillsLoadCount > 1
                return apiTestJSONResponse("""
                [{"name": "swift-refactor", "category": "coding", "enabled": \(!disabled)}]
                """, for: request)
            case "/api/skills/toggle":
                XCTAssertEqual(request.httpMethod, "PUT")
                let body = try apiTestJSONBody(from: request)
                XCTAssertEqual(body["name"] as? String, "swift-refactor")
                XCTAssertEqual(body["enabled"] as? Bool, false)
                return apiTestJSONResponse("""
                {"ok": true, "name": "swift-refactor", "enabled": false}
                """, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = SkillsViewModel(client: client, profile: "work")

        await model.load()
        await model.setSkill(try XCTUnwrap(model.skills.first), enabled: false)

        XCTAssertEqual(paths, ["/api/skills", "/api/skills/toggle", "/api/skills"])
        XCTAssertEqual(model.skills.first?.disabled, true)
        XCTAssertNil(model.lastError)
    }

    @MainActor
    func testToggleSkillRevertsOnFailure() async throws {
        var shouldFailToggle = false
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/skills":
                return apiTestJSONResponse("""
                [{"name": "swift-refactor", "category": "coding", "enabled": true}]
                """, for: request)
            case "/api/skills/toggle":
                shouldFailToggle = true
                throw URLError(.notConnectedToInternet)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = SkillsViewModel(client: client)

        await model.load()
        await model.setSkill(try XCTUnwrap(model.skills.first), enabled: false)

        XCTAssertTrue(shouldFailToggle)
        XCTAssertEqual(model.skills.first?.disabled, false)
        XCTAssertNotNil(model.lastError)
    }
}
