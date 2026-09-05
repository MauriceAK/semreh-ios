import Foundation
import XCTest
@testable import HermesMobile

/// Opt-in hosted smoke coverage for the pinned local Slice 1 deployment.
///
/// This is deliberately not part of the default XCTest path. The hosted
/// runner must set both environment variables, and the credentials file is
/// required to remain outside the source tree.
final class DirectHermesLiveSmokeTests: XCTestCase {
    private static let credentialsPath = "/Users/maurice/workspace/semreh-slice1-runtime/credentials.json"

    private enum HostedTransport {
        case loopback
        case https

        var baseURL: URL {
            switch self {
            case .loopback:
                return URL(string: "http://127.0.0.1:18791")!
            case .https:
                return URL(string: "https://semreh-slice1-test.tailda8427.ts.net")!
            }
        }

        var gatewayURL: URL {
            switch self {
            case .loopback:
                return URL(string: "ws://127.0.0.1:18791/api/ws")!
            case .https:
                return URL(string: "wss://semreh-slice1-test.tailda8427.ts.net/api/ws")!
            }
        }

        var hostHeader: String? {
            switch self {
            case .loopback:
                return "semreh-slice1.test:18791"
            case .https:
                return nil
            }
        }
    }

    func testOptInHostedSlice1AuthGatewayAndDurability() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Slice 1 hosted smoke is simulator-only.")
        #endif

        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE1_LIVE"] == "1",
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == Self.credentialsPath
        else {
            throw XCTSkip("Slice 1 hosted smoke is opt-in.")
        }

