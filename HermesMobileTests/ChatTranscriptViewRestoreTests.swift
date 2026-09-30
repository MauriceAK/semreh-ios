import SwiftUI
import UIKit
import XCTest
import Vision
import SwiftData
@testable import HermesMobile

@MainActor
final class ChatTranscriptViewRestoreTests: XCTestCase {
    func testBackCaptureCannotBeReplacedByTeardownGeometry() {
        let memory = ChatWarmReaderMemory()
        let saved = ChatWarmReaderMemory.Point(messageID: "row1", minY: -107, viewportWidth: 402)
        memory.capture(saved)
        memory.suspendCapture()
        memory.capture(.init(messageID: "row0", minY: 114, viewportWidth: 402))
        XCTAssertEqual(memory.point, saved)
        memory.resumeCapture()
        memory.capture(.init(messageID: "row2", minY: -20, viewportWidth: 402))
        XCTAssertEqual(memory.point?.messageID, "row2")
    }

    func testWarmAttachmentCandidateRestoresIntraRowOffsetOnlyAtProvisionalTop() throws {
        let scope = UUID()
        let sample = ChatInitialMeasuredTarget(id: "row1", scope: scope, restoreToken: 0,
            renderRevision: 4, viewportWidth: 402,
            frame: CGRect(x: 16, y: 706, width: 346, height: 2780))
        func offset(current: CGFloat, revision: Int = 4, interacting: Bool = false) -> CGFloat? {
            ChatInitialMeasuredTarget.initialOffset(for: sample, targetID: "row1", scope: scope,
                restoreToken: 0, renderRevision: revision, viewportWidth: 402, nativeWidth: 402,
                nativeHeight: 755, contentHeight: 5000, currentOffset: current,
                topInset: 0, bottomInset: 0, isAttached: true, restoreActive: true,
                isCancelled: false, isDirectlyInteracting: interacting, targetMinY: -107)
        }
        XCTAssertEqual(try XCTUnwrap(offset(current: 0)), 813)
        XCTAssertNil(offset(current: 706), "Native seed already moved; await fresh geometry")
        XCTAssertNil(offset(current: 0, revision: 5), "Reflow invalidates the candidate")
        XCTAssertNil(offset(current: 0, interacting: true), "A drag owns the viewport")
    }

