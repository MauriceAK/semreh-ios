import XCTest
@testable import HermesMobile

@MainActor
final class GatewayConversationGoalTests: XCTestCase {
    func testDraftGoalPreparationCreatesCanonicalBindingWithoutSubmittingPrompt() async throws {
        let fixture = try await makeFixture(profile: "selected", mode: .output("unused"), storedID: nil)

        let binding = try await fixture.controller.prepareGoalSession(create: [
            "cwd": .string("/workspace"), "model": .string("model"),
            "provider": .string("provider"), "reasoning_effort": .string("high"),
            "fast": .bool(true), "ignored": .string("never forwarded")
        ])
        let repeated = try await fixture.controller.prepareGoalSession(create: [:])

        XCTAssertEqual(binding, repeated)
        XCTAssertEqual(binding.storedID, "created-session")
        XCTAssertEqual(fixture.controller.storedID, "created-session")
        XCTAssertEqual(fixture.transport.requestedMethods.filter { $0 == "session.create" }.count, 1)
        XCTAssertFalse(fixture.transport.requestedMethods.contains("prompt.submit"))
        XCTAssertEqual(fixture.transport.createParams, [
            "cwd": .string("/workspace"), "model": .string("model"),
            "provider": .string("provider"), "reasoning_effort": .string("high"),
            "fast": .bool(true), "profile": .string("selected"),
            "close_on_disconnect": .bool(false)
        ])
        await fixture.runtime.stop()
    }

    func testLostDraftCreateIsQuarantinedAndNeverRetried() async throws {
        let fixture = try await makeFixture(profile: "default", mode: .lostCreate, storedID: nil)
        for _ in 0..<2 {
            do {
                _ = try await fixture.controller.prepareGoalSession(create: ["cwd": .string("/workspace")])
                XCTFail("Expected unknown create outcome")
            } catch { XCTAssertEqual(error as? DirectGoalError, .outcomeUnknown) }
        }
        XCTAssertEqual(fixture.transport.requestedMethods.filter { $0 == "session.create" }.count, 1)
        XCTAssertFalse(fixture.transport.requestedMethods.contains("prompt.submit"))
        await fixture.runtime.stop()
    }

    func testRunningCurrentProfileGatesDispatchWhileStickyActiveIsIrrelevant() async throws {
        let fixture = try await makeFixture(profile: "selected", mode: .output("No active goal."))

        let result = try await fixture.controller.dispatchGoal(
            "status",
            profileContext: DirectHermesActiveProfile(active: "other", current: "selected")
        )

        XCTAssertEqual(result, .output("No active goal."))
        XCTAssertEqual(fixture.transport.commandMethods, ["command.resolve", "command.dispatch"])
        XCTAssertEqual(fixture.transport.resolveParams, ["name": .string("goal")])
        XCTAssertEqual(fixture.transport.dispatchParams, [
            "session_id": .string("runtime-session"),
            "name": .string("goal"),
            "arg": .string("status")
        ])
        await fixture.runtime.stop()
    }

    func testMissingOrMismatchedRunningProfileRefusesBeforeCommandRPC() async throws {
        let missing = try await makeFixture(profile: "selected", mode: .output("unused"))
        do {
            _ = try await missing.controller.dispatchGoal(
                "status", profileContext: DirectHermesActiveProfile(active: "selected", current: nil)
            )
            XCTFail("Expected missing-current refusal")
        } catch { XCTAssertEqual(error as? DirectGoalError, .runningProfileUnavailable) }
        XCTAssertTrue(missing.transport.commandMethods.isEmpty)

        let mismatch = try await makeFixture(profile: "selected", mode: .output("unused"))
        do {
            _ = try await mismatch.controller.dispatchGoal(
                "status", profileContext: DirectHermesActiveProfile(active: "selected", current: "gateway")
            )
            XCTFail("Expected current-profile refusal")
        } catch {
            XCTAssertEqual(error as? DirectGoalError, .runningProfileMismatch(selected: "selected", current: "gateway"))
        }
        XCTAssertTrue(mismatch.transport.commandMethods.isEmpty)
        await missing.runtime.stop()
        await mismatch.runtime.stop()
    }

