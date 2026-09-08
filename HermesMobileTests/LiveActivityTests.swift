import XCTest
@testable import HermesMobile

@MainActor
final class LiveActivityTests: XCTestCase {
    override func tearDown() {
        LiveActivityURLProtocol.handler = nil
        super.tearDown()
    }

    func testSanitizesLiveActivityText() {
        let title = AgentRunActivitySanitizer.sessionTitle("  A very long Hermes session title with\nmultiple lines and extra words  ")
        let activity = AgentRunActivitySanitizer.activityLine("Reading /Users/example/project/Secrets.swift\nwith details")
        let excerpt = AgentRunActivitySanitizer.responseExcerpt(String(repeating: "A", count: 180))

        XCTAssertFalse(title.contains("\n"))
        XCTAssertLessThanOrEqual(title.count, AgentRunActivitySanitizer.maximumSessionTitleCharacters)
        XCTAssertFalse(activity.contains("\n"))
        XCTAssertLessThanOrEqual(activity.count, AgentRunActivitySanitizer.maximumActivityCharacters)
        XCTAssertLessThanOrEqual(excerpt.count, AgentRunActivitySanitizer.maximumExcerptCharacters)
    }

    func testMapsToolNamesToSafeStatuses() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let state = AgentRunActivityStateReducer.initialState(
            sessionID: "session-abc",
            sessionTitle: "Build fixes",
            startedAt: startedAt
        )

        let command = AgentRunActivityStateReducer.toolStarted(name: "shell_command", state: state)
        XCTAssertEqual(command.status, .runningCommand)
        XCTAssertEqual(command.currentActivity, "Running command")

        let search = AgentRunActivityStateReducer.toolStarted(name: "ripgrep_search", state: state)
        XCTAssertEqual(search.status, .searchingFiles)
        XCTAssertEqual(search.currentActivity, "Searching files")

