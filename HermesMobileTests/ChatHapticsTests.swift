import XCTest
import SwiftUI
import UIKit
@testable import HermesMobile

final class ChatHapticsTests: XCTestCase {
    @MainActor
    func testHapticsRespectEnabledSetting() {
        var feedback: [ChatHapticFeedback] = []

        ChatHaptics.messageSent(isEnabled: false) { feedback.append($0) }
        ChatHaptics.assistantResponseCompleted(isEnabled: false) { feedback.append($0) }
        ChatHaptics.streamCancelled(isEnabled: false) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.deny, isEnabled: false) { feedback.append($0) }
        ChatHaptics.clarificationSubmitted(isEnabled: false) { feedback.append($0) }
        ChatHaptics.configurationSelected(isEnabled: false) { feedback.append($0) }
        ChatHaptics.destructiveConfirmationAccepted(isEnabled: false) { feedback.append($0) }

        XCTAssertTrue(feedback.isEmpty)
    }

    @MainActor
    func testChatDecisionHapticLanguage() {
        var feedback: [ChatHapticFeedback] = []

        ChatHaptics.messageSent(isEnabled: true) { feedback.append($0) }
        ChatHaptics.assistantResponseCompleted(isEnabled: true) { feedback.append($0) }
        ChatHaptics.streamCancelled(isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.once, isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.session, isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.always, isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.deny, isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalBypassEnabled(isEnabled: true) { feedback.append($0) }
        ChatHaptics.clarificationSubmitted(isEnabled: true) { feedback.append($0) }
        ChatHaptics.configurationSelected(isEnabled: true) { feedback.append($0) }
        ChatHaptics.destructiveConfirmationAccepted(isEnabled: true) { feedback.append($0) }

        XCTAssertEqual(feedback, [
            .lightImpact,
            .success,
            .mediumImpact,
            .lightImpact,
            .lightImpact,
            .lightImpact,
            .warning,
            .warning,
            .selection,
            .selection,
            .warning
        ])
    }

    @MainActor
    func testConfigurationNoOpSelectionsDoNotReportSuccess() async {
        let viewModel = ChatViewModel(
            session: SessionSummary(
                sessionId: "session-1",
                workspace: "/tmp/project",
                model: "gpt-5",
                modelProvider: "openai",
                profile: "work"
            ),
            server: URL(string: "https://example.test")!
        )

        let didSelectCurrentModel = await viewModel.selectComposerModel(ModelCatalogOption(
            id: "gpt-5",
            displayName: "GPT-5",
            providerID: "openai"
        ))
        let didSelectCurrentWorkspace = await viewModel.selectWorkspacePath(" /tmp/project ")
        let didSelectCurrentProfile = await viewModel.switchProfile(
            ProfileSummary(
                name: "work",
                path: nil,
                isDefault: nil,
                isActive: true,
                gatewayRunning: nil,
                model: nil,
                provider: nil,
                hasEnv: nil,
                skillCount: nil
            ),
            startNewSession: false
        )

        XCTAssertFalse(didSelectCurrentModel)
        XCTAssertFalse(didSelectCurrentWorkspace)
        XCTAssertNil(didSelectCurrentProfile)
    }
}

@MainActor
final class OutgoingBubbleMotionTests: XCTestCase {
    func testHostedLocalSendEventsConsumeOnceAndDoNotReplay() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let scope = UUID()
        let ledger = OutgoingInsertionLedger()
        ledger.mount(scope: scope, through: 0)
        let fixture = OutgoingBubbleMotionFixture(scope: scope)
        window.rootViewController = UIHostingController(
            rootView: OutgoingBubbleMotionFixtureView(fixture: fixture, ledger: ledger)
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        fixture.append("First local send", id: "local-first")
        try await Task.sleep(for: .milliseconds(350))
        attach(window, named: "Outgoing first local send")
        XCTAssertEqual(fixture.messages.count, 1)
        XCTAssertFalse(ledger.isEligible(fixture.event, messageID: "local-first", role: "user", allowed: true))

        fixture.append("Second local send", id: "local-second")
        try await Task.sleep(for: .milliseconds(350))
        attach(window, named: "Outgoing second local send")
        XCTAssertEqual(fixture.messages.count, 2)
        XCTAssertFalse(ledger.isEligible(fixture.event, messageID: "local-second", role: "user", allowed: true))

        fixture.reduceMotion = true
        fixture.append("Reduce Motion local send", id: "local-reduced")
        try await Task.sleep(for: .milliseconds(100))
        attach(window, named: "Outgoing Reduce Motion")
        XCTAssertEqual(fixture.messages.count, 3)

        fixture.reduceMotion = false
        fixture.allowsMotion = false
        fixture.append("Reader away local send", id: "local-away")
        ledger.discardPending(through: fixture.event?.sequence ?? 0)
        try await Task.sleep(for: .milliseconds(100))
        attach(window, named: "Outgoing reader away")
        fixture.allowsMotion = true
        try await Task.sleep(for: .milliseconds(100))
        attach(window, named: "Outgoing reader returns, no replay")
        XCTAssertEqual(fixture.messages.count, 4)
        XCTAssertFalse(ledger.isEligible(fixture.event, messageID: "local-away", role: "user", allowed: true))
    }

    private func attach(_ window: UIWindow, named name: String) {
        window.layoutIfNeeded()
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class OutgoingBubbleMotionFixture: ObservableObject {
    let scope: UUID
    @Published var messages: [ChatMessage] = []
    @Published var event: OutgoingInsertionEvent?
    @Published var reduceMotion = false
    @Published var allowsMotion = true
    private var sequence: UInt64 = 0

    init(scope: UUID) { self.scope = scope }

    func append(_ text: String, id: String) {
        sequence += 1
        event = OutgoingInsertionEvent(scope: scope, messageID: id, sequence: sequence)
        messages.append(ChatMessage(
            role: "user", content: text,
            timestamp: Date().timeIntervalSince1970, messageId: id
        ))
    }
}

private struct OutgoingBubbleMotionFixtureView: View {
    @ObservedObject var fixture: OutgoingBubbleMotionFixture
    let ledger: OutgoingInsertionLedger

    var body: some View {
        VStack(spacing: 12) {
            ForEach(fixture.messages, id: \.id) { message in
                MessageBubbleView(message: message)
                    .modifier(OutgoingBubbleInsertionModifier(
                        event: fixture.event?.messageID == message.id ? fixture.event : nil,
                        message: message, ledger: ledger, isAllowed: fixture.allowsMotion,
                        reduceMotionOverride: fixture.reduceMotion
                    ))
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}
