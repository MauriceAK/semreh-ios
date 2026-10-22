import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import HermesCompanion

@MainActor
final class SendPresentationTests: XCTestCase {
    private let submittedText = "First line\nSecond line\nThird line\nFourth line"
    private var suite: String!
    private var defaults: UserDefaults!
    private var session: URLSession!
    private var store: AppStore!
    private var attachments: AttachmentDrafts!
    private var window: UIWindow!
    private var previousKeyWindow: UIWindow?
    private var observer: SendWindowObserver!
    private var sendTask: Task<Void, Never>?

    override func setUp() async throws {
        suite = "send-presentation-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SendPresentationProtocol.self]
        session = URLSession(configuration: configuration)
        SendPresentationProtocol.reset()
        store = AppStore(api: .init(baseURL: URL(string: "http://127.0.0.1/\(suite!)")!, token: nil, session: session),
            journal: OperationJournal(defaults: defaults), memory: ConversationMemory(hostID: suite, defaults: defaults))
        attachments = AttachmentDrafts(hostID: suite)
        store.attachmentDrafts = attachments
        store.connection = "Connected"
        store.selectedSession = .init(id: "presentation", title: "Presentation test", updatedAt: "", profile: "test")
        try store.receiveFreshSnapshotForTesting(messages: history(30..<60), before: "older", hasMore: true)
        store.draft = submittedText
        XCTAssertFalse(store.fixture, "These cases must use the production submission and receipt paths.")
    }