    func testWarmReaderLateRequestConsumesAttachedAlignmentExactlyOnce() {
        let lease = ChatWarmReaderSettlement(
            point: .init(messageID: "A", minY: -216, viewportWidth: 402), scope: nil)
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1, target: .message(id: "A"))
        var outcomes: [ChatTranscriptRestoreOutcome] = []
        // Attached geometry precedes asynchronous parent startup.
        XCTAssertNil(lease.observe(delta: 0, currentOffset: 216, lower: 0, upper: 1_000))
        var parent = ChatTranscriptRestoreOutcomeState()
        parent.begin(request)
        lease.bind(request) {
            outcomes.append($0)
            XCTAssertTrue(parent.complete(request, outcome: $0, currentScope: request.scope))
        }
        lease.bind(request) { outcomes.append($0) }
        lease.expire()
        XCTAssertNil(parent.pending, "The late token must release the parent's paging gate")
        XCTAssertFalse(parent.preservesDurableTarget)
        XCTAssertEqual(outcomes, [.success])
        XCTAssertFalse(lease.isActive)
    }

    func testWarmReaderQuiescentLeasesRetireWithoutAnotherPreference() async {
        // Success, absent target, and a correction clamped at the content edge
        // all stop producing preferences. Each must retire on the single timer.
        for geometry in ["aligned", "missing", "clamped"] {
            let lease = ChatWarmReaderSettlement(
                point: .init(messageID: "A", minY: -216, viewportWidth: 402), scope: nil)
            let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1, target: .message(id: "A"))
            var outcomes: [ChatTranscriptRestoreOutcome] = []
            lease.bind(request) { outcomes.append($0) }
            if geometry == "aligned" {
                XCTAssertNil(lease.observe(delta: 0, currentOffset: 216, lower: 0, upper: 1_000))
            } else if geometry == "missing" {
                XCTAssertNil(lease.observe(delta: nil, currentOffset: 0, lower: 0, upper: 1_000))
            } else {
                // A real nonzero measured delta cannot move an offset whose
                // available range has collapsed to zero. No alignment follows.
                let delta = lease.point.correction(
                    frame: CGRect(x: 0, y: 0, width: 402, height: 500), viewportWidth: 402)
                XCTAssertEqual(delta, 216)
                XCTAssertNil(lease.observe(delta: delta, currentOffset: 0, lower: 0, upper: 0))
            }
            let retired = expectation(description: "retired \(geometry) without preferences")
            lease.startExpiry(after: .milliseconds(10), isCurrent: { true }) { retired.fulfill() }
            await fulfillment(of: [retired], timeout: 1)
            XCTAssertFalse(lease.isActive, geometry)
            XCTAssertEqual(outcomes, [geometry == "aligned" ? .success : .exhausted], geometry)
            lease.expire()
            XCTAssertEqual(outcomes.count, 1)
        }
    }

    func testWarmReaderRequestAfterQuiescentExpiryIsExhaustedExactlyOnce() async {
        let lease = ChatWarmReaderSettlement(
            point: .init(messageID: "A", minY: -216, viewportWidth: 402), scope: nil)
        let retired = expectation(description: "pre-token expiry")
        lease.startExpiry(after: .milliseconds(10), isCurrent: { true }) { retired.fulfill() }
        await fulfillment(of: [retired], timeout: 1)
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1, target: .message(id: "A"))
        var outcomes: [ChatTranscriptRestoreOutcome] = []
        lease.bind(request) { outcomes.append($0) }
        lease.bind(request) { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.exhausted])
    }

    func testWarmReaderCancellationAndObsoleteOwnerCannotPublishExpiry() async {
        let point = ChatWarmReaderMemory.Point(messageID: "A", minY: -216, viewportWidth: 402)
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1, target: .message(id: "A"))
        for reason in ["disappear", "new-owner", "identity", "arrow", "follow-latest", "interaction"] {
            let lease = ChatWarmReaderSettlement(point: point, scope: nil)
            var outcomes: [ChatTranscriptRestoreOutcome] = []
            var retirements = 0
            lease.bind(request) { outcomes.append($0) }
            lease.startExpiry(after: .milliseconds(10), isCurrent: { true }) { retirements += 1 }
            lease.cancel()
            try? await Task.sleep(for: .milliseconds(25))
            XCTAssertFalse(lease.isActive, reason)
            XCTAssertEqual(outcomes, [.cancelled], reason)
            XCTAssertEqual(retirements, 0, reason)
        }
        let obsolete = ChatWarmReaderSettlement(point: point, scope: nil)
        var outcomes: [ChatTranscriptRestoreOutcome] = []
        obsolete.bind(request) { outcomes.append($0) }
        obsolete.startExpiry(after: .milliseconds(10), isCurrent: { false }) {
            XCTFail("Obsolete owner must not mutate view state")
        }
        try? await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(obsolete.isActive)
        XCTAssertTrue(outcomes.isEmpty)
    }

    func testPersistenceUsesCurrentVisibleIDAfterCancelledWarmSettlement() throws {
        let suite = "warm-persistence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = try XCTUnwrap(URL(string: "https://fixture.invalid"))
        let session = SessionSummary(sessionId: "reader", title: "Reader")
        let model = ChatViewModel(session: session, server: server, userDefaults: defaults,
                                  gatewayRuntimeProvider: { _ in throw URLError(.cannotConnectToHost) })
        let memory = try XCTUnwrap(model.warmTranscriptReaderMemory)
        let point = ChatWarmReaderMemory.Point(messageID: "A", minY: -216, viewportWidth: 402)
        memory.point = point
        let lease = ChatWarmReaderSettlement(point: point, scope: memory.scope)
        // Visible B arrives during settlement, when warm capture is suppressed.
        // Interaction cancels the lease and Back persists before another sample.
        let visibleID = "B"
        lease.cancel()
        model.rememberTranscriptRestorePoint(followingLatest: false, visibleMessageID: visibleID)
        XCTAssertEqual(TranscriptRestoreStore(defaults: defaults)
            .load(server: server, sessionID: "reader").visibleMessageID, "B")
        XCTAssertNil(memory.point)
        XCTAssertEqual(model.transcriptRestoreTarget, .message(id: "B"))

        memory.point = point
        model.rememberTranscriptRestorePoint(followingLatest: false, visibleMessageID: "A")
        XCTAssertEqual(memory.point, point, "Matching geometry can be reused")
        model.rememberTranscriptRestorePoint(followingLatest: false, visibleMessageID: nil)
        XCTAssertNil(memory.point, "No supplied visible identity must not resurrect A")
        XCTAssertNil(TranscriptRestoreStore(defaults: defaults)
            .load(server: server, sessionID: "reader").visibleMessageID)
        memory.point = point
        model.rememberTranscriptRestorePoint(followingLatest: true, visibleMessageID: "A")
        XCTAssertNil(memory.point)
    }

    func testWarmReaderUsesFreshRowDeltaAcrossDifferentWindows() throws {
        let point = ChatWarmReaderMemory.Point(messageID: "rich-row", minY: -162.333,
                                               viewportWidth: 402)
        // The same row can have unrelated absolute content offsets in two
        // bounded windows. Both corrections must recover its viewport position.
        for (offset, rowY) in [(CGFloat(100), CGFloat(54)), (CGFloat(4_000), CGFloat(900))] {
            let delta = try XCTUnwrap(point.correction(
                frame: CGRect(x: 16, y: rowY, width: 346, height: 2_780), viewportWidth: 402
            ))
            let correctedOffset = offset + delta
            XCTAssertEqual(rowY - (correctedOffset - offset), point.minY, accuracy: 0.001)
        }
        XCTAssertNil(point.correction(frame: CGRect(x: 0, y: 0, width: 346, height: 2_780),
                                     viewportWidth: 600), "Reflow invalidates the saved point")
        XCTAssertNil(point.correction(frame: .zero, viewportWidth: 402))
    }

    func testWarmReaderMemoryIsScopedToCanonicalSessionAndProfile() throws {
        let memory = ChatWarmReaderMemory()
        let server = try XCTUnwrap(URL(string: "https://fixture.invalid"))
        let original = ChatWarmReaderMemory.Scope(server: server, profile: "default", sessionID: "one")
        memory.bind(to: original)
        let point = ChatWarmReaderMemory.Point(messageID: "row", minY: -216, viewportWidth: 402)
        memory.point = point
        memory.bind(to: original)
        XCTAssertEqual(memory.point, point, "Warm reuse keeps measured geometry")
        memory.bind(to: .init(server: server, profile: "other", sessionID: "one"))
        XCTAssertNil(memory.point)
        memory.point = point
        memory.bind(to: .init(server: server, profile: "other", sessionID: "two"))
        XCTAssertNil(memory.point)
        memory.point = point
        memory.bind(to: nil)
        XCTAssertNil(memory.point, "A new, unassigned chat cannot inherit reader geometry")
    }

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
        // Two different offscreen IDs expose a binding that merely keeps the
        // default top offset while the saved ID is present in the source data.
        for savedRow in [10, 20] {
            do {
                try await assertFirstAttachedLayerStartsAtSavedMessage(savedRow)
            } catch {
                // A missing/unreadable first image must not skip evidence for
                // the other target. Each thrown error still fails the test.
                XCTFail("Saved row \(savedRow) capture failed: \(error)")
            }
        }
    }

    private func assertFirstAttachedLayerStartsAtSavedMessage(_ savedRow: Int) async throws {
        let appeared = expectation(description: "transcript enters the SwiftUI view lifecycle")
        let firstDisplayLinkTick = expectation(description: "first display-link tick after window attachment is sampled")
        var hasAppeared = false
        var hasSampledFirstDisplayLinkTick = false
        var proxyFallbackRequests: [(id: String, animated: Bool)] = []
        var latestRestoreRequests = 0
        var publishedRowIDs: [String] = []
        var publishedRowIDsAtTick: [String] = []
        var firstTickImage: UIImage?
        var laterTickImages: [(Int, UIImage)] = []
        let boundedTicks = expectation(description: "four attached layer samples captured")
        let restoreProbe = ChatTranscriptRestoreProbe()

        let window = try mountTranscript(
            restoreScrollToken: 1,
            restoreTarget: .message(id: "message-\(savedRow)"),
            onAppear: {
                guard !hasAppeared else { return }
                hasAppeared = true
                appeared.fulfill()
            },
            onRestoreLatest: { _ in
                restoreProbe.record("callback.latest")
                latestRestoreRequests += 1
            },
            onRestoreMessage: { id, animated in
                restoreProbe.record("callback.proxy id=\(id) animated=\(animated)")
                proxyFallbackRequests.append((id: id, animated: animated))
            },
            onVisibleRowIDChange: { id in
                restoreProbe.record("callback.visible id=\(id ?? "nil")")
                if let id { publishedRowIDs.append(id) }
            },
            restoreProbe: restoreProbe,
            onDisplayLinkTick: { attachedWindow, tick, timestamp, targetTimestamp in
                restoreProbe.record("tick.\(tick).begin timestamp=\(timestamp) targetTimestamp=\(targetTimestamp) published=\(publishedRowIDs)")
                restoreProbe.record(attachedScrollDescription(in: attachedWindow))
                if tick == 1 {
                    hasSampledFirstDisplayLinkTick = true
                    publishedRowIDsAtTick = publishedRowIDs
                }
                if let attachedWindow {
                    let image = UIGraphicsImageRenderer(bounds: attachedWindow.bounds).image { context in
                        // Capture the existing layer tree at the tick. A
                        // drawHierarchy(afterScreenUpdates:) call can force a
                        // later SwiftUI layout and mask an initial flash.
                        attachedWindow.layer.render(in: context.cgContext)
                    }
                    if tick == 1 {
                        firstTickImage = image
                    } else { laterTickImages.append((tick, image)) }
                }
                if tick == 1 {
                    // Observe after the original raw capture, in the same callback.
                    // No layout, repaint, crop, or replacement of the judged image.
                    restoreProbe.record(firstTickViewportDescription(in: attachedWindow))
                }
                restoreProbe.record("tick.\(tick).end")
                if tick == 1 { firstDisplayLinkTick.fulfill() }
                if tick == 4 { boundedTicks.fulfill() }
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [appeared, firstDisplayLinkTick, boundedTicks], timeout: 1)
        // Retain the existing 200 ms no-fallback guard after the four samples.
        // This delay never determines which image is the first-tick assertion.
        try await Task.sleep(for: .milliseconds(200))
        if let firstTickImage {
            let attachment = XCTAttachment(image: firstTickImage)
            attachment.name = "First attached display-link tick layer tree, saved row \(savedRow)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // These later trees are separate observations, never a replacement
        // for tick 1 or proof of compositor presentation. Save evidence before
        // OCR/assertions so even unreadable first pixels retain the timeline.
        for (tick, laterImage) in laterTickImages {
            let laterAttachment = XCTAttachment(image: laterImage)
            laterAttachment.name = "Attached display-link tick \(tick) layer tree, saved row \(savedRow)"
            laterAttachment.lifetime = .keepAlways
            add(laterAttachment)
        }
        let timeline = XCTAttachment(string: restoreProbe.events.joined(separator: "\n")
            + "\ndroppedEvents=\(restoreProbe.droppedEvents)")
        timeline.name = "Restore lifecycle and native geometry, saved row \(savedRow)"
        timeline.lifetime = .keepAlways
        add(timeline)
        XCTAssertTrue(hasSampledFirstDisplayLinkTick)
        XCTAssertEqual(laterTickImages.count, 3)
        let image = try XCTUnwrap(firstTickImage, "The display-link probe must be attached to the window")
        let firstVisibleNumber = try firstVisibleTranscriptMessageNumber(in: image)
        XCTAssertEqual(firstVisibleNumber, savedRow,
                       "The first captured layer tree must show the saved row first; published IDs before the tick: \(publishedRowIDsAtTick)")
        XCTAssertTrue(publishedRowIDsAtTick.allSatisfy { $0 == "message-\(savedRow)" },
                      "A provisional row must not escape as the durable reader position")
        XCTAssertEqual(proxyFallbackRequests.count, 0,
                       "Initial positioning must not need proxy fallback; observed \(proxyFallbackRequests)")
        XCTAssertEqual(latestRestoreRequests, 0,
                       "A saved-message restore must not request the latest content")
    }

    private func firstVisibleTranscriptMessageNumber(in image: UIImage) throws -> Int {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let cgImage = try XCTUnwrap(image.cgImage)
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        let visibleRows = (request.results ?? []).compactMap { observation -> (Int, CGFloat)? in
            guard let text = observation.topCandidates(1).first?.string,
                  let range = text.range(of: #"Restored transcript message\s+(\d+)"#, options: .regularExpression),
                  let number = Int(text[range].split(separator: " ").last ?? "")
            else { return nil }
            return (number, observation.boundingBox.maxY)
        }
        XCTAssertFalse(visibleRows.isEmpty, "The tick image must contain a readable transcript row")
        return try XCTUnwrap(visibleRows.max(by: { $0.1 < $1.1 })?.0)
    }

    func testMissingSavedMessageKeepsBoundedProxyFallback() async throws {
        let appeared = expectation(description: "transcript enters the SwiftUI view lifecycle")
        let fallbackRequested = expectation(description: "missing lazy target requests a proxy fallback")
        fallbackRequested.assertForOverFulfill = false
        var hasAppeared = false

        let window = try mountTranscript(
            restoreScrollToken: 1,
            restoreTarget: .message(id: "not-loaded"),
            onAppear: {
                guard !hasAppeared else { return }
                hasAppeared = true
                appeared.fulfill()
            },
            onRestoreLatest: { _ in
                XCTFail("A saved-message restore must not request the latest content.")
            },
            onRestoreMessage: { id, animated in
                XCTAssertEqual(id, "not-loaded")
                XCTAssertFalse(animated)
                fallbackRequested.fulfill()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [appeared, fallbackRequested], timeout: 1)
    }

    func testInitialMountWithZeroRestoreTokenDoesNotRequestRestore() async throws {
        let appeared = expectation(description: "transcript enters the SwiftUI view lifecycle")
        var hasAppeared = false
        var restoreRequests = 0

        let window = try mountTranscript(
            restoreScrollToken: 0,
            restoreTarget: .latest,
            onAppear: {
                guard !hasAppeared else { return }
                hasAppeared = true
                appeared.fulfill()
            },
            onRestoreLatest: { _ in restoreRequests += 1 },
            onRestoreMessage: { _, _ in restoreRequests += 1 }
        )
        defer { tearDown(window) }

        await fulfillment(of: [appeared], timeout: 1)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(restoreRequests, 0, "A zero restore token must not request a restore")
    }

    func testProductionChatShellFreshAndWarmReaderRestore() async throws {
        for savedRow in [10, 20] {
            let suite = "shell-reader-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let session = SessionSummary(sessionId: "shell-reader-\(UUID().uuidString)", title: "Reader restore fixture")
            let server = try XCTUnwrap(URL(string: "http://127.0.0.1:9"))
            let model = ChatViewModel(session: session, server: server, userDefaults: defaults,
                                      gatewayRuntimeProvider: { _ in throw URLError(.cannotConnectToHost) })
            model.seedTranscriptForTesting((0..<60).map { index in
                ChatMessage(role: index.isMultiple(of: 2) ? "user" : "assistant",
                            content: "Restored transcript message \(index)\n\nReader fixture body \(index). The same display row is the durable reading unit.",
                            timestamp: Double(index), messageId: "shell-message-\(index)")
            })
            let displayRows = model.displayedTranscriptMessages
            XCTAssertEqual(displayRows.count, 60)
            let targetID = displayRows[savedRow].renderID
            XCTAssertEqual(displayRows[savedRow].message.messageId, "shell-message-\(savedRow)")
            let restoreStore = TranscriptRestoreStore(defaults: defaults)
            model.rememberTranscriptRestorePoint(followingLatest: false, visibleMessageID: targetID)
            XCTAssertEqual(restoreStore.load(server: server, sessionID: session.sessionId ?? session.id).visibleMessageID, targetID)

            let schema = Schema([CachedSession.self, CachedMessage.self, CachedSessionPreviewRecord.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            let route = ReaderShellRoute()
            let capture = ReaderShellCapture()
            let root = ReaderShellRoot(route: route, session: session, server: server,
                                       model: model, capture: capture).modelContainer(container)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive }), "A foreground scene is required")
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            // Match the real scene at attachment; do not manufacture a width
            // transition before judging the original raw first-tick image.
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = UIHostingController(rootView: root)
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKey()
            }

            var firstImages: [UIImage] = []
            for visit in 1...2 {
                let completed = capture.beginVisit()
                route.chatPresented = true
                await fulfillment(of: [completed], timeout: 4)
                XCTAssertEqual(capture.samples.map(\.tick), [1, 2, 3, 4],
                               "Every entry must retain the original first attachment tick and later ticks separately")
                for sample in capture.samples {
                    let image = try XCTUnwrap(sample.image, "The full window must be attached at tick \(sample.tick)")
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Production shell row \(savedRow) visit \(visit) raw tick \(sample.tick)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    let geometry = XCTAttachment(string: sample.geometry)
                    geometry.name = "Production shell row \(savedRow) visit \(visit) geometry tick \(sample.tick)"
                    geometry.lifetime = .keepAlways
                    add(geometry)
                }
                let firstImage = try XCTUnwrap(capture.samples.first?.image)
                firstImages.append(firstImage)
                // This visit has no user drag. An unconfirmed restore deliberately
                // preserves its durable seed on disappearance; clearing that seed
                // here would manufacture loss outside the production lifecycle.
                // Readback checks preservation, not a new write. The real-drag UI
                // test covers accepting a changed reader position before Back.
                XCTAssertEqual(restoreStore.load(server: server, sessionID: session.sessionId ?? session.id).visibleMessageID, targetID,
                               "Mounting without a user gesture must preserve the durable reader target")
                route.chatPresented = false
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertEqual(model.transcriptRestoreTarget, .message(id: targetID),
                               "ChatView disappearance must keep the display-row identity")
                XCTAssertEqual(restoreStore.load(server: server, sessionID: session.sessionId ?? session.id).visibleMessageID, targetID,
                               "Leaving without a user gesture must preserve the durable display-row identity")
            }
            let timeline = XCTAttachment(string: capture.probe.events.joined(separator: "\n"))
            timeline.name = "Production shell named-space restore trace, row \(savedRow)"
            timeline.lifetime = .keepAlways
            add(timeline)
            for (visit, firstImage) in firstImages.enumerated() {
                do {
                    XCTAssertEqual(try firstVisibleTranscriptMessageNumber(in: firstImage), savedRow,
                                   "The raw first attached production window on visit \(visit + 1) must show the saved reader row first")
                } catch {
                    XCTFail("Production shell first tick on visit \(visit + 1) could not be read: \(error)")
                }
            }
        }
    }

    #if DEBUG
    func testR58MountedBoundaryUnchangedKeyAndEagerControlGeometry() async throws {
        var frames: [[CGRect]] = []
        for eager in [false, true] {
            let (controller, fixture) = try mountNativeMotion(initialID: nil, ids: [])
            defer { controller.stop(); tearDown(fixture) }
            controller.reusesBoundaryConfigurations = !eager
            var input = nativeMotionInput(scope: controller.input.scope, initialID: nil, ids: [],
                                          footerHeight: 48, headerHeight: 24)
            input.headerRevision = .spacer(height: 24)
            input.footerRevision = .spacer(height: 48)
            controller.update(input)
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()
            let before = controller.boundaryConfigurations
            let original = try nativeBoundaryFrames(controller)
            for _ in 0..<10 { controller.update(input) }
            controller.view.layoutIfNeeded()
            XCTAssertEqual(controller.boundaryConfigurations - before, eager ? 20 : 0)
            XCTAssertEqual(try nativeBoundaryFrames(controller), original)
            XCTAssertEqual(original[1].height, 48, accuracy: 1)
            frames.append(original)
            // The top host includes its realized safe-area contribution. Require
            // the requested growth, not equality with the bare SwiftUI height.
            input = nativeMotionInput(scope: input.scope, initialID: nil, ids: [],
                                      footerHeight: 48, headerHeight: 34)
            input.headerRevision = .spacer(height: 34)
            input.footerRevision = .spacer(height: 48)
            controller.update(input)
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()
            XCTAssertEqual(try nativeBoundaryFrames(controller)[0].height - original[0].height,
                           10, accuracy: 1)
        }
        XCTAssertEqual(frames[0], frames[1], "Reuse must preserve realized boundary geometry")
    }

    func testR58MountedBoundaryChangedAndAbsentKeysRefreshGeometry() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: nil, ids: [])
        defer { controller.stop(); tearDown(fixture) }
        var input = nativeMotionInput(scope: controller.input.scope, initialID: nil, ids: [],
                                      footerHeight: 48, headerHeight: 24)
        input.headerRevision = .spacer(height: 24)
        input.footerRevision = .spacer(height: 48)
        controller.update(input)
        try await Task.sleep(for: .milliseconds(100))
        let before = controller.boundaryConfigurations
        input = nativeMotionInput(scope: input.scope, initialID: nil, ids: [],
                                  footerHeight: 96, headerHeight: 24)
        input.headerRevision = .spacer(height: 24)
        input.footerRevision = .spacer(height: 96)
        controller.update(input)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(controller.boundaryConfigurations, before)
        XCTAssertEqual(try nativeBoundaryFrames(controller)[1].height, 96, accuracy: 1)
        // Missing keys restore the real factories, including independently changed content.
        controller.update(nativeMotionInput(scope: input.scope, initialID: nil, ids: [], footerHeight: 130))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try nativeBoundaryFrames(controller)[1].height, 130, accuracy: 1)
        let eagerBefore = controller.boundaryConfigurations
        controller.update(controller.input)
        XCTAssertEqual(controller.boundaryConfigurations - eagerBefore, 2)
    }

    func testR58MountedBoundaryScopeTypeWidthLifecycleAndReappearance() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: nil, ids: [])
        defer { controller.stop(); tearDown(fixture) }
        func keyed(scope: String, type: String) -> ChatNativeTranscriptViewport {
            var input = nativeMotionInput(scope: scope, initialID: nil, ids: [],
                                          footerHeight: 48, typeKey: type, headerHeight: 24)
            input.headerRevision = .spacer(height: 24)
            input.footerRevision = .spacer(height: 48)
            return input
        }
        controller.update(keyed(scope: controller.input.scope, type: "first"))
        try await Task.sleep(for: .milliseconds(100))
        for input in [keyed(scope: controller.input.scope, type: "second"),
                      keyed(scope: "r58-replacement-\(UUID())", type: "second")] {
            let before = controller.boundaryConfigurations
            controller.update(input)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertGreaterThan(controller.boundaryConfigurations, before)
            XCTAssertEqual(try nativeBoundaryFrames(controller)[1].height, 48, accuracy: 1)
        }
        let oldWidth = try nativeBoundaryFrames(controller)[0].width
        let beforeWidth = controller.boundaryConfigurations
        controller.view.frame.size.width -= 40
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertGreaterThan(controller.boundaryConfigurations, beforeWidth)
        XCTAssertEqual(try nativeBoundaryFrames(controller)[0].width, oldWidth - 40, accuracy: 1)
        controller.suspendPresentation()
        controller.presentationVisible = true
        controller.applicationActive = true
        controller.resumePresentation()
        let beforeResume = controller.boundaryConfigurations
        controller.update(controller.input)
        XCTAssertGreaterThan(controller.boundaryConfigurations, beforeResume)

        var longInput = nativeMotionInput(scope: controller.input.scope, initialID: "native-row-0", headerHeight: 24)
        longInput.headerRevision = .spacer(height: 24)
        controller.update(longInput)
        try await Task.sleep(for: .milliseconds(100))
        controller.ownership = .reading
        controller.anchor = nil // This fixture positions directly, without a UIKit drag.
        controller.collection.setContentOffset(.zero, animated: false)
        controller.collection.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let headerPath = try XCTUnwrap(controller.dataSource.indexPath(for: .header))
        let headerHeight = try XCTUnwrap(controller.collection.cellForItem(at: headerPath)).frame.height
        controller.collection.setContentOffset(CGPoint(x: 0, y: controller.bottomOffset), animated: false)
        controller.collection.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.collection.indexPathsForVisibleItems.contains(headerPath))
        longInput = nativeMotionInput(scope: controller.input.scope, initialID: "native-row-0", headerHeight: 77)
        longInput.headerRevision = .spacer(height: 77)
        controller.update(longInput)
        controller.collection.setContentOffset(.zero, animated: false)
        controller.collection.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        controller.collection.layoutIfNeeded()
        let header = try XCTUnwrap(controller.collection.cellForItem(at: headerPath))
        XCTAssertTrue(controller.collection.indexPathsForVisibleItems.contains(headerPath))
        XCTAssertEqual(header.frame.height - headerHeight, 53, accuracy: 1,
                       "Reappearing cells must apply the requested 24-to-77 height growth")
        // Force a new dequeue with an unchanged key as well.
        let beforeReload = controller.boundaryConfigurations
        controller.collection.reloadData()
        controller.collection.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertGreaterThan(controller.boundaryConfigurations, beforeReload)
        XCTAssertEqual(try XCTUnwrap(controller.collection.cellForItem(at: headerPath)).frame.height,
                       headerHeight + 53, accuracy: 1)
    }

    private func nativeBoundaryFrames(_ controller: ChatNativeTranscriptViewport.Controller) throws -> [CGRect] {
        try [ChatNativeTranscriptViewport.Controller.Item.header, .footer].map { item in
            let path = try XCTUnwrap(controller.dataSource.indexPath(for: item))
            let cell = try XCTUnwrap(controller.collection.cellForItem(at: path))
            return cell.frame
        }
    }

    func testMountedNativeIdentityReusePreservesContentScopeAndStructuralChanges() async throws {
        let scope = "identity-cache-\(UUID().uuidString)"
        let (controller, fixture) = try mountNativeMotion(scope: scope, initialID: "native-row-5")
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        let original = controller.input.ids
        XCTAssertEqual(controller.identityBuilds, 1)
        for _ in 0..<20 { controller.update(controller.input) }
        XCTAssertEqual(controller.identityBuilds, 1, "Unchanged identity must not rebuild the history index")

        for (nextScope, text) in [(scope, "Updated current content العربية 👩🏽‍💻"),
                                  (scope + "-replacement", "Replacement scope content")] {
            controller.update(nativeMotionInput(scope: nextScope, initialID: "native-row-5",
                                                revision: 1, liveText: text))
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(controller.identityBuilds, 1, "Equal IDs may reuse structure, never stale row content")
            let revision = try XCTUnwrap(controller.revisions["native-row-6"])
            XCTAssertEqual(revision.message.message.content, text)
        }
        let sequences = [original + ["append"], ["prepend"] + original + ["append"],
                         ["prepend"] + Array(original.reversed()), ["replacement"], []]
        for (index, ids) in sequences.enumerated() {
            controller.update(nativeMotionInput(scope: controller.input.scope,
                                                initialID: ids.first ?? "", ids: ids))
            controller.view.layoutIfNeeded()
            XCTAssertEqual(controller.identityBuilds, index + 2)
            XCTAssertEqual(controller.indices, Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) }))
            XCTAssertEqual(controller.dataSource.snapshot().itemIdentifiers,
                           [.header] + ids.map(ChatNativeTranscriptViewport.Controller.Item.row) + [.footer])
            XCTAssertTrue(controller.revisions.keys.allSatisfy { controller.indices[$0] != nil },
                          "Removed rows must not accumulate revision payloads")
        }
    }

    func testMountedNativeIdentityReuseUpdatePathMeasurement() async throws {
        let ids = (0..<1_000).map { "native-row-\($0)" }
        let updates = 120
        var samples: [[String: Any]] = []
        for trial in 0..<3 {
            for reuse in (trial.isMultiple(of: 2) ? [false, true] : [true, false]) {
                let scope = "identity-measure-\(trial)-\(reuse)"
                let (controller, fixture) = try mountNativeMotion(scope: scope, initialID: "native-row-5",
                                                                  ids: ids, reusesIdentitySnapshot: reuse)
                defer { controller.stop(); tearDown(fixture) }
                try await Task.sleep(for: .milliseconds(60))
                // Fresh equal arrays resemble repeated SwiftUI inputs. Prepare
                // outside timing; measure actual mounted controller update work.
                let inputs = (0..<updates).map { tick in
                    nativeMotionInput(scope: scope, initialID: "native-row-5",
                                      ids: ids.map { "\($0)" }, revision: tick)
                }
                let start = CACurrentMediaTime()
                for input in inputs { controller.update(input) }
                let elapsed = CACurrentMediaTime() - start
                XCTAssertEqual(controller.identityBuilds, reuse ? 1 : updates + 1)
                XCTAssertEqual(controller.indices.count, ids.count)
                samples.append(["trial": trial, "reuses_identity": reuse, "updates": updates,
                                "logical_rows": ids.count, "elapsed_seconds": elapsed,
                                "identity_builds": controller.identityBuilds,
                                "mounted_cells": controller.collection.visibleCells.count])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "scope": "Mounted native controller update CPU wall time, no layout drain in timed loop; not FPS or whole-chat latency",
            "samples": samples
        ], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "r43-native-identity-update-measurement"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMountedNativeMotionResignActiveCancelsWithoutResumeSnap() async throws {
        let (controller, fixture) = try mountNativeMotion()
        defer { controller.stop(); tearDown(fixture) }
        try await startMountedNativeMotion(controller)
        let before = try XCTUnwrap(controller.currentAnchor())
        let offset = controller.collection.contentOffset.y
        let completed = controller.motionCompleted
        let cancelled = controller.motionCancelled
        let epoch = controller.presentationEpoch
        // Deliver the real UIKit notification, not the controller's handler.
        // This is notification mechanics coverage, not physical backgrounding.
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification,
                                        object: UIApplication.shared)
        XCTAssertNil(controller.motionLink)
        XCTAssertEqual(controller.motionCancelled, cancelled + 1)
        XCTAssertGreaterThan(controller.presentationEpoch, epoch)
        let samples = controller.motionSamples
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.motionSamples, samples)
        XCTAssertEqual(controller.collection.contentOffset.y, offset, accuracy: 1)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification,
                                        object: UIApplication.shared)
        try await assertNativeReaderRemains(controller, id: before.id, delta: before.delta,
                                           offset: offset, completed: completed)
    }

    func testMountedNativeMotionDisappearanceCancelsWithoutResumeSnap() async throws {
        let (controller, fixture) = try mountNativeMotion()
        defer { controller.stop(); tearDown(fixture) }
        try await startMountedNativeMotion(controller)
        let completed = controller.motionCompleted
        let cancelled = controller.motionCancelled
        let cover = UIViewController()
        cover.view.backgroundColor = .systemBackground
        cover.modalPresentationStyle = .fullScreen
        let disappeared = expectation(description: "UIKit completes full-screen cover")
        controller.present(cover, animated: false) { disappeared.fulfill() }
        await fulfillment(of: [disappeared], timeout: 2)
        XCTAssertTrue(controller.presentedViewController === cover)
        XCTAssertNil(controller.view.window, "A real full-screen presentation must detach the transcript")
        XCTAssertNil(controller.motionLink)
        XCTAssertEqual(controller.motionCancelled, cancelled + 1)
        // UIKit may run another motion tick before delivering viewWillDisappear.
        // Score the cancellation boundary, not the earlier presentation request.
        let before = try XCTUnwrap(controller.anchor)
        let offset = controller.collection.contentOffset.y
        let cancelledSamples = controller.motionSamples
        XCTAssertEqual(controller.motionCompleted, completed)
        let resumed = expectation(description: "UIKit completes transcript reappearance")
        cover.dismiss(animated: false) { resumed.fulfill() }
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertTrue(controller.view.window === fixture.window)
        try await assertNativeReaderRemains(controller, id: before.id, delta: before.delta,
                                           offset: offset, completed: completed)
        XCTAssertEqual(controller.motionSamples, cancelledSamples)
    }

    func testMountedNativeReduceMotionReachesRealizedTailWithoutAnimation() async throws {
        let (controller, fixture) = try mountNativeMotion(reduceMotion: true)
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.realizedTailArrival)
        controller.latest.sendActions(for: .touchUpInside)
        XCTAssertNil(controller.motionLink)
        for _ in 0..<40 {
            if controller.realizedTailArrival { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(controller.realizedTailArrival, "Reduce Motion still needs a mounted, measured footer")
        XCTAssertTrue(controller.follows)
        XCTAssertEqual(controller.motionSamples, 0)
        XCTAssertEqual(controller.motionCompleted, 0)
    }

    func testMountedNativeParkedLiveRevisionsKeepAnchorThroughEachChunk() async throws {
        let scope = "native-stream-\(UUID().uuidString)"
        let (controller, fixture) = try mountNativeMotion(scope: scope, initialID: "native-row-5")
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        let parked = try XCTUnwrap(controller.currentAnchor())
        XCTAssertEqual(parked.id, "native-row-5")
        let offset = controller.collection.contentOffset.y
        var text = ""
        var samples: [String] = []
        defer {
            let evidence = XCTAttachment(string: samples.joined(separator: "\n"))
            evidence.name = "Mounted native live revision anchor samples (synthetic inputs)"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        for chunk in 1...6 {
            text += "Live chunk \(chunk): source continues across the mounted native row.\n"
            let active = chunk < 6
            controller.update(nativeMotionInput(scope: scope, initialID: "native-row-5",
                                                revision: chunk, liveText: text, active: active))
            try await Task.sleep(for: .milliseconds(60))
            let current = try XCTUnwrap(controller.currentAnchor())
            XCTAssertEqual(current.id, parked.id, "Chunk \(chunk), active=\(active)")
            XCTAssertEqual(current.delta, parked.delta, accuracy: 1)
            XCTAssertEqual(controller.collection.contentOffset.y, offset, accuracy: 1)
            XCTAssertFalse(controller.follows)
            XCTAssertNil(controller.motionLink)
            // The changing row is actually realized and reconfigured during the
            // live samples; this is not just a completed endpoint assertion.
            let path = try XCTUnwrap(controller.dataSource.indexPath(for: .row("native-row-6")))
            XCTAssertNotNil(controller.collection.cellForItem(at: path))
            let rendered = try XCTUnwrap(controller.revisions["native-row-6"])
            XCTAssertEqual(rendered.message.message.content, text)
            XCTAssertEqual(rendered.hasActiveStream, active)
            XCTAssertEqual(rendered.streamingAssistantMessageID, active ? "native-row-6" : nil)
            samples.append("chunk=\(chunk) active=\(active) anchor=\(current.id) delta=\(current.delta) offset=\(controller.collection.contentOffset.y) sourceCharacters=\(text.count)")
        }
    }

    // Delegate delivery below exercises mounted ownership mechanics only. The
    // UI journey must independently prove a physical status-bar tap is delivered.
    func testMountedNativeSystemTopOwnsMotionThroughParentEchoAndCompletion() async throws {
        let (controller, fixture) = try mountNativeMotion()
        defer { controller.stop(); tearDown(fixture) }
        try await startMountedNativeMotion(controller)
        XCTAssertTrue(controller.scrollViewShouldScrollToTop(controller.collection))
        XCTAssertNil(controller.motionLink)
        XCTAssertTrue(controller.interacting)
        XCTAssertTrue(controller.lastPublished?.metrics.isDirectlyInteracting == true)
        let echo = try XCTUnwrap(controller.latestEchoCancellationToken)
        controller.update(nativeMotionInput(scope: controller.input.scope,
            initialID: "native-row-1", cancellationToken: echo, following: true))
        XCTAssertTrue(controller.systemTopActive)
        let midpoint = controller.collection.contentOffset.y / 2
        controller.collection.setContentOffset(CGPoint(x: 0, y: midpoint), animated: false)
        controller.collection.layoutIfNeeded()
        controller.settleLayout()
        XCTAssertEqual(controller.collection.contentOffset.y, midpoint, accuracy: 1)
        controller.collection.setContentOffset(CGPoint(x: 0, y: -controller.collection.adjustedContentInset.top), animated: false)
        controller.collection.layoutIfNeeded()
        controller.scrollViewDidScrollToTop(controller.collection)
        controller.settleLayout()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(controller.systemTopActive)
        XCTAssertFalse(controller.follows)
        XCTAssertEqual(controller.systemTopRequests, 1)
        XCTAssertEqual(controller.systemTopCompleted, 1)
        XCTAssertEqual(controller.collection.contentOffset.y, -controller.collection.adjustedContentInset.top, accuracy: 1)
        XCTAssertEqual(controller.currentAnchor()?.id, "native-row-0")
        XCTAssertTrue(controller.probe.accessibilityValue?.contains("topCompleted=1") == true)
        XCTAssertTrue(controller.scrollViewShouldScrollToTop(controller.collection))
        controller.latest.sendActions(for: .touchUpInside)
        XCTAssertFalse(controller.systemTopActive, "A newer explicit latest tap must replace OS ascent")
        XCTAssertNotNil(controller.motionLink)
    }

    func testMountedNativeSystemTopCancellationRejectsStaleCompletionAndResume() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-5")
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.scrollViewShouldScrollToTop(controller.collection))
        let offset = controller.collection.contentOffset.y
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification,
                                        object: UIApplication.shared)
        XCTAssertFalse(controller.systemTopActive)
        controller.scrollViewDidScrollToTop(controller.collection)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification,
                                        object: UIApplication.shared)
        // An ordinary follow echo without a cancellation edge is not a new tap.
        controller.update(nativeMotionInput(scope: controller.input.scope,
            initialID: "native-row-5", following: true))
        controller.collection.layoutIfNeeded()
        XCTAssertFalse(controller.follows)
        controller.update(nativeMotionInput(scope: controller.input.scope,
            initialID: "native-row-5", cancellationToken: 1, following: true))
        controller.collection.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.collection.contentOffset.y, offset, accuracy: 1)
        XCTAssertFalse(controller.follows)
        XCTAssertEqual(controller.systemTopCompleted, 0)
        XCTAssertTrue(controller.scrollViewShouldScrollToTop(controller.collection))
        controller.scrollViewWillBeginDragging(controller.collection)
        controller.scrollViewDidScrollToTop(controller.collection)
        XCTAssertFalse(controller.systemTopActive)
        XCTAssertEqual(controller.systemTopCompleted, 0)
        XCTAssertTrue(controller.scrollViewShouldScrollToTop(controller.collection))
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1,
                                                   target: .message(id: "native-row-10"))
        controller.update(nativeMotionInput(scope: controller.input.scope,
            initialID: "native-row-5", cancellationToken: 1, restoreRequest: request))
        controller.scrollViewDidScrollToTop(controller.collection)
        XCTAssertFalse(controller.systemTopActive)
        if case .restoring(let target) = controller.ownership {
            XCTAssertEqual(target?.id, "native-row-10")
        } else {
            XCTFail("A new restore must replace system-top ownership")
        }
        XCTAssertEqual(controller.systemTopCompleted, 0)
    }

    func testMountedNativeQueuedRefreshDoesNotStartAfterScopeChangeOrStop() async throws {
        for stops in [false, true] {
            var firstCalls = 0
            var replacementCalls = 0
            let (controller, fixture) = try mountNativeMotion(onRefresh: { _ in firstCalls += 1 })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(controller.isPresentationActive)
            let refresh = try XCTUnwrap(controller.collection.refreshControl)
            refresh.beginRefreshing()
            controller.refreshHistory()
            let queued = try XCTUnwrap(controller.refreshTask)
            XCTAssertTrue(refresh.isRefreshing)
            // No suspension between queueing and invalidating: the backend task
            // has not begun its first main-actor turn.
            if stops {
                controller.stop()
            } else {
                controller.update(nativeMotionInput(scope: "replacement-\(UUID())", initialID: "native-row-5",
                    onRefresh: { _ in replacementCalls += 1 }))
            }
            XCTAssertNil(controller.refreshTask)
            XCTAssertFalse(refresh.isRefreshing, "Obsolete spinner must end synchronously")
            await queued.value
            XCTAssertEqual(firstCalls, 0)
            XCTAssertEqual(replacementCalls, 0, "A queued old refresh cannot call the new chat")
        }
    }

    func testMountedNativeOldRefreshCannotFinishReplacementAndCoverKeepsOwner() async throws {
        let firstStarted = expectation(description: "First backend refresh entered")
        let replacementStarted = expectation(description: "Replacement backend refresh entered")
        var firstFinish: CheckedContinuation<Void, Never>?
        var replacementFinish: CheckedContinuation<Void, Never>?
        var firstCurrent: (@MainActor () -> Bool)?
        var replacementCurrent: (@MainActor () -> Bool)?
        var firstCalls = 0
        let (controller, fixture) = try mountNativeMotion(onRefresh: { isCurrent in
            firstCalls += 1
            firstCurrent = isCurrent
            await withCheckedContinuation { continuation in
                firstFinish = continuation
                firstStarted.fulfill()
            }
        })
        defer {
            controller.stop(); tearDown(fixture)
            firstFinish?.resume(); replacementFinish?.resume()
        }
        try await Task.sleep(for: .milliseconds(80))
        let refresh = try XCTUnwrap(controller.collection.refreshControl)
        refresh.beginRefreshing()
        controller.refreshHistory()
        let oldTask = try XCTUnwrap(controller.refreshTask)
        await fulfillment(of: [firstStarted], timeout: 2)
        controller.refreshHistory()
        XCTAssertEqual(firstCalls, 1, "Duplicate gestures retain a single owner")
        XCTAssertTrue(try XCTUnwrap(firstCurrent)())
        controller.update(nativeMotionInput(scope: "replacement-\(UUID())", initialID: "native-row-5",
            onRefresh: { isCurrent in
                replacementCurrent = isCurrent
                await withCheckedContinuation { continuation in
                    replacementFinish = continuation
                    replacementStarted.fulfill()
                }
            }))
        XCTAssertFalse(try XCTUnwrap(firstCurrent)())
        XCTAssertFalse(refresh.isRefreshing)
        refresh.beginRefreshing()
        controller.refreshHistory()
        let replacementTask = try XCTUnwrap(controller.refreshTask)
        await fulfillment(of: [replacementStarted], timeout: 2)
        firstFinish?.resume(); firstFinish = nil
        await oldTask.value
        XCTAssertNotNil(controller.refreshTask)
        XCTAssertTrue(refresh.isRefreshing, "Old completion must not dismiss the new spinner")
        XCTAssertTrue(try XCTUnwrap(replacementCurrent)())
        // Same-chat temporary coverage affects presentation, not refresh ownership.
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        let covered = expectation(description: "Refresh viewport covered")
        controller.present(cover, animated: false) { covered.fulfill() }
        await fulfillment(of: [covered], timeout: 2)
        XCTAssertTrue(controller.presentationSuspended)
        XCTAssertNotNil(controller.refreshTask)
        XCTAssertTrue(try XCTUnwrap(replacementCurrent)())
        replacementFinish?.resume(); replacementFinish = nil
        await replacementTask.value
        XCTAssertNil(controller.refreshTask)
        XCTAssertFalse(refresh.isRefreshing)
        let resumed = expectation(description: "Refresh viewport returns")
        cover.dismiss(animated: false) { resumed.fulfill() }
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertTrue(controller.isPresentationActive)
    }

    func testMountedNativeSuspendedRefreshDoesNotRetainStoppedViewport() async throws {
        let started = expectation(description: "Backend refresh suspended")
        var finish: CheckedContinuation<Void, Never>?
        var isCurrent: (@MainActor () -> Bool)?
        var mounted: (ChatNativeTranscriptViewport.Controller, MountedWindowFixture)? = try mountNativeMotion(onRefresh: { current in
            isCurrent = current
            await withCheckedContinuation { continuation in
                finish = continuation
                started.fulfill()
            }
        })
        let fixture = try XCTUnwrap(mounted?.1)
        defer { mounted?.0.stop(); tearDown(fixture); finish?.resume() }
        try await Task.sleep(for: .milliseconds(80))
        weak var owner = mounted?.0
        mounted?.0.refreshHistory()
        let task = try XCTUnwrap(mounted?.0.refreshTask)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(try XCTUnwrap(isCurrent)())
        mounted?.0.stop()
        tearDown(fixture)
        mounted = nil
        // UIKit can defer the release of its detached root; backend work remains
        // suspended throughout this bounded observation.
        for _ in 0..<20 {
            if owner == nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(try XCTUnwrap(isCurrent)())
        XCTAssertNil(owner, "A suspended backend callback must not retain the stopped viewport")
        finish?.resume(); finish = nil
        await task.value
    }

    // Injected UIKit state models the ownership boundary; these tests do not
    // synthesize physical momentum or prove the real-gesture probe counter.
    private final class ModeledMomentumCollection: ChatNativeTranscriptViewport.Collection {
        var modeledDeceleration = false
        var modeledDragging = false
        var modeledTracking = false
        var stoppedMomentumAt: CGPoint?
        var onMomentumStopped: (() -> Void)?
        override var isDecelerating: Bool { modeledDeceleration }
        override var isDragging: Bool { modeledDragging }
        override var isTracking: Bool { modeledTracking }
        override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            if modeledDeceleration && !animated {
                stoppedMomentumAt = contentOffset
                modeledDeceleration = false
                onMomentumStopped?()
            }
            super.setContentOffset(contentOffset, animated: animated)
        }
    }

    func testMountedNativeModeledDecelerationLatestTakeoverRejectsStaleEndsAndEcho() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Animated ownership requires Reduce Motion off")
        let (controller, fixture) = try mountNativeMotion(makeCollection: {
            ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0)
        })
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
        let offset = collection.contentOffset
        collection.modeledDeceleration = true
        controller.jumpToLatest()
        let link = try XCTUnwrap(controller.motionLink)
        XCTAssertEqual(collection.stoppedMomentumAt, offset)
        XCTAssertEqual(controller.decelerationTakeovers, 1, "Injected state only; not physical gesture evidence")
        XCTAssertTrue(controller.probe.accessibilityValue?.contains("decelerationTakeovers=1") == true)
        controller.scrollViewDidEndDragging(collection, willDecelerate: false)
        controller.scrollViewDidEndDecelerating(collection)
        XCTAssertTrue(controller.motionLink === link)
        XCTAssertTrue(controller.follows)
        // A trailing deceleration observation is also not a new finger gesture.
        collection.modeledDeceleration = true
        controller.advanceMotion(link)
        XCTAssertTrue(controller.motionLink === link)
        XCTAssertEqual(controller.decelerationTakeovers, 1)
        collection.modeledDeceleration = false
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-1",
            cancellationToken: try XCTUnwrap(controller.latestEchoCancellationToken), following: true))
        XCTAssertTrue(controller.motionLink === link)
        XCTAssertTrue(controller.explicitLatestOwnsViewport)
        XCTAssertEqual(controller.decelerationTakeovers, 1)
        controller.scrollViewWillBeginDragging(collection)
        XCTAssertNil(controller.motionLink)
        XCTAssertFalse(controller.explicitLatestOwnsViewport)
        XCTAssertFalse(controller.follows)
    }

    func testMountedNativeModeledDecelerationExplicitEdgeTakeoverAndCancellation() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Animated ownership requires Reduce Motion off")
        let (controller, fixture) = try mountNativeMotion(makeCollection: {
            ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0)
        })
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
        collection.modeledDeceleration = true
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-1",
            explicitLatest: true))
        let link = try XCTUnwrap(controller.motionLink)
        controller.scrollViewDidEndDecelerating(collection)
        XCTAssertTrue(controller.motionLink === link)
        XCTAssertTrue(controller.follows)
        XCTAssertEqual(controller.decelerationTakeovers, 1)
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-1",
            cancellationToken: 1, explicitLatest: true))
        XCTAssertNil(controller.motionLink)
        XCTAssertFalse(controller.explicitLatestOwnsViewport)
        XCTAssertFalse(controller.follows)
    }

    func testMountedNativeModeledDirectTouchRejectsLatestAndExplicitEdge() async throws {
        for tracking in [true, false] {
            let (controller, fixture) = try mountNativeMotion(makeCollection: {
                ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0)
            })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(100))
            let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
            collection.modeledTracking = tracking
            collection.modeledDragging = !tracking
            collection.modeledDeceleration = true
            controller.jumpToLatest()
            controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-1",
                explicitLatest: true))
            XCTAssertNil(controller.motionLink)
            XCTAssertNil(controller.latestEchoCancellationToken)
            XCTAssertFalse(controller.explicitLatestOwnsViewport)
            XCTAssertFalse(controller.follows)
            XCTAssertEqual(controller.decelerationTakeovers, 0)
            XCTAssertNil(collection.stoppedMomentumAt)
        }
    }

    func testMountedNativeModeledDecelerationReduceMotionRetainsOwnershipUntilSuspension() async throws {
        let (controller, fixture) = try mountNativeMotion(reduceMotion: true, makeCollection: {
            ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0)
        })
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
        collection.modeledDeceleration = true
        controller.jumpToLatest()
        controller.scrollViewDidEndDragging(collection, willDecelerate: false)
        controller.scrollViewDidEndDecelerating(collection)
        XCTAssertNil(controller.motionLink)
        XCTAssertTrue(controller.follows)
        XCTAssertTrue(controller.explicitLatestOwnsViewport)
        XCTAssertEqual(controller.decelerationTakeovers, 1)
        for _ in 0..<20 {
            collection.layoutIfNeeded()
            if controller.realizedTailArrival { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(controller.realizedTailArrival)
        controller.suspendPresentation()
        XCTAssertFalse(controller.explicitLatestOwnsViewport)
        XCTAssertFalse(controller.follows)
        XCTAssertEqual(controller.decelerationTakeovers, 1, "Counter remains latched after cancellation")
    }

    func testMountedNativeMotionObservationBatchingAB() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "A/B requires animated display-link motion")
        var records: [[String: Any]] = []
        var endpoints: [ChatNativeTranscriptViewport.Controller.Published] = []
        var tailFrames: [CGRect] = []
        var rates: [(publish: Double, scan: Double)] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: [
                "scope": "Native work inside accepted CADisplayLink ticks only; not FPS or whole-chat smoothness",
                "runs": records
            ], options: [.sortedKeys, .prettyPrinted]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "r45-native-motion-observation-ab"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        for batched in [false, true] {
            let (controller, fixture) = try mountNativeMotion(batchesMotionObservations: batched)
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(controller.realizedTailArrival)
            controller.latest.sendActions(for: .touchUpInside)
            for _ in 0..<150 {
                if controller.motionLink == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let ticks = controller.motionTicks
            let publications = controller.motionPublishComputations
            let scans = controller.motionDescendantScanPasses
            let publishRate = Double(publications) / Double(max(1, ticks))
            let scanRate = Double(scans) / Double(max(1, ticks))
            let tailPath = try XCTUnwrap(controller.dataSource.indexPath(for: .footer))
            let tail = try XCTUnwrap(controller.collection.cellForItem(at: tailPath))
            let tailFrame = tail.convert(tail.bounds, to: controller.view)
            records.append([
                "batched": batched, "accepted_motion_ticks": ticks,
                "scroll_callbacks": controller.motionSamples,
                "publish_computations": publications, "descendant_scan_passes": scans,
                "publishes_per_tick": publishRate, "scans_per_tick": scanRate,
                "completed": controller.motionCompleted, "cancelled": controller.motionCancelled,
                "arrived": controller.realizedTailArrival,
                "offset_y": Double(controller.collection.contentOffset.y),
                "bottom_offset_y": Double(controller.bottomOffset),
                "content_height": Double(controller.collection.contentSize.height),
                "visible_tail_frame": [Double(tailFrame.minX), Double(tailFrame.minY),
                                       Double(tailFrame.width), Double(tailFrame.height)]
            ])
            XCTAssertGreaterThan(ticks, 0)
            XCTAssertGreaterThan(controller.motionSamples, 0)
            XCTAssertNil(controller.motionLink)
            XCTAssertEqual(controller.motionCompleted, 1)
            XCTAssertEqual(controller.motionCancelled, 0)
            XCTAssertTrue(controller.realizedTailArrival)
            XCTAssertTrue(controller.follows)
            XCTAssertFalse(controller.batchingMotionObservations)
            XCTAssertEqual(controller.collection.contentOffset.y, controller.bottomOffset, accuracy: 1)
            endpoints.append(try XCTUnwrap(controller.lastPublished))
            tailFrames.append(tailFrame)
            rates.append((publishRate, scanRate))
            if batched {
                XCTAssertEqual(publications, ticks)
                XCTAssertLessThanOrEqual(scans, ticks)
            }
        }
        // Same terminal state: identity fields exactly; geometry at sub-pixel
        // tolerance, since a settled bottom can differ by one ULP (~9e-13 pt).
        XCTAssertEqual(endpoints[0].visible, endpoints[1].visible)
        XCTAssertEqual(endpoints[0].last, endpoints[1].last)
        XCTAssertEqual(endpoints[0].bottom, endpoints[1].bottom)
        XCTAssertEqual(endpoints[0].metrics.distanceFromBottom, endpoints[1].metrics.distanceFromBottom,
                       accuracy: 0.001, "Both modes must publish the same terminal state")
        XCTAssertEqual(endpoints[0].metrics.isUserInteracting, endpoints[1].metrics.isUserInteracting)
        XCTAssertEqual(endpoints[0].metrics.isDirectlyInteracting, endpoints[1].metrics.isDirectlyInteracting)
        XCTAssertEqual(endpoints[0].metrics.isDecelerating, endpoints[1].metrics.isDecelerating)
        // Unrealized cells retain estimates, so absolute offsets can differ even
        // at the same realized footer. Compare the actual viewport-space target.
        XCTAssertEqual(tailFrames[0].minX, tailFrames[1].minX, accuracy: 1)
        XCTAssertEqual(tailFrames[0].minY, tailFrames[1].minY, accuracy: 1)
        XCTAssertEqual(tailFrames[0].width, tailFrames[1].width, accuracy: 1)
        XCTAssertEqual(tailFrames[0].height, tailFrames[1].height, accuracy: 1)
        XCTAssertLessThan(rates[1].publish, rates[0].publish * 0.75)
        // A tick may request only one sweep already. Do not demand an invented
        // percentage improvement; batching must cap it without adding idle work.
        XCTAssertLessThanOrEqual(rates[1].scan, 1)
    }

    func testMountedNativeMotionObservationBatchClearsOnEarlyExit() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Cancellation requires animated motion")
        for directGesture in [false, true] {
            var reduceMotion = false
            let (controller, fixture) = try mountNativeMotion(
                reduceMotionOverride: { reduceMotion }, makeCollection: {
                    ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0)
                })
            defer { controller.stop(); tearDown(fixture) }
            try await startMountedNativeMotion(controller)
            let link = try XCTUnwrap(controller.motionLink)
            let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
            if directGesture { collection.modeledTracking = true } else { reduceMotion = true }
            let ticks = controller.motionTicks
            let scans = controller.descendantScanPasses
            controller.advanceMotion(link)
            XCTAssertEqual(controller.motionTicks, ticks + 1)
            XCTAssertEqual(controller.descendantScanPasses, scans,
                           "Early exits without layout must not invent a subtree scan")
            XCTAssertNil(controller.motionLink)
            XCTAssertFalse(controller.batchingMotionObservations)
            XCTAssertEqual(controller.motionCancelled, 1)
            XCTAssertEqual(controller.follows, !directGesture)
            if directGesture { controller.scrollViewWillBeginDragging(collection) }
            // Ordinary publication must compute and update lastPublished synchronously.
            controller.lastPublished = nil
            let before = controller.publishComputations
            controller.publish()
            XCTAssertEqual(controller.publishComputations, before + 1)
            XCTAssertNotNil(controller.lastPublished)
            controller.suspendPresentation()
            let suspendedCount = controller.publishComputations
            controller.advanceMotion(link)
            controller.publish()
            XCTAssertEqual(controller.publishComputations, suspendedCount)
            XCTAssertFalse(controller.batchingMotionObservations)
        }
    }

    func testMountedNativeMotionObservationBatchRejectsInvalidatedLayout() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Invalidation requires animated motion")
        for stop in [false, true] {
            let (controller, fixture) = try mountNativeMotion()
            defer { controller.stop(); tearDown(fixture) }
            try await startMountedNativeMotion(controller)
            let link = try XCTUnwrap(controller.motionLink)
            let publications = controller.publishComputations
            let offset = controller.collection.contentOffset
            var invalidated = false
            controller.collection.didLayout = { [weak controller] in
                guard let controller, !invalidated else { return }
                invalidated = true
                XCTAssertTrue(controller.batchingMotionObservations)
                if stop { controller.stop() } else { controller.suspendPresentation() }
            }
            controller.collection.setNeedsLayout()
            controller.advanceMotion(link)
            XCTAssertTrue(invalidated)
            XCTAssertFalse(controller.batchingMotionObservations)
            XCTAssertNil(controller.motionLink)
            XCTAssertEqual(controller.publishComputations, publications,
                           "An invalidated synchronous transaction must not publish a stale frame")
            XCTAssertEqual(controller.collection.contentOffset.y, offset.y, accuracy: 1)
        }
    }

    // Injected synchronous UIKit bursts, not physical gestures or FPS evidence.
    func testMountedNativeScrollObservationCoalescingAB() async throws {
        var records: [[String: Any]] = []
        var endpoints: [ChatNativeTranscriptViewport.Controller.Published] = []
        var work: [Int] = []
        for coalesced in [false, true] {
            var delivered: [ChatNativeTranscriptViewport.Controller.Published] = []
            let (controller, fixture) = try mountNativeMotion(
                coalescesScrollObservations: coalesced,
                onState: { delivered.append(.init(metrics: $0, visible: $1, last: $2, bottom: $3)) },
                makeCollection: { ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0) })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(controller.initialized)
            controller.ownership = .reading
            (controller.collection as? ModeledMomentumCollection)?.modeledDragging = true
            let start = controller.collection.contentOffset
            let before = controller.publishComputations
            delivered.removeAll()
            for step in 1...24 {
                controller.collection.setContentOffset(CGPoint(x: start.x, y: start.y + CGFloat(step)), animated: false)
                controller.scrollViewDidScroll(controller.collection)
            }
            await drainNativeScrollQueue()
            let count = controller.publishComputations - before
            let final = try XCTUnwrap(controller.lastPublished)
            XCTAssertEqual(delivered.last, final)
            XCTAssertEqual(final.metrics.distanceFromBottom,
                           max(0, controller.bottomOffset - controller.collection.contentOffset.y), accuracy: 0.01)
            XCTAssertEqual(controller.collection.contentOffset.y - start.y, 24, accuracy: 0.01)
            endpoints.append(final)
            work.append(count)
            records.append(["coalesced": coalesced, "injectedCallbacks": 24,
                            "publishComputations": count,
                            "distanceFromBottom": final.metrics.distanceFromBottom,
                            "offsetDelta": controller.collection.contentOffset.y - start.y])
        }
        XCTAssertEqual(endpoints[0], endpoints[1])
        XCTAssertLessThan(work[1], work[0])
        let data = try JSONSerialization.data(withJSONObject: [
            "scope": "Mounted injected synchronous offset/callback burst; actual publication computations, not FPS or physical gestures",
            "runs": records
        ], options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "r46-native-scroll-observation-ab"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMountedNativeScrollObservationEagerPublicationSupersedesDrain() async throws {
        var delivered: [ChatNativeTranscriptViewport.Controller.Published] = []
        let (controller, fixture) = try mountNativeMotion(
            onState: { delivered.append(.init(metrics: $0, visible: $1, last: $2, bottom: $3)) },
            makeCollection: { ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0) })
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        controller.ownership = .reading
        (controller.collection as? ModeledMomentumCollection)?.modeledDragging = true
        delivered.removeAll()
        let start = controller.collection.contentOffset
        controller.collection.setContentOffset(CGPoint(x: start.x, y: start.y + 12), animated: false)
        controller.scrollViewDidScroll(controller.collection)
        (controller.collection as? ModeledMomentumCollection)?.modeledDragging = false
        controller.scrollViewDidEndDragging(controller.collection, willDecelerate: false)
        let eager = try XCTUnwrap(controller.lastPublished)
        // A fresh scroll queue followed by an identical eager publication must
        // preserve the valid onState delivery already waiting on the main queue.
        controller.scrollViewDidScroll(controller.collection)
        controller.publish()
        // UIKit may legitimately publish a layout during the barrier; distinguish
        // that from executing the superseded queued scroll observation.
        let beforeDrain = controller.scrollObservationDrains
        await drainNativeScrollQueue()
        XCTAssertEqual(controller.scrollObservationDrains, beforeDrain)
        XCTAssertEqual(delivered, [eager])
        delivered.removeAll()
        (controller.collection as? ModeledMomentumCollection)?.modeledDragging = true
        controller.collection.setContentOffset(CGPoint(x: start.x, y: start.y + 24), animated: false)
        controller.publish()
        // An older onState and an obsolete drain both precede this newer queue.
        // Neither may deliver stale geometry or consume the replacement ticket.
        controller.collection.setContentOffset(CGPoint(x: start.x, y: start.y + 36), animated: false)
        controller.scrollViewDidScroll(controller.collection)
        await drainNativeScrollQueue()
        let final = try XCTUnwrap(controller.lastPublished)
        XCTAssertEqual(controller.collection.contentOffset.y - start.y, 36, accuracy: 0.01)
        XCTAssertNotEqual(final, eager)
        XCTAssertEqual(delivered, [final])
        XCTAssertEqual(final.metrics.distanceFromBottom,
                       max(0, controller.bottomOffset - controller.collection.contentOffset.y), accuracy: 0.01)
    }

    func testMountedNativeScrollObservationInvalidationAndReopening() async throws {
        for boundary in ["suspend", "scope", "stop"] {
            var replacementDelivered: [ChatNativeTranscriptViewport.Controller.Published] = []
            var delivered: [ChatNativeTranscriptViewport.Controller.Published] = []
            let (controller, fixture) = try mountNativeMotion(
                onState: { delivered.append(.init(metrics: $0, visible: $1, last: $2, bottom: $3)) },
                makeCollection: { ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0) })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(100))
            delivered.removeAll()
            controller.scrollViewDidScroll(controller.collection)
            switch boundary {
            case "suspend": controller.suspendPresentation()
            case "scope":
                controller.update(nativeMotionInput(scope: "r46-replacement-\(UUID())", initialID: "native-row-1",
                    onState: { replacementDelivered.append(.init(metrics: $0, visible: $1, last: $2, bottom: $3)) }))
            default: controller.stop()
            }
            let beforeDrain = controller.publishComputations
            await drainNativeScrollQueue()
            XCTAssertTrue(delivered.isEmpty, boundary)
            if boundary != "scope" { XCTAssertEqual(controller.publishComputations, beforeDrain, boundary) }
            if boundary == "stop" { continue }
            if boundary == "suspend" { controller.resumePresentation() }
            try await Task.sleep(for: .milliseconds(100))
            controller.ownership = .reading
            (controller.collection as? ModeledMomentumCollection)?.modeledDragging = true
            let beforeNewQueue = controller.publishComputations
            let start = controller.collection.contentOffset
            controller.collection.setContentOffset(CGPoint(x: start.x, y: start.y + 16), animated: false)
            controller.scrollViewDidScroll(controller.collection)
            await drainNativeScrollQueue()
            XCTAssertGreaterThan(controller.publishComputations, beforeNewQueue, boundary)
            let final = try XCTUnwrap(controller.lastPublished)
            XCTAssertEqual(final.metrics.distanceFromBottom,
                           max(0, controller.bottomOffset - controller.collection.contentOffset.y), accuracy: 0.01)
            if boundary == "suspend" { XCTAssertEqual(delivered.last, final) }
            if boundary == "scope" { XCTAssertEqual(replacementDelivered.last, final) }
        }
    }

    private func drainNativeScrollQueue() async {
        // First barrier runs after the observation; second after its onState.
        for _ in 0..<2 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    /// Appearance is run-loop driven: main-queue hops do not fire viewDidAppear.
    /// Rejoin/explicit commands gate on an active presentation, so the fixture
    /// window must reach it before those assertions.
    private func awaitPresentationActive(_ controller: ChatNativeTranscriptViewport.Controller) async throws {
        for _ in 0..<40 {
            if controller.isPresentationActive { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Mounted fixture never became presentation-active")
    }

    // R48: real mounted offsets with synthetic footer growth and live display links.
    // These are movement/ownership samples, not presentation or FPS measurements.
    func testR48MountedStreamingFollowRetargetsAndCompletesAtRealTail() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: nil, reduceMotionOverride: { false })
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.realizedTailArrival)
        let start = controller.collection.contentOffset.y
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            revision: 1, active: true, footerHeight: 230))
        controller.collection.layoutIfNeeded()
        let link = try XCTUnwrap(controller.followLink)
        var samples: [String] = []
        var intermediate = false
        defer {
            let attachment = XCTAttachment(string: samples.joined(separator: "\n"))
            attachment.name = "R48 mounted live-link offsets; synthetic footer growth; not FPS"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for tick in 0..<12 {
            try await Task.sleep(for: .milliseconds(15))
            let offset = controller.collection.contentOffset.y
            let target = controller.bottomOffset
            samples.append("sample=\(tick) offset=\(offset) liveBottom=\(target) followTicks=\(controller.followTicks)")
            intermediate = intermediate || (offset > start + 0.5 && offset < target - 0.5)
            XCTAssertTrue(controller.latest.isHidden)
            if tick == 2 {
                controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
                    revision: 2, active: true, footerHeight: 330))
                controller.collection.layoutIfNeeded()
                XCTAssertTrue(controller.followLink === link, "Growth retargets the same link")
            }
        }
        XCTAssertTrue(intermediate, "Observe actual movement before arrival")
        XCTAssertGreaterThan(controller.followTicks, 0)
        for tick in 0..<40 {
            try await Task.sleep(for: .milliseconds(15))
            samples.append("settle=\(tick) offset=\(controller.collection.contentOffset.y) liveBottom=\(controller.bottomOffset) followTicks=\(controller.followTicks) link=\(controller.followLink != nil) arrived=\(controller.realizedTailArrival)")
        }
        XCTAssertNil(controller.followLink, "A settled active stream retains no display link")
        XCTAssertTrue(controller.realizedTailArrival)
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            revision: 3, active: true, footerHeight: 350))
        controller.collection.layoutIfNeeded()
        let finalLink = try XCTUnwrap(controller.followLink)
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            revision: 4, active: false, footerHeight: 370))
        controller.collection.layoutIfNeeded()
        XCTAssertTrue(controller.followLink === finalLink, "Completion lets the existing glide settle instead of snapping")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(controller.followLink)
        XCTAssertTrue(controller.realizedTailArrival)
        XCTAssertEqual(controller.motionSamples, 0)
        XCTAssertEqual(controller.motionCompleted, 0)
    }

    func testNativeMountedExplicitSendRejoinsWhileCancellingRestore() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-5", reduceMotion: true)
        defer { controller.stop(); tearDown(fixture) }
        try await awaitPresentationActive(controller)
        await drainNativeScrollQueue()
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1,
                                                  target: .message(id: "native-row-5"))
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
            restoreRequest: request))
        controller.collection.layoutIfNeeded()
        XCTAssertFalse(controller.follows)
        // Actual prepareTranscriptForExplicitSend input: clear restore, increment
        // cancellation AND rejoin, set following in the same update.
        let send = nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
            cancellationToken: 1, following: true, latestToken: 1)
        controller.update(send)
        controller.collection.layoutIfNeeded()
        await drainNativeScrollQueue()
        controller.collection.layoutIfNeeded()
        XCTAssertTrue(controller.follows)
        XCTAssertTrue(controller.realizedTailArrival)
        XCTAssertEqual(controller.collection.contentOffset.y, controller.bottomOffset, accuracy: 1)
        controller.scrollViewWillBeginDragging(controller.collection)
        XCTAssertTrue(controller.align(.init(id: "native-row-5", delta: 0)))
        controller.anchor = controller.currentAnchor()
        let parked = controller.collection.contentOffset.y
        for _ in 0..<3 {
            controller.update(send)
            controller.collection.layoutIfNeeded()
            XCTAssertFalse(controller.follows, "Repeated send input cannot reclaim a newer drag")
            XCTAssertNil(controller.followLink)
            XCTAssertEqual(controller.collection.contentOffset.y, parked, accuracy: 1)
        }
    }

    func testNativeMountedCancellationAndActiveFingerDoNotRejoin() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-5", reduceMotion: true,
            makeCollection: { ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0) })
        defer { controller.stop(); tearDown(fixture) }
        try await awaitPresentationActive(controller)
        await drainNativeScrollQueue()
        let parked = controller.collection.contentOffset.y
        let cancellation = nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
            cancellationToken: 1, following: true)
        for _ in 0..<3 {
            controller.update(cancellation)
            controller.collection.layoutIfNeeded()
            XCTAssertFalse(controller.follows, "Ordinary cancellation plus stale following is not send")
            XCTAssertEqual(controller.collection.contentOffset.y, parked, accuracy: 1)
        }
        let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
        collection.modeledTracking = true
        controller.scrollViewWillBeginDragging(collection)
        let send = nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
            cancellationToken: 2, following: true, latestToken: 1)
        controller.update(send)
        controller.collection.layoutIfNeeded()
        XCTAssertFalse(controller.follows)
        XCTAssertEqual(controller.collection.contentOffset.y, parked, accuracy: 1)
        collection.modeledTracking = false
        controller.update(send)
        controller.collection.layoutIfNeeded()
        XCTAssertFalse(controller.follows, "A command consumed during tracking cannot replay after finger release")
        XCTAssertNil(controller.motionLink)
        XCTAssertNil(controller.followLink)
        collection.modeledDeceleration = true
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
            cancellationToken: 3, following: true, latestToken: 2))
        controller.collection.layoutIfNeeded()
        XCTAssertFalse(collection.isDecelerating, "A fresh send may replace inherited momentum")
        XCTAssertTrue(controller.follows)
        XCTAssertTrue(controller.realizedTailArrival)
        controller.scrollViewDidEndDecelerating(collection)
        XCTAssertTrue(controller.follows, "Late momentum callbacks cannot reclaim the fresh send")
    }

    func testR48MountedStreamingDragSynchronouslyParksSubsequentGrowth() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: nil, reduceMotionOverride: { false })
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(150))
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            active: true, footerHeight: 250))
        controller.collection.layoutIfNeeded()
        XCTAssertNotNil(controller.followLink)
        // Modeled delegate interruption; the collection and display link are real.
        controller.scrollViewWillBeginDragging(controller.collection)
        XCTAssertNil(controller.followLink)
        XCTAssertFalse(controller.follows)
        let parked = try XCTUnwrap(controller.currentAnchor())
        let offset = controller.collection.contentOffset.y
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            active: true, footerHeight: 350))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(controller.followLink)
        XCTAssertFalse(controller.follows)
        XCTAssertEqual(controller.currentAnchor()?.id, parked.id)
        XCTAssertEqual(controller.collection.contentOffset.y, offset, accuracy: 1)
    }

    func testR48MountedStreamingLifecycleScopeAndStopReleaseFollow() async throws {
        for transition in ["suspend", "scope", "stop"] {
            let (controller, fixture) = try mountNativeMotion(initialID: nil, reduceMotionOverride: { false })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(150))
            controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
                active: true, footerHeight: 250))
            controller.collection.layoutIfNeeded()
            XCTAssertNotNil(controller.followLink)
            switch transition {
            case "suspend": controller.suspendPresentation()
            case "scope":
                controller.update(nativeMotionInput(scope: "r48-new-\(UUID().uuidString)",
                    initialID: "native-row-5", active: true))
            default: controller.stop()
            }
            XCTAssertNil(controller.followLink)
            let ticks = controller.followTicks
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertNil(controller.followLink)
            XCTAssertEqual(controller.followTicks, ticks, "Suspension/scope/stop must synchronously release hidden work")
            if transition == "suspend" {
                XCTAssertTrue(controller.follows, "Ordinary follow intent survives suspension")
                controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
                    revision: 1, active: true, footerHeight: 350))
                controller.collection.layoutIfNeeded()
                XCTAssertNil(controller.followLink)
                XCTAssertEqual(controller.followTicks, ticks)
                controller.resumePresentation()
                // The existing glide has a bounded 0.5s settlement deadline.
                try await Task.sleep(for: .milliseconds(700))
                XCTAssertTrue(controller.follows)
                XCTAssertNil(controller.followLink)
                XCTAssertTrue(controller.realizedTailArrival)
                XCTAssertEqual(controller.collection.contentOffset.y, controller.bottomOffset, accuracy: 1)
            } else {
                XCTAssertFalse(controller.follows && transition != "stop")
            }
        }
    }

    func testR48MountedInitialRestoreReduceMotionAndResizeStayImmediate() async throws {
        var reduce = false
        let (controller, fixture) = try mountNativeMotion(initialID: nil, reduceMotionOverride: { reduce })
        defer { controller.stop(); tearDown(fixture) }
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil, active: true))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.realizedTailArrival)
        XCTAssertEqual(controller.followTicks, 0)
        reduce = true
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            active: true, footerHeight: 230))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.followLink)
        XCTAssertTrue(controller.realizedTailArrival)
        reduce = false
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            active: true, footerHeight: 330))
        controller.collection.layoutIfNeeded()
        XCTAssertNotNil(controller.followLink)
        controller.collection.contentInset.bottom = 80
        controller.collection.setNeedsLayout()
        controller.collection.layoutIfNeeded()
        XCTAssertNil(controller.followLink)
        XCTAssertTrue(controller.realizedTailArrival)
        let resizeTicks = controller.followTicks
        // Model a late self-sizing correction in the same semantic revision.
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            active: true, footerHeight: 370))
        controller.collection.layoutIfNeeded()
        await drainNativeScrollQueue()
        controller.collection.layoutIfNeeded()
        XCTAssertNil(controller.followLink, "Inset-only resize must not restart on late layout refinement")
        XCTAssertEqual(controller.followTicks, resizeTicks)
        XCTAssertTrue(controller.realizedTailArrival)
        controller.collection.bounds.size.height -= 40
        controller.collection.setNeedsLayout()
        controller.collection.layoutIfNeeded()
        XCTAssertNil(controller.followLink)
        XCTAssertTrue(controller.realizedTailArrival)
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            revision: 1, active: true, footerHeight: 470))
        controller.collection.layoutIfNeeded()
        XCTAssertNotNil(controller.followLink, "A new semantic revision may glide again")
        controller.update(nativeMotionInput(scope: "r48-restore-\(UUID().uuidString)",
            initialID: "native-row-5", active: true))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.followLink)
        XCTAssertFalse(controller.follows)
        XCTAssertEqual(controller.currentAnchor()?.id, "native-row-5")
    }

    func testR51MountedStreamingFollowObservationBatchingAB() async throws {
        var records: [[String: Any]] = []
        var frames: [CGRect] = []
        var rates: [Double] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "R51 live follow AB; synthetic growth, unmodified layout callbacks; not FPS"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        for batched in [false, true] {
            let (controller, fixture) = try mountNativeMotion(initialID: nil,
                batchesMotionObservations: batched, reduceMotionOverride: { false })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(controller.realizedTailArrival)
            let start = controller.collection.contentOffset.y
            let publicationsBefore = controller.publishComputations
            let scansBefore = controller.descendantScanPasses
            let initialTailPath = try XCTUnwrap(controller.dataSource.indexPath(for: .footer))
            let initialTailHeight = try XCTUnwrap(controller.collection.cellForItem(at: initialTailPath)).bounds.height
            var samples: [[String: Any]] = []
            var moved = false
            for sample in 0..<60 {
                if sample == 0 || sample == 6 || sample == 12 {
                    controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
                        revision: sample + 1, active: sample != 12,
                        footerHeight: CGFloat(230 + sample * 10)))
                    controller.collection.layoutIfNeeded()
                }
                try await Task.sleep(for: .milliseconds(15))
                let offset = controller.collection.contentOffset.y
                moved = moved || offset > start + 1
                samples.append(["sample": sample, "offset": Double(offset),
                    "bottom": Double(controller.bottomOffset), "ticks": controller.followTicks,
                    "steps": controller.followObservationSteps,
                    "step_publications": controller.followPublishComputations,
                    "step_scans": controller.followDescendantScanPasses])
            }
            let steps = controller.followObservationSteps
            let publications = controller.followPublishComputations
            let scans = controller.followDescendantScanPasses
            let tailPath = try XCTUnwrap(controller.dataSource.indexPath(for: .footer))
            let tail = try XCTUnwrap(controller.collection.cellForItem(at: tailPath))
            let frame = tail.convert(tail.bounds, to: controller.view)
            let rate = Double(publications) / Double(max(1, steps))
            records.append(["batched": batched, "steps": steps, "live_ticks": controller.followTicks,
                "initial_footer_height": Double(initialTailHeight), "requested_final_footer_height": 350,
                "step_publications": publications, "step_scans": scans,
                "all_publications": controller.publishComputations - publicationsBefore,
                "all_scans": controller.descendantScanPasses - scansBefore,
                "publications_per_step": rate,
                "scans_per_step": Double(scans) / Double(max(1, steps)),
                "offset": Double(controller.collection.contentOffset.y),
                "bottom": Double(controller.bottomOffset),
                "tail_viewport_frame": [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)],
                "samples": samples])
            XCTAssertTrue(moved)
            XCTAssertGreaterThan(controller.followTicks, 0)
            XCTAssertEqual(steps, controller.followTicks, "Uninterrupted callbacks must advance the live glide")
            XCTAssertNil(controller.followLink)
            XCTAssertTrue(controller.realizedTailArrival)
            XCTAssertTrue(controller.follows)
            XCTAssertFalse(controller.batchingMotionObservations)
            XCTAssertEqual(controller.collection.contentOffset.y, controller.bottomOffset, accuracy: 1)
            if batched {
                XCTAssertEqual(publications, steps)
                XCTAssertLessThanOrEqual(scans, steps)
            }
            // Compare requested content growth; the same scene-hosted footer also
            // includes UIKit safe-area sizing, so its cell is not the bare 350pt body.
            XCTAssertEqual(frame.height - initialTailHeight, 350 - 30, accuracy: 1,
                "The realized footer must include the final requested growth, not only the first update")
            frames.append(frame)
            rates.append(rate)
        }
        XCTAssertLessThan(rates[1], rates[0], "Compare actual computations per callback, not unequal raw tick totals")
        XCTAssertEqual(frames[0].minX, frames[1].minX, accuracy: 1)
        XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1)
        XCTAssertEqual(frames[0].width, frames[1].width, accuracy: 1)
        XCTAssertEqual(frames[0].height, frames[1].height, accuracy: 1)
    }

    func testR51MountedFollowBatchEarlyExitReleasesOrdinaryPublication() async throws {
        var records: [String] = []
        defer {
            let attachment = XCTAttachment(string: records.joined(separator: "\n"))
            attachment.name = "R51 modeled early exits; not physical gestures"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for gesture in [false, true] {
            var reduce = false
            let (controller, fixture) = try mountNativeMotion(initialID: nil,
                reduceMotionOverride: { reduce }, makeCollection: {
                    ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0)
                })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(150))
            controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
                active: true, footerHeight: 250))
            controller.collection.layoutIfNeeded()
            let link = try XCTUnwrap(controller.followLink)
            let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
            // Deliberately modeled tracking/Reduce Motion, not a physical gesture.
            if gesture { collection.modeledTracking = true } else { reduce = true }
            let steps = controller.followObservationSteps
            let scans = controller.descendantScanPasses
            controller.advanceFollow(link)
            XCTAssertNil(controller.followLink)
            XCTAssertFalse(controller.batchingMotionObservations)
            XCTAssertEqual(controller.followObservationSteps, steps)
            XCTAssertEqual(controller.descendantScanPasses, scans)
            controller.lastPublished = nil
            let before = controller.publishComputations
            controller.publish()
            XCTAssertEqual(controller.publishComputations, before + 1)
            XCTAssertNotNil(controller.lastPublished)
            records.append("modeledGesture=\(gesture) steps=\(steps) scans=\(scans) publicationsBeforeOrdinary=\(before) after=\(controller.publishComputations)")
        }
    }

    func testR51MountedFollowBatchRejectsReentrantInvalidation() async throws {
        var records: [String] = []
        defer {
            let attachment = XCTAttachment(string: records.joined(separator: "\n"))
            attachment.name = "R51 injected layout invalidations and raw work counters"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for transition in ["scope", "suspend", "stop", "gesture", "reduce"] {
            var reduce = false
            let (controller, fixture) = try mountNativeMotion(initialID: nil,
                reduceMotionOverride: { reduce })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(150))
            controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
                active: true, footerHeight: 250))
            controller.collection.layoutIfNeeded()
            let link = try XCTUnwrap(controller.followLink)
            let publications = controller.publishComputations
            let scans = controller.descendantScanPasses
            let followPublications = controller.followPublishComputations
            let followScans = controller.followDescendantScanPasses
            let steps = controller.followObservationSteps
            let originalLayout = controller.collection.didLayout
            var invalidated = false
            controller.collection.didLayout = { [weak controller] in
                guard let controller, !invalidated else { return }
                invalidated = true
                XCTAssertTrue(controller.batchingMotionObservations)
                // Inject nested observation requests before invalidating this frame.
                controller.publish()
                controller.disableNestedScrollToTop(in: controller.collection)
                switch transition {
                case "scope": controller.update(self.nativeMotionInput(scope: "r51-\(UUID().uuidString)", initialID: "native-row-5"))
                case "suspend": controller.suspendPresentation()
                case "stop": controller.stop()
                case "gesture": controller.scrollViewWillBeginDragging(controller.collection)
                default: reduce = true; controller.advanceFollow(link)
                }
            }
            controller.collection.setNeedsLayout()
            controller.advanceFollow(link)
            XCTAssertTrue(invalidated)
            XCTAssertFalse(controller.batchingMotionObservations)
            XCTAssertNil(controller.followLink)
            XCTAssertEqual(controller.followObservationSteps, steps + 1)
            let expectedWork = transition == "reduce" ? 1 : 0
            XCTAssertEqual(controller.publishComputations - publications, expectedWork)
            XCTAssertEqual(controller.descendantScanPasses - scans, expectedWork)
            XCTAssertEqual(controller.followPublishComputations - followPublications, expectedWork)
            XCTAssertEqual(controller.followDescendantScanPasses - followScans, expectedWork)
            records.append("transition=\(transition) steps=\(controller.followObservationSteps - steps) publications=\(controller.publishComputations - publications) scans=\(controller.descendantScanPasses - scans)")
            if transition != "stop" {
                controller.collection.didLayout = originalLayout
                if transition == "suspend" { controller.resumePresentation() }
                controller.lastPublished = nil
                let before = controller.publishComputations
                controller.publish()
                XCTAssertEqual(controller.publishComputations, before + 1)
                XCTAssertNotNil(controller.lastPublished)
            }
        }
    }

    func testR50NativeMemoryChurnRetains32RecentPoints() throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let previous = Controller.memory
        Controller.memory.removeAll()
        defer { Controller.memory = previous }
        var oldPolicy: [String: Controller.Memory] = [:]
        for index in 0..<34 {
            let point = Controller.Memory(anchor: .init(id: "row-\(index)", delta: 37), following: false)
            if oldPolicy.count > 32 { oldPolicy.removeAll() }
            oldPolicy["key-\(index)"] = point
            Controller.memory["key-\(index)"] = point
            XCTAssertLessThanOrEqual(Controller.memory.count, 32)
        }
        XCTAssertEqual(oldPolicy.count, 1)
        XCTAssertNil(oldPolicy["key-32"])
        XCTAssertEqual(Controller.memory.count, 32)
        XCTAssertNil(Controller.memory["key-0"])
        XCTAssertNil(Controller.memory["key-1"])
        XCTAssertEqual(try XCTUnwrap(Controller.memory["key-32"]).anchor.delta, 37)
        let evidence = XCTAttachment(string: "34 distinct saves: old policy retains 1; LRU retains 32; recent key-32 delta 37 survives only LRU. Bounded state comparison, not RSS/FPS.")
        evidence.name = "R50 bounded cache policy comparison"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testR50NativeMemoryAccessOverwriteMissAndRemovalRecency() throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let previous = Controller.memory
        Controller.memory.removeAll()
        defer { Controller.memory = previous }
        let point = Controller.Memory(anchor: .init(id: "row", delta: 21), following: false)
        for index in 0..<32 { Controller.memory["key-\(index)"] = point }
        XCTAssertNotNil(Controller.memory["key-0"])
        Controller.memory["key-1"] = .init(anchor: .init(id: "updated", delta: 42), following: true)
        XCTAssertNil(Controller.memory["absent"])
        Controller.memory["key-32"] = point
        Controller.memory["key-33"] = point
        XCTAssertNil(Controller.memory["key-2"])
        XCTAssertNil(Controller.memory["key-3"])
        XCTAssertNotNil(Controller.memory["key-0"])
        let overwritten = try XCTUnwrap(Controller.memory["key-1"])
        XCTAssertEqual(overwritten.anchor.id, "updated")
        XCTAssertEqual(overwritten.anchor.delta, 42)
        XCTAssertTrue(overwritten.following)
        Controller.memory["key-0"] = nil
        Controller.memory["absent"] = nil
        XCTAssertEqual(Controller.memory.count, 31)
        Controller.memory["replacement"] = point
        Controller.memory["overflow"] = point
        XCTAssertNil(Controller.memory["key-4"])
        Controller.memory.removeAll()
        XCTAssertEqual(Controller.memory.count, 0)
        Controller.memory["fresh"] = point
        XCTAssertEqual(Controller.memory.count, 1)
        XCTAssertNotNil(Controller.memory["fresh"])
    }

    func testR50NativeMemoryKeyIsolationAndExplicitTargetPrecedence() async throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let previous = Controller.memory
        Controller.memory.removeAll()
        defer { Controller.memory = previous }
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-5")
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        controller.ownership = .reading
        XCTAssertTrue(controller.align(.init(id: "native-row-5", delta: 37)))
        controller.saveMemory(scope: controller.input.scope)
        let key = controller.memoryKey
        let saved = try XCTUnwrap(Controller.memory[key])
        XCTAssertEqual(saved.anchor.delta, 37, accuracy: 1)
        func assertRow(_ ownership: Controller.Ownership, id: String, delta: CGFloat) {
            guard case .restoring(let anchor) = ownership, let anchor else {
                return XCTFail("Expected a row restore")
            }
            XCTAssertEqual(anchor.id, id)
            XCTAssertEqual(anchor.delta, delta, accuracy: 1)
        }
        assertRow(controller.requestedOwnership(controller.input), id: "native-row-5", delta: 37)
        assertRow(controller.requestedOwnership(nativeMotionInput(scope: controller.input.scope + "-other",
            initialID: "native-row-5")), id: "native-row-5", delta: 0)
        Controller.memory[key] = nil
        let width = Int(controller.collection.bounds.width.rounded())
        Controller.memory["\(controller.input.scope)|\(width + 1)|\(controller.input.typeKey)"] = saved
        Controller.memory["\(controller.input.scope)|\(width)|other-type"] = saved
        assertRow(controller.requestedOwnership(controller.input), id: "native-row-5", delta: 0)
        Controller.memory[key] = saved
        assertRow(controller.requestedOwnership(nativeMotionInput(scope: controller.input.scope,
            initialID: "native-row-7")), id: "native-row-7", delta: 0)
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1, target: .message(id: "native-row-8"))
        assertRow(controller.requestedOwnership(nativeMotionInput(scope: controller.input.scope,
            initialID: "native-row-5", restoreRequest: request)), id: "native-row-8", delta: 0)
        for input in [
            nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5", explicitLatest: true),
            nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
                restoreRequest: .init(scope: UUID(), generation: 2, target: .latest))
        ] {
            guard case .following = controller.requestedOwnership(input) else {
                XCTFail("Explicit latest must win over the saved reader point")
                continue
            }
        }
    }

    func testR50MountedNativeRecentReaderSurvivesPressureAndReopen() async throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let previous = Controller.memory
        Controller.memory.removeAll()
        defer { Controller.memory = previous }
        let scope = "r50-reader-\(UUID().uuidString)"
        let (controller, fixture) = try mountNativeMotion(scope: scope, initialID: "native-row-5")
        var originalMounted = true
        defer { if originalMounted { controller.stop(); tearDown(fixture) } }
        try await Task.sleep(for: .milliseconds(100))
        controller.ownership = .reading
        XCTAssertTrue(controller.align(.init(id: "native-row-5", delta: 37)))
        controller.saveMemory(scope: scope)
        let saved = try XCTUnwrap(controller.currentAnchor())
        XCTAssertEqual(saved.id, "native-row-5")
        XCTAssertEqual(saved.delta, 37, accuracy: 1)
        let source = Array(try XCTUnwrap(controller.input.revisionAt(5).message.message.content).utf8)
        for index in 0..<31 { controller.saveMemory(scope: "\(scope)-pressure-\(index)") }
        guard case .restoring(let touched) = controller.requestedOwnership(controller.input) else {
            return XCTFail("Saved reader must be reusable before pressure")
        }
        XCTAssertEqual(try XCTUnwrap(touched).delta, saved.delta, accuracy: 1)
        for index in 31..<34 { controller.saveMemory(scope: "\(scope)-pressure-\(index)") }
        XCTAssertEqual(Controller.memory.count, 32)
        XCTAssertEqual(try XCTUnwrap(Controller.memory[controller.memoryKey]).anchor.delta, saved.delta, accuracy: 1)
        controller.stop()
        tearDown(fixture)
        originalMounted = false
        let (reopened, reopenedFixture) = try mountNativeMotion(scope: scope, initialID: saved.id)
        defer { reopened.stop(); tearDown(reopenedFixture) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(reopened.memoryKey, controller.memoryKey)
        let restored = try XCTUnwrap(reopened.currentAnchor())
        XCTAssertEqual(restored.id, saved.id)
        XCTAssertEqual(restored.delta, saved.delta, accuracy: 1)
        XCTAssertEqual(Array(try XCTUnwrap(reopened.input.revisionAt(5).message.message.content).utf8), source)
        XCTAssertFalse(reopened.follows)
        XCTAssertNil(reopened.motionLink)
        XCTAssertNil(reopened.followLink)
        let offset = reopened.collection.contentOffset.y
        reopened.collection.setNeedsLayout()
        try await Task.sleep(for: .milliseconds(1050))
        XCTAssertEqual(reopened.collection.contentOffset.y, offset, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(reopened.currentAnchor()).delta, saved.delta, accuracy: 1)
        XCTAssertNil(reopened.motionLink)
        XCTAssertNil(reopened.followLink)
        XCTAssertEqual(reopened.motionSamples, 0)
        XCTAssertEqual(reopened.followTicks, 0)
    }

    private func startMountedNativeMotion(_ controller: ChatNativeTranscriptViewport.Controller) async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Animated lifecycle gate requires system Reduce Motion off")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(controller.view.window)
        XCTAssertTrue(controller.initialized)
        XCTAssertFalse(controller.realizedTailArrival)
        let offset = controller.collection.contentOffset.y
        controller.latest.sendActions(for: .touchUpInside)
        for _ in 0..<20 {
            if controller.motionSamples > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(controller.motionLink, "Cancellation must interrupt an actual live CADisplayLink")
        XCTAssertGreaterThan(controller.motionSamples, 0)
        XCTAssertGreaterThan(controller.collection.contentOffset.y, offset)
    }

    private func assertNativeReaderRemains(_ controller: ChatNativeTranscriptViewport.Controller,
                                          id: String, delta: CGFloat, offset: CGFloat,
                                          completed: Int) async throws {
        // Longer than the production 0.9s expiry: an expired link cannot resume
        // and silently settle at latest on a subsequent layout or parent update.
        let echoToken = try XCTUnwrap(controller.latestEchoCancellationToken)
        controller.update(nativeMotionInput(scope: controller.input.scope,
            initialID: try XCTUnwrap(controller.input.initialID),
            cancellationToken: echoToken, following: true))
        XCTAssertNil(controller.latestEchoCancellationToken)
        controller.collection.setNeedsLayout()
        try await Task.sleep(for: .milliseconds(1050))
        let current = try XCTUnwrap(controller.currentAnchor())
        XCTAssertEqual(current.id, id)
        XCTAssertEqual(current.delta, delta, accuracy: 1)
        XCTAssertEqual(controller.collection.contentOffset.y, offset, accuracy: 1)
        XCTAssertNil(controller.motionLink)
        XCTAssertFalse(controller.follows)
        XCTAssertFalse(controller.realizedTailArrival)
        XCTAssertEqual(controller.motionCompleted, completed)
        // Consuming the stale echo must not permanently disable the next explicit tap.
        controller.latest.sendActions(for: .touchUpInside)
        XCTAssertNotNil(controller.motionLink)
        controller.cancelMotion()
    }

    func testR65MountedWarmEstimatesRemainCorrectableByUIKit() async throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let scope = "r65-warm-\(UUID())"
        let (first, fixture) = try mountNativeMotion(scope: scope, initialID: nil, ids: [])
        await drainNativeScrollQueue()
        first.collection.layoutIfNeeded()
        let layout = try XCTUnwrap(first.collection.collectionViewLayout as? Controller.ColumnLayout)
        XCTAssertTrue(layout.measured.contains(.footer))
        let key = Controller.EstimateKey(scope: scope, width: first.collection.bounds.width,
                                        type: first.input.typeKey, padding: first.input.horizontalPadding)
        first.stop(); tearDown(fixture)
        // Deliberately poison the scalar hint. The mounted factory still owns 30pt.
        Controller.estimates.put(900, item: .footer, key: key)
        let (second, secondFixture) = try mountNativeMotion(scope: scope, initialID: nil, ids: [])
        defer { second.stop(); tearDown(secondFixture) }
        await drainNativeScrollQueue()
        second.collection.layoutIfNeeded()
        let warm = try XCTUnwrap(second.collection.collectionViewLayout as? Controller.ColumnLayout)
        XCTAssertGreaterThan(warm.warmHits, 0)
        XCTAssertTrue(warm.measured.contains(.footer))
        XCTAssertEqual(try nativeBoundaryFrames(second)[1].height, 30, accuracy: 1)
    }

    func testR65PreparedRowDisplayRefreshesHostAndFittingReceipt() async throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-6")
        defer { controller.stop(); tearDown(fixture) }
        await drainNativeScrollQueue()
        let item = Controller.Item.row("native-row-6")
        let path = try XCTUnwrap(controller.dataSource.indexPath(for: item))
        // A real scene-attached host outside the collection's visible set models
        // UIKit's retained prepared-cell callback; it is not a physical-scroll test.
        let prepared = Controller.Cell(frame: CGRect(x: 0, y: 10_000, width: 378, height: 160))
        controller.view.addSubview(prepared)
        defer { prepared.removeFromSuperview() }
        controller.configure(prepared, item: item)
        let stale = try XCTUnwrap(prepared.rowStamp)
        let text = String(repeating: "Prepared rows must refresh their complete content.\n", count: 60)
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-6",
            revision: 1, liveText: text, typeKey: "changed-type", horizontalPadding: 70))
        await drainNativeScrollQueue()
        XCTAssertEqual(prepared.rowStamp, stale, "The hidden host must reach the delegate with stale inputs")
        let expected = try XCTUnwrap(controller.rowStamp(for: "native-row-6"))
        XCTAssertNotEqual(stale, expected)
        controller.collectionView(controller.collection, willDisplay: prepared, forItemAt: path)
        XCTAssertEqual(prepared.rowStamp, expected)
        let layout = try XCTUnwrap(controller.collection.collectionViewLayout as? Controller.ColumnLayout)
        layout.needsFit(item)
        XCTAssertFalse(layout.measured.contains(item))
        let original = try XCTUnwrap(layout.layoutAttributesForItem(at: path))
        let fitted = prepared.preferredLayoutAttributesFitting(original)
        XCTAssertTrue(layout.measured.contains(item), "Fresh callback must accept the new exact key")
        XCTAssertEqual(fitted.size.width, controller.collection.bounds.width - 140, accuracy: 0.01)
        XCTAssertGreaterThan(fitted.size.height, 1_000, "Full multiline source must be laid out, not its stale estimate")
    }

    func testR65EstimateStoreBoundsAndExactWidthIsolation() {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        var store = Controller.EstimateStore()
        for scope in 0...Controller.EstimateStore.scopeLimit {
            let key = Controller.EstimateKey(scope: "scope-\(scope)", width: 390.25, type: "large", padding: 12)
            for row in 0...Controller.EstimateStore.rowLimit {
                store.put(CGFloat(row), item: .row("\(row)"), key: key)
            }
        }
        XCTAssertEqual(store.values.count, Controller.EstimateStore.scopeLimit)
        XCTAssertTrue(store.values.values.allSatisfy { $0.count == Controller.EstimateStore.rowLimit })
        let otherWidth = Controller.EstimateKey(scope: "scope-16", width: 390.5, type: "large", padding: 12)
        XCTAssertTrue(store.heights(for: otherWidth).isEmpty)
        let otherType = Controller.EstimateKey(scope: "scope-16", width: 390.25, type: "small", padding: 12)
        XCTAssertTrue(store.heights(for: otherType).isEmpty)
    }

    func testR65MountedWidthAndDynamicContentRefit() async throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-5")
        defer { controller.stop(); tearDown(fixture) }
        await drainNativeScrollQueue()
        let before = controller.collection.bounds.width
        controller.view.frame.size.width -= 40
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
            revision: 1, liveText: String(repeating: "New multiline content grows.\n", count: 100),
            typeKey: "r65-new-type"))
        await drainNativeScrollQueue()
        controller.collection.layoutIfNeeded()
        XCTAssertEqual(controller.collection.bounds.width, before - 40, accuracy: 1)
        let path = try XCTUnwrap(controller.dataSource.indexPath(for: .row("native-row-6")))
        _ = controller.align(.init(id: "native-row-6", delta: 0))
        controller.collection.layoutIfNeeded()
        await drainNativeScrollQueue()
        let frame = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: path)?.frame)
        let cell = try XCTUnwrap(controller.collection.cellForItem(at: path))
        XCTAssertGreaterThan(frame.height, 1_000, "The 100-line body must not remain at the 160pt estimate")
        XCTAssertEqual(cell.frame.height, frame.height, accuracy: 1)
        XCTAssertEqual(cell.contentView.bounds.height, frame.height, accuracy: 1)
        XCTAssertEqual(frame.width, controller.collection.bounds.width - 24, accuracy: 0.01)
        let layout = try XCTUnwrap(controller.collection.collectionViewLayout as? Controller.ColumnLayout)
        XCTAssertTrue(layout.measured.contains(.row("native-row-6")))
        let priorHeight = frame.height
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-6",
            revision: 1, liveText: String(repeating: "New multiline content grows.\n", count: 100),
            typeKey: "r65-new-type", horizontalPadding: 100))
        await drainNativeScrollQueue()
        controller.collection.layoutIfNeeded()
        let padded = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: path))
        let fitted = cell.preferredLayoutAttributesFitting(padded)
        XCTAssertEqual(padded.size.width, controller.collection.bounds.width - 200, accuracy: 0.01)
        XCTAssertEqual(fitted.size.height, padded.size.height, accuracy: 1,
                       "Mounted hosted content and layout must agree after a padding-only change")
        XCTAssertGreaterThan(padded.size.height, priorHeight, "Narrower wrapping must grow the real multiline body")
    }

    func testNativeOrdinaryFollowingSurvivesSuspendedGrowth() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: nil, reduceMotion: true)
        defer { controller.stop(); tearDown(fixture) }
        try await awaitPresentationActive(controller)
        await drainNativeScrollQueue()
        XCTAssertTrue(controller.follows)
        XCTAssertFalse(controller.explicitLatestOwnsViewport)
        controller.applicationActive = false
        controller.suspendPresentation()
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            revision: 1, footerHeight: 500, following: true))
        XCTAssertTrue(controller.follows, "Suspension must retain ordinary follow intent")
        controller.applicationActive = true
        controller.resumePresentation()
        await drainNativeScrollQueue()
        controller.collection.layoutIfNeeded()
        XCTAssertTrue(controller.follows)
        XCTAssertTrue(controller.realizedTailArrival)
        XCTAssertEqual(controller.collection.contentOffset.y, controller.bottomOffset, accuracy: 1)
    }

    func testNativeOrdinaryRejoinAndSendSurviveSuspendedGrowthAfterMomentumHandoff() async throws {
        for cancellationToken in [0, 1] {
            let (controller, fixture) = try mountNativeMotion(initialID: "native-row-5", reduceMotion: true,
                makeCollection: { ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0) })
            defer { controller.stop(); tearDown(fixture) }
            try await awaitPresentationActive(controller)
            await drainNativeScrollQueue()
            let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
            XCTAssertFalse(controller.follows)
            XCTAssertFalse(controller.realizedTailArrival)
            let parked = collection.contentOffset
            var synchronousEnds = 0
            collection.onMomentumStopped = { [weak controller, weak collection] in
                guard let controller, let collection else { return }
                synchronousEnds += 1
                // Callback before geometry reaches the tail must not turn rejoin
                // into reading, even though native deceleration has ended.
                XCTAssertFalse(controller.realizedTailArrival)
                controller.scrollViewDidEndDragging(collection, willDecelerate: false)
                controller.scrollViewDidEndDecelerating(collection)
                XCTAssertTrue(controller.follows)
                XCTAssertFalse(controller.explicitLatestOwnsViewport)
            }
            collection.modeledDeceleration = true
            controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
                cancellationToken: cancellationToken, following: true, latestToken: 1))
            XCTAssertEqual(synchronousEnds, 1)
            XCTAssertEqual(collection.stoppedMomentumAt, parked)
            XCTAssertEqual(controller.decelerationTakeovers, 1)
            collection.onMomentumStopped = nil
            // The stop callback can also arrive after update, before tail layout.
            XCTAssertFalse(controller.realizedTailArrival)
            controller.scrollViewDidEndDecelerating(collection)
            XCTAssertTrue(controller.follows)
            collection.layoutIfNeeded()
            await drainNativeScrollQueue()
            collection.layoutIfNeeded()
            XCTAssertTrue(controller.follows)
            XCTAssertTrue(controller.realizedTailArrival)
            XCTAssertFalse(controller.explicitLatestOwnsViewport)
            controller.scrollViewDidEndDecelerating(collection)
            XCTAssertTrue(controller.follows)

            controller.applicationActive = false
            controller.suspendPresentation()
            let hiddenOffset = collection.contentOffset.y
            controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
                revision: 1, footerHeight: 500, cancellationToken: cancellationToken,
                following: true, latestToken: 1))
            collection.layoutIfNeeded()
            await drainNativeScrollQueue()
            XCTAssertTrue(controller.follows, "Consumed ordinary rejoin/send intent survives suspension")
            XCTAssertEqual(collection.contentOffset.y, hiddenOffset, accuracy: 1)
            controller.applicationActive = true
            controller.resumePresentation()
            await drainNativeScrollQueue()
            collection.layoutIfNeeded()
            XCTAssertTrue(controller.follows)
            XCTAssertTrue(controller.realizedTailArrival)
            XCTAssertEqual(collection.contentOffset.y, controller.bottomOffset, accuracy: 1)
        }
    }

    private func mountNativeMotion(scope: String = "native-motion-\(UUID().uuidString)",
                                   initialID: String? = "native-row-1", reduceMotion: Bool = false,
                                   ids: [String]? = nil, reusesIdentitySnapshot: Bool = true,
                                   batchesMotionObservations: Bool = true,
                                   coalescesScrollObservations: Bool = true,
                                   onState: @escaping (ChatScrollMetrics, String?, Bool, Bool) -> Void = { _, _, _, _ in },
                                   reduceMotionOverride: (() -> Bool)? = nil,
                                   makeCollection: @escaping @MainActor (UICollectionViewLayout) -> ChatNativeTranscriptViewport.Collection = {
                                       ChatNativeTranscriptViewport.Collection(frame: .zero, collectionViewLayout: $0)
                                   },
                                   onRefresh: @escaping @MainActor (@escaping @MainActor () -> Bool) async -> Void = { _ in }) throws
        -> (ChatNativeTranscriptViewport.Controller, MountedWindowFixture) {
        let input = nativeMotionInput(scope: scope, initialID: initialID, ids: ids, onState: onState, onRefresh: onRefresh)
        let controller = ChatNativeTranscriptViewport.Controller(input: input,
            reduceMotionEnabled: { reduceMotionOverride?() ?? (reduceMotion || UIAccessibility.isReduceMotionEnabled) },
            reusesIdentitySnapshot: reusesIdentitySnapshot,
            batchesMotionObservations: batchesMotionObservations,
            coalescesScrollObservations: coalescesScrollObservations, makeCollection: makeCollection)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (controller, MountedWindowFixture(window: window, previousKeyWindow: previous))
    }

    private func nativeMotionInput(scope: String, initialID: String?, ids suppliedIDs: [String]? = nil,
                                   revision: Int = 0, liveText: String = "", active: Bool = false, footerHeight: CGFloat = 30,
                                   cancellationToken: Int = 0, following: Bool = false, explicitLatest: Bool = false,
                                   latestToken: Int = 0,
                                   restoreRequest: ChatTranscriptRestoreRequest? = nil,
                                   typeKey: String = "mounted-native-motion", headerHeight: CGFloat = 1, horizontalPadding: CGFloat = 12,
                                   onState: @escaping (ChatScrollMetrics, String?, Bool, Bool) -> Void = { _, _, _, _ in },
                                   onRefresh: @escaping @MainActor (@escaping @MainActor () -> Bool) async -> Void = { _ in })
        -> ChatNativeTranscriptViewport {
        let ids = suppliedIDs ?? (0..<40).map { "native-row-\($0)" }
        let environment = EnvironmentValues()
        return ChatNativeTranscriptViewport(ids: ids, revisionAt: { index in
            let message = ChatMessage(role: "assistant",
                                      content: index == 6 ? liveText : "Mounted source row \(index)",
                                      timestamp: Double(index), messageId: ids[index])
            return StableViewportRowRevision(
                message: TranscriptMessage(loadedIndex: index, renderID: ids[index],
                                           anchorID: ids[index], message: message),
                latestCompletedAssistantRenderID: nil, outgoingInsertionEvent: nil,
                allowsOutgoingMotion: false, reasoningGroups: [], toolCallGroups: [],
                liveReasoningText: "", liveToolCalls: [],
                streamingAssistantMessageID: active ? ids[6] : nil,
                liveTokensPerSecond: nil, localAttachmentPreviews: nil,
                compressionReferenceCard: nil, listeningMessageID: nil,
                showsThinkingAndToolCards: false, isViewingCachedData: false,
                hasActiveStream: active, isRegeneratingMessage: false,
                isEditingMessage: false, isForkingMessage: false,
                transcriptMediaCacheNamespace: scope)
        }, revision: revision, typeKey: typeKey, scope: scope,
           initialID: initialID, restoreRequest: restoreRequest, cancellationToken: cancellationToken,
           latestToken: latestToken, explicitLatest: explicitLatest, following: following, isStreaming: active,
           horizontalPadding: horizontalPadding, spacing: 12, bottomInset: 0, environment: environment,
           makeRow: { index in
               AnyView(Text(index == 6 ? liveText : "Mounted source row \(index)")
                   .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading))
           }, makeHeader: { AnyView(Color.clear.frame(height: headerHeight)) },
           makeFooter: { AnyView(Text("Mounted terminal").frame(height: footerHeight)) },
           onLatest: {}, onState: onState, onRestore: { _, _ in }, onRefresh: onRefresh)
    }
    #endif

    private func mountTranscript(
        restoreScrollToken: Int,
        restoreTarget: ChatTranscriptRestoreTarget,
        onAppear: @escaping () -> Void,
        onRestoreLatest: @escaping (Bool) -> Void,
        onRestoreMessage: @escaping (String, Bool) -> Void,
        onVisibleRowIDChange: @escaping (String?) -> Void = { _ in },
        restoreProbe: ChatTranscriptRestoreProbe? = nil,
        onDisplayLinkTick: @escaping (UIWindow?, Int, CFTimeInterval, CFTimeInterval) -> Void = { _, _, _, _ in }
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
            onScrollToBottom: { _, _, _, _ in },
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
                onDisplayLinkTick: onDisplayLinkTick
            )
            .environment(\.chatTranscriptRestoreProbe, restoreProbe)
        )
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windowScene = try XCTUnwrap(
            scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
            "A connected UIWindowScene is required to exercise the mounted SwiftUI lifecycle."
        )
        let window = UIWindow(windowScene: windowScene)
        let previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        // Match the real scene; a fixed smaller window invents an attachment reflow.
        window.frame = windowScene.coordinateSpace.bounds
        window.rootViewController = hostingController
        restoreProbe?.record("mount.makeKeyAndVisible.begin")
        window.makeKeyAndVisible()
        restoreProbe?.record("mount.makeKeyAndVisible.end")
        hostingController.view.frame = window.bounds
        restoreProbe?.record("mount.layoutIfNeeded.begin")
        hostingController.view.layoutIfNeeded()
        restoreProbe?.record("mount.layoutIfNeeded.end")
        return MountedWindowFixture(window: window, previousKeyWindow: previousKeyWindow)
    }

    private func tearDown(_ fixture: MountedWindowFixture) {
        fixture.window.isHidden = true
        fixture.window.rootViewController = nil
        fixture.previousKeyWindow?.makeKey()
    }
}