    func testBoundRunningTurnAllowsOnlyStatusPauseAndClearAsOutputControls() async throws {
        for command in ["status", "pause", "clear"] {
            let fixture = try await makeFixture(profile: "default", mode: .output("controlled \(command)"))
            fixture.transport.emit(type: "message.start", payload: [:])
            await drainEvents()
            XCTAssertEqual(fixture.controller.runState, .running)

            let result = try await fixture.controller.dispatchGoal(
                command, profileContext: DirectHermesActiveProfile(active: nil, current: "default")
            )

            XCTAssertEqual(result, .output("controlled \(command)"))
            XCTAssertEqual(fixture.controller.runState, .running)
            XCTAssertEqual(fixture.transport.commandMethods, ["command.resolve", "command.dispatch"])
            await fixture.runtime.stop()
        }
    }

    func testRunningTurnRejectsGoalTextAndResumeBeforeCommandRPC() async throws {
        for command in ["Ship it", "resume"] {
            let fixture = try await makeFixture(profile: "default", mode: .output("unused"))
            fixture.transport.emit(type: "message.start", payload: [:])
            await drainEvents()
            do {
                _ = try await fixture.controller.dispatchGoal(
                    command, profileContext: DirectHermesActiveProfile(active: nil, current: "default")
                )
                XCTFail("Expected running rejection for \(command)")
            } catch { XCTAssertTrue(error is DirectSessionError) }
            XCTAssertTrue(fixture.transport.commandMethods.isEmpty)
            await fixture.runtime.stop()
        }
    }

    func testRunningControlNeverReturnsSendAndTurnTransitionsAreScoped() async throws {
        let send = try await makeFixture(profile: "default", mode: .send)
        send.transport.emit(type: "message.start", payload: [:])
        await drainEvents()
        do {
            _ = try await send.controller.dispatchGoal(
                "pause", profileContext: DirectHermesActiveProfile(active: nil, current: "default")
            )
            XCTFail("A running control must never launch a prompt")
        } catch { XCTAssertEqual(error as? DirectGoalError, .unsupportedResult) }
        XCTAssertFalse(send.transport.requestedMethods.contains("prompt.submit"))
        XCTAssertEqual(send.controller.runState, .running)

        let transitioned = try await makeFixture(profile: "default", mode: .completeAfterResolve)
        transitioned.transport.emit(type: "message.start", payload: [:])
        await drainEvents()
        do {
            _ = try await transitioned.controller.dispatchGoal(
                "clear", profileContext: DirectHermesActiveProfile(active: nil, current: "default")
            )
            XCTFail("Expected turn transition rejection")
        } catch { XCTAssertTrue(error is DirectSessionError) }
        XCTAssertEqual(transitioned.transport.commandMethods, ["command.resolve"])
        XCTAssertEqual(transitioned.controller.runState, .idle)
        await send.runtime.stop()
        await transitioned.runtime.stop()
    }

    func testSendAndPluginShapesAreTypedWithoutSubmittingPrompt() async throws {
        let send = try await makeFixture(profile: "default", mode: .send)
        let sendResult = try await send.controller.dispatchGoal(
            "resume", profileContext: DirectHermesActiveProfile(active: nil, current: "default")
        )
        XCTAssertEqual(
            sendResult,
            .send(notice: "Goal resumed", message: "[Continuing toward your standing goal] next", display: "/goal resume")
        )
        XCTAssertFalse(send.transport.requestedMethods.contains("prompt.submit"))

        let plugin = try await makeFixture(profile: "default", mode: .plugin)
        let pluginResult = try await plugin.controller.dispatchGoal(
            "status", profileContext: DirectHermesActiveProfile(active: nil, current: "default")
        )
        XCTAssertEqual(pluginResult, .output("plugin-owned goal output"))
        await send.runtime.stop()
        await plugin.runtime.stop()
    }