        do {
            try await runHostedSmoke(
                transport: environment["SEMREH_SLICE1_HTTPS"] == "1" ? .https : .loopback
            )
        } catch let failure as LiveSmokeFailure {
            XCTFail("Slice 1 hosted smoke failed at \(failure.stage).")
        } catch {
            XCTFail("Slice 1 hosted smoke failed.")
        }
    }

    func testOptInHostedCookieLoginPhase() async throws {
        let transport = try cookiePhase("login", requiresCredentials: true)
        let credentials = try await stage("credentials") {
            try Self.readCredentials()
        }
        Self.clearHostedCookies(for: transport.baseURL)
        let api = Self.makeAPIClient(transport: transport)

        var loggedIn = false
        do {
            let login = try await stage("cookie login") {
                try await api.directPasswordLogin(
                    username: credentials.username,
                    password: credentials.password
                )
            }
            guard login.ok == true else {
                throw LiveSmokeInvariant.failed
            }
            loggedIn = true

            try await stage("cookie login protected probe") {
                try await api.directProtectedProbe()
            }
            guard HTTPCookieStorage.shared.cookies(for: transport.baseURL)?.isEmpty == false else {
                throw LiveSmokeInvariant.failed
            }
            UserDefaults.standard.set(ProcessInfo.processInfo.processIdentifier, forKey: "SemrehSlice1CookieLoginPID")
            print("Slice1 cookie login host PID: \(ProcessInfo.processInfo.processIdentifier)")
        } catch {
            if loggedIn {
                try? await api.directLogout()
            }
            throw error
        }
    }

    func testOptInHostedCookieRestorePhase() async throws {
        let transport = try cookiePhase("restore", requiresCredentials: false)
        let api = Self.makeAPIClient(transport: transport)

        // Deliberately does not read the credentials file or call login.
        let loginPID = UserDefaults.standard.integer(forKey: "SemrehSlice1CookieLoginPID")
        guard loginPID > 0, loginPID != Int(ProcessInfo.processInfo.processIdentifier) else {
            throw LiveSmokeInvariant.failed
        }
        try await stage("cookie restore protected probe") {
            try await api.directProtectedProbe()
        }
        print("Slice1 cookie restore host PID: \(ProcessInfo.processInfo.processIdentifier); login PID: \(loginPID)")
    }

    func testOptInHostedCookieLogoutPhase() async throws {
        let transport = try cookiePhase("logout", requiresCredentials: false)
        let api = Self.makeAPIClient(transport: transport)

        var loggedIn = true
        do {
            // Deliberately does not read the credentials file or call login.
            try await stage("cookie cleanup protected probe") {
                try await api.directProtectedProbe()
            }
            try await stage("cookie logout") {
                try await api.directLogout()
            }
            loggedIn = false
            UserDefaults.standard.removeObject(forKey: "SemrehSlice1CookieLoginPID")
            try await stage("cookie logout expiry") {
                do {
                    try await api.directProtectedProbe()
                    throw LiveSmokeInvariant.failed
                } catch let error as DirectHermesAuthError {
                    guard error == .sessionExpired else {
                        throw LiveSmokeInvariant.failed
                    }
                } catch {
                    throw LiveSmokeInvariant.failed
                }
            }
        } catch {
            if loggedIn {
                try? await api.directLogout()
            }
            throw error
        }
    }

    private func cookiePhase(
        _ phase: String,
        requiresCredentials: Bool
    ) throws -> HostedTransport {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Slice 1 cookie phases are simulator-only.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE1_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE1_COOKIE_PHASE"] == phase
        else {
            throw XCTSkip("Slice 1 cookie phase is opt-in.")
        }
        if requiresCredentials,
           environment["SEMREH_SLICE1_CREDENTIALS_FILE"] != Self.credentialsPath {
            throw XCTSkip("Slice 1 cookie login requires the fixed private credentials path.")
        }
        return .https
        #endif
    }

    private static func makeAPIClient(
        transport: HostedTransport
    ) -> APIClient {
        // Use APIClient's production default URLSession: it is configured with
        // URLSessionConfiguration.default and HTTPCookieStorage.shared. Keep
        // only the custom-header override empty so no personal headers enter
        // this hosted smoke.
        APIClient(
            baseURL: transport.baseURL,
            customHeaderProvider: { [] }
        )
    }

    private static func clearHostedCookies(for baseURL: URL) {
        let host = baseURL.host ?? ""
        for cookie in HTTPCookieStorage.shared.cookies ?? [] {
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if domain == host {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    private func runHostedSmoke(transport: HostedTransport) async throws {
        let credentials = try await stage("credentials") {
            try Self.readCredentials()
        }

        let configuration = URLSessionConfiguration.ephemeral
        if let hostHeader = transport.hostHeader {
            configuration.httpAdditionalHeaders = ["Host": hostHeader]
        } else {
            configuration.httpAdditionalHeaders = [:]
        }
        // Ephemeral URLSession supplies a private in-memory cookie store. Do
        // not use HTTPCookieStorage.shared: the smoke test must not touch a
        // user's persisted server accounts.
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = APIClient(
            baseURL: transport.baseURL,
            session: session,
            publicMediaSession: session,
            customHeaderProvider: { [] }
        )

        var gateway: HermesGatewayClient?
        var connected = false
        var loggedIn = false
        var sessionID: String?

        do {
            let status = try await stage("status") {
                try await api.directStatus()
            }
            guard status.authRequired == true else {
                throw LiveSmokeInvariant.failed
            }

            let providers = try await stage("providers") {
                try await api.directProviders()
            }
            guard providers.providers?.contains(where: { $0.name == "basic" && $0.supportsPassword == true }) == true else {
                throw LiveSmokeInvariant.failed
            }

            let login = try await stage("login") {
                try await api.directPasswordLogin(
                    username: credentials.username,
                    password: credentials.password
                )
            }
            guard login.ok == true else {
                throw LiveSmokeInvariant.failed
            }
            loggedIn = true

            try await stage("protected probe") {
                try await api.directProtectedProbe()
            }

            let events = LiveGatewayEventCapture()
            let client = HermesGatewayClient(
                gatewayURL: transport.gatewayURL,
                ticketProvider: {
                    let response = try await api.directWSTicket()
                    guard let ticket = response.ticket,
                          !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else {
                        throw LiveSmokeInvariant.failed
                    }
                    return ticket
                },
                requestTimeout: .seconds(30),
                eventHandler: { event in
                    Task { await events.append(event) }
                },
                urlSessionConfiguration: configuration
            )
            gateway = client

            try await stage("gateway connect") {
                try await client.connect()
            }
            connected = true

            _ = try await stage("gateway ping") {
                try await client.ping(timeout: .seconds(30))
            }

            let createResult = try await stage("session create") {
                try await client.request(
                    method: "session.create",
                    params: .object([
                        "cwd": .string("/Users/maurice/workspace/semreh-slice1-runtime/tools"),
                        "model": .string("semreh-fixture"),
                        "provider": .string("custom")
                    ]),
                    timeout: .seconds(30)
                )
            }
            guard let createObject = objectValue(createResult),
                  let createdSessionID = stringValue(createObject["session_id"]),
                  let storedSessionID = stringValue(createObject["stored_session_id"])
            else {
                throw LiveSmokeInvariant.failed
            }
            sessionID = createdSessionID

            let promptResult = try await stage("prompt submit") {
                try await client.request(
                    method: "prompt.submit",
                    params: .object([
                        "session_id": .string(createdSessionID),
                        "text": .string("SEMREH_SLICE1_PROMPT")
                    ]),
                    timeout: .seconds(30)
                )
            }
            guard stringValue(objectValue(promptResult)?["status"]) == "streaming" else {
                throw LiveSmokeInvariant.failed
            }

            let completeEvent = try await stage("prompt terminal event") {
                try await events.wait { event in
                    event.sessionID == createdSessionID && event.type == "message.complete"
                }
            }
            guard stringValue(objectValue(completeEvent.payload)?["text"]) == "SEMREH_SLICE1_ACK",
                  stringValue(objectValue(completeEvent.payload)?["status"]) == "complete"
            else {
                throw LiveSmokeInvariant.failed
            }
            let firstTerminalSequence = completeEvent.sequence ?? -1

            try await stage("durable transcript") {
                try await Self.verifyDurableTranscript(
                    session: session,
                    baseURL: transport.baseURL,
                    storedSessionID: storedSessionID
                )
            }

            let interruptPromptResult = try await stage("interrupt prompt submit") {
                try await client.request(
                    method: "prompt.submit",
                    params: .object([
                        "session_id": .string(createdSessionID),
                        "text": .string("SEMREH_INTERRUPT_FIXTURE")
                    ]),
                    timeout: .seconds(30)
                )
            }
            guard stringValue(objectValue(interruptPromptResult)?["status"]) == "streaming" else {
                throw LiveSmokeInvariant.failed
            }

            _ = try await stage("interrupt start event") {
                try await events.wait { event in
                    event.sessionID == createdSessionID
                        && event.type == "message.start"
                        && (event.sequence ?? -1) > firstTerminalSequence
                }
            }

            let interruptResult = try await stage("session interrupt") {
                try await client.request(
                    method: "session.interrupt",
                    params: .object(["session_id": .string(createdSessionID)]),
                    timeout: .seconds(30)
                )
            }
            guard stringValue(objectValue(interruptResult)?["status"]) == "interrupted" else {
                throw LiveSmokeInvariant.failed
            }

            let interruptedEvent = try await stage("interrupt terminal event") {
                try await events.wait { event in
                    event.sessionID == createdSessionID
                        && event.type == "message.complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "interrupted"
                }
            }
            guard stringValue(objectValue(interruptedEvent.payload)?["status"]) == "interrupted" else {
                throw LiveSmokeInvariant.failed
            }

            let statusResult = try await stage("session status") {
                try await client.request(
                    method: "session.status",
                    params: .object(["session_id": .string(createdSessionID)]),
                    timeout: .seconds(30)
                )
            }
            guard stringValue(objectValue(statusResult)?["output"])?.contains("Agent Running: No") == true else {
                throw LiveSmokeInvariant.failed
            }
        } catch {
            if connected, let gateway, let sessionID {
                _ = try? await gateway.request(
                    method: "session.close",
                    params: .object(["session_id": .string(sessionID)]),
                    timeout: .seconds(30)
                )
            }
            if let gateway {
                await gateway.close()
            }
            if loggedIn {
                try? await api.directLogout()
            }
            throw error
        }

        do {
            if connected, let gateway, let sessionID {
                _ = try await stage("session close") {
                    try await gateway.request(
                        method: "session.close",
                        params: .object(["session_id": .string(sessionID)]),
                        timeout: .seconds(30)
                    )
                }
            }
            if let gateway {
                await gateway.close()
            }
            if loggedIn {
                try await stage("logout") {
                    try await api.directLogout()
                }
                loggedIn = false
                try await stage("logout expiry") {
                    do {
                        try await api.directProtectedProbe()
                        throw LiveSmokeInvariant.failed
                    } catch let error as DirectHermesAuthError {
                        guard error == .sessionExpired else {
                            throw LiveSmokeInvariant.failed
                        }
                    } catch {
                        throw LiveSmokeInvariant.failed
                    }
                }
            }
        } catch {
            if connected, let gateway, let sessionID {
                _ = try? await gateway.request(
                    method: "session.close",
                    params: .object(["session_id": .string(sessionID)]),
                    timeout: .seconds(30)
                )
            }
            if let gateway {
                await gateway.close()
            }
            if loggedIn {
                try? await api.directLogout()
            }
            throw error
        }
    }

    private static func readCredentials() throws -> LiveCredentials {
        let data = try Data(contentsOf: URL(fileURLWithPath: credentialsPath), options: [.mappedIfSafe])
        return try JSONDecoder().decode(LiveCredentials.self, from: data)
    }

    private static func verifyDurableTranscript(
        session: URLSession,
        baseURL: URL,
        storedSessionID: String
    ) async throws {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("sessions")
                .appendingPathComponent(storedSessionID)
                .appendingPathComponent("messages"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "profile", value: "default"),
            URLQueryItem(name: "limit", value: "120"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "order", value: "latest"),
            URLQueryItem(name: "include_compacted", value: "true")
        ]
        guard let url = components?.url else {
            throw LiveSmokeInvariant.failed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]]
        else {
            throw LiveSmokeInvariant.failed
        }

        let durable = messages.filter { message in
            guard let role = message["role"] as? String else { return false }
            return role == "user" || role == "assistant"
        }
        guard durable.count == 2,
              durable[0]["role"] as? String == "user",
              durable[0]["content"] as? String == "SEMREH_SLICE1_PROMPT",
              durable[1]["role"] as? String == "assistant",
              durable[1]["content"] as? String == "SEMREH_SLICE1_ACK"
        else {
            throw LiveSmokeInvariant.failed
        }
    }

    private func stage<T>(
        _ name: String,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw LiveSmokeFailure.stage(name)
        }
    }

    private static func objectValue(_ value: JSONValue?) -> [String: JSONValue]? {
        guard let value else { return nil }
        if case let .object(object) = value { return object }
        return nil
    }

    private func objectValue(_ value: JSONValue?) -> [String: JSONValue]? {
        Self.objectValue(value)
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case let .string(string) = value { return string }
        return nil
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        Self.stringValue(value)
    }
}

