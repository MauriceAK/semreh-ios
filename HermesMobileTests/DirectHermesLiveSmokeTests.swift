import Foundation
import XCTest
@testable import HermesMobile

/// Opt-in hosted smoke coverage for the pinned local Slice 1 deployment.
///
/// This is deliberately not part of the default XCTest path. The hosted
/// runner must set both environment variables, and the credentials file is
/// required to remain outside the source tree.
final class DirectHermesLiveSmokeTests: XCTestCase {
    private static let defaultCredentialsPath = "/Users/maurice/workspace/semreh-slice1-runtime/credentials.json"
    private static let developmentCredentialsPath = "/Users/maurice/workspace/semreh-slice2-runtime/credentials.json"
    private static let stockBackendSHA = "29112bef099274229cadff79cdff7bf7b99c4b77"
    private static let stockToolCwd = "/Users/maurice/workspace/semreh-slice1-runtime/tools"
    private static let developmentToolCwd = "/Users/maurice/workspace/semreh-slice2-runtime/tools"
    private static let recoveryPNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

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
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == Self.defaultCredentialsPath
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

    @MainActor
    func testOptInHostedSlice2ConversationFoundation() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Slice 2 hosted smoke is simulator-only.")
        #endif

        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE1_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == Self.defaultCredentialsPath
        else {
            throw XCTSkip("Slice 2 hosted smoke is opt-in.")
        }

