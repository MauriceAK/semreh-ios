import Foundation
import XCTest
@testable import SemrehRemoteBrowserCore

/// Test double: records performed actions and lets the test emit adapter events.
final class FakeBrowserAdapter: BrowserAdapter {
    var capabilities: RemoteBrowserCapabilities
    var onEvent: ((BrowserAdapterEvent) -> Void)?

    private(set) var performed: [(action: BrowserAdapterAction, commandID: CommandID)] = []

    init(capabilities: RemoteBrowserCapabilities = RemoteBrowserCapabilities(
        controlSupported: true,
        stopTaskSupported: false
    )) {
        self.capabilities = capabilities
    }

    func connect() {}
    func disconnect() {}

    func perform(_ action: BrowserAdapterAction, commandID: CommandID) {
        performed.append((action, commandID))
    }

    func emit(_ event: BrowserAdapterEvent) {
        onEvent?(event)
    }

    var humanActions: [BrowserAdapterAction] {
        performed.map(\.action)
    }
}

private func makeDescriptor(
    connectionGeneration: UInt64 = 1,
    surfaceGeneration: UInt64 = 1
) -> RemoteSurfaceDescriptor {
    RemoteSurfaceDescriptor(
        connection: ConnectionEpoch(generation: connectionGeneration),
        surface: SurfaceIdentity(generation: surfaceGeneration),
        sourceDimensions: PixelDimensions(width: 800, height: 600),
        hostDisplayName: "fixture.local"
    )
}

private func makeController(
    capabilities: RemoteBrowserCapabilities = RemoteBrowserCapabilities(
        controlSupported: true,
        stopTaskSupported: false
    )
) -> (BrowserSessionController, FakeBrowserAdapter) {
    let adapter = FakeBrowserAdapter(capabilities: capabilities)
    let controller = BrowserSessionController(adapter: adapter)
    adapter.onEvent = { controller.handle($0) }
    return (controller, adapter)
}

final class OwnershipStateTests: XCTestCase {

    // MARK: - Unavailable default

    func testUnavailableAdapterNeverGrantsControl() {
        let adapter = UnavailableBrowserAdapter()
        let controller = BrowserSessionController(adapter: adapter)
        adapter.onEvent = { controller.handle($0) }

        controller.connect()

        XCTAssertEqual(
            controller.state,
            .unavailable(reason: "Browser unavailable: no adapter configured.")
        )
        XCTAssertNil(controller.requestControl())
        XCTAssertNil(controller.sendHumanCommand(.click(RemotePoint(x: 0.5, y: 0.5))))
        XCTAssertEqual(controller.acceptedCommandCount, 0)
    }

    // MARK: - Request / grant

    func testRequestControlGrantEnablesCommands() {
        let (controller, adapter) = makeController()
        controller.handle(.connected(makeDescriptor(), adapter.capabilities))
        XCTAssertEqual(controller.state, .watching(controlSupported: true))

        let requestID = controller.requestControl()
        XCTAssertNotNil(requestID)
        XCTAssertEqual(controller.state, .requestPending(requestID: requestID!))
        XCTAssertFalse(controller.canSendHumanCommands)

        let descriptor = controller.currentSurface!
        adapter.emit(.controlGranted(ControlGrant(
            requestID: requestID!,
            connection: descriptor.connection,
            surface: descriptor.surface,
            revision: 1
        )))

        guard case .manual(let lease) = controller.state else {
            return XCTFail("expected manual, got \(controller.state)")
        }
        XCTAssertEqual(lease.clientIdentity, controller.clientIdentity)
        XCTAssertTrue(controller.canSendHumanCommands)

        let commandID = controller.sendHumanCommand(.click(RemotePoint(x: 0.5, y: 0.5)))
        XCTAssertNotNil(commandID)
        XCTAssertEqual(controller.acceptedCommandCount, 1)
        XCTAssertEqual(adapter.performed.count, 2) // requestControl + click
    }

    func testRequestControlRequiresControlSupport() {
        let (controller, adapter) = makeController(capabilities: RemoteBrowserCapabilities(
            controlSupported: false,
            stopTaskSupported: false
        ))
        controller.handle(.connected(makeDescriptor(), adapter.capabilities))
        XCTAssertEqual(controller.state, .watching(controlSupported: false))
        XCTAssertNil(controller.requestControl())
    }

    func testMismatchedGrantDispatchesZeroHumanCommands() {
        let (controller, adapter) = makeController()
        controller.handle(.connected(makeDescriptor(), adapter.capabilities))
        let requestID = controller.requestControl()!

        let descriptor = controller.currentSurface!
        // Wrong request ID: must be ignored.
        adapter.emit(.controlGranted(ControlGrant(
            requestID: UUID(),
            connection: descriptor.connection,
            surface: descriptor.surface,
            revision: 1
        )))
        XCTAssertEqual(controller.state, .requestPending(requestID: requestID))
        XCTAssertEqual(controller.ignoredGrantCount, 1)
        XCTAssertNil(controller.sendHumanCommand(.click(RemotePoint(x: 0.1, y: 0.1))))
        XCTAssertEqual(controller.acceptedCommandCount, 0)
    }