private struct ReaderShellRoot: View {
    @ObservedObject var route: ReaderShellRoute
    let session: SessionSummary
    let server: URL
    let model: ChatViewModel
    let capture: ReaderShellCapture

    var body: some View {
        NavigationStack {
            Color.clear
                .navigationDestination(isPresented: $route.chatPresented) {
                    ChatView(session: session, server: server, onAPIError: { _ in },
                             loadsInitialMessages: false, retainedViewModel: model,
                             disablesExternalLifecycle: true)
                    .background {
                        WindowAttachmentDisplayLinkProbe { window, tick, _, _ in
                            capture.record(window: window, tick: tick)
                        }
                    }
                }
        }
        .environment(\.scenePhase, .active)
        .environment(\.chatTranscriptRestoreProbe, capture.probe)
    }
}

@MainActor
private final class ReaderShellRoute: ObservableObject {
    @Published var chatPresented = false
}

private struct ReaderShellSample {
    let tick: Int
    let image: UIImage?
    let geometry: String
}

@MainActor
private final class ReaderShellCapture {
    let probe = ChatTranscriptRestoreProbe()
    private(set) var samples: [ReaderShellSample] = []
    private var completed: XCTestExpectation?

    func beginVisit() -> XCTestExpectation {
        samples = []
        let expectation = XCTestExpectation(description: "four raw production shell attachment ticks")
        completed = expectation
        return expectation
    }

