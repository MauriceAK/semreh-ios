import UIKit
import XCTest
@testable import HermesCompanion

@MainActor
final class DeliveryCaptionTests: XCTestCase {
    func testAcceptedDeliveryReplacesPendingCaptionWithoutOverlappingLabels() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .dark
        let controller = TranscriptController()
        window.rootViewController = controller
        let observer = DeliveryCaptionObserver(window: window)
        defer {
            observer.stop()
            for (name, image) in observer.captures {
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            if let data = try? JSONEncoder().encode(observer.samples) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "delivery-caption-display-samples"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        let text = "First line\nSecond line\nThird line\nFourth line"
        let history = (0..<30).map {
            ChatMessage(id: "history-\($0)", role: "assistant", text: "History row \($0). A public reply for the reading viewport.", provisional: false)
        }
        let pending = ChatMessage(id: "pending-operation", role: "user", text: text, provisional: true,
                                  operationId: "caption-operation", delivery: .sending)
        let accepted = ChatMessage(id: "canonical-outgoing", role: "user", text: text, provisional: false,
                                   operationId: "caption-operation", delivery: .accepted)
        let revision = UUID()
        controller.update(messages: history + [pending], hasMore: false, loading: false, latestRevision: revision)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        observer.start()
        try await observer.observeFrames(4)
        XCTAssertEqual(observer.samples.last?.visibleLabels.map(\.text), ["Sending…"])
        observer.capture("pending-caption")

        observer.accepted = true
        controller.update(messages: history + [accepted], hasMore: false, loading: false, latestRevision: revision)
        observer.sampleImmediate()
        try await observer.observeFrames(24)
        observer.capture("accepted-caption")

        let displayed = observer.samples.filter { $0.accepted && $0.displayCallback }
        XCTAssertGreaterThanOrEqual(displayed.count, 24)
        for sample in displayed {
            XCTAssertEqual(sample.visibleLabels.map(\.text), ["Sent"],
                           "Each displayed accepted frame must contain one Sent caption. Frame \(sample.index) has \(sample.visibleLabels.map(\.text)).")
        }
        let table = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
        let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: history.count, section: 0)))
        let body = try XCTUnwrap(DeliveryCaptionObserver.descendants(cell).compactMap { $0 as? UITextView }.first)
        XCTAssertEqual(body.text, text)
        XCTAssertEqual(body.accessibilityIdentifier, "message-canonical-outgoing")
    }

    func testChangedBodyAndCaptionPresenceStillUpdateContentAndHeight() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = TranscriptController()
        window.rootViewController = controller
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        let revision = UUID()
        let pending = ChatMessage(id: "pending-edit", role: "user", text: "Original body", provisional: true,
                                  operationId: "edited-operation", delivery: .sending)
        controller.update(messages: [pending], hasMore: false, loading: false, latestRevision: revision)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let table = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
        let path = IndexPath(row: 0, section: 0)
        let originalHeight = table.rectForRow(at: path).height

        var edited = pending
        edited.text = "Revised first line\nSecond line\nThird line\nFourth line"
        edited.delivery = .uncertain
        controller.update(messages: [edited], hasMore: false, loading: false, latestRevision: revision)
        let editedCell = try XCTUnwrap(table.cellForRow(at: path))
        let body = try XCTUnwrap(DeliveryCaptionObserver.descendants(editedCell).compactMap { $0 as? UITextView }.first)
        XCTAssertEqual(body.text, edited.text)
        XCTAssertEqual(body.accessibilityLabel, "You. " + edited.text)
        XCTAssertTrue(DeliveryCaptionObserver.descendants(editedCell).compactMap { $0 as? UILabel }.contains {
            !$0.isHidden && $0.text == "Delivery uncertain"
        })
        let captionedHeight = table.rectForRow(at: path).height
        XCTAssertGreaterThan(captionedHeight, originalHeight)

        edited.delivery = nil
        controller.update(messages: [edited], hasMore: false, loading: false, latestRevision: revision)
        let uncaptionedCell = try XCTUnwrap(table.cellForRow(at: path))
        XCTAssertFalse(DeliveryCaptionObserver.descendants(uncaptionedCell).compactMap { $0 as? UILabel }.contains {
            !$0.isHidden && ["Sending…", "Sent", "Delivery uncertain"].contains($0.text ?? "")
        })
        XCTAssertLessThan(table.rectForRow(at: path).height, captionedHeight)

        edited.delivery = .sending
        controller.update(messages: [edited], hasMore: false, loading: false, latestRevision: revision)
        let recaptionedCell = try XCTUnwrap(table.cellForRow(at: path))
        XCTAssertTrue(DeliveryCaptionObserver.descendants(recaptionedCell).compactMap { $0 as? UILabel }.contains {
            !$0.isHidden && $0.text == "Sending…"
        })
        XCTAssertEqual(table.rectForRow(at: path).height, captionedHeight, accuracy: 0.5)
    }
}

