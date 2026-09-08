import XCTest
import AVFoundation
import ImageIO
import PDFKit
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientWorkspaceFileTests: APIClientTestCase {
    func testWorkspaceReadRejectsReturnedCanonicalPathOutsideRoot() async throws {
        let client = makeClient { request in
            if let fixture = try workspaceTraversalFixture(request) { return fixture }
            XCTAssertEqual(request.url?.path, "/api/files/read")
            return apiTestJSONResponse(#"{"path":"/outside/Notes.txt","data_url":"data:text/plain;base64,c2VjcmV0"}"#, for: request)
        }
        do {
            _ = try await client.directWorkspaceDownload(sessionID: "session-abc", profile: "default", path: "Sources/Notes.txt")
            XCTFail("Must not expose bytes from mismatched canonical path")
        } catch DirectWorkspaceError.outsideWorkspace {}
    }

    @MainActor
    func testCancelledBrowserDoesNotPublishLateDirectory() async throws {
        let started = expectation(description: "Directory suspended")
        WorkspacePreviewReadGate.configure(holdDirectory: true, started: { started.fulfill() })
        defer { WorkspacePreviewReadGate.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspacePreviewReadGate.self]
        let client = APIClient(baseURL: URL(string: "https://example.test")!,
                               session: URLSession(configuration: configuration))
        let model = FileBrowserViewModel(session: try makeFilePreviewSession(),
            server: URL(string: "https://example.test")!, apiClient: client)
        let load = Task { await model.loadRoot() }
        await fulfillment(of: [started], timeout: 2)
        load.cancel()
        WorkspacePreviewReadGate.completeOlder()
        await load.value
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testCancelledExportDoesNotPublishError() async throws {
        let started = expectation(description: "Export suspended")
        WorkspacePreviewReadGate.configure(started: { started.fulfill() })
        defer { WorkspacePreviewReadGate.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspacePreviewReadGate.self]
        let client = APIClient(baseURL: URL(string: "https://example.test")!,
                               session: URLSession(configuration: configuration))
        let model = FilePreviewViewModel(session: try makeFilePreviewSession(),
            server: URL(string: "https://example.test")!, path: "Sources/Notes.txt", apiClient: client)
        let export = Task { try? await model.exportPayload() }
        await fulfillment(of: [started], timeout: 2)
        export.cancel()
        WorkspacePreviewReadGate.completeOlder()
        _ = await export.value
        XCTAssertNil(model.exportErrorMessage)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.isExporting)
    }

    @MainActor
    func testFilePreviewLatestReadWinsWhenOlderResponseArrivesLast() async throws {
        let started = expectation(description: "First read suspended")
        WorkspacePreviewReadGate.configure(started: { started.fulfill() })
        defer { WorkspacePreviewReadGate.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspacePreviewReadGate.self]
        let client = APIClient(baseURL: URL(string: "https://example.test")!,
                               session: URLSession(configuration: configuration))
        let model = FilePreviewViewModel(session: try makeFilePreviewSession(),
            server: URL(string: "https://example.test")!, path: "Sources/Notes.txt", apiClient: client)
        let old = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)
        await model.load()
        WorkspacePreviewReadGate.completeOlder()
        await old.value
        guard case .text(let file) = model.preview else { return XCTFail("Expected text preview") }
        XCTAssertEqual(file.content, "new")
        let exported = try await model.exportPayload()
        XCTAssertEqual(exported.data, Data("new".utf8))
        XCTAssertFalse(model.isLoading)
    }

    func testDirectWorkspaceRequiresFreshCwdWithoutHostHomeFallback() async throws {
        var requests = 0
        let client = makeClient { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc")
            return apiTestJSONResponse(#"{"id":"session-abc","profile":"work"}"#, for: request)
        }
        do {
            _ = try await client.directWorkspaceDirectory(sessionID: "session-abc", profile: "work", path: ".")
            XCTFail("Missing cwd must not browse a host default")
        } catch DirectWorkspaceError.missingWorkspace {}
        XCTAssertEqual(requests, 1)
    }

    func testDirectWorkspaceMapsMetadataAndExcludesResolvedOutsideEntries() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/sessions/session-abc" {
                return apiTestJSONResponse(#"{"id":"session-abc","cwd":"/workspace","profile":"work"}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/files")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "path", value: "/workspace")])
            return apiTestJSONResponse(#"{"path":"/workspace","entries":[{"name":"notes","path":"/workspace/notes","is_directory":true,"mtime":12},{"name":"outside","path":"/private/other","is_directory":true}]}"#, for: request)
        }
        let listing = try await client.directWorkspaceDirectory(sessionID: "session-abc", profile: "work", path: ".")
        XCTAssertEqual(listing.path, ".")
        XCTAssertEqual(listing.entries?.count, 1)
        XCTAssertEqual(listing.entries?.first?.path, "notes")
        XCTAssertEqual(listing.entries?.first?.modified, 12)
        XCTAssertEqual(listing.entries?.first?.isBrowsableDirectory, true)
        do {
            _ = try await client.directWorkspaceDownload(sessionID: "session-abc", profile: "work", path: "outside/file.txt")
            XCTFail("Must not request a resolved outside directory")
        } catch DirectWorkspaceError.outsideWorkspace {}
    }

    func testDirectWorkspaceRejectsTraversalBeforeRequests() async throws {
        let client = makeClient { _ in XCTFail("Must not request"); throw URLError(.badURL) }
        for path in ["", "../outside", "/host", "dir/../outside"] {
            do {
                _ = try await client.directWorkspaceDirectory(sessionID: "session-abc", profile: "default", path: path)
                XCTFail("Expected invalid path")
            } catch DirectWorkspaceError.invalidPath {}
        }
    }

    func testProjectsBuildsExpectedPathAndDecodesProjectList() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/projects")
            XCTAssertNil(request.httpBody)

            return apiTestJSONResponse("""
            {
              "projects": [
                {
                  "project_id": "proj123",
                  "name": "Client Work",
                  "color": "#336699",
                  "created_at": 1770000000
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.projects()
        let project = try XCTUnwrap(response.projects?.first)

        XCTAssertEqual(project.projectId, "proj123")
        XCTAssertEqual(project.name, "Client Work")
        XCTAssertEqual(project.color, "#336699")
        XCTAssertEqual(project.createdAt, 1_770_000_000)
    }

    func testProjectsToleratesLossyProjectFields() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/projects")

            return apiTestJSONResponse("""
            {
              "projects": [
                {
                  "project_id": 123,
                  "name": true,
                  "color": 456,
                  "created_at": "1770000000"
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.projects()
        let project = try XCTUnwrap(response.projects?.first)

        XCTAssertEqual(project.projectId, "123")
        XCTAssertEqual(project.name, "true")
        XCTAssertEqual(project.color, "456")
        XCTAssertEqual(project.createdAt, 1_770_000_000)
    }

    func testCreateProjectBuildsExpectedBodyAndDecodesCreatedProject() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/projects/create")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["name"] as? String, "Client Work")
            XCTAssertEqual(json?["color"] as? String, "#7cb9ff")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "project": {
                "project_id": "proj123",
                "name": "Client Work",
                "color": "#7cb9ff",
                "profile": "default",
                "created_at": 1770000000
              }
            }
            """, for: request)
        }

        let response = try await client.createProject(name: "Client Work", color: "#7cb9ff")
        let project = try XCTUnwrap(response.project)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(project.projectId, "proj123")
        XCTAssertEqual(project.name, "Client Work")
        XCTAssertEqual(project.color, "#7cb9ff")
        XCTAssertEqual(project.createdAt, 1_770_000_000)
    }

    func testRenameProjectBuildsExpectedBodyAndDecodesRenamedProject() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/projects/rename")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["project_id"] as? String, "proj123")
            XCTAssertEqual(json?["name"] as? String, "Client Archive")
            XCTAssertEqual(json?["color"] as? String, "#f5c542")
            XCTAssertNil(json?["projectId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "project": {
                "project_id": "proj123",
                "name": "Client Archive",
                "color": "#f5c542",
                "created_at": "1770000000",
                "unexpected": "ignored"
              }
            }
            """, for: request)
        }

        let response = try await client.renameProject(id: "proj123", name: "Client Archive", color: "#f5c542")
        let project = try XCTUnwrap(response.project)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(project.projectId, "proj123")
        XCTAssertEqual(project.name, "Client Archive")
        XCTAssertEqual(project.color, "#f5c542")
        XCTAssertEqual(project.createdAt, 1_770_000_000)
    }

    func testRenameProjectOmitsColorWhenNil() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/projects/rename")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["project_id"] as? String, "proj123")
            XCTAssertEqual(json?["name"] as? String, "Client Archive")
            XCTAssertNil(json?["color"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "project": {
                "project_id": "proj123",
                "name": "Client Archive"
              }
            }
            """, for: request)
        }

        let response = try await client.renameProject(id: "proj123", name: "Client Archive", color: nil)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.project?.projectId, "proj123")
        XCTAssertNil(response.project?.color)
    }

    func testDeleteProjectBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/projects/delete")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["project_id"] as? String, "proj123")
            XCTAssertNil(json?["projectId"])

            return apiTestJSONResponse(#"{"ok": true}"#, for: request)
        }

        let response = try await client.deleteProject(id: "proj123")

        XCTAssertEqual(response.ok, true)
        XCTAssertNil(response.project)
    }

    func testWorkspacesDecodesWorkspaceObjects() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces")

            return apiTestJSONResponse("""
            {
              "workspaces": [
                {"path": "/Users/test/project", "name": "Project"}
              ],
              "last": "/Users/test/project"
            }
            """, for: request)
        }

        let response = try await client.workspaces()

        XCTAssertEqual(response.last, "/Users/test/project")
        XCTAssertEqual(response.workspaces?.first?.path, "/Users/test/project")
        XCTAssertEqual(response.workspaces?.first?.name, "Project")
    }

    func testWorkspacesToleratesLegacyStringEntries() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces")

            return apiTestJSONResponse("""
            {
              "workspaces": ["/Users/test/project"],
              "last": null
            }
            """, for: request)
        }

        let response = try await client.workspaces()

        XCTAssertEqual(response.workspaces?.first?.path, "/Users/test/project")
        XCTAssertNil(response.workspaces?.first?.name)
    }

    func testWorkspaceSuggestionsBuildsExpectedQueryAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces/suggest")
            XCTAssertEqual(request.httpMethod, "GET")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["prefix"], "/Users/test/pro")

            return apiTestJSONResponse("""
            {
              "suggestions": [
                "/Users/test/project",
                "/Users/test/prototypes"
              ],
              "prefix": "/Users/test/pro"
            }
            """, for: request)
        }

        let response = try await client.workspaceSuggestions(prefix: "/Users/test/pro")

        XCTAssertEqual(response.prefix, "/Users/test/pro")
        XCTAssertEqual(response.suggestions, ["/Users/test/project", "/Users/test/prototypes"])
    }

    func testAddWorkspaceBuildsExpectedBodyAndDecodesUpdatedList() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces/add")
            XCTAssertEqual(request.httpMethod, "POST")

            let json = try apiTestJSONBody(from: request)
            XCTAssertEqual(json["path"] as? String, "/Users/test/newproject")
            XCTAssertEqual(json["name"] as? String, "New Project")
            XCTAssertEqual(json["create"] as? Bool, true)

            return apiTestJSONResponse("""
            {
              "ok": true,
              "workspaces": [
                {"path": "/Users/test/project", "name": "Project"},
                {"path": "/Users/test/newproject", "name": "New Project"}
              ]
            }
            """, for: request)
        }

        let response = try await client.addWorkspace(path: "/Users/test/newproject", name: "New Project", create: true)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.workspaces?.count, 2)
        XCTAssertEqual(response.workspaces?.last?.path, "/Users/test/newproject")
        XCTAssertEqual(response.workspaces?.last?.name, "New Project")
    }

    func testAddWorkspaceOmitsOptionalFieldsWhenNil() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces/add")

            let json = try apiTestJSONBody(from: request)
            XCTAssertEqual(json["path"] as? String, "/Users/test/newproject")
            XCTAssertNil(json["name"])
            XCTAssertNil(json["create"])

            return apiTestJSONResponse("""
            {"ok": true, "workspaces": [{"path": "/Users/test/newproject", "name": "newproject"}]}
            """, for: request)
        }

        let response = try await client.addWorkspace(path: "/Users/test/newproject")

        XCTAssertEqual(response.ok, true)
    }

    func testAddWorkspaceSurfacesServerErrorString() async throws {
        let client = makeClient { request in
            let (_, data) = apiTestJSONResponse("""
            {"error": "Workspace already in list"}
            """, for: request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        do {
            _ = try await client.addWorkspace(path: "/Users/test/project")
            XCTFail("Expected APIError.http")
        } catch let error as APIError {
            XCTAssertEqual(error.serverMessage, "Workspace already in list")
            XCTAssertTrue(error.localizedDescription.contains("Workspace already in list"))
        }
    }

    func testRemoveWorkspaceBuildsExpectedBodyAndDecodesUpdatedList() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces/remove")
            XCTAssertEqual(request.httpMethod, "POST")

            let json = try apiTestJSONBody(from: request)
            XCTAssertEqual(json["path"] as? String, "/Users/test/oldproject")

            return apiTestJSONResponse("""
            {"ok": true, "workspaces": [{"path": "/Users/test/project", "name": "Project"}]}
            """, for: request)
        }

        let response = try await client.removeWorkspace(path: "/Users/test/oldproject")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.workspaces?.map(\.path), ["/Users/test/project"])
    }

    func testRenameWorkspaceBuildsExpectedBodyAndDecodesUpdatedList() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces/rename")
            XCTAssertEqual(request.httpMethod, "POST")

            let json = try apiTestJSONBody(from: request)
            XCTAssertEqual(json["path"] as? String, "/Users/test/project")
            XCTAssertEqual(json["name"] as? String, "Renamed")

            return apiTestJSONResponse("""
            {"ok": true, "workspaces": [{"path": "/Users/test/project", "name": "Renamed"}]}
            """, for: request)
        }

        let response = try await client.renameWorkspace(path: "/Users/test/project", name: "Renamed")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.workspaces?.first?.name, "Renamed")
    }

    func testReorderWorkspacesBuildsExpectedBodyAndDecodesUpdatedList() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces/reorder")
            XCTAssertEqual(request.httpMethod, "POST")

            let json = try apiTestJSONBody(from: request)
            XCTAssertEqual(json["paths"] as? [String], ["/Users/test/b", "/Users/test/a"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "workspaces": [
                {"path": "/Users/test/b", "name": "B"},
                {"path": "/Users/test/a", "name": "A"}
              ]
            }
            """, for: request)
        }

        let response = try await client.reorderWorkspaces(paths: ["/Users/test/b", "/Users/test/a"])

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.workspaces?.compactMap(\.path), ["/Users/test/b", "/Users/test/a"])
    }

    func testWorkspaceMutationToleratesMissingWorkspacesEcho() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {"ok": true, "unexpected_new_field": {"nested": 1}}
            """, for: request)
        }

        let response = try await client.removeWorkspace(path: "/Users/test/project")

        XCTAssertEqual(response.ok, true)
        XCTAssertNil(response.workspaces)
    }

    func testDirectoryListDecodesUpstreamEntries() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/list")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "abc123")
            XCTAssertEqual(query["path"], ".")

            return apiTestJSONResponse("""
            {
              "entries": [
                {"name": "Sources", "path": "Sources", "type": "dir", "size": null},
                {"name": "LinkedDocs", "path": "LinkedDocs", "type": "symlink", "is_dir": true},
                {"name": "README.md", "path": "README.md", "type": "file", "size": 1200}
              ],
              "path": "."
            }
            """, for: request)
        }

        let response = try await client.directoryList(sessionID: "abc123", path: ".")

        XCTAssertEqual(response.path, ".")
        XCTAssertEqual(response.entries?.count, 3)
        XCTAssertEqual(response.entries?[0].name, "Sources")
        XCTAssertEqual(response.entries?[0].type, "dir")
        XCTAssertEqual(response.entries?[1].type, "symlink")
        XCTAssertEqual(response.entries?[1].isDirectory, true)
        XCTAssertEqual(response.entries?[2].size, 1200)
    }

    func testDirectoryListBuildsNestedPathQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/list")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "abc123")
            XCTAssertEqual(query["path"], "Sources/App")

            return apiTestJSONResponse("""
            {
              "entries": [],
              "path": "Sources/App"
            }
            """, for: request)
        }

        let response = try await client.directoryList(sessionID: "abc123", path: "Sources/App")

        XCTAssertEqual(response.path, "Sources/App")
    }

    @MainActor
    func testFileBrowserLatestDirectoryRequestWins() async throws {
        let firstRequestStarted = expectation(description: "First directory request started")
        let client = makeClient { request in
            if let fixture = try workspaceTraversalFixture(request) { return fixture }
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let path = components?.queryItems?.first(where: { $0.name == "path" })?.value

            if path == "/tmp/workspace/cat" {
                firstRequestStarted.fulfill()
                Thread.sleep(forTimeInterval: 0.3)
            }

            return apiTestJSONResponse("""
            {
              "entries": [],
              "path": "\(path ?? "/tmp/workspace")"
            }
            """, for: request)
        }
        let viewModel = try FileBrowserViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            apiClient: client
        )

        let firstLoad = Task { await viewModel.load(path: "cat") }
        await fulfillment(of: [firstRequestStarted], timeout: 1)
        let latestLoad = Task { await viewModel.load(path: "leetcode-editor") }

        await latestLoad.value
        await firstLoad.value

        XCTAssertEqual(viewModel.currentPath, "leetcode-editor")
    }

    @MainActor
    func testFileBrowserRetriesFailedDirectoryWithoutDiscardingCurrentEntries() async throws {
        var catAttempts = 0
        let client = makeClient { request in
            if let fixture = try workspaceTraversalFixture(request) { return fixture }
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let path = components?.queryItems?.first(where: { $0.name == "path" })?.value

            if path == "/tmp/workspace/cat" {
                catAttempts += 1
                if catAttempts == 1 {
                    let response = HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                    return (try XCTUnwrap(response), Data(#"{"error":"temporarily unavailable"}"#.utf8))
                }
            }

            return apiTestJSONResponse("""
            {
              "entries": [{"name": "cat", "path": "/tmp/workspace/cat", "is_directory": true}],
              "path": "\(path ?? "/tmp/workspace")"
            }
            """, for: request)
        }
        let viewModel = try FileBrowserViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            apiClient: client
        )

        await viewModel.loadRoot()
        await viewModel.load(path: "cat")

        XCTAssertEqual(viewModel.currentPath, ".")
        XCTAssertEqual(viewModel.entries.first?.name, "cat")
        XCTAssertNotNil(viewModel.errorMessage)

        await viewModel.retryLastLoad()

        XCTAssertEqual(viewModel.currentPath, "cat")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(catAttempts, 2)
    }

    @MainActor
    func testFileBrowserCancellationDoesNotSurfaceError() async throws {
        let client = makeClient { _ in
            throw URLError(.cancelled)
        }
        let viewModel = try FileBrowserViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            apiClient: client
        )

        await viewModel.loadRoot()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    func testFileReadBuildsExpectedQueryAndDecodesTextResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/file")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "abc123")
            XCTAssertEqual(query["path"], "Sources/App/FilePreviewView.swift")

            return apiTestJSONResponse("""
            {
              "path": "Sources/App/FilePreviewView.swift",
              "content": "import SwiftUI\\n",
              "size": 15,
              "lines": 2,
              "unexpected": "ignored"
            }
            """, for: request)
        }

        let response = try await client.file(sessionID: "abc123", path: "Sources/App/FilePreviewView.swift")

        XCTAssertEqual(response.path, "Sources/App/FilePreviewView.swift")
        XCTAssertEqual(response.content, "import SwiftUI\n")
        XCTAssertEqual(response.size, 15)
        XCTAssertEqual(response.lines, 2)
    }

    func testFileReadToleratesMissingOptionalMetadata() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/file")

            return apiTestJSONResponse("""
            {
              "content": "hello"
            }
            """, for: request)
        }

        let response = try await client.file(sessionID: "abc123", path: "README.md")

        XCTAssertEqual(response.content, "hello")
        XCTAssertNil(response.path)
        XCTAssertNil(response.size)
        XCTAssertNil(response.lines)
    }

    func testRawFileBuildsExpectedQueryAndReturnsBytes() async throws {
        let expectedData = Data([0x89, 0x50, 0x4E, 0x47])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/file/raw")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "abc123")
            XCTAssertEqual(query["path"], "Screenshots/result.png")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )
            return (try XCTUnwrap(response), expectedData)
        }

        let response = try await client.rawFileData(sessionID: "abc123", path: "Screenshots/result.png")

        XCTAssertEqual(response, expectedData)
    }

    func testRawFilePreviewRejectsPayloadAboveByteLimit() async throws {
        let oversizedData = Data(repeating: 0x41, count: 5)
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/pdf",
                    "Content-Length": String(oversizedData.count)
                ]
            )
            return (try XCTUnwrap(response), oversizedData)
        }

        do {
            _ = try await client.rawFilePreviewData(
                sessionID: "abc123",
                path: "report.pdf",
                maximumBytes: 4
            )
            XCTFail("Expected oversized preview data to be rejected.")
        } catch let PreviewDownloadError.responseTooLarge(maximumBytes) {
            XCTAssertEqual(maximumBytes, 4)
        } catch {
            XCTFail("Expected responseTooLarge, got \(error)")
        }
    }

    func testBoundedPreviewCancelsTransferWhenHeadersExceedLimit() async throws {
        let stopped = expectation(description: "oversized transfer cancelled")
        CancellablePreviewURLProtocol.configure(contentLength: 5) {
            stopped.fulfill()
        }
        defer { CancellablePreviewURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancellablePreviewURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(baseURL: URL(string: "https://example.test")!, session: session)

        do {
            _ = try await client.rawFilePreviewData(
                sessionID: "abc123",
                path: "report.pdf",
                maximumBytes: 4
            )
            XCTFail("Expected oversized preview data to be rejected.")
        } catch let PreviewDownloadError.responseTooLarge(maximumBytes) {
            XCTAssertEqual(maximumBytes, 4)
        }

        await fulfillment(of: [stopped], timeout: 1)
    }

    func testRemotePreviewUsesMIMEDiscoveredDocumentLimitBeforeReadingBody() async throws {
        let data = Data(repeating: 0x41, count: 5)
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/pdf",
                    "Content-Length": String(data.count)
                ]
            )
            return (try XCTUnwrap(response), data)
        }

        do {
            _ = try await client.remoteTranscriptMediaPreviewResource(
                from: try XCTUnwrap(URL(string: "https://example.test/generated/image.png")),
                maximumBytes: 8,
                documentMaximumBytes: 4,
                nameOrPath: "https://example.test/generated/image.png"
            )
            XCTFail("Expected MIME-discovered PDF to use the document limit.")
        } catch let PreviewDownloadError.responseTooLarge(maximumBytes) {
            XCTAssertEqual(maximumBytes, 4)
        }
    }

    func testMediaDataBuildsExpectedQueryAndReturnsBytes() async throws {
        let expectedData = Data([0x89, 0x50, 0x4E, 0x47])
        let mediaPath = "/Users/hermes/.hermes/browser_screenshots/result image.png"
        let sessionID = "abc123"
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/media")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], sessionID)
            XCTAssertEqual(query["path"], mediaPath)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )
            return (try XCTUnwrap(response), expectedData)
        }

        let response = try await client.mediaData(sessionID: sessionID, path: mediaPath)

        XCTAssertEqual(response, expectedData)
    }

    func testMediaDataDecodesStockJSONImageEnvelope() async throws {
        let expectedData = Data([0x89, 0x50, 0x4E, 0x47])
        let dataURL = "data:image/png;base64,\(expectedData.base64EncodedString())"
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/media")
            return apiTestJSONResponse(
                #"{"data_url":"\#(dataURL)"}"#,
                for: request
            )
        }

        let response = try await client.mediaData(sessionID: "abc123", path: "images/result.png")

        XCTAssertEqual(response, expectedData)
    }

    func testMediaDataRejectsMalformedJSONEnvelope() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("{not-json", for: request)
        }

        do {
            _ = try await client.mediaData(sessionID: "abc123", path: "images/result.png")
            XCTFail("Expected malformed media JSON to be rejected.")
        } catch APIError.decoding {
            // The JSON decoding detail is intentionally kept out of the public
            // error surface; callers only need a safe decoding failure.
        } catch {
            XCTFail("Expected APIError.decoding, got \(error)")
        }
    }

    func testMediaDataRejectsMissingDataURL() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"unexpected":"field"}"#, for: request)
        }

        do {
            _ = try await client.mediaData(sessionID: "abc123", path: "images/result.png")
            XCTFail("Expected a missing data_url to be rejected.")
        } catch APIError.decoding {
            // Missing data_url is a decoding failure, not raw media bytes.
        } catch {
            XCTFail("Expected APIError.decoding, got \(error)")
        }
    }

    func testMediaDataRejectsInvalidBase64AndNonImageDataURLs() async throws {
        let cases = [
            #"{"data_url":"data:image/png;base64,not valid base64"}"#,
            #"{"data_url":"data:application/pdf;base64,JVBERi0="}"#
        ]

        for body in cases {
            let client = makeClient { request in
                apiTestJSONResponse(body, for: request)
            }

            do {
                _ = try await client.mediaData(sessionID: "abc123", path: "images/result.png")
                XCTFail("Expected invalid media data URL to be rejected.")
            } catch APIError.decoding {
                // Invalid base64 and non-image MIME types are decoding failures.
            } catch {
                XCTFail("Expected APIError.decoding, got \(error)")
            }
        }
    }

    func testMediaPreviewRejectsDecodedImageAboveLimit() async throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let body = #"{"data_url":"data:image/png;base64,\#(imageData.base64EncodedString())"}"#
        let client = makeClient { request in
            apiTestJSONResponse(body, for: request)
        }

        do {
            _ = try await client.mediaPreviewData(
                sessionID: "abc123",
                path: "images/result.png",
                maximumBytes: imageData.count - 1
            )
            XCTFail("Expected decoded image limit to be enforced.")
        } catch let PreviewDownloadError.responseTooLarge(maximumBytes) {
            XCTAssertEqual(maximumBytes, imageData.count - 1)
        }
    }

    func testMediaPreviewBoundsEncodedJSONEnvelopeBeforeDecoding() async throws {
        let payload = Data(repeating: 0x41, count: 600).base64EncodedString()
        let body = #"{"data_url":"data:image/png;base64,\#(payload)"}"#
        let client = makeClient { request in
            apiTestJSONResponse(body, for: request)
        }
        // ceil(1 / 3) * 4 plus the adapter's fixed 512-byte envelope allowance.
        let expectedEnvelopeLimit = 516

        do {
            _ = try await client.mediaPreviewData(
                sessionID: "abc123",
                path: "images/result.png",
                maximumBytes: 1
            )
            XCTFail("Expected encoded media envelope limit to be enforced.")
        } catch let PreviewDownloadError.responseTooLarge(maximumBytes) {
            XCTAssertEqual(maximumBytes, expectedEnvelopeLimit)
        }
    }

    func testMediaPreviewPreservesRawByteLimitForLegacyResponse() async throws {
        let rawData = Data(repeating: 0x41, count: 5)
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )
            return (try XCTUnwrap(response), rawData)
        }

        do {
            _ = try await client.mediaPreviewData(
                sessionID: "abc123",
                path: "images/result.png",
                maximumBytes: 4
            )
            XCTFail("Expected legacy raw media preview limit to be enforced.")
        } catch let PreviewDownloadError.responseTooLarge(maximumBytes) {
            XCTAssertEqual(maximumBytes, 4)
        }
    }

    func testMediaDataPreservesAuthenticatedUnauthorizedError() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"detail":"unauthorized"}"#.utf8))
        }

        do {
            _ = try await client.mediaData(sessionID: "abc123", path: "images/result.png")
            XCTFail("Expected unauthorized media response to fail.")
        } catch APIError.unauthorized {
            // boundedData maps same-origin 401 responses to APIError.unauthorized.
        } catch {
            XCTFail("Expected APIError.unauthorized, got \(error)")
        }
    }

    @MainActor
    func testFilePreviewExportPayloadUsesLoadedTextContent() async throws {
        let client = makeClient { request in
            if let fixture = try workspaceTraversalFixture(request) { return fixture }
            XCTAssertEqual(request.url?.path, "/api/files/read")

            return apiTestJSONResponse("""
            {
              "path": "/tmp/workspace/Sources/Notes.txt",
              "data_url": "data:text/plain;base64,aGVsbG8K",
              "size": 6,
              "lines": 1
            }
            """, for: request)
        }
        let viewModel = try FilePreviewViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            path: "Sources/Notes.txt",
            apiClient: client
        )

        await viewModel.load()
        let payload = try await viewModel.exportPayload()

        XCTAssertEqual(payload.data, Data("hello\n".utf8))
        XCTAssertEqual(payload.filename, "Notes.txt")
        XCTAssertTrue(payload.contentType.conforms(to: .text))
        XCTAssertFalse(payload.isImage)
    }

    @MainActor
    func testFilePreviewExportPayloadFetchesRawDataForUnsupportedPreview() async throws {
        let rawData = Data([0x50, 0x4B, 0x03, 0x04])
        var requestedPaths: [String] = []
        let client = makeClient { request in
            if let fixture = try workspaceTraversalFixture(request) { return fixture }
            requestedPaths.append(request.url?.path ?? "nil")
            XCTAssertEqual(request.url?.path, "/api/files/read")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertNil(query["session_id"])
            XCTAssertEqual(query["path"], "/tmp/workspace/Build/archive.zip")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/zip"]
            )
            return apiTestJSONResponse("""
            {"path":"/tmp/workspace/Build/archive.zip","data_url":"data:application/zip;base64,\(rawData.base64EncodedString())"}
            """, for: request)
        }
        let viewModel = try FilePreviewViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            path: "Build/archive.zip",
            apiClient: client
        )

        await viewModel.load()
        let payload = try await viewModel.exportPayload()

        if case .unavailable = viewModel.preview {
            XCTAssertTrue(true)
        } else {
            XCTFail("Zip files should keep the unsupported-preview state.")
        }
        XCTAssertEqual(payload.data, rawData)
        XCTAssertEqual(payload.filename, "archive.zip")
        XCTAssertEqual(payload.contentType, UTType.zip)
        XCTAssertFalse(payload.isImage)
        XCTAssertEqual(requestedPaths, ["/api/files/read"])
    }

    @MainActor
    func testFilePreviewLoadsPDFBytesFromRawEndpoint() async throws {
        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480)).pdfData { context in
            context.beginPage()
            "Semreh PDF preview".draw(at: CGPoint(x: 24, y: 24), withAttributes: nil)
        }
        let client = makeClient { request in
            if let fixture = try workspaceTraversalFixture(request) { return fixture }
            XCTAssertEqual(request.url?.path, "/api/files/read")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/pdf"]
            )
            return apiTestJSONResponse("""
            {"path":"/tmp/workspace/Docs/report.PDF","data_url":"data:application/pdf;base64,\(pdfData.base64EncodedString())"}
            """, for: request)
        }
        let viewModel = try FilePreviewViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            path: "Docs/report.PDF",
            apiClient: client
        )

        await viewModel.load()

        guard case let .pdf(previewDocument) = viewModel.preview else {
            return XCTFail("PDF files should load into the native PDF preview state.")
        }
        XCTAssertEqual(previewDocument.document.pageCount, 1)
        XCTAssertNil(viewModel.errorMessage)
        let exportPayload = try await viewModel.exportPayload()
        XCTAssertEqual(exportPayload.data, pdfData)
    }

    func testPDFPreviewDocumentRejectsZeroPageDocuments() {
        XCTAssertFalse(PDFPreviewDocument.isPreviewable(PDFDocument()))
    }

    @MainActor
    func testFilePreviewLoadsMarkdownFromTextEndpoint() async throws {
        let client = makeClient { request in
            if let fixture = try workspaceTraversalFixture(request) { return fixture }
            XCTAssertEqual(request.url?.path, "/api/files/read")
            return apiTestJSONResponse("""
            {
              "path": "/tmp/workspace/Docs/readme.md",
              "data_url": "data:text/markdown;base64,IyBIZWFkaW5nCgpSZWFkYWJsZSBwcm9zZS4=",
              "size": 28,
              "lines": 3
            }
            """, for: request)
        }
        let viewModel = try FilePreviewViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            path: "Docs/readme.md",
            apiClient: client
        )

        await viewModel.load()

        guard case let .markdown(file) = viewModel.preview else {
            return XCTFail("Markdown files should use the rendered document state.")
        }
        XCTAssertEqual(file.content, "# Heading\n\nReadable prose.")
        XCTAssertNil(viewModel.errorMessage)
    }
}

private final class CancellablePreviewURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var configuredContentLength = 0
    private static var stoppedHandler: (() -> Void)?

    static func configure(contentLength: Int, stopped: @escaping () -> Void) {
        lock.lock()
        configuredContentLength = contentLength
        stoppedHandler = stopped
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        configuredContentLength = 0
        stoppedHandler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let contentLength = Self.configuredContentLength
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/pdf",
                    "Content-Length": String(contentLength)
                ]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    override func stopLoading() {
        Self.lock.lock()
        let handler = Self.stoppedHandler
        Self.lock.unlock()
        handler?()
    }
}

/// Exact stock session/list fixtures shared by consumer tests; file routes
/// remain asserted by each test's own handler.
private func workspaceTraversalFixture(_ request: URLRequest) throws -> (HTTPURLResponse, Data)? {
    if request.url?.path == "/api/sessions/session-abc" {
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "profile", value: "default")])
        return apiTestJSONResponse(#"{"id":"session-abc","cwd":"/tmp/workspace","profile":"default"}"#, for: request)
    }
    guard request.url?.path == "/api/files" else { return nil }
    let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
    let entries: [[String: Any]]
    switch path {
    case "/tmp/workspace":
        entries = ["cat", "leetcode-editor", "Sources", "Build", "Docs"].map {
            ["name": $0, "path": "/tmp/workspace/" + $0, "is_directory": true]
        }
    case "/tmp/workspace/Sources":
        entries = [["name": "Notes.txt", "path": "/tmp/workspace/Sources/Notes.txt", "is_directory": false]]
    case "/tmp/workspace/Build":
        entries = [["name": "archive.zip", "path": "/tmp/workspace/Build/archive.zip", "is_directory": false]]
    case "/tmp/workspace/Docs":
        entries = ["report.PDF", "readme.md"].map {
            ["name": $0, "path": "/tmp/workspace/Docs/" + $0, "is_directory": false]
        }
    default: return nil
    }
    let data = try JSONSerialization.data(withJSONObject: ["path": path!, "entries": entries])
    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"])!, data)
}

private final class WorkspacePreviewReadGate: URLProtocol {
    private static let lock = NSLock()
    private static var pending: WorkspacePreviewReadGate?
    private static var first = true
    private static var holdDirectory = false
    private static var started: (() -> Void)?
    static func configure(holdDirectory: Bool = false, started: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        first = true
        self.holdDirectory = holdDirectory
        pending = nil
        self.started = started
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        pending = nil
        started = nil
    }
    static func completeOlder() {
        lock.lock()
        let pending = self.pending
        self.pending = nil
        lock.unlock()
        if let pending, pending.request.url?.path == "/api/files",
           let fixture = try? workspaceTraversalFixture(pending.request) {
            pending.deliver(fixture)
        } else {
            pending?.complete(text: "old")
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            if Self.holdDirectory && Self.first && request.url?.path == "/api/files" {
                Self.first = false
                Self.pending = self
                let started = Self.started
                Self.lock.unlock()
                started?()
                return
            }
            Self.lock.unlock()
            if let fixture = try workspaceTraversalFixture(request) {
                deliver(fixture)
                return
            }
            Self.lock.lock()
            if Self.first {
                Self.first = false
                Self.pending = self
                let started = Self.started
                Self.lock.unlock()
                started?()
            } else {
                Self.lock.unlock()
                complete(text: "new")
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    private func complete(text: String) {
        let encoded = Data(text.utf8).base64EncodedString()
        deliver(apiTestJSONResponse("""
        {"path":"/tmp/workspace/Sources/Notes.txt","data_url":"data:text/plain;base64,\(encoded)"}
        """, for: request))
    }
    private func deliver(_ response: (HTTPURLResponse, Data)) {
        client?.urlProtocol(self, didReceive: response.0, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }
}
