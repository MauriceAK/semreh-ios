import Foundation
import CoreFoundation
import QuartzCore
import UIKit
import os

@MainActor
final class ChatPerformance: NSObject {
    static let shared = ChatPerformance()

    enum Work: String, Codable, Sendable {
        case draftPersistence, socketDecode, deltaFlush, transcriptUpdate, markdownLayout
        case sendReceipt, historyFetch, latestFetch, latestJump, scroll, draftChangeToNextDisplayCallback, deltaQueuedToLayout, latestRequestToLayout

        fileprivate var signpostName: StaticString {
            switch self {
            case .draftPersistence: "Draft persistence"
            case .socketDecode: "Socket decode"
            case .deltaFlush: "Delta flush"
            case .transcriptUpdate: "Transcript update"
            case .markdownLayout: "Markdown layout"
            case .sendReceipt: "Send receipt"
            case .historyFetch: "History fetch"
            case .latestFetch: "Latest fetch"
            case .latestJump: "Latest jump"
            case .scroll: "Chat scroll"
            case .draftChangeToNextDisplayCallback: "Draft to callback"
            case .deltaQueuedToLayout: "Delta to layout"
            case .latestRequestToLayout: "Latest to layout"
            }
        }
    }

    enum Milestone: String, Codable, Sendable {
        case draftChanged, deltaQueued, transcriptLaidOut, latestRequested
        case latestWindowReady, latestViewportMoved, latestJumpCompleted, latestCancelled, latestJumpCancelled
    }

    enum Outcome: String, Codable, Sendable { case completed, failed, cancelled }

    struct Token: Sendable {
        fileprivate let id: Int
    }

    struct Span: Codable, Sendable {
        let id: Int
        let work: Work
        let start: Double
        let end: Double
        let count: Int
        let outcome: Outcome
    }

    struct Event: Codable, Sendable {
        let milestone: Milestone
        let time: Double
        let count: Int
    }

    struct Frame: Codable, Sendable {
        let segment: Int
        let callback: Double
        let timestamp: Double
        let targetTimestamp: Double
        let scrolling: Bool
    }

    struct Snapshot: Codable, Sendable {
        let schema: Int
        let runID: String
        let label: String
        let configuration: String
        let bundleVersion: String
        let bundleShortVersion: String
        let os: String
        let model: String
        let simulator: Bool
        let screenMaximumFramesPerSecond: Int
        let displayLinkPolicy: String
        let startedAt: String
        let duration: Double
        let thermalStateAtStart: Int
        let thermalStateAtEnd: Int
        let lowPowerModeAtStart: Bool
        let lowPowerModeAtEnd: Bool
        let spans: [Span]
        let events: [Event]
        let frames: [Frame]
        let unfinishedSpans: Int
        let droppedRecords: Int
        let invalidOperations: Int
        let finishReason: String
    }

    private struct Pending {
        let work: Work
        let start: Double
        var count: Int
        let signpost: OSSignpostIntervalState
    }

    private let signposter = OSSignposter(subsystem: "org.hermescompanion.performance", category: .pointsOfInterest)
    private let logger = Logger(subsystem: "org.hermescompanion.performance", category: "export")
    private let limit = 30_000
    private let runID = UUID().uuidString
    private let origin = CACurrentMediaTime()
    private let startedAt = ISO8601DateFormatter().string(from: Date())
    private let initialThermal = ProcessInfo.processInfo.thermalState.rawValue
    private let initialLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private let label: String
    private let controlID: String?
    private var enabled: Bool
    private var link: CADisplayLink?
    private var frameSegment = 0
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var spans: [Span] = []
    private var events: [Event] = []
    private var frames: [Frame] = []
    private var draftTokens: [Token] = []
    private var deltaToken: Token?
    private var latestToken: Token?
    private var latestAwaitingWindow = false
    private var droppedRecords = 0
    private var invalidOperations = 0