        let generic = AgentRunActivityStateReducer.toolStarted(name: "apply_patch", state: state)
        XCTAssertEqual(generic.status, .usingTool)
        XCTAssertEqual(generic.currentActivity, "Using apply patch")
    }

    func testElapsedTimeFormatterUsesStableClockLabels() {
        let startedAt = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            "00:00"
        )
        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 106)
            ),
            "00:06"
        )
        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 190)
            ),
            "01:30"
        )
        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 3_761)
            ),
            "1:01:01"
        )
        XCTAssertEqual(
            AgentRunElapsedTimeFormatter.label(
                startedAt: startedAt,
                updatedAt: Date(timeIntervalSince1970: 99)
            ),
            "00:00"
        )
    }

    func testLiveActivityReusePolicyRequiresMatchingSessionAndStream() {
        XCTAssertTrue(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-1"
            )
        )
        XCTAssertTrue(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: " stream-1 ",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-1"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: nil,
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "other-session",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
    }

    func testActiveLiveActivityStatesCarryRenderableText() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 106)
        let initial = AgentRunActivityStateReducer.initialState(
            sessionID: "session-abc",
            sessionTitle: "Active render",
            startedAt: startedAt
        )
        let states = [
            initial,
            AgentRunActivityStateReducer.reasoning("Thinking through the plan", state: initial, now: later),
            AgentRunActivityStateReducer.toolStarted(name: "ripgrep_search", state: initial, now: later),
            AgentRunActivityStateReducer.toolCompleted(state: initial, now: later),
            AgentRunActivityStateReducer.waitingForApproval(state: initial, now: later),
            AgentRunActivityStateReducer.waitingForClarification(state: initial, now: later),
            AgentRunActivityStateReducer.appendingToken("Hello", to: initial, now: later),
            AgentRunActivityStateReducer.settingInterimAssistant("Drafting the answer", on: initial, now: later)
        ]

        for state in states {
            XCTAssertFalse(state.isFinal)
            XCTAssertFalse(state.sessionTitle.isEmpty)
            XCTAssertFalse(state.currentActivity.isEmpty)
            XCTAssertGreaterThanOrEqual(state.updatedAt, state.startedAt)
            XCTAssertFalse(
                AgentRunElapsedTimeFormatter.label(
                    startedAt: state.startedAt,
                    updatedAt: state.updatedAt
                ).isEmpty
            )
        }
    }

    func testUpdatingSessionTitlePreservesLiveActivityState() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let state = AgentRunActivityAttributes.ContentState(
            sessionID: "session-abc",
            sessionTitle: "Untitled Session",
            status: .searchingFiles,
            currentActivity: "Searching files",
            responseExcerpt: "Looking through the repo.",
            startedAt: startedAt,
            updatedAt: startedAt,
            isStale: true
        )

        let updated = AgentRunActivityStateReducer.updatingSessionTitle(
            "Generated repo audit title",
            state: state,
            now: Date(timeIntervalSince1970: 130)
        )

        XCTAssertEqual(updated.sessionTitle, "Generated repo audit title")
        XCTAssertEqual(updated.status, .searchingFiles)
        XCTAssertEqual(updated.currentActivity, "Searching files")
        XCTAssertEqual(updated.responseExcerpt, "Looking through the repo.")
        XCTAssertEqual(updated.startedAt, startedAt)
        XCTAssertEqual(updated.updatedAt, Date(timeIntervalSince1970: 130))
        XCTAssertTrue(updated.isStale)
    }

    func testBuildsAndParsesSessionDeepLink() throws {
        let url = try XCTUnwrap(HermesDeepLink.sessionURL(sessionID: "session-abc"))
        let scheme = HermesDeepLink.scheme

        XCTAssertEqual(url.scheme, scheme)
        XCTAssertEqual(url.host, "session")
        XCTAssertEqual(HermesDeepLink.sessionID(from: url), "session-abc")
        XCTAssertEqual(HermesDeepLink.sessionID(from: URL(string: "\(scheme)://session/session-xyz")!), "session-xyz")
        XCTAssertNil(HermesDeepLink.sessionID(from: HermesShareDraft.openURL))
    }

    func testSessionDeepLinkURLPercentEncodesSessionID() throws {
        let sessionID = "session & /?=✓"
        let url = try XCTUnwrap(HermesDeepLink.sessionURL(sessionID: sessionID))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(url.scheme, HermesDeepLink.scheme)
        XCTAssertEqual(url.host, "session")
        XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "id", value: sessionID)])
        XCTAssertFalse(url.absoluteString.contains(sessionID))
    }

    func testChatViewModelLiveActivityLifecycleUsesInjectedManager() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Live work")

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStart = viewModel.seedLegacyResponseForTesting("Run the tests")
        XCTAssertTrue(didStart)
        XCTAssertEqual(manager.starts, [
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: "stream-123")
        ])

        streamClient.emit(.reasoning("I should inspect failures."))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: nil,
            name: "shell_command",
            preview: nil,
            args: nil,
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.token("Done."))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: nil,
            name: "shell_command",
            preview: nil,
            args: nil,
            duration: 1.2,
            isError: false
        )))
        streamClient.emit(.done(DoneStreamEvent()))

        XCTAssertEqual(manager.updates, [
            .reasoning("I should inspect failures."),
            .toolStarted(name: "shell_command"),
            .toolCompleted
        ])
        XCTAssertEqual(manager.ends.last, SpyAgentLiveActivityManager.End(
            status: .complete,
            activity: "Response complete",
            errorSummary: nil
        ))
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 1)
    }

    func testChatViewModelSuppressesLiveActivityResponseExcerptsByDefault() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Private live work")

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStart = viewModel.seedLegacyResponseForTesting("Keep response text private")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("Private token."))
        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(text: "Private interim.", alreadyStreamed: false)))

        XCTAssertTrue(manager.updates.isEmpty)
        XCTAssertTrue(viewModel.messages.contains { $0.content?.contains("Private token.") == true })
    }

    func testChatViewModelCanOptIntoLiveActivityResponseExcerpts() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Visible live work")

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager,
            showsLiveActivityResponseExcerpts: true
        )

        let didStart = viewModel.seedLegacyResponseForTesting("Show response text")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("Visible token."))
        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(text: "Visible interim.", alreadyStreamed: false)))

        XCTAssertEqual(manager.updates, [
            .token("Visible token."),
            .interimAssistant("Visible interim.")
        ])
    }

    func testDisablingLiveActivityResponseExcerptsClearsActiveExcerpt() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Toggle live work")

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager,
            showsLiveActivityResponseExcerpts: true
        )

        let didStart = viewModel.seedLegacyResponseForTesting("Toggle response text")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("Visible token."))
        viewModel.setShowsLiveActivityResponseExcerpts(false)

        XCTAssertEqual(manager.updates, [
            .token("Visible token."),
            .clearResponseExcerpt
        ])
    }

    func testFollowupMessageStartsNewLiveActivityAfterCompletedResponse() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Live work")
        var nextStreamNumber = 1

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            let streamID = "stream-\(nextStreamNumber)"
            nextStreamNumber += 1
            return Self.jsonResponse(#"{"stream_id":"\#(streamID)","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStartFirstResponse = viewModel.seedLegacyResponseForTesting("Run the first answer", streamID: "stream-1")
        XCTAssertTrue(didStartFirstResponse)
        streamClient.emit(.token("First answer."))
        streamClient.emit(.done(DoneStreamEvent()))

        XCTAssertEqual(manager.ends, [
            SpyAgentLiveActivityManager.End(
                status: .complete,
                activity: "Response complete",
                errorSummary: nil
            )
        ])
        XCTAssertNil(viewModel.activeStreamID)

        let didStartFollowup = viewModel.seedLegacyResponseForTesting("Follow up", streamID: "stream-2")
        XCTAssertTrue(didStartFollowup)

        XCTAssertEqual(manager.starts, [
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: "stream-1"),
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: "stream-2")
        ])
        XCTAssertEqual(viewModel.activeStreamID, "stream-2")
    }

    func testTitleStreamEventUpdatesLiveActivityTitle() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Untitled Session")

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStart = viewModel.seedLegacyResponseForTesting("Name this run")
        XCTAssertTrue(didStart)

        streamClient.emit(.title(TitleStreamEvent(sessionId: "session-abc", title: "Generated Search Plan")))

        XCTAssertEqual(viewModel.displayTitle, "Generated Search Plan")
        XCTAssertEqual(manager.updates, [
            .sessionTitle("Generated Search Plan")
        ])
    }

    func testDoneSessionTitleUpdatesLiveActivityBeforeCompletion() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Untitled Session")

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStart = viewModel.seedLegacyResponseForTesting("Finish with a generated title")
        XCTAssertTrue(didStart)

        streamClient.emit(.done(DoneStreamEvent(session: try Self.sessionDetail(id: "session-abc", title: "Generated Finish Plan"))))

        XCTAssertEqual(viewModel.displayTitle, "Generated Finish Plan")
        XCTAssertEqual(manager.updates, [
            .sessionTitle("Generated Finish Plan")
        ])
        XCTAssertEqual(manager.ends.last, SpyAgentLiveActivityManager.End(
            status: .complete,
            activity: "Response complete",
            errorSummary: nil
        ))
    }

    func testStreamEndWithoutDoneStillCompletesLiveActivity() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Live work")

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStart = viewModel.seedLegacyResponseForTesting("Run the tests")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("Done."))
        streamClient.emit(.streamEnd)

        XCTAssertEqual(manager.ends, [
            SpyAgentLiveActivityManager.End(
                status: .complete,
                activity: "Response complete",
                errorSummary: nil
            )
        ])
        XCTAssertNil(viewModel.activeStreamID)
    }

    // Retired WebUI status-refresh coverage maps to the direct recovery tests below:
    // completion/text convergence -> testDirectIdleRecoveryEndsWithoutClaimingSuccessAndAllowsFollowup
    // unknown/running/read failure -> testDirectRecoveryRequiresExplicitIdleAndSuccessfulCanonicalRead

    func testDirectIdleRecoveryEndsWithoutClaimingSuccessAndAllowsFollowup() async throws {
        let manager = SpyAgentLiveActivityManager()
        let fixture = try await makeDirectActivityFixture(manager: manager)
        await fixture.emit("message.start")
        await fixture.emit("message.delta", payload: ["text": .string("Partial answer")])
        fixture.viewModel.flushPendingStreamingContent()
        XCTAssertEqual(fixture.viewModel.messages.compactMap(\.content), ["Partial answer"])
        fixture.transcript.messages = [
            ChatMessage(role: "user", content: "Original prompt", timestamp: 1,
                messageId: "1"),
            ChatMessage(role: "assistant", content: "Complete durable answer", timestamp: 2,
                messageId: "2")
        ]
        XCTAssertEqual(manager.starts.count, 1)
        fixture.transport.setRunning(false)

        try await fixture.runtime.reconnect()
        _ = await fixture.viewModel.reconnectStreamIfNeeded()

        XCTAssertEqual(manager.ends, [.init(status: .ended, activity: "No longer running", errorSummary: nil)])
        XCTAssertEqual(fixture.viewModel.messages.compactMap(\.content),
            ["Original prompt", "Complete durable answer"])
        XCTAssertEqual(fixture.viewModel.messages.compactMap(\.messageId), ["1", "2"])
        XCTAssertFalse(fixture.viewModel.messages.contains { $0.content == "Partial answer" })
        XCTAssertEqual(fixture.transport.methods(), ["session.resume", "session.resume"])
        XCTAssertFalse(fixture.transport.methods().contains("prompt.submit"))
        XCTAssertNil(fixture.viewModel.activeStreamID)
        try await fixture.runtime.reconnect()
        XCTAssertEqual(manager.ends.count, 1, "Repeated idle recovery cannot finalize twice")

        await fixture.emit("message.start")
        XCTAssertEqual(manager.starts.count, 2)
        await fixture.emit("message.complete", payload: ["status": .string("complete")])
        XCTAssertEqual(manager.ends.last?.status, .complete)
        await fixture.runtime.stop()
    }

    func testDirectRecoveryAndTerminalCannotEndSiblingActivity() async throws {
        let manager = SpyAgentLiveActivityManager()
        let first = try await makeDirectActivityFixture(manager: manager, sessionID: "first")
        let sibling = try await makeDirectActivityFixture(manager: manager, sessionID: "sibling")
        await first.emit("message.start")
        await sibling.emit("message.start")
        first.transport.setRunning(false)
        try await first.runtime.reconnect()
        XCTAssertTrue(manager.ends.isEmpty)

        await first.emit("message.start")
        await sibling.emit("message.start")
        await first.emit("message.complete", payload: ["status": .string("cancelled")])
        XCTAssertTrue(manager.ends.isEmpty)
        await sibling.emit("message.complete", payload: ["status": .string("cancelled")])
        XCTAssertEqual(manager.ends.map(\.status), [.cancelled])
        await first.runtime.stop()
        await sibling.runtime.stop()
    }

    func testBufferedTerminalWinsOverNeutralIdleRecovery() async throws {
        let manager = SpyAgentLiveActivityManager()
        let fixture = try await makeDirectActivityFixture(manager: manager)
        await fixture.emit("message.start")
        fixture.transport.setRunning(false)
        fixture.transport.emitTerminalOnResume()
        fixture.transcript.beforeRead = {
            fixture.transcript.beforeRead = nil
            for _ in 0..<1000 {
                if fixture.runtime.bufferedEventCountForTesting > 0 { break }
                await Task.yield()
            }
            XCTAssertEqual(fixture.runtime.bufferedEventCountForTesting, 1)
            // The canonical read is still behind the reconnect barrier here.
            XCTAssertTrue(manager.ends.isEmpty)
        }

        try await fixture.runtime.reconnect()
        fixture.transcript.beforeRead = nil

        XCTAssertEqual(manager.ends.map(\.status), [.complete])
        await fixture.runtime.stop()
    }

    func testDirectRecoveryRequiresExplicitIdleAndSuccessfulCanonicalRead() async throws {
        let manager = SpyAgentLiveActivityManager()
        let fixture = try await makeDirectActivityFixture(manager: manager)
        await fixture.emit("message.start")
        fixture.transport.setRunning(nil)
        try await fixture.runtime.reconnect()
        XCTAssertTrue(manager.ends.isEmpty)
        fixture.transport.setRunning(true)
        try await fixture.runtime.reconnect()
        XCTAssertTrue(manager.ends.isEmpty)

        fixture.transport.setRunning(false)
        fixture.transcript.fails = true
        do {
            try await fixture.runtime.reconnect()
            XCTFail("Canonical read failure must fail recovery")
        } catch { }
        XCTAssertTrue(manager.ends.isEmpty)
        fixture.transcript.fails = false
        fixture.transcript.canonicalID = "different-session"
        do {
            try await fixture.runtime.reconnect()
            XCTFail("Changed canonical identity must invalidate the recovered binding")
        } catch { }
        XCTAssertTrue(manager.ends.isEmpty)
        await fixture.runtime.stop()
    }

    func testDirectRecoveryCannotEndActivityAfterOwnerInvalidation() async throws {
        let manager = SpyAgentLiveActivityManager()
        let fixture = try await makeDirectActivityFixture(manager: manager)
        await fixture.emit("message.start")
        fixture.viewModel.invalidateDirectConversation()
        fixture.transport.setRunning(false)

        try await fixture.runtime.reconnect()

        XCTAssertTrue(manager.ends.isEmpty)
        await fixture.runtime.stop()
    }

    func testEndedActivityIsFinalNeutralAndPreservesExcerpt() throws {
        let initial = AgentRunActivityStateReducer.initialState(sessionID: "session", sessionTitle: "Work")
        let responding = AgentRunActivityStateReducer.appendingToken("Partial answer", to: initial)
        let ended = AgentRunActivityStateReducer.final(
            status: .ended, activity: "No longer running", state: responding
        )
        XCTAssertTrue(ended.isFinal)
        XCTAssertFalse(ended.isStale)
        XCTAssertNil(ended.errorSummary)
        XCTAssertEqual(ended.responseExcerpt, "Partial answer")
        XCTAssertEqual(ended.status.title, "Ended")
        XCTAssertEqual(ended.status.compactTitle, "Ended")
        XCTAssertEqual(try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(ended)), ended)
    }

    private func makeDirectActivityFixture(
        manager: SpyAgentLiveActivityManager,
        sessionID: String = "session-abc"
    ) async throws -> DirectActivityFixture {
        let server = try XCTUnwrap(URL(string: "https://activity.example.test"))
        let transport = DirectActivityTransport(sessionID: sessionID)
        let runtime = try HermesServerRuntime(origin: server) { sink in
            transport.installSink(sink)
            return transport
        }
        let transcript = DirectActivityTranscript()
        let controller = GatewayConversationController(
            runtime: runtime, storedID: sessionID, profile: "default",
            loadTranscript: { id, _, _, _ in
                await transcript.beforeRead?()
                if transcript.fails { throw DirectSessionError.invalidResponse }
                return DirectHermesTranscriptPage(
                    sessionID: transcript.canonicalID ?? id,
                    messages: transcript.messages,
                    pagination: nil
                )
            }
        )
        try await controller.open()
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: sessionID, title: "Live work"),
            server: server, liveActivityManager: manager,
            gatewayRuntimeProvider: { _ in runtime }, initialDirectConversation: controller
        )
        return DirectActivityFixture(viewModel: viewModel, runtime: runtime, transport: transport, transcript: transcript)
    }

    func testFinalLiveActivityStateKeepsExcerptVisible() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let state = AgentRunActivityAttributes.ContentState(
            sessionID: "session-abc",
            sessionTitle: "Live work",
            status: .responding,
            currentActivity: "Writing response",
            responseExcerpt: "Here is the answer.",
            startedAt: startedAt,
            updatedAt: startedAt
        )

        let finalState = AgentRunActivityStateReducer.final(
            status: .complete,
            activity: "Response complete",
            state: state,
            now: Date(timeIntervalSince1970: 120)
        )

        XCTAssertEqual(finalState.status, .complete)
        XCTAssertEqual(finalState.currentActivity, "Response complete")
        XCTAssertEqual(finalState.responseExcerpt, "Here is the answer.")
        XCTAssertTrue(finalState.isFinal)
        XCTAssertFalse(finalState.isStale)
    }

    func testClearingLiveActivityExcerptRemovesRenderableText() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let state = AgentRunActivityAttributes.ContentState(
            sessionID: "session-abc",
            sessionTitle: "Live work",
            status: .responding,
            currentActivity: "Writing response",
            responseExcerpt: "Sensitive answer text.",
            startedAt: startedAt,
            updatedAt: startedAt
        )

        let cleared = AgentRunActivityStateReducer.clearingResponseExcerpt(
            state: state,
            now: Date(timeIntervalSince1970: 130)
        )

        XCTAssertEqual(cleared.status, .responding)
        XCTAssertEqual(cleared.currentActivity, "Writing response")
        XCTAssertTrue(cleared.responseExcerpt.isEmpty)
        XCTAssertEqual(cleared.startedAt, startedAt)
        XCTAssertEqual(cleared.updatedAt, Date(timeIntervalSince1970: 130))
    }

    private static func sessionSummary(id: String, title: String) throws -> SessionSummary {
        let data = Data(#"{"session_id":"\#(id)","title":"\#(title)"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionSummary.self, from: data)
    }

    private static func sessionDetail(id: String, title: String) throws -> SessionDetail {
        let data = Data(#"{"session_id":"\#(id)","title":"\#(title)"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionDetail.self, from: data)
    }

    private static func jsonResponse(_ json: String, for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    // MARK: - Orphaned activity reconciliation (#246)

    /// Builds a stream-status response for driving the reconciler core. `nil`
    /// `terminalState` omits the `journal` block entirely (the server's shape
    /// when it has no run summary), which the reconciler maps to `.complete`.
    private func statusResponse(active: Bool, terminalState: String? = nil) -> ChatStreamStatusResponse {
        ChatStreamStatusResponse(
            active: active,
            streamId: nil,
            replayAvailable: nil,
            journal: terminalState.map { RunJournalStatus(terminal: true, terminalState: $0) }
        )
    }

    @MainActor
    func testReconcilerEndsOnlyStreamsTheServerReportsInactive() async {
        var ended: [String] = []
        let now = Date(timeIntervalSince1970: 10_000)

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "done", sessionID: "s-done", updatedAt: now),
                OrphanedLiveActivity(streamID: "running", sessionID: "s-running", updatedAt: now),
                OrphanedLiveActivity(streamID: "errored", sessionID: "s-errored", updatedAt: now)
            ],
            now: now,
            notifiesOnCompletion: false,
            streamStatus: { streamID in
                switch streamID {
                case "done": self.statusResponse(active: false)   // server says the run is over → end the orphan
                case "running": self.statusResponse(active: true)  // still active → leave it for the reconnect path
                default: nil                                       // status check failed → leave it (no false positives)
                }
            },
            endOrphan: { orphan, _ in ended.append(orphan.streamID); return true },
            notify: { _ in }
        )

        XCTAssertEqual(ended, ["done"])
    }

    @MainActor
    func testReconcilerEndsNothingWhenNoOrphansExist() async {
        var endCount = 0

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [],
            now: Date(timeIntervalSince1970: 10_000),
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { _, _ in endCount += 1; return true },
            notify: { _ in }
        )

        XCTAssertEqual(endCount, 0)
    }

    // #248: on the cold-launch pass, a recently finished orphan also fires a
    // "response complete" notification once it's ended.
    @MainActor
    func testReconcilerNotifiesRecentlyCompletedOrphanOnColdLaunchPass() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "recent", sessionID: "s-recent", updatedAt: now.addingTimeInterval(-60))
            ],
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { _, _ in true },
            notify: { notified.append($0.sessionID) }
        )

        XCTAssertEqual(notified, ["s-recent"])
    }

    // #248: a completion older than the recency window is finalized silently.
    @MainActor
    func testReconcilerEndsButDoesNotNotifyStaleCompletion() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var ended: [String] = []
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(
                    streamID: "stale",
                    sessionID: "s-stale",
                    updatedAt: now.addingTimeInterval(-(LiveActivityReconciler.recentCompletionWindow + 1))
                )
            ],
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { orphan, _ in ended.append(orphan.streamID); return true },
            notify: { notified.append($0.sessionID) }
        )

        XCTAssertEqual(ended, ["stale"])
        XCTAssertTrue(notified.isEmpty)
    }

    // #248 dedup: if another path already finalized the run, `endOrphan` reports it
    // ended nothing here, so the reconciler must not fire a second notification.
    @MainActor
    func testReconcilerDoesNotNotifyWhenAnotherPathAlreadyFinalized() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "dup", sessionID: "s-dup", updatedAt: now)
            ],
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { _, _ in false },   // already final — nothing transitioned here
            notify: { notified.append($0.sessionID) }
        )

        XCTAssertTrue(notified.isEmpty)
    }

    // #248: the foreground pass ends orphans but never notifies — the in-session
    // completion paths own notifications while the app is alive.
    @MainActor
    func testReconcilerForegroundPassEndsOrphansButNeverNotifies() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var ended: [String] = []
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "recent", sessionID: "s-recent", updatedAt: now)
            ],
            now: now,
            notifiesOnCompletion: false,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { orphan, _ in ended.append(orphan.streamID); return true },
            notify: { notified.append($0.sessionID) }
        )

        XCTAssertEqual(ended, ["recent"])
        XCTAssertTrue(notified.isEmpty)
    }

    // #248: a future-dated completion (clock skew) is treated as not-recent.
    @MainActor
    func testReconcilerDoesNotNotifyFutureDatedCompletion() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "future", sessionID: "s-future", updatedAt: now.addingTimeInterval(120))
            ],
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { _, _ in true },
            notify: { notified.append($0.sessionID) }
        )

        XCTAssertTrue(notified.isEmpty)
    }

    // #267: the journal `terminal_state` → Live Activity outcome mapping. The
    // load-bearing rows are `lost-worker-bookkeeping` → `.failed` (a silently
    // dropped run — the bug this issue fixes) and the unknown/missing fallback →
    // `.complete` (never mislabel a genuine completion as a failure).
    @MainActor
    func testReconciledOutcomeMapsTerminalStateToStatus() {
        func status(_ terminalState: String?) -> AgentRunActivityStatus {
            LiveActivityReconciler.reconciledOutcome(forTerminalState: terminalState).status
        }
        XCTAssertEqual(status("completed"), .complete)
        XCTAssertEqual(status("errored"), .failed)
        XCTAssertEqual(status("interrupted-by-crash"), .failed)
        XCTAssertEqual(status("lost-worker-bookkeeping"), .failed)
        XCTAssertEqual(status("interrupted-by-user"), .cancelled)
        XCTAssertEqual(status("running"), .complete)
        XCTAssertEqual(status("unknown"), .complete)
        XCTAssertEqual(status(nil), .complete)
        XCTAssertEqual(status("a-state-we-have-never-seen"), .complete)

        // The widget line reuses the existing localized completion strings.
        XCTAssertEqual(
            LiveActivityReconciler.reconciledOutcome(forTerminalState: "completed").activity,
            String(localized: "Response complete")
        )
        XCTAssertEqual(
            LiveActivityReconciler.reconciledOutcome(forTerminalState: "errored").activity,
            String(localized: "Response failed")
        )
        XCTAssertEqual(
            LiveActivityReconciler.reconciledOutcome(forTerminalState: "interrupted-by-user").activity,
            String(localized: "Response cancelled")
        )
    }

    // #267: the core finalizes each orphan with the outcome mapped from the
    // server journal's terminal_state — not an unconditional `.complete`.
    @MainActor
    func testReconcilerFinalizesOrphanWithMappedOutcome() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var endedWith: [String: AgentRunActivityStatus] = [:]

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "ok", sessionID: "s-ok", updatedAt: now),
                OrphanedLiveActivity(streamID: "lost", sessionID: "s-lost", updatedAt: now),
                OrphanedLiveActivity(streamID: "stopped", sessionID: "s-stopped", updatedAt: now)
            ],
            now: now,
            notifiesOnCompletion: false,
            streamStatus: { streamID in
                switch streamID {
                case "ok": self.statusResponse(active: false, terminalState: "completed")
                case "lost": self.statusResponse(active: false, terminalState: "lost-worker-bookkeeping")
                default: self.statusResponse(active: false, terminalState: "interrupted-by-user")
                }
            },
            endOrphan: { orphan, outcome in endedWith[orphan.streamID] = outcome.status; return true },
            notify: { _ in }
        )

        XCTAssertEqual(endedWith["ok"], .complete)
        XCTAssertEqual(endedWith["lost"], .failed)
        XCTAssertEqual(endedWith["stopped"], .cancelled)
    }

    // #267: a recently silently-failed run must still be finalized but must NOT
    // fire a "response complete" notification on the cold-launch pass — only a
    // run that mapped to `.complete` notifies.
    @MainActor
    func testReconcilerNotifiesOnlyCompletedTerminalStateOnColdLaunch() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var ended: [String] = []
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "failed", sessionID: "s-failed", updatedAt: now.addingTimeInterval(-60)),
                OrphanedLiveActivity(streamID: "done", sessionID: "s-done", updatedAt: now.addingTimeInterval(-60))
            ],
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { streamID in
                streamID == "failed"
                    ? self.statusResponse(active: false, terminalState: "errored")
                    : self.statusResponse(active: false, terminalState: "completed")
            },
            endOrphan: { orphan, _ in ended.append(orphan.streamID); return true },
            notify: { notified.append($0.sessionID) }
        )

        XCTAssertEqual(ended.sorted(), ["done", "failed"])  // both finalized
        XCTAssertEqual(notified, ["s-done"])                // only the completed one notifies
    }

    // #246 follow-up (PR #266 #3): the orphan reconciler must defer to a stream
    // whose SSE is live in this process. The manager tracks that ownership via the
    // lifecycle calls the coordinator already makes — set on `start`, cleared on
    // `markStale` (suspend/trouble) and `end` (finalize) — and
    // `orphanedActivities()` skips the tracked stream. This verifies the
    // ownership lifecycle directly (the ActivityKit-backed list isn't reachable in
    // unit tests, but the gate it consults is).
    @MainActor
    func testActiveConnectedStreamIDTracksLiveConnectionLifecycle() {
        let manager = AgentLiveActivityManager()

        // A live SSE connection claims the stream so the reconciler leaves it alone.
        manager.start(sessionID: "session-1", sessionTitle: "Title", streamID: "stream-abc")
        XCTAssertEqual(manager.activeConnectedStreamID, "stream-abc")

        // Suspension / transport trouble releases the claim — the suspended stream is
        // eligible for server-truth reconciliation again.
        manager.markStale()
        XCTAssertNil(manager.activeConnectedStreamID)

        // Reconnecting the same stream re-claims it.
        manager.start(sessionID: "session-1", sessionTitle: "Title", streamID: "stream-abc")
        XCTAssertEqual(manager.activeConnectedStreamID, "stream-abc")

        // Finalizing the run releases the claim.
        manager.end(status: .complete, activity: "Response complete")
        XCTAssertNil(manager.activeConnectedStreamID)
    }
}

