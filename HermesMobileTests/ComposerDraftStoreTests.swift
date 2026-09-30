import XCTest
import SwiftUI
import UIKit
@testable import HermesMobile

@MainActor
final class ComposerDraftStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: ComposerDraftStore!
    private let server = URL(string: "https://semreh.example")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ComposerDraftStoreTests.\(UUID().uuidString)")
        store = ComposerDraftStore(defaults: defaults)
    }

    override func tearDown() {
        store.resetForTesting()
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.contains("suite") ? "" : "")
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testLeaveAndReopenRestoresTypedDraft() {
        store.save("half-written thought", server: server, sessionID: "session-a")

        XCTAssertEqual(
            store.load(server: server, sessionID: "session-a"),
            "half-written thought"
        )
    }

    func testDraftsAreIsolatedPerSession() {
        store.save("for A", server: server, sessionID: "session-a")
        store.save("for B", server: server, sessionID: "session-b")

        XCTAssertEqual(store.load(server: server, sessionID: "session-a"), "for A")
        XCTAssertEqual(store.load(server: server, sessionID: "session-b"), "for B")
    }

    func testDraftSurvivesANewStoreInstanceLikeAnAppRestart() {
        store.save("still here after relaunch", server: server, sessionID: "session-a")

        let relaunched = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a"),
            "still here after relaunch"
        )
    }

    func testClearingOrSendingRemovesTheDraft() {
        store.save("do not keep after send", server: server, sessionID: "session-a")
        store.clear(server: server, sessionID: "session-a")

        XCTAssertEqual(store.load(server: server, sessionID: "session-a"), "")
    }

    func testPreAwaitClearRemovesSubmittedDraftWithoutTouchingAnotherSession() {
        // Store-level coverage for the write sequence used before a gated
        // send. This does not prove production call order or process-death
        // durability.
        store.save("A", server: server, sessionID: "session-a")
        store.save("B", server: server, sessionID: "session-b")

        store.save("", server: server, sessionID: "session-a")

        let freshStore = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(freshStore.load(server: server, sessionID: "session-a"), "")
        XCTAssertEqual(freshStore.load(server: server, sessionID: "session-b"), "B")
    }

    func testDefiniteFailureCanRestoreDraftAfterPreAwaitClear() {
        store.save("A", server: server, sessionID: "session-a")

        // Model the direct-send sequence: clear before the await, then
        // restore the submitted draft when the operation definitely fails.
        store.save("", server: server, sessionID: "session-a")
        store.save("A", server: server, sessionID: "session-a")

        XCTAssertEqual(store.load(server: server, sessionID: "session-a"), "A")
    }

    func testEmptyOrWhitespaceOnlyDraftIsNotRestored() {
        store.save("   \n\t  ", server: server, sessionID: "session-a")

        XCTAssertEqual(store.load(server: server, sessionID: "session-a"), "")
    }

    func testShareSheetDraftWinsOverAnEmptyStoredDraft() {
        XCTAssertEqual(
            ComposerDraftStore.resolvedDraft(initialDraft: "from share", storedDraft: ""),
            "from share"
        )
    }

    func testStoredDraftWinsWhenTheComposerWouldOtherwiseBeEmpty() {
        XCTAssertEqual(
            ComposerDraftStore.resolvedDraft(initialDraft: "", storedDraft: "cached"),
            "cached"
        )
    }
}

@MainActor
final class TranscriptRestoreStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: TranscriptRestoreStore!
    private let server = URL(string: "https://semreh.example")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "TranscriptRestoreStoreTests.\(UUID().uuidString)")
        store = TranscriptRestoreStore(defaults: defaults)
    }

    override func tearDown() {
        store.resetForTesting()
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testLeaveWhileReadingOlderSurvivesAppRestart() {
        store.save(
            TranscriptRestorePoint(followingLatest: false, visibleMessageID: "msg-where-i-left"),
            server: server,
            sessionID: "session-a"
        )

        let relaunched = TranscriptRestoreStore(defaults: defaults)
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a"),
            TranscriptRestorePoint(followingLatest: false, visibleMessageID: "msg-where-i-left")
        )
    }

    func testFollowingLatestDoesNotKeepAStaleMessageID() {
        store.save(
            TranscriptRestorePoint(followingLatest: true, visibleMessageID: "msg-mid"),
            server: server,
            sessionID: "session-a"
        )

        XCTAssertEqual(
            ChatTranscriptRestorePolicy.target(
                wasFollowingLatest: store.load(server: server, sessionID: "session-a").followingLatest,
                lastVisibleMessageID: store.load(server: server, sessionID: "session-a").visibleMessageID
            ),
            .latest
        )
    }
}