    func testDelayedGrantForSupersededRequestIsIgnored() {
        let (controller, adapter) = makeController()
        controller.handle(.connected(makeDescriptor(), adapter.capabilities))
        let first = controller.requestControl()!
        adapter.emit(.controlRequestRejected(requestID: first, reason: "nope"))
        XCTAssertEqual(controller.state, .watching(controlSupported: true))

        // The delayed grant for the dead request must not resurrect authority.
        let descriptor = controller.currentSurface!
        adapter.emit(.controlGranted(ControlGrant(
            requestID: first,
            connection: descriptor.connection,
            surface: descriptor.surface,
            revision: 1
        )))
        XCTAssertEqual(controller.state, .watching(controlSupported: true))
        XCTAssertEqual(controller.ignoredGrantCount, 1)
    }

    func testGrantWithStaleConnectionIsIgnored() {
        let (controller, adapter) = makeController()
        controller.handle(.connected(makeDescriptor(), adapter.capabilities))
        let requestID = controller.requestControl()!

        adapter.emit(.controlGranted(ControlGrant(
            requestID: requestID,
            connection: ConnectionEpoch(generation: 999),
            surface: SurfaceIdentity(generation: 999),
            revision: 1
        )))
        XCTAssertEqual(controller.ignoredGrantCount, 1)
        XCTAssertFalse(controller.canSendHumanCommands)
    }

    func testRejectedRequestReturnsToWatching() {
        let (controller, adapter) = makeController()
        controller.handle(.connected(makeDescriptor(), adapter.capabilities))
        let requestID = controller.requestControl()!
        adapter.emit(.controlRequestRejected(requestID: requestID, reason: "busy"))
        XCTAssertEqual(controller.state, .watching(controlSupported: true))
    }

    // MARK: - Lease invalidation

    func testSurfaceChangeVoidsManualLease() {
        let (controller, adapter) = makeController()
        controller.handle(.connected(makeDescriptor(), adapter.capabilities))
        let requestID = controller.requestControl()!
        let descriptor = controller.currentSurface!
        adapter.emit(.controlGranted(ControlGrant(
            requestID: requestID,
            connection: descriptor.connection,
            surface: descriptor.surface,
            revision: 1
        )))
        XCTAssertTrue(controller.canSendHumanCommands)

        adapter.emit(.surfaceChanged(SurfaceIdentity(generation: 2)))
        XCTAssertEqual(controller.state, .watching(controlSupported: true))
        XCTAssertNil(controller.sendHumanCommand(.click(RemotePoint(x: 0.5, y: 0.5))))
    }

    func testNewConnectionEpochNeverRestoresAuthority() {
        let (controller, adapter) = makeController()
        controller.handle(.connected(makeDescriptor(), adapter.capabilities))
        let requestID = controller.requestControl()!
        let descriptor = controller.currentSurface!
        adapter.emit(.controlGranted(ControlGrant(
            requestID: requestID,
            connection: descriptor.connection,
            surface: descriptor.surface,
            revision: 1
        )))
        XCTAssertTrue(controller.canSendHumanCommands)

        controller.handle(.connected(
            makeDescriptor(connectionGeneration: 2, surfaceGeneration: 1),
            adapter.capabilities
        ))
        XCTAssertEqual(controller.state, .watching(controlSupported: true))
        XCTAssertNil(controller.sendHumanCommand(.click(RemotePoint(x: 0.5, y: 0.5))))
        XCTAssertEqual(controller.acceptedCommandCount, 0)
    }

    func testDisconnectClearsLeaseAndInput() {
        let (controller, adapter) = makeController()
        controller.handle(.connected(makeDescriptor(), adapter.capabilities))
        let requestID = controller.requestControl()!
        let descriptor = controller.currentSurface!
        adapter.emit(.controlGranted(ControlGrant(
            requestID: requestID,
            connection: descriptor.connection,
            surface: descriptor.surface,
            revision: 1
        )))
        adapter.emit(.disconnected)
        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertNil(controller.sendHumanCommand(.click(RemotePoint(x: 0.5, y: 0.5))))
    }

    // MARK: - Resume