    func testLostDispatchAndStalePostDispatchAreUnknownAndNeverRetried() async throws {
        for mode in [GoalTransport.Mode.lostDispatch, .staleAfterDispatch] {
            let fixture = try await makeFixture(profile: "default", mode: mode)
            do {
                _ = try await fixture.controller.dispatchGoal(
                    "Ship it", profileContext: DirectHermesActiveProfile(active: nil, current: "default")
                )
                XCTFail("Expected unknown outcome")
            } catch { XCTAssertEqual(error as? DirectGoalError, .outcomeUnknown) }
            XCTAssertEqual(fixture.transport.commandMethods.filter { $0 == "command.dispatch" }.count, 1)
            await fixture.runtime.stop()
        }
    }

    func testAliasIsNotFollowed() async throws {
        let fixture = try await makeFixture(profile: "default", mode: .alias)
        do {
            _ = try await fixture.controller.dispatchGoal(
                "status", profileContext: DirectHermesActiveProfile(active: nil, current: "default")
            )
            XCTFail("Expected bounded alias refusal")
        } catch { XCTAssertEqual(error as? DirectGoalError, .unsupportedResult) }
        XCTAssertEqual(fixture.transport.commandMethods, ["command.resolve", "command.dispatch"])
        await fixture.runtime.stop()
    }

    func testMalformedAcknowledgementIsUnknownButServerRefusalRemainsDefinite() async throws {
        let malformed = try await makeFixture(profile: "default", mode: .malformed)
        do {
            _ = try await malformed.controller.dispatchGoal(
                "status", profileContext: DirectHermesActiveProfile(active: nil, current: "default")
            )
            XCTFail("Expected malformed acknowledged outcome")
        } catch { XCTAssertEqual(error as? DirectGoalError, .outcomeUnknown) }
        XCTAssertEqual(malformed.transport.commandMethods.filter { $0 == "command.dispatch" }.count, 1)

        let refused = try await makeFixture(profile: "default", mode: .serverRefusal)
        do {
            _ = try await refused.controller.dispatchGoal(
                "status", profileContext: DirectHermesActiveProfile(active: nil, current: "default")
            )
            XCTFail("Expected definite RPC refusal")
        } catch HermesGatewayError.server(let code, _, _, let method, _, _) {
            XCTAssertEqual(code, 4004)
            XCTAssertEqual(method, "command.dispatch")
        } catch {
            XCTFail("Expected structured server refusal, got \(error)")
        }
        XCTAssertEqual(refused.transport.commandMethods.filter { $0 == "command.dispatch" }.count, 1)
        await malformed.runtime.stop()
        await refused.runtime.stop()
    }

    func testUnsolicitedServerContinuationIsAcceptedAsANewTurn() async throws {
        let fixture = try await makeFixture(profile: "default", mode: .output("unused"))
        var delivered: [String] = []
        fixture.controller.onEvent = { delivered.append($0.type) }

        fixture.transport.emit(type: "message.start", payload: [:])
        fixture.transport.emit(type: "message.delta", payload: ["text": .string("first")])
        fixture.transport.emit(type: "message.complete", payload: ["status": .string("complete"), "text": .string("first")])
        await drainEvents()
        XCTAssertEqual(fixture.controller.runState, .idle)

        fixture.transport.emit(type: "message.start", payload: [:])
        fixture.transport.emit(type: "message.delta", payload: ["text": .string("continuation")])
        fixture.transport.emit(type: "message.complete", payload: ["status": .string("complete"), "text": .string("continuation")])
        await drainEvents()

        XCTAssertEqual(fixture.controller.runState, .idle)
        XCTAssertEqual(delivered.filter { $0 == "message.start" }.count, 2)
        XCTAssertEqual(delivered.filter { $0 == "message.delta" }.count, 2)
        XCTAssertEqual(delivered.filter { $0 == "message.complete" }.count, 2)
        await fixture.runtime.stop()
    }