#if DEBUG
@MainActor
final class ChatP09DiagnosticRestoreBootstrapTests: XCTestCase {
    func testCalibrationOneShotRejectsDuplicateAndWrongScopeRelease() {
        var state = ChatP09CalibrationState()
        let scope = UUID()
        XCTAssertFalse(state.finish(scope: scope, released: true))
        XCTAssertTrue(state.begin(scope: scope))
        XCTAssertFalse(state.begin(scope: scope))
        XCTAssertFalse(state.finish(scope: UUID(), released: true))
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertTrue(state.finish(scope: scope, released: true))
        XCTAssertEqual(state.phase, .released)
        XCTAssertFalse(state.finish(scope: scope, released: true))
        XCTAssertFalse(state.begin(scope: scope))
    }

    func testCalibrationTimeoutAndCancellationAbortRatherThanRelease() {
        for _ in ["timeout", "scope_or_user_cancellation"] {
            var state = ChatP09CalibrationState()
            let scope = UUID()
            XCTAssertTrue(state.begin(scope: scope))
            XCTAssertTrue(state.finish(scope: scope, released: false))
            XCTAssertEqual(state.phase, .aborted)
            XCTAssertFalse(state.finish(scope: scope, released: true))
            XCTAssertFalse(state.begin(scope: scope))
        }
    }

