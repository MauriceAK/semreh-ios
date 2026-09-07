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
