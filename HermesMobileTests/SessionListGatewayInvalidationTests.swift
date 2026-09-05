import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class SessionListGatewayInvalidationTests: APIClientTestCase {
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
        let initialRequestCount = requests.value

        for sequence in 1...4 {
            transport.emit(event: sessionsChanged(sequence: sequence))
        }
        try await Task.sleep(for: .milliseconds(550))

        XCTAssertEqual(requests.value, initialRequestCount + 1)
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
        let initialRequestCount = requests.value

        viewModel.setSidebarEditing(true)
        transport.emit(event: sessionsChanged(sequence: 1))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(requests.value, initialRequestCount)
        XCTAssertTrue(viewModel.isSidebarDirty)

        viewModel.setSidebarEditing(false)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(requests.value, initialRequestCount + 1)
        XCTAssertFalse(viewModel.isSidebarDirty)

        viewModel.setSidebarDestructiveActionPending(true)
        transport.emit(event: sessionsChanged(sequence: 2))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(requests.value, initialRequestCount + 1)
        XCTAssertTrue(viewModel.isSidebarDirty)

        viewModel.setSidebarDestructiveActionPending(false)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(requests.value, initialRequestCount + 2)
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
            let path = request.url?.path
            guard path == "/api/profiles/sessions" else {
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
            requests.increment()
            return apiTestJSONResponse(
                #"{"sessions":[{"id":"one","title":"One"}]}"#,
                for: request
            )
        }
        let viewModel = SessionListViewModel(
            server: server,
            client: client,
            gatewayRuntimeProvider: { _ in selectedRuntime }
        )

        try await startObservation(for: viewModel)
        let firstLoad = await viewModel.load()
        XCTAssertTrue(firstLoad)
        let afterFirstLoad = requests.value

        selectedRuntime = secondRuntime
        viewModel.invalidateGatewayObservation()
        try await startObservation(for: viewModel)
        let secondLoad = await viewModel.load()
        XCTAssertTrue(secondLoad)
        let afterRebindLoad = requests.value

        firstTransport.emit(event: sessionsChanged(sequence: 1))
        secondTransport.emit(event: sessionsChanged(sequence: 1))
        try await Task.sleep(for: .milliseconds(550))

        XCTAssertEqual(afterRebindLoad, afterFirstLoad + 1)
        XCTAssertEqual(requests.value, afterRebindLoad + 1)
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
            guard request.url?.path == "/api/profiles/sessions" else {
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
            requests.increment()
            return apiTestJSONResponse(
                #"{"sessions":[{"id":"one","title":"One"}]}"#,
                for: request
            )
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
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
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