    func testCalibrationNonceRequiresExactSeedFixture() {
        let nonce = UUID().uuidString
        let key = "SEMREH_P09_CALIBRATION_NONCE"
        let arguments = ["--chat-p09-seed-restore",
                         "--chat-p09-restore-server=https://semreh-slice1-test.tailda8427.ts.net",
                         "--chat-p09-restore-session=p09-test", "--chat-p09-restore-message=123"]
        XCTAssertEqual(ChatP09CalibrationState.nonce(arguments: arguments, environment: [key: nonce]), nonce)
        let server = URL(string: "https://semreh-slice1-test.tailda8427.ts.net")!
        XCTAssertTrue(ChatP09CalibrationState.matchesFixture(arguments: arguments, server: server, sessionID: "p09-test"))
        XCTAssertFalse(ChatP09CalibrationState.matchesFixture(arguments: arguments, server: server, sessionID: "other-session"))
        XCTAssertFalse(ChatP09CalibrationState.matchesFixture(arguments: arguments, server: URL(string: "https://outside.example")!, sessionID: "p09-test"))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: [], environment: [key: nonce]))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: arguments, environment: [:]))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: arguments, environment: [key: "malformed"]))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: arguments.map { $0.replacingOccurrences(of: "semreh-slice1-test.tailda8427.ts.net", with: "outside.example") }, environment: [key: nonce]))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: arguments.map { $0.replacingOccurrences(of: "--chat-p09-seed-restore", with: "--chat-p09-cleanup-restore") }, environment: [key: nonce]))
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let server = URL(string: "https://semreh-slice1-test.tailda8427.ts.net")!
    private let sessionID = "p09-session-123"
    private let oldMessageID = "old-message-456"
    private let seededMessageID = "seed-message-789"

    override func setUp() {
        super.setUp()
        suiteName = "ChatP09DiagnosticRestoreBootstrapTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSeedRequestRequiresApprovedOriginAndCompleteCanonicalScope() {
        let valid = seedArguments()
        let request = ChatP09DiagnosticRestoreRequest.parse(arguments: valid)
        XCTAssertEqual(request?.operation, .seed)
        XCTAssertEqual(request?.server, server)
        XCTAssertEqual(request?.sessionID, sessionID)
        XCTAssertEqual(request?.visibleMessageID, seededMessageID)

        let invalidRequests: [[String]] = [
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)https://other.example",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(seededMessageID)"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)bad/session",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(seededMessageID)"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)bad/message"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(String(repeating: "x", count: 129))"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             ChatP09DiagnosticRestoreRequest.cleanupArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(seededMessageID)"],
        ]

        for arguments in invalidRequests {
            XCTAssertNil(
                ChatP09DiagnosticRestoreRequest.parse(arguments: arguments),
                "out-of-scope P09 arguments must fail closed: \(arguments)"
            )
        }
    }

    func testSeedAndCleanupRestoreOnlyTheExactPriorReaderPoint() {
        let store = TranscriptRestoreStore(defaults: defaults)
        let unrelatedKey = "unrelated-setting"
        defaults.set("preserve-me", forKey: unrelatedKey)
        let prior = TranscriptRestorePoint(
            followingLatest: false,
            visibleMessageID: oldMessageID
        )
        store.save(prior, server: server, sessionID: sessionID)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .installed
        )
        XCTAssertEqual(
            store.load(server: server, sessionID: sessionID),
            TranscriptRestorePoint(
                followingLatest: false,
                visibleMessageID: "transcript:row:\(seededMessageID)"
            )
        )
        XCTAssertEqual(defaults.string(forKey: unrelatedKey), "preserve-me")
        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .rejected,
            "a second seed must not overwrite the saved backup"
        )

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(
                arguments: cleanupArguments(),
                defaults: defaults
            ),
            .restored
        )
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), prior)
        XCTAssertEqual(defaults.string(forKey: unrelatedKey), "preserve-me")
    }

    func testDirectTranscriptRenderIdentityUsesTheProductionNamespace() {
        XCTAssertEqual(
            TranscriptRenderIdentity.directID(for: seededMessageID),
            "transcript:row:\(seededMessageID)"
        )
        XCTAssertNil(TranscriptRenderIdentity.directID(for: nil))
        XCTAssertNil(TranscriptRenderIdentity.directID(for: ""))
    }

    func testCleanupWithoutMatchingSeedDoesNotWipeTheRestorePoint() {
        let store = TranscriptRestoreStore(defaults: defaults)
        let prior = TranscriptRestorePoint(
            followingLatest: false,
            visibleMessageID: oldMessageID
        )
        store.save(prior, server: server, sessionID: sessionID)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(
                arguments: cleanupArguments(),
                defaults: defaults
            ),
            .rejected
        )
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), prior)
    }

    func testSeedWithoutPriorPointCleansBackToLatestWithoutLeavingBackup() {
        let store = TranscriptRestoreStore(defaults: defaults)
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), .followingLatest)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .installed
        )
        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(
                arguments: cleanupArguments(),
                defaults: defaults
            ),
            .restored
        )
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), .followingLatest)
        XCTAssertFalse(
            defaults.dictionaryRepresentation().keys.contains {
                $0.contains("chatP09.restore-backup")
            }
        )
    }

    func testNonDataBackupRejectsSeedWithoutReplacingIt() {
        let store = TranscriptRestoreStore(defaults: defaults)
        let prior = TranscriptRestorePoint(
            followingLatest: false,
            visibleMessageID: oldMessageID
        )
        store.save(prior, server: server, sessionID: sessionID)
        defaults.set("not-a-data-backup", forKey: backupKey)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .rejected
        )
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), prior)
        XCTAssertEqual(defaults.string(forKey: backupKey), "not-a-data-backup")
    }

    func testNonDataPriorRestoreRejectsSeedWithoutReplacingIt() {
        defaults.set("not-a-data-restore", forKey: restoreKey)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .rejected
        )
        XCTAssertEqual(defaults.string(forKey: restoreKey), "not-a-data-restore")
        XCTAssertNil(defaults.object(forKey: backupKey))
    }

    func testNonDataCleanupTargetRejectsWithoutOverwritingCurrentValue() {
        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .installed
        )
        defaults.set("later-corrupt-value", forKey: restoreKey)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(
                arguments: cleanupArguments(),
                defaults: defaults
            ),
            .rejected
        )
        XCTAssertEqual(defaults.string(forKey: restoreKey), "later-corrupt-value")
        XCTAssertNotNil(defaults.object(forKey: backupKey))
    }

    private func seedArguments() -> [String] {
        [
            ChatP09DiagnosticRestoreRequest.seedArgument,
            "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
            "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
            "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(seededMessageID)",
        ]
    }

    private func cleanupArguments() -> [String] {
        [
            ChatP09DiagnosticRestoreRequest.cleanupArgument,
            "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
            "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
        ]
    }

    private var restoreKey: String {
        "\(TranscriptRestoreStore.visibilityKeyPrefix)\(server.absoluteString)|\(sessionID)"
    }

    private var backupKey: String {
        "semreh.debug.chatP09.restore-backup.\(server.absoluteString)|\(sessionID)"
    }
}
#endif

