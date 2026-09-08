import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class SessionListGatewayInvalidationTests: APIClientTestCase {
    func testActiveMonitorSkipsReadyObserverAndFallsBackAfterDisconnect() async throws {
        let server = try XCTUnwrap(URL(string: "https://fixture.example"))
        let transport = SessionListInvalidationFakeTransport()
        let runtime = try makeRuntime(server: server, transport: transport)
        let requests = SessionListRequestCounter()
        let viewModel = makeViewModel(server: server, requests: requests, runtime: runtime)
        try await startObservation(for: viewModel)
        // Allow the existing runtime-ready invalidation to settle before measuring
        // the monitor; that invalidation remains the connected refresh owner.
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(runtime.state, .ready)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertGreaterThan(requests.visibleListValue, 0)
        let visibleBefore = requests.visibleListValue
        let archiveBefore = requests.archiveCountValue

        let readyResult = await viewModel.refreshActiveSessionStatesIfNeeded()
        XCTAssertEqual(readyResult, .unchanged)
        XCTAssertEqual(requests.visibleListValue, visibleBefore)
        XCTAssertEqual(requests.archiveCountValue, archiveBefore)

        transport.emit(event: HermesGatewayEvent(method: "local", type: "transport.closed",
            sessionID: nil, sequence: nil, payload: nil, params: nil, connectionGeneration: 1))
        for _ in 0..<50 where runtime.state == .ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(runtime.state, .disconnected)
        let disconnectedResult = await viewModel.refreshActiveSessionStatesIfNeeded()
        XCTAssertEqual(disconnectedResult, .reloaded)
        XCTAssertEqual(requests.visibleListValue, visibleBefore + 1)
        XCTAssertEqual(requests.archiveCountValue, archiveBefore + 1)
        await runtime.stop()
    }

    func testSessionsChangedBurstCoalescesToOneDirectListRefresh() async throws {
        let server = try XCTUnwrap(URL(string: "https://fixture.example"))
        let transport = SessionListInvalidationFakeTransport()
        let runtime = try makeRuntime(server: server, transport: transport)
        let requests = SessionListRequestCounter()
        let viewModel = makeViewModel(
            server: server,
            requests: requests,
            runtime: runtime
        )

        try await startObservation(for: viewModel)
        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)
        let initialVisibleListCount = requests.visibleListValue
        let initialArchiveCountRequestCount = requests.archiveCountValue

        for sequence in 1...4 {
            transport.emit(event: sessionsChanged(sequence: sequence))
        }
        try await Task.sleep(for: .milliseconds(550))

        XCTAssertEqual(requests.visibleListValue, initialVisibleListCount + 1)
        XCTAssertEqual(requests.archiveCountValue, initialArchiveCountRequestCount + 1)
        XCTAssertFalse(viewModel.isSidebarDirty)
        await runtime.stop()
    }

    func testSessionsChangedDefersWhileEditingThenRefreshesWhenSafe() async throws {
        let server = try XCTUnwrap(URL(string: "https://fixture.example"))
        let transport = SessionListInvalidationFakeTransport()
        let runtime = try makeRuntime(server: server, transport: transport)
        let requests = SessionListRequestCounter()
        let viewModel = makeViewModel(
            server: server,
            requests: requests,
            runtime: runtime
        )

        try await startObservation(for: viewModel)
        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)
        let initialVisibleListCount = requests.visibleListValue
        let initialArchiveCountRequestCount = requests.archiveCountValue

        viewModel.setSidebarEditing(true)
        transport.emit(event: sessionsChanged(sequence: 1))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(requests.visibleListValue, initialVisibleListCount)
        XCTAssertEqual(requests.archiveCountValue, initialArchiveCountRequestCount)
        XCTAssertTrue(viewModel.isSidebarDirty)

        viewModel.setSidebarEditing(false)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(requests.visibleListValue, initialVisibleListCount + 1)
        XCTAssertEqual(requests.archiveCountValue, initialArchiveCountRequestCount + 1)
        XCTAssertFalse(viewModel.isSidebarDirty)

        viewModel.setSidebarDestructiveActionPending(true)
        transport.emit(event: sessionsChanged(sequence: 2))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(requests.visibleListValue, initialVisibleListCount + 1)
        XCTAssertEqual(requests.archiveCountValue, initialArchiveCountRequestCount + 1)
        XCTAssertTrue(viewModel.isSidebarDirty)

        viewModel.setSidebarDestructiveActionPending(false)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(requests.visibleListValue, initialVisibleListCount + 2)
        XCTAssertEqual(requests.archiveCountValue, initialArchiveCountRequestCount + 2)
        XCTAssertFalse(viewModel.isSidebarDirty)
        await runtime.stop()
    }

    func testStaleRuntimeEventsAreIgnoredAfterObservationRebind() async throws {
        let server = try XCTUnwrap(URL(string: "https://fixture.example"))
        let firstTransport = SessionListInvalidationFakeTransport()
        let secondTransport = SessionListInvalidationFakeTransport()
        let firstRuntime = try makeRuntime(server: server, transport: firstTransport)
        let secondRuntime = try makeRuntime(server: server, transport: secondTransport)
        var selectedRuntime = firstRuntime
        let requests = SessionListRequestCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                requests.incrementVisibleList()
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"one","title":"One"}]}"#,
                    for: request
                )
            case "/api/sessions":
                let query = Dictionary(
                    uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? [])
                        .map { ($0.name, $0.value ?? "") }
                )
                XCTAssertEqual(query["profile"], "default")
                XCTAssertEqual(query["archived"], "only")
                XCTAssertEqual(query["limit"], "0")
                XCTAssertEqual(query["offset"], "0")
                XCTAssertEqual(query["order"], "recent")
                requests.incrementArchiveCount()
                return apiTestJSONResponse(
                    #"{"sessions":[],"total":0,"limit":0,"offset":0}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let viewModel = SessionListViewModel(
            server: server,
            client: client,
            gatewayRuntimeProvider: { _ in selectedRuntime }
        )

        try await startObservation(for: viewModel)
        let firstLoad = await viewModel.load()
        XCTAssertTrue(firstLoad)
        let afterFirstVisibleListLoad = requests.visibleListValue
        let afterFirstArchiveCountLoad = requests.archiveCountValue

        selectedRuntime = secondRuntime
        viewModel.invalidateGatewayObservation()
        try await startObservation(for: viewModel)
        let secondLoad = await viewModel.load()
        XCTAssertTrue(secondLoad)
        let afterRebindVisibleListLoad = requests.visibleListValue
        let afterRebindArchiveCountLoad = requests.archiveCountValue

        firstTransport.emit(event: sessionsChanged(sequence: 1))
        secondTransport.emit(event: sessionsChanged(sequence: 1))
        try await Task.sleep(for: .milliseconds(550))

        XCTAssertEqual(afterRebindVisibleListLoad, afterFirstVisibleListLoad + 1)
        XCTAssertEqual(afterRebindArchiveCountLoad, afterFirstArchiveCountLoad + 1)
        XCTAssertEqual(requests.visibleListValue, afterRebindVisibleListLoad + 1)
        XCTAssertEqual(requests.archiveCountValue, afterRebindArchiveCountLoad + 1)
        await firstRuntime.stop()
        await secondRuntime.stop()
    }

    func testSessionsChangedUsesCurrentSelectedProfileOnRefresh() async throws {
        let server = try XCTUnwrap(URL(string: "https://fixture.example"))
        let transport = SessionListInvalidationFakeTransport()
        let runtime = try makeRuntime(server: server, transport: transport)
        let sessionProfiles = SessionListProfileRecorder()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(
                    #"{"profiles":[{"name":"default"},{"name":"work"}],"active":"work","single_profile_mode":false}"#,
                    for: request
                )
            case "/api/profiles/sessions":
                let profile = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "profile" })?.value
                sessionProfiles.record(profile)
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"work-session","title":"Work"}]}"#,
                    for: request
                )
            case "/api/sessions":
                let query = Dictionary(
                    uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? [])
                        .map { ($0.name, $0.value ?? "") }
                )
                XCTAssertEqual(query["profile"], "work")
                XCTAssertEqual(query["archived"], "only")
                XCTAssertEqual(query["limit"], "0")
                XCTAssertEqual(query["offset"], "0")
                XCTAssertEqual(query["order"], "recent")
                return apiTestJSONResponse(
                    #"{"sessions":[],"total":0,"limit":0,"offset":0}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let viewModel = SessionListViewModel(
            server: server,
            client: client,
            gatewayRuntimeProvider: { _ in runtime }
        )

        try await startObservation(for: viewModel)
        await viewModel.loadActiveProfile()
        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)
        transport.emit(event: sessionsChanged(sequence: 1))
        try await Task.sleep(for: .milliseconds(550))

        XCTAssertEqual(sessionProfiles.values, ["work", "work"])
        await runtime.stop()
    }

    private func makeViewModel(
        server: URL,
        requests: SessionListRequestCounter,
        runtime: HermesServerRuntime
    ) -> SessionListViewModel {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles/sessions":
                requests.incrementVisibleList()
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"one","title":"One"}]}"#,
                    for: request
                )
            case "/api/sessions":
                let query = Dictionary(
                    uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? [])
                        .map { ($0.name, $0.value ?? "") }
                )
                XCTAssertEqual(query["profile"], "default")
                XCTAssertEqual(query["archived"], "only")
                XCTAssertEqual(query["limit"], "0")
                XCTAssertEqual(query["offset"], "0")
                XCTAssertEqual(query["order"], "recent")
                requests.incrementArchiveCount()
                return apiTestJSONResponse(
                    #"{"sessions":[],"total":0,"limit":0,"offset":0}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        return SessionListViewModel(
            server: server,
            client: client,
            gatewayRuntimeProvider: { _ in runtime }
        )
    }

    private func makeRuntime(
        server: URL,
        transport: SessionListInvalidationFakeTransport
    ) throws -> HermesServerRuntime {
        let sinkBox = transport.sinkBox
        return try HermesServerRuntime(origin: server) { sink in
            sinkBox.install(sink)
            return transport
        }
    }

    private func startObservation(for viewModel: SessionListViewModel) async throws {
        viewModel.startGatewayObservation()
        try await Task.sleep(for: .milliseconds(75))
    }

    private func sessionsChanged(sequence: Int) -> HermesGatewayEvent {
        HermesGatewayEvent(
            method: "event",
            type: "sessions.changed",
            sessionID: nil,
            sequence: sequence,
            payload: .object([:]),
            params: nil,
            connectionGeneration: 1
        )
    }
}

