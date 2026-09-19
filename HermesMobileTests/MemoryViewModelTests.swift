import XCTest
@testable import HermesMobile

@MainActor
final class MemoryViewModelTests: APIClientTestCase {
    func testCancelledLoadDoesNotReadOrPublish() async throws {
        let fixture = DirectMemoryTestServer()
        let vm = model(fixture)
        let load = Task { await vm.load() }
        load.cancel()
        await load.value
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(fixture.paths.isEmpty)
    }

    func testRejectedMultipartUploadPreservesOriginalAndDoesNotRetry() async throws {
        for status in [403, 409] {
            let fixture = DirectMemoryTestServer()
            let vm = model(fixture)
            await vm.load()
            fixture.writeStatus = status
            let saved = await vm.save(section: .memory, content: "rejected")
            XCTAssertFalse(saved)
            XCTAssertEqual(vm.memoryText, "notes")
            XCTAssertEqual(fixture.notes, "notes")
            XCTAssertTrue(vm.hasUnconfirmedSave)
            guard let error = vm.lastError as? DirectHermesRequestError,
                  case .http(let code, _) = error else {
                XCTFail("Underlying direct HTTP classification must survive")
                continue
            }
            XCTAssertEqual(code, status)
            let retried = await vm.save(section: .memory, content: "rejected")
            XCTAssertFalse(retried)
            XCTAssertEqual(fixture.writes, ["/api/files/upload-stream"])
        }
    }

    func testSaveWritesSelectedSectionAndConfirmsReadback() async throws {
        let fixture = DirectMemoryTestServer()
        let vm = model(fixture)
        await vm.load()
        XCTAssertEqual(vm.scope?.memoryEnabled, false)
        XCTAssertEqual(vm.scope?.externalProvider, "honcho")
        vm.beginEditing(.soul)
        let saved = await vm.save(section: .soul, content: "updated soul")
        XCTAssertTrue(saved)
        XCTAssertEqual(vm.soulText, "updated soul")
        XCTAssertEqual(vm.userText, "user")
        XCTAssertEqual(fixture.writes, ["/api/profiles/work/soul"])
    }

    func testInterveningEditRejectsSaveEvenIfViewRefreshedDuringEditing() async throws {
        let fixture = DirectMemoryTestServer()
        let vm = model(fixture)
        await vm.load()
        vm.beginEditing(.memory)
        fixture.notes = "other writer"
        await vm.load()
        let saved = await vm.save(section: .memory, content: "my draft")
        XCTAssertFalse(saved)
        XCTAssertTrue(fixture.writes.isEmpty)
        XCTAssertEqual(vm.memoryText, "other writer")
        XCTAssertTrue(vm.actionErrorMessage?.contains("changed on the server") == true)
    }

    func testUnconfirmedWriteIsNotRetriedAndRefreshRecoversServerCopy() async throws {
        let fixture = DirectMemoryTestServer()
        let vm = model(fixture)
        await vm.load()
        fixture.loseWriteResponse = true
        let saved = await vm.save(section: .memory, content: "accepted before disconnect")
        XCTAssertFalse(saved)
        XCTAssertTrue(vm.hasUnconfirmedSave)
        let retried = await vm.save(section: .memory, content: "accepted before disconnect")
        XCTAssertFalse(retried)
        XCTAssertEqual(fixture.writes.count, 1)
        await vm.load()
        XCTAssertFalse(vm.hasUnconfirmedSave)
        XCTAssertEqual(vm.memoryText, "accepted before disconnect")
    }

    func testDeniedBuiltinReadDoesNotPretendEmptyOrBlockSoul() async throws {
        let fixture = DirectMemoryTestServer()
        fixture.denyNotes = true
        let vm = model(fixture)
        await vm.load()
        XCTAssertTrue(vm.hasLoaded)
        XCTAssertNil(vm.memoryText)
        XCTAssertFalse(vm.canEdit(.memory))
        XCTAssertNotNil(vm.sectionErrors["memory"])
        XCTAssertTrue(vm.canEdit(.soul))
        XCTAssertFalse(fixture.paths.contains { $0.hasPrefix("/api/fs") })
    }

    func testReadbackMismatchNeverReportsSuccessfulSave() async throws {
        let fixture = DirectMemoryTestServer()
        let vm = model(fixture)
        await vm.load()
        fixture.ignoreWrite = true
        let saved = await vm.save(section: .user, content: "not persisted")
        XCTAssertFalse(saved)
        XCTAssertTrue(vm.hasUnconfirmedSave)
        XCTAssertEqual(vm.userText, "user")
        XCTAssertEqual(fixture.writes.count, 1)
    }

