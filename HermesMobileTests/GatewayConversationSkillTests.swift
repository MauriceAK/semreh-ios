import XCTest
@testable import HermesMobile

@MainActor
final class GatewayConversationSkillTests: XCTestCase {
    func testDynamicSkillUsesExactRPCFieldsAndReturnsOpaqueInvocation() async throws {
        let fixture = try await makeFixture(mode: .skill)
        let result = try await fixture.controller.dispatchSkill(
            name: "/review-work", arg: "check this",
            profileContext: DirectHermesActiveProfile(active: "other", current: "work")
        )

        XCTAssertEqual(result, .invocation(
            name: "Review Work", message: "opaque expanded scaffold", display: "/review-work check this"
        ))
        XCTAssertEqual(fixture.transport.commandMethods, ["command.resolve", "command.dispatch"])
        XCTAssertEqual(fixture.transport.resolveParams, ["name": .string("review-work")])
        XCTAssertEqual(fixture.transport.dispatchParams, [
            "session_id": .string("runtime-session"), "name": .string("review-work"),
            "arg": .string("check this")
        ])
        XCTAssertFalse(fixture.transport.requestedMethods.contains("prompt.submit"))
        await fixture.runtime.stop()
    }

    func testBundleAndIntentionalShadowOutputRemainTyped() async throws {
        let bundle = try await makeFixture(mode: .bundle)
        let bundleResult = try await bundle.controller.dispatchSkill(
            name: "review-work", arg: "all",
            profileContext: DirectHermesActiveProfile(active: nil, current: "work")
        )
        XCTAssertEqual(bundleResult, .bundle(
            message: "opaque bundle scaffold", notice: "Loading bundle", display: "/review-work all"
        ))

        let shadow = try await makeFixture(mode: .output)
        let outputResult = try await shadow.controller.dispatchSkill(
            name: "review-work", arg: "all",
            profileContext: DirectHermesActiveProfile(active: nil, current: "work")
        )
        XCTAssertEqual(outputResult, .output("plugin shadow output"))
        await bundle.runtime.stop()
        await shadow.runtime.stop()
    }

    func testAuthoritativeScaffoldAndDisplayWhitespaceIsPreservedExactly() async throws {
        let fixture = try await makeFixture(mode: .whitespace)
        let result = try await fixture.controller.dispatchSkill(
            name: "review-work", arg: "x",
            profileContext: DirectHermesActiveProfile(active: nil, current: "work")
        )

        XCTAssertEqual(result, .invocation(
            name: " Review Work ", message: "\n opaque scaffold \n", display: "  /review-work x  "
        ))
        await fixture.runtime.stop()
    }

    func testEmptyAuthoritativePluginOutputIsPreserved() async throws {
        let fixture = try await makeFixture(mode: .emptyOutput)
        let result = try await fixture.controller.dispatchSkill(
            name: "review-work", arg: "x",
            profileContext: DirectHermesActiveProfile(active: nil, current: "work")
        )

        XCTAssertEqual(result, .output(""))
        await fixture.runtime.stop()
    }

    func testCoreCollisionAndWrongRunningProfileRefuseBeforeDispatch() async throws {
        let core = try await makeFixture(mode: .reserved)
        do {
            _ = try await core.controller.dispatchSkill(
                name: "goal", arg: "x",
                profileContext: DirectHermesActiveProfile(active: nil, current: "work")
            )
            XCTFail("Expected core collision refusal")
        } catch { XCTAssertEqual(error as? DirectSkillDispatchError, .reservedCommand) }
        XCTAssertEqual(core.transport.commandMethods, ["command.resolve"])

        for context in [
            DirectHermesActiveProfile(active: "work", current: nil),
            DirectHermesActiveProfile(active: "work", current: "other")
        ] {
            let mismatch = try await makeFixture(mode: .skill)
            do {
                _ = try await mismatch.controller.dispatchSkill(name: "review-work", arg: "x", profileContext: context)
                XCTFail("Expected profile refusal")
            } catch {
                XCTAssertTrue(error is DirectSkillDispatchError)
            }
            XCTAssertTrue(mismatch.transport.commandMethods.isEmpty)
            await mismatch.runtime.stop()
        }
        await core.runtime.stop()
    }

