import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientMemoryEndpointTests: APIClientTestCase {
    func testManagedMultipartPreservesUTF8NewlinesAndEmptyDocumentBytes() async throws {
        let fixture = DirectMemoryTestServer()
        let client = makeClient { try fixture.respond($0) }
        let scope = try await client.directMemoryScope(profile: "work")
        var baseline = try await client.directMemoryDocument(section: .memory, scope: scope)
        for content in ["first\r\n💡 café\n\r\nlast\n", ""] {
            baseline = try await client.directSaveMemory(content, baseline: baseline, scope: scope)
            XCTAssertEqual(baseline.content, content)
            XCTAssertEqual(fixture.notes, content)
        }
        XCTAssertEqual(fixture.writes, ["/api/files/upload-stream", "/api/files/upload-stream"])
        XCTAssertFalse(fixture.paths.contains("/api/files/upload"))
    }

    func testDirectSoulPreservesStructuredExpiryVersusGenericUnauthorized() async throws {
        for structured in [false, true] {
            let fixture = DirectMemoryTestServer()
            let client = makeClient { request in
                if request.url?.path == "/api/profiles/work/soul" {
                    let body = structured ? #"{"error":"session_expired","detail":"Unauthorized","reason":"invalid_or_expired_session"}"# : #"{"detail":"Unauthorized"}"#
                    return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
                }
                return try fixture.respond(request)
            }
            let scope = try await client.directMemoryScope(profile: "work")
            do { _ = try await client.directMemoryDocument(section: .soul, scope: scope); XCTFail("Unauthorized read") }
            catch DirectHermesAuthError.sessionExpired { XCTAssertTrue(structured) }
            catch let error as DirectHermesRequestError {
                XCTAssertFalse(structured)
                XCTAssertEqual(error, .http(statusCode: 401, reason: .unauthorized))
            }
        }
    }

    func testDirectMemoryFlagsMatchStockBoolishConfigurationWithoutMutation() async throws {
        let fixture = DirectMemoryTestServer()
        let client = makeClient { request in
            if request.url?.path == "/api/config" {
                return apiTestJSONResponse(#"{"memory":{"memory_enabled":"false","user_profile_enabled":"yes","provider":"honcho"}}"#, for: request)
            }
            return try fixture.respond(request)
        }
        let scope = try await client.directMemoryScope(profile: "work")
        XCTAssertFalse(scope.memoryEnabled)
        XCTAssertTrue(scope.userEnabled)
        XCTAssertEqual(scope.externalProvider, "honcho")
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testDirectBuiltinMemoryUsesAdvertisedProfilePathAndExactUploadContract() async throws {
        let fixture = DirectMemoryTestServer()
        let client = makeClient { try fixture.respond($0) }
        let scope = try await client.directMemoryScope(profile: "work")
        let baseline = try await client.directMemoryDocument(section: .user, scope: scope)
        let saved = try await client.directSaveMemory("new user", baseline: baseline, scope: scope)
        XCTAssertEqual(scope.home, "/fixture/profile work")
        XCTAssertEqual(baseline.path, "/fixture/profile work/memories/USER.md")
        XCTAssertEqual(saved.content, "new user")
        XCTAssertEqual(fixture.lastOverwrite, true)
        XCTAssertEqual(fixture.writes, ["/api/files/upload-stream"])
        XCTAssertFalse(fixture.paths.contains("/api/memory"))
        XCTAssertFalse(fixture.paths.contains { $0.hasPrefix("/api/fs") })
    }

    func testDirectMemoryRefusesChangedProfileHomeBeforeWriting() async throws {
        let fixture = DirectMemoryTestServer()
        let client = makeClient { try fixture.respond($0) }
        let scope = try await client.directMemoryScope(profile: "work")
        let baseline = try await client.directMemoryDocument(section: .memory, scope: scope)
        fixture.home = "/different-home"
        do { _ = try await client.directSaveMemory("new", baseline: baseline, scope: scope); XCTFail("Moved scope must conflict") }
        catch DirectMemoryError.conflict { }
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testDirectMemoryRejectsUnknownProfileAndInvalidTextWithoutWrites() async throws {
        let fixture = DirectMemoryTestServer()
        let client = makeClient { try fixture.respond($0) }
        do { _ = try await client.directMemoryScope(profile: "missing"); XCTFail("No default profile fallback") }
        catch DirectMemoryError.invalidScope { }
        let scope = try await client.directMemoryScope(profile: "work")
        let baseline = try await client.directMemoryDocument(section: .memory, scope: scope)
        for content in ["bad\0text", String(repeating: "x", count: 512 * 1024 + 1)] {
            do { _ = try await client.directSaveMemory(content, baseline: baseline, scope: scope); XCTFail("Invalid document") }
            catch DirectMemoryError.invalidDocument { }
        }
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testDirectMemoryDoesNotFollowDifferentReturnedFilePath() async throws {
        let fixture = DirectMemoryTestServer()
        let client = makeClient { request in
            if request.url?.path == "/api/files/read" {
                return apiTestJSONResponse(#"{"path":"/another-profile/memories/MEMORY.md","data_url":"data:text/markdown;base64,bm90ZXM="}"#, for: request)
            }
            return try fixture.respond(request)
        }
        let scope = try await client.directMemoryScope(profile: "work")
        do { _ = try await client.directMemoryDocument(section: .memory, scope: scope); XCTFail("Returned scope must match") }
        catch DirectMemoryError.invalidDocument { }
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testMemoryProjectionDecodesKnownFields() async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(MemoryResponse.self, from: Data("""
            {
              "memory": "# Notes\\n\\n- Prefer SwiftUI",
              "user": "# Profile\\n\\n- Name: Developer",
              "soul": "# Agent Soul\\n\\n- Be concise",
              "memory_path": "/Users/test/.hermes/memories/MEMORY.md",
              "user_path": "/Users/test/.hermes/memories/USER.md",
              "soul_path": "/Users/test/.hermes/SOUL.md",
              "memory_mtime": 1770000000,
              "user_mtime": 1770000100,
              "soul_mtime": "1770000200",
              "project_context": "# Project\\n\\n- Ship it",
              "project_context_name": "AGENTS.md",
              "project_context_path": "/Users/test/workspace/AGENTS.md",
              "project_context_workspace": "/Users/test/workspace",
              "project_context_mtime": 1770000300,
              "project_context_shadowed": [
                {
                  "name": "PROJECT.md",
                  "path": "/Users/test/PROJECT.md",
                  "shadowed_by": "AGENTS.md"
                }
              ],
              "external_notes_enabled": true
            }
            """.utf8))

        XCTAssertEqual(response.memory, "# Notes\n\n- Prefer SwiftUI")
        XCTAssertEqual(response.user, "# Profile\n\n- Name: Developer")
        XCTAssertEqual(response.soul, "# Agent Soul\n\n- Be concise")
        XCTAssertEqual(response.memoryPath, "/Users/test/.hermes/memories/MEMORY.md")
        XCTAssertEqual(response.userPath, "/Users/test/.hermes/memories/USER.md")
        XCTAssertEqual(response.soulPath, "/Users/test/.hermes/SOUL.md")
        XCTAssertEqual(response.memoryMtime, 1_770_000_000)
        XCTAssertEqual(response.userMtime, 1_770_000_100)
        XCTAssertEqual(response.soulMtime, 1_770_000_200)
        XCTAssertEqual(response.projectContext, "# Project\n\n- Ship it")
        XCTAssertEqual(response.projectContextName, "AGENTS.md")
        XCTAssertEqual(response.projectContextPath, "/Users/test/workspace/AGENTS.md")
        XCTAssertEqual(response.projectContextWorkspace, "/Users/test/workspace")
        XCTAssertEqual(response.projectContextMtime, 1_770_000_300)
        XCTAssertEqual(response.projectContextShadowed, true)
        XCTAssertEqual(response.externalNotesEnabled, true)
    }

    func testMemoryToleratesMissingFields() async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(MemoryResponse.self, from: Data("""
            {
              "memory": "",
              "user": null
            }
            """.utf8))

        XCTAssertEqual(response.memory, "")
        XCTAssertNil(response.user)
        XCTAssertNil(response.soul)
        XCTAssertNil(response.memoryMtime)
        XCTAssertNil(response.userMtime)
        XCTAssertNil(response.soulMtime)
        XCTAssertNil(response.projectContext)
        XCTAssertNil(response.projectContextName)
        XCTAssertNil(response.projectContextPath)
        XCTAssertNil(response.projectContextWorkspace)
        XCTAssertNil(response.projectContextMtime)
        XCTAssertNil(response.projectContextShadowed)
        XCTAssertNil(response.externalNotesEnabled)
    }

    func testMemoryDecodesProjectContextShadowedBooleanShape() async throws {
        // The API docs describe project_context_shadowed as a boolean flag even though
        // upstream currently sends a list; both shapes must decode.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(MemoryResponse.self, from: Data("""
            {
              "project_context": "# Project",
              "project_context_shadowed": true
            }
            """.utf8))

        XCTAssertEqual(response.projectContext, "# Project")
        XCTAssertEqual(response.projectContextShadowed, true)
    }

    func testMemoryDecodesEmptyShadowedListAsNotShadowed() async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(MemoryResponse.self, from: Data("""
            {
              "project_context": "# Project",
              "project_context_shadowed": []
            }
            """.utf8))

        XCTAssertEqual(response.projectContextShadowed, false)
    }

    func testMemoryToleratesNullAndUnexpectedShadowedShapes() async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(MemoryResponse.self, from: Data("""
            {
              "project_context": "# Project",
              "project_context_shadowed": null,
              "external_notes_enabled": "yes"
            }
            """.utf8))

        XCTAssertNil(response.projectContextShadowed)
        XCTAssertNil(response.externalNotesEnabled)
    }

    func testRetainedMemoryWriteReceiptDecodesKnownFields() async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(MemoryWriteResponse.self, from: Data("""
            {
              "ok": true,
              "section": "user",
              "path": "/Users/test/.hermes/memories/USER.md",
              "unexpected": "ignored"
            }
            """.utf8))

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.section, .user)
        XCTAssertEqual(response.path, "/Users/test/.hermes/memories/USER.md")
    }

    func testMemoryWriteToleratesMissingFieldsAndUnknownSection() async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(MemoryWriteResponse.self, from: Data("""
            {
              "section": "future"
            }
            """.utf8))

        XCTAssertNil(response.ok)
        XCTAssertNil(response.section)
        XCTAssertNil(response.path)
    }
}
