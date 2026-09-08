import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class SessionListMutationTests: XCTestCase {
    @MainActor
    func testExportCleansOwnedWrittenFileWhenCancelledOrProfileChangesDuringWrite() async throws {
        for cancel in [false, true] {
            let written = expectation(description: "owned file written")
            let gate = SessionExportWriterGate()
            let viewModel = try makeViewModel {
                apiTestJSONResponse(#"{"id":"export-row","messages":[]}"#, for: $0)
            }
            let task = Task { @MainActor in
                await viewModel.export(SessionSummary(sessionId: "export-row", title: "Fixture"), format: .json) { data, url in
                    try await SessionExportFile.write(data, to: url)
                    await gate.hold(url, written: written)
                }
            }
            await fulfillment(of: [written], timeout: 2)
            let writtenURL = await gate.url
            let url = try XCTUnwrap(writtenURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            if cancel { task.cancel() }
            else {
                let profile = try JSONDecoder().decode(ProfileSummary.self, from: Data(#"{"name":"other"}"#.utf8))
                let switched = await viewModel.switchActiveProfile(profile)
                XCTAssertTrue(switched)
            }
            await gate.release()
            let result = await task.value
            XCTAssertNil(result)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
            XCTAssertNil(viewModel.actionErrorMessage)
        }
    }

    @MainActor
    func testExportUsesRowsExplicitProfileAndPublishesCompleteJSONFile() async throws {
        let payload = #"{"id":"export-row","messages":[{"role":"tool","content":"fixture output"}],"fixture":true}"#
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/export-row/export")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "profile", value: "work")])
            return apiTestJSONResponse(payload, for: request)
        }
        let row = SessionSummary(sessionId: "export-row", title: "Export fixture", profile: "work")
        let result = await viewModel.export(row, format: .json)
        let url = try XCTUnwrap(result)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: url), Data(payload.utf8))
        XCTAssertEqual(url.lastPathComponent, "Export fixture.json")
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testExportDoesNotPublishAfterProfileSwitchOrCancellation() async throws {
        for cancel in [false, true] {
            let started = expectation(description: "export started")
            let release = DispatchSemaphore(value: 0)
            let viewModel = try makeViewModel { request in
                started.fulfill()
                release.wait()
                return apiTestJSONResponse(#"{"id":"export-row","messages":[]}"#, for: request)
            }
            let task = Task { @MainActor in
                await viewModel.export(SessionSummary(sessionId: "export-row", title: "Fixture"), format: .json)
            }
            await fulfillment(of: [started], timeout: 2)
            if cancel { task.cancel() }
            else {
                let profile = try JSONDecoder().decode(ProfileSummary.self, from: Data(#"{"name":"other"}"#.utf8))
                let switched = await viewModel.switchActiveProfile(profile)
                XCTAssertTrue(switched)
            }
            release.signal()
            let result = await task.value
            XCTAssertNil(result)
            XCTAssertNil(viewModel.actionErrorMessage)
        }
    }

    @MainActor
    func testStockProfileRefreshPreservesExplicitLocalSelectionAndRefreshesMetadata() async throws {
        var readCount = 0
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/profiles")
            XCTAssertEqual(request.httpMethod, "GET")
            readCount += 1
            return apiTestJSONResponse("""
            {"profiles":[{"name":"default","is_default":true},
                         {"name":"work","is_default":false,"model":"fixture-\(readCount)","provider":"custom"}]}
            """, for: request)
        }
        await viewModel.loadActiveProfile()
        let work = try XCTUnwrap(viewModel.profileOptions.first { $0.name == "work" })
        let switched = await viewModel.switchActiveProfile(work)
        XCTAssertTrue(switched)
        await viewModel.loadActiveProfile()
        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(viewModel.activeProfileName, "work")
        XCTAssertEqual(viewModel.activeProfileModel, "fixture-2")
        XCTAssertEqual(viewModel.activeProfileProvider, "custom")
        XCTAssertNil(viewModel.activeProfileErrorMessage)
    }

    @MainActor
    func testStockProfileMissingSelectionDoesNotSilentlyRetargetLocalConversation() async throws {
        var reads = 0
        let viewModel = try makeViewModel { request in
            reads += 1
            return apiTestJSONResponse(reads == 1
                ? "{\"profiles\":[{\"name\":\"default\",\"is_default\":true},{\"name\":\"work\"}]}"
                : "{\"profiles\":[{\"name\":\"default\",\"is_default\":true}]}", for: request)
        }
        await viewModel.loadActiveProfile()
        let work = try XCTUnwrap(viewModel.profileOptions.first { $0.name == "work" })
        let switched = await viewModel.switchActiveProfile(work)
        XCTAssertTrue(switched)
        await viewModel.loadActiveProfile()
        XCTAssertEqual(viewModel.activeProfileName, "work")
        XCTAssertEqual(viewModel.profileOptions.count, 1)
        XCTAssertNil(viewModel.activeProfileModel)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        OverlappingDeleteURLProtocol.reset()
        ArchivedCountGateURLProtocol.reset()
        MetadataOverlayURLProtocol.reset()
        super.tearDown()
    }

    func testScheduledSessionGroupsPartitionOneCandidateCollection() throws {
        let ordinary = SessionSummary(sessionId: "ordinary", title: "Ordinary")
        let scheduled = SessionSummary(sessionId: "cron_scheduled", title: "Scheduled")
        let archivedScheduled = SessionSummary(
            sessionId: "cron_archived",
            title: "Archived scheduled",
            archived: true
        )

        let groups = ScheduledSessionGroups.partition(
            [ordinary, scheduled, archivedScheduled],
            totalScheduledCount: 2
        )

        XCTAssertEqual(groups.ordinary.map(\.sessionId), ["ordinary"])
        XCTAssertEqual(groups.scheduled.map(\.sessionId), ["cron_scheduled"])
        XCTAssertEqual(groups.totalScheduledCount, 2)
    }

    @MainActor
    func testLoadFallsBackToCachedSessionsForNetworkTimeout() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let organizer = LocalOrganizerStore(defaults: UserDefaults(suiteName: "SessionListMutationTests.cacheGroups.\(UUID().uuidString)")!)
        let group = try organizer.createGroup(name: "One", color: nil, server: serverURL, profile: "default")
        let groupID = try XCTUnwrap(group.projectId)
        try organizer.assignSession("cached-project-one", toGroup: groupID, server: serverURL, profile: "default")
        try organizer.assignSession("cached-subagent", toGroup: groupID, server: serverURL, profile: "default")
        let otherServerURL = try XCTUnwrap(URL(string: "https://other.example.test"))
        try CacheStore.cacheSessions(
            [
                SessionSummary(
                    sessionId: "cached-project-one",
                    title: "Cached project one",
                    archived: false,
                    projectId: "project-1",
                    profile: "default"
                ),
                SessionSummary(
                    sessionId: "cached-project-two",
                    title: "Cached project two",
                    archived: false,
                    projectId: "project-2",
                    profile: "default"
                ),
                SessionSummary(
                    sessionId: "cached-subagent",
                    title: "Cached delegated work",
                    archived: false,
                    projectId: "project-1",
                    profile: "default",
                    sourceTag: "subagent",
                    readOnly: true
                )
            ],
            serverURL: serverURL,
            in: context
        )
        try CacheStore.cacheSessions(
            [
                SessionSummary(sessionId: "other-server", title: "Other server", archived: false)
            ],
            serverURL: otherServerURL,
            in: context
        )
        let viewModel = try makeViewModel(organizerStore: organizer) { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            throw URLError(.timedOut)
        }

        await viewModel.load(modelContext: context)

        XCTAssertEqual(
            Set(viewModel.sessions.compactMap(\.sessionId)),
            Set(["cached-project-one", "cached-project-two", "cached-subagent"])
        )
        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: groupID,
                automatedVisibility: AutomatedSessionVisibility(showsCron: true, showsCli: true)
            ).compactMap(\.sessionId),
            ["cached-project-one"]
        )
        XCTAssertEqual(
            Set(viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: groupID,
                automatedVisibility: .showAll
            ).compactMap(\.sessionId)),
            Set(["cached-project-one", "cached-subagent"])
        )
        XCTAssertTrue(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testLoadSurfacesNetworkTimeoutWhenCacheIsEmpty() async throws {
        let context = try makeContext()
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            throw URLError(.timedOut)
        }

        await viewModel.load(modelContext: context)

        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(
            viewModel.errorMessage,
            "The server did not respond in time. Check that the Mac is awake, hermes-webui is running, and the tunnel is connected."
        )
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testSessionLoadErrorStaysScopedWhenRemoteSearchFails() async throws {
        let context = try makeContext()
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                throw URLError(.timedOut)
            case "/api/sessions/search":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"boom"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load(modelContext: context)
        let sessionLoadError = try XCTUnwrap(viewModel.sessionLoadError)
        XCTAssertTrue(CacheFallbackPolicy.shouldUseCache(for: sessionLoadError))
        XCTAssertEqual(
            viewModel.errorMessage,
            "The server did not respond in time. Check that the Mac is awake, hermes-webui is running, and the tunnel is connected."
        )

        await viewModel.searchSessions(query: "later", debounceNanoseconds: 0)

        XCTAssertFalse(CacheFallbackPolicy.shouldUseCache(for: try XCTUnwrap(viewModel.lastError)))
        XCTAssertTrue(CacheFallbackPolicy.shouldUseCache(for: try XCTUnwrap(viewModel.sessionLoadError)))
        XCTAssertEqual(
            viewModel.errorMessage,
            "The server did not respond in time. Check that the Mac is awake, hermes-webui is running, and the tunnel is connected."
        )
    }

    @MainActor
    func testNewestOverlappingSessionLoadWinsWhenOlderRequestFinishesLast() async throws {
        OutOfOrderSessionURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OutOfOrderSessionURLProtocol.self]
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
            let viewModel = SessionListViewModel(server: server, client: client)

        let firstLoad = Task { await viewModel.load() }
        try await Task.sleep(nanoseconds: 20_000_000)
        let secondResult = await viewModel.load()
        _ = await firstLoad.value

        XCTAssertTrue(secondResult)
        XCTAssertEqual(viewModel.sessions.map(\.sessionId), ["new"])
        XCTAssertEqual(viewModel.sessions.map(\.title), ["Fresh result"])
        XCTAssertEqual(OutOfOrderSessionURLProtocol.requestCount, 2)
    }

    @MainActor
    func testLoadPaintsCachedSessionsBeforeSlowNetworkReconcile() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheSessions(
            [SessionSummary(sessionId: "cached-session", title: "Cached immediately", archived: false)],
            serverURL: serverURL,
            in: context
        )

        let requestStarted = expectation(description: "session request started")
        let allowResponse = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            requestStarted.fulfill()
            allowResponse.wait()
            return apiTestJSONResponse(
                #"{"sessions":[{"id":"fresh-session","title":"Fresh response","archived":false}]}"#,
                for: request
            )
        }

        let loadTask = Task { @MainActor in
            await viewModel.load(modelContext: context)
        }
        await fulfillment(of: [requestStarted], timeout: 2)

        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["cached-session"])
        XCTAssertFalse(viewModel.isViewingCachedData)

        allowResponse.signal()
        let loaded = await loadTask.value
        XCTAssertTrue(loaded)
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["fresh-session"])
        XCTAssertFalse(viewModel.isViewingCachedData)
    }

    @MainActor
    func testLoadDoesNotReplaceSuccessfulOnlineSessionsWithStaleCache() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheSessions(
            [
                SessionSummary(sessionId: "stale-session", title: "Stale planning", archived: false)
            ],
            serverURL: serverURL,
            in: context
        )
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "id": "fresh-session",
                  "title": "Fresh planning",
                  "archived": false,
                  "project_id": "project-1",
                  "profile": "work"
                }
              ]
            }
            """, for: request)
        }

        await viewModel.load(modelContext: context)

        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["fresh-session"])
        XCTAssertNil(viewModel.sessions.first?.projectId)
        XCTAssertEqual(viewModel.sessions.first?.profile, "work")
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            try CacheStore.cachedSessions(serverURL: serverURL, in: context).compactMap(\.sessionId),
            ["fresh-session"]
        )
    }

    @MainActor
    func testLoadFiltersEmptyUntitledPlaceholdersButKeepsRealUntitledRows() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "id": "empty-placeholder",
                  "title": "Untitled Session",
                  "message_count": 0,
                  "archived": false
                },
                {
                  "id": "empty-placeholder-missing-count",
                  "title": "Untitled Session",
                  "archived": false
                },
                {
                  "id": "contentful-untitled",
                  "title": "Untitled Session",
                  "message_count": 2,
                  "archived": false
                },
                {
                  "id": "recent-untitled",
                  "title": "Untitled",
                  "message_count": 0,
                  "last_message_at": 1770000000,
                  "archived": false
                },
                {
                  "id": "streaming-untitled",
                  "title": "Untitled",
                  "message_count": 0,
                  "active_stream_id": "stream-123",
                  "archived": false
                },
                {
                  "id": "pending-untitled",
                  "title": "Untitled",
                  "message_count": 0,
                  "has_pending_user_message": true,
                  "archived": false
                },
                {
                  "id": "worktree-untitled",
                  "title": "Untitled",
                  "message_count": 0,
                  "worktree_path": "/tmp/hermes-worktree",
                  "archived": false
                },
                {
                  "id": "named-empty",
                  "title": "Planning",
                  "message_count": 0,
                  "archived": false
                }
              ]
            }
            """, for: request)
        }

        await viewModel.load(modelContext: context)

        let expectedIDs = [
            "contentful-untitled",
            "named-empty"
        ]
        let loadedIDs = viewModel.sessions.compactMap(\.sessionId)
        XCTAssertEqual(Set(loadedIDs), Set(expectedIDs))
        XCTAssertEqual(loadedIDs.count, expectedIDs.count)

        let cachedIDs = try CacheStore.cachedSessions(serverURL: serverURL, in: context).compactMap(\.sessionId)
        XCTAssertEqual(Set(cachedIDs), Set(expectedIDs))
        XCTAssertEqual(cachedIDs.count, expectedIDs.count)
    }

    @MainActor
    func testLoadDoesNotUseCachedSessionsForRealServerError() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheSessions(
            [
                SessionSummary(sessionId: "cached-session", title: "Cached planning", archived: false)
            ],
            serverURL: serverURL,
            in: context
        )
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"boom"}"#.utf8))
        }

        await viewModel.load(modelContext: context)

        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(viewModel.errorMessage, "Hermes returned HTTP 500.")
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testInitialCachePrepaintIsClearedForRealServerError() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheSessions(
            [SessionSummary(sessionId: "cached-session", title: "Cached planning", archived: false)],
            serverURL: serverURL,
            in: context
        )
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"boom"}"#.utf8))
        }

        viewModel.prepareInitialCachedSessions(modelContext: context)
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["cached-session"])

        await viewModel.load(modelContext: context)

        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(viewModel.errorMessage, "Hermes returned HTTP 500.")
    }

    @MainActor
    func testCreateSessionReturnsEmptyPlaceholderWithoutInsertingIntoSessionList() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = try makeViewModel { request in
            XCTFail("New Chat must not issue a request: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }

        let created = await viewModel.createSession(modelContext: context)

        XCTAssertNil(created?.sessionId)
        XCTAssertEqual(created?.title, "New Chat")
        XCTAssertEqual(created?.profile, "default")
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertTrue(try CacheStore.cachedSessions(serverURL: serverURL, in: context).isEmpty)
        XCTAssertFalse(viewModel.isCreatingSession)
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testCreateSessionKeepsWorktreeBackedUntitledSessionWithoutCounts() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = try makeViewModel { request in
            XCTFail("New Chat must not issue a request: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }

        let created = await viewModel.createSession(modelContext: context)

        XCTAssertNil(created?.sessionId)
        XCTAssertEqual(created?.title, "New Chat")
        XCTAssertEqual(created?.profile, "default")
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertTrue(try CacheStore.cachedSessions(serverURL: serverURL, in: context).isEmpty)
    }

    @MainActor
    func testLoadActiveProfileUsesProfilesEndpointAndStoresCurrentProfile() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            requestedPaths.append(request.url?.path ?? "nil")

            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "profiles": [
                    {
                      "name": "default",
                      "is_default": true,
                      "model": "gpt-5"
                    },
                    {
                      "name": "work",
                      "is_active": true,
                      "model": "claude-sonnet-4-5",
                      "provider": "anthropic"
                    }
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadActiveProfile()

        XCTAssertEqual(requestedPaths, ["/api/profiles"])
        XCTAssertEqual(viewModel.activeProfileName, "work")
        XCTAssertEqual(viewModel.activeProfileDisplayName, "work")
        XCTAssertEqual(viewModel.activeProfileModel, "claude-sonnet-4-5")
        XCTAssertEqual(viewModel.activeProfileProvider, "anthropic")
        XCTAssertEqual(viewModel.profileOptions.compactMap(\.normalizedName), ["default", "work"])
        XCTAssertFalse(viewModel.isSingleProfileMode)
        XCTAssertFalse(viewModel.isLoadingActiveProfile)
        XCTAssertNil(viewModel.activeProfileErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testLoadActiveProfileStoresSingleProfileMode() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    { "name": "default", "is_default": true, "is_active": true }
                  ],
                  "single_profile_mode": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadActiveProfile()

        XCTAssertTrue(viewModel.isSingleProfileMode)
        XCTAssertEqual(viewModel.activeProfileName, "default")
    }

    @MainActor
    func testLoadActiveProfileCanRefreshChangedProfile() async throws {
        var profileLoadCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles":
                profileLoadCount += 1

                if profileLoadCount == 1 {
                    return apiTestJSONResponse("""
                    {
                      "active": "default",
                      "profiles": [
                        {"name": "default", "is_active": true, "model": "gpt-5", "provider": "openai"},
                        {"name": "work", "model": "claude-sonnet-4-5", "provider": "anthropic"}
                      ]
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "profiles": [
                    {"name": "default", "model": "gpt-5", "provider": "openai"},
                    {"name": "work", "is_active": true, "model": "claude-sonnet-4-5", "provider": "anthropic"}
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadActiveProfile()
        XCTAssertEqual(viewModel.activeProfileDisplayName, "Default")
        XCTAssertEqual(viewModel.activeProfileModel, "gpt-5")

        await viewModel.loadActiveProfile()
        XCTAssertEqual(profileLoadCount, 2)
        XCTAssertEqual(viewModel.activeProfileName, "work")
        XCTAssertEqual(viewModel.activeProfileDisplayName, "work")
        XCTAssertEqual(viewModel.activeProfileModel, "claude-sonnet-4-5")
        XCTAssertEqual(viewModel.activeProfileProvider, "anthropic")
        XCTAssertNil(viewModel.activeProfileErrorMessage)
    }

    @MainActor
    func testSwitchActiveProfileCallsServerAndUpdatesPickerState() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            let path = request.url?.path ?? "nil"
            requestedPaths.append(path)

            switch path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    {"name": "default", "is_active": true, "model": "gpt-5", "provider": "openai"},
                    {"name": "work", "model": "claude-sonnet-4-5", "provider": "anthropic"}
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(path)")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadActiveProfile()
        let workProfile = try XCTUnwrap(viewModel.profileOptions.first { $0.normalizedName == "work" })
        let didSwitch = await viewModel.switchActiveProfile(workProfile)

        XCTAssertTrue(didSwitch)
        XCTAssertEqual(requestedPaths, ["/api/profiles"])
        XCTAssertEqual(viewModel.activeProfileName, "work")
        XCTAssertEqual(viewModel.activeProfileDisplayName, "work")
        XCTAssertEqual(viewModel.activeProfileModel, "claude-sonnet-4-5")
        XCTAssertEqual(viewModel.activeProfileProvider, "anthropic")
        XCTAssertFalse(viewModel.isSwitchingActiveProfile)
        XCTAssertNil(viewModel.switchingActiveProfileName)
        XCTAssertNil(viewModel.activeProfileErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testSwitchActiveProfileUpdatesLocalProfileWithoutServerMutation() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    {"name": "default", "is_active": true, "model": "gpt-5", "provider": "openai"},
                    {"name": "work", "model": "claude-sonnet-4-5", "provider": "anthropic"}
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadActiveProfile()
        let workProfile = try XCTUnwrap(viewModel.profileOptions.first { $0.normalizedName == "work" })
        let didSwitch = await viewModel.switchActiveProfile(workProfile)

        XCTAssertTrue(didSwitch)
        XCTAssertEqual(viewModel.activeProfileName, "work")
        XCTAssertEqual(viewModel.activeProfileDisplayName, "work")
        XCTAssertEqual(viewModel.activeProfileModel, "claude-sonnet-4-5")
        XCTAssertFalse(viewModel.isSwitchingActiveProfile)
        XCTAssertNil(viewModel.switchingActiveProfileName)
        XCTAssertNil(viewModel.activeProfileErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testLoadActiveProfileFailureDoesNotOverwriteSessionListState() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/profiles":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"profile failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        await viewModel.loadActiveProfile()

        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["session-abc"])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isLoadingActiveProfile)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.activeProfileErrorMessage)
        XCTAssertNil(viewModel.activeProfileName)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testActiveMonitorFallbackReloadsThroughScopedDirectListWithoutStreamStatus() async throws {
        var paths: [String] = []
        let viewModel = try makeViewModel { request in
            paths.append(request.url?.path ?? "")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "profile" }?.value, "default")
            return apiTestJSONResponse(#"{"sessions":[{"id":"session-streaming","title":"Updated direct row","archived":false}]}"#, for: request)
        }
        let result = await viewModel.refreshActiveSessionStatesIfNeeded()
        XCTAssertEqual(result, .reloaded)
        XCTAssertEqual(paths, ["/api/profiles/sessions"])
        XCTAssertEqual(viewModel.sessions.first?.title, "Updated direct row")
    }

    @MainActor
    func testActiveMonitorDefersWhileSidebarEditingOrDestructiveActionPending() async throws {
        let viewModel = try makeViewModel { _ in
            XCTFail("Blocked monitor must not issue a list or stream-status request")
            throw URLError(.badURL)
        }
        viewModel.setSidebarEditing(true)
        let editing = await viewModel.refreshActiveSessionStatesIfNeeded()
        XCTAssertEqual(editing, .unchanged)
        viewModel.setSidebarEditing(false)
        viewModel.setSidebarDestructiveActionPending(true)
        let pending = await viewModel.refreshActiveSessionStatesIfNeeded()
        XCTAssertEqual(pending, .unchanged)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testActiveMonitorDirectUnauthorizedIsPreservedForAuthHandling() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            // Stock dashboard_auth/middleware.py uses this structured code;
            // a generic unauthorized response must not imply cookie expiry.
            return (response, Data(#"{"error":"unauthenticated"}"#.utf8))
        }
        let result = await viewModel.refreshActiveSessionStatesIfNeeded()
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(viewModel.lastError as? DirectHermesAuthError, .sessionExpired)
    }

    @MainActor
    func testCancelledActiveMonitorMakesNoRequest() async throws {
        let viewModel = try makeViewModel { _ in
            XCTFail("Cancelled monitor must not issue a request")
            throw URLError(.badURL)
        }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await viewModel.refreshActiveSessionStatesIfNeeded()
        }
        let result = await task.value
        XCTAssertEqual(result, .unchanged)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testActiveMonitorGenericUnauthorizedDoesNotClaimSessionExpiry() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            return (response, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        let result = await viewModel.refreshActiveSessionStatesIfNeeded()
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(viewModel.lastError as? DirectHermesRequestError,
            .http(statusCode: 401, reason: .unauthorized))
        XCTAssertNil(viewModel.lastError as? DirectHermesAuthError)
    }

    @MainActor
    func testDeleteRemovesRowBeforeServerAcknowledgementAndKeepsItGoneAfterSuccess() async throws {
        let mutationStarted = expectation(description: "delete request started")
        let releaseMutation = DispatchSemaphore(value: 0)
        var sessionLoadCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                sessionLoadCount += 1
                let body = sessionLoadCount == 1
                    ? #"{"sessions":[{"id":"delete-me","title":"Delete me","archived":false},{"id":"keep-me","title":"Keep me","archived":false}]}"#
                    : #"{"sessions":[{"id":"keep-me","title":"Keep me","archived":false}]}"#
                return apiTestJSONResponse(body, for: request)
            case "/api/session/delete":
                mutationStarted.fulfill()
                releaseMutation.wait()
                return apiTestJSONResponse(#"{"ok":true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first(where: { $0.sessionId == "delete-me" }))
        let deleteTask = Task { @MainActor in
            await viewModel.delete(session)
        }
        await fulfillment(of: [mutationStarted], timeout: 2)

        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["keep-me"])
        XCTAssertTrue(viewModel.isMutating(session))

        releaseMutation.signal()
        let didDelete = await deleteTask.value
        XCTAssertTrue(didDelete)
        XCTAssertFalse(viewModel.isMutating(session))
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["keep-me"])
    }

    @MainActor
    func testDeleteFailureRestoresTheExactRowAndOrder() async throws {
        var sessionLoadCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                sessionLoadCount += 1
                XCTAssertEqual(sessionLoadCount, 1)
                return apiTestJSONResponse(#"{"sessions":[{"id":"first","title":"First","archived":false},{"id":"delete-me","title":"Delete me","archived":false},{"id":"last","title":"Last","archived":false}]}"#, for: request)
            case "/api/session/delete":
                return apiTestJSONResponse(#"{"ok":false,"error":"delete refused"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let session = try XCTUnwrap(viewModel.sessions.first(where: { $0.sessionId == "delete-me" }))
        let didDelete = await viewModel.delete(session)

        XCTAssertFalse(didDelete)
        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertEqual(viewModel.actionErrorMessage, "delete refused")
        XCTAssertFalse(viewModel.isMutating(session))
    }

    @MainActor
    func testDeleteFailureAfterOverlappingCanonicalRefreshRestoresLatestCanonicalRow() async throws {
        let mutationStarted = expectation(description: "delete request started")
        let overlappingLoadStarted = expectation(description: "overlapping canonical load started")
        OverlappingDeleteURLProtocol.configure(
            onMutationStarted: { mutationStarted.fulfill() },
            onOverlappingLoadStarted: { overlappingLoadStarted.fulfill() }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OverlappingDeleteURLProtocol.self]
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let viewModel = SessionListViewModel(server: server, client: client)

        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first(where: { $0.sessionId == "delete-me" }))
        let deleteTask = Task { @MainActor in await viewModel.delete(session) }
        await fulfillment(of: [mutationStarted], timeout: 2)

        let overlappingLoadTask = Task { @MainActor in await viewModel.load() }
        await fulfillment(of: [overlappingLoadStarted], timeout: 2)
        XCTAssertNil(viewModel.sessions.first(where: { $0.sessionId == "delete-me" }))
        let overlappingLoadSucceeded = await overlappingLoadTask.value
        XCTAssertTrue(overlappingLoadSucceeded)

        let deleteSucceeded = await deleteTask.value
        XCTAssertFalse(deleteSucceeded)
        XCTAssertEqual(
            viewModel.sessions.first(where: { $0.sessionId == "delete-me" })?.title,
            "Canonical latest"
        )
    }

    @MainActor
    func testPinArchiveUseDirectReadbackWhileLocalMoveAvoidsLegacyRoute() async throws {
        var loadCount = 0
        var mutationPaths: [String] = []
        var detailCount = 0
        let organizer = LocalOrganizerStore(defaults: UserDefaults(suiteName: "SessionListMutationTests.pinArchive.\(UUID().uuidString)")!)
        let project = try organizer.createGroup(name: "Local", color: nil, server: URL(string: "https://example.test")!, profile: "default")
        let viewModel = try makeViewModel(organizerStore: organizer) { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                loadCount += 1
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: loadCount), for: request)
            case "/api/sessions/session-abc":
                if request.httpMethod == "PATCH" {
                    let body = try XCTUnwrap(apiTestJSONBody(from: request))
                    XCTAssertEqual(body["profile"] as? String, "default")
                    mutationPaths.append("PATCH /api/sessions/session-abc")
                    if body["pinned"] != nil {
                        XCTAssertEqual(body["pinned"] as? Bool, true)
                    } else {
                        XCTAssertEqual(body["archived"] as? Bool, true)
                    }
                    return apiTestJSONResponse(
                        body["pinned"] != nil
                            ? #"{"ok":true,"pinned":true}"#
                            : #"{"ok":true,"archived":true}"#,
                        for: request
                    )
                }
                detailCount += 1
                mutationPaths.append("GET /api/sessions/session-abc")
                return apiTestJSONResponse(
                    detailCount == 1
                        ? #"{"id":"session-abc","title":"Planning","profile":"default","pinned":1,"archived":0}"#
                        : #"{"id":"session-abc","title":"Planning","profile":"default","pinned":1,"archived":1}"#,
                    for: request
                )
            case "/api/session/delete":
                mutationPaths.append("/api/session/delete")
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first)

        let didPin = await viewModel.setPinned(true, for: session)
        XCTAssertTrue(didPin)
        XCTAssertEqual(viewModel.sessions.first?.pinned, true)

        let didArchive = await viewModel.archive(session)
        XCTAssertTrue(didArchive)
        XCTAssertTrue(viewModel.sessions.isEmpty)

        await viewModel.move(session, to: project.projectId)
        XCTAssertEqual(try organizer.groupID(forSession: "session-abc", server: URL(string: "https://example.test")!, profile: "default"), project.projectId)

        let didDelete = await viewModel.delete(session)
        XCTAssertTrue(didDelete)
        XCTAssertTrue(viewModel.sessions.isEmpty)

        XCTAssertEqual(loadCount, 2, "Local assignment does not reload the server session list")
        XCTAssertEqual(
            mutationPaths,
            [
                "PATCH /api/sessions/session-abc",
                "GET /api/sessions/session-abc",
                "PATCH /api/sessions/session-abc",
                "GET /api/sessions/session-abc",
                "/api/session/delete"
            ]
        )
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testSessionMutatorDuplicateBranchesThenLoadsReturnedSession() async throws {
        var requestedPaths: [String] = []
        let transport = SessionDuplicateTransport()
        let runtime = try HermesServerRuntime(origin: URL(string: "https://example.test")!) { sink in
            transport.installSink(sink)
            return transport
        }
        let client = try makeClient { request in
            let path = request.url?.path ?? "nil"
            requestedPaths.append(path)

            switch path {
            case "/api/sessions/session-abc/messages":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","messages":[],"pagination":{"returned":0}}"#,
                    for: request
                )
            case "/api/sessions/copy-123/messages":
                return apiTestJSONResponse(
                    #"{"session_id":"copy-123","messages":[],"pagination":{"returned":0}}"#,
                    for: request
                )
            case "/api/sessions/copy-123":
                return apiTestJSONResponse(
                    #"{"id":"copy-123","profile":"work","title":"Planning (copy)","archived":0}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(path)")
                throw URLError(.badURL)
            }
        }

        let result = try await SessionMutator(client: client).duplicate(
            sessionID: "session-abc",
            title: "Planning (copy)",
            profile: "work",
            runtime: runtime
        )

        XCTAssertEqual(requestedPaths, [
            "/api/sessions/session-abc/messages",
            "/api/sessions/copy-123/messages",
            "/api/sessions/copy-123"
        ])
        XCTAssertEqual(transport.methods(), ["session.resume", "session.branch"])
        XCTAssertEqual(transport.branchFields()["name"], .string("Planning (copy)"))
        XCTAssertEqual(transport.branchFields()["profile"], .string("work"))
        XCTAssertEqual(result.session?.sessionId, "copy-123")
        XCTAssertEqual(result.session?.title, "Planning (copy)")
        XCTAssertEqual(result.createdSessionID, "copy-123")
        XCTAssertNil(result.errorMessage)
        await runtime.stop()
    }

    @MainActor
    func testConcurrentSessionMutationsAreIgnoredWhileSameSessionIsInFlight() async throws {
        let firstPinRequestStarted = expectation(description: "first pin request started")
        let requestCounts = LockedSessionMutationRequestCounts()
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                let currentLoadCount = requestCounts.incrementLoadCount()
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: currentLoadCount), for: request)
            case "/api/sessions/session-abc":
                if request.httpMethod == "PATCH" {
                    let body = try XCTUnwrap(apiTestJSONBody(from: request))
                    XCTAssertEqual(body["profile"] as? String, "default")
                    XCTAssertEqual(body["pinned"] as? Bool, true)

                    let currentPinRequestCount = requestCounts.incrementPinRequestCount()

                    if currentPinRequestCount == 1 {
                        firstPinRequestStarted.fulfill()
                        Thread.sleep(forTimeInterval: 0.2)
                    }

                    return apiTestJSONResponse(#"{"ok": true, "pinned": true}"#, for: request)
                }
                return apiTestJSONResponse(
                    #"{"id":"session-abc","title":"Planning","profile":"default","pinned":1,"archived":0}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first)

        let firstMutation = Task { @MainActor in
            await viewModel.setPinned(true, for: session)
        }
        await fulfillment(of: [firstPinRequestStarted], timeout: 1)
        XCTAssertTrue(viewModel.isMutating(session))

        let duplicatePinMutation = Task { @MainActor in
            await viewModel.setPinned(false, for: session)
        }
        let duplicateMutation = Task { @MainActor in
            await viewModel.duplicate(session)
        }
        let moveMutation = Task { @MainActor in
            await viewModel.move(session, to: "project-1")
        }

        let didSkipDuplicatePin = await duplicatePinMutation.value
        _ = await duplicateMutation.value
        await moveMutation.value
        let didPin = await firstMutation.value

        let finalCounts = requestCounts.snapshot

        XCTAssertTrue(didPin)
        XCTAssertFalse(didSkipDuplicatePin)
        XCTAssertEqual(finalCounts.pinRequestCount, 1)
        XCTAssertEqual(finalCounts.loadCount, 1)
        XCTAssertFalse(viewModel.isMutating(session))
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testDirectMetadataMutationIsDiscardedAfterProfileSwitch() async throws {
        let patchStarted = expectation(description: "direct metadata patch started")
        let releasePatch = DispatchSemaphore(value: 0)
        let client = try makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(
                    #"{"profiles":[{"name":"default","is_default":true},{"name":"work"}],"active":"default","single_profile_mode":false}"#,
                    for: request
                )
            case "/api/profiles/sessions":
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","pinned":false,"archived":false}]}"#,
                    for: request
                )
            case "/api/sessions":
                let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["profile"], "default")
                XCTAssertEqual(query["limit"], "0")
                XCTAssertEqual(query["offset"], "0")
                XCTAssertEqual(query["archived"], "only")
                return apiTestJSONResponse(#"{"sessions":[],"total":0,"limit":0,"offset":0}"#, for: request)
            case "/api/sessions/session-abc":
                if request.httpMethod == "PATCH" {
                    patchStarted.fulfill()
                    _ = releasePatch.wait(timeout: .now() + 2)
                    return apiTestJSONResponse(#"{"ok":true,"pinned":true}"#, for: request)
                }
                return apiTestJSONResponse(
                    #"{"id":"session-abc","title":"Planning","profile":"default","pinned":1,"archived":0}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)
        await viewModel.loadActiveProfile()
        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)
        let session = try XCTUnwrap(viewModel.sessions.first)

        let mutation = Task { @MainActor in
            await viewModel.setPinned(true, for: session)
        }
        await fulfillment(of: [patchStarted], timeout: 1)
        let work = try XCTUnwrap(viewModel.profileOptions.first(where: { $0.name == "work" }))
        let switched = await viewModel.switchActiveProfile(work)
        XCTAssertTrue(switched)
        let `default` = try XCTUnwrap(viewModel.profileOptions.first(where: { $0.name == "default" }))
        let switchedBack = await viewModel.switchActiveProfile(`default`)
        XCTAssertTrue(switchedBack)
        releasePatch.signal()

        let mutationSucceeded = await mutation.value
        XCTAssertFalse(mutationSucceeded)
        XCTAssertEqual(viewModel.sessions.first?.pinned, false)
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testDirectMetadataFailureAfterProfileSwitchDoesNotPublishStaleError() async throws {
        let patchStarted = expectation(description: "direct metadata patch started")
        let releasePatch = DispatchSemaphore(value: 0)
        let client = try makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(
                    #"{"profiles":[{"name":"default","is_default":true},{"name":"work"}],"active":"default","single_profile_mode":false}"#,
                    for: request
                )
            case "/api/profiles/sessions":
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","pinned":false,"archived":false}]}"#,
                    for: request
                )
            case "/api/sessions":
                let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["profile"], "default")
                XCTAssertEqual(query["limit"], "0")
                XCTAssertEqual(query["offset"], "0")
                XCTAssertEqual(query["archived"], "only")
                return apiTestJSONResponse(#"{"sessions":[],"total":0,"limit":0,"offset":0}"#, for: request)
            case "/api/sessions/session-abc":
                patchStarted.fulfill()
                _ = releasePatch.wait(timeout: .now() + 2)
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 500,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                )
                return (response, Data(#"{"error":"old profile write failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)
        await viewModel.loadActiveProfile()
        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)
        let session = try XCTUnwrap(viewModel.sessions.first)

        let mutation = Task { @MainActor in
            await viewModel.setPinned(true, for: session)
        }
        await fulfillment(of: [patchStarted], timeout: 1)
        let work = try XCTUnwrap(viewModel.profileOptions.first(where: { $0.name == "work" }))
        let switched = await viewModel.switchActiveProfile(work)
        XCTAssertTrue(switched)
        releasePatch.signal()

        let mutationSucceeded = await mutation.value
        XCTAssertFalse(mutationSucceeded)
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testRenameSessionUpdatesLocalRowAndCachedSession() async throws {
        var requestedPaths: [String] = []
        let context = try makeContext()
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = try makeViewModel { request in
            let path = request.url?.path ?? "nil"
            requestedPaths.append(path)

            switch path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/sessions/session-abc":
                if request.httpMethod == "GET" {
                    return apiTestJSONResponse(
                        #"{"id":"session-abc","title":"Launch Notes","profile":"default","archived":0}"#,
                        for: request
                    )
                }
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["profile"] as? String, "default")
                XCTAssertEqual(body["title"] as? String, "Launch Notes")
                return apiTestJSONResponse(#"{"ok":true,"title":"Launch Notes"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(path)")
                throw URLError(.badURL)
            }
        }

        await viewModel.load(modelContext: context)
        let session = try XCTUnwrap(viewModel.sessions.first)
        let didRename = await viewModel.rename(session, to: "  Launch Notes  ", modelContext: context)
        let cachedSessions = try CacheStore.cachedSessions(serverURL: server, in: context)

        XCTAssertTrue(didRename)
        XCTAssertEqual(
            requestedPaths,
            ["/api/profiles/sessions", "/api/sessions/session-abc", "/api/sessions/session-abc"]
        )
        XCTAssertEqual(viewModel.sessions.first?.title, "Launch Notes")
        XCTAssertEqual(viewModel.sessions.first?.workspace, session.workspace)
        XCTAssertEqual(cachedSessions.first?.title, "Launch Notes")
        XCTAssertFalse(viewModel.isRenamingSession)
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testRenameSessionBlocksBlankTitleBeforeNetworkRequest() async throws {
        let viewModel = try makeViewModel { request in
            XCTFail("Blank session titles should not make network requests: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let session = try makeSessionSummary(
            id: "session-abc",
            title: "Planning",
            pinned: false,
            archived: false
        )

        let didRename = await viewModel.rename(session, to: "   ")

        XCTAssertFalse(didRename)
        XCTAssertEqual(viewModel.actionErrorMessage, "Enter a session title.")
        XCTAssertNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isRenamingSession)
    }

    @MainActor
    func testRenameSessionFailureKeepsOldTitleAndShowsActionError() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            let path = request.url?.path ?? "nil"
            requestedPaths.append(path)

            switch path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/sessions/session-abc":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"rename failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(path)")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let beforeSessions = viewModel.sessions
        let session = try XCTUnwrap(beforeSessions.first)
        let didRename = await viewModel.rename(session, to: "Launch Notes")

        XCTAssertFalse(didRename)
        XCTAssertEqual(requestedPaths, ["/api/profiles/sessions", "/api/sessions/session-abc"])
        XCTAssertEqual(viewModel.sessions, beforeSessions)
        XCTAssertEqual(viewModel.sessions.first?.title, "Planning")
        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isRenamingSession)
    }

    @MainActor
    func testRenameSessionIsBlockedForCachedOfflineData() async throws {
        var requestedPaths: [String] = []
        let context = try makeContext()
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let cachedSession = try makeSessionSummary(
            id: "session-abc",
            title: "Cached Planning",
            pinned: false,
            archived: false
        )
        try CacheStore.cacheSession(cachedSession, serverURL: server, in: context)

        let viewModel = try makeViewModel { request in
            let path = request.url?.path ?? "nil"
            requestedPaths.append(path)
            throw URLError(.notConnectedToInternet)
        }

        await viewModel.load(modelContext: context)
        let session = try XCTUnwrap(viewModel.sessions.first)
        let didRename = await viewModel.rename(session, to: "Launch Notes", modelContext: context)

        XCTAssertFalse(didRename)
        XCTAssertTrue(viewModel.isViewingCachedData)
        XCTAssertEqual(requestedPaths, ["/api/profiles/sessions"])
        XCTAssertEqual(viewModel.sessions.first?.title, "Cached Planning")
        XCTAssertEqual(viewModel.actionErrorMessage, "Reconnect to the server to rename a session.")
        XCTAssertFalse(viewModel.isRenamingSession)
    }

    @MainActor
    func testDirectPinAndArchiveAreBlockedForCachedOfflineData() async throws {
        let context = try makeContext()
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let cachedSession = try makeSessionSummary(
            id: "session-abc",
            title: "Cached Planning",
            pinned: false,
            archived: false
        )
        try CacheStore.cacheSession(cachedSession, serverURL: server, in: context)
        var requestCount = 0
        let viewModel = try makeViewModel { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            throw URLError(.notConnectedToInternet)
        }

        await viewModel.load(modelContext: context)
        let session = try XCTUnwrap(viewModel.sessions.first)
        let didPin = await viewModel.setPinned(true, for: session)
        let didArchive = await viewModel.archive(session)

        XCTAssertFalse(didPin)
        XCTAssertFalse(didArchive)
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(viewModel.isViewingCachedData)
        XCTAssertTrue(viewModel.actionErrorMessage?.contains("Reconnect") == true)
    }

    @MainActor
    func testLocalProjectCRUDMoveAndUnassignNeverUsesProjectRoutes() async throws {
        let suite = "SessionListMutationTests.localCRUD.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LocalOrganizerStore(defaults: defaults)
        var paths: [String] = []
        let viewModel = try makeViewModel(organizerStore: store) { request in
            paths.append(request.url?.path ?? "")
            guard request.url?.path == "/api/profiles/sessions" else {
                XCTFail("Local organizer must not use project routes")
                throw URLError(.badURL)
            }
            return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
        }
        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first)
        let created = await viewModel.createProject(named: " Client Work ", color: "#7cb9ff", moving: session)
        XCTAssertTrue(created)
        let project = try XCTUnwrap(viewModel.projects.first)
        XCTAssertEqual(viewModel.sessions.first?.projectId, project.projectId)
        let renamed = await viewModel.rename(project, named: "Archive", color: "#f5c542")
        XCTAssertTrue(renamed)
        await viewModel.move(session, to: nil)
        XCTAssertNil(viewModel.sessions.first?.projectId)
        let deleted = await viewModel.delete(try XCTUnwrap(viewModel.projects.first))
        XCTAssertTrue(deleted)
        XCTAssertTrue(viewModel.projects.isEmpty)
        XCTAssertEqual(paths, ["/api/profiles/sessions"])
    }

    @MainActor
    func testLocalProjectInvalidAndCorruptStoresDoNotMutateNetworkOrBytes() async throws {
        let suite = "SessionListMutationTests.corrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: "localOrganizer.v1")
        let store = LocalOrganizerStore(defaults: defaults)
        let viewModel = try makeViewModel(organizerStore: store) { request in
            XCTFail("Organizer validation must not use network: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let session = try makeSessionSummary(id: "session-abc", title: "Planning", pinned: false, archived: false)
        let blank = await viewModel.createProject(named: "   ", color: "#7cb9ff", moving: session)
        let corruptCreate = await viewModel.createEmptyProject(named: "No overwrite", color: "#7cb9ff")
        XCTAssertFalse(blank)
        XCTAssertFalse(corruptCreate)
        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertEqual(defaults.data(forKey: "localOrganizer.v1"), corrupt)
    }

    @MainActor
    func testFreshAndFailedRefreshPreserveLocalGrouping() async throws {
        let suite = "SessionListMutationTests.refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LocalOrganizerStore(defaults: defaults)
        let server = URL(string: "https://example.test")!
        let group = try store.createGroup(name: "Local", color: nil, server: server, profile: "default")
        try store.assignSession("session-abc", toGroup: try XCTUnwrap(group.projectId), server: server, profile: "default")
        let context = try makeContext()
        var load = 0
        let viewModel = try makeViewModel(organizerStore: store) { request in
            guard request.url?.path == "/api/profiles/sessions" else { throw URLError(.badURL) }
            load += 1
            if load == 3 { throw URLError(.notConnectedToInternet) }
            return apiTestJSONResponse(self.sessionListJSON(forLoadCount: load), for: request)
        }
        await viewModel.load(modelContext: context)
        await viewModel.load(modelContext: context)
        XCTAssertEqual(viewModel.projects.map(\.name), ["Local"])
        XCTAssertEqual(viewModel.sessions.first?.projectId, group.projectId)
        await viewModel.load(modelContext: context)
        XCTAssertEqual(viewModel.projects.map(\.name), ["Local"])
        XCTAssertEqual(viewModel.sessions.first?.projectId, group.projectId)
    }
    @MainActor
    func testMutationErrorSurfacesMessageWithoutReloadingOrCorruptingSessions() async throws {
        var loadCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                loadCount += 1
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/sessions/session-abc":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"archive failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let didArchive = await viewModel.archive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertFalse(didArchive)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testSuccessfulDirectMutationDoesNotDependOnSidebarReload() async throws {
        var loadCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                loadCount += 1
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/sessions/session-abc":
                if request.httpMethod == "PATCH" {
                    return apiTestJSONResponse(#"{"ok":true,"archived":true}"#, for: request)
                }
                return apiTestJSONResponse(
                    #"{"id":"session-abc","title":"Planning","profile":"default","pinned":0,"archived":1}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let didArchive = await viewModel.archive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertTrue(didArchive)
        XCTAssertEqual(loadCount, 1)
        XCTAssertNotEqual(viewModel.sessions, before)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testConfirmedMetadataOverlaysAnInFlightStaleSidebarLoadThenConverges() async throws {
        let staleLoadStarted = expectation(description: "stale sidebar load started")
        MetadataOverlayURLProtocol.configure(.pin) {
            staleLoadStarted.fulfill()
        }
        let viewModel = try makeMetadataOverlayViewModel()

        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)
        let session = try XCTUnwrap(viewModel.sessions.first)
        let staleLoad = Task { @MainActor in await viewModel.load() }
        await fulfillment(of: [staleLoadStarted], timeout: 1)

        let didPin = await viewModel.setPinned(true, for: session)
        XCTAssertTrue(didPin)
        MetadataOverlayURLProtocol.releaseStaleLoad()
        let staleLoadSucceeded = await staleLoad.value
        XCTAssertTrue(staleLoadSucceeded)
        XCTAssertEqual(viewModel.sessions.first?.pinned, true)

        // This request starts after confirmation, so its raw canonical value
        // is authoritative and clears the older overlay.
        _ = await viewModel.load()
        XCTAssertEqual(viewModel.sessions.first?.pinned, false)
        XCTAssertEqual(viewModel.sessions.first?.title, "External Edit")
        XCTAssertEqual(MetadataOverlayURLProtocol.listRequestCount, 3)
    }

    @MainActor
    func testSequentialDirectMetadataOverlaysAccumulateWithoutClobberingFreshFields() async throws {
        let staleLoadStarted = expectation(description: "stale sequential load started")
        MetadataOverlayURLProtocol.configure(.sequential) {
            staleLoadStarted.fulfill()
        }
        let viewModel = try makeMetadataOverlayViewModel()

        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)
        let session = try XCTUnwrap(viewModel.sessions.first)
        let staleLoad = Task { @MainActor in await viewModel.load() }
        await fulfillment(of: [staleLoadStarted], timeout: 1)
        let didPin = await viewModel.setPinned(true, for: session)
        XCTAssertTrue(didPin)
        let didRename = await viewModel.rename(session, to: "Launch Notes")
        XCTAssertTrue(didRename)
        MetadataOverlayURLProtocol.releaseStaleLoad()
        let staleLoadSucceeded = await staleLoad.value
        XCTAssertTrue(staleLoadSucceeded)

        XCTAssertEqual(viewModel.sessions.first?.title, "Launch Notes")
        XCTAssertEqual(viewModel.sessions.first?.pinned, true)
        XCTAssertEqual(viewModel.sessions.first?.workspace, "fresh-workspace")
        _ = await viewModel.load()
        XCTAssertEqual(viewModel.sessions.first?.title, "External Edit")
        XCTAssertEqual(viewModel.sessions.first?.pinned, false)
        XCTAssertEqual(viewModel.sessions.first?.workspace, "fresh-workspace")
        XCTAssertEqual(MetadataOverlayURLProtocol.listRequestCount, 3)
    }

    @MainActor
    func testArchivedSessionUnarchiveRemovesRowAndSendsSingleServerMutation() async throws {
        var archiveRequestCount = 0
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["profile"], "default")
                XCTAssertEqual(query["limit"], "100")
                XCTAssertEqual(query["offset"], "0")
                XCTAssertEqual(query["archived"], "only")
                return apiTestJSONResponse(#"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","archived":true},{"id":"session-def","title":"Later","profile":"default","archived":true}],"total":2}"#, for: request)
            case "/api/sessions/session-abc":
                archiveRequestCount += 1
                if request.httpMethod == "PATCH" {
                    let body = try XCTUnwrap(apiTestJSONBody(from: request))
                    XCTAssertEqual(body["profile"] as? String, "default")
                    XCTAssertEqual(body["archived"] as? Bool, false)
                    return apiTestJSONResponse(#"{"ok": true, "archived": false}"#, for: request)
                }
                return apiTestJSONResponse(#"{"id":"session-abc","profile":"default","archived":0}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first)

        let didUnarchive = await viewModel.unarchive(session)
        let didSkipDuplicateUnarchive = await viewModel.unarchive(session)

        XCTAssertTrue(didUnarchive)
        XCTAssertFalse(didSkipDuplicateUnarchive)
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["session-def"])
        XCTAssertEqual(archiveRequestCount, 2)
        XCTAssertFalse(viewModel.isUnarchiving)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testArchivedSessionUnarchiveFailureRestoresRemovedRow() async throws {
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["profile"], "default")
                XCTAssertEqual(query["limit"], "100")
                XCTAssertEqual(query["archived"], "only")
                return apiTestJSONResponse(#"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","archived":true},{"id":"session-def","title":"Later","profile":"default","archived":true}],"total":2}"#, for: request)
            case "/api/sessions/session-abc":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"unarchive failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let didUnarchive = await viewModel.unarchive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertFalse(didUnarchive)
        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertFalse(viewModel.isUnarchiving)
        XCTAssertNotNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testArchivedSessionUnarchiveRejectionSurfacesServerMessage() async throws {
        // Mirrors the live contract: subagent and read-only imported CLI sessions
        // reject archive-state changes with HTTP 400 + an `error` message, which
        // must reach the user verbatim rather than a generic failure (issue #17).
        let serverMessage = "Subagent sessions are view-only and cannot be archived from WebUI"
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["profile"], "default")
                XCTAssertEqual(query["limit"], "100")
                XCTAssertEqual(query["archived"], "only")
                return apiTestJSONResponse(#"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","archived":true}],"total":1}"#, for: request)
            case "/api/sessions/session-abc":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"\#(serverMessage)"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let didUnarchive = await viewModel.unarchive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertFalse(didUnarchive)
        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertEqual(viewModel.actionErrorMessage, "Hermes returned HTTP 400.")
    }

    @MainActor
    func testArchivedSessionUnarchiveOkResponseWithErrorFieldSurfacesMessageAndRestoresRow() async throws {
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                return apiTestJSONResponse(#"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","archived":true}],"total":1}"#, for: request)
            case "/api/sessions/session-abc":
                return apiTestJSONResponse(#"{"ok": false, "error": "Session not writable"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let didUnarchive = await viewModel.unarchive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertFalse(didUnarchive)
        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertEqual(viewModel.actionErrorMessage, "Hermes rejected the session change.")
    }

    @MainActor
    func testArchivedSessionUnarchiveOkFalseWithoutErrorFieldFailsAndRestoresRow() async throws {
        // An explicit `ok: false` with no `error` string must still be treated
        // as a failure — reporting success here would permanently drop the row
        // from the archived list even though the server did not restore it.
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                return apiTestJSONResponse(#"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","archived":true}],"total":1}"#, for: request)
            case "/api/sessions/session-abc":
                return apiTestJSONResponse(#"{"ok": false}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let didUnarchive = await viewModel.unarchive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertFalse(didUnarchive)
        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertFalse(viewModel.isUnarchiving)
    }

    @MainActor
    func testDirectLoadRestoresArchivedCountFromArchiveOnlyTotal() async throws {
        var countRequests = 0
        let viewModel = try makeViewModel(handlesArchivedCount: false) { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first(where: { $0.name == "profile" })?.value, "default")
                XCTAssertEqual(query?.first(where: { $0.name == "limit" })?.value, "500")
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","archived":false}],"total":1}"#,
                    for: request
                )
            case "/api/sessions":
                countRequests += 1
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                let values = Dictionary(uniqueKeysWithValues: (query ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(values["profile"], "default")
                XCTAssertEqual(values["limit"], "0")
                XCTAssertEqual(values["offset"], "0")
                XCTAssertEqual(values["order"], "recent")
                XCTAssertEqual(values["archived"], "only")
                return apiTestJSONResponse(#"{"sessions":[],"total":3,"limit":0,"offset":0}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let loaded = await viewModel.load()

        XCTAssertTrue(loaded)
        XCTAssertEqual(viewModel.archivedCount, 3)
        XCTAssertEqual(countRequests, 1)
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["session-abc"])
    }

    @MainActor
    func testArchivedCountFailureKeepsVisibleRowsAndUsesSanitizedNonBlockingError() async throws {
        let viewModel = try makeViewModel(handlesArchivedCount: false) { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","archived":false}],"total":1}"#,
                    for: request
                )
            case "/api/sessions":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"private count detail"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let loaded = await viewModel.load()

        XCTAssertTrue(loaded)
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["session-abc"])
        XCTAssertNil(viewModel.archivedCount)
        XCTAssertEqual(viewModel.errorMessage, "Hermes returned HTTP 500.")
        XCTAssertFalse(viewModel.errorMessage?.contains("private count detail") == true)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testArchivedCountDoesNotCrossAnActiveProfileEpoch() async throws {
        let countStarted = expectation(description: "default archived count started")
        ArchivedCountGateURLProtocol.configure {
            countStarted.fulfill()
        }
        let viewModel = try makeArchivedCountGateViewModel()
        let workProfile = try JSONDecoder().decode(
            ProfileSummary.self,
            from: Data(#"{"name":"work"}"#.utf8)
        )

        let defaultLoad = Task { @MainActor in await viewModel.load() }
        await fulfillment(of: [countStarted], timeout: 1)

        let switched = await viewModel.switchActiveProfile(workProfile)
        XCTAssertTrue(switched)
        let workLoaded = await viewModel.load()
        XCTAssertTrue(workLoaded)
        XCTAssertEqual(viewModel.activeProfileName, "work")
        XCTAssertEqual(viewModel.archivedCount, 7)

        // The old default-profile count completes after the active profile has
        // changed; it must not overwrite work's count.
        ArchivedCountGateURLProtocol.releaseCount()
        let defaultLoaded = await defaultLoad.value
        XCTAssertTrue(defaultLoaded)
        XCTAssertEqual(viewModel.archivedCount, 7)
        XCTAssertEqual(ArchivedCountGateURLProtocol.countProfiles, ["default", "work"])
    }

    @MainActor
    func testCancelledArchivedCountDoesNotPublishErrorOrCount() async throws {
        let countStarted = expectation(description: "archived count started")
        ArchivedCountGateURLProtocol.configure {
            countStarted.fulfill()
        }
        let viewModel = try makeArchivedCountGateViewModel()

        let loadTask = Task { @MainActor in await viewModel.load() }
        await fulfillment(of: [countStarted], timeout: 1)
        loadTask.cancel()
        ArchivedCountGateURLProtocol.releaseCount()

        let loaded = await loadTask.value
        XCTAssertTrue(loaded)
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["default-session"])
        XCTAssertNil(viewModel.archivedCount)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testArchivedCountZeroCanBecomePositiveOnExplicitRefresh() async throws {
        var countRequests = 0
        let viewModel = try makeViewModel(handlesArchivedCount: false) { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","archived":false}],"total":1}"#,
                    for: request
                )
            case "/api/sessions":
                countRequests += 1
                let total = countRequests == 1 ? 0 : 5
                return apiTestJSONResponse(#"{"sessions":[],"total":\#(total),"limit":0,"offset":0}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let firstLoaded = await viewModel.load()
        XCTAssertTrue(firstLoaded)
        XCTAssertEqual(viewModel.archivedCount, 0)
        await viewModel.refreshArchivedCountForProfile("default")

        XCTAssertEqual(viewModel.archivedCount, 5)
        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(countRequests, 2)
    }

    @MainActor
    func testArchivedCountFailurePreservesPriorSameProfileCount() async throws {
        var listRequests = 0
        var countRequests = 0
        let viewModel = try makeViewModel(handlesArchivedCount: false) { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                listRequests += 1
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","archived":false}],"total":1}"#,
                    for: request
                )
            case "/api/sessions":
                countRequests += 1
                if countRequests == 1 {
                    return apiTestJSONResponse(#"{"sessions":[],"total":3,"limit":0,"offset":0}"#, for: request)
                }
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"private count detail"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let firstLoaded = await viewModel.load()
        XCTAssertTrue(firstLoaded)
        XCTAssertEqual(viewModel.archivedCount, 3)
        let secondLoaded = await viewModel.load()
        XCTAssertTrue(secondLoaded)

        XCTAssertEqual(viewModel.archivedCount, 3)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertEqual(listRequests, 2)
        XCTAssertEqual(countRequests, 2)
    }

    @MainActor
    func testInvalidArchivedCountIsSanitizedAndDoesNotPublishNegativeValue() async throws {
        let viewModel = try makeViewModel(handlesArchivedCount: false) { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","archived":false}],"total":1}"#,
                    for: request
                )
            case "/api/sessions":
                return apiTestJSONResponse(#"{"sessions":[],"total":-1,"limit":0,"offset":0}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)

        XCTAssertNil(viewModel.archivedCount)
        XCTAssertEqual(viewModel.errorMessage, "Hermes did not return a valid archived session count.")
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testMissingArchivedCountIsSanitizedWithoutDiscardingRows() async throws {
        let viewModel = try makeViewModel(handlesArchivedCount: false) { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","archived":false}],"total":1}"#,
                    for: request
                )
            case "/api/sessions":
                return apiTestJSONResponse(#"{"sessions":[],"limit":0,"offset":0}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["session-abc"])
        XCTAssertNil(viewModel.archivedCount)
        XCTAssertEqual(viewModel.errorMessage, "Hermes did not return a valid archived session count.")
    }

    @MainActor
    func testNewerSameProfileArchivedCountWinsOverOlderPendingRequest() async throws {
        let countStarted = expectation(description: "first archived count started")
        ArchivedCountGateURLProtocol.configure {
            countStarted.fulfill()
        }
        let viewModel = try makeArchivedCountGateViewModel()

        let olderLoad = Task { @MainActor in await viewModel.load() }
        await fulfillment(of: [countStarted], timeout: 1)
        let newerLoaded = await viewModel.load()
        XCTAssertTrue(newerLoaded)
        XCTAssertEqual(viewModel.archivedCount, 4)

        ArchivedCountGateURLProtocol.releaseCount()
        let olderLoaded = await olderLoad.value
        XCTAssertTrue(olderLoaded)
        XCTAssertEqual(viewModel.archivedCount, 4)
        XCTAssertEqual(ArchivedCountGateURLProtocol.countProfiles, ["default", "default"])
    }

    @MainActor
    func testProfileSwitchClearsArchivedCountBeforeNewProfileFetch() async throws {
        let countStarted = expectation(description: "default archived count started")
        ArchivedCountGateURLProtocol.configure {
            countStarted.fulfill()
        }
        let viewModel = try makeArchivedCountGateViewModel()
        let workProfile = try JSONDecoder().decode(
            ProfileSummary.self,
            from: Data(#"{"name":"work"}"#.utf8)
        )

        let initialLoad = Task { @MainActor in await viewModel.load() }
        await fulfillment(of: [countStarted], timeout: 1)
        ArchivedCountGateURLProtocol.releaseCount()
        let initialLoaded = await initialLoad.value
        XCTAssertTrue(initialLoaded)
        XCTAssertEqual(viewModel.archivedCount, 4)

        let switched = await viewModel.switchActiveProfile(workProfile)
        XCTAssertTrue(switched)
        XCTAssertNil(viewModel.archivedCount)
    }

    @MainActor
    func testDuplicateBranchesWithCopyTitleLoadsDetailAndInsertsWhenReloadOmitsCopy() async throws {
        let transport = SessionDuplicateTransport(profile: "default")
        let runtime = try HermesServerRuntime(origin: URL(string: "https://example.test")!) { sink in
            transport.installSink(sink)
            return transport
        }
        var didRequestDuplicatedDetail = false
        let source = try makeSessionSummary(
            id: "session-abc",
            title: "Planning",
            pinned: false,
            archived: false
        )
        let viewModel = try makeViewModel(gatewayRuntimeProvider: { _ in runtime }) { request in
            switch request.url?.path {
            case "/api/sessions/session-abc/messages":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","messages":[],"pagination":{"returned":0}}"#,
                    for: request
                )
            case "/api/sessions/copy-123/messages":
                return apiTestJSONResponse(
                    #"{"session_id":"copy-123","messages":[],"pagination":{"returned":0}}"#,
                    for: request
                )
            case "/api/sessions/copy-123":
                didRequestDuplicatedDetail = true
                return apiTestJSONResponse(
                    #"{"id":"copy-123","profile":"default","title":"Planning (copy)","archived":0}"#,
                    for: request
                )
            case "/api/profiles/sessions":
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "id": "session-abc",
                      "title": "Planning",
                      "archived": false
                    }
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let duplicated = await viewModel.duplicate(source)

        XCTAssertTrue(didRequestDuplicatedDetail)
        XCTAssertEqual(transport.methods(), ["session.resume", "session.branch"])
        XCTAssertEqual(transport.branchFields()["name"], .string("Planning (copy)"))
        XCTAssertEqual(duplicated?.sessionId, "copy-123")
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["copy-123", "session-abc"])
        XCTAssertNil(viewModel.actionErrorMessage)
        await runtime.stop()
    }

    @MainActor
    func testDuplicateUnknownOutcomeBlocksSecondBranchAfterTemporaryControllerInvalidates() async throws {
        let transport = SessionDuplicateTransport(
            profile: "default",
            branchError: .timeout(method: "session.branch", requestID: "lost-ack")
        )
        let runtime = try HermesServerRuntime(origin: URL(string: "https://example.test")!) { sink in
            transport.installSink(sink)
            return transport
        }
        let source = SessionSummary(sessionId: "session-abc", title: "Planning")
        let viewModel = try makeViewModel(gatewayRuntimeProvider: { _ in runtime }) { request in
            guard request.url?.path == "/api/sessions/session-abc/messages" else {
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
            return apiTestJSONResponse(
                #"{"session_id":"session-abc","messages":[],"pagination":{"returned":0}}"#,
                for: request
            )
        }

        let first = await viewModel.duplicate(source)
        let second = await viewModel.duplicate(source)
        XCTAssertNil(first)
        XCTAssertNil(second)

        XCTAssertEqual(transport.methods().filter { $0 == "session.branch" }.count, 1)
        XCTAssertTrue(viewModel.actionErrorMessage?.contains("another duplicate is blocked") == true)
        await runtime.stop()
    }

    @MainActor
    func testDuplicateRunningSourceRefusesWithoutBranch() async throws {
        let transport = SessionDuplicateTransport(profile: "default", running: true)
        let runtime = try HermesServerRuntime(origin: URL(string: "https://example.test")!) { sink in
            transport.installSink(sink); return transport
        }
        let viewModel = try makeViewModel(gatewayRuntimeProvider: { _ in runtime }) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            return apiTestJSONResponse(
                #"{"session_id":"session-abc","messages":[],"pagination":{"returned":0}}"#,
                for: request
            )
        }

        let result = await viewModel.duplicate(SessionSummary(sessionId: "session-abc", title: "Planning"))

        XCTAssertNil(result)
        XCTAssertFalse(transport.methods().contains("session.branch"))
        XCTAssertTrue(viewModel.actionErrorMessage?.contains("still responding") == true)
        await runtime.stop()
    }

    @MainActor
    func testKnownChildDetailFailureRecoversExactListRowWithoutRebranch() async throws {
        let transport = SessionDuplicateTransport(profile: "default")
        let runtime = try HermesServerRuntime(origin: URL(string: "https://example.test")!) { sink in
            transport.installSink(sink); return transport
        }
        let viewModel = try makeViewModel(gatewayRuntimeProvider: { _ in runtime }) { request in
            switch request.url?.path {
            case "/api/sessions/session-abc/messages", "/api/sessions/copy-123/messages":
                let id = request.url!.path.contains("copy-123") ? "copy-123" : "session-abc"
                return apiTestJSONResponse(
                    #"{"session_id":"\#(id)","messages":[],"pagination":{"returned":0}}"#,
                    for: request
                )
            case "/api/sessions/copy-123":
                throw URLError(.networkConnectionLost)
            case "/api/profiles/sessions":
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"copy-123","profile":"default","title":"Planning (copy)"},{"id":"session-abc","profile":"default","title":"Planning"}]}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.duplicate(SessionSummary(sessionId: "session-abc", title: "Planning"))

        XCTAssertEqual(result?.sessionId, "copy-123")
        XCTAssertEqual(transport.methods().filter { $0 == "session.branch" }.count, 1)
        XCTAssertNil(viewModel.actionErrorMessage)
        await runtime.stop()
    }

    @MainActor
    func testProfileSwitchDuringKnownChildDetailFailureKeepsOriginalScopeBlocked() async throws {
        let detailStarted = expectation(description: "child detail started")
        let releaseDetail = DispatchSemaphore(value: 0)
        let transport = SessionDuplicateTransport(profile: "default")
        let runtime = try HermesServerRuntime(origin: URL(string: "https://example.test")!) { sink in
            transport.installSink(sink); return transport
        }
        let viewModel = try makeViewModel(gatewayRuntimeProvider: { _ in runtime }) { request in
            switch request.url?.path {
            case "/api/sessions/session-abc/messages", "/api/sessions/copy-123/messages":
                let id = request.url!.path.contains("copy-123") ? "copy-123" : "session-abc"
                return apiTestJSONResponse(
                    #"{"session_id":"\#(id)","messages":[],"pagination":{"returned":0}}"#,
                    for: request
                )
            case "/api/sessions/copy-123":
                detailStarted.fulfill()
                guard releaseDetail.wait(timeout: .now() + 2) == .success else {
                    throw URLError(.timedOut)
                }
                throw URLError(.networkConnectionLost)
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let source = SessionSummary(sessionId: "session-abc", title: "Planning", profile: "default")
        let other = try JSONDecoder().decode(ProfileSummary.self, from: Data(#"{"name":"other"}"#.utf8))
        let original = try JSONDecoder().decode(ProfileSummary.self, from: Data(#"{"name":"default"}"#.utf8))

        let duplicate = Task { @MainActor in await viewModel.duplicate(source) }
        await fulfillment(of: [detailStarted], timeout: 1)
        let switchedAway = await viewModel.switchActiveProfile(other)
        releaseDetail.signal()
        let staleResult = await duplicate.value
        XCTAssertTrue(switchedAway)
        XCTAssertNil(staleResult)
        XCTAssertNil(viewModel.actionErrorMessage, "The old profile cannot surface an error in the new scope")
        let switchedBack = await viewModel.switchActiveProfile(original)
        XCTAssertTrue(switchedBack)
        let blocked = await viewModel.duplicate(source)

        XCTAssertNil(blocked)
        XCTAssertEqual(transport.methods().filter { $0 == "session.branch" }.count, 1)
        XCTAssertTrue(viewModel.actionErrorMessage?.contains("another duplicate is blocked") == true)
        await runtime.stop()
    }

    @MainActor
    func testSidebarDuplicateDoesNotInvalidateOpenControllerOnSharedRuntime() async throws {
        let transport = SessionDuplicateTransport(profile: "default")
        let runtime = try HermesServerRuntime(origin: URL(string: "https://example.test")!) { sink in
            transport.installSink(sink); return transport
        }
        let client = try makeClient { request in
            if Self.isArchivedCountRequest(request) {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(query?.first { $0.name == "profile" }?.value, "default")
                return apiTestJSONResponse(#"{"sessions":[],"total":0,"limit":0,"offset":0}"#, for: request)
            }
            switch request.url?.path {
            case "/api/sessions/session-abc/messages", "/api/sessions/copy-123/messages":
                let id = request.url!.path.contains("copy-123") ? "copy-123" : "session-abc"
                return apiTestJSONResponse(
                    #"{"session_id":"\#(id)","messages":[],"pagination":{"returned":0}}"#,
                    for: request
                )
            case "/api/sessions/copy-123":
                return apiTestJSONResponse(
                    #"{"id":"copy-123","profile":"default","title":"Planning (copy)"}"#,
                    for: request
                )
            case "/api/profiles/sessions":
                return apiTestJSONResponse(#"{"sessions":[{"id":"session-abc","profile":"default"}]}"#, for: request)
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let openController = GatewayConversationController(
            runtime: runtime, client: client, storedID: "session-abc", profile: "default"
        )
        try await openController.open()
        var delivered = 0
        let eventDelivered = expectation(description: "open controller still receives events")
        openController.onEvent = { _ in delivered += 1; eventDelivered.fulfill() }
        let viewModel = SessionListViewModel(
            server: URL(string: "https://example.test")!, client: client,
            gatewayRuntimeProvider: { _ in runtime }
        )

        let duplicated = await viewModel.duplicate(
            SessionSummary(sessionId: "session-abc", title: "Planning", profile: "default")
        )
        transport.emit(type: "message.start", sessionID: "runtime-parent")
        await fulfillment(of: [eventDelivered], timeout: 1)

        XCTAssertEqual(duplicated?.sessionId, "copy-123")
        XCTAssertEqual(delivered, 1)
        XCTAssertFalse(openController.isDisposed)
        XCTAssertFalse(transport.methods().contains("session.close"))
        openController.invalidate()
        await runtime.stop()
    }

    @MainActor
    func testRemoteSessionSearchAppendsLoadedContentMatchesAfterLocalMatchesAndPreservesProjectScope() async throws {
        let organizer = LocalOrganizerStore(defaults: UserDefaults(suiteName: "SessionListMutationTests.searchGroups.\(UUID().uuidString)")!)
        let server = URL(string: "https://example.test")!
        let firstGroupID = try XCTUnwrap(organizer.createGroup(name: "One", color: nil, server: server, profile: "default").projectId)
        let secondGroupID = try XCTUnwrap(organizer.createGroup(name: "Two", color: nil, server: server, profile: "default").projectId)
        for id in ["local-title", "content-project", "archived-session"] {
            try organizer.assignSession(id, toGroup: firstGroupID, server: server, profile: "default")
        }
        try organizer.assignSession("content-other-project", toGroup: secondGroupID, server: server, profile: "default")
        let viewModel = try makeViewModel(organizerStore: organizer) { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "id": "local-title",
                      "title": "Needle planning",
                      "project_id": "project-1",
                      "last_message_at": 30,
                      "archived": false
                    },
                    {
                      "id": "content-project",
                      "title": "Budget",
                      "project_id": "project-1",
                      "last_message_at": 20,
                      "archived": false
                    },
                    {
                      "id": "content-other-project",
                      "title": "Roadmap",
                      "project_id": "project-2",
                      "last_message_at": 40,
                      "archived": false
                    },
                    {
                      "id": "archived-session",
                      "title": "Archived",
                      "project_id": "project-1",
                      "archived": true
                    }
                  ]
                }
                """, for: request)
            case "/api/sessions/search":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["q"], "needle")
                XCTAssertEqual(query["profile"], "default")
                XCTAssertEqual(query["limit"], "20")

                return apiTestJSONResponse("""
                {
                  "results": [
                    {"session_id": "content-project", "lineage_root": "content-project", "snippet": "needle", "role": "user", "archived": false},
                    {"session_id": "content-other-project", "lineage_root": "content-other-project", "snippet": "needle", "role": "assistant", "archived": false},
                    {"session_id": "local-title", "lineage_root": "local-title", "snippet": "needle", "role": "user", "archived": false},
                    {"session_id": "unknown-session", "lineage_root": "unknown-session", "snippet": "needle", "role": "user", "archived": false},
                    {"session_id": "archived-session", "lineage_root": "archived-session", "snippet": "needle", "role": "user", "archived": true},
                    {"session_id": "title-only", "lineage_root": "title-only", "snippet": "needle", "role": "user", "archived": false}
                  ],
                  "future_field": true
                }
                """, for: request)
            case "/api/sessions/unknown-session", "/api/sessions/title-only":
                let url = try XCTUnwrap(request.url)
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name == "profile" })?.value,
                    "default"
                )
                return (
                    try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)),
                    Data(#"{"detail":"Session not found"}"#.utf8)
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        try primeSessions([
            SessionSummary(sessionId: "local-title", title: "Needle planning", lastMessageAt: 30, projectId: "project-1"),
            SessionSummary(sessionId: "content-project", title: "Budget", lastMessageAt: 20, projectId: "project-1"),
            SessionSummary(sessionId: "content-other-project", title: "Roadmap", lastMessageAt: 40, projectId: "project-2"),
            SessionSummary(sessionId: "archived-session", title: "Archived", archived: true, projectId: "project-1")
        ], in: viewModel)
        await viewModel.searchSessions(query: "needle", debounceNanoseconds: 0)

        XCTAssertEqual(
            viewModel.visibleSessions(searchText: "needle", selectedProjectID: firstGroupID).compactMap(\.sessionId),
            ["local-title", "content-project"]
        )
        XCTAssertEqual(
            viewModel.visibleSessions(searchText: "needle", selectedProjectID: secondGroupID).compactMap(\.sessionId),
            ["content-other-project"]
        )
        XCTAssertEqual(
            viewModel.visibleSessions(searchText: "needle", selectedProjectID: nil).compactMap(\.sessionId),
            ["local-title", "content-other-project", "content-project"]
        )
    }

    @MainActor
    func testRemoteSessionSearchIgnoresStaleResultsWhenQueryChanges() async throws {
        let oldSearchStarted = expectation(description: "old search started")
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "id": "old-content",
                      "title": "First result",
                      "archived": false
                    },
                    {
                      "id": "new-content",
                      "title": "Second result",
                      "archived": false
                    }
                  ]
                }
                """, for: request)
            case "/api/sessions/search":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                let searchQuery = query["q"] ?? ""

                if searchQuery == "old" {
                    oldSearchStarted.fulfill()
                    Thread.sleep(forTimeInterval: 0.15)
                    return apiTestJSONResponse("""
                    {
                      "results": [
                        {"session_id": "old-content", "lineage_root": "old-content", "snippet": "old", "role": "user", "archived": false}
                      ]
                    }
                    """, for: request)
                }

                if searchQuery == "new" {
                    return apiTestJSONResponse("""
                    {
                      "results": [
                        {"session_id": "new-content", "lineage_root": "new-content", "snippet": "new", "role": "user", "archived": false}
                      ]
                    }
                    """, for: request)
                }

                XCTFail("Unexpected search query: \(searchQuery)")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        try primeSessions([
            SessionSummary(sessionId: "old-content", title: "First result"),
            SessionSummary(sessionId: "new-content", title: "Second result")
        ], in: viewModel)
        let oldTask = Task {
            await viewModel.searchSessions(query: "old", debounceNanoseconds: 0)
        }
        await fulfillment(of: [oldSearchStarted], timeout: 1)

        await viewModel.searchSessions(query: "new", debounceNanoseconds: 0)
        await oldTask.value

        XCTAssertEqual(viewModel.remoteContentSearchSessionIDs, ["new-content"])
        XCTAssertEqual(
            viewModel.visibleSessions(searchText: "new", selectedProjectID: nil).compactMap(\.sessionId),
            ["new-content"]
        )
    }

    // MARK: - Cron/CLI session classification (#256)

    func testCronSessionDetectedBySessionIdPrefix() {
        XCTAssertTrue(SessionSummary(sessionId: "cron_abc123").isCronSession)
        // Case-insensitive.
        XCTAssertTrue(SessionSummary(sessionId: "CRON_abc123").isCronSession)
    }

    func testCronSessionDetectedBySourceMarkers() {
        XCTAssertTrue(SessionSummary(sessionId: "s1", sourceTag: "cron").isCronSession)
        XCTAssertTrue(SessionSummary(sessionId: "s2", sessionSource: "cron").isCronSession)
        XCTAssertTrue(SessionSummary(sessionId: "s3", sourceLabel: "cron").isCronSession)
        // Tolerates surrounding whitespace / casing from the server.
        XCTAssertTrue(SessionSummary(sessionId: "s4", sourceTag: "  Cron  ").isCronSession)
    }

    func testNonCronSessionsAreNotFlagged() {
        // A `cron_` substring that is not a prefix must not match.
        XCTAssertFalse(SessionSummary(sessionId: "session_cron_x").isCronSession)
        // Plain WebUI session with no automation markers.
        XCTAssertFalse(SessionSummary(sessionId: "s5", sessionSource: "webui").isCronSession)
        // No source metadata at all (tolerant default → treated as normal).
        XCTAssertFalse(SessionSummary(sessionId: "s6").isCronSession)
    }

    func testDelegatedSubagentRequiresExplicitSourceMarker() {
        XCTAssertTrue(SessionSummary(sessionId: "s1", sourceTag: "subagent").isDelegatedSubagentSession)
        XCTAssertTrue(SessionSummary(sessionId: "s2", rawSource: " SubAgent ").isDelegatedSubagentSession)
        XCTAssertTrue(SessionSummary(sessionId: "s3", sessionSource: "subagent").isDelegatedSubagentSession)
        XCTAssertTrue(SessionSummary(sessionId: "s4", sourceLabel: "Subagent").isDelegatedSubagentSession)

        XCTAssertFalse(
            SessionSummary(
                sessionId: "fork",
                sourceTag: "fork",
                parentSessionId: "parent",
                relationshipType: "fork"
            ).isDelegatedSubagentSession
        )
        XCTAssertFalse(
            SessionSummary(
                sessionId: "continuation",
                sessionSource: "webui",
                parentSessionId: "parent",
                relationshipType: "compression_continuation"
            ).isDelegatedSubagentSession
        )
        XCTAssertFalse(SessionSummary(sessionId: "parent-only", parentSessionId: "parent").isDelegatedSubagentSession)
        XCTAssertFalse(SessionSummary(sessionId: "cron_1", sourceTag: "cron").isDelegatedSubagentSession)
        XCTAssertFalse(SessionSummary(sessionId: "cli", isCliSession: true).isDelegatedSubagentSession)
        XCTAssertFalse(SessionSummary(sessionId: "normal").isDelegatedSubagentSession)
    }

    func testClaudeCodeSessionRequiresExplicitSourceMetadata() {
        XCTAssertTrue(SessionSummary(sessionId: "s1", sourceTag: "claude_code").isClaudeCodeSession)
        XCTAssertTrue(
            SessionSummary(sessionId: "s2", rawSource: "  Claude_Code ").isClaudeCodeSession
        )

        XCTAssertFalse(
            SessionSummary(
                sessionId: "descriptive-only",
                title: "Claude Code session",
                model: "claude-sonnet",
                isCliSession: true,
                sessionSource: "claude_code",
                sourceLabel: "Claude Code"
            ).isClaudeCodeSession
        )
        XCTAssertFalse(SessionSummary(sessionId: "normal").isClaudeCodeSession)
    }

    func testReadOnlyRowsOfferExportButNoMutationActions() {
        let currentShape = SessionSummary(sessionId: "current", readOnly: true)
        let legacyShape = SessionSummary(sessionId: "legacy", isReadOnly: true)
        let normal = SessionSummary(sessionId: "normal")

        XCTAssertFalse(SessionRowActionPolicy.offersMutationActions(for: currentShape))
        XCTAssertFalse(SessionRowActionPolicy.offersMutationActions(for: legacyShape))
        XCTAssertFalse(
            SessionRowActionPolicy.offersMutationActions(
                for: SessionSummary(sessionId: "subagent", sourceTag: "subagent")
            )
        )
        XCTAssertTrue(SessionRowActionPolicy.offersMutationActions(for: normal))

        XCTAssertTrue(SessionRowActionPolicy.canExport(currentShape, isViewingCachedData: false))
        XCTAssertFalse(SessionRowActionPolicy.canExport(currentShape, isViewingCachedData: true))
        XCTAssertFalse(
            SessionRowActionPolicy.canExport(
                SessionSummary(sessionId: nil, readOnly: true),
                isViewingCachedData: false
            )
        )
    }

    func testCopyDeepLinkUsesExportAvailabilityRules() throws {
        let session = SessionSummary(sessionId: "session & /?=✓", readOnly: true)

        let url = try XCTUnwrap(
            SessionRowActionPolicy.deepLinkURL(
                for: session,
                isViewingCachedData: false,
                isMutating: false
            )
        )
        XCTAssertEqual(HermesDeepLink.sessionID(from: url), session.sessionId)
        XCTAssertNil(
            SessionRowActionPolicy.deepLinkURL(
                for: session,
                isViewingCachedData: true,
                isMutating: false
            )
        )
        XCTAssertNil(
            SessionRowActionPolicy.deepLinkURL(
                for: session,
                isViewingCachedData: false,
                isMutating: true
            )
        )
        XCTAssertNil(
            SessionRowActionPolicy.deepLinkURL(
                for: SessionSummary(sessionId: nil),
                isViewingCachedData: false,
                isMutating: false
            )
        )
    }

    func testAutomatedVisibilityShowAllKeepsEveryKind() {
        let visibility = AutomatedSessionVisibility.showAll
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "cron_1")))
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "cli-1", isCliSession: true)))
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "subagent", sourceTag: "subagent")))
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "normal")))
    }

    func testAutomatedVisibilityHidesSubagentsByDefaultAndShowsThemWhenEnabled() {
        let child = SessionSummary(sessionId: "subagent", sourceTag: "subagent")
        XCTAssertFalse(AutomatedSessionVisibility(showsCron: true, showsCli: true).shows(child))
        XCTAssertTrue(
            AutomatedSessionVisibility(
                showsCron: true,
                showsCli: true,
                showsSubagents: true
            ).shows(child)
        )
    }

    func testAutomatedVisibilityHidesCronIndependently() {
        let visibility = AutomatedSessionVisibility(showsCron: false, showsCli: true)
        XCTAssertFalse(visibility.shows(SessionSummary(sessionId: "cron_1")))
        XCTAssertFalse(visibility.shows(SessionSummary(sessionId: "c1", sourceTag: "cron")))
        // CLI and normal sessions stay visible.
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "cli-1", isCliSession: true)))
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "normal")))
    }

    func testAutomatedVisibilityHidesCliIndependently() {
        let visibility = AutomatedSessionVisibility(showsCron: true, showsCli: false)
        XCTAssertFalse(visibility.shows(SessionSummary(sessionId: "cli-1", isCliSession: true)))
        // Cron and normal sessions stay visible.
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "cron_1")))
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "normal")))
    }

    func testAutomatedVisibilityAppliesClaudeCodeChildPreferenceUnderCliParent() {
        let claudeCode = SessionSummary(
            sessionId: "claude-code",
            isCliSession: true,
            sourceTag: "claude_code"
        )
        let ordinaryCli = SessionSummary(sessionId: "ordinary-cli", isCliSession: true)

        let childHidden = AutomatedSessionVisibility(
            showsCron: true,
            showsCli: true,
            showsClaudeCode: false
        )
        XCTAssertFalse(childHidden.shows(claudeCode))
        XCTAssertTrue(childHidden.shows(ordinaryCli))

        let childShown = AutomatedSessionVisibility(
            showsCron: true,
            showsCli: true,
            showsClaudeCode: true
        )
        XCTAssertTrue(childShown.shows(claudeCode))

        let parentHidden = AutomatedSessionVisibility(
            showsCron: true,
            showsCli: false,
            showsClaudeCode: true
        )
        XCTAssertFalse(parentHidden.shows(claudeCode))
        XCTAssertFalse(parentHidden.shows(ordinaryCli))
    }

    func testAutomatedVisibilityHidesBothKinds() {
        let visibility = AutomatedSessionVisibility(showsCron: false, showsCli: false)
        XCTAssertFalse(visibility.shows(SessionSummary(sessionId: "cron_1")))
        XCTAssertFalse(visibility.shows(SessionSummary(sessionId: "cli-1", isCliSession: true)))
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "normal")))
    }

    @MainActor
    func testScheduledSessionGroupsSeparatesAndCapsNewestNonArchivedCronSessions() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            return apiTestJSONResponse("""
            {
              "sessions": [
                {"id":"ordinary","title":"Ordinary","last_active":50},
                {"id":"cron_1","title":"Scheduled 1","last_active":10},
                {"id":"cron_2","title":"Scheduled 2","last_active":20},
                {"id":"cron_3","title":"Scheduled 3","last_active":30},
                {"id":"cron_4","title":"Scheduled 4","last_active":40},
                {"id":"cron_5","title":"Scheduled 5","last_active":50},
                {"id":"cron_6","title":"Scheduled 6","last_active":60},
                {"id":"cron_7","title":"Scheduled 7","last_active":70},
                {"id":"cron_archived","title":"Archived scheduled","last_active":80,"archived":true}
              ]
            }
            """, for: request)
        }

        await viewModel.load()
        let groups = viewModel.scheduledSessionGroups(searchText: "", selectedProjectID: nil)

        XCTAssertEqual(groups.ordinary.compactMap(\.sessionId), ["ordinary"])
        XCTAssertEqual(groups.totalScheduledCount, 7)
        XCTAssertEqual(
            groups.scheduled.compactMap(\.sessionId),
            ["cron_7", "cron_6", "cron_5", "cron_4", "cron_3", "cron_2", "cron_1"]
        )
        XCTAssertEqual(
            groups.scheduledPreview.compactMap(\.sessionId),
            ["cron_7", "cron_6", "cron_5", "cron_4", "cron_3"]
        )
        XCTAssertTrue(groups.hasAdditionalScheduledSessions)
        XCTAssertTrue(groups.showsDisclosure(isSearchActive: false))
    }

    @MainActor
    func testScheduledSessionGroupsRespectCronVisibilityAndSearchWithoutCappingMatches() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            return apiTestJSONResponse("""
            {
              "sessions": [
                {"id":"ordinary","title":"Needle ordinary","last_active":5},
                {"id":"cron_1","title":"Needle scheduled 1","last_active":10},
                {"id":"cron_2","title":"Needle scheduled 2","last_active":20},
                {"id":"cron_3","title":"Needle scheduled 3","last_active":30},
                {"id":"cron_4","title":"Needle scheduled 4","last_active":40},
                {"id":"cron_5","title":"Needle scheduled 5","last_active":50},
                {"id":"cron_6","title":"Needle scheduled 6","last_active":60}
              ]
            }
            """, for: request)
        }

        await viewModel.load()
        let matches = viewModel.scheduledSessionGroups(searchText: "needle", selectedProjectID: nil)
        XCTAssertEqual(matches.ordinary.compactMap(\.sessionId), ["ordinary"])
        XCTAssertEqual(matches.scheduled.count, 6)
        XCTAssertEqual(matches.totalScheduledCount, 6)
        XCTAssertTrue(matches.showsDisclosure(isSearchActive: true))

        let noScheduledMatches = viewModel.scheduledSessionGroups(
            searchText: "ordinary",
            selectedProjectID: nil
        )
        XCTAssertFalse(noScheduledMatches.showsDisclosure(isSearchActive: true))
        XCTAssertTrue(noScheduledMatches.showsDisclosure(isSearchActive: false))

        let hidden = viewModel.scheduledSessionGroups(
            searchText: "",
            selectedProjectID: nil,
            automatedVisibility: AutomatedSessionVisibility(showsCron: false, showsCli: true)
        )
        XCTAssertTrue(hidden.scheduled.isEmpty)
        XCTAssertEqual(hidden.totalScheduledCount, 0)
        XCTAssertEqual(hidden.ordinary.compactMap(\.sessionId), ["ordinary"])
        XCTAssertFalse(hidden.showsDisclosure(isSearchActive: false))
    }

    @MainActor
    func testScheduledSessionGroupsApplyProjectFilterToScheduledAndOrdinaryRows() async throws {
        let organizer = LocalOrganizerStore(defaults: UserDefaults(suiteName: "SessionListMutationTests.scheduledGroups.\(UUID().uuidString)")!)
        let server = URL(string: "https://example.test")!
        let groupID = try XCTUnwrap(organizer.createGroup(name: "One", color: nil, server: server, profile: "default").projectId)
        try organizer.assignSession("ordinary-1", toGroup: groupID, server: server, profile: "default")
        try organizer.assignSession("cron_1", toGroup: groupID, server: server, profile: "default")
        let viewModel = try makeViewModel(organizerStore: organizer) { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            return apiTestJSONResponse("""
            {
              "sessions": [
                {"id":"ordinary-1","title":"Ordinary one","project_id":"project-1"},
                {"id":"ordinary-2","title":"Ordinary two","project_id":"project-2"},
                {"id":"cron_1","title":"Scheduled one","project_id":"project-1"},
                {"id":"cron_2","title":"Scheduled two","project_id":"project-2"}
              ]
            }
            """, for: request)
        }

        try primeSessions([
            SessionSummary(sessionId: "ordinary-1", title: "Ordinary one", projectId: "project-1"),
            SessionSummary(sessionId: "ordinary-2", title: "Ordinary two", projectId: "project-2"),
            SessionSummary(sessionId: "cron_1", title: "Scheduled one", projectId: "project-1"),
            SessionSummary(sessionId: "cron_2", title: "Scheduled two", projectId: "project-2")
        ], in: viewModel)
        let groups = viewModel.scheduledSessionGroups(
            searchText: "",
            selectedProjectID: groupID
        )

        XCTAssertEqual(groups.ordinary.compactMap(\.sessionId), ["ordinary-1"])
        XCTAssertEqual(groups.scheduled.compactMap(\.sessionId), ["cron_1"])
        // The badge is intentionally global even when rows are project-filtered:
        // issue #125 requires the total number of non-archived scheduled sessions.
        XCTAssertEqual(groups.totalScheduledCount, 2)
    }

    @MainActor
    func testVisibleSessionsFiltersCronAndCliIndependently() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            return apiTestJSONResponse("""
            {
              "sessions": [
                {"id": "normal-1", "title": "Normal one", "last_message_at": 50, "archived": false},
                {"id": "cron_job_1", "title": "Nightly digest", "last_message_at": 40, "archived": false},
                {"id": "tagged-cron", "title": "Tagged cron", "source_tag": "cron", "last_message_at": 30, "archived": false},
                {"id": "cli-1", "title": "CLI import", "is_cli_session": true, "last_message_at": 20, "archived": false},
                {"id": "normal-2", "title": "Normal two", "last_message_at": 10, "archived": false}
              ]
            }
            """, for: request)
        }

        try primeSessions([
            SessionSummary(sessionId: "normal-1", title: "Normal one", lastMessageAt: 50),
            SessionSummary(sessionId: "cron_job_1", title: "Nightly digest", lastMessageAt: 40),
            SessionSummary(sessionId: "tagged-cron", title: "Tagged cron", lastMessageAt: 30, sourceTag: "cron"),
            SessionSummary(sessionId: "cli-1", title: "CLI import", lastMessageAt: 20, isCliSession: true),
            SessionSummary(sessionId: "normal-2", title: "Normal two", lastMessageAt: 10)
        ], in: viewModel)

        // Default keeps every row.
        XCTAssertEqual(
            Set(viewModel.visibleSessions(searchText: "", selectedProjectID: nil).compactMap(\.sessionId)),
            ["normal-1", "cron_job_1", "tagged-cron", "cli-1", "normal-2"]
        )

        // Hiding cron only removes cron rows; CLI and normal rows stay.
        XCTAssertEqual(
            Set(viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: nil,
                automatedVisibility: AutomatedSessionVisibility(showsCron: false, showsCli: true)
            ).compactMap(\.sessionId)),
            ["normal-1", "cli-1", "normal-2"]
        )

        // Hiding CLI only removes the CLI row; cron and normal rows stay.
        XCTAssertEqual(
            Set(viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: nil,
                automatedVisibility: AutomatedSessionVisibility(showsCron: true, showsCli: false)
            ).compactMap(\.sessionId)),
            ["normal-1", "cron_job_1", "tagged-cron", "normal-2"]
        )

        // Hiding both leaves only the normal WebUI sessions, newest first.
        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: nil,
                automatedVisibility: AutomatedSessionVisibility(showsCron: false, showsCli: false)
            ).compactMap(\.sessionId),
            ["normal-1", "normal-2"]
        )
    }

    @MainActor
    func testVisibleSessionsFiltersSubagentsAcrossSearchAndProjects() async throws {
        let organizer = LocalOrganizerStore(defaults: UserDefaults(suiteName: "SessionListMutationTests.subagentGroups.\(UUID().uuidString)")!)
        let server = URL(string: "https://example.test")!
        let groupID = try XCTUnwrap(organizer.createGroup(name: "One", color: nil, server: server, profile: "default").projectId)
        for id in ["normal-p1", "subagent-p1", "fork-p1"] {
            try organizer.assignSession(id, toGroup: groupID, server: server, profile: "default")
        }
        let viewModel = try makeViewModel(organizerStore: organizer) { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {"id": "normal-p1", "title": "Planning", "project_id": "p1", "last_message_at": 40},
                    {"id": "subagent-p1", "title": "Delegated research", "project_id": "p1", "source_tag": "subagent", "read_only": true, "last_message_at": 30},
                    {"id": "fork-p1", "title": "Ordinary fork", "project_id": "p1", "parent_session_id": "normal-p1", "relationship_type": "fork", "last_message_at": 20},
                    {"id": "normal-p2", "title": "Other project", "project_id": "p2", "last_message_at": 10}
                  ]
                }
                """, for: request)
            case "/api/sessions/search":
                return apiTestJSONResponse("""
                {
                  "results": [
                    {"session_id": "subagent-p1", "lineage_root": "subagent-p1", "snippet": "needle", "role": "user", "archived": false},
                    {"session_id": "normal-p2", "lineage_root": "normal-p2", "snippet": "needle", "role": "assistant", "archived": false}
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        try primeSessions([
            SessionSummary(sessionId: "normal-p1", title: "Planning", lastMessageAt: 40, projectId: "p1"),
            SessionSummary(sessionId: "subagent-p1", title: "Delegated research", lastMessageAt: 30, projectId: "p1", sourceTag: "subagent", readOnly: true),
            SessionSummary(sessionId: "fork-p1", title: "Ordinary fork", lastMessageAt: 20, projectId: "p1", parentSessionId: "normal-p1", relationshipType: "fork"),
            SessionSummary(sessionId: "normal-p2", title: "Other project", lastMessageAt: 10, projectId: "p2")
        ], in: viewModel)
        let hidden = AutomatedSessionVisibility(showsCron: true, showsCli: true)
        let shown = AutomatedSessionVisibility(
            showsCron: true,
            showsCli: true,
            showsSubagents: true
        )

        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: groupID,
                automatedVisibility: hidden
            ).compactMap(\.sessionId),
            ["normal-p1", "fork-p1"]
        )
        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: groupID,
                automatedVisibility: shown
            ).compactMap(\.sessionId),
            ["normal-p1", "subagent-p1", "fork-p1"]
        )
        XCTAssertTrue(
            viewModel.visibleSessions(
                searchText: "delegated",
                selectedProjectID: nil,
                automatedVisibility: hidden
            ).isEmpty
        )
        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "delegated",
                selectedProjectID: nil,
                automatedVisibility: shown
            ).compactMap(\.sessionId),
            ["subagent-p1"]
        )

        await viewModel.searchSessions(query: "needle", debounceNanoseconds: 0)

        XCTAssertTrue(
            viewModel.visibleSessions(
                searchText: "needle",
                selectedProjectID: groupID,
                automatedVisibility: hidden
            ).isEmpty
        )
        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "needle",
                selectedProjectID: groupID,
                automatedVisibility: shown
            ).compactMap(\.sessionId),
            ["subagent-p1"]
        )
    }

    @MainActor
    func testVisibleSessionsFiltersClaudeCodeAcrossSearchAndProjects() async throws {
        let organizer = LocalOrganizerStore(defaults: UserDefaults(suiteName: "SessionListMutationTests.claudeGroups.\(UUID().uuidString)")!)
        let server = URL(string: "https://example.test")!
        let groupID = try XCTUnwrap(organizer.createGroup(name: "One", color: nil, server: server, profile: "default").projectId)
        for id in ["normal-p1", "claude-p1", "cli-p1"] {
            try organizer.assignSession(id, toGroup: groupID, server: server, profile: "default")
        }
        let viewModel = try makeViewModel(organizerStore: organizer) { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {"id": "normal-p1", "title": "Planning", "project_id": "p1", "last_message_at": 40},
                    {"id": "claude-p1", "title": "Imported transcript", "project_id": "p1", "source_tag": "claude_code", "raw_source": "claude_code", "is_cli_session": true, "read_only": true, "last_message_at": 30},
                    {"id": "cli-p1", "title": "Terminal chat", "project_id": "p1", "source_tag": "cli", "is_cli_session": true, "last_message_at": 20},
                    {"id": "normal-p2", "title": "Other project", "project_id": "p2", "last_message_at": 10}
                  ]
                }
                """, for: request)
            case "/api/sessions/search":
                return apiTestJSONResponse("""
                {
                  "results": [
                    {"session_id": "claude-p1", "lineage_root": "claude-p1", "snippet": "needle", "role": "user", "archived": false},
                    {"session_id": "cli-p1", "lineage_root": "cli-p1", "snippet": "needle", "role": "assistant", "archived": false}
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        try primeSessions([
            SessionSummary(sessionId: "normal-p1", title: "Planning", lastMessageAt: 40, projectId: "p1"),
            SessionSummary(sessionId: "claude-p1", title: "Imported transcript", lastMessageAt: 30, projectId: "p1", isCliSession: true, sourceTag: "claude_code", rawSource: "claude_code", readOnly: true),
            SessionSummary(sessionId: "cli-p1", title: "Terminal chat", lastMessageAt: 20, projectId: "p1", isCliSession: true, sourceTag: "cli"),
            SessionSummary(sessionId: "normal-p2", title: "Other project", lastMessageAt: 10, projectId: "p2")
        ], in: viewModel)
        let hidden = AutomatedSessionVisibility(
            showsCron: true,
            showsCli: true,
            showsClaudeCode: false
        )

        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: groupID,
                automatedVisibility: hidden
            ).compactMap(\.sessionId),
            ["normal-p1", "cli-p1"]
        )

        await viewModel.searchSessions(query: "needle", debounceNanoseconds: 0)

        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "needle",
                selectedProjectID: groupID,
                automatedVisibility: hidden
            ).compactMap(\.sessionId),
            ["cli-p1"]
        )
    }

    @MainActor
    private func makeViewModel(
        handlesArchivedCount: Bool = true,
        gatewayRuntimeProvider: SessionListViewModel.GatewayRuntimeProvider? = nil,
        organizerStore: LocalOrganizerStore? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> SessionListViewModel {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = try makeClient(server: server) { request in
            if handlesArchivedCount, Self.isArchivedCountRequest(request) {
                let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
                let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertFalse(query["profile", default: ""].isEmpty)
                XCTAssertEqual(query["limit"], "0")
                XCTAssertEqual(query["offset"], "0")
                XCTAssertEqual(query["order"], "recent")
                XCTAssertEqual(query["archived"], "only")
                return apiTestJSONResponse(#"{"sessions":[],"total":0,"limit":0,"offset":0}"#, for: request)
            }
            return try handler(request)
        }

        let isolatedOrganizer = organizerStore ?? LocalOrganizerStore(
            defaults: UserDefaults(suiteName: "SessionListMutationTests.\(UUID().uuidString)")!
        )
        return SessionListViewModel(
            server: server,
            client: client,
            gatewayRuntimeProvider: gatewayRuntimeProvider,
            organizerStore: isolatedOrganizer
        )
    }

    private static func isArchivedCountRequest(_ request: URLRequest) -> Bool {
        guard request.url?.path == "/api/sessions" else { return false }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        let values = Dictionary(uniqueKeysWithValues: (query ?? []).map { ($0.name, $0.value ?? "") })
        return values["limit"] == "0" && values["archived"] == "only"
    }

    @MainActor
    private func makeMetadataOverlayViewModel() throws -> SessionListViewModel {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataOverlayURLProtocol.self]
        let client = APIClient(
            baseURL: server,
            session: URLSession(configuration: configuration)
        )
        return SessionListViewModel(server: server, client: client)
    }

    @MainActor
    private func makeArchivedCountGateViewModel() throws -> SessionListViewModel {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchivedCountGateURLProtocol.self]
        let client = APIClient(
            baseURL: server,
            session: URLSession(configuration: configuration)
        )
        return SessionListViewModel(server: server, client: client)
    }

    private func makeClient(
        server: URL? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> APIClient {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let resolvedServer: URL
        if let server {
            resolvedServer = server
        } else {
            resolvedServer = try XCTUnwrap(URL(string: "https://example.test"))
        }

        return APIClient(baseURL: resolvedServer, session: session)
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedSession.self,
            CachedMessage.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    @MainActor
    private func primeSessions(_ sessions: [SessionSummary], in viewModel: SessionListViewModel) throws {
        let context = try makeContext()
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheSessions(sessions, serverURL: server, in: context)
        viewModel.prepareInitialCachedSessions(modelContext: context)
    }

    @MainActor
    private func makeArchivedViewModel(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ArchivedSessionsViewModel {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: session)

        return ArchivedSessionsViewModel(server: server, client: client)
    }

    private func sessionListJSON(forLoadCount loadCount: Int) -> String {
        switch loadCount {
        case 2:
            return """
            {
              "sessions": [
                {
                  "id": "session-abc",
                  "title": "Planning",
                  "pinned": true,
                  "archived": false
                }
              ]
            }
            """
        case 3:
            return """
            {
              "sessions": [
                {
                  "id": "session-abc",
                  "title": "Planning",
                  "pinned": true,
                  "archived": true
                }
              ]
            }
            """
        case 4:
            return """
            {
              "sessions": [
                {
                  "id": "session-abc",
                  "title": "Planning",
                  "project_id": "project-1",
                  "archived": false
                }
              ]
            }
            """
        case 5:
            return """
            {
              "sessions": []
            }
            """
        default:
            return """
            {
              "sessions": [
                {
                  "id": "session-abc",
                  "title": "Planning",
                  "pinned": false,
                  "archived": false
                }
              ]
            }
            """
        }
    }

    private func archivedSessionListJSON() -> String {
        """
        {
          "sessions": [
            {
              "session_id": "session-abc",
              "title": "Planning",
              "archived": true
            },
            {
              "session_id": "session-def",
              "title": "Research",
              "archived": true
            },
            {
              "session_id": "session-active",
              "title": "Visible in main list",
              "archived": false
            }
          ]
        }
        """
    }

    private func makeSessionSummary(
        id: String,
        title: String,
        pinned: Bool,
        archived: Bool
    ) throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "\(id)",
              "title": "\(title)",
              "pinned": \(pinned),
              "archived": \(archived)
            }
            """.utf8)
        )
    }
}

