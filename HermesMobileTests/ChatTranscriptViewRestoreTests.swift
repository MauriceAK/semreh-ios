import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ChatTranscriptViewRestoreTests: XCTestCase {
    func testFirstDisplayLinkTickAfterWindowAttachmentTargetsSavedMessage() async throws {
        let appeared = expectation(description: "transcript enters the SwiftUI view lifecycle")
        let firstDisplayLinkTick = expectation(description: "first display-link tick after window attachment is sampled")
        let proxyFallback = expectation(description: "proxy fallback is unnecessary after initial positioning")
        proxyFallback.isInverted = true
        var latestVisibleRowID: String?
        var firstDisplayLinkTickVisibleRowID: String?

        let window = try mountTranscript(
            restoreScrollToken: 1,
            restoreTarget: .message(id: "message-20"),
            onAppear: { appeared.fulfill() },
            onRestoreLatest: { _ in
                XCTFail("A saved-message restore must not request the latest content.")
            },
            onRestoreMessage: { _, _ in
                proxyFallback.fulfill()
            },
            onVisibleRowIDChange: { id in
                latestVisibleRowID = id
            },
            onFirstDisplayLinkTick: {
                firstDisplayLinkTickVisibleRowID = latestVisibleRowID
                firstDisplayLinkTick.fulfill()
            }
        )

        await fulfillment(of: [appeared, firstDisplayLinkTick], timeout: 1)
        await fulfillment(of: [proxyFallback], timeout: 0.2)
        XCTAssertEqual(
            firstDisplayLinkTickVisibleRowID,
            "message-20",
            "pre-window preference samples are not user-visible; the first display-link tick after window attachment must already target the saved row"
        )
        tearDown(window)
    }

    func testMissingSavedMessageKeepsBoundedProxyFallback() async throws {
        let appeared = expectation(description: "transcript enters the SwiftUI view lifecycle")
        let fallbackRequested = expectation(description: "missing lazy target requests a proxy fallback")
        fallbackRequested.assertForOverFulfill = false

        let window = try mountTranscript(
            restoreScrollToken: 1,
            restoreTarget: .message(id: "not-loaded"),
            onAppear: { appeared.fulfill() },
            onRestoreLatest: { _ in
                XCTFail("A saved-message restore must not request the latest content.")
            },
            onRestoreMessage: { id, animated in
                XCTAssertEqual(id, "not-loaded")
                XCTAssertFalse(animated)
                fallbackRequested.fulfill()
            }
        )

        await fulfillment(of: [appeared, fallbackRequested], timeout: 1)
        tearDown(window)
    }

    func testInitialMountWithZeroRestoreTokenDoesNotRequestRestore() async throws {
        let appeared = expectation(description: "transcript enters the SwiftUI view lifecycle")
        let restoreRequested = expectation(description: "zero restore token is ignored")
        restoreRequested.isInverted = true

        let window = try mountTranscript(
            restoreScrollToken: 0,
            restoreTarget: .latest,
            onAppear: { appeared.fulfill() },
            onRestoreLatest: { _ in restoreRequested.fulfill() },
            onRestoreMessage: { _, _ in restoreRequested.fulfill() }
        )

        await fulfillment(of: [appeared, restoreRequested], timeout: 0.25)
        tearDown(window)
    }

    private func mountTranscript(
        restoreScrollToken: Int,
        restoreTarget: ChatTranscriptRestoreTarget,
        onAppear: @escaping () -> Void,
        onRestoreLatest: @escaping (Bool) -> Void,
        onRestoreMessage: @escaping (String, Bool) -> Void,
        onVisibleRowIDChange: @escaping (String?) -> Void = { _ in },
        onFirstDisplayLinkTick: @escaping () -> Void = {}
    ) throws -> MountedWindowFixture {
        let messages = (0..<40).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Restored transcript message \(index)",
                timestamp: Double(index),
                messageId: "message-\(index)"
            )
        }
        let transcriptMessages = messages.enumerated().map { index, message in
            TranscriptMessage(
                loadedIndex: index,
                renderID: message.id,
                anchorID: message.id,
                message: message
            )
        }

        let view = ChatTranscriptView(
            isLoading: false,
            errorMessage: nil,
            messages: messages,
            displayedTranscriptMessages: transcriptMessages,
            compressionReferenceCard: nil,
            reasoningGroupsForAnchor: { _ in [] },
            completedToolCallGroupsForAnchor: { _ in [] },
            liveReasoningText: "",
            reasoningAnchorMessageID: nil,
            liveToolCalls: [],
            toolCallAnchorMessageID: nil,
            streamingAssistantMessageID: nil,
            liveTokensPerSecond: nil,
            activeStreamRecoveryState: .idle,
            clarificationPrompt: nil,
            isRespondingToClarification: false,
            clarificationErrorMessage: nil,
            hidesRunStatusAccessibility: false,
            showsThinkingAndToolCards: true,
            showsAssistantTypingIndicator: false,
            showsScrollToBottomButton: false,
            shouldFollowLatestMessage: restoreTarget == .latest,
            latestTranscriptMessageRole: "assistant",
            isScrolledNearBottom: false,
            activeStreamID: nil,
            streamingScrollTrigger: 0,
            cacheFirstReconcileScrollToken: 0,
            bottomAnchorID: "transcript-bottom",
            transcriptMessageSpacing: 12,
            transcriptBlockSpacing: 8,
            transcriptBottomInsetHeight: 0,
            scrollToBottomButtonBottomPadding: 0,
            localAttachmentPreviews: [:],
            listeningMessageID: nil,
            isViewingCachedData: false,
            hasOlderMessages: false,
            isLoadingOlderMessages: false,
            isRegeneratingMessage: false,
            isEditingMessage: false,
            isForkingMessage: false,
            loadAttachmentImage: { _ in nil },
            loadAttachmentData: { _ in nil },
            loadTranscriptMediaImage: { _ in nil },
            loadTranscriptMediaData: { _ in nil },
            transcriptMediaCacheNamespace: "restore-regression",
            actionContext: { _, _ in nil },
            shouldRenderMessageRow: { _ in true },
            onLoadMessages: {},
            onLoadOlderMessages: { _ in .noProgress },
            onUpdateScrollMetrics: { _ in },
            onDismissKeyboard: {},
            onScrollToBottom: { _ in },
            onScrollToLatestTranscriptMessage: { _ in },
            onScrollToLatestContent: { _, animated in
                onRestoreLatest(animated)
            },
            onScrollToTranscriptMessage: { _, id, animated in
                onRestoreMessage(id, animated)
            },
            onVisibleTranscriptRowIDChange: onVisibleRowIDChange,
            onPreviewAttachment: { _, _ in },
            onPreviewTranscriptMedia: { _ in },
            onToggleListening: { _ in },
            onSubmitClarification: { _, _ in },
            onCancelClarification: { _ in },
            onSelectText: { _ in },
            onRegenerate: { _ in },
            onEdit: { _ in },
            onFork: { _ in },
            onCopy: { _ in },
            restoreScrollToken: restoreScrollToken,
            restoreTarget: restoreTarget
        )

        let hostingController = UIHostingController(
            rootView: MountedChatTranscriptRoot(
                transcript: view,
                onAppear: onAppear,
                onFirstDisplayLinkTick: onFirstDisplayLinkTick
            )
        )
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windowScene = try XCTUnwrap(
            scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
            "A connected UIWindowScene is required to exercise the mounted SwiftUI lifecycle."
        )
        let window = UIWindow(windowScene: windowScene)
        let previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.frame = window.bounds
        hostingController.view.layoutIfNeeded()
        return MountedWindowFixture(window: window, previousKeyWindow: previousKeyWindow)
    }

    private func tearDown(_ fixture: MountedWindowFixture) {
        fixture.window.isHidden = true
        fixture.window.rootViewController = nil
        fixture.previousKeyWindow?.makeKey()
    }
}