    func testAliasMalformedLostAndStaleResultsNeverRetry() async throws {
        for mode in [SkillTransport.Mode.alias, .malformed, .lost, .stale] {
            let fixture = try await makeFixture(mode: mode)
            do {
                _ = try await fixture.controller.dispatchSkill(
                    name: "review-work", arg: "x",
                    profileContext: DirectHermesActiveProfile(active: nil, current: "work")
                )
                XCTFail("Expected bounded dispatch failure")
            } catch {
                if case .alias = mode {
                    XCTAssertEqual(error as? DirectSkillDispatchError, .unsupportedResult)
                } else {
                    XCTAssertEqual(error as? DirectSkillDispatchError, .outcomeUnknown)
                }
            }
            XCTAssertEqual(fixture.transport.commandMethods.filter { $0 == "command.dispatch" }.count, 1)
            XCTAssertFalse(fixture.transport.requestedMethods.contains("prompt.submit"))
            await fixture.runtime.stop()
        }
    }

    func testRunningControllerRejectsBeforeResolver() async throws {
        let fixture = try await makeFixture(mode: .skill)
        fixture.transport.emitStart()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(fixture.controller.runState, .running)
        do {
            _ = try await fixture.controller.dispatchSkill(
                name: "review-work", arg: "x",
                profileContext: DirectHermesActiveProfile(active: nil, current: "work")
            )
            XCTFail("Expected busy refusal")
        } catch { XCTAssertTrue(error is DirectSessionError) }
        XCTAssertTrue(fixture.transport.commandMethods.isEmpty)
        await fixture.runtime.stop()
    }

    func testConcurrentInvocationIsDefinitivelyBusyAndOnlyFirstReachesRPCs() async throws {
        let fixture = try await makeFixture(mode: .gatedSkill)
        let context = DirectHermesActiveProfile(active: nil, current: "work")
        let first = Task { @MainActor in
            try await fixture.controller.dispatchSkill(name: "review-work", arg: "first", profileContext: context)
        }
        await fixture.transport.waitUntilResolveEntered()

        do {
            _ = try await fixture.controller.dispatchSkill(
                name: "review-work", arg: "second", profileContext: context
            )
            XCTFail("Expected concurrent invocation refusal")
        } catch {
            XCTAssertEqual(error as? DirectSkillDispatchError, .alreadyDispatching)
        }
        XCTAssertEqual(fixture.transport.commandMethods, ["command.resolve"])

        await fixture.transport.releaseResolve()
        let result = try await first.value
        XCTAssertEqual(result, .invocation(
            name: "Review Work", message: "opaque expanded scaffold", display: "/review-work first"
        ))
        XCTAssertEqual(fixture.transport.commandMethods, ["command.resolve", "command.dispatch"])
        await fixture.runtime.stop()
    }

    private func makeFixture(mode: SkillTransport.Mode) async throws -> (
        controller: GatewayConversationController, runtime: HermesServerRuntime, transport: SkillTransport
    ) {
        let transport = SkillTransport(mode: mode)
        let runtime = try HermesServerRuntime(origin: XCTUnwrap(URL(string: "https://skill.example.test"))) { sink in
            transport.installSink(sink); return transport
        }
        let controller = GatewayConversationController(
            runtime: runtime,
            storedID: "stored-session",
            profile: "work",
            promptUncertaintyStore: InMemoryDirectPromptDeliveryUncertaintyStore()
        ) {
            id, _, _, _ in DirectHermesTranscriptPage(sessionID: id, messages: [], pagination: nil)
        }
        try await controller.open()
        return (controller, runtime, transport)
    }
}