private actor SessionExportWriterGate {
    private(set) var url: URL?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func hold(_ url: URL, written: XCTestExpectation) async {
        self.url = url
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { self.continuation = continuation }
            written.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class LockedSessionMutationRequestCounts {
    private let lock = NSLock()
    private var loadRequestCount = 0
    private var pinMutationRequestCount = 0

    func incrementLoadCount() -> Int {
        lock.lock()
        defer { lock.unlock() }

        loadRequestCount += 1
        return loadRequestCount
    }

    func incrementPinRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }

        pinMutationRequestCount += 1
        return pinMutationRequestCount
    }

    var snapshot: (loadCount: Int, pinRequestCount: Int) {
        lock.lock()
        defer { lock.unlock() }

        return (loadRequestCount, pinMutationRequestCount)
    }
}

private final class ArchivedCountGateURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var onFirstCountStarted: (() -> Void)?
    private static var countContinuation: CheckedContinuation<Void, Never>?
    private static var releaseRequested = false
    private static var profiles: [String] = []
    private var loadingTask: Task<Void, Never>?

    static var countProfiles: [String] {
        lock.lock()
        defer { lock.unlock() }
        return profiles
    }

    static func configure(onFirstCountStarted: @escaping () -> Void) {
        lock.lock()
        Self.onFirstCountStarted = onFirstCountStarted
        countContinuation = nil
        releaseRequested = false
        profiles = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        let continuation = countContinuation
        countContinuation = nil
        releaseRequested = false
        onFirstCountStarted = nil
        profiles = []
        lock.unlock()
        continuation?.resume()
    }

    static func releaseCount() {
        lock.lock()
        let continuation = countContinuation
        countContinuation = nil
        if continuation == nil {
            releaseRequested = true
        }
        lock.unlock()
        continuation?.resume()
    }

    private static func waitForRelease() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if releaseRequested {
                releaseRequested = false
                lock.unlock()
                continuation.resume()
            } else {
                countContinuation = continuation
                lock.unlock()
            }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        let profile = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "profile" })?.value ?? "default"
        let responseBody: String
        let shouldHold: Bool
        let startedCallback: (() -> Void)?

        Self.lock.lock()
        switch path {
        case "/api/profiles/sessions":
            shouldHold = false
            startedCallback = nil
            responseBody = #"{"sessions":[{"id":"\#(profile)-session","title":"Planning","profile":"\#(profile)","archived":false}],"total":1}"#
        case "/api/sessions":
            Self.profiles.append(profile)
            shouldHold = Self.profiles.count == 1
            startedCallback = shouldHold ? Self.onFirstCountStarted : nil
            responseBody = profile == "work"
                ? #"{"sessions":[],"total":7,"limit":0,"offset":0}"#
                : #"{"sessions":[],"total":4,"limit":0,"offset":0}"#
        default:
            shouldHold = false
            startedCallback = nil
            responseBody = #"{}"#
        }
        Self.lock.unlock()

        startedCallback?()
        loadingTask = Task { [weak self] in
            guard let self else { return }
            if shouldHold {
                await Self.waitForRelease()
            }
            guard !Task.isCancelled else { return }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
    }
}