@MainActor
final class LiveRunBookmarkStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: LiveRunBookmarkStore!
    private let server = URL(string: "https://semreh.example")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LiveRunBookmarkStoreTests.\(UUID().uuidString)")
        store = LiveRunBookmarkStore(defaults: defaults)
    }

    override func tearDown() {
        store.resetForTesting()
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testBookmarkSurvivesProcessDeath() {
        store.save(
            LiveRunBookmark(
                streamID: "stream-live",
                lastEventID: "42",
                liveReasoningText: "checking the lock",
                streamingAssistantMessageID: "msg-assistant",
                liveToolCalls: [
                    ToolCall(
                        id: "tool-1",
                        name: "read_file",
                        preview: "README.md",
                        args: nil,
                        isCompleted: false
                    )
                ]
            ),
            server: server,
            sessionID: "session-a"
        )

        let relaunched = LiveRunBookmarkStore(defaults: defaults)
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a")?.streamID,
            "stream-live"
        )
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a")?.liveReasoningText,
            "checking the lock"
        )
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a")?.liveToolCalls.first?.name,
            "read_file"
        )
    }

    func testFinishedRunClearsTheBookmark() {
        store.save(
            LiveRunBookmark(
                streamID: "stream-live",
                lastEventID: nil,
                liveReasoningText: "done",
                streamingAssistantMessageID: nil
            ),
            server: server,
            sessionID: "session-a"
        )
        store.remove(server: server, sessionID: "session-a")
        XCTAssertNil(store.load(server: server, sessionID: "session-a"))
    }
}

@MainActor
private func makeComposerSizingView(_ text: String = "A short draft") -> UITextView {
    let view = ComposerTextView.PastingTextView(frame: CGRect(x: 0, y: 0, width: 280, height: 120))
    view.font = .systemFont(ofSize: 17)
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.isScrollEnabled = false
    view.text = text
    return view
}

@MainActor
private func makeComposerSizingCoordinator(onHeight: @escaping (CGFloat) -> Void = { _ in }) -> ComposerTextView.Coordinator {
    ComposerTextView.Coordinator(text: .constant(""), isFocused: .constant(false), onHeightChange: onHeight)
}