private final class SkillTransport: HermesGatewayTransport, @unchecked Sendable {
    enum Mode {
        case skill, gatedSkill, bundle, output, emptyOutput, whitespace, reserved, alias, malformed, lost, stale
    }
    private let lock = NSLock()
    private let mode: Mode
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var generation = 0
    private var sequence = 0
    private var methods: [String] = []
    private var parameters: [String: [String: JSONValue]] = [:]
    private let resolveGate = SkillResolveGate()

    init(mode: Mode) { self.mode = mode }
    var requestedMethods: [String] { lock.withLock { methods } }
    var commandMethods: [String] { requestedMethods.filter { $0.hasPrefix("command.") } }
    var resolveParams: [String: JSONValue]? { lock.withLock { parameters["command.resolve"] } }
    var dispatchParams: [String: JSONValue]? { lock.withLock { parameters["command.dispatch"] } }
    func waitUntilResolveEntered() async { await resolveGate.waitUntilEntered() }
    func releaseResolve() async { await resolveGate.release() }
    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) { lock.withLock { self.sink = sink } }
    func connect() async throws { lock.withLock { generation += 1 } }
    func close() async {}
    func connectionIdentifier() async -> Int? { lock.withLock { generation } }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        lock.withLock { methods.append(method); parameters[method] = params?.gatewayFields }
        if method == "session.resume" {
            return .object(["session_id": .string("runtime-session"), "session_key": .string("stored-session"), "running": .bool(false)])
        }
        if method == "command.resolve" {
            if case .reserved = mode { return .object(["canonical": .string("goal")]) }
            if case .gatedSkill = mode { await resolveGate.enterAndWait() }
            throw HermesGatewayError.server(
                code: 4011, message: "unknown command", data: nil,
                method: "command.resolve", requestID: "resolve", server: nil
            )
        }
        guard method == "command.dispatch" else { return .object([:]) }
        switch mode {
        case .skill, .gatedSkill:
            return .object(["type": .string("skill"), "name": .string("Review Work"),
                "message": .string("opaque expanded scaffold"),
                "display": .string(mode.isGatedSkill ? "/review-work first" : "/review-work check this")])
        case .bundle:
            return .object(["type": .string("send"), "message": .string("opaque bundle scaffold"),
                "notice": .string("Loading bundle"), "display": .string("/review-work all")])
        case .output: return .object(["type": .string("plugin"), "output": .string("plugin shadow output")])
        case .emptyOutput: return .object(["type": .string("plugin"), "output": .string("")])
        case .whitespace:
            return .object(["type": .string("skill"), "name": .string(" Review Work "),
                "message": .string("\n opaque scaffold \n"), "display": .string("  /review-work x  ")])
        case .alias: return .object(["type": .string("alias"), "target": .string("other")])
        case .malformed: return .object(["type": .string("skill"), "message": .string("secret")])
        case .lost: throw HermesGatewayError.transport("lost")
        case .stale:
            emitStart()
            for _ in 0..<20 { await Task.yield() }
            return .object(["type": .string("skill"), "name": .string("Review Work"),
                "message": .string("secret"), "display": .string("/review-work x")])
        case .reserved: return .object([:])
        }
    }

    func emitStart() {
        let delivery = lock.withLock { () -> ((@Sendable (HermesGatewayEvent) -> Void)?, HermesGatewayEvent) in
            sequence += 1
            return (sink, HermesGatewayEvent(method: "event", type: "message.start", sessionID: "runtime-session",
                sequence: sequence, payload: .object([:]), params: nil, connectionGeneration: generation))
        }
        delivery.0?(delivery.1)
    }
}

private extension SkillTransport.Mode {
    var isGatedSkill: Bool {
        if case .gatedSkill = self { return true }
        return false
    }
}

private actor SkillResolveGate {
    private var entered = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