    private override init() {
        let arguments = ProcessInfo.processInfo.arguments
        enabled = arguments.contains("--chat-performance")
        let suppliedLabel = Self.argument("--chat-performance-label", in: arguments) ?? "unlabeled"
        label = String(suppliedLabel.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(64))
        controlID = Self.argument("--chat-performance-control", in: arguments).flatMap(UUID.init(uuidString:))?.uuidString
        super.init()
        guard enabled else { return }
        spans.reserveCapacity(2_000)
        events.reserveCapacity(2_000)
        frames.reserveCapacity(12_000)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        if let controlID {
            let name = "org.hermescompanion.performance.finish." + controlID
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
                Task { @MainActor in ChatPerformance.shared.finish(reason: "controlled") }
            }, name as CFString, nil, .deliverImmediately)
        }
        if let durationText = Self.argument("--chat-performance-duration", in: arguments),
           let duration = Double(durationText), duration.isFinite, (1...600).contains(duration) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                self?.finish(reason: "duration")
            }
        }
    }

    private static func argument(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    func begin(_ work: Work, count: Int = 1) -> Token? {
        guard enabled else { return nil }
        guard count >= 0, pending.count < 128, reserveRecord() else { invalidOperations += 1; return nil }
        nextID += 1
        let state = work == .scroll
            ? signposter.beginAnimationInterval(work.signpostName, id: signposter.makeSignpostID())
            : signposter.beginInterval(work.signpostName, id: signposter.makeSignpostID())
        pending[nextID] = Pending(work: work, start: CACurrentMediaTime() - origin, count: count, signpost: state)
        if observesFrames(work) { ensureDisplayLink() }
        return Token(id: nextID)
    }

    func end(_ token: Token?, outcome: Outcome = .completed, count: Int? = nil) {
        guard enabled, let token else { return }
        guard let value = pending.removeValue(forKey: token.id) else { invalidOperations += 1; return }
        let end = CACurrentMediaTime() - origin
        signposter.endInterval(value.work.signpostName, value.signpost)
        let workCount = count ?? value.count
        guard workCount >= 0 else { invalidOperations += 1; return }
        spans.append(Span(id: token.id, work: value.work, start: value.start, end: end, count: workCount, outcome: outcome))
        if !pending.values.contains(where: { observesFrames($0.work) }) { link?.isPaused = true }
    }

    func mark(_ milestone: Milestone, count: Int = 1) {
        guard enabled else { return }
        guard count >= 0, reserveRecord() else { invalidOperations += 1; return }
        events.append(Event(milestone: milestone, time: CACurrentMediaTime() - origin, count: count))
        switch milestone {
        case .draftChanged:
            if let token = begin(.draftChangeToNextDisplayCallback, count: count) { draftTokens.append(token) }
        case .deltaQueued:
            if let deltaToken, var value = pending[deltaToken.id] {
                value.count += count
                pending[deltaToken.id] = value
            } else { deltaToken = begin(.deltaQueuedToLayout, count: count) }
        case .latestRequested:
            end(latestToken, outcome: .cancelled)
            latestToken = begin(.latestRequestToLayout, count: count)
            latestAwaitingWindow = true
        case .latestWindowReady:
            latestAwaitingWindow = false
        case .latestCancelled:
            end(latestToken, outcome: .cancelled)
            latestToken = nil
            latestAwaitingWindow = false
        case .latestViewportMoved, .latestJumpCompleted, .latestJumpCancelled:
            break
        case .transcriptLaidOut:
            end(deltaToken)
            deltaToken = nil
            if !latestAwaitingWindow {
                end(latestToken)
                latestToken = nil
            }
        }
    }

    func finish() { finish(reason: "explicit") }

    @objc private func backgrounded() { finish(reason: "backgrounded") }

    private func finish(reason: String) {
        guard enabled else { return }
        enabled = false
        if let controlID {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil,
                CFNotificationName(rawValue: ("org.hermescompanion.performance.finish." + controlID) as CFString), nil)
        }
        link?.invalidate()
        link = nil
        for value in pending.values { signposter.endInterval(value.work.signpostName, value.signpost) }
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        let snapshot = Snapshot(
            schema: 1, runID: runID, label: label, configuration: configuration,
            bundleVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            bundleShortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            os: UIDevice.current.systemVersion, model: UIDevice.current.model, simulator: simulator,
            screenMaximumFramesPerSecond: UIScreen.main.maximumFramesPerSecond,
            displayLinkPolicy: "default-adaptive; callback diagnostics only; not presented frames",
            startedAt: startedAt, duration: CACurrentMediaTime() - origin,
            thermalStateAtStart: initialThermal, thermalStateAtEnd: ProcessInfo.processInfo.thermalState.rawValue,
            lowPowerModeAtStart: initialLowPower, lowPowerModeAtEnd: ProcessInfo.processInfo.isLowPowerModeEnabled,
            spans: spans, events: events, frames: frames, unfinishedSpans: pending.count,
            droppedRecords: droppedRecords, invalidOperations: invalidOperations, finishReason: reason
        )
        let logger = logger
        let controlID = controlID
        Task.detached(priority: .utility) {
            do {
                let directory = URL.cachesDirectory.appending(path: "ChatPerformance", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(snapshot).write(to: directory.appending(path: "latest.json"), options: .atomic)
                if let controlID {
                    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                        CFNotificationName(rawValue: ("org.hermescompanion.performance.exported." + controlID) as CFString), nil, nil, true)
                }
                logger.notice("Chat performance diagnostic export complete")
            } catch { logger.error("Chat performance diagnostic export failed") }
        }
    }

    private func reserveRecord() -> Bool {
        guard spans.count + events.count + frames.count + pending.count < limit else { droppedRecords += 1; return false }
        return true
    }

    private func ensureDisplayLink() {
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        if link?.isPaused != false || frameSegment == 0 { frameSegment += 1 }
        link?.isPaused = false
    }

    private func observesFrames(_ work: Work) -> Bool {
        [.scroll, .latestJump, .draftChangeToNextDisplayCallback, .deltaQueuedToLayout, .latestRequestToLayout].contains(work)
    }

    @objc private func tick(_ sender: CADisplayLink) {
        let callback = CACurrentMediaTime()
        if reserveRecord() {
            frames.append(Frame(segment: frameSegment, callback: callback - origin, timestamp: sender.timestamp - origin,
                                targetTimestamp: sender.targetTimestamp - origin,
                                scrolling: pending.values.contains { $0.work == .scroll }))
        }
        let drafts = draftTokens
        draftTokens.removeAll(keepingCapacity: true)
        for token in drafts { end(token) }
    }
}