private final class MetadataOverlayURLProtocol: URLProtocol {
    enum Scenario {
        case pin
        case sequential
    }

    private static let lock = NSLock()
    private static var scenario: Scenario = .pin
    private static var listCount = 0
    private static var patchCount = 0
    private static var staleLoadContinuation: CheckedContinuation<Void, Never>?
    private static var releaseRequested = false
    private static var staleLoadStarted: (() -> Void)?
    private var loadingTask: Task<Void, Never>?

    static var listRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return listCount
    }

    static func configure(_ scenario: Scenario, onStaleLoadStarted: @escaping () -> Void) {
        lock.lock()
        self.scenario = scenario
        listCount = 0
        patchCount = 0
        staleLoadContinuation = nil
        releaseRequested = false
        staleLoadStarted = onStaleLoadStarted
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        let continuation = staleLoadContinuation
        staleLoadContinuation = nil
        releaseRequested = false
        staleLoadStarted = nil
        listCount = 0
        patchCount = 0
        lock.unlock()
        continuation?.resume()
    }

    static func releaseStaleLoad() {
        lock.lock()
        let continuation = staleLoadContinuation
        staleLoadContinuation = nil
        if continuation == nil {
            releaseRequested = true
        }
        lock.unlock()
        continuation?.resume()
    }

    private static func waitForRelease() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if releaseRequested {
                releaseRequested = false
                lock.unlock()
                continuation.resume()
            } else {
                staleLoadContinuation = continuation
                lock.unlock()
            }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        let method = request.httpMethod ?? "GET"
        let responseBody: String
        let shouldHold: Bool
        let startedCallback: (() -> Void)?

        Self.lock.lock()
        switch path {
        case "/api/profiles/sessions":
            Self.listCount += 1
            shouldHold = Self.listCount == 2
            startedCallback = shouldHold ? Self.staleLoadStarted : nil
            if Self.listCount == 1 || Self.listCount == 2 {
                responseBody = #"{"sessions":[{"id":"session-abc","title":"Planning","profile":"default","pinned":false,"archived":false,"cwd":"fresh-workspace"}],"total":1}"#
            } else {
                responseBody = #"{"sessions":[{"id":"session-abc","title":"External Edit","profile":"default","pinned":false,"archived":false,"cwd":"fresh-workspace"}],"total":1}"#
            }
        case "/api/sessions/session-abc":
            shouldHold = false
            startedCallback = nil
            if method == "PATCH" {
                Self.patchCount += 1
                if Self.patchCount == 1 {
                    responseBody = #"{"ok":true,"pinned":true}"#
                } else {
                    responseBody = #"{"ok":true,"title":"Launch Notes"}"#
                }
            } else if Self.scenario == .pin {
                responseBody = #"{"id":"session-abc","title":"Planning","profile":"default","pinned":1,"archived":0,"cwd":"fresh-workspace"}"#
            } else {
                responseBody = #"{"id":"session-abc","title":"Launch Notes","profile":"default","pinned":1,"archived":0,"cwd":"fresh-workspace"}"#
            }
        default:
            shouldHold = false
            startedCallback = nil
            responseBody = #"{}"#
        }
        Self.lock.unlock()

        startedCallback?()
        loadingTask = Task { [weak self] in
            guard let self else { return }
            if shouldHold {
                await Self.waitForRelease()
            }
            guard !Task.isCancelled else { return }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
    }
}

