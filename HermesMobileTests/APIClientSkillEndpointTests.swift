import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientSkillEndpointTests: APIClientTestCase {
    func testDirectSkillsClassifiesStructuredAuthExpiry() async throws {
        let client = makeClient { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401,
                                                        httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            return (response, Data(#"{"error":"unauthenticated","detail":"Unauthorized"}"#.utf8))
        }
        do {
            _ = try await client.directSkills(profile: "work")
            XCTFail("Expected session expiry")
        } catch DirectHermesAuthError.sessionExpired { }
    }

    func testDirectSkillsUsesProfileAndStockEnabledArray() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/skills")
            XCTAssertEqual(request.httpMethod, "GET")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query, [URLQueryItem(name: "profile", value: "work & notes")])
            return apiTestJSONResponse("""
            [{"name":"on","enabled":true,"category":"coding","description":"Tools","usage":5},
             {"name":"off","enabled":false},{"name":"unknown"}]
            """, for: request)
        }
        let rows = try await client.directSkills(profile: "work & notes").skills
        XCTAssertEqual(rows?.count, 3)
        XCTAssertEqual(rows?[0].disabled, false)
        XCTAssertEqual(rows?[1].disabled, true)
        XCTAssertNil(rows?[2].disabled)
        XCTAssertEqual(rows?[0].description, "Tools")
    }

    func testDirectSkillsRejectsLegacyEnvelope() async throws {
        let client = makeClient { apiTestJSONResponse("{\"skills\":[]}", for: $0) }
        do {
            _ = try await client.directSkills(profile: "default")
            XCTFail("Legacy envelope must not decode as stock skills")
        } catch { }
    }

    func testDirectSkillsRejectsBlankProfileWithoutRequest() async throws {
        let client = makeClient { request in
            XCTFail("Blank profile must not reach the server")
            return apiTestJSONResponse("[]", for: request)
        }
        do {
            _ = try await client.directSkills(profile: "  ")
            XCTFail("Expected invalid profile")
        } catch DirectSkillsError.invalidProfile { }
    }

    func testDirectToggleUsesPutAndValidatesReceipt() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/skills/toggle")
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "profile", value: "work")])
            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(body["name"] as? String, "tool")
            XCTAssertEqual(body["enabled"] as? Bool, false)
            return apiTestJSONResponse("{\"ok\":true,\"name\":\"tool\",\"enabled\":false}", for: request)
        }
        let response = try await client.directToggleSkill(name: "tool", enabled: false, profile: "work")
        XCTAssertEqual(response.enabled, false)
    }

    func testDirectToggleRejectsMissingOrMismatchedReceipt() async throws {
        for body in ["{}", "{\"ok\":false,\"name\":\"tool\",\"enabled\":false}",
                     "{\"ok\":true,\"name\":\"other\",\"enabled\":false}",
                     "{\"ok\":true,\"name\":\"tool\",\"enabled\":true}"] {
            let client = makeClient { apiTestJSONResponse(body, for: $0) }
            do {
                _ = try await client.directToggleSkill(name: "tool", enabled: false, profile: "work")
                XCTFail("Expected unconfirmed mutation")
            } catch DirectSkillsError.invalidAcknowledgement { }
        }
    }

    func testDirectSkillContentEscapesNameAndUsesExplicitProfile() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/skills/content")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "profile", value: "work"),
                            URLQueryItem(name: "name", value: "a & b/#")])
            return apiTestJSONResponse("{\"name\":\"a & b/#\",\"content\":\"# Skill\",\"path\":\"/fixture/SKILL.md\"}", for: request)
        }
        let response = try await client.directSkillContent(name: "a & b/#", profile: "work")
        XCTAssertEqual(response.content, "# Skill")
        XCTAssertNil(response.linkedFiles)
    }

    func testSkillsBuildsExpectedPathAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/skills")
            XCTAssertEqual(request.httpMethod, "GET")

            return apiTestJSONResponse("""
            {
              "skills": [
                {"name": "swift-refactor", "category": "coding", "description": "Refactors Swift code", "path": "/skills/coding/swift-refactor", "disabled": true, "tags": ["swift", "refactor"], "related_skills": ["test-driven-development"]},
                {"name": "doc-search", "category": "research", "description": "Searches docs"}
              ]
            }
            """, for: request)
        }

        let response = try await client.skills()
        XCTAssertEqual(response.skills?.count, 2)
        XCTAssertEqual(response.skills?[0].name, "swift-refactor")
        XCTAssertEqual(response.skills?[0].category, "coding")
        XCTAssertEqual(response.skills?[0].description, "Refactors Swift code")
        XCTAssertEqual(response.skills?[0].disabled, true)
        XCTAssertEqual(response.skills?[0].tags, ["swift", "refactor"])
        XCTAssertEqual(response.skills?[0].relatedSkills, ["test-driven-development"])
        XCTAssertEqual(response.skills?[1].name, "doc-search")
        XCTAssertEqual(response.skills?[1].category, "research")
    }

    func testSkillsToleratesMissingFields() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/skills")
            return apiTestJSONResponse("""
            {"skills": [{"name": "minimal-skill"}]}
            """, for: request)
        }

        let response = try await client.skills()
        XCTAssertEqual(response.skills?.count, 1)
        XCTAssertEqual(response.skills?[0].name, "minimal-skill")
        XCTAssertNil(response.skills?[0].category)
        XCTAssertNil(response.skills?[0].description)
        XCTAssertNil(response.skills?[0].disabled)
        XCTAssertNil(response.skills?[0].tags)
        XCTAssertNil(response.skills?[0].relatedSkills)
    }

    func testToggleSkillPostsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/skills/toggle")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(body["name"] as? String, "swift-refactor")
            XCTAssertEqual(body["enabled"] as? Bool, false)

            return apiTestJSONResponse("""
            {"ok": true, "name": "swift-refactor", "enabled": false}
            """, for: request)
        }

        let response = try await client.toggleSkill(name: "swift-refactor", enabled: false)
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.name, "swift-refactor")
        XCTAssertEqual(response.enabled, false)
    }

    func testSkillContentBuildsExpectedQueryAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/skills/content")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["name"], "swift-refactor")
            XCTAssertNil(query["file"])
            XCTAssertEqual(request.httpMethod, "GET")

            return apiTestJSONResponse("""
            {"name": "swift-refactor", "content": "# Swift Refactor\\n\\nRefactors Swift code.", "linked_files": {"README.md": "Read me", "config.json": "Config"}}
            """, for: request)
        }

        let response = try await client.skillContent(name: "swift-refactor")
        XCTAssertEqual(response.name, "swift-refactor")
        XCTAssertEqual(response.content, "# Swift Refactor\n\nRefactors Swift code.")
        XCTAssertEqual(response.linkedFiles, ["README.md", "config.json"])
    }

    func testSkillContentDecodesGroupedLinkedFiles() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/skills/content")

            return apiTestJSONResponse("""
            {
              "name": "google-workspace",
              "content": "# Google Workspace",
              "linked_files": {
                "references": ["references/auth.md"],
                "scripts": ["scripts/setup.py", "scripts/google_api.py"],
                "assets": []
              }
            }
            """, for: request)
        }

        let response = try await client.skillContent(name: "google-workspace")

        XCTAssertEqual(response.linkedFiles, [
            "references/auth.md",
            "scripts/google_api.py",
            "scripts/setup.py"
        ])
    }

    func testSkillLinkedFileBuildsExpectedQueryAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/skills/content")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["name"], "swift-refactor")
            XCTAssertEqual(query["file"], "README.md")
            XCTAssertEqual(request.httpMethod, "GET")

            return apiTestJSONResponse("""
            {"content": "# README\\n\\nDetails here.", "path": "README.md"}
            """, for: request)
        }

        let response = try await client.skillContent(name: "swift-refactor", file: "README.md")
        XCTAssertEqual(response.content, "# README\n\nDetails here.")
    }
}
