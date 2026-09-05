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
    private static let baseURL = URL(string: "http://127.0.0.1:18791")!
    private static let gatewayURL = URL(string: "ws://127.0.0.1:18791/api/ws")!

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
            try await runHostedSmoke()
        } catch let failure as LiveSmokeFailure {
            XCTFail("Slice 1 hosted smoke failed at \(failure.stage).")
        } catch {
            XCTFail("Slice 1 hosted smoke failed.")
        }
    }

    private func runHostedSmoke() async throws {
        let credentials = try await stage("credentials") {
            try Self.readCredentials()
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["Host": "semreh-slice1.test:18791"]
        // Ephemeral URLSession supplies a private in-memory cookie store. Do
        // not use HTTPCookieStorage.shared: the smoke test must not touch a
        // user's persisted server accounts.
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = APIClient(
            baseURL: Self.baseURL,
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
                gatewayURL: Self.gatewayURL,
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