        do {
            // This foundation gate intentionally never selects the loopback
            // transport, even when the older Slice 1 smoke does.
            try await runHostedSlice2ConversationFoundation(transport: .https)
        } catch let failure as LiveSmokeFailure {
            XCTFail("Slice 2 conversation foundation failed at \(failure.stage).")
        } catch {
            XCTFail("Slice 2 conversation foundation failed.")
        }
    }

    @MainActor
    func testOptInHostedSlice2NativeChatFlow() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Slice 2 native chat smoke is simulator-only.")
        #endif

        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE1_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == Self.defaultCredentialsPath
        else {
            throw XCTSkip("Slice 2 native chat smoke is opt-in.")
        }

        do {
            try await runHostedSlice2NativeChatFlow(transport: .https)
        } catch let failure as LiveSmokeFailure {
            XCTFail("Slice 2 native chat smoke failed at \(failure.stage).")
        } catch {
            XCTFail("Slice 2 native chat smoke failed.")
        }
    }

    @MainActor
    func testOptInHostedSlice2NativeReasoning() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Slice 2 reasoning smoke is simulator-only.")
        #endif

        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE1_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE2_REASONING"] == "1"
        else {
            throw XCTSkip("Slice 2 reasoning smoke is opt-in.")
        }
        let stock = environment["SEMREH_SLICE2_STOCK_BACKEND_SHA"] == Self.stockBackendSHA
            && environment["SEMREH_SLICE2_DEVELOPMENT_BACKEND_SHA"] == nil
            && environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == Self.defaultCredentialsPath
            && environment["SEMREH_SLICE2_TOOL_CWD"] == Self.stockToolCwd
        let development = environment["SEMREH_SLICE2_STOCK_BACKEND_SHA"] == nil
            && environment["SEMREH_SLICE2_DEVELOPMENT_BACKEND_SHA"]?.isEmpty == false
            && environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == Self.developmentCredentialsPath
            && environment["SEMREH_SLICE2_TOOL_CWD"] == Self.developmentToolCwd
        guard stock != development else { throw XCTSkip("Slice 2 reasoning backend mode is invalid.") }

        do {
            try await runHostedSlice2NativeReasoning(transport: .https, stockBackend: stock)
        } catch let failure as LiveSmokeFailure {
            XCTFail("Slice 2 native reasoning smoke failed at \(failure.stage).")
        } catch {
            XCTFail("Slice 2 native reasoning smoke failed.")
        }
    }

    @MainActor
    func testOptInHostedSlice4SessionMetadataConsumers() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Slice 4 session metadata smoke is simulator-only.")
        #endif

        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE1_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE4_SESSION_METADATA_NATIVE"] == "1",
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == Self.defaultCredentialsPath,
              environment["SEMREH_SLICE2_STOCK_BACKEND_SHA"] == Self.stockBackendSHA,
              environment["SEMREH_SLICE2_TOOL_CWD"] == Self.stockToolCwd
        else {
            throw XCTSkip("Slice 4 session metadata smoke is opt-in for the pinned stock HTTPS fixture.")
        }

        do {
            try await runHostedSlice4SessionMetadataConsumers()
        } catch let failure as LiveSmokeFailure {
            XCTFail("Slice 4 session metadata smoke failed at \(failure.stage).")
        } catch {
            XCTFail("Slice 4 session metadata smoke failed.")
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
           environment["SEMREH_SLICE1_CREDENTIALS_FILE"] != Self.defaultCredentialsPath {
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

    @MainActor
    private func runHostedSlice2ConversationFoundation(transport: HostedTransport) async throws {
        let credentials = try await stage("slice2 credentials") {
            try Self.readCredentials()
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [:]
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

        var runtime: HermesServerRuntime?
        var loggedIn = false
        var cleanupRuntimeID: String?

        do {
            let status = try await stage("slice2 status") { try await api.directStatus() }
            guard status.authRequired == true else { throw LiveSmokeInvariant.failed }
            let providers = try await stage("slice2 providers") { try await api.directProviders() }
            guard providers.providers?.contains(where: { $0.name == "basic" && $0.supportsPassword == true }) == true else {
                throw LiveSmokeInvariant.failed
            }
            let login = try await stage("slice2 login") {
                try await api.directPasswordLogin(username: credentials.username, password: credentials.password)
            }
            guard login.ok == true else { throw LiveSmokeInvariant.failed }
            loggedIn = true
            try await stage("slice2 protected probe") { try await api.directProtectedProbe() }

            let serverRuntime = try await stage("slice2 runtime init") {
                try HermesServerRuntime(origin: transport.baseURL, client: api)
            }
            runtime = serverRuntime
            try await stage("slice2 runtime connect") { try await serverRuntime.connect() }

            let events = LiveGatewayEventCapture()
            let draft = GatewayConversationController(
                runtime: serverRuntime,
                storedID: nil,
                profile: "default",
                loadTranscript: { id, profile, limit, offset in
                    try await api.directSessionMessages(
                        sessionID: id,
                        profile: profile,
                        limit: limit,
                        offset: offset
                    )
                }
            )
            draft.onEvent = { event in Task { await events.append(event) } }

            // Opening a local draft is deliberately side-effect free; the
            // first submit is the one operation that creates the durable row.
            try await stage("slice2 local draft open") { try await draft.open() }
            try await stage("slice2 first create") { try await draft.submit("SEMREH_SLICE2_TURN_01") }
            guard let runtimeID = draft.binding?.runtimeID,
                  let firstStoredID = draft.storedID
            else { throw LiveSmokeInvariant.failed }
            cleanupRuntimeID = runtimeID

            let firstComplete = try await stage("slice2 turn 1 terminal") {
                try await events.wait { event in
                    event.sessionID == runtimeID
                        && event.type == "message.complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "complete"
                }
            }
            var lastSequence = firstComplete.sequence ?? -1
            for turn in 2...10 {
                let prompt = String(format: "SEMREH_SLICE2_TURN_%02d", turn)
                try await stage("slice2 turn \(turn) submit") {
                    try await draft.submit(prompt)
                }
                let minimumSequence = lastSequence
                let complete = try await stage("slice2 turn \(turn) terminal") {
                    try await events.wait { event in
                        event.sessionID == runtimeID
                            && event.type == "message.complete"
                            && (event.sequence ?? -1) > minimumSequence
                            && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "complete"
                    }
                }
                lastSequence = complete.sequence ?? lastSequence
            }

            let transcript = try await stage("slice2 canonical ten-turn transcript") {
                try await api.directSessionMessages(
                    sessionID: firstStoredID,
                    profile: "default",
                    limit: 500,
                    offset: 0
                )
            }
            let canonicalMessages = transcript.messages.filter { $0.role == "user" || $0.role == "assistant" }
            let users = canonicalMessages.filter { $0.role == "user" }
            let assistants = canonicalMessages.filter { $0.role == "assistant" }
            let expectedPrompts = (1...10).map { String(format: "SEMREH_SLICE2_TURN_%02d", $0) }
            guard users.count == 10,
                  assistants.count == 10,
                  users.compactMap(\.content) == expectedPrompts
            else { throw LiveSmokeInvariant.failed }

            let discovered = try await stage("slice2 direct session discovery") {
                try await api.directSessions(profile: "default", limit: 500, offset: 0)
            }
            guard discovered.sessions.filter({ $0.sessionId == firstStoredID }).count == 1 else {
                throw LiveSmokeInvariant.failed
            }

            try await stage("slice2 first controller dispose") { try await draft.dispose() }
            let resumed = GatewayConversationController(
                runtime: serverRuntime,
                storedID: firstStoredID,
                profile: "default",
                loadTranscript: { id, profile, limit, offset in
                    try await api.directSessionMessages(
                        sessionID: id,
                        profile: profile,
                        limit: limit,
                        offset: offset
                    )
                }
            )
            resumed.onEvent = { event in Task { await events.append(event) } }
            try await stage("slice2 second controller resume") { try await resumed.open() }
            guard resumed.binding?.runtimeID.isEmpty == false,
                  resumed.storedID == transcript.sessionID
            else { throw LiveSmokeInvariant.failed }

            let generationBeforeReconnect = serverRuntime.connectionGeneration
            try await stage("slice2 shared runtime reconnect") { try await serverRuntime.reconnect() }
            guard serverRuntime.connectionGeneration > generationBeforeReconnect,
                  resumed.binding?.runtimeID.isEmpty == false,
                  resumed.storedID == transcript.sessionID
            else { throw LiveSmokeInvariant.failed }

            let rediscovered = try await stage("slice2 post-reconnect discovery") {
                try await api.directSessions(profile: "default", limit: 500, offset: 0)
            }
            guard rediscovered.sessions.filter({ $0.sessionId == firstStoredID }).count == 1 else {
                throw LiveSmokeInvariant.failed
            }

            // The pinned fixture delays this prompt until the controller's
            // interrupt RPC. This proves the controller's server-side stop
            // path rather than merely toggling local state.
            let interruptRuntimeID = try XCTUnwrap(resumed.binding?.runtimeID)
            cleanupRuntimeID = interruptRuntimeID
            let interruptMinimumSequence = lastSequence
            try await stage("slice2 interrupt fixture submit") {
                try await resumed.submit("SEMREH_INTERRUPT_FIXTURE")
            }
            _ = try await stage("slice2 interrupt fixture start") {
                try await events.wait { event in
                    event.sessionID == interruptRuntimeID
                        && event.type == "message.start"
                        && (event.sequence ?? -1) > interruptMinimumSequence
                }
            }
            try await stage("slice2 controller interrupt") { try await resumed.interrupt() }
            _ = try await stage("slice2 interrupt fixture terminal") {
                try await events.wait { event in
                    event.sessionID == interruptRuntimeID
                        && event.type == "message.complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "interrupted"
                }
            }

            try await resumed.dispose()
            await serverRuntime.stop()
            runtime = nil
            try await stage("slice2 logout") { try await api.directLogout() }
            loggedIn = false
        } catch {
            if let runtime, let cleanupRuntimeID {
                _ = try? await runtime.request(
                    "session.close",
                    params: ["session_id": .string(cleanupRuntimeID), "profile": .string("default")],
                    timeout: .seconds(30)
                )
            }
            if let runtime { await runtime.stop() }
            if loggedIn { try? await api.directLogout() }
            throw error
        }
    }

    @MainActor
    private func runHostedSlice4SessionMetadataConsumers() async throws {
        let credentials = try await stage("slice4 metadata credentials") { try Self.readCredentials() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [:]
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = APIClient(
            baseURL: HostedTransport.https.baseURL,
            session: session,
            publicMediaSession: session,
            customHeaderProvider: { [] }
        )
        var runtime: HermesServerRuntime?
        var controllers: [GatewayConversationController] = []
        var ownedRuntimeIDs: [String] = []
        var originals: [String: SessionSummary] = [:]
        var loggedIn = false

        do {
            let status = try await stage("slice4 metadata status") { try await api.directStatus() }
            guard status.authRequired == true else { throw LiveSmokeInvariant.failed }
            let login = try await stage("slice4 metadata login") {
                try await api.directPasswordLogin(username: credentials.username, password: credentials.password)
            }
            guard login.ok == true else { throw LiveSmokeInvariant.failed }
            loggedIn = true
            try await stage("slice4 metadata protected probe") { try await api.directProtectedProbe() }

            let serverRuntime = try await stage("slice4 metadata runtime init") {
                try HermesServerRuntime(origin: HostedTransport.https.baseURL, client: api)
            }
            runtime = serverRuntime
            try await stage("slice4 metadata runtime connect") { try await serverRuntime.connect() }
            let create: [String: JSONValue] = [
                "cwd": .string(Self.stockToolCwd),
                "model": .string("semreh-fixture"),
                "provider": .string("custom")
            ]

            for index in 1...2 {
                let events = LiveGatewayEventCapture()
                let controller = GatewayConversationController(
                    runtime: serverRuntime,
                    client: api,
                    storedID: nil,
                    profile: "default"
                )
                controller.onEvent = { event in Task { await events.append(event) } }
                controller.onBinding = { binding in
                    if !ownedRuntimeIDs.contains(binding.runtimeID) {
                        ownedRuntimeIDs.append(binding.runtimeID)
                    }
                }
                controllers.append(controller)
                try await stage("slice4 metadata create \(index)") {
                    try await controller.submit("SEMREH_SLICE1_PROMPT", create: create)
                }
                let runtimeID = try XCTUnwrap(controller.binding?.runtimeID)
                if !ownedRuntimeIDs.contains(runtimeID) { ownedRuntimeIDs.append(runtimeID) }
                _ = try await stage("slice4 metadata terminal \(index)") {
                    try await events.wait { event in
                        event.sessionID == runtimeID
                            && event.type == "message.complete"
                            && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "complete"
                    }
                }
                let storedID = try XCTUnwrap(controller.storedID)
                originals[storedID] = try await stage("slice4 metadata baseline detail \(index)") {
                    try await api.directSessionDetail(sessionID: storedID, profile: "default")
                }
            }

            let storedIDs = Array(originals.keys)
            guard storedIDs.count == 2,
                  let targetID = storedIDs.first,
                  let siblingID = storedIDs.last,
                  targetID != siblingID,
                  let targetOriginal = originals[targetID],
                  let siblingOriginal = originals[siblingID],
                  targetOriginal.title != nil,
                  targetOriginal.pinned == false,
                  targetOriginal.archived == false
            else { throw LiveSmokeInvariant.failed }
            let baselineTranscript = try await stage("slice4 metadata transcript baseline") {
                try await api.directSessionMessages(sessionID: targetID, profile: "default")
            }

            let list = SessionListViewModel(server: HostedTransport.https.baseURL, client: api)
            guard try await stage("slice4 metadata list load", operation: { await list.load() }),
                  let target = list.sessions.first(where: { $0.sessionId == targetID })
            else { throw LiveSmokeInvariant.failed }
            let changedTitle = "SEMREH_SLICE4_METADATA_\(UUID().uuidString)"
            guard try await stage("slice4 metadata rename consumer", operation: {
                await list.rename(target, to: changedTitle)
            }) else { throw LiveSmokeInvariant.failed }
            let renamed = try await api.directSessionDetail(sessionID: targetID, profile: "default")
            guard renamed.title == changedTitle else { throw LiveSmokeInvariant.failed }

            let renamedTarget = list.sessions.first(where: { $0.sessionId == targetID }) ?? renamed
            guard try await stage("slice4 metadata pin consumer", operation: {
                await list.setPinned(true, for: renamedTarget)
            }) else { throw LiveSmokeInvariant.failed }
            let pinned = try await api.directSessionDetail(sessionID: targetID, profile: "default")
            guard pinned.title == changedTitle, pinned.pinned == true else { throw LiveSmokeInvariant.failed }

            let pinnedTarget = list.sessions.first(where: { $0.sessionId == targetID }) ?? pinned
            guard try await stage("slice4 metadata archive consumer", operation: {
                await list.archive(pinnedTarget)
            }) else { throw LiveSmokeInvariant.failed }
            let archived = try await api.directSessionDetail(sessionID: targetID, profile: "default")
            guard archived.title == changedTitle, archived.pinned == true, archived.archived == true else {
                throw LiveSmokeInvariant.failed
            }

            let archivedList = ArchivedSessionsViewModel(
                server: HostedTransport.https.baseURL,
                profile: "default",
                client: api
            )
            try await stage("slice4 metadata archived collection") { await archivedList.load() }
            guard let archivedTarget = archivedList.sessions.first(where: { $0.sessionId == targetID }),
                  try await stage("slice4 metadata unarchive consumer", operation: {
                      await archivedList.unarchive(archivedTarget)
                  })
            else { throw LiveSmokeInvariant.failed }
            let unarchived = try await api.directSessionDetail(sessionID: targetID, profile: "default")
            guard unarchived.title == changedTitle, unarchived.pinned == true, unarchived.archived == false else {
                throw LiveSmokeInvariant.failed
            }

            let siblingAfter = try await stage("slice4 metadata sibling unchanged") {
                try await api.directSessionDetail(sessionID: siblingID, profile: "default")
            }
            guard siblingAfter == siblingOriginal else { throw LiveSmokeInvariant.failed }
            let transcriptAfter = try await stage("slice4 metadata transcript unchanged") {
                try await api.directSessionMessages(sessionID: targetID, profile: "default")
            }
            guard transcriptAfter == baselineTranscript else { throw LiveSmokeInvariant.failed }

            try await stage("slice4 metadata restore") {
                try await restoreSlice4Metadata(api: api, originals: originals)
            }
            originals = [:]
            try await stage("slice4 metadata owned runtime cleanup") {
                try await closeSlice4Runtimes(runtime: serverRuntime, runtimeIDs: ownedRuntimeIDs)
            }
            ownedRuntimeIDs = []
            for controller in controllers { try await controller.dispose() }
            controllers = []
            await serverRuntime.stop()
            runtime = nil
            try await stage("slice4 metadata logout") { try await api.directLogout() }
            loggedIn = false
        } catch {
            try? await restoreSlice4Metadata(api: api, originals: originals)
            if let runtime { try? await closeSlice4Runtimes(runtime: runtime, runtimeIDs: ownedRuntimeIDs) }
            for controller in controllers { try? await controller.dispose() }
            if let runtime { await runtime.stop() }
            if loggedIn { try? await api.directLogout() }
            throw error
        }
    }

    private func restoreSlice4Metadata(
        api: APIClient,
        originals: [String: SessionSummary]
    ) async throws {
        var failed = false
        for (sessionID, original) in originals {
            guard let title = original.title,
                  let pinned = original.pinned,
                  let archived = original.archived else {
                failed = true
                continue
            }
            do {
                _ = try await api.directMutateSession(sessionID: sessionID, operation: .title(title))
                _ = try await api.directMutateSession(sessionID: sessionID, operation: .pinned(pinned))
                _ = try await api.directMutateSession(sessionID: sessionID, operation: .archived(archived))
                let restored = try await api.directSessionDetail(sessionID: sessionID)
                guard restored.title == title,
                      restored.pinned == pinned,
                      restored.archived == archived else {
                    failed = true
                    continue
                }
            } catch {
                failed = true
            }
        }
        if failed { throw LiveSmokeInvariant.failed }
    }

    private func closeSlice4Runtimes(
        runtime: HermesServerRuntime,
        runtimeIDs: [String]
    ) async throws {
        var failed = false
        for runtimeID in runtimeIDs {
            do {
                let result = try await runtime.request("session.close", params: [
                    "session_id": .string(runtimeID),
                    "profile": .string("default")
                ])
                guard case .bool = result?.gatewayFields["closed"] else {
                    failed = true
                    continue
                }
            } catch {
                failed = true
            }
        }
        if failed { throw LiveSmokeInvariant.failed }
    }

    @MainActor
    private func runHostedSlice2NativeChatFlow(transport: HostedTransport) async throws {
        let credentials = try await stage("native chat credentials") {
            try Self.readCredentials()
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [:]
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

        var runtime: HermesServerRuntime?
        var firstViewModel: ChatViewModel?
        var secondViewModel: ChatViewModel?
        var loggedIn = false

        do {
            let status = try await stage("native chat status") { try await api.directStatus() }
            guard status.authRequired == true else { throw LiveSmokeInvariant.failed }
            let providers = try await stage("native chat providers") { try await api.directProviders() }
            guard providers.providers?.contains(where: { $0.name == "basic" && $0.supportsPassword == true }) == true else {
                throw LiveSmokeInvariant.failed
            }
            let login = try await stage("native chat login") {
                try await api.directPasswordLogin(username: credentials.username, password: credentials.password)
            }
            guard login.ok == true else { throw LiveSmokeInvariant.failed }
            loggedIn = true
            try await stage("native chat protected probe") { try await api.directProtectedProbe() }

            let serverRuntime = try await stage("native chat runtime init") {
                try HermesServerRuntime(origin: transport.baseURL, client: api)
            }
            runtime = serverRuntime
            try await stage("native chat runtime connect") { try await serverRuntime.connect() }

            let prompt = "SEMREH_SLICE1_PROMPT"
            let expectedAck = "SEMREH_SLICE1_ACK"
            var durableID: String?
            let first = ChatViewModel(
                session: SessionSummary(sessionId: nil, title: "Native Slice 2 smoke", profile: "default"),
                server: transport.baseURL,
                client: api,
                liveActivityManager: NativeSmokeNoopLiveActivityManager(),
                gatewayRuntimeProvider: { _ in serverRuntime }
            )
            first.onDirectCanonicalID = { id in durableID = id }
            firstViewModel = first

            try await stage("native draft profiled model inventory") {
                await first.loadComposerConfiguration()
                guard first.composerConfigurationErrorMessage == nil,
                      first.selectedModelID == "semreh-fixture",
                      !first.hasServerBackedSession else { throw LiveSmokeInvariant.failed }
            }

            try await stage("native chat first send accepted") {
                guard await first.sendMessage(prompt) else { throw LiveSmokeInvariant.failed }
            }
            try await stage("native chat first rendered canonical transcript") {
                try await waitForNativeTranscript(
                    in: first,
                    user: prompt,
                    assistant: expectedAck
                )
            }
            guard first.hasServerBackedSession,
                  let durableID,
                  !durableID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw LiveSmokeInvariant.failed }

            try await stage("native chat first view model dispose") {
                await first.disposeDirectConversation()
            }
            firstViewModel = nil

            var resumedID: String?
            let second = ChatViewModel(
                session: SessionSummary(sessionId: durableID, title: "Native Slice 2 smoke", profile: "default"),
                server: transport.baseURL,
                client: api,
                liveActivityManager: NativeSmokeNoopLiveActivityManager(),
                gatewayRuntimeProvider: { _ in serverRuntime }
            )
            second.onDirectCanonicalID = { id in resumedID = id }
            secondViewModel = second

            try await stage("native chat second view model resume") {
                await second.loadMessages()
                guard second.lastError == nil, second.errorMessage == nil else {
                    throw LiveSmokeInvariant.failed
                }
            }
            try await stage("native chat resumed canonical transcript") {
                try await waitForNativeTranscript(
                    in: second,
                    user: prompt,
                    assistant: expectedAck
                )
            }
            try await stage("native chat canonical identity unchanged") {
                // The VM callback reports changes, not a redundant attachment
                // to the durable ID it already owns from the initializer.
                guard second.hasServerBackedSession, (resumedID ?? durableID) == durableID else {
                    throw LiveSmokeInvariant.failed
                }
            }

            await second.disposeDirectConversation()
            secondViewModel = nil
            await serverRuntime.stop()
            runtime = nil
            try await stage("native chat logout") { try await api.directLogout() }
            loggedIn = false
        } catch {
            if let secondViewModel { await secondViewModel.disposeDirectConversation() }
            if let firstViewModel { await firstViewModel.disposeDirectConversation() }
            if let runtime { await runtime.stop() }
            if loggedIn { try? await api.directLogout() }
            throw error
        }
    }

    @MainActor
    func testOptInHostedSlice3NativeAttachmentRecovery() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Slice 3 native recovery smoke is simulator-only.")
        #endif

        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE1_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE3_RECOVERY_NATIVE"] == "1",
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == Self.defaultCredentialsPath,
              environment["SEMREH_SLICE2_STOCK_BACKEND_SHA"] == Self.stockBackendSHA,
              environment["SEMREH_SLICE2_TOOL_CWD"] == Self.stockToolCwd
        else {
            throw XCTSkip("Slice 3 native recovery smoke is opt-in for the pinned stock HTTPS fixture.")
        }

        let credentials = try await stage("slice3 recovery credentials") {
            try Self.readCredentials()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [:]
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = APIClient(
            baseURL: HostedTransport.https.baseURL,
            session: session,
            publicMediaSession: session,
            customHeaderProvider: { [] }
        )

        let markerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemrehSlice3Recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: markerRoot) }
        let markerStore = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: markerRoot)
        var runtime: HermesServerRuntime?
        var first: GatewayConversationController?
        var second: GatewayConversationController?
        var resumed: GatewayConversationController?
        var loggedIn = false
        var cleanupRuntimeID: String?
        let events = LiveGatewayEventCapture()
        let seedPrompt = "SEMREH_SLICE1_PROMPT"
        let expectedAck = "SEMREH_SLICE1_ACK"
        let postResetPrompt = "SEMREH_SLICE3_RECOVERY_POST_RESET_\(UUID().uuidString)"
        let stockFixtureCreate: [String: JSONValue] = [
            "cwd": .string(Self.stockToolCwd),
            "model": .string("semreh-fixture"),
            "provider": .string("custom")
        ]

        do {
            let status = try await stage("slice3 recovery status") { try await api.directStatus() }
            guard status.authRequired == true else { throw LiveSmokeInvariant.failed }
            let providers = try await stage("slice3 recovery providers") { try await api.directProviders() }
            guard providers.providers?.contains(where: { $0.name == "basic" && $0.supportsPassword == true }) == true else {
                throw LiveSmokeInvariant.failed
            }
            let login = try await stage("slice3 recovery login") {
                try await api.directPasswordLogin(username: credentials.username, password: credentials.password)
            }
            guard login.ok == true else { throw LiveSmokeInvariant.failed }
            loggedIn = true
            try await stage("slice3 recovery protected probe") { try await api.directProtectedProbe() }

            let serverRuntime = try await stage("slice3 recovery runtime init") {
                try HermesServerRuntime(origin: HostedTransport.https.baseURL, client: api)
            }
            runtime = serverRuntime
            try await stage("slice3 recovery runtime connect") { try await serverRuntime.connect() }

            let initial = GatewayConversationController(
                runtime: serverRuntime,
                client: api,
                storedID: nil,
                profile: "default",
                recoveryMarkerStore: markerStore
            )
            initial.onEvent = { event in Task { await events.append(event) } }
            initial.onBinding = { binding in cleanupRuntimeID = binding.runtimeID }
            first = initial
            try await stage("slice3 recovery seed submit") {
                try await initial.submit(seedPrompt, create: stockFixtureCreate)
            }
            let seedRuntimeID = try await stage("slice3 recovery seed binding") {
                try XCTUnwrap(initial.binding?.runtimeID)
            }
            cleanupRuntimeID = seedRuntimeID
            _ = try await stage("slice3 recovery seed terminal") {
                try await events.wait { event in
                    event.sessionID == seedRuntimeID
                        && event.type == "message.complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "complete"
                }
            }
            let storedID = try await stage("slice3 recovery durable identity") {
                try XCTUnwrap(initial.storedID)
            }
            let baseline = try await stage("slice3 recovery baseline transcript") {
                try await api.directSessionMessages(sessionID: storedID, profile: "default")
            }
            try assertRecoveryTranscript(baseline, users: [seedPrompt], assistant: expectedAck)

            var pending = try DirectPendingAttachment(
                source: .image(data: Self.recoveryPNGData, filename: "recovery.png")
            )
            let staged = try await stage("slice3 recovery image stage") {
                try await initial.stageAttachment(pending)
            }
            guard staged.receipt.kind == .image,
                  staged.receipt.detachPaths.count == 1,
                  !staged.receipt.detachPaths[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw LiveSmokeInvariant.failed }
            guard let oldBinding = initial.binding,
                  let markerToken = initial.unresolvedAttachmentMarkerToken else {
                throw LiveSmokeInvariant.failed
            }
            cleanupRuntimeID = oldBinding.runtimeID
            let oldIdentity = try DirectGatewayAttachmentRecoveryIdentity(
                origin: HostedTransport.https.baseURL,
                profile: "default",
                storedID: storedID,
                runtimeID: oldBinding.runtimeID
            )
            let recreatedStore = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: markerRoot)
            guard try recreatedStore.load(for: oldIdentity)?.token == markerToken else {
                throw LiveSmokeInvariant.failed
            }
            _ = pending.confirm(
                scope: staged.scope,
                referenceText: staged.receipt.referenceText,
                serverDetachPaths: staged.receipt.detachPaths
            )

            try await stage("slice3 recovery first controller disposal") { try await initial.dispose() }
            first = nil

            let recreated = GatewayConversationController(
                runtime: serverRuntime,
                client: api,
                storedID: storedID,
                profile: "default",
                recoveryMarkerStore: recreatedStore
            )
            recreated.onEvent = { event in Task { await events.append(event) } }
            recreated.onBinding = { binding in cleanupRuntimeID = binding.runtimeID }
            second = recreated
            try await stage("slice3 recovery recreated controller resume") { try await recreated.open() }
            guard recreated.attachmentRecoveryNeedsReset,
                  recreated.unresolvedAttachmentMarkerToken == markerToken else {
                throw LiveSmokeInvariant.failed
            }
            do {
                _ = try await recreated.stageAttachment(
                    DirectPendingAttachment(source: .image(data: Self.recoveryPNGData, filename: "retry.png"))
                )
                throw LiveSmokeInvariant.failed
            } catch let error as DirectGatewayAttachmentStageError {
                guard case .definiteBeforeStage(kind: .image, reason: .unresolvedAttachment) = error else {
                    throw LiveSmokeInvariant.failed
                }
            }
            do {
                try await recreated.submit("SEMREH_SLICE3_RECOVERY_BLOCKED")
                throw LiveSmokeInvariant.failed
            } catch let error as DirectSessionError {
                guard case .unresolvedAttachment = error else { throw LiveSmokeInvariant.failed }
            }

            // This reset abandons the queued attachment. Stock session.close and
            // image.detach have no contract to delete the host image file, so
            // this smoke intentionally never attempts host-side file cleanup.
            try await stage("slice3 recovery explicit reset") {
                try await recreated.resetPendingAttachments(expectedToken: markerToken)
            }
            guard recreated.attachmentRecoveryNeedsReset == false,
                  try recreatedStore.load(for: oldIdentity) == nil else {
                throw LiveSmokeInvariant.failed
            }
            try await stage("slice3 recovery reset transcript preserved") {
                let afterReset = try await api.directSessionMessages(sessionID: storedID, profile: "default")
                guard afterReset.messages == baseline.messages else { throw LiveSmokeInvariant.failed }
                try assertRecoveryTranscript(afterReset, users: [seedPrompt], assistant: expectedAck)
            }
            try await stage("slice3 recovery second controller disposal") { try await recreated.dispose() }
            second = nil

            let reopened = GatewayConversationController(
                runtime: serverRuntime,
                client: api,
                storedID: storedID,
                profile: "default",
                recoveryMarkerStore: recreatedStore
            )
            reopened.onEvent = { event in Task { await events.append(event) } }
            reopened.onBinding = { binding in cleanupRuntimeID = binding.runtimeID }
            resumed = reopened
            try await stage("slice3 recovery fresh resume") { try await reopened.open() }
            guard reopened.attachmentRecoveryNeedsReset == false else { throw LiveSmokeInvariant.failed }
            let reopenedRuntimeID = try XCTUnwrap(reopened.binding?.runtimeID)
            cleanupRuntimeID = reopenedRuntimeID

            var removable = try DirectPendingAttachment(
                source: .image(data: Self.recoveryPNGData, filename: "known-removal.png")
            )
            let removalStage = try await stage("slice3 recovery known image stage") {
                try await reopened.stageAttachment(removable)
            }
            guard removalStage.receipt.kind == .image,
                  removalStage.receipt.detachPaths.count == 1,
                  let detachPath = removalStage.receipt.detachPaths.first,
                  !detachPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  removable.confirm(
                    scope: removalStage.scope,
                    referenceText: removalStage.receipt.referenceText,
                    serverDetachPaths: removalStage.receipt.detachPaths
                  ),
                  let reopenedBinding = reopened.binding else {
                throw LiveSmokeInvariant.failed
            }
            let removalIdentity = try DirectGatewayAttachmentRecoveryIdentity(
                origin: HostedTransport.https.baseURL,
                profile: "default",
                storedID: storedID,
                runtimeID: reopenedBinding.runtimeID
            )
            guard try recreatedStore.load(for: removalIdentity) != nil else {
                throw LiveSmokeInvariant.failed
            }
            try await stage("slice3 recovery known image removal") {
                try await reopened.removeStagedAttachment(removable)
            }
            guard reopened.attachmentRecoveryNeedsReset == false,
                  try recreatedStore.load(for: removalIdentity) == nil else {
                throw LiveSmokeInvariant.failed
            }
            try await stage("slice3 recovery known removal transcript preserved") {
                let afterRemoval = try await api.directSessionMessages(sessionID: storedID, profile: "default")
                guard afterRemoval.messages == baseline.messages else { throw LiveSmokeInvariant.failed }
                try assertRecoveryTranscript(afterRemoval, users: [seedPrompt], assistant: expectedAck)
            }
            try await stage("slice3 recovery post-reset plain submit") { try await reopened.submit(postResetPrompt) }
            _ = try await stage("slice3 recovery post-reset terminal") {
                try await events.wait { event in
                    event.sessionID == reopenedRuntimeID
                        && event.type == "message.complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "complete"
                }
            }
            let finalTranscript = try await stage("slice3 recovery final transcript") {
                try await api.directSessionMessages(sessionID: storedID, profile: "default")
            }
            guard finalTranscript.messages.count >= baseline.messages.count,
                  Array(finalTranscript.messages.prefix(baseline.messages.count)) == baseline.messages else {
                throw LiveSmokeInvariant.failed
            }
            try assertRecoveryTranscript(finalTranscript, users: [seedPrompt, postResetPrompt], assistant: expectedAck)

            try await stage("slice3 recovery owned runtime cleanup") {
                let closed = try await serverRuntime.request("session.close", params: [
                    "session_id": .string(reopenedRuntimeID),
                    "profile": .string("default")
                ])
                guard closed?.gatewayFields["closed"] == .bool(true) else {
                    throw LiveSmokeInvariant.failed
                }
            }
            cleanupRuntimeID = nil
            try await reopened.dispose()
            resumed = nil
            await serverRuntime.stop()
            runtime = nil
            try await stage("slice3 recovery logout") { try await api.directLogout() }
            loggedIn = false
        } catch {
            if let cleanupRuntimeID, let runtime {
                let closeResult = try? await runtime.request(
                    "session.close",
                    params: [
                        "session_id": .string(cleanupRuntimeID),
                        "profile": .string("default")
                    ],
                    timeout: .seconds(30)
                )
                if case .bool = closeResult?.gatewayFields["closed"] {
                    // True closed the owned runtime; false means it was absent.
                } else {
                    XCTFail("Owned recovery-test runtime cleanup was not confirmed.")
                }
            }
            if let resumed { try? await resumed.dispose() }
            if let second { try? await second.dispose() }
            if let first { try? await first.dispose() }
            if let runtime { await runtime.stop() }
            if loggedIn { try? await api.directLogout() }
            throw error
        }
    }

    @MainActor
    func testOptInHostedSlice3CompletedWhileAway() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Slice 3 completed-away smoke is simulator-only.")
        #endif

        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE1_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE3_COMPLETED_AWAY_NATIVE"] == "1",
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == Self.defaultCredentialsPath,
              environment["SEMREH_SLICE2_STOCK_BACKEND_SHA"] == Self.stockBackendSHA,
              environment["SEMREH_SLICE2_TOOL_CWD"] == Self.stockToolCwd
        else {
            throw XCTSkip("Slice 3 completed-away smoke is opt-in for the pinned stock HTTPS fixture.")
        }

        let credentials = try await stage("slice3 completed-away credentials") {
            try Self.readCredentials()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [:]
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = APIClient(
            baseURL: HostedTransport.https.baseURL,
            session: session,
            publicMediaSession: session,
            customHeaderProvider: { [] }
        )

        var runtime: HermesServerRuntime?
        var initial: GatewayConversationController?
        var reopened: GatewayConversationController?
        var loggedIn = false
        var cleanupRuntimeID: String?
        let events = LiveGatewayEventCapture()
        let seedPrompt = "SEMREH_SLICE1_PROMPT"
        let delayedPrompt = "SEMREH_INTERRUPT_FIXTURE SEMREH_RECOVERY_AFTER_ACCEPT"
        let expectedAck = "SEMREH_SLICE1_ACK"
        let stockFixtureCreate: [String: JSONValue] = [
            "cwd": .string(Self.stockToolCwd),
            "model": .string("semreh-fixture"),
            "provider": .string("custom")
        ]

        do {
            let status = try await stage("slice3 completed-away status") { try await api.directStatus() }
            guard status.authRequired == true else { throw LiveSmokeInvariant.failed }
            let providers = try await stage("slice3 completed-away providers") { try await api.directProviders() }
            guard providers.providers?.contains(where: { $0.name == "basic" && $0.supportsPassword == true }) == true else {
                throw LiveSmokeInvariant.failed
            }
            let login = try await stage("slice3 completed-away login") {
                try await api.directPasswordLogin(username: credentials.username, password: credentials.password)
            }
            guard login.ok == true else { throw LiveSmokeInvariant.failed }
            loggedIn = true
            try await stage("slice3 completed-away protected probe") { try await api.directProtectedProbe() }

            let serverRuntime = try await stage("slice3 completed-away runtime init") {
                try HermesServerRuntime(origin: HostedTransport.https.baseURL, client: api)
            }
            runtime = serverRuntime
            try await stage("slice3 completed-away runtime connect") { try await serverRuntime.connect() }

            let first = GatewayConversationController(
                runtime: serverRuntime,
                client: api,
                storedID: nil,
                profile: "default"
            )
            first.onEvent = { event in Task { await events.append(event) } }
            first.onBinding = { binding in cleanupRuntimeID = binding.runtimeID }
            initial = first
            try await stage("slice3 completed-away seed submit") {
                try await first.submit(seedPrompt, create: stockFixtureCreate)
            }
            let seedRuntimeID = try await stage("slice3 completed-away seed binding") {
                try XCTUnwrap(first.binding?.runtimeID)
            }
            cleanupRuntimeID = seedRuntimeID
            let seedTerminal = try await stage("slice3 completed-away seed terminal") {
                try await events.wait { event in
                    event.sessionID == seedRuntimeID
                        && event.type == "message.complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "complete"
                }
            }
            let storedID = try await stage("slice3 completed-away durable identity") {
                try XCTUnwrap(first.storedID)
            }
            let baseline = try await stage("slice3 completed-away baseline transcript") {
                try await api.directSessionMessages(sessionID: storedID, profile: "default")
            }
            try assertRecoveryTranscript(baseline, users: [seedPrompt], assistant: expectedAck)

            try await stage("slice3 completed-away delayed submit") {
                try await first.submit(delayedPrompt, create: stockFixtureCreate)
            }
            _ = try await stage("slice3 completed-away accepted running") {
                try await events.wait { event in
                    event.sessionID == seedRuntimeID
                        && event.type == "message.start"
                        && (event.sequence ?? -1) > (seedTerminal.sequence ?? -1)
                }
            }

            // The controller is the app-owned observer. Dispose it without a
            // session.close. The stock session must finish while this owner
            // is absent; no prompt is resent by the test.
            try await stage("slice3 completed-away controller disposal") { try await first.dispose() }
            initial = nil

            let replacementRuntime = try await stage("slice3 completed-away replacement runtime init") {
                try HermesServerRuntime(origin: HostedTransport.https.baseURL, client: api)
            }
            await serverRuntime.stop()
            runtime = replacementRuntime

            let completedAway = try await stage("slice3 completed-away canonical completion") {
                for _ in 0..<90 {
                    let page = try await api.directSessionMessages(sessionID: storedID, profile: "default")
                    let durable = page.messages.filter { $0.role == "user" || $0.role == "assistant" }
                    let users = durable.filter { $0.role == "user" }.compactMap(\.content)
                    let assistants = durable.filter { $0.role == "assistant" }.compactMap(\.content)
                    if users == [seedPrompt, delayedPrompt],
                       assistants == [expectedAck, expectedAck] {
                        return page
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                throw LiveSmokeInvariant.failed
            }
            guard completedAway.messages.count >= baseline.messages.count,
                  Array(completedAway.messages.prefix(baseline.messages.count)) == baseline.messages else {
                throw LiveSmokeInvariant.failed
            }
            try assertRecoveryTranscript(
                completedAway,
                users: [seedPrompt, delayedPrompt],
                assistant: expectedAck
            )

            try await stage("slice3 completed-away replacement runtime connect") {
                try await replacementRuntime.connect()
            }
            let resumed = GatewayConversationController(
                runtime: replacementRuntime,
                client: api,
                storedID: storedID,
                profile: "default"
            )
            resumed.onBinding = { binding in cleanupRuntimeID = binding.runtimeID }
            var reopenedTranscript: DirectHermesTranscriptPage?
            resumed.onTranscript = { page, _ in reopenedTranscript = page }
            reopened = resumed
            try await stage("slice3 completed-away controller reopen") { try await resumed.open() }
            guard resumed.storedID == storedID,
                  resumed.runState == .idle,
                  resumed.binding?.runtimeID.isEmpty == false,
                  reopenedTranscript?.messages == completedAway.messages else {
                throw LiveSmokeInvariant.failed
            }
            let reopenedPage = try await stage("slice3 completed-away reopened transcript") {
                try await api.directSessionMessages(sessionID: storedID, profile: "default")
            }
            guard reopenedPage.messages == completedAway.messages else {
                throw LiveSmokeInvariant.failed
            }
            try assertRecoveryTranscript(
                reopenedPage,
                users: [seedPrompt, delayedPrompt],
                assistant: expectedAck
            )

            let reopenedRuntimeID = try XCTUnwrap(resumed.binding?.runtimeID)
            cleanupRuntimeID = reopenedRuntimeID
            try await stage("slice3 completed-away owned runtime cleanup") {
                let closed = try await replacementRuntime.request("session.close", params: [
                    "session_id": .string(reopenedRuntimeID),
                    "profile": .string("default")
                ])
                guard closed?.gatewayFields["closed"] == .bool(true) else {
                    throw LiveSmokeInvariant.failed
                }
            }
            cleanupRuntimeID = nil
            try await resumed.dispose()
            reopened = nil
            await replacementRuntime.stop()
            runtime = nil
            try await stage("slice3 completed-away logout") { try await api.directLogout() }
            loggedIn = false
        } catch {
            if let cleanupRuntimeID, let runtime {
                try? await runtime.connect()
                let closeResult = try? await runtime.request(
                    "session.close",
                    params: [
                        "session_id": .string(cleanupRuntimeID),
                        "profile": .string("default")
                    ],
                    timeout: .seconds(30)
                )
                if case .bool = closeResult?.gatewayFields["closed"] {
                    // True closed the owned runtime; false means it was absent.
                } else {
                    XCTFail("Owned completed-away runtime cleanup was not confirmed.")
                }
            }
            if let reopened { try? await reopened.dispose() }
            if let initial { try? await initial.dispose() }
            if let runtime { await runtime.stop() }
            if loggedIn { try? await api.directLogout() }
            throw error
        }
    }

    @MainActor
    func testOptInHostedSlice3NativeGatewayRestart() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Slice 3 gateway restart smoke is simulator-only.")
        #endif

        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE1_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE3_GATEWAY_RESTART_NATIVE"] == "1",
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == Self.defaultCredentialsPath,
              environment["SEMREH_SLICE2_STOCK_BACKEND_SHA"] == Self.stockBackendSHA,
              environment["SEMREH_SLICE2_TOOL_CWD"] == Self.stockToolCwd,
              let nonce = environment["SEMREH_SLICE3_GATEWAY_RESTART_NONCE"],
              let markerURL = try? Self.gatewayRestartMarkerURL(environment: environment, nonce: nonce)
        else {
            throw XCTSkip("Slice 3 native gateway restart smoke is opt-in for the pinned stock HTTPS fixture.")
        }

        let credentials = try await stage("slice3 gateway restart credentials") {
            try Self.readCredentials()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [:]
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = APIClient(
            baseURL: HostedTransport.https.baseURL,
            session: session,
            publicMediaSession: session,
            customHeaderProvider: { [] }
        )

        let markerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemrehSlice3GatewayRestart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: markerRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: markerRoot) }
        let markerStore = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: markerRoot)
        let events = LiveGatewayEventCapture()
        let seedPrompt = "SEMREH_SLICE3_GATEWAY_RESTART_SEED_\(UUID().uuidString)"
        let postRestartPrompt = "SEMREH_SLICE3_GATEWAY_RESTART_POST_\(UUID().uuidString)"
        let expectedAck = "SEMREH_SLICE1_ACK"
        let stockFixtureCreate: [String: JSONValue] = [
            "cwd": .string(Self.stockToolCwd),
            "model": .string("semreh-fixture"),
            "provider": .string("custom")
        ]

        var runtime: HermesServerRuntime?
        var controller: GatewayConversationController?
        var loggedIn = false
        var ownedRuntimeID: String?
        var initialTranscript: DirectHermesTranscriptPage?
        do {
            let status = try await stage("slice3 gateway restart status") { try await api.directStatus() }
            guard status.authRequired == true else { throw LiveSmokeInvariant.failed }
            let providers = try await stage("slice3 gateway restart providers") { try await api.directProviders() }
            guard providers.providers?.contains(where: { $0.name == "basic" && $0.supportsPassword == true }) == true else {
                throw LiveSmokeInvariant.failed
            }
            let login = try await stage("slice3 gateway restart login") {
                try await api.directPasswordLogin(username: credentials.username, password: credentials.password)
            }
            guard login.ok == true else { throw LiveSmokeInvariant.failed }
            loggedIn = true
            try await stage("slice3 gateway restart protected probe before") { try await api.directProtectedProbe() }

            let serverRuntime = try await stage("slice3 gateway restart runtime init") {
                try HermesServerRuntime(origin: HostedTransport.https.baseURL, client: api)
            }
            runtime = serverRuntime
            try await stage("slice3 gateway restart runtime connect") { try await serverRuntime.connect() }
            let initial = GatewayConversationController(
                runtime: serverRuntime,
                client: api,
                storedID: nil,
                profile: "default",
                recoveryMarkerStore: markerStore
            )
            initial.onEvent = { event in Task { await events.append(event) } }
            initial.onBinding = { binding in ownedRuntimeID = binding.runtimeID }
            initial.onTranscript = { page, _ in initialTranscript = page }
            controller = initial
            try await stage("slice3 gateway restart seed submit") {
                try await initial.submit(seedPrompt, create: stockFixtureCreate)
            }
            let seedRuntimeID = try await stage("slice3 gateway restart seed binding") {
                try XCTUnwrap(initial.binding?.runtimeID)
            }
            ownedRuntimeID = seedRuntimeID
            _ = try await stage("slice3 gateway restart seed terminal") {
                try await events.wait { event in
                    event.sessionID == seedRuntimeID
                        && event.type == "message.complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "complete"
                }
            }
            guard initial.runState == .idle else { throw LiveSmokeInvariant.failed }
            let storedID = try await stage("slice3 gateway restart durable identity") {
                try XCTUnwrap(initial.storedID)
            }
            guard initial.storedID == storedID else { throw LiveSmokeInvariant.failed }
            let baseline = try await stage("slice3 gateway restart baseline transcript") {
                try await api.directSessionMessages(sessionID: storedID, profile: "default")
            }
            try assertRecoveryTranscript(baseline, users: [seedPrompt], assistant: expectedAck)
            try await initial.refresh()
            guard initialTranscript?.messages == baseline.messages else { throw LiveSmokeInvariant.failed }

            try Self.writeGatewayRestartMarker(url: markerURL, nonce: nonce, phase: "ready")
            try await stage("slice3 gateway restart external restart") {
                try await Self.waitForGatewayRestartMarker(url: markerURL, nonce: nonce)
            }
            // The URLSession cookie jar is intentionally retained: this proves
            // the restarted stock process still accepts the authenticated app
            // session, rather than hiding a restart failure behind a relogin.
            try await stage("slice3 gateway restart protected probe after") { try await api.directProtectedProbe() }
            try await stage("slice3 gateway restart runtime reconnect") { try await serverRuntime.reconnect() }
            try await stage("slice3 gateway restart controller reopen") { try await initial.open() }
            let reboundRuntimeID = try await stage("slice3 gateway restart rebound binding") {
                try XCTUnwrap(initial.binding?.runtimeID)
            }
            guard reboundRuntimeID != seedRuntimeID else { throw LiveSmokeInvariant.failed }
            ownedRuntimeID = reboundRuntimeID
            guard initial.storedID == storedID, initial.runState == .idle else { throw LiveSmokeInvariant.failed }
            try await initial.refresh()
            guard initialTranscript?.messages == baseline.messages else { throw LiveSmokeInvariant.failed }
            let reboundBaseline = try await stage("slice3 gateway restart canonical baseline") {
                try await api.directSessionMessages(sessionID: storedID, profile: "default")
            }
            guard reboundBaseline.messages == baseline.messages else { throw LiveSmokeInvariant.failed }

            try await stage("slice3 gateway restart post prompt") {
                try await initial.submit(postRestartPrompt)
            }
            _ = try await stage("slice3 gateway restart post terminal") {
                try await events.wait { event in
                    event.sessionID == reboundRuntimeID
                        && event.type == "message.complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "complete"
                }
            }
            let finalTranscript = try await stage("slice3 gateway restart final transcript") {
                try await api.directSessionMessages(sessionID: storedID, profile: "default")
            }
            guard finalTranscript.messages.count >= baseline.messages.count,
                  Array(finalTranscript.messages.prefix(baseline.messages.count)) == baseline.messages else {
                throw LiveSmokeInvariant.failed
            }
            try assertRecoveryTranscript(
                finalTranscript,
                users: [seedPrompt, postRestartPrompt],
                assistant: expectedAck
            )
            if let ownedRuntimeID {
                let closed = try await serverRuntime.request("session.close", params: [
                    "session_id": .string(ownedRuntimeID),
                    "profile": .string("default")
                ])
                guard closed?.gatewayFields["closed"] == .bool(true) else { throw LiveSmokeInvariant.failed }
            }
            try await initial.dispose()
            controller = nil
            await serverRuntime.stop()
            runtime = nil
            try await stage("slice3 gateway restart logout") { try await api.directLogout() }
            loggedIn = false
            try Self.writeGatewayRestartMarker(url: markerURL, nonce: nonce, phase: "complete")
        } catch {
            if let ownedRuntimeID, let runtime {
                do {
                    try await runtime.connect()
                    let closeResult = try await runtime.request("session.close", params: [
                        "session_id": .string(ownedRuntimeID),
                        "profile": .string("default")
                    ])
                    guard closeResult?.gatewayFields["closed"] == .bool(true) else {
                        XCTFail("Owned gateway restart runtime cleanup was not confirmed.")
                        throw LiveSmokeInvariant.failed
                        }
                } catch {
                    XCTFail("Owned gateway restart runtime cleanup failed.")
                }
            }
            if let controller { try? await controller.dispose() }
            if let runtime { await runtime.stop() }
            if loggedIn { try? await api.directLogout() }
            throw error
        }
    }

    @MainActor
    func testOptInHostedSlice3NativePreACKLoss() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Slice 3 pre-ACK-loss smoke is simulator-only.")
        #endif

        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE1_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE3_PRE_ACK_LOSS_NATIVE"] == "1",
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == Self.defaultCredentialsPath,
              environment["SEMREH_SLICE2_STOCK_BACKEND_SHA"] == Self.stockBackendSHA,
              environment["SEMREH_SLICE2_TOOL_CWD"] == Self.stockToolCwd
        else {
            throw XCTSkip("Slice 3 pre-ACK-loss smoke is opt-in for the pinned stock HTTPS fixture.")
        }

        do {
            try await runHostedSlice3NativePreACKLoss()
        } catch let failure as LiveSmokeFailure {
            XCTFail("Slice 3 pre-ACK-loss smoke failed at \(failure.stage).")
        } catch {
            XCTFail("Slice 3 pre-ACK-loss smoke failed.")
        }
    }

    @MainActor
    func testOptInHostedSlice3NativeActiveSocketLoss() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Slice 3 active socket-loss smoke is simulator-only.")
        #endif

        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMREH_SLICE1_LIVE"] == "1",
              environment["SEMREH_SLICE1_HTTPS"] == "1",
              environment["SEMREH_SLICE3_ACTIVE_SOCKET_LOSS_NATIVE"] == "1",
              environment["SEMREH_SLICE1_CREDENTIALS_FILE"] == Self.defaultCredentialsPath,
              environment["SEMREH_SLICE2_STOCK_BACKEND_SHA"] == Self.stockBackendSHA,
              environment["SEMREH_SLICE2_TOOL_CWD"] == Self.stockToolCwd
        else {
            throw XCTSkip("Slice 3 active socket-loss smoke is opt-in for the pinned stock HTTPS fixture.")
        }

        let credentials = try await stage("slice3 active socket-loss credentials") {
            try Self.readCredentials()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [:]
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = APIClient(
            baseURL: HostedTransport.https.baseURL,
            session: session,
            publicMediaSession: session,
            customHeaderProvider: { [] }
        )
        let socketFactory = LiveActiveSocketLossFactory(session: session)
        let events = LiveGatewayEventCapture()
        let seedPrompt = "SEMREH_SLICE3_ACTIVE_SOCKET_SEED_\(UUID().uuidString)"
        let delayedPrompt = "SEMREH_INTERRUPT_FIXTURE SEMREH_SLICE3_ACTIVE_SOCKET_LOSS_\(UUID().uuidString)"
        let expectedAck = "SEMREH_SLICE1_ACK"
        let stockFixtureCreate: [String: JSONValue] = [
            "cwd": .string(Self.stockToolCwd),
            "model": .string("semreh-fixture"),
            "provider": .string("custom")
        ]

        var runtime: HermesServerRuntime?
        var controller: GatewayConversationController?
        var loggedIn = false
        var ownedRuntimeID: String?
        do {
            let status = try await stage("slice3 active socket-loss status") { try await api.directStatus() }
            guard status.authRequired == true else { throw LiveSmokeInvariant.failed }
            let providers = try await stage("slice3 active socket-loss providers") { try await api.directProviders() }
            guard providers.providers?.contains(where: { $0.name == "basic" && $0.supportsPassword == true }) == true else {
                throw LiveSmokeInvariant.failed
            }
            let login = try await stage("slice3 active socket-loss login") {
                try await api.directPasswordLogin(username: credentials.username, password: credentials.password)
            }
            guard login.ok == true else { throw LiveSmokeInvariant.failed }
            loggedIn = true
            try await stage("slice3 active socket-loss protected probe") { try await api.directProtectedProbe() }

            let serverRuntime = try await stage("slice3 active socket-loss runtime init") {
                try HermesServerRuntime(origin: HostedTransport.https.baseURL) { sink in
                    HermesGatewayClient(
                        gatewayURL: HostedTransport.https.gatewayURL,
                        ticketProvider: {
                            let response = try await api.directWSTicket()
                            guard let ticket = response.ticket,
                                  !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            else { throw LiveSmokeInvariant.failed }
                            return ticket
                        },
                        requestTimeout: .seconds(30),
                        eventHandler: sink,
                        urlSessionConfiguration: configuration,
                        socketFactory: { request in socketFactory.make(request: request) }
                    )
                }
            }
            runtime = serverRuntime
            try await stage("slice3 active socket-loss runtime connect") { try await serverRuntime.connect() }

            var bindingUpdateCount = 0
            let initial = GatewayConversationController(
                runtime: serverRuntime,
                client: api,
                storedID: nil,
                profile: "default"
            )
            initial.onEvent = { event in Task { await events.append(event) } }
            initial.onBinding = { binding in
                bindingUpdateCount += 1
                ownedRuntimeID = binding.runtimeID
            }
            controller = initial

            try await stage("slice3 active socket-loss seed submit") {
                try await initial.submit(seedPrompt, create: stockFixtureCreate)
            }
            let seedRuntimeID = try await stage("slice3 active socket-loss seed binding") {
                try XCTUnwrap(initial.binding?.runtimeID)
            }
            ownedRuntimeID = seedRuntimeID
            _ = try await stage("slice3 active socket-loss seed start") {
                try await events.wait { event in
                    event.sessionID == seedRuntimeID && event.type == "message.start"
                }
            }
            _ = try await stage("slice3 active socket-loss seed terminal") {
                try await events.wait { event in
                    event.sessionID == seedRuntimeID
                        && event.type == "message.complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "complete"
                }
            }
            guard initial.runState == .idle else { throw LiveSmokeInvariant.failed }
            let storedID = try await stage("slice3 active socket-loss durable identity") {
                try XCTUnwrap(initial.storedID)
            }
            let baseline = try await stage("slice3 active socket-loss baseline transcript") {
                try await api.directSessionMessages(sessionID: storedID, profile: "default")
            }
            try assertRecoveryTranscript(baseline, users: [seedPrompt], assistant: expectedAck)
            var nativeTranscript: DirectHermesTranscriptPage?
            initial.onTranscript = { page, _ in nativeTranscript = page }
            let initialConnectionGeneration = serverRuntime.connectionGeneration

            try await stage("slice3 active socket-loss accepted submit") {
                try await initial.submit(delayedPrompt, create: stockFixtureCreate)
            }
            _ = try await stage("slice3 active socket-loss running before cancel") {
                try await events.wait { event in
                    event.sessionID == seedRuntimeID && event.type == "message.start"
                }
            }
            guard initial.runState == .running else { throw LiveSmokeInvariant.failed }
            var acceptedPage: DirectHermesTranscriptPage?
            for _ in 0..<90 {
                let page = try await api.directSessionMessages(sessionID: storedID, profile: "default")
                let durable = page.messages.filter { $0.role == "user" || $0.role == "assistant" }
                let users = durable.filter { $0.role == "user" }.compactMap(\.content)
                let assistants = durable.filter { $0.role == "assistant" }.compactMap(\.content)
                if users == [seedPrompt, delayedPrompt], assistants == [expectedAck] {
                    acceptedPage = page
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard acceptedPage != nil,
                  initial.runState == .running,
                  serverRuntime.connectionGeneration == initialConnectionGeneration,
                  socketFactory.socketCount == 1 else { throw LiveSmokeInvariant.failed }
            guard socketFactory.cancelOnlySocket() else { throw LiveSmokeInvariant.failed }

            for _ in 0..<90 {
                if serverRuntime.connectionGeneration > initialConnectionGeneration,
                   bindingUpdateCount >= 2 {
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard serverRuntime.connectionGeneration > initialConnectionGeneration,
                  bindingUpdateCount >= 2,
                  initial.storedID == storedID else {
                throw LiveSmokeInvariant.failed
            }
            let reboundRuntimeID = try XCTUnwrap(initial.binding?.runtimeID)
            _ = try await stage("slice3 active socket-loss recovered terminal") {
                try await events.wait { event in
                    event.sessionID == reboundRuntimeID
                        && event.type == "message.complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["text"]) == expectedAck
                }
            }
            guard serverRuntime.state == .ready,
                  initial.binding != nil,
                  initial.runState == .idle else {
                throw LiveSmokeInvariant.failed
            }
            guard socketFactory.socketCount >= 2,
                  socketFactory.promptSubmitCount == 2 else {
                throw LiveSmokeInvariant.failed
            }

            let finalTranscript = try await stage("slice3 active socket-loss canonical transcript") {
                try await api.directSessionMessages(sessionID: storedID, profile: "default")
            }
            guard finalTranscript.messages.count >= baseline.messages.count,
                  Array(finalTranscript.messages.prefix(baseline.messages.count)) == baseline.messages else {
                throw LiveSmokeInvariant.failed
            }
            try assertRecoveryTranscript(
                finalTranscript,
                users: [seedPrompt, delayedPrompt],
                assistant: expectedAck
            )
            try await initial.refresh()
            guard nativeTranscript?.messages == finalTranscript.messages else {
                throw LiveSmokeInvariant.failed
            }

            if let ownedRuntimeID {
                let closed = try await stage("slice3 active socket-loss owned cleanup") {
                    try await serverRuntime.request("session.close", params: [
                        "session_id": .string(ownedRuntimeID),
                        "profile": .string("default")
                    ])
                }
                guard closed?.gatewayFields["closed"] == .bool(true) else { throw LiveSmokeInvariant.failed }
            }
            try await initial.dispose()
            controller = nil
            await serverRuntime.stop()
            runtime = nil
            try await stage("slice3 active socket-loss logout") { try await api.directLogout() }
            loggedIn = false
        } catch {
            if let runtime, let ownedRuntimeID {
                try? await runtime.connect()
                _ = try? await runtime.request("session.close", params: [
                    "session_id": .string(ownedRuntimeID),
                    "profile": .string("default")
                ])
            }
            if let controller { try? await controller.dispose() }
            if let runtime { await runtime.stop() }
            if loggedIn { try? await api.directLogout() }
            throw error
        }
    }

    @MainActor
    private func runHostedSlice3NativePreACKLoss() async throws {
        let credentials = try await stage("slice3 pre-ACK-loss credentials") {
            try Self.readCredentials()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [:]
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = APIClient(
            baseURL: HostedTransport.https.baseURL,
            session: session,
            publicMediaSession: session,
            customHeaderProvider: { [] }
        )
        let seedPrompt = "SEMREH_SLICE3_PRE_ACK_SEED_\(UUID().uuidString)"
        let delayedPrompt = "SEMREH_INTERRUPT_FIXTURE SEMREH_SLICE3_PRE_ACK_LOSS_\(UUID().uuidString)"
        let expectedAck = "SEMREH_SLICE1_ACK"
        let socketFactory = LivePreACKLossFactory(session: session, targetPrompt: delayedPrompt)
        let events = LiveGatewayEventCapture()
        let stockFixtureCreate: [String: JSONValue] = [
            "cwd": .string(Self.stockToolCwd),
            "model": .string("semreh-fixture"),
            "provider": .string("custom")
        ]

        var runtime: HermesServerRuntime?
        var controller: GatewayConversationController?
        var submitTask: Task<Void, Error>?
        var loggedIn = false
        var ownedRuntimeID: String?
        do {
            let status = try await stage("slice3 pre-ACK-loss status") { try await api.directStatus() }
            guard status.authRequired == true else { throw LiveSmokeInvariant.failed }
            let providers = try await stage("slice3 pre-ACK-loss providers") { try await api.directProviders() }
            guard providers.providers?.contains(where: { $0.name == "basic" && $0.supportsPassword == true }) == true else {
                throw LiveSmokeInvariant.failed
            }
            let login = try await stage("slice3 pre-ACK-loss login") {
                try await api.directPasswordLogin(username: credentials.username, password: credentials.password)
            }
            guard login.ok == true else { throw LiveSmokeInvariant.failed }
            loggedIn = true
            try await stage("slice3 pre-ACK-loss protected probe") { try await api.directProtectedProbe() }

            let serverRuntime = try await stage("slice3 pre-ACK-loss runtime init") {
                try HermesServerRuntime(origin: HostedTransport.https.baseURL) { sink in
                    HermesGatewayClient(
                        gatewayURL: HostedTransport.https.gatewayURL,
                        ticketProvider: {
                            let response = try await api.directWSTicket()
                            guard let ticket = response.ticket,
                                  !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            else { throw LiveSmokeInvariant.failed }
                            return ticket
                        },
                        requestTimeout: .seconds(30),
                        eventHandler: sink,
                        urlSessionConfiguration: configuration,
                        socketFactory: { request in socketFactory.make(request: request) }
                    )
                }
            }
            runtime = serverRuntime
            try await stage("slice3 pre-ACK-loss runtime connect") { try await serverRuntime.connect() }

            var bindingUpdateCount = 0
            let initial = GatewayConversationController(
                runtime: serverRuntime,
                client: api,
                storedID: nil,
                profile: "default"
            )
            initial.onEvent = { event in Task { await events.append(event) } }
            initial.onBinding = { binding in
                bindingUpdateCount += 1
                ownedRuntimeID = binding.runtimeID
            }
            controller = initial

            try await stage("slice3 pre-ACK-loss seed submit") {
                try await initial.submit(seedPrompt, create: stockFixtureCreate)
            }
            let seedRuntimeID = try await stage("slice3 pre-ACK-loss seed binding") {
                try XCTUnwrap(initial.binding?.runtimeID)
            }
            ownedRuntimeID = seedRuntimeID
            _ = try await stage("slice3 pre-ACK-loss seed start") {
                try await events.wait { event in
                    event.sessionID == seedRuntimeID && event.type == "message.start"
                }
            }
            _ = try await stage("slice3 pre-ACK-loss seed terminal") {
                try await events.wait { event in
                    event.sessionID == seedRuntimeID
                        && event.type == "message.complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "complete"
                }
            }
            try await stage("slice3 pre-ACK-loss seed idle") {
                guard initial.runState == .idle else { throw LiveSmokeInvariant.failed }
            }
            let storedID = try await stage("slice3 pre-ACK-loss durable identity") {
                try XCTUnwrap(initial.storedID)
            }
            let baseline = try await stage("slice3 pre-ACK-loss baseline transcript") {
                try await api.directSessionMessages(sessionID: storedID, profile: "default")
            }
            try await stage("slice3 pre-ACK-loss baseline identity") {
                guard baseline.sessionID == storedID else { throw LiveSmokeInvariant.failed }
                try assertExactRecoveryTranscript(baseline, users: [seedPrompt], assistant: expectedAck)
            }
            let initialConnectionGeneration = serverRuntime.connectionGeneration
            var nativeTranscript: DirectHermesTranscriptPage?
            initial.onTranscript = { page, _ in nativeTranscript = page }

            let pendingSubmit = Task { @MainActor in
                try await initial.submit(delayedPrompt, create: stockFixtureCreate)
            }
            submitTask = pendingSubmit
            for _ in 0..<150 {
                if socketFactory.targetSubmitCount == 1 { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            try await stage("slice3 pre-ACK-loss target dispatched once") {
                guard socketFactory.targetSubmitCount == 1 else { throw LiveSmokeInvariant.failed }
            }

            var acceptedPage: DirectHermesTranscriptPage?
            for _ in 0..<150 {
                let page = try await api.directSessionMessages(sessionID: storedID, profile: "default")
                let durable = page.messages.filter { $0.role == "user" || $0.role == "assistant" }
                let users = durable.filter { $0.role == "user" }.compactMap(\.content)
                let assistants = durable.filter { $0.role == "assistant" }.compactMap(\.content)
                if users == [seedPrompt, delayedPrompt], assistants == [expectedAck] {
                    acceptedPage = page
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            for _ in 0..<50 {
                if socketFactory.droppedTargetSuccessCount == 1 { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            try await stage("slice3 pre-ACK-loss accepted canonical row") {
                guard let acceptedPage,
                      acceptedPage.sessionID == storedID,
                      acceptedPage.messages.count >= baseline.messages.count,
                      Array(acceptedPage.messages.prefix(baseline.messages.count)) == baseline.messages else {
                    throw LiveSmokeInvariant.failed
                }
                try assertAcceptedRecoveryTranscript(
                    acceptedPage,
                    seed: seedPrompt,
                    assistant: expectedAck,
                    accepted: delayedPrompt
                )
            }
            try await stage("slice3 pre-ACK-loss response suppressed before cancel") {
                guard socketFactory.droppedTargetSuccessCount == 1,
                      initial.runState == .running,
                      serverRuntime.connectionGeneration == initialConnectionGeneration,
                      socketFactory.socketCount == 1 else {
                    throw LiveSmokeInvariant.failed
                }
            }

            try await stage("slice3 pre-ACK-loss cancel sole socket") {
                guard socketFactory.cancelOnlySocket() else { throw LiveSmokeInvariant.failed }
            }
            let submitResult = await pendingSubmit.result
            try await stage("slice3 pre-ACK-loss ambiguous submit") {
                guard case .failure = submitResult else { throw LiveSmokeInvariant.failed }
            }
            submitTask = nil

            for _ in 0..<150 {
                if serverRuntime.connectionGeneration > initialConnectionGeneration,
                   bindingUpdateCount >= 2 {
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            try await stage("slice3 pre-ACK-loss rebound binding") {
                guard serverRuntime.connectionGeneration > initialConnectionGeneration,
                      bindingUpdateCount >= 2,
                      initial.storedID == storedID else {
                    throw LiveSmokeInvariant.failed
                }
            }
            let reboundRuntimeID = try XCTUnwrap(initial.binding?.runtimeID)
            _ = try await stage("slice3 pre-ACK-loss canonical completion") {
                try await events.wait { event in
                    event.sessionID == reboundRuntimeID
                        && event.type == "message.complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["status"]) == "complete"
                        && Self.stringValue(Self.objectValue(event.payload)?["text"]) == expectedAck
                }
            }
            try await stage("slice3 pre-ACK-loss recovered idle and no resend") {
                guard serverRuntime.state == .ready,
                      initial.binding != nil,
                      initial.runState == .idle,
                      socketFactory.targetSubmitCount == 1,
                      socketFactory.promptSubmitCount == 2 else {
                    throw LiveSmokeInvariant.failed
                }
            }

            let finalTranscript = try await stage("slice3 pre-ACK-loss final transcript") {
                try await api.directSessionMessages(sessionID: storedID, profile: "default")
            }
            try await stage("slice3 pre-ACK-loss final canonical transcript") {
                guard finalTranscript.sessionID == storedID,
                      finalTranscript.messages.count >= baseline.messages.count,
                      Array(finalTranscript.messages.prefix(baseline.messages.count)) == baseline.messages else {
                    throw LiveSmokeInvariant.failed
                }
                try assertExactRecoveryTranscript(
                    finalTranscript,
                    users: [seedPrompt, delayedPrompt],
                    assistant: expectedAck
                )
            }
            try await stage("slice3 pre-ACK-loss controller refresh") {
                try await initial.refresh()
                guard nativeTranscript?.messages == finalTranscript.messages else {
                    throw LiveSmokeInvariant.failed
                }
            }

            // Public synthetic identity only: a later production UI gate can
            // reopen this exact chat and exercise its persisted uncertainty
            // without inserting a marker through a debug-only app hook.
            let recoverySeed = try JSONSerialization.data(withJSONObject: [
                "stored_id": storedID,
                "seed_prompt": seedPrompt,
                "delayed_prompt": delayedPrompt,
                "canonical_row_count": finalTranscript.messages.count
            ], options: [.sortedKeys])
            let seedAttachment = XCTAttachment(data: recoverySeed, uniformTypeIdentifier: "public.json")
            seedAttachment.name = "slice3-preack-production-recovery-seed"
            seedAttachment.lifetime = .keepAlways
            add(seedAttachment)

            if let ownedRuntimeID {
                let closed = try await stage("slice3 pre-ACK-loss owned cleanup") {
                    try await serverRuntime.request("session.close", params: [
                        "session_id": .string(ownedRuntimeID),
                        "profile": .string("default")
                    ])
                }
                guard closed?.gatewayFields["closed"] == .bool(true) else { throw LiveSmokeInvariant.failed }
            }
            try await initial.dispose()
            controller = nil
            await serverRuntime.stop()
            runtime = nil
            try await stage("slice3 pre-ACK-loss logout") { try await api.directLogout() }
            loggedIn = false
        } catch {
            if let submitTask {
                submitTask.cancel()
                _ = await submitTask.result
            }
            if let runtime, let ownedRuntimeID {
                try? await runtime.connect()
                _ = try? await runtime.request("session.close", params: [
                    "session_id": .string(ownedRuntimeID),
                    "profile": .string("default")
                ])
            }
            if let controller { try? await controller.dispose() }
            if let runtime { await runtime.stop() }
            if loggedIn { try? await api.directLogout() }
            throw error
        }
    }

    private func assertRecoveryTranscript(
        _ page: DirectHermesTranscriptPage,
        users: [String],
        assistant: String
    ) throws {
        let durable = page.messages.filter { $0.role == "user" || $0.role == "assistant" }
        let userMessages = durable.filter { $0.role == "user" }
        let assistantMessages = durable.filter { $0.role == "assistant" }
        guard userMessages.count == users.count,
              assistantMessages.count == users.count,
              userMessages.compactMap(\.content) == users,
              assistantMessages.allSatisfy({ $0.content == assistant }),
              durable.allSatisfy({ ($0.attachments ?? []).isEmpty }),
              durable.allSatisfy({
                  let content = $0.content ?? ""
                  return !content.contains("@image:") && !content.contains("@file:")
              })
        else { throw LiveSmokeInvariant.failed }
    }

    private func assertExactRecoveryTranscript(
        _ page: DirectHermesTranscriptPage,
        users: [String],
        assistant: String
    ) throws {
        try assertRecoveryTranscript(page, users: users, assistant: assistant)
        let durable = page.messages.filter { $0.role == "user" || $0.role == "assistant" }
        let expectedRoles = users.flatMap { _ in ["user", "assistant"] }
        let canonicalIDs = durable.compactMap(\.messageId)
        guard durable.compactMap(\.role) == expectedRoles,
              canonicalIDs.count == durable.count,
              Set(canonicalIDs).count == canonicalIDs.count,
              zip(durable, users.flatMap { [$0, assistant] }).allSatisfy({ message, expected in
                  message.content == expected
              }) else {
            throw LiveSmokeInvariant.failed
        }
    }

    private func assertAcceptedRecoveryTranscript(
        _ page: DirectHermesTranscriptPage,
        seed: String,
        assistant: String,
        accepted: String
    ) throws {
        let durable = page.messages.filter { $0.role == "user" || $0.role == "assistant" }
        let canonicalIDs = durable.compactMap(\.messageId)
        guard durable.compactMap(\.role) == ["user", "assistant", "user"],
              durable.compactMap(\.content) == [seed, assistant, accepted],
              canonicalIDs.count == durable.count,
              Set(canonicalIDs).count == canonicalIDs.count,
              durable.allSatisfy({ ($0.attachments ?? []).isEmpty }),
              durable.allSatisfy({
                  let content = $0.content ?? ""
                  return !content.contains("@image:") && !content.contains("@file:")
              }) else {
            throw LiveSmokeInvariant.failed
        }
    }

    @MainActor
    private func runHostedSlice2NativeReasoning(
        transport: HostedTransport,
        stockBackend: Bool
    ) async throws {
        let credentials = try await stage("reasoning credentials") {
            try Self.readCredentials(development: !stockBackend)
        }
        guard let toolCwd = ProcessInfo.processInfo.environment["SEMREH_SLICE2_TOOL_CWD"],
              !toolCwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw LiveSmokeInvariant.failed }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [:]
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

        var runtime: HermesServerRuntime?
        var firstViewModel: ChatViewModel?
        var siblingViewModel: ChatViewModel?
        var resumedViewModel: ChatViewModel?
        var loggedIn = false

        do {
            let status = try await stage("reasoning status") { try await api.directStatus() }
            guard status.authRequired == true else { throw LiveSmokeInvariant.failed }
            let providers = try await stage("reasoning providers") { try await api.directProviders() }
            guard providers.providers?.contains(where: { $0.name == "basic" && $0.supportsPassword == true }) == true else {
                throw LiveSmokeInvariant.failed
            }
            let login = try await stage("reasoning login") {
                try await api.directPasswordLogin(username: credentials.username, password: credentials.password)
            }
            guard login.ok == true else { throw LiveSmokeInvariant.failed }
            loggedIn = true
            try await stage("reasoning protected probe") { try await api.directProtectedProbe() }

            let serverRuntime = try await stage("reasoning runtime init") {
                try HermesServerRuntime(origin: transport.baseURL, client: api)
            }
            runtime = serverRuntime
            try await stage("reasoning runtime connect") { try await serverRuntime.connect() }

            let first = ChatViewModel(
                session: SessionSummary(
                    title: "Generated reasoning low",
                    workspace: toolCwd,
                    model: "gpt-5",
                    modelProvider: "custom",
                    reasoningEffort: "low",
                    profile: "default"
                ),
                server: transport.baseURL,
                client: api,
                liveActivityManager: NativeSmokeNoopLiveActivityManager(),
                gatewayRuntimeProvider: { _ in serverRuntime }
            )
            firstViewModel = first
            var firstStoredID: String?
            first.onDirectCanonicalID = { id in firstStoredID = id }

            try await stage("reasoning first inventory") {
                await first.loadComposerConfiguration()
                guard first.composerConfigurationErrorMessage == nil,
                      first.selectedModelID == "gpt-5",
                      first.selectedModelProviderID == "custom",
                      first.supportedReasoningEfforts?.contains("high") == true,
                      !first.hasServerBackedSession
                else { throw LiveSmokeInvariant.failed }
            }

            let firstWarmup = "SEMREH_REASONING_PROBE GENERATED_FIRST_WARMUP"
            try await stage("reasoning first low send") {
                guard await first.sendMessage(firstWarmup) else { throw LiveSmokeInvariant.failed }
            }
            try await stage("reasoning first low transcript") {
                try await waitForNativeReasoningTranscript(
                    in: first,
                    expected: [(firstWarmup, "SEMREH_REASONING_EFFORT:low")]
                )
            }
            guard first.hasServerBackedSession, firstStoredID?.isEmpty == false else {
                throw LiveSmokeInvariant.failed
            }
            try await stage("reasoning first session capability") {
                try await waitForNativeReasoningCapability(in: first)
            }

            let delayed = "SEMREH_INTERRUPT_FIXTURE SEMREH_REASONING_PROBE GENERATED_FIRST_DELAYED"
            try await stage("reasoning delayed send") {
                guard await first.sendMessage(delayed) else { throw LiveSmokeInvariant.failed }
            }
            try await stage("reasoning delayed run started") {
                try await waitForNativeDirectRun(in: first)
            }
            try await stage("reasoning deferred high selection") {
                guard await first.selectReasoningEffort("high"),
                      first.selectedReasoningEffort == "high",
                      first.sessionReasoningEffort == "high",
                      first.isReasoningChangeDeferred
                else { throw LiveSmokeInvariant.failed }
            }

            try await stage("reasoning delayed low transcript") {
                try await waitForNativeReasoningTranscript(
                    in: first,
                    expected: [
                        (firstWarmup, "SEMREH_REASONING_EFFORT:low"),
                        (delayed, "SEMREH_REASONING_EFFORT:low")
                    ]
                )
            }
            let firstNext = "SEMREH_REASONING_PROBE GENERATED_FIRST_NEXT"
            try await stage("reasoning next high send") {
                guard await first.sendMessage(firstNext) else { throw LiveSmokeInvariant.failed }
            }
            try await stage("reasoning next high transcript") {
                try await waitForNativeReasoningTranscript(
                    in: first,
                    expected: [
                        (firstWarmup, "SEMREH_REASONING_EFFORT:low"),
                        (delayed, "SEMREH_REASONING_EFFORT:low"),
                        (firstNext, "SEMREH_REASONING_EFFORT:high")
                    ]
                )
            }

            let sibling = ChatViewModel(
                session: SessionSummary(
                    title: "Generated reasoning medium",
                    workspace: toolCwd,
                    model: "gpt-5",
                    modelProvider: "custom",
                    reasoningEffort: "medium",
                    profile: "default"
                ),
                server: transport.baseURL,
                client: api,
                liveActivityManager: NativeSmokeNoopLiveActivityManager(),
                gatewayRuntimeProvider: { _ in serverRuntime }
            )
            siblingViewModel = sibling
            try await stage("reasoning sibling inventory") {
                await sibling.loadComposerConfiguration()
                guard sibling.composerConfigurationErrorMessage == nil,
                      sibling.selectedModelID == "gpt-5",
                      sibling.selectedModelProviderID == "custom",
                      sibling.supportedReasoningEfforts?.contains("medium") == true
                else { throw LiveSmokeInvariant.failed }
            }
            let siblingWarmup = "SEMREH_REASONING_PROBE GENERATED_SIBLING_WARMUP"
            try await stage("reasoning sibling medium send") {
                guard await sibling.sendMessage(siblingWarmup) else { throw LiveSmokeInvariant.failed }
            }
            try await stage("reasoning sibling medium transcript") {
                try await waitForNativeReasoningTranscript(
                    in: sibling,
                    expected: [(siblingWarmup, "SEMREH_REASONING_EFFORT:medium")]
                )
            }
            guard sibling.selectedReasoningEffort == "medium",
                  sibling.sessionReasoningEffort == "medium"
            else { throw LiveSmokeInvariant.failed }

            try await stage("reasoning first view model dispose") {
                await first.disposeDirectConversation()
            }
            firstViewModel = nil

            let storedID = try XCTUnwrap(firstStoredID)
            let resumed = ChatViewModel(
                session: SessionSummary(
                    sessionId: storedID,
                    title: "Generated reasoning low",
                    workspace: toolCwd,
                    model: "gpt-5",
                    modelProvider: "custom",
                    profile: "default"
                ),
                server: transport.baseURL,
                client: api,
                liveActivityManager: NativeSmokeNoopLiveActivityManager(),
                gatewayRuntimeProvider: { _ in serverRuntime }
            )
            resumedViewModel = resumed
            try await stage("reasoning resume transcript") {
                await resumed.loadMessages()
                guard resumed.lastError == nil, resumed.errorMessage == nil else {
                    throw LiveSmokeInvariant.failed
                }
                try await waitForNativeReasoningTranscript(
                    in: resumed,
                    expected: [
                        (firstWarmup, "SEMREH_REASONING_EFFORT:low"),
                        (delayed, "SEMREH_REASONING_EFFORT:low"),
                        (firstNext, "SEMREH_REASONING_EFFORT:high")
                    ]
                )
            }
            try await stage("reasoning resume configuration") {
                await resumed.loadComposerConfiguration()
                guard resumed.selectedModelID == "gpt-5",
                      resumed.selectedModelProviderID == "custom",
                      resumed.selectedReasoningEffort == "high",
                      resumed.sessionReasoningEffort == "high",
                      resumed.isReasoningChangeDeferred == false
                else { throw LiveSmokeInvariant.failed }
            }
            let resumedNext = "SEMREH_REASONING_PROBE GENERATED_FIRST_RESUMED"
            try await stage("reasoning resumed high send") {
                guard await resumed.sendMessage(resumedNext) else { throw LiveSmokeInvariant.failed }
            }
            try await stage("reasoning resumed high transcript") {
                try await waitForNativeReasoningTranscript(
                    in: resumed,
                    expected: [
                        (firstWarmup, "SEMREH_REASONING_EFFORT:low"),
                        (delayed, "SEMREH_REASONING_EFFORT:low"),
                        (firstNext, "SEMREH_REASONING_EFFORT:high"),
                        (resumedNext, "SEMREH_REASONING_EFFORT:high")
                    ]
                )
            }

            let siblingNext = "SEMREH_REASONING_PROBE GENERATED_SIBLING_NEXT"
            try await stage("reasoning sibling unchanged send") {
                guard await sibling.sendMessage(siblingNext) else { throw LiveSmokeInvariant.failed }
            }
            try await stage("reasoning sibling unchanged transcript") {
                try await waitForNativeReasoningTranscript(
                    in: sibling,
                    expected: [
                        (siblingWarmup, "SEMREH_REASONING_EFFORT:medium"),
                        (siblingNext, "SEMREH_REASONING_EFFORT:medium")
                    ]
                )
            }
            guard sibling.selectedReasoningEffort == "medium",
                  sibling.sessionReasoningEffort == "medium"
            else { throw LiveSmokeInvariant.failed }

            await resumed.disposeDirectConversation()
            resumedViewModel = nil
            await sibling.disposeDirectConversation()
            siblingViewModel = nil
            await serverRuntime.stop()
            runtime = nil
            try await stage("reasoning logout") { try await api.directLogout() }
            loggedIn = false
        } catch {
            if let resumedViewModel { await resumedViewModel.disposeDirectConversation() }
            if let siblingViewModel { await siblingViewModel.disposeDirectConversation() }
            if let firstViewModel { await firstViewModel.disposeDirectConversation() }
            if let runtime { await runtime.stop() }
            if loggedIn { try? await api.directLogout() }
            throw error
        }
    }

    @MainActor
    private func waitForNativeTranscript(
        in viewModel: ChatViewModel,
        user: String,
        assistant: String
    ) async throws {
        // The controller's terminal event is followed by its canonical REST
        // refresh. Wait for that replacement rather than treating the local
        // optimistic row and terminal event as durable proof.
        for _ in 0..<450 {
            let users = viewModel.messages.filter { $0.role == "user" }
            let assistants = viewModel.messages.filter { $0.role == "assistant" }
            if users.count == 1, assistants.count == 1,
               users[0].content == user, assistants[0].content == assistant,
               let userID = users[0].messageId, !userID.hasPrefix("local-"),
               let assistantID = assistants[0].messageId, !assistantID.hasPrefix("stream-"),
               viewModel.activeStreamID == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LiveSmokeInvariant.failed
    }

    @MainActor
    private func waitForNativeDirectRun(in viewModel: ChatViewModel) async throws {
        for _ in 0..<300 {
            if viewModel.activeStreamID != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LiveSmokeInvariant.failed
    }

    @MainActor
    private func waitForNativeReasoningCapability(in viewModel: ChatViewModel) async throws {
        for _ in 0..<300 {
            if viewModel.allowsReasoningChangesWhileStreaming,
               viewModel.supportedReasoningEfforts?.contains("high") == true {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LiveSmokeInvariant.failed
    }

    @MainActor
    private func waitForNativeReasoningTranscript(
        in viewModel: ChatViewModel,
        expected: [(String, String)]
    ) async throws {
        for _ in 0..<450 {
            let durable = viewModel.messages.filter { $0.role == "user" || $0.role == "assistant" }
            let users = durable.filter { $0.role == "user" }
            let assistants = durable.filter { $0.role == "assistant" }
            let pairsMatch = users.count == expected.count
                && assistants.count == expected.count
                && durable.map(\.role) == expected.flatMap { _ in ["user", "assistant"] }
                && zip(users, expected).allSatisfy { $0.0.content == $0.1.0 }
                && zip(assistants, expected).allSatisfy { $0.0.content == $0.1.1 }
            let durableIDs = durable.allSatisfy { message in
                guard let id = message.messageId else { return false }
                return message.role == "user" ? !id.hasPrefix("local-") : !id.hasPrefix("stream-")
            }
            if pairsMatch, durableIDs, viewModel.activeStreamID == nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LiveSmokeInvariant.failed
    }

    private static func readCredentials(development: Bool = false) throws -> LiveCredentials {
        let path = development ? developmentCredentialsPath : defaultCredentialsPath
        let url = URL(fileURLWithPath: path)
        guard url.resolvingSymlinksInPath().path == path else { throw LiveSmokeInvariant.failed }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try JSONDecoder().decode(LiveCredentials.self, from: data)
    }

    private static func gatewayRestartMarkerURL(
        environment: [String: String],
        nonce: String
    ) throws -> URL {
        guard nonce.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil else {
            throw LiveSmokeInvariant.failed
        }
        guard let rawPath = environment["SEMREH_SLICE3_GATEWAY_RESTART_COORDINATION_PATH"] else {
            throw LiveSmokeInvariant.failed
        }
        let url = URL(fileURLWithPath: rawPath)
        let runtimeRoot = URL(fileURLWithPath: Self.defaultCredentialsPath)
            .deletingLastPathComponent()
        guard url.isFileURL,
              url.path == url.standardizedFileURL.path,
              url.deletingLastPathComponent().path == runtimeRoot.path,
              url.lastPathComponent == "slice3-gateway-restart-\(nonce).json",
              url.deletingLastPathComponent().resolvingSymlinksInPath().path == runtimeRoot.path,
              !FileManager.default.fileExists(atPath: url.path) else {
            throw LiveSmokeInvariant.failed
        }
        return url
    }

    private static func writeGatewayRestartMarker(
        url: URL,
        nonce: String,
        phase: String
    ) throws {
        guard ["ready", "complete"].contains(phase) else { throw LiveSmokeInvariant.failed }
        let object: [String: String] = [
            "kind": "semreh-slice3-gateway-restart-v1",
            "nonce": nonce,
            "phase": phase
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func waitForGatewayRestartMarker(url: URL, nonce: String) async throws {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object.count == 3,
               object["kind"] as? String == "semreh-slice3-gateway-restart-v1",
               object["nonce"] as? String == nonce,
               object["phase"] as? String == "restart-complete" {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LiveSmokeInvariant.failed
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

private final class LiveActiveSocketLossFactory: @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var sockets: [LiveActiveSocketLossWebSocket] = []
    private var promptSubmits = 0

    init(session: URLSession) {
        self.session = session
    }

    func make(request: URLRequest) -> HermesGatewayWebSocket {
        let socket = LiveActiveSocketLossWebSocket(
            task: session.webSocketTask(with: request),
            onMessage: { [weak self] message in self?.record(message) }
        )
        lock.lock()
        sockets.append(socket)
        lock.unlock()
        return socket
    }

    func cancelOnlySocket() -> Bool {
        lock.lock()
        let socket = sockets.count == 1 ? sockets.last : nil
        lock.unlock()
        socket?.cancel(with: .abnormalClosure, reason: nil)
        return socket != nil
    }

    var socketCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sockets.count
    }

    var promptSubmitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return promptSubmits
    }

    private func record(_ message: URLSessionWebSocketTask.Message) {
        guard case let .string(raw) = message,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "prompt.submit"
        else { return }
        lock.lock()
        promptSubmits += 1
        lock.unlock()
    }
}

private final class LiveActiveSocketLossWebSocket: HermesGatewayWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let onMessage: (URLSessionWebSocketTask.Message) -> Void

    init(
        task: URLSessionWebSocketTask,
        onMessage: @escaping (URLSessionWebSocketTask.Message) -> Void
    ) {
        self.task = task
        self.onMessage = onMessage
    }

    func resume() {
        task.resume()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        onMessage(message)
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }
}

/// Real URLSession transport wrapper used only by the opt-in pre-ACK smoke.
/// It drops one matching JSON-RPC success response at the client receive
/// boundary while returning every gateway event and every other response.
private final class LivePreACKLossFactory: @unchecked Sendable {
    private let session: URLSession
    private let targetPrompt: String
    private let lock = NSLock()
    private var sockets: [LivePreACKLossWebSocket] = []
    private var promptSubmits = 0
    private var targetSubmits = 0
    private var targetRequestID: String?
    private var droppedTargetSuccesses = 0

    init(session: URLSession, targetPrompt: String) {
        self.session = session
        self.targetPrompt = targetPrompt
    }

    func make(request: URLRequest) -> HermesGatewayWebSocket {
        let socket = LivePreACKLossWebSocket(
            task: session.webSocketTask(with: request),
            onSend: { [weak self] message in self?.recordOutgoing(message) },
            shouldDrop: { [weak self] message in self?.dropTargetSuccess(message) ?? false }
        )
        lock.lock()
        sockets.append(socket)
        lock.unlock()
        return socket
    }

    func cancelOnlySocket() -> Bool {
        lock.lock()
        let socket = sockets.count == 1 ? sockets.last : nil
        lock.unlock()
        socket?.cancel(with: .abnormalClosure, reason: nil)
        return socket != nil
    }

    var socketCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sockets.count
    }

    var promptSubmitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return promptSubmits
    }

    var targetSubmitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return targetSubmits
    }

    var droppedTargetSuccessCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedTargetSuccesses
    }

    private func recordOutgoing(_ message: URLSessionWebSocketTask.Message) {
        guard case let .string(raw) = message,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "prompt.submit" else { return }
        lock.lock()
        promptSubmits += 1
        if let params = object["params"] as? [String: Any],
           params["text"] as? String == targetPrompt {
            targetSubmits += 1
            if let requestID = Self.requestID(object["id"]), targetRequestID == nil {
                targetRequestID = requestID
            }
        }
        lock.unlock()
    }

    private func dropTargetSuccess(_ message: URLSessionWebSocketTask.Message) -> Bool {
        guard case let .string(raw) = message,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] == nil,
              object["result"] != nil,
              let requestID = Self.requestID(object["id"]) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard requestID == targetRequestID, droppedTargetSuccesses == 0 else { return false }
        droppedTargetSuccesses += 1
        return true
    }

    private static func requestID(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}

private final class LivePreACKLossWebSocket: HermesGatewayWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let onSend: (URLSessionWebSocketTask.Message) -> Void
    private let shouldDrop: (URLSessionWebSocketTask.Message) -> Bool

    init(
        task: URLSessionWebSocketTask,
        onSend: @escaping (URLSessionWebSocketTask.Message) -> Void,
        shouldDrop: @escaping (URLSessionWebSocketTask.Message) -> Bool
    ) {
        self.task = task
        self.onSend = onSend
        self.shouldDrop = shouldDrop
    }

    func resume() {
        task.resume()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        onSend(message)
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        while true {
            let message = try await task.receive()
            if !shouldDrop(message) { return message }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
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

@MainActor
private final class NativeSmokeNoopLiveActivityManager: AgentLiveActivityManaging {
    func start(sessionID: String, sessionTitle: String, streamID: String?) {}
    func update(_ event: AgentLiveActivityEvent) {}
    func markStale() {}
    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {}
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