@MainActor
private final class DeliveryCaptionObserver: NSObject {
    struct Label: Codable {
        let text: String
        let identity: String
        let cellIdentity: String?
        let modelFrame: CGRect
        let presentationFrame: CGRect
        let visibleFrame: CGRect
        let opacity: Float
        let hasPresentationLayer: Bool
        var visible: Bool { opacity > 0.05 && visibleFrame.width > 1 && visibleFrame.height > 1 }
    }
    struct Sample: Codable {
        let index: Int
        let timestamp: CFTimeInterval
        let displayTimestamp: CFTimeInterval?
        let accepted: Bool
        let displayCallback: Bool
        let reduceMotion: Bool
        let labels: [Label]
        var visibleLabels: [Label] { labels.filter(\.visible) }
    }
    private let window: UIWindow
    private var link: CADisplayLink?
    private var onFrame: (() -> Void)?
    private var displayCount = 0
    var accepted = false
    private(set) var samples: [Sample] = []
    private(set) var captures: [(String, UIImage)] = []

    init(window: UIWindow) { self.window = window; super.init() }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil; onFrame = nil }

    func observeFrames(_ count: Int) async throws {
        let target = displayCount + count
        let ready = XCTestExpectation(description: "Observe \(count) delivery-caption display callbacks")
        var fulfilled = false
        onFrame = { [weak self] in
            if !fulfilled, let self, self.displayCount >= target {
                fulfilled = true
                ready.fulfill()
            }
        }
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        onFrame = nil
        XCTAssertEqual(result, .completed)
        guard result == .completed else { throw ClientError.invalidResponse }
    }

    @objc private func tick(_ link: CADisplayLink) {
        sample(displayTimestamp: link.timestamp)
        displayCount += 1
        onFrame?()
    }
    func sampleImmediate() { sample(displayTimestamp: nil) }

    private func sample(displayTimestamp: CFTimeInterval?) {
        let labels = Self.descendants(window).compactMap { $0 as? UILabel }.filter {
            ["Sending…", "Sent", "Delivery uncertain"].contains($0.text ?? "")
        }.map { label in
            var opacity: Float = 1
            var visibleFrame = presentationFrame(label).intersection(window.bounds)
            var cellIdentity: String?
            var ancestor: UIView? = label
            while let current = ancestor {
                opacity *= current.isHidden ? 0 : (current.layer.presentation()?.opacity ?? current.layer.opacity)
                if current.clipsToBounds { visibleFrame = visibleFrame.intersection(presentationFrame(current)) }
                if current is BubbleCell { cellIdentity = String(describing: ObjectIdentifier(current)) }
                ancestor = current.superview
            }
            return Label(text: label.text ?? "", identity: String(describing: ObjectIdentifier(label)),
                         cellIdentity: cellIdentity, modelFrame: label.convert(label.bounds, to: window),
                         presentationFrame: presentationFrame(label), visibleFrame: visibleFrame.isNull ? .zero : visibleFrame,
                         opacity: opacity, hasPresentationLayer: label.layer.presentation() != nil)
        }
        let sample = Sample(index: samples.count, timestamp: CACurrentMediaTime(), displayTimestamp: displayTimestamp,
                            accepted: accepted, displayCallback: displayTimestamp != nil,
                            reduceMotion: UIAccessibility.isReduceMotionEnabled, labels: labels)
        samples.append(sample)
        if accepted && displayTimestamp != nil && sample.visibleLabels.count > 1 && captures.count < 6 {
            capture("overlapping-captions-\(sample.index)")
        }
    }

    private func presentationFrame(_ view: UIView) -> CGRect {
        if let layer = view.layer.presentation(), let root = window.layer.presentation() {
            return layer.convert(layer.bounds, to: root)
        }
        return view.convert(view.bounds, to: window)
    }
    static func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }

    func capture(_ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        captures.append((name, image))
    }
}