@MainActor
final class ComposerProposalSizingTests: XCTestCase {
    func testLongDraftHonorsProposedWidthAndCapsHeightAcrossRelayout() async throws {
        let draft = String(repeating: "Preserved draft with selectable words and wrapping. ", count: 100)
        var reportedHeight: CGFloat = 0
        let input = ComposerTextView(
            text: .constant(draft),
            isFocused: .constant(false),
            isDisabled: false,
            isKeyboardSendEnabled: false,
            onKeyboardSend: {},
            onHeightChange: { reportedHeight = $0 },
            onPasteFileProviders: { _ in },
            onPasteFileURLs: { _ in },
            onPasteImageProviders: { _ in },
            onPasteImages: { _ in }
        )
        let host = UIHostingController(rootView: input)
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let container = UIViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        defer {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        for width in [CGFloat(280), 160, 340] {
            host.view.frame = CGRect(x: 0, y: 100, width: width, height: 120)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let size = host.sizeThatFits(in: CGSize(width: width, height: 1_000))
            XCTAssertEqual(size.width, width, accuracy: 0.5, "A persisted draft must not expand the proposal")
            XCTAssertEqual(size.height, 120, accuracy: 0.5, "Long drafts must scroll within the existing height cap")
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let textView = try XCTUnwrap(findTextView(in: host.view))
            textView.setNeedsLayout()
            textView.layoutIfNeeded()
            XCTAssertEqual(textView.bounds.width, width, accuracy: 0.5)
            XCTAssertEqual(reportedHeight, size.height, accuracy: 0.5)
            XCTAssertTrue(textView.isScrollEnabled)
            XCTAssertFalse(textView.scrollsToTop, "The capped composer must not compete with transcript status-bar scrolling")
            XCTAssertTrue(textView.isSelectable)
            XCTAssertEqual(textView.text, draft)
        }
    }

    func testAlternatingWidthsMatchUIKitWithFewerMeasurementsAB() {
        let draft = String(repeating: "Unicode 👩🏽‍💻 العربية 漢字 e\u{301} wrapping ", count: 12)
        let widths: [CGFloat] = [160, 280, 160, 280, 160, 280]
        var rows = ["capacity,request,width,utf16_count,measurement_calls,height,UIKit_height"]
        defer {
            let attachment = XCTAttachment(string: rows.joined(separator: "\n"))
            attachment.name = "R53 actual UIKit calls and exact heights (not app latency)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for capacity in [1, 4] {
            let view = makeComposerSizingView(draft)
            let coordinator = ComposerTextView.Coordinator(text: .constant(""), isFocused: .constant(false),
                onHeightChange: { _ in }, measurementCacheCapacity: capacity)
            var calls = 0
            coordinator.measureContentHeight = { view, width in
                calls += 1
                return ComposerTextView.contentHeight(for: view, width: width)
            }
            let selection = view.selectedRange
            let focus = view.isFirstResponder
            for (request, width) in widths.enumerated() {
                let before = calls
                let actual = coordinator.contentHeight(for: view, width: width)
                let oracle = ComposerTextView.contentHeight(for: view, width: width)
                XCTAssertEqual(actual, oracle)
                XCTAssertLessThanOrEqual(coordinator.cachedMeasurementEntryCount, capacity)
                rows.append("\(capacity),\(request),\(width),\(draft.utf16.count),\(calls - before),\(actual),\(oracle)")
            }
            XCTAssertEqual(calls, capacity == 1 ? widths.count : 2)
            XCTAssertEqual(view.text, draft)
            XCTAssertEqual(view.selectedRange, selection)
            XCTAssertEqual(view.isFirstResponder, focus)
        }
    }

    func testProposalAndPostLayoutWidthsRetainBothMeasurements() {
        let view = makeComposerSizingView()
        var reports: [CGFloat] = []
        let coordinator = ComposerTextView.Coordinator(text: .constant(""), isFocused: .constant(false),
            onHeightChange: { reports.append($0) }, measurementCacheCapacity: 4)
        var calls = 0
        coordinator.measureContentHeight = { view, width in
            calls += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        for _ in 0..<6 {
            XCTAssertEqual(coordinator.contentHeight(for: view, width: 160),
                           ComposerTextView.contentHeight(for: view, width: 160))
            coordinator.reportHeight(for: view)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 2)
        XCTAssertEqual(reports, [min(120, max(22, ComposerTextView.contentHeight(for: view, width: 280)))])
    }

    func testMeasurementCachePressurePromotesHitsAndBoundsCapacity() {
        let view = makeComposerSizingView()
        let coordinator = ComposerTextView.Coordinator(text: .constant(""), isFocused: .constant(false),
            onHeightChange: { _ in }, measurementCacheCapacity: 4)
        var calls = 0
        coordinator.measureContentHeight = { view, width in
            calls += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        for width in [CGFloat(160), 180, 200, 220, 160, 240, 160] {
            XCTAssertEqual(coordinator.contentHeight(for: view, width: width),
                           ComposerTextView.contentHeight(for: view, width: width))
            XCTAssertLessThanOrEqual(coordinator.cachedMeasurementEntryCount, 4)
        }
        XCTAssertEqual(calls, 5, "A hit must promote 160 ahead of the evicted 180 entry")
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 4)
        XCTAssertEqual(coordinator.contentHeight(for: view, width: 180),
                       ComposerTextView.contentHeight(for: view, width: 180))
        XCTAssertEqual(calls, 6)
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 4)
    }

    func testViewChangeAndUnsupportedContentClearAllCachedEntries() {
        let first = makeComposerSizingView()
        let second = makeComposerSizingView()
        let coordinator = ComposerTextView.Coordinator(text: .constant(""), isFocused: .constant(false),
            onHeightChange: { _ in }, measurementCacheCapacity: 4)
        var calls = 0
        coordinator.measureContentHeight = { view, width in
            calls += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        for width in [CGFloat(160), 280] { _ = coordinator.contentHeight(for: first, width: width) }
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 2)
        _ = coordinator.contentHeight(for: second, width: 160)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 1)
        _ = coordinator.contentHeight(for: first, width: 160)
        XCTAssertEqual(calls, 4)
        first.textStorage.addAttribute(.kern, value: 2, range: NSRange(location: 0, length: 1))
        for _ in 0..<2 {
            XCTAssertEqual(coordinator.contentHeight(for: first, width: 160),
                           ComposerTextView.contentHeight(for: first, width: 160))
            XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 0)
        }
        XCTAssertEqual(calls, 6)
        first.textStorage.removeAttribute(.kern, range: NSRange(location: 0, length: 1))
        _ = coordinator.contentHeight(for: first, width: 160)
        XCTAssertEqual(calls, 7, "Unsupported content must discard the previously supported entries")
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 1)
        first.setMarkedText("候補", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertNotNil(first.markedTextRange)
        _ = coordinator.contentHeight(for: first, width: 160)
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 0)
        XCTAssertEqual(calls, 8)
        first.unmarkText()
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }
}