private final class OutOfOrderSessionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var nextOrdinal = 0
    private var loadingTask: Task<Void, Never>?

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextOrdinal
    }

    static func reset() {
        lock.lock()
        nextOrdinal = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let isVisibleList = url.path == "/api/profiles/sessions"
        let ordinal: Int?
        Self.lock.lock()
        if isVisibleList {
            Self.nextOrdinal += 1
            ordinal = Self.nextOrdinal
        } else {
            ordinal = nil
        }
        Self.lock.unlock()

        loadingTask = Task { [weak self] in
            guard let self else { return }
            if let ordinal {
                try? await Task.sleep(nanoseconds: ordinal == 1 ? 200_000_000 : 10_000_000)
            }
            guard !Task.isCancelled else { return }

            let data: Data
            if let ordinal {
                let title = ordinal == 1 ? "Stale result" : "Fresh result"
                let sessionID = ordinal == 1 ? "old" : "new"
                data = Data("""
                {"sessions":[{"id":"\(sessionID)","title":"\(title)"}]}
                """.utf8)
            } else {
                data = Data(#"{"sessions":[],"total":0,"limit":0,"offset":0}"#.utf8)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
    }
}

private final class OverlappingDeleteURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var sessionLoadCount = 0
    private static var onMutationStarted: (() -> Void)?
    private static var onOverlappingLoadStarted: (() -> Void)?
    private var loadingTask: Task<Void, Never>?

    static func configure(
        onMutationStarted: @escaping () -> Void,
        onOverlappingLoadStarted: @escaping () -> Void
    ) {
        lock.lock()
        sessionLoadCount = 0
        self.onMutationStarted = onMutationStarted
        self.onOverlappingLoadStarted = onOverlappingLoadStarted
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        sessionLoadCount = 0
        onMutationStarted = nil
        onOverlappingLoadStarted = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        let responseBody: String
        let delayNanoseconds: UInt64

        Self.lock.lock()
        switch path {
        case "/api/profiles/sessions":
            Self.sessionLoadCount += 1
            if Self.sessionLoadCount == 1 {
                responseBody = #"{"sessions":[{"id":"delete-me","title":"Before delete","archived":false},{"id":"keep-me","title":"Keep me","archived":false}]}"#
            } else {
                Self.onOverlappingLoadStarted?()
                responseBody = #"{"sessions":[{"id":"delete-me","title":"Canonical latest","archived":false},{"id":"keep-me","title":"Keep me","archived":false}]}"#
            }
            delayNanoseconds = 0
        case "/api/session/delete":
            Self.onMutationStarted?()
            responseBody = #"{"ok":false,"error":"delete refused"}"#
            delayNanoseconds = 100_000_000
        default:
            responseBody = #"{}"#
            delayNanoseconds = 0
        }
        Self.lock.unlock()

        loadingTask = Task { [weak self] in
            guard let self else { return }
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
    }
}

private final class SessionDuplicateTransport: HermesGatewayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var recorded: [(String, JSONValue?)] = []
    private var generation = 0
    private var sequence = 0
    private let parentID: String
    private let childID: String
    private let profile: String
    private let branchError: HermesGatewayError?
    private let running: Bool

    init(
        parentID: String = "session-abc",
        childID: String = "copy-123",
        profile: String = "work",
        running: Bool = false,
        branchError: HermesGatewayError? = nil
    ) {
        self.parentID = parentID
        self.childID = childID
        self.profile = profile
        self.running = running
        self.branchError = branchError
    }

    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        lock.withLock { self.sink = sink }
    }

    func connect() async throws { lock.withLock { generation += 1 } }
    func close() async { }
    func connectionIdentifier() async -> Int? { lock.withLock { generation } }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        lock.withLock { recorded.append((method, params)) }
        switch method {
        case "session.resume":
            return .object([
                "session_id": .string("runtime-parent"),
                "session_key": .string(parentID),
                "running": .bool(running),
                "info": .object(["profile_name": .string(profile)])
            ])
        case "session.branch":
            if let branchError { throw branchError }
            return .object([
                "session_id": .string("runtime-child"),
                "stored_session_id": .string(childID),
                "session_key": .string(childID),
                "parent": .string(parentID),
                "message_count": .number(2),
                "info": .object(["profile_name": .string(profile)])
            ])
        default:
            throw DirectSessionError.invalidResponse
        }
    }

    func methods() -> [String] { lock.withLock { recorded.map(\.0) } }

    func branchFields() -> [String: JSONValue] {
        lock.withLock {
            guard let params = recorded.first(where: { $0.0 == "session.branch" })?.1,
                  case .object(let fields) = params else { return [:] }
            return fields
        }
    }

    func emit(type: String, sessionID: String) {
        let delivery = lock.withLock { () -> ((@Sendable (HermesGatewayEvent) -> Void)?, HermesGatewayEvent) in
            sequence += 1
            return (sink, HermesGatewayEvent(
                method: "event", type: type, sessionID: sessionID, sequence: sequence,
                payload: .object([:]), params: nil, connectionGeneration: generation
            ))
        }
        delivery.0?(delivery.1)
    }
}