@MainActor
private final class DirectActivityTranscript {
    var fails = false
    var canonicalID: String?
    var messages: [ChatMessage] = []
    var beforeRead: (@MainActor () async -> Void)?
}

@MainActor
private struct DirectActivityFixture {
    let viewModel: ChatViewModel
    let runtime: HermesServerRuntime
    let transport: DirectActivityTransport
    let transcript: DirectActivityTranscript

    func emit(_ type: String, payload: [String: JSONValue] = [:]) async {
        transport.emit(type, payload: payload)
        // The runtime delivers transport callbacks on its buffered event task.
        for _ in 0..<40 { await Task.yield() }
    }
}

private final class DirectActivityTransport: HermesGatewayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let sessionID: String
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var running: Bool? = false
    private var generation = 0
    private var sequence = 0
    private var terminalOnResume = false
    private var recordedMethods: [String] = []

    init(sessionID: String) { self.sessionID = sessionID }
    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        lock.withLock { self.sink = sink }
    }
    func setRunning(_ value: Bool?) { lock.withLock { running = value } }
    func methods() -> [String] { lock.withLock { recordedMethods } }
    func emitTerminalOnResume() { lock.withLock { terminalOnResume = true } }
    func connect() async throws { lock.withLock { generation += 1 } }
    func close() async { }
    func connectionIdentifier() async -> Int? { lock.withLock { generation } }
    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        lock.withLock { recordedMethods.append(method) }
        guard method == "session.resume" else { return .object([:]) }
        let shouldEmit = lock.withLock {
            let value = terminalOnResume
            terminalOnResume = false
            return value
        }
        if shouldEmit { emit("message.complete", payload: ["status": .string("complete")]) }
        return lock.withLock {
            var fields: [String: JSONValue] = [
                "session_id": .string("runtime-\(sessionID)"),
                "session_key": .string(sessionID)
            ]
            if let running { fields["running"] = .bool(running) }
            return .object(fields)
        }
    }
    func emit(_ type: String, payload: [String: JSONValue]) {
        let delivery = lock.withLock { () -> ((@Sendable (HermesGatewayEvent) -> Void)?, HermesGatewayEvent) in
            sequence += 1
            return (sink, HermesGatewayEvent(
                method: "event", type: type, sessionID: "runtime-\(sessionID)", sequence: sequence,
                payload: .object(payload), params: nil, connectionGeneration: generation
            ))
        }
        delivery.0?(delivery.1)
    }
}