    private func makeManual(
        _ controller: BrowserSessionController,
        _ adapter: FakeBrowserAdapter
    ) -> ControlLease {
        controller.handle(.connected(makeDescriptor(), adapter.capabilities))
        let requestID = controller.requestControl()!
        let descriptor = controller.currentSurface!
        adapter.emit(.controlGranted(ControlGrant(
            requestID: requestID,
            connection: descriptor.connection,
            surface: descriptor.surface,
            revision: 1
        )))
        guard case .manual(let lease) = controller.state else {
            fatalError("expected manual")
        }
        return lease
    }

    func testResumeDisablesInputBeforeDispatch() {
        let (controller, adapter) = makeController()
        _ = makeManual(controller, adapter)

        controller.resumeHermes()

        // Input disabled immediately, before any dispatch could be observed.
        XCTAssertFalse(controller.canSendHumanCommands)
        guard case .resumePending(_, let known) = controller.state, known else {
            return XCTFail("expected known resumePending, got \(controller.state)")
        }
        XCTAssertEqual(adapter.humanActions.last, .resumeHermes)
        // Further human commands dispatch zero commands while resuming.
        XCTAssertNil(controller.sendHumanCommand(.click(RemotePoint(x: 0.5, y: 0.5))))
    }

    func testResumeAckReturnsToWatching() {
        let (controller, adapter) = makeController()
        _ = makeManual(controller, adapter)
        controller.resumeHermes()

        let resumeAction = adapter.performed.last!
        adapter.emit(.commandAcknowledged(resumeAction.commandID))
        XCTAssertEqual(controller.state, .watching(controlSupported: true))
    }

    func testResumeAckLostIsUnknownNotPaused() {
        let (controller, adapter) = makeController()
        _ = makeManual(controller, adapter)
        controller.resumeHermes()

        let resumeAction = adapter.performed.last!
        adapter.emit(.acknowledgementLost(resumeAction.commandID))

        guard case .resumePending(_, let known) = controller.state else {
            return XCTFail("expected resumePending, got \(controller.state)")
        }
        XCTAssertFalse(known, "lost acknowledgement must be UNKNOWN, not auto-paused")
        XCTAssertFalse(controller.canSendHumanCommands)
        // A fresh observation reconciles the unknown outcome.
        controller.handle(.connected(makeDescriptor(), adapter.capabilities))
        XCTAssertEqual(controller.state, .watching(controlSupported: true))
    }

    func testResumeIsNeverReplayedAutomatically() {
        let (controller, adapter) = makeController()
        _ = makeManual(controller, adapter)
        controller.resumeHermes()
        let resumeCount = adapter.humanActions.filter { $0 == .resumeHermes }.count

        let resumeAction = adapter.performed.last!
        adapter.emit(.acknowledgementLost(resumeAction.commandID))
        // Emit more events; the controller must not re-dispatch resume by itself.
        adapter.emit(.quiescent)
        controller.handleBackground()

        XCTAssertEqual(
            adapter.humanActions.filter { $0 == .resumeHermes }.count,
            resumeCount
        )
    }

    // MARK: - Background / close

    func testBackgroundNeverEmitsImplicitResume() {
        let (controller, adapter) = makeController()
        _ = makeManual(controller, adapter)

        controller.handleBackground()

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertFalse(adapter.humanActions.contains(.resumeHermes))
        XCTAssertNil(controller.sendHumanCommand(.click(RemotePoint(x: 0.5, y: 0.5))))
    }

    func testCloseNeverEmitsImplicitResume() {
        let (controller, adapter) = makeController()
        _ = makeManual(controller, adapter)

        controller.close()

        XCTAssertEqual(controller.state, .ended)
        XCTAssertFalse(adapter.humanActions.contains(.resumeHermes))
    }

    // MARK: - Stop task capability

    func testStopTaskRequiresCapability() {
        let (controller, adapter) = makeController()
        _ = makeManual(controller, adapter)
        XCTAssertNil(controller.sendHumanCommand(.stopTask))

        let (controller2, adapter2) = makeController(capabilities: RemoteBrowserCapabilities(
            controlSupported: true,
            stopTaskSupported: true
        ))
        _ = makeManual(controller2, adapter2)
        XCTAssertNotNil(controller2.sendHumanCommand(.stopTask))
    }

    // MARK: - Watch mode input

    func testWatchModeDispatchesZeroHumanCommands() {
        let (controller, _) = makeController()
        controller.handle(.connected(
            makeDescriptor(),
            RemoteBrowserCapabilities(controlSupported: false, stopTaskSupported: false)
        ))
        XCTAssertNil(controller.sendHumanCommand(.click(RemotePoint(x: 0.5, y: 0.5))))
        XCTAssertNil(controller.sendHumanCommand(.scroll(dx: 0, dy: 10)))
        XCTAssertNil(controller.sendHumanCommand(.insertText("hello")))
        XCTAssertEqual(controller.acceptedCommandCount, 0)
    }
}
