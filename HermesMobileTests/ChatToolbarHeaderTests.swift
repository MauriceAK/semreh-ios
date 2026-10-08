import SwiftUI
import XCTest
import UIKit
@testable import HermesMobile

final class ChatToolbarHeaderTests: XCTestCase {
    func testSubtitleUsesWorkspaceBasenameBeforeProfile() {
        XCTAssertEqual(
            ChatToolbarSubtitleResolver.subtitle(
                workspacePath: "/Users/example/hermes-mobile",
                profileTitle: "Default"
            ),
            "hermes-mobile"
        )
    }

    func testSubtitleFallsBackToStableProfileTitle() {
        XCTAssertEqual(
            ChatToolbarSubtitleResolver.subtitle(
                workspacePath: nil,
                profileTitle: "Work"
            ),
            "Work"
        )
    }

    func testSubtitleOmitsGenericOrBlankContext() {
        XCTAssertNil(ChatToolbarSubtitleResolver.subtitle(workspacePath: nil, profileTitle: "Profile"))
        XCTAssertNil(ChatToolbarSubtitleResolver.subtitle(workspacePath: "   ", profileTitle: "   "))
    }
}

@MainActor
final class ChatBotHeaderGeometryTests: XCTestCase {
    func testIdleDefaultNameCapsuleHasCompactSingleLineHeight() {
        let capsule = UIHostingController(rootView: ChatBotNameCapsule(title: "Default")
            .environment(\.dynamicTypeSize, .large))
        let size = capsule.sizeThatFits(in: CGSize(width: 260, height: 1_000))
        XCTAssertEqual(size.height, 32, accuracy: 0.5,
                       "The visible glass must not include an invisible activity row")
        XCTAssertGreaterThan(size.width, 52)
    }

    func testLongNameCanUseTwoLinesAtAccessibilitySize() {
        let title = "A long descriptive profile name for accessibility"
        let ordinary = measure(ChatBotNameCapsule(title: title), typeSize: .large)
        let accessible = measure(ChatBotNameCapsule(title: title), typeSize: .accessibility3)
        XCTAssertGreaterThan(accessible.height, ordinary.height,
                             "Restoring a compact idle capsule must not clip large profile names")
    }