private final class SessionListRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var visibleListCount = 0
    private var archiveCount = 0

    func incrementVisibleList() {
        lock.lock()
        visibleListCount += 1
        lock.unlock()
    }

    func incrementArchiveCount() {
        lock.lock()
        archiveCount += 1
        lock.unlock()
    }

    var visibleListValue: Int {
        lock.lock()
        defer { lock.unlock() }
        return visibleListCount
    }

    var archiveCountValue: Int {
        lock.lock()
        defer { lock.unlock() }
        return archiveCount
    }
}

private final class SessionListProfileRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ profile: String?) {
        lock.lock()
        recorded.append(profile ?? "nil")
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class SessionListEventSinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (HermesGatewayEvent) -> Void)?

    func install(_ handler: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func send(_ event: HermesGatewayEvent) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(event)
    }
}

private actor SessionListInvalidationFakeTransport: HermesGatewayTransport {
    nonisolated let sinkBox = SessionListEventSinkBox()
    private var connectionCount = 0
    private var activeConnection: Int?

    func connect() async throws {
        connectionCount += 1
        activeConnection = connectionCount
    }

    func close() async {
        activeConnection = nil
    }

    func connectionIdentifier() async -> Int? {
        activeConnection
    }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        .object(["ok": .bool(true)])
    }

    nonisolated func emit(event: HermesGatewayEvent) {
        sinkBox.send(event)
    }
}