    func testMissingBuiltinDocumentCreatesWithoutOverwrite() async throws {
        let fixture = DirectMemoryTestServer()
        fixture.notes = nil
        let vm = model(fixture)
        await vm.load()
        XCTAssertEqual(vm.memoryText, "")
        let saved = await vm.save(section: .memory, content: "first note")
        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.lastOverwrite, false)
    }

    func testProjectContextPresentationRemainsWithoutInventingDiscovery() async throws {
        let vm = model(DirectMemoryTestServer())
        await vm.load()
        XCTAssertFalse(vm.showsProjectContext)
        XCTAssertNil(vm.isExternalNotesEnabled)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(MemoryResponse.self, from: Data(##"{"project_context":"# Rules","project_context_name":"AGENTS.md","project_context_workspace":"/workspace","project_context_mtime":1770000300,"project_context_shadowed":[{"name":"old"}]}"##.utf8))
        vm.applyProjectContext(response)
        XCTAssertTrue(vm.showsProjectContext)
        XCTAssertEqual(vm.projectContextText, "# Rules")
        XCTAssertEqual(vm.projectContextDetail, "AGENTS.md — /workspace")
        XCTAssertTrue(vm.isProjectContextShadowed)
        XCTAssertEqual(vm.projectContextMtime, Date(timeIntervalSince1970: 1770000300))
        let blank = try decoder.decode(MemoryResponse.self, from: Data(#"{"project_context":"  ","project_context_name":"","project_context_workspace":"/workspace"}"#.utf8))
        vm.applyProjectContext(blank)
        XCTAssertFalse(vm.showsProjectContext)
        XCTAssertEqual(vm.projectContextDetail, "/workspace")
    }

    private func model(_ fixture: DirectMemoryTestServer) -> MemoryViewModel {
        MemoryViewModel(server: URL(string: "https://example.test")!, profile: "work", client: makeClient { try fixture.respond($0) })
    }
}

/// In-memory endpoint fixture; no real filesystem or provider is accessed.
final class DirectMemoryTestServer: @unchecked Sendable {
    var notes: String? = "notes"
    var user = "user"
    var soul = "soul"
    var home = "/fixture/profile work"
    var denyNotes = false
    var loseWriteResponse = false
    var ignoreWrite = false
    var writeStatus: Int?
    var lastOverwrite: Bool?
    var writes: [String] = []
    var paths: [String] = []

    func respond(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let path = request.url?.path ?? ""
        paths.append(path)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func json(_ object: [String: Any], status: Int = 200) throws -> (HTTPURLResponse, Data) {
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, try JSONSerialization.data(withJSONObject: object))
        }
        switch path {
        case "/api/profiles":
            return try json(["profiles": [["name": "default", "path": "/unselected"], ["name": "work", "path": home]]])
        case "/api/config":
            XCTAssertEqual(query.first { $0.name == "profile" }?.value, "work")
            XCTAssertEqual(request.httpMethod, "GET")
            return try json(["memory": ["memory_enabled": false, "user_profile_enabled": true, "provider": "honcho"]])
        case "/api/files/read":
            let target = try XCTUnwrap(query.first { $0.name == "path" }?.value)
            XCTAssertTrue([home + "/memories/MEMORY.md", home + "/memories/USER.md"].contains(target))
            if target.hasSuffix("MEMORY.md"), denyNotes { return try json(["detail": "denied"], status: 403) }
            let content = target.hasSuffix("MEMORY.md") ? notes : user
            guard let content else { return try json(["detail": "File not found"], status: 404) }
            return try json(["path": target, "name": "memory.md", "mime_type": "text/markdown", "size": content.utf8.count, "data_url": "data:text/markdown;base64," + Data(content.utf8).base64EncodedString()])
        case "/api/profiles/work/soul" where request.httpMethod == "GET":
            return try json(["content": soul, "exists": true])
        case "/api/files/upload-stream", "/api/profiles/work/soul":
            writes.append(path)
            if let writeStatus { return try json(["detail": "Write rejected"], status: writeStatus) }
            let data = try XCTUnwrap(apiTestBodyData(from: request))
            if path == "/api/files/upload-stream" {
                XCTAssertEqual(request.httpMethod, "POST")
                let type = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
                XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
                let boundary = try XCTUnwrap(type.components(separatedBy: "boundary=").last)
                let body = try XCTUnwrap(String(data: data, encoding: .utf8))
                XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))
                let parts = body.components(separatedBy: "--\(boundary)\r\n")
                func value(_ name: String) throws -> String {
                    let part = try XCTUnwrap(parts.first { $0.hasPrefix("Content-Disposition: form-data; name=\"\(name)\"") })
                    let range = try XCTUnwrap(part.range(of: "\r\n\r\n"))
                    let text = String(part[range.upperBound...])
                    let closing = "\r\n--\(boundary)--\r\n"
                    let suffix = text.hasSuffix(closing) ? closing : "\r\n"
                    XCTAssertTrue(text.hasSuffix(suffix))
                    return String(text.dropLast(suffix.count))
                }
                let target = try value("path")
                XCTAssertTrue([home + "/memories/MEMORY.md", home + "/memories/USER.md"].contains(target))
                let overwrite = try value("overwrite")
                XCTAssertTrue(["true", "false"].contains(overwrite))
                lastOverwrite = overwrite == "true"
                let filename = target.hasSuffix("MEMORY.md") ? "MEMORY.md" : "USER.md"
                XCTAssertTrue(body.contains("name=\"file\"; filename=\"\(filename)\"\r\n"))
                let content = try value("file")
                if !ignoreWrite {
                    if target.hasSuffix("MEMORY.md") { notes = content } else { user = content }
                }
                if loseWriteResponse { throw URLError(.networkConnectionLost) }
                return try json(["ok": true, "path": target])
            }
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if !ignoreWrite { soul = try XCTUnwrap(body["content"] as? String) }
            if loseWriteResponse { throw URLError(.networkConnectionLost) }
            return try json(["ok": true])
        default:
            XCTFail("Unexpected memory route: \(path)")
            throw URLError(.badURL)
        }
    }
}