    func record(window: UIWindow?, tick: Int) {
        guard completed != nil else { return }
        let image = window.map { window in
            UIGraphicsImageRenderer(bounds: window.bounds).image { context in
                // The judged first tick is the existing whole-window layer tree.
                window.layer.render(in: context.cgContext)
            }
        }
        // Geometry is observed after the capture; it cannot force a later
        // hierarchy repaint into the image or replace tick one with tick four.
        let geometry = window.map {
            "window.bounds=\($0.bounds) safeArea=\($0.safeAreaInsets) scale=\($0.screen.scale)\n"
                + attachedScrollDescription(in: $0)
        } ?? "window=nil"
        samples.append(ReaderShellSample(tick: tick, image: image, geometry: geometry))
        if tick == 4 {
            completed?.fulfill()
            completed = nil
        }
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
            onScrollToBottom: { _, _, _, _ in }, onScrollToLatestTranscriptMessage: { _ in },
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
    let onDisplayLinkTick: (UIWindow?, Int, CFTimeInterval, CFTimeInterval) -> Void

    var body: some View {
        transcript
            .background {
                WindowAttachmentDisplayLinkProbe(onDisplayLinkTick: onDisplayLinkTick)
            }
            .onAppear(perform: onAppear)
    }
}

private struct WindowAttachmentDisplayLinkProbe: UIViewRepresentable {
    @Environment(\.chatTranscriptRestoreProbe) private var restoreProbe
    let onDisplayLinkTick: (UIWindow?, Int, CFTimeInterval, CFTimeInterval) -> Void