@MainActor
final class ComposerMeasurementReuseTests: XCTestCase {
    func testIdenticalProposalAndReportReuseRealMeasurement() {
        let view = makeComposerSizingView()
        var reports: [CGFloat] = []
        let coordinator = makeComposerSizingCoordinator { reports.append($0) }
        var operations = 0
        coordinator.measureContentHeight = { view, width in
            operations += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        let oracle = ComposerTextView.contentHeight(for: view, width: 280)
        let proposal = coordinator.contentHeight(for: view, width: 280)
        for _ in 0..<12 {
            XCTAssertEqual(coordinator.contentHeight(for: view, width: 280), oracle)
            coordinator.reportHeight(for: view)
        }
        XCTAssertEqual(proposal, oracle)
        XCTAssertEqual(operations, 1)
        XCTAssertEqual(reports, [min(120, max(22, oracle))])
    }

    func testSizingMutationsInvalidateWithoutChangingUIKitGeometry() {
        let view = makeComposerSizingView(String(repeating: "مرحبا 👩🏽‍💻 e\u{301} words ", count: 20))
        let coordinator = makeComposerSizingCoordinator()
        var operations = 0
        coordinator.measureContentHeight = { view, width in
            operations += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        _ = coordinator.contentHeight(for: view, width: view.bounds.width)
        let mutations: [(String, () -> Void)] = [
            ("programmatic replacement", { view.text = "Replacement\n" + view.text }),
            ("typing/paste", { view.insertText(" pasted 🧑‍🚀") }),
            ("width", { view.bounds.size.width = 160 }),
            ("same-size font", { view.font = .monospacedSystemFont(ofSize: 17, weight: .bold) }),
            ("paragraph style", {
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 13
                view.textStorage.addAttribute(.paragraphStyle, value: style,
                    range: NSRange(location: 0, length: view.textStorage.length))
            }),
            ("insets", { view.textContainerInset.top = 11 }),
            ("padding", { view.textContainer.lineFragmentPadding = 9 }),
            ("RTL", { view.semanticContentAttribute = .forceRightToLeft; view.textAlignment = .right }),
            ("traits", {
                view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
                view.updateTraitsIfNeeded()
                XCTAssertEqual(view.traitCollection.preferredContentSizeCategory, .accessibilityExtraExtraExtraLarge)
            }),
            ("line limit", { view.textContainer.maximumNumberOfLines = 3 }),
            ("line break", { view.textContainer.lineBreakMode = .byTruncatingTail })
        ]
        for (name, mutate) in mutations {
            mutate()
            let before = operations
            let actual = coordinator.contentHeight(for: view, width: view.bounds.width)
            XCTAssertEqual(operations, before + 1, name)
            XCTAssertEqual(actual, ComposerTextView.contentHeight(for: view, width: view.bounds.width), name)
        }
        // Unsupported runs and IME composition deliberately never reuse a result.
        view.textStorage.addAttribute(.kern, value: 2, range: NSRange(location: 0, length: 1))
        var before = operations
        for _ in 0..<2 { _ = coordinator.contentHeight(for: view, width: view.bounds.width) }
        XCTAssertEqual(operations, before + 2)
        view.text = "composition"
        view.setMarkedText("候補", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        before = operations
        for _ in 0..<2 { _ = coordinator.contentHeight(for: view, width: view.bounds.width) }
        XCTAssertEqual(operations, before + 2)
        view.unmarkText()
    }

    func testIndependentViewLifetimesAndRestoredUnicodeDraftPreserveState() {
        let draft = String(repeating: "👨‍👩‍👧‍👦 مرحبا e\u{301} 漢字\n", count: 150)
        let coordinator = makeComposerSizingCoordinator()
        var operations = 0
        coordinator.measureContentHeight = { view, width in
            operations += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        weak var released: UITextView?
        do {
            let first = makeComposerSizingView(draft)
            released = first
            _ = coordinator.contentHeight(for: first, width: 280)
        }
        XCTAssertNil(released, "The cache must not retain a text view")
        let restored = makeComposerSizingView(draft)
        restored.selectedRange = NSRange(location: 4, length: 0)
        let selection = restored.selectedRange
        let focus = restored.isFirstResponder
        let before = operations
        let height = coordinator.contentHeight(for: restored, width: 280)
        XCTAssertEqual(operations, before + 1)
        XCTAssertEqual(height, ComposerTextView.contentHeight(for: restored, width: 280))
        var reported: CGFloat = 0
        coordinator.onHeightChange = { reported = $0 }
        coordinator.reportHeight(for: restored)
        XCTAssertEqual(reported, 120)
        XCTAssertTrue(restored.isScrollEnabled)
        XCTAssertEqual(restored.text, draft)
        XCTAssertEqual(restored.selectedRange, selection)
        XCTAssertEqual(restored.isFirstResponder, focus)
        let independent = makeComposerSizingCoordinator()
        var independentOperations = 0
        independent.measureContentHeight = { view, width in
            independentOperations += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        _ = independent.contentHeight(for: restored, width: 280)
        XCTAssertEqual(independentOperations, 1)
        restored.text = ""
        coordinator.reportHeight(for: restored)
        XCTAssertEqual(reported, max(22, min(120, ComposerTextView.contentHeight(for: restored, width: 280))))
        XCTAssertFalse(restored.isScrollEnabled)
    }

    func testBoundedSameProcessMeasurementABAttachment() {
        let draft = String(repeating: "Unicode 👩🏽‍💻 العربية 漢字 e\u{301} wrapping\n", count: 150)
        var rows = ["round,mode,iteration,duration_ns,measurement_count,height"]
        defer {
            let attachment = XCTAttachment(string: rows.joined(separator: "\n"))
            attachment.name = "R49 real UIKit measurement AB raw iterations (not UI FPS)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for round in 0..<4 {
            for cached in (round.isMultiple(of: 2) ? [false, true] : [true, false]) {
                let view = makeComposerSizingView(draft)
                let coordinator = makeComposerSizingCoordinator()
                var operations = 0
                coordinator.measureContentHeight = { view, width in
                    operations += 1
                    return ComposerTextView.contentHeight(for: view, width: width)
                }
                let oracle = ComposerTextView.contentHeight(for: view, width: 280)
                for iteration in 0..<20 {
                    let before = operations
                    let start = DispatchTime.now().uptimeNanoseconds
                    let height: CGFloat
                    if cached {
                        height = coordinator.contentHeight(for: view, width: 280)
                    } else {
                        operations += 1
                        height = ComposerTextView.contentHeight(for: view, width: 280)
                    }
                    let duration = DispatchTime.now().uptimeNanoseconds - start
                    rows.append("\(round),\(cached ? "cached" : "uncached"),\(iteration),\(duration),\(operations - before),\(height)")
                    XCTAssertEqual(height, oracle)
                }
                XCTAssertEqual(operations, cached ? 1 : 20)
                XCTAssertEqual(view.text, draft)
            }
        }
    }
}
