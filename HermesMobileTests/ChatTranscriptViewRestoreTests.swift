import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ChatTranscriptViewRestoreTests: XCTestCase {
    func testMountedOrdinaryTranscriptCapturesRetainedHandoffs() async throws {
        for mode in [MountedActivityMode.retainedAndLive, .loose] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let model = MountedActivityModel()
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = UIHostingController(
                rootView: MountedActivityTranscriptRoot(model: model, mode: mode)
            )
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKey()
            }

            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(90))
            attachActivityImage(of: window, named: "Mounted ordinary transcript \(mode) initial")
            if mode == .retainedAndLive {
                model.liveText = "Continuing to examine the next source segment."
                try await Task.sleep(for: .milliseconds(100))
                attachActivityImage(of: window, named: "Mounted activity update +0.10s hierarchy")
                try await Task.sleep(for: .milliseconds(200))
                attachActivityImage(of: window, named: "Mounted activity update +0.30s hierarchy")
                attachActivityImage(of: window, named: "Mounted activity update +0.30s layer", usesLayer: true)
                try await Task.sleep(for: .milliseconds(350))
                attachActivityImage(of: window, named: "Mounted activity update +0.65s hierarchy")
                attachActivityImage(of: window, named: "Mounted activity update +0.65s layer", usesLayer: true)
            }
        }
    }

    func testMountedOrdinaryTranscriptUnperturbedLiveUpdateStaysMounted() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let model = MountedActivityModel()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(
            rootView: MountedActivityTranscriptRoot(model: model, mode: .retainedAndLive)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        // Keep the interval around the update entirely free of in-process
        // screenshot requests; simctl records the real display externally.
        try await Task.sleep(for: .milliseconds(350))
        print("ACTIVITY_UNPERTURBED_UPDATE_BEGIN epoch=\(Date().timeIntervalSince1970)")
        model.liveText = "Continuing to examine the next source segment."
        try await Task.sleep(for: .milliseconds(1_250))
        print("ACTIVITY_UNPERTURBED_UPDATE_END epoch=\(Date().timeIntervalSince1970)")
        XCTAssertFalse(window.isHidden)
        XCTAssertNotNil(window.rootViewController)
    }

    private func attachActivityImage(of window: UIWindow, named name: String, usesLayer: Bool = false) {
        window.layoutIfNeeded()
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            if usesLayer {
                window.layer.render(in: context.cgContext)
            } else {
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBareThinkingUsesTrailingCurrentActivityOnly() {
        let retainedAssistant = ChatTranscriptTypingIndicatorPolicy.shouldShowBareIndicator(
            isEligible: true, hasActiveStream: true, showsActivityCards: true,
            trailingMessageRole: "assistant", hasTrailingRetainedReasoning: true,
            hasTrailingCompletedTools: false
        )
        XCTAssertFalse(retainedAssistant, "Retained Thinking already conveys current progress")

        let retainedTool = ChatTranscriptTypingIndicatorPolicy.shouldShowBareIndicator(
            isEligible: true, hasActiveStream: true, showsActivityCards: true,
            trailingMessageRole: "assistant", hasTrailingRetainedReasoning: false,
            hasTrailingCompletedTools: true
        )
        XCTAssertFalse(retainedTool, "Completed tool activity in the trailing assistant is already visible")

        let newerUserRow = ChatTranscriptTypingIndicatorPolicy.shouldShowBareIndicator(
            isEligible: true, hasActiveStream: true, showsActivityCards: true,
            trailingMessageRole: "user", hasTrailingRetainedReasoning: true,
            hasTrailingCompletedTools: false
        )
        XCTAssertTrue(newerUserRow, "Historical assistant activity must not hide a new turn's progress")
    }

#if DEBUG
    func testNativeRichPendingJumpIsCancelledByReaderDragAndDisappearance() {
        let controller = ChatStableViewportPrototype.Controller()
        controller.loadViewIfNeeded()
        controller.pendingNativeJumpAt = CACurrentMediaTime()
        controller.scrollViewWillBeginDragging(controller.scroll)
        XCTAssertNil(controller.pendingNativeJumpAt)
        controller.pendingNativeJumpAt = CACurrentMediaTime()
        controller.viewWillDisappear(false)
        XCTAssertNil(controller.pendingNativeJumpAt)
    }

    func testPrototypeLateHighlightHeightRefinementKeepsTailAttached() {
        let controller = ChatStableViewportPrototype.Controller()
        controller.loadViewIfNeeded()
        controller.scroll.delegate = nil
        controller.width = 370
        let ids = ["first", "tail"]
        controller.input = ChatStableViewportPrototype(
            ids: ids, revisionAt: { index in
                let message = ChatMessage(role: "assistant", content: "Geometry fixture \(index)",
                                          timestamp: Double(index), messageId: ids[index])
                return StableViewportRowRevision(
                    message: TranscriptMessage(loadedIndex: index, renderID: ids[index],
                                               anchorID: ids[index], message: message),
                    latestCompletedAssistantRenderID: nil, outgoingInsertionEvent: nil,
                    allowsOutgoingMotion: false, reasoningGroups: [], toolCallGroups: [],
                    liveReasoningText: "", liveToolCalls: [], streamingAssistantMessageID: nil,
                    liveTokensPerSecond: nil, localAttachmentPreviews: nil,
                    compressionReferenceCard: nil, listeningMessageID: nil,
                    showsThinkingAndToolCards: false, isViewingCachedData: false,
                    hasActiveStream: false, isRegeneratingMessage: false,
                    isEditingMessage: false, isForkingMessage: false,
                    transcriptMediaCacheNamespace: "geometry-test")
            }, revision: 0,
            typeKey: "test", bottomInset: 0, spacing: 12, reduceMotion: false,
            initialID: nil, startsAtBottom: false, onJumpToLatest: {},
            onScrollState: { _, _, _, _ in }, nativeRichDark: false, nativeRichWrapsCodeLines: false,
            nativePromptFillHex: "#E7D3B3", nativePromptForegroundHex: "#30251D", nativePromptBorderHex: "#C6AB83",
            onDirectSelectText: { _ in }, onDirectCopy: { _ in }, onDirectOpenURL: { _ in },
            makeRow: { _, _ in AnyView(Text("row")) }
        )
        controller.heights = [100, 1_000]
        controller.scroll.frame = CGRect(x: 0, y: 0, width: 402, height: 600)
        controller.rebuildPositions()
        controller.scroll.contentOffset.y = controller.bottomOffset
        controller.applyHeight(900, index: 1)
        XCTAssertEqual(controller.scroll.contentOffset.y, controller.bottomOffset, accuracy: 0.5)
        // Once the reader leaves the tail, refinements must preserve their
        // row-local anchor rather than silently pulling them back to latest.
        controller.scroll.contentOffset.y = 200
        let readerLocalOffset = controller.scroll.contentOffset.y - controller.positions[1]
        controller.applyHeight(200, index: 0)
        XCTAssertEqual(controller.scroll.contentOffset.y - controller.positions[1], readerLocalOffset, accuracy: 0.5)
    }

    func testPrototypeRejectsIntrinsicWidthProbeAsDisplayedGeometry() {
        // Actual cold rich-row regression: an intrinsic-width fitting probe
        // reported 206k height before the real 370pt-wide row reported 7.8k.
        XCTAssertFalse(ChatStableViewportPrototype.Controller.isDisplaySize(
            CGSize(width: 162, height: 206_231), width: 370
        ))
        XCTAssertTrue(ChatStableViewportPrototype.Controller.isDisplaySize(
            CGSize(width: 370, height: 7_812), width: 370
        ))
    }

    func testPrototypeGeometryRequiresFinitePositiveCurrentWidthAndHeight() {
        for size in [CGSize(width: 370, height: 0), CGSize(width: 370, height: CGFloat.infinity),
                     CGSize(width: CGFloat.nan, height: 100), CGSize(width: 369, height: 100)] {
            XCTAssertFalse(ChatStableViewportPrototype.Controller.isDisplaySize(size, width: 370))
        }
        XCTAssertFalse(ChatStableViewportPrototype.Controller.isDisplaySize(CGSize(width: 0, height: 10), width: 0))
        XCTAssertTrue(ChatStableViewportPrototype.Controller.isDisplaySize(CGSize(width: 370.25, height: 100), width: 370))
    }
#endif
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
            onLoadOlderMessages: { _, _ in .noProgress },
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

private enum MountedActivityMode: Equatable, CustomStringConvertible {
    case retainedAndLive
    case loose

    var description: String {
        switch self {
        case .retainedAndLive: "retained + live"
        case .loose: "loose retained"
        }
    }
}

@MainActor
private final class MountedActivityModel: ObservableObject {
    @Published var liveText = "Continuing to inspect the source."
}

private struct MountedActivityTranscriptRoot: View {
    @ObservedObject var model: MountedActivityModel
    let mode: MountedActivityMode

    private var messages: [ChatMessage] {
        [
            ChatMessage(role: "user", content: "Inspect the source", timestamp: 1, messageId: "activity-user"),
            ChatMessage(role: "assistant", content: "Work in progress", timestamp: 2, messageId: "activity-assistant")
        ]
    }

    var body: some View {
        ChatTranscriptView(
            isLoading: false, errorMessage: nil,
            messages: messages,
            displayedTranscriptMessages: messages.enumerated().map { index, message in
                TranscriptMessage(loadedIndex: index, renderID: message.id,
                                  anchorID: message.id, message: message)
            },
            compressionReferenceCard: nil,
            reasoningGroupsForAnchor: { anchor in
                let expectedAnchor: String? = mode == .loose ? nil : "activity-assistant"
                guard anchor == expectedAnchor else { return [] }
                return [ReasoningGroup(id: "activity-reasoning", anchorMessageID: expectedAnchor,
                                       text: "Retained source analysis.")]
            },
            completedToolCallGroupsForAnchor: { anchor in
                guard anchor == "activity-assistant" else { return [] }
                return [ToolCallGroup(anchorMessageID: anchor, toolCalls: [
                    ToolCall(name: "read_file", preview: "Synthetic source content",
                             args: ["path": .string("fixtures/example.md")], isCompleted: true)
                ])]
            },
            liveReasoningText: mode == .retainedAndLive ? model.liveText : "",
            reasoningAnchorMessageID: mode == .retainedAndLive ? "activity-assistant" : nil,
            liveToolCalls: [], toolCallAnchorMessageID: nil,
            streamingAssistantMessageID: nil, liveTokensPerSecond: nil,
            activeStreamRecoveryState: .idle, clarificationPrompt: nil,
            isRespondingToClarification: false, clarificationErrorMessage: nil,
            hidesRunStatusAccessibility: false, showsThinkingAndToolCards: true,
            showsAssistantTypingIndicator: mode == .loose,
            showsScrollToBottomButton: false, shouldFollowLatestMessage: true,
            latestTranscriptMessageRole: "assistant", isScrolledNearBottom: true,
            activeStreamID: "synthetic-active-stream", streamingScrollTrigger: 0,
            cacheFirstReconcileScrollToken: 0, bottomAnchorID: "activity-bottom",
            transcriptMessageSpacing: 12, transcriptBlockSpacing: 8,
            transcriptBottomInsetHeight: 0, scrollToBottomButtonBottomPadding: 0,
            localAttachmentPreviews: [:], listeningMessageID: nil,
            isViewingCachedData: false, hasOlderMessages: false, isLoadingOlderMessages: false,
            isRegeneratingMessage: false, isEditingMessage: false, isForkingMessage: false,
            loadAttachmentImage: { _ in nil }, loadAttachmentData: { _ in nil },
            loadTranscriptMediaImage: { _ in nil }, loadTranscriptMediaData: { _ in nil },
            transcriptMediaCacheNamespace: "activity-synthetic",
            actionContext: { _, _ in nil }, shouldRenderMessageRow: { _ in true },
            onLoadMessages: {}, onLoadOlderMessages: { _, _ in .noProgress },
            onUpdateScrollMetrics: { _ in }, onDismissKeyboard: {},
            onScrollToBottom: { _ in }, onScrollToLatestTranscriptMessage: { _ in },
            onScrollToLatestContent: { _, _ in },
            onPreviewAttachment: { _, _ in }, onPreviewTranscriptMedia: { _ in },
            onToggleListening: { _ in }, onSubmitClarification: { _, _ in },
            onCancelClarification: { _ in }, onSelectText: { _ in },
            onRegenerate: { _ in }, onEdit: { _ in }, onFork: { _ in }, onCopy: { _ in }
        )
        .environment(\.colorScheme, .dark)
    }
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
