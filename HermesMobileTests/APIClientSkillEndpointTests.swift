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

}