    func testIdleAndActivityKeepTheSameHeaderFootprintWithDynamicType() async throws {
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            for title in ["Default", "A long descriptive profile name for accessibility"] {
                let (vm, runtime, controller, transport) = try makeRuntimeFixture()
                try await runtime.connect()
                XCTAssertEqual(controller.runState, .idle)
                XCTAssertNil(vm.displayedHeaderActivityPhase)
                func fittedHeader(showsActivity: Bool = true) -> CGSize {
                    measure(ChatBotActivityHeader(viewModel: vm, showsActivity: showsActivity) {
                        VStack(spacing: -3) {
                            Color.clear.frame(width: 52, height: 52)
                            ChatBotNameCapsule(title: title)
                        }
                    }, typeSize: typeSize)
                }
                let nameOnly = fittedHeader(showsActivity: false)
                let idle = fittedHeader()
                XCTAssertGreaterThan(idle.height, nameOnly.height,
                                     "The stable activity slot belongs outside the visible name capsule")
                XCTAssertEqual(idle.width, nameOnly.width, accuracy: 0.5)
                emit(vm, "status.update", ["kind": .string("compacting")])
                XCTAssertEqual(vm.displayedHeaderActivityPhase, .summarizing)
                var sizes = [fittedHeader()]
                emit(vm, "status.update", ["kind": .string("status"), "text": .string("ready")])
                XCTAssertNil(vm.displayedHeaderActivityPhase)
                sizes.append(fittedHeader())
                // A VM event alone cannot prove activity is visible. Bind a real
                // controlled runtime/controller and receive an authoritative
                // running resume, as production does for an existing live turn.
                await transport.setResumeRunning(true)
                try await runtime.reconnect()
                XCTAssertEqual(controller.runState, .running)
                XCTAssertNotNil(vm.activeStreamID)
                XCTAssertEqual(vm.displayedHeaderActivityPhase, .working)
                sizes.append(fittedHeader())
                emit(vm, "tool.start", ["tool_id": .string("search"), "name": .string("web_search")])
                XCTAssertEqual(vm.displayedHeaderActivityPhase, .searching)
                sizes.append(fittedHeader())
                emit(vm, "tool.start", ["tool_id": .string("read"), "name": .string("read_file")])
                XCTAssertEqual(vm.displayedHeaderActivityPhase, .reading)
                sizes.append(fittedHeader())
                emit(vm, "message.delta", ["text": .string("A response")])
                XCTAssertEqual(vm.displayedHeaderActivityPhase, .replying)
                sizes.append(fittedHeader())
                emit(vm, "message.complete", ["status": .string("complete")])
                XCTAssertNil(vm.displayedHeaderActivityPhase)
                sizes.append(fittedHeader())
                for size in sizes {
                    XCTAssertEqual(size.height, idle.height, accuracy: 0.5,
                                   "Activity must not move the transcript or composer")
                    XCTAssertEqual(size.width, idle.width, accuracy: 0.5)
                }
                await runtime.stop()
            }
        }
    }

    private func measure<Content: View>(_ content: Content, typeSize: DynamicTypeSize) -> CGSize {
        UIHostingController(rootView: content
            .environment(\.dynamicTypeSize, typeSize))
            .sizeThatFits(in: CGSize(width: 260, height: 1_000))
    }

    private func makeRuntimeFixture() throws
        -> (ChatViewModel, HermesServerRuntime, GatewayConversationController, HeaderGeometryGatewayTransport) {
        let server = URL(string: "https://example.test")!
        let transport = HeaderGeometryGatewayTransport()
        let runtime = try HermesServerRuntime(origin: server) { _ in transport }
        let uncertainty = InMemoryDirectPromptDeliveryUncertaintyStore()
        let controller = GatewayConversationController(runtime: runtime, storedID: "header-durable",
            promptUncertaintyStore: uncertainty) { id, _, _, _ in
                DirectHermesTranscriptPage(sessionID: id, messages: [], pagination: nil)
            }
        let vm = ChatViewModel(session: SessionSummary(sessionId: "header-durable", title: "Header"), server: server,
            gatewayRuntimeProvider: { _ in runtime }, promptUncertaintyStore: uncertainty,
            initialDirectConversation: controller)
        return (vm, runtime, controller, transport)
    }

    private func emit(_ vm: ChatViewModel, _ type: String, _ payload: [String: JSONValue] = [:]) {
        vm.handleDirectEventForTesting(HermesGatewayEvent(method: "event", type: type,
            sessionID: "header-geometry", sequence: nil, payload: .object(payload), params: nil))
    }
}

/// In-memory stock-shaped resume responses; no backend or provider access.
private actor HeaderGeometryGatewayTransport: HermesGatewayTransport {
    private var generation = 0
    private var connected = false
    private var resumeRunning = false

    func setResumeRunning(_ value: Bool) { resumeRunning = value }
    func connect() async throws {
        generation += 1
        connected = true
    }
    func close() async { connected = false }
    func connectionIdentifier() async -> Int? { connected ? generation : nil }
    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        if method == "session.resume" {
            return .object(["session_id": .string("header-runtime"), "session_key": .string("header-durable"),
                            "running": .bool(resumeRunning)])
        }
        throw DirectSessionError.invalidResponse
    }
}

@MainActor
final class ChatChromeActivationTests: XCTestCase {
    func testOneTouchUpUsesLatestActionWithoutTouchDownOrDuplicateDispatch() {
        let button = ChatChromeButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        var calls: [String] = []
        button.onActivate = { calls.append("old") }
        button.sendActions(for: .touchDown)
        XCTAssertTrue(calls.isEmpty)
        // SwiftUI may update the closure during streaming or a held press.
        button.onActivate = { calls.append("current") }
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, ["current"])
        XCTAssertTrue(button.isAccessibilityElement)
        XCTAssertTrue(button.accessibilityTraits.contains(.button))
        XCTAssertEqual(button.bounds.size, CGSize(width: 44, height: 44))
        button.isEnabled = false
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, ["current"])
    }

    func testFirstActivationClearsDestinationAndBlocksLateAuthoritativeRestore() {
        let session = SessionSummary(sessionId: "reader", title: "Reader")
        var navigation = SessionNavigationState(lastSelectedSessionID: "reader")
        navigation.select(session)
        let button = ChatChromeButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        button.onActivate = { navigation.clearDestination() }
        button.sendActions(for: .touchUpInside)
        XCTAssertNil(navigation.destination)
        navigation.reconcileAuthoritativeSelection(from: [session])
        XCTAssertNil(navigation.destination)
        XCTAssertEqual(navigation.lastSelectedSessionID, "reader")
    }
}