private struct LiveCredentials: Decodable {
    let username: String
    let password: String
}

private enum LiveSmokeInvariant: Error {
    case failed
}

private enum LiveSmokeFailure: Error {
    case stage(String)

    var stage: String {
        switch self {
        case let .stage(value): return value
        }
    }
}

private actor LiveGatewayEventCapture {
    private struct Waiter {
        let predicate: @Sendable (HermesGatewayEvent) -> Bool
        let continuation: CheckedContinuation<HermesGatewayEvent, Error>
    }

    private var events: [HermesGatewayEvent] = []
    private var waiters: [Int: Waiter] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var nextWaiterID = 0

    func append(_ event: HermesGatewayEvent) {
        if let (id, waiter) = waiters.first(where: { $0.value.predicate(event) }) {
            waiters.removeValue(forKey: id)
            timers.removeValue(forKey: id)?.cancel()
            waiter.continuation.resume(returning: event)
        } else {
            events.append(event)
        }
    }

    func wait(
        timeout: Duration = .seconds(45),
        where predicate: @escaping @Sendable (HermesGatewayEvent) -> Bool
    ) async throws -> HermesGatewayEvent {
        if let index = events.firstIndex(where: predicate) {
            return events.remove(at: index)
        }

        nextWaiterID += 1
        let id = nextWaiterID
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = Waiter(predicate: predicate, continuation: continuation)
            timers[id] = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                    await self?.timeout(id: id)
                } catch {
                    // A matching event cancels this timer.
                }
            }
        }
    }

    private func timeout(id: Int) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        timers.removeValue(forKey: id)
        waiter.continuation.resume(throwing: LiveSmokeInvariant.failed)
    }
}