private final class SpyAgentLiveActivityManager: AgentLiveActivityManaging {
    struct Start: Equatable {
        let sessionID: String
        let sessionTitle: String
        let streamID: String?
    }

    struct End: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
        let errorSummary: String?
    }

    private(set) var starts: [Start] = []
    private(set) var updates: [AgentLiveActivityEvent] = []
    private(set) var didMarkStale = false
    private(set) var ends: [End] = []
    private var directOwner: UUID?

    func start(sessionID: String, sessionTitle: String, streamID: String?) {
        directOwner = nil
        starts.append(Start(sessionID: sessionID, sessionTitle: sessionTitle, streamID: streamID))
    }

    func startDirect(owner: UUID, sessionID: String, sessionTitle: String) {
        start(sessionID: sessionID, sessionTitle: sessionTitle, streamID: nil)
        directOwner = owner
    }

    func endDirect(owner: UUID, status: AgentRunActivityStatus, activity: String, errorSummary: String?) -> Bool {
        guard directOwner == owner else { return false }
        end(status: status, activity: activity, errorSummary: errorSummary)
        return true
    }

    func update(_ event: AgentLiveActivityEvent) {
        updates.append(event)
    }

    func markStale() {
        didMarkStale = true
    }

    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        directOwner = nil
        ends.append(End(status: status, activity: activity, errorSummary: errorSummary))
    }
}

private final class LiveActivitySpySSEClient: SSEStreamingClient {
    private var onEvent: (@MainActor (SSEEvent) -> Void)?
    private(set) var startedURLs: [URL] = []
    private(set) var stopCount = 0
    private(set) var lastEventID: String?

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        startedURLs.append(url)
        lastEventID = nil
        self.onEvent = onEvent
    }

    func stop() {
        stopCount += 1
    }

    @MainActor
    func emit(_ event: SSEEvent) {
        onEvent?(event)
    }
}

private final class LiveActivityURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