    func makeUIView(context: Context) -> WindowAttachmentDisplayLinkProbeView {
        let view = WindowAttachmentDisplayLinkProbeView()
        view.onDisplayLinkTick = onDisplayLinkTick
        view.restoreProbe = restoreProbe
        return view
    }

    func updateUIView(_ uiView: WindowAttachmentDisplayLinkProbeView, context: Context) {
        uiView.onDisplayLinkTick = onDisplayLinkTick
    }

    static func dismantleUIView(_ uiView: WindowAttachmentDisplayLinkProbeView, coordinator: ()) {
        uiView.stop()
    }
}

private final class WindowAttachmentDisplayLinkProbeView: UIView {
    var onDisplayLinkTick: ((UIWindow?, Int, CFTimeInterval, CFTimeInterval) -> Void)?
    private var displayLink: CADisplayLink?
    var restoreProbe: ChatTranscriptRestoreProbe?
    private var tick = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            stop()
            return
        }
        guard displayLink == nil, tick < 4 else { return }
        restoreProbe?.record("probe.didMoveToWindow")

        let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkDidTick(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    @objc private func displayLinkDidTick(_ displayLink: CADisplayLink) {
        tick += 1
        onDisplayLinkTick?(window, tick, displayLink.timestamp, displayLink.targetTimestamp)
        if tick == 4 {
            stop()
            onDisplayLinkTick = nil
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

/// Public UIKit geometry only; querying it does not force layout/commit. All
/// descendant scroll views are reported to expose an absent or wrong attachment.
@MainActor
private func attachedScrollDescription(in window: UIWindow?) -> String {
    guard let window else { return "native.tick window=nil" }
    var samples: [String] = []
    func visit(_ view: UIView) {
        if let scroll = view as? UIScrollView {
            samples.append("id=\(scroll.accessibilityIdentifier ?? "nil") attached=\(scroll.window === window) offset=\(scroll.contentOffset) size=\(scroll.contentSize) bounds=\(scroll.bounds) inset=\(scroll.adjustedContentInset) presentationBounds=\(String(describing: scroll.layer.presentation()?.bounds)) dragging=\(scroll.isDragging) tracking=\(scroll.isTracking)")
        }
        view.subviews.forEach(visit)
    }
    visit(window)
    return "native.tick count=\(samples.count) " + samples.joined(separator: " | ")
}

/// Observation-only candidates, all expressed in hosting-view coordinates.
/// UIView.convert(_:to:) accounts for the scroll bounds' contentOffset origin;
/// frame is in the superview's coordinates and must not be compared directly.
/// Safe areas and adjusted content insets describe layout, not opaque occlusion.
/// None of these candidates asserts which pixels the real app makes visible.
@MainActor
private func firstTickViewportDescription(in window: UIWindow?) -> String {
    guard let window, let hosting = window.rootViewController?.viewIfLoaded else {
        return "viewport.tick1 windowOrLoadedHosting=nil"
    }
    let hostBounds = hosting.bounds
    let hostSafe = hosting.safeAreaLayoutGuide.layoutFrame
    let windowInHost = window.convert(window.bounds, to: hosting)
    let rawCaptureInHost = hostBounds.intersection(windowInHost)
    var samples = [
        "viewport.tick1 units=points candidateSpace=hosting capture=UIWindow.layer phase=afterRawCapture",
        "hosting.bounds=\(hostBounds) frameInSuperview=\(hosting.frame) safeAreaInsets=\(hosting.safeAreaInsets) safeAreaLayoutFrame=\(hostSafe)",
        "window.bounds=\(window.bounds) frame=\(window.frame) safeAreaInsets=\(window.safeAreaInsets) boundsInHosting=\(windowInHost) screenScale=\(window.screen.scale)"
    ]
    var scrollIndex = 0
    func visit(_ view: UIView) {
        if let scroll = view as? UIScrollView {
            let index = scrollIndex
            scrollIndex += 1
            let nativeInHost = scroll.convert(scroll.bounds, to: hosting)
            let adjustedBounds = scroll.bounds.inset(by: scroll.adjustedContentInset)
            let adjustedInHost = scroll.convert(adjustedBounds, to: hosting)
            let nativeSafeInHost = scroll.convert(scroll.safeAreaLayoutGuide.layoutFrame, to: hosting)
            let raw = nativeInHost.intersection(rawCaptureInHost)
            // Intersect actual clipping ancestors separately from safe areas.
            // Safe-area membership alone does not imply a layer clips there.
            var ancestorClipped = raw
            var ancestor = scroll.superview
            var ancestorIndex = 0
            while let current = ancestor {
                let rect = current.convert(current.bounds, to: hosting)
                if current.clipsToBounds {
                    ancestorClipped = ancestorClipped.intersection(rect)
                }
                samples.append("scroll[\(index)].ancestor[\(ancestorIndex)] type=\(String(describing: type(of: current))) boundsInHosting=\(rect) clipsToBounds=\(current.clipsToBounds)")
                if current === window { break }
                ancestor = current.superview
                ancestorIndex += 1
            }
            samples.append("scroll[\(index)] type=\(String(describing: type(of: scroll))) id=\(scroll.accessibilityIdentifier ?? "nil") attached=\(scroll.window === window) bounds=\(scroll.bounds) frameInSuperview=\(scroll.frame) contentOffset=\(scroll.contentOffset) contentInset=\(scroll.contentInset) adjustedContentInset=\(scroll.adjustedContentInset) safeAreaInsets=\(scroll.safeAreaInsets) safeAreaLayoutFrame=\(scroll.safeAreaLayoutGuide.layoutFrame) clipsToBounds=\(scroll.clipsToBounds)")
            samples.append("scroll[\(index)].converted nativeBounds=\(nativeInHost) adjustedBounds=\(adjustedInHost) nativeSafeArea=\(nativeSafeInHost)")
            // Names encode the entire formula; no fixed status-bar offset.
            samples.append("scroll[\(index)].candidate.rawCaptureIntersection=\(raw)")
            samples.append("scroll[\(index)].candidate.ancestorClipped=\(ancestorClipped)")
            samples.append("scroll[\(index)].candidate.ancestorClipped_hostSafe=\(ancestorClipped.intersection(hostSafe))")
            samples.append("scroll[\(index)].candidate.ancestorClipped_nativeSafe=\(ancestorClipped.intersection(nativeSafeInHost))")
            samples.append("scroll[\(index)].candidate.ancestorClipped_adjustedInsets=\(ancestorClipped.intersection(adjustedInHost))")
        }
        view.subviews.forEach(visit)
    }
    visit(hosting)
    samples.append("viewport.tick1 scrollCount=\(scrollIndex)")
    return samples.joined(separator: "\n")
}