    override func tearDown() async throws {
        observer?.stop()
        window?.endEditing(true)
        window?.isHidden = true
        window?.rootViewController = nil
        previousKeyWindow?.makeKey()
        sendTask?.cancel()
        await sendTask?.value
        store.background()
        await store.waitForScheduledRefreshes().value
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: attachments.directory)
        SendPresentationProtocol.reset()
        observer = nil
        window = nil
        sendTask = nil
    }

    func testAtLatestPendingBubbleIsVisibleBeforeHeldHTTPReceipt() async throws {
        defer { attachEvidence() }
        try await hostChatWithKeyboard()
        let command = try await beginSend()
        try await observeFrames(12)

        XCTAssertFalse(command.hasResponded)
        XCTAssertTrue(observer.submittedFrames.contains { $0.outgoing?.visible == true },
            "Sending at Latest must paint the outgoing bubble while the HTTP receipt is still held.")
        XCTAssertFalse(observer.submittedFrames.contains { $0.activity?.visible == true })
        assertOutgoingPixels()
    }

    func testReadingOlderHistorySendShowsPendingBubbleBeforeHeldHTTPReceipt() async throws {
        defer { attachEvidence() }
        try await hostChatWithKeyboard()
        let started = expectation(description: "The production history request started")
        SendPresentationProtocol.watch("/history", started: started)
        let load = Task { await store.loadOlder() }
        addTeardownBlock { load.cancel(); await load.value }
        let older = try await heldRequest("/history", started: started)
        older.respond(try CompanionAPI.encoder.encode(HistoryPage(messages: history(0..<30), before: nil, hasMore: false)))
        await load.value
        try await waitForFrame("The full older page is displayed") { $0.rowCount == 60 }
        let table = try XCTUnwrap(observer.table)
        table.delegate?.scrollViewWillBeginDragging?(table)
        table.scrollToRow(at: IndexPath(row: 10, section: 0), at: .top, animated: false)
        table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: false)
        try await observeFrames(3)
        XCTAssertTrue(store.isReadingHistory, "The real older-history flow must establish the reader-away precondition.")
        XCTAssertGreaterThan(table.contentSize.height - table.contentOffset.y - table.bounds.height, 300)
        XCTAssertFalse(table.indexPathsForVisibleRows?.contains(IndexPath(row: 59, section: 0)) == true)
        observer.capture("reader-away-before-send")

        let command = try await beginSend()
        try await observeFrames(30)

        XCTAssertFalse(command.hasResponded)
        XCTAssertTrue(observer.submittedFrames.contains { $0.outgoing?.visible == true },
            "Sending from older history must bring the pending outgoing bubble into the unobscured viewport before any receipt. A hidden model row does not satisfy this.")
        assertOutgoingPixels()
    }

    func testNewWorkingDotsFollowSettledOutgoingBubbleThroughEarlySocketReceipt() async throws {
        defer { attachEvidence() }
        try await hostChatWithKeyboard()
        XCTAssertFalse(observer.frames.contains { $0.activity?.visible == true })
        let command = try await beginSend()
        let operation = try XCTUnwrap(command.json["operation_id"] as? String)
        observer.mark("early-working")
        try receive(type: "connection", payload: ["state": "working"])
        observer.mark("early-socket-receipt")
        try receive(type: "receipt", payload: ["operation_id": operation, "status": "accepted", "user_row_id": "accepted-outgoing"])
        try await waitForFrame("New working dots are visible") { $0.activity?.visible == true }
        try await observeFrames(12)

        XCTAssertFalse(command.hasResponded, "Socket acceptance must precede the held HTTP response.")
        XCTAssertEqual(observer.editorText, "", "The real correlated receipt must clear the multiline editor.")
        let frames = observer.submittedFrames
        let firstDots = try XCTUnwrap(frames.firstIndex { $0.activity?.visible == true })
        let beforeDots = Array(frames.prefix(firstDots))
        let settled = beforeDots.indices.dropFirst().last {
            beforeDots[$0].outgoingIsSettled(comparedTo: beforeDots[$0 - 1])
        }
        XCTAssertNotNil(settled,
            "New dots need a prior displayed, stable outgoing bubble. Publishing both in one displayed frame does not establish order.")
        if let settled {
            XCTAssertTrue(frames[firstDots].outgoingIsSettled(comparedTo: beforeDots[settled]),
                "The outgoing bubble and composer geometry must finish moving before new working dots appear.")
        }
        XCTAssertTrue(frames.suffix(from: firstDots).allSatisfy { $0.outgoingIsSettled(comparedTo: frames[firstDots]) },
            "The outgoing bubble must stay settled while the newly visible dots are displayed.")
        assertOutgoingPixels()
    }

    func testExistingWorkingDotsRemainWhilePendingDirectionBecomesVisible() async throws {
        store.runState = .working
        defer { attachEvidence() }
        try await hostChatWithKeyboard()
        try await waitForFrame("The existing working indicator is visible") { $0.activity?.visible == true }
        observer.mark("working-before-send")

        let command = try await beginSend()
        try await observeFrames(12)

        XCTAssertFalse(command.hasResponded)
        let outgoing = try XCTUnwrap(observer.submittedFrames.first { $0.outgoing?.visible == true },
            "A direction sent during existing work must become visible before its receipt.")
        XCTAssertTrue(outgoing.activity?.visible == true, "Existing dots must remain classified as existing work.")
        XCTAssertLessThanOrEqual(try XCTUnwrap(outgoing.outgoing).frame.maxY,
            try XCTUnwrap(outgoing.activity).frame.minY + 1)
        assertOutgoingPixels()
    }

    private func hostChatWithKeyboard() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: ChatView(store: store))
        observer = SendWindowObserver(window: window, submittedText: submittedText)
        window.makeKeyAndVisible()
        observer.start()
        window.layoutIfNeeded()
        try await waitForFrame("The real chat and multiline composer are attached") {
            $0.rowCount == 30 && $0.editorFrame != nil
        }
        let editor = try XCTUnwrap(observer.editor)
        XCTAssertEqual(observer.editorText, submittedText)
        XCTAssertTrue(editor.becomeFirstResponder(), "The real composer must accept keyboard focus.")
        try await waitForFrame("The software keyboard is visibly open") { $0.keyboardFrame.height > 100 }
        try await observeFrames(3)
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertGreaterThan(try XCTUnwrap(observer.frames.last?.editorFrame).height, 60,
            "The setup must exercise a genuinely multiline composer.")
        observer.capture("ready-with-multiline-composer-and-keyboard")
    }

    private func beginSend() async throws -> SendPresentationProtocol {
        let started = expectation(description: "The production send request is held")
        SendPresentationProtocol.watch("/commands", started: started)
        observer.mark("send-input")
        sendTask = Task { await store.send() }
        let command = try await heldRequest("/commands", started: started)
        XCTAssertEqual(command.json["kind"] as? String, "send")
        XCTAssertEqual(command.json["text"] as? String, submittedText)
        return command
    }

    private func heldRequest(_ suffix: String, started: XCTestExpectation) async throws -> SendPresentationProtocol {
        let result = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(result, .completed, "The request did not reach the controlled transport.")
        return try XCTUnwrap(SendPresentationProtocol.requests.first { $0.request.url?.path.hasSuffix(suffix) == true })
    }

    private func observeFrames(_ count: Int) async throws {
        let target = observer.frames.count + count
        try await waitForFrame("Observe \(count) subsequent display callbacks") { $0.index >= target }
    }

    private func waitForFrame(_ description: String, predicate: @escaping (SendWindowObserver.Frame) -> Bool) async throws {
        if let last = observer.frames.last, predicate(last) { return }
        let ready = expectation(description: description)
        var fulfilled = false
        observer.onFrame = { frame in
            if !fulfilled && predicate(frame) { fulfilled = true; ready.fulfill() }
        }
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        observer.onFrame = nil
        XCTAssertEqual(result, .completed, description)
        guard result == .completed else { throw ClientError.invalidResponse }
    }

    private func receive(type: String, payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": type, "session_id": "presentation", "payload": payload])
        try store.receive(CompanionAPI.decoder.decode(WireEvent.self, from: data))
    }

    private func history(_ range: Range<Int>) -> [ChatMessage] {
        range.map { .init(id: "history-\($0)", role: "assistant", text: "History row \($0). A public reply for the reading viewport.", provisional: false) }
    }

    private func assertOutgoingPixels() {
        if let outgoing = observer.frames.last?.outgoing, outgoing.visible {
            observer.capture("outgoing-at-assertion", outgoingRegion: outgoing.visibleFrame)
        }
        XCTAssertGreaterThan(observer.outgoingPixelCount, 100,
            "The captured visible outgoing region must contain painted blue bubble pixels. Existence or model order alone is insufficient.")
    }

    private func attachEvidence() {
        guard let observer else { return }
        observer.stop()
        observer.capture("final-window")
        for (name, image) in observer.captures {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let attachment = XCTAttachment(data: observer.trace(), uniformTypeIdentifier: "public.json")
        attachment.name = "send-window-display-samples"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class SendWindowObserver: NSObject {
    struct Element: Codable {
        let frame: CGRect
        let modelFrame: CGRect
        let visibleFrame: CGRect
        let opacity: Float
        let hasPresentationLayer: Bool
        var visible: Bool { opacity > 0.9 && visibleFrame.width >= 44 && visibleFrame.height >= 32 }
    }

    struct Frame: Codable {
        let index: Int
        let timestamp: CFTimeInterval
        let displayTimestamp: CFTimeInterval
        let outgoing: Element?
        let activity: Element?
        let editorFrame: CGRect?
        let viewport: CGRect
        let keyboardFrame: CGRect
        let contentOffset: CGPoint
        let rowCount: Int

        func outgoingIsSettled(comparedTo previous: Frame) -> Bool {
            guard let outgoing, let old = previous.outgoing, outgoing.visible, old.visible,
                  outgoing.hasPresentationLayer, old.hasPresentationLayer,
                  let editorFrame, let oldEditor = previous.editorFrame else { return false }
            return close(outgoing.frame, old.frame) && close(outgoing.frame, outgoing.modelFrame)
                && close(editorFrame, oldEditor) && close(viewport, previous.viewport)
        }

        private func close(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.minY - rhs.minY) < 0.5
                && abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
        }
    }

    struct Event: Codable { let name: String; let timestamp: CFTimeInterval }
    struct Capture: Codable {
        let name: String
        let frameIndex: Int
        let timestamp: CFTimeInterval
        let hierarchyRendered: Bool
        let outgoingPixels: Int
    }
    private let window: UIWindow
    private let submittedText: String
    private var link: CADisplayLink?
    private var keyboardFrame = CGRect.zero
    private var sawOutgoing = false
    private var sawActivity = false
    private(set) var frames: [Frame] = []
    private(set) var events: [Event] = []
    private(set) var captures: [(String, UIImage)] = []
    private var captureResults: [Capture] = []
    private(set) var outgoingPixelCount = 0
    var onFrame: ((Frame) -> Void)?
    var table: UITableView? { descendants(window).compactMap { $0 as? UITableView }.first { $0.accessibilityIdentifier == "transcript" } }
    var editor: UIView? { descendants(window).first { ($0 as? UITextView)?.isEditable == true || $0 is UITextField } }
    var editorText: String? { (editor as? UITextView)?.text ?? (editor as? UITextField)?.text }
    var submittedFrames: [Frame] {
        guard let submitted = events.first(where: { $0.name == "send-input" }) else { return [] }
        return frames.filter { $0.timestamp >= submitted.timestamp }
    }

    init(window: UIWindow, submittedText: String) {
        self.window = window
        self.submittedText = submittedText
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardDidShowNotification, object: nil)
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(sample(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.invalidate()
        link = nil
        onFrame = nil
        NotificationCenter.default.removeObserver(self)
    }

    func mark(_ name: String) { events.append(.init(name: name, timestamp: CACurrentMediaTime())) }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let converted = window.convert(frame.cgRectValue, from: window.screen.coordinateSpace)
        keyboardFrame = window.bounds.intersection(converted)
        if keyboardFrame.isNull { keyboardFrame = .zero }
        mark("keyboard-frame")
    }

    @objc private func sample(_ link: CADisplayLink) {
        let table = table
        let viewport: CGRect
        if let table {
            let bounds = table.layer.presentation()?.bounds ?? table.bounds
            viewport = presentationRect(table, rect: bounds.inset(by: table.adjustedContentInset)).intersection(window.bounds)
        } else { viewport = .zero }
        let outgoingView = table.flatMap { table in
            table.visibleCells.flatMap { descendants($0) }.compactMap { $0 as? UITextView }
                .first { !$0.isEditable && $0.accessibilityLabel == "You. " + submittedText }
        }
        let activityView = table.flatMap { descendants($0).first { $0.accessibilityIdentifier == "workingIndicator" } }
        let outgoing = outgoingView.map { element($0, viewport: viewport) }
        let activity = activityView.map { element($0, viewport: viewport) }
        let frame = Frame(index: frames.count + 1, timestamp: CACurrentMediaTime(), displayTimestamp: link.timestamp, outgoing: outgoing, activity: activity,
            editorFrame: editor.map { presentationRect($0) }, viewport: viewport, keyboardFrame: keyboardFrame,
            contentOffset: table?.contentOffset ?? .zero, rowCount: table?.numberOfRows(inSection: 0) ?? 0)
        frames.append(frame)
        if outgoing?.visible == true && !sawOutgoing {
            sawOutgoing = true
            capture("first-visible-outgoing", outgoingRegion: outgoing?.visibleFrame)
        }
        if activity?.visible == true && !sawActivity {
            sawActivity = true
            capture("first-visible-working", outgoingRegion: outgoing?.visibleFrame)
        }
        onFrame?(frame)
    }

    private func element(_ view: UIView, viewport: CGRect) -> Element {
        let frame = presentationRect(view)
        var clipped = frame.intersection(viewport)
        var opacity: Float = 1
        var ancestor: UIView? = view
        while let current = ancestor {
            opacity *= current.isHidden ? 0 : (current.layer.presentation()?.opacity ?? current.layer.opacity)
            if current.clipsToBounds { clipped = clipped.intersection(presentationRect(current)) }
            ancestor = current.superview
        }
        return .init(frame: frame, modelFrame: view.convert(view.bounds, to: window),
            visibleFrame: clipped.isNull ? .zero : clipped, opacity: opacity, hasPresentationLayer: view.layer.presentation() != nil)
    }

    private func presentationRect(_ view: UIView, rect: CGRect? = nil) -> CGRect {
        if let layer = view.layer.presentation(), let root = window.layer.presentation() {
            return layer.convert(rect ?? layer.bounds, to: root)
        }
        return view.convert(rect ?? view.bounds, to: window)
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }

    func capture(_ name: String, outgoingRegion: CGRect? = nil) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        captures.append((name, image))
        let pixels = rendered ? outgoingRegion.map { bluePixels(image, in: $0) } ?? 0 : 0
        outgoingPixelCount = max(outgoingPixelCount, pixels)
        captureResults.append(.init(name: name, frameIndex: frames.count, timestamp: CACurrentMediaTime(), hierarchyRendered: rendered, outgoingPixels: pixels))
    }

    private func bluePixels(_ image: UIImage, in region: CGRect) -> Int {
        guard let raster = image.cgImage, let crop = raster.cropping(to: region.integral) else { return 0 }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        guard let context = CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return 0 }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            if blue > red + 60 && blue > green + 30 { count += 1 }
        }
        return count
    }

    func trace() -> Data {
        struct Trace: Encodable {
            let scope: String
            let os: String
            let reduceMotion: Bool
            let windowBounds: CGRect
            let outgoingPixelCount: Int
            let events: [Event]
            let frames: [Frame]
            let captures: [Capture]
        }
        let trace = Trace(scope: "Controlled transport; real attached ChatView and software keyboard. Send invokes the production button action store.send. CADisplayLink samples presentation geometry without forcing layout. Keyframes use drawHierarchy without afterScreenUpdates. Samples are not hardware display acknowledgements or an FPS benchmark.",
            os: ProcessInfo.processInfo.operatingSystemVersionString, reduceMotion: UIAccessibility.isReduceMotionEnabled,
            windowBounds: window.bounds, outgoingPixelCount: outgoingPixelCount, events: events, frames: frames, captures: captureResults)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(trace)) ?? Data("Trace encoding failed".utf8)
    }
}

private final class SendPresentationProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [SendPresentationProtocol] = []
    nonisolated(unsafe) private static var starts: [String: XCTestExpectation] = [:]
    private var responded = false
    private(set) var json: [String: Any] = [:]
    static var requests: [SendPresentationProtocol] { lock.withLock { held } }
    var hasResponded: Bool { Self.lock.withLock { responded } }

    static func reset() { lock.withLock { held = []; starts = [:] } }
    static func watch(_ suffix: String, started: XCTestExpectation) { lock.withLock { starts[suffix] = started } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let started = Self.lock.withLock {
            Self.held.append(self)
            let suffix = Self.starts.keys.first { request.url?.path.hasSuffix($0) == true }
            return suffix.flatMap { Self.starts.removeValue(forKey: $0) }
        }
        started?.fulfill()
    }

    func respond(_ data: Data) {
        Self.lock.withLock { responded = true }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