private struct MountedWindowFixture {
    let window: UIWindow
    let previousKeyWindow: UIWindow?
}

private struct MountedChatTranscriptRoot: View {
    let transcript: ChatTranscriptView
    let onAppear: () -> Void
    let onFirstDisplayLinkTick: () -> Void

    var body: some View {
        transcript
            .background {
                WindowAttachmentDisplayLinkProbe(onFirstDisplayLinkTick: onFirstDisplayLinkTick)
            }
            .onAppear(perform: onAppear)
    }
}

private struct WindowAttachmentDisplayLinkProbe: UIViewRepresentable {
    let onFirstDisplayLinkTick: () -> Void

    func makeUIView(context: Context) -> WindowAttachmentDisplayLinkProbeView {
        let view = WindowAttachmentDisplayLinkProbeView()
        view.onFirstDisplayLinkTick = onFirstDisplayLinkTick
        return view
    }

    func updateUIView(_ uiView: WindowAttachmentDisplayLinkProbeView, context: Context) {
        uiView.onFirstDisplayLinkTick = onFirstDisplayLinkTick
    }

    static func dismantleUIView(_ uiView: WindowAttachmentDisplayLinkProbeView, coordinator: ()) {
        uiView.stop()
    }
}

private final class WindowAttachmentDisplayLinkProbeView: UIView {
    var onFirstDisplayLinkTick: (() -> Void)?
    private var displayLink: CADisplayLink?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            stop()
            return
        }
        guard displayLink == nil else { return }

        let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkDidTick(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    @objc private func displayLinkDidTick(_ displayLink: CADisplayLink) {
        stop()
        let callback = onFirstDisplayLinkTick
        onFirstDisplayLinkTick = nil
        callback?()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
}