    private func makeFixture(
        profile: String, mode: GoalTransport.Mode, storedID: String? = "stored-session"
    ) async throws -> (
        controller: GatewayConversationController, runtime: HermesServerRuntime, transport: GoalTransport
    ) {
        let transport = GoalTransport(mode: mode)
        let runtime = try HermesServerRuntime(origin: XCTUnwrap(URL(string: "https://goal.example.test"))) { sink in
            transport.installSink(sink)
            return transport
        }
        let controller = GatewayConversationController(runtime: runtime, storedID: storedID, profile: profile) {
            id, _, _, _ in DirectHermesTranscriptPage(sessionID: id, messages: [], pagination: nil)
        }
        try await controller.open()
        return (controller, runtime, transport)
    }

    private func drainEvents() async { for _ in 0..<80 { await Task.yield() } }
}

private final class GoalTransport: HermesGatewayTransport, @unchecked Sendable {
    enum Mode {
        case output(String), send, plugin, alias, malformed, serverRefusal, lostCreate, lostDispatch,
             completeAfterResolve, staleAfterDispatch
    }
    private let lock = NSLock()
    private let mode: Mode
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var generation = 0
    private var sequence = 0
    private var methods: [String] = []
    private var parameters: [String: [String: JSONValue]] = [:]

    init(mode: Mode) { self.mode = mode }
    var requestedMethods: [String] { lock.withLock { methods } }
    var commandMethods: [String] { requestedMethods.filter { $0.hasPrefix("command.") } }
    var resolveParams: [String: JSONValue]? { lock.withLock { parameters["command.resolve"] } }
    var dispatchParams: [String: JSONValue]? { lock.withLock { parameters["command.dispatch"] } }
    var createParams: [String: JSONValue]? { lock.withLock { parameters["session.create"] } }
    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) { lock.withLock { self.sink = sink } }
    func connect() async throws { lock.withLock { generation += 1 } }
    func close() async {}
    func connectionIdentifier() async -> Int? { lock.withLock { generation } }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        lock.withLock {
            methods.append(method)
            parameters[method] = params?.gatewayFields
        }
        if method == "session.resume" {
            return .object(["session_id": .string("runtime-session"), "session_key": .string("stored-session"), "running": .bool(false)])
        }
        if method == "session.create" {
            if case .lostCreate = mode { throw HermesGatewayError.transport("lost create") }
            return .object([
                "session_id": .string("runtime-created"),
                "session_key": .string("created-session")
            ])
        }
        if method == "command.resolve" {
            if case .completeAfterResolve = mode {
                emit(type: "message.complete", payload: ["status": .string("complete"), "text": .string("done")])
                for _ in 0..<20 { await Task.yield() }
            }
            return .object(["canonical": .string("goal")])
        }
        guard method == "command.dispatch" else { return .object([:]) }
        switch mode {
        case .output(let output): return .object(["type": .string("exec"), "output": .string(output)])
        case .send:
            return .object(["type": .string("send"), "notice": .string("Goal resumed"),
                "message": .string("[Continuing toward your standing goal] next"), "display": .string("/goal resume")])
        case .plugin: return .object(["type": .string("plugin"), "output": .string("plugin-owned goal output")])
        case .alias: return .object(["type": .string("alias"), "target": .string("other")])
        case .malformed: return .object(["type": .string("send")])
        case .serverRefusal:
            throw HermesGatewayError.server(
                code: 4004, message: "goal refused", data: nil,
                method: "command.dispatch", requestID: "goal-refusal", server: nil
            )
        case .lostCreate: return .object([:])
        case .lostDispatch: throw HermesGatewayError.transport("lost")
        case .completeAfterResolve: return .object([:])
        case .staleAfterDispatch:
            emit(type: "message.start", payload: [:])
            for _ in 0..<20 { await Task.yield() }
            return .object(["type": .string("exec"), "output": .string("stale")])
        }
    }

    func emit(type: String, payload: [String: JSONValue]) {
        let delivery = lock.withLock { () -> ((@Sendable (HermesGatewayEvent) -> Void)?, HermesGatewayEvent) in
            sequence += 1
            return (sink, HermesGatewayEvent(method: "event", type: type, sessionID: "runtime-session", sequence: sequence,
                payload: .object(payload), params: nil, connectionGeneration: generation))
        }
        delivery.0?(delivery.1)
    }
}
