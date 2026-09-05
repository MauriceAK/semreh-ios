import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class SessionListMutationTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        OverlappingDeleteURLProtocol.reset()
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
        let otherServerURL = try XCTUnwrap(URL(string: "https://other.example.test"))
        try CacheStore.cacheSessions(
            [
                SessionSummary(
                    sessionId: "cached-project-one",
                    title: "Cached project one",
                    archived: false,
                    projectId: "project-1",
                    profile: "work"
                ),
                SessionSummary(
                    sessionId: "cached-project-two",
                    title: "Cached project two",
                    archived: false,
                    projectId: "project-2",
                    profile: "work"
                ),
                SessionSummary(
                    sessionId: "cached-subagent",
                    title: "Cached delegated work",
                    archived: false,
                    projectId: "project-1",
                    profile: "work",
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
        let viewModel = try makeViewModel { request in
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
                selectedProjectID: "project-1",
                automatedVisibility: AutomatedSessionVisibility(showsCron: true, showsCli: true)
            ).compactMap(\.sessionId),
            ["cached-project-one"]
        )
        XCTAssertEqual(
            Set(viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: "project-1",
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
    func testInactiveActiveStreamStatusReloadsSessionsToClearStreamingIndicator() async throws {
        var loadCount = 0
        var requestPaths: [String] = []
        let viewModel = try makeViewModel { request in
            let path = request.url?.path ?? "nil"
            requestPaths.append(path)

            switch path {
            case "/api/profiles/sessions":
                loadCount += 1
                let activeStreamIDField = loadCount == 1 ? #","active_stream_id":"stream-123""# : ""
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "id": "session-streaming",
                      "title": "Streaming work",
                      "archived": false\(activeStreamIDField)
                    }
                  ]
                }
                """, for: request)
            case "/api/chat/stream/status":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let streamID = components?.queryItems?.first { $0.name == "stream_id" }?.value
                XCTAssertEqual(streamID, "stream-123")
                return apiTestJSONResponse(
                    #"{"active":false,"stream_id":"stream-123"}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(path)")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        XCTAssertNil(viewModel.sessions.first?.activeStreamId)

        let refreshResult = await viewModel.refreshActiveSessionStatesIfNeeded(streamIDs: ["stream-123"])

        XCTAssertEqual(refreshResult, .reloaded)
        XCTAssertNil(viewModel.sessions.first?.activeStreamId)
        XCTAssertEqual(requestPaths, ["/api/profiles/sessions", "/api/chat/stream/status", "/api/profiles/sessions"])
    }

    @MainActor
    func testActiveStreamStatusDoesNotReloadSessionsWhileStillActive() async throws {
        var loadCount = 0
        var statusCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                loadCount += 1
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "id": "session-streaming",
                      "title": "Streaming work",
                      "archived": false,
                      "active_stream_id": "stream-123"
                    }
                  ]
                }
                """, for: request)
            case "/api/chat/stream/status":
                statusCount += 1
                return apiTestJSONResponse(
                    #"{"active":true,"stream_id":"stream-123"}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let refreshResult = await viewModel.refreshActiveSessionStatesIfNeeded(streamIDs: ["stream-123"])

        XCTAssertEqual(refreshResult, .unchanged)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(statusCount, 1)
        XCTAssertNil(viewModel.sessions.first?.activeStreamId)
    }

    @MainActor
    func testActiveStreamStatusUnauthorizedIsPreservedForAuthHandling() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"unauthorized"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let refreshResult = await viewModel.refreshActiveSessionStatesIfNeeded(streamIDs: ["stream-123"])

        XCTAssertEqual(refreshResult, .failed)
        guard let lastError = viewModel.lastError,
              case APIError.unauthorized = lastError
        else {
            XCTFail("Expected unauthorized lastError, got \(String(describing: viewModel.lastError))")
            return
        }
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
    func testPinArchiveMoveAndDeleteCallServerMutationThenReloadSessions() async throws {
        var loadCount = 0
        var mutationPaths: [String] = []
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                loadCount += 1
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: loadCount), for: request)
            case "/api/session/pin":
                mutationPaths.append("/api/session/pin")
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["pinned"] as? Bool, true)
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            case "/api/session/archive":
                mutationPaths.append("/api/session/archive")
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["archived"] as? Bool, true)
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            case "/api/session/move":
                mutationPaths.append("/api/session/move")
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["project_id"] as? String, "project-1")
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
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

        await viewModel.move(session, to: "project-1")
        XCTAssertNil(viewModel.sessions.first?.projectId)

        let didDelete = await viewModel.delete(session)
        XCTAssertTrue(didDelete)
        XCTAssertTrue(viewModel.sessions.isEmpty)

        XCTAssertEqual(loadCount, 5)
        XCTAssertEqual(
            mutationPaths,
            ["/api/session/pin", "/api/session/archive", "/api/session/move", "/api/session/delete"]
        )
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    func testSessionMutatorDuplicateBranchesThenLoadsReturnedSession() async throws {
        var requestedPaths: [String] = []
        let client = try makeClient { request in
            let path = request.url?.path ?? "nil"
            requestedPaths.append(path)

            switch path {
            case "/api/session/branch":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["title"] as? String, "Planning (copy)")
                return apiTestJSONResponse(#"{"session_id":"copy-123"}"#, for: request)
            case "/api/session":
                XCTAssertEqual(request.url?.query?.contains("session_id=copy-123"), true)
                return apiTestJSONResponse(
                    """
                    {
                      "session": {
                        "session_id": "copy-123",
                        "title": "Planning (copy)",
                        "archived": false
                      }
                    }
                    """,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(path)")
                throw URLError(.badURL)
            }
        }

        let result = try await SessionMutator(client: client).duplicate(
            sessionID: "session-abc",
            title: "Planning (copy)"
        )

        XCTAssertEqual(requestedPaths, ["/api/session/branch", "/api/session"])
        XCTAssertEqual(result.session?.sessionId, "copy-123")
        XCTAssertEqual(result.session?.title, "Planning (copy)")
        XCTAssertNil(result.errorMessage)
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
            case "/api/session/pin":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")

                let currentPinRequestCount = requestCounts.incrementPinRequestCount()

                if currentPinRequestCount == 1 {
                    firstPinRequestStarted.fulfill()
                    Thread.sleep(forTimeInterval: 0.2)
                }

                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
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
        XCTAssertEqual(finalCounts.loadCount, 2)
        XCTAssertFalse(viewModel.isMutating(session))
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
            case "/api/session/rename":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["title"] as? String, "Launch Notes")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "session": {
                    "session_id": "session-abc",
                    "title": "Launch Notes"
                  }
                }
                """, for: request)
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
        XCTAssertEqual(requestedPaths, ["/api/profiles/sessions", "/api/session/rename"])
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
            case "/api/session/rename":
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
        XCTAssertEqual(requestedPaths, ["/api/profiles/sessions", "/api/session/rename"])
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

    func testCreateProjectThenMovesSessionAndUpdatesLocalLists() async throws {
        var loadCount = 0
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/profiles/sessions":
                loadCount += 1
                if loadCount == 1 {
                    return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
                }

                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "id": "session-abc",
                      "title": "Planning",
                      "project_id": "project-new",
                      "archived": false
                    }
                  ]
                }
                """, for: request)
            case "/api/projects/create":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["name"] as? String, "Client Work")
                XCTAssertEqual(body["color"] as? String, "#7cb9ff")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "project": {
                    "project_id": "project-new",
                    "name": "Client Work",
                    "color": "#7cb9ff",
                    "created_at": 1770000000
                  }
                }
                """, for: request)
            case "/api/session/move":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["project_id"] as? String, "project-new")
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let session = try await MainActor.run {
            try XCTUnwrap(viewModel.sessions.first)
        }
        let didMove = await viewModel.createProject(
            named: "  Client Work  ",
            color: "#7cb9ff",
            moving: session
        )

        XCTAssertTrue(didMove)
        let projectIDs = await MainActor.run { viewModel.projects.compactMap(\.projectId) }
        let projectName = await MainActor.run { viewModel.projects.first?.name }
        let movedProjectID = await MainActor.run { viewModel.sessions.first?.projectId }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }
        let isMovingSession = await MainActor.run { viewModel.isMovingSession }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }

        XCTAssertEqual(projectIDs, ["project-new"])
        XCTAssertEqual(projectName, "Client Work")
        XCTAssertNil(movedProjectID)
        XCTAssertEqual(
            requestedPaths,
            ["/api/profiles/sessions", "/api/projects/create", "/api/session/move", "/api/profiles/sessions"]
        )
        XCTAssertFalse(isCreatingProject)
        XCTAssertFalse(isMovingSession)
        XCTAssertNil(actionErrorMessage)
        XCTAssertNil(lastError)
    }

    func testCreateProjectBlocksBlankNameBeforeNetworkRequest() async throws {
        let viewModel = try await makeViewModel { request in
            XCTFail("Blank project names should not make network requests: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let session = try makeSessionSummary(
            id: "session-abc",
            title: "Planning",
            pinned: false,
            archived: false
        )

        let didMove = await viewModel.createProject(
            named: "  ",
            color: "#7cb9ff",
            moving: session
        )

        XCTAssertFalse(didMove)
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }
        let isMovingSession = await MainActor.run { viewModel.isMovingSession }

        XCTAssertEqual(actionErrorMessage, "Enter a project name.")
        XCTAssertNil(lastError)
        XCTAssertFalse(isCreatingProject)
        XCTAssertFalse(isMovingSession)
    }

    func testCreateProjectMoveFailureKeepsSessionUnmovedAndShowsError() async throws {
        var loadCount = 0
        let viewModel = try await makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                loadCount += 1
                XCTAssertEqual(loadCount, 1)
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/projects/create":
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "project": {
                    "project_id": "project-new",
                    "name": "Client Work",
                    "color": "#7cb9ff"
                  }
                }
                """, for: request)
            case "/api/session/move":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"move failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = await MainActor.run { viewModel.sessions }
        let session = try XCTUnwrap(before.first)
        let didMove = await viewModel.createProject(
            named: "Client Work",
            color: "#7cb9ff",
            moving: session
        )

        XCTAssertFalse(didMove)
        XCTAssertEqual(loadCount, 1)
        let sessions = await MainActor.run { viewModel.sessions }
        let projectIDs = await MainActor.run { viewModel.projects.compactMap(\.projectId) }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }
        let isMovingSession = await MainActor.run { viewModel.isMovingSession }

        XCTAssertEqual(sessions, before)
        XCTAssertEqual(projectIDs, ["project-new"])
        XCTAssertNotNil(actionErrorMessage)
        XCTAssertNotNil(lastError)
        XCTAssertFalse(isCreatingProject)
        XCTAssertFalse(isMovingSession)
    }

    func testCreateEmptyProjectCreatesProjectWithoutMovingAnySession() async throws {
        var loadCount = 0
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/profiles/sessions":
                loadCount += 1
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/projects/create":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["name"] as? String, "Client Work")
                XCTAssertEqual(body["color"] as? String, "#7cb9ff")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "project": {
                    "project_id": "project-new",
                    "name": "Client Work",
                    "color": "#7cb9ff",
                    "created_at": 1770000000
                  }
                }
                """, for: request)
            case "/api/session/move":
                XCTFail("createEmptyProject must not move any session")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let didCreate = await viewModel.createEmptyProject(
            named: "  Client Work  ",
            color: "#7cb9ff"
        )

        XCTAssertTrue(didCreate)
        let projectIDs = await MainActor.run { viewModel.projects.compactMap(\.projectId) }
        let projectName = await MainActor.run { viewModel.projects.first?.name }
        let sessionProjectID = await MainActor.run { viewModel.sessions.first?.projectId }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }
        let isMovingSession = await MainActor.run { viewModel.isMovingSession }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }

        XCTAssertEqual(projectIDs, ["project-new"])
        XCTAssertEqual(projectName, "Client Work")
        // The existing session stays unassigned: no move request was made.
        XCTAssertNil(sessionProjectID)
        XCTAssertFalse(requestedPaths.contains("/api/session/move"))
        XCTAssertEqual(
            requestedPaths,
            ["/api/profiles/sessions", "/api/projects/create", "/api/profiles/sessions"]
        )
        XCTAssertFalse(isCreatingProject)
        XCTAssertFalse(isMovingSession)
        XCTAssertNil(actionErrorMessage)
        XCTAssertNil(lastError)
    }

    func testCreateEmptyProjectBlocksBlankNameBeforeNetworkRequest() async throws {
        let viewModel = try await makeViewModel { request in
            XCTFail("Blank project names should not make network requests: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }

        let didCreate = await viewModel.createEmptyProject(
            named: "   ",
            color: "#7cb9ff"
        )

        XCTAssertFalse(didCreate)
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }

        XCTAssertEqual(actionErrorMessage, "Enter a project name.")
        XCTAssertNil(lastError)
        XCTAssertFalse(isCreatingProject)
    }

    func testCreateEmptyProjectMissingProjectInResponseShowsError() async throws {
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/projects/create":
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didCreate = await viewModel.createEmptyProject(
            named: "Client Work",
            color: "#7cb9ff"
        )

        XCTAssertFalse(didCreate)
        let projectIDs = await MainActor.run { viewModel.projects.compactMap(\.projectId) }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }

        XCTAssertEqual(requestedPaths, ["/api/projects/create"])
        XCTAssertTrue(projectIDs.isEmpty)
        XCTAssertEqual(actionErrorMessage, "The server did not return the new project.")
        XCTAssertFalse(isCreatingProject)
    }

    func testCreateEmptyProjectNetworkFailureSetsError() async throws {
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/projects/create":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"server boom"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didCreate = await viewModel.createEmptyProject(
            named: "Client Work",
            color: "#7cb9ff"
        )

        XCTAssertFalse(didCreate)
        let projectIDs = await MainActor.run { viewModel.projects.compactMap(\.projectId) }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }

        XCTAssertEqual(requestedPaths, ["/api/projects/create"])
        XCTAssertTrue(projectIDs.isEmpty)
        XCTAssertNotNil(actionErrorMessage)
        XCTAssertNotNil(lastError)
        XCTAssertFalse(isCreatingProject)
    }

    func testRenameProjectUpdatesLocalProject() async throws {
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/projects":
                return apiTestJSONResponse("""
                {
                  "projects": [
                    {
                      "project_id": "project-1",
                      "name": "Client Work",
                      "color": "#7cb9ff"
                    }
                  ]
                }
                """, for: request)
            case "/api/projects/rename":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["project_id"] as? String, "project-1")
                XCTAssertEqual(body["name"] as? String, "Client Archive")
                XCTAssertEqual(body["color"] as? String, "#f5c542")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "project": {
                    "project_id": "project-1",
                    "name": "Client Archive",
                    "color": "#f5c542"
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadProjects()
        let project = try await MainActor.run {
            try XCTUnwrap(viewModel.projects.first)
        }
        let didRename = await viewModel.rename(project, named: "  Client Archive  ", color: "#f5c542")
        let projects = await MainActor.run { viewModel.projects }
        let isRenamingProject = await MainActor.run { viewModel.isRenamingProject }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }

        XCTAssertTrue(didRename)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.projectId, "project-1")
        XCTAssertEqual(projects.first?.name, "Client Archive")
        XCTAssertEqual(projects.first?.color, "#f5c542")
        XCTAssertEqual(requestedPaths, ["/api/projects", "/api/projects/rename"])
        XCTAssertFalse(isRenamingProject)
        XCTAssertNil(actionErrorMessage)
        XCTAssertNil(lastError)
    }

    func testRenameProjectBlocksBlankNameBeforeNetworkRequest() async throws {
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/projects":
                return apiTestJSONResponse("""
                {
                  "projects": [
                    {
                      "project_id": "project-1",
                      "name": "Client Work",
                      "color": "#7cb9ff"
                    }
                  ]
                }
                """, for: request)
            default:
                XCTFail("Blank project names should not make rename requests: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadProjects()
        let project = try await MainActor.run {
            try XCTUnwrap(viewModel.projects.first)
        }
        let didRename = await viewModel.rename(project, named: "  ", color: "#7cb9ff")
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isRenamingProject = await MainActor.run { viewModel.isRenamingProject }

        XCTAssertFalse(didRename)
        XCTAssertEqual(requestedPaths, ["/api/projects"])
        XCTAssertEqual(actionErrorMessage, "Enter a project name.")
        XCTAssertNil(lastError)
        XCTAssertFalse(isRenamingProject)
    }

    func testRenameProjectFailureKeepsProject() async throws {
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/projects":
                return apiTestJSONResponse("""
                {
                  "projects": [
                    {
                      "project_id": "project-1",
                      "name": "Client Work",
                      "color": "#7cb9ff"
                    }
                  ]
                }
                """, for: request)
            case "/api/projects/rename":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"rename failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadProjects()
        let beforeProjects = await MainActor.run { viewModel.projects }
        let project = try XCTUnwrap(beforeProjects.first)
        let didRename = await viewModel.rename(project, named: "Client Archive", color: "#f5c542")
        let projects = await MainActor.run { viewModel.projects }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isRenamingProject = await MainActor.run { viewModel.isRenamingProject }

        XCTAssertFalse(didRename)
        XCTAssertEqual(requestedPaths, ["/api/projects", "/api/projects/rename"])
        XCTAssertEqual(projects, beforeProjects)
        XCTAssertNotNil(actionErrorMessage)
        XCTAssertNotNil(lastError)
        XCTAssertFalse(isRenamingProject)
    }

    func testDeleteProjectRemovesProjectAndReloadsUnassignedSessions() async throws {
        var sessionLoadCount = 0
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/profiles/sessions":
                sessionLoadCount += 1
                if sessionLoadCount == 1 {
                    return apiTestJSONResponse("""
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
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "id": "session-abc",
                      "title": "Planning",
                      "project_id": null,
                      "archived": false
                    }
                  ]
                }
                """, for: request)
            case "/api/projects":
                return apiTestJSONResponse("""
                {
                  "projects": [
                    {
                      "project_id": "project-1",
                      "name": "Client Work",
                      "color": "#7cb9ff"
                    }
                  ]
                }
                """, for: request)
            case "/api/projects/delete":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["project_id"] as? String, "project-1")
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        await viewModel.loadProjects()
        let project = try await MainActor.run {
            try XCTUnwrap(viewModel.projects.first)
        }
        let didDelete = await viewModel.delete(project)
        let projectIDs = await MainActor.run { viewModel.projects.compactMap(\.projectId) }
        let sessionProjectID = await MainActor.run { viewModel.sessions.first?.projectId }
        let isDeletingProject = await MainActor.run { viewModel.isDeletingProject }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }

        XCTAssertTrue(didDelete)
        XCTAssertEqual(projectIDs, [])
        XCTAssertNil(sessionProjectID)
        XCTAssertFalse(isDeletingProject)
        XCTAssertNil(actionErrorMessage)
        XCTAssertNil(lastError)
        XCTAssertEqual(
            requestedPaths,
            ["/api/profiles/sessions", "/api/projects", "/api/projects/delete", "/api/profiles/sessions"]
        )
    }

    func testDeleteProjectFailureKeepsProjectAndSessions() async throws {
        var sessionLoadCount = 0
        let viewModel = try await makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                sessionLoadCount += 1
                XCTAssertEqual(sessionLoadCount, 1)
                return apiTestJSONResponse("""
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
                """, for: request)
            case "/api/projects":
                return apiTestJSONResponse("""
                {
                  "projects": [
                    {
                      "project_id": "project-1",
                      "name": "Client Work",
                      "color": "#7cb9ff"
                    }
                  ]
                }
                """, for: request)
            case "/api/projects/delete":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"delete failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        await viewModel.loadProjects()
        let project = try await MainActor.run {
            try XCTUnwrap(viewModel.projects.first)
        }
        let beforeSessions = await MainActor.run { viewModel.sessions }
        let beforeProjects = await MainActor.run { viewModel.projects }
        let didDelete = await viewModel.delete(project)
        let sessions = await MainActor.run { viewModel.sessions }
        let projects = await MainActor.run { viewModel.projects }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isDeletingProject = await MainActor.run { viewModel.isDeletingProject }

        XCTAssertFalse(didDelete)
        XCTAssertEqual(sessionLoadCount, 1)
        XCTAssertEqual(sessions, beforeSessions)
        XCTAssertEqual(projects, beforeProjects)
        XCTAssertNotNil(actionErrorMessage)
        XCTAssertNotNil(lastError)
        XCTAssertFalse(isDeletingProject)
    }

    @MainActor
    func testMutationErrorSurfacesMessageWithoutReloadingOrCorruptingSessions() async throws {
        var loadCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                loadCount += 1
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/session/archive":
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
    func testSuccessfulMutationReturnsFalseWhenFollowUpReloadFails() async throws {
        var loadCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                loadCount += 1
                if loadCount == 1 {
                    return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
                }

                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"reload failed"}"#.utf8))
            case "/api/session/archive":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["archived"] as? Bool, true)
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let didArchive = await viewModel.archive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertFalse(didArchive)
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertNotNil(viewModel.sessionLoadError)
    }

    @MainActor
    func testArchivedSessionUnarchiveRemovesRowAndSendsSingleServerMutation() async throws {
        var archiveRequestCount = 0
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                // The archived screen must opt in to archived rows — without
                // include_archived=1 the server returns none (issue #17).
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["include_archived"], "1")
                return apiTestJSONResponse(self.archivedSessionListJSON(), for: request)
            case "/api/session/archive":
                archiveRequestCount += 1
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["archived"] as? Bool, false)
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
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
        XCTAssertEqual(archiveRequestCount, 1)
        XCTAssertFalse(viewModel.isUnarchiving)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testArchivedSessionUnarchiveFailureRestoresRemovedRow() async throws {
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                // The archived screen must opt in to archived rows — without
                // include_archived=1 the server returns none (issue #17).
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["include_archived"], "1")
                return apiTestJSONResponse(self.archivedSessionListJSON(), for: request)
            case "/api/session/archive":
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
                return apiTestJSONResponse(self.archivedSessionListJSON(), for: request)
            case "/api/session/archive":
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
        let actionErrorMessage = try XCTUnwrap(viewModel.actionErrorMessage)
        XCTAssertTrue(
            actionErrorMessage.contains(serverMessage),
            "Expected the server's message in: \(actionErrorMessage)"
        )
    }

    @MainActor
    func testArchivedSessionUnarchiveOkResponseWithErrorFieldSurfacesMessageAndRestoresRow() async throws {
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                return apiTestJSONResponse(self.archivedSessionListJSON(), for: request)
            case "/api/session/archive":
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
        XCTAssertEqual(viewModel.actionErrorMessage, "Session not writable")
    }

    @MainActor
    func testArchivedSessionUnarchiveOkFalseWithoutErrorFieldFailsAndRestoresRow() async throws {
        // An explicit `ok: false` with no `error` string must still be treated
        // as a failure — reporting success here would permanently drop the row
        // from the archived list even though the server did not restore it.
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                return apiTestJSONResponse(self.archivedSessionListJSON(), for: request)
            case "/api/session/archive":
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
    func testDirectLoadDoesNotInventArchivedCountForArchivedEntry() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "profile" })?.value, "default")
            XCTAssertEqual(query?.first(where: { $0.name == "limit" })?.value, "500")
            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "id": "session-abc",
                  "title": "Planning",
                  "archived": false
                }
              ],
              "total": 1
            }
            """, for: request)
        }

        XCTAssertNil(viewModel.archivedCount)

        await viewModel.load()

        XCTAssertNil(viewModel.archivedCount)
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["session-abc"])
    }

    @MainActor
    func testDuplicateBranchesWithCopyTitleLoadsDetailAndInsertsWhenReloadOmitsCopy() async throws {
        var branchCount = 0
        var didRequestDuplicatedDetail = false
        let source = try makeSessionSummary(
            id: "session-abc",
            title: "Planning",
            pinned: false,
            archived: false
        )
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session/branch":
                branchCount += 1
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["title"] as? String, "Planning (copy)")

                if branchCount == 1 {
                    return apiTestJSONResponse("""
                    {
                      "session_id": "copy-123",
                      "parent_session_id": "session-abc"
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "error": "copy failed"
                }
                """, for: request)
            case "/api/session":
                didRequestDuplicatedDetail = true
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "copy-123",
                    "title": "Planning (copy)",
                    "archived": false
                  }
                }
                """, for: request)
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
        let missingID = await viewModel.duplicate(source)

        XCTAssertTrue(didRequestDuplicatedDetail)
        XCTAssertEqual(duplicated?.sessionId, "copy-123")
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["copy-123", "session-abc"])
        XCTAssertNil(missingID)
        XCTAssertEqual(viewModel.actionErrorMessage, "copy failed")
    }

    @MainActor
    func testRemoteSessionSearchAppendsLoadedContentMatchesAfterLocalMatchesAndPreservesProjectScope() async throws {
        let viewModel = try makeViewModel { request in
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
                XCTAssertEqual(query["content"], "1")
                XCTAssertEqual(query["depth"], "5")

                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {"session_id": "content-project", "title": "Budget", "match_type": "content"},
                    {"session_id": "content-other-project", "title": "Roadmap", "match_type": "content"},
                    {"session_id": "local-title", "title": "Needle planning", "match_type": "content"},
                    {"session_id": "unknown-session", "title": "Unknown", "match_type": "content"},
                    {"session_id": "archived-session", "title": "Archived", "match_type": "content"},
                    {"session_id": "title-only", "title": "Needle remote", "match_type": "title"}
                  ],
                  "query": "needle",
                  "count": 6
                }
                """, for: request)
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
            viewModel.visibleSessions(searchText: "needle", selectedProjectID: "project-1").compactMap(\.sessionId),
            ["local-title", "content-project"]
        )
        XCTAssertEqual(
            viewModel.visibleSessions(searchText: "needle", selectedProjectID: "project-2").compactMap(\.sessionId),
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
                      "sessions": [
                        {"session_id": "old-content", "title": "First result", "match_type": "content"}
                      ],
                      "query": "old",
                      "count": 1
                    }
                    """, for: request)
                }

                if searchQuery == "new" {
                    return apiTestJSONResponse("""
                    {
                      "sessions": [
                        {"session_id": "new-content", "title": "Second result", "match_type": "content"}
                      ],
                      "query": "new",
                      "count": 1
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
        let viewModel = try makeViewModel { request in
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
            selectedProjectID: "project-1"
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
        let viewModel = try makeViewModel { request in
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
                  "sessions": [
                    {"session_id": "subagent-p1", "title": "Delegated research", "match_type": "content"},
                    {"session_id": "normal-p2", "title": "Other project", "match_type": "content"}
                  ],
                  "query": "needle",
                  "count": 2
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
                selectedProjectID: "p1",
                automatedVisibility: hidden
            ).compactMap(\.sessionId),
            ["normal-p1", "fork-p1"]
        )
        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: "p1",
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
                selectedProjectID: "p1",
                automatedVisibility: hidden
            ).isEmpty
        )
        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "needle",
                selectedProjectID: "p1",
                automatedVisibility: shown
            ).compactMap(\.sessionId),
            ["subagent-p1"]
        )
    }

    @MainActor
    func testVisibleSessionsFiltersClaudeCodeAcrossSearchAndProjects() async throws {
        let viewModel = try makeViewModel { request in
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
                  "sessions": [
                    {"session_id": "claude-p1", "title": "Imported transcript", "match_type": "content"},
                    {"session_id": "cli-p1", "title": "Terminal chat", "match_type": "content"}
                  ],
                  "query": "needle",
                  "count": 2
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
                selectedProjectID: "p1",
                automatedVisibility: hidden
            ).compactMap(\.sessionId),
            ["normal-p1", "cli-p1"]
        )

        await viewModel.searchSessions(query: "needle", debounceNanoseconds: 0)

        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "needle",
                selectedProjectID: "p1",
                automatedVisibility: hidden
            ).compactMap(\.sessionId),
            ["cli-p1"]
        )
    }

    @MainActor
    private func makeViewModel(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> SessionListViewModel {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = try makeClient(server: server, handler: handler)

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
        Self.lock.lock()
        Self.nextOrdinal += 1
        let ordinal = Self.nextOrdinal
        Self.lock.unlock()

        loadingTask = Task { [weak self] in
            guard let self, let url = request.url else { return }
            try? await Task.sleep(nanoseconds: ordinal == 1 ? 200_000_000 : 10_000_000)
            guard !Task.isCancelled else { return }

            let title = ordinal == 1 ? "Stale result" : "Fresh result"
            let sessionID = ordinal == 1 ? "old" : "new"
            let data = Data("""
            {"sessions":[{"id":"\(sessionID)","title":"\(title)"}]}
            """.utf8)
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
